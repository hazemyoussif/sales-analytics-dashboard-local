-- ===========================================================================
-- 32. Filtering by class must show the accounts that went quiet
-- ===========================================================================
-- File 31 added the A/B/C filter and I described what it would do wrongly.
-- Measured after running it:
--
--   customer_class(2025) says            305 customers are class A
--   customers_pareto(p_class => 'A')     302 rows
--
-- The three missing ones are class A accounts that bought NOTHING in the
-- selected period. customers_pareto builds from `cur`, which is customers with
-- sales in the window, so a customer with no sales has no row to attach a
-- class to and disappears.
--
-- That is exactly backwards. The reason a fixed tier is worth having is that
-- it does not move when the dates do -- so "show me the A accounts" has to
-- mean all of them, and an A account with a blank period is the single most
-- useful row on the page. It is a million-a-month customer who has stopped
-- buying, and under file 31 it was the one row you could not see.
--
-- Only when p_class IS GIVEN. Unfiltered, the page still lists customers who
-- actually bought: adding 3,382 zero-revenue rows to the default view would
-- bury the ranking the page exists for. Asking for a class is asking about the
-- class, not about this period's activity.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

drop function if exists public.customers_pareto(
  date, date, text, text, text, text, text, date, date, text, integer);

create or replace function public.customers_pareto(
  p_from        date,
  p_to          date,
  p_gov         text default null,
  p_dept        text default null,
  p_salesperson text default null,
  p_category    text default null,
  p_agency      text default null,
  p_prev_from   date default null,
  p_prev_to     date default null,
  p_class       text default null,
  p_class_year  integer default 2025
)
returns table (
  partner_id     bigint,
  customer       text,
  gov            text,
  dept           text,
  salesperson    text,
  revenue        numeric,
  margin         numeric,
  units          numeric,
  invoices       bigint,
  last_purchase  date,
  revenue_prev   numeric,
  margin_prev    numeric,
  units_prev     numeric,
  invoices_prev  bigint,
  growth_pct     numeric,
  cls            text,
  avg_monthly    numeric
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('revenue' = any (h)) as c_revenue,
           not ('margin'  = any (h)) as c_margin
    from (select public.app_my_hidden_columns() as h) z
  ),
  bounds as (
    select p_from as f, p_to as t,
           coalesce(p_prev_from, (p_from - interval '1 year')::date) as pf,
           coalesce(p_prev_to,   (p_to   - interval '1 year')::date) as pt
  ),
  klass as (select * from public.customer_class(p_class_year)),
  by_product as (select p_category is not null or p_agency is not null as on_),
  cur as (
    select m.partner_id, sum(m.revenue) revenue, sum(m.margin) margin,
           sum(m.units) units, sum(m.invoices) invoices
    from public.dashboard_partner_month m, bounds b, by_product bp
    where not bp.on_
      and m.month >= date_trunc('month', b.f)::date
      and m.month <= date_trunc('month', b.t)::date
    group by m.partner_id
    union all
    select l.partner_id, sum(l.price_subtotal), sum(l.price_margin),
           sum(l.qty), count(distinct l.move_id)
    from public.dashboard_invoice_lines l, bounds b, by_product bp
    where bp.on_
      and l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
      and l.invoice_date >= b.f and l.invoice_date <= b.t
      and (p_category is null or l.category = p_category)
      and (p_agency   is null or l.brand    = p_agency)
    group by l.partner_id
  ),
  -- WHO THE PAGE IS ABOUT. Normally the customers who bought in the window.
  -- When a class is asked for, every member of that class as well -- including
  -- the ones with nothing in the window, which is the point of asking.
  roster as (
    select partner_id from cur
    union
    select k.partner_id from klass k
    where p_class is not null and k.cls = p_class
  ),
  prev as (
    select m.partner_id, sum(m.revenue) revenue, sum(m.margin) margin,
           sum(m.units) units, sum(m.invoices) invoices
    from public.dashboard_partner_month m, bounds b, by_product bp
    where not bp.on_
      and m.month >= date_trunc('month', b.pf)::date
      and m.month <= date_trunc('month', b.pt)::date
    group by m.partner_id
    union all
    select l.partner_id, sum(l.price_subtotal), sum(l.price_margin),
           sum(l.qty), count(distinct l.move_id)
    from public.dashboard_invoice_lines l, bounds b, by_product bp
    where bp.on_
      and l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
      and l.invoice_date >= b.pf and l.invoice_date <= b.pt
      and (p_category is null or l.category = p_category)
      and (p_agency   is null or l.brand    = p_agency)
    group by l.partner_id
  ),
  last_seen as (
    select partner_id, max(month) as m
    from public.dashboard_partner_month group by partner_id
  )
  select r.partner_id,
         coalesce(dc.complete_name, r.partner_id::text),
         dc.governorate,
         null::text,
         dc.salesperson,
         -- 0, not NULL, for an account with no sales this period. It bought
         -- nothing; that is a number, and the ±% column needs it to be one.
         case when pm.c_revenue then coalesce(c.revenue, 0) end,
         case when pm.c_margin  then coalesce(c.margin,  0) end,
         coalesce(c.units, 0),
         coalesce(c.invoices, 0),
         ls.m,
         case when pm.c_revenue then coalesce(pv.revenue, 0) end,
         case when pm.c_margin  then coalesce(pv.margin,  0) end,
         coalesce(pv.units, 0),
         coalesce(pv.invoices, 0),
         -- -100% for an account that bought last period and nothing this one.
         -- That is the number this whole change exists to surface, and it is
         -- a real measurement rather than a missing one.
         case when pm.c_revenue and coalesce(pv.revenue, 0) > 0
              then round(100.0 * (coalesce(c.revenue, 0) - pv.revenue) / pv.revenue, 1)
         end,
         coalesce(k.cls, 'C'),
         case when pm.c_revenue then coalesce(k.avg_monthly, 0) end
  from roster r
  cross join perms pm
  left join cur c                              on c.partner_id  = r.partner_id
  left join prev pv                            on pv.partner_id = r.partner_id
  left join last_seen ls                       on ls.partner_id = r.partner_id
  left join public.dashboard_customers dc      on dc.partner_id = r.partner_id
  left join klass k                            on k.partner_id  = r.partner_id
  where (p_gov         is null or dc.governorate = p_gov)
    and (p_salesperson is null or dc.salesperson = p_salesperson)
    and (p_class       is null or coalesce(k.cls, 'C') = p_class)
    and p_dept is null
  order by coalesce(c.revenue, 0) desc nulls last;
$$;

grant execute on function public.customers_pareto(
  date, date, text, text, text, text, text, date, date, text, integer) to authenticated;

-- Should now match customer_class exactly.
select 'class A rows' as check, count(*) as n
from public.customers_pareto(date '2025-08-23', date '2026-08-23', null, null, null, null, null,
                             null, null, 'A')
union all
select 'class A per customer_class', count(*) from public.customer_class(2025) where cls = 'A';

-- The rows this change exists for: big accounts with nothing in the period.
select customer, cls, round(avg_monthly) as avg_monthly_2025, revenue, last_purchase
from public.customers_pareto(date '2025-08-23', date '2026-08-23', null, null, null, null, null,
                             null, null, 'A')
where coalesce(revenue, 0) = 0
order by avg_monthly desc;
