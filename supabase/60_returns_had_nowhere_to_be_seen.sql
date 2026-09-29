-- ===========================================================================
-- 60. RETURNS WERE SUBTRACTED EVERYWHERE AND SHOWN NOWHERE
--
-- Every sales figure on this dashboard is NET of returns: out_refund lines
-- carry negative qty and negative price_subtotal, so summing them subtracts
-- them. That is the right default -- it is what the business actually earned
-- -- but it left the return itself invisible. A product selling 1,019 and
-- taking 4 back reads identically to one selling 1,015 clean.
--
-- Requested for the Overview product table: show the returned quantity and
-- its value beside the net figures they explain.
--
-- WHERE THE NUMBERS COME FROM.
--
-- dashboard_product_month and dashboard_product_place_month gain refund_units
-- and refund_revenue, populated by the same pass that already builds them:
--
--     sum(l.qty)            filter (where l.move_type = 'out_refund')
--     sum(l.price_subtotal) filter (where l.move_type = 'out_refund')
--
-- No second scan of the invoice lines, and both refresh functions keep their
-- existing incremental cutoff. product_facts then reads them on the summary
-- routes and computes them directly on the two line routes, so all seven
-- branches of file 59's period_parts carry the pair and the partial-month
-- edges stay exact.
--
-- THE SIGN.
--
-- Stored with the sign the lines carry, which is negative. product_facts
-- negates it once, in period_agg, so the column reads as a magnitude: a
-- return of four units is 4, not -4, under a heading that already says
-- "returned". A negative number under that heading is a double negative and
-- gets read as an addition.
--
-- Checked before relying on it: of 11,125 posted refund lines, every single
-- one has negative qty, and the only 522 with POSITIVE price_subtotal are all
-- product 8, [DISC] -- a discount being reversed on a credit note, which
-- correctly adds money back. Overview excludes [DISC] outright, so no real
-- product can produce a negative magnitude here.
--
-- WHAT THESE COLUMNS ARE NOT.
--
-- They are not a further deduction. units and revenue have ALREADY had them
-- subtracted; these two say how much of the gross came back. Subtracting them
-- again double-counts. The table carries a note saying so, because the
-- adjacency alone will not stop someone reaching for a calculator.
--
-- Verified: refund_units and refund_revenue match the raw invoice lines with
-- ZERO mismatches across all 10,356 product-month rows and all 150,410
-- product-place-month rows. product_facts matches the lines with zero product
-- mismatches on six window shapes -- whole month, partial window, single day,
-- full year, place filter, salesperson filter.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.
-- ===========================================================================

alter table public.dashboard_product_month
  add column if not exists refund_units   numeric,
  add column if not exists refund_revenue numeric;

alter table public.dashboard_product_place_month
  add column if not exists refund_units   numeric,
  add column if not exists refund_revenue numeric;

-- ---------------------------------------------------------------------------
-- The two refresh functions. Unchanged apart from the two filtered sums.
-- ---------------------------------------------------------------------------

create or replace function public.refresh_product_month(p_since date default null)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  n bigint;
  -- date_trunc, so that "since 22 June" means "rebuild June entirely".
  -- Rebuilding a partial month is never wanted here: the table grain IS the
  -- month, and half a month under a whole month key is a wrong number rather
  -- than a missing one.
  cutoff date := date_trunc('month', coalesce(p_since, date '1900-01-01'))::date;
begin
  delete from public.dashboard_product_month where month >= cutoff;

  insert into public.dashboard_product_month
    (product_id, month, units, revenue, margin, invoices, customers, govs,
     refund_units, refund_revenue, updated_at)
  select l.product_id,
         date_trunc('month', l.invoice_date)::date,
         sum(l.qty),
         sum(l.price_subtotal),
         sum(l.price_margin),
         count(distinct l.move_id),
         count(distinct l.partner_id),
         count(distinct l.gov),
         -- The refund side on its own. units and revenue above are NET -- the
         -- refunds are already subtracted inside them -- so these two are not
         -- another slice to add, they are the part of the gross that was given
         -- back. Stored with the sign the lines carry, negative for every real
         -- product; product_facts flips it so the column reads as a magnitude.
         sum(l.qty)            filter (where l.move_type = 'out_refund'),
         sum(l.price_subtotal) filter (where l.move_type = 'out_refund'),
         now()
  from public.dashboard_invoice_lines l
  where l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.product_id is not null
    and l.invoice_date >= cutoff
  group by 1, 2;

  get diagnostics n = row_count;
  return n;
end;
$fn$;

create or replace function public.refresh_place_month(p_since date default null)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  n bigint;
  -- date_trunc for the reason file 27 documents: the delete compares against a
  -- column that only holds month starts, so a mid-month cutoff leaves the
  -- oldest month behind and the insert then collides with it.
  cutoff date := date_trunc('month', coalesce(p_since, date '1900-01-01'))::date;
begin
  delete from public.dashboard_product_place_month where month >= cutoff;

  insert into public.dashboard_product_place_month
    (product_id, gov, city, month, units, revenue, margin, invoices,
     refund_units, refund_revenue, updated_at)
  select l.product_id,
         coalesce(l.gov, ''), coalesce(l.city, ''),
         date_trunc('month', l.invoice_date)::date,
         sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
         count(distinct l.move_id),
         sum(l.qty)            filter (where l.move_type = 'out_refund'),
         sum(l.price_subtotal) filter (where l.move_type = 'out_refund'),
         now()
  from public.dashboard_invoice_lines l
  where l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.product_id is not null
    and l.invoice_date >= cutoff
  group by 1, 2, 3, 4;

  get diagnostics n = row_count;
  return n;
end;
$fn$;

-- file 54's lockdown: these rebuild summaries and must never be callable with
-- the anon key, nor by a signed-in user. The sync worker holds service_role.
revoke execute on function public.refresh_product_month(date) from public, anon, authenticated;
revoke execute on function public.refresh_place_month(date)   from public, anon, authenticated;

-- Backfill. Both take a null cutoff, which rebuilds every month from 1900,
-- because the two new columns are null for every existing row.
select public.refresh_product_month(null);
select public.refresh_place_month(null);

-- A full rebuild replaces every row, so the planner's statistics describe a
-- table that no longer exists. Skipping this cost real time: the default
-- Overview window measured 918 ms straight after the backfill and 54 ms once
-- the statistics were current. Not VACUUM -- that cannot run in a transaction
-- block, and the autovacuum will get to the dead rows on its own.
analyze public.dashboard_product_month;
analyze public.dashboard_product_place_month;

-- ---------------------------------------------------------------------------
-- product_facts gains returned_units and returned_value.
--
-- The signature changes, so this is a DROP and CREATE, not a REPLACE. Grants
-- go with the dropped function and PUBLIC would otherwise get EXECUTE back by
-- default, so file 54's lockdown is re-applied at the end.
--
-- The body below is file 59's, with six edits, all inside period_parts:
--   * the unfiltered month summary reads m.refund_units / m.refund_revenue
--     and, being the UNION's first branch, names them for the rest
--   * the place summary reads pm.refund_units / pm.refund_revenue
--   * all five invoice-line branches -- four partial-month edges plus the
--     salesperson/customer route -- sum the out_refund lines directly
--   * period_agg folds and NEGATES, turning the stored negative into the
--     magnitude the column heading implies
--   * the final select emits both under the same permission gates as the
--     figures they break down
-- ---------------------------------------------------------------------------

drop function if exists public.product_facts(date,date,text,text,bigint,text,text,text);

create function public.product_facts(
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
  velocity_90d       numeric,
  -- NET figures above, the returned part of them below. Not a further
  -- deduction: units and revenue have already had these subtracted.
  returned_units     numeric,
  returned_value     numeric
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
           sum(m.invoices) as distinct_invoices,
           sum(m.refund_units) as returned_units_raw,
           sum(m.refund_revenue) as returned_value_raw
    from public.dashboard_product_month m
    where (select not needs_lines and not has_place from route)
      and m.month >= (select m_lo from span)
      and m.month <= (select m_hi from span)
    group by m.product_id
    union all
    -- unfiltered, leading partial month: exact to the day
    select l.product_id,
           sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
           null::bigint, null::bigint, count(distinct l.move_id),
           sum(l.qty)            filter (where l.move_type = 'out_refund'),
           sum(l.price_subtotal) filter (where l.move_type = 'out_refund')
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
           null::bigint, null::bigint, count(distinct l.move_id),
           sum(l.qty)            filter (where l.move_type = 'out_refund'),
           sum(l.price_subtotal) filter (where l.move_type = 'out_refund')
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
           sum(pm.invoices),
           sum(pm.refund_units), sum(pm.refund_revenue)
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
           null::bigint, null::bigint, count(distinct l.move_id),
           sum(l.qty)            filter (where l.move_type = 'out_refund'),
           sum(l.price_subtotal) filter (where l.move_type = 'out_refund')
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
           null::bigint, null::bigint, count(distinct l.move_id),
           sum(l.qty)            filter (where l.move_type = 'out_refund'),
           sum(l.price_subtotal) filter (where l.move_type = 'out_refund')
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
           count(distinct l.move_id),
           sum(l.qty)            filter (where l.move_type = 'out_refund'),
           sum(l.price_subtotal) filter (where l.move_type = 'out_refund')
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
           sum(distinct_invoices)  as distinct_invoices,
           -sum(returned_units_raw) as returned_units,
           -sum(returned_value_raw) as returned_value
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
    case when pm.t_lines then greatest(coalesce(tr.units_90d, 0) / 3.0, 0) end,
    case when pm.t_lines then coalesce(pe.returned_units, 0) end,
    case when pm.t_lines and pm.c_revenue then coalesce(pe.returned_value, 0) end
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

revoke execute on function public.product_facts(date,date,text,text,bigint,text,text,text)
  from public, anon;
grant execute on function public.product_facts(date,date,text,text,bigint,text,text,text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- overview_facts carries the pair out through the top-products JSON. One
-- addition to top_rows and nothing else, so it is patched in place rather
-- than restated: the anchor check makes re-running this file a no-op instead
-- of inserting the keys twice.
-- ---------------------------------------------------------------------------

do $do$
declare s text; b text;
begin
  select prosrc into s from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'overview_facts';
  if s is null then raise exception 'overview_facts not found'; end if;

  if position('''returned_units'', returned_units' in s) > 0 then
    raise notice 'overview_facts already carries the returned columns; nothing to do';
    return;
  end if;

  b := s;
  s := replace(s,
    '''last_invoiced'', last_invoiced, ''velocity_90d'', velocity_90d,',
    '''last_invoiced'', last_invoiced, ''velocity_90d'', velocity_90d,' || chr(13) || chr(10) ||
    '               ''returned_units'', returned_units,' || chr(13) || chr(10) ||
    '               ''returned_value'', returned_value,');
  if s = b then raise exception 'top_rows anchor not found'; end if;

  execute 'create or replace function public.overview_facts('
    || 'p_from date, p_to date, p_salesperson text default null, p_gov text default null, '
    || 'p_customer bigint default null, p_category text default null, '
    || 'p_brand text default null, p_city text default null, '
    || 'p_idle_days integer default 90, p_top integer default 200, p_unsold integer default 50) '
    || 'returns table (products bigint, sold bigint, units numeric, revenue numeric, '
    || 'stock_value numeric, frozen_count bigint, frozen_value numeric, '
    || 'unsold_count bigint, unsold_value numeric, top jsonb, unsold jsonb, by_category jsonb) '
    || 'language sql stable security invoker as ' || quote_literal(s);
end $do$;

revoke execute on function
  public.overview_facts(date,date,text,text,bigint,text,text,text,integer,integer,integer)
  from public, anon;
grant execute on function
  public.overview_facts(date,date,text,text,bigint,text,text,text,integer,integer,integer)
  to authenticated;
