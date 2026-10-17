# Plane World: performance

CPU micro-benchmarks for the C++ build, from `pwcli --bench` (`src/cli/bench.cpp`). GPU work (CFD, rendering) is
not covered here; CFD timings are in `docs/CFD.md` §6.

## How to measure

    build/src/cli/pwcli --info                      # machine / SIMD / GPU backend
    build/src/cli/pwcli --bench list                # bench names
    build/src/cli/pwcli --bench all --reps 3 [--json out.json]
    build/src/cli/pwcli --bench physics.substep.trainer.air --reps 7   # one bench, exact name

Use a release build. Each bench runs 3 times and prints the best (min time or max rate); `--reps N` sets the work per
run (for `physics.substep.*`, the median of max(3, N) timed blocks). `allocs/substep` counts every `operator new`
over 100 substeps (`src/cli/alloc_count.cpp`); it must stay 0, and pwtests also enforces that for every craft and
profile.

| bench | what it measures |
|---|---|
| `physics.substep.{trainer.air,trainer.runway,jet.air,rover.ground,rocket.air}` | one `CraftSim` substep at 1 kHz, flat world, wind (2,0,1), turbulence 0.3, motors 0.8 / other outputs 0.1, standard sensors, single thread; air = 300 m at 45 m/s, ground = resting spawn |
| `sim.trainer.fast.{classic,plus}` | Trainer substep throughput with each fast-aero profile |
| `aero.wing` | wing-strip aero evaluations |
| `panels.{scalar,neon}` | Newtonian panel aero, scalar vs SIMD |
| `reduce.dot.{scalar,neon}`, `math.fma`, `math.quat-act` | SIMD and math kernels |
| `jobs.parallelFor.empty` | job-pool dispatch overhead (empty parallelFor) |

## Current numbers

Apple M4 (10 cores), `pwcli --info`: `Plane World (C++) 0.1.0`, `cpu: simd=neon cores=10 [ neon ]`, GPU backend
Metal. Command: `build/src/cli/pwcli --bench all --reps 3` (2.4 s wall), 2026-10-17, load average about 1.5.

| bench | result |
|---|---|
| physics.substep.trainer.air | 3.60 µs/substep, 0 allocs |
| physics.substep.trainer.runway | 4.12 µs/substep, 0 allocs |
| physics.substep.jet.air | 3.17 µs/substep, 0 allocs |
| physics.substep.rover.ground | 0.53 µs/substep, 0 allocs |
| physics.substep.rocket.air | 1.85 µs/substep, 0 allocs |
| sim.trainer.fast.classic | 644.70 ksubsteps/s |
| sim.trainer.fast.plus | 412.93 ksubsteps/s |
| aero.wing | 37.83 Mevals/s |
| panels.scalar / panels.neon | 40.31 / 48.82 Mpanels/s |
| reduce.dot.scalar / reduce.dot.neon | 10897.64 / 11081.50 Melem/s |
| math.fma | 689.16 Mfma/s |
| math.quat-act | 175.13 Mops/s |
| jobs.parallelFor.empty | 102.82 kloops/s |

Single runs on a shared machine vary by about ±10 %; re-run before drawing conclusions from small differences.

## Not benchmarked yet

Training throughput (`train.*`), JS controller calls, MLP forward, terrain, water, fluid and render benches from the
earlier app are not in `pwcli --bench`, nor are the CAD-craft substep variants (no CAD part builder in the bench).
