-- ===========================================================================
-- 38. Filters that narrow each other
-- ===========================================================================
-- Asked for: pick a governorate or a city, and the other dropdowns should
-- offer only what exists inside it.
--
-- Today every dropdown lists everything, always. Choosing اربيل still offers
-- salespeople who have never sold there and categories nobody there buys, so
-- most combinations return an empty table -- and an empty table looks like a
-- broken page, not like a question with no answer. The customers page already
-- offers 18 governorates when only 16 have customers.
--
-- CITY IS NEW. dashboard_invoice_lines has carried a `city` column all along
-- and nothing has ever offered it as a filter.
--
-- THE CASCADE IS NOT SYMMETRIC, on purpose:
--
--   gov          always the full list. Narrowing the control you are standing
--                on is a trap -- pick اربيل and you can never pick anything
--                else, because اربيل is the only governorate "available".
--   city         narrowed by the chosen gov. Cities belong to governorates,
--                so this one is a real hierarchy.
--   rep/cat/brand  narrowed by city if a city is chosen, otherwise by gov.
--
-- Precomputed, like every other answer here. Doing it live would mean
-- aggregating invoice lines on every filter change, which is what the last two
-- days were spent removing.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. Which values exist inside which place
-- ---------------------------------------------------------------------------
create table if not exists public.dashboard_filter_scope (
  scope_kind  text   not null,          -- 'gov' | 'city'
  scope_value text   not null,
  kind        text   not null,          -- 'city' | 'salesperson' | 'category' | 'brand'
  value       text   not null,
  n           bigint not null,
  updated_at  timestamptz not null default now(),
  primary key (scope_kind, scope_value, kind, value)
);

create index if not exists idx_filter_scope_lookup
  on public.dashboard_filter_scope (scope_kind, scope_value, kind);

alter table public.dashboard_filter_scope enable row level security;
drop policy if exists filter_scope_read on public.dashboard_filter_scope;
create policy filter_scope_read on public.dashboard_filter_scope
  for select to authenticated using (true);
grant select on public.dashboard_filter_scope to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Built with the other summaries
-- ---------------------------------------------------------------------------
create or replace function public.refresh_filter_scope()
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare n bigint;
begin
  delete from public.dashboard_filter_scope where true;

  insert into public.dashboard_filter_scope (scope_kind, scope_value, kind, value, n)
  -- inside a governorate
  select 'gov', l.gov, 'city', l.city, count(*)
    from public.dashboard_invoice_lines l
   where l.gov is not null and l.city is not null
   group by l.gov, l.city
  union all
  select 'gov', l.gov, 'salesperson', l.salesperson, count(*)
    from public.dashboard_invoice_lines l
   where l.gov is not null and l.salesperson is not null
   group by l.gov, l.salesperson
  union all
  select 'gov', l.gov, 'category', l.category, count(*)
    from public.dashboard_invoice_lines l
   where l.gov is not null and l.category is not null
   group by l.gov, l.category
  union all
  select 'gov', l.gov, 'brand', l.brand, count(*)
    from public.dashboard_invoice_lines l
   where l.gov is not null and l.brand is not null
   group by l.gov, l.brand
  -- inside a city
  union all
  select 'city', l.city, 'salesperson', l.salesperson, count(*)
    from public.dashboard_invoice_lines l
   where l.city is not null and l.salesperson is not null
   group by l.city, l.salesperson
  union all
  select 'city', l.city, 'category', l.category, count(*)
    from public.dashboard_invoice_lines l
   where l.city is not null and l.category is not null
   group by l.city, l.category
  union all
  select 'city', l.city, 'brand', l.brand, count(*)
    from public.dashboard_invoice_lines l
   where l.city is not null and l.brand is not null
   group by l.city, l.brand;

  get diagnostics n = row_count;
  return n;
end;
$$;

grant execute on function public.refresh_filter_scope() to service_role;

-- ---------------------------------------------------------------------------
-- 3. city joins the global option list
-- ---------------------------------------------------------------------------
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

  delete from public.dashboard_filter_options where true;

  insert into public.dashboard_filter_options (kind, value, n, updated_at)
  select 'gov', gov, count(*), now() from public.dashboard_invoice_lines
    where gov is not null group by gov
  union all
  select 'city', city, count(*), now() from public.dashboard_invoice_lines
    where city is not null group by city
  union all
  select 'salesperson', salesperson, count(*), now() from public.dashboard_invoice_lines
    where salesperson is not null group by salesperson
  union all
  select 'category', category, count(*), now() from public.dashboard_invoice_lines
    where category is not null group by category
  union all
  select 'brand', brand, count(*), now() from public.dashboard_invoice_lines
    where brand is not null group by brand;

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
end;
$$;

grant execute on function public.refresh_dashboard_summaries() to service_role;

-- ---------------------------------------------------------------------------
-- 4. filter_options, now aware of where you are
-- ---------------------------------------------------------------------------
-- The zero-argument version is DROPPED, not left beside this one. A call with
-- no arguments matches both, PostgREST picks one, and the page would silently
-- get the un-narrowed list back with no error. Same trap as files 25, 31 and
-- 35; three times is enough to stop being surprised by it.
drop function if exists public.filter_options();

create or replace function public.filter_options(
  p_gov  text default null,
  p_city text default null
)
returns table (kind text, value text, n bigint)
language sql
stable
security invoker
as $$
  -- gov: never narrowed. Narrowing the control you are standing on means that
  -- once اربيل is chosen, اربيل is the only governorate on offer and there is
  -- no way back without editing the URL.
  select o.kind, o.value, o.n
  from public.dashboard_filter_options o
  where o.kind = 'gov'

  union all

  -- city: narrowed by gov, because cities really do belong to governorates.
  select s.kind, s.value, s.n
  from public.dashboard_filter_scope s
  where p_gov is not null and s.scope_kind = 'gov'
    and s.scope_value = p_gov and s.kind = 'city'
  union all
  select o.kind, o.value, o.n
  from public.dashboard_filter_options o
  where p_gov is null and o.kind = 'city'

  union all

  -- everything else: the tightest scope given wins.
  select s.kind, s.value, s.n
  from public.dashboard_filter_scope s
  where p_city is not null and s.scope_kind = 'city'
    and s.scope_value = p_city and s.kind in ('salesperson','category','brand')
  union all
  select s.kind, s.value, s.n
  from public.dashboard_filter_scope s
  where p_city is null and p_gov is not null and s.scope_kind = 'gov'
    and s.scope_value = p_gov and s.kind in ('salesperson','category','brand')
  union all
  select o.kind, o.value, o.n
  from public.dashboard_filter_options o
  where p_city is null and p_gov is null
    and o.kind in ('salesperson','category','brand')

  order by 1, 3 desc;
$$;

grant execute on function public.filter_options(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4b. product_facts learns about city
-- ---------------------------------------------------------------------------
-- Narrowing the dropdown without filtering the numbers would be worse than not
-- offering the filter: the page would look like it had applied a city and the
-- totals would be national.
--
-- A city forces the invoice-line path, like every other dimension the monthly
-- summary cannot answer -- dashboard_product_month is keyed by product and
-- month, and knows nothing about where the goods went.
--
-- The old seven-argument signature is dropped rather than left beside this
-- one, for the reason this schema has now met four times.
drop function if exists public.product_facts(date, date, text, text, bigint, text, text);

create or replace function public.product_facts(
  p_from        date,
  p_to          date,
  p_salesperson text   default null,
  p_gov         text   default null,
  p_customer    bigint default null,
  p_category    text   default null,
  p_brand       text   default null,
  p_city        text   default null
)
returns table (
  product_id         bigint,
  sku                text,
  name               text,
  category           text,
  brand              text,
  uom                text,
  cost               numeric,
  list_price         numeric,
  units              numeric,
  revenue            numeric,
  margin             numeric,
  margin_pct         numeric,
  realized_price     numeric,
  last_invoiced      date,
  distinct_customers bigint,
  distinct_govs      bigint,
  distinct_invoices  bigint,
  on_hand            numeric,
  stock_value        numeric,
  velocity_90d       numeric
)
language sql
stable
security invoker
as $$
  with perms as materialized (
    select not ('margin'      = any (h)) as c_margin,
           not ('cost'        = any (h)) as c_cost,
           not ('revenue'     = any (h)) as c_revenue,
           not ('stock_value' = any (h)) as c_stock_value,
           not ('customers'   = any (h)) as c_customers,
           public.app_table_visible('dashboard_stock')         as t_stock,
           public.app_table_visible('dashboard_invoice_lines') as t_lines
    from (select public.app_my_hidden_columns() as h) z
  ),
  -- p_city joins the list that forces the invoice lines: dashboard_product_month
  -- is keyed by product and month and knows nothing about where the goods went.
  filtered as (select p_salesperson is not null or p_gov is not null
                   or p_customer is not null or p_category is not null
                   or p_brand is not null or p_city is not null as on_),
  -- The precomputed velocity trails TODAY. It may only be used when the
  -- selected window ends near today; a week of slack covers "yesterday" and
  -- a page left open overnight without letting March 2025 borrow this week's
  -- rate. Filters force the scan too: a stored global figure cannot answer
  -- "how fast does this sell in Basra".
  use_cached as (
    select (not f.on_) and p_to >= current_date - 7 as on_ from filtered f
  ),
  period_agg as (
    select m.product_id,
           sum(m.units) as units, sum(m.revenue) as revenue, sum(m.margin) as margin,
           null::bigint as distinct_customers, null::bigint as distinct_govs,
           sum(m.invoices) as distinct_invoices
    from public.dashboard_product_month m, filtered f
    where not f.on_
      and m.month >= date_trunc('month', p_from)::date
      and m.month <= date_trunc('month', p_to)::date
    group by m.product_id
    union all
    select l.product_id,
           sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
           count(distinct l.partner_id), count(distinct l.gov),
           count(distinct l.move_id)
    from public.dashboard_invoice_lines l, filtered f
    where f.on_
      and l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_customer    is null or l.partner_id  = p_customer)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_city        is null or l.city        = p_city)
      and (p_category    is null or l.category    = p_category)
      and (p_brand       is null or l.brand       = p_brand)
    group by l.product_id
  ),
  trailing_90 as (
    select ls.product_id, ls.units_90d as units_90d
    from public.dashboard_product_lastsale ls, use_cached u
    where u.on_
    union all
    select l.product_id, sum(l.qty)
    from public.dashboard_invoice_lines l, use_cached u
    where not u.on_
      and l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date > p_to - 90 and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_customer    is null or l.partner_id  = p_customer)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_city        is null or l.city        = p_city)
      and (p_category    is null or l.category    = p_category)
      and (p_brand       is null or l.brand       = p_brand)
    group by l.product_id
  )
  select
    p.product_id, p.sku, p.name, p.category, p.brand, p.uom,
    case when pm.c_cost then p.cost end,
    p.list_price,
    case when pm.t_lines then coalesce(pe.units, 0) end,
    case when pm.t_lines and pm.c_revenue then coalesce(pe.revenue, 0) end,
    case when pm.t_lines and pm.c_margin  then coalesce(pe.margin, 0) end,
    case when pm.t_lines and pm.c_margin and coalesce(pe.revenue, 0) <> 0
         then round(100.0 * pe.margin / pe.revenue, 1) end,
    case when pm.t_lines and pm.c_revenue and coalesce(pe.units, 0) <> 0
         then pe.revenue / pe.units end,
    ls.last_invoiced,
    case when pm.t_lines and pm.c_customers then pe.distinct_customers end,
    case when pm.t_lines then pe.distinct_govs end,
    case when pm.t_lines then coalesce(pe.distinct_invoices, 0) end,
    case when pm.t_stock then coalesce(s.on_hand_qty, 0) end,
    case when pm.t_stock and pm.c_stock_value then coalesce(s.stock_value, 0) end,
    case when pm.t_lines then greatest(coalesce(tr.units_90d, 0) / 3.0, 0) end
  from public.dashboard_products p
  cross join perms pm
  left join public.dashboard_stock s             on s.product_id = p.product_id
  left join period_agg  pe                       on pe.product_id = p.product_id
  left join trailing_90 tr                       on tr.product_id = p.product_id
  left join public.dashboard_product_lastsale ls on ls.product_id = p.product_id
  where coalesce(p.category, '') !~ 'عارضات|استاندات'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = p.product_id)
    and (p_category is null or p.category = p_category)
    and (p_brand    is null or p.brand    = p_brand);
$$;

grant execute on function public.product_facts(
  date, date, text, text, bigint, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Build and prove
-- ---------------------------------------------------------------------------
select public.refresh_filter_scope() as scope_rows;
select public.refresh_dashboard_summaries();

analyze public.dashboard_filter_scope;
analyze public.dashboard_filter_options;

select scope_kind, kind, count(*) as rows
from public.dashboard_filter_scope group by 1, 2 order by 1, 2;

-- Unscoped against scoped: the second list should be materially shorter.
select 'all' as scope, kind, count(*) from public.filter_options() group by 2
union all
select 'اربيل (IQ)', kind, count(*)
from public.filter_options('اربيل (IQ)') group by 2
order by 1, 2;
