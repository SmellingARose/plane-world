// Core math. World-space simulation uses Double (SIMD3<Double>) so positions stay
// precise over 100+ km worlds; rendering uses Float in camera-relative space.
// Conventions: right-handed, +Y up, world ground plane is XZ. Craft frame (same as the
// web prototype): +X forward, +Y up, +Z right. Angles in JSON are degrees, Euler XYZ (three.js order).
import simd
import Foundation

public typealias Vec2 = SIMD2<Float>
public typealias Vec3 = SIMD3<Float>
public typealias Vec4 = SIMD4<Float>
public typealias Vec2d = SIMD2<Double>
public typealias Vec3d = SIMD3<Double>
public typealias Quatd = simd_quatd
public typealias Quatf = simd_quatf
public typealias Mat4 = simd_float4x4
public typealias Mat3 = simd_float3x3
public typealias Mat3d = simd_double3x3

public let kDeg = Double.pi / 180
public let kGravity = 9.81

@inlinable public func clamp<T: Comparable>(_ v: T, _ a: T, _ b: T) -> T { max(a, min(b, v)) }
@inlinable public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
@inlinable public func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = clamp((x - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t)
}

public extension SIMD3 where Scalar == Double {
    @inlinable var float: Vec3 { Vec3(Float(x), Float(y), Float(z)) }
    @inlinable var length: Double { simd_length(self) }
    @inlinable var normalizedSafe: Vec3d { let l = simd_length(self); return l > 1e-12 ? self / l : .zero }
}
public extension SIMD3 where Scalar == Float {
    @inlinable var double: Vec3d { Vec3d(Double(x), Double(y), Double(z)) }
    @inlinable var xyz1: Vec4 { Vec4(x, y, z, 1) }
}
public extension SIMD4 where Scalar == Float {
    @inlinable var xyz: Vec3 { Vec3(x, y, z) }
}

public extension simd_quatd {
    static let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    /// Euler XYZ in degrees (three.js 'XYZ' order: R = Rx * Ry * Rz), as used by craft JSON `rot`.
    init(eulerXYZDegrees e: Vec3d) {
        let qx = simd_quatd(angle: e.x * kDeg, axis: [1, 0, 0])
        let qy = simd_quatd(angle: e.y * kDeg, axis: [0, 1, 0])
        let qz = simd_quatd(angle: e.z * kDeg, axis: [0, 0, 1])
        self = qx * qy * qz
    }
    var float: simd_quatf { simd_quatf(ix: Float(imag.x), iy: Float(imag.y), iz: Float(imag.z), r: Float(real)) }
}

/// Rigid transform in double precision.
public struct Transform: Codable, Sendable, Equatable {
    public var position: Vec3d
    public var rotation: Quatd
    public init(position: Vec3d = .zero, rotation: Quatd = .identity) { self.position = position; self.rotation = rotation }
    public static let identity = Transform()
    @inlinable public func apply(_ p: Vec3d) -> Vec3d { position + rotation.act(p) }
    @inlinable public func applyDir(_ d: Vec3d) -> Vec3d { rotation.act(d) }
    @inlinable public func inverseApply(_ p: Vec3d) -> Vec3d { rotation.inverse.act(p - position) }
    @inlinable public static func * (a: Transform, b: Transform) -> Transform {
        Transform(position: a.apply(b.position), rotation: (a.rotation * b.rotation).normalized)
    }
    /// Float matrix relative to a render origin (camera-relative rendering).
    public func matrix(relativeTo origin: Vec3d, scale: Vec3 = .one) -> Mat4 {
        let r = Mat3(rotation.float)
        let t = (position - origin).float
        return Mat4(columns: (Vec4(r.columns.0 * scale.x, 0), Vec4(r.columns.1 * scale.y, 0),
                              Vec4(r.columns.2 * scale.z, 0), Vec4(t, 1)))
    }
    enum CodingKeys: String, CodingKey { case position, rotation }
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        position = try c.decode(Vec3d.self, forKey: .position)
        let q = try c.decode([Double].self, forKey: .rotation)
        rotation = q.count == 4 ? Quatd(ix: q[0], iy: q[1], iz: q[2], r: q[3]) : .identity
    }
    public func encode(to e: any Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(position, forKey: .position)
        try c.encode([rotation.imag.x, rotation.imag.y, rotation.imag.z, rotation.real], forKey: .rotation)
    }
}

public extension Mat4 {
    static let identity = matrix_identity_float4x4
    init(translation t: Vec3) {
        self = matrix_identity_float4x4; columns.3 = Vec4(t, 1)
    }
    init(scale s: Vec3) { self = Mat4(diagonal: Vec4(s, 1)) }
    init(_ q: simd_quatf) { self = simd_float4x4(q) }
    /// Right-handed look-at view matrix.
    static func lookAt(eye: Vec3, target: Vec3, up: Vec3) -> Mat4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return Mat4(columns: (Vec4(s.x, u.x, -f.x, 0), Vec4(s.y, u.y, -f.y, 0), Vec4(s.z, u.z, -f.z, 0),
                              Vec4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }
    /// Reverse-Z infinite-far perspective (depth 1 at near, 0 at infinity). Metal NDC z in [0,1].
    static func perspectiveReverseZInfinite(fovY: Float, aspect: Float, near: Float) -> Mat4 {
        let f = 1 / tan(fovY * 0.5)
        return Mat4(columns: (Vec4(f / aspect, 0, 0, 0), Vec4(0, f, 0, 0), Vec4(0, 0, 0, -1), Vec4(0, 0, near, 0)))
    }
    /// Standard orthographic (z in [0,1], near maps to 0) for shadow maps.
    static func orthographic(left l: Float, right r: Float, bottom b: Float, top t: Float, near n: Float, far f: Float) -> Mat4 {
        Mat4(columns: (Vec4(2 / (r - l), 0, 0, 0), Vec4(0, 2 / (t - b), 0, 0), Vec4(0, 0, -1 / (f - n), 0),
                       Vec4((l + r) / (l - r), (t + b) / (b - t), -n / (f - n), 1)))
    }
}

/// Axis-aligned bounding box.
public struct AABB: Sendable, Codable, Equatable {
    public var min: Vec3d, max: Vec3d
    public init(min: Vec3d, max: Vec3d) { self.min = min; self.max = max }
    public static let empty = AABB(min: Vec3d(repeating: .infinity), max: Vec3d(repeating: -.infinity))
    public var center: Vec3d { (min + max) * 0.5 }
    public var extents: Vec3d { (max - min) * 0.5 }
    public mutating func expand(_ p: Vec3d) { min = simd_min(min, p); max = simd_max(max, p) }
    public func union(_ o: AABB) -> AABB { AABB(min: simd_min(min, o.min), max: simd_max(max, o.max)) }
    public func intersects(_ o: AABB) -> Bool { all(min .<= o.max) && all(o.min .<= max) }
}

public struct Ray: Sendable { public var origin: Vec3d; public var direction: Vec3d
    public init(origin: Vec3d, direction: Vec3d) { self.origin = origin; self.direction = direction.normalizedSafe } }

public struct RayHit: Sendable { public var distance: Double; public var position: Vec3d; public var normal: Vec3d; public var userID: Int
    public init(distance: Double, position: Vec3d, normal: Vec3d, userID: Int = -1) {
        self.distance = distance; self.position = position; self.normal = normal; self.userID = userID } }

/// Deterministic PCG32 RNG for procedural generation (seedable, Sendable value type).
public struct PCG32: RandomNumberGenerator, Sendable {
    var state: UInt64, inc: UInt64
    public init(seed: UInt64, stream: UInt64 = 54) { state = 0; inc = (stream << 1) | 1; _ = next32(); state &+= seed; _ = next32() }
    public mutating func next32() -> UInt32 {
        let old = state; state = old &* 6364136223846793005 &+ inc
        let xs = UInt32(truncatingIfNeeded: ((old >> 18) ^ old) >> 27), rot = UInt32(truncatingIfNeeded: old >> 59)
        return (xs >> rot) | (xs << ((~rot &+ 1) & 31))
    }
    public mutating func next() -> UInt64 { (UInt64(next32()) << 32) | UInt64(next32()) }
    public mutating func unit() -> Double { Double(next32()) / 4294967296.0 }
}

/// International Standard Atmosphere (troposphere + lower stratosphere), same as the prototype
/// for h <= 11 km, extended isothermal above.
public struct Atmosphere: Sendable {
    public var temperature: Double, pressure: Double, density: Double, speedOfSound: Double
    public static func isa(altitude h: Double) -> Atmosphere {
        let hc = clamp(h, -500, 11000)
        let T = 288.15 - 0.0065 * hc
        var p = 101325 * pow(T / 288.15, 5.2559)
        if h > 11000 { p *= exp(-(h - 11000) * 9.80665 / (287.05 * 216.65)) }
        let rho = p / (287.05 * T)
        return Atmosphere(temperature: T, pressure: p, density: rho, speedOfSound: (1.4 * 287.05 * T).squareRoot())
    }
}
