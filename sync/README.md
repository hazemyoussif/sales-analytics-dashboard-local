# sync — Odoo → Supabase, through the engine

Replaces the `n8n/` workflows. Same tables, same row shapes, same rules —
a different way of fetching, and one that does not time out.

## Why this exists

The n8n backfill asks Odoo for a whole month in one request. July 2025 is
34,081 invoice lines; Odoo has to build the entire response before sending a
byte, and it dies first. That is why 2024 and 2025 were never loaded — not a
scheduling oversight, a job that fails every time it runs.

This pages at 1,000 rows through the engine instead:

| Month | Lines | Requests | Total | Slowest single request |
|---|---|---|---|---|
| 2025-01 | 27,466 | 28 | 63s | 3.7s |
| 2025-07 | 34,081 | 35 | 88s | 4.2s |

Nothing is big enough to time out. A full backfill of all 739,220 lines is
roughly 740 requests and about 30 minutes, unattended.

## Setup

```bash
cd sync
python -m venv .venv
.venv/Scripts/pip install -r requirements.txt    # .venv/bin/pip on Linux
cp .env.example .env                             # then fill it in
```

`.env` needs the engine's URL and API key, and Supabase's URL and
**service_role** key. The anon key will not work: this process writes, and
row-level security denies the anon role every table it touches. That is also
why nothing in this package may ever be shipped to a browser.

## Jobs

```bash
python -m odoosync backfill --from 2024-01-01 --to 2026-09-01
python -m odoosync backfill --from 2024-01-01 --to 2026-09-01 --dry-run
python -m odoosync nightly            # rolling 35-day window
python -m odoosync products           # products + stock
python -m odoosync customers
python -m odoosync stock-history      # today's snapshot
python -m odoosync receivables        # who owes what, aged (debt page)
python -m odoosync branch-stock       # per-warehouse stock (branches page)
python -m odoosync product-lastsale   # when each product last sold (product pages)
python -m odoosync all                # everything except backfill
```

`--dry-run` reads from the engine and reports counts without constructing a
Supabase client at all, so it cannot write even if something later tried to.

## Two rules that must not be changed casually

**The nightly delete is not optional.** A cancelled invoice *disappears* from
`account.invoice.report`. Upserting alone would never remove its stale row, so
revenue would be overstated forever and silently. The job fetches first,
deletes the window only if the fetch returned rows, then inserts — so a failed
fetch stops the run before anything is removed, and an empty fetch never wipes
real data.

**Credit notes keep their negative sign.** They arrive from Odoo with negative
quantity and `price_subtotal`, so returns net out by plain summation. Never
`abs()` them.

## Scheduling

`odoosync` is a plain command, not a service, so what triggers it stays a
separate decision. It is now triggered by GitHub Actions, in two workflows:

| Workflow | When | What it does |
|---|---|---|
| [`sync-daily.yml`](../.github/workflows/sync-daily.yml) | 00:00 UTC = **03:00 Baghdad** | `odoosync all` — every table, ending in the summary rebuild |
| [`sync-monthly.yml`](../.github/workflows/sync-monthly.yml) | 01:00 UTC on the 1st | `backfill --replace` over the trailing 3 months, a full branch sweep, then `refresh --since` |

Both carry `workflow_dispatch`, so either can be run from the GitHub UI — on a
phone, with no laptop and no checkout. That is what replaces running these by
hand.

**The monthly one is the row the old pipeline got wrong.** n8n ran the upserts
but its backfill was written once and never scheduled to repeat, so drift
accumulated with nothing able to correct it. An upsert cannot delete; only
`--replace` can. See "Drift" below.

### Four secrets, set in the repository

`Settings → Secrets and variables → Actions`:

| Secret | Note |
|---|---|
| `ENGINE_URL` | The engine's **Render** URL, not `http://127.0.0.1:8000` |
| `ENGINE_API_KEY` | **A different key from the dashboard's** — see "The sync needs its own API key" |
| `SUPABASE_URL` | |
| `SUPABASE_SERVICE_KEY` | The service_role key |

### Two properties of the daily run worth knowing

**The engine is always cold.** It is on Render's free plan and spins down after
15 minutes idle, and the dashboard talks to Supabase rather than the engine, so
nothing keeps it warm. The first request of each run absorbs the 30–60s
spin-up, comfortably inside the client's 120s timeout. A slow first line in the
log is normal.

**`branch-sales` and `branch-revenue` read three months, not twenty-seven.**
Their standalone default is the full 27, which is right for a sweep and wrong
for a nightly job: it is the bulk of the run's time, and 24 of those months
cannot have changed since yesterday. `--months` overrides either default. The
monthly workflow does the full depth.

### `refresh --since`, and why the monthly job needs it

`refresh_after_sync()` rebuilds a **fixed** two months, chosen to cover the
35-day nightly window. A three-month `--replace` would correct the invoice
lines and leave the oldest month's summary holding the old numbers — and every
page reads the summaries, so the correction would never reach a screen. Passing
the backfill's own `--from` rebuilds exactly what was replaced:

```bash
python -m odoosync backfill --replace --from 2026-05-01 --to 2026-08-23
python -m odoosync refresh --since 2026-05-01
```

### GitHub disables idle schedules

After 60 days with no commits to the repository, scheduled workflows are turned
off. GitHub emails first. A repo under active work never reaches it; one left
alone for a quarter does, and the dashboard would quietly stop advancing.

## Verified

A dry run over June–September 2024 counted 40,673 lines. Odoo's own
`search_count` for the same filter returns 40,673.

## The sync needs its own API key

`.env.example` describes two keys — "the DASHBOARD's key" and "Ahmed's key".
Use a *different* one here from whatever the dashboard uses. The engine rate
limits **per key**, at 60 requests a minute, and a backfill runs continuously
at about 24. Share one key and a few dashboard page loads will starve the
backfill into 429s — which is exactly what happened during testing: the run
died at month 23 of 27 after exhausting all four retries against a browser
that kept asking.

## Drift: why `--replace` exists

An upsert can never delete. A cancelled invoice DISAPPEARS from
`account.invoice.report`, so its row survives every re-run forever and keeps
inflating revenue.

Measured on this database before the first full reconciliation: the range the
old n8n pipeline maintained held 150,093 rows where Odoo had 120,809 —
**29,284 phantom lines**, with nothing in the pipeline able to remove them.
The old advice to "re-run the backfill monthly to reset drift" could not have
worked, because that backfill upserted too.

```bash
python -m odoosync backfill --from 2026-01-01 --to 2026-09-01 --replace
```

Run that over the recent past monthly. It deletes each month before rewriting
it, so rows that should no longer exist actually go.

## Reconciliation, 2026-08-21

| Year | Odoo | Supabase | diff |
|---|---|---|---|
| 2024 | 127,971 | 127,971 | match |
| 2025 | 386,791 | 386,767 | −24 |
| 2026 | 224,458 | 224,413 | −45 |
| **Total** | **739,220** | **739,151** | **−69** |

Odoo holds exactly 69 lines with no `product_id`, which the transform skips —
the same rule the n8n Code node applied. Every difference is accounted for.
