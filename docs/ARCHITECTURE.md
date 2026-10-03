# Architecture

## Data flow (since the 2026-07 raw-tables restructure)
```
┌────────┐     ┌──────────────┐     ┌─────────────────────┐     ┌───────────────┐
│  Odoo  │ ──▶ │ n8n          │ ──▶ │ Supabase (Postgres) │ ──▶ │  Dashboard    │
│ (ERP)  │     │ FETCH ONLY   │     │  raw tables, PK/FK  │     │  (browser JS) │
└────────┘     └──────────────┘     └─────────────────────┘     └───────────────┘
```
- **Odoo** is the source of truth (sale orders, payments, partners, ledger).
- **n8n** ("Dabboos Sync v6 — raw mirror 2026") is a **pure fetcher / raw
  mirror**: it copies rows from Odoo into Supabase tables (history from
  2026-01-01, plus ALL still-open receivables regardless of date) and computes
  nothing except the per-order risk score (`level`/`reasons`). There are
  **no snapshots or summaries** — every aggregate the dashboard shows is
  computed from raw rows, so any number can be traced to rows you can inspect
  and compare with Odoo directly. Upserts are keyed on primary keys
  (`on_conflict` + merge-duplicates), so re-syncing can never duplicate rows.
- **Supabase** stores the raw tables and serves them over PostgREST. The
  browser sends the logged-in user's JWT; Row-Level Security decides access
  (see `docs/AUTH.md`).
- **Dashboard** is static files; each page polls every `POLL_MS` (60s).

## Tables (relational, see `supabase/restructure.sql`)

| Table | Key | Contents |
|---|---|---|
| `salespeople` | `user_id` PK | one row per rep (res.users) — the single spelling of every rep name |
| `dashboard_customers` | `partner_id` PK, `user_id` FK→salespeople | customer MASTER: assigned rep, credit (=receivable), credit_limit, overdue, DSO, trust, sales/payment averages, payment method |
| `dashboard_orders` | `order_id` PK, `partner_id` FK→customers, `user_id` FK→salespeople | one row per sale order: state, `date_order`/`create_date` (timestamptz), amounts, invoice/delivery counts, risk `level`+`reasons`, embedded customer profile as-of scoring time |
| `dashboard_payments` | `payment_id` PK, `user_id` FK→salespeople | one row per customer payment: `date` (date), amount, state (paid / in_process / canceled), courier `journal`. History accumulates (the 95-day prune was removed in v6) |
| `dashboard_invoices` | `invoice_id` PK (= `account.move.line` id) | one row per receivable JOURNAL ITEM: dates, due date, `amount_residual` (what's still unpaid), `salesperson` (custom `salesperson_id` field on the line) — **the transactional source of all debt/aging numbers** |
| `alert_acks` | | alert acknowledgements written by the dashboard (`acked_by` user) |
| `dash_users`, `page_views` | | auth roles/permissions + traffic log (`docs/AUTH.md`) |

Sync cadence: orders + on-demand customers every 20 min (48h `write_date`
lookback, so downtime self-heals); payments every 20 min (48h lookback —
states heal `in_process → paid`); invoice lines every 20 min (48h lookback);
full customer master pull every 2 h.
All upserts are FK-ordered: salespeople → customers → orders.
One-time **FULL BACKFILL 2026** manual trigger (run after
`supabase/reset-data.sql`) fills all four tables sequentially:
customers → orders (scored) → payments → invoice lines (2026 slice + all-open
slice, deduped), in 1,000-row upsert chunks.

## How pages get aggregates — `api()` adapters in `common.js`
The old n8n snapshots (`rep_debt`, `rep_collections`, `collections`) are now
**adapter functions** that query the raw tables and return the same shapes:
- `buildRepDebt()` — debtors grouped by assigned rep, from `dashboard_customers`.
- `buildRepCollections()` — 14-day per-rep paid/pending grid, from `dashboard_payments`.
- `buildCollections()` — DSO aging buckets, credit exposure, top overdue (from
  customers) + uninvoiced and new-risk orders (from `dashboard_orders`).
`loadOrders()` / `loadPayments()` paginate past PostgREST's 1,000-row cap and
de-duplicate by primary key. If an aggregate ever gets too heavy for the
browser, the upgrade path is a SQL (materialized) **view inside Postgres** —
never a computed table written by n8n.

## Client library (`window.DASH`)
`common.js` exposes: i18n (`t`, `isAR`), formatting (`fmtMoney`…), security
(`esc`), API (`api`, `loadOrders`, `loadPayments`, `sbGetAll`, `sbWrite`,
`ackAlert`), dates (`bagDay` Baghdad-day bucketing, `addDays`,
`weekStartSat`), geo (`govOf`, `govLabel`), UI (`buildChrome`, `filterBar`,
`toast`…), and `cfg`. Auth lives in `window.DASH_AUTH` (`auth.js`).

## Rendering model
Each page's inline `<script>`: `buildChrome` → `filterBar` → load raw window →
`render()` recomputes every KPI/chart client-side → `setInterval` re-polls.
Client-side aggregation is deliberate: a date filter genuinely recomputes
everything from rows, and every figure is auditable against the table.
