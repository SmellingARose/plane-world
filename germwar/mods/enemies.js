// Enemy organisms and their bases. Hot-reloadable.
(() => {
const T = THREE, { rand } = GW;
const skin = (color, o={}) => new T.MeshStandardMaterial({ color, roughness:.3, metalness:.05, transparent:true, opacity:.88, ...o });
const glow = (color, i=2.5) => new T.MeshStandardMaterial({ color, emissive:color, emissiveIntensity:i, roughness:.4 });
const hsl  = (h, s, l) => new T.Color().setHSL(h, s, l);
const at   = (o,x,y,z) => { o.position.set(x,y,z); return o; };
const geo = {
  sphere:new T.SphereGeometry(1, 16, 12), blob:new T.IcosahedronGeometry(1, 3), ico:new T.IcosahedronGeometry(1, 0),
  cone:new T.ConeGeometry(1, 1, 6), cyl:new T.CylinderGeometry(1, 1, 1, 8), hex:new T.CylinderGeometry(1, 1, 1, 6),
};
const mesh = (g, m, s) => { const o = new T.Mesh(g, m); if (s != null) (typeof s === 'number' ? o.scale.setScalar(s) : o.scale.set(...s)); return o; };
const near = (e, type, d) => { const a = rand(0, 6.28), r = (d ?? GW.R(e) + 10) + rand(0, 15); return GW.spawn(type, { x:e.pos.x + Math.cos(a)*r, z:e.pos.z + Math.sin(a)*r }); };
const cap = () => 70 + GW.wave*30;   // soft limit on swarm size

// Ground melee AI: crawl to the nearest player thing and chew on it.
function crawl(e, dt, o={}){
  const def = GW.def(e);
  // Orders from the attacker player override instincts
  const ord = e.order;
  if (ord?.type === 'move'){
    const sp = def.speed*(e.spd||1);
    if (GW.moveToward(e, ord.p, sp, dt, 6)) e.order = null;
    return null;
  }
  if (ord?.type === 'attack'){ if (ord.t.dead) e.order = null; else e.tgt = ord.t; }
  else if (!e.tgt || e.tgt.dead || Math.random() < .01) e.tgt = GW.nearest(e.pos, 'us');
  const t = e.tgt; if (!t) return null;
  const d = GW.flat(t.pos, e.pos), reach = GW.R(t) + def.r*.6 + (o.stopAt || 0);
  if (d > reach){
    const dx = (t.pos.x-e.pos.x)/d, dz = (t.pos.z-e.pos.z)/d, w = Math.sin(e.t*3 + e.ph)*.45, sp = def.speed*(e.spd||1)*dt;
    e.pos.x += (dx + w*dz)*sp; e.pos.z += (dz - w*dx)*sp; e.g.rotation.y = Math.atan2(dx, dz);
  } else if (!o.stopAt) GW.damage(t, def.dps*dt, e);
  return { t, d };
}

// Spores: lobbed infection pods. Batteries & shields can stop them.
GW.crawl = crawl;
GW.spore = (src, o={}) => {
  const targets = GW.ents.filter(x => x.side === 'us' && !x.dead && (!o.range || GW.flat(x.pos, src.pos) < o.range));
  if (!targets.length) return;
  const tg = targets[Math.floor(Math.random()*targets.length)];
  const to = tg.pos.clone().add(new T.Vector3(rand(-15,15), 0, rand(-15,15)));
  const from = src.pos.clone().setY(src.pos.y + (o.y || 25));
  GW.lob(from, to, o.T || rand(6, 9), { interceptable:true, trail:0x9955cc, mesh:mesh(geo.sphere, glow(0xcc66ff, 3), 3.5),
    onHit:p => {
      GW.fx.explode(p.clone().setY(p.y + 2), 0xcc66ff, 35);
      for (const x of GW.within(p, 'us', 35)) GW.damage(x, o.dmg || 70);
      for (let i=0;i<(o.germs ?? 3);i++) GW.spawn('germ', { x:p.x + rand(-8,8), z:p.z + rand(-8,8) });
    } });
};

const LOOK = 2;   // bump when creature models change; live entities get rebuilt on hot-reload
const unit = (name, def) => GW.type(name, Object.assign({ side:'them', onSpawn(e){ e.spd = rand(.85, 1.2); e.look = LOOK; def.init?.(e); } }, def));
// Swap an existing entity's model for its type's current build() without touching its state
GW.rebuild = e => {
  const def = GW.def(e);
  for (const c of [...e.g.children]) if (c !== e.ring) e.g.remove(c);
  e.parts = {}; def.build(e, e.g); e.mats = []; e.flashing = false;
  e.g.traverse(m => { if (!m.isMesh || m === e.ring) return; m.castShadow = !m.material.transparent; m.receiveShadow = true; m.userData.ent = e;
    if (m.material.emissive && !e.mats.includes(m.material)){ m.material.userData.e0 = m.material.emissive.getHex(); e.mats.push(m.material); } });
};

// A jointed limb chain: nested groups so bending the root swings the whole tentacle.
function tentacle(n, r0, m){
  const root = new T.Group(), joints = []; let parent = root;
  for (let i=0;i<n;i++){
    const j = new T.Group(); j.position.y = i ? r0*1.5*(1 - (i-1)/n*.6) : 0; parent.add(j);
    j.add(mesh(geo.sphere, m, r0*(1 - i/n*.7))); joints.push(j); parent = j;
  }
  return { root, joints };
}
function wave(tent, t, amp, ph=0){ tent.joints.forEach((j, i) => { j.rotation.x = Math.sin(t + i*.7 + ph)*amp; j.rotation.z = Math.cos(t*.8 + i*.5 + ph)*amp*.6; }); }
// Spider-style legs: hip pivots, upper segment out, lower segment down to the ground
function legs(g, n, spread, hipY, upper, lower, m){
  const out = [];
  for (let i=0;i<n;i++){
    const side = i < n/2 ? -1 : 1, k = i % (n/2), hip = new T.Group();
    hip.position.set(side*spread, hipY, (k - (n/2-1)/2)*spread*1.3); g.add(hip);
    const up = mesh(geo.cyl, m, [.3, upper, .3]); up.rotation.z = Math.PI/2; up.position.x = side*upper/2; hip.add(up);
    const knee = new T.Group(); knee.position.x = side*upper; hip.add(knee);
    const lo = mesh(geo.cone, m, [.35, lower, .35]); lo.rotation.z = Math.PI; lo.position.y = -lower/2; knee.add(lo);
    out.push({ hip, side, ph:i*1.7 + (side > 0 ? Math.PI : 0) });
  }
  return out;
}
function gait(ls, t){ for (const l of ls){ l.hip.rotation.y = Math.sin(t + l.ph)*.45; l.hip.rotation.z = l.side*(.3 + Math.max(0, Math.sin(t + l.ph))*.35); } }

unit('germ', { label:'Ciliate Crawler', hp:30, r:4, speed:20, dps:10, bounty:4,
  init(e){ e.div = rand(14, 24); },
  build(e, g){
    const hue = rand(.27, .4), body = skin(hsl(hue,.7,.45), { opacity:.93 }), dark = skin(hsl(hue,.45,.2), { opacity:1 });
    e.parts.segs = [];
    for (let i=0;i<3;i++){ const s = mesh(geo.sphere, body, [3.4 - i*.7, 2.6 - i*.5, 3.4 - i*.6]); s.position.set(0, 3, -i*4.2); g.add(s); e.parts.segs.push(s); }
    for (const sx of [-1,1]){
      const st = at(mesh(geo.cyl, dark, [.3, 3, .3]), sx*1.4, 6, 1.6); st.rotation.z = -sx*.35; g.add(st);
      g.add(at(mesh(geo.sphere, glow(0xfff6a0, 1.8), .8), sx*2, 7.6, 1.8));
      const md = at(mesh(geo.cone, dark, [.5, 2.4, .5]), sx*1.2, 2.4, 3.6); md.rotation.x = Math.PI/2; md.rotation.z = sx*.5; g.add(md);
    }
    e.parts.cilia = [];
    for (let i=0;i<8;i++){ const side = i%2 ? 1 : -1, c = at(mesh(geo.cyl, dark, [.15, 2.6, .15]), side*2.8, 2.2, 1.5 - (i>>1)*2.6); c.rotation.z = side*1.1; g.add(c); e.parts.cilia.push(c); }
    g.add(at(mesh(geo.sphere, glow(hsl(hue + .12, 1, .6), 1.4), 1), 0, 3.4, -1));
  },
  tick(e, dt){
    crawl(e, dt); const t = e.t*8 + e.ph;
    e.parts.segs.forEach((s, i) => { s.position.x = Math.sin(t - i*1.2)*.9*i; s.position.y = 3 + Math.abs(Math.sin(t - i))*.4; });
    e.parts.cilia.forEach((c, i) => { c.rotation.x = Math.sin(t*1.6 + i)*.6; });
    if ((e.div -= dt) <= 0 && GW.count('them') < cap()){ e.div = rand(14, 24); near(e, 'germ', 4); }
  },
});

unit('runner', { label:'Virus Skitterer', hp:16, r:3, speed:62, dps:7, bounty:3, deathColor:0xff4466,
  build(e, g){
    const shell = skin(0x3a0d18, { opacity:1, metalness:.4, roughness:.35 });
    const body = at(new T.Group(), 0, 5, 0); g.add(body); e.parts.body = body;
    body.add(mesh(geo.ico, glow(0xff3355, .9), 2.6));
    const v = geo.ico.attributes.position, seen = new Set();
    for (let i=0;i<v.count;i++){
      const p = new T.Vector3().fromBufferAttribute(v, i), k = p.toArray().map(n => n.toFixed(2)).join(); if (seen.has(k)) continue; seen.add(k);
      const sp = mesh(geo.cone, skin(0xffd0d8, { opacity:1 }), [.4, 2, .4]); sp.position.copy(p).multiplyScalar(3); sp.lookAt(p.clone().multiplyScalar(10)); sp.rotateX(Math.PI/2); body.add(sp);
    }
    e.parts.legs = legs(g, 6, 2, 5, 4.5, 6, shell);
  },
  tick(e, dt){ crawl(e, dt); e.parts.body.rotation.y += dt*4; gait(e.parts.legs, e.t*18); e.parts.body.position.y = 5 + Math.abs(Math.sin(e.t*18))*.6; },
});

unit('brute', { label:'Amoeba Titan', hp:450, r:13, speed:11, dps:45, armor:.3, bounty:35, deathColor:0xbb66ff,
  build(e, g){
    const flesh = skin(0x8a3dff, { opacity:.55 });
    e.parts.body = at(mesh(geo.blob, skin(0x9a4dff, { opacity:.62 }), 13), 0, 12, 0); g.add(e.parts.body);
    // gaping maw with a ring of teeth
    const maw = at(new T.Group(), 0, 10, 11); g.add(maw); e.parts.maw = maw;
    maw.add(mesh(new T.TorusGeometry(5, 1.4, 8, 20), skin(0x2a0a30, { opacity:1 })));
    maw.add(at(mesh(geo.sphere, new T.MeshBasicMaterial({ color:0x0a0008 }), [4.2, 4.2, 1]), 0, 0, -.5));
    for (let i=0;i<10;i++){ const a = i/10*6.28, th = mesh(geo.cone, skin(0xf4ecd8, { opacity:1 }), [.8, 2.8, .8]); th.position.set(Math.cos(a)*4.6, Math.sin(a)*4.6, .6); th.rotation.z = a + Math.PI/2; maw.add(th); }
    for (let i=0;i<5;i++) g.add(at(mesh(geo.sphere, glow(0xff5ad0, 2), rand(.8, 1.4)), -4 + i*2, 21 + Math.sin(i)*1.5, 7));
    e.parts.orgs = [];
    for (let i=0;i<4;i++){ const o = mesh(geo.sphere, glow(i%2 ? 0xff66cc : 0x66ffee, 1.4), rand(1.5, 2.6)); g.add(o); e.parts.orgs.push(o); }
    e.parts.tents = [];
    for (let i=0;i<5;i++){
      const tn = tentacle(7, 2.2, flesh), a = i/5*6.28 + .6;
      tn.root.position.set(Math.cos(a)*10, 6, Math.sin(a)*10); tn.root.rotation.set(Math.sin(a)*1.3, 0, -Math.cos(a)*1.3);
      g.add(tn.root); e.parts.tents.push(tn);
    }
  },
  tick(e, dt){
    crawl(e, dt); const t = e.t;
    e.parts.body.scale.set(13*(1 + .1*Math.sin(t*2)), 13*(1 + .1*Math.sin(t*2.6 + 1)), 13*(1 + .08*Math.sin(t*1.7 + 2)));
    e.parts.maw.scale.setScalar(1 + .18*Math.sin(t*3));
    e.parts.orgs.forEach((o, i) => o.position.set(Math.sin(t*.8 + i*1.3)*5, 12 + Math.cos(t*1.1 + i)*4, Math.cos(t*.7 + i*2)*5));
    e.parts.tents.forEach((tn, i) => wave(tn, t*2.2, .35, i));
  },
});

unit('spitter', { label:'Acid Mantis', hp:60, r:6, speed:20, range:170, rate:2.2, dmg:22, bounty:8,
  build(e, g){
    const chitin = skin(0x4a6a14, { opacity:1, metalness:.3, roughness:.35 });
    e.parts.sac = at(mesh(geo.sphere, skin(0xc8ff40, { opacity:.55, depthWrite:false }), [4.2, 3.6, 5.2]), 0, 7, -5); g.add(e.parts.sac);
    e.parts.acid = at(mesh(geo.sphere, glow(0xb8ff30, 1.6), 2.4), 0, 7, -5); g.add(e.parts.acid);
    g.add(at(mesh(geo.sphere, chitin, [2.4, 2.2, 3.4]), 0, 7, 1));
    const head = at(new T.Group(), 0, 9.5, 4.5); g.add(head); e.parts.head = head;
    head.add(mesh(geo.sphere, chitin, [2, 1.8, 2.4]));
    for (const sx of [-1,1]){
      head.add(at(mesh(geo.sphere, glow(0xffee55, 2.2), .8), sx*1.4, .8, 1.2));
      const claw = at(new T.Group(), sx*1.8, -1.5, 1.5); head.add(claw);
      const arm = mesh(geo.cyl, chitin, [.35, 5, .35]); arm.position.y = -2.5; arm.rotation.x = -.6; claw.add(arm);
      const blade = mesh(geo.cone, skin(0xd8f080, { opacity:1 }), [.5, 4, .5]); blade.position.set(0, -4, 3); blade.rotation.x = 1.9; claw.add(blade);
    }
    e.parts.legs = legs(g, 4, 2, 6.5, 4, 7, chitin);
  },
  tick(e, dt){
    const def = GW.types.spitter, r = crawl(e, dt, { stopAt:def.range*.8 });
    const moving = r && r.d > def.range*.8 + GW.R(r.t);
    gait(e.parts.legs, e.t*(moving ? 12 : 2));
    const charge = 1 - Math.max(0, e.cd)/def.rate;   // sac swells before each shot
    e.parts.sac.scale.set(4.2 + charge, 3.6 + charge, 5.2 + charge); e.parts.acid.material.emissiveIntensity = .8 + charge*2;
    if (!r || e.cd > 0 || r.d > def.range) return;
    e.cd = def.rate;
    GW.homing(e.pos.clone().setY(e.pos.y + 10), r.t, 170, { lead:false, mesh:mesh(geo.sphere, glow(0xccff33, 2.5), 2),
      onHit:(t, p) => { GW.damage(t, def.dmg, e); GW.fx.explode(p, 0xccff33, 10); } });
  },
});

unit('splitter', { label:'Mitotic Splitter', hp:90, r:7, speed:18, dps:14, bounty:8, deathColor:0xff9933,
  build(e, g){
    const m = skin(0xff8a3a, { opacity:.7, depthWrite:false });
    e.parts.a = at(new T.Group(), -3, 6, 0); e.parts.b = at(new T.Group(), 3, 6, 0); g.add(e.parts.a, e.parts.b);
    for (const c of [e.parts.a, e.parts.b]){
      c.add(mesh(geo.sphere, m, 5.5));
      for (let i=0;i<3;i++){ const ch = mesh(geo.cyl, glow(0xffdd55, 1.6), [.5, 2.6, .5]); ch.position.set(rand(-1.5,1.5), rand(-1.5,1.5), rand(-1.5,1.5)); ch.rotation.set(rand(0,3), 0, rand(0,3)); c.add(ch); }
    }
    e.parts.fibres = [];
    for (let i=0;i<5;i++){ const f = mesh(geo.cyl, glow(0xffaa66, .9), [.12, 1, .12]); f.rotation.z = Math.PI/2; f.position.set(0, 6 + (i-2)*1.2, (i%2 - .5)*1.6); g.add(f); e.parts.fibres.push(f); }
    e.parts.pinch = at(mesh(new T.TorusGeometry(4, .6, 6, 20), skin(0xd86a2a, { opacity:1 })), 0, 6, 0); e.parts.pinch.rotation.y = Math.PI/2; g.add(e.parts.pinch);
  },
  tick(e, dt){
    crawl(e, dt);
    const s = 2.5 + Math.sin(e.t*3)*1.2;
    e.parts.a.position.x = -s; e.parts.b.position.x = s; e.parts.a.rotation.y += dt; e.parts.b.rotation.y -= dt;
    for (const f of e.parts.fibres) f.scale.y = s*2;
    e.parts.pinch.scale.setScalar(.6 + (s - 1.3)/2.4*.5);
  },
  onDeath(e){ for (let i=0;i<3;i++) near(e, 'germ', 4); },
});

unit('phage', { label:'Phage (flying)', air:true, alt:45, hp:55, r:6, speed:42, dps:20, bounty:10, deathColor:0x66ffee,
  build(e, g){
    const m = new T.MeshStandardMaterial({ color:0x9fe8e0, metalness:.8, roughness:.25 });
    g.add(at(mesh(new T.IcosahedronGeometry(5, 0), m), 0, 12, 0));
    g.add(at(mesh(geo.sphere, glow(0x55ffdd, 2), 2.4), 0, 12, 0));
    g.add(at(mesh(geo.cyl, m, [1.2, 10, 1.2]), 0, 3, 0));
    g.add(at(mesh(geo.hex, m, [3, 1, 3]), 0, -2, 0));
    const legs = new T.Group(); legs.position.y = -2; g.add(legs); e.parts.legs = legs;
    for (let i=0;i<6;i++){ const a = i/6*Math.PI*2, l = mesh(geo.cyl, m, [.35, 9, .35]); l.position.set(Math.cos(a)*4, -3, Math.sin(a)*4); l.rotation.set(Math.sin(a)*.8, 0, -Math.cos(a)*.8); legs.add(l); }
  },
  tick(e, dt){
    const r = crawl(e, dt);
    const close = r && r.d < GW.R(r.t) + 25;
    const want = GW.heightAt(e.pos.x, e.pos.z) + (close ? 14 : 45) + Math.sin(e.t*2 + e.ph)*3;
    e.pos.y += (want - e.pos.y)*Math.min(1, dt*2);
    e.parts.legs.rotation.y += dt*2;
  },
});

for (const e of GW.ents) if (['germ','runner','brute','spitter','splitter'].includes(e.type) && e.look !== LOOK){ GW.rebuild(e); e.look = LOOK; }

// ---------------- Bases ----------------
const base = (name, def) => GW.type(name, Object.assign({ side:'them', cat:'base', onSpawn(e){ def.init?.(e); } }, def));

base('colony', { label:'Colony', hp:600, r:22, bounty:250,
  init(e){ e.spawnT = 2; e.sporeT = rand(6, 10); },
  build(e, g){
    const m = skin(0x2f9a3a, { opacity:.9, emissive:0x0c3a08 });
    for (let i=0;i<9;i++) g.add(at(mesh(geo.blob, m, rand(8, 16)), rand(-14,14), rand(4,14), rand(-14,14)));
    e.parts.core = at(mesh(geo.sphere, glow(0xccff44, 3), 9), 0, 18, 0); g.add(e.parts.core);
    for (let i=0;i<6;i++){ const a = i/6*6.28, t = mesh(geo.cyl, skin(0x1f7a2a), [1.2, 30, 1.2]); t.position.set(Math.cos(a)*22, 6, Math.sin(a)*22); t.rotation.set(Math.sin(a)*.9, 0, -Math.cos(a)*.9); g.add(t); }
  },
  tick(e, dt){
    e.g.scale.setScalar(1 + .05*Math.sin(e.t*2 + e.ph)); e.parts.core.material.emissiveIntensity = 2.5 + Math.sin(e.t*3)*1;
    if ((e.spawnT -= dt) <= 0){ e.spawnT = Math.max(.8, 4.5 - GW.wave*.35); if (GW.count('them') < cap()) near(e, GW.wave >= 3 && Math.random() < .15 ? 'splitter' : 'germ'); }
    if (GW.wave >= 2 && (e.sporeT -= dt) <= 0){ e.sporeT = Math.max(3, 11 - GW.wave*.8); GW.spore(e); }
  },
});

base('hive', { label:'Virus Hive', hp:850, r:22, bounty:350,
  init(e){ e.burstT = 4; e.phageT = 8; },
  build(e, g){
    const m = new T.MeshStandardMaterial({ color:0x5a1424, roughness:.6, flatShading:true });
    for (let i=0;i<12;i++){
      const h = rand(15, 50), a = rand(0, 6.28), r = rand(0, 14), c = at(mesh(geo.hex, m, [5, h, 5]), Math.cos(a)*r, h/2, Math.sin(a)*r); g.add(c);
      g.add(at(mesh(geo.hex, glow(0xff5522, 2.5), [3.5, 1, 3.5]), c.position.x, h + .2, c.position.z));
    }
    e.parts.eye = at(mesh(geo.sphere, glow(0xff2200, 3), 6), 0, 56, 0); g.add(e.parts.eye);
  },
  tick(e, dt){
    e.parts.eye.scale.setScalar(6 + Math.sin(e.t*4)*1.2);
    if ((e.burstT -= dt) <= 0){ e.burstT = Math.max(6, 14 - GW.wave*.6); for (let i=0;i<4;i++) if (GW.count('them') < cap()) near(e, 'runner'); }
    if (GW.wave >= 3 && (e.phageT -= dt) <= 0){ e.phageT = Math.max(7, 16 - GW.wave*.7); near(e, 'phage'); }
  },
});

base('spire', { label:'Spore Spire', hp:700, r:16, bounty:400, barY:100,
  init(e){ e.sporeT = 3; e.spitT = 6; },
  build(e, g){
    const m = skin(0x6a2a8a, { opacity:1, flatShading:true, emissive:0x200830 });
    let y = 0;
    for (let i=0;i<7;i++){ const h = 14 - i, r = 15 - i*2; const s = at(mesh(geo.cone, m, [r, h*1.6, r]), 0, y + h*.8, 0); s.rotation.y = i*.5; g.add(s); y += h*1.2; }
    e.parts.tip = at(mesh(geo.sphere, glow(0xdd66ff, 3.5), 5), 0, y + 4, 0); g.add(e.parts.tip);
    e.tipY = y + 4;
  },
  tick(e, dt){
    e.parts.tip.scale.setScalar(5 + Math.sin(e.t*5)*1.5);
    if ((e.sporeT -= dt) <= 0){ e.sporeT = Math.max(2, 4.5 - GW.wave*.15); GW.spore(e, { y:e.tipY, germs:2 }); }
    if ((e.spitT -= dt) <= 0){ e.spitT = 9; if (GW.count('them') < cap()) near(e, 'spitter'); }
  },
});

base('mother', { label:'Mother Cell (boss)', hp:3500, r:40, speed:5, dps:80, bounty:1500, barY:100, deathColor:0xff44aa,
  init(e){ e.broodT = 5; e.volleyT = 8; GW.toast('⚠ A Mother Cell is approaching!', '#ff88cc'); },
  build(e, g){
    e.parts.body = at(mesh(geo.blob, skin(0xd0307a, { opacity:.55 }), 38), 0, 30, 0); g.add(e.parts.body);
    e.parts.nuc = at(mesh(geo.blob, glow(0xff66bb, 2.5), 14), 0, 32, 0); g.add(e.parts.nuc);
    e.parts.sats = [];
    for (let i=0;i<10;i++){ const s = mesh(geo.sphere, glow(i%2 ? 0xffcc66 : 0x66ffee, 2), rand(2, 4)); g.add(s); e.parts.sats.push(s); }
  },
  tick(e, dt){
    crawl(e, dt); const t = e.t;
    e.parts.body.scale.set(38*(1 + .08*Math.sin(t*1.3)), 38*(1 + .08*Math.sin(t*1.7 + 1)), 38*(1 + .08*Math.sin(t*1.1 + 2)));
    e.parts.nuc.rotation.y += dt*.4;
    e.parts.sats.forEach((s, i) => s.position.set(Math.cos(t*.6 + i)*28, 30 + Math.sin(t + i*2)*16, Math.sin(t*.6 + i)*28));
    if ((e.broodT -= dt) <= 0){ e.broodT = 6; near(e, Math.random() < .5 ? 'brute' : 'splitter', 45); }
    if ((e.volleyT -= dt) <= 0){ e.volleyT = 8; for (let i=0;i<4;i++) GW.spore(e, { y:60, T:rand(4, 7) }); }
  },
});
})();
