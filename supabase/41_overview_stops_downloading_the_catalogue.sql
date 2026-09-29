-- ===========================================================================
-- 41. Overview downloaded 1,431 products to show 60
-- ===========================================================================
-- Measured signed in as a real user (role authenticated, RLS on, 20s cap):
--
--   product_facts   2 requests   2.7s   1,431 rows x 20 columns
--   27 months + city filter               13.4s
--
-- The page fetches every product, in two requests that each re-run the whole
-- function, then does sums, counts, sorting and classification in JavaScript.
-- Every one of those is a SUM, a COUNT or a TOP N, and Postgres does them in
-- milliseconds. The 1,431 rows exist only because the page asked for them.
--
-- WHY THESE ARE WRAPPERS AROUND product_facts RATHER THAN NEW QUERIES
--
-- Every tile has to keep its current value exactly. Re-implementing the
-- filters, the exclusions, the masking and the summary/lines routing in four
-- new functions is four new chances to be subtly wrong -- and "subtly wrong
-- but faster" is the worst outcome available here.
--
-- So each one selects FROM product_facts. Identical semantics by construction:
-- if product_facts changes, these follow. The cost is real but small --
-- product_facts is 12ms server-side since file 34, and what made the page slow
-- was never the query, it was shipping 1,431 rows to Baghdad.
--
-- The 1000-row cap also stops mattering. It applies to what PostgREST returns,
-- not to what a function sees internally, so product_summary aggregates all
-- 1,431 rows and returns one.
--
-- IDLENESS IS MEASURED FROM p_to, NOT FROM TODAY. That is what the page does,
-- and it is deliberate: Overview must agree with the Frozen capital and
-- Reorder pages, which measure from the date you picked. Measuring from today
-- made the same product read differently on two pages for the same filter.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. The tiles: one row
-- ---------------------------------------------------------------------------
-- frozen and unsold are the same shape with different thresholds. frozen uses
-- 60 days to match THRESHOLDS.IDLE_DAYS and the Frozen capital page; unsold
-- uses whatever the 30/60/90 control is set to.
--
-- `dormant` never occurs on this page -- classifyStock is called with
-- peak_month null, so its dormant branch is unreachable and frozen is exactly
-- the `dead` case: has stock, and has not sold within the threshold.
create or replace function public.product_summary(
  p_from        date,
  p_to          date,
  p_salesperson text    default null,
  p_gov         text    default null,
  p_customer    bigint  default null,
  p_category    text    default null,
  p_brand       text    default null,
  p_city        text    default null,
  p_idle_days   integer default 90
)
returns table (
  products      bigint,
  sold          bigint,
  units         numeric,
  revenue       numeric,
  stock_value   numeric,
  frozen_count  bigint,
  frozen_value  numeric,
  unsold_count  bigint,
  unsold_value  numeric
)
language sql
stable
security invoker
as $$
  with f as (
    select * from public.product_facts(
      p_from, p_to, p_salesperson, p_gov, p_customer, p_category, p_brand, p_city)
  ),
  m as (
    select *,
           case when f.last_invoiced is null then null
                else (p_to - f.last_invoiced) end as idle
    from f
  )
  select count(*),
         count(*) filter (where coalesce(units, 0) > 0),
         sum(coalesce(units, 0)),
         -- NULL, not 0, when revenue is masked: summing a column of nulls with
         -- coalesce would report zero revenue to a restricted role, which reads
         -- as a collapse rather than as a permission.
         case when bool_or(revenue is not null) then sum(coalesce(revenue, 0)) end,
         case when bool_or(stock_value is not null)
              then sum(greatest(coalesce(stock_value, 0), 0)) end,
         count(*) filter (
           where coalesce(on_hand, 0) > 0 and (idle is null or idle >= 60)),
         case when bool_or(stock_value is not null) then sum(coalesce(stock_value, 0))
              filter (where coalesce(on_hand, 0) > 0 and (idle is null or idle >= 60)) end,
         count(*) filter (
           where coalesce(on_hand, 0) > 0
             and (idle is null or idle >= greatest(p_idle_days, 1))),
         case when bool_or(stock_value is not null) then sum(coalesce(stock_value, 0))
              filter (where coalesce(on_hand, 0) > 0
                        and (idle is null or idle >= greatest(p_idle_days, 1))) end
  from m;
$$;

grant execute on function public.product_summary(
  date, date, text, text, bigint, text, text, text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. The rows actually shown
-- ---------------------------------------------------------------------------
-- 200 by default: the table renders 60 and the bars 12, so 200 leaves room for
-- client-side sorting without another round trip, and stays far under the
-- 1000-row cap so this is always ONE request.
--
-- ABC comes back from here rather than being computed in the browser, and it
-- is MORE correct for it. The page ranked whatever rows it had received; this
-- ranks every product the filters match, then returns the class for the ones
-- shown. A product's class no longer depends on how many rows fitted in the
-- response.
create or replace function public.product_top(
  p_from        date,
  p_to          date,
  p_salesperson text    default null,
  p_gov         text    default null,
  p_customer    bigint  default null,
  p_category    text    default null,
  p_brand       text    default null,
  p_city        text    default null,
  p_limit       integer default 200,
  p_order       text    default 'revenue'
)
returns table (
  product_id     bigint,
  sku            text,
  name           text,
  category       text,
  brand          text,
  uom            text,
  units          numeric,
  revenue        numeric,
  margin         numeric,
  margin_pct     numeric,
  realized_price numeric,
  last_invoiced  date,
  on_hand        numeric,
  stock_value    numeric,
  velocity_90d   numeric,
  idle           integer,
  cls            text
)
language sql
stable
security invoker
as $$
  with f as (
    select * from public.product_facts(
      p_from, p_to, p_salesperson, p_gov, p_customer, p_category, p_brand, p_city)
  ),
  ranked as (
    select f.*,
           case when f.last_invoiced is null then null
                else (p_to - f.last_invoiced) end as idle,
           -- Cumulative share of revenue, over EVERY matching product.
           case when sum(greatest(coalesce(f.revenue, 0), 0)) over () > 0
                then sum(greatest(coalesce(f.revenue, 0), 0))
                       over (order by f.revenue desc nulls last
                             rows between unbounded preceding and current row)
                     / sum(greatest(coalesce(f.revenue, 0), 0)) over ()
           end as cum
    from f
  )
  select product_id, sku, name, category, brand, uom,
         units, revenue, margin, margin_pct, realized_price,
         last_invoiced, on_hand, stock_value, velocity_90d,
         idle::integer,
         -- Same cut-offs calc.js uses: A to 80% of revenue, B to 95%, C the
         -- tail. A product with no positive revenue is C by definition rather
         -- than ranked, which is also what abcClasses() does.
         case when coalesce(revenue, 0) <= 0 then 'C'
              when cum is null then 'C'
              when cum <= 0.80 then 'A'
              when cum <= 0.95 then 'B'
              else 'C' end
  from ranked
  order by case when p_order = 'units' then units else revenue end desc nulls last
  limit greatest(coalesce(p_limit, 200), 1);
$$;

grant execute on function public.product_top(
  date, date, text, text, bigint, text, text, text, integer, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. The unsold list
-- ---------------------------------------------------------------------------
-- Its own function, and this is exactly why a plain LIMIT on product_facts
-- would not have worked. This list is products that have NOT sold. Rank the
-- catalogue by revenue and take the top 200 and you have selected precisely
-- the products that did sell -- the ones this card exists to show are the ones
-- the limit removes. It has to be ordered by stock value, not revenue.
create or replace function public.product_unsold(
  p_from        date,
  p_to          date,
  p_salesperson text    default null,
  p_gov         text    default null,
  p_customer    bigint  default null,
  p_category    text    default null,
  p_brand       text    default null,
  p_city        text    default null,
  p_idle_days   integer default 90,
  p_limit       integer default 50
)
returns table (
  product_id    bigint,
  sku           text,
  name          text,
  category      text,
  brand         text,
  on_hand       numeric,
  stock_value   numeric,
  last_invoiced date,
  idle          integer
)
language sql
stable
security invoker
as $$
  with f as (
    select * from public.product_facts(
      p_from, p_to, p_salesperson, p_gov, p_customer, p_category, p_brand, p_city)
  )
  select product_id, sku, name, category, brand, on_hand, stock_value, last_invoiced,
         (case when last_invoiced is null then null
               else (p_to - last_invoiced) end)::integer
  from f
  where coalesce(on_hand, 0) > 0
    and (last_invoiced is null or (p_to - last_invoiced) >= greatest(p_idle_days, 1))
  order by stock_value desc nulls last
  limit greatest(coalesce(p_limit, 50), 1);
$$;

grant execute on function public.product_unsold(
  date, date, text, text, bigint, text, text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. The category mix
-- ---------------------------------------------------------------------------
create or replace function public.product_by_category(
  p_from        date,
  p_to          date,
  p_salesperson text    default null,
  p_gov         text    default null,
  p_customer    bigint  default null,
  p_category    text    default null,
  p_brand       text    default null,
  p_city        text    default null
)
returns table (category text, revenue numeric, units numeric, products bigint)
language sql
stable
security invoker
as $$
  select coalesce(category, '-'),
         case when bool_or(revenue is not null) then sum(coalesce(revenue, 0)) end,
         sum(coalesce(units, 0)),
         count(*)
  from public.product_facts(
    p_from, p_to, p_salesperson, p_gov, p_customer, p_category, p_brand, p_city)
  group by 1
  order by 2 desc nulls last;
$$;

grant execute on function public.product_by_category(
  date, date, text, text, bigint, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Prove the tiles are unchanged
-- ---------------------------------------------------------------------------
-- Left column: what product_summary now reports.
-- Right column: the same figures computed the way the page does today.
-- Every pair must match.
with page as (
  select count(*) as products,
         count(*) filter (where coalesce(units, 0) > 0) as sold,
         sum(coalesce(units, 0)) as units,
         sum(coalesce(revenue, 0)) as revenue,
         sum(greatest(coalesce(stock_value, 0), 0)) as stock_value
  from public.product_facts(date '2025-08-15', date '2026-08-15')
),
srv as (select * from public.product_summary(date '2025-08-15', date '2026-08-15'))
select 'products' as tile, srv.products::text as new, page.products::text as old,
       srv.products = page.products as same from srv, page
union all
select 'sold', srv.sold::text, page.sold::text, srv.sold = page.sold from srv, page
union all
select 'units', round(srv.units)::text, round(page.units)::text,
       round(srv.units) = round(page.units) from srv, page
union all
select 'revenue', round(srv.revenue)::text, round(page.revenue)::text,
       round(srv.revenue) = round(page.revenue) from srv, page
union all
select 'stock_value', round(srv.stock_value)::text, round(page.stock_value)::text,
       round(srv.stock_value) = round(page.stock_value) from srv, page;
