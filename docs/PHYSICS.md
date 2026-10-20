# Plane World: Physics models and equations

Every equation the **fast** aero model uses, where it lives in the C++ code, what it assumes and where it stops
being valid. In FLY, the EQUATIONS panel shows these formulas for the selected part with live values.

Paths are relative to the repo root. `craft_sim.cpp` = `src/core/src/sim/craft_sim.cpp`, `aero.cpp` =
`src/core/src/aero.cpp`. Line numbers drift; search for the function name if they do.

Symbols: ρ air density, V airspeed, q = ½ρV² dynamic pressure, S area, α angle of attack, M Mach number,
β = √(1−M²), Re Reynolds number, R rotor radius, A = πR² disk area.

## 1. Rigid body and integration

| What | Equation | Code |
|---|---|---|
| Substep | 1 kHz fixed step (`substepHz`), all forces summed per substep | `CraftSim::substepCore`, `craft_sim.cpp:584` |
| Linear | v ← v + (F/m)h, x ← x + ½(v_old + v_new)h (force held over the step) | `craft_sim.cpp:941` |
| Angular | L ← L + T h, ω = I⁻¹L (world inertia), orientation by midpoint exp-map | `craft_sim.cpp:944` |
| Gravity | F = m g | `craft_sim.cpp:817` |

Assumptions: one rigid body. Servos and spinning parts move their geometry, but the inertia tensor is rebuilt only
at load. Invariant: zero heap allocations per substep (selftested).

## 2. Atmosphere and wind

| What | Equation | Code |
|---|---|---|
| Viscosity (Sutherland) | μ = 1.458·10⁻⁶ T^1.5 / (T + 110.4) | `aero.cpp:10` |
| Wind profile | v(h) = v_mean · clamp(ln(h/z₀)/ln(10/z₀), 0, 1.6) | `src/core/src/atmosphere.cpp:17` |
| Turbulence | frozen, advected 4-octave sinusoids, σ ∝ turbulence·(0.6 + 0.12\|v_mean\|) | `src/core/src/atmosphere.cpp:20` |

## 3. Wings (per strip)

Each wing is cut into spanwise strips; each strip sees its own local velocity (rigid-body motion + wind + rotor
wakes) and gets its own coefficients. Code: `aero::wing`, `aero.cpp:24` (reference) and `aero.cpp:77`
(precomputed `WingConst` version used by the sim, bit-identical), called per strip from `CraftSim::runStrips`
(`craft_sim.cpp:565`).

| What | Equation | Code |
|---|---|---|
| Lift slope (Helmbold/DATCOM + Prandtl–Glauert) | a = 2πA / (2 + √(A²β²/κ² + 4)), κ = 0.95, M capped at 0.8 | `aero.cpp:12` |
| Camber | C_L0 = C_L0,camber / β | `aero.cpp:27` |
| Plain flap | ΔC_L0 = a·τ·η·δ, τ = 1 − (θ_f − sin θ_f)/π, θ_f = acos(2c_f − 1) | `aero.cpp:29-34` |
| Attached lift | C_L = a·(α − α₀), with α₀ = −C_L0/a | `aero.cpp:39-43` |
| Post-stall | linear blend over 12° from the peak C_L to flat-plate 1.05 sin 2α | `aero.cpp:44-49` |
| Stall angle | function of Re and t/c (thin < 4 % sections lose about 3°) | `aero.cpp:17` |
| Profile drag | C_D0 = 2C_f (1 + 2 t/c + 60 (t/c)⁴), C_f = 0.455/(log₁₀ Re)^2.58 | `aero.cpp:50-51` |
| Total drag | C_D = C_D0 + φ C_L²/(πAe) + 0.02 sin²α + ΔC_D,flap (+ post-stall term) | `aero.cpp:53-54` |
| Drag rise | M_crit,eff = max(0.55, 0.87 − t/c − 0.1\|C_L\| − 0.108) (Korn) | `aero.cpp:55-56` |
| Ground effect (McCormick) | φ = (16h/b)² / (1 + (16h/b)²), lift gain 1 + 0.15(1 − φ) | `aero.cpp:114` |
| Hinge moment | C_h = −0.55 δ − 0.2 α, H = \|C_h\| q S c_f (back-drives the servo) | `aero.cpp:36`, `craft_sim.cpp:573` |
| Force | L = q S C_L ⟂ local flow, D = q S C_D ∥ local flow, applied at the strip's centre of pressure | `craft_sim.cpp:569` |

Validity: subsonic (M < 0.8), attached or mildly separated flow, moderate aspect ratio. Strips do not see each
other's induced flow (strip theory), except through the downwash effect in §7.

## 4. Bodies

| What | Equation | Code |
|---|---|---|
| Primitive bodies | D = ½ρV² C_D S_proj (C_D = part `cd`, default 0.3, × transonic rise above M 0.8), along the local flow | `craft_sim.cpp:709-711` |
| CAD panels, windward (modified Newtonian) | f = −n · C_p,max cos²θ · q · A, C_p,max = 1 + M²/4, skipped if shadowed | `src/core/src/sim/panel_aero.cpp:157` |
| CAD panels, leeward | f = n · 0.25 cosθ · q · A (base suction) | `src/core/src/sim/panel_aero.cpp:159` |
| Skin friction (Schlichting turbulent) | C_f = 0.455 / (log₁₀ Re)^2.58, along the tangential flow | `src/core/src/sim/panel_aero.cpp:163` |
| Shadowing | depth buffer along the flow, panel shadowed if behind another panel | `PanelMesh::updateShadows`, `src/core/src/sim/panel_aero.cpp:51` |

The panel loop also has SIMD kernels (`src/core/src/simd_*.cpp`) with the same equations.

Validity: Newtonian theory is a hypersonic model. At low speed it gives the right order of magnitude for bluff
bodies and nothing better. There is no clean published error figure (see §9).

## 5. Propulsion

| What | Equation | Code |
|---|---|---|
| Power from static thrust rating | P = √(T₀³ / (2ρA)) / 0.75 | `aero.cpp:121` |
| Prop thrust (momentum theory) | T (V + v_i) = η P, η = 0.75, solved by Newton | `aero.cpp:126-137` |
| Induced velocity | v_i = −V/2 + √(V²/4 + T/(2ρA)) | `aero.cpp:132-133` |
| Pitch-speed unloading | thrust × max(0, 1 − (V/V_max)³) | `aero.cpp:141` |
| Shaft torque | Q = 0.75 P / Ω at the operating speed; the full Q reacts on the airframe | `craft_sim.cpp:766-768` |
| Turbojet lapse | T/T₀ = σ^0.7 (1 − 0.25M + 0.45M²), σ = ρ/ρ₀ | `aero.cpp:145` |
| Spool | dN/dt = (N_cmd − N)/τ, τ = 1.6 s up, 0.9 s down | `aero.cpp:146` |
| Solid motor | T = T₀ · ramp(0.08 s) · (0.3 + 0.7·tail-off) · (1 + 0.08(1 − p/p₀)) | `aero.cpp:150` |

## 6. Rotor slipstream (actuator disk)

Code: `RotorWake` / `aero::wakeInduced` (`aero.cpp:172`), wake views in `src/core/pw/sim/slipstream.h`, wake
construction at `craft_sim.cpp:622`. Off with `PW_SLIPSTREAM=0` (digest `77acda15065ef25b`, bit-identical to the
isolated-part model).

| What | Equation | Code |
|---|---|---|
| Disk velocity, open rotor | T = 2ρA(V + v_i)v_i → v_i = ½(−V + √(V² + 2T/(ρA))) | `aero.cpp:201` |
| Disk velocity, ducted (σ = 1) | T = ρA(V + w)w → k = 4 in the same formula | `aero.cpp:204` |
| Axial wake profile (vortex cylinder) | Δv(s) = v_i (1 + s/√(s² + R²)) | `aero.cpp:179-180` |
| Contraction (continuity) | R_s = R √((V + v_i)/(V + Δv)); ducted keeps R | `aero.cpp:181` |
| Mixing decay | × exp(−s / (14R)) | `aero.cpp:190` |
| Swirl | v_t = Γ / ((V + Δv) r) · profile · decay, Γ = Q/(ρπR²), sense = prop `spin` | `aero.cpp:192-195`, `craft_sim.cpp:635` |
| Rotor ground effect (Cheeseman–Bennett) | T_IGE/T_OGE = 1 / (1 − (R/4z)²), z/R ≥ 0.5 | `aero.cpp:208` |
| Duct detection | structure in ≥ 9 of 12 sectors at 1.0–1.7 R around the disk; override with param `duct` | `CraftSim::detectDucts`, `craft_sim.cpp:981` |

The wake state lags one substep so the model stays explicit and deterministic.

## 7. Fast-model fidelity additions (toggles)

Each is a `FastAeroToggles` flag (`src/core/pw/sim/fidelity.h:12`, all on by default) and applies only when
slipstream is on, so the slipstream-off digest is unchanged. Implementations are in
`src/core/src/sim/fast_gaps.cpp`.

| Toggle | Effect | Model | Code |
|---|---|---|---|
| `gyro` | Rotor and wheel angular momentum couples into body rotation | h = I_rotor Ω along the spin axis; T = −ω_body × h | `src/core/src/sim/fast_gaps.cpp:106` |
| `pFactor` | Asymmetric disk loading at incidence | in-plane normal force N ≈ T·k_N·sin(α_p) and moment from the advancing/retreating blade offset | `src/core/src/sim/fast_gaps.cpp:9` |
| `downwash` | Wings induce downwash on downstream surfaces | horseshoe vortex per wing group (Γ = L/(ρVb) = ½ V c C_L), Biot–Savart at downstream strips; far-field ε ≈ 2C_L/(πA) | `src/core/src/sim/fast_gaps.cpp:84`, `src/core/pw/sim/slipstream.h:46` |
| `blockage` | Bodies shadow rotor wakes | wake attenuated behind bodies on the wake axis | `src/core/src/sim/fast_gaps.cpp:29`, `aero.cpp:156` |
| `cadWash` | CAD panels see the slipstream per panel | each panel samples wake + downwash velocity at its centre | `craft_sim.cpp:688`, `src/core/src/sim/panel_aero.cpp:147` |

The following toggles are correctness fixes. Unlike the toggles above, they apply whether or not slipstream is
on. All default to on, and `FastAeroToggles::setSwiftLegacy()` turns them off for the Swift-parity tests.
`docs/VALIDATION.md` has the before/after numbers.

| Toggle | Effect |
|---|---|
| `hingeAtAC` | All-moving surfaces pivot near the aerodynamic centre; the servo load comes from the centre-of-pressure offset |
| `staticFriction` | Ground corners and slow wheels hold with an anchored tangential spring, capped at μN (Coulomb stiction); no creep on slopes |
| `spinReaction` | The airframe takes −dh/dt of wheel and rotor spin (motor reaction); angular momentum is conserved |
| `finiteWingStall` | Stall angle × 0.9·a₀/a(A), capped at 35°, so a finite wing reaches CLmax ≈ 0.9·c_lmax |
| `exactMass` | Mass properties follow fuel use on every substep, including burnout |

## 8. Ground, wheels, water

| What | Equation | Code |
|---|---|---|
| Corner contacts | penalty spring-damper normal force + Coulomb friction μ = terrain material friction | `craft_sim.cpp:819-860` |
| Wheel suspension | spring-damper on the wheel contact (k = m g/(n·0.08 m), ζ = 0.6) | `craft_sim.cpp:862-866` |
| Tyre (Pacejka-lite) | κ = (ωr − v)/max(\|v\|, 1), F_x = D sin(C atan(Bκ)); F_y = −D sin(1.3 atan(8α)); implicit ω update | `craft_sim.cpp:901-908` |
| Buoyancy / hydrodynamics | submerged-volume forces from `WaterSystem::submergedForces` | `craft_sim.cpp:935`, `src/env/src/water.cpp:163` |

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
