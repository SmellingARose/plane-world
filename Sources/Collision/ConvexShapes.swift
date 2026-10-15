// OWNED BY collision builder.
// Convex polyhedron representation, quickhull, mass properties.
import Foundation
import simd
import PWCore

/// Convex "core" + radius. sphere = 1 vertex + r, capsule = segment + r, box/hull = polyhedron (r = 0).
public struct ConvexPoly: Sendable {
    public struct Face: Sendable { public var normal: Vec3d; public var d: Double; public var verts: [Int] } // CCW about normal
    public struct Edge: Sendable { public var a: Int; public var b: Int; public var dir: Int }
    public var verts: [Vec3d]
    public var faces: [Face] = []
    public var edges: [Edge] = []
    public var edgeDirs: [Vec3d] = []      // unique unit directions
    public var radius: Double = 0
    public init(verts: [Vec3d], radius: Double = 0) { self.verts = verts; self.radius = radius }

    public var isPolyhedron: Bool { !faces.isEmpty }

    @inlinable public func support(_ d: Vec3d) -> Int {
        var bi = 0, bd = -Double.infinity
        for i in 0..<verts.count { let v = simd_dot(verts[i], d); if v > bd { bd = v; bi = i } }
        return bi
    }

    /// Build edges + unique edge directions from faces.
    public mutating func buildEdges() {
        edges = []; edgeDirs = []
        var seen = Set<Int>()
        for f in faces {
            for k in 0..<f.verts.count {
                let a = f.verts[k], b = f.verts[(k + 1) % f.verts.count]
                let key = min(a, b) * 1_000_003 + max(a, b)
                if seen.contains(key) { continue }; seen.insert(key)
                let d = (verts[b] - verts[a]).normalizedSafe
                var di = -1
                for (i, e) in edgeDirs.enumerated() where abs(simd_dot(e, d)) > 0.99999 { di = i; break }
                if di < 0 { edgeDirs.append(d); di = edgeDirs.count - 1 }
                edges.append(Edge(a: a, b: b, dir: di))
            }
        }
    }

    public func transformed(_ t: Transform) -> ConvexPoly {
        var p = self
        p.verts = verts.map { t.apply($0) }
        p.faces = faces.map { f in let n = t.applyDir(f.normal); return Face(normal: n, d: simd_dot(n, p.verts[f.verts[0]]), verts: f.verts) }
        p.edgeDirs = edgeDirs.map { t.applyDir($0) }
        return p
    }

    /// In-place version of `transformed` (no allocation once sizes match).
    public mutating func setTransformed(from src: ConvexPoly, _ t: Transform) {
        if verts.count != src.verts.count || faces.count != src.faces.count || edgeDirs.count != src.edgeDirs.count { self = src.transformed(t); return }
        let R = Mat3d(t.rotation), p = t.position
        verts.withUnsafeMutableBufferPointer { v in for i in 0..<src.verts.count { v[i] = p + R * src.verts[i] } }
        for i in 0..<src.faces.count { let n = R * src.faces[i].normal; faces[i].normal = n; faces[i].d = simd_dot(n, verts[src.faces[i].verts[0]]) }
        for i in 0..<src.edgeDirs.count { edgeDirs[i] = R * src.edgeDirs[i] }
    }

    public static func box(_ h: Vec3d) -> ConvexPoly {
        var p = ConvexPoly(verts: [])
        for i in 0..<8 { p.verts.append(Vec3d(i & 1 == 0 ? -h.x : h.x, i & 2 == 0 ? -h.y : h.y, i & 4 == 0 ? -h.z : h.z)) }
        // faces CCW seen from outside
        let fs: [(Vec3d, [Int])] = [([-1,0,0],[0,4,6,2]), ([1,0,0],[1,3,7,5]), ([0,-1,0],[0,1,5,4]),
                                    ([0,1,0],[2,6,7,3]), ([0,0,-1],[0,2,3,1]), ([0,0,1],[4,5,7,6])]
        for (n, idx) in fs { p.faces.append(Face(normal: n, d: simd_dot(n, p.verts[idx[0]]), verts: idx)) }
        p.buildEdges(); return p
    }
    public static func sphere(_ r: Double) -> ConvexPoly { ConvexPoly(verts: [.zero], radius: r) }
    public static func capsule(_ r: Double, _ hh: Double) -> ConvexPoly { ConvexPoly(verts: [[0, -hh, 0], [0, hh, 0]], radius: r) }
    public static func triangle(_ a: Vec3d, _ b: Vec3d, _ c: Vec3d) -> ConvexPoly {
        var p = ConvexPoly(verts: [a, b, c])
        let n = simd_cross(b - a, c - a).normalizedSafe
        p.faces = [Face(normal: n, d: simd_dot(n, a), verts: [0, 1, 2]), Face(normal: -n, d: -simd_dot(n, a), verts: [0, 2, 1])]
        p.buildEdges(); return p
    }

    /// Quickhull. Returns nil if the point set is degenerate (< 4 non-coplanar points).
    public static func hull(_ input: [Vec3d], maxVerts: Int = 256) -> ConvexPoly? {
        guard let h = QuickHull.build(input) else { return nil }
        return h
    }

    /// Volume, centre of mass and inertia tensor (about COM) for unit density.
    public func massProperties() -> (volume: Double, com: Vec3d, inertia: Mat3d) {
        if !isPolyhedron {
            let r = radius
            if verts.count == 1 {
                let v = 4.0 / 3 * .pi * r * r * r
                return (v, verts[0], Mat3d(diagonal: Vec3d(repeating: 0.4 * v * r * r)))
            }
            // capsule along segment (assume local y as built)
            let a = verts[0], b = verts[1]; let h = simd_length(b - a)
            let vc = .pi * r * r * h, vs = 4.0 / 3 * .pi * r * r * r
            let ia = vc * r * r / 2 + vs * 0.4 * r * r
            let ip = vc * (3 * r * r + h * h) / 12 + vs * (0.4 * r * r + h * h / 4 + 3 * h * r / 8)
            let axis = (b - a).normalizedSafe
            // I = ip*(I - aa^T) + ia*aa^T
            let aa = Mat3d(rows: [axis * axis.x, axis * axis.y, axis * axis.z])
            let I = Mat3d(diagonal: [ip, ip, ip]) + (ia - ip) * aa
            return (vc + vs, (a + b) * 0.5, I)
        }
        var vol = 0.0, com = Vec3d.zero
        var C = Mat3d(0)
        let canon = Mat3d(rows: [[2, 1, 1], [1, 2, 1], [1, 1, 2]]) * (1.0 / 120)
        for f in faces {
            let p0 = verts[f.verts[0]]
            for k in 1..<(f.verts.count - 1) {
                let p1 = verts[f.verts[k]], p2 = verts[f.verts[k + 1]]
                let A = Mat3d(columns: (p0, p1, p2))
                let det = A.determinant
                vol += det / 6
                com += det / 6 * (p0 + p1 + p2) / 4
                C += det * A * canon * A.transpose
            }
        }
        guard vol > 1e-15 else { return (0, verts[0], Mat3d(diagonal: [1e-9, 1e-9, 1e-9])) }
        com /= vol
        let cc = Mat3d(rows: [com * com.x, com * com.y, com * com.z])
        C -= vol * cc
        let tr = C[0, 0] + C[1, 1] + C[2, 2]
        let I = Mat3d(diagonal: [tr, tr, tr]) - C
        return (vol, com, I)
    }

    public func pointInside(_ p: Vec3d) -> Bool { faces.allSatisfy { simd_dot($0.normal, p) - $0.d <= 1e-9 } }

    /// Triangle mesh for rendering/hydro (fan-triangulated faces).
    public func triangulated() -> HullMesh {
        var idx: [UInt32] = []
        for f in faces { for k in 1..<(f.verts.count - 1) { idx += [UInt32(f.verts[0]), UInt32(f.verts[k]), UInt32(f.verts[k + 1])] } }
        return HullMesh(positions: verts.map { $0.float }, indices: idx)
    }
}

enum QuickHull {
    struct Tri { var a: Int, b: Int, c: Int; var n: Vec3d; var d: Double; var outside: [Int] = []; var alive = true }

    static func build(_ pts: [Vec3d]) -> ConvexPoly? {
        guard pts.count >= 4 else { return nil }
        var bb = AABB.empty; for p in pts { bb.expand(p) }
        let scale = max(simd_length(bb.max - bb.min), 1e-9)
        let eps = 1e-9 * scale * 10
        // initial simplex
        var i0 = 0, i1 = 0
        var best = -1.0
        for axis in 0..<3 {
            var mn = 0, mx = 0
            for i in 0..<pts.count { if pts[i][axis] < pts[mn][axis] { mn = i }; if pts[i][axis] > pts[mx][axis] { mx = i } }
            let d = simd_length(pts[mx] - pts[mn]); if d > best { best = d; i0 = mn; i1 = mx }
        }
        guard best > eps else { return nil }
        var i2 = -1; best = eps
        let dir = (pts[i1] - pts[i0]).normalizedSafe
        for i in 0..<pts.count { let v = pts[i] - pts[i0]; let d = simd_length(v - dir * simd_dot(v, dir)); if d > best { best = d; i2 = i } }
        guard i2 >= 0 else { return nil }
        let pn = simd_cross(pts[i1] - pts[i0], pts[i2] - pts[i0]).normalizedSafe
        var i3 = -1; best = eps
        for i in 0..<pts.count { let d = abs(simd_dot(pts[i] - pts[i0], pn)); if d > best { best = d; i3 = i } }
        guard i3 >= 0 else { return nil }
        let centroid = (pts[i0] + pts[i1] + pts[i2] + pts[i3]) / 4
        var tris: [Tri] = []
        func makeTri(_ a: Int, _ b: Int, _ c: Int) -> Tri {
            var n = simd_cross(pts[b] - pts[a], pts[c] - pts[a]).normalizedSafe
            var t = Tri(a: a, b: b, c: c, n: n, d: simd_dot(n, pts[a]))
            if simd_dot(n, centroid) - t.d > 0 { n = -n; t = Tri(a: a, b: c, c: b, n: n, d: simd_dot(n, pts[a])) }
            return t
        }
        tris = [makeTri(i0, i1, i2), makeTri(i0, i1, i3), makeTri(i0, i2, i3), makeTri(i1, i2, i3)]
        let initial: Set<Int> = [i0, i1, i2, i3]
        for i in 0..<pts.count where !initial.contains(i) {
            for k in 0..<tris.count where simd_dot(tris[k].n, pts[i]) - tris[k].d > eps { tris[k].outside.append(i); break }
        }
        var iter = 0
        while iter < 100_000 {
            iter += 1
            guard let fi = tris.firstIndex(where: { $0.alive && !$0.outside.isEmpty }) else { break }
            // farthest point
            var ep = -1; var bd = -1.0
            for p in tris[fi].outside { let d = simd_dot(tris[fi].n, pts[p]) - tris[fi].d; if d > bd { bd = d; ep = p } }
            let P = pts[ep]
            var visible: [Int] = []
            for k in 0..<tris.count where tris[k].alive && simd_dot(tris[k].n, P) - tris[k].d > eps { visible.append(k) }
            var edgeSet = Set<Int64>()
            func key(_ a: Int, _ b: Int) -> Int64 { Int64(a) << 32 | Int64(b) }
            for k in visible { let t = tris[k]; edgeSet.insert(key(t.a, t.b)); edgeSet.insert(key(t.b, t.c)); edgeSet.insert(key(t.c, t.a)) }
            var horizon: [(Int, Int)] = []
            for k in visible {
                let t = tris[k]
                for (a, b) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] where !edgeSet.contains(key(b, a)) { horizon.append((a, b)) }
            }
            var orphans: [Int] = []
            for k in visible { orphans += tris[k].outside; tris[k].alive = false; tris[k].outside = [] }
            let start = tris.count
            for (a, b) in horizon {
                let n = simd_cross(pts[b] - pts[a], P - pts[a]).normalizedSafe
                tris.append(Tri(a: a, b: b, c: ep, n: n, d: simd_dot(n, pts[a])))
            }
            for p in orphans where p != ep {
                for k in start..<tris.count where simd_dot(tris[k].n, pts[p]) - tris[k].d > eps { tris[k].outside.append(p); break }
            }
            if tris.count > 4096 { tris = tris.filter { $0.alive } }
        }
        let live = tris.filter { $0.alive && simd_length_squared($0.n) > 0.5 }
        // merge coplanar triangles into polygons
        var remap: [Int: Int] = [:]
        var out = ConvexPoly(verts: [])
        func vi(_ i: Int) -> Int { if let r = remap[i] { return r }; out.verts.append(pts[i]); remap[i] = out.verts.count - 1; return out.verts.count - 1 }
        var used = [Bool](repeating: false, count: live.count)
        let planeTol = 1e-6 * scale + 1e-9
        for i in 0..<live.count where !used[i] {
            used[i] = true
            var group = Set([live[i].a, live[i].b, live[i].c])
            var nsum = live[i].n
            for j in (i + 1)..<max(i + 1, live.count) where !used[j] {
                if simd_dot(live[j].n, live[i].n) > 1 - 1e-6 && abs(live[j].d - live[i].d) < planeTol {
                    used[j] = true; group.formUnion([live[j].a, live[j].b, live[j].c]); nsum += live[j].n
                }
            }
            let n = nsum.normalizedSafe
            let gp = Array(group)
            let c = gp.reduce(Vec3d.zero) { $0 + pts[$1] } / Double(gp.count)
            let u = (pts[gp[0]] - c - n * simd_dot(pts[gp[0]] - c, n)).normalizedSafe
            let w = simd_cross(n, u)
            let sorted = gp.sorted { atan2(simd_dot(pts[$0] - c, w), simd_dot(pts[$0] - c, u)) < atan2(simd_dot(pts[$1] - c, w), simd_dot(pts[$1] - c, u)) }
            // drop collinear vertices
            var poly: [Int] = []
            for k in 0..<sorted.count {
                let p = pts[sorted[(k + sorted.count - 1) % sorted.count]], q = pts[sorted[k]], r = pts[sorted[(k + 1) % sorted.count]]
                if simd_length(simd_cross(q - p, r - q)) > 1e-9 * scale * scale { poly.append(sorted[k]) }
            }
            if poly.count < 3 { continue }
            let idx = poly.map(vi)
            out.faces.append(ConvexPoly.Face(normal: n, d: simd_dot(n, out.verts[idx[0]]), verts: idx))
        }
        guard out.faces.count >= 4 else { return nil }
        out.buildEdges()
        return out
    }
}
