-- Dabboos Product Dashboard — returns and discounts
-- Run in: Supabase -> SQL Editor. Safe to re-run.
-- Run AFTER 07_tables_and_overrides.sql. Run BEFORE or AFTER 05_masking.sql —
-- these are new functions and 05 does not redefine them.
--
-- ===========================================================================
-- WHY THESE TWO PAGES
-- ===========================================================================
-- Both numbers already exist in the data and are currently invisible:
--
--   RETURNS   credit notes are netted into every figure on the dashboard, so
--             a product that sells 1000 and takes back 300 looks identical to
--             one that sells 700 cleanly. The dashboard is right about the
--             money and silent about the problem.
--
--   DISCOUNTS margin leakage is usually pricing, not cost. list_price is
--             synced and read by nothing; realized price is computable from
--             every line. The gap between them is the leak.
--
-- ===========================================================================
-- SIGN CONVENTION — READ THIS BEFORE CHANGING ANY SUM
-- ===========================================================================
-- Credit-note rows carry NEGATIVE qty and price_subtotal (01_schema.sql), so
-- plain summation nets returns out. That is deliberate everywhere else. HERE
-- we want the gross figures apart, so:
--
--     sold      = sum(...) filter (where move_type = 'out_invoice')
--     returned  = -sum(...) filter (where move_type = 'out_refund')   ← negated
--
-- The negation makes `returned` a positive magnitude for display. Never wrap
-- these in abs(): a genuinely negative sale line (a correction) would then be
-- silently counted as a return.
--
-- ===========================================================================
-- MASKING AND SCOPING
-- ===========================================================================
-- SECURITY INVOKER, like every other RPC, so the RLS policies scope the rows
-- and a hidden dashboard_invoice_lines yields nothing. Money columns follow
-- the same mask keys as product_facts: revenue, margin, cost, customers.

-- ===========================================================================
-- 1. returns_by_product
-- ===========================================================================
create or replace function public.returns_by_product(
  p_from        date,
  p_to          date,
  p_salesperson text default null,
  p_gov         text default null,
  p_category    text default null
)
returns table (
  product_id      bigint,
  sku             text,
  name            text,
  category        text,
  sold_units      numeric,
  sold_value      numeric,
  returned_units  numeric,
  returned_value  numeric,
  return_rate     numeric,   -- % of units sold that came back
  return_invoices bigint,
  customers       bigint
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('revenue'   = any (h)) as c_revenue,
           not ('customers' = any (h)) as c_customers
    from (select public.app_my_hidden_columns() as h) z
  ),
  scoped as (
    select l.*
    from public.dashboard_invoice_lines l
    where l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_category    is null or l.category    = p_category)
      -- the invoice-level discount lines are not products; excluded here for
      -- the same reason product_facts excludes them
      and not exists (select 1 from public.dashboard_excluded_products x
                       where x.product_id = l.product_id)
  ),
  agg as (
    select s.product_id,
           sum(s.qty)            filter (where s.move_type = 'out_invoice') as sold_units,
           sum(s.price_subtotal) filter (where s.move_type = 'out_invoice') as sold_value,
           -sum(s.qty)            filter (where s.move_type = 'out_refund') as ret_units,
           -sum(s.price_subtotal) filter (where s.move_type = 'out_refund') as ret_value,
           count(distinct s.move_id) filter (where s.move_type = 'out_refund') as ret_invoices,
           count(distinct s.partner_id) filter (where s.move_type = 'out_refund') as ret_customers
    from scoped s
    group by s.product_id
  )
  select a.product_id, p.sku, p.name, p.category,
         coalesce(a.sold_units, 0),
         case when pm.c_revenue then coalesce(a.sold_value, 0) end,
         coalesce(a.ret_units, 0),
         case when pm.c_revenue then coalesce(a.ret_value, 0) end,
         -- Rate on UNITS, not money: a return at a discount would understate a
         -- money-based rate, and the operational question is how many pieces
         -- came back. Undefined rather than 0 when nothing was sold — a
         -- product with returns and no sales in the period is a real case.
         case when coalesce(a.sold_units, 0) > 0
              then round(100.0 * coalesce(a.ret_units, 0) / a.sold_units, 1) end,
         coalesce(a.ret_invoices, 0),
         case when pm.c_customers then coalesce(a.ret_customers, 0) end
  from agg a
  cross join perms pm
  join public.dashboard_products p on p.product_id = a.product_id
  where coalesce(a.ret_units, 0) <> 0        -- only products that came back
    and coalesce(p.category, '') !~ 'عارضات|استاندات'
  order by coalesce(a.ret_units, 0) desc;
$$;

grant execute on function public.returns_by_product(date, date, text, text, text)
  to authenticated;

-- ===========================================================================
-- 2. returns_by_dimension
-- ===========================================================================
-- One function rather than four near-identical ones. p_kind picks the grouping
-- column; anything else returns no rows rather than erroring, so a typo in the
-- front end degrades to an empty chart instead of a red banner.
create or replace function public.returns_by_dimension(
  p_from date,
  p_to   date,
  p_kind text                     -- customer | salesperson | gov | category
)
returns table (
  label          text,
  sold_value     numeric,
  returned_value numeric,
  returned_units numeric,
  return_rate    numeric
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('revenue' = any (h)) as c_revenue
    from (select public.app_my_hidden_columns() as h) z
  ),
  scoped as (
    select l.*,
           case p_kind
             when 'customer'    then coalesce(c.complete_name, 'Partner ' || l.partner_id)
             when 'salesperson' then l.salesperson
             when 'gov'         then l.gov
             when 'category'    then l.category
           end as label
    from public.dashboard_invoice_lines l
    left join public.dashboard_customers c on c.partner_id = l.partner_id
    where l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and not exists (select 1 from public.dashboard_excluded_products x
                       where x.product_id = l.product_id)
  )
  select coalesce(s.label, '—'),
         case when bool_and(pm.c_revenue)
              then sum(s.price_subtotal) filter (where s.move_type = 'out_invoice') end,
         case when bool_and(pm.c_revenue)
              then -sum(s.price_subtotal) filter (where s.move_type = 'out_refund') end,
         -sum(s.qty) filter (where s.move_type = 'out_refund'),
         case when sum(s.qty) filter (where s.move_type = 'out_invoice') > 0
              then round(100.0 * (-sum(s.qty) filter (where s.move_type = 'out_refund'))
                         / sum(s.qty) filter (where s.move_type = 'out_invoice'), 1) end
  from scoped s
  cross join perms pm
  where p_kind in ('customer', 'salesperson', 'gov', 'category')
  group by 1
  having -sum(s.qty) filter (where s.move_type = 'out_refund') <> 0
  order by 3 desc nulls last;
$$;

grant execute on function public.returns_by_dimension(date, date, text) to authenticated;

-- ===========================================================================
-- 3. discounts_by_product
-- ===========================================================================
-- Realized price is computed from SALES ONLY. Including credit notes would
-- pull the average toward whatever was refunded and report a discount that
-- nobody ever gave.
--
-- discount % is null, never 0, when list_price is missing or zero: "we do not
-- know the list price" and "this product is sold at list" are different facts,
-- and a 0 would put unpriced products at the top of a "best discipline" sort.
create or replace function public.discounts_by_product(
  p_from        date,
  p_to          date,
  p_salesperson text default null,
  p_gov         text default null,
  p_category    text default null
)
returns table (
  product_id     bigint,
  sku            text,
  name           text,
  category       text,
  units          numeric,
  revenue        numeric,
  list_price     numeric,
  realized_price numeric,
  discount_pct   numeric,
  margin         numeric,
  margin_pct     numeric,
  leakage        numeric     -- money given away vs list, at the units sold
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('revenue' = any (h)) as c_revenue,
           not ('margin'  = any (h)) as c_margin,
           not ('cost'    = any (h)) as c_cost
    from (select public.app_my_hidden_columns() as h) z
  ),
  agg as (
    select l.product_id,
           sum(l.qty)            as units,
           sum(l.price_subtotal) as revenue,
           sum(l.price_margin)   as margin
    from public.dashboard_invoice_lines l
    where l.state = 'posted'
      and l.move_type = 'out_invoice'          -- sales only, see above
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_category    is null or l.category    = p_category)
      and not exists (select 1 from public.dashboard_excluded_products x
                       where x.product_id = l.product_id)
    group by l.product_id
    having sum(l.qty) > 0
  )
  select a.product_id, p.sku, p.name, p.category,
         a.units,
         case when pm.c_revenue then a.revenue end,
         case when pm.c_cost    then p.list_price end,
         case when pm.c_revenue then a.revenue / a.units end,
         case when coalesce(p.list_price, 0) > 0
              then round(100.0 * (p.list_price - a.revenue / a.units) / p.list_price, 1) end,
         case when pm.c_margin then a.margin end,
         case when pm.c_margin and a.revenue <> 0
              then round(100.0 * a.margin / a.revenue, 1) end,
         case when pm.c_revenue and coalesce(p.list_price, 0) > 0
              then (p.list_price - a.revenue / a.units) * a.units end
  from agg a
  cross join perms pm
  join public.dashboard_products p on p.product_id = a.product_id
  where coalesce(p.category, '') !~ 'عارضات|استاندات'
  order by 12 desc nulls last;               -- biggest leakage first
$$;

grant execute on function public.discounts_by_product(date, date, text, text, text)
  to authenticated;

-- ===========================================================================
-- 4. discounts_by_dimension
-- ===========================================================================
-- The average discount is REVENUE-WEIGHTED, not a mean of per-line percentages.
-- An unweighted mean lets one tiny heavily-discounted line outweigh a large
-- disciplined one, which would name the wrong salesperson.
create or replace function public.discounts_by_dimension(
  p_from date,
  p_to   date,
  p_kind text                     -- customer | salesperson | gov | category
)
returns table (
  label        text,
  units        numeric,
  revenue      numeric,
  list_value   numeric,
  leakage      numeric,
  discount_pct numeric
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('revenue' = any (h)) as c_revenue
    from (select public.app_my_hidden_columns() as h) z
  ),
  scoped as (
    select l.qty, l.price_subtotal, p.list_price,
           case p_kind
             when 'customer'    then coalesce(c.complete_name, 'Partner ' || l.partner_id)
             when 'salesperson' then l.salesperson
             when 'gov'         then l.gov
             when 'category'    then l.category
           end as label
    from public.dashboard_invoice_lines l
    join public.dashboard_products p on p.product_id = l.product_id
    left join public.dashboard_customers c on c.partner_id = l.partner_id
    where l.state = 'posted'
      and l.move_type = 'out_invoice'
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and coalesce(p.list_price, 0) > 0      -- no list price, no discount to speak of
      and not exists (select 1 from public.dashboard_excluded_products x
                       where x.product_id = l.product_id)
  )
  select coalesce(s.label, '—'),
         sum(s.qty),
         case when bool_and(pm.c_revenue) then sum(s.price_subtotal) end,
         case when bool_and(pm.c_revenue) then sum(s.qty * s.list_price) end,
         case when bool_and(pm.c_revenue) then sum(s.qty * s.list_price) - sum(s.price_subtotal) end,
         case when sum(s.qty * s.list_price) > 0
              then round(100.0 * (sum(s.qty * s.list_price) - sum(s.price_subtotal))
                         / sum(s.qty * s.list_price), 1) end
  from scoped s
  cross join perms pm
  where p_kind in ('customer', 'salesperson', 'gov', 'category')
  group by 1
  having sum(s.qty) > 0
  order by 5 desc nulls last;
$$;

grant execute on function public.discounts_by_dimension(date, date, text) to authenticated;

-- ===========================================================================
-- 5. Grant the two new pages to the system roles
-- ===========================================================================
-- Same reasoning as 08_add_status_page.sql: app_roles.pages is an allow-list,
-- so a page key that is absent is a screen nobody can open — including the
-- admin, whose grant checkbox reads the same list.
update public.app_roles
set pages = array_append(pages, 'returns')
where role_key in ('admin', 'management') and not ('returns' = any (pages));

update public.app_roles
set pages = array_append(pages, 'discounts')
where role_key in ('admin', 'management') and not ('discounts' = any (pages));

-- ===========================================================================
-- 6. Confirm
-- ===========================================================================
select 'functions' as what,
       string_agg(routine_name, ', ' order by routine_name) as detail
from information_schema.routines
where routine_schema = 'public'
  and routine_name in ('returns_by_product', 'returns_by_dimension',
                       'discounts_by_product', 'discounts_by_dimension')
union all
select 'pages on system roles',
       string_agg(role_key || ': ' || array_to_string(pages, '/'), '  |  ' order by role_key)
from public.app_roles where is_system;
