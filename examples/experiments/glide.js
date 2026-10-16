// Glide distance: the craft starts in the air (150 m AGL, 32 m/s) with the engine off. A fixed PID
// autopilot holds a shallow glide attitude and keeps the wings level; the evolved genes are the airframe.
// Points: distance (m flown horizontally), airtime (s), landing (penalty for a hard touchdown).
function terms() { return ["distance", "airtime", "landing"]; }

function init(ctx) {
  ctx.memory.pitch = pid(0.08, 0.01, 0.4);
  ctx.memory.roll = pid(0.03, 0.0, 0.2);
}

function control(ctx) {
  const s = ctx.state, m = ctx.memory;
  ctx.out.Engine = 0;
  // pitch for ~1.3x stall-ish speed: nose down when slow, up when fast
  const target = clamp((s.airspeed - 24) * 0.5, -8, 4);
  ctx.out.Elevator = clamp(m.pitch.update(target - s.pitch, ctx.dt), -1, 1);
  ctx.out.Ailerons = clamp(m.roll.update(-s.roll, ctx.dt), -1, 1);
  ctx.out.Rudder = 0;
}

function reward(ctx) { return { airtime: ctx.state.contact ? 0 : ctx.dt }; }

function terminate(ctx) { return ctx.state.crashed || (ctx.t > 1 && ctx.state.contact); }

function fitness(ctx) {
  const s = ctx.state;
  const distance = s.distance;
  const landing = s.crashed ? -200 : -Math.max(0, s.impactSpeed - 4) * 10;
  return { fitness: distance + landing, terms: { distance: distance, landing: landing } };
}
