-- ===========================================================================

-- 59. THE DATE PICKERS PROMISED DAYS AND THE QUERY DELIVERED MONTHS

--

-- Reported as a number that would not reconcile: one product, H 100, showing

-- 18,364 units and 658.6M on Overview against 1,283 units in Odoo. Fourteen

-- times over.

--

-- The dashboard figure was not wrong for what it measured. It matched the

-- invoice lines EXACTLY for 2025-07-01 to 2026-07-31 -- 18,364.00 units and

-- 658,647,500. The window was thirteen months.

--

-- Two things put it there, and only the second is a defect.

--

--   1. safePeriod defaults to DEFAULT_MONTHS = 12 back from the last invoice

--      date. Unless you pick dates, every product figure on Overview is a

--      YEAR. That is a labelling problem, not a correctness one.

--

--   2. period_agg then rounded that window OUTWARD to whole months, turning

--      2025-08-15..2026-08-15 into 2025-08-01..2026-08-31. Thirteen months

--      from a twelve month request, and no way for a reader to tell.

--

-- The second one is the bug this file fixes, and it is worse than the

-- default: it inflated ANY window not already sitting on month boundaries.

-- Asking for 10-20 July 2026 reported 1,015 units for H 100 where the lines

-- say 499 -- more than double -- because it silently answered for the whole

-- of July.

--

-- It was also inconsistent with the rest of the same function. The

-- salesperson/customer route filters invoice_date to the day, so the SAME

-- dates on the SAME page returned 41 units with a rep selected and 1,015

-- without, against a true 499. Which definition of "the period" you got

-- depended on which filters happened to be set.

--

-- THE FIX. The month summaries are exact for whole months and only for

-- whole months, so use them for the interior of the window and read the

-- invoice lines for the one or two PARTIAL months at the edges. Bounded:

-- at most two months of lines, on idx_inv_lines_dt. A window already on

-- month boundaries -- which every default and every month-picker window is

-- -- reads no lines at all and returns exactly what it returned before.

--

-- Customers 80/20 solved the same problem the other way, by making the

-- control months. That was right for a page whose comparison is month over

-- month. Overview is where people reconcile against Odoo one product at a

-- time, and Odoo lets them pick any two dates, so here the query moves to

-- meet the control rather than the other way round.

--

-- Not changed: velocity_90d still reads three whole month buckets (file 58).

-- It is a rate, not a total, the error is around 1.2%, and making it exact

-- would put the 348 MB table back on the default page load.

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
  -- THE WINDOW IS NOW HONOURED TO THE DAY.
  --
  -- period_agg read whole months: m.month between date_trunc(p_from) and
  -- date_trunc(p_to). That widens the window OUTWARD at both ends, silently.
  -- Asking for 10-20 July returned the whole of July: 1,015 units for H 100
  -- where the truth is 499. The page offered day pickers and answered a
  -- different question. The default window -- twelve months back from the
  -- last invoice, so 2025-08-15 to 2026-08-15 -- was actually executed as
  -- 2025-08-01 to 2026-08-31. Thirteen months, not twelve. That is how a
  -- single product came to report 18,364 units against Odoo 1,283, and it
  -- is what a manager hit when they went looking for the difference.
  --
  -- Worse, it was not consistent with itself. The salesperson/customer route
  -- below filters l.invoice_date between p_from and p_to, exact to the day.
  -- Same dates, same page, two definitions of "the period" depending on
  -- whether a filter happened to be set: 10-20 July returned 1,015 units
  -- unfiltered and 41 for one rep, against a true 499.
  --
  -- The fix keeps the summaries where they are EXACT -- the whole months in
  -- the interior of the window -- and reads the invoice lines only for the
  -- one or two PARTIAL months at the edges. At most two months of lines,
  -- served by idx_inv_lines_dt, rather than the whole 348 MB table. A window
  -- that already sits on month boundaries touches no lines at all and is
  -- byte for byte what it was before.
  span as (
    select
      mf, mt, from_full, to_full,
      -- the whole months the summaries may answer; NULL when there are none
      case when mf = mt then (case when from_full and to_full then mf end)
           when from_full then mf
           else (mf + interval '1 month')::date end                     as m_lo,
      case when mf = mt then (case when from_full and to_full then mt end)
           when to_full then mt
           else (mt - interval '1 month')::date end                     as m_hi,
      -- the partial slice at the START of the window. When the window sits
      -- inside a single month this slice carries the whole of it.
      case when mf = mt then (case when from_full and to_full then null else p_from end)
           when from_full then null
           else p_from end                                              as lead_from,
      case when mf = mt then (case when from_full and to_full then null else p_to end)
           when from_full then null
           else (mf + interval '1 month' - interval '1 day')::date end  as lead_to,
      -- the partial slice at the END. Never set for a single-month window,
      -- which the slice above has already covered in full; double counting
      -- there would be silent, and would surface only as inflated revenue.
      case when mf < mt and not to_full then mt   end                   as tail_from,
      case when mf < mt and not to_full then p_to end                   as tail_to
    from (
      select date_trunc('month', p_from)::date as mf,
             date_trunc('month', p_to)::date   as mt,
             p_from = date_trunc('month', p_from)::date as from_full,
             p_to   = (date_trunc('month', p_to)
                        + interval '1 month' - interval '1 day')::date as to_full
    ) b
  ),
  -- Several rows per product now -- interior plus up to two edges -- so this
  -- CANNOT be joined directly. period_agg below folds it back to one row.
  period_parts as (
    -- unfiltered, interior whole months: the summary, as before
    select m.product_id,
           sum(m.units) as units, sum(m.revenue) as revenue, sum(m.margin) as margin,
           null::bigint as distinct_customers, null::bigint as distinct_govs,
           sum(m.invoices) as distinct_invoices
    from public.dashboard_product_month m
    where (select not needs_lines and not has_place from route)
      and m.month >= (select m_lo from span)
      and m.month <= (select m_hi from span)
    group by m.product_id
    union all
    -- unfiltered, leading partial month: exact to the day
    select l.product_id,
           sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
           null::bigint, null::bigint, count(distinct l.move_id)
    from public.dashboard_invoice_lines l
    where (select not needs_lines and not has_place from route)
      and l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= (select lead_from from span)
      and l.invoice_date <= (select lead_to   from span)
    group by l.product_id
    union all
    -- unfiltered, trailing partial month
    select l.product_id,
           sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
           null::bigint, null::bigint, count(distinct l.move_id)
    from public.dashboard_invoice_lines l
    where (select not needs_lines and not has_place from route)
      and l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= (select tail_from from span)
      and l.invoice_date <= (select tail_to   from span)
    group by l.product_id
    union all
    -- place only, interior whole months: file 43 narrow summary. distinct
    -- customers and govs stay NULL here for the same reason as on the
    -- unfiltered path -- a monthly summary cannot count a customer once
    -- across several months, and an inflated count is worse than an absent
    -- one.
    select pm.product_id,
           sum(pm.units), sum(pm.revenue), sum(pm.margin),
           null::bigint, null::bigint,
           sum(pm.invoices)
    from public.dashboard_product_place_month pm
    where (select has_place and not needs_lines from route)
      and pm.month >= (select m_lo from span)
      and pm.month <= (select m_hi from span)
      and (p_gov  is null or pm.gov  = p_gov)
      and (p_city is null or pm.city = p_city)
    group by pm.product_id
    union all
    -- place only, leading partial month
    select l.product_id,
           sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
           null::bigint, null::bigint, count(distinct l.move_id)
    from public.dashboard_invoice_lines l
    where (select has_place and not needs_lines from route)
      and l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= (select lead_from from span)
      and l.invoice_date <= (select lead_to   from span)
      and (p_gov  is null or l.gov  = p_gov)
      and (p_city is null or l.city = p_city)
    group by l.product_id
    union all
    -- place only, trailing partial month
    select l.product_id,
           sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
           null::bigint, null::bigint, count(distinct l.move_id)
    from public.dashboard_invoice_lines l
    where (select has_place and not needs_lines from route)
      and l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= (select tail_from from span)
      and l.invoice_date <= (select tail_to   from span)
      and (p_gov  is null or l.gov  = p_gov)
      and (p_city is null or l.city = p_city)
    group by l.product_id
    union all
    -- salesperson or customer: the lines, already exact to the day. Untouched.
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
  -- The slices are disjoint by date, so units, revenue, margin and invoice
  -- counts add. max() on the two distinct counts because only the
  -- salesperson/customer route produces them; the rest are NULL, and a NULL
  -- must not be turned into a zero.
  period_agg as (
    select product_id,
           sum(units)   as units,
           sum(revenue) as revenue,
           sum(margin)  as margin,
           max(distinct_customers) as distinct_customers,
           max(distinct_govs)      as distinct_govs,
           sum(distinct_invoices)  as distinct_invoices
    from period_parts
    group by product_id
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
