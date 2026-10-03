# Authentication, permissions & the admin panel

Added 2026-07. The dashboard is now behind a username/password gate backed by
**Supabase Auth + Row-Level Security (RLS)**. The static site still has no
server — the browser talks straight to Supabase, but every request carries the
logged-in user's JWT, and **the database decides what that user may read**.
Hiding pages in the UI is convenience; RLS is the enforcement.

## Roles

| Role         | Sees                                                                     |
|--------------|--------------------------------------------------------------------------|
| `admin`      | every page **plus** the admin panel (`admin.html`)                       |
| `management` | every dashboard page (Overview, Regions, Salespeople, Collections, Debt, Alerts) |
| `alerts`     | Alert Center only — and the DB itself only serves them order rows whose `level` is `critical`/`warning`, nothing else |

Per-user **page overrides** (the checkboxes in the admin panel) are stored in
`dash_users.pages` (jsonb) and override the role defaults page by page.
Role defaults live in `assets/js/auth.js` (`ROLE_DEFAULTS`).

Note the honest boundary: which *rows/tables* a user can read is enforced by
RLS per **role**. The per-page checkboxes are a UI-level convenience on top —
a technically skilled `management` user could still query any management-
visible table directly. Don't use page checkboxes as a data-security control;
use the role for that.

## One-time setup (in order!)

1. **Deploy the code** (this repo) to Vercel first.
2. Supabase Dashboard → **Authentication → Sign In / Providers**:
   - "Allow new users to sign up" = **ON** (the admin panel creates users
     through the signup endpoint; self-signups are harmless because they start
     **inactive** and see nothing until an admin activates them).
   - "Confirm email" = **OFF** (usernames map to synthetic `@dabboos.app`
     addresses; there is no mailbox to receive a confirmation).
3. Supabase Dashboard → **SQL Editor** → run `supabase/auth-setup.sql`.
   ⚠️ From this moment the anon key alone reads **nothing** — old clients and
   any bookmarked pre-auth version stop showing data. That is intended.
4. Create your own admin account:
   - Authentication → Users → **Add user**: email `ahmed@dabboos.app`,
     a strong password, ✔ Auto Confirm.
   - SQL Editor:
     ```sql
     update public.dash_users
     set role = 'admin', is_active = true, full_name = 'Ahmed Gomma'
     where username = 'ahmed';
     ```
5. Open the site → you land on `login.html` → sign in as `ahmed`.
   Create everyone else from the **admin panel**.

## How login works (no SDK, plain REST)

- Usernames are mapped to synthetic emails: `ahmed` → `ahmed@dabboos.app`
  (`EMAIL_DOMAIN` in `assets/js/auth.js`).
- `auth.js` calls GoTrue directly: `POST /auth/v1/token?grant_type=password`,
  stores `{access_token, refresh_token}` in `localStorage`, refreshes the token
  automatically before expiry, and loads the user's `dash_users` profile.
- Every PostgREST call sends `apikey: <anon>` + `Authorization: Bearer <user JWT>`
  (see `authHeaders()` in `common.js`), so RLS sees who is asking.
- `auth.js` **must load after `config.js` and before `common.js`** on every
  page. Its guard runs at parse time: no session → `login.html`; page not
  permitted → redirect to the user's first allowed page. It re-fetches the
  profile in the background so permission changes apply on the next page load.
- Log out: the ⏻ button in the header.

## The admin panel (`admin.html`)

- **Create user** — username / full name / password / role. Uses the signup
  endpoint; the DB trigger creates the profile *inactive*, and the panel
  immediately activates it.
- **Users table** — change full name, role, per-page checkboxes, active flag.
  Deactivating (`is_active = false`) is the practical "delete": the account
  keeps its login but every RLS policy returns nothing.
  You cannot suspend or demote **yourself** from the UI (self row is locked)
  so you can't lock yourself out.
- **Password reset / real deletion** need the `service_role` key, which never
  goes in the browser — do those in Supabase Dashboard → Authentication →
  Users. Or just suspend the account and create a new one.
- **Traffic** — every page load inserts a row into `page_views` (user, page,
  language, user-agent, time). The panel shows views today / 7 days / active
  users, a 30-day per-day chart, breakdowns by page and by user, and the most
  recent visits. Only admins can read this table.

## Tables added by `supabase/auth-setup.sql`

- `dash_users` — profile per login: `username`, `full_name`, `role`,
  `pages` (jsonb overrides), `is_active`. Auto-created by a trigger on
  `auth.users`; **new rows are always inactive**.
- `page_views` — traffic log (insert: any active user; select: admin only).
- Adds `acked_by` / `acked_by_name` to `alert_acks`, so acknowledgements are
  no longer anonymous.

## PWA ("install like an app")

- `manifest.webmanifest` + `service-worker.js` + icons in `assets/icons/`
  make the dashboard installable: Android/Chrome shows an **Install app**
  prompt (menu → *Add to home screen*), iOS Safari → Share → *Add to Home
  Screen*. It opens standalone, full-screen, with the DB icon.
- The service worker **never caches Supabase requests** — data and auth are
  always live (golden rule: trustworthy numbers). Same-origin files are
  network-first with cache fallback; CDN assets are cache-first.
- When you bump the `?v=NN` cache-buster in the HTML files, also bump
  `VERSION` in `service-worker.js` so installed clients drop old caches.
- PWA install requires HTTPS — Vercel provides it; `localhost` works for dev.
