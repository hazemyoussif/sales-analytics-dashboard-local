/* ============================================================
   Dabboos Sales Command Center — auth gate
   Session (Supabase Auth via REST) + page guard + permissions
   + traffic ping. MUST load after config.js and BEFORE common.js.

   The UI checks here are convenience only — the hard enforcement
   is Row-Level Security in Supabase (see supabase/auth-setup.sql):
   without a valid, ACTIVE login token the database returns nothing.
   ============================================================ */
(function () {
  const CFG = window.DASH_CONFIG;
  const BASE = CFG.SUPABASE_URL.replace(/\/$/, "");
  const SKEY = "dash_session_v1";
  const PKEY = "dash_profile_v1";
  // Usernames are mapped to synthetic emails for Supabase Auth
  // ("ahmed" → "ahmed@dabboos.app"). No mailbox exists — email
  // confirmations must be OFF in Supabase Auth settings.
  const EMAIL_DOMAIN = "dabboos.app";

  /* ------------- pages & role defaults ------------- */
  const PAGE_ORDER = ["overview", "regions", "sales", "collections", "debt", "alerts", "admin"];
  // Clean URLs (Vercel cleanUrls): pages are addressed without the .html
  // extension; overview lives at the site root. These are redirect targets.
  const FILE_OF = {
    overview: "/", regions: "/regions", sales: "/salespeople",
    collections: "/collections", debt: "/debt", alerts: "/alerts", admin: "/admin"
  };
  // A user's `pages` jsonb overrides these per key; missing keys fall back here.
  const ROLE_DEFAULTS = {
    admin:      { overview: true,  regions: true,  sales: true,  collections: true,  debt: true,  alerts: true, admin: true  },
    management: { overview: true,  regions: true,  sales: true,  collections: true,  debt: true,  alerts: true, admin: false },
    alerts:     { overview: false, regions: false, sales: false, collections: false, debt: false, alerts: true, admin: false }
  };

  function pageIdFromLocation() {
    // Strip any .html FIRST, then match bare names — so it works whether the
    // URL is clean (/salespeople, Vercel cleanUrls) or legacy (salespeople.html).
    const f = (location.pathname.split("/").pop() || "").toLowerCase().replace(/\.html$/, "");
    if (!f || f === "index") return "overview";
    if (f === "salespeople") return "sales";
    if (f === "acknowledgments") return "alerts";
    if (f === "login") return "login";
    return f;
  }
  const CURRENT = pageIdFromLocation();

  /* ------------- storage ------------- */
  function readJSON(k) { try { return JSON.parse(localStorage.getItem(k) || "null"); } catch (e) { return null; } }
  function session() { return readJSON(SKEY); }
  function profile() { return readJSON(PKEY); }
  function saveSession(s) { localStorage.setItem(SKEY, JSON.stringify(s)); }
  function clearAll() { localStorage.removeItem(SKEY); localStorage.removeItem(PKEY); }
  function toEmail(u) {
    u = String(u || "").trim().toLowerCase();
    return u.includes("@") ? u : u + "@" + EMAIL_DOMAIN;
  }

  /* ------------- headers for PostgREST calls -------------
     apikey stays the anon key; Authorization carries the USER token so
     Row-Level Security sees who is asking. */
  function headers(extra) {
    const s = session();
    const tok = (s && s.access_token) || CFG.SUPABASE_ANON_KEY;
    return Object.assign(
      { apikey: CFG.SUPABASE_ANON_KEY, Authorization: "Bearer " + tok },
      extra || {});
  }

  /* ------------- sign in / out / up ------------- */
  async function signIn(username, password) {
    const res = await fetch(BASE + "/auth/v1/token?grant_type=password", {
      method: "POST",
      headers: { apikey: CFG.SUPABASE_ANON_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ email: toEmail(username), password: password })
    });
    const j = await res.json().catch(() => ({}));
    if (!res.ok) {
      const err = new Error(j.error_description || j.msg || ("login failed HTTP " + res.status));
      err.code = "badlogin";
      throw err;
    }
    saveSession({
      access_token: j.access_token,
      refresh_token: j.refresh_token,
      expires_at: Math.floor(Date.now() / 1000) + (j.expires_in || 3600),
      user_id: j.user && j.user.id
    });
    const p = await fetchProfile();
    if (!p) { clearAll(); const e = new Error("profile missing"); e.code = "noprofile"; throw e; }
    if (!p.is_active) { clearAll(); const e = new Error("account inactive"); e.code = "inactive"; throw e; }
    return p;
  }

  async function signOut() {
    try {
      if (session()) await fetch(BASE + "/auth/v1/logout", { method: "POST", headers: headers() });
    } catch (e) { /* best effort */ }
    toLogin();
  }

  // Used by the admin panel to create users. New users are born INACTIVE
  // (the DB trigger forces it) — the panel activates them right after.
  async function signUp(username, password, fullName, role) {
    const res = await fetch(BASE + "/auth/v1/signup", {
      method: "POST",
      headers: { apikey: CFG.SUPABASE_ANON_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({
        email: toEmail(username), password: password,
        data: { username: String(username).trim().toLowerCase(), full_name: fullName || "", role: role || "alerts" }
      })
    });
    const j = await res.json().catch(() => ({}));
    if (!res.ok) {
      const err = new Error(j.error_description || j.msg || ("signup failed HTTP " + res.status));
      err.code = res.status;
      throw err;
    }
    return (j.user && j.user.id) || j.id || null;
  }

  /* ------------- token refresh ------------- */
  let refreshing = null;
  async function ensureToken() {
    const s = session();
    if (!s) return null;
    if (s.expires_at - 60 > Date.now() / 1000) return s.access_token;
    if (!refreshing) {
      refreshing = (async () => {
        try {
          const res = await fetch(BASE + "/auth/v1/token?grant_type=refresh_token", {
            method: "POST",
            headers: { apikey: CFG.SUPABASE_ANON_KEY, "Content-Type": "application/json" },
            body: JSON.stringify({ refresh_token: s.refresh_token })
          });
          if (!res.ok) throw new Error("refresh failed HTTP " + res.status);
          const j = await res.json();
          saveSession({
            access_token: j.access_token,
            refresh_token: j.refresh_token,
            expires_at: Math.floor(Date.now() / 1000) + (j.expires_in || 3600),
            user_id: (j.user && j.user.id) || s.user_id
          });
          return j.access_token;
        } catch (e) {
          toLogin();
          return null;
        } finally {
          refreshing = null;
        }
      })();
    }
    return refreshing;
  }

  /* ------------- profile & permissions ------------- */
  async function fetchProfile() {
    const s = session();
    if (!s || !s.user_id) return null;
    const res = await fetch(
      BASE + "/rest/v1/dash_users?user_id=eq." + encodeURIComponent(s.user_id) +
      "&select=user_id,username,full_name,role,pages,is_active,scope_user_ids",
      { headers: headers() });
    if (!res.ok) return null;
    const rows = await res.json().catch(() => null);
    const p = rows && rows[0] ? rows[0] : null;
    if (p) localStorage.setItem(PKEY, JSON.stringify(p));
    return p;
  }

  function canView(pageId, p) {
    p = p || profile();
    if (!p || !p.is_active) return false;
    const o = p.pages || {};
    if (typeof o[pageId] === "boolean") return o[pageId];
    const d = ROLE_DEFAULTS[p.role];
    return !!(d && d[pageId]);
  }

  function firstAllowed(p) {
    p = p || profile();
    for (let i = 0; i < PAGE_ORDER.length; i++) {
      if (canView(PAGE_ORDER[i], p)) return FILE_OF[PAGE_ORDER[i]];
    }
    return null;
  }

  /* ------------- traffic ping (fire and forget) ------------- */
  function logView(pageId) {
    const s = session(), p = profile();
    if (!s || !p) return;
    fetch(BASE + "/rest/v1/page_views", {
      method: "POST",
      headers: headers({ "Content-Type": "application/json", Prefer: "return=minimal" }),
      body: JSON.stringify({
        user_id: s.user_id, username: p.username, page: pageId,
        lang: localStorage.getItem("dash_lang") || CFG.DEFAULT_LANG,
        ua: String(navigator.userAgent || "").slice(0, 200)
      })
    }).catch(() => {});
  }

  /* ------------- redirects & guard ------------- */
  function redirect(url) {
    document.documentElement.style.visibility = "hidden";
    location.replace(url);
  }
  function toLogin() { clearAll(); redirect("/login"); }

  // Runs at parse time, before the page's own script:
  //  • no session → login page (synchronous, no content flash)
  //  • cached profile says "not allowed here" → first allowed page
  //  • then re-validates in the background so permission changes made in
  //    the admin panel take effect on the next page load.
  (function guard() {
    if (CURRENT === "login") {
      const p = profile();
      if (session() && p && p.is_active) {
        const fa = firstAllowed(p);
        if (fa) redirect(fa);
      }
      return;
    }
    if (!session()) { redirect("/login"); return; }
    const cached = profile();
    if (cached && !canView(CURRENT, cached)) {
      const fa = firstAllowed(cached);
      redirect(fa || "/login");
      return;
    }
    ensureToken().then(function (tok) {
      if (!tok) return; // ensureToken already redirected to login
      fetchProfile().then(function (fresh) {
        if (!fresh) { toLogin(); return; }
        if (!fresh.is_active) { toLogin(); return; }
        if (!canView(CURRENT, fresh)) { redirect(firstAllowed(fresh) || "/login"); return; }
        logView(CURRENT);
      });
    });
  })();

  /* ------------- expose ------------- */
  window.DASH_AUTH = {
    signIn: signIn, signOut: signOut, signUp: signUp,
    ensureToken: ensureToken, headers: headers,
    session: session, profile: profile, fetchProfile: fetchProfile,
    canView: canView, firstAllowed: firstAllowed, toEmail: toEmail,
    currentPage: function () { return CURRENT; },
    // The salesperson user_ids this login is scoped to, or null = full access.
    // RLS already filters the data; the UI uses this only for cosmetics
    // (a "Viewing: <reps>" banner, degrading snapshot-only widgets).
    scopeIds: function () {
      const p = profile();
      const a = p && p.scope_user_ids;
      return (Array.isArray(a) && a.length) ? a : null;
    },
    isScoped: function () { return this.scopeIds() != null; },
    ROLE_DEFAULTS: ROLE_DEFAULTS, PAGE_ORDER: PAGE_ORDER, FILE_OF: FILE_OF
  };
})();
