// OWNED BY import builder. -------------------------------------------------------------------
// Part geometry in the part-local frame, matching the prototype's makeGeo() dimensions, with nicer shapes:
// wings are cambered NACA-4-digit-style airfoil sections (chord along X, leading edge at +X, span along Z),
// tanks are capsules. Parts converted by auto-rig carry their CAD mesh (p.visual = "cad") which is used instead.
import Foundation
import simd
import PWCore
import PWRender

public enum PartMeshFactory {
    public static func mesh(for part: CraftPart) -> CPUMesh {
        let f = { (k: String) in Float(part.param(k)) }
        let rotZ90 = simd_quatf(angle: .pi / 2, axis: [0, 0, 1]), rotX90 = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        if part.partType != .cad, part.paramString("visual") == "cad", let c = part.cad, !c.isEmpty {
            return MeshBuilder.triangleSoup(Base64Floats.decode(c))
        }
        switch part.partType {
        case .box: return MeshBuilder.box([f("sx"), f("sy"), f("sz")])
        case .cylinder: return MeshBuilder.cylinder(radiusTop: f("r"), radiusBottom: f("r"), height: f("h"))
        case .cone: return MeshBuilder.cylinder(radiusTop: 0.001, radiusBottom: f("r"), height: f("h"))
        case .sphere: return MeshBuilder.sphere(radius: f("r"))
        case .wing: return airfoilWing(chord: f("chord"), thickness: f("thick"), span: f("span"), camber: f("camber"))
        case .servo: return MeshBuilder.box([0.14, 0.08, 0.08])
        case .wheel: return transform(MeshBuilder.cylinder(radiusTop: f("r"), radiusBottom: f("r"), height: f("width")), rotX90)
        case .motor: return transform(MeshBuilder.cylinder(radiusTop: 0.22, radiusBottom: 0.25, height: 0.5, segments: 16), rotZ90)
        case .prop: return MeshBuilder.box([0.06, f("d"), 0.14])
        case .jet: return transform(MeshBuilder.cylinder(radiusTop: f("r") * 0.75, radiusBottom: f("r"), height: f("len")), rotZ90)
        case .tank: return transform(capsule(radius: f("r"), length: max(0.01, f("len") - 2 * f("r"))), rotZ90)
        case .solid: return transform(MeshBuilder.cylinder(radiusTop: f("r") * 0.8, radiusBottom: f("r"), height: f("len"), segments: 16), rotZ90)
        case .cad: return MeshBuilder.triangleSoup(Base64Floats.decode(part.cad ?? ""), scale: f("scale"))
        case .sensor: return MeshBuilder.sphere(radius: 0.06)
        case nil: return MeshBuilder.box([0.2, 0.2, 0.2])
        }
    }

    static func transform(_ m: CPUMesh, _ q: simd_quatf) -> CPUMesh {
        var m = m
        for i in m.vertices.indices {
            let p = q.act(m.vertices[i].position), n = q.act(Vec3(m.vertices[i].nx, m.vertices[i].ny, m.vertices[i].nz))
            m.vertices[i] = MeshVertex(p, n, Vec2(m.vertices[i].u, m.vertices[i].v))
        }
        return m
    }

    /// Cambered airfoil extruded along Z, fitted in the prototype's box (chord × thick × span), closed with end caps.
    /// Camber (prototype Cl0) maps to a NACA mean-line max camber of ~cl0/(2π)·… clamped to 6 %.
    public static func airfoilWing(chord c: Float, thickness tk: Float, span s: Float, camber cl0: Float, stations n: Int = 24) -> CPUMesh {
        let t = max(0.02, min(0.4, tk / max(c, 1e-3)))
        let m = min(0.06, max(-0.06, cl0 / (4 * .pi) * 0.9)), pc: Float = 0.4
        // profile points from trailing edge along upper surface to leading edge and back along lower surface
        var prof: [Vec2] = []
        func pt(_ x: Float, upper: Bool) -> Vec2 {
            let yt = 5 * t * (0.2969 * sqrt(x) - 0.1260 * x - 0.3516 * x * x + 0.2843 * x * x * x - 0.1036 * x * x * x * x)
            let yc = x < pc ? m / (pc * pc) * (2 * pc * x - x * x) : m / ((1 - pc) * (1 - pc)) * ((1 - 2 * pc) + 2 * pc * x - x * x)
            return Vec2(x, yc + (upper ? yt : -yt))
        }
        for i in 0...n { let x = 0.5 * (1 + cos(Float(i) / Float(n) * .pi)); prof.append(pt(x, upper: true)) }       // TE→LE
        for i in 1..<n { let x = 0.5 * (1 - cos(Float(i) / Float(n) * .pi)); prof.append(pt(x, upper: false)) }     // LE→TE
        // to part frame: leading edge at +X; centred in chord and thickness like the prototype box
        let pts = prof.map { Vec2((0.5 - $0.x) * c, $0.y * c) }
        var ymin = Float.infinity, ymax = -Float.infinity; for p in pts { ymin = min(ymin, p.y); ymax = max(ymax, p.y) }
        let yoff = -(ymin + ymax) / 2, k = pts.count
        var v: [MeshVertex] = [], idx: [UInt32] = []
        for (i, p) in pts.enumerated() {
            let a = pts[(i + k - 1) % k], b = pts[(i + 1) % k], d = simd_normalize(b - a)
            let nrm = Vec3(d.y, -d.x, 0) * -1
            v.append(MeshVertex([p.x, p.y + yoff, -s / 2], nrm, [Float(i) / Float(k), 0]))
            v.append(MeshVertex([p.x, p.y + yoff, s / 2], nrm, [Float(i) / Float(k), 1]))
        }
        for i in 0..<k {
            let a = UInt32(i * 2), b = UInt32(((i + 1) % k) * 2)
            idx += [a, b, a + 1, b, b + 1, a + 1]
        }
        // end caps (fan around the profile centroid)
        for (z, nz) in [(-s / 2, Float(-1)), (s / 2, Float(1))] {
            let base = UInt32(v.count)
            v.append(MeshVertex([0, yoff, z], [0, 0, nz]))
            for p in pts { v.append(MeshVertex([p.x, p.y + yoff, z], [0, 0, nz])) }
            for i in 0..<k {
                let a = base + 1 + UInt32(i), b = base + 1 + UInt32((i + 1) % k)
                idx += nz > 0 ? [base, a, b] : [base, b, a]
            }
        }
        return orientOutward(CPUMesh(vertices: v, indices: idx))
    }

    /// Capsule along Y: cylinder of `length` plus hemispherical ends.
    public static func capsule(radius r: Float, length l: Float, segments: Int = 24, rings: Int = 8) -> CPUMesh {
        var v: [MeshVertex] = [], idx: [UInt32] = []
        let rows = rings * 2 + 2
        for j in 0..<rows {
            let top = j <= rings
            let ph = top ? Float(j) / Float(rings) * .pi / 2 : Float(j - rings - 1) / Float(rings) * .pi / 2 + .pi / 2
            let y = cos(ph) * r + (top ? l / 2 : -l / 2), rr = sin(ph) * r
            for i in 0...segments {
                let th = Float(i) / Float(segments) * 2 * .pi
                let n = Vec3(sin(ph) * cos(th), cos(ph), sin(ph) * sin(th))
                v.append(MeshVertex([rr * cos(th), y, rr * sin(th)], n, [Float(i) / Float(segments), Float(j) / Float(rows - 1)]))
            }
        }
        let w = UInt32(segments + 1)
        for j in 0..<UInt32(rows - 1) { for i in 0..<UInt32(segments) {
            let a = j * w + i, b = a + w
            idx += [a, a + 1, b, a + 1, b + 1, b]
        } }
        return orientOutward(CPUMesh(vertices: v, indices: idx))
    }

    /// Flips triangle winding where it disagrees with the vertex normals (counter-clockwise front faces).
    static func orientOutward(_ m: CPUMesh) -> CPUMesh {
        var m = m
        for t in 0..<(m.indices.count / 3) {
            let a = m.vertices[Int(m.indices[t * 3])], b = m.vertices[Int(m.indices[t * 3 + 1])], c = m.vertices[Int(m.indices[t * 3 + 2])]
            let fn = simd_cross(b.position - a.position, c.position - a.position)
            let vn = Vec3(a.nx + b.nx + c.nx, a.ny + b.ny + c.ny, a.nz + b.nz + c.nz)
            if simd_dot(fn, vn) < 0 { m.indices.swapAt(t * 3 + 1, t * 3 + 2) }
        }
        return m
    }
}
