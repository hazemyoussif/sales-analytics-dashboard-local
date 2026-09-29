-- ===========================================================================
-- 67. Customer segment (Title) becomes a real filter on عملاء ٨٠/٢٠
-- ===========================================================================
-- customers_pareto has ALWAYS had a p_dept argument and a `dept` return
-- column -- both dead: `dept` was `null::text` on every row and `p_dept`
-- only matched when it was null. They were placeholders for the customer
-- segment (سوبرماركت / كرزات / جملة / سلاسل), which was never synced.
--
-- 66 + the engine's res.partner allowlist change fixed the sync -- the
-- segment now lives in dashboard_customers.title -- so this wires the two
-- dead slots to it:
--
--   dept column   ->  dc.title   (so the page can group by segment)
--   p_dept        ->  filters dc.title when given
--
-- NO SIGNATURE CHANGE. p_dept is argument 4 and has been since the function
-- was written, so this is a create-or-replace in place -- no drop, no
-- PostgREST overload risk.
--
-- Done as a DO block that rewrites the LIVE definition rather than pasting a
-- 120-line body: two exact fragments swapped, the rest reproduced by Postgres
-- itself, so it cannot drift from whatever 62/53/51 last built.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run (the replaces are no-ops the
-- second time).

do $do$
declare
  src text;
begin
  select pg_get_functiondef(p.oid) into src
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'customers_pareto'
    and pg_get_function_identity_arguments(p.oid) like '%text[]%';

  if src is null then
    raise exception 'customers_pareto (text[] overload) not found';
  end if;

  -- 1. return the segment instead of the null placeholder
  src := replace(src,
    E'\n         null::text,\n         dc.salesperson,',
    E'\n         dc.title,\n         dc.salesperson,');

  -- 2. honour p_dept as a filter on the segment
  src := replace(src,
    E'\n    and p_dept is null\n',
    E'\n    and (p_dept is null or dc.title = p_dept)\n');

  execute src;
end
$do$;

-- Should now come back non-null, and filter.
select dept as segment, count(*) as customers
from public.customers_pareto(date '2025-08-01', date '2026-08-31')
group by dept order by count(*) desc;
