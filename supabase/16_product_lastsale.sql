-- ===========================================================================
-- 16. Precompute the two things product_facts cannot afford
-- ===========================================================================
-- frozen, products, reorder and status all read product_facts, and it timed
-- out at EVERY range width -- one month exactly as badly as twenty-seven:
--
--   1 month: timeout   3 months: timeout   1 year: timeout   all: timeout
--
-- Because two of its CTEs ignore the date window entirely, and correctly so:
--
--   lastsale       max(invoice_date) per product over ALL history, because
--                  "days idle" means since it last sold at all
--   latest_labels  distinct on (product_id) ... order by invoice_date desc,
--                  sorting the whole table to label each product
--
-- Both compute a PER-PRODUCT fact. There are about 1,245 products and
-- 739,151 invoice lines, so both were deriving 1,245 answers by reading and
-- sorting 739,151 rows, on every single page load. No index fixes that; the
-- work is real. The only fix is to stop doing it repeatedly.
--
-- This is not the general "summary table" rewrite. It is one small table and
-- two CTEs removed. period_agg and trailing_90 still read the invoice lines,
-- and should -- they are genuinely window-scoped and bounded.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

create table if not exists public.dashboard_product_lastsale (
  product_id    bigint primary key,
  last_invoiced date,
  updated_at    timestamptz not null default now()
);

alter table public.dashboard_product_lastsale enable row level security;
drop policy if exists product_lastsale_read on public.dashboard_product_lastsale;
create policy product_lastsale_read on public.dashboard_product_lastsale
  for select to authenticated using (true);
grant select on public.dashboard_product_lastsale to authenticated;

-- Populate it once, here, where the statement timeout is the SQL editor's
-- rather than the 8 seconds the authenticated role gets. Afterwards the sync
-- maintains it (odoosync product-lastsale), reading the same figure straight
-- from Odoo so this scan never runs again.
insert into public.dashboard_product_lastsale (product_id, last_invoiced, updated_at)
select product_id, max(invoice_date), now()
from public.dashboard_invoice_lines
where state = 'posted'
  and move_type in ('out_invoice', 'out_refund')
  and product_id is not null
group by product_id
on conflict (product_id) do update
  set last_invoiced = excluded.last_invoiced,
      updated_at    = excluded.updated_at;

-- ---------------------------------------------------------------------------
-- product_facts, without the two whole-table passes
-- ---------------------------------------------------------------------------
-- One deliberate behaviour change, and it is an improvement rather than a
-- compromise: last_invoiced is now UNFILTERED.
--
-- Previously the filters fed lastsale, so viewing one governorate made
-- "days idle" mean "days since it last sold IN THAT GOVERNORATE" -- and a
-- product selling briskly in Baghdad appeared dead when Basra was selected.
-- Idleness is a property of the product, not of the current filter.
--
-- latest_labels is dropped outright. It existed to label a product from its
-- most recent invoice line when dashboard_products had no category or brand;
-- but that table is synced from Odoo and is the authoritative source for what
-- a product IS today, while an invoice line records what it was called when
-- it sold. Preferring the product record is more correct, and it removes a
-- 739,151-row sort.
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
  -- Both remaining CTEs are date-bounded, which is what makes them cheap.
  period_agg as (
    select l.product_id,
           sum(l.qty)                    as units,
           sum(l.price_subtotal)         as revenue,
           sum(l.price_margin)           as margin,
           count(distinct l.partner_id)  as distinct_customers,
           count(distinct l.gov)         as distinct_govs,
           count(distinct l.move_id)     as distinct_invoices
    from public.dashboard_invoice_lines l
    where l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_customer    is null or l.partner_id  = p_customer)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_category    is null or l.category    = p_category)
      and (p_brand       is null or l.brand       = p_brand)
    group by l.product_id
  ),
  trailing_90 as (
    select l.product_id, sum(l.qty) as units_90d
    from public.dashboard_invoice_lines l
    where l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date > p_to - 90 and l.invoice_date <= p_to
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_customer    is null or l.partner_id  = p_customer)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_category    is null or l.category    = p_category)
      and (p_brand       is null or l.brand       = p_brand)
    group by l.product_id
  )
  select
    p.product_id, p.sku, p.name,
    p.category,
    p.brand,
    p.uom,
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
    case when pm.t_lines and pm.c_customers then coalesce(pe.distinct_customers, 0) end,
    case when pm.t_lines then coalesce(pe.distinct_govs, 0) end,
    case when pm.t_lines then coalesce(pe.distinct_invoices, 0) end,
    case when pm.t_stock then coalesce(s.on_hand_qty, 0) end,
    case when pm.t_stock and pm.c_stock_value then coalesce(s.stock_value, 0) end,
    case when pm.t_lines then greatest(coalesce(tr.units_90d, 0) / 3.0, 0) end
  from public.dashboard_products p
  cross join perms pm
  left join public.dashboard_stock s            on s.product_id = p.product_id
  left join period_agg  pe                      on pe.product_id = p.product_id
  left join trailing_90 tr                      on tr.product_id = p.product_id
  left join public.dashboard_product_lastsale ls on ls.product_id = p.product_id
  where coalesce(p.category, '') !~ 'عارضات|استاندات'
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = p.product_id)
    and (p_category is null or p.category = p_category)
    and (p_brand    is null or p.brand    = p_brand);
$$;

grant execute on function public.product_facts(date, date, text, text, bigint, text, text)
  to authenticated;

analyze public.dashboard_product_lastsale;

select count(*) as products_with_a_last_sale,
       min(last_invoiced) as earliest,
       max(last_invoiced) as latest
from public.dashboard_product_lastsale;
