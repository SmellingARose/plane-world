// OWNED BY aero/physics builder.
// Aerodynamic models: per-surface wing coefficients (finite-AR lift slope with Prandtl-Glauert
// compressibility, Reynolds-dependent stall, stall blend to flat plate, induced drag with ground
// effect, wave-drag rise), plain trailing-edge flaps, and atmosphere helpers.
import Foundation
import simd
import PWCore

/// `kDeg` (= Double.pi / 180, same bits) as a folded constant: avoids the cross-module global's lazy-init
/// addressor in hot loops.
@inline(__always) var kDegF: Double { Double(bitPattern: 0x3f91df46a2529d39) }

public enum Aero {
    /// Dynamic viscosity of air (Sutherland), Pa·s.
    @inlinable public static func viscosity(temperature T: Double) -> Double { 1.458e-6 * pow(T, 1.5) / (T + 110.4) }

    public struct WingParams: Sendable {
        public var aspectRatio: Double
        public var camberCl0: Double     // prototype "camber" = zero-AoA lift coefficient
        public var thicknessRatio: Double
        public var flapChordFraction: Double  // 0 = no flap
        public init(aspectRatio: Double, camberCl0: Double, thicknessRatio: Double, flapChordFraction: Double = 0) {
            self.aspectRatio = max(0.2, aspectRatio); self.camberCl0 = camberCl0; self.thicknessRatio = thicknessRatio; self.flapChordFraction = flapChordFraction
        }
    }

    public struct WingCoefficients: Sendable { public var cl: Double, cd: Double, stalled: Bool, centerOfPressure: Double /* fraction of chord from LE */, hingeCh: Double }

    /// Lift curve slope per radian (Helmbold/DATCOM, includes Prandtl-Glauert, valid M < 0.8).
    @inlinable public static func liftSlope(aspectRatio A: Double, mach: Double) -> Double {
        let M = min(mach, 0.8), beta2 = 1 - M * M, kappa = 0.95
        return 2 * Double.pi * A / (2 + (A * A * beta2 / (kappa * kappa) + 4).squareRoot())
    }

    /// Stall angle (rad) vs Reynolds number: ~11° at Re 1e5 rising to ~16° at Re 1e7, thinner sections stall earlier.
    @inlinable public static func stallAngle(reynolds: Double, thickness t: Double) -> Double {
        let lr = log10(max(reynolds, 1e3))
        let base = 11 + 5 * smoothstep(5, 7, lr)
        let thick = clamp((t - 0.04) / 0.08, 0, 1)   // < 4% sections lose ~3°
        return (base - 3 * (1 - thick)) * kDeg
    }

    /// Coefficients at angle of attack `a` (rad), flap deflection `delta` (rad).
    public static func wing(alpha a: Double, mach: Double, reynolds: Double, params p: WingParams, flapDeflection delta: Double,
                            groundEffectInduced phi: Double = 1, groundLiftGain: Double = 1) -> WingCoefficients {
        let M = min(mach, 0.8), beta = (1 - M * M).squareRoot()
        let slope = liftSlope(aspectRatio: p.aspectRatio, mach: mach) * groundLiftGain
        var cl0 = p.camberCl0 / beta
        var ch = 0.0, dcdFlap = 0.0
        if p.flapChordFraction > 0 && delta != 0 {
            let cf = clamp(p.flapChordFraction, 0.05, 0.6)
            let th = acos(2 * cf - 1)
            let tau = 1 - (th - sin(th)) / Double.pi
            let eff = 0.75 - 0.25 * smoothstep(15 * kDeg, 40 * kDeg, abs(delta))   // viscous loss at large deflection
            cl0 += slope * tau * eff * delta
            dcdFlap = 0.9 * cf * pow(abs(sin(delta)), 1.5)
            ch = -0.55 * delta - 0.2 * a
        }
        let stall = stallAngle(reynolds: reynolds, thickness: p.thicknessRatio)
        // effective AoA measured from zero-lift line so flaps/camber stall earlier in alpha
        let aZL = a + cl0 / slope
        let flat = 1.05 * sin(2 * a)
        var cl: Double, stalled = false
        let ex = abs(aZL) - stall
        if ex <= 0 { cl = slope * aZL }
        else {
            stalled = true
            let t = clamp(ex / (12 * kDeg), 0, 1)
            let peak = slope * stall * (aZL >= 0 ? 1 : -1)
            cl = peak * (1 - t) + flat * t
        }
        // skin friction (turbulent flat plate, both sides) with thickness form factor
        let cf = 0.455 / pow(log10(max(reynolds, 1e4)), 2.58)
        let cd0 = 2 * cf * (1 + 2 * p.thicknessRatio + 60 * pow(p.thicknessRatio, 4))
        let e = 0.8
        var cd = cd0 + phi * cl * cl / (Double.pi * p.aspectRatio * e) + 0.02 * pow(sin(a), 2) + dcdFlap
        if stalled { cd += 1.2 * pow(sin(a), 2) * smoothstep(0, 6 * kDeg, ex) }
        // Korn/Lock wave drag rise
        let mcritEff = max(0.55, 0.87 - p.thicknessRatio - 0.1 * abs(cl) - 0.108)
        if mach > mcritEff { cd += 20 * pow(mach - mcritEff, 4) }
        let cp = stalled ? 0.25 + 0.2 * smoothstep(0, 12 * kDeg, ex) : 0.25
        return WingCoefficients(cl: cl, cd: cd, stalled: stalled, centerOfPressure: cp, hingeCh: ch)
    }

    /// Per-surface constants of `wing(...)` precomputed once (bit-identical: same expressions, same order).
    public struct WingConst: Sendable {
        public var params: WingParams
        var liftNum = 0.0, AA = 0.0, stallThick = 0.0, thickFactor = 0.0, inducedDen = 0.0, mcritBase = 0.0
        var flapCf = 0.0, flapTau = 0.0, flapCd = 0.0
        public static let zero = WingConst(WingParams(aspectRatio: 1, camberCl0: 0, thicknessRatio: 0))
        public init(_ p: WingParams) {
            params = p
            let A = p.aspectRatio
            liftNum = 2 * Double.pi * A; AA = A * A
            let thick = clamp((p.thicknessRatio - 0.04) / 0.08, 0, 1)
            stallThick = 3 * (1 - thick)
            thickFactor = 1 + 2 * p.thicknessRatio + 60 * pow(p.thicknessRatio, 4)
            let e = 0.8
            inducedDen = Double.pi * p.aspectRatio * e
            mcritBase = 0.87 - p.thicknessRatio
            if p.flapChordFraction > 0 {
                let cf = clamp(p.flapChordFraction, 0.05, 0.6)
                let th = acos(2 * cf - 1)
                flapCf = cf; flapTau = 1 - (th - sin(th)) / Double.pi; flapCd = 0.9 * cf
            }
        }
    }

    /// `wing(...)` with per-surface constants hoisted (hot path of CraftSim). Bit-identical to `wing`.
    @inline(__always) public static func wing(alpha a: Double, mach: Double, reynolds: Double, const k: WingConst, flapDeflection delta: Double,
                                              groundEffectInduced phi: Double = 1, groundLiftGain: Double = 1) -> WingCoefficients {
        let p = k.params
        let M = min(mach, 0.8), beta2 = 1 - M * M, beta = beta2.squareRoot()
        let slope = k.liftNum / (2 + (k.AA * beta2 / (0.95 * 0.95) + 4).squareRoot()) * groundLiftGain
        var cl0 = p.camberCl0 / beta
        var ch = 0.0, dcdFlap = 0.0
        if p.flapChordFraction > 0 && delta != 0 {
            let eff = 0.75 - 0.25 * smoothstep(15 * kDegF, 40 * kDegF, abs(delta))
            cl0 += slope * k.flapTau * eff * delta
            dcdFlap = k.flapCd * pow(abs(sin(delta)), 1.5)
            ch = -0.55 * delta - 0.2 * a
        }
        let lr = log10(max(reynolds, 1e3))
        let stall = (11 + 5 * smoothstep(5, 7, lr) - k.stallThick) * kDegF
        let aZL = a + cl0 / slope
        let flat = 1.05 * sin(2 * a)
        var cl: Double, stalled = false
        let ex = abs(aZL) - stall
        if ex <= 0 { cl = slope * aZL }
        else {
            stalled = true
            let t = clamp(ex / (12 * kDegF), 0, 1)
            let peak = slope * stall * (aZL >= 0 ? 1 : -1)
            cl = peak * (1 - t) + flat * t
        }
        let lr4 = reynolds >= 1e4 ? lr : log10(max(reynolds, 1e4))
        let cf = 0.455 / pow(lr4, 2.58)
        let cd0 = 2 * cf * k.thickFactor
        let sa = sin(a), sa2 = pow(sa, 2)
        var cd = cd0 + phi * cl * cl / k.inducedDen + 0.02 * sa2 + dcdFlap
        if stalled { cd += 1.2 * sa2 * smoothstep(0, 6 * kDegF, ex) }
        let mcritEff = max(0.55, k.mcritBase - 0.1 * abs(cl) - 0.108)
        if mach > mcritEff { cd += 20 * pow(mach - mcritEff, 4) }
        let cp = stalled ? 0.25 + 0.2 * smoothstep(0, 12 * kDegF, ex) : 0.25
        return WingCoefficients(cl: cl, cd: cd, stalled: stalled, centerOfPressure: cp, hingeCh: ch)
    }

    /// Ground effect (McCormick): induced-drag factor φ and a lift-slope gain, h = height of AC above ground, b = span.
    @inlinable public static func groundEffect(height h: Double, span b: Double) -> (phi: Double, liftGain: Double) {
        guard h > 0, b > 0 else { return (1, 1) }
        let x = 16 * h / b, x2 = x * x
        let phi = x2 / (1 + x2)
        return (phi, 1 + 0.15 * (1 - phi))
    }
}

/// Wind field: mean wind with a log boundary-layer profile plus frozen, advected multi-octave turbulence
/// (deterministic, thread-safe value type).
public struct WindField: Sendable {
    public var mean: Vec3d = .zero
    /// 0 = calm, 1 = moderate, 2 = severe.
    public var turbulence: Double = 0
    public var roughnessLength: Double = 0.03
    public init(mean: Vec3d = .zero, turbulence: Double = 0) { self.mean = mean; self.turbulence = turbulence }

    @inlinable public func velocity(at p: Vec3d, heightAGL h: Double, time t: Double) -> Vec3d {
        let z0 = roughnessLength, zc = clamp(h, 0.2, 500)
        let profile = clamp(log(zc / z0) / log(10 / z0), 0, 1.6)
        var w = mean * profile
        if turbulence > 0 {
            let sigma = turbulence * (0.6 + 0.12 * simd_length(mean)) * (0.5 + 0.5 * min(1, zc / 50))
            let q = p - mean * t   // frozen turbulence advected by mean wind
            var acc = Vec3d.zero, amp = 1.0, k = 0.012
            for o in 0..<4 {
                let fo = Double(o)
                acc.x += amp * sin(k * q.x * 1.3 + k * q.z * 0.7 + 1.7 * fo + 0.9 * t * (1 + fo))
                acc.y += amp * 0.6 * sin(k * q.y * 1.1 - k * q.x * 0.8 + 2.3 * fo + 1.3 * t)
                acc.z += amp * sin(k * q.z * 1.2 - k * q.y * 0.5 + 0.5 * fo + 1.1 * t * (1 + 0.5 * fo))
                amp *= 0.55; k *= 2.1
            }
            w += acc * sigma
        }
        return w
    }
}

extension WindField {
    /// `velocity(at:heightAGL:time:)` with everything that depends only on the field and the time hoisted
    /// (built once per substep, evaluated per strip). Bit-identical to `velocity`: same operations, same order.
    struct Prepared {
        let mean: Vec3d, turbulence: Double, z0: Double, lnRef: Double, sigmaBase: Double, shift: Vec3d
        var amp = simd_double4(), amp6 = simd_double4(), k = simd_double4()
        var ax = simd_double4(), bx = simd_double4(), ay = simd_double4(), by = 0.0, az = simd_double4(), bz = simd_double4()
        init(_ w: WindField, time t: Double) {
            mean = w.mean; turbulence = w.turbulence; z0 = w.roughnessLength; lnRef = log(10 / z0)
            sigmaBase = w.turbulence * (0.6 + 0.12 * simd_length(w.mean))
            shift = w.mean * t
            var a = 1.0, kk = 0.012
            for o in 0..<4 {
                let fo = Double(o)
                amp[o] = a; amp6[o] = a * 0.6; k[o] = kk
                ax[o] = 1.7 * fo; bx[o] = 0.9 * t * (1 + fo)
                ay[o] = 2.3 * fo; az[o] = 0.5 * fo; bz[o] = 1.1 * t * (1 + 0.5 * fo)
                a *= 0.55; kk *= 2.1
            }
            by = 1.3 * t
        }
        @inline(__always) func velocity(at p: Vec3d, heightAGL h: Double) -> Vec3d {
            let zc = clamp(h, 0.2, 500)
            let profile = clamp(log(zc / z0) / lnRef, 0, 1.6)
            var w = mean * profile
            if turbulence > 0 {
                let sigma = sigmaBase * (0.5 + 0.5 * min(1, zc / 50))
                let q = p - shift
                var acc = Vec3d.zero
                for o in 0..<4 {
                    let kk = k[o]
                    acc.x += amp[o] * sin(kk * q.x * 1.3 + kk * q.z * 0.7 + ax[o] + bx[o])
                    acc.y += amp6[o] * sin(kk * q.y * 1.1 - kk * q.x * 0.8 + ay[o] + by)
                    acc.z += amp[o] * sin(kk * q.z * 1.2 - kk * q.y * 0.5 + az[o] + bz[o])
                }
                w += acc * sigma
            }
            return w
        }
    }
}
