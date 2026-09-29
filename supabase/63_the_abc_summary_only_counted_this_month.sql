-- ===========================================================================
-- 63. THE A/B/C SUMMARY ONLY COUNTED CUSTOMERS WHO BOUGHT THIS MONTH
-- ===========================================================================
-- The عملاء ٨٠/٢٠ page has a "الفئات A / B / C" block whose subtitle promises
-- a FIXED 2025 tier -- "التصنيف ثابت ولا يتغيّر بتغيّر الفترة المعروضة". Its
-- counts did not keep that promise.
--
-- The block was built from customers_pareto's rows, and customers_pareto
-- (file 32) only returns the full class population when p_class IS GIVEN.
-- Unfiltered -- which is how the summary calls it -- the roster is `cur`
-- alone: customers with sales in the month on screen. So the summary showed
-- the INTERSECTION of "classified in 2025" and "bought in the shown month",
-- and with the page defaulting to the current month that is roughly:
--
--     shown on the page   A 228   B 462   C 1,204   total ~1,894
--     the real 2025 tier  A 305   B 653   C 2,424   total  3,382
--
-- ~1,450 classified customers were missing from a block whose whole point is
-- that it does not move when the period does.
--
-- File 32 deliberately does NOT add those rows to customers_pareto's default
-- output -- "adding 3,382 zero-revenue rows to the default view would bury the
-- ranking the page exists for" -- and that judgement still holds for the
-- per-customer table. The summary is a different question and gets its own
-- source: three rows straight off dashboard_customer_class, the same
-- precomputed table customers_pareto already reads its class letters from.
--
-- revenue here is the 2025 total (avg_monthly * 12, summed), not this period's
-- sales, so the block finally means one thing top to bottom. Masked with the
-- same 'revenue' hidden-column check as everywhere else: a role that may not
-- see revenue gets the counts and a null money column, not a locked door.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

create or replace function public.customer_class_summary(
  p_year integer default 2025
)
returns table (
  cls       text,
  customers bigint,
  revenue   numeric
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('revenue' = any (h)) as c_revenue
    from (select public.app_my_hidden_columns() as h) z
  )
  select k.cls,
         count(*)::bigint as customers,
         case when bool_and(p.c_revenue)
              then round(sum(k.avg_monthly * 12), 2)
         end as revenue
  from public.dashboard_customer_class k
  cross join perms p
  where k.year = p_year
  group by k.cls
  order by k.cls;
$$;

grant execute on function public.customer_class_summary(integer) to authenticated;

-- Should match dashboard_customer_class for the year, and the "الفئات A / B / C"
-- block on the page should now read the same three numbers whatever month is
-- selected.
select * from public.customer_class_summary(2025);
