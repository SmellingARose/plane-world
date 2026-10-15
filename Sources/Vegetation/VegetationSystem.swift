// OWNED BY vegetation builder. ---------------------------------------------------------------
// ProceduralVegetation: the VegetationSystem implementation.
//  * Placement: jittered-grid scatter over the world area evaluated in parallel (JobSystem) against the
//    terrain's height / slope / material layers; species chosen by habitat (palms on low sandy ground,
//    pines high/steep, oak & birch elsewhere). Painted/erased strokes are stored and replayed.
//  * Breakable trees: trunks are exposed as capsule collision proxies; an impulse above the species'
//    threshold (from `interact` or a BreakEvent on a proxy id) snaps the tree into a falling rigid body —
//    in the CollisionWorld if one is attached, otherwise with a built-in rigid-rod-on-pivot integrator.
//  * Grass: density map (material grass weight × painted density) baked around the camera for the GPU
//    blade generator; interactions are queued as splats for the GPU interaction texture.
import Foundation
import simd
import PWCore
import PWRender

/// One placed tree.
public struct TreeRecord: Sendable {
    public var position: Vec3d
    public var yaw: Float
    public var scale: Float
    public var template: Int          // index into templates
    public var tint: Float
    public var broken = false
    public var painted = false
}

/// A tree that has been broken off and is falling / lying on the ground.
public struct FallingTree: Sendable {
    public var treeID: Int
    public var transform: Transform     // tree root frame (base of trunk)
    // Built-in integrator state (pivot at the base): rotation axis (horizontal), angle, angular rate.
    public var axis: Vec3d
    public var angle: Double
    public var omega: Double
    public var restAngle: Double
    public var settled = false
    public var body: BodyHandle?
    public var baseRotation: Quatd
    public var age: Double = 0
}

/// Grass interaction splat (consumed by the GPU interaction pass each frame).
public struct GrassInteractor: Sendable {
    public var position: Vec3d
    public var radius: Double
    public var direction: Vec2d       // xz, zero = radial push
    public var strength: Double       // 0…1 (1 = flattened)
}

public final class ProceduralVegetation: VegetationSystem, @unchecked Sendable {
    // MARK: parameters (persisted in WorldDocument.vegetation)
    public var enabled = true
    public var treeDensityPerHa = 45.0
    public var areaSize = 4096.0
    public var areaCenter = Vec2d(0, 0)
    public var speciesWeights: [Double] = [1, 1, 1, 1]
    public var grassDensity = 1.0
    public var grassHeight = 0.45
    public var grassRadius = 70.0
    public var seaLevel = 0.0
    public var maxSlopeDeg = 38.0
    public var variantsPerSpecies = 2
    public private(set) var seed: UInt64 = 1

    // Brush strokes, replayed in order on generate (persisted as "strokes").
    public enum Stroke: Sendable {
        case trees(x: Double, z: Double, radius: Double, densityPerHa: Double, species: Int /* -1 = habitat */)
        case erase(x: Double, z: Double, radius: Double)
        case grass(x: Double, z: Double, radius: Double, value: Double)
        var row: [Double] {
            switch self {
            case let .trees(x, z, r, d, s): return [0, x, z, r, d, Double(s)]
            case let .erase(x, z, r): return [1, x, z, r]
            case let .grass(x, z, r, v): return [2, x, z, r, v]
            }
        }
        init?(row a: [Double]) {
            guard let k = a.first else { return nil }
            switch k {
            case 0 where a.count >= 6: self = .trees(x: a[1], z: a[2], radius: a[3], densityPerHa: a[4], species: Int(a[5]))
            case 1 where a.count >= 4: self = .erase(x: a[1], z: a[2], radius: a[3])
            case 2 where a.count >= 5: self = .grass(x: a[1], z: a[2], radius: a[3], value: a[4])
            default: return nil
            }
        }
    }
    public private(set) var strokes: [Stroke] = []

    // MARK: state
    public private(set) var templates: [TreeTemplate] = []
    public private(set) var trees: [TreeRecord] = []
    public private(set) var falling: [FallingTree] = []
    public var terrain: (any TerrainProvider)?
    /// When set, broken trees become rigid bodies in this world.
    public weak var collision: (any CollisionWorld)?
    /// Called when a tree breaks (so the App can remove that tree's static trunk body).
    public var onTreeBroken: ((Int) -> Void)?
    /// Bumped whenever the tree set changes (renderer re-uploads instances).
    public private(set) var treesVersion = 0
    /// Bumped when only broken flags changed.
    public private(set) var brokenVersion = 0
    public private(set) var grassVersion = 0
    public private(set) var templatesVersion = 0
    public private(set) var lastGenerateMs = 0.0
    public private(set) var lastTemplateMs = 0.0

    var pendingInteractors: [GrassInteractor] = []
    private let lock = NSLock()
    private var grid: [Int64: [Int32]] = [:]
    private let cellSize = 32.0
    private var grassChunks: [Int64: [UInt8]] = [:]   // 64×64 m chunks, 1 m texels, 255 = full density
    private var breakToken: EventBus.Token?
    /// Proxy ids handed to the CollisionWorld are `proxyIDBase + treeIndex`.
    public static let proxyIDBase = 0x5600_0000
    public var renderable: VegetationRenderable?

    public init(events: EventBus = .shared) {
        breakToken = events.subscribe(BreakEvent.self) { [weak self] e in
            guard let self, e.objectID >= Self.proxyIDBase, e.objectID < Self.proxyIDBase + 0x0100_0000 else { return }
            let id = e.objectID - Self.proxyIDBase
            self.lock.lock(); defer { self.lock.unlock() }
            guard id < self.trees.count else { return }
            let dir = (self.trees[id].position - e.position).normalizedSafe
            self.breakTree(id, impulse: Vec3d(dir.x, 0, dir.z).normalizedSafe * max(e.impulse, 1), at: e.position)
        }
    }
    deinit { if let t = breakToken { EventBus.shared.unsubscribe(t) } }

    // MARK: VegetationSystem

    public func generate(terrain: any TerrainProvider, params: [String: JSONValue], seed: UInt64) {
        self.terrain = terrain
        self.seed = seed
        apply(params: params)
        if templates.isEmpty || templates.count != TreeSpecies.allCases.count * variantsPerSpecies { buildTemplates() }
        regenerateTrees()
    }

    public func interact(at position: Vec3d, radius: Double, impulse: Vec3d) {
        lock.lock(); defer { lock.unlock() }
        let mag = impulse.length
        let hdir = Vec2d(impulse.x, impulse.z)
        let hl = simd_length(hdir)
        pendingInteractors.append(GrassInteractor(position: position, radius: max(radius, 0.3),
                                                  direction: hl > 1e-6 ? hdir / hl : .zero, strength: min(1, 0.35 + mag / 400)))
        if pendingInteractors.count > 256 { pendingInteractors.removeFirst(pendingInteractors.count - 256) }
        guard mag > 0 else { return }
        for id in treesNear(position, radius: radius + 1.5) {
            let t = trees[id]
            guard !t.broken else { continue }
            let tp = templates[t.template]
            let threshold = tp.params.breakImpulse * Double(t.scale * t.scale)
            // Only contacts below the crown top count; the trunk must actually be within reach.
            let dxz = simd_length(Vec2d(t.position.x - position.x, t.position.z - position.z))
            let hitH = position.y - t.position.y
            guard dxz < radius + Double(tp.trunkRadius * t.scale) + 0.5, hitH > -1, hitH < Double(tp.height * t.scale) else { continue }
            if mag >= threshold { breakTree(id, impulse: impulse, at: position) }
        }
    }

    public func step(dt: Double, wind: Vec3d, time: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !falling.isEmpty else { return }
        let g = kGravity
        for i in falling.indices {
            falling[i].age += dt
            if let h = falling[i].body, let c = collision {
                if let s = c.state(of: h) {
                    // Body frame is the trunk centre; convert to the root frame used for rendering.
                    let t = trees[falling[i].treeID], tp = templates[t.template]
                    let half = Double(tp.params.trunkHeight * t.scale) * 0.5
                    falling[i].transform = Transform(position: s.transform.apply([0, -half, 0]), rotation: s.transform.rotation)
                }
                continue
            }
            if falling[i].settled { continue }
            // Rigid rod pivoting about its base: I = m L² / 3, gravity torque = m g (L/2) sin θ.
            let t = trees[falling[i].treeID], tp = templates[t.template]
            let L = Double(tp.height * t.scale)
            let alpha = 1.5 * g / L * sin(falling[i].angle) - 0.4 * falling[i].omega   // + aerodynamic crown damping
            falling[i].omega += alpha * dt
            falling[i].angle += falling[i].omega * dt
            if falling[i].angle >= falling[i].restAngle {
                falling[i].angle = falling[i].restAngle
                falling[i].omega = -falling[i].omega * 0.2
                if abs(falling[i].omega) < 0.05 { falling[i].settled = true; falling[i].omega = 0 }
            }
            let q = Quatd(angle: falling[i].angle, axis: falling[i].axis) * falling[i].baseRotation
            falling[i].transform = Transform(position: t.position, rotation: q.normalized)
            // Crown sweeping through grass flattens it.
            if falling[i].omega > 0.3 {
                let tip = falling[i].transform.apply([0, L * 0.8, 0])
                pendingInteractors.append(GrassInteractor(position: tip, radius: Double(tp.crownRadius * t.scale), direction: .zero, strength: 1))
            }
        }
    }

    public func makeParams() -> [String: JSONValue] {
        var p: [String: JSONValue] = [
            "enabled": .bool(enabled),
            "treeDensityPerHa": .number(treeDensityPerHa),
            "areaSize": .number(areaSize),
            "areaCenter": .array([.number(areaCenter.x), .number(areaCenter.y)]),
            "speciesWeights": .object(Dictionary(uniqueKeysWithValues: TreeSpecies.allCases.map { ($0.name, JSONValue.number(speciesWeights[$0.rawValue])) })),
            "grassDensity": .number(grassDensity),
            "grassHeight": .number(grassHeight),
            "grassRadius": .number(grassRadius),
            "seaLevel": .number(seaLevel),
            "maxSlopeDeg": .number(maxSlopeDeg),
            "variantsPerSpecies": .number(Double(variantsPerSpecies)),
            "seed": .number(Double(seed)),
        ]
        p["strokes"] = .array(strokes.map { .array($0.row.map { JSONValue.number($0) }) })
        return p
    }

    public func collisionProxies() -> [(id: Int, transform: Transform, shape: CollisionShape, breakImpulse: Double)] {
        lock.lock(); defer { lock.unlock() }
        var out: [(id: Int, transform: Transform, shape: CollisionShape, breakImpulse: Double)] = []
        out.reserveCapacity(trees.count)
        for (i, t) in trees.enumerated() where !t.broken {
            let tp = templates[t.template]
            let s = Double(t.scale)
            let trunkH = Double(tp.params.trunkHeight) * s + (tp.species == .pine ? Double(tp.height) * 0.3 * s : 0)
            let r = Double(tp.trunkRadius) * s
            let half = max(0.1, trunkH * 0.5 - r)
            out.append((Self.proxyIDBase + i, Transform(position: t.position + [0, trunkH * 0.5, 0], rotation: .identity),
                        .capsule(radius: r, halfHeight: half), tp.params.breakImpulse * s * s))
        }
        return out
    }

    // MARK: brushes (WORLD tab)

    /// Paint trees in a disc. `species` nil = choose by habitat.
    public func paintTrees(center: Vec3d, radius: Double, densityPerHa: Double, species: TreeSpecies? = nil) {
        record(.trees(x: center.x, z: center.z, radius: radius, densityPerHa: densityPerHa, species: species?.rawValue ?? -1))
    }
    /// Remove all trees in a disc (also suppresses procedural trees there on regeneration).
    public func eraseTrees(center: Vec3d, radius: Double) { record(.erase(x: center.x, z: center.z, radius: radius)) }
    /// Paint grass density (0 = none, 1 = full) with a soft brush.
    public func paintGrass(center: Vec3d, radius: Double, value: Double) {
        record(.grass(x: center.x, z: center.z, radius: radius, value: clamp(value, 0, 1)))
    }
    public func clearStrokes() {
        lock.lock(); strokes.removeAll(); grassChunks.removeAll(); grassVersion += 1; lock.unlock()
        regenerateTrees()
    }
    private func record(_ s: Stroke) {
        lock.lock(); defer { lock.unlock() }
        strokes.append(s)
        applyStroke(s, index: strokes.count - 1)
    }
    /// Caller holds `lock`.
    private func applyStroke(_ s: Stroke, index: Int) {
        switch s {
        case let .trees(x, z, r, d, sp): applyTreeStroke(x: x, z: z, radius: r, densityPerHa: d, species: sp, strokeIndex: index); treesVersion += 1
        case let .erase(x, z, r): applyErase(x: x, z: z, radius: r); treesVersion += 1
        case let .grass(x, z, r, v): applyGrassStroke(x: x, z: z, radius: r, value: v); grassVersion += 1
        }
    }

    // MARK: queries

    public var aliveTreeCount: Int { trees.reduce(0) { $0 + ($1.broken ? 0 : 1) } }

    /// Painted grass density multiplier at x,z (0…1). Thread-safe for concurrent readers when no stroke is being applied.
    public func grassDensityMultiplier(x: Double, z: Double) -> Float {
        let cx = Int(floor(x / 64)), cz = Int(floor(z / 64))
        guard let c = grassChunks[Self.key(cx, cz)] else { return 1 }
        let ix = clamp(Int(x - Double(cx) * 64), 0, 63), iz = clamp(Int(z - Double(cz) * 64), 0, 63)
        return Float(c[iz * 64 + ix]) / 255
    }

    /// Drain queued grass interactors (renderer).
    func takeInteractors() -> [GrassInteractor] {
        lock.lock(); defer { lock.unlock() }
        let r = pendingInteractors; pendingInteractors.removeAll(keepingCapacity: true); return r
    }
    func snapshotFalling() -> [FallingTree] { lock.lock(); defer { lock.unlock() }; return falling }

    // MARK: internals

    static func key(_ x: Int, _ z: Int) -> Int64 { (Int64(x) << 32) ^ Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: z))) }

    func apply(params p: [String: JSONValue]) {
        func num(_ k: String) -> Double? { p[k]?.double }
        if case .bool(let b)? = p["enabled"] { enabled = b }
        treeDensityPerHa = num("treeDensityPerHa") ?? treeDensityPerHa
        areaSize = num("areaSize") ?? areaSize
        if case .array(let a)? = p["areaCenter"], a.count == 2 { areaCenter = Vec2d(a[0].double ?? 0, a[1].double ?? 0) }
        if case .object(let o)? = p["speciesWeights"] { for s in TreeSpecies.allCases { if let v = o[s.name]?.double { speciesWeights[s.rawValue] = v } } }
        grassDensity = num("grassDensity") ?? grassDensity
        grassHeight = num("grassHeight") ?? grassHeight
        grassRadius = num("grassRadius") ?? grassRadius
        seaLevel = num("seaLevel") ?? seaLevel
        maxSlopeDeg = num("maxSlopeDeg") ?? maxSlopeDeg
        variantsPerSpecies = max(1, min(4, Int(num("variantsPerSpecies") ?? Double(variantsPerSpecies))))
        if case .array(let a)? = p["strokes"] {
            strokes = a.compactMap { v -> Stroke? in if case .array(let r) = v { return Stroke(row: r.map { $0.double ?? 0 }) }; return nil }
        } else { strokes = [] }
        grassChunks.removeAll()
        for st in strokes { if case let .grass(x, z, r, v) = st { applyGrassStroke(x: x, z: z, radius: r, value: v) } }
        grassVersion += 1
    }

    /// Generate all species templates in parallel.
    public func buildTemplates() {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let n = TreeSpecies.allCases.count * variantsPerSpecies
        let vps = variantsPerSpecies, sd = seed
        let out = UnsafeMutableBufferPointer<TreeTemplate?>.allocate(capacity: n)
        out.initialize(repeating: nil)
        JobSystem.shared.parallelFor(n, grain: 1, label: "veg.templates") { r in
            for i in r { out[i] = TreeGenerator.generate(species: TreeSpecies(rawValue: i / vps)!, seed: sd &+ UInt64(i % vps) &* 7919, variant: i % vps) }
        }
        templates = out.map { $0! }
        out.deallocate()
        lastTemplateMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        treesVersion += 1; templatesVersion += 1
    }

    /// Habitat-weighted species choice; returns nil when the site is unsuitable.
    func chooseSpecies(height h: Double, normal: Vec3d, material m: TerrainMaterialSample, r: Double, forced: Int = -1) -> TreeSpecies? {
        if h < seaLevel + 0.4 { return nil }
        let slope = acos(clamp(normal.y, -1, 1)) / kDeg
        if slope > maxSlopeDeg { return nil }
        let rock = Double(m.weights.y), sand = Double(m.weights.z), snow = Double(m.weights.w)
        if forced >= 0 { return TreeSpecies(rawValue: forced) }
        let alt = h - seaLevel
        var w = speciesWeights
        w[0] *= 0.4 + smoothstep(300, 1200, alt) * 2 + slope / 30            // pine: high / steep
        w[1] *= (1 - smoothstep(600, 1400, alt)) * (1 - sand)                // oak: lowland
        w[2] *= 0.6 + 0.6 * smoothstep(100, 600, alt) * (1 - smoothstep(1400, 2000, alt))
        w[3] *= (sand > 0.3 ? 3 : 0.0) + (alt < 12 ? 1.5 : 0) * (1 - smoothstep(30, 60, alt))   // palm: coasts
        let suit = (1 - rock) * (1 - snow)
        let total = w.reduce(0, +)
        guard total > 1e-9, r * 0.999 < suit else { return nil }
        var x = (r / max(suit, 1e-9)) * total
        for (i, wi) in w.enumerated() { if x < wi { return TreeSpecies(rawValue: i) }; x -= wi }
        return .oak
    }

    static func hash(_ a: Int64, _ b: Int64, _ s: UInt64) -> UInt64 {
        var h = s &+ 0x9E3779B97F4A7C15
        h ^= UInt64(bitPattern: a) &* 0xBF58476D1CE4E5B9; h = (h ^ (h >> 31)) &* 0x94D049BB133111EB
        h ^= UInt64(bitPattern: b) &* 0x9E3779B97F4A7C15; h = (h ^ (h >> 29)) &* 0xBF58476D1CE4E5B9
        return h ^ (h >> 32)
    }

    /// Scatter trees in parallel over the area.
    public func regenerateTrees() {
        guard let terrain else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        var result: [TreeRecord] = []
        if enabled && treeDensityPerHa > 0 {
            let spacing = (10000 / treeDensityPerHa).squareRoot()
            let tb = terrain.bounds
            let half = areaSize * 0.5
            let x0 = max(areaCenter.x - half, tb.min.x), x1 = min(areaCenter.x + half, tb.max.x)
            let z0 = max(areaCenter.y - half, tb.min.z), z1 = min(areaCenter.y + half, tb.max.z)
            if x1 > x0 && z1 > z0 {
                let nx = Int((x1 - x0) / spacing), nz = Int((z1 - z0) / spacing)
                let rows = UnsafeMutableBufferPointer<[TreeRecord]>.allocate(capacity: max(nz, 1))
                rows.initialize(repeating: [])
                let vps = variantsPerSpecies, sd = seed
                JobSystem.shared.parallelFor(nz, grain: 4, label: "veg.scatter") { [self] r in
                    for iz in r {
                        var row: [TreeRecord] = []
                        for ix in 0..<nx {
                            let gx = Int64(floor(x0 / spacing)) + Int64(ix), gz = Int64(floor(z0 / spacing)) + Int64(iz)
                            var rng = PCG32(seed: Self.hash(gx, gz, sd))
                            let x = (Double(gx) + rng.unit()) * spacing, z = (Double(gz) + rng.unit()) * spacing
                            guard x >= x0, x < x1, z >= z0, z < z1 else { continue }
                            let h = terrain.height(x: x, z: z)
                            guard let sp = chooseSpecies(height: h, normal: terrain.normal(x: x, z: z), material: terrain.material(x: x, z: z), r: rng.unit()) else { continue }
                            // Clustering: low-frequency value noise thins trees into groves and clearings.
                            let grove = Self.valueNoise(x / 180, z / 180, sd)
                            if rng.unit() > smoothstep(0.25, 0.65, grove) { continue }
                            row.append(TreeRecord(position: [x, h - 0.15, z], yaw: Float(rng.unit() * 2 * .pi), scale: Float(0.75 + rng.unit() * 0.5),
                                                  template: sp.rawValue * vps + Int(rng.next32() % UInt32(vps)), tint: Float(rng.unit())))
                        }
                        rows[iz] = row
                    }
                }
                for r in rows { result += r }
                rows.deallocate()
            }
        }
        lock.lock()
        trees = result
        falling.removeAll()
        for (i, st) in strokes.enumerated() {
            switch st {
            case let .trees(x, z, r, d, sp): applyTreeStroke(x: x, z: z, radius: r, densityPerHa: d, species: sp, strokeIndex: i)
            case let .erase(x, z, r): applyErase(x: x, z: z, radius: r)
            case .grass: break   // grass map already rebuilt in apply(params:)
            }
        }
        rebuildGrid()
        treesVersion += 1
        lock.unlock()
        lastGenerateMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    static func valueNoise(_ x: Double, _ z: Double, _ s: UInt64) -> Double {
        let ix = floor(x), iz = floor(z)
        var fx = x - ix, fz = z - iz
        fx = fx * fx * (3 - 2 * fx); fz = fz * fz * (3 - 2 * fz)
        func h(_ a: Double, _ b: Double) -> Double { Double(hash(Int64(a), Int64(b), s &+ 99) >> 11) / Double(1 << 53) }
        return lerp(lerp(h(ix, iz), h(ix + 1, iz), fx), lerp(h(ix, iz + 1), h(ix + 1, iz + 1), fx), fz)
    }

    private func applyTreeStroke(x sx: Double, z sz: Double, radius: Double, densityPerHa: Double, species: Int, strokeIndex: Int) {
        guard let terrain, !templates.isEmpty else { return }
        let area = Double.pi * radius * radius / 10000
        let count = Int((area * densityPerHa).rounded())
        var rng = PCG32(seed: seed &+ UInt64(strokeIndex) &* 104729 &+ 17)
        for _ in 0..<count {
            let a = rng.unit() * 2 * .pi, r = radius * rng.unit().squareRoot()
            let x = sx + cos(a) * r, z = sz + sin(a) * r
            let h = terrain.height(x: x, z: z)
            guard let sp = chooseSpecies(height: h, normal: terrain.normal(x: x, z: z), material: terrain.material(x: x, z: z), r: rng.unit() * 0.5, forced: species) else { continue }
            trees.append(TreeRecord(position: [x, h - 0.15, z], yaw: Float(rng.unit() * 2 * .pi), scale: Float(0.75 + rng.unit() * 0.5),
                                    template: sp.rawValue * variantsPerSpecies + Int(rng.next32() % UInt32(variantsPerSpecies)), tint: Float(rng.unit()), painted: true))
            insertGrid(trees.count - 1)
        }
    }

    private func applyErase(x ex: Double, z ez: Double, radius: Double) {
        let before = trees.count
        trees.removeAll { simd_length(Vec2d($0.position.x - ex, $0.position.z - ez)) < radius }
        if trees.count != before { falling.removeAll(); rebuildGrid() }
    }

    private func applyGrassStroke(x gx: Double, z gz: Double, radius gr: Double, value gv: Double) {
        let g = (x: gx, z: gz, radius: gr, value: gv)
        let x0 = Int(floor(g.x - g.radius)), x1 = Int(ceil(g.x + g.radius)), z0 = Int(floor(g.z - g.radius)), z1 = Int(ceil(g.z + g.radius))
        for z in z0...z1 { for x in x0...x1 {
            let d = simd_length(Vec2d(Double(x) + 0.5 - g.x, Double(z) + 0.5 - g.z))
            guard d < g.radius else { continue }
            let w = 1 - smoothstep(g.radius * 0.6, g.radius, d)
            let cx = Int(floor(Double(x) / 64)), cz = Int(floor(Double(z) / 64))
            let k = Self.key(cx, cz)
            var c = grassChunks[k] ?? [UInt8](repeating: 255, count: 64 * 64)
            let i = (z - cz * 64) * 64 + (x - cx * 64)
            let cur = Double(c[i]) / 255
            c[i] = UInt8(clamp((cur + (g.value - cur) * w) * 255, 0, 255).rounded())
            grassChunks[k] = c
        } }
    }

    private func rebuildGrid() {
        grid.removeAll(keepingCapacity: true)
        for i in trees.indices { insertGrid(i) }
    }
    private func insertGrid(_ i: Int) {
        let p = trees[i].position
        grid[Self.key(Int(floor(p.x / cellSize)), Int(floor(p.z / cellSize))), default: []].append(Int32(i))
    }
    func treesNear(_ p: Vec3d, radius: Double) -> [Int] {
        var out: [Int] = []
        let r = radius + 8
        for cz in Int(floor((p.z - r) / cellSize))...Int(floor((p.z + r) / cellSize)) {
            for cx in Int(floor((p.x - r) / cellSize))...Int(floor((p.x + r) / cellSize)) {
                for i in grid[Self.key(cx, cz)] ?? [] where simd_length(Vec2d(trees[Int(i)].position.x - p.x, trees[Int(i)].position.z - p.z)) < r { out.append(Int(i)) }
            }
        }
        return out
    }

    /// Snap a tree into a falling rigid body. Caller holds `lock`.
    private func breakTree(_ id: Int, impulse: Vec3d, at hit: Vec3d) {
        guard !trees[id].broken else { return }
        trees[id].broken = true
        brokenVersion += 1
        let t = trees[id], tp = templates[t.template]
        let s = Double(t.scale)
        var hdir = Vec3d(impulse.x, 0, impulse.z).normalizedSafe
        if hdir == .zero { hdir = Vec3d(cos(Double(t.yaw)), 0, sin(Double(t.yaw))) }
        let axis = simd_normalize(simd_cross([0, 1, 0], hdir))
        let base = Quatd(angle: Double(t.yaw), axis: [0, 1, 0])
        let L = Double(tp.height) * s
        let m = tp.params.massKg * s * s * s
        let hitH = clamp(hit.y - t.position.y, 0.3, L)
        // Angular impulse about the base: ω0 = J h / I, I = m L²/3.
        let omega0 = impulse.length * hitH / (m * L * L / 3)
        // Rest angle: lie on the terrain (slope along the fall direction).
        var rest = Double.pi / 2 - 0.03
        if let terrain {
            let tipXZ = t.position + hdir * L * 0.9
            let dh = terrain.height(x: tipXZ.x, z: tipXZ.z) - t.position.y
            rest = Double.pi / 2 - atan2(dh + Double(tp.crownRadius) * s * 0.4, L * 0.9)
        }
        var f = FallingTree(treeID: id, transform: Transform(position: t.position, rotation: base), axis: axis, angle: 0.02, omega: max(omega0, 0.05),
                            restAngle: rest, body: nil, baseRotation: base)
        if let c = collision {
            let trunkH = Double(tp.params.trunkHeight) * s
            let r = Double(tp.trunkRadius) * s
            var d = RigidBodyDesc(shape: .compound([
                (Transform(position: .zero), .capsule(radius: r, halfHeight: max(0.1, trunkH * 0.5 - r))),
                (Transform(position: [0, (L - trunkH) * 0.5 + trunkH * 0.5, 0]), .sphere(radius: Double(tp.crownRadius) * s * 0.7)),
            ]), transform: Transform(position: t.position + [0, trunkH * 0.5, 0], rotation: base), mass: m)
            d.userID = Self.proxyIDBase + id
            d.friction = 0.8
            let h = c.addBody(d)
            let Icm = m * L * L / 12
            let lever = Vec3d(0, hitH - trunkH * 0.5, 0)
            c.setState(h, BodyState(transform: d.transform, linearVelocity: impulse / m, angularVelocity: simd_cross(lever, impulse) / Icm,
                                    centerOfMass: d.transform.position))
            f.body = h
        }
        falling.append(f)
        pendingInteractors.append(GrassInteractor(position: t.position, radius: 3, direction: Vec2d(hdir.x, hdir.z), strength: 1))
        onTreeBroken?(id)
    }
}

/// Empty vegetation system (kept for callers that want none).
public final class EmptyVegetation: VegetationSystem {
    public init() {}
    public func generate(terrain: any TerrainProvider, params: [String: JSONValue], seed: UInt64) {}
    public func interact(at position: Vec3d, radius: Double, impulse: Vec3d) {}
    public func step(dt: Double, wind: Vec3d, time: Double) {}
    public func makeParams() -> [String: JSONValue] { [:] }
    public func collisionProxies() -> [(id: Int, transform: Transform, shape: CollisionShape, breakImpulse: Double)] { [] }
}
