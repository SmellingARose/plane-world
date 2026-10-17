# Plane World: Physics models and equations

This page lists every equation the **fast** aero model uses, where it lives in the code, what it assumes and
where it stops being valid. The **full** model (GPU lattice-Boltzmann CFD) is described in `docs/CFD.md`. The
contract between the two is in `docs/FIDELITY.md`. In FLY, the EQUATIONS panel shows these same formulas for the
selected part with live values substituted, and shows the CFD force for that part when CFD is on.

File:line references are for the tree at the time of writing. Search for the function name if they drift.

Symbols used throughout: ρ air density, V airspeed, q = ½ρV² dynamic pressure, S area, α angle of attack,
M Mach number, β = √(1−M²), Re Reynolds number, R rotor radius, A = πR² disk area.

## 1. Rigid body and integration

| What | Equation | Code |
|---|---|---|
| Substep | 1 kHz fixed step (`physicsHz`), all forces summed per substep | `CraftSim.substepCore`, `Sources/Physics/CraftSim.swift:534` |
| Linear | symplectic Euler: v ← v + (F/m)h, x ← x + v h | `CraftSim.swift:828` |
| Angular | angular momentum L ← L + T h, ω = I⁻¹L (world inertia), orientation by midpoint exp-map | `CraftSim.swift:828` |
| Gravity | F = m g | `CraftSim.swift:708` |

Assumptions: the craft is one rigid body. Servos and spinning parts move their geometry, but the inertia tensor is
rebuilt only at load. Invariant: zero heap allocations per substep (selftested), and `substepCore` stays
`@inline(never)`.

## 2. Atmosphere and wind

| What | Equation | Code |
|---|---|---|
| Viscosity (Sutherland) | μ = 1.458·10⁻⁶ T^1.5 / (T + 110.4) | `Aerodynamics.swift:15` |
| Wind profile | v(h) = v_mean · clamp(ln(h/z₀)/ln(10/z₀), 0, 1.6) | `Aerodynamics.swift:166` |
| Turbulence | frozen, advected multi-octave sinusoids, σ ∝ turbulence·(0.6 + 0.12|v_mean|) | `Aerodynamics.swift:171` |

## 3. Wings (per strip)

Each wing is cut into spanwise strips. Each strip sees its own local velocity (rigid-body motion + wind + rotor
wakes) and gets its own coefficients. Code: `Aero.wing`, `Sources/Physics/Aerodynamics.swift:44` (reference
version) and `:110` (precomputed-constant version used by the sim), called from the wing-strip block at
`CraftSim.swift:574`.

| What | Equation | Code |
|---|---|---|
| Lift slope (Helmbold/DATCOM + Prandtl–Glauert) | a = 2πA / (2 + √(A²β²/κ² + 4)) | `Aerodynamics.swift:30` |
| Camber | C_L0 = C_L0,camber / β | `Aerodynamics.swift:48` |
| Plain flap | ΔC_L0 = a·τ·η·δ, τ = 1 − (θ_f − sin θ_f)/π, θ_f = acos(2c_f − 1) | `Aerodynamics.swift:51-55` |
| Attached lift | C_L = a·(α − α₀), with α₀ = −C_L0/a | `Aerodynamics.swift:61-65` |
| Post-stall | linear blend over 12° from the peak C_L to flat-plate 2 sin α cos α | `Aerodynamics.swift:66-70` |
| Stall angle | function of Re and t/c (thin < 4 % sections lose about 3°) | `Aerodynamics.swift:36` |
| Profile drag | C_D0 = 2C_f (1 + 2 t/c + 60 (t/c)⁴) (form factor on flat-plate friction) | `Aerodynamics.swift:74` |
| Total drag | C_D = C_D0 + φ C_L²/(πAe) + 0.02 sin²α + ΔC_D,flap | `Aerodynamics.swift:76` |
| Drag rise | M_crit,eff = max(0.55, 0.87 − t/c − 0.1|C_L| − 0.108) (Korn) | `Aerodynamics.swift:79` |
| Ground effect (McCormick) | φ = (16h/b)² / (1 + (16h/b)²), lift gain 1 + 0.15(1 − φ) | `Aerodynamics.swift:149` |
| Hinge moment | C_h = −0.55 δ − 0.2 α, H = |C_h| q S c_f (back-drives the servo) | `Aerodynamics.swift:57`, `CraftSim.swift:966` |
| Force | L = q S C_L ⟂ local flow, D = q S C_D ∥ local flow, applied at the strip's centre of pressure | `CraftSim.swift:574` |

Validity: subsonic (M < 0.8), attached or mildly separated flow, moderate aspect ratio. Strips do not see each
other's induced flow (a strip-theory model), except through the downwash effect in §7 when enabled.

## 4. Bodies

| What | Equation | Code |
|---|---|---|
| Primitive bodies | D = ½ρV² C_D S_proj (C_D = part `cd`, default 0.3), along the local flow | `CraftSim.swift:594` |
| CAD panels, windward (modified Newtonian) | f = −n · C_p,max cos²θ · q · A, C_p,max = 1 + M²/4, skipped if the panel is shadowed | `PanelAero.swift:104-108` |
| CAD panels, leeward | f = n · 0.25 cosθ · q · A (base suction) | `PanelAero.swift:110` |
| Skin friction (Schlichting turbulent) | C_f = 0.455 / (log₁₀ Re)^2.58, along the tangential flow | `PanelAero.swift:113-118` |
| Shadowing | depth buffer along the flow, panel shadowed if behind another panel | `PanelAero.swift:47` |

Validity: Newtonian theory is a hypersonic model. At low speed it gives the right order of magnitude for bluff
bodies and nothing better. There is no clean published error figure (see §9).

## 5. Propulsion

| What | Equation | Code |
|---|---|---|
| Power from static thrust rating | P = √(T₀³ / (2ρA)) / 0.75 | `Propulsion.swift:10` |
| Prop thrust (momentum theory) | T (V + v_i) = η P, η = 0.75, solved by Newton | `Propulsion.swift:17-30` |
| Induced velocity | v_i = −V/2 + √(V²/4 + T/(2ρA)) | `Propulsion.swift:21` |
| Pitch-speed unloading | thrust fades as V approaches the fixed-pitch speed | `Propulsion.swift:17` |
| Shaft torque | Q = P / Ω at the operating speed; the full Q reacts on the airframe | `CraftSim.swift:631` |
| Turbojet lapse | T/T₀ = σ^0.7 (1 − 0.25M + 0.45M²), σ = ρ/ρ₀ | `Propulsion.swift:38` |
| Spool | dN/dt = (N_cmd − N)/τ, τ = 1.6 s up, 0.9 s down | `Propulsion.swift:42` |
| Solid motor | T = T₀ · ramp(0.08 s) · (0.3 + 0.7·tail-off) · (1 + 0.08(1 − p/p₀)) | `Propulsion.swift:47` |

## 6. Rotor slipstream (actuator disk)

Code: `Sources/Physics/Slipstream.swift`. Off with `PW_SLIPSTREAM=0` (digest `77acda15065ef25b`, bit-identical
to the isolated-part model).

| What | Equation | Code |
|---|---|---|
| Disk velocity, open rotor | T = 2ρA(V + v_i)v_i → v_i = ½(−V + √(V² + 2T/(ρA))) | `Slipstream.swift:82` |
| Disk velocity, ducted (σ = 1) | T = ρA(V + w)w → k = 4 in the same formula | `Slipstream.swift:85` |
| Axial wake profile (vortex cylinder) | Δv(s) = v_i (1 + s/√(s² + R²)) | `Slipstream.swift:56-57` |
| Contraction (continuity) | R_s = R √((V + v_i)/(V + Δv)); ducted keeps R | `Slipstream.swift:59` |
| Mixing decay | × exp(−s / (14R)) | `Slipstream.swift:69` |
| Swirl | v_t = Γ / ((V + Δv) r) · profile · decay, Γ = Q/(ρπR²), sense = prop `spin` | `Slipstream.swift:72-74` |
| Rotor ground effect (Cheeseman–Bennett) | T_IGE/T_OGE = 1 / (1 − (R/4z)²), z/R ≥ 0.5 | `Slipstream.swift:91` |
| Duct detection | structure in ≥ 9 of 12 sectors at 1.0–1.7 R around the disk; override with param `duct` | `Slipstream.swift:117` |

The wake state lags one substep so the model stays explicit and deterministic.

## 7. Fast-model fidelity additions (toggles)

Each one is behind a `FastAeroToggles` flag (`Sources/Core/Fidelity.swift`) and applies only when slipstream is
on, so the slipstream-off digest is unchanged. **Status:** these are being implemented by the physics builder in
this pass. Check `docs/FIDELITY.md` "Status" and `--selftest physics` for which ones have landed. The formulas
below are the target models.

| Toggle | Effect | Model |
|---|---|---|
| `gyro` | Rotor and wheel angular momentum couples into body rotation | h = I_rotor Ω along the spin axis; gyroscopic torque T = −ω_body × h (precession) |
| `pFactor` | Asymmetric disk loading at incidence | in-plane normal force N ≈ T·k_N·sin(α_p) and yaw/pitch moment from the advancing/retreating blade offset |
| `downwash` | Wings induce downwash on downstream surfaces | horseshoe vortex per wing (bound + two trailing legs, Γ = ½ V c C_L), Biot–Savart velocity at downstream strips; classic tail result ε ≈ 2C_L/(πA) far behind |
| `blockage` | Bodies shadow and deflect rotor wakes | wake contribution attenuated behind bodies on the wake axis |
| `cadWash` | CAD panels see the slipstream per panel | each panel samples `WakeField.velocity` at its centre instead of the craft-level wind |

## 8. Ground, wheels, water

| What | Equation | Code |
|---|---|---|
| Corner contacts | penalty spring-damper normal force + Coulomb friction μ = terrain material friction | `CraftSim.swift:711-754` |
| Wheel suspension | spring-damper on the wheel contact | `CraftSim.swift:755` |
| Tyre (Pacejka-lite) | κ = (ωr − v)/max(|v|, 1), F_x = D sin(C atan(Bκ)); F_y = −D sin(C atan(Bα)); implicit ω update | `CraftSim.swift:791-800` |
| Buoyancy / hydrodynamics | submerged-volume forces from `WaterProvider.submergedForces` | `CraftSim.swift:818` |

## 9. How accurate are these models? (research table)

Typical error against experiment, from published validation work. These are figures for the model classes, not
measurements of Plane World itself.

| Model class | Typical error vs experiment | Source |
|---|---|---|
| Wing lift, attached flow (lifting line / strip) | a few % | [1], [2] |
| Low aspect ratio or large flaps | 10–20 % (inviscid theory overpredicts flap effectiveness) | [3], [4] |
| Unsteady / separated flow with a linear lifting line | up to about 60 % | [5] |
| Momentum theory / BEMT propeller | thrust 10–20 %, torque up to 30 % | [6], [9] |
| Actuator-disk prop-wing interaction | lift about 4 % (pitching moment poor) | [6] |
| Newtonian panels at low speed | no clean published figure (a hypersonic model, used here for order of magnitude) | — |
| RANS | lift about 5 % including near stall (single code); drag code-to-code scatter ±40 counts (2σ, DPW-I) | [7], [8] |
| Lattice-Boltzmann (Ahmed body) | drag 4.7 % on a fine grid vs 32.5 % on a coarse grid | [10] |

The LBM row is why `docs/CFD.md` insists on watching the grid-convergence estimate: resolution dominates CFD error.

Sources:
1. IOP Conf. Ser. Mater. Sci. Eng. 645 012017, doi:10.1088/1757-899X/645/1/012017
2. Utah State University MAE faculty publications 33, https://digitalcommons.usu.edu/mae_facpub/33
3. Kostić, FME Transactions 42(2), https://simlab.mas.bg.ac.rs/_media/istrazivanje/fme/vol42/2/01_ikostic.pdf
4. NASA NTRS 19750022028, https://ntrs.nasa.gov/citations/19750022028
5. PMC4529218, https://pmc.ncbi.nlm.nih.gov/articles/PMC4529218
6. TU Delft, AIAA 2018-0542, https://research.tudelft.nl/files/127914099/6.2018_0542.pdf
7. NASA NTRS 20200002409, https://ntrs.nasa.gov/citations/20200002409
8. NASA NTRS 20030001035 (AIAA Drag Prediction Workshop I), https://ntrs.nasa.gov/citations/20030001035
9. SAE Technical Paper 2022-26-1186
10. SimScale validation case, Ahmed body (LBM), https://www.simscale.com/docs/validation-cases/aerodynamics-ahmed-body-lbm/

## 10. What is not modelled (fast model)

- Wake reflection off the ground (beyond the rotor ground-effect thrust gain)
- Unsteady aerodynamics (dynamic stall, Theodorsen lag); everything is quasi-steady
- Blade flapping and blade-element detail (props are disks)
- Compressibility beyond Prandtl–Glauert and an empirical drag rise
- Aeroelasticity
