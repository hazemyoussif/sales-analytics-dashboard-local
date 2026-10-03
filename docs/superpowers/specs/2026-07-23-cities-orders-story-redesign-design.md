# Cities page (Orders basis) — story redesign

**Date:** 2026-07-23
**Branch:** `feat/regions-orders-story`
**File touched:** `regions.html` (inline script + markup), `assets/js/common.js` (i18n keys only), all HTML cache-buster bump, `service-worker.js` VERSION bump.

## Goal
Rebuild the **Orders basis** of the Cities page so it tells a story through
**charts + numbers**, not a snapshot table. It must answer two questions at a
glance:
1. **Who's growing / slipping** — each region vs the previous period.
2. **Where to push** — regions with untapped customers and customers who went
   quiet.

The **Invoices basis is out of scope and must render exactly as today**
(v64/v65 Sales / Returns / Net). No returns story on the Orders view (returns
only exist on invoices).

## Non-goals (YAGNI)
- No concentration/risk story (owner deselected it).
- No returns block on the Orders view.
- No 3-level Day > State > City pivot (that idea was dropped).
- No change to how governorate/city are classified (State-verbatim from the
  customer master stays — it already reconciles with Odoo's money).

## Scope boundary — the basis branch
`render()` branches on `basis`:
- `basis === "inv"` → **existing** code path, byte-for-byte unchanged.
- `basis === "ord"` → **new** story layout described below.

The existing governorate chart + governorate table + cities table markup is
reused for the Invoices path. The Orders path renders into new containers. Both
paths share the same loaded data window and the same filters (date range,
region select, search).

## Layout (Orders basis only), top to bottom

### ① KPI tiles — the story in numbers
A row of tiles (reuse the project's existing KPI tile pattern / `data-src`):
- **Total sales** (this period, `fmtMoney`) + **▲/▼ % vs previous period**,
  color-coded green/red. Delta hidden when the previous period isn't covered
  by loaded data (see Momentum rule).
- **Active regions · active cities** (counts with orders this period).
- **Rising star** — region with the largest positive % change (name + %).
- **Falling** — region with the largest negative % change (name + %).

No return-rate tile (invoice-only).

### ② Two charts side by side — "where" and "which way"
- **Where the money is** — horizontal bar, sales by region, sorted desc.
  (Reuses the current `govChart` Chart.js config; magnitude + rank.)
- **Who's moving** — **diverging** horizontal bar of **% change vs previous
  period** per region: green bars to the right (growth), red to the left
  (decline), sorted growth→decline. When the whole prior window is
  uncovered (delta hidden globally) this chart is replaced by a "no comparison
  data yet" note. Regions flagged **"new"** (prev = 0, cur > 0) can't have a
  % — they're omitted from the diverging bars and surfaced as a small "new
  regions" chip, not drawn at an arbitrary value.

### ③ Where to push — coverage chart
One horizontal bar per region: filled = customers who ordered this period,
track = all customers known in that region (customer master). Sorted by the
**biggest gap** (most non-buyers first). Each row labels the numbers:
`3 / 12 → 9 to chase`. A secondary figure per region: **quiet customers** =
customers who ordered in the *previous* period but not this one.

### ④ Detail table — region → cities drill (kept)
The region table and click-to-drill cities table remain, with a small inline
**▲/▼** arrow per region (same % as the "Who's moving" chart). Exact numbers
live here. The small "🔍 check in Odoo" line stays beneath it (Odoo
comparability rule).

## Data & computation

### Periods
- **Current period** = selected `From..To`.
- **Previous period** = the equal-length window immediately before `From`:
  `[From − (To−From+1 days), From)`.
- **Default page range** changes from "last 30 days" to the **current calendar
  month** so the page opens on a live *this-month vs last-month* story
  (today 2026-07-23 → July vs June, and June data exists).

### Momentum (▲/▼ %)
- Per region: `(cur − prev) / prev`; when `prev === 0` and `cur > 0`, show
  "new" (not a %); when both 0, blank.
- **Honesty rule (same as Overview MoM):** if the earliest loaded
  `date_order` is later than `prevFrom`, the previous window isn't fully
  covered → **hide all deltas** (no fake arrows). Detected from the fetched
  rows' min date.

### Loading
- One widened fetch: `loadOrders({ from: prevFrom, to, dateField: "date_order",
  select: … })`, then partition rows into current vs previous by comparing
  `date_order`'s Baghdad day (`D.bagDay`) against `From`. Single round trip,
  no second query.
- **Customer master for coverage:** query
  `dashboard_customers?select=partner_id,governorate` (all rows, paginated via
  `sbGetAll`), cached for the page session. Per-region total-customer counts
  come from here; active/quiet come from the orders partition.
- Governorate per order still via the FK embed
  `dashboard_customers(governorate,city)`, State-verbatim, else "None".

## Pure functions to extract + unit-test in Node
Per project convention (no browser test harness):
- `regionMomentum(curRows, prevRows)` → `{ [gov]: {cur, prev, pct, count} }`.
- `regionCoverage(activePartnerIdsByGov, masterCountsByGov)` →
  `{ [gov]: {active, total, gap} }`.
- `quietCustomers(curPartnerIdsByGov, prevPartnerIdsByGov)` →
  `{ [gov]: count }`.
- `priorCovered(minLoadedDate, prevFrom)` → boolean.
Each gets a small fixture test run with `node`.

## Charts / dataviz
Apply the **dataviz skill** before writing any chart code (color semantics:
green=growth, red=decline, one neutral accent for magnitude; diverging scale
centered at 0 for "Who's moving"; accessible in light/dark). Keep Chart.js
(already loaded); labels on `<canvas>` need no escaping.

## Hard rules to honor
- **Escape every DB string** (`D.esc`) in all new `innerHTML` (region/city
  names). Chart.js labels are canvas-safe.
- **New user-facing strings** go in BOTH `I18N.ar` and `I18N.en` in
  `common.js`, via `D.t()`. No hardcoded AR/EN in the page.
- **Cache-buster:** editing `common.js` → bump `?v=NN` in ALL HTML files AND
  `VERSION` in `service-worker.js`.
- Money via `fmtMoney`/`fmtMoneyFull`; never hardcode the currency symbol.
- Baghdad calendar; week irrelevant here (period aggregation, not weekly).

## Verification
- `node --check assets/js/common.js` and a syntax check of the inline script.
- Node fixture tests for the four pure functions above.
- Manual: `python -m http.server 8123`, open `regions.html`, confirm:
  Orders basis shows the new layout; Invoices basis is visually identical to
  today; deltas hidden for a range with no prior data; totals still match the
  governorate table.

## Rollout note
No schema or n8n change. Pure front-end. Ship with the cache-buster bump.
