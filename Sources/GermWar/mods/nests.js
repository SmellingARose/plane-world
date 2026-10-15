// Enemy nests (bases). `spawns` lists what each nest breeds; spores are lobbed at defenders.
var P = M.part;

GW.type('colony', { label: 'Colony', side: 'them', cat: 'base', brain: 'nest', hp: 600, r: 22, bounty: 250, cost: 250,
  spawns: [{ type: 'germ', every: 3 }, { type: 'splitter', every: 14, minWave: 3 }], sporeEvery: 9, sporeMinWave: 2,
  model: M.cat([P('sphere', [0, 18, 0], 9, '#ccff44', { e: 3, anim: 'pulse', amp: 0.15, f: 3 })],
    [[-10, 8, 4, 14], [9, 10, -6, 12], [3, 6, 11, 11], [-6, 12, -10, 13], [12, 5, 9, 9], [-13, 5, -2, 10], [0, 14, 0, 15]].map(function(b, i) {
      return P('blob', [b[0], b[1], b[2]], b[3], '#2f9a3a', { rough: 0.25, anim: 'pulse', amp: 0.05, f: 2, ph: i }); }),
    M.ring(6, 22, 6, function(x, y, z, a) { return P('cyl', [x, y, z], [1.2, 30, 1.2], '#1f7a2a', { rot: [Math.sin(a) * 0.9, 0, -Math.cos(a) * 0.9], anim: 'swing', amp: 0.15, f: 1.5, ph: a, lod: false }); })) });

GW.type('hive', { label: 'Virus Hive', side: 'them', cat: 'base', brain: 'nest', hp: 850, r: 22, bounty: 350, cost: 350,
  spawns: [{ type: 'runner', every: 10, burst: 4 }, { type: 'phage', every: 14, minWave: 3 }],
  model: M.cat([P('sphere', [0, 56, 0], 6, '#ff2200', { e: 3, anim: 'pulse', amp: 0.2, f: 4 })],
    [[0, 0, 50], [9, 3, 34], [-8, 6, 42], [5, -10, 28], [-6, -8, 22], [12, -4, 18], [-12, 4, 26], [2, 12, 30]].map(function(c) {
      return P('cyl', [c[0], c[2] / 2, c[1]], [5, c[2], 5], '#5a1424', { rough: 0.6 }); }),
    [[0, 0, 50], [9, 3, 34], [-8, 6, 42], [5, -10, 28], [-6, -8, 22], [12, -4, 18], [-12, 4, 26], [2, 12, 30]].map(function(c) {
      return P('cyl', [c[0], c[2] + 0.3, c[1]], [3.5, 1, 3.5], '#ff5522', { e: 2.5, anim: 'flicker', f: 0.5 }); })) });

GW.type('spire', { label: 'Spore Spire', side: 'them', cat: 'base', brain: 'nest', hp: 700, r: 16, bounty: 400, cost: 400,
  spawns: [{ type: 'spitter', every: 9 }], sporeEvery: 3.5, sporeMinWave: 1,
  model: M.cat([0, 1, 2, 3, 4, 5, 6].map(function(i) {
      var h = 14 - i, y = [0, 13, 25, 36, 46, 55, 63][i];
      return P('cone', [0, y + h * 0.8, 0], [15 - i * 2, h * 1.6, 15 - i * 2], '#6a2a8a', { rot: [0, i * 0.5, 0], rough: 0.4 }); }),
    [P('sphere', [0, 74, 0], 5, '#dd66ff', { e: 3.5, anim: 'pulse', amp: 0.3, f: 5 })]) });

GW.type('factory', { label: 'Germ Factory', side: 'them', cat: 'base', brain: 'nest', hp: 500, r: 18, bounty: 200, cost: 150,
  spawns: [{ type: 'germ', every: 2.5 }],
  model: M.cat([P('cyl', [0, 5, 0], [18, 10, 18], '#c0607a', { rough: 0.5 }), P('sphere', [0, 9, 0], [15, 10, 15], '#c0607a', { rough: 0.5 }),
      P('cyl', [0, 26, 0], [3, 14, 3], '#7a3040')],
    M.ring(3, 15, 10, function(x, y, z) { return P('cyl', [x, y, z], [4.5, 16, 4.5], '#ccffee', { rough: 0.05, metal: 0.2 }); }),
    M.ring(3, 15, 9, function(x, y, z, a, i) { return P('cyl', [x, y, z], [3.8, 9, 3.8], '#66ff66', { e: 2.5, anim: 'pulse', amp: 0.3, f: 1.5, ph: i * 2 }); })) });

GW.type('hatchery', { label: 'Phage Hatchery', side: 'them', cat: 'base', brain: 'nest', hp: 900, r: 20, bounty: 450, cost: 600, builderEvery: 30,
  model: M.cat([P('cyl', [0, 7, 0], [18, 14, 18], '#8a6a2a', { rough: 0.6 }),
      P('sphere', [0, 34, 0], 9, '#ffe9a0', { rough: 0.1 }), P('ico', [0, 34, 0], 3.5, '#ffcc55', { e: 2.5, anim: 'spin', f: 2 })],
    M.ring(7, 11, 30, function(x, y, z, a) { return P('cyl', [x, y, z], [1.8, 46, 1.8], '#8a6a2a', { rot: [Math.sin(a) * 0.25, 0, -Math.cos(a) * 0.25] }); }),
    M.ring(5, 19, 16, function(x, y, z, a, i) { return P('sphere', [x, y, z], [3.4, 4.8, 3.4], '#f0d890', { anim: 'pulse', amp: 0.1, f: 3, ph: i }); })) });

GW.type('cocoon', { label: 'Nest (growing)', side: 'them', cat: 'base', brain: 'cocoon', hp: 250, r: 14, bounty: 60, growTime: 14,
  model: M.cat([P('sphere', [0, 10, 0], [12, 14, 12], '#d6ffd0', { rough: 0.1 }), P('ico', [0, 10, 0], 4, '#66ff88', { e: 3, anim: 'spin', f: 2 })],
    M.ring(5, 10, 6, function(x, y, z, a) { return P('cyl', [x, y, z], [0.8, 20, 0.8], '#88aa77', { rot: [-Math.sin(a) * 0.5, 0, Math.cos(a) * 0.5] }); })) });

GW.type('mother', { label: 'Mother Cell (boss)', side: 'them', cat: 'base', brain: 'nest', hp: 3500, r: 40, speed: 5, dps: 80, bounty: 1500, cost: 1200,
  spawns: [{ type: 'brute', every: 12 }, { type: 'splitter', every: 7, burst: 2 }], sporeEvery: 8, sporeMinWave: 1,
  model: M.cat([P('blob', [0, 30, 0], 38, '#d0307a', { rough: 0.15, anim: 'pulse', amp: 0.07, f: 1.3 }),
      P('blob', [0, 32, 0], 14, '#ff66bb', { e: 2.5, anim: 'spin', f: 0.4 })],
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map(function(i) { return P('sphere', [Math.cos(i) * 28, 30, Math.sin(i) * 28], 3, i % 2 ? '#ffcc66' : '#66ffee', { e: 2, anim: 'orbit', f: 0.6, amp: 16, ph: i }); })) });
