// OWNED BY collision builder.
// Narrowphase: SAT + face clipping for polyhedra (stable stacking manifolds), GJK/EPA for rounded cores
// (spheres, capsules, rounded hulls), heightfield contacts against TerrainProvider.
import Foundation
import simd
import PWCore

public struct RawContact: Sendable {
    public var point: Vec3d      // midway between surfaces
    public var normal: Vec3d     // A → B
    public var separation: Double // < 0 = penetration
}

public enum Narrowphase {
    /// All contacts between two world-space convex shapes within `margin`.
    public static func collide(_ A: ConvexPoly, _ B: ConvexPoly, margin: Double) -> [RawContact] {
        if A.isPolyhedron && B.isPolyhedron && A.radius == 0 && B.radius == 0 { return polyPoly(A, B, margin: margin) }
        var out: [RawContact] = []
        if let c = core(A, B, margin: margin) { out.append(c) }
        // segment cores: test end points separately so a capsule lying on something gets 2 points
        if A.verts.count == 2 && !A.isPolyhedron {
            for v in A.verts { var a = ConvexPoly(verts: [v]); a.radius = A.radius; if let c = core(a, B, margin: margin) { addUnique(&out, c) } }
        }
        if B.verts.count == 2 && !B.isPolyhedron {
            for v in B.verts { var b = ConvexPoly(verts: [v]); b.radius = B.radius; if let c = core(A, b, margin: margin) { addUnique(&out, c) } }
        }
        return out
    }

    static func addUnique(_ out: inout [RawContact], _ c: RawContact) {
        if !out.contains(where: { simd_length_squared($0.point - c.point) < 1e-4 }) { out.append(c) }
    }

    /// GJK on cores + radii; EPA if the cores overlap.
    static func core(_ A: ConvexPoly, _ B: ConvexPoly, margin: Double) -> RawContact? {
        let g = GJK.distance(A, B)
        let rs = A.radius + B.radius
        if !g.overlap && g.distance > 1e-9 {
            let sep = g.distance - rs
            guard sep < margin else { return nil }
            let n = (g.pointB - g.pointA) / g.distance
            let pa = g.pointA + n * A.radius, pb = g.pointB - n * B.radius
            return RawContact(point: (pa + pb) * 0.5, normal: n, separation: sep)
        }
        guard let e = EPA.penetration(A, B) else { return nil }
        let pa = e.pointA + e.normal * A.radius, pb = e.pointB - e.normal * B.radius
        return RawContact(point: (pa + pb) * 0.5, normal: e.normal, separation: -e.depth - rs)
    }

    // MARK: SAT

    struct FaceQ { var sep = -Double.infinity; var face = -1 }
    static func faceQuery(_ A: ConvexPoly, _ B: ConvexPoly) -> FaceQ {
        var q = FaceQ()
        for (i, f) in A.faces.enumerated() {
            let v = B.verts[B.support(-f.normal)]
            let s = simd_dot(f.normal, v) - f.d
            if s > q.sep { q.sep = s; q.face = i }
        }
        return q
    }
    static func centroid(_ P: ConvexPoly) -> Vec3d { P.verts.reduce(.zero, +) / Double(P.verts.count) }

    static func polyPoly(_ A: ConvexPoly, _ B: ConvexPoly, margin: Double) -> [RawContact] {
        let fa = faceQuery(A, B); if fa.sep > margin { return [] }
        let fb = faceQuery(B, A); if fb.sep > margin { return [] }
        let cA = centroid(A), cB = centroid(B)
        var eSep = -Double.infinity, eAxis = Vec3d.zero, eia = -1, eib = -1
        for (ia, da) in A.edgeDirs.enumerated() {
            for (ib, db) in B.edgeDirs.enumerated() {
                var ax = simd_cross(da, db)
                let l = simd_length(ax); if l < 1e-5 { continue }
                ax /= l
                if simd_dot(ax, cB - cA) < 0 { ax = -ax }
                let s = simd_dot(B.verts[B.support(-ax)], ax) - simd_dot(A.verts[A.support(ax)], ax)
                if s > margin { return [] }
                if s > eSep { eSep = s; eAxis = ax; eia = ia; eib = ib }
            }
        }
        let faceBest = max(fa.sep, fb.sep)
        let relTol = 0.95, absTol = 0.002
        if eia >= 0 && eSep > faceBest + absTol {
            if let c = edgeContact(A, B, eAxis, eia, eib, eSep, margin) { return [c] }
        }
        if fb.sep > relTol * fa.sep + absTol * 0.5 {
            return clip(ref: B, refFace: fb.face, inc: A, margin: margin, flip: true)
        }
        return clip(ref: A, refFace: fa.face, inc: B, margin: margin, flip: false)
    }

    static func edgeContact(_ A: ConvexPoly, _ B: ConvexPoly, _ n: Vec3d, _ ia: Int, _ ib: Int, _ sep: Double, _ margin: Double) -> RawContact? {
        var bestA = -1, bestB = -1, ma = -Double.infinity, mb = Double.infinity
        for (k, e) in A.edges.enumerated() where e.dir == ia {
            let v = simd_dot(A.verts[e.a] + A.verts[e.b], n); if v > ma { ma = v; bestA = k }
        }
        for (k, e) in B.edges.enumerated() where e.dir == ib {
            let v = simd_dot(B.verts[e.a] + B.verts[e.b], n); if v < mb { mb = v; bestB = k }
        }
        guard bestA >= 0, bestB >= 0 else { return nil }
        let (p, q) = segmentClosest(A.verts[A.edges[bestA].a], A.verts[A.edges[bestA].b], B.verts[B.edges[bestB].a], B.verts[B.edges[bestB].b])
        return RawContact(point: (p + q) * 0.5, normal: n, separation: sep)
    }

    public static func segmentClosest(_ p1: Vec3d, _ q1: Vec3d, _ p2: Vec3d, _ q2: Vec3d) -> (Vec3d, Vec3d) {
        let d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2
        let a = simd_dot(d1, d1), e = simd_dot(d2, d2), f = simd_dot(d2, r)
        var s = 0.0, t = 0.0
        if a <= 1e-12 && e <= 1e-12 { return (p1, p2) }
        if a <= 1e-12 { t = clamp(f / e, 0, 1) } else {
            let c = simd_dot(d1, r)
            if e <= 1e-12 { s = clamp(-c / a, 0, 1) } else {
                let b = simd_dot(d1, d2), den = a * e - b * b
                s = den > 1e-12 ? clamp((b * f - c * e) / den, 0, 1) : 0
                t = (b * s + f) / e
                if t < 0 { t = 0; s = clamp(-c / a, 0, 1) } else if t > 1 { t = 1; s = clamp((b - c) / a, 0, 1) }
            }
        }
        return (p1 + d1 * s, p2 + d2 * t)
    }

    static func clip(ref: ConvexPoly, refFace: Int, inc: ConvexPoly, margin: Double, flip: Bool) -> [RawContact] {
        let rf = ref.faces[refFace]
        let n = rf.normal
        var incFace = 0, md = Double.infinity
        for (i, f) in inc.faces.enumerated() { let d = simd_dot(f.normal, n); if d < md { md = d; incFace = i } }
        var poly = inc.faces[incFace].verts.map { inc.verts[$0] }
        let rv = rf.verts.map { ref.verts[$0] }
        for k in 0..<rv.count {
            let v0 = rv[k], v1 = rv[(k + 1) % rv.count]
            let sn = simd_cross(v1 - v0, n).normalizedSafe
            let sd = simd_dot(sn, v0)
            var out: [Vec3d] = []
            for i in 0..<poly.count {
                let a = poly[i], b = poly[(i + 1) % poly.count]
                let da = simd_dot(sn, a) - sd, db = simd_dot(sn, b) - sd
                if da <= 0 { out.append(a) }
                if (da <= 0) != (db <= 0) { out.append(a + (b - a) * (da / (da - db))) }
            }
            poly = out
            if poly.isEmpty { break }
        }
        var res: [RawContact] = []
        for p in poly {
            let s = simd_dot(n, p) - rf.d
            if s <= margin { res.append(RawContact(point: p - n * (s * 0.5), normal: flip ? -n : n, separation: s)) }
        }
        return reduce(res)
    }

    /// Keep at most 4 points: deepest, farthest from it, max-area third, max-area fourth.
    public static func reduce(_ c: [RawContact]) -> [RawContact] {
        guard c.count > 4 else { return c }
        var idx: [Int] = []
        let i0 = c.indices.min { c[$0].separation < c[$1].separation }!
        idx.append(i0)
        let i1 = c.indices.max { simd_length_squared(c[$0].point - c[i0].point) < simd_length_squared(c[$1].point - c[i0].point) }!
        idx.append(i1)
        let a = c[i0].point, b = c[i1].point
        let i2 = c.indices.max { simd_length_squared(simd_cross(b - a, c[$0].point - a)) < simd_length_squared(simd_cross(b - a, c[$1].point - a)) }!
        idx.append(i2)
        let n = c[i0].normal
        let sideC = simd_dot(simd_cross(b - a, c[i2].point - a), n)
        var best = -1, bestArea = 0.0
        for i in c.indices where !idx.contains(i) {
            let p = c[i].point
            // area of triangle with the edge it lies outside of
            let areas = [simd_dot(simd_cross(b - a, p - a), n), simd_dot(simd_cross(c[i2].point - b, p - b), n), simd_dot(simd_cross(a - c[i2].point, p - c[i2].point), n)]
            let ar = areas.map { sideC >= 0 ? -$0 : $0 }.max()!
            if ar > bestArea { bestArea = ar; best = i }
        }
        if best >= 0 { idx.append(best) }
        return idx.map { c[$0] }
    }

    // MARK: Terrain

    /// Contacts of a world-space convex shape against a heightfield terrain. Normal A → terrain.
    public static func terrain(_ A: ConvexPoly, _ t: any TerrainProvider, margin: Double) -> [RawContact] {
        var res: [RawContact] = []
        func test(_ v: Vec3d, _ r: Double) {
            let h = t.height(x: v.x, z: v.z)
            if v.y - r - h > margin + r + 1 { return }
            let n = t.normal(x: v.x, z: v.z)
            let s = (v.y - h) * n.y - r
            if s < margin { res.append(RawContact(point: v - n * (r + s * 0.5), normal: -n, separation: s)) }
        }
        for v in A.verts { test(v, A.radius) }
        if A.isPolyhedron && A.radius == 0 {
            // sample face centres / edge midpoints of large faces so a big box on a bump still gets support
            for e in A.edges { test((A.verts[e.a] + A.verts[e.b]) * 0.5, 0) }
        }
        if res.count > 4 { res = reduce(res) }
        return res
    }
}
