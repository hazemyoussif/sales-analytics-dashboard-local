-- ============================================================
-- Products & Warehouse tables (Odoo → n8n → Supabase → dashboard)
-- Run ONCE in the Supabase SQL editor before importing the n8n syncs.
-- RLS mirrors dashboard_orders in auth-setup.sql: authenticated users read;
-- only the service_role (used by n8n) writes.
-- ============================================================

-- Product master: identity + cost/category/brand for margin & grouping.
create table if not exists dashboard_products (
  product_id  bigint primary key,
  name        text,
  sku         text,            -- default_code
  category    text,            -- categ_id label
  brand       text,            -- product.template brand
  cost        numeric default 0,   -- standard_price
  list_price  numeric default 0,
  uom         text,
  active      boolean default true,
  updated_at  timestamptz default now()
);

-- On-hand snapshot (company-wide, all internal locations summed). Overwritten
-- each sync; products depleted to zero are zeroed by the sync's reconcile step.
create table if not exists dashboard_stock (
  product_id   bigint primary key references dashboard_products(product_id),
  on_hand_qty  numeric default 0,
  stock_value  numeric default 0,   -- cost valuation (stock.quant value:sum)
  updated_at   timestamptz default now()
);

-- Confirmed sale lines, denormalized with the order/customer keys so the page
-- can group by product x customer x city in one read.
create table if not exists dashboard_order_lines (
  line_id        bigint primary key,
  order_id       bigint,
  product_id     bigint,
  qty            numeric default 0,       -- product_uom_qty
  price_subtotal numeric default 0,       -- untaxed
  price_total    numeric default 0,       -- taxed
  date_order     timestamptz,
  partner_id     bigint,
  city           text,
  gov            text,
  salesperson    text,
  user_id        bigint,
  state          text,                    -- parent order state (sale/done)
  updated_at     timestamptz default now()
);

create index if not exists idx_ol_product on dashboard_order_lines(product_id);
create index if not exists idx_ol_date    on dashboard_order_lines(date_order);
create index if not exists idx_ol_partner on dashboard_order_lines(partner_id);
create index if not exists idx_stock_qty  on dashboard_stock(on_hand_qty);

-- ---- Row-Level Security ----
alter table dashboard_products    enable row level security;
alter table dashboard_stock       enable row level security;
alter table dashboard_order_lines enable row level security;

-- Authenticated users may read all three (same shape as dashboard_orders).
create policy p_products_read on dashboard_products
  for select to authenticated using (true);
create policy p_stock_read on dashboard_stock
  for select to authenticated using (true);
create policy p_ol_read on dashboard_order_lines
  for select to authenticated using (true);
-- No insert/update/delete policies → only the service_role key (n8n) can write.
