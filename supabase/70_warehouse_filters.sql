-- ===========================================================================
-- 70. Warehouses page gains the عائلة / توكيل / منتج filters
-- ===========================================================================
-- dashboard_branch_stock is product x warehouse and nothing else -- no
-- governorate, no salesperson -- so the only filters that mean anything are
-- the product hierarchy. warehouse_totals and warehouse_stock take p_family,
-- p_brand and p_product, all resolved against dashboard_products the same way
-- product_filter_tree() splits family from category.
--
-- Signature change on both, so drop + recreate. Neither has any other caller.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

drop function if exists public.warehouse_totals();
drop function if exists public.warehouse_stock(text);

create or replace function public.warehouse_totals(
  p_family  text   default null,
  p_brand   text   default null,
  p_product bigint default null
)
returns table (
  warehouse   text,
  skus        bigint,
  on_hand     numeric,
  stock_value numeric
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('stock_value' = any (h)) as c_value
    from (select public.app_my_hidden_columns() as h) z
  )
  select b.warehouse,
         count(*)::bigint                                   as skus,
         sum(b.on_hand_qty)                                 as on_hand,
         case when bool_and(p.c_value) then sum(b.stock_value) end as stock_value
  from public.dashboard_branch_stock b
  cross join perms p
  join public.dashboard_products d on d.product_id = b.product_id
  where coalesce(d.category, '') !~ U&'\0639\0627\0631\0636\0627\062A|\0627\0633\062A\0627\0646\062F\0627\062A'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = b.product_id)
    and (p_family  is null or trim(split_part(coalesce(d.category, ''), '/', 1)) = p_family)
    and (p_brand   is null or d.brand = p_brand)
    and (p_product is null or d.product_id = p_product)
  group by b.warehouse
  order by sum(b.stock_value) desc nulls last, b.warehouse;
$$;

grant execute on function public.warehouse_totals(text, text, bigint) to authenticated;

create or replace function public.warehouse_stock(
  p_warehouse text   default null,
  p_family    text   default null,
  p_brand     text   default null,
  p_product   bigint default null
)
returns table (
  product_id  bigint,
  sku         text,
  name        text,
  category    text,
  brand       text,
  warehouse   text,
  on_hand_qty numeric,
  stock_value numeric
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('stock_value' = any (h)) as c_value
    from (select public.app_my_hidden_columns() as h) z
  ),
  agg as (
    select b.product_id,
           case when p_warehouse is null then 'ALL' else max(b.warehouse) end as warehouse,
           sum(b.on_hand_qty) as on_hand_qty,
           sum(b.stock_value) as stock_value
    from public.dashboard_branch_stock b
    where (p_warehouse is null or b.warehouse = p_warehouse)
    group by b.product_id
  )
  select a.product_id,
         d.sku,
         coalesce(d.name, a.product_id::text),
         d.category,
         d.brand,
         a.warehouse,
         a.on_hand_qty,
         case when pm.c_value then a.stock_value end
  from agg a
  cross join perms pm
  join public.dashboard_products d on d.product_id = a.product_id
  where coalesce(d.category, '') !~ U&'\0639\0627\0631\0636\0627\062A|\0627\0633\062A\0627\0646\062F\0627\062A'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = a.product_id)
    and (p_family  is null or trim(split_part(coalesce(d.category, ''), '/', 1)) = p_family)
    and (p_brand   is null or d.brand = p_brand)
    and (p_product is null or d.product_id = p_product)
  order by a.stock_value desc nulls last, a.on_hand_qty desc;
$$;

grant execute on function public.warehouse_stock(text, text, text, bigint) to authenticated;

select * from public.warehouse_totals();
