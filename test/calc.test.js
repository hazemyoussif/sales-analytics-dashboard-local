import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  daysIdle, agingBucket, velocityPerMonth, daysOfCover, marginPct,
  discountDepth, momentum, abcClasses, classifyStock, suggestedOrder,
  salesStatus, matchesSalesStatus, SALES_STATUS, packSize, toPieces, safePeriod
} from '../assets/js/calc.js';

test('daysIdle counts whole days between dates', () => {
  assert.equal(daysIdle('2026-06-01', '2026-07-01'), 30);
});

test('daysIdle returns null for a product never invoiced', () => {
  assert.equal(daysIdle(null, '2026-07-01'), null);
});

test('agingBucket treats never-sold (null) as the worst bucket', () => {
  assert.equal(agingBucket(null), '180+');
});

test('agingBucket boundaries are lower-inclusive', () => {
  assert.equal(agingBucket(59), '0-60');
  assert.equal(agingBucket(60), '60-90');
  assert.equal(agingBucket(90), '90-180');
  assert.equal(agingBucket(180), '180+');
});

test('velocityPerMonth converts 90 days of units to a monthly rate', () => {
  assert.equal(velocityPerMonth(303), 101);
});

test('velocityPerMonth floors net-negative demand at zero', () => {
  // more returned than sold in the window; negative velocity is meaningless
  assert.equal(velocityPerMonth(-30), 0);
});

test('daysOfCover divides stock by daily demand', () => {
  // 100 on hand, 30 units/month = 1 unit/day -> 100 days
  assert.equal(daysOfCover(100, 30), 100);
});

test('daysOfCover is Infinity when nothing is selling', () => {
  // must NOT be NaN - this feeds a sort, and NaN silently corrupts ordering
  assert.equal(daysOfCover(100, 0), Infinity);
});

test('daysOfCover is 0 when there is no stock', () => {
  assert.equal(daysOfCover(0, 30), 0);
});

test('marginPct is null when revenue is zero', () => {
  assert.equal(marginPct(0, 0), null);
});

test('marginPct handles a loss', () => {
  assert.equal(marginPct(100, -25), -25);
});

test('discountDepth is the shortfall against list price', () => {
  assert.equal(discountDepth(80, 100), 20);
});

test('discountDepth is null when list price is missing', () => {
  assert.equal(discountDepth(80, 0), null);
});

test('discountDepth can be negative when sold above list', () => {
  assert.equal(discountDepth(110, 100), -10);
});

test('momentum is null when there is no prior period to compare', () => {
  // a new product is not "infinite growth"
  assert.equal(momentum(50, 0), null);
});

test('momentum reports percent change', () => {
  assert.equal(momentum(150, 100), 50);
});

test('abcClasses puts the revenue leaders in A', () => {
  const rows = [
    { product_id: 1, revenue: 800 },
    { product_id: 2, revenue: 150 },
    { product_id: 3, revenue: 50 }
  ];
  const m = abcClasses(rows);
  assert.equal(m.get(1), 'A');
  assert.equal(m.get(2), 'B');
  assert.equal(m.get(3), 'C');
});

test('abcClasses ignores net-negative products rather than ranking them', () => {
  const rows = [
    { product_id: 1, revenue: 1000 },
    { product_id: 2, revenue: -40 }
  ];
  const m = abcClasses(rows);
  assert.equal(m.get(1), 'A');
  assert.equal(m.get(2), 'C');
});

test('classifyStock calls idle stock dead', () => {
  const row = { on_hand: 10, days_idle: 200, peak_month: 1, velocity: 0 };
  assert.equal(classifyStock(row, { today: '2026-08-01', idleDays: 60 }), 'dead');
});

test('classifyStock calls idle stock dormant when its season is ahead', () => {
  // idle in August, but this category peaks in December - do not liquidate
  const row = { on_hand: 10, days_idle: 200, peak_month: 12, velocity: 0 };
  assert.equal(classifyStock(row, { today: '2026-08-01', idleDays: 60 }), 'dormant');
});

test('classifyStock flags fast movers about to run out', () => {
  const row = { on_hand: 5, days_idle: 2, peak_month: null, velocity: 60 };
  assert.equal(classifyStock(row, { today: '2026-08-01', idleDays: 60 }), 'understock');
});

test('classifyStock surfaces negative on-hand instead of hiding it as reorder', () => {
  // 14 real products carry negative on_hand. Treating that as zero stock would
  // file each one under "reorder" and bury a bookkeeping error in a buying list.
  const row = { on_hand: -3, days_idle: 2, peak_month: null, velocity: 125 };
  assert.equal(classifyStock(row, { today: '2026-08-01', idleDays: 60 }), 'oversold');
});

test('classifyStock does not call a non-selling product "reorder"', () => {
  // Zero stock scores zero days of cover, which naively reads as "urgent".
  // On the real catalogue that mislabelled 932 of 1248 products and buried the
  // ~60 that genuinely needed buying. No demand, no reorder.
  const row = { on_hand: 0, days_idle: null, peak_month: null, velocity: 0 };
  assert.equal(classifyStock(row, { today: '2026-08-01', idleDays: 60 }), 'inactive');
});

test('classifyStock still reorders a product that is out of stock but selling', () => {
  const row = { on_hand: 0, days_idle: 3, peak_month: null, velocity: 90 };
  assert.equal(classifyStock(row, { today: '2026-08-01', idleDays: 60 }), 'understock');
});

test('classifyStock flags slow movers sitting on a year of stock', () => {
  const row = { on_hand: 600, days_idle: 2, peak_month: null, velocity: 30 };
  assert.equal(classifyStock(row, { today: '2026-08-01', idleDays: 60 }), 'overstock');
});

test('suggestedOrder tops stock up to the target cover', () => {
  // 30 units/month = 1/day; 60 days of cover = 60 units; 10 on hand -> order 50
  assert.equal(suggestedOrder(10, 30, 60), 50);
});

test('suggestedOrder never orders for a product with no demand', () => {
  // ordering against a zero sales rate is exactly how dead stock gets created
  assert.equal(suggestedOrder(0, 0, 60), 0);
});

test('suggestedOrder returns 0 when cover is already sufficient', () => {
  assert.equal(suggestedOrder(100, 30, 60), 0);
});

test('suggestedOrder treats negative stock as zero, not as a credit', () => {
  // an oversold product still needs a full 60 days bought, not 60 plus the deficit
  assert.equal(suggestedOrder(-5, 30, 60), 60);
});


// ===========================================================================
// salesStatus — the Status page. Deliberately independent of classifyStock:
// that one answers "buy or liquidate", this one answers "still moving?".
// ===========================================================================
const TODAY = '2026-08-07';

test('salesStatus bands follow days since the last invoice', () => {
  assert.equal(salesStatus('2026-08-01', 10, TODAY), 'active');   // 6 days
  assert.equal(salesStatus('2026-07-08', 10, TODAY), 'active');   // 30 days, inclusive
  assert.equal(salesStatus('2026-07-01', 10, TODAY), 'idle');     // 37 days
  assert.equal(salesStatus('2026-04-01', 10, TODAY), 'stalled');  // 128 days
});

test('out of stock wins over any sales band', () => {
  // A product can be selling well AND have nothing left; "out" is the
  // actionable fact, so it takes precedence.
  assert.equal(salesStatus('2026-08-06', 0, TODAY), 'out');
  assert.equal(salesStatus('2026-08-06', -3, TODAY), 'out');
});

test('never invoiced is the worst band, not the best', () => {
  assert.equal(salesStatus(null, 10, TODAY), 'stalled');
});

// A withheld on_hand arrives as null from 05_masking.sql. Treating it as 0
// would mark the entire catalogue "out of stock" for a role that simply may
// not see stock — a permission setting masquerading as an inventory crisis.
test('a withheld on_hand is not read as zero stock', () => {
  assert.equal(salesStatus('2026-08-01', null, TODAY), 'active');
  assert.equal(salesStatus('2026-04-01', undefined, TODAY), 'stalled');
});

// The bands are nested, which is why the page filters one at a time.
test('the idle filter includes stalled, but not the reverse', () => {
  assert.equal(matchesSalesStatus('stalled', 'idle'), true);
  assert.equal(matchesSalesStatus('idle', 'idle'), true);
  assert.equal(matchesSalesStatus('idle', 'stalled'), false);
  assert.equal(matchesSalesStatus('active', 'idle'), false);
});

test('an empty filter matches everything', () => {
  for (const s of SALES_STATUS) assert.equal(matchesSalesStatus(s, ''), true);
});

// ===========================================================================
// packSize — a regex over Odoo's free-text UoM. Fragile by nature, so the
// contract is: parse it or say so. Never guess.
// ===========================================================================
test('packSize reads the count out of a UoM string', () => {
  assert.equal(packSize('كارتونة 6 وحدات'), 6);
  assert.equal(packSize('Carton of 12'), 12);
  assert.equal(packSize('24'), 24);
  assert.equal(packSize('box 2.5 kg'), 2.5);
});

// Falling back to 1 would silently report carton counts as piece counts for
// every product whose UoM is written differently — an undercount with no
// visible symptom. null forces the UI to show "?" instead.
test('packSize returns null rather than guessing 1', () => {
  assert.equal(packSize('وحدة'), null);
  assert.equal(packSize('Units'), null);
  assert.equal(packSize(''), null);
  assert.equal(packSize(null), null);
  assert.equal(packSize('box 0'), null);
});

test('toPieces multiplies, and stays null when the pack size is unknown', () => {
  assert.equal(toPieces(10, 'كارتونة 6 وحدات'), 60);
  assert.equal(toPieces(2.5, 'Carton of 12'), 30);
  assert.equal(toPieces(10, 'وحدة'), null);
  assert.equal(toPieces(null, 'كارتونة 6 وحدات'), null);
});


// ===========================================================================
// safePeriod — one date resolver for every page.
//
// Overview used to compute days-idle against health.date_to (the dataset's
// last invoice) while every other page used the SELECTED end date, so the
// same product could read idle on one page and healthy on another for the
// same filter. These lock the shared behaviour down.
// ===========================================================================
const HEALTH = { date_from: '2026-04-01', date_to: '2026-07-31' };

test('safePeriod honours the dates actually chosen', () => {
  assert.deepEqual(safePeriod(HEALTH, '2026-05-01', '2026-05-31'),
                   { from: '2026-05-01', to: '2026-05-31' });
});

test('safePeriod falls back to the data window when nothing is chosen', () => {
  assert.deepEqual(safePeriod(HEALTH, null, null),
                   { from: '2026-04-01', to: '2026-07-31' });
});

// data_health() returns the literal string '—' when there are no invoice rows,
// which is exactly what a newly scoped user sees. Passing that to an RPC as a
// date is a Postgres type error, so the page died instead of saying "no data".
test('safePeriod never passes the em-dash placeholder through as a date', () => {
  const empty = { date_from: '—', date_to: '—' };
  const p = safePeriod(empty, null, null);
  assert.match(p.from, /^\d{4}-\d{2}-\d{2}$/);
  assert.match(p.to,   /^\d{4}-\d{2}-\d{2}$/);
});

// from > to returns zero rows from every RPC, which on screen is
// indistinguishable from a genuinely empty period — a mistyped year read as
// "we sold nothing". The intent is never ambiguous, so swap rather than reject.
test('safePeriod swaps a reversed range instead of returning nothing', () => {
  assert.deepEqual(safePeriod(HEALTH, '2026-07-31', '2026-04-01'),
                   { from: '2026-04-01', to: '2026-07-31' });
});

test('safePeriod rejects malformed dates without throwing', () => {
  const p = safePeriod(HEALTH, 'not-a-date', '2026-06-30');
  assert.equal(p.to, '2026-06-30');
  assert.equal(p.from, '2026-04-01');            // fell back to the data window
  assert.deepEqual(safePeriod({}, null, null).from.length, 10);
});
