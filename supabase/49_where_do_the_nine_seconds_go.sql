-- ===========================================================================
-- 49. Diagnostic only -- changes nothing, creates nothing
-- ===========================================================================
-- File 48's indexes did not fix customers_pareto. Measured after building them:
--
--   12mo +category   10,931 ms min   27,540 ms max   (was 6,034 / 18,542)
--   FULL +category    8,946 ms min   21,540 ms max   (was 9,240 / 24,288)
--
-- No better, and the category index is not earning its keep. Two measurements
-- say why:
--
--   date range, category fixed at 205 products
--     1 day 379ms | 30 days 534ms | 12mo 10,426ms | 27mo 9,133ms | FULL 8,475ms
--
--   category size, range fixed at FULL
--     205 products 9,695ms | 28 products 11,344ms | 19 products 8,797ms
--
-- Short ranges are fast, so the date predicate does reach an index. Long ranges
-- plateau at ~9s regardless of how few products the category has -- so past
-- some threshold the planner stops using idx_inv_lines_category_date and reads
-- the table, and the size of the answer stops mattering.
--
-- WHAT I DO NOT KNOW is where those nine seconds go. Two candidates, and from
-- outside the database they look identical:
--
--   1. The scan happens TWICE. cur and prev are separate CTEs over
--      dashboard_invoice_lines, so a comparison period doubles the work.
--   2. count(distinct l.move_id) grouped by partner_id over 739,151 rows.
--      The summary route gets this precomputed as sum(m.invoices); the lines
--      route has to build a distinct set per customer.
--
-- Guessing between them is how file 48 happened. This file asks instead.
--
-- Nothing here creates, alters or drops anything. Run it and paste the output.

-- ---------------------------------------------------------------------------
-- 1. The whole function, worst case, as the page calls it
-- ---------------------------------------------------------------------------
-- Read three things out of this: whether idx_inv_lines_category_date appears
-- at all, how many times dashboard_invoice_lines is scanned, and what the
-- slowest single node is.
explain (analyze, buffers)
select * from public.customers_pareto(
  date '2025-08-24', date '2026-08-24', null, null, null,
  U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1');

-- ---------------------------------------------------------------------------
-- 2. The lines branch on its own, WITH the distinct count
-- ---------------------------------------------------------------------------
-- This is exactly what cur does, lifted out of the function so nothing else
-- can be blamed for its time.
explain (analyze, buffers)
select l.partner_id, sum(l.price_subtotal), sum(l.price_margin),
       sum(l.qty), count(distinct l.move_id)
from public.dashboard_invoice_lines l
where l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
  and l.invoice_date >= date '2025-08-24' and l.invoice_date <= date '2026-08-24'
  and l.category = U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1'
group by l.partner_id;

-- ---------------------------------------------------------------------------
-- 3. The same branch WITHOUT the distinct count
-- ---------------------------------------------------------------------------
-- The only difference from 2 is count(distinct move_id) -> count(*). If this
-- is fast and 2 is slow, the distinct count is the nine seconds and no index
-- will ever help. If both are slow, it is the scan, and the fix is a summary
-- table rather than an index.
explain (analyze, buffers)
select l.partner_id, sum(l.price_subtotal), sum(l.price_margin),
       sum(l.qty), count(*)
from public.dashboard_invoice_lines l
where l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
  and l.invoice_date >= date '2025-08-24' and l.invoice_date <= date '2026-08-24'
  and l.category = U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1'
group by l.partner_id;

-- ---------------------------------------------------------------------------
-- 4. Is the category index used when the range is SHORT?
-- ---------------------------------------------------------------------------
-- 30 days measured at 534 ms. If this shows an index scan and 2 shows a seq
-- scan, that pins the threshold where the planner changes its mind.
explain (analyze, buffers)
select l.partner_id, sum(l.price_subtotal), count(distinct l.move_id)
from public.dashboard_invoice_lines l
where l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
  and l.invoice_date >= date '2026-07-25' and l.invoice_date <= date '2026-08-24'
  and l.category = U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1'
group by l.partner_id;

-- ---------------------------------------------------------------------------
-- 5. How big would a partner x category x month summary be?
-- ---------------------------------------------------------------------------
-- The fix that worked for place filters was file 43: a narrow summary keyed by
-- the thing being filtered. The equivalent here is partner x category x month.
-- Worth building only if it is genuinely smaller than the table it replaces --
-- dashboard_product_place_month is 150,410 rows against 739,151 lines.
select count(*) as partner_category_month_rows,
       (select count(*) from public.dashboard_invoice_lines) as invoice_lines_rows,
       round(100.0 * count(*)
             / (select count(*) from public.dashboard_invoice_lines), 1) as pct_of_lines
from (
  select l.partner_id, l.category, date_trunc('month', l.invoice_date)
  from public.dashboard_invoice_lines l
  where l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
  group by 1, 2, 3
) s;

-- ---------------------------------------------------------------------------
-- 6. And is the count(distinct) even summarisable?
-- ---------------------------------------------------------------------------
-- sum(invoices) over months only equals count(distinct move_id) over the range
-- if no invoice ever spans two months. It cannot -- an invoice has one date --
-- but a customer can have the same move_id counted once per (category, month)
-- group, so summing across CATEGORIES would double count. This checks whether
-- summing across MONTHS alone is safe, which is all the summary route needs.
with src as (
  select l.partner_id, l.move_id, date_trunc('month', l.invoice_date) as mth
  from public.dashboard_invoice_lines l
  where l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
    and l.invoice_date >= date '2026-06-01' and l.invoice_date <= date '2026-08-24'
),
over_range as (
  select partner_id, count(distinct move_id) as n from src group by partner_id
),
by_month as (
  select partner_id, sum(n) as n from (
    select partner_id, mth, count(distinct move_id) as n
    from src group by partner_id, mth
  ) m group by partner_id
)
select count(*) filter (where o.n <> b.n) as partners_where_month_sum_differs,
       count(*)                           as partners_checked
from over_range o join by_month b on b.partner_id = o.partner_id;
