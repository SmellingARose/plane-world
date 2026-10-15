// OWNED BY water builder.
// Tessendorf ocean spectrum (CPU side): JONSWAP frequency spectrum (Hasselmann et al. 1973) with
// fetch-limited peak, directional spreading cos^2s(θ/2) (Longuet-Higgins), deep-water dispersion
// quantised to a 1000 s repeat period (keeps float phase precise forever), three band-limited cascades.
// The GPU (OceanGPU) evolves h(k,t) and runs the inverse FFTs; this file also provides an exact
// direct-sum reference used by the self-tests to validate the GPU result.
import Foundation
import simd
import PWCore

public struct OceanSettings: Sendable, Equatable {
    public var windSpeed = 8.0              // U10, m/s
    public var windDirectionDeg = 0.0       // direction the wind blows TOWARD (0 = +z), degrees
    public var fetchKm = 100.0
    public var gamma = 3.3                  // JONSWAP peak enhancement
    public var spreading = 8.0              // s in cos^2s(θ/2)
    public var choppiness = 1.0             // λ, horizontal displacement scale
    public var swell = 0.0                  // 0…1 adds a long-period swell peak at 0.4·ωp
    public var resolution = 256             // N (power of two, ≤ 512)
    public var patchSizes: [Double] = [512, 96, 18]
    public var seed: UInt64 = 1337
    public init() {}
}

/// Repeat period for the quantised dispersion relation (Tessendorf §4.3).
let kOceanRepeatPeriod = 1000.0

struct OceanCascadeSpectrum {
    var L: Double
    var kLow: Double, kHigh: Double
    /// Per texel: h0(k).re, h0(k).im, conj(h0(-k)).re, conj(h0(-k)).im
    var h0: [SIMD4<Float>]
    var omega: [Float]
}

final class OceanSpectrum {
    let settings: OceanSettings
    let N: Int
    var cascades: [OceanCascadeSpectrum] = []
    /// Significant wave height estimate 4·sqrt(Σ variance) (m).
    private(set) var significantWaveHeight = 0.0

    init(settings: OceanSettings) {
        self.settings = settings
        N = settings.resolution
        build()
    }

    // MARK: spectrum model

    static func dispersion(_ k: Double) -> Double {
        let w0 = 2 * Double.pi / kOceanRepeatPeriod
        let w = (kGravity * k).squareRoot()
        return (w / w0).rounded(.down) * w0
    }

    /// JONSWAP S(ω) in m²·s.
    func jonswap(_ w: Double) -> Double {
        let g = kGravity
        let U = max(settings.windSpeed, 0.01), F = max(settings.fetchKm, 0.1) * 1000
        let alpha = 0.076 * pow(U * U / (F * g), 0.22)
        let wp = 22 * pow(g * g / (U * F), 1.0 / 3.0)
        guard w > 1e-4 else { return 0 }
        let sigma = w <= wp ? 0.07 : 0.09
        let r = exp(-(w - wp) * (w - wp) / (2 * sigma * sigma * wp * wp))
        var s = alpha * g * g / pow(w, 5) * exp(-1.25 * pow(wp / w, 4)) * pow(settings.gamma, r)
        if settings.swell > 0 {
            // Long-period swell: narrow peak at 0.4 ωp.
            let ws = wp * 0.4
            s += settings.swell * alpha * g * g / pow(w, 5) * exp(-1.25 * pow(ws / w, 4)) * pow(6.0, exp(-(w - ws) * (w - ws) / (2 * 0.05 * 0.05 * ws * ws)))
        }
        return s
    }

    /// Normalised directional spreading D(θ), ∫D dθ over [-π, π] = 1.
    func spreading(_ theta: Double) -> Double {
        let s = settings.spreading
        let norm = tgamma(s + 1) / (2 * Double.pi.squareRoot() * tgamma(s + 0.5))
        return norm * pow(abs(cos(theta / 2)), 2 * s)
    }

    /// 2D wavenumber spectrum Ψ(k) with ∫Ψ d²k = variance (m⁴ → m² per (rad/m)²).
    func spectrum2D(kx: Double, kz: Double) -> Double {
        let k = (kx * kx + kz * kz).squareRoot()
        guard k > 1e-6 else { return 0 }
        let w = (kGravity * k).squareRoot()
        let dwdk = kGravity / (2 * w)
        let windAngle = settings.windDirectionDeg * kDeg
        // θ measured from the wind direction; wind blows toward (sin a, cos a) in xz.
        let theta = atan2(kx, kz) - windAngle
        // Short-wave suppression (removes aliasing of capillary band, Tessendorf eq. 41).
        let l = 0.002
        return jonswap(w) * dwdk / k * spreading(theta) * exp(-k * k * l * l)
    }

    // MARK: build

    private func build() {
        let Ls = settings.patchSizes
        var rng = PCG32(seed: settings.seed)
        func gauss() -> Double {
            // Box-Muller
            let u1 = max(rng.unit(), 1e-12), u2 = rng.unit()
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
        var variance = 0.0
        cascades = []
        for (ci, L) in Ls.enumerated() {
            // Band limits: each cascade owns [kLow, kHigh) so energy is never counted twice.
            let kLow = ci == 0 ? 0 : kHighOf(ci - 1)
            let kHigh = kHighOf(ci)
            var h0 = [SIMD4<Float>](repeating: .zero, count: N * N)
            var om = [Float](repeating: 0, count: N * N)
            let dk = 2 * Double.pi / L
            var raw = [SIMD2<Double>](repeating: .zero, count: N * N)
            for y in 0..<N { for x in 0..<N {
                let kx = Double(x - N / 2) * dk, kz = Double(y - N / 2) * dk
                let k = (kx * kx + kz * kz).squareRoot()
                let g1 = gauss(), g2 = gauss()       // always draw to keep the stream stable
                guard k >= kLow, k < kHigh, k > 1e-6 else { continue }
                let amp = (spectrum2D(kx: kx, kz: kz) * dk * dk / 2).squareRoot()
                raw[y * N + x] = SIMD2(g1, g2) * (1 / 2.0.squareRoot()) * amp
                variance += amp * amp * 2
                om[y * N + x] = Float(OceanSpectrum.dispersion(k))
            } }
            for y in 0..<N { for x in 0..<N {
                let mx = (N - x) % N, my = (N - y) % N
                let a = raw[y * N + x], b = raw[my * N + mx]
                h0[y * N + x] = SIMD4(Float(a.x), Float(a.y), Float(b.x), Float(-b.y))
            } }
            cascades.append(OceanCascadeSpectrum(L: L, kLow: kLow, kHigh: kHigh, h0: h0, omega: om))
        }
        significantWaveHeight = 4 * variance.squareRoot()
    }

    private func kHighOf(_ ci: Int) -> Double {
        let Ls = settings.patchSizes
        if ci < 0 { return 0 }
        if ci + 1 < Ls.count { return 2 * Double.pi / Ls[ci + 1] * 6 }
        return Double.pi * Double(N) / Ls[ci]   // Nyquist of the finest cascade
    }

    // MARK: exact reference (self-tests)

    /// Direct sum over all modes: returns (Dx, h, Dz) at world point (x, z), time t. Slow (O(cascades·N²)).
    func referenceDisplacement(x: Double, z: Double, time: Double, cascade: Int? = nil) -> Vec3d {
        let t = time.truncatingRemainder(dividingBy: kOceanRepeatPeriod)
        var out = Vec3d.zero
        let lam = settings.choppiness
        for (ci, c) in cascades.enumerated() where cascade == nil || cascade == ci {
            let dk = 2 * Double.pi / c.L
            for y in 0..<N { for xi in 0..<N {
                let i = y * N + xi
                let w = Double(c.omega[i]); let h0 = c.h0[i]
                if h0 == .zero { continue }
                let kx = Double(xi - N / 2) * dk, kz = Double(y - N / 2) * dk
                let k = (kx * kx + kz * kz).squareRoot()
                let cw = cos(w * t), sw = sin(w * t)
                // h = h0 e^{iwt} + conj(h0(-k)) e^{-iwt}
                let hr = Double(h0.x) * cw - Double(h0.y) * sw + Double(h0.z) * cw + Double(h0.w) * sw
                let hi = Double(h0.x) * sw + Double(h0.y) * cw - Double(h0.z) * sw + Double(h0.w) * cw
                let ph = kx * x + kz * z
                let cp = cos(ph), sp = sin(ph)
                // Re(h e^{iφ})
                out.y += hr * cp - hi * sp
                // D = -i k/|k| h → Re(-i (k/|k|) h e^{iφ}) = (k/|k|)·Im(h e^{iφ})
                let im = hr * sp + hi * cp
                out.x += lam * kx / k * im
                out.z += lam * kz / k * im
            } }
        }
        return out
    }
}
