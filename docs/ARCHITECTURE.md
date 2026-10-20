# Architecture

C++20 core with no Qt dependency, a thin explicit GPU layer over Metal and Direct3D 12, Slang shaders compiled to
MSL / DXIL at build time, and a Qt 6 Quick app on top. One CMake project at the repository root.

## Layout

| Path | Target | Contents |
|---|---|---|
| `src/core` | `pwcore` (static, no Qt) | math (`pw/math.h`, double world / float render), JSON, job system (`pw/jobs.h`), CPU feature dispatch + SIMD kernels, craft documents / CAD import / auto-rig (`pw/craft`), collision (`pw/collision`), craft physics `CraftSim` + aero profiles + equation capture (`pw/sim`), worlds (`pw/world`), evolution (`pw/evo`), JavaScript scripting (`pw/script`), self-test registry |
| `src/gpu` | `pwgpu` | device, buffers, textures, graphics + compute pipelines, graphics and async-compute queues, fences, triple-buffered frames, GPU timestamps (`pw/gpu.h`); GPGPU layer for simulation kernels (`pw/compute.h`). Metal in Objective-C++, Direct3D 12 with a WARP fallback |
| `src/render` | `pwrender` | frame graph, sky / aerial-perspective LUTs, cascaded shadows, PBR meshes, TAA, bloom, ACES, debug lines, `CraftRenderable` |
| `src/env` | `pwenv`, `pwenv_render` | terrain (flat / procedural + GPU erosion / heightmap / real-world DEM tiles, sculpt + paint), FFT ocean, lakes, rivers, buoyancy, FLIP fluid zones, vegetation, grass; their renderables |
| `src/app` | `pwapp` ("Plane World"), `pwuitests` | Qt Quick UI (`qml/`), `AppController` (BUILD / FLY), `WorldModel`, `EvolveModel`, `GpuViewport` / `WorldViewport` |
| `src/cli` | `pwcli` | headless `--selftest`, `--train`, `--bench`, `--gpu-smoke`, `--render-shot`, `--info` |
| `shaders` | `pw_shaders` | Slang sources (`scene.slang`, `env/`), embedded per backend by `cmake/PWSlang*.cmake` |
| `data`, `examples` | | bundled crafts and experiment presets (embedded at build time), example crafts and experiments |
| `tests` | `pwtests` | doctest suite; `tests/parity` (reference trajectories, unit samples, training histories) and `tests/render_ref` |
| `packaging` | | `.dmg` and `.msi` scripts ([PACKAGING.md](PACKAGING.md)) |

Dependencies point downward only: `pwcore` ← `pwgpu` ← `pwrender` ← `pwenv_render` ← `pwapp`; `pwenv` needs
`pwcore` + `pwgpu`. The core has no link-time dependency on the GPU.

## UI

`src/app/qml/Main.qml` holds four tabs (BUILD, FLY, WORLD, EVOLVE), each a `TabPage` with a GPU viewport and an
inspector panel. Controls come from the native Qt Quick Controls style (macOS / Windows) plus a small design system:
`Theme.qml` (4 px spacing grid, type scale, colors for light and dark) and the `Pw*` components (`PwSection`, `PwCard`,
`PwPropertyRow`, `PwSlider`, `PwSegmented`, ...). `AeroModelPicker.qml` is the aero model list shared by FLY and EVOLVE.
Every action is in the command palette (Ctrl/⌘+K, `AppCommands.qml`) with its shortcut.

`pwapp` flags: `--tab build|fly|world|evolve`, `--color-scheme dark|light`, `--size WxH`, `--command "<palette entry>"` or `"wait <s>"`
(repeatable, runs 1 s after launch), `--screenshot file.png --quit-after <s>`.

## Threading

- **GUI thread:** `AppController`, `WorldModel` and `EvolveModel` live here. FLY steps `CraftSim` from a display-rate
  timer with 1 kHz substeps. Viewports read their render snapshot (document revision, part poses) in
  `updatePaintNode`, which Qt runs while the GUI thread is blocked, then record on Qt Quick's own Metal / D3D12 device
  and queue and composite the output texture without a copy.
- **Job system** (`pw/jobs.h`): work-stealing, topology aware (Apple P/E clusters, Ryzen CCDs, Intel P/E). Used for
  CAD panel aero, terrain bakes and the training evaluator.
- **Training:** `EvolutionRun` runs generations on a background thread; `SimEvaluator` spreads episodes over the job
  system, one `EvalWorker` per thread with a zero-allocation episode loop.
- **GPU:** async compute for the sky LUTs and simulation kernels, joined to graphics by fences.
- **World I/O:** real-world DEM tiles download on I/O threads into a disk cache.

## Determinism

- The physics step is deterministic and allocation-free after `load()` (tested for every craft and aero profile).
  Serial, parallel and every SIMD level (scalar / NEON / AVX2 / AVX-512) give identical bits: reductions run in a fixed
  order, and FMAs are explicit (`std::fma`); the build uses `-ffp-contract=off` / `/fp:precise`
  (`cmake/PWCompilerFlags.cmake`).
- `tests/parity` holds reference data recorded with the original Swift implementation: 30 trajectories (5 crafts ×
  3 fast profiles × ground / air), 19k unit samples, simd results, evolution runs and training histories. On macOS
  arm64 all of it is reproduced bit for bit. On Windows the platform libm differs in the last ulp, so trajectories are
  compared with tolerances (1e-9 for the first second, 1e-6 over 3 s) and training generation 0 within 5 %.
- Training results do not depend on the worker count: each episode seed derives from (run seed, generation,
  candidate, episode) via `EvoRNG::derive` (`src/core/src/evo/evaluator.cpp:288`), and results are written by index. `tools/train_parity.sh` checks 1 vs 4 workers.

## GPU backends and shaders

Shaders are written once in Slang (`shaders/`). At build time `slangc` produces MSL (macOS) or HLSL that the Windows
SDK `dxc` turns into DXIL; the blobs are embedded in the binaries (`cmake/PWSlang.cmake`, `PWSlangLib.cmake`), and
Slang's reflection JSON remaps Metal storage-texture indices so both APIs share one binding model (b0-3 constants,
t0-7 textures, t8-11 / u8-11 buffers, s0-3 static samplers). A per-vendor tuning table picks the TAA tile, wave size,
async compute and shadow resolution. CI runs the Direct3D 12 path on WARP.

## Tests

| Command | Covers |
|---|---|
| `build/tests/pwtests` | doctest: math, JSON, parity, physics, collision, environment, evolution, scripting, flow, GPU readback, renderer vs `tests/render_ref` |
| `build/src/app/pwuitests` (`QT_QPA_PLATFORM=offscreen`) | WORLD and EVOLVE view models |
| `build/src/cli/pwcli --selftest all` | the self-test registry (`--selftest list` for groups) |
| `bash tools/train_parity.sh build/src/cli/pwcli` | example experiments vs recorded histories, 1 and 4 workers |
