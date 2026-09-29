# Engine change request — expose product expiry / lot data

**To:** owner of `odoo-engine-gomaa-edition` (the Odoo DB Engine service)
**From:** Dabboos product dashboard
**Date:** 2026-09-01
**Precedent:** same kind of change as `res.partner.title` (commit `257d7ed`, "engine now allows it")

## What we need and why

The dashboard wants to show **product expiry dates** — "how much stock expires
within 30 / 60 / 90 days", "batches already expired sitting in the warehouse".

In Odoo, expiry is **not** a field on the product. It lives on the lot/batch
record (`stock.lot`), and on-hand stock links to it through `stock.quant.lot_id`.
The engine currently exposes neither. We probed it on 2026-09-01 and every route
is blocked (see "Current state" below).

We need **three additions to the engine's static field allowlist**
(`discovery.source = "static_fallback"`). No behaviour change, just more
models/fields passed through `/v1/search_read` and `/v1/read_group`.

---

## 1. New model: `stock.lot`

Add `stock.lot` to the model allowlist with these fields:

| Field | Type | Purpose |
|---|---|---|
| `id` | int | key |
| `name` | char | lot / batch number |
| `product_id` | many2one → product.product | which product this batch is |
| `expiration_date` | datetime | **the expiry date** |
| `use_date` | datetime | best-before |
| `removal_date` | datetime | pull-from-shelf date |
| `product_qty` | float | qty currently in this lot (computed; nice to have, not required) |

- On Odoo ≤ 13 this model is named `stock.production.lot` — if the Odoo version
  behind the engine is old, use that name instead.
- These date fields exist only when the **`product_expiry`** module is installed
  in Odoo. If it is not installed, `expiration_date` won't exist and this whole
  request is moot — please tell us that's the case.

## 2. `product.product` — add 2 fields

Currently 11 fields are exposed. Add:

| Field | Type | Purpose |
|---|---|---|
| `tracking` | selection (`none` / `lot` / `serial`) | is this product batch-tracked at all |
| `use_expiration_date` | boolean | does this product use expiry dates |

These let the dashboard show expiry only for products that actually have it,
instead of a blank column everywhere.

## 3. `stock.quant` — add 1 field

Currently 8 fields are exposed. Add:

| Field | Type | Purpose |
|---|---|---|
| `lot_id` | many2one → stock.lot | links on-hand quantity to its batch (and thus its expiry date) |

This is the join that turns "batch X expires on date Y" into "N cartons in the
main warehouse expire on date Y".

---

## Current state (probe, 2026-09-01)

`GET /v1/models` → 10 models, `field_counts` product.product=11, stock.quant=8,
`discovery.source = "static_fallback"`, `discovery.ok = false`.

| Request | Response today | Wanted |
|---|---|---|
| `search_read stock.lot [] [id,name,product_id,expiration_date]` | `400 model not available: 'stock.lot'` | `200` |
| `search_read product.product [] [id,tracking]` | `400 'product.product' has no queryable field 'tracking'` | `200` |
| `search_read stock.quant [...] [id,product_id,lot_id,quantity]` | `400 'stock.quant' has no queryable field 'lot_id'` | `200` |

## Done when

All three of these return `200`:

```jsonc
POST /v1/search_read
{ "model": "stock.lot", "domain": [["expiration_date","!=",false]],
  "fields": ["id","name","product_id","expiration_date","use_date","removal_date"],
  "limit": 5, "offset": 0, "order": "id asc" }

POST /v1/search_read
{ "model": "product.product", "domain": [["type","=","product"]],
  "fields": ["id","display_name","tracking","use_expiration_date"],
  "limit": 5, "offset": 0, "order": "id asc" }

POST /v1/search_read
{ "model": "stock.quant",
  "domain": [["location_id.usage","=","internal"],["quantity","!=",0]],
  "fields": ["id","product_id","lot_id","quantity","location_id"],
  "limit": 5, "offset": 0, "order": "id asc" }
```

Once these work we add a `lots` sync job and an expiry view to the dashboard —
no further engine involvement needed.
