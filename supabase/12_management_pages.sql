-- ===========================================================================
-- 12. The four management pages, on real data
-- ===========================================================================
-- customers.js, agencies.js, debt.js and branches.js each name an RPC and
-- draw demo rows until it exists. This file is those RPCs.
--
-- Three of them need no new data at all -- customers_pareto, agency_lines and
-- agency_customer_matrix are pure aggregations over dashboard_invoice_lines,
-- which is already synced. They have been renderable from day one; nobody had
-- written the SQL.
--
-- Two need data Odoo has and no sync ever fetched: receivables (invoice due
-- dates and outstanding balances, which live on account.move, a different
-- model from the invoice-line report) and per-warehouse stock (stock.quant;
-- qty_available is a single company-wide number with no location in it).
-- Both tables are filled by sync/odoosync.
--
-- branch_trend is deliberately NOT here. See the note at the bottom.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. Receivables -- one row per customer, aged against their OWN terms
-- ---------------------------------------------------------------------------
create table if not exists public.dashboard_receivables (
  partner_id   bigint primary key,
  customer     text,
  gov          text,
  salesperson  text,
  balance      numeric not null default 0,   -- total outstanding
  overdue      numeric not null default 0,   -- the part past its due date
  oldest_days  integer not null default 0,   -- days past due of the oldest item
  terms_days   integer,                      -- observed, not parsed from a label
  credit_limit numeric,
  updated_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 2. Per-warehouse stock -- what qty_available cannot express
-- ---------------------------------------------------------------------------
-- Keyed on (product_id, warehouse) because a product exists in several
-- warehouses at once; that IS the pair question the branches page asks.
create table if not exists public.dashboard_branch_stock (
  product_id  bigint  not null,
  warehouse   text    not null,
  on_hand_qty numeric not null default 0,
  stock_value numeric,
  updated_at  timestamptz not null default now(),
  primary key (product_id, warehouse)
);

alter table public.dashboard_receivables   enable row level security;
alter table public.dashboard_branch_stock  enable row level security;

drop policy if exists receivables_read  on public.dashboard_receivables;
drop policy if exists branch_stock_read on public.dashboard_branch_stock;

create policy receivables_read  on public.dashboard_receivables
  for select to authenticated using (true);
create policy branch_stock_read on public.dashboard_branch_stock
  for select to authenticated using (true);

grant select on public.dashboard_receivables  to authenticated;
grant select on public.dashboard_branch_stock to authenticated;

-- ---------------------------------------------------------------------------
-- 3. customers_pareto -- revenue concentration
-- ---------------------------------------------------------------------------
-- The question is not "who is biggest" but "how few customers carry us".
-- Governorate and salesperson are per-INVOICE facts, not per-customer ones --
-- a customer can be served by two reps -- so each is attributed to whichever
-- they spent the most with, rather than whichever row happened to sort first.
create or replace function public.customers_pareto(
  p_from        date,
  p_to          date,
  p_gov         text default null,
  p_dept        text default null,
  p_salesperson text default null
)
returns table (
  partner_id    bigint,
  customer      text,
  gov           text,
  dept          text,
  salesperson   text,
  revenue       numeric,
  margin        numeric,
  units         numeric,
  invoices      bigint,
  last_purchase date
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('revenue' = any (h)) as c_revenue,
           not ('margin'  = any (h)) as c_margin
    from (select public.app_my_hidden_columns() as h) z
  ),
  scoped as (
    select l.*
    from public.dashboard_invoice_lines l
    where l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_gov         is null or l.gov         = p_gov)
      and (p_salesperson is null or l.salesperson = p_salesperson)
      and l.partner_id is not null
  ),
  agg as (
    select s.partner_id,
           sum(s.price_subtotal)      as revenue,
           sum(s.price_margin)        as margin,
           sum(s.qty)                 as units,
           count(distinct s.move_id)  as invoices,
           max(s.invoice_date)        as last_purchase
    from scoped s group by s.partner_id
  ),
  -- Dominant governorate and salesperson: highest revenue wins the label.
  dom_gov as (
    select distinct on (partner_id) partner_id, gov
    from (select partner_id, gov, sum(price_subtotal) v
          from scoped where gov is not null group by partner_id, gov) t
    order by partner_id, v desc
  ),
  dom_rep as (
    select distinct on (partner_id) partner_id, salesperson
    from (select partner_id, salesperson, sum(price_subtotal) v
          from scoped where salesperson is not null group by partner_id, salesperson) t
    order by partner_id, v desc
  )
  select a.partner_id,
         coalesce(c.complete_name, a.partner_id::text),
         coalesce(g.gov, c.governorate),
         -- No Odoo field corresponds to the dashboard's "dept". NULL rather
         -- than mapped onto sales team or category, either of which would
         -- subtotal by the wrong thing without anyone noticing.
         null::text,
         r.salesperson,
         case when pm.c_revenue then a.revenue end,
         case when pm.c_margin  then a.margin  end,
         a.units, a.invoices, a.last_purchase
  from agg a
  cross join perms pm
  left join public.dashboard_customers c on c.partner_id = a.partner_id
  left join dom_gov g on g.partner_id = a.partner_id
  left join dom_rep r on r.partner_id = a.partner_id
  where p_dept is null            -- accepted for signature compatibility
  order by a.revenue desc nulls last;
$$;

grant execute on function public.customers_pareto(date, date, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4. agency_lines -- product revenue within each agency (brand)
-- ---------------------------------------------------------------------------
-- Brand is set on only about 64% of invoice lines, so roughly a third of
-- revenue belongs to no agency. That bucket is LABELLED and returned, never
-- dropped: dropping it makes every agency total look bigger than it is and
-- puts the page a third out of step with the Overview.
create or replace function public.agency_lines(
  p_from   date,
  p_to     date,
  p_agency text default null,
  p_gov    text default null,
  p_dept   text default null
)
returns table (
  agency     text,
  product_id bigint,
  sku        text,
  name       text,
  revenue    numeric,
  margin     numeric,
  units      numeric,
  gov        text,
  dept       text,
  customers  bigint
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('revenue'   = any (h)) as c_revenue,
           not ('margin'    = any (h)) as c_margin,
           not ('customers' = any (h)) as c_customers
    from (select public.app_my_hidden_columns() as h) z
  ),
  scoped as (
    select coalesce(l.brand, 'غير محدد التوكيل') as agency, l.*
    from public.dashboard_invoice_lines l
    where l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and (p_gov is null or l.gov = p_gov)
      and not exists (select 1 from public.dashboard_excluded_products x
                       where x.product_id = l.product_id)
  )
  select s.agency, s.product_id, p.sku, p.name,
         case when pm.c_revenue then sum(s.price_subtotal) end,
         case when pm.c_margin  then sum(s.price_margin)   end,
         sum(s.qty),
         null::text, null::text,
         case when pm.c_customers then count(distinct s.partner_id) end
  from scoped s
  cross join perms pm
  left join public.dashboard_products p on p.product_id = s.product_id
  where (p_agency is null or s.agency = p_agency)
    and p_dept is null
  group by s.agency, s.product_id, p.sku, p.name,
           pm.c_revenue, pm.c_margin, pm.c_customers;
$$;

grant execute on function public.agency_lines(date, date, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5. agency_customer_matrix -- the cross-tab
-- ---------------------------------------------------------------------------
-- The EMPTY cells are the product: a customer who buys heavily from us and
-- nothing at all from one agency is a call to make this week.
-- p_agencies is the COLUMN ORDER, decided by the page and passed in. The cells
-- are POSITIONAL, so computing the ranking here instead would produce a grid
-- with every value under the wrong heading -- wrong, and still entirely
-- plausible-looking. unnest(...) with ordinality is what keeps a cell in the
-- column its caller meant.
--
-- An earlier version of this took no p_agencies and returned flat rows. Both
-- were wrong in the same dangerous direction: PostgREST answers an unknown
-- argument with "no such function", which insights.load() treats as "the RPC
-- does not exist yet" and answers with DEMO ROWS. The page would have shown
-- invented numbers with no error anywhere.
drop function if exists public.agency_customer_matrix(date, date, integer);

create or replace function public.agency_customer_matrix(
  p_from     date,
  p_to       date,
  p_limit    integer default 14,
  p_agencies text[] default '{}'
)
returns table ("rowLabel" text, cells jsonb)
language sql
stable
security invoker
as $$
  with scoped as (
    select coalesce(l.brand, 'غير محدد التوكيل') as agency,
           l.partner_id, l.price_subtotal
    from public.dashboard_invoice_lines l
    where l.state = 'posted'
      and l.move_type in ('out_invoice', 'out_refund')
      and l.invoice_date >= p_from and l.invoice_date <= p_to
      and l.partner_id is not null
  ),
  top_customers as (
    select partner_id, sum(price_subtotal) total
    from scoped group by partner_id
    order by total desc nulls last limit p_limit
  ),
  spend as (
    select s.partner_id, s.agency, sum(s.price_subtotal) as revenue
    from scoped s
    join top_customers t on t.partner_id = s.partner_id
    group by s.partner_id, s.agency
  )
  select coalesce(c.complete_name, t.partner_id::text),
         (select jsonb_agg(jsonb_build_object('value',
                    coalesce((select sp.revenue from spend sp
                              where sp.partner_id = t.partner_id
                                and sp.agency = a.name), 0))
                 order by a.ord)
          from unnest(p_agencies) with ordinality as a(name, ord))
  from top_customers t
  left join public.dashboard_customers c on c.partner_id = t.partner_id
  order by t.total desc nulls last;
$$;

grant execute on function public.agency_customer_matrix(date, date, integer, text[])
  to authenticated;

-- ---------------------------------------------------------------------------
-- 6. customer_receivables -- who owes what, and how late
-- ---------------------------------------------------------------------------
-- A balance, not a period: this takes no date range, which is why the debt
-- page kept working when every other page was collapsing to a one-day window.
create or replace function public.customer_receivables(
  p_gov         text default null,
  p_salesperson text default null
)
returns table (
  partner_id   bigint,
  customer     text,
  gov          text,
  salesperson  text,
  dept         text,
  balance      numeric,
  overdue      numeric,
  oldest_days  integer,
  terms_days   integer,
  credit_limit numeric,
  avg_pay_days integer
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('revenue' = any (h)) as c_money
    from (select public.app_my_hidden_columns() as h) z
  )
  select r.partner_id, r.customer, r.gov, r.salesperson,
         null::text,
         case when pm.c_money then r.balance end,
         case when pm.c_money then r.overdue end,
         r.oldest_days, r.terms_days,
         case when pm.c_money then r.credit_limit end,
         -- Average days-to-pay needs each invoice matched to its payment,
         -- which in Odoo runs through account.partial.reconcile: a
         -- many-to-many two hops from the invoice. The engine traverses one
         -- hop, so this is not reachable and is NULL rather than guessed.
         null::integer
  from public.dashboard_receivables r
  cross join perms pm
  where (p_gov         is null or r.gov         = p_gov)
    and (p_salesperson is null or r.salesperson = p_salesperson)
  order by r.overdue desc, r.balance desc;
$$;

grant execute on function public.customer_receivables(text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 7. branch_stock -- one branch, with the others' position beside it
-- ---------------------------------------------------------------------------
-- units_month / revenue_month / cover_days are NULL on purpose. Stock per
-- warehouse is real; SALES per warehouse is not derivable, because the invoice
-- report carries no warehouse. branches.js is explicit that substituting
-- governorate would be "wrong in a way nobody could see" -- sales TO Basra and
-- sales FROM the Basra warehouse are different quantities.
create or replace function public.branch_stock(p_warehouse text)
returns table (
  product_id        bigint,
  sku               text,
  name              text,
  agency            text,
  on_hand           numeric,
  stock_value       numeric,
  other_on_hand     numeric,
  units_month       numeric,
  revenue_month     numeric,
  cover_days        integer,
  other_units_month numeric
)
language sql
stable
security invoker
as $$
  with perms as (
    select not ('stock_value' = any (h)) as c_value
    from (select public.app_my_hidden_columns() as h) z
  ),
  here as (
    select product_id, on_hand_qty, stock_value
    from public.dashboard_branch_stock where warehouse = p_warehouse
  ),
  elsewhere as (
    select product_id, sum(on_hand_qty) qty
    from public.dashboard_branch_stock where warehouse <> p_warehouse
    group by product_id
  )
  select coalesce(h.product_id, e.product_id),
         p.sku, p.name, coalesce(p.brand, 'غير محدد التوكيل'),
         coalesce(h.on_hand_qty, 0),
         case when pm.c_value then coalesce(h.stock_value, 0) end,
         coalesce(e.qty, 0),
         null::numeric, null::numeric, null::integer, null::numeric
  from here h
  full outer join elsewhere e on e.product_id = h.product_id
  cross join perms pm
  left join public.dashboard_products p
         on p.product_id = coalesce(h.product_id, e.product_id)
  order by 6 desc nulls last, 5 desc;
$$;

grant execute on function public.branch_stock(text) to authenticated;

-- ---------------------------------------------------------------------------
-- branch_trend is NOT defined here, deliberately
-- ---------------------------------------------------------------------------
-- The page draws it as monthly revenue for one branch. That needs sales
-- attributed to a warehouse, and the invoice report has no warehouse column --
-- the same reason branch_stock returns NULL for units_month.
--
-- It could be redefined as stock VALUE per branch over time, which
-- dashboard_branch_stock will support once it has been snapshotted for a few
-- months. That is a different question from the one the chart's label asks,
-- so it is a decision to take deliberately rather than a gap to quietly fill.
-- Until then the page falls back to demo rows for this one chart and says so.

select 'ok' as status,
       (select count(*) from public.dashboard_receivables)  as receivables_rows,
       (select count(*) from public.dashboard_branch_stock) as branch_stock_rows;
