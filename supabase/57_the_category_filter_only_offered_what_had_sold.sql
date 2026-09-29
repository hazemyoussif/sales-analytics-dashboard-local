-- ===========================================================================
-- 57. The category filter only offered categories that had already sold
-- ===========================================================================
-- dashboard_filter_options is built from dashboard_invoice_lines, so a category
-- reaches the dropdown only once something in it has been invoiced. Compared
-- against Odoo's product-category list:
--
--   66  categories in Odoo
--   56  in the dropdown
--   52  in both
--
-- Four of the fourteen missing ones hold real products and simply have not sold
-- in the data window:
--
--   للجميع / ميغا شيبس        14 products
--   للجميع / بلكوريا / بسكت     9
--   للجميع / شركة مارتن        4
--   اكوند / لوح                1
--
-- The other ten hold ZERO products -- للجميع, الطون, للجميع / برياكولد and so
-- on. They are branch nodes in Odoo's category tree, not places products live.
-- Offering them would add filters that can never match anything, so this file
-- does not add them: it sources from the CATALOGUE, which is the set of
-- categories that actually contain products, rather than from a pasted list
-- that goes stale the next time someone edits the tree in Odoo.
--
-- A NAME MISMATCH THIS FILE DOES NOT FIX. Four categories are stored without
-- their parent path:
--
--   dashboard says          Odoo says
--   SOJ شركة                 للجميع / SOJ شركة
--   بسكت صيني                 للجميع / بسكت صيني
--   شركة ميراتورك             للجميع / شركة ميراتورك
--   ويفر اصابع بامبوك          للجميع / ويفر اصابع بامبوك
--
-- This is not the sync mangling them. Both jobs read the same m2o_label, and
-- 52 other categories carry their full path correctly (للجميع / برياكولد /
-- بسكت). dashboard_products was synced from Odoo on 2026-08-25 and holds the
-- short form, so Odoo itself returned the short form at that moment. If those
-- four were re-parented under للجميع afterwards, the next products sync picks
-- the new names up on its own. Hardcoding them here would fight the source of
-- truth rather than follow it.
--
-- SCOPED DROPDOWNS ARE DELIBERATELY UNCHANGED. filter_options() only reads this
-- table when no governorate or city is chosen; with a scope it reads
-- dashboard_filter_scope, which is sales-derived. That is correct and stays:
-- unfiltered, offer every category that exists; inside بغداد, offer only what
-- actually sold in بغداد.
--
-- Ordering is preserved. n stays the invoice-line count, so categories that
-- sell rank first and never-sold categories sort to the bottom at n = 0
-- (filter_options orders by n desc).
--
-- Run in: Supabase -> SQL Editor. Safe to re-run. This only changes the body of
-- refresh_dashboard_summaries; run it, then rebuild once with
--   select public.refresh_dashboard_summaries();
-- or wait for tonight's sync.
-- ===========================================================================

create or replace function public.refresh_dashboard_summaries()
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  insert into public.dashboard_health (metric, value, updated_at)
  select 'invoice_lines', count(*)::text, now() from public.dashboard_invoice_lines
  union all
  select 'date_from', coalesce(min(invoice_date)::text, U&'\2014'), now()
    from public.dashboard_invoice_lines
  union all
  select 'date_to', coalesce(max(invoice_date)::text, U&'\2014'), now()
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

  delete from public.dashboard_filter_options where true;

  -- gov, city and salesperson stay sales-derived: they describe WHERE and BY
  -- WHOM things were sold, which only the invoice lines know. category and
  -- brand are attributes of the PRODUCT -- file 47's distinction -- so they
  -- come from the catalogue as well, with n = 0 for anything unsold.
  insert into public.dashboard_filter_options (kind, value, n, updated_at)
  select kind, value, sum(n), now()
  from (
    select 'gov' as kind, gov as value, count(*) as n
      from public.dashboard_invoice_lines where gov is not null group by gov
    union all
    select 'city', city, count(*) from public.dashboard_invoice_lines
      where city is not null group by city
    union all
    select 'salesperson', salesperson, count(*) from public.dashboard_invoice_lines
      where salesperson is not null group by salesperson
    union all
    select 'category', category, count(*) from public.dashboard_invoice_lines
      where category is not null group by category
    union all
    select 'brand', brand, count(*) from public.dashboard_invoice_lines
      where brand is not null group by brand
    union all
    -- the catalogue half: every category and brand that a product belongs to,
    -- whether or not it has ever been invoiced.
    select 'category', category, 0 from public.dashboard_products
      where category is not null group by category
    union all
    select 'brand', brand, 0 from public.dashboard_products
      where brand is not null group by brand
  ) t
  group by kind, value;

  update public.dashboard_product_lastsale set units_90d = 0 where true;

  update public.dashboard_product_lastsale t
     set units_90d = v.units
    from (select l.product_id, sum(l.qty) as units
            from public.dashboard_invoice_lines l
           where l.state = 'posted'
             and l.move_type in ('out_invoice', 'out_refund')
             and l.product_id is not null
             and l.invoice_date > current_date - 90
             and l.invoice_date <= current_date
           group by l.product_id) v
   where t.product_id = v.product_id;

  perform public.refresh_filter_scope();
  -- Two months. A backfill reaching further back needs a full rebuild of each:
  --   select public.refresh_place_month();
  --   select public.refresh_partner_mix_month();
  perform public.refresh_place_month((current_date - interval '2 months')::date);
  perform public.refresh_partner_mix_month((current_date - interval '2 months')::date);

  -- File 51's caches.
  perform public.refresh_customer_class();
  perform public.refresh_partner_lastseen();
end;
$function$;
