-- ===========================================================================
-- 52. Nine pages removed, four tables dropped
-- ===========================================================================
-- A product decision, not a performance one, and the distinction matters
-- because it is easy to mistake this file for a fix.
--
-- Overview and Customers 80/20 are the two pages that get used. The other
-- nine -- products, status, returns, discounts, agencies, debt, branches,
-- frozen, reorder -- were dropped along with the data that fed only them.
--
-- WHAT THIS DOES NOT DO: STOP THE TIMEOUTS.
--
-- Measured before writing this, the four tables dropped here are:
--
--   dashboard_branch_sales     5,312 kB
--   dashboard_receivables        632 kB
--   dashboard_branch_stock       320 kB
--   dashboard_branch_revenue      32 kB
--   ------------------------------------
--   total                     ~6,300 kB   of a 401 MB database -- 1.6%
--
-- while dashboard_invoice_lines is 348 MB, 85.7% of the database, and BOTH
-- surviving pages still read it:
--
--   Overview          product_facts scans it whenever p_salesperson or
--                     p_customer is set. File 47 pushed category and brand
--                     onto the catalogue; those two it could not.
--   Customers 80/20   customers_pareto scans it for p_category / p_agency,
--                     measured at 11,175 ms against a 20 s cap.
--
-- Deleting the branches and debt tables does not touch either path. The
-- Arabic timeout banner comes back on the next category filter. The fix for
-- that is file 53's dashboard_partner_mix_month, and nothing in this file
-- substitutes for it.
--
-- WHAT IT IS GOOD FOR: nine pages' worth of RPCs no longer compete for a
-- 224 MB shared_buffers, and there is less surface to keep correct.
--
-- dashboard_stock_history IS DELIBERATELY KEPT. frozen and reorder were its
-- only readers, so by the rule applied to everything else it should go too.
-- It does not, because it is the one table here that cannot be rebuilt.
-- Every other dropped table is a projection of Odoo's current state and
-- comes back by re-running its sync job. dashboard_stock_history is 21 daily
-- snapshots, and there is no query against Odoo that recovers what was on
-- the shelf on a date that has already passed. Deleting it destroys the only
-- copy. It costs 3 MB to keep, which is 0.7% of the database, and the sync
-- job that appends to it still runs so the series stays unbroken.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.
--
-- REVERSING THIS: the pages are in git. Per page, restore its .html, its
-- assets/js/pages/*.js, its row in perm.js PAGES, and its key in
-- app_roles.pages. Branches and Debt additionally need their table and RPCs
-- back -- the function bodies are in 02_functions.sql and 11/12, and the
-- tables refill from `python -m odoosync branch-stock` / `branch-sales` /
-- `branch-revenue` / `receivables`.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. The RPCs no surviving page calls
-- ---------------------------------------------------------------------------
-- Verified against every remaining .js: nothing in overview.js, customers.js,
-- admin.js, sync.js or insights.js references any of these. The discounts_*,
-- returns_*, product_top, product_unsold and product_by_category wrappers
-- still had entries in api.js, but api.js is a menu -- the pages that ordered
-- from it are gone.
--
-- Dropped by name rather than by signature. Postgres does not track a
-- function body's dependency on a table, so dropping the tables below would
-- otherwise leave these in place, resolving fine until someone called one.
do $$
declare
  r record;
  gone text[] := array[
    -- branches
    'branch_stock', 'branch_trend', 'branch_warehouses', 'branch_revenue_total',
    -- debt
    'customer_receivables',
    -- agencies
    'agency_lines', 'agency_customer_matrix',
    -- products detail panel
    'product_customers', 'product_regions', 'product_trend',
    -- products / status / frozen / reorder tables
    'product_top', 'product_unsold', 'product_by_category',
    -- discounts
    'discounts_by_product', 'discounts_by_dimension',
    -- returns
    'returns_by_product', 'returns_by_dimension',
    -- had no caller in any page even before this file
    'revenue_by_month_compare'
  ];
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (gone)
  loop
    execute format('drop function if exists %s', r.sig);
    raise notice 'dropped %', r.sig;
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 2. The tables only those pages read
-- ---------------------------------------------------------------------------
-- Checked first: no function outside the five branch_*/customer_receivables
-- ones dropped above mentions any of these four.
--
-- NOT dashboard_stock_history. See the header.
drop table if exists public.dashboard_branch_sales;
drop table if exists public.dashboard_branch_stock;
drop table if exists public.dashboard_branch_revenue;
drop table if exists public.dashboard_receivables;


-- ---------------------------------------------------------------------------
-- 3. The role page lists
-- ---------------------------------------------------------------------------
-- app_me() returns app_roles.pages straight through, and perm.js filters the
-- nav by it. Leaving dead keys here would not draw a link -- PAGES no longer
-- has a row for them -- but app_guard_admin_page() and the admin screen both
-- read this column, so it should say what is true.
--
-- `management` already held exactly ['overview','customers'] and is untouched.
update public.app_roles
   set pages = array['overview','customers','sync','admin']::text[],
       updated_at = now()
 where role_key = 'admin';

-- Any per-user denial naming a page that no longer exists is now noise.
update public.app_users
   set pages_denied = (
         select coalesce(array_agg(p), '{}')::text[]
           from unnest(coalesce(pages_denied, '{}')::text[]) p
          where p in ('overview','customers','sync','admin')
       ),
       updated_at = now()
 where pages_denied is not null
   and exists (
     select 1 from unnest(pages_denied) p
      where p not in ('overview','customers','sync','admin')
   );


-- ---------------------------------------------------------------------------
-- 4. What is left
-- ---------------------------------------------------------------------------
select 'tables' as kind, count(*) as n,
       string_agg(relname, ', ' order by relname) as names
  from pg_stat_user_tables where schemaname = 'public'
union all
select 'roles', count(*), string_agg(role_key || '=' || array_to_string(pages, '|'), '  ')
  from public.app_roles
union all
select 'db_size', null, pg_size_pretty(pg_database_size(current_database()));
