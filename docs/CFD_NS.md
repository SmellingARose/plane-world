# Plane World: Navier–Stokes finite-volume CFD (and the OpenFOAM reference)

Plane World has three ways to compute aerodynamic forces. They are separate options, and this page covers the
second and third:

| | **Fast (analytic)** | **CFD · Lattice Boltzmann** | **CFD · Navier–Stokes FV** | **OpenFOAM reference** |
|---|---|---|---|---|
| What it is | Strip-theory wings, momentum props, slipstream, Newtonian panels ([PHYSICS.md](PHYSICS.md)) | Kinetic (Boltzmann) solver on a lattice, LES ([CFD.md](CFD.md)) | Incompressible Navier–Stokes, finite-volume projection method, URANS k-ω SST (this page) | OpenFOAM `pimpleFoam` / `simpleFoam`, k-ω SST, body-fitted snappyHexMesh mesh, offline |
| Where | FLY, EVOLVE, training | FLY, EVOLVE, training (GPU) | FLY, `pwcli --aero-compare` (GPU) | `pwcli --openfoam-export` + your OpenFOAM installation |
| Cost | microseconds per step | the fastest CFD here; real time on coarse settings | more per cell than the LBM, fewer and larger time steps; real time at Draft (Trainer ≈ 4 ms GPU per update) | minutes to hours per flight condition on a workstation |
| Expected accuracy | good in attached flow, wrong in separation and interference | with grid levels: sphere C_D 0.50, cube 0.82, AR-2 slope 3.93 /rad, which overshoots Helmbold and is 9 % asymmetric (see CFD.md §6) | sphere C_D(Re 100) +3 %, cavity within 0.01 of Ghia, plate skin friction +3-12 %, AR-2 lift slope ~83 % of Helmbold at 20 cells/chord | the most accurate here when the mesh is converged (prism layers, y+ checked) |
| Use it for | flying, training, design sweeps | seeing the flow live; CFD in the loop | numbers you want to trust from inside the app: lift, skin friction, separation | a reference to check the other three |

The NS backend is `pw::flow::NSSolver` (`src/flow/pw/flow/ns.h`, `src/flow/src/fv_ns.cpp`, kernels
`shaders/flow/fv_ns.slang`), a separate `sim::AeroBackend` next to the LBM's `LBMSolver`. It runs on Metal (macOS)
and Direct3D 12 (Windows) through the same pwgpu compute layer. The OpenFOAM reference is `pw::flow::openfoam`
(`src/flow/pw/flow/openfoam.h`): it writes text files and runs OpenFOAM as a subprocess. Nothing from OpenFOAM is
linked or copied, so its GPL does not apply to Plane World.

## 1. Equations

Incompressible Reynolds-averaged (or filtered) Navier–Stokes in the frame moving with the craft:

    div u = 0
    du/dt + div(u u) = -grad p + div((nu + nu_t) grad u) + f_rotor

with u the velocity relative to the domain frame, p the kinematic pressure (pressure / rho) and nu_t the eddy
viscosity from the turbulence model. The `(grad u)^T` part of the eddy stress is dropped; it vanishes for constant
nu_t and is commonly omitted. The frame translates with the craft's centre of mass at the craft velocity. When that
velocity changes by dV, the stored field gets the exact Galilean shift u -= dV, the same as the LBM's
uniform body force but applied in one step. Air is treated as incompressible, which holds below about Mach 0.3.

## 2. Discretisation

- **Grid:** a uniform staggered MAC grid (Harlow & Welch 1965). Velocity components sit on cell faces; pressure and
  the turbulence scalars sit at cell centres. There are two ghost layers. The interior dimensions are rounded up to
  multiples of 8 for the multigrid.
- **Domain:** the same craft-following, world-axis-aligned box as the LBM. Every face is at least the craft's
  bounding radius from the CoM, plus padding in craft lengths. dx = min(1/cellsPerMeter, main-wing chord /
  `chordCells`) within the `maxCellsPerAxis`³ budget.
- **Time integration:** each time step is a two-stage SSP Runge–Kutta (Heun) step, and every stage is a full
  fractional-step projection (Chorin 1968; Kim & Moin 1985):
  1. explicit momentum: u* = a u^n + b (u + dt L(u)), where L is advection + diffusion + sources;
  2. immersed-boundary forcing (§4);
  3. boundary conditions (§5);
  4. pressure Poisson: lap p = div u* / (b dt);
  5. projection: u = u* - b dt grad p.

  Solving each stage with its own b dt keeps p the physical pressure in both stages. That gives a consistent
  warm start and the correct surface pressure. An earlier version without this read half the pressure, and sphere
  C_D came out 40 % low.
- **Advection:** conservative finite-volume fluxes. The transported velocity is reconstructed with the TVD van Leer
  limiter (default, van Leer 1974), QUICK (Leonard 1979) or central differences (`NSOptions::advection`).
  Turbulence scalars use first-order upwind with the non-conservative correction.
- **Diffusion:** second-order central differences. nu + nu_t is averaged onto the control-volume faces and edges.
- **Time step:** dt = min(CFL dx / max|u|, 0.1 dx² / (nu + max nu_t)), with CFL = 0.5. max|u| and max nu_t are
  measured on the GPU during the previous update. The explicit-diffusion factor is 0.1 rather than the
  forward-Euler bound of 1/6: the Re = 100 cavity oscillated at 0.15. One CFD update covers the physics interval
  in n equal steps, capped at 48.
- **Pressure solver:** cell-centred geometric multigrid V-cycles (Brandt 1977; Trottenberg, Oosterlee & Schüller
  2001):
  - red-black Gauss–Seidel smoothing, 2 sweeps before and 2 after each coarse correction;
  - residual restriction by averaging, trilinear prolongation;
  - semi-coarsening of any axis that can no longer halve;
  - a single-threadgroup coarsest solve (60 sweeps; the mean is removed for pure-Neumann problems such as the
    cavity);
  - inline boundary conditions: Dirichlet p = 0 on outflow faces, Neumann elsewhere.

  Each solve is warm-started from the last pressure. The GPU measures ||r||∞ / ||b||∞ after every solve, and the
  V-cycle count adapts (1-10) to keep that ratio under `mgTolerance` = 1e-3. The adjustment lags one update, so the
  solver never waits for a readback.

## 3. Turbulence (URANS by default)

The NS backend integrates in time, so with a RANS model it is URANS. The models (`NSOptions::turbulence`) are:

- **k-ω SST** (Menter, Kuntz & Langtry 2003). This is the default. It has blended F1 / F2 functions, production
  limited to 10 β* k ω, the cross-diffusion term, and nu_t = a1 k / max(a1 ω, S F2).
- **Spalart–Allmaras** (1992, without the ft2 term).
- **SST-DDES** (Gritskevich, Garbaruk, Schütze & Menter 2012). The k destruction term uses l_DDES = l_RANS - f_d
  max(0, l_RANS - C_DES Δ), with C_DES blended 0.78 / 0.61 by F1. It switches to LES only where the grid resolves
  the eddies, so on coarse grids it behaves like SST.
- **LES:** Smagorinsky (C_s 0.17, mixing length capped at κ d) or WALE (C_w 0.5). These are available but not the
  default, because they are under-resolved on in-app grids.
- **Laminar.**

Source terms are point-implicit: the destruction terms go in the denominator. k, ω and nu~ are clipped to positive
values, and nu_t ≤ 1e5 nu. The wall distance is the scene signed distance (parts and ground).

**Automatic wall treatment.** In the first fluid layer, ω blends the viscous-sublayer and log-layer values:
ω = sqrt(ω_vis² + ω_log²), with ω_vis = 6 nu / (β1 y²) and ω_log = u_τ / (sqrt(β*) κ y). Where y+ > 5, k (and nu~
for SA) are blended toward their log-layer equilibrium values: k = u_τ² / sqrt(β*) and nu~ = κ u_τ y, fully so from
y+ = 30. u_τ comes from the law of the wall (§4). Inside bodies, k is copied from the fluid side (zero gradient).

## 4. Immersed boundaries, wall functions and forces

- **Geometry:** every update, each cell gets the signed distance φ to the posed parts. φ is sampled from the parts'
  anisotropic signed-distance grids (`PartSDF`, shared with the LBM; read-only) and from the ground plane. Sheets
  and sub-cell plates are inflated to a core at least 1.5 cells thick.
- **Direct-forcing IBM** (Fadlun et al. 2000; Balaras 2004):
  - faces inside a body (φ_face ≤ 0) take the body velocity, v_lin + ω × r;
  - faces in the first fluid layer (0 < φ < dx) are reconstructed along the wall normal from the velocity at a probe
    one cell further out. The normal component is linear. The tangential component follows **Reichardt's law of the
    wall**: u_τ is solved from the probe by Newton iteration, then u_t(φ) = u_τ u+(φ u_τ / nu).

  Reichardt's law is linear in the viscous sublayer and logarithmic beyond, so the same rule acts as a no-slip
  condition on fine grids and as a wall function on coarse ones. Domain-boundary faces that lie inside a body also
  take the body velocity. Before this rule, the ground crossing the inlet acted as a mass source, which made a wall
  jet and doubled the plate's skin friction.
- **Forces per part:** the surface integral of pressure and wall shear over each part, F = Σ (-p n + τ_w t)
  δ_ε(φ) dV. It uses a smoothed delta function (ε = 1.5 dx) on the signed-distance band and a surface point
  x_s = x - φ n.
  - The wall pressure is extrapolated linearly from probes 1.5 and 2.5 cells out.
  - The wall shear comes from a quadratic profile through the wall and both probes (laminar), blended over
    y+ = 5-30 into the law-of-the-wall u_τ² (turbulent).
  - Torque is r × dF about the CoM. Forces are averaged over the NS steps of the update.

  As a cross-check, the GPU also accumulates the momentum the IBM forcing removes from the fluid per part (Uhlmann
  2005); `PW_NS_DEBUG=1` prints both. On the Re = 100 sphere the surface integral gives C_D 1.125 and the forcing sum
  gives 1.23, against a reference of 1.09. The surface integral is the reported force.
- **Rotors:** actuator disks as in the LBM: axial thrust reaction plus a swirl body force from the shaft torque,
  over a two-cell-thick hat.

## 5. Boundary conditions

The type of each domain face comes from the relative wind direction:

- **velocity inlet** (outward normal · u < -0.2 |u|): Dirichlet free stream, with free-stream turbulence
  k = 1.5 (I U)², nu_t = nu (so ω = k / nu_t), or nu~ = 3 nu for SA;
- **convective outflow** (> 0.2 |u|): du/dt + U_c du/dn = 0 on the boundary-normal velocity, zero gradient for
  the rest, p = 0;
- **free-stream slip** on lateral faces: the normal component is the free-stream value, the tangential components
  have zero gradient;
- **open** (p = 0, zero gradient) on every face when there is no wind, for hover and the rotor wake.

The ground is an immersed moving wall at -V_craft. The validation box mode (`NSSolver::configureBox`) also has
no-slip walls with a moving lid.

## 6. Validation (`pwcli --selftest ns. --verbose`, Apple M4, Metal)

| Test | Case | Result | Reference | Band |
|---|---|---|---|---|
| `ns.cavity-re100` | lid-driven cavity, 64², quasi-2D | max \|u − Ghia\| 0.0045, max \|v − Ghia\| 0.0082 | Ghia, Ghia & Shin 1982 | < 0.03 |
| `ns.cavity-re1000` | 128², t = 60 s | 0.0051 / 0.0099; u(centre) −0.0622 (Ghia −0.0608) | Ghia et al. 1982 | < 0.06 |
| `ns.flatplate-blasius` | laminar plate Re_L = 1e4 | C_F +26 %, local c_f(0.8 L) +15 % (+20 % at half resolution: converging) | Blasius 1.328 / sqrt(Re) | 35 % / 25 % |
| `ns.flatplate-sst` | turbulent plate Re_L = 2.6e6, first cell y+ ≈ 110 | SST C_F 0.00422 (+12 %), SA 0.00389 (+3 %) | Schlichting 0.455 / (log Re)^2.58 = 0.00377; 1/7 law 0.00387 | 20 % (SST), 30 % (SA) |
| `ns.sphere-re100` | 16 cells/D, laminar | C_D 1.125 | 1.09 (Schiller–Naumann; exp.) | 0.9-1.4 |
| `ns.sphere-re1000` | 16 cells/D, laminar | C_D 0.39 | 0.46-0.47 | 0.33-0.7 |
| `ns.sphere-drag` | Re 1.3e5, URANS SST | C_D 0.18 | fully turbulent BL ≈ post-critical 0.1-0.25 (subcritical exp. 0.47) | 0.08-0.6 |
| `ns.cube-drag` | face-on cube, Re 1.3e5, SST | C_D 0.87 | ~1.05 | 0.7-1.6 |
| `ns.wing-lift-slope` | NACA 0012 AR 2, ±6°, 20 cells/chord, SST | slope 2.16 /rad (C_L ±0.21/0.24), C_D 0.036 | Helmbold 2.60 /rad (LBM, 3 levels: 3.93) | 0.5-1.3 × Helmbold |
| `ns.actuator-disk` | T = 10 N, R = 0.15 m, hover | v_disk 10.0 m/s | momentum theory 7.6 m/s | 0.6-1.4 × |
| `ns.turbulence-models` | every model on the sphere | all stable (C_D 0.22-0.23 after 0.1 s) | | finite |
| `ns.craftsim-full` | Trainer in CraftSim, NS draft | drag opposes motion, positive lift, finite | | |
| `ns.openfoam-case` | case export + both force-file formats | complete case; parsed exactly | | |

Cost on an Apple M4: about 10-13 ms per NS step (both stages) on the 0.87 M-cell sphere grids, 2-3 ms on 100 k
cells, and 0.6 / 0.9 ms for the 16 k / 65 k-cell cavities (dispatch-bound). All 15 `ns.*` tests take about 2 minutes. In FLY at Draft (64³ cells max) the Trainer costs about
4 ms of GPU per CFD update.

**Reading the numbers.**

- The cavity tests check the core discretisation: momentum, projection and multigrid. They agree with Ghia to
  better than 1 % of the lid speed.
- The turbulent plate checks SST / SA with the automatic wall treatment. Both are within the scatter of the
  classical correlations.
- The laminar plate is high because the leading edge sits on the inlet face and the finite domain speeds up the
  core. It converges with resolution.
- The sphere at Re 1.3e5 shows what a fully turbulent RANS model does without transition. The boundary layer
  stays attached past the laminar separation point, so the drag is post-critical. That is physics of the model, not
  a bug. For subcritical bluff bodies, use a transition-capable OpenFOAM setup.
- The wing slope is 83 % of Helmbold at 20 cells/chord and symmetric within the expected ±6° difference. The LBM
  reached 44 % before its grid-refinement rework and now overshoots (3.93 /rad, see CFD.md §6). The NS gets the
  trailing edge and the boundary-layer momentum deficit about right on a uniform grid, because it uses a
  sharp-interface IBM with a wall function.

## 7. Comparison of the methods

| | LBM (in-app) | NS-FV (in-app) | OpenFOAM (offline) |
|---|---|---|---|
| Method | lattice Boltzmann (kinetic), weakly compressible, explicit | incompressible FV projection, explicit RK2 + multigrid | incompressible FV PISO/SIMPLE, implicit, unstructured |
| Mesh | nested lattice levels (ratio 2), interpolated bounce-back | uniform MAC grid, sharp IBM, Reichardt wall function | body-fitted snappyHexMesh, optional prism layers |
| Turbulence | LES (Smagorinsky / WALE) + log-law wall model | URANS k-ω SST (default), SA, SST-DDES, LES, laminar | k-ω SST (URANS `pimpleFoam` or steady `simpleFoam`), any OpenFOAM model |
| Time step | acoustic (Ma 0.1): many cheap steps | CFL 0.5 on the flow speed: ~6x fewer, ~30x costlier steps | implicit (Co ≤ 2) or steady |
| Cost (Trainer) | Draft real time; Medium ≈ 1 s GPU per 4 ms update (CFD.md §6) | Draft ≈ 4 ms GPU per update (real time); Medium / High slower than real time | hours |
| Accuracy | sphere / cube drag within ~20 %, lift slope overshoots on the refined grid | lift slope ~83 % of Helmbold, skin friction within 3-12 % | best when the mesh is converged |
| When to use | live flow pictures (slice, tracers), CFD in the loop, training | trustworthy in-app forces at one or a few conditions; `--aero-compare` | final reference and checking the in-app methods |

## 8. Using it

- **FLY:** in Aero model, pick *CFD · Navier–Stokes FV · Draft / Medium / High*. The picker groups the models
  under *Fast (analytic)*, *CFD · Lattice Boltzmann (real-time GPU)* and *CFD · Navier–Stokes finite volume (GPU,
  URANS k-ω SST, slower)*, and each group says what it costs. The status bar shows `CFD · NS-FV URANS`. The CFD
  panel hides the LBM-only settings. The quality readout shows the max CFL and the pressure residual in place of the
  lattice Mach and the mass drift. `collect()` never waits for the GPU: it keeps the last forces. The flow-slice
  overlay is LBM-only for now. EVOLVE and training list only the fast and LBM models.
- **CLI comparison:**
  `pwcli --aero-compare Trainer --speed 25 --alpha 4 --ns [--ns-model sst|sa|ddes|wale|smagorinsky|laminar] [--no-lbm] [--openfoam <case>]`
  prints Fx Fy Fz per part in columns: fast | LBM | NS-FV | OpenFOAM.
- **Debugging:** `PW_NS_DEBUG=1` prints, for each update, the steps, dt, max |u|, multigrid residual, max nu_t and
  V-cycles, plus the surface-integral and IBM-forcing force per part.

## 9. OpenFOAM reference

    pwcli --openfoam-export Trainer --out cases/trainer25 --speed 25 --alpha 4 [--steady] [--of-cells 8]
          [--of-level 3 4] [--of-layers 3] [--of-procs 8] [--of-endtime t] [--run]
    pwcli --openfoam-run cases/trainer25          # needs blockMesh / snappyHexMesh / pimpleFoam on PATH
    pwcli --aero-compare Trainer --speed 25 --alpha 4 --ns --openfoam cases/trainer25

The FLY panel's *OpenFOAM reference (offline)* button writes the same case for the current airspeed and pitch to
`~/Documents/Plane World/OpenFOAM/`. The case contains:

- `constant/triSurface/<patch>.stl`: one ASCII STL per part, in world axes with the CoM at the origin. Patch names
  are `p<index>_<name>`; `pw_parts.txt` maps them to part indices. Props are not meshed: the case assumes throttle 0;
- `system/blockMeshDict`: the background box. The inlet is upstream at +x, because the craft flies +x. Padding is
  3 L upstream, 6 L downstream and 3 L lateral, with 8 background cells per craft length;
- `system/snappyHexMeshDict`: surface refinement levels (3 4), a wake refinement box, and optional prism layers;
- `system/controlDict`: `pimpleFoam` (URANS, the default) or `simpleFoam` (`--steady`), and one `forces` function
  object per part patch plus `forces_total`. The function objects use `rho rhoInf` (ISA density at the altitude) and
  `CofR (0 0 0)`, so forces are in newtons and moments are about the CoM, in the same axes as the in-app CFD.
  There is also a `yPlus` function object;
- `system/fvSchemes`: linearUpwind for U and upwind for k / ω (bounded when steady);
- `system/fvSolution`: GAMG for p, PIMPLE (2 outer, 2 inner correctors) or consistent SIMPLE;
- `0/`: an inlet with a fixed free stream, an `inletOutlet` outlet with p = 0, and slip sides. Walls use
  `nutUSpaldingWallFunction`, `omegaWallFunction` and `kqRWallFunction` (automatic y+ treatment);
- `constant/transportProperties` + `turbulenceProperties` (OpenFOAM.com v2006+) and `physicalProperties` +
  `momentumTransport` (Foundation v9+): both naming generations are written;
- `Allrun` and `README.txt`.

`readForces` averages the last 30 % of the samples. It parses `force.dat` / `moment.dat` (OpenFOAM.com: total,
pressure, viscous) or `forces.dat` (Foundation: pressure + viscous, with or without porous columns).

For reference quality, use prism layers (`--of-layers 3` or more), check `yPlus` (30-300 for wall functions) and
refine until the forces stop changing.

## References

Brandt 1977 (Math. Comp. 31); Chorin 1968 (Math. Comp. 22); Fadlun, Verzicco, Orlandi & Mohd-Yusof 2000 (J. Comput.
Phys. 161); Balaras 2004 (Comput. Fluids 33); Ghia, Ghia & Shin 1982 (J. Comput. Phys. 48); Gritskevich, Garbaruk,
Schütze & Menter 2012 (Flow Turbul. Combust. 88); Harlow & Welch 1965 (Phys. Fluids 8); Kim & Moin 1985 (J. Comput.
Phys. 59); Leonard 1979 (CMAME 19); Menter, Kuntz & Langtry 2003 (Turbulence, Heat and Mass Transfer 4); Nicoud &
Ducros 1999 (Flow Turbul. Combust. 62); Reichardt 1951 (ZAMM 31); Schlichting, Boundary-Layer Theory; Spalart &
Allmaras 1992 (AIAA 92-0439); Trottenberg, Oosterlee & Schüller 2001, Multigrid; Uhlmann 2005 (J. Comput. Phys.
209); van Leer 1974 (J. Comput. Phys. 14). All kernels were written from these papers for this project: no
third-party code, and no GPL code. OpenFOAM is a trademark of OpenCFD Ltd; Plane World only writes input files for
it and runs it as a separate program.
