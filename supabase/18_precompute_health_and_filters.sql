-- ===========================================================================
-- 18. data_health and filter_options, precomputed
-- ===========================================================================
-- With product_facts fixed (file 16), these two are what still breaks pages.
-- Measured just now at the 12-month default:
--
--   data_health          TIMEOUT        product_facts        14.3s  OK
--   filter_options       TIMEOUT        revenue_adjustments   1.8s  OK
--                                       branch_stock          0.8s  OK
--
-- Both run on EVERY page -- boot() calls dataHealth() before anything else --
-- so a timeout in either takes the whole page down regardless of what else
-- works. That is why overview is dead while product_facts is healthy.
--
-- Neither is date-scoped, and that is the whole problem:
--
--   data_health     count(*) over 739,151 rows, plus min/max, plus a
--                   filtered count for brand fill
--   filter_options  FOUR separate full scans -- gov, salesperson, category,
--                   brand -- roughly 3,000,000 rows processed to return
--                   about 200
--
-- And every answer is identical for every viewer. Computing them per page
-- load is the same mistake lastsale was: real work, endlessly repeated.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run. The refresh at the bottom
-- does the expensive scans ONCE, here, where the timeout is the editor's.

-- ---------------------------------------------------------------------------
-- 1. Two small tables
-- ---------------------------------------------------------------------------
create table if not exists public.dashboard_health (
  metric     text primary key,
  value      text,
  updated_at timestamptz not null default now()
);

create table if not exists public.dashboard_filter_options (
  kind       text   not null,
  value      text   not null,
  n          bigint not null,
  updated_at timestamptz not null default now(),
  primary key (kind, value)
);

alter table public.dashboard_health         enable row level security;
alter table public.dashboard_filter_options enable row level security;

drop policy if exists health_read  on public.dashboard_health;
drop policy if exists filters_read on public.dashboard_filter_options;

create policy health_read  on public.dashboard_health
  for select to authenticated using (true);
create policy filters_read on public.dashboard_filter_options
  for select to authenticated using (true);

grant select on public.dashboard_health         to authenticated;
grant select on public.dashboard_filter_options to authenticated;

-- ---------------------------------------------------------------------------
-- 2. One function that does the expensive work, on purpose and rarely
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER so the sync can call it without needing table privileges,
-- and so it is not subject to the authenticated role's short timeout.
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
  select 'date_from', coalesce(min(invoice_date)::text, '—'), now()
    from public.dashboard_invoice_lines
  union all
  select 'date_to', coalesce(max(invoice_date)::text, '—'), now()
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

  -- Rebuilt wholesale rather than upserted: a governorate or brand that
  -- stops appearing must disappear from the filter bar, and an upsert can
  -- never remove anything. Same rule the invoice backfill needed --replace
  -- for, and for the same reason.
  delete from public.dashboard_filter_options;

  insert into public.dashboard_filter_options (kind, value, n, updated_at)
  select 'gov', gov, count(*), now() from public.dashboard_invoice_lines
    where gov is not null group by gov
  union all
  select 'salesperson', salesperson, count(*), now() from public.dashboard_invoice_lines
    where salesperson is not null group by salesperson
  union all
  select 'category', category, count(*), now() from public.dashboard_invoice_lines
    where category is not null group by category
  union all
  select 'brand', brand, count(*), now() from public.dashboard_invoice_lines
    where brand is not null group by brand;
end;
$$;

grant execute on function public.refresh_dashboard_summaries() to service_role;

-- ---------------------------------------------------------------------------
-- 3. The two RPCs, now reading a few hundred rows instead of millions
-- ---------------------------------------------------------------------------
-- Same names, same signatures, same output shape. Nothing in the front end
-- changes -- api.js still maps metric/value pairs into an object and groups
-- filter options by kind.
create or replace function public.data_health()
returns table (metric text, value text)
language sql
stable
security invoker
as $$
  select metric, value from public.dashboard_health;
$$;

create or replace function public.filter_options()
returns table (kind text, value text, n bigint)
language sql
stable
security invoker
as $$
  select kind, value, n
  from public.dashboard_filter_options
  order by kind, n desc;
$$;

grant execute on function public.data_health()    to authenticated;
grant execute on function public.filter_options() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Fill them now
-- ---------------------------------------------------------------------------
select public.refresh_dashboard_summaries();

analyze public.dashboard_health;
analyze public.dashboard_filter_options;

select * from public.dashboard_health order by metric;

select kind, count(*) as options
from public.dashboard_filter_options
group by kind order by kind;

-- ---------------------------------------------------------------------------
-- Keeping them current
-- ---------------------------------------------------------------------------
-- These are now as fresh as the last refresh, not as fresh as the data. Call
-- refresh_dashboard_summaries() after each sync run -- it is one statement,
-- and the sync already holds the service_role key:
--
--   POST {SUPABASE_URL}/rest/v1/rpc/refresh_dashboard_summaries
--
-- Stale filter options are harmless (an option appears or disappears a day
-- late). A stale date_to is not entirely harmless: safePeriod uses it as the
-- default range end, so if this stops being refreshed the dashboard quietly
-- stops advancing its own "today".
