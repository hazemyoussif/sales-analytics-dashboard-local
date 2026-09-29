"""HTTP trigger for the sync -- the backend of the "sync now" button.

The dashboard is a static site; it cannot run `python -m odoosync`. This tiny
service can. One authenticated endpoint starts a FULL sync in the background
and returns immediately. Progress needs no new plumbing: odoosync writes
dashboard_sync_runs as it goes, so the Sync page's "التشغيلات الأخيرة" list
shows the run appear and its jobs turn green, exactly as for the cron.

Auth is the caller's own dashboard session token, checked against app_me() --
only a user whose role is `admin` may trigger it. The service holds the SAME
four secrets the CLI already needs (ENGINE_URL, ENGINE_API_KEY, SUPABASE_URL,
SUPABASE_SERVICE_KEY) and nothing more.

Deploy: see sync/RUNNER.md.

    uvicorn runner:app --host 0.0.0.0 --port $PORT      # from the sync/ dir
"""
from __future__ import annotations

import logging
import os
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone

import httpx
from fastapi import FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from odoosync.config import Settings

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("runner")

# A new request is refused if a sync started less than this ago. The full sync
# is ~15-20 min; 20 stops a double-click or an impatient retry without blocking
# a genuine one after a failure.
MIN_GAP_SECONDS = 20 * 60

# Render's free web service spins down after ~15 min with no inbound request.
# While a sync runs we ping our own public URL to stay up. Needs
# RUNNER_PUBLIC_URL set; without it the keepalive is simply skipped (fine on a
# paid always-on instance).
KEEPALIVE_EVERY = 8 * 60

app = FastAPI(title="dabboos sync runner")

_origin = os.environ.get("ALLOWED_ORIGIN", "*")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if _origin == "*" else [o.strip() for o in _origin.split(",")],
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["authorization", "content-type"],
)

_state = threading.Lock()
_busy = False
_started_at = 0.0


def _settings() -> Settings:
    # Read every call, not once at import: a missing var should fail the
    # request with a clear message, not crash the whole service on boot.
    return Settings.from_env()


@app.get("/health")
def health():
    return {"ok": True, "busy": _busy}


@app.post("/sync")
def sync(authorization: str | None = Header(default=None)):
    s = _settings()
    _require_admin(authorization, s)

    global _busy, _started_at
    now = time.time()
    with _state:
        if _busy:
            raise HTTPException(409, "a sync is already running")
        if now - _started_at < MIN_GAP_SECONDS:
            mins = int((MIN_GAP_SECONDS - (now - _started_at)) // 60) + 1
            raise HTTPException(429, f"a sync started recently — try again in ~{mins} min")
        # Another host (the local Windows task) may be mid-run. odoosync has no
        # cross-host lock, and invoice_lines_nightly does delete-then-insert, so
        # an overlap can race. A 'running' row in the last hour means hands off.
        other = _running_elsewhere(s)
        if other:
            raise HTTPException(409, f"a sync is already running ({other})")
        _busy = True
        _started_at = now

    threading.Thread(target=_run_full, daemon=True).start()
    log.info("sync started")
    return JSONResponse({"status": "started"}, status_code=202)


def _require_admin(authorization: str | None, s: Settings) -> None:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    url = s.supabase_url.rstrip("/") + "/rest/v1/rpc/app_me"
    try:
        # apikey = service key so Kong lets the request through; the user's
        # Bearer is what PostgREST reads for the role and auth.uid().
        r = httpx.post(url, json={}, timeout=15, headers={
            "apikey": s.supabase_key,
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        })
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"could not reach Supabase: {exc}")
    if r.status_code == 401:
        raise HTTPException(401, "session token is not valid")
    if r.status_code >= 300:
        raise HTTPException(502, f"app_me() failed: {r.status_code} {r.text[:200]}")
    rows = r.json()
    me = rows[0] if isinstance(rows, list) and rows else rows if isinstance(rows, dict) else None
    if not me or not me.get("is_admin"):
        raise HTTPException(403, "only an admin can trigger a sync")


def _running_elsewhere(s: Settings) -> str | None:
    since = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    url = s.supabase_url.rstrip("/") + "/rest/v1/dashboard_sync_runs"
    try:
        r = httpx.get(url, timeout=15, headers={
            "apikey": s.supabase_key,
            "Authorization": f"Bearer {s.supabase_key}",
        }, params={
            "select": "job,host,started_at",
            "status": "eq.running",
            "started_at": f"gt.{since}",
            "order": "started_at.desc",
            "limit": "1",
        })
        r.raise_for_status()
        rows = r.json()
    except httpx.HTTPError as exc:
        log.warning("could not check for a running sync: %s", exc)
        return None
    if not rows:
        return None
    row = rows[0]
    return f"{row.get('job')} on {row.get('host') or 'another host'}"


def _run_full() -> None:
    global _busy
    pub = os.environ.get("RUNNER_PUBLIC_URL", "").rstrip("/")
    try:
        log.info("launching: python -m odoosync full -v")
        # No stdout=PIPE: let it inherit and land in the container log stream.
        proc = subprocess.Popen([sys.executable, "-m", "odoosync", "full", "-v"])
        while True:
            try:
                rc = proc.wait(timeout=KEEPALIVE_EVERY)
                log.info("odoosync full finished rc=%s", rc)
                break
            except subprocess.TimeoutExpired:
                if pub:
                    try:
                        httpx.get(pub + "/health", timeout=10)
                        log.info("keepalive ping ok")
                    except httpx.HTTPError as exc:
                        log.warning("keepalive ping failed: %s", exc)
    except Exception as exc:  # noqa: BLE001 -- last-ditch, must always clear _busy
        log.error("sync thread crashed: %s", exc)
    finally:
        with _state:
            _busy = False
        log.info("sync thread done")
