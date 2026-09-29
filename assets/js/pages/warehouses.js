/**
 * Warehouses — what is FREE TO USE in each warehouse (الرئيسي / البصرة / الموصل).
 *
 * "Free to use" = on hand − reserved. A reserved carton is already committed to
 * an order and cannot be sold again, so the whole page reports free, not raw
 * on-hand (reserved is shown as its own column).
 *
 * dashboard_branch_stock is product x warehouse and nothing else -- no date, no
 * governorate, no salesperson -- so the filters are the product hierarchy:
 * العائلة -> التوكيل (= Odoo product category) -> المنتج, plus which warehouse.
 * The sync's branch-stock job fills the table; until it runs the page says so.
 */
import {
  $, tile, table, breakdown, params, mountFilters, bootInsight, load,
  money, num, qty, esc, T, showField
} from './insights.js';
import { productCascade } from '../calc.js';
import { productFilterTree } from '../api.js';

bootInsight('warehouses.html', async ({ health }) => {
  const L = T();
  const B = L.br;
  const canValue = showField('stock_value');

  const f = params(health, ['wh', 'fam', 'agency', 'product']);

  // Warehouse names, always the full list, from an UNFILTERED call.
  const allTotals = await load('warehouse_totals', {}, () => []);
  const names = allTotals.map(t => t.warehouse).filter(Boolean);
  const wh = names.includes(f.wh) ? f.wh : '';

  const cardOf = id => $(id)?.closest('.card');

  if (!allTotals.length) {
    $('tiles').innerHTML = `<div class="state">${esc(B.pending)}</div>`;
    for (const id of ['by-wh', 'table']) {
      const c = cardOf(id); if (c) c.style.display = 'none';
    }
    return;
  }

  const tree = await productFilterTree().catch(() => []);
  const cc = productCascade(tree, {
    family: f.fam, agency: f.agency, product: f.product
  });

  const scopeArgs = {
    p_category: cc.agency || null,
    p_family: f.fam || null,
    p_product: cc.product ? Number(cc.product) : null
  };
  const [totals, rows] = await Promise.all([
    load('warehouse_totals', scopeArgs, () => []),
    load('warehouse_stock', { p_warehouse: wh || null, ...scopeArgs }, () => [])
  ]);

  mountFilters([
    { key: 'wh', label: B.warehouse, type: 'select',
      options: names.map(n => ({ value: n, label: n })) },
    { key: 'fam', label: L.family, type: 'select', options: cc.families,
      clears: ['agency', 'product'] },
    { key: 'agency', label: L.agn.agencies, type: 'select', options: cc.agencyOptions,
      clears: ['product'] },
    { key: 'product', label: L.agn.product, type: 'select', options: cc.productOptions }
  ], { ...f, wh, agency: cc.agency, product: cc.product });

  // ---- KPI band -- the selected warehouse, or every warehouse added up.
  const scope = wh ? totals.filter(t => t.warehouse === wh) : totals;
  const skus     = scope.reduce((a, t) => a + Number(t.skus || 0), 0);
  const free     = scope.reduce((a, t) => a + Number(t.free_qty || 0), 0);
  const reserved = scope.reduce((a, t) => a + Number(t.reserved || 0), 0);
  const value    = scope.reduce((a, t) => a + Number(t.stock_value || 0), 0);
  const label    = wh || B.allWarehouses;

  $('tiles').innerHTML =
    tile(B.skus, num(skus), label, 'accent-1', null, null, B.info.skus) +
    tile(B.free, qty(free), `${B.reservedWord}: ${qty(reserved)}`,
         'accent-3', null, null, B.info.free) +
    (canValue
      ? tile(B.value, money(value), label, 'accent-8', null, null, B.info.value)
      : '');

  // ---- Stock by warehouse -- only in the "all" view.
  const byWhCard = cardOf('by-wh');
  if (wh) {
    if (byWhCard) byWhCard.style.display = 'none';
  } else {
    if (byWhCard) byWhCard.style.display = '';
    breakdown($('by-wh'), totals.map(t => ({
      label: t.warehouse,
      v: canValue ? Number(t.stock_value || 0) : Number(t.free_qty || 0),
      d: canValue ? money(t.stock_value) : `${qty(t.free_qty)} ${L.skuUnit}`
    })), { valueOf: r => r.v, displayOf: r => r.d, colorVar: '--s3' });
  }

  // ---- the product rows
  table($('table'), rows, [
    { label: L.product, get: r => (r.sku ? `[${r.sku}] ` : '') + (r.name || '') },
    { label: B.category, get: r => r.category || '—' },
    { label: B.free, n: true, get: r => qty(r.free_qty) },
    { label: B.reservedWord, n: true, get: r => qty(r.reserved) },
    ...(canValue
      ? [{ label: B.value, n: true, get: r => money(r.stock_value) }]
      : [])
  ], { limit: 400, empty: L.nodata });
});
