"""CLI: python -m odoosync <job> [options]

Deliberately a plain command rather than a scheduled service, so what triggers
it stays a separate decision -- cron, GitHub Actions, or an n8n HTTP node --
and can be changed without touching this code.
"""

import argparse
import logging
import socket
import sys
import uuid
from datetime import date, datetime

from odoosync.clients import Engine, Supabase
from odoosync.config import MissingConfig, Settings
# branch_revenue, branch_sales and receivables are NOT imported. Their tables
# were dropped in 52_narrow_to_overview_and_customers.sql along with the Debt
# page. The functions are still in jobs.py -- if a page is ever restored,
# re-add the import, the CLI choice and the line in "all".
#
# branch_stock IS back: 64_warehouses_stock_page.sql recreated
# dashboard_branch_stock for the Warehouses page. product_expiry (74_*) feeds
# the Expiry page. Neither is in "all" -- both are stock snapshots from
# stock.quant on their own cadence. They ARE in "full", which is "all" plus
# those two: the target the "sync now" button (sync/runner.py) fires.
from odoosync.jobs import (
    branch_stock, customers, invoice_lines_backfill, invoice_lines_nightly,
    product_expiry, product_lastsale, products_and_stock, refresh_summaries,
    stock_history,
)

log = logging.getLogger("odoosync")

# One id for this invocation, so `all` shows up as a single run of ten jobs
# rather than ten unrelated ones.
RUN_ID = str(uuid.uuid4())


def _record(supa, job, fn):
    """Run one job, recording its start and outcome in dashboard_sync_runs.

    WHY EVERY WRITE HERE SITS IN ITS OWN try. This is bookkeeping, and
    bookkeeping must never be the reason a sync fails. If the status write is
    rejected, the job's own result still stands and the exception that matters
    is still the one that propagates. A monitoring layer able to turn a healthy
    run into a failed one is worse than no monitoring at all.

    The corollary is the failure this cannot see: if Supabase is unreachable,
    nothing is written, so there is no error row either. That is why
    sync_health() reports hours since the last SUCCESS rather than counting
    failures, and why the page leads with staleness instead of an error list.
    """
    if supa is None:
        return fn()

    base = {"p_run_id": RUN_ID, "p_job": job, "p_host": socket.gethostname()}

    def warn(stage, exc):
        # Truncated hard. A PostgREST error carries the whole schema-cache
        # complaint, about 400 characters, and there are two of these per job.
        # Twenty of them would bury the ten INFO lines that say what the sync
        # actually did -- in the log whose entire purpose is being readable.
        log.warning("sync_record(%s, %s) failed: %.120s", stage, job, exc)

    try:
        supa.rpc("sync_record", dict(base, p_status="running"))
    except Exception as exc:
        warn("start", exc)

    try:
        result = fn()
    except Exception as exc:
        detail = "{}: {}".format(type(exc).__name__, exc)
        try:
            # Truncated: an Odoo traceback can be enormous and the page has to
            # render it inside a table cell.
            supa.rpc("sync_record", dict(base, p_status="failed",
                                         p_error=detail[:2000]))
        except Exception as inner:
            warn("fail", inner)
        raise

    try:
        supa.rpc("sync_record", dict(base, p_status="ok",
                                     p_rows=result if isinstance(result, int) else None))
    except Exception as exc:
        warn("ok", exc)
    return result


def _date(value: str) -> date:
    try:
        return datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected YYYY-MM-DD, got {value!r}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="odoosync")
    parser.add_argument("job", choices=[
        "backfill", "nightly", "products", "customers", "stock-history",
        "product-lastsale", "branch-stock", "expiry", "refresh", "all", "full",
    ])
    parser.add_argument("--from", dest="frm", type=_date,
                        help="backfill start (YYYY-MM-DD)")
    parser.add_argument("--to", dest="to", type=_date,
                        help="backfill end, exclusive (YYYY-MM-DD)")
    parser.add_argument("--window-days", type=int, default=35,
                        help="nightly re-sync window (default 35)")
    parser.add_argument("--months", type=int,
                        help="branch-sales/branch-revenue history depth. Default 3 "
                             "inside `all`, 27 when the job is run on its own: a "
                             "daily run re-reading 27 months of stock moves spends "
                             "most of its time on months that cannot have changed.")
    parser.add_argument("--since", type=_date,
                        help="refresh: rebuild summaries from this month onward "
                             "(YYYY-MM-DD). Use the backfill's --from after a "
                             "--replace run, or the summaries keep the numbers the "
                             "backfill just corrected.")
    parser.add_argument("--replace", action="store_true",
                        help="backfill: DELETE each month before inserting, so rows "
                             "that no longer exist in Odoo are removed. Needed to "
                             "clear drift; an upsert alone can never delete.")
    parser.add_argument("--dry-run", action="store_true",
                        help="read from the engine and report counts, write nothing")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
    )
    # httpx logs one INFO line per request. A backfill makes ~740 of them,
    # which buries the per-month progress this job actually reports.
    #
    # httpcore is the one that actually matters under -v, and silencing httpx
    # alone did nothing for it: it emits five DEBUG lines per request for the
    # connection's internal state machine. Measured on a real run, ten seconds
    # of syncing produced 366 log lines of which 2 carried information -- and
    # the whole reason the scheduled runs write a log is so a person can read
    # it the morning after and see what happened.
    for noisy in ("httpx", "httpcore", "hpack"):
        logging.getLogger(noisy).setLevel(logging.WARNING)

    try:
        settings = Settings.from_env()
    except MissingConfig as exc:
        log.error("%s", exc)
        return 2

    if args.job == "backfill" and not (args.frm and args.to):
        log.error("backfill needs --from and --to")
        return 2

    engine = Engine(settings)
    # A dry run must be incapable of writing, not merely instructed not to.
    supa = None if args.dry_run else Supabase(settings)
    if args.dry_run:
        log.info("DRY RUN: reading from the engine, writing nothing")

    try:
        if args.job == "backfill":
            _run_backfill(engine, supa, args)
        elif args.job == "nightly":
            _guard(supa) or _record(supa, "nightly", lambda: invoice_lines_nightly(engine, supa, args.window_days))
        elif args.job == "products":
            _guard(supa) or _record(supa, "products", lambda: products_and_stock(engine, supa))
        elif args.job == "customers":
            _guard(supa) or _record(supa, "customers", lambda: customers(engine, supa))
        elif args.job == "stock-history":
            _guard(supa) or _record(supa, "stock-history", lambda: stock_history(supa, settings.timezone))
        elif args.job == "product-lastsale":
            _guard(supa) or _record(supa, "product-lastsale", lambda: product_lastsale(engine, supa))
        elif args.job == "branch-stock":
            _guard(supa) or _record(supa, "branch-stock", lambda: branch_stock(engine, supa))
        elif args.job == "expiry":
            _guard(supa) or _record(supa, "expiry", lambda: product_expiry(engine, supa))
        elif args.job == "refresh":
            _guard(supa) or _record(supa, "refresh", lambda: refresh_summaries(supa, args.since))
        elif args.job in ("all", "full"):
            # Order matters: stock-history snapshots dashboard_stock, so the
            # products job has to have refreshed it first or the snapshot
            # records yesterday's numbers under today's date.
            _guard(supa)
            _record(supa, "products", lambda: products_and_stock(engine, supa))
            _record(supa, "customers", lambda: customers(engine, supa))
            _record(supa, "nightly", lambda: invoice_lines_nightly(engine, supa, args.window_days))
            _record(supa, "product-lastsale", lambda: product_lastsale(engine, supa))
            # stock-history still runs even though frozen and reorder are gone.
            # It is the one table file 52 kept: a snapshot of a past day cannot
            # be recovered from Odoo later, so the series stays unbroken whether
            # or not anything reads it today. Costs ~1.5s.
            _record(supa, "stock-history", lambda: stock_history(supa, settings.timezone))
            # `full` adds the two stock snapshots that are NOT in the nightly:
            # per-warehouse free-to-use and lot expiry. They read stock.quant
            # at more depth, so they run on their own cadence normally -- but
            # the "sync now" button (sync/runner.py) means one full refresh.
            if args.job == "full":
                _record(supa, "branch-stock", lambda: branch_stock(engine, supa))
                _record(supa, "expiry", lambda: product_expiry(engine, supa))
            # Last, and never skipped: the pages read the summaries, not the
            # tables the jobs above just wrote.
            #
            # sync_health() keys "is the data current" off THIS job rather than
            # off any successful row, because it is the only one whose success
            # means the dashboard changed. Nine green jobs and a failed refresh
            # leaves every page showing the previous day's numbers.
            _record(supa, "refresh", lambda: refresh_summaries(supa, args.since))
    except Exception as exc:
        log.error("%s: %s", type(exc).__name__, exc)
        return 1
    finally:
        engine.close()
        if supa:
            supa.close()
    return 0


def _guard(supa):
    if supa is None:
        raise SystemExit("--dry-run is only supported for backfill")
    return False


def _run_backfill(engine, supa, args) -> None:
    from odoosync.jobs import _fetch_invoice_month, _months
    if supa is None:
        total = 0
        for m_from, m_to in _months(args.frm, args.to):
            rows = _fetch_invoice_month(engine, m_from, m_to)
            total += len(rows)
            log.info("would write %s: %d lines", m_from.strftime("%Y-%m"), len(rows))
        log.info("DRY RUN total: %d lines", total)
        return
    total = invoice_lines_backfill(engine, supa, args.frm, args.to, args.replace)
    log.info("backfill complete: %d lines", total)


if __name__ == "__main__":
    sys.exit(main())
