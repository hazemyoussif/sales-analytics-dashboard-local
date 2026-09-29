# Odoo `account.invoice.report` — verified field list

**Verified:** 2026-08-01, by API probe through n8n (`n8n/odoo-introspect.workflow.json`).
**Odoo host:** `accounting.aldabboos.com`
**Field count:** 32

## Assumption check

| Assumption | Confirmed | Actual |
|---|---|---|
| `quantity` exists | ✅ | present; fractional values observed (`0.4`) |
| `out_refund` rows have negative `quantity` | ✅ | `[-2, -1, -1, -1, -1]` |
| `out_refund` rows have negative `price_subtotal` | ✅ | `[-88000, -21500, -9750, -42000, -9750]` |
| `out_invoice` rows are positive | ✅ | `[6, 1, 1, 1, 0.4]` |
| `move_id` exists | ✅ | basket / "bought together" analysis is possible |
| `invoice_user_id` exists | ✅ | salesperson |
| `commercial_partner_id` exists | ✅ | |
| `payment_state` exists | ✅ | |

**Verdict: credit notes are negative.** The sync stores them as-is and every sum nets
returns automatically. No sign flipping anywhere.

## Full field list

```
account_id              company_currency_id     invoice_date_due    price_average
city_id                 company_id              invoice_user_id     price_margin
commercial_partner_id   country_id              journal_id          price_subtotal
currency_id             display_name            move_id             price_subtotal_currency
fiscal_position_id      id                      move_type           price_total
inventory_value         invoice_date            partner_id          product_brand_id
product_categ_id        product_id              product_uom_id      quantity
state                   state_id                team_id
```

## Three fields that change the design

### 1. `price_margin` — margin stops being an approximation

The design assumed margin had to be derived as `revenue − qty × current standard_price`,
which is wrong for historical periods because `standard_price` moves over time. That caveat
was going to have to appear in the UI next to every margin figure.

Odoo computes margin itself and exposes it here. We store it and the caveat disappears.

**Verified on 33,806 real July 2026 rows:**

```
price_margin = price_subtotal + inventory_value      100.00% of rows (33,806/33,806)
price_margin = price_subtotal − inventory_value        0.00% of rows
```

The identity holds with a **plus**, not a minus, because Odoo stores `inventory_value` as a
**negative** number (32,092 negative, 372 positive, 342 zero). It is a signed cost, not an
absolute one.

Getting this backwards would have doubled every margin figure — e.g. line 1332206:
`subtotal 48,000`, `inventory_value −26,460`, `margin 21,540`. Subtracting gives 74,460
instead. **Margin is exact and can be summed directly.**

### 2. `product_categ_id` and `product_brand_id` — no join needed

Both come down on the invoice line itself. This matters because
`dashboard_products.brand` is **hardcoded to `null`** by the existing products sync, so
sourcing brand from that table would have produced empty charts with no error.

**Measured on July 2026:** brand is set on **64.4%** of lines — 132 distinct brands,
896M IQD of revenue branded against 490M unbranded. Usable, but a third of the money has no
brand, so every brand breakdown must carry an explicit **"unbranded"** bucket. Silently
dropping those rows would make brand totals disagree with headline revenue by 35%.

### 3. `state_id` / `city_id` / `country_id` — geography on the line

Geography no longer requires the `dashboard_customers` join. In an Iraqi Odoo, `state_id` is
the governorate.

**Measured on July 2026 — `gov` wins outright:**

| Field | Fill rate | Verdict |
|---|---|---|
| `gov` (from `state_id`) | **100%** — 17 governorates (بغداد, البصرة, اربيل, الموصل, كركوك, واسط, ذي قار, دهوك …) | use this |
| `city` (from `city_id`) | **35.4%** — 21,843 of 33,806 rows blank | do not build on it |

All geographic analysis — coverage gaps, regional mix, price variance by region — uses
**governorate**. City appears only as an optional detail on a drill-down, never as a
dimension anything is grouped by, because two thirds of it is missing.

## n8n execution gotcha

`Sample Invoices` was set to `limit: 5` but returned **25 rows**. It is not a data problem:
the node received 5 input items from `Sample Refunds` and **ran once per item**, 5 × 5 = 25.

This is why the existing sale.report backfill has `After 2026-04` / `After 2026-05` nodes
that collapse to a single item between month fetches. **Every Odoo node in the sync
workflows must be preceded by a collapse to one item**, or each will run N times and
multiply both load and cost.

## July 2026 baseline (33,806 rows)

The first real load, used as the reference for everything downstream.

| | |
|---|---|
| Rows | 33,806 |
| Date range | 2026-07-01 .. 2026-07-31 |
| Distinct products | 435 |
| Distinct customers | 1,896 |
| Distinct invoices (`move_id`) | 3,306 |
| Units (net of returns) | 40,132 |
| Revenue (untaxed, net) | 1,385,614,250 IQD |
| Margin | 621,373,512 IQD (**44.8%**) |
| Credit notes | 397 rows, −13,333,250 IQD |

**A 44.8% gross margin is high for distribution.** It is internally consistent — every row
satisfies the margin identity — but it should be sanity-checked by someone who knows the
business before it goes in front of management. If Odoo's `inventory_value` is not the true
landed cost, margin will read high across the board.

### Known data anomaly: 30 credit notes with positive revenue

30 of the 397 credit-note rows have negative `qty` but **positive** `price_subtotal`
(e.g. line 1344310: `qty −1`, `subtotal +2,000`, `inventory_value 0`). They inflate revenue
by a few thousand IQD out of 1.39 billion — immaterial, and not worth special handling.

Recorded because it will be spotted eventually, and it is an Odoo data-entry artefact rather
than a sync bug: the sync stores exactly what the report returns.

## Fill rates that shape the UI

| Field | Fill | Consequence |
|---|---|---|
| `price_margin`, `inventory_value` | 100% | margin is exact everywhere |
| `category`, `gov`, `salesperson`, `payment_state`, `move_id` | 100% | safe to group by |
| `brand` | 64.4% | needs an explicit "unbranded" bucket |
| `city` | 35.4% | drill-down detail only, never a grouping dimension |
