-- ===========================================================================
-- 47. A category filter scanned 739,000 invoice lines to change nothing
-- ===========================================================================
-- Measured signed in as a real user, product_facts paged the way five pages
-- call it (products, status, worklist, frozen, reorder):
--
--   range   filter        wall
--   FULL    +category   19,920ms   <-- the 20s cap. This is the timeout.
--   FULL    +brand      13,197ms
--   27mo    +category    7,925ms
--   FULL    none         2,327ms
--   FULL    +gov         2,655ms
--
-- Files 43, 44 and 46 routed gov and city onto a narrow summary and left
-- salesperson, customer, CATEGORY and BRAND on the invoice lines, on the
-- reasoning that "only the invoice lines know these". For category and brand
-- that reasoning was simply wrong.
--
-- A product has one category and one brand. dashboard_invoice_lines carries
-- them only as denormalised copies, and the final select of product_facts has
-- always filtered on the product's own columns anyway. So the 739,000-row scan
-- applied a filter that was then applied again, correctly, against a
-- 1,431-row table.
--
-- VERIFIED BEFORE CHANGING ANYTHING, all 20 columns, 205 products:
--
--   17 of 20 identical, including units, revenue, margin, margin_pct,
--   realized_price, last_invoiced, distinct_invoices, on_hand, stock_value.
--
--   distinct_customers   179 products: a real count becomes null
--   distinct_govs        179 products: a real count becomes null
--   velocity_90d          39 products: 69.67 -> 70.33, ~1%
--
-- Those three are the price, and they are affordable:
--
--   distinct_govs is not read by any page.
--   distinct_customers is read by exactly one -- the products page detail
--     panel -- and that page sends only p_gov and p_salesperson, never a
--     category or a brand. It cannot observe this.
--   velocity_90d moves because the summary route uses the cached 90-day units
--     from file 33 instead of rescanning. That is the same cached figure the
--     unfiltered view has used since file 45, so this makes a category filter
--     agree with the default view rather than disagree with it.
--
-- And it is the RIGHT answer for velocity: how fast a product sells does not
-- depend on which category filter is on screen. p_gov, p_city, p_salesperson
-- and p_customer do change which sales count for a product, which is why they
-- still force the live scan.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

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
  --   needs_lines   salesperson or customer -- a filter that changes which
  --                 SALES COUNT for a product, which no product-keyed summary
  --                 can express. Only the invoice lines know these.
  --   place_only    gov and/or city, and nothing else. Answered by
  --                 dashboard_product_place_month, which is eight narrow
  --                 columns instead of twenty-five wide ones and therefore
  --                 stays in cache.
  --   neither       dashboard_product_month, as before.
  --
  -- The middle route is the point of file 43. A place filter used to be the
  -- last thing dragging the 739,000-row invoice table off disk, and it was
  -- measured at 10.6 seconds cold against 1.6 warm.
  -- CATEGORY AND BRAND ARE NOT ON THIS LIST ANY MORE.
  --
  -- They are attributes of the PRODUCT, not of the invoice line. A product has
  -- one category and one brand, and the final select already filters on them:
  --
  --     and (p_category is null or p.category = p_category)
  --     and (p_brand    is null or p.brand    = p_brand)
  --
  -- So the lines were being scanned to apply a filter that was then applied a
  -- second time against a 1,431-row catalogue. The scan changed nothing and
  -- cost everything.
  --
  -- Only salesperson and customer genuinely need the lines. Those change WHICH
  -- SALES COUNT for a given product; category and brand only change WHICH
  -- PRODUCTS APPEAR.
  route as (
    select (p_salesperson is not null or p_customer is not null) as needs_lines,
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
  -- WHEN THE PRECOMPUTED VELOCITY MAY BE USED.
  --
  -- This compared p_to against CURRENT_DATE, and that was wrong in a way that
  -- disabled the whole of file 33. The page's default window ends at
  -- health.date_to -- the most recent invoice in the data -- and this source
  -- stopped receiving invoices on 2026-08-15 while today is 2026-08-24. So
  -- `p_to >= current_date - 7` was false on every default page load, and
  -- trailing_90 scanned the invoice lines EVERY time, including on the
  -- unfiltered view that was supposed to touch nothing but summaries.
  --
  -- That is what kept the 739,000-row table permanently in the working set,
  -- and it is why a cold cache hurt so much: the one query that should never
  -- have gone near it went there on every load.
  --
  -- The reference is now the latest date the DATA knows about, not the
  -- calendar. dashboard_product_lastsale is 1,152 rows and already read by
  -- this function, so it costs nothing.
  use_cached as (
    select (not f.on_)
           and p_to >= (select coalesce(max(last_invoiced), current_date)
                          from public.dashboard_product_lastsale) - 7 as on_
    from filtered f
  ),
  period_agg as (
    select m.product_id,
           sum(m.units) as units, sum(m.revenue) as revenue, sum(m.margin) as margin,
           null::bigint as distinct_customers, null::bigint as distinct_govs,
           sum(m.invoices) as distinct_invoices
    from public.dashboard_product_month m
    where (select not needs_lines and not has_place from route)
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
    from public.dashboard_product_place_month pm
    where (select has_place and not needs_lines from route)
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
    from public.dashboard_invoice_lines l
    where (select needs_lines from route)
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
    from public.dashboard_product_lastsale ls
    where (select on_ from use_cached)
    union all
    select l.product_id, sum(l.qty)
    from public.dashboard_invoice_lines l
    where not (select on_ from use_cached)
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
-- The category filter must not touch dashboard_invoice_lines at all
-- ---------------------------------------------------------------------------
-- Expect One-Time Filter on the lines branch, and an execution time in the
-- low hundreds of milliseconds where it was 19,920.
explain (analyze, buffers)
select * from public.product_facts(
  date '2000-01-01', date '2026-08-24', null, null, null, U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1');

-- ---------------------------------------------------------------------------
-- And it must still return the same money
-- ---------------------------------------------------------------------------
-- Left: the category filter, now on the summary route.
-- Right: the same category computed straight from the invoice lines.
with routed as (
  select round(sum(revenue)) as revenue, round(sum(units)) as units,
         count(*) as products
  from public.product_facts(date '2000-01-01', date '2026-08-24',
                            null, null, null, U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1')
),
direct as (
  select round(sum(l.price_subtotal)) as revenue, round(sum(l.qty)) as units
  from public.dashboard_invoice_lines l
  join public.dashboard_products p on p.product_id = l.product_id
  where l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
    and p.category = U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = p.product_id)
)
select routed.products,
       routed.revenue as routed_revenue, direct.revenue as direct_revenue,
       routed.revenue = direct.revenue as revenue_matches,
       routed.units   as routed_units,   direct.units   as direct_units,
       routed.units   = direct.units     as units_matches
from routed, direct;
