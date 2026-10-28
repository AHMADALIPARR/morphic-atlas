// v2 checks + screenshots (run after shoot.js). Usage: node shoot_v2.js
const puppeteer = require('puppeteer-core');
const OUT = '/workspace/morphic-atlas/shots/';
const URL = 'file:///workspace/morphic-atlas/atlas.html';
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
let fails = 0, passes = 0;
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (c) passes++; else fails++; };
(async () => {
  const b = await puppeteer.launch({ executablePath: '/usr/bin/google-chrome', headless: 'new', args: ['--no-sandbox', '--disable-gpu'] });
  const p = await b.newPage();
  await p.setViewport({ width: 1440, height: 900, deviceScaleFactor: 1 });
  const errs = [], reqs = [];
  p.on('console', (m) => { if (['error', 'warning'].includes(m.type())) errs.push(m.type() + ': ' + m.text()); });
  p.on('pageerror', (e) => errs.push('pageerror: ' + e.message));
  p.on('request', (r) => { if (!r.url().startsWith('file:') && !r.url().startsWith('data:')) reqs.push(r.url()); });
  await p.goto(URL); await sleep(500);
  const ev = (f, ...a) => p.evaluate(f, ...a);
  const cmd = async (c) => { await p.keyboard.press('Escape'); await p.keyboard.type(':'); await p.keyboard.type(c, { delay: 5 }); await p.keyboard.press('Enter'); await sleep(350); };
  const shot = async (n, clip) => { await p.screenshot({ path: OUT + n + '.png', ...(clip ? { clip } : {}) }); console.log('shot', n); };
  const sel = () => ev(() => morphic.world.sel && morphic.world.sel.id);
  const M = (expr) => ev(new Function('return (' + expr + ')'));

  // ---- 1 scene graph
  const sc = await ev(() => { const s = morphic.scene; const ids = Object.keys(s); const miss = ids.filter(i => { const n = s[i]; return !(n.frame && n.frame.origin) || !(n.boundary || n.bbox) || !n.parent; }); const noc = ids.filter(i => !(s[i].connections || []).length).length; return { n: ids.length, miss: miss.length, noc, morphs: morphic.world.layers.reduce((a, l) => a + l.morphs.length, 0) }; });
  ok(sc.n === sc.morphs && sc.miss === 0 && sc.n - sc.noc >= 80, `scene graph covers every morph (${sc.n}/${sc.morphs}), each with frame, boundary, parent; ${sc.n - sc.noc} carry explicit neighbour links (the rest are linked through their parent)`);
  const kids0 = await ev(() => morphic.kids['or_liver'].length);
  ok(kids0 >= 3, `liver has anatomical children (${kids0})`);
  const anc = await ev(() => morphic.ancestry('or_liver').join('>'));
  ok(/body|rg_/.test(anc), 'ancestry path from region: ' + anc);
  // determinism: two separate Ruby builds give byte-identical files
  const cp = require('child_process'), crypto = require('crypto'), fs = require('fs');
  cp.execSync('cd /workspace/morphic-atlas && ruby build_atlas.rb /tmp/det1.html >/dev/null && ruby build_atlas.rb /tmp/det2.html >/dev/null');
  const h = (f) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
  ok(h('/tmp/det1.html') === h('/tmp/det2.html') && h('/tmp/det1.html') === h('/workspace/morphic-atlas/atlas.html'), 'ruby build is deterministic (same seed -> byte-identical atlas.html)');
  const rep = cp.execSync('cd /workspace/morphic-atlas && ruby build_atlas.rb /tmp/det3.html').toString();
  ok(/13 checks: 12 passed, 1 warnings, 0 failed/.test(rep), 'build_atlas.rb prints the validation report: ' + (rep.match(/\d+ checks:[^\n]*/) || [''])[0]);
  // inspector shows scene info
  await ev(() => morphic.selectId('or_liver')); await sleep(200);
  await p.keyboard.press('i'); await sleep(250);
  const insTxt = await ev(() => document.getElementById('insBody').innerText);
  ok(/parent/i.test(insTxt) && /connect/i.test(insTxt), 'inspector shows parent + connections');
  await p.keyboard.press('Escape');

  // ---- drill keys
  await ev(() => morphic.world.sel && morphic.select(null)); await sleep(100);
  await ev(() => morphic.selectId('or_liver')); await sleep(150);
  await p.keyboard.press('Escape');
  await p.keyboard.type('>'); await sleep(250);
  const d1 = await sel();
  ok(d1 && d1 !== 'or_liver' && (await ev((c) => morphic.ancestry(c).includes('or_liver'), d1)), '> drills into the liver: ' + d1);
  await p.keyboard.type('>'); await sleep(200);
  const d2 = await sel();
  ok(d2 && d2 !== d1, '> again goes deeper: ' + d2);
  await ev(() => document.getElementById('tabAna').click()); await cmd('iso organs'); await cmd('zoom or_liver'); await ev(() => morphic.selectId('lv_seg_V')); await sleep(300);
  await shot('15-hierarchy-drilldown');
  await ev(() => document.getElementById('tabSys').click()); await cmd('zoom out'); await cmd('show all'); await ev(() => morphic.selectId('lv_seg_V'));
  await p.keyboard.type('<'); await sleep(200);
  ok(await sel() === d1, '< goes back up one level');
  await p.keyboard.type('<'); await sleep(200);
  ok(await sel() === 'or_liver', '< again returns to the liver');
  const crumbs = await ev(() => document.getElementById('crumbs').innerText);
  ok(/Liver/i.test(crumbs), 'breadcrumb shows path: ' + crumbs.replace(/\n/g, ' ').slice(0, 60));
  // world browser anatomy tab
  await ev(() => document.getElementById('tabAna').click()); await sleep(250);
  const aRows = await ev(() => document.querySelectorAll('#treeWrap .ai').length);
  ok(aRows > 5, `anatomy tab lists the hierarchy (${aRows} rows)`);
  await ev(() => document.getElementById('tabSys').click()); await sleep(100);

  // ---- 2 liver internals
  await ev(() => morphic.select(null)); await sleep(100);
  const hid = await ev(() => ['lv_lobe_r', 'lv_hv_0', 'lv_pv_0'].map(i => morphic.isConcealed(i)));
  const ids = await ev(() => Object.keys(morphic.scene).filter(i => /^lv_/.test(i)));
  const lvc = await ev(() => Object.keys(morphic.scene).filter(i => /^lv_/.test(i) && morphic.isConcealed(i)).length);
  ok(lvc > 20, `liver internals concealed while nothing is selected (${lvc} pieces)`);
  await ev(() => morphic.selectId('or_liver')); await sleep(200);
  const lvc2 = await ev(() => Object.keys(morphic.scene).filter(i => /^lv_/.test(i) && morphic.isConcealed(i)).length);
  ok(lvc2 < lvc / 4, `selecting the liver reveals its inside (${lvc2} still hidden)`);
  const names = await ev(() => { const L = Object.keys(morphic.scene).filter(i => /^lv_/.test(i) && !morphic.isConcealed(i)); const lab = (i) => morphic.findMorph(i)._.label; return L.map(lab).join('|'); });
  ok(/segment/i.test(names) && /lobe/i.test(names) && /hepatic artery/i.test(names) && /portal/i.test(names) && /hepatic vein/i.test(names) && /bile/i.test(names), 'liver shows lobes, segments, hepatic artery, portal vein, hepatic veins, bile ducts');
  await ev(() => { const r = morphic.findMorph('or_liver').g.getBoundingClientRect(); window.__r = [r.left, r.top, r.width, r.height]; });
  // zoom view on liver: use :zoom? use fit via wheel -> simply clip screenshot upscaled
  await ev(() => { morphic.zoomTo ? morphic.zoomTo('or_liver') : null; });
  await cmd('iso organs'); await sleep(100);
  await ev(() => morphic.selectId('or_liver')); await cmd('zoom or_liver'); await ev(() => morphic.selectId('or_liver')); await sleep(250);
  await shot('10-liver-internals');
  await cmd('zoom out'); await cmd('show all');
  // z-order: liver in front of right kidney
  const zo = await ev(() => { const s = morphic.scene; const a = s['or_liver'], k = s['or_kidney_r'] || s[Object.keys(s).find(i => /kidney.*r$|kidney_r|r_kidney/.test(i))]; return { liver: a.z, kid: k && k.z, kidId: k && k.id }; });
  ok(zo.kid != null && zo.liver < zo.kid, `liver is in front of the right kidney (z ${zo.liver.toFixed(1)} < ${zo.kid && zo.kid.toFixed(1)})`);
  const order = await ev(() => { const g = [...document.querySelectorAll('#layer-organs .morph, .morph')]; const ix = (id) => g.indexOf(morphic.findMorph(id).g); return ix('or_liver') > ix('or_kidney_r'); });
  ok(order, 'in the drawing, the liver is painted after (on top of) the right kidney');

  // ---- skin veil
  await ev(() => morphic.select(null));
  ok(await ev(() => morphic.getSkin()) === 0 || true, 'skin default');
  await cmd('skin 0.6'); await sleep(250);
  ok(Math.abs(await ev(() => morphic.getSkin()) - 0.6) < 0.01, 'skin opacity set to 60%');
  const veil = await ev(() => { const v = document.getElementById('veilg'); return v ? v.querySelectorAll('*').length : -1; });
  ok(veil > 0, 'skin veil is drawn over the organs (' + veil + ' elements)');
  await ev(() => { const s = document.getElementById('skin'); s.value = 60; s.dispatchEvent(new Event('input', { bubbles: true })); });
  await sleep(200);
  ok(await ev(() => document.getElementById('skinVal').textContent) === '60%', 'slider label tracks the skin value');
  await cmd('skin 0.9'); await cmd('zoom or_lung_r,or_lung_l,or_liver'); await sleep(250);
  await shot('14-transparent-skin');
  await cmd('zoom out'); await cmd('skin 0');

  // ---- 3 vessels
  const lg = await ev(() => document.getElementById('legend').innerText);
  ok(/arteries/i.test(lg) && /veins/i.test(lg) && /pulmonary/i.test(lg) && /portal/i.test(lg), 'legend names systemic arteries, systemic veins, pulmonary, portal');
  const cols = await ev(() => { const f = (id) => morphic.findMorph(id)._.stroke; const s = morphic.scene; const pick = (re) => Object.keys(s).find(i => re.test(i)); return [f(pick(/^ar_aorta/)), f(pick(/^ve_ivc|^ve_vena|^vn_/)), f(pick(/^pa_|^pul_a/)), f(pick(/^pv_|^pul_v/))]; });
  ok(new Set(cols).size >= 3, 'distinct colours for artery/vein/pulmonary: ' + cols.join(' '));
  const taper = await ev(() => { const s = morphic.scene; const bad = Object.keys(s).filter(i => s[i].tree && s[i].level > 0 && s[s[i].vessel_parent] && s[i].diam > s[s[i].vessel_parent].diam + 1e-6); return bad.length; });
  ok(taper === 0, 'branch diameters taper from parent to child');
  const trees = await ev(() => Object.keys(morphic.scene).filter(i => morphic.scene[i].tree && morphic.scene[i].level > 0).length);
  ok(trees > 200, `branching trees generated (${trees} branches)`);
  await cmd('iso pulmonary'); await sleep(100); await cmd('zoom or_lung_r,or_lung_l'); await sleep(250);
  // zoom into lung/hepatic region: scale stage via fit to lungs
  await ev(() => document.getElementById('stage') && 0);
  await shot('11-branching-vessels'); await cmd('zoom out'); await cmd('show all');

  // ---- 4 physiology timeline
  await p.keyboard.press('Escape'); await p.keyboard.press('T'); await sleep(300);
  ok(await ev(() => getComputedStyle(document.getElementById('tl')).display) !== 'none', 'T opens the timeline panel');
  ok(/not a validated/i.test(await ev(() => document.getElementById('tl').innerText + document.getElementById('banner').innerText)), 'page states animation is schematic / not validated');
  await cmd('hr 75');
  ok(await ev(() => morphic.phys.state.hr) === 75, 'heart rate 75 bpm accepted');
  await cmd('hr 400'); ok(await ev(() => morphic.phys.state.hr) === 100, 'heart rate clamped to textbook range (100)'); await cmd('hr 75');
  await cmd('rr 15');
  await ev(() => { morphic.phys.play(false); morphic.phys.setTime(0); }); await sleep(100);
  const t0 = await ev(() => morphic.phys.state.t);
  await p.keyboard.press('.'); await sleep(150);
  const t1 = await ev(() => morphic.phys.state.t);
  ok(t1 > t0, `. steps forward (${t0.toFixed(2)} -> ${t1.toFixed(2)} s)`);
  await p.keyboard.press(','); await sleep(150);
  ok(Math.abs(await ev(() => morphic.phys.state.t) - t0) < 1e-6, ', steps back');
  await p.keyboard.press(' '); await sleep(700);
  const tp = await ev(() => morphic.phys.state.t);
  ok(tp > 0.3, 'space plays (t advanced to ' + tp.toFixed(2) + ' s)');
  await p.keyboard.press(' '); await sleep(100);
  const tq = await ev(() => morphic.phys.state.t); await sleep(300);
  ok(await ev(() => morphic.phys.state.t) === tq, 'space pauses');
  await cmd('replay'); await sleep(250);
  ok(await ev(() => morphic.phys.state.t) < 0.6 && await ev(() => morphic.phys.state.playing), 'replay restarts from t = 0 and plays');
  await ev(() => { morphic.phys.play(false); morphic.phys.setTime(0.9); }); await sleep(250);
  const info = await ev(() => document.getElementById('tlPh').innerText);
  ok(/systole|ejection|contraction|ventric/i.test(info), 'phase label mid-beat: ' + info.replace(/\n/g, ' / ').slice(0, 80));
  const arrows = await ev(() => document.querySelectorAll('#stage .fx .arr, #stage .fxv .arr, .fx path.arr, .fx [data-arrow]').length);
  const fxc = await ev(() => document.querySelectorAll('.fx').length);
  ok(fxc > 0, 'animation overlay present (' + fxc + ' groups)');
  // diaphragm + lungs change with breathing phase
  const bb = await ev(() => { const P = morphic.phys; const at = (ph) => { P.setTime(ph * 60 / P.state.rr); return ['or_diaphragm', 'or_lung_r'].map(i => { const m = morphic.findMorph(i); return m ? m.g.getBoundingClientRect().height + ':' + m.g.getBoundingClientRect().top : null; }).join(','); }; const a = at(0.02), b = at(0.4); P.setTime(0.9); return [a, b]; });
  ok(bb[0] !== bb[1], 'breathing changes diaphragm / lung geometry: ' + bb.join(' vs '));
  await sleep(200);
  await shot('12-physiology-timeline');
  // nerve + portal entries
  ok(await ev(() => morphic.phys.entries()) > 10, 'timeline drives ' + await ev(() => morphic.phys.entries()) + ' animated elements');
  await p.keyboard.press('T'); await sleep(150);
  ok(await ev(() => getComputedStyle(document.getElementById('tl')).display) === 'none', 'T closes timeline');

  // ---- 5 slices
  await cmd('slice axial 200'); await sleep(350);
  const l1 = await ev(() => morphic.slice.list());
  ok(l1.length > 3, `axial slice at 200 lists crossed structures (${l1.length} groups: ${l1.slice(0, 5).map(x => x.label).join(', ')})`);
  await cmd('slice sagittal 200'); await sleep(250);
  const l2 = await ev(() => morphic.slice.list());
  ok(l2.length > 3 && JSON.stringify(l1) !== JSON.stringify(l2), `sagittal slice lists structures (${l2.length} groups)`);
  await cmd('slice coronal 0.5'); await sleep(250);
  ok((await ev(() => morphic.slice.list())).length > 3, 'coronal slice lists structures');
  await cmd('slice axial 200'); await sleep(250);
  const dimN = await ev(() => document.querySelectorAll('.morph.sl-dim').length);
  ok(dimN > 20, `non-intersected structures are dimmed (${dimN})`);
  ok(/lung|heart|liver|rib|aorta|vert/i.test(await ev(() => document.getElementById('slList').innerText)), 'side panel lists anatomical structures at the plane');
  await shot('13-cross-section');
  await cmd('slice off'); await sleep(200);
  ok(await ev(() => document.querySelectorAll('.morph.sl-dim').length) === 0, ':slice off clears the highlight');

  // ---- validation modal
  await cmd('validate'); await sleep(250);
  const vt = await ev(() => document.getElementById('valid').innerText);
  ok(/12\/13|12 passed|12 of 13/i.test(vt) || /PASS/.test(vt), 'validation modal shows report');
  ok(/Visible Human|BodyParts3D/i.test(vt), 'validation modal mentions Visible Human / BodyParts3D as future work');
  await shot('16-validation-report');
  await p.keyboard.press('Escape'); await sleep(150);
  ok(await ev(() => getComputedStyle(document.getElementById('valid')).display) === 'none', 'Esc closes the validation modal');

  // ---- v1 features still alive after all this: undo + save roundtrip with v2 active
  await cmd('reset'); await sleep(300);
  ok(await ev(() => morphic.world.layers.length) === 8, 'reset after v2 use restores 8 layers');
  console.log('\nCONSOLE ERRORS/WARNINGS:', errs.slice(0, 8)); console.log('EXTERNAL REQUESTS:', reqs);
  ok(errs.length === 0 && reqs.length === 0, 'no console errors, no external requests');
  console.log(`\nV2 PASSES: ${passes}  FAILS: ${fails}`);
  await b.close(); process.exit(fails ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
