const puppeteer = require('puppeteer-core');
const OUT = '/workspace/morphic-atlas/shots/';
const URL = 'file:///workspace/morphic-atlas/atlas.html';
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
let fails = 0;
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) fails++; };
(async () => {
  const b = await puppeteer.launch({ executablePath: '/usr/bin/google-chrome', headless: 'new', args: ['--no-sandbox', '--disable-gpu'] });
  const p = await b.newPage();
  await p.setViewport({ width: 1440, height: 900, deviceScaleFactor: 1 });
  const errs = [], reqs = [];
  p.on('console', (m) => { if (['error', 'warning'].includes(m.type())) errs.push(m.type() + ': ' + m.text()); });
  p.on('pageerror', (e) => errs.push('pageerror: ' + e.message));
  p.on('request', (r) => { if (!r.url().startsWith('file:') && !r.url().startsWith('data:')) reqs.push(r.url()); });
  await p.goto(URL); await sleep(400);
  const ev = (f, ...a) => p.evaluate(f, ...a);
  const cmd = async (c) => { await p.keyboard.press('Escape'); await p.keyboard.type(':'); await p.keyboard.type(c, { delay: 6 }); await p.keyboard.press('Enter'); await sleep(450); };
  const shot = async (n, clip) => { await p.screenshot({ path: OUT + n + '.png', ...(clip ? { clip } : {}) }); console.log('shot', n); };
  const mode = () => ev(() => document.getElementById('mode').textContent);
  const sel = () => ev(() => morphic.world.sel && morphic.world.sel.id);
  const slot = (id, k) => ev((id, k) => morphic.findMorph(id)._[k], id, k);
  const hit = (id) => ev((id) => { const m = morphic.findMorph(id); const r = m.g.getBoundingClientRect(); for (let f = 0.5, i = 0; i < 40; i++) { const fx = [0.5,0.3,0.7,0.5,0.5,0.4,0.6,0.2,0.8][i % 9], fy = [0.5,0.5,0.5,0.3,0.7,0.4,0.6,0.5,0.5][i % 9]; const x = Math.round(r.left + r.width * (fx + (i/9|0)*0.03)), y = Math.round(r.top + r.height * (fy + (i/9|0)*0.03)); const e = document.elementFromPoint(x, y); if (e && e.closest && e.closest('.morph') === m.g) return { x, y }; } return null; }, id);
  const center = (id) => ev((id) => { const r = morphic.findMorph(id).g.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }, id);

  ok(await mode() === 'NORMAL', 'starts in NORMAL');
  await shot('01-default');

  // explode via slider-equivalent vim `e`
  await p.keyboard.press('e'); await sleep(600);
  ok(await ev(() => morphic.world.explode) >= 40, 'e toggles explode on');
  await shot('02-exploded');
  await p.keyboard.press('e'); await sleep(600);
  ok(await ev(() => morphic.world.explode) === 0, 'e toggles explode off');

  // isolate veins
  await cmd('iso veins'); ok(await ev(() => morphic.world.iso) === 'veins', ':iso veins');
  await shot('03-veins-isolated');
  await cmd('show all'); ok(await ev(() => morphic.world.iso) === null, ':show all');

  // click-to-select a morph, then right-click -> inspector
  await p.keyboard.press('Escape');
  let c = await center('ca_arch') .catch(() => null);
  const pick = await ev(() => morphic.allMorphs().find(m => /liver/.test(m.id)).id);
  c = await hit(pick); console.log('liver hit point', JSON.stringify(c));
  await p.mouse.click(c.x, c.y); await sleep(100);
  const sid = await sel(); console.log('clicked ->', sid);
  ok(!!sid, 'click selects a morph');
  await p.keyboard.press('i'); await sleep(200);
  ok(await mode() === 'INSERT', 'i opens inspector + INSERT mode');
  ok(await ev(() => document.getElementById('inspector').classList.contains('on')), 'inspector visible');
  // live edit via inspector fields
  await ev(() => { const rows = [...document.querySelectorAll('#insBody .irow')]; const row = rows.find(r => r.querySelector('label')?.textContent === 'width'); const n = row.querySelector('input[type=number]'); n.value = '5'; n.dispatchEvent(new Event('input', { bubbles: true })); n.dispatchEvent(new Event('change', { bubbles: true })); });
  ok(await slot(sid, 'strokeWidth') === 5, 'inspector number field edits strokeWidth live');
  await ev(() => { const rows = [...document.querySelectorAll('#insBody .irow')]; const row = rows.find(r => r.querySelector('label')?.textContent === 'fill'); const t = row.querySelector('input[type=text]'); t.value = '#2a9d8f'; t.dispatchEvent(new Event('input', { bubbles: true })); t.dispatchEvent(new Event('change', { bubbles: true })); });
  ok(await slot(sid, 'fill') === '#2a9d8f', 'inspector fill field edits fill live');
  await p.keyboard.press('Escape'); await sleep(100);
  ok(await mode() === 'NORMAL', 'Esc -> NORMAL');
  // reopen inspector via right-click for the screenshot
  await ev(() => morphic.select(null)); // v2: a selected liver shows its lobes on top, so deselect first to right-click the liver itself
  await p.mouse.click(c.x, c.y, { button: 'right' }); await sleep(250);
  await shot('04-inspector');

  // vim nudge
  await p.keyboard.press('Escape');
  const x0 = await slot(sid, 'x'); await p.keyboard.press('l'); await p.keyboard.press('l'); await p.keyboard.press('j');
  console.log('nudge dbg', x0, await slot(sid,'x'), await slot(sid,'y'), await sel(), await mode()); ok(await slot(sid, 'x') === x0 + 8 && await slot(sid, 'y') === 4, 'h/j/k/l nudges selected morph');
  await p.keyboard.press('u'); await p.keyboard.press('u'); await p.keyboard.press('u');
  // w/b
  const s1 = await sel(); await p.keyboard.press('w'); const s2 = await sel(); await p.keyboard.press('b'); ok(s1 !== s2 && await sel() === s1, 'w / b cycle morphs');
  await p.keyboard.press('L'); const l1 = await ev(() => morphic.world.sel.constructor.name); ok(l1 === 'Layer', 'L selects next layer');
  await p.keyboard.press('H');
  // x hide/show
  await p.keyboard.press('w'); const hid = await sel(); await p.keyboard.press('x'); ok(await slot(hid, 'visible') === false, 'x hides'); await p.keyboard.press('x'); ok(await slot(hid, 'visible') === true, 'x shows');

  // vim command: set color, set width
  await cmd('set color #aa0000'); ok((await slot(hid, 'fill')) === '#aa0000' || (await slot(hid, 'stroke')) === '#aa0000', ':set color');
  await cmd('set width 3'); ok(await slot(hid, 'strokeWidth') === 3, ':set width 3');
  await cmd('explode 40'); ok(await ev(() => morphic.world.explode) === 40, ':explode 40');
  await cmd('explode 0');
  await cmd('select liver'); await cmd('set color #2a6f97'); await cmd('set width 2.5');
  await shot('05-vim-command-executed');
  await cmd('iso arteries');
  await p.keyboard.press('Escape');
  await p.keyboard.type(':'); await p.keyboard.type('set opacity 0.5', { delay: 15 });
  await shot('05b-vim-command-typing');
  await p.keyboard.press('Enter'); await sleep(200);
  await cmd('show all');

  // halo handles: duplicate, rotate, resize, delete, undo
  const m0 = await ev(() => morphic.allMorphs().length);
  await p.mouse.click(c.x, c.y); await sleep(100);
  const hpos = (h) => ev((h) => { const e = document.querySelector(`#halosvg [data-h=${h}]`); const r = e.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }, h);
  let hp = await hpos('dup'); await p.mouse.click(hp.x, hp.y); await sleep(100);
  ok(await ev(() => morphic.allMorphs().length) === m0 + 1, 'halo duplicate handle');
  const dupId = await sel();
  hp = await hpos('rotate'); await p.mouse.move(hp.x, hp.y); await p.mouse.down(); await p.mouse.move(hp.x + 60, hp.y + 20, { steps: 6 }); await p.mouse.up();
  ok(Math.abs(await slot(dupId, 'rotation')) > 5, 'halo rotate handle rotates (' + await slot(dupId, 'rotation') + '°)');
  hp = await hpos('resize'); await p.mouse.move(hp.x, hp.y); await p.mouse.down(); await p.mouse.move(hp.x + 40, hp.y + 40, { steps: 6 }); await p.mouse.up();
  ok(await slot(dupId, 'scaleX') > 1.05, 'halo resize handle scales (' + await slot(dupId, 'scaleX') + ')');
  hp = await hpos('move'); const px = await slot(dupId, 'x'); await p.mouse.move(hp.x, hp.y); await p.mouse.down(); await p.mouse.move(hp.x - 30, hp.y + 10, { steps: 5 }); await p.mouse.up();
  ok(await slot(dupId, 'x') !== px, 'halo move handle moves');
  await shot('06-halo');
  hp = await hpos('delete'); await p.mouse.click(hp.x, hp.y); await sleep(100);
  ok(await ev(() => morphic.allMorphs().length) === m0, 'halo delete handle');
  await p.keyboard.press('Escape'); await p.keyboard.press('u'); ok(await ev(() => morphic.allMorphs().length) === m0 + 1, 'u undoes the delete');
  await p.keyboard.press('Escape'); await p.keyboard.type('dd'); ok(await ev(() => morphic.allMorphs().length) === m0, 'dd deletes');
  await p.keyboard.type('yy'); ok(await ev(() => morphic.allMorphs().length) === m0 + 1, 'yy duplicates');

  // direct drag of a morph
  const target = await ev(() => morphic.allMorphs().find(m => m.id.startsWith('or_bladder')).id);
  c = await center(target); const bx = await slot(target, 'x');
  await p.mouse.move(c.x, c.y); await p.mouse.down(); await p.mouse.move(c.x + 50, c.y + 20, { steps: 6 }); await p.mouse.up();
  ok(await slot(target, 'x') > bx + 20, 'dragging a morph moves it');
  // alt-drag a layer
  c = await center('or_bladder'.length ? target : target); const lx = await ev(() => morphic.world.layerById.organs._.x);
  await p.keyboard.down('Alt'); await p.mouse.move(c.x, c.y); await p.mouse.down(); await p.mouse.move(c.x - 40, c.y, { steps: 5 }); await p.mouse.up(); await p.keyboard.up('Alt');
  ok(await ev(() => morphic.world.layerById.organs._.x) < lx - 20, 'alt-drag moves the whole layer');

  // save / reset / load / export
  await cmd('save'); const saved = await ev(() => localStorage.getItem('morphic-atlas.world.v1'));
  ok(!!saved && JSON.parse(saved).morphs.length === m0 + 1, ':save writes localStorage (' + (saved || '').length + ' bytes)');
  await cmd('reset'); ok(await ev(() => morphic.allMorphs().length) === m0 && await ev(() => morphic.world.layerById.organs._.x) === 0, ':reset restores defaults');
  await cmd('load'); ok(await ev(() => morphic.allMorphs().length) === m0 + 1 && await ev(() => morphic.world.layerById.organs._.x) < -20, ':load restores the saved world');
  const exp = await ev(() => { let got; const orig = URL.createObjectURL; URL.createObjectURL = (b) => { got = b; return orig.call(URL, b); }; morphic.cmd.exportJson(); return got.text().then(t => t.slice(0, 80)); });
  ok(/morphic-atlas-world/.test(exp), 'export JSON produces blob: ' + exp.slice(0, 60));
  await cmd('reset!'); ok(await ev(() => localStorage.getItem('morphic-atlas.world.v1')) === null, ':reset! clears saved copy');
  await cmd('foo'); ok((await ev(() => document.getElementById('msg').textContent)).includes('E492'), 'unknown command reports error');
  // eval in inspector
  await cmd('select femoral vein'); await p.keyboard.press('Escape'); await cmd('inspect');
  await ev(() => { const e = document.getElementById('evalIn'); e.value = 'this.strokeWidth = 9'; });
  await p.focus('#evalIn'); await p.keyboard.press('Enter'); await sleep(100);
  ok(await ev(() => morphic.world.sel.strokeWidth) === 9, 'inspector evaluator runs code against the morph');
  await cmd('reset');
  await cmd('explode 100'); await shot('07-exploded-max');
  await cmd('explode 0'); await p.keyboard.press('?'); await sleep(150); await shot('08-help');
  console.log('\nCONSOLE ERRORS/WARNINGS:', JSON.stringify(errs), '\nEXTERNAL REQUESTS:', JSON.stringify(reqs), '\nFAILS:', fails);
  await b.close();
})().catch(e => { console.error('SCRIPT ERROR', e); process.exit(1); });
