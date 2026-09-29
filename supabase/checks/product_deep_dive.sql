-- Everything the database knows about ONE product
-- Currently set to: [H 100] جكليت هزار نوروز 1 كيلو * 6 صحراوي
-- Run in: Supabase -> SQL Editor. Read-only.
--
-- ===========================================================================
-- HOW TO RUN THIS
-- ===========================================================================
-- The Supabase SQL editor shows only the LAST result when several statements
-- are run together. Select ONE section and press Ctrl+Enter (Cmd+Enter) to run
-- just that section. Running the whole file at once will only show section 10.
--
-- To switch products, change the SKU in the `target` CTE at the top of each
-- section — it is repeated per section on purpose so every section can be run
-- on its own without setting anything up first.
--
-- ===========================================================================
-- WHY THE NUMBERS ARE SIGNED
-- ===========================================================================
-- Credit-note rows carry NEGATIVE qty and price_subtotal, so a plain sum() is
-- already net of returns. Where a section wants returns as a positive figure
-- it negates them explicitly. Nothing here uses abs(): a genuinely negative
-- sale line (a correction) must not be silently reclassified as a return.

-- ###########################################################################
-- 1. THE PRODUCT ITSELF — master data and current stock
-- ###########################################################################
with target as (
  select product_id from public.dashboard_products
  where upper(trim(sku)) = 'H 100'
)
select p.product_id, p.sku, p.name, p.category, p.brand, p.uom,
       p.cost, p.list_price, p.active, p.updated_at,
       s.on_hand_qty, s.stock_value, s.updated_at as stock_updated,
       exists (select 1 from public.dashboard_excluded_products x
                where x.product_id = p.product_id) as excluded_from_dashboard
from public.dashboard_products p
join target t on t.product_id = p.product_id
left join public.dashboard_stock s on s.product_id = p.product_id;

-- ###########################################################################
-- 2. GRAND TOTAL — the whole synced window
-- ###########################################################################
-- `net_*` is what the dashboard shows with the date filter at its default.
with target as (
  select product_id from public.dashboard_products where upper(trim(sku)) = 'H 100'
)
select min(l.invoice_date)::text || '  →  ' || max(l.invoice_date)::text as window,
       count(*)                                                       as lines,
       count(distinct l.move_id)                                      as documents,
       count(distinct l.partner_id)                                   as customers,
       round(sum(l.qty), 2)                                           as net_units,
       round(sum(l.price_subtotal))                                   as net_untaxed,
       round(sum(l.price_margin))                                     as net_margin,
       round(sum(l.price_subtotal) / nullif(sum(l.qty), 0))           as avg_price_per_unit,
       round(sum(l.qty) filter (where l.move_type = 'out_invoice'), 2)        as sold_units,
       round(sum(l.price_subtotal) filter (where l.move_type = 'out_invoice')) as sold_untaxed,
       round(-sum(l.qty) filter (where l.move_type = 'out_refund'), 2)         as returned_units,
       round(-sum(l.price_subtotal) filter (where l.move_type = 'out_refund')) as returned_untaxed
from public.dashboard_invoice_lines l
join target t on t.product_id = l.product_id
where l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund');

-- ###########################################################################
-- 3. MONTH BY MONTH — compare each row against Odoo with that month selected
-- ###########################################################################
with target as (
  select product_id from public.dashboard_products where upper(trim(sku)) = 'H 100'
)
select to_char(date_trunc('month', l.invoice_date), 'YYYY-MM')            as month,
       round(sum(l.qty), 2)                                              as net_units,
       round(sum(l.price_subtotal))                                      as net_untaxed,
       round(sum(l.price_subtotal) / nullif(sum(l.qty), 0))               as price_per_unit,
       round(sum(l.qty) filter (where l.move_type = 'out_invoice'), 2)         as sold_units,
       round(sum(l.price_subtotal) filter (where l.move_type = 'out_invoice')) as sold_untaxed,
       round(-sum(l.qty) filter (where l.move_type = 'out_refund'), 2)         as returned_units,
       round(-sum(l.price_subtotal) filter (where l.move_type = 'out_refund')) as returned_untaxed,
       count(distinct l.move_id)                                          as documents
from public.dashboard_invoice_lines l
join target t on t.product_id = l.product_id
where l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
group by 1 order by 1;

-- ###########################################################################
-- 4. DAY BY DAY — for pinning down a specific invoice
-- ###########################################################################
with target as (
  select product_id from public.dashboard_products where upper(trim(sku)) = 'H 100'
)
select l.invoice_date,
       round(sum(l.qty), 2)         as net_units,
       round(sum(l.price_subtotal)) as net_untaxed,
       count(distinct l.move_id)    as documents
from public.dashboard_invoice_lines l
join target t on t.product_id = l.product_id
where l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
group by 1 order by 1 desc;

-- ###########################################################################
-- 5. BY CUSTOMER
-- ###########################################################################
with target as (
  select product_id from public.dashboard_products where upper(trim(sku)) = 'H 100'
)
select coalesce(c.complete_name, 'Partner ' || l.partner_id) as customer,
       c.governorate, c.salesperson as customer_rep,
       round(sum(l.qty), 2)                                             as net_units,
       round(sum(l.price_subtotal))                                     as net_untaxed,
       round(sum(l.price_subtotal) / nullif(sum(l.qty), 0))             as price_per_unit,
       round(-sum(l.qty) filter (where l.move_type = 'out_refund'), 2)  as returned_units,
       count(distinct l.move_id)                                        as documents,
       max(l.invoice_date)                                              as last_bought
from public.dashboard_invoice_lines l
join target t on t.product_id = l.product_id
left join public.dashboard_customers c on c.partner_id = l.partner_id
where l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
group by 1, 2, 3
order by net_untaxed desc;

-- ###########################################################################
-- 6. BY SALESPERSON AND GOVERNORATE
-- ###########################################################################
with target as (
  select product_id from public.dashboard_products where upper(trim(sku)) = 'H 100'
)
select coalesce(l.salesperson, '—') as salesperson,
       coalesce(l.gov, '—')         as governorate,
       round(sum(l.qty), 2)                                     as net_units,
       round(sum(l.price_subtotal))                             as net_untaxed,
       round(sum(l.price_subtotal) / nullif(sum(l.qty), 0))     as price_per_unit,
       count(distinct l.partner_id)                             as customers,
       count(distinct l.move_id)                                as documents
from public.dashboard_invoice_lines l
join target t on t.product_id = l.product_id
where l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
group by 1, 2
order by net_untaxed desc;

-- ###########################################################################
-- 7. EVERY SINGLE LINE — the raw truth, newest first
-- ###########################################################################
-- unit_price is what was actually charged on that line. Compare it against
-- list_price from section 1 to see the discount on each individual sale.
with target as (
  select product_id, list_price from public.dashboard_products
  where upper(trim(sku)) = 'H 100'
)
select l.invoice_date, l.move_type, l.move_id, l.line_id,
       round(l.qty, 2)                                as qty,
       round(l.price_subtotal)                        as untaxed,
       round(l.price_subtotal / nullif(l.qty, 0))     as unit_price,
       t.list_price,
       case when coalesce(t.list_price, 0) > 0
            then round(100.0 * (t.list_price - l.price_subtotal / nullif(l.qty, 0))
                       / t.list_price, 1) end          as discount_pct,
       round(l.price_margin)                          as margin,
       coalesce(c.complete_name, 'Partner ' || l.partner_id) as customer,
       l.salesperson, l.gov, l.city, l.payment_state
from public.dashboard_invoice_lines l
join target t on t.product_id = l.product_id
left join public.dashboard_customers c on c.partner_id = l.partner_id
where l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
order by l.invoice_date desc, l.line_id desc;

-- ###########################################################################
-- 8. RETURNS ONLY — who sent it back and when
-- ###########################################################################
with target as (
  select product_id from public.dashboard_products where upper(trim(sku)) = 'H 100'
)
select l.invoice_date, l.move_id,
       round(-l.qty, 2)                            as returned_units,
       round(-l.price_subtotal)                    as returned_untaxed,
       round(l.price_subtotal / nullif(l.qty, 0))  as unit_price,
       coalesce(c.complete_name, 'Partner ' || l.partner_id) as customer,
       l.salesperson, l.gov
from public.dashboard_invoice_lines l
join target t on t.product_id = l.product_id
left join public.dashboard_customers c on c.partner_id = l.partner_id
where l.state = 'posted' and l.move_type = 'out_refund'
order by l.invoice_date desc;

-- ###########################################################################
-- 9. PRICE SPREAD — is the average moving because of pricing or because of mix?
-- ###########################################################################
-- A wide gap between min and max unit price on the same product means the
-- realized price depends on WHO is buying, not on the product. That is the
-- discount story on the Discounts page, seen one product at a time.
with target as (
  select product_id, list_price from public.dashboard_products
  where upper(trim(sku)) = 'H 100'
),
sales as (
  select l.invoice_date, l.qty, l.price_subtotal,
         l.price_subtotal / nullif(l.qty, 0) as unit_price, t.list_price
  from public.dashboard_invoice_lines l
  join target t on t.product_id = l.product_id
  where l.state = 'posted' and l.move_type = 'out_invoice' and l.qty > 0
)
select round(min(unit_price))                                     as min_price,
       round(percentile_cont(0.25) within group (order by unit_price)) as p25,
       round(percentile_cont(0.50) within group (order by unit_price)) as median,
       round(percentile_cont(0.75) within group (order by unit_price)) as p75,
       round(max(unit_price))                                     as max_price,
       round(sum(price_subtotal) / nullif(sum(qty), 0))           as weighted_avg,
       list_price,
       round(sum(qty), 2)                                         as units,
       -- Money foregone against list, at the units actually sold — the same
       -- figure the Discounts page calls "leakage", for this product alone.
       -- list_price is constant per product, so it comes straight off `sales`
       -- rather than through a window function, which Postgres will not allow
       -- inside an aggregate.
       round(sum((list_price - unit_price) * qty))                as leakage_vs_list
from sales
group by list_price;

-- ###########################################################################
-- 10. WHAT THE DASHBOARD ITSELF COMPUTES — the definitive comparison
-- ###########################################################################
-- Calls the very same function the Overview and Products pages call, so this
-- row IS the dashboard's answer. If it disagrees with sections 2-3 above, the
-- bug is inside product_facts. If it agrees but the screen shows something
-- else, the bug is in the browser.
--
-- ← EDIT the two dates to match the range selected on the dashboard.
select f.sku, f.name, f.uom,
       f.units, round(f.revenue) as revenue, round(f.margin) as margin,
       f.margin_pct, round(f.realized_price) as realized_price,
       f.last_invoiced, f.distinct_customers, f.distinct_invoices,
       f.on_hand, round(f.stock_value) as stock_value,
       round(f.velocity_90d, 1) as velocity_per_month,
       f.cost, f.list_price
from public.product_facts(date '2026-04-01', date '2026-08-31') f
where upper(trim(f.sku)) = 'H 100';
