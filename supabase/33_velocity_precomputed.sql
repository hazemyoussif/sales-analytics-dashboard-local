-- ===========================================================================
-- 33. The last invoice-line scan on the busiest RPC
-- ===========================================================================
-- Users are hitting "canceling statement due to statement timeout" often
-- enough to report it. Measured, as service_role (300s cap) rather than
-- authenticated (20s), so the real numbers for a user are worse:
--
--   product_facts alone, warm                    3,388 ms
--   product_facts inside a real page load        7,527 ms
--
-- The page fires five calls at once and product_facts more than doubles just
-- from the competition. Two people opening Overview together is 15s; three is
-- past the cap. That is the report.
--
-- WHERE THE TIME GOES. File 19 moved period_agg onto dashboard_product_month
-- and left trailing_90 reading invoice lines, with the reasoning that it is
-- "genuinely window-scoped and bounded". It is bounded -- and it is 59,599
-- rows, aggregated per product, on every single call including the unfiltered
-- one every page makes first. Bounded is not the same as cheap.
--
-- So velocity gets the same treatment last_invoiced got in file 16: computed
-- once after each sync, read as one row per product afterwards.
--
-- WHY IT IS STILL CONDITIONAL. A precomputed trailing-90 is trailing from
-- TODAY. Someone looking at March 2025 must not be shown this week's velocity
-- with March's sales -- that is a wrong number wearing the right label, which
-- is worse than a slow page. So the precomputed value is used only when the
-- window ends within a week of today, which is the default view and the one
-- that times out; historical windows still scan, and still cost what they
-- cost.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. One more column on the table that already exists for this reason
-- ---------------------------------------------------------------------------
alter table public.dashboard_product_lastsale
  add column if not exists units_90d numeric;

comment on column public.dashboard_product_lastsale.units_90d is
  'Units sold in the 90 days before the last refresh. Trailing from the '
  'refresh date, NOT from any user-selected window -- product_facts only uses '
  'it when the selected window ends near today.';

-- ---------------------------------------------------------------------------
-- 2. Refreshed with the other summaries
-- ---------------------------------------------------------------------------
-- Folded into refresh_dashboard_summaries() rather than given its own entry
-- point, because that function already runs after every sync and returns void
-- -- so nothing downstream has a signature to change. refresh_after_sync()
-- calls it and needs no edit at all.
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

  -- `where true` satisfies pg_safeupdate, which the role PostgREST connects as
  -- has enabled and the SQL Editor's role does not. See file 29.
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

  -- Velocity. Reset every product first: one that sold 90 days ago and has not
  -- since must fall to zero, and an update driven by the sales side alone can
  -- only ever raise it. A stale non-zero velocity is what makes the reorder
  -- page recommend buying something nobody is buying.
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
end;
$$;

grant execute on function public.refresh_dashboard_summaries() to service_role;

-- ---------------------------------------------------------------------------
-- 3. product_facts, reading it
-- ---------------------------------------------------------------------------
create or replace function public.product_facts(
  p_from        date,
  p_to          date,
  p_salesperson text   default null,
  p_gov         text   default null,
  p_customer    bigint default null,
  p_category    text   default null,
  p_brand       text   default null
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
  with perms as (
    select not ('margin'      = any (h)) as c_margin,
           not ('cost'        = any (h)) as c_cost,
           not ('revenue'     = any (h)) as c_revenue,
           not ('stock_value' = any (h)) as c_stock_value,
           not ('customers'   = any (h)) as c_customers,
           public.app_table_visible('dashboard_stock')         as t_stock,
           public.app_table_visible('dashboard_invoice_lines') as t_lines
    from (select public.app_my_hidden_columns() as h) z
  ),
  filtered as (select p_salesperson is not null or p_gov is not null
                   or p_customer is not null or p_category is not null
                   or p_brand is not null as on_),
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

grant execute on function public.product_facts(date, date, text, text, bigint, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Fill it now, and prove it
-- ---------------------------------------------------------------------------
select public.refresh_dashboard_summaries();

analyze public.dashboard_product_lastsale;

select count(*) as products,
       count(*) filter (where units_90d > 0) as selling_now,
       round(sum(units_90d)) as units_last_90d
from public.dashboard_product_lastsale;
