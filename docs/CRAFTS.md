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
