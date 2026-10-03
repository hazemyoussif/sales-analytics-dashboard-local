# Deployment guide — Dabboos Sales Command Center

This document is for whoever installs the dashboard on a server.

## What this project is

A **web dashboard** (Node.js + static HTML/JS) that shows Dabboos' sales
analytics in Arabic and English. It is a **front-end only**: the browser reads
data directly from a cloud database (Supabase). This server's only job is to
serve the dashboard files to browsers.

**You do not need to set up a database, and you do not need to run Odoo or n8n.**
Those already run separately (see the architecture below).

## Architecture — how the pieces fit

```
   Odoo            n8n              Supabase              This dashboard
 (the ERP)  ──►  (sync engine) ──►  (cloud database) ◄────  (browser)
                                          ▲                     │
                                          └─────────────────────┘
                                   the browser reads data directly
```

| Piece | What it does | Where it runs | Your responsibility? |
|-------|--------------|---------------|----------------------|
| **Odoo** | Source ERP (sales, invoices, payments) | Company's existing Odoo | No |
| **n8n** | Every ~20 min, copies Odoo data into Supabase | Already on a server | No |
| **Supabase** | Cloud database the dashboard reads | Cloud (`*.supabase.co`) | No |
| **This dashboard** | The web UI | **The server you are setting up** | **Yes — this repo only** |

Key point: **this server holds no secrets and connects to no database.** Each
user's browser talks to Supabase directly, secured by a public "anon" key plus
database Row-Level Security. Moving the dashboard to a new server does not affect
Odoo, n8n, or Supabase.

## Requirements

- **Node.js 18 or newer** (`node -v` to check), **or** Docker.
- Outbound internet access **for end-user browsers** to reach `*.supabase.co`.
  (The server itself needs no special access — it only serves files.)

## Run it — pick one

### Option A — plain Node.js
```bash
npm install
npm start
```
The dashboard is now on `http://<server>:3000` (change with `PORT=8080 npm start`).

To keep it running after logout / on reboot, use a process manager, e.g. **pm2**:
```bash
npm install -g pm2
pm2 start server.js --name dabboos-dashboard
pm2 save && pm2 startup
```
…or a `systemd` service that runs `npm start` in this folder.

### Option B — Docker
```bash
docker build -t dabboos-dashboard .
docker run -d --restart unless-stopped -p 80:3000 --name dabboos-dashboard dabboos-dashboard
```
The dashboard is now on `http://<server>` (host port 80 → container port 3000).

### Option C — managed platform (Render / Railway / Azure App Service, …)
Connect this GitHub repo. Build command: `npm install`. Start command: `npm start`.
The platform provides the port via the `PORT` environment variable, which the
server already reads.

## Put it behind HTTPS + your domain (recommended)

Run the app on an internal port (e.g. 3000) and let **nginx** terminate HTTPS and
proxy to it:

```nginx
server {
    listen 443 ssl;
    server_name dashboard.yourcompany.com;

    ssl_certificate     /etc/ssl/certs/your.crt;
    ssl_certificate_key /etc/ssl/private/your.key;

    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_set_header   Host $host;
        proxy_set_header   X-Forwarded-For $remote_addr;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
```

## Configuration

There are **no environment secrets to set.** The Supabase connection lives in
[`assets/js/config.js`](assets/js/config.js):

- `SUPABASE_URL` — the Supabase project URL.
- `SUPABASE_ANON_KEY` — the **public** anon key. Safe to expose: on its own it
  reads nothing; every read requires a logged-in user and passes Row-Level
  Security. (The private `service_role` key is **never** here — it lives only in
  n8n.)

Only change these if you are pointing the dashboard at a different Supabase
project. `PORT` (default 3000) is the only server setting.

## Verifying it works

1. Open the site — the login page should appear.
2. Sign in with a dashboard user; the Overview loads with live numbers.
3. Clean URLs work: `/regions`, `/admin`, etc. load without a `.html` extension.
4. `GET /healthz` returns `ok` (useful for a load-balancer health check).

## Notes

- The `supabase/*.sql` files are one-time database setup scripts that have
  already been applied. They are kept for reference; you do not run them to
  deploy the dashboard.
- `vercel.json` is only used if the project is hosted on Vercel; it is ignored
  when running under Node.js/Docker. It does no harm either way.
- The dashboard is a PWA (installable, offline shell) via `service-worker.js`;
  the server sends that file with `no-cache` so updates roll out immediately.
