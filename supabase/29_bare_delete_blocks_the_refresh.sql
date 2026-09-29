-- ===========================================================================
-- 29. A DELETE with no WHERE stops the whole nightly refresh
-- ===========================================================================
-- With file 27 in place the summary rebuilds stopped colliding, and the run
-- got one step further before failing:
--
--   rpc refresh_after_sync -> 400
--   21000: DELETE requires a WHERE clause
--
-- refresh_after_sync() calls three things. The first two were failing until
-- tonight, so refresh_dashboard_summaries() had never actually been reached
-- through this path, and it contains:
--
--   delete from public.dashboard_filter_options;
--
-- Supabase runs pg_safeupdate for the role PostgREST connects as, which
-- rejects an unqualified DELETE. The SQL Editor connects as postgres and has
-- no such guard.
--
-- THIS IS THE THIRD TIME THE SAME MISTAKE HAS BITTEN. File 24 was a function
-- that worked in the editor and timed out under service_role. File 27 was a
-- refresh that worked on the 1st of the month and failed on the other thirty
-- days. Both were verified in the one context that was never how they would
-- run. Testing in the SQL Editor proves a statement is valid SQL; it proves
-- nothing about the role, the timeout or the guards it will meet in
-- production.
--
-- The fix is `where true`, which satisfies the guard and changes nothing about
-- what the statement does. TRUNCATE would also work and takes an ACCESS
-- EXCLUSIVE lock on a table the dashboard reads on every page load, for no
-- gain on a table this small.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

create or replace function public.refresh_dashboard_summaries()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.dashboard_health (metric, value, updated_at)
  select 'invoice_lines', count(*)::text, now() from public.dashboard_invoice_lines
  union all
  select 'date_from', coalesce(min(invoice_date)::text, '—'), now()
    from public.dashboard_invoice_lines
  union all
  select 'date_to', coalesce(max(invoice_date)::text, '—'), now()
    from public.dashboard_invoice_lines
  union all
  select 'products', count(*)::text, now() from public.dashboard_products
  union all
  select 'stock_rows', count(*)::text, now() from public.dashboard_stock
  union all
  select 'customers', count(*)::text, now() from public.dashboard_customers
  union all
  select 'stock_snapshots', count(distinct snap_date)::text, now()
    from public.dashboard_stock_history
  union all
  select 'brand_fill_pct',
         coalesce(round(100.0 * count(*) filter (where brand is not null) /
                  nullif(count(*), 0))::text, '0'), now()
    from public.dashboard_invoice_lines
  on conflict (metric) do update
    set value = excluded.value, updated_at = excluded.updated_at;

  -- Rebuilt wholesale rather than upserted: a governorate or brand that
  -- stops appearing must disappear from the filter bar, and an upsert can
  -- never remove anything. Same rule the invoice backfill needed --replace
  -- for, and for the same reason.
  -- `where true` is not decoration. Supabase runs pg_safeupdate for the
  -- role PostgREST connects as, and a DELETE with no WHERE raises
  -- 21000 'DELETE requires a WHERE clause'. The SQL Editor connects as
  -- postgres, which has no such guard -- so this statement worked every
  -- time it was tested and failed the first time the sync ran it.
  delete from public.dashboard_filter_options where true;

  insert into public.dashboard_filter_options (kind, value, n, updated_at)
  select 'gov', gov, count(*), now() from public.dashboard_invoice_lines
    where gov is not null group by gov
  union all
  select 'salesperson', salesperson, count(*), now() from public.dashboard_invoice_lines
    where salesperson is not null group by salesperson
  union all
  select 'category', category, count(*), now() from public.dashboard_invoice_lines
    where category is not null group by category
  union all
  select 'brand', brand, count(*), now() from public.dashboard_invoice_lines
    where brand is not null group by brand;
end;
$$;

grant execute on function public.refresh_dashboard_summaries() to service_role;

-- The real thing, through the same path the sync uses.
select * from public.refresh_after_sync();

select metric, value from public.dashboard_health order by metric;
select kind, count(*) as options from public.dashboard_filter_options group by kind order by kind;
