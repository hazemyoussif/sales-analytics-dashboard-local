# CLAUDE.md — guide for AI agents & developers working on this project

Read this first. It captures the non-obvious rules that keep this dashboard
trustworthy. If you change behaviour, update this file and `docs/`.

## What this is
A **static, no-build** analytics dashboard (plain HTML + vanilla JS + Chart.js
from CDN) for Dabboos, a beverage retailer in Iraq. It reads sales data directly
from **Supabase** using the public **anon key** and renders executive views in
**Arabic (RTL) and English**. There is no server, no framework, no bundler —
just open the `.html` files from a static host.

Pipeline: **Odoo → n8n → Supabase → this dashboard**. n8n syncs Odoo into
Supabase tables/snapshots; the browser reads them. See `docs/ARCHITECTURE.md`.

## The golden rule: numbers must be trustworthy
This is a CEO-facing tool. A single wrong number destroys trust in the whole
dashboard. Before changing any calculation, read `docs/METRICS.md` — it defines
every metric's exact basis (orders vs invoices, tax-inclusive vs untaxed, which
date field). **Do not mix bases.** When in doubt, label the basis in the UI
rather than guessing.

## Hard rules (do not break these)
1. **Escape all DB strings.** Any value from the database (customer/rep/city
   names, `order_name`, alert `note`, risk `reasons`) is user-controlled and
   MUST be wrapped in `D.esc(...)` before going into `innerHTML`. The alert
   `note` is written anonymously, so an unescaped render is stored XSS. Chart.js
   labels render on `<canvas>` and are safe without escaping.
2. **Never put the Supabase `service_role` key in the browser.** Only the
   `anon` key belongs in `config.js`. The anon key is only safe if Row-Level
   Security is correct — see `docs/KNOWN_ISSUES.md` #2.
3. **"Confirmed sales" = `state` is `sale` or `done`.** Quotations (`draft`,
   `sent`) and `cancel` are never counted as sales. This rule is company policy.
4. **De-dupe by primary key.** Loaders (`loadOrders`, `loadPayments`) already
   call `dedupeBy(rows, "order_id" / "payment_id")`. Keep it — the n8n sync can
   emit duplicate rows and inflate every total. Real fix is upsert in n8n.
5. **Bump the cache-buster.** Assets are referenced as `?v=NN` in every HTML
   file. If you change `common.js`/`config.js`/`auth.js`/`style.css`/
   `order-modal.js`, bump `NN` in **all** HTML files AND `VERSION` in
   `service-worker.js`, or clients keep stale code.
6. **Auth is enforced by RLS, not by the UI.** Every page loads `auth.js`
   (after `config.js`, before `common.js`); it guards the page and attaches
   the user's JWT to every Supabase call. Roles/permissions live in the
   `dash_users` table (`supabase/auth-setup.sql` + `docs/AUTH.md`). Never
   "fix" access by only hiding a nav link — the database policy is the control.
7. **The service worker must never cache Supabase requests.** Data and auth
   go straight to the network — a cached number is a wrong number.

## Where things live
- `assets/js/common.js` — the shared library: i18n, formatting, `esc`, Supabase
  API layer, governorate mapping, data loaders. Exposes everything on `window.DASH`.
- `assets/js/config.js` — Supabase URL/anon key, table names, poll interval,
  currency, targets. The only file with environment-specific values.
- `assets/js/auth.js` — the auth gate: Supabase Auth session (username →
  synthetic `@dabboos.app` email), page guard, role/permission logic, traffic
  ping. Exposes `window.DASH_AUTH`.
- `assets/js/order-modal.js` — the click-to-drill-down order modal.
- `index.html` (Overview), `regions.html`, `salespeople.html`,
  `collections.html`, `debt.html`, `alerts.html` — one file per page; each has
  an inline `<script>` that uses `window.DASH`.
- `login.html` — sign-in page; `admin.html` — admin panel (users, permissions,
  traffic). See `docs/AUTH.md`.
- `acknowledgments.html` — redirect stub (merged into `alerts.html`).
- `manifest.webmanifest`, `service-worker.js`, `assets/icons/` — PWA install
  ("add to home screen") support.
- `supabase/auth-setup.sql` — one-time script: profile + traffic tables and
  the full RLS lockdown.
- `docs/` — architecture, metric definitions, known issues, auth guide.

## Conventions
- Calendar anchors use **Asia/Baghdad**; the week starts **Saturday**.
- Money is **IQD**; `fmtMoney` compacts to K/M, `fmtMoneyFull` shows the full
  number. Never hardcode a currency symbol — use the config + `isAR()`.
- New user-facing strings go in BOTH `I18N.ar` and `I18N.en` in `common.js`,
  keyed and looked up via `D.t("key")`. Never hardcode Arabic/English in a page.
- Governorate is derived from the free-text `city` via `D.govOf()`. This is a
  best-effort fallback; the correct long-term fix is a real governorate field
  from Odoo (`res.partner.state_id`). See `docs/KNOWN_ISSUES.md` #1.

## How to run / verify
Serve the folder statically and open in a browser (it needs to reach Supabase):
```
python -m http.server 8123
# then open http://localhost:8123/index.html
```
There are no automated tests. For logic changes, extract the pure function and
test it in Node (see how `normCity`/`govOf` were validated). Syntax-check with
`node --check assets/js/common.js`.

## Verified in this state (2026-07)
`node --check` passes on all JS; `govOf` normalization has 13 passing cases;
`esc` neutralizes `<img onerror>`; all six pages load with no console errors.
