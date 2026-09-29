-- Dabboos Product Dashboard — non-product exclusions
-- Run in: Supabase -> SQL Editor. Safe to re-run.
--
-- ===========================================================================
-- ⚠️ IF YOU RE-RUN THIS FILE, RE-RUN 05_masking.sql AFTERWARDS
-- ===========================================================================
-- Section 2 redefines product_facts. 05_masking.sql redefines it AGAIN, adding
-- the column masking that hides margin/cost/revenue from roles not allowed to
-- see them. Whichever file runs last wins.
--
-- Re-running this one alone silently removes the masking: no error, and the
-- only symptom is a restricted user quietly reading margin again.
--
-- THE PROBLEM
-- Odoo posts invoice-level adjustments as product lines. `[DISC] خصم عام علي
-- الفاتوره` is a general invoice discount carrying -44,520,000 IQD and 850
-- "units" over Apr-Jul 2026. Left alone it:
--   * appears in product rankings and in the reorder list (velocity 221/month)
--   * adds 850 meaningless units to "units sold"
--   * sits at the bottom of any margin ranking as the worst "product"
--
-- THE CONSTRAINT
-- It cannot simply be deleted. Odoo's Untaxed Total INCLUDES that discount, so
-- dropping it entirely would put revenue 0.79% out from Invoice Analysis and
-- break the reconciliation the whole dashboard rests on.
--
-- THE FIX
-- Exclude it from PRODUCT-level analysis, and report it separately as an
-- adjustment. Headline revenue = product revenue + adjustments, which still
-- ties to Odoo exactly, while no product table is polluted.

-- ===========================================================================
-- 1. The exclusion list
-- ===========================================================================
-- A table rather than a hardcoded pattern: Odoo will grow more of these
-- (delivery, rounding, service fees) and they can be added here from the
-- Supabase UI without touching any code.
create table if not exists public.dashboard_excluded_products (
  product_id  bigint primary key,
  sku         text,
  name        text,
  reason      text not null,
  excluded_at timestamptz not null default now()
);

alter table public.dashboard_excluded_products enable row level security;
drop policy if exists excluded_read on public.dashboard_excluded_products;
create policy excluded_read on public.dashboard_excluded_products
  for select to authenticated using (true);
grant select on public.dashboard_excluded_products to authenticated;

-- Seed: invoice-level discount lines, matched on SKU rather than on the name,
-- because a real product could legitimately contain the word "خصم".
insert into public.dashboard_excluded_products (product_id, sku, name, reason)
select p.product_id, p.sku, p.name, 'invoice-level discount, not a product'
from public.dashboard_products p
where upper(coalesce(p.sku, '')) in ('DISC', 'DISCOUNT')
on conflict (product_id) do nothing;

-- ===========================================================================
-- 2. product_facts — now excluding the list
-- ===========================================================================
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
  with scoped as (
    select *
    from public.dashboard_invoice_lines l
    where l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and (p_customer    is null or l.partner_id  = p_customer)
      and (p_gov         is null or l.gov         = p_gov)
      and (p_category    is null or l.category    = p_category)
      and (p_brand       is null or l.brand       = p_brand)
  ),
  period_agg as (
    select product_id,
           sum(qty)                    as units,
           sum(price_subtotal)         as revenue,
           sum(price_margin)           as margin,
           count(distinct partner_id)  as distinct_customers,
           count(distinct gov)         as distinct_govs,
           count(distinct move_id)     as distinct_invoices
    from scoped
    where invoice_date >= p_from and invoice_date <= p_to
    group by product_id
  ),
  trailing_90 as (
    select product_id, sum(qty) as units_90d
    from scoped
    where invoice_date > p_to - 90 and invoice_date <= p_to
    group by product_id
  ),
  lastsale as (
    select product_id, max(invoice_date) as last_invoiced
    from scoped
    group by product_id
  ),
  latest_labels as (
    select distinct on (product_id) product_id, category, brand
    from scoped
    order by product_id, invoice_date desc
  )
  select
    p.product_id, p.sku, p.name,
    coalesce(p.category, ll.category),
    coalesce(p.brand, ll.brand),
    p.uom, p.cost, p.list_price,
    coalesce(pe.units, 0),
    coalesce(pe.revenue, 0),
    coalesce(pe.margin, 0),
    case when coalesce(pe.revenue, 0) <> 0
         then round(100.0 * pe.margin / pe.revenue, 1) end,
    case when coalesce(pe.units, 0) <> 0
         then pe.revenue / pe.units end,
    ls.last_invoiced,
    coalesce(pe.distinct_customers, 0),
    coalesce(pe.distinct_govs, 0),
    coalesce(pe.distinct_invoices, 0),
    coalesce(s.on_hand_qty, 0),
    coalesce(s.stock_value, 0),
    greatest(coalesce(tr.units_90d, 0) / 3.0, 0)
  from public.dashboard_products p
  left join public.dashboard_stock s on s.product_id = p.product_id
  left join period_agg    pe on pe.product_id = p.product_id
  left join trailing_90   tr on tr.product_id = p.product_id
  left join lastsale      ls on ls.product_id = p.product_id
  left join latest_labels ll on ll.product_id = p.product_id
  where coalesce(p.category, '') !~ 'عارضات|استاندات'   -- fixtures, by category
    -- the individually-identified non-products (invoice discounts etc.)
    and not exists (select 1 from public.dashboard_excluded_products x
                     where x.product_id = p.product_id)
    and (p_category is null or coalesce(p.category, ll.category) = p_category)
    and (p_brand    is null or coalesce(p.brand, ll.brand)       = p_brand);
$$;

grant execute on function public.product_facts(date, date, text, text, bigint, text, text)
  to authenticated;

-- ===========================================================================
-- 3. revenue_adjustments — what product_facts leaves out
-- ===========================================================================
-- The other half of the fix. The UI shows this beside the KPI tiles so that
--     product revenue + adjustments = the figure Odoo reports
-- remains true and visible, instead of the difference being hidden.
create or replace function public.revenue_adjustments(
  p_from        date,
  p_to          date,
  p_salesperson text   default null,
  p_gov         text   default null,
  p_customer    bigint default null
)
returns table (product_id bigint, sku text, name text, reason text,
               units numeric, revenue numeric, margin numeric)
language sql
stable
security invoker
as $$
  select x.product_id, x.sku, x.name, x.reason,
         sum(l.qty), sum(l.price_subtotal), sum(l.price_margin)
  from public.dashboard_invoice_lines l
  join public.dashboard_excluded_products x on x.product_id = l.product_id
  where l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.invoice_date >= p_from and l.invoice_date <= p_to
    and (p_salesperson is null or l.salesperson = p_salesperson)
    and (p_customer    is null or l.partner_id  = p_customer)
    and (p_gov         is null or l.gov         = p_gov)
  group by x.product_id, x.sku, x.name, x.reason
  order by 6;
$$;

grant execute on function public.revenue_adjustments(date, date, text, text, bigint)
  to authenticated;

-- ===========================================================================
-- 4. Check what was excluded
-- ===========================================================================
select x.sku, x.name, x.reason,
       round(sum(l.qty))            as units,
       round(sum(l.price_subtotal)) as revenue
from public.dashboard_excluded_products x
left join public.dashboard_invoice_lines l on l.product_id = x.product_id
group by x.sku, x.name, x.reason;
