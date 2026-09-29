# Dabboos Product Dashboard — Design

**Date:** 2026-08-01
**Repo:** `dabboos-product-dashboard` (private)
**Status:** approved, ready for implementation planning

---

## 1. Purpose

A product analytics dashboard for Dabboos that answers four business questions:

1. **What do I buy?** — velocity, days of cover, reorder lists.
2. **What do I kill?** — frozen capital, dead vs dormant stock, liquidation candidates.
3. **What do I push, where, and to whom?** — momentum, coverage gaps, cross-sell targets.
4. **Where am I leaking money?** — discount depth, below-cost sales, margin outliers.

The dashboard is the decision surface for purchasing, liquidation, sales push, and pricing.

## 2. The golden rule

**A single wrong number destroys trust in the whole dashboard.** Every metric must be
reproducible on a named Odoo screen. Never mix bases. Never render a zero when we mean an
error. When a basis is ambiguous, label it in the UI.

## 3. Decisions taken

| Decision | Choice | Consequence |
|---|---|---|
| **Sales basis** | **Invoices only** (`account.invoice.report`) | Returns net out automatically; direct invoices (no sales order) are included; confirmed-but-uninvoiced demand is invisible; numbers will **not** match the existing sales dashboard |
| **Verification screen** | Invoicing → Reporting → **Invoice Analysis** | *Not* Sales Analysis. The existing `[A 31] = 303.5 cartons` reconciliation is no longer the reference |
| **Date field** | `invoice_date` | A June order invoiced in July counts as **July** |
| **Front end** | Static HTML + native ES modules, no build step | Chart.js from CDN; deploys by dropping the folder |
| **Aggregation** | Hybrid: one wide fact RPC + targeted drill RPCs | One definition of "a sale" shared by every module |
| **Deployment** | Netlify | Matches the other Dabboos dashboards |
| **Language** | Arabic (default) + English, RTL-aware, dark/light | Money in IQD |

### Why invoices, and what it costs

Chosen deliberately over the orders basis. The upside is that credit notes arrive signed
negative, so returns are netted without extra work, and invoices raised outside the sales
module stop being invisible. The cost is that this abandons the reconciliation already
verified against Sales Analysis, and period totals will diverge from the sales dashboard.
That divergence is **expected behaviour, not a bug** — hence the permanent basis label
(§8).

### Two properties of the invoice basis that simplify the build

- **`invoice_date` is a date, not a timestamp.** No UTC→Baghdad conversion is required on
  this basis, which removes the entire timezone-bucketing class of bug that the orders
  basis had to defend against.
- **`account.invoice.report` carries `move_id`**, which `sale.report` did not. Lines can be
  grouped back into documents, so basket / "bought together" analysis is possible here even
  though it was impossible on the orders basis. *(Subject to §4.1 introspection.)*

## 4. Data layer

### 4.1 Field introspection comes first

Field availability on `account.invoice.report` varies by Odoo release, and we have **no Odoo
UI access**. Before any sync is written, run `fields_get` on `account.invoice.report` through
n8n and record the actual field list in `docs/odoo-fields.md`. Every assumption below is
subject to that check:

- `quantity` is UoM-normalized to the product's reference unit (the same division-by-UoM-factor
  the `sale.report` view does).
- `out_refund` rows arrive with **negative** `quantity` and `price_subtotal`.
- `move_id`, `invoice_user_id`, `commercial_partner_id`, `payment_state` exist.

If any assumption fails, the design adapts before code is written — not after.

### 4.2 New table: `dashboard_invoice_lines`

Sourced from `account.invoice.report`, filtered to `state = 'posted'` and
`move_type in ('out_invoice','out_refund')`.

| Column | Source | Notes |
|---|---|---|
| `line_id` (PK) | report row `id` | equals the `account.move.line` id |
| `move_id` | `move_id` | enables basket analysis |
| `product_id` | `product_id` | joins `dashboard_products` |
| `qty` | `quantity` | **UoM-normalized**, fractional, negative for credit notes |
| `price_subtotal` | `price_subtotal` | untaxed, negative for credit notes |
| `invoice_date` | `invoice_date` | a **date** |
| `partner_id` | `commercial_partner_id` | joins `dashboard_customers` for gov/city |
| `salesperson` | `invoice_user_id` | |
| `move_type` | `move_type` | `out_invoice` / `out_refund` |
| `state`, `payment_state` | | |

Geography (`governorate`, `city`) is **not** on the invoice report — it comes from the
`dashboard_customers` join.

### 4.3 New table: `dashboard_stock_history`

`(product_id, snap_date, on_hand_qty, stock_value)`, PK `(product_id, snap_date)`.

`dashboard_stock` is a *current snapshot only* — yesterday's on-hand is lost forever. This
table is built in Phase 0 even though nothing reads it until later, because **every day of
delay is a day of history that cannot be recovered.** It later unlocks stockout tracking,
cover-days trend, and true inventory turns.

### 4.4 Reused tables (read-only, already synced)

`dashboard_products`, `dashboard_stock`, `dashboard_customers`.

### 4.5 n8n workflows

| Workflow | Schedule | Behaviour |
|---|---|---|
| **Invoice-lines backfill** | one-time | month-chunked over full history, upsert on `line_id` |
| **Invoice-lines nightly** | 02:00 | rolling ~35-day window, **delete-then-insert** |
| **Stock history** | nightly | append one row per product to `dashboard_stock_history` |

The nightly job **must delete its window before inserting**, not upsert. A cancelled invoice
*disappears* from `account.invoice.report`; a pure upsert would leave the stale row in place
forever, silently inflating revenue. This is the single most likely source of a wrong number
in the whole pipeline.

Because the report view has no reliable `write_date`, edits to invoices older than the
rolling window are caught by re-running the full backfill periodically (monthly), not by the
nightly.

### 4.6 Auth and RLS

Confirmed empirically on 2026-08-01: `dashboard_products`, `dashboard_stock`,
`dashboard_order_lines` and `dashboard_customers` return **HTTP 200 with
`Content-Range: */0`** using the anon key alone — RLS silently filters every row.
`dashboard_orders` returns a hard 401.

Therefore **the dashboard cannot read anything without a logged-in user's JWT.** The new
tables get RLS policies granting `select` to the `authenticated` role, and the RPCs are
`security invoker` so RLS still applies. The `service_role` key never leaves n8n.

## 5. Aggregation layer

One function owns the definition of a sale. Every module inherits from it, so "posted",
"excluded fixtures", and "in period" cannot come to mean two different things on two pages.

```
product_facts(date_from, date_to, salesperson, gov, customer, category, brand)
  → one row per product:
    units, revenue, margin, margin_pct, realized_price, last_invoiced,
    distinct_customers, distinct_govs, on_hand, stock_value, velocity_90d
```

Baked in: `state = 'posted'`, `move_type in ('out_invoice','out_refund')`, fixtures category
excluded (`category !~ 'عارضات|استاندات'`).

Supporting RPCs, used only where genuinely deeper data is needed:

| RPC | Returns |
|---|---|
| `product_customers(product_id, from, to)` | that product's customers by units and revenue |
| `product_cities(product_id, from, to)` | that product's governorates |
| `product_trend(product_id, months)` | monthly series |
| `category_seasonality(category)` | month × intensity matrix |
| `product_gaps(product_id)` | customers buying the category but not this product |

The browser reshapes the single `product_facts` payload to drive most modules — ABC curve,
category and brand roll-ups, frozen list, reorder list, overstock, momentum, margin outliers
are all sorts and filters over the same few hundred rows, needing no extra round trip.

### Metric definitions

| Metric | Formula |
|---|---|
| Units | `Σ qty` (credit notes negative → net) |
| Revenue | `Σ price_subtotal` (untaxed, net of returns) |
| Margin | `Σ price_margin` — **Odoo's own margin, computed at invoice time** |
| Realized price | `revenue ÷ units` |
| Discount depth | `1 − (realized_price ÷ list_price)` |
| Velocity | units in trailing 90 days ÷ 3 = units/month |
| Days of cover | `on_hand ÷ (velocity ÷ 30)` |
| Frozen | `on_hand > 0` **and** (`last_invoiced` is null **or** older than N days; N = 30/60/90, default 60) |
| Dormant vs dead | frozen, but the product's category peaks in a month that has not arrived yet → dormant |
| Mix % | product revenue ÷ total revenue |

**Margin is exact, not approximated** *(revised 2026-08-01 after field introspection)*.
The original design derived margin from the product's **current** `standard_price`, which is
wrong for any historical period because cost moves over time — and it would have needed a
permanent "approximate" caveat next to every margin figure.

`account.invoice.report` exposes **`price_margin`**, Odoo's own margin computed at invoice
time, with `inventory_value` as the cost side. We store both and sum `price_margin` directly.

The identity `price_margin = price_subtotal − inventory_value` **must be verified on real
rows before margin is trusted** (see §9). If it does not hold, fall back to the derived
formula and reinstate the caveat.

## 6. Pages

| Page | File | Answers |
|---|---|---|
| **Overview** | `index.html` | KPI band, ABC/Pareto curve, category × brand matrix, top movers, alert strip (below-cost sales, imminent stockouts, newly dead) |
| **Products** | `products.html` | Searchable table of every product with all fact columns; click → detail drawer (trend, top customers, top cities, price history) |
| **Frozen capital** | `frozen.html` | Aging buckets 60/90/180, dead vs dormant, value at risk by category and brand, liquidation candidates |
| **Stock & reorder** | `stock.html` | Days of cover, reorder-now list, overstock list, stockout risk |
| **Price & margin** | `pricing.html` | Realized vs list price, discount depth, below-cost alerts, margin distribution, price variance per SKU across customers |
| **Coverage & growth** | `growth.html` | MoM/YoY momentum, decelerating watchlist, governorate coverage gaps, cross-sell targets |

## 7. Structure

```
index.html  products.html  frozen.html  stock.html  pricing.html  growth.html
assets/
  css/style.css
  js/
    config.js    Supabase URL + anon key, constants, thresholds
    auth.js      login, session, JWT headers
    api.js       the ONLY file that knows Supabase exists — RPC + REST + paging
    filters.js   URL-backed filter state, shared filter bar
    format.js    IQD, compact numbers, dates, esc()
    calc.js      PURE functions, no I/O — ABC, buckets, cover, momentum
    charts.js    the ONLY file that knows Chart.js exists — theme-aware palette
    shell.js     nav, language toggle, theme, basis label
    pages/*.js   one per page
supabase/
  01_schema.sql     tables, indexes, RLS policies
  02_functions.sql  RPCs
n8n/
  invoice-lines-backfill.workflow.json
  invoice-lines-nightly.workflow.json
  stock-history-nightly.workflow.json
test/
  calc.test.js      node:test, no dependencies
docs/
```

Each file has one job and no knowledge of the others' internals. `calc.js` being pure is what
makes the numbers testable without a network or a database.

## 8. Cross-cutting UI rules

1. **Permanent basis label** on every page: `Invoice basis · Invoice Analysis · IQD`. This is
   what makes divergence from the sales dashboard self-explaining.
2. **Filter state lives in the URL** so filters survive navigation and pages are linkable.
3. **Error ≠ empty.** A failed RPC shows an error banner; a query with no matching rows shows
   "no data for these filters". Conflating them is how a dashboard lies.
4. **Escape every DB string** before `innerHTML` — product, customer and city names are
   user-controlled (stored-XSS risk). Chart.js `<canvas>` labels are safe.
5. **Expired JWT** redirects to login rather than rendering zeros.
6. Money in **IQD**, large numbers compacted to K/M, currency never hardcoded as a symbol.
7. Quantities are in the **product's UoM** and can be **fractional** (e.g. 303.5 cartons).

## 9. Testing and verification

- `calc.js` unit-tested with `node:test` — no dependencies, no network.
- **Numeric verification:** an n8n API probe pulls one known product's totals straight from
  `account.invoice.report` and compares them to what `product_facts` returns for the same
  period. This is the substitute for Odoo UI access.
- **Hand-off check:** a documented procedure for whoever *does* have Odoo UI access to
  confirm one product against the Invoice Analysis pivot. Until that check is signed off, the
  numbers are "verified against the API" and not "verified against Odoo".
- **The end-date trap:** Odoo's date filters drop the final day when the end is
  `00:00:00`. Any manual comparison must set the end to the next day or `23:59:59`.

## 10. Phases

| Phase | Delivers | Gate |
|---|---|---|
| **0 — foundation** | Repo, schema, RLS, invoice sync, stock history, field introspection, one product verified end to end | No UI. Nothing else starts until a number is proven right |
| **1 — core** | Shell, auth, `product_facts`, Overview, Products explorer | The dashboard becomes usable |
| **2 — decisions** | Frozen capital, Stock & reorder | |
| **3 — money** | Price & margin, Coverage & growth | |

## 11. Known limitations

State these in the UI rather than letting users discover them:

1. **No stock history before Phase 0 ships.** Cover-days trend and stockout counts only
   become meaningful after the snapshot table has been accumulating.
2. ~~Margin uses current cost~~ — **resolved.** Odoo's `price_margin` gives margin at invoice
   time (§5). Pending the identity check in §9.
2b. **Brand may be sparsely populated.** `product_brand_id` exists on the invoice report, but
   the sampled product had it unset. Fill rate is measured after the backfill; if low, brand
   breakdowns are hidden rather than shown mostly-empty.
3. **No expiry, batch, or purchase data** in the synced tables — no supplier lead times, no
   shelf-life risk, no true purchase-cost turns.
4. **Confirmed-but-uninvoiced demand is invisible** — a direct consequence of the invoice
   basis.
5. **Edits to invoices older than the rolling window** are only caught by the periodic full
   backfill.

## 12. Open items

- The Odoo field introspection (§4.1) may change §4.2. Resolve before writing the sync.
- History depth for the backfill — determined once we can query row counts with a JWT.
- Whoever has Odoo UI access must eventually sign off the §9 hand-off check.
