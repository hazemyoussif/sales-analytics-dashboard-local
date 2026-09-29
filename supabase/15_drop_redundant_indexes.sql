-- ===========================================================================
-- 15. Give the memory back
-- ===========================================================================
-- Files 13 and 14 added roughly 280 MB of index to dashboard_invoice_lines,
-- betting that better access paths would bring the RPCs under the statement
-- timeout. The bet lost, and the measurement afterwards says why:
--
--   data_health, three consecutive runs of the IDENTICAL query:
--     15,599ms, then TIMEOUT, then TIMEOUT
--
-- A trivial aggregate cannot vary like that because of query design. That is
-- a machine short of memory, thrashing. Indexes are not free: every one
-- competes for the same cache, and the table now carries about 400 MB of
-- them. Past a point, adding indexes to a small instance makes everything
-- slower, including the queries they were meant to help.
--
-- So this drops the ones that lost the bet, and the older ones they made
-- redundant. Postgres can use a leading prefix of an index, so a plain index
-- on (product_id) is dead weight beside one on (product_id, invoice_date).
--
-- Run in: Supabase -> SQL Editor. Safe to re-run. Fast.
-- Everything here is recreated by files 01, 13 and 14 if it turns out to be
-- needed after all.

-- ---------------------------------------------------------------------------
-- 1. The three added in 13 and 14, which did not deliver
-- ---------------------------------------------------------------------------
drop index if exists public.idx_inv_lines_agg;           -- 68 MB
drop index if exists public.idx_inv_lines_brand_date;    -- 55 MB
drop index if exists public.idx_inv_lines_partner_date;  -- 49 MB

-- idx_inv_lines_prod_date_cov (107 MB) is KEPT: it is the only one that
-- measurably changed anything, taking agency_customer_matrix from timeout to
-- six seconds and returns_by_product from timeout to eight. It is also the
-- one serving product_facts's two whole-table CTEs.

-- ---------------------------------------------------------------------------
-- 2. Older indexes that are now redundant prefixes
-- ---------------------------------------------------------------------------
-- Each of these duplicates the leading column of a composite index that
-- survives, so the planner can use the wider one wherever it used these.
drop index if exists public.idx_inv_lines_product;       -- prefix of prod_date_cov
drop index if exists public.idx_inv_lines_prod_date;     -- superseded by prod_date_cov
drop index if exists public.idx_inv_lines_posted_date;   -- superseded by prod_date_cov
drop index if exists public.idx_inv_lines_date;          -- prefix of posted_date's shape

analyze public.dashboard_invoice_lines;

-- ---------------------------------------------------------------------------
-- 3. What is left, and what it costs
-- ---------------------------------------------------------------------------
select pg_size_pretty(pg_relation_size('public.dashboard_invoice_lines')) as table_size,
       pg_size_pretty(pg_indexes_size('public.dashboard_invoice_lines'))  as index_size,
       pg_size_pretty(pg_total_relation_size('public.dashboard_invoice_lines')) as total;

select indexname, pg_size_pretty(pg_relation_size(indexname::regclass)) as size
from pg_indexes
where tablename = 'dashboard_invoice_lines'
order by pg_relation_size(indexname::regclass) desc;
