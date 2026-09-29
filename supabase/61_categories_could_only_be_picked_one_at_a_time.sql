-- ===========================================================================
-- 61. CATEGORIES COULD ONLY BE PICKED ONE AT A TIME
--
-- Odoo names categories "family / subcategory". هزار has nine of them --
-- هزار, هزار / الواح, هزار / بسكت, هزار / جكليت, هزار / جكليت سيرين,
-- هزار / جلاتين, هزار / كاكو, هزار / هزار 2 مشكل, هزار / ويفر -- and the
-- filter was a flat list of sixty with a single selection. So "how is هزار
-- doing" took nine page loads and could not be totalled on screen at all.
--
-- Five families have more than one member: للجميع (15), هزار (9), اكوند (6),
-- دايت (6), الطون (2). Thirty-five of the sixty categories carry a family
-- prefix; the remaining twenty-five are their own family, so grouping hides
-- nothing -- every category reaches the list through exactly one family.
--
-- WHAT CHANGES IN SQL.
--
-- product_facts and overview_facts gain p_categories text[], applied at all
-- three sites the scalar is applied at: the two invoice-line routes and the
-- catalogue. The scalar p_category stays, unused by the page now but still
-- valid, so an existing link or saved query keeps working.
--
-- Both conditions are ANDed, which is why the page sends the list and NULL
-- rather than both: a family plus one of its own members would otherwise
-- return that member alone -- correct by the letter, never what was meant.
--
-- WHY THE ANCHOR IS SO LONG BELOW.
--
-- The catalogue condition
--     and (p_category is null or p.category = p_category)
-- appears TWICE in the body: once for real, and once quoted inside a comment
-- that explains why category is filtered against the product rather than the
-- line. Replacing the bare text rewrites the comment too, and the injected
-- lines then sit inside a "--" block as live SQL. That failed on the first
-- attempt with "syntax error at or near and". Anchoring on the preceding
-- line is what separates them.
--
-- Verified against the raw invoice lines for July 2026:
--   whole هزار family   8,776 units / 292,565,500  -- equal to the lines
--   هزار / جكليت alone  4,013 units / 143,182,250  -- equal to the old scalar
--   no filter          33,585 units / 1,181,451,108 -- unchanged
-- and `products` narrows with the selection: 1,431 -> 154 -> 28.
--
-- NOT DONE HERE: customers_pareto. Its category route reads
-- dashboard_partner_mix_month, which is keyed (kind, value) one category at a
-- time. Summing several values would be right for revenue, units and margin
-- and WRONG for invoices -- an invoice spanning two chosen categories would
-- be counted twice. Doing it properly means a fourth route through the
-- invoice lines, where count(distinct move_id) is available. Separate change.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run: the guard makes a second
-- run a no-op rather than applying the conditions twice.
-- ===========================================================================

do $do$
declare s text; b text; c int; anchor text;
begin
  select prosrc into s from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'product_facts';
  if s is null then raise exception 'product_facts not found'; end if;

  if position('p_categories' in s) > 0 then
    raise notice 'product_facts already takes p_categories; nothing to do';
    return;
  end if;

  -- the two invoice-line routes: period_parts (salesperson/customer) and
  -- trailing_90 route 2. Six-space indent, identical text, both wanted.
  c := (length(s) - length(replace(s, '      and (p_category    is null or l.category    = p_category)', '')))
       / length('      and (p_category    is null or l.category    = p_category)');
  if c <> 2 then raise exception 'line-route category checks = %, expected 2', c; end if;
  s := replace(s,
    '      and (p_category    is null or l.category    = p_category)',
    '      and (p_category    is null or l.category    = p_category)' || chr(10) ||
    '      and (p_categories  is null or coalesce(array_length(p_categories, 1), 0) = 0' || chr(10) ||
    '           or l.category = any (p_categories))');

  -- the catalogue, anchored on the line above it so the comment copy is safe
  anchor := '                     where x.product_id = p.product_id)' || chr(13) || chr(10) ||
            '    and (p_category is null or p.category = p_category)';
  c := (length(s) - length(replace(s, anchor, ''))) / length(anchor);
  if c <> 1 then raise exception 'catalogue anchor matched % times, expected 1', c; end if;
  s := replace(s, anchor, anchor || chr(10) ||
    '    and (p_categories is null or coalesce(array_length(p_categories, 1), 0) = 0' || chr(10) ||
    '         or p.category = any (p_categories))');

  drop function if exists public.product_facts(date,date,text,text,bigint,text,text,text);
  execute 'create function public.product_facts('
    || 'p_from date, p_to date, p_salesperson text default null, p_gov text default null, '
    || 'p_customer bigint default null, p_category text default null, '
    || 'p_brand text default null, p_city text default null, '
    || 'p_categories text[] default null) '
    || 'returns table (product_id bigint, sku text, name text, category text, brand text, '
    || 'uom text, cost numeric, list_price numeric, units numeric, revenue numeric, '
    || 'margin numeric, margin_pct numeric, realized_price numeric, last_invoiced date, '
    || 'distinct_customers bigint, distinct_govs bigint, distinct_invoices bigint, '
    || 'on_hand numeric, stock_value numeric, velocity_90d numeric, '
    || 'returned_units numeric, returned_value numeric) '
    || 'language sql stable security invoker as ' || quote_literal(s);

  -- overview_facts only has to hand the list through to product_facts. Its
  -- own return type is unchanged; the new argument goes LAST so any existing
  -- positional call still resolves.
  select prosrc into s from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'overview_facts';
  b := s;
  s := replace(s,
    'p_from, p_to, p_salesperson, p_gov, p_customer, p_category, p_brand, p_city)',
    'p_from, p_to, p_salesperson, p_gov, p_customer, p_category, p_brand, p_city,' || chr(10) ||
    '      p_categories)');
  if s = b then raise exception 'product_facts call site not found in overview_facts'; end if;

  drop function if exists public.overview_facts(date,date,text,text,bigint,text,text,text,integer,integer,integer);
  execute 'create function public.overview_facts('
    || 'p_from date, p_to date, p_salesperson text default null, p_gov text default null, '
    || 'p_customer bigint default null, p_category text default null, '
    || 'p_brand text default null, p_city text default null, '
    || 'p_idle_days integer default 90, p_top integer default 200, p_unsold integer default 50, '
    || 'p_categories text[] default null) '
    || 'returns table (products bigint, sold bigint, units numeric, revenue numeric, '
    || 'stock_value numeric, frozen_count bigint, frozen_value numeric, '
    || 'unsold_count bigint, unsold_value numeric, top jsonb, unsold jsonb, by_category jsonb) '
    || 'language sql stable security invoker as ' || quote_literal(s);
end $do$;

-- file 54's lockdown. Dropping a function drops its grants, and PUBLIC would
-- otherwise get EXECUTE back by default.
revoke execute on function
  public.product_facts(date,date,text,text,bigint,text,text,text,text[])
  from public, anon;
grant execute on function
  public.product_facts(date,date,text,text,bigint,text,text,text,text[])
  to authenticated;

revoke execute on function
  public.overview_facts(date,date,text,text,bigint,text,text,text,integer,integer,integer,text[])
  from public, anon;
grant execute on function
  public.overview_facts(date,date,text,text,bigint,text,text,text,integer,integer,integer,text[])
  to authenticated;
