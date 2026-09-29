-- ===========================================================================
-- 72. The A/B/C summary follows the who-is-counted filters
-- ===========================================================================
-- The block stays the FIXED 2025 tier -- the letter never moves with the shown
-- month -- but the COUNTS now respond to the segment / governorate / rep
-- filters on the page. Pick القسم = ماركتات and the block shows that segment's
-- A/B/C split (79 / 215 / 874 instead of 305 / 653 / 2,424).
--
-- customer_class_summary gains p_gov / p_salesperson / p_title, applied through
-- a left join to dashboard_customers. Signature change, so drop + recreate;
-- the only caller is customers.js.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

drop function if exists public.customer_class_summary(integer);

create or replace function public.customer_class_summary(
  p_year        integer default 2025,
  p_gov         text    default null,
  p_salesperson text    default null,
  p_title       text    default null
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
  left join public.dashboard_customers dc on dc.partner_id = k.partner_id
  where k.year = p_year
    and (p_gov         is null or dc.governorate = p_gov)
    and (p_salesperson is null or dc.salesperson = p_salesperson)
    and (p_title       is null or dc.title       = p_title)
  group by k.cls
  order by k.cls;
$$;

grant execute on function public.customer_class_summary(integer, text, text, text) to authenticated;

select * from public.customer_class_summary(2025);
