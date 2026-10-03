-- ============================================================
-- reconcile_orders(keep_ids) — delete MIRROR GHOSTS: orders that were
-- deleted in Odoo after we synced them. Upserts add/update but never
-- delete, so Odoo deletions accumulate as extra rows (owner found +11:
-- dashboard 2,034 vs Odoo 2,023 for July).
--
-- Run ONCE in Supabase → SQL Editor. Called by the n8n workflow
-- "Dabboos Orders RECONCILE" via POST /rest/v1/rpc/reconcile_orders
-- with the full list of CURRENT Odoo order ids (2026+). The id list
-- travels in the request BODY, so its size is unlimited.
--
-- Returns the deleted rows (id + name + state) as evidence.
-- Service-role only: the dashboard's anon/authenticated keys cannot
-- call it.
-- ============================================================
-- Scope is DATE_ORDER (2026-07-18): the whole orders pipeline slices by
-- order date now — orders dated 2026 but created earlier were invisible
-- to create_date slicing (owner found 2,205 vs 2,046 July-dated orders).
create or replace function public.reconcile_orders(keep_ids int8[])
returns table (order_id int8, order_name text, state text)
language sql
security definer
set search_path = public
as $$
  delete from public.dashboard_orders o
  where o.date_order >= '2026-01-01'
    and not (o.order_id = any (keep_ids))
  returning o.order_id, o.order_name, o.state;
$$;

revoke all on function public.reconcile_orders(int8[]) from public;
revoke all on function public.reconcile_orders(int8[]) from anon;
revoke all on function public.reconcile_orders(int8[]) from authenticated;
grant execute on function public.reconcile_orders(int8[]) to service_role;

-- safety: never callable with an empty/absurdly small list by accident?
-- The n8n workflow guards this (aborts if Odoo returned < 100 ids), so a
-- transient Odoo failure can never mass-delete the mirror.
