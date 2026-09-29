# Odoo reconciliation runbook — Overview page

Follow top to bottom. Every check is the same shape:
**do this in Odoo → do this in Supabase → the two numbers must match.**

First run ≈ 45 minutes. Later runs ≈ 15.

Fill these in once and reuse them everywhere below:

| Placeholder | Where to get it | Your value |
|---|---|---|
| `«FROM»` | date you are testing, start | `2026-07-01` |
| `«TO»` | date you are testing, end | `2026-07-31` |
| `«DATE_FROM»` | health strip, first date | |
| `«DATE_TO»` | health strip, second date | |

Test **one month**, not the whole range. A mismatch on a 4-month total tells you nothing
about where it is.

---

## Setup — do this once

**S1.** Open Overview. **Clear the Governorate / Rep / Category / Customer filters.**
Set From = `«FROM»`, To = `«TO»`.

**S2.** Read the health strip at the top. Write down `«DATE_FROM»` and `«DATE_TO»` in the
table above.

**S3.** Open `accounting.aldabboos.com` → **Invoicing → Reporting → Invoice Analysis**.

**S4.** **Click the × on every filter facet in the search bar.** All of them. Odoo's
defaults are the number-one cause of a fake mismatch.

**S5.** Click the **pivot** icon (top right).

**S6.** **Filters → Add Custom Filter** → paste, with your dates:

```
[("state","=","posted"),
 ("move_type","in",["out_invoice","out_refund"]),
 ("invoice_date",">=","«FROM»"),
 ("invoice_date","<=","«TO»")]
```

> ### ⚠️ `state` here is the invoice status, NOT the governorate
>
> `account.invoice.report` has two different fields and the labels do not help:
>
> | Technical name | UI label | Meaning |
> |---|---|---|
> | `state` | **Status** | `draft` / `posted` / `cancel` — this is what the domain above filters |
> | `state_id` | **State** | the governorate (بغداد, البصرة …), synced to `gov` |
>
> **Paste the domain as text** and it is correct as written. **Build the filter by picking
> a field labelled "State"** and you have just filtered by governorate instead of status —
> which silently drops most of your data and makes every number below wrong.
>
> If you build it through the picker, choose **Status**, not State. Then confirm: switch the
> Add Custom Filter dialog to its code/domain view and check it reads `("state","=","posted")`.

**S7.** **Measures ▾** → tick **Untaxed Total** and **Product Quantity**. Untick everything
else.

**S8.** Open the Supabase SQL editor in a second tab.

Keep this pivot open — Checks 0, 2, 3 and 4 all reuse it.

---

## Check 0 — Row count (gate: do not skip)

**0.1** Odoo: switch to **list view**. Read the count in the pager, e.g. `1-80 / 33806`.

**0.2** Supabase:

```sql
select count(*)
from public.dashboard_invoice_lines
where state = 'posted'
  and move_type in ('out_invoice','out_refund')
  and invoice_date between '«FROM»' and '«TO»';
```

**0.3** Odoo: switch back to **pivot** view.

✅ **Expect:** the two counts are identical.

❌ **If not:**

| | Do this |
|---|---|
| Supabase **lower** | The sync dropped rows. Re-run the invoice-lines backfill for this month. |
| Supabase **higher** | An invoice was cancelled in Odoo after the sync. Re-run the backfill for this month. |

**Stop here until they match.** Every check below assumes they do.

---

## Check 1 — Never sold

### 1.1 Get the full list

Supabase:

```sql
select p.product_id, p.sku, p.name, p.category,
       coalesce(s.on_hand_qty, 0)  as on_hand,
       coalesce(s.stock_value, 0)  as stock_value
from public.dashboard_products p
left join public.dashboard_stock s on s.product_id = p.product_id
where coalesce(p.category, '') !~ 'عارضات|استاندات'
  and not exists (select 1 from public.dashboard_excluded_products x
                   where x.product_id = p.product_id)
  and not exists (select 1 from public.dashboard_invoice_lines l
                   where l.product_id = p.product_id
                     and l.state = 'posted'
                     and l.move_type in ('out_invoice','out_refund'))
order by stock_value desc;
```

### 1.2 Match it to the screen

✅ **Expect:** row count and `sum(stock_value)` = the footer under the chart
(`N SKU · <value>`), and the first 15 rows = the 15 bars, in order.

❌ **If not:** the bug is in the page, not in Odoo. Stop and report it.
❌ **If the list is huge:** you left a filter on. Go back to **S1**. With a governorate
selected this section means "never sold **in that governorate**".

### 1.3 Export A from Odoo — everything ever invoiced

**a.** Invoice Analysis → **remove the date filter completely**. Custom filter:

```
[("state","=","posted"),("move_type","in",["out_invoice","out_refund"])]
```

**b.** Group rows by **Product**.
**c.** ⚙️ → **Download xlsx**. Call it `A_ever.xlsx`.

### 1.4 Export B from Odoo — invoiced inside the synced window

**a.** Same, plus one clause:

```
[("state","=","posted"),("move_type","in",["out_invoice","out_refund"]),
 ("invoice_date",">=","«DATE_FROM»")]
```

**b.** Group rows by **Product** → **Download xlsx**. Call it `B_window.xlsx`.

### 1.5 Cross the three lists

For each product in the 1.1 list, look it up in both exports:

| Found in | Verdict | Action |
|---|---|---|
| Neither | Genuinely never sold | ✅ none |
| **A only** | Sold before `«DATE_FROM»` | ✅ correct given the backfill. To make it disappear, extend the backfill |
| **B** | Odoo invoiced it inside the window, Supabase never got the line | ❌ **sync gap — investigate this product** |

### 1.6 Spot-check the stock figures

For the **top 3** rows only: Odoo → **Inventory → Products → the product**.

✅ **Expect:** `On Hand` = the query's `on_hand`, and the product is **not archived**.

❌ **Archived in Odoo but present here** → stale products sync; re-run it.
❌ **On-hand matches, value looks off** → expected. `stock_value` is `on_hand ×
standard_price`, not Odoo's valuation layers.

---

## Check 2 — Top products

### 2.1 Get the full list

Supabase:

```sql
select p.sku, p.name,
       round(sum(l.qty))            as units,
       round(sum(l.price_subtotal)) as revenue
from public.dashboard_invoice_lines l
join public.dashboard_products p on p.product_id = l.product_id
where l.state = 'posted'
  and l.move_type in ('out_invoice','out_refund')
  and l.invoice_date between '«FROM»' and '«TO»'
  and coalesce(p.category, '') !~ 'عارضات|استاندات'
  and not exists (select 1 from public.dashboard_excluded_products x
                   where x.product_id = l.product_id)
group by p.sku, p.name
having sum(l.price_subtotal) > 0
order by revenue desc
limit 20;
```

✅ **Expect:** the first 12 rows = the 12 bars on screen, same order, same amounts.

### 2.2 Odoo side

**a.** Back in the setup pivot (dates = `«FROM»`/`«TO»`).
**b.** **Group rows by Product**.
**c.** Click the **Untaxed Total** header to sort descending.

### 2.3 Strike out three kinds of row from Odoo's list before comparing

1. the **`DISC`** product
2. anything in **`عارضات`** or **`استاندات`**
3. any product with a **negative** total

### 2.4 Compare the top 12 — **by SKU, not by name**

✅ **Expect:** same 12 SKUs, same order, same amounts.

❌ **If not:**

| Symptom | Do this |
|---|---|
| Same 12, different order | Credit note on a period boundary. Check the two swapped products on `«FROM»` and `«TO»` exactly |
| High in Odoo, missing from chart | Run the missing-products query in **Appendix A3** |
| In chart, missing from Odoo's top | You matched on name. Re-check by SKU |
| One product's amount differs | Dashboard **Products page → that product** → compare monthly trend vs Odoo grouped by **Product × Invoice Date (Month)** |

---

## Check 3 — Categories

### 3.1 Get the full list

Supabase:

```sql
select coalesce(p.category, l.category, '—') as category,
       round(sum(l.price_subtotal))          as revenue
from public.dashboard_invoice_lines l
join public.dashboard_products p on p.product_id = l.product_id
where l.state = 'posted'
  and l.move_type in ('out_invoice','out_refund')
  and l.invoice_date between '«FROM»' and '«TO»'
  and coalesce(p.category, '') !~ 'عارضات|استاندات'
  and not exists (select 1 from public.dashboard_excluded_products x
                   where x.product_id = l.product_id)
group by 1
order by revenue desc;
```

✅ **Expect:** the top 10 rows = the 10 bars.

⚠️ The bars will **not** sum to the Revenue tile if there are more than 10 categories. That
is truncation, not a gap.

### 3.2 Odoo side

Setup pivot → **Group rows by Product Category**.

### 3.3 Compare, allowing for three known differences

| Difference | Expected? |
|---|---|
| `عارضات` / `استاندات` in Odoo, absent from chart | ✅ by design |
| One category lower on the dashboard by exactly the `DISC` amount (Appendix A2) | ✅ by design — that is the category the `DISC` pseudo-product sits in |
| A category lower with no explanation | ❌ run the missing-products query, **Appendix A3** |

✅ **Expect, per category:** `Odoo total − DISC (if it is in that category) = dashboard bar`.

### 3.4 One rule difference to be aware of

This chart includes **net-negative** products; Top products excludes them. So a category
holding a heavily-returned product reads lower here than the sum of its visible products in
Check 2. Both are correct; they are different rules.

---

## Check 4 — Products (bottom table)

Units and Revenue are already proven by Checks 0–2. Verify the three columns that come from
somewhere else.

### 4.1 Pick five rows to check — not all sixty

1. the top row
2. one from the middle
3. one with an old **Last sale** date
4. one with **On hand = 0**
5. one at the **A/B** boundary in the ABC column

### 4.2 On hand → Inventory, not Invoice Analysis

For each of the five: Odoo → **Inventory → Products → the product → On Hand**.

✅ **Expect:** exact match.
❌ **If not:** stale products/stock sync (runs every 2h). Re-run it and recheck.

### 4.3 Last sale → Odoo with the date filter removed

For each of the five: Invoice Analysis, **no date filter**, filter to that product, group by
**Invoice Date (Month)**, read the latest.

✅ **Expect:** matches the Last sale column.

⚠️ Two things that are correct but look wrong:
- Last sale **ignores your period filter** — it is all-time. A row can show `units 0` for
  July with a Last sale in April.
- Last sale **counts credit notes**. If a date looks surprisingly recent, open that
  document in Odoo — if it is a credit note, the product's last real *sale* is older.

### 4.4 ABC → reproduce it in SQL

```sql
with r as (
  select p.sku, p.name, sum(l.price_subtotal) as revenue
  from public.dashboard_invoice_lines l
  join public.dashboard_products p on p.product_id = l.product_id
  where l.state = 'posted'
    and l.move_type in ('out_invoice','out_refund')
    and l.invoice_date between '«FROM»' and '«TO»'
    and coalesce(p.category, '') !~ 'عارضات|استاندات'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = l.product_id)
  group by p.sku, p.name
  having sum(l.price_subtotal) > 0
),
c as (
  select r.*,
         (sum(revenue) over (order by revenue desc
                             rows between unbounded preceding and 1 preceding))
           / sum(revenue) over () as share_before
  from r
)
select sku, name, round(revenue) as revenue,
       case when coalesce(share_before, 0) < 0.80 then 'A'
            when coalesce(share_before, 0) < 0.95 then 'B'
            else 'C' end as abc
from c
order by revenue desc;
```

✅ **Expect:** the five sampled rows carry the same letter as the screen.

⚠️ ABC is computed over **every** product in the filter, not the 60 on screen — you cannot
reproduce it from the visible table.
⚠️ The class uses the cumulative share **before** the row is added, so the product that
crosses 80% is still an **A**. Recompute it in Excel the obvious way and your boundary rows
will disagree by one. That is the spreadsheet, not the dashboard.

---

## Appendix A — the four tiles

Only needed when a table check points at a total. Same pivot as Setup.

### A1 — Units

Read **Product Quantity**, ungrouped. Apply the A2/A3 subtractions below.

⚠️ Fractional quantities (`303.5`) are correct — they are cartons, the product's own UoM.
⚠️ Units are **net of returns** on both sides.

### A2 — Revenue ladder

| # | Figure | How |
|---|---|---|
| **A** | Odoo untaxed total | pivot, no grouping, **Untaxed Total** |
| **B** | Invoice discount | group by **Product** → the `DISC` / `DISCOUNT` row (negative) |
| **C** | Fixtures | group by **Product Category** → sum `عارضات` + `استاندات` |
| **D** | **A − B − C** | = the **Revenue tile** |

✅ **Expect:** the adjustments strip under the tiles shows **B** by name and ends `= (Odoo)`.

### A3 — Missing products (run this whenever a total is short)

```sql
select l.product_id, round(sum(l.price_subtotal)) as missing_revenue, count(*) as lines
from public.dashboard_invoice_lines l
left join public.dashboard_products p on p.product_id = l.product_id
where p.product_id is null
  and l.invoice_date between '«FROM»' and '«TO»'
group by l.product_id
order by 2 desc;
```

Any row here contributes **zero** to every product table, silently. Cause: archived in Odoo,
or the products sync has not run since the product started selling. Fix: re-run the products
sync.

### A4 — Frozen capital

Not from Invoice Analysis. Verify **per product**, not in total:

**a.** Frozen capital page → take the top 5.
**b.** Odoo → Inventory → Products → On Hand must match.
**c.** Invoice Analysis, no date filter, that product, grouped by month → the latest month
must be **more than 60 days before `«DATE_TO»`**.

⚠️ The 60 days count from `«DATE_TO»`, **not from today**.
⚠️ `stock_value` is approximate. A few percent off Odoo's Valuation report is expected.

---

## Appendix B — symptom → cause

| Symptom | Cause |
|---|---|
| Odoo **far** lower than the dashboard, on every check | You filtered on **State** (governorate) instead of **Status** — see the callout after **S6** |
| Odoo higher by a large round amount | Credit notes missing from your Odoo filter — redo **S6** |
| Odoo higher by ~0.8% | The `DISC` line — **A2 step B** |
| Odoo higher, no single cause | Products missing from `dashboard_products` — **A3** |
| Counts match, money does not | You measured **Total** instead of **Untaxed Total** — redo **S7** |
| Dashboard higher than Odoo | Invoice cancelled in Odoo after the sync — re-run the backfill |
| Off by one day of sales | Both bounds are **inclusive** on both sides |
| Bars do not sum to the tile | Charts are truncated to 15 / 12 / 10 rows — use the SQL |
| "But we definitely sold that" | Sold before `«DATE_FROM»` — **1.5, export A** |
| Every page is wrong | Check `«DATE_TO»` first — a stalled sync explains all of it |

---

## When it ties out

Record the month, the four tile values and the Odoo figures. Next month's reconciliation is
then a diff against a known-good baseline instead of a fresh investigation.
