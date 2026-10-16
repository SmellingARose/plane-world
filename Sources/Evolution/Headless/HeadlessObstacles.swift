// Static CPU obstacles for headless runs: tree trunks (vertical capsules, from ProceduralVegetation's collision
// proxies) and placed world objects (props + breakables as oriented boxes). Baked once per run, read-only and
// thread-safe afterwards (uniform grid, no allocation on query).
//
// Semantics (deliberately simpler than the live RigidWorld): obstacles never move, break or fracture headless,
// and have no contact response. Any craft corner touching one latches `crashed` (CraftSim.markObstacleHit).
// Contact is tested on swept corner segments between control ticks, so fast craft do not tunnel through trunks.
// Imported-mesh props are approximated by a scaled unit box. Raycast sensors do NOT see obstacles headless.
import Foundation
import simd
import PWCore
import PWVegetation

public final class HeadlessObstacles: @unchecked Sendable {
    public struct Obstacle: Sendable {
        public var transform: Transform
        public var isCapsule: Bool
        public var radius: Double, halfHeight: Double     // capsule (axis = local y)
        public var halfExtents: Vec3d                     // box
        public var boundRadius: Double
        public var id: String
    }
    public private(set) var obstacles: [Obstacle] = []
    private var grid: [Int64: [Int32]] = [:]
    private let cell = 32.0
    private var maxBound = 0.0
    public var treeCount = 0, objectCount = 0
    public var isEmpty: Bool { obstacles.isEmpty }

    public init() {}

    @inline(__always) private func key(_ ix: Int, _ iz: Int) -> Int64 { (Int64(ix) << 32) ^ Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: iz))) }

    public func add(_ o: Obstacle) {
        let i = Int32(obstacles.count)
        obstacles.append(o)
        maxBound = max(maxBound, o.boundRadius)
        let p = o.transform.position
        grid[key(Int(floor(p.x / cell)), Int(floor(p.z / cell))), default: []].append(i)
    }

    public func addTrees(_ proxies: [(id: Int, transform: Transform, shape: CollisionShape, breakImpulse: Double)]) {
        for t in proxies {
            guard case let .capsule(r, h) = t.shape else { continue }
            add(Obstacle(transform: t.transform, isCapsule: true, radius: r, halfHeight: h, halfExtents: .zero, boundRadius: r + h, id: "tree\(t.id)"))
            treeCount += 1
        }
    }

    /// Same box sizes as AppModel.addObject.
    public func addObjects(_ objs: [WorldObject]) {
        for d in objs {
            let s = d.scale.count == 3 ? Vec3d(d.scale[0], d.scale[1], d.scale[2]) : Vec3d(1, 1, 1)
            var he = s * 0.5
            switch d.asset ?? "" {
            case "Brick wall": he = Vec3d(0.1, 1, 2) * s
            case "Tower": he = Vec3d(1.5, 6, 1.5) * s
            case "Glass pane": he = Vec3d(0.03, 1.2, 1.2) * s
            case "Pillar": he = Vec3d(0.4, 3, 0.4) * s
            default: break
            }
            add(Obstacle(transform: d.transform, isCapsule: false, radius: 0, halfHeight: 0, halfExtents: he, boundRadius: simd_length(he), id: d.id))
            objectCount += 1
        }
    }

    /// Trees generated as AppModel.loadWorld does (saved params incl. brush strokes; seed from params, else 7).
    public static func trees(world doc: WorldDocument, terrain: any TerrainProvider) -> [(id: Int, transform: Transform, shape: CollisionShape, breakImpulse: Double)] {
        let veg = ProceduralVegetation()
        let seed = UInt64(max(0, doc.vegetation["seed"]?.double ?? 7))
        veg.generate(terrain: terrain, params: doc.vegetation, seed: seed)
        return veg.collisionProxies()
    }

    @inline(__always) func inside(_ o: Obstacle, _ p: Vec3d) -> Bool {
        let l = o.transform.inverseApply(p)
        if o.isCapsule {
            let y = max(-o.halfHeight, min(o.halfHeight, l.y))
            let dx = l.x, dy = l.y - y, dz = l.z
            return dx * dx + dy * dy + dz * dz < o.radius * o.radius
        }
        return abs(l.x) < o.halfExtents.x && abs(l.y) < o.halfExtents.y && abs(l.z) < o.halfExtents.z
    }

    /// True if any swept corner segment prev[i] → cur[i] touches an obstacle near `center` (craft radius `radius`).
    public func hit(center: Vec3d, radius: Double, prev: UnsafePointer<Vec3d>, cur: UnsafePointer<Vec3d>, count: Int, travel: Double) -> Bool {
        if obstacles.isEmpty { return false }
        let reach = radius + maxBound + travel
        let x0 = Int(floor((center.x - reach) / cell)), x1 = Int(floor((center.x + reach) / cell))
        let z0 = Int(floor((center.z - reach) / cell)), z1 = Int(floor((center.z + reach) / cell))
        var ix = x0
        while ix <= x1 {
            var iz = z0
            while iz <= z1 {
                if let list = grid[key(ix, iz)] {
                    for k in list {
                        let o = obstacles[Int(k)]
                        let d = simd_length(o.transform.position - center)
                        if d > o.boundRadius + radius + travel { continue }
                        let minDim = o.isCapsule ? o.radius : min(o.halfExtents.x, o.halfExtents.y, o.halfExtents.z)
                        let stepLen = max(0.05, minDim)
                        for i in 0..<count {
                            let a = prev[i], b = cur[i]
                            let n = max(1, min(64, Int((simd_length(b - a) / stepLen).rounded(.up))))
                            for s in 0...n { if inside(o, a + (b - a) * (Double(s) / Double(n))) { return true } }
                        }
                    }
                }
                iz += 1
            }
            ix += 1
        }
        return false
    }
}
