// OWNED BY aero/physics builder.
// Lane math for the batched simulator (CraftSimBatch): K candidates in lockstep, one SIMD lane each.
//
// Every primitive reproduces the scalar code's rounding exactly, lane by lane:
//   * Swift scalar / SIMD arithmetic is never contracted into FMA (no `contract` flag), so plain ops here.
//   * The simd C header functions used by the scalar path (simd_cross, quaternion multiply / act,
//     matrix × vector) ARE compiled with FP_CONTRACT ON by clang, so their fused multiply-adds are
//     reproduced with explicit `vfma` at exactly the same places (see the comment on each primitive).
//   * Swift.min / Swift.max / clamp semantics (operand order matters for ±0 and NaN) are reproduced with
//     selects, never with fmin/fmax.
//   * Transcendentals (sin, atan2, pow, log, …) are NOT vectorised: Apple's vector libm differs from scalar
//     libm in the last ulp on ~30 % of inputs, so they are evaluated per lane with the scalar functions.
// `physics.batch-bitexact` checks every primitive against the scalar simd functions bit for bit.
import Foundation
import simd
import PWCore

/// A SIMD vector of Doubles usable as K batch lanes (SIMD2 / SIMD4 / SIMD8 on NEON: 1 / 2 / 4 registers).
public protocol LaneVec: SIMD where Scalar == Double {
    /// a * b + c with a single rounding.
    static func vfma(_ a: Self, _ b: Self, _ c: Self) -> Self
    static func vabs(_ a: Self) -> Self
    static func vsqrt(_ a: Self) -> Self
}
extension SIMD2: LaneVec where Scalar == Double {
    @inline(__always) public static func vfma(_ a: Self, _ b: Self, _ c: Self) -> Self { c.addingProduct(a, b) }
    @inline(__always) public static func vabs(_ a: Self) -> Self { __tg_fabs(a) }
    @inline(__always) public static func vsqrt(_ a: Self) -> Self { a.squareRoot() }
}
extension SIMD4: LaneVec where Scalar == Double {
    @inline(__always) public static func vfma(_ a: Self, _ b: Self, _ c: Self) -> Self { c.addingProduct(a, b) }
    @inline(__always) public static func vabs(_ a: Self) -> Self { __tg_fabs(a) }
    @inline(__always) public static func vsqrt(_ a: Self) -> Self { a.squareRoot() }
}
extension SIMD8: LaneVec where Scalar == Double {
    @inline(__always) public static func vfma(_ a: Self, _ b: Self, _ c: Self) -> Self { c.addingProduct(a, b) }
    @inline(__always) public static func vabs(_ a: Self) -> Self { __tg_fabs(a) }
    @inline(__always) public static func vsqrt(_ a: Self) -> Self { a.squareRoot() }
}

// MARK: scalar-semantics helpers

/// Swift.min(x, y) = y < x ? y : x
@inline(__always) func vmin<V: LaneVec>(_ x: V, _ y: V) -> V { x.replacing(with: y, where: y .< x) }
/// Swift.max(x, y) = y >= x ? y : x
@inline(__always) func vmax<V: LaneVec>(_ x: V, _ y: V) -> V { x.replacing(with: y, where: y .>= x) }
/// PWCore.clamp(v, a, b) = max(a, min(b, v))
@inline(__always) func vclamp<V: LaneVec>(_ v: V, _ a: V, _ b: V) -> V { vmax(a, vmin(b, v)) }
@inline(__always) func vclamp<V: LaneVec>(_ v: V, _ a: Double, _ b: Double) -> V { vmax(V(repeating: a), vmin(V(repeating: b), v)) }
/// PWCore.smoothstep
@inline(__always) func vsmoothstep<V: LaneVec>(_ e0: Double, _ e1: Double, _ x: V) -> V {
    let t = vclamp((x - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t)
}
/// True IEEE negation (fneg). NOTE: Swift's SIMD prefix `-` is `0 - x` (so -(+0) = +0); that is what the
/// scalar code's `-someVec3d` computes, and what `BV3`'s prefix `-` reproduces. Scalar `-someDouble` and the C
/// headers' `-q.vector` are true negations: use `vneg`.
@inline(__always) func vneg<V: LaneVec>(_ x: V) -> V { x * -1 }
/// cond ? a : b
@inline(__always) func vsel<V: LaneVec>(_ m: SIMDMask<V.MaskStorage>, _ a: V, _ b: V) -> V { b.replacing(with: a, where: m) }
@inline(__always) func vsel<V: LaneVec>(_ m: SIMDMask<V.MaskStorage>, _ a: Double, _ b: Double) -> V { V(repeating: b).replacing(with: a, where: m) }
/// Per-lane scalar function (transcendentals: evaluated with scalar libm, so bit-identical to the scalar path).
@inline(__always) func vmap<V: LaneVec>(_ x: V, _ f: (Double) -> Double) -> V {
    var r = V(); for i in 0..<V.scalarCount { r[i] = f(x[i]) }; return r
}
@inline(__always) func vmap<V: LaneVec>(_ x: V, _ y: V, _ f: (Double, Double) -> Double) -> V {
    var r = V(); for i in 0..<V.scalarCount { r[i] = f(x[i], y[i]) }; return r
}
/// Per-lane scalar function only where `m` is set (other lanes keep `x`) — skips libm calls for idle lanes.
@inline(__always) func vmapMasked<V: LaneVec>(_ m: SIMDMask<V.MaskStorage>, _ x: V, _ f: (Double) -> Double) -> V {
    var r = x; for i in 0..<V.scalarCount where m[i] { r[i] = f(x[i]) }; return r
}
@inline(__always) func anyLane<M>(_ m: SIMDMask<M>) -> Bool { any(m) }

// MARK: 3-vectors

struct BV3<V: LaneVec> {
    var x: V, y: V, z: V
    @inline(__always) init(_ x: V, _ y: V, _ z: V) { self.x = x; self.y = y; self.z = z }
    @inline(__always) init(_ c: Vec3d) { x = V(repeating: c.x); y = V(repeating: c.y); z = V(repeating: c.z) }
    static var zero: BV3 { BV3(V(), V(), V()) }
    @inline(__always) subscript(lane i: Int) -> Vec3d {
        get { Vec3d(x[i], y[i], z[i]) }
        set { x[i] = newValue.x; y[i] = newValue.y; z[i] = newValue.z }
    }
    @inline(__always) static func + (a: BV3, b: BV3) -> BV3 { BV3(a.x + b.x, a.y + b.y, a.z + b.z) }
    @inline(__always) static func - (a: BV3, b: BV3) -> BV3 { BV3(a.x - b.x, a.y - b.y, a.z - b.z) }
    @inline(__always) static prefix func - (a: BV3) -> BV3 { BV3(-a.x, -a.y, -a.z) }
    @inline(__always) static func * (a: BV3, s: V) -> BV3 { BV3(a.x * s, a.y * s, a.z * s) }
    @inline(__always) static func * (a: BV3, s: Double) -> BV3 { BV3(a.x * s, a.y * s, a.z * s) }
    @inline(__always) static func / (a: BV3, s: V) -> BV3 { BV3(a.x / s, a.y / s, a.z / s) }
    @inline(__always) static func += (a: inout BV3, b: BV3) { a = a + b }
    @inline(__always) static func -= (a: inout BV3, b: BV3) { a = a - b }
    /// cond ? a : b per lane
    @inline(__always) static func sel(_ m: SIMDMask<V.MaskStorage>, _ a: BV3, _ b: BV3) -> BV3 {
        BV3(b.x.replacing(with: a.x, where: m), b.y.replacing(with: a.y, where: m), b.z.replacing(with: a.z, where: m))
    }
}

/// simd_dot(double3) = simd_reduce_add(x*y) = (x0*y0 + x1*y1) + x2*y2, no FMA.
@inline(__always) func bdot<V: LaneVec>(_ a: BV3<V>, _ b: BV3<V>) -> V { (a.x * b.x + a.y * b.y) + a.z * b.z }
/// simd_length(double3) = sqrt(simd_length_squared) (same reduction as dot).
@inline(__always) func blength<V: LaneVec>(_ a: BV3<V>) -> V { V.vsqrt(bdot(a, a)) }
@inline(__always) func blength2<V: LaneVec>(_ a: BV3<V>) -> V { bdot(a, a) }
/// simd_normalize(double3) = x * (1 / sqrt(length_squared(x)))  (simd_precise_rsqrt).
@inline(__always) func bnormalize<V: LaneVec>(_ a: BV3<V>) -> BV3<V> { a * (1 / V.vsqrt(bdot(a, a))) }
/// simd_cross(x, y) = (x.zxy*y - x*y.zxy).zxy with FP_CONTRACT: the first product is fused.
@inline(__always) func bcross<V: LaneVec>(_ a: BV3<V>, _ b: BV3<V>) -> BV3<V> {
    BV3(V.vfma(a.y, b.z, vneg(a.z * b.y)),
        V.vfma(a.z, b.x, vneg(a.x * b.z)),
        V.vfma(a.x, b.y, vneg(a.y * b.x)))
}

// MARK: quaternions (simd_quatd semantics, arm64 code paths of <simd/quaternion.h>)

struct BQ<V: LaneVec> {
    var x: V, y: V, z: V, w: V   // vector = (ix, iy, iz, r)
    @inline(__always) init(_ x: V, _ y: V, _ z: V, _ w: V) { self.x = x; self.y = y; self.z = z; self.w = w }
    @inline(__always) init(_ q: Quatd) { let v = q.vector; x = V(repeating: v.x); y = V(repeating: v.y); z = V(repeating: v.z); w = V(repeating: v.w) }
    static var identity: BQ { BQ(V(), V(), V(), V(repeating: 1)) }
    @inline(__always) subscript(lane i: Int) -> Quatd {
        get { Quatd(vector: simd_double4(x[i], y[i], z[i], w[i])) }
        set { let v = newValue.vector; x[i] = v.x; y[i] = v.y; z[i] = v.z; w[i] = v.w }
    }
    @inline(__always) static func sel(_ m: SIMDMask<V.MaskStorage>, _ a: BQ, _ b: BQ) -> BQ {
        BQ(b.x.replacing(with: a.x, where: m), b.y.replacing(with: a.y, where: m), b.z.replacing(with: a.z, where: m), b.w.replacing(with: a.w, where: m))
    }
}

/// simd_mul(p, q) = (p.x*shuf(q,-q,3,6,1,4) + p.y*shuf(q,-q,2,3,4,5)) + (p.z*shuf(q,-q,5,0,3,6) + p.w*q)
/// (in each parenthesised pair the left product is fused into the right one).
///   shuf(q,-q,3,6,1,4) = ( w, -z,  y, -x);  shuf(q,-q,2,3,4,5) = ( z,  w, -x, -y);  shuf(q,-q,5,0,3,6) = (-y,  x,  w, -z)
@inline(__always) func bqmul<V: LaneVec>(_ p: BQ<V>, _ q: BQ<V>) -> BQ<V> {
    let nx = vneg(q.x), ny = vneg(q.y), nz = vneg(q.z)
    let rx = V.vfma(p.x, q.w, p.y * q.z) + V.vfma(p.z, ny, p.w * q.x)
    let ry = V.vfma(p.x, nz, p.y * q.w) + V.vfma(p.z, q.x, p.w * q.y)
    let rz = V.vfma(p.x, q.y, p.y * nx) + V.vfma(p.z, q.w, p.w * q.z)
    let rw = V.vfma(p.x, nx, p.y * ny) + V.vfma(p.z, nz, p.w * q.w)
    return BQ(rx, ry, rz, rw)
}
/// simd_act(q, v) on arm64 = simd_mul(q, _simd_mul_vq(v, simd_conjugate(q))).vector.xyz, where
/// simd_conjugate(q) = q.vector * (-1,-1,-1,1) and
/// _simd_mul_vq(v, c) = v.x*shuf(c,-c,3,6,1,4) + v.y*shuf(c,-c,2,3,4,5) + v.z*shuf(c,-c,5,0,3,6) = fma(v.z, C, fma(v.x, A, v.y*B)).
@inline(__always) func bact<V: LaneVec>(_ q: BQ<V>, _ v: BV3<V>) -> BV3<V> {
    let cx = vneg(q.x), cy = vneg(q.y), cz = vneg(q.z), cw = q.w
    let ncx = vneg(cx), ncy = vneg(cy), ncz = vneg(cz)
    let tx = V.vfma(v.z, ncy, V.vfma(v.x, cw, v.y * cz))
    let ty = V.vfma(v.z, cx, V.vfma(v.x, ncz, v.y * cw))
    let tz = V.vfma(v.z, cw, V.vfma(v.x, cy, v.y * ncx))
    let tw = V.vfma(v.z, ncz, V.vfma(v.x, ncx, v.y * ncy))
    let r = bqmul(q, BQ(tx, ty, tz, tw))
    return BV3(r.x, r.y, r.z)
}
/// simd_length_squared(double4) = reduce_add(lo + hi) = (x²+z²) + (y²+w²).
@inline(__always) func bqlen2<V: LaneVec>(_ q: BQ<V>) -> V {
    let xx = q.x * q.x, yy = q.y * q.y, zz = q.z * q.z, ww = q.w * q.w
    return (xx + zz) + (yy + ww)
}
/// simd_normalize(quatd): length² == 0 → identity, else vector * (1/sqrt(length²)).
@inline(__always) func bqnormalize<V: LaneVec>(_ q: BQ<V>) -> BQ<V> {
    let l2 = bqlen2(q)
    let s = 1 / V.vsqrt(l2)
    let n = BQ(q.x * s, q.y * s, q.z * s, q.w * s)
    let zero = l2 .== 0
    if !any(zero) { return n }
    return BQ.sel(zero, BQ.identity, n)
}
/// simd_inverse(quatd) = conjugate.vector * (1 / length²).
@inline(__always) func bqinverse<V: LaneVec>(_ q: BQ<V>) -> BQ<V> {
    let s = 1 / bqlen2(q)
    return BQ(vneg(q.x) * s, vneg(q.y) * s, vneg(q.z) * s, q.w * s)
}

// MARK: 3×3 matrices (column major, simd_double3x3 semantics)

struct BM3<V: LaneVec> {
    var c0: BV3<V>, c1: BV3<V>, c2: BV3<V>
    @inline(__always) subscript(lane i: Int) -> Mat3d {
        get { Mat3d(columns: (c0[lane: i], c1[lane: i], c2[lane: i])) }
        set { c0[lane: i] = newValue.columns.0; c1[lane: i] = newValue.columns.1; c2[lane: i] = newValue.columns.2 }
    }
    static var zero: BM3 { BM3(c0: .zero, c1: .zero, c2: .zero) }
}
/// simd_mul(m, v) = fma(c2, v.z, fma(c1, v.y, c0 * v.x)).
@inline(__always) func bmul<V: LaneVec>(_ m: BM3<V>, _ v: BV3<V>) -> BV3<V> {
    BV3(V.vfma(m.c2.x, v.z, V.vfma(m.c1.x, v.y, m.c0.x * v.x)),
        V.vfma(m.c2.y, v.z, V.vfma(m.c1.y, v.y, m.c0.y * v.x)),
        V.vfma(m.c2.z, v.z, V.vfma(m.c1.z, v.y, m.c0.z * v.x)))
}
/// simd_mul(transpose(m), v): the transposed matrix's columns are m's rows.
@inline(__always) func bmulT<V: LaneVec>(_ m: BM3<V>, _ v: BV3<V>) -> BV3<V> {
    BV3(V.vfma(m.c0.z, v.z, V.vfma(m.c0.y, v.y, m.c0.x * v.x)),
        V.vfma(m.c1.z, v.z, V.vfma(m.c1.y, v.y, m.c1.x * v.x)),
        V.vfma(m.c2.z, v.z, V.vfma(m.c2.y, v.y, m.c2.x * v.x)))
}
/// simd_matrix3x3(quatd) via simd_matrix4x4 with FP_CONTRACT ON:
///   a*b - c*d → fma(a, b, -(c*d));  s - c*d → fma(-c, d, s);  s + c*d → fma(c, d, s);  2*(a*b ± c*d) → 2*fma(a, b, ±(c*d)).
@inline(__always) func bmat<V: LaneVec>(_ q: BQ<V>) -> BM3<V> {
    let x = q.x, y = q.y, z = q.z, w = q.w
    let nx = vneg(x), ny = vneg(y), nz = vneg(z)
    let c00 = V.vfma(w, w, V.vfma(nz, z, V.vfma(x, x, vneg(y * y))))
    let c01 = 2 * V.vfma(x, y, z * w)
    let c02 = 2 * V.vfma(x, z, vneg(y * w))
    let c10 = 2 * V.vfma(x, y, vneg(z * w))
    let c11 = V.vfma(nx, x, V.vfma(w, w, V.vfma(y, y, vneg(z * z))))
    let c12 = 2 * V.vfma(y, z, x * w)
    let c20 = 2 * V.vfma(z, x, y * w)
    let c21 = 2 * V.vfma(y, z, vneg(x * w))
    let c22 = V.vfma(ny, y, V.vfma(nx, x, V.vfma(z, z, w * w)))
    return BM3(c0: BV3(c00, c01, c02), c1: BV3(c10, c11, c12), c2: BV3(c20, c21, c22))
}
