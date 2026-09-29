-- ===========================================================================
-- 75. Expiry is its own page
-- ===========================================================================
-- 74 put the expiry view on the Warehouses page as a card. The client asked
-- for a separate page (expiry.html / assets/js/pages/expiry.js). No data
-- change -- dashboard_product_expiry, expiry_totals and expiry_report are
-- exactly as 74 left them. This only grants the new page key.
--
-- app_roles.pages is text[]; every role that can see 'warehouses' gets
-- 'expiry' too. Idempotent.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

update public.app_roles
set pages = array_append(pages, 'expiry')
where 'warehouses' = any (pages)
  and not ('expiry' = any (pages));

select role_key, pages from public.app_roles order by role_key;
