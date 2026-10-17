# Plane World — C++ / Qt 6 port

Phase 0 of [docs/PORT_PLAN.md](../docs/PORT_PLAN.md). The Swift app stays the shipping version.

| Target | What |
|---|---|
| `pwcore` | C++20 static lib, no Qt: math, JSON, SIMD dispatch (NEON / AVX2 / AVX-512, bit-identical reductions), ported wing/prop/wake unit physics, parity loader, self-tests |
| `pwgpu` | GPU device: Metal (Objective-C++) / Direct3D 12 (WARP fallback); Slang shaders → MSL / DXIL embedded at build time |
| `pwapp` | Qt 6 Quick app, native Qt Quick Controls style, BUILD/FLY/WORLD/EVOLVE, ⌘K/Ctrl+K command palette, GPU viewport sharing Qt's device |
| `pwtests` | doctest: core, parity (`tests/parity`), GPU readback |
| `pwcli` | `--selftest`, `--gpu-smoke [--warp]`, `--bench`, `--info` (`--train` arrives in phase 2) |

## Build (macOS)

    brew install cmake ninja qt
    # Slang: official release from github.com/shader-slang/slang, unpacked to ~/.local/slang-<ver> or SLANG_DIR
    cmake -S cpp -B cpp/build -G Ninja -DCMAKE_PREFIX_PATH=$(brew --prefix qt)
    cmake --build cpp/build
    cpp/build/tests/pwtests && cpp/build/src/cli/pwcli --selftest all
    open "cpp/build/src/app/Plane World.app"

Windows is built in CI (`.github/workflows/cpp.yml`): MSVC + Ninja, Qt via install-qt-action, Slang → HLSL → DXIL with
the Windows SDK `dxc`, tests and a WARP Direct3D 12 smoke test.

## Parity data

`tests/parity` is produced by the Swift app: `swift build -c release && .build/release/PlaneWorld --export-parity cpp/tests/parity`
(from the repo root). 5 crafts × 3 fast aero profiles × 2 scenarios (ground / air), 3 s at 1 kHz, sampled every
10 ms, plus `units.json` (wing, propeller, misc, rotor-wake samples). Doubles are shortest round-trip decimals.
Compiled with `-ffp-contract=off` / `/fp:precise`, the C++ unit physics currently reproduces all 19,441 unit values
bit-for-bit on Apple clang.

## Physics core (phase 1a)

| Header | What |
|---|---|
| `pw/math.h` | `Vec3d` / `Quatd` / `Mat3d` that reproduce Apple `<simd/simd.h>` (as Swift calls it on arm64) bit for bit: the FMAs Apple's headers contract are explicit `std::fma` (correctly rounded on every platform), `simd_inverse` follows libsystem_m's `__invert_d3`, Swift `min`/`max`/`clamp` and prefix-minus semantics. Checked against `tests/parity/simd.json` (`tools/simd_reference.swift`). |
| `pw/render_math.h` | float render math: `Float4x4`, look-at, reverse-Z perspective, camera-relative model matrices |
| `pw/jobs.h` | work-stealing job system, zero-allocation `parallelFor` / reusable `ParallelLoop`, topology aware (Apple P/E clusters, Ryzen CCDs and Intel P/E on Windows with per-cluster pinning, Linux L3 groups) |
| `pw/simd_kernels.h` | runtime-dispatched kernels (scalar / NEON / AVX2 / AVX-512), each ISA in its own TU, bit-identical across ISAs (CAD panel aero today) |
| `pw/atmosphere.h` | ISA atmosphere, log-profile wind + frozen turbulence |
| `pw/sim/*` | `CraftSpec` (craft JSON / `craft::CraftDocument`), `CraftSim` (servos, wing strips with stall / flaps / ground effect, body drag, CAD panels with occlusion, props / ducts / rotor ground effect / slipstream with swirl, jets, solids, fuel and CoM, ground contact, tyres, buoyancy hook, sensors), Fast+ effects (gyro, P-factor, downwash, blockage, CAD wash), equation capture, aero profiles |

Verification: on macOS arm64 all 30 reference trajectories and the Swift self-test trajectory digests
(`pwcli --selftest physics.trajectory-digest`) are reproduced bit for bit; the step allocates nothing (tested for
every craft and profile); serial / parallel / every SIMD level give identical bits. On Windows the platform libm
differs from Apple's in the last ulp, so runs are compared with tolerances (1e-9 for the first second, 1e-6 over 3 s);
the ducted rocket with the slipstream model is excluded there because the wake cut-offs make it discontinuous.

## Evolution + headless training (phase 2a)

| Header | What |
|---|---|
| `pw/evo/types.h` | `EvoRNG` (xoshiro256** via SplitMix64, `derive` seed paths), `GeneSpec` / `GenomeLayout`, NEAT genome data, `Genome`, `Fitness`, `EliteArchive`, JSON codecs with the Swift key names (64-bit seeds / ids exact) |
| `pw/evo/algorithm.h` | ask/tell `Algorithm`, registry, operators (tournament / roulette / rank, uniform / one-point / blend / SBX, gaussian / polynomial, iso+line) and the built-ins: `random`, `simple-es`, `ga`, `cmaes` (IPOP / BIPOP), `sep-cmaes`, `openai-es`, `neat`, `map-elites` (grid + CVT), `novelty`, plus `script` (JS `ask`/`tell`) |
| `pw/evo/experiment.h` | `ExperimentDocument` (same JSON as the Swift app, same tolerant / synthesized-Codable decode rules), presets, craft resolution |
| `pw/evo/policy.h` | allocation-free `MLPPolicy`, lane-batched `MLPBatch`, `NEATNetwork` (feed-forward / recurrent), design decoder |
| `pw/evo/script.h` | evolution script runtimes: none, C++ closures, the preset scripts natively, and any JavaScript through `pw/script` (JavaScriptCore / QuickJS) incl. select / crossover / mutate hooks |
| `pw/evo/evaluator.h` | headless world + static obstacles, `ExperimentContext`, `EvalWorker` (zero-allocation episode loop), `SimEvaluator` (job-system parallel, results independent of the thread count) |
| `pw/evo/run.h` | `EvolutionRun` (history, hall of fame, background loop, checkpoint / resume in the Swift run-directory format, export of the best craft with its embedded controller), replay, `EvolvedAutopilot` |

`pwcli --train <experiment.json> [--generations N] [--out dir] [--resume] [--current-as-flat] [--script-engine auto|jsc|quickjs]`
prints the Swift CLI's per-generation lines and writes `history.csv`, `run.json`, `algorithm.state` and `best-craft.json`.

Verification (`pwcli --selftest evolution-algo.` / `evolution.`, `pwtests -tc="evolution*"`): on macOS every number the Swift
algorithm self-tests print (CMA-ES sphere / Rosenbrock / IPOP + BIPOP Rastrigin, sep-CMA-ES, OpenAI-ES, 12 GA
configurations, NEAT XOR + species control, MAP-Elites / CVT coverage, novelty archive) is reproduced bit for bit, and four
training runs recorded with the Swift app (`tests/parity/evolution`: neural controller with sep-CMA-ES, craft design with
the GA, NEAT controller, MAP-Elites) give bit-identical fitness histories, hall of fame genomes and NEAT topologies — with
1, 4 or all workers, with the native preset runtime and on both JavaScript engines. Checkpoint → resume continues
bit-identically for every algorithm; the episode loop allocates nothing per control tick. On Windows (different libm in the
last ulp) the same criteria as the Swift tests are checked, and generation 0 of the parity runs must agree within 1e-6.

## GPU layer + renderer (phase 3a)

| Target | What |
|---|---|
| `pwgpu` (`pw/gpu.h`) | thin explicit backend over Metal and Direct3D 12: buffers (device / upload / readback), textures (2D, 2D array, 3D, mips, views), graphics + compute pipelines from the Slang library, command lists on the graphics and async compute queues, cross-queue fences, triple-buffered frames with a per-frame upload ring, per-pass GPU timestamps, a per-vendor tuning table (TAA tile, wave size, async compute, shadow resolution). One binding model on both APIs (b0-3 / t0-7 / t8-11 buffers / u8-11 / s0-3 static samplers); D3D12 states tracked per subresource; Slang's Metal storage-texture indices remapped from its reflection JSON |
| `pwrender` (`pw/render/*.h`) | port of Sources/Render: frame graph (culling, transient aliasing, queue switches joined by fences), sky-view + aerial-perspective LUTs (async compute), 4 cascaded shadow maps with far-cascade caching, PBR mesh pipeline, sky + sun disk, tiled TAA, bloom mip chain, ACES tonemap, debug lines, instanced meshes and craft part meshes (`CraftRenderable`) |

The Qt viewport (`GpuViewport`) runs the renderer on Qt Quick's own Metal / D3D12 device and queue and composites its
output texture without copies (orbit camera: drag / scroll / arrows+WASD / F / Home, `[` `]` time of day, G per-pass GPU times).

Verification: `pwtests -tc="gpu*,render*"` (compute + readback, async compute fence, instanced indexed draws with depth,
timestamps, ring overflow, frame-graph culling / aliasing, async vs. graphics-queue LUTs identical, craft parts visible)
and a screenshot test against the Swift renderer's image (`tests/render_ref`, same scene): 47 dB PSNR on Apple M4.
`pwcli --render-shot out.png [--warp]` writes the test scene; CI runs it on WARP and uploads the screenshots.

## Terrain, water, vegetation (phase 3b)

| Target / header | What |
|---|---|
| `pwgpu` `pw/compute.h` | GPGPU layer for simulation kernels (read-write storage buffers + atomics, which the renderer's binding model leaves out): b0 root constants, u1..u8 buffers on Metal and Direct3D 12 (WARP on CI). Kernels: `shaders/env/{erosion,ocean,fluid}.slang` (`cmake/PWSlangLib.cmake`) |
| `pwenv` `pw/env/terrain.h` | `TerrainSystem` (the app's `TerrainProvider`): flat / procedural (fBm, ridged, warp) / heightmap (PNG 8/16-bit, JPEG, .r16) / real-world DEM (AWS terrarium tiles, I/O threads, disk cache in the user cache dir); hydraulic + thermal erosion on the GPU with a CPU implementation of the same kernels (bit-identical on every platform, used for headless bakes); sculpt (raise / lower / smooth / flatten) and paint, persisted as raw-DEFLATE Float16 deltas byte-compatible with the Swift app; min/max pyramid, dirty chunks, CDLOD node selection |
| `pwenv` `pw/env/water.h` | `WaterSystem` (`WaterProvider`): JONSWAP spectrum, 3-cascade FFT ocean on the CPU (deterministic) or GPU, lock-free sampling with choppy inversion; lakes / rivers; exact clipped buoyancy + drag / skin friction / radiation damping (zero allocations in steady state); splashes; GPU FLIP fluid zones with two-way box coupling (integer atomics: deterministic) |
| `pwenv` `pw/env/vegetation.h` | space-colonisation trees + palms (LOD0 / LOD1 / shadow proxy), octahedral impostor mapping, habitat scatter with groves, tree / erase / grass brushes, breakable trees (rigid bodies in `collision::RigidWorld` or a pivot integrator), grass density maps |
| `pwenv_render` `pw/env/render.h` | Renderables for `pwrender`: CDLOD terrain with shadows, FFT water with terrain depth absorption and shore foam, trees by distance with GPU-baked impostor atlases, GPU grass (`shaders/env/{terrain,water,vegetation,grass}.slang`) |

`pw::env::install()` plugs the terrain builder into `world::bake` (pwcli does this at start), so headless training
worlds get eroded terrain, PNG heightmaps and sculpt edits.

Verification: `pwcli --selftest terrain.` / `water.` / `vegetation.` / `env.` / `envrender.` (also in `pwtests`): the Swift
self-tests ported (continuity, raycast, sculpt + paint + persistence, DEM decode / fetch / mosaic, buoyancy = rho g V,
Archimedes draft, FFT vs. direct sum, floating box in a seaway, FLIP dam break and coupling, species / 200k-tree
placement / brushes / breaking) plus GPU-vs-CPU erosion (max deviation 1e-4 m), GPU-vs-CPU ocean (5e-7 m), a stream
written by the Swift app's codec, CDLOD tiling, and an offscreen coast scene through the renderer
(`PW_SELFTEST_OUT=dir` keeps the PNGs). On Apple M4, 1920x1080 terrain + ocean + 57k trees + 77k grass blades render in
about 12.5 ms of GPU time (`envrender.perf-1080p`).

## CFD: lattice-Boltzmann on the GPU (phase 4)

| Target / header | What |
|---|---|
| `pwcore` `pw/sim/cfd.h`, `pw/sim/full_aero.h` | the fidelity contract of Sources/Core/Fidelity.swift: `CFDSettings` (presets, tolerant JSON with the Swift keys), `CFDDiagnostics`, the per-substep `AeroBackend` / batched `AeroDomainPool` interfaces and their registry; `CraftSim` runs `AeroModel::Full` exactly like FullAero.swift (forces lag one update, props stay momentum-theory and become actuator disks, equation-capture comparison rows); the evaluator trains with `aero.model = "full"` |
| `pwflow` `pw/flow/lbm.h` | port of Sources/Flow: craft-following D3Q19 / D3Q27 domain, BGK / TRT ("mrt") / regularized collision (cumulant runs regularized, as in Swift), Smagorinsky (van Driest damped) or WALE LES, moving Galilean frame, per-update re-voxelisation from part SDF grids, interpolated (Bouzidi) bounce-back with moving walls, Galilean-invariant momentum exchange, actuator disks (thrust + swirl, Guo forcing), ground as a moving wall, far-field shell + sponge, lattice-Mach control with population rescaling, divergence reset, 2x-coarser shadow grid (Richardson estimate), slice + tracer products, `LBMDomainPool` (several domains in one GPU submission). Kernels: `shaders/flow/lbm_common.slang` (one Slang source, MSL + DXIL) on the `pw/compute.h` layer |
| `pwflow_render` `pw/flow/overlay.h` | `FlowOverlay` Renderable: the slice as a world-space turbo quad + tracer dots (`shaders/flow_overlay.slang`) |

Port notes: all reductions (per-part force / torque, mass, fluid cells) are 64-bit fixed point accumulated with 32-bit
integer atomics after a wave reduction: D3D12 SM 6.0 has no float atomics and Metal only a weak compare-exchange, and
integer sums are order independent, so pooled lanes equal a single domain bit for bit. Velocity sampling at the part
centres runs on the GPU, so a collect reads back a few hundred bytes. Kernels compile without fast math (as the rest
of `pw/compute.h`); with `PW_METAL_FAST=1` the actuator disk reproduces Swift's fast-math number exactly.
`submit` / `collect` allocate nothing after the first update (`pwtests -tc="flow*"`; on Metal the driver itself
allocates once per kernel per command buffer, never per step).

Parity with the Swift solver (`PlaneWorld --selftest flow`, same grids, Apple M4):

| Case | Swift | C++ (Metal) |
|---|---|---|
| sphere C_D, Re 1.3e5, 16 cells/D | 0.761 | 0.761 |
| cube C_D, 16 cells/side | 1.408 | 1.408 |
| NACA 0012 AR 2, lift slope (C_L at +-6 deg) | 0.92 /rad (+0.055 / -0.138) | 0.92 /rad (+0.055 / -0.138) |
| actuator disk, v at the disk | 9.21 m/s | 8.87 m/s (9.21 with `PW_METAL_FAST=1`) |
| rotating bar torque | -0.0331 N m | -0.0331 N m |
| fine vs coarse shadow delta | 40.8 % | 40.8 % |
| voxel volume sphere / NACA / box | 0.00444 / 0.00148 / 0.00400 m3 | identical |
| whole Trainer, `--aero-compare Trainer --speed 25 --alpha 4 --cfd-preset medium`, total CFD force | (-2288.6, 3042.8, -15.9) N | (-2288.2, 3042.6, -15.7) N |

`pwcli --aero-compare` is the Swift CLI's port (same flags and table). On software adapters (WARP on the Windows CI) or
with `PW_FLOW_SMALL=1` the flow tests run on coarser grids and compare with the same cases measured on Metal (sphere
0.947, cube 1.369, wing slope 1.68, disk 6.24 m/s).

Accuracy at equal cost (`PW_FLOW_VALIDATE=1 pwcli --selftest flow.accuracy`, same grids and step counts, Apple M4):

| Variant | sphere C_D (exp 0.47) | cube C_D (exp 1.05) | wing slope (Helmbold 2.60) | ms / LBM step |
|---|---|---|---|---|
| Swift numerics (default) | 0.761 | 1.408 | 0.92 | 0.571 |
| `accuracy.thinOnlyInflation` (depth rule) | **0.715** | **1.340** | 0.92 | 0.575 |
| wall-damping length 4 cells | **0.681** | 1.405 | 0.90 | 0.567 |
| both | 0.728 | 1.358 | 0.90 | 0.574 |

Swift inflates every part by 0.3 of its SDF cell so zero-thickness sheets cannot leak; that also fattens closed bodies
(sphere voxel volume +6 %). The depth rule inflates only sheets and parts whose interior is shallower than 1.5 lattice
cells (wings keep their sharp-edge seal: inflating nothing drops the wing slope to 0.41), which cuts the bluff-body drag
error by 6-9 points at no cost; it is opt-in (`LBMSolver::accuracy`, `pwcli --aero-compare --accurate`) so the default
stays Swift-identical. Refining the Bouzidi wall fraction with secant steps changed nothing measurable (kept as an
option). Coarse-grid lift is dominated by the unresolved boundary layer; no equal-cost fix for it was found.
