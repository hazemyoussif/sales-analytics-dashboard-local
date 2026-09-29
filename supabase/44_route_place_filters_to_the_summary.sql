-- ===========================================================================
-- 44. Route the place filters through the summary built in file 43
-- ===========================================================================
-- File 43 built dashboard_product_place_month. Nothing reads it until this.
--
-- Measured before, the same query eight times as a real user:
--
--   10,586ms  5,212  6,056  2,119  1,917  1,667  1,632  1,808
--
-- Cold to warm. The first number is what someone gets when nobody has used a
-- place filter recently, which is most of the time.
--
-- product_facts had two routes: unfiltered went to dashboard_product_month,
-- anything else went to the invoice lines. A governorate or city filter took
-- the second route and dragged 739,000 wide rows off disk to answer a question
-- a summary could answer from eight narrow columns.
--
-- It now has three. Only filters no summary can answer -- salesperson,
-- customer, category, brand -- still reach the lines.
--
-- TRAILING_90 IS DELIBERATELY LEFT ON THE INVOICE LINES. It reads ninety days,
-- not twelve or twenty-seven months, so it is a small indexed read even cold --
-- and a monthly summary cannot express "the last ninety days" without rounding
-- to three calendar months. Velocity feeds the reorder page's buying
-- suggestions; rounding it to make an already-fast query faster would be
-- trading correctness for nothing.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.
-- Requires file 43 to have been run first.

create or replace function public.product_facts(
  p_from        date,
  p_to          date,
  p_salesperson text   default null,
  p_gov         text   default null,
  p_customer    bigint default null,
  p_category    text   default null,
  p_brand       text   default null,
  p_city        text   default null
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
  with perms as materialized (
    select not ('margin'      = any (h)) as c_margin,
           not ('cost'        = any (h)) as c_cost,
           not ('revenue'     = any (h)) as c_revenue,
           not ('stock_value' = any (h)) as c_stock_value,
           not ('customers'   = any (h)) as c_customers,
           public.app_table_visible('dashboard_stock')         as t_stock,
           public.app_table_visible('dashboard_invoice_lines') as t_lines
    from (select public.app_my_hidden_columns() as h) z
  ),
  -- p_city joins the list that forces the invoice lines: dashboard_product_month
  -- is keyed by product and month and knows nothing about where the goods went.
  -- THREE ROUTES, not two.
  --
  --   needs_lines   a filter no summary can answer -- salesperson, customer,
  --                 category or brand. Only the invoice lines know these.
  --   place_only    gov and/or city, and nothing else. Answered by
  --                 dashboard_product_place_month, which is eight narrow
  --                 columns instead of twenty-five wide ones and therefore
  --                 stays in cache.
  --   neither       dashboard_product_month, as before.
  --
  -- The middle route is the point of file 43. A place filter used to be the
  -- last thing dragging the 739,000-row invoice table off disk, and it was
  -- measured at 10.6 seconds cold against 1.6 warm.
  route as (
    select (p_salesperson is not null or p_customer is not null
            or p_category is not null or p_brand is not null) as needs_lines,
           (p_gov is not null or p_city is not null) as has_place
  ),
  filtered as (
    select r.needs_lines or r.has_place as on_ from route r
  ),
  -- The precomputed velocity trails TODAY. It may only be used when the
  -- selected window ends near today; a week of slack covers "yesterday" and
  -- a page left open overnight without letting March 2025 borrow this week's
  -- rate. Filters force the scan too: a stored global figure cannot answer
  -- "how fast does this sell in Basra".
  use_cached as (
    select (not f.on_) and p_to >= current_date - 7 as on_ from filtered f
  ),
  period_agg as (
    select m.product_id,
           sum(m.units) as units, sum(m.revenue) as revenue, sum(m.margin) as margin,
           null::bigint as distinct_customers, null::bigint as distinct_govs,
           sum(m.invoices) as distinct_invoices
    from public.dashboard_product_month m, route r
    where not r.needs_lines and not r.has_place
      and m.month >= date_trunc('month', p_from)::date
      and m.month <= date_trunc('month', p_to)::date
    group by m.product_id
    union all
    -- place only: the narrow summary. distinct customers and govs are NULL
    -- here for the same reason they are on the unfiltered path -- a monthly
    -- summary cannot count a customer once across several months, and an
    -- inflated count is worse than an absent one.
    select pm.product_id,
           sum(pm.units), sum(pm.revenue), sum(pm.margin),
           null::bigint, null::bigint,
           sum(pm.invoices)
    from public.dashboard_product_place_month pm, route r
    where r.has_place and not r.needs_lines
      and pm.month >= date_trunc('month', p_from)::date
      and pm.month <= date_trunc('month', p_to)::date
      and (p_gov  is null or pm.gov  = p_gov)
      and (p_city is null or pm.city = p_city)
    group by pm.product_id
    union all
    select l.product_id,
           sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
           count(distinct l.partner_id), count(distinct l.gov),
           count(distinct l.move_id)
    from public.dashboard_invoice_lines l, route r
    where r.needs_lines
      and l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_customer    is null or l.partner_id  = p_customer)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_city        is null or l.city        = p_city)
      and (p_category    is null or l.category    = p_category)
      and (p_brand       is null or l.brand       = p_brand)
    group by l.product_id
  ),
  trailing_90 as (
    select ls.product_id, ls.units_90d as units_90d
    from public.dashboard_product_lastsale ls, use_cached u
    where u.on_
    union all
    select l.product_id, sum(l.qty)
    from public.dashboard_invoice_lines l, use_cached u
    where not u.on_
      and l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date > p_to - 90 and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_customer    is null or l.partner_id  = p_customer)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_city        is null or l.city        = p_city)
      and (p_category    is null or l.category    = p_category)
      and (p_brand       is null or l.brand       = p_brand)
    group by l.product_id
  )
  select
    p.product_id, p.sku, p.name, p.category, p.brand, p.uom,
    case when pm.c_cost then p.cost end,
    p.list_price,
    case when pm.t_lines then coalesce(pe.units, 0) end,
    case when pm.t_lines and pm.c_revenue then coalesce(pe.revenue, 0) end,
    case when pm.t_lines and pm.c_margin  then coalesce(pe.margin, 0) end,
    case when pm.t_lines and pm.c_margin and coalesce(pe.revenue, 0) <> 0
         then round(100.0 * pe.margin / pe.revenue, 1) end,
    case when pm.t_lines and pm.c_revenue and coalesce(pe.units, 0) <> 0
         then pe.revenue / pe.units end,
    ls.last_invoiced,
    case when pm.t_lines and pm.c_customers then pe.distinct_customers end,
    case when pm.t_lines then pe.distinct_govs end,
    case when pm.t_lines then coalesce(pe.distinct_invoices, 0) end,
    case when pm.t_stock then coalesce(s.on_hand_qty, 0) end,
    case when pm.t_stock and pm.c_stock_value then coalesce(s.stock_value, 0) end,
    case when pm.t_lines then greatest(coalesce(tr.units_90d, 0) / 3.0, 0) end
  from public.dashboard_products p
  cross join perms pm
  left join public.dashboard_stock s             on s.product_id = p.product_id
  left join period_agg  pe                       on pe.product_id = p.product_id
  left join trailing_90 tr                       on tr.product_id = p.product_id
  left join public.dashboard_product_lastsale ls on ls.product_id = p.product_id
  where coalesce(p.category, '') !~ U&'\0639\0627\0631\0636\0627\062A|\0627\0633\062A\0627\0646\062F\0627\062A'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = p.product_id)
    and (p_category is null or p.category = p_category)
    and (p_brand    is null or p.brand    = p_brand);
$$;
grant execute on function public.product_facts(
  date, date, text, text, bigint, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- The routed answer must equal the answer from the lines, to the dinar
-- ---------------------------------------------------------------------------
-- Left: what product_facts now returns for a governorate, via the summary.
-- Right: the same figure computed straight from the invoice lines.
with routed as (
  select sum(revenue) as revenue, sum(units) as units, count(*) as products
  from public.product_facts(date '2025-08-01', date '2026-08-15',
                            null, U&'\0627\0631\0628\064A\0644 (IQ)')
  where revenue is not null
),
direct as (
  select sum(l.price_subtotal) as revenue, sum(l.qty) as units,
         count(distinct l.product_id) as products
  from public.dashboard_invoice_lines l
  where l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
    and l.product_id is not null
    and l.gov = U&'\0627\0631\0628\064A\0644 (IQ)'
    and l.invoice_date >= date '2025-08-01' and l.invoice_date <= date '2026-08-15'
)
select round(routed.revenue) as routed_revenue,
       round(direct.revenue) as direct_revenue,
       round(routed.revenue) = round(direct.revenue) as revenue_matches,
       round(routed.units)   as routed_units,
       round(direct.units)   as direct_units,
       round(routed.units)   = round(direct.units) as units_matches
from routed, direct;
