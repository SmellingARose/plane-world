// Preset scripts, verbatim from Sources/Evolution/Core/Presets.swift (the native preset runtime recognises them).
#include "pw/evo/experiment.h"
namespace pw::evo::presets {
const char* const kNeuralJS = R"JS(// Neural controller preset. The native MLP (genome → weights) writes ctx.out before control() runs;
// this script shapes the genome and scores the flight. See docs/EVOLUTION.md §4.
function terms() { return ["altitude", "speed", "level", "crash"]; }

// Start every MLP weight at 0 (neutral surfaces, half throttle) and let the optimiser explore with a
// step of 0.5 per weight. Random ±3 weights saturate the network and the Trainer never leaves the runway.
function genome(base) {
  base.genes.forEach(function (g) { if (g.group === "mlp") { g.initial = 0; g.sigma = 0.5; } });
  return base;
}

function control(ctx) {
  // optional post-processing of the network outputs, e.g. keep the brakes off:
  // ctx.out["Main L motor"] = 0;
}

function reward(ctx) {
  const s = ctx.state, dt = ctx.dt;
  return {
    altitude: -Math.min(Math.abs(s.agl - 150) / 150, 1) * dt,
    speed: Math.min(s.airspeed, 45) / 45 * dt * 0.5,
    level: -Math.min(Math.abs(s.roll) / 90, 1) * dt * 0.5,
  };
}

function terminate(ctx) { return ctx.state.crashed; }

// A crash also costs 2 points (the per-second weights) for every second not flown, so crashing early never pays.
function fitness(ctx) {
  const crash = ctx.state.crashed ? -20 - 2 * Math.max(0, ctx.info.duration - ctx.t) : 0;
  return { fitness: ctx.sum.altitude + ctx.sum.speed + ctx.sum.level + crash, terms: { crash: crash } };
}

function descriptor(ctx) { return [ctx.state.x / 1000, ctx.state.agl / 300]; })JS";
const char* const kDesignJS = R"JS(// Craft design preset. Genes are applied natively (genome.design); this script flies every design with
// a PID autopilot and scores climb per kilogram.
function terms() { return ["climb", "efficiency", "crash"]; }

function init(ctx) {
  ctx.memory.pitch = pid(0.08, 0.01, 0.5);
  ctx.memory.roll = pid(0.03, 0.0, 0.2);
}

function control(ctx) {
  const s = ctx.state, m = ctx.memory;
  const targetPitch = s.airspeed > 30 ? 8 : 0;
  ctx.out.Engine = 1;
  ctx.out.Elevator = clamp(m.pitch.update(targetPitch - s.pitch, ctx.dt), -1, 1);
  ctx.out.Ailerons = clamp(m.roll.update(-s.roll, ctx.dt), -1, 1);
  ctx.out.Rudder = 0;
}

function reward(ctx) { return { climb: Math.max(0, ctx.state.vy) * ctx.dt }; }

function terminate(ctx) { return ctx.state.crashed; }

function fitness(ctx) {
  const crash = ctx.state.crashed ? -100 : 0;
  const eff = ctx.state.agl / Math.max(ctx.state.mass, 1) * 100;
  return { fitness: ctx.sum.climb + eff + crash, terms: { efficiency: eff, crash: crash } };
})JS";
}
