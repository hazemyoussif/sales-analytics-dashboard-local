-- ============================================================
-- Salesperson-scoped viewer access — run ONCE in Supabase → SQL Editor.
--
-- Lets an admin attach a login to a GROUP of salespersons. That user then
-- sees the whole dashboard normally, but every number counts ONLY their
-- attached salespersons — enforced by the DATABASE (RLS), not the UI.
--
-- How it works:
--   • dash_users gets `scope_user_ids int8[]` — the Odoo salesperson user_ids
--     this login may see. NULL / empty = NO restriction (full access, today's
--     behaviour). Every existing user stays NULL, so nothing changes for them.
--   • dash_scope_ids() returns the caller's list (NULL when unrestricted).
--   • Each data table's read policy gains one clause:
--       AND (scope IS NULL OR scope @> array[user_id])
--     (@> = "array contains" — compares int8[] to int8[]; the `= ANY(subquery)`
--      form fails with "operator does not exist: bigint = bigint[]").
--   • The pre-aggregated tables (snapshots, monthly) are summed across ALL reps
--     and cannot be split, so scoped users are BLOCKED from them.
--
-- Design: docs/superpowers/specs/2026-08-05-salesperson-scoped-access-design.md
-- Safe to re-run (idempotent): it only restates the current role logic and
-- appends the scope clause.
--
-- ⚠️ Scope is admin-set only: regular users have no UPDATE policy on dash_users,
--    so a scoped user cannot lift their own restriction.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The column
-- ------------------------------------------------------------
alter table public.dash_users
  add column if not exists scope_user_ids int8[];

comment on column public.dash_users.scope_user_ids is
  'Odoo salesperson user_ids this login may see. NULL/empty = full access.';

-- ------------------------------------------------------------
-- 2. Helper: the caller's scope list (NULL when unrestricted).
--    SECURITY DEFINER so it can read dash_users without recursing into RLS.
--    Empty array is normalised to NULL so "no reps checked" = full access,
--    never "see nothing".
-- ------------------------------------------------------------
create or replace function public.dash_scope_ids()
returns int8[]
language sql
stable
security definer
set search_path = public
as $$
  select case
           when scope_user_ids is null or cardinality(scope_user_ids) = 0
             then null
           else scope_user_ids
         end
  from public.dash_users
  where user_id = auth.uid() and is_active
$$;

-- ------------------------------------------------------------
-- 3. Re-create the read policies with the scope clause.
--    Role logic is restated verbatim from perf-policies.sql / add-invoices.sql
--    (the `(select ...)` InitPlan form — evaluated once per query, not per row).
-- ------------------------------------------------------------

-- Orders: management/admin see all; alerts-role users see only alert rows.
-- The scope clause applies on top of whichever branch matched.
drop policy if exists orders_read on public.dashboard_orders;
create policy orders_read on public.dashboard_orders
  for select to authenticated
  using (
    (
      (select public.dash_role()) in ('admin', 'management')
      or ((select public.dash_role()) = 'alerts' and level in ('critical', 'warning'))
    )
    and (
      (select public.dash_scope_ids()) is null
      or (select public.dash_scope_ids()) @> array[user_id]
    )
  );

drop policy if exists payments_read on public.dashboard_payments;
create policy payments_read on public.dashboard_payments
  for select to authenticated
  using (
    (select public.dash_role()) in ('admin', 'management')
    and (
      (select public.dash_scope_ids()) is null
      or (select public.dash_scope_ids()) @> array[user_id]
    )
  );

drop policy if exists invoices_read on public.dashboard_invoices;
create policy invoices_read on public.dashboard_invoices
  for select to authenticated
  using (
    (select public.dash_role()) in ('admin', 'management')
    and (
      (select public.dash_scope_ids()) is null
      or (select public.dash_scope_ids()) @> array[user_id]
    )
  );

drop policy if exists customers_read on public.dashboard_customers;
create policy customers_read on public.dashboard_customers
  for select to authenticated
  using (
    (select public.dash_role()) in ('admin', 'management')
    and (
      (select public.dash_scope_ids()) is null
      or (select public.dash_scope_ids()) @> array[user_id]
    )
  );

-- Aggregate tables: summed across ALL reps, cannot be split → block scoped
-- users. These are not read by the current front-end (defence-in-depth), and
-- may not exist in every environment, so guard each with a to_regclass check
-- so a missing table never aborts this script.
do $$
begin
  if to_regclass('public.dashboard_snapshots') is not null then
    drop policy if exists snapshots_read on public.dashboard_snapshots;
    create policy snapshots_read on public.dashboard_snapshots
      for select to authenticated
      using (
        (select public.dash_role()) in ('admin', 'management')
        and (select public.dash_scope_ids()) is null
      );
  end if;

  if to_regclass('public.dashboard_monthly') is not null then
    drop policy if exists monthly_read on public.dashboard_monthly;
    create policy monthly_read on public.dashboard_monthly
      for select to authenticated
      using (
        (select public.dash_role()) in ('admin', 'management')
        and (select public.dash_scope_ids()) is null
      );
  end if;
end $$;

-- ============================================================
-- Verify:
--   -- as an admin, attach two reps to a test user (get their user_ids from
--   -- the salespeople table), then log in AS that user and confirm scoping:
--
--   select user_id, name from public.salespeople order by name;
--   update public.dash_users
--     set scope_user_ids = array[<repA_user_id>, <repB_user_id>]
--     where username = '<test_viewer>';
--
--   -- Signed in as the test viewer, these must return ONLY the two reps' rows:
--   --   select distinct user_id from public.dashboard_orders;
--   -- and snapshots must be empty:
--   --   select count(*) from public.dashboard_snapshots;   -- 0 for scoped user
--
--   -- Unset (full access) again:
--   update public.dash_users set scope_user_ids = null where username = '<test_viewer>';
-- ============================================================
