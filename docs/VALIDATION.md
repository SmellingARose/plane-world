# Plane World: physics validation

This document checks the fast model against closed-form theory and well-known published values, for every
vehicle class the simulator supports. Every row is a self-test check:

```
build/src/cli/pwcli --selftest validate. --verbose     # prints one ROW| line per check
```

The tests are in `src/env/src/validate_selftests.cpp`. They live in pwenv because the boat checks need
`WaterSystem`. The groups are `validate.aircraft`, `glider`, `rocket`, `rotorcraft`, `ground`, `boat`, `general`
and `fixes`. Any failing row fails its test. The numbers below come from macOS arm64. They are deterministic.

**Static (aerodynamic) checks.** The helper `forceAt` holds the craft at a fixed state: attitude, velocity,
1000 m altitude, zero g. It runs one 1 ms substep and reads F = mΔv/h and M = ΔL/h. It does this three times so
the lagged state (downwash horseshoes, rotor wakes) catches up with the held state. Coefficients use q = ½ρV² at
that altitude.

**Dynamic checks.** These fly the full 6-DOF sim: glide, phugoid, short period, weathercocking, hover, braking,
slopes, flotation and capsize.

## Results

### Aircraft

| Check | Expected | Measured | Error | Result | Source / formula |
|---|---|---|---|---|---|
| Lift-curve slope dCL/dα, AR 4 (1/rad) | 3.883 | 3.781 | -2.62% | PASS | Helmbold: 2πA/(2+√(A²+4)) |
| Lift-curve slope dCL/dα, AR 8 (1/rad) | 4.906 | 4.732 | -3.54% | PASS | Helmbold: 2πA/(2+√(A²+4)) |
| Lift-curve slope dCL/dα, AR 16 (1/rad) | 5.547 | 5.321 | -4.07% | PASS | Helmbold: 2πA/(2+√(A²+4)) |
| Induced-drag Oswald factor e, AR 8 | 0.8 | 0.786 | -1.75% | PASS | CD−CD0 = CL²/(πAe), e≈0.75–0.85 (Raymer) |
| Section c_lmax implied by the model, 12% t/c, Re≈1.9e6 | 1.4–1.7 (NACA 0012/2412) | 1.518 | - | PASS | Abbott & von Doenhoff, Theory of Wing Sections |
| Wing CLmax, AR 8 | 1.366 | 1.364 | -0.18% | PASS | DATCOM: CLmax ≈ 0.9·c_lmax (straight, high AR) |
| Wing stall angle, AR 8 | 12.91° | 12.9° | -0.0134° | PASS | α_s = CLmax/a + α0 (finite-wing slope) |
| All-moving surface: +deflection raises CL | ΔCL > 0 | ΔCL +1.980 | - | PASS | thin-airfoil theory |
| Plain flap: +deflection (TE down) raises CL | ΔCL > 0 | ΔCL +0.981 | - | PASS | thin-airfoil flap theory (τ) |
| Flap less effective than all-moving at equal δ | ΔCL_flap < ΔCL_slab | 0.981 < 1.980 | - | PASS | τ < 1 for c_f < c |
| Trainer +elevator → nose-up pitch (+z) | Mz > 0, Mz dominant | M=(-0,-0,12056) N·m | - | PASS | sign convention |
| Trainer +aileron → roll right (+x) | Mx > 0, Mx dominant | M=(19362,1242,-690) N·m | - | PASS | sign convention |
| Trainer rudder → yaw moment (y) dominant | My dominant | M=(-1358,-6500,323) N·m | - | PASS | sign convention |
| Static stability, CG ahead of neutral point | dCm/dα < 0 | -2.248 /rad | - | PASS | Etkin & Reid |
| Static instability, CG behind neutral point | dCm/dα > 0 | 2.596 /rad | - | PASS | Etkin & Reid |
| Phugoid period vs Lanchester π√2·V/g (constant-α idealisation) | 7.60 s | 10.12 s | - | PASS | Lanchester (1908); info: pitch damping lengthens it |
| Phugoid period (Lanchester + pitch-damping α shift) | 10.54 s | 10.12 s | -4.04% | PASS | ω² = 2g²/V² / (1 + g CLα k/(CL V)), k = (Cmq/Cmα)c/2V; Cmq, Cmα from sim |
| Phugoid damped (speed excursion, first vs last 20 s) | decays | 2.51 → 1.72 m/s | - | PASS | drag damping (weak: ζ ≈ 1/(√2·L/D)) |
| Trimmed glide ratio L/D | 21.4 | 21.67 | +1.27% | PASS | steady glide: tanγ = CD/CL at trim (sim polar) |
| Trimmed glide sink rate | 0.7788 m/s | 0.7675 m/s | -1.45% | PASS | w = V·sinγ, V = √(2W cosγ/(ρ S CL)) |
| Short-period mode damped (α excursion after pitch kick) | late < 25% of peak | peak 1.86°, 1–1.5 s 0.17° | - | PASS | Etkin & Reid (heavily damped short period) |

### Glider

| Check | Expected | Measured | Error | Result | Source / formula |
|---|---|---|---|---|---|
| Best-L/D speed | 14.77 m/s | 14.73 m/s | -0.29% | PASS | V* = √(2W/(ρS))·(k/CD0)^¼ (parabolic polar fit) |
| (L/D)max | 22.25 | 22.44 | +0.85% | PASS | (L/D)max = 1/(2√(k·CD0)) |
| Polar fit k vs 1/(πAe), A=12 | 0.0332 (e=0.8) | 0.0333 | - | PASS | lifting line + tail/trim contributions |

### Rocket

| Check | Expected | Measured | Error | Result | Source / formula |
|---|---|---|---|---|---|
| Vacuum Δv (m0 17 kg, mf 12 kg, ve 400 m/s) | 139.3 m/s | 139.3 m/s | +0.00% | PASS | Tsiolkovsky: Δv = ve·ln(m0/mf) |
| Mass after burnout | 12 kg | 12 kg | +0 kg | PASS | dry mass |
| Drag-free apogee from 100 m/s | 509.7 m | 509.7 m | -0.00% | PASS | h = v²/2g |
| Fins aft of CG: weathercocks (incidence, 2–3 s) | < 1.5° (from 7°) | 0.24° | - | PASS | Barrowman: CP aft of CG ⇒ stable |
| Fins ahead of CG: diverges / tumbles | > 30° | 179.4° | - | PASS | Barrowman: CP ahead of CG ⇒ unstable |

### Rotorcraft

| Check | Expected | Measured | Error | Result | Source / formula |
|---|---|---|---|---|---|
| Static thrust at rating (ρ-scaled) | 59.71 N | 59.71 N | +0.00% | PASS | momentum theory, P fixed by rating |
| Hover figure of merit P_ideal/P_shaft | 0.75 | 0.75 | +0.00% | PASS | P_ideal = T^1.5/√(2ρA); FM 0.7–0.8 typical (Leishman) |
| Thrust at half power | 0.63 | 0.63 | -0.00% | PASS | T ∝ P^(2/3) (momentum theory) |
| Climb accel. at 1.03× hover throttle (first 0.5 s) | 0.1952 m/s² | 0.1785 m/s² | -8.57% | PASS | a = (T−W)/m, T ∝ throttle^(2/3) |
| T/W > 1 climbs, < 1 sinks | vy(1.5 s): + / − | +0.225 / -0.296 m/s | - | PASS | Newton |
| Counter-rotating pairs cancel yaw | r ≈ 0 | 1.09e-16 rad/s (same-spin -1.667) | - | PASS | torque balance ΣQ = 0 |

### Ground vehicle

| Check | Expected | Measured | Error | Result | Source / formula |
|---|---|---|---|---|---|
| Sliding deceleration, μ = 0.6 | 5.886 m/s² | 5.886 m/s² | +0.00% | PASS | Coulomb: a = μg |
| Box at rest on 15° slope, μ 0.9: drift in 10 s | 0 m | 4.12e-13 m | +4.12e-13 m | PASS | static friction: tanθ < μ ⇒ no motion |
| Box at rest on 40° slope, μ 0.9 (tan 0.84): drift in 10 s | 0 m | 1.719e-11 m | +1.72e-11 m | PASS | static friction |
| Box sliding on 30° slope, μ 0.3 | 2.356 m/s² | 2.356 m/s² | -0.00% | PASS | a = g(sinθ − μcosθ) |
| Rover coast-down (rolling resistance C_rr 0.02) | 0.1825 m/s² | 0.1825 m/s² | +0.03% | PASS | a = C_rr·g·m/(m + ΣI/r²) |
| Rover parked across a 15° slope: sideways drift in 10 s | 0 m | 0.000258 m | +0.000258 m | PASS | tyre static friction |
| Full-lock cornering lateral accel ≤ μg | ≤ 9.81 m/s² | max 8.53 m/s² (0.1 s mean) | - | PASS | friction circle: a_y ≤ μg |

### Boat / water

| Check | Expected | Measured | Error | Result | Source / formula |
|---|---|---|---|---|---|
| Floating box draft (2×2 m, 1000 kg) | 0.25 m | 0.25 m | +0.00% | PASS | Archimedes: ρ V_sub = m |
| Heave oscillation decays | < 10% of 0.25 m drop after 28 s | 0.0000 m | - | PASS | radiation + viscous damping |
| Heave natural period | 1.003 s | 1.02 s | +1.68% | PASS | T = 2π√(m/(ρgA_wp)), no added mass |
| Roll period, wide box (GM 1.46 m) | 1.323 s | 1.324 s | +0.11% | PASS | T = 2π√(I/(m g GM)), no added inertia |
| Positive GM: returns upright | heel < 1° at 20 s | 0.65° | - | PASS | metacentric height > 0 |
| Negative GM (tall narrow box, GM −0.49 m): capsizes | heel > 45° | 87.6° | - | PASS | metacentric height < 0 |
| Water drag ≫ air drag (2 m/s, same hull) | ratio > 100 (ρw/ρa ≈ 816) | 2514 N vs 3.90 N (×645) | - | PASS | drag ∝ ρ |
| Box of density 2000 kg/m³ sinks to the bed | y_CoM ≈ 0.5 m | 0.50 m | - | PASS | Archimedes |

### General mechanics

| Check | Expected | Measured | Error | Result | Source / formula |
|---|---|---|---|---|---|
| Free fall 5 s | -122.6 m | -122.6 m | -0.00% | PASS | y = −½gt² |
| Projectile energy drift (8 s, relative) | 0 | -9.623e-16 | -9.62e-16 | PASS | energy conservation (no dissipation) |
| Torque-free tumble: L magnitude drift (20 s, relative) | 0 | 0 | +0 | PASS | angular momentum conservation |
| Torque-free tumble: max rotational KE drift | 0 | 4.844e-07 | +4.84e-07 | PASS | energy conservation (Dzhanibekov flip) |
| Internal wheel motor: total angular momentum / wheel h | 0 | 1.15e-15 | +1.15e-15 | PASS | angular momentum conservation (motor reaction) |
| Internal wheel motor: linear momentum | 0 kg·m/s | 0 kg·m/s | +0 kg·m/s | PASS | momentum conservation |
| Determinism: repeat run bit-identical | identical | identical | - | PASS | fixed-step, ordered reductions |
| Determinism: parallel strips = serial | identical | identical | - | PASS | ordered reductions |

### Fixes (legacy → fixed)

| Check | Expected | Measured | Error | Result | Source / formula |
|---|---|---|---|---|---|
| Box on 15° slope (μ 0.9): drift in 10 s | 0 m | 0.423 m → 4.12e-13 m | - | PASS | staticFriction |
| Rover parked across 15° slope: sideways drift in 10 s | 0 m | 0.265 m → 0.000258 m | - | PASS | staticFriction (tyre) |
| Wheel motor in free space: (L_body + h_wheel) / h_wheel | 0 | 1 → 1.15e-15 | - | PASS | spinReaction |
| Wing CLmax, AR 8 (expect ≈0.9·c_lmax = 1.36) | 1.32–1.40 | 1.197 → 1.364 | - | PASS | finiteWingStall |
| Solid motor: propellant left in mass after burnout | 0 kg | 0.00194 kg → 0 kg | - | PASS | exactMass |

## Bugs found and fixed

Each fix changes trajectories, so each one is a `FastAeroToggles` flag (`src/core/pw/sim/fidelity.h`).

- **Defaults.** Every flag defaults to the correct behaviour.
- **Parity.** `FastAeroToggles::setSwiftLegacy()` turns them all off, together with the earlier `hingeAtAC`.
  The Swift-parity tests call it: the `tests/test_sim.cpp` replays, `physics.trajectory-digest`,
  `evolution.parity-*` and `evolution.evaluator-determinism`.
- **Storage.** Experiment JSON stores each flag under `aero.toggles`.
- **Allocations.** None of the fixes adds a heap allocation to the substep.

| Flag | Bug | Legacy → fixed (`validate.fixes`) | Fix |
|---|---|---|---|
| `staticFriction` | Ground corners had only viscous friction, min(μN, v·c). A body at rest on any slope crept downhill at about g·sinθ/60 m/s. | Box on a 15° slope, μ 0.9: drifted 0.42 m in 10 s → 4e-13 m | Coulomb friction with stiction. A tangential spring-damper pulls toward the touch-down anchor, capped at μN. While the body slides, the anchor follows, so the force is μN against the slip velocity. |
| `staticFriction` (tyres) | The slip-angle curve is viscous at zero speed, so a parked car slid sideways down a cross-slope. | Rover across a 15° slope: 0.27 m in 10 s → 0.26 mm | Below 0.5 m/s, a lateral spring pulls toward an anchor, capped at the grip D. |
| `spinReaction` | Wheel-motor and rotor spin-up torqued only the wheel or rotor, with no reaction on the airframe, so total angular momentum was not conserved. A wheel spun up in the air did not counter-rotate the craft. The chassis did not feel motor torque while a wheel accelerated. | (L_body + h_wheel) / h_wheel: 1.0 → 1e-15 | The airframe takes −dh/dt of each wheel's and prop's spin. The contact force already carries the ground torque on the wheel, so this term is exactly the motor and bearing reaction. |
| `finiteWingStall` | The model applied the 2-D section stall angle to the finite-wing lift slope, so CLmax came out low by the factor a₃D/a₂D. At AR 8, CLmax was 1.20 instead of about 1.36. Low-AR fins stalled near 15° instead of near 35°. | AR 8 CLmax: 1.197 → 1.364 (DATCOM estimate 0.9·c_lmax = 1.36) | The stall angle is multiplied by 0.9·a₀/a(A) and capped at 35° (`aero::finiteWingStallScale`). `aero::wing(WingConst…)` takes this as a new `stallScale` argument; the default of 1 keeps parity. |
| `exactMass` | Mass, CoM and inertia were refreshed only on every 10th substep, and only while a motor burned. Up to 9 substeps of propellant stayed in the mass after burnout, permanently. | Propellant left in the mass: 1.94 g (of 5 kg) → 0 | Mass properties are refreshed on every substep that uses fuel, including the burnout step. |
| `rotorSpeedLaw` | Rotor speed was proportional to throttle while shaft power was too, so drag torque Q = P/ω came out the same at every throttle. Differential throttle could not yaw a multirotor, and the yaw reaction of any prop was wrong away from full power. | Racer quad yaw axis: no response → tracks a turn (physics.multirotor-fc) | A fixed-pitch prop has P ∝ ω³ and T, Q ∝ ω², so ω ∝ P^(1/3): torque now grows with thrust. |

A fix from before this suite: `hingeAtAC`, where the servo hinge load used the total force instead of the
centre-of-pressure offset.

## Notes on the comparisons

- **Lift-curve slope.** The model uses the DATCOM form with section efficiency κ = 0.95, so it sits 2.6 to 4.1 %
  below Helmbold's ideal (a₀ = 2π). That gap is the usual difference between real sections and thin-airfoil
  theory.
- **Phugoid.** Lanchester's period π√2·V/g assumes α stays constant. In the sim, pitch damping shifts α during
  the phugoid: Δα = −(Cmq/Cmα)(c/2V)·q. This is real physics, and it softens the lift-versus-speed spring.
  - Corrected formula: ω² = (2g²/V²) / (1 + g·CLα·k/(CL·V)), with Cmq and Cmα measured from the sim.
  - The corrected formula predicts 10.5 s and the sim gives 10.1 s (−4 %). Lanchester alone gives 7.6 s.
- **Rotors.**
  - The figure of merit is fixed at η = 0.75, inside the 0.7 to 0.8 range of good rotors.
  - Static thrust is the rating scaled by ρ/ρ₀, and thrust scales as P^(2/3), as momentum theory says.
  - In the climb check, thrust falls below the static value because inflow builds up. This is momentum theory,
    and it explains the −8.6 % gap.
  - The hub sits outside the wake. A body inside the wake correctly feels download.
- **Boats.** Hydrostatics are exact (clipped-triangle Froude–Krylov pressure). The model has no added mass, so
  the heave and roll periods match the dry formulas. A real hull would oscillate 10 to 30 % slower.

## Known limitations (not fixed)

- **Phugoid damping.** It is weaker than the constant-CD estimate ζ ≈ 1/(√2·L/D): the speed excursion falls only
  from 2.5 to 1.7 m/s over 120 s. Two causes contribute:
  - α, and with it induced drag, varies with speed through pitch damping.
  - Profile drag falls as the Reynolds number rises.
- **Wing `ar` is a user parameter.** The model does not derive it from geometry, and the default is 7 for every
  wing panel. A panel whose `ar` disagrees with its planform gets the wrong lift slope and induced drag.
  Deriving AR from wing groups would need another parity flag.
- **Primitive bodies use box projected areas.** A sphere or cylinder presents (2r)² instead of πr², which is
  27 % more, and the part's `cd` absorbs the difference. Cylinders and cones may set `cdAxial` instead, an axial
  coefficient on the true πr² with `cd` left for cross-flow (used by New Shepard). Drag acts along the flow, so
  bodies produce no crossflow lift, and parts do not shield each other.
- **Water forces are incomplete.**
  - No added mass or added inertia.
  - No wave-making resistance and no hydrodynamic lift, so planing hulls and hydrofoils get only buoyancy and
    pressure drag.
  - Hull drag is pressure drag plus ITTC skin friction plus linear radiation damping.
- **Prop torque.** It is Q = 0.75·P/Ω. With slipstream off, the legacy path applies only a quarter of that.
- **The lake and river path allocates memory.** `WaterSystem::submergedForces` builds a `std::function` height
  sampler on every call when lakes or rivers exist, which is one heap allocation per substep on water. The
  ocean-only path does not allocate, and CraftSim's own substep stays allocation-free. This was not changed here.
- **Wheels have no brakes.** The braking check uses a sliding box (deceleration μg). A wheeled vehicle slows only
  through rolling resistance (C_rr) and its motor.
- **Compressibility.** The model has only Prandtl–Glauert plus an empirical drag rise, and nothing here is
  validated above M 0.8.
