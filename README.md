# Dabboos Product Dashboard

داشبورد تحليلات المنتجات لشركة دبوس — يقرأ من Supabase ويجيب على أربعة أسئلة:
ماذا أشتري؟ ماذا أصفّي؟ ماذا أدفع وأين؟ وأين أخسر المال؟

Product analytics for Dabboos. Answers four decisions: **what to buy**, **what to
liquidate**, **what to push and where**, and **where margin is leaking**.

## Basis — read this first

Every number on this dashboard is on the **invoice basis**, sourced from Odoo's
`account.invoice.report` (Invoicing → Reporting → **Invoice Analysis**).

**It will not match the Dabboos Sales Command Center**, which is on the orders basis
(`sale.report` / Sales Analysis). That is expected, not a bug:

| | This dashboard (invoices) | Sales Command Center (orders) |
|---|---|---|
| Date | `invoice_date` — a June order invoiced in July counts as July | `date_order` |
| Returns | netted (credit notes are negative) | not netted |
| Invoices with no sales order | included | invisible |
| Confirmed but not yet invoiced | invisible | counted |

## Stack

Static HTML + native ES modules. **No build step, no npm to deploy.** Chart.js from CDN,
Supabase via PostgREST, Arabic (default) / English with RTL, dark + light, money in IQD.

Node is used only to run the unit tests.

## Layout

```
*.html            one page per module (overview · products · status · returns ·
                  discounts · customers · agencies · debt · branches ·
                  frozen · reorder · admin)
assets/js/        api · calc · config · format · perm · shell · pages/
supabase/         schema + RPCs + permissions (run in the Supabase SQL editor)
supabase/functions/  admin-users Edge Function (holds the service_role key)
n8n/              Odoo → Supabase sync workflows
test/             unit tests for the pure functions (node:test)
docs/             design specs and Odoo field notes
```

`calc.js` and `perm.js` are pure functions with no I/O, so the maths and the permission
rules are testable without a network or a database. `api.js` is the only file that knows
Supabase exists.

## Users and permissions

Access is **role-based and enforced in Postgres**, not in the browser.

| | Set on | Enforced by |
|---|---|---|
| Which **pages** you see | the role, minus a per-user denial list | nav filtering + a page guard |
| Which **columns** are hidden (margin, cost, revenue, stock value, customer names) | the role | `case when` inside the RPCs — the value comes back NULL |
| Which **Supabase tables** you may read at all | the role | one RLS predicate per table |
| Which **rows** you see (salespersons, governorates) | the **user** | RLS policies on `dashboard_invoice_lines` and `dashboard_customers` |

Roles carry pages, columns and tables; scope is per user, so one `Salesperson` role can
serve ten people who each see only their own territory. A user can additionally be
**denied** individual pages — subtractive only, so an override can never grant access
the role lacks, and the role stays an upper bound.

`app_me()` returns the already-computed **effective** page list, so the browser never
merges two layers and they can never disagree.

### Hiding a whole table

Admin → Tables lists every Supabase table, what it provides, and which pages read it.
They are not equally safe to switch off, so each carries its impact:

| Table | Hiding it |
|---|---|
| `dashboard_customers` | drill-down shows partner IDs |
| `dashboard_stock_history` | nothing reads it yet |
| `dashboard_stock` | Frozen capital and Reorder stop working |
| `dashboard_invoice_lines` | **no sales numbers anywhere** |
| `dashboard_products` | **blank dashboard** — every page is built from this table |

`dashboard_excluded_products` is deliberately **not** hideable. It is a filter, not a
data source: hiding it would let the `[DISC]` invoice-discount lines back into every
product table and make the numbers *wrong* rather than absent.

**A withheld number is blank, never zero.** RLS makes a hidden table return no rows, and
the RPCs then return NULL rather than letting `coalesce(…, 0)` turn absence into a
confident `0`. Without that, hiding stock would show every product as "0 on hand" and
Reorder would recommend buying the entire catalogue.

Two roles ship as system roles: **admin** (everything, including `/admin`) and
**management** (everything except `/admin`). Admins create the rest.

Hiding in JavaScript is not hiding: the anon key is in `config.js` and any signed-in
user can read their own JWT. Every restriction that matters therefore lives in
[`supabase/04_admin.sql`](supabase/04_admin.sql) and
[`supabase/05_masking.sql`](supabase/05_masking.sql). `perm.js` only decides what to
*draw*.

**A user with no `app_users` row is denied, not granted.** The dashboard says
*"your account is not set up yet"* rather than rendering an empty page — an empty
dashboard would look like a data outage.

## The four management pages

Added on request from management. They live beside the rest of the dashboard and obey
the same permission model, but three of the four are **ahead of the data** — so each one
calls the RPC it will eventually use, and draws clearly-marked demo rows until that
function exists.

| Page | Question | Real data today? |
|---|---|---|
| `customers.html` — عملاء 80/20 | how few customers carry the company, per governorate and sales department | revenue and governorate yes; the **department name** is missing |
| `agencies.html` — التوكيلات | which 20% of an agency's products make 80% of its sales, where it sells, and which big customers it never reaches | yes — brand is on the invoice line |
| `debt.html` — الديون | who owes, how far past **their own** terms, who is over their limit | balances and limits yes; **aging** no |
| `branches.html` — المخازن | Basra and Mosul separately, including transfer suggestions | no — nothing knows about warehouses |

### What each page still needs from Odoo

| Page | Missing | Where it is |
|---|---|---|
| Customers | the sales-**team name** | `team_id` is already synced, but the n8n mapper keeps `id0(r.team_id)` and drops the label. First confirm the four departments (سوبرماركت وهايبر · كرزات · الجملة · السلاسل) really are `crm.team` records and not partner tags. |
| Agencies | nothing | but brand is set on only ~64% of lines, so the unattributed third stays visible as its own bucket rather than being dropped |
| Debt | `invoice_date_due`, `amount_residual`, payment terms | the due date is already on `account.invoice.report` and simply absent from the sync's field list; the residual needs a new sync from `account.move` |
| Branches | per-warehouse stock | `dashboard_stock` holds `qty_available`, which is **company-wide** — there is no location in it at all. Needs a `stock.quant` sync grouped by warehouse. |

**The demo fallback fires on exactly one condition:** PostgREST answering *"function does
not exist"*. A network error, a timeout, a permission denial or an empty result is
reported as itself. Falling back on any of those would replace a real outage with
plausible fake numbers — the worst thing this dashboard could do. A page on demo data
says so in a red banner and marks every tile.

To make the pages openable, run
[`supabase/11_management_pages.sql`](supabase/11_management_pages.sql) once.
Without it `app_roles.pages` does not list them and the page guard bounces everyone,
including the admin.

### Why the 80/20 charts have no bars on them

A textbook Pareto chart puts revenue bars on one y-axis and the cumulative percentage on
a second. Two scales in one frame can be slid against each other until the story looks
how the author wants, and the reader cannot see that it happened. Here the curve is a
pure 0–100% frame with an equality diagonal for reference, and the magnitudes live in
the bars and the table beneath it. Same information, nothing to hide behind.


## Caching

`vercel.json` sets `Cache-Control: public, max-age=0, must-revalidate` on **everything**.
That is deliberate, and it is not a performance oversight.

The `?v=` cache-busting numbers live **only** in the HTML files. So:

* a cached **page** keeps requesting the *old* script URLs — a deploy lands and nothing
  on screen changes, with no error to explain why;
* ES modules import each other **without** a version query (`overview.js?v=9` imports a
  bare `../shell.js`), so a stale `shell.js` can pair with fresh page code and produce
  missing labels rather than an honest failure.

`must-revalidate` means the browser sends an `If-None-Match` on each load and gets a
`304` when nothing changed — a round trip, not a download. For a handful of small static
files that is the right trade against shipping a deploy nobody can see.

## Running locally

```
npx serve .        # or any static server
```

A **login is required** — Row-Level Security means the anon key alone returns zero rows.

## Tests

```
node --test test/*.test.js
```

## Design

See [docs/superpowers/specs/2026-08-01-dabboos-product-dashboard-design.md](docs/superpowers/specs/2026-08-01-dabboos-product-dashboard-design.md).
