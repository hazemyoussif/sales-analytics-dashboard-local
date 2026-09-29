-- ===========================================================================
-- 68. product_facts / overview_facts gain p_segment (customer trade segment)
-- ===========================================================================
-- The agencies page (and Overview) need "what did segment X buy" -- families,
-- quantities, unsold stock, scoped to customers whose res.partner.title is
-- ماركتات / كرزات / جملة / سلاسل. That is a filter on WHICH SALES COUNT for a
-- product, which only the invoice lines can express -- exactly like the
-- existing p_customer. So p_segment joins p_salesperson and p_customer on the
-- `needs_lines` route and filters l.partner_id to that segment.
--
-- Three functions move together because product_facts is called by
-- product_summary (dead, kept working) and overview_facts:
--
--   product_facts    + p_segment arg, + needs_lines trigger, + two line filters
--   overview_facts   + p_segment arg, passed straight through
--   product_summary  body unchanged; its 8-arg call now binds to the only
--                    product_facts overload
--
-- Done as one transaction that captures the live bodies, rewrites two of them
-- with exact string swaps, drops the old signatures and recreates -- so the
-- 200-line product_facts body is reproduced by Postgres, never transcribed,
-- and PostgREST never sees two overloads.
--
-- Run in: Supabase -> SQL Editor.

do $do$
declare
  pf_src text;
  ps_src text;
  ov_src text;
begin
  select pg_get_functiondef(p.oid) into pf_src
  from pg_proc p
  where p.proname = 'product_facts' and p.pronamespace = 'public'::regnamespace
    and pg_get_function_identity_arguments(p.oid) not like '%p_segment%';

  select pg_get_functiondef(p.oid) into ps_src
  from pg_proc p
  where p.proname = 'product_summary' and p.pronamespace = 'public'::regnamespace;

  select pg_get_functiondef(p.oid) into ov_src
  from pg_proc p
  where p.proname = 'overview_facts' and p.pronamespace = 'public'::regnamespace
    and pg_get_function_identity_arguments(p.oid) not like '%p_segment%';

  if pf_src is null or ov_src is null then
    raise notice 'nothing to do (p_segment already present, or functions missing)';
    return;
  end if;

  -- ---- product_facts -------------------------------------------------------
  pf_src := replace(pf_src,
    'p_categories text[] DEFAULT NULL::text[])',
    'p_categories text[] DEFAULT NULL::text[], p_segment text DEFAULT NULL::text)');

  pf_src := replace(pf_src,
    '(p_salesperson is not null or p_customer is not null) as needs_lines',
    '(p_salesperson is not null or p_customer is not null or p_segment is not null) as needs_lines');

  pf_src := replace(pf_src,
    'and (p_customer    is null or l.partner_id  = p_customer)',
    'and (p_customer    is null or l.partner_id  = p_customer)' || E'\n' ||
    '      and (p_segment is null or l.partner_id in (select partner_id from public.dashboard_customers where title = p_segment))');

  -- ---- overview_facts ----------------------------------------------------
  ov_src := replace(ov_src,
    'p_product bigint DEFAULT NULL::bigint)',
    'p_product bigint DEFAULT NULL::bigint, p_segment text DEFAULT NULL::text)');

  ov_src := replace(ov_src, 'p_categories)', 'p_categories, p_segment)');

  -- ---- swap them in -----------------------------------------------------
  drop function public.overview_facts(
    date, date, text, text, bigint, text, text, text,
    integer, integer, integer, text[], bigint);
  drop function public.product_summary(
    date, date, text, text, bigint, text, text, text, integer);
  drop function public.product_facts(
    date, date, text, text, bigint, text, text, text, text[]);

  execute pf_src;
  execute ps_src;
  execute ov_src;
end
$do$;

grant execute on function public.product_facts(
  date, date, text, text, bigint, text, text, text, text[], text) to authenticated;
grant execute on function public.product_summary(
  date, date, text, text, bigint, text, text, text, integer) to authenticated;
grant execute on function public.overview_facts(
  date, date, text, text, bigint, text, text, text,
  integer, integer, integer, text[], bigint, text) to authenticated;

-- Sanity: no p_segment == the old numbers; with p_segment == that segment only.
select 'all' as scope, products, round(units) units from public.overview_facts(
  '2026-01-01','2026-08-31', null,null,null,null,null,null, 90,5,50, null, null, null)
union all
select 'ماركتات', products, round(units) from public.overview_facts(
  '2026-01-01','2026-08-31', null,null,null,null,null,null, 90,5,50, null, null, 'ماركتات');
