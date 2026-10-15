// OWNED BY import builder. -------------------------------------------------------------------
// Indexed triangle mesh used by CAD import, auto-rig and the mesh-cut tool.
import Foundation
import simd
import PWCore
import PWRender

public struct TriMesh: Sendable, Equatable {
    public var positions: [Vec3]
    public var indices: [UInt32]
    public init(positions: [Vec3] = [], indices: [UInt32] = []) { self.positions = positions; self.indices = indices }

    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { indices.isEmpty }

    /// From a non-indexed xyz soup (prototype `cad` format).
    public init(soup: [Float]) {
        positions = stride(from: 0, to: soup.count - 2, by: 3).map { Vec3(soup[$0], soup[$0 + 1], soup[$0 + 2]) }
        positions = Array(positions.prefix(positions.count / 3 * 3))
        indices = (0..<UInt32(positions.count)).map { $0 }
    }
    /// Non-indexed xyz soup for CraftPart.cad.
    public var soup: [Float] {
        var out: [Float] = []; out.reserveCapacity(indices.count * 3)
        for i in indices { let p = positions[Int(i)]; out += [p.x, p.y, p.z] }
        return out
    }
    public var bounds: (min: Vec3, max: Vec3) {
        var lo = Vec3(repeating: .infinity), hi = Vec3(repeating: -.infinity)
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return positions.isEmpty ? (.zero, .zero) : (lo, hi)
    }
    public func transformed(_ m: simd_float4x4) -> TriMesh {
        var r = self; r.positions = positions.map { (m * Vec4($0, 1)).xyz }
        // keep outward winding when the transform mirrors
        if simd_determinant(simd_float3x3(m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz)) < 0 {
            for t in 0..<triangleCount { r.indices.swapAt(t * 3 + 1, t * 3 + 2) }
        }
        return r
    }
    public func mapped(_ f: (Vec3) -> Vec3) -> TriMesh { var r = self; r.positions = positions.map(f); return r }
    public mutating func append(_ o: TriMesh) {
        let base = UInt32(positions.count); positions += o.positions; indices += o.indices.map { $0 + base }
    }

    /// Merge vertices closer than `epsilon` (spatial hash). Drops degenerate triangles.
    public func welded(epsilon: Float = 1e-5) -> TriMesh {
        var map: [SIMD3<Int64>: UInt32] = [:]; map.reserveCapacity(positions.count)
        var out: [Vec3] = []; var remap = [UInt32](repeating: 0, count: positions.count)
        let inv = 1 / max(epsilon, 1e-9)
        for (i, p) in positions.enumerated() {
            let k = SIMD3<Int64>(Int64((p.x * inv).rounded()), Int64((p.y * inv).rounded()), Int64((p.z * inv).rounded()))
            if let j = map[k] { remap[i] = j } else { let j = UInt32(out.count); map[k] = j; out.append(p); remap[i] = j }
        }
        var idx: [UInt32] = []; idx.reserveCapacity(indices.count)
        for t in 0..<triangleCount {
            let a = remap[Int(indices[t * 3])], b = remap[Int(indices[t * 3 + 1])], c = remap[Int(indices[t * 3 + 2])]
            if a != b, b != c, a != c { idx += [a, b, c] }
        }
        return TriMesh(positions: out, indices: idx)
    }

    /// Closed 2-manifold with consistent orientation: every directed edge appears once and its reverse once.
    public var isWatertight: Bool {
        guard !indices.isEmpty else { return false }
        var directed: [UInt64: Int] = [:]
        for t in 0..<triangleCount {
            for e in 0..<3 {
                let a = UInt64(indices[t * 3 + e]), b = UInt64(indices[t * 3 + (e + 1) % 3])
                directed[(a << 32) | b, default: 0] += 1
            }
        }
        for (k, n) in directed { if n != 1 || directed[((k & 0xffff_ffff) << 32) | (k >> 32)] != 1 { return false } }
        return true
    }
    /// Signed volume (positive for outward-facing closed meshes).
    public var volume: Double {
        var v = 0.0
        for t in 0..<triangleCount {
            let a = positions[Int(indices[t * 3])].double, b = positions[Int(indices[t * 3 + 1])].double, c = positions[Int(indices[t * 3 + 2])].double
            v += simd_dot(a, simd_cross(b, c)) / 6
        }
        return v
    }
    /// Flat-shaded render mesh.
    public var cpuMesh: CPUMesh { MeshBuilder.triangleSoup(soup) }

    /// Principal axes (eigenvectors of the vertex covariance), sorted by extent descending, with extents and centre.
    public func principalFrame() -> (axes: [Vec3d], extentsMin: [Double], extentsMax: [Double], center: Vec3d) {
        let pts = positions.map(\.double)
        guard !pts.isEmpty else { return ([[1, 0, 0], [0, 1, 0], [0, 0, 1]], [0, 0, 0], [0, 0, 0], .zero) }
        let mean = pts.reduce(Vec3d.zero, +) / Double(pts.count)
        var c = Mat3d(0)
        for p in pts { let d = p - mean; c += Mat3d(columns: (d * d.x, d * d.y, d * d.z)) }
        c = c * (1 / Double(pts.count))
        var axes = jacobiEigenvectors(c)
        // Prefer axis-aligned frames for near-axis-aligned parts (covariance noise on boxes).
        axes = axes.map { a in
            let m = [abs(a.x), abs(a.y), abs(a.z)]; let i = m.firstIndex(of: m.max()!)!
            if m[i] > 0.9995 { var v = Vec3d.zero; v[i] = a[i] < 0 ? -1 : 1; return v }
            return a
        }
        var ext: [(Vec3d, Double, Double)] = axes.map { a in
            var lo = Double.infinity, hi = -Double.infinity
            for p in pts { let s = simd_dot(p - mean, a); lo = min(lo, s); hi = max(hi, s) }
            return (a, lo, hi)
        }
        ext.sort { ($0.2 - $0.1) > ($1.2 - $1.1) }
        // Re-centre on the box centre along each axis.
        var center = mean
        for e in ext { center += e.0 * ((e.1 + e.2) / 2) }
        return (ext.map(\.0), ext.map { -($0.2 - $0.1) / 2 }, ext.map { ($0.2 - $0.1) / 2 }, center)
    }
}

/// Symmetric 3x3 eigenvectors by cyclic Jacobi rotations.
func jacobiEigenvectors(_ m: Mat3d) -> [Vec3d] {
    var a = [[m[0][0], m[1][0], m[2][0]], [m[0][1], m[1][1], m[2][1]], [m[0][2], m[1][2], m[2][2]]]
    var v = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
    for _ in 0..<32 {
        var off = 0.0; for i in 0..<3 { for j in 0..<3 where i != j { off += a[i][j] * a[i][j] } }
        if off < 1e-20 { break }
        for (p, q) in [(0, 1), (0, 2), (1, 2)] where abs(a[p][q]) > 1e-30 {
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot(), s = t * c
            for k in 0..<3 { let akp = a[k][p], akq = a[k][q]; a[k][p] = c * akp - s * akq; a[k][q] = s * akp + c * akq }
            for k in 0..<3 { let apk = a[p][k], aqk = a[q][k]; a[p][k] = c * apk - s * aqk; a[q][k] = s * apk + c * aqk }
            for k in 0..<3 { let vkp = v[k][p], vkq = v[k][q]; v[k][p] = c * vkp - s * vkq; v[k][q] = s * vkp + c * vkq }
        }
    }
    return (0..<3).map { Vec3d(v[0][$0], v[1][$0], v[2][$0]).normalizedSafe }
}

/// Euler XYZ degrees (three.js 'XYZ' order, R = Rx*Ry*Rz) from an orthonormal basis given as columns.
/// Inverse of `Quatd(eulerXYZDegrees:)`; used to write craft-JSON `rot`.
public func eulerXYZDegrees(basisX x: Vec3d, y: Vec3d, z: Vec3d) -> Vec3d {
    let m13 = z.x, m12 = y.x, m11 = x.x, m23 = z.y, m33 = z.z, m32 = y.z, m22 = y.y
    let ey = asin(clamp(m13, -1, 1)); var ex: Double, ez: Double
    if abs(m13) < 0.9999999 { ex = atan2(-m23, m33); ez = atan2(-m12, m11) } else { ex = atan2(m32, m22); ez = 0 }
    let r = { (v: Double) in (v / kDeg * 1e4).rounded() / 1e4 + 0 }
    return Vec3d(r(ex), r(ey), r(ez))
}
public func eulerXYZDegrees(_ q: Quatd) -> Vec3d {
    eulerXYZDegrees(basisX: q.act([1, 0, 0]), y: q.act([0, 1, 0]), z: q.act([0, 0, 1]))
}
