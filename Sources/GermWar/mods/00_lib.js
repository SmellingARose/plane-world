// Shared helpers for model building. Loaded first (files load in name order).
// A model is a list of parts: { p:'sphere'|'box'|'cyl'|'cone'|'ico'|'torus'|'blob', at:[x,y,z], s:[sx,sy,sz],
//   rot:[x,y,z], c:'#rrggbb', e:emissive, rough, metal, anim:'bob'|'spin'|'pulse'|'wiggle'|'swing'|'orbit'|'gait'|'aim'|'flicker',
//   amp, f (frequency), ph (phase), jitter (per-entity colour variation), lod:false (hide when far) }
var M = {
  part: function(p, at, s, c, o) { var r = { p: p, at: at, s: s, c: c }; for (var k in (o || {})) r[k] = o[k]; return r; },
  // ring of n parts around the y axis
  ring: function(n, radius, y, make) { var out = []; for (var i = 0; i < n; i++) { var a = i / n * Math.PI * 2; out.push(make(Math.cos(a) * radius, y, Math.sin(a) * radius, a, i)); } return out; },
  // jointed legs: upper bar out to the side, lower spike down to the ground, animated by gait
  legs: function(n, spread, hipY, upper, lower, c) {
    var out = [];
    for (var i = 0; i < n; i++) {
      var side = i < n / 2 ? -1 : 1, k = i % (n / 2), z = (k - (n / 2 - 1) / 2) * spread * 1.3, ph = i * 1.7 + (side > 0 ? Math.PI : 0);
      out.push(M.part('cyl', [side * (spread + upper / 2), hipY, z], [0.35, upper, 0.35], c, { rot: [0, 0, Math.PI / 2], anim: 'gait', amp: 0.4, f: 16, ph: ph, lod: false }));
      out.push(M.part('cone', [side * (spread + upper), hipY - lower / 2, z], [0.4, lower, 0.4], c, { rot: [Math.PI, 0, 0], anim: 'gait', amp: 0.4, f: 16, ph: ph, lod: false }));
    }
    return out;
  },
  // tentacle: a chain of shrinking spheres that sways
  tentacle: function(base, dir, n, r0, c, ph) {
    var out = [];
    for (var i = 0; i < n; i++) {
      var k = i / n;
      out.push(M.part('sphere', [base[0] + dir[0] * i * r0 * 1.4, base[1] + dir[1] * i * r0 * 1.4, base[2] + dir[2] * i * r0 * 1.4], r0 * (1 - k * 0.7), c,
        { anim: 'wiggle', amp: 1.5 * k * r0, f: 3, ph: ph + i * 0.6, lod: i < 2 }));
    }
    return out;
  },
  cat: function() { return [].concat.apply([], arguments); },
};
