-- ===========================================================================
-- 23. Branch revenue -- the tile and the monthly chart
-- ===========================================================================
-- Two widgets on the branches page were still blank:
--
--   "Branch revenue — مخزن الدبوس الرئيسي"   the KPI tile
--   "Branch revenue by month"                the column chart (branch_trend)
--
-- Both are revenue, and file 22 left revenue NULL because stock moves carry
-- no price. That was the wrong place to look. sale.order carries BOTH
-- warehouse_id and amount_untaxed, both stored. Measured since 2026-05:
--
--   مخزن الدبوس الرئيسي   2,886,159,112
--   مخزن فرع الموصل         757,856,697
--   مخزن فرع البصره         509,712,000
--
-- TWO PROPERTIES OF THIS NUMBER, both worth stating plainly:
--
--   ORDER BASIS. Every other money figure on this dashboard is on the invoice
--   basis. This is what was ORDERED from a branch, not what was invoiced.
--   They will not agree, and an order never invoiced still counts here. It is
--   the only per-branch money figure Odoo yields without joining prices to
--   warehouses line by line, which is one hop past what the engine reaches.
--
--   BRANCH TOTAL, NOT PER PRODUCT. sale.order holds one amount for the whole
--   order and it cannot honestly be split across the products on it. So the
--   TILE and the CHART are filled; the per-product revenue_month column in
--   branch_stock stays NULL, because that number does not exist at this
--   grain.
--
-- Filled by: python -m odoosync branch-revenue
-- Run in: Supabase -> SQL Editor. Safe to re-run.

create table if not exists public.dashboard_branch_revenue (
  warehouse  text not null,
  month      date not null,
  revenue    numeric not null default 0,
  orders     bigint  not null default 0,
  updated_at timestamptz not null default now(),
  primary key (warehouse, month)
);

alter table public.dashboard_branch_revenue enable row level security;
drop policy if exists branch_revenue_read on public.dashboard_branch_revenue;
create policy branch_revenue_read on public.dashboard_branch_revenue
  for select to authenticated using (true);
grant select on public.dashboard_branch_revenue to authenticated;

-- ---------------------------------------------------------------------------
-- branch_trend -- no longer deliberately empty
-- ---------------------------------------------------------------------------
-- File 21 defined this as an empty function so the page would stop marking
-- itself DEMO DATA. It can now answer for real: the last 12 months of order
-- revenue for one branch.
--
-- The masking check matters here. This is the only widget on the page that
-- shows money to a role, and every other money column on this dashboard is
-- withheld from roles that may not see revenue. An unguarded chart would be
-- the hole in that.
create or replace function public.branch_trend(p_warehouse text)
returns table (label text, value numeric)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('revenue' = any (h)) as c_revenue
    from (select public.app_my_hidden_columns() as h) z
  )
  select to_char(r.month, 'YYYY-MM'),
         case when pm.c_revenue then r.revenue end
  from public.dashboard_branch_revenue r
  cross join perms pm
  where r.warehouse = p_warehouse
    and r.month >= (date_trunc('month', current_date) - interval '11 months')::date
  order by r.month;
$$;

grant execute on function public.branch_trend(text) to authenticated;

-- ---------------------------------------------------------------------------
-- The tile: one number for the branch over a period
-- ---------------------------------------------------------------------------
-- branches.js currently builds this tile by summing revenue_month across the
-- product rows, which is NULL for every one of them and so always renders
-- zero. This gives the page a number it can show directly.
create or replace function public.branch_revenue_total(
  p_warehouse text,
  p_months    integer default 1
)
returns table (revenue numeric, orders bigint, months integer)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('revenue' = any (h)) as c_revenue
    from (select public.app_my_hidden_columns() as h) z
  )
  select case when pm.c_revenue then coalesce(sum(r.revenue), 0) end,
         coalesce(sum(r.orders), 0),
         p_months
  from public.dashboard_branch_revenue r
  cross join perms pm
  where r.warehouse = p_warehouse
    and r.month >= (date_trunc('month', current_date)
                    - make_interval(months => greatest(p_months, 1) - 1))::date
  group by pm.c_revenue;
$$;

grant execute on function public.branch_revenue_total(text, integer) to authenticated;

analyze public.dashboard_branch_revenue;

select warehouse, count(*) as months,
       round(sum(revenue)) as total_revenue, sum(orders) as orders,
       min(month) as earliest, max(month) as latest
from public.dashboard_branch_revenue
group by warehouse
order by sum(revenue) desc;
