// Plane World script prelude (C++ port; same JS on JavaScriptCore and QuickJS). Port of the Swift
// JSPrelude.source. Evaluated as its own script ("prelude.js") before the user source ("user.js", line 1), so
// error line numbers are already relative to the user source. Differences from the Swift prelude are only in
// the native boundary: names, results and populations cross it as JSON text (engine-neutral), never as objects.
"use strict";
// ---- math helpers --------------------------------------------------------------------------------
function clamp(x, a, b) { return x < a ? a : (x > b ? b : x); }
function lerp(a, b, t) { return a + (b - a) * t; }
function sign(x) { return x > 0 ? 1 : (x < 0 ? -1 : 0); }
function deg(r) { return r * 57.29577951308232; }
function rad(d) { return d * 0.017453292519943295; }
function pid(kp, ki, kd, iLimit) {
  if (iLimit === undefined) iLimit = 1;
  var integ = 0, prev = NaN;
  return {
    kp: kp, ki: ki, kd: kd,
    update: function (err, dt) {
      integ += err * dt;
      if (this.ki > 0) { var lim = iLimit / this.ki; integ = integ < -lim ? -lim : (integ > lim ? lim : integ); }
      var d = (prev === prev && dt > 0) ? (err - prev) / dt : 0;
      prev = err;
      return this.kp * err + this.ki * integ + this.kd * d;
    },
    reset: function () { integ = 0; prev = NaN; }
  };
}
var vec = {
  len: function (x, y, z) { if (typeof x === "object") { z = x[2]; y = x[1]; x = x[0]; } return Math.sqrt(x * x + y * y + (z || 0) * (z || 0)); },
  norm: function (v) { var l = vec.len(v); return l > 0 ? [v[0] / l, v[1] / l, (v[2] || 0) / l] : [0, 0, 0]; },
  dot: function (a, b) { return a[0] * b[0] + a[1] * b[1] + (a[2] || 0) * (b[2] || 0); },
  cross: function (a, b) { return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]; },
  add: function (a, b) { return [a[0] + b[0], a[1] + b[1], (a[2] || 0) + (b[2] || 0)]; },
  sub: function (a, b) { return [a[0] - b[0], a[1] - b[1], (a[2] || 0) - (b[2] || 0)]; },
  scale: function (a, s) { return [a[0] * s, a[1] * s, (a[2] || 0) * s]; }
};
// ---- deterministic RNG (sfc32; seeded from the episode seed or the algorithm's EvoRNG) ---------------
function __Rng() { this.a = 1; this.b = 2; this.c = 3; this.d = 4; }
__Rng.prototype.seed = function (lo, hi) {
  this.a = lo >>> 0; this.b = hi >>> 0; this.c = (lo ^ 0x9E3779B9) >>> 0; this.d = (hi ^ 0x85EBCA6B) >>> 0;
  if ((this.a | this.b | this.c | this.d) === 0) this.d = 1;
  for (var k = 0; k < 15; k++) this.next32();
  return this;
};
__Rng.prototype.next32 = function () {
  var a = this.a, b = this.b, c = this.c, d = this.d;
  var t = (((a + b) | 0) + d) | 0;
  d = (d + 1) | 0; a = b ^ (b >>> 9); b = (c + (c << 3)) | 0; c = (c << 21) | (c >>> 11); c = (c + t) | 0;
  this.a = a; this.b = b; this.c = c; this.d = d;
  return t >>> 0;
};
__Rng.prototype.random = function () { return ((this.next32() >>> 5) * 67108864 + (this.next32() >>> 6)) / 9007199254740992; };
__Rng.prototype.uniform = function (a, b) { return a + (b - a) * this.random(); };
__Rng.prototype.gaussian = function () {
  var u1 = this.random(); if (u1 < 1e-300) u1 = 1e-300;
  return Math.sqrt(-2 * Math.log(u1)) * Math.cos(6.283185307179586 * this.random());
};
__Rng.prototype.int = function (n) { return Math.floor(this.random() * n); };
var __rng = new __Rng(), __cur = __rng;
Math.random = function () { return __cur.random(); };
Date.now = function () { return __S === null ? 0 : Math.round(__S[0] * 1000); };
// ---- neural nets (forward pass is native) --------------------------------------------------------
var __nets = Object.create(null);
var nn = {
  tanh: Math.tanh,
  relu: function (x) { return x > 0 ? x : 0; },
  sigmoid: function (x) { return 1 / (1 + Math.exp(-x)); },
  softmax: function (a) {
    var m = -Infinity, i, s = 0, o = new Float64Array(a.length);
    for (i = 0; i < a.length; i++) if (a[i] > m) m = a[i];
    for (i = 0; i < a.length; i++) { o[i] = Math.exp(a[i] - m); s += o[i]; }
    for (i = 0; i < a.length; i++) o[i] /= s;
    return o;
  },
  paramCount: function (sizes) { var n = 0; for (var l = 0; l + 1 < sizes.length; l++) n += sizes[l + 1] * sizes[l] + sizes[l + 1]; return n; },
  // A reusable network: net.forward(weights, x, offset = 0) → net.output (Float64Array, overwritten by the next call).
  create: function (sizes, act, outAct) {
    act = act || "tanh"; outAct = outAct || "tanh";
    var h = __native.nnCreate(JSON.stringify(Array.from(sizes, Number)), String(act), String(outAct));
    var net = {
      sizes: Array.from(sizes, Number), paramCount: nn.paramCount(sizes),
      input: new Float64Array(sizes[0]), output: new Float64Array(sizes[sizes.length - 1]),
      _w: null,
      forward: function (weights, x, offset) {
        if (!(x instanceof Float64Array)) { for (var i = 0; i < this.input.length; i++) this.input[i] = +x[i] || 0; x = this.input; }
        if (!(weights instanceof Float64Array)) {
          if (this._w === null || this._w.length !== weights.length) this._w = new Float64Array(weights.length);
          for (var j = 0; j < weights.length; j++) this._w[j] = weights[j];
          weights = this._w;
        }
        __native.nnForward(h, weights, offset || 0, x, this.output);
        return this.output;
      }
    };
    return net;
  },
  // nn.mlp(sizes, weights, x, act, outAct): weights use the native MLP layout (docs §3); result reused per sizes.
  mlp: function (sizes, weights, x, act, outAct) {
    var key = sizes.join(",") + "|" + (act || "tanh") + "|" + (outAct || "tanh");
    var n = __nets[key];
    if (n === undefined) { n = nn.create(sizes, act, outAct); __nets[key] = n; }
    return n.forward(weights, x, 0);
  },
  dense: function (W, b, x, act) {
    var nOut = b.length, nIn = x.length, o = new Float64Array(nOut);
    var f = act === "relu" ? nn.relu : act === "sigmoid" ? nn.sigmoid : act === "linear" ? null : Math.tanh;
    var flat = typeof W[0] === "number";
    for (var r = 0; r < nOut; r++) {
      var acc = b[r], row = flat ? null : W[r];
      for (var i = 0; i < nIn; i++) acc += (flat ? W[r * nIn + i] : row[i]) * x[i];
      o[r] = f === null ? acc : f(acc);
    }
    return o;
  }
};
function log() { if (__logOn) __native.log(Array.prototype.map.call(arguments, String).join(" ")); }
var __logOn = true;
// ---- hook plumbing (called from Swift) ------------------------------------------------------------
var __S = null, __IN = null, __OUT = null, __T = null, __SUM = null, __G = null;
var __ctx = null, __H = null, __termIndex = null, __termNames = [], __geneIndex = Object.create(null);
var __REASONS = ["", "time", "crash", "nan", "bounds", "script"];
function __fn(name) { try { var f = globalThis[name]; if (typeof f === "function") return f; } catch (e) {}
  try { var g = (0, eval)("typeof " + name + " === 'function' ? " + name + " : null"); return g; } catch (e) { return null; } }
function __collect() {
  __H = { genome: __fn("genome"), terms: __fn("terms"), decode: __fn("decode"), init: __fn("init"), control: __fn("control"),
          reward: __fn("reward"), terminate: __fn("terminate"), fitness: __fn("fitness"), descriptor: __fn("descriptor"),
          select: __fn("select"), crossover: __fn("crossover"), mutate: __fn("mutate"), ask: __fn("ask"), tell: __fn("tell") };
  var names = []; for (var k in __H) if (__H[k] !== null) names.push(k);
  return names.join(",");
}
function __strictProxy(kind, list) {
  return new Proxy({}, {
    get: function (t, k) { if (typeof k !== "string" || k === "toJSON" || k === "then") return undefined;
      if (kind === "input") return 0;
      throw new Error("unknown " + kind + " '" + k + "' (known: " + list.join(", ") + ")"); },
    set: function (t, k) { throw new Error("unknown " + kind + " '" + String(k) + "' (known: " + list.join(", ") + ")"); }
  });
}
function __accessors(obj, names, arr, writable, asBool) {
  names.forEach(function (n, i) {
    var d = { enumerable: true, configurable: false };
    d.get = asBool ? function () { return arr[i] !== 0; } : function () { return arr[i]; };
    if (writable) d.set = function (v) { arr[i] = +v; };
    Object.defineProperty(obj, n, d);
  });
  return obj;
}
function __bind(IN, OUT, T, SUM, inJSON, outJSON, termJSON, stateJSON, craftJSON) {
  var inNames = JSON.parse(inJSON), outNames = JSON.parse(outJSON), termNames = JSON.parse(termJSON), stateNames = JSON.parse(stateJSON);
  var S = __S; __IN = IN; __OUT = OUT; __T = T; __SUM = SUM; __termNames = termNames;
  __termIndex = Object.create(null); termNames.forEach(function (n, i) { __termIndex[n] = i; });
  var c = {};
  c.inputs = IN; c.outputs = OUT; c.inputNames = inNames; c.outputNames = outNames; c.termNames = termNames;
  c.in = __accessors(Object.create(__strictProxy("input", inNames)), inNames, IN, false, false);
  c.out = __accessors(Object.create(__strictProxy("output", outNames)), outNames, OUT, true, false);
  c.reward = __accessors(Object.create(__strictProxy("reward term", termNames)), termNames, T, true, false);
  c.sum = __accessors({}, termNames, SUM, false, false);
  var st = {};
  stateNames.forEach(function (n, k) {
    var j = 16 + k, b = (n === "crashed" || n === "contact");
    Object.defineProperty(st, n, { enumerable: true, get: b ? function () { return S[j] !== 0; } : function () { return S[j]; } });
  });
  c.state = st;
  c.info = {};
  [["generation", 3], ["candidate", 4], ["episode", 5], ["duration", 8], ["world", 12], ["worldCount", 13]].forEach(function (p) {
    Object.defineProperty(c.info, p[0], { enumerable: true, get: function () { return S[p[1]]; } });
  });
  Object.defineProperty(c.info, "seed", { enumerable: true, get: function () { return S[7] * 4294967296 + S[6]; } });
  Object.defineProperty(c, "t", { enumerable: true, get: function () { return S[0]; } });
  Object.defineProperty(c, "dt", { enumerable: true, get: function () { return S[1]; } });
  Object.defineProperty(c, "tick", { enumerable: true, get: function () { return S[2]; } });
  Object.defineProperty(c, "doneReason", { enumerable: true, get: function () { return __REASONS[S[9]] || ""; } });
  c.craft = JSON.parse(craftJSON || "{}");   // { mass, rotors: [{ output, x, y, z, spin, thrust }], outputs: [{ name, kind }] }
  c.memory = {};
  c.rng = __rng;
  c.genome = __genome;
  __ctx = c;
}
var __genome = { values: new Float64Array(0), get: function (name) {
  var i = __geneIndex[name];
  if (i === undefined) throw new Error("unknown gene '" + name + "' (gene names are known after genome() ran or decode() was called)");
  return this.values[i]; } };
Object.defineProperty(__genome, "id", { enumerable: true, get: function () { return __S[10]; } });
function __bindScalars(S) { __S = S; }
function __bindGenome(G, namesJSON) {
  __G = G; __genome.values = G;
  var names = namesJSON === "" ? null : JSON.parse(namesJSON);
  if (names !== null) { __geneIndex = Object.create(null); names.forEach(function (n, i) { __geneIndex[n] = i; }); }
}
function __addReward(r) {
  if (typeof r === "number") { if (__T.length === 0) throw new Error("reward() returned a number but no reward terms are declared"); __T[0] += r; return; }
  if (typeof r !== "object") throw new Error("reward() must return a number or an object of term deltas");
  for (var k in r) {
    var i = __termIndex[k];
    if (i === undefined) throw new Error("unknown reward term '" + k + "' — declare it in terms() (known: " + __termNames.join(", ") + ")");
    __T[i] += +r[k];
  }
}
function __begin() {
  var c = __ctx; c.memory = {};
  __rng.seed(__S[6], __S[7]); __cur = __rng; c.rng = __rng;
  if (__H.init !== null) { __S[11] = 1; __H.init(c); }
  __S[11] = 0;
}
function __tick() {
  var H = __H, c = __ctx, S = __S, stop = 0;
  if (H.control !== null) { S[11] = 2; H.control(c); }
  if (H.reward !== null) { S[11] = 3; var r = H.reward(c); if (r !== undefined && r !== null) __addReward(r); }
  if (H.terminate !== null) { S[11] = 4; stop = H.terminate(c) ? 1 : 0; }
  S[11] = 0;
  return stop;
}
function __nf(k, v) { return typeof v === "number" && !isFinite(v) ? (v !== v ? "NaN" : (v > 0 ? "Infinity" : "-Infinity")) : v; }
function __json(v) { return JSON.stringify(v === undefined ? null : v, __nf); }
function __numArray(d, what) {
  var out = []; for (var i = 0; i < d.length; i++) { var v = +d[i]; if (v !== v) throw new Error(what + "[" + i + "] is not a number"); out.push(v); }
  return out;
}
function __end() {
  var c = __ctx, res = { fitness: null, terms: null, descriptor: null };
  if (__H.fitness !== null) {
    __S[11] = 5; var f = __H.fitness(c);
    if (typeof f === "number") res.fitness = f;
    else if (f !== null && typeof f === "object") {
      if (f.fitness !== undefined && f.fitness !== null) res.fitness = +f.fitness;
      if (f.terms) { res.terms = {}; for (var k in f.terms) res.terms[k] = +f.terms[k]; }
      if (f.descriptor) res.descriptor = __numArray(f.descriptor, "descriptor");
    } else if (f !== undefined && f !== null) throw new Error("fitness() must return a number or { fitness, terms, descriptor }");
  }
  if (res.descriptor === null && __H.descriptor !== null) {
    __S[11] = 6; var d = __H.descriptor(c);
    if (d !== undefined && d !== null) res.descriptor = __numArray(d, "descriptor");
  }
  __S[11] = 0;
  return __json(res);
}
function __normLayout(L) {
  if (L === undefined || L === null) throw new Error("genome() must return a layout { genes: [...] }");
  var genes = Array.isArray(L) ? L : L.genes;
  if (!Array.isArray(genes)) throw new Error("genome() result needs a 'genes' array");
  var out = { genes: genes.map(function (g, i) {
    if (typeof g !== "object" || g === null || typeof g.name !== "string") throw new Error("gene " + i + " needs a string 'name'");
    var o = { name: g.name, kind: g.kind || "real", min: g.min === undefined ? -1 : +g.min, max: g.max === undefined ? 1 : +g.max, group: g.group || "script" };
    if (o.kind !== "real" && o.kind !== "int" && o.kind !== "bool") throw new Error("gene '" + g.name + "': kind must be real, int or bool");
    if (o.kind === "bool" && g.min === undefined) { o.min = 0; o.max = 1; }
    if (!(o.max >= o.min)) throw new Error("gene '" + g.name + "': max < min");
    if (g.initial !== undefined && g.initial !== null) o.initial = +g.initial;
    if (g.sigma !== undefined && g.sigma !== null) o.sigma = +g.sigma;
    return o; }) };
  if (!Array.isArray(L) && L.neat) out.neat = L.neat;
  return out;
}
function __callGenome(json) { __S[11] = 8; var base = JSON.parse(json); var r = __H.genome(base); if (r === undefined) r = base; __S[11] = 0; return JSON.stringify(__normLayout(r)); }
function __callTerms() {
  __S[11] = 9; var t = __H.terms(); __S[11] = 0;
  if (!Array.isArray(t)) throw new Error("terms() must return an array of names");
  return JSON.stringify(t.map(String));
}
function __callDecode(craftJSON) {
  __S[11] = 7; var craft = JSON.parse(craftJSON); var r = __H.decode(__genome, craft); __S[11] = 0;
  return JSON.stringify(r === undefined || r === null ? craft : r);
}
function __unnf(k, v) { return v === "NaN" ? NaN : v === "Infinity" ? Infinity : v === "-Infinity" ? -Infinity : v; }
function __popFromJSON(json) {
  return JSON.parse(json, __unnf).map(function (p) { p.values = Float64Array.from(p.values); return p; });
}
function __numOrNull(r, what) {
  if (r === undefined || r === null) return null;
  return __numArray(r, what);
}
function __callSelect(popJSON, count, lo, hi) {
  var rng = new __Rng().seed(lo, hi), prev = __cur; __cur = rng;
  try { __S[11] = 10; var r = __H.select(__popFromJSON(popJSON), count, rng); return __json(__numOrNull(r, "select()")); } finally { __cur = prev; __S[11] = 0; }
}
function __callCrossover(aJSON, bJSON, layoutJSON, lo, hi) {
  var rng = new __Rng().seed(lo, hi), prev = __cur; __cur = rng;
  try { __S[11] = 11; var a = JSON.parse(aJSON, __unnf), b = JSON.parse(bJSON, __unnf); a.values = Float64Array.from(a.values); b.values = Float64Array.from(b.values);
    return __json(__numOrNull(__H.crossover(a, b, JSON.parse(layoutJSON), rng), "crossover()")); } finally { __cur = prev; __S[11] = 0; }
}
function __callMutate(gJSON, layoutJSON, rate, lo, hi) {
  var rng = new __Rng().seed(lo, hi), prev = __cur; __cur = rng;
  try { __S[11] = 12; var g = JSON.parse(gJSON, __unnf); g.values = Float64Array.from(g.values);
    return __json(__numOrNull(__H.mutate(g, JSON.parse(layoutJSON), rate, rng), "mutate()")); } finally { __cur = prev; __S[11] = 0; }
}
function __callAsk(stateJSON, layoutJSON, infoJSON, lo, hi) {
  var rng = new __Rng().seed(lo, hi), prev = __cur; __cur = rng;
  try {
    __S[11] = 13; var state = JSON.parse(stateJSON);
    var r = __H.ask(state, JSON.parse(layoutJSON), rng, JSON.parse(infoJSON));
    if (!Array.isArray(r) || r.length === 0) throw new Error("ask() must return a non-empty array of gene arrays");
    var vals = r.map(function (x, i) { return __numArray(Array.isArray(x) || ArrayBuffer.isView(x) ? x : x.values, "ask()[" + i + "]"); });
    return __json({ state: JSON.stringify(state), values: vals });
  } finally { __cur = prev; __S[11] = 0; }
}
function __callTell(stateJSON, popJSON, lo, hi) {
  var rng = new __Rng().seed(lo, hi), prev = __cur; __cur = rng;
  try { __S[11] = 14; var state = JSON.parse(stateJSON); __H.tell(state, __popFromJSON(popJSON), rng); return JSON.stringify(state); }
  finally { __cur = prev; __S[11] = 0; }
}
