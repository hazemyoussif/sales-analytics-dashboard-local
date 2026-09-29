-- Dabboos Product Dashboard — hideable tables + per-user page overrides
-- Run in: Supabase -> SQL Editor. Safe to re-run (idempotent).
-- Run AFTER 04_admin.sql.
--
-- ⚠️ AFTER RUNNING THIS FILE, RE-RUN 05_masking.sql.
--    This file makes a hidden table return zero rows. 05_masking.sql is what
--    stops the fields that came from it turning into a confident `0` — see
--    "WHY NULL, NOT ZERO" below. Running this alone gives a role that reads
--    "0 on hand" for every product instead of "stock data unavailable".
--
-- ===========================================================================
-- WHAT THIS FILE ADDS
-- ===========================================================================
--   app_roles.hidden_tables   Supabase tables this role may not read at all
--   app_users.pages_denied    pages taken away from ONE person
--
-- ===========================================================================
-- WHY NULL, NOT ZERO
-- ===========================================================================
-- product_facts LEFT JOINs dashboard_stock and wraps the result in
-- coalesce(s.on_hand_qty, 0). Once RLS denies that table, the join produces
-- NULL and the coalesce turns it into 0 — so every product would read "0 on
-- hand" and the Reorder page would urgently recommend buying the entire
-- catalogue. A withheld number must be absent, never zero. That is the same
-- rule the health strip exists to enforce, and 05_masking.sql applies it.
--
-- ===========================================================================
-- WHY dashboard_excluded_products IS NOT HIDEABLE
-- ===========================================================================
-- It is a FILTER, not a data source. product_facts reads it to exclude the
-- `[DISC] خصم عام` invoice-discount lines, which carry -44.5M IQD and 850
-- fake "units". Hiding it would not hide anything — the NOT EXISTS check would
-- match nothing, those lines would flow back into every product table, and the
-- numbers would be silently WRONG rather than absent. Corrupting data is not a
-- permission setting, so the table is deliberately absent from the admin UI
-- and keeps its provisioning-only policy.

-- ===========================================================================
-- 1. Columns
-- ===========================================================================
-- Default '{}' — nothing hidden — so every existing role keeps working
-- unchanged the moment this runs.
alter table public.app_roles
  add column if not exists hidden_tables text[] not null default '{}';

-- NULL or '{}' means "deny nothing". Subtractive ONLY: this list can remove a
-- page the role grants, and can never add one it does not. An override that
-- could grant would let an admin escalate a user past their role without the
-- role ever showing it — the exact confusion that made per-user overrides a
-- bad idea in the first place. Subtraction keeps the role an upper bound.
alter table public.app_users
  add column if not exists pages_denied text[];

-- ===========================================================================
-- 2. Helpers
-- ===========================================================================
create or replace function public.app_my_hidden_tables()
returns text[]
language sql stable security definer set search_path = public, pg_temp
as $$
  select coalesce(
    (select r.hidden_tables
       from public.app_users u
       join public.app_roles r on r.role_key = u.role_key
      where u.user_id = auth.uid() and u.is_active),
    '{}'::text[]);
$$;

-- Note the ANY here takes a plain function call, not a parenthesised SELECT,
-- so it is the ARRAY form and needs no cast. Contrast the policies in
-- 04_admin.sql, which do — the comment there explains why.
create or replace function public.app_table_visible(p_table text)
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select not (p_table = any (public.app_my_hidden_tables()));
$$;

grant execute on function public.app_my_hidden_tables() to authenticated;
grant execute on function public.app_table_visible(text) to authenticated;

-- ===========================================================================
-- 3. app_me — now returns EFFECTIVE pages
-- ===========================================================================
-- `pages` is the role's list minus the user's denied list, computed here. The
-- front end therefore needs no override logic at all: it keeps asking "which
-- pages do I have", and the answer already accounts for both layers. One
-- source of truth, in SQL, where the enforcement is.
--
-- DROP, not just CREATE OR REPLACE. This version returns four columns that
-- 04_admin.sql's version does not (role_pages, pages_denied, hidden_tables),
-- and Postgres refuses to replace a function whose OUT parameters change:
--     ERROR: cannot change return type of existing function
-- Nothing depends on app_me() in a policy or a view, so dropping it is safe.
drop function if exists public.app_me();

create or replace function public.app_me()
returns table (
  user_id            uuid,
  username           text,
  display_name       text,
  role_key           text,
  role_name_ar       text,
  role_name_en       text,
  pages              text[],
  role_pages         text[],
  pages_denied       text[],
  hidden_columns     text[],
  hidden_tables      text[],
  scope_salespersons text[],
  scope_govs         text[],
  is_admin           boolean
)
language sql stable security definer set search_path = public, pg_temp
as $$
  select u.user_id, u.username, u.display_name, u.role_key,
         r.name_ar, r.name_en,
         -- effective pages
         coalesce((select array_agg(p)
                     from unnest(r.pages) p
                    where not (p = any (coalesce(u.pages_denied, '{}'::text[])))),
                  '{}'::text[]),
         r.pages,                     -- what the role grants, for the admin UI
         coalesce(u.pages_denied, '{}'::text[]),
         r.hidden_columns,
         r.hidden_tables,
         u.scope_salespersons, u.scope_govs,
         (u.role_key = 'admin')
  from public.app_users u
  join public.app_roles r on r.role_key = u.role_key
  where u.user_id = auth.uid() and u.is_active;
$$;

grant execute on function public.app_me() to authenticated;

-- ===========================================================================
-- 4. Guard: an admin cannot lock themselves out of the admin page
-- ===========================================================================
-- 04_admin.sql already stops the admin ROLE losing the admin page. A denial
-- list is a second route to the same dead end, one person at a time.
create or replace function public.app_guard_admin_page()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if new.role_key = 'admin'
     and new.is_active
     and 'admin' = any (coalesce(new.pages_denied, '{}'::text[])) then
    raise exception 'Cannot deny the admin page to an administrator (%)', new.username;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_app_users_admin_page on public.app_users;
create trigger trg_app_users_admin_page
  before insert or update on public.app_users
  for each row execute function public.app_guard_admin_page();

-- ===========================================================================
-- 5. RLS — each table now also checks whether the role hid it
-- ===========================================================================
-- One extra predicate per policy. Because this is RLS, a hidden table returns
-- zero rows however it is reached: through an RPC, through PostgREST, through
-- a hand-written fetch in devtools.

drop policy if exists inv_lines_read  on public.dashboard_invoice_lines;
drop policy if exists customers_read  on public.dashboard_customers;
drop policy if exists products_read   on public.dashboard_products;
drop policy if exists stock_read      on public.dashboard_stock;
drop policy if exists stock_hist_read on public.dashboard_stock_history;

-- ⚠️ The ::text[] casts are required — see the long comment in 04_admin.sql
--    section 9. `any ((select f()))` is the SUBQUERY form and fails with
--    "operator does not exist: text = text[]".
create policy inv_lines_read on public.dashboard_invoice_lines
  for select to authenticated
  using (
    (select public.app_is_provisioned())
    and (select public.app_table_visible('dashboard_invoice_lines'))
    and ((select public.app_my_salespersons()) is null
         or salesperson = any ((select public.app_my_salespersons())::text[]))
    and ((select public.app_my_govs()) is null
         or gov = any ((select public.app_my_govs())::text[]))
  );

create policy customers_read on public.dashboard_customers
  for select to authenticated
  using (
    (select public.app_is_provisioned())
    and (select public.app_table_visible('dashboard_customers'))
    and ((select public.app_my_salespersons()) is null
         or salesperson = any ((select public.app_my_salespersons())::text[]))
    and ((select public.app_my_govs()) is null
         or governorate = any ((select public.app_my_govs())::text[]))
  );

create policy products_read on public.dashboard_products
  for select to authenticated
  using ((select public.app_is_provisioned())
         and (select public.app_table_visible('dashboard_products')));

create policy stock_read on public.dashboard_stock
  for select to authenticated
  using ((select public.app_is_provisioned())
         and (select public.app_table_visible('dashboard_stock')));

create policy stock_hist_read on public.dashboard_stock_history
  for select to authenticated
  using ((select public.app_is_provisioned())
         and (select public.app_table_visible('dashboard_stock_history')));

-- dashboard_excluded_products keeps its provisioning-only policy on purpose.
-- See the header: hiding a filter corrupts numbers instead of withholding them.

-- ===========================================================================
-- 6. Confirm
-- ===========================================================================
select 'new columns' as what,
       string_agg(table_name || '.' || column_name, ', ' order by column_name) as detail
from information_schema.columns
where table_schema = 'public'
  and (table_name, column_name) in
      (values ('app_roles','hidden_tables'), ('app_users','pages_denied'))
union all
select 'helpers',
       string_agg(routine_name, ', ' order by routine_name)
from information_schema.routines
where routine_schema = 'public'
  and routine_name in ('app_my_hidden_tables','app_table_visible','app_me')
union all
select '⚠️ NEXT STEP', 're-run 05_masking.sql, or hidden tables will read as 0 instead of blank';
