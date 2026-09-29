-- ===========================================================================
-- 54. REVOKE ... FROM anon, authenticated does not revoke anything
-- ===========================================================================
-- Files 50 and 51 both ended with a line I believed closed this:
--
--     revoke execute on function public.refresh_customer_class()
--       from anon, authenticated;
--
-- It does not. Postgres grants EXECUTE on every new function to PUBLIC by
-- default, and anon and authenticated inherit through PUBLIC. Revoking their
-- explicit grants leaves the inherited one untouched. The ACL says so plainly
-- once you know to read the first entry:
--
--     refresh_customer_class    =X/postgres  postgres=X  service_role=X
--                               ^^^ this is PUBLIC, and it still has EXECUTE
--
-- Verified with has_function_privilege() rather than by reading the ACL:
-- anon could execute all twelve SECURITY DEFINER maintenance functions,
-- including the three added in files 50 and 51.
--
-- WHY THIS MATTERS MORE THAN IT LOOKS. The anon key ships in
-- assets/js/config.js by design and is safe for READING -- RLS grants select
-- to authenticated only, and anon genuinely gets zero rows from every table
-- (checked: dashboard_invoice_lines, dashboard_customers and
-- dashboard_partner_mix_month all return 0 as anon).
--
-- But SECURITY DEFINER functions do not run as the caller. They run as their
-- owner and bypass RLS entirely. So the anon key could not read a single
-- invoice line, and could still:
--
--   refresh_partner_mix_month()   a ~90s rebuild of a 464,141-row table,
--                                 scanning the 348 MB invoice table twice,
--                                 on a 224 MB shared_buffers instance
--   refresh_dashboard_summaries() the whole nightly chain, on demand
--   prune_sync_runs()             delete the sync history
--   sync_record()                 write fabricated rows into it, so a failed
--                                 sync could be made to look successful
--
-- Called in a loop that is a denial of service against the dashboard, from a
-- key that is in the repository on purpose.
--
-- THE FIX IS `FROM PUBLIC`, not `FROM anon, authenticated`. Then grant back
-- explicitly, to the one role that actually calls each.
--
-- Nothing legitimate breaks:
--   the sync uses SUPABASE_SERVICE_KEY (sync/.env.example says so, and
--     config.py requires it), and service_role keeps its grant
--   file 24's concern was service_role's statement_timeout, not anon's
--     ability to execute -- re-read, it never wanted these public
--   app_log is called behind `if (!getSession()) return` and app_me through
--     rpc(), which treats a missing session as an auth failure -- both are
--     authenticated-only already, and keep an explicit grant
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Maintenance: service_role only
-- ---------------------------------------------------------------------------
-- The sync's jobs. No browser, signed in or not, has business firing these.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'refresh\_%' or p.proname in ('prune_sync_runs','sync_record'))
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
    execute format('grant  execute on function %s to service_role', r.sig);
    raise notice 'locked to service_role: %', r.sig;
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 2. Permission helpers: authenticated only
-- ---------------------------------------------------------------------------
-- These are SECURITY DEFINER because they read app_users, which the caller
-- cannot. They are also called from inside the RLS policies, which evaluate as
-- the querying role -- so `authenticated` genuinely needs EXECUTE and an
-- unqualified revoke would lock the dashboard out of its own data.
--
-- anon does not need them. An anon session has no app_users row to describe.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig, p.prorettype
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname like 'app\_%'
       and p.prorettype <> 'trigger'::regtype
  loop
    execute format('revoke execute on function %s from public, anon', r.sig);
    execute format('grant  execute on function %s to authenticated, service_role', r.sig);
    raise notice 'locked to authenticated: %', r.sig;
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 3. Trigger functions: nobody
-- ---------------------------------------------------------------------------
-- app_guard_admin_page, app_guard_last_admin, app_guard_system_role and
-- app_touch_updated_at return `trigger`. A trigger firing does not consult
-- EXECUTE privileges, so revoking costs nothing and removes them from the
-- surface the linter keeps flagging.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prorettype = 'trigger'::regtype
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
    raise notice 'trigger-only: %', r.sig;
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 4. Stop the next one being created wide open
-- ---------------------------------------------------------------------------
-- Every function above was born public. Default privileges are why, and
-- without this the next migration reopens the hole silently.
alter default privileges in schema public revoke execute on functions from public;


-- ---------------------------------------------------------------------------
-- 5. Proof, by privilege rather than by reading the ACL
-- ---------------------------------------------------------------------------
-- anon_can_run must be false on every row.
select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as fn,
       has_function_privilege('anon', p.oid, 'EXECUTE')          as anon_can_run,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_can_run,
       has_function_privilege('service_role', p.oid, 'EXECUTE')  as sync_can_run
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
order by 1;
