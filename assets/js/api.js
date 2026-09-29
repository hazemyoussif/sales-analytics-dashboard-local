/**
 * The only file that knows Supabase exists.
 *
 * Two rules it exists to enforce:
 *
 *  1. EVERY response is capped at 1000 rows — including RPCs. product_facts
 *     returns one row per product; with 1265 products an unpaginated call
 *     silently loses 265 of them and understates revenue by 29%. Measured, not
 *     hypothetical. rpc() paginates by default.
 *
 *  2. An auth failure is NOT an empty result. Without a session every table
 *     returns HTTP 200 with zero rows, so a dashboard that treats "no rows" as
 *     "no sales" will confidently render zeros to a logged-out user. Callers get
 *     a thrown AuthError instead.
 */
import {
  SUPABASE_URL, SUPABASE_ANON_KEY, AUTH_EMAIL_DOMAIN, SYNC_RUNNER_URL
} from './config.js';

const SESSION_KEY = 'dabboos.session';
const ME_KEY = 'dabboos.me';
const PAGE = 1000;

export class ApiError extends Error {
  constructor(message, status, detail) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.detail = detail;
  }
}
export class AuthError extends ApiError {
  constructor(message = 'Not signed in') {
    super(message, 401);
    this.name = 'AuthError';
  }
}

// ---------------------------------------------------------------- session
export function getSession() {
  try {
    const s = JSON.parse(localStorage.getItem(SESSION_KEY) || 'null');
    if (!s || !s.access_token) return null;
    if (s.expires_at && Date.now() > s.expires_at - 60_000) return null;  // treat near-expiry as expired
    return s;
  } catch {
    return null;
  }
}

function setSession(s) {
  localStorage.setItem(SESSION_KEY, JSON.stringify({
    ...s, expires_at: Date.now() + (s.expires_in || 3600) * 1000
  }));
}

export function signOut() {
  localStorage.removeItem(SESSION_KEY);
  // The permission cache belongs to the person who just left. Leaving it
  // behind would let the next sign-in on this browser render the previous
  // user's nav for one paint.
  sessionStorage.removeItem(ME_KEY);
  clearCached('dabboos.health');
  clearCached('dabboos.filters');
  clearCached('dabboos.customers');
}

/** Accepts a bare username or a full email; bare names get the synthetic domain. */
export async function signIn(userOrEmail, password) {
  const email = userOrEmail.includes('@') ? userOrEmail : userOrEmail + AUTH_EMAIL_DOMAIN;
  const res = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: SUPABASE_ANON_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password })
  });
  const body = await res.json();
  if (!res.ok || !body.access_token) {
    throw new AuthError(body.error_description || body.msg || 'Sign-in failed');
  }
  setSession(body);
  sessionStorage.removeItem(ME_KEY);       // whoever was cached here is gone
  logActivity('login');                    // deliberately not awaited
  return body;
}

function headers() {
  const s = getSession();
  if (!s) throw new AuthError();
  return {
    apikey: SUPABASE_ANON_KEY,
    Authorization: `Bearer ${s.access_token}`,
    'Content-Type': 'application/json'
  };
}

// -------------------------------------------------------------------- rpc
/**
 * Call a Postgres function.
 * @param {boolean} paginate  page past the 1000-row cap (default true).
 *                            Pass false only for functions that return a
 *                            handful of rows by construction.
 */
export async function rpc(fn, args = {}, { paginate = true } = {}) {
  const h = headers();
  const call = async (limit, offset) => {
    const qs = limit === null ? '' : `?limit=${limit}&offset=${offset}`;
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}${qs}`, {
      method: 'POST', headers: h, body: JSON.stringify(args)
    });
    if (res.status === 401 || res.status === 403) throw new AuthError('Session expired');
    const body = await res.json().catch(() => null);
    if (!res.ok) {
      throw new ApiError(`${fn} failed`, res.status,
        body?.message || body?.hint || res.statusText);
    }
    return Array.isArray(body) ? body : [];
  };

  if (!paginate) return call(null, 0);

  const out = [];
  for (let offset = 0; ; offset += PAGE) {
    const page = await call(PAGE, offset);
    out.push(...page);
    // A short page means the end. A full page means there is probably more —
    // never assume one page is the whole answer.
    if (page.length < PAGE) break;
    if (offset > 500_000) break;                       // runaway guard
  }
  return out;
}

/** Plain table read, paged the same way. */
export async function select(table, query = '') {
  const h = headers();
  const out = [];
  for (let offset = 0; ; offset += PAGE) {
    const sep = query.includes('?') ? '&' : '?';
    const url = `${SUPABASE_URL}/rest/v1/${table}${query}${sep}limit=${PAGE}&offset=${offset}`;
    const res = await fetch(url, { headers: h });
    if (res.status === 401 || res.status === 403) throw new AuthError('Session expired');
    if (!res.ok) throw new ApiError(`read ${table} failed`, res.status, await res.text());
    const page = await res.json();
    out.push(...page);
    if (page.length < PAGE) break;
  }
  return out;
}

/**
 * Two answers that are identical for everyone and change once a day, cached
 * for the length of a browsing session.
 *
 * These run on EVERY page load, before anything else -- so moving between
 * pages paid for both again each time, and that is most of what "the
 * dashboard feels laggy" actually was. Neither depends on the user, the
 * filters or the date range, and both are rebuilt by the nightly sync.
 *
 * sessionStorage, not localStorage: a tab is the right lifetime. Someone who
 * reopens the dashboard after the sync has run gets the new figures without
 * having to know to clear anything.
 *
 * Deliberately NOT a general request cache. Every other call varies by date
 * and filter, so caching those would mostly store answers nobody asks for
 * twice, and would eventually serve a stale number to someone who had just
 * changed a filter -- which is worse than being slow.
 */
const SESSION_TTL_MS = 10 * 60 * 1000;

function sessionCached(keyBase, ttl, fetcher) {
  return async (...args) => {
    // THE ARGUMENTS ARE PART OF THE KEY. They were not, and filter_options was
    // about to grow some: filterOptions('اربيل') would have returned the
    // cached global list, the cascade would have looked broken, and the bug
    // would have looked like it was in the SQL.
    const key = args.length ? `${keyBase}:${JSON.stringify(args)}` : keyBase;
    try {
      const hit = JSON.parse(sessionStorage.getItem(key) || 'null');
      if (hit && Date.now() - hit.at < ttl) return hit.value;
    } catch { /* unreadable cache is a miss, never an error */ }
    const value = await fetcher(...args);
    try {
      sessionStorage.setItem(key, JSON.stringify({ at: Date.now(), value }));
    } catch { /* full or blocked: caching is a nicety, the answer is not */ }
    return value;
  };
}

/** Drop every cached entry under a base key, whatever arguments made it. */
function clearCached(keyBase) {
  try {
    for (const k of Object.keys(sessionStorage)) {
      if (k === keyBase || k.startsWith(keyBase + ':')) sessionStorage.removeItem(k);
    }
  } catch { /* nothing to clear is not a failure */ }
}

/** data_health() as a plain object. */
export const dataHealth = sessionCached('dabboos.health', SESSION_TTL_MS,
  async () => {
    const rows = await rpc('data_health', {}, { paginate: false });
    return Object.fromEntries(rows.map(r => [r.metric, r.value]));
  });

/**
 * filter_options() grouped by kind, each sorted by frequency.
 *
 * Pass a governorate, and optionally a city, to get only what exists inside
 * it. `gov` itself always comes back complete -- narrowing the control you are
 * standing on would leave no way to choose a different one.
 */
export const filterOptions = sessionCached('dabboos.filters', SESSION_TTL_MS,
  async (gov = null, city = null) => {
    const rows = await rpc('filter_options',
      { p_gov: gov || null, p_city: city || null }, { paginate: false });
    const out = { gov: [], city: [], salesperson: [], category: [], brand: [] };
    for (const r of rows) if (out[r.kind]) out[r.kind].push({ value: r.value, n: Number(r.n) });
    for (const k of Object.keys(out)) out[k].sort((a, b) => b.n - a.n);
    return out;
  });

export function productFacts(params) {
  return rpc('product_facts', params);
}

/** One row per catalogue product: family, agency (brand), category, id, name.
 *  ~1,400 rows, so it pages once. Feeds the عائلة -> توكيل -> منتج cascade on
 *  Overview, 80/20 and the Agencies page. */
export const productFilterTree = () => rpc('product_filter_tree', {});

/* ---------------------------------------------------------------------------
 * Overview, without downloading the catalogue
 * -------------------------------------------------------------------------
 * product_facts returns one row per product -- 1,431 of them, in two paged
 * requests that each re-run the whole function, so the browser could sum them
 * itself. Measured as a real user: 2.7s unfiltered, 13.4s with a city filter
 * over 27 months, against a 20 second cap.
 *
 * These four ask the database for the answers instead. All four are SQL
 * wrappers around product_facts, so the numbers are identical by construction
 * rather than by my having re-derived them.
 *
 * paginate:false on every one. Each is bounded by its own LIMIT or returns a
 * single row, so paging would only ever cost a second request that returns
 * nothing -- and that second request re-runs the function.
 */
export const productSummary = params =>
  rpc('product_summary', params, { paginate: false });
export const productTop = params =>
  rpc('product_top', params, { paginate: false });
export const productUnsold = params =>
  rpc('product_unsold', params, { paginate: false });
export const productByCategory = params =>
  rpc('product_by_category', params, { paginate: false });

/**
 * All of the above in ONE call, one scan.
 *
 * The four separate functions were five round trips and five executions of
 * product_facts. When the query is 12ms the round trips ARE the cost, so the
 * default view got slower even though it downloaded 85% less. This runs
 * product_facts once and reads that single result four ways.
 *
 * The lists arrive as jsonb because a function returns one shape and the tiles
 * are one row while the tables are many.
 */
export const overviewFacts = params =>
  rpc('overview_facts', params, { paginate: false });

// ------------------------------------------------- returns and discounts
/**
 * Credit notes, separated out rather than netted.
 *
 * Every other figure on this dashboard nets returns into revenue, so a product
 * that sells 1000 and takes 300 back looks identical to one that sold 700
 * cleanly. These RPCs pull the two apart. Paginated by default — a busy period
 * can exceed 1000 products.
 */
export const returnsByProduct = params => rpc('returns_by_product', params);

/** kind: customer | salesperson | gov | category. Few rows by construction. */
export const returnsByDimension = (params) =>
  rpc('returns_by_dimension', params, { paginate: false });

/**
 * Realized price against list price — where margin leaks.
 * discount_pct is null, never 0, when no list price is known.
 */
export const discountsByProduct = params => rpc('discounts_by_product', params);

export const discountsByDimension = (params) =>
  rpc('discounts_by_dimension', params, { paginate: false });

/**
 * Customers for the filter dropdown, name-sorted.
 *
 * CACHED, because this was the most expensive thing on the page and nobody had
 * noticed. There are 6,351 customers and PostgREST caps a response at 1000, so
 * api.js paged: SEVEN sequential requests, about 3.7 seconds, on every single
 * page load — to fill one dropdown. Measured signed in as a real user.
 *
 * It is safe to cache in a way the numbers are not: this is a list of names,
 * it changes once a day when the sync runs, and a customer missing from the
 * dropdown for ten minutes costs nothing. A stale REVENUE figure would be a
 * different matter, which is why nothing else here is cached.
 *
 * Scoped by RLS like everything else, so a Basra-restricted user's list holds
 * only Basra customers — and a role with dashboard_customers hidden gets an
 * empty list rather than an error. Callers must therefore treat "empty" as
 * "no customer filter available", not as "this company has no customers".
 *
 * The cache key includes no arguments because there are none; sign-out clears
 * it, so the next user does not inherit the previous one's scoped list.
 */
export const listCustomers = sessionCached('dabboos.customers', SESSION_TTL_MS,
  () => select('dashboard_customers',
               '?select=partner_id,complete_name&order=complete_name.asc'));

/**
 * Invoice-level adjustments (discounts etc.) that product_facts deliberately
 * excludes. Shown beside the KPIs so that
 *     product revenue + adjustments = the figure Odoo reports
 * stays true and visible rather than the difference going unexplained.
 */
export function revenueAdjustments(params) {
  return rpc('revenue_adjustments', params, { paginate: false });
}

// ================================================================ permissions
/**
 * Who am I and what may I see — one row from app_me(), or null.
 *
 * NULL IS NOT AN ERROR AND IT IS NOT "NO DATA". It means the signed-in account
 * has no row in app_users, so the database will hand it zero rows on every
 * table. Callers must say "account not provisioned" rather than rendering an
 * empty dashboard — the same distinction this file already draws between an
 * auth failure and an empty result.
 *
 * Cached in sessionStorage for the tab's lifetime: it is read on every page
 * load and changes only when an admin edits the user, or when a migration adds
 * a page to a role.
 *
 * ⚠️ A RELOAD DOES NOT PICK UP A CHANGE. sessionStorage survives reloads —
 * including a hard reload — so a tab that is already open keeps the permission
 * list it fetched when it was opened. Only signing out, opening a NEW tab, or
 * calling clearMeCache() refetches it.
 *
 * This is worth knowing before debugging a nav that "did not update": after
 * granting a page in SQL, the screen is right and the tab is stale. An earlier
 * version of this comment claimed a hard reload was enough, which sent someone
 * looking for a deploy problem that was not there.
 */
export async function appMe({ fresh = false } = {}) {
  if (!fresh) {
    try {
      const cached = JSON.parse(sessionStorage.getItem(ME_KEY) || 'null');
      if (cached) return cached.me;
    } catch { /* a corrupt cache just means we refetch */ }
  }
  const rows = await rpc('app_me', {}, { paginate: false });
  const me = rows[0] || null;
  try {
    sessionStorage.setItem(ME_KEY, JSON.stringify({ me }));
  } catch { /* private mode: work uncached rather than fail */ }
  return me;
}

export function clearMeCache() {
  sessionStorage.removeItem(ME_KEY);
}

/**
 * Record a login or a page view. Fire-and-forget on purpose: tracking must
 * never delay a render or surface an error on someone's dashboard, so this
 * swallows everything. A failed log is a lost row, not a broken page.
 */
export async function logActivity(kind, page = null) {
  try {
    if (!getSession()) return;
    await rpc('app_log', { p_kind: kind, p_page: page }, { paginate: false });
  } catch { /* intentionally silent */ }
}

// ====================================================================== admin
/**
 * Call the admin-users Edge Function — the only path to creating a login or
 * setting a password, because both need the service_role key.
 *
 * The function re-checks that the caller is an admin against the database. A
 * non-admin who calls this directly gets 403, so the admin page hiding the
 * button is convenience, not protection.
 */
export async function adminUsers(action, payload = {}) {
  const s = getSession();
  if (!s) throw new AuthError();

  const res = await fetch(`${SUPABASE_URL}/functions/v1/admin-users`, {
    method: 'POST',
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${s.access_token}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ action, ...payload })
  });

  const body = await res.json().catch(() => null);
  if (res.status === 401) throw new AuthError(body?.error || 'Session expired');
  if (!res.ok) {
    throw new ApiError(body?.error || `admin-users/${action} failed`, res.status,
      body?.error || res.statusText);
  }
  return body;
}

/**
 * Roles are plain table writes: app_roles has admin-only RLS policies, so no
 * elevated key is involved and no Edge Function round-trip is needed.
 * A non-admin's write is rejected by Postgres, not by this function.
 */
async function write(method, table, query, row) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}${query}`, {
    method,
    headers: { ...headers(), Prefer: 'return=representation' },
    body: row === undefined ? undefined : JSON.stringify(row)
  });
  if (res.status === 401 || res.status === 403) {
    throw new AuthError('Not permitted — administrator access required');
  }
  const body = await res.json().catch(() => null);
  if (!res.ok) {
    throw new ApiError(`${method} ${table} failed`, res.status,
      body?.message || body?.hint || body?.details || res.statusText);
  }
  return body;
}

export const listRoles   = () => select('app_roles', '?order=is_system.desc,role_key.asc');
export const createRole  = role => write('POST', 'app_roles', '', role);
export const updateRole  = (key, patch) =>
  write('PATCH', 'app_roles', `?role_key=eq.${encodeURIComponent(key)}`, patch);
export const deleteRole  = key =>
  write('DELETE', 'app_roles', `?role_key=eq.${encodeURIComponent(key)}`);

/**
 * Recent activity, newest first. Admins see everyone; anyone else sees only
 * their own rows — enforced by the RLS policy, not by this query.
 *
 * A single capped read rather than select(), which pages to the end: this
 * table grows without bound, and "the last 200 events" is the whole question
 * the admin page asks.
 */
export async function listActivity(limit = 200) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/app_activity?order=at.desc&limit=${limit}`,
    { headers: headers() });
  if (res.status === 401 || res.status === 403) throw new AuthError('Session expired');
  if (!res.ok) throw new ApiError('read app_activity failed', res.status, await res.text());
  return res.json();
}

/* ---------------------------------------------------------------------------
 * Sync health
 * -------------------------------------------------------------------------
 * Deliberately NOT sessionCached. Everything else cached above is a fact about
 * the data that changes once a day; this is a fact about whether that daily
 * change actually happened. Serving it ten minutes stale would mean the one
 * page whose job is to tell you something is wrong could be the last to say so.
 */
export const syncHealth = () => rpc('sync_health');
export const syncRuns = (limit = 60) => rpc('sync_runs', { p_limit: limit });

/** Whether a "sync now" button can be offered at all (see config.js). */
export const syncRunnerConfigured = () => Boolean(SYNC_RUNNER_URL);

/**
 * Ask the sync-runner service to start a full sync. Resolves on 202. Throws an
 * Error whose `.status` is the HTTP code so the caller can tell "already
 * running" (409) and "too soon" (429) from a real failure.
 */
export async function triggerSync() {
  if (!SYNC_RUNNER_URL) throw new Error('sync runner not configured');
  const s = getSession();
  if (!s) throw new AuthError();
  let res;
  try {
    res = await fetch(`${SYNC_RUNNER_URL.replace(/\/$/, '')}/sync`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${s.access_token}` }
    });
  } catch (err) {
    const e = new Error('could not reach the sync service');
    e.status = 0;
    throw e;
  }
  if (res.status === 202) return true;
  let detail = '';
  try { detail = (await res.json()).detail || ''; } catch { /* no body */ }
  const e = new Error(detail || `sync request failed (${res.status})`);
  e.status = res.status;
  throw e;
}
