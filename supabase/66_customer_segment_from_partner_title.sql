-- ===========================================================================
-- 66. Customer segment (ماركتات / كرزات / جملة / سلاسل كبرى)
-- ===========================================================================
-- Management classifies each customer by trade type and wants to filter on it.
-- In Odoo it is stored on res.partner.title -- the honorific field, repurposed.
-- The customers sync now reads it into this column (jobs.py CUSTOMER_FIELDS).
--
-- Nullable and unindexed for now: it is a low-cardinality label on ~3,400 rows,
-- filtered in-memory on the page, and empty until `python -m odoosync customers`
-- runs against the new field.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

alter table public.dashboard_customers
  add column if not exists title text;

comment on column public.dashboard_customers.title is
  'Trade segment from res.partner.title (ماركتات / كرزات / جملة / سلاسل كبرى). Repurposed honorific field.';
