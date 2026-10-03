# Products & Warehouse Page — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Products & Warehouse page that shows which products are frozen (in stock, no sale in 60+ days) and why, and which products sell most by customer & city.

**Architecture:** Three new Supabase tables (`dashboard_products`, `dashboard_stock`, `dashboard_order_lines`) fed by n8n from Odoo; a new static `products.html` reads them via PostgREST and renders two sections (Frozen dead-stock, Hot products) using pure aggregation functions in `common.js` that are Node-unit-tested.

**Tech Stack:** Plain HTML + vanilla JS + Chart.js (CDN), Supabase/PostgREST (anon key + RLS), n8n (service key), Node for pure-function tests. No build step.

## Global Constraints

- Confirmed sales only: parent order `state` in (`sale`,`done`); never count quotations/cancel.
- Escape every DB string with `D.esc(...)` before `innerHTML` (product/category/brand/customer/city names).
- New user-facing strings go in BOTH `I18N.ar` and `I18N.en` in `common.js`, via `D.t("key")`.
- Money via `fmtMoney`/`fmtMoneyFull`; never hardcode a currency symbol.
- Baghdad calendar (`D.bagDay`) for date bucketing; history from `2026-01-01`.
- Odoo `false` → `null` before upsert; upsert `on_conflict=<pk>`; FK parents before children; `returnAll:true`; paginate reads (`sbGetAll` with a unique sort tiebreaker).
- RLS on all new tables; page access gated in `dash_users` (auth.js is the control, not the UI).
- Service worker never caches Supabase; bump `?v=NN` in ALL HTML + `VERSION` in `service-worker.js` (currently **v68**).
- `service_role` key only in n8n, never in the browser.
- Odoo-comparability: every card gets Odoo vocabulary + a 🔍 verify-in-Odoo line (`chk_*` i18n key).

## File Structure

- Create `supabase/products-warehouse.sql` — DDL for 3 tables + indexes + RLS.
- Create n8n workflow JSON(s) in `Downloads/` (not in repo) — 3 pipelines + backfills.
- Create `products.html` — the page (inline `<script>` using `window.DASH`).
- Modify `assets/js/config.js` — add table names to `CFG.TABLES`.
- Modify `assets/js/common.js` — nav entry in `PAGES`, i18n keys, `DATA_SOURCES` manifest entries, loaders (`loadProducts`, `loadStock`, `loadOrderLines`), and the 5 pure functions (exported for tests).
- Create `test/products.test.js` — Node fixture tests for the pure functions.
- Modify all `*.html` + `service-worker.js` — cache-buster bump.
- Modify `docs/ODOO_MODELS.md`, `CHANGELOG.md`.

---

## PHASE 0 — Supabase schema (operational: you run the SQL)

### Task 0.1: Create the three tables + RLS

**Files:** Create `supabase/products-warehouse.sql`

- [ ] **Step 1: Write the DDL** (copy RLS pattern from `supabase/auth-setup.sql`)

```sql
-- Products & Warehouse tables. Run once in Supabase SQL editor.
create table if not exists dashboard_products (
  product_id  bigint primary key,
  name        text,
  sku         text,
  category    text,
  brand       text,
  cost        numeric default 0,   -- standard_price
  list_price  numeric default 0,
  uom         text,
  active      boolean default true,
  updated_at  timestamptz default now()
);

create table if not exists dashboard_stock (
  product_id   bigint primary key references dashboard_products(product_id),
  on_hand_qty  numeric default 0,
  stock_value  numeric default 0,
  updated_at   timestamptz default now()
);

create table if not exists dashboard_order_lines (
  line_id        bigint primary key,
  order_id       bigint,
  product_id     bigint,
  qty            numeric default 0,
  price_subtotal numeric default 0,
  price_total    numeric default 0,
  date_order     timestamptz,
  partner_id     bigint,
  city           text,
  gov            text,
  salesperson    text,
  user_id        bigint,
  state          text,
  updated_at     timestamptz default now()
);
create index if not exists idx_ol_product on dashboard_order_lines(product_id);
create index if not exists idx_ol_date    on dashboard_order_lines(date_order);
create index if not exists idx_ol_partner on dashboard_order_lines(partner_id);
create index if not exists idx_stock_qty  on dashboard_stock(on_hand_qty);

-- RLS: authenticated users may read; only service_role writes (copy the exact
-- policy shape used by dashboard_orders in auth-setup.sql).
alter table dashboard_products    enable row level security;
alter table dashboard_stock       enable row level security;
alter table dashboard_order_lines enable row level security;

create policy p_products_read on dashboard_products
  for select to authenticated using (true);
create policy p_stock_read on dashboard_stock
  for select to authenticated using (true);
create policy p_ol_read on dashboard_order_lines
  for select to authenticated using (true);
```

- [ ] **Step 2: You run it** in Supabase SQL editor. Expected: "Success. No rows returned." Verify the three tables appear under Table Editor with RLS enabled.

- [ ] **Step 3: Commit the SQL file**

```bash
git add supabase/products-warehouse.sql
git commit -m "feat(sql): products/stock/order_lines tables + RLS"
```

**Gate:** confirm the policy shape matches `dashboard_orders` in `auth-setup.sql` (same `authenticated`/`select`/service-role-write pattern) before moving on.

---

## PHASE 1 — n8n syncs (operational: you import + backfill)

Build by adapting existing proven workflows. Each pipeline = incremental (schedule) + manual backfill, upsert on PK, chunked ≤250 rows/POST. Reuse the Config/credential nodes from the existing sync file.

### Task 1.1: Products master sync
**Source:** `product.product` read + `product.template` (brand/category). Fields: `display_name`, `default_code`, `categ_id`, `product_tmpl_id`, `standard_price`, `list_price`, `uom_id`, `active`. Shape → `dashboard_products` rows (arr/id0/num helpers; `false`→`null`). Upsert `on_conflict=product_id`. Full fetch every 2h + a manual backfill trigger. (Adapt `Dead_Stock_Sync`'s product read node.)
- [ ] Build node chain; upsert; run backfill.
- [ ] **Verify:** row count ≈ Odoo product count (Inventory → Products). Spot-check one product's cost = Odoo `standard_price`.

### Task 1.2: Stock snapshot sync (+ ghost-zeroing)
**Source:** `stock.quant` `read_group` `[['location_id.usage','=','internal'],['quantity','>',0]]`, measures `quantity:sum`,`value:sum`, group `product_id`. Shape → `{product_id, on_hand_qty, stock_value}`. Upsert `on_conflict=product_id`.
- [ ] **Ghost-zeroing:** after upsert, set `on_hand_qty=0, stock_value=0` for any `dashboard_stock` row whose product_id is NOT in the current read_group (product fully depleted). Implement as a small "zero the rest" HTTP PATCH keyed on `product_id=not.in.(<current ids>)`, or an RPC mirroring `reconcile_orders`. Run every 20–60 min.
- [ ] **Verify:** Σ `stock_value` ≈ Inventory → Reporting → **Stock Valuation** total. Spot-check one product's on-hand vs Odoo.

### Task 1.3: Order-lines sync (the heavy one)
**Source:** `sale.order.line`; keep only lines whose parent order `state` in (`sale`,`done`). Fields: `id`(line_id), `order_id`, `product_id`, `product_uom_qty`, `price_subtotal`, `price_total`, `state`(related). Enrich each line with `date_order`, `partner_id` from the order, and `city`/`gov`/`salesperson`/`user_id` from the customer master (State-verbatim else "None"). Upsert `on_conflict=line_id`, chunked ≤250.
- [ ] Incremental: parent-order `write_date` window (48h), 20 min. Backfill: month-chunked by order `date_order` (Jan→current), like the orders backfill.
- [ ] **Reconcile:** remove lines belonging to cancelled/deleted orders (mirror `reconcile_orders`: keep only line_ids whose order is currently confirmed in Odoo).
- [ ] **Verify:** for one month, Σ `price_subtotal` grouped by product ≈ Odoo Sales Analysis (Product, Untaxed) — note lines are UNtaxed; confirm which measure you compare. Line count ≈ Odoo sale.order.line count for the window.

**Gate:** all three tables populated and each cross-checked against its Odoo screen before touching the front-end.

---

## PHASE 2 — Front-end (code: TDD on pure functions, then wire the page)

### Task 2.1: Pure function `classifyFrozen` (TDD)

**Files:** Modify `assets/js/common.js` (add + export); Test `test/products.test.js`

**Interfaces:**
- Produces: `classifyFrozen(products, stockById, lastSaleById, thresholdDays, now) -> Array<{product_id,name,category,brand,on_hand_qty,stock_value,last_sale,days_idle,frozen,never_sold}>`
  - `products`: `[{product_id,name,category,brand}]`
  - `stockById`: `{ [product_id]: {on_hand_qty, stock_value} }`
  - `lastSaleById`: `{ [product_id]: ISOstring }` (max confirmed `date_order`)
  - frozen = `on_hand_qty > 0 && (last_sale == null || days_idle > thresholdDays)`

- [ ] **Step 1: Write the failing test** — `test/products.test.js`

```js
const assert = require("assert");
const { classifyFrozen } = require("../assets/js/common.node.js"); // see Step 3 note
const now = new Date("2026-07-23T00:00:00Z").getTime();
const products = [
  { product_id: 1, name: "A", category: "X", brand: "B" },
  { product_id: 2, name: "B", category: "X", brand: "B" },
  { product_id: 3, name: "C", category: "Y", brand: "B" },
];
const stock = { 1: { on_hand_qty: 100, stock_value: 500000 },
                2: { on_hand_qty: 10,  stock_value: 20000 },
                3: { on_hand_qty: 0,   stock_value: 0 } };
const lastSale = { 1: "2026-03-01T00:00:00Z" /*>60d*/, 2: "2026-07-20T00:00:00Z" /*<60d*/ };
const out = classifyFrozen(products, stock, lastSale, 60, now);
const byId = Object.fromEntries(out.map(r => [r.product_id, r]));
assert.equal(byId[1].frozen, true);        // stocked + idle 144d
assert.equal(byId[1].never_sold, false);
assert.equal(byId[2].frozen, false);       // sold 3d ago
assert.equal(byId[3].frozen, false);       // no stock, ignore
assert.equal(byId[1].days_idle, 144);
console.log("classifyFrozen OK");
```

- [ ] **Step 2: Run to verify it fails** — `node test/products.test.js` → FAIL (`classifyFrozen is not a function`).

- [ ] **Step 3: Implement** in `common.js` (and mirror the pure fns into a tiny `common.node.js` shim that `module.exports` them for Node — the project already tests pure fns this way; follow the existing `normCity`/`govOf` test setup).

```js
function classifyFrozen(products, stockById, lastSaleById, thresholdDays, now) {
  const DAY = 86400000;
  return products.map(p => {
    const st = stockById[p.product_id] || { on_hand_qty: 0, stock_value: 0 };
    const last = lastSaleById[p.product_id] || null;
    const days_idle = last ? Math.floor((now - new Date(last).getTime()) / DAY) : null;
    const stocked = Number(st.on_hand_qty) > 0;
    const never_sold = stocked && last == null;
    const frozen = stocked && (last == null || days_idle > thresholdDays);
    return { product_id: p.product_id, name: p.name, category: p.category, brand: p.brand,
      on_hand_qty: Number(st.on_hand_qty) || 0, stock_value: Number(st.stock_value) || 0,
      last_sale: last, days_idle, frozen, never_sold };
  });
}
```

- [ ] **Step 4: Run to verify it passes** — `node test/products.test.js` → `classifyFrozen OK`.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(products): classifyFrozen + test"`

### Task 2.2: Pure functions `productVelocity`, `productMarkets`, `lineMargin`, `aggregateLines` (TDD)

**Interfaces (Produces):**
- `productVelocity(lines, product_id, windowDays, now) -> unitsPerMonth` (Σ qty in trailing window ÷ (windowDays/30)).
- `productMarkets(lines, product_id) -> [{gov, units, revenue}]` sorted desc (distinct govs a product sold to).
- `lineMargin(line, costById) -> number` (`price_subtotal - cost*qty`).
- `aggregateLines(lines, {from,to}) -> { byProduct: [...], drill(product_id): {byCustomer, byGov} }` — group confirmed lines in window by product (units, revenue, margin, %mix), with a drill into customer/gov splits.

- [ ] Write failing tests with fixtures (each function: 1 happy case + 1 empty case), run, implement minimally, run green, commit. (Follow the exact shape shown in Task 2.1; one `assert` block per function.)

### Task 2.3: `config.js` table names + `common.js` loaders

**Files:** Modify `assets/js/config.js`, `assets/js/common.js`
- [ ] Add to `CFG.TABLES`: `products: "dashboard_products"`, `stock: "dashboard_stock"`, `order_lines: "dashboard_order_lines"`.
- [ ] Add loaders using `sbGetAll` with unique tiebreakers:
  - `loadProducts()` → `dashboard_products?select=product_id,name,sku,category,brand,cost&order=product_id.desc`
  - `loadStock()` → `dashboard_stock?select=product_id,on_hand_qty,stock_value&order=product_id.desc`
  - `loadOrderLines({from,to})` → `dashboard_order_lines?select=line_id,product_id,qty,price_subtotal,date_order,partner_id,city,gov,state&state=in.(sale,done)&date_order=gte.${from}&date_order=lt.${nextDay(to)}&order=line_id.desc`
  - `lastSaleByProduct()` → per-product max(date_order): fetch confirmed lines ordered, reduce to max per product (or a PostgREST view later).
- [ ] Export the loaders and the 5 pure fns on `window.DASH`.
- [ ] Commit.

### Task 2.4: i18n keys + nav entry + data-source manifest

**Files:** Modify `assets/js/common.js`
- [ ] Add `PAGES` entry: `{ id:"products", href:"products.html", key:"nav_products", group:"..." }` (mirror an existing page object exactly).
- [ ] Add i18n (AR+EN) for: `nav_products`, page title/sub, section titles (frozen/hot), column headers (product, category, brand, on_hand, stock_value, last_sale, days_idle, velocity, units, revenue, margin, mix), `frozen_never_sold`, threshold labels, and `chk_products`/`chk_frozen`/`chk_hot` verify-in-Odoo lines.
- [ ] Register the 3 tables in the `DATA_SOURCES` manifest (label + which page/panels they feed), so the admin hide/show works.
- [ ] Commit.

### Task 2.5: Build `products.html`

**Files:** Create `products.html` (copy the head/boilerplate + script-load order from `regions.html`, cache `?v=` = new version)
- [ ] Chrome via `buildChrome("products")`; shared filter bar (date range default = current month; search).
- [ ] KPI tiles: total stock value, frozen value, # frozen SKUs, % frozen, top seller.
- [ ] **Section A (Frozen):** threshold pills (30/60/90); table sorted by `stock_value` desc using `classifyFrozen` output filtered to `frozen`; 🔴 badge for `never_sold`; expand row → `productMarkets` "where it sells"; category bar chart (frozen value by category). All names via `D.esc`. 🔍 `chk_frozen` line.
- [ ] **Section B (Hot):** `aggregateLines` over the date window; top-products bar (revenue/units toggle); click a product → drill panel (top customers + top govs) via `aggregateLines(...).drill(id)`; margin column via `lineMargin`. 🔍 `chk_hot` line.
- [ ] Poll every `POLL_MS`; `setUpdated()` keeps the freshness clock.
- [ ] **Verify (manual):** `python -m http.server 8123`, open `products.html`; both sections render; threshold changes reflow the frozen list; drill works; totals reconcile with the Odoo screens named in the 🔍 lines.
- [ ] Commit.

### Task 2.6: Cache-buster bump + docs

**Files:** all `*.html`, `service-worker.js`, `docs/ODOO_MODELS.md`, `CHANGELOG.md`
- [ ] Bump `?v=68` → new version in every HTML (including new `products.html`) and `VERSION` in `service-worker.js`.
- [ ] `node --check assets/js/common.js`; run `node test/products.test.js` (all pass).
- [ ] CHANGELOG entry; mark the 3 tables as built in `ODOO_MODELS.md`.
- [ ] Commit; open PR into `main`.

---

## Self-Review

- **Spec coverage:** data layer (Tasks 0.1, 1.1–1.3) ✓; frozen view + why (2.1, 2.2, 2.5-A) ✓; hot view + customer/city drill (2.2, 2.5-B) ✓; page shell/RLS/i18n/data-source/cache-bust (0.1, 2.3, 2.4, 2.6) ✓; Odoo-verify footers (2.4, 2.5) ✓; ghost guards (1.2, 1.3) ✓; testing (2.1, 2.2, 2.6) ✓.
- **Deferred per spec (Open questions):** single-warehouse, margin-trust caveat, product returns — intentionally out of v1.
- **Type consistency:** `classifyFrozen`/`aggregateLines`/`productMarkets`/`lineMargin`/`productVelocity` signatures are referenced identically in 2.1–2.5.
