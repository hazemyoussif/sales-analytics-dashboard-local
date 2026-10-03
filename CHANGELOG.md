# Changelog

## 2026-07-23 — Products & Warehouse page (v70)

- New page `products.html` (nav under "sales", role-gated via auth.js):
  - **Frozen stock** — products in stock with no sale within a tunable
    30/60/90-day window; table sorted by capital-at-risk, category chart,
    expandable "where it sells", KPI tiles (stock value · frozen value · %).
  - **Hot products** — top sellers for a date window (default this month),
    revenue/units toggle, click-to-drill into top customers + top cities,
    gross-margin column (cost from `standard_price`).
- Pure analytics live in `assets/js/products-calc.js` (dual browser/Node,
  unit-tested in `test/products.test.js`): classifyFrozen, productVelocity,
  productMarkets, lineMargin, aggregateLines.
- Data from three new tables (`dashboard_products`, `dashboard_stock`,
  `dashboard_order_lines`) fed by new n8n syncs; `supabase/products-warehouse.sql`.
- 🔍 Odoo-verify lines on both sections. Cache-bust v70.

## 2026-07-23 — Freshness becomes a live countdown clock (v67–v68)

- Moved the indicator next to the **LIVE** badge (it was clipped off the
  right edge after the logout button) — v67.
- Turned it into a **self-ticking countdown** that needs no page refresh — v68.
  Shows `Synced from Odoo HH:MM · next in MM:SS`, counting down to the next
  expected sync (pipelines fire every 20 min). A 1-second `setInterval`
  repaints the clock; when it reaches 0 it force-polls the DB (bypassing the
  60s cache) until the new sync lands, then resets itself. Still goes amber
  past ~45 min. One interval per page, no network cost per tick.

## 2026-07-22 — Header shows real "Synced from Odoo" time (v66)

- The header's timestamp used to show `generated_at` — the browser's poll
  time — which could be 20 min newer than the actual data and gave false
  confidence. Replaced with the **true last-sync-from-Odoo** time on every
  page.
- Source: `max(updated_at)` across the three 20-min pipelines
  (`dashboard_orders`, `dashboard_payments`, `dashboard_invoices`). Every
  n8n upsert stamps `updated_at`, so this is the real "data as of" moment.
  `dashboard_customers` is excluded — it's a 2-hour master sync and would
  falsely make sales numbers look stale. Three tiny `limit=1` reads,
  cached 60s; RLS-blocked/errored tables count as 0.
- **Stale warning**: if the freshest sync is older than ~45 min (pipelines
  run every 20 min, so that signals a stall), the line turns amber with a
  "sync may be delayed — check n8n" hint.
- No n8n changes, no new tables, no webhook (live-trigger idea was dropped
  by owner in favour of freshness-only). `common.js` + i18n only.
- Cache-bust v=66.

## 2026-07-20 — Cities invoice basis: Sales / Returns / Net as separate columns (v65)

- Owner feedback: netting sales + returns into one "Net" figure was
  confusing to reviewers even though correct. Now the invoice basis keeps
  the two document types **separate**:
  - **فواتير المبيعات (Sales invoices)** — the primary figure (positive
    INV/ only); the governorate chart plots this.
  - **المرتجعات (Returns)** — its own column (credit notes RINv/, red/
    negative) — a standalone بند, never blended in.
  - **الصافي (Net = Sales − Returns)** — kept and labeled, so anyone
    comparing Odoo's combined Invoices-by-State screen still reconciles.
- Basis note rewritten: sales and returns are separate document types;
  Net is their combination = Odoo. Verified Baghdad July: Sales 352.42M
  (921) · Returns −2.88M (36) · Net 349.54M (Net ↔ Odoo Posted 349.66M).
- Cache-bust v=65.

## 2026-07-20 — Regions invoice basis nets credit notes: Gross + Net (v64)

- Diagnosed the ~1% invoice-basis gap vs Odoo: our page showed positive
  invoices only; Odoo's Invoices-by-State screen **nets credit notes**
  (RINv/, ~87 in July). More documents, less money — exactly the gap.
- **n8n invoice sync now captures credit notes**: both workflows fetch
  `credit` and store `amount_total = debit − credit`, so credit notes
  carry their NEGATIVE total (regular invoices unchanged, credit = 0).
  The incremental was regenerated (it had been cleaned from Downloads);
  **both must be re-imported** or the next run zeroes credit notes again.
- **Regions invoice basis shows BOTH**: Gross (invoices only) and Net
  (after credit notes = Odoo's total), as two money columns; the chart
  plots Net so it lines up with Odoo. Orders basis unchanged.
- Rollout: re-import both invoice workflows, run the BACKFILL once (signs
  existing credit notes), then Net matches Odoo's screen to the dinar.
- Cache-bust v=64.

## 2026-07-20 — Salespeople (WoW): Orders ⇄ Invoices basis toggle (v63)

- Added the same basis toggle to the Salespeople page: each rep's
  week-over-week / month-over-month, the comparison chart, the sparklines,
  the KPIs and the per-card counts now compute on **Orders** (confirmed
  sale orders by order date) OR **Invoices** (posted INV documents by
  invoice date, per the invoice's salesperson). Persisted per browser.
- Loader normalizes both bases into one `items` shape, so the buckets and
  the uid-aware rep/customer filtering are identical either way. Count/KPI
  labels and the 🔍 verify hint switch with the toggle (invoice mode →
  Customer Invoices grouped by Salesperson).
- Cache-bust v=63.

## 2026-07-20 — Cities page: Orders ⇄ Invoices basis toggle (v62)

- The boss's regional reference is the INVOICE view (Accounting →
  Invoices by State); the page showed ORDERS. Added a **basis toggle** at
  the top — "أساس: الطلبات / الفواتير" — persisted per browser.
  - **Orders** (unchanged): confirmed sale orders by order date.
  - **Invoices** (new): posted INV/ documents by invoice date, tax-incl,
    joined to the customer master for State/City — the twin of Odoo's
    Invoices-grouped-by-State screen. Verified: 10/16 governorates match
    to the dinar today; the 6 high ones are stale/ghost invoices (no
    invoice reconcile yet — owner deferred).
- Count column + None banner + basis note all switch with the toggle;
  labels stay verbatim (State/City), None = Odoo's None row.
- Cache-bust v=62.

## 2026-07-18 — Cities & Governorates in ODOO-EXACT mode (v59)

- Owner decision: the Regions page must read like Odoo's own State
  grouping, label for label. Governorate = the customer's **State string
  verbatim** (incl. "(IQ)"), city = the **City field verbatim**, empty =
  the same **"بدون (None)"** bucket Odoo's pivot shows — the dictionary
  normalization (govOf) is no longer used on this page.
- None rows carry a ⚠️ amber badge (tooltip: the State field is empty on
  the customer form) and the banner totals the None bucket — same
  worklist on both screens; the customer's CITY still shows for those
  rows so they remain identifiable.
- Basis note rewritten with the exact verification recipe (incl. the
  "Sales Analysis Count = product lines, not orders" trap).
- Raw DB strings now escaped in the gov select/tables (they were
  dictionary constants before).
- Cache-bust v=59.

## 2026-07-18 — "Orders by day" table, the numeric twin of Odoo's list (v57)

- New collapsible panel at the top of the Rhythm section: **Orders by
  day** — day × total · confirmed · drafts · cancelled · money — exactly
  the grouping of Odoo's Orders list ("Order Date: Day > Status"); money
  sums ALL statuses like Odoo's Total column. Honors every filter
  (date range, rep, customer); grand-total footer; 🔍 verify hint.
- Buckets by `date_order` on the Baghdad calendar via the page's shared
  `dayOf()` — the same basis as the daily chart, so chart and table can
  never disagree.
- Cache-bust v=57.

## 2026-07-17 — Filters now reach EVERYTHING (v56)

- Audit: some Overview blocks came from global builders and ignored the
  rep/customer filter. All fixed — the filter now narrows:
  - the **"Invoiced today" KPI** and the WHOLE invoices-today card
    (status buckets, collected footer, cancelled row — recomputed
    client-side from invoice-level rows; builder now also returns
    `cancelled_rows`),
  - the **month revenue card** (value/count/collected recomputed from
    `posted_rows`; MoM% and the target bar hide while filtered — they
    are company-wide comparisons and would mislead against a slice),
  - the **top-debtors card** (uid-aware rep matching; rows carry
    `user_id`),
  - the **collections 14-day grid** (uid-aware rep match, and the footer
    totals switch to the FILTERED reps' totals instead of the global
    grand total).
- Already filtered and verified: payments cards, per-rep tables, minis,
  charts, debt page, alerts, salespeople.
- Cache-bust v=56.

## 2026-07-17 — Speak Odoo's language: verify-in-Odoo hints everywhere (v55)

- Design rule adopted: viewers ALWAYS compare the dashboard with Odoo, so
  cards use Odoo's own vocabulary and name the exact screen that
  reproduces them.
- **Top overdue customers** re-presented with Aged-Receivable columns:
  Overdue (the late columns) · **Not due yet** (At Date) · **Total open**
  (the Total column, bold) · days late — plus a 🔍 footer naming the
  report. "Receivable" (ambiguous) is gone.
- 🔍 verify-hints added: invoices-today card (Customer Invoices grouped by
  payment status), payments-today card (Customer Payments grouped by
  status, signed amounts), month invoice/payment rep cards (grouped by
  salesperson), Debt page header (Aged Receivable column mapping), and
  the Collections page subtitle.
- Debt table column "الدين" renamed to "إجمالي الذمة" (= Odoo's Total).
- n8n (earlier today, no assets): orders incremental "Fetch Missing
  Customers" collapsed from one-request-per-customer to a single in-list
  request — the cold-cache crawl is gone.
- Cache-bust v=55.

## 2026-07-17 — Filters work on every page + invoices backfill (v54)

- **Filter audit across all pages**, fixed:
  - Salespeople page: the rep dropdown was NEVER populated (no `setReps`
    call) and the customer search matched nothing (partner_name wasn't
    selected). Both fixed; rep matching is uid-aware.
  - Collections page: dropdown held payment spellings only, but the
    filter also matches orders — cross-spelling reps broke the per-rep
    "vs sales" columns. Now master list + uid-aware matching on both
    payments and orders.
  - Debt page: rows carry `user_id`; dropdown = master + snapshot
    spellings; uid-aware matching.
  - Alerts page: alerts endpoint now returns `user_id`; dropdown =
    master + alert spellings; uid-aware matching.
  - Overview: reloading the date window no longer shrinks the dropdown
    back to order-spellings only.
  - Shared `D.loadSalespeopleMaster()` (cached, never throws) feeds every
    page's dropdown so ALL reps are always selectable.
- **n8n: "Dabboos Invoices BACKFILL 2026 — run once"** standalone
  workflow, like the payments one: receivable lines dated 2026-01-01+
  PLUS all still-open lines of any date (pre-2026 open receivables are
  real debt), deduped, chunked upserts on invoice_id.
- Cache-bust v=54.

## 2026-07-16 — Fix: pagination lost rows on non-unique sort (v53)

- **Root cause of "dashboard shows fewer rows than the DB"** (owner found
  it: card Received 1,794 vs DB 1,843): `sbGetAll` fetches 1,000-row pages
  IN PARALLEL, and queries ordered only by `date` (hundreds of ties) — or
  not ordered at all — let tied rows drift between page requests. Drifted
  rows appear twice (removed by dedupe) or never (silently lost). All NINE
  paginated queries now carry a unique primary-key tiebreaker
  (`order=…,payment_id.desc` / `order_id` / `invoice_id` / `partner_id`).
  This also explains earlier small count gaps blamed on sync lag.
- n8n (no assets): the incremental payments workflow gains a
  `date >= 2026-07-01` floor — reconciling an OLD payment bumps its
  write_date, which was re-inserting pre-July rows into the July-only
  table (owner saw 177 reappear after the cleanup delete).
- Cache-bust v=53.

## 2026-07-16 — Cash card: basis note + grand total incl. rejected/cancelled (v51–v52)

- Third sub-line on "Cash collected — this month":
  **"المحصّل = مستلَم + قيد التحويل"** (states the headline's basis) and
  **"الإجمالي شاملاً المرفوضة والملغاة: X"** — the figure that matches
  Odoo's payments-list footer, so the card explains both numbers.
- v52: every status on the card shows its **count** in Odoo's group-header
  style — Received (1,842) · In transit (155) · Rejected (1) ·
  Cancelled (23) — counts sum to the total-payments figure plus
  rejected/cancelled, mirroring Odoo's day/month grouping exactly.
- Cache-bust v=52.

## 2026-07-16 — Full Odoo-style payment status split; REJECTED never cash (v50)

- Owner's Odoo month view showed a **Rejected** state (bounced payments)
  we never handled — worse, the dashboard was silently COUNTING rejected
  rows as collected cash (only `canceled` was excluded). `loadPayments`
  now excludes both by default; new `all: true` option loads every state.
- **Cash collected — this month**: second sub-line shows Rejected (red)
  and Cancelled amounts, labeled "not counted as cash". Headline stays
  received + in-transit.
- **Today's payments by status** now mirrors Odoo's grouping exactly:
  Total / ✓ Received / In transit / Rejected / Cancelled, plus a footer
  with the collected figure. Per-rep table aggregates CASH rows only.
- Fixture with the owner's real month numbers: cash = 662,730,500 while
  Odoo's grand total 669,331,000 = cash + rejected 150,000 + cancelled
  6,450,500 — the split explains the difference on-screen.
- Cache-bust v=50.

## 2026-07-16 — Cash card sub-line + payments card never blank (v49)

- **"Cash collected — this month"**: the "Collected ÷ invoiced %" sub-line
  is removed (owner request; the ratio still lives on the Collections
  page). In its place: **payment count + the received / in-transit split**
  of the month's cash.
- **"Today's payments by status"** now always renders its three category
  rows (total / received / in-transit) with zeros instead of an empty
  body — the reader sees the buckets we classify by even before the
  first payment of the day; the by-rep section shows "no data" until
  rows exist.
- Cache-bust v=49.

## 2026-07-16 — Shorter Overview: paired cards, capped heights (v48)

- The Overview was too long. The today invoice/payment cards now sit
  **side by side** (grid-2), same for the month pair; all four bodies get
  the `cap` scroll (max 60vh, sticky headers) so long rep lists scroll
  inside the card instead of stretching the page.
- The **month pair starts collapsed** on first visit (click to open;
  choice still persists per panel).
- n8n: "Dabboos Orders BACKFILL 2026 (run once)" standalone workflow —
  sale.order rows created 2026-01-01+, risk-scored against a fresh
  customer master fetched in the same run; chunked upserts on order_id.
- Cache-bust v=48.

## 2026-07-15 — Collapsible cards + full rep list + customer filter on invoice tables (v47)

- The four invoice/payment cards (today by status+rep, month by rep) are
  now **collapsible** — click the panel head to fold/unfold; the choice
  persists per panel (localStorage).
- The salesperson dropdown now includes **every rep from the `salespeople`
  master** (plus every spelling seen in orders/invoices/payments), not
  only reps with activity in the loaded window.
- **Customer search now narrows the invoice by-salesperson tables** too:
  the builders return invoice-level rows (`posted_rows` with
  partner_name), and the page aggregates client-side after applying both
  filters. Rep matching is uid-aware everywhere (the same rep can be
  spelled differently in orders vs invoices vs payments) — payments
  filtering upgraded to uid-aware as well.
- Cache-bust v=47.

## 2026-07-15 — n8n payments fix: refunds counted (no asset changes)

- Found by the owner comparing Odoo's Customer Payments day totals:
  the sync filtered `payment_type = inbound`, so **customer refunds
  (outbound) were never fetched** — the dashboard showed MORE cash than
  Odoo (2026-07-01: 33,675,250 vs 33,618,250 = one 57,000 refund).
- Both payment workflows now fetch both directions for customers and
  store refunds with **negative amounts**; every sum (day, rep, month)
  nets exactly like Odoo's signed Amount column. Verified with a fixture
  reproducing the owner's July-1 case (557,500 − 57,000 = 500,500).
- Re-import both payment workflow JSONs and run the BACKFILL once to pull
  historical refunds in (upserts — no duplicates, no truncate needed).

## 2026-07-15 — Payments cards mirror the invoice cards (v46)

- Removed by owner request: **"Cash in transit — who holds it now?"** and
  **"Reps — sales vs collected (this month)"** (leaderboard).
- New, on the payment basis (`dashboard_payments`, cancelled excluded at
  load): **"Today's payments by status"** (total / received / in-transit ×
  count · amount) with a per-salesperson table underneath (count · amount ·
  in transit · received), and **"This month's payments by salesperson"**
  under the month band — the exact twin of the invoice cards.
- Groups key on `user_id` (name fallback), honor the page's rep/customer
  filter (input rows are pre-filtered), names `D.esc`-escaped; panels
  tagged `data-src="dashboard_payments"` so the admin hide toggle covers
  them.
- Top-debtors and top-customers panels became full-width (their grid
  partners were the removed panels). DATA_SOURCES feeds updated.
- Cache-bust v=46.

## 2026-07-15 — Hide data sources also hides the KPI numbers (v45)

- Fix: hiding a source (v44) only hid the static panels; the Overview KPI
  tiles, month exec cards, and minis are rebuilt on every poll, so their
  numbers stayed visible. Each tile/card/mini now carries its own
  `data-src`, and `applyHidden()` (new sync, cache-based, no network) is
  re-run after every Overview render.
- Also tagged the alerts & salespeople KPI grids (single-source pages).
- e.g. hide **Invoices** → the "Invoiced today" KPI + "Invoiced this month"
  card disappear too, not just the invoice tables.
- Cache-bust v=45.

## 2026-07-15 — Admin: show/hide data sources + what-each-feeds (v44)

- **Admin → Data sources** panel: one toggle per raw table
  (invoices / payments / orders / customers). Turning a table off hides
  every panel and chart fed by it, **for all users** — the setting is
  global (Supabase `dash_settings.hidden_sources`, RLS: admins write /
  everyone reads). Each row also documents what that table feeds on the
  dashboard, so the impact is visible before flipping it.
- Mechanism: panels carry a declarative `data-src="dashboard_…"` tag;
  `applyDataSourceVisibility()` (run from `buildChrome` on every page)
  hides tagged panels whose source is off. Paints instantly from a
  localStorage copy (no flash), then reconciles with the server.
- Degrades safely: if `data-source-visibility.sql` hasn't been run, or the
  fetch fails, everything stays visible. Deploy order is not constrained.
- New file `supabase/data-source-visibility.sql` (run once). Mixed-source
  KPI strips and the month exec band are intentionally not hideable (they
  combine tables); only clearly single-source panels are tagged.
- Cache-bust v=44.

## 2026-07-15 — Trim the Overview month band (v43)

- Removed by owner request: the **Outstanding overdue** exec card (with its
  aging strip / credit-exposure / due-7d sub-lines), the **Quotations**
  mini stat, the **Value at risk** block, and **The story in one line**
  narrative. The month band is now two cards (invoiced vs target · cash)
  plus the mini row (confirmed · customers · cancelled · top-10 conc ·
  top governorate).
- Dead code removed with them: `buildStory`, the overdue/concentration and
  DSO/exposure computations, the critical-alerts value-at-risk sum, and the
  unused quotation totals. Top-debtors table and all other panels unchanged.
- Cache-bust v=43.

## 2026-07-15 — "This month's invoices by salesperson" (v42)

- New panel under the month exec band: month-to-date POSTED invoices per
  rep (count · amount · still unpaid · collected) — the monthly twin of
  the invoiced-today table, same basis (`buildInvoicesMonth` now returns
  `by_rep`; 4-min cache as before).
- Footer: month, invoice count, collected-so-far.
- Both per-rep tables share one row/header builder and honor the page's
  salesperson filter (user_id match, name fallback).
- Cache-bust v=42.

## 2026-07-15 — Fix: false "Unassigned" on the debt views (v41)

- `debtorsFromInvoices` stamped each customer's rep from the FIRST open
  line it met; when that line was a payment/credit (those carry no
  salesperson), the customer showed as Unassigned even though their
  invoice lines named a rep — found by the owner comparing against a
  Supabase query. Now any later line with a rep fills a missing
  `salesperson`/`user_id`. Customer-master rep still wins when present.
- Affects the Debt page, Overview top-debtors, and rep-debt groupings.
- Cache-bust v=41.

## 2026-07-14 — Per-rep invoices: Collected column + rep filter (v40)

- **"Today's invoices by salesperson"** gains a **Collected** column
  (amount − still unpaid), matching the owner's verification SQL
  one-for-one (salesperson · invoices · amount · still_unpaid · collected).
- The table now honors the page's **salesperson filter**: matched by
  `user_id` resolved from the loaded orders (order and invoice rep names
  can spell differently), with name equality as fallback.
- The rep dropdown now also includes today's invoice reps — after a data
  reset the orders table can be empty and the dropdown used to be too.
- Cache-bust v=40.

## 2026-07-14 — n8n v6: raw mirror 2026 (no dashboard asset changes)

- **"Dabboos Sync v6 — raw mirror 2026"**: n8n's only job is to mirror raw
  Odoo rows into the 4 Supabase tables from 2026-01-01, upserting on primary
  keys (duplicates impossible). The dashboard becomes a query machine over
  complete raw data.
- **Salesperson in ONE node**: the instance has a custom `salesperson_id`
  field directly on `account.move.line`, so the v5.6 `account.move` join is
  gone. (Root cause of the v5.6 slowness found: an n8n node executes once
  per incoming item, so "Odoo Invoice Moves" re-ran its window query once
  per invoice line.)
- **Payments prune removed** — payment history accumulates.
- **FULL BACKFILL 2026** (manual, run once after `supabase/reset-data.sql`
  wipes the data tables): customers → orders (scored against the fresh
  master) → payments → invoice lines (2026 slice + ALL-open slice deduped —
  pre-2026 open receivables are today's real debt). 1,000-row upsert chunks;
  collapse nodes keep every Odoo fetch single-shot.
- `supabase/reset-data.sql` added (truncates the 4 data tables +
  salespeople; never touches auth/acks/traffic).
- Verified: structure assertions + fixture simulations of every new/changed
  Code node, including the user's real `salesperson_id` sample rows.

## 2026-07-14 — Salesperson on invoices (v39)

- **`dashboard_invoices.salesperson`** (new column, `add-invoices.sql`):
  the Odoo `invoice_user_id` name snapshot. Requires **n8n v5.6** to map
  `invoice_user_id[1] → salesperson` in the invoice sync + one backfill
  run; run the `alter table` BEFORE deploying this JS (it selects the
  column) or the invoice cards 400.
- **"Today's invoices by salesperson"**: the invoiced-today card gains a
  per-rep table (count · amount · still unpaid) over today's POSTED
  invoices — rows sum to the posted total; cancelled/drafts excluded.
  Name = invoice `salesperson`, else customer-master assigned rep (cached
  4 min) for pre-backfill rows, else "ID n". Names are `D.esc`-escaped.
- Debt attribution unchanged (assigned rep first), but the invoice's
  salesperson now backfills missing names in the debt views.
- Cache-bust v=39.

## 2026-07-13 — Month card on invoice basis (v38)

- **"Invoiced — this month (posted)"** replaces the order-based month
  revenue card: Σ posted invoices this month, MoM vs same days of last
  month (invoice basis), sub-line = invoice count + collected-so-far.
  Story line + "Collected ÷ invoiced" updated to match.
- Cash collected — this month: unchanged, confirmed already payment-based
  (dashboard_payments, same basis as the today KPI).
- **n8n v5.5**: adds a one-click "BACKFILL Months" branch (all receivable
  items dated since the 1st of last month, paid included) — required once,
  because the ledger backfill fetched only OPEN items and early-month paid
  invoices are missing (pre-backfill July shows 490.9M / 1,092 invoices).
- 4/4 fixture tests (month bucketing, same-days MoM, collected).
  Cache-bust v=38.

## 2026-07-13 — Invoiced-today (accounting view) + city from partner data (v37)

- **"Invoiced today" KPI** replaces the order-value KPI in the today strip:
  posted customer invoices dated today, with same-day collection %. Verified
  against the Odoo screen: 174 posted = 94 not paid / 47 paid / 33 partial,
  6 cancelled, 66.96M — exact match (7/7 fixture tests).
- **"Today's invoices by status" table**: posted / paid / partially paid /
  not paid / cancelled × count · value · still-unpaid, with same-day
  collected and the not-yet-invoiced gap underneath.
- **"Due within 7 days"** line in the overdue card — money to chase BEFORE
  it becomes overdue.
- **City strictly from partner data (n8n v5.4)**: customer fetches add
  `city_id` (the res.city dropdown — likely why 26% looked city-less);
  resolved city = free-text city else dropdown name. Regions/Overview embed
  the customer master's governorate+city through the FK and prefer them
  over the per-order snapshot.
- Cache-bust v=37.

## 2026-07-12 — Remove "Confirmed, not invoiced" (v36)

- Removed by owner request: the Overview exec card and the Debt-page KPI;
  the adapter no longer runs its query (one less request per refresh).
  Exec band is now 3 cards: revenue · cash · overdue+aging.
- Cache-bust v=36.

## 2026-07-12 — Net receivable ledger + calmer polling (v35)

- **Debt now nets unapplied credits**: the ledger backfill captured 1,532.6M
  gross while the true net book is ~1,376M — the gap is customer payments /
  credit notes not yet matched to invoices (negative residuals). The
  adapter now loads `amount_residual != 0` and credits subtract per
  customer and per aging bucket, mirroring Odoo's Aged Receivable.
  "Days late" is computed from debit items only. n8n v5.3 backfill fetches
  both signs.
- **POLL_MS 60s → 180s**: every poll re-downloads and re-renders the whole
  window; on low-power machines the 60s cycle kept the main thread busy
  enough for Chrome's "Page Unresponsive" prompt. Heavy aggregates remain
  cached 4 minutes.
- Cache-bust v=35.

## 2026-07-12 — Today's orders explained + staged rendering + AR ledger (v34)

- **"Orders today (as in Odoo)" KPI**: the big number is now the day's TOTAL
  record count (matches Odoo's grouped list, e.g. 172), with the composition
  spelled out underneath: ✓ confirmed · quotations · cancelled.
- **Staged rendering (Overview)**: the page paints as soon as orders+payments
  arrive (~1–2s); debt/aging panels re-render when their queries finish.
  Every table/chart section is individually guarded — a failure logs
  `[overview] <section>` to the console and empties only that panel, never
  the whole page. Loading placeholder replaces the frozen-looking blank.
- **Debt basis corrected — Sync v5.1**: invoices-only capture was 322M of a
  ~1,349M receivable book (opening balances/journal entries are not
  invoices). v5.1 feeds `dashboard_invoices` from `account.move.line`
  open receivable items (the partner ledger) — complete and still 100%
  transactional. Requires: `delete from dashboard_invoices;` then import
  v5.1 + run its BACKFILL branch once.
- Cache-bust v=34.

## 2026-07-11 — Debt from transactional facts: invoices replace precomputed fields

Owner's principle adopted: dashboard numbers come from transactional rows
that can be verified in Odoo one-by-one. The customers table's precomputed
money fields (`credit`, `vt_overdue_amount`, DSO — a custom-addon black box)
no longer drive any KPI; `dashboard_customers` is demoted to identity only
(name, assigned rep, governorate).

- **New `dashboard_invoices`** (`supabase/add-invoices.sql`) synced from
  `account.move` by n8n v5 (48h write_date lookback so residuals and
  payment states heal; disabled one-click BACKFILL branch fetches the whole
  open book on first run).
- **Adapters rebuilt on invoices**: receivable = Σ open residuals; overdue =
  residuals past due date; aging strip = amounts by days-late (≤30/31–60/
  >60/no-due-date); top debtors carry "days overdue" (oldest late invoice).
  15/15 fixture tests pass on the aging/grouping math.
- Overview: aging strip now shows IQD amounts; debtors column renamed
  "Days overdue". Pages otherwise unchanged (same adapter shapes).
- Cache-bust v=33.

## 2026-07-11 — Performance: parallel pages, adapter cache, initplan RLS

Measured causes of slowness (from Iraq: ~183ms per round trip):
serial pagination (orders window = 4 sequential requests ≈ 1.8s), the
raw-table adapters re-aggregating thousands of rows on EVERY 60s poll,
and RLS policies calling dash_role() per scanned row.

- `sbGetAll` now fetches page 1 with `Prefer: count=exact` and pages 2..N
  **in parallel** — a 4-page window costs ~2 round trips instead of 4.
- The three adapters (`rep_debt`, `collections`, `rep_collections`) are
  cached for 4 minutes (verified: cached call = 0ms) — receivables data
  changes hourly at most; live order/payment windows still poll every 60s.
- **`supabase/perf-policies.sql`** (run once): rewrites every policy to the
  `(select dash_role())` InitPlan form — role evaluated once per query
  instead of once per row. Same security.
- Cache-bust v=32.

## 2026-07-11 — Real governorate + Overview story headings

- **Real governorate from Odoo** (`res.partner.state_id`): n8n v4.1 syncs it
  into `dashboard_customers.governorate` (`supabase/add-governorate.sql`);
  the Regions page embeds it through the orders→customers FK and prefers it,
  falling back to the free-text city dictionary only when empty. `govOf()`
  also recognizes English governorate names. This is the durable fix for the
  "Unknown / بدون مدينة" buckets — coverage grows as the field fills in Odoo.
- **Overview decluttered** (by request): removed the "Cash in process (held
  by reps)" KPI (the per-holder in-transit panel remains); the placeholder
  900M target is now 0 → the misleading "% of target / on pace" bar is hidden
  until a real target exists (ideally synced from Odoo's salesperson.target);
  "Top governorate" now ignores no-city/unknown buckets so "No city" can
  never be crowned the top region.
- **Story headings on the Overview**: five numbered questions (AR/EN) that
  make the page read top-to-bottom as a narrative — Today: how is the day
  going? · The month: are we on track? · Names: who do we call? · Rhythm:
  which way are we trending? · Cash & customers: who holds our money?
- Cache-bust v=31.

## 2026-07-11 — Raw-tables restructure: n8n is a fetcher, snapshots retired

- **Architecture:** Odoo → n8n (fetch-only) → relational Supabase tables →
  dashboard queries. No n8n-computed snapshots/summaries anywhere — every
  aggregate is computed in the browser from rows that can be audited
  against Odoo one-by-one.
- **Schema** (`supabase/restructure.sql`): new `salespeople` table (user_id
  PK — one spelling per rep, backfilled from orders+payments);
  `dashboard_customers` gains the assigned rep (user_id FK); orders gain
  `partner_id` FK; `date_order`/`create_date` become timestamptz and
  payments `date` a real date; indexes for all polling queries; RLS for the
  new table.
- **n8n v4** ("Dabboos Sync v4 — raw only"): all snapshot-builder nodes
  deleted; FK-safe upsert order (salespeople → customers → orders); hourly
  full pull now fills the `dashboard_customers` MASTER (all real customers,
  with assigned rep); includes all v3/v3.1 fixes (write_date fetch, states
  heal, false→null, pagination irrelevant now).
- **Dashboard:** `D.api("rep_debt"/"collections"/"rep_collections")` are now
  raw-table adapters returning the same shapes — Debt, Collections and
  Overview pages unchanged by design. Bases documented in METRICS.md
  (aging/exposure now cover ALL owing customers, not just recently-seen).
- Cache-bust v=30. ARCHITECTURE.md rewritten. Cutover order documented in
  restructure.sql (SQL → n8n v4 + backfill → deploy → retire snapshots).

## 2026-07-08 — Overview v2: business-owner metrics (audit-driven)

### Fixed
- **MoM was misleading:** it compared the partial current month against the
  FULL last month. Now compares month-to-date vs the same days of last month,
  and hides the delta entirely when history doesn't cover the compared days.

### Added — Overview
- **Today strip:** sales & cash now show "vs 4-week same-weekday average";
  new "cash in process" aging flag (⚠ N payments older than 3 days + amount);
  new 4th KPI: orders today + cancelled today.
- **Overdue card:** receivables age strip (≤30 / 31–60 / >60 DSO customer
  buckets) + total credit exposure — from the collections snapshot the page
  already downloads, labeled "as of latest snapshot".
- **Minis:** cancel rate % and top-10 customer share of period revenue.
- **Debtors table:** DSO column (red when >60d).
- **Rep leaderboard:** cash-in-transit and critical-orders columns per rep.
- **New chart:** weekly confirmed revenue, last 6 Saturday-start weeks
  (current partial week drawn lighter). No extra data fetched.
- **New panel:** "Cash in transit — who holds it now?" top courier journals
  with amount + oldest payment age (red past 3 days).
- Rejected during verification: "confirmed, not delivered" from
  `delivery_count` — Odoo counts pickings created at confirmation, not goods
  delivered; the number would lie (see METRICS.md).

### Added — quotations visibility
- "Orders per day" is now a 3-way stack: confirmed (blue) + **quotations
  draft/sent (amber)** + cancelled (grey); bar totals still match Odoo.
- New "Quotations" mini (count + value for the filter range).

### Docs
- **`docs/N8N_AUDIT.md`** — full audit of the n8n sync with proofs: snapshot
  reads silently truncated at Supabase's 1,000-row cap (summary says 964 July
  orders, table has 986), payment states never heal (32 stale in_process),
  payments fetch fragile (limit 800, no date filter), 2h payment lag,
  dashboard_customers upsert never lands, UTC/Baghdad day mixing in
  snapshots, missing backfill after downtime, service key hygiene + Supabase
  index/table recommendations.
- New helpers `D.addDays` / `D.weekStartSat` (8 unit tests pass); metrics
  bases documented in METRICS.md. Cache-bust v=28.

## 2026-07-07 — Match Odoo's daily order counts (audit-driven)

- **Audited the "gap" vs Odoo for Jul 1–7:** Supabase has exactly the same 913
  orders as Odoo (zero missing, zero duplicates). The visible difference was
  (a) 36 cancelled/draft orders Odoo's list counts but the dashboard excludes
  by policy, and (b) day-boundary drift from bucketing raw UTC timestamps.
- **New `D.bagDay()`**: buckets datetimes into Asia/Baghdad calendar days, the
  same way Odoo's screens group them. The Overview (`dayOf`) now uses it
  everywhere; the fetch window is widened 1 UTC day so Baghdad-evening orders
  on the first day aren't lost.
- **"Orders per day" chart is now stacked**: blue = confirmed (still the only
  thing any KPI counts), grey = cancelled/unconfirmed, so the bar total
  matches Odoo's grouped Orders list. Tooltip shows both + "Total (as in
  Odoo)". METRICS.md date axis corrected (`date_order`, Baghdad days).
- Cache-bust v=26 (+ service worker VERSION).

## 2026-07-07 — Login gate, admin panel & installable app (PWA)

### Added — authentication (Supabase Auth + RLS)
- **Username/password login** (`login.html`). Usernames map to synthetic
  `ahmed@dabboos.app` emails; sessions are stored/refreshed by the new
  `assets/js/auth.js` and every Supabase call now carries the user's JWT.
- **Roles enforced by the database** (`supabase/auth-setup.sql`): `admin`
  (everything + admin panel), `management` (all dashboard pages), `alerts`
  (Alert Center only — RLS only serves them critical/warning order rows).
  The anon key alone now reads **nothing**.
- **Per-user page permissions** (`dash_users.pages` jsonb) override role
  defaults; nav + page guard respect them.
- Alert acknowledgements now record **who** acked (`acked_by`,
  `acked_by_name`) instead of being anonymous.

### Added — admin panel (`admin.html`, admins only)
- Create users, edit full name / role / per-page checkboxes / active flag.
  New and self-signed-up accounts start **inactive** (see nothing) until
  activated. Self row is locked so you can't lock yourself out.
- **Traffic**: every page load logs to `page_views`; the panel shows views
  today / 7 days / active users, a 30-day per-day chart, by-page and by-user
  breakdowns, and recent activity. Admin-read-only via RLS.

### Added — PWA ("install like an app" on phones)
- `manifest.webmanifest`, `service-worker.js`, generated icons
  (`assets/icons/`), and meta tags on every page. Employees can Add to Home
  Screen on Android/iOS; the dashboard opens standalone and full-screen.
- The service worker never caches Supabase (numbers stay live); app shell is
  network-first with offline fallback, CDN assets cache-first.

### Docs
- New `docs/AUTH.md` (setup order, security model and its honest boundaries),
  updated `CLAUDE.md` hard rules, KNOWN_ISSUES #2 → 🟡 / #3 → ✅.
- Cache-bust v=25 (+ service worker `VERSION` now tracks it).

## 2026-07-05 — Kill the "Unknown" governorate bucket (data-driven)

- Audited every live `city` value (2,629 orders): 780 orders / 303M IQD were
  "Unknown". Root cause split: **701 orders (239M) have an empty city in Odoo**;
  only 79 were genuinely unrecognized strings.
- **New `nocity` bucket** ("بدون مدينة / No city"): empty city is now reported
  separately from unrecognized city, each with its own fix instruction. Regions
  page shows two banners (red = fill City field in Odoo; amber = add to
  dictionary).
- **+26 dictionary entries** — every remaining real string, assigned by
  cross-checking geography against the owning rep's territory (68–100%
  agreement): Basra districts (الحيانية، الطويسة، المدينة، الجزائر، الدير…),
  Mosul (الفيصلية، الساحل الأيسر، المهندسين…), Baghdad (حي اور، اعلام، الجاردية),
  Babil (الحصوة، ناحية الامام), plus typo fixes (كؤكوك→Kirkuk، ارييل→Erbil).
- Result: true "Unknown" is now **2 orders / ~3M IQD** (garbage strings `٩٩`,
  `داكير` — clean at the source in Odoo). 23/23 regression cases pass.
- Cache-bust v=24.

## 2026-07-05 — Match Odoo: count sales by order date (date_order)

- All order date-bucketing (Overview, Regions, Collections period sales,
  Salespeople) switched from `create_date` to `date_order` — the same basis as
  Odoo's Sales screens, so "today's orders" now matches Odoo (the 117 vs 148 gap).
- Pairs with the Site_Orders_Sync workflow v2 (fetch by `write_date` = anything
  created/confirmed/cancelled/edited today; snapshots bucketed by `date_order`).
  Stale rows (orders confirmed or cancelled days after creation) now self-heal.
- Cache-bust v=23.

## 2026-07-05 — Executive overview redesign (audit-driven)

### Changed — Overview (`index.html`)
- **New "Today" strip** (always anchored to today, respects rep/customer filters):
  sales today, cash collected today, and cash in process (held by reps).
- **4th hero card: "Confirmed, not invoiced"** (from the `collections` snapshot) —
  ~263M IQD / 578 orders of sold-but-uninvoiced revenue is now impossible to miss.
- **Two action tables replace two low-value charts:** Top-10 overdue debtors
  (who to call today) and a rep leaderboard (sales vs collected MTD with a
  color-coded collection ratio).
- **Removed:** order-status doughnut (97% one state — told nothing), conversion %
  mini (~18 quotations/month), avg-order-value mini, DSO approximation, and the
  top-governorates chart (lives on the Regions page; the mini stat remains).
- Minis are now: confirmed orders, customers, cancelled orders, top governorate.

### Fixed — numbers
- **`loadPayments()` now excludes `canceled` payments** (`state=neq.canceled`).
  This closes the on-screen mismatch where Collections KPIs read 226,000 IQD
  higher than the 14-day grid (the snapshot already skipped canceled rows).
- **~30 new city→governorate dictionary entries** (Baghdad districts, Anbar,
  Karbala, Basra, Nineveh towns…) verified against live order data — reduces
  "Unknown" governorate orders further on top of the normalizer.
- Added the missing `.ok` CSS class (green) used by ratio cells.

### Notes
- Asset cache-bust bumped to `?v=22`.
- Hero band is now 4 columns (2×2 below 1280px).

## 2026-07-02 — Trust & security pass

### Fixed — numbers / trust (CEO-facing)
- **Governorate mapping overhauled** (`common.js`): new `normCity()` normalizes
  Arabic diacritics, alef/ya/hamza/ta-marbuta, Persian letters, and location
  prefixes; `govOf()` now matches normalized forms, governorate names, and tokens
  inside compound strings. Far fewer cities fall into "Unknown". 13 unit cases pass.
- **"Unmapped cities" banner** on `regions.html`: shows the count/value/% of
  orders that couldn't be classified, so "Unknown" is transparent, not silent.
- **Basis note** on `regions.html`: states the numbers are confirmed orders,
  tax-inclusive, by create_date — and may differ from Odoo Invoice Analysis.
- **Client-side de-duplication** (`common.js`): `loadOrders`/`loadPayments`/alerts
  now de-dupe by `order_id`/`payment_id`, so duplicate sync rows no longer inflate
  counts (defense against the "606 orders" symptom).

### Fixed — security
- **Stored XSS closed:** added `DASH.esc()` and wrapped every database-derived
  string rendered via `innerHTML` across `index/alerts/debt/regions/collections/
  salespeople` and `order-modal.js`. The anonymously-written alert `note` was the
  critical vector.

### Fixed — hygiene
- Removed stale `N8N_BASE`/n8n references from error messages and comments
  (`common.js`, `config.js`, `order-modal.js`); the app reads Supabase directly.
- Clarified the placeholder-target warning in `config.js`.

### Added — documentation
- `README.md`, `CLAUDE.md`, `docs/ARCHITECTURE.md`, `docs/METRICS.md`,
  `docs/KNOWN_ISSUES.md`.

### Not changed (tracked in docs/KNOWN_ISSUES.md)
- RLS verification + committing `supabase/schema.sql` (#2) — needs Supabase access.
- Access gate in front of the dashboard (#3) — hosting config.
- Polling bandwidth (#5), Chart.js SRI (#7), real revenue target (#9).
- The real governorate fix (Odoo `state_id`) and n8n upsert — backend/n8n work.
