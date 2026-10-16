// Take off and hold 100 m AGL for 60 s. Named reward terms ("points"):
//   speed   - airspeed up to 35 m/s (shaping: gets the takeoff roll going)
//   track   - closeness to 100 m every step (0..1 per second)
//   hold    - seconds spent within +-10 m of 100 m (the headline number)
//   level   - penalty for bank angle
//   crash   - one-off penalty if the episode ends in a crash
function terms() { return ["speed", "track", "hold", "level", "crash"]; }

function genome(base) {
  // Random initial weights in [-1.5, 1.5] (no fixed initial value, so a GA starts from a diverse population).
  base.genes.forEach(function (g) { if (g.group === "mlp") { g.min = -1.5; g.max = 1.5; g.initial = null; g.sigma = 0.3; } });
  return base;
}

function reward(ctx) {
  const s = ctx.state, dt = ctx.dt;
  const err = Math.abs(s.agl - 100);
  return {
    speed: Math.min(s.airspeed, 35) / 35 * dt * 0.3,
    track: Math.max(0, 1 - err / 100) * dt,
    hold: err < 10 ? dt : 0,
    level: -Math.min(Math.abs(s.roll) / 90, 1) * dt * 0.5,
  };
}

// Stop early on a crash, or if the craft is still on the ground after 30 s (saves simulation time).
function terminate(ctx) { return ctx.state.crashed || (ctx.t > 30 && ctx.state.agl < 5); }

function fitness(ctx) {
  const crash = ctx.state.crashed ? -20 : 0;
  return { fitness: ctx.sum.speed + ctx.sum.track + ctx.sum.hold + ctx.sum.level + crash, terms: { crash: crash } };
}

function descriptor(ctx) { return [ctx.state.x, ctx.state.agl]; }
