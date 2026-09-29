-- ===========================================================================
-- 24. The refresh functions could not actually be called
-- ===========================================================================
-- Files 18 and 19 built refresh_dashboard_summaries() and
-- refresh_product_month() specifically so the SYNC could call them after each
-- run. Both fail when it does:
--
--   refresh_dashboard_summaries   HTTP 500  9,139ms  57014 statement timeout
--   refresh_product_month         HTTP 500  8,816ms  57014 statement timeout
--
-- They work in the SQL editor, which is where I tested them, and that is the
-- whole mistake: the editor runs as a role with a generous timeout, while
-- PostgREST runs as service_role with the default. I verified them in the one
-- context that was never going to be how they ran.
--
-- Two fixes, and both are needed.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. Give service_role room to do maintenance work
-- ---------------------------------------------------------------------------
-- service_role is not a user-facing role -- nothing a person waits on runs
-- through it. It is the sync, and the sync's job IS the long scan. The 8
-- second default exists to protect interactive queries from each other, and
-- applying it here only guarantees maintenance can never complete.
--
-- authenticated keeps its short leash: that one IS user-facing, and a page
-- that hangs for five minutes is worse than one that errors.
alter role service_role set statement_timeout = '300s';

-- ---------------------------------------------------------------------------
-- 2. Make the routine refresh cheap enough not to need it
-- ---------------------------------------------------------------------------
-- A longer timeout alone would leave a five-minute rebuild running nightly
-- forever. refresh_product_month already accepts p_since, and the nightly
-- sync only re-syncs 35 days, so two months always covers everything that
-- could have changed:
--
--   select public.refresh_product_month((current_date - interval '2 months')::date);
--
-- That rebuilds two months instead of twenty-seven. A full rebuild is only
-- needed after a backfill reaching further back -- which is exactly when
-- someone is watching anyway.

-- One helper so the sync makes a single call rather than remembering the
-- date arithmetic, and so the two refreshes cannot drift apart.
create or replace function public.refresh_after_sync()
returns table (product_month_rows bigint, health_metrics bigint, filter_options bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  n bigint;
begin
  -- Two months back: the nightly window is 35 days, so anything older than
  -- that cannot have changed since the last run.
  n := public.refresh_product_month((current_date - interval '2 months')::date);
  perform public.refresh_dashboard_summaries();
  return query
    select n,
           (select count(*) from public.dashboard_health),
           (select count(*) from public.dashboard_filter_options);
end;
$$;

grant execute on function public.refresh_after_sync() to service_role;

-- ---------------------------------------------------------------------------
-- 3. Rebuild now -- the summaries were built from the phantom rows
-- ---------------------------------------------------------------------------
-- dashboard_product_month was computed while 29,686 cancelled-invoice rows
-- were still present, so it still reports the inflated 2026 figures even
-- though the invoice table itself now reconciles with Odoo exactly. This is
-- the full rebuild, and it belongs here in the editor rather than in the
-- nightly path.
select public.refresh_product_month() as product_month_rows;
select public.refresh_dashboard_summaries();

analyze public.dashboard_product_month;

select * from public.dashboard_health order by metric;
