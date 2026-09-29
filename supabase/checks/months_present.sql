-- What months does Supabase actually hold, and what is each worth?
-- Run in: Supabase -> SQL Editor. Read-only.
--
-- Before the 2026-08-21 backfill this returned five rows, all 2026. It should
-- now return every month from 2024-06 onward.

select to_char(invoice_date, 'YYYY-MM')            as month,
       count(*)                                    as lines,
       count(distinct move_id)                     as invoices,
       count(distinct partner_id)                  as customers,
       round(sum(price_subtotal))                  as revenue,
       round(sum(price_subtotal) filter (where move_type = 'out_refund')) as returns
from public.dashboard_invoice_lines
where state = 'posted'
  and move_type in ('out_invoice', 'out_refund')
group by 1
order by 1;


-- ---------------------------------------------------------------------------
-- One-line version, if you only want the range
-- ---------------------------------------------------------------------------
-- select min(invoice_date), max(invoice_date), count(*)
-- from public.dashboard_invoice_lines;


-- ---------------------------------------------------------------------------
-- Is the database still busy from the backfill?
-- ---------------------------------------------------------------------------
-- Loading 588,000 rows and building three large indexes leaves autovacuum
-- working hard afterwards, and everything else is slow while it does. If
-- autovacuum_count is climbing or last_autovacuum is within the last few
-- minutes, the timeouts may simply be that -- and may pass on their own.
select relname,
       n_live_tup,
       n_dead_tup,
       last_vacuum, last_autovacuum,
       last_analyze, last_autoanalyze
from pg_stat_user_tables
where relname like 'dashboard_%'
order by n_live_tup desc;

-- Anything running right now, and for how long?
select pid,
       now() - query_start as running_for,
       state,
       left(query, 90) as query
from pg_stat_activity
where state <> 'idle'
  and query not ilike '%pg_stat_activity%'
order by query_start;
