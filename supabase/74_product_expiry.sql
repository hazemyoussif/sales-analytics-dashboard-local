-- ===========================================================================
-- 74. PRODUCT EXPIRY -- "what is on the shelf and about to go off"
-- ===========================================================================
-- Management asked to see product expiry dates. In Odoo the date is not on the
-- product: it lives on the lot/batch (stock.lot.expiration_date), and on-hand
-- stock links to a lot through stock.quant.lot_id. The engine exposed neither
-- until commit 8f5b057; see docs/engine-request-expiry.md.
--
-- The sync's `expiry` job (jobs.py product_expiry) writes one row per
-- product / warehouse / lot: how many units of a dated batch are physically on
-- hand and when that batch expires. This file is the table it upserts into and
-- two read functions for the card on the Warehouses page.
--
--   python -m odoosync expiry
--
-- Until that runs the table is empty and the card says so -- it does NOT put a
-- banner over the rest of the page.
--
-- Notes carried from the engine owner:
--   * expiration_date is a datetime in Odoo; the sync slices it to a date, so
--     everything here compares date against date.
--   * only lot-tracked products can appear -- a product with tracking = none
--     has no lot and therefore no date.
--   * every dated lot already has a real date and many are in the past, so the
--     "already expired, still on hand" number has volume from the first run.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. The table (exact shape the sync's product_expiry job upserts)
-- ---------------------------------------------------------------------------
create table if not exists public.dashboard_product_expiry (
  product_id  bigint  not null,
  warehouse   text    not null,
  lot_name    text    not null,
  expiry_date date    not null,
  on_hand_qty numeric not null default 0,
  updated_at  timestamptz not null default now(),
  primary key (product_id, warehouse, lot_name)
);

comment on table public.dashboard_product_expiry is
  'stock.lot x stock.quant: on-hand units of a dated batch per product per warehouse. Fed by odoosync `expiry`.';

alter table public.dashboard_product_expiry enable row level security;

drop policy if exists product_expiry_read on public.dashboard_product_expiry;
create policy product_expiry_read on public.dashboard_product_expiry
  for select to authenticated using (true);

grant select on public.dashboard_product_expiry to authenticated;

-- ---------------------------------------------------------------------------
-- 2. expiry_totals() -- the three tiles above the table
-- ---------------------------------------------------------------------------
-- One row. expired = date already past; soon = within p_within_days from
-- today; tracked = every dated unit in scope regardless of when. Value columns
-- are qty x dashboard_products.cost, masked with the same 'stock_value'
-- hidden-column check used across the dashboard; the quantities are not
-- restricted. The عارضات/استاندات categories and dashboard_excluded_products
-- are cut here exactly as the Warehouses functions cut them.
drop function if exists public.expiry_totals(text, integer, text, text, bigint);

create or replace function public.expiry_totals(
  p_warehouse   text    default null,
  p_within_days integer default 90,
  p_category    text    default null,
  p_family      text    default null,
  p_product     bigint  default null
)
returns table (
  skus          bigint,
  expired_qty   numeric,
  soon_qty      numeric,
  tracked_qty   numeric,
  expired_value numeric,
  soon_value    numeric
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('stock_value' = any (h)) as c_value
    from (select public.app_my_hidden_columns() as h) z
  ),
  scoped as (
    select e.product_id, e.expiry_date, e.on_hand_qty,
           e.on_hand_qty * coalesce(d.cost, 0) as val
    from public.dashboard_product_expiry e
    join public.dashboard_products d on d.product_id = e.product_id
    where coalesce(d.category, '') !~ U&'\0639\0627\0631\0636\0627\062A|\0627\0633\062A\0627\0646\062F\0627\062A'
      and not exists (select 1 from public.dashboard_excluded_products x
                       where x.product_id = e.product_id)
      and (p_warehouse is null or e.warehouse = p_warehouse)
      and (p_category  is null or d.category = p_category)
      and (p_family    is null or trim(split_part(coalesce(d.category, ''), '/', 1)) = p_family)
      and (p_product   is null or d.product_id = p_product)
  )
  select count(distinct product_id)::bigint,
         coalesce(sum(on_hand_qty) filter (where expiry_date < current_date), 0),
         coalesce(sum(on_hand_qty) filter (
           where expiry_date >= current_date
             and expiry_date <= current_date + p_within_days), 0),
         coalesce(sum(on_hand_qty), 0),
         case when bool_and(p.c_value)
              then coalesce(sum(val) filter (where expiry_date < current_date), 0) end,
         case when bool_and(p.c_value)
              then coalesce(sum(val) filter (
                     where expiry_date >= current_date
                       and expiry_date <= current_date + p_within_days), 0) end
  from scoped cross join perms p;
$$;

grant execute on function public.expiry_totals(text, integer, text, text, bigint) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. expiry_report() -- one row per product, soonest expiry first
-- ---------------------------------------------------------------------------
-- Lots are rolled up to the product: the card answers "which products need
-- attention", and a per-lot list would be hundreds of rows of batch numbers.
-- later_qty is the dated stock that is neither expired nor inside the window --
-- shown so the three buckets add up to total_qty and nothing looks missing.
drop function if exists public.expiry_report(text, integer, text, text, bigint);

create or replace function public.expiry_report(
  p_warehouse   text    default null,
  p_within_days integer default 90,
  p_category    text    default null,
  p_family      text    default null,
  p_product     bigint  default null
)
returns table (
  product_id     bigint,
  sku            text,
  name           text,
  category       text,
  family         text,
  earliest_expiry date,
  expired_qty    numeric,
  soon_qty       numeric,
  later_qty      numeric,
  total_qty      numeric,
  expired_value  numeric,
  soon_value     numeric
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('stock_value' = any (h)) as c_value
    from (select public.app_my_hidden_columns() as h) z
  ),
  scoped as (
    select e.product_id, e.expiry_date, e.on_hand_qty,
           e.on_hand_qty * coalesce(d.cost, 0) as val,
           d.sku, d.name, d.category,
           trim(split_part(coalesce(d.category, ''), '/', 1)) as family
    from public.dashboard_product_expiry e
    join public.dashboard_products d on d.product_id = e.product_id
    where coalesce(d.category, '') !~ U&'\0639\0627\0631\0636\0627\062A|\0627\0633\062A\0627\0646\062F\0627\062A'
      and not exists (select 1 from public.dashboard_excluded_products x
                       where x.product_id = e.product_id)
      and (p_warehouse is null or e.warehouse = p_warehouse)
      and (p_category  is null or d.category = p_category)
      and (p_family    is null or trim(split_part(coalesce(d.category, ''), '/', 1)) = p_family)
      and (p_product   is null or d.product_id = p_product)
  )
  select s.product_id,
         max(s.sku),
         coalesce(max(s.name), s.product_id::text),
         max(s.category),
         max(s.family),
         min(s.expiry_date) as earliest_expiry,
         coalesce(sum(s.on_hand_qty) filter (where s.expiry_date < current_date), 0),
         coalesce(sum(s.on_hand_qty) filter (
           where s.expiry_date >= current_date
             and s.expiry_date <= current_date + p_within_days), 0),
         coalesce(sum(s.on_hand_qty) filter (
           where s.expiry_date > current_date + p_within_days), 0),
         coalesce(sum(s.on_hand_qty), 0),
         case when bool_and(p.c_value)
              then coalesce(sum(s.val) filter (where s.expiry_date < current_date), 0) end,
         case when bool_and(p.c_value)
              then coalesce(sum(s.val) filter (
                     where s.expiry_date >= current_date
                       and s.expiry_date <= current_date + p_within_days), 0) end
  from scoped s
  cross join perms p
  group by s.product_id
  order by min(s.expiry_date) asc nulls last,
           sum(s.on_hand_qty) filter (where s.expiry_date < current_date) desc nulls last;
$$;

grant execute on function public.expiry_report(text, integer, text, text, bigint) to authenticated;

select * from public.expiry_totals();
