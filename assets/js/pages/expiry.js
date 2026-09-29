/**
 * Expiry (الصلاحية) — what is on the shelf and about to go off.
 *
 * Expiry lives on the lot in Odoo (stock.lot.expiration_date), and on-hand
 * stock links to a lot through stock.quant.lot_id. The `expiry` sync job
 * (jobs.py product_expiry) rolls that into dashboard_product_expiry — one row
 * per product / warehouse / lot — and expiry_totals / expiry_report (74_*)
 * bucket it into expired / expiring-within-N-days / total.
 *
 * Only lot-tracked products appear at all: a product with tracking = none has
 * no lot and no date. The filter hierarchy is the same عائلة -> توكيل -> منتج
 * cascade every other page uses (calc.js productCascade), plus which warehouse
 * and the window that counts as "soon".
 */
import {
  $, tile, table, params, mountFilters, bootInsight, load,
  money, qty, esc, T, showField
} from './insights.js';
import { productCascade } from '../calc.js';
import { productFilterTree } from '../api.js';

bootInsight('expiry.html', async ({ health }) => {
  const L = T();
  const B = L.br;
  const canValue = showField('stock_value');

  const f = params(health, ['wh', 'fam', 'agency', 'product', 'within']);
  // 30 / 60 / 90 / 180 days for "expires soon". Empty URL -> 90, matching the
  // expiry_report default so a fresh link and the RPC agree.
  const within = [30, 60, 90, 180].includes(Number(f.within)) ? Number(f.within) : 90;

  // Warehouse names, always the full list, from an UNFILTERED call. Shared with
  // the Warehouses page — the expiry table itself has no "all warehouses" row.
  const allTotals = await load('warehouse_totals', {}, () => []);
  const names = allTotals.map(t => t.warehouse).filter(Boolean);
  const wh = names.includes(f.wh) ? f.wh : '';

  const tree = await productFilterTree().catch(() => []);
  const cc = productCascade(tree, {
    family: f.fam, agency: f.agency, product: f.product
  });

  const args = {
    p_warehouse: wh || null,
    p_within_days: within,
    p_category: cc.agency || null,
    p_family: f.fam || null,
    p_product: cc.product ? Number(cc.product) : null
  };
  const [totalsRows, rows] = await Promise.all([
    load('expiry_totals', args, () => []),
    load('expiry_report', args, () => [])
  ]);

  mountFilters([
    { key: 'wh', label: B.warehouse, type: 'select',
      options: names.map(n => ({ value: n, label: n })) },
    { key: 'fam', label: L.family, type: 'select', options: cc.families,
      clears: ['agency', 'product'] },
    { key: 'agency', label: L.agn.agencies, type: 'select', options: cc.agencyOptions,
      clears: ['product'] },
    { key: 'product', label: L.agn.product, type: 'select', options: cc.productOptions },
    { key: 'within', label: B.within, type: 'select', required: true,
      options: [30, 60, 90, 180].map(n => ({ value: String(n), label: `${n} ${B.days}` })) }
  ], { ...f, wh, agency: cc.agency, product: cc.product, within: String(within) });

  const et = totalsRows[0] || {};
  const tracked = Number(et.tracked_qty || 0);
  const expiredQty = Number(et.expired_qty || 0);
  const soonQty = Number(et.soon_qty || 0);
  const label = wh || B.allWarehouses;

  if (!rows.length && !tracked) {
    $('tiles').innerHTML = `<div class="state">${esc(B.expiryEmpty)}</div>`;
    table($('table'), [], [], { empty: B.expiryEmpty });
    return;
  }

  $('tiles').innerHTML =
    tile(B.expired, qty(expiredQty),
         canValue ? money(et.expired_value) : label, 'accent-2',
         null, null, B.info.expired) +
    tile(B.expSoon.replace('{n}', within), qty(soonQty),
         canValue ? money(et.soon_value) : label, 'accent-4',
         null, null, B.info.expSoon) +
    tile(B.expTracked, qty(tracked), label, 'accent-1', null, null, B.info.expTracked);

  table($('table'), rows, [
    { label: L.product, get: r => (r.sku ? `[${r.sku}] ` : '') + (r.name || '') },
    { label: B.category, get: r => r.category || '—' },
    { label: B.earliest, get: r => r.earliest_expiry || '—' },
    { label: B.expired, n: true, get: r => qty(r.expired_qty) },
    { label: B.expSoon.replace('{n}', within), n: true, get: r => qty(r.soon_qty) },
    ...(canValue
      ? [{ label: B.value, n: true,
           get: r => money(Number(r.expired_value || 0) + Number(r.soon_value || 0)) }]
      : [])
  ], { limit: 500, empty: L.nodata });
});
