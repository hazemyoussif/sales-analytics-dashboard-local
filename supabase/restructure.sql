-- ============================================================
-- Dabboos — raw-tables restructure (run ONCE in Supabase SQL Editor)
--
-- Goal: n8n becomes a pure fetcher; the dashboard reads raw tables
-- directly. Snapshots/summaries are retired. This script is ADDITIVE:
-- the currently-deployed dashboard keeps working while it runs.
--
-- ⚠️ CUTOVER ORDER:
--   1. Run this script.
--   2. Import + run "Dabboos Sync v4 — raw only" in n8n
--      (one backfill run: orders 90 days, payments 30 days).
--   3. Verify salespeople / dashboard_customers / orders.partner_id filled.
--   4. Merge + deploy the feat/raw-tables dashboard branch.
--   5. Deactivate old n8n workflows. After a week of clean operation,
--      run the RETIREMENT block at the bottom.
-- ============================================================

-- ------------------------------------------------------------
-- 1. salespeople — one row per rep (res.users id), ends the
--    "same rep spelled three ways" problem
-- ------------------------------------------------------------
create table if not exists public.salespeople (
  user_id    int8 primary key,
  name       text not null,
  updated_at timestamptz not null default now()
);

-- backfill from every rep already present in orders + payments
insert into public.salespeople (user_id, name)
select user_id, coalesce(max(salesperson), '—')
from (
  select user_id, salesperson from public.dashboard_orders   where user_id is not null
  union all
  select user_id, salesperson from public.dashboard_payments where user_id is not null
) t
group by user_id
on conflict (user_id) do nothing;

-- ------------------------------------------------------------
-- 2. dashboard_customers — becomes the customer MASTER:
--    add the assigned salesperson (res.partner.user_id)
-- ------------------------------------------------------------
alter table public.dashboard_customers add column if not exists user_id int8;
alter table public.dashboard_customers add column if not exists salesperson text;

do $$ begin
  alter table public.dashboard_customers
    add constraint dashboard_customers_user_id_fkey
    foreign key (user_id) references public.salespeople (user_id) on delete set null;
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- 3. dashboard_orders — relational keys + real timestamp types
-- ------------------------------------------------------------
alter table public.dashboard_orders add column if not exists partner_id int8;

do $$ begin
  alter table public.dashboard_orders
    add constraint dashboard_orders_user_id_fkey
    foreign key (user_id) references public.salespeople (user_id) on delete set null;
exception when duplicate_object then null; end $$;

-- n8n only writes partner_id when the customer row is guaranteed to exist
-- (it upserts customers before orders), so this FK stays valid.
do $$ begin
  alter table public.dashboard_orders
    add constraint dashboard_orders_partner_id_fkey
    foreign key (partner_id) references public.dashboard_customers (partner_id) on delete set null;
exception when duplicate_object then null; end $$;

-- text → timestamptz (values are UTC; the DB runs UTC, so the cast is exact)
alter table public.dashboard_orders
  alter column date_order  type timestamptz using nullif(date_order,  '')::timestamptz,
  alter column create_date type timestamptz using nullif(create_date, '')::timestamptz;

-- ------------------------------------------------------------
-- 4. dashboard_payments — real date types + rep key
--    (partner_id deliberately has NO hard FK: a brand-new customer's
--    payment can arrive minutes before the hourly customer pull, and
--    ingestion must never be blocked)
-- ------------------------------------------------------------
alter table public.dashboard_payments
  alter column date        type date        using nullif(date,        '')::date,
  alter column create_date type timestamptz using nullif(create_date, '')::timestamptz;

do $$ begin
  alter table public.dashboard_payments
    add constraint dashboard_payments_user_id_fkey
    foreign key (user_id) references public.salespeople (user_id) on delete set null;
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- 5. indexes for the dashboard's polling queries
-- ------------------------------------------------------------
create index if not exists dashboard_orders_date_order_idx  on public.dashboard_orders  (date_order desc);
create index if not exists dashboard_orders_state_idx       on public.dashboard_orders  (state);
create index if not exists dashboard_orders_partner_id_idx  on public.dashboard_orders  (partner_id);
create index if not exists dashboard_payments_date_idx      on public.dashboard_payments (date desc);
create index if not exists dashboard_payments_partner_idx   on public.dashboard_payments (partner_id);
create index if not exists dashboard_customers_user_id_idx  on public.dashboard_customers (user_id);

-- ------------------------------------------------------------
-- 6. RLS for the new table (same model as auth-setup.sql)
-- ------------------------------------------------------------
alter table public.salespeople enable row level security;
revoke all on public.salespeople from anon;
grant select on public.salespeople to authenticated;
drop policy if exists salespeople_read on public.salespeople;
create policy salespeople_read on public.salespeople
  for select to authenticated
  using (public.dash_role() is not null);

-- sanity checks
--   select count(*) from public.salespeople;
--   select column_name, data_type from information_schema.columns
--   where table_name in ('dashboard_orders','dashboard_payments') and column_name like '%date%';

-- ============================================================
-- RETIREMENT — run ONLY after a week of clean v4 operation
-- (the old dashboard build reads snapshots; make sure the new
--  build is deployed everywhere first):
--
--   drop table if exists public.dashboard_snapshots;
--   drop table if exists public.dashboard_monthly;
-- ============================================================
