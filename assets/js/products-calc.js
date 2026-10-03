/* ============================================================
   Products & Warehouse — pure analytics functions.
   No DOM, no network: same code runs in the browser (window.DASH_PRODUCTS)
   and in Node (module.exports) so it can be unit-tested directly.
   Every function is pure: inputs in, plain objects out.
   ============================================================ */
(function (root, factory) {
  const api = factory();
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.DASH_PRODUCTS = api;
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  const DAY = 86400000;
  const num = n => Number(n) || 0;

  // Frozen = in stock (on_hand_qty > 0) AND no confirmed sale within
  // thresholdDays (or never sold). lastSaleById[pid] = ISO string of the
  // product's most recent confirmed date_order.
  function classifyFrozen(products, stockById, lastSaleById, thresholdDays, now) {
    now = now || Date.now();
    stockById = stockById || {};
    lastSaleById = lastSaleById || {};
    return products.map(p => {
      const st = stockById[p.product_id] || { on_hand_qty: 0, stock_value: 0 };
      const last = lastSaleById[p.product_id] || null;
      const days_idle = last ? Math.floor((now - new Date(last).getTime()) / DAY) : null;
      const stocked = num(st.on_hand_qty) > 0;
      const never_sold = stocked && last == null;
      const frozen = stocked && (last == null || days_idle > thresholdDays);
      return {
        product_id: p.product_id, name: p.name, category: p.category, brand: p.brand,
        on_hand_qty: num(st.on_hand_qty), stock_value: num(st.stock_value),
        last_sale: last, days_idle, frozen, never_sold
      };
    });
  }

  // Trailing units/month for one product over windowDays ending at `now`.
  function productVelocity(lines, product_id, windowDays, now) {
    now = now || Date.now();
    const floor = now - windowDays * DAY;
    let units = 0;
    for (const l of lines) {
      if (l.product_id !== product_id) continue;
      const t = l.date_order ? new Date(l.date_order).getTime() : 0;
      if (t >= floor && t <= now) units += num(l.qty);
    }
    return units / (windowDays / 30);
  }

  // Where a product sells: distinct governorates it reached, ranked by revenue.
  function productMarkets(lines, product_id) {
    const m = {};
    for (const l of lines) {
      if (l.product_id !== product_id) continue;
      const g = (l.gov && String(l.gov).trim()) || "None";
      if (!m[g]) m[g] = { gov: g, units: 0, revenue: 0 };
      m[g].units += num(l.qty);
      m[g].revenue += num(l.price_subtotal);
    }
    return Object.values(m).sort((a, b) => b.revenue - a.revenue);
  }

  // Gross margin of a single line: revenue − cost × qty. costById[pid] = cost.
  function lineMargin(line, costById) {
    costById = costById || {};
    return num(line.price_subtotal) - num(costById[line.product_id]) * num(line.qty);
  }

  // Aggregate confirmed lines (already windowed by the caller) into a
  // by-product summary + a drill into customer/gov splits per product.
  function aggregateLines(lines, costById) {
    costById = costById || {};
    const prod = {};
    let totalRevenue = 0;
    for (const l of lines) {
      const pid = l.product_id;
      if (!prod[pid]) prod[pid] = { product_id: pid, units: 0, revenue: 0, margin: 0 };
      const rev = num(l.price_subtotal);
      prod[pid].units += num(l.qty);
      prod[pid].revenue += rev;
      prod[pid].margin += rev - num(costById[pid]) * num(l.qty);
      totalRevenue += rev;
    }
    const byProduct = Object.values(prod)
      .map(r => Object.assign(r, { mix_pct: totalRevenue ? (r.revenue / totalRevenue) * 100 : 0 }))
      .sort((a, b) => b.revenue - a.revenue);

    function drill(product_id) {
      const cust = {}, gov = {};
      for (const l of lines) {
        if (l.product_id !== product_id) continue;
        const pk = l.partner_id;
        if (!cust[pk]) cust[pk] = { partner_id: pk, units: 0, revenue: 0 };
        cust[pk].units += num(l.qty); cust[pk].revenue += num(l.price_subtotal);
        const g = (l.gov && String(l.gov).trim()) || "None";
        if (!gov[g]) gov[g] = { gov: g, units: 0, revenue: 0 };
        gov[g].units += num(l.qty); gov[g].revenue += num(l.price_subtotal);
      }
      return {
        byCustomer: Object.values(cust).sort((a, b) => b.revenue - a.revenue),
        byGov: Object.values(gov).sort((a, b) => b.revenue - a.revenue)
      };
    }
    return { byProduct, totalRevenue, drill };
  }

  return { classifyFrozen, productVelocity, productMarkets, lineMargin, aggregateLines };
});
