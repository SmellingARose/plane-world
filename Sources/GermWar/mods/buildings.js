// Defender buildings and units. Save this file while playing: every existing building switches instantly.
var P = M.part;

GW.type('hq', { label: 'HQ', side: 'us', hp: 2000, r: 24, speed: 8, brain: 'none',
  model: M.cat([
    P('cyl', [0, 4, 0], [28, 8, 28], '#56657a', { metal: 0.6 }),
    P('cyl', [0, 11, 0], [22, 6, 22], '#7a8aa0', { metal: 0.6 }),
    P('sphere', [0, 14, 0], [15, 11, 15], '#9fd4ff', { rough: 0.05, metal: 0.3 }),
    P('ico', [0, 22, 0], 6, '#44ddff', { e: 3, anim: 'spin', f: 1 }),
    P('torus', [0, 16, 0], [19, 6, 19], '#44ddff', { e: 1.5, anim: 'spin', f: 0.6 }),
    P('cyl', [12, 24, 0], [0.8, 26, 0.8], '#cccccc', { metal: 0.9 }),
    P('sphere', [12, 37, 0], 2, '#ff3344', { e: 5, anim: 'flicker', f: 1 }),
  ], M.ring(6, 27, 6, function(x, y, z) { return P('box', [x, y, z], [4, 3, 4], '#44ffcc', { e: 1.2 }); })) });

GW.type('extractor', { label: 'Extractor', cost: 150, hp: 260, r: 12, income: 4, speed: 15, maxLvl: 3, order: 1, desc: '+$4/s income',
  model: M.cat([
    P('cyl', [0, 2.5, 0], [12, 5, 12], '#6b5a3a'),
    P('cyl', [0, 12, 0], [3, 16, 3], '#bbbbbb', { metal: 0.9, anim: 'bob', amp: 3, f: 6 }),
    P('ico', [0, 26, 0], 5, '#ffcc33', { e: 2.5, anim: 'spin', f: 2 }),
  ], M.ring(3, 7, 12, function(x, y, z) { return P('box', [x, y, z], [2, 20, 2], '#8a7a5a', { metal: 0.5 }); })) });

GW.type('wall', { label: 'Wall', cost: 30, hp: 900, r: 9, armor: 0.3, order: 2, desc: 'Cheap germ bait', maxLvl: 3,
  model: [P('cyl', [0, 8, 0], [9, 16, 9], '#55606e', { metal: 0.4 }), P('cyl', [0, 12, 0], [9.3, 1.5, 9.3], '#33ffaa', { e: 1.5 }), P('cyl', [0, 17, 0], [7, 3, 7], '#707c8a')] });

GW.type('radar', { label: 'Radar', cost: 120, hp: 200, r: 9, brain: 'radar', radius: 900, speed: 14, maxLvl: 3, upgRange: 0.3, order: 3, desc: 'Pushes nests away',
  model: [P('cyl', [0, 2, 0], [8, 4, 8], '#3e4a58'), P('cyl', [0, 13, 0], [1.6, 20, 1.6], '#a0aab8', { metal: 0.8 }),
          P('sphere', [0, 25, 0], [9, 2.5, 9], '#dfe6ee', { metal: 0.6, rot: [0.5, 0, 0], anim: 'spin', f: 1.2 }),
          P('sphere', [0, 28, 0], 1.2, '#55ffcc', { e: 4, anim: 'flicker', f: 1 })] });

GW.type('turret', { label: 'Gatling Turret', cost: 100, hp: 320, r: 10, brain: 'gun', range: 140, dmg: 18, rate: 0.25, speed: 18, canAttack: true,
  maxLvl: 3, upgDmg: 0.45, upgRange: 0.12, baseMult: 0.4, order: 4, desc: 'Fast, hits air',
  model: [P('box', [0, 3, 0], [16, 6, 16], '#4d5a68', { metal: 0.5 }),
          P('box', [0, 10, 0], [10, 7, 10], '#8193a8', { anim: 'aim', metal: 0.6 }),
          P('box', [0, 12, 0], [10.2, 1, 10.2], '#ffcc44', { anim: 'aim', e: 1.5 }),
          P('cyl', [1.4, 10, 10], [0.8, 12, 0.8], '#2a2a2a', { anim: 'aim', rot: [Math.PI / 2, 0, 0], metal: 0.9 }),
          P('cyl', [-1.4, 10, 10], [0.8, 12, 0.8], '#2a2a2a', { anim: 'aim', rot: [Math.PI / 2, 0, 0], metal: 0.9 }),
          P('cyl', [0, 12, 10], [0.8, 12, 0.8], '#2a2a2a', { anim: 'aim', rot: [Math.PI / 2, 0, 0], metal: 0.9 })] });

GW.type('tesla', { label: 'Tesla Coil', cost: 225, hp: 300, r: 10, brain: 'chain', range: 115, dmg: 40, rate: 1.1, chain: 4, speed: 14, canAttack: true,
  maxLvl: 3, upgDmg: 0.4, upgRange: 0.12, order: 5, desc: 'Chain lightning',
  model: M.cat([P('cyl', [0, 2.5, 0], [10, 5, 10], '#3a4250'), P('cyl', [0, 16, 0], [3, 26, 3], '#9aa5b5', { metal: 0.8 }),
          P('sphere', [0, 31, 0], 4.5, '#88ccff', { e: 3.5, anim: 'pulse', amp: 0.15, f: 14 })],
    [0, 1, 2, 3].map(function(i) { return P('torus', [0, 9 + i * 5, 0], [6 - i, 6, 6 - i], '#c58a3a', { metal: 0.95, rough: 0.3 }); })) });

GW.type('laser', { label: 'Laser Tower', cost: 275, hp: 280, r: 10, brain: 'beam', range: 230, dmg: 75, speed: 12, canAttack: true,
  maxLvl: 3, upgDmg: 0.5, upgRange: 0.15, baseMult: 0.8, order: 6, desc: 'Beam melts big things',
  model: [P('cyl', [0, 2, 0], [10, 4, 10], '#404858'), P('cyl', [0, 15, 0], [5.5, 22, 5.5], '#d0d6e0', { metal: 0.7 }),
          P('box', [0, 28, 0], [7, 6, 10], '#606a7a', { anim: 'aim', metal: 0.6 }),
          P('sphere', [0, 28, 5.5], 2, '#ff2244', { anim: 'aim', e: 5 })] });

GW.type('battery', { label: 'Missile Battery', cost: 200, hp: 260, r: 12, brain: 'aa', range: 750, rate: 0.9, dmg: 70, speed: 15,
  maxLvl: 3, upgRate: -0.25, upgRange: 0.15, order: 7, desc: 'Shoots spores & flyers',
  model: [P('box', [0, 2.5, 0], [18, 5, 18], '#4a5560'),
          P('cyl', [-2.5, 9, 0], [2, 14, 2], '#ccd4dd', { rot: [0.9, 0, 0], metal: 0.7 }), P('cyl', [2.5, 9, 0], [2, 14, 2], '#ccd4dd', { rot: [0.9, 0, 0], metal: 0.7 }),
          P('cyl', [-2.5, 14, 0], [2, 14, 2], '#ccd4dd', { rot: [0.9, 0, 0], metal: 0.7 }), P('cyl', [2.5, 14, 0], [2, 14, 2], '#ccd4dd', { rot: [0.9, 0, 0], metal: 0.7 }),
          P('box', [0, 18, -7], [10, 6, 1], '#66ccff', { e: 1.2, anim: 'spin', f: 2 })] });

GW.type('shield', { label: 'Shield Dome', cost: 250, hp: 300, r: 11, brain: 'shield', radius: 140, speed: 10, maxLvl: 3, upgRange: 0.25, order: 8, desc: 'Blocks spores',
  model: [P('cyl', [0, 3, 0], [11, 6, 11], '#3c4a5c'), P('ico', [0, 13, 0], 5, '#66aaff', { e: 3, anim: 'spin', f: 1 })] });

GW.type('repair', { label: 'Repair Bay', cost: 200, hp: 260, r: 11, brain: 'heal', radius: 120, dmg: 14, speed: 12, maxLvl: 3, upgDmg: 0.6, upgRange: 0.2, order: 9, desc: 'Heals nearby',
  model: [P('cyl', [0, 2, 0], [11, 4, 11], '#d8dde4'), P('box', [0, 6, 0], [14, 3, 4], '#44ff88', { e: 2 }), P('box', [0, 6, 0], [4, 3, 14], '#44ff88', { e: 2 }),
          P('cyl', [0, 16, 0], [1, 12, 1], '#999999'), P('sphere', [14, 21, 0], 1.6, '#66ffaa', { e: 4, anim: 'orbit', f: 1.5 })] });

GW.type('silo', { label: 'Rocket Silo', cost: 300, hp: 300, r: 13, brain: 'lob', prefersBases: true, range: 550, dmg: 220, rate: 5, speed: 12, canAttack: true,
  maxLvl: 6, upgRange: 0.27, upgDmg: 0.15, order: 10, desc: 'Strikes enemy nests',
  model: [P('cyl', [0, 3, 0], [13, 6, 13], '#5d5048'), P('cyl', [0, 15, 0], [6, 22, 6], '#8a8f96', { metal: 0.7 }),
          P('cyl', [0, 9, 0], [6.2, 1, 6.2], '#ff6633', { e: 1.5 }), P('cyl', [0, 15, 0], [6.2, 1, 6.2], '#ff6633', { e: 1.5 }), P('cyl', [0, 21, 0], [6.2, 1, 6.2], '#ff6633', { e: 1.5 }),
          P('cone', [0, 30.5, 0], [6, 9, 6], '#ff6633', { e: 1.2 })] });

GW.type('tank', { label: 'Tank', cat: 'unit', cost: 250, hp: 450, r: 9, brain: 'gun', range: 125, dmg: 40, rate: 0.55, speed: 55, canAttack: true,
  maxLvl: 3, upgDmg: 0.4, baseMult: 1.5, order: 11, desc: 'Mobile assault',
  model: [P('box', [0, 4, 0], [14, 6, 20], '#55663a', { metal: 0.4 }), P('box', [-8, 2.5, 0], [4, 5, 22], '#222222'), P('box', [8, 2.5, 0], [4, 5, 22], '#222222'),
          P('sphere', [-4.5, 5, 10.2], 0.9, '#ffffcc', { e: 5 }), P('sphere', [4.5, 5, 10.2], 0.9, '#ffffcc', { e: 5 }),
          P('box', [0, 9, 0], [9, 4, 10], '#6d7f48', { anim: 'aim' }), P('cyl', [0, 9, 10], [1, 14, 1], '#2a2a2a', { anim: 'aim', rot: [Math.PI / 2, 0, 0] })] });

GW.type('artillery', { label: 'Artillery', cat: 'unit', cost: 350, hp: 300, r: 10, brain: 'lob', groundOnly: true, range: 340, dmg: 90, rate: 2.6, speed: 35, canAttack: true,
  maxLvl: 3, upgDmg: 0.4, upgRange: 0.15, baseMult: 1.2, order: 12, desc: 'Long-range splash',
  model: M.cat([P('box', [0, 5, 0], [12, 6, 22], '#5a5a40'), P('box', [0, 9, -3], [8, 4, 8], '#6a6a4a', { anim: 'aim' }),
          P('cyl', [0, 15, 5], [1.5, 22, 1.5], '#2a2a2a', { anim: 'aim', rot: [0.97, 0, 0] })],
    [-7, 0, 7].map(function(z) { return P('cyl', [-7, 2.6, z], [2.6, 2, 2.6], '#1a1a1a', { rot: [0, 0, Math.PI / 2] }); }),
    [-7, 0, 7].map(function(z) { return P('cyl', [7, 2.6, z], [2.6, 2, 2.6], '#1a1a1a', { rot: [0, 0, Math.PI / 2] }); })) });
