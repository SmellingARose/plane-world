# Plane World: Full-flow model (GPU CFD)

The aero model is a switch: **fast** (strip wings, momentum props, actuator-disk slipstream, Newtonian panels;
see `docs/PHYSICS.md`) or **full** (a lattice-Boltzmann CFD solver on Metal). Both FLY and training
(`--train`, EVOLVE) can use either. Settings type: `AeroRunSettings` / `CFDSettings` in
`Sources/Core/Fidelity.swift`. Solver: `Sources/Flow/`. Contract and threading: `docs/FIDELITY.md`.

> **Status (measured, this build).** The Metal solver is live and wired end to end: FLY (Fast/Full switch, CFD
> inspector, live diagnostics, slice + particle overlay), `--train --aero full`, EVOLVE, and
> `--aero-compare` (per-part fast vs CFD table). Selftests `flow.*` and `fidelity.*` cover it.
> **Accuracy is poor at the grids that run at usable speed** (see §6): treat full-mode forces as qualitative
> unless the convergence readouts are small. If the backend is unavailable, **full** falls back to **fast** and
> the UI says why.

## 1. Method

- **Lattice-Boltzmann**, D3Q19 (default) or D3Q27 velocities, on a uniform grid of spacing dx.
- **Collision:** BGK, MRT (Hermite-basis: stress modes at ω, higher modes at 1.2) or regularized.
  **Cumulant is not implemented:** selecting it (the settings default) runs the regularized operator, and
  `LBMSolver.effectiveCollision` reports that. BGK is the cheapest and the least stable.
- **Turbulence (LES):** none, Smagorinsky (C_s default 0.17) or WALE. A real craft's Reynolds number is far too
  high to resolve, so leave LES on.
- **Moving, craft-following domain.** A **world-axis-aligned** box that translates with the craft's centre of
  mass (Galilean frame at the craft velocity; changes of velocity enter as a uniform body force). It is laid out
  on the first update from the craft size, the padding and the dominant flow direction (or the rotor wake when
  hovering), then coarsened to respect `maxCellsPerAxis` (the effective dx is in the diagnostics; the Draft
  Trainer runs at dx = 38 cm, not the nominal 12.5 cm). The settings inspector shows the effective dx under the
  resolution slider and turns it orange with a "capped by max cells/axis" note when the cap is what sets it.
- **Boundaries:** inflow faces hold the far-field velocity with a velocity sponge; the other faces are open
  pressure outlets with a density-only sponge (so mass is not exactly conserved: see `massDrift`).
- **Geometry** is voxelised every CFD update from the part transforms, so servo-deflected surfaces and wheels move.
- **Walls:** simple bounce-back or interpolated (Bouzidi-style) bounce-back (default, better for curved and
  off-grid surfaces).
- **Forces:** Galilean-invariant momentum exchange at wall links (populations taken relative to the rest state, so a
  part partly buried in another part does not feel the ambient pressure on its exposed side only), summed per part, to give a force and torque per part. These replace
  the fast wing, body and panel aero.
- **Propellers** are not meshed. Each one is an actuator-disk body force (thrust plus swirl in its spin sense),
  with thrust and torque from the fast momentum-theory model. So prop thrust is the same in both models; what CFD
  changes is how that wake interacts with the airframe.
- **Ground:** a moving-wall boundary at the ground's relative velocity when the domain reaches terrain.
- **Training:** each evaluation worker owns one CFD domain (`EvalWorker.applyAero`), on the scalar CraftSim
  (the SIMD-lane batch sim has no CFD call site, so `batchLanes` is forced to 1). `LBMDomainPool` (several domains
  in one command buffer) exists and is selftested, but the trainer does not use it yet.
- **Lag:** update k submits poses at substep k·N and collects at substep (k+1)·N (N = `updateEvery`), so the GPU
  runs while the CPU integrates; CFD forces are one update old.
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
| `maxCellsPerAxis` | 192 | Hard cap; the domain is coarsened to fit | Protects memory (19 or 27 floats × 2 per cell) |
| `padUpstream / padDownstream / padLateral` | 1.0 / 2.5 / 1.0 craft lengths | Domain size around the craft | Too small: blockage and reflected waves inflate forces. Too big: cells wasted |
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

| Preset | cellsPerMeter | maxCellsPerAxis | Other |
|---|---|---|---|
| Draft | 8 | 96 | regularized collision, updateEvery 8 |
| Medium (default) | 16 | 192 | cumulant, Smagorinsky, updateEvery 4 |
| High | 32 | 256 | updateEvery 2 |
| Ultra | 64 | 384 | D3Q27, WALE, updateEvery 1 |

Changing any field switches the preset to Custom.

## 3. Reading the diagnostics ("how good is it")

`CFDDiagnostics`, shown in the FLY CFD inspector:

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

or override from the CLI with `--aero fast|full`. In EVOLVE, use the aero-model switch. Missing keys fall back
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

## 6. Measured results (Apple M4, this build)

**Solver validation** (`PW_FLOW_VALIDATE=1 --selftest flow.validate`, CFD builder's runs; GPU shared, timings noisy):

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
is not resolved (no wall model yet).

**Fast vs CFD per part** (`PlaneWorld --aero-compare Trainer --speed 30 --alpha 4 --seconds 1 --cfd-preset P`;
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

Ducted rocket at hover (`--aero-compare examples/crafts/ducted-rocket.json --throttle 0.7 --alt 20 --cfd-preset
medium`, 91×125×91 at 6.25 cm): total non-rotor force fast −94.8 N (down) vs CFD −66.5 N (−30 %): the two lift
motors (bodies in the jet) −36.9/−54.5 N fast vs −19.4/−25.4 N CFD; the 8 duct shell panels carry 2.6–6.9 N each in
CFD (radial loads that mostly cancel) vs ≤ 0.33 N fast; the fixed vanes 0.87 N fast vs 0.85–1.09 N CFD. It ran at
0.014× real time (72.7 s wall for 1 s).

**Training throughput** (hover-ducted-rocket reduced to population 8, 1 episode of 3 s, 4 workers, 5 generations):
fast 790–1170 sim-s/s; full/Draft 0.3 sim-s/s (405 s wall in total). The full experiment
(population 48, 2 × 20 s episodes) runs at 1000–1750 sim-s/s in fast (about 1 s for 5 generations) and would take
about 3.5 h per generation in full/Draft.

## Screenshot / debug flags

`--tab fly --aero full --cfd-preset draft --flow-viz` opens FLY on Draft CFD with the slice and particles on.
`--air-start <m/s>` launches the craft 120 m above its spawn along body +x at that speed with all motors at 0.7
(a launch condition, not a trim). `--select-part <id>` selects a part for the EQUATIONS panel, and
`--show-equations` scrolls the sidebar to it. `docs/screens/fly-full.jpg` and `equations.jpg` were taken with
`--air-start 30 --select-part p8` on the Trainer (Draft: 96×71×71 grid, dx 38 cm, ~35 ms GPU per CFD step on the M4;
fast-vs-CFD |F| difference on the left wing was 33.6 % in that frame).
