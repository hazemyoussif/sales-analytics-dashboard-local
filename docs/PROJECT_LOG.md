# Project log — what we did and where we are

A narrative record of the July 2026 overhaul. Detailed change-by-change notes
live in `CHANGELOG.md`; deep dives in `N8N_AUDIT.md`, `AUTH.md`, `METRICS.md`.

## Phase 1 — Security gate, admin panel, mobile app (Jul 7)
- **Login gate**: username/password via Supabase Auth (usernames map to
  synthetic `@dabboos.app` emails), sessions + token refresh in `auth.js`,
  page guard, and the user's JWT on every data request.
- **Roles enforced by the database (RLS)**, not the UI: `admin` (everything +
  admin panel), `management` (all pages), `alerts` (Alert Center only — the DB
  serves them only alert rows). Per-user page overrides in `dash_users.pages`.
- **Admin panel** (`admin.html`): create users, change roles/permissions,
  suspend accounts, and a traffic section fed by a `page_views` log.
- **PWA**: manifest + service worker + icons — installable on phones,
  standalone full-screen; Supabase requests are never cached.
- Go-live hiccups fixed: the auth branch initially wasn't merged (site showed
  zeros with no login); `dash_users` needed a backfill for users created
  before the trigger; two tables missed the first RLS lockdown.

## Phase 2 — Making the numbers match Odoo (Jul 7–8)
- **Daily order counts investigated**: Supabase held exactly Odoo's orders
  (913 = 913 for Jul 1–7, zero missing/duplicated). The visible "gap" was
  (a) cancelled orders Odoo's list counts but the dashboard excludes by
  policy, (b) UTC vs Baghdad day boundaries.
- Fixes: `D.bagDay()` Baghdad-day bucketing everywhere on the Overview; the
  "Orders per day" chart became a stack — confirmed + quotations + cancelled —
  whose TOTAL equals the Odoo screen.
- **City audit**: 162 distinct free-text city values; 6 unmapped ones fixed
  with evidence (customer names contain the districts); the real problem
  surfaced: 788 orders (26%) have an EMPTY City in Odoo. Data-health report
  published as an artifact.

## Phase 3 — Overview v2 + n8n audit (Jul 8)
- **Overview v2** (as analyst + owner): fixed a misleading MoM (partial month
  vs full month → same-days comparison, hidden when history can't support it);
  same-weekday benchmarks on today's KPIs; in-process cash aging (⚠ >3 days);
  receivables aging strip + credit exposure; cancel rate; top-10 customer
  concentration; weekly revenue chart; "cash in transit by holder" panel.
  Rejected during verification: "not delivered" from `delivery_count` (it
  counts pickings created at confirmation — the number would lie).
- **n8n audit** (`N8N_AUDIT.md`): 8 findings with proofs — snapshot reads
  silently truncated at Supabase's 1,000-row cap (summary said 964 July
  orders, table had 986), payment states never healing, a `limit 800` fetch
  with no date filter, 2h payment lag, an always-failing customers upsert,
  UTC day mixing, no downtime backfill, service-key hygiene.

## Phase 4 — Fixing the sync (Jul 8–11)
- **v3**: write_date-based fetching (48h lookback, states heal), pagination,
  Baghdad days in snapshots, monthly rollup, customers-cache fix attempt.
- **Payments collapse diagnosed**: the v2 fetch stopped capturing payments
  entirely (Odoo showed 118 payments/41.3M on a day the table got 0).
- **v3.1**: found the real poison — Odoo returns `false` for empty fields,
  which made PostgREST reject whole batches while "continue on error" hid the
  failure. Fixed (`false→null`, batch dedupe, fail-loudly).

## Phase 5 — Raw-tables restructure (Jul 11) ← current
Decision: **n8n is a pure fetcher; no snapshots or summaries anywhere.**
Snapshots were undebuggable black boxes; raw tables can be audited against
Odoo row-by-row.
- `supabase/restructure.sql`: new `salespeople` table; customers get the
  assigned rep (FK); orders get `partner_id` (FK) + real timestamptz dates;
  payments get real date types; indexes; RLS.
- **n8n v4 "raw only"**: all snapshot builders deleted; FK-safe upsert order
  (salespeople → customers → orders); hourly full customer-master pull.
- Dashboard: `D.api("rep_debt"/"collections"/"rep_collections")` became
  raw-table **adapters returning the old shapes** — pages unchanged.
  Verified: the new 14-day collections grid matches the last n8n snapshot
  EXACTLY (36 reps, 348.58M, every day identical).
- **Post-cutover audit**: salespeople 43 ✓; customers **6,239** with assigned
  reps ✓; 100% of today's orders carry `partner_id` ✓; payments healthy
  (169 = 51.6M today) ✓; date types converted ✓.

## Current pending checklist
- [ ] Run the `customers_read` RLS policy block (customers table is filled but
      invisible to logged-in users until then).
- [ ] Merge the **feat/raw-tables** PR (contains: Overview v2, quotations,
      city fixes, adapters, v30) → Vercel deploys.
- [ ] Deactivate old n8n workflows (v2/v3/v3.1); keep only v4.
- [ ] After a week clean: run the RETIREMENT block in `restructure.sql`
      (drop `dashboard_snapshots`, `dashboard_monthly`).
- [ ] Suspend the temporary `analyst` login (password is known).
- [ ] Rotate the Supabase service_role key and move it into an n8n credential.
- [ ] Set the real monthly revenue target in `config.js` — or better, sync
      the real per-rep targets from Odoo's `salesperson.target` model
      (see `ODOO_MODELS.md` 💎).

## Next horizons (agreed direction, not started)
1. `res.partner.state_id` + `res.city` → real governorates (kill the dictionary).
2. `sale.order.line` + product master (+ brands, cost) → products page, margins.
3. `account.move` invoices → true aging + accountant-matching revenue.
4. `salesperson.target` → real targets; `sales.visit`/routes → field-execution page.
5. Story headings on the Overview (the five questions each row answers).
