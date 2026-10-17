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
