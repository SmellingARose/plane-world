// The petri-dish world: an analytic height function (thread-safe, used by the simulation)
// plus the static meshes and decoration placements built from it.
import Foundation
import simd
import PWCore
import PWRender

enum Terrain {
    static let size: Float = 5200
    static let waterLevel: Float = -9

    @inline(__always) static func ss(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }
    /// Flat base in the middle, rolling bio-terrain, and a raised dish rim at the edge.
    @inline(__always) static func height(_ x: Float, _ z: Float) -> Float {
        let r = (x * x + z * z).squareRoot()
        let n = sin(x * 0.0042 + 1.3) * cos(z * 0.0051) * 28 + sin(x * 0.011 + z * 0.007) * 11
              + sin(z * 0.019 - x * 0.004) * 5 + cos(x * 0.027 + z * 0.023) * 2.5
        let rim = max(0, r - 1900) / 220
        return n * ss(300, 750, r) + rim * rim * 60
    }
    static func normal(_ x: Float, _ z: Float) -> Vec3 {
        let e: Float = 2
        let hx = height(x + e, z) - height(x - e, z), hz = height(x, z + e) - height(x, z - e)
        return simd_normalize(Vec3(-hx, 2 * e, -hz))
    }

    /// Grid mesh with heights baked in (positions are world space; the shader shifts them camera-relative).
    static func mesh(segments: Int = 320) -> CPUMesh {
        var v: [MeshVertex] = []; v.reserveCapacity((segments + 1) * (segments + 1))
        var idx: [UInt32] = []; idx.reserveCapacity(segments * segments * 6)
        // denser near the middle: warp grid coordinates
        func warp(_ u: Float) -> Float { let s = u * 2 - 1; return (s * (0.55 + 0.45 * abs(s))) * size / 2 }
        for j in 0...segments { for i in 0...segments {
            let x = warp(Float(i) / Float(segments)), z = warp(Float(j) / Float(segments))
            v.append(MeshVertex(Vec3(x, height(x, z), z), normal(x, z)))
        } }
        let row = UInt32(segments + 1)
        for j in 0..<UInt32(segments) { for i in 0..<UInt32(segments) {
            let a = j * row + i; idx += [a, a + row, a + 1, a + 1, a + row, a + row + 1]
        } }
        return CPUMesh(vertices: v, indices: idx)
    }

    struct Decor { var prim: Part.Prim; var pos: Vec3; var scale: Vec3; var rot: Vec3; var color: Vec3; var emissive: Float; var rough: Float; var metal: Float }

    /// Scatter mushrooms, crystals, rocks and coral, avoiding the base plateau and the pools.
    static func decorations(seed: UInt64 = 7) -> [Decor] {
        var rng = PCG32(seed: seed)
        func r(_ a: Float, _ b: Float) -> Float { a + (b - a) * Float(rng.unit()) }
        var out: [Decor] = []
        func scatter(_ n: Int, _ minR: Float, _ maxR: Float, minH: Float = -6, _ make: (Vec3) -> [Decor]) {
            var k = 0, tries = 0
            while k < n && tries < n * 20 {
                tries += 1
                let a = r(0, 2 * .pi), rr = (r(minR * minR, maxR * maxR)).squareRoot()
                let x = cos(a) * rr, z = sin(a) * rr, h = height(x, z)
                if h < minH { continue }
                out += make(Vec3(x, h, z)); k += 1
            }
        }
        let caps: [Vec3] = [[0.1, 1, 0.75], [1, 0.25, 0.85], [0.2, 0.65, 1], [1, 0.75, 0.15]]
        scatter(280, 480, 1850) { p in
            let s = r(4, 14), c = caps[Int(r(0, 3.99))]
            return [Decor(prim: .cyl, pos: p + Vec3(0, s * 1.1, 0), scale: Vec3(s * 0.45, s * 2.2, s * 0.45), rot: .zero, color: [0.8, 0.75, 0.66], emissive: 0, rough: 0.8, metal: 0),
                    Decor(prim: .sphere, pos: p + Vec3(0, s * 2.2, 0), scale: Vec3(s * 1.4, s * 0.7, s * 1.4), rot: .zero, color: c * 0.8, emissive: 1.4, rough: 0.5, metal: 0)]
        }
        scatter(240, 520, 2000) { p in
            let s = r(3, 10)
            return [Decor(prim: .ico, pos: p + Vec3(0, s * 1.3, 0), scale: Vec3(s, s * r(2.5, 4.5), s), rot: Vec3(r(-0.4, 0.4), r(0, 6.28), r(-0.4, 0.4)), color: [0.3, 0.75, 1], emissive: 0.5, rough: 0.15, metal: 0.2)]
        }
        scatter(420, 460, 2300, minH: -60) { p in
            let s = r(4, 22)
            return [Decor(prim: .ico, pos: p, scale: Vec3(s * r(0.8, 1.4), s * r(0.5, 0.9), s * r(0.8, 1.4)), rot: Vec3(r(0, 3), r(0, 6), r(0, 3)), color: [0.22, 0.16, 0.28], emissive: 0, rough: 0.95, metal: 0)]
        }
        scatter(420, 600, 1900) { p in
            let s = r(1.5, 3.5), h = s * r(6, 16)
            return [Decor(prim: .cyl, pos: p + Vec3(0, h / 2, 0), scale: Vec3(s, h, s), rot: Vec3(r(-0.25, 0.25), 0, r(-0.25, 0.25)), color: [1, 0.35, 0.45], emissive: 0.25, rough: 0.5, metal: 0)]
        }
        return out
    }

    struct Cell { var pos: Vec3; var radius: Float; var color: Vec3 }
    /// Dead giant cells half-sunk in the ground (drawn translucent).
    static func giantCells(seed: UInt64 = 11) -> [Cell] {
        var rng = PCG32(seed: seed)
        return (0..<14).map { _ in
            let a = Float(rng.unit()) * 2 * .pi, rr = 700 + Float(rng.unit()) * 1100, R = 45 + Float(rng.unit()) * 65
            let x = cos(a) * rr, z = sin(a) * rr
            let hue = 0.45 + Float(rng.unit()) * 0.45
            return Cell(pos: Vec3(x, height(x, z) - R * 0.35, z), radius: R, color: hsv(hue, 0.6, 0.8))
        }
    }
}

func hsv(_ h: Float, _ s: Float, _ v: Float) -> Vec3 {
    let i = Int(h * 6) % 6, f = h * 6 - floor(h * 6)
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    let c: Vec3
    switch i { case 0: c = [v, t, p]; case 1: c = [q, v, p]; case 2: c = [p, v, t]; case 3: c = [p, q, v]; case 4: c = [t, p, v]; default: c = [v, p, q] }
    return c * c   // rough sRGB → linear
}
