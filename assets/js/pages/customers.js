/**
 * Customers 80/20 — which customers actually carry the company.
 *
 * The question management asked is not "who is biggest", which any sorted list
 * answers. It is "how few customers are we depending on", and that is a
 * CONCENTRATION question: if 30 of 1,900 customers are 80% of the revenue,
 * losing three of them is a budget problem, not a sales problem.
 *
 * THERE IS NO CHART AT THE TOP ANY MORE
 * There was a concentration curve, removed in review as "مش مفيد خالص" — fair,
 * since it drew the SHAPE of the customer base, which barely moves and cannot
 * be acted on. It was replaced with a year-on-year column chart, and that was
 * the wrong correction: the review asked for a comparison the user drives, and
 * a second picture of one fixed comparison is not that. Worse, the heading and
 * subtitle were left describing a Lorenz curve, so the page spent a day
 * explaining a chart that was no longer on it.
 *
 * The comparison now lives in the table, where the numbers are, and the user
 * chooses both what is compared and which two periods.
 *
 * The concentration question is not lost — the tiles, the A/B/C classes and
 * the cumulative-share column all answer it. Only the picture went.
 *
 * THE DEFAULT COMPARISON IS THE SAME DATES ONE YEAR EARLIER
 * Not "last calendar year". Comparing Jan–Aug 2026 against the whole of 2025
 * would show every customer collapsing, which is a fact about the calendar
 * rather than about the business. It is only the default; both ends are
 * editable.
 */
import { paretoRank, paretoSummary, daysIdle, productCascade } from '../calc.js';
import { demoCustomers, GOVS } from '../demo.js';
import {
  $, tile, table, breakdown, groupSum, params, mountFilters, bootInsight, load,
  money, num, pct, qty, esc, T, lang, showField,
  monthOf, startOfMonth, endOfMonth
} from './insights.js';
import { rpc, ApiError, productFilterTree } from '../api.js';
import { todayBaghdad } from '../format.js';

/**
 * What can be compared. All four come back from the RPC on every call, so
 * switching between them is a re-render rather than a round trip — the cost of
 * that query is the scan, not the summing.
 *
 * `needs` is the maskable column each one depends on. A role that may not see
 * revenue is not offered revenue; it still gets units and invoices, because
 * those are not restricted and a table of dashes would read as "no sales"
 * rather than "not your data".
 */
const MEASURES = {
  revenue:  { needs: 'revenue', cur: r => r.revenue,  prev: r => r.revenue_prev,  fmt: money },
  margin:   { needs: 'margin',  cur: r => r.margin,   prev: r => r.margin_prev,   fmt: money },
  units:    { needs: null,      cur: r => r.units,    prev: r => r.units_prev,    fmt: qty },
  invoices: { needs: null,      cur: r => r.invoices, prev: r => r.invoices_prev, fmt: num }
};

/**
 * ONE control, and it is a month.
 *
 * This card used to carry four date inputs: من/إلى for the period and
 * المقارنة من/إلى for the window to compare against, plus three preset
 * buttons that wrote the second pair for you. Four ways to say "when", and the
 * only thing standing between a reader and a meaningless ±% was a warning
 * underneath saying the two windows had come out different lengths.
 *
 * A single month cannot produce that mistake. The comparison is the same month
 * a year earlier -- always the same length, always the same season, no second
 * control to disagree with the first.
 *
 * What was given up, stated plainly: this page can no longer show a quarter or
 * a full year, and cannot compare against an arbitrary window. Overview still
 * takes any range. If a multi-month view is wanted back here, it belongs as a
 * span selector -- 1 / 3 / 12 months ending at the chosen one -- rather than a
 * return to two free-typed pickers.
 */

/** N months from a YYYY-MM. Month arithmetic on the month itself, so there is
 *  no day to clamp and 31 March cannot roll into March again. */
function shiftYm(ym, delta) {
  if (!ym) return '';
  const [y, m] = ym.split('-').map(Number);
  const t = (y * 12) + (m - 1) + delta;
  return `${Math.floor(t / 12)}-${String((t % 12) + 1).padStart(2, '0')}`;
}

/** Growth against the comparison period. NULL, never 0 and never infinity,
 *  when there was nothing to grow from: a first-time customer has no growth
 *  rate, and printing one invents a comparison that never existed. */
function growth(now, before) {
  const b = Number(before || 0);
  if (!(b > 0)) return null;
  return ((Number(now || 0) - b) / b) * 100;
}

bootInsight('customers.html', async ({ health, filters }) => {
  const L = T();
  const C = L.cust;
  const canMoney = showField('revenue');

  const f = params(health, ['gov', 'rep', 'product', 'fam', 'agency', 'measure', 'cls', 'cmp', 'seg']);

  // Fixed vocabulary from Odoo's Title field. Option lists that could otherwise
  // be built from the already-filtered rows are assembled below, after the
  // fetch, from an unfiltered source instead.
  const SEGMENTS = ['ماركتات', 'كرزات و معجنات', 'جملة', 'سلاسل كبرى'];

  // عائلة -> توكيل (= Odoo product category) -> منتج. Shared logic in calc.js.
  const tree = await load('product_filter_tree', {}, () => []);
  const cc = productCascade(tree, {
    family: f.fam, agency: f.agency, product: f.product
  });
  const { families, agencyOptions, agency, productOptions, product } = cc;
  const famCatList = cc.categories;

  // The period is one month, held in the URL as ?month=YYYY-MM, and expanded
  // here to the two ISO dates every RPC and every label downstream expects.
  //
  // params() still returns from/to -- it defaults them to twelve months back
  // from the newest invoice -- and both are deliberately ignored. Only `to`
  // survives, as the fallback month: the newest month that has data is a far
  // better landing page than the current calendar month, which is empty
  // whenever the sync is behind.
  const ym = monthOf(new URLSearchParams(location.search).get('month'))
             || monthOf(f.to) || monthOf(todayBaghdad());
  const from = startOfMonth(ym);
  const to = endOfMonth(ym);

  const allowed = Object.entries(MEASURES)
    .filter(([, m]) => !m.needs || showField(m.needs))
    .map(([k]) => k);
  const measureKey = allowed.includes(f.measure) ? f.measure : allowed[0];
  const measure = MEASURES[measureKey];

  // WHAT THE SECOND COLUMN COMPARES AGAINST.
  //
  // Two choices, both derived from the chosen month, so neither needs a date
  // input of its own. lastYear is the default because it is the one that
  // survives seasonality -- Ramadan against Ramadan rather than against the
  // month before it.
  const cmpKey = f.cmp === 'prevMonth' ? 'prevMonth' : 'lastYear';
  const prevYm = cmpKey === 'prevMonth' ? shiftYm(ym, -1) : shiftYm(ym, -12);
  const prevFrom = startOfMonth(prevYm);
  const prevTo = endOfMonth(prevYm);

  const rows = await load('customers_pareto', {
    p_from: from, p_to: to,
    // p_dept was a dead placeholder; it now filters dashboard_customers.title,
    // the customer trade segment (ماركتات / كرزات / جملة / سلاسل).
    p_gov: f.gov || null, p_dept: f.seg || null, p_salesperson: f.rep || null,
    // The scalar is retired in favour of the list; sending both would AND them
    // and a family plus one of its members would return the member alone.
    // التوكيل is the Odoo category now, so it travels in p_categories (one
    // category when picked, the whole family otherwise). p_agency stays null.
    p_category: null,
    p_categories: famCatList,
    p_agency: null,
    // Passed explicitly now rather than left null. The RPC's null default is
    // "same dates one year earlier", which is only ONE of the two options the
    // buttons offer -- letting it default would make the previous-month button
    // silently do nothing.
    p_prev_from: prevFrom, p_prev_to: prevTo,
    p_class: f.cls || null
  }, demoCustomers);

  // Year alone when the two columns are in different years, which is the
  // year-over-year default and what was asked for: 2026 beside 2025. Comparing
  // against the previous month puts both in the SAME year, where two headings
  // reading "2026" would be indistinguishable, so those fall back to the
  // month.
  const sameYear = ym.slice(0, 4) === prevYm.slice(0, 4);
  const curLabel = sameYear ? ym : ym.slice(0, 4);
  const prevLabel = sameYear ? prevYm : prevYm.slice(0, 4);

  // Filter option lists must come from an UNFILTERED source, never from the
  // rows already narrowed by the current pick -- otherwise choosing a value
  // collapses its own dropdown to just that value with no way back.
  const govOpts = (filters.gov || []).length
    ? filters.gov.map(o => o.value)
    : uniq(rows, 'gov', GOVS);
  const repOpts = (filters.salesperson || []).length
    ? filters.salesperson.map(o => o.value)
    : uniq(rows, 'salesperson', []);
  const segOpts = [...new Set([...SEGMENTS,
    ...rows.map(r => r.dept).filter(Boolean)])];

  // المنتجات is applied here: customers_pareto has no product dimension, so a
  // tiny helper returns the partner_ids that bought the product in the window
  // and rows are intersected with that set. Empty Set when no product picked.
  let buyers = null;
  if (product) {
    try {
      const b = await rpc('customers_of_product',
        { p_from: from, p_to: to, p_product: Number(product) }, { paginate: false });
      buyers = new Set((b || []).map(x => Number(x.partner_id)));
    } catch (err) {
      if (!(err instanceof ApiError && err.status === 404)) throw err;
    }
  }

  // Applied on the client too. When the RPC exists it has already filtered and
  // this matches everything; on demo rows it is what makes the filters work.
  // Family and agency are applied by the RPC only: they describe the PRODUCTS a
  // customer bought, and a customer row carries no product. On demo rows they
  // simply do nothing, which is honest — the demo has no products.
  const scoped = rows.filter(r =>
    (!f.gov || r.gov === f.gov) &&
    (!f.rep || r.salesperson === f.rep) &&
    (!f.seg || r.dept === f.seg) &&
    (!buyers || buyers.has(Number(r.partner_id))) &&
    (!f.cls || (r.cls || 'C') === f.cls))
    // paretoRank overwrites `cls` with its own Pareto letter, so the volume
    // class from the server is carried aside and put back after. They are two
    // different ideas that happen to share three letters: one is "share of
    // what is on screen", the other is "how big is this account", and the
    // review replaced the first with the second.
    .map(r => ({ ...r, volume_cls: r.cls || 'C' }));

  const defs = [
    // ONE place to choose time on this page, and it is a month. It sits in the
    // period card at the top; the controls below it decide WHO is counted,
    // which is a different question and stays in its own row.
    //
    // Days were never honoured here anyway. The unfiltered path aggregates
    // dashboard_partner_month, and customers_pareto snaps a filtered period to
    // month boundaries as well, so the 20th and the 1st have always returned
    // the same numbers. A control offering a choice the data ignores is worse
    // than one that does not offer it.
    { key: 'month', label: C.periodMonth, type: 'ym', group: 'period' },
    { key: 'gov', label: L.gov, type: 'select', options: govOpts },
    { key: 'rep', label: L.rep, type: 'select', options: repOpts },
    // A/B/C as a filter, per the review. The letters are now fixed sales tiers
    // rather than a share of this view, so filtering by one is a real question
    // -- "show me the A accounts" -- in a way it never was before.
    { key: 'cls', label: C.class, type: 'select',
      options: ['A', 'B', 'C'].map(k => ({ value: k, label: `${k} — ${C.classHelp[k]}` })) },
    // Customer trade segment, from res.partner.title in Odoo. Comes back as the
    // `dept` column now that customers_pareto is wired to dashboard_customers.title.
    { key: 'seg', label: C.segment, type: 'select', options: segOpts },
    // عائلة -> توكيل -> منتج. Each clears the ones under it, because a value
    // left over from another branch would not appear in the rebuilt list and a
    // filter you cannot see is a filter you cannot undo.
    { key: 'fam', label: L.family, type: 'select', options: families,
      clears: ['agency', 'product'] },
    { key: 'agency', label: L.agn.agencies, type: 'select', options: agencyOptions,
      clears: ['product'] },
    { key: 'product', label: L.agn.product, type: 'select', options: productOptions },
    // Not a date: it chooses WHICH NUMBER the two columns show, not when.
    // It stays in the period card because it describes the comparison the
    // card is about.
    { key: 'measure', label: C.measure, type: 'select', required: true,
      group: 'period',
      options: allowed.map(k => ({ value: k, label: C.measures[k] })) }
  ];
  // `month` is not in `f` -- params() does not know about it -- so it is
  // handed to mountFilters separately. Miss this and the picker renders blank
  // on every load while the page shows the right month, which is the kind of
  // disagreement that makes people distrust the whole screen.
  // `month` is not in `f`, and `cat` is passed as the FILTERED list so a pick
  // left over from another family cannot render as a ticked box that is not in
  // the options.
  mountFilters(defs, { ...f, month: ym, agency, product });
  mountCompareButtons(cmpKey);
  mountCompareNote(from, to, prevFrom, prevTo);

  const ranked = paretoRank(scoped, r => r.revenue)
    .map(r => ({ ...r, cls: r.volume_cls }));
  const s80 = paretoSummary(ranked, 80);
  const total = ranked.reduce((a, r) => a + Math.max(0, Number(r.revenue) || 0), 0);
  const classes = ['A', 'B', 'C'].map(cls => {
    const rs = ranked.filter(r => r.cls === cls);
    return {
      cls,
      count: rs.length,
      revenue: rs.reduce((a, r) => a + Number(r.revenue || 0), 0),
      share: total ? rs.reduce((a, r) => a + Number(r.revenue || 0), 0) / total * 100 : 0
    };
  });

  // ---- KPI band
  // The ⓘ on each tile carries the definition, for the same reason Overview's
  // do: this page excludes nothing while Overview excludes [DISC], and A/B/C
  // is a 2025 tier rather than a share of this month. Neither is visible in
  // the number, and both have already been misread once.
  $('tiles').innerHTML =
    tile(C.customers, num(ranked.length), `${num(classes[0].count)} ${C.classA}`,
         'accent-1', null, null, C.info.customers) +
    tile(C.carry80, num(s80.count),
         `${C.ofCustomers}: ${pct(s80.pctOfPopulation)}`, 'accent-3',
         s80.ofTotal ? pct(s80.pctOfPopulation) : null, null, C.info.carry80) +
    (canMoney
      ? tile(C.revenueA, money(classes[0].revenue),
             `${pct(classes[0].share)} ${L.of} ${money(total)}`, 'accent-3',
             null, null, C.info.revenueA)
      : '') +
    tile(C.topCustomer, ranked[0] ? ranked[0].customer : '—',
         ranked[0] ? `${pct(ranked[0].share)} ${C.ofRevenue}` : '', 'accent-8',
         ranked[0] ? pct(ranked[0].share) : null, null, C.info.topCustomer);

  if (!ranked.length) {
    for (const id of ['classes', 'top', 'by-gov', 'by-dept', 'table']) {
      const el = $(id); if (el) el.innerHTML = `<div class="state">${esc(L.nodata)}</div>`;
    }
    return;
  }

  // ---- A / B / C summary
  //
  // The FIXED 2025 tier (not a slice of the shown month), but it DOES respond
  // to the who-is-counted filters: pick a segment or a governorate and the
  // block shows that subset's A/B/C split. The class letter stays 2025; only
  // the population narrows. From customer_class_summary, which joins
  // dashboard_customers for gov / rep / title.
  //
  // Its own try/catch rather than load(): a missing RPC must fall back to the
  // period figures quietly -- load() would flip the page into the DEMO banner.
  let classPop = classes.map(c => ({
    cls: c.cls, customers: c.count, revenue: c.revenue
  }));
  try {
    const s = await rpc('customer_class_summary', {
      p_year: 2025,
      p_gov: f.gov || null,
      p_salesperson: f.rep || null,
      p_title: f.seg || null
    }, { paginate: false });
    if (Array.isArray(s) && s.length) {
      classPop = ['A', 'B', 'C'].map(cls => {
        const row = s.find(x => x.cls === cls) || {};
        return {
          cls,
          customers: Number(row.customers) || 0,
          revenue: row.revenue == null ? null : Number(row.revenue)
        };
      });
    }
  } catch (err) {
    if (!(err instanceof ApiError && err.status === 404)) throw err;
  }

  const clsPeople = classPop.reduce((a, r) => a + (Number(r.customers) || 0), 0);
  const clsMoney = classPop.reduce((a, r) => a + (Number(r.revenue) || 0), 0);
  table($('classes'), classPop, [
    { label: C.class, get: r => `${r.cls} — ${C.classHelp[r.cls]}` },
    { label: C.customers, n: true, get: r => num(r.customers) },
    { label: C.shareOfCustomers, n: true,
      get: r => pct(clsPeople ? r.customers / clsPeople * 100 : 0) },
    ...(canMoney ? [{ label: C.revenue2025, n: true, get: r => money(r.revenue) }] : []),
    { label: C.shareOfRevenue, n: true,
      get: r => pct(clsMoney ? (Number(r.revenue) || 0) / clsMoney * 100 : 0) }
  ], { countEl: null });

  // ---- breakdowns
  breakdown($('top'), ranked.slice(0, 12).map(r => ({
    label: r.customer, revenue: r.revenue, share: r.share
  })), {
    valueOf: r => (canMoney ? r.revenue : r.share),
    displayOf: r => `${canMoney ? money(r.revenue) + ' · ' : ''}${pct(r.share)}`,
    colorVar: '--s1'
  });

  const dim = (el, key, colorVar) => breakdown($(el),
    groupSum(scoped, r => r[key], r => r.revenue).map(g => ({
      label: g.label, value: g.value,
      share: total ? g.value / total * 100 : 0
    })), {
      valueOf: r => r.value,
      displayOf: r => `${canMoney ? money(r.value) + ' · ' : ''}${pct(r.share)}`,
      colorVar
    });

  dim('by-gov', 'gov', '--s3');
  dim('by-dept', 'dept', '--s4');

  // ---- the list
  const today = todayBaghdad();
  table($('table'), ranked, [
    { label: '#', n: true, get: r => num(r.rank) },
    { label: C.customer, get: r => r.customer },
    { label: L.gov, get: r => r.gov || '—' },
    { label: L.rep, get: r => r.salesperson || '—' },
    // The two periods and the change between them, in whichever measure is
    // selected. Every one of these is masked at the server for a role that may
    // not see it, and such a role is not offered it in the selector either.
    //
    // The years alone. The measure used to be repeated in both headings --
    // "المبيعات 2025–2026" and "المبيعات 2024–2025" -- which spent the widest
    // part of two columns restating something the المقارنة على أساس selector
    // above the table already says, and says once.
    //
    // A single month always sits inside one year, so year-over-year reads as
    // 2026 beside 2025. Comparing against the PREVIOUS MONTH puts both in the
    // same year, and two headings reading "2026" would be indistinguishable --
    // those show the month instead. Computed where the two windows are, so the
    // heading cannot disagree with the number under it.
    { label: curLabel, n: true,
      get: r => measure.fmt(measure.cur(r)) },
    { label: prevLabel, n: true, help: C.info.compare,
      get: r => measure.fmt(measure.prev(r)) },
    { label: '±%', n: true, help: C.info.growth, get: r => {
      const g = growth(measure.cur(r), measure.prev(r));
      return g === null ? '—' : `${g > 0 ? '+' : ''}${num(Math.round(g * 10) / 10)}%`;
    } },
    { label: C.shareOfRevenue, n: true, get: r => pct(r.share) },
    // الحصة التراكمية removed from the table. cum_share is still COMPUTED --
    // paretoRank sets it and paretoSummary(ranked, 80) reads it for the "who
    // makes 80%" tile above, which is the headline of the whole page. Only the
    // per-row column is gone: it is a running total, so it means nothing on a
    // row read on its own and only made sense while scanning the table in
    // order, which is not how anyone uses it.
    { label: C.class, n: true, help: C.info.revenueA, get: r => r.cls },
    // The number the letter came from, so nobody has to take the letter on
    // trust. Masked with revenue, because it IS revenue divided by twelve.
    ...(canMoney ? [{ label: C.avgMonthly, n: true, col: 'revenue', help: C.info.avgMonthly,
      get: r => (r.avg_monthly === null || r.avg_monthly === undefined)
        ? '—' : money(r.avg_monthly) }] : []),
    ...(measureKey === 'invoices'
      ? [] : [{ label: C.invoices, n: true, get: r => num(r.invoices) }]),
    { label: C.lastPurchase, n: true, help: C.info.lastPurchase,
      // Days, not a date: "94 days ago" is a decision, "2026-05-17" is homework.
      get: r => {
        const d = daysIdle(r.last_purchase, today);
        return d === null ? '—' : `${num(d)} ${C.daysAgo}`;
      } }
  ], { limit: 300 });

  $('legend').innerHTML = `<div class="legend">
    <span class="legend-title">${esc(C.legend)}</span>
    <span>${esc(C.legendA)}</span>
    <span>${esc(C.legendB)}</span>
    <span>${esc(C.legendC)}</span>
  </div>`;
});

/** Distinct values present in the data, with a fallback list for empty columns. */
function uniq(rows, key, fallback) {
  const seen = [...new Set(rows.map(r => r[key]).filter(Boolean))].sort();
  return seen.length ? seen : fallback;
}

// shiftYear went with the RPC's implicit comparison. The page now computes
// both windows itself from the chosen month -- shiftYm(ym, -12) or
// shiftYm(ym, -1) -- and PASSES them, so the heading and the numbers under it
// come from the same arithmetic instead of two copies that can drift.

/**
 * The two comparison choices, as buttons.
 *
 * Buttons and not a third date picker: both windows are DERIVED from the month
 * already chosen, so there is nothing to type. That was the whole reason the
 * four date inputs came out -- a second freely typed window can be a different
 * length from the first, and a ±% between windows of different lengths is
 * arithmetic dressed as a business result.
 *
 * lastYear is the default because it survives seasonality: Ramadan against
 * Ramadan, not Ramadan against the month before it. prevMonth answers the
 * different and equally real question of whether this month moved.
 *
 * aria-pressed rather than colour alone, so which one is active survives
 * greyscale and forced-colours mode.
 */
function mountCompareButtons(active) {
  const el = $('compare-buttons');
  if (!el) return;
  const C = T().cust;
  el.innerHTML = ['lastYear', 'prevMonth'].map(k =>
    `<button type="button" data-cmp="${k}" aria-pressed="${k === active}">${
      esc(C.compare[k])}</button>`).join('');

  el.onclick = ev => {
    const k = ev.target?.dataset?.cmp;
    if (!k) return;
    const q = new URLSearchParams(location.search);
    // The default is not written to the URL. A link then says what was chosen
    // rather than restating the default, and the default can change later
    // without every saved link pinning the old one.
    if (k === 'lastYear') q.delete('cmp'); else q.set('cmp', k);
    location.search = q.toString();
  };
}

/**
 * Name both windows, plainly.
 *
 * This used to also measure the two in days and warn when they came out more
 * than 12% apart, because the period was picked by day and the comparison by
 * month and the two could silently differ -- twenty days of August against a
 * whole August is a 35% "drop" that never happened.
 *
 * That warning is gone because the condition it detected can no longer occur.
 * One month against the same month a year earlier differs by at most a leap
 * day (29 vs 28 February, 3.4%), which was already inside the old threshold.
 * A check that cannot fire is not a safety net, it is furniture.
 *
 * The line stays: it still answers "compared against what?", which is the one
 * thing a reader cannot work out from two column headings reading 2025 and
 * 2026.
 */
function mountCompareNote(from, to, prevFrom, prevTo) {
  const el = $('compare-note');
  if (!el) return;
  const C = T().cust;
  if (!from || !to || !prevFrom || !prevTo) { el.innerHTML = ''; return; }

  el.innerHTML = `${esc(from)} → ${esc(to)} ` +
                 `${esc(C.versus)} ${esc(prevFrom)} → ${esc(prevTo)}`;
}

// setYear and shiftMonth lived here to build the comparison presets. Both
// presets are gone with the second pair of date pickers, and neither function
// had another caller. Removed rather than left: an unused date helper is the
// kind of thing the next person wires back in without discovering why the
// control it served was taken away.
