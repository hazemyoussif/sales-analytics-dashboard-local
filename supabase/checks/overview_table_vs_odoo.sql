-- The Overview "Products" table, side by side with Odoo's Invoice Analysis
-- Run in: Supabase -> SQL Editor. Read-only. ONE statement — run the whole file.
--
-- ===========================================================================
-- EDIT THE TWO DATES ON THE NEXT LINE OF SQL, THEN RUN
-- ===========================================================================
-- Set them to the SAME range you selected in Odoo. This is the single most
-- common source of a false mismatch: the dashboard defaults to its whole data
-- window, Odoo defaults to nothing, and comparing four months against one
-- month produces a "discrepancy" that is only a filter.
--
-- ===========================================================================
-- WHAT THIS PRODUCES
-- ===========================================================================
-- One row per product, ordered by revenue, with the same two measures Odoo's
-- screen shows — Untaxed Amount and Product Quantity — followed by three
-- reconciliation rows:
--
--   TOTAL products     what the dashboard's revenue tile shows
--   TOTAL [DISC]       the invoice-level discount, which the dashboard reports
--                      SEPARATELY and excludes from every product table
--   GRAND TOTAL        products + [DISC] = what Odoo's screen shows
--
-- If GRAND TOTAL matches Odoo and the per-product rows match, the dashboard is
-- correct and the only difference is that Odoo mixes the discount in with the
-- products while this dashboard keeps it apart.
--
-- ===========================================================================
-- IN ODOO, TO PRODUCE THE COMPARABLE SCREEN
-- ===========================================================================
--   Invoicing -> Reporting -> Invoice Analysis
--   Filter:   Invoiced,  Invoice Date between the same two dates
--   Group by: Product
--   Measures: Untaxed Amount, Product Quantity
--
-- ===========================================================================
-- WHY A PRODUCT CAN APPEAR HERE AND NOT IN ODOO (OR VICE VERSA)
-- ===========================================================================
--   * fixtures (عارضات / استاندات) are excluded from every dashboard metric
--   * [DISC] lines are excluded from product rows and totalled separately
--   * a product with sales AND equal returns nets to zero and is filtered out
--     below, while Odoo still lists it
--   * the dashboard only knows what n8n has backfilled — check the window in
--     the health strip before blaming the maths

with bounds as (
  select date '2026-07-01' as d_from,     -- <<<< EDIT
         date '2026-07-31' as d_to        -- <<<< EDIT
),

-- product_facts is the function the Overview page itself calls, so these rows
-- ARE the dashboard's answer, not a re-implementation of it. If they disagree
-- with Odoo, the disagreement is real.
facts as (
  select f.*
  from bounds b, lateral public.product_facts(b.d_from, b.d_to) f
),

active as (
  select * from facts where coalesce(units, 0) <> 0 or coalesce(revenue, 0) <> 0
),

ranked as (
  select a.*, row_number() over (order by coalesce(a.revenue, 0) desc) as rn
  from active a
),

-- The invoice-level discount lines, which product_facts deliberately excludes.
-- Odoo shows them as just another product row, so they have to be added back
-- before the grand totals can be compared.
disc as (
  select coalesce(sum(l.price_subtotal), 0) as disc_value,
         coalesce(sum(l.qty), 0)            as disc_units
  from public.dashboard_invoice_lines l
  join public.dashboard_excluded_products x on x.product_id = l.product_id
  cross join bounds b
  where l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.invoice_date >= b.d_from and l.invoice_date <= b.d_to
),

totals as (
  select coalesce(sum(coalesce(revenue, 0)), 0) as prod_value,
         coalesce(sum(coalesce(units, 0)), 0)   as prod_units,
         count(*)                               as prod_count
  from active
)

select * from (
  -- ---- the products, exactly as the Overview table ranks them
  select 1                                as sort,
         r.rn::text                       as rank,
         r.sku,
         r.name                           as product,
         r.category,
         round(r.units, 2)                as product_quantity,   -- Odoo's column
         round(r.revenue)                 as untaxed_amount,     -- Odoo's column
         round(r.on_hand, 2)              as on_hand,
         r.last_invoiced::text            as last_sale,
         case when r.rn <= 60 then 'yes' else '' end as in_dashboard_top_60
  from ranked r

  union all
  select 2, '', '', '── TOTAL: products (dashboard revenue tile) ──', '',
         round(t.prod_units, 2), round(t.prod_value), null::numeric, t.prod_count::text, ''
  from totals t

  union all
  select 3, '', '', '── TOTAL: [DISC] invoice-level discount ──', '',
         round(d.disc_units, 2), round(d.disc_value), null::numeric, '', ''
  from disc d

  union all
  -- This is the number that must equal Odoo's grand total.
  select 4, '', '', '── GRAND TOTAL = what Odoo shows ──', '',
         round(t.prod_units + d.disc_units, 2),
         round(t.prod_value + d.disc_value), null::numeric,
         (select d_from::text || ' → ' || d_to::text from bounds), ''
  from totals t, disc d
) x
order by sort, coalesce(nullif(rank, '')::int, 0);
