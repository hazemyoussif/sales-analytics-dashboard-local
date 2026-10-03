-- ============================================================
-- Real governorate from Odoo (res.partner.state_id)
-- Run ONCE, then import + run "Dabboos Sync v4.1 — governorate".
--
-- The dashboard prefers this field and falls back to the free-text
-- city dictionary (govOf) only when it's empty — so coverage improves
-- as the field gets filled in Odoo, and nothing breaks meanwhile.
-- ============================================================
alter table public.dashboard_customers add column if not exists governorate text;

-- (optional, run to see coverage after the first v4.1 run)
--   select count(*) filter (where governorate is not null) as with_gov,
--          count(*) as total
--   from public.dashboard_customers;
