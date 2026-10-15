# Plane World

Native macOS flight and vehicle physics sandbox. Built with Swift 6, Metal, AppKit and SwiftPM only. Metal shaders compile at runtime, so no Xcode or `metal` CLI is needed.

## Build and run
```sh
swift build -c release --scratch-path /tmp/pw-build
/tmp/pw-build/release/PlaneWorld                    # launch the app
/tmp/pw-build/release/PlaneWorld --tab fly          # start on a tab (build|fly|world)
/tmp/pw-build/release/PlaneWorld --selftest all     # headless tests (or: core, physics, collision, terrain, vegetation, water, craft, app)
/tmp/pw-build/release/PlaneWorld --quit-after 10    # smoke test
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

## Architecture
See `docs/ARCHITECTURE.md`. The App wires TerrainSystem, WaterSystem, ProceduralVegetation and VegetationRenderable, RigidWorld and CraftSim through `SimulationServices`. Physics runs at 1 kHz substeps and the collision world at 240 Hz. The craft is coupled to the collision world through a kinematic proxy box, so it pushes props and breaks breakables. Craft-tree contacts and grass flattening go through the vegetation `interact` API. Screenshots are in `docs/screens/`.
