# Plane World: performance baseline and hotspots

Measured on an Apple M4 (4 P-cores, 6 E-cores, 16 GB) with a release build (`-Ounchecked`). Other agents were
running on the machine at the same time: the load average was 13–24, and one java process held a full core.
CPU numbers are therefore noisy (±10–30 % on multi-thread runs). Where it matters, use the min column or re-run.
Raw output: `/tmp/pw-perf-prof/bench-all.txt` and `bench-all.json`.

## Harness

    swift build -c release --scratch-path <s>
    <s>/release/PlaneWorld --bench list
    <s>/release/PlaneWorld --bench all [--reps N] [--quick] [--json out.json]
    <s>/release/PlaneWorld --bench physics.substep        # a name, or a prefix group (physics, train, render, ...)

The harness lives in `Sources/App/BenchCLI.swift`. Each bench runs one warm-up and then `reps` repetitions, and
prints the median, min, max and half-range spread. `allocs/substep` counts every malloc in the process through a
`malloc_logger` hook, with the job pool idle.

| bench | what it measures |
|---|---|
| physics.substep.{trainer,jet,rover,rocket,cad60,cad60big} | `CraftSim.step` at 1 kHz on the flat headless world, with turbulence 0.3, plus allocations per substep |
| headless.episode.{js,null-script} | one 40 s training episode (neural.json, MLP + JS reward) on one worker |
| js.controller-call | `JSScriptRuntime.tick` (control, reward and terminate) per control tick |
| nn.forward | `MLPPolicy.forward` at the training size and two larger sizes |
| train.scaling | free-running throughput with N threads and no generation barrier. Also: heap-isolated workers, and E-core rate (background QoS) |
| train.generation | `EvolutionRun.runGeneration` with 1, 4 and 10 workers |
| terrain.erosion / terrain.noise | GPU hydraulic + thermal erosion (200 iterations), and CPU noise generation |
| water.fft | ocean spectrum + FFT GPU time per update, CPU step cost, CPU `sample()` cost |
| buoyancy | `WaterSystem.submergedForces` for hulls of 256, 2.3k and 16k triangles |
| fluid.step | `FluidZone.stepSync(1/60)` (GPU FLIP/PIC) |
| render.frame / cpu.frame | headless AppModel, offscreen 3200×1920, TAA, FLY and WORLD tabs. GPU per-pass timestamps; per-renderable cost by subtraction; main-thread tick and encode time |

## Baseline (median)

**Physics: one substep, single thread**

| craft | µs/substep | allocs/substep |
|---|---|---|
| Trainer, in air | 11.7 (10.9 when the machine was quiet) | 0 |
| Trainer, runway | 11.6 | 0 |
| Jet trainer, in air | 11.1 | 0 |
| Rover, ground | 3.65 | 0 |
| Sounding rocket | 6.7 | 0 |
| CAD craft, 60 parts / 5.3k panels (serial per mesh) | 173 | 0 |
| CAD craft, 60 parts / 21k panels (parallelFor per mesh) | 1070 | **185** |
| same 21k panels, `parallelThreshold = .max` (serial) | 688 | 0 |

**Training (neural.json: Trainer, MLP 9-12-4, JS reward, 40 s episodes at 1 kHz)**

| measurement | value |
|---|---|
| one episode, one worker | 530 ms (75 sim-s/s, 13.3 µs/substep including the episode loop) |
| same episode with the JS runtime replaced by a null one | 540 ms (no measurable difference) |
| JS `tick` per control tick | 1.01 µs (50 Hz → 0.05 ms per sim-second, about 0.4 % of an episode) |
| MLP forward 9-12-4 | 102 ns (about 0.04 % of an episode) |
| MLP 32-64-64-8 / 128-256-256-16 | 2.4 µs / 49 µs (4–6 GFLOP/s scalar) |
| train.generation 1 worker, population 16 | 60–76 sim-s/s (1.5–1.9 sims/s) |
| train.generation 4 workers, population 64 | 100–175 sim-s/s |
| train.generation 10 workers, population 64 | 227–239 sim-s/s (5.8–6.1 sims/s) |
| free-running, 1 thread (P-core) | 76–88 sim-s/s |
| free-running, 2 / 4 / 6 / 8 / 10 threads | 126 / 151–191 / 162–200 / 210–235 / 224–247 sim-s/s |
| efficiency at 4 and 10 threads | 50 % and 28–30 % |
| **heap-isolated workers, 4 and 10 threads** | **195–236 and 279–414 sim-s/s** (same machine, interleaved runs) |
| 1 thread on an E-core (background QoS) | 26–27 sim-s/s |
| 6 threads on E-cores (background QoS) | 121–125 sim-s/s |

**GPU and water**

| measurement | value |
|---|---|
| terrain.erosion 1025² | 314 ms GPU (1.57 ms per iteration); noise 50 ms CPU |
| terrain.erosion 2049² | 1296 ms GPU (6.5 ms per iteration); noise 292 ms CPU |
| water.fft (3 cascades of 256²) | 1.15 ms GPU per update; step 38–53 µs CPU; `sample()` 430 ns |
| buoyancy, 256 / 2304 / 16384 triangles | 17.5 / 131 / 295 µs per call (the 16k hull runs parallel) |
| fluid.step 32³ / 64³ | 2.1 / 4.7–10.5 ms per 1/60 s |

**Rendering at 3200×1920 (FLY, 69.5k trees)**

The FLY numbers come from the full `--reps 5` run, which was taken while the machine was loaded. The quick runs on
a quieter machine gave 12.2–12.4 ms of GPU time.

| measurement | value |
|---|---|
| GPU total | 12.2–16.7 ms (WORLD 12.2–15.0 ms) |
| skyLUT | 0.18 ms |
| shadow cascades 0–3 | 0.13 / 0.14 / 0.67–0.76 / 0.19 ms (cascades 2 and 3 render on alternate frames) |
| hdr | 8.1–8.9 ms (WORLD 8.0–10.2 ms) |
| taa | 1.7–1.8 ms |
| bloom | 1.1–1.2 ms |
| tonemap | not usable: see the note below |
| Δ terrain (hdr + shadows) | 3.6–6.2 ms |
| Δ trees | 0.2–1.1 ms |
| Δ grass | 0.2–0.8 ms |
| Δ water | about 0–2 ms (depends on how much ocean is in view) |
| sky + empty passes | 0.5 ms |
| CPU `model.tick` on the main thread | 0.31–0.35 ms (WORLD 0.02–0.05 ms) |
| CPU `render()` encode | 0.18–0.30 ms |

Note on tonemap: the reported 11–13 ms is an artefact. On a tile-based GPU the tonemap pass's start-of-vertex
timestamp is taken while earlier passes are still running, so the interval overlaps them. Post-processing really
costs about total − (skyLUT + shadows + hdr), roughly 3 ms (TAA 1.7, bloom 1.1, tonemap about 0.2). Δ values
come from removing one renderable at a time and subtracting. They are single samples and noisy.

## Ranked hotspots

**Training profile.** `sample` was run for 10 s on the release `--train neural.json` with 10 workers. There were
69.7k active samples. Costs from runtime and libm calls are attributed to the nearest PlaneWorld frame.

| # | where (file:function) | % of active CPU | cause |
|---|---|---|---|
| 1 | Physics/CraftSim.swift `substep` / `step`: `initializeWithCopy` and `destroy` for `SimPart` | **34 %** | `let p = parts[i]`, `let s = parts[i]` and `for p in parts where …` copy the whole `SimPart` struct, which contains `doc: CraftPart` (strings, `[String: JSONValue]` dictionaries, arrays). Each copy retains and releases about 10 heap objects, several times per part per substep |
| 2 | Core/Documents.swift `CraftPart.param` → `Dictionary.find`, `String.hash`, `JSONValue.double`, `partType.defaults`; Physics/CraftSim.swift `StripJob.run` lines 724/735/736 and `substep` lines 388/451/554–598 | **18 %** | Constant part parameters (`chord`, `ar`, `camber`, `thick`, `span`, `range`, `torque`, `speed`, `thrust`, `d`, …) are looked up in a string-keyed dictionary on every substep, about 60 lookups per substep for the Trainer |
| 3 | Physics/Aerodynamics.swift `WindField.velocity` (called from `StripJob.run`:727) | 9.7 % | 12 `sin` and 2 `log` per call, once per wing strip plus once at the CoM: about 13 calls and 180 transcendentals per substep |
| 4 | Physics/CraftSim.swift `StripJob.run` (aero math itself) | 7.9 % | `atan2`, `pow` and `log10` (Reynolds stall model), quaternion acts |
| 5 | `CraftSim.substep` self | 11.5 % | integration, propulsion, ground corners |
| 6 | Evolution/Headless `BakedTerrain.height`/`normal` → `HeightField.sampleHeight`/`sampleNormal` | 4.2 % | protocol-existential call plus bilinear sample for every strip, corner and wheel per substep, on a flat world |
| 7 | `CraftSim.updateEffective` | 4.2 % | `paramString("axis")` string lookup and `Quatd(angle:axis:)` per servo-linked part per substep |
| 8 | `Set<PartType>.contains` (`BODY_TYPES`, CraftSim.swift:425) | 3.2 % | hashes an enum for each part on every substep |
| 9 | `JSScriptRuntime.tick` | 0.8 % | not a bottleneck |
| 10 | `MLPPolicy.forward` | < 0.1 % | not a bottleneck |

Combined, ARC traffic (retain/release/bridgeObject) is 32 % of leaf samples and hashing/dictionary work is 22 %.
Allocations are zero: the 0 allocs/substep invariant holds for every craft except big CAD meshes (#11 below).

**Other hotspots**

| # | where | cost | cause |
|---|---|---|---|
| 11 | CraftSim.swift `substep` panel `parallelFor` (`physics.panels`) | 185 allocs/substep; 1070 µs against 688 µs serial on 21k panels | closure and job boxing on every substep; fork/join overhead larger than the work |
| 12 | Core/JobSystem.swift `workerLoop` / `stealAny` | about 1.4 cores burned while idle in FLY (each of 9 workers 14–18 % busy; 4.5 % `psynch_mutexwait`) | each wake does 200 × `stealAny` over 10 NSLock-protected deques, then a 2 ms timed wait in a loop |
| 13 | Water/Hydrodynamics.swift `compute` | 131 µs per call for 2.3k triangles (57 ns per triangle); allocates `world`, `dist` and `partials` arrays on every call | one ocean `sample` (430 ns, 4 displacement-inversion iterations) per hull vertex, at 1 kHz substeps. It breaks the zero-allocation rule whenever a hull is wet |
| 14 | GPU hdr pass, terrain renderable | 3.6–6.2 ms of a 12–15 ms frame | per-pixel splat, normal and aerial perspective at 6.1 Mpx |
| 15 | GPU post (TAA and bloom) | about 3 ms | rgba16f full-resolution history, plus a bloom chain at 6.1 Mpx |
| 16 | GPU FluidZone 64³ | 4.7–10.5 ms per 1/60 s | pressure iterations; 30–60 % of a 60 Hz frame |
| 17 | GPU ocean FFT | 1.15 ms per update | 3 × 256² radix-2 FFT plus mip generation. This is high for the size; part of it is the low GPU clock while otherwise idle |
| 18 | CPU terrain noise 2049² | 292 ms | one-off, at world generation |

## Recommendations and ownership (CPU vs GPU)

| # | recommendation | owner | expected effect |
|---|---|---|---|
| 1, 2, 7, 8 | Split `SimPart` into a hot SoA or POD struct (`PartHot`) with every numeric parameter pre-baked at `load()` (`chord`, `ar`, `camber`, `thick/chord`, `span`, `range·kDeg`, `torque`, `speed`, servo axis vector, `isBody`, `isWing`, …). Keep `CraftPart` only in a cold array. Iterate with `withUnsafeMutableBufferPointer`. No `Set`, `String` or `Dictionary` in `substep` | **CPU, algorithmic** | Removes about 55 % of the substep: expect 11.7 → about 4–5 µs. Bit-identical results, because it is the same arithmetic in the same order |
| 3 | `WindField.velocity`: evaluate turbulence once per substep at the CoM and apply a linear gradient across strips, or evaluate all strips at once SoA with vForce `vvsin` / SIMD polynomial sin | CPU SIMD | 10 % → about 2 %. A gradient changes results slightly; the trainer selftest must stay within 1 %. The SIMD version can be made bit-identical only if it uses the same `sin` |
| 6 | Give `BakedTerrain` a non-existential fast path (concrete `HeightField` pointer in `SimEnvironment`, plus a flat-world short-circuit) | CPU | about 3 % |
| **scaling** | Make worker hot state share no Swift heap objects. In the heap-isolated experiment (each worker's craft decoded separately), 10-thread throughput rose from 224–247 to 279–414 sim-s/s (+15–85 %, median about +50 %). After fix #1 removes the per-substep copies, the shared-heap version should get the same gain | CPU | 10 threads → about 400 sim-s/s before the single-thread speed-up; about 900+ with it |
| 11 | Panel aero: drop the per-substep `parallelFor` for a single craft (fork/join costs more than the work) or reuse a preallocated job. Make the panel loop SoA with SIMD (float4 normals and areas). GPU is the wrong place for one craft: a command-buffer round trip of 50–150 µs at 1 kHz is longer than the 170 µs of work, and the result is needed in the same substep. It is plausible on GPU only for batched training of many CAD crafts (one dispatch of crafts × panels per substep), which is opt-in and not bit-identical | CPU SIMD; GPU only for big batches | 21k panels: 1070 → < 400 µs; 185 → 0 allocs |
| 12 | JobSystem idle: park workers on a futex or semaphore immediately after a short exponential back-off (about 20 µs), and use `os_unfair_lock` or a lock-free Chase-Lev deque in place of NSLock. Give the training pool its own `JobSystem` | CPU | Gives back about 1.4 cores of power and thermal budget while flying (the GPU and P-cluster share the power budget) |
| 13 | Buoyancy: preallocate scratch buffers (zero allocations). Sample the water height on a small grid over the hull AABB once per substep (or per ocean update) and interpolate per vertex. Use a decimated buoyancy hull (≤ 512 triangles). Keep it on the CPU; GPU makes sense only for many floating bodies | CPU, algorithmic | 131 → about 20 µs for a 2.3k-triangle hull |
| NN | Keep the MLP scalar on the CPU (102 ns). For wide nets (≥ 128) use Accelerate `cblas_dgemv`. Batched forward for a whole population is a GEMM, which Accelerate/BNNS run on the AMX units. Never use the GPU at these sizes | CPU (Accelerate) | not on the critical path today |
| JS | Not a bottleneck: 1 µs per tick at 50 Hz is about 0.4 %. Each worker has its own VM, so there is no lock. JSC GC threads were ≤ 0.1 % busy | — | — |
| 14, 15 | Render: profile the terrain fragment shader (splat sampling and per-pixel atmosphere; try `fastAtmosphere` or a froxel/LUT aerial perspective). Render the internal frame at about 0.67× and upscale with MetalFX Temporal in place of TAA: about 2.2× fewer pixels for hdr, taa and bloom | **GPU** | 12–15 ms → about 7–8 ms |
| 16 | Fluid: stays on the GPU. Reduce pressure iterations (warm start, or multigrid/Red-Black), and step asynchronously at 30 Hz | GPU | |
| 17 | Ocean: stays on the GPU. Use a Stockham FFT in threadgroup memory, fusing the horizontal and vertical passes per cascade; update only the near cascade every frame | GPU | |
| erosion | Stays on the GPU: 1.6 ms per iteration for 1M cells. A one-off. Noise could move to `parallelFor` or a GPU compute kernel (292 ms) | GPU / CPU-parallel | |
| batched training on GPU | Not plausible for the strip-aero crafts. A Trainer substep is about 4 µs of branchy, mixed-precision (Double) work, and 64 sims × 13 strips is too small to fill the GPU. Apple GPUs have no fast fp64, and moving to fp32 breaks bit-identity. Keep training on the CPU | CPU | |

## Why training scales poorly on 10 cores

The brief quotes 5.3×. That is not reproducible here. One worker gives 60–88 sim-s/s (not 40) and 10 workers give
224–247 sim-s/s, so the measured scaling is about 3×.

1. **Shared-refcount contention (largest effect).** Every worker's `CraftSim` is loaded from the same
   `CraftDocument`. Its `SimPart.doc` copies share the same dictionary, string and array storage, so the
   per-substep struct copies (hotspot #1) do atomic retain/release on the same cache lines from every core.
   Evidence: 4 threads reach only 2× the single-thread rate on four P-cores, where no E-cores are involved. With
   heap-isolated workers, the same 10-thread load runs +15–85 % faster.
2. **E-cores.** One E-core runs at about 26 sim-s/s against about 85 on a P-core (0.31×; background QoS lowers the
   E clock too, so this is a lower bound). The ideal for 4P + 6E is about 4×85 + 6×27 ≈ 500 sim-s/s, about 5.9×
   one P-core. The work-stealing pool hands out candidates dynamically, so E-cores are not a load-balance problem.
   They just add less.
3. **P-cluster frequency and shared L2.** With isolated heaps, 4 threads give about 230 sim-s/s against 4 × 85 =
   340 (about 68 %). The remainder is all-core clock drop plus shared L2 and memory traffic. The working set is
   small (`SimPart` arrays), so memory bandwidth is not the limit.
4. **Generation barrier and tail.** It is small at population 64: train.generation at 10 workers gives 227–239
   sim-s/s, against 224–247 free-running. With population 64 on 10 workers there are 6.4 candidates per worker, and
   crash-terminated episodes vary in length, so expect up to 5–10 % tail loss on smaller populations.
5. **Not the cause.** JS context locks: there is one `JSVirtualMachine` per worker and 0.8 % in JS. Scheduler QoS:
   workers are `.userInteractive`. Allocations: there are none. False sharing on the result array: one write per
   candidate. Per-thread busy fractions during a generation were 98–99.9 %, so cores are not idle: they run slowly.

## Why one sim costs 11–25 µs per substep

A single Trainer substep on a P-core with a quiet machine is **11.7 µs**. Under 10-thread training it averages
about 40 µs wall per thread: 240 sim-s/s over 10 threads is 24 sim-s/s per thread. The "25 µs" figure falls
between the two because of the contention and E-core effects above. Of the 11.7 µs, about 34 % is `SimPart`
copying (ARC), about 18 % is string-keyed parameter lookups, about 10 % is turbulence transcendentals, and about
12 % is terrain sampling, `Set` lookups and `updateEffective`. The remaining physics (strip aero, integration,
contacts) is about 3–4 µs. That is the realistic CPU floor before any SIMD work.

## Invariants check

- Release `--selftest all`: 85/85 pass with the harness added. The bench code is additive and does not change
  physics.
- `allocs/substep` = 0 for Trainer, Jet, Rover, Rocket and CAD60 (serial). It is non-zero for panel `parallelFor`
  (185) and for any wet hull (`Hydrodynamics.compute` allocates three arrays per call).

## Final results (after optimisation)

Measured on a clean release build at `/tmp/pw-perf-final/build` (load average about 3), from `--bench all`. Raw output is in
`/tmp/pw-perf-final/bench-all.txt`. "Before" is the baseline above. Release `--selftest all`: 91/91 pass.

| bench | before | after | change |
|---|---|---|---|
| substep trainer.air | 11.7 µs | 2.96 µs | 3.9x |
| substep trainer.runway | about 10.6 µs | 3.90 µs | 2.7x |
| substep jet.air | 11.1 µs | 2.89 µs | 3.8x |
| substep rover.ground | 3.65 µs | 0.85 µs | 4.3x |
| substep rocket.air | 6.7 µs | 1.98 µs | 3.4x |
| substep cad60 (5.3k panels) | 173 µs | 44.2 µs | 3.9x |
| substep cad60big (21k panels), parallel | 1070 µs, 185 allocs | 136 µs, 0 allocs | 7.8x |
| substep cad60big, serial | 688 µs | 532 µs | 1.29x |
| allocations per substep, every bench | 0 to 185 | 0 | |
| headless episode, JS | 530 ms (75 sim-s/s) | 161 ms (249 sim-s/s) | 3.3x |
| JS controller tick | 1.01 µs | 0.79 µs | 1.27x |
| NN forward 9-12-4 | 102 ns | 82 ns | 1.24x |
| train free-running, 1 / 4 / 10 threads | 76-88 / 151-191 / 224-247 sim-s/s | 249 / 877 / 1325 sim-s/s | about 3x / 5x / 5.5x |
| train, 1 E-core (background QoS) | 26 sim-s/s | 60 sim-s/s (±19 %) | about 2.3x |
| train.generation, 10 workers | 5.8-6.1 sims/s | 34.5 sims/s (1348 sim-s/s) | 5.7x |
| erosion 1025² (GPU) | 314 ms | 247 ms | -21 % |
| ocean FFT update (GPU) | 1.15 ms (noisy; same-session base was 1.99) | 1.23 ms | about the same as PERF.md, -37 % against the same-session base |
| buoyancy 256 / 2.3k / 16k tris | 17.5 / 131 / 295 µs | 13.8 / 105 / 222 µs (16k: ±12 %) | -21 % / -20 % / -25 % |
| fluid 32³ / 64³ (GPU) | 64³: 4.7-10.5 ms | 2.43 / 4.51 ms (64³: ±59 %) | about the same |
| render FLY / WORLD GPU total, 3200x1920 | 12.2-16.7 ms | 12.22 / 12.01 ms | unchanged |
| render() CPU encode, FLY / WORLD | 0.18-0.30 ms | 0.085 / 0.083 ms | no regression (n=8) |

### What runs where, and why

- **CPU: all per-craft physics, including CAD panel aero.** The hot `SimPart` data was pre-baked into flat
  structs, so a substep does no allocation and no dictionary or string work. A GPU round trip of 50-150 µs at
  1 kHz is longer than the whole substep, and the result is needed inside that same substep. Large panel sets
  use a reusable, allocation-free `ParallelLoop` on the JobSystem. Its chunk boundaries do not depend on the
  thread count, so results are the same for any number of threads.
- **CPU: training.** Each sim is a few µs of branchy Double work. Apple GPUs have no fast fp64, and fp32 would
  break bit-identity. The gains came from the single-thread speed-up and from giving workers no shared hot heap
  objects, which raised 10-thread scaling to 5.3x of one thread.
- **CPU: NN forward and buoyancy.** At these sizes a dispatch costs more than the arithmetic.
- **GPU: rendering, erosion, ocean FFT and fluid.** These are large, regular grid workloads, and they stay on the GPU.
- Determinism: a seeded 5-generation run gives byte-identical history.csv (excluding the timing columns) and
  identical algorithm.state with 1 and 10 workers, and matches the original binary. The trajectory digest
  `0x77acda15065ef25b` (release) passes. trainer-takeoff-climb matches the base exactly: liftoff at 12.3 s and
  219 m after 60 s.

### Fixes after verification

- `ParallelLoop` (`Sources/Core/JobSystem.swift`): `count`, `grain` and `chunks` are now atomics (relaxed). A
  late helper from an earlier run could read them while the next run was re-arming the loop. That was a data
  race under TSan, though it never claimed a wrong chunk. The TSan debug `--selftest physics` now passes 11/11
  with 0 warnings.
- `physics.trajectory-digest`: the digest depends on the optimisation level, because release contracts
  multiply-adds into FMA. Debug builds now check against their own reference, `0x144cb400e4c99c37`, measured in
  the TSan debug build. Release remains authoritative.
- The CPU encode "regression" did not reproduce on a quieter machine: 0.08 ms against 0.18-0.30 ms in the baseline.

## GPU pass (native 3200x1920, no upscaling)

Goal: a GPU frame of 12 ms or less in the worst case, ideally 10 ms or less, in FLY and WORLD at native resolution,
with no visible quality loss.

### Bench views

`Sources/Render/BenchViews.swift` adds fixed worst-case cameras. Set `PW_VIEW=horizon|low|grass|ocean` to override
the camera passed to `Renderer.render`, both in `--bench render.frame` and in the app. Each view is placed relative
to the tab's own camera, so FLY and WORLD each get a deterministic view:

| view | camera |
|---|---|
| default | the tab's own chase or orbit camera, over the runway |
| horizon | 250 m above ground, pitched 2° down, looking across the terrain to the horizon |
| low | 2.5 m above ground, pitched 6° down |
| grass | 2 m above the nearest flat, fully grassed spot, pitched 3° down, with a tree line in view |
| ocean | 40 m above the sea, pitched 4° down toward the coast (the worst view) |

Other environment variables:

- `PW_DUMP=/path.png` writes the tonemapped frame `PW_DUMP_FRAME` (default 150) as a PNG. It works with
  framebuffer-only drawables because it re-tonemaps into an offscreen target.
- `PW_SKIP=TerrainRenderable,…` drops renderables by type name, for profiling.

Measurement method: release build, `--bench render.frame` (90 frames per tab). Runs alternated between base and new
binaries, view by view. Base is HEAD's Render, Terrain, Water and Vegetation plus only the bench hooks. Values are
medians in ms. "shadows" is the per-frame average; cascades 2 and 3 render on alternate frames.

Caveat: macOS Low Power Mode roughly doubles every GPU number (a first run gave 24–33 ms). The table below was
measured with it off.

| view | gpu total | hdr | taa | bloom | skyLUT (+aerial LUT) | shadows |
|---|---|---|---|---|---|---|
| default FLY | 12.37 → 9.03 | 7.99 → 4.80 | 1.68 → 1.29 | 1.12 → 1.16 | 0.18 → 0.40 | 0.69 → 0.79 |
| default WORLD | 12.59 → 8.90 | 8.21 → 4.88 | 1.71 → 1.30 | 1.12 → 1.15 | 0.18 → 0.41 | 0.70 → 0.83 |
| horizon FLY | 10.77 → 7.69 | 6.01 → 3.52 | 1.76 → 1.29 | 1.20 → 1.14 | 0.20 → 0.44 | 0.37 → 0.34 |
| horizon WORLD | 10.62 → 7.61 | 6.31 → 3.76 | 1.80 → 1.30 | 1.19 → 1.14 | 0.21 → 0.49 | 0.37 → 0.36 |
| low FLY | 11.56 → 7.71 | 6.92 → 3.45 | 1.71 → 1.24 | 1.13 → 1.13 | 0.19 → 0.49 | 0.82 → 1.04 |
| low WORLD | 11.71 → 7.55 | 7.13 → 3.54 | 1.72 → 1.27 | 1.15 → 1.13 | 0.20 → 0.50 | 0.85 → 1.17 |
| grass FLY | 9.35 → 7.93 | 4.54 → 3.39 | 1.74 → 1.32 | 1.12 → 1.17 | 0.19 → 0.50 | 1.71 → 1.96 |
| grass WORLD | 9.23 → 7.78 | 4.66 → 3.31 | 1.76 → 1.33 | 1.13 → 1.15 | 0.19 → 0.49 | 1.74 → 1.89 |
| ocean FLY | 14.86 → 9.04 | 10.48 → 5.18 | 1.72 → 1.27 | 1.14 → 1.14 | 0.19 → 0.45 | 0.48 → 0.56 |
| ocean WORLD | 14.85 → 9.19 | 10.74 → 5.35 | 1.72 → 1.29 | 1.14 → 1.15 | 0.18 → 0.47 | 0.46 → 0.58 |

The worst case drops from 14.9 ms (ocean) to 9.2 ms. Every view is now under 10 ms. "gpu total" is measured
without timestamps; per-pass timestamps have about ±5 % noise.

### Where the hdr time went

Profiled with shader toggles in the default view, before the changes below. The hdr pass was 9.6 ms, of which the
terrain fragment shader was about 6.9 ms:

| part | cost |
|---|---|
| splat and layer sampling | about 1.8 ms |
| macro-variation noise (8 `sin` hashes per pixel) | about 1.1 ms |
| per-pixel aerial perspective and sun transmittance | about 2.5 ms |
| 9-tap shadow PCF | about 1 ms |

Per-pixel aerial perspective was 6 scattering steps, each with an 8-step sun march, plus another 8-step sun march in
`shadeSurface`. That is about 60 atmosphere-medium evaluations per pixel, paid by the terrain, the water and the
mesh pipeline.

### Changes

1. **Aerial-perspective LUT** (`ShaderCommon` and the `aerialLUT` kernel). A per-frame 64×64×48 rgba16f 3D LUT over
   (view azimuth, sqrt-warped elevation, sqrt distance up to 100 km) holds three things: in-scatter, view
   transmittance and sun transmittance at the point. Each LUT cell is computed with the same `integrateScattering`
   and `transmittanceToSun` calls as before. It is bound by `FrameContext.bindFrame` at fragment textures 13–15.
   Terrain, water and the PBR mesh call `aerialLookup` and `shadeSurfaceT`. Beyond 100 km they fall back to the exact
   path. Cost: +0.25 ms in the skyLUT pass. Saving: about 2.5 ms in hdr. Vegetation already did this per vertex.
2. **Terrain layer culling, exact.** The dominant splat layer is sampled first. A layer whose largest possible
   height-blend score, `w + 0.45·hmax`, cannot reach `a_dom − 0.18` would get zero weight, so it is skipped.
   `hmax` is each layer's measured maximum detail height, taken from the generated texture by an atomic-max kernel.
3. **Triplanar floor.** Projection weights have 0.04 subtracted and are then renormalised. Near-flat ground uses one
   projection (2 fetches per layer). The blend stays continuous on slopes.
4. **Macro noise baked.** The `/173 m` and `/41 m` lattice `tvhash` values are baked once into r32f textures that
   cover the quadtree root plus the falloff band. Each noise is now one `gather` plus the same Hermite blend, with
   identical values.
5. **Shadow PCF early-out** (`sampleShadow`). The four corner hardware-PCF taps cover the same 4×4 texels as all
   nine taps. When the corners agree (fully lit or fully shadowed), the other five taps are skipped. Penumbrae still
   take 9 taps.
6. **Sky after opaque.** The full-screen sky is drawn after opaque geometry, at z = 0 with a read-only
   greater-equal test. Early-z now rejects every covered pixel. Before, it shaded all 6.1 Mpx first.
7. **TAA tiled.** Each 16×16 group loads its 18×18 neighbourhood into threadgroup memory: colour is converted to
   tonemapped YCoCg once per texel, and depth is loaded alongside. The maths is identical. Saving: 1.7 → 1.3 ms.

### Checked and left alone

- **Depth prepass.** Opaque terrain is drawn first, and Apple's HSR already removes opaque overdraw, so a prepass
  only adds vertex work. Alpha-tested trees stay after the opaque terrain, as Apple recommends.
- **Far-cascade caching.** It already exists: cascades 2 and 3 alternate.
- **Bloom.** It is already half-res. A cheaper first downsample would change the filter.
- **fp16 render targets.** HDR, history and bloom are already rgba16f. rg11b10 history risks tint drift.
- **Anisotropy.** Dropping from 8x to 2x on the dominant layer saves only about 0.4 ms, so it stays at 8x.
- **Tree shadow casters.** These cost about 1–2 ms in the grass view and are already LOD'd per cascade.

### Quality check

Screenshots were taken at identical cameras with `PW_DUMP`, frame 150 for FLY and frame 480 for WORLD, base
against new, for all five views in both tabs (in `/tmp/pw-gpu/shots/`). PSNR ranges from 56 to 65 dB, the mean
absolute difference is at most 0.11 of 255, and the 99th-percentile difference is at most 2 of 255. The largest
single-pixel differences (up to 72) are on ocean glints and foam. No visible difference.

Release `--selftest all`: 92/92 pass.

## Batched lanes (K candidates per worker in SIMD lanes)

`CraftSimBatch` steps K candidates of the same craft in lockstep (SoA, `SIMDn<Double>`, masked branches). Each lane gives exactly the same result as the scalar `CraftSim`; this is checked by the `BatchSelfTests` selftests.

| 10 workers, median of 5 | K=1 sim-s/s | K=2 sim-s/s | K=2 vs K=1 |
|---|---|---|---|
| population 64 | 1351 | 1244 | -8% |
| population 1024 | 1186 | 949 | -20% |

A seeded 3-generation training run gives identical `history.csv` (timing columns excluded) for K=1 with 1 worker, K=1 with 10 workers and K=2 with 10 workers.

**Verdict: the default is `batchLanes = 1` (batching off); larger values are opt-in per experiment.** Each sim is branch-heavy Double work: stall, contact and servo saturation diverge across lanes, so masked execution wastes lanes. A NEON register holds only 2 Doubles. Running all 10 cores also pushes memory bandwidth and the shared power budget, so the losses get larger at high worker counts. Training throughput is already close to the M4 ceiling (about 4×P + 6×E ≈ 1350 sim-s/s). Further gains need cheaper sims (lower fidelity, two-tier evaluation), not wider ones.

## C++ port (cpp/, branch cpp-port): physics substep against Swift

Same machine (Apple M4), same session, same setup: craft through addStandardSensors + prepareForFlight, 1 kHz,
flat world, wind (2,0,1), turbulence 0.3, motors 0.8 / other outputs 0.1, single thread, fast.plus profile.
Swift: `.build/release/PlaneWorld --bench physics.substep` (median of 7). C++: `cpp/build-*/src/cli/pwcli --bench
physics.substep.<name> --reps 7` (best of 3 medians of 7; two runs gave the same numbers to ±0.04 µs).
The Swift numbers are lower than the baseline table above because the Swift substep has been optimised since.

| craft | Swift µs/substep | C++ µs/substep | C++ speed-up | allocs/substep (Swift / C++) |
|---|---|---|---|---|
| Trainer, in air | 3.92 | 3.86 | 1.02x | 0 / 0 |
| Trainer, runway | 4.95 | 4.30 | 1.15x | 0 / 0 |
| Jet trainer, in air | 3.46 | 3.35 | 1.03x | 0 / 0 |
| Rover, ground | 0.83 | 0.55 | 1.52x | 0 / 0 |
| Sounding rocket | 2.14 | 1.91 | 1.12x | 0 / 0 |

C++ is at least as fast on every craft; the Trainer in the air is within noise of Swift (the substep is dominated by
the same libm calls in both). The CAD craft variants (cad60, cad60big) are not in the C++ bench yet: the C++ side has no
sphere-mesh CAD part builder for the bench. The step allocates nothing in C++ (also enforced in pwtests for every
craft × profile with sensors and equation capture on).
