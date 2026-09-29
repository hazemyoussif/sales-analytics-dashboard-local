-- ===========================================================================
-- 73. overview_facts.by_category also reports `sold`
-- ===========================================================================
-- The Agencies page shows عدد الأصناف per family. It was the catalogue count
-- (every SKU in the family), which reads as inflated next to the quantity that
-- actually moved. by_category now carries `sold` -- how many of those SKUs had
-- a non-zero quantity in the window -- so the page can show "sold / total".
--
-- One string swap on the live definition; nothing else changes.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

do $do$
declare src text;
begin
  select pg_get_functiondef(p.oid) into src
  from pg_proc p
  where p.proname = 'overview_facts' and p.pronamespace = 'public'::regnamespace;

  if src like '%''sold'', count(*) filter%' then
    raise notice 'already patched';
    return;
  end if;

  src := replace(src,
    '''products'', count(*)) as c,',
    '''products'', count(*), ''sold'', count(*) filter (where coalesce(units, 0) > 0)) as c,');

  execute src;
end
$do$;
