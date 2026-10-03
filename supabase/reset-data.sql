-- ============================================================
-- reset-data.sql — wipe the sync DATA tables for the v6 clean slate
-- (2026-07: "raw mirror" cutover — Odoo → Supabase from 2026-01-01)
--
-- Run this ONCE, immediately before running the "FULL BACKFILL 2026"
-- trigger in "Dabboos Sync v6 — raw mirror 2026". The dashboard shows
-- empty data between the truncate and the end of the backfill, so do
-- both in one sitting.
--
-- ONLY data tables are touched. Structure, RLS policies, auth
-- (dash_users), acknowledgments (alert_acks) and traffic tables are
-- deliberately NOT here — never truncate those.
-- ============================================================
truncate table
  public.dashboard_orders,
  public.dashboard_payments,
  public.dashboard_invoices,
  public.dashboard_customers,
  public.salespeople;

-- sanity: all five should read 0
--   select 'orders' t, count(*) from public.dashboard_orders
--   union all select 'payments', count(*) from public.dashboard_payments
--   union all select 'invoices', count(*) from public.dashboard_invoices
--   union all select 'customers', count(*) from public.dashboard_customers
--   union all select 'salespeople', count(*) from public.salespeople;
