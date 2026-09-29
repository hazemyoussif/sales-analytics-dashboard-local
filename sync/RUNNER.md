# The "sync now" button

`runner.py` is a tiny FastAPI service that runs `python -m odoosync full` when
an **admin** presses **مزامنة الآن** on the dashboard's Sync page. The dashboard
is a static site and cannot run the CLI itself; this can.

Nothing about the sync changes — `odoosync full` is just `all` plus
`branch-stock` and `expiry`, and it writes `dashboard_sync_runs` exactly as the
cron does, so the run and its jobs appear in "التشغيلات الأخيرة" with no new
status plumbing.

## Endpoints

| | |
|---|---|
| `GET /health` | liveness; also what the service pings itself with to stay awake |
| `POST /sync`  | `Authorization: Bearer <dashboard session JWT>` → 202 and the sync starts in the background |

`POST /sync` refuses with:
- **401** no / invalid token · **403** caller is not an admin (checked via `app_me()`)
- **409** a sync is already running (this process, or a `running` row from any host in the last hour)
- **429** a sync started less than 20 minutes ago

## Deploy on Render (free)

1. **New + → Blueprint**, point at this repo. Render reads `render.yaml` and
   creates **dabboos-sync-runner**.
2. Set the secret env vars when prompted — the SAME four the CLI uses:
   `ENGINE_URL`, `ENGINE_API_KEY`, `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`.
   Use a **separate** engine API key from the dashboard's (the engine rate-limits
   per key; sharing one lets page loads starve the sync into 429s).
3. First deploy finishes and Render shows the URL
   (`https://dabboos-sync-runner.onrender.com`). Set two more env vars:
   - `RUNNER_PUBLIC_URL` = that URL. The free plan spins the box down after
     ~15 min idle; while a sync runs the service pings this every 8 min to stay
     up. Without it a 20-minute sync gets killed halfway.
   - `ALLOWED_ORIGIN` = the dashboard's origin (already defaulted to the Vercel
     domain in `render.yaml`; change if yours differs, comma-separate several).
4. In `assets/js/config.js` set `SYNC_RUNNER_URL` to the Render URL and push —
   Vercel redeploys, and the button appears for admins.

To hide the button again: set `SYNC_RUNNER_URL = ''` and push. The dashboard is
fully functional without it — the nightly GitHub Action and the local Windows
task still run the sync.

## Run it locally

```bash
cd sync
.venv/Scripts/pip install -r requirements-runner.txt
.venv/Scripts/uvicorn runner:app --port 8000
# then POST http://localhost:8000/sync with a real Bearer token
```
