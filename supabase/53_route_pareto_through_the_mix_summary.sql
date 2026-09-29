-- ===========================================================================
-- 53. Customers 80/20 stops reading the invoice lines
-- ===========================================================================
-- This is the file 50 header's "file 51". It is 53 because 51 went to the
-- klass/last_seen caches and 52 to narrowing the dashboard to two pages.
--
-- File 50 built dashboard_partner_mix_month and stopped there, on the same
-- split as 43/44 -- build in one file, route in the next -- which is what made
-- 44 recoverable when it turned out to be wrong. This is the routing half.
--
-- WHAT FILE 50 MEASURED, and what it was right about:
--
--   category  198,196 rows   exactly its estimate
--   brand     265,945 rows
--   TOTAL     464,141 rows   62.8% of the invoice lines
--
-- Its own abort threshold was "much above ~500,000, reconsider". 464,141 is
-- under it, so the trade stands.
--
-- Both kinds independently reconcile against the lines they summarise:
--
--   category revenue  32,061,308,554  = lines revenue
--   brand    revenue  32,061,308,554  = lines revenue
--
-- and read the way this file reads it -- one value, summed over months only --
-- a single category agrees on all four measures, INCLUDING the one file 50
-- was careful about:
--
--   summary invoices 19,933 = lines invoices 19,933
--
-- WHAT FILE 50 UNDERSTATED: the table is 109 MB, not the ~29 MB its comparison
-- to dashboard_product_place_month implies. place_month is 150,410 narrow
-- rows; this is 464,141 rows each carrying a long Arabic `value` string plus
-- two indexes. Against a 224 MB shared_buffers that is not free. It is still
-- the right trade -- a query reads the slice for ONE value, not 109 MB, where
-- before it read a 348 MB table -- but if buffer pressure is ever the question
-- again, normalising `value` to an id is where the next 60 MB is.
--
-- WHERE THE TIME ACTUALLY WENT. File 49 asked and did not answer; file 50
-- guessed "an index cannot fix a query whose cost is the scan". The plan,
-- captured before this change:
--
--   cur    Bitmap Heap Scan  114,113 rows  Heap Blocks: exact=17,977
--          Sort Method: external merge  Disk: 5,688kB
--   prev   Bitmap Heap Scan   61,271 rows  Heap Blocks: exact= 8,912
--          Sort Method: external merge  Disk: 3,048kB
--
-- Both of file 49's candidates, together: the scan happens TWICE, and the
-- count(distinct move_id) sorts SPILL TO DISK because work_mem is 2,184 kB.
--
-- And a correction to file 49's reasoning: it supposed the planner "stops
-- using idx_inv_lines_category_date and reads the table". It does not. The
-- plan shows Bitmap Index Scan on that index, on the FULL range. File 48's
-- index works. It was never the bottleneck -- 26,889 heap-block fetches and
-- two disk sorts were. Raising work_mem to 24MB removed the spills and moved
-- 14,071 ms to 11,175 ms, which is the size of that half of the problem.
--
-- The summary removes both halves at once: no scan, and `invoices` arrives
-- precomputed so there is no count(distinct) left to sort.
--
-- THE COMBINATION THIS DOES NOT COVER. p_category AND p_agency together still
-- read the lines, exactly as file 50 said it must -- two kinds cannot be
-- intersected from a table keyed by one kind at a time. That path is
-- unchanged and still slow, and the UI can reach it.
--
-- A DELIBERATE SEMANTIC CHANGE. The summary is monthly, so a filtered period
-- now snaps to month boundaries. The UNFILTERED path has always done this --
-- dashboard_partner_month is monthly and cur/prev already wrote
-- date_trunc('month', ...) -- so this makes a category filter agree with the
-- default view instead of disagreeing with it. Mid-month ranges on a category
-- will differ from what they returned yesterday. That is the trade.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run. Requires file 50.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. The nightly chain, with all three summaries
-- ---------------------------------------------------------------------------
-- File 50 and file 51 each shipped their own refresh_dashboard_summaries(),
-- neither knowing about the other: 50 adds the mix summary, 51 adds the
-- customer-class and last-seen caches. Whichever ran last would have silently
-- dropped the other's line. This is the merged definition and it supersedes
-- both -- if a later file touches this function, start from THIS body.
create or replace function public.refresh_dashboard_summaries()
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  insert into public.dashboard_health (metric, value, updated_at)
  select 'invoice_lines', count(*)::text, now() from public.dashboard_invoice_lines
  union all
  select 'date_from', coalesce(min(invoice_date)::text, U&'\2014'), now()
    from public.dashboard_invoice_lines
  union all
  select 'date_to', coalesce(max(invoice_date)::text, U&'\2014'), now()
    from public.dashboard_invoice_lines
  union all
  select 'products', count(*)::text, now() from public.dashboard_products
  union all
  select 'stock_rows', count(*)::text, now() from public.dashboard_stock
  union all
  select 'customers', count(*)::text, now() from public.dashboard_customers
  union all
  select 'stock_snapshots', count(distinct snap_date)::text, now()
    from public.dashboard_stock_history
  union all
  select 'brand_fill_pct',
         coalesce(round(100.0 * count(*) filter (where brand is not null) /
                  nullif(count(*), 0))::text, '0'), now()
    from public.dashboard_invoice_lines
  on conflict (metric) do update
    set value = excluded.value, updated_at = excluded.updated_at;

  delete from public.dashboard_filter_options where true;

  insert into public.dashboard_filter_options (kind, value, n, updated_at)
  select 'gov', gov, count(*), now() from public.dashboard_invoice_lines
    where gov is not null group by gov
  union all
  select 'city', city, count(*), now() from public.dashboard_invoice_lines
    where city is not null group by city
  union all
  select 'salesperson', salesperson, count(*), now() from public.dashboard_invoice_lines
    where salesperson is not null group by salesperson
  union all
  select 'category', category, count(*), now() from public.dashboard_invoice_lines
    where category is not null group by category
  union all
  select 'brand', brand, count(*), now() from public.dashboard_invoice_lines
    where brand is not null group by brand;

  update public.dashboard_product_lastsale set units_90d = 0 where true;

  update public.dashboard_product_lastsale t
     set units_90d = v.units
    from (select l.product_id, sum(l.qty) as units
            from public.dashboard_invoice_lines l
           where l.state = 'posted'
             and l.move_type in ('out_invoice', 'out_refund')
             and l.product_id is not null
             and l.invoice_date > current_date - 90
             and l.invoice_date <= current_date
           group by l.product_id) v
   where t.product_id = v.product_id;

  perform public.refresh_filter_scope();
  -- Two months, matching refresh_after_sync's window. A backfill reaching
  -- further back needs a full rebuild of each of these three:
  --   select public.refresh_place_month();
  --   select public.refresh_partner_mix_month();
  perform public.refresh_place_month((current_date - interval '2 months')::date);
  perform public.refresh_partner_mix_month((current_date - interval '2 months')::date);

  -- File 51's caches. Both read dashboard_partner_month, which
  -- refresh_after_sync rebuilt before calling this.
  perform public.refresh_customer_class();
  perform public.refresh_partner_lastseen();
end;
$function$;


-- ---------------------------------------------------------------------------
-- 2. Three routes for cur and prev, not two
-- ---------------------------------------------------------------------------
-- Gated with scalar subqueries -- `where (select ... from route)` -- and NOT
-- with the cross join this function used to carry:
--
--     from public.dashboard_partner_month m, bounds b, by_product bp
--     where not bp.on_
--
-- File 46 had to remove that construct from product_facts, where the planner
-- inverted the join and ran a dead branch 392,676 times, and file 48's closing
-- note flagged that customers_pareto still had it. A scalar subquery becomes
-- an InitPlan and then a One-Time Filter, which is the form that provably
-- does not execute. With three branches instead of two there are now two dead
-- ones on every call, so this matters more than it did.
create or replace function public.customers_pareto(
  p_from date,
  p_to date,
  p_gov text default null::text,
  p_dept text default null::text,
  p_salesperson text default null::text,
  p_category text default null::text,
  p_agency text default null::text,
  p_prev_from date default null::date,
  p_prev_to date default null::date,
  p_class text default null::text,
  p_class_year integer default 2025
)
returns table(
  partner_id bigint, customer text, gov text, dept text, salesperson text,
  revenue numeric, margin numeric, units numeric, invoices bigint,
  last_purchase date, revenue_prev numeric, margin_prev numeric,
  units_prev numeric, invoices_prev bigint, growth_pct numeric,
  cls text, avg_monthly numeric
)
language sql
stable
as $function$
  with perms as materialized (
    select not ('revenue' = any (h)) as c_revenue,
           not ('margin'  = any (h)) as c_margin
    from (select public.app_my_hidden_columns() as h) z
  ),
  -- One row, read as an InitPlan by every gate below.
  route as (
    select p_category is not null as has_cat,
           p_agency   is not null as has_brand,
           coalesce(p_prev_from, (p_from - interval '1 year')::date) as pf,
           coalesce(p_prev_to,   (p_to   - interval '1 year')::date) as pt,
           case when p_category is not null then 'category' else 'brand' end as kind,
           coalesce(p_category, p_agency) as value
  ),
  -- File 51's cache.
  klass as (
    select partner_id, avg_monthly, cls
      from public.dashboard_customer_class
     where year = p_class_year
  ),
  cur as (
    -- no dimension filter: the partner-by-month summary, as before
    select m.partner_id, sum(m.revenue) revenue, sum(m.margin) margin,
           sum(m.units) units, sum(m.invoices) invoices
    from public.dashboard_partner_month m
    where (select not has_cat and not has_brand from route)
      and m.month >= date_trunc('month', p_from)::date
      and m.month <= date_trunc('month', p_to)::date
    group by m.partner_id
    union all
    -- exactly one of category / agency: file 50's summary
    select x.partner_id, sum(x.revenue), sum(x.margin),
           sum(x.units), sum(x.invoices)
    from public.dashboard_partner_mix_month x
    where (select has_cat <> has_brand from route)
      and x.kind  = (select kind  from route)
      and x.value = (select value from route)
      and x.month >= date_trunc('month', p_from)::date
      and x.month <= date_trunc('month', p_to)::date
    group by x.partner_id
    union all
    -- BOTH: no summary keyed by one kind can intersect two. Still the lines.
    select l.partner_id, sum(l.price_subtotal), sum(l.price_margin),
           sum(l.qty), count(distinct l.move_id)
    from public.dashboard_invoice_lines l
    where (select has_cat and has_brand from route)
      and l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and l.category = p_category
      and l.brand    = p_agency
    group by l.partner_id
  ),
  -- WHO THE PAGE IS ABOUT. Normally the customers who bought in the window.
  -- When a class is asked for, every member of that class as well -- including
  -- the ones with nothing in the window, which is the point of asking.
  roster as (
    select partner_id from cur
    union
    select k.partner_id from klass k
    where p_class is not null and k.cls = p_class
  ),
  prev as (
    select m.partner_id, sum(m.revenue) revenue, sum(m.margin) margin,
           sum(m.units) units, sum(m.invoices) invoices
    from public.dashboard_partner_month m
    where (select not has_cat and not has_brand from route)
      and m.month >= date_trunc('month', (select pf from route))::date
      and m.month <= date_trunc('month', (select pt from route))::date
    group by m.partner_id
    union all
    select x.partner_id, sum(x.revenue), sum(x.margin),
           sum(x.units), sum(x.invoices)
    from public.dashboard_partner_mix_month x
    where (select has_cat <> has_brand from route)
      and x.kind  = (select kind  from route)
      and x.value = (select value from route)
      and x.month >= date_trunc('month', (select pf from route))::date
      and x.month <= date_trunc('month', (select pt from route))::date
    group by x.partner_id
    union all
    select l.partner_id, sum(l.price_subtotal), sum(l.price_margin),
           sum(l.qty), count(distinct l.move_id)
    from public.dashboard_invoice_lines l
    where (select has_cat and has_brand from route)
      and l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
      and l.invoice_date >= (select pf from route)
      and l.invoice_date <= (select pt from route)
      and l.category = p_category
      and l.brand    = p_agency
    group by l.partner_id
  ),
  -- File 51's cache.
  last_seen as (
    select partner_id, last_month as m
      from public.dashboard_partner_lastseen
  )
  select r.partner_id,
         coalesce(dc.complete_name, r.partner_id::text),
         dc.governorate,
         null::text,
         dc.salesperson,
         -- 0, not NULL, for an account with no sales this period. It bought
         -- nothing; that is a number, and the +/-% column needs it to be one.
         case when pm.c_revenue then coalesce(c.revenue, 0) end,
         case when pm.c_margin  then coalesce(c.margin,  0) end,
         coalesce(c.units, 0),
         coalesce(c.invoices, 0),
         ls.m,
         case when pm.c_revenue then coalesce(pv.revenue, 0) end,
         case when pm.c_margin  then coalesce(pv.margin,  0) end,
         coalesce(pv.units, 0),
         coalesce(pv.invoices, 0),
         -- -100% for an account that bought last period and nothing this one.
         -- That is the number this whole change exists to surface, and it is
         -- a real measurement rather than a missing one.
         case when pm.c_revenue and coalesce(pv.revenue, 0) > 0
              then round(100.0 * (coalesce(c.revenue, 0) - pv.revenue) / pv.revenue, 1)
         end,
         coalesce(k.cls, 'C'),
         case when pm.c_revenue then coalesce(k.avg_monthly, 0) end
  from roster r
  cross join perms pm
  left join cur c                              on c.partner_id  = r.partner_id
  left join prev pv                            on pv.partner_id = r.partner_id
  left join last_seen ls                       on ls.partner_id = r.partner_id
  left join public.dashboard_customers dc      on dc.partner_id = r.partner_id
  left join klass k                            on k.partner_id  = r.partner_id
  where (p_gov         is null or dc.governorate = p_gov)
    and (p_salesperson is null or dc.salesperson = p_salesperson)
    and (p_class       is null or coalesce(k.cls, 'C') = p_class)
    and p_dept is null
  order by coalesce(c.revenue, 0) desc nulls last;
$function$;


-- ---------------------------------------------------------------------------
-- 3. The dead branches must be provably dead
-- ---------------------------------------------------------------------------
-- File 46's check, which is why that file exists. Two of the three routes are
-- unreachable on any given call. Read the plan for `One-Time Filter: false`
-- or `never executed` on both -- an `actual rows=0` with real loops means the
-- planner is running them and throwing the rows away, which is what cost
-- product_facts 392,676 iterations.
explain (analyze, buffers, costs off, timing off, summary on)
select * from public.customers_pareto(
  date '2024-06-26', date '2026-08-15', null, null, null,
  U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1');


-- ---------------------------------------------------------------------------
-- 4. The numbers must not move
-- ---------------------------------------------------------------------------
-- Against the invoice lines directly, on the category route. Revenue and
-- customers must match exactly. Invoices must match because an invoice has
-- one date and cannot straddle two months -- file 50 checked that for 2,311
-- of 2,311 partners before building the table.
with pareto as (
  select count(*) as customers, round(sum(revenue)) as revenue,
         sum(invoices) as invoices
  from public.customers_pareto(date '2024-06-26', date '2026-08-15', null, null,
                               null, U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1')
  where revenue is not null and revenue <> 0
),
direct as (
  select count(distinct l.partner_id) as customers,
         round(sum(l.price_subtotal)) as revenue,
         count(distinct l.move_id) as invoices
  from public.dashboard_invoice_lines l
  where l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
    and l.partner_id is not null
    and l.category = U&'\062F\0627\064A\062A / \062F\0627\064A\062A 1'
    and l.invoice_date >= date '2024-06-26' and l.invoice_date <= date '2026-08-15'
)
select pareto.revenue as pareto_revenue, direct.revenue as direct_revenue,
       pareto.revenue = direct.revenue as revenue_matches,
       pareto.invoices as pareto_invoices, direct.invoices as direct_invoices,
       pareto.customers as pareto_customers, direct.customers as direct_customers
from pareto, direct;
