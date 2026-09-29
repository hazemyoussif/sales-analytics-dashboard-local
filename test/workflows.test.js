/**
 * Executes the jsCode of every n8n Code node against mock Odoo payloads.
 *
 * Without this, the sync logic is only ever exercised in production against a
 * live Odoo — where a mistake means wrong numbers rather than a red test.
 * The n8n runtime globals ($input, $json, $()) are stubbed.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const wf = name => JSON.parse(fs.readFileSync(path.join(root, 'n8n', name), 'utf8'));

const BACKFILL = wf('invoice-lines-backfill.workflow.json');
const NIGHTLY = wf('invoice-lines-nightly.workflow.json');
const PRODUCTS = wf('products-stock-sync.workflow.json');
const CUSTOMERS = wf('customers-sync.workflow.json');
const STOCK_HISTORY = wf('stock-history-nightly.workflow.json');

const code = (workflow, nodeName) => {
  const node = workflow.nodes.find(n => n.name === nodeName);
  assert.ok(node, `node "${nodeName}" not found`);
  return node.parameters.jsCode;
};

/** Run a Code node's body with stubbed n8n globals. */
const run = (js, ctx = {}) =>
  new Function('$input', '$json', '$', js)(ctx.$input, ctx.$json, ctx.$);

const configStub = json => () => ({ first: () => ({ json }) });

// ---------------------------------------------------------------- Months
test('Months tiles the range with no gaps or overlaps', () => {
  const out = run(code(BACKFILL, 'Months'),
    { $: configStub({ backfillFrom: '2024-01-01', backfillTo: '2026-09-01' }) });

  assert.equal(out.length, 32);
  assert.equal(out[0].json.from, '2024-01-01');
  assert.equal(out[0].json.to, '2024-02-01');
  assert.equal(out[31].json.to, '2026-09-01');

  for (let i = 1; i < out.length; i++) {
    assert.equal(out[i - 1].json.to, out[i].json.from,
      `gap or overlap between ${out[i - 1].json.label} and ${out[i].json.label}`);
  }
});

test('Months supports a single-month test run', () => {
  const out = run(code(BACKFILL, 'Months'),
    { $: configStub({ backfillFrom: '2026-06-01', backfillTo: '2026-07-01' }) });
  assert.equal(out.length, 1);
});

test('Months refuses an inverted range rather than silently doing nothing', () => {
  assert.throws(() => run(code(BACKFILL, 'Months'),
    { $: configStub({ backfillFrom: '2026-09-01', backfillTo: '2024-01-01' }) }));
});

// ---------------------------------------------------------------- Mapper
const invoiceRow = {
  id: 1, move_id: [900, 'INV/2026/001'], product_id: [55, '[A 31] nuts'],
  quantity: 6, price_subtotal: 60000, price_total: 63000, price_margin: 12000,
  inventory_value: 48000, invoice_date: '2026-06-14',
  commercial_partner_id: [7, 'Shop A'], partner_id: [7, 'Shop A'],
  invoice_user_id: [3, 'Ali'], move_type: 'out_invoice', state: 'posted',
  payment_state: 'paid', product_categ_id: [2, 'Snacks'], product_brand_id: false,
  state_id: [12, 'Baghdad'], city_id: false, team_id: [1, 'Sales']
};

const refundRow = {
  id: 2, move_id: [901, 'RINV/2026/001'], product_id: [55, '[A 31] nuts'],
  quantity: -2, price_subtotal: -20000, price_total: -21000, price_margin: -4000,
  inventory_value: -16000, invoice_date: '2026-06-20',
  commercial_partner_id: [7, 'Shop A'], partner_id: [7, 'Shop A'],
  invoice_user_id: [3, 'Ali'], move_type: 'out_refund', state: 'posted',
  payment_state: 'paid', product_categ_id: [2, 'Snacks'], product_brand_id: [4, 'Atlomy'],
  state_id: [12, 'Baghdad'], city_id: [88, 'Karrada'], team_id: false
};

const mapRows = rows =>
  run(code(BACKFILL, 'Map Rows'), { $input: { all: () => rows.map(json => ({ json })) } })[0].json.rows;

test('Mapper keeps credit notes negative so sums net returns', () => {
  const rows = mapRows([invoiceRow, refundRow]);
  const refund = rows.find(r => r.line_id === 2);

  assert.equal(refund.qty, -2);
  assert.equal(refund.price_subtotal, -20000);
  assert.equal(refund.price_margin, -4000);

  // the entire reason signed storage is correct: no sign handling anywhere else
  assert.equal(rows.reduce((s, r) => s + r.qty, 0), 4);
  assert.equal(rows.reduce((s, r) => s + r.price_subtotal, 0), 40000);
});

test('Mapper splits many2one into id and label', () => {
  const r = mapRows([refundRow])[0];
  assert.equal(r.product_categ_id, 2);
  assert.equal(r.category, 'Snacks');
  assert.equal(r.product_brand_id, 4);
  assert.equal(r.brand, 'Atlomy');
  assert.equal(r.gov, 'Baghdad');
  assert.equal(r.city, 'Karrada');
});

test('Mapper turns Odoo false into null, never 0 or empty string', () => {
  const r = mapRows([invoiceRow])[0];
  // brand unset must be null: 0 would look like a real brand id, "" like a real name
  assert.equal(r.product_brand_id, null);
  assert.equal(r.brand, null);
  assert.equal(r.city_id, null);
});

test('Mapper drops rows that cannot be used', () => {
  const rows = mapRows([
    invoiceRow,
    { id: 3, product_id: false, quantity: 5, invoice_date: '2026-06-01', state: 'posted' },
    { id: 4, product_id: [55, 'x'], quantity: 5, invoice_date: false, state: 'posted' }
  ]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].line_id, 1);
});

test('Mapper de-dupes by line_id', () => {
  const rows = mapRows([invoiceRow, { ...invoiceRow, quantity: 99 }]);
  assert.equal(rows.length, 1);
});

test('Mapper normalises invoice_date to YYYY-MM-DD', () => {
  const r = mapRows([{ ...invoiceRow, invoice_date: '2026-06-14 08:30:00' }])[0];
  assert.equal(r.invoice_date, '2026-06-14');
});

// ---------------------------------------------------------------- Chunk
test('Chunk splits rows into POST-sized batches', () => {
  const rows = Array.from({ length: 1200 }, (_, i) => ({ line_id: i }));
  const out = run(code(BACKFILL, 'Chunk'), { $json: { rows } });
  assert.equal(out.length, 3);
  assert.equal(out[0].json.rows.length, 500);
  assert.equal(out[2].json.rows.length, 200);
});

test('Chunk emits an item for an empty month so the loop cannot stall', () => {
  const out = run(code(BACKFILL, 'Chunk'), { $json: { rows: [] } });
  assert.equal(out.length, 1);
  assert.deepEqual(out[0].json.rows, []);
});

// ---------------------------------------------------------------- Nightly
test('Window returns a Baghdad-dated start about windowDays back', () => {
  const out = run(code(NIGHTLY, 'Window'), { $: configStub({ windowDays: '35' }) });
  const from = out[0].json.from;

  assert.match(from, /^\d{4}-\d{2}-\d{2}$/);
  const days = Math.round((Date.now() - Date.parse(from + 'T00:00:00Z')) / 86400000);
  assert.ok(days >= 34 && days <= 36, `expected ~35 days back, got ${days}`);
});

test('Window falls back to 35 days when windowDays is unset', () => {
  const out = run(code(NIGHTLY, 'Window'), { $: configStub({}) });
  const days = Math.round((Date.now() - Date.parse(out[0].json.from + 'T00:00:00Z')) / 86400000);
  assert.ok(days >= 34 && days <= 36, `expected ~35 days back, got ${days}`);
});

// ------------------------------------------------------- structural guards
test('the nightly deletes its window before inserting, never upserts blindly', () => {
  // A cancelled invoice DISAPPEARS from account.invoice.report. A plain upsert
  // would leave its stale row behind forever and overstate revenue silently.
  const del = NIGHTLY.nodes.find(n => n.name === 'Delete Window');
  assert.equal(del.parameters.method, 'DELETE');

  // the delete must come AFTER the Odoo fetch, so a failed fetch cannot empty
  // the window and leave nothing behind
  assert.equal(NIGHTLY.connections['Map Rows'].main[0][0].node, 'Has Rows?');
  assert.equal(NIGHTLY.connections['Delete Window'].main[0][0].node, 'Chunk');
});

test('an empty nightly fetch skips the delete instead of wiping the window', () => {
  // 35 days with genuinely zero invoices is far less likely than a silent Odoo
  // failure. Deleting on an empty result would destroy real data.
  const c = NIGHTLY.connections['Has Rows?'].main;   // IF v2: 0 = true, 1 = false
  assert.equal(c[0][0].node, 'Delete Window');
  assert.notEqual(c[1][0].node, 'Delete Window');
});

test('every Odoo node has alwaysOutputData on', () => {
  // Without it, a query matching nothing emits no items and n8n HALTS the whole
  // workflow — which is exactly what stopped the backfill on its first empty month.
  for (const w of [BACKFILL, NIGHTLY, PRODUCTS, CUSTOMERS]) {
    for (const n of w.nodes.filter(n => n.type === 'n8n-nodes-base.odoo')) {
      assert.equal(n.alwaysOutputData, true, `${w.name} / ${n.name}`);
    }
  }
});

test('the mapper survives the empty item alwaysOutputData emits', () => {
  // alwaysOutputData hands on [{json:{}}] for an empty month; that must map to
  // zero rows, not crash and not invent a row.
  const rows = mapRows([{}]);
  assert.deepEqual(rows, []);
});

test('no HTTP node reads $json when its input is another HTTP node', () => {
  // With Prefer: return=minimal a Supabase write responds with an empty body,
  // so a following node's $json is that empty response — not the shaper's
  // output. Chaining two upserts and reading $json.stock yields
  // "undefined is not valid JSON" at runtime. Reference the node by name.
  for (const w of [BACKFILL, NIGHTLY, PRODUCTS, CUSTOMERS, STOCK_HISTORY]) {
    const typeOf = name => w.nodes.find(n => n.name === name)?.type;

    for (const [from, conn] of Object.entries(w.connections)) {
      if (typeOf(from) !== 'n8n-nodes-base.httpRequest') continue;

      for (const target of (conn.main || []).flat()) {
        const node = w.nodes.find(n => n.name === target.node);
        if (node?.type !== 'n8n-nodes-base.httpRequest') continue;

        const body = node.parameters.jsonBody || '';
        assert.ok(!/\$json\./.test(body),
          `${w.name} / ${node.name} reads $json but is fed by the HTTP node "${from}"`);
      }
    }
  }
});

test('the products sync writes both tables from the shaper, not from each other', () => {
  const targets = PRODUCTS.connections['Shape'].main[0].map(t => t.node).sort();
  assert.deepEqual(targets, ['Upsert Products', 'Upsert Stock']);

  for (const name of ['Upsert Products', 'Upsert Stock']) {
    const body = PRODUCTS.nodes.find(n => n.name === name).parameters.jsonBody;
    assert.match(body, /\$\('Shape'\)/, `${name} must name the Shape node explicitly`);
  }
});

test('no workflow carries a real credential', () => {
  const files = fs.readdirSync(path.join(root, 'n8n')).filter(f => f.endsWith('.json'));
  assert.ok(files.length >= 5, 'expected the full workflow set');
  for (const name of files) {
    const raw = fs.readFileSync(path.join(root, 'n8n', name), 'utf8');
    // Any Supabase key — anon or service_role — is a JWT. Prose mentioning
    // "service_role" in a sticky note is documentation, not a leak.
    assert.ok(!/eyJhbGciOiJ/.test(raw), `${name} contains a JWT`);
    assert.ok(/__SERVICE_ROLE_KEY__|__SUPABASE_URL__/.test(raw) || !/supabaseUrl/.test(raw),
      `${name} has a Config node but no placeholder — a real URL may have been committed`);
  }
});

// ------------------------------------------------- products / customers
test('the products shaper reads a real brand and emits a stock row for zero qty', () => {
  const out = run(code(PRODUCTS, 'Shape'), {
    $input: {
      all: () => [
        { json: { id: 55, display_name: '[A 31] nuts', default_code: 'A31',
                  categ_id: [2, 'Snacks'], standard_price: 8000, list_price: 10000,
                  uom_id: [9, 'كارتونة 6 وحدات'], active: true, qty_available: 12,
                  product_brand_id: [4, 'Atlomy'] } },
        { json: { id: 56, display_name: 'x', default_code: false, categ_id: false,
                  standard_price: 0, list_price: 0, uom_id: false, active: true,
                  qty_available: 0, product_brand_id: false } }
      ]
    }
  })[0].json;

  assert.equal(out.products[0].brand, 'Atlomy');   // not the hardcoded null
  assert.equal(out.products[0].uom, 'كارتونة 6 وحدات');
  assert.equal(out.products[1].sku, null);
  assert.equal(out.stock[0].stock_value, 96000);   // 12 x 8000

  // zero-quantity products MUST still get a stock row, or "no stock" becomes
  // indistinguishable from "never synced"
  assert.equal(out.stock.length, 2);
  assert.equal(out.stock[1].on_hand_qty, 0);
});

test('the customers shaper keeps only real customers and takes gov from state_id', () => {
  const out = run(code(CUSTOMERS, 'Shape'), {
    $input: {
      all: () => [
        { json: { id: 7, complete_name: 'Shop A', city: 'Karrada', state_id: [12, 'Baghdad'],
                  user_id: [3, 'Ali'], credit: 500, credit_limit: 1000, customer_rank: 1 } },
        { json: { id: 8, complete_name: 'A Supplier', city: false, state_id: false,
                  user_id: false, credit: 0, credit_limit: 0, customer_rank: 0 } }
      ]
    }
  })[0].json;

  assert.equal(out.rows.length, 1, 'customer_rank 0 is not a customer');
  assert.equal(out.rows[0].governorate, 'Baghdad');
  assert.equal(out.rows[0].salesperson, 'Ali');
  assert.equal(out.rows[0].user_id, 3);
});

test('the stock-history snapshot refuses to run against an empty stock table', () => {
  // Silently writing zero rows would look like a successful snapshot and leave
  // a permanent hole in the history.
  assert.match(code(STOCK_HISTORY, 'Snapshot Stock'), /throw new Error/);
  assert.match(code(STOCK_HISTORY, 'Snapshot Stock'), /Asia\/Baghdad/);
});

test('stock history upserts on the date key so a re-run cannot duplicate a day', () => {
  const node = STOCK_HISTORY.nodes.find(n => n.name === 'Append Snapshot');
  assert.match(node.parameters.url, /on_conflict=product_id,snap_date/);
});

test('the backfill loop is wired to the loop output, not the done output', () => {
  // splitInBatches v3: output 0 = "done", output 1 = "loop". Wiring the body to
  // output 0 would process exactly one month and silently stop.
  const c = BACKFILL.connections['Each Month'].main;
  assert.deepEqual(c[0], []);
  assert.equal(c[1][0].node, 'Invoice Report');
  assert.equal(BACKFILL.connections['Upsert'].main[0][0].node, 'Each Month');
});
