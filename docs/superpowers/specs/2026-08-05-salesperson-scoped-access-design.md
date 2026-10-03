# Salesperson-scoped viewer access — design

**Date:** 2026-08-05
**Status:** approved, ready to implement

## Goal (owner's words)
> "I want the one who will login, I will give him access to watch specific
> salespersons, so the user will be attached to a number of salespersons and he
> will watch the whole dashboard normal but the numbers reflect for those
> salespersons."

A viewer login can be **attached to a group of salespersons** (one or many). That
viewer sees the **whole dashboard exactly as normal** — every page, every chart,
rep comparisons — but **every number counts only their attached salespersons**.
They cannot see any rep outside their group. Empty group = full access (today's
behaviour, unchanged for all existing users).

Think "team supervisor": watches their own team of reps, normal dashboard, totals
limited to that team.

## The golden rule (why this is DB-enforced, not UI)
Per `CLAUDE.md` #6, access is enforced by **Row-Level Security**, never by hiding
things in the UI. The anon key + a user's JWT must be physically unable to read
another rep's rows. All UI changes here are cosmetic; RLS is the control.

Every data row already carries `user_id` = the Odoo salesperson id
(`dashboard_orders`, `dashboard_payments`, `dashboard_invoices`,
`dashboard_customers`). That single column is what we filter on.

## Data model

New nullable column on `public.dash_users`:

- `scope_user_ids int8[]` — the Odoo salesperson `user_id`s this login may see.
  `NULL` or empty `{}` = **no restriction** (full access). Existing rows stay
  `NULL`, so nothing changes for current users.

New SECURITY DEFINER helper (mirrors `dash_role()`), normalises empty → NULL:

```sql
create or replace function public.dash_scope_ids()
returns int8[]
language sql stable security definer set search_path = public
as $$
  select case
           when scope_user_ids is null or cardinality(scope_user_ids) = 0
             then null
           else scope_user_ids
         end
  from public.dash_users
  where user_id = auth.uid() and is_active
$$;
```

Scope is **admin-set only** — regular users have no UPDATE policy on `dash_users`,
so a scoped user cannot lift their own restriction. Scope is **orthogonal to
role**: a viewer is typically `role = management` (all dashboard pages, no admin)
with a scope set. Any role may carry a scope; empty = unrestricted.

## RLS policy changes

Row-level tables — add one clause (data auto-filters to the attached reps):

| Table | Existing rule (unchanged) | Added clause |
|---|---|---|
| `dashboard_orders` | role gate | `and (dash_scope_ids() is null or user_id = any(dash_scope_ids()))` |
| `dashboard_payments` | role gate | same |
| `dashboard_invoices` | role gate | same |
| `dashboard_customers` | role gate | same |

Aggregate tables — pre-summed across ALL reps, cannot be split → **block scoped
users**:

| Table | New rule |
|---|---|
| `dashboard_snapshots` | `... and dash_scope_ids() is null` |
| `dashboard_monthly` | `... and dash_scope_ids() is null` |

All shipped as a new idempotent script `supabase/salesperson-scope.sql` (adds the
column, the helper, and re-creates the affected policies). It restates the current
role logic verbatim and appends the scope clause, so it is safe to re-run.

Rows with `user_id IS NULL` (unassigned) are invisible to scoped users — correct:
an unassigned order belongs to no rep's team.

## Admin page

- **Create-user form** and **each user row** get an "Attached salespersons"
  control: a scrollable checkbox list of reps from the `salespeople` master
  (`user_id`, `name`), styled like the existing `.pg-checks` page checkboxes.
  None checked = full access.
- Saving writes `scope_user_ids` (array of `user_id`, or `NULL` when none checked).
- The user row shows a compact summary ("3 reps" / "Full access").
- New i18n keys in both `ar` and `en` (`admin_scope`, `admin_scope_all`, …).

## Dashboard behaviour for a scoped viewer

- `auth.js` adds `scope_user_ids` to the profile `select` and exposes
  `DASH_AUTH.scopeIds()` (array or null).
- **No calculation changes** on the raw-based pages (Overview, Salespeople, Debt,
  Regions/Cities, Alerts, and most of Collections): RLS filters server-side, so
  they render normally with only the attached reps. The shared filter bar's rep
  dropdown auto-limits, because `setReps()` is filled from the already-filtered
  rows.
- **Header banner** (in `buildChrome`): when scoped, show
  "Viewing: «rep names»" so the numbers are self-explanatory and trustworthy.
- **Snapshot-derived widgets** (Collections 14-day per-rep grid, rep-debt, DSO):
  IMPLEMENTATION NOTE — verified during build that `D.api("rep_collections" /
  "rep_debt" / "collections")` are **raw-table adapters** (they build from
  `dashboard_orders` / `dashboard_payments` / `dashboard_invoices` /
  `dashboard_customers`, per the "used to be n8n snapshots" comment in
  `common.js`). Every source carries `user_id`, so these widgets **auto-scope
  under RLS with no code change** — no degradation or recompute needed. The
  `dashboard_snapshots` / `dashboard_monthly` tables are not read by the current
  front-end; blocking scoped users from them is harmless defence-in-depth.

## Security & edge cases
- RLS is the control; every UI hide/banner is cosmetic.
- A scoped viewer can still read the `salespeople` name master (names only, low
  sensitivity). Left readable in v1; can be scoped later if desired.
- `service_role` (n8n) bypasses RLS — sync unaffected.
- Empty array must mean "no restriction," not "see nothing" — the helper
  normalises `{}` → `NULL`; the admin saves `NULL` when no rep is checked.
- Scope + role combine: e.g. an `alerts`-role user with a scope sees only their
  team's alert rows.

## Verification (no automated tests in this repo)
1. `node --check` on changed JS.
2. Create a test viewer, attach rep X (and Y) → log in:
   - Overview / Salespeople / Debt / Regions / Alerts / Collections show only
     X (+Y) numbers; rep dropdown lists only X (+Y).
   - Header shows "Viewing: X, Y".
3. Direct REST probe as that user (`dashboard_orders?user_id=eq.<other rep>`)
   returns `[]` — DB-enforced, not UI.
4. `dashboard_snapshots` returns `[]` for the scoped user; the Collections grid
   still renders (recomputed) or is cleanly hidden — no console error.
5. An unscoped admin/management user still sees everything (regression check).
6. Cache-buster bumped (`?v=78 → ?v=79`) in all HTML + `service-worker` VERSION,
   since `common.js`/`auth.js` change (CLAUDE.md #5).

## Out of scope (later, if wanted)
- Rebuilding all snapshot/monthly trend charts from raw for scoped users.
- Scoping the `salespeople` name list itself.
- A dedicated "supervisor" role label (scope stays a separate attribute).
