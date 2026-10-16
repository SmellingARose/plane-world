# Plane World: Architecture

Native macOS app. Swift 6 compiler (modules in Swift 5 language mode), Metal, AppKit with SwiftUI panels, built only with SwiftPM.
Shaders are MSL source strings compiled at runtime (`ShaderLibrary`, with `ShaderCommon.header` prepended).

## Build / run / test
    swift build --scratch-path <scratch>
    <scratch>/debug/PlaneWorld                      # app
    <scratch>/debug/PlaneWorld --selftest all|list|<group>|<group.name>   # headless, exit 0/1
    <scratch>/debug/PlaneWorld --quit-after 8       # smoke test
    PW_SELFTEST_OUT=dir ... --selftest render       # writes offscreen PNGs
    swift test --scratch-path <scratch>             # swift-testing wrapper over core self-tests

## Modules (target, directory, owner)
| Target | Dir | Owner | Contents |
|---|---|---|---|
| PWCore | Core/ | architect | Math (Double world, Float render), JobSystem, EventBus, SimulationClock, JSON docs (Craft/World), **Interfaces.swift**, SelfTestRegistry |
| PWRender | Render/ | architect | GPU, ShaderLibrary, Renderer, StandardPipelines, Renderable/RenderRegistry, MeshBuilder/GPUMesh, InstancedMeshRenderable, DebugDraw |
| PWCollision | Collision/ | collision builder | implements `CollisionWorld` |
| PWPhysics | Physics/ | aero/physics builder | implements `CraftSimulation` (depends on Collision) |
| PWTerrain | Terrain/ | terrain builder | implements `TerrainProvider` + Renderable |
| PWVegetation | Vegetation/ | vegetation builder | implements `VegetationSystem` + Renderable |
| PWWater | Water/ | water builder | implements `WaterProvider` + Renderable (transparent pass) |
| PWCraft | Craft/ | import builder | CAD import, auto-rig, mesh cut, PartMeshFactory, CraftLibrary |
| PWEvolution | Evolution/ | architect + script / ga-es / neat-qd builders | EVOLVE: headless world, parallel evaluator, algorithms (ask/tell), JavaScriptCore scripting, run/checkpoint/replay — see docs/EVOLUTION.md |
| PlaneWorld | App/ | architect, then integrator (App/Evolve/: evolve-ui builder) | window, tabs, panels, input, main loop, wiring |

Dependency rule: everything depends on Core. Render-facing modules depend on Render. Modules never import each other, except Physics→Collision, Craft→Physics and Evolution→{Physics, Collision, Terrain, Water}. Only App wires concrete types together, through `SimulationServices`.
Each stub file is headed `OWNED BY <x> builder` and every unfinished piece is marked `TODO(<owner>)`. Each module exposes `<Module>SelfTests.register()`, and App/main.swift calls it.

## Key interfaces (Core/Interfaces.swift)
- `TerrainProvider`: height, normal, material and raycast (thread-safe); `update(cameraPosition:)`; load/save `TerrainSpec`.
- `WaterProvider`: `sample` (height, normal, velocity, depth), `flow`, `submergedForces(hull:state:time:)`, `step`.
- `CollisionWorld`: add/remove bodies (`RigidBodyDesc`, `CollisionShape`), state, forces, `registerBreakable`, `addBreakableJoint`, `step`, contacts, raycast. Breaks publish `BreakEvent`.
- `VegetationSystem`: `generate`, `interact`, `step(wind)`, `collisionProxies`.
- `CraftSimulation`: `load(CraftDocument)`, `outputs` (one slider each), `setOutput`, `reset`, `step(dt, env: SimEnvironment)`, `bodyState`, `partPoses`, `telemetry`. `CraftSim` adds sensor `inputs` (`CraftInput`, from `sensor` parts), `readSensors(env:into:)`, `setOutput(index:value:)`, crash/contact flags and `clone()`.
- `WorldDocument` / `JSONWorldDocumentStore`: JSON world save/load.
- `Renderable` (Render/RenderCore.swift): `prepare`, `drawShadow(cascade)`, `drawOpaque`, `drawTransparent`, with a `FrameContext`. Register it with `RenderRegistry.shared.add`.

`CraftDocument` is compatible with the prototype's JSON. Unknown keys are kept in `extra`, and `p` is a `[String: JSONValue]` with defaults merged in.

## Threading model
- Main thread: AppKit, SwiftUI, and the MTKView draw callback, which is the main loop: `model.tick(dt)` → `SimulationClock.advance` runs fixed substeps (default 600 Hz, clamp 60–2000) → craft.step, collision.step, water.step. After that come vegetation, terrain streaming, and the render.
- `JobSystem.shared`: work-stealing pool with cores−1 workers plus the caller. Use `parallelFor(count, grain:, label:)`. It nests safely, and the label records an EMA timing. Job bodies must write only disjoint memory. Measured speedup is 7.6× on the 10-core M4.
- Thread-safe queries (terrain and water sampling) may be called from inside `parallelFor`.
- GPU: 3 frames in flight. `FrameContext.transientBuffer` gives per-frame ring memory.

## Rendering
Camera-relative rendering: world positions are Double, and GPU positions are Float relative to the camera. Depth is reverse-Z with an infinite far plane (clear 0, compare greaterEqual).
Passes: sky-view LUT (compute, Hillaire-style single scattering plus an approximate multiple-scattering term, ozone) → 4 stabilised shadow cascades (2048², texel-snapped, PCF) → HDR rgba16f (sky with sun disk, opaque PBR GGX with sky IBL-lite and aerial perspective, debug lines, transparent) → TAA (YCoCg clamp, reprojection from depth) or 4x MSAA → bloom mip chain → ACES fitted tonemap + dither.
Modules write their own shaders with `ShaderLibrary.shared.library(named:source:device:)`. They get `FrameUniforms`, the atmosphere functions, `shadeSurface` and `applyAerial` from the header. Bind frame data with `FrameContext.bindFrame` (buffer 2, textures 0/1).
Known TODOs: TAA uses camera-only reprojection (no per-object motion vectors, so moving objects can ghost). IBL is an approximation (no prefiltered cubemap).

## Rotor slipstream (induced flow)

`Sources/Physics/Slipstream.swift`. Each propeller is an actuator disk (momentum theory). Its wake follows the vortex-cylinder axial profile `Δv(s) = v_i(1 + s/√(s²+R²))`, contracts by continuity, drifts with the crossflow, carries swirl in the rotor's rotation sense (prop param `spin` = ±1), and decays by mixing over about 14 radii. Every wing strip, body and *other* propeller adds the wakes to the air it sees. The wake state lags one substep, so the model stays explicit and deterministic.

- **Ducts** are detected automatically: structure covering at least 9 of 12 sectors at 1.0–1.7 R around the disk. Override with prop param `duct` (0 or 1). A ducted rotor gets the σ = 1 duct thrust (same power as an open rotor of √2 times the diameter) and an uncontracted wake.
- **Rotor ground effect** uses the Cheeseman–Bennett model, limited to z/R ≥ 0.5.
- **Torque:** the full shaft torque at the operating speed reacts on the airframe. The old model applied a fixed 25 %.
- **Switching it off:** `PW_SLIPSTREAM=0` or `CraftSim.slipstream = false` gives the isolated-part model, bit-identical to before (trajectory digest 77acda15065ef25b).
- **Batched lanes** implement only the isolated-part model. Crafts with props and slipstream on use the scalar path (`CraftSimBatch.unsupportedFeatures`).
- **Not modelled:**
  - blockage or deflection of the flow by bodies (the wake passes through them; they only feel drag from it)
  - wakes and downwash from wings
  - wake reflection off the ground
  - CAD-panel bodies sampling the wake per panel (they use the craft-level wind)
