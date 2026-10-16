// OWNED BY aero/physics builder.
// Mesh-panel aerodynamics for arbitrary (CAD) bodies: per-triangle modified-Newtonian pressure on
// windward panels, base suction on leeward panels, turbulent skin friction along the local flow.
// Occlusion: panels hidden upstream by other geometry are found with a projected depth grid
// (rasterise triangle footprints onto a plane normal to the flow, keep the most-upstream depth per
// cell). The mask is cached and rebuilt only when the body-frame flow direction turns > 3°.
import Foundation
import simd
import PWCore

public final class PanelMesh {
    public let centers: [Vec3d], normals: [Vec3d], areas: [Double]
    public let tris: [(Vec3d, Vec3d, Vec3d)]
    public let referenceLength: Double
    private(set) var shadowed: [Bool]
    private var cachedFlow = Vec3d.zero
    public private(set) var shadowRebuilds = 0

    /// Triangle soup (body-local, already scaled). Degenerate triangles are dropped.
    public init(soup: [Vec3d]) {
        var c: [Vec3d] = [], n: [Vec3d] = [], a: [Double] = [], t: [(Vec3d, Vec3d, Vec3d)] = []
        var bb = AABB.empty
        var i = 0
        while i + 2 < soup.count {
            let p0 = soup[i], p1 = soup[i + 1], p2 = soup[i + 2]; i += 3
            let cr = simd_cross(p1 - p0, p2 - p0), l = simd_length(cr)
            if l < 1e-12 { continue }
            c.append((p0 + p1 + p2) / 3); n.append(cr / l); a.append(0.5 * l); t.append((p0, p1, p2))
            bb.expand(p0); bb.expand(p1); bb.expand(p2)
        }
        centers = c; normals = n; areas = a; tris = t
        referenceLength = c.isEmpty ? 1 : max(0.05, simd_reduce_max(bb.max - bb.min))
        shadowed = Array(repeating: false, count: c.count)
        // Fix inward-facing (inconsistently wound) meshes: if the signed volume is negative, flip.
        var vol = 0.0
        for (p0, p1, p2) in t { vol += simd_dot(p0, simd_cross(p1, p2)) }
        if vol < 0 { flipped = true } else { flipped = false }
        orientedNormals = flipped ? n.map { -$0 } : n
    }
    public private(set) var flipped: Bool
    /// `normal(k)` for every panel (flip applied), for the hot evaluation loop.
    private(set) var orientedNormals: [Vec3d] = []
    public var count: Int { centers.count }
    func normal(_ i: Int) -> Vec3d { flipped ? -normals[i] : normals[i] }

    /// Update the occlusion mask for a body-frame flow direction `u` (direction the air moves).
    public func updateShadows(flowDir u: Vec3d) {
        guard count > 0 else { return }
        if simd_dot(u, cachedFlow) > cos(3 * kDeg) { return }
        cachedFlow = u; shadowRebuilds += 1
        // basis perpendicular to u
        let a: Vec3d = abs(u.x) < 0.9 ? [1, 0, 0] : [0, 1, 0]
        let e1 = simd_normalize(simd_cross(u, a)), e2 = simd_cross(u, e1)
        let G = Int(clamp(Double(count).squareRoot() * 1.5, 16, 256))
        var lo = Vec2d(repeating: .infinity), hi = Vec2d(repeating: -.infinity)
        for c in centers { let q = Vec2d(simd_dot(c, e1), simd_dot(c, e2)); lo = simd_min(lo, q); hi = simd_max(hi, q) }
        let ext = simd_max(hi - lo, Vec2d(1e-6, 1e-6)) * 1.0001
        let cell = ext / Double(G)
        var depth = [Double](repeating: .infinity, count: G * G)
        func cellRange(_ t: (Vec3d, Vec3d, Vec3d)) -> (Int, Int, Int, Int) {
            let qs = [t.0, t.1, t.2].map { Vec2d(simd_dot($0, e1), simd_dot($0, e2)) }
            let mn = simd_min(simd_min(qs[0], qs[1]), qs[2]), mx = simd_max(simd_max(qs[0], qs[1]), qs[2])
            let i0 = clamp(Int(((mn.x - lo.x) / cell.x).rounded(.down)), 0, G - 1), i1 = clamp(Int(((mx.x - lo.x) / cell.x).rounded(.down)), 0, G - 1)
            let j0 = clamp(Int(((mn.y - lo.y) / cell.y).rounded(.down)), 0, G - 1), j1 = clamp(Int(((mx.y - lo.y) / cell.y).rounded(.down)), 0, G - 1)
            return (i0, i1, j0, j1)
        }
        // depth along u: smaller = further upstream. Use the triangle's centroid depth for its footprint
        // centre cell only (conservative footprints over-shadow thin parts), full footprint for big panels.
        for k in 0..<count {
            let d = simd_dot(centers[k], u)
            let (i0, i1, j0, j1) = cellRange(tris[k])
            for j in j0...j1 { for i in i0...i1 { let idx = j * G + i; if d < depth[idx] { depth[idx] = d } } }
        }
        let tol = referenceLength * 0.02
        for k in 0..<count {
            let q = Vec2d(simd_dot(centers[k], e1), simd_dot(centers[k], e2))
            let i = clamp(Int(((q.x - lo.x) / cell.x).rounded(.down)), 0, G - 1), j = clamp(Int(((q.y - lo.y) / cell.y).rounded(.down)), 0, G - 1)
            let d = simd_dot(centers[k], u)
            // a windward panel is shadowed if something else sits clearly upstream in its cell
            shadowed[k] = simd_dot(normal(k), u) < 0 && d > depth[j * G + i] + tol + sqrt(areas[k])
        }
    }

    /// Force/torque (world frame, torque about `com`) for panels in `range`.
    /// `toWorld` rotates body→world, `origin` = world position of the mesh frame origin.
    func evaluate(range: Range<Int>, toWorld q: Quatd, origin: Vec3d, com: Vec3d, linVel: Vec3d, angVel: Vec3d,
                             wind: Vec3d, rho: Double, nu: Double, speedOfSound: Double) -> ForceTorque {
        var F = Vec3d.zero, T = Vec3d.zero
        // Raw pointers over the (immutable) panel arrays: no bounds checks, no per-panel class-property
        // access/exclusivity checks. `orientedNormals` is `normal(k)` precomputed. Same arithmetic, same order.
        let refL = referenceLength
        centers.withUnsafeBufferPointer { C in orientedNormals.withUnsafeBufferPointer { N in areas.withUnsafeBufferPointer { AR in
        shadowed.withUnsafeBufferPointer { SH in
        for k in range {
            let pw = origin + q.act(C[k])
            let r = pw - com
            let vrel = linVel + simd_cross(angVel, r) - wind
            let sp = simd_length(vrel); if sp < 0.05 { continue }
            let u = -vrel / sp                      // air direction
            let n = q.act(N[k])
            let qdyn = 0.5 * rho * sp * sp, A = AR[k]
            let c = simd_dot(n, u)                  // < 0 : windward
            var f = Vec3d.zero
            if c < 0 {
                if !SH[k] {
                    let M = sp / speedOfSound
                    let cpmax = 1 + M * M / 4       // stagnation Cp (compressible, subsonic)
                    f -= n * (cpmax * c * c * qdyn * A)
                }
            } else {
                f += n * (0.25 * c * qdyn * A)     // base / separated suction on leeward panels
            }
            // skin friction along the tangential flow
            let tang = u - n * c, tl = simd_length(tang)
            if tl > 1e-6 {
                let re = max(1e4, sp * refL / nu)
                let cf = 0.455 / pow(log10(re), 2.58)
                f += tang / tl * (cf * qdyn * A * tl)
            }
            F += f; T += simd_cross(r, f)
        }
        } } } }
        return ForceTorque(force: F, torque: T)
    }
}

public extension PanelMesh {
    /// Decode the prototype's `cad` field: base64 little-endian Float32 xyz triangle soup.
    static func decodePrototypeCAD(_ b64: String, scale: Double) -> [Vec3d]? {
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), data.count >= 36 else { return nil }
        let n = data.count / 4
        var out = [Vec3d](); out.reserveCapacity(n / 3)
        data.withUnsafeBytes { raw in
            var i = 0
            while i + 2 < n {
                let x = Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))))
                let y = Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4 + 4, as: UInt32.self))))
                let z = Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4 + 8, as: UInt32.self))))
                out.append(Vec3d(x, y, z) * scale); i += 3
            }
        }
        return out
    }
    /// Closed box triangle soup (outward winding) for hulls / tests.
    static func boxSoup(center c: Vec3d, size s: Vec3d, rotation q: Quatd = .identity) -> [Vec3d] {
        let h = s * 0.5
        func v(_ x: Double, _ y: Double, _ z: Double) -> Vec3d { c + q.act(Vec3d(x * h.x, y * h.y, z * h.z)) }
        let faces: [[Vec3d]] = [
            [v(1,-1,-1), v(1,1,-1), v(1,1,1), v(1,-1,1)], [v(-1,-1,1), v(-1,1,1), v(-1,1,-1), v(-1,-1,-1)],
            [v(-1,1,-1), v(-1,1,1), v(1,1,1), v(1,1,-1)], [v(-1,-1,1), v(-1,-1,-1), v(1,-1,-1), v(1,-1,1)],
            [v(-1,-1,1), v(1,-1,1), v(1,1,1), v(-1,1,1)], [v(1,-1,-1), v(-1,-1,-1), v(-1,1,-1), v(1,1,-1)]]
        var out: [Vec3d] = []
        for f in faces { out += [f[0], f[1], f[2], f[0], f[2], f[3]] }
        return out
    }
}
