# Admin, roles and permissions — design

**Date:** 2026-08-07
**Status:** approved, implementing

## The problem

Every user of the dashboard sees everything. RLS says `using (true)` for the
`authenticated` role, so a login is all-or-nothing. There is no way to give a
salesperson a view of their own territory, no way to hide margin from someone who
should see volume, and no way to create or manage users without opening the
Supabase dashboard.

## What we are building

1. An **admin page**, reachable only by admins, that creates users, sets their
   passwords and display names, assigns roles, and sets each user's data scope.
2. **Roles** — two seeded (`admin`, `management`) plus any number the admin
   creates. A role owns a set of visible **pages** and a set of hidden
   **columns**.
3. **Per-user scope** — the salespersons and governorates a user may see.
4. **Activity tracking** — logins and page views, surfaced on the admin page.

## Enforcement: three problems, three mechanisms

Hiding in JavaScript is not hiding. Any user can read the anon key out of
`config.js`, take their own JWT from localStorage, and call PostgREST directly.
Anything that must be secret is therefore enforced in Postgres.

| What | Mechanism | Why not otherwise |
|---|---|---|
| **Rows** — salesperson, governorate | RLS policies on `dashboard_invoice_lines` and `dashboard_customers` | RLS is row-level by definition, and it is the only layer a hand-crafted API call cannot step around |
| **Columns** — margin, cost, revenue, stock value, customer names | `case when` inside each RPC, returning **NULL** | RLS cannot mask columns. Returning NULL rather than dropping the column keeps every RPC's return signature stable, so no page breaks |
| **Pages** | Nav filtering + a page guard in `shell.js` | With rows and columns already enforced, forcing a page URL leaks nothing new — the page renders the user's own slice |

### Why RLS scoping is nearly free here

Every RPC in `02_functions.sql` and `03_exclusions.sql` is `security invoker`.
RLS on the base tables therefore applies *inside* the function body. One policy on
`dashboard_invoice_lines` scopes Overview KPIs, Products, Frozen capital, Reorder,
`filter_options()` and `data_health()` simultaneously, with no per-page filtering
code anywhere.

A pleasant consequence: a Basra-scoped user's governorate dropdown contains only
Basra, because `filter_options()` is built from the rows they can see. The scope is
invisible to them rather than offering options that silently return nothing.

### Performance

An RLS policy that calls a function is evaluated **per row** unless the call is
wrapped in a scalar subquery. On 33k+ invoice lines per month that is the entire
performance story, so every helper call in a policy is written as
`(select public.app_my_govs())`, which Postgres hoists into a once-per-query
InitPlan.

## Data model

Three tables, in `04_admin.sql`.

### `app_roles`

| Column | Type | Notes |
|---|---|---|
| `role_key` | text PK | `admin`, `management`, or admin-chosen |
| `name_ar`, `name_en` | text | shown in the UI, bilingual like the rest of the app |
| `pages` | text[] | subset of `overview`, `products`, `frozen`, `reorder`, `admin` |
| `hidden_columns` | text[] | subset of `margin`, `cost`, `revenue`, `stock_value`, `customers` |
| `is_system` | bool | `admin` and `management` — cannot be deleted or renamed |

### `app_users`

| Column | Type | Notes |
|---|---|---|
| `user_id` | uuid PK | → `auth.users(id)`, `on delete cascade` |
| `username` | text unique | the local part of the synthetic email |
| `display_name` | text | |
| `role_key` | text | → `app_roles` |
| `scope_salespersons` | text[] | **NULL means all** — not empty array |
| `scope_govs` | text[] | **NULL means all** |
| `is_active` | bool | a false here denies access without deleting the login |
| `last_seen_at` | timestamptz | |

`NULL = all, empty array = nothing` is deliberate. An admin who assigns a role but
forgets the scope gets a user who sees everything (visible, obviously wrong) rather
than a user who sees nothing (looks like a bug in the dashboard).

### `app_activity`

`id`, `user_id`, `kind` (`login` | `page`), `page`, `at`, `user_agent`.

## Permission resolution

Roles carry pages and hidden columns. Users carry scope. There are **no per-user
permission overrides** — to change what someone sees you change their role or their
scope, so there is only ever one place to look.

Helpers are `SECURITY DEFINER` with `search_path` pinned to `public, pg_temp`, which
is what lets an `app_users` policy read `app_users` without recursing:

- `app_is_provisioned()` — has an active `app_users` row
- `app_is_admin()`
- `app_my_salespersons()`, `app_my_govs()` — NULL means unrestricted
- `app_my_hidden_columns()`
- `app_me()` — the whole identity as one row, for the front end
- `app_log(kind, page)` — appends activity and touches `last_seen_at`

## Failure modes designed against

The project's existing rule is that *an auth failure is never an empty result*
(`api.js` header comment). Two new ways to violate it, both handled:

1. **A user with no `app_users` row is denied, not granted.** Default-deny, so an
   account created directly in the Supabase dashboard cannot bypass the system. The
   front end distinguishes this from "no data" and shows *"account not provisioned —
   contact the admin"*. `06_bootstrap.sql` backfills every existing `auth.users` row
   as `management` first, so nobody is locked out on deploy.

2. **Re-running an earlier SQL file silently removes every restriction.**
   `01_schema.sql` ends with `create policy ... using (true)`, and `03_exclusions.sql`
   redefines `product_facts` without masking. Re-running either would revert
   permissions with no error. Both files get a warning header pointing at the file
   that supersedes them, and the numbered run order is documented in
   `supabase/README.md`.

## Admin write path

Creating a user and setting a password require the `service_role` key, which can
never reach the browser. A Supabase **Edge Function** (`admin-users`) holds it:

1. Reads the caller's JWT from the `Authorization` header.
2. Verifies with the service client that the caller has an active `app_users` row
   whose role is `admin`. **The client is never trusted about who it is.**
3. Executes one of `list`, `create`, `set_password`, `update`, `delete`.

Role CRUD and scope edits do **not** go through the Edge Function — they are
ordinary PostgREST writes guarded by admin-only RLS policies on `app_roles` and
`app_users`. Only operations that genuinely need `service_role` are routed
server-side.

Two guards implemented as triggers, because RLS cannot express them:

- The last remaining admin cannot be demoted or deactivated.
- A `is_system` role cannot be deleted, and its `role_key` cannot change.

## Front end

- **`assets/js/perm.js`** — pure functions (`canPage`, `canColumn`, `visibleNav`,
  `maskRow`) with no I/O, unit-tested under `node --test` alongside `calc.js`.
- **`assets/js/api.js`** — gains `appMe()`, `logActivity()`, and the admin calls.
  `appMe()` is fetched once per page load and cached in `sessionStorage`.
- **`assets/js/shell.js`** — `mountShell()` renders only the user's pages;
  `requireAuth()` gains a page guard that redirects to the first allowed page;
  a new not-provisioned state.
- **`admin.html` + `assets/js/pages/admin.js`** — three tabs: Users, Roles,
  Activity.
- Existing pages hide masked columns rather than rendering a column of dashes.
  The server nulls them regardless; the UI change is cosmetic, belt and braces.

## Run order

```
01_schema.sql        (already run — do not re-run, see its header)
02_functions.sql     (already run)
03_exclusions.sql    (already run — do not re-run, see its header)
04_admin.sql         NEW — tables, helpers, scoped RLS
05_masking.sql       NEW — redefines the RPCs with column masking
06_bootstrap.sql     NEW — seed roles, backfill users, grant first admin
```

## Testing

- `test/perm.test.js` — pure permission logic under `node --test`.
- `04_admin.sql` and `06_bootstrap.sql` each end with a verification `select`,
  matching the existing files' convention.
- Manual: sign in as a scoped user and confirm the Overview total differs from the
  admin's, and that a direct PostgREST call with that user's JWT returns only their
  rows.
