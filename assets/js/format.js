/**
 * Formatting and escaping. Pure — no DOM, no network.
 */
import { CURRENCY, CURRENCY_USD, CURRENCY_KEY, USD_RATE } from './config.js';

/**
 * Escape a string for safe insertion into innerHTML.
 * Product, customer and category names come from Odoo and are user-controlled,
 * so every one of them is a stored-XSS vector. Nothing from the database reaches
 * innerHTML without passing through here.
 */
export function esc(s) {
  if (s === null || s === undefined) return '';
  return String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/** Full number with thousands separators. Fractional quantities keep 1 decimal. */
export function num(n, decimals = 0) {
  if (n === null || n === undefined || Number.isNaN(Number(n))) return '—';
  return Number(n).toLocaleString('en-US',
    { minimumFractionDigits: decimals, maximumFractionDigits: decimals });
}

/** Compact form for tiles: 1.39B, 47.2M, 12.5K. */
export function compact(n) {
  if (n === null || n === undefined || Number.isNaN(Number(n))) return '—';
  const v = Number(n), a = Math.abs(v), sign = v < 0 ? '-' : '';
  if (a >= 1e9) return `${sign}${(a / 1e9).toFixed(2)}B`;
  if (a >= 1e6) return `${sign}${(a / 1e6).toFixed(1)}M`;
  if (a >= 1e3) return `${sign}${(a / 1e3).toFixed(1)}K`;
  return `${sign}${a.toFixed(0)}`;
}

/**
 * Which currency money() renders in. Everything is stored in IQD; a user can
 * flip the whole dashboard to a USD view from the top bar. The choice lives in
 * localStorage so it holds across pages and reloads.
 */
export function activeCurrency() {
  return localStorage.getItem(CURRENCY_KEY) === 'USD' ? CURRENCY_USD : CURRENCY;
}

/**
 * Money. The currency is never hardcoded as a symbol. When the USD view is on,
 * the IQD amount is divided by the fixed rate before formatting — same compact
 * / full logic, just a smaller number and a different code.
 */
export function money(n, { compact: c = true } = {}) {
  if (n === null || n === undefined || Number.isNaN(Number(n))) return '—';
  const cur = activeCurrency();
  const v = cur.code === 'USD' ? Number(n) / USD_RATE : Number(n);
  return `${c ? compact(v) : num(v)} ${cur.code}`;
}

export function pct(n, decimals = 1) {
  if (n === null || n === undefined || Number.isNaN(Number(n))) return '—';
  return `${Number(n).toFixed(decimals)}%`;
}

/** Quantities are in the product's UoM and can be fractional (303.5 cartons). */
export function qty(n) {
  if (n === null || n === undefined || Number.isNaN(Number(n))) return '—';
  const v = Number(n);
  return num(v, Number.isInteger(v) ? 0 : 1);
}

export function date(s) {
  return s ? String(s).slice(0, 10) : '—';
}

/** Today in Baghdad — "how many days idle" must be measured locally. */
export function todayBaghdad() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Baghdad' });
}
