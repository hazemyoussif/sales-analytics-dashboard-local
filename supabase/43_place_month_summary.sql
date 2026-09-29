-- ===========================================================================
-- 43. The place filters are the last thing reading the invoice lines
-- ===========================================================================
-- The same query, eight times in a row, signed in as a real user:
--
--   10,586ms  5,212  6,056  2,119  1,917  1,667  1,632  1,808
--
-- A plan does not change between runs. That is a cold cache warming up, and
-- the first number is what a user gets when nobody has run a place filter for
-- a while -- which on a dashboard is most of the time.
--
-- The irony is that the optimisation work caused it. dashboard_invoice_lines
-- is 739,000 rows of twenty-five columns. Since files 19, 33, 36 and 41 routed
-- everything through summaries, almost nothing reads it any more, so Postgres
-- evicts it -- and a gov or city filter is one of the last things that still
-- touches it, so it pays for the whole table being cold.
--
-- The unfiltered view stays fast for the same reason in reverse: it reads only
-- small tables, and small tables stay resident.
--
-- So place gets what product and partner already have. Same shape as
-- dashboard_product_month with two more key columns, and narrow enough to stay
-- in memory: eight small columns against twenty-five wide ones.
--
-- NULL GOV AND CITY BECOME '' IN THE KEY. A primary key cannot hold nulls, and
-- a line with no city still has revenue that has to appear in a total. Empty
-- string is a real group here, not a missing one.
--
-- This file only BUILDS and MAINTAINS the table. Routing product_facts through
-- it is file 44, so that if the routing turns out to be wrong the table is
-- already correct and only one thing has to be fixed.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run. The initial build scans the
-- invoice lines once.

create table if not exists public.dashboard_product_place_month (
  product_id bigint  not null,
  gov        text    not null,
  city       text    not null,
  month      date    not null,
  units      numeric not null default 0,
  revenue    numeric not null default 0,
  margin     numeric,
  invoices   bigint  not null default 0,
  updated_at timestamptz not null default now(),
  primary key (product_id, gov, city, month)
);

create index if not exists idx_place_month_gov
  on public.dashboard_product_place_month (gov, month);
create index if not exists idx_place_month_city
  on public.dashboard_product_place_month (city, month);

alter table public.dashboard_product_place_month enable row level security;
drop policy if exists place_month_read on public.dashboard_product_place_month;
create policy place_month_read on public.dashboard_product_place_month
  for select to authenticated using (true);
grant select on public.dashboard_product_place_month to authenticated;

create or replace function public.refresh_place_month(p_since date default null)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  n bigint;
  -- date_trunc for the reason file 27 documents: the delete compares against a
  -- column that only holds month starts, so a mid-month cutoff leaves the
  -- oldest month behind and the insert then collides with it.
  cutoff date := date_trunc('month', coalesce(p_since, date '1900-01-01'))::date;
begin
  delete from public.dashboard_product_place_month where month >= cutoff;

  insert into public.dashboard_product_place_month
    (product_id, gov, city, month, units, revenue, margin, invoices, updated_at)
  select l.product_id,
         coalesce(l.gov, ''), coalesce(l.city, ''),
         date_trunc('month', l.invoice_date)::date,
         sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
         count(distinct l.move_id), now()
  from public.dashboard_invoice_lines l
  where l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.product_id is not null
    and l.invoice_date >= cutoff
  group by 1, 2, 3, 4;

  get diagnostics n = row_count;
  return n;
end;
$$;

grant execute on function public.refresh_place_month(date) to service_role;

-- ---------------------------------------------------------------------------
-- Maintained with the other summaries
-- ---------------------------------------------------------------------------
create or replace function public.refresh_dashboard_summaries()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.dashboard_health (metric, value, updated_at)
  select 'invoice_lines', count(*)::text, now() from public.dashboard_invoice_lines
  union all
  select 'date_from', coalesce(min(invoice_date)::text, U&'\2014'), now()
    from public.dashboard_invoice_lines
  union all
  select 'date_to', coalesce(max(invoice_date)::text, U&'\2014'), now()
    from public.dashboard_invoice_lines
  union all
  select 'products', count(*)::text, now() from public.dashboard_products
  union all
  select 'stock_rows', count(*)::text, now() from public.dashboard_stock
  union all
  select 'customers', count(*)::text, now() from public.dashboard_customers
  union all
  select 'stock_snapshots', count(distinct snap_date)::text, now()
    from public.dashboard_stock_history
  union all
  select 'brand_fill_pct',
         coalesce(round(100.0 * count(*) filter (where brand is not null) /
                  nullif(count(*), 0))::text, '0'), now()
    from public.dashboard_invoice_lines
  on conflict (metric) do update
    set value = excluded.value, updated_at = excluded.updated_at;

  delete from public.dashboard_filter_options where true;

  insert into public.dashboard_filter_options (kind, value, n, updated_at)
  select 'gov', gov, count(*), now() from public.dashboard_invoice_lines
    where gov is not null group by gov
  union all
  select 'city', city, count(*), now() from public.dashboard_invoice_lines
    where city is not null group by city
  union all
  select 'salesperson', salesperson, count(*), now() from public.dashboard_invoice_lines
    where salesperson is not null group by salesperson
  union all
  select 'category', category, count(*), now() from public.dashboard_invoice_lines
    where category is not null group by category
  union all
  select 'brand', brand, count(*), now() from public.dashboard_invoice_lines
    where brand is not null group by brand;

  update public.dashboard_product_lastsale set units_90d = 0 where true;

  update public.dashboard_product_lastsale t
     set units_90d = v.units
    from (select l.product_id, sum(l.qty) as units
            from public.dashboard_invoice_lines l
           where l.state = 'posted'
             and l.move_type in ('out_invoice', 'out_refund')
             and l.product_id is not null
             and l.invoice_date > current_date - 90
             and l.invoice_date <= current_date
           group by l.product_id) v
   where t.product_id = v.product_id;

  perform public.refresh_filter_scope();
  -- Two months, matching refresh_after_sync's window. A backfill reaching
  -- further back needs a full rebuild: select public.refresh_place_month();
  perform public.refresh_place_month((current_date - interval '2 months')::date);
end;
$$;

grant execute on function public.refresh_dashboard_summaries() to service_role;

-- ---------------------------------------------------------------------------
-- Build it, and show what it costs
-- ---------------------------------------------------------------------------
select public.refresh_place_month() as place_month_rows;

analyze public.dashboard_product_place_month;

select count(*) as rows,
       pg_size_pretty(pg_total_relation_size('public.dashboard_product_place_month'))
         as place_month_size,
       pg_size_pretty(pg_total_relation_size('public.dashboard_invoice_lines'))
         as invoice_lines_size,
       min(month) as earliest,
       max(month) as latest
from public.dashboard_product_place_month;

-- It must agree with the invoice lines it summarises.
select round(sum(revenue)) as place_month_revenue,
       (select round(sum(price_subtotal))
          from public.dashboard_invoice_lines
         where state = 'posted'
           and move_type in ('out_invoice','out_refund')
           and product_id is not null) as invoice_lines_revenue
from public.dashboard_product_place_month;
