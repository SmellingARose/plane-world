// Attacker side: play as the germs (or as a god running both sides).
// Adds bio-mass economy, Germ Factories, Builder Phages that found new nests using a
// selectable strategy (default: stealth = outside the defender's radar), and the UI for it.
// Hot-reloadable: state lives in GW.atk and survives saves of this file.
(() => {
const T = THREE, { rand, $ } = GW;
const A = GW.atk ||= { bio:300, mode:'defend', strategy:'stealth', buildPref:'auto', aiWaves:true, autoBuilders:true, sel:new Set(), placing:null };
A.sel ||= new Set(); A.btnSig = null;

const COST = A.cost = { germ:10, runner:15, spitter:30, splitter:35, phage:40, brute:120, builder:250,
                        factory:150, hatchery:600, colony:250, hive:350, spire:400, mother:1200 };
const skin = (color, o={}) => new T.MeshStandardMaterial({ color, roughness:.3, metalness:.05, transparent:true, opacity:.88, ...o });
const glow = (color, i=2.5) => new T.MeshStandardMaterial({ color, emissive:color, emissiveIntensity:i, roughness:.4 });
const at = (o,x,y,z) => { o.position.set(x,y,z); return o; };
const hqOf = () => GW.ents.find(e => e.type === 'hq' && !e.dead);
const isBase = o => GW.def(o).cat === 'base';
function near(e, type, d){ const a = rand(0, 6.28), r = (d ?? GW.R(e) + 10) + rand(0, 15); return GW.spawn(type, { x:e.pos.x + Math.cos(a)*r, z:e.pos.z + Math.sin(a)*r }); }
function despawn(e){ e.dead = true; GW.scene.remove(e.g); GW.scene.remove(e.bar); A.sel.delete(e); }
const radarHit = (p, m) => GW.radarCovered ? GW.radarCovered(p, m) : false;

// ---------------- Builder site selection ----------------
function candidates(builder, n=70){
  const hq = hqOf(), c = hq ? hq.pos : { x:0, z:0 }, out = [];
  for (let i=0; i<n; i++){
    const a = rand(0, 6.28), r = rand(GW.BUILD_R + 80, 1800);
    let x = c.x + Math.cos(a)*r, z = c.z + Math.sin(a)*r;
    const d = Math.hypot(x, z); if (d > 1850){ x *= 1850/d; z *= 1850/d; }
    const p = { x, z };
    if (GW.heightAt(x, z) < -6) continue;
    if (hq && GW.flat(hq.pos, p) < GW.BUILD_R + 60) continue;
    if (GW.ents.some(o => !o.dead && (isBase(o) && GW.flat(o.pos, p) < 110 || o.site && o !== builder && GW.flat(o.site, p) < 110))) continue;
    out.push(p);
  }
  return out;
}
const byDist = (from, list) => list.sort((a, b) => GW.flat(a, from) - GW.flat(b, from));
const minBaseDist = p => Math.min(Infinity, ...GW.ents.filter(o => !o.dead && isBase(o)).map(o => GW.flat(o.pos, p)));
const STRATS = A.STRATS = {
  stealth:   { label:'Stealth — outside radar', pick(b, c){
    const hidden = c.filter(p => !radarHit(p, 80));
    if (hidden.length) return byDist(b.pos, hidden)[0];
    const hq = hqOf(); return hq ? c.sort((a, z) => GW.flat(z, hq.pos) - GW.flat(a, hq.pos))[0] : c[0]; } },
  aggressive:{ label:'Aggressive — close to their base', pick(b, c){ const hq = hqOf(); return hq ? byDist(hq.pos, c)[0] : c[0]; } },
  spread:    { label:'Spread — far from other nests', pick(b, c){ return c.sort((a, z) => minBaseDist(z) - minBaseDist(a))[0]; } },
  cluster:   { label:'Cluster — next to own nests', pick(b, c){ return c.sort((a, z) => minBaseDist(a) - minBaseDist(z))[0]; } },
  random:    { label:'Random', pick(b, c){ return c[Math.floor(Math.random()*c.length)]; } },
  mixed:     { label:'Mixed — each builder picks', pick(b, c){ b.strat ||= ['stealth','aggressive','spread','cluster'][Math.floor(Math.random()*4)]; return STRATS[b.strat].pick(b, c); } },
};
function pickSite(b){ const c = candidates(b); if (!c.length) return null; const p = (STRATS[A.strategy] || STRATS.stealth).pick(b, c); return p && new T.Vector3(p.x, 0, p.z); }
function chooseWhat(){
  if (A.buildPref !== 'auto') return A.buildPref;
  const w = GW.wave, opts = [['factory',3],['colony',3]];
  if (w >= 2) opts.push(['hive',2]); if (w >= 4) opts.push(['spire',1.5]);
  let r = rand(0, opts.reduce((s, o) => s + o[1], 0));
  for (const [t, wt] of opts){ if ((r -= wt) <= 0) return t; }
  return 'colony';
}

// ---------------- New enemy types ----------------
GW.type('factory', { label:'Germ Factory', side:'them', cat:'base', hp:500, r:18, bounty:200,
  onSpawn(e){ e.germT = 2; e.builderT = 12; },
  build(e, g){
    const flesh = skin(0xc0607a, { opacity:1, emissive:0x2a0810, flatShading:true });
    g.add(at(new T.Mesh(new T.CylinderGeometry(17, 19, 10, 10), flesh), 0, 5, 0));
    g.add(at(new T.Mesh(new T.SphereGeometry(15, 20, 10, 0, 6.28, 0, 1.4), flesh), 0, 9, 0));
    e.parts.vats = [];
    for (let i=0;i<3;i++){
      const a = i/3*6.28, x = Math.cos(a)*15, z = Math.sin(a)*15;
      g.add(at(new T.Mesh(new T.CylinderGeometry(4.5, 4.5, 16, 12), skin(0xccffee, { opacity:.35, depthWrite:false })), x, 10, z));
      const goo = at(new T.Mesh(new T.CylinderGeometry(3.8, 3.8, 1, 12), glow(0x66ff66, 2.5)), x, 6, z); g.add(goo); e.parts.vats.push(goo);
    }
    const chim = at(new T.Mesh(new T.CylinderGeometry(2.5, 3.5, 14, 8), skin(0x7a3040, { opacity:1 })), 0, 26, 0); g.add(chim);
  },
  tick(e, dt){
    e.parts.vats.forEach((v, i) => { const h = 4 + (Math.sin(e.t*1.5 + i*2) + 1)*5; v.scale.y = h; v.position.y = 2 + h/2; });
    if ((e.puff = (e.puff||0) - dt) <= 0){ e.puff = .25; GW.fx.puff(e.pos.clone().setY(e.pos.y + 34), 0x88aa77, 4); }
    if ((e.germT -= dt) <= 0){ e.germT = Math.max(1.5, 3.5 - GW.wave*.15); if (GW.count('them') < 70 + GW.wave*30) near(e, 'germ'); }
  },
});

// Phage Hatchery: the only nest that breeds Builder Phages. Expensive, slow, high value.
GW.type('hatchery', { label:'Phage Hatchery', side:'them', cat:'base', hp:900, r:20, bounty:450, barY:70,
  info:e => `Next builder in ${Math.max(0, Math.ceil(e.builderT))}s`,
  onSpawn(e){ e.builderT = 10; },
  build(e, g){
    const shell = skin(0x8a6a2a, { opacity:1, flatShading:true, emissive:0x1a1004 });
    g.add(at(new T.Mesh(new T.CylinderGeometry(14, 22, 14, 9), shell), 0, 7, 0));
    // twisted ribs rising to a crown
    for (let i=0;i<7;i++){ const a = i/7*6.28, rib = new T.Mesh(new T.CylinderGeometry(1.2, 2.6, 46, 6), shell);
      rib.position.set(Math.cos(a)*11, 30, Math.sin(a)*11); rib.rotation.set(Math.sin(a)*.25, 0, -Math.cos(a)*.25); g.add(rib); }
    e.parts.womb = at(new T.Mesh(new T.SphereGeometry(9, 20, 14), skin(0xffe9a0, { opacity:.5, depthWrite:false })), 0, 34, 0); g.add(e.parts.womb);
    e.parts.embryo = at(new T.Mesh(new T.IcosahedronGeometry(3.5, 0), glow(0xffcc55, 2)), 0, 34, 0); g.add(e.parts.embryo);
    e.parts.eggs = [];
    for (let i=0;i<5;i++){ const a = i/5*6.28 + .3, egg = new T.Mesh(new T.SphereGeometry(3.4, 12, 10), skin(0xf0d890, { opacity:.8 }));
      egg.scale.y = 1.4; egg.position.set(Math.cos(a)*19, 16, Math.sin(a)*19); g.add(egg); e.parts.eggs.push(egg); }
  },
  tick(e, dt){
    const p = 1 - Math.max(0, e.builderT)/30;            // gestation progress
    e.parts.embryo.scale.setScalar(.6 + p*1.4); e.parts.embryo.rotation.y += dt*(1 + p*4);
    e.parts.womb.scale.setScalar(1 + .06*Math.sin(e.t*(2 + p*6)));
    e.parts.eggs.forEach((g, i) => g.scale.set(1, 1.4 + .15*Math.sin(e.t*3 + i), 1));
    if (!A.autoBuilders) return;
    if ((e.builderT -= dt) <= 0){
      e.builderT = 30;
      if (GW.ents.filter(o => o.type === 'builder' && !o.dead).length < 2 + GW.wave/2){
        const b = near(e, 'builder', 6); b.pos.y = e.pos.y + 34; GW.fx.shock(e.pos, 0xffcc55, 50);
      }
    }
  },
});

GW.type('builder', { label:'Builder Phage', side:'them', air:true, alt:35, hp:70, r:6, speed:34, bounty:25, deathColor:0xffdd44,
  info:e => e.site ? `Building ${e.what}` : 'Looking for a site',
  build(e, g){
    const m = new T.MeshStandardMaterial({ color:0xffcc55, metalness:.75, roughness:.3 });
    g.add(at(new T.Mesh(new T.IcosahedronGeometry(5, 0), m), 0, 12, 0));
    g.add(at(new T.Mesh(new T.CylinderGeometry(1.2, 1.2, 9, 8), m), 0, 4, 0));
    e.parts.seed = at(new T.Mesh(new T.SphereGeometry(3, 12, 8), glow(0x66ff88, 3)), 0, -2, 0); g.add(e.parts.seed);
    const legs = new T.Group(); g.add(legs); e.parts.legs = legs;
    for (let i=0;i<4;i++){ const a = i/4*6.28, l = new T.Mesh(new T.CylinderGeometry(.4, .4, 8, 6), m); l.position.set(Math.cos(a)*3.5, -1, Math.sin(a)*3.5); l.rotation.set(Math.sin(a)*.9, 0, -Math.cos(a)*.9); legs.add(l); }
  },
  tick(e, dt){
    if (e.order){ if (e.order.type === 'move'){ e.site = e.order.p.clone(); e.manual = true; } e.order = null; }
    if (!e.manual && (e.recheck = (e.recheck||0) - dt) <= 0){
      e.recheck = 5;
      const stale = !e.site || ((A.strategy === 'stealth' || e.strat === 'stealth') && radarHit(e.site, 40));
      if (stale){ e.site = pickSite(e); e.what ||= chooseWhat(); }
    }
    e.what ||= chooseWhat();
    e.parts.legs.rotation.y += dt*2; e.parts.seed.scale.setScalar(1 + .2*Math.sin(e.t*6));
    const arrived = e.site && GW.moveToward(e, e.site, GW.types.builder.speed, dt, 4);
    const want = GW.heightAt(e.pos.x, e.pos.z) + (arrived ? 8 : 35) + Math.sin(e.t*2)*2;
    e.pos.y += (want - e.pos.y)*Math.min(1, dt*2);
    if (arrived && (e.buildT = (e.buildT||0) + dt) > 1.2){
      GW.spawn('cocoon', e.site, { into:e.what });
      GW.fx.ring(e.site, 0x66ff88, 40);
      despawn(e);
    }
  },
});

GW.type('cocoon', { label:'Nest (growing)', side:'them', cat:'base', hp:250, r:14, bounty:60, barY:40,
  info:e => `Becoming ${e.into} · ${Math.round((e.prog||0)*100)}%`,
  build(e, g){
    e.parts.shell = at(new T.Mesh(new T.SphereGeometry(1, 20, 14), skin(0xd6ffd0, { opacity:.45, depthWrite:false })), 0, 10, 0); g.add(e.parts.shell);
    e.parts.core = at(new T.Mesh(new T.IcosahedronGeometry(1, 1), glow(0x66ff88, 3)), 0, 10, 0); g.add(e.parts.core);
    for (let i=0;i<5;i++){ const a = i/5*6.28, r = new T.Mesh(new T.CylinderGeometry(.6, 1, 20, 5), skin(0x88aa77, { opacity:1 })); r.position.set(Math.cos(a)*10, 6, Math.sin(a)*10); r.rotation.set(Math.sin(a)*-.5, 0, Math.cos(a)*.5); g.add(r); }
  },
  tick(e, dt){
    e.prog = Math.min(1, (e.prog||0) + dt/14);
    const s = 4 + e.prog*10; e.parts.shell.scale.set(s, s*1.2, s); e.parts.core.scale.setScalar(2 + e.prog*3 + Math.sin(e.t*8)*.4);
    e.parts.core.rotation.y += dt*2;
    if (e.prog >= 1){
      despawn(e); GW.spawn(e.into || 'colony', e.pos); GW.fx.shock(e.pos, 0x99ff66, 80);
      if (A.mode !== 'defend') GW.toast(`New ${GW.types[e.into]?.label || e.into} hatched`, '#aaff88');
    }
  },
});

// ---------------- Economy ----------------
GW.restartHooks.atk = () => { A.bio = 300; A.sel.clear(); A.placing = null; };
GW.frameHooks.atkEconomy = dt => {
  if (GW.paused || GW.over) return;
  const bases = GW.ents.filter(e => e.side === 'them' && isBase(e) && !e.dead).length;
  A.bio += (4 + bases*1.5)*dt*GW.speed;
};

// ---------------- Visual helpers: selection rings, radar coverage, builder sites ----------------
if (A.vis){ for (const m of A.vis.all) GW.scene.remove(m); }
A.vis = { all:[] };
function pool(name, make){
  const list = A.vis[name] = [];
  return i => { if (!list[i]){ const m = make(); m.rotation.x = -Math.PI/2; m.raycast = () => {}; GW.scene.add(m); list.push(m); A.vis.all.push(m); } list[i].visible = true; return list[i]; };
}
const ringMat = (c, o) => new T.MeshBasicMaterial({ color:c, transparent:true, opacity:o, depthWrite:false, toneMapped:false, side:T.DoubleSide });
const selRing = pool('sel', () => new T.Mesh(new T.RingGeometry(.85, 1, 32), ringMat(0xff4466, .9)));
const radarDisc = pool('radar', () => new T.Mesh(new T.CircleGeometry(1, 64), ringMat(0x33ffcc, .07)));
const radarEdge = pool('radarEdge', () => new T.Mesh(new T.RingGeometry(.99, 1, 96), ringMat(0x33ffcc, .5)));
const siteRing = pool('site', () => new T.Mesh(new T.RingGeometry(.8, 1, 24), ringMat(0xffcc44, .9)));
function hideFrom(name, n){ const l = A.vis[name]; for (let i=n; i<l.length; i++) l[i].visible = false; }

GW.frameHooks.atkVisuals = () => {
  const show = A.mode !== 'defend';
  let n = 0;
  for (const e of [...A.sel]){ if (e.dead){ A.sel.delete(e); continue; } const r = selRing(n++); const R = GW.R(e) + 6; r.scale.setScalar(R); r.position.set(e.pos.x, GW.heightAt(e.pos.x, e.pos.z) + 1.5, e.pos.z); }
  hideFrom('sel', n);
  n = 0;
  if (show) for (const e of GW.ents){
    const rr = !e.dead && e.side === 'us' && GW.def(e).radar && GW.stat(e, 'radar'); if (!rr) continue;
    const d = radarDisc(n), g = radarEdge(n); n++;
    d.scale.setScalar(rr); g.scale.setScalar(rr); d.position.set(e.pos.x, 2, e.pos.z); g.position.set(e.pos.x, 2.2, e.pos.z);
  }
  hideFrom('radar', n); hideFrom('radarEdge', n);
  n = 0;
  if (show) for (const e of GW.ents){
    if (e.type !== 'builder' || e.dead || !e.site) continue;
    const s = siteRing(n++); s.scale.setScalar(14 + Math.sin(performance.now()/200)*3);
    s.position.set(e.site.x, GW.heightAt(e.site.x, e.site.z) + 2, e.site.z);
  }
  hideFrom('site', n);
  updatePanel();
};

// ---------------- UI ----------------
for (const id of ['atkStyle','modeBar','atkPanel']) $(id)?.remove();
document.head.insertAdjacentHTML('beforeend', `<style id="atkStyle">
  #modeBar { position:fixed; top:10px; left:50%; transform:translateX(-50%); display:flex; gap:4px; background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:4px; }
  #modeBar button { padding:5px 12px; border:0; background:transparent; }
  #modeBar button.on { background:#17463a; }
  #modeBar button.atk.on { background:#5a1830; }
  #atkPanel { top:90px; left:14px; width:250px; max-height:calc(100% - 240px); overflow:auto; display:none; border-color:#6a2a40; }
  #atkPanel h3 { color:#ff7a9a; }
  #atkPanel .bio { color:#9fff7a; font-size:16px; }
  #atkPanel .grid { display:grid; grid-template-columns:1fr 1fr; gap:5px; }
  #atkPanel button { padding:5px 8px; }
  #atkPanel button small { color:#9fff7a; }
  #atkPanel button.on { background:#5a1830; border-color:#ff7a9a; }
  #atkPanel select { width:100%; font:inherit; background:#140c12; color:var(--fg); border:1px solid #6a2a40; border-radius:6px; padding:4px; }
  #atkPanel label { display:block; margin:4px 0; }
  @media (max-width:820px){ #atkPanel { top:auto; bottom:12px; max-height:45%; } #modeBar { top:64px; left:auto; right:14px; transform:none; } }
</style>`);
document.body.insertAdjacentHTML('beforeend', `
<div id="modeBar">
  <button data-mode="defend">🛡 Defender</button><button data-mode="attack" class="atk">🦠 Attacker</button><button data-mode="god" class="atk">⚡ God (both)</button>
</div>
<div id="atkPanel" class="panel">
  <h3>🦠 Infection command</h3>
  <div class="bio" id="atkBio"></div>
  <h4>Spawn units (click map)</h4><div class="grid" id="atkUnits"></div>
  <h4>Plant nests (click map)</h4><div class="grid" id="atkBases"></div>
  <h4>Builder phages</h4>
  <label>Site strategy<select id="atkStrat"></select></label>
  <label>Builders make<select id="atkWhat"></select></label>
  <label><input type="checkbox" id="atkAuto"> Hatcheries breed builders</label>
  <label><input type="checkbox" id="atkWaves"> AI waves running</label>
  <h4>Army</h4>
  <div class="grid"><button id="atkAll">Select all</button><button id="atkCharge">⚔ All attack HQ</button></div>
  <div class="row" id="atkSelInfo" style="margin-top:6px;opacity:.8"></div>
</div>`);

const UNITS = ['germ','runner','spitter','splitter','phage','brute','builder'], BASES = ['factory','hatchery','colony','hive','spire','mother'];
function fillButtons(id, list){
  $(id).innerHTML = '';
  for (const t of list){
    const d = GW.types[t]; if (!d) continue;
    const b = document.createElement('button'); b.dataset.type = t;
    b.innerHTML = `${(d.label || t).replace(' (boss)','').replace(' (flying)','')}<small>${COST[t]} bio</small>`;
    b.onclick = () => { A.placing = A.placing === t ? null : t; markPlacing(); if (A.placing) GW.toast(`Click the map to place ${d.label || t} (shift = repeat)`); };
    $(id).appendChild(b);
  }
}
function markPlacing(){ document.querySelectorAll('#atkPanel [data-type]').forEach(b => b.classList.toggle('on', b.dataset.type === A.placing)); }
fillButtons('atkUnits', UNITS); fillButtons('atkBases', BASES);
$('atkStrat').innerHTML = Object.entries(STRATS).map(([k, s]) => `<option value="${k}">${s.label}</option>`).join('');
$('atkWhat').innerHTML = ['auto','factory','colony','hive','spire'].map(k => `<option value="${k}">${k === 'auto' ? 'Auto (mix by wave)' : GW.types[k]?.label || k}</option>`).join('');
$('atkStrat').value = A.strategy; $('atkWhat').value = A.buildPref; $('atkAuto').checked = A.autoBuilders; $('atkWaves').checked = A.aiWaves;
$('atkStrat').onchange = e => { A.strategy = e.target.value; for (const b of GW.ents) if (b.type === 'builder' && !b.manual){ b.site = null; b.recheck = 0; b.strat = null; } GW.toast(`Builder strategy: ${STRATS[A.strategy].label}`); };
$('atkWhat').onchange = e => { A.buildPref = e.target.value; for (const b of GW.ents) if (b.type === 'builder') b.what = null; };
$('atkAuto').onchange = e => { A.autoBuilders = e.target.checked; };
$('atkWaves').onchange = e => { A.aiWaves = e.target.checked; };
$('atkAll').onclick = () => { A.sel.clear(); for (const e of GW.ents) if (e.side === 'them' && !isBase(e) && !e.dead) A.sel.add(e); };
$('atkCharge').onclick = () => { const hq = hqOf(); if (!hq) return; for (const e of GW.ents) if (e.side === 'them' && !isBase(e) && e.type !== 'builder') e.order = { type:'attack', t:hq }; GW.toast('⚔ The swarm charges the HQ!', '#ff8aa8'); };

function setMode(m){
  A.mode = m;
  document.querySelectorAll('#modeBar button').forEach(b => b.classList.toggle('on', b.dataset.mode === m));
  $('atkPanel').style.display = m === 'defend' ? 'none' : 'block';
  $('build').style.display = m === 'attack' ? 'none' : 'flex';
  if (m === 'attack'){ GW.selected.clear(); GW.refreshPanel(); }
  if (m === 'defend'){ A.sel.clear(); A.placing = null; markPlacing(); }
}
document.querySelectorAll('#modeBar button').forEach(b => b.onclick = () => setMode(b.dataset.mode));
setMode(A.mode);

let lastInfo = '';
function updatePanel(){
  if (A.mode === 'defend') return;
  // attackers.js can load before enemies.js, so fill the buttons once all types exist
  const sig = UNITS.concat(BASES).map(t => GW.types[t]?.label).join();
  if (sig !== A.btnSig){ A.btnSig = sig; fillButtons('atkUnits', UNITS); fillButtons('atkBases', BASES); }
  $('atkBio').textContent = `${Math.floor(A.bio)} bio-mass`;
  for (const b of document.querySelectorAll('#atkPanel [data-type]')) b.disabled = !GW.god && A.bio < COST[b.dataset.type];
  const counts = {}; for (const e of A.sel) counts[e.type] = (counts[e.type]||0) + 1;
  const info = A.sel.size ? `Selected ${A.sel.size}: ${Object.entries(counts).map(([k,v]) => `${k}×${v}`).join(', ')}<br>Click ground = move (builders: build there) · click defender = attack`
                          : 'Click your organisms to select them (shift adds).';
  if (info !== lastInfo){ $('atkSelInfo').innerHTML = info; lastInfo = info; }
}

// ---------------- Input: attacker clicks ----------------
GW.clickHooks.atk = (e, btn) => {
  if (A.mode === 'defend') return false;
  if (A.placing){
    if (btn === 2){ A.placing = null; markPlacing(); return true; }
    const p = GW.pickGround(e); if (!p) return true;
    const t = A.placing, cost = COST[t], hq = hqOf();
    if (!GW.god && A.bio < cost){ GW.toast('Not enough bio-mass', '#ff7a7a'); return true; }
    if (hq && GW.flat(hq.pos, p) < (isBase({ type:t }) ? GW.BUILD_R*.6 : 120)){ GW.toast('Too close to the defenders’ HQ', '#ff7a7a'); return true; }
    if (!GW.god) A.bio -= cost;
    const u = GW.spawn(t, p); GW.fx.ring(p, 0xff4466, GW.R(u) + 12);
    if (!e.shiftKey){ A.placing = null; markPlacing(); }
    return true;
  }
  const ent = GW.pickEnt(e);
  if (ent && ent.side === 'them' && btn === 0){
    if (!e.shiftKey) A.sel.clear();
    if (e.shiftKey && A.sel.has(ent)) A.sel.delete(ent); else A.sel.add(ent);
    GW.selected.clear(); GW.refreshPanel();
    return true;
  }
  if (A.sel.size){
    if (ent && ent.side === 'us'){ for (const s of A.sel) s.order = { type:'attack', t:ent }; GW.fx.ring(ent.pos, 0xff4466, GW.R(ent) + 10); return true; }
    const p = GW.pickGround(e);
    if (p){
      const movers = [...A.sel].filter(s => !isBase(s) || GW.def(s).speed), cols = Math.ceil(Math.sqrt(movers.length));
      movers.forEach((s, i) => { s.order = { type:'move', p:new T.Vector3(p.x + (i%cols - (cols-1)/2)*22, 0, p.z + (Math.floor(i/cols) - (cols-1)/2)*22) }; });
      GW.fx.ring(p, 0xff4466, 18);
      return true;
    }
  }
  if (btn === 0 && A.sel.size && !ent){ A.sel.clear(); }
  return A.mode === 'attack';   // in God mode, let defender clicks through
};

if (A.onKey) removeEventListener('keydown', A.onKey);
A.onKey = e => { if (e.code === 'Escape'){ A.sel.clear(); A.placing = null; markPlacing(); } };
addEventListener('keydown', A.onKey);
})();
