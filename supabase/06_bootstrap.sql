  -- Dabboos Product Dashboard — permission bootstrap
  -- Run in: Supabase -> SQL Editor. Safe to re-run.
  -- Run AFTER 04_admin.sql and 05_masking.sql.
  --
  -- ===========================================================================
  -- ⚠️ EDIT ONE LINE BEFORE RUNNING
  -- ===========================================================================
  -- Find `v_admin_username` in section 3 and set it to YOUR login — the name you
  -- type on the sign-in screen, without the @dabboos.app part.
  --
  -- Edit that ONE line by hand. Do not use replace-all: the name is meant to
  -- appear exactly once, and a stray second copy is how this file rejects the
  -- very username you gave it.
  --
  -- The first admin cannot be created from the admin page: reaching that page
  -- requires already being an admin. This file is the way in.
  --
  -- ===========================================================================
  -- WHY THE BACKFILL MATTERS
  -- ===========================================================================
  -- 04_admin.sql made the data tables default-deny: no app_users row means no
  -- rows, on every page. Everyone who can sign in today has no app_users row
  -- yet. Without section 2 below, shipping this locks out the entire company —
  -- and it would look like a data outage, not a permissions change.

  -- ===========================================================================
  -- 1. The two system roles
  -- ===========================================================================
  -- `admin` sees everything including the admin page. `management` is the same
  -- minus the admin page — the default everyone lands on.
  --
  -- on conflict ... do update keeps this re-runnable AND repairs a system role
  -- that was edited into a broken state (e.g. the admin page removed from admin).
  insert into public.app_roles (role_key, name_ar, name_en, pages, hidden_columns, is_system)
  values
    ('admin', 'مدير النظام', 'Administrator',
    array['overview','products','frozen','reorder','admin'], '{}', true),
    ('management', 'الإدارة', 'Management',
    array['overview','products','frozen','reorder'], '{}', true)
  on conflict (role_key) do update
    set name_ar        = excluded.name_ar,
        name_en        = excluded.name_en,
        pages          = excluded.pages,
        hidden_columns = excluded.hidden_columns,
        is_system      = true;

  -- ===========================================================================
  -- 2. Backfill every existing login as management
  -- ===========================================================================
  -- `do nothing` on conflict, so re-running never demotes an admin back to
  -- management or resets a scope someone has already configured.
  insert into public.app_users (user_id, username, display_name, role_key)
  select u.id,
        split_part(u.email, '@', 1),
        coalesce(u.raw_user_meta_data ->> 'display_name',
                  split_part(u.email, '@', 1)),
        'management'
  from auth.users u
  where u.email is not null
  on conflict (user_id) do nothing;

  -- ===========================================================================
  -- 3. Promote the first admin  ← EDIT THE USERNAME HERE
  -- ===========================================================================
  -- The username appears exactly ONCE in this block, on the line below. An
  -- earlier version also named it in a "did you edit this?" guard, which meant
  -- a replace-all helpfully rewrote the guard too and rejected the very name it
  -- was given. There is no guard now: getting it wrong lands in the "No user
  -- named ..." branch, which prints every existing login, and that is a better
  -- error than the guard ever was.
  do $$
  declare
    v_admin_username text := 'Gomaa';   -- <<<< your login. THE ONLY LINE TO EDIT.
    v_user_id uuid;
  begin
    -- Matched case-insensitively: the username comes from the email local part,
    -- which Supabase stores lowercased, so a login typed as "Gomaa" is stored
    -- as "gomaa" and an exact match would miss it.
    select user_id into v_user_id
    from public.app_users
    where lower(username) = lower(trim(v_admin_username));

    if v_user_id is null then
      raise exception
        'No user named "%". Existing logins: %',
        v_admin_username,
        coalesce((select string_agg(username, ', ' order by username)
                  from public.app_users),
                 '(none — section 2 found no accounts in auth.users)');
    end if;

    update public.app_users
    set role_key = 'admin', is_active = true
    where user_id = v_user_id;

    raise notice 'User "%" is now an administrator.', v_admin_username;
  end $$;

  -- ===========================================================================
  -- 4. Confirm
  -- ===========================================================================
  -- Read this output before signing out. If `admins` is 0 you are locked out of
  -- the admin page and section 3 did not do what you expected.
  select 'roles' as what, count(*)::text as n,
        string_agg(role_key, ', ' order by role_key) as detail
  from public.app_roles
  union all
  select 'users', count(*)::text,
        string_agg(username || ' → ' || role_key, ', ' order by username)
  from public.app_users
  union all
  select 'admins', count(*)::text,
        coalesce(string_agg(username, ', ' order by username), '⚠️ NONE — you are locked out')
  from public.app_users where role_key = 'admin' and is_active;
