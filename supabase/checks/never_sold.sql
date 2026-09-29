-- Reconciliation: the "Never sold" figures on the Overview page
-- Run in: Supabase -> SQL Editor. Read-only, safe to run any time.
--
-- ===========================================================================
-- WHAT THE DASHBOARD MEANS BY "NEVER SOLD"
-- ===========================================================================
-- A product in dashboard_products with NO posted invoice line at all.
--
-- NOT "no sales in the selected period". product_facts computes last_invoiced
-- as max(invoice_date) across the product's WHOLE history, deliberately
-- outside the date filter, so moving the dates on the Overview page does not
-- change this list. "Never sold" is a fact about the product, not about the
-- window being looked at.
--
-- ===========================================================================
-- ⚠️ THE ONE THAT WILL BITE YOU WHEN COMPARING TO ODOO
-- ===========================================================================
-- "Never" means "never WITHIN THE SYNCED DATA". dashboard_invoice_lines holds
-- only what n8n backfilled — section 1 below prints that window. A product
-- whose last sale in Odoo predates it looks never-sold here and has sales
-- there. That is not a bug in either system; it is the backfill boundary.
--
-- So compare against Odoo RESTRICTED TO THE SAME DATE RANGE, or extend the
-- backfill. Anything else compares two different questions.

-- ===========================================================================
-- 1. The window — establish this BEFORE comparing anything
-- ===========================================================================
select 'invoice data covers' as what,
       min(invoice_date)::text || '  →  ' || max(invoice_date)::text as detail,
       count(*)::text as lines
from public.dashboard_invoice_lines
where state = 'posted' and move_type in ('out_invoice', 'out_refund');

-- ===========================================================================
-- 2. The headline numbers, exactly as the tile computes them
-- ===========================================================================
-- These must match the Overview "منتجات لم تُبع أبداً" tile: count, value, and
-- the share of the catalogue.
with catalogue as (
  select p.product_id, p.sku, p.name, p.category, p.active,
         coalesce(s.on_hand_qty, 0)  as on_hand,
         coalesce(s.stock_value, 0)  as stock_value,
         exists (select 1 from public.dashboard_invoice_lines l
                  where l.product_id = p.product_id
                    and l.state = 'posted'
                    and l.move_type in ('out_invoice', 'out_refund')) as ever_sold
  from public.dashboard_products p
  left join public.dashboard_stock s on s.product_id = p.product_id
  -- the two exclusions product_facts applies, repeated verbatim
  where coalesce(p.category, '') !~ 'عارضات|استاندات'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = p.product_id)
)
select
  count(*)                                              as products_in_scope,
  count(*) filter (where not ever_sold)                 as never_sold,
  round(100.0 * count(*) filter (where not ever_sold)
        / nullif(count(*), 0), 1)                       as never_sold_pct,
  round(sum(stock_value) filter (where not ever_sold))  as never_sold_value,
  -- If this is large, most never-sold products hold no stock either: they are
  -- catalogue clutter rather than frozen money, and the value tile understates
  -- how many rows the list actually has.
  count(*) filter (where not ever_sold and on_hand <= 0) as never_sold_no_stock,
  -- Odoo's product list hides archived products by default. If this is not 0,
  -- that alone explains a count difference.
  count(*) filter (where not ever_sold and active is not true) as never_sold_archived
from catalogue;

-- ===========================================================================
-- 3. The list itself — spot-check these in Odoo one by one
-- ===========================================================================
-- Ordered by stock value, the same as the page. Take the top few, search each
-- SKU in Odoo, and open its sales history.
with catalogue as (
  select p.product_id, p.sku, p.name, p.category, p.active,
         coalesce(s.on_hand_qty, 0) as on_hand,
         coalesce(s.stock_value, 0) as stock_value
  from public.dashboard_products p
  left join public.dashboard_stock s on s.product_id = p.product_id
  where coalesce(p.category, '') !~ 'عارضات|استاندات'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = p.product_id)
    and not exists (select 1 from public.dashboard_invoice_lines l
                     where l.product_id = p.product_id
                       and l.state = 'posted'
                       and l.move_type in ('out_invoice', 'out_refund'))
)
select product_id, sku, name, category,
       on_hand, round(stock_value) as stock_value,
       case when active is true then '' else 'ARCHIVED IN ODOO' end as note
from catalogue
order by stock_value desc, name
limit 100;

-- ===========================================================================
-- 4. What was excluded, so a count difference has somewhere to land
-- ===========================================================================
-- Odoo's product count will not match `products_in_scope` above, because the
-- dashboard drops these on purpose. This says how many.
select 'fixtures (عارضات/استاندات)' as excluded_because,
       count(*)::text as products
from public.dashboard_products
where coalesce(category, '') ~ 'عارضات|استاندات'
union all
select 'invoice-level discount lines',
       count(*)::text
from public.dashboard_excluded_products
union all
select 'archived in Odoo (still counted by this dashboard)',
       count(*)::text
from public.dashboard_products
where active is not true;

-- ===========================================================================
-- 5. Sanity check — is the products sync actually current?
-- ===========================================================================
-- A stale products sync inflates "never sold" with products Odoo has since
-- sold, and no amount of checking Odoo will explain the difference.
select 'products synced'  as what, count(*)::text as n,
       max(updated_at)::text as last_updated from public.dashboard_products
union all
select 'stock synced', count(*)::text, max(updated_at)::text from public.dashboard_stock;
