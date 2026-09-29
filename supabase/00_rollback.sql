-- Dabboos Product Dashboard - DROP EVERYTHING this project owns
-- Run in: Supabase -> SQL Editor. Use before re-running 01_schema.sql clean.
--
-- ⚠️ DESTRUCTIVE. It drops these five tables and their data, indexes and
--    RLS policies:
--
--      dashboard_invoice_lines
--      dashboard_stock_history
--      dashboard_products
--      dashboard_stock
--      dashboard_customers
--
-- Two guards run first. Both ABORT the entire script - nothing is dropped
-- unless both pass.
--
--   GUARD 1 - wrong project. If tables that belong ONLY to the Sales Command
--   Center are present, this is the OLD project and the script refuses to run.
--   dashboard_products / _stock / _customers are shared names, so dropping
--   them there would break the live sales dashboard.
--
--   GUARD 2 - not empty. Reports the row count of every table and aborts if
--   any holds data.
--
-- To drop tables that DO contain rows, set the flag on the next line to true.
-- Guard 1 has no override on purpose.

do $$
declare
  allow_nonempty boolean := false;   -- <<< set to true to drop populated tables

  wrong_project text[];
  t             text;
  n             bigint;
  total         bigint := 0;
  targets       text[] := array[
    'dashboard_invoice_lines',
    'dashboard_stock_history',
    'dashboard_products',
    'dashboard_stock',
    'dashboard_customers'
  ];
begin
  -- ---- GUARD 1: are we on the old (sales dashboard) project? -------------
  select array_agg(x) into wrong_project
  from unnest(array['dashboard_orders','dashboard_order_lines','dashboard_payments',
                    'dash_users','salespeople','alert_acks']) as x
  where to_regclass('public.' || x) is not null;

  if wrong_project is not null then
    raise exception
      E'ABORTED - WRONG PROJECT.\n'
      'Found tables that belong to the Sales Command Center: %.\n'
      'This looks like the OLD Supabase project. Dropping dashboard_products, '
      'dashboard_stock or dashboard_customers here would break the live sales '
      'dashboard. Nothing was dropped.',
      array_to_string(wrong_project, ', ');
  end if;

  -- ---- GUARD 2: is anything populated? -----------------------------------
  foreach t in array targets loop
    if to_regclass('public.' || t) is null then
      raise notice '% : does not exist', rpad(t, 26);
    else
      execute format('select count(*) from public.%I', t) into n;
      total := total + n;
      raise notice '% : % rows', rpad(t, 26), n;
    end if;
  end loop;

  if total > 0 and not allow_nonempty then
    raise exception
      E'ABORTED - % row(s) across these tables.\n'
      'Nothing was dropped. Set allow_nonempty := true at the top of this '
      'script if you really mean to destroy the data.', total;
  end if;

  raise notice 'Guards passed. Dropping.';
end $$;

-- Only reached when both guards pass.
drop table if exists public.dashboard_invoice_lines cascade;
drop table if exists public.dashboard_stock_history cascade;
drop table if exists public.dashboard_products      cascade;
drop table if exists public.dashboard_stock         cascade;
drop table if exists public.dashboard_customers     cascade;

-- Drop the RPCs too, so 02_functions.sql can be re-run from clean.
drop function if exists public.product_facts(date, date, text, text, bigint, text, text);

-- Confirm. Every value should come back NULL.
select to_regclass('public.dashboard_invoice_lines') as invoice_lines,
       to_regclass('public.dashboard_stock_history') as stock_history,
       to_regclass('public.dashboard_products')      as products,
       to_regclass('public.dashboard_stock')         as stock,
       to_regclass('public.dashboard_customers')     as customers;
