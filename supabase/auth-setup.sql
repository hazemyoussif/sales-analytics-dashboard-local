-- ============================================================
-- Dabboos Sales Command Center — authentication & permissions
-- Run this ONCE in Supabase → SQL Editor.
--
-- What it does:
--   1. Creates `dash_users`  — one profile row per login (role + per-page permissions).
--   2. Creates `page_views`  — traffic log the admin panel reads.
--   3. Locks EVERY data table down with Row-Level Security so that
--      only logged-in, ACTIVE users can read data. The public anon
--      key alone can no longer read anything.
--
-- Roles:
--   admin       → all pages + admin panel (manage users, see traffic)
--   management  → all dashboard pages
--   alerts      → Alert Center only (the DB only lets them read alert rows)
--
-- ⚠️ ORDER OF OPERATIONS (avoid breaking the live dashboard):
--   1. Deploy the new dashboard code (login page etc.) first.
--   2. Run this script.
--    3. Create your own admin user (see BOOTSTRAP at the bottom).
--   Old clients still running pre-auth code will stop seeing data the
--   moment this script runs — that is the point of the lockdown.
--
-- Supabase Auth settings required (Dashboard → Authentication → Sign In/Up):
--   • "Allow new users to sign up"  = ON   (the admin panel creates users
--     via the signup endpoint; new signups start INACTIVE, so strangers
--     who sign up themselves get nothing until an admin activates them)
--   • "Confirm email"               = OFF  (usernames use synthetic
--     @dabboos.app addresses — no mailbox exists to confirm)
-- ============================================================

-- ------------------------------------------------------------
-- 1. Profile table
-- ------------------------------------------------------------
create table if not exists public.dash_users (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  username   text not null unique,
  full_name  text,
  role       text not null default 'alerts'
             check (role in ('admin', 'management', 'alerts')),
  -- Per-page overrides, e.g. {"regions": false}. Missing keys fall back
  -- to the role's defaults (defined in assets/js/auth.js).
  pages      jsonb not null default '{}'::jsonb,
  -- New users start INACTIVE: they can log in but see no data until an
  -- admin activates them from the admin panel.
  is_active  boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Auto-create a profile whenever an auth user is created.
create or replace function public.handle_new_dash_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.dash_users (user_id, username, full_name, role, is_active)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'username', ''), split_part(new.email, '@', 1)),
    nullif(new.raw_user_meta_data ->> 'full_name', ''),
    case
      when (new.raw_user_meta_data ->> 'role') in ('admin', 'management', 'alerts')
        then new.raw_user_meta_data ->> 'role'
      else 'alerts'
    end,
    false  -- always inactive until an admin flips the switch
  )
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_dash on auth.users;
create trigger on_auth_user_created_dash
  after insert on auth.users
  for each row execute function public.handle_new_dash_user();

-- Backfill: profiles for auth users created BEFORE the trigger existed
-- (idempotent — safe to re-run).
insert into public.dash_users (user_id, username, full_name, role, is_active)
select id, split_part(email, '@', 1), null, 'alerts', false
from auth.users
on conflict (user_id) do nothing;

-- ------------------------------------------------------------
-- 2. Traffic log
-- ------------------------------------------------------------
create table if not exists public.page_views (
  id        bigint generated always as identity primary key,
  user_id   uuid references auth.users (id) on delete set null,
  username  text,
  page      text not null,
  lang      text,
  ua        text,
  viewed_at timestamptz not null default now()
);
create index if not exists page_views_viewed_at_idx on public.page_views (viewed_at desc);

-- ------------------------------------------------------------
-- 3. Who-acknowledged-what (optional columns on the existing table)
-- ------------------------------------------------------------
alter table public.alert_acks add column if not exists acked_by uuid;
alter table public.alert_acks add column if not exists acked_by_name text;

-- ------------------------------------------------------------
-- 4. Helper: the caller's active role (NULL when logged out / inactive)
--    SECURITY DEFINER so it can read dash_users without recursing into RLS.
-- ------------------------------------------------------------
create or replace function public.dash_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.dash_users
  where user_id = auth.uid() and is_active
$$;

-- ------------------------------------------------------------
-- 5. Row-Level Security — wipe old policies, install the new set
-- ------------------------------------------------------------
do $$
declare p record;
begin
  for p in
    select policyname, tablename from pg_policies
    where schemaname = 'public'
      and tablename in ('dashboard_orders', 'dashboard_payments',
                        'dashboard_snapshots', 'dashboard_customers',
                        'dashboard_monthly', 'alert_acks',
                        'dash_users', 'page_views', 'salespeople')
  loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;

alter table public.dashboard_orders    enable row level security;
alter table public.dashboard_payments  enable row level security;
alter table public.dashboard_snapshots enable row level security;
alter table public.dashboard_customers enable row level security;
alter table public.dashboard_monthly   enable row level security;
alter table public.alert_acks          enable row level security;
alter table public.dash_users          enable row level security;
alter table public.page_views          enable row level security;

-- Belt and braces: the anon key gets no table privileges at all.
revoke all on public.dashboard_orders    from anon;
revoke all on public.dashboard_payments  from anon;
revoke all on public.dashboard_snapshots from anon;
revoke all on public.dashboard_customers from anon;
revoke all on public.dashboard_monthly   from anon;
revoke all on public.alert_acks          from anon;
revoke all on public.dash_users          from anon;
revoke all on public.page_views          from anon;
grant select                 on public.dashboard_orders,
                                public.dashboard_payments,
                                public.dashboard_snapshots,
                                public.dashboard_customers,
                                public.dashboard_monthly to authenticated;
grant select, insert         on public.alert_acks, public.page_views to authenticated;
grant select, update         on public.dash_users to authenticated;

-- dashboard_orders: management sees everything; alerts-only users can
-- ONLY read rows that are actual alerts (this is enforced by the DB,
-- not just hidden in the UI).
create policy orders_read on public.dashboard_orders
  for select to authenticated
  using (
    public.dash_role() in ('admin', 'management')
    or (public.dash_role() = 'alerts' and level in ('critical', 'warning'))
  );

-- payments & snapshots: management and admin only.
create policy payments_read on public.dashboard_payments
  for select to authenticated
  using (public.dash_role() in ('admin', 'management'));

create policy snapshots_read on public.dashboard_snapshots
  for select to authenticated
  using (public.dash_role() in ('admin', 'management'));

create policy customers_read on public.dashboard_customers
  for select to authenticated
  using (public.dash_role() in ('admin', 'management'));

create policy monthly_read on public.dashboard_monthly
  for select to authenticated
  using (public.dash_role() in ('admin', 'management'));

-- alert acknowledgements: any active user can read and write.
create policy acks_read on public.alert_acks
  for select to authenticated
  using (public.dash_role() is not null);

create policy acks_insert on public.alert_acks
  for insert to authenticated
  with check (public.dash_role() is not null);

-- profiles: everyone reads their own row (even while inactive, so the
-- login page can say "account disabled"); admins read & edit everyone.
create policy users_self_read on public.dash_users
  for select to authenticated
  using (user_id = auth.uid());

create policy users_admin_read on public.dash_users
  for select to authenticated
  using (public.dash_role() = 'admin');

create policy users_admin_update on public.dash_users
  for update to authenticated
  using (public.dash_role() = 'admin')
  with check (public.dash_role() = 'admin');

-- traffic: any active user logs their own views; only admins read them.
create policy views_insert on public.page_views
  for insert to authenticated
  with check (user_id = auth.uid() and public.dash_role() is not null);

create policy views_admin_read on public.page_views
  for select to authenticated
  using (public.dash_role() = 'admin');

-- ============================================================
-- BOOTSTRAP — create YOUR admin account (do this right after running
-- the script above):
--
--   1. Supabase Dashboard → Authentication → Users → "Add user"
--        email:    ahmed@dabboos.app     (username = the part before @)
--        password: <choose a strong one>
--        ✔ Auto Confirm User
--
--   2. Promote it (SQL Editor):
--
--        update public.dash_users
--        set role = 'admin', is_active = true, full_name = 'Ahmed Gomma'
--        where username = 'ahmed';
--
--   3. Log in at <your-site>/login.html with username "ahmed".
--      Every other user can then be created from the admin panel.
--
-- Sanity checks:
--   select username, role, is_active from public.dash_users;
--   select * from pg_policies where schemaname = 'public';
-- ============================================================
