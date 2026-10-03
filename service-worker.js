/* ============================================================
   Dabboos Sales Command Center — service worker (PWA)
   Keep VERSION in sync with the ?v=NN cache-buster in the HTML
   files: bumping it here drops every old cache on next visit.

   Strategy:
     - Supabase (data + auth)  -> NEVER intercepted. Numbers must be live.
     - Same-origin app shell   -> network-first, cache fallback (offline).
     - CDN assets (Chart.js)   -> cache-first (URLs are versioned).
   ============================================================ */
const VERSION = "v82";
const CACHE = "dabboos-" + VERSION;

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => k.startsWith("dabboos-") && k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);

  // The dashboard's whole point is trustworthy live numbers — data and
  // auth calls go straight to the network, always.
  if (url.hostname.endsWith(".supabase.co")) return;

  if (url.origin === location.origin) {
    e.respondWith(
      fetch(req)
        .then(res => {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
          return res;
        })
        .catch(() =>
          caches.match(req).then(m => m || (req.mode === "navigate" ? caches.match("/") : undefined)))
    );
  } else {
    e.respondWith(
      caches.match(req).then(m => m || fetch(req).then(res => {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
        return res;
      }))
    );
  }
});
