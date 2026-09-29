-- Dabboos Product Dashboard — column masking
-- Run in: Supabase -> SQL Editor. Safe to re-run.
-- Run AFTER 04_admin.sql AND 07_tables_and_overrides.sql.
--
-- ===========================================================================
-- WHAT THIS FILE DOES
-- ===========================================================================
-- Redefines every RPC so that:
--
--   1. columns a role may not see come back as NULL (RLS cannot mask columns);
--   2. fields sourced from a table the role has HIDDEN come back as NULL
--      rather than 0.
--
-- Row scoping and table hiding are both handled by RLS (04_admin.sql,
-- 07_tables_and_overrides.sql). This file exists for the two things RLS
-- structurally cannot do.
--
-- ===========================================================================
-- WHY POINT 2 IS NOT OPTIONAL
-- ===========================================================================
-- RLS makes a hidden table return no rows. But the query below LEFT JOINs
-- dashboard_stock and wraps the result in coalesce(s.on_hand_qty, 0), so "no
-- rows" silently becomes "0 on hand" — for every product at once. The Reorder
-- page would then compute zero cover across the whole catalogue and urgently
-- recommend buying all of it. The same applies to dashboard_invoice_lines:
-- every product would show 0 revenue and 0 units, which reads as a catastrophic
-- sales collapse rather than a permission setting.
--
-- A withheld number must be ABSENT, never zero.
--
-- ⚠️ This file REDEFINES product_facts and revenue_adjustments, which are also
--    defined in 03_exclusions.sql, and product_customers / product_regions /
--    product_trend, also defined in 02_functions.sql. This file must be run
--    LAST. Re-running 02 or 03 afterwards would silently drop the masking —
--    with no error, and no visible change until someone notices a restricted
--    user reading margin.
--
-- ===========================================================================
-- WHY NULL RATHER THAN A MISSING COLUMN
-- ===========================================================================
-- Dropping a column would change each function's return signature, so every
-- page would have to know which shape it is about to receive. Returning NULL
-- keeps one shape for everyone: the maths in calc.js already handles nulls,
-- and the front end hides the column header on top of this. The server-side
-- null is the enforcement; the hidden header is only tidiness.
--
-- ===========================================================================
-- THE MASK KEYS
-- ===========================================================================
--   margin       -> margin, margin_pct
--   cost         -> cost
--   revenue      -> revenue, realized_price
--   stock_value  -> stock_value
--   customers    -> customer names and distinct-customer counts
--
-- Note on `revenue`: hiding it also empties the top-products ranking and the
-- ABC classes, which are computed from revenue. That is a legitimate choice
-- for a stock-only role, but it is not a small one — such a user sees units
-- and cover days, not a sales dashboard.

-- ===========================================================================
-- 1. product_facts
-- ===========================================================================
-- Identical to 03_exclusions.sql except for the `perms` CTE and the masking in
-- the final select. The exclusion list and the fixtures filter are preserved
-- exactly; if this file and 03 ever disagree about what counts as a product,
-- this one wins because it runs last.
create or replace function public.product_facts(
  p_from        date,
  p_to          date,
  p_salesperson text   default null,
  p_gov         text   default null,
  p_customer    bigint default null,
  p_category    text   default null,
  p_brand       text   default null
)
returns table (
  product_id         bigint,
  sku                text,
  name               text,
  category           text,
  brand              text,
  uom                text,
  cost               numeric,
  list_price         numeric,
  units              numeric,
  revenue            numeric,
  margin             numeric,
  margin_pct         numeric,
  realized_price     numeric,
  last_invoiced      date,
  distinct_customers bigint,
  distinct_govs      bigint,
  distinct_invoices  bigint,
  on_hand            numeric,
  stock_value        numeric,
  velocity_90d       numeric
)
language sql
stable
security invoker
as $$
  with perms as (
    -- Resolved ONCE for the whole query, not per row.
    select not ('margin'      = any (h)) as c_margin,
           not ('cost'        = any (h)) as c_cost,
           not ('revenue'     = any (h)) as c_revenue,
           not ('stock_value' = any (h)) as c_stock_value,
           not ('customers'   = any (h)) as c_customers,
           -- Table visibility. Whatever a hidden table would have contributed
           -- becomes NULL below instead of falling through coalesce(...,0).
           public.app_table_visible('dashboard_stock')         as t_stock,
           public.app_table_visible('dashboard_invoice_lines') as t_lines
    from (select public.app_my_hidden_columns() as h) z
  ),
  scoped as (
    select *
    from public.dashboard_invoice_lines l
    where l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_customer    is null or l.partner_id  = p_customer)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_category    is null or l.category    = p_category)
      and (p_brand       is null or l.brand       = p_brand)
  ),
  period_agg as (
    select product_id,
           sum(qty)                    as units,
           sum(price_subtotal)         as revenue,
           sum(price_margin)           as margin,
           count(distinct partner_id)  as distinct_customers,
           count(distinct gov)         as distinct_govs,
           count(distinct move_id)     as distinct_invoices
    from scoped
    where invoice_date >= p_from and invoice_date <= p_to
    group by product_id
  ),
  trailing_90 as (
    select product_id, sum(qty) as units_90d
    from scoped
    where invoice_date > p_to - 90 and invoice_date <= p_to
    group by product_id
  ),
  lastsale as (
    select product_id, max(invoice_date) as last_invoiced
    from scoped
    group by product_id
  ),
  latest_labels as (
    select distinct on (product_id) product_id, category, brand
    from scoped
    order by product_id, invoice_date desc
  )
  select
    p.product_id, p.sku, p.name,
    coalesce(p.category, ll.category),
    coalesce(p.brand, ll.brand),
    p.uom,
    case when pm.c_cost    then p.cost end,
    p.list_price,
    -- Every field below that is guarded by pm.t_lines or pm.t_stock would
    -- otherwise coalesce a withheld table's absence into a real-looking 0.
    case when pm.t_lines then coalesce(pe.units, 0) end,
    case when pm.t_lines and pm.c_revenue then coalesce(pe.revenue, 0) end,
    case when pm.t_lines and pm.c_margin  then coalesce(pe.margin, 0) end,
    -- margin_pct is a ratio of two protected numbers; it leaks margin whenever
    -- revenue is known, so it follows the margin flag.
    case when pm.t_lines and pm.c_margin and coalesce(pe.revenue, 0) <> 0
         then round(100.0 * pe.margin / pe.revenue, 1) end,
    case when pm.t_lines and pm.c_revenue and coalesce(pe.units, 0) <> 0
         then pe.revenue / pe.units end,
    ls.last_invoiced,
    case when pm.t_lines and pm.c_customers then coalesce(pe.distinct_customers, 0) end,
    case when pm.t_lines then coalesce(pe.distinct_govs, 0) end,
    case when pm.t_lines then coalesce(pe.distinct_invoices, 0) end,
    case when pm.t_stock then coalesce(s.on_hand_qty, 0) end,
    case when pm.t_stock and pm.c_stock_value then coalesce(s.stock_value, 0) end,
    -- velocity drives the Reorder suggestions. A hidden invoice table must not
    -- present itself as "sells nothing", which would read as a dead catalogue.
    case when pm.t_lines then greatest(coalesce(tr.units_90d, 0) / 3.0, 0) end
  from public.dashboard_products p
  cross join perms pm
  left join public.dashboard_stock s on s.product_id = p.product_id
  left join period_agg    pe on pe.product_id = p.product_id
  left join trailing_90   tr on tr.product_id = p.product_id
  left join lastsale      ls on ls.product_id = p.product_id
  left join latest_labels ll on ll.product_id = p.product_id
  where coalesce(p.category, '') !~ 'عارضات|استاندات'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = p.product_id)
    and (p_category is null or coalesce(p.category, ll.category) = p_category)
    and (p_brand    is null or coalesce(p.brand, ll.brand)       = p_brand);
$$;

grant execute on function public.product_facts(date, date, text, text, bigint, text, text)
  to authenticated;

-- ===========================================================================
-- 2. revenue_adjustments
-- ===========================================================================
create or replace function public.revenue_adjustments(
  p_from        date,
  p_to          date,
  p_salesperson text   default null,
  p_gov         text   default null,
  p_customer    bigint default null
)
returns table (product_id bigint, sku text, name text, reason text,
               units numeric, revenue numeric, margin numeric)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('margin'  = any (h)) as c_margin,
           not ('revenue' = any (h)) as c_revenue
    from (select public.app_my_hidden_columns() as h) z
  )
  select x.product_id, x.sku, x.name, x.reason,
         sum(l.qty),
         case when bool_and(pm.c_revenue) then sum(l.price_subtotal) end,
         case when bool_and(pm.c_margin)  then sum(l.price_margin) end
  from public.dashboard_invoice_lines l
  join public.dashboard_excluded_products x on x.product_id = l.product_id
  cross join perms pm
  where l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.invoice_date >= p_from and l.invoice_date <= p_to
    and (p_salesperson is null or l.salesperson = p_salesperson)
    and (p_customer    is null or l.partner_id  = p_customer)
    and (p_gov         is null or l.gov         = p_gov)
  group by x.product_id, x.sku, x.name, x.reason
  order by 6;
$$;

grant execute on function public.revenue_adjustments(date, date, text, text, bigint)
  to authenticated;

-- ===========================================================================
-- 3. product_customers — the drill-down that names names
-- ===========================================================================
-- The `customers` mask replaces the name with '•••' rather than dropping the
-- row. A role that may see the shape of demand but not who the buyers are
-- still gets an honest row count and honest units.
create or replace function public.product_customers(
  p_product_id bigint, p_from date, p_to date)
returns table (partner_id bigint, customer text, units numeric,
               revenue numeric, margin numeric, invoices bigint)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('margin'    = any (h)) as c_margin,
           not ('revenue'   = any (h)) as c_revenue,
           not ('customers' = any (h)) as c_customers
    from (select public.app_my_hidden_columns() as h) z
  )
  select case when bool_and(pm.c_customers) then l.partner_id end,
         case when bool_and(pm.c_customers)
              then coalesce(c.complete_name, 'Partner ' || l.partner_id)
              else '•••' end,
         sum(l.qty),
         case when bool_and(pm.c_revenue) then sum(l.price_subtotal) end,
         case when bool_and(pm.c_margin)  then sum(l.price_margin) end,
         count(distinct l.move_id)
  from public.dashboard_invoice_lines l
  left join public.dashboard_customers c on c.partner_id = l.partner_id
  cross join perms pm
  where l.product_id = p_product_id
    and l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.invoice_date >= p_from and l.invoice_date <= p_to
  group by l.partner_id, c.complete_name
  order by 3 desc;
$$;

grant execute on function public.product_customers(bigint, date, date) to authenticated;

-- ===========================================================================
-- 4. product_regions
-- ===========================================================================
create or replace function public.product_regions(
  p_product_id bigint, p_from date, p_to date)
returns table (gov text, units numeric, revenue numeric,
               margin numeric, customers bigint)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('margin'    = any (h)) as c_margin,
           not ('revenue'   = any (h)) as c_revenue,
           not ('customers' = any (h)) as c_customers
    from (select public.app_my_hidden_columns() as h) z
  )
  select coalesce(l.gov, '—'),
         sum(l.qty),
         case when bool_and(pm.c_revenue)   then sum(l.price_subtotal) end,
         case when bool_and(pm.c_margin)    then sum(l.price_margin) end,
         case when bool_and(pm.c_customers) then count(distinct l.partner_id) end
  from public.dashboard_invoice_lines l
  cross join perms pm
  where l.product_id = p_product_id
    and l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.invoice_date >= p_from and l.invoice_date <= p_to
  group by 1
  order by 2 desc;
$$;

grant execute on function public.product_regions(bigint, date, date) to authenticated;

-- ===========================================================================
-- 5. product_trend
-- ===========================================================================
create or replace function public.product_trend(p_product_id bigint, p_months int default 24)
returns table (month text, units numeric, revenue numeric, margin numeric)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('margin'  = any (h)) as c_margin,
           not ('revenue' = any (h)) as c_revenue
    from (select public.app_my_hidden_columns() as h) z
  )
  select to_char(date_trunc('month', l.invoice_date), 'YYYY-MM'),
         sum(l.qty),
         case when bool_and(pm.c_revenue) then sum(l.price_subtotal) end,
         case when bool_and(pm.c_margin)  then sum(l.price_margin) end
  from public.dashboard_invoice_lines l
  cross join perms pm
  where l.product_id = p_product_id
    and l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.invoice_date >= (current_date - (p_months || ' months')::interval)
  group by 1
  order by 1;
$$;

grant execute on function public.product_trend(bigint, int) to authenticated;

-- ===========================================================================
-- 6. Confirm — what the CURRENT session may see
-- ===========================================================================
-- Run as a restricted user (not the SQL editor's service role) to check the
-- masking actually bites. In the SQL editor auth.uid() is NULL, so this shows
-- the unrestricted case.
select public.app_my_hidden_columns() as hidden_for_me;
