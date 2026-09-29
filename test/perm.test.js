/**
 * Unit tests for the permission logic.
 *
 * These test what the BROWSER decides to draw. They are not, and cannot be, a
 * test of the security model: rows are scoped by RLS policies (04_admin.sql)
 * and columns are nulled inside the RPCs (05_masking.sql), neither of which
 * runs in Node. What is tested here is that the UI never draws a link or a
 * column the role does not have, and — more importantly — that the defaults
 * fail CLOSED when the permission row is missing or malformed.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  PAGES, PAGE_KEYS, MASKABLE_COLUMNS, TABLES, TABLE_KEYS,
  pageHref, pageKeyForHref,
  isProvisioned, isAdmin, canPage, canColumn, canField,
  visiblePages, firstAllowedPage, scopeSummary, isScoped, validateRole,
  tableVisible, hasSales, hasStock, tableWarnings
} from '../assets/js/perm.js';

const admin = {
  username: 'ahmed', role_key: 'admin', is_admin: true,
  pages: [...PAGE_KEYS], hidden_columns: [], hidden_tables: [],
  scope_salespersons: null, scope_govs: null
};

const rep = {
  username: 'ali', role_key: 'sales_rep', is_admin: false,
  pages: ['overview', 'products'], hidden_columns: ['margin', 'cost'],
  hidden_tables: [],
  scope_salespersons: ['Ali Hassan'], scope_govs: ['البصرة', 'النجف']
};

// ----------------------------------------------------------- fail-closed rules
test('an unprovisioned user is denied everything', () => {
  for (const me of [null, undefined, {}, { pages: null }]) {
    assert.equal(isProvisioned(me), false);
    assert.equal(isAdmin(me), false);
    assert.equal(canPage(me, 'overview'), false);
    assert.equal(canColumn(me, 'margin'), false);
    assert.equal(canField(me, 'revenue'), false);
    assert.deepEqual(visiblePages(me), []);
    assert.equal(firstAllowedPage(me), null);
  }
});

test('an empty pages array grants no page, rather than all of them', () => {
  const me = { pages: [], hidden_columns: [], is_admin: false };
  assert.equal(canPage(me, 'overview'), false);
  assert.equal(firstAllowedPage(me), null);
});

// -------------------------------------------------------------------- pages
test('a role sees only the pages it lists, in canonical order', () => {
  assert.deepEqual(visiblePages(rep).map(p => p.key), ['overview', 'products']);
  assert.equal(canPage(rep, 'frozen'), false);
  assert.equal(canPage(rep, 'admin'), false);
  assert.equal(firstAllowedPage(rep), 'index.html');
});

test('only an admin gets the admin page', () => {
  assert.equal(canPage(admin, 'admin'), true);
  assert.equal(isAdmin(admin), true);
  assert.equal(isAdmin(rep), false);
});

// The guard is driven by the URL, and vercel.json sets cleanUrls: true — so
// production paths have no .html. Matching only the literal file name would
// silently disable the guard in production and nowhere else.
test('page keys resolve from both clean and .html URLs', () => {
  assert.equal(pageKeyForHref('/products.html'), 'products');
  assert.equal(pageKeyForHref('/products'), 'products');
  assert.equal(pageKeyForHref('products.html?from=2026-01-01'), 'products');
  assert.equal(pageKeyForHref('/'), 'overview');
  assert.equal(pageKeyForHref(''), 'overview');
  assert.equal(pageKeyForHref('/index.html'), 'overview');
  assert.equal(pageKeyForHref('/admin'), 'admin');
  assert.equal(pageKeyForHref('/nope'), null);
});

test('every page has an href and every href maps back to its key', () => {
  for (const p of PAGES) {
    assert.equal(pageHref(p.key), p.href);
    assert.equal(pageKeyForHref(p.href), p.key);
  }
});

// ------------------------------------------------------------------ columns
test('hidden columns hide every field they cover', () => {
  assert.equal(canColumn(rep, 'margin'), false);
  assert.equal(canField(rep, 'margin'), false);
  assert.equal(canField(rep, 'margin_pct'), false);   // margin_pct leaks margin
  assert.equal(canField(rep, 'cost'), false);
});

test('columns the role does not hide stay visible', () => {
  assert.equal(canColumn(rep, 'revenue'), true);
  assert.equal(canField(rep, 'revenue'), true);
  assert.equal(canField(rep, 'realized_price'), true);
  assert.equal(canField(rep, 'stock_value'), true);
});

test('an admin with no hidden columns sees every maskable column', () => {
  for (const c of MASKABLE_COLUMNS) assert.equal(canColumn(admin, c), true);
});

// A new column added to a page must render for existing roles rather than
// vanishing until someone edits the database.
test('an unknown field is allowed for a provisioned user', () => {
  assert.equal(canField(rep, 'some_new_column'), true);
  assert.equal(canColumn(rep, 'some_new_column'), true);
});

// -------------------------------------------------------------------- scope
// NULL means all and [] means nothing. Conflating them is the single easiest
// way to hand someone the whole company by accident.
test('null scope is unrestricted, empty scope is nothing', () => {
  assert.equal(isScoped(admin), false);
  assert.equal(isScoped({ scope_salespersons: null, scope_govs: null }), false);
  assert.equal(isScoped({ scope_salespersons: [], scope_govs: null }), true);
  assert.equal(isScoped(rep), true);
});

test('scope summary distinguishes all from none', () => {
  assert.equal(scopeSummary(admin, 'en'), 'all');
  assert.match(scopeSummary(rep, 'en'), /rep: Ali Hassan/);
  assert.match(scopeSummary(rep, 'en'), /gov: البصرة, النجف/);
  assert.match(scopeSummary({ scope_govs: [] }, 'en'), /gov: none/);
});

// --------------------------------------------------------------- role rules
test('a valid role passes', () => {
  assert.deepEqual(
    validateRole({ role_key: 'sales_rep', name_ar: 'مندوب', name_en: 'Rep',
                   pages: ['overview'], hidden_columns: ['margin'] }),
    []);
});

test('a role must have a usable key, both names, and a page', () => {
  const errs = validateRole({ role_key: 'Bad Key!', name_ar: '', name_en: '', pages: [] });
  assert.equal(errs.length, 3);
  assert.match(errs.join(' '), /Role key/);
  assert.match(errs.join(' '), /Arabic and English/);
  assert.match(errs.join(' '), /at least one page/);
});

test('unknown pages and columns are rejected', () => {
  const errs = validateRole({
    role_key: 'x_role', name_ar: 'أ', name_en: 'A',
    pages: ['overview', 'billing'], hidden_columns: ['margin', 'secret']
  });
  assert.match(errs.join(' '), /Unknown page: billing/);
  assert.match(errs.join(' '), /Unknown column: secret/);
});

test('a duplicate role key is rejected for a new role only', () => {
  const role = { role_key: 'management', name_ar: 'أ', name_en: 'A', pages: ['overview'] };
  assert.match(
    validateRole(role, { existingKeys: ['admin', 'management'] }).join(' '),
    /already exists/);
  // editing an existing role passes no existingKeys, so its own key is fine
  assert.deepEqual(validateRole(role), []);
});

// Mirrors the trigger in 04_admin.sql. Without the admin page nobody can ever
// reach the admin screen again, and the only fix is a manual SQL session.
test('the admin role cannot drop the admin page', () => {
  const errs = validateRole({
    role_key: 'admin', name_ar: 'مدير', name_en: 'Administrator',
    pages: ['overview'], hidden_columns: [], is_system: true
  });
  assert.match(errs.join(' '), /must keep the admin page/);
});

// ------------------------------------------------------------ hidden tables
const stockless = {
  ...rep, hidden_tables: ['dashboard_stock']
};

test('a hidden table is invisible, others are unaffected', () => {
  assert.equal(tableVisible(stockless, 'dashboard_stock'), false);
  assert.equal(hasStock(stockless), false);
  assert.equal(tableVisible(stockless, 'dashboard_invoice_lines'), true);
  assert.equal(hasSales(stockless), true);
});

test('an unprovisioned user can read no table', () => {
  for (const me of [null, {}, { hidden_tables: [] }]) {
    assert.equal(tableVisible(me, 'dashboard_stock'), false);
    assert.equal(hasSales(me), false);
  }
});

test('a role with no hidden_tables sees every table', () => {
  for (const k of TABLE_KEYS) assert.equal(tableVisible(admin, k), true);
});

// dashboard_excluded_products is a FILTER. Hiding it would un-exclude the
// [DISC] invoice-discount lines and make numbers wrong rather than absent, so
// it must never be offerable.
test('the exclusion-list table is not hideable', () => {
  assert.equal(TABLE_KEYS.includes('dashboard_excluded_products'), false);
  const errs = validateRole({
    role_key: 'x_role', name_ar: 'أ', name_en: 'A', pages: ['overview'],
    hidden_columns: [], hidden_tables: ['dashboard_excluded_products']
  });
  assert.match(errs.join(' '), /non-hideable table/);
});

test('every table declares a risk level and the pages it feeds', () => {
  for (const t of TABLES) {
    assert.ok(['safe', 'degrade', 'blackout'].includes(t.risk), t.key);
    assert.ok(Array.isArray(t.pages), t.key);
    assert.ok(t.ar && t.en, t.key);
    // every page a table claims to feed must actually exist
    for (const p of t.pages) assert.ok(PAGE_KEYS.includes(p), `${t.key} → ${p}`);
  }
});

// The warning is the whole reason blackout tables are safe to expose in the
// UI. If it stops firing, an admin can blank a role's dashboard in one click.
test('blackout tables warn, safe tables do not', () => {
  const warns = tableWarnings({ hidden_tables: ['dashboard_products'] }, 'en');
  assert.equal(warns.length, 1);
  assert.equal(warns[0].risk, 'blackout');
  assert.match(warns[0].text, /no data at all/);

  assert.deepEqual(tableWarnings({ hidden_tables: ['dashboard_customers'] }, 'en'), []);
  assert.deepEqual(tableWarnings({ hidden_tables: [] }, 'en'), []);
  assert.deepEqual(tableWarnings({}, 'en'), []);
});

test('degrading a table warns without claiming a blackout', () => {
  const warns = tableWarnings({ hidden_tables: ['dashboard_stock'] }, 'en');
  assert.equal(warns.length, 1);
  assert.equal(warns[0].risk, 'degrade');
  assert.match(warns[0].text, /Frozen capital and Reorder/);
});

test('warnings are produced in both languages', () => {
  const ar = tableWarnings({ hidden_tables: ['dashboard_products'] }, 'ar');
  assert.equal(ar.length, 1);
  assert.notEqual(ar[0].text, tableWarnings({ hidden_tables: ['dashboard_products'] }, 'en')[0].text);
});

// --------------------------------------------------- per-user page overrides
// app_me() computes effective pages in SQL (role.pages minus pages_denied), so
// the browser never merges two layers. These assert that contract holds: what
// perm.js receives in `pages` is already final.
test('effective pages are taken as given, with no client-side merging', () => {
  const denied = { ...rep, pages: ['overview'], pages_denied: ['products'] };
  assert.deepEqual(visiblePages(denied).map(p => p.key), ['overview']);
  assert.equal(canPage(denied, 'products'), false);
});

test('a denial list cannot grant a page the role never had', () => {
  // pages is the SERVER's effective list; a stray pages_denied entry naming a
  // page not in it must not resurrect that page.
  const me = { ...rep, pages: ['overview'], pages_denied: ['frozen'] };
  assert.equal(canPage(me, 'frozen'), false);
  assert.deepEqual(visiblePages(me).map(p => p.key), ['overview']);
});


// The Status page is a new entry in PAGES. Every place that lists pages has to
// agree, or the page exists and nobody can open it — including the admin, who
// would have no checkbox to grant it with.
test('the status page is registered and reachable', () => {
  assert.ok(PAGE_KEYS.includes('status'));
  assert.equal(pageHref('status'), 'status.html');
  assert.equal(pageKeyForHref('/status'), 'status');
  assert.equal(pageKeyForHref('/status.html'), 'status');
});

test('a role without the status page cannot open it', () => {
  assert.equal(canPage(rep, 'status'), false);
  assert.equal(canPage(admin, 'status'), true);
});


// Returns and Discounts are new PAGES entries. Every list that names pages has
// to agree — perm.js, the Edge Function's VALID_PAGES, and app_roles.pages via
// 09_returns_discounts.sql — or the page exists and nobody can open it.
test('the returns and discounts pages are registered and reachable', () => {
  for (const [key, href] of [['returns', 'returns.html'], ['discounts', 'discounts.html']]) {
    assert.ok(PAGE_KEYS.includes(key), key);
    assert.equal(pageHref(key), href);
    assert.equal(pageKeyForHref('/' + key), key);          // vercel cleanUrls
    assert.equal(pageKeyForHref('/' + href), key);
  }
});

test('a role without the new pages cannot open them', () => {
  assert.equal(canPage(rep, 'returns'), false);
  assert.equal(canPage(rep, 'discounts'), false);
  assert.equal(canPage(admin, 'returns'), true);
  assert.equal(canPage(admin, 'discounts'), true);
});

// Both pages are built entirely from dashboard_invoice_lines, so the table
// catalogue must say so — otherwise the admin hiding it gets no warning that
// these pages go dark.
test('the invoice-lines table declares the pages it feeds', () => {
  const lines = TABLES.find(t => t.key === 'dashboard_invoice_lines');
  assert.ok(lines.pages.includes('returns'));
  assert.ok(lines.pages.includes('discounts'));
});
