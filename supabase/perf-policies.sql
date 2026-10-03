-- ============================================================
-- RLS performance fix — run ONCE in Supabase SQL Editor.
--
-- Policies written as `using (public.dash_role() = ...)` make Postgres call
-- the function for EVERY ROW it scans (3,000+ orders × every poll).
-- Wrapping it as `(select public.dash_role())` turns it into an InitPlan:
-- evaluated ONCE per query. Same security, measurably faster scans.
-- ============================================================

drop policy if exists orders_read on public.dashboard_orders;
create policy orders_read on public.dashboard_orders
  for select to authenticated
  using (
    (select public.dash_role()) in ('admin', 'management')
    or ((select public.dash_role()) = 'alerts' and level in ('critical', 'warning'))
  );

drop policy if exists payments_read on public.dashboard_payments;
create policy payments_read on public.dashboard_payments
  for select to authenticated
  using ((select public.dash_role()) in ('admin', 'management'));

drop policy if exists customers_read on public.dashboard_customers;
create policy customers_read on public.dashboard_customers
  for select to authenticated
  using ((select public.dash_role()) in ('admin', 'management'));

drop policy if exists salespeople_read on public.salespeople;
create policy salespeople_read on public.salespeople
  for select to authenticated
  using ((select public.dash_role()) is not null);

drop policy if exists acks_read on public.alert_acks;
create policy acks_read on public.alert_acks
  for select to authenticated
  using ((select public.dash_role()) is not null);

drop policy if exists acks_insert on public.alert_acks;
create policy acks_insert on public.alert_acks
  for insert to authenticated
  with check ((select public.dash_role()) is not null);

drop policy if exists views_insert on public.page_views;
create policy views_insert on public.page_views
  for insert to authenticated
  with check (user_id = (select auth.uid()) and (select public.dash_role()) is not null);

drop policy if exists views_admin_read on public.page_views;
create policy views_admin_read on public.page_views
  for select to authenticated
  using ((select public.dash_role()) = 'admin');

drop policy if exists users_admin_read on public.dash_users;
create policy users_admin_read on public.dash_users
  for select to authenticated
  using ((select public.dash_role()) = 'admin');

drop policy if exists users_admin_update on public.dash_users;
create policy users_admin_update on public.dash_users
  for update to authenticated
  using ((select public.dash_role()) = 'admin')
  with check ((select public.dash_role()) = 'admin');

drop policy if exists users_self_read on public.dash_users;
create policy users_self_read on public.dash_users
  for select to authenticated
  using (user_id = (select auth.uid()));
