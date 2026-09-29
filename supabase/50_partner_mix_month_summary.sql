-- ===========================================================================
-- 50. Customers 80/20: a summary for the filters that still scan
-- ===========================================================================
-- customers_pareto, signed in as a real user, after files 47 and 48:
--
--   filter          min         max
--   none          2,405 ms    4,671 ms
--   +gov          1,263 ms    1,594 ms   <-- file 40's index
--   +salesperson    582 ms      804 ms   <-- dashboard_partner_month
--   +category    10,931 ms   27,540 ms   <-- past the 20s cap
--   +agency       6,144 ms   15,880 ms
--
-- File 47's trick does not work here. product_facts is keyed by PRODUCT, so a
-- category filter there only chooses which products appear and could be pushed
-- onto the 1,431-row catalogue. This function is keyed by CUSTOMER, and "how
-- much did this customer buy of this category" genuinely has to read the lines.
--
-- File 48's indexes did not work either. Measured after building them:
--
--   date range, category fixed
--     1 day 379ms | 30 days 534ms | 12mo 10,426ms | 27mo 9,133ms | FULL 8,475ms
--   category size, range fixed at FULL
--     205 products 9,695ms | 28 products 11,344ms | 19 products 8,797ms
--
-- Short ranges use the index; long ranges plateau at ~9s no matter how small
-- the category. Past some threshold the planner stops using
-- idx_inv_lines_category_date and reads the table, and then the size of the
-- answer stops mattering. An index cannot fix a query whose cost is the scan.
--
-- So this gets what place filters got in file 43: a narrow summary keyed by the
-- thing being filtered. Measured before building it:
--
--   partner x category x month   198,196 rows   26.8% of the invoice lines
--
-- against dashboard_product_place_month's 150,410.
--
-- WHY (partner, kind, value, month) AND NOT (partner, category, brand, month)
--
-- revenue, margin and units are additive: summing them across any axis is
-- correct. invoices is a COUNT DISTINCT and is not. Key the table by category
-- AND brand together and a category-only filter has to sum across brands --
-- so an invoice holding two brands of the same category gets counted twice.
-- A brand-only filter has the mirror problem. A single combined key is wrong
-- for both of the common cases and exact only for the rare one.
--
-- Two rows per line instead -- one under kind='category', one under
-- kind='brand' -- and each filter reads only its own kind. Then the only axis
-- ever summed over is MONTH, which is the axis that was checked:
--
--   count(distinct move_id) over a range equals the sum of the per-month
--   counts for 2,311 of 2,311 partners. An invoice has one date, so it cannot
--   straddle two months.
--
-- The cost is that p_category and p_agency TOGETHER cannot be answered from
-- this table -- that combination still reads the lines, correctly and slowly.
-- File 51 must keep that fallback rather than pretend the summary covers it.
--
-- NULL CATEGORY AND BRAND BECOME '' IN THE KEY, as in file 43: a primary key
-- cannot hold nulls, and a line with no brand still has revenue that has to
-- appear in a total. Empty string is a real group here, not a missing one.
--
-- This file only BUILDS and MAINTAINS the table. Routing customers_pareto
-- through it is file 51 -- the same split as 43 and 44, which is what made
-- file 44 recoverable when it turned out to be wrong.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run. The build scans the invoice
-- lines twice, once per kind.

create table if not exists public.dashboard_partner_mix_month (
  partner_id bigint  not null,
  kind       text    not null,          -- 'category' or 'brand'
  value      text    not null,          -- the category name, or the brand name
  month      date    not null,
  units      numeric not null default 0,
  revenue    numeric not null default 0,
  margin     numeric,
  invoices   bigint  not null default 0,
  updated_at timestamptz not null default now(),
  primary key (partner_id, kind, value, month),
  constraint dashboard_partner_mix_month_kind check (kind in ('category', 'brand'))
);

create index if not exists idx_pmm_kind_value_month
  on public.dashboard_partner_mix_month (kind, value, month);
create index if not exists idx_pmm_partner
  on public.dashboard_partner_mix_month (partner_id);

alter table public.dashboard_partner_mix_month enable row level security;
drop policy if exists pmm_read on public.dashboard_partner_mix_month;
create policy pmm_read on public.dashboard_partner_mix_month
  for select to authenticated using (true);
grant select on public.dashboard_partner_mix_month to authenticated;

create or replace function public.refresh_partner_mix_month(
  p_since date default null)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  n bigint;
  -- date_trunc for the reason file 27 documents: the delete compares against a
  -- column that only holds month starts, so a mid-month cutoff leaves the
  -- oldest month behind and the insert then collides with it. That bug only
  -- ever showed itself on the first of a month.
  cutoff date := date_trunc('month', coalesce(p_since, date '1900-01-01'))::date;
begin
  delete from public.dashboard_partner_mix_month where month >= cutoff;

  -- Two passes over the same window, one per dimension. Each row counts its
  -- own invoices independently, so neither pass can contaminate the other.
  insert into public.dashboard_partner_mix_month
    (partner_id, kind, value, month, units, revenue, margin, invoices, updated_at)
  select l.partner_id, 'category', coalesce(l.category, ''),
         date_trunc('month', l.invoice_date)::date,
         sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
         count(distinct l.move_id), now()
  from public.dashboard_invoice_lines l
  where l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.partner_id is not null
    and l.invoice_date >= cutoff
  group by 1, 2, 3, 4;

  insert into public.dashboard_partner_mix_month
    (partner_id, kind, value, month, units, revenue, margin, invoices, updated_at)
  select l.partner_id, 'brand', coalesce(l.brand, ''),
         date_trunc('month', l.invoice_date)::date,
         sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
         count(distinct l.move_id), now()
  from public.dashboard_invoice_lines l
  where l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.partner_id is not null
    and l.invoice_date >= cutoff
  group by 1, 2, 3, 4;

  select count(*) into n
  from public.dashboard_partner_mix_month where month >= cutoff;
  return n;
end;
$fn$;

grant execute on function public.refresh_partner_mix_month(date) to service_role;

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
  -- Same two-month window, same caveat: a backfill reaching further back
  -- needs a full rebuild via select public.refresh_partner_mix_month();
  perform public.refresh_partner_mix_month((current_date - interval '2 months')::date);
end;
$$;
grant execute on function public.refresh_dashboard_summaries() to service_role;

-- ---------------------------------------------------------------------------
-- Build it, and show what it actually cost
-- ---------------------------------------------------------------------------
select public.refresh_partner_mix_month() as partner_mix_month_rows;

analyze public.dashboard_partner_mix_month;

-- category was estimated at 198,196 rows. brand is the unknown -- there are
-- 182 brands against 56 categories, so it will be larger. If the TOTAL lands
-- much above ~500,000, file 51 is a worse trade than it looks and is worth
-- reconsidering before it is run.
select kind, count(*) as rows,
       round(100.0 * count(*)
             / (select count(*) from public.dashboard_invoice_lines), 1) as pct_of_lines
from public.dashboard_partner_mix_month
group by kind
union all
select 'TOTAL', count(*),
       round(100.0 * count(*)
             / (select count(*) from public.dashboard_invoice_lines), 1)
from public.dashboard_partner_mix_month;

select pg_size_pretty(pg_total_relation_size(
         'public.dashboard_partner_mix_month')) as summary_size,
       pg_size_pretty(pg_total_relation_size(
         'public.dashboard_invoice_lines')) as invoice_lines_size,
       min(month) as earliest, max(month) as latest
from public.dashboard_partner_mix_month;

-- ---------------------------------------------------------------------------
-- It must agree with the invoice lines it summarises
-- ---------------------------------------------------------------------------
-- Each kind independently covers every line, so each kind's revenue must equal
-- the whole. If they disagree, a line was dropped or double counted.
select kind,
       round(sum(revenue)) as summary_revenue,
       (select round(sum(price_subtotal))
          from public.dashboard_invoice_lines
         where state = 'posted' and move_type in ('out_invoice','out_refund')
           and partner_id is not null) as lines_revenue,
       round(sum(revenue)) =
       (select round(sum(price_subtotal))
          from public.dashboard_invoice_lines
         where state = 'posted' and move_type in ('out_invoice','out_refund')
           and partner_id is not null) as revenue_matches
from public.dashboard_partner_mix_month
group by kind;

-- And one category, read the way file 51 will read it: filter to one value,
-- sum over months only.
with summary as (
  select sum(revenue) as revenue, sum(units) as units,
         count(distinct partner_id) as customers, sum(invoices) as invoices
  from public.dashboard_partner_mix_month
  where kind = 'category'
    and value = U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1'
),
lines as (
  select sum(price_subtotal) as revenue, sum(qty) as units,
         count(distinct partner_id) as customers,
         count(distinct move_id) as invoices
  from public.dashboard_invoice_lines
  where state = 'posted' and move_type in ('out_invoice','out_refund')
    and partner_id is not null
    and category = U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1'
)
select round(summary.revenue) as summary_revenue,
       round(lines.revenue)   as lines_revenue,
       round(summary.revenue) = round(lines.revenue) as revenue_matches,
       summary.customers      as summary_customers,
       lines.customers        as lines_customers,
       summary.customers = lines.customers as customers_match,
       summary.invoices       as summary_invoices,
       lines.invoices         as lines_invoices,
       summary.invoices = lines.invoices  as invoices_match
from summary, lines;
