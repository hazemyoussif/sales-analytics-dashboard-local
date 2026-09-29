-- ===========================================================================
-- 19. product x month summary -- the last expensive thing product_facts does
-- ===========================================================================
-- File 16 removed the two whole-table CTEs and product_facts started
-- returning. It is still not RELIABLE:
--
--   14.3s  OK        (measured after file 16)
--   20.2s  OK
--   25.5s  TIMEOUT   (server-side: canceling statement due to statement timeout)
--
-- Borderline, and borderline fails under load. The authenticated role gets
-- 20s, so a page works or dies depending on what else the database is doing.
--
-- What remains expensive is period_agg: twelve months is roughly 380,000
-- invoice lines, grouped by product, with THREE count(distinct) columns --
-- partner_id, gov and move_id. Distinct counts cannot stream; each group must
-- be accumulated. That is the cost, and no index removes it.
--
-- Those totals never change once a month is closed. Computing January's
-- figures fresh on every page load, forever, is the same waste as recomputing
-- last-sale dates was. This precomputes product x month once: roughly 1,245
-- products over 27 months, so about 20,000 rows in place of 739,151.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run. The initial build does one
-- heavy pass here, where the timeout is the editor's.

create table if not exists public.dashboard_product_month (
  product_id bigint  not null,
  month      date    not null,          -- first day of the month
  units      numeric not null default 0,
  revenue    numeric not null default 0,
  margin     numeric,
  invoices   bigint  not null default 0,   -- distinct move_id WITHIN the month
  customers  bigint  not null default 0,   -- distinct partner_id within the month
  govs       bigint  not null default 0,
  updated_at timestamptz not null default now(),
  primary key (product_id, month)
);

create index if not exists idx_prod_month_month
  on public.dashboard_product_month (month);

alter table public.dashboard_product_month enable row level security;
drop policy if exists product_month_read on public.dashboard_product_month;
create policy product_month_read on public.dashboard_product_month
  for select to authenticated using (true);
grant select on public.dashboard_product_month to authenticated;

-- ---------------------------------------------------------------------------
-- Build / rebuild
-- ---------------------------------------------------------------------------
-- Whole months only. A month is deleted before being rewritten, because an
-- upsert cannot remove a product that stopped selling in a month that has
-- since been corrected -- the same rule the invoice backfill needed --replace
-- for.
create or replace function public.refresh_product_month(p_since date default null)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  n bigint;
  cutoff date := coalesce(p_since, date '1900-01-01');
begin
  delete from public.dashboard_product_month where month >= cutoff;

  insert into public.dashboard_product_month
    (product_id, month, units, revenue, margin, invoices, customers, govs, updated_at)
  select l.product_id,
         date_trunc('month', l.invoice_date)::date,
         sum(l.qty),
         sum(l.price_subtotal),
         sum(l.price_margin),
         count(distinct l.move_id),
         count(distinct l.partner_id),
         count(distinct l.gov),
         now()
  from public.dashboard_invoice_lines l
  where l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.product_id is not null
    and l.invoice_date >= cutoff
  group by 1, 2;

  get diagnostics n = row_count;
  return n;
end;
$$;

grant execute on function public.refresh_product_month(date) to service_role;

-- ---------------------------------------------------------------------------
-- product_facts, reading months instead of lines
-- ---------------------------------------------------------------------------
-- ⚠ ONE HONEST LOSS, and it is why this was the last resort rather than the
-- first move.
--
-- units, revenue, margin and invoices survive exactly. Summing monthly totals
-- gives the same answer as summing lines, and an invoice belongs to exactly
-- one month, so distinct invoice counts add up correctly too.
--
-- distinct_customers and distinct_govs DO NOT. A customer who bought in March
-- and again in April is one customer, but two monthly rows -- adding them
-- would report two. Rather than publish a number inflated by up to the number
-- of months in the range, both are returned as NULL, which the pages render
-- as a dash.
--
-- A dash says "not measured". An inflated count says something false and
-- looks entirely reasonable. Restoring them exactly needs a product x partner
-- table, which is a much larger thing to carry.
--
-- The filters keep working against the line table, because they must: a
-- monthly summary cannot answer "this product, in Basra, sold by this rep".
-- Filtered views therefore still pay the old cost -- but the UNFILTERED
-- default, which is what every page loads first and what was timing out, no
-- longer touches the invoice lines at all.
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
                   or p_brand is not null as on_)
  ,
  -- Unfiltered: months. Filtered: lines, because a summary cannot answer a
  -- question about who bought or where.
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
  -- 90 days never spans more than four months, so this stays on the lines.
  trailing_90 as (
    select l.product_id, sum(l.qty) as units_90d
    from public.dashboard_invoice_lines l
    where l.state = 'posted' and l.move_type in ('out_invoice', 'out_refund')
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
-- Build it now
-- ---------------------------------------------------------------------------
select public.refresh_product_month() as rows_built;

analyze public.dashboard_product_month;

select count(*) as summary_rows,
       min(month) as earliest, max(month) as latest,
       round(sum(revenue)) as total_revenue
from public.dashboard_product_month;

-- ---------------------------------------------------------------------------
-- Keeping it current
-- ---------------------------------------------------------------------------
-- After each sync, refresh only the months that can still change. The nightly
-- job re-syncs 35 days, so two months always covers it:
--
--   select public.refresh_product_month((current_date - interval '2 months')::date);
--
-- A full rebuild is only needed after a backfill that reaches further back.
