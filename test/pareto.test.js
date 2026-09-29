import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  paretoRank, paretoSummary, concentrationPoints, debtBucket, dso, DEBT_BUCKETS
} from '../assets/js/calc.js';

const rows = [
  { id: 'a', revenue: 80 },
  { id: 'b', revenue: 10 },
  { id: 'c', revenue: 5 },
  { id: 'd', revenue: 5 }
];

test('paretoRank sorts biggest first and numbers the ranks', () => {
  const r = paretoRank(rows);
  assert.deepEqual(r.map(x => x.id), ['a', 'b', 'c', 'd']);
  assert.deepEqual(r.map(x => x.rank), [1, 2, 3, 4]);
});

test('paretoRank shares and cumulative shares reach exactly 100', () => {
  const r = paretoRank(rows);
  assert.equal(r[0].share, 80);
  assert.equal(r[0].cum_share, 80);
  assert.equal(r.at(-1).cum_share, 100);
});

test('class A covers the entities up to 80% of value, B to 95%', () => {
  const r = paretoRank(rows);
  assert.equal(r[0].cls, 'A');   // 0% before it → A
  assert.equal(r[1].cls, 'B');   // 80% before it → B
  assert.equal(r[2].cls, 'B');   // 90% before it → B
  assert.equal(r[3].cls, 'C');   // 95% before it → C
});

test('a negative-revenue entity is class C and is kept out of the total', () => {
  const withCredit = [...rows, { id: 'e', revenue: -40 }];
  const r = paretoRank(withCredit);
  const e = r.find(x => x.id === 'e');
  assert.equal(e.cls, 'C');
  assert.equal(e.share, 0);
  // the denominator is unchanged, so 'a' keeps its 80% share
  assert.equal(r.find(x => x.id === 'a').share, 80);
});

test('paretoRank on an empty list does not throw', () => {
  assert.deepEqual(paretoRank([]), []);
});

test('paretoSummary counts how few entities reach the target share', () => {
  const s = paretoSummary(paretoRank(rows), 80);
  assert.equal(s.count, 1);
  assert.equal(s.ofTotal, 4);
  assert.equal(s.pctOfPopulation, 25);
});

test('paretoSummary handles a target no entity reaches', () => {
  const s = paretoSummary(paretoRank([{ revenue: 0 }]), 80);
  assert.equal(s.count, 0);
});

test('concentrationPoints starts at the origin and ends at 100/100', () => {
  const p = concentrationPoints(paretoRank(rows));
  assert.deepEqual(p[0], { x: 0, y: 0 });
  assert.deepEqual(p.at(-1), { x: 100, y: 100 });
});

test('concentrationPoints thins a long list instead of drawing every point', () => {
  const many = Array.from({ length: 5000 }, (_, i) => ({ revenue: 5000 - i }));
  const p = concentrationPoints(paretoRank(many), 120);
  assert.ok(p.length <= 123, `expected a thinned curve, got ${p.length} points`);
});

test('debtBucket treats not-yet-due and exactly-due as current', () => {
  assert.equal(debtBucket(null), 'current');
  assert.equal(debtBucket(-5), 'current');
  assert.equal(debtBucket(0), 'current');
});

test('debtBucket boundaries are upper-inclusive', () => {
  assert.equal(debtBucket(1), '1-30');
  assert.equal(debtBucket(30), '1-30');
  assert.equal(debtBucket(31), '31-60');
  assert.equal(debtBucket(90), '61-90');
  assert.equal(debtBucket(91), '90+');
});

test('every debtBucket result is one of the declared buckets', () => {
  for (const d of [null, -1, 0, 1, 30, 45, 90, 400]) {
    assert.ok(DEBT_BUCKETS.includes(debtBucket(d)), `unknown bucket for ${d}`);
  }
});

test('dso is null, not zero, when nothing was sold in the period', () => {
  assert.equal(dso(1000, 0, 30), null);
  assert.equal(dso(1000, 500, 0), null);
});

test('dso converts a receivable into days of selling', () => {
  assert.equal(dso(1000, 1000, 30), 30);
  assert.equal(dso(500, 1000, 30), 15);
});
