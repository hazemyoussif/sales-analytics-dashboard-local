/* ============================================================
   Dabboos Sales Command Center — Node.js server
   ------------------------------------------------------------
   This dashboard is a STATIC app: plain HTML + vanilla JS that reads
   Supabase directly from the browser (Odoo → n8n → Supabase → browser).
   This server does ONE job: hand those files to browsers over HTTP.

   It holds no secrets and connects to no database. The Supabase URL +
   public anon key live in assets/js/config.js (safe to expose — Row-Level
   Security protects the data). n8n and Supabase run separately and are not
   part of this process — see DEPLOYMENT.md.

   Run:  npm install  &&  npm start        (listens on PORT, default 3000)
   ============================================================ */
const express = require("express");
const path = require("path");

const app = express();
const ROOT = __dirname;
const PORT = process.env.PORT || 3000;

// Health check for load balancers / uptime monitors.
app.get("/healthz", (_req, res) => res.type("text").send("ok"));

// Serve the app.
//  • extensions: ["html"] gives the same CLEAN URLs as the Vercel setup:
//    /regions → regions.html, /admin → admin.html, / → index.html.
//  • the service worker and config are served with no-cache so clients always
//    pick up the current version (the app relies on fresh code + live data).
app.use(express.static(ROOT, {
  extensions: ["html"],
  setHeaders(res, filePath) {
    const base = path.basename(filePath);
    if (base === "service-worker.js" || base === "config.js") {
      res.setHeader("Cache-Control", "no-cache");
    }
  }
}));

// Unknown path → send the Overview (its auth guard then routes correctly).
app.use((_req, res) => res.sendFile(path.join(ROOT, "index.html")));

app.listen(PORT, () => {
  console.log("Dabboos dashboard listening on http://localhost:" + PORT);
});
