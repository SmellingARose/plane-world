// OWNED BY import builder. -------------------------------------------------------------------
// Plane mesh-cut tool: splits a closed mesh by a plane into two closed parts, capping the holes by
// chaining the cut edges into loops and ear-clipping each loop in the plane.
// Limitation (TODO(import builder)): caps of nested loops (a cut through a hollow tube cross-section with an
// inner wall) are triangulated per loop, i.e. the inner loop is filled instead of being a hole; still watertight.
import Foundation
import simd
import PWCore
import PWRender

public enum MeshCut {
    public struct Result: Sendable { public var below: TriMesh; public var above: TriMesh; public var loops: Int }

    /// `below` keeps the side opposite to `normal`. Input is welded first so that shared edges stay shared.
    public static func split(_ input: TriMesh, planePoint: Vec3, planeNormal: Vec3) -> Result {
        let mesh = input.welded()
        let n = simd_normalize(planeNormal)
        let nv = mesh.positions.count
        var dist = [Float](repeating: 0, count: nv)
        let eps: Float = 1e-6 * max(1, simd_length(mesh.bounds.max - mesh.bounds.min))
        dist.withUnsafeMutableBufferPointer { d in
            let base = d.baseAddress!
            mesh.positions.withUnsafeBufferPointer { pp in
                let pb = pp.baseAddress!
                JobSystem.shared.parallelFor(nv, grain: 4096, label: "craft.meshcut.classify") { r in
                    for i in r { let s = simd_dot(pb[i] - planePoint, n); base[i] = abs(s) < eps ? eps : s }   // on-plane → above
                }
            }
        }
        var below = TriMesh(positions: mesh.positions, indices: []), above = below
        var edgeVert: [UInt64: UInt32] = [:]
        var newPos: [Vec3] = []
        func cutVertex(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let key = a < b ? (UInt64(a) << 32 | UInt64(b)) : (UInt64(b) << 32 | UInt64(a))
            if let v = edgeVert[key] { return v }
            let (i, j) = a < b ? (a, b) : (b, a)
            let t = dist[Int(i)] / (dist[Int(i)] - dist[Int(j)])
            let p = mesh.positions[Int(i)] + (mesh.positions[Int(j)] - mesh.positions[Int(i)]) * t
            let v = UInt32(nv + newPos.count); newPos.append(p); edgeVert[key] = v; return v
        }
        var capBelow: [(UInt32, UInt32)] = [], capAbove: [(UInt32, UInt32)] = []   // directed cut edges as they appear in each side's triangles
        for t in 0..<mesh.triangleCount {
            let v = [mesh.indices[t * 3], mesh.indices[t * 3 + 1], mesh.indices[t * 3 + 2]]
            let s = v.map { dist[Int($0)] > 0 }
            if s[0] == s[1] && s[1] == s[2] { if s[0] { above.indices += v } else { below.indices += v }; continue }
            // rotate so that v[0] is the lone vertex
            let lone = s[0] != s[1] && s[0] != s[2] ? 0 : (s[1] != s[0] && s[1] != s[2] ? 1 : 2)
            let a = v[lone], b = v[(lone + 1) % 3], c = v[(lone + 2) % 3]
            let ab = cutVertex(a, b), ac = cutVertex(a, c)
            let loneAbove = s[lone]
            let tri1: [UInt32] = [a, ab, ac], quad: [UInt32] = [ab, b, c, ab, c, ac]
            if loneAbove { above.indices += tri1; below.indices += quad; capAbove.append((ab, ac)); capBelow.append((ac, ab)) }
            else { below.indices += tri1; above.indices += quad; capBelow.append((ab, ac)); capAbove.append((ac, ab)) }
        }
        below.positions += newPos; above.positions += newPos
        let all = below.positions
        let (u, w) = planeBasis(n)
        let lb = capTriangles(capBelow, positions: all, u: u, w: w)
        let la = capTriangles(capAbove, positions: all, u: u, w: w)
        below.indices += lb.tris; above.indices += la.tris
        return Result(below: compact(below), above: compact(above), loops: lb.loops)
    }

    static func planeBasis(_ n: Vec3) -> (Vec3, Vec3) {
        let r: Vec3 = abs(n.x) < 0.9 ? [1, 0, 0] : [0, 1, 0]
        let u = simd_normalize(simd_cross(n, r)); return (u, simd_cross(n, u))
    }

    /// Cap = reversed boundary edges chained into loops, each ear-clipped (winding preserved).
    static func capTriangles(_ edges: [(UInt32, UInt32)], positions: [Vec3], u: Vec3, w: Vec3) -> (tris: [UInt32], loops: Int) {
        var next: [UInt32: [UInt32]] = [:]
        for (a, b) in edges { next[b, default: []].append(a) }       // reversed
        var tris: [UInt32] = [], loops = 0
        while let start = next.first(where: { !$0.value.isEmpty })?.key {
            var loop: [UInt32] = [start]; var cur = start
            while var outs = next[cur], let nx = outs.popLast() {
                next[cur] = outs.isEmpty ? nil : outs
                if nx == start { break }
                loop.append(nx); cur = nx
                if loop.count > edges.count + 1 { break }
            }
            next[start] = next[start]?.isEmpty == true ? nil : next[start]
            if loop.count >= 3 { tris += earClip(loop, positions.map { Vec2(simd_dot($0, u), simd_dot($0, w)) }); loops += 1 }
        }
        return (tris, loops)
    }

    static func earClip(_ loop: [UInt32], _ p2: [Vec2]) -> [UInt32] {
        var poly = loop
        func pt(_ i: UInt32) -> Vec2 { p2[Int(i)] }
        func cross(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Float { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        var area: Float = 0
        for i in poly.indices { let a = pt(poly[i]), b = pt(poly[(i + 1) % poly.count]); area += a.x * b.y - b.x * a.y }
        let sign: Float = area >= 0 ? 1 : -1
        var out: [UInt32] = []
        var guardCount = 0
        let maxIter = poly.count * 2 + 16
        while poly.count > 3 && guardCount < maxIter {
            guardCount += 1
            var clipped = false
            for i in poly.indices {
                let ia = poly[(i + poly.count - 1) % poly.count], ib = poly[i], ic = poly[(i + 1) % poly.count]
                let a = pt(ia), b = pt(ib), c = pt(ic)
                if cross(a, b, c) * sign <= 0 { continue }
                var inside = false
                for q in poly where q != ia && q != ib && q != ic {
                    let pq = pt(q)
                    if cross(a, b, pq) * sign >= 0 && cross(b, c, pq) * sign >= 0 && cross(c, a, pq) * sign >= 0 { inside = true; break }
                }
                if inside { continue }
                out += [ia, ib, ic]; poly.remove(at: i); clipped = true; break
            }
            if !clipped {   // degenerate / self-touching: fall back to removing the flattest vertex
                let i = poly.indices.min { abs(cross(pt(poly[($0 + poly.count - 1) % poly.count]), pt(poly[$0]), pt(poly[($0 + 1) % poly.count]))) <
                                           abs(cross(pt(poly[($1 + poly.count - 1) % poly.count]), pt(poly[$1]), pt(poly[($1 + 1) % poly.count]))) }!
                out += [poly[(i + poly.count - 1) % poly.count], poly[i], poly[(i + 1) % poly.count]]; poly.remove(at: i)
            }
        }
        if poly.count == 3 { out += poly }
        return out
    }

    static func compact(_ m: TriMesh) -> TriMesh {
        var remap = [Int32](repeating: -1, count: m.positions.count); var pos: [Vec3] = []
        let idx = m.indices.map { i -> UInt32 in
            if remap[Int(i)] < 0 { remap[Int(i)] = Int32(pos.count); pos.append(m.positions[Int(i)]) }
            return UInt32(remap[Int(i)])
        }
        return TriMesh(positions: pos, indices: idx)
    }

    /// Splits a craft part (cad or primitive) into two `cad` parts. Mass is divided by volume.
    public static func split(part: CraftPart, planePoint: Vec3d, planeNormal: Vec3d) -> (CraftPart, CraftPart)? {
        let world: TriMesh = part.partType == .cad ? CraftAssembler.worldMesh(of: part)
            : TriMesh(positionsOf: PartMeshFactory.mesh(for: part)).mapped { (part.position + part.rotation.act($0.double)).float }
        let r = split(world, planePoint: planePoint.float, planeNormal: planeNormal.float)
        guard !r.below.isEmpty, !r.above.isEmpty else { return nil }
        let vb = abs(r.below.volume), va = abs(r.above.volume), tot = max(vb + va, 1e-12)
        var a = CraftAssembler.cadPart(id: part.id + "a", name: part.name + " A", worldMesh: r.below)
        var b = CraftAssembler.cadPart(id: part.id + "b", name: part.name + " B", worldMesh: r.above)
        a.mass = part.mass * vb / tot; b.mass = part.mass * va / tot
        a.color = part.color; b.color = part.color
        return (a, b)
    }
}
