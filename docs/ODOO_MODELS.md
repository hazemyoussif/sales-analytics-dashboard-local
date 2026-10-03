# Odoo models available to n8n — catalog & sync roadmap

Source: the model list exposed by the n8n Odoo node on the live instance
(2026-07-11). Framework internals (ir.*, wizards, qweb, mail plumbing, themes,
~350 models) are omitted — everything business-relevant is below.

## ✅ Currently synced (Dabboos Sync v4)

| Odoo model | → Supabase table | What |
|---|---|---|
| `sale.order` | `dashboard_orders` | order headers (state, dates, amounts, counts, risk scoring) |
| `account.payment` | `dashboard_payments` | inbound customer payments (paid / in_process) |
| `res.partner` | `dashboard_customers` | customer IDENTITY master (name, assigned rep, governorate, limits) — its precomputed money fields are no longer used by the dashboard |
| `account.move.line` | `dashboard_invoices` | receivable JOURNAL ITEMS (partner ledger): due dates + open residuals — the transactional debt source. Since v6 also `salesperson`, from the **custom `salesperson_id` field on the line** (this instance's sales module — standard Odoo has no salesperson on journal items, so this saves a whole `account.move` join) |
| (derived) | `salespeople` | one row per rep (res.users id + name) |

## ⭐ Recommended next syncs (priority order)

| # | Model | Why (what it unlocks) |
|---|---|---|
| 1 | `res.partner.state_id` + **`res.city`** | A real governorate/city instead of free-text guessing — `res.city` exists on this instance, so cities may already be structured. Kills the dictionary problem permanently. One field + one small table. |
| 2 | **`sale.order.line`** | Product-level sales: top/dead products, mix by region/rep/customer, discount leakage, basket size. The single biggest missing dataset. → `dashboard_order_lines` |
| 3 | **`product.product`** / `product.template` + `product.category` + `product.brand` | Product master incl. **cost** (`standard_price`) → margin per product/order/customer/rep. You even have brands. → `dashboard_products` |
| 4 | **`account.move`** (+ `account.move.line`) | Customer invoices: number, date, **due date**, payment_state → TRUE receivables aging by document, invoiced-vs-ordered reconciliation, accountant-matching revenue. → `dashboard_invoices` |
| 5 | **`stock.picking`** | Delivery status + completion date per order → the honest "sold but not delivered" metric (delivery_count can't provide it). |
| 6 | `crm.team` / `crm.team.member` | Channel segmentation (van sales vs اون لاين vs POS). |

## 💎 Custom modules found on this instance (high value, zero extra cost)

These are **your company's own models** — data that exists nowhere else:

| Model | What it is | Dashboard opportunity |
|---|---|---|
| **`salesperson.target`** (+ `.line`, `.settlement`, `.incentive.scheme/.rule`) | Per-rep sales targets & incentive schemes | Replace the PLACEHOLDER `MONTHLY_REVENUE_TARGET` in config.js with **real targets per rep per month** — attainment %, pace, and leaderboard vs target become real numbers. Probably the highest-value single addition. |
| **`sales.visit`**, `sales.route`, `sales.route.plan` (+ `.line`), `visit.missed.reason`, `visit.stage` | Van-sales route planning & visit tracking | A "field execution" page: planned vs completed visits per rep, missed-visit reasons, route coverage vs orders. Connects sales results to street-level activity. |
| `sales.dues` (+ `.line`) | Custom dues/receivables model | Cross-check against `vt_overdue_amount`; may be the true source of the debt numbers. |
| `sales.partner` (+ `.line`), `partner.performance.wizard` | Custom partner performance | Investigate — may hold precomputed KPIs. |
| `trading.valuation` (+ `.line`) | Custom trading valuation | Investigate. |
| `product.salesperson.limit.line` | Per-rep product limits | Compliance view (who sells outside their allowed range). |
| `whatsapp.account/.template/.message` | WhatsApp Business integration | Future: automated alert delivery to reps/managers via WhatsApp. |

## 📦 Available if ever needed (not recommended now)

- **POS**: `pos.order`, `pos.order.line`, `pos.session`, `pos.payment` — if the
  POS channel should appear in the dashboard, this is where it lives.
- **Inventory**: `stock.quant` (on-hand), `stock.move(.line)`, `stock.lot`,
  `stock.warehouse.orderpoint` (min rules), `stock.valuation.layer` (stock value).
- **Purchasing**: `purchase.order(.line)`, `purchase.report`, `product.supplierinfo`.
- **Accounting depth**: `account.journal`, `account.payment.term` (credit terms
  per customer), `account.tax`, `account.analytic.*`, `account.invoice.report`.
- **Pricing**: `product.pricelist(.item)` — who gets which price.
- **CRM**: `crm.lead`, `crm.stage`, `loyalty.program/card` (they exist!).
- **HR**: `hr.employee`, `hr.attendance`, `hr.contract` — rep attendance vs
  sales performance someday.
- **Manufacturing**: `mrp.bom`, `mrp.production`, `mrp.workorder` — if own
  production ever needs a dashboard.

## Rules for every new sync (learned the hard way — see N8N_AUDIT.md)
1. Fetch by **`write_date` lookback** (48h), never "today only" — states must heal.
2. **`returnAll: true`**, never a row limit; paginate any Supabase reads.
3. Convert Odoo's `false` → `null` before upserting (int/text columns reject it).
4. Upsert with `on_conflict=<pk>`; FK parents (salespeople, customers, products)
   always upserted **before** children (orders, lines).
5. New table = PK + FKs + indexes + RLS policy (copy the pattern in
   `supabase/restructure.sql`) + entry in `docs/ARCHITECTURE.md`.
6. n8n computes nothing — aggregates live in the dashboard (or SQL views later).
