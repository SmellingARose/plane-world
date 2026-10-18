# Plane World: Crafts

Bundled presets are `data/crafts/*.json`; they and the example crafts in `examples/crafts/` are embedded in the
binary at build time (`src/core/src/craft/library.cpp:51`). User crafts are saved to `<library root>/crafts`:
`~/Library/Application Support/PlaneWorld` on macOS, `%APPDATA%\PlaneWorld` on Windows, `PW_DATA_DIR` overrides
(`src/core/pw/craft/library.h:4`). Every craft is a
list of parts (`box`, `cylinder`, `cone`, `wing`, `prop`, `motor`, `jet`, `solid`, `tank`, `servo`, `wheel`,
`sensor`, CAD meshes) with a position, rotation, mass and type parameters. Servos and motors are linked by id.
Every servo, motor, jet and solid becomes an output (a FLY slider, or a controller output in EVOLVE).

## Bundled presets

| Craft | Parts | What it is for |
|---|---|---|
| **Trainer** | boxes, cone, wings, motor + prop, servos (control surfaces), wheels | High-wing propeller trainer. The default craft for FLY and the `hold100-*` and `glide-cmaes` experiments |
| **Jet trainer** | boxes, wings, jet, tank, servos, wheels | Turbojet with spool lag and fuel burn |
| **Rover** | boxes, motor, servos, wheels | Ground vehicle: suspension and Pacejka-lite tyres, servo steering |
| **Sounding rocket** | cone, cylinders, solid motor, fins | Unguided solid rocket with passive fin stability |
| **Racer quad** | cylinder, cones, arms, 4 motors + props, sensors | 5" FPV-style racing quad, T/W ≈ 9.5. The craft for `drone-hover` and `drone-race` |

## Racer quad (`data/crafts/racer-quad.json`)

A 5-inch FPV racing quad at real scale: 0.764 kg, four 0.127 m (5") props rated 18 N static each
(72 N, **T/W ≈ 9.5**), X layout with 0.226 m motor-to-motor diagonal. The generator for the file is not checked in;
edit the JSON directly.

| Group | Parts | Notes |
|---|---|---|
| Fuselage | `Battery pod` cylinder r 0.03 × 0.16 m (0.43 kg, C_D 0.08), `Camera nose` cone, `Tail fairing` cone (C_D 0.05) | Streamlined pod, **tilted 50° nose-up** relative to the prop plane |
| Arms | 4 thin carbon `box` arms 0.113 × 0.006 × 0.014 m, C_D 0.1 | |
| Motors | `Motor bell XX` cylinders (31 g each) at the arm tips for mass and drag; output parts `Motor FL/FR/RL/RR` | One output per prop |
| Props | `Prop FL (CW)`, `Prop RR (CW)` spin +1; `Prop FR (CCW)`, `Prop RL (CCW)` spin −1; d 0.127, thrust 18 N, vmax 70 m/s | Canted 10° tangentially (see below) |
| Sensors | `att`, `rate`, `alt`, `vs`, `air`, `target` (target at 0, 10, 0) | Inputs for the controllers |

### Design rationale

- **Body tilt.** A racing quad flies its dash at 60–80° nose-down. The pod is built 50° nose-up relative to the
  prop plane (like an FPV camera uptilt), so it is close to streamlined to the flow at dash attitude.
- **Canted motors for yaw.** The prop torque model reacts Q = 0.75 P / Ω with Ω ∝ throttle, so the reaction torque
  hardly changes with throttle and differential throttle gives almost no yaw (measured: −1.7 °/s after 0.1 s
  with a 0.03 split). Each prop is therefore canted 10° tangentially: the CW pair leans one way and the CCW pair
  the other, so a speed difference between the pairs gives a real yaw moment (−85 °/s after 0.1 s, same split)
  for a 1.5 % thrust cost. Tilted motors are a real technique for heavy-lift multirotors.
- **Motor output parts sit at the centre with 1 g mass and `cd` 0.** A `motor` part is a fixed 0.5 m cube body.
  At the arm tips that cube's inertia would triple the quad's pitch/roll inertia and, with the default C_D,
  dominate the drag. The real motor mass and drag are in the small `Motor bell` cylinders. The cubes' ground
  contact corners still make the quad sit about 0.24 m above the ground on the runway.
- **Thrust and throttle.** Static prop thrust grows as power^(2/3), so with T/W 9.5 the motors hover at about
  **4 % output** (≈ 11 % of maximum thrust). The controllers work in thrust fraction and send
  `fraction^1.5` to the motors.
- **Real scale.** At 1 kHz physics the 0.76 kg craft is stable under PID control, so it was not scaled up.

### Measured (fast aero, flat world, still air, scripted cascaded PID: `pwcli --train` probes)

| | |
|---|---|
| Hover output | 0.040 per motor (thrust fraction 0.106) |
| Full-power climb | 51 m/s vertical, 122 m in 3 s from the ground |
| Dash, level at 10 m | 28 m/s with a 78° lean limit, 37 m/s at 85°, **42 m/s (150 km/h)** at 88° (the attitude loop saturates at about 76° real pitch); about 0.03 m² effective drag area, most of it rotor in-plane (H-force) drag from the p-factor model |
| Yaw | 90 °/s command tracked at 89 °/s mean |

### Controls (FLY keys)

The craft declares `"controls": { "controller": "multirotor" }`, so FLY flies it with the built-in angle-mode
flight controller ([CONTROLS.md](CONTROLS.md)):

| Keys | Axis | Effect |
|---|---|---|
| W / S | throttle | Climb / descend at up to 6 m/s; release to hold altitude |
| A / D | yaw | Turn left / right |
| ↑ / ↓ | pitch | Tilt forward / back (up to 35°); release to level |
| ← / → | roll | Tilt left / right; release to level |

It sits idle on the ground until you press W. The props are mounted flat; the controller handles the CoM / thrust
offset itself.

### Experiments

The controller in both is a JS flight controller: position → lean angle → attitude PD → quad mixer, with an
altitude PD and yaw-rate damping. Mixer signs: more front thrust pitches up, more left thrust raises the left side,
more CW-pair thrust (FL, RR) gives negative yaw rate, so the yaw term enters with a minus sign and all gains are ≥ 0.
(Before the `rotorSpeedLaw` fix rotor drag torque did not change with throttle, so the yaw sign was never exercised
and had been wrong.)

- `examples/experiments/drone-hover.json`: climb to 10 m and hold position in wind up to 3 m/s with turbulence.
  8 genes, CMA-ES, 24 × 30 generations. Best fitness 11.7 (population mean 11.5), with 13.8 s of the 15 s episode
  inside the ±1 m / 1.5 m hover box. About 15 s wall time (M4).
- `examples/experiments/drone-race.json`: reach (100, 15, 40) m (109 m away) as fast as possible, then stop and
  hold there. 9 genes (adds the lean limit, starting at 45°). Fitness goes from −8.0 (never arrives) to +15.2: it arrives
  after about 5.6 s and then holds. About 20 s wall time (M4).

## Ducted rocket (`examples/crafts/ducted-rocket.json`)

A vertical-takeoff, tail-sitting ducted-fan "rocket": a 2 m tube with two coaxial fans inside and two exhaust
vanes below them. Total mass is about 13.8 kg (135 N weight). Static thrust is 2 × 230 N, so T/W ≈ 3.4.

| Group | Parts | Notes |
|---|---|---|
| Duct | 8 `box` shell panels, 0.26 × 2.0 × 0.02 m, on a 0.32 m radius, y = 0.3–2.3 m, C_D 0.15 | A hollow octagonal tube, not a solid cylinder |
| Fans | `Prop lower (CW)` at y = 1.0 (spin +1), `Prop upper (CCW)` at y = 1.3 (spin −1); d = 0.55 m, 230 N rated | Counter-rotating |
| Motors | `Lift upper`, `Lift lower`, one per fan | Separate outputs |
| Vanes | `Fin X (vane)` / `Fin Z (vane)`, 0.5 × 0.25 m, at y = 0.55 on servos `Vane X` / `Vane Z` (±25°) | Inside the duct, in the fan exhaust |
| Sensors | `att`, `rate`, `alt`, `vs`, `target` (target at 0, 10, 0) | Inputs for the hover controller |

### Design rationale

- **Hollow duct.** The shell sits at 0.32 m from the axis, about 1.16 fan radii. That is inside the 1.0–1.7 R
  ring the slipstream model's auto-detection looks for (≥ 9 of 12 sectors covered), so both fans are treated as
  ducted rotors: σ = 1 duct thrust (the same power as an open rotor √2 times larger) and an uncontracted wake.
  A solid cylinder would block the flow path. A hollow tube is what a real ducted fan looks like.
- **Counter-rotation.** One fan alone puts its full shaft torque on the airframe (the model reacts the whole
  operating-point torque), so the craft would spin up in yaw. Two fans with `spin` +1 and −1 cancel the torque and
  most of the swirl. Each fan has its **own motor**, so a speed difference between them gives a yaw command.
  `physics.prop-counter-rotation` tests this.
- **Exhaust vanes.** At hover the craft's airspeed is near zero, so the only fast air is the fan exhaust (several
  m/s to tens of m/s). The vanes sit in that exhaust, under the lower fan and inside the duct, so deflecting them
  turns the jet and gives a pitch or roll moment about the centre of mass. That is the same idea as jet vanes on a
  rocket or the vanes under a ducted-fan drone.
- **Why fins outside the duct cannot steer at hover.** A fin produces force ∝ ½ρV²: at hover the free-stream V
  is about 0, so an external fin produces nothing until the craft is already moving. The slipstream model only
  gives a surface wake velocity if it lies inside the wake tube (radius about R behind the disk). Fins outside
  the duct are outside that tube, so they are useless for hover control, and the
  craft needs vanes in the exhaust.

### Tests

`pwcli --selftest physics.prop-counter-rotation` checks that the coaxial pair climbs and cancels yaw torque.
`examples/experiments/hover-ducted-rocket.json` and `hover-pid.json` train controllers for it
([EVOLUTION.md §9](EVOLUTION.md#9-headless-training-cli)).
