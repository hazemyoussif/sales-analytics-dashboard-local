-- ===========================================================================
-- 40. The city filter had no index, and the page asks for it twice
-- ===========================================================================
-- Measured signed in as a real user -- role `authenticated`, RLS applied, 20
-- second statement cap -- rather than as service_role, which skips RLS and
-- gets 300 seconds. That difference is why every earlier measurement looked
-- healthy while users were timing out.
--
--   product_facts                1,390 ms
--   product_facts + gov          1,190 ms
--   product_facts + city         8,692 ms   <-- seven times gov
--
-- gov has an index (idx_inv_lines_gov). city has never had one, because until
-- file 38 nothing filtered by it. So the gov filter narrows through an index
-- and the city filter scans the whole date range -- around 370,000 rows for a
-- twelve month window -- testing every one.
--
-- AND THE PAGE ASKS TWICE. PostgREST caps a response at 1000 rows, there are
-- ~1,296 products, so api.js pages: two requests, each re-running the whole
-- function. 8.7s becomes roughly 17.4s against a 20s cap. That is not close to
-- the limit, that IS the limit, and it is exactly the report:
-- "I tried to select city and got canceling statement due to statement
-- timeout".
--
-- Partial, matching the queries. Every path that filters by city also carries
-- state = 'posted' and move_type in ('out_invoice','out_refund'), so the index
-- only needs those rows -- smaller to build, smaller to keep, and still used.
-- The same reasoning file 14 applied to the product/date index.
--
-- city second in (city, invoice_date): the city is an equality test and the
-- date is a range, and a btree can only range-scan after the equality columns
-- are pinned. The other order would make this index nearly useless here.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run. Building it reads the table
-- once; a minute or so on this data.

create index if not exists idx_inv_lines_city_date
  on public.dashboard_invoice_lines (city, invoice_date)
  where state = 'posted' and move_type in ('out_invoice', 'out_refund');

analyze public.dashboard_invoice_lines;

-- Was 8,692 ms for a real user. The plan should now show an index scan on
-- idx_inv_lines_city_date rather than a scan of the whole date range.
explain (analyze, buffers)
select * from public.product_facts(
  date '2025-08-23', date '2026-08-23',
  null, null, null, null, null,
  U&'\0623\0631\0628\064A\0644');
