# Dabboos Product Dashboard — Phase 0: Data Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify the invoice-basis data pipeline (Odoo → Supabase) plus the pure calculation library, so that one product's numbers are provably correct before any UI exists.

**Architecture:** A new `dashboard_invoice_lines` table is filled from Odoo's `account.invoice.report` by two n8n workflows (a one-time month-chunked backfill and a nightly delete-then-insert of a rolling window). A second nightly workflow appends daily on-hand snapshots to `dashboard_stock_history`, which has no readers yet but must start accumulating immediately. A single Postgres function, `product_facts`, owns the definition of "a sale" and is what every future page will call. A pure, dependency-free JS module holds the maths so it can be unit-tested without a network.

**Tech Stack:** Postgres (Supabase), PostgREST, n8n, Odoo JSON-RPC, vanilla ES modules, `node:test`.

## Global Constraints

- **Basis is invoices only.** Every query filters `state = 'posted'` AND `move_type IN ('out_invoice','out_refund')`. Never mix in `dashboard_order_lines`.
- **Date field is `invoice_date`**, which is a Postgres `date`. No timezone conversion on this basis.
- **Credit notes are negative.** `out_refund` rows carry negative `qty` and `price_subtotal` so returns net out by summation. Never take `abs()`.
- **Quantities are UoM-normalized and fractional.** `303.5` cartons is valid. Never round to integers in storage.
- **Exclude the fixtures category:** `coalesce(category,'') !~ 'عارضات|استاندات'`.
- **Revenue is `price_subtotal`** (untaxed). `price_total` is taxed and is not used for revenue.
- **Margin uses current `standard_price`**, not cost-at-sale. Approximate by construction; must be labelled in any UI.
- **NEVER commit secrets.** The `service_role` key and all Odoo credentials stay in n8n. Every workflow JSON in this repo uses the literal placeholders `__SUPABASE_URL__`, `__SERVICE_ROLE_KEY__`, `__ODOO_URL__`, `__ODOO_DB__`, `__ODOO_LOGIN__`, `__ODOO_API_KEY__`. The user substitutes them inside n8n after import.
- **Supabase project URL:** `https://puqfldltipedlodwfyex.supabase.co`
- **Anon key** (browser-safe, reads nothing without a user JWT) may be committed. The service_role key may not.
- **Node version:** v22 (`node:test` is built in — no test framework dependency).
- **Commit after every task.** Conventional-commit prefixes (`feat:`, `test:`, `docs:`, `chore:`).

---

## Task 1: Odoo field introspection

Everything downstream assumes specific field names and sign behaviour on `account.invoice.report`. Those vary by Odoo release and **we have no Odoo UI access**, so they must be verified by API before a single line of sync code is written.

**Files:**
- Create: `n8n/odoo-introspect.workflow.json`
- Create: `docs/odoo-fields.md`

**Interfaces:**
- Produces: the confirmed field list that Tasks 3 and 4 depend on — specifically whether `move_id`, `invoice_user_id`, `commercial_partner_id`, `payment_state`, and `quantity` exist, and whether `out_refund` rows are negative.

- [ ] **Step 1: Write the introspection workflow**

Create `n8n/odoo-introspect.workflow.json`. It is a manual-trigger workflow with four nodes: a `Conn` set-node holding the placeholders, a JSON-RPC `authenticate` call, a `fields_get` call, and a sample `search_read` of five refund rows.

```json
{
  "name": "Dabboos Invoice Report INTROSPECT",
  "nodes": [
    { "id": "t", "name": "When clicking Test", "type": "n8n-nodes-base.manualTrigger",
      "typeVersion": 1, "position": [0, 0], "parameters": {} },
    { "id": "c", "name": "Conn", "type": "n8n-nodes-base.set", "typeVersion": 3.4,
      "position": [200, 0], "parameters": { "assignments": { "assignments": [
        { "id": "a1", "name": "url",   "value": "__ODOO_URL__",     "type": "string" },
        { "id": "a2", "name": "db",    "value": "__ODOO_DB__",      "type": "string" },
        { "id": "a3", "name": "login", "value": "__ODOO_LOGIN__",   "type": "string" },
        { "id": "a4", "name": "key",   "value": "__ODOO_API_KEY__", "type": "string" }
      ] }, "options": {} } },
    { "id": "a", "name": "Auth", "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
      "position": [400, 0], "parameters": {
        "method": "POST",
        "url": "={{ $('Conn').first().json.url }}/jsonrpc",
        "sendHeaders": true,
        "headerParameters": { "parameters": [ { "name": "Content-Type", "value": "application/json" } ] },
        "sendBody": true, "contentType": "raw", "rawContentType": "application/json",
        "body": "={{ JSON.stringify({ jsonrpc:'2.0', method:'call', params:{ service:'common', method:'authenticate', args:[ $('Conn').first().json.db, $('Conn').first().json.login, $('Conn').first().json.key, {} ] } }) }}",
        "options": {} } },
    { "id": "f", "name": "Fields", "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
      "position": [600, 0], "parameters": {
        "method": "POST",
        "url": "={{ $('Conn').first().json.url }}/jsonrpc",
        "sendHeaders": true,
        "headerParameters": { "parameters": [ { "name": "Content-Type", "value": "application/json" } ] },
        "sendBody": true, "contentType": "raw", "rawContentType": "application/json",
        "body": "={{ JSON.stringify({ jsonrpc:'2.0', method:'call', params:{ service:'object', method:'execute_kw', args:[ $('Conn').first().json.db, $('Auth').first().json.result, $('Conn').first().json.key, 'account.invoice.report', 'fields_get', [], { attributes:['string','type'] } ] } }) }}",
        "options": {} } },
    { "id": "s", "name": "Sample Refunds", "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
      "position": [800, 0], "parameters": {
        "method": "POST",
        "url": "={{ $('Conn').first().json.url }}/jsonrpc",
        "sendHeaders": true,
        "headerParameters": { "parameters": [ { "name": "Content-Type", "value": "application/json" } ] },
        "sendBody": true, "contentType": "raw", "rawContentType": "application/json",
        "body": "={{ JSON.stringify({ jsonrpc:'2.0', method:'call', params:{ service:'object', method:'execute_kw', args:[ $('Conn').first().json.db, $('Auth').first().json.result, $('Conn').first().json.key, 'account.invoice.report', 'search_read', [ [['move_type','=','out_refund'],['state','=','posted']] ], { limit:5 } ] } }) }}",
        "options": {} } }
  ],
  "connections": {
    "When clicking Test": { "main": [ [ { "node": "Conn", "type": "main", "index": 0 } ] ] },
    "Conn":              { "main": [ [ { "node": "Auth", "type": "main", "index": 0 } ] ] },
    "Auth":              { "main": [ [ { "node": "Fields", "type": "main", "index": 0 } ] ] },
    "Fields":            { "main": [ [ { "node": "Sample Refunds", "type": "main", "index": 0 } ] ] }
  },
  "settings": {}
}
```

- [ ] **Step 2: USER ACTION — import and run**

Hand the user these instructions verbatim:

> 1. n8n → Workflows → Import from File → `n8n/odoo-introspect.workflow.json`
> 2. Open the **Conn** node, replace the four `__ODOO_*__` placeholders with the same values your existing "Odoo Conn (sync)" node uses.
> 3. Click **Test workflow**.
> 4. Copy the full output of the **Fields** node and the **Sample Refunds** node back to me.

- [ ] **Step 3: Record the findings**

Write `docs/odoo-fields.md` containing the actual field list returned, and an explicit confirm/deny table:

```markdown
| Assumption | Confirmed? | Actual |
|---|---|---|
| `quantity` exists and is UoM-normalized | | |
| `out_refund` rows have negative `quantity` | | |
| `out_refund` rows have negative `price_subtotal` | | |
| `move_id` exists | | |
| `invoice_user_id` exists | | |
| `commercial_partner_id` exists | | |
| `payment_state` exists | | |
```

- [ ] **Step 4: Gate — reconcile the spec**

If any assumption is denied, update `docs/superpowers/specs/2026-08-01-dabboos-product-dashboard-design.md` §4.2 **before** starting Task 3. If `move_id` is absent, delete the basket-analysis claim from §3. Do not proceed with a design the data does not support.

- [ ] **Step 5: Commit**

```bash
git add n8n/odoo-introspect.workflow.json docs/odoo-fields.md
git commit -m "feat: add Odoo account.invoice.report introspection workflow"
```

---

## Task 2: Pure calculation library

This is the maths every page will use. It is pure — no network, no DOM, no Supabase — which is exactly what makes it testable now, before any credentials exist. Written test-first.

**Files:**
- Create: `assets/js/calc.js`
- Test: `test/calc.test.js`

**Interfaces:**
- Produces (all named exports of `assets/js/calc.js`):
  - `daysIdle(lastInvoiced: string|null, today: string) → number|null`
  - `agingBucket(days: number|null) → '0-60'|'60-90'|'90-180'|'180+'`
  - `velocityPerMonth(units90d: number) → number`
  - `daysOfCover(onHand: number, velocityPerMonth: number) → number` (`Infinity` when velocity ≤ 0)
  - `marginPct(revenue: number, margin: number) → number|null`
  - `discountDepth(realizedPrice: number, listPrice: number) → number|null`
  - `momentum(current: number, prior: number) → number|null`
  - `abcClasses(rows: {product_id, revenue}[]) → Map<product_id, 'A'|'B'|'C'>`
  - `classifyStock(row, opts) → 'dead'|'dormant'|'understock'|'overstock'|'healthy'`

- [x] **Step 1: Declare ES modules, then write the failing tests**

The repo has no build step, so Node needs telling that bare `.js` files are ES modules — otherwise `import` throws `Cannot use import statement outside a module`. Create `package.json`:

```json
{ "type": "module" }
```

Then create `test/calc.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  daysIdle, agingBucket, velocityPerMonth, daysOfCover, marginPct,
  discountDepth, momentum, abcClasses, classifyStock
} from '../assets/js/calc.js';

test('daysIdle counts whole days between dates', () => {
  assert.equal(daysIdle('2026-06-01', '2026-07-01'), 30);
});

test('daysIdle returns null for a product never invoiced', () => {
  assert.equal(daysIdle(null, '2026-07-01'), null);
});

test('agingBucket treats never-sold (null) as the worst bucket', () => {
  assert.equal(agingBucket(null), '180+');
});

test('agingBucket boundaries are lower-inclusive', () => {
  assert.equal(agingBucket(59), '0-60');
  assert.equal(agingBucket(60), '60-90');
  assert.equal(agingBucket(90), '90-180');
  assert.equal(agingBucket(180), '180+');
});

test('velocityPerMonth converts 90 days of units to a monthly rate', () => {
  assert.equal(velocityPerMonth(303), 101);
});

test('velocityPerMonth floors net-negative demand at zero', () => {
  // more returned than sold in the window; negative velocity is meaningless
  assert.equal(velocityPerMonth(-30), 0);
});

test('daysOfCover divides stock by daily demand', () => {
  // 100 on hand, 30 units/month = 1 unit/day -> 100 days
  assert.equal(daysOfCover(100, 30), 100);
});

test('daysOfCover is Infinity when nothing is selling', () => {
  // must NOT be NaN - this feeds a sort, and NaN silently corrupts ordering
  assert.equal(daysOfCover(100, 0), Infinity);
});

test('daysOfCover is 0 when there is no stock', () => {
  assert.equal(daysOfCover(0, 30), 0);
});

test('marginPct is null when revenue is zero', () => {
  assert.equal(marginPct(0, 0), null);
});

test('marginPct handles a loss', () => {
  assert.equal(marginPct(100, -25), -25);
});

test('discountDepth is the shortfall against list price', () => {
  assert.equal(discountDepth(80, 100), 20);
});

test('discountDepth is null when list price is missing', () => {
  assert.equal(discountDepth(80, 0), null);
});

test('discountDepth can be negative when sold above list', () => {
  assert.equal(discountDepth(110, 100), -10);
});

test('momentum is null when there is no prior period to compare', () => {
  // a new product is not "infinite growth"
  assert.equal(momentum(50, 0), null);
});

test('momentum reports percent change', () => {
  assert.equal(momentum(150, 100), 50);
});

test('abcClasses puts the revenue leaders in A', () => {
  const rows = [
    { product_id: 1, revenue: 800 },
    { product_id: 2, revenue: 150 },
    { product_id: 3, revenue: 50 }
  ];
  const m = abcClasses(rows);
  assert.equal(m.get(1), 'A');
  assert.equal(m.get(2), 'B');
  assert.equal(m.get(3), 'C');
});

test('abcClasses ignores net-negative products rather than ranking them', () => {
  const rows = [
    { product_id: 1, revenue: 1000 },
    { product_id: 2, revenue: -40 }
  ];
  const m = abcClasses(rows);
  assert.equal(m.get(1), 'A');
  assert.equal(m.get(2), 'C');
});

test('classifyStock calls idle stock dead', () => {
  const row = { on_hand: 10, days_idle: 200, peak_month: 1, velocity: 0 };
  assert.equal(classifyStock(row, { today: '2026-08-01', idleDays: 60 }), 'dead');
});

test('classifyStock calls idle stock dormant when its season is ahead', () => {
  // idle in August, but this category peaks in December - do not liquidate
  const row = { on_hand: 10, days_idle: 200, peak_month: 12, velocity: 0 };
  assert.equal(classifyStock(row, { today: '2026-08-01', idleDays: 60 }), 'dormant');
});

test('classifyStock flags fast movers about to run out', () => {
  const row = { on_hand: 5, days_idle: 2, peak_month: null, velocity: 60 };
  assert.equal(classifyStock(row, { today: '2026-08-01', idleDays: 60 }), 'understock');
});

test('classifyStock flags slow movers sitting on a year of stock', () => {
  const row = { on_hand: 600, days_idle: 2, peak_month: null, velocity: 30 };
  assert.equal(classifyStock(row, { today: '2026-08-01', idleDays: 60 }), 'overstock');
});
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `node --test "test/**/*.test.js"`

Use the quoted glob, not `node --test test/`. On Windows the bare directory form is resolved as a *module* path and dies with `Cannot find module ...\test` before any test runs — which looks like a broken test but is a broken command.

Expected: FAIL — `Cannot find module '../assets/js/calc.js'`

- [x] **Step 3: Implement `calc.js`**

Create `assets/js/calc.js`:

```js
/**
 * Pure calculation helpers for the Dabboos product dashboard.
 * No I/O, no DOM, no Supabase - so the maths can be tested without a network.
 *
 * Conventions that apply throughout:
 *  - Quantities are UoM-normalized and may be fractional (303.5 cartons).
 *  - Credit notes are negative, so sums net out returns. Never abs().
 *  - A metric that cannot be computed returns null, never 0 or NaN.
 */

const DAY_MS = 86400000;

/** Whole days between the last invoice and today. null when never invoiced. */
export function daysIdle(lastInvoiced, today) {
  if (!lastInvoiced) return null;
  const a = Date.parse(lastInvoiced + 'T00:00:00Z');
  const b = Date.parse(today + 'T00:00:00Z');
  if (Number.isNaN(a) || Number.isNaN(b)) return null;
  return Math.round((b - a) / DAY_MS);
}

/** Aging bucket. Never-invoiced (null) is the worst case, not the best. */
export function agingBucket(days) {
  if (days === null || days === undefined) return '180+';
  if (days < 60) return '0-60';
  if (days < 90) return '60-90';
  if (days < 180) return '90-180';
  return '180+';
}

/** Trailing-90-day units expressed as units per month. Net-negative floors at 0. */
export function velocityPerMonth(units90d) {
  const v = Number(units90d) / 3;
  return v > 0 ? v : 0;
}

/**
 * How many days the current stock lasts at the current rate.
 * Infinity (not NaN) when nothing is selling - this value feeds sorts,
 * and NaN silently corrupts ordering.
 */
export function daysOfCover(onHand, velocityPerMonth) {
  if (!(onHand > 0)) return 0;
  if (!(velocityPerMonth > 0)) return Infinity;
  return onHand / (velocityPerMonth / 30);
}

/** Margin as a percentage of revenue. null when there is no revenue to divide by. */
export function marginPct(revenue, margin) {
  if (!revenue) return null;
  return (margin / revenue) * 100;
}

/**
 * How far below list price we actually sold, in percent. Negative = sold above list.
 * Rounded to 4 decimals: the naive expression yields 19.999999999999996 for a plain
 * 20% discount, which is noise in a figure nobody reads past two decimals.
 */
export function discountDepth(realizedPrice, listPrice) {
  if (!(listPrice > 0)) return null;
  return Math.round((1 - realizedPrice / listPrice) * 1e6) / 1e4;
}

/** Percent change against the prior period. null when there is no prior activity. */
export function momentum(current, prior) {
  if (!prior) return null;
  return ((current - prior) / Math.abs(prior)) * 100;
}

/**
 * Pareto classification by revenue share: A = top 80%, B = next 15%, C = the tail.
 * Products with net-negative revenue are C by definition rather than ranked.
 */
export function abcClasses(rows) {
  const out = new Map();
  const positive = rows.filter(r => r.revenue > 0).sort((a, b) => b.revenue - a.revenue);
  for (const r of rows) if (!(r.revenue > 0)) out.set(r.product_id, 'C');

  const total = positive.reduce((s, r) => s + r.revenue, 0);
  if (!total) { for (const r of positive) out.set(r.product_id, 'C'); return out; }

  let cum = 0;
  for (const r of positive) {
    const shareBefore = cum / total;
    cum += r.revenue;
    out.set(r.product_id, shareBefore < 0.8 ? 'A' : shareBefore < 0.95 ? 'B' : 'C');
  }
  return out;
}

/**
 * The action label for a product.
 *  dead       - in stock, idle past the threshold, and its season is not ahead
 *  dormant    - same, but the category peaks in a month still to come: wait, do not discount
 *  understock - selling well with under 30 days of cover
 *  overstock  - more than 180 days of cover
 */
export function classifyStock(row, opts) {
  const { on_hand = 0, days_idle = null, peak_month = null, velocity = 0 } = row;
  const idleDays = opts.idleDays ?? 60;

  if (on_hand > 0 && (days_idle === null || days_idle >= idleDays)) {
    const thisMonth = Number(opts.today.slice(5, 7));
    if (peak_month && peak_month > thisMonth) return 'dormant';
    return 'dead';
  }

  const cover = daysOfCover(on_hand, velocity);
  if (cover < 30) return 'understock';
  if (cover > 180) return 'overstock';
  return 'healthy';
}
```

- [x] **Step 4: Run the tests to verify they pass**

Run: `node --test "test/**/*.test.js"`
Expected: PASS — `# tests 22 / # pass 22 / # fail 0`.

- [x] **Step 5: Commit**

```bash
git add package.json assets/js/calc.js test/calc.test.js
git commit -m "feat: add pure calculation library with unit tests"
```

---

## Task 3: Supabase schema

**Files:**
- Create: `supabase/01_schema.sql`

**Interfaces:**
- Produces: tables `dashboard_invoice_lines` and `dashboard_stock_history`, read-granted to the `authenticated` role. Task 4 writes to the first; Task 5 writes to the second; Task 6 reads both.

- [ ] **Step 1: Write the schema**

Create `supabase/01_schema.sql`:

```sql
-- Dabboos Product Dashboard - Phase 0 schema
-- Run in: Supabase -> SQL Editor. Safe to re-run (idempotent).

-- ---------------------------------------------------------------------------
-- Invoice lines, sourced from Odoo `account.invoice.report`.
-- Only posted customer invoices and credit notes are ever inserted.
-- Credit-note rows carry NEGATIVE qty and price_subtotal so that returns
-- net out by plain summation. Never store abs() values here.
-- ---------------------------------------------------------------------------
create table if not exists public.dashboard_invoice_lines (
  line_id        bigint primary key,          -- account.invoice.report row id
  move_id        bigint,                      -- the invoice; lets lines regroup into documents
  product_id     bigint not null,
  qty            numeric not null,            -- UoM-normalized, fractional, signed
  price_subtotal numeric not null,            -- untaxed, signed
  price_total    numeric,                     -- taxed; kept for cross-checks only
  invoice_date   date   not null,             -- a DATE: no timezone conversion needed
  partner_id     bigint,                      -- commercial_partner_id
  salesperson    text,
  user_id        bigint,
  move_type      text   not null,             -- out_invoice | out_refund
  state          text   not null,             -- always 'posted'
  payment_state  text,
  synced_at      timestamptz not null default now()
);

create index if not exists idx_inv_lines_date    on public.dashboard_invoice_lines (invoice_date);
create index if not exists idx_inv_lines_product on public.dashboard_invoice_lines (product_id);
create index if not exists idx_inv_lines_partner on public.dashboard_invoice_lines (partner_id);
-- the shape of nearly every query: a product over a date window
create index if not exists idx_inv_lines_prod_date
  on public.dashboard_invoice_lines (product_id, invoice_date);

-- ---------------------------------------------------------------------------
-- Daily on-hand snapshots.
-- `dashboard_stock` only ever holds TODAY - yesterday's on-hand is lost the
-- moment it refreshes. Nothing reads this table yet; it exists so that history
-- starts accumulating now, because it cannot be backfilled later.
-- ---------------------------------------------------------------------------
create table if not exists public.dashboard_stock_history (
  product_id  bigint  not null,
  snap_date   date    not null,
  on_hand_qty numeric not null,
  stock_value numeric,
  primary key (product_id, snap_date)
);

create index if not exists idx_stock_hist_date on public.dashboard_stock_history (snap_date);

-- ---------------------------------------------------------------------------
-- RLS. The anon key must read nothing; a logged-in user reads everything.
-- Writes belong to n8n, which uses the service_role key and bypasses RLS.
-- ---------------------------------------------------------------------------
alter table public.dashboard_invoice_lines  enable row level security;
alter table public.dashboard_stock_history  enable row level security;

drop policy if exists inv_lines_read  on public.dashboard_invoice_lines;
drop policy if exists stock_hist_read on public.dashboard_stock_history;

create policy inv_lines_read  on public.dashboard_invoice_lines
  for select to authenticated using (true);
create policy stock_hist_read on public.dashboard_stock_history
  for select to authenticated using (true);

grant select on public.dashboard_invoice_lines  to authenticated;
grant select on public.dashboard_stock_history  to authenticated;
```

- [ ] **Step 2: USER ACTION — run the schema**

> Supabase → SQL Editor → New query → paste the contents of `supabase/01_schema.sql` → **Run**.
> Report back either "Success. No rows returned" or the error text.

- [ ] **Step 3: Verify the tables exist and are RLS-protected**

With the anon key only, both tables must return HTTP 200 and **zero rows** — proving RLS is on and the table exists (a missing table returns 404, which is how we tell the two apart):

```bash
K='<anon key from assets/js/config.js>'
for t in dashboard_invoice_lines dashboard_stock_history; do
  printf '%-28s ' "$t"
  curl -s -I "https://puqfldltipedlodwfyex.supabase.co/rest/v1/$t?select=*" \
    -H "apikey: $K" -H "Authorization: Bearer $K" \
    -H "Prefer: count=exact" -H "Range: 0-0" | grep -iE 'HTTP/|content-range'
done
```

Expected: `HTTP/2 200` and `Content-Range: */0` for both. A `404` means the schema did not run.

- [ ] **Step 4: Commit**

```bash
git add supabase/01_schema.sql
git commit -m "feat: add invoice-lines and stock-history schema with RLS"
```

---

## Task 4: Invoice sync workflows

Two workflows sharing one node graph shape: a month-chunked backfill and a nightly rolling window.

**Files:**
- Create: `n8n/invoice-lines-backfill.workflow.json`
- Create: `n8n/invoice-lines-nightly.workflow.json`
- Create: `n8n/README.md`

**Interfaces:**
- Consumes: `dashboard_invoice_lines` from Task 3; the confirmed field names from Task 1.
- Produces: populated invoice lines that Task 6's `product_facts` reads.

- [ ] **Step 1: Write the shared row-mapping code**

Both workflows use this identical Code node body, mapping Odoo rows to table columns. Keep it byte-identical in both so the two paths can never disagree:

```js
// Map account.invoice.report rows -> dashboard_invoice_lines columns.
// Odoo many2one fields arrive as [id, "Display Name"]; take id or label as needed.
const id0 = v => Array.isArray(v) ? v[0] : (v ?? null);
const lbl = v => Array.isArray(v) ? v[1] : (v ?? null);
const num = v => (v === false || v == null) ? 0 : Number(v);

const rows = $input.first().json.result || [];
const out = rows.map(r => ({
  line_id:        r.id,
  move_id:        id0(r.move_id),
  product_id:     id0(r.product_id),
  qty:            num(r.quantity),            // signed: refunds are negative
  price_subtotal: num(r.price_subtotal),      // signed
  price_total:    num(r.price_total),
  invoice_date:   r.invoice_date || null,
  partner_id:     id0(r.commercial_partner_id ?? r.partner_id),
  salesperson:    lbl(r.invoice_user_id),
  user_id:        id0(r.invoice_user_id),
  move_type:      r.move_type,
  state:          r.state,
  payment_state:  r.payment_state ?? null
})).filter(r => r.product_id && r.invoice_date);

return [{ json: { rows: out, count: out.length } }];
```

- [ ] **Step 2: Write the backfill workflow**

Create `n8n/invoice-lines-backfill.workflow.json`. Manual trigger → `Conn` (placeholders) → `Auth` → a Code node emitting one item per month from `2024-01` to today → `search_read` per month with domain
`[['state','=','posted'],['move_type','in',['out_invoice','out_refund']],['invoice_date','>=',from],['invoice_date','<',to]]`
→ the Step 1 mapper → POST to `/rest/v1/dashboard_invoice_lines?on_conflict=line_id` with header `Prefer: resolution=merge-duplicates,return=minimal`.

Month chunking keeps each JSON-RPC response small enough not to time out. Use the same node shapes as `n8n/odoo-introspect.workflow.json` from Task 1.

- [ ] **Step 3: Write the nightly workflow**

Create `n8n/invoice-lines-nightly.workflow.json`. Schedule trigger at 02:00 → same Auth → `search_read` for `invoice_date >= today - 35 days` → mapper → **then two HTTP calls in strict order**:

1. `DELETE /rest/v1/dashboard_invoice_lines?invoice_date=gte.<today-35d>`
2. `POST /rest/v1/dashboard_invoice_lines` (plain insert)

**This delete-then-insert is not interchangeable with an upsert.** A cancelled invoice *disappears* from `account.invoice.report`; an upsert would never remove its stale row, and revenue would be silently overstated forever. The delete must be wired to run only after the fetch succeeds, so a failed Odoo call cannot wipe the window and leave it empty.

- [ ] **Step 4: Document the operational rules**

Create `n8n/README.md` covering: the placeholder substitution list, run-once-then-activate order (backfill first, then enable nightly), and the rule that the **full backfill must be re-run monthly** because `account.invoice.report` exposes no `write_date`, so edits to invoices older than 35 days are otherwise never caught.

- [ ] **Step 5: USER ACTION — import, wire, run**

> 1. Import both workflows.
> 2. In each, open **Conn** and replace the `__ODOO_*__` placeholders, and open **Config** and replace `__SUPABASE_URL__` / `__SERVICE_ROLE_KEY__`.
> 3. Run the **backfill** once. Report the total row count it inserted.
> 4. Leave the nightly **inactive** until Task 7 confirms the numbers are right.

- [ ] **Step 6: Verify rows landed**

```sql
select count(*)                      as lines,
       min(invoice_date)             as first_date,
       max(invoice_date)             as last_date,
       count(*) filter (where move_type = 'out_refund') as credit_notes,
       count(*) filter (where qty < 0)                  as negative_qty
from dashboard_invoice_lines;
```

`credit_notes` and `negative_qty` should be roughly equal. If `negative_qty` is 0 while `credit_notes` is not, the sign assumption from Task 1 was wrong and the mapper must negate refund rows explicitly.

- [ ] **Step 7: Commit**

```bash
git add n8n/
git commit -m "feat: add Odoo invoice-lines backfill and nightly sync workflows"
```

---

## Task 5: Stock history snapshot workflow

**Files:**
- Create: `n8n/stock-history-nightly.workflow.json`

**Interfaces:**
- Consumes: `dashboard_stock_history` from Task 3.
- Produces: one row per product per day. No reader until a later phase — that is expected.

- [ ] **Step 1: Write the workflow**

Schedule trigger at 03:00 (after the existing 2-hourly product/stock sync has run) → read `dashboard_stock` from Supabase REST → Code node stamping today's Baghdad date → POST to `/rest/v1/dashboard_stock_history?on_conflict=product_id,snap_date` with `Prefer: resolution=merge-duplicates,return=minimal`.

The date stamp must be Baghdad-local, not UTC, or a 03:00 Baghdad run lands on the previous UTC day:

```js
const snap_date = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Baghdad' });
const rows = $input.all().map(i => i.json).map(s => ({
  product_id:  s.product_id,
  snap_date,
  on_hand_qty: Number(s.on_hand_qty) || 0,
  stock_value: s.stock_value == null ? null : Number(s.stock_value)
}));
return [{ json: { rows, count: rows.length } }];
```

Upsert (not delete-then-insert) is correct here: re-running on the same day should overwrite that day's snapshot, and past days must never be touched.

- [ ] **Step 2: USER ACTION — import, wire, run, activate**

> Import, substitute the two Supabase placeholders, run once, then **activate it immediately** — every day it is off is a day of history that cannot be recovered.

- [ ] **Step 3: Verify**

```sql
select snap_date, count(*) as products, round(sum(on_hand_qty)) as total_units
from dashboard_stock_history group by snap_date order by snap_date desc limit 5;
```

Expected: one row, today's date, product count matching `select count(*) from dashboard_stock`.

- [ ] **Step 4: Commit**

```bash
git add n8n/stock-history-nightly.workflow.json
git commit -m "feat: add nightly stock-history snapshot workflow"
```

---

## Task 6: The `product_facts` RPC

The single place that defines what a sale is. Every page in every later phase inherits its filters from here, which is what stops two pages from disagreeing.

**Files:**
- Create: `supabase/02_functions.sql`

**Interfaces:**
- Consumes: `dashboard_invoice_lines`, `dashboard_products`, `dashboard_stock`, `dashboard_customers`.
- Produces: `product_facts(...)` returning one row per product — consumed by every Phase 1+ page.

- [ ] **Step 1: Write the function**

Create `supabase/02_functions.sql`:

```sql
-- One row per product for a period and filter set.
-- SECURITY INVOKER so the caller's RLS still applies - a logged-in user only.
create or replace function public.product_facts(
  p_from        date,
  p_to          date,
  p_salesperson text   default null,
  p_gov         text   default null,
  p_customer    bigint default null,
  p_category    text   default null,
  p_brand       text   default null
)
returns table (
  product_id         bigint,
  sku                text,
  name               text,
  category           text,
  brand              text,
  uom                text,
  cost               numeric,
  list_price         numeric,
  units              numeric,
  revenue            numeric,
  margin             numeric,
  realized_price     numeric,
  last_invoiced      date,
  distinct_customers bigint,
  distinct_govs      bigint,
  on_hand            numeric,
  stock_value        numeric,
  velocity_90d       numeric
)
language sql
stable
security invoker
as $$
  with scoped as (
    select l.*, c.governorate
    from public.dashboard_invoice_lines l
    left join public.dashboard_customers c on c.partner_id = l.partner_id
    where l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_customer    is null or l.partner_id  = p_customer)
      and (p_gov         is null or c.governorate = p_gov)
  ),
  period as (
    select product_id,
           sum(qty)                                    as units,
           sum(price_subtotal)                         as revenue,
           count(distinct partner_id)                  as distinct_customers,
           count(distinct governorate)                 as distinct_govs
    from scoped
    where invoice_date >= p_from and invoice_date <= p_to
    group by product_id
  ),
  -- trailing 90 days ending at p_to, independent of the selected period,
  -- so velocity means the same thing on every screen
  trailing as (
    select product_id, sum(qty) as units_90d
    from scoped
    where invoice_date > p_to - 90 and invoice_date <= p_to
    group by product_id
  ),
  -- last invoice EVER, not just in the period: a product idle for two years
  -- must not look freshly sold because the period happens to exclude it
  lastsale as (
    select product_id, max(invoice_date) as last_invoiced
    from scoped
    group by product_id
  )
  select
    p.product_id,
    p.sku,
    p.name,
    p.category,
    p.brand,
    p.uom,
    p.cost,
    p.list_price,
    coalesce(pe.units, 0)                                            as units,
    coalesce(pe.revenue, 0)                                          as revenue,
    coalesce(pe.revenue, 0) - coalesce(pe.units, 0) * coalesce(p.cost, 0) as margin,
    case when coalesce(pe.units, 0) <> 0
         then pe.revenue / pe.units end                              as realized_price,
    ls.last_invoiced,
    coalesce(pe.distinct_customers, 0),
    coalesce(pe.distinct_govs, 0),
    coalesce(s.on_hand_qty, 0)                                       as on_hand,
    coalesce(s.stock_value, 0)                                       as stock_value,
    greatest(coalesce(tr.units_90d, 0) / 3.0, 0)                     as velocity_90d
  from public.dashboard_products p
  left join public.dashboard_stock s  on s.product_id  = p.product_id
  left join period    pe on pe.product_id = p.product_id
  left join trailing  tr on tr.product_id = p.product_id
  left join lastsale  ls on ls.product_id = p.product_id
  where coalesce(p.category, '') !~ 'عارضات|استاندات'   -- fixtures, not products
    and (p_category is null or p.category = p_category)
    and (p_brand    is null or p.brand    = p_brand);
$$;

grant execute on function public.product_facts(date, date, text, text, bigint, text, text)
  to authenticated;
```

Note the deliberate choice of `dashboard_products` as the driving table with `left join`: products that sold nothing in the period still return a row with `units = 0`. That is required — the frozen and never-sold analyses are *about* those rows, and an inner join would silently hide exactly the products the dashboard exists to surface.

- [ ] **Step 2: USER ACTION — run it**

> Supabase → SQL Editor → paste `supabase/02_functions.sql` → **Run**.

- [ ] **Step 3: Verify it returns rows and includes never-sold products**

```sql
select count(*)                                  as products,
       count(*) filter (where units = 0)         as sold_nothing_in_period,
       count(*) filter (where last_invoiced is null) as never_invoiced,
       round(sum(revenue))                       as total_revenue
from product_facts('2026-06-01', '2026-06-30');
```

`sold_nothing_in_period` must be greater than zero on a real catalogue. If it is zero, the join is wrong.

- [ ] **Step 4: Commit**

```bash
git add supabase/02_functions.sql
git commit -m "feat: add product_facts RPC as the single definition of a sale"
```

---

## Task 7: End-to-end verification

The gate for the whole phase. Until a number is proven against Odoo, nothing here is trustworthy and no UI should be built on it.

**Files:**
- Create: `docs/verification.md`
- Create: `n8n/verify-product.workflow.json`

- [ ] **Step 1: Pick the reference product**

```sql
select p.sku, p.name, round(sum(l.qty),1) as units, round(sum(l.price_subtotal)) as revenue
from dashboard_invoice_lines l
join dashboard_products p on p.product_id = l.product_id
where l.invoice_date between '2026-06-01' and '2026-06-30'
group by p.sku, p.name
order by units desc
limit 5;
```

Take the top SKU. Record its `product_id`, units and revenue.

- [ ] **Step 2: Probe Odoo directly for the same product and window**

Create `n8n/verify-product.workflow.json` — same Conn/Auth nodes as Task 1, then a `read_group` call:

```
model:  account.invoice.report
method: read_group
domain: [['state','=','posted'],
         ['move_type','in',['out_invoice','out_refund']],
         ['product_id','=', <PRODUCT_ID>],
         ['invoice_date','>=','2026-06-01'],
         ['invoice_date','<=','2026-06-30']]
fields: ['quantity','price_subtotal']
groupby: []
```

- [ ] **Step 3: Compare and record**

Write `docs/verification.md` with a table of Supabase value, Odoo value, and difference for units and revenue.

**Pass condition:** agreement within rounding (< 0.1%). Anything larger is a real defect — investigate before proceeding, and check in this order: (a) date-window inclusivity, (b) refund signs, (c) whether the backfill covered the full window, (d) whether a filter differs between the two queries.

- [ ] **Step 4: Record the hand-off check**

Add a section to `docs/verification.md` for whoever has Odoo UI access, stating the exact steps: Invoicing → Reporting → Invoice Analysis, filter to the product, set the end date to **`07/01/2026`, not `06/30`** (an end of `06/30 00:00:00` silently drops the whole of June 30), measure = Product Quantity. Until this is signed off, the numbers are "verified against the Odoo API", not "verified against Odoo".

- [ ] **Step 5: USER ACTION — activate the nightly sync**

> Only once the comparison passes: activate `invoice-lines-nightly` in n8n.

- [ ] **Step 6: Commit**

```bash
git add docs/verification.md n8n/verify-product.workflow.json
git commit -m "docs: add end-to-end numeric verification against Odoo"
```

---

## Phase 0 exit criteria

- [ ] `docs/odoo-fields.md` records the real field list; the spec matches reality.
- [x] `node --test "test/**/*.test.js"` passes (22/22).
- [ ] Both tables exist, RLS-protected, returning zero rows to the anon key.
- [ ] Backfill has run; `negative_qty ≈ credit_notes`.
- [ ] Stock-history workflow is **active** and has at least one day of rows.
- [ ] `product_facts` returns rows, including products with `units = 0`.
- [ ] One product reconciles with Odoo within 0.1%, recorded in `docs/verification.md`.

Only then does Phase 1 (shell, auth, Overview, Products explorer) begin.
