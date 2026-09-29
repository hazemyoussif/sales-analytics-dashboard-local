-- Dabboos Product Dashboard - Phase 0 schema
-- Run in: Supabase -> SQL Editor of the NEW project. Safe to re-run (idempotent).
--
-- ===========================================================================
-- ⚠️ DO NOT RE-RUN THIS FILE ONCE 04_admin.sql HAS BEEN APPLIED
-- ===========================================================================
-- Section 6 below creates `using (true)` policies: every signed-in user reads
-- every row. 04_admin.sql REPLACES those with policies scoped by the user's
-- salespersons and governorates.
--
-- Re-running this file would restore `using (true)` and hand every user the
-- whole company's numbers. It would not raise an error and nothing on screen
-- would look wrong - a restricted user would simply start seeing everything.
--
-- If you must re-run it, run 04_admin.sql again immediately afterwards.
--
-- This is a COMPLETE bootstrap for a fresh Supabase project. It creates every
-- table the dashboard reads, not just the invoice-basis ones, because a new
-- project inherits nothing from the sales dashboard's project.
--
--   TABLE                     FILLED BY
--   dashboard_invoice_lines   n8n: invoice-lines backfill + nightly   (new)
--   dashboard_stock_history   n8n: stock-history nightly              (new)
--   dashboard_products        n8n: products+stock sync, every 2h      (clone of existing)
--   dashboard_stock           n8n: products+stock sync, every 2h      (clone of existing)
--   dashboard_customers       n8n: customers sync                     (clone of existing)
--
-- The three "clone" workflows already exist in n8n against the OLD project.
-- Duplicate them and repoint their Config node at this project's URL and
-- service_role key. Do not repoint the originals - the sales dashboard still
-- needs them.

-- ===========================================================================
-- 1. Invoice lines - the basis for every number on this dashboard
-- ===========================================================================
-- Sourced from Odoo `account.invoice.report`. Only posted customer invoices
-- and credit notes are ever inserted. Credit-note rows carry NEGATIVE qty and
-- price_subtotal so that returns net out by plain summation.
-- Never store abs() values here. Verified 2026-08-01: see docs/odoo-fields.md.
create table if not exists public.dashboard_invoice_lines (
  line_id        bigint primary key,          -- account.invoice.report row id
  move_id        bigint,                      -- the invoice; lets lines regroup into documents
  product_id     bigint not null,
  qty            numeric not null,            -- UoM-normalized, fractional, signed
  price_subtotal numeric not null,            -- untaxed, signed
  price_total    numeric,                     -- taxed; kept for cross-checks only
  invoice_date   date   not null,             -- a DATE: no timezone conversion needed
  partner_id     bigint,                      -- commercial_partner_id
  salesperson    text,
  user_id        bigint,
  move_type      text   not null,             -- out_invoice | out_refund
  state          text   not null,             -- always 'posted'
  payment_state  text,
  synced_at      timestamptz not null default now()
);

-- Columns added after the 2026-08-01 field introspection (docs/odoo-fields.md).
-- Written as ADD COLUMN IF NOT EXISTS so this file both creates a fresh table
-- and upgrades one that already exists.

-- Odoo's OWN margin, computed at invoice time. This is why the dashboard does
-- not approximate margin from the product's CURRENT standard_price - which
-- would be wrong for any historical period, since cost moves over time.
-- inventory_value is the cost side, kept so the identity
--     price_margin = price_subtotal - inventory_value
-- can be verified on real rows before margin is trusted.
alter table public.dashboard_invoice_lines add column if not exists price_margin    numeric;
alter table public.dashboard_invoice_lines add column if not exists inventory_value numeric;

-- Category and brand ride on the invoice line itself, so no product join is
-- needed. This matters: the existing products sync hardcodes
-- dashboard_products.brand to NULL, so sourcing brand from there would render
-- empty charts with no error.
alter table public.dashboard_invoice_lines add column if not exists product_categ_id bigint;
alter table public.dashboard_invoice_lines add column if not exists category         text;
alter table public.dashboard_invoice_lines add column if not exists product_brand_id bigint;
alter table public.dashboard_invoice_lines add column if not exists brand            text;

-- Geography on the line. In an Iraqi Odoo, state_id is the governorate.
-- Kept alongside dashboard_customers so the two can be compared; whichever is
-- better populated wins and the other is dropped.
alter table public.dashboard_invoice_lines add column if not exists state_id  bigint;
alter table public.dashboard_invoice_lines add column if not exists gov       text;
alter table public.dashboard_invoice_lines add column if not exists city_id   bigint;
alter table public.dashboard_invoice_lines add column if not exists city      text;
alter table public.dashboard_invoice_lines add column if not exists team_id   bigint;

create index if not exists idx_inv_lines_date    on public.dashboard_invoice_lines (invoice_date);
create index if not exists idx_inv_lines_product on public.dashboard_invoice_lines (product_id);
create index if not exists idx_inv_lines_partner on public.dashboard_invoice_lines (partner_id);
-- the shape of nearly every query: a product over a date window
create index if not exists idx_inv_lines_prod_date
  on public.dashboard_invoice_lines (product_id, invoice_date);
create index if not exists idx_inv_lines_categ on public.dashboard_invoice_lines (product_categ_id);
create index if not exists idx_inv_lines_brand on public.dashboard_invoice_lines (product_brand_id);
create index if not exists idx_inv_lines_move  on public.dashboard_invoice_lines (move_id);

-- ===========================================================================
-- 2. Daily on-hand snapshots
-- ===========================================================================
-- dashboard_stock only ever holds TODAY - yesterday's on-hand is lost the
-- moment it refreshes. Nothing reads this table yet; it exists so history
-- starts accumulating now, because it cannot be backfilled later.
create table if not exists public.dashboard_stock_history (
  product_id  bigint  not null,
  snap_date   date    not null,
  on_hand_qty numeric not null,
  stock_value numeric,
  primary key (product_id, snap_date)
);

create index if not exists idx_stock_hist_date on public.dashboard_stock_history (snap_date);

-- ===========================================================================
-- 3. Product catalogue  (clone of the existing sync's target)
-- ===========================================================================
-- From Odoo product.product. cost = standard_price, uom = the product's unit
-- (e.g. "كارتونة 6 وحدات") - which is why quantities are fractional cartons.
--
-- NOTE: the existing n8n shaper writes brand as a hardcoded NULL. Brand for
-- this dashboard comes from dashboard_invoice_lines.brand instead. The column
-- is kept only so the cloned workflow can be reused unmodified.
create table if not exists public.dashboard_products (
  product_id bigint primary key,
  name       text,
  sku        text,
  category   text,
  brand      text,          -- always NULL from the sync; use invoice_lines.brand
  cost       numeric,       -- Odoo standard_price (CURRENT, not cost-at-sale)
  list_price numeric,
  uom        text,
  active     boolean,
  updated_at timestamptz
);

create index if not exists idx_products_category on public.dashboard_products (category);
create index if not exists idx_products_sku      on public.dashboard_products (sku);

-- ===========================================================================
-- 4. Current stock  (clone of the existing sync's target)
-- ===========================================================================
-- on_hand_qty = Odoo qty_available, company-wide, in the product's UoM.
-- Products with zero quantity still get a row (on_hand_qty = 0) so that
-- "in stock" and "not in the table" never get confused.
create table if not exists public.dashboard_stock (
  product_id  bigint primary key,
  on_hand_qty numeric,
  stock_value numeric,      -- on_hand x cost, approximate
  updated_at  timestamptz
);

-- ===========================================================================
-- 5. Customers  (clone of the existing sync's target)
-- ===========================================================================
-- Needed for the per-product customer drill-down: the invoice report gives a
-- partner_id but no customer name.
create table if not exists public.dashboard_customers (
  partner_id    bigint primary key,
  complete_name text,
  governorate   text,
  city          text,
  salesperson   text,
  user_id       bigint,
  credit        numeric,
  credit_limit  numeric,
  updated_at    timestamptz
);

create index if not exists idx_customers_gov on public.dashboard_customers (governorate);

-- ===========================================================================
-- 6. Row-Level Security
-- ===========================================================================
-- The anon key must read NOTHING; a logged-in user reads everything.
-- Writes belong to n8n, which uses the service_role key and bypasses RLS.
--
-- Verified on the old project 2026-08-01: without a user JWT these tables
-- return HTTP 200 with Content-Range */0 - a silent empty result, not an
-- error. That is why the dashboard must distinguish "no rows" from "not
-- logged in" and never render zeros for an auth failure.
alter table public.dashboard_invoice_lines enable row level security;
alter table public.dashboard_stock_history enable row level security;
alter table public.dashboard_products      enable row level security;
alter table public.dashboard_stock         enable row level security;
alter table public.dashboard_customers     enable row level security;

drop policy if exists inv_lines_read  on public.dashboard_invoice_lines;
drop policy if exists stock_hist_read on public.dashboard_stock_history;
drop policy if exists products_read   on public.dashboard_products;
drop policy if exists stock_read      on public.dashboard_stock;
drop policy if exists customers_read  on public.dashboard_customers;

create policy inv_lines_read  on public.dashboard_invoice_lines
  for select to authenticated using (true);
create policy stock_hist_read on public.dashboard_stock_history
  for select to authenticated using (true);
create policy products_read   on public.dashboard_products
  for select to authenticated using (true);
create policy stock_read      on public.dashboard_stock
  for select to authenticated using (true);
create policy customers_read  on public.dashboard_customers
  for select to authenticated using (true);

grant select on public.dashboard_invoice_lines to authenticated;
grant select on public.dashboard_stock_history to authenticated;
grant select on public.dashboard_products      to authenticated;
grant select on public.dashboard_stock         to authenticated;
grant select on public.dashboard_customers     to authenticated;

-- ===========================================================================
-- 7. Confirm
-- ===========================================================================
select table_name,
       (select count(*) from information_schema.columns c
         where c.table_name = t.table_name and c.table_schema = 'public') as columns
from information_schema.tables t
where table_schema = 'public'
  and table_name in ('dashboard_invoice_lines','dashboard_stock_history',
                     'dashboard_products','dashboard_stock','dashboard_customers')
order by table_name;
