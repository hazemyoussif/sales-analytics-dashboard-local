-- ===========================================================================
-- 37. My inner join silently deleted 56 products' revenue
-- ===========================================================================
-- File 36 made agency_lines 40x faster and quietly lost rows with it:
--
--   before   874 rows
--   after    834 rows
--
-- Counted directly against the database:
--
--   products with sales since 2025-08     891
--   present in dashboard_products         835
--   MISSING from dashboard_products        56
--   excluded on purpose                     1   -> 834
--
-- Fifty-six products have real sales and no row in dashboard_products. They
-- are almost certainly archived in Odoo: the products sync stops returning
-- them, while their invoice history stays exactly where it was.
--
-- The original used LEFT JOIN and showed them with a null name. I wrote JOIN,
-- and every dinar those 56 products sold left the agencies page without a
-- trace. That is precisely the failure this project keeps writing comments
-- about -- a number that is quietly smaller, with nothing on screen to say so.
--
-- Left join restored, and they are labelled "#<product_id>" instead of blank,
-- because a row with no name at all reads as a rendering bug rather than as an
-- archived product.
--
-- ONE REAL DIFFERENCE REMAINS, and it is a property of every summary in this
-- schema rather than a mistake: the month table rounds the window to whole
-- months. Asking for 23 August 2025 onward gets all of August 2025. Same as
-- product_facts since file 19. It is why the row count will still not match
-- the old figure exactly, and it is the price of not scanning 370,000 rows.
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
  where (p_agency is null or coalesce(p.brand, 'غير محدد التوكيل') = p_agency)
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = a.product_id)
    and p_dept is null;
$$;

grant execute on function public.agency_lines(date, date, text, text, text) to authenticated;

-- Should be 890: 891 with sales, minus the 1 deliberately excluded.
select count(*) as rows_now
from public.agency_lines(date '2025-08-23', date '2026-08-23');

-- The products that were disappearing.
select agency, product_id, name, round(units) as units
from public.agency_lines(date '2025-08-23', date '2026-08-23')
where name like '#%'
order by units desc nulls last
limit 10;
