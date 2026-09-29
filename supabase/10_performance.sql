-- Dabboos Product Dashboard — performance fix for Returns and Discounts
-- Run in: Supabase -> SQL Editor. Safe to re-run.
-- Run AFTER 09_returns_discounts.sql.
--
-- ===========================================================================
-- THE SYMPTOM
-- ===========================================================================
--     ERROR: canceling statement due to statement timeout
--
-- ===========================================================================
-- THE THREE CAUSES
-- ===========================================================================
-- 1. NO INDEX MATCHED THE QUERY SHAPE. Every RPC filters
--        state = 'posted' AND move_type IN (...) AND invoice_date BETWEEN ...
--    and the only usable index was on invoice_date alone, so Postgres read
--    every line in the period and discarded most of it. 09 added no index of
--    its own — that was the omission.
--
-- 2. THE DIMENSION FUNCTIONS IGNORED THE FILTER BAR. They took only a date
--    range, so choosing a governorate narrowed the table while every chart
--    still scanned the whole company. That was also a correctness bug: the
--    breakdowns did not agree with the table above them.
--
-- 3. GROUPING HAPPENED AFTER THE JOIN. The customer breakdown joined
--    dashboard_customers to every line and grouped by the joined NAME. Now it
--    aggregates on partner_id — an integer already in the table — and joins
--    once per surviving group to get the label.
--
-- Four of these ran concurrently on every page load, which is what turned slow
-- into cancelled.

-- ===========================================================================
-- 1. The index the query shape actually wanted
-- ===========================================================================
-- Partial: every RPC on this dashboard filters to posted customer documents,
-- so rows that can never match are kept out of the index entirely. Smaller
-- index, and the planner can use it for the date range and the ordering.
create index if not exists idx_inv_lines_posted_date
  on public.dashboard_invoice_lines (invoice_date, product_id)
  where state = 'posted' and move_type in ('out_invoice', 'out_refund');

-- Returns are a small slice of the table. A partial index on refunds alone
-- makes "what came back" cheap regardless of how large sales get.
create index if not exists idx_inv_lines_refunds
  on public.dashboard_invoice_lines (invoice_date, product_id, partner_id)
  where state = 'posted' and move_type = 'out_refund';

analyze public.dashboard_invoice_lines;

-- ===========================================================================
-- 2. returns_by_dimension — filtered, aggregated before the join, capped
-- ===========================================================================
-- The signature gains three parameters, so CREATE OR REPLACE cannot be used
-- (Postgres treats a different argument list as a different function and the
-- old one would linger, still reachable, still slow).
drop function if exists public.returns_by_dimension(date, date, text);

create or replace function public.returns_by_dimension(
  p_from        date,
  p_to          date,
  p_kind        text,
  p_salesperson text default null,
  p_gov         text default null,
  p_category    text default null,
  p_limit       int  default 50
)
returns table (
  label          text,
  sold_value     numeric,
  returned_value numeric,
  returned_units numeric,
  return_rate    numeric
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('revenue' = any (h)) as c_revenue
    from (select public.app_my_hidden_columns() as h) z
  ),
  base as (
    -- pid and txt are mutually exclusive: only the one matching p_kind is
    -- populated, so the grouping below is on a single real key and the
    -- customer name is never carried through the aggregate.
    select case when p_kind = 'customer' then l.partner_id end as pid,
           case p_kind when 'salesperson' then l.salesperson
                       when 'gov'         then l.gov
                       when 'category'    then l.category end  as txt,
           l.qty, l.price_subtotal, l.move_type
    from public.dashboard_invoice_lines l
    where l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_category    is null or l.category    = p_category)
      and not exists (select 1 from public.dashboard_excluded_products x
                       where x.product_id = l.product_id)
  ),
  agg as (
    select b.pid, b.txt,
           sum(b.qty)            filter (where b.move_type = 'out_invoice') as sold_units,
           sum(b.price_subtotal) filter (where b.move_type = 'out_invoice') as sold_value,
           -sum(b.qty)            filter (where b.move_type = 'out_refund')  as ret_units,
           -sum(b.price_subtotal) filter (where b.move_type = 'out_refund')  as ret_value
    from base b
    group by b.pid, b.txt
    having coalesce(-sum(b.qty) filter (where b.move_type = 'out_refund'), 0) <> 0
  )
  select coalesce(c.complete_name,
                  case when a.pid is not null then 'Partner ' || a.pid else a.txt end,
                  '—'),
         case when pm.c_revenue then a.sold_value end,
         case when pm.c_revenue then a.ret_value end,
         a.ret_units,
         case when coalesce(a.sold_units, 0) > 0
              then round(100.0 * a.ret_units / a.sold_units, 1) end
  from agg a
  cross join perms pm
  left join public.dashboard_customers c on c.partner_id = a.pid
  where p_kind in ('customer', 'salesperson', 'gov', 'category')
  order by a.ret_units desc nulls last
  limit greatest(p_limit, 1);
$$;

grant execute on function
  public.returns_by_dimension(date, date, text, text, text, text, int) to authenticated;

-- ===========================================================================
-- 3. discounts_by_dimension — same three fixes
-- ===========================================================================
drop function if exists public.discounts_by_dimension(date, date, text);

create or replace function public.discounts_by_dimension(
  p_from        date,
  p_to          date,
  p_kind        text,
  p_salesperson text default null,
  p_gov         text default null,
  p_category    text default null,
  p_limit       int  default 50
)
returns table (
  label        text,
  units        numeric,
  revenue      numeric,
  list_value   numeric,
  leakage      numeric,
  discount_pct numeric
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('revenue' = any (h)) as c_revenue
    from (select public.app_my_hidden_columns() as h) z
  ),
  base as (
    select case when p_kind = 'customer' then l.partner_id end as pid,
           case p_kind when 'salesperson' then l.salesperson
                       when 'gov'         then l.gov
                       when 'category'    then l.category end  as txt,
           l.qty, l.price_subtotal, p.list_price
    from public.dashboard_invoice_lines l
    join public.dashboard_products p on p.product_id = l.product_id
    where l.state = 'posted'
      and l.move_type = 'out_invoice'
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and coalesce(p.list_price, 0) > 0
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_category    is null or l.category    = p_category)
      and not exists (select 1 from public.dashboard_excluded_products x
                       where x.product_id = l.product_id)
  ),
  agg as (
    select b.pid, b.txt,
           sum(b.qty)                  as units,
           sum(b.price_subtotal)       as revenue,
           sum(b.qty * b.list_price)   as list_value
    from base b
    group by b.pid, b.txt
    having sum(b.qty) > 0 and sum(b.qty * b.list_price) > 0
  )
  select coalesce(c.complete_name,
                  case when a.pid is not null then 'Partner ' || a.pid else a.txt end,
                  '—'),
         a.units,
         case when pm.c_revenue then a.revenue end,
         case when pm.c_revenue then a.list_value end,
         case when pm.c_revenue then a.list_value - a.revenue end,
         round(100.0 * (a.list_value - a.revenue) / a.list_value, 1)
  from agg a
  cross join perms pm
  left join public.dashboard_customers c on c.partner_id = a.pid
  where p_kind in ('customer', 'salesperson', 'gov', 'category')
  order by (a.list_value - a.revenue) desc nulls last
  limit greatest(p_limit, 1);
$$;

grant execute on function
  public.discounts_by_dimension(date, date, text, text, text, text, int) to authenticated;

-- ===========================================================================
-- 4. A longer leash, as a safety net only
-- ===========================================================================
-- The indexes and the rewrites above are the actual fix. This raises the
-- ceiling so that a slow query on a cold cache reports a slow page rather than
-- a red error, and so a future heavy query fails visibly in testing instead of
-- only for whoever picks the widest date range.
--
-- Deliberately not generous: a query that needs more than this is a query that
-- needs fixing, and a high timeout hides that.
alter role authenticated set statement_timeout = '20s';

-- ===========================================================================
-- 5. Confirm
-- ===========================================================================
-- Check the plan uses the new index rather than a sequential scan. `Seq Scan
-- on dashboard_invoice_lines` here means the index is not being chosen and the
-- timeout will come back on a wider date range.
explain (costs off)
select count(*) from public.dashboard_invoice_lines
where state = 'posted' and move_type in ('out_invoice', 'out_refund')
  and invoice_date >= current_date - 120 and invoice_date <= current_date;
