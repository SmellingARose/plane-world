// OWNED BY architect. ------------------------------------------------------------------------------
// CPU-only world for headless training. Baked once per run, then read-only and thread-safe, so any number
// of craft sims on any number of workers can sample it concurrently.
//   * BakedTerrain: a private copy of a HeightField (heights + splat). Sampling/raycast formulas are the
//     same as TerrainSystem's, so a replay in the live (GPU) world sees identical ground.
//   * HeadlessWater: sea level (flat or deterministic analytic swell), lakes and rivers from WaterSpec.
//     The GPU FFT ocean and FLIP fluid zones are NOT simulated headless.
//   * Vegetation / breakables / props: optional static obstacles (HeadlessObstacles, per HeadlessOptions flags).
//     They never move or break headless; touching one latches crashed. No per-candidate RigidWorld clone.
import Foundation
import simd
import PWCore
import PWPhysics
import PWTerrain
import PWWater

public final class BakedTerrain: TerrainProvider, @unchecked Sendable {
    public let field: HeightField

    /// Deep copy of `source` (base, edits, paint, moisture) recomposited, so later edits in the app do not leak in.
    public init(copying source: HeightField) {
        let f = HeightField(width: source.width, height: source.height, spacing: source.spacing, origin: source.origin)
        f.baseLevel = source.baseLevel; f.falloff = source.falloff; f.splatParams = source.splatParams
        let n = source.width * source.height
        f.base.ptr.update(from: source.base.ptr, count: n)
        f.delta.ptr.update(from: source.delta.ptr, count: n)
        f.paint.ptr.update(from: source.paint.ptr, count: n)
        f.paintMask.ptr.update(from: source.paintMask.ptr, count: n)
        f.moisture.ptr.update(from: source.moisture.ptr, count: n)
        f.recompute(f.fullRect)
        field = f
    }
    /// Flat ground at `level` (257² × 32 m, like TerrainSystem.setFlat).
    public convenience init(flatLevel level: Double) {
        let f = HeightField(width: 257, height: 257, spacing: 32, origin: Vec2d(-128 * 32, -128 * 32), fill: Float(level))
        f.baseLevel = level; f.falloff = 1
        f.moisture.buffer.update(repeating: 0.6)
        f.recompute(f.fullRect)
        self.init(copying: f)
    }

    public func height(x: Double, z: Double) -> Double { field.sampleHeight(x: x, z: z) }
    public func normal(x: Double, z: Double) -> Vec3d { field.sampleNormal(x: x, z: z) }
    public func material(x: Double, z: Double) -> TerrainMaterialSample {
        let w = field.sampleSplat(x: x, z: z)
        let fr: SIMD4<Float> = [0.85, 1.0, 0.6, 0.35], rr: SIMD4<Float> = [1.6, 1.0, 3.0, 2.2]   // = TerrainSystem.material
        return TerrainMaterialSample(weights: w, friction: Double(simd_dot(w, fr)), rollingResistance: Double(simd_dot(w, rr)))
    }
    public var bounds: AABB {
        let f = field
        return AABB(min: Vec3d(f.worldMin.x, Double(min(f.minHeight, Float(f.baseLevel))), f.worldMin.y),
                    max: Vec3d(f.worldMax.x, Double(max(f.maxHeight, Float(f.baseLevel))), f.worldMax.y))
    }
    /// Same adaptive march + bisection as TerrainSystem.raycast (allocation-free).
    public func raycast(_ ray: Ray, maxDistance: Double) -> RayHit? {
        let f = field
        let o = ray.origin, d = ray.direction
        let top = Double(max(f.maxHeight, Float(f.baseLevel))) + 1, bottom = Double(min(f.minHeight, Float(f.baseLevel))) - 1
        var t = 0.0
        if o.y > top {
            if d.y >= 0 { return nil }
            t = (o.y - top) / -d.y
            if t > maxDistance { return nil }
        }
        @inline(__always) func gap(_ t: Double) -> Double { let p = o + d * t; return p.y - f.sampleHeight(x: p.x, z: p.z) }
        var g = gap(t)
        if g < 0 { let p = o + d * t; return RayHit(distance: t, position: Vec3d(p.x, p.y - g, p.z), normal: f.sampleNormal(x: p.x, z: p.z)) }
        let minStep = f.spacing * 0.35
        let horiz = simd_length(Vec2d(d.x, d.z))
        while t < maxDistance {
            let step = max(minStep, g / (abs(min(d.y, 0)) + 2.5 * horiz + 1e-3) * 0.9)
            let tn = min(t + step, maxDistance)
            let gn = gap(tn)
            if gn <= 0 {
                var a = t, b = tn
                for _ in 0..<24 { let m = 0.5 * (a + b); if gap(m) > 0 { a = m } else { b = m } }
                let p = o + d * b
                return RayHit(distance: b, position: Vec3d(p.x, f.sampleHeight(x: p.x, z: p.z), p.z), normal: f.sampleNormal(x: p.x, z: p.z))
            }
            let p = o + d * tn
            if d.y >= 0 && p.y > top { return nil }
            if p.y < bottom - 1 { return nil }
            t = tn; g = gn
        }
        return nil
    }
    public func update(cameraPosition: Vec3d, deltaTime: Double) {}
    public func load(spec: TerrainSpec, baseURL: URL?) throws { throw EvolutionError.invalidExperiment("BakedTerrain is read-only") }
    public func makeSpec() -> TerrainSpec { TerrainSpec() }
}

extension BakedTerrain: TerrainBulkHeights {
    /// Bulk `height(x:z:)` for CraftSimBatch (same function per point: bit-identical, no per-point dispatch).
    public func heights(xs: UnsafePointer<Double>, zs: UnsafePointer<Double>, into out: UnsafeMutablePointer<Double>, count: Int) {
        let f = field
        for i in 0..<count { out[i] = f.sampleHeight(x: xs[i], z: zs[i]) }
    }
}

/// Read-only, thread-safe water for headless runs.
public final class HeadlessWater: WaterProvider, @unchecked Sendable {
    public let oceanEnabled: Bool
    public let seaLevel: Double
    public let lakes: [Lake]
    public let rivers: [River]
    public let hydro = HydroSettings()
    public let seawaterDensity = 1025.0
    /// Analytic swell components (empty = flat sea): direction (unit xz), wavenumber, angular freq, amplitude, phase.
    struct Wave { var dir: Vec2d; var k: Double; var omega: Double; var amp: Double; var phase: Double }
    let waves: [Wave]
    let terrainHeight: ((Double, Double) -> Double)?

    public init(spec: WaterSpec, waves enableWaves: Bool, seed: UInt64, terrain: (any TerrainProvider)?) {
        oceanEnabled = spec.oceanEnabled; seaLevel = spec.seaLevel
        lakes = spec.lakes.map { Lake(json: $0) }
        rivers = spec.rivers.map { River(json: $0) }
        var w: [Wave] = []
        if enableWaves && spec.oceanEnabled {
            // Pierson–Moskowitz Hs ≈ 0.21 U²/g split over 4 components around the wind direction.
            var rng = EvoRNG(seed: seed)
            let U = max(0.5, spec.windSpeed), hs = 0.21 * U * U / kGravity
            let peakOmega = 0.877 * kGravity / U
            for i in 0..<4 {
                let om = peakOmega * (0.8 + 0.25 * Double(i)), k = om * om / kGravity
                let a = (spec.windDirectionDeg + rng.uniform(-30, 30)) * kDeg
                w.append(Wave(dir: Vec2d(sin(a), cos(a)), k: k, omega: om, amp: hs * 0.5 / 2, phase: rng.uniform(0, 2 * .pi)))
            }
        }
        waves = w
        if let terrain { terrainHeight = { [terrain] x, z in terrain.height(x: x, z: z) } } else { terrainHeight = nil }
    }

    @inline(__always) func seaHeight(x: Double, z: Double, time: Double) -> Double {
        var h = seaLevel
        for w in waves { h += w.amp * sin(w.k * (w.dir.x * x + w.dir.y * z) - w.omega * time + w.phase) }
        return h
    }

    public func sample(x: Double, z: Double, time: Double) -> WaterSample {
        var best = WaterSample(surfaceHeight: -1e9), found = false
        if oceanEnabled {
            var gx = 0.0, gz = 0.0, vy = 0.0
            for w in waves {
                let ph = w.k * (w.dir.x * x + w.dir.y * z) - w.omega * time + w.phase, c = cos(ph)
                gx += w.amp * w.k * w.dir.x * c; gz += w.amp * w.k * w.dir.y * c; vy += -w.amp * w.omega * c
            }
            best = WaterSample(surfaceHeight: seaHeight(x: x, z: z, time: time), surfaceNormal: simd_normalize(Vec3d(-gx, 1, -gz)), velocity: Vec3d(0, vy, 0))
            found = true
        }
        for l in lakes where l.contains(x: x, z: z) && (!found || l.level > best.surfaceHeight) { best = WaterSample(surfaceHeight: l.level); found = true }
        for r in rivers {
            if let q = r.query(x: x, z: z), !found || q.height > best.surfaceHeight {
                let f = r.flow(x: x, z: z) ?? .zero
                best = WaterSample(surfaceHeight: q.height, velocity: Vec3d(f.x, 0, f.y)); found = true
            }
        }
        if found, let th = terrainHeight { best.depth = best.surfaceHeight - th(x, z) }
        return best
    }
    public func flow(x: Double, z: Double) -> Vec2d {
        for r in rivers { if let f = r.flow(x: x, z: z) { return f } }
        return .zero
    }
    /// Buoyancy + hydrodynamics via Hydrodynamics.compute. Allocates a small closure per call (only while the
    /// hull is within ~1 m of a water surface); no splash particles headless.
    public func submergedForces(hull: HullMesh, state: BodyState, time: Double) -> (ForceTorque, submergedVolume: Double) {
        let com = state.centerOfMass
        let s = sample(x: com.x, z: com.z, time: time)
        guard s.surfaceHeight > -1e8 else { return (.zero, 0) }
        var rho = 1000.0
        if oceanEnabled && abs(s.surfaceHeight - seaHeight(x: com.x, z: com.z, time: time)) < 0.5 { rho = seawaterDensity }
        else if let l = lakes.first(where: { $0.contains(x: com.x, z: com.z) }) { rho = l.density }
        let r = Hydrodynamics.compute(hull: hull, state: state, density: rho, gravity: kGravity, settings: hydro,
                                      heightAt: { [self] x, z in
                                          var h = -1e9
                                          if oceanEnabled { h = seaHeight(x: x, z: z, time: time) }
                                          for l in lakes where l.level > h && l.contains(x: x, z: z) { h = l.level }
                                          for r in rivers { if let q = r.query(x: x, z: z), q.height > h { h = q.height } }
                                          return h
                                      }, waterVelocity: s.velocity)
        return (r.0, r.volume)
    }
    public func step(dt: Double, time: Double) {}
    public func load(spec: WaterSpec) throws { throw EvolutionError.invalidExperiment("HeadlessWater is read-only") }
    public func makeSpec() -> WaterSpec { WaterSpec() }
}

/// Everything an episode needs from the world. Immutable after construction; share across workers.
public final class HeadlessWorld: @unchecked Sendable {
    public let name: String
    public let terrain: BakedTerrain?
    public let water: HeadlessWater?
    /// World spawn (runway) from the WorldDocument.
    public let spawn: Transform
    public let environment: EnvironmentSpec
    /// Static trees / props / breakables (nil = none).
    public let obstacles: HeadlessObstacles?

    public init(name: String, terrain: BakedTerrain?, water: HeadlessWater?, spawn: Transform, environment: EnvironmentSpec, obstacles: HeadlessObstacles? = nil) {
        self.name = name; self.terrain = terrain; self.water = water; self.spawn = spawn; self.environment = environment
        self.obstacles = (obstacles?.isEmpty ?? true) ? nil : obstacles
    }

    /// Flat ground at y = 0, no water, calm.
    public static func flat() -> HeadlessWorld {
        HeadlessWorld(name: "flat", terrain: BakedTerrain(flatLevel: 0), water: nil, spawn: Transform(position: [0, 2, 0]), environment: EnvironmentSpec())
    }

    /// Bake from the app's live state (the "current" world): copies the height field, keeps water spec.
    public static func bake(field: HeightField?, water: WaterSpec?, spawn: Transform, environment: EnvironmentSpec,
                            options: HeadlessOptions = HeadlessOptions(), seed: UInt64 = 1, name: String = "current",
                            trees: (() -> [(id: Int, transform: Transform, shape: CollisionShape, breakImpulse: Double)])? = nil,
                            objects: [WorldObject] = []) -> HeadlessWorld {
        let t = (options.terrain ? field : nil).map { BakedTerrain(copying: $0) }
        let w = (options.water ? water : nil).map { HeadlessWater(spec: $0, waves: options.oceanWaves, seed: seed, terrain: t) }
        var obs: HeadlessObstacles? = nil
        if options.vegetation || options.breakables {
            let o = HeadlessObstacles()
            if options.vegetation, let trees { o.addTrees(trees()) }
            if options.breakables { o.addObjects(objects) }
            obs = o
        }
        return HeadlessWorld(name: name, terrain: t, water: w, spawn: spawn, environment: environment, obstacles: obs)
    }

    /// Build from a world document without a renderer (TerrainSystem with no registry/device; procedural
    /// erosion still uses the GPU if present). Real-world (tile) terrain needs network: prefer "current".
    public static func load(_ doc: WorldDocument, baseURL: URL?, options: HeadlessOptions = HeadlessOptions(), seed: UInt64 = 1) throws -> HeadlessWorld {
        let ts = TerrainSystem(registry: nil, device: nil)
        try ts.load(spec: doc.terrain, baseURL: baseURL)
        let field = ts.field
        return bake(field: field, water: doc.water, spawn: doc.spawn, environment: doc.environment, options: options, seed: seed, name: doc.name,
                    trees: { HeadlessObstacles.trees(world: doc, terrain: ts) }, objects: doc.objects)
    }

    /// Resolve an experiment's WorldRef. `current` must be supplied by the app for source "current".
    public static func resolve(_ ref: WorldRef, experimentURL: URL?, options: HeadlessOptions, seed: UInt64, current: (() -> HeadlessWorld)?) throws -> HeadlessWorld {
        switch ref.source {
        case "flat": return flat()
        case "inline":
            guard let d = ref.inline else { throw EvolutionError.invalidExperiment("world.source inline without world.inline") }
            return try load(d, baseURL: experimentURL?.deletingLastPathComponent(), options: options, seed: seed)
        case "file":
            guard let p = ref.path else { throw EvolutionError.invalidExperiment("world.source file without world.path") }
            let base = experimentURL?.deletingLastPathComponent()
            let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : (base?.appendingPathComponent(p) ?? URL(fileURLWithPath: p))
            let d = try JSONWorldDocumentStore().load(url: url)
            return try load(d, baseURL: url.deletingLastPathComponent(), options: options, seed: seed)
        default:
            if let current { return current() }
            throw EvolutionError.invalidExperiment("world source '\(ref.source)' needs the running app (the live world); use source \"file\" or \"inline\" for headless CLI training")
        }
    }

    /// Ground or water surface height (for AGL spawn placement).
    public func surfaceHeight(x: Double, z: Double) -> Double {
        var h = terrain?.height(x: x, z: z) ?? 0
        if let w = water { h = max(h, w.sample(x: x, z: z, time: 0).surfaceHeight) }
        return h
    }

    /// A copy whose terrain is private (perf: workers never share the terrain object's refcount cache line).
    /// Water and obstacles are immutable and stay shared.
    public func isolatedCopy() -> HeadlessWorld {
        HeadlessWorld(name: name, terrain: terrain.map { BakedTerrain(copying: $0.field) }, water: water, spawn: spawn,
                      environment: environment, obstacles: obstacles)
    }

    public func makeEnvironment(wind: Vec3d, time: Double = 0) -> SimEnvironment {
        SimEnvironment(terrain: terrain, water: water, collision: nil, wind: wind, time: time)
    }
}
