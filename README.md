# Dabboos — Sales Command Center

A live executive dashboard for a beverage retailer in Iraq. It shows confirmed
sales, collections, customer debt, regional performance, salesperson
performance, and a human-review alert center — bilingual **Arabic (RTL)** and
**English**, updating on a poll.

**Stack:** plain HTML + vanilla JS + [Chart.js](https://www.chartjs.org/) (CDN).
No build step, no framework. Data comes from **Supabase**, fed by **Odoo → n8n**.

```
Odoo (ERP)  →  n8n (sync/ETL)  →  Supabase (Postgres + REST)  →  this dashboard (browser)
```

## Pages
| File | Purpose |
|------|---------|
| `index.html` | Overview + executive summary band (revenue, cash, overdue, story) |
| `regions.html` | Confirmed sales by governorate → city |
| `salespeople.html` | Per-rep weekly/monthly performance (WoW / MoM) |
| `collections.html` | Daily cash collected per rep |
| `debt.html` | Outstanding customer receivables & overdue |
| `alerts.html` | Orders flagged for human review + acknowledgment notes |

## Run locally
The dashboard is static but must reach Supabase over the network:
```bash
python -m http.server 8123
# open http://localhost:8123/index.html
```

## Configuration
All environment values live in [`assets/js/config.js`](assets/js/config.js):
- `SUPABASE_URL` and `SUPABASE_ANON_KEY` (public anon key only — never the
  service_role key).
- `TABLES`, `POLL_MS`, `CURRENCY`, `DEFAULT_LANG`, sound settings.
- `TARGETS.MONTHLY_REVENUE_TARGET` — **set the real figure** or set to `0` to
  hide the target bar. It currently holds a placeholder.

## Documentation
- [`CLAUDE.md`](CLAUDE.md) — rules for anyone (human or AI) editing this project.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — data pipeline & tables.
- [`docs/METRICS.md`](docs/METRICS.md) — exact definition of every metric and
  its known caveats. **Read this before trusting or changing a number.**
- [`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md) — open risks and their fixes.
- [`CHANGELOG.md`](CHANGELOG.md) — notable changes.

## Security note
The dashboard exposes financial data using only the Supabase anon key. Its
safety depends entirely on **Row-Level Security** being correctly configured in
Supabase (read-only for `anon`) and on the dashboard being hosted behind an
access gate. See `docs/KNOWN_ISSUES.md`.
