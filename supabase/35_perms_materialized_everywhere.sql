-- ===========================================================================
-- 35. The same one-keyword fix, everywhere else
-- ===========================================================================
-- File 34 proved it on product_facts. Measured, same query, same data:
--
--   before   Execution Time  2,317.058 ms   buffers 23,741   no CTE perms node
--   after    Execution Time     12.181 ms   buffers    417   CTE perms, loops=1
--
-- 190x, from one keyword. The plan now shows "CTE perms ... rows=1 loops=1"
-- where before there was no perms node at all: Postgres had inlined it and was
-- calling app_my_hidden_columns() and app_table_visible() once per output row,
-- roughly 3,900 times, each reading app_users and app_roles.
--
-- Every RPC in this schema uses that same CTE, so every one of them has been
-- paying the same tax in proportion to the rows it returns. The ones that emit
-- a handful of rows barely noticed; the ones that emit hundreds or thousands
-- have been slow for this reason and no other.
--
-- Each function below is its LATEST definition, taken from whichever file last
-- redefined it, with the single keyword added and nothing else changed. Several
-- of these have been redefined two or three times across the numbered files and
-- only the last one is live, so they are regenerated from that.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

-- from 12_management_pages.sql
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
  scoped as (
    select coalesce(l.brand, 'غير محدد التوكيل') as agency, l.*
    from public.dashboard_invoice_lines l
    where l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_gov is null or l.gov = p_gov)
      and not exists (select 1 from public.dashboard_excluded_products x
                       where x.product_id = l.product_id)
  )
  select s.agency, s.product_id, p.sku, p.name,
         case when pm.c_revenue then sum(s.price_subtotal) end,
         case when pm.c_margin  then sum(s.price_margin)   end,
         sum(s.qty),
         null::text, null::text,
         case when pm.c_customers then count(distinct s.partner_id) end
  from scoped s
  cross join perms pm
  left join public.dashboard_products p on p.product_id = s.product_id
  where (p_agency is null or s.agency = p_agency)
    and p_dept is null
  group by s.agency, s.product_id, p.sku, p.name,
           pm.c_revenue, pm.c_margin, pm.c_customers;
$$;

grant execute on function public.agency_lines(date, date, text, text, text)
  to authenticated;

-- from 23_branch_revenue.sql
create or replace function public.branch_revenue_total(
  p_warehouse text,
  p_months    integer default 1
)
returns table (revenue numeric, orders bigint, months integer)
language sql
stable
security invoker
as $$
  with perms as materialized (
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

-- from 22_branch_sales.sql
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

-- from 23_branch_revenue.sql
create or replace function public.branch_trend(p_warehouse text)
returns table (label text, value numeric)
language sql
stable
security invoker
as $$
  with perms as materialized (
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

-- from 12_management_pages.sql
create or replace function public.customer_receivables(
  p_gov         text default null,
  p_salesperson text default null
)
returns table (
  partner_id   bigint,
  customer     text,
  gov          text,
  salesperson  text,
  dept         text,
  balance      numeric,
  overdue      numeric,
  oldest_days  integer,
  terms_days   integer,
  credit_limit numeric,
  avg_pay_days integer
)
language sql
stable
security invoker
as $$
  with perms as materialized (
    select not ('revenue' = any (h)) as c_money
    from (select public.app_my_hidden_columns() as h) z
  )
  select r.partner_id, r.customer, r.gov, r.salesperson,
         null::text,
         case when pm.c_money then r.balance end,
         case when pm.c_money then r.overdue end,
         r.oldest_days, r.terms_days,
         case when pm.c_money then r.credit_limit end,
         -- Average days-to-pay needs each invoice matched to its payment,
         -- which in Odoo runs through account.partial.reconcile: a
         -- many-to-many two hops from the invoice. The engine traverses one
         -- hop, so this is not reachable and is NULL rather than guessed.
         null::integer
  from public.dashboard_receivables r
  cross join perms pm
  where (p_gov         is null or r.gov         = p_gov)
    and (p_salesperson is null or r.salesperson = p_salesperson)
  order by r.overdue desc, r.balance desc;
$$;

grant execute on function public.customer_receivables(text, text)
  to authenticated;

-- from 32_class_filter_shows_quiet_accounts.sql
create or replace function public.customers_pareto(
  p_from        date,
  p_to          date,
  p_gov         text default null,
  p_dept        text default null,
  p_salesperson text default null,
  p_category    text default null,
  p_agency      text default null,
  p_prev_from   date default null,
  p_prev_to     date default null,
  p_class       text default null,
  p_class_year  integer default 2025
)
returns table (
  partner_id     bigint,
  customer       text,
  gov            text,
  dept           text,
  salesperson    text,
  revenue        numeric,
  margin         numeric,
  units          numeric,
  invoices       bigint,
  last_purchase  date,
  revenue_prev   numeric,
  margin_prev    numeric,
  units_prev     numeric,
  invoices_prev  bigint,
  growth_pct     numeric,
  cls            text,
  avg_monthly    numeric
)
language sql
stable
security invoker
as $$
  with perms as materialized (
    select not ('revenue' = any (h)) as c_revenue,
           not ('margin'  = any (h)) as c_margin
    from (select public.app_my_hidden_columns() as h) z
  ),
  bounds as (
    select p_from as f, p_to as t,
           coalesce(p_prev_from, (p_from - interval '1 year')::date) as pf,
           coalesce(p_prev_to,   (p_to   - interval '1 year')::date) as pt
  ),
  klass as (select * from public.customer_class(p_class_year)),
  by_product as (select p_category is not null or p_agency is not null as on_),
  cur as (
    select m.partner_id, sum(m.revenue) revenue, sum(m.margin) margin,
           sum(m.units) units, sum(m.invoices) invoices
    from public.dashboard_partner_month m, bounds b, by_product bp
    where not bp.on_
      and m.month >= date_trunc('month', b.f)::date
      and m.month <= date_trunc('month', b.t)::date
    group by m.partner_id
    union all
    select l.partner_id, sum(l.price_subtotal), sum(l.price_margin),
           sum(l.qty), count(distinct l.move_id)
    from public.dashboard_invoice_lines l, bounds b, by_product bp
    where bp.on_
      and l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
      and l.invoice_date >= b.f and l.invoice_date <= b.t
      and (p_category is null or l.category = p_category)
      and (p_agency   is null or l.brand    = p_agency)
    group by l.partner_id
  ),
  -- WHO THE PAGE IS ABOUT. Normally the customers who bought in the window.
  -- When a class is asked for, every member of that class as well -- including
  -- the ones with nothing in the window, which is the point of asking.
  roster as (
    select partner_id from cur
    union
    select k.partner_id from klass k
    where p_class is not null and k.cls = p_class
  ),
  prev as (
    select m.partner_id, sum(m.revenue) revenue, sum(m.margin) margin,
           sum(m.units) units, sum(m.invoices) invoices
    from public.dashboard_partner_month m, bounds b, by_product bp
    where not bp.on_
      and m.month >= date_trunc('month', b.pf)::date
      and m.month <= date_trunc('month', b.pt)::date
    group by m.partner_id
    union all
    select l.partner_id, sum(l.price_subtotal), sum(l.price_margin),
           sum(l.qty), count(distinct l.move_id)
    from public.dashboard_invoice_lines l, bounds b, by_product bp
    where bp.on_
      and l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
      and l.invoice_date >= b.pf and l.invoice_date <= b.pt
      and (p_category is null or l.category = p_category)
      and (p_agency   is null or l.brand    = p_agency)
    group by l.partner_id
  ),
  last_seen as (
    select partner_id, max(month) as m
    from public.dashboard_partner_month group by partner_id
  )
  select r.partner_id,
         coalesce(dc.complete_name, r.partner_id::text),
         dc.governorate,
         null::text,
         dc.salesperson,
         -- 0, not NULL, for an account with no sales this period. It bought
         -- nothing; that is a number, and the ±% column needs it to be one.
         case when pm.c_revenue then coalesce(c.revenue, 0) end,
         case when pm.c_margin  then coalesce(c.margin,  0) end,
         coalesce(c.units, 0),
         coalesce(c.invoices, 0),
         ls.m,
         case when pm.c_revenue then coalesce(pv.revenue, 0) end,
         case when pm.c_margin  then coalesce(pv.margin,  0) end,
         coalesce(pv.units, 0),
         coalesce(pv.invoices, 0),
         -- -100% for an account that bought last period and nothing this one.
         -- That is the number this whole change exists to surface, and it is
         -- a real measurement rather than a missing one.
         case when pm.c_revenue and coalesce(pv.revenue, 0) > 0
              then round(100.0 * (coalesce(c.revenue, 0) - pv.revenue) / pv.revenue, 1)
         end,
         coalesce(k.cls, 'C'),
         case when pm.c_revenue then coalesce(k.avg_monthly, 0) end
  from roster r
  cross join perms pm
  left join cur c                              on c.partner_id  = r.partner_id
  left join prev pv                            on pv.partner_id = r.partner_id
  left join last_seen ls                       on ls.partner_id = r.partner_id
  left join public.dashboard_customers dc      on dc.partner_id = r.partner_id
  left join klass k                            on k.partner_id  = r.partner_id
  where (p_gov         is null or dc.governorate = p_gov)
    and (p_salesperson is null or dc.salesperson = p_salesperson)
    and (p_class       is null or coalesce(k.cls, 'C') = p_class)
    and p_dept is null
  order by coalesce(c.revenue, 0) desc nulls last;
$$;

grant execute on function public.customers_pareto(
  date, date, text, text, text, text, text, date, date, text, integer) to authenticated;

-- from 10_performance.sql
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
  with perms as materialized (
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

-- from 09_returns_discounts.sql
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
  where coalesce(p.category, '') !~ 'عارضات|استاندات'
  order by 12 desc nulls last;               -- biggest leakage first
$$;

grant execute on function public.discounts_by_product(date, date, text, text, text)
  to authenticated;

-- from 05_masking.sql
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
              else '•••' end,
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

-- from 05_masking.sql
create or replace function public.product_regions(
  p_product_id bigint, p_from date, p_to date)
returns table (gov text, units numeric, revenue numeric,
               margin numeric, customers bigint)
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
  select coalesce(l.gov, '—'),
         sum(l.qty),
         case when bool_and(pm.c_revenue)   then sum(l.price_subtotal) end,
         case when bool_and(pm.c_margin)    then sum(l.price_margin) end,
         case when bool_and(pm.c_customers) then count(distinct l.partner_id) end
  from public.dashboard_invoice_lines l
  cross join perms pm
  where l.product_id = p_product_id
    and l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.invoice_date >= p_from and l.invoice_date <= p_to
  group by 1
  order by 2 desc;
$$;

grant execute on function public.product_regions(bigint, date, date) to authenticated;

-- from 05_masking.sql
create or replace function public.product_trend(p_product_id bigint, p_months int default 24)
returns table (month text, units numeric, revenue numeric, margin numeric)
language sql
stable
security invoker
as $$
  with perms as materialized (
    select not ('margin'  = any (h)) as c_margin,
           not ('revenue' = any (h)) as c_revenue
    from (select public.app_my_hidden_columns() as h) z
  )
  select to_char(date_trunc('month', l.invoice_date), 'YYYY-MM'),
         sum(l.qty),
         case when bool_and(pm.c_revenue) then sum(l.price_subtotal) end,
         case when bool_and(pm.c_margin)  then sum(l.price_margin) end
  from public.dashboard_invoice_lines l
  cross join perms pm
  where l.product_id = p_product_id
    and l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.invoice_date >= (current_date - (p_months || ' months')::interval)
  group by 1
  order by 1;
$$;

grant execute on function public.product_trend(bigint, int) to authenticated;

-- from 10_performance.sql
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
  with perms as materialized (
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

-- from 09_returns_discounts.sql
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
         -- came back. Undefined rather than 0 when nothing was sold — a
         -- product with returns and no sales in the period is a real case.
         case when coalesce(a.sold_units, 0) > 0
              then round(100.0 * coalesce(a.ret_units, 0) / a.sold_units, 1) end,
         coalesce(a.ret_invoices, 0),
         case when pm.c_customers then coalesce(a.ret_customers, 0) end
  from agg a
  cross join perms pm
  join public.dashboard_products p on p.product_id = a.product_id
  where coalesce(a.ret_units, 0) <> 0        -- only products that came back
    and coalesce(p.category, '') !~ 'عارضات|استاندات'
  order by coalesce(a.ret_units, 0) desc;
$$;

grant execute on function public.returns_by_product(date, date, text, text, text)
  to authenticated;

-- from 05_masking.sql
create or replace function public.revenue_adjustments(
  p_from        date,
  p_to          date,
  p_salesperson text   default null,
  p_gov         text   default null,
  p_customer    bigint default null
)
returns table (product_id bigint, sku text, name text, reason text,
               units numeric, revenue numeric, margin numeric)
language sql
stable
security invoker
as $$
  with perms as materialized (
    select not ('margin'  = any (h)) as c_margin,
           not ('revenue' = any (h)) as c_revenue
    from (select public.app_my_hidden_columns() as h) z
  )
  select x.product_id, x.sku, x.name, x.reason,
         sum(l.qty),
         case when bool_and(pm.c_revenue) then sum(l.price_subtotal) end,
         case when bool_and(pm.c_margin)  then sum(l.price_margin) end
  from public.dashboard_invoice_lines l
  join public.dashboard_excluded_products x on x.product_id = l.product_id
  cross join perms pm
  where l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.invoice_date >= p_from and l.invoice_date <= p_to
    and (p_salesperson is null or l.salesperson = p_salesperson)
    and (p_customer    is null or l.partner_id  = p_customer)
    and (p_gov         is null or l.gov         = p_gov)
  group by x.product_id, x.sku, x.name, x.reason
  order by 6;
$$;

grant execute on function public.revenue_adjustments(date, date, text, text, bigint)
  to authenticated;

-- from 26_month_compare_uses_summary.sql
create or replace function public.revenue_by_month_compare(
  p_from     date,
  p_to       date,
  p_gov      text default null,
  p_category text default null,
  p_agency   text default null
)
returns table (label text, revenue numeric, revenue_prev numeric)
language sql
stable
security invoker
as $$
  with perms as materialized (
    select not ('revenue' = any (h)) as c_revenue
    from (select public.app_my_hidden_columns() as h) z
  ),
  by_line as (
    select p_gov is not null or p_category is not null
        or p_agency is not null as on_
  ),
  months as (
    select generate_series(date_trunc('month', p_from),
                           date_trunc('month', p_to),
                           interval '1 month')::date as m
  ),
  -- This year
  agg as (
    select m.month as m, sum(m.revenue) as v
    from public.dashboard_partner_month m, by_line bl
    where not bl.on_
      and m.month >= date_trunc('month', p_from)::date
      and m.month <= date_trunc('month', p_to)::date
    group by m.month
    union all
    select date_trunc('month', l.invoice_date)::date, sum(l.price_subtotal)
    from public.dashboard_invoice_lines l, by_line bl
    where bl.on_
      and l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_gov      is null or l.gov      = p_gov)
      and (p_category is null or l.category = p_category)
      and (p_agency   is null or l.brand    = p_agency)
    group by 1
  ),
  -- Last year, shifted forward a year so it lines up with the month beside it
  agg_prev as (
    select (m.month + interval '1 year')::date as m, sum(m.revenue) as v
    from public.dashboard_partner_month m, by_line bl
    where not bl.on_
      and m.month >= (date_trunc('month', p_from) - interval '1 year')::date
      and m.month <= (date_trunc('month', p_to)   - interval '1 year')::date
    group by m.month
    union all
    select (date_trunc('month', l.invoice_date) + interval '1 year')::date,
           sum(l.price_subtotal)
    from public.dashboard_invoice_lines l, by_line bl
    where bl.on_
      and l.state = 'posted' and l.move_type in ('out_invoice','out_refund')
      and l.invoice_date >= (p_from - interval '1 year')::date
      and l.invoice_date <= (p_to   - interval '1 year')::date
      and (p_gov      is null or l.gov      = p_gov)
      and (p_category is null or l.category = p_category)
      and (p_agency   is null or l.brand    = p_agency)
    group by 1
  )
  select to_char(mo.m, 'YYYY-MM'),
         case when pm.c_revenue then coalesce(a.v,  0) end,
         case when pm.c_revenue then coalesce(ap.v, 0) end
  from months mo
  cross join perms pm
  left join agg a       on a.m  = mo.m
  left join agg_prev ap on ap.m = mo.m
  order by mo.m;
$$;

grant execute on function public.revenue_by_month_compare(date, date, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- A live ambiguity, found while checking the grants for these two
-- ---------------------------------------------------------------------------
-- File 09 created returns_by_dimension(date, date, text). File 10 created
-- returns_by_dimension(date, date, text, text, text, text, int) with defaults
-- on the last four -- which does not REPLACE the first, it adds a second
-- function of the same name. Both exist right now.
--
-- A three-argument call, which is exactly what the page makes, matches both
-- equally well. PostgREST picks one, and nothing says which. If it has been
-- picking file 09's, then every filter file 10 added has been silently ignored
-- since the day it ran -- the page would look like it was filtering and the
-- numbers would not change.
--
-- This is the third time this exact trap has appeared in this schema (file 25,
-- file 31, here), and it is always silent. Dropping the narrow versions leaves
-- one function per name, so a call either resolves to the right body or fails
-- loudly.
drop function if exists public.returns_by_dimension(date, date, text);
drop function if exists public.discounts_by_dimension(date, date, text);

grant execute on function public.returns_by_dimension(date, date, text, text, text, text, int)
  to authenticated;
grant execute on function public.discounts_by_dimension(date, date, text, text, text, text, int)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Spot-check the heaviest ones
-- ---------------------------------------------------------------------------
explain (analyze) select * from public.customers_pareto(date '2025-08-23', date '2026-08-23');
