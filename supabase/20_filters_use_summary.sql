-- ===========================================================================
-- 20. Let category and brand filters use the summary too
-- ===========================================================================
-- After file 19, unfiltered product_facts is quick and steady:
--
--   run 1  11,794ms  (cold)      data_health      676ms   (was timeout)
--   run 2   3,443ms              filter_options   585ms   (was timeout)
--   run 3   3,056ms
--
-- But choosing a filter still times out, because file 19 routes ANY filter
-- down the invoice-line path:
--
--   product_facts with p_gov     TIMEOUT
--
-- For gov, salesperson and customer that is unavoidable -- a product x month
-- summary genuinely cannot say who bought or where.
--
-- For CATEGORY and BRAND it is not, and the reason is already in the query.
-- Both are attributes of the PRODUCT, and the outer WHERE clause already
-- applies them there:
--
--   and (p_category is null or p.category = p_category)
--   and (p_brand    is null or p.brand    = p_brand)
--
-- So the line-level path was re-filtering on l.category/l.brand to reach the
-- same set of products the outer clause was about to select anyway. Dropping
-- those two from the routing test sends them through the summary instead, and
-- changes no result.
--
-- One subtlety worth stating, because it is a real difference rather than an
-- optimisation. l.category is the category the product had WHEN IT SOLD;
-- p.category is what it is today. File 16 already made the displayed category
-- come from the product record, so filtering on the line value while
-- displaying the product value could disagree -- recategorise a product and it
-- would vanish from its own new category. Filtering on the product record is
-- both faster and more consistent with what the page shows.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

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
    select not ('margin'      = any (h)) as c_margin,
           not ('cost'        = any (h)) as c_cost,
           not ('revenue'     = any (h)) as c_revenue,
           not ('stock_value' = any (h)) as c_stock_value,
           not ('customers'   = any (h)) as c_customers,
           public.app_table_visible('dashboard_stock')         as t_stock,
           public.app_table_visible('dashboard_invoice_lines') as t_lines
    from (select public.app_my_hidden_columns() as h) z
  ),
  -- Only the three that describe WHO or WHERE force the line-level path.
  -- Category and brand describe the product, and the outer WHERE already
  -- filters on it.
  filtered as (
    select p_salesperson is not null
        or p_gov         is not null
        or p_customer    is not null as on_
  ),
  period_agg as (
    select m.product_id,
           sum(m.units) as units, sum(m.revenue) as revenue, sum(m.margin) as margin,
           null::bigint as distinct_customers, null::bigint as distinct_govs,
           sum(m.invoices) as distinct_invoices
    from public.dashboard_product_month m, filtered f
    where not f.on_
      and m.month >= date_trunc('month', p_from)::date
      and m.month <= date_trunc('month', p_to)::date
    group by m.product_id
    union all
    select l.product_id,
           sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
           count(distinct l.partner_id), count(distinct l.gov),
           count(distinct l.move_id)
    from public.dashboard_invoice_lines l, filtered f
    where f.on_
      and l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_customer    is null or l.partner_id  = p_customer)
      and (p_gov         is null or l.gov         = p_gov)
    group by l.product_id
  ),
  trailing_90 as (
    select l.product_id, sum(l.qty) as units_90d
    from public.dashboard_invoice_lines l
    where l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date > p_to - 90 and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_customer    is null or l.partner_id  = p_customer)
      and (p_gov         is null or l.gov         = p_gov)
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
  where coalesce(p.category, '') !~ 'عارضات|استاندات'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = p.product_id)
    and (p_category is null or p.category = p_category)
    and (p_brand    is null or p.brand    = p_brand);
$$;

grant execute on function public.product_facts(date, date, text, text, bigint, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- What is still slow, and what it would take
-- ---------------------------------------------------------------------------
-- gov, salesperson and customer filters still read the invoice lines and may
-- still time out. Fixing those means a second summary carrying the dimension
-- -- product x month x gov is roughly 50,000 rows, which is still small.
--
-- Worth doing only if people actually use those filters. Ask before building
-- it: three summary tables to maintain is a real cost, and this dashboard has
-- already accumulated enough machinery for one day.
