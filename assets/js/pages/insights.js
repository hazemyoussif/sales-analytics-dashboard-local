/**
 * Shared machinery for the four management pages:
 * Customers 80/20, Agencies, Debt, Branches.
 *
 * They differ in what they measure and agree on everything else — auth, the
 * shell, the health strip, the filter bar in the URL, how a masked column is
 * dropped, and what happens when the data is not there yet. Keeping that in
 * one file is the same decision analysis.js made for Returns and Discounts.
 *
 * ===========================================================================
 * THE ONE THING TO UNDERSTAND BEFORE EDITING THIS FILE
 * ===========================================================================
 * Three of these four pages need data we do not sync yet. Rather than ship
 * blank screens, each page names the RPC it WILL call and a demo dataset to
 * draw until that RPC exists.
 *
 * The fallback fires on exactly one condition: PostgREST answering "no such
 * function" (404 / PGRST202). It does NOT fire on a network error, a timeout,
 * a permission denial or an empty result — every one of those is reported as
 * itself. Falling back on any of them would replace a real outage with
 * plausible fake numbers, which is the single worst thing this dashboard could
 * do.
 *
 * When a page is on demo data it says so in a red banner that cannot be
 * dismissed, and every tile on it carries the same mark. See demo.js.
 */
import { dataHealth, filterOptions, rpc, ApiError, AuthError } from '../api.js';
import { esc, money, num, pct, qty } from '../format.js';
import { safePeriod } from '../calc.js';
import {
  requireAuth, mountShell, showError, showLoading, healthStrip, barList,
  T, lang, applyLang, showField, haveSales, showUnavailable, unavailableStrip,
  checklist, checklistValues, infoIcon
} from '../shell.js';

export const $ = id => document.getElementById(id);

/** Set once per page load by load(); read by the banner and the tiles. */
let _demo = false;
export const isDemo = () => _demo;

/**
 * Call the page's RPC, or fall back to demo data if that function has not been
 * created yet.
 *
 * @param {string} fn      the Postgres function this page will call
 * @param {object} args    its arguments
 * @param {Function} demo  produces the stand-in rows
 */
export async function load(fn, args, demo) {
  try {
    const rows = await rpc(fn, args);
    return rows;
  } catch (err) {
    // 404 with PGRST202 is PostgREST for "that function does not exist".
    // Anything else — 401, 403, 500, a dropped connection — is a real failure
    // and has to reach the user as one.
    const missing = err instanceof ApiError && err.status === 404;
    if (!missing) throw err;
    _demo = true;
    return demo();
  }
}

/** Marks a page as demo-fed without an RPC attempt, for screens whose data
 *  source does not exist in any form yet (per-warehouse stock). */
export function markDemo() { _demo = true; }

export function demoBanner() {
  if (!_demo) return '';
  const ar = lang() === 'ar';
  return `<div class="demo-banner">
    <strong>${esc(ar ? 'بيانات تجريبية — للتصميم فقط' : 'DEMO DATA — layout only')}</strong>
    <span>${esc(ar
      ? 'الأرقام في هذه الصفحة مُولّدة، وليست من أودو. الصفحة تتحول إلى البيانات الحقيقية تلقائياً فور إنشاء دوال القراءة في Supabase.'
      : 'Every figure here is generated, not from Odoo. The page switches to real data by itself once the Supabase functions exist.')}</span>
  </div>`;
}

// ------------------------------------------------------------------- pieces
// checklist and checklistValues live in shell.js, one layer down, because
// Overview builds its filter bar by hand and imports only shell. Re-exported
// here so pages that import from insights get them too.
// Imported above, re-exported here. Same rule as infoIcon below: the
// `export … from` form alone would not bind these locally, and mountFilters
// calls both.
export { checklist, checklistValues };

/**
 * `flag` is for a caveat about the NUMBER ITSELF, as opposed to `note`, which
 * describes it. It exists because some tiles cannot honour every filter: stock
 * is held per product with no location or salesperson dimension, so with a
 * governorate selected the frozen-capital figure is still the whole company's.
 * Silently correct and confidently misread, which is the worst combination a
 * dashboard offers -- so the tile says so, on the tile, only when it applies.
 */
export function tile(label, value, note, accent = '', share = null, flag = null, info = null) {
  return `<div class="tile ${accent}${_demo ? ' is-demo' : ''}">
    <div class="label">${esc(label)}${info ? infoIcon(info) : ''}</div>
    <div class="value">${esc(value)}${share ? `<span class="share">${esc(share)}</span>` : ''}</div>
    ${note ? `<div class="note">${esc(note)}</div>` : ''}
    ${flag ? `<div class="tile-flag">${esc(flag)}</div>` : ''}
  </div>`;
}

// infoIcon lives in shell.js for the same reason checklist does: Overview
// builds its tiles with its OWN local tile(), not this one, so a helper only
// exported from here is invisible to the page that needs it most.
//
// It is IMPORTED above as well as re-exported here, and both are required.
// `export { x } from './y.js'` forwards the name to this module's consumers
// WITHOUT binding it locally -- so tile() and table() below called an
// identifier that did not exist in their scope, and the page died with
// "infoIcon is not defined". Valid syntax, so node --check passed it; the
// failure only exists at run time.
export { infoIcon };

/** Table renderer. `cols` is [{label, n, get, help}]; get() returns text. */
export function table(el, rows, cols, { limit = 150, empty, countEl = 'count' } = {}) {
  if (!el) return;
  if (!rows.length) {
    el.innerHTML = `<div class="state">${esc(empty || T().nodata)}</div>`;
    const c = $(countEl); if (c) c.textContent = '';
    return;
  }
  const shown = rows.slice(0, limit);
  el.innerHTML = `<div class="table-wrap"><table><thead><tr>
    ${cols.map(c => `<th class="${c.n ? 'n' : ''}">${esc(c.label)}${infoIcon(c.help)}</th>`).join('')}
    </tr></thead><tbody>
    ${shown.map(r => `<tr>${cols.map(c =>
      `<td class="${c.n ? 'n' : ''}">${c.html ? c.get(r) : esc(c.get(r))}</td>`).join('')}</tr>`).join('')}
    </tbody></table></div>`;
  const c = $(countEl);
  if (c) {
    c.textContent = rows.length > shown.length
      ? `${num(rows.length)} · ${T().showing} ${num(shown.length)}`
      : `${num(rows.length)}`;
  }
}

/**
 * A breakdown bar list. A null value means the column is masked for this role,
 * not zero, so those rows are dropped rather than drawn as empty bars — an
 * empty bar reads as "this customer bought nothing".
 */
export function breakdown(el, rows, { valueOf, displayOf, colorVar, limit = 12 }) {
  if (!el) return;
  const usable = rows.filter(r => valueOf(r) !== null && valueOf(r) !== undefined);
  el.innerHTML = usable.length
    ? barList(usable.slice(0, limit).map(r => ({
        label: r.label || '—',
        value: Math.abs(Number(valueOf(r))),
        display: displayOf(r)
      })), { colorVar })
    : `<div class="state">${esc(T().nodata)}</div>`;
}

/** Group rows by a key and sum a measure — the shape every breakdown needs. */
export function groupSum(rows, keyOf, valueOf) {
  const m = new Map();
  for (const r of rows) {
    const k = keyOf(r) || '—';
    m.set(k, (m.get(k) || 0) + Number(valueOf(r) || 0));
  }
  return [...m.entries()]
    .map(([label, value]) => ({ label, value }))
    .sort((a, b) => b.value - a.value);
}

// ------------------------------------------------------------------ filters
/** Current filter values from the URL. Dates fall back to the data's own range. */
export function params(health, extraKeys = []) {
  const p = new URLSearchParams(location.search);
  const period = safePeriod(health, p.get('from'), p.get('to'));
  const out = { from: period.from, to: period.to };
  for (const k of extraKeys) out[k] = p.get(k) || '';
  return out;
}

/** First and last day of a YYYY-MM. Kept here rather than in each page so the
 *  two ends of a range can never disagree about what a month is. */
export const monthOf = iso => String(iso || '').slice(0, 7);
export const startOfMonth = ym => (ym ? `${ym}-01` : '');
export function endOfMonth(ym) {
  if (!ym) return '';
  const [y, m] = ym.split('-').map(Number);
  // Day 0 of the NEXT month is the last day of this one — no leap-year table.
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return `${ym}-${String(last).padStart(2, '0')}`;
}

/**
 * Render the filter controls.
 *
 * @param {Array} defs
 *   {key, label, type:'date'|'month'|'ym'|'select', options, required, edge, group}
 *
 *   type 'month' shows a month picker but still stores a full ISO date in the
 *   query string, so every RPC signature and every saved link keeps working.
 *   `edge` says which end of the month to store: 'start' (default) or 'end'.
 *   Storing the 1st for a range's end would silently drop the rest of the
 *   month — a whole month of sales missing from a total, with nothing on
 *   screen to suggest it.
 *
 *   `group` is the id of the element to render into, default 'filters'. It is
 *   what lets the comparison controls sit in their own panel instead of being
 *   five more boxes in a row of nine.
 *
 * Changing any control rewrites the query string and reloads, so every view is
 * a link somebody can paste into a message.
 */
export function mountFilters(defs, current) {
  const groups = new Map();
  for (const d of defs) {
    const g = d.group || 'filters';
    if (!groups.has(g)) groups.set(g, []);
    groups.get(g).push(d);
  }

  const control = d => {
    // 'ym' stores the month ITSELF -- "2026-08" -- not one end of it. 'month'
    // below exists to put a month picker on a from/to PAIR while keeping full
    // ISO dates in the URL; a single control that means one whole month has no
    // pair to pick an end of, and storing "2026-08-01" for it would say the
    // first of August where the page means all of August. The caller expands it
    // to both ends when it builds the RPC arguments.
    if (d.type === 'ym') {
      return `<input type="month" id="f-${d.key}" value="${esc(current[d.key] || '')}">`;
    }
    // Several values, comma-joined in the URL. current[key] may arrive as an
    // array (the caller already split it) or as the raw string.
    if (d.type === 'checklist') {
      const cur = current[d.key];
      const sel = Array.isArray(cur) ? cur
                : String(cur || '').split(',').map(s => s.trim()).filter(Boolean);
      return checklist(`f-${d.key}`, d.options || [], sel);
    }
    if (d.type === 'month') {
      return `<input type="month" id="f-${d.key}" value="${esc(monthOf(current[d.key]))}">`;
    }
    if (d.type === 'date') {
      return `<input type="date" id="f-${d.key}" value="${esc(current[d.key] || '')}">`;
    }
    const opts = (d.options || []).map(o => {
      const value = typeof o === 'string' ? o : o.value;
      const label = typeof o === 'string' ? o : o.label;
      return `<option value="${esc(value)}"${value === current[d.key] ? ' selected' : ''}>${esc(label)}</option>`;
    }).join('');
    return `<select id="f-${d.key}">${d.required ? '' : '<option value="">—</option>'}${opts}</select>`;
  };

  for (const [groupId, gdefs] of groups) {
    const el = $(groupId);
    if (!el) continue;
    el.innerHTML = gdefs.map(d =>
      `<div class="field${d.type === 'checklist' ? ' field-wide' : ''}">` +
      `<label for="f-${d.key}">${esc(d.label)}</label>${control(d)}` +
      (d.hint ? `<span class="field-hint">${esc(d.hint)}</span>` : '') +
      `</div>`
    ).join('');
  }

  const apply = () => {
    const q = new URLSearchParams();
    for (const d of defs) {
      let v;
      if (d.type === 'checklist') {
        v = checklistValues(`f-${d.key}`).join(',');
      } else {
        v = $(`f-${d.key}`)?.value;
        if (d.type === 'month' && v) {
          v = d.edge === 'end' ? endOfMonth(v) : startOfMonth(v);
        }
      }
      if (v) q.set(d.key, v);
      // A def may declare other params it owns and must clear -- a family
      // whose category picks no longer exist under it, for instance. Without
      // this the stale value survives in the URL and is silently re-applied.
      for (const k of d.clears || []) q.delete(k);
    }
    location.search = q.toString();
  };
  for (const d of defs) {
    const c = $(`f-${d.key}`);
    // A checklist is a container, so the change event comes from a checkbox
    // inside it and reaches the div by bubbling. `change` does bubble; `input`
    // on a checkbox does too, but change is the one that fires once per click.
    if (c) c.onchange = apply;
  }
}

// ---------------------------------------------------------------- bootstrap
/**
 * Page bootstrap: session, permission, shell, health strip, then render.
 *
 * A role that cannot read dashboard_invoice_lines gets the explicit
 * "not available to your role" state instead of an empty page, which would
 * read as "this company has no customers and no debt" — a very reassuring lie.
 */
export async function bootInsight(activePage, render) {
  const app = $('app');
  const bootEl = $('boot');
  app.classList.remove('hidden');
  try {
    await requireAuth();
    applyLang();
    mountShell(activePage);
    $('shell').classList.remove('hidden');
    bootEl?.remove();

    const health = await dataHealth();

    // Filter options come from here rather than from each page's own rows.
    // A page that derives its dropdown from the rows it loaded can only ever
    // offer values that survived the CURRENT filter, so choosing one narrows
    // the list and there is no way back to the others. Sourcing them from the
    // whole dataset keeps every option reachable.
    //
    // Never fatal: a page with no dropdowns is worth more than no page.
    let filters = { gov: [], salesperson: [], category: [], brand: [] };
    try {
      filters = await filterOptions();
    } catch (err) {
      console.warn('filter options unavailable', err);
    }

    if (!haveSales()) {
      $('health').innerHTML = unavailableStrip();
      showUnavailable($('tiles'), 'sales');
      return;
    }

    showLoading($('tiles'));
    await render({ health, filters });

    // Rendered last: the demo flag is only known after the page has tried its
    // RPC, and the banner has to sit above everything it describes.
    $('health').innerHTML = demoBanner() + healthStrip(health) + unavailableStrip();
  } catch (err) {
    console.error(err);
    bootEl?.remove();
    showError($('tiles') || app, err);
    if (err instanceof AuthError) setTimeout(() => location.reload(), 1500);
  }
}

export { money, num, pct, qty, esc, barList, T, lang, showField };
