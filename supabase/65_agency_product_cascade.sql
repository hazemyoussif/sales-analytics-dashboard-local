-- ===========================================================================
-- 65. THE FILTER HIERARCHY: عائلة -> توكيل -> منتج
-- ===========================================================================
-- Management wants the product filters to read as a drill-down: pick a
-- family, the agency list narrows to that family's agencies; pick an agency,
-- the product list narrows to that agency's products. The category tree
-- (هزار / جكليت) is not something they filter on -- the family control
-- already covers it -- so its slot becomes the agency picker and the old
-- agency slot becomes a product picker.
--
-- Two things here:
--
--   1. product_filter_tree() -- one row per catalogue product carrying its
--      family, agency (brand) and category. The pages build the cascade from
--      this: family -> {agencies}, agency -> {products}.
--
--   2. overview_facts gains p_product. A one-line filter in the `m` CTE, so
--      picking a single product scopes the tiles, the top list, the unsold
--      list and the family breakdown together. product_facts is untouched;
--      every existing caller passes no p_product and behaves exactly as before.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. The cascade source
-- ---------------------------------------------------------------------------
create or replace function public.product_filter_tree()
returns table (
  family     text,
  brand      text,
  category   text,
  product_id bigint,
  product    text,
  sku        text
)
language sql
stable
security invoker
as $$
  select nullif(trim(split_part(coalesce(p.category, ''), '/', 1)), '') as family,
         p.brand,
         p.category,
         p.product_id,
         coalesce(p.name, p.product_id::text) as product,
         p.sku
  from public.dashboard_products p
  where coalesce(p.category, '') !~ U&'\0639\0627\0631\0636\0627\062A|\0627\0633\062A\0627\0646\062F\0627\062A'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = p.product_id);
$$;

grant execute on function public.product_filter_tree() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. overview_facts + p_product
-- ---------------------------------------------------------------------------
-- Drop the 12-arg signature first: adding a defaulted arg creates a SECOND
-- overload that a short call matches equally well, and PostgREST would pick
-- one at random.
drop function if exists public.overview_facts(
  date, date, text, text, bigint, text, text, text, integer, integer, integer, text[]);

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
  p_unsold      integer default 50,
  p_categories  text[]  default null,
  p_product     bigint  default null
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
      p_from, p_to, p_salesperson, p_gov, p_customer, p_category, p_brand, p_city,
      p_categories)
  ),
  m as (
    select *,
           case when last_invoiced is null then null
                else (p_to - last_invoiced) end as idle
    from f
    where p_product is null or f.product_id = p_product
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
               'returned_units', returned_units,
               'returned_value', returned_value,
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
  date, date, text, text, bigint, text, text, text,
  integer, integer, integer, text[], bigint) to authenticated;

-- Sanity: no p_product == the old answer; with p_product == one product.
select 'all' as scope, products, round(units) as units from public.overview_facts(
  '2026-01-01','2026-08-31', null,null,null,null,null,null, 90,5,50, null, null)
union all
select 'one product', products, round(units) from public.overview_facts(
  '2026-01-01','2026-08-31', null,null,null,null,null,null, 90,5,50, null,
  (select product_id from public.dashboard_products
   where name is not null order by product_id limit 1));
