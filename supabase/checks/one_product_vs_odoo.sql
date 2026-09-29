-- Reconcile ONE product against Odoo's Invoice Analysis
-- Run in: Supabase -> SQL Editor. Read-only.
--
-- ===========================================================================
-- HOW TO USE
-- ===========================================================================
-- Set v_sku below, run the whole file, then compare section 3 (month by month)
-- against Odoo with the SAME month selected. Comparing a dashboard showing
-- April-August against an Odoo filter showing July is the single most common
-- way to "find" a discrepancy that does not exist.
--
-- ===========================================================================
-- WHAT ODOO'S SCREEN IS SHOWING
-- ===========================================================================
-- Invoicing -> Reporting -> Invoice Analysis, filter "Invoiced", grouped by
-- product, measures Untaxed Amount and Product Quantity. That is the same
-- source this dashboard syncs (account.invoice.report), so the numbers SHOULD
-- agree exactly for the same period. Any difference is a real finding.
--
-- Two things Odoo's default view does that people forget:
--   * credit notes are included, with NEGATIVE quantity and amount — which is
--     why a month's total Product Quantity can come out negative;
--   * the [DISC] discount line is a product row like any other.
-- This dashboard nets credit notes the same way, but EXCLUDES [DISC] from
-- product tables and reports it separately. Section 4 quantifies that.

-- ===========================================================================
-- 1. Pick the product  ← EDIT THIS
-- ===========================================================================
-- Use the SKU exactly as it appears in the square brackets on the dashboard,
-- e.g. 'H 100' for [H 100].
create temporary view v_target as
  select p.product_id, p.sku, p.name, p.uom, p.list_price, p.cost
  from public.dashboard_products p
  where upper(trim(p.sku)) = upper(trim('H 100'));   -- <<<< EDIT

select * from v_target;

-- ===========================================================================
-- 2. The whole synced window for this product
-- ===========================================================================
-- This is what the dashboard shows when the date filter is left at its
-- default, which is the full data range — NOT the current month.
select 'ALL SYNCED DATA' as period,
       min(l.invoice_date)::text || ' → ' || max(l.invoice_date)::text as window,
       round(sum(l.qty), 2)                as net_units,
       round(sum(l.price_subtotal))        as net_untaxed,
       round(sum(l.price_subtotal) / nullif(sum(l.qty), 0)) as price_per_unit
from public.dashboard_invoice_lines l
join v_target t on t.product_id = l.product_id
where l.state = 'posted'
  and l.move_type in ('out_invoice', 'out_refund');

-- ===========================================================================
-- 3. Month by month — compare THIS against Odoo, one month at a time
-- ===========================================================================
-- net_units and net_untaxed are what the dashboard reports for that month.
-- They must equal Odoo's Product Quantity and Untaxed Amount for the same
-- month, for this product, exactly.
--
-- sold_* and returned_* split the same figures so a large return shows up as
-- a return rather than as "sales fell".
select to_char(date_trunc('month', l.invoice_date), 'YYYY-MM')       as month,
       round(sum(l.qty), 2)                                          as net_units,
       round(sum(l.price_subtotal))                                  as net_untaxed,
       round(sum(l.price_subtotal) / nullif(sum(l.qty), 0))          as price_per_unit,
       round(sum(l.qty) filter (where l.move_type = 'out_invoice'), 2)   as sold_units,
       round(sum(l.price_subtotal) filter (where l.move_type = 'out_invoice')) as sold_untaxed,
       round(-sum(l.qty) filter (where l.move_type = 'out_refund'), 2)      as returned_units,
       round(-sum(l.price_subtotal) filter (where l.move_type = 'out_refund')) as returned_untaxed,
       count(distinct l.move_id)                                      as documents
from public.dashboard_invoice_lines l
join v_target t on t.product_id = l.product_id
where l.state = 'posted'
  and l.move_type in ('out_invoice', 'out_refund')
group by 1
order by 1;

-- ===========================================================================
-- 4. Is the price per unit actually moving, or is the comparison wrong?
-- ===========================================================================
-- If price_per_unit above is stable across months, then a units/revenue ratio
-- that does not match between two periods means the two periods are simply
-- different — nothing is broken.
--
-- If it swings hard, the cause is real and is one of: a price change, heavy
-- discounting in one month, or a credit note issued at a different price from
-- the original sale. This lists the biggest documents so it can be traced.
select l.invoice_date,
       l.move_type,
       l.move_id,
       round(l.qty, 2)                            as qty,
       round(l.price_subtotal)                    as untaxed,
       round(l.price_subtotal / nullif(l.qty, 0)) as unit_price,
       l.salesperson,
       l.gov
from public.dashboard_invoice_lines l
join v_target t on t.product_id = l.product_id
where l.state = 'posted'
  and l.move_type in ('out_invoice', 'out_refund')
order by abs(l.price_subtotal) desc
limit 40;

-- ===========================================================================
-- 5. Whole-company totals, to check the headline rather than one product
-- ===========================================================================
-- `product_total` is what the dashboard's revenue tile shows.
-- `disc_total` is the [DISC] line, which the dashboard reports SEPARATELY.
-- `odoo_total` is what Odoo's Invoice Analysis shows for the same period —
-- the sum of both. If odoo_total matches Odoo's screen, the dashboard is
-- correct and the difference is only in how the discount is presented.
--
-- ← EDIT the two dates to match whatever you selected in Odoo.
with bounds as (select date '2026-07-01' as d_from, date '2026-07-31' as d_to),
lines as (
  select l.*, exists (select 1 from public.dashboard_excluded_products x
                       where x.product_id = l.product_id) as is_disc
  from public.dashboard_invoice_lines l, bounds b
  where l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.invoice_date >= b.d_from and l.invoice_date <= b.d_to
)
select (select d_from::text || ' → ' || d_to::text from bounds) as period,
       round(sum(price_subtotal) filter (where not is_disc)) as product_total,
       round(sum(price_subtotal) filter (where is_disc))     as disc_total,
       round(sum(price_subtotal))                            as odoo_total,
       round(sum(qty) filter (where not is_disc), 2)         as product_units,
       round(sum(qty), 2)                                    as odoo_units
from lines;
