# Plane World: Full-flow model (GPU CFD)

The aero model is a switch: **fast** (strip wings, momentum props, actuator-disk slipstream, Newtonian panels;
see `docs/PHYSICS.md`) or **full** (a lattice-Boltzmann CFD solver on the GPU: Metal on macOS, D3D12 on
Windows; Slang shaders in `shaders/flow`). Both FLY and training (`pwcli --train`, EVOLVE) can use either.
Settings: `CFDSettings` (`src/core/pw/sim/cfd.h:45`), presets in `CFDSettings::fromPreset`
(`src/core/src/sim/cfd.cpp:31`), diagnostics `CFDDiagnostics` (`cfd.h:70`). Backend interface `AeroBackend`
(`cfd.h:116`); solver `pw::flow::LBMSolver` (`src/flow/pw/flow/lbm.h:56`, `src/flow/src/lbm.cpp`). CraftSim glue:
`src/core/pw/sim/full_aero.h`, `src/core/src/sim/full_aero.cpp`.

> **Status.** The GPU solver is wired end to end: FLY (aero model list, CFD settings
> panel, live diagnostics, slice + particle overlay), `--train --aero full`, EVOLVE, and
> `pwcli --aero-compare` (per-part fast vs CFD table). Selftests `flow.*` and `fidelity.*` cover it.
> The 2026-10 solver rework (§7: anisotropic part SDFs, exact Bouzidi across sub-cell sheets, log-law wall model,
> chord-targeted craft-fitted domain, esoteric-pull fp16 single-buffer streaming) has **not been re-measured yet**;
> the §6 numbers are from the old solver, where accuracy was poor at usable grids. Check the convergence readouts. If the backend is unavailable, **full** falls back to **fast** and
> the UI says why.

## 1. Method

- **Lattice-Boltzmann**, D3Q19 (default) or D3Q27 velocities, on a uniform grid of spacing dx.
- **Collision:** BGK, MRT (Hermite-basis: stress modes at ω, higher modes at 1.2) or regularized.
  **Cumulant is not implemented:** selecting it (the settings default) runs the regularized operator, and
  `LBMSolver::effectiveCollision()` (`lbm.h:75`) reports that. BGK is the cheapest and the least stable.
- **Turbulence (LES):** none, Smagorinsky (C_s default 0.17) or WALE. A real craft's Reynolds number is far too
  high to resolve, so leave LES on.
- **Moving, craft-following domain.** A **world-axis-aligned** box that translates with the craft's centre of
  mass (Galilean frame at the craft velocity; changes of velocity enter as a uniform body force). It is laid out
  on the first update: every face at least the craft's bounding radius Lc from the CoM, plus padding in multiples of Lc,
  on the dominant flow direction (or the rotor wake when hovering). dx = min(1/cellsPerMeter, main-wing chord / 16),
  then coarsened to the cell budget `maxCellsPerAxis`³ (and 2 × `maxCellsPerAxis` per axis); the effective dx is in
  the diagnostics. The settings inspector shows the effective dx under the
  resolution slider and turns it orange with a "capped by max cells/axis" note when the cap is what sets it.
- **Boundaries:** inflow faces hold the far-field velocity with a velocity sponge; the other faces are open
  pressure outlets with a density-only sponge (so mass is not exactly conserved: see `massDrift`).
- **Geometry** is voxelised every CFD update from the part transforms, so servo-deflected surfaces and wheels move.
- **Walls:** simple bounce-back or interpolated (Bouzidi) bounce-back (default) on the signed-distance wall
  position, plus a log-law wall model on the first fluid cell (§7).
- **Forces:** Galilean-invariant momentum exchange at wall links (populations taken relative to the rest state, so a
  part partly buried in another part does not feel the ambient pressure on its exposed side only), summed per part, to give a force and torque per part. These replace
  the fast wing, body and panel aero.
- **Propellers** are not meshed. Each one is an actuator-disk body force (thrust plus swirl in its spin sense),
  with thrust and torque from the fast momentum-theory model. So prop thrust is the same in both models; what CFD
  changes is how that wake interacts with the airframe.
- **Ground:** a moving-wall boundary at the ground's relative velocity when the domain reaches terrain.
- **Training:** each evaluation worker owns one private CFD backend (`EvalWorker::fullBackend_`,
  `src/core/pw/evo/evaluator.h:120`; configured in `EvalWorker::loadSim`, `src/core/src/evo/evaluator.cpp:235`)
  on the scalar CraftSim (the C++ evaluator is scalar; `batchLanes` is ignored). `LBMDomainPool` (several domains
  in one command buffer, `lbm.h:141`) exists, is registered and selftested, but the trainer does not use it yet,
  so "one domain pool per worker" is today "one domain per worker".
- **Lag:** update k submits poses at substep k·N and collects at substep (k+1)·N (N = `updateEvery`). `submit`
  records and commits GPU work without waiting; `collect` waits for it, so the GPU runs while the CPU integrates
  and CFD forces are one update old (`CraftSim::substep`, `src/core/src/sim/craft_sim.cpp:512`: `fullCollect`
  before `substepCore`, `fullSubmit` after).

### Contract

- **Fast path untouched when the model is fast.** The full path is one branch around `substepCore`
  (`craft_sim.cpp:512`); with `AeroModel::Fast` nothing changes, and the trajectory digests in
  `physics.trajectory-digest` (`src/core/src/sim/physics_selftests.cpp:430`) stay bit-exact. In full mode the fast
  wing/body/panel aero runs only on an equation-capture substep, for the comparison rows (`craft_sim.cpp:619`).
- **No per-substep allocation in the full path.** Pose, rotor and force buffers are sized in `enableFull` /
  `prepareFull` (`full_aero.cpp:29`, `:43`); `submit`/`collect` do not allocate after the first submit of a layout
  (`cfd.h:114`, `lbm.h:20`), unless a diverged domain is re-laid out.
- **One backend per CraftSim**, called only from that sim's thread (`CraftSim::aeroBackend`,
  `src/core/pw/sim/craft_sim.h:131`; not owned).
- If the backend is missing or `configure` fails, full falls back to fast and the error is shown.
- **Not wired:** the sampled flow velocity per part does not yet feed servo hinge loads or sensors; in full mode
  the servo hinge load is 0 and sensors use the free stream. The slice plane is in world axes, not craft axes.

### Unit conversion
dx = 1 / cellsPerMeter. The reference speed U_ref (max of airspeed and the slipstream estimate) maps to the
lattice speed `latticeMach · c_s`, c_s = 1/√3. So

- dt = latticeMach · c_s · dx / U_ref
- ν_lat = ν · dt / dx²

The lattice Mach number is an artificial compressibility knob, not the real Mach number. Errors grow like Ma²,
so keep it at 0.05–0.15. Above `maxMach` (default 0.3) the run is flagged.

## 2. Settings guide

| Setting | Default | What it does | Cost / accuracy |
|---|---|---|---|
| `cellsPerMeter` | 16 | Resolution. dx = 1/cellsPerMeter | Cost ∝ cells³ × steps ∝ roughly (cellsPerMeter)⁴. The biggest single accuracy knob |
| `maxCellsPerAxis` | 192 | Cell budget: at most maxCellsPerAxis³ cells (and 2× per axis); dx is coarsened to fit | Memory ≈ 19 or 27 × 2 bytes (fp16) or × 4 (fp32) + ~40 bytes per cell |
| `padUpstream / padDownstream / padLateral` | 1.0 / 2.5 / 1.0 craft half-sizes | Padding around the craft's bounding box | Too small: blockage and reflected waves inflate forces. Too big: cells wasted |
| `latticeMach` | 0.1 | Sets the time step | Lower is more accurate, but needs more steps per second of sim time |
| `maxMach` | 0.3 | Divergence guard | Flagged when exceeded |
| `lattice` | d3q19 | Velocity set | d3q27 is about 40 % more work, more isotropic, more stable with cumulant |
| `collision` | cumulant (runs regularized) | Collision operator | See §1 |
| `turbulence` | smagorinsky | Subgrid model | WALE behaves better near walls |
| `smagorinskyCs` | 0.17 | Smagorinsky constant | 0.1–0.2 is the usual range |
| `wall` | interpolatedBounceBack | Wall treatment | Plain bounce-back is a stair-step surface: cheaper, less accurate |
| `substeps` | 0 (= 256) | Cap on LBM steps per CFD update | When hit, the flow falls behind real time (`stepCapHit`) |
| `updateEvery` | 4 | Physics substeps between CFD updates | Forces are held between updates. Higher = cheaper and laggier |
| `ground` | on | Ground wall when terrain is inside the domain | Needed for takeoff, landing and hover |
| `convergenceEvery` | 200 | Every N CFD steps, also run a 2× coarser shadow grid | 0 = off. Gives the convergence estimate below |
| `visualization` | off | Slice (speed, pressure or vorticity) on an axis and offset, optional particles. The colour map auto-ranges to the slice's own max (GPU atomic max, read back one frame later, smoothed; speed floor 0.5 m/s), so a slow or fast craft both use the full map | Small extra GPU cost |

### Presets

Defined in `CFDSettings::fromPreset` (`src/core/src/sim/cfd.cpp:31`). In the UI they are picked from the aero
model list, which FLY and EVOLVE share (`AeroModelPicker.qml`, built in `src/app/appcontroller.cpp:953`): entries
"Full CFD · Draft", "Full CFD · Medium", "Full CFD · High", "Full CFD · Ultra" next to the fast profiles. The
"CFD settings" section of the aero panel (`src/app/qml/AeroPanel.qml:61`) has the sliders for every field. Palette
commands (`src/app/qml/AppCommands.qml:68`): "Aero: toggle flow slice", "Aero: flow slice horizontal",
"Aero: flow slice vertical".

| Preset | cellsPerMeter | maxCellsPerAxis | Other |
|---|---|---|---|
| Draft | 8 | 96 | regularized collision, updateEvery 8 |
| Medium (default) | 16 | 192 | cumulant, Smagorinsky, updateEvery 4 |
| High | 32 | 256 | updateEvery 2 |
| Ultra | 64 | 384 | D3Q27, WALE, updateEvery 1 |

Changing any field switches the preset to Custom.

## 3. Reading the diagnostics ("how good is it")

`CFDDiagnostics` (`cfd.h:70`), shown in the "CFD quality (live)" section of the aero panel:

| Field | Meaning | Healthy |
|---|---|---|
| `gridCells`, `dx`, `dtLattice` | Actual grid after caps | — |
| `maxLatticeMach` | Largest local lattice Mach | < 0.3; < 0.15 for good accuracy |
| `massDrift` | Relative change in total mass | Near 0. Steady growth means leaking or diverging boundaries |
| `coarseDelta` | Force difference vs the 2× coarser shadow grid | Small. A large value means the grid is not converged |
| `richardsonError` | Richardson-extrapolated error estimate from the two grids (order p ≈ 2): (F_fine − F_coarse)/(2^p − 1) as a fraction | < 5 % is good |
| `gpuMsPerStep`, `cpuWaitMsPerStep` | Cost | CPU wait > 0 means the GPU is the bottleneck |
| `stepsRun`, `diverged` | Health | `diverged` true: lower latticeMach, use cumulant/regularized, or turn LES on |

The per-part comparison (`PartForceComparison`) shows the fast force, the CFD force and the % difference. Use it
together with the research table in `docs/PHYSICS.md` §9: a 30 % gap on a Draft grid says more about the grid
than about the fast model (LBM on an Ahmed body: 32.5 % error coarse, 4.7 % fine).

## 4. Training in full mode

In the experiment JSON:

```json
"aero": { "model": "full", "cfd": { "preset": "draft" }, "toggles": { "gyro": true } }
```

or override from the CLI with `pwcli --train exp.json --aero fast|full`. In EVOLVE, pick it from the aero model list. Missing keys fall back
to the defaults, so old experiments load unchanged (as fast).

Full mode is about **3000× slower** than fast (measured below). Extra CLI flag: `--cfd-preset draft|medium|high|ultra`. A practical workflow:

1. Train in **fast** to get a controller that works.
2. Fine-tune a few generations in **full / Draft or Medium** to adapt to interaction effects the fast model misses.
3. Check the result in FLY with **full / High**, and watch the convergence estimate.

## 5. When to use which

| Situation | Use |
|---|---|
| Conventional aircraft in cruise, attached flow | fast (a few % on lift) |
| Large flaps, low aspect ratio, high α, separated flow | full |
| Prop wash over wings and tails, ducts, bodies in the wake | fast with the slipstream toggles for training, full to check |
| Bluff CAD bodies at low speed | full (Newtonian panels have no good error bound here) |
| Long evolutionary runs | fast |

## 6. Measured results (Apple M4; measured on the earlier Swift build of the same solver, not re-run on C++)

**Solver validation** (`PW_FLOW_VALIDATE=1 pwcli --selftest flow.validate`, CFD builder's runs; GPU shared, timings noisy):

| Case | Grid | Result | Reference |
|---|---|---|---|
| Sphere, Re 1.3e5 | 8 cells/D | C_D 0.926 (0.08 ms/LBM step) | ≈ 0.47 |
| | 16 cells/D | C_D 0.786 (0.58 ms/step) | |
| | 24 cells/D | C_D 0.704 (1.63 ms/step) | |
| | 32 cells/D, D3Q27 + WALE | C_D 0.575 (4.99 ms/step) | |
| Cube, face-on | 16 cells/side | C_D 1.41 (1.16 in a larger domain: blockage) | ≈ 1.05 |
| NACA0012, AR 2, ±6° | 20 cells/chord | lift slope 0.79–0.92 /rad, C_D 0.12 | 2.60 /rad (Helmbold) |
| Actuator disk T = 10 N, R = 0.15 m | | 9.0–9.2 m/s through the disk | 7.60 m/s momentum theory |
| Fine vs 2× coarse shadow | sphere 12 cells/D | coarseDelta 41 %, Richardson 13.6 % | |

Drag converges toward experiment as the grid is refined; lift is badly under-predicted because the boundary layer
is not resolved (this was before the wall model and the other §7 changes).

**Fast vs CFD per part** (`pwcli --aero-compare Trainer --speed 30 --alpha 4 --seconds 1 --cfd-preset P`;
craft pinned, throttle 0; totals over non-rotor parts; Fx = −drag, Fy = lift):

| Preset | grid (effective dx) | CFD total Fx / Fy (N) | fast Fx / Fy (N) | coarseΔ / Richardson | wall time for 1 s |
|---|---|---|---|---|---|
| Draft | 96×71×71 (38 cm) | −5858 / 511 | −593 / 6820 | 53 % / 18 % | 3.1 s |
| Medium | 192×140×140 (19 cm) | −2995 / 4261 | −593 / 6820 | 91 % / 30 % | ~60 s |
| High | 256×187×187 (14 cm) | −2496 / 1661 | −593 / 6820 | 100 % / 33 % | ~4 min |

Medium per part: wings 1535–1573 N lift each vs 2488 fast (−33 %); ailerons −44 %; stabilator −8 %; the fuselage,
spinner, fin and wheels carry 5–10× the fast drag (they are a few cells across, so they are stair-stepped bluff
bodies, and the fast model gives wheels no drag at all). High is not better than Medium after 1 s: the flow had not
developed (the convergence readouts say so). **Conclusion: at these grids CFD is not more accurate than the fast
model for an attached-flow trainer**; it is a qualitative interaction model (wakes, blockage, ground).

Ducted rocket at hover (`pwcli --aero-compare examples/crafts/ducted-rocket.json --throttle 0.7 --alt 20 --cfd-preset
medium`, 91×125×91 at 6.25 cm): total non-rotor force fast −94.8 N (down) vs CFD −66.5 N (−30 %): the two lift
motors (bodies in the jet) −36.9/−54.5 N fast vs −19.4/−25.4 N CFD; the 8 duct shell panels carry 2.6–6.9 N each in
CFD (radial loads that mostly cancel) vs ≤ 0.33 N fast; the fixed vanes 0.87 N fast vs 0.85–1.09 N CFD. It ran at
0.014× real time (72.7 s wall for 1 s).

**Training throughput** (hover-ducted-rocket reduced to population 8, 1 episode of 3 s, 4 workers, 5 generations):
fast 790–1170 sim-s/s; full/Draft 0.3 sim-s/s (405 s wall in total). The full experiment
(population 48, 2 × 20 s episodes) runs at 1000–1750 sim-s/s in fast (about 1 s for 5 generations) and would take
about 3.5 h per generation in full/Draft.

## 7. Solver rework (accuracy and speed; not yet re-measured)

Why the old solver flew slowly in full mode (Trainer, 40 m/s, 4°: CFD drag 9887 N / lift 641 N on Draft vs
1048 / 12154 fast): the part SDF grids were capped at 64 cells per axis with one isotropic cell size, so a 10 m wing
got 17 cm cells and its 18 cm thickness disappeared (an inflated sub-cell slab, no camber, no thickness); the main
wing had 4 cells per chord at the Draft dx of 38 cm; the domain was a sphere-radius box, so a flat craft wasted
most cells above and below; and no wall model. Changes (`shaders/flow/lbm_common.slang`, `src/flow/src/lbm.cpp`,
`src/flow/src/part_sdf.cpp`):

- **Geometry.** Part SDFs are anisotropic (cell size per part axis, >= 10 cells across short axes, up to 192 per
  axis / 1.5M cells), so wings keep their real thickness and camber (`flow.sdf-thin-wing`). Only open sheets and
  plates under 0.3 lattice cells get a core (0.15 dx) so link sampling cannot miss them; closed bodies keep their
  true volume (`LBMAccuracy`, all options on by default).
- **Walls.** Interpolated (Bouzidi) bounce-back on refined wall crossings. Near-wall cells keep their last
  post-collision set in a wall-slot buffer, so the q >= 0.5 branch is exact and a link crossing a sheet thinner than
  a cell (fluid on both sides) reflects correctly. Log-law wall model: the first fluid cell gets the eddy viscosity
  ν_w = u_τ² y / u_t that makes its wall stress ρ u_τ² (κ 0.41, E 9.8; only for y+ > 11).
- **Resolution where it matters.** dx = min(1/cellsPerMeter, chord/16) with the main-wing chord taken from the
  largest plate-like part. The box keeps every face at least the bounding radius from the CoM: a box hugging the
  body's extents blocked ~16 % of a cube's cross-section and tripled its drag. The cell budget still applies, so Draft
  stays coarse; Medium gives about 16 cells per chord on the Trainer. True local refinement (nested multi-resolution
  blocks with coarse/fine coupling) is **not implemented**: the chord-targeted uniform grid is the current answer.
- **Forces.** Momentum exchange (Galilean invariant) per wall link, in lattice momentum per step:
  F = F_lat ρ dx⁴/dt², T = T_lat ρ dx⁵/dt² with the lever arm from the CoM node (the domain is centred on the CoM
  passed to `submit`), averaged over the steps of the update. CraftSim adds these to the CoM force/torque.
- **Speed.** One population buffer with esoteric-pull streaming (Lehmann 2022) fused with collision: one kernel per
  LBM step (was collide + stream with two buffers, four passes over the populations). Populations stored as fp16
  ((f − w)·2¹⁵, fp32 arithmetic) when the device supports 16-bit shader types (D3D12 SM 6.2, e.g. RX 6700 XT;
  Metal always), else fp32; `PW_FLOW_FP32=1` forces fp32. SoA layout, 64-thread 1D groups, macro fields written only
  where the next step needs them (every cell on the last step), lattice-Mach/NaN checks reduced per wave. FLY sets
  `LBMSolver::nonBlockingCollect`: collect never waits for the GPU (it keeps the previous forces while the GPU is
  busy).
- **Tests.** The `flow.*` references are the old solver's numbers and are now printed for comparison only; the
  checks are physical bands.

## Screenshots

The app takes `--tab <name>`, `--command "<palette entry>"` (repeatable), `--size WxH`, `--screenshot <file>` and
`--quit-after <s>` (`src/app/main.cpp`), e.g. `--tab fly --command "Aero: toggle flow slice"`. The Swift-era
`--air-start`, `--select-part`, `--show-equations` and `--flow-viz` flags do not exist in the C++ app.
