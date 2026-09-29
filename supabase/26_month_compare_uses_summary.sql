-- ===========================================================================
-- 26. The last slow query on the customers page
-- ===========================================================================
-- Measured after file 25:
--
--   customers_pareto            2,376ms   (was ~20,000)
--   customers_pareto + agency   3,781ms
--   revenue_by_month_compare   15,083ms   <-- the remaining lag
--
-- 15 seconds against a 20 second limit for the authenticated role. It works
-- and it is one bad afternoon away from not working.
--
-- The reason is plain: it reads dashboard_invoice_lines TWICE, once for this
-- year and once for last, to produce sixteen numbers. dashboard_partner_month
-- already holds monthly revenue -- 39,973 rows against 739,151 -- and summing
-- it by month gives exactly the same answer.
--
-- Same routing rule as product_facts and customers_pareto: the summary
-- answers the unfiltered case, and the lines answer anything that needs
-- gov, category or agency, because a partner-by-month summary knows nothing
-- about which products were on the invoice or where they went.
--
-- This is the whole reason not to reach for Redis here. The repeated work was
-- never the same query twice -- everyone picks their own dates -- it was
-- recomputing a monthly total from 739,151 rows that had already been
-- computed and stored. A cache in front of that would have made the second
-- viewer fast and left the first one waiting fifteen seconds.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

create or replace function public.revenue_by_month_compare(
  p_from     date,
  p_to       date,
  p_gov      text default null,
  p_category text default null,
  p_agency   text default null
)
returns table (label text, revenue numeric, revenue_prev numeric)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('revenue' = any (h)) as c_revenue
    from (select public.app_my_hidden_columns() as h) z
  ),
  by_line as (
    select p_gov is not null or p_category is not null
        or p_agency is not null as on_
  ),
  months as (
    select generate_series(date_trunc('month', p_from),
                           date_trunc('month', p_to),
                           interval '1 month')::date as m
  ),
  -- This year
  agg as (
    select m.month as m, sum(m.revenue) as v
    from public.dashboard_partner_month m, by_line bl
    where not bl.on_
      and m.month >= date_trunc('month', p_from)::date
      and m.month <= date_trunc('month', p_to)::date
    group by m.month
    union all
    select date_trunc('month', l.invoice_date)::date, sum(l.price_subtotal)
    from public.dashboard_invoice_lines l, by_line bl
    where bl.on_
      and l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_gov      is null or l.gov      = p_gov)
      and (p_category is null or l.category = p_category)
      and (p_agency   is null or l.brand    = p_agency)
    group by 1
  ),
  -- Last year, shifted forward a year so it lines up with the month beside it
  agg_prev as (
    select (m.month + interval '1 year')::date as m, sum(m.revenue) as v
    from public.dashboard_partner_month m, by_line bl
    where not bl.on_
      and m.month >= (date_trunc('month', p_from) - interval '1 year')::date
      and m.month <= (date_trunc('month', p_to)   - interval '1 year')::date
    group by m.month
    union all
    select (date_trunc('month', l.invoice_date) + interval '1 year')::date,
           sum(l.price_subtotal)
    from public.dashboard_invoice_lines l, by_line bl
    where bl.on_
      and l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
      and l.invoice_date >= (p_from - interval '1 year')::date
      and l.invoice_date <= (p_to   - interval '1 year')::date
      and (p_gov      is null or l.gov      = p_gov)
      and (p_category is null or l.category = p_category)
      and (p_agency   is null or l.brand    = p_agency)
    group by 1
  )
  select to_char(mo.m, 'YYYY-MM'),
         case when pm.c_revenue then coalesce(a.v,  0) end,
         case when pm.c_revenue then coalesce(ap.v, 0) end
  from months mo
  cross join perms pm
  left join agg a       on a.m  = mo.m
  left join agg_prev ap on ap.m = mo.m
  order by mo.m;
$$;

grant execute on function public.revenue_by_month_compare(date, date, text, text, text)
  to authenticated;
