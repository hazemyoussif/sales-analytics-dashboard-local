# Metric definitions & trust notes

This file is the contract for what every number means. A CEO dashboard lives or
dies on trust — if two numbers use different bases without saying so, the whole
tool loses credibility. **Read this before changing any calculation.**

## The three axes that MUST be stated for every money figure
1. **Orders vs. Invoices.** This dashboard counts **sales orders**, not invoices.
   "Confirmed sales" = orders in state `sale` or `done`. An order can be
   confirmed but not yet invoiced (see the "uninvoiced" metric on the debt page).
2. **Tax-inclusive vs. untaxed.** All amounts use Odoo's `amount_total`, which is
   **tax-inclusive**. Odoo's *Invoice Analysis* report defaults to **Untaxed
   Total**. Same transactions, different number.
3. **Which date.** Order aggregation is by **`date_order`** (Odoo's "Order
   Date" — the same basis as Odoo's Sales screens; it moves to the confirmation
   time when a quotation is confirmed), not `create_date` or `invoice_date`.
   Days are bucketed in the **Asia/Baghdad** calendar (Odoo stores UTC but
   displays/groups in the user's timezone) — see `D.bagDay()` in `common.js`.
   The Overview uses this everywhere (`dayOf`); a UTC slice would put
   late-evening orders on the wrong day vs the Odoo screen.

### ⚠️ Reconciling with Odoo "Invoice Analysis"
The regions numbers will **not** match Odoo's Invoice Analysis by default,
because they measure different things. To compare fairly:
- Dashboard = confirmed **orders**, **tax-inclusive**, by **create_date**.
- Invoice Analysis = posted **invoices**, **untaxed**, by **invoice date**.

They only converge if you align all three axes. This is a **definitional
difference, not necessarily a bug.** If after aligning them the counts still
diverge wildly, check for duplicate rows (see `KNOWN_ISSUES.md` #4):
```sql
select count(*), count(distinct order_id) from dashboard_orders;
-- if these differ, duplicate sync rows are inflating counts
```
The regions page now shows the confirmed-orders/tax/create_date basis inline,
and surfaces an "Unmapped cities" banner so unclassified value is visible.

## Confirmed sales
`state ∈ {sale, done}`, summing `amount_total`. Quotations (`draft`, `sent`) and
`cancel` are excluded. Used on Overview, Regions, Salespeople.

## Orders per day (Overview chart)
Stacked bar per Baghdad day: **blue = confirmed** (`sale`/`done`, the only
segment any KPI counts) + **grey = cancelled/unconfirmed**. The bar TOTAL
therefore matches Odoo's grouped Orders list, which counts every record
including cancelled — verified 2026-07-07 against Odoo for Jul 1–7 (913 = 913,
zero missing/duplicate rows; the visible per-day "gap" was exactly the 36
cancelled/draft orders Odoo includes and the dashboard excludes by policy).

## Conversion rate
`confirmed / (confirmed + quotations)` by order **count** within the filter
range. Note it's count-based, not value-based.

## Average order value (AOV)
`confirmed value / confirmed count` within the range.

## Governorate (Regions page)
Derived from the free-text `city` field via `govOf()`. `govOf` normalizes the
string (diacritics, alef/ya/hamza/ta-marbuta, Persian letters, prefixes like
`محافظة`/`حي`) and matches it against a dictionary of known cities and
governorate names; unmatched values fall into **"Unknown" (غير محدد)**.
- "Unknown" means *"the city text didn't match our dictionary,"* not *"Odoo has
  no data."* The Regions page now shows how many orders/how much value are
  unmapped so this is transparent.
- **Correct long-term fix:** sync a real governorate field from Odoo
  (`res.partner.state_id`) so classification doesn't depend on parsing free text.
  See `KNOWN_ISSUES.md` #1.

## Cash collected
Sum of `dashboard_payments.amount` in the period. "Collected ÷ sales" divides
period collections by period **confirmed order value** (tax-inclusive) — a
rough liquidity signal, not an accounting figure.

## Overdue / Receivable (Debt page) — transactional basis (2026-07-12)
Debt is computed from the **receivable LEDGER open items**
(`dashboard_invoices`, synced from Odoo `account.move.line` where
`account_type = asset_receivable` — Sync v5.1):
- **Receivable** = Σ `amount_residual` of posted, unreconciled items.
- **Overdue** = the slice whose `date_maturity` (due date) has passed.
- Grouped by customer, then by the customer's **assigned rep**; identity
  comes from the customers master, whose precomputed money fields
  (`credit`, `vt_*`, DSO) are **no longer used** for any KPI.
⚠️ Lesson recorded 2026-07-12: syncing only customer *invoices*
(`account.move`, out_invoice) captured 322M of a ~1,349M book — the rest is
**opening balances / journal entries** that are receivable but not invoices.
The ledger (journal items) is the complete transactional truth; every row
matches Odoo → Accounting → Partner Ledger.

## Invoiced — this month (Overview month card, 2026-07-13)
Σ `amount_total` of POSTED INV/ invoices with `invoice_date` in the current
month (accounting revenue). MoM compares vs last month's SAME days, invoice
basis, hidden when last month's invoices aren't in the table. Sub-line shows
invoice count + how much of the month's invoicing is already collected
(Σ total − residual). "Collected ÷ invoiced" = payments month ÷ invoiced
month. ⚠ Requires the v5.5 "BACKFILL Months" one-time run — the ledger
backfill only fetched OPEN items, so fully-paid invoices from before the
cutover are missing until then (undercount). The order-based month numbers
remain on the charts/minis (commercial view), clearly separated.

## Invoiced today (Overview, 2026-07-13)
From `dashboard_invoices`, INV/ documents with `invoice_date = today`:
- **Invoiced today** = Σ `amount_total` of POSTED invoices (accounting
  basis, tax-inclusive — deliberately different from the order-based month
  band, and labeled as such).
- **Status split** = cancelled (`state`), paid (residual 0), partially paid
  (0 < residual < total), not paid (residual = total). Drafts ignored.
- **Collected same-day** = Σ (total − residual) over today's posted rows.
- **By salesperson** (2026-07-14) = the POSTED slice grouped by the
  row's `user_id` (the custom `salesperson_id` field on the receivable
  journal item, synced by n8n v6). Display name = the row's own
  `salesperson` column, else the customer master's assigned-rep name for
  rows synced before the column existed, else "ID n". Cancelled/draft rows
  are excluded, so the per-rep values sum to the posted total.
- **Invoicing gap note** = today's confirmed ORDER value − invoiced value.
- **Due within 7 days** (overdue card) = open residuals with
  today ≤ due_date < today+7 — the pre-overdue collections calendar.
Phase-2 ideas: weekly invoiced-revenue trend (needs history to accumulate),
avg days-to-pay (needs payment-date sync).

## City preference chain (2026-07-13 — partner data only)
governorate (`res.partner.state_id`) → customer master `city`
(free-text `city`, else the `city_id` dropdown name — synced by n8n v5.4)
→ the order's own city snapshot → "no city". No name-guessing.

## Raw-table adapter bases (2026-07 restructure — snapshots retired)
- **Payments basis (2026-07-16, full parity)**: `dashboard_payments` holds
  ALL customer payments — inbound receipts positive, **outbound refunds
  negative** (signed in n8n from `payment_type`), so every sum nets exactly
  like the signed Amount column on Odoo's Customer Payments screen. Before
  this, refunds were skipped and the dashboard showed MORE cash than Odoo
  (2026-07-01: +57,000). Additionally, **partner-less rows are kept only at
  zero amount** (voided receipts وصل ملغي/تالف — gives count parity with
  Odoo's day view); partner-less rows with real money are internal
  transfers between cash boxes and are dropped (not collections). Vendor
  payments never fetched. **Cancelled AND rejected (bounced) payments are
  stored but are never cash**: `loadPayments` excludes both by default;
  the Overview loads all states (`all: true`) purely to show them as their
  own status rows, Odoo-style (2026-07-16 — before this, `rejected` was
  silently counted as collected).
- **14-day collections grid** = `dashboard_payments` rows of the last 14
  Baghdad days; paid = state `paid`, pending = state `in_process`.
- **Receivables age strip** = open-invoice residual AMOUNTS bucketed by
  days past due: ≤30 (incl. not yet due), 31–60, >60, unknown (no due date).
- **"Days overdue" column** = the customer's oldest overdue invoice age.
- **Credit exposure** = Σ all open residuals (the whole open book).
- **New risk** = this month's confirmed orders with `level = critical`.
- ~~Uninvoiced~~ — removed from the UI 2026-07-12 by owner request (was:
  confirmed orders of the last 95 days with `invoice_count = 0`).

## DSO (Days Sales Outstanding)
`receivable / thisMonthConfirmedSales × 30`. A **rough proxy** only: it mixes a
point-in-time balance with a single month of order value. Do not quote as a
precise finance metric.

## Overview v2 additions (2026-07-08)
- **MoM delta** = confirmed MTD vs **the same number of days of last month**
  (day-of-month ≤ today's). Never partial-vs-full. The delta is hidden when
  the loaded data doesn't cover the compared days (history starts mid-June
  2026) — no delta beats a wrong delta.
- **"vs typical" on Today KPIs** = today vs the average of the last 4 same
  weekdays (Baghdad days), from the loaded window. Hidden when the average is 0.
- **Cash in transit** = payments with `state = in_process`; "stuck" = older
  than 3 days by collection `date`. Grouped by the Odoo `journal` (the courier
  holding the money). ⚠ accuracy depends on the payments sync healing states —
  see `N8N_AUDIT.md` #2.
- **Receivables age strip** = `dso_buckets` from the `collections` snapshot
  (customer counts ≤30 / 31–60 / >60 DSO days) — labeled "as of latest
  snapshot", not date-filtered. Credit exposure comes from the same snapshot.
- **Top-10 customer share** = top 10 customers' confirmed value ÷ all
  confirmed value in the filter range.
- **Cancel rate** = cancelled ÷ (confirmed + cancelled) by count, filter range.
- **Weekly revenue chart** = confirmed value per Saturday-start week, last 6
  weeks from the loaded window; the current (partial) week is drawn lighter.
- **Rejected: "confirmed, not delivered" from `delivery_count`** — Odoo
  creates the delivery order at confirmation, so `delivery_count` counts
  pickings created, NOT goods delivered; it cannot measure fulfillment.
  Needs a real delivery-state field from Odoo first.

## Month pace / attainment (Overview)
- `attain = revMonth / MONTHLY_REVENUE_TARGET`.
- `pace = revMonth / dayOfMonth × daysInMonth` — naive **linear** extrapolation;
  ignores weekends and seasonality.
- ⚠️ `MONTHLY_REVENUE_TARGET` in `config.js` is a **placeholder**. Until it's the
  real company goal, attainment/pace are meaningless. Set it, or set it to `0`
  to hide the target bar (the code falls back to showing order count).

## WoW / MoM (Salespeople, Collections)
Week starts **Saturday** (Iraq). MoM compares this calendar month to last.
Percent change = `(current − previous) / previous`, or `100%` when previous is 0.

## Value at risk (Overview)
Sum of `amount_total` for orders whose alert `level = critical` in the last
45 days. Sourced from the `alerts` query, not the date-filtered window.
