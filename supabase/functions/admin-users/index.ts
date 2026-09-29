/**
 * admin-users — the only place the service_role key is allowed to run.
 *
 * Creating a login and setting a password require Supabase's Admin API, which
 * requires the service_role key. That key bypasses RLS entirely, so it can
 * never reach the browser (see the warning in assets/js/config.js). This Edge
 * Function holds it server-side and refuses to act for anyone who is not an
 * administrator.
 *
 * THE CALLER IS NEVER TRUSTED ABOUT WHO THEY ARE.
 * Every request is authorised in two steps:
 *   1. the JWT in the Authorization header is verified against Supabase Auth,
 *      which yields a user id that cannot be forged;
 *   2. that id is looked up in app_users, and the request is rejected unless
 *      the row is active and its role is `admin`.
 * A field like `role` in the request body is ignored. It is only ever read
 * from the database.
 *
 * WHAT THIS FUNCTION DOES *NOT* DO
 * Role definitions (pages, hidden columns) are ordinary PostgREST writes,
 * guarded by admin-only RLS policies on app_roles. They need no elevated key,
 * so they are not routed through here. Only operations that genuinely require
 * service_role live in this file.
 *
 * Deploy:  supabase functions deploy admin-users
 * Secrets: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected by the
 *          platform. Nothing to configure by hand.
 */
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

const EMAIL_DOMAIN = '@dabboos.app';
const MIN_PASSWORD = 8;

/** Kept in step with app_roles.pages / app_roles.hidden_columns in 04_admin.sql. */
const VALID_PAGES = [
  'overview', 'products', 'status', 'returns', 'discounts', 'frozen', 'reorder', 'admin'
];
const VALID_COLUMNS = ['margin', 'cost', 'revenue', 'stock_value', 'customers'];

/**
 * Hideable tables. dashboard_excluded_products is deliberately absent: it is a
 * FILTER, so hiding it would let the invoice-discount lines back into every
 * product table and make numbers wrong rather than absent. Kept in step with
 * TABLES in perm.js and 07_tables_and_overrides.sql.
 */
const VALID_TABLES = [
  'dashboard_invoice_lines', 'dashboard_products', 'dashboard_stock',
  'dashboard_customers', 'dashboard_stock_history'
];

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' }
  });

const fail = (message: string, status = 400) => json({ error: message }, status);

/** A username must survive being turned into an email local part. */
function normaliseUsername(raw: unknown): string {
  const name = String(raw ?? '').trim().toLowerCase();
  if (!/^[a-z0-9._-]{2,32}$/.test(name)) {
    throw new Error(
      'Username must be 2–32 characters, using only a–z, 0–9, dot, underscore or hyphen'
    );
  }
  return name;
}

function checkPassword(raw: unknown): string {
  const pw = String(raw ?? '');
  if (pw.length < MIN_PASSWORD) {
    throw new Error(`Password must be at least ${MIN_PASSWORD} characters`);
  }
  return pw;
}

/**
 * Scope arrays: null means "everything", an empty array means "nothing".
 * The distinction is load-bearing (see 04_admin.sql), so `undefined`, `null`
 * and `[]` are NOT collapsed into one another here.
 */
function normaliseScope(v: unknown): string[] | null {
  if (v === null || v === undefined || v === '') return null;
  if (!Array.isArray(v)) throw new Error('Scope must be an array or null');
  const out = v.map(x => String(x).trim()).filter(Boolean);
  return out;
}

function normaliseList(v: unknown, valid: string[], label: string): string[] {
  if (!Array.isArray(v)) throw new Error(`${label} must be an array`);
  const out = [...new Set(v.map(x => String(x)))];
  const bad = out.filter(x => !valid.includes(x));
  if (bad.length) throw new Error(`Unknown ${label}: ${bad.join(', ')}`);
  return out;
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail('POST only', 405);

  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !serviceKey) return fail('Function is missing its Supabase credentials', 500);

  // service_role: bypasses RLS. Everything below must therefore do its own
  // authorisation — there is no database safety net on this client.
  const admin = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false }
  });

  // ---------------------------------------------------------------- authorise
  const authHeader = req.headers.get('Authorization') ?? '';
  const token = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!token) return fail('Not signed in', 401);

  const { data: caller, error: callerErr } = await admin.auth.getUser(token);
  if (callerErr || !caller?.user) return fail('Session expired — sign in again', 401);

  const { data: callerRow, error: rowErr } = await admin
    .from('app_users')
    .select('user_id, username, role_key, is_active')
    .eq('user_id', caller.user.id)
    .maybeSingle();

  if (rowErr) return fail(`Could not read caller permissions: ${rowErr.message}`, 500);
  if (!callerRow || !callerRow.is_active) {
    return fail('Account not provisioned — contact an administrator', 403);
  }
  if (callerRow.role_key !== 'admin') {
    return fail('Administrator access required', 403);
  }

  // ------------------------------------------------------------------ dispatch
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail('Request body must be JSON');
  }
  const action = String(body.action ?? '');

  try {
    switch (action) {
      // ---------------------------------------------------------------- list
      case 'list': {
        const { data: users, error } = await admin
          .from('app_users')
          .select('*')
          .order('username');
        if (error) throw new Error(error.message);

        // auth.users is not reachable through PostgREST, so email and the real
        // created_at have to come from the Admin API and be merged in.
        const { data: authList, error: authErr } =
          await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
        if (authErr) throw new Error(authErr.message);

        const byId = new Map(authList.users.map(u => [u.id, u]));
        return json({
          users: (users ?? []).map(u => ({
            ...u,
            email: byId.get(u.user_id)?.email ?? null,
            last_sign_in_at: byId.get(u.user_id)?.last_sign_in_at ?? null,
            // An auth.users row with no app_users row cannot appear here: the
            // list is driven by app_users. Orphans in the other direction are
            // reported below so they are not invisible.
            orphaned: !byId.has(u.user_id)
          }))
        });
      }

      // -------------------------------------------------------------- create
      case 'create': {
        const username = normaliseUsername(body.username);
        const password = checkPassword(body.password);
        const email = username + EMAIL_DOMAIN;
        const roleKey = String(body.role_key ?? 'management');

        const { data: role } = await admin
          .from('app_roles').select('role_key').eq('role_key', roleKey).maybeSingle();
        if (!role) throw new Error(`No such role: ${roleKey}`);

        // email_confirm: the @dabboos.app addresses are synthetic and receive
        // no mail, so there is no confirmation link anyone could ever click.
        const { data: created, error: createErr } = await admin.auth.admin.createUser({
          email, password, email_confirm: true,
          user_metadata: { display_name: String(body.display_name ?? username) }
        });
        if (createErr) throw new Error(createErr.message);

        const { error: insErr } = await admin.from('app_users').insert({
          user_id: created.user.id,
          username,
          display_name: String(body.display_name ?? username),
          role_key: roleKey,
          scope_salespersons: normaliseScope(body.scope_salespersons),
          scope_govs: normaliseScope(body.scope_govs),
          is_active: body.is_active === false ? false : true
        });

        if (insErr) {
          // Roll the auth user back. Without this a failed insert leaves a
          // login that exists but is unprovisioned — it can authenticate and
          // then see nothing, which reads as a broken dashboard.
          await admin.auth.admin.deleteUser(created.user.id);
          throw new Error(insErr.message);
        }

        return json({ ok: true, user_id: created.user.id, username });
      }

      // -------------------------------------------------------------- update
      case 'update': {
        const userId = String(body.user_id ?? '');
        if (!userId) throw new Error('user_id is required');

        const patch: Record<string, unknown> = {};
        if (body.display_name !== undefined) patch.display_name = String(body.display_name);
        if (body.role_key !== undefined) patch.role_key = String(body.role_key);
        if (body.is_active !== undefined) patch.is_active = Boolean(body.is_active);
        if ('scope_salespersons' in body) {
          patch.scope_salespersons = normaliseScope(body.scope_salespersons);
        }
        if ('scope_govs' in body) patch.scope_govs = normaliseScope(body.scope_govs);

        // Subtractive only — app_me() computes effective pages as the role's
        // list MINUS this one, so a denial can never grant access the role
        // lacks. Validated against VALID_PAGES so a typo cannot silently deny
        // nothing at all.
        if ('pages_denied' in body) {
          patch.pages_denied = body.pages_denied === null
            ? null
            : normaliseList(body.pages_denied, VALID_PAGES, 'pages');
        }

        // A username change is really an email change, so both sides move together.
        if (body.username !== undefined) {
          const username = normaliseUsername(body.username);
          patch.username = username;
          const { error: mailErr } = await admin.auth.admin.updateUserById(userId, {
            email: username + EMAIL_DOMAIN, email_confirm: true
          });
          if (mailErr) throw new Error(mailErr.message);
        }

        if (!Object.keys(patch).length) return json({ ok: true, unchanged: true });

        // The last-admin trigger in 04_admin.sql raises here if this demotes or
        // deactivates the only remaining administrator.
        const { error } = await admin.from('app_users').update(patch).eq('user_id', userId);
        if (error) throw new Error(error.message);
        return json({ ok: true });
      }

      // -------------------------------------------------------- set_password
      case 'set_password': {
        const userId = String(body.user_id ?? '');
        if (!userId) throw new Error('user_id is required');
        const password = checkPassword(body.password);
        const { error } = await admin.auth.admin.updateUserById(userId, { password });
        if (error) throw new Error(error.message);
        return json({ ok: true });
      }

      // -------------------------------------------------------------- delete
      case 'delete': {
        const userId = String(body.user_id ?? '');
        if (!userId) throw new Error('user_id is required');
        if (userId === callerRow.user_id) {
          throw new Error('You cannot delete your own account');
        }
        // app_users cascades from auth.users, and its delete trigger refuses
        // to remove the last administrator — so that check happens in the
        // database, not here.
        const { error } = await admin.auth.admin.deleteUser(userId);
        if (error) throw new Error(error.message);
        return json({ ok: true });
      }

      // ------------------------------------------------------- validate_role
      // Roles are written straight to PostgREST by the admin page; this is
      // offered so the page can check page/column keys against the same list
      // the server uses rather than keeping a second copy in sync by hand.
      case 'role_vocabulary':
        return json({ pages: VALID_PAGES, columns: VALID_COLUMNS, tables: VALID_TABLES });

      case 'validate_role': {
        return json({
          ok: true,
          pages: normaliseList(body.pages, VALID_PAGES, 'pages'),
          hidden_columns: normaliseList(body.hidden_columns, VALID_COLUMNS, 'columns'),
          hidden_tables: normaliseList(body.hidden_tables ?? [], VALID_TABLES, 'tables')
        });
      }

      default:
        return fail(`Unknown action: ${action || '(none)'}`);
    }
  } catch (e) {
    return fail(e instanceof Error ? e.message : String(e));
  }
});
