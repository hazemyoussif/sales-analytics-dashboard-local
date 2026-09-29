/**
 * Permission logic — pure functions, no I/O.
 *
 * Same discipline as calc.js: nothing here fetches, reads localStorage or
 * touches the DOM, so the rules can be unit-tested without a network or a
 * database (test/perm.test.js).
 *
 * NOTHING HERE IS A SECURITY BOUNDARY. It decides what to *draw*. The real
 * enforcement is in Postgres — RLS policies scope the rows (04_admin.sql) and
 * the RPCs null out forbidden columns (05_masking.sql). A user who edits these
 * functions in devtools gets a nav link that leads to a page rendering their
 * own scoped, masked data. That is the point: the browser is allowed to be
 * wrong about the rules without leaking anything.
 */

/** Every page the dashboard has. `key` matches app_roles.pages in Postgres.
 *
 * NARROWED. This dashboard used to carry eleven commercial pages. products,
 * status, returns, discounts, agencies, debt, branches, frozen and reorder
 * were removed, and the four tables that fed only them were dropped from
 * Postgres: dashboard_branch_sales, dashboard_branch_stock,
 * dashboard_branch_revenue, dashboard_receivables.
 *
 * dashboard_stock_history was deliberately KEPT even though frozen and reorder
 * were its only readers. Every other dropped table can be rebuilt by re-running
 * its sync job against Odoo. A stock snapshot cannot: you cannot go back and
 * ask what was on the shelf on a date that has already passed.
 *
 * The deleted pages are in git. Restoring one means restoring its .html, its
 * page .js, its row here, its key in app_roles.pages, and -- for branches and
 * debt -- re-running the sync job that rebuilds its table.
 */
export const PAGES = [
  { key: 'overview',   href: 'index.html' },
  { key: 'customers',  href: 'customers.html' },
  // Product mix per توكيل (dashboard_products.brand). A re-framing of Overview
  // data -- calls overview_facts, no table of its own.
  { key: 'agencies',   href: 'agencies.html' },
  // Per-warehouse stock (الرئيسي / البصرة / الموصل). Restored from the nine
  // pages file 52 removed; its table dashboard_branch_stock refills from
  // `python -m odoosync branch-stock`.
  { key: 'warehouses', href: 'warehouses.html' },
  // Lot-level expiry: what is on the shelf and about to go off. Its table
  // dashboard_product_expiry (74_*) refills from `python -m odoosync expiry`.
  { key: 'expiry',     href: 'expiry.html' },
  // Operational rather than commercial: whether the data arrived, not what
  // it says. Grant it to whoever is expected to notice a failed sync.
  { key: 'sync',       href: 'sync.html' },
  { key: 'admin',      href: 'admin.html' }
];

export const PAGE_KEYS = PAGES.map(p => p.key);

/** Maskable columns. Must match VALID_COLUMNS in the admin-users function
 *  and the mask keys handled in 05_masking.sql. */
export const MASKABLE_COLUMNS = ['margin', 'cost', 'revenue', 'stock_value', 'customers'];

/**
 * The Supabase tables a role can be denied outright, with what each one feeds.
 *
 * `risk` drives how the admin page presents it, because these are not equally
 * safe to switch off:
 *
 *   safe      turning it off degrades one feature
 *   degrade   two pages stop being able to answer their question
 *   blackout  the role's dashboard is empty
 *
 * dashboard_excluded_products is deliberately ABSENT. It is a filter, not a
 * data source: hiding it would let the `[DISC]` invoice-discount lines back
 * into every product table and make the numbers WRONG rather than absent.
 * Corrupting data is not a permission setting. See 07_tables_and_overrides.sql.
 */
export const TABLES = [
  {
    key: 'dashboard_invoice_lines', risk: 'blackout',
    ar: 'سطور الفواتير', en: 'Invoice lines',
    pages: ['overview', 'customers'],
    providesAr: 'كل أرقام المبيعات: الإيراد، الكميات، الربح، سرعة البيع، آخر بيع',
    providesEn: 'Every sales number: revenue, units, margin, velocity, last sale'
  },
  {
    key: 'dashboard_products', risk: 'blackout',
    ar: 'المنتجات', en: 'Products',
    pages: ['overview'],
    providesAr: 'كتالوج المنتجات — كل صفحة تبدأ من هذا الجدول',
    providesEn: 'The product catalogue — every page is built from this table'
  },
  {
    key: 'dashboard_stock', risk: 'degrade',
    ar: 'المخزون', en: 'Stock',
    pages: ['overview'],
    providesAr: 'الرصيد الحالي وقيمة المخزون والتغطية',
    providesEn: 'On-hand quantity, stock value and days of cover'
  },
  {
    key: 'dashboard_customers', risk: 'safe',
    ar: 'العملاء', en: 'Customers',
    pages: ['customers'],
    providesAr: 'أسماء العملاء، وأرصدة الذمم والحدود الائتمانية لصفحة الديون',
    providesEn: 'Customer names, plus the balances and credit limits the Debt page is built from'
  },
  {
    key: 'dashboard_stock_history', risk: 'safe',
    ar: 'تاريخ المخزون', en: 'Stock history',
    pages: [],
    providesAr: 'لقطات يومية للمخزون — محفوظة ولا تُقرأ من أي صفحة',
    providesEn: 'Daily stock snapshots — retained, read by no page. Kept because a past snapshot cannot be rebuilt from Odoo.'
  }
];

export const TABLE_KEYS = TABLES.map(t => t.key);

/** Which result fields each mask key covers, for hiding table headers. */
export const COLUMN_FIELDS = {
  margin:      ['margin', 'margin_pct'],
  cost:        ['cost'],
  revenue:     ['revenue', 'realized_price'],
  stock_value: ['stock_value'],
  customers:   ['distinct_customers', 'customer']
};

export function pageHref(key) {
  return PAGES.find(p => p.key === key)?.href ?? null;
}

/**
 * The page key for a URL or file name.
 *
 * Handles both forms, because vercel.json sets `cleanUrls: true`: locally the
 * path is `/products.html`, in production it is `/products`, and the site root
 * `/` is index.html. Matching only the literal file name would make the page
 * guard a no-op in production and nowhere else — the worst kind of bug to find.
 */
export function pageKeyForHref(href) {
  let file = String(href || '').split(/[?#]/)[0].split('/').pop();
  if (!file) file = 'index';                    // '/' and '' are the overview
  file = file.replace(/\.html$/, '');
  return PAGES.find(p => p.href.replace(/\.html$/, '') === file)?.key ?? null;
}

/**
 * `me` is the row from app_me(), or null when the account has no app_users row.
 * Null is DENY, never allow — an account created straight in the Supabase
 * dashboard must not inherit access by being unknown to us.
 */
export function isProvisioned(me) {
  return Boolean(me && Array.isArray(me.pages));
}

export function isAdmin(me) {
  return Boolean(me && me.is_admin);
}

export function canPage(me, key) {
  if (!isProvisioned(me)) return false;
  return me.pages.includes(key);
}

/**
 * True when the column may be shown. An unknown key is allowed: adding a new
 * column to a page should not require a database change before it renders.
 * Forbidding by default would hide new columns from everyone, silently.
 */
export function canColumn(me, key) {
  if (!isProvisioned(me)) return false;
  const hidden = me.hidden_columns || [];
  return !hidden.includes(key);
}

/** Field-level test, for tables that name result fields rather than mask keys. */
export function canField(me, field) {
  if (!isProvisioned(me)) return false;
  const hidden = me.hidden_columns || [];
  return !hidden.some(key => (COLUMN_FIELDS[key] || []).includes(field));
}

/**
 * May this user read this Supabase table?
 *
 * `me.pages` from app_me() is already the EFFECTIVE page list — the role's
 * pages minus the user's `pages_denied` — computed in SQL. There is no
 * override logic here on purpose: two layers that can disagree is exactly the
 * bug this avoids.
 */
export function tableVisible(me, key) {
  if (!isProvisioned(me)) return false;
  return !(me.hidden_tables || []).includes(key);
}

/** Convenience for the pages, which care about capability, not table names. */
export const hasSales = me => tableVisible(me, 'dashboard_invoice_lines');
export const hasStock = me => tableVisible(me, 'dashboard_stock');

/** Nav entries in canonical order, filtered to what this user may open. */
export function visiblePages(me) {
  if (!isProvisioned(me)) return [];
  return PAGES.filter(p => me.pages.includes(p.key));
}

/**
 * Where to send someone who opened a page they may not see. Null means they
 * have no pages at all, which the shell reports rather than redirecting in a
 * loop.
 */
export function firstAllowedPage(me) {
  return visiblePages(me)[0]?.href ?? null;
}

/**
 * A short human description of a user's data scope, for the admin table.
 * `null` scope means everything; `[]` means nothing — the asymmetry is
 * deliberate and documented in 04_admin.sql, so it is spelled out here too.
 */
export function scopeSummary(user, lang = 'ar') {
  const parts = [];
  const all = lang === 'ar' ? 'الكل' : 'all';
  const none = lang === 'ar' ? 'لا شيء' : 'none';
  const rep = lang === 'ar' ? 'مندوب' : 'rep';
  const gov = lang === 'ar' ? 'محافظة' : 'gov';

  const describe = v => (v === null || v === undefined ? all : v.length === 0 ? none : v.join(', '));

  const reps = user?.scope_salespersons;
  const govs = user?.scope_govs;
  if (reps !== null && reps !== undefined) parts.push(`${rep}: ${describe(reps)}`);
  if (govs !== null && govs !== undefined) parts.push(`${gov}: ${describe(govs)}`);
  return parts.length ? parts.join(' · ') : all;
}

/** True when the user is restricted to a subset of the company's data. */
export function isScoped(user) {
  return Boolean(
    (user?.scope_salespersons ?? null) !== null || (user?.scope_govs ?? null) !== null
  );
}

/**
 * Validate a role before saving. Returns an array of problems; empty means OK.
 * Mirrors the guards in 04_admin.sql so the admin sees the reason in the form
 * instead of a raw Postgres exception.
 */
export function validateRole(role, { existingKeys = [] } = {}) {
  const errors = [];
  const key = String(role?.role_key ?? '').trim();

  if (!/^[a-z0-9_]{2,32}$/.test(key)) {
    errors.push('Role key must be 2–32 characters of a–z, 0–9 or underscore');
  }
  if (!role?.is_system && existingKeys.includes(key)) {
    errors.push(`A role named "${key}" already exists`);
  }
  if (!String(role?.name_ar ?? '').trim() || !String(role?.name_en ?? '').trim()) {
    errors.push('Both the Arabic and English names are required');
  }

  const pages = role?.pages ?? [];
  if (!pages.length) errors.push('A role must include at least one page');
  const badPages = pages.filter(p => !PAGE_KEYS.includes(p));
  if (badPages.length) errors.push(`Unknown page: ${badPages.join(', ')}`);

  const badCols = (role?.hidden_columns ?? []).filter(c => !MASKABLE_COLUMNS.includes(c));
  if (badCols.length) errors.push(`Unknown column: ${badCols.join(', ')}`);

  const badTables = (role?.hidden_tables ?? []).filter(t => !TABLE_KEYS.includes(t));
  if (badTables.length) errors.push(`Unknown or non-hideable table: ${badTables.join(', ')}`);

  // The database refuses this too; catching it here explains why.
  if (key === 'admin' && !pages.includes('admin')) {
    errors.push('The admin role must keep the admin page, or nobody can get back in');
  }
  return errors;
}

/**
 * Consequences of a role's hidden tables, for the admin form.
 *
 * These are NOT errors — hiding a blackout table is a legitimate thing to
 * want. They exist so the consequence is stated before the click rather than
 * discovered afterwards as "the dashboard is broken".
 */
export function tableWarnings(role, lang = 'ar') {
  const hidden = role?.hidden_tables ?? [];
  return TABLES
    .filter(t => hidden.includes(t.key) && t.risk !== 'safe')
    .map(t => ({
      key: t.key,
      risk: t.risk,
      text: t.risk === 'blackout'
        ? (lang === 'ar'
            ? `${t.ar}: هذا الدور لن يرى أي بيانات على الإطلاق — كل الصفحات ستكون فارغة.`
            : `${t.en}: this role will see no data at all — every page comes back empty.`)
        : (lang === 'ar'
            ? `${t.ar}: صفحتا رأس المال المجمّد وإعادة الطلب لن تعملا لهذا الدور.`
            : `${t.en}: Frozen capital and Reorder stop working for this role.`)
    }));
}
