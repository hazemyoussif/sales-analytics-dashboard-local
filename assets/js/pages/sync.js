/**
 * Sync status — did the data actually arrive, and if not, why.
 *
 * WHY STALENESS IS THE HEADLINE AND ERRORS ARE THE DETAIL
 *
 * The sync records each job as it runs, so a job that throws leaves a row
 * saying so. But the failure that hurt this project most was never an error:
 * n8n's backfill could not complete, said nothing, and 29,284 phantom invoice
 * lines accumulated for months. And a sync that cannot reach Supabase at all
 * writes NO row — not even a failed one — because writing the row is the thing
 * that failed.
 *
 * A page that lists errors would show a clean green history through both. So
 * the first thing on it is how long since the last SUCCESSFUL refresh, and it
 * turns red on its own after 36 hours with nobody having to report anything.
 * Absence is the signal; errors are the explanation.
 *
 * WHY THE `refresh` JOB SPECIFICALLY
 *
 * sync_health() keys freshness off `refresh` rather than off any successful
 * job, because it is the only one whose success means the dashboard changed.
 * Every page reads the precomputed summaries rather than the tables the other
 * jobs write, so nine green jobs and a failed refresh means new data landed in
 * Supabase and not one number on screen moved. That happened three times
 * tonight while this was being built.
 */
import {
  syncHealth, syncRuns, triggerSync, syncRunnerConfigured, AuthError
} from '../api.js';
import { esc, num } from '../format.js';
import {
  requireAuth, mountShell, showError, showLoading, applyLang, lang, me
} from '../shell.js';
import { isAdmin } from '../perm.js';

const $ = id => document.getElementById(id);

const TXT = {
  ar: {
    title: 'حالة المزامنة',
    fresh: 'البيانات محدّثة',
    staleTitle: 'البيانات لم تُحدَّث',
    staleBody: 'آخر مزامنة ناجحة كانت قبل %s. الأرقام المعروضة في كل الصفحات هي أرقام ذلك التاريخ.',
    never: 'لم تنجح أي مزامنة بعد',
    neverBody: 'لا يوجد سجل لمزامنة ناجحة. إمّا أنها لم تُشغَّل أبداً، أو أنها لا تستطيع الوصول إلى قاعدة البيانات أصلاً.',
    lastSuccess: 'آخر نجاح', lastRun: 'آخر تشغيل',
    failed24: 'إخفاقات آخر ٢٤ ساعة', runs: 'التشغيلات الأخيرة',
    job: 'المهمة', rowsCol: 'صفوف', secs: 'ثانية', status: 'الحالة',
    ok: 'نجحت', fail: 'فشلت', running: 'قيد التشغيل',
    ago: 'قبل %s', hours: 'ساعة', minutes: 'دقيقة', days: 'يوم',
    none: 'لا يوجد سجل بعد',
    noneHelp: 'لم تُسجَّل أي مزامنة. شغّل المزامنة يدوياً أو انتظر الموعد المجدول.',
    host: 'الجهاز',
    syncNow: 'مزامنة الآن',
    syncNowHint: 'يسحب كل البيانات من أودو من جديد — الفواتير والمنتجات والعملاء والمخازن والصلاحية. يستغرق ١٥–٢٠ دقيقة، وتظهر مراحله في القائمة أدناه.',
    confirmSync: 'بدء مزامنة كاملة الآن؟ تستغرق ١٥–٢٠ دقيقة.',
    syncStarting: 'جارٍ الإرسال…',
    syncStarted: 'بدأت المزامنة. تابع تقدّمها في القائمة أدناه — تُحدَّث الصفحة تلقائياً.',
    syncRunning: 'المزامنة قيد التشغيل الآن',
    errTooSoon: 'بدأت مزامنة قبل قليل. حاول بعد قليل.',
    errAlready: 'هناك مزامنة قيد التشغيل بالفعل.',
    errDenied: 'هذه العملية للمدير فقط.',
    errUnreachable: 'تعذّر الوصول إلى خدمة المزامنة.',
    errFailed: 'تعذّر بدء المزامنة.'
  },
  en: {
    title: 'Sync status',
    fresh: 'Data is current',
    staleTitle: 'Data is not current',
    staleBody: 'The last successful sync was %s ago. Every page is showing the numbers from then.',
    never: 'No sync has ever succeeded',
    neverBody: 'There is no record of a successful sync. Either it has never run, or it cannot reach the database at all.',
    lastSuccess: 'Last success', lastRun: 'Last run',
    failed24: 'Failures in 24h', runs: 'Recent runs',
    job: 'Job', rowsCol: 'Rows', secs: 'sec', status: 'Status',
    ok: 'OK', fail: 'Failed', running: 'Running',
    ago: '%s ago', hours: 'h', minutes: 'min', days: 'd',
    none: 'Nothing recorded yet',
    noneHelp: 'No sync has been recorded. Run one by hand, or wait for the schedule.',
    host: 'Host',
    syncNow: 'Sync now',
    syncNowHint: 'Pulls everything from Odoo again — invoices, products, customers, warehouses, expiry. Takes 15–20 min; its steps appear in the list below.',
    confirmSync: 'Start a full sync now? It takes 15–20 minutes.',
    syncStarting: 'Sending…',
    syncStarted: 'Sync started. Watch its progress in the list below — this page refreshes itself.',
    syncRunning: 'A sync is running now',
    errTooSoon: 'A sync started a moment ago. Try again shortly.',
    errAlready: 'A sync is already running.',
    errDenied: 'This action is for admins only.',
    errUnreachable: 'Could not reach the sync service.',
    errFailed: 'Could not start the sync.'
  }
};

const L = () => TXT[lang()] || TXT.ar;

/** Human gap. Deliberately coarse — nobody needs seconds to decide anything. */
function since(iso) {
  if (!iso) return null;
  const mins = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
  const t = L();
  if (mins < 90) return `${num(mins)} ${t.minutes}`;
  const hrs = Math.round(mins / 60);
  if (hrs < 48) return `${num(hrs)} ${t.hours}`;
  return `${num(Math.round(hrs / 24))} ${t.days}`;
}

function stamp(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  const p = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/**
 * The banner. Three states, and the third is the one that matters:
 * never-succeeded is NOT the same as stale, and reads very differently to
 * someone deciding whether to trust the numbers.
 */
function banner(h) {
  const t = L();
  if (!h || !h.last_success) {
    return `<div class="state error">
      <strong>${esc(t.never)}</strong><br>${esc(t.neverBody)}</div>`;
  }
  const gap = since(h.last_success);
  if (h.stale) {
    return `<div class="state error">
      <strong>${esc(t.staleTitle)}</strong><br>
      ${esc(t.staleBody.replace('%s', gap))}</div>`;
  }
  return `<div class="state">
    <strong>${esc(t.fresh)}</strong> — ${esc(t.ago.replace('%s', gap))}</div>`;
}

function tile(label, value, note, accent = '') {
  return `<div class="tile ${accent}">
    <div class="label">${esc(label)}</div>
    <div class="value">${esc(value)}</div>
    ${note ? `<div class="note">${esc(note)}</div>` : ''}
  </div>`;
}

function statusPill(s) {
  const t = L();
  const map = { ok: [t.ok, 'ok'], failed: [t.fail, 'bad'], running: [t.running, 'warn'] };
  const [text, cls] = map[s] || [s, ''];
  // The word is always present, never colour alone — same rule as charts.js.
  return `<span class="pill ${cls}">${esc(text)}</span>`;
}

/** Rows come back newest-first and flat; group them back into runs. */
function groupRuns(rows) {
  const runs = new Map();
  for (const r of rows) {
    if (!runs.has(r.run_id)) runs.set(r.run_id, []);
    runs.get(r.run_id).push(r);
  }
  return [...runs.entries()].map(([id, jobs]) => {
    const ordered = jobs.slice().sort((a, b) =>
      new Date(a.started_at) - new Date(b.started_at));
    return {
      id,
      jobs: ordered,
      started: ordered[0]?.started_at,
      host: ordered[0]?.host,
      failed: ordered.some(j => j.status === 'failed'),
      running: ordered.some(j => j.status === 'running'),
      seconds: ordered.reduce((s, j) => s + Number(j.seconds || 0), 0)
    };
  });
}

function renderRuns(runs) {
  const t = L();
  if (!runs.length) {
    return `<div class="state"><strong>${esc(t.none)}</strong><br>${esc(t.noneHelp)}</div>`;
  }
  return runs.map(run => {
    const state = run.failed ? 'failed' : run.running ? 'running' : 'ok';
    const jobs = run.jobs.map(j => `
      <tr>
        <td>${esc(j.job)}</td>
        <td class="n">${statusPill(j.status)}</td>
        <td class="n">${j.rows === null || j.rows === undefined ? '—' : num(j.rows)}</td>
        <td class="n">${esc(Number(j.seconds || 0).toFixed(1))}</td>
      </tr>
      ${j.error ? `<tr class="err-row"><td colspan="4">
         <pre class="err">${esc(j.error)}</pre></td></tr>` : ''}`).join('');
    return `<div class="card">
      <h3>${esc(stamp(run.started))} ${statusPill(state)}</h3>
      <p class="sub">${esc(run.jobs.length)} ${esc(t.job)} · ${esc(run.seconds.toFixed(0))} ${esc(t.secs)}${
        run.host ? ` · ${esc(t.host)}: ${esc(run.host)}` : ''}</p>
      <div class="table-wrap"><table>
        <thead><tr>
          <th>${esc(t.job)}</th><th class="n">${esc(t.status)}</th>
          <th class="n">${esc(t.rowsCol)}</th><th class="n">${esc(t.secs)}</th>
        </tr></thead>
        <tbody>${jobs}</tbody>
      </table></div>
    </div>`;
  }).join('');
}

/** How long to keep auto-refreshing the page after a sync is triggered. */
const POLL_EVERY_MS = 20_000;
const POLL_FOR_MS = 25 * 60_000;
let pollUntil = 0;
let pollTimer = null;

/**
 * A run counts as live only if it has a 'running' job AND started recently. A
 * killed sync leaves its last job marked 'running' forever (see the table
 * comment in 28_sync_runs.sql); an orphan from last week must not read as "a
 * sync is happening now" and hide the button. A full sync is ~20 min.
 */
const LIVE_WINDOW_MS = 45 * 60_000;
const isLive = run =>
  run.running && Date.now() - new Date(run.started).getTime() < LIVE_WINDOW_MS;

/**
 * The "sync now" control. Shown only to an admin, and only when a runner
 * service is configured (config.js). Reflects the live state: if a run is
 * already going, it says so instead of offering the button.
 */
function renderActions(runs) {
  const el = $('actions');
  if (!el) return;
  const t = L();
  if (!syncRunnerConfigured() || !isAdmin(me())) { el.innerHTML = ''; return; }

  if (runs.some(isLive)) {
    el.innerHTML = `<div class="card"><p class="sub">⏳ ${esc(t.syncRunning)}</p></div>`;
    return;
  }
  el.innerHTML = `<div class="card">
    <button class="btn primary" id="sync-now">${esc(t.syncNow)}</button>
    <p class="sub" id="sync-msg">${esc(t.syncNowHint)}</p>
  </div>`;

  $('sync-now').onclick = async () => {
    if (!confirm(t.confirmSync)) return;
    const btn = $('sync-now');
    btn.disabled = true;
    $('sync-msg').textContent = t.syncStarting;
    try {
      await triggerSync();
      $('sync-msg').textContent = t.syncStarted;
      // Auto-refresh so the new run and its jobs appear without a manual reload.
      pollUntil = Date.now() + POLL_FOR_MS;
      if (!pollTimer) pollTimer = setInterval(tick, POLL_EVERY_MS);
      setTimeout(() => render().catch(() => {}), 4000);
    } catch (err) {
      btn.disabled = false;
      const map = { 429: t.errTooSoon, 409: t.errAlready, 403: t.errDenied,
                    401: t.errDenied, 0: t.errUnreachable };
      $('sync-msg').textContent = map[err.status] || err.message || t.errFailed;
    }
  };
}

function tick() {
  if (Date.now() > pollUntil) { clearInterval(pollTimer); pollTimer = null; return; }
  render().catch(() => {});
}

async function render() {
  const t = L();
  // Sequential rather than Promise.all: if sync_health throws because the
  // table does not exist yet, the error should name that rather than being
  // one of two rejections.
  const health = (await syncHealth())[0] || null;
  const rows = await syncRuns(120);
  const runs = groupRuns(rows);

  $('banner').innerHTML = banner(health);

  $('tiles').innerHTML =
    tile(t.lastSuccess,
         health?.last_success ? stamp(health.last_success) : '—',
         health?.last_success ? t.ago.replace('%s', since(health.last_success)) : '',
         health?.stale ? 'accent-8' : '') +
    tile(t.lastRun,
         health?.last_run ? stamp(health.last_run) : '—',
         health?.last_run_status || '') +
    tile(t.failed24, num(health?.failed_last_24h ?? 0), '',
         Number(health?.failed_last_24h || 0) > 0 ? 'accent-8' : '');

  renderActions(runs);
  $('runs').innerHTML = renderRuns(runs);

  // If a sync is in progress — one we started, or one from cron / the local
  // task — keep the page refreshing on its own until it finishes.
  if (runs.some(isLive) && !pollTimer) {
    pollUntil = Date.now() + POLL_FOR_MS;
    pollTimer = setInterval(tick, POLL_EVERY_MS);
  }
}

(async () => {
  const app = $('app');
  const boot = $('boot');
  app.classList.remove('hidden');
  try {
    await requireAuth('sync');
    applyLang();
    mountShell('sync.html');
    $('shell').classList.remove('hidden');
    boot?.remove();

    showLoading($('runs'));
    await render();
  } catch (err) {
    console.error(err);
    boot?.remove();
    showError($('runs') || app, err);
    if (err instanceof AuthError) setTimeout(() => location.reload(), 1500);
  }
})();
