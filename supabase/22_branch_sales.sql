-- ===========================================================================
-- 22. Per-branch sales -- the columns I said could not exist
-- ===========================================================================
-- branch_stock returns real stock, and four of its columns are always empty:
-- units_month, revenue_month, cover_days, other_units_month. Everything that
-- depends on them is empty too -- the median-cover tile, the stockouts list,
-- the top-sellers panel, and the "مقترحات المناقلة" transfer card that
-- branches.js calls the feature justifying the page.
--
-- I said repeatedly that per-branch sales was underivable, because
-- account.invoice.report carries no warehouse. That was true of the invoice
-- report and false of Odoo. I only ever looked at one model.
--
-- stock.move records location_id -- where goods came FROM -- as a stored
-- field. Filter to moves whose destination is a CUSTOMER, and the source
-- location is the branch that shipped them. 734,562 such moves exist here.
-- Measured through the engine: Dabos 512 products / 78,980 units, Basra 437
-- products / 15,178 units, since May.
--
-- TWO HONEST CAVEATS, both worth stating before anyone reconciles a number:
--
--   UNITS, NOT REVENUE. Stock moves carry no price. revenue_month stays NULL
--   rather than being invented; it would need a second hop through
--   sale_line_id into the order line.
--
--   MOVED, NOT INVOICED. Every other figure on this dashboard counts goods
--   invoiced. These count goods shipped. They will not tie out exactly: a
--   delivery can precede or follow its invoice, and a delivery nobody
--   invoiced still moved stock. For "how fast does this branch shift this
--   product", shipped is arguably the better answer anyway.
--
-- Filled by: python -m odoosync branch-sales
-- Run in: Supabase -> SQL Editor. Safe to re-run.

create table if not exists public.dashboard_branch_sales (
  product_id bigint  not null,
  warehouse  text    not null,
  month      date    not null,
  units      numeric not null default 0,
  updated_at timestamptz not null default now(),
  primary key (product_id, warehouse, month)
);

create index if not exists idx_branch_sales_month
  on public.dashboard_branch_sales (month);

alter table public.dashboard_branch_sales enable row level security;
drop policy if exists branch_sales_read on public.dashboard_branch_sales;
create policy branch_sales_read on public.dashboard_branch_sales
  for select to authenticated using (true);
grant select on public.dashboard_branch_sales to authenticated;

-- ---------------------------------------------------------------------------
-- branch_stock, with velocity and cover filled in
-- ---------------------------------------------------------------------------
-- units_month is the trailing THREE months divided by three, not the current
-- calendar month. A page opened on the 2nd would otherwise report a product
-- as barely selling because the month has barely started -- and the reorder
-- page already uses a trailing-90 average for exactly that reason.
create or replace function public.branch_stock(p_warehouse text)
returns table (
  product_id        bigint,
  sku               text,
  name              text,
  agency            text,
  on_hand           numeric,
  stock_value       numeric,
  other_on_hand     numeric,
  units_month       numeric,
  revenue_month     numeric,
  cover_days        integer,
  other_units_month numeric
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('stock_value' = any (h)) as c_value
    from (select public.app_my_hidden_columns() as h) z
  ),
  here as (
    select product_id, on_hand_qty, stock_value
    from public.dashboard_branch_stock where warehouse = p_warehouse
  ),
  elsewhere as (
    select product_id, sum(on_hand_qty) qty
    from public.dashboard_branch_stock where warehouse <> p_warehouse
    group by product_id
  ),
  window_start as (
    select (date_trunc('month', current_date) - interval '3 months')::date as m
  ),
  sold_here as (
    select s.product_id, sum(s.units) / 3.0 as per_month
    from public.dashboard_branch_sales s, window_start w
    where s.warehouse = p_warehouse and s.month >= w.m
    group by s.product_id
  ),
  sold_elsewhere as (
    select s.product_id, sum(s.units) / 3.0 as per_month
    from public.dashboard_branch_sales s, window_start w
    where s.warehouse <> p_warehouse and s.month >= w.m
    group by s.product_id
  )
  select coalesce(h.product_id, e.product_id, sh.product_id),
         p.sku, p.name, coalesce(p.brand, 'غير محدد التوكيل'),
         coalesce(h.on_hand_qty, 0),
         case when pm.c_value then coalesce(h.stock_value, 0) end,
         coalesce(e.qty, 0),
         coalesce(sh.per_month, 0),
         -- Still NULL, and still on purpose: stock moves carry no price.
         null::numeric,
         -- Days of cover. NULL, never 0, when nothing sells here: "no cover"
         -- and "not selling" are different problems, and calc.js already
         -- treats a null cover as "not selling" rather than "urgent".
         case when coalesce(sh.per_month, 0) > 0
              then round(coalesce(h.on_hand_qty, 0) / sh.per_month * 30)::integer
         end,
         coalesce(se.per_month, 0)
  from here h
  full outer join elsewhere e       on e.product_id  = h.product_id
  full outer join sold_here sh      on sh.product_id = coalesce(h.product_id, e.product_id)
  left join sold_elsewhere se       on se.product_id = coalesce(h.product_id, e.product_id, sh.product_id)
  cross join perms pm
  left join public.dashboard_products p
         on p.product_id = coalesce(h.product_id, e.product_id, sh.product_id)
  order by 6 desc nulls last, 5 desc;
$$;

grant execute on function public.branch_stock(text) to authenticated;

analyze public.dashboard_branch_sales;

select warehouse,
       count(distinct product_id) as products,
       round(sum(units))          as units_shipped,
       min(month) as earliest, max(month) as latest
from public.dashboard_branch_sales
group by warehouse
order by sum(units) desc;
