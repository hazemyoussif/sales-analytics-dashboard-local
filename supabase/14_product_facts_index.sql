-- ===========================================================================
-- 14. The index product_facts actually needs
-- ===========================================================================
-- File 13 helped the date-range queries (data_health went from timeout to
-- 4.7s) but product_facts still timed out, and the measurement said why:
--
--   product_facts, 1 month  : timeout
--   product_facts, 3 months : timeout
--   product_facts, 1 year   : timeout
--   product_facts, everything: timeout
--
-- Identical at every range. So it was never about how much data the filter
-- selects -- two of its CTEs deliberately ignore the date range entirely:
--
--   lastsale       max(invoice_date) per product, over ALL history, because
--                  "days idle" means since the product last sold AT ALL, not
--                  since it last sold this month
--   latest_labels  distinct on (product_id) ... order by invoice_date desc,
--                  to label a product with its most recent category/brand
--
-- Both are correct and both scan the whole table however narrow the filter.
-- latest_labels is the expensive one: DISTINCT ON must SORT 739,151 rows by
-- (product_id, invoice_date desc), and then visit the heap for every one of
-- them because category and brand are not in any index.
--
-- idx_inv_lines_prod_date is close but cannot serve it: not partial, so it
-- carries rows that can never match, and it stops at (product_id,
-- invoice_date) with no included columns.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run. A minute or two.

-- The order matters: (product_id, invoice_date DESC) is exactly what
-- DISTINCT ON ... ORDER BY product_id, invoice_date DESC wants, so the sort
-- disappears entirely -- the index is already in that order. INCLUDE carries
-- everything the four CTEs read, so none of them touch the table at all.
create index if not exists idx_inv_lines_prod_date_cov
  on public.dashboard_invoice_lines (product_id, invoice_date desc)
  include (category, brand, qty, price_subtotal, price_margin,
           partner_id, move_id, gov)
  where state = 'posted' and move_type in ('out_invoice', 'out_refund');

analyze public.dashboard_invoice_lines;

-- ---------------------------------------------------------------------------
-- If this is still not enough
-- ---------------------------------------------------------------------------
-- Then the answer is pre-aggregation, not another index, and it should be
-- said plainly rather than guessed at a third time.
--
-- These RPCs recompute sums over 739,151 rows on every page load, and that
-- number only grows. A summary table of product x month -- roughly 1,245
-- products across 27 months, so about 33,000 rows -- answers the same
-- questions from a table twenty times smaller, and the sync can maintain it
-- on the same schedule it maintains everything else.
--
-- That is a real change: the RPCs would be rewritten against the summary, and
-- anything needing line-level detail would keep reading the full table. It is
-- the normal shape for a dashboard over a growing fact table, and it stops
-- this problem returning every time the data doubles.

select indexname, pg_size_pretty(pg_relation_size(indexname::regclass)) as size
from pg_indexes
where tablename = 'dashboard_invoice_lines'
order by pg_relation_size(indexname::regclass) desc;
