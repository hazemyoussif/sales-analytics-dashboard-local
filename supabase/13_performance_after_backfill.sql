-- ===========================================================================
-- 13. Performance after the history backfill
-- ===========================================================================
-- dashboard_invoice_lines went from 150,970 rows to 739,151 when 2024 and
-- 2025 were finally loaded. Every RPC that reads it then began failing with
-- "canceling statement due to statement timeout" -- Supabase caps the
-- authenticated role at 8 seconds.
--
-- Measured before this file, against the full table:
--
--   data_health             timeout   customer_receivables   1.4s  (new table)
--   filter_options          timeout   branch_stock           1.0s  (new table)
--   product_facts           timeout   discounts_by_product   4.8s
--   customers_pareto        timeout   revenue_adjustments    8.2s  (borderline)
--   agency_lines            timeout
--   agency_customer_matrix  timeout
--   returns_by_product      timeout
--
-- The pattern is exact: everything that scans the invoice lines fails,
-- everything reading a smaller or pre-aggregated table is fine.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run. Takes a minute or two.

-- ---------------------------------------------------------------------------
-- 1. Statistics
-- ---------------------------------------------------------------------------
-- The cheapest possible fix, and quite likely most of it. The last ANALYZE
-- ran when this table held a fifth as many rows, so the planner has been
-- choosing plans for a table that no longer exists -- typically a nested loop
-- where it should now hash-aggregate. Bad statistics produce bad plans far
-- more often than missing indexes do.
analyze public.dashboard_invoice_lines;
analyze public.dashboard_products;
analyze public.dashboard_customers;

-- ---------------------------------------------------------------------------
-- 2. A covering index for the aggregation these RPCs actually run
-- ---------------------------------------------------------------------------
-- Every heavy RPC does the same shape: filter to posted customer documents in
-- a date range, then group by product or partner and sum the money columns.
--
-- The existing partial index carries only (invoice_date, product_id), so the
-- planner must visit the heap for every matching row to read qty and
-- price_subtotal -- 739,151 random heap reads for a full-history query, which
-- is where the eight seconds go.
--
-- INCLUDE puts those columns in the index itself, so the whole aggregation can
-- run as an index-only scan and never touch the table. Partial, so rows that
-- can never match are not stored at all.
create index if not exists idx_inv_lines_agg
  on public.dashboard_invoice_lines (invoice_date)
  include (product_id, partner_id, move_id, qty, price_subtotal,
           price_margin, product_brand_id, product_categ_id)
  where state = 'posted' and move_type in ('out_invoice', 'out_refund');

-- customers_pareto and agency_customer_matrix group by partner first, so they
-- want the partner leading rather than the date.
create index if not exists idx_inv_lines_partner_date
  on public.dashboard_invoice_lines (partner_id, invoice_date)
  include (move_id, qty, price_subtotal, price_margin)
  where state = 'posted' and move_type in ('out_invoice', 'out_refund');

-- agency_lines groups by brand.
create index if not exists idx_inv_lines_brand_date
  on public.dashboard_invoice_lines (product_brand_id, invoice_date)
  include (product_id, partner_id, qty, price_subtotal, price_margin)
  where state = 'posted' and move_type in ('out_invoice', 'out_refund');

analyze public.dashboard_invoice_lines;

-- ---------------------------------------------------------------------------
-- 3. A slightly longer leash
-- ---------------------------------------------------------------------------
-- Not the fix, and deliberately modest. The indexes above should bring these
-- queries well under the original 8 seconds; this only stops a cold cache or
-- an unusually wide date range from showing a user an error instead of a slow
-- page. If anything still needs more than 20 seconds, the answer is a
-- materialised summary table, not a longer timeout.
alter role authenticated set statement_timeout = '20s';

-- ---------------------------------------------------------------------------
-- 4. Confirm
-- ---------------------------------------------------------------------------
select relname as table_name,
       n_live_tup as approx_rows,
       last_analyze,
       last_autoanalyze
from pg_stat_user_tables
where relname = 'dashboard_invoice_lines';

select indexname
from pg_indexes
where tablename = 'dashboard_invoice_lines'
order by indexname;
