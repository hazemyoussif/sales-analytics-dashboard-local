-- ===========================================================================
-- 25. The customers page: agency/category filters, and 2025 beside 2026
-- ===========================================================================
-- Three things asked for in the review:
--
--   1. filters at the top for AGENCY (التوكيل) and PRODUCT CATEGORY
--   2. the same period LAST YEAR beside this year in the customers table, so
--      every row is a comparison rather than a single number
--   3. the big concentration curve replaced -- "مش مفيد خالص"
--
-- (2) is why this file starts with a summary table rather than a rewrite.
-- customers_pareto already takes about 20 seconds: it groups 739,151 invoice
-- lines by partner with a count(distinct move_id). Asking it for a second
-- year as well would double that and put it back over the timeout, so the
-- honest order of work is to make it cheap first and add the feature second.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. partner x month -- the customers equivalent of dashboard_product_month
-- ---------------------------------------------------------------------------
create table if not exists public.dashboard_partner_month (
  partner_id bigint  not null,
  month      date    not null,
  revenue    numeric not null default 0,
  margin     numeric,
  units      numeric not null default 0,
  invoices   bigint  not null default 0,
  updated_at timestamptz not null default now(),
  primary key (partner_id, month)
);

create index if not exists idx_partner_month_month
  on public.dashboard_partner_month (month);

alter table public.dashboard_partner_month enable row level security;
drop policy if exists partner_month_read on public.dashboard_partner_month;
create policy partner_month_read on public.dashboard_partner_month
  for select to authenticated using (true);
grant select on public.dashboard_partner_month to authenticated;

create or replace function public.refresh_partner_month(p_since date default null)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  n bigint;
  cutoff date := coalesce(p_since, date '1900-01-01');
begin
  delete from public.dashboard_partner_month where month >= cutoff;

  insert into public.dashboard_partner_month
    (partner_id, month, revenue, margin, units, invoices, updated_at)
  select l.partner_id,
         date_trunc('month', l.invoice_date)::date,
         sum(l.price_subtotal), sum(l.price_margin), sum(l.qty),
         count(distinct l.move_id), now()
  from public.dashboard_invoice_lines l
  where l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.partner_id is not null
    and l.invoice_date >= cutoff
  group by 1, 2;

  get diagnostics n = row_count;
  return n;
end;
$$;

grant execute on function public.refresh_partner_month(date) to service_role;

-- ---------------------------------------------------------------------------
-- 2. customers_pareto -- with last year alongside
-- ---------------------------------------------------------------------------
-- The old five-argument version must be DROPPED, not replaced. Postgres keys
-- a function by its argument list, so (date,date,text,text,text) and
-- (date,date,text,text,text,text,text) are two different functions and both
-- would exist. With every new argument defaulting to null, a five-argument
-- call then matches BOTH, and PostgREST picks one -- so the page could get
-- the old body, silently, with no year-on-year columns and no error anywhere.
--
-- An error is a good outcome here. Two functions quietly answering to the
-- same name is not.
drop function if exists public.customers_pareto(date, date, text, text, text);

-- The prior period is the SAME dates shifted back one year, not "last
-- calendar year". Comparing Jan-Aug 2026 against all of 2025 would show every
-- customer collapsing, which is a property of the calendar rather than the
-- business.
--
-- p_agency and p_category are new. Both describe the PRODUCTS a customer
-- bought, so they cannot come from the partner summary -- they need the
-- invoice lines, which is why filtering on either falls back to the slower
-- path. Unfiltered, and filtered by gov/rep, still use the summary.
create or replace function public.customers_pareto(
  p_from        date,
  p_to          date,
  p_gov         text default null,
  p_dept        text default null,
  p_salesperson text default null,
  p_category    text default null,
  p_agency      text default null
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
           (p_from - interval '1 year')::date as pf,
           (p_to   - interval '1 year')::date as pt
  ),
  -- Product-level filters force the line table; nothing else does.
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
    select m.partner_id, sum(m.revenue) revenue, sum(m.invoices) invoices
    from public.dashboard_partner_month m, bounds b, by_product bp
    where not bp.on_
      and m.month >= date_trunc('month', b.pf)::date
      and m.month <= date_trunc('month', b.pt)::date
    group by m.partner_id
    union all
    select l.partner_id, sum(l.price_subtotal), count(distinct l.move_id)
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
         -- Still null: "dept" is the Odoo sales TEAM, whose id is synced but
         -- whose label was dropped at sync time. Fixable, and not part of
         -- this change.
         null::text,
         dc.salesperson,
         case when pm.c_revenue then c.revenue end,
         case when pm.c_margin  then c.margin  end,
         c.units,
         c.invoices,
         ls.m,
         case when pm.c_revenue then coalesce(pv.revenue, 0) end,
         coalesce(pv.invoices, 0),
         -- Growth against the same period last year. NULL, not 0 and not
         -- infinity, when there was nothing last year to grow from: a new
         -- customer has no growth rate, and printing one would invent a
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

grant execute on function public.customers_pareto(date, date, text, text, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3. The replacement chart: this year against last, month by month
-- ---------------------------------------------------------------------------
-- The concentration curve showed the SHAPE of the customer base, which does
-- not change much and cannot be acted on. This answers "are we ahead of last
-- year", which is what the rest of the review was asking for.
--
-- Months are labelled by the CURRENT year's month, with the prior year's same
-- month beside it, so the two align even though they are a year apart.
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
  months as (
    select generate_series(date_trunc('month', p_from),
                           date_trunc('month', p_to),
                           interval '1 month')::date as m
  ),
  agg as (
    select date_trunc('month', l.invoice_date)::date as m,
           sum(l.price_subtotal) filter (
             where l.invoice_date >= p_from and l.invoice_date <= p_to) as cur
    from public.dashboard_invoice_lines l
    where l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_gov      is null or l.gov      = p_gov)
      and (p_category is null or l.category = p_category)
      and (p_agency   is null or l.brand    = p_agency)
    group by 1
  ),
  agg_prev as (
    select (date_trunc('month', l.invoice_date) + interval '1 year')::date as m,
           sum(l.price_subtotal) as prev
    from public.dashboard_invoice_lines l
    where l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
      and l.invoice_date >= (p_from - interval '1 year')::date
      and l.invoice_date <= (p_to   - interval '1 year')::date
      and (p_gov      is null or l.gov      = p_gov)
      and (p_category is null or l.category = p_category)
      and (p_agency   is null or l.brand    = p_agency)
    group by 1
  )
  select to_char(mo.m, 'YYYY-MM'),
         case when pm.c_revenue then coalesce(a.cur, 0) end,
         case when pm.c_revenue then coalesce(ap.prev, 0) end
  from months mo
  cross join perms pm
  left join agg a       on a.m  = mo.m
  left join agg_prev ap on ap.m = mo.m
  order by mo.m;
$$;

grant execute on function public.revenue_by_month_compare(date, date, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Build the summary now, and fold it into the post-sync refresh
-- ---------------------------------------------------------------------------
-- File 24 created this returning three columns; it now returns four, and
-- CREATE OR REPLACE cannot change a function's OUT parameters:
--   42P13: cannot change return type of existing function
drop function if exists public.refresh_after_sync();

create or replace function public.refresh_after_sync()
returns table (product_month_rows bigint, partner_month_rows bigint,
               health_metrics bigint, filter_options bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  cutoff date := (current_date - interval '2 months')::date;
  a bigint; b bigint;
begin
  a := public.refresh_product_month(cutoff);
  b := public.refresh_partner_month(cutoff);
  perform public.refresh_dashboard_summaries();
  return query
    select a, b,
           (select count(*) from public.dashboard_health),
           (select count(*) from public.dashboard_filter_options);
end;
$$;

grant execute on function public.refresh_after_sync() to service_role;

select public.refresh_partner_month() as partner_month_rows;
analyze public.dashboard_partner_month;

select count(*) as rows, count(distinct partner_id) as customers,
       min(month) as earliest, max(month) as latest
from public.dashboard_partner_month;
