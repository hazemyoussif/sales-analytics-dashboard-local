/**
 * Pure calculation helpers for the Dabboos product dashboard.
 * No I/O, no DOM, no Supabase - so the maths can be tested without a network.
 *
 * Conventions that apply throughout:
 *  - Quantities are UoM-normalized and may be fractional (303.5 cartons).
 *  - Credit notes are negative, so sums net out returns. Never abs().
 *  - A metric that cannot be computed returns null, never 0 or NaN.
 */

const DAY_MS = 86400000;

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Resolve the date range a page should actually use.
 *
 * Three hazards, all of which produced a wrong page rather than an error:
 *
 * 1. data_health() returns the STRING '—' when there are no invoice rows at
 *    all — which is exactly what a newly scoped user sees. Passing '—' to an
 *    RPC as a date is a Postgres type error, so the page died with a red
 *    banner instead of saying "no data for your scope".
 *
 * 2. from > to returns zero rows from every RPC. Indistinguishable on screen
 *    from a genuinely empty period, so a mistyped year read as "we sold
 *    nothing". Swapped rather than rejected: the intent is never ambiguous.
 *
 * 3. A range end must be a real date for daysIdle() to measure against, or
 *    every product reads as never-idle.
 */
/** Months of history a page loads when the URL names no dates. */
export const DEFAULT_MONTHS = 12;

export function safePeriod(health, from, to) {
  const healthTo   = ISO_DATE.test(health?.date_to)   ? health.date_to   : null;
  const healthFrom = ISO_DATE.test(health?.date_from) ? health.date_from : null;
  const today = new Date().toISOString().slice(0, 10);

  let t = ISO_DATE.test(to)   ? to   : (healthTo || today);

  // 4. The default START is DEFAULT_MONTHS back, not the beginning of all
  //    history. While this dashboard held five months of data those were the
  //    same thing. After 2024 and 2025 were backfilled they are not: every
  //    page began aggregating 739,151 rows before rendering anything, and
  //    Postgres cancelled the statement — "Could not load data / canceling
  //    statement due to statement timeout" on every page that reads invoices.
  //
  //    Nothing is hidden by this. The filter bar still reaches the earliest
  //    invoice and an explicit ?from= in the URL still wins. It only stops a
  //    page that was asked no question from answering the most expensive one
  //    available.
  let f;
  if (ISO_DATE.test(from)) {
    f = from;
  } else {
    const d = new Date(t + 'T00:00:00Z');
    d.setUTCMonth(d.getUTCMonth() - DEFAULT_MONTHS);
    f = d.toISOString().slice(0, 10);
    // Never start before the data does: a range reaching into empty months
    // reads as a gap in the business rather than a gap in the sync.
    if (healthFrom && f < healthFrom) f = healthFrom;
  }

  if (f > t) [f, t] = [t, f];
  return { from: f, to: t };
}

/** Whole days between the last invoice and today. null when never invoiced. */
export function daysIdle(lastInvoiced, today) {
  if (!lastInvoiced) return null;
  const a = Date.parse(lastInvoiced + 'T00:00:00Z');
  const b = Date.parse(today + 'T00:00:00Z');
  if (Number.isNaN(a) || Number.isNaN(b)) return null;
  return Math.round((b - a) / DAY_MS);
}

/**
 * Sales status — "who is still selling", by time since the last invoice alone.
 *
 * Deliberately SEPARATE from classifyStock(). That one answers a buying
 * question ("do I reorder or stop?") from days-of-cover and velocity; this one
 * answers an activity question ("is this product still moving?") from one
 * date. Mixing them would mean Frozen capital and Reorder silently changed
 * their recommendations, which is not what a new filter should do.
 *
 * The bands are NESTED on purpose, and this is why the page filters one at a
 * time rather than by multi-select:
 *
 *   active   sold within the last month
 *   idle     no sale in the last month   (contains `stalled`)
 *   stalled  no sale in the last 3 months
 *   out      nothing on hand — an independent axis, a product can be
 *            out of stock AND active
 *
 * Ticking `idle` + `stalled` together would just return `idle`, so offering it
 * would imply a distinction the data does not have.
 */
export const SALES_STATUS = ['active', 'idle', 'stalled', 'out'];

export function salesStatus(lastInvoiced, onHand, today) {
  // A withheld on_hand arrives as null (see 05_masking.sql). Treating that as
  // 0 would label every product "out of stock" for a role that simply may not
  // see stock, so it is excluded from the out-of-stock test rather than
  // guessed at.
  const hand = onHand === null || onHand === undefined ? null : Number(onHand);
  if (hand !== null && hand <= 0) return 'out';

  const idle = daysIdle(lastInvoiced, today);
  if (idle === null) return 'stalled';        // never sold is the worst case
  if (idle <= 30) return 'active';
  if (idle > 90) return 'stalled';
  return 'idle';
}

/** Does a product fall in a filter band? `idle` includes `stalled`. */
export function matchesSalesStatus(status, filter) {
  if (!filter) return true;
  if (filter === 'idle') return status === 'idle' || status === 'stalled';
  return status === filter;
}

/**
 * Pieces per pack, parsed out of Odoo's free-text UoM ("كارتونة 6 وحدات" → 6).
 *
 * Returns null when no number is present, which the UI must show as "unknown"
 * rather than falling back to 1. Falling back would silently report carton
 * counts as piece counts for every product whose UoM is written differently —
 * an undercount with no visible symptom.
 *
 * This is a text heuristic against data nobody validates, so the page reports
 * what fraction of the catalogue it managed to parse.
 */
export function packSize(uom) {
  if (!uom) return null;
  const m = String(uom).match(/(\d+(?:[.,]\d+)?)/);
  if (!m) return null;
  const n = Number(m[1].replace(',', '.'));
  return Number.isFinite(n) && n > 0 ? n : null;
}

/** Quantity converted to individual pieces. null when the pack size is unknown. */
export function toPieces(qty, uom) {
  const size = packSize(uom);
  if (size === null || qty === null || qty === undefined) return null;
  return Number(qty) * size;
}

/** Aging bucket. Never-invoiced (null) is the worst case, not the best. */
export function agingBucket(days) {
  if (days === null || days === undefined) return '180+';
  if (days < 60) return '0-60';
  if (days < 90) return '60-90';
  if (days < 180) return '90-180';
  return '180+';
}

/** Trailing-90-day units expressed as units per month. Net-negative floors at 0. */
export function velocityPerMonth(units90d) {
  const v = Number(units90d) / 3;
  return v > 0 ? v : 0;
}

/**
 * How many days the current stock lasts at the current rate.
 * Infinity (not NaN) when nothing is selling - this value feeds sorts,
 * and NaN silently corrupts ordering.
 */
export function daysOfCover(onHand, velocityPerMonth) {
  if (!(onHand > 0)) return 0;
  if (!(velocityPerMonth > 0)) return Infinity;
  return onHand / (velocityPerMonth / 30);
}

/** Margin as a percentage of revenue. null when there is no revenue to divide by. */
export function marginPct(revenue, margin) {
  if (!revenue) return null;
  return (margin / revenue) * 100;
}

/**
 * How far below list price we actually sold, in percent. Negative = sold above list.
 * Rounded to 4 decimals: the naive expression yields 19.999999999999996 for a plain
 * 20% discount, which is noise in a figure nobody reads past two decimals.
 */
export function discountDepth(realizedPrice, listPrice) {
  if (!(listPrice > 0)) return null;
  return Math.round((1 - realizedPrice / listPrice) * 1e6) / 1e4;
}

/** Percent change against the prior period. null when there is no prior activity. */
export function momentum(current, prior) {
  if (!prior) return null;
  return ((current - prior) / Math.abs(prior)) * 100;
}

/**
 * Pareto classification by revenue share: A = top 80%, B = next 15%, C = the tail.
 * Products with net-negative revenue are C by definition rather than ranked.
 */
export function abcClasses(rows) {
  const out = new Map();
  const positive = rows.filter(r => r.revenue > 0).sort((a, b) => b.revenue - a.revenue);
  for (const r of rows) if (!(r.revenue > 0)) out.set(r.product_id, 'C');

  const total = positive.reduce((s, r) => s + r.revenue, 0);
  if (!total) { for (const r of positive) out.set(r.product_id, 'C'); return out; }

  let cum = 0;
  for (const r of positive) {
    const shareBefore = cum / total;
    cum += r.revenue;
    out.set(r.product_id, shareBefore < 0.8 ? 'A' : shareBefore < 0.95 ? 'B' : 'C');
  }
  return out;
}

/**
 * How much to buy to reach a target number of days of cover.
 * Returns 0 when the product is not selling — cover is meaningless without
 * demand, and ordering against a zero rate is how dead stock is created.
 */
export function suggestedOrder(onHand, velocityPerMonth, targetCoverDays = 60) {
  if (!(velocityPerMonth > 0)) return 0;
  const need = (velocityPerMonth / 30) * targetCoverDays - (onHand > 0 ? onHand : 0);
  return need > 0 ? Math.ceil(need * 10) / 10 : 0;
}

/**
 * The action label for a product.
 *  dead       - in stock, idle past the threshold, and its season is not ahead
 *  dormant    - same, but the category peaks in a month still to come: wait, do not discount
 *  understock - SELLING, with under 30 days of cover -> reorder
 *  overstock  - selling, but sitting on more than 180 days of cover
 *  inactive   - no stock and no sales: nothing to decide
 *  healthy    - none of the above
 */
export function classifyStock(row, opts) {
  const { on_hand = 0, days_idle = null, peak_month = null, velocity = 0 } = row;
  const idleDays = opts.idleDays ?? 60;

  // Negative on-hand means Odoo let more go out than was ever booked in. It is
  // a bookkeeping problem, not a stocking decision, and it must not be quietly
  // read as "zero stock" — that would file it under "reorder" and hide it.
  if (on_hand < 0) return 'oversold';

  // Capital is only frozen if there is stock to freeze.
  if (on_hand > 0 && (days_idle === null || days_idle >= idleDays)) {
    const thisMonth = Number(opts.today.slice(5, 7));
    if (peak_month && peak_month > thisMonth) return 'dormant';
    return 'dead';
  }

  // Cover means nothing without demand. Without this guard every product with
  // zero stock scores 0 days of cover and gets flagged "reorder" — which on the
  // real catalogue labelled 932 of 1248 products, burying the ~60 that actually
  // need buying. A product only needs reordering if it is selling.
  if (!(velocity > 0)) return on_hand > 0 ? 'healthy' : 'inactive';

  const cover = daysOfCover(on_hand, velocity);
  if (cover < 30) return 'understock';
  if (cover > 180) return 'overstock';
  return 'healthy';
}

/**
 * Pareto (80/20) ranking over any list of entities with a value.
 *
 * Returns a NEW array, sorted biggest-first, each row carrying:
 *   share      this entity's % of the positive total
 *   cum_share  cumulative % up to and including this entity
 *   rank       1-based position
 *   cls        'A' up to 80% of the value, 'B' to 95%, 'C' the tail
 *
 * WHY NEGATIVE AND ZERO ROWS ARE CLASS C AND EXCLUDED FROM THE TOTAL
 * A customer whose net is negative — more credit notes than invoices in the
 * period — would otherwise shrink the denominator and push every other
 * customer's share up. Concentration would then depend on how many returns
 * happened, which is not what "80/20 of our sales" means to anyone.
 *
 * This is the same A/B/C convention abcClasses() already applies to products,
 * generalised so customers, agencies and products all classify identically.
 * Two different definitions of "class A" on one dashboard is a meeting nobody
 * should have to sit through.
 */
export function paretoRank(rows, valueOf = r => r.revenue) {
  const positive = rows.filter(r => Number(valueOf(r)) > 0)
                       .sort((a, b) => Number(valueOf(b)) - Number(valueOf(a)));
  const rest = rows.filter(r => !(Number(valueOf(r)) > 0));
  const total = positive.reduce((s, r) => s + Number(valueOf(r)), 0);

  let cum = 0;
  const ranked = positive.map((r, i) => {
    const v = Number(valueOf(r));
    const shareBefore = total ? cum / total : 0;
    cum += v;
    return {
      ...r,
      rank: i + 1,
      share: total ? (v / total) * 100 : 0,
      cum_share: total ? (cum / total) * 100 : 0,
      cls: !total ? 'C' : shareBefore < 0.8 ? 'A' : shareBefore < 0.95 ? 'B' : 'C'
    };
  });

  return ranked.concat(rest.map((r, i) => ({
    ...r, rank: ranked.length + i + 1, share: 0, cum_share: 100, cls: 'C'
  })));
}

/**
 * How many entities it takes to reach a given share of the value, and what
 * fraction of the population that is.
 *
 * This is the sentence management asked for — "38 customers, 9% of them, are
 * 80% of the money" — computed once so the headline, the curve annotation and
 * the tile can never disagree with each other.
 */
export function paretoSummary(ranked, targetPct = 80) {
  const scored = ranked.filter(r => r.share > 0);
  if (!scored.length) return { count: 0, ofTotal: 0, pctOfPopulation: 0, target: targetPct };
  const idx = scored.findIndex(r => r.cum_share >= targetPct);
  const count = idx === -1 ? scored.length : idx + 1;
  return {
    count,
    ofTotal: ranked.length,
    pctOfPopulation: (count / ranked.length) * 100,
    target: targetPct
  };
}

/**
 * The cumulative curve, thinned to at most `maxPoints` samples.
 *
 * An SVG path with 4000 points is 200KB of markup that renders identically to
 * one with 120. The first and last points are always kept so the curve starts
 * at the origin and ends at 100/100.
 */
export function concentrationPoints(ranked, maxPoints = 120) {
  const scored = ranked.filter(r => r.share > 0);
  if (!scored.length) return [];
  const n = scored.length;
  const step = Math.max(1, Math.ceil(n / maxPoints));
  const pts = [{ x: 0, y: 0 }];
  for (let i = 0; i < n; i += step) {
    pts.push({ x: ((i + 1) / n) * 100, y: scored[i].cum_share });
  }
  pts.push({ x: 100, y: 100 });
  return pts;
}

/**
 * Receivables aging bucket, in days past the invoice due date.
 *
 * Distinct from agingBucket(), which measures how long STOCK has sat still.
 * The two answer different questions with different cut-offs and must not be
 * merged: 60 days of idle stock is a decision, 60 days of overdue cash is a
 * problem.
 */
export const DEBT_BUCKETS = ['current', '1-30', '31-60', '61-90', '90+'];

export function debtBucket(daysPastDue) {
  if (daysPastDue === null || daysPastDue === undefined) return 'current';
  if (daysPastDue <= 0) return 'current';
  if (daysPastDue <= 30) return '1-30';
  if (daysPastDue <= 60) return '31-60';
  if (daysPastDue <= 90) return '61-90';
  return '90+';
}

/**
 * Days Sales Outstanding — how many days of selling the receivable represents.
 *
 * Null, never zero, when there were no sales in the window. A DSO of 0 reads
 * as "we collect instantly", which is the opposite of what an absent
 * denominator means.
 */
export function dso(receivables, revenueInPeriod, periodDays) {
  if (!(revenueInPeriod > 0) || !(periodDays > 0)) return null;
  return (Number(receivables) / Number(revenueInPeriod)) * periodDays;
}

/**
 * The عائلة → توكيل → منتج filter cascade, computed from product_filter_tree().
 *
 * "التوكيل" is the Odoo product CATEGORY (categ_id), e.g. "هزار / جكليت" -- NOT
 * the product_brand_id field, which in this data holds pack labels rather than
 * agencies. "العائلة" is the part before the first slash. So the hierarchy is
 * one taxonomy split two ways, plus the individual product.
 *
 * Every page builds the same three dropdowns and sends the same p_categories /
 * p_product to its RPC, so the logic lives here once.
 *
 * @param tree  rows of {family, brand, category, product_id, product, sku}
 * @param sel   {family, agency, product} -- the raw URL values
 * @returns {families, agencyOptions, agency, productOptions, product,
 *           categories, prodName}
 *          `agency` / `product` are '' when the raw value is not valid for the
 *          current parent (stale pick from another branch). `categories` is what
 *          to pass as p_categories: the chosen category alone, else the whole
 *          family, else null.
 */
export function productCascade(tree, { family = '', agency = '', product = '' } = {}) {
  const famOf = c => String(c || '').split('/')[0].trim();
  const famCats = new Map();       // family   -> Set(category)
  const catProducts = new Map();   // category -> [{id, name}]
  const famProducts = new Map();   // family   -> [{id, name}]
  const prodName = new Map();
  const all = [];
  for (const r of tree || []) {
    const fam = r.family || famOf(r.category) || '—';
    prodName.set(String(r.product_id), r.product);
    all.push({ id: r.product_id, name: r.product });
    if (r.category) {
      if (!famCats.has(fam)) famCats.set(fam, new Set());
      famCats.get(fam).add(r.category);
      if (!catProducts.has(r.category)) catProducts.set(r.category, []);
      catProducts.get(r.category).push({ id: r.product_id, name: r.product });
    }
    if (!famProducts.has(fam)) famProducts.set(fam, []);
    famProducts.get(fam).push({ id: r.product_id, name: r.product });
  }

  const families = [...famProducts.keys()].filter(x => x !== '—')
    .sort((a, b) => a.localeCompare(b, 'ar'));

  const agencyOptions = [...(family && famCats.has(family)
    ? famCats.get(family)
    : new Set([].concat(...[...famCats.values()].map(s => [...s]))))]
    .sort((a, b) => a.localeCompare(b, 'ar'));
  const ag = agencyOptions.includes(agency) ? agency : '';

  const pool = ag && catProducts.has(ag) ? catProducts.get(ag)
             : family && famProducts.has(family) ? famProducts.get(family)
             : all;
  const productOptions = pool.slice()
    .sort((a, b) => String(a.name).localeCompare(String(b.name), 'ar'))
    .map(p => ({ value: String(p.id), label: p.name }));
  const pr = productOptions.some(o => o.value === String(product))
    ? String(product) : '';

  const famCatList = family && famCats.has(family) ? [...famCats.get(family)] : null;
  const categories = ag ? [ag] : famCatList;

  return { families, agencyOptions, agency: ag, productOptions, product: pr,
           categories, prodName };
}
