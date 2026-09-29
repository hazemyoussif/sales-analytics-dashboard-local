-- ===========================================================================
-- 71. Warehouses: Free to use instead of On Hand; توكيل filter is the category
-- ===========================================================================
-- Two review points:
--
--  * The page must report FREE TO USE (quantity - reserved_quantity), not raw
--    on-hand. A reserved carton is already committed to an order. The sync now
--    writes reserved_qty alongside on_hand_qty (jobs.py branch_stock), and
--    stock_value is on the free quantity.
--
--  * "التوكيل" is the Odoo product category (categ_id), matching every other
--    page. warehouse_totals / warehouse_stock take p_category instead of
--    p_brand.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

alter table public.dashboard_branch_stock
  add column if not exists reserved_qty numeric not null default 0;

comment on column public.dashboard_branch_stock.reserved_qty is
  'stock.quant.reserved_quantity, summed. Free to use = on_hand_qty - reserved_qty.';

drop function if exists public.warehouse_totals(text, text, bigint);
drop function if exists public.warehouse_stock(text, text, text, bigint);

create or replace function public.warehouse_totals(
  p_category text   default null,
  p_family   text   default null,
  p_product  bigint default null
)
returns table (
  warehouse   text,
  skus        bigint,
  free_qty    numeric,
  reserved    numeric,
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
         count(*)::bigint                                          as skus,
         sum(greatest(b.on_hand_qty - b.reserved_qty, 0))          as free_qty,
         sum(b.reserved_qty)                                       as reserved,
         case when bool_and(p.c_value) then sum(b.stock_value) end as stock_value
  from public.dashboard_branch_stock b
  cross join perms p
  join public.dashboard_products d on d.product_id = b.product_id
  where coalesce(d.category, '') !~ U&'\0639\0627\0631\0636\0627\062A|\0627\0633\062A\0627\0646\062F\0627\062A'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = b.product_id)
    and (p_category is null or d.category = p_category)
    and (p_family   is null or trim(split_part(coalesce(d.category, ''), '/', 1)) = p_family)
    and (p_product  is null or d.product_id = p_product)
  group by b.warehouse
  order by sum(b.stock_value) desc nulls last, b.warehouse;
$$;

grant execute on function public.warehouse_totals(text, text, bigint) to authenticated;

create or replace function public.warehouse_stock(
  p_warehouse text   default null,
  p_category  text   default null,
  p_family    text   default null,
  p_product   bigint default null
)
returns table (
  product_id  bigint,
  sku         text,
  name        text,
  category    text,
  brand       text,
  warehouse   text,
  free_qty    numeric,
  reserved    numeric,
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
           sum(greatest(b.on_hand_qty - b.reserved_qty, 0)) as free_qty,
           sum(b.reserved_qty)                              as reserved,
           sum(b.stock_value)                               as stock_value
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
         a.free_qty,
         a.reserved,
         case when pm.c_value then a.stock_value end
  from agg a
  cross join perms pm
  join public.dashboard_products d on d.product_id = a.product_id
  where coalesce(d.category, '') !~ U&'\0639\0627\0631\0636\0627\062A|\0627\0633\062A\0627\0646\062F\0627\062A'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = a.product_id)
    and (p_category is null or d.category = p_category)
    and (p_family   is null or trim(split_part(coalesce(d.category, ''), '/', 1)) = p_family)
    and (p_product  is null or d.product_id = p_product)
  order by a.stock_value desc nulls last, a.free_qty desc;
$$;

grant execute on function public.warehouse_stock(text, text, text, bigint) to authenticated;

select * from public.warehouse_totals();
