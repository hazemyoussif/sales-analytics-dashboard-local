-- ===========================================================================
-- 39. Arabic literals were corrupted on the way into the database
-- ===========================================================================
-- Measured against the live database, not suspected:
--
--   agency_lines returns    'D-D:D?D...'  mojibake, where it should return the
--                           Arabic for "agency not specified"
--   product_facts LEAKS     the display-stands category it is supposed to
--                           exclude -- 1 category, visible on the products page
--
-- Category names in the DATA are clean. The corruption is in the function
-- BODIES, which means it happened between the .sql file and Postgres.
--
-- THE CAUSE IS THE COMMAND I GAVE YOU.
--
--   Get-Content file -Raw | Set-Clipboard
--
-- Windows PowerShell 5.1's Get-Content decides a file's encoding from its BOM.
-- These files are UTF-8 with NO BOM, so it fell back to the system ANSI
-- codepage and read every Arabic byte as Windows-1252. The clipboard, the
-- editor and Postgres then faithfully stored exactly what they were handed.
--
-- Correct form, for any future file:
--
--   Get-Content file -Raw -Encoding UTF8 | Set-Clipboard
--
-- THIS FILE DOES NOT RELY ON THAT. Every non-ASCII literal below is written as
-- a Postgres U&'...' escape -- \0639 rather than the character itself -- so the
-- executable part of this file is pure ASCII and cannot be damaged by any
-- encoding path between here and the database. U&'\0639\0627...' is the same
-- string to Postgres; it is only unreadable to us, which is the trade.
--
-- Six functions carried such literals. All six are regenerated here from their
-- latest definitions.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

-- product_facts (from 38_cascading_filters.sql)
create or replace function public.product_facts(
  p_from        date,
  p_to          date,
  p_salesperson text   default null,
  p_gov         text   default null,
  p_customer    bigint default null,
  p_category    text   default null,
  p_brand       text   default null,
  p_city        text   default null
)
returns table (
  product_id         bigint,
  sku                text,
  name               text,
  category           text,
  brand              text,
  uom                text,
  cost               numeric,
  list_price         numeric,
  units              numeric,
  revenue            numeric,
  margin             numeric,
  margin_pct         numeric,
  realized_price     numeric,
  last_invoiced      date,
  distinct_customers bigint,
  distinct_govs      bigint,
  distinct_invoices  bigint,
  on_hand            numeric,
  stock_value        numeric,
  velocity_90d       numeric
)
language sql
stable
security invoker
as $$
  with perms as materialized (
    select not ('margin'      = any (h)) as c_margin,
           not ('cost'        = any (h)) as c_cost,
           not ('revenue'     = any (h)) as c_revenue,
           not ('stock_value' = any (h)) as c_stock_value,
           not ('customers'   = any (h)) as c_customers,
           public.app_table_visible('dashboard_stock')         as t_stock,
           public.app_table_visible('dashboard_invoice_lines') as t_lines
    from (select public.app_my_hidden_columns() as h) z
  ),
  -- p_city joins the list that forces the invoice lines: dashboard_product_month
  -- is keyed by product and month and knows nothing about where the goods went.
  filtered as (select p_salesperson is not null or p_gov is not null
                   or p_customer is not null or p_category is not null
                   or p_brand is not null or p_city is not null as on_),
  -- The precomputed velocity trails TODAY. It may only be used when the
  -- selected window ends near today; a week of slack covers "yesterday" and
  -- a page left open overnight without letting March 2025 borrow this week's
  -- rate. Filters force the scan too: a stored global figure cannot answer
  -- "how fast does this sell in Basra".
  use_cached as (
    select (not f.on_) and p_to >= current_date - 7 as on_ from filtered f
  ),
  period_agg as (
    select m.product_id,
           sum(m.units) as units, sum(m.revenue) as revenue, sum(m.margin) as margin,
           null::bigint as distinct_customers, null::bigint as distinct_govs,
           sum(m.invoices) as distinct_invoices
    from public.dashboard_product_month m, filtered f
    where not f.on_
      and m.month >= date_trunc('month', p_from)::date
      and m.month <= date_trunc('month', p_to)::date
    group by m.product_id
    union all
    select l.product_id,
           sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
           count(distinct l.partner_id), count(distinct l.gov),
           count(distinct l.move_id)
    from public.dashboard_invoice_lines l, filtered f
    where f.on_
      and l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_customer    is null or l.partner_id  = p_customer)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_city        is null or l.city        = p_city)
      and (p_category    is null or l.category    = p_category)
      and (p_brand       is null or l.brand       = p_brand)
    group by l.product_id
  ),
  trailing_90 as (
    select ls.product_id, ls.units_90d as units_90d
    from public.dashboard_product_lastsale ls, use_cached u
    where u.on_
    union all
    select l.product_id, sum(l.qty)
    from public.dashboard_invoice_lines l, use_cached u
    where not u.on_
      and l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date > p_to - 90 and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_customer    is null or l.partner_id  = p_customer)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_city        is null or l.city        = p_city)
      and (p_category    is null or l.category    = p_category)
      and (p_brand       is null or l.brand       = p_brand)
    group by l.product_id
  )
  select
    p.product_id, p.sku, p.name, p.category, p.brand, p.uom,
    case when pm.c_cost then p.cost end,
    p.list_price,
    case when pm.t_lines then coalesce(pe.units, 0) end,
    case when pm.t_lines and pm.c_revenue then coalesce(pe.revenue, 0) end,
    case when pm.t_lines and pm.c_margin  then coalesce(pe.margin, 0) end,
    case when pm.t_lines and pm.c_margin and coalesce(pe.revenue, 0) <> 0
         then round(100.0 * pe.margin / pe.revenue, 1) end,
    case when pm.t_lines and pm.c_revenue and coalesce(pe.units, 0) <> 0
         then pe.revenue / pe.units end,
    ls.last_invoiced,
    case when pm.t_lines and pm.c_customers then pe.distinct_customers end,
    case when pm.t_lines then pe.distinct_govs end,
    case when pm.t_lines then coalesce(pe.distinct_invoices, 0) end,
    case when pm.t_stock then coalesce(s.on_hand_qty, 0) end,
    case when pm.t_stock and pm.c_stock_value then coalesce(s.stock_value, 0) end,
    case when pm.t_lines then greatest(coalesce(tr.units_90d, 0) / 3.0, 0) end
  from public.dashboard_products p
  cross join perms pm
  left join public.dashboard_stock s             on s.product_id = p.product_id
  left join period_agg  pe                       on pe.product_id = p.product_id
  left join trailing_90 tr                       on tr.product_id = p.product_id
  left join public.dashboard_product_lastsale ls on ls.product_id = p.product_id
  where coalesce(p.category, '') !~ U&'\0639\0627\0631\0636\0627\062A|\0627\0633\062A\0627\0646\062F\0627\062A'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = p.product_id)
    and (p_category is null or p.category = p_category)
    and (p_brand    is null or p.brand    = p_brand);
$$;

grant execute on function public.product_facts(
  date, date, text, text, bigint, text, text, text) to authenticated;

-- agency_lines (from 37_agency_lines_kept_dropping_56_products.sql)
create or replace function public.agency_lines(
  p_from   date,
  p_to     date,
  p_agency text default null,
  p_gov    text default null,
  p_dept   text default null
)
returns table (
  agency     text,
  product_id bigint,
  sku        text,
  name       text,
  revenue    numeric,
  margin     numeric,
  units      numeric,
  gov        text,
  dept       text,
  customers  bigint
)
language sql
stable
security invoker
as $$
  with perms as materialized (
    select not ('revenue'   = any (h)) as c_revenue,
           not ('margin'    = any (h)) as c_margin,
           not ('customers' = any (h)) as c_customers
    from (select public.app_my_hidden_columns() as h) z
  ),
  by_gov as (select p_gov is not null as on_),
  agg as (
    select m.product_id,
           sum(m.revenue) as revenue, sum(m.margin) as margin, sum(m.units) as units,
           null::bigint as customers
    from public.dashboard_product_month m, by_gov g
    where not g.on_
      and m.month >= date_trunc('month', p_from)::date
      and m.month <= date_trunc('month', p_to)::date
    group by m.product_id
    union all
    select l.product_id,
           sum(l.price_subtotal), sum(l.price_margin), sum(l.qty),
           count(distinct l.partner_id)
    from public.dashboard_invoice_lines l, by_gov g
    where g.on_
      and l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and l.gov = p_gov
    group by l.product_id
  )
  select coalesce(p.brand, U&'\063A\064A\0631 \0645\062D\062F\062F \0627\0644\062A\0648\0643\064A\0644'),
         a.product_id, p.sku,
         -- A product missing from the catalogue still sold something, so it
         -- keeps its row and is labelled by id rather than vanishing.
         coalesce(p.name, '#' || a.product_id::text),
         case when pm.c_revenue then a.revenue end,
         case when pm.c_margin  then a.margin  end,
         a.units,
         -- gov and dept were already null here before this change: agency_lines
         -- groups by product, and a product row has no single governorate.
         null::text, null::text,
         case when pm.c_customers then a.customers end
  from agg a
  cross join perms pm
  left join public.dashboard_products p on p.product_id = a.product_id
  where (p_agency is null or coalesce(p.brand, U&'\063A\064A\0631 \0645\062D\062F\062F \0627\0644\062A\0648\0643\064A\0644') = p_agency)
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = a.product_id)
    and p_dept is null;
$$;

grant execute on function public.agency_lines(date, date, text, text, text) to authenticated;

-- branch_stock (from 35_perms_materialized_everywhere.sql)
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
  with perms as materialized (
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
         p.sku, p.name, coalesce(p.brand, U&'\063A\064A\0631 \0645\062D\062F\062F \0627\0644\062A\0648\0643\064A\0644'),
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

-- discounts_by_product (from 35_perms_materialized_everywhere.sql)
create or replace function public.discounts_by_product(
  p_from        date,
  p_to          date,
  p_salesperson text default null,
  p_gov         text default null,
  p_category    text default null
)
returns table (
  product_id     bigint,
  sku            text,
  name           text,
  category       text,
  units          numeric,
  revenue        numeric,
  list_price     numeric,
  realized_price numeric,
  discount_pct   numeric,
  margin         numeric,
  margin_pct     numeric,
  leakage        numeric     -- money given away vs list, at the units sold
)
language sql
stable
security invoker
as $$
  with perms as materialized (
    select not ('revenue' = any (h)) as c_revenue,
           not ('margin'  = any (h)) as c_margin,
           not ('cost'    = any (h)) as c_cost
    from (select public.app_my_hidden_columns() as h) z
  ),
  agg as (
    select l.product_id,
           sum(l.qty)            as units,
           sum(l.price_subtotal) as revenue,
           sum(l.price_margin)   as margin
    from public.dashboard_invoice_lines l
    where l.state = 'posted'
      and l.move_type = 'out_invoice'          -- sales only, see above
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_category    is null or l.category    = p_category)
      and not exists (select 1 from public.dashboard_excluded_products x
                       where x.product_id = l.product_id)
    group by l.product_id
    having sum(l.qty) > 0
  )
  select a.product_id, p.sku, p.name, p.category,
         a.units,
         case when pm.c_revenue then a.revenue end,
         case when pm.c_cost    then p.list_price end,
         case when pm.c_revenue then a.revenue / a.units end,
         case when coalesce(p.list_price, 0) > 0
              then round(100.0 * (p.list_price - a.revenue / a.units) / p.list_price, 1) end,
         case when pm.c_margin then a.margin end,
         case when pm.c_margin and a.revenue <> 0
              then round(100.0 * a.margin / a.revenue, 1) end,
         case when pm.c_revenue and coalesce(p.list_price, 0) > 0
              then (p.list_price - a.revenue / a.units) * a.units end
  from agg a
  cross join perms pm
  join public.dashboard_products p on p.product_id = a.product_id
  where coalesce(p.category, '') !~ U&'\0639\0627\0631\0636\0627\062A|\0627\0633\062A\0627\0646\062F\0627\062A'
  order by 12 desc nulls last;               -- biggest leakage first
$$;

grant execute on function public.discounts_by_product(date, date, text, text, text)
  to authenticated;

-- returns_by_product (from 35_perms_materialized_everywhere.sql)
create or replace function public.returns_by_product(
  p_from        date,
  p_to          date,
  p_salesperson text default null,
  p_gov         text default null,
  p_category    text default null
)
returns table (
  product_id      bigint,
  sku             text,
  name            text,
  category        text,
  sold_units      numeric,
  sold_value      numeric,
  returned_units  numeric,
  returned_value  numeric,
  return_rate     numeric,   -- % of units sold that came back
  return_invoices bigint,
  customers       bigint
)
language sql
stable
security invoker
as $$
  with perms as materialized (
    select not ('revenue'   = any (h)) as c_revenue,
           not ('customers' = any (h)) as c_customers
    from (select public.app_my_hidden_columns() as h) z
  ),
  scoped as (
    select l.*
    from public.dashboard_invoice_lines l
    where l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_category    is null or l.category    = p_category)
      -- the invoice-level discount lines are not products; excluded here for
      -- the same reason product_facts excludes them
      and not exists (select 1 from public.dashboard_excluded_products x
                       where x.product_id = l.product_id)
  ),
  agg as (
    select s.product_id,
           sum(s.qty)            filter (where s.move_type = 'out_invoice') as sold_units,
           sum(s.price_subtotal) filter (where s.move_type = 'out_invoice') as sold_value,
           -sum(s.qty)            filter (where s.move_type = 'out_refund') as ret_units,
           -sum(s.price_subtotal) filter (where s.move_type = 'out_refund') as ret_value,
           count(distinct s.move_id) filter (where s.move_type = 'out_refund') as ret_invoices,
           count(distinct s.partner_id) filter (where s.move_type = 'out_refund') as ret_customers
    from scoped s
    group by s.product_id
  )
  select a.product_id, p.sku, p.name, p.category,
         coalesce(a.sold_units, 0),
         case when pm.c_revenue then coalesce(a.sold_value, 0) end,
         coalesce(a.ret_units, 0),
         case when pm.c_revenue then coalesce(a.ret_value, 0) end,
         -- Rate on UNITS, not money: a return at a discount would understate a
         -- money-based rate, and the operational question is how many pieces
         -- came back. Undefined rather than 0 when nothing was sold <arabic text> a
         -- product with returns and no sales in the period is a real case.
         case when coalesce(a.sold_units, 0) > 0
              then round(100.0 * coalesce(a.ret_units, 0) / a.sold_units, 1) end,
         coalesce(a.ret_invoices, 0),
         case when pm.c_customers then coalesce(a.ret_customers, 0) end
  from agg a
  cross join perms pm
  join public.dashboard_products p on p.product_id = a.product_id
  where coalesce(a.ret_units, 0) <> 0        -- only products that came back
    and coalesce(p.category, '') !~ U&'\0639\0627\0631\0636\0627\062A|\0627\0633\062A\0627\0646\062F\0627\062A'
  order by coalesce(a.ret_units, 0) desc;
$$;

grant execute on function public.returns_by_product(date, date, text, text, text)
  to authenticated;

-- product_customers (from 35_perms_materialized_everywhere.sql)
create or replace function public.product_customers(
  p_product_id bigint, p_from date, p_to date)
returns table (partner_id bigint, customer text, units numeric,
               revenue numeric, margin numeric, invoices bigint)
language sql
stable
security invoker
as $$
  with perms as materialized (
    select not ('margin'    = any (h)) as c_margin,
           not ('revenue'   = any (h)) as c_revenue,
           not ('customers' = any (h)) as c_customers
    from (select public.app_my_hidden_columns() as h) z
  )
  select case when bool_and(pm.c_customers) then l.partner_id end,
         case when bool_and(pm.c_customers)
              then coalesce(c.complete_name, 'Partner ' || l.partner_id)
              else U&'\2022\2022\2022' end,
         sum(l.qty),
         case when bool_and(pm.c_revenue) then sum(l.price_subtotal) end,
         case when bool_and(pm.c_margin)  then sum(l.price_margin) end,
         count(distinct l.move_id)
  from public.dashboard_invoice_lines l
  left join public.dashboard_customers c on c.partner_id = l.partner_id
  cross join perms pm
  where l.product_id = p_product_id
    and l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.invoice_date >= p_from and l.invoice_date <= p_to
  group by l.partner_id, c.complete_name
  order by 3 desc;
$$;

grant execute on function public.product_customers(bigint, date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- Prove it, in ASCII
-- ---------------------------------------------------------------------------
-- The excluded category must no longer appear.
select count(*) as leaked_categories
from public.product_facts(date '2025-08-23', date '2026-08-23')
where category ~ U&'\0639\0627\0631\0636\0627\062A|\0627\0633\062A\0627\0646\062F\0627\062A';

-- And the agency label must match the real Arabic string, not mojibake.
select count(*) as rows_with_correct_unknown_label
from public.agency_lines(date '2026-06-01', date '2026-08-23')
where agency = U&'\063A\064A\0631 \0645\062D\062F\062F \0627\0644\062A\0648\0643\064A\0644';
