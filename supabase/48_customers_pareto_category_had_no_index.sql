-- ===========================================================================
-- 48. Customers 80/20: category and agency had no index either
-- ===========================================================================
-- File 47 fixed product_facts, and Overview went from 19,920 ms to under a
-- second. The same measurement run against customers_pareto:
--
--   range   filter          min        max
--   FULL    none         2,936 ms    4,927 ms
--   FULL    +gov         1,503 ms    1,600 ms   <-- file 40's index
--   FULL    +salesperson   639 ms      866 ms   <-- idx_inv_lines_rep
--   FULL    +category    9,240 ms   24,288 ms   <-- past the 20s cap
--   FULL    +agency      9,686 ms   13,131 ms
--   12mo    +category    6,034 ms   18,542 ms
--
-- customers_pareto cannot take file 47's fix. product_facts is keyed by
-- product, so a category filter there only chooses WHICH PRODUCTS APPEAR and
-- could be pushed onto the 1,431-row catalogue. This function is keyed by
-- CUSTOMER, and "how much did this customer buy OF THIS CATEGORY" genuinely
-- has to read the invoice lines -- there is no customer x category summary.
--
-- So the scan is legitimate. What is not legitimate is that it is a scan.
--
-- dashboard_invoice_lines already has indexes on salesperson, gov, city,
-- partner_id, product_id, invoice_date -- and on product_categ_id and
-- product_brand_id, the ID columns. But this function filters on l.category
-- and l.brand, the denormalised TEXT columns:
--
--     and (p_category is null or l.category = p_category)
--     and (p_agency   is null or l.brand    = p_agency)
--
-- An index on product_categ_id cannot answer a predicate on category. So
-- every one of 739,151 rows was fetched and its Arabic category string
-- compared -- twice, once for the current period and once for the comparison
-- period. That is why +category is slower than no filter at all: the
-- unfiltered path reads dashboard_partner_month, which is small.
--
-- Two indexes, in the same shape as file 40's city index: the filter column
-- first, invoice_date second so the date range is satisfied by the same scan,
-- and partial on the state and move_type every caller already requires.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run. Each one reads the table
-- once to build; a minute or so on this data.

create index if not exists idx_inv_lines_category_date
  on public.dashboard_invoice_lines (category, invoice_date)
  where state = 'posted' and move_type in ('out_invoice', 'out_refund');

create index if not exists idx_inv_lines_brand_date
  on public.dashboard_invoice_lines (brand, invoice_date)
  where state = 'posted' and move_type in ('out_invoice', 'out_refund');

-- And the third one, for Overview rather than for this page.
--
--   Overview 12mo +salesperson    1,059 ms min   12,988 ms max
--   Overview 27mo +salesperson    2,647 ms min   16,158 ms max
--
-- A salesperson filter is the one thing product_facts still has to read the
-- invoice lines for -- unlike category, it changes WHICH SALES COUNT for a
-- product, so file 47 could not push it onto the catalogue.
--
-- idx_inv_lines_rep already exists, but it is (salesperson) alone. Postgres
-- can find the rep's rows with it and then has to fetch every one of them to
-- check invoice_date. That is the spread between 1,059 and 12,988: warm, the
-- rows are in memory; cold, they come off disk.
--
-- (salesperson, invoice_date) satisfies both from the index. The single-column
-- index is left in place -- it is small, and dropping it is a separate
-- decision from adding this one.
create index if not exists idx_inv_lines_rep_date
  on public.dashboard_invoice_lines (salesperson, invoice_date)
  where state = 'posted' and move_type in ('out_invoice', 'out_refund');

analyze public.dashboard_invoice_lines;

-- ---------------------------------------------------------------------------
-- What the plan has to say now
-- ---------------------------------------------------------------------------
-- Expect an Index Scan or Bitmap Index Scan on idx_inv_lines_category_date,
-- and an execution time in the hundreds of milliseconds where it was 24,288.
-- A Seq Scan here means the planner judged the category too common to be worth
-- the index -- read the row estimate before assuming the index is at fault.
explain (analyze, buffers)
select * from public.customers_pareto(
  date '2000-01-01', date '2026-08-24', null, null, null,
  U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1');

-- ---------------------------------------------------------------------------
-- The indexes must not change a single number
-- ---------------------------------------------------------------------------
-- An index cannot change an answer, so this is a regression check rather than
-- a proof: if these disagree, something other than the index moved.
with pareto as (
  select count(*) as customers, round(sum(revenue)) as revenue
  from public.customers_pareto(date '2000-01-01', date '2026-08-24', null, null,
                               null, U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1')
  where revenue is not null
),
direct as (
  select count(distinct l.partner_id) as customers,
         round(sum(l.price_subtotal)) as revenue
  from public.dashboard_invoice_lines l
  where l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
    and l.category = U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1'
    and l.invoice_date >= date '2000-01-01' and l.invoice_date <= date '2026-08-24'
)
select pareto.customers as pareto_customers, direct.customers as direct_customers,
       pareto.revenue   as pareto_revenue,   direct.revenue   as direct_revenue,
       pareto.revenue = direct.revenue as revenue_matches
from pareto, direct;

-- ---------------------------------------------------------------------------
-- What this file deliberately does NOT do
-- ---------------------------------------------------------------------------
-- customers_pareto still guards its dead branches with a cross join:
--
--     from public.dashboard_partner_month m, bounds b, by_product bp
--     where not bp.on_
--
-- That is the exact construct file 46 had to remove from product_facts, where
-- the planner inverted the join and ran a dead branch 392,676 times for
-- fourteen seconds. This function was never converted.
--
-- It is left alone here on purpose. Adding an index cannot change an answer;
-- rewriting five branches can. If the measurements after this file are good,
-- the rewrite is not needed. If they are not, it is the next thing to do, on
-- its own, so the effect can be attributed.
