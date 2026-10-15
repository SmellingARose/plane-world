// World: a giant alien petri dish — rolling bio-terrain, glowing fungi, crystals,
// pools, drifting motes and dead giant cells. Hot-reloadable: rebuilds itself on save.
(() => {
const T = THREE, { scene, rand } = GW;
if (GW.world){ scene.remove(GW.world); GW.world.traverse(o => { o.geometry?.dispose(); o.material?.dispose?.(); }); }
const W = GW.world = new T.Group(); scene.add(W);

const ss = (a, b, x) => { x = Math.min(1, Math.max(0, (x-a)/(b-a))); return x*x*(3-2*x); };
GW.heightAt = (x, z) => {
  const r = Math.hypot(x, z);
  const n = Math.sin(x*.0042 + 1.3)*Math.cos(z*.0051)*28 + Math.sin(x*.011 + z*.007)*11
          + Math.sin(z*.019 - x*.004)*5 + Math.cos(x*.027 + z*.023)*2.5;
  return n*ss(300, 750, r) + Math.pow(Math.max(0, r-1900)/220, 2)*60;   // flat base, rising dish rim
};

// ---- Sky dome & fog ----
scene.background = null;
scene.fog = new T.FogExp2(0x0d2834, .00026);
const sky = new T.Mesh(new T.SphereGeometry(9000, 32, 16), new T.ShaderMaterial({
  side:T.BackSide, depthWrite:false, fog:false,
  uniforms:{ top:{ value:new T.Color(0x05031a) }, mid:{ value:new T.Color(0x123f52) }, glow:{ value:new T.Color(0x3a7a8a) } },
  vertexShader:`varying vec3 vP; void main(){ vP = normalize(position); gl_Position = projectionMatrix*modelViewMatrix*vec4(position,1.); }`,
  fragmentShader:`uniform vec3 top, mid, glow; varying vec3 vP;
    void main(){ float h = vP.y; vec3 c = mix(mid, top, smoothstep(0., .55, h));
      c += glow * pow(1. - abs(h), 6.) * .6; gl_FragColor = vec4(c, 1.); }`,
}));
W.add(sky);
const starG = new T.BufferGeometry(), sp = [];
for (let i=0;i<1800;i++){ const v = new T.Vector3().randomDirection().multiplyScalar(8000); if (v.y < 500) v.y = Math.abs(v.y) + 500; sp.push(v.x, v.y, v.z); }
starG.setAttribute('position', new T.Float32BufferAttribute(sp, 3));
W.add(new T.Points(starG, new T.PointsMaterial({ color:0xbfe8ff, size:7, fog:false, transparent:true, opacity:.8 })));

GW.hemi.color.set(0x9fdcff); GW.hemi.groundColor.set(0x3a1440); GW.hemi.intensity = 1.05;
GW.sun.color.set(0xfff0dd); GW.sun.intensity = 2.2;
// Less glare (softer bloom, dimmer glowing decor) but brighter, readable daylight on units; that only catches the brightest things
GW.bloom.strength = .38; GW.bloom.radius = .35; GW.bloom.threshold = .92;
GW.renderer.toneMappingExposure = 1.0;

// ---- Terrain ----
const SIZE = 5200, SEG = 260;
const tg = new T.PlaneGeometry(SIZE, SIZE, SEG, SEG); tg.rotateX(-Math.PI/2);
const pos = tg.attributes.position, cols = new Float32Array(pos.count*3);
const lo = new T.Color(0x0b2738), mid = new T.Color(0x1d5c50), hi = new T.Color(0x9a3d72), peak = new T.Color(0xe08a7a),
      rim = new T.Color(0xcab48a), pad = new T.Color(0x34485a), c = new T.Color();
for (let i=0; i<pos.count; i++){
  const x = pos.getX(i), z = pos.getZ(i), h = GW.heightAt(x, z), r = Math.hypot(x, z);
  pos.setY(i, h);
  c.lerpColors(lo, mid, ss(-25, 2, h)).lerp(hi, ss(8, 30, h)).lerp(peak, ss(30, 45, h)*.6);
  c.lerp(pad, (1 - ss(280, 430, r))*.75).lerp(rim, ss(1880, 2150, r));
  // organic veins
  const vein = Math.abs(Math.sin(x*.02 + Math.sin(z*.013)*3)) < .05 && r > 450 ? .25 : 0;
  c.lerp(new T.Color(0x3affc0), vein);
  c.offsetHSL(0, 0, (Math.random()-.5)*.035);
  cols.set([c.r, c.g, c.b], i*3);
}
tg.setAttribute('color', new T.BufferAttribute(cols, 3)); tg.computeVertexNormals();
const terrain = new T.Mesh(tg, new T.MeshStandardMaterial({ vertexColors:true, roughness:.93, metalness:0, flatShading:true }));
terrain.receiveShadow = true; W.add(terrain); GW.ground = terrain;

// Base plaza: hex plate with glowing trim
const plaza = new T.Mesh(new T.CylinderGeometry(270, 275, 3, 6), new T.MeshStandardMaterial({ color:0x5d7286, roughness:.75, metalness:.15 }));
plaza.position.y = -1; plaza.receiveShadow = true; W.add(plaza);
const trim = new T.Mesh(new T.TorusGeometry(272, 1.6, 6, 6), new T.MeshStandardMaterial({ color:0x44ffcc, emissive:0x44ffcc, emissiveIntensity:2 }));
trim.rotation.x = Math.PI/2; trim.position.y = .8; W.add(trim);
for (let i=0;i<6;i++){ // lane lights
  const a = i/6*Math.PI*2 + Math.PI/6;
  for (let k=1;k<6;k++){ const l = new T.Mesh(new T.BoxGeometry(6,1,2), new T.MeshBasicMaterial({ color:0x55ffdd }));
    l.position.set(Math.cos(a)*k*45, .8, Math.sin(a)*k*45); l.rotation.y = -a; W.add(l); }
}

// ---- Fluid pools ----
const water = new T.Mesh(new T.PlaneGeometry(SIZE, SIZE), new T.MeshStandardMaterial({
  color:0x1590a8, transparent:true, opacity:.55, roughness:.12, metalness:.4, emissive:0x08445a, emissiveIntensity:1 }));
water.rotation.x = -Math.PI/2; water.position.y = -9; W.add(water);

// ---- Scatter helper (instanced, avoids base + pools) ----
const dummy = new T.Object3D();
function scatter(geo, mat, n, minR, maxR, place, { shadow=true, minH=-6 }={}){
  const im = new T.InstancedMesh(geo, mat, n); let k = 0, tries = 0;
  while (k < n && tries++ < n*20){
    const a = rand(0, Math.PI*2), r = Math.sqrt(rand(minR*minR, maxR*maxR)), x = Math.cos(a)*r, z = Math.sin(a)*r, h = GW.heightAt(x, z);
    if (h < minH) continue;
    dummy.position.set(x, h, z); dummy.rotation.set(0, rand(0, 6.28), 0); dummy.scale.setScalar(1);
    place(dummy, k, im); dummy.updateMatrix(); im.setMatrixAt(k++, dummy.matrix);
  }
  im.count = k; im.castShadow = shadow; im.receiveShadow = true; W.add(im); return im;
}

// Glowing mushrooms: stems + caps (caps use HDR instance colours so they bloom)
const shroomSpots = [];
scatter(new T.CylinderGeometry(.6, 1, 1, 6), new T.MeshStandardMaterial({ color:0xe8dcc8, roughness:.8 }), 260, 480, 1850, (d) => {
  const s = rand(4, 14); d.scale.set(s*.5, s*2.2, s*.5); d.position.y += s*1.1; shroomSpots.push([d.position.x, d.position.y + s*1.1, d.position.z, s]);
});
const caps = new T.InstancedMesh(new T.SphereGeometry(1, 14, 8, 0, Math.PI*2, 0, Math.PI/2), new T.MeshBasicMaterial({ color:0xffffff }), shroomSpots.length);
const capPalette = [[.12,1.1,.8],[1.1,.25,.9],[.2,.7,1.3],[1.2,.8,.15]];
shroomSpots.forEach(([x,y,z,s], i) => {
  dummy.position.set(x, y, z); dummy.rotation.set(0,0,0); dummy.scale.set(s*1.4, s*.8, s*1.4); dummy.updateMatrix(); caps.setMatrixAt(i, dummy.matrix);
  const p = capPalette[i % capPalette.length], k = rand(.6, 1.1); caps.setColorAt(i, new T.Color(p[0]*k, p[1]*k, p[2]*k));
});
W.add(caps);

// Crystal shards
scatter(new T.OctahedronGeometry(1, 0), new T.MeshStandardMaterial({ color:0x66e0ff, emissive:0x2bb8ff, emissiveIntensity:.6, roughness:.15, metalness:.2, flatShading:true }),
  220, 520, 2000, d => { const s = rand(3, 10); d.scale.set(s, s*rand(2.5, 4.5), s); d.rotation.set(rand(-.4,.4), rand(0,6.28), rand(-.4,.4)); d.position.y += s*1.2; });
// Rocks
scatter(new T.DodecahedronGeometry(1, 0), new T.MeshStandardMaterial({ color:0x4d3f5a, roughness:.95, flatShading:true }),
  380, 460, 2300, d => { const s = rand(4, 22); d.scale.set(s*rand(.8,1.4), s*rand(.5,.9), s*rand(.8,1.4)); d.rotation.set(rand(0,3), rand(0,6), rand(0,3)); }, { minH:-60 });
// Tube worms / coral fingers
scatter(new T.CylinderGeometry(.7, 1, 1, 7), new T.MeshStandardMaterial({ color:0xff7a9a, emissive:0x7a1030, emissiveIntensity:.35, roughness:.5 }),
  420, 600, 1900, d => { const s = rand(1.5, 3.5); d.scale.set(s, s*rand(6, 16), s); d.rotation.set(rand(-.25,.25), 0, rand(-.25,.25)); d.position.y += s*5; });

// Dead giant cells, half-sunk: translucent membrane with glowing nucleus
const cells = [];
for (let i=0;i<14;i++){
  const a = rand(0, 6.28), r = rand(700, 1800), x = Math.cos(a)*r, z = Math.sin(a)*r, R = rand(45, 110);
  const g = new T.Group(); g.position.set(x, GW.heightAt(x, z) - R*.35, z);
  const hue = rand(.45, .9);
  g.add(new T.Mesh(new T.SphereGeometry(R, 32, 20), new T.MeshStandardMaterial({ color:new T.Color().setHSL(hue,.6,.55), transparent:true, opacity:.22, roughness:.1, metalness:.1, depthWrite:false })));
  const nuc = new T.Mesh(new T.IcosahedronGeometry(R*.28, 2), new T.MeshStandardMaterial({ color:new T.Color().setHSL(hue,.9,.6), emissive:new T.Color().setHSL(hue,.9,.5), emissiveIntensity:.7 }));
  nuc.position.set(R*.2, R*.25, 0); g.add(nuc); cells.push(nuc); W.add(g);
}

// Drifting bio-motes
const MN = 2200, mg = new T.BufferGeometry(), mp = new Float32Array(MN*3), mc = new Float32Array(MN*3);
for (let i=0;i<MN;i++){
  mp.set([rand(-2000,2000), rand(0,420), rand(-2000,2000)], i*3);
  const col = new T.Color().setHSL(Math.random() < .5 ? .48 : .88, 1, .65); mc.set([col.r, col.g, col.b], i*3);
}
mg.setAttribute('position', new T.BufferAttribute(mp, 3)); mg.setAttribute('color', new T.BufferAttribute(mc, 3));
const motes = new T.Points(mg, new T.PointsMaterial({ size:2.4, vertexColors:true, transparent:true, opacity:.45, blending:T.AdditiveBlending, depthWrite:false }));
W.add(motes);

let t = 0;
GW.frameHooks.world = dt => {
  t += dt;
  const a = mg.attributes.position.array;
  for (let i=0;i<MN;i++){ a[i*3+1] += dt*(6 + (i%7)); a[i*3] += Math.sin(t*.3 + i)*dt*4; if (a[i*3+1] > 420) a[i*3+1] = 0; }
  mg.attributes.position.needsUpdate = true;
  water.position.y = -9 + Math.sin(t*.5)*.8;
  water.material.emissiveIntensity = .35 + Math.sin(t*.8)*.1;
  for (const [i, n] of cells.entries()) n.material.emissiveIntensity = .55 + Math.sin(t*1.3 + i)*.25;
  trim.material.emissiveIntensity = .9 + Math.sin(t*2)*.3;
};
})();
