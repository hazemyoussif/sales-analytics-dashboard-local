/**
 * Agencies (التوكيلات) — the product mix inside each توكيل, and what it is
 * not moving.
 *
 * A re-framing of Overview data. Calls the SAME overview_facts RPC, so the
 * numbers agree with Overview by construction and it needs no table of its own.
 *
 * THE FILTER HIERARCHY IS عائلة -> توكيل -> منتج, and "توكيل" is the Odoo
 * product CATEGORY (categ_id, e.g. "هزار / جكليت") -- NOT product_brand_id,
 * which in this data holds pack labels. The cascade lives in
 * calc.js productCascade(); every page uses the same one.
 *
 * The القسم filter (res.partner.title: ماركتات / كرزات / جملة / سلاسل) routes
 * through the invoice lines via overview_facts.p_segment.
 */
import {
  $, tile, table, breakdown, params, mountFilters, bootInsight, load,
  money, num, pct, qty, esc, T, showField
} from './insights.js';
import { productCascade } from '../calc.js';
import { overviewFacts } from '../api.js';

const familyOf = c => String(c || '').split('/')[0].trim();

bootInsight('agencies.html', async ({ health, filters }) => {
  const L = T();
  const A = L.agn;
  const canRevenue = showField('revenue');
  const canStockValue = showField('stock_value');

  const f = params(health, ['gov', 'rep', 'agency', 'fam', 'product', 'seg', 'idle']);
  const idle = ['30', '60', '90'].includes(f.idle) ? f.idle : '90';
  const SEGMENTS = ['ماركتات', 'كرزات و معجنات', 'جملة', 'سلاسل كبرى'];
  const seg = SEGMENTS.includes(f.seg) ? f.seg : '';

  const tree = await load('product_filter_tree', {}, () => []);
  const c = productCascade(tree, { family: f.fam, agency: f.agency, product: f.product });

  const S = (await overviewFacts({
    p_from: f.from, p_to: f.to,
    p_gov: f.gov || null,
    p_salesperson: f.rep || null,
    p_category: null,
    p_categories: c.categories,
    p_product: c.product ? Number(c.product) : null,
    p_idle_days: Number(idle),
    p_top: 5,
    p_unsold: 300,
    p_segment: seg || null
  }))[0] || {};
  const byCat = S.by_category || [];
  const unsold = S.unsold || [];

  mountFilters([
    { key: 'from', label: L.from, type: 'date' },
    { key: 'to', label: L.to, type: 'date' },
    { key: 'fam', label: L.family, type: 'select', options: c.families,
      clears: ['agency', 'product'] },
    { key: 'agency', label: A.agencies, type: 'select', options: c.agencyOptions,
      clears: ['product'] },
    { key: 'product', label: A.product, type: 'select', options: c.productOptions },
    { key: 'seg', label: L.cust.segment, type: 'select', options: SEGMENTS },
    { key: 'gov', label: L.gov, type: 'select',
      options: (filters.gov || []).map(o => o.value) },
    { key: 'rep', label: L.rep, type: 'select',
      options: (filters.salesperson || []).map(o => o.value) },
    { key: 'idle', label: L.unsoldFor, type: 'select', required: true,
      options: ['30', '60', '90'].map(d => ({ value: d, label: `${d} ${L.daysUnit}` })) }
  ], { ...f, agency: c.agency, product: c.product, seg, idle });

  // ---- roll the category breakdown up to families, ranked by QUANTITY.
  const famMap = new Map();
  for (const row of byCat) {
    const key = familyOf(row.category) || '—';
    const cur = famMap.get(key)
      || { family: key, units: 0, revenue: 0, products: 0, sold: 0 };
    cur.units += Number(row.units || 0);
    cur.revenue += Number(row.revenue || 0);
    cur.products += Number(row.products || 0);
    cur.sold += Number(row.sold || 0);
    famMap.set(key, cur);
  }
  const fams = [...famMap.values()].sort((a, b) => b.units - a.units);
  const totalUnits = fams.reduce((a, r) => a + r.units, 0);
  const totalRev = fams.reduce((a, r) => a + r.revenue, 0);
  const focusName = (c.product && c.prodName.get(c.product))
    || c.agency || (f.fam || A.allAgencies);

  // ---- KPI band
  $('tiles').innerHTML =
    tile(A.units, qty(totalUnits), focusName, 'accent-1', null, null, A.info.units) +
    (canRevenue
      ? tile(L.revenue, money(totalRev), focusName, 'accent-3', null, null, A.info.revenue)
      : '') +
    tile(A.families, num(fams.length), focusName, 'accent-4', null, null, A.info.families) +
    tile(A.products, num(Number(S.products || 0)),
         `${num(Number(S.sold || 0))} ${A.sold}`, 'accent-8', null, null, A.info.products);

  // ---- families by quantity sold
  breakdown($('by-family'), fams.map(r => ({
    label: r.family,
    v: r.units,
    d: `${qty(r.units)} ${L.units}${canRevenue ? ' · ' + money(r.revenue) : ''}`
  })), {
    valueOf: r => r.v,
    displayOf: r => r.d,
    colorVar: '--s2',
    limit: 30
  });

  table($('fam-table'), fams, [
    { label: A.family, get: r => r.family },
    { label: A.units, n: true, get: r => qty(r.units) },
    { label: A.unitShare, n: true,
      get: r => pct(totalUnits ? r.units / totalUnits * 100 : 0) },
    ...(canRevenue ? [{ label: L.revenue, n: true, get: r => money(r.revenue) }] : []),
    { label: A.skus, n: true, get: r => `${num(r.sold)} / ${num(r.products)}` }
  ], { countEl: null });

  // ---- not selling, still in stock. A table now, with العائلة and التوكيل per
  // product, per the review.
  table($('unsold'), unsold, [
    { label: L.product, get: r => (r.sku ? `[${r.sku}] ` : '') + (r.name || `#${r.product_id}`) },
    { label: A.family, get: r => familyOf(r.category) || '—' },
    { label: A.agency, get: r => r.category || '—' },
    { label: L.onhand, n: true, get: r => qty(r.on_hand) },
    ...(canStockValue
      ? [{ label: L.br.value, n: true, get: r => money(r.stock_value) }]
      : [])
  ], { limit: 300, empty: L.nodata });
});
