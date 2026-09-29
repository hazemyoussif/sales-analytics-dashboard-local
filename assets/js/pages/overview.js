/**
 * Overview — the executive answer to "how did products do, and what is stuck".
 */
import {
  dataHealth, filterOptions, revenueAdjustments, listCustomers, AuthError,
  overviewFacts, productFilterTree
} from '../api.js';
import { esc, money, num, pct, qty } from '../format.js';
import { safePeriod, productCascade } from '../calc.js';
import { THRESHOLDS } from '../config.js';
import {
  requireAuth, mountShell, showError, showLoading, healthStrip, barList,
  T, applyLang, showField,
  haveSales, haveStock, showUnavailable, unavailableStrip,
  infoIcon
} from '../shell.js';

const $ = id => document.getElementById(id);

/** Filters live in the URL so a view is linkable and survives navigation. */
function readFilters(health) {
  const p = new URLSearchParams(location.search);
  const period = safePeriod(health, p.get('from'), p.get('to'));
  return {
    from: period.from,
    to:   period.to,
    gov:  p.get('gov')  || '',
    city: p.get('city') || '',
    salesperson: p.get('rep') || '',
    // The product filters read as a hierarchy: العائلة -> التوكيل -> المنتج.
    // family narrows the agency list to that family's agencies; agency narrows
    // the product list to its products. The old flat category checklist is
    // gone -- family covers "how is هزار doing", and nobody filtered on the
    // sub-category. `?cat=` links no longer do anything, deliberately.
    family: p.get('fam') || '',
    agency: p.get('agency') || '',
    product: p.get('product') || '',
    customer: p.get('cust') || '',
    // How long a product must have gone without selling to count as unsold.
    // 90 by default: 30 days catches ordinary seasonality and would flood the
    // list with products that are simply between orders, which is what made
    // the old version untrustworthy.
    idle: p.get('idle') || '90'
  };
}

function writeFilters(f) {
  const p = new URLSearchParams();
  p.set('from', f.from); p.set('to', f.to);
  if (f.gov) p.set('gov', f.gov);
  if (f.city) p.set('city', f.city);
  if (f.salesperson) p.set('rep', f.salesperson);
  if (f.family) p.set('fam', f.family);
  if (f.agency) p.set('agency', f.agency);
  if (f.product) p.set('product', f.product);
  if (f.customer) p.set('cust', f.customer);
  if (f.idle && f.idle !== '90') p.set('idle', f.idle);
  history.replaceState(null, '', `?${p}`);
}

/**
 * A KPI tile.
 *
 * `share` renders BESIDE the headline number, not in the note underneath — a
 * percentage tucked into 12px grey type is a percentage nobody reads. The note
 * keeps the counts and the money denominators, which are context rather than
 * the point.
 *
 * `share` is null whenever its denominator is zero or masked, in which case
 * nothing is drawn at all. An absent share and a "0%" share mean very
 * different things and only one of them is honest.
 *
 * `flag` is a caveat about the NUMBER, not a description of it: the stock
 * tiles cannot honour a governorate, salesperson or customer filter, and say
 * so when one is set. `info` is the ⓘ that explains where the figure comes
 * from in Odoo.
 *
 * This is a SECOND tile() -- insights.js exports its own, which the customers
 * page uses. They drifted: `flag` was added to that one and passed from here,
 * where the parameter did not exist, so the warning was silently discarded for
 * a day. Extra arguments to a JS function are not an error, they are simply
 * dropped, which is why nothing broke and nothing appeared. Keep the two
 * signatures identical, or merge them.
 */
function tile(label, value, note, accent = '', share = null, flag = null, info = null) {
  return `<div class="tile ${accent}">
    <div class="label">${esc(label)}${infoIcon(info)}</div>
    <div class="value">${esc(value)}${
      share ? `<span class="share">${esc(share)}</span>` : ''}</div>
    ${note ? `<div class="note">${esc(note)}</div>` : ''}
    ${flag ? `<div class="tile-flag">${esc(flag)}</div>` : ''}
  </div>`;
}

async function render() {
  const L = T();
  const health = await dataHealth();
  const f = readFilters(health);
  writeFilters(f);

  $('health').innerHTML = healthStrip(health) + unavailableStrip();

  // Without the invoice table there is no revenue, no units, no margin and no
  // last-sale date — which is every question this page exists to answer. Stop
  // here rather than rendering tiles of zeros that read as a sales collapse.
  if (!haveSales()) {
    showUnavailable($('tiles'), 'sales');
    for (const id of ['filters', 'adjustments', 'top-products', 'by-category', 'table']) {
      const el = $(id);
      if (el) el.innerHTML = '';
    }
    return;
  }

  // filter bar, built from the data rather than hardcoded
  const [opts, customers, tree] = await Promise.all([
    // Scoped: the other dropdowns offer only what exists in the chosen
    // governorate or city. Every filter change reloads the page, so the
    // narrowed lists arrive with the next render rather than needing their
    // own refresh path.
    filterOptions(f.gov, f.city),
    // A role with dashboard_customers hidden gets [] here, which renders as a
    // filter with only "—" in it rather than an error. That is correct: the
    // customer filter is simply not available to them.
    listCustomers().catch(() => []),
    // The عائلة -> توكيل -> منتج cascade source: one row per catalogue product.
    productFilterTree().catch(() => [])
  ]);

  // عائلة → توكيل (= Odoo product category) → منتج. Shared logic in calc.js.
  const cc = productCascade(tree, {
    family: f.family, agency: f.agency, product: f.product
  });
  const { families, agencyOptions, agency, productOptions, product } = cc;

  const optSel = (v, cur) =>
    `<option value="${esc(v)}"${v === cur ? ' selected' : ''}>${esc(v)}</option>`;

  $('filters').innerHTML = `
    <div class="field"><label>${esc(L.from)}</label>
      <input type="date" id="f-from" value="${esc(f.from)}"></div>
    <div class="field"><label>${esc(L.to)}</label>
      <input type="date" id="f-to" value="${esc(f.to)}"></div>
    <div class="field"><label>${esc(L.gov)}</label>
      <select id="f-gov"><option value="">—</option>
      ${opts.gov.map(o => optSel(o.value, f.gov)).join('')}
      </select></div>
    <div class="field"><label>${esc(L.city)}</label>
      <select id="f-city"><option value="">—</option>
      ${(opts.city || []).map(o => optSel(o.value, f.city)).join('')}
      </select></div>
    <div class="field"><label>${esc(L.rep)}</label>
      <select id="f-rep"><option value="">—</option>
      ${opts.salesperson.map(o => optSel(o.value, f.salesperson)).join('')}
      </select></div>
    <div class="field"><label>${esc(L.family)}</label>
      <select id="f-fam"><option value="">—</option>
      ${families.map(fam => optSel(fam, f.family)).join('')}
      </select></div>
    <div class="field"><label>${esc(L.agn.agencies)}</label>
      <select id="f-agency"><option value="">—</option>
      ${agencyOptions.map(b => optSel(b, agency)).join('')}
      </select></div>
    <div class="field"><label>${esc(L.agn.product)}</label>
      <select id="f-product"><option value="">—</option>
      ${productOptions.map(o => `<option value="${esc(o.value)}"${o.value === product ? ' selected' : ''}>${esc(o.label)}</option>`).join('')}
      </select></div>
    <div class="field"><label>${esc(L.unsoldFor)}</label>
      <select id="f-idle">
      ${[30, 60, 90].map(d => `<option ${String(d) === String(f.idle) ? 'selected' : ''} value="${d}">${esc(String(d))} ${esc(L.daysUnit)}</option>`).join('')}
      </select></div>
    ${customers.length ? `<div class="field"><label>${esc(L.customer)}</label>
      <select id="f-cust"><option value="">—</option>
      ${customers.map(c => `<option ${String(c.partner_id) === f.customer ? 'selected' : ''} value="${esc(c.partner_id)}">${esc(c.complete_name || c.partner_id)}</option>`).join('')}
      </select></div>` : ''}`;

  const apply = () => {
    const p = new URLSearchParams();
    p.set('from', $('f-from').value); p.set('to', $('f-to').value);
    if ($('f-gov').value) p.set('gov', $('f-gov').value);
    if ($('f-city')?.value) p.set('city', $('f-city').value);
    if ($('f-rep').value) p.set('rep', $('f-rep').value);
    if ($('f-fam')?.value) p.set('fam', $('f-fam').value);
    if ($('f-agency')?.value) p.set('agency', $('f-agency').value);
    if ($('f-product')?.value) p.set('product', $('f-product').value);
    if ($('f-cust')?.value) p.set('cust', $('f-cust').value);
    if ($('f-idle')?.value && $('f-idle').value !== '90') p.set('idle', $('f-idle').value);
    location.search = p.toString();
  };

  // Changing the FAMILY drops the agency and product beneath it -- they belong
  // to the old family and would not appear in the rebuilt lists. Changing the
  // AGENCY drops the product for the same reason.
  const applyFamily = () => {
    const p = new URLSearchParams(location.search);
    const v = $('f-fam').value;
    if (v) p.set('fam', v); else p.delete('fam');
    p.delete('agency'); p.delete('product');
    location.search = p.toString();
  };
  const applyAgency = () => {
    const p = new URLSearchParams(location.search);
    const v = $('f-agency').value;
    if (v) p.set('agency', v); else p.delete('agency');
    p.delete('product');
    location.search = p.toString();
  };

  // EVERY control the bar renders, minus the two that clear things below them.
  for (const el of document.querySelectorAll('#filters select, #filters input')) {
    if (el.id && el.id !== 'f-fam' && el.id !== 'f-agency') el.onchange = apply;
  }
  if ($('f-fam')) $('f-fam').onchange = applyFamily;
  if ($('f-agency')) $('f-agency').onchange = applyAgency;

  showLoading($('tiles'));
  const args = { p_from: f.from, p_to: f.to,
                 p_gov: f.gov || null, p_city: f.city || null,
                 p_salesperson: f.salesperson || null,
                 p_category: null,
                 // التوكيل is now the Odoo category: a pick sends that one
                 // category, a family alone sends all of its categories.
                 p_categories: cc.categories,
                 p_brand: null,
                 p_product: product ? Number(product) : null,
                 // p_customer is a bigint in product_facts; an empty string
                 // would be a type error, not an "all customers" filter.
                 p_customer: f.customer ? Number(f.customer) : null };
  // revenue_adjustments takes NO p_category — passing the same object would
  // resolve to a function signature that does not exist and fail the whole
  // page. Its arguments are spelled out rather than shared.
  const adjArgs = { p_from: args.p_from, p_to: args.p_to,
                    p_gov: args.p_gov, p_salesperson: args.p_salesperson,
                    p_customer: args.p_customer };
  // ONE call where there were two paged ones, and it returns 110 KB instead of
  // 742. overview_facts runs product_facts once and reads that single result
  // four ways: the tiles, the top 200, the unsold list and the category mix.
  //
  // It was four separate RPCs first. That downloaded just as little but was
  // five round trips and five executions of product_facts, and when the query
  // is 12ms the round trips ARE the cost -- the default view got slower.
  //
  // The summary is what keeps a 200-row fetch honest: the tiles are computed
  // across every product the filters match, so limiting what is DISPLAYED
  // never changes what is COUNTED. Limiting the fetch alone would have made
  // revenue quietly wrong and emptied the unsold list, since that list is
  // about products which did NOT sell and a revenue-ranked top 200 selects
  // exactly the ones that did.
  const idleDays = Number(f.idle) || 90;
  const [factRows, adjustments] = await Promise.all([
    overviewFacts({ ...args, p_idle_days: idleDays, p_top: 200, p_unsold: 50 }),
    revenueAdjustments(adjArgs)
  ]);
  const S = factRows[0] || {};
  const N = k => Number(S[k] || 0);
  // The lists arrive as jsonb inside that single row.
  const top = S.top || [];
  const unsold = S.unsold || [];
  const byCat = S.by_category || [];

  // The SELECTED range end, not the dataset's. Using health.date_to here meant
  // Overview measured idleness from the last invoice in the database while
  // Frozen capital and Reorder measured it from the date you picked — so the
  // same product could read راكد on one page and سليم on another for the same
  // filter, and the frozen tile disagreed with the Frozen capital page.
  // All of these came from summing 1,431 downloaded rows. They now come from
  // one row of SQL, computed over every product rather than over the ones that
  // happened to arrive.
  //
  // classifyStock is gone from this page rather than reimplemented: with
  // peak_month passed as null its `dormant` branch was unreachable, so frozen
  // was only ever the `dead` case -- has stock, and has not sold within the
  // threshold. product_summary computes exactly that.
  const productCount = N('products');
  const revenue = S.revenue === null || S.revenue === undefined ? null : N('revenue');
  const units = N('units');
  const sold = N('sold');
  const frozenCount = N('frozen_count');
  const frozenValue = N('frozen_value');

  // Margin and margin % were removed from this page by request. The masking
  // machinery for them still exists in 05_masking.sql and still protects a
  // direct API read — this is a UI decision, not a permission change.
  const canRevenue = showField('revenue');
  // Stock value needs both the column permission AND the table itself. With
  // dashboard_stock hidden, on_hand comes back NULL, Number() makes it 0, and
  // the frozen tile would confidently report zero frozen capital.
  const canStockV  = showField('stock_value') && haveStock();
  const canStockValue = canStockV;

  // Items 3 and 4 of the review: "unsold" now means has not sold in N days AND
  // has stock. It is its own query rather than a slice of the 200, because a
  // revenue-ranked list selects precisely the products this card must exclude.
  const neverSold = unsold;
  const neverSoldCount = N('unsold_count');
  const neverSoldValue = N('unsold_value');

  // Invoice-level adjustments sit outside every product table, so the revenue
  // tile states its own share of the invoiced total rather than letting the
  // difference go unexplained.
  const adjTotal = adjustments.reduce((s, a) => s + Number(a.revenue || 0), 0);

  // Every tile carries THREE things: the headline number, the count behind it,
  // and its share. A money figure alone gives no sense of scale — "80M frozen"
  // means something different across 30 products than across 300, and
  // different again at 5% of stock than at 40%.
  //
  // A share is shown only when its denominator is real. `pct(null)` renders a
  // dash rather than inventing 0%, so a masked or missing total degrades to no
  // percentage instead of a confident wrong one.
  const share = (part, whole) => (whole > 0 ? pct(100 * part / whole) : null);

  const totalStockValue = N('stock_value');

  const bits = (...parts) => parts.filter(Boolean).join(' · ');

  // share() returns null when the denominator is zero or masked. Interpolated
  // straight into a template that becomes the literal string "null", so any
  // suffixed use goes through here instead.
  const sharePart = (part, whole, suffix) => {
    const s = share(part, whole);
    return s ? `${s} ${suffix}` : null;
  };

  // WHICH FILTERS THE STOCK TILES CANNOT HONOUR.
  //
  // Category and brand are properties of the PRODUCT, so filtering by one
  // genuinely narrows the catalogue and every tile follows. Governorate, city,
  // salesperson and customer are properties of the SALE. A product does not
  // belong to Basra, and dashboard_stock holds one row per product with no
  // location and no salesperson on it, so there is no per-governorate stock to
  // compute -- Odoo has the warehouse breakdown, this mirror does not sync it.
  //
  // The consequence measured on the live data: filter to بغداد, or to a rep,
  // or to a single customer, and frozen capital stays at 15,078,038 in every
  // case -- identical to no filter at all. Read next to a governorate anyone
  // would take it for that governorate's frozen stock.
  //
  // Flagged rather than blanked. The figure is true, just company-wide, and a
  // dash would throw away something correct to avoid something misread. The
  // flag appears ONLY when one of these filters is set, so the normal
  // unfiltered view stays clean.
  const companyWide = Boolean(f.gov || f.city || f.salesperson || f.customer);
  const scopeFlag = companyWide ? L.companyWide : null;

  $('tiles').innerHTML =
    // The share beside each number is the one that matches what the number
    // MEASURES: a money tile shows its share of a money total, a count tile
    // its share of the catalogue. Mixing the two would put "9.5% of products"
    // next to a dinar figure and invite exactly the wrong reading.
    (canRevenue
      ? tile(L.revenue, money(revenue),
             bits(`${num(sold)}/${num(productCount)} ${L.skuUnit}`,
                  adjTotal ? `${L.of} ${money(revenue + adjTotal)}` : null),
             'accent-1',
             // share of the invoiced total when adjustments exist, otherwise
             // the share of the catalogue that earned it
             adjTotal ? share(revenue, revenue + adjTotal) : share(sold, productCount),
             null, L.info.revenue)
      : '') +
    tile(L.units, qty(units),
         `${num(sold)}/${num(productCount)} ${L.skuUnit}`,
         'accent-1',
         share(sold, productCount),
         null, L.info.units) +
    // Both stock tiles below carry scopeFlag: they are built from
    // dashboard_stock, which has no governorate, city, salesperson or customer
    // on it, so those four filters leave them unchanged. The two tiles above
    // are built from the invoice lines and honour every filter, so they get no
    // flag -- putting one on all four would train people to ignore it.
    (!haveStock()
      ? tile(L.frozen, '🔒', L.unavailableStock, 'accent-8')
      : canStockV
        ? tile(L.frozen, money(frozenValue),
               bits(`${num(frozenCount)}/${num(productCount)} ${L.skuUnit}`,
                    sharePart(frozenCount, productCount, L.skuUnit)),
               'accent-8',
               share(frozenValue, totalStockValue),
               scopeFlag, L.info.frozen)
        : tile(L.frozen, num(frozenCount),
               `${L.daysIdle} > ${THRESHOLDS.IDLE_DAYS}`,
               'accent-8',
               share(frozenCount, productCount),
               scopeFlag, L.info.frozen)) +
    // Never sold gets its own tile now that the section leads the page.
    tile(`${L.unsoldTitle} ${idleDays} ${L.daysUnit}`,
         canStockValue ? money(neverSoldValue) : num(neverSoldCount),
         bits(`${num(neverSoldCount)}/${num(productCount)} ${L.skuUnit}`,
              sharePart(neverSoldCount, productCount, L.skuUnit)),
         'accent-8',
         canStockValue ? share(neverSoldValue, totalStockValue) : share(neverSoldCount, productCount),
         scopeFlag, L.info.unsold);

  // Stated explicitly as well, so the reconciliation to Odoo stays visible.
  $('adjustments').innerHTML = (adjTotal && canRevenue)
    ? `<div class="health"><span>${esc(L.revenue)} <b>${esc(money(revenue))}</b></span>
       ${adjustments.map(a => `<span>${esc(a.name || a.sku)} <b>${esc(money(a.revenue))}</b></span>`).join('')}
       <span>= <b>${esc(money(revenue + adjTotal))}</b> (Odoo)</span></div>`
    : '';

  // ---- top products. Ranked by revenue, or by units for a role that may not
  // see revenue — the same question answered with the number they are allowed.
  const rankKey = canRevenue ? 'revenue' : 'units';
  const rankFmt = canRevenue ? money : qty;
  // The denominator for every share in the two lists below: the WHOLE period,
  // not the ten or twelve rows that fitted on screen. A top-twelve list drawn
  // from 1,431 products would otherwise sum to 100% and read a product at 3%
  // of revenue as 20%. These percentages are meant not to sum to 100.
  //
  // Same masking rule as the tiles: a role that cannot see revenue is ranked
  // by units and gets its share of units, never a share of a number it is not
  // allowed to know.
  const rankTotal = canRevenue ? revenue : units;
  // Already ordered by the server; the browser only takes the first twelve.
  const topBars = top.filter(r => Number(r[rankKey]) > 0).slice(0, 12);
  $('top-products').innerHTML = barList(topBars.map(r => ({
    label: r.name || r.sku || `#${r.product_id}`,
    value: Number(r[rankKey]),
    display: rankFmt(r[rankKey])
  })), { colorVar: '--s1', total: rankTotal });
  const sub = document.querySelector('#top-products')?.previousElementSibling;
  if (sub && !canRevenue) sub.textContent = L.pg.topProductsSubUnits;

  // ---- category mix, grouped in SQL over every matching product rather than
  // over the rows that fitted in the response.
  $('by-category').innerHTML = barList(
    byCat.map(c => ({ label: c.category || '—', value: Number(c[rankKey] || 0) }))
      .filter(c => c.value > 0)
      .sort((a, b) => b.value - a.value).slice(0, 10)
      .map(c => ({ ...c, display: rankFmt(c.value) })),
    { colorVar: '--s3', total: rankTotal });

  // ---- never sold. product_facts drives from dashboard_products with LEFT
  // JOINs precisely so these rows survive: a product that sold nothing still
  // comes back with units = 0. An inner join would hide exactly the products
  // this section exists to surface.
  //
  // last_invoiced is null only when the product appears on NO invoice ever —
  // not merely none in the selected period — so this list does not change when
  // the date filter moves. That is deliberate: "never sold" is a fact about
  // the product, not about the window being looked at.
  // Say WHICH date the claim is bounded by, right next to the list. The health
  // strip already shows the window, but nobody connects the two — and this is
  // the list people act on, so the caveat has to travel with it.
  const neverSoldSub = document.querySelector('#never-sold')?.previousElementSibling;
  if (neverSoldSub) {
    // Says what the list IS, not what the data cannot promise. The old caveat
    // ("may have sold before this date") existed because the window started in
    // April 2026; the set is now defined by a rolling number of days and a
    // stock balance, both of which are true regardless of how far back the
    // history reaches.
    neverSoldSub.textContent =
      `${L.unsoldSubA} ${idleDays} ${L.daysUnit} ${L.unsoldSubB}`;
  }

  const unsoldHead = document.querySelector('#never-sold')
    ?.closest('.card')?.querySelector('h2');
  if (unsoldHead) unsoldHead.textContent = `${L.unsoldTitle} ${idleDays} ${L.daysUnit}`;

  $('never-sold').innerHTML = neverSold.length
    ? barList(neverSold.slice(0, 15).map(r => ({
        label: r.name || r.sku || `#${r.product_id}`,
        value: canStockValue ? Number(r.stock_value || 0) : 1,
        display: canStockValue ? money(r.stock_value) : `${qty(r.on_hand)} ${L.onhand}`
      // Share of ALL stock value, so "this one product is 4% of everything
      // sitting still" is readable straight off the row.
      //
      // Only when stock value is visible. Without it the rows carry value: 1
      // as an equal-bar placeholder, and a share of that would be a flat
      // 1/15 on every row -- a number that looks like a measurement and is
      // really just the length of the list.
      })), { colorVar: '--s8', total: canStockValue ? totalStockValue : null }) +
      `<p class="sub" style="margin-top:10px">${esc(num(neverSoldCount))} ${esc(L.skuUnit)}${
        share(neverSoldCount, productCount)
          ? ` (${esc(share(neverSoldCount, productCount))})` : ''}${
        canStockValue
          ? ` · ${esc(money(neverSoldValue))}${
              share(neverSoldValue, totalStockValue)
                ? ` (${esc(share(neverSoldValue, totalStockValue))})` : ''}`
          : ''}</p>`
    : `<div class="state">${esc(L.nodata)}</div>`;

  // ---- table. ABC is a share of revenue, so a role that cannot see revenue
  // gets no ABC column rather than a column of meaningless letters.
  // ABC arrives from SQL, ranked across every product the filters match. It
  // used to be computed here over whatever rows had been downloaded, so a
  // product's class depended on how many fitted in the response.
  const table = top.slice(0, 60);
  // The two returned columns sit immediately after the figures they break
  // down, because that adjacency IS the explanation: 1,015 sold of which 4
  // came back. Putting them at the far end of the row, past stock and last
  // sale, would read as two more independent measures and invite subtracting
  // them from a number they have already been subtracted from.
  //
  // A product with nothing returned shows a dash, not a zero. Sixty rows of
  // "0" would drown the handful of rows this column exists to surface, and
  // the eye finds a number among dashes far faster than a non-zero among
  // zeroes.
  const returned = (n, fmt) => (Number(n) > 0 ? esc(fmt(n)) : '—');

  $('table').innerHTML = `<div class="table-wrap"><table>
    <thead><tr>
      <th>${esc(L.product)}</th><th>${esc(L.category)}</th>
      <th class="n">${esc(L.units)}${infoIcon(L.info.units)}</th>
      <th class="n">${esc(L.returnedUnits)}${infoIcon(L.info.returned)}</th>
      ${canRevenue ? `<th class="n">${esc(L.revenue)}${infoIcon(L.info.revenue)}</th>` : ''}
      ${canRevenue ? `<th class="n">${esc(L.returnedValue)}${infoIcon(L.info.returned)}</th>` : ''}
      ${haveStock() ? `<th class="n">${esc(L.onhand)}${infoIcon(L.info.onhand)}</th>` : ''}
      <th class="n">${esc(L.lastSale)}${infoIcon(L.info.lastSale)}</th>
      ${canRevenue ? `<th>ABC${infoIcon(L.info.abc)}</th>` : ''}
    </tr></thead><tbody>
    ${table.map(r => `<tr>
      <td title="${esc(r.name)}">${esc((r.sku ? `[${r.sku}] ` : '') + (r.name || ''))}</td>
      <td>${esc(r.category || '—')}</td>
      <td class="n">${esc(qty(r.units))}</td>
      <td class="n">${returned(r.returned_units, qty)}</td>
      ${canRevenue ? `<td class="n">${esc(money(r.revenue))}</td>` : ''}
      ${canRevenue ? `<td class="n">${returned(r.returned_value, money)}</td>` : ''}
      ${haveStock() ? `<td class="n">${esc(qty(r.on_hand))}</td>` : ''}
      <td class="n">${esc(r.last_invoiced || '—')}</td>
      ${canRevenue ? `<td>${esc(r.cls || '—')}</td>` : ''}
    </tr>`).join('')}
    </tbody></table></div>
  <p class="sub">${esc(L.returnsNote)}</p>
`;
}

(async function main() {
  const app = document.getElementById('app');
  const boot = document.getElementById('boot');
  app.classList.remove('hidden');          // never leave the page a blank background
  try {
    await requireAuth();                   // resolves only once signed in
    applyLang();
    mountShell('index.html');
    document.getElementById('shell').classList.remove('hidden');
    boot?.remove();
    await render();
  } catch (err) {
    console.error(err);
    boot?.remove();
    showError(document.getElementById('tiles') || app, err);
    if (err instanceof AuthError) setTimeout(() => location.reload(), 1500);
  }
})();
