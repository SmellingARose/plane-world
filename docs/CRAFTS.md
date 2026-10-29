# Plane World: Crafts

Bundled presets are `data/crafts/*.json`; they and the example crafts in `examples/crafts/` are embedded in the
binary at build time (`src/core/src/craft/library.cpp:51`). User crafts are saved to `<library root>/crafts`:
`~/Library/Application Support/PlaneWorld` on macOS, `%APPDATA%\PlaneWorld` on Windows, `PW_DATA_DIR` overrides
(`src/core/pw/craft/library.h:4`). Every craft is a
list of parts (`box`, `cylinder`, `cone`, `wing`, `prop`, `motor`, `jet`, `solid`, `rocket`, `tank`, `servo`, `wheel`,
`sensor`, CAD meshes) with a position, rotation, mass and type parameters. Servos and motors are linked by id.
Every servo, motor, jet and solid becomes an output (a FLY slider, or a controller output in EVOLVE).

## Craft library (BUILD)

BUILD › *Craft library…* (Ctrl+L, also in the command palette) opens a page of picture cards: the built-in crafts
(presets, then examples) and every `.json` in `<library root>/crafts`, including saved crafts that share a built-in's
name. Each card shows the craft's kind (`evo::craftKind`: plane, multirotor, rocket, ground vehicle), part count and
mass with fuel, a *Built-in* or *Yours* badge, and *Open now* on the craft being edited.

| Key | Action |
|---|---|
| ← ↑ → ↓ | Move between cards |
| Return / click | Open the craft (undoable, like any load) |
| typing | Search by name, kind or "yours" / "built-in" |
| F2 | Rename (yours only): the file becomes `<new name>.json`, clashes with your crafts or a built-in name are refused |
| Ctrl+D | Duplicate into your crafts as "<name> copy" (works on built-ins too: the way to start from a preset) |
| Delete / Backspace | Move to the Trash after an in-app confirmation (yours only; built-ins can't be deleted) |

Deleting the open craft keeps it open but marks it unsaved; renaming it keeps it open under the new name and file.
*Save to library* now also makes the library file the open craft's file, so Ctrl+S keeps saving there.

**Pictures.** `pw::render::ThumbnailRenderer` (`src/render/src/thumbnail.cpp`) renders the craft offscreen with the
normal renderer: BUILD's ground and lighting, BUILD's default orbit direction (a little higher), the camera distance
fitted to the craft's bounds, 12 frames so TAA settles, at 960×600, scaled to 480×300. The app renders on a worker
thread with its own GPU device (`src/app/craftthumbnails.cpp`), only for missing pictures and only once the library is
first opened. Pictures are cached as `<library root>/thumbnails/<key>-<hash>.png`: key is the file name for your crafts
and `built-in/<name>` for built-ins; hash is `library::shapeHash` (FNV-1a over the parts and a picture-style version,
not the name), so a rename moves the picture, an edit makes a new one and the stale one is removed.
`pwcli --craft-thumbnail "<preset>|<craft.json>" out.png [--width W --height H]` renders the same picture headless.

## Bundled presets

| Craft | Parts | What it is for |
|---|---|---|
| **Trainer** | boxes, cone, wings, motor + prop, servos (control surfaces), wheels | High-wing propeller trainer. The default craft for FLY and the `hold100-*` and `glide-cmaes` experiments |
| **Jet trainer** | boxes, wings, jet, tank, servos, wheels | Turbojet with spool lag and fuel burn |
| **Rover** | boxes, motor, servos, wheels | Ground vehicle: suspension and Pacejka-lite tyres, servo steering |
| **Sounding rocket** | cone, cylinders, solid motor, fins | Unguided solid rocket with passive fin stability |
| **New Shepard** | BE-3PM rocket engine (2-axis gimbal), LOX + LH2 tanks, cylinders, sphere, ring fin + wedge fins + aft fins (wings), drag brakes, legs | Blue Origin's suborbital booster + crew capsule at real scale: 490 kN sea-level hydrolox engine, 35 t lift-off, T/W 1.43, 18 %-of-SL deep throttling. Flown by the built-in `rocket` controller |
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

## New Shepard (`data/crafts/new-shepard.json`)

Blue Origin's New Shepard (single-stage VTVL booster + six-seat crew capsule) at real scale, flown by the built-in
`rocket` controller. It replaces the earlier generic "Liquid rocket" preset.

### Published figures used

| Figure | Value | Source |
|---|---|---|
| Engine | one BE-3PM, LOX/LH2, pump-fed tap-off cycle | [1], [2] |
| Sea-level thrust | 110,000 lbf (490 kN) | [1], [2], [3] |
| Deep throttling | 18–100 %; ~20,000 lbf (89 kN) for landing | [1], [2] |
| Length / diameter | 19.2 m / 3.8 m (we use 3.7 m, the figure quoted for the booster barrel) | [3] |
| Launch mass | 35,000 kg | [3] |
| Aero surfaces | ring fin + wedge fins near the top, four aft fins at the base, drag brakes that deploy from the ring fin and halve the descent speed (eight on the first landing) | [3], [4], [5] |
| Landing gear | four legs | [3] |
| Capsule | 6 seats, 6 large windows, 15 m³, three parachutes | [3] |

Our six windows, four legs and eight drag brakes follow these sources (four legs, not six: [3] and the design
overviews agree on four).

### Engineering estimates (not published)

- **Isp**: 328 s at sea level, 410 s in vacuum. Hydrolox at mixture ratio ~5.5 with an assumed ~7 MPa chamber and a
  sea-level nozzle (area ratio 25, `expansion`): ideal vacuum Isp ≈ 430 s × 0.95 efficiency ≈ 410 s; the
  sea-level thrust coefficient is (C_F,vac − ε p₀/p_c) / C_F,vac ≈ 0.80 of vacuum, so 328 s.
  These give F_vac = 490 kN × 410/328 = 612.5 kN (the `thrust` param) and a nozzle exit area
  A_e = (F_vac − F_SL)/p₀ = 1.21 m², i.e. the 0.62 m exit radius (`r`) of the engine mesh: the
  thrust model and the geometry agree. Full-throttle propellant flow is 152 kg/s.
- **Minimum throttle**: the model's pressure-loss term (s·F_vac − p·A_e) is evaluated with `minThrottle` = 0.345 so
  that the sea-level minimum is the published 89 kN (18 % of 490 kN). A real nozzle at that chamber pressure
  separates and loses less, which is why the flow fraction is higher than 18 %.
- **Gimbal**: ±6° at 20°/s (typical for an engine this size).
- **Masses**: capsule 4.0 t, booster dry 12.0 t (engine 1.0 t, structure/skin 5.4 t, tanks 2.5 t, ring fin + brakes +
  wedge fins 1.5 t, aft fins 0.6 t, legs 1.0 t), propellant 19.0 t to make the published 35 t lift-off mass.
  19 t is ~125 s at full throttle, in line with the ~110–140 s powered flight [3].
- **Propellant split**: LOX 16,286 kg + LH2 2,714 kg (6 : 1 by mass), in two internal `tank` parts (the LH2 tank is
  6 m long for the 38 m³ it needs; the tanks have `cd` 0 because they are inside the skin). Both drain together.
- **Geometry**: booster 15.4 m (engine bay 2.15–3.85 m, LOX section to 7.0 m, LH2 section to 13.2 m, forward skirt with
  the ring fin to 15.4 m), capsule 3.8 m (heat shield, cabin, hemispherical dome, parachute cover). Ring fin: 16
  wing panels at 2.3 m radius, 1.1 m chord; four wedge fins tie it to the body; four 1.9 × 1.0 m aft fins; the
  nozzle exit sits 0.8 m above the ground on the deployed legs.

### Aerodynamics

Every surface is a normal part of the fast aero model:

- **Fins are wings** (strip theory): ring-fin panels `ar` 4 (an annular wing has about twice the lift slope of its
  flat span), aft fins `ar` 1.1 and wedge fins `ar` 1 (span doubled by the body), all 0.12–0.16 m thick, uncambered.
- **Cylinders use `cdAxial`** (axial drag on πr²) and `cd` (cross-flow on the 2r·h side). Cross-flow `cd` 0.6 is the
  supercritical circular-cylinder value at Re ~10⁷. Axial values are a textbook build-up on the 10.75 m² frontal
  area [6]: turbulent skin friction C_f = 0.002 on each section's wetted area, the capsule's blunt-dome forebody
  pressure drag 0.15, base drag 0.15 on the aft skirt (power off), and 0.02 ring-fin/body interference.
  The capsule's drag is carried by the cabin cylinder (its cross-flow `cd` is raised to cover the dome's side
  area), so the dome sphere has `cd` 0.
- **Drag brakes** are stowed flush in the ring fin (`cd` 0; their area is the ring fin's). Deploying them is left
  to a future servo-driven version.

Whole-vehicle drag at Mach 0.5, sea level, measured by `physics.rocket-gimbal`:

| Configuration | C_D (on 10.75 m²) |
|---|---|
| Clean (legs stowed, as on the real ascent) | **0.42** |
| As modelled (landing legs deployed, foot pads face-on) | 0.71 |

0.42 is inside the 0.3–0.6 range expected for a blunt capsule on a cylinder with fins (forebody 0.15 + friction
0.04 + base 0.15 + fins/interference ~0.05). The preset keeps the legs deployed because it lands; that costs
0.29, mostly the face-on foot pads (`cdAxial` 1.1, a disc). The model has no part-to-part shielding, so the legs
in the base wake are counted in full.

### Engine and gimbal

The `rocket` part is drawn as a real engine (`pw/rocket_geometry.h`, `craft::partMesh`): gimbal block with cardan
pins and ring on a thrust plate, injector dome, cylindrical chamber (contraction ratio 3.2), 30° convergent
section, throat, and an 80 % Rao bell (0.382 r_t throat arc to the inflection angle, Bézier to the exit angle,
both from the area ratio) split into a dark regeneratively cooled section and a lighter nozzle extension, with
coolant manifolds, a sooty inner wall, two hydraulic actuators (pitch and yaw planes), two turbopumps with
discharge ducts and feed lines, and a turbine exhaust duct. Parts' meshes can carry per-sub-mesh materials
(`MeshData::groups`). In FLY the engine visibly swivels about its gimbal pivot (the same point the thrust acts
through) and a plume glows below the nozzle, scaled with throttle.

### Flying it

- **Outputs**: `BE-3PM engine` (throttle), `… gimbal pitch`, `… gimbal yaw` (ids `eng`, `eng.gimbal-pitch`,
  `eng.gimbal-yaw`).
- **Lift-off**: T/W 1.43 at full throttle; the climb is ~4 m/s² rising as it burns.
- **Landing**: near the end of the burn (~17 t) it hovers at ~48 % throttle; minimum throttle (89 kN) is well below
  the weight, so it can descend onto the pad.

| Keys | Axis | Effect |
|---|---|---|
| W / S | throttle | Ramp up / down (stays where you leave it) |
| ↑ / ↓ | pitch | Tilt forward / back up to 20°; release to return vertical |
| ← / → | yaw | Tilt left / right; release to return vertical |

There is no roll control (one engine cannot roll the rocket). `physics.rocket-gimbal` checks the sea-level and
vacuum thrust, the 89 kN minimum, the propellant flow, the 35 t lift-off mass and T/W, the gimbal limit, that the
rendered engine turns by the gimbal angle about its pivot (nozzle axis = thrust axis), the Mach 0.5 drag, that the
controller holds a vertical climb and tilts on command, and the end-of-burn hover.

Sources:
1. Blue Origin, BE-3 engine, https://www.blueorigin.com/engines/be-3
2. Wikipedia, BE-3, https://en.wikipedia.org/wiki/BE-3
3. Wikipedia, New Shepard, https://en.wikipedia.org/wiki/New_Shepard
4. Blue Origin, New Shepard, https://www.blueorigin.com/new-shepard
5. National Space Society, "Blue Origin Makes Historic Rocket Landing" (2015), https://nss.org/blue-origin-makes-historic-rocket-landing/
6. S. F. Hoerner, *Fluid-Dynamic Drag* (1965), ch. 2–3 (skin friction, blunt forebodies, base drag) and ch. 13 (rockets)
