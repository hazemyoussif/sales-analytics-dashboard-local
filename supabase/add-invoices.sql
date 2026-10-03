-- ============================================================
-- dashboard_invoices — customer invoices from Odoo (account.move)
-- Run ONCE, then import + backfill "Dabboos Sync v5 — invoices".
--
-- This makes DEBT a transactional fact: receivable = the sum of open
-- invoice residuals; overdue = residuals past their due date. Every
-- figure traces to an invoice you can open in Odoo — no precomputed
-- black-box fields.
-- ============================================================
create table if not exists public.dashboard_invoices (
  invoice_id      int8 primary key,
  name            text,
  partner_id      int8,
  partner_name    text,
  user_id         int8,
  salesperson     text,          -- custom salesperson_id on account.move.line (id + name)
  invoice_date    date,
  due_date        date,
  amount_total    numeric,
  amount_residual numeric,
  payment_state   text,
  state           text,
  updated_at      timestamptz not null default now()
);

-- 2026-07-14: salesperson name snapshot — from the CUSTOM `salesperson_id`
-- field this instance has on account.move.line (n8n v6 syncs it in the same
-- fetch as the lines). Idempotent — safe on databases created before this
-- column existed. Rows synced before v6 stay null (the dashboard then falls
-- back to the customer master's rep name).
alter table public.dashboard_invoices add column if not exists salesperson text;

create index if not exists dashboard_invoices_due_idx     on public.dashboard_invoices (due_date);
create index if not exists dashboard_invoices_partner_idx on public.dashboard_invoices (partner_id);
create index if not exists dashboard_invoices_open_idx    on public.dashboard_invoices (amount_residual) where amount_residual > 0;

alter table public.dashboard_invoices enable row level security;
revoke all on public.dashboard_invoices from anon;
grant select on public.dashboard_invoices to authenticated;
drop policy if exists invoices_read on public.dashboard_invoices;
create policy invoices_read on public.dashboard_invoices
  for select to authenticated
  using ((select public.dash_role()) in ('admin', 'management'));

-- sanity after the n8n backfill run:
--   select count(*),
--          sum(amount_residual) filter (where amount_residual > 0) as open_book,
--          sum(amount_residual) filter (where amount_residual > 0 and due_date < current_date) as overdue
--   from public.dashboard_invoices where state = 'posted';
-- open_book should land near the customers-table receivable (~1,368M).
