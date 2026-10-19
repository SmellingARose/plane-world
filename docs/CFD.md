# Plane World: Full-flow model (GPU CFD)

The aero model is a switch: **fast** (strip wings, momentum props, actuator-disk slipstream, Newtonian panels;
see `docs/PHYSICS.md`) or **full** (a lattice-Boltzmann CFD solver on the GPU: Metal on macOS, D3D12 on
Windows; Slang shaders in `shaders/flow`). Both FLY and training (`pwcli --train`, EVOLVE) can use either.
Settings: `CFDSettings` (`src/core/pw/sim/cfd.h:45`), presets in `CFDSettings::fromPreset`
(`src/core/src/sim/cfd.cpp:31`), diagnostics `CFDDiagnostics` (`cfd.h:74`). Backend interface `AeroBackend`
(`cfd.h:124`); solver `pw::flow::LBMSolver` (`src/flow/pw/flow/lbm.h:73`, `src/flow/src/lbm.cpp`). CraftSim glue:
`src/core/pw/sim/full_aero.h`, `src/core/src/sim/full_aero.cpp`.

> **Status.** The GPU solver is wired end to end: FLY (aero model list, CFD settings
> panel, live diagnostics, slice + particle overlay), `--train --aero full`, EVOLVE, and
> `pwcli --aero-compare` (per-part fast vs CFD table). Selftests `flow.*` and `fidelity.*` cover it.
> The solver uses local refinement (nested levels), a blockage-sized outer box with velocity-inlet / convective-outlet /
> free-stream faces, and a slip-velocity log-law wall model (§6); measured results and open issues are in §7. Check the
> convergence readouts. If the backend is unavailable, **full** falls back to **fast** and the UI says why.

## 1. Method

- **Lattice-Boltzmann**, D3Q19 (default) or D3Q27 velocities, on nested grid levels (local refinement, §6): the
  finest level (spacing dx) holds the craft, each coarser one doubles dx out to the outer box.
- **Collision:** BGK, MRT (Hermite-basis: stress modes at ω, higher modes at 1.2) or regularized.
  **Cumulant is not implemented:** selecting it (the settings default) runs the regularized operator, and
  `LBMSolver::effectiveCollision()` (`lbm.h:92`) reports that. BGK is the cheapest and the least stable.
- **Turbulence (LES):** none, Smagorinsky (C_s default 0.17) or WALE. A real craft's Reynolds number is far too
  high to resolve, so leave LES on.
- **Moving, craft-following domain.** **World-axis-aligned** boxes that translate with the craft's centre of
  mass (Galilean frame at the craft velocity; changes of velocity enter as a uniform body force), laid out on the
  first update (§6): the outer box is sized by blockage (`blockageRatio`) and `padUpstream` / `padDownstream` craft
  lengths on the dominant flow direction (or the rotor wake when hovering); the finest box holds the posed craft
  plus a margin at dx = min(1/cellsPerMeter, main-wing chord / 32), and is laid out again (keeping the flow) when a
  part leaves it. All levels together stay within `maxCellsPerAxis`³ cells (dx is coarsened to fit); the effective
  dx is in the diagnostics. The settings inspector shows it under the resolution slider and turns it orange with a
  "capped by max cells/axis" note when the cap is what sets it.
- **Boundaries:** velocity inlet, pressure outlet with a convective velocity, free-stream lateral faces, and
  absorbing sponge layers outside the sized box (§6); mass is not exactly conserved (see `massDrift`).
- **Geometry** is voxelised every CFD update from the part transforms, so servo-deflected surfaces and wheels move.
- **Walls:** simple bounce-back or interpolated (Bouzidi) bounce-back (default) on the signed-distance wall
  position, plus a slip-velocity log-law wall model on the near-wall nodes (§6).
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
  in one command buffer, `lbm.h:175`) exists, is registered and selftested, but the trainer does not use it yet,
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
  (`cfd.h:122`, `lbm.h:30`), unless the domain is re-laid out (divergence, or a part left the finest box).
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
| `cellsPerMeter` | 16 | Finest-level resolution: dx = min(1/cellsPerMeter, main-wing chord / 32) | Cost ∝ fine cells × steps ∝ roughly (1/dx)⁴. The biggest single accuracy knob |
| `levels` | 3 (Draft 2, Ultra 4) | Grid levels, refinement ratio 2 (1 = uniform grid) | More levels: a large outer box for few cells. The finest level dominates the cost |
| `maxCellsPerAxis` | 192 | Cell budget: all levels together hold at most maxCellsPerAxis³ cells; the finest dx is coarsened to fit | Memory ≈ 19 or 27 × 2 bytes (fp16) or × 4 (fp32) + ~70 bytes per cell |
| `padUpstream / padDownstream` | 2 / 4 craft lengths | Outer box up / downstream of the craft (craft length = bounding diameter) | Too small: the inlet and outlet disturb the flow near the craft |
| `blockageRatio` | 0.03 | Largest craft frontal area / outer cross-section (at least one craft length each side) | Larger: tighter box, more tunnel-like blockage |
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

| Preset | cellsPerMeter | maxCellsPerAxis | levels | Other |
|---|---|---|---|---|
| Draft | 8 | 96 | 2 | regularized collision, updateEvery 8 |
| Medium (default) | 16 | 192 | 3 | cumulant, Smagorinsky, updateEvery 4 |
| High | 32 | 256 | 3 | updateEvery 2 |
| Ultra | 64 | 384 | 4 | D3Q27, WALE, updateEvery 1 |

Changing any field switches the preset to Custom.

## 3. Reading the diagnostics ("how good is it")

`CFDDiagnostics` (`cfd.h:74`), shown in the "CFD quality (live)" section of the aero panel:

| Field | Meaning | Healthy |
|---|---|---|
| `gridCells`, `levels`, `cells` | Outer (level-0) box, level count, cells of all levels | — |
| `dx`, `dxOuter`, `dtLattice` | Finest (craft) and outer cell size, finest time step, after the cell budget | — |
| `blockage` | Craft frontal area / outer cross-section (inside the sponge) | ≤ `blockageRatio` |
| `maxLatticeMach` | Largest local lattice Mach | < 0.3; < 0.15 for good accuracy |
| `massDrift` | Relative change in total mass | Near 0. Steady growth means leaking or diverging boundaries |
| `coarseDelta` | Force difference vs the 2× coarser shadow grid | Small. A large value means the grid is not converged |
| `richardsonError` | Richardson-extrapolated error estimate from the two grids (order p ≈ 2): (F_fine − F_coarse)/(2^p − 1) as a fraction | < 5 % is good |
| `gpuMsPerStep`, `cpuWaitMsPerStep` | Cost per CFD update (all levels) | CPU wait > 0 means the GPU is the bottleneck |
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

Full mode is orders of magnitude slower than fast (§7 has the cost per CFD update). Extra CLI flag: `--cfd-preset draft|medium|high|ultra`. A practical workflow:

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

## 6. How the solver works

Kernels: `shaders/flow/lbm_common.slang`; host: `src/flow/src/lbm.cpp`; part SDFs: `src/flow/src/part_sdf.cpp`.

### Grid levels (local refinement)

- **Nested boxes, refinement ratio 2.** Level 0 is the outer box; each finer level is a box inside its parent with
  half the cell size and half the time step (acoustic scaling: lattice velocities are the same on every level,
  ν_lat doubles per level). `levels` sets the count (Draft 2, Medium/High 3, Ultra 4; 1 = uniform grid); fewer are
  used when a level would already cover the outer box. A level steps once, then its child twice (recursively), so the
  finest level advances 2^(L-1) steps per level-0 step.
- **Finest level** = the posed craft (mesh bounding boxes of the parts plus rotor disks) turned by up to ±15° about
  each axis, plus a margin of max(6 cells, 0.1 craft length) and 0.25 craft lengths downstream. dx there is
  min(1/cellsPerMeter, main-wing chord / 32); if all levels exceed `maxCellsPerAxis`³ cells, dx is coarsened.
  Each coarser level adds max(6 own cells, a quarter of its child's largest extent) on every face (twice that
  downstream). Parts, rotors and forces live on the finest level only.
- **Re-layout.** When a part leaves the finest box (the craft turned more than the slack, or a part moved), the
  hierarchy is laid out again around the new pose and starts from the previous flow: `lbmRegrid` gives every new cell
  equilibrium populations at the (ρ, u) of the finest old level containing it (non-equilibrium parts re-develop within
  a few steps). Divergence still restarts from the far field.
- **Coarse/fine coupling** (Dupuis & Chopard 2003, Lagrava et al. 2012, on moments). The fine box's outer node layer
  ("ghosts") is rebuilt every fine step from (ρ, u, Π_neq, τ) records that the parent writes on the box surface,
  interpolated in space with 4-point cubic midpoint weights along the face (linear where the face ends) and linearly
  in time (first fine substep: mean of the parent's last two steps),
  with Π_f = Π_c τ_f / (2 τ_c) and τ_f − ½ = 2 (τ_c − ½) (equal physical viscosity, including the eddy viscosity).
  On the second substep the fine layers 1–3 inside the ghosts write band records and `lbmRestrict` rebuilds every
  parent node on the layer just inside the box from the coincident fine node's (ρ, u) and the (¼, ½, ¼)³-filtered
  Π_neq and τ of its 27 fine neighbours (Π_c = Π_f 2 τ_c / τ_f; with Smagorinsky, τ_c is at least the parent's own
  eddy viscosity at that strain); parent nodes deeper inside are idle and only receive the macro for slices, sampling
  and the mass check. Records live in the `aux` buffer in front
  of the wall slots, so the kernels keep the 8-buffer binding model on Metal and D3D12.
- **Storage.** One population buffer for all levels (per level SoA, esoteric pull), populations stored relative to the
  far-field equilibrium feq(1, u_s) (u_s = far-field velocity at layout, re-encoded by `lbmRescale` when it drifts by
  more than 0.02 lattice units or the time step changes), so the free stream is ~0 in fp16 and small pressure
  differences survive the 10-bit mantissa.

### Outer box and boundaries

- **Size.** Upstream `padUpstream` (2) and downstream `padDownstream` (4) craft lengths (bounding diameter D) from the
  craft along the dominant relative-flow axis (rotor wake in hover). The cross-section blocks at most `blockageRatio`
  (3 %) of the craft's frontal area (rasterised projection of the posed meshes) and leaves at least D on each side.
  An 8-cell sponge layer is added outside this box on every face, so the sponge never eats into it. The measured
  blockage is in the diagnostics.
- **Faces** (level 0): velocity inlet (u = u∞, ρ from the inward neighbour, so pressure waves leave); pressure outlet
  with a convective velocity (ρ = 1, u_b ← u_b − λ (u_b − u_nb), λ = outward normal speed; zero gradient where flow
  enters an outlet face, e.g. entrainment in hover); free-stream lateral faces (u = u∞, ρ from the neighbour). With no
  relative wind every face is an outlet.
- **Sponge**: behind inflow and lateral faces the velocity is relaxed toward u∞ (density kept); behind outflow faces
  the density is relaxed toward ρ0 (velocity kept), which pins the pressure level.

### Walls

- Interpolated (Bouzidi) bounce-back on refined wall crossings, exact across sub-cell sheets via the wall-slot buffer;
  Galilean-invariant momentum exchange per link (force and torque about the CoM node, finest-level units).
- **Log-law wall model (slip velocity).** Nodes within 1.5 cells of a wall (with a well-defined normal, |∇d| within
  20 % of 1) solve u_t / u_τ = ln(E y⁺)/κ for u_τ from the previous step's tangential velocity. In the log region
  (y⁺ > 11) their viscosity is ν_w = max(κ u_τ y, 0.01/3) and their wall links bounce back toward the tangential
  slip velocity u_s = u_t − u_τ² y / ν_w, so the wall stress is ρ u_τ² (for ν_w = κ u_τ y, u_s = u_t − u_τ/κ is the
  wall intercept of the log-law slope). The viscosity floor (τ ≥ 0.51) keeps the slip wall stable: without it the
  wall nodes ran at τ ≈ 0.5002 and blew up at the leading edge. Without the slip, a no-slip ramp over one cell is a
  boundary layer many times too thick that separates early (the NACA 0012 at Re 10⁵ kept C_L ≈ 0.1 at 6°). Below
  y⁺ = 11 the node is in the viscous sublayer: no slip, molecular viscosity.
- **Part SDFs**: anisotropic grids, exact distances 2.5 cells out from the surface (so every near-wall node and link
  crossing sees the true surface), inside/outside from ray parity along all three axes (majority vote).

## 7. Measured results (Apple M4, Metal, fp16 storage; `pwcli --selftest flow. --verbose`)

Before = the uniform-grid solver (commit 11980ae: one craft-fitted box, faces ≥ the bounding radius from the CoM,
16 cells per diameter / 20 per chord, no-slip wall model). After = this solver, default settings (3 levels, 32 cells per
diameter / chord on the finest level, blockage-sized box, slip wall model).

| Case | Before | After | Reference |
|---|---|---|---|
| Sphere, Re 1.3·10⁵ (laminar separation; wall model off) | C_D 0.590 | C_D 0.497 | ≈ 0.47 |
| Sphere, Re 10⁶ (turbulent; default wall model) | — | C_D 0.103 | ≈ 0.1–0.2 (supercritical) |
| Cube, face-on, Re 1.3·10⁵ | C_D 1.529 | C_D 0.823 | ≈ 1.05 |
| NACA 0012, AR 2, ±6°, Re 10⁵ | C_L +0.148 / −0.090, slope 1.14 /rad | C_L +0.393 / −0.429 (9 % asymmetric), slope 3.93 /rad | Helmbold 2.60 /rad |
| Actuator disk T = 10 N, R = 0.15 m | 7.42 m/s | 7.58 m/s | 7.60 m/s (momentum theory) |
| Sphere Re 200, 1 vs 3 levels (`flow.refinement`) | — | C_D 0.929 vs 0.926, 489 k vs 92 k cells, 35.7 vs 6.5 ms/update | ≈ 0.77 (8 cells/D) |

Cost per 4 ms CFD update (the real-time budget at `updateEvery` 4): sphere 153 ms (695 k cells), cube 172 ms, wing
319 ms (1.26 M cells), actuator disk 13 ms; the same 32-cell wing on one uniform grid of the same outer box is 24 M cells
and 10.4 s per update (33× more).

**Wing, what is and is not settled.** The old lift asymmetry had two causes, both fixed: part SDFs kept exact
distances only one lattice cell from the surface (beyond that the grid held a "far" value, so near-wall classification
and crossings depended on how the wing sat in the SDF grid; flipping the wing changed C_L(−6°) from −0.09 to −0.17), and
a domain whose lateral faces were open pressure outlets 2.6 chords away (lift fell by 40 % over the run). The 64-bit
fixed-point force sum also rounded small negative per-wave sums wrongly (fixed). The remaining asymmetry is not a sign
error: C_L at α = 0 is ±0.00x, but moving the wing by a third of a cell changes C_L at 6° by up to ±0.1 through the
wall model (with the wall model off the placement effect is a few %). That placement sensitivity, not the refinement
coupling, is why ±6° (two different placements) differ by 9 % and why the slope overshoots: a uniform 24 M-cell run of
the same wing gives C_L 0.306 (slope 2.9 /rad), a 3-level run 0.39, and shifting the wing 2 mm moves either by as much.
At 16 cells per chord, where placement matters less, 1 and 3 levels agree to 0.5 % (C_L 0.192 vs 0.1915); at Re 10³
(wall model inactive) they agree to 3 % at 32 cells per chord. The slope target (≥ 2.0 /rad) is met; the 5 % symmetry
target is not, and the test band is wide (asymmetry < 30 %) until the wall model's placement dependence is removed.

**Trainer** (`pwcli --aero-compare Trainer --speed 30 --alpha 4 --seconds 1`, Medium): 3 levels (255×97×124 @ 35 cm, 147×85×131 @
17.6 cm, 159×81×173 @ 8.8 cm; 6.9 M cells; the cell budget caps the finest dx at 8.8 cm, ≈ 17 cells per chord), CFD
total Fx / Fy −2340 / 5679 N vs fast −593 / 6820 N (before: −2995 / 4261 N on the uniform 19 cm grid); 956 ms per
4 ms update, i.e. 0.004× real time. **Real time at 32 cells per chord is not reached**: it needs the High/Ultra
budgets for the dx and roughly 250× the throughput; the convergence shadow readout (`coarseDelta`) on this case is not
meaningful yet (the half-resolution shadow is far too coarse for the Trainer's thin parts).

## Screenshots

The app takes `--tab <name>`, `--command "<palette entry>"` (repeatable), `--size WxH`, `--screenshot <file>` and
`--quit-after <s>` (`src/app/main.cpp`), e.g. `--tab fly --command "Aero: toggle flow slice"`. The Swift-era
`--air-start`, `--select-part`, `--show-equations` and `--flow-viz` flags do not exist in the C++ app.
