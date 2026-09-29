-- ===========================================================================
-- 62. THE CUSTOMER PAGE COULD NOT TAKE A LIST OF CATEGORIES
--
-- File 61 gave Overview a category family filter and multi-select. This does
-- the same for عملاء ٨٠/٢٠, which needed a different fix.
--
-- WHY IT COULD NOT JUST SUM THE SUMMARY.
--
-- customers_pareto answers a category filter from dashboard_partner_mix_month,
-- which is keyed (partner, kind, value, month) -- ONE category per row. Summing
-- several of those rows is correct for revenue, units and margin, and WRONG
-- for the invoice count: an invoice containing products from two chosen
-- categories is counted once under each.
--
-- Measured on the هزار family, July 2026:
--     summing the mix summary   2,307 invoices   revenue 292,565,500
--     the invoice lines         1,312 invoices   revenue 292,565,500
-- Revenue agrees exactly. The invoice count is overstated by 76%.
--
-- So a list of categories takes a fourth route, through dashboard_invoice_lines
-- where count(distinct move_id) is available and correct. That route costs
-- 1,368 ms cold and 5-10 ms warm on idx_inv_lines_category_date for one month,
-- which is what this page now always asks for -- it became a single-month page
-- in the commit that replaced its four date inputs with one.
--
-- The existing three routes each gain "and not has_cats" so exactly one route
-- can fire. Miss that on any of them and two routes UNION their rows together,
-- which reads as a customer having bought twice.
--
-- Verified against the raw lines, July 2026:
--     هزار family        1,312 invoices · 292,565,500 · 8,776 units   equal
--     هزار / جكليت via LIST    822 · 143,182,250 · 4,013
--     هزار / جكليت via SCALAR  822 · 143,182,250 · 4,013   -- agree
--     no filter          2,845 · 1,173,320,358 · 33,819    -- unchanged
--
-- The scalar p_category is kept and still works, so old links resolve. The
-- page sends the list and NULL, never both: they are ANDed, and a family plus
-- one of its own members would return the member alone.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run -- the guard makes a second
-- run a no-op rather than inserting the route twice.
-- ===========================================================================

do $do$
declare s text; c int; nl text := chr(10); newroute text;
begin
  select prosrc into s from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customers_pareto';
  if s is null then raise exception 'customers_pareto not found'; end if;

  if position('p_categories' in s) > 0 then
    raise notice 'customers_pareto already takes p_categories; nothing to do';
    return;
  end if;

  s := replace(s, '    select p_category is not null as has_cat,',
    '    select coalesce(array_length(p_categories, 1), 0) > 0 as has_cats,' || nl ||
    '           p_category is not null as has_cat,');

  -- Each existing route stands down when a list is supplied. Both cur and
  -- prev carry every gate, hence the count of 2 on each.
  c := (length(s) - length(replace(s, 'where (select not has_cat and not has_brand from route)', '')))
       / length('where (select not has_cat and not has_brand from route)');
  if c <> 2 then raise exception 'partner_month gate count = %, expected 2', c; end if;
  s := replace(s, 'where (select not has_cat and not has_brand from route)',
                  'where (select not has_cat and not has_brand and not has_cats from route)');

  c := (length(s) - length(replace(s, 'where (select has_cat <> has_brand from route)', '')))
       / length('where (select has_cat <> has_brand from route)');
  if c <> 2 then raise exception 'mix gate count = %, expected 2', c; end if;
  s := replace(s, 'where (select has_cat <> has_brand from route)',
                  'where (select (has_cat <> has_brand) and not has_cats from route)');

  c := (length(s) - length(replace(s, 'where (select has_cat and has_brand from route)', '')))
       / length('where (select has_cat and has_brand from route)');
  if c <> 2 then raise exception 'lines gate count = %, expected 2', c; end if;
  s := replace(s, 'where (select has_cat and has_brand from route)',
                  'where (select has_cat and has_brand and not has_cats from route)');

  newroute :=
    '    union all' || nl ||
    '    select l.partner_id, sum(l.price_subtotal), sum(l.price_margin),' || nl ||
    '           sum(l.qty), count(distinct l.move_id)' || nl ||
    '    from public.dashboard_invoice_lines l' || nl ||
    '    where (select has_cats from route)' || nl ||
    '      and l.state = ''posted'' and l.move_type in (''out_invoice'',''out_refund'')' || nl ||
    '      and l.invoice_date >= %FROM% and l.invoice_date <= %TO%' || nl ||
    '      and l.category = any (p_categories)' || nl ||
    '      and (p_agency is null or l.brand = p_agency)' || nl ||
    '    group by l.partner_id' || nl;

  -- cur ends just before roster; prev just before last_seen. That is what
  -- separates two otherwise identical blocks.
  s := replace(s,
    '    group by l.partner_id' || nl || '  ),' || nl || '  roster as (',
    '    group by l.partner_id' || nl ||
    replace(replace(newroute, '%FROM%', 'p_from'), '%TO%', 'p_to') ||
    '  ),' || nl || '  roster as (');

  s := replace(s,
    '    group by l.partner_id' || nl || '  ),' || nl || '  last_seen as (',
    '    group by l.partner_id' || nl ||
    replace(replace(newroute, '%FROM%', '(select pf from route)'), '%TO%', '(select pt from route)') ||
    '  ),' || nl || '  last_seen as (');

  if position('has_cats from route' in s) = 0 then
    raise exception 'the new route was not inserted'; end if;

  drop function if exists public.customers_pareto(date,date,text,text,text,text,text,date,date,text,integer);
  execute 'create function public.customers_pareto('
    || 'p_from date, p_to date, p_gov text default null, p_dept text default null, '
    || 'p_salesperson text default null, p_category text default null, '
    || 'p_agency text default null, p_prev_from date default null, '
    || 'p_prev_to date default null, p_class text default null, '
    || 'p_class_year integer default 2025, p_categories text[] default null) '
    || 'returns table (partner_id bigint, customer text, gov text, dept text, '
    || 'salesperson text, revenue numeric, margin numeric, units numeric, '
    || 'invoices bigint, last_purchase date, revenue_prev numeric, margin_prev numeric, '
    || 'units_prev numeric, invoices_prev bigint, growth_pct numeric, cls text, '
    || 'avg_monthly numeric) '
    || 'language sql stable security invoker as ' || quote_literal(s);
end $do$;

-- file 54's lockdown; a dropped function takes its grants with it.
revoke execute on function
  public.customers_pareto(date,date,text,text,text,text,text,date,date,text,integer,text[])
  from public, anon;
grant execute on function
  public.customers_pareto(date,date,text,text,text,text,text,date,date,text,integer,text[])
  to authenticated;
