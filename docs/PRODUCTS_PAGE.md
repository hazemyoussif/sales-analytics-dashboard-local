# Products & Warehouse page — build notes, numbers, and Odoo verification

> Status: **removed from the live dashboard** (2026-07-30) but fully documented here so
> it can be rebuilt or re-enabled. The **data layer, tables, n8n syncs, pure calc
> logic (`assets/js/products-calc.js` + `test/products.test.js`), and the schema
> (`supabase/products-warehouse.sql`) are kept.** Only the page (`products.html`) and
> its nav/auth wiring were removed. Original spec:
> `docs/superpowers/specs/2026-07-23-products-warehouse-design.md`.

## 1. What it was
A page answering two questions for management:
1. **Frozen stock** — which products are *in stock but not selling* (dead capital), and why.
2. **Hot products** — which products sell the most, and **to which customer & city**.

Filterable by **salesperson · customer · city · period**, with **quantity-first** KPIs.

## 2. How it was built (data flow)
**Odoo → n8n → Supabase → page.** Three tables:

| Table | Source in Odoo | Key fields |
|---|---|---|
| `dashboard_products` | `product.product` (+ template) | product_id, name, sku, category, **cost** (`standard_price`), **uom** |
| `dashboard_stock` | `product.product.qty_available` | product_id, **on_hand_qty**, stock_value (= on_hand × cost, approx) |
| `dashboard_order_lines` | **`sale.report`** (Sales Analysis) | line_id, product_id, **qty**, price_subtotal, price_total, date_order, partner_id, city, gov, salesperson, state |

### The critical decision: source order-lines from `sale.report`, NOT `sale.order.line`
`sale.order.line.product_uom_qty` is the **raw** line quantity in the **line's** unit of
measure — so summing it mixes cartons + pieces (e.g. `[A 31]` summed to **1,061**, garbage).
**`sale.report.product_uom_qty` is Odoo's "Qty Ordered"** — already **UoM-normalized to the
product's reference unit** (so `[A 31]` = **303.5 cartons**, matching Odoo), and its **`date`
is the real order date**. Sourcing from `sale.report` makes the page reconcile with Odoo's
Sales Analysis by construction. (`sale.report` has **no `order_id`** field, so `order_id` is
null on lines; its row `id` equals the order-line id, so upsert on `line_id` still works.)

### n8n syncs
- **Products + Stock** — every 2h, from `product.product` (`Dabboos Products Sync`).
- **Order-lines full backfill** — one-time, month-chunked from `sale.report`
  (`Dabboos Order-Lines from sale.report BACKFILL`). Truncate `dashboard_order_lines` first.
- **Order-lines nightly top-up** — 02:00, upserts the **last ~10 days** from `sale.report`
  (`Dabboos Order-Lines NIGHTLY refresh`). No `write_date` on `sale.report`, so it can't
  auto-catch cancellations / edits to *older* orders — re-run the full backfill monthly to reset drift.

### Front-end
- `products.html` (page) + `assets/js/products-calc.js` (pure, unit-tested logic:
  `classifyFrozen`, `productVelocity`, `productMarkets`, `lineMargin`, `aggregateLines`).

## 3. The numbers on the page, and how to check each in Odoo

**Golden rules for every Odoo comparison:**
- Report: **Sales → Reporting → Sales (Sales Analysis pivot)**.
- Filter **Sales Orders** (confirmed = state `sale`/`done`).
- **Order Date end must be the *next day* / `23:59:59`** — an end of `06/30 00:00:00` silently
  **drops all of June 30** (this caused a whole "127-unit gap" that was purely a filter mistake).
- Exclude the fixtures category **عارضات و استاندات** (the page hides it).
- Quantities are in the **product's UoM** (e.g. cartons), and can be **fractional**.
- Days are bucketed in **Asia/Baghdad**; the page uses `date_order` (real order date).

### KPI tiles (quantity-first)
| KPI | Meaning | Odoo check |
|---|---|---|
| **Units sold** | Σ `qty` in the period | Sales Analysis → **Qty Ordered** grand total |
| **Units in stock** | Σ `on_hand_qty` | Inventory → Products → sum of **On Hand** (product's unit, all internal locations, live snapshot) |
| **Frozen SKUs** (+ frozen units) | # products in stock & idle > threshold | two-part, see Frozen below |
| **Top product** | #1 by units in the period | Sales Analysis → Qty Ordered by Product, top row |

### Section A — Frozen (in stock, not sold recently)
Rule: **`on_hand_qty > 0` AND** (no confirmed sale in **N days** — pills 30/60/90, default 60).
Columns: product · category · on-hand · value · **last sale** · **days idle** · velocity (units/mo, trailing 90d).
**Odoo check (two parts):**
1. **On hand** → Inventory → Products → the product's **On Hand** = `on_hand_qty` (same unit).
2. **Last sale** → Sales → Orders filtered to that product → newest order is **> N days** ago.

### Section B — Hot products (by customer & city)
| Column | Meaning | Odoo check |
|---|---|---|
| **Units** | Σ `qty` (normalized) | Sales Analysis → **Qty Ordered** by Product |
| **Revenue** | Σ `price_subtotal` (untaxed) | Sales Analysis → **Untaxed Total** by Product |
| **Margin** | Revenue − cost × units (gross) | Sales Analysis → **Margin** measure (close; page uses current `standard_price`) |
| **Mix %** | product's share of period revenue | product Untaxed Total ÷ grand total |

**Drill (click a product):**
- **Top customers** → Sales Analysis, filter Product, **Group By → Customer**, Qty Ordered.
- **Top cities / governorates** → same, **Group By → Customer ▸ State**, Qty Ordered.
- (In the page, clicking a customer/city then re-filters the whole page to them.)

## 4. Verified reconciliations (2026, June)
- `[A 31] اتلومي مكسرات كاكو` → **303.5** cartons on both sides (after the `sale.report` fix).
- June grand total → DB **35,743** vs Odoo **35,742** (rounding).
- `[H 100]` June → **1,162** once Odoo's end date included June 30 (the `00:00` trap).

## 5. Verification SQL (Supabase = what the page computes)
```sql
-- units / revenue / margin per product for a period
select p.sku, p.name,
       round(sum(l.qty), 1)                                        as units,
       round(sum(l.price_subtotal))                                as revenue,
       round(sum(l.price_subtotal) - sum(l.qty * coalesce(p.cost,0))) as margin
from dashboard_order_lines l
join dashboard_products p on p.product_id = l.product_id
where date(l.date_order at time zone 'Asia/Baghdad') between '2026-06-01' and '2026-06-30'
  and l.state in ('sale','done')
  and coalesce(p.category,'') !~ 'عارضات|استاندات'
group by p.sku, p.name order by units desc;

-- frozen list (in stock, no confirmed sale in 60 days)
select p.sku, p.name, s.on_hand_qty,
       (select max(date(l.date_order at time zone 'Asia/Baghdad'))
          from dashboard_order_lines l
          where l.product_id = p.product_id and l.state in ('sale','done')) as last_sale
from dashboard_products p
join dashboard_stock s on s.product_id = p.product_id
where s.on_hand_qty > 0 and coalesce(p.category,'') !~ 'عارضات|استاندات'
order by s.on_hand_qty desc;
```

## 6. Lessons (every "gap" was a filter/basis mismatch, not a dashboard bug)
1. **Use `sale.report`** for quantities (UoM-normalized) — raw `sale.order.line` mixes units.
2. **Odoo end date** must include the last day (`07/01`, not `06/30 00:00`).
3. **`date_order`** (order date), bucketed in **Asia/Baghdad**, matches Odoo's Order Date.
4. **Confirmed only** (`sale`/`done`); exclude **عارضات/استاندات** fixtures.
5. Quantities are **in the product's UoM** and can be **fractional** (303.5 cartons).
6. **Performance:** the page loaded ~80–120k raw lines into the browser → slow. If rebuilt,
   do **server-side aggregation** (Postgres views/RPCs return small summaries) instead of
   shipping every line to the client.
