-- Dabboos Product Dashboard — admin, roles and permissions
-- Run in: Supabase -> SQL Editor. Safe to re-run (idempotent).
-- Run AFTER 01_schema.sql, 02_functions.sql and 03_exclusions.sql.
--
-- ===========================================================================
-- WHAT THIS FILE DOES
-- ===========================================================================
-- Until now RLS said `using (true)`: a login was all-or-nothing. This file
-- replaces that with a role + scope model:
--
--   app_roles     which PAGES a role sees, which COLUMNS it may not see
--   app_users     which ROLE a person has, and which SALESPERSONS/GOVERNORATES
--   app_activity  logins and page views
--
-- ===========================================================================
-- WHY ENFORCEMENT IS HERE AND NOT IN JAVASCRIPT
-- ===========================================================================
-- The anon key ships in assets/js/config.js and any signed-in user can read
-- their own JWT out of localStorage. Hiding a page or a column in the browser
-- stops nobody who opens devtools. Anything that must actually be secret is
-- enforced in this file.
--
-- ===========================================================================
-- WHY SCOPING ONE TABLE SCOPES THE WHOLE DASHBOARD
-- ===========================================================================
-- Every RPC (product_facts, filter_options, data_health, product_customers,
-- product_regions, product_trend, revenue_adjustments) is SECURITY INVOKER.
-- RLS on the base tables therefore applies INSIDE the function body. One
-- policy on dashboard_invoice_lines scopes every page at once, and no page
-- needs filtering code of its own.
--
-- A welcome side effect: a Basra-scoped user's governorate dropdown contains
-- only Basra, because filter_options() is built from the rows they can see.
--
-- ===========================================================================
-- WHY EVERY HELPER CALL IN A POLICY IS WRAPPED IN (select ...)
-- ===========================================================================
-- A bare function call in a USING clause is evaluated once PER ROW. Wrapped in
-- a scalar subquery, Postgres hoists it into a once-per-query InitPlan. On
-- 33k+ invoice lines a month that difference is the entire performance story.
-- Do not "simplify" the (select ...) wrappers away.

-- ===========================================================================
-- 1. Roles
-- ===========================================================================
-- A role owns two things: the pages it can open, and the columns it must not
-- see. Scope (which salespersons / governorates) lives on the USER, not here,
-- so one "Salesperson" role can serve ten people who each see only themselves.
create table if not exists public.app_roles (
  role_key       text primary key,
  name_ar        text not null,
  name_en        text not null,
  -- subset of: overview, products, frozen, reorder, admin
  pages          text[] not null default '{}',
  -- subset of: margin, cost, revenue, stock_value, customers
  hidden_columns text[] not null default '{}',
  -- admin and management. Cannot be deleted or renamed; see the trigger below.
  is_system      boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- ===========================================================================
-- 2. Users
-- ===========================================================================
-- One row per person who may sign in. A user with NO row here is DENIED, not
-- granted — so an account created straight from the Supabase dashboard cannot
-- sidestep this system. 06_bootstrap.sql backfills the existing logins so
-- nobody is locked out when this ships.
create table if not exists public.app_users (
  user_id            uuid primary key references auth.users(id) on delete cascade,
  username           text not null unique,
  display_name       text,
  role_key           text not null references public.app_roles(role_key) on update cascade,

  -- NULL means ALL. An empty array means NOTHING.
  -- This asymmetry is deliberate: an admin who assigns a role but forgets the
  -- scope gets a user who sees everything — obviously wrong at a glance —
  -- rather than a user who sees nothing, which looks like a broken dashboard.
  scope_salespersons text[],
  scope_govs         text[],

  -- Denies access without destroying the login or the activity history.
  is_active          boolean not null default true,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  last_seen_at       timestamptz
);

create index if not exists idx_app_users_role on public.app_users (role_key);

-- ===========================================================================
-- 3. Activity
-- ===========================================================================
create table if not exists public.app_activity (
  id         bigserial primary key,
  user_id    uuid references auth.users(id) on delete cascade,
  kind       text not null check (kind in ('login', 'page')),
  page       text,
  at         timestamptz not null default now(),
  user_agent text
);

create index if not exists idx_app_activity_user on public.app_activity (user_id, at desc);
create index if not exists idx_app_activity_at   on public.app_activity (at desc);

-- ===========================================================================
-- 4. Permission helpers
-- ===========================================================================
-- SECURITY DEFINER with a pinned search_path. The security-definer part is
-- what lets a policy ON app_users read app_users without infinite recursion;
-- the pinned search_path is what stops a caller from shadowing `public` with
-- a temp schema and having these resolve to tables of their own making.

create or replace function public.app_is_provisioned()
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.app_users u
    where u.user_id = auth.uid() and u.is_active
  );
$$;

create or replace function public.app_is_admin()
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.app_users u
    where u.user_id = auth.uid() and u.is_active and u.role_key = 'admin'
  );
$$;

-- NULL means unrestricted. Callers must test `is null` BEFORE testing
-- membership: `x = any(null)` yields NULL, not false, and a NULL in a USING
-- clause filters the row out — which would silently give an unscoped user
-- zero rows instead of every row.
create or replace function public.app_my_salespersons()
returns text[]
language sql stable security definer set search_path = public, pg_temp
as $$
  select u.scope_salespersons from public.app_users u
  where u.user_id = auth.uid() and u.is_active;
$$;

create or replace function public.app_my_govs()
returns text[]
language sql stable security definer set search_path = public, pg_temp
as $$
  select u.scope_govs from public.app_users u
  where u.user_id = auth.uid() and u.is_active;
$$;

-- Always an array, never NULL — an unprovisioned user gets '{}' here, but the
-- RLS policies have already denied them every row, so it never matters.
create or replace function public.app_my_hidden_columns()
returns text[]
language sql stable security definer set search_path = public, pg_temp
as $$
  select coalesce(
    (select r.hidden_columns
       from public.app_users u
       join public.app_roles r on r.role_key = u.role_key
      where u.user_id = auth.uid() and u.is_active),
    '{}'::text[]);
$$;

-- Used by 05_masking.sql inside the RPCs.
create or replace function public.app_can_col(p_col text)
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select not (p_col = any (public.app_my_hidden_columns()));
$$;

-- ===========================================================================
-- 5. app_me — the caller's identity and permissions, for the front end
-- ===========================================================================
-- Returns ZERO rows for an unprovisioned or deactivated user. The front end
-- treats that as "account not provisioned", never as "no data" — the same
-- distinction api.js already draws between an auth failure and an empty
-- result.
--
-- ⚠️ 07_tables_and_overrides.sql REPLACES this function with a wider one that
--    also returns role_pages, pages_denied and hidden_tables. Re-running THIS
--    file afterwards downgrades it back to the narrow shape, and the front end
--    then stops knowing which tables are hidden — so a restricted page renders
--    zeros instead of "data unavailable". The data itself stays protected
--    (RLS reads app_roles directly, not app_me), but the screen starts lying.
--    If you re-run this file, re-run 07 immediately afterwards.
create or replace function public.app_me()
returns table (
  user_id            uuid,
  username           text,
  display_name       text,
  role_key           text,
  role_name_ar       text,
  role_name_en       text,
  pages              text[],
  hidden_columns     text[],
  scope_salespersons text[],
  scope_govs         text[],
  is_admin           boolean
)
language sql stable security definer set search_path = public, pg_temp
as $$
  select u.user_id, u.username, u.display_name, u.role_key,
         r.name_ar, r.name_en, r.pages, r.hidden_columns,
         u.scope_salespersons, u.scope_govs,
         (u.role_key = 'admin')
  from public.app_users u
  join public.app_roles r on r.role_key = u.role_key
  where u.user_id = auth.uid() and u.is_active;
$$;

-- The scoped RLS policies below call these in the context of the QUERYING role,
-- so `authenticated` must be able to execute them. New functions grant EXECUTE
-- to PUBLIC by default, but that default is one hardening step away from being
-- revoked project-wide — at which point every policy would start erroring and
-- the dashboard would go blank for everyone. Grant explicitly.
grant execute on function public.app_me()                to authenticated;
grant execute on function public.app_can_col(text)       to authenticated;
grant execute on function public.app_is_provisioned()    to authenticated;
grant execute on function public.app_is_admin()          to authenticated;
grant execute on function public.app_my_salespersons()   to authenticated;
grant execute on function public.app_my_govs()           to authenticated;
grant execute on function public.app_my_hidden_columns() to authenticated;

-- ===========================================================================
-- 6. app_log — activity tracking
-- ===========================================================================
-- SECURITY DEFINER so the caller can only ever log AS THEMSELVES: the user_id
-- is taken from auth.uid() and is not a parameter. A client cannot forge
-- activity for another account.
create or replace function public.app_log(p_kind text, p_page text default null)
returns void
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then return; end if;
  if p_kind not in ('login', 'page') then return; end if;

  insert into public.app_activity (user_id, kind, page, user_agent)
  values (auth.uid(), p_kind, left(p_page, 64),
          left(current_setting('request.headers', true)::json ->> 'user-agent', 200));

  update public.app_users set last_seen_at = now() where user_id = auth.uid();
exception when others then
  -- Tracking must never break a page. A failed log is a lost row, not an error
  -- on someone's dashboard.
  return;
end;
$$;

grant execute on function public.app_log(text, text) to authenticated;

-- ===========================================================================
-- 7. Guards that RLS cannot express
-- ===========================================================================
-- Locking yourself out is a one-click mistake with no self-service recovery:
-- with no admin left, nobody can reach the admin page to appoint one, and the
-- fix is a manual SQL session. Hence a hard stop rather than a UI warning.
create or replace function public.app_guard_last_admin()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare n_admins int;
begin
  select count(*) into n_admins
  from public.app_users where role_key = 'admin' and is_active;

  if tg_op = 'DELETE' then
    if old.role_key = 'admin' and old.is_active and n_admins <= 1 then
      raise exception 'Cannot delete the last admin';
    end if;
    return old;
  end if;

  -- demoted, or deactivated, while being the only one left
  if old.role_key = 'admin' and old.is_active
     and (new.role_key <> 'admin' or not new.is_active)
     and n_admins <= 1 then
    raise exception 'Cannot remove the last admin';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_app_users_last_admin on public.app_users;
create trigger trg_app_users_last_admin
  before update or delete on public.app_users
  for each row execute function public.app_guard_last_admin();

-- System roles are referenced by name in the helpers above and in the front
-- end. Renaming or deleting one would break permission checks silently.
create or replace function public.app_guard_system_role()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    if old.is_system then raise exception 'Cannot delete a system role (%)', old.role_key; end if;
    return old;
  end if;
  if old.is_system and new.role_key <> old.role_key then
    raise exception 'Cannot rename a system role (%)', old.role_key;
  end if;
  -- The admin role must always keep the admin page, or nobody can get back in.
  if new.role_key = 'admin' and not ('admin' = any (new.pages)) then
    raise exception 'The admin role must retain the admin page';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_app_roles_system on public.app_roles;
create trigger trg_app_roles_system
  before update or delete on public.app_roles
  for each row execute function public.app_guard_system_role();

create or replace function public.app_touch_updated_at()
returns trigger
language plpgsql set search_path = public, pg_temp
as $$
begin new.updated_at = now(); return new; end;
$$;

drop trigger if exists trg_app_users_touch on public.app_users;
create trigger trg_app_users_touch before update on public.app_users
  for each row execute function public.app_touch_updated_at();

drop trigger if exists trg_app_roles_touch on public.app_roles;
create trigger trg_app_roles_touch before update on public.app_roles
  for each row execute function public.app_touch_updated_at();

-- ===========================================================================
-- 8. RLS on the admin tables themselves
-- ===========================================================================
alter table public.app_roles    enable row level security;
alter table public.app_users    enable row level security;
alter table public.app_activity enable row level security;

drop policy if exists roles_read      on public.app_roles;
drop policy if exists roles_admin_ins on public.app_roles;
drop policy if exists roles_admin_upd on public.app_roles;
drop policy if exists roles_admin_del on public.app_roles;

-- Role definitions are not secret — a user needs their own to know which nav
-- items to draw, and the admin page needs all of them.
create policy roles_read on public.app_roles
  for select to authenticated using (true);
create policy roles_admin_ins on public.app_roles
  for insert to authenticated with check ((select public.app_is_admin()));
create policy roles_admin_upd on public.app_roles
  for update to authenticated
  using ((select public.app_is_admin()))
  with check ((select public.app_is_admin()));
create policy roles_admin_del on public.app_roles
  for delete to authenticated using ((select public.app_is_admin()));

drop policy if exists users_read      on public.app_users;
drop policy if exists users_admin_upd on public.app_users;
drop policy if exists users_admin_del on public.app_users;

-- Your own row, or everything if you are an admin.
create policy users_read on public.app_users
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.app_is_admin()));

-- Admins edit role, scope, display name and is_active straight through
-- PostgREST. There is deliberately NO insert policy: creating a user means
-- creating an auth.users row too, which needs the service_role key and
-- therefore the admin-users Edge Function.
create policy users_admin_upd on public.app_users
  for update to authenticated
  using ((select public.app_is_admin()))
  with check ((select public.app_is_admin()));
create policy users_admin_del on public.app_users
  for delete to authenticated using ((select public.app_is_admin()));

drop policy if exists activity_read on public.app_activity;
drop policy if exists activity_ins  on public.app_activity;

create policy activity_read on public.app_activity
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.app_is_admin()));
-- app_log() is SECURITY DEFINER and bypasses this, but a direct insert must
-- still be unable to forge another user's activity.
create policy activity_ins on public.app_activity
  for insert to authenticated with check (user_id = (select auth.uid()));

grant select on public.app_roles    to authenticated;
grant insert, update, delete on public.app_roles to authenticated;
grant select on public.app_users    to authenticated;
grant update, delete on public.app_users to authenticated;
grant select, insert on public.app_activity to authenticated;
grant usage, select on sequence public.app_activity_id_seq to authenticated;

-- ===========================================================================
-- 9. Scoped RLS on the data tables — replaces the `using (true)` policies
-- ===========================================================================
-- ⚠️ These supersede the policies created at the bottom of 01_schema.sql.
--    Re-running that file would silently restore `using (true)` and hand every
--    user the whole company. If you ever do re-run it, re-run this section.

drop policy if exists inv_lines_read  on public.dashboard_invoice_lines;
drop policy if exists customers_read  on public.dashboard_customers;
drop policy if exists products_read   on public.dashboard_products;
drop policy if exists stock_read      on public.dashboard_stock;
drop policy if exists stock_hist_read on public.dashboard_stock_history;
drop policy if exists excluded_read   on public.dashboard_excluded_products;

-- ---------------------------------------------------------------------------
-- ⚠️ THE ::text[] CASTS BELOW ARE REQUIRED. DO NOT REMOVE THEM.
-- ---------------------------------------------------------------------------
-- `x = ANY (...)` has two different meanings in Postgres, chosen by grammar:
--
--     x = ANY (<select statement>)   -> SUBQUERY form: compare x to each ROW
--     x = ANY (<array expression>)   -> ARRAY form:    compare x to each ELEMENT
--
-- The helpers return text[], and the (select ...) wrapper is there to force an
-- InitPlan. But a bare `any ((select f()))` is literally a select statement in
-- parentheses, so Postgres picks the SUBQUERY form and tries to compare a text
-- column against a text[] row:
--
--     ERROR: operator does not exist: text = text[]
--
-- Casting turns the parenthesised select into an EXPRESSION, which selects the
-- array form. The cast is doing grammar work, not type work — which is exactly
-- why it looks redundant and gets deleted. It is not redundant.
-- ---------------------------------------------------------------------------

-- The one policy that scopes the entire dashboard.
create policy inv_lines_read on public.dashboard_invoice_lines
  for select to authenticated
  using (
    (select public.app_is_provisioned())
    and ((select public.app_my_salespersons()) is null
         or salesperson = any ((select public.app_my_salespersons())::text[]))
    and ((select public.app_my_govs()) is null
         or gov = any ((select public.app_my_govs())::text[]))
  );

-- Customers carry their own salesperson and governorate, so a scoped user must
-- not be able to read the customer list for territories they cannot see.
create policy customers_read on public.dashboard_customers
  for select to authenticated
  using (
    (select public.app_is_provisioned())
    and ((select public.app_my_salespersons()) is null
         or salesperson = any ((select public.app_my_salespersons())::text[]))
    and ((select public.app_my_govs()) is null
         or governorate = any ((select public.app_my_govs())::text[]))
  );

-- The catalogue tables are not territorial: a product is a product. They are
-- gated on provisioning only. What a scoped user learns from them is the
-- product list and current stock, never who sold what or where.
create policy products_read on public.dashboard_products
  for select to authenticated using ((select public.app_is_provisioned()));
create policy stock_read on public.dashboard_stock
  for select to authenticated using ((select public.app_is_provisioned()));
create policy stock_hist_read on public.dashboard_stock_history
  for select to authenticated using ((select public.app_is_provisioned()));
create policy excluded_read on public.dashboard_excluded_products
  for select to authenticated using ((select public.app_is_provisioned()));

-- Supports the salesperson/gov predicates the policy above adds to every scan.
create index if not exists idx_inv_lines_rep on public.dashboard_invoice_lines (salesperson);
create index if not exists idx_inv_lines_gov on public.dashboard_invoice_lines (gov);

-- ===========================================================================
-- 10. Confirm
-- ===========================================================================
select 'tables' as what,
       string_agg(table_name, ', ' order by table_name) as detail
from information_schema.tables
where table_schema = 'public' and table_name in ('app_roles','app_users','app_activity')
union all
select 'helpers',
       string_agg(routine_name, ', ' order by routine_name)
from information_schema.routines
where routine_schema = 'public' and routine_name like 'app!_%' escape '!'
union all
select 'scoped policies',
       string_agg(tablename || '.' || policyname, ', ' order by tablename)
from pg_policies
where schemaname = 'public'
  and policyname in ('inv_lines_read','customers_read','products_read',
                     'stock_read','stock_hist_read','excluded_read');
