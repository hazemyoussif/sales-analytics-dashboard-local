/**
 * Dabboos Product Dashboard — configuration.
 *
 * This project has its OWN Supabase project, separate from the Sales Command
 * Center. Numbers here are on the INVOICE basis and will not match that
 * dashboard — see README.md for why that is expected.
 */

export const SUPABASE_URL = 'https://jxihpdjyquyttscqzcid.supabase.co';

/**
 * The anon (public) key. Safe to ship in the browser: by itself it reads
 * NOTHING. Row-Level Security grants select to the `authenticated` role only,
 * so every request needs a logged-in user's JWT on top of this.
 *
 * Verified 2026-08-01: with this key alone every table returns HTTP 200 with a
 * zero-row Content-Range — a silent empty result, not an error. That is exactly
 * why api.js must treat "no session" as an auth failure and never as "no data".
 *
 * ⚠️ The service_role key must NEVER appear in this file. It lives in n8n only.
 */
export const SUPABASE_ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imp4aWhwZGp5cXV5dHRzY3F6Y2lkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU2MTEwMDEsImV4cCI6MjEwMTE4NzAwMX0.dTjuYplKencUR8bdJKjIYKwK55Zh8jK1LJkXHt1DBB0';

/** Login convention inherited from the sales dashboard: username → synthetic email. */
export const AUTH_EMAIL_DOMAIN = '@dabboos.app';

/**
 * The sync-runner service (sync/runner.py), if one is deployed. When set, the
 * Sync page shows admins a "مزامنة الآن" button that POSTs {url}/sync with the
 * user's session token. Leave '' to hide the button — the dashboard is fully
 * functional without it (cron and the local task still run the sync).
 * Not a secret: it is only an endpoint, and every call is auth'd by the JWT.
 */
export const SYNC_RUNNER_URL = 'https://dabboos-sync-runner.onrender.com';

export const CURRENCY = { code: 'IQD', ar: 'د.ع', en: 'IQD' };

/**
 * Optional USD view. Every money figure on the dashboard is stored and returned
 * in IQD; the toggle in the top bar only changes how money() renders it. The
 * rate is a FIXED accounting rate the client set — not a live FX rate — so a
 * figure shown in USD today and re-shown next month is the same number.
 */
export const USD_RATE = 1500;                       // 1 USD = 1500 IQD, fixed
export const CURRENCY_USD = { code: 'USD', ar: '$', en: 'USD' };
export const CURRENCY_KEY = 'dabboos.currency';     // localStorage: 'USD' | unset

/** Baghdad drives "today" everywhere. Invoice dates are plain dates, but
 *  "how many days idle" still has to be measured against a Baghdad today. */
export const TIMEZONE = 'Asia/Baghdad';

export const DEFAULT_LANG = 'ar';

/** Business thresholds. Changing these changes what the dashboard recommends,
 *  so they live in one place rather than scattered through the pages. */
export const THRESHOLDS = {
  IDLE_DAYS: 60,            // default "frozen" cut-off; UI offers 30/60/90
  IDLE_DAYS_OPTIONS: [30, 60, 90],
  UNDERSTOCK_COVER_DAYS: 30,   // less cover than this while selling = reorder now
  OVERSTOCK_COVER_DAYS: 180,   // more cover than this = stop buying
  AGING_BUCKETS: [60, 90, 180],
  TARGET_COVER_DAYS: 60,       // what a reorder aims to restore
  STOCKOUT_URGENT_DAYS: 7      // below this, treat as urgent
};

/** Odoo's fixtures category — display racks and stands, not sellable products.
 *  Excluded from every metric. Matched as a regex against the category name. */
export const EXCLUDED_CATEGORY_PATTERN = 'عارضات|استاندات';
