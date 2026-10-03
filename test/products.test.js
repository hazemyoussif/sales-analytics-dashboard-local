/* Node fixture tests for the pure product-analytics functions.
   Run: node test/products.test.js   (exit 0 = all pass) */
const assert = require("assert");
const P = require("../assets/js/products-calc.js");

const now = new Date("2026-07-23T00:00:00Z").getTime();

// ---- classifyFrozen ----
(function () {
  const products = [
    { product_id: 1, name: "A", category: "X", brand: "B" },
    { product_id: 2, name: "B", category: "X", brand: "B" },
    { product_id: 3, name: "C", category: "Y", brand: "B" },
    { product_id: 4, name: "D", category: "Y", brand: "B" }, // stocked, never sold
  ];
  const stock = {
    1: { on_hand_qty: 100, stock_value: 500000 },
    2: { on_hand_qty: 10, stock_value: 20000 },
    3: { on_hand_qty: 0, stock_value: 0 },
    4: { on_hand_qty: 5, stock_value: 9000 },
  };
  const lastSale = { 1: "2026-03-01T00:00:00Z", 2: "2026-07-20T00:00:00Z" };
  const out = classifyById(P.classifyFrozen(products, stock, lastSale, 60, now));
  assert.equal(out[1].frozen, true, "1 stocked + 144d idle → frozen");
  assert.equal(out[1].days_idle, 144, "1 days_idle");
  assert.equal(out[1].never_sold, false);
  assert.equal(out[2].frozen, false, "2 sold 3d ago");
  assert.equal(out[3].frozen, false, "3 no stock → ignore");
  assert.equal(out[4].frozen, true, "4 stocked never sold → frozen");
  assert.equal(out[4].never_sold, true);
  assert.equal(out[4].days_idle, null);
  // empty
  assert.deepEqual(P.classifyFrozen([], {}, {}, 60, now), []);
  console.log("classifyFrozen OK");
})();

// ---- productVelocity ----
(function () {
  const lines = [
    { product_id: 1, qty: 30, date_order: "2026-07-10T00:00:00Z" }, // in 90d
    { product_id: 1, qty: 60, date_order: "2026-06-01T00:00:00Z" }, // in 90d
    { product_id: 1, qty: 999, date_order: "2026-01-01T00:00:00Z" }, // out of 90d
    { product_id: 2, qty: 5, date_order: "2026-07-01T00:00:00Z" },
  ];
  // 90 units in trailing 90d ÷ (90/30 = 3 months) = 30/mo
  assert.equal(P.productVelocity(lines, 1, 90, now), 30, "velocity 30/mo");
  assert.equal(P.productVelocity(lines, 999, 90, now), 0, "unknown product → 0");
  console.log("productVelocity OK");
})();

// ---- productMarkets ----
(function () {
  const lines = [
    { product_id: 1, qty: 2, price_subtotal: 200, gov: "بغداد (IQ)" },
    { product_id: 1, qty: 3, price_subtotal: 300, gov: "البصرة (IQ)" },
    { product_id: 1, qty: 1, price_subtotal: 100, gov: "بغداد (IQ)" },
    { product_id: 2, qty: 9, price_subtotal: 900, gov: "بغداد (IQ)" },
  ];
  const m = P.productMarkets(lines, 1);
  assert.equal(m.length, 2, "two govs for product 1");
  assert.equal(m[0].gov, "بغداد (IQ)", "baghdad ranks first by revenue (300)");
  assert.equal(m[0].revenue, 300);
  assert.equal(m[1].gov, "البصرة (IQ)");
  console.log("productMarkets OK");
})();

// ---- lineMargin ----
(function () {
  const cost = { 1: 40 };
  assert.equal(P.lineMargin({ product_id: 1, qty: 3, price_subtotal: 200 }, cost), 200 - 120, "margin 80");
  assert.equal(P.lineMargin({ product_id: 9, qty: 3, price_subtotal: 200 }, cost), 200, "no cost → full revenue");
  console.log("lineMargin OK");
})();

// ---- aggregateLines + drill ----
(function () {
  const cost = { 1: 40, 2: 10 };
  const lines = [
    { product_id: 1, qty: 2, price_subtotal: 200, partner_id: 11, gov: "بغداد (IQ)" },
    { product_id: 1, qty: 3, price_subtotal: 300, partner_id: 12, gov: "البصرة (IQ)" },
    { product_id: 2, qty: 1, price_subtotal: 100, partner_id: 11, gov: "بغداد (IQ)" },
  ];
  const agg = P.aggregateLines(lines, cost);
  assert.equal(agg.totalRevenue, 600);
  assert.equal(agg.byProduct[0].product_id, 1, "product 1 tops revenue (500)");
  assert.equal(agg.byProduct[0].revenue, 500);
  assert.equal(agg.byProduct[0].units, 5);
  assert.equal(agg.byProduct[0].margin, 500 - 40 * 5, "margin 300");
  assert.ok(Math.abs(agg.byProduct[0].mix_pct - (500 / 600) * 100) < 1e-9, "mix %");
  const d = agg.drill(1);
  assert.equal(d.byCustomer.length, 2, "product 1 has 2 customers");
  assert.equal(d.byCustomer[0].partner_id, 12, "customer 12 tops (300)");
  assert.equal(d.byGov.length, 2);
  console.log("aggregateLines OK");
})();

function classifyById(arr) {
  const m = {};
  arr.forEach(r => (m[r.product_id] = r));
  return m;
}

console.log("\nALL PRODUCT TESTS PASSED");
