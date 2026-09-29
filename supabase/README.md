# Supabase setup — new project

The product dashboard lives in its **own Supabase project**, separate from the Dabboos Sales
Command Center. It inherits nothing, so everything it reads has to be created and synced here.

## Order of operations

### 1. Clean up the old project *(only if you already ran the schema there)*

Run [`00_rollback.sql`](00_rollback.sql) in the **old** project (`puqfldltipedlodwfyex`).
It drops only `dashboard_invoice_lines` and `dashboard_stock_history`, and aborts if either
holds rows. Everything the sales dashboard uses is left untouched.

### 2. Create the new project

Supabase → New project. Note down, from Settings → API:

| Value | Where it goes |
|---|---|
| Project URL | `assets/js/config.js` **and** every n8n Config node |
| `anon` key | `assets/js/config.js` — safe in the browser, reads nothing without a user JWT |
| `service_role` key | **n8n only.** Never in this repo, never in the browser |

### 3. Run the schema

Paste [`01_schema.sql`](01_schema.sql) into the SQL Editor and run it. It is idempotent —
re-running upgrades an existing table rather than failing. The final query lists the five
tables it created with their column counts.

### 4. Create a login

RLS grants read to the `authenticated` role only. With no user, every query returns
**HTTP 200 with zero rows** — a silent empty result, not an error.

Authentication → Users → Add user. The sales dashboard's convention is a synthetic email
(`<username>@dabboos.app`) with a password, which the front end derives from the username at
login. Create at least one user before expecting any data on screen.

### 5. Clone the three existing n8n syncs

These already exist and work against the old project. **Duplicate them** — do not repoint the
originals, the sales dashboard still depends on them — and change only the Config node's
`supabaseUrl` and `serviceKey` to this project.

| Existing workflow | Fills | Schedule |
|---|---|---|
| Products + Stock sync | `dashboard_products`, `dashboard_stock` | every 2h |
| Customers sync | `dashboard_customers` | hourly |

### 6. Add the new syncs

| Workflow | Fills | Schedule |
|---|---|---|
| `invoice-lines-backfill` | `dashboard_invoice_lines` | once, month-chunked |
| `invoice-lines-nightly` | `dashboard_invoice_lines` | 02:00, rolling 35 days, delete-then-insert |
| `stock-history-nightly` | `dashboard_stock_history` | 03:00, append one row per product |

Activate `stock-history-nightly` **immediately** — every day it is off is a day of stock
history that cannot be recovered.

Leave `invoice-lines-nightly` **inactive** until one product has been verified against Odoo.

### 7. Run the RPCs

Paste [`02_functions.sql`](02_functions.sql) once invoice lines are populated, then
[`03_exclusions.sql`](03_exclusions.sql).

### 8. Run the permission layer

| Order | File | What it does |
|---|---|---|
| 1 | [`04_admin.sql`](04_admin.sql) | `app_roles`, `app_users`, `app_activity`, the permission helpers, and the **scoped** RLS policies that replace `using (true)` |
| 2 | [`07_tables_and_overrides.sql`](07_tables_and_overrides.sql) | `hidden_tables` on roles, `pages_denied` on users, and the RLS predicate that makes a hidden table return nothing |
| 3 | [`05_masking.sql`](05_masking.sql) | redefines every RPC so hidden columns — and fields from hidden tables — come back **NULL, not 0** |
| 4 | [`06_bootstrap.sql`](06_bootstrap.sql) | seeds the `admin` and `management` roles, backfills existing logins, and makes **you** an admin — **edit `v_admin_username` in section 3 before running** |
| 5 | [`08_add_status_page.sql`](08_add_status_page.sql) | grants the new **Status** page to the two system roles |
| 6 | [`09_returns_discounts.sql`](09_returns_discounts.sql) | the Returns and Discounts RPCs, and grants both pages to the system roles |
| 7 | [`10_performance.sql`](10_performance.sql) | **required** — the indexes those RPCs need. Without it they hit `statement timeout` |

**Yes, 07 really does run before 05.** `05_masking.sql` calls `app_table_visible()`,
which `07` creates, and `05` must be the last file to define the RPCs. If you already
ran `05` before `07` existed, just run `07` and then re-run `05`.

Skipping the re-run of `05` does not fail loudly. It produces a role that reads
**`0` on hand for every product** instead of "stock data unavailable" — and the
Reorder page will then urgently recommend buying the entire catalogue.

Read the output of `06_bootstrap.sql` before signing out. If its `admins` row says
`NONE`, you cannot reach the admin page and the only way back is another SQL session.

### 9. Deploy the admin Edge Function

Creating a login and setting a password need the `service_role` key, which cannot
go in the browser. [`functions/admin-users/index.ts`](functions/admin-users/index.ts)
holds it server-side and refuses anyone whose `app_users` row is not an active admin.

```
supabase functions deploy admin-users
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected by the platform —
nothing to configure. Everything else (role definitions, scope edits) is an
ordinary PostgREST write guarded by admin-only RLS, so it needs no elevated key.

## ⚠️ Run order is load-bearing

Later files **redefine** what earlier ones create. Re-running an earlier file alone
silently undoes the permission layer — no error, and the only symptom is a
restricted user quietly seeing more than they should.

```
01_schema.sql               `using (true)` policies   → superseded by 04 and 07
02_functions.sql            creates the RPCs          → superseded by 05
03_exclusions.sql           redefines product_facts   → superseded by 05
04_admin.sql                scoped RLS policies       → policies superseded by 07
07_tables_and_overrides.sql hideable tables + overrides
05_masking.sql              RPCs with masking          ← must run LAST of the RPC files
06_bootstrap.sql            seed roles + first admin
08_add_status_page.sql      grants the Status page
09_returns_discounts.sql    returns/discounts RPCs + page grants
10_performance.sql          indexes + faster dimension RPCs
```

`09` defines only NEW functions, so it does not collide with `05_masking.sql` and can
run either side of it.

**A new page always needs a migration.** `app_roles.pages` is an allow-list and
`requireAuth()` denies anything not in it, so shipping a page without adding its key
gives a screen nobody can open — including the admin, whose grant checkbox reads from
the same list. `08` adds `status` to the two system roles only; custom roles get it when
an admin ticks the box, because silently widening a restricted role's access just
because developers added a screen is the surprise this model exists to prevent.

| If you re-run… | Follow it with |
|---|---|
| `01_schema.sql` | `04_admin.sql`, then `07_tables_and_overrides.sql` |
| `02_functions.sql` or `03_exclusions.sql` | `05_masking.sql` |
| `04_admin.sql` | `07_tables_and_overrides.sql` (it owns the data-table policies now) |
| `07_tables_and_overrides.sql` | `05_masking.sql` |

## Why two projects costs something

Products, stock and customers now exist in **two** places, synced from Odoo twice. They will
drift if one set of workflows fails silently. If a number on this dashboard ever disagrees
with the sales dashboard, check whether both projects' product syncs actually ran before
assuming the maths is wrong.
