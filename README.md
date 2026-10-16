# Plane World

Native macOS flight and vehicle physics sandbox. Built with Swift 6, Metal, AppKit and SwiftPM only. Metal shaders compile at runtime, so no Xcode or `metal` CLI is needed.

## Build and run
```sh
swift build -c release --scratch-path /tmp/pw-build
/tmp/pw-build/release/PlaneWorld                    # launch the app
/tmp/pw-build/release/PlaneWorld --tab fly          # start on a tab (build|fly|world|evolve)
/tmp/pw-build/release/PlaneWorld --selftest all     # headless tests (or: core, physics, collision, terrain, vegetation, water, craft, evolution, evolution-js, evolution-algo, app)
/tmp/pw-build/release/PlaneWorld --quit-after 10    # smoke test
/tmp/pw-build/release/PlaneWorld --train examples/experiments/hold100-ga.json --generations 40 --out /tmp/run   # headless training
/tmp/pw-build/release/PlaneWorld --make-experiment "Neural controller" my.json  # preset -> editable experiment
swift test --scratch-path /tmp/pw-build
```
Use release builds when you judge performance. The physics, collision and terrain generation are 10–200x slower in debug.

## Tabs
- **BUILD**: craft library (presets, plus user crafts in `~/Library/Application Support/PlaneWorld/crafts`), JSON import and export (prototype format), add primitives, and CAD import (STL/OBJ/glTF/GLB/USD/USDZ) with auto-rig on import. You also get an auto-rig button, a mesh-cut tool (plane plus offset), and a properties inspector (transform, params, servo/motor links, invert). Duplicate and mirror are there too, plus mass and CoM, and renamable auto outputs.
  - Viewport: click to select a part, ⇧-drag to move it, ⌘-drag to rotate it, ⌫ to delete it.
- **FLY**: spawns the craft on the current world's runway. Every output (servo, motor, jet, solid, and an auto motor for unlinked wheels and props) is its own slider. The HUD shows IAS, TAS, altitude, VS, AoA, mass, fuel, stall and servo-stall warnings.
  - Keys: R reset, P pause, C to cycle the camera (chase, orbit, cockpit).
- **WORLD**: terrain from a real place (AWS terrarium tiles, by lat/lon and zoom), procedural terrain (seed plus GPU erosion), or a heightmap (PNG or R16).
  - Tools: sculpt (raise, lower, smooth, flatten), material paint, tree paint and erase, grass paint, props and breakables (crate, wall, tower, glass, pillar, or an imported mesh), lakes, and river splines.
  - Also here: ocean level and wind, FLIP fluid zones, sky, wind and render settings, and world save/load as JSON.

Mouse: left-drag orbits, right- or ⌥-drag pans, scroll zooms, WASD/QE moves. When a WORLD tool is active, left-drag applies the tool and right-drag orbits.

- **EVOLVE**: evolutionary optimisation of neural controllers (MLP or NEAT), craft designs, or both. You write the genome, controller, named reward points, termination and descriptor in JavaScript. Algorithms: GA, CMA-ES (full and separable), simple ES, OpenAI-ES, NEAT, MAP-Elites, novelty search, or a custom JS algorithm. Candidates run headless on all cores, with live charts, checkpoint and resume, 3D replay, and export to a craft. In FLY, "Autopilot from evolved controller" then flies the exported craft. Sensor parts (`sensor` type in BUILD) provide the named inputs controllers read. Docs: `docs/EVOLUTION.md`, including the reward tutorial in §11. Example experiments are in `examples/experiments/`.

### Example training results
Release build, Apple M4 (10 cores), CLI `--train`, flat world, Trainer craft, 1 kHz physics, 50 Hz controller.

| Run | Algorithm | Result |
|---|---|---|
| Take off and hold 100 m (`hold100-ga.json`, 64 × 150 gens) | GA | Best fitness 4.6 → 79.4. Takeoff learned by gen 18. Time within ±10 m of 100 m: 0 → 25 s of the 60 s window. Not yet a full 60 s hold. |
| Same task (`hold100-neat.json`, 96 × 40 gens) | NEAT | Best fitness 5.0 → 92.2. Takes off at gen 5; holds 32 s within ±10 m at gen 39. |
| Glide distance (`glide-cmaes.json`, 24 × 30 gens) | CMA-ES | Best 2067 → 2525 m (+22%), mean 1676 → 2522 m. Converged to the span and chord upper bounds. |
| Descriptor (final x, final AGL) (`hold100-mapelites.json`, 64 × 30 gens) | MAP-Elites | Archive coverage 2.3% → 19.7% (59 of 300 cells) |

Throughput (JS-scored neural controller): 67–69 sim-s per wall-second on 1 worker and 218–222 on 10 workers, a 3.2× speedup. The 10-worker run gives identical fitness. `evolution.bench-headless` measures 67 sim-s/s on 1 core and 240 on 10 cores (3.6×). The M4's 6 efficiency cores bound the scaling.

## Architecture
See `docs/ARCHITECTURE.md`. The App wires TerrainSystem, WaterSystem, ProceduralVegetation and VegetationRenderable, RigidWorld and CraftSim through `SimulationServices`. Physics runs at 1 kHz substeps and the collision world at 240 Hz. The craft is coupled to the collision world through a kinematic proxy box, so it pushes props and breaks breakables. Craft-tree contacts and grass flattening go through the vegetation `interact` API. Screenshots are in `docs/screens/`.
