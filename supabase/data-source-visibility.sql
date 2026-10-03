-- ============================================================
-- dash_settings — small key/value store for admin-controlled, GLOBAL
-- dashboard settings. First use: "hidden_sources" — which raw source
-- tables are hidden from the dashboard (whole panels fed by them are
-- hidden for every user).
--
-- Run ONCE in the Supabase SQL editor. Safe/idempotent. The dashboard
-- degrades gracefully if this is not run yet (everything stays visible),
-- so the code can be deployed before or after this script.
--
-- RLS: every logged-in user READS settings (so the hide takes effect for
-- all); only ADMINS may WRITE. Reuses public.dash_role() from
-- supabase/auth-setup.sql.
-- ============================================================
create table if not exists public.dash_settings (
  key        text primary key,
  value      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.dash_settings enable row level security;
revoke all on public.dash_settings from anon;
grant select, insert, update on public.dash_settings to authenticated;

drop policy if exists dash_settings_read on public.dash_settings;
create policy dash_settings_read on public.dash_settings
  for select to authenticated
  using (true);

drop policy if exists dash_settings_write on public.dash_settings;
create policy dash_settings_write on public.dash_settings
  for all to authenticated
  using ((select public.dash_role()) = 'admin')
  with check ((select public.dash_role()) = 'admin');

-- seed the single row the dashboard PATCHes (so writers never need upsert)
insert into public.dash_settings (key, value)
  values ('hidden_sources', '{"tables": []}'::jsonb)
  on conflict (key) do nothing;
