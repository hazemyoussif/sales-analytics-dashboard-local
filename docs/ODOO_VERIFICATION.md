# Verifying dashboard numbers in Odoo — the company guide

Every number on the dashboard is computed from rows mirrored 1:1 from Odoo,
so every number can be reproduced on an Odoo screen — **if you ask Odoo the
same question**. Most "wrong number" reports are two screens asking
different questions. This guide gives, per page: what the number is made
of, and the exact Odoo recipe that reproduces it.

## The five golden comparison rules

1. **Totals are TAX-INCLUSIVE** (`amount_total`). In Odoo pivots pick the
   **Total** measure, never *Untaxed Total*.
2. **"Confirmed" = Sales Order + Done only.** Quotations (draft/sent) and
   Cancelled never count as sales — company policy. When Odoo shows a
   mixed list, group by Status and read only the matching groups.
3. **Days are Baghdad calendar days, weeks start SATURDAY.** Odoo's
   built-in "This Week" filters are usually Monday-based — use explicit
   date ranges (Sat → Fri) when comparing weeks.
4. **Dates: orders compare by ORDER DATE** (تاريخ الطلب), not Create Date;
   invoices by Invoice Date; payments by Payment Date. Check which chip
   is active in Odoo before comparing.
5. **Freshness:** Odoo → dashboard takes up to ~20 min (sync) + ~3–7 min
   (page refresh cycle). The 🔄 button re-pulls everything instantly from
   the mirror. Never compare against a screenshot older than that.

---

## 1 · Cities & Governorates (regions.html)

**What the numbers are:** confirmed orders (rule 2), tax-inclusive value
(rule 1), bucketed by order date (rule 3/4) in the chosen range. Each
order is located by a preference chain: the customer's **State field in
Odoo** (`res.partner.state_id`) → else the customer's city text matched
against a normalization dictionary → else the order's own city snapshot →
else "no city" (never guessed). The orange banner lists unrecognized city
spellings — that's the data-entry worklist.

**Odoo recipe (totals per governorate):**
Sales → Reporting → **Sales** → pivot view →
filters: *Order Date = the range*, statuses *Sales Order + Done* →
Rows: **Customer > State** → Measures: **Count + Total** (not Untaxed).

**Odoo recipe (one governorate / one city):**
Sales → Orders → filter *Order Date range* + Status → Add Custom Filter →
*Customer > State = …* (or *Customer > City contains …*) → the list footer
Total ↔ the dashboard row.

**Legitimate differences:** customers with an EMPTY State in Odoo land in
Odoo's "None" row but the dashboard often rescues them via the city
dictionary; and the dashboard merges spelling variants ("الحلة"/"حلة")
that Odoo lists separately. Fixing the State field on the customer form
closes both permanently.

---

## 2 · Salespeople — week over week (salespeople.html)

**What the numbers are:** confirmed orders only, tax-inclusive, per rep
(the salesperson on the sale order), bucketed by order date. "This week"
= Saturday → today; "last week" = the previous Sat→Fri; the sparkline is
12 such weeks; the month figures are calendar months. The range KPIs
follow the date filter.

**Odoo recipe:**
Sales → Orders → Add Custom Filter: *Order Date ≥ last Saturday* (and
*≤ Friday* for a closed week) → filter/group Status = Sales Order + Done →
**Group by Salesperson** → each group's count + Total ↔ the rep's row.
For months: filter *Order Date = the month*, same grouping.

**Trap to avoid:** Odoo's "This Week" quick-filter starts Monday; the
dashboard's week starts Saturday (Iraq). Always use explicit dates.

---

## 3 · Daily Collections (collections.html)

**What the numbers are:** customer payments from `account.payment`, on
this exact basis:
- **Received (مستلَم)** = state Paid; **In transit (قيد التحويل)** =
  state In Process — BOTH count as collected (the courier already took
  the customer's money).
- **Cancelled and Rejected are never money** (stored, shown as their own
  rows on the Overview, excluded from every sum).
- **Refunds count NEGATIVE** (outbound customer payments) — sums net
  exactly like the signed Amount column in Odoo.
- Rep = the payment's salesperson field; day = Payment Date (Baghdad).
- "Collected ÷ sales" divides the period's payments by the same period's
  confirmed order value (two bases, labeled).

**Odoo recipe (a day / a period):**
Accounting → Customer Payments → filter *Payment Date = day or range* →
**Group by Status**: dashboard-collected = **Paid + In Process** group
sums (signed); ignore Cancelled/Rejected groups.
Per rep: additionally **Group by Salesperson** (المندوب) — group sums ↔
the rep grid/table.
Grand-total check: the Odoo list footer (ALL statuses) ↔ the Overview
cash card's "الإجمالي شاملاً المرفوضة والملغاة" line.

---

## 4 · Customer Debt (debt.html)

**What the numbers are:** open receivable JOURNAL ITEMS (`state = posted`
and residual ≠ 0, **any date** — an unpaid 2024 invoice is still debt).
Per customer:
- **إجمالي الذمة (Total open)** = Σ residuals (credits/unmatched payments
  subtract),
- **المتأخر (Overdue)** = the slice with due date before today (Baghdad),
- days late = age of the oldest overdue debit line.
Customer name/governorate/rep come from the customer master; the rep on
the invoice line is the fallback. "New risk" is the only order-based KPI:
this month's confirmed orders auto-scored critical (unpaid overdue,
credit over limit, DSO > 60 — from the customer form's own fields).

**Odoo recipe:**
Accounting → Reporting → **Aged Receivable** (as of today):
- report grand Total ↔ debt page "إجمالي الدين" KPI,
- per customer: row Total ↔ إجمالي الذمة · sum of the LATE columns
  (1-30…Older) ↔ المتأخر · the **At Date** column ↔ غير مستحق بعد,
- drill any dispute: the customer's **Partner Ledger** — every open item
  there is literally a row in the mirror, same amount and due date.

---

## When a number still differs after the right recipe

1. Press 🔄 on the dashboard (fresh pull) and re-check the Odoo filter
   chips (date type + status + measure).
2. If the dashboard count is HIGHER: suspect records deleted in Odoo —
   run the RECONCILE workflow (removes mirror ghosts, lists what it
   deleted).
3. If still different: note the exact screen, filters, and both numbers,
   and escalate — a genuine basis question is a docs/METRICS.md decision,
   not a bug hunt.
