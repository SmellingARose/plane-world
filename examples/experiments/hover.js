// Ducted rocket: lift off, climb to 10 m and hover over the start point, upright.
// Outputs: Lift upper, Lift lower (differential speed = yaw), Vane X / Vane Z (exhaust vanes tilt the craft).
// Named reward terms ("points"); all shaped so every candidate gets a gradient toward hovering:
//   height - always-on penalty for height error (capped at 20 m)
//   hover  - seconds within +-1.5 m of 10 m and 2 m horizontally (the headline number)
//   calm   - penalty for vertical speed (weighted more near the target)
//   drift  - penalty for horizontal distance from the start point
//   upright- penalty for tilt
//   spin   - penalty for yaw rate
//   crash  - one-off penalty (crash, tipped over or flew away above 30 m)
function terms() { return ["height", "hover", "calm", "drift", "upright", "spin", "crash"]; }

function reward(ctx) {
  const i = ctx.in, dt = ctx.dt;
  const dy = Math.abs(i["target.dy"]);
  const dh = Math.sqrt(i["target.dx"] * i["target.dx"] + i["target.dz"] * i["target.dz"]);
  const tilt = Math.min(Math.sqrt(i["att.pitch"] * i["att.pitch"] + i["att.roll"] * i["att.roll"]) / 90, 1);
  const near = dy < 3 ? 1 : 0.3;
  return {
    height: -Math.min(dy, 20) / 10 * dt,
    hover: (dy < 1.5 && dh < 2) ? dt : 0,
    calm: -Math.min(Math.abs(i.vs) / 5, 1) * near * dt * 0.5,
    drift: -Math.min(dh / 10, 1) * dt * 0.5,
    upright: -tilt * dt,
    spin: -Math.min(Math.abs(i["rate.yaw"]) / 180, 1) * dt * 0.3,
  };
}

function failed(ctx) {
  const i = ctx.in;
  return ctx.state.crashed || Math.abs(i["att.pitch"]) > 80 || Math.abs(i["att.roll"]) > 80 || i.alt > 30;
}
// End early on failure (saves sim time); the remaining time is charged via the crash penalty.
function terminate(ctx) { return failed(ctx); }

function fitness(ctx) {
  // Losing the rest of the episode costs the same per second as sitting on the ground (height error ~1/s),
  // so trying to fly is never worse than not taking off (a harsher penalty made 'stay on the ground' optimal).
  const crash = failed(ctx) ? -1.0 * (20 - ctx.t) - 1 : 0;
  const s = ctx.sum;
  return { fitness: s.height + s.hover + s.calm + s.drift + s.upright + s.spin + crash, terms: { crash: crash } };
}

function descriptor(ctx) { return [ctx.in["target.dx"], ctx.in["target.dz"]]; }
