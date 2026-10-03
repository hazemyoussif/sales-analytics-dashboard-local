/* ============================================================
   Dabboos Sales Command Center — configuration
   The dashboard reads data DIRECTLY from Supabase (cloud),
   which n8n keeps fresh. n8n itself can stay on localhost.
   ============================================================ */
window.DASH_CONFIG = {
  // Your Supabase project URL (no trailing slash).
  SUPABASE_URL: "https://puqfldltipedlodwfyex.supabase.co",

  // Supabase ANON (public) key — SAFE to expose in the browser because, once
  // supabase/auth-setup.sql has been applied, this key alone reads NOTHING:
  // every read requires a logged-in, active user's JWT (Row-Level Security).
  // Get it from: Supabase → Project Settings → API → Project API keys → "anon public".
  // ⚠️ NEVER put the service_role key here — that one stays inside n8n only.
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB1cWZsZGx0aXBlZGxvZHdmeWV4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA5NDExODUsImV4cCI6MjA5NjUxNzE4NX0.4vUPTMBBDkHMQTfAr8R0hU7vwKxc969ORVhiO_VhVCc",

  // Table / snapshot names (must match supabase/schema.sql).
  TABLES: {
    orders: "dashboard_orders",
    snapshots: "dashboard_snapshots"
  },

  // Live refresh interval in milliseconds. 3 minutes: every poll re-downloads
  // and re-renders the whole window, and a 60s cycle kept low-power machines
  // permanently busy ("Page Unresponsive"). Heavy aggregates are additionally
  // cached for 4 minutes in common.js.
  POLL_MS: 180000,

  // Currency label shown next to amounts.
  CURRENCY: "IQD",
  CURRENCY_AR: "د.ع",

  // Default UI language: "ar" or "en".
  DEFAULT_LANG: "ar",

  // Play a sound + toast when a NEW critical alert appears.
  SOUND_ENABLED: true,

  // Treat "warning" alerts as sound-worthy too (false = critical only).
  SOUND_ON_WARNING: false,

  // ---- Executive targets (used by the Overview / Executive summary band) ----
  // Set these to the company's real goals. They drive the "vs target",
  // attainment %, and pace-to-target figures. Pure presentation config — no
  // sensitive data.
  // ⚠️ IMPORTANT: MONTHLY_REVENUE_TARGET below is a PLACEHOLDER. Until the real
  // figure is set, the Overview's "% of target" and "on pace for" numbers are
  // meaningless. Set the real monthly goal, OR set it to 0 to HIDE the target
  // bar entirely (the code already falls back to showing order count instead).
  TARGETS: {
    // 0 = HIDE the target bar. The old 900M was a placeholder that showed
    // misleading "% of target / on pace" figures. The real fix is syncing the
    // per-rep targets from Odoo's salesperson.target model (docs/ODOO_MODELS.md);
    // until then, set the real company-wide goal here or keep it hidden.
    MONTHLY_REVENUE_TARGET: 0,
    COLLECTION_RATE_TARGET: 70        // target for collected ÷ sales (%)
  }
};
