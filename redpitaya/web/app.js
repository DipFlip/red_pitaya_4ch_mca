'use strict';
const $ = id => document.getElementById(id);
const colors = ['#087e86', '#d47b35', '#7961b5', '#bd4c70'];
const selected = new Set([1, 2, 3, 4]);
const number = value => Number(value).toLocaleString(undefined, {maximumFractionDigits: 1});
let state = null;
let channelKey = '';

function chart(canvas, xmax, ymax, xlabel, logarithmic = false, xmin = 0) {
  const box = canvas.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  canvas.width = Math.round(box.width * ratio);
  canvas.height = Math.round(box.height * ratio);
  const ctx = canvas.getContext('2d');
  ctx.scale(ratio, ratio);
  const pad = {left: 60, right: 16, top: 24, bottom: 34};
  const w = box.width - pad.left - pad.right, h = box.height - pad.top - pad.bottom;
  const scale = value => logarithmic ? Math.log10(1 + value) : value;
  const top = Math.max(1, scale(ymax));
  const x = value => pad.left + (value - xmin) / (xmax - xmin) * w;
  const y = value => pad.top + h - scale(value) / top * h;
  ctx.font = '11px -apple-system, sans-serif';
  ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const sy = pad.top + h * (1 - i / 4);
    ctx.strokeStyle = '#e9eff0'; ctx.beginPath(); ctx.moveTo(pad.left, sy); ctx.lineTo(pad.left + w, sy); ctx.stroke();
    const value = logarithmic ? Math.pow(10, top * i / 4) - 1 : top * i / 4;
    ctx.fillStyle = '#627580'; ctx.textAlign = 'right'; ctx.fillText(number(value), pad.left - 10, sy + 4);
  }
  for (let i = 0; i <= 5; i++) {
    const value = xmin + (xmax - xmin) * i / 5;
    ctx.textAlign = 'center'; ctx.fillText(xlabel(value), x(value), pad.top + h + 21);
  }
  ctx.textAlign = 'left'; ctx.fillText(logarithmic ? 'counts · log' : (canvas.id === 'spectrum' ? 'counts' : 'counts/s'), pad.left, 13);
  return {ctx, x, y};
}

function draw() {
  if (!state) return;
  const rows = state.channels.filter(row => selected.has(row.channel));
  const maxCount = Math.max(1, ...rows.flatMap(row => row.histogram));
  const spectrum = chart($('spectrum'), state.histogram_max, maxCount * 1.1, number, $('log-scale').checked);
  for (const row of rows) {
    const {ctx, x, y} = spectrum;
    ctx.strokeStyle = colors[row.channel - 1]; ctx.lineWidth = 1.7; ctx.beginPath();
    row.histogram.forEach((count, i) => {
      const left = x(i / state.histogram_bins * state.histogram_max);
      const right = x((i + 1) / state.histogram_bins * state.histogram_max);
      if (!i) ctx.moveTo(left, y(0));
      ctx.lineTo(left, y(count)); ctx.lineTo(right, y(count));
    });
    ctx.stroke();
  }
  const latest = Math.max(0, ...state.channels.map(row => row.history.length ? row.history[row.history.length - 1][0] : 0));
  const points = rows.flatMap(row => row.history.filter(point => point[0] >= latest - 120));
  const rates = chart($('rate-chart'), 0, Math.max(1, ...points.map(point => point[1])) * 1.1, number, false, -120);
  for (const row of rows) {
    const {ctx, x, y} = rates;
    ctx.strokeStyle = colors[row.channel - 1]; ctx.lineWidth = 1.7; ctx.beginPath();
    let first = true;
    for (const [t, cps] of row.history) {
      if (t < latest - 120) continue;
      if (first) ctx.moveTo(x(t - latest), y(cps)); else ctx.lineTo(x(t - latest), y(cps));
      first = false;
    }
    ctx.stroke();
  }
}

function render() {
  const rows = state.channels;
  const stale = state.age_s !== null && state.age_s > 3;
  const live = state.phase === 'running' && !stale;
  $('connection').textContent = state.error || (live ? '● Receiving' : stale ? 'Waiting for data…' : state.phase === 'starting' ? 'Starting acquisition…' : state.phase === 'complete' ? 'Acquisition complete' : state.phase);
  $('connection').className = `connection ${live ? 'live' : 'warn'}`;
  $('rate').textContent = stale ? '—' : number(rows.reduce((n, row) => n + row.cps, 0));
  $('accepted').textContent = number(rows.reduce((n, row) => n + row.accepted, 0));
  $('rejected').textContent = number(rows.reduce((n, row) => n + row.rejected, 0));
  $('drops').textContent = state.status.fifo_dropped_events == null ? '—' : number(state.status.fifo_dropped_events);
  const key = rows.map(row => row.channel).join(',');
  if (channelKey !== key) {
    channelKey = key; $('channels').replaceChildren();
    for (const row of rows) {
      const label = document.createElement('label'); label.className = 'channel';
      const checkbox = document.createElement('input'); checkbox.type = 'checkbox'; checkbox.checked = selected.has(row.channel);
      checkbox.setAttribute('aria-label', `Show input ${row.channel}`);
      checkbox.onchange = () => { if (checkbox.checked) selected.add(row.channel); else selected.delete(row.channel); draw(); };
      const swatch = document.createElement('span'); swatch.className = `swatch ch${row.channel}`;
      const info = document.createElement('span');
      const title = document.createElement('strong'); title.textContent = `IN${row.channel}`;
      const detail = document.createElement('small'); detail.id = `detail-${row.channel}`;
      info.append(title, detail); label.append(checkbox, swatch, info); $('channels').append(label);
    }
  }
  for (const row of rows) $('detail-' + row.channel).textContent = `${stale ? '—' : number(row.cps)} cps · ${number(row.live_fraction * 100)}% live`;
  const under = rows.reduce((n, row) => n + row.underflow, 0), over = rows.reduce((n, row) => n + row.overflow, 0);
  $('range-note').textContent = `${state.histogram_bins} bins · ${number(under)} below range · ${number(over)} above range`;
  const elapsed = Math.max(0, ...rows.map(row => row.history.length ? row.history[row.history.length - 1][0] : 0));
  const gaps = state.status.sequence_gaps || 0;
  $('run-info').textContent = `${number(elapsed)} s acquired · ${number(gaps)} sequence gaps · ${state.recording ? 'Raw recording: ' + state.recording : 'Raw recording off'}`;
  draw();
}

async function refresh() {
  try {
    const response = await fetch('/api/state', {cache: 'no-store', signal: AbortSignal.timeout(3000)});
    if (!response.ok) throw new Error('Dashboard unavailable');
    state = await response.json(); render();
  } catch {
    $('connection').textContent = 'Receiver disconnected'; $('connection').className = 'connection warn';
    $('rate').textContent = '—';
    document.querySelectorAll('.channel small').forEach(element => { element.textContent = 'Disconnected'; });
  } finally { setTimeout(refresh, 500); }
}
$('log-scale').onchange = draw;
window.addEventListener('resize', draw);
refresh();
