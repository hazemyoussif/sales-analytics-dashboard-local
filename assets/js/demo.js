/**
 * Demo data for the four management pages, used ONLY until their SQL exists.
 *
 * ===========================================================================
 * WHY THIS FILE EXISTS, AND THE RULE THAT COMES WITH IT
 * ===========================================================================
 * Management asked for four analyses. Three of them need data we do not sync
 * yet — sales-team names, per-warehouse stock, invoice due dates. Building the
 * syncs first would mean nobody sees a screen for a week and the layout gets
 * argued about afterwards, in production.
 *
 * So the pages are built against the SHAPE of the answer, fed from here, and
 * every one of them switches to the real RPC the moment it exists (see
 * insights.js — the fallback triggers on "function does not exist", nothing
 * else).
 *
 * THE RULE: a page fed from this file MUST say so, loudly, on screen. This
 * dashboard's whole discipline is that a number is never allowed to look more
 * certain than it is — an unlabelled demo figure in front of management is the
 * worst version of that failure. insights.js renders the banner; do not build
 * a page that reads this module without it.
 *
 * Numbers are deterministic: the same seed produces the same figures on every
 * reload, so two people looking at the layout are looking at the same screen.
 */

/** Small deterministic PRNG. Same seed, same dashboard, every time. */
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const pick = (r, arr) => arr[Math.floor(r() * arr.length)];

export const GOVS = [
  'بغداد', 'البصرة', 'نينوى', 'اربيل', 'كركوك', 'النجف', 'كربلاء', 'بابل',
  'ذي قار', 'واسط', 'ديالى', 'الانبار', 'صلاح الدين', 'دهوك', 'السليمانية',
  'ميسان', 'المثنى', 'القادسية'
];

/** The four departments management named. Kept in one place so the day the
 *  real crm.team labels arrive, only this list is deleted. */
export const DEPTS = ['سوبرماركت وهايبر', 'كرزات', 'الجملة', 'السلاسل'];

export const WAREHOUSES = ['مخزن البصرة', 'مخزن الموصل'];

const REPS = ['أحمد الجبوري', 'مصطفى العلي', 'حسين كريم', 'زيد الربيعي',
              'عمر الحديثي', 'سيف الدين', 'كرار عبد', 'وسام ناصر'];

const SHOP = ['سوبرماركت', 'هايبر', 'مول', 'مركز', 'أسواق', 'ستور', 'ماركت'];
const NAMEY = ['النخيل', 'الرشيد', 'بلاد الرافدين', 'الزهراء', 'المستقبل', 'الوفاء',
               'السلام', 'الفرات', 'دجلة', 'الاندلس', 'المنصور', 'الكرادة',
               'الحرية', 'الجادرية', 'زيونة', 'المعقل', 'الجزائر', 'الدورة'];

const AGENCIES = ['توكيل نستله', 'توكيل ألمراعي', 'توكيل بيبسيكو', 'توكيل يونيليفر',
                  'توكيل مونديليز', 'توكيل هنكل', 'توكيل الرابية', 'توكيل جهينة',
                  'توكيل الدوحة', 'توكيل سافولا', 'توكيل ريتش', 'توكيل باقي'];

const PRODUCT_WORDS = ['بسكويت', 'شوكولاتة', 'عصير', 'شيبس', 'حليب', 'جبن', 'زيت',
                       'معجون', 'شامبو', 'منظف', 'مكسرات', 'تمر', 'قهوة', 'شاي',
                       'كيك', 'ويفر', 'مشروب', 'صلصة', 'معكرونة', 'سكر'];
const PRODUCT_SIZE = ['150غم', '250غم', '500غم', '1كغم', '330مل', '1لتر',
                      'كارتونة 12', 'كارتونة 24', 'كارتونة 6'];

/**
 * A skewed magnitude. Real distribution revenue is heavily concentrated — a
 * flat uniform draw would produce a concentration curve that looks like the
 * equality diagonal and make the 80/20 page look pointless.
 */
const skewed = (r, scale) => Math.round(scale * Math.pow(r(), 5) + scale * 0.0015);

// ---------------------------------------------------------------- customers
export function demoCustomers(n = 420) {
  const r = rng(20260819);
  const rows = [];
  for (let i = 0; i < n; i++) {
    const gov = i < n * 0.34 ? 'بغداد' : pick(r, GOVS);
    const dept = pick(r, DEPTS);
    const revenue = skewed(r, 240_000_000);
    const marginPct = 0.18 + r() * 0.22;
    // The fixed 2025 tier, drawn on its own scale so the split lands near the
    // real one (A ~9%, B ~15%, C ~76%) rather than following this month's
    // revenue. avg_monthly is what the A/B/C letter is derived from.
    const avgMonthly = skewed(r, 1_600_000);
    rows.push({
      partner_id: 100000 + i,
      customer: `${pick(r, SHOP)} ${pick(r, NAMEY)}${r() > 0.7 ? ' ' + (i % 40) : ''}`,
      gov,
      dept,
      salesperson: pick(r, REPS),
      revenue,
      margin: Math.round(revenue * marginPct),
      invoices: 1 + Math.round(revenue / 4_000_000),
      units: Math.round(revenue / (9000 + r() * 12000)),
      last_purchase: isoDaysAgo(Math.floor(Math.pow(r(), 2.4) * 210)),
      avg_monthly: avgMonthly,
      cls: avgMonthly >= 1_000_000 ? 'A' : avgMonthly >= 400_000 ? 'B' : 'C'
    });
  }
  return rows.sort((a, b) => b.revenue - a.revenue);
}

// ----------------------------------------------------------------- agencies
export function demoAgencyLines() {
  const r = rng(770077);
  const rows = [];
  // The unbranded bucket is real and large: brand is set on only 64% of
  // invoice lines today. It is generated here on purpose so the page is
  // designed around it rather than surprised by it later.
  const agencies = [...AGENCIES, 'غير محدد التوكيل'];
  for (const agency of agencies) {
    const isUnknown = agency === 'غير محدد التوكيل';
    const nProducts = isUnknown ? 60 : 8 + Math.floor(r() * 26);
    const scale = isUnknown ? 520_000_000 : 40_000_000 + r() * 300_000_000;
    for (let p = 0; p < nProducts; p++) {
      const revenue = skewed(r, scale / 3);
      rows.push({
        agency,
        product_id: 900000 + rows.length,
        sku: `P${(10000 + rows.length).toString()}`,
        name: `${pick(r, PRODUCT_WORDS)} ${pick(r, NAMEY)} ${pick(r, PRODUCT_SIZE)}`,
        revenue,
        margin: Math.round(revenue * (0.15 + r() * 0.25)),
        units: Math.round(revenue / (7000 + r() * 15000)),
        gov: r() < 0.3 ? 'بغداد' : pick(r, GOVS),
        dept: pick(r, DEPTS),
        customers: 1 + Math.floor(r() * 90)
      });
    }
  }
  return rows;
}

/** Which of our top customers buy from which agency — the cross-tab. */
export function demoAgencyCustomerMatrix(topCustomers, agencies) {
  const r = rng(31337);
  return topCustomers.map(c => ({
    rowLabel: c.customer,
    cells: agencies.map(() => {
      // A third of the grid is deliberately empty. Those holes are the whole
      // reason management asked for this cross-tab.
      const buys = r() > 0.34;
      return { value: buys ? skewed(r, c.revenue / 2) : 0 };
    })
  }));
}

// --------------------------------------------------------------------- debt
export function demoDebt(n = 380) {
  const r = rng(55512);
  const rows = [];
  for (let i = 0; i < n; i++) {
    const balance = skewed(r, 90_000_000);
    const termsDays = pick(r, [0, 14, 21, 30, 45, 60]);
    // Age is skewed young — most receivables are current. A flat spread would
    // paint every customer as a problem and the page would be ignored.
    const oldest = Math.floor(Math.pow(r(), 2.1) * 220);
    const overdueShare = oldest <= termsDays ? 0 : Math.min(1, (oldest - termsDays) / 90);
    const overdue = Math.round(balance * overdueShare);
    const limit = r() < 0.12 ? 0 : Math.round(balance * (0.6 + r() * 1.9) / 1e6) * 1e6;
    rows.push({
      partner_id: 100000 + i,
      customer: `${pick(r, SHOP)} ${pick(r, NAMEY)}${r() > 0.7 ? ' ' + (i % 40) : ''}`,
      gov: i < n * 0.3 ? 'بغداد' : pick(r, GOVS),
      salesperson: pick(r, REPS),
      dept: pick(r, DEPTS),
      balance,
      overdue,
      oldest_days: oldest,
      terms_days: termsDays,
      credit_limit: limit,
      avg_pay_days: Math.round(termsDays + (r() - 0.35) * 34)
    });
  }
  return rows.sort((a, b) => b.overdue - a.overdue || b.balance - a.balance);
}

// ----------------------------------------------------------------- branches
export function demoBranch(warehouse) {
  const seed = warehouse === WAREHOUSES[0] ? 61001 : 61002;
  const r = rng(seed);
  const rows = [];
  for (let i = 0; i < 240; i++) {
    const monthly = Math.round(Math.pow(r(), 2.6) * 900) + (r() < 0.15 ? 0 : 3);
    const onHand = Math.round(Math.pow(r(), 1.6) * 1400);
    const cost = 6000 + Math.round(r() * 26000);
    rows.push({
      product_id: 900000 + i,
      sku: `P${10000 + i}`,
      name: `${pick(r, PRODUCT_WORDS)} ${pick(r, NAMEY)} ${pick(r, PRODUCT_SIZE)}`,
      agency: pick(r, AGENCIES),
      on_hand: onHand,
      stock_value: onHand * cost,
      units_month: monthly,
      revenue_month: monthly * cost * 1.35,
      // Cover is undefined, not zero, when nothing sells — the same rule the
      // Reorder page already follows.
      cover_days: monthly > 0 ? Math.round(onHand / monthly * 30) : null,
      // The other branch's position, so transfer suggestions are computable.
      other_on_hand: Math.round(Math.pow(r(), 1.4) * 1500),
      other_units_month: Math.round(Math.pow(r(), 2.8) * 700)
    });
  }
  return rows;
}

export function demoBranchTrend(warehouse) {
  const r = rng(warehouse === WAREHOUSES[0] ? 4401 : 4402);
  const base = warehouse === WAREHOUSES[0] ? 310_000_000 : 190_000_000;
  const out = [];
  const now = new Date();
  for (let i = 11; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    out.push({
      label: `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`,
      value: Math.round(base * (0.72 + r() * 0.55))
    });
  }
  return out;
}

function isoDaysAgo(days) {
  const d = new Date(Date.now() - days * 86400000);
  return d.toISOString().slice(0, 10);
}
