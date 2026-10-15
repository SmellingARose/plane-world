// Enemy creatures. Models are built from parts with per-part animation; edit and save to see changes live.
var P = M.part;

GW.type('germ', { label: 'Ciliate Crawler', side: 'them', cat: 'creature', brain: 'crawl', hp: 30, r: 4, speed: 20, dps: 10, bounty: 4, divideEvery: 18, deathColor: '#88ff55',
  model: M.cat([
    P('sphere', [0, 3, 0], [3.4, 2.6, 3.4], '#3faa48', { jitter: true, rough: 0.3 }),
    P('sphere', [0, 3, -4.2], [2.7, 2.1, 2.8], '#3faa48', { jitter: true, anim: 'wiggle', amp: 0.9, f: 8, ph: 1.2 }),
    P('sphere', [0, 3, -8.4], [2.0, 1.6, 2.2], '#3faa48', { jitter: true, anim: 'wiggle', amp: 1.8, f: 8, ph: 2.4, lod: false }),
    P('sphere', [0, 3.4, -1], 1, '#ccff66', { e: 1.6 }),
    P('cyl', [-1.4, 6, 1.6], [0.3, 3, 0.3], '#1d4a22', { rot: [0, 0, 0.35], lod: false }), P('cyl', [1.4, 6, 1.6], [0.3, 3, 0.3], '#1d4a22', { rot: [0, 0, -0.35], lod: false }),
    P('sphere', [-2, 7.6, 1.8], 0.8, '#fff6a0', { e: 2 }), P('sphere', [2, 7.6, 1.8], 0.8, '#fff6a0', { e: 2 }),
    P('cone', [-1.2, 2.4, 3.6], [0.5, 2.4, 0.5], '#1d4a22', { rot: [Math.PI / 2, 0, 0.5], lod: false }), P('cone', [1.2, 2.4, 3.6], [0.5, 2.4, 0.5], '#1d4a22', { rot: [Math.PI / 2, 0, -0.5], lod: false }),
  ], [0, 1, 2, 3, 4, 5, 6, 7].map(function(i) { var side = i % 2 ? 1 : -1;
      return P('cyl', [side * 2.8, 2.2, 1.5 - (i >> 1) * 2.6], [0.15, 2.6, 0.15], '#1d4a22', { rot: [0, 0, side * 1.1], anim: 'swing', amp: 0.6, f: 13, ph: i, lod: false }); })) });

GW.type('runner', { label: 'Virus Skitterer', side: 'them', cat: 'creature', brain: 'crawl', hp: 16, r: 3, speed: 62, dps: 7, bounty: 3, deathColor: '#ff4466',
  model: M.cat([P('ico', [0, 5, 0], 2.6, '#ff3355', { e: 0.9, anim: 'spin', f: 4 })],
    M.ring(6, 3.2, 5, function(x, y, z, a) { return P('cone', [x, y, z], [0.4, 2, 0.4], '#ffd0d8', { rot: [0, -a, Math.PI / 2], anim: 'spin', f: 4, lod: false }); }),
    [P('cone', [0, 8.2, 0], [0.4, 2, 0.4], '#ffd0d8', { lod: false })],
    M.legs(6, 2, 5, 4.5, 6, '#3a0d18')) });

GW.type('brute', { label: 'Amoeba Titan', side: 'them', cat: 'creature', brain: 'crawl', hp: 450, r: 13, speed: 11, dps: 45, armor: 0.3, bounty: 35, deathColor: '#bb66ff',
  model: M.cat([
    P('blob', [0, 12, 0], 13, '#7a2fd0', { rough: 0.2, anim: 'pulse', amp: 0.1, f: 2 }),
    P('torus', [0, 10, 11], [5, 5, 5], '#2a0a30', { rot: [Math.PI / 2, 0, 0], anim: 'pulse', amp: 0.18, f: 3 }),
    P('sphere', [0, 10, 10.6], [4.2, 4.2, 1], '#050004'),
  ], M.ring(10, 4.6, 0, function(x, y, z, a) { return P('cone', [x, 10 + z, 11.6], [0.8, 2.8, 0.8], '#f4ecd8', { rot: [0, 0, a + Math.PI / 2], lod: false }); }),
    [-4, -2, 0, 2, 4].map(function(x, i) { return P('sphere', [x, 21 + Math.sin(i) * 1.5, 7], 1.1, '#ff5ad0', { e: 2 }); }),
    [0, 1, 2, 3].map(function(i) { return P('sphere', [Math.cos(i * 1.6) * 5, 12, Math.sin(i * 1.6) * 5], 2, i % 2 ? '#ff66cc' : '#66ffee', { e: 1.4, anim: 'orbit', f: 0.8, amp: 3, ph: i }); }),
    M.tentacle([10, 6, 0], [0.7, -0.2, 0], 7, 2.2, '#6a2ad0', 0), M.tentacle([-10, 6, 0], [-0.7, -0.2, 0], 7, 2.2, '#6a2ad0', 1),
    M.tentacle([6, 6, -8], [0.5, -0.2, -0.6], 7, 2.2, '#6a2ad0', 2), M.tentacle([-6, 6, -8], [-0.5, -0.2, -0.6], 7, 2.2, '#6a2ad0', 3)) });

GW.type('spitter', { label: 'Acid Mantis', side: 'them', cat: 'creature', brain: 'ranged', hp: 60, r: 6, speed: 20, range: 170, rate: 2.2, dmg: 22, bounty: 8, deathColor: '#ccff33',
  model: M.cat([
    P('sphere', [0, 7, -5], [4.2, 3.6, 5.2], '#a8e030', { rough: 0.15, anim: 'pulse', amp: 0.12, f: 3 }),
    P('sphere', [0, 7, -5], 2.4, '#b8ff30', { e: 1.8, anim: 'pulse', amp: 0.2, f: 3 }),
    P('sphere', [0, 7, 1], [2.4, 2.2, 3.4], '#4a6a14', { metal: 0.3 }),
    P('sphere', [0, 9.5, 4.5], [2, 1.8, 2.4], '#4a6a14', { metal: 0.3 }),
    P('sphere', [-1.4, 10.3, 5.7], 0.8, '#ffee55', { e: 2.5 }), P('sphere', [1.4, 10.3, 5.7], 0.8, '#ffee55', { e: 2.5 }),
    P('cyl', [-1.8, 7, 6], [0.35, 5, 0.35], '#4a6a14', { rot: [-0.6, 0, 0], anim: 'swing', amp: 0.3, f: 4 }),
    P('cyl', [1.8, 7, 6], [0.35, 5, 0.35], '#4a6a14', { rot: [-0.6, 0, 0], anim: 'swing', amp: 0.3, f: 4, ph: 1 }),
    P('cone', [-1.8, 5, 8.5], [0.5, 4, 0.5], '#d8f080', { rot: [1.9, 0, 0], lod: false }), P('cone', [1.8, 5, 8.5], [0.5, 4, 0.5], '#d8f080', { rot: [1.9, 0, 0], lod: false }),
  ], M.legs(4, 2, 6.5, 4, 7, '#4a6a14')) });

GW.type('splitter', { label: 'Mitotic Splitter', side: 'them', cat: 'creature', brain: 'crawl', hp: 90, r: 7, speed: 18, dps: 14, bounty: 8, deathSpawn: ['germ', 3], deathColor: '#ff9933',
  model: M.cat([
    P('sphere', [-3, 6, 0], 5.5, '#ff8a3a', { anim: 'wiggle', amp: -1.2, f: 3, rough: 0.2 }),
    P('sphere', [3, 6, 0], 5.5, '#ff8a3a', { anim: 'wiggle', amp: 1.2, f: 3, rough: 0.2 }),
    P('torus', [0, 6, 0], [4, 4, 4], '#d86a2a', { rot: [0, 0, Math.PI / 2], anim: 'pulse', amp: 0.2, f: 3 }),
  ], [-1, 0, 1].map(function(k) { return P('cyl', [0, 6 + k * 1.2, k * 0.8], [0.12, 6, 0.12], '#ffaa66', { e: 1, rot: [0, 0, Math.PI / 2], lod: false }); }),
    [-4, -3, 3, 4].map(function(x, i) { return P('cyl', [x, 6 + (i % 2) * 1.5, (i % 2) - 0.5], [0.5, 2.6, 0.5], '#ffdd55', { e: 1.6, rot: [i, 0, i * 0.7], lod: false }); })) });

GW.type('phage', { label: 'Phage (flying)', side: 'them', cat: 'creature', brain: 'flyer', air: true, alt: 45, hp: 55, r: 6, speed: 42, dps: 20, bounty: 10, deathColor: '#66ffee',
  model: M.cat([P('ico', [0, 12, 0], 5, '#9fe8e0', { metal: 0.8, rough: 0.25 }), P('sphere', [0, 12, 0], 2.4, '#55ffdd', { e: 2 }),
    P('cyl', [0, 3, 0], [1.2, 10, 1.2], '#9fe8e0', { metal: 0.8 }), P('cyl', [0, -2, 0], [3, 1, 3], '#9fe8e0', { metal: 0.8 })],
    M.ring(6, 4, -5, function(x, y, z, a) { return P('cyl', [x, y, z], [0.35, 9, 0.35], '#9fe8e0', { rot: [Math.sin(a) * 0.8, 0, -Math.cos(a) * 0.8], metal: 0.8, anim: 'swing', amp: 0.2, f: 5, ph: a, lod: false }); })) });

GW.type('builder', { label: 'Builder Phage', side: 'them', cat: 'creature', brain: 'builder', air: true, alt: 35, hp: 70, r: 6, speed: 34, bounty: 25, cost: 250, deathColor: '#ffdd44',
  model: M.cat([P('ico', [0, 12, 0], 5, '#ffcc55', { metal: 0.75, rough: 0.3 }), P('cyl', [0, 4, 0], [1.2, 9, 1.2], '#ffcc55', { metal: 0.75 }),
    P('sphere', [0, -2, 0], 3, '#66ff88', { e: 3, anim: 'pulse', amp: 0.2, f: 6 })],
    M.ring(4, 3.5, -1, function(x, y, z, a) { return P('cyl', [x, y, z], [0.4, 8, 0.4], '#ffcc55', { rot: [Math.sin(a) * 0.9, 0, -Math.cos(a) * 0.9], metal: 0.75, anim: 'swing', amp: 0.3, f: 4, ph: a }); })) });

// attacker purchase prices (bio-mass)
[['germ', 10], ['runner', 15], ['spitter', 30], ['splitter', 35], ['phage', 40], ['brute', 120]].forEach(function(c) { GW.type(c[0], { cost: c[1] }); });
