// OWNED BY water builder.
// Buoyancy + hydrodynamic forces on an arbitrary triangle hull.
//  * Each triangle is clipped against the water surface using per-vertex signed heights (y − η(x,z)),
//    giving the exactly wetted polygon for a locally planar surface.
//  * Hydrostatic (Froude–Krylov) pressure p = ρ g depth is linear over each sub-triangle, so the force uses the
//    centroid depth and the moment uses the exact linear×linear triangle integral ∫p·r dA = A/12(Σpᵢrᵢ + ΣpΣr).
//    For a closed hull in calm water the sum equals Archimedes' buoyancy exactly.
//  * Hydrodynamic: pressure drag on faces advancing into the water (½ρC_D A vₙ|vₙ|), weaker suction on receding
//    faces, and ITTC-1957 skin friction on the tangential flow.
//  * Fast entry of a face through the surface emits splash particles.
// Work is split over the JobSystem for large hulls; partial sums are reduced deterministically.
import Foundation
import simd
import PWCore

public struct HydroSettings: Sendable {
    public var pressureDragCoefficient = 1.0
    public var suctionCoefficient = 0.3
    public var kinematicViscosity = 1.19e-6
    public var splashSpeedThreshold = 1.5      // m/s normal entry speed that throws spray
    /// Linear wave-radiation damping (not captured by Froude–Krylov pressure). Per wetted face:
    /// F = −k·ρ·√(g·L)·e^(−depth/(L/2))·A·vₙ·n, k ≈ 0.15 gives ~10–15 % of critical heave damping for barge-like hulls.
    public var radiationDamping = 0.15
    public init() {}
}

struct HydroPartial {
    var force = Vec3d.zero, torque = Vec3d.zero
    var volume = 0.0, wetted = 0.0
    var splashPos = Vec3d.zero, splashVel = Vec3d.zero, splashWeight = 0.0
}

enum Hydrodynamics {
    /// - Parameters:
    ///   - heightAt: water surface height at world x,z (thread-safe).
    ///   - waterVelocity: water velocity at a world point (current + orbital).
    static func compute(hull: HullMesh, state: BodyState, density rho: Double, gravity g: Double,
                        settings: HydroSettings, heightAt: @escaping (Double, Double) -> Double,
                        waterVelocity: Vec3d,
                        jobs: JobSystem = .shared) -> (ForceTorque, volume: Double, wetted: Double, splash: (Vec3d, Vec3d, Double)?) {
        let nv = hull.positions.count, nt = hull.indices.count / 3
        guard nv > 0, nt > 0 else { return (.zero, 0, 0, nil) }
        let tf = state.transform
        // Hull winding: CAD meshes may be inside-out; the signed volume tells us which way normals point.
        let orient = signedVolume(hull) < 0 ? -1.0 : 1.0
        var world = [Vec3d](repeating: .zero, count: nv)
        var dist = [Double](repeating: 0, count: nv)
        var bmin = Vec3d(repeating: .infinity), bmax = Vec3d(repeating: -.infinity)
        // Vertex pass (parallel for large hulls).
        world.withUnsafeMutableBufferPointer { wp in
            dist.withUnsafeMutableBufferPointer { dp in
                let wpp = wp.baseAddress!, dpp = dp.baseAddress!
                let body: (Range<Int>) -> Void = { r in
                    for i in r {
                        let p = tf.apply(hull.positions[i].double)
                        wpp[i] = p
                        dpp[i] = p.y - heightAt(p.x, p.z)
                    }
                }
                if nv >= 1024 { jobs.parallelFor(nv, grain: 256, label: "water.hull.verts", body) } else { body(0..<nv) }
            }
        }
        var anySub = false
        for i in 0..<nv { bmin = simd_min(bmin, world[i]); bmax = simd_max(bmax, world[i]); if dist[i] < 0 { anySub = true } }
        guard anySub else { return (.zero, 0, 0, nil) }
        let lengthRef = max(simd_reduce_max(bmax - bmin), 0.1)
        let com = state.centerOfMass
        let chunks = nt >= 2048 ? min(jobs.threadCount * 4, max(1, nt / 512)) : 1
        var partials = [HydroPartial](repeating: HydroPartial(), count: chunks)
        world.withUnsafeBufferPointer { wb in dist.withUnsafeBufferPointer { db in
            hull.indices.withUnsafeBufferPointer { ib in
                partials.withUnsafeMutableBufferPointer { pb in
                    let W = wb.baseAddress!, D = db.baseAddress!, I = ib.baseAddress!, PB = pb.baseAddress!
                    let per = (nt + chunks - 1) / chunks
                    let body: (Range<Int>) -> Void = { r in
                        for ch in r {
                            var acc = HydroPartial()
                            let t0 = ch * per, t1 = min(nt, t0 + per)
                            if t0 < t1 {
                                for t in t0..<t1 {
                                    let a = Int(I[t * 3]), b = Int(I[t * 3 + 1]), c = Int(I[t * 3 + 2])
                                    if orient > 0 { clipTriangle(W[a], W[b], W[c], D[a], D[b], D[c], rho: rho, g: g, com: com, state: state,
                                                 waterVel: waterVelocity, lengthRef: lengthRef, settings: settings, acc: &acc)
                                    } else { clipTriangle(W[a], W[c], W[b], D[a], D[c], D[b], rho: rho, g: g, com: com, state: state,
                                                 waterVel: waterVelocity, lengthRef: lengthRef, settings: settings, acc: &acc) }
                                }
                            }
                            PB[ch] = acc
                        }
                    }
                    if chunks > 1 { jobs.parallelFor(chunks, grain: 1, label: "water.hull.tris", body) } else { body(0..<1) }
                }
            }
        } }
        var total = HydroPartial()
        for p in partials {
            total.force += p.force; total.torque += p.torque; total.volume += p.volume; total.wetted += p.wetted
            total.splashPos += p.splashPos; total.splashVel += p.splashVel; total.splashWeight += p.splashWeight
        }
        var splash: (Vec3d, Vec3d, Double)? = nil
        if total.splashWeight > 1e-6 {
            splash = (total.splashPos / total.splashWeight, total.splashVel / total.splashWeight, total.splashWeight)
        }
        return (ForceTorque(force: total.force, torque: total.torque), max(total.volume, 0), total.wetted, splash)
    }

    /// Signed enclosed volume (positive for outward-facing CCW winding).
    static func signedVolume(_ hull: HullMesh) -> Double {
        var v = 0.0
        let P = hull.positions, I = hull.indices
        var t = 0
        while t + 2 < I.count {
            let a = P[Int(I[t])].double, b = P[Int(I[t + 1])].double, c = P[Int(I[t + 2])].double
            v += simd_dot(a, simd_cross(b, c)); t += 3
        }
        return v / 6
    }

    @inline(__always)
    static func clipTriangle(_ p0: Vec3d, _ p1: Vec3d, _ p2: Vec3d, _ d0: Double, _ d1: Double, _ d2: Double,
                             rho: Double, g: Double, com: Vec3d, state: BodyState, waterVel: Vec3d, lengthRef: Double,
                             settings: HydroSettings, acc: inout HydroPartial) {
        let s0 = d0 < 0, s1 = d1 < 0, s2 = d2 < 0
        let n = (s0 ? 1 : 0) + (s1 ? 1 : 0) + (s2 ? 1 : 0)
        if n == 0 { return }
        @inline(__always) func cut(_ a: Vec3d, _ b: Vec3d, _ da: Double, _ db: Double) -> Vec3d { a + (b - a) * (da / (da - db)) }
        let partial = n < 3
        if n == 3 {
            subTriangle(p0, p1, p2, -d0, -d1, -d2, rho: rho, g: g, com: com, state: state, waterVel: waterVel, lengthRef: lengthRef,
                        settings: settings, partial: false, acc: &acc)
            return
        }
        // Rotate so the odd-one-out vertex is first while keeping winding.
        var (a, b, c) = (p0, p1, p2), (da, db, dc) = (d0, d1, d2)
        if n == 1 {
            if s1 { (a, b, c) = (p1, p2, p0); (da, db, dc) = (d1, d2, d0) } else if s2 { (a, b, c) = (p2, p0, p1); (da, db, dc) = (d2, d0, d1) }
            // a submerged
            let qab = cut(a, b, da, db), qac = cut(a, c, da, dc)
            subTriangle(a, qab, qac, -da, 0, 0, rho: rho, g: g, com: com, state: state, waterVel: waterVel, lengthRef: lengthRef,
                        settings: settings, partial: partial, acc: &acc)
        } else {
            if !s1 { (a, b, c) = (p1, p2, p0); (da, db, dc) = (d1, d2, d0) } else if !s2 { (a, b, c) = (p2, p0, p1); (da, db, dc) = (d2, d0, d1) }
            // a emerged, b and c submerged
            let qab = cut(a, b, da, db), qca = cut(c, a, dc, da)
            subTriangle(qab, b, c, 0, -db, -dc, rho: rho, g: g, com: com, state: state, waterVel: waterVel, lengthRef: lengthRef,
                        settings: settings, partial: partial, acc: &acc)
            subTriangle(qab, c, qca, 0, -dc, 0, rho: rho, g: g, com: com, state: state, waterVel: waterVel, lengthRef: lengthRef,
                        settings: settings, partial: partial, acc: &acc)
        }
    }

    @inline(__always)
    static func subTriangle(_ a: Vec3d, _ b: Vec3d, _ c: Vec3d, _ ha: Double, _ hb: Double, _ hc: Double,
                            rho: Double, g: Double, com: Vec3d, state: BodyState, waterVel: Vec3d, lengthRef: Double,
                            settings: HydroSettings, partial: Bool, acc: inout HydroPartial) {
        let cr = simd_cross(b - a, c - a)
        let len = simd_length(cr)
        guard len > 1e-14 else { return }
        let area = 0.5 * len
        let nrm = cr / len                          // outward for CCW-outside hulls
        let pa = rho * g * max(ha, 0), pb = rho * g * max(hb, 0), pc = rho * g * max(hc, 0)
        let pMean = (pa + pb + pc) / 3
        // Hydrostatic force and exact moment.
        let F = -pMean * area * nrm
        let ra = a - com, rb = b - com, rc = c - com
        let M = (pa * ra + pb * rb + pc * rc + (pa + pb + pc) * (ra + rb + rc)) * (area / 12)
        acc.force += F
        acc.torque += -simd_cross(M, nrm)
        acc.volume += (ha + hb + hc) / 3 * area * (-nrm.y)
        acc.wetted += area
        // Hydrodynamic forces at the centroid.
        let cen = (a + b + c) / 3
        let v = state.velocity(at: cen) - waterVel
        let vn = simd_dot(v, nrm)
        let cd = vn > 0 ? settings.pressureDragCoefficient : settings.suctionCoefficient
        var Fd = -0.5 * rho * cd * area * vn * abs(vn) * nrm
        let depthC = (ha + hb + hc) / 3
        let radC: Double = settings.radiationDamping * rho * (g * lengthRef).squareRoot() * exp(-depthC / (0.5 * lengthRef))
        Fd -= (radC * area * vn) * nrm
        let vt = v - vn * nrm
        let vtl = simd_length(vt)
        if vtl > 1e-6 {
            let re = max(simd_length(v) * lengthRef / settings.kinematicViscosity, 1e5)
            let l10 = log10(re) - 2
            let cf = 0.075 / (l10 * l10)
            Fd += -0.5 * rho * cf * area * vtl * vt
        }
        acc.force += Fd
        acc.torque += simd_cross(cen - com, Fd)
        if partial && vn > settings.splashSpeedThreshold {
            let w = area * (vn - settings.splashSpeedThreshold)
            acc.splashPos += cen * w
            // Spray leaves sideways and up, roughly mirroring the entry velocity off the surface.
            let up = Vec3d(0, 1, 0)
            let sv = (vt * 0.6 + up * vn * 0.8 + nrm * vn * 0.4)
            acc.splashVel += sv * w
            acc.splashWeight += w
        }
    }
}
