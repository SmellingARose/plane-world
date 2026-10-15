// OWNED BY water builder.
// Lakes (flat level inside a circle or polygon) and rivers (Catmull–Rom spline centre-line with width,
// sloped surface and a parabolic cross-stream flow profile). Both serialise as the raw dictionaries in
// WaterSpec so unknown keys survive a load/save round-trip.
import Foundation
import simd
import PWCore

public struct Lake: Sendable {
    public var center: Vec2d              // x, z
    public var radius: Double
    public var level: Double
    public var polygon: [Vec2d] = []      // optional shoreline (xz); empty = circle
    public var waveScale = 0.15           // fraction of the ocean cascade amplitude used for small wind waves
    public var density = 1000.0
    public var raw: [String: JSONValue] = [:]

    public init(center: Vec2d, radius: Double, level: Double) { self.center = center; self.radius = radius; self.level = level }

    init(json: [String: JSONValue]) {
        center = Vec2d(json["x"]?.double ?? 0, json["z"]?.double ?? 0)
        radius = json["radius"]?.double ?? 50
        level = json["level"]?.double ?? 0
        waveScale = json["waveScale"]?.double ?? 0.15
        density = json["density"]?.double ?? 1000
        if case .array(let pts)? = json["points"] {
            polygon = pts.compactMap { if case .array(let a) = $0, a.count >= 2, let x = a[0].double, let z = a[a.count - 1].double { return Vec2d(x, z) }; return nil }
            if !polygon.isEmpty {
                var c = Vec2d.zero; for p in polygon { c += p }; c /= Double(polygon.count)
                center = c; radius = polygon.map { simd_length($0 - c) }.max() ?? radius
            }
        }
        raw = json
    }
    var json: [String: JSONValue] {
        var j = raw
        j["x"] = .number(center.x); j["z"] = .number(center.y); j["radius"] = .number(radius); j["level"] = .number(level)
        j["waveScale"] = .number(waveScale); j["density"] = .number(density)
        if !polygon.isEmpty { j["points"] = .array(polygon.map { .array([.number($0.x), .number($0.y)]) }) }
        return j
    }

    public func contains(x: Double, z: Double) -> Bool {
        let d = Vec2d(x, z) - center
        if simd_length_squared(d) > radius * radius { return false }
        guard polygon.count >= 3 else { return true }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > z) != (b.y > z), x < (b.x - a.x) * (z - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}

public struct River: Sendable {
    public var controlPoints: [Vec3d]
    public var width: Double
    public var speed: Double              // centre-line surface speed (m/s)
    public var density = 1000.0
    public var raw: [String: JSONValue] = [:]
    /// Resampled centre line (≈ every `step` metres) with tangents and cumulative length.
    private(set) var samples: [Vec3d] = []
    private(set) var tangents: [Vec3d] = []
    private(set) var bounds = AABB.empty

    public init(points: [Vec3d], width: Double, speed: Double) {
        controlPoints = points; self.width = width; self.speed = speed
        resample()
    }
    init(json: [String: JSONValue]) {
        var pts: [Vec3d] = []
        if case .array(let a)? = json["points"] {
            for p in a { if case .array(let c) = p, c.count >= 3, let x = c[0].double, let y = c[1].double, let z = c[2].double { pts.append(Vec3d(x, y, z)) } }
        }
        controlPoints = pts
        width = json["width"]?.double ?? 12
        speed = json["speed"]?.double ?? 1.5
        density = json["density"]?.double ?? 1000
        raw = json
        resample()
    }
    var json: [String: JSONValue] {
        var j = raw
        j["points"] = .array(controlPoints.map { .array([.number($0.x), .number($0.y), .number($0.z)]) })
        j["width"] = .number(width); j["speed"] = .number(speed); j["density"] = .number(density)
        return j
    }

    mutating func resample(step: Double = 2) {
        samples = []; tangents = []; bounds = .empty
        let n = controlPoints.count
        guard n >= 2 else { return }
        func P(_ i: Int) -> Vec3d { controlPoints[max(0, min(n - 1, i))] }
        for i in 0..<(n - 1) {
            let p0 = P(i - 1), p1 = P(i), p2 = P(i + 1), p3 = P(i + 2)
            let segs = max(1, Int(simd_length(p2 - p1) / step))
            for s in 0..<segs {
                let t = Double(s) / Double(segs)
                let t2 = t * t, t3 = t2 * t
                let p = 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
                samples.append(p)
            }
        }
        samples.append(controlPoints[n - 1])
        for i in 0..<samples.count {
            let a = samples[max(0, i - 1)], b = samples[min(samples.count - 1, i + 1)]
            var t = b - a; t.y = 0
            tangents.append(t.normalizedSafe)
            bounds.expand(samples[i])
        }
        bounds.min -= Vec3d(width, 50, width); bounds.max += Vec3d(width, 50, width)
    }

    /// Nearest centre-line point: (surface height, lateral distance, tangent) or nil if outside the channel.
    func query(x: Double, z: Double) -> (height: Double, lateral: Double, tangent: Vec3d)? {
        guard samples.count >= 2, x >= bounds.min.x, x <= bounds.max.x, z >= bounds.min.z, z <= bounds.max.z else { return nil }
        let q = Vec2d(x, z)
        var best = Double.infinity, bh = 0.0, bt = Vec3d.zero
        for i in 0..<(samples.count - 1) {
            let a = Vec2d(samples[i].x, samples[i].z), b = Vec2d(samples[i + 1].x, samples[i + 1].z)
            let ab = b - a
            let l2 = simd_length_squared(ab)
            let t = l2 > 0 ? clamp(simd_dot(q - a, ab) / l2, 0, 1) : 0
            let d = simd_length_squared(q - (a + ab * t))
            if d < best { best = d; bh = samples[i].y + (samples[i + 1].y - samples[i].y) * t; bt = tangents[i] }
        }
        let lat = best.squareRoot()
        return lat <= width / 2 ? (bh, lat, bt) : nil
    }

    func flow(x: Double, z: Double) -> Vec2d? {
        guard let r = query(x: x, z: z) else { return nil }
        let s = r.lateral / (width / 2)
        let v = speed * max(0, 1 - s * s)     // parabolic cross-stream profile, centre-line = speed
        return Vec2d(r.tangent.x, r.tangent.z) * v
    }
}
