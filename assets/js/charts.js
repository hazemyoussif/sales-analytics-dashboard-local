/**
 * SVG and CSS chart marks. Pure rendering — no network, no Supabase, no
 * permission logic.
 *
 * Everything here draws with the palette already defined in style.css as
 * --s1..--s8 plus the status tokens. Those are the validated data-viz palette,
 * so nothing in this file introduces a colour of its own.
 *
 * TWO RULES THAT SHAPED THESE FUNCTIONS
 *
 * 1. ONE AXIS. A textbook Pareto chart plots bars on a money axis and the
 *    cumulative percentage on a second one. Two y-scales in a single frame let
 *    whoever draws it slide one against the other until the story looks how
 *    they want, and the reader cannot tell that it happened. So the
 *    concentration story is split: concentrationCurve() is a pure 0-100%
 *    frame, and the magnitudes live in the bar list and the table beside it.
 *
 * 2. NEVER COLOUR ALONE. Every mark that carries meaning also carries a label
 *    or a number, so the chart survives colour-blindness, greyscale printing
 *    and forced-colours mode.
 */
import { esc } from './format.js';

/** Unique ids per chart instance — two charts on one page must not share a
 *  gradient definition, or the second one silently inherits the first. */
let _uid = 0;
const uid = () => `c${++_uid}`;

/**
 * Concentration (Lorenz) curve — the honest form of an 80/20 chart.
 *
 * x = cumulative share of CUSTOMERS (or products), y = cumulative share of
 * REVENUE. Both axes are percentages of the same total, so there is exactly
 * one scale and no way to distort it.
 *
 * The dashed diagonal is what perfect equality would look like: every customer
 * buying the same amount. The gap between the curve and that diagonal IS the
 * concentration. Without the reference line the curve is just a shape rising
 * to 100% and means nothing to a reader who has not seen one before.
 *
 * @param {{x:number,y:number}[]} points cumulative percentages, ascending
 * @param {object} opts crossX = where the curve reaches 80% of revenue
 */
export function concentrationCurve(points, opts = {}) {
  const {
    crossX = null, crossLabel = '', xLabel = '', yLabel = '',
    equalityLabel = '', curveLabel = ''
  } = opts;

  if (!points.length) return '';

  const W = 760, H = 300, P = { t: 20, r: 16, b: 34, l: 46 };
  const iw = W - P.l - P.r, ih = H - P.t - P.b;
  const sx = v => P.l + (v / 100) * iw;
  const sy = v => P.t + ih - (v / 100) * ih;
  const id = uid();

  const path = points
    .map((p, i) => `${i ? 'L' : 'M'}${sx(p.x).toFixed(1)},${sy(p.y).toFixed(1)}`)
    .join('');
  const area = `${path}L${sx(points[points.length - 1].x).toFixed(1)},${sy(0)}`
             + `L${sx(points[0].x).toFixed(1)},${sy(0)}Z`;

  const ticks = [0, 25, 50, 75, 100];

  // The 80% guide and where the curve crosses it. This is the number
  // management actually asked for, so it is drawn and written out rather than
  // left to be estimated off the axis.
  const cross = crossX === null ? '' : `
    <line x1="${sx(crossX)}" y1="${sy(0)}" x2="${sx(crossX)}" y2="${sy(80)}"
          stroke="var(--s8)" stroke-width="2" stroke-dasharray="4 3"/>
    <line x1="${P.l}" y1="${sy(80)}" x2="${sx(crossX)}" y2="${sy(80)}"
          stroke="var(--s8)" stroke-width="2" stroke-dasharray="4 3"/>
    <circle cx="${sx(crossX)}" cy="${sy(80)}" r="5"
            fill="var(--s8)" stroke="var(--surface)" stroke-width="2"/>`;

  return `
  <div class="chart">
    <svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(curveLabel)}">
      <defs>
        <linearGradient id="${id}-f" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%"   stop-color="var(--s1)" stop-opacity=".22"/>
          <stop offset="100%" stop-color="var(--s1)" stop-opacity="0"/>
        </linearGradient>
      </defs>

      ${ticks.map(v => `
        <line x1="${P.l}" y1="${sy(v)}" x2="${W - P.r}" y2="${sy(v)}"
              stroke="var(--grid)" stroke-width="1"/>
        <text x="${P.l - 8}" y="${sy(v) + 4}" class="ch-axis" text-anchor="end">${v}%</text>`).join('')}
      ${ticks.map(v => `
        <text x="${sx(v)}" y="${H - 10}" class="ch-axis" text-anchor="middle">${v}%</text>`).join('')}

      <line x1="${sx(0)}" y1="${sy(0)}" x2="${sx(100)}" y2="${sy(100)}"
            stroke="var(--axis)" stroke-width="2" stroke-dasharray="5 4"/>

      <path d="${area}" fill="url(#${id}-f)"/>
      <path d="${path}" fill="none" stroke="var(--s1)" stroke-width="2"
            stroke-linejoin="round" stroke-linecap="round"/>
      ${cross}

      <line x1="${P.l}" y1="${sy(0)}" x2="${W - P.r}" y2="${sy(0)}"
            stroke="var(--axis)" stroke-width="1"/>
      <line x1="${P.l}" y1="${P.t}" x2="${P.l}" y2="${sy(0)}"
            stroke="var(--axis)" stroke-width="1"/>
    </svg>
    ${crossLabel ? `<p class="ch-callout">${esc(crossLabel)}</p>` : ''}
    <div class="ch-legend">
      <span><i class="sw" style="background:var(--s1)"></i>${esc(curveLabel)}</span>
      <span><i class="sw dash"></i>${esc(equalityLabel)}</span>
      <span class="ch-axis-name">${esc(xLabel)} · ${esc(yLabel)}</span>
    </div>
  </div>`;
}

/**
 * Vertical columns for a time series. One series, one axis.
 * @param {{label:string, value:number, display:string, colorVar?:string}[]} rows
 */
export function columnChart(rows, { colorVar = '--s1', empty = '' } = {}) {
  if (!rows.length) return `<div class="state">${esc(empty)}</div>`;
  const max = Math.max(...rows.map(r => Math.abs(Number(r.value) || 0)), 1);
  return `<div class="cols">${rows.map(r => `
    <div class="col" title="${esc(r.label)} — ${esc(r.display)}">
      <span class="col-val">${esc(r.display)}</span>
      <span class="col-track">
        <span class="col-fill" style="height:${(Math.abs(Number(r.value) || 0) / max * 100).toFixed(1)}%;
              background:var(${r.colorVar || colorVar})"></span>
      </span>
      <span class="col-label">${esc(r.label)}</span>
    </div>`).join('')}</div>`;
}

/**
 * Ordered-severity bars — aging buckets, and anything else whose categories
 * run from fine to alarming.
 *
 * Each row carries its own colour token because the ORDER is the meaning here.
 * The label, the amount and the share are always drawn, so severity never
 * rests on colour alone.
 */
export function severityBars(rows) {
  if (!rows.length) return '';
  const total = rows.reduce((s, r) => s + Math.abs(Number(r.value) || 0), 0) || 1;
  return `<div class="sev">${rows.map(r => {
    const share = Math.abs(Number(r.value) || 0) / total * 100;
    return `<div class="sev-row" title="${esc(r.label)} — ${esc(r.display)}">
      <span class="sev-label"><i class="sw" style="background:var(${r.colorVar})"></i>${esc(r.label)}</span>
      <span class="sev-value">${esc(r.display)}</span>
      <span class="sev-track"><span class="sev-fill"
            style="width:${share.toFixed(1)}%;background:var(${r.colorVar})"></span></span>
      <span class="sev-share">${share.toFixed(0)}%</span>
    </div>`;
  }).join('')}</div>`;
}

/**
 * Cross-tab heat table — one sequential hue, light to dark.
 *
 * The number is printed in every cell. The tint is a second, redundant
 * encoding for scanning, which is why it is capped well below full strength:
 * a cell dark enough to need white text is a cell whose number stops being
 * readable in one of the two themes.
 *
 * A zero gets NO tint at all. That hole in the grid is the point of the chart —
 * an agency our biggest customer does not buy is the opportunity being hunted.
 *
 * @param {string[]} cols column headings
 * @param {{rowLabel:string, cells:{value:number, display:string}[]}[]} rows
 */
export function heatMatrix(cols, rows, { corner = '', hueVar = '--s1' } = {}) {
  if (!rows.length) return '';
  const max = Math.max(
    ...rows.flatMap(r => r.cells.map(c => Math.abs(Number(c.value) || 0))), 1);
  return `<div class="table-wrap"><table class="matrix">
    <thead><tr><th>${esc(corner)}</th>
      ${cols.map(c => `<th class="n">${esc(c)}</th>`).join('')}</tr></thead>
    <tbody>${rows.map(r => `<tr>
      <td class="matrix-row-label" title="${esc(r.rowLabel)}">${esc(r.rowLabel)}</td>
      ${r.cells.map((c, i) => {
        const v = Math.abs(Number(c.value) || 0);
        const bg = v === 0 ? 'transparent'
          : `color-mix(in oklab, var(${hueVar}) ${(8 + (v / max) * 46).toFixed(0)}%, var(--surface))`;
        return `<td class="n" style="background:${bg}"
                    title="${esc(r.rowLabel)} · ${esc(cols[i] || '')}">${esc(c.display)}</td>`;
      }).join('')}
    </tr>`).join('')}</tbody></table></div>`;
}
