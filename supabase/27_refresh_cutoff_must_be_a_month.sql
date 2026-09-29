-- ===========================================================================
-- 27. The nightly refresh could only ever work on the 1st of the month
-- ===========================================================================
-- The first real scheduled sync completed all ten jobs and then failed on the
-- last call, the one that matters most:
--
--   rpc refresh_after_sync -> 409
--   23505: Key (product_id, month)=(8, 2026-06-01) already exists
--
-- refresh_after_sync() passes (current_date - interval '2 months'), which on
-- 22 August is 2026-06-22. Both summary refreshers then did this:
--
--   cutoff := 2026-06-22
--   delete ... where month        >= cutoff   -- month is 2026-06-01: SURVIVES
--   insert ... where invoice_date >= cutoff   -- reads from 22 June
--          select date_trunc('month', invoice_date)  -- produces 2026-06-01
--
-- The delete compares a mid-month date against a column that only ever holds
-- month starts, so June is not removed; the insert then rebuilds a June row
-- and collides with the one still sitting there.
--
-- THE CRASH IS THE LESSER PROBLEM. Suppose the delete had matched. June would
-- have been rebuilt from 22 June onward -- a month's summary containing three
-- weeks of that month, with nothing to indicate it. Every page reads these
-- tables rather than the invoice lines, so the dashboard would have shown a
-- June that quietly lost two thirds of itself.
--
-- The function's own comment says "Whole months only". That was the right
-- intent; the code truncated on one side of the operation and not the other.
--
-- Why it survived until now: the cutoff is already a month boundary when the
-- job runs on the 1st, so a refresh on the 1st succeeds and a refresh on any
-- other day fails. Every previous rebuild was run by hand with p_since => null,
-- which makes the cutoff 1900-01-01 and deletes the whole table.
--
-- The fix is one expression in each function: truncate the cutoff to the start
-- of its month, so the delete and the insert describe the same set of months.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

create or replace function public.refresh_product_month(p_since date default null)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  n bigint;
  -- date_trunc, so that "since 22 June" means "rebuild June entirely".
  -- Rebuilding a partial month is never wanted here: the table's grain IS the
  -- month, and half a month under a whole month's key is a wrong number rather
  -- than a missing one.
  cutoff date := date_trunc('month', coalesce(p_since, date '1900-01-01'))::date;
begin
  delete from public.dashboard_product_month where month >= cutoff;

  insert into public.dashboard_product_month
    (product_id, month, units, revenue, margin, invoices, customers, govs, updated_at)
  select l.product_id,
         date_trunc('month', l.invoice_date)::date,
         sum(l.qty),
         sum(l.price_subtotal),
         sum(l.price_margin),
         count(distinct l.move_id),
         count(distinct l.partner_id),
         count(distinct l.gov),
         now()
  from public.dashboard_invoice_lines l
  where l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.product_id is not null
    and l.invoice_date >= cutoff
  group by 1, 2;

  get diagnostics n = row_count;
  return n;
end;
$$;

grant execute on function public.refresh_product_month(date) to service_role;

-- Identical bug, identical fix.
create or replace function public.refresh_partner_month(p_since date default null)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  n bigint;
  cutoff date := date_trunc('month', coalesce(p_since, date '1900-01-01'))::date;
begin
  delete from public.dashboard_partner_month where month >= cutoff;

  insert into public.dashboard_partner_month
    (partner_id, month, revenue, margin, units, invoices, updated_at)
  select l.partner_id,
         date_trunc('month', l.invoice_date)::date,
         sum(l.price_subtotal), sum(l.price_margin), sum(l.qty),
         count(distinct l.move_id), now()
  from public.dashboard_invoice_lines l
  where l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.partner_id is not null
    and l.invoice_date >= cutoff
  group by 1, 2;

  get diagnostics n = row_count;
  return n;
end;
$$;

grant execute on function public.refresh_partner_month(date) to service_role;

-- Prove it: this is the exact call the sync makes, on a day that is not the 1st.
select * from public.refresh_after_sync();

select 'product_month' as summary, count(*) as rows,
       min(month) as earliest, max(month) as latest
from public.dashboard_product_month
union all
select 'partner_month', count(*), min(month), max(month)
from public.dashboard_partner_month;
