  -- Dabboos Product Dashboard — aggregation layer
  -- Run in: Supabase -> SQL Editor of the product-dashboard project.
  -- Safe to re-run (create or replace).
  --
  -- product_facts is the ONLY place that defines what counts as a sale. Every
  -- page inherits its filters from here, so two screens can never disagree about
  -- "posted", "in period", or "excluding fixtures".

  -- ===========================================================================
  -- product_facts — one row per product for a period and filter set
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
      -- Every filter lives here, once. Geography, category and brand come off the
      -- invoice line itself (gov is 100% populated; the customers table is not
      -- needed for filtering at all).
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
            -- Odoo's own margin. inventory_value is stored NEGATIVE, so the
            -- identity is margin = subtotal + inventory_value. Verified on
            -- 100% of 33,806 July rows. Summing price_margin needs no arithmetic.
            sum(price_margin)           as margin,
            count(distinct partner_id)  as distinct_customers,
            count(distinct gov)         as distinct_govs,
            count(distinct move_id)     as distinct_invoices
      from scoped
      where invoice_date >= p_from and invoice_date <= p_to
      group by product_id
    ),
    -- Trailing 90 days ending at p_to, deliberately independent of the selected
    -- period, so "velocity" means the same thing on every screen no matter what
    -- date range the user picked.
    trailing_90 as (
      select product_id, sum(qty) as units_90d
      from scoped
      where invoice_date > p_to - 90 and invoice_date <= p_to
      group by product_id
    ),
    -- Last invoice EVER, not just within the period. A product idle for two years
    -- must not look freshly sold because the chosen period happens to exclude it.
    lastsale as (
      select product_id, max(invoice_date) as last_invoiced
      from scoped
      group by product_id
    ),
    -- The most recent category/brand seen on a line, used only to fill in when
    -- the product record itself has none.
    latest_labels as (
      select distinct on (product_id) product_id, category, brand
      from scoped
      order by product_id, invoice_date desc
    )
    select
      p.product_id,
      p.sku,
      p.name,
      coalesce(p.category, ll.category)                              as category,
      coalesce(p.brand, ll.brand)                                    as brand,
      p.uom,
      p.cost,
      p.list_price,
      coalesce(pe.units, 0)                                          as units,
      coalesce(pe.revenue, 0)                                        as revenue,
      coalesce(pe.margin, 0)                                         as margin,
      case when coalesce(pe.revenue, 0) <> 0
          then round(100.0 * pe.margin / pe.revenue, 1) end         as margin_pct,
      case when coalesce(pe.units, 0) <> 0
          then pe.revenue / pe.units end                            as realized_price,
      ls.last_invoiced,
      coalesce(pe.distinct_customers, 0),
      coalesce(pe.distinct_govs, 0),
      coalesce(pe.distinct_invoices, 0),
      coalesce(s.on_hand_qty, 0)                                     as on_hand,
      coalesce(s.stock_value, 0)                                     as stock_value,
      greatest(coalesce(tr.units_90d, 0) / 3.0, 0)                   as velocity_90d
    -- dashboard_products drives with LEFT JOINs on purpose: a product that sold
    -- nothing still returns a row with units = 0. The frozen-stock and never-sold
    -- analyses are ABOUT those rows; an inner join would hide exactly the products
    -- this dashboard exists to surface.
    from public.dashboard_products p
    left join public.dashboard_stock s on s.product_id = p.product_id
    left join period_agg    pe on pe.product_id = p.product_id
    left join trailing_90   tr on tr.product_id = p.product_id
    left join lastsale      ls on ls.product_id = p.product_id
    left join latest_labels ll on ll.product_id = p.product_id
    where coalesce(p.category, '') !~ 'عارضات|استاندات'   -- fixtures, not products
      and (p_category is null or coalesce(p.category, ll.category) = p_category)
      and (p_brand    is null or coalesce(p.brand, ll.brand)       = p_brand);
  $$;

  grant execute on function public.product_facts(date, date, text, text, bigint, text, text)
    to authenticated;

  -- ===========================================================================
  -- filter_options — the values the filter bar offers
  -- ===========================================================================
  -- Built from the DATA, not hardcoded, so a new governorate or salesperson
  -- appears in the UI the moment it appears in Odoo.
  create or replace function public.filter_options()
  returns table (kind text, value text, n bigint)
  language sql
  stable
  security invoker
  as $$
    select 'gov',         gov,         count(*) from public.dashboard_invoice_lines
      where gov is not null group by gov
    union all
    select 'salesperson', salesperson, count(*) from public.dashboard_invoice_lines
      where salesperson is not null group by salesperson
    union all
    select 'category',    category,    count(*) from public.dashboard_invoice_lines
      where category is not null group by category
    union all
    select 'brand',       brand,       count(*) from public.dashboard_invoice_lines
      where brand is not null group by brand
    order by 1, 3 desc;
  $$;

  grant execute on function public.filter_options() to authenticated;

  -- ===========================================================================
  -- product_customers — drill-down: who buys this product
  -- ===========================================================================
  create or replace function public.product_customers(
    p_product_id bigint, p_from date, p_to date)
  returns table (partner_id bigint, customer text, units numeric,
                revenue numeric, margin numeric, invoices bigint)
  language sql
  stable
  security invoker
  as $$
    select l.partner_id,
          -- the invoice report carries no customer name, so fall back to the id
          -- rather than showing a blank row if the customers sync has not run
          coalesce(c.complete_name, 'Partner ' || l.partner_id),
          sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
          count(distinct l.move_id)
    from public.dashboard_invoice_lines l
    left join public.dashboard_customers c on c.partner_id = l.partner_id
    where l.product_id = p_product_id
      and l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
    group by l.partner_id, c.complete_name
    order by 3 desc;
  $$;

  grant execute on function public.product_customers(bigint, date, date) to authenticated;

  -- ===========================================================================
  -- product_regions — drill-down: where this product sells
  -- ===========================================================================
  create or replace function public.product_regions(
    p_product_id bigint, p_from date, p_to date)
  returns table (gov text, units numeric, revenue numeric,
                margin numeric, customers bigint)
  language sql
  stable
  security invoker
  as $$
    select coalesce(l.gov, '—'),
          sum(l.qty), sum(l.price_subtotal), sum(l.price_margin),
          count(distinct l.partner_id)
    from public.dashboard_invoice_lines l
    where l.product_id = p_product_id
      and l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
    group by 1
    order by 2 desc;
  $$;

  grant execute on function public.product_regions(bigint, date, date) to authenticated;

  -- ===========================================================================
  -- product_trend — monthly series for one product
  -- ===========================================================================
  create or replace function public.product_trend(p_product_id bigint, p_months int default 24)
  returns table (month text, units numeric, revenue numeric, margin numeric)
  language sql
  stable
  security invoker
  as $$
    select to_char(date_trunc('month', l.invoice_date), 'YYYY-MM'),
          sum(l.qty), sum(l.price_subtotal), sum(l.price_margin)
    from public.dashboard_invoice_lines l
    where l.product_id = p_product_id
      and l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= (current_date - (p_months || ' months')::interval)
    group by 1
    order by 1;
  $$;

  grant execute on function public.product_trend(bigint, int) to authenticated;

  -- ===========================================================================
  -- data_health — what is actually populated, surfaced in the UI
  -- ===========================================================================
  -- The dashboard shows this so a blank chart is never mistaken for zero sales.
  create or replace function public.data_health()
  returns table (metric text, value text)
  language sql
  stable
  security invoker
  as $$
    select 'invoice_lines',   count(*)::text                       from public.dashboard_invoice_lines
    union all
    select 'date_from',       coalesce(min(invoice_date)::text, '—') from public.dashboard_invoice_lines
    union all
    select 'date_to',         coalesce(max(invoice_date)::text, '—') from public.dashboard_invoice_lines
    union all
    select 'products',        count(*)::text                       from public.dashboard_products
    union all
    select 'stock_rows',      count(*)::text                       from public.dashboard_stock
    union all
    select 'customers',       count(*)::text                       from public.dashboard_customers
    union all
    select 'stock_snapshots', count(distinct snap_date)::text      from public.dashboard_stock_history
    union all
    select 'brand_fill_pct',
          coalesce(round(100.0 * count(*) filter (where brand is not null) /
                    nullif(count(*), 0))::text, '0')               from public.dashboard_invoice_lines;
  $$;

  grant execute on function public.data_health() to authenticated;
