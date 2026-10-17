# Fidelity contract: fast vs full aero, equations, new fast-model effects

This file is the contract that the four builders work against during the fidelity pass. The shared types
are in `Sources/Core/Fidelity.swift` (module PWCore). Any change to them has to be agreed here first.

## Status

| Item | State |
|---|---|
| `AeroModel`, `AeroRunSettings`, `CFDSettings` (+ presets), `CFDDiagnostics`, `FastAeroToggles` | defined, Codable with tolerant decode |
| `ExperimentDocument.aero` | defined, decoded, **not yet consumed** by the evaluator |
| `CraftSim.aeroModel / aeroBackend / fastToggles / equationCapture` | wired: `.full` replaces wing/body/panel aero with per-part CFD forces (`Sources/Physics/FullAero.swift`) |
| `AeroBackend`, `AeroDomainPool`, `AeroBackendRegistry` | defined |
| PWFlow `LBMSolver` / `LBMDomainPool` | implemented (Metal LBM); cumulant runs the regularized operator |
| `EquationID / EquationCatalog / EquationRecord / EquationCapture` | catalog complete (every case has formula, symbols and source); substepCore fills records on a requested substep (physics builder) |
| Fast-model effects gyro / pFactor / downwash / blockage / cadWash | implemented in `Sources/Physics/FastGaps.swift` (+ Slipstream.swift, PanelAero.swift), one selftest each, all gated by `slipstream && toggle` |

## Ownership

| Builder | Owns (may edit) | Delivers |
|---|---|---|
| **Physics (fast)** | `Sources/Physics/*` (not CraftSimBatch's digest paths), `EquationCatalog` in Fidelity.swift, new physics selftests | gyro, pFactor, downwash, blockage and cadWash (each behind its `FastAeroToggles` flag and only when `slipstream` is on), with a selftest for each; `EquationCapture` filling in substepCore; the `.full` call site in CraftSim |
| **CFD** | `Sources/Flow/*` | Metal LBM (D3Q19/27; BGK/MRT/regularized/cumulant; Smagorinsky/WALE), voxelisation from part poses, (interpolated) bounce-back walls, per-part momentum exchange, actuator-disk rotor sources, ground BC, inflow/outflow, a craft-following domain, diagnostics, slice/particle visualisation, `LBMDomainPool`, Flow selftests |
| **Training** | `Sources/Evolution/*`, `Sources/App/TrainCLI.swift`, `AppModel+Evolve.swift`, `Sources/App/Evolve/*` | `--train` and EVOLVE honour `experiment.aero` (`--aero fast|full` CLI override); `.full` lanes share one `AeroDomainPool` per worker |
| **UI/Docs** | `Sources/App/*` (except the training files above), `docs/*`, README | Aero-model switch in FLY and EVOLVE, a CFD settings inspector (presets plus every field), a diagnostics readout, a flow slice overlay, the EQUATIONS panel, a status bar (sim rate, model, fps), tooltips and shortcut hints; `docs/PHYSICS.md` (all equations, sources, research table) |

The architect owns `Fidelity.swift` and this file. A builder that needs a change files it here.

## Invariants

- The fast path stays untouched when `aeroModel == .fast`. The slipstream-off digest `77acda15065ef25b` must be
  bit-identical, so every new effect is gated by `slipstream && toggle`. The slipstream-on digest `574c741598910e2d`
  can change only when a new effect is intentional. The physics builder updates that constant and records the reason.
- No allocations per substep. That covers the `.full` path too: `submit` and `collect` write only into buffers
  allocated during `configure`. `substepCore` stays `@inline(never)`.
- Put the `.full` call before or after `substepCore`'s aero block, behind a single branch. Do not let it pull
  closures into substepCore.

## The `.full` step (CraftSim)

1. At load (or on switching to `.full`), build `[AeroPartGeometry]` from `PartMeshFactory`/hull and call
   `backend.configure`. On failure, fall back to `.fast` and surface the error string in the UI.
2. Each CFD update (every `cfd.updateEvery` substeps), fill the preallocated `AeroPartPose` and `AeroRotorSource`
   buffers, then call `submit`. Rotor thrust and torque come from the existing momentum-theory prop model, which
   acts as the actuator-disk body force.
3. On the next substep, `collect`. If it returns false, keep the last forces. Per-part `ForceTorque` replaces
   the wing-strip, panel and body aero. Prop thrust and torque still come from the prop model, because the
   blades are not meshed. `sampleVelocity` feeds servo hinge loads and the airspeed sensors.
4. For the comparison rows, the fast model is evaluated on the UI-rate capture step only, and the result goes
   into `PartForceComparison`.

## Threading

- One `AeroBackend` per CraftSim, called only from that sim's thread.
- `submit` encodes and commits a command buffer without waiting. `collect` waits on the previous buffer, so the
  GPU work for step n overlaps the CPU physics for step n. Forces lag by one CFD update, and the docs state this.
- Training uses one `AeroDomainPool` per worker. Every lane `submit`s, then `flush()` commits all domains in one
  command buffer, then every lane `collect`s.
- `EquationCapture` has a single writer (the sim thread). The UI calls `request(part:)` at about 10 Hz and reads
  `records[0..<count]` after `ready` turns true.

## Units (CFD)

dx = 1/cellsPerMeter. The lattice speed is set so the reference speed U_ref (max of airspeed and slipstream
estimate) maps to `latticeMach·c_s` with c_s = 1/√3. That gives dt = latticeMach·c_s·dx / U_ref, and
ν_lat = ν·dt/dx². When ν_lat < ~1e-5 (high Re), LES has to be enabled. The diagnostics report max lattice Mach,
and when it exceeds `maxMach` the run is flagged.

## Filed changes (physics builder)

- `EquationID.bodyDrag` appended **after** `cfdMomentumExchange` (raw values of earlier cases unchanged): the projected-area
  drag of primitive bodies had no equation id.
- Slipstream-on digest is now `b99e6b32309ca982` (`PhysicsSelfTests.expectedDigestSlipstream`). The reason is that the five new
  effects are on by default (it was `2d054c3807bf213e` until the integrator's downwash fixes: the group circulation
  Γ = L/(ρVb') now uses the local stream including rotor wakes, and the induced velocity fades out within ±1.5 chords
  of the bound vortex; without that, crossed exhaust vanes in the ducted rocket fed each other and diverged to NaN in
  training). With every `FastAeroToggles` flag off, the digest is still the old `574c741598910e2d`; this is asserted as
  `expectedDigestSlipstreamLegacy`. The slipstream-off digest `77acda15065ef25b` is unchanged.
- `blockage` also covers coaxial swirl recovery: a downstream rotor inside another rotor's wake takes over that wake's swirl.
  Angular-momentum flux is conserved, so a counter-rotating pair leaves almost no swirl. This fixed the ducted-rocket yaw of
  12 rad/s in `physics.prop-counter-rotation`.
- That test also drove every output to 1, servos included, so the vanes sat at full deflection and the rocket tipped over. This
  was the HEAD failure. Servos are now held at 0 and the lift motors at 1.
- Hot-path note: substepCore became big enough that Swift stopped folding `Vec3d` array literals such as `.act([1, 0, 0])`,
  which then cost one heap allocation per substep. Use `Vec3d(1, 0, 0)` in the physics hot paths.
- The `.full` call site is done (integrator): `Sources/Physics/FullAero.swift`; comparison rows are `.cfdMomentumExchange`
  records whose values 0–5 hold the fast per-part force/torque. Equation docs live in `docs/PHYSICS.md` (no separate EQUATIONS.md).
