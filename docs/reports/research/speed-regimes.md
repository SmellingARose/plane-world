# Flight speed regimes and the CFD solvers that can (and cannot) cover them

Research note for the CFD-solver comparison page. Every number has a source URL. Numbers marked *(computed)* are derived here from standard isentropic or linearised-flow formulas, not taken from a source.

## Our crafts on the Mach axis

| Craft | Typical speed | Mach | Regimes crossed |
|---|---|---|---|
| Light propeller trainer | ~40 m/s | ~0.12 *(computed, a = 340 m/s)* | 1 |
| Racing quad | 30–70 m/s; record 263 km/h average, 289 km/h peak ([Guinness](https://www.guinnessworldrecords.com/news/2017/7/the-drone-racing-league-builds-the-worlds-fastest-racing-drone-482701)) | ≤0.21 *(computed)* | 1 (propeller tips go higher) |
| Jet trainer | — | 0.6–0.8 | 2, reaches the edge of 3 |
| New Shepard | Ascent peak Mach 2.94; booster descent Mach 3.74 (Mission 7); Mach 3 on the first flight ([SpaceRef](https://spaceref.com/space-commerce/another-successful-blue-origin-flight/), [SpaceRef 2015](https://spaceref.com/?p=13082)) | 0 → ~3.7 | 1 → 4, then descent back through 3 and 2 |
| Sounding rocket (Terrier-Black Brant IX) | 400 km apogee with a 360 kg payload, burnout at 46 s ([arXiv 1602.02333](https://arxiv.org/pdf/1602.02333)) | Burnout speed ≈ √(2gh) ≈ 2.8 km/s, so hypersonic at altitude *(computed estimate)* | 1 → 5, with a rarefied coast |

The rockets cross every regime in under a minute. That is why launch-vehicle databases are built as Mach sweeps from several sources (see "How launch-vehicle aero databases handle regimes" below).

---

## 1. Incompressible subsonic (M < ~0.3)

**Definition.** At M = 0.3 the stagnation density is about 4.6% above the static density *(computed: (1+0.2M²)^2.5)*. That is why ~5% is the usual threshold for treating the flow as incompressible ([Wikipedia: compressible flow](https://en.wikipedia.org/wiki/Compressible_flow)). What matters is the **local** maximum Mach number, not the freestream value: suction peaks and propeller tips exceed the freestream value.

**Physics**
- Density is essentially constant, and pressure acts as a Lagrange multiplier that enforces ∇·u = 0.
- Results are dominated by Reynolds number: laminar–turbulent transition, laminar separation bubbles, stall, propeller slipstream and wake interaction.
- Prandtl–Glauert factor 1/√(1−M²) = 1.007 at M = 0.12 and 1.048 at M = 0.3 *(computed)*, so the compressibility correction is below 5%.

**Equations and methods.** Incompressible Navier–Stokes. The energy equation decouples. Pressure–velocity coupling (SIMPLE/PISO, or artificial compressibility). Upwind/central schemes need no shock capturing. A compressible solver run here needs low-Mach preconditioning, otherwise it converges poorly and is inaccurate.

| Solver | Valid? | Why |
|---|---|---|
| Panel / vortex-lattice | Yes for attached-flow lift and induced drag | Inviscid potential flow is exact for incompressible irrotational flow. No viscous drag and no stall. |
| Steady RANS | Yes | The standard tool. Stall and transition are model-dependent. |
| URANS / DDES / WMLES / LES | Yes | Needed for stall, wakes and rotor–airframe interaction. Cost rises in that order. |
| DNS | Only at low Re | Cost scales roughly as Re^(9/4). |
| Lattice Boltzmann (standard) | Yes, this is its home regime | Recovers Navier–Stokes only as a low-Mach expansion. The second-order equilibrium has a velocity-dependent (Ma³) viscosity error on standard lattices ([arXiv 0801.2924](https://arxiv.org/pdf/0801.2924)), and LBM is described as restricted to low-Mach flow ([arXiv 1504.07034](https://arxiv.org/pdf/1504.07034)). |

**Accuracy evidence.** The main error sources are transition and stall modelling, not compressibility. The SLS liftoff database used a low-speed tunnel test at M ≤ 0.2 rather than CFD as its baseline ([NTRS 20150006862](https://ntrs.nasa.gov/api/citations/20150006862/downloads/20150006862.pdf)).

**Open-source solvers.** SU2 `INC_RANS` ([SU2 docs](https://su2code.github.io/docs_v7/Solver-Setup/)); OpenFOAM `simpleFoam`/`pimpleFoam`; FUN3D (incompressible and low-Mach-preconditioned options).

---

## 2. Compressible subsonic (0.3 < M < ~0.8)

**Physics**
- Density changes become first-order: 19% at M = 0.6 and 35% at M = 0.8 *(computed)*.
- Pressure coefficients scale with 1/√(1−M²): ×1.25 at M = 0.6 and ×1.67 at M = 0.8 *(computed)*. This is the Prandtl–Glauert correction. It is singular at M = 1, so it is limited to subsonic flow well below Mach 1. The Kármán–Tsien and Laitone rules are more accurate as transonic effects approach ([Georgia Tech AE3021 notes](https://sankar.gatech.edu/AE3021/CriticalMachNumber.pdf)).
- **Critical Mach number** (M_cr): the freestream Mach number at which the local flow first reaches M = 1 somewhere on the body. The drag-divergence Mach number lies above M_cr and below 1 ([ERAU, Computational Simulation for Aero](https://eaglepubs.erau.edu/compsimforaero/chapter/c-2/)).
- Both correction rules assume thin bodies and attached, shock-free flow. They fail once a supersonic pocket forms.

**Equations and methods.** Compressible Navier–Stokes with the energy equation. Mild shocks are possible near M_cr, so use upwind or JST schemes with limiters.

| Solver | Valid? | Why |
|---|---|---|
| Panel with Prandtl–Glauert or Kármán–Tsien | OK up to ~M_cr | Linearised compressibility only. |
| Full potential | Yes | Isentropic. Fine until shocks become strong. |
| Steady RANS (compressible) | Yes | The standard tool. |
| Incompressible RANS | Invalid above ~0.3–0.4 | Misses density change and Cp amplification. |
| Standard LBM | Poor to invalid | Low-Mach limit as above. Needs compressible variants: two-population models reach the "fully compressible regime", including transonic flutter ([arXiv 2107.01370](https://arxiv.org/pdf/2107.01370)). Some compressible LBM models are unstable above M = 1 ([arXiv 0908.3749](https://arxiv.org/pdf/0908.3749)). |
| DDES / WMLES / LES | Yes | Only needed for separated flow. |

**Accuracy evidence.** For attached flow, RANS is generally accurate here. The major error budgets show up at transonic conditions (section 3).

**Open-source solvers.** SU2 `RANS`; OpenFOAM `rhoSimpleFoam`/`rhoPimpleFoam`; FUN3D.

---

## 3. Transonic (~0.8 < M < ~1.2)

**Physics**
- Mixed subsonic/supersonic flow with embedded normal shocks.
- Drag rise and divergence from wave drag plus shock-induced boundary-layer thickening.
- Shock–boundary-layer interaction (SBLI) and shock-induced separation.
- **Buffet**: self-sustained shock oscillation. On the OAT15A airfoil at M = 0.73 and α = 3.5°, the shock oscillates periodically at 69 Hz ([Deck 2005](https://cfd.spbstu.ru/agarbaruk/doc/2005_Deck_Numerical-Simulation-of-Transonic-Buffet-over-a-Supercritical-Airfoil.pdf)).
- On rockets: the nose and shoulder shocks move along the body, and the pitching moment is most uncertain near M = 1.
- Linear theories fail here: the Prandtl–Glauert singularity and the mixed elliptic/hyperbolic character of the flow.

**Equations and methods.** Compressible Euler or RANS with shock capturing: Roe (needs an entropy fix), HLLC, AUSM, or JST with MUSCL limiters. Use unsteady time stepping for buffet. Grid resolution affects shock location ([Pomeroy, NASA 2024](https://ntrs.nasa.gov/api/citations/20240005798/downloads/Buffet%20v4.pdf)).

| Solver | Valid? | Why |
|---|---|---|
| Panel / Prandtl–Glauert | Invalid | Singular at M = 1. No shocks. |
| Transonic small disturbance / full potential | OK for weak shocks, attached flow | Isentropic shocks give the wrong strength and position once the shock is strong. |
| Euler | OK for shock position trends | No viscosity, so no SBLI or separation. |
| Steady RANS | Good at cruise, poor past pitch-up and buffet | See DPW evidence below. |
| URANS | OK for buffet, model-dependent | In URANS, SA and BSL k-ω gave a steady solution on OAT15A while SST and KKL gave periodic shock oscillation ([Thiery & Coustols 2006](https://cfd.spbstu.ru/agarbaruk/doc/2006_Thiery-Coustols_Numerical-prediction-of-shock-induced-oscillations-over-a-2D-airfoil-Influence-of-turbulence-modelling-and-test-section-walls.pdf); summarised in [Illi 2012](https://www.tu-braunschweig.de/fileadmin/Redaktionsgruppen/Forschung/FOR1066/Veroeffentlichungen/SWNS_2012/5-Illi-2012.pdf)). |
| DDES | Risky | DES variants can fail buffet onset because the boundary layer does not stay turbulent up to the shock. Zonal DES fixes this by keeping the boundary layer in RANS mode ([Tsukamoto & Kitamura 2024](https://ynu.repo.nii.ac.jp/record/2001012/files/tsukamoto-kitamura-2024-numerical-study-of-transonic-buffet-on-sc%282%29-0518-and-oat15a-with-vortex-generators.pdf)). |
| WMLES / WRLES | Good, costly | Good agreement with OAT15A experiments ([MIT, Nguyen group](https://www.mit.edu/~cuongng/publication/pub95/pub95.pdf)). |
| Standard LBM | Invalid | Compressible or hybrid LBM is required. |

**Accuracy evidence**
- **AIAA Drag Prediction Workshop (DPW), cruise drag:** code-to-code scatter fell from about ±50 counts in DPW-I to about ±5 counts in DPW-V and DPW-VI ([Tinoco, NASA CR-2019-220284](https://ntrs.nasa.gov/citations/20190027400)).
- **DPW-V:** one standard deviation was below 1% of ~250 counts, i.e. about 2.5 counts. Turbulence model is "a source of bias that won't be reduced by grid resolution" ([Morrison, NTRS 20130003238](https://ntrs.nasa.gov/api/citations/20130003238/downloads/20130003238.pdf)). The industry target is ±1 count.
- **DPW-7 (2022):** 18 organisations submitted 34 data sets at M = 0.85. Results were consistent through pitch-up (C_L ≈ 0.61), with "significant spread in solvers post pitch-up". SA versus k-ω differences are a suspected cause, and the field is "inconclusive regarding best practices for buffet" ([Pomeroy, NASA 2024](https://ntrs.nasa.gov/api/citations/20240005798/downloads/Buffet%20v4.pdf)). One participant found EARSM drag higher than SA, and closer to experiment, because it predicts a more upstream shock ([Chalmers](https://research.chalmers.se/en/publication/542330)).
- **SLS ascent database:** CFD-to-tunnel pitching-moment scatter peaked at Mach 0.95 ([Shea et al., NTRS 20200002382](https://ntrs.nasa.gov/api/citations/20200002382/downloads/20200002382.pdf)).

**Open-source solvers.** SU2 `RANS` (Roe, HLLC, AUSM, JST); OpenFOAM `rhoPimpleFoam`/`rhoCentralFoam`; FUN3D (the DPW workhorse).

---

## 4. Supersonic (1.2 < M < ~5)

**Physics**
- Attached oblique shocks, detached bow shocks on blunt noses, Prandtl–Meyer expansion fans and Mach cones.
- Wave drag, which depends on how the body's cross-sectional area is distributed along its length.
- The flow is hyperbolic: disturbances do not propagate upstream.
- Base flow behind blunt bodies: a recirculating wake that sets base drag.
- Rocket plumes: plume-induced flow separation (PIFS) and base heating.
- Aerodynamic heating starts to matter: the stagnation temperature ratio is 1+0.2M², which is 2.8 at M = 3 *(computed)*.

**Equations and methods.** Compressible RANS with an upwind Riemann solver: Roe + entropy fix, HLLC, or AUSM+. MUSCL with a limiter (minmod, van Albada, Venkatakrishnan).

Watch for the **carbuncle**: Roe-type schemes distort strong bow shocks. Quirk attributed this to insufficient dissipation. A Harten entropy fix cures it ad hoc, and HLLE avoids it ([Notre Dame AIAA 2015 slides](https://www3.nd.edu/~powers/paper.list/slides_aiaa2015.pdf)). Not every entropy fix works: the Harten–Hyman fix acts only on expansions and does not cure the carbuncle ([Zhou & Yan 2009](https://bhxb.buaa.edu.cn/bhzk/en/article/id/8980)).

OpenFOAM's `rhoCentralFoam` instead uses Kurganov–Tadmor central-upwind fluxes ([OpenFOAM docs](https://doc.openfoam.com/2212/tools/processing/solvers/rtm/compressible/rhoCentralFoam/)).

| Solver | Valid? | Why |
|---|---|---|
| Linear supersonic panel / slender-body / shock-expansion | OK for slender bodies at small α | Linear theory. No blunt nose, base or plume. |
| Euler | Good for forebody pressures and shocks | No base or viscous drag. |
| Steady RANS | Good for forebody forces, poor for base flow | Early RANS failed to reproduce the base-pressure level on the Mach 2.46 Herrin–Dutton afterbody ([Simon, Deck & Guillen 2006](https://cfd.spbstu.ru/agarbaruk/doc/2006_Simon-Deck-Guillen_Reynolds-averaged-Navier-Stokeslarge-eddy-simulations-of-supersonic-base-flow.pdf)). |
| DDES / ZDES | Good for base flow | Relatively good mean wake and base pressure on the same case ([same](https://cfd.spbstu.ru/agarbaruk/doc/2006_Simon-Deck-Guillen_Reynolds-averaged-Navier-Stokeslarge-eddy-simulations-of-supersonic-base-flow.pdf); [Garbaruk et al. 2009](https://cfd.spbstu.ru/agarbaruk/doc/2009_Garbaruk-et-al._Supersonic-base-flow-experiments-in-the-near-wake-of-a-cylindrical-afterbody.pdf)). |
| Potential / incompressible / standard LBM | Invalid | Shocks are not isentropic and the flow is hyperbolic. |

**Accuracy evidence**
- **SLS Block 1B ascent database** (tunnel at M 0.5–2.5 plus FUN3D at tunnel and flight conditions): CFD at tunnel conditions "compared well". The largest differences were in pitching moment. CFD axial force was generally lower than tunnel values. Ground-to-flight uncertainty was the largest uncertainty term from M 0.5 to 1.6 ([NTRS 20200002382](https://ntrs.nasa.gov/api/citations/20200002382/downloads/20200002382.pdf)).
- **Sonic Boom Prediction Workshops:** M = 1.6 near-field signatures, compared participant against participant ([USM3D SBPW2](https://ntrs.nasa.gov/citations/20170006501)). The SBPW2 summary (Park & Nemec) reports that the quieter configurations exposed weaknesses in convective discretisation. *(Summary paper's URL not verified.)*
- **Plumes:** SLS predicts PIFS and base heating semi-empirically from Shuttle and Saturn V data. CFD and semi-empirical predictions "show significant differences" ([NTRS 20180003486](https://ntrs.nasa.gov/api/citations/20180003486/downloads/20180003486.pdf)).

**Open-source solvers.** SU2; OpenFOAM `rhoCentralFoam`; FUN3D; Eilmer.

---

## 5. Hypersonic (M > ~5)

**Physics**
- Thin shock layers and strong viscous–inviscid interaction.
- Entropy layers from blunt noses.
- Severe heating that dominates design. Transition is a major uncertainty.
- Above ~2000 K: vibrational excitation, dissociation and ionisation, i.e. real-gas, thermochemical nonequilibrium effects.
- Wall catalysis, ablation, radiation.
- Rarefaction at high altitude, measured by the Knudsen number (Kn). The conventional continuum/transition boundary is Kn ≈ 0.1, with free-molecular flow above about Kn = 10. Below Kn ≈ 0.1 DSMC is limited and continuum CFD is preferred ([arXiv 2401.13344](https://arxiv.org/abs/2401.13344)).

**Equations and methods.**
- Compressible Navier–Stokes plus species continuity equations.
- Two-temperature models (Park), finite-rate chemistry, catalytic wall boundary conditions.
- Robust, positivity-preserving fluxes (AUSM-family, HLLE/HLLC) with carbuncle control, plus shock-aligned grids.
- DSMC in the transition and free-molecular regimes.

| Solver | Valid? | Why |
|---|---|---|
| Newtonian / modified Newtonian | OK for blunt-body pressure | No heating detail. |
| Perfect-gas RANS | OK at low enthalpy only | Real-gas effects raise peak SBLI heating by up to 20% ([Bose et al., NTRS 20110014963](https://ntrs.nasa.gov/api/citations/20110014963/downloads/20110014963.pdf)). |
| Nonequilibrium RANS (US3D, FUN3D generic-gas, hy2Foam, Eilmer, SU2 NEMO) | Standard tool | See error bars below. |
| LES / DNS | Research use for transition and SBLI | Cost. |
| DSMC (SPARTA) | Required for Kn ≳ 0.1 | Particle-based. Impractically costly at low Kn. |
| Standard LBM / incompressible / potential | Invalid | — |

**Accuracy evidence** (NASA uncertainty assessment, [Bose et al. 2011](https://ntrs.nasa.gov/api/citations/20110014963/downloads/20110014963.pdf)):
- Compression-corner SBLI with separation: ±55% combined prediction uncertainty, or 64% including experimental uncertainty. "No turbulence model … stood out as the superior one."
- Impinging shock on a turbulent boundary layer (95% confidence): ±55% heating and ±15% pressure.
- Mars entry heating: ±15% at low enthalpy (<5 MJ/kg) and ±60% at high enthalpy (>10 MJ/kg).
- 15 km/s Earth return stagnation-point heating: +78%/−53%.

Other evidence:
- **CUBRC double cone (M ≈ 12, laminar):** in the blind comparison, five codes overpredicted forebody heating by about 20% and the separation zone was slightly too large ([NATO EN-AVT-162-15](https://www.sto.nato.int/publications/STO%20Educational%20Notes/RTO-EN-AVT-162/EN-AVT-162-15.pdf)). A later Sandia UQ study found underprediction in the same region ([SAND2018-13668C](https://www.sandia.gov/app/uploads/sites/203/2022/06/sand2018-13668C.pdf)), so the sign of the error is unsettled.
- **Turbulence models:** SST overpredicts SBLI heat flux and SA underpredicts it ([arXiv 2412.13985](https://arxiv.org/pdf/2412.13985)).
- **Hypersonic workshops:** the Blottner sphere was used at the 2022 NASA/AIAA High-Fidelity CFD Workshop ([WUSTL thesis](https://openscholarship.wustl.edu/eng_etds/821/)).

**Open-source and government solvers**
- [hy2Foam](https://strathprints.strath.ac.uk/59682/): OpenFOAM, two-temperature, 11-species air; validated at M 11 on a cone and against DSMC at M 20.
- [Eilmer](https://arxiv.org/pdf/2206.01386): UQ, open source, compressible Navier–Stokes with high-temperature gas models.
- [US3D](https://www.iccfd.org/iccfd11/assets/pdf/papers/ICCFD11_Paper-3201.pdf): Minnesota/NASA Ames, finite-rate chemistry. Access is controlled.
- FUN3D generic gas path, derived from LAURA; beta access, separate agreement required ([FUN3D slides](https://fun3d.larc.nasa.gov/session9_2018.pdf)).
- SU2 NEMO ([docs](https://su2code.github.io/docs_v7/Solver-Setup/)).
- [SPARTA](https://www.sandia.gov/research/publications/details/sparta-an-open-source-dsmc-code-for-turbulence-and-re-entry-modeling-2018-01-01/): Sandia, open-source DSMC.

---

## How launch-vehicle aero databases handle regimes

- **Ares I (DAC-3):** tunnel testing at M 0.5–1.6 (Boeing Polysonic) and M 1.6–4.5 (Langley Unitary Plan). Tunnel data built the baseline response surfaces; CFD (USM3D) supplied increments and the tunnel-to-flight Reynolds-number correction. The two facilities agreed at the M 1.6 overlap ([NTRS 20110002871](https://ntrs.nasa.gov/api/citations/20110002871/downloads/20110002871.pdf)).
- **SLS:**
  - Wind tunnel is the primary source because it is the most cost-effective way to collect large data volumes ([NTRS 20140004078](https://ntrs.nasa.gov/api/citations/20140004078/downloads/20140004078.pdf)).
  - More than 1,300 FUN3D and Overflow cases over Mach × α × roll ([NTRS 20180001534](https://ntrs.nasa.gov/api/citations/20180001534/downloads/20180001534.pdf)).
  - Block 1B uncertainty is a root-sum-square of the individual terms × 1.05 for "unknown unknowns" ([NTRS 20200002382](https://ntrs.nasa.gov/api/citations/20200002382/downloads/20200002382.pdf)).
- **Pattern:** a Mach sweep that is dense through 0.8–1.3, response surfaces in (M, α, β), CFD for Reynolds-number and flight corrections, and plumes and base flow handled separately.

---

## Cross-regime summary (good / ok / poor / invalid)

| Solver | Incomp. <0.3 | Comp. subsonic 0.3–0.8 | Transonic 0.8–1.2 | Supersonic 1.2–5 | Hypersonic >5 |
|---|---|---|---|---|---|
| Panel / VLM | good (attached) | ok (with P-G/K-T) | invalid | poor (linear supersonic panel: ok) | invalid |
| Full potential / TSD | good | good | ok (weak shocks) | poor | invalid |
| Euler | ok (no viscous) | ok | ok | good (forebody) | ok (pressure only) |
| Steady RANS | good | good | good at cruise, poor in buffet | good forebody, poor base | ok with nonequilibrium models; heating ±15–55% |
| URANS | good | good | ok (buffet, model-dependent) | ok | ok |
| DDES / ZDES | good | good | ok (ZDES); DDES risky for onset | good (base flow) | research |
| WMLES / LES | good | good | good (costly) | good (costly) | research |
| DNS | good (low Re only) | good (low Re) | research | research | research (transition) |
| LBM, standard | good | poor | invalid | invalid | invalid |
| LBM, compressible / hybrid | good | ok | ok (emerging) | poor (stability) | invalid |
| DSMC | invalid (cost) | invalid | invalid | invalid | required when Kn ≳ 0.1 |

---

## Phenomena worth animating

1. **Subsonic to transonic airfoil Mach sweep (2D, Euler/RANS).** An honest simulation shows Cp growing roughly as 1/√(1−M²), then a supersonic pocket appearing at M_cr. It is closed by a shock that strengthens and moves aft, and C_D rises sharply. A Prandtl–Glauert overlay should visibly diverge near M = 1.
2. **Transonic buffet (2D OAT15A, URANS-SST).** The shock oscillates at ~70 Hz and the separation bubble breathes. Show the caveat: SA gives a steady solution at the same conditions.
3. **Wedge versus blunt nose at M = 2–3 (2D Euler).** An attached oblique shock against a detached bow shock, a Prandtl–Meyer fan at the shoulder, and the Mach-cone half-angle shrinking with Mach number as μ = asin(1/M). Optionally, add Roe without an entropy fix on the blunt nose to show a carbuncle artefact.
4. **Rocket base flow and plume at M ≈ 2.5 (axisymmetric, DDES).** A recirculating base region, an expansion around the base corner, and a recompression shock. As altitude rises the plume balloons and separates the body boundary layer (PIFS). Label it as qualitative, since even NASA uses semi-empirical methods here.
5. **Hypersonic blunt body, perfect gas versus reacting gas (2D, M ≈ 10–20).** Real-gas chemistry moves the bow shock closer to the body and cools the post-shock gas. Stagnation heating should be shown with error bars of ±15–60%. Also show where Kn > 0.1 at altitude marks the point where DSMC must take over.

## Sources (primary, by regime)

- **Compressibility basics:** [Georgia Tech critical Mach notes](https://sankar.gatech.edu/AE3021/CriticalMachNumber.pdf) · [ERAU](https://eaglepubs.erau.edu/compsimforaero/chapter/c-2/)
- **Drag Prediction Workshops:** [Tinoco 2019](https://ntrs.nasa.gov/citations/20190027400) · [Morrison DPW-V](https://ntrs.nasa.gov/api/citations/20130003238/downloads/20130003238.pdf) · [Pomeroy 2024 buffet plan](https://ntrs.nasa.gov/api/citations/20240005798/downloads/Buffet%20v4.pdf)
- **Buffet:** [Deck 2005](https://cfd.spbstu.ru/agarbaruk/doc/2005_Deck_Numerical-Simulation-of-Transonic-Buffet-over-a-Supercritical-Airfoil.pdf) · [Thiery & Coustols 2006](https://cfd.spbstu.ru/agarbaruk/doc/2006_Thiery-Coustols_Numerical-prediction-of-shock-induced-oscillations-over-a-2D-airfoil-Influence-of-turbulence-modelling-and-test-section-walls.pdf) · [MIT LES](https://www.mit.edu/~cuongng/publication/pub95/pub95.pdf)
- **Supersonic base flow:** [Simon, Deck & Guillen 2006](https://cfd.spbstu.ru/agarbaruk/doc/2006_Simon-Deck-Guillen_Reynolds-averaged-Navier-Stokeslarge-eddy-simulations-of-supersonic-base-flow.pdf)
- **Hypersonic uncertainty:** [Bose et al. 2011](https://ntrs.nasa.gov/api/citations/20110014963/downloads/20110014963.pdf) · [NATO EN-AVT-162-15](https://www.sto.nato.int/publications/STO%20Educational%20Notes/RTO-EN-AVT-162/EN-AVT-162-15.pdf) · [arXiv 2412.13985](https://arxiv.org/pdf/2412.13985)
- **Launch-vehicle databases:** [SLS Block 1B database](https://ntrs.nasa.gov/api/citations/20200002382/downloads/20200002382.pdf) · [Ares I DAC-3](https://ntrs.nasa.gov/api/citations/20110002871/downloads/20110002871.pdf)
- **LBM:** [arXiv 0801.2924](https://arxiv.org/pdf/0801.2924) · [arXiv 2107.01370](https://arxiv.org/pdf/2107.01370)
- **Rarefied flow:** [arXiv 2401.13344](https://arxiv.org/abs/2401.13344)
