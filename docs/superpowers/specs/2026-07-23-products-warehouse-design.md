# Products & Warehouse analytics page — design

**Date:** 2026-07-23
**Branch:** `feat/products-warehouse`
**Files touched:** new `products.html`; `assets/js/common.js` (nav entry, i18n keys,
data-source manifest, loaders); `assets/js/config.js` (table names); new
`supabase/*.sql` (3 tables + RLS); n8n workflows (3 new pipelines); all HTML
cache-buster bump; `service-worker.js` VERSION bump; `docs/` updates.

## Goal
A single **Products & Warehouse** page that answers two owner questions at a glance:

1. **Which products are frozen — and why.** Frozen = *in stock but not selling*.
2. **Which products sell a lot — and to which customer & city.**

Everything must be reproducible on a named Odoo screen (Odoo-comparability rule):
each card carries Odoo vocabulary + a 🔍 "check in Odoo" line.

## Non-goals (YAGNI, for the first version)
- No per-warehouse / per-location stock split (single company-wide on-hand for
  now; revisit if multiple warehouses matter — see Open questions).
- No purchasing / reorder-point automation, no supplier analytics.
- No manufacturing/BOM, no POS lines (sale.order.line only for now).
- No forecasting. Velocity is a trailing average, not a prediction.

## Decisions locked with the owner
- **Frozen rule:** `on_hand_qty > 0` AND `last_sale_date` is null or older than
  **60 days** (threshold tunable 30/60/90 in the UI).
- **Build both stories in one page** (not phased), but each number is verified
  against Odoo slice by slice during implementation.
- **Single company-wide stock** number per product (all internal locations summed).
- **Denormalize** `date_order` / `partner_id` / `city` / `gov` onto each order
  line at sync time, so *product × customer × city* is one fast read.
- History from **2026-01-01**, consistent with every other sync.

---

## Data layer (foundation)

Three new Supabase tables in the **main** dashboard project
(`puqfldltipedlodwfyex`), fed by n8n. All follow the existing rules
(`docs/N8N_AUDIT.md`): `returnAll:true`, paginate reads, Odoo `false`→`null`,
upsert `on_conflict=<pk>`, FK parents before children, RLS policy per table,
cache-buster bump.

### 1. `dashboard_products` (master)
- **PK** `product_id`.
- Fields: `name` (display_name), `sku` (default_code), `category` (categ_id label),
  `brand` (product.template brand field), `cost` (standard_price), `list_price`,
  `uom`, `active`, `updated_at`.
- Source: `product.product` read + `product.template` for brand/category.
- Refresh: full sync every ~2h (like customers). Small table.
- Reuses the proven pull in `DabboosTecj-Unsold products/n8n/Dead_Stock_Sync`.

### 2. `dashboard_stock` (on-hand snapshot)
- **PK** `product_id`.
- Fields: `on_hand_qty`, `stock_value` (cost valuation), `updated_at`.
- Source: `stock.quant` `read_group` over `location_id.usage = internal`,
  `quantity > 0`; measures `quantity:sum`, `value:sum`, grouped by `product_id`.
- Refresh: every ~20–60 min. It is a **snapshot**, not history — an upsert that
  overwrites the current on-hand per product. Products that drop to zero on-hand
  must be zeroed/removed (reconcile: a product no longer in the read_group has no
  stock → set `on_hand_qty = 0` so it stops looking stocked). This is the
  inventory analogue of the orders "ghost" problem; handle with a small reconcile
  step (fetch the full current set each run and zero anything missing).

### 3. `dashboard_order_lines` (the heavy one)
- **PK** `line_id`.
- Fields: `order_id` (FK → dashboard_orders), `product_id` (FK → dashboard_products),
  `qty` (product_uom_qty), `price_subtotal`, `price_total`, plus **denormalized**
  `date_order`, `partner_id`, `city`, `gov`, `salesperson`/`user_id`, `state`,
  `updated_at`.
- Source: `sale.order.line`. **Confirmed sales only** — the parent order's
  `state` in (`sale`,`done`); quotations/cancel excluded (company policy).
- Enrichment: `date_order` from the order; `city`/`gov` from the customer master
  (State-verbatim, else "None"), copied at sync time.
- Refresh: 20-min incremental (parent order `write_date` window) + a
  **month-chunked backfill** (Cloudflare ~100s cap; ≈11 lines per order → tens of
  thousands of rows, chunked ≤250/upsert like the orders backfill).
- Reconcile: mirror the orders reconcile — lines of cancelled/deleted orders must
  be removed so sums stay honest.

---

## Page layout (`products.html`)

Shared chrome (`buildChrome`) — header, filters, and the live "Synced from Odoo"
countdown. Two clearly separated sections on one page (tab or stacked):

### KPI tiles (top)
- **Total stock value** (Σ `stock_value`).
- **Frozen value** — capital stuck (Σ `stock_value` of frozen products).
- **# frozen SKUs** and **% of stock value frozen**.
- **Top seller** (this period) — product + revenue.
Reuses the KPI tile pattern; each tile gets its 🔍 Odoo line.

### Section A — Frozen (dead stock)
- Threshold control: 30 / 60 / 90 days (default 60).
- Table, sorted by **frozen value desc** (biggest stuck money first):
  product · category/brand · on-hand qty · stock value · **last sale date** ·
  days idle · velocity (units/mo, trailing 90d). 🔴 badge when never sold.
- **"Why" per row** (expand): last sale date, velocity trend, and the cities/govs
  it *did* sell to (from order lines) — "sells only in Basra; 400 units idle."
  When a product never sold anywhere, say so plainly.
- Chart: frozen value by category (bar) — where the stuck money concentrates.
- 🔍 Odoo line: Inventory → Products (on-hand) + Sales Analysis by Product
  (last sale / units), tax-inclusive, confirmed only.

### Section B — Hot products (by customer & city)
- Date range (default **current calendar month**), shared filter bar.
- Top-products bar (by revenue; toggle to units).
- Click a product → drill panel:
  - **Top customers** for that product (units + revenue).
  - **Top cities / governorates** for that product.
- Bonus **gross margin** column: `revenue − cost × qty` (cost from
  `dashboard_products.standard_price`); labeled as cost-based, verify separately.
- 🔍 Odoo line: Sales Analysis grouped by Product × Customer (or Customer > State),
  same range, Total measure.

---

## Data & computation

- **Frozen classification** (pure fn `classifyFrozen`): input product master +
  stock + `lastSaleByProduct` (max `date_order` per product from confirmed lines)
  + threshold days → `{ product_id, on_hand_qty, stock_value, last_sale,
  days_idle, frozen: bool, never_sold: bool }`.
- **Velocity** (pure fn `productVelocity`): units sold in trailing 90d ÷ 3 →
  units/month per product.
- **Top products by customer/city** (pure fn `aggregateLines`): group confirmed
  lines in the window by product, then by partner and by gov/city → sorted totals.
- **Where-it-sells** (pure fn `productMarkets`): distinct govs/cities a product's
  lines went to, ranked — powers the frozen "why".
- **Margin** (pure fn `lineMargin`): `price_subtotal − cost × qty`.

All amounts via `fmtMoney`/`fmtMoneyFull`. Baghdad calendar for date bucketing.

## Pure functions to extract + unit-test in Node
Per project convention (no browser harness):
`classifyFrozen`, `productVelocity`, `aggregateLines`, `productMarkets`,
`lineMargin`. Each gets a small fixture test run with `node`, plus
`node --check` on `common.js` and a syntax check of the inline script.

## Charts / dataviz
Apply the **dataviz skill** before writing chart code (magnitude bars for value;
one neutral accent; red reserved for frozen/negative-margin signals; accessible
light/dark). Keep Chart.js; canvas labels need no escaping.

## Hard rules to honor
- **Escape every DB string** (`D.esc`): product name, category, brand, customer,
  city — all user-controlled, all go through `esc` before `innerHTML`.
- **Confirmed sales only** (`sale`/`done`) for every sales number.
- **New user-facing strings** in BOTH `I18N.ar` and `I18N.en`, via `D.t()`.
- **RLS** on all 3 new tables (copy the existing policy pattern;
  `supabase/auth-setup.sql`), and a **page permission** in `dash_users` so the
  nav link + access are role-gated (auth.js is the control, not the UI).
- Register the 3 tables in the admin **data-source visibility** manifest.
- **Service worker never caches Supabase**; bump `?v=NN` in ALL HTML +
  `VERSION` in `service-worker.js` (currently v68 → next).
- Never put the `service_role` key in the browser — only the anon key; the new
  syncs use the service key **in n8n only**.

## Verification (numbers must be trustworthy)
- Node fixture tests for the five pure functions above.
- `node --check` on all JS.
- Odoo reconciliation recipes documented per card:
  - Stock value ↔ Inventory → Reporting → Stock Valuation.
  - Frozen list ↔ products with on-hand and no confirmed sale in 60d
    (Sales Analysis by Product, last sale date).
  - Hot products ↔ Sales Analysis (Product × Customer / State), Total, same range.
- Manual: `python -m http.server 8123`, open `products.html`; confirm both
  sections, threshold control, drill panel, and that totals match Odoo.

## Rollout
1. Supabase: create the 3 tables + RLS (`supabase/products-warehouse.sql`).
2. n8n: import the 3 pipelines; run the backfills (products, stock, order-lines).
3. Verify a handful of numbers against Odoo before announcing.
4. Merge the PR; host rebuilds `main`; hard-refresh to load the new page.

## Open questions (revisit after v1 — "change or add later")
- **Multiple warehouses?** If yes, `dashboard_stock` becomes `(product_id,
  location)` and we add a "stocked here, sells there" signal.
- **Margin trust:** `standard_price` may not reflect landed cost; confirm with
  accounting before leaning on margin.
- **Returns of products** (credit-note lines): out of scope for v1; the frozen
  and hot stories use sales lines only.
