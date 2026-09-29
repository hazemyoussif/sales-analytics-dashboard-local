"""The two HTTP clients: read from the engine, write to Supabase.

Both exist to enforce one rule each that the callers must not have to
remember -- page every read, chunk every write.
"""

import logging
import time
from typing import Any, Iterator

import httpx

from odoosync.config import Settings

log = logging.getLogger("odoosync")

# The engine caps every response at 1000 rows and rejects a larger limit.
ENGINE_PAGE = 1000
# PostgREST accepts far more than this per request, but a failed 10k-row insert
# tells you nothing about which row was bad. 500 keeps a failure legible.
WRITE_CHUNK = 500
# A long run against a remote Odoo will meet a dropped connection eventually.
# Four attempts at 2s, 4s, 8s covers a worker recycling or a brief network
# fault without masking a server that is genuinely down.
MAX_ATTEMPTS = 4
BACKOFF_BASE = 2
# The engine rate-limits per API key at ~60/minute. A 429 clears on a
# minute boundary, not in seconds, so it gets its own long waits (30s, 60s,
# 90s) instead of the 2/4/8s that suit a dropped connection. Without this a
# sync that meets the limiter -- a cold engine, or a second sync sharing the
# key -- burns all four attempts in 14s and aborts on the first job.
RATE_LIMIT_BACKOFF = (30, 60, 90)


class EngineError(RuntimeError):
    pass


class SupabaseError(RuntimeError):
    pass


class Engine:
    """Reads Odoo through the odoo-engine's HTTP API.

    Every request is small by construction, and that is the point rather than
    a limitation: n8n's Odoo node asks for a whole month at once (34,081 rows
    for July 2025) and Odoo times out building the response. The same month
    through here is 35 requests whose slowest is about four seconds, so there
    is nothing big enough to time out.
    """

    def __init__(self, settings: Settings) -> None:
        self._url = settings.engine_url
        self._client = httpx.Client(
            headers={"X-API-Key": settings.engine_key, "Content-Type": "application/json"},
            timeout=120.0,
        )

    def close(self) -> None:
        self._client.close()

    def _post(self, endpoint: str, body: dict) -> list[dict]:
        """One request, retried through transient failures.

        A backfill is ~740 requests over half an hour against a remote Odoo.
        Something WILL drop a connection in that time -- the first full run
        died on month 17 of 27 with "Odoo RPC transport error", an empty
        transport failure meaning the far end hung up mid-response. Without
        retries a single blip discards half an hour of work.

        Only transport failures and 5xx are retried. A 4xx is this code asking
        for something wrong, and repeating it just asks again more slowly:
        those raise immediately so the mistake is visible.
        """
        last: Exception | None = None
        for attempt in range(MAX_ATTEMPTS):
            try:
                response = self._client.post(self._url + endpoint, json=body)
            except httpx.TransportError as exc:
                last = exc
                self._backoff(attempt, endpoint, f"{type(exc).__name__}: {exc}")
                continue

            if response.status_code == 200:
                return response.json()["data"]

            detail = response.text[:300]
            try:
                detail = response.json().get("detail", detail)
            except Exception:
                pass

            if response.status_code >= 500 or response.status_code == 429:
                last = EngineError(f"{endpoint} -> {response.status_code}: {detail}")
                self._backoff(attempt, endpoint, f"HTTP {response.status_code}",
                              rate_limited=response.status_code == 429)
                continue

            raise EngineError(f"{endpoint} -> {response.status_code}: {detail}")

        raise EngineError(
            f"{endpoint} failed after {MAX_ATTEMPTS} attempts; last error: {last}")

    @staticmethod
    def _backoff(attempt: int, endpoint: str, reason: str,
                 rate_limited: bool = False) -> None:
        if attempt == MAX_ATTEMPTS - 1:
            return                                  # caller raises next
        if rate_limited:
            delay = RATE_LIMIT_BACKOFF[min(attempt, len(RATE_LIMIT_BACKOFF) - 1)]
        else:
            delay = BACKOFF_BASE * (2 ** attempt)
        log.warning("%s failed (%s); retrying in %ds [attempt %d/%d]",
                    endpoint, reason, delay, attempt + 1, MAX_ATTEMPTS)
        time.sleep(delay)

    def search_read(self, model: str, domain: list, fields: list[str],
                    order: str = "id asc") -> Iterator[list[dict]]:
        """Yield pages of records.

        `order` defaults to a stable key on purpose. Paging with offset over an
        unordered result may return a row twice and skip another, producing a
        total that is wrong but entirely plausible -- the failure mode this
        whole pipeline keeps having to guard against.
        """
        offset = 0
        while True:
            started = time.perf_counter()
            page = self._post("/v1/search_read", {
                "model": model, "domain": domain, "fields": fields,
                "limit": ENGINE_PAGE, "offset": offset, "order": order,
            })
            log.debug("search_read %s offset=%d rows=%d %.0fms",
                      model, offset, len(page), (time.perf_counter() - started) * 1000)
            if page:
                yield page
            if len(page) < ENGINE_PAGE:
                return
            offset += ENGINE_PAGE

    def read_group(self, model: str, domain: list, aggregates: list[str],
                   groupby: list[str]) -> list[dict]:
        rows: list[dict] = []
        offset = 0
        while True:
            page = self._post("/v1/read_group", {
                "model": model, "domain": domain, "aggregates": aggregates,
                "groupby": groupby, "limit": ENGINE_PAGE, "offset": offset,
            })
            rows.extend(page)
            if len(page) < ENGINE_PAGE:
                return rows
            offset += ENGINE_PAGE


class Supabase:
    """Writes to PostgREST with the service-role key."""

    def __init__(self, settings: Settings) -> None:
        self._url = settings.supabase_url
        self._client = httpx.Client(
            headers={
                "apikey": settings.supabase_key,
                "Authorization": f"Bearer {settings.supabase_key}",
                "Content-Type": "application/json",
            },
            timeout=120.0,
        )

    def close(self) -> None:
        self._client.close()

    def upsert(self, table: str, rows: list[dict], on_conflict: str) -> int:
        """Insert rows, overwriting any that already exist.

        `on_conflict` should name the columns the table's UNIQUE or PRIMARY KEY
        constraint actually covers, so a re-run overwrites instead of erroring.

        Retried on the same terms as engine reads: a backfill writes hundreds
        of chunks over half an hour, and a dropped connection to Supabase
        loses the work exactly as one to Odoo does. Safe to retry because
        every write here is an upsert -- repeating it rewrites the same rows
        rather than duplicating them.
        """
        if not rows:
            return 0
        written = 0
        for start in range(0, len(rows), WRITE_CHUNK):
            chunk = rows[start:start + WRITE_CHUNK]
            last: Exception | str | None = None
            for attempt in range(MAX_ATTEMPTS):
                try:
                    response = self._client.post(
                        f"{self._url}/rest/v1/{table}",
                        params={"on_conflict": on_conflict},
                        headers={"Prefer": "resolution=merge-duplicates,return=minimal"},
                        json=chunk,
                    )
                except httpx.TransportError as exc:
                    last = exc
                    Engine._backoff(attempt, f"upsert {table}",
                                    f"{type(exc).__name__}: {exc}")
                    continue
                if response.status_code < 300:
                    break
                if response.status_code >= 500 or response.status_code == 429:
                    last = f"HTTP {response.status_code}: {response.text[:200]}"
                    Engine._backoff(attempt, f"upsert {table}",
                                    f"HTTP {response.status_code}")
                    continue
                raise SupabaseError(
                    f"upsert {table} rows {start}-{start + len(chunk)} -> "
                    f"{response.status_code}: {response.text[:300]}"
                )
            else:
                raise SupabaseError(
                    f"upsert {table} rows {start}-{start + len(chunk)} failed "
                    f"after {MAX_ATTEMPTS} attempts; last error: {last}")
            written += len(chunk)
        return written

    def delete_where(self, table: str, params: dict[str, str]) -> None:
        """Delete rows matching PostgREST filters, e.g. {'invoice_date': 'gte.2026-01-01'}."""
        response = self._client.delete(
            f"{self._url}/rest/v1/{table}", params=params,
            headers={"Prefer": "return=minimal"},
        )
        if response.status_code >= 300:
            raise SupabaseError(
                f"delete {table} {params} -> {response.status_code}: {response.text[:300]}"
            )

    def rpc(self, fn: str, args: dict | None = None, timeout: float = 300.0) -> Any:
        """Call a Postgres function.

        Used for the post-sync refreshes. Those rebuild the precomputed tables
        the dashboard reads, and without them the sync updates the raw data
        while every page keeps showing the previous run's totals -- wrong, and
        silent about it.
        """
        response = self._client.post(f"{self._url}/rest/v1/rpc/{fn}",
                                     json=args or {}, timeout=timeout)
        if response.status_code >= 300:
            raise SupabaseError(
                f"rpc {fn} -> {response.status_code}: {response.text[:300]}")
        return response.json() if response.content else None

    def select(self, table: str, select: str, order: str) -> list[dict]:
        """Read every row of a table, paged."""
        rows: list[dict] = []
        offset = 0
        while True:
            response = self._client.get(
                f"{self._url}/rest/v1/{table}",
                params={"select": select, "order": order,
                        "limit": str(ENGINE_PAGE), "offset": str(offset)},
            )
            if response.status_code >= 300:
                raise SupabaseError(
                    f"select {table} -> {response.status_code}: {response.text[:300]}")
            page = response.json()
            rows.extend(page)
            if len(page) < ENGINE_PAGE:
                return rows
            offset += ENGINE_PAGE


def m2o_id(value: Any) -> Any:
    """Odoo returns a many2one as [id, "Label"], or False when unset."""
    if isinstance(value, list):
        return value[0]
    return None if value is False or value is None else value


def m2o_label(value: Any) -> Any:
    if isinstance(value, list):
        return value[1]
    return None if value is False or value is None else value


def num(value: Any) -> float:
    if value is False or value is None:
        return 0.0
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def opt_num(value: Any) -> float | None:
    return None if value is False or value is None else num(value)


def text(value: Any) -> str | None:
    return None if value is False or value is None or value == "" else value
