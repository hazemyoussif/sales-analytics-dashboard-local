-- ===========================================================================
-- 31. A/B/C by actual sales volume, not by share of the current view
-- ===========================================================================
-- From the review:
--
--   A : متوسط مبيعات شهرية لعام ٢٠٢٥  ≥ 1,000,000 دينار
--   B : متوسط مبيعات شهرية لعام ٢٠٢٥  400,000 حتى 1,000,000
--   C : متوسط مبيعات شهرية لعام ٢٠٢٥  < 400,000
--
-- THIS IS A DIFFERENT KIND OF CLASS FROM THE ONE IT REPLACES, and the
-- difference matters more than the thresholds do.
--
-- The old A/B/C was Pareto: sort by revenue, A is everyone inside the first
-- 80% of it, B the next 15%, C the tail. That is a share of WHATEVER IS ON
-- SCREEN, so a customer moves between classes when the date filter moves, and
-- two people looking at different periods disagree about who is an A.
--
-- The new one is absolute and fixed to 2025. It does not move when the dates
-- move, which is what makes it usable as a sales tier -- you can put it on a
-- rep's target, and it means the same thing in every conversation.
--
-- The cost is that "class" and "share of this view" are now two different
-- columns on the same table, and they will sometimes disagree in ways that
-- look wrong: a class A customer who bought nothing in the selected period is
-- still class A. That is correct. It is what "this is a big account, and it
-- has gone quiet" looks like, and it is the single most useful row on the page.
--
-- ÷ 12, ALWAYS. Not by the months the customer actually bought in. A customer
-- who bought 6,000,000 once and never again averages 500,000 a month and is a
-- B, not an A. "Monthly average for the year" is a rate, and a customer who
-- buys once a year does not deliver a million a month.
--
-- THE YEAR IS AN ARGUMENT, defaulting to 2025 as specified. Hard-coding it
-- would be a time bomb: in January the thresholds would silently start
-- describing a year everyone had stopped caring about, with nothing on screen
-- to say so.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. The classifier
-- ---------------------------------------------------------------------------
create or replace function public.customer_class(
  p_year      integer default 2025,
  p_a_monthly numeric default 1000000,
  p_b_monthly numeric default 400000
)
returns table (partner_id bigint, avg_monthly numeric, cls text)
language sql
stable
security invoker
as $$
  select m.partner_id,
         round(sum(m.revenue) / 12.0, 2) as avg_monthly,
         case
           when sum(m.revenue) / 12.0 >= p_a_monthly then 'A'
           when sum(m.revenue) / 12.0 >= p_b_monthly then 'B'
           else 'C'
         end
  from public.dashboard_partner_month m
  where m.month >= make_date(p_year, 1, 1)
    and m.month <= make_date(p_year, 12, 1)
  group by m.partner_id;
$$;

grant execute on function public.customer_class(integer, numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. customers_pareto carries the class, and can filter on it
-- ---------------------------------------------------------------------------
-- Dropped rather than replaced, again: Postgres keys a function by its
-- argument list, so an added argument creates a SECOND function that a
-- short call matches equally well, and PostgREST picks one. The page would
-- then get a body with no class column, silently, with no error anywhere.
drop function if exists public.customers_pareto(date, date, text, text, text);
drop function if exists public.customers_pareto(date, date, text, text, text, text, text);
drop function if exists public.customers_pareto(date, date, text, text, text, text, text, date, date);

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
  -- The new filter: 'A', 'B' or 'C'. NULL means every class.
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
         -- Still null: customer SEGMENT lives in Odoo as partner tags and the
         -- engine cannot read many-to-many fields yet.
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
         case when pm.c_revenue and coalesce(pv.revenue, 0) > 0
              then round(100.0 * (c.revenue - pv.revenue) / pv.revenue, 1)
         end,
         -- A customer with no rows at all in the reference year is a C: they
         -- averaged nothing that year. NOT null -- an unclassified row would
         -- vanish from every class filter, and a customer who bought nothing
         -- in 2025 is exactly who a C filter should surface.
         coalesce(k.cls, 'C'),
         -- The number behind the letter, so nobody has to trust the letter.
         -- Masked with revenue: it IS revenue, divided by twelve.
         case when pm.c_revenue then coalesce(k.avg_monthly, 0) end
  from cur c
  cross join perms pm
  left join prev pv                            on pv.partner_id = c.partner_id
  left join last_seen ls                       on ls.partner_id = c.partner_id
  left join public.dashboard_customers dc      on dc.partner_id = c.partner_id
  left join klass k                            on k.partner_id  = c.partner_id
  where (p_gov         is null or dc.governorate = p_gov)
    and (p_salesperson is null or dc.salesperson = p_salesperson)
    and (p_class       is null or coalesce(k.cls, 'C') = p_class)
    and p_dept is null
  order by c.revenue desc nulls last;
$$;

grant execute on function public.customers_pareto(
  date, date, text, text, text, text, text, date, date, text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- What the new tiers actually look like on this database
-- ---------------------------------------------------------------------------
select cls,
       count(*)                              as customers,
       round(min(avg_monthly))               as lowest_monthly,
       round(max(avg_monthly))               as highest_monthly,
       round(sum(avg_monthly * 12))          as total_2025
from public.customer_class(2025)
group by cls
order by cls;
