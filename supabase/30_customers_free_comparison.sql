-- ===========================================================================
-- 30. Let the user choose what to compare, and over which two periods
-- ===========================================================================
-- The review asked for a comparison the user drives rather than one the page
-- decides. Two things were fixed before:
--
--   the second period was ALWAYS "the same dates one year earlier"
--   the compared number was ALWAYS revenue
--
-- Both are now arguments. The old behaviour is still what happens when nobody
-- touches anything, because same-dates-last-year is the right default: it is
-- the only comparison that is not distorted by the calendar.
--
-- WHY ALL FOUR MEASURES COME BACK AT ONCE rather than the function taking a
-- "which measure" argument. Switching between revenue and units then costs a
-- render instead of a round trip, and the measures are sums over rows already
-- being scanned -- the work is the scan, not the summing. A p_measure argument
-- would have made every switch a fresh 3-second query for numbers already in
-- the browser.
--
-- MASKING IS PER MEASURE, not per period. A role that may not see revenue must
-- not see it in either column, and must still get units and invoices in both,
-- because those are not restricted and a table of dashes would read as "no
-- sales" rather than "not your data".
--
-- The old five- and seven-argument versions are DROPPED, not replaced.
-- Postgres keys a function by its argument list, so leaving them would let a
-- call match more than one and let PostgREST pick -- silently serving a body
-- with no comparison columns and no error anywhere. File 25 hit exactly this.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

drop function if exists public.customers_pareto(date, date, text, text, text);
drop function if exists public.customers_pareto(date, date, text, text, text, text, text);

create or replace function public.customers_pareto(
  p_from        date,
  p_to          date,
  p_gov         text default null,
  p_dept        text default null,
  p_salesperson text default null,
  p_category    text default null,
  p_agency      text default null,
  -- The comparison period. NULL means "these dates, one year earlier", which
  -- is what the page did before and still does until someone changes it.
  p_prev_from   date default null,
  p_prev_to     date default null
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
  growth_pct     numeric
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
  -- Product-level filters force the line table; nothing else does. A
  -- partner-by-month summary knows nothing about which products were on the
  -- invoice, so category and agency cannot be answered from it.
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
  -- Same shape as `cur`, over the comparison window. It now returns margin and
  -- units too, which the previous version did not, because the user can pick
  -- either as the thing being compared.
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
  select c.partner_id,
         coalesce(dc.complete_name, c.partner_id::text),
         dc.governorate,
         -- Still null. "dept" is the customer's SEGMENT -- supermarket,
         -- wholesale, chains -- which lives in Odoo as partner tags
         -- (res.partner.category_id) and is not synced, because the engine
         -- excludes many-to-many fields: a tag link has no column on
         -- res_partner. Filling this is an engine change, not a query change.
         null::text,
         dc.salesperson,
         case when pm.c_revenue then c.revenue end,
         case when pm.c_margin  then c.margin  end,
         c.units,
         c.invoices,
         ls.m,
         case when pm.c_revenue then coalesce(pv.revenue, 0) end,
         case when pm.c_margin  then coalesce(pv.margin,  0) end,
         coalesce(pv.units, 0),
         coalesce(pv.invoices, 0),
         -- Revenue growth, kept for callers that want one ready-made number.
         -- The page computes its own for whichever measure is on screen.
         -- NULL, not 0 and not infinity, when there was nothing to grow from:
         -- a new customer has no growth rate, and printing one invents a
         -- comparison that does not exist.
         case when pm.c_revenue and coalesce(pv.revenue, 0) > 0
              then round(100.0 * (c.revenue - pv.revenue) / pv.revenue, 1)
         end
  from cur c
  cross join perms pm
  left join prev pv                            on pv.partner_id = c.partner_id
  left join last_seen ls                       on ls.partner_id = c.partner_id
  left join public.dashboard_customers dc      on dc.partner_id = c.partner_id
  where (p_gov         is null or dc.governorate = p_gov)
    and (p_salesperson is null or dc.salesperson = p_salesperson)
    and p_dept is null
  order by c.revenue desc nulls last;
$$;

grant execute on function public.customers_pareto(
  date, date, text, text, text, text, text, date, date) to authenticated;

-- Prove both paths: the default comparison, and an explicit one.
select 'default (same dates last year)' as mode, count(*) as customers
from public.customers_pareto(date '2026-01-01', date '2026-08-23');

select 'explicit window' as mode, count(*) as customers
from public.customers_pareto(date '2026-01-01', date '2026-08-23',
                             null, null, null, null, null,
                             date '2024-01-01', date '2024-08-23');
