// Germ War engine: renderer, entity system, input, UI and the live-reload channel.
// All game content (world, buildings, enemies, waves) lives in mods/*.js and hot-reloads
// while the game runs. Everything is reachable through the global `GW` object.
(() => {
const T = THREE, $ = id => document.getElementById(id);
const rand = (a,b) => a + Math.random()*(b-a);
const GW = window.GW = {
  types:{}, ents:[], projs:[], hooks:{}, frameHooks:{}, clickHooks:{}, restartHooks:{}, selected:new Set(),
  money:0, wave:0, waveT:0, time:0, kills:0, income:0, over:false, paused:false, speed:1, god:false,
  BUILD_R:420, G:30, rand, $,
};

// ---------- Renderer ----------
const renderer = new T.WebGLRenderer({ antialias:true });
renderer.setPixelRatio(Math.min(2, devicePixelRatio)); renderer.setSize(innerWidth, innerHeight);
renderer.shadowMap.enabled = true; renderer.shadowMap.type = T.PCFSoftShadowMap;
renderer.toneMapping = T.ACESFilmicToneMapping; renderer.toneMappingExposure = 1.05;
document.body.prepend(renderer.domElement);
const scene = new T.Scene();
scene.background = new T.Color(0x050a10);
const camera = new T.PerspectiveCamera(55, innerWidth/innerHeight, 1, 14000);
const hemi = new T.HemisphereLight(0x9fd8ff, 0x2a1030, .8); scene.add(hemi);
const sun = new T.DirectionalLight(0xffe8d0, 2); sun.castShadow = true;
sun.shadow.mapSize.set(2048, 2048);
Object.assign(sun.shadow.camera, { left:-750, right:750, top:750, bottom:-750, near:10, far:3500 });
sun.shadow.bias = -0.0006; scene.add(sun, sun.target);
const composer = new POST.EffectComposer(renderer);
composer.addPass(new POST.RenderPass(scene, camera));
const bloom = new POST.UnrealBloomPass(new T.Vector2(innerWidth, innerHeight), .75, .55, .82);
composer.addPass(bloom); composer.addPass(new POST.OutputPass());
Object.assign(GW, { renderer, scene, camera, hemi, sun, bloom, composer });
GW.heightAt = () => 0;   // replaced by mods/world.js

// ---------- Health bars & rings ----------
const planeGeo = new T.PlaneGeometry(1,1);
function makeBar(w){
  const g = new T.Group();
  const bg = new T.Mesh(planeGeo, new T.MeshBasicMaterial({ color:0x220000, depthTest:false, toneMapped:false }));
  const fg = new T.Mesh(planeGeo, new T.MeshBasicMaterial({ color:0x44ff66, depthTest:false, toneMapped:false }));
  bg.scale.set(w,2.2,1); fg.scale.set(w,2.2,1); bg.renderOrder = 10; fg.renderOrder = 11;
  g.add(bg, fg); g.userData = { fg, w }; scene.add(g); return g;
}
function updBar(e){
  const def = GW.def(e), bar = e.bar, ratio = Math.max(0, e.hp/e.maxHp);
  bar.visible = e.side === 'us' || def.cat === 'base' || ratio < .999;
  if (!bar.visible) return;
  bar.position.set(e.pos.x, e.pos.y + (def.barY ?? def.r*1.4 + 16), e.pos.z); bar.quaternion.copy(camera.quaternion);
  const { fg, w } = bar.userData;
  fg.scale.x = Math.max(.001, w*ratio); fg.position.x = -(w - w*ratio)/2;
  fg.material.color.setHex(e.side === 'them' ? 0xff5566 : ratio > .5 ? 0x44ff66 : ratio > .25 ? 0xffcc33 : 0xff4433);
}
function flatRing(color, op=.5){
  const m = new T.Mesh(new T.RingGeometry(.994, 1, 128), new T.MeshBasicMaterial({ color, transparent:true, opacity:op, depthWrite:false, toneMapped:false }));
  m.rotation.x = -Math.PI/2; m.visible = false; scene.add(m); return m;
}
const buildRing = flatRing(0x44ff99, .6), rangeRing = flatRing(0xffaa55, .7);

// ---------- Entities ----------
let uid = 0;
GW.def = e => GW.types[e.type] || {};
GW.type = (name, def) => {
  GW.types[name] = Object.assign({ name, side:'us', r:8, hp:100 }, def);
  GW.ui?.refreshLists(); return GW.types[name];
};
GW.spawn = (type, pos, o={}) => {
  const def = GW.types[type]; if (!def) throw new Error('unknown type: ' + type);
  const g = new T.Group();
  const e = Object.assign({ id:++uid, type, side:def.side, g, pos:g.position, hp:def.hp, maxHp:def.hp, lvl:1, cd:0, t:0,
                            auto:true, parts:{}, spent:def.cost||0, ph:rand(0,6.28) }, o);
  const gy = GW.heightAt(pos.x, pos.z);
  g.position.set(pos.x, def.air ? gy + (def.alt||40) : gy, pos.z);
  def.build?.(e, g);
  e.mats = [];
  g.traverse(m => {
    if (!m.isMesh) return;
    m.castShadow = def.shadow !== false && !m.material.transparent; m.receiveShadow = true; m.userData.ent = e;
    if (m.material.emissive && !e.mats.includes(m.material)){ m.material.userData.e0 = m.material.emissive.getHex(); e.mats.push(m.material); }
  });
  if (e.side === 'us'){
    const ring = new T.Mesh(new T.RingGeometry(def.r+5, def.r+7, 40), new T.MeshBasicMaterial({ color:0x66ffaa, toneMapped:false }));
    ring.rotation.x = -Math.PI/2; ring.position.y = .8; ring.visible = false; ring.raycast = () => {}; g.add(ring); e.ring = ring;
  }
  e.bar = makeBar(Math.max(14, def.r*1.6));
  scene.add(g); GW.ents.push(e); def.onSpawn?.(e); return e;
};
GW.damage = (e, amt, src) => {
  if (e.dead || (GW.god && e.side === 'us')) return;
  const def = GW.def(e);
  amt *= 1 - (def.armor || 0);
  if (def.onHurt) amt = def.onHurt(e, amt, src) ?? amt;
  e.hp -= amt; e.hitT = .1;
  if (e.hp <= 0) GW.kill(e, src);
};
GW.kill = (e, src) => {
  if (e.dead) return; e.dead = true;
  scene.remove(e.g); scene.remove(e.bar);
  const def = GW.def(e);
  try { def.onDeath?.(e, src); } catch (err){ reportErr(err, e.type + '.onDeath'); }
  GW.fx.explode(e.pos.clone().setY(e.pos.y + def.r*.6), def.deathColor ?? (e.side === 'us' ? 0xff8833 : 0x99ff55), def.r*2.2 + 6);
  if (e.side === 'them'){
    GW.money += def.bounty || 0; GW.kills++;
    if (def.cat === 'base'){ GW.toast(`${def.label || def.name} destroyed! +$${def.bounty||0}`); GW.fx.shock(e.pos, 0xccff66, def.r*5); }
  } else if (GW.selected.delete(e)) refreshPanel();
};
GW.count = side => { let n = 0; for (const e of GW.ents) if (!e.dead && e.side === side) n++; return n; };

// ---------- Queries & helpers for mods ----------
GW.flat = (a,b) => Math.hypot(a.x-b.x, a.z-b.z);
GW.R = o => GW.types[o.type]?.r || 4;
GW.foeSide = e => e.side === 'us' ? 'them' : 'us';
GW.nearest = (pos, side, range=Infinity, filter) => {
  let best = null, bd = range;
  for (const o of GW.ents){ if (o.dead || o.side !== side || (filter && !filter(o))) continue;
    const d = GW.flat(o.pos, pos) - GW.R(o); if (d < bd){ bd = d; best = o; } }
  return best;
};
GW.within = (pos, side, r, filter) => GW.ents.filter(o => !o.dead && o.side === side && GW.flat(o.pos,pos) - GW.R(o) <= r && (!filter || filter(o)));
GW.acquire = (e, range, filter) => {
  const a = e.attack;
  if (a && !a.dead && GW.flat(a.pos, e.pos) - GW.R(a) <= range && (!filter || filter(a))) return a;
  return GW.nearest(e.pos, GW.foeSide(e), range, filter);
};
GW.stat = (e, k) => { const def = GW.def(e), v = def[k]; if (typeof v !== 'number') return v; return v * Math.max(.1, 1 + (def.upg?.[k] || 0)*(e.lvl-1)); };
GW.aim = (e, p) => { const h = e.parts.head; if (h) h.rotation.y = Math.atan2(p.x-e.pos.x, p.z-e.pos.z) - e.g.rotation.y; };
GW.moveToward = (e, dest, speed, dt, stopAt=3, turn=true) => {
  const dx = dest.x-e.pos.x, dz = dest.z-e.pos.z, d = Math.hypot(dx,dz);
  if (d <= stopAt) return true;
  const st = Math.min(d - stopAt + .01, speed*dt); e.pos.x += dx/d*st; e.pos.z += dz/d*st;
  if (turn) e.g.rotation.y = Math.atan2(dx, dz);
  return false;
};
// Player unit brain: manual move > attack order > auto-hunt
GW.unitAI = (e, dt, range) => {
  const def = GW.def(e);
  if (e.attack && e.attack.dead) e.attack = null;
  let goal = null;
  if (e.dest) goal = e.dest;
  else if (e.attack){ if (GW.flat(e.attack.pos, e.pos) - GW.R(e.attack) > range*.85) goal = e.attack.pos; }
  else if (e.auto && def.canAttack){
    const t = GW.nearest(e.pos, GW.foeSide(e), 750, def.targets);
    if (t && GW.flat(t.pos, e.pos) - GW.R(t) > range*.85) goal = t.pos;
  }
  if (goal && GW.moveToward(e, goal, GW.stat(e,'speed'), dt) && goal === e.dest) e.dest = null;
};
GW.upgCost = e => Math.round((GW.def(e).cost || 100) * .7 * e.lvl);
GW.upgrade = e => {
  const def = GW.def(e), c = GW.upgCost(e);
  if (!def.maxLvl || e.lvl >= def.maxLvl || GW.money < c) return false;
  GW.money -= c; e.spent += c; e.lvl++;
  e.maxHp = Math.round(def.hp * (1 + (def.upg?.hp ?? .25)*(e.lvl-1))); e.hp = e.maxHp;
  def.onUpgrade?.(e); GW.fx.shock(e.pos, 0x66ffaa, 40); GW.toast(`${def.label||def.name} → level ${e.lvl}`);
  refreshPanel(); return true;
};
GW.sell = e => { GW.money += Math.round(e.spent*.5); e.hp = 0; GW.kill(e); };

// ---------- Projectiles ----------
GW.addProj = p => { GW.projs.push(p); return p; };
GW.lob = (from, to, T_, o={}) => {
  const vel = new T.Vector3().subVectors(to, from).divideScalar(T_); vel.y += .5*GW.G*T_;
  const mesh = o.mesh; mesh.position.copy(from); scene.add(mesh);
  return GW.addProj({ mesh, pos:mesh.position, vel, interceptable:o.interceptable, smoke:0, tick(p, dt){
    p.vel.y -= GW.G*dt; p.pos.addScaledVector(p.vel, dt); p.mesh.lookAt(p.pos.clone().add(p.vel));
    if (o.trail != null && (p.smoke -= dt) <= 0){ GW.fx.puff(p.pos, o.trail); p.smoke = .045; }
    if (p.pos.y <= GW.heightAt(p.pos.x, p.pos.z)){ o.onHit?.(p.pos.clone()); return false; }
    return true; } });
};
GW.homing = (from, target, speed, o={}) => {
  const mesh = o.mesh; mesh.position.copy(from); scene.add(mesh);
  return GW.addProj({ mesh, pos:mesh.position, target, life:o.life || 5, smoke:0, tick(p, dt){
    p.life -= dt;
    if (!p.target || p.target.dead) p.target = o.retarget?.(p);
    if (!p.target || p.life <= 0){ GW.fx.explode(p.pos, 0x88aaff, 5); return false; }
    const tp = p.target.pos.clone(); if (p.target.type) tp.y += GW.R(p.target)*.7;
    const dist = p.pos.distanceTo(tp);
    if (p.target.vel && o.lead !== false) tp.addScaledVector(p.target.vel, dist/speed);
    const dir = tp.sub(p.pos).normalize();
    p.pos.addScaledVector(dir, speed*dt); p.mesh.lookAt(p.pos.clone().add(dir));
    if (o.trail != null && (p.smoke -= dt) <= 0){ GW.fx.puff(p.pos, o.trail, 2); p.smoke = .04; }
    if (dist < (o.hitR || 8)){ o.onHit?.(p.target, p.pos.clone()); return false; }
    return true; } });
};

// ---------- Effects ----------
let fxList = [];
const sphereGeo = new T.SphereGeometry(1, 12, 8), lowSphere = new T.IcosahedronGeometry(1, 0);
const addMat = (color, opacity=1) => new T.MeshBasicMaterial({ color, transparent:true, opacity, blending:T.AdditiveBlending, depthWrite:false });
GW.fx = {
  add(obj, life, upd, disposeGeo=false){ scene.add(obj); fxList.push({ obj, t:0, life, upd, disposeGeo }); return obj; },
  explode(pos, color=0xff8833, size=20){
    const m = new T.Mesh(sphereGeo, addMat(color)); m.position.copy(pos);
    this.add(m, .6, k => { m.scale.setScalar(size*(.25 + .75*Math.min(1, k*3))); m.material.opacity = 1-k; });
    const n = Math.min(10, 3 + size/6|0);
    for (let i=0;i<n;i++) this.particle(pos, new T.Vector3(rand(-1,1), rand(.2,1.4), rand(-1,1)).multiplyScalar(size*2.2), { color, size:size*.12+1, life:.6 });
  },
  particle(pos, vel, { color=0xffaa44, size=3, life=.6, grow=1, gravity=0 }={}){
    const m = new T.Mesh(lowSphere, addMat(color)); m.position.copy(pos); const v = vel.clone();
    this.add(m, life, (k, dt) => { v.y -= gravity*dt; m.position.addScaledVector(v, dt); m.scale.setScalar(size*(1 + grow*k)); m.material.opacity = 1-k; });
  },
  puff(pos, color=0x888888, size=3){
    const m = new T.Mesh(lowSphere, new T.MeshBasicMaterial({ color, transparent:true, opacity:.4, depthWrite:false }));
    m.position.copy(pos); this.add(m, 1.1, k => { m.scale.setScalar(size*(1+k*2.5)); m.material.opacity = .4*(1-k); m.position.y += .15; });
  },
  line(points, color, life=.08, opacity=1){
    const l = new T.Line(new T.BufferGeometry().setFromPoints(points), new T.LineBasicMaterial({ color, transparent:true, blending:T.AdditiveBlending }));
    this.add(l, life, k => { l.material.opacity = opacity*(1-k); }, true);
  },
  tracer(a, b, color=0xffee88){ this.line([a.clone(), b.clone()], color, .07); },
  lightning(a, b, color=0x99ddff){
    for (let pass=0; pass<2; pass++){
      const pts = [a.clone()], n = 9;
      for (let i=1;i<n;i++){ const p = a.clone().lerp(b, i/n); p.x += rand(-6,6); p.y += rand(-6,6); p.z += rand(-6,6); pts.push(p); }
      pts.push(b.clone()); this.line(pts, color, .14);
    }
  },
  ring(pos, color, r=20, life=.6){
    const m = new T.Mesh(new T.RingGeometry(.85, 1, 48), addMat(color, .8)); m.rotation.x = -Math.PI/2;
    m.position.set(pos.x, pos.y + 1, pos.z);
    this.add(m, life, k => { m.scale.setScalar(Math.max(.01, r*k)); m.material.opacity = .8*(1-k); }, true);
  },
  shock(pos, color, r=60){ this.ring(pos, color, r, .7); },
};
function updateFx(dt){
  for (const f of fxList){ f.t += dt; f.upd(Math.min(1, f.t/f.life), dt); }
  fxList = fxList.filter(f => {
    if (f.t < f.life) return true;
    scene.remove(f.obj); f.obj.material?.dispose(); if (f.disposeGeo) f.obj.geometry.dispose(); return false;
  });
}

// ---------- Toasts & errors ----------
GW.toast = (msg, color) => {
  const d = document.createElement('div'); d.textContent = msg; if (color) d.style.color = color;
  $('toasts').appendChild(d);
  while ($('toasts').children.length > 4) $('toasts').firstChild.remove();
  setTimeout(() => { d.style.opacity = 0; setTimeout(() => d.remove(), 600); }, 2800);
};
const errSeen = {};
function reportErr(err, where){
  console.error(where, err);
  const now = performance.now(); if (errSeen[where] && now - errSeen[where] < 3000) return;
  errSeen[where] = now; GW.toast(`⚠ ${where}: ${err.message}`, '#ff7a7a');
}
GW.reportErr = reportErr;

// ---------- Game flow ----------
GW.restart = () => {
  for (const e of GW.ents){ scene.remove(e.g); scene.remove(e.bar); }
  for (const p of GW.projs) scene.remove(p.mesh);
  GW.ents = []; GW.projs = []; GW.selected.clear();
  Object.assign(GW, { money:500, wave:1, waveT:50, time:0, kills:0, over:false });
  cancelModes();
  GW.spawn('hq', { x:0, z:0 });
  try { GW.hooks.onRestart?.(); } catch (err){ reportErr(err, 'onRestart'); }
  for (const [k, fn] of Object.entries(GW.restartHooks)){ try { fn(); } catch (err){ reportErr(err, 'restart:' + k); } }
  $('over').style.display = 'none'; refreshPanel();
  camTarget.set(0,0,0);
  GW.toast('Germs incoming — build defenses!');
};
GW.lose = () => {
  if (GW.over) return; GW.over = true;
  const m = Math.floor(GW.time/60), s = Math.floor(GW.time%60);
  $('overMsg').innerHTML = `The infection overran your HQ<br><small>Survived ${m}:${String(s).padStart(2,'0')} · wave ${GW.wave} · ${GW.kills} kills</small>`;
  $('over').style.display = 'flex';
};
GW.step = dt => {
  GW.time += dt;
  let inc = GW.baseIncome ?? 3;
  for (const e of GW.ents) if (!e.dead && e.side === 'us') inc += GW.stat(e, 'income') || 0;
  GW.income = inc; GW.money += inc*dt;
  try { GW.director?.(dt); } catch (err){ reportErr(err, 'director'); }
  const list = GW.ents;
  for (let i=0; i<list.length; i++){
    const e = list[i]; if (e.dead) continue;
    const def = GW.def(e);
    e.t += dt; e.cd -= dt;
    if (def.cat !== 'unit' && e.dest && def.speed && GW.moveToward(e, e.dest, def.speed, dt, 2, false)) e.dest = null;
    try { def.tick?.(e, dt); } catch (err){ reportErr(err, e.type + '.tick'); }
    if (!def.air) e.pos.y = GW.heightAt(e.pos.x, e.pos.z);
    e.hitT = (e.hitT || 0) - dt;
    const fl = e.hitT > 0;
    if (fl !== !!e.flashing){ e.flashing = fl; for (const m of e.mats) m.emissive.setHex(fl ? 0xaa2211 : m.userData.e0); }
  }
  for (const p of GW.projs){
    if (!p.dead){ try { if (!p.tick(p, dt)) p.dead = true; } catch (err){ p.dead = true; reportErr(err, 'projectile'); } }
    if (p.dead) scene.remove(p.mesh);
  }
  GW.projs = GW.projs.filter(p => !p.dead);
  GW.ents = GW.ents.filter(e => !e.dead);
  if (!GW.ents.some(e => e.type === 'hq')) GW.lose();
};

// ---------- Build / spawn modes ----------
let buildMode = null, spawnMode = null, ghost = null, ghostOk = false;
const hqs = () => GW.ents.filter(e => e.type === 'hq' && !e.dead);
function chooseBuild(type){
  const def = GW.types[type]; if (!def) return;
  if (def.cat === 'unit'){
    if (GW.money < def.cost) return;
    const h = hqs()[0]; if (!h) return;
    GW.money -= def.cost; const a = rand(0, Math.PI*2);
    const u = GW.spawn(type, { x:h.pos.x + Math.cos(a)*40, z:h.pos.z + Math.sin(a)*40 }); u.g.rotation.y = a; return;
  }
  cancelModes();
  if (GW.money < def.cost) return;
  buildMode = type; ghost = new T.Group();
  def.build(Object.assign({ parts:{}, lvl:1, ghost:true, t:0 }), ghost);
  ghost.traverse(o => { if (o.material){ o.material = o.material.clone(); o.material.transparent = true; o.material.opacity = .5; o.material.depthWrite = false; } });
  scene.add(ghost); buildRing.visible = true;
  document.querySelector(`#build [data-type="${type}"]`)?.classList.add('on');
}
function setSpawnMode(type){
  cancelModes(); spawnMode = type;
  document.querySelector(`#dSpawn [data-type="${type}"]`)?.classList.add('on');
  if (type) GW.toast(`Click the map to spawn ${GW.types[type].label || type}`);
}
function cancelModes(){
  if (ghost) scene.remove(ghost); ghost = null; buildMode = null; spawnMode = null; buildRing.visible = false;
  document.querySelectorAll('#build .on, #dSpawn .on').forEach(b => b.classList.remove('on'));
}
function placementOk(p){
  const def = GW.types[buildMode];
  if (!hqs().some(h => GW.flat(h.pos, p) <= GW.BUILD_R)) return false;
  for (const s of GW.ents) if (!GW.def(s).air && GW.flat(s.pos, p) < GW.R(s) + def.r + 3) return false;
  return true;
}

// ---------- Selection panel ----------
function refreshPanel(){
  const sel = [...GW.selected].filter(e => !e.dead), p = $('sel');
  if (!sel.length){ p.style.display = 'none'; return; }
  p.style.display = 'block';
  const one = sel.length === 1 ? sel[0] : null, d1 = one && GW.def(one);
  let h = one ? `<h3>${d1.label || d1.name}${d1.maxLvl ? ` · Lv ${one.lvl}/${d1.maxLvl}` : ''}</h3><div class="row">HP ${Math.ceil(one.hp)}/${one.maxHp}</div>`
              : `<h3>${sel.length} selected</h3>`;
  if (one){
    const st = [];
    for (const [k,lab] of [['dmg','Dmg'],['range','Range'],['rate','Reload'],['radius','Radius'],['heal','Heal/s']])
      if (typeof d1[k] === 'number') st.push(`${lab} ${+GW.stat(one,k).toFixed(k==='rate'?2:0)}`);
    if (st.length) h += `<div class="row">${st.join(' · ')}</div>`;
    if (d1.info) h += `<div class="row">${d1.info(one)}</div>`;
  }
  const movers = sel.some(s => GW.def(s).speed), attackers = sel.some(s => GW.def(s).canAttack);
  h += `<div class="row" style="opacity:.6">${movers ? 'Click ground: move' : ''}${attackers ? ' · click enemy: attack' : ''}</div>`;
  const units = sel.filter(s => GW.def(s).cat === 'unit');
  if (units.length){ const all = units.every(u => u.auto); h += `<button id="pAuto" class="${all?'on':''}">Auto-attack: ${all?'ON':'OFF'} (R)</button>`; }
  if (one && d1.maxLvl && one.lvl < d1.maxLvl)
    h += `<button id="pUp">Upgrade → Lv ${one.lvl+1}${d1.upgDesc ? ' · ' + d1.upgDesc : ''}<small>$${GW.upgCost(one)}</small></button>`;
  if (one && one.type !== 'hq') h += `<button id="pSell">Sell<small>+$${Math.round(one.spent*.5)}</small></button>`;
  p.innerHTML = h;
  if ($('pAuto')) $('pAuto').onclick = toggleAuto;
  if ($('pUp')) $('pUp').onclick = () => GW.upgrade(one);
  if ($('pSell')) $('pSell').onclick = () => { GW.sell(one); refreshPanel(); };
}
GW.refreshPanel = refreshPanel;
function toggleAuto(){
  const us = [...GW.selected].filter(e => GW.def(e).cat === 'unit'); if (!us.length) return;
  const v = !us.every(u => u.auto); us.forEach(u => u.auto = v);
  GW.toast(`Auto-attack ${v ? 'ON' : 'OFF'}`); refreshPanel();
}

// ---------- UI lists (rebuilt whenever a mod registers types) ----------
GW.ui = {
  refreshLists(){
    if (!document.body) return;
    const bl = $('build'); bl.innerHTML = '';
    GW.ui.buildList = Object.values(GW.types).filter(d => d.side === 'us' && d.cost).sort((a,b) => (a.order ?? 99) - (b.order ?? 99));
    GW.ui.buildList.forEach((d,i) => {
      const b = document.createElement('button'); b.dataset.type = d.name;
      b.innerHTML = `${i < 10 ? (i+1)%10 + '. ' : ''}${d.label || d.name}<small>$${d.cost}${d.desc ? ' · ' + d.desc : ''}</small>`;
      b.onclick = () => chooseBuild(d.name); bl.appendChild(b);
    });
    const sl = $('dSpawn'); sl.innerHTML = '';
    Object.values(GW.types).filter(d => d.side === 'them').sort((a,b) => (b.cat === 'base') - (a.cat === 'base')).forEach(d => {
      const b = document.createElement('button'); b.dataset.type = d.name;
      b.innerHTML = `${d.cat === 'base' ? '🏠 ' : ''}${d.label || d.name}`; b.onclick = () => setSpawnMode(d.name); sl.appendChild(b);
    });
  },
};

function hud(){
  const hq = hqs()[0], them = GW.ents.filter(e => e.side === 'them');
  const bases = them.filter(e => GW.def(e).cat === 'base').length;
  $('hud').innerHTML =
    `<span class="m">$${Math.floor(GW.money)}</span> <span style="opacity:.7">(+${Math.round(GW.income)}/s)</span> · WAVE <b>${GW.wave}</b> next in <b>${Math.max(0,Math.ceil(GW.waveT))}s</b><br>`+
    `HQ <b>${hq ? Math.ceil(hq.hp) : 0}</b>/${hq ? hq.maxHp : 0} · ENEMIES <b>${them.length - bases}</b> · BASES <b>${bases}</b> · KILLS <b>${GW.kills}</b><br>`+
    `<span style="color:${GW.live ? '#5fffb0' : '#888'}">● ${GW.live ? 'LIVE — Claude connected' : 'offline'}</span>`+
    `${GW.paused ? ' · <b style="color:#ffd84a">PAUSED</b>' : ''}${GW.speed !== 1 ? ` · <b>${GW.speed}×</b>` : ''}${GW.god ? ' · <b style="color:#ff9">GOD</b>' : ''}`;
  for (const b of $('build').children) b.disabled = GW.money < (GW.types[b.dataset.type]?.cost ?? 0);
  if ($('pUp')){ const one = [...GW.selected][0]; if (one) $('pUp').disabled = GW.money < GW.upgCost(one); }
}

// ---------- Camera ----------
const camTarget = new T.Vector3();
let yaw = .8, pitch = .7, dist = 780;
const keys = {};
GW.cam = { target:camTarget, get yaw(){ return yaw; }, set yaw(v){ yaw = v; }, get dist(){ return dist; }, set dist(v){ dist = v; } };
function updateCam(dt){
  const sp = dist*.9*dt, fx = -Math.cos(yaw), fz = -Math.sin(yaw);
  if (keys.KeyW){ camTarget.x += fx*sp; camTarget.z += fz*sp; }
  if (keys.KeyS){ camTarget.x -= fx*sp; camTarget.z -= fz*sp; }
  if (keys.KeyA){ camTarget.x += fz*sp; camTarget.z -= fx*sp; }
  if (keys.KeyD){ camTarget.x -= fz*sp; camTarget.z += fx*sp; }
  if (keys.KeyQ) yaw -= dt*1.5; if (keys.KeyE) yaw += dt*1.5;
  camTarget.clampLength(0, 2000);
  camTarget.y += (Math.max(0, GW.heightAt(camTarget.x, camTarget.z)) - camTarget.y) * Math.min(1, dt*4);
  camera.position.set(camTarget.x + Math.cos(yaw)*Math.cos(pitch)*dist, camTarget.y + Math.sin(pitch)*dist, camTarget.z + Math.sin(yaw)*Math.cos(pitch)*dist);
  camera.lookAt(camTarget);
  sun.position.set(camTarget.x + 500, 900, camTarget.z + 350); sun.target.position.copy(camTarget);
}
function updateOverlays(){
  for (const e of GW.ents){ updBar(e); if (e.ring) e.ring.visible = GW.selected.has(e); }
  const h = hqs()[0];
  if (h && buildRing.visible){ buildRing.position.set(h.pos.x, h.pos.y + 1, h.pos.z); buildRing.scale.setScalar(GW.BUILD_R); }
  const r = [...GW.selected].find(e => typeof GW.def(e).range === 'number' || typeof GW.def(e).radius === 'number');
  rangeRing.visible = !!r;
  if (r){ rangeRing.position.set(r.pos.x, r.pos.y + 1.2, r.pos.z); rangeRing.scale.setScalar(GW.stat(r, GW.def(r).range ? 'range' : 'radius')); }
}

// ---------- Input ----------
const ray = new T.Raycaster(), ndc = new T.Vector2();
function setRay(e){ ndc.set(e.clientX/innerWidth*2-1, -e.clientY/innerHeight*2+1); ray.setFromCamera(ndc, camera); }
// March the ray against the analytic terrain height — cheap and exact enough.
function pickGround(e){
  setRay(e); const o = ray.ray.origin, d = ray.ray.direction; if (d.y >= 0) return null;
  const p = new T.Vector3(); let t = 0, step = 10;
  for (let i=0; i<1400; i++){
    p.copy(o).addScaledVector(d, t);
    if (p.y <= GW.heightAt(p.x, p.z)){
      let a = t - step, b = t;
      for (let j=0;j<10;j++){ const m = (a+b)/2; p.copy(o).addScaledVector(d, m); if (p.y <= GW.heightAt(p.x,p.z)) b = m; else a = m; }
      p.copy(o).addScaledVector(d, b); return p;
    }
    t += step;
  }
  return null;
}
GW.pickGround = pickGround;
function pickEnt(e){
  setRay(e);
  const hit = ray.intersectObjects(GW.ents.map(x => x.g), true).find(h => h.object.userData.ent && !h.object.userData.ent.dead);
  return hit?.object.userData.ent;
}
GW.pickEnt = pickEnt;

const cv = renderer.domElement;
let drag = null;
cv.addEventListener('contextmenu', e => e.preventDefault());
cv.addEventListener('pointerdown', e => { drag = { x0:e.clientX, y0:e.clientY, x:e.clientX, y:e.clientY, moved:false, btn:e.button }; });
addEventListener('pointermove', e => {
  if (ghost){
    const p = pickGround(e);
    if (p){ p.x = Math.round(p.x/5)*5; p.z = Math.round(p.z/5)*5; p.y = GW.heightAt(p.x, p.z); ghost.position.copy(p);
      ghostOk = placementOk(p) && GW.money >= GW.types[buildMode].cost;
      ghost.traverse(o => { if (o.material?.emissive) o.material.emissive.setHex(ghostOk ? 0x116633 : 0x881111); }); }
  }
  if (!drag) return;
  if (!drag.moved && Math.abs(e.clientX-drag.x0) + Math.abs(e.clientY-drag.y0) > 5) drag.moved = true;
  if (!drag.moved) return;
  if (drag.btn !== 0 || buildMode || spawnMode){
    yaw += (e.clientX-drag.x)*.005; pitch = Math.min(1.45, Math.max(.18, pitch + (e.clientY-drag.y)*.005));
  } else {
    const b = $('box'); b.style.display = 'block';
    b.style.left = Math.min(drag.x0, e.clientX) + 'px'; b.style.top = Math.min(drag.y0, e.clientY) + 'px';
    b.style.width = Math.abs(e.clientX-drag.x0) + 'px'; b.style.height = Math.abs(e.clientY-drag.y0) + 'px';
  }
  drag.x = e.clientX; drag.y = e.clientY;
});
addEventListener('pointerup', e => {
  if (!drag){ return; }
  if (!GW.over){
    if (!drag.moved) click(e, drag.btn);
    else if (drag.btn === 0 && !buildMode && !spawnMode) boxSelect(drag.x0, drag.y0, e.clientX, e.clientY, e.shiftKey);
  }
  $('box').style.display = 'none'; drag = null;
});
cv.addEventListener('wheel', e => { dist = Math.min(2600, Math.max(120, dist*(1 + e.deltaY*.001))); e.preventDefault(); }, { passive:false });
addEventListener('resize', () => {
  camera.aspect = innerWidth/innerHeight; camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight); composer.setSize(innerWidth, innerHeight);
});
addEventListener('keydown', e => {
  if (e.target.tagName === 'INPUT') return;
  keys[e.code] = true;
  if (e.code === 'Escape'){ cancelModes(); GW.selected.clear(); refreshPanel(); }
  if (e.code === 'KeyT'){ if (!e.shiftKey) GW.selected.clear(); GW.ents.filter(u => u.side === 'us' && GW.def(u).cat === 'unit').forEach(u => GW.selected.add(u)); refreshPanel(); }
  if (e.code === 'KeyR') toggleAuto();
  if (e.code === 'KeyP') togglePause();
  if (e.code === 'KeyH'){ const h = hqs()[0]; if (h) camTarget.copy(h.pos); }
  if (e.code === 'Backquote') toggleDev();
  const n = '1234567890'.indexOf(e.key);
  if (n >= 0 && GW.ui.buildList?.[n]) chooseBuild(GW.ui.buildList[n].name);
});
addEventListener('keyup', e => { keys[e.code] = false; });
addEventListener('blur', () => { for (const k in keys) keys[k] = false; });

function boxSelect(x0, y0, x1, y1, add){
  const [l, r, t, b] = [Math.min(x0,x1), Math.max(x0,x1), Math.min(y0,y1), Math.max(y0,y1)];
  if (!add) GW.selected.clear();
  const v = new T.Vector3();
  for (const u of GW.ents){
    if (u.side !== 'us' || GW.def(u).cat !== 'unit') continue;
    v.copy(u.pos).setY(u.pos.y + 5).project(camera);
    const sx = (v.x+1)/2*innerWidth, sy = (1-v.y)/2*innerHeight;
    if (sx >= l && sx <= r && sy >= t && sy <= b) GW.selected.add(u);
  }
  refreshPanel();
}

function click(e, btn){
  // Mods can claim clicks first (e.g. the attacker-side UI)
  for (const [k, fn] of Object.entries(GW.clickHooks)){ try { if (fn(e, btn)) return; } catch (err){ reportErr(err, 'click:' + k); } }
  if (spawnMode){
    if (btn === 2){ cancelModes(); return; }
    const p = pickGround(e);
    if (p){ try { GW.spawn(spawnMode, p); GW.fx.ring(p, 0xff4466, 30); } catch (err){ reportErr(err, 'spawn'); } }
    if (!e.shiftKey) cancelModes();
    return;
  }
  if (buildMode){
    if (btn === 2){ cancelModes(); return; }
    if (ghostOk){
      const t = buildMode, def = GW.types[t];
      GW.money -= def.cost; GW.spawn(t, ghost.position); GW.fx.ring(ghost.position, 0x66ffaa, def.r*3);
      if (!e.shiftKey || GW.money < def.cost) cancelModes(); else ghostOk = placementOk(ghost.position);
    }
    return;
  }
  const ent = pickEnt(e);
  if (ent && ent.side === 'them' && GW.selected.size){
    let n = 0;
    for (const s of GW.selected) if (GW.def(s).canAttack){ s.attack = ent; s.dest = null; n++; }
    if (n){ GW.fx.ring(ent.pos, 0xff4444, GW.R(ent) + 10); return; }
  }
  if (ent && ent.side === 'us' && btn === 0){
    if (!e.shiftKey) GW.selected.clear();
    if (e.shiftKey && GW.selected.has(ent)) GW.selected.delete(ent); else GW.selected.add(ent);
    refreshPanel(); return;
  }
  const p = pickGround(e);
  const movers = [...GW.selected].filter(s => GW.def(s).speed);
  if (p && movers.length){
    const cols = Math.ceil(Math.sqrt(movers.length));
    movers.forEach((s, i) => {
      const off = Math.max(28, GW.R(s)*2.8);
      s.dest = new T.Vector3(p.x + (i%cols - (cols-1)/2)*off, 0, p.z + (Math.floor(i/cols) - (cols-1)/2)*off);
      s.attack = null;
    });
    GW.fx.ring(p, 0x66ffaa, 18, .5);
  } else if (btn === 0 && GW.selected.size){ GW.selected.clear(); refreshPanel(); }
}

// ---------- Dev panel ----------
function toggleDev(){ const d = $('dev'); d.style.display = d.style.display === 'block' ? 'none' : 'block'; }
function togglePause(){ GW.paused = !GW.paused; $('dPause').textContent = GW.paused ? '▶ Resume (P)' : '⏸ Pause (P)'; }
$('devBtn').onclick = toggleDev;
$('dRestart').onclick = () => GW.restart();
$('overRestart').onclick = () => GW.restart();
$('dPause').onclick = togglePause;
$('dSpeed').onclick = () => { GW.speed = GW.speed >= 4 ? .5 : GW.speed*2; $('dSpeed').textContent = `Speed ${GW.speed}×`; };
$('dMoney').onclick = () => { GW.money += 1000; };
$('dGod').onclick = () => { GW.god = !GW.god; $('dGod').textContent = `God mode: ${GW.god ? 'ON' : 'off'}`; };
$('dWave').onclick = () => { GW.waveT = 0; };
$('dClear').onclick = () => { for (const e of GW.ents) if (e.side === 'them') { e.hp = 0; GW.kill(e); } };
$('dReload').onclick = () => GW.loadAllMods(true);

// ---------- Live channel: hot-reload mods + remote eval ----------
GW.loadMod = async (file, announce) => {
  try {
    const src = await (await fetch('mods/' + file + '?t=' + Date.now(), { cache:'no-store' })).text();
    (0, eval)(src + '\n//# sourceURL=mods/' + file);
    if (announce) GW.toast(`🔧 Live update: ${file}`, '#8fffd0');
    return true;
  } catch (err){ reportErr(err, file); return false; }
};
GW.loadAllMods = async announce => {
  let mods;
  try { mods = await (await fetch('/mods')).json(); } catch { mods = ['world.js','buildings.js','enemies.js','waves.js']; }
  for (const f of mods) await GW.loadMod(f, announce);
};
function fmt(v){
  try {
    if (v === undefined) return 'undefined';
    if (typeof v === 'function') return v.toString().slice(0, 400);
    const seen = new WeakSet();
    const s = JSON.stringify(v, (k, x) => {
      if (x && typeof x === 'object'){
        if (x.isObject3D || x.isMaterial || x.isBufferGeometry) return `[${x.type}]`;
        if (x instanceof Set) return [...x];
        if (seen.has(x)) return '[circular]'; seen.add(x);
      }
      return x;
    }, 1);
    return s === undefined ? String(v) : s.slice(0, 8000);
  } catch { return String(v); }
}
GW.connect = () => {
  if (location.protocol === 'file:') return;
  const es = new EventSource('/events');
  es.onopen = () => { GW.live = true; };
  es.onerror = () => { GW.live = false; };
  es.onmessage = async ev => {
    const m = JSON.parse(ev.data);
    if (m.type === 'mod') await GW.loadMod(m.file, true);
    if (m.type === 'eval'){
      let out;
      try { out = fmt(await (0, eval)(m.code)); } catch (err){ out = 'Error: ' + err.message; }
      fetch('/result', { method:'POST', body:JSON.stringify({ id:m.id, value:out }) });
    }
  };
};

// ---------- Main loop ----------
let last = performance.now(), panelT = 0;
function frame(now){
  requestAnimationFrame(frame);   // first, so a bad mod can never stop the loop
  const real = Math.min(.05, (now - last)/1000); last = now;
  if (!GW.paused && !GW.over){
    let left = real*GW.speed;
    while (left > 1e-4){ const d = Math.min(.05, left); try { GW.step(d); } catch (err){ reportErr(err, 'step'); } left -= d; }
  }
  for (const [k, fn] of Object.entries(GW.frameHooks)){ try { fn(real); } catch (err){ reportErr(err, 'frame:' + k); } }
  updateFx(real); updateCam(real); updateOverlays(); hud();
  if ((panelT -= real) <= 0 && GW.selected.size === 1 && !document.querySelector('#sel button:hover')){ panelT = .5; refreshPanel(); }
  composer.render();
}

(async () => {
  if (location.protocol === 'file:'){
    for (const f of ['world.js','buildings.js','enemies.js','waves.js'])
      await new Promise(r => { const s = document.createElement('script'); s.src = 'mods/' + f; s.onload = s.onerror = r; document.body.appendChild(s); });
  } else await GW.loadAllMods(false);
  GW.ui.refreshLists();
  GW.connect();
  GW.restart();
  $('loading').remove();
  requestAnimationFrame(frame);
})();
})();
