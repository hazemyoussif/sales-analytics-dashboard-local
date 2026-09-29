-- ===========================================================================
-- 42. One call, one scan
-- ===========================================================================
-- File 41 replaced a 1,431-row download with four small RPCs. Measured as a
-- real user, best of two:
--
--   scenario            OLD wall   OLD KB      NEW wall   NEW KB
--   12 months             1.37s      742         1.76s      110
--   12 months + city      1.89s      726         1.39s      109
--   27 months             1.49s      752         0.78s      110
--   27 months + city      5.69s      732         3.70s      109
--
-- 85% less data every time, and the bad cases much better. But the DEFAULT
-- view got slower -- 1.37 to 1.76 -- and that is the one people actually look
-- at.
--
-- The reason is not subtle: five parallel calls are five round trips AND five
-- executions of product_facts. When the query is 12ms, the round trips are the
-- whole cost and fewer requests wins. When a city filter makes it 250ms, five
-- executions is 1.2s of database work competing with itself.
--
-- So this does the same work in one statement: product_facts runs ONCE, and
-- four aggregations read that one result. One round trip, one scan.
--
-- WHY jsonb FOR THE LISTS. A function returns one shape, and the tiles are one
-- row while the tables are many. Returning the lists as jsonb keeps it to a
-- single call without inventing a union of unrelated columns. The four
-- functions from file 41 stay -- they are still the honest way to ask for one
-- piece, they are what this is tested against, and nothing is lost by keeping
-- them.
--
-- Masking is inherited, not reimplemented: every column comes from
-- product_facts, which already nulls what a role may not see.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

create or replace function public.overview_facts(
  p_from        date,
  p_to          date,
  p_salesperson text    default null,
  p_gov         text    default null,
  p_customer    bigint  default null,
  p_category    text    default null,
  p_brand       text    default null,
  p_city        text    default null,
  p_idle_days   integer default 90,
  p_top         integer default 200,
  p_unsold      integer default 50
)
returns table (
  products     bigint,
  sold         bigint,
  units        numeric,
  revenue      numeric,
  stock_value  numeric,
  frozen_count bigint,
  frozen_value numeric,
  unsold_count bigint,
  unsold_value numeric,
  top          jsonb,
  unsold       jsonb,
  by_category  jsonb
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
           case when last_invoiced is null then null
                else (p_to - last_invoiced) end as idle
    from f
  ),
  ranked as (
    select m.*,
           case when sum(greatest(coalesce(revenue, 0), 0)) over () > 0
                then sum(greatest(coalesce(revenue, 0), 0))
                       over (order by revenue desc nulls last
                             rows between unbounded preceding and current row)
                     / sum(greatest(coalesce(revenue, 0), 0)) over ()
           end as cum
    from m
  ),
  agg as (
    select count(*) as products,
           count(*) filter (where coalesce(units, 0) > 0) as sold,
           sum(coalesce(units, 0)) as units,
           -- NULL, never 0, when the column is masked. Summing nulls through
           -- coalesce would report zero revenue to a restricted role, which
           -- reads as a collapse rather than as a permission.
           case when bool_or(revenue is not null)
                then sum(coalesce(revenue, 0)) end as revenue,
           case when bool_or(stock_value is not null)
                then sum(greatest(coalesce(stock_value, 0), 0)) end as stock_value,
           count(*) filter (
             where coalesce(on_hand, 0) > 0 and (idle is null or idle >= 60)) as frozen_count,
           case when bool_or(stock_value is not null) then sum(coalesce(stock_value, 0))
                filter (where coalesce(on_hand, 0) > 0
                          and (idle is null or idle >= 60)) end as frozen_value,
           count(*) filter (
             where coalesce(on_hand, 0) > 0
               and (idle is null or idle >= greatest(p_idle_days, 1))) as unsold_count,
           case when bool_or(stock_value is not null) then sum(coalesce(stock_value, 0))
                filter (where coalesce(on_hand, 0) > 0
                          and (idle is null or idle >= greatest(p_idle_days, 1)))
           end as unsold_value
    from m
  ),
  top_rows as (
    select coalesce(jsonb_agg(t order by t.rev_order desc nulls last), '[]'::jsonb) as j
    from (
      select jsonb_build_object(
               'product_id', product_id, 'sku', sku, 'name', name,
               'category', category, 'brand', brand,
               'units', units, 'revenue', revenue, 'margin', margin,
               'on_hand', on_hand, 'stock_value', stock_value,
               'last_invoiced', last_invoiced, 'velocity_90d', velocity_90d,
               'idle', idle,
               'cls', case when coalesce(revenue, 0) <= 0 then 'C'
                           when cum is null then 'C'
                           when cum <= 0.80 then 'A'
                           when cum <= 0.95 then 'B'
                           else 'C' end) as t,
             coalesce(revenue, units) as rev_order
      from ranked
      order by coalesce(revenue, units) desc nulls last
      limit greatest(coalesce(p_top, 200), 1)
    ) t
  ),
  unsold_rows as (
    select coalesce(jsonb_agg(u order by u.sv desc nulls last), '[]'::jsonb) as j
    from (
      select jsonb_build_object(
               'product_id', product_id, 'sku', sku, 'name', name,
               'category', category, 'on_hand', on_hand,
               'stock_value', stock_value, 'last_invoiced', last_invoiced,
               'idle', idle) as u,
             stock_value as sv
      from m
      where coalesce(on_hand, 0) > 0
        and (idle is null or idle >= greatest(p_idle_days, 1))
      order by stock_value desc nulls last
      limit greatest(coalesce(p_unsold, 50), 1)
    ) u
  ),
  cat_rows as (
    select coalesce(jsonb_agg(c order by c.rev desc nulls last), '[]'::jsonb) as j
    from (
      select jsonb_build_object(
               'category', coalesce(category, '-'),
               'revenue', case when bool_or(revenue is not null)
                               then sum(coalesce(revenue, 0)) end,
               'units', sum(coalesce(units, 0)),
               'products', count(*)) as c,
             sum(coalesce(revenue, 0)) as rev
      from m
      group by category
    ) c
  )
  select agg.products, agg.sold, agg.units, agg.revenue, agg.stock_value,
         agg.frozen_count, agg.frozen_value, agg.unsold_count, agg.unsold_value,
         top_rows.j, unsold_rows.j, cat_rows.j
  from agg, top_rows, unsold_rows, cat_rows;
$$;

grant execute on function public.overview_facts(
  date, date, text, text, bigint, text, text, text, integer, integer, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- It must agree with file 41's separate functions, exactly
-- ---------------------------------------------------------------------------
with one as (select * from public.overview_facts(date '2025-08-15', date '2026-08-15')),
     four as (select * from public.product_summary(date '2025-08-15', date '2026-08-15'))
select 'products'     as tile, one.products::text, four.products::text,
       one.products = four.products as same from one, four
union all select 'sold', one.sold::text, four.sold::text, one.sold = four.sold from one, four
union all select 'units', round(one.units)::text, round(four.units)::text,
       round(one.units) = round(four.units) from one, four
union all select 'revenue', round(one.revenue)::text, round(four.revenue)::text,
       round(one.revenue) = round(four.revenue) from one, four
union all select 'stock_value', round(one.stock_value)::text, round(four.stock_value)::text,
       round(one.stock_value) = round(four.stock_value) from one, four
union all select 'frozen_count', one.frozen_count::text, four.frozen_count::text,
       one.frozen_count = four.frozen_count from one, four
union all select 'unsold_count', one.unsold_count::text, four.unsold_count::text,
       one.unsold_count = four.unsold_count from one, four
union all select 'top rows', jsonb_array_length(one.top)::text, '200',
       jsonb_array_length(one.top) = 200 from one
union all select 'unsold rows', jsonb_array_length(one.unsold)::text,
       (select count(*)::text from public.product_unsold(date '2025-08-15', date '2026-08-15')),
       jsonb_array_length(one.unsold) =
         (select count(*) from public.product_unsold(date '2025-08-15', date '2026-08-15'))
       from one;
