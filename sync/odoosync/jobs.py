"""The sync jobs, replacing the n8n workflows of the same names.

Each transform below is a direct port of the corresponding n8n Code node, and
the comments explaining WHY a rule exists were kept with it. Those rules are
the accumulated result of things that went wrong once; re-deriving them from
the schema alone is not possible.
"""

import logging
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from odoosync.clients import Engine, Supabase, m2o_id, m2o_label, num, opt_num, text

log = logging.getLogger("odoosync")

# Posted customer documents. Credit notes (out_refund) are INCLUDED and arrive
# with negative quantity and price_subtotal, so every sum nets returns
# automatically. Never abs() these.
INVOICE_DOMAIN = [
    ["state", "=", "posted"],
    ["move_type", "in", ["out_invoice", "out_refund"]],
]

INVOICE_FIELDS = [
    "move_id", "product_id", "quantity", "price_subtotal", "price_total",
    "invoice_date", "commercial_partner_id", "partner_id", "invoice_user_id",
    "move_type", "state", "payment_state", "price_margin", "inventory_value",
    "product_categ_id", "product_brand_id", "state_id", "city_id", "team_id",
]


def _invoice_row(r: dict) -> dict | None:
    """account.invoice.report -> dashboard_invoice_lines."""
    product_id = m2o_id(r.get("product_id"))
    if not product_id or not r.get("invoice_date"):
        return None
    return {
        "line_id": r["id"],
        "move_id": m2o_id(r.get("move_id")),
        "product_id": product_id,
        "qty": num(r.get("quantity")),
        "price_subtotal": num(r.get("price_subtotal")),
        "price_total": opt_num(r.get("price_total")),
        "price_margin": opt_num(r.get("price_margin")),
        "inventory_value": opt_num(r.get("inventory_value")),
        "invoice_date": str(r["invoice_date"])[:10],
        # commercial_partner_id is the invoicing entity; partner_id may be a
        # delivery contact under it. Falling back keeps a row attributable
        # rather than dropping it.
        "partner_id": m2o_id(r.get("commercial_partner_id")) or m2o_id(r.get("partner_id")),
        "salesperson": m2o_label(r.get("invoice_user_id")),
        "user_id": m2o_id(r.get("invoice_user_id")),
        "move_type": r.get("move_type"),
        "state": r.get("state"),
        "payment_state": r.get("payment_state") or None,
        "product_categ_id": m2o_id(r.get("product_categ_id")),
        "category": m2o_label(r.get("product_categ_id")),
        "product_brand_id": m2o_id(r.get("product_brand_id")),
        "brand": m2o_label(r.get("product_brand_id")),
        "state_id": m2o_id(r.get("state_id")),
        "gov": m2o_label(r.get("state_id")),
        "city_id": m2o_id(r.get("city_id")),
        "city": m2o_label(r.get("city_id")),
        "team_id": m2o_id(r.get("team_id")),
    }


def _months(start: date, end: date):
    """One (from, to) pair per calendar month, `to` exclusive."""
    cur = date(start.year, start.month, 1)
    while cur < end:
        nxt = date(cur.year + (cur.month == 12), (cur.month % 12) + 1, 1)
        yield cur, min(nxt, end)
        cur = nxt


def _fetch_invoice_month(engine: Engine, frm: date, to: date) -> list[dict]:
    """Every line in one month, de-duplicated by line_id.

    The source can emit a row twice across page boundaries; keying by line_id
    makes that harmless instead of double-counting revenue.
    """
    domain = INVOICE_DOMAIN + [
        ["invoice_date", ">=", frm.isoformat()],
        ["invoice_date", "<", to.isoformat()],
    ]
    by_id: dict[int, dict] = {}
    for page in engine.search_read("account.invoice.report", domain, INVOICE_FIELDS):
        for raw in page:
            row = _invoice_row(raw)
            if row:
                by_id[row["line_id"]] = row
    return list(by_id.values())


def invoice_lines_backfill(engine: Engine, supa: Supabase, frm: date, to: date,
                           replace: bool = False) -> int:
    """Load history, one month at a time.

    Month chunking is what n8n's backfill also did, and for the same reason:
    it keeps each unit of work small enough to retry. The difference is that
    within a month this pages at 1000 rows, where n8n asked Odoo for the whole
    month at once and timed out -- which is why 2024 and 2025 were never
    loaded.

    `replace` decides which of two different jobs this is.

    Without it, months are UPSERTED: safe to interrupt and repeat, right for
    loading history into empty space.

    With it, each month is DELETED and rewritten. That is the only way to
    remove a row that should no longer exist -- a cancelled invoice DISAPPEARS
    from account.invoice.report, and an upsert can never delete anything, so
    its stale row survives every re-run forever. Measured on this database:
    the range the old n8n pipeline maintained held 150,093 rows where Odoo had
    120,809, so 29,284 phantom lines were inflating 2026 revenue with nothing
    able to clear them.

    That is what "re-run the backfill monthly to reset drift" actually
    requires, and why the old advice could not have worked: n8n's backfill
    upserted too.

    The delete carries the same safeguard as the nightly job: it happens only
    after a fetch that returned rows, so a failed fetch can never empty a
    month.
    """
    total = 0
    for m_from, m_to in _months(frm, to):
        rows = _fetch_invoice_month(engine, m_from, m_to)
        label = m_from.strftime("%Y-%m")
        if replace:
            if not rows:
                log.warning("%s: fetch returned 0 rows; not deleting", label)
                continue
            supa.delete_where("dashboard_invoice_lines", {
                # state and move_type are not decoration. The only date index
                # left on this table is PARTIAL -- "where state = 'posted' and
                # move_type in (...)" -- and Postgres cannot use a partial
                # index for a query that omits its condition. Deleting on
                # invoice_date alone full-scanned 768,882 rows and hit the
                # statement timeout.
                #
                # It is also the safer scope: this sync only ever writes
                # posted customer documents, so it should only ever delete
                # those. A bare date range would remove rows it never wrote.
                "state": "eq.posted",
                "move_type": "in.(out_invoice,out_refund)",
                "invoice_date": f"gte.{m_from.isoformat()}",
                "and": f"(invoice_date.lt.{m_to.isoformat()})",
            })
        written = supa.upsert("dashboard_invoice_lines", rows, "line_id")
        total += written
        log.info("backfill%s %s: %d lines", " (replace)" if replace else "",
                 label, written)
    return total


def invoice_lines_nightly(engine: Engine, supa: Supabase, window_days: int = 35) -> int:
    """Re-sync a rolling window: fetch, DELETE the window, insert.

    THE DELETE IS NOT OPTIONAL AND MUST NOT BECOME A PLAIN UPSERT. A cancelled
    invoice DISAPPEARS from account.invoice.report; an upsert would never
    remove its stale row, so revenue would be overstated forever and silently.

    Two safeguards around it, both carried over from the n8n workflow:
      1. the delete runs AFTER the fetch, so a failed fetch stops the run
         before anything is removed;
      2. an empty fetch skips the delete entirely. Thirty-five days with
         genuinely zero invoices is far less likely than a silent upstream
         failure, and wiping the window on that basis would destroy real data.
    """
    start = date.today() - timedelta(days=window_days)
    rows = _fetch_invoice_month(engine, start, date.today() + timedelta(days=1))
    if not rows:
        log.warning("nightly: fetch returned 0 rows; skipping the window delete")
        return 0
    # Same partial-index rule as the backfill's delete -- see there.
    supa.delete_where("dashboard_invoice_lines", {
        "state": "eq.posted",
        "move_type": "in.(out_invoice,out_refund)",
        "invoice_date": f"gte.{start.isoformat()}",
    })
    written = supa.upsert("dashboard_invoice_lines", rows, "line_id")
    log.info("nightly: %d lines from %s", written, start)
    return written


PRODUCT_FIELDS = ["display_name", "default_code", "categ_id", "standard_price",
                  "list_price", "uom_id", "active", "qty_available", "product_brand_id"]


def products_and_stock(engine: Engine, supa: Supabase) -> int:
    """product.product -> dashboard_products + dashboard_stock.

    qty_available is company-wide on-hand in the product's OWN unit of measure,
    which is why quantities are fractional cartons rather than whole numbers.
    A product with zero quantity still gets a stock row, so "no stock" and
    "not synced" can never be confused.
    """
    now = datetime.now(timezone.utc).isoformat()
    products, stock = [], []
    # THE DOMAIN IS NOT EMPTY, AND IT MATTERS. An archived product may still
    # hold stock and certainly still has sales history, so dropping it quietly
    # shrinks both the stock valuation and every agency total.
    #
    # This code already intended that -- it writes `active` and this comment
    # used to say "active is not filtered". It was, invisibly: the engine
    # applies an `active = true` guard of its own to every model whose spec
    # carries Guards(active=True), and product.product does. An empty domain
    # means "engine, use your default", not "no filter".
    #
    # Naming `active` explicitly stands the guard down. Measured before the
    # fix: 56 products had sales since 2025-08 and no row in
    # dashboard_products, one of them 18,601 units, and their revenue was
    # dropping off the agencies page entirely.
    for page in engine.search_read("product.product",
                                   [["active", "in", [True, False]]],
                                   PRODUCT_FIELDS):
        for p in page:
            cost = num(p.get("standard_price"))
            products.append({
                "product_id": p["id"],
                "name": text(p.get("display_name")),
                "sku": text(p.get("default_code")),
                "category": m2o_label(p.get("categ_id")),
                "brand": m2o_label(p.get("product_brand_id")),
                "cost": cost,
                "list_price": num(p.get("list_price")),
                "uom": m2o_label(p.get("uom_id")),
                "active": p.get("active") is not False,
                "updated_at": now,
            })
            qty = num(p.get("qty_available"))
            stock.append({"product_id": p["id"], "on_hand_qty": qty,
                          "stock_value": qty * cost, "updated_at": now})
    supa.upsert("dashboard_products", products, "product_id")
    supa.upsert("dashboard_stock", stock, "product_id")
    log.info("products: %d rows", len(products))
    return len(products)


CUSTOMER_FIELDS = ["complete_name", "name", "city", "state_id", "user_id",
                   "credit", "credit_limit", "customer_rank", "title"]


def customers(engine: Engine, supa: Supabase) -> int:
    """res.partner -> dashboard_customers, real customers only.

    governorate comes from state_id, the SAME field the invoice lines use, so
    the two sources agree by construction rather than by string matching.
    """
    now = datetime.now(timezone.utc).isoformat()
    rows = []
    for page in engine.search_read("res.partner", [["customer_rank", ">", 0]],
                                   CUSTOMER_FIELDS):
        for p in page:
            rows.append({
                "partner_id": p["id"],
                "complete_name": text(p.get("complete_name")) or m2o_label(p.get("name")),
                "governorate": m2o_label(p.get("state_id")),
                "city": text(p.get("city")),
                "salesperson": m2o_label(p.get("user_id")),
                "user_id": m2o_id(p.get("user_id")),
                "credit": num(p.get("credit")),
                "credit_limit": num(p.get("credit_limit")),
                # Repurposed by the client: res.partner.title holds the trade
                # segment (ماركتات / كرزات / جملة / سلاسل كبرى), not an
                # honorific. Needs `title` on the engine's res.partner field
                # allowlist. -> dashboard_customers.title (file 66).
                "title": m2o_label(p.get("title")),
                "updated_at": now,
            })
    written = supa.upsert("dashboard_customers", rows, "partner_id")
    log.info("customers: %d rows", written)
    return written


def product_lastsale(engine: Engine, supa: Supabase) -> int:
    """When each product last sold, over all history.

    One row per product -- about 1,245 of them. product_facts used to derive
    this itself with max(invoice_date) over the whole invoice table, which
    meant reading 739,151 rows to produce 1,245 answers on every page load,
    and it timed out at every date range because the date range never applied
    to it.

    Read from Odoo rather than recomputed in Postgres: one read_group of about
    four seconds, against a scan Supabase could not finish in eight.

    Deliberately unfiltered. Idleness is a property of the product, not of
    whatever the viewer has selected -- scoping it to a governorate made a
    product selling briskly in Baghdad look dead when Basra was chosen.
    """
    now = datetime.now(timezone.utc).isoformat()
    grouped = engine.read_group(
        "account.invoice.report", INVOICE_DOMAIN,
        ["invoice_date:max"], ["product_id"],
    )
    rows = []
    for g in grouped:
        pid = m2o_id(g.get("product_id"))
        last = g.get("invoice_date_max")
        if pid and last:
            rows.append({"product_id": pid,
                         "last_invoiced": str(last)[:10],
                         "updated_at": now})
    written = supa.upsert("dashboard_product_lastsale", rows, "product_id")
    log.info("product_lastsale: %d products", written)
    return written


def receivables(engine: Engine, supa: Supabase) -> int:
    """account.move -> dashboard_receivables.

    The debt page's own header says real aging needs invoice_date_due and
    amount_residual, "neither of which is synced today". They are stored
    fields on account.move -- the invoice DOCUMENT -- while every existing
    sync reads account.invoice.report, the per-line analysis view. Different
    model, so no amount of extending the old pipeline would have reached them.
    """
    now = datetime.now(timezone.utc).isoformat()
    today = date.today()
    open_docs = []
    for page in engine.search_read(
        "account.move",
        [["state", "=", "posted"],
         ["move_type", "in", ["out_invoice", "out_refund"]],
         ["amount_residual", "!=", 0]],
        ["commercial_partner_id", "invoice_date", "invoice_date_due",
         "amount_residual", "invoice_user_id"],
    ):
        open_docs.extend(page)

    by_partner: dict[int, dict] = {}
    observed_terms: dict[int, list[int]] = {}
    for m in open_docs:
        pid = m2o_id(m.get("commercial_partner_id"))
        if not pid:
            continue
        row = by_partner.setdefault(pid, {
            "partner_id": pid,
            "customer": m2o_label(m.get("commercial_partner_id")),
            "gov": None,
            "salesperson": m2o_label(m.get("invoice_user_id")),
            "balance": 0.0, "overdue": 0.0, "oldest_days": 0,
            "terms_days": None, "credit_limit": 0.0, "updated_at": now,
        })
        residual = num(m.get("amount_residual"))
        row["balance"] += residual

        due = m.get("invoice_date_due")
        if not due:
            # Nothing to be late against. It counts toward the balance and
            # nothing else -- calling it overdue would invent a debt age.
            continue
        days = (today - date.fromisoformat(str(due)[:10])).days
        if days > 0:
            row["overdue"] += residual
            row["oldest_days"] = max(row["oldest_days"], days)
        if m.get("invoice_date"):
            observed_terms.setdefault(pid, []).append(
                (date.fromisoformat(str(due)[:10])
                 - date.fromisoformat(str(m["invoice_date"])[:10])).days)

    # Terms read off the invoices themselves, not parsed out of a payment
    # term's name -- those are free text and translated.
    for pid, terms in observed_terms.items():
        if terms:
            by_partner[pid]["terms_days"] = round(sum(terms) / len(terms))

    # credit_limit and governorate come from the partner record.
    if by_partner:
        for page in engine.search_read(
            "res.partner", [["customer_rank", ">", 0]],
            ["credit_limit", "state_id"],
        ):
            for p in page:
                row = by_partner.get(p["id"])
                if row:
                    row["credit_limit"] = num(p.get("credit_limit"))
                    row["gov"] = m2o_label(p.get("state_id"))

    rows = list(by_partner.values())
    written = supa.upsert("dashboard_receivables", rows, "partner_id")
    log.info("receivables: %d customers owing", written)
    return written


def branch_stock(engine: Engine, supa: Supabase) -> int:
    """stock.quant -> dashboard_branch_stock, one row per product per warehouse.

    Per-warehouse stock has never existed anywhere in this project, because
    qty_available is a single company-wide number with no location in it.

    Two details that are not optional. Quants are filtered to internal
    locations: most rows live in virtual locations (customers, suppliers,
    inventory adjustment) which belong to no warehouse and are not stock --
    that filter cuts ~12,988 rows to the ~1,137 that are real. And the mapping
    goes through stock.location because quant's own warehouse_id is COMPUTED,
    so Odoo cannot group by it, while location's warehouse_id is stored.
    """
    now = datetime.now(timezone.utc).isoformat()

    locations = {}
    for page in engine.search_read("stock.location", [["usage", "=", "internal"]],
                                   ["warehouse_id"]):
        for loc in page:
            locations[loc["id"]] = m2o_label(loc.get("warehouse_id"))

    costs = {}
    # Same guard, same reason -- see products_and_stock.
    for page in engine.search_read("product.product",
                                   [["active", "in", [True, False]]],
                                   ["standard_price"]):
        for p in page:
            costs[p["id"]] = num(p.get("standard_price"))

    grouped = engine.read_group(
        "stock.quant",
        [["location_id.usage", "=", "internal"], ["quantity", "!=", 0]],
        ["quantity:sum", "reserved_quantity:sum"], ["location_id", "product_id"],
    )

    # (on_hand, reserved) per product/warehouse. Free to use = on_hand - reserved,
    # which is what the page reports -- a reserved carton is already promised to
    # an order and cannot be sold again.
    totals: dict[tuple[int, str], list[float]] = {}
    for g in grouped:
        loc_id = m2o_id(g.get("location_id"))
        product_id = m2o_id(g.get("product_id"))
        warehouse = locations.get(loc_id)
        if not warehouse or not product_id:
            continue
        key = (product_id, warehouse)
        acc = totals.setdefault(key, [0.0, 0.0])
        acc[0] += num(g.get("quantity_sum"))
        acc[1] += num(g.get("reserved_quantity_sum"))

    rows = [{
        "product_id": product_id,
        "warehouse": warehouse,
        "on_hand_qty": on_hand,
        "reserved_qty": reserved,
        "stock_value": max(on_hand - reserved, 0.0) * costs.get(product_id, 0.0),
        "updated_at": now,
    } for (product_id, warehouse), (on_hand, reserved) in totals.items()]

    written = supa.upsert("dashboard_branch_stock", rows, "product_id,warehouse")
    log.info("branch_stock: %d product/warehouse rows across %d warehouses",
             written, len({w for _, w in totals}))
    return written


def product_expiry(engine: Engine, supa: Supabase) -> int:
    """stock.lot + stock.quant -> dashboard_product_expiry.

    One row per (product, warehouse, lot): how many units of a dated batch are
    physically on hand, and when that batch expires. The Warehouses page turns
    this into "expired / expires within N days".

    THREE things the engine owner flagged when opening this path (commit
    8f5b057) and that this code has to respect:

    * expiration_date is a DATETIME ("2025-08-14 14:14:44"); the time is just
      when the batch was keyed. Sliced to a plain date here so the DB compares
      dates against dates.
    * product_qty / tracking / use_expiration_date on stock.lot are store=False
      -- output-only, Odoo cannot group or order by them. The groupable
      quantity is stock.quant.quantity, reached through quant.lot_id, which is
      why that field was added.
    * every one of the ~4,407 lots already carries an expiration_date and many
      are in the past, so the "already expired, still on the shelf" figure has
      real volume from the first run.

    Only lot-tracked products appear at all -- expiry lives on the lot, and a
    product with tracking = none has no lot to carry a date.
    """
    now = datetime.now(timezone.utc).isoformat()

    # lot_id -> (product_id, lot_name, expiry_date). search_read, not read_group:
    # we need the date field itself, not an aggregate of it.
    lots: dict[int, tuple[int, str, str]] = {}
    for page in engine.search_read("stock.lot", [["expiration_date", "!=", False]],
                                   ["name", "product_id", "expiration_date"]):
        for lot in page:
            pid = m2o_id(lot.get("product_id"))
            exp = text(lot.get("expiration_date"))
            if pid and exp:
                lots[lot["id"]] = (pid, text(lot.get("name")) or str(lot["id"]),
                                   exp[:10])

    # Same internal-location -> warehouse mapping branch_stock uses, and for the
    # same reason: quant.warehouse_id is computed, location.warehouse_id stored.
    locations = {}
    for page in engine.search_read("stock.location", [["usage", "=", "internal"]],
                                   ["warehouse_id"]):
        for loc in page:
            locations[loc["id"]] = m2o_label(loc.get("warehouse_id"))

    grouped = engine.read_group(
        "stock.quant",
        [["location_id.usage", "=", "internal"], ["quantity", "!=", 0],
         ["lot_id", "!=", False]],
        ["quantity:sum"], ["lot_id", "location_id"],
    )

    # (product_id, warehouse, lot_name, expiry_date) -> on_hand. Keyed on the
    # lot NAME, not its id: the id is meaningless in the dashboard and the name
    # is what a warehouse person reads off the carton.
    totals: dict[tuple[int, str, str, str], float] = {}
    for g in grouped:
        lot_id = m2o_id(g.get("lot_id"))
        loc_id = m2o_id(g.get("location_id"))
        lot = lots.get(lot_id)
        warehouse = locations.get(loc_id)
        if not lot or not warehouse:
            continue
        product_id, lot_name, expiry_date = lot
        key = (product_id, warehouse, lot_name, expiry_date)
        totals[key] = totals.get(key, 0.0) + num(g.get("quantity_sum"))

    rows = [{
        "product_id": product_id,
        "warehouse": warehouse,
        "lot_name": lot_name,
        "expiry_date": expiry_date,
        "on_hand_qty": on_hand,
        "updated_at": now,
    } for (product_id, warehouse, lot_name, expiry_date), on_hand in totals.items()]

    written = supa.upsert("dashboard_product_expiry", rows,
                          "product_id,warehouse,lot_name")
    log.info("product_expiry: %d product/warehouse/lot rows, %d lots dated, "
             "%d warehouses", written, len(lots), len({w for _, w, _, _ in totals}))
    return written


def branch_sales(engine: Engine, supa: Supabase, months: int = 27) -> int:
    """What each warehouse actually SHIPPED, per product per month.

    This is the one I said could not be done. account.invoice.report carries
    no warehouse, so per-branch sales looked underivable, and branches.js was
    left with empty velocity, empty days-of-cover and no transfer suggestions
    -- the card it calls "the feature that justifies the page".

    It was derivable all along, from a different model. A stock move records
    location_id, where the goods came FROM, as a stored field. Filter to moves
    whose destination is a customer, and that source location IS the branch
    that shipped them.

    UNITS, not revenue: stock moves carry no price, and revenue per branch
    would need a second hop through sale_line_id. Units are what the page's
    operational questions -- velocity, cover, what to transfer -- need.

    One caveat to keep in view: this counts goods MOVED, while every other
    number on this dashboard counts goods INVOICED. They will not tie out
    exactly. A delivery can precede or follow its invoice, and a delivery that
    was never invoiced still moved stock.
    """
    now = datetime.now(timezone.utc).isoformat()
    start = date(date.today().year, date.today().month, 1)
    for _ in range(months):
        start = date(start.year - (start.month == 1), ((start.month - 2) % 12) + 1, 1)

    locations = {}
    for page in engine.search_read("stock.location", [["usage", "=", "internal"]],
                                   ["warehouse_id"]):
        for loc in page:
            locations[loc["id"]] = m2o_label(loc.get("warehouse_id"))

    grouped = engine.read_group(
        "stock.move",
        [["state", "=", "done"],
         # Destination is a CUSTOMER: goods leaving the business, not an
         # internal transfer between warehouses. Counting transfers would
         # report the same goods as sold twice, once from each end.
         ["location_dest_id.usage", "=", "customer"],
         ["date", ">=", start.isoformat()]],
        ["quantity:sum"], ["location_id", "product_id", "date:month"],
    )

    totals: dict[tuple, float] = {}
    for g in grouped:
        loc_id = m2o_id(g.get("location_id"))
        product_id = m2o_id(g.get("product_id"))
        warehouse = locations.get(loc_id)
        if not warehouse or not product_id:
            continue
        # The ENGINE already resolves Odoo's granularity bucket. Odoo itself
        # returns a human-readable label with the real date tucked in
        # __range; engine.backend.odoo_api._reshape_group unpacks that and
        # hands back "date_month" as a plain ISO timestamp. Reading __range
        # here found nothing and silently produced zero rows -- the reshaping
        # had already happened one layer down.
        month = str(g.get("date_month") or "")[:10]
        if not month:
            continue
        key = (product_id, warehouse, month)
        totals[key] = totals.get(key, 0.0) + num(g.get("quantity_sum"))

    rows = [{"product_id": p, "warehouse": w, "month": m,
             "units": q, "updated_at": now}
            for (p, w, m), q in totals.items()]
    written = supa.upsert("dashboard_branch_sales", rows,
                          "product_id,warehouse,month")
    log.info("branch_sales: %d product/warehouse/month rows across %d warehouses",
             written, len({w for _, w, _ in totals}))
    return written


def branch_revenue(engine: Engine, supa: Supabase, months: int = 27) -> int:
    """Revenue per warehouse per month, from confirmed sale orders.

    The branches page has two revenue widgets -- a tile and a monthly chart --
    and both were empty because stock moves carry no price. sale.order carries
    both warehouse_id and amount_untaxed, and both are stored, so branch-level
    revenue was always one query away.

    ORDER BASIS, and that matters. Every other money figure on this dashboard
    is on the invoice basis; this is what was ordered from a branch, not what
    was invoiced. The two will not agree, and an order that was never invoiced
    still counts here. It is the only per-branch money figure Odoo can give
    without joining prices to warehouses line by line, which the engine's
    one-hop limit does not reach.

    BRANCH TOTAL, not per product. sale.order holds one amount for the whole
    order, so this cannot be split across the products on it. Per-product
    revenue per branch would need sale.order.line joined to its order's
    warehouse -- one hop past what the API backend can return as an output
    column.
    """
    now = datetime.now(timezone.utc).isoformat()
    start = date(date.today().year, date.today().month, 1)
    for _ in range(months):
        start = date(start.year - (start.month == 1), ((start.month - 2) % 12) + 1, 1)

    grouped = engine.read_group(
        "sale.order",
        [["state", "in", ["sale", "done"]], ["date_order", ">=", start.isoformat()]],
        ["amount_untaxed:sum", "id:count"],
        ["warehouse_id", "date_order:month"],
    )

    rows = []
    for g in grouped:
        warehouse = m2o_label(g.get("warehouse_id"))
        month = str(g.get("date_order_month") or "")[:10]
        if not warehouse or not month:
            continue
        rows.append({
            "warehouse": warehouse,
            "month": month,
            "revenue": num(g.get("amount_untaxed_sum")),
            "orders": int(num(g.get("id_count"))),
            "updated_at": now,
        })
    written = supa.upsert("dashboard_branch_revenue", rows, "warehouse,month")
    log.info("branch_revenue: %d warehouse/month rows", written)
    return written


def stock_history(supa: Supabase, tz: str = "Asia/Baghdad") -> int:
    """Stamp today's dashboard_stock into dashboard_stock_history.

    Reads Supabase rather than Odoo on purpose: the snapshot must match what
    the dashboard reported today, not what Odoo says a second later.

    on_conflict names (product_id, snap_date), the table's actual primary key.
    The n8n job this replaces sends on_conflict=product_id, which does not
    cover that key. I predicted that would fail with PostgREST's 42P10 and it
    does not: checked against the live table, that job has been writing
    correctly since 2026-08-03 -- 19 daily snapshots, 1,294 products each. It
    evidently only matters when a row actually collides, and re-running the
    job on a date already snapshotted is the case that would prove it.

    Naming the full key here anyway: it is what the constraint actually is, so
    a same-day re-run overwrites rather than erroring, which is the behaviour a
    job that might be retried needs.

    Baghdad, not UTC: a 03:00 Baghdad run is still the previous day in UTC, and
    stamping it as such would put two snapshots on one date and none on another.
    """
    rows = supa.select("dashboard_stock", "product_id,on_hand_qty,stock_value",
                       "product_id.asc")
    if not rows:
        raise RuntimeError("dashboard_stock is empty - run the products job first")
    snap_date = datetime.now(ZoneInfo(tz)).date().isoformat()
    snapshot = [{
        "product_id": s["product_id"],
        "snap_date": snap_date,
        "on_hand_qty": num(s.get("on_hand_qty")),
        "stock_value": opt_num(s.get("stock_value")),
    } for s in rows]
    written = supa.upsert("dashboard_stock_history", snapshot, "product_id,snap_date")
    log.info("stock_history: %d rows for %s", written, snap_date)
    return written


def refresh_summaries(supa: Supabase, since: date | None = None) -> None:
    """Rebuild the precomputed tables the dashboard actually reads.

    THIS IS NOT OPTIONAL AFTER A SYNC. dashboard_product_month,
    dashboard_health and dashboard_filter_options hold answers, not rows.
    Syncing new invoices without rebuilding them updates the source and leaves
    every page showing the previous run's totals -- and dashboard_health
    carries date_to, which safePeriod uses as the default range end, so the
    dashboard quietly stops advancing its own "today".

    Wrong-and-silent, which is the failure mode this pipeline keeps meeting.

    `since` exists because refresh_after_sync() rebuilds a FIXED two months
    (current_date - 2 months, chosen to cover the 35-day nightly window). A
    --replace backfill can rewrite invoice lines older than that, and then the
    lines and the summaries disagree with nobody able to see it: the pages read
    the summaries, so the corrected lines simply never reach the screen.

    Passing the backfill's own start date rebuilds exactly what was replaced,
    however far back it went. Relying on the two-month default lining up with
    the backfill window would work most months and fail silently in the ones
    where a run slipped past the 1st.
    """
    if since is None:
        result = supa.rpc("refresh_after_sync")
        row = (result or [{}])[0] if isinstance(result, list) else (result or {})
        log.info("refreshed: %s product-month rows, %s partner-month rows, "
                 "%s health metrics, %s filter options",
                 row.get("product_month_rows"), row.get("partner_month_rows"),
                 row.get("health_metrics"), row.get("filter_options"))
        return

    # Same three calls refresh_after_sync() makes, with the window given rather
    # than assumed. Order matters only in that the summaries are read by
    # dashboard_health, so it goes last.
    cutoff = date(since.year, since.month, 1).isoformat()
    product_rows = supa.rpc("refresh_product_month", {"p_since": cutoff})
    partner_rows = supa.rpc("refresh_partner_month", {"p_since": cutoff})
    supa.rpc("refresh_dashboard_summaries")
    log.info("refreshed from %s: %s product-month rows, %s partner-month rows",
             cutoff, product_rows, partner_rows)
