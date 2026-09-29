/**
 * Administration — users, roles and activity.
 *
 * Reaching this page requires the `admin` page in your role, which requireAuth()
 * checks. That check is convenience: every write below is re-authorised by the
 * server. The admin-users Edge Function looks the caller up in app_users and
 * returns 403 for anyone who is not an admin, and app_roles has admin-only RLS
 * policies. Editing this file in devtools buys nothing.
 */
import {
  adminUsers, listRoles, createRole, updateRole, deleteRole,
  listActivity, filterOptions, clearMeCache, AuthError
} from '../api.js';
import { esc } from '../format.js';
import {
  requireAuth, mountShell, showError, showLoading, T, applyLang, lang
} from '../shell.js';
import {
  PAGES, MASKABLE_COLUMNS, TABLES, validateRole, tableWarnings,
  scopeSummary, isScoped
} from '../perm.js';

const $ = id => document.getElementById(id);

const state = {
  tab: 'users',
  users: [],
  roles: [],
  options: { salesperson: [], gov: [] },
  editingUser: null,     // user_id, or 'new'
  editingRole: null      // role_key, or 'new'
};

// -------------------------------------------------------------------- helpers
function notice(msg, kind = 'ok') {
  $('notice').innerHTML = msg
    ? `<div class="state ${kind === 'err' ? 'error' : ''}">${esc(msg)}</div>`
    : '';
  if (msg && kind === 'ok') setTimeout(() => { $('notice').innerHTML = ''; }, 2500);
}

/** Every write goes through here so no failure can be silent. */
async function run(fn, okMessage) {
  try {
    notice('');
    await fn();
    await load();
    render();
    if (okMessage) notice(okMessage);
  } catch (err) {
    console.error(err);
    if (err instanceof AuthError) { location.reload(); return; }
    notice(err?.detail || err?.message || String(err), 'err');
  }
}

const EDIT = () => (lang() === 'ar' ? 'تعديل' : 'Edit');

/**
 * Scope editor. NULL and [] are different answers and the UI has to be able to
 * express both: the checkbox means "everything" (NULL), an unchecked box with
 * nothing selected means "nothing" ([]). Collapsing them would make it
 * impossible to create a user who is deliberately shown no data.
 */
function scopeField(id, label, values, selected, allLabel) {
  const isAll = selected === null || selected === undefined;
  return `
    <div class="field" style="min-width:220px">
      <label>${esc(label)}</label>
      <label style="font-size:12px;display:flex;gap:6px;align-items:center">
        <input type="checkbox" id="${id}-all" ${isAll ? 'checked' : ''}>
        ${esc(allLabel)}
      </label>
      <select id="${id}" multiple size="6" ${isAll ? 'disabled' : ''}
              style="min-width:220px">
        ${values.map(v => `<option value="${esc(v)}"
           ${!isAll && selected.includes(v) ? 'selected' : ''}>${esc(v)}</option>`).join('')}
      </select>
    </div>`;
}

function readScope(id) {
  if ($(`${id}-all`).checked) return null;
  return [...$(id).selectedOptions].map(o => o.value);
}

function wireScope(id) {
  $(`${id}-all`).onchange = e => { $(id).disabled = e.target.checked; };
}

function checkboxList(id, items, selected, labels = {}) {
  return `<div style="display:flex;flex-wrap:wrap;gap:10px">
    ${items.map(k => `<label style="font-size:13px;display:flex;gap:5px;align-items:center">
      <input type="checkbox" name="${id}" value="${esc(k)}"
        ${selected.includes(k) ? 'checked' : ''}>${esc(labels[k] || k)}</label>`).join('')}
  </div>`;
}

const readCheckboxes = name =>
  [...document.querySelectorAll(`input[name="${name}"]:checked`)].map(i => i.value);

// ---------------------------------------------------------------------- users
function usersPanel() {
  const L = T().admin;
  const l = lang();

  const rows = state.users.map(u => {
    const role = state.roles.find(r => r.role_key === u.role_key);
    return `<tr>
      <td>${esc(u.username)}${u.is_active ? '' : ' <span class="chip dead">off</span>'}</td>
      <td>${esc(u.display_name || '—')}</td>
      <td>${esc(role ? (l === 'ar' ? role.name_ar : role.name_en) : u.role_key)}</td>
      <td>
        ${isScoped(u) ? esc(scopeSummary(u, l)) : `<span class="chip healthy">${esc(l === 'ar' ? 'الكل' : 'all')}</span>`}
        ${(u.pages_denied || []).length
          ? `<br><span class="sub">${esc(L.deniedPages)}:</span> ` +
            u.pages_denied.map(p => `<span class="chip dead">${esc(T().nav[p] || p)}</span>`).join(' ')
          : ''}
      </td>
      <td class="n">${esc(u.last_seen_at ? u.last_seen_at.slice(0, 16).replace('T', ' ') : '—')}</td>
      <td>
        <button class="btn" data-edit-user="${esc(u.user_id)}">${esc(EDIT())}</button>
        <button class="btn" data-pw-user="${esc(u.user_id)}">${esc(L.setPassword)}</button>
        <button class="btn" data-del-user="${esc(u.user_id)}">${esc(L.del)}</button>
      </td>
    </tr>`;
  }).join('');

  return `
    <div class="card">
      <h2>${esc(L.users)}</h2>
      <p class="sub">${esc(L.scopeHelp)}</p>
      <button class="btn primary" id="new-user">${esc(L.newUser)}</button>
      <div id="user-form"></div>
      <div class="table-wrap" style="margin-top:14px"><table>
        <thead><tr>
          <th>${esc(L.username)}</th><th>${esc(L.displayName)}</th><th>${esc(L.role)}</th>
          <th>${esc(L.scope)}</th><th class="n">${esc(L.lastSeen)}</th><th>${esc(L.actions)}</th>
        </tr></thead>
        <tbody>${rows || `<tr><td colspan="6" class="state">—</td></tr>`}</tbody>
      </table></div>
    </div>`;
}

function userForm(user) {
  const L = T().admin;
  const isNew = !user;
  const u = user || {
    username: '', display_name: '', role_key: 'management',
    scope_salespersons: null, scope_govs: null, is_active: true
  };

  return `<div class="card" style="margin-top:14px" id="uf">
    <h2>${esc(isNew ? L.newUser : u.username)}</h2>
    <div class="filters">
      <div class="field"><label>${esc(L.username)}</label>
        <input id="uf-username" value="${esc(u.username)}" autocomplete="off"></div>
      <div class="field"><label>${esc(L.displayName)}</label>
        <input id="uf-display" value="${esc(u.display_name || '')}" autocomplete="off"></div>
      ${isNew ? `<div class="field"><label>${esc(L.password)}</label>
        <input id="uf-password" type="password" autocomplete="new-password"></div>` : ''}
      <div class="field"><label>${esc(L.role)}</label>
        <select id="uf-role">
          ${state.roles.map(r => `<option value="${esc(r.role_key)}"
            ${r.role_key === u.role_key ? 'selected' : ''}>${esc(r.name_en)} · ${esc(r.name_ar)}</option>`).join('')}
        </select></div>
      <div class="field"><label>${esc(L.active)}</label>
        <select id="uf-active">
          <option value="1" ${u.is_active ? 'selected' : ''}>✓</option>
          <option value="0" ${u.is_active ? '' : 'selected'}>✕</option>
        </select></div>
    </div>
    <div class="filters">
      ${scopeField('uf-reps', T().rep, state.options.salesperson, u.scope_salespersons, L.allReps)}
      ${scopeField('uf-govs', T().gov, state.options.gov, u.scope_govs, L.allGovs)}
    </div>
    <div class="field" style="margin-bottom:12px">
      <label>${esc(L.deniedPages)}</label>
      <p class="sub" style="margin:0 0 8px">${esc(L.deniedHelp)}</p>
      ${deniedPagesList(u)}
    </div>
    <button class="btn primary" id="uf-save">${esc(L.save)}</button>
    <button class="btn" id="uf-cancel">${esc(L.cancel)}</button>
  </div>`;
}

/**
 * Per-user page denials, offered only for pages the ROLE actually grants.
 *
 * Listing pages the role never had would imply ticking one changes something,
 * and would suggest an override could grant access. It cannot: app_me()
 * computes effective pages as role.pages minus this list, so the role is
 * always an upper bound.
 */
function deniedPagesList(u) {
  const role = state.roles.find(r => r.role_key === u.role_key);
  const grantable = role?.pages || [];
  const denied = u.pages_denied || [];
  if (!grantable.length) {
    return `<span class="sub">${esc(T().noPages)}</span>`;
  }
  return checkboxList('uf-denied', grantable, denied, T().nav);
}

function wireUsers() {
  const L = T().admin;

  $('new-user').onclick = () => { state.editingUser = 'new'; render(); };

  document.querySelectorAll('[data-edit-user]').forEach(b =>
    b.onclick = () => { state.editingUser = b.dataset.editUser; render(); });

  document.querySelectorAll('[data-del-user]').forEach(b => b.onclick = () => {
    const u = state.users.find(x => x.user_id === b.dataset.delUser);
    if (!confirm(`${L.confirmDelete}\n\n${u?.username || ''}`)) return;
    run(() => adminUsers('delete', { user_id: b.dataset.delUser }), L.saved);
  });

  document.querySelectorAll('[data-pw-user]').forEach(b => b.onclick = () => {
    const u = state.users.find(x => x.user_id === b.dataset.pwUser);
    const pw = prompt(`${L.setPassword} — ${u?.username || ''}`);
    if (!pw) return;
    run(() => adminUsers('set_password', { user_id: b.dataset.pwUser, password: pw }), L.saved);
  });

  if (!state.editingUser) return;

  const editing = state.editingUser === 'new'
    ? null
    : state.users.find(u => u.user_id === state.editingUser);
  $('user-form').innerHTML = userForm(editing);
  wireScope('uf-reps');
  wireScope('uf-govs');

  $('uf-cancel').onclick = () => { state.editingUser = null; render(); };

  $('uf-save').onclick = () => {
    const payload = {
      username: $('uf-username').value.trim(),
      display_name: $('uf-display').value.trim(),
      role_key: $('uf-role').value,
      is_active: $('uf-active').value === '1',
      scope_salespersons: readScope('uf-reps'),
      scope_govs: readScope('uf-govs'),
      pages_denied: readCheckboxes('uf-denied')
    };
    const isNew = state.editingUser === 'new';
    if (isNew) payload.password = $('uf-password').value;

    run(async () => {
      await adminUsers(isNew ? 'create' : 'update',
        isNew ? payload : { user_id: state.editingUser, ...payload });
      state.editingUser = null;
      // An admin who edits their own role or scope is holding a stale copy of
      // their own permissions until this is dropped.
      clearMeCache();
    }, L.saved);
  };
}

// ---------------------------------------------------------------------- roles
function rolesPanel() {
  const L = T().admin;
  const l = lang();
  const navLabels = T().nav;

  const rows = state.roles.map(r => `<tr>
    <td>${esc(r.role_key)}${r.is_system ? ` <span class="chip">${esc(L.systemRole)}</span>` : ''}</td>
    <td>${esc(l === 'ar' ? r.name_ar : r.name_en)}</td>
    <td>${r.pages.map(p => `<span class="chip">${esc(navLabels[p] || p)}</span>`).join(' ')}</td>
    <td>${r.hidden_columns.length
          ? r.hidden_columns.map(c => `<span class="chip dead">${esc(L.cols[c] || c)}</span>`).join(' ')
          : '—'}</td>
    <td>${(r.hidden_tables || []).length
          ? (r.hidden_tables || []).map(k => {
              const t = TABLES.find(x => x.key === k);
              const cls = t?.risk === 'blackout' ? 'dead' : 'under';
              return `<span class="chip ${cls}">${esc(t ? (l === 'ar' ? t.ar : t.en) : k)}</span>`;
            }).join(' ')
          : '—'}</td>
    <td class="n">${esc(String(state.users.filter(u => u.role_key === r.role_key).length))}</td>
    <td>
      <button class="btn" data-edit-role="${esc(r.role_key)}">${esc(EDIT())}</button>
      ${r.is_system ? '' : `<button class="btn" data-del-role="${esc(r.role_key)}">${esc(L.del)}</button>`}
    </td>
  </tr>`).join('');

  return `
    <div class="card">
      <h2>${esc(L.roles)}</h2>
      <p class="sub">${esc(l === 'ar'
        ? 'الدور يحدد الصفحات والأعمدة. النطاق (المندوبون والمحافظات) يُضبط لكل مستخدم على حدة.'
        : 'A role sets pages and hidden columns. Scope — salespersons and governorates — is set per user.')}</p>
      <button class="btn primary" id="new-role">${esc(L.newRole)}</button>
      <div id="role-form"></div>
      <div class="table-wrap" style="margin-top:14px"><table>
        <thead><tr>
          <th>${esc(L.roleKey)}</th><th>${esc(L.role)}</th><th>${esc(L.pages)}</th>
          <th>${esc(L.hiddenCols)}</th><th>${esc(L.hiddenTables)}</th>
          <th class="n">${esc(L.users)}</th><th>${esc(L.actions)}</th>
        </tr></thead>
        <tbody>${rows}</tbody>
      </table></div>
    </div>`;
}

function roleForm(role) {
  const L = T().admin;
  const isNew = !role;
  const r = role || { role_key: '', name_ar: '', name_en: '',
                      pages: ['overview'], hidden_columns: [], is_system: false };

  return `<div class="card" style="margin-top:14px">
    <h2>${esc(isNew ? L.newRole : r.role_key)}</h2>
    <div class="filters">
      <div class="field"><label>${esc(L.roleKey)}</label>
        <input id="rf-key" value="${esc(r.role_key)}" ${isNew ? '' : 'disabled'}
               placeholder="sales_rep" autocomplete="off"></div>
      <div class="field"><label>${esc(L.nameAr)}</label>
        <input id="rf-ar" value="${esc(r.name_ar)}" autocomplete="off"></div>
      <div class="field"><label>${esc(L.nameEn)}</label>
        <input id="rf-en" value="${esc(r.name_en)}" autocomplete="off"></div>
    </div>
    <div class="field" style="margin-bottom:12px">
      <label>${esc(L.pages)}</label>
      ${checkboxList('rf-pages', PAGES.map(p => p.key), r.pages, T().nav)}
    </div>
    <div class="field" style="margin-bottom:12px">
      <label>${esc(L.hiddenCols)}</label>
      ${checkboxList('rf-cols', MASKABLE_COLUMNS, r.hidden_columns, L.cols)}
    </div>
    <div class="field" style="margin-bottom:12px">
      <label>${esc(L.hiddenTables)}</label>
      <p class="sub" style="margin:0 0 8px">${esc(L.tablesHelp)}</p>
      ${tableCheckboxes(r.hidden_tables || [])}
    </div>
    <div id="rf-warn"></div>
    <button class="btn primary" id="rf-save">${esc(L.save)}</button>
    <button class="btn" id="rf-cancel">${esc(L.cancel)}</button>
  </div>`;
}

/**
 * Table toggles, each labelled with its real Supabase name and what breaks.
 * The risk chip is the whole point: a flat list of checkboxes would let
 * someone blank a role's dashboard without ever being told that is what the
 * click does.
 */
function tableCheckboxes(hidden) {
  const L = T().admin;
  const l = lang();
  const nav = T().nav;
  return `<div style="display:flex;flex-direction:column;gap:8px">
    ${TABLES.map(t => {
      const cls = t.risk === 'blackout' ? 'dead' : t.risk === 'degrade' ? 'under' : '';
      const feeds = t.pages.length
        ? t.pages.map(p => nav[p] || p).join(' · ')
        : L.noPageUse;
      return `<label style="display:flex;gap:8px;align-items:flex-start;font-size:13px">
        <input type="checkbox" name="rf-tables" value="${esc(t.key)}"
               data-risk="${esc(t.risk)}" ${hidden.includes(t.key) ? 'checked' : ''}
               style="margin-top:3px">
        <span>
          <b>${esc(l === 'ar' ? t.ar : t.en)}</b>
          <span class="chip ${cls}">${esc(L.risk[t.risk])}</span><br>
          <span class="sub" style="font-family:monospace;font-size:11.5px">${esc(t.key)}</span><br>
          <span class="sub">${esc(l === 'ar' ? t.providesAr : t.providesEn)}</span><br>
          <span class="sub">${esc(L.feeds)}: ${esc(feeds)}</span>
        </span>
      </label>`;
    }).join('')}
  </div>`;
}

function wireRoles() {
  const L = T().admin;

  $('new-role').onclick = () => { state.editingRole = 'new'; render(); };

  document.querySelectorAll('[data-edit-role]').forEach(b =>
    b.onclick = () => { state.editingRole = b.dataset.editRole; render(); });

  document.querySelectorAll('[data-del-role]').forEach(b => b.onclick = () => {
    const key = b.dataset.delRole;
    const inUse = state.users.filter(u => u.role_key === key).length;
    if (inUse) {
      notice(`${key}: ${inUse} user(s) still have this role — move them first`, 'err');
      return;
    }
    if (!confirm(`${L.confirmDelete}\n\n${key}`)) return;
    run(() => deleteRole(key), L.saved);
  });

  if (!state.editingRole) return;

  const editing = state.editingRole === 'new'
    ? null
    : state.roles.find(r => r.role_key === state.editingRole);
  $('role-form').innerHTML = roleForm(editing);

  $('rf-cancel').onclick = () => { state.editingRole = null; render(); };

  // Live consequence preview: tick dashboard_products and the warning appears
  // immediately, not after saving and wondering why the dashboard went blank.
  const paintWarnings = () => {
    const warns = tableWarnings({ hidden_tables: readCheckboxes('rf-tables') }, lang());
    $('rf-warn').innerHTML = warns.length
      ? `<div class="state error" style="text-align:start">
           ${warns.map(w => `<div>⚠ ${esc(w.text)}</div>`).join('')}
         </div>`
      : '';
  };
  document.querySelectorAll('input[name="rf-tables"]')
    .forEach(cb => cb.onchange = paintWarnings);
  paintWarnings();

  $('rf-save').onclick = () => {
    const isNew = state.editingRole === 'new';
    const hiddenTables = readCheckboxes('rf-tables');
    const role = {
      role_key: isNew ? $('rf-key').value.trim() : state.editingRole,
      name_ar: $('rf-ar').value.trim(),
      name_en: $('rf-en').value.trim(),
      pages: readCheckboxes('rf-pages'),
      hidden_columns: readCheckboxes('rf-cols'),
      hidden_tables: hiddenTables,
      is_system: Boolean(editing?.is_system)
    };

    // A blackout is allowed but never accidental.
    const blackout = tableWarnings(role, lang()).filter(w => w.risk === 'blackout');
    if (blackout.length && !confirm(`${T().admin.confirmBlackout}\n\n${blackout.map(w => w.text).join('\n')}`)) {
      return;
    }

    // Validate before the round trip, so the admin reads a sentence rather
    // than a Postgres exception. The database enforces the same rules anyway.
    const errors = validateRole(role, {
      existingKeys: isNew ? state.roles.map(r => r.role_key) : []
    });
    if (errors.length) { notice(errors.join(' · '), 'err'); return; }

    run(async () => {
      if (isNew) await createRole(role);
      else {
        const { role_key, is_system, ...patch } = role;
        await updateRole(role_key, patch);
      }
      state.editingRole = null;
      clearMeCache();
    }, L.saved);
  };
}

// --------------------------------------------------------------------- tables
/**
 * A read-only map of the Supabase tables, what each feeds, and which roles
 * have switched it off. Roles are still edited on the Roles tab — this exists
 * so "which roles cannot see stock?" is answerable by looking, rather than by
 * opening five role forms in turn.
 */
function tablesPanel() {
  const L = T().admin;
  const l = lang();
  const nav = T().nav;

  const rows = TABLES.map(t => {
    const hiders = state.roles.filter(r => (r.hidden_tables || []).includes(t.key));
    const cls = t.risk === 'blackout' ? 'dead' : t.risk === 'degrade' ? 'under' : '';
    return `<tr>
      <td>
        <b>${esc(l === 'ar' ? t.ar : t.en)}</b><br>
        <span class="sub" style="font-family:monospace;font-size:11.5px">${esc(t.key)}</span>
      </td>
      <td>${esc(l === 'ar' ? t.providesAr : t.providesEn)}</td>
      <td>${t.pages.length
            ? t.pages.map(p => `<span class="chip">${esc(nav[p] || p)}</span>`).join(' ')
            : `<span class="sub">${esc(L.noPageUse)}</span>`}</td>
      <td><span class="chip ${cls}">${esc(L.risk[t.risk])}</span></td>
      <td>${hiders.length
            ? hiders.map(r => `<span class="chip dead">${esc(l === 'ar' ? r.name_ar : r.name_en)}</span>`).join(' ')
            : '—'}</td>
    </tr>`;
  }).join('');

  return `<div class="card">
    <h2>${esc(L.tables)}</h2>
    <p class="sub">${esc(L.tablesHelp)}</p>
    <div class="table-wrap"><table>
      <thead><tr>
        <th>${esc(L.tableName)}</th><th>${esc(L.provides)}</th>
        <th>${esc(L.feeds)}</th><th>${esc(l === 'ar' ? 'الأثر' : 'Impact')}</th>
        <th>${esc(L.hiddenTables)}</th>
      </tr></thead>
      <tbody>${rows}</tbody>
    </table></div>
    <p class="sub" style="margin-top:14px">${esc(l === 'ar'
      ? 'جدول dashboard_excluded_products غير قابل للإخفاء: هو مُرشِّح وليس مصدر بيانات — إخفاؤه يُفسد الأرقام بدل أن يحجبها.'
      : 'dashboard_excluded_products is not hideable: it is a filter, not a data source — hiding it would corrupt the numbers rather than withhold them.')}</p>
  </div>`;
}

// ------------------------------------------------------------------- activity
function activityPanel() {
  const L = T().admin;
  const byId = new Map(state.users.map(u => [u.user_id, u]));

  const rows = (state.activity || []).map(a => `<tr>
    <td class="n">${esc(a.at.slice(0, 19).replace('T', ' '))}</td>
    <td>${esc(byId.get(a.user_id)?.username || a.user_id?.slice(0, 8) || '—')}</td>
    <td>${esc(a.kind === 'login' ? L.login : L.pageview)}</td>
    <td>${esc(a.page || '—')}</td>
  </tr>`).join('');

  return `<div class="card">
    <h2>${esc(L.activity)}</h2>
    <p class="sub">${esc(lang() === 'ar'
      ? 'آخر 200 حدث. تُسجَّل عمليات الدخول وفتح الصفحات فقط — لا شيء عمّا شاهده المستخدم داخل الصفحة.'
      : 'The last 200 events. Sign-ins and page opens only — nothing about what was looked at inside a page.')}</p>
    <div class="table-wrap"><table>
      <thead><tr><th class="n">${esc(L.when)}</th><th>${esc(L.username)}</th>
        <th>${esc(L.event)}</th><th>${esc(L.page)}</th></tr></thead>
      <tbody>${rows || `<tr><td colspan="4" class="state">—</td></tr>`}</tbody>
    </table></div>
  </div>`;
}

// --------------------------------------------------------------------- render
function render() {
  const L = T().admin;
  const tabs = [['users', L.users], ['roles', L.roles],
                ['tables', L.tables], ['activity', L.activity]];

  $('tabs').innerHTML = tabs.map(([k, label]) =>
    `<button class="btn${state.tab === k ? ' primary' : ''}" data-tab="${k}">${esc(label)}</button>`
  ).join('');
  document.querySelectorAll('[data-tab]').forEach(b => b.onclick = () => {
    state.tab = b.dataset.tab;
    state.editingUser = state.editingRole = null;
    render();
  });

  if (state.tab === 'users')    { $('panel').innerHTML = usersPanel();    wireUsers(); }
  if (state.tab === 'roles')    { $('panel').innerHTML = rolesPanel();    wireRoles(); }
  if (state.tab === 'tables')   { $('panel').innerHTML = tablesPanel(); }
  if (state.tab === 'activity') { $('panel').innerHTML = activityPanel(); }
}

async function load() {
  const [usersRes, roles, opts, activity] = await Promise.all([
    adminUsers('list'),
    listRoles(),
    filterOptions(),
    listActivity(200)
  ]);
  state.users = usersRes.users || [];
  state.roles = roles;
  state.options = {
    salesperson: opts.salesperson.map(o => o.value),
    gov: opts.gov.map(o => o.value)
  };
  state.activity = activity;
}

(async function main() {
  const app = document.getElementById('app');
  const boot = document.getElementById('boot');
  app.classList.remove('hidden');
  try {
    await requireAuth('admin');
    applyLang();
    mountShell('admin.html');
    document.getElementById('shell').classList.remove('hidden');
    boot?.remove();

    showLoading($('panel'));
    await load();
    render();
  } catch (err) {
    console.error(err);
    boot?.remove();
    showError($('panel') || app, err);
    if (err instanceof AuthError) setTimeout(() => location.reload(), 1500);
  }
})();
