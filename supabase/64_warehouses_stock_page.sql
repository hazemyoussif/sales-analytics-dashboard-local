-- ===========================================================================
-- 64. THE WAREHOUSES PAGE -- per-warehouse stock, restored
-- ===========================================================================
-- Management asked for a صفحة المخازن: what is on hand in each warehouse
-- (الرئيسي / البصرة / الموصل), with a filter by warehouse.
--
-- dashboard_stock holds Odoo's qty_available -- ONE company-wide number per
-- product, no location in it -- so this page cannot be built from what the
-- other pages read. It needs dashboard_branch_stock, which is stock.quant
-- grouped by warehouse. That table and its page existed once and were dropped
-- in file 52 ("nine pages removed, four tables dropped") as a scope cut, not
-- a data problem. This brings back the table and a leaner pair of read
-- functions -- stock only, none of the old branch-revenue / transfer machinery
-- that file 21 already flagged as partly underivable.
--
-- The fetch job is still in the sync package and was never touched:
--     python -m odoosync branch-stock
-- Until it runs the table is empty and the page says so; it does NOT fall back
-- to a demo banner over the rest of the dashboard.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. The table (exact shape the sync's branch_stock job upserts)
-- ---------------------------------------------------------------------------
create table if not exists public.dashboard_branch_stock (
  product_id  bigint  not null,
  warehouse   text    not null,
  on_hand_qty numeric not null default 0,
  stock_value numeric,
  updated_at  timestamptz not null default now(),
  primary key (product_id, warehouse)
);

alter table public.dashboard_branch_stock enable row level security;

drop policy if exists branch_stock_read on public.dashboard_branch_stock;
create policy branch_stock_read on public.dashboard_branch_stock
  for select to authenticated using (true);

grant select on public.dashboard_branch_stock to authenticated;

-- ---------------------------------------------------------------------------
-- 2. warehouse_totals() -- one row per warehouse, for the filter and the tiles
-- ---------------------------------------------------------------------------
-- Warehouse names come from the data the sync actually wrote, never a
-- hardcoded list, so a new branch appears on its own and a closed one drops
-- off. stock_value is masked with the same 'stock_value' hidden-column check
-- used everywhere else; the SKU count and unit total are not restricted.
create or replace function public.warehouse_totals()
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
  where coalesce(d.category, '') !~ 'عارضات|استاندات'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = b.product_id)
  group by b.warehouse
  order by sum(b.stock_value) desc nulls last, b.warehouse;
$$;

grant execute on function public.warehouse_totals() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. warehouse_stock(p_warehouse) -- the product rows for one or all warehouses
-- ---------------------------------------------------------------------------
-- p_warehouse NULL sums a product across every warehouse (the "all" view).
-- Same عارضات/استاندات and excluded-product exclusions as product_facts, so
-- the SKU counts here reconcile with Overview.
create or replace function public.warehouse_stock(
  p_warehouse text default null
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
  where coalesce(d.category, '') !~ 'عارضات|استاندات'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = a.product_id)
  order by a.stock_value desc nulls last, a.on_hand_qty desc;
$$;

grant execute on function public.warehouse_stock(text) to authenticated;

-- What the sync will fill in. Empty until `python -m odoosync branch-stock`.
select * from public.warehouse_totals();
