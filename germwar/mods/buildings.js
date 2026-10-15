// Player buildings & units. Hot-reloadable: save this file while playing and
// existing buildings pick up the new behaviour immediately.
(() => {
const T = THREE, { rand } = GW;
const mat  = (color, o={}) => new T.MeshStandardMaterial({ color, roughness:.5, metalness:.45, ...o });
const glow = (color, i=2) => new T.MeshStandardMaterial({ color, emissive:color, emissiveIntensity:i, roughness:.4 });
const box  = (w,h,d,m) => new T.Mesh(new T.BoxGeometry(w,h,d), m);
const cyl  = (rt,rb,h,m,s=16) => new T.Mesh(new T.CylinderGeometry(rt,rb,h,s), m);
const at   = (o,x,y,z) => { o.position.set(x,y,z); return o; };
const isAir = o => !!GW.def(o).air, onGround = o => !GW.def(o).air;
const aimPt = t => t.pos.clone().setY(t.pos.y + GW.R(t)*.7);
const muzzle = (e, h) => e.pos.clone().setY(e.pos.y + h);
const rocketGeo = new T.ConeGeometry(1.6, 8, 6); rocketGeo.rotateX(Math.PI/2);
const strikeGeo = new T.ConeGeometry(3, 18, 10); strikeGeo.rotateX(Math.PI/2);
const shellGeo  = new T.SphereGeometry(2.2, 8, 6);
const tmp = new T.Vector3();

// Weapons deal a per-building multiplier against enemy bases
function hit(e, t, dmg){ if (GW.def(t).cat === 'base') dmg *= GW.def(e).baseMult ?? .5; GW.damage(t, dmg, e); }

GW.type('hq', { label:'HQ', hp:2000, r:24, speed:8, barY:56, radar:500,
  build(e, g){
    g.add(at(cyl(26,30,8,mat(0x56657a),6),0,4,0)); g.add(at(cyl(20,24,6,mat(0x7a8aa0),6),0,11,0));
    g.add(at(new T.Mesh(new T.SphereGeometry(15,24,14,0,Math.PI*2,0,Math.PI/2), mat(0x9fd4ff,{ transparent:true, opacity:.5, metalness:.1, roughness:.05 })),0,14,0));
    e.parts.core = at(new T.Mesh(new T.IcosahedronGeometry(6,1), glow(0x44ddff,3)),0,22,0); g.add(e.parts.core);
    const ring = new T.Mesh(new T.TorusGeometry(19,1.2,8,48), glow(0x44ddff,1.5)); ring.rotation.x = Math.PI/2; at(ring,0,16,0); g.add(ring); e.parts.ring = ring;
    g.add(at(cyl(.8,.8,26,mat(0xcccccc)),12,24,0)); g.add(at(new T.Mesh(new T.SphereGeometry(2,8,6), glow(0xff3344,4)),12,37,0));
    for (let i=0;i<6;i++){ const a = i/6*Math.PI*2; g.add(at(box(4,3,4,glow(0x44ffcc,1.2)), Math.cos(a)*27, 6, Math.sin(a)*27)); }
  },
  tick(e, dt){ e.parts.core.rotation.y += dt; e.parts.core.position.y = 22 + Math.sin(e.t*2)*1.5; e.parts.ring.rotation.z += dt*.6; },
});

GW.type('extractor', { label:'Extractor', cost:150, hp:260, r:12, income:4, speed:15, order:1, desc:'+$4/s income',
  maxLvl:3, upg:{ income:1 }, upgDesc:'+$4/s',
  build(e, g){
    g.add(at(cyl(12,13,5,mat(0x6b5a3a),8),0,2.5,0));
    for (const a of [0,2.1,4.2]) g.add(at(box(2,20,2,mat(0x8a7a5a)), Math.cos(a)*7, 12, Math.sin(a)*7));
    e.parts.piston = at(cyl(3,3,16,mat(0xbbbbbb)),0,12,0); g.add(e.parts.piston);
    e.parts.gem = at(new T.Mesh(new T.OctahedronGeometry(5), glow(0xffcc33,2.5)),0,26,0); g.add(e.parts.gem);
  },
  tick(e, dt){ e.parts.gem.rotation.y += dt*2; e.parts.piston.position.y = 10 + Math.abs(Math.sin(e.t*3))*6; },
});
GW.baseIncome = 3;

GW.type('wall', { label:'Wall', cost:30, hp:900, r:9, armor:.3, order:2, desc:'Cheap germ bait', maxLvl:3, upg:{ hp:.6 },
  build(e, g){ g.add(at(cyl(9,10,16,mat(0x55606e,{ flatShading:true }),6),0,8,0)); g.add(at(cyl(9.3,9.3,1.5,glow(0x33ffaa,1.5),6),0,12,0)); g.add(at(cyl(6,9,3,mat(0x707c8a),6),0,17,0)); },
});

// Radar: enemy builder phages avoid building inside radar coverage
GW.type('radar', { label:'Radar', cost:120, hp:200, r:9, radar:900, speed:14, order:2.5, desc:'Pushes enemy nests away',
  maxLvl:3, upg:{ radar:.3 }, info:e => `Coverage ${Math.round(GW.stat(e,'radar'))}`,
  build(e, g){
    g.add(at(cyl(8,9,4,mat(0x3e4a58),6),0,2,0)); g.add(at(cyl(1.5,2,20,mat(0xa0aab8)),0,13,0));
    const dish = at(new T.Group(),0,24,0); g.add(dish); e.parts.dish = dish;
    const d = new T.Mesh(new T.SphereGeometry(9,20,10,0,Math.PI*2,0,1.1), mat(0xdfe6ee,{ side:T.DoubleSide, metalness:.6 })); d.rotation.x = -1.2; dish.add(d);
    dish.add(at(new T.Mesh(new T.SphereGeometry(1.2,8,6), glow(0x55ffcc,4)),0,2,5));
  },
  tick(e, dt){
    e.parts.dish.rotation.y += dt*1.2;
    if ((e.ping = (e.ping||0) - dt) <= 0){ e.ping = 3; GW.fx.ring(e.pos, 0x55ffcc, Math.min(300, GW.stat(e,'radar')), 1.5); }
  },
});
// Is a world point covered by any player radar?
GW.radarCovered = (p, margin=0) => GW.ents.some(e => e.side === 'us' && !e.dead && GW.def(e).radar && GW.flat(e.pos, p) < GW.stat(e,'radar') + margin);

GW.type('turret', { label:'Gatling Turret', cost:100, hp:320, r:10, range:140, dmg:18, rate:.25, speed:18, canAttack:true,
  maxLvl:3, upg:{ dmg:.45, range:.12 }, baseMult:.4, order:3, desc:'Fast, hits air',
  build(e, g){
    g.add(at(box(16,6,16,mat(0x4d5a68)),0,3,0));
    const head = at(new T.Group(),0,10,0); g.add(head); e.parts.head = head;
    head.add(box(10,7,10,mat(0x8193a8))); head.add(at(box(10.2,1,10.2,glow(0xffcc44,1.5)),0,2,0));
    const barrels = at(new T.Group(),0,0,8); head.add(barrels); e.parts.barrels = barrels;
    for (let i=0;i<3;i++){ const b = cyl(.8,.8,12,mat(0x2a2a2a),6); b.rotation.x = Math.PI/2; b.position.set(Math.cos(i*2.1)*1.6, Math.sin(i*2.1)*1.6, 2); barrels.add(b); }
  },
  tick(e, dt){
    const t = GW.acquire(e, GW.stat(e,'range')); if (!t) return;
    const p = aimPt(t); GW.aim(e, p); e.parts.barrels.rotation.z += dt*25;
    if (e.cd > 0) return; e.cd = GW.stat(e,'rate');
    GW.fx.tracer(muzzle(e,10), p, 0xffee88); hit(e, t, GW.stat(e,'dmg'));
  },
});

GW.type('flamer', { label:'Flamer', cost:175, hp:380, r:11, range:75, dmg:55, speed:15, canAttack:true, targets:onGround,
  maxLvl:3, upg:{ dmg:.5, range:.15 }, baseMult:.6, order:4, desc:'Burns crowds',
  build(e, g){
    g.add(at(cyl(11,12,6,mat(0x5a4a40),8),0,3,0));
    const head = at(new T.Group(),0,10,0); g.add(head); e.parts.head = head;
    head.add(box(9,6,9,mat(0x8a6a50)));
    for (const s of [-1,1]){ const tk = cyl(2.2,2.2,9,mat(0xcc4422),10); tk.rotation.x = Math.PI/2; at(tk,s*5.5,1,-2); head.add(tk); }
    const noz = new T.Mesh(new T.ConeGeometry(2,8,8), mat(0x333333)); noz.rotation.x = Math.PI/2; at(noz,0,0,8); head.add(noz);
    head.add(at(new T.Mesh(new T.SphereGeometry(1.2,8,6), glow(0x55aaff,4)),0,0,12.5));
  },
  tick(e, dt){
    const R = GW.stat(e,'range'), t = GW.acquire(e, R, onGround); if (!t) return;
    GW.aim(e, t.pos);
    const yaw = Math.atan2(t.pos.x-e.pos.x, t.pos.z-e.pos.z);
    for (const o of GW.within(e.pos, 'them', R, onGround)){
      const a = Math.atan2(o.pos.x-e.pos.x, o.pos.z-e.pos.z), da = Math.abs(((a - yaw + Math.PI*3) % (Math.PI*2)) - Math.PI);
      if (da < .45) hit(e, o, GW.stat(e,'dmg')*dt);
    }
    if ((e.fl = (e.fl||0) - dt) <= 0){
      e.fl = .035;
      const dir = new T.Vector3(Math.sin(yaw + rand(-.2,.2)), rand(-.05,.1), Math.cos(yaw + rand(-.2,.2)));
      GW.fx.particle(muzzle(e,10).addScaledVector(dir, 12), dir.multiplyScalar(R*1.5), { color:Math.random()<.5 ? 0xff6622 : 0xffbb33, size:2, grow:3, life:.5 });
    }
  },
});

GW.type('tesla', { label:'Tesla Coil', cost:225, hp:300, r:10, range:115, dmg:40, rate:1.1, chain:4, speed:14, canAttack:true,
  maxLvl:3, upg:{ dmg:.4, range:.12, chain:.5 }, baseMult:.5, order:5, desc:'Chain lightning',
  build(e, g){
    g.add(at(cyl(10,11,5,mat(0x3a4250),8),0,2.5,0)); g.add(at(cyl(2.5,3.5,26,mat(0x9aa5b5)),0,16,0));
    for (let i=0;i<4;i++){ const ring = new T.Mesh(new T.TorusGeometry(6-i,1,8,24), mat(0xc58a3a,{ metalness:.9, roughness:.3 })); ring.rotation.x = Math.PI/2; at(ring,0,9+i*5,0); g.add(ring); }
    e.parts.orb = at(new T.Mesh(new T.SphereGeometry(4.5,16,12), glow(0x88ccff,3.5)),0,31,0); g.add(e.parts.orb);
  },
  tick(e, dt){
    e.parts.orb.scale.setScalar(1 + .15*Math.sin(e.t*14));
    if (e.cd > 0) return;
    let t = GW.acquire(e, GW.stat(e,'range')); if (!t) return;
    e.cd = GW.stat(e,'rate');
    let from = muzzle(e,31); const done = new Set(), n = Math.round(GW.stat(e,'chain'));
    for (let i=0; i<n && t; i++){
      const p = aimPt(t); GW.fx.lightning(from, p); hit(e, t, GW.stat(e,'dmg')); done.add(t); from = p;
      t = GW.nearest(p, 'them', 70, o => !done.has(o));
    }
  },
});

GW.type('laser', { label:'Laser Tower', cost:275, hp:280, r:10, range:230, dmg:75, speed:12, canAttack:true,
  maxLvl:3, upg:{ dmg:.5, range:.15 }, baseMult:.8, order:6, desc:'Beam melts big things',
  build(e, g){
    g.add(at(cyl(10,11,4,mat(0x404858),6),0,2,0)); g.add(at(cyl(4,7,22,mat(0xd0d6e0)),0,15,0));
    const head = at(new T.Group(),0,28,0); g.add(head); e.parts.head = head;
    head.add(box(7,6,10,mat(0x606a7a))); head.add(at(new T.Mesh(new T.SphereGeometry(2,10,8), glow(0xff2244,4)),0,0,5.5));
    const bg = new T.CylinderGeometry(.9,.9,1,8); bg.rotateX(Math.PI/2); bg.translate(0,0,.5);
    const beam = new T.Mesh(bg, new T.MeshBasicMaterial({ color:0xff3355, transparent:true, opacity:.9, blending:T.AdditiveBlending, depthWrite:false }));
    beam.position.y = 28; beam.visible = false; beam.raycast = () => {}; g.add(beam); e.parts.beam = beam;
  },
  tick(e, dt){
    const R = GW.stat(e,'range');
    let t = e.attack && !e.attack.dead && GW.flat(e.attack.pos, e.pos) - GW.R(e.attack) <= R ? e.attack : null;
    if (!t){ let best = -1; for (const o of GW.within(e.pos, 'them', R)) if (o.hp > best){ best = o.hp; t = o; } }
    const beam = e.parts.beam; beam.visible = !!t; if (!t) return;
    const p = aimPt(t); GW.aim(e, p); beam.lookAt(p);
    beam.scale.set(1 + Math.random()*.6, 1 + Math.random()*.6, beam.getWorldPosition(tmp).distanceTo(p));
    hit(e, t, GW.stat(e,'dmg')*dt);
    if (Math.random() < .3) GW.fx.particle(p, new T.Vector3(rand(-20,20), rand(5,30), rand(-20,20)), { color:0xff5566, size:1.2, life:.3 });
  },
});

GW.type('battery', { label:'Missile Battery', cost:200, hp:260, r:12, range:750, rate:.9, dmg:70, speed:15,
  maxLvl:3, upg:{ rate:-.25, range:.15 }, order:7, desc:'Shoots spores & flyers',
  build(e, g){
    g.add(at(box(18,5,18,mat(0x4a5560)),0,2.5,0));
    const rack = at(new T.Group(),0,9,0); rack.rotation.x = -.6; g.add(rack);
    for (let i=0;i<4;i++){ const t = cyl(2,2,14,mat(0xccd4dd),8); t.rotation.x = Math.PI/2; t.position.set((i%2)*5-2.5, Math.floor(i/2)*5-2.5, 0); rack.add(t); }
    e.parts.radar = at(box(10,6,1,glow(0x66ccff,1.2)),0,18,-7); g.add(e.parts.radar);
  },
  tick(e, dt){
    e.parts.radar.rotation.y += dt*2;
    if (e.cd > 0) return;
    const R = GW.stat(e,'range'); let tgt = null, bd = R;
    for (const p of GW.projs){ if (!p.interceptable || p.dead || p.claimed) continue; const d = p.pos.distanceTo(e.pos); if (d < bd){ bd = d; tgt = p; } }
    if (!tgt) tgt = GW.nearest(e.pos, 'them', R, isAir);
    if (!tgt) return;
    if (!tgt.type) tgt.claimed = true;
    e.cd = GW.stat(e,'rate');
    const dmg = GW.stat(e,'dmg');
    GW.homing(muzzle(e,12), tgt, 430, { mesh:new T.Mesh(rocketGeo, glow(0x66ddff,2)), trail:0x99aabb,
      onHit:(t, p) => { if (t.type) GW.damage(t, dmg, e); else { t.dead = true; GW.money += 10; } GW.fx.explode(p, 0xffee88, 14); } });
  },
});

GW.type('shield', { label:'Shield Dome', cost:250, hp:300, r:11, radius:140, speed:10, maxLvl:3, upg:{ radius:.25 }, order:8, desc:'Blocks spores',
  info:e => `Energy ${Math.round(e.energy ?? 300)}/300`,
  onSpawn(e){ e.energy = 300; },
  build(e, g){
    g.add(at(cyl(10,12,6,mat(0x3c4a5c),8),0,3,0)); g.add(at(new T.Mesh(new T.OctahedronGeometry(5), glow(0x66aaff,3)),0,13,0));
    const dome = new T.Mesh(new T.SphereGeometry(1,40,20,0,Math.PI*2,0,Math.PI/2),
      new T.MeshBasicMaterial({ color:0x4499ff, transparent:true, opacity:.12, side:T.DoubleSide, depthWrite:false, blending:T.AdditiveBlending }));
    dome.scale.setScalar(GW.types.shield.radius); dome.raycast = () => {}; g.add(dome); e.parts.dome = dome;
  },
  tick(e, dt){
    const R = GW.stat(e,'radius');
    e.energy = Math.min(300, (e.energy ?? 300) + 12*dt);
    e.parts.dome.scale.setScalar(R); e.parts.dome.material.opacity = .03 + .14*e.energy/300;
    for (const p of GW.projs){
      if (!p.interceptable || p.dead || e.energy < 40 || p.pos.distanceTo(e.pos) > R) continue;
      p.dead = true; e.energy -= 40; GW.fx.explode(p.pos, 0x66bbff, 18);
    }
  },
});

GW.type('repair', { label:'Repair Bay', cost:200, hp:260, r:11, radius:120, heal:14, speed:12, maxLvl:3, upg:{ heal:.6, radius:.2 }, order:9, desc:'Heals nearby',
  build(e, g){
    g.add(at(cyl(11,12,4,mat(0xd8dde4),8),0,2,0));
    g.add(at(box(14,3,4,glow(0x44ff88,2)),0,6,0)); g.add(at(box(4,3,14,glow(0x44ff88,2)),0,6,0));
    const arm = at(new T.Group(),0,10,0); g.add(arm); e.parts.arm = arm;
    arm.add(at(cyl(1,1,12,mat(0x999999)),0,6,0)); arm.add(at(box(14,1.5,1.5,mat(0xaaaaaa)),7,12,0));
    arm.add(at(new T.Mesh(new T.SphereGeometry(1.6,8,6), glow(0x66ffaa,4)),14,11,0));
  },
  tick(e, dt){
    e.parts.arm.rotation.y += dt*1.5;
    const R = GW.stat(e,'radius'), h = GW.stat(e,'heal'); let any = false;
    for (const o of GW.within(e.pos, 'us', R)) if (o !== e && o.hp < o.maxHp){ o.hp = Math.min(o.maxHp, o.hp + h*dt); any = true; }
    if (any && (e.pulse = (e.pulse||0) - dt) <= 0){ e.pulse = 1.2; GW.fx.ring(e.pos, 0x55ff99, R, 1.2); }
  },
});

GW.type('silo', { label:'Rocket Silo', cost:300, hp:300, r:13, range:550, dmg:220, rate:5, speed:12, canAttack:true,
  maxLvl:6, upg:{ range:.27 }, upgDesc:'+150 range', order:10, desc:'Strikes enemy bases',
  build(e, g){
    g.add(at(cyl(13,14,6,mat(0x5d5048),8),0,3,0)); g.add(at(cyl(6,6,22,mat(0x8a8f96)),0,15,0));
    for (const y of [9,15,21]) g.add(at(cyl(6.2,6.2,1,glow(0xff6633,1.5)),0,y,0));
    e.parts.nose = at(new T.Mesh(new T.ConeGeometry(6,9,16), glow(0xff6633,1.2)),0,30.5,0); g.add(e.parts.nose);
    for (const s of [-1,1]) g.add(at(box(2,8,8,mat(0x444444)),s*8,7,0));
  },
  tick(e, dt){
    e.parts.nose.visible = e.cd <= 0;
    if (e.cd > 0) return;
    const R = GW.stat(e,'range');
    const t = e.attack && !e.attack.dead && onGround(e.attack) && GW.flat(e.attack.pos, e.pos) - GW.R(e.attack) <= R
      ? e.attack : GW.nearest(e.pos, 'them', R, o => GW.def(o).cat === 'base');
    if (!t) return;
    e.cd = GW.stat(e,'rate');
    const from = muzzle(e,34), to = t.pos.clone(), dmg = GW.stat(e,'dmg');
    GW.lob(from, to, 2.5 + GW.flat(from, to)/260, { mesh:new T.Mesh(strikeGeo, glow(0xff7733,2)), trail:0xaaaaaa,
      onHit:p => {
        GW.fx.explode(p.clone().setY(p.y + 6), 0xff9933, 70); GW.fx.shock(p, 0xffaa55, 100);
        for (const o of GW.within(p, 'them', 50, onGround)) GW.damage(o, GW.def(o).cat === 'base' ? dmg : 999, e);
      } });
  },
});

GW.type('tank', { label:'Tank', cat:'unit', cost:250, hp:450, r:9, range:125, dmg:40, rate:.55, speed:55, canAttack:true,
  maxLvl:3, upg:{ dmg:.4, hp:.3 }, baseMult:1.5, order:11, desc:'Mobile assault',
  build(e, g){
    g.add(at(box(14,6,20,mat(0x55663a)),0,4,0));
    for (const s of [-1,1]) g.add(at(box(4,5,22,mat(0x222222)),s*8,2.5,0));
    for (const s of [-1,1]) g.add(at(new T.Mesh(new T.SphereGeometry(.9,6,4), glow(0xffffcc,4)),s*4.5,5,10.2));
    const head = at(new T.Group(),0,9,0); g.add(head); e.parts.head = head;
    head.add(box(9,4,10,mat(0x6d7f48)));
    const barrel = cyl(1,1,14,mat(0x2a2a2a),8); barrel.rotation.x = Math.PI/2; barrel.position.z = 10; head.add(barrel);
  },
  tick(e, dt){
    const R = GW.stat(e,'range'); GW.unitAI(e, dt, R);
    const t = GW.acquire(e, R); if (!t) return;
    const p = aimPt(t); GW.aim(e, p);
    if (e.cd > 0) return; e.cd = GW.stat(e,'rate');
    GW.fx.tracer(muzzle(e,9), p, 0xffaa33); GW.fx.explode(p, 0xffaa33, 5); hit(e, t, GW.stat(e,'dmg'));
  },
});

GW.type('artillery', { label:'Artillery', cat:'unit', cost:350, hp:300, r:10, range:340, dmg:90, rate:2.6, speed:35, canAttack:true, targets:onGround,
  maxLvl:3, upg:{ dmg:.4, range:.15 }, baseMult:1.2, order:12, desc:'Long-range splash',
  build(e, g){
    g.add(at(box(12,6,22,mat(0x5a5a40)),0,5,0));
    for (const z of [-7,0,7]) for (const s of [-1,1]){ const w = cyl(2.6,2.6,2,mat(0x1a1a1a),10); w.rotation.z = Math.PI/2; at(w,s*7,2.6,z); g.add(w); }
    const head = at(new T.Group(),0,9,-3); g.add(head); e.parts.head = head;
    head.add(box(8,4,8,mat(0x6a6a4a)));
    const b = cyl(1.3,1.6,22,mat(0x2a2a2a),8); b.rotation.x = Math.PI/2 - .6; b.position.set(0,6,8); head.add(b);
  },
  tick(e, dt){
    const R = GW.stat(e,'range'); GW.unitAI(e, dt, R);
    const t = GW.acquire(e, R, onGround); if (!t) return;
    GW.aim(e, t.pos);
    if (e.cd > 0) return; e.cd = GW.stat(e,'rate');
    const from = muzzle(e,16), dmg = GW.stat(e,'dmg');
    GW.lob(from, t.pos.clone(), 1.2 + GW.flat(from, t.pos)/300, { mesh:new T.Mesh(shellGeo, glow(0xffcc66,2)), trail:0x777777,
      onHit:p => { GW.fx.explode(p, 0xffaa44, 30); for (const o of GW.within(p, 'them', 35, onGround)) hit(e, o, dmg); } });
  },
});
})();
