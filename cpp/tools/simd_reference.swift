// Generates cpp/tests/parity/simd.json: Apple simd (as the Swift app calls it) results for random inputs, written
// as exact bit patterns. The C++ port's pw/math.h must reproduce every value bit-for-bit (incl. the FMAs Apple's
// headers contract on arm64), so CraftSim trajectories can match the Swift app.
//   swiftc -O cpp/tools/simd_reference.swift -o /tmp/simdref && /tmp/simdref > cpp/tests/parity/simd.json
import simd
import Foundation

var state: UInt64 = 0x853c49e6748fea9b
func rnd() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 11) / Double(1 << 53) * 2 - 1 }
func v3() -> SIMD3<Double> { SIMD3(rnd() * 10, rnd() * 10, rnd() * 10) }
func uq() -> simd_quatd { simd_normalize(simd_quatd(vector: SIMD4(rnd(), rnd(), rnd(), rnd()))) }
func h(_ d: Double) -> String { "\"" + String(d.bitPattern, radix: 16) + "\"" }
func hv(_ v: SIMD3<Double>) -> String { "[\(h(v.x)),\(h(v.y)),\(h(v.z))]" }
func hq(_ q: simd_quatd) -> String { "[\(h(q.vector.x)),\(h(q.vector.y)),\(h(q.vector.z)),\(h(q.vector.w))]" }
func hm(_ m: simd_double3x3) -> String { "[\(hv(m.columns.0)),\(hv(m.columns.1)),\(hv(m.columns.2))]" }
func sym() -> simd_double3x3 {
    let a = v3(), b = v3(), c = v3()
    let m = simd_double3x3(columns: (a, b, c))
    return m * m.transpose + simd_double3x3(diagonal: SIMD3(repeating: 5))
}

var rows: [String] = []
for _ in 0..<200 {
    let a = v3(), b = v3(), q = uq(), p = uq(), ang = rnd() * 4, s = rnd() * 3
    let ax = simd_normalize(v3())
    let e = SIMD3(rnd() * 180, rnd() * 180, rnd() * 180); let kDeg = Double.pi / 180
    let qe = simd_quatd(angle: e.x * kDeg, axis: [1, 0, 0]) * simd_quatd(angle: e.y * kDeg, axis: [0, 1, 0]) * simd_quatd(angle: e.z * kDeg, axis: [0, 0, 1])
    let M = sym(), N = simd_double3x3(columns: (v3(), v3(), v3()))
    let R = simd_double3x3(q)
    var r = "{"
    r += "\"a\":\(hv(a)),\"b\":\(hv(b)),\"q\":\(hq(q)),\"p\":\(hq(p)),\"ang\":\(h(ang)),\"s\":\(h(s)),\"ax\":\(hv(ax)),\"e\":\(hv(e)),"
    r += "\"M\":\(hm(M)),\"N\":\(hm(N)),"
    r += "\"dot\":\(h(simd_dot(a, b))),\"len\":\(h(simd_length(a))),\"len2\":\(h(simd_length_squared(a))),"
    r += "\"norm\":\(hv(simd_normalize(a))),\"cross\":\(hv(simd_cross(a, b))),"
    r += "\"qmul\":\(hq(q * p)),\"act\":\(hv(q.act(a))),\"inv\":\(hq(q.inverse)),\"invact\":\(hv(q.inverse.act(a))),"
    r += "\"qnorm\":\(hq(simd_quatd(vector: q.vector * 1.37).normalized)),\"aa\":\(hq(simd_quatd(angle: ang, axis: ax))),\"euler\":\(hq(qe)),"
    r += "\"mq\":\(hm(R)),\"mv\":\(hv(M * a)),\"mm\":\(hm(M * N)),\"mt\":\(hm(N.transpose)),\"madd\":\(hm(M + N)),\"msub\":\(hm(M - N)),"
    r += "\"ms\":\(hm(N * s)),\"minv\":\(hm(M.inverse)),\"rir\":\(hm(R * M * R.transpose))"
    r += "}"
    rows.append(r)
}
print("{\"schema\":\"planeworld.parity.simd/1\",\"rows\":[\n" + rows.joined(separator: ",\n") + "\n]}")
