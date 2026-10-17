// Part-local signed-distance grids for CFD voxelisation (built once in `LBMSolver.configure`, CPU).
// Each part's triangle soup is turned into a small regular grid of signed distance (metres, < 0 inside) in the
// part's own frame. Every LBM update the GPU transforms each cell centre into each nearby part's frame and samples
// that grid, so rotating servos / wheels / vanes re-voxelise for free and the zero-crossing gives the wall
// distance fraction q used by interpolated (Bouzidi) bounce-back.
//
// Sign: ray parity along +x per (y, z) row (closed meshes). Parts whose interior is shallower than 0.6·dx of the
// actual lattice (open panels, plates, thin skins — decided per domain, so the coarse shadow grid too) are treated
// as thin: the GPU subtracts 0.6·dx from their distance so they always occupy at least one cell and cannot leak.
import Foundation
import simd
import PWCore

struct PartSDF {
    var partIndex: Int
    var origin: SIMD3<Float>          // part-local position of cell (0,0,0)'s corner, metres
    var h: Float                       // cell size, metres
    var dims: SIMD3<Int32>
    var values: [Float]                // signed distance at cell centres (metres)
    var thin: Bool
    var boundRadius: Float             // max |vertex| in the part frame (+ h), for the GPU cull test
    var minValue: Float                // most negative sdf (−max interior depth); thin if −minValue < 0.6·dx

    /// Builds a grid with cell size ≈ `targetH` (clamped so the longest axis has at most `maxCells` cells).
    static func build(_ g: AeroPartGeometry, targetH: Float, maxCells: Int = 64) -> PartSDF? {
        let P = g.positions
        guard P.count >= 3, g.indices.count >= 3 else { return nil }
        var lo = P[0], hi = P[0]
        for p in P { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let ext = hi - lo
        let maxExt = max(ext.x, max(ext.y, ext.z))
        var h = max(targetH, maxExt / Float(maxCells - 4))
        h = max(h, 1e-4)
        let band = 2 * h
        let o = lo - SIMD3(repeating: band)
        let n = SIMD3<Int32>(Int32(ceil((ext.x + 2 * band) / h)) + 1, Int32(ceil((ext.y + 2 * band) / h)) + 1, Int32(ceil((ext.z + 2 * band) / h)) + 1)
        let nx = Int(n.x), ny = Int(n.y), nz = Int(n.z)
        let cnt = nx * ny * nz
        let far = Float(4 * band)
        var d = [Float](repeating: far, count: cnt)
        var parity = [UInt8](repeating: 0, count: cnt)
        let triCount = g.indices.count / 3
        @inline(__always) func c(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> { o + SIMD3(Float(i) + 0.5, Float(j) + 0.5, Float(k) + 0.5) * h }
        for t in 0..<triCount {
            let a = P[Int(g.indices[3 * t])], b = P[Int(g.indices[3 * t + 1])], cc = P[Int(g.indices[3 * t + 2])]
            // Unsigned distance in the triangle's bbox ± band.
            let tlo = simd_min(a, simd_min(b, cc)) - SIMD3(repeating: band), thi = simd_max(a, simd_max(b, cc)) + SIMD3(repeating: band)
            let i0 = max(0, Int(floor((tlo.x - o.x) / h - 0.5))), i1 = min(nx - 1, Int(ceil((thi.x - o.x) / h - 0.5)))
            let j0 = max(0, Int(floor((tlo.y - o.y) / h - 0.5))), j1 = min(ny - 1, Int(ceil((thi.y - o.y) / h - 0.5)))
            let k0 = max(0, Int(floor((tlo.z - o.z) / h - 0.5))), k1 = min(nz - 1, Int(ceil((thi.z - o.z) / h - 0.5)))
            if i0 <= i1 && j0 <= j1 && k0 <= k1 {
                for k in k0...k1 { for j in j0...j1 { for i in i0...i1 {
                    let q = c(i, j, k)
                    let dist = simd_length(q - closestPointOnTriangle(q, a, b, cc))
                    let id = i + nx * (j + ny * k)
                    if dist < d[id] { d[id] = dist }
                } } }
            }
            // Parity: ray from each (y,z) row centre along +x; flip parity of every cell beyond the crossing.
            let ylo = min(a.y, min(b.y, cc.y)), yhi = max(a.y, max(b.y, cc.y))
            let zlo = min(a.z, min(b.z, cc.z)), zhi = max(a.z, max(b.z, cc.z))
            let ja = max(0, Int(floor((ylo - o.y) / h - 0.5))), jb = min(ny - 1, Int(ceil((yhi - o.y) / h - 0.5)))
            let ka = max(0, Int(floor((zlo - o.z) / h - 0.5))), kb = min(nz - 1, Int(ceil((zhi - o.z) / h - 0.5)))
            guard ja <= jb, ka <= kb else { continue }
            for k in ka...kb { for j in ja...jb {
                // Tiny irrational offset avoids rays through shared edges/vertices.
                let py = o.y + (Float(j) + 0.5) * h + 1.37e-5 * h, pz = o.z + (Float(k) + 0.5) * h + 2.11e-5 * h
                guard let x = rayX(py, pz, a, b, cc) else { continue }
                let istart = max(0, Int(ceil((x - o.x) / h - 0.5)))
                if istart >= nx { continue }
                let base = nx * (j + ny * k)
                for i in istart..<nx { parity[base + i] ^= 1 }
            }}
        }
        // Rows whose ray leaves the grid still "inside" crossed an odd number of faces: the mesh is not watertight
        // there (open CAD soup), so that row's parity is meaningless — treat it as outside (unsigned distance).
        for k in 0..<nz { for j in 0..<ny {
            let base = nx * (j + ny * k)
            if parity[base + nx - 1] == 1 { for i in 0..<nx { parity[base + i] = 0 } }
        }}
        var inside = 0
        for i in 0..<cnt where parity[i] == 1 { d[i] = -d[i]; inside += 1 }
        var br: Float = 0
        for p in P { br = max(br, simd_length(p)) }
        return PartSDF(partIndex: g.partIndex, origin: o, h: h, dims: n, values: d, thin: inside == 0, boundRadius: br + band, minValue: d.min() ?? 0)
    }

    /// x of the intersection of the line (y=py, z=pz) with the triangle, if any.
    static func rayX(_ py: Float, _ pz: Float, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float? {
        // 2-D barycentric in (y, z).
        let v0 = SIMD2(b.y - a.y, b.z - a.z), v1 = SIMD2(c.y - a.y, c.z - a.z), v2 = SIMD2(py - a.y, pz - a.z)
        let den = v0.x * v1.y - v1.x * v0.y
        if abs(den) < 1e-14 { return nil }
        let u = (v2.x * v1.y - v1.x * v2.y) / den, v = (v0.x * v2.y - v2.x * v0.y) / den
        if u < 0 || v < 0 || u + v > 1 { return nil }
        return a.x + u * (b.x - a.x) + v * (c.x - a.x)
    }

    /// Ericson, Real-Time Collision Detection §5.1.5.
    static func closestPointOnTriangle(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b, d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c, d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
        let den = 1 / (va + vb + vc)
        return a + ab * (vb * den) + ac * (vc * den)
    }
}

/// Simple meshes used by the flow selftests and available to callers that have no mesh for a part.
public enum FlowShapes {
    public static func sphere(radius r: Float, segments: Int = 32, rings: Int = 16) -> ([Vec3], [UInt32]) {
        var p: [Vec3] = [], idx: [UInt32] = []
        for j in 0...rings {
            let th = Float.pi * Float(j) / Float(rings)
            for i in 0...segments {
                let ph = 2 * Float.pi * Float(i) / Float(segments)
                p.append(Vec3(r * sin(th) * cos(ph), r * cos(th), r * sin(th) * sin(ph)))
            }
        }
        let w = UInt32(segments + 1)
        for j in 0..<UInt32(rings) { for i in 0..<UInt32(segments) {
            let a = j * w + i, b = a + 1, c = a + w, d = c + 1
            idx += [a, c, b, b, c, d]
        } }
        return (p, idx)
    }

    /// NACA 4-digit symmetric wing (chord along +x from −c/4, span along z, centred), closed with flat tip caps.
    public static func nacaWing(chord c: Float, span b: Float, thickness t: Float = 0.12, stations n: Int = 40) -> ([Vec3], [UInt32]) {
        var prof: [SIMD2<Float>] = []
        for i in 0..<n {   // upper surface TE→LE, then lower LE→TE (cosine spacing)
            let x = 0.5 * (1 + cos(Float.pi * Float(i) / Float(n - 1)))
            prof.append(SIMD2(x, yt(x, t)))
        }
        for i in 1..<(n - 1) {
            let x = 0.5 * (1 - cos(Float.pi * Float(i) / Float(n - 1)))
            prof.append(SIMD2(x, -yt(x, t)))
        }
        let m = prof.count
        var p: [Vec3] = [], idx: [UInt32] = []
        for zs in [-b / 2, b / 2] { for q in prof { p.append(Vec3((q.x - 0.25) * c, q.y * c, zs)) } }
        for i in 0..<m {
            let a = UInt32(i), bb = UInt32((i + 1) % m), a2 = a + UInt32(m), b2 = bb + UInt32(m)
            idx += [a, bb, a2, bb, b2, a2]
        }
        for i in 1..<(m - 1) {   // tip caps (fan)
            idx += [0, UInt32(i + 1), UInt32(i)]
            idx += [UInt32(m), UInt32(m + i), UInt32(m + i + 1)]
        }
        return (p, idx)
    }
    static func yt(_ x: Float, _ t: Float) -> Float {
        5 * t * (0.2969 * x.squareRoot() - 0.1260 * x - 0.3516 * x * x + 0.2843 * x * x * x - 0.1036 * x * x * x * x)
    }

    /// Axis-aligned box centred on the origin with the given half extents.
    public static func box(half e: Vec3) -> ([Vec3], [UInt32]) {
        var p: [Vec3] = []
        for k in 0..<8 { p.append(Vec3(k & 1 == 0 ? -e.x : e.x, k & 2 == 0 ? -e.y : e.y, k & 4 == 0 ? -e.z : e.z)) }
        let f: [UInt32] = [0, 2, 1, 1, 2, 3,  4, 5, 6, 5, 7, 6,  0, 1, 4, 1, 5, 4,  2, 6, 3, 3, 6, 7,  0, 4, 2, 2, 4, 6,  1, 3, 5, 3, 7, 5]
        return (p, f)
    }
}
