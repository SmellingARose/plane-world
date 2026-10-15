// OWNED BY terrain builder.
// Procedural terrain: seeded gradient noise, fBm, ridged multifractal and domain warping, evaluated in
// parallel on the JobSystem. Followed (optionally) by GPU hydraulic + thermal erosion (TerrainErosion.swift).
import Foundation
import simd
import PWCore

/// Seeded 2D gradient (Perlin-style, quintic fade) noise. Thread-safe after init.
public struct GradientNoise2D: Sendable {
    private var perm: [UInt16]   // 512 entries
    public init(seed: UInt64) {
        var p = (0..<256).map { UInt16($0) }
        var s = seed &* 0x9E3779B97F4A7C15 | 1
        for i in stride(from: 255, to: 0, by: -1) {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            let j = Int(s % UInt64(i + 1)); p.swapAt(i, j)
        }
        perm = p + p
    }
    @inline(__always) private func grad(_ h: UInt16, _ x: Double, _ y: Double) -> Double {
        // 8 gradient directions
        switch h & 7 {
        case 0: return x + y
        case 1: return -x + y
        case 2: return x - y
        case 3: return -x - y
        case 4: return x * 1.4142
        case 5: return -x * 1.4142
        case 6: return y * 1.4142
        default: return -y * 1.4142
        }
    }
    /// Value in roughly [-1, 1].
    @inline(__always) public func noise(_ x: Double, _ y: Double) -> Double {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let xi = Int(fx) & 255, yi = Int(fy) & 255
        let xf = x - fx, yf = y - fy
        let u = xf * xf * xf * (xf * (xf * 6 - 15) + 10), v = yf * yf * yf * (yf * (yf * 6 - 15) + 10)
        return perm.withUnsafeBufferPointer { p -> Double in
            let aa = p[Int(p[xi]) + yi], ab = p[Int(p[xi]) + yi + 1], ba = p[Int(p[xi + 1]) + yi], bb = p[Int(p[xi + 1]) + yi + 1]
            let x1 = grad(aa, xf, yf) + (grad(ba, xf - 1, yf) - grad(aa, xf, yf)) * u
            let x2 = grad(ab, xf, yf - 1) + (grad(bb, xf - 1, yf - 1) - grad(ab, xf, yf - 1)) * u
            return (x1 + (x2 - x1) * v) * 0.7071
        }
    }
    public func fbm(_ x: Double, _ y: Double, octaves: Int, lacunarity: Double = 2.03, gain: Double = 0.5) -> Double {
        var a = 1.0, f = 1.0, s = 0.0, n = 0.0
        for o in 0..<octaves { s += a * noise(x * f + Double(o) * 17.13, y * f - Double(o) * 9.71); n += a; a *= gain; f *= lacunarity }
        return s / n
    }
    /// Ridged multifractal (Musgrave), returns ~[0, 1].
    public func ridged(_ x: Double, _ y: Double, octaves: Int, lacunarity: Double = 2.0, gain: Double = 0.5) -> Double {
        var a = 1.0, f = 1.0, s = 0.0, n = 0.0, weight = 1.0
        for o in 0..<octaves {
            var r = 1 - abs(noise(x * f + Double(o) * 31.7, y * f + Double(o) * 5.3))
            r *= r; r *= weight
            weight = min(max(r * 2, 0), 1)
            s += r * a; n += a; a *= gain; f *= lacunarity
        }
        return s / n
    }
}

/// Parameters for `ProceduralTerrain`, stored in `TerrainSpec.params`.
public struct ProceduralParams: Sendable, Equatable {
    public var size = 2049                 // samples per side
    public var spacing = 8.0               // metres between samples
    public var heightScale = 1800.0        // metres of relief
    public var featureSize = 7000.0        // metres, largest feature wavelength
    public var octaves = 10
    public var ridged = 0.6                // 0 = rolling fBm, 1 = ridged mountains
    public var warp = 0.35                 // domain-warp strength (fraction of featureSize)
    public var seaLevelFraction = 0.12     // fraction of heightScale below 0 m
    public var erosionIterations = 240     // hydraulic (GPU)
    public var thermalIterations = 40
    public var erosionStrength = 1.0
    public init() {}

    public init(params p: [String: JSONValue]) {
        self.init()
        if let v = p["size"]?.double { size = max(65, min(8193, Int(v))) }
        if let v = p["spacing"]?.double { spacing = max(0.5, v) }
        if let v = p["heightScale"]?.double { heightScale = v }
        if let v = p["featureSize"]?.double { featureSize = max(100, v) }
        if let v = p["octaves"]?.double { octaves = max(1, min(16, Int(v))) }
        if let v = p["ridged"]?.double { ridged = v }
        if let v = p["warp"]?.double { warp = v }
        if let v = p["seaLevelFraction"]?.double { seaLevelFraction = v }
        if let v = p["erosionIterations"]?.double { erosionIterations = max(0, Int(v)) }
        if let v = p["thermalIterations"]?.double { thermalIterations = max(0, Int(v)) }
        if let v = p["erosionStrength"]?.double { erosionStrength = v }
    }
    public var json: [String: JSONValue] {
        ["size": .number(Double(size)), "spacing": .number(spacing), "heightScale": .number(heightScale), "featureSize": .number(featureSize),
         "octaves": .number(Double(octaves)), "ridged": .number(ridged), "warp": .number(warp), "seaLevelFraction": .number(seaLevelFraction),
         "erosionIterations": .number(Double(erosionIterations)), "thermalIterations": .number(Double(thermalIterations)),
         "erosionStrength": .number(erosionStrength)]
    }
}

public enum ProceduralTerrain {
    /// Fill `field.base` with noise terrain. Generated in 128×128 tiles as parallel jobs.
    public static func generate(into field: HeightField, seed: UInt64, params: ProceduralParams) {
        let n = GradientNoise2D(seed: seed)
        let warpN = GradientNoise2D(seed: seed ^ 0xA5A5_5A5A_DEAD_BEEF)
        let maskN = GradientNoise2D(seed: seed &+ 77)
        let W = field.width, H = field.height, s = field.spacing, o = field.origin
        let invF = 1 / params.featureSize
        let out = field.base.ptr
        let hs = params.heightScale, sea = params.seaLevelFraction, ridgedMix = params.ridged, warp = params.warp, oct = params.octaves
        // detail octaves stop once the wavelength drops under ~2 samples
        let maxOct = max(1, min(oct, Int(log2(params.featureSize / (2 * s))) + 1))
        let tile = 128, tx = (W + tile - 1) / tile, ty = (H + tile - 1) / tile
        JobSystem.shared.parallelFor(tx * ty, grain: 1, label: "terrain.procedural") { r in
            for t in r {
                let x0 = (t % tx) * tile, y0 = (t / tx) * tile
                for y in y0..<min(H, y0 + tile) { for x in x0..<min(W, x0 + tile) {
                    let wx = (o.x + Double(x) * s) * invF, wz = (o.y + Double(y) * s) * invF
                    // domain warp
                    let qx = warpN.fbm(wx * 0.5 + 3.1, wz * 0.5 + 1.7, octaves: 2), qz = warpN.fbm(wx * 0.5 - 5.2, wz * 0.5 + 8.3, octaves: 2)
                    let px = wx + warp * qx, pz = wz + warp * qz
                    let rolling = n.fbm(px, pz, octaves: maxOct) * 0.5 + 0.5
                    let mountains = n.ridged(px * 0.9 + 11, pz * 0.9 - 7, octaves: maxOct)
                    // continent mask: low frequency, decides where mountains rise
                    let mask = HeightField.smoothstep(-0.25, 0.45, maskN.fbm(wx * 0.35, wz * 0.35, octaves: 3))
                    var h = rolling * (1 - ridgedMix) + mountains * ridgedMix * (0.35 + 0.65 * mask)
                    h = pow(max(h, 0), 1.35)          // flatter valleys, sharper peaks
                    out[y * W + x] = Float(h)
                } }
            }
        }
        // normalise relief so the field spans [-sea, 1-sea] × heightScale regardless of noise statistics
        var lo = Float.infinity, hi = -Float.infinity
        for i in 0..<(W * H) { lo = min(lo, out[i]); hi = max(hi, out[i]) }
        let scale = Float(hs) / max(hi - lo, 1e-6), off = Float(sea * hs)
        JobSystem.shared.parallelFor(W * H, grain: 65536) { r in for i in r { out[i] = (out[i] - lo) * scale - off } }
        // moisture prior: low areas wetter (replaced by erosion flow when erosion runs)
        let m = field.moisture.ptr, b = field.base.ptr
        JobSystem.shared.parallelFor(W * H, grain: 65536) { r in
            for i in r { let h = Double(b[i]) / max(hs, 1); m[i] = Float(min(1, max(0, 0.65 - h * 0.8 + 0.15 * n.noise(Double(i % W) * 0.01, Double(i / W) * 0.01)))) }
        }
    }
}
