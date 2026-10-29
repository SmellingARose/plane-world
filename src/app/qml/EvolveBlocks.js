.pragma library
// EVOLVE goal blocks: the reward script as a small block program that compiles to the experiment's JavaScript.
// A program is plain JSON (saved in the experiment as scripts.blocks next to the generated scripts.source):
//   { v: 1,
//     target: { ahead: 800, side: 0 } | null,      // a point relative to the start (+X ahead, +Z side), metres
//     terms:   [ { name, kind, ...fields } ],       // scored every control tick (see termKinds)
//     stops:   [ { kind, ...fields } ],             // end the flight early (see stopKinds)
//     bonuses: [ { name, when, points, timeBonus } ],  // one-off points when the flight ends (when = a condition id)
//     code: "" }                                     // extra JavaScript kept verbatim (helpers, control(), descriptor())
// The goal presets below are block programs; "hold" compiles to the Neural-controller preset script verbatim so the
// native runtime still fast-paths the quick start. Used by EvolvePanel (Set up › Goal, Goal › Blocks) and pwuitests.

// what a term can measure: id -> label, unit, JavaScript expression (s = ctx.state, m = ctx.memory). A signal with
// "init" / "update" keeps per-flight memory: init runs in init(), update every tick before the terms.
const signals = [
    { id: "agl", label: "height above ground", unit: "m", expr: "s.agl" },
    { id: "altitude", label: "altitude (sea level)", unit: "m", expr: "s.altitude" },
    { id: "airspeed", label: "airspeed", unit: "m/s", expr: "s.airspeed" },
    { id: "groundSpeed", label: "ground speed", unit: "m/s", expr: "s.groundSpeed" },
    { id: "climb", label: "climb rate", unit: "m/s", expr: "s.vy" },
    { id: "roll", label: "bank (roll)", unit: "°", expr: "s.roll" },
    { id: "pitch", label: "pitch", unit: "°", expr: "s.pitch" },
    { id: "tilt", label: "tilt (roll + pitch)", unit: "°", expr: "(Math.abs(s.roll) + Math.abs(s.pitch))" },
    { id: "distance", label: "distance from start", unit: "m", expr: "s.distance" },
    { id: "sideways", label: "sideways speed", unit: "m/s", expr: "Math.hypot(s.vx, s.vz)" },
    { id: "target", label: "distance to target", unit: "m", expr: "dist(ctx)", needsTarget: true },
    { id: "peak", label: "highest height so far", unit: "m", expr: "m.peak", init: "m.peak = s.agl;", update: "m.peak = Math.max(m.peak, s.agl);" },
    { id: "heading", label: "turn from the start heading", unit: "°", expr: "(((s.yaw - m.yaw0) % 360 + 540) % 360 - 180)", init: "m.yaw0 = s.yaw;" }
]
function signal(id) { for (const x of signals) if (x.id === id) return x; return signals[0] }
// plain words for the standard sensor channels (craft sensors keep their own names)
const sensorWords = { "alt": "height", "att.pitch": "pitch", "att.roll": "bank", "att.yaw": "heading", "rate.roll": "roll rate",
                      "rate.pitch": "pitch rate", "rate.yaw": "yaw rate", "air": "airspeed", "vs": "climb rate", "aero.aoa": "angle of attack",
                      "aero.sideslip": "sideslip", "gs": "ground speed" }
function sensorLabel(name) { return sensorWords[name] || name }

// field types: "signal" (pick from signals), "number" (with unit; "@" = the signal's unit), "check"
const termKinds = [
    { id: "near", title: "Stay near", color: "penalty",
      hint: "Lose points the further a measurement drifts from a value (height, bank…)",
      fields: [ { key: "signal", type: "signal" }, { key: "target", label: "at", type: "number", unit: "@" },
                { key: "range", label: "full penalty when off by", type: "number", unit: "@", min: 0.01 } ],
      defaults: { signal: "agl", target: 100, range: 100, weight: 1 },
      plain: t => "loses up to " + num(t.weight) + " points a second as its " + signal(t.signal).label + " strays from " + qty(t.target, signal(t.signal).unit)
                  + " (all of it at ±" + qty(t.range, signal(t.signal).unit) + ")" },
    { id: "upTo", title: "More is better", color: "score",
      hint: "Reward a measurement, but stop rewarding past a cap (e.g. keep some speed)",
      fields: [ { key: "signal", type: "signal" }, { key: "cap", label: "up to", type: "number", unit: "@", min: 0.01 } ],
      defaults: { signal: "airspeed", cap: 40, weight: 0.5 },
      plain: t => "earns points for " + signal(t.signal).label + ", up to " + qty(t.cap, signal(t.signal).unit) },
    { id: "per", title: "Earn for every", color: "score",
      hint: "Reward every bit of a measurement, no cap (e.g. distance covered)",
      fields: [ { key: "signal", type: "signal" }, { key: "per", label: "per", type: "number", unit: "@", min: 0.01 } ],
      defaults: { signal: "groundSpeed", per: 100, weight: 1 },
      plain: t => t.signal === "groundSpeed" ? "earns 1 point per " + num(t.per) + " m travelled"
                  : "earns points for " + signal(t.signal).label + ": 1 point per " + qty(t.per, signal(t.signal).unit) + " held for a second" },
    { id: "below", title: "Penalise low", color: "penalty",
      hint: "Lose points while a measurement is too low (e.g. scraping the ground)",
      fields: [ { key: "signal", type: "signal" }, { key: "limit", label: "while below", type: "number", unit: "@" },
                { key: "onceAbove", label: "only after it first got above", type: "check" } ],
      defaults: { signal: "agl", limit: 20, onceAbove: true, weight: 1 },
      plain: t => "loses points while " + signal(t.signal).label + " is below " + qty(t.limit, signal(t.signal).unit) + (t.onceAbove ? " (once it has been above)" : "") },
    { id: "above", title: "Penalise high", color: "penalty",
      hint: "Lose points while a measurement is too high (e.g. tilting too far)",
      fields: [ { key: "signal", type: "signal" }, { key: "limit", label: "while above", type: "number", unit: "@" } ],
      defaults: { signal: "tilt", limit: 30, weight: 1 },
      plain: t => "loses points while " + signal(t.signal).label + " is above " + qty(t.limit, signal(t.signal).unit) },
    { id: "approach", title: "Get closer to the target", color: "score", needsTarget: true,
      hint: "Reward getting closer to a target point (adds a target)",
      fields: [],
      defaults: { weight: 10 },
      plain: t => "earns up to " + num(t.weight) + " points for closing the distance to the target (loses them again moving away)" },
    { id: "stayOver", title: "Stay over the start", color: "penalty",
      hint: "Lose points for drifting away from where it started (hovering)",
      fields: [ { key: "range", label: "full penalty at", type: "number", unit: "m", min: 0.01 } ],
      defaults: { range: 20, weight: 0.5 },
      plain: t => "loses points for moving away from the start point" }
]
function termKind(id) { for (const k of termKinds) if (k.id === id) return k; return null }

// conditions shared by stop blocks and bonuses
const stopKinds = [
    { id: "crashed", hint: "Stop as soon as it hits the ground or anything else", title: "it crashes", endTitle: "it crashed", fields: [], defaults: {} },
    { id: "reached", hint: "Stop when it gets close enough to the target point", title: "it reaches the target", endTitle: "it reached the target", needsTarget: true,
      fields: [ { key: "radius", label: "within", type: "number", unit: "m", min: 0.1 } ], defaults: { radius: 30 } },
    { id: "tipped", hint: "Stop when it rolls or pitches past an angle", title: "it tips over", endTitle: "it ends tipped over", fields: [ { key: "limit", label: "past", type: "number", unit: "°", min: 1 } ], defaults: { limit: 70 } },
    { id: "tooLow", hint: "Stop when it is still low after some time (never took off)", title: "it is still low", endTitle: "it ends too low", fields: [ { key: "height", label: "below", type: "number", unit: "m" },
                                                    { key: "after", label: "after", type: "number", unit: "s", min: 0 } ], defaults: { height: 5, after: 10 } },
    { id: "grounded", hint: "Stop when it is still on the ground after some time (never took off)", title: "it hasn't taken off", endTitle: "it never took off",
      fields: [ { key: "after", label: "by", type: "number", unit: "s", min: 0 } ], defaults: { after: 3 } },
    { id: "tooHigh", hint: "Stop when it climbs above a height", title: "it is too high", endTitle: "it ends too high", fields: [ { key: "height", label: "above", type: "number", unit: "m" } ], defaults: { height: 300 } }
]
function stopKind(id) { for (const k of stopKinds) if (k.id === id) return k; return null }

function num(x) { return String(Math.round(Number(x) * 1000) / 1000) }
function qty(x, unit) { return num(x) + (unit === "°" ? "°" : " " + unit) }
function clone(x) { return JSON.parse(JSON.stringify(x)) }
// key-order-independent JSON. A program read back from the document has its keys sorted, and its lists arrive as Qt
// sequence wrappers (not Arrays), so normalise through JSON first.
function canon(x) { return canonOf(JSON.parse(JSON.stringify(x === undefined ? null : x))) }
function canonOf(x) {
    if (Array.isArray(x)) return "[" + x.map(canonOf).join(",") + "]"
    if (x && typeof x === "object") return "{" + Object.keys(x).sort().map(k => JSON.stringify(k) + ":" + canonOf(x[k])).join(",") + "}"
    return JSON.stringify(x)
}
function ident(n) { return /^[A-Za-z_$][\w$]*$/.test(n) }

function newProgram() { return { v: 1, target: null, terms: [], stops: [{ kind: "crashed" }], bonuses: [{ name: "crash", when: "crashed", points: -20, timeBonus: 0, chargeRest: true }], code: "" } }
function newTerm(kind, program) {
    const k = termKind(kind), t = Object.assign({ name: kind, kind: kind }, clone(k.defaults))
    t.name = uniqueName(program, kind === "near" ? "hold" : kind === "upTo" ? "speed" : kind === "per" ? "distance" : kind === "below" ? "low"
                                : kind === "above" ? "high" : kind === "approach" ? "progress" : "drift")
    return t
}
function newStop(kind) { return Object.assign({ kind: kind }, clone(stopKind(kind).defaults)) }
function newBonus(program) { return { name: uniqueName(program, "bonus"), when: "crashed", points: -20, timeBonus: 0 } }
function uniqueName(program, base) {
    const used = names(program)
    if (used.indexOf(base) < 0) return base
    for (let i = 2; ; ++i) if (used.indexOf(base + i) < 0) return base + i
}
function names(program) { return (program.terms || []).map(t => t.name).concat((program.bonuses || []).map(b => b.name)) }
function terms(program) { return names(program) }

// ---------------------------------------------------------------- goal presets (block programs)
const goals = [
    { id: "hold", suits: ["plane"], title: "Hold a height, wings level", param: { label: "Height", unit: "m", def: 150, min: 5, get: p => p.terms && p.terms[0] ? p.terms[0].target : undefined },
      blurb: "Get to (or stay at) the height above the ground, keep the wings level and keep some speed.",
      program: (h) => ({ v: 1, target: null,
          terms: [ { name: "altitude", kind: "near", signal: "agl", target: h === undefined ? 150 : h, range: h === undefined ? 150 : h, weight: 1 },
                   { name: "speed", kind: "upTo", signal: "airspeed", cap: 45, weight: 0.5 },
                   { name: "level", kind: "near", signal: "roll", target: 0, range: 90, weight: 0.5 } ],
          stops: [ { kind: "crashed" } ],
          bonuses: [ { name: "crash", when: "crashed", points: -20, timeBonus: 0, chargeRest: true } ], code: "" }) },
    { id: "hover", suits: ["rotor", "rocket"], title: "Hover at a height", param: { label: "Height", unit: "m", def: 20, min: 1, get: p => p.terms && p.terms[0] ? p.terms[0].target : undefined },
      blurb: "Take off if needed, then stay at the chosen height above the ground, hold still over the start point and stay upright. Best with drones and rockets.",
      // "still" (sideways speed) gives a gradient everywhere; "drift" alone maxed out within a second for a fast start
      // (New Shepard wandered 200–550 m). "liftoff" makes sitting on the pad as bad as crashing.
      program: (h) => ({ v: 1, target: null,
          terms: [ { name: "height", kind: "near", signal: "agl", target: h === undefined ? 20 : h, range: h === undefined ? 20 : h, weight: 1 },
                   { name: "still", kind: "near", signal: "sideways", target: 0, range: 10, weight: 0.5 },
                   { name: "drift", kind: "stayOver", range: 100, weight: 0.25 },
                   { name: "upright", kind: "near", signal: "tilt", target: 0, range: 90, weight: 0.5 } ],
          stops: [ { kind: "crashed" }, { kind: "grounded", after: 3 } ],
          bonuses: [ { name: "crash", when: "crashed", points: -20, timeBonus: 0, chargeRest: true },
                     { name: "liftoff", when: "grounded", points: -20, timeBonus: 0, chargeRest: true } ], code: "" }) },
    { id: "target", suits: ["plane", "rotor"], title: "Fly to a target", param: { label: "Distance", unit: "m", def: 800, min: 10, get: p => p.target ? p.target.ahead : undefined },
      blurb: "Reach a point straight ahead of the start, staying clear of the ground. Arriving early scores more.",
      program: (d) => ({ v: 1, target: { ahead: d === undefined ? 800 : d, side: 0 },
          terms: [ { name: "progress", kind: "approach", weight: 10 },
                   { name: "clearance", kind: "below", signal: "agl", limit: 20, onceAbove: true, weight: 1 } ],
          stops: [ { kind: "crashed" }, { kind: "reached", radius: 30 } ],
          bonuses: [ { name: "arrive", when: "reached", points: 20, timeBonus: 10 },
                     { name: "crash", when: "crashed", points: -20, timeBonus: 0, chargeRest: true } ], code: "" }) },
    { id: "distance", suits: ["plane"], title: "Fly as far as possible", param: { label: "Min. height", unit: "m", def: 10, min: 0, get: p => p.terms && p.terms[1] ? p.terms[1].limit : undefined },
      blurb: "Cover the most ground in the episode without crashing or scraping the ground.",
      program: (hmin) => ({ v: 1, target: null,
          terms: [ { name: "distance", kind: "per", signal: "groundSpeed", per: 100, weight: 1 },
                   { name: "low", kind: "below", signal: "agl", limit: hmin === undefined ? 10 : hmin, onceAbove: true, weight: 1 } ],
          stops: [ { kind: "crashed" } ],
          bonuses: [ { name: "crash", when: "crashed", points: -20, timeBonus: 0, chargeRest: true } ], code: "" }) },
    { id: "drive", suits: ["ground"], title: "Drive to a point", param: { label: "Distance", unit: "m", def: 100, min: 1, get: p => p.target ? p.target.ahead : undefined },
      blurb: "Ground vehicles: reach a point straight ahead without flipping over.",
      program: (d) => ({ v: 1, target: { ahead: d === undefined ? 100 : d, side: 0 },
          terms: [ { name: "progress", kind: "approach", weight: 10 } ],
          stops: [ { kind: "crashed" }, { kind: "tipped", limit: 70 }, { kind: "reached", radius: 3 } ],
          bonuses: [ { name: "arrive", when: "reached", points: 20, timeBonus: 10 },
                     { name: "flip", when: "tipped", points: -20, timeBonus: 0, chargeRest: true },
                     { name: "crash", when: "crashed", points: -20, timeBonus: 0, chargeRest: true } ], code: "" }) },
    { id: "speed", suits: ["ground"], title: "Drive fast without flipping", param: { label: "Top speed", unit: "m/s", def: 15, min: 1, get: p => p.terms && p.terms[0] ? p.terms[0].cap : undefined },
      blurb: "Ground vehicles: keep up the chosen speed for the whole flight, in any direction, staying on its wheels. Flipping over or crashing ends it and costs the time left.",
      program: (v) => ({ v: 1, target: null,
          terms: [ { name: "speed", kind: "upTo", signal: "groundSpeed", cap: v === undefined ? 15 : v, weight: 1 },
                   { name: "level", kind: "near", signal: "tilt", target: 0, range: 90, weight: 0.25 } ],
          stops: [ { kind: "crashed" }, { kind: "tipped", limit: 70 } ],
          bonuses: [ { name: "flip", when: "tipped", points: -20, timeBonus: 0, chargeRest: true },
                     { name: "crash", when: "crashed", points: -20, timeBonus: 0, chargeRest: true } ], code: "" }) },
    { id: "climb", suits: ["plane"], title: "Take off and climb", param: { label: "Height", unit: "m", def: 300, min: 10, get: p => p.terms && p.terms[0] ? p.terms[0].cap : undefined },
      blurb: "Planes: take off from the runway and climb to the height, wings level and keeping flying speed. Still on the ground after 25 s is as bad as crashing.",
      // "speed" starts the take-off roll from generation 0 (§10: a reward for height alone is flat on the runway)
      program: (h) => ({ v: 1, target: null,
          terms: [ { name: "height", kind: "upTo", signal: "agl", cap: h === undefined ? 300 : h, weight: 1 },
                   { name: "speed", kind: "upTo", signal: "airspeed", cap: 40, weight: 0.3 },
                   { name: "level", kind: "near", signal: "roll", target: 0, range: 90, weight: 0.5 } ],
          stops: [ { kind: "crashed" }, { kind: "tooLow", height: 3, after: 25 } ],
          bonuses: [ { name: "crash", when: "crashed", points: -20, timeBonus: 0, chargeRest: true },
                     { name: "takeoff", when: "tooLow", points: -20, timeBonus: 0, chargeRest: true } ], code: "" }) },
    { id: "cruise", suits: ["plane"], title: "Hold a speed and heading", param: { label: "Airspeed", unit: "m/s", def: 40, min: 5, get: p => p.terms && p.terms[0] ? p.terms[0].target : undefined },
      blurb: "Planes: fly straight on at the chosen airspeed, keeping the heading it started with, wings level and clear of the ground. Best from an air start.",
      program: (v) => ({ v: 1, target: null,
          terms: [ { name: "speed", kind: "near", signal: "airspeed", target: v === undefined ? 40 : v, range: (v === undefined ? 40 : v) / 2, weight: 1 },
                   { name: "heading", kind: "near", signal: "heading", target: 0, range: 90, weight: 0.5 },
                   { name: "level", kind: "near", signal: "roll", target: 0, range: 90, weight: 0.25 },
                   { name: "low", kind: "below", signal: "agl", limit: 20, onceAbove: true, weight: 1 } ],
          stops: [ { kind: "crashed" } ],
          bonuses: [ { name: "crash", when: "crashed", points: -20, timeBonus: 0, chargeRest: true } ], code: "" }) },
    { id: "station", suits: ["rotor"], title: "Hold position in wind", param: { label: "Height", unit: "m", def: 10, min: 1, get: p => p.terms && p.terms[0] ? p.terms[0].target : undefined },
      blurb: "Drones: take off, hover at the height and stay right over the start point while the wind pushes it. Set the wind in Set up › Advanced (Wind max, Turbulence); two or more flights each make it fair.",
      // Hover on a short leash: "drift" is full at 10 m (Hover: 100 m) and weighs as much as the height
      program: (h) => ({ v: 1, target: null,
          terms: [ { name: "height", kind: "near", signal: "agl", target: h === undefined ? 10 : h, range: h === undefined ? 10 : h, weight: 1 },
                   { name: "drift", kind: "stayOver", range: 10, weight: 1 },
                   { name: "still", kind: "near", signal: "sideways", target: 0, range: 5, weight: 0.5 },
                   { name: "upright", kind: "near", signal: "tilt", target: 0, range: 90, weight: 0.25 } ],
          stops: [ { kind: "crashed" }, { kind: "grounded", after: 3 } ],
          bonuses: [ { name: "crash", when: "crashed", points: -20, timeBonus: 0, chargeRest: true },
                     { name: "liftoff", when: "grounded", points: -20, timeBonus: 0, chargeRest: true } ], code: "" }) },
    { id: "hop", suits: ["rocket"], title: "Hop and land softly", param: { label: "Height", unit: "m", def: 30, min: 2, get: p => p.terms && p.terms[0] ? p.terms[0].cap : undefined },
      blurb: "Rockets: lift off, climb to the height, then come back down and land gently (touching down faster than the crash speed is a crash). The height reached counts for the rest of the flight, so landing after the hop scores most.",
      // "height" pays the highest point so far, so coming back down costs nothing; "land" (being up) and "gentle"
      // (sinking faster than 3 m/s) are smaller, so a hop always pays more than staying on the pad
      program: (h) => ({ v: 1, target: null,
          terms: [ { name: "height", kind: "upTo", signal: "peak", cap: h === undefined ? 30 : h, weight: 1 },
                   { name: "land", kind: "near", signal: "agl", target: 0, range: h === undefined ? 30 : h, weight: 0.5 },
                   { name: "gentle", kind: "below", signal: "climb", limit: -3, onceAbove: false, weight: 0.5 },
                   { name: "upright", kind: "near", signal: "tilt", target: 0, range: 90, weight: 0.5 } ],
          stops: [ { kind: "crashed" } ],
          bonuses: [ { name: "crash", when: "crashed", points: -20, timeBonus: 0, chargeRest: true } ], code: "" }) }
]
function goalById(id, extra) { for (const g of goals.concat(extra || [])) if (g.id === id) return g; return null }

// Craft kinds (EvolveModel.io.craftKind, evo::craftKind): which presets suit which craft.
// A craft of another kind ("other") sees every preset; a saved preset with no kind suits every craft.
const kindWords = { plane: "planes", rotor: "drones and hovering craft", rocket: "rockets", ground: "ground vehicles" }
function suits(g, kind) { return !kind || !kindWords[kind] || !g.suits.length || g.suits.indexOf(kind) >= 0 }
// The preset lists: the presets (built-in, then extra = userGoals) that suit this craft; all = the others too, after
// them. current (the goal in use) is always listed, even when it is for another kind of craft.
function goalsFor(kind, all, extra, current) {
    const list = goals.concat(extra || []), fit = list.filter(g => suits(g, kind)), rest = list.filter(g => !suits(g, kind))
    return all ? fit.concat(rest) : current && rest.indexOf(current) >= 0 ? fit.concat([current]) : fit
}
// how many presets "Show presets for other crafts" adds
function otherCount(kind, extra) { return goals.concat(extra || []).filter(g => !suits(g, kind)).length }
// "Drive to a point  (for ground vehicles)" for a preset that doesn't suit the craft, "Mine  (yours)" for a saved one
function goalLabel(g, kind) {
    const tags = (g.user ? ["yours"] : []).concat(suits(g, kind) ? [] : ["for " + g.suits.map(k => kindWords[k] || k).join(", ")])
    return tags.length ? g.title + "  (" + tags.join(", ") + ")" : g.title
}
// Your saved presets (EvolveModel.goalPresets: [{ name, file, suits, program }]) as goals: no setting, marked "yours".
function userGoals(list) {
    return clone(list || []).map(u => ({ id: "user:" + u.file, user: true, file: u.file, suits: u.suits || [], title: u.name, param: null,
                                         blurb: "Your saved preset" + ((u.suits || []).length ? ", for " + u.suits.map(k => kindWords[k] || k).join(", ") + "." : "."),
                                         program: () => clone(u.program) }))
}
// the goal a craft of this kind starts with after a craft switch (null: keep whatever is there)
function defaultGoal(kind) { return goalById({ plane: "hold", rotor: "hover", rocket: "hover", ground: "drive" }[kind] || "") }
// Which preset a program is (unchanged), or null once edited.
// A preset with a parameter (hover height, target distance…) still counts as that preset at any value of it.
// extra = userGoals: an unchanged saved preset is that preset (the built-ins are tried first).
function goalOf(program, extra) {
    if (!program) return null
    const s = canon(program)
    for (const g of goals.concat(extra || [])) if (canon(g.program(g.param ? g.param.get(program) : undefined)) === s) return g
    return null
}

// ---------------------------------------------------------------- compiler
function usesTarget(p) {
    return !!p.target && ((p.terms || []).some(t => t.kind === "approach" || t.signal === "target")
                          || (p.stops || []).some(x => x.kind === "reached") || (p.bonuses || []).some(b => b.when === "reached"))
}
function cond(kind, args) {
    switch (kind) {
    case "crashed": return "s.crashed"
    case "reached": return "dist(ctx) < " + num(args.radius)
    case "tipped": return "(Math.abs(s.roll) > " + num(args.limit) + " || Math.abs(s.pitch) > " + num(args.limit) + ")"
    case "tooLow": return "(ctx.t > " + num(args.after) + " && s.agl < " + num(args.height) + ")"
    case "tooHigh": return "s.agl > " + num(args.height)
    case "grounded": return "(!s.crashed && s.contact && ctx.t > " + num(args.after) + ")"   // a crash is scored as a crash, not twice
    }
    return "false"
}
// a bonus's condition uses the settings of the stop block of the same kind (e.g. the "reached" radius)
function whenArgs(p, when) { for (const x of p.stops || []) if (x.kind === when) return x; return stopKind(when) ? stopKind(when).defaults : {} }
// The most the per-second scores can change in a second (sum of their weights). Ending the flight early on purpose
// must not beat flying on: "chargeRest" end points also take this for every second not flown, or the search learns to
// crash early to stop paying the per-second penalties (seen on New Shepard: engine off, dive).
function perSecondWeight(p) { return (p.terms || []).filter(t => t.kind !== "approach").reduce((a, t) => a + Math.abs(Number(t.weight) || 0), 0) }
function scale(w) { return Number(w) === 1 ? "" : " * " + num(w) }

function termExpr(t, i) {
    const S = t.signal ? signal(t.signal).expr : ""
    switch (t.kind) {
    case "near": {
        const off = Number(t.target) === 0 ? (t.signal === "tilt" ? S : "Math.abs(" + S + ")") : "Math.abs(" + S + " - " + num(t.target) + ")"
        return "-Math.min(" + off + " / " + num(Math.max(1e-6, t.range)) + ", 1) * dt" + scale(t.weight) }
    case "upTo": return "Math.min(" + S + ", " + num(t.cap) + ") / " + num(Math.max(1e-6, t.cap)) + " * dt" + scale(t.weight)
    case "per": return S + " * dt / " + num(Math.max(1e-6, t.per)) + scale(t.weight)
    case "below": {
        const L = num(t.limit), r = "-Math.min((" + L + " - " + S + ") / " + num(Math.max(1, Math.abs(t.limit))) + ", 1) * dt" + scale(t.weight)
        return (t.onceAbove ? "m.above" + i + " && " : "") + S + " < " + L + " ? " + r + " : 0" }
    case "above": return S + " > " + num(t.limit) + " ? -dt" + scale(t.weight) + " : 0"
    case "approach": return "gain" + scale(t.weight)
    case "stayOver": return "-Math.min(Math.hypot(s.x - m.x0, s.z - m.z0) / " + num(Math.max(1e-6, t.range)) + ", 1) * dt" + scale(t.weight)
    }
    return "0"
}

// The JavaScript for a program. neuralPreset = EvolveModel.presetScript("neural") (the "hold" preset emits it as is).
function compile(p, neuralPreset) {
    if (neuralPreset && canon(p) === canon(goals[0].program())) return neuralPreset
    const T = p.terms || [], B = p.bonuses || [], X = p.stops || [], tgt = usesTarget(p)
    const D = tgt ? num(Math.max(1, Math.hypot(p.target.ahead || 0, p.target.side || 0))) : "1"
    const L = []
    L.push("// Built from EVOLVE blocks (Goal › Blocks). Editing it here turns it into a hand-written script.")
    L.push("function terms() { return " + JSON.stringify(names(p)) + "; }")
    L.push("")
    L.push("// Start every network weight at 0 (neutral surfaces, half throttle) and explore in steps of 0.5.")
    L.push("function genome(base) {\n  base.genes.forEach(function (g) { if (g.group === \"mlp\") { g.initial = 0; g.sigma = 0.5; } });\n  return base;\n}")
    if (tgt) L.push("\nfunction dist(ctx) { const s = ctx.state, m = ctx.memory; return Math.hypot(s.x - m.tx, s.z - m.tz); }")
    const init = []
    if (tgt) init.push("m.tx = s.x + " + num(p.target.ahead || 0) + "; m.tz = s.z + " + num(p.target.side || 0) + "; m.last = " + D + ";")
    if (T.some(t => t.kind === "stayOver")) init.push("m.x0 = s.x; m.z0 = s.z;")
    const mem = signals.filter(x => (x.init || x.update) && T.some(t => t.signal === x.id))
    for (const x of mem) if (x.init) init.push(x.init)
    T.forEach((t, i) => { if (t.kind === "below" && t.onceAbove) init.push("m.above" + i + " = false;") })
    if (init.length) L.push("\nfunction init(ctx) {\n  const s = ctx.state, m = ctx.memory;\n  " + init.join("\n  ") + "\n}")
    // reward: per-tick terms
    const pre = []
    if (tgt && T.some(t => t.kind === "approach")) pre.push("const now = dist(ctx), gain = (m.last - now) / " + D + ";", "m.last = now;")
    for (const x of mem) if (x.update) pre.push(x.update)
    T.forEach((t, i) => { if (t.kind === "below" && t.onceAbove) pre.push("if (" + signal(t.signal).expr + " > " + num(Number(t.limit) + 2) + ") m.above" + i + " = true;") })
    L.push("\nfunction reward(ctx) {\n  const s = ctx.state, m = ctx.memory, dt = ctx.dt;" + (pre.length ? "\n  " + pre.join("\n  ") : "")
           + "\n  return {" + T.map((t, i) => "\n    " + t.name + ": " + termExpr(t, i) + ",").join("") + "\n  };\n}")
    // terminate
    const ends = X.map(x => cond(x.kind, x))
    L.push("\nfunction terminate(ctx) {\n  const s = ctx.state;\n  return " + (ends.length ? ends.join(" || ") : "false") + ";\n}")
    // fitness: summed terms + end bonuses
    const W = perSecondWeight(p)
    const lines = B.map(b => "const " + b.name + " = " + cond(b.when, whenArgs(p, b.when)) + " ? "
                         + (Number(b.timeBonus) ? num(b.points) + " + " + num(b.timeBonus) + " * Math.max(0, 1 - ctx.t / ctx.info.duration)" : num(b.points))
                         + (b.chargeRest && W > 0 ? " - " + num(W) + " * Math.max(0, ctx.info.duration - ctx.t)" : "") + " : 0;")
    const sum = T.map(t => "ctx.sum." + t.name).concat(B.map(b => b.name))
    L.push("\nfunction fitness(ctx) {\n  const s = ctx.state;" + (lines.length ? "\n  " + lines.join("\n  ") : "")
           + "\n  return { fitness: " + (sum.length ? sum.join(" + ") : "0") + ", terms: { " + B.map(b => b.name + ": " + b.name).join(", ") + " } };\n}")
    if (p.code && p.code.trim()) L.push("\n// ---- custom code block\n" + p.code.trim())
    return L.join("\n") + "\n"
}

// Problems that would make the script fail or mislead, as plain sentences ([] = fine).
function problems(p) {
    const r = [], seen = {}
    for (const n of names(p)) {
        if (!ident(n)) r.push("“" + n + "” can't be a score name: use letters, digits and _ only.")
        else if (seen[n]) r.push("Two scores are called “" + n + "”.")
        seen[n] = true
    }
    const needT = (p.terms || []).some(t => t.kind === "approach" || t.signal === "target") || (p.stops || []).some(x => x.kind === "reached")
                  || (p.bonuses || []).some(b => b.when === "reached")
    if (needT && !p.target) r.push("A block uses the target: set a target point.")
    if ((p.terms || []).length === 0 && (p.bonuses || []).length === 0) r.push("Add at least one score, or every flight scores 0.")
    if (/function\s+(terms|reward|terminate|fitness)\s*\(/.test(p.code || "")) r.push("The custom code block redefines a hook the blocks write (terms, reward, terminate or fitness).")
    return r
}

// "How it is scored", one line per score
function describe(p) {
    const r = (p.terms || []).map(t => ({ name: t.name, plain: termKind(t.kind) ? termKind(t.kind).plain(t) : "" }))
    const stops = (p.stops || []).map(x => stopKind(x.kind) ? stopKind(x.kind).title : x.kind)
    if (stops.length) r.push({ name: "", plain: "The flight ends early if " + stops.join(", or ") + "." })
    for (const b of p.bonuses || []) {
        const k = stopKind(b.when)
        r.push({ name: b.name, plain: (Number(b.points) >= 0 ? "+" : "−") + num(Math.abs(b.points)) + " points if " + (k ? k.endTitle : b.when)
                                      + (Number(b.timeBonus) ? ", plus up to " + num(b.timeBonus) + " for time left" : "")
                                      + (b.chargeRest && perSecondWeight(p) > 0 ? ", and " + num(perSecondWeight(p)) + " more for every second it didn't fly" : "") })
    }
    return r
}

// The program behind a script: the saved blocks, else a recognised preset / older goal-picker script, else null.
function programFor(scripts, neuralPreset) {
    if (scripts && scripts.blocks) return scripts.blocks
    const src = scripts ? scripts.source || "" : ""
    if (neuralPreset && (src.trim() === neuralPreset.trim() || src.trim() === legacyNeural(neuralPreset).trim())) return goals[0].program()
    const m = /^\/\/ Goal: (\w+)(?: (-?[\d.]+))?/.exec(src)   // scripts written by the earlier goal picker
    const g = m ? goalById(m[1]) : null
    return g ? g.program(m[2] !== undefined ? Number(m[2]) : undefined) : null
}
// The Neural preset before crashes charged the seconds not flown (experiments saved until 2026-10): Hold, "edited".
function legacyNeural(neuralPreset) {
    return neuralPreset.replace(/\/\/ A crash also costs[^\n]*\n/, "").replace("-20 - 2 * Math.max(0, ctx.info.duration - ctx.t)", "-20")
}
// "blocks": the script is the program's output; "edited": it differs (changed by hand, or written by an older version
// of the blocks / presets, so the banner offers to update it); "script": hand-written.
function state(scripts, neuralPreset) {
    const p = programFor(scripts, neuralPreset)
    if (!p) return "script"
    return compile(p, neuralPreset) === (scripts.source || "") ? "blocks" : "edited"
}
