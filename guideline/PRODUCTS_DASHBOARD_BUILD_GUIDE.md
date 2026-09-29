# Products Dashboard — Build Guide (same Supabase, same numbers as Odoo)

This is a self-contained handoff for building a **new products dashboard** that reads the
**same Supabase** as the Dabboos Sales Command Center and produces numbers that reconcile
with **Odoo's Sales Analysis**. Follow the conventions here exactly — they are the whole
reason the numbers are trustworthy. (Source project this is distilled from: the Dabboos
dashboard; the removed page's details live in `docs/PRODUCTS_PAGE.md`.)

---

## 0. Golden rule
**A single wrong number destroys trust in the whole dashboard.** Every metric must be
**reproducible on a named Odoo screen**. Never mix bases (orders vs invoices, taxed vs
untaxed, raw vs UoM-normalized). When unsure, label the basis in the UI.

---

## 1. Architecture
```
Odoo  →  n8n (sync)  →  Supabase (Postgres + REST)  →  browser dashboard
```
- **Static, no build.** Plain HTML + vanilla JS + Chart.js from CDN. No framework, no bundler.
- The browser reads **Supabase REST** directly. n8n keeps the tables fresh (you do **not**
  build syncs for the new dashboard — they already exist; you only read).
- **RTL Arabic + English**, money in **IQD**, calendar anchored to **Asia/Baghdad**.

---

## 2. Connect to Supabase

```js
const SUPABASE_URL = "https://puqfldltipedlodwfyex.supabase.co";
// anon (public) key — safe in the browser. By itself it reads NOTHING:
// Row-Level Security requires a logged-in user's JWT on every read.
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB1cWZsZGx0aXBlZGxvZHdmeWV4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA5NDExODUsImV4cCI6MjA5NjUxNzE4NX0.4vUPTMBBDkHMQTfAr8R0hU7vwKxc969ORVhiO_VhVCc";
```

**REST pattern:** `GET {SUPABASE_URL}/rest/v1/{table}?select=...&{filters}`
**Headers:** `apikey: <anon>` and `Authorization: Bearer <JWT>`.

### ⚠️ Auth is required (RLS)
The tables have Row-Level Security: **the anon key alone returns nothing.** Every read needs a
**logged-in user's JWT** (Supabase Auth). The existing dashboard handles this in `auth.js`
(username → synthetic `@dabboos.app` email → Supabase Auth session → JWT attached to each
request). **Reuse that `auth.js` login flow** in the new project, or the reads will 401.
**Never put the `service_role` key in the browser** — that key is for n8n only.

### Pagination — Supabase caps every response at 1,000 rows
You **must** page through. Copy this helper:
```js
async function sbGetAll(pathAndQuery, headers) {           // headers must include apikey + Bearer JWT
  const PAGE = 1000, sep = pathAndQuery.includes("?") ? "&" : "?";
  const url = o => `${SUPABASE_URL}/rest/v1/${pathAndQuery}${sep}limit=${PAGE}&offset=${o}`;
  const first = await fetch(url(0), { headers: { ...headers, Prefer: "count=exact" } });
  const out = await first.json();
  const total = Number((first.headers.get("content-range") || "").split("/")[1]);
  if (out.length === PAGE && total > PAGE) {
    const offs = []; for (let o = PAGE; o < total; o += PAGE) offs.push(o);
    const more = await Promise.all(offs.map(o => fetch(url(o), { headers }).then(r => r.json())));
    more.forEach(rows => out.push(...rows));
  }
  return out;                                              // ALWAYS add a unique sort tiebreaker (e.g. &order=line_id.desc)
}
```
> Always sort by a **unique** column (`&order=<pk>.desc`) — parallel pages on a non-unique
> sort drop/duplicate rows.

---

## 3. Data model (the tables you read)

| Table | PK | Key fields | Notes |
|---|---|---|---|
| **`dashboard_products`** | `product_id` | `name, sku, category, brand, cost, list_price, uom, active` | `cost` = Odoo `standard_price`. `uom` = product's unit (e.g. "كارتونة 6 وحدات"). |
| **`dashboard_stock`** | `product_id` | `on_hand_qty, stock_value, updated_at` | On-hand = Odoo `qty_available` (all internal locations, product's UoM). Live-ish snapshot (2h). |
| **`dashboard_order_lines`** | `line_id` | `product_id, qty, price_subtotal, price_total, date_order, partner_id, city, gov, salesperson, user_id, state` | **Sourced from Odoo `sale.report`** (see §4). `order_id` is null. |
| **`dashboard_customers`** | `partner_id` | `complete_name, governorate, city, salesperson, user_id, credit…` | Customer master / identity + geography. |
| `dashboard_orders` | `order_id` | `date_order, partner_id, amount_total, state, city…` | Order headers (for cross-checks). |

---

## 4. THE most important rule: quantities come from `sale.report`

`dashboard_order_lines.qty` is **UoM-normalized** because the sync sources it from Odoo's
**`sale.report`** (Sales Analysis), **not** `sale.order.line`:

- `sale.order.line.product_uom_qty` = **raw** qty in the **line's** unit → summing mixes
  cartons + pieces (garbage; e.g. one product summed to 1,061 instead of 303.5).
- **`sale.report.product_uom_qty` = Odoo's "Qty Ordered"** = normalized to the **product's
  reference unit** → matches Odoo exactly (303.5 cartons). And `sale.report.date` is the
  **real order date**.

So in the new dashboard: **`qty` is already correct and matches Odoo. Do not re-derive it.**
Quantities are in the **product's UoM** and can be **fractional** (303.5 cartons). `sale.report`
has **no `order_id`** and **no `write_date`** (it's a view) — that's why lines carry `order_id = null`
and why the sync tops up nightly by a rolling date window rather than by "recently changed".

---

## 5. Core conventions (match these or numbers drift)

1. **Confirmed sales only:** `state in ('sale','done')`. Quotations (`draft`,`sent`) and `cancel` never count.
2. **Baghdad calendar:** bucket days in **Asia/Baghdad**, NOT UTC. Week starts **Saturday**.
   Use this helper on any timestamp before comparing dates:
   ```js
   function bagDay(s) {                       // "2026-06-14 20:21:51+00" -> "2026-06-14" (Baghdad)
     if (!s) return "";
     const d = new Date(String(s).includes("T") ? s : String(s).replace(" ", "T") + "Z");
     return isNaN(d) ? String(s).slice(0,10) : d.toLocaleDateString("en-CA", { timeZone: "Asia/Baghdad" });
   }
   ```
3. **Quantity = normalized** (from `sale.report`); never sum raw `sale.order.line`.
4. **Date field = `date_order`** (the real order date), bucketed in Baghdad.
5. **Revenue = `price_subtotal`** (untaxed) — matches Odoo **"Untaxed Total"**. `price_total` = taxed.
6. **Margin = `revenue − cost × qty`** (gross; `cost` = product `standard_price`). Close to Odoo's
   Margin measure (Odoo uses cost-at-sale; the DB uses current `standard_price`).
7. **Exclude the fixtures category** `عارضات و استاندات` (display racks/stands — not products):
   filter out `p.category ~ 'عارضات|استاندات'`.
8. **Escape every DB string** (`esc`) before putting it in `innerHTML` (product/customer/city
   names are user-controlled → stored-XSS risk). Chart.js `<canvas>` labels are safe.
9. **De-dupe by primary key** after loading (the sync can emit duplicates).
10. **Money = IQD**; compact large numbers to K/M; never hardcode the currency symbol.

---

## 6. The metrics (formulas)

Let `L` = confirmed lines in the selected **period** (Baghdad `date_order`), fixtures excluded.

| Metric | Formula |
|---|---|
| **Units sold** | `Σ L.qty` |
| **Units in stock** | `Σ dashboard_stock.on_hand_qty` |
| **Revenue** | `Σ L.price_subtotal` |
| **Margin** | `Σ L.price_subtotal − Σ (L.qty × product.cost)` |
| **Mix %** (per product) | `product revenue ÷ total revenue × 100` |
| **Velocity** (per product) | units in trailing 90d ÷ 3 = units/month |
| **Last sale** (per product) | `max(date_order)` over confirmed lines |
| **Frozen** (per product) | `on_hand_qty > 0` **AND** (`last_sale` is null **OR** `last_sale` older than N days; N = 30/60/90, default 60) |
| **Drill: top customers** (per product) | group that product's lines by `partner_id` → `Σ qty, Σ price_subtotal` |
| **Drill: top cities** (per product) | group that product's lines by `gov` |

Reusable, unit-tested implementations of these already exist in
**`assets/js/products-calc.js`** (`classifyFrozen`, `productVelocity`, `productMarkets`,
`lineMargin`, `aggregateLines`) with tests in `test/products.test.js` — **copy that file**.

---

## 7. Verify every number against Odoo

**Tool:** Sales → Reporting → **Sales (Sales Analysis pivot)**.
**Always:** filter **Sales Orders** (confirmed); **Measure = Qty Ordered** (for units) or
**Untaxed Total** (for revenue) or **Margin**; exclude the fixtures category.

⚠️ **The #1 trap — the end date.** Odoo's "Order Date is between … and `06/30/2026 00:00:00`"
**drops all of June 30.** Always set the end to the **next day** (`07/01/2026`) or `23:59:59`.
(This alone caused an entire "127-unit gap" that was purely a filter mistake.)

| Dashboard number | Odoo check |
|---|---|
| Units sold / per-product units | Qty Ordered grand total / by Product |
| Revenue | Untaxed Total |
| Margin | Margin measure |
| Units in stock / on-hand | Inventory → Products → **On Hand** (product's unit, all locations) |
| Frozen | On Hand > 0 **and** newest order in Sales > N days ago |
| Drill top customers | Group By → Customer, Qty Ordered |
| Drill top cities | Group By → Customer ▸ State, Qty Ordered |

**Verification SQL** (Supabase = what the page should compute):
```sql
select p.sku, p.name,
       round(sum(l.qty), 1)                                        as units,
       round(sum(l.price_subtotal))                                as revenue,
       round(sum(l.price_subtotal) - sum(l.qty * coalesce(p.cost,0))) as margin
from dashboard_order_lines l
join dashboard_products p on p.product_id = l.product_id
where date(l.date_order at time zone 'Asia/Baghdad') between '2026-06-01' and '2026-06-30'
  and l.state in ('sale','done')
  and coalesce(p.category,'') !~ 'عارضات|استاندات'
group by p.sku, p.name order by units desc;
```

---

## 8. How the data stays fresh (you rely on this; you don't build it)
Existing n8n workflows already populate the tables:
- **Products + Stock** — every 2h from `product.product` (catalog + `qty_available` + cost).
- **Order-lines full backfill** — one-time, month-chunked from **`sale.report`** (run after truncate).
- **Order-lines nightly top-up** — 02:00, upserts the last ~10 days from `sale.report`.
  (`sale.report` has no `write_date`, so cancellations / edits to *old* orders are caught by an
  occasional full re-backfill, not the nightly.)

The new dashboard just **reads** these tables.

---

## 9. Recommended architecture for the NEW build (important)
The removed page loaded **~100k raw lines into the browser** → slow, and it hammered Supabase
(~100 paginated requests) which slowed the whole project. **Do not repeat that.** Instead:

- **Aggregate server-side.** Create Postgres **RPCs / views** that return the *summaries* the UI
  needs (frozen list, top products for a window+filters, per-product customer/city drill), so the
  browser downloads **kilobytes, not megabytes**. Filters (period, salesperson, city, customer)
  become RPC parameters. This keeps the page fast at any history depth.
- Keep the pure-calc functions only for small client-side shaping; do the heavy sums in SQL.

---

## 10. Checklist for the new session
- [ ] Reuse `auth.js` login (RLS needs a JWT; anon alone reads nothing).
- [ ] Read: `dashboard_products`, `dashboard_stock`, `dashboard_order_lines`, `dashboard_customers`.
- [ ] Treat `qty` as **already UoM-normalized** (matches Odoo Qty Ordered); it can be fractional.
- [ ] Filter **confirmed** (`sale`/`done`), bucket dates in **Baghdad**, use `date_order`.
- [ ] Exclude `عارضات|استاندات`. Revenue = `price_subtotal`. Escape DB strings.
- [ ] Verify every number in Odoo Sales Analysis with the **next-day end date**.
- [ ] Prefer **server-side aggregation** over loading all lines.
- [ ] Copy `assets/js/products-calc.js` + tests; reuse `sbGetAll` + `bagDay`.
