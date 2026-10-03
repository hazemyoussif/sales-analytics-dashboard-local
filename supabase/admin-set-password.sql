-- ============================================================
-- Admin "Set password" — run ONCE in Supabase → SQL Editor.
--
-- Lets a logged-in ADMIN set any dashboard user's password from the Admin
-- panel, WITHOUT the service_role key ever touching the browser (golden rule
-- #2). The page calls this function over PostgREST RPC with the admin's own
-- JWT; the function runs SECURITY DEFINER (as the table owner), so it can write
-- auth.users — but ONLY after verifying the caller is an active admin.
--
-- Passwords stay one-way hashed (bcrypt via pgcrypto's crypt/gen_salt), exactly
-- like Supabase Auth stores them — nothing is ever readable.
-- ============================================================

-- pgcrypto provides crypt() + gen_salt(). On Supabase it lives in the
-- `extensions` schema; create it there if it's somehow missing (no-op if it
-- already exists in any schema).
create extension if not exists pgcrypto with schema extensions;

create or replace function public.dash_set_password(target_id uuid, new_password text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  -- Only an ACTIVE admin may set passwords. dash_role() reads the CALLER's
  -- role from their JWT (auth.uid()), unaffected by SECURITY DEFINER.
  if (select public.dash_role()) is distinct from 'admin' then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if new_password is null or length(new_password) < 6 then
    raise exception 'password too short (min 6)' using errcode = '22023';
  end if;

  -- Only allow targeting real dashboard users (not arbitrary auth rows).
  if not exists (select 1 from public.dash_users where user_id = target_id) then
    raise exception 'unknown dashboard user' using errcode = 'P0002';
  end if;

  update auth.users
     set encrypted_password = crypt(new_password, gen_salt('bf', 10)),
         updated_at         = now()
   where id = target_id;

  return 'ok';
end;
$$;

-- The anon key must not be able to call this; only authenticated sessions
-- (the function itself re-checks admin). Owner stays whoever ran this script
-- (postgres in the SQL Editor), which is what lets it write auth.users.
revoke all on function public.dash_set_password(uuid, text) from public, anon;
grant execute on function public.dash_set_password(uuid, text) to authenticated;

-- ============================================================
-- Verify (as an admin, from the Admin panel or SQL as the admin's role):
--   select public.dash_set_password('<user_uuid>', 'NewPass123');
-- Then log in as that user with the new password.
-- A non-admin caller gets: ERROR 42501 not authorized.
-- ============================================================
