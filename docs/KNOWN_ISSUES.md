# Known issues & open risks

Status legend: ✅ fixed · 🟡 mitigated (real fix elsewhere) · 🔴 open (needs you)

Ordered by business impact. Items 1–4 are what the CEO/manager can see; 5–9 are
engineering risks.

---

## 1. 🟡 Governorate "Unknown / غير محدد" bucket
**Symptom (manager, 2026-07):** regions numbers look wrong and there's a mystery
"غير محدد" bucket even though all governorates are known.

**Cause:** the governorate is *guessed in the browser* from the free-text `city`
field via a hardcoded dictionary. Any spelling/prefix/typo the dictionary
doesn't know falls into "Unknown."

**Done in this pass:**
- Rewrote `normCity()` + `govOf()` to normalize Arabic (diacritics, alef/ya/
  hamza/ta-marbuta, **Persian letters**), strip prefixes (`محافظة`, `حي`, …),
  match governorate names directly, and do token matching inside compound
  strings. 13 unit cases pass.
- Regions page now shows an **"Unmapped cities" banner** with the count/value/%
  in Unknown, so it's visible instead of silent.

**Done 2026-07-05 (data-driven dictionary pass):**
- Pulled every live `city` value (2,629 orders) and classified them: 780 orders /
  303M IQD were "Unknown", but **701 of those (239M) had an empty city field** —
  a data-entry gap in Odoo, not a dictionary gap.
- **Split the bucket:** `govOf("")` now returns a distinct **`nocity` ("بدون
  مدينة / No city")** governorate, and the Regions banner shows two separate
  lines with two separate fixes: *no city in Odoo → fill the customer's City
  field* (red) vs. *unrecognized city name → add to dictionary* (amber).
- **Mapped all 26 remaining real strings** by cross-checking geography against
  the owning rep's territory (each rep's other orders are 68–100% one
  governorate). True "Unknown" is now **2 orders / ~3M IQD** (garbage values
  `٩٩`, `داكير` — fix those in Odoo).
- 23/23 regression cases pass (original 13 + new mappings + the nocity split).

**Real fix (backend, not done here):** sync a real governorate from Odoo
(`res.partner.state_id` or delivery address) into `dashboard_orders`, and use the
dictionary only as a fallback. This removes the guessing entirely.

## 2. 🟡 Security model depends on RLS — now captured in the repo
`config.js` used to point at a `supabase/schema.sql` that didn't exist. The
policies are now **written down and reproducible**: `supabase/auth-setup.sql`
revokes all `anon` access and grants reads to logged-in, active users only
(per-role — see `docs/AUTH.md`). 🟡 not ✅ because it's only real once the
script has actually been **run** in the Supabase project — verify with
`select * from pg_policies where schemaname = 'public';`.

## 3. ✅ No authentication in front of financial data (FIXED 2026-07)
The dashboard is now behind a username/password gate (Supabase Auth) with
roles (`admin` / `management` / `alerts`) enforced by Row-Level Security, a
login page, and an admin panel for user/permission management + traffic.
See `docs/AUTH.md` for setup and the security model's honest boundaries.

## 4. 🟡 "606 orders" — possible duplicate sync rows
A count that looks impossibly high is usually duplicate rows in
`dashboard_orders` (n8n appending instead of upserting).

**Done in this pass:** loaders now **de-duplicate by `order_id` / `payment_id`**
client-side, so the UI counts each order once even if the table has duplicates.

**Real fix (backend):** make the n8n sync **upsert on the primary key** so
duplicates never land in the table. Verify with
`select count(*), count(distinct order_id) from dashboard_orders;`.

## 4b. ✅ Snapshot pipeline retired (FIXED 2026-07-11)
All n8n-computed snapshots/summaries (`rep_debt`, `rep_collections`,
`collections`, plus the never-used `summary`/`trends`/`reps`/`regions`/
`salespeople`) are replaced by raw-table adapters in `common.js` — every
aggregate is now computed from rows that can be checked against Odoo
directly. This closes the whole class of snapshot bugs found in
`docs/N8N_AUDIT.md` (1,000-row truncation, UTC/Baghdad mixing, staleness).
Schema is relational now (`supabase/restructure.sql`: `salespeople` +
FKs + timestamptz). Drop `dashboard_snapshots`/`dashboard_monthly` after a
week of clean v4 operation.

## 5. 🔴 Full-window polling re-downloads everything every 60s
`sbGetAll()` pulls the entire orders + payments window on every poll, on every
page, in every open tab — no delta, no cache. Fine now; costly as data grows.
Consider incremental fetch (`create_date > lastSeen`) or moving heavy pages onto
server-side snapshots (the `dashboard_snapshots` pattern already exists).

## 6. ✅ Stored XSS via unescaped DB strings (FIXED)
DB strings (esp. the anonymously-written alert `note`) were rendered via
`innerHTML` with no escaping — a stored-XSS hole. **Fixed:** added `D.esc()` and
wrapped every DB-derived value across all pages and the order modal. Verified
`esc('<img onerror=x>')` is neutralized in-browser.

## 7. 🔴 Chart.js loaded from CDN without integrity hash
Four pages load `cdn.jsdelivr.net/npm/chart.js@4.4.1` with no SRI and no
fallback. Pin with `integrity=`/`crossorigin`, or vendor it into `assets/`.
(Left as-is here to avoid shipping a wrong hash that would break rendering —
compute the real sha384 first, or self-host.)

## 8. ✅ Stale "n8n" references (FIXED)
Error text and comments referenced a non-existent `N8N_BASE`; the app reads
Supabase directly. **Fixed** in `common.js` (error messages), `config.js`, and
`order-modal.js` (header comment).

## 9. 🔴 Placeholder revenue target shown as real
`MONTHLY_REVENUE_TARGET = 900,000,000` is a placeholder but the Overview shows
"% of target" / "on pace" as if real. Set the true figure, or `0` to hide the
target band. (Comment in `config.js` now warns about this.)

## Minor
- Manual `?v=NN` cache-busting across 6 files is easy to desync — automate it.
- No retry/backoff: a transient fetch failure blanks state and shows an error
  until the next poll. Consider keeping last-good data + backoff.
- Rep identity: some views key on `user_id`, the filter matches on `salesperson`
  name — a renamed/duplicate-named rep can split or merge.
- No README/LICENSE historically; README + docs added in this pass.
