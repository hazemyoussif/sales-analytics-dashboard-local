-- ===========================================================================
-- 36. The last query that still reads a year of invoice lines
-- ===========================================================================
-- After file 35, measured isolated, best of three:
--
--   data_health           1,715 ms   (8 rows -- almost all round-trip latency)
--   filter_options        1,179 ms
--   product_facts         1,663 ms
--   customers_pareto      2,270 ms
--   agency_lines          8,710 ms   <-- five times everything else
--
-- And unlike the others it scales with the window: 870ms over one month,
-- 8,710ms over twelve. That is the signature of a table scan, and agency_lines
-- is the one RPC left that still reads dashboard_invoice_lines directly for
-- its main path -- roughly 370,000 rows for a year, with a count(distinct
-- partner_id) on top.
--
-- It groups by (agency, product_id), which dashboard_product_month already
-- holds. The brand comes from dashboard_products rather than from the line.
-- Checked before switching, because a silent disagreement between the two
-- would misfile products under the wrong agency: 558 products compared, brand
-- agrees on 558.
--
-- `customers` becomes NULL on the summary path -- distinct partners cannot be
-- summed across months without counting the same customer once per month. The
-- agencies page does not display this column (its customer view is
-- agency_customer_matrix, untouched here), so nothing on screen changes. Same
-- decision file 19 made for product_facts, for the same reason.
--
-- The governorate filter still uses the lines, because a product-by-month
-- summary knows nothing about where the goods went.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

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
  select coalesce(p.brand, 'غير محدد التوكيل'),
         a.product_id, p.sku, p.name,
         case when pm.c_revenue then a.revenue end,
         case when pm.c_margin  then a.margin  end,
         a.units,
         -- gov and dept were already null here before this change: agency_lines
         -- groups by product, and a product row has no single governorate.
         null::text, null::text,
         case when pm.c_customers then a.customers end
  from agg a
  cross join perms pm
  join public.dashboard_products p on p.product_id = a.product_id
  where (p_agency is null or coalesce(p.brand, 'غير محدد التوكيل') = p_agency)
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = a.product_id)
    and p_dept is null;
$$;

grant execute on function public.agency_lines(date, date, text, text, text) to authenticated;

-- Twelve months, the range that took 8.7 seconds.
explain (analyze)
select * from public.agency_lines(date '2025-08-23', date '2026-08-23');
