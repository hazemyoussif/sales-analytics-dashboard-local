-- ===========================================================================
-- 69. customers_of_product(p_from, p_to, p_product)
-- ===========================================================================
-- The عملاء ٨٠/٢٠ page gains a منتج filter (the renamed التوكيل slot). "Which
-- customers bought product X" is a filter on the invoice LINES -- customers_pareto
-- has no product dimension and five routes that would each need one. Rather
-- than open that up, this tiny helper returns the partner_ids that bought the
-- product in the window, and the page intersects its rows with that set.
--
-- One column, distinct, indexed on product_id + invoice_date -- a few ms.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

create or replace function public.customers_of_product(
  p_from    date,
  p_to      date,
  p_product bigint
)
returns table (partner_id bigint)
language sql
stable
security invoker
as $$
  select distinct l.partner_id
  from public.dashboard_invoice_lines l
  where l.product_id = p_product
    and l.state = 'posted'
    and l.move_type in ('out_invoice', 'out_refund')
    and l.invoice_date >= p_from
    and l.invoice_date <= p_to
    and l.partner_id is not null;
$$;

grant execute on function public.customers_of_product(date, date, bigint) to authenticated;
