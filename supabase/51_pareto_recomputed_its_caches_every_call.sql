-- ===========================================================================
-- 51. Customers 80/20: two CTEs rebuilt yesterday's answer on every call
-- ===========================================================================
-- This is NOT the file 50 header's "file 51". That one routes p_category and
-- p_agency onto dashboard_partner_mix_month and is still unwritten -- it is
-- now file 52. This file was written first because it is independent of the
-- mix summary and fixes the UNFILTERED path, which file 50's own table shows
-- is the slowest thing left once category and agency are excluded:
--
--   filter          min         max
--   none          2,405 ms    4,671 ms   <-- this file
--   +gov          1,263 ms    1,594 ms
--   +salesperson    582 ms      804 ms
--   +category    10,931 ms   27,540 ms   <-- file 52
--   +agency       6,144 ms   15,880 ms   <-- file 52
--
-- From pg_stat_statements, customers_pareto was the most expensive RPC in the
-- database by total time: 572 calls, 3,860 ms mean, 2,208 SECONDS total, and
-- 200 of those calls died at the authenticated role's 20 s statement_timeout.
--
-- EXPLAIN (ANALYZE, BUFFERS) on a fully warm cache, no filters:
--
--   Execution Time: 241.374 ms
--   Buffers: shared hit=10687
--     of which  klass      4,511   (42%)
--               last_seen    532
--
-- WHAT THOSE TWO CTEs WERE DOING
--
--   klass      select * from public.customer_class(p_class_year)
--              An index scan over ~20,000 dashboard_partner_month rows,
--              aggregating a full calendar year, on every single call.
--
--   last_seen  select partner_id, max(month) ... group by partner_id
--              A full seq scan of all 39,973 partner_month rows, to compute a
--              max() that only moves when the nightly sync runs.
--
-- NEITHER IS DEAD CODE, which is what makes this different from file 46. My
-- first reading was that klass was discarded when p_class is null and could be
-- gated the way file 46 gated product_facts' invoice-line branch. That was
-- wrong, and gating it would have silently changed the page:
--
--     coalesce(k.cls, 'C')                              -- the cls column
--     case when pm.c_revenue then coalesce(k.avg_monthly, 0) end
--     ls.m                                              -- last_purchase
--
-- klass feeds cls and avg_monthly on EVERY row regardless of p_class, and
-- last_seen feeds last_purchase. Gate them and every customer reads class 'C'
-- with no last purchase date. They are not discardable -- they are CACHEABLE,
-- which is a different fix. Nothing here is gated; both CTEs still produce
-- exactly the rows they produced before, just read instead of recomputed.
--
-- AFTER, same query, same warm cache:
--
--   Execution Time:  79.516 ms   (was 241.374)
--   Planning Time:    5.053 ms   (was  13.672)
--   Buffers: shared hit=5735     (was 10,687, -46%)
--     of which  klass         67   (was 4,511)
--               last_seen     27   (was   532)
--
-- VERIFIED BEFORE SWAPPING ANYTHING. The rewritten body was run inline against
-- the live function and diffed with EXCEPT ALL in both directions:
--
--   default call   3,100 rows vs 3,100 rows   0 differences
--   p_class='A'      305 rows vs   305 rows   0 differences
--
-- and after swapping: 3,100 default rows, 305 class-A rows, last_purchase
-- non-null on all 3,100, 3 distinct classes, 294 class-A inside the window
-- (the 11 missing are class-A accounts that bought nothing in 2026, which is
-- file 32's roster union doing its job).
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. The two caches
-- ---------------------------------------------------------------------------
create table if not exists public.dashboard_customer_class (
  partner_id  bigint      not null,
  year        integer     not null,
  avg_monthly numeric     not null default 0,
  cls         text        not null,
  updated_at  timestamptz not null default now(),
  primary key (partner_id, year)
);

comment on table public.dashboard_customer_class is
  'Nightly cache of customer_class(year) with its default A/B thresholds. Read by customers_pareto. Rebuilt by refresh_customer_class().';

create table if not exists public.dashboard_partner_lastseen (
  partner_id bigint      primary key,
  last_month date,
  updated_at timestamptz not null default now()
);

comment on table public.dashboard_partner_lastseen is
  'Nightly cache of max(month) per partner from dashboard_partner_month. Read by customers_pareto as last_purchase.';

-- Both derive from dashboard_partner_month, whose policy is `true`. Matching
-- it keeps the visibility of the derived data identical to its source.
--
-- customers_pareto is SECURITY INVOKER. Without these policies it does not
-- error -- it returns a page with every customer classed 'C' and no last
-- purchase date, which is the silent-empty-result trap the supabase README
-- warns about in a different form.
alter table public.dashboard_customer_class   enable row level security;
alter table public.dashboard_partner_lastseen enable row level security;

drop policy if exists customer_class_read on public.dashboard_customer_class;
create policy customer_class_read on public.dashboard_customer_class
  for select to authenticated using (true);

drop policy if exists partner_lastseen_read on public.dashboard_partner_lastseen;
create policy partner_lastseen_read on public.dashboard_partner_lastseen
  for select to authenticated using (true);


-- ---------------------------------------------------------------------------
-- 2. Rebuilding them
-- ---------------------------------------------------------------------------
-- Every year present in partner_month -- 2024, 2025, 2026 today, 8,993 rows.
-- customers_pareto takes p_class_year as a parameter, so a cache keyed only to
-- the current year would silently return nothing for any other year and hand
-- every customer class 'C'.
--
-- Delegates to customer_class() rather than restating its thresholds. That
-- function now has exactly one caller and it is this one -- verified against
-- every function body in public -- so it is the definition rather than dead
-- code, and a cached class cannot drift from the function it replaced.
create or replace function public.refresh_customer_class()
returns bigint
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  y integer;
  n bigint := 0;
  k bigint;
begin
  delete from public.dashboard_customer_class where true;

  for y in
    select distinct extract(year from month)::integer
      from public.dashboard_partner_month
     order by 1
  loop
    insert into public.dashboard_customer_class
           (partner_id, year, avg_monthly, cls, updated_at)
    select c.partner_id, y, c.avg_monthly, c.cls, now()
      from public.customer_class(y) c
    on conflict (partner_id, year) do update
      set avg_monthly = excluded.avg_monthly,
          cls         = excluded.cls,
          updated_at  = excluded.updated_at;

    get diagnostics k = row_count;
    n := n + k;
  end loop;

  return n;
end;
$function$;

create or replace function public.refresh_partner_lastseen()
returns bigint
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare n bigint;
begin
  delete from public.dashboard_partner_lastseen where true;

  insert into public.dashboard_partner_lastseen (partner_id, last_month, updated_at)
  select partner_id, max(month), now()
    from public.dashboard_partner_month
   group by partner_id;

  get diagnostics n = row_count;
  return n;
end;
$function$;

-- File 24 made the refreshes callable because the sync needs them. These two
-- are different: nothing outside the nightly chain calls them, and the sync
-- worker holds the service_role key, which bypasses grants entirely. So the
-- browser roles get no execute -- the same reasoning file 24 applied in the
-- other direction, for a job the browser genuinely did have to trigger.
revoke execute on function public.refresh_customer_class()   from anon, authenticated;
revoke execute on function public.refresh_partner_lastseen() from anon, authenticated;


-- ---------------------------------------------------------------------------
-- 3. Into the nightly chain
-- ---------------------------------------------------------------------------
-- refresh_after_sync() calls refresh_partner_month() before it calls
-- refresh_dashboard_summaries(), so partner_month -- the source both caches
-- read -- is already rebuilt by the time these two run.
--
-- Body below is unchanged from file 43's version except the two PERFORM lines
-- at the end.
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
  -- further back needs a full rebuild: select public.refresh_place_month();
  perform public.refresh_place_month((current_date - interval '2 months')::date);

  -- File 51: the two customers_pareto caches.
  perform public.refresh_customer_class();
  perform public.refresh_partner_lastseen();
end;
$function$;


-- ---------------------------------------------------------------------------
-- 4. Reading them
-- ---------------------------------------------------------------------------
-- Exactly two CTEs differ from the previous definition. Everything else is
-- identical, deliberately, so the diff is auditable and the only thing under
-- test is where klass and last_seen get their rows.
--
-- The cross-join dead-branch guard that file 48's closing note flags --
--
--     from public.dashboard_partner_month m, bounds b, by_product bp
--     where not bp.on_
--
-- -- is LEFT ALONE here. It is the construct file 46 had to remove from
-- product_facts, and it is still worth removing. But EXPLAIN on this function
-- shows both invoice-line branches reporting `never executed`, so unlike
-- product_facts the planner is not inverting the join today. Changing it is a
-- real semantic risk for no measured gain, and it belongs in the file that
-- rewrites these branches anyway -- file 52.
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
  bounds as (
    select p_from as f, p_to as t,
           coalesce(p_prev_from, (p_from - interval '1 year')::date) as pf,
           coalesce(p_prev_to,   (p_to   - interval '1 year')::date) as pt
  ),
  -- CHANGED: the nightly cache, not customer_class() inline. Same rows, same
  -- thresholds -- refresh_customer_class() builds it by calling that very
  -- function. Was 4,511 of this query's 10,687 buffers.
  klass as (
    select partner_id, avg_monthly, cls
      from public.dashboard_customer_class
     where year = p_class_year
  ),
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
    from public.dashboard_partner_month m, bounds b, by_product bp
    where not bp.on_
      and m.month >= date_trunc('month', b.pf)::date
      and m.month <= date_trunc('month', b.pt)::date
    group by m.partner_id
    union all
    select l.partner_id, sum(l.price_subtotal), sum(l.price_margin),
           sum(l.qty), count(distinct l.move_id)
    from public.dashboard_invoice_lines l, bounds b, by_product bp
    where bp.on_
      and l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
      and l.invoice_date >= b.pf and l.invoice_date <= b.pt
      and (p_category is null or l.category = p_category)
      and (p_agency   is null or l.brand    = p_agency)
    group by l.partner_id
  ),
  -- CHANGED: the nightly cache. Was a full seq scan of all 39,973
  -- partner_month rows on every call, 532 buffers, to recompute a max() that
  -- only moves when the sync runs.
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
-- 5. Populate now, so the page is not reading empty tables
-- ---------------------------------------------------------------------------
select public.refresh_customer_class()   as customer_class_rows;   -- expect 8993
select public.refresh_partner_lastseen() as partner_lastseen_rows; -- expect 4229

analyze public.dashboard_customer_class;
analyze public.dashboard_partner_lastseen;


-- ---------------------------------------------------------------------------
-- 6. The caches must equal the live computation
-- ---------------------------------------------------------------------------
-- Both must return 0. This is a tighter check than diffing customers_pareto's
-- full output, and it is the thing that can actually rot: if the nightly
-- refresh is ever skipped or reordered, THIS is what catches it.
with years as (
  select distinct extract(year from month)::integer as y
    from public.dashboard_partner_month
),
live as (
  select y.y as year, c.partner_id, c.avg_monthly, c.cls
    from years y, lateral public.customer_class(y.y) c
),
class_diff as (
  select 1 from live l
  full outer join public.dashboard_customer_class c
    on c.year = l.year and c.partner_id = l.partner_id
  where l.partner_id is null or c.partner_id is null
     or l.avg_monthly is distinct from c.avg_monthly
     or l.cls         is distinct from c.cls
),
live_ls as (
  select partner_id, max(month) as last_month
    from public.dashboard_partner_month group by partner_id
),
ls_diff as (
  select 1 from live_ls l
  full outer join public.dashboard_partner_lastseen c on c.partner_id = l.partner_id
  where l.partner_id is null or c.partner_id is null
     or l.last_month is distinct from c.last_month
)
select (select count(*) from class_diff) as customer_class_mismatches,
       (select count(*) from ls_diff)    as lastseen_mismatches;


-- ---------------------------------------------------------------------------
-- A WARNING FOR WHOEVER READS pg_stat_user_indexes NEXT
-- ---------------------------------------------------------------------------
-- While working on this file I read idx_scan = 0 on idx_inv_lines_brand_date
-- and idx_inv_lines_rep_date, and dropped both as unused. Supabase's own
-- performance advisor recommends exactly that, by name.
--
-- Both were WRONG to drop. File 48 created them days earlier, and the counter
-- was zero because it had not had time to move -- not because nothing wants
-- them. idx_inv_lines_rep_date in particular is what file 48 built to fix
-- Overview + salesperson in product_facts, measured at 1,059-12,988 ms.
--
-- Both were rebuilt CONCURRENTLY within the hour and are valid. Nothing in
-- this file drops an index. Before trusting idx_scan on this table, check
-- whether the index is older than the statistics: an index younger than the
-- last stats reset has a meaningless count, and file 48's are recent enough
-- that this file's author got it wrong once already.
-- ---------------------------------------------------------------------------
