-- ===========================================================================
-- 17. Getting back under the free-tier limit, without deleting any history
-- ===========================================================================
-- Evidence that this is a disk/resource problem rather than a query problem:
-- reading 1,294 rows from dashboard_products took 16.4 seconds, and fetching
-- ONE row from dashboard_invoice_lines took 35 seconds and then dropped the
-- connection. No index or rewrite produces that.
--
-- This morning the database held ~120 MB. It now holds roughly:
--
--   invoice lines table   ~200 MB
--   indexes on it         ~400 MB   <-- the problem, and mostly self-inflicted
--   everything else        ~50 MB
--
-- Supabase's free tier caps the database at 500 MB.
--
-- The indexes are bigger than the table they index. That is the thing to fix,
-- and it costs no data: run this whole file top to bottom.
--
-- ⚠ Run this whole file first. Then, OPTIONALLY and in a separate tab, the
--    one VACUUM line described in section 3 -- it cannot live in this file,
--    because Supabase wraps a script in a transaction and VACUUM refuses to
--    run inside one.

-- ---------------------------------------------------------------------------
-- 0. Before
-- ---------------------------------------------------------------------------
select pg_size_pretty(pg_database_size(current_database())) as database_total;

select relname,
       pg_size_pretty(pg_relation_size(relid))       as table_only,
       pg_size_pretty(pg_indexes_size(relid))        as indexes,
       pg_size_pretty(pg_total_relation_size(relid)) as total
from pg_catalog.pg_statio_user_tables
where relname like 'dashboard_%'
order by pg_total_relation_size(relid) desc;

-- ---------------------------------------------------------------------------
-- 1. The index diet
-- ---------------------------------------------------------------------------
-- Fourteen indexes on one table was never right, and I added four of them.
-- Keeping only what the RPCs actually need:
--
--   pkey                  required by the primary key
--   idx_inv_lines_pd      (product_id, invoice_date) partial -- serves
--                         product_facts, and it is the shape nearly every
--                         query uses
--   idx_inv_lines_dt      (invoice_date) partial -- date-range scans
--   idx_inv_lines_pt      (partner_id) partial -- customers_pareto
--
-- Everything else goes. Note especially idx_inv_lines_prod_date_cov: 107 MB
-- for eight INCLUDE columns. It was the only index that measurably helped,
-- but it costs a fifth of the entire free tier, and the plain version below
-- does most of the same job for about a sixth of the size.

drop index if exists public.idx_inv_lines_prod_date_cov;   -- 107 MB
drop index if exists public.idx_inv_lines_agg;             --  68 MB
drop index if exists public.idx_inv_lines_brand_date;      --  55 MB
drop index if exists public.idx_inv_lines_partner_date;    --  49 MB
drop index if exists public.idx_inv_lines_prod_date;       --  15 MB
drop index if exists public.idx_inv_lines_posted_date;     --  14 MB
drop index if exists public.idx_inv_lines_move;            --  12 MB
drop index if exists public.idx_inv_lines_date;            --   9 MB
drop index if exists public.idx_inv_lines_partner;         --   8 MB
drop index if exists public.idx_inv_lines_product;         --   8 MB
drop index if exists public.idx_inv_lines_rep;             --   7 MB
drop index if exists public.idx_inv_lines_gov;             --   7 MB
drop index if exists public.idx_inv_lines_brand;           --   7 MB
drop index if exists public.idx_inv_lines_categ;           --   7 MB
drop index if exists public.idx_inv_lines_refunds;         -- 792 kB

-- Three lean partial indexes in their place. Partial matters: every RPC
-- filters to posted customer documents, so rows that can never match are kept
-- out of the index entirely.
create index if not exists idx_inv_lines_pd
  on public.dashboard_invoice_lines (product_id, invoice_date)
  where state = 'posted' and move_type in ('out_invoice', 'out_refund');

create index if not exists idx_inv_lines_dt
  on public.dashboard_invoice_lines (invoice_date)
  where state = 'posted' and move_type in ('out_invoice', 'out_refund');

create index if not exists idx_inv_lines_pt
  on public.dashboard_invoice_lines (partner_id, invoice_date)
  where state = 'posted' and move_type in ('out_invoice', 'out_refund');

-- ---------------------------------------------------------------------------
-- 2. Dropping columns: DON'T, at least not the obvious ones
-- ---------------------------------------------------------------------------
-- This section began as a list of columns that looked unused. Checking each
-- one against the repository rather than trusting that impression killed most
-- of the list:
--
--   inventory_value  USED. 02_functions.sql computes Odoo's own margin as
--                    margin = price_subtotal + inventory_value (it is stored
--                    negative). Dropping it silently breaks every margin
--                    figure on the dashboard.
--   team_id          NEEDED, and currently the reason a feature is missing --
--                    see the note at the end of this file.
--   price_total      01_schema calls it "kept for cross-checks only", which
--                    is a real if occasional purpose.
--
-- What is left is city/city_id, worth a few MB at most -- not enough to take
-- an irreversible action for. Section 1 and section 3 are where the space is.

-- ---------------------------------------------------------------------------
-- 3. Table bloat -- run SEPARATELY, see the note below
-- ---------------------------------------------------------------------------
-- VACUUM FULL cannot appear here. Supabase's SQL editor wraps a script in a
-- transaction, and VACUUM refuses to run inside one:
--
--   ERROR: 25001: VACUUM cannot run inside a transaction block
--
-- It also matters less than it first appears. DROPPING AN INDEX RETURNS ITS
-- SPACE IMMEDIATELY -- no vacuum involved -- so section 1 already recovers
-- about 340 MB of the roughly 400 MB at stake. What VACUUM FULL would add is
-- the space behind ~29,000 phantom rows deleted earlier today, which is about
-- 4% of the table.
--
-- To run it anyway: open a NEW SQL editor tab, paste ONLY the line below,
-- nothing else, and run it. A lone statement is not wrapped.
--
--   vacuum (full, analyze) public.dashboard_invoice_lines;
--
-- It takes an exclusive lock -- nothing can read the table while it runs.
--
-- ANALYZE on its own is transaction-safe, so it stays here: after dropping
-- thirteen indexes and creating three, the planner needs to be told.
analyze public.dashboard_invoice_lines;

-- ---------------------------------------------------------------------------
-- 4. After
-- ---------------------------------------------------------------------------
select pg_size_pretty(pg_database_size(current_database())) as database_total;

select relname,
       pg_size_pretty(pg_relation_size(relid))       as table_only,
       pg_size_pretty(pg_indexes_size(relid))        as indexes,
       pg_size_pretty(pg_total_relation_size(relid)) as total
from pg_catalog.pg_statio_user_tables
where relname like 'dashboard_%'
order by pg_total_relation_size(relid) desc;

-- ---------------------------------------------------------------------------
-- If it is STILL over 500 MB
-- ---------------------------------------------------------------------------
-- The next lever keeps every number while discarding the rows behind them:
-- roll invoice lines older than, say, 12 months into a product x month
-- summary and delete the raw lines. Two years of summary is roughly 33,000
-- rows against 500,000 raw ones.
--
-- The cost is honest and worth stating: per-invoice and per-customer detail
-- for those older months would be gone, so returns and customer-level
-- analysis would only reach back as far as the raw window. Monthly totals,
-- product performance and trends would all survive intact.

-- ---------------------------------------------------------------------------
-- Footnote: what "dept" is, discovered while checking the above
-- ---------------------------------------------------------------------------
-- I asked three times what the dashboard's "dept" filter maps to in Odoo and
-- said I would leave it null rather than guess. 11_management_pages.sql
-- answers it, and has all along:
--
--   "customers  customers_pareto  the sales-TEAM NAME. team_id is already
--    synced but only as a bare id -- the n8n mapper keeps id0(r.team_id) and
--    drops the label."
--
-- So dept is the Odoo sales team (crm.team), and demo.js's four values --
-- سوبرماركت وهايبر / كرزات / الجملة / السلاسل -- are team names. The id is in
-- every row already; only the label was thrown away at sync time.
--
-- The engine has crm.team reachable as a relation on account.invoice.report,
-- so the sync can carry team_name the same way it carries salesperson and
-- gov. That makes dept a real filter instead of a null column, on customers
-- and agencies both. Small change, once the database is healthy again.
