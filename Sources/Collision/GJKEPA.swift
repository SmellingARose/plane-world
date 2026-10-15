// OWNED BY collision builder.
// GJK distance (closest points between convex cores) and EPA penetration depth.
import Foundation
import simd
import PWCore

public struct GJKResult: Sendable {
    public var distance: Double       // core-to-core distance (0 if overlapping)
    public var pointA: Vec3d, pointB: Vec3d
    public var overlap: Bool
}

public enum GJK {
    struct SV { var a: Vec3d; var b: Vec3d; var w: Vec3d }

    /// Closest point to the origin on a simplex; returns barycentric weights and reduces the simplex.
    static func closest(_ s: inout [SV]) -> (Vec3d, [Double]) {
        switch s.count {
        case 1: return (s[0].w, [1])
        case 2:
            let a = s[0].w, b = s[1].w, ab = b - a
            let t = simd_dot(-a, ab) / max(simd_length_squared(ab), 1e-300)
            if t <= 0 { s = [s[0]]; return (a, [1]) }
            if t >= 1 { s = [s[1]]; return (b, [1]) }
            return (a + ab * t, [1 - t, t])
        case 3:
            let (p, bc, keep) = triangleClosest(s[0].w, s[1].w, s[2].w)
            var ns: [SV] = []; var nb: [Double] = []
            var bi = 0
            for i in 0..<3 where keep[i] { ns.append(s[i]); nb.append(bc[bi]); bi += 1 }
            s = ns; return (p, nb)
        default:
            // tetrahedron: if origin inside → overlap (signalled by zero vector with full simplex)
            let a = s[0].w, b = s[1].w, c = s[2].w, d = s[3].w
            func outside(_ p: Vec3d, _ q: Vec3d, _ r: Vec3d, _ o: Vec3d) -> Bool {
                let n = simd_cross(q - p, r - p)
                let sp = simd_dot(-p, n), so = simd_dot(o - p, n)
                return sp * so < 0
            }
            var bestD = Double.infinity; var bestP = Vec3d.zero; var bestS: [SV] = []; var bestB: [Double] = []
            let facesIdx = [(0, 1, 2, 3), (0, 1, 3, 2), (0, 2, 3, 1), (1, 2, 3, 0)]
            var anyOutside = false
            for (i, j, k, l) in facesIdx {
                let pts = [a, b, c, d]
                if outside(pts[i], pts[j], pts[k], pts[l]) {
                    anyOutside = true
                    var sub = [s[i], s[j], s[k]]
                    let (p, bc) = closest(&sub)
                    let dd = simd_length_squared(p)
                    if dd < bestD { bestD = dd; bestP = p; bestS = sub; bestB = bc }
                }
            }
            if !anyOutside { return (.zero, [0.25, 0.25, 0.25, 0.25]) }
            s = bestS; return (bestP, bestB)
        }
    }

    /// Ericson's closest point on triangle to origin.
    static func triangleClosest(_ a: Vec3d, _ b: Vec3d, _ c: Vec3d) -> (Vec3d, [Double], [Bool]) {
        let p = Vec3d.zero
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return (a, [1], [true, false, false]) }
        let bp = p - b; let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return (b, [1], [false, true, false]) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { let v = d1 / (d1 - d3); return (a + ab * v, [1 - v, v], [true, true, false]) }
        let cp = p - c; let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return (c, [1], [false, false, true]) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { let w = d2 / (d2 - d6); return (a + ac * w, [1 - w, w], [true, false, true]) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6)); return (b + (c - b) * w, [1 - w, w], [false, true, true])
        }
        let den = 1 / (va + vb + vc); let v = vb * den, w = vc * den
        return (a + ab * v + ac * w, [1 - v - w, v, w], [true, true, true])
    }

    @inline(__always) static func support(_ A: ConvexPoly, _ B: ConvexPoly, _ d: Vec3d) -> SV {
        let a = A.verts[A.support(d)], b = B.verts[B.support(-d)]
        return SV(a: a, b: b, w: a - b)
    }

    /// Distance between the cores (ignores radii).
    public static func distance(_ A: ConvexPoly, _ B: ConvexPoly) -> GJKResult {
        var s: [SV] = []; var simplexOut: [SV] = []
        let r = run(A, B, &s)
        simplexOut = s; _ = simplexOut
        return r
    }

    static func run(_ A: ConvexPoly, _ B: ConvexPoly, _ s: inout [SV]) -> GJKResult {
        var d = A.verts[0] - B.verts[0]
        if simd_length_squared(d) < 1e-20 { d = [1, 0, 0] }
        s = [support(A, B, -d)]
        var v = s[0].w
        var bc: [Double] = [1]
        for _ in 0..<64 {
            let vv = simd_length_squared(v)
            if vv < 1e-18 { return GJKResult(distance: 0, pointA: s[0].a, pointB: s[0].a, overlap: true) }
            let w = support(A, B, -v)
            if vv - simd_dot(v, w.w) <= 1e-10 * vv + 1e-14 { break }
            if s.contains(where: { simd_length_squared($0.w - w.w) < 1e-20 }) { break }
            s.append(w)
            (v, bc) = closest(&s)
            if s.count == 4 { return GJKResult(distance: 0, pointA: .zero, pointB: .zero, overlap: true) }
        }
        (v, bc) = closest(&s)
        var pa = Vec3d.zero, pb = Vec3d.zero
        for i in 0..<s.count { pa += s[i].a * bc[i]; pb += s[i].b * bc[i] }
        return GJKResult(distance: simd_length(v), pointA: pa, pointB: pb, overlap: false)
    }

    /// Point-vs-core distance (for sphere tracing raycasts).
    public static func pointDistance(_ p: Vec3d, _ A: ConvexPoly) -> Double {
        distance(ConvexPoly(verts: [p]), A).distance
    }
}

public enum EPA {
    /// Penetration of overlapping cores. Returns normal pointing from A to B and depth (>0), contact points on A and B.
    public static func penetration(_ A: ConvexPoly, _ B: ConvexPoly) -> (normal: Vec3d, depth: Double, pointA: Vec3d, pointB: Vec3d)? {
        var s: [GJK.SV] = []
        let g = GJK.run(A, B, &s)
        guard g.overlap else { return nil }
        // Build an initial tetrahedron containing the origin
        var pts: [GJK.SV] = []
        let dirs: [Vec3d] = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1], [0.577, 0.577, 0.577], [-0.577, 0.577, -0.577]]
        for v in s where !pts.contains(where: { simd_length_squared($0.w - v.w) < 1e-18 }) { pts.append(v) }
        var di = 0
        while pts.count < 4 && di < dirs.count {
            let v = GJK.support(A, B, dirs[di]); di += 1
            if pts.contains(where: { simd_length_squared($0.w - v.w) < 1e-18 }) { continue }
            if pts.count == 2 && simd_length(simd_cross(pts[1].w - pts[0].w, v.w - pts[0].w)) < 1e-12 { continue }
            if pts.count == 3 && abs(simd_dot(simd_cross(pts[1].w - pts[0].w, pts[2].w - pts[0].w), v.w - pts[0].w)) < 1e-15 { continue }
            pts.append(v)
        }
        guard pts.count == 4 else {
            // degenerate (e.g. coincident points): pick an arbitrary axis
            let n = Vec3d(0, 1, 0)
            let depth = simd_dot(A.verts[A.support(n)], n) - simd_dot(B.verts[B.support(-n)], n)
            return (n, max(depth, 0), A.verts[A.support(n)], B.verts[B.support(-n)])
        }
        struct F { var i: Int, j: Int, k: Int; var n: Vec3d; var d: Double }
        let centroid = (pts[0].w + pts[1].w + pts[2].w + pts[3].w) / 4
        func mk(_ i: Int, _ j: Int, _ k: Int) -> F {
            var n = simd_cross(pts[j].w - pts[i].w, pts[k].w - pts[i].w).normalizedSafe
            var f = F(i: i, j: j, k: k, n: n, d: simd_dot(n, pts[i].w))
            if simd_dot(n, centroid) > f.d { n = -n; f = F(i: i, j: k, k: j, n: n, d: -f.d) }
            return f
        }
        var faces = [mk(0, 1, 2), mk(0, 1, 3), mk(0, 2, 3), mk(1, 2, 3)]
        var best = faces[0]
        for _ in 0..<64 {
            best = faces.min { $0.d < $1.d }!
            let v = GJK.support(A, B, best.n)
            let dist = simd_dot(v.w, best.n)
            if dist - best.d < 1e-7 { break }
            pts.append(v); let pi = pts.count - 1
            var edges: [(Int, Int)] = []
            var keep: [F] = []
            for f in faces {
                if simd_dot(f.n, v.w) - f.d > 1e-12 {
                    for (a, b) in [(f.i, f.j), (f.j, f.k), (f.k, f.i)] {
                        if let idx = edges.firstIndex(where: { $0.0 == b && $0.1 == a }) { edges.remove(at: idx) } else { edges.append((a, b)) }
                    }
                } else { keep.append(f) }
            }
            for (a, b) in edges {
                let n = simd_cross(pts[b].w - pts[a].w, v.w - pts[a].w).normalizedSafe
                if simd_length_squared(n) < 0.5 { continue }
                keep.append(F(i: a, j: b, k: pi, n: n, d: simd_dot(n, pts[a].w)))
            }
            if keep.isEmpty { break }
            faces = keep
        }
        // barycentric of origin projection on best face
        let p = best.n * best.d
        let a = pts[best.i].w, b = pts[best.j].w, c = pts[best.k].w
        let v0 = b - a, v1 = c - a, v2 = p - a
        let d00 = simd_dot(v0, v0), d01 = simd_dot(v0, v1), d11 = simd_dot(v1, v1), d20 = simd_dot(v2, v0), d21 = simd_dot(v2, v1)
        let den = d00 * d11 - d01 * d01
        var bv = 0.0, bw = 0.0
        if abs(den) > 1e-300 { bv = (d11 * d20 - d01 * d21) / den; bw = (d00 * d21 - d01 * d20) / den }
        let bu = 1 - bv - bw
        let pa = pts[best.i].a * bu + pts[best.j].a * bv + pts[best.k].a * bw
        let pb = pts[best.i].b * bu + pts[best.j].b * bv + pts[best.k].b * bw
        // Closest boundary point of A−B is n·d: translating B by +n·d separates them, so n points A→B.
        return (best.n, best.d, pa, pb)
    }
}
