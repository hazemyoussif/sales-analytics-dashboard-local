-- ===========================================================================
-- 21. The two reasons the branches page still says DEMO DATA
-- ===========================================================================
-- branch_stock returns 441 real rows, and the page still shows "Every figure
-- here is generated, not from Odoo". Two independent causes.
--
-- 1. branch_trend does not exist, so insights.load() catches PostgREST's 404
--    and sets the page's demo flag. That flag is PER PAGE, so one missing
--    chart marks every figure on the screen as invented -- including the
--    stock numbers, which are real. The banner is now actively false.
--
-- 2. branches.js picks warehouse names from demo.js: 'مخزن البصرة' and
--    'مخزن الموصل'. Odoo's are 'مخزن فرع البصره' and 'مخزن فرع الموصل' --
--    different wording AND different spelling (ة vs ه). Nothing matches, so
--    every "here" column reads zero while "other branches" reads correctly.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. The real warehouse names
-- ---------------------------------------------------------------------------
-- Sourced from the stock the sync actually wrote, not a hardcoded list, so a
-- new branch appears by itself and a closed one disappears.
create or replace function public.branch_warehouses()
returns table (warehouse text, products bigint, stock_value numeric)
language sql
stable
security invoker
as $$
  select warehouse, count(*)::bigint, sum(stock_value)
  from public.dashboard_branch_stock
  group by warehouse
  order by sum(stock_value) desc nulls last;
$$;

grant execute on function public.branch_warehouses() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. branch_trend -- exists, and returns nothing, on purpose
-- ---------------------------------------------------------------------------
-- The page draws this as monthly REVENUE for one branch. That cannot be
-- computed: account.invoice.report carries no warehouse, so there is no way
-- to attribute a sale to the branch that shipped it. branches.js says so
-- itself, and refuses to substitute governorate -- sales TO Basra and sales
-- FROM the Basra warehouse are different quantities, and a page labelled
-- "مخزن البصرة" showing the first would be wrong in a way nobody could see.
--
-- So why define an empty function at all? Because NOT defining it is worse.
-- A missing function returns 404, which the page reads as "not built yet" and
-- answers by marking THE WHOLE PAGE as demo data -- including 441 rows of
-- real per-warehouse stock. Existing-and-empty renders one empty chart and
-- leaves every other figure standing as the real number it is.
--
-- An empty chart says "no data for this". A demo banner over real data says
-- something false about numbers someone might otherwise act on.
--
-- What would make this real: snapshot dashboard_branch_stock monthly, the way
-- dashboard_stock_history snapshots stock, and redefine the chart as stock
-- VALUE per branch over time. That answers a different question from the one
-- the label asks, so it needs deciding rather than assuming -- and it starts
-- empty regardless, since no history exists yet.
create or replace function public.branch_trend(p_warehouse text)
returns table (label text, value numeric)
language sql
stable
security invoker
as $$
  select null::text, null::numeric where false;
$$;

grant execute on function public.branch_trend(text) to authenticated;

select * from public.branch_warehouses();
