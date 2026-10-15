// OWNED BY collision builder.
// Sequential-impulse solver (Catto) with warm starting, Coulomb friction (2 tangents), restitution,
// Baumgarte stabilisation + speculative contacts, fixed and hinge joints.
import Foundation
import simd
import PWCore

enum Solver {
    typealias Body = RigidWorld.Body
    typealias Manifold = RigidWorld.Manifold
    typealias Joint = RigidWorld.Joint

    @inline(__always) static func perp(_ n: Vec3d) -> Vec3d {
        abs(n.x) > 0.57 ? simd_normalize(Vec3d(n.y, -n.x, 0)) : simd_normalize(Vec3d(0, n.z, -n.y))
    }
    @inline(__always) static func skew(_ r: Vec3d) -> Mat3d { Mat3d(rows: [[0, -r.z, r.y], [r.z, 0, -r.x], [-r.y, r.x, 0]]) }
    @inline(__always) static func safeInverse(_ m: Mat3d) -> Mat3d { abs(m.determinant) > 1e-300 ? m.inverse : Mat3d(0) }

    static func solveIsland(_ B: UnsafeMutablePointer<Body>, _ M: UnsafeMutablePointer<Manifold>?, _ mIdx: [Int],
                            _ J: UnsafeMutablePointer<Joint>?, _ jIdx: [Int], _ iters: Int, _ p: SolverParams) {
        let dt = p.dt, invDt = 1 / dt
        var zeroBody = Body()   // terrain / world anchor
        zeroBody.invMass = 0
        // prepare contacts + warm start
        for mi in mIdx {
            let m = M![mi]
            let a = m.a, b = m.b
            let A = B[a]; let Bb = b >= 0 ? B[b] : zeroBody
            M![mi].pts.withUnsafeMutableBufferPointer { pts in
            for k in 0..<pts.count {
                var c = pts[k]
                c.rA = c.p - A.x; c.rB = b >= 0 ? c.p - Bb.x : .zero
                c.t1 = perp(c.n); c.t2 = simd_cross(c.n, c.t1)
                func eff(_ d: Vec3d) -> Double {
                    let ra = simd_cross(c.rA, d), rb = simd_cross(c.rB, d)
                    let k = A.invMass + Bb.invMass + simd_dot(ra, A.invIWorld * ra) + simd_dot(rb, Bb.invIWorld * rb)
                    return k > 0 ? 1 / k : 0
                }
                c.mN = eff(c.n); c.mT1 = eff(c.t1); c.mT2 = eff(c.t2)
                let rv = (Bb.v + simd_cross(Bb.w, c.rB)) - (A.v + simd_cross(A.w, c.rA))
                let vn = simd_dot(rv, c.n)
                var target: Double
                if c.sep > 0 { target = -c.sep * invDt }
                else { target = min(p.beta * max(-c.sep - p.slop, 0) * invDt, p.maxPush) }
                if vn < -p.restThreshold { target = max(target, -m.e * vn) }
                c.target = target
                pts[k] = c
                let P = c.n * c.jn + c.t1 * c.jt1 + c.t2 * c.jt2
                B[a].v -= P * A.invMass; B[a].w -= A.invIWorld * simd_cross(c.rA, P)
                if b >= 0 && Bb.invMass > 0 { B[b].v += P * Bb.invMass; B[b].w += Bb.invIWorld * simd_cross(c.rB, P) }
            }
            }
        }
        // prepare joints + warm start
        for ji in jIdx {
            var j = J![ji]
            let A = B[j.a], Bb = B[j.b]
            j.rA = A.q.act(j.lA); j.rB = Bb.q.act(j.lB)
            let sa = skew(j.rA), sb = skew(j.rB)
            let K = Mat3d(diagonal: Vec3d(repeating: A.invMass + Bb.invMass)) - sa * A.invIWorld * sa - sb * Bb.invIWorld * sb
            j.kLinInv = safeInverse(K)
            j.kAngInv = safeInverse(A.invIWorld + Bb.invIWorld)
            let P = j.accLin, L = j.accAng
            B[j.a].v -= P * A.invMass; B[j.a].w -= A.invIWorld * (simd_cross(j.rA, P) + L)
            B[j.b].v += P * Bb.invMass; B[j.b].w += Bb.invIWorld * (simd_cross(j.rB, P) + L)
            J![ji] = j
        }

        for _ in 0..<iters {
            // joints
            for ji in jIdx {
                var j = J![ji]
                let a = j.a, b = j.b
                let iA = B[a].invIWorld, iB = B[b].invIWorld, mA = B[a].invMass, mB = B[b].invMass
                // angular
                switch j.kind {
                case .fixed:
                    let qErr = (B[b].q * (B[a].q * j.qRel).inverse).normalized
                    var e = qErr.imag * 2; if qErr.real < 0 { e = -e }
                    let cdot = B[b].w - B[a].w
                    let L = -(j.kAngInv * (cdot + e * (p.beta * invDt)))
                    j.accAng += L
                    B[a].w -= iA * L; B[b].w += iB * L
                case .hinge:
                    let aA = B[a].q.act(j.axisA), aB = B[b].q.act(j.axisB)
                    let p1 = perp(aA), p2 = simd_cross(aA, p1)
                    let err = simd_cross(aA, aB)
                    for pv in [p1, p2] {
                        let k = simd_dot(pv, (iA + iB) * pv); if k <= 0 { continue }
                        let cdot = simd_dot(B[b].w - B[a].w, pv)
                        let lam = -(cdot + simd_dot(err, pv) * p.beta * invDt) / k
                        j.accAng += pv * lam
                        B[a].w -= iA * pv * lam; B[b].w += iB * pv * lam
                    }
                }
                // point
                let rA = B[a].q.act(j.lA), rB = B[b].q.act(j.lB)
                let C = (B[b].x + rB) - (B[a].x + rA)
                let cdot = (B[b].v + simd_cross(B[b].w, rB)) - (B[a].v + simd_cross(B[a].w, rA))
                let P = -(j.kLinInv * (cdot + C * (p.beta * invDt)))
                j.accLin += P
                B[a].v -= P * mA; B[a].w -= iA * simd_cross(rA, P)
                B[b].v += P * mB; B[b].w += iB * simd_cross(rB, P)
                J![ji] = j
            }
            // contacts
            for mi in mIdx {
                let a = M![mi].a, b = M![mi].b, mu = M![mi].mu
                let mA = B[a].invMass, iA = B[a].invIWorld
                let mB = b >= 0 ? B[b].invMass : 0, iB = b >= 0 ? B[b].invIWorld : Mat3d(0)
                var vA = B[a].v, wA = B[a].w
                var vB = b >= 0 ? B[b].v : .zero, wB = b >= 0 ? B[b].w : .zero
                let cnt = M![mi].pts.count
                M![mi].pts.withUnsafeMutableBufferPointer { cp in
                    for k in 0..<cnt {
                        var c = cp[k]
                        // friction first (uses previous normal impulse)
                        let lim = mu * c.jn
                        var rv = (vB + simd_cross(wB, c.rB)) - (vA + simd_cross(wA, c.rA))
                        var d1 = -simd_dot(rv, c.t1) * c.mT1
                        let n1 = clamp(c.jt1 + d1, -lim, lim); d1 = n1 - c.jt1; c.jt1 = n1
                        var d2 = -simd_dot(rv, c.t2) * c.mT2
                        let n2 = clamp(c.jt2 + d2, -lim, lim); d2 = n2 - c.jt2; c.jt2 = n2
                        var P = c.t1 * d1 + c.t2 * d2
                        vA -= P * mA; wA -= iA * simd_cross(c.rA, P)
                        vB += P * mB; wB += iB * simd_cross(c.rB, P)
                        // normal
                        rv = (vB + simd_cross(wB, c.rB)) - (vA + simd_cross(wA, c.rA))
                        let vn = simd_dot(rv, c.n)
                        var dn = (c.target - vn) * c.mN
                        let nn = max(c.jn + dn, 0); dn = nn - c.jn; c.jn = nn
                        P = c.n * dn
                        vA -= P * mA; wA -= iA * simd_cross(c.rA, P)
                        vB += P * mB; wB += iB * simd_cross(c.rB, P)
                        cp[k] = c
                    }
                }
                if M![mi].roll > 0 {
                    var sum = 0.0; for c in M![mi].pts { sum += c.jn }
                    let lim = M![mi].roll * sum
                    let kinv = safeInverse(iA + iB)
                    let old = M![mi].accRoll
                    var acc = old - kinv * (wB - wA)
                    let l = simd_length(acc); if l > lim { acc *= lim / l }
                    let L = acc - old; M![mi].accRoll = acc
                    wA -= iA * L; wB += iB * L
                }
                B[a].v = vA; B[a].w = wA
                if b >= 0 && mB > 0 { B[b].v = vB; B[b].w = wB }
            }
        }
    }
}
