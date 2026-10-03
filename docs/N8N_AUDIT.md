# n8n workflow audit — "Dabboos Sync v2" (2026-07-08)

Audit of the n8n workflow (orders + payments + debt sync) against the live
Supabase data. Findings ranked by impact on **number accuracy**. Each fix is
something you change **inside n8n**; nothing here needs a dashboard deploy.

---

## 1. 🔴 CRITICAL — "Read Orders Window" is silently truncated to 1,000 rows

**Node:** `Read Orders Window` (`…dashboard_orders?…&limit=5000`).
Supabase caps every PostgREST response at **1,000 rows** regardless of a
larger `limit`. The 95-day window already holds **2,988 rows**, so the node
gets only the newest 1,000 — and every snapshot computed from it
(`summary`, `trends`, `reps`, `regions`, `salespeople`) undercounts.

**Proof (2026-07-08):** `summary.month.orders = 964`, but the real July
confirmed count in the table is **986**. The error grows every day.

Same problem waiting in `Read Payments Window1` (`limit=20000` → still 1,000;
95-day window currently ~818 rows, so it works *today* but will silently
break as volume grows).

**Fix:** paginate. In each read node, loop with `offset` (or use the
`Range` header) until fewer than 1,000 rows return. Easiest in n8n: replace
the single HTTP node with a small Code node that loops:

```js
const base = $('Config3').first().json.supabaseUrl, key = $('Config3').first().json.serviceKey;
const out = [];
for (let offset = 0; ; offset += 1000) {
  const res = await this.helpers.httpRequest({
    url: `${base}/rest/v1/dashboard_orders?select=…&date_order=gte.…&order=date_order.desc&limit=1000&offset=${offset}`,
    headers: { apikey: key, Authorization: `Bearer ${key}` }, json: true });
  out.push(...res);
  if (res.length < 1000) break;
}
return [{ json: { rows: out } }];
```
(Note: the dashboard pages are NOT affected — they paginate correctly
client-side. Only the snapshot numbers are wrong.)

## 2. 🔴 Payment states never heal — "in transit" numbers go stale

**Nodes:** `Odoo Payments1` → `Filter Today3`.
The flow re-fetches only payments whose **collection date is today**. A
payment from 5 days ago that moves `in_process → paid` in Odoo is **never
re-synced** — it stays `in_process` in `dashboard_payments` forever.

**Proof:** 32 of the 52 current `in_process` rows are older than 3 days
(6.7M IQD). Some of that is likely already cleared in Odoo.

This directly affects the dashboard's *cash in process / cash in transit*
figures (Overview) — they can only be as fresh as this sync.

**Fix:** filter Odoo by **write_date**, not by collection date — the same
pattern the orders flow already uses:
- In `Odoo Payments1`, add filter `write_date >= today start (Baghdad→UTC)`
  (keep `payment_type=inbound`, `partner_type=customer`).
- Delete the date check in `Filter Today3` (pass everything through) — the
  upsert on `payment_id` heals old rows automatically.

## 3. 🔴 "Odoo Payments1" fetches with `limit 800` and no date filter / order

The node asks Odoo for at most **800** payments with no domain on date and no
explicit ordering. Whether "today's" payments are inside those 800 depends on
Odoo's default ordering — fragile, and it breaks quietly the day you pass 800
total historical inbound payments (you already have 818 in Supabase).
**Fix:** the write_date filter from #2 solves this too (today's touched
payments are always a small set); also remove the 800 limit.

## 4. 🟡 Payments sync runs every 2 hours, not 15 minutes

The trigger is *named* "Every 15 min" but configured `hoursInterval: 2`.
"Cash collected today" on the dashboard lags up to 2 hours behind reality.
**Fix:** set the schedule to 15–20 minutes (it's a cheap sync once #2/#3 are
applied — only rows touched today move).

## 5. 🟡 `dashboard_customers` upsert never lands — the cache is permanently empty

The table has **0 rows** even though `Upsert Customers → Cache` runs every 20
minutes. Consequences: `Read Cache` always misses → `Fetch Missing Customers`
re-fetches **every** partner from Odoo **one request per customer, every
run** (slow, hammers Odoo), and the cache never warms.

Most likely cause: the POST fails (check that node's executions — a column
mismatch like `best_selling_products` being a JSON array vs a `text` column
returns HTTP 400, and n8n reports the node red).
**Fix:** (a) open one execution and read the actual error; (b) align the
`dashboard_customers` columns with what `Shape Customers` sends (make
`best_selling_products jsonb`, `customer_rank int`, money columns `numeric`);
(c) set the node's *On Error* to "Continue" so a cache failure can't kill the
run silently.

## 6. 🟡 Snapshot day-bucketing mixes UTC days with Baghdad anchors

In `Build Snapshots`, `dayOf` slices the raw UTC `date_order`
(`toDay = s.slice(0,10)`), but "today / week start / month" are computed in
Asia/Baghdad. Orders placed 21:00–24:00 UTC land on the wrong local day —
the same bug we fixed in the dashboard (`bagDay()`).
**Fix:** convert to Baghdad before slicing:
```js
const toDay = s => s ? new Date(String(s).replace(' ', 'T') + 'Z')
  .toLocaleDateString('en-CA', { timeZone: 'Asia/Baghdad' }) : null;
```

## 7. 🟡 Orders sync misses edits made on previous days after downtime

`Odoo Recent Orders` filters `write_date >= start of TODAY`. If n8n is down
for a day (or the run at 23:59 fails), yesterday's late changes are lost
forever — there is no backfill.
**Fix:** widen to `write_date >= now − 48h`, or add a nightly run with a
7-day write_date window. Upserts make re-fetching harmless.

## 8. 🔵 Security note — the service_role key is pasted in Set nodes

`Config3/4/5` embed the service key in plain text, so it travels with every
workflow export (like the JSON just shared in chat). Move it to an n8n
**credential** (Header Auth) referenced by the HTTP nodes, and rotate the key
in Supabase afterwards (Settings → API → "Reset service_role secret") —
after rotating, update it in n8n only.

---

# Supabase structure recommendations

1. **Indexes for the dashboard's range queries** (run once in SQL Editor):
   ```sql
   create index if not exists dashboard_orders_date_order_idx on public.dashboard_orders (date_order desc);
   create index if not exists dashboard_orders_state_idx      on public.dashboard_orders (state);
   create index if not exists dashboard_payments_date_idx     on public.dashboard_payments (date desc);
   ```
2. **`dashboard_customers`** — fix the upsert (#5) and it becomes the customer
   master the Debt page can read directly (today the dashboard only sees
   customers embedded in recent orders).
3. **`dashboard_monthly`** — empty and unwritten. Either drop it, or (better)
   add a small monthly-rollup branch in n8n (orders per month: confirmed
   count/value, cancelled, per-governorate) — that's what will make
   year-over-year and 12-month trend charts possible without fetching the
   whole orders table into the browser.
4. **Keep `dashboard_orders` unpruned** (it currently is) — it's the only
   full history; payments prune at 95 days is fine since collections views
   are short-window.
5. The dashboard deliberately does **not** read the `summary`/`trends`/`reps`
   snapshots (basis unverified + truncation bug #1). If you fix #1 and #6 and
   want to switch pages to snapshots later to cut bandwidth, verify each
   number against the raw table first (METRICS.md golden rule).
