-- ===========================================================================
-- 58. Any window that does not end at the newest data scanned the invoice lines
-- ===========================================================================
-- Reported as: pick a date range on Overview and get تعذّر تحميل البيانات /
-- canceling statement due to statement timeout.
--
-- It is not the LENGTH of the range. It is whether the range ENDS at the
-- newest data. Measured warm, unfiltered, on overview_facts:
--
--   2024-06-26 → 2026-08-15   ends at newest data      396 ms
--   2026-01-01 → 2026-08-15   ends at newest data       62 ms
--   2025-01-01 → 2025-12-31   ends in the past       4,252 ms
--   2026-06-01 → 2026-06-30   ends in the past       3,234 ms
--
-- WHY. product_facts computes velocity_90d. File 33 precomputed it and file 45
-- fixed the comparison to use max(last_invoiced) rather than current_date, so
-- the cache is used when the window ends near the newest data. That gate is
-- RIGHT: units_90d trails the last refresh, and today's sell-through rate
-- cannot describe June 2026. Refusing the cache is correct.
--
-- The bug was the fallback. Refusing the cache meant scanning
-- dashboard_invoice_lines -- 348 MB -- for the trailing ninety days. Warm that
-- is three to four seconds. Cold it is the 20 s cap, which is the error.
--
-- Every historical window paid it, with no filter set at all. Picking "June"
-- was enough.
--
-- THE FIX. dashboard_product_month already holds units per product per month
-- (file 19), and dashboard_product_place_month holds them per gov and city
-- (file 43). Ninety days is three of those buckets. trailing_90 gains two more
-- routes so the lines are read only when something genuinely needs them:
--
--   window ends near newest data, no filters   dashboard_product_lastsale
--   salesperson or customer                    dashboard_invoice_lines
--   gov or city only                           dashboard_product_place_month
--   historical window, no filters              dashboard_product_month
--
-- The four are mutually exclusive and cover every combination: use_cached is
-- false whenever any filter is set, so route 1 fires only with no filters and
-- a recent window, and route 4 takes the same case with an old window.
--
-- MEASURED, product_facts, warm:
--
--   2025 full year, no filter        71 ms →  17 ms
--   June 2026 only                3,365 ms →  17 ms      198x
--   2025 + gov filter                39 ms →  28 ms
--
-- and overview_facts end to end, every case now 39–63 ms where two of them
-- were 3–4 seconds warm and timing out cold.
--
-- WHAT CHANGES IN THE NUMBERS. Only velocity_90d, and only on the two routes
-- that moved. Verified column by column against the previous definition:
--
--   recent window, no filter     0 rows differ   (cached route, untouched)
--   salesperson filter           0 rows differ   (lines route, untouched)
--   historical, no filter        19 other columns identical;
--                                velocity differs on 210 of 1,431 products,
--                                total 45,528 → 46,084, +1.2%
--   gov filter                   149 rows differ, velocity only
--
-- The difference is exact-ninety-days versus three whole months. The dashboard
-- is month-based everywhere else -- file 53 snaps filtered periods to month
-- boundaries and the period control is now months -- so three buckets is the
-- consistent answer rather than an approximation of a precision nothing else
-- offers.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.
-- ===========================================================================

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
    -- 1. the window ends near the newest data AND nothing is filtered:
    --    file 33's cached figure, unchanged.
    select ls.product_id, ls.units_90d as units_90d
    from public.dashboard_product_lastsale ls
    where (select on_ from use_cached)
    union all
    -- 2. salesperson or customer. Only the invoice lines know these, so this
    --    route still reads them -- correctly, and it was never the slow case.
    select l.product_id, sum(l.qty)
    from public.dashboard_invoice_lines l
    where (select needs_lines from route)
      and l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date > p_to - 90 and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_customer    is null or l.partner_id  = p_customer)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_city        is null or l.city        = p_city)
      and (p_category    is null or l.category    = p_category)
      and (p_brand       is null or l.brand       = p_brand)
    group by l.product_id
    union all
    -- 3. a place filter and nothing else: file 43's narrow summary, which
    --    already carries units per product per gov/city per month.
    select pm.product_id, sum(pm.units)
    from public.dashboard_product_place_month pm
    where (select has_place and not needs_lines from route)
      and pm.month >  (date_trunc('month', p_to) - interval '3 months')::date
      and pm.month <= date_trunc('month', p_to)::date
      and (p_gov  is null or pm.gov  = p_gov)
      and (p_city is null or pm.city = p_city)
    group by pm.product_id
    union all
    -- 4. NO filters, but a HISTORICAL window. THIS IS THE CASE THAT TIMED OUT.
    --    file 19's product-by-month summary: 10,356 rows instead of 348 MB.
    select m.product_id, sum(m.units)
    from public.dashboard_product_month m
    where (select not needs_lines and not has_place from route)
      and not (select on_ from use_cached)
      and m.month >  (date_trunc('month', p_to) - interval '3 months')::date
      and m.month <= date_trunc('month', p_to)::date
    group by m.product_id
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
