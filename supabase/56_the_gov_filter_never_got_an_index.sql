-- ===========================================================================
-- 56. Every timeout in the logs is Overview, and gov never got file 40's index
-- ===========================================================================
-- File 55 blamed customers_pareto's five-page fetch. That is a real cost and
-- worth the fix, but it is NOT what users are seeing. The PostgREST access log
-- names the failing endpoint, and it is the same one every time:
--
--   09:10:37  POST /rpc/overview_facts  500  57014 canceling statement...
--   08:43:38  POST /rpc/overview_facts  500  57014
--   08:36:30  POST /rpc/overview_facts  500  57014
--   10:16:22  POST /rpc/overview_facts  500  57014
--   10:15:42  POST /rpc/overview_facts  500  57014
--
-- Not one customers_pareto. And overview_facts is called with paginate:false
-- (api.js), so the 1000-row cap and the five-page loop have nothing to do with
-- the error at all.
--
-- WHAT ACTUALLY FAILS. product_facts computes velocity_90d. File 45 gave it a
-- cached figure, but use_cached is switched off whenever ANY of p_salesperson,
-- p_customer, p_gov or p_city is set -- correctly, because a global rate cannot
-- answer "how fast does this sell in Baghdad". So a gov filter falls back to
-- the invoice lines for the trailing 90 days:
--
--   Index Scan using idx_inv_lines_dt   rows=24296
--     Index Cond: invoice_date > '2026-05-17'      <-- DATE ONLY
--     Rows Removed by Filter: 44177                <-- 64% discarded on gov
--
-- 68,473 rows fetched from a 348 MB table to keep 24,296, with the governorate
-- applied as a filter rather than as an index condition. Warm that is
-- affordable. Cold it is tens of thousands of scattered heap reads, and it was
-- measured from the log at 16,380 ms against a 20 s cap.
--
-- THIS IS FILE 40 ALL OVER AGAIN. File 40 is titled "the city filter had no
-- index" and added (city, invoice_date). The table now carries date-composite
-- indexes for city, brand, category, salesperson, product and partner:
--
--   idx_inv_lines_city_date      idx_inv_lines_pd
--   idx_inv_lines_brand_date     idx_inv_lines_pt
--   idx_inv_lines_category_date  idx_inv_lines_rep_date
--
-- and none for gov -- which is the filter the Overview page offers first and
-- the one most people actually click. City got an index; the governorate above
-- it never did.
--
-- MEASURED, same call, warm best-of-three:
--
--                        before     after
--   p_gov = بغداد        2,332 ms   91 ms
--   no filter (ref)        228 ms   75 ms
--   rows discarded        44,177    0
--
-- The gov filter now costs about what no filter costs. Cold, the scan touches
-- only the pages it needs instead of three times as many.
--
-- An index cannot change an answer; verified anyway, unchanged after:
--   revenue 5,959,213,281  units 181,455.57  sold 840
--   unsold 34 / 6,933,101  top 200 rows  59 categories
--
-- BUILT CONCURRENTLY. This table is 348 MB and a plain CREATE INDEX holds
-- ACCESS EXCLUSIVE for the duration, which would block every dashboard read
-- while it ran. CONCURRENTLY cannot run inside a transaction block -- if your
-- migration runner wraps files, run this one outside it.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.
-- ===========================================================================

create index concurrently if not exists idx_inv_lines_gov_date
  on public.dashboard_invoice_lines (gov, invoice_date)
  where state = 'posted' and move_type in ('out_invoice', 'out_refund');

analyze public.dashboard_invoice_lines;

-- Expect a Bitmap Heap Scan on idx_inv_lines_gov_date and NO "Rows Removed by
-- Filter" for the governorate. If gov still appears as a Filter rather than an
-- Index Cond, the planner judged it non-selective -- read the row estimate
-- before assuming the index is at fault.
explain (analyze, buffers, costs off, timing off, summary on)
select * from public.overview_facts(
  '2025-08-15','2026-08-15', null, U&'\0628\063A\062F\0627\062F (IQ)',
  null, null, null, null, 90, 200, 50);
