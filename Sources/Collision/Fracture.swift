// OWNED BY collision builder.
// Voronoi pre-fracture of convex shapes into convex chunks + material presets.
import Foundation
import simd
import PWCore

public struct FractureMaterial: Sendable {
    public var name: String
    public var density: Double        // kg/m³
    /// Impulse per unit of characteristic area (N·s/m²): breakImpulse = strength · V^(2/3).
    public var strength: Double
    public var friction: Double, restitution: Double
    public var pieces: Int            // default number of Voronoi cells
    public init(name: String, density: Double, strength: Double, friction: Double, restitution: Double, pieces: Int) {
        self.name = name; self.density = density; self.strength = strength; self.friction = friction; self.restitution = restitution; self.pieces = pieces
    }
    public static let wood     = FractureMaterial(name: "wood", density: 600, strength: 6_000, friction: 0.6, restitution: 0.2, pieces: 6)
    public static let concrete = FractureMaterial(name: "concrete", density: 2_400, strength: 2_000, friction: 0.8, restitution: 0.05, pieces: 8)
    public static let glass    = FractureMaterial(name: "glass", density: 2_500, strength: 250, friction: 0.4, restitution: 0.1, pieces: 12)
    public static let metal    = FractureMaterial(name: "metal", density: 7_800, strength: 60_000, friction: 0.5, restitution: 0.15, pieces: 4)
    public static let presets: [FractureMaterial] = [.wood, .concrete, .glass, .metal]
    public static func named(_ n: String) -> FractureMaterial? { presets.first { $0.name == n } }

    public func breakImpulse(volume: Double) -> Double { strength * pow(max(volume, 1e-9), 2.0 / 3.0) }
}

public enum VoronoiFracture {
    /// Split a convex point cloud (body-local) into Voronoi cells. Each returned array is the vertex set of a convex chunk.
    public static func fracture(points: [Vec3d], cells: Int, seed: UInt64) -> [[Vec3d]] {
        guard let hull = ConvexPoly.hull(points), cells > 1 else { return [points] }
        var rng = PCG32(seed: seed)
        var bb = AABB.empty; for p in hull.verts { bb.expand(p) }
        var seeds: [Vec3d] = []
        var tries = 0
        while seeds.count < cells && tries < cells * 200 {
            tries += 1
            let p = bb.min + (bb.max - bb.min) * Vec3d(rng.unit(), rng.unit(), rng.unit())
            if hull.pointInside(p) { seeds.append(p) }
        }
        var out: [[Vec3d]] = []
        for (i, s) in seeds.enumerated() {
            var cell = hull.verts
            for (j, t) in seeds.enumerated() where j != i {
                let n = (t - s).normalizedSafe, m = (s + t) * 0.5
                cell = clip(cell, n, simd_dot(n, m))
                if cell.count < 4 { break }
            }
            if cell.count >= 4, let h = ConvexPoly.hull(cell), h.massProperties().volume > 1e-9 { out.append(h.verts) }
        }
        return out
    }

    /// Clip a convex point set by the half-space n·p ≤ d.
    static func clip(_ pts: [Vec3d], _ n: Vec3d, _ d: Double) -> [Vec3d] {
        if pts.allSatisfy({ simd_dot(n, $0) <= d + 1e-12 }) { return pts }
        guard let h = ConvexPoly.hull(pts) else { return [] }
        var out: [Vec3d] = h.verts.filter { simd_dot(n, $0) <= d }
        for e in h.edges {
            let a = h.verts[e.a], b = h.verts[e.b]
            let da = simd_dot(n, a) - d, db = simd_dot(n, b) - d
            if (da < 0) != (db < 0) && abs(da - db) > 1e-15 { out.append(a + (b - a) * (da / (da - db))) }
        }
        return out
    }

    /// Convenience: build a BreakableDesc for a shape and material.
    public static func breakable(shape: CollisionShape, material: FractureMaterial, pieces: Int? = nil, seed: UInt64 = 1) -> BreakableDesc {
        var parts: [(ConvexPoly?, HullMesh?)] = []
        RigidWorld.flatten(shape, .identity, &parts, isStatic: false)
        var pieceShapes: [CollisionShape] = []
        var vol = 0.0
        for (k, (p, _)) in parts.enumerated() {
            guard let p else { continue }
            vol += p.massProperties().volume
            let src: [Vec3d]
            if p.isPolyhedron { src = p.verts } else {
                // rounded core: sample the surface
                var s: [Vec3d] = []
                for i in 0..<64 { let z = 1 - 2 * (Double(i) + 0.5) / 64, r = (1 - z * z).squareRoot(), ph = Double(i) * 2.39996
                    for c in p.verts { s.append(c + Vec3d(r * cos(ph), z, r * sin(ph)) * p.radius) } }
                src = s
            }
            for cell in fracture(points: src, cells: pieces ?? material.pieces, seed: seed &+ UInt64(k)) {
                pieceShapes.append(.convexHull(points: cell.map { $0.float }))
            }
        }
        return BreakableDesc(pieces: pieceShapes, breakImpulse: material.breakImpulse(volume: vol))
    }
}
