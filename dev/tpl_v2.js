/* ====================================================================
 * v2 -- the anatomy layer on top of the Morphic world:
 *   scene graph (parents, frames, boundaries, connections), hierarchy
 *   drill-down, internals that appear when you select their organ,
 *   depth ordering + soft shading + skin veil, vessel legend,
 *   a schematic physiology timeline, and approximate cross-sections.
 * All of it reads WORLD0.scene / physiology / validation, which Ruby wrote.
 * ================================================================== */
const SC = WORLD0.scene || {}, PHYS0 = WORLD0.physiology || { params: {}, waves: {}, coupling: {} };
const VAL = WORLD0.validation || { checks: [], pass: 0, warn: 0, fail: 0 }, LEG = WORLD0.legend || [];
const MM_PER_PX = WORLD0.px_mm || 2.19, CM_PER_PX = MM_PER_PX / 10, PX_PER_CM = 1 / CM_PER_PX;
const REGS = {}; for (const r of WORLD0.regions || []) REGS[r.id] = r;
const KIDS = {};
for (const id of Object.keys(SC)) { const p = SC[id].parent; if (p) (KIDS[p] = KIDS[p] || []).push(id); }
for (const p in KIDS) if (KIDS[p].every((c) => SC[c].diam)) KIDS[p].sort((a, b) => SC[b].diam[0] - SC[a].diam[0]);
const KIND_COLOR = {}; for (const l of LEG) KIND_COLOR[l.kind] = l.color;
const SYS_ORDER = ['organs', 'arteries', 'veins', 'pulmonary', 'nerves', 'skeleton', 'muscles', 'skin'];
const V2 = { treeMode: 'systems', shade: true, focus: false, reveal: false, skin: 0, legend: true, kindFocus: null,
  aOpen: new Set(['rg_thorax', 'rg_abdomen']), lastKid: {}, ready: false };
let MBY = {};
const sid = (m) => { const i = typeof m === 'string' ? m : m.id; return SC[i] ? i : i.replace(/_copy\d+$/, ''); };
const labelOf = (id) => (REGS[id] ? REGS[id].label : MBY[id] ? MBY[id]._.label : (id || '').replace(/^[a-z]+_/, ''));
const mk = (tag, cls, txt) => { const e = document.createElement(tag); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; };
const frac = (v) => v - Math.floor(v);
const parentOf = (id) => (SC[id] ? SC[id].parent : null);
function ownerOf(id) { let n = SC[id], g = 0; while (n && n.internal && n.parent && SC[n.parent] && g++ < 20) { id = n.parent; n = SC[id]; } return id; }
function ancestry(id) { const a = []; let g = 0; while (id && g++ < 40) { a.push(id); id = parentOf(id) || (REGS[id] && REGS[id].parent); } return a.reverse(); }
function descendants(id, out = new Set()) { for (const c of KIDS[id] || []) { out.add(c); descendants(c, out); } return out; }
const curId = () => (W.sel && isMorph(W.sel) ? sid(W.sel) : null);
function selectId(id, opts) { const m = MBY[id]; if (m) { select(m, opts || {}); return true; } if (REGS[id]) say(`${REGS[id].label} is a body region (not a drawn piece) - press > to go inside it`); return false; }

/* ------------------------------------------------ build / rebuild hook */
function v2Build() {
  MBY = {}; for (const m of allMorphs()) MBY[m.id] = m;
  const defs = $('#stage defs');
  if (!$('#shadeG')) {
    const g = svg('radialGradient', { id: 'shadeG', cx: '.36', cy: '.3', r: '.85' }, defs);
    svg('stop', { offset: '0', 'stop-color': '#fff', 'stop-opacity': '.34' }, g); svg('stop', { offset: '.42', 'stop-color': '#fff', 'stop-opacity': '0' }, g);
    svg('stop', { offset: '1', 'stop-color': '#1c0e24', 'stop-opacity': '.30' }, g);
    const cp = svg('clipPath', { id: 'slclip', clipPathUnits: 'userSpaceOnUse' }, defs); V2.clipRect = svg('rect', { x: -9999, y: -9999, width: 99999, height: 99999 }, cp);
    V2.probe = svg('path', { d: 'M0 0' }, defs);
  }
  // depth order: back-to-front by mean depth, so the liver sits in front of the right kidney
  const org = W.layerById.organs;
  if (org) { org.morphs.sort((a, b) => (SC[sid(b)] ? SC[sid(b)].z : 0.5) - (SC[sid(a)] ? SC[sid(a)].z : 0.5)); for (const m of org.morphs) org.items.appendChild(m.g); }
  if (W.layerById.skin) W.layerById.skin.items.id = 'skin-items';
  for (const m of allMorphs()) { m.concealed = false; m.shade = null; m.fxv = null; }
  // soft shading on the big solid organs
  if (org) for (const m of org.morphs) {
    const n = SC[sid(m)]; if (!n || n.internal || m._.fill === 'none' || !n.size_mm || Math.min(n.size_mm[0], n.size_mm[1]) < 38) continue;
    m.shade = svg('path', { class: 'shade', fill: 'url(#shadeG)', 'pointer-events': 'none', d: m.shape.d }); m.ag.insertBefore(m.shade, m.el.nextSibling);
  }
  buildFx(); buildOcclusion();
  // overlays that sit above every layer: skin veil, slice marks
  V2.veil = svg('g', { id: 'veilg', 'pointer-events': 'none' }, vp); V2.veilUse = svg('use', { href: '#skin-items' }, V2.veil);
  V2.slfx = svg('g', { id: 'slicefx', 'pointer-events': 'none' }, vp);
  V2.ready = true;
  for (const m of allMorphs()) m.apply();
  updateVeil(); applyConceal(); updateDim(); drawCrumbs(); sliceUpdate(true); if (PH.open) renderPhys();
}
// back vessels of the right kidney are hidden where the liver covers them
const OCC = [{ front: 'or_liver', back: ['ar_renal_r', 've_renal_r', 'ar_kid_r', 've_kid_r'] }];
function buildOcclusion() {
  for (const o of OCC) {
    const f = MBY[o.front]; if (!f) continue;
    let id = 'occ_' + o.front; const old = $('#' + id); if (old) old.remove();
    const cp = svg('clipPath', { id, clipPathUnits: 'userSpaceOnUse' }, $('#stage defs'));
    svg('path', { d: `M-9999 -9999H99999V99999H-9999Z${f.shape.d}`, 'clip-rule': 'evenodd' }, cp);
    for (const m of allMorphs()) if (o.back.some((p) => m.id.startsWith(p))) m.ag.setAttribute('clip-path', `url(#${id})`);
  }
}

/* patches: the shade follows its organ; fx follow their vessel; veil follows the skin layer */
const _mApply = Morph.prototype.apply;
Morph.prototype.apply = function () {
  _mApply.call(this);
  if (this.shade) { if (this.shade.getAttribute('d') !== this.shape.d) this.shade.setAttribute('d', this.shape.d); this.shade.setAttribute('opacity', this._.opacity); }
  if (this.fxv) { this.fxv.g.setAttribute('transform', this.g.getAttribute('transform')); this.fxv.g.classList.toggle('off', !this._.visible); }
};
const _lApply = Layer.prototype.apply;
Layer.prototype.apply = function () { _lApply.call(this); if (this.id === 'skin' && V2.ready) updateVeil(); };
function updateVeil() {
  const sk = W.layerById.skin; if (!sk || !V2.veil) return;
  const on = V2.skin > 0.01 && sk.shown && W.explode < 8;
  V2.veil.setAttribute('display', on ? 'inline' : 'none'); V2.veil.setAttribute('opacity', V2.skin * sk._.opacity);
  V2.veil.setAttribute('transform', sk.g.getAttribute('transform') || '');
  V2.slfx.setAttribute('display', W.explode < 8 ? 'inline' : 'none');
}
function setSkin(v) { V2.skin = clamp(+v, 0, 1); $('#skin').value = Math.round(V2.skin * 100); $('#skinVal').textContent = Math.round(V2.skin * 100) + '%'; updateVeil(); }
$('#skin').addEventListener('input', (e) => setSkin(e.target.value / 100));

/* ------------------------------------------- selection ownership & focus */
function applyConceal() {
  const sel = curId(), own = sel ? ownerOf(sel) : null;
  for (const m of allMorphs()) {
    const i = sid(m), n = SC[i];
    const c = !!(n && n.internal && !V2.reveal && ownerOf(i) !== own);
    if (c !== m.concealed) { m.concealed = c; m.g.classList.toggle('concealed', c); if (m.fxv) m.fxv.g.classList.toggle('concealed', c); }
  }
}
function updateDim() {
  const sel = curId(); let keep = null;
  if (V2.focus && sel) { keep = new Set(ancestry(sel)); keep.add(sel); descendants(sel, keep); }
  for (const m of allMorphs()) {
    const i = sid(m), n = SC[i];
    let dim = keep ? !keep.has(i) : false;
    if (V2.kindFocus && !(n && n.kind === V2.kindFocus)) dim = true;
    m.g.classList.toggle('fdim', dim); if (m.fxv) m.fxv.g.classList.toggle('fdim', dim);
  }
}
function v2Select() { applyConceal(); updateDim(); drawCrumbs(); sliceDimUpdate(); if (V2.treeMode === 'anatomy') anatomyReveal(); }

/* ---------------------------------------------- breadcrumbs & drilling */
function drawCrumbs() {
  const box = $('#crumbs'); box.textContent = '';
  const id = curId();
  if (!id) { box.append(mk('span', 'c cur', 'Body'), mk('span', 'hintc', '  select a structure · > goes inside it · < goes up')); return; }
  let path = ancestry(id);
  if (path.length > 6) path = ['…'].concat(path.slice(-5));
  path.forEach((p, i) => {
    if (i) box.append(mk('span', 'sep', '›'));
    if (p === '…') { box.append(mk('span', 'c', '…')); return; }
    const b = mk('span', 'c' + (i === path.length - 1 ? ' cur' : '') + (REGS[p] ? ' reg' : ''), labelOf(p));
    if (!REGS[p]) b.addEventListener('click', () => selectId(p)); box.append(b);
  });
  const k = (KIDS[id] || []).length, n = SC[id];
  const hier = n && n.hierarchy ? ` (${n.hierarchy})` : '';
  box.append(mk('span', 'hintc', k ? `${hier}  ·  ${k} part${k > 1 ? 's' : ''} inside · press >` : `${hier}  ·  smallest piece · < goes up`));
}
function drillDown(c = 1) {
  let id = curId(); let moved = false;
  for (let i = 0; i < c; i++) {
    let kids = id ? KIDS[id] : null;
    if (!id) { const r = (WORLD0.regions || []).find((x) => (KIDS[x.id] || []).length && x.id !== 'rg_body'); kids = r ? KIDS[r.id] : []; }
    if (!kids || !kids.length) { if (!moved) say(`${labelOf(id)} is the smallest piece drawn - press < to go back up`); break; }
    const pick = (id && V2.lastKid[id] && kids.includes(V2.lastKid[id])) ? V2.lastKid[id] : kids[0]; id = pick; moved = true;
  }
  if (moved) { selectId(id); say(`${ancestry(id).map(labelOf).join(' › ')}`); }
}
function drillUp(c = 1) {
  let id = curId(); if (!id) return say('nothing selected');
  for (let i = 0; i < c; i++) {
    const p = parentOf(id);
    if (!p || REGS[p]) { say(`${labelOf(id)} is top-level in the ${REGS[p] ? REGS[p].label.toLowerCase() : 'body'} - nothing above it to select`); break; }
    V2.lastKid[p] = id; id = p;
  }
  selectId(id); say(ancestry(id).map(labelOf).join(' › '));
}
function nextSibling(dir = 1, c = 1) {
  const id = curId(); if (!id) return; const sib = KIDS[parentOf(id)] || [id]; let i = sib.indexOf(id);
  i = ((i + dir * c) % sib.length + sib.length) % sib.length; V2.lastKid[parentOf(id)] = sib[i]; selectId(sib[i]); say(`${i + 1}/${sib.length} in ${labelOf(parentOf(id))}`);
}

/* --------------------------------------------------------- inspector */
function chip(id, text, title) {
  const b = mk('button', 'chip', text || labelOf(id)); b.type = 'button'; if (title) b.title = title;
  if (MBY[id]) b.addEventListener('click', () => select(MBY[id], { scroll: false }));
  else b.disabled = true;
  return b;
}
const FLOW_TXT = { artery: 'away from the heart', pulm_a: 'from the heart to the lungs', vein: 'towards the heart', pulm_v: 'from the lungs to the heart', portal: 'from the gut to the liver', hepatic_a: 'into the liver', bile: 'out of the liver', nerve: 'away from the brain / cord' };
function v2Inspector(target) {
  const id = sid(target), n = SC[id]; if (!n) return;
  const h = mk('h3', '', 'anatomy · scene graph'); insBody.appendChild(h);
  const row = (l, ctl) => mkRow(l, [].concat(ctl), 'sg');
  const par = parentOf(id);
  row('parent', REGS[par] ? mk('span', 'sgt', `${REGS[par].label} (region)`) : chip(par));
  row('path', mk('span', 'sgt', ancestry(id).map(labelOf).join(' › ')));
  const ks = KIDS[id] || [];
  row('children', ks.length ? [...ks.slice(0, 8).map((c) => chip(c)), ...(ks.length > 8 ? [mk('span', 'sgt', `+${ks.length - 8} more`)] : [])] : mk('span', 'sgt', 'none (smallest piece)'));
  const f = n.frame || {};
  row('frame', mk('span', 'sgt', f.origin ? `origin (${f.origin[0]}, ${f.origin[1]}) px · depth ${f.origin[2]}   [x right, y down, z 0 = front → 1 = back]` : '-'));
  if (f.offset) row('offset', mk('span', 'sgt', `from parent: ${r2(f.offset[0] * MM_PER_PX)} mm across, ${r2(f.offset[1] * MM_PER_PX)} mm down, ${r2(f.offset[2])} depth`));
  const b = n.boundary || {};
  row('boundary', mk('span', 'sgt', `${b.type || '-'} · ${b.pts ? b.pts.length : 0} points · ${n.size_mm ? n.size_mm[0] + ' × ' + n.size_mm[1] + ' mm' : ''}`));
  if (n.depth) row('depth', mk('span', 'sgt', n.depth.map((d) => `${d[0]} → ${d[1]}`).join(', ') + `  (z-order ${n.z})`));
  row('tissue', mk('span', 'sgt', `${n.system} · ${n.kind}${n.hierarchy ? ' · ' + n.hierarchy : ''}${n.internal ? ' · inside ' + labelOf(ownerOf(id)) : ''}`));
  if (n.diam) row('vessel', mk('span', 'sgt', `${n.diam[0]} → ${n.diam[1]} mm wide${n.level != null ? ' · branch level ' + n.level : ''}${n.len ? ' · ' + n.len + ' mm long' : ''}${n.flow && FLOW_TXT[n.kind] ? ' · flow ' + FLOW_TXT[n.kind] : ''}${n.dist ? ' · ' + r2(n.dist * MM_PER_PX / 10) + ' cm from ' + (n.kind === 'nerve' ? 'the brain/cord' : 'the heart') : ''}`));
  const cs = (n.connections || []);
  if (cs.length) row('connections', [...cs.slice(0, 14).map((c) => chip(c.to, `${c.kind}: ${labelOf(c.to)}`, c.dir)), ...(cs.length > 14 ? [mk('span', 'sgt', `+${cs.length - 14} more`)] : [])]);
}

/* ------------------------------------------------- anatomy tree tab */
function aRows(id, depth, out, q) {
  const ks = KIDS[id] || [];
  for (const c of ks) { out.push({ id: c, depth }); if (V2.aOpen.has(c) && (KIDS[c] || []).length) aRows(c, depth + 1, out); }
}
function v2RenderAnatomy() {
  const box = $('#treeWrap'); box.textContent = ''; const q = $('#filter').value.toLowerCase();
  const mkRowEl = (id, depth, flat) => {
    const n = SC[id], k = (KIDS[id] || []).length;
    const r = mk('div', 'ai'); r.dataset.id = id; r.style.paddingLeft = (8 + depth * 12) + 'px';
    const ar = mk('span', 'ar', k && !flat ? (V2.aOpen.has(id) ? '▾' : '▸') : ' ');
    ar.addEventListener('click', (e) => { e.stopPropagation(); if (!k) return; V2.aOpen.has(id) ? V2.aOpen.delete(id) : V2.aOpen.add(id); v2RenderAnatomy(); });
    const lb = mk('span', 'lb', labelOf(id)); r.append(ar, lb);
    if (k) r.append(mk('span', 'kc', k));
    if (flat && n) r.append(mk('span', 'kc', labelOf(n.parent)));
    r.addEventListener('click', () => { if (REGS[id]) { if (k) { V2.aOpen.has(id) ? V2.aOpen.delete(id) : V2.aOpen.add(id); v2RenderAnatomy(); } } else select(MBY[id], { scroll: false }); });
    if (MBY[id] && W.sel === MBY[id]) r.classList.add('sel'); if (MBY[id] && !MBY[id]._.visible) r.classList.add('off');
    box.appendChild(r);
  };
  if (q) {
    const hits = Object.keys(SC).filter((i) => MBY[i] && (labelOf(i).toLowerCase().includes(q) || i.includes(q))).slice(0, 80);
    hits.forEach((i) => mkRowEl(i, 0, true)); if (!hits.length) box.appendChild(mk('div', 'ai', 'no match'));
    return;
  }
  for (const r of WORLD0.regions || []) {
    if (r.id === 'rg_body' || !(KIDS[r.id] || []).length) continue;
    mkRowEl(r.id, 0, false);
    if (V2.aOpen.has(r.id)) { const rows = []; aRows(r.id, 1, rows); rows.slice(0, 400).forEach((x) => mkRowEl(x.id, x.depth, false)); }
  }
  const s = $('#treeWrap .ai.sel'); if (s) s.scrollIntoView({ block: 'nearest' });
}
function anatomyReveal() {
  const id = curId(); if (!id) return v2RenderAnatomy();
  ancestry(id).slice(0, -1).forEach((a) => { if (!REGS[a] || a !== 'rg_body') V2.aOpen.add(a); }); v2RenderAnatomy();
}
function setTreeMode(m) {
  V2.treeMode = m; $('#tabSys').classList.toggle('on', m === 'systems'); $('#tabAna').classList.toggle('on', m === 'anatomy');
  renderTree(); if (m === 'anatomy') anatomyReveal();
}
$('#tabSys').addEventListener('click', () => setTreeMode('systems')); $('#tabAna').addEventListener('click', () => setTreeMode('anatomy'));

/* ----------------------------------------------------- legend panel */
function buildLegend() {
  const box = $('#legend'); box.textContent = '';
  const h = mk('div', 'lh'); h.append(mk('b', '', 'Legend')); const x = mk('span', 'x', '×'); x.title = 'hide'; x.addEventListener('click', () => setLegend(false)); h.append(x); box.append(h);
  for (const l of LEG) {
    const r = mk('div', 'lr'); r.dataset.kind = l.kind;
    const sw = mk('i'); sw.style.background = l.color; r.append(sw, mk('span', '', l.label)); r.title = 'click: highlight only this kind';
    r.addEventListener('click', () => { V2.kindFocus = V2.kindFocus === l.kind ? null : l.kind; box.querySelectorAll('.lr').forEach((e) => e.classList.toggle('on', e.dataset.kind === V2.kindFocus)); updateDim(); });
    box.append(r);
  }
  const f = mk('div', 'lr plain'); f.innerHTML = '<i class="arrow">▶</i><span>Small arrows show which way blood (or a nerve signal) flows</span>'; box.append(f);
}
function setLegend(on) { V2.legend = on; $('#legend').style.display = on ? 'block' : 'none'; $('#cLegend').checked = on; }
$('#cLegend').addEventListener('change', (e) => setLegend(e.target.checked));
$('#cShade').addEventListener('change', (e) => { V2.shade = e.target.checked; stage.classList.toggle('noshade', !V2.shade); });
$('#cFocus').addEventListener('change', (e) => { V2.focus = e.target.checked; updateDim(); });

/* =============================================== physiology (schematic) */
const P = PHYS0.params || {}, WV = PHYS0.waves || {}, CPL = PHYS0.coupling || {};
const pv = (k, d) => (P[k] ? P[k].value : d);
const PH = { open: false, playing: false, t: 0, speed: 1, hr: pv('heart_rate', 72), rr: pv('respiratory_rate', 15),
  on: { heart: true, breath: true, nerve: true, portal: true, flow: true }, raf: 0, last: 0, lastR: 0, entries: [], targets: [] };
const interp = (arr, ph) => { if (!arr || !arr.length) return 0; const n = arr.length, x = frac(ph) * n, i = Math.floor(x) % n, f = x - Math.floor(x); return arr[i] * (1 - f) + arr[(i + 1) % n] * f; };
// pulsatile flow: velocity profile from the arterial pulse, normalised so the average speed is 1
const VPROF = (WV.arterial_pulse || [1]).map((a) => 0.25 + a);
const VMEAN = VPROF.reduce((a, b) => a + b, 0) / VPROF.length; const VCUM = [0];
for (let i = 0; i < VPROF.length; i++) VCUM.push(VCUM[i] + VPROF[i] / VMEAN / VPROF.length);
const cumFlow = (b) => { const w = Math.floor(b), x = frac(b) * VPROF.length, i = Math.min(Math.floor(x), VPROF.length - 1); return w + VCUM[i] + (VCUM[i + 1] - VCUM[i]) * (x - i); };
const PULSATILE = new Set(['artery', 'pulm_a', 'hepatic_a']);
const SPEED_PX = { artery: 62, pulm_a: 52, hepatic_a: 34, vein: 40, pulm_v: 38, portal: 36, bile: 12 };
const NERVE_CYCLE = 3.8, PACKET = 15;
const hashOf = (s) => { let h = 7; for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0; return h; };

function polyline(d, orient) {
  V2.probe.setAttribute('d', d); const L = V2.probe.getTotalLength(); if (!(L > 0.5)) return null;
  const nS = clamp(Math.ceil(L / 3.5), 4, 90), pts = [], cum = [];
  for (let i = 0; i <= nS; i++) { const p = V2.probe.getPointAtLength(L * i / nS); pts.push([p.x, p.y]); }
  if (orient < 0) pts.reverse();
  let c = 0; cum.push(0); for (let i = 1; i < pts.length; i++) { c += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]); cum.push(c); }
  return { pts, cum, L: c };
}
function posAt(en, s) {
  const { pts, cum } = en; let lo = 0, hi = cum.length - 1;
  while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (cum[mid] <= s) lo = mid; else hi = mid; }
  const a = pts[lo], b = pts[hi], seg = cum[hi] - cum[lo] || 1, f = clamp((s - cum[lo]) / seg, 0, 1);
  return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, Math.atan2(b[1] - a[1], b[0] - a[0]) * 180 / Math.PI];
}
function buildFx() {
  PH.entries = []; PH.targets = [];
  for (const l of W.layers) l.fx.textContent = '';
  for (const m of allMorphs()) {
    const n = SC[sid(m)]; if (!n || !n.cl || !n.flow || n.internal === undefined) continue;
    if (!(PULSATILE.has(n.kind) || SPEED_PX[n.kind] || n.kind === 'nerve')) continue;
    const pl = polyline(n.cl, n.flow); if (!pl || pl.L < 3) continue;
    const g = svg('g', { class: 'fxv ' + n.kind }, m.layer.fx), a = svg('g', { class: 'fxa' }, g);
    m.fxv = { g, a };
    const col = n.kind === 'nerve' ? '#e0b020' : (KIND_COLOR[n.kind] || '#444'), sw = Math.max(1, m._.strokeWidth);
    const en = { m, n, kind: n.kind, col, sw, pts: pl.pts, cum: pl.cum, L: pl.L, off: hashOf(m.id) % Math.ceil(pl.L), arrows: [], delay: ((n.dist || 0) / (PX_PER_CM * 100)) / pv('pulse_wave_speed', 7), pulsatile: PULSATILE.has(n.kind) };
    const d = 'M' + pl.pts.map((p) => p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join('L');
    if (n.kind === 'nerve') {
      en.sig = svg('path', { class: 'nsig', d, fill: 'none', stroke: '#fff6bd', 'stroke-width': sw + 2.4, 'stroke-linecap': 'round', opacity: 0 }, a);
      en.sig.setAttribute('stroke-dasharray', `${PACKET} ${pl.L + PACKET + 60}`); en.phr = m.id.startsWith('ne_phrenic');
    } else {
      if (en.pulsatile) en.glow = svg('path', { class: 'pglow', d, fill: 'none', stroke: '#fff', 'stroke-width': sw + 0.8, 'stroke-linecap': 'round', opacity: 0 }, a);
      const K = Math.max(1, Math.round(pl.L / 26)), sc = clamp(0.55 + sw * 0.3, 0.7, 1.7);
      for (let k = 0; k < K; k++) en.arrows.push(svg('path', { class: 'arr', d: 'M-2.4 -2.1L2.2 0L-2.4 2.1Z', fill: '#fff', stroke: col, 'stroke-width': 0.7, 'stroke-linejoin': 'round', 'data-sc': sc }, a));
      en.K = K; en.sc = sc;
    }
    PH.entries.push(en);
  }
  // body-motion targets
  const add = (id, part) => { const m = MBY[id]; if (!m) return; (m.__parts = m.__parts || []).push(part); if (!PH.targets.includes(m)) PH.targets.push(m); };
  for (const m of allMorphs()) m.__parts = null;
  if (CPL.heart) for (const id of CPL.heart.ids) add(id, { k: 'heart', c: CPL.heart });
  for (const g of CPL.breath_lung || []) for (const id of g.ids) add(id, { k: 'lung', c: g });
  if (CPL.breath_ribs) for (const id of CPL.breath_ribs.ids) add(id, { k: 'lung', c: CPL.breath_ribs });
  for (const s of CPL.breath_shift || []) add(s.id, { k: 'shift', f: s.f });
}
function scaleAround(c, v) { return `translate(${c.pivot[0]} ${c.pivot[1]}) scale(${(1 + c.sx * v).toFixed(4)} ${(1 + c.sy * v).toFixed(4)}) translate(${-c.pivot[0]} ${-c.pivot[1]})`; }

function phaseInfo() {
  const Tb = 60 / PH.hr, Tr = 60 / PH.rr, b = PH.t / Tb, r = PH.t / Tr, sf = pv('systole_fraction', 0.37), isf = pv('inspiration_share', 0.4);
  return { Tb, Tr, b, r, hp: frac(b), rp: frac(r), sys: frac(b) < sf, insp: frac(r) < isf, sf, isf, beats: Math.floor(b) };
}
function renderPhys() {
  const q = phaseInfo(), sq = PH.on.heart ? interp(WV.ventricle_squeeze, q.hp) : 0, vol = PH.on.breath ? interp(WV.lung_volume, q.rp) : 0;
  const travel = pv('diaphragm_travel', 1.5) * PX_PER_CM;
  for (const m of PH.targets) {
    let s = '';
    for (const p of m.__parts) {
      if (p.k === 'heart') s += scaleAround(p.c, sq); else if (p.k === 'lung') s += scaleAround(p.c, vol);
      else if (p.k === 'shift') s += `translate(0 ${(p.f * travel * vol * 1.3).toFixed(2)})`;
    }
    if (s !== m.__tf) { m.__tf = s; m.ag.setAttribute('transform', s); if (m.fxv) m.fxv.a.setAttribute('transform', s); }
  }
  const pvPortal = SPEED_PX.portal * pv('portal_flow', 1100) / 1100;
  for (const en of PH.entries) {
    const m = en.m; if (m.concealed || !m._.visible || !m.layer.shown) continue;
    if (en.kind === 'nerve') {
      if (!PH.on.nerve) { en.sig.setAttribute('opacity', 0); continue; }
      const v = pv('nerve_display_speed', 330); let tau = frac(PH.t / NERVE_CYCLE) * NERVE_CYCLE;
      if (en.phr) { const travel2 = ((en.n.dist || 0) + en.L) / v, Tr = q.Tr; tau = frac((PH.t + travel2) / Tr) * Tr; }
      const s = tau * v - (en.n.dist || 0), vis = s >= 0 && s <= en.L + PACKET;
      en.sig.setAttribute('opacity', vis ? 1 : 0); if (vis) en.sig.setAttribute('stroke-dashoffset', (PACKET - s).toFixed(1));
      continue;
    }
    const doFlow = PH.on.flow && (en.kind !== 'portal' || PH.on.portal) && (en.kind !== 'hepatic_a' || PH.on.portal);
    const speed = en.kind === 'portal' ? pvPortal : SPEED_PX[en.kind];
    let D;
    if (en.pulsatile && PH.on.heart) D = speed * q.Tb * cumFlow(q.b); else D = speed * PH.t;
    for (let k = 0; k < en.arrows.length; k++) {
      const a = en.arrows[k];
      if (!doFlow) { a.setAttribute('opacity', 0); continue; }
      const s = (D + en.off + k * en.L / en.K) % en.L, p = posAt(en, s);
      a.setAttribute('transform', `translate(${p[0].toFixed(1)} ${p[1].toFixed(1)}) rotate(${p[2].toFixed(0)}) scale(${en.sc})`);
      a.setAttribute('opacity', 0.95);
    }
    if (en.glow) {
      const a = PH.on.heart ? interp(WV.arterial_pulse, q.b - en.delay / q.Tb) : 0, g = clamp((a - 0.3) / 0.7, 0, 1);
      en.glow.setAttribute('opacity', (g * 0.8).toFixed(2));
    }
  }
  updatePanel(q);
}
function physFrame(ts) {
  if (!PH.playing) return;
  PH.raf = requestAnimationFrame(physFrame);
  if (!PH.last) PH.last = ts; const dt = (ts - PH.last) / 1000; if (ts - PH.lastR < 30) return;
  PH.last = ts; PH.lastR = ts; PH.t += Math.min(dt, 0.15) * PH.speed; renderPhys();
}
function physOpen(on) {
  PH.open = on; stage.classList.toggle('phys-on', on); $('#tl').style.display = on ? 'block' : 'none'; $('#bTl').classList.toggle('on', on); dockLayout();
  if (on) renderPhys(); else { physPlay(false); for (const m of PH.targets) { m.__tf = null; m.ag.removeAttribute('transform'); if (m.fxv) m.fxv.a.removeAttribute('transform'); } }
}
function physPlay(on) {
  if (on === undefined) on = !PH.playing; if (on && !PH.open) physOpen(true);
  PH.playing = on; cancelAnimationFrame(PH.raf); PH.last = 0; $('#tlPlay').textContent = on ? '❚❚' : '▶'; $('#tlPlay').title = on ? 'Pause (space)' : 'Play (space)';
  if (on) PH.raf = requestAnimationFrame(physFrame); else if (PH.open) renderPhys();
}
function physStep(dir, c = 1) { if (!PH.open) physOpen(true); physPlay(false); const dt = 60 / PH.hr / 20; PH.t = Math.max(0, PH.t + dir * dt * c); renderPhys(); }
function physSetTime(t) { PH.t = Math.max(0, +t || 0); if (PH.open) renderPhys(); }
function physSetPhase(ph) { const Tb = 60 / PH.hr; PH.t = (Math.floor(PH.t / Tb) + clamp(ph, 0, 0.999)) * Tb; if (PH.open) renderPhys(); }
function physReplay() { PH.t = 0; physPlay(true); }
function setHr(v) { PH.hr = clamp(Math.round(+v), 60, 100); $('#tlHr').value = PH.hr; $('#tlHrV').textContent = PH.hr + ' bpm'; if (PH.open) renderPhys(); }
function setRr(v) { PH.rr = clamp(Math.round(+v), 12, 20); $('#tlRr').value = PH.rr; $('#tlRrV').textContent = PH.rr + ' /min'; if (PH.open) renderPhys(); }

/* timeline panel: wave traces + phase labels */
const tlc = $('#tlc'), tlx = tlc.getContext('2d');
function trace(y0, h, arr, ph, col, label, fill) {
  const w = tlc.width - 74, x0 = 70; tlx.save();
  tlx.fillStyle = '#5b6678'; tlx.font = '10.5px system-ui,sans-serif'; tlx.fillText(label, 4, y0 + h / 2 + 3);
  tlx.strokeStyle = '#e1e6ee'; tlx.strokeRect(x0, y0, w, h);
  if (fill) { tlx.fillStyle = fill.col; tlx.fillRect(x0, y0, w * fill.w, h); }
  tlx.beginPath(); const n = arr.length; for (let i = 0; i <= n; i++) { const v = arr[i % n]; const x = x0 + w * i / n, y = y0 + h - 3 - (h - 6) * v; i ? tlx.lineTo(x, y) : tlx.moveTo(x, y); }
  tlx.strokeStyle = col; tlx.lineWidth = 1.8; tlx.stroke();
  const px = x0 + w * ph; tlx.strokeStyle = '#1b212c'; tlx.lineWidth = 1.4; tlx.beginPath(); tlx.moveTo(px, y0 - 2); tlx.lineTo(px, y0 + h + 2); tlx.stroke(); tlx.restore();
}
function updatePanel(q) {
  tlx.clearRect(0, 0, tlc.width, tlc.height);
  trace(4, 30, WV.arterial_pulse || [0], q.hp, '#d1222f', 'heart · pulse', { col: 'rgba(209,34,47,.10)', w: q.sf });
  trace(38, 30, WV.lung_volume || [0], q.rp, '#1d6fb8', 'breathing', { col: 'rgba(29,111,184,.10)', w: q.isf });
  trace(72, 30, WV.action_potential || [0], frac(PH.t / NERVE_CYCLE), '#c99a10', 'nerve signal');
  $('#tlT').textContent = `t = ${PH.t.toFixed(2)} s`; $('#tlScrub').value = Math.round(q.hp * 1000);
  $('#tlPh').innerHTML = `<div><b>Heart</b> ${PH.hr} bpm: <span class="ph">${q.sys ? 'systole - the ventricles squeeze' : 'diastole - the ventricles fill'}</span> (beat phase ${q.hp.toFixed(2)})</div>` +
    `<div><b>Breathing</b> ${PH.rr}/min: <span class="ph">${q.insp ? 'inspiration - diaphragm moves down, lungs widen' : 'expiration - diaphragm rises, lungs recoil'}</span></div>` +
    `<div><b>Nerve</b> signal ${Math.round(pv('nerve_display_speed', 330))} px/s on screen (real: ~${pv('nerve_speed', 60)} m/s)</div>`;
}
function buildPanel() {
  const t = $('#tlParams'); t.textContent = '';
  for (const k of Object.keys(P)) { const p = P[k]; const r = mk('div'); r.textContent = `${p.label}: ${p.value} ${p.unit}${p.range ? ' (typical ' + p.range[0] + '-' + p.range[1] + ')' : ''}`; t.append(r); }
  const s = mk('div', 'src', PHYS0.source || ''); t.append(s);
  $('#tlDisc').textContent = (PHYS0.disclaimer || 'Schematic animation.') + ' Movements are exaggerated for visibility and nerve signals are drawn about 100 times slower than real ones.';
}
$('#tlPlay').onclick = () => physPlay(); $('#tlRe').onclick = () => physReplay(); $('#tlBk').onclick = () => physStep(-1); $('#tlFw').onclick = () => physStep(1);
$('#tlClose').onclick = () => physOpen(false); $('#bTl').onclick = () => physOpen(!PH.open);
$('#tlSpd').onchange = (e) => { PH.speed = +e.target.value; };
$('#tlHr').oninput = (e) => setHr(e.target.value); $('#tlRr').oninput = (e) => setRr(e.target.value);
$('#tlScrub').oninput = (e) => { physPlay(false); physSetPhase(e.target.value / 1000); };
for (const k of ['heart', 'breath', 'nerve', 'flow', 'portal']) $('#tc_' + k).onchange = (e) => { PH.on[k] = e.target.checked; if (PH.open) renderPhys(); };

/* ================================================= cross-sections */
const SL = { mode: 'off', pos: { axial: 250, sagittal: 200, coronal: 0.4 }, clip: false, keep: 1, dim: true, hits: [], list: [] };
const LANDMARKS = [[0, 'head'], [125, 'neck'], [152, 'upper chest (thorax)'], [210, 'mid chest (thorax)'], [250, 'upper abdomen'], [300, 'lower abdomen'], [340, 'pelvis'], [410, 'thighs'], [600, 'lower legs'], [790, 'feet']];
const landmark = (y) => { let r = LANDMARKS[0][1]; for (const l of LANDMARKS) if (y >= l[0]) r = l[1]; return r; };
function polysOf(m) {
  if (m.__pd === m.shape.d) return m.__polys;
  const toks = (m.shape.d || '').match(/[MLCQHVAZ]|-?\d*\.?\d+(?:e-?\d+)?/gi) || []; const subs = []; let cur = null, x = 0, y = 0, sx = 0, sy = 0, i = 0, cmd = '';
  const num = () => parseFloat(toks[i++]); const push = (px, py) => { cur.pts.push([px, py]); x = px; y = py; };
  const bez = (c) => { const [x0, y0] = [x, y]; for (let t = 0.25; t <= 1.001; t += 0.25) { const u = 1 - t; let px, py; if (c.length === 6) { px = u * u * u * x0 + 3 * u * u * t * c[0] + 3 * u * t * t * c[2] + t * t * t * c[4]; py = u * u * u * y0 + 3 * u * u * t * c[1] + 3 * u * t * t * c[3] + t * t * t * c[5]; } else { px = u * u * x0 + 2 * u * t * c[0] + t * t * c[2]; py = u * u * y0 + 2 * u * t * c[1] + t * t * c[3]; } cur.pts.push([px, py]); } x = c[c.length - 2]; y = c[c.length - 1]; };
  while (i < toks.length) {
    if (/[A-Za-z]/.test(toks[i])) cmd = toks[i++];
    if (cmd === 'M') { x = num(); y = num(); cur = { pts: [[x, y]], closed: false }; subs.push(cur); sx = x; sy = y; cmd = 'L'; }
    else if (cmd === 'L') push(num(), num());
    else if (cmd === 'H') push(num(), y); else if (cmd === 'V') push(x, num());
    else if (cmd === 'C') bez([num(), num(), num(), num(), num(), num()]); else if (cmd === 'Q') bez([num(), num(), num(), num()]);
    else if (cmd === 'A') arcPts(cur, x, y, num(), num(), num(), num(), num(), num(), num()), (x = cur.pts[cur.pts.length - 1][0], y = cur.pts[cur.pts.length - 1][1]);
    else if (cmd === 'Z') { if (cur) { cur.closed = true; x = sx; y = sy; } cmd = ''; }
    else i++;
  }
  m.__pd = m.shape.d; m.__polys = subs; return subs;
}
function arcPts(cur, x1, y1, rx, ry, phi, fa, fs, x2, y2) {
  if (!rx || !ry) { cur.pts.push([x2, y2]); return; }
  const ph = phi * Math.PI / 180, c = Math.cos(ph), s = Math.sin(ph), dx = (x1 - x2) / 2, dy = (y1 - y2) / 2, x1p = c * dx + s * dy, y1p = -s * dx + c * dy;
  rx = Math.abs(rx); ry = Math.abs(ry); const lam = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry); if (lam > 1) { rx *= Math.sqrt(lam); ry *= Math.sqrt(lam); }
  const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p, den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
  const co = (fa === fs ? -1 : 1) * Math.sqrt(Math.max(0, num / den)), cxp = co * rx * y1p / ry, cyp = -co * ry * x1p / rx;
  const cx = c * cxp - s * cyp + (x1 + x2) / 2, cy = s * cxp + c * cyp + (y1 + y2) / 2;
  const ang = (ux, uy, vx, vy) => { const a = Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy); return a; };
  const th1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry); let dth = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
  if (!fs && dth > 0) dth -= 2 * Math.PI; else if (fs && dth < 0) dth += 2 * Math.PI;
  for (let k = 1; k <= 10; k++) { const t = th1 + dth * k / 10, ex = rx * Math.cos(t), ey = ry * Math.sin(t); cur.pts.push([c * ex - s * ey + cx, s * ex + c * ey + cy]); }
}
// intersect one morph with the plane; returns {spans:[[a,b]]} (area) or {pts:[u...]} (tube crossing), in drawing px
function planeCut(m, mode, pos) {
  const n = SC[sid(m)]; if (!n) return null;
  if (mode === 'coronal') { return (n.depth || []).some((d) => pos >= d[0] && pos <= d[1]) ? { depth: true } : null; }
  const axial = mode === 'axial', offV = axial ? m._.y : m._.x, offU = axial ? m._.x : m._.y, v0 = pos - offV;
  const polys = polysOf(m), area = m._.fill !== 'none', spans = [], cross = [];
  const xs = [];
  for (const s of polys) {
    const P2 = s.pts, ncount = P2.length; if (ncount < 2) continue;
    const isArea = (area || s.closed) && ncount > 2;
    const lim = isArea ? ncount : ncount - 1;
    for (let i = 0; i < lim; i++) {
      const a = P2[i], b = P2[(i + 1) % ncount], av = axial ? a[1] : a[0], bv = axial ? b[1] : b[0], au = axial ? a[0] : a[1], bu = axial ? b[0] : b[1];
      if ((av <= v0) !== (bv <= v0)) { const u = au + (bu - au) * (v0 - av) / (bv - av); (isArea ? xs : cross).push(u + offU); }
    }
  }
  xs.sort((p, q) => p - q); for (let i = 0; i + 1 < xs.length; i += 2) spans.push([xs[i], xs[i + 1]]);
  if (spans.length) return { spans }; if (cross.length) return { cross };
  return null;
}
const TREE_LABEL = {};
function sliceCompute() {
  const mode = SL.mode, pos = SL.pos[mode]; const groups = new Map(); SL.hits = [];
  for (const m of allMorphs()) {
    if (!m._.visible || !m.layer.shown) continue;
    const i = sid(m), n = SC[i]; if (!n) continue;
    if (m.layer.id === 'skin' && i !== 'skin_body') continue;
    if (m.layer.id === 'skeleton' && /^sk_(orbit|nasal)/.test(i)) continue;
    const cut = planeCut(m, mode, pos); if (!cut) continue;
    SL.hits.push({ m, cut });
    let key = i, label = m._.label, rep = i;
    if (n.internal) { key = 'in:' + ownerOf(i); label = labelOf(ownerOf(i)) + ' - inside'; rep = ownerOf(i); }
    else if (n.tree && n.level > 0) { key = 'tree:' + n.tree; label = `${labelOf(n.tree + '_0')} (branches)`; rep = i; }
    let g = groups.get(key); if (!g) { g = { key, label, rep, system: m.layer.id, color: m._.fill !== 'none' ? m._.fill : m._.stroke, n: 0, w: 0, parts: [], kind: n.internal ? 'inside' : n.tree && n.level > 0 ? 'tree' : 'one' }; groups.set(key, g); }
    g.n++; if (cut.spans) g.w += cut.spans.reduce((a, s) => a + (s[1] - s[0]), 0); if (n.internal && (n.hierarchy === 'segment' || n.hierarchy === 'lobe')) g.parts.push(m._.label.replace(/^Liver\s*/i, ''));
    if (n.internal && g.system === 'organs') g.system = 'organs';
  }
  SL.list = [...groups.values()].sort((a, b) => SYS_ORDER.indexOf(a.system) - SYS_ORDER.indexOf(b.system) || b.w - a.w);
}
function sliceDraw() {
  const g = V2.slfx; g.textContent = ''; if (SL.mode === 'off') return;
  const mode = SL.mode, pos = SL.pos[mode];
  if (mode === 'axial') { svg('rect', { x: -10, y: pos - 1.2, width: 420, height: 2.4, fill: '#0a84ff', opacity: 0.55 }, g); }
  else if (mode === 'sagittal') { svg('rect', { x: pos - 1.2, y: 6, width: 2.4, height: 836, fill: '#0a84ff', opacity: 0.55 }, g); }
  else { svg('rect', { x: -8, y: 6, width: 416, height: 836, fill: '#0a84ff', opacity: 0.05 }, g); }
  let drawn = 0;
  for (const h of SL.hits) {
    if (drawn > 500) break; const col = h.m._.fill !== 'none' ? h.m._.fill : h.m._.stroke;
    if (h.cut.spans) for (const s of h.cut.spans) { drawn++; const a = mode === 'axial' ? [s[0], pos, s[1], pos] : [pos, s[0], pos, s[1]]; svg('line', { x1: a[0], y1: a[1], x2: a[2], y2: a[3], stroke: col, 'stroke-width': 3.6, 'stroke-linecap': 'round', opacity: 0.95 }, g); svg('line', { x1: a[0], y1: a[1], x2: a[2], y2: a[3], stroke: '#fff', 'stroke-width': 1, opacity: 0.7 }, g); }
    else if (h.cut.cross) for (const u of h.cut.cross) { drawn++; svg('circle', { cx: mode === 'axial' ? u : pos, cy: mode === 'axial' ? pos : u, r: 2.2, fill: col, stroke: '#fff', 'stroke-width': 0.8 }, g); }
  }
}
function sliceDimUpdate() {
  const on = SL.mode !== 'off'; const hit = new Set(SL.hits.map((h) => h.m));
  for (const m of allMorphs()) {
    const dim = on && SL.dim && !SL.clip && !m.concealed && !hit.has(m) && m.layer.id !== 'skin';
    m.g.classList.toggle('sl-dim', dim);
    let cut = false;
    if (on && SL.clip && SL.mode === 'coronal' && !m.concealed) { const n = SC[sid(m)], pos = SL.pos.coronal; if (n && n.depth) cut = SL.keep > 0 ? n.depth.every((d) => d[0] > pos) : n.depth.every((d) => d[1] < pos); }
    m.g.classList.toggle('sl-cut', cut);
    if (m.fxv) { m.fxv.g.classList.toggle('sl-cut', cut || (on && SL.dim && !SL.clip && !hit.has(m))); }
  }
}
function sliceClip() {
  const on = SL.mode !== 'off' && SL.clip && SL.mode !== 'coronal', p = SL.pos[SL.mode], k = SL.keep, r = V2.clipRect;
  if (on) {
    if (SL.mode === 'axial') { r.setAttribute('x', -9999); r.setAttribute('width', 99999); if (k > 0) { r.setAttribute('y', p); r.setAttribute('height', 99999); } else { r.setAttribute('y', -9999); r.setAttribute('height', p + 9999); } }
    else { r.setAttribute('y', -9999); r.setAttribute('height', 99999); if (k > 0) { r.setAttribute('x', p); r.setAttribute('width', 99999); } else { r.setAttribute('x', -9999); r.setAttribute('width', p + 9999); } }
  }
  for (const l of W.layers) { if (on) l.g.setAttribute('clip-path', 'url(#slclip)'); else l.g.removeAttribute('clip-path'); }
}
function sliceRenderList() {
  const box = $('#slList'); box.textContent = '';
  const mode = SL.mode, pos = SL.pos[mode];
  if (mode === 'off') { box.append(mk('div', 'sln', 'Pick a plane above. The list shows which drawn structures the plane crosses.')); return; }
  $('#slInfo').textContent = mode === 'axial' ? `level y = ${Math.round(pos)} (around the ${landmark(pos)})` : mode === 'sagittal' ? `x = ${Math.round(pos)} (${Math.abs(pos - 200) < 6 ? 'midline' : pos < 200 ? 'patient\'s right of midline' : 'patient\'s left of midline'}, ${r2(Math.abs(pos - 200) * CM_PER_PX)} cm)` : `depth ${pos.toFixed(2)} (0 = front of body, 1 = back)`;
  const tot = SL.list.length; $('#slCount').textContent = `${SL.hits.length} pieces cut · ${tot} rows`;
  let lastSys = '';
  for (const g of SL.list.slice(0, 70)) {
    if (g.system !== lastSys) { lastSys = g.system; box.append(mk('div', 'slh', W.layerById[g.system] ? W.layerById[g.system]._.label : g.system)); }
    const r = mk('div', 'slr'); const dot = mk('i'); dot.style.background = g.color === 'none' ? '#999' : g.color;
    let detail = '';
    if (g.kind === 'inside') detail = `${g.n} inner pieces${g.parts.length ? ': ' + [...new Set(g.parts)].slice(0, 5).join(', ') : ''}`;
    else if (g.kind === 'tree') detail = `${g.n} branch cuts`;
    else if (g.w) detail = `${r2(g.w * CM_PER_PX)} cm across`;
    else if (SL.mode !== 'coronal') detail = g.n > 1 ? `${g.n} crossings` : 'crossed';
    r.append(dot, mk('span', 'nm', g.label), mk('span', 'dt', detail)); r.addEventListener('click', () => selectId(g.rep)); box.append(r);
  }
  if (tot > 70) box.append(mk('div', 'sln', `+${tot - 70} more rows`));
  if (!tot) box.append(mk('div', 'sln', 'Nothing drawn is cut at this position.'));
}
function sliceUpdate(quiet) {
  if (!V2.ready) return;
  $('#slice').style.display = SL.mode === 'off' && !SL.open ? 'none' : 'block';
  document.querySelectorAll('#slModes button').forEach((b) => b.classList.toggle('on', b.dataset.m === SL.mode));
  const mode = SL.mode, sl = $('#slPos');
  if (mode !== 'off') { if (mode === 'coronal') { sl.min = 0; sl.max = 100; sl.value = Math.round(SL.pos.coronal * 100); } else { sl.min = 0; sl.max = mode === 'axial' ? 840 : 400; sl.value = Math.round(SL.pos[mode]); } }
  sl.disabled = mode === 'off'; $('#slClip').checked = SL.clip; $('#slDim').checked = SL.dim;
  const ko = $('#slKeep'); const opts = mode === 'axial' ? ['above the plane', 'below the plane'] : mode === 'sagittal' ? ['patient\'s right half', 'patient\'s left half'] : ['front part', 'back part'];
  ko.options[0].text = 'keep ' + opts[0]; ko.options[1].text = 'keep ' + opts[1]; ko.selectedIndex = SL.keep > 0 ? 1 : 0;
  if (mode === 'off') { SL.hits = []; SL.list = []; } else sliceCompute();
  sliceDraw(); sliceClip(); sliceDimUpdate(); sliceRenderList(); $('#bSlice').classList.toggle('on', mode !== 'off'); dockLayout();
}
function sliceSet(mode, pos) {
  if (mode === 'off') { SL.mode = 'off'; SL.open = false; sliceUpdate(); return; }
  SL.mode = mode; SL.open = true;
  if (pos != null) SL.pos[mode] = mode === 'coronal' ? clamp(pos > 1.001 ? pos / 100 : pos, 0, 1) : +pos;
  else if (curId() && SC[curId()]) { const o = SC[curId()].origin || (SC[curId()].frame && SC[curId()].frame.origin); if (o) SL.pos[mode] = mode === 'axial' ? o[1] : mode === 'sagittal' ? o[0] : o[2]; }
  sliceUpdate();
}
document.querySelectorAll('#slModes button').forEach((b) => { b.onclick = () => sliceSet(b.dataset.m); });
$('#slPos').oninput = (e) => { const v = +e.target.value; SL.pos[SL.mode] = SL.mode === 'coronal' ? v / 100 : v; sliceUpdate(); };
$('#slClip').onchange = (e) => { SL.clip = e.target.checked; sliceUpdate(); }; $('#slDim').onchange = (e) => { SL.dim = e.target.checked; sliceUpdate(); };
$('#slKeep').onchange = (e) => { SL.keep = e.target.selectedIndex ? 1 : -1; sliceUpdate(); };
$('#slClose').onclick = () => sliceSet('off'); $('#bSlice').onclick = () => (SL.mode === 'off' ? sliceSet('axial') : sliceSet('off'));
SL.keep = 1;

function dockLayout() {
  const open = PH.open || SL.mode !== 'off'; $('#dock').classList.toggle('on', open);
  const pl = open ? 372 : 0; if (W.padL !== pl) { W.padL = pl; if (W.autoFit) fitView(); }
}

/* =================================================== validation modal */
function showValidation(on) {
  const box = $('#valid'); if (on === undefined) on = !box.classList.contains('on'); box.classList.toggle('on', on); if (!on) return;
  box.textContent = '';
  box.append(mk('h2', '', 'Anatomy checks'));
  box.append(mk('p', 'vs', `Run by build_atlas.rb every time the atlas is built: ${VAL.pass} passed · ${VAL.warn} warnings · ${VAL.fail} failed.`));
  for (const c of VAL.checks) { const r = mk('div', 'vr ' + c.status.toLowerCase()); r.append(mk('span', 'b', c.status), mk('span', 'nm', c.name)); if (c.detail) r.append(mk('span', 'dt', Array.isArray(c.detail) ? c.detail.join('; ') : c.detail)); box.append(r); }
  box.append(mk('p', 'vf', VAL.future || '')); const x = mk('button', 'btn', 'Close'); x.onclick = () => showValidation(false); box.append(x);
}
$('#bVal').onclick = () => showValidation();
$('#bVal').textContent = `Checks ${VAL.pass}/${VAL.checks.length}`;
function v2Esc() { showValidation(false); }

/* ============================================ ex commands & vim keys */
function v2Ex(c, rest, args) {
  const onoff = (v, d) => (v === undefined ? d : /^(on|1|yes|true)$/i.test(v));
  switch (c) {
    case 'children': { const id = curId(); if (!id) { say('nothing selected', true); return true; } const k = KIDS[id] || []; say(k.length ? `${k.length} inside ${labelOf(id)}: ${k.slice(0, 12).map(labelOf).join(', ')}${k.length > 12 ? '…' : ''}` : `${labelOf(id)} has no smaller pieces`); return true; }
    case 'parent': case 'up': drillUp(+args[0] || 1); return true;
    case 'down': case 'drill': drillDown(+args[0] || 1); return true;
    case 'path': { const id = curId(); say(id ? ancestry(id).map(labelOf).join(' › ') : 'nothing selected'); return true; }
    case 'focus': V2.focus = onoff(args[0], !V2.focus); $('#cFocus').checked = V2.focus; updateDim(); say('focus branch ' + (V2.focus ? 'on' : 'off')); return true;
    case 'skin': if (args[0] === undefined) { say(`skin opacity ${Math.round(V2.skin * 100)}%`); return true; } { let v = parseFloat(args[0]); if (v > 1) v /= 100; setSkin(v); say(`skin opacity ${Math.round(V2.skin * 100)}%`); } return true;
    case 'shade': V2.shade = onoff(args[0], !V2.shade); $('#cShade').checked = V2.shade; stage.classList.toggle('noshade', !V2.shade); say('shading ' + (V2.shade ? 'on' : 'off')); return true;
    case 'reveal': V2.reveal = onoff(args[0], !V2.reveal); applyConceal(); say(V2.reveal ? 'all inner structures shown' : 'inner structures appear when you select their organ'); return true;
    case 'legend': setLegend(onoff(args[0], !V2.legend)); return true;
    case 'tree': setTreeMode(args[0] === 'anatomy' ? 'anatomy' : 'systems'); return true;
    case 'timeline': case 'tl': physOpen(onoff(args[0], !PH.open)); return true;
    case 'play': physPlay(true); say('playing (schematic)'); return true;
    case 'pause': physPlay(false); say('paused'); return true;
    case 'step': physStep(1, +args[0] || 1); return true;
    case 'replay': physReplay(); say('replay from t = 0'); return true;
    case 'hr': if (!args.length) { say(`heart rate ${PH.hr} bpm (60-100)`); return true; } setHr(args[0]); say(`heart rate ${PH.hr} bpm`); return true;
    case 'rr': if (!args.length) { say(`breathing ${PH.rr}/min (12-20)`); return true; } setRr(args[0]); say(`breathing ${PH.rr}/min`); return true;
    case 'speed': PH.speed = clamp(parseFloat(args[0]) || 1, 0.1, 4); $('#tlSpd').value = [0.25, 0.5, 1, 2].includes(PH.speed) ? PH.speed : 1; say(`playback speed ${PH.speed}x`); return true;
    case 'slice': {
      const a = (args[0] || '').toLowerCase();
      if (!a) { say(SL.mode === 'off' ? 'usage: :slice axial|sagittal|coronal [position] | off' : `slice ${SL.mode} at ${r2(SL.pos[SL.mode])}`); return true; }
      if (a === 'off') { sliceSet('off'); say('slice off'); return true; }
      const mm = { a: 'axial', ax: 'axial', axial: 'axial', s: 'sagittal', sag: 'sagittal', sagittal: 'sagittal', c: 'coronal', cor: 'coronal', coronal: 'coronal' }[a];
      if (!mm) { say('slice: axial, sagittal, coronal or off', true); return true; }
      sliceSet(mm, args[1] !== undefined ? parseFloat(args[1]) : undefined); say(`${mm} slice: ${SL.list.length} rows`); return true;
    }
    case 'clip': SL.clip = onoff(args[0], !SL.clip); sliceUpdate(); return true;
    case 'zoom': { const id = args[0] && args[0] !== 'out' && args[0] !== 'fit' ? args[0] : (args[0] ? null : curId()); if (!id || !String(id).split(',').some((x) => SC[x])) { fitView(); say('zoom: fit whole body'); return true; } zoomTo(id); say('zoomed to ' + labelOf(id) + ' (:zoom out to fit again)'); return true; }
    case 'validate': case 'checks': showValidation(true); return true;
    default: return false;
  }
}
function v2Key(k, n, e) {
  switch (k) {
    case '>': drillDown(n); break;
    case '<': drillUp(n); break;
    case 'Tab': nextSibling(e.shiftKey ? -1 : 1, n); break;
    case ' ': physPlay(); break;
    case '.': physStep(1, n); break;
    case ',': physStep(-1, n); break;
    case 'T': physOpen(!PH.open); break;
    case 'Z': if (SL.mode === 'off') sliceSet('axial'); else sliceSet(SL.mode === 'axial' ? 'sagittal' : SL.mode === 'sagittal' ? 'coronal' : 'off'); break;
    case '(': setSkin(V2.skin - 0.1 * n); say(`skin ${Math.round(V2.skin * 100)}%`); break;
    case ')': setSkin(V2.skin + 0.1 * n); say(`skin ${Math.round(V2.skin * 100)}%`); break;
    default: break;
  }
}
function zoomTo(id) {
  const ns = String(id).split(',').map((x) => SC[x]).filter((n) => n && n.bbox); if (!ns.length) return;
  const bb = [Math.min(...ns.map((n) => n.bbox[0])), Math.min(...ns.map((n) => n.bbox[1])), Math.max(...ns.map((n) => n.bbox[2])), Math.max(...ns.map((n) => n.bbox[3]))];
  const r = stage.getBoundingClientRect(), pl = W.padL || 0;
  const w = bb[2] - bb[0] + 24, h = bb[3] - bb[1] + 24;
  const k = Math.min((r.width - pl - 60) / w, (r.height - 100) / h, 6);
  W.view.k = k; W.view.tx = pl + (r.width - pl - w * k) / 2 - (bb[0] - 12) * k; W.view.ty = (r.height - h * k) / 2 - (bb[1] - 12) * k;
  W.autoFit = false; applyView();
}
function v2Api() {
  return { scene: SC, kids: KIDS, ownerOf, ancestry, drillDown, drillUp, nextSibling, selectId, isConcealed: (id) => !!(MBY[id] && MBY[id].concealed),
    setSkin, getSkin: () => V2.skin, legend: LEG,
    phys: { state: PH, open: physOpen, play: physPlay, step: physStep, setTime: physSetTime, setPhase: physSetPhase, replay: physReplay, setHr, setRr, info: phaseInfo, render: renderPhys, entries: () => PH.entries.length },
    slice: { set: sliceSet, state: SL, list: () => SL.list.map((g) => ({ key: g.key, label: g.label, kind: g.kind, n: g.n })) },
    showValidation, v2: V2, planeCut, zoomTo };
}
buildLegend(); buildPanel(); setHr(PH.hr); setRr(PH.rr);
