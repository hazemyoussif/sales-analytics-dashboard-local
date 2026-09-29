-- Dabboos Product Dashboard — register the Status page
-- Run in: Supabase -> SQL Editor. Safe to re-run (idempotent).
-- Run AFTER 06_bootstrap.sql.
--
-- ===========================================================================
-- WHY A NEW PAGE NEEDS A MIGRATION AT ALL
-- ===========================================================================
-- app_roles.pages is an explicit allow-list, and requireAuth() denies anything
-- not in it. Shipping status.html without this file gives a page that NOBODY
-- can open — including the admin, who would then have no way to grant it from
-- the admin UI either, because the checkbox reads from the same list.
--
-- Adding it to the two SYSTEM roles only. A custom role gets it when an admin
-- ticks the box: silently widening a restricted role's access because the
-- developers added a screen is exactly the kind of surprise this permission
-- model exists to prevent.

-- ===========================================================================
-- 1. Grant the page to the system roles
-- ===========================================================================
-- array_append only when absent, so re-running cannot produce
-- {overview,products,status,status,frozen}.
update public.app_roles
set pages = array_append(pages, 'status')
where role_key in ('admin', 'management')
  and not ('status' = any (pages));

-- ===========================================================================
-- 2. Confirm
-- ===========================================================================
-- `status?` must read `yes` for both rows. A `no` means the page is invisible
-- to that role and the nav link will not appear.
select role_key,
       array_to_string(pages, ', ') as pages,
       case when 'status' = any (pages) then 'yes' else '⚠️ no' end as "status?"
from public.app_roles
order by is_system desc, role_key;
