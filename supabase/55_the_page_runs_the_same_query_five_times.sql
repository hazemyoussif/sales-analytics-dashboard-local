-- ===========================================================================
-- 55. The page is slow to open because it runs the same query five times
-- ===========================================================================
-- Reported as "slow when it opens, sometimes the error, then it works normal".
-- That is not cold-start and it is not the browser. From the production log:
--
--   duration: 10052.349 ms   customers_pareto
--   p_gov: null, p_category: null, p_agency: null ... every filter null
--   $2 = '1000',  $3 = '2000'        <-- LIMIT 1000 OFFSET 2000
--
-- Every filter null. That is the query measured at 285 ms warm. It took ten
-- seconds because it was the THIRD OF FIVE.
--
-- WHY FIVE. PostgREST caps every response at 1000 rows, which api.js documents
-- from measurement: an unpaginated product_facts "silently loses 265 of them
-- and understates revenue by 29%". So rpc() pages, sequentially. customers_pareto
-- returns 4,229 rows -> offsets 0, 1000, 2000, 3000, 4000. And because the
-- function carries its own ORDER BY, OFFSET cannot skip work: each of the five
-- computes and sorts the ENTIRE result set, then throws away all but 1000 rows.
--
-- The page pays the full cost five times, in series. Warm that is 5 x 285 ms
-- and nobody complains. Cold it is five multi-second executions in series, any
-- one of which can reach the 20 s cap -- which is the intermittent error, and
-- why the retry always works.
--
-- FETCHING FEWER ROWS IS NOT AVAILABLE. 1,176 customers are needed to reach the
-- 80% line on this data. A 1000-row cut would truncate the page named 80/20
-- above its own threshold.
--
-- So: make each execution cheap enough that five of them cold is survivable.
--
-- WHERE THE BUFFERS WENT, warm, per execution:
--
--   cur   Index Scan idx_partner_month_month   22,016 rows   4,179 buffers
--   prev  Index Scan idx_partner_month_month   19,626 rows   4,434 buffers
--   klass Seq Scan   dashboard_customer_class   3,382 rows      67 buffers
--                                              ---------------------------
--                                              8,680 of 9,251 = 94%
--
-- idx_partner_month_month covers (month) alone, so all 41,642 rows cost an
-- index entry AND a heap fetch to read partner_id, revenue, margin, units and
-- invoices. As INCLUDE columns both scans become index-only and never touch
-- the heap. klass filters year = 2025 out of 8,993 rows by Seq Scan because
-- the primary key is (partner_id, year), which cannot serve a year-only
-- predicate.
--
-- MEASURED, same call, warm:
--
--                       before      after
--   execution            285 ms     45.8 ms      6.2x
--   buffers              9,251      1,010        9.2x
--   partner_month scan   4,179      209 buffers, Heap Fetches: 0
--   customer_class scan  67         23  buffers, Heap Fetches: 0
--
-- Cold I/O per page load drops ~9x, and that is the number that decides
-- whether the fifth request finishes before the cap.
--
-- VACUUM IS PART OF THE FIX, NOT HOUSEKEEPING. An index-only scan still visits
-- the heap for any page not marked all-visible in the visibility map. This
-- table carried 7,088 dead tuples and had never been explicitly vacuumed, so
-- without the VACUUM the new index reports Heap Fetches and buys nothing.
--
-- An index cannot change an answer; verified anyway, unchanged after:
--   3,506 rows  revenue 17,273,864,054  invoices 35,376
--   A 302 / B 640 / C 2,564   last_purchase non-null on all 3,506
--
-- STILL OPEN, and outside SQL: raising "Max rows" in Supabase -> Settings ->
-- API above 4,229 would collapse five requests into one and is the real fix
-- for the 5x. There is no pgrst.db_max_rows at database or role level, so it
-- cannot be set from a migration.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.
-- ===========================================================================

create index if not exists idx_partner_month_month_covering
  on public.dashboard_partner_month (month)
  include (partner_id, revenue, margin, units, invoices);

create index if not exists idx_customer_class_year
  on public.dashboard_customer_class (year)
  include (partner_id, avg_monthly, cls);

vacuum (analyze) public.dashboard_partner_month;
analyze public.dashboard_customer_class;

-- Expect Index Only Scan on both, and Heap Fetches: 0 on both. A non-zero
-- Heap Fetches means the visibility map is stale -- re-run the VACUUM.
explain (analyze, buffers, costs off, timing off, summary on)
select * from public.customers_pareto('2025-08-15','2026-08-15') limit 1000 offset 2000;
