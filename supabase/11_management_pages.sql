-- Dabboos Product Dashboard — register the four management pages
-- Run in: Supabase -> SQL Editor. Safe to re-run (idempotent).
-- Run AFTER 09_returns_discounts.sql.
--
-- ===========================================================================
-- WHAT THIS FILE DOES, AND WHAT IT DELIBERATELY DOES NOT
-- ===========================================================================
-- It registers four pages management asked for:
--
--   customers   العملاء 80/20 — customer concentration by governorate and
--               sales department
--   agencies    التوكيلات — product 80/20 inside each agency, its geography,
--               and a top-customers × agencies cross-tab
--   debt        الديون — receivables, aging against each customer's own terms,
--               and credit-limit breaches
--   branches    المخازن — Basra and Mosul, including transfer suggestions
--
-- It does NOT create any read function. Three of the four pages need data the
-- project does not sync yet, so each page calls the RPC it WILL use, gets
-- "function does not exist" back, and draws clearly-marked demo rows instead
-- (assets/js/demo.js). The moment a function below exists with the right name
-- and arguments, that page switches to real data with no front-end change.
--
--   PAGE        FUNCTION IT LOOKS FOR      WHAT IT STILL NEEDS FROM ODOO
--   customers   customers_pareto           the sales-TEAM NAME. team_id is
--                                          already synced but only as a bare
--                                          id — the n8n mapper keeps
--                                          id0(r.team_id) and drops the label.
--                                          Confirm first that سوبرماركت وهايبر /
--                                          كرزات / الجملة / السلاسل really are
--                                          crm.team records and not partner
--                                          tags, or the page groups by the
--                                          wrong dimension.
--   agencies    agency_lines,              nothing — brand is on the invoice
--               agency_customer_matrix     line already. But it is set on only
--                                          ~64% of lines, so the unattributed
--                                          third must stay visible as its own
--                                          bucket.
--   debt        customer_receivables       invoice_date_due (exists on
--                                          account.invoice.report, simply not
--                                          in the sync's field list) and
--                                          amount_residual (needs a new sync
--                                          from account.move).
--   branches    branch_stock, branch_trend per-warehouse stock. dashboard_stock
--                                          holds qty_available, which is
--                                          COMPANY-WIDE — there is no location
--                                          in it at all. Needs a stock.quant
--                                          sync grouped by warehouse.
--
-- ===========================================================================
-- WHY A NEW PAGE NEEDS A MIGRATION AT ALL
-- ===========================================================================
-- app_roles.pages is an explicit allow-list and requireAuth() denies anything
-- not in it. Shipping these four HTML files without this migration produces
-- four pages NOBODY can open — including the admin, who could not grant them
-- from the admin UI either, because that checkbox reads the same list.
--
-- Granted to the two SYSTEM roles only. A custom role gets them when an admin
-- ticks the box. Silently widening a restricted role because the developers
-- added a screen is exactly the surprise this permission model exists to
-- prevent.

-- ===========================================================================
-- 1. Grant the pages to the system roles
-- ===========================================================================
-- array_append only when absent, so re-running cannot produce
-- {overview,customers,customers,debt}.
do $$
declare p text;
begin
  foreach p in array array['customers', 'agencies', 'debt', 'branches'] loop
    update public.app_roles
       set pages = array_append(pages, p)
     where role_key in ('admin', 'management')
       and not (p = any (pages));
  end loop;
end $$;

-- ===========================================================================
-- 2. AFTER RUNNING THIS: SIGN OUT AND BACK IN
-- ===========================================================================
-- app_me() is cached in the browser's sessionStorage for the tab's lifetime,
-- and sessionStorage survives a reload — including a hard reload. A tab that
-- was already open therefore keeps the page list it fetched when it opened,
-- and the four new links do not appear no matter how many times it is
-- refreshed. Sign out and back in, or open a new tab.
--
-- This is the single most likely reason for "I ran the SQL and nothing
-- changed".

-- ===========================================================================
-- 3. Confirm
-- ===========================================================================
-- Every column must read `yes` for admin and management. A `no` means that
-- page is invisible to the role and its nav link will not appear.
select role_key,
       case when 'customers' = any (pages) then 'yes' else '⚠️ no' end as "customers?",
       case when 'agencies'  = any (pages) then 'yes' else '⚠️ no' end as "agencies?",
       case when 'debt'      = any (pages) then 'yes' else '⚠️ no' end as "debt?",
       case when 'branches'  = any (pages) then 'yes' else '⚠️ no' end as "branches?",
       array_to_string(pages, ', ') as pages
from public.app_roles
order by is_system desc, role_key;
