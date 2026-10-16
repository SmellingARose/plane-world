// OWNED BY ga-es builder (algorithms builder). ------------------------------------------------------------
// Shared GA operators (selection / crossover / mutation) usable by ClassicGA, NEAT flat genes, MAP-Elites,
// novelty search and JS hooks. Pure functions over [Double] + GenomeLayout + inout EvoRNG (deterministic).
import Foundation
import PWCore

public enum SelectionMethod: String, Codable, Sendable { case tournament, roulette, rank }
public enum CrossoverMethod: String, Codable, Sendable { case uniform, onePoint = "one-point", blend, sbx }
public enum MutationMethod: String, Codable, Sendable { case gaussian, polynomial }

public enum Operators {
    /// Fitness value used for ranking: failed / non-finite candidates become the worst.
    @inline(__always) public static func score(_ f: Fitness) -> Double {
        f.total.isFinite ? f.total : EvolutionConstants.failedFitness
    }

    /// Indices sorted best-first (stable: ties keep population order → deterministic).
    public static func rankOrder(_ s: [Double]) -> [Int] {
        s.indices.sorted { s[$0] != s[$1] ? s[$0] > s[$1] : $0 < $1 }
    }

    // MARK: selection

    /// Pick `count` parent indices from scores (higher is better).
    public static func select(_ method: SelectionMethod, scores s: [Double], count: Int, tournamentSize: Int = 3, rng: inout EvoRNG) -> [Int] {
        let n = s.count
        guard n > 0 else { return [] }
        var out: [Int] = []; out.reserveCapacity(count)
        switch method {
        case .tournament:
            let k = max(1, tournamentSize)
            for _ in 0..<count {
                var b = rng.int(below: n)
                for _ in 1..<max(2, k) where k > 1 { let c = rng.int(below: n); if s[c] > s[b] { b = c } }
                out.append(b)
            }
        case .roulette:
            let lo = s.min()!, hi = s.max()!
            let span = max(hi - lo, 1e-12)
            // shift so the worst gets a small positive weight
            let w = s.map { ($0 - lo) / span + 1e-3 }
            out = sampleWeighted(w, count: count, rng: &rng)
        case .rank:
            // linear ranking, selection pressure 1.7
            let order = rankOrder(s), sp = 1.7
            var w = [Double](repeating: 0, count: n)
            for (r, i) in order.enumerated() {
                let pos = n == 1 ? 1.0 : Double(n - 1 - r) / Double(n - 1)
                w[i] = (2 - sp) + 2 * (sp - 1) * pos
            }
            out = sampleWeighted(w, count: count, rng: &rng)
        }
        return out
    }

    /// Stochastic universal sampling-free roulette (independent draws, cumulative search).
    public static func sampleWeighted(_ w: [Double], count: Int, rng: inout EvoRNG) -> [Int] {
        var cum = [Double](repeating: 0, count: w.count), acc = 0.0
        for i in w.indices { acc += max(0, w[i]); cum[i] = acc }
        guard acc > 0 else { return (0..<count).map { _ in rng.int(below: w.count) } }
        return (0..<count).map { _ in
            let r = rng.nextDouble() * acc
            var lo = 0, hi = cum.count - 1
            while lo < hi { let m = (lo + hi) / 2; if cum[m] > r { hi = m } else { lo = m + 1 } }
            return lo
        }
    }

    // MARK: crossover

    public static func crossover(_ method: CrossoverMethod, _ a: [Double], _ b: [Double], layout: GenomeLayout,
                                 blendAlpha: Double = 0.5, sbxEta: Double = 15, rng: inout EvoRNG) -> [Double] {
        let n = min(a.count, b.count)
        var c = Array(a.prefix(n))
        switch method {
        case .uniform:
            for i in 0..<n where rng.nextDouble() < 0.5 { c[i] = b[i] }
        case .onePoint:
            if n > 1 { let p = 1 + rng.int(below: n - 1); for i in p..<n { c[i] = b[i] } }
        case .blend:
            for i in 0..<n {
                let lo = min(a[i], b[i]), hi = max(a[i], b[i]), d = hi - lo
                if layout.genes[i].kind == .bool { c[i] = rng.nextDouble() < 0.5 ? a[i] : b[i]; continue }
                c[i] = rng.uniform(lo - blendAlpha * d, hi + blendAlpha * d)
            }
        case .sbx:
            for i in 0..<n {
                let g = layout.genes[i]
                if g.kind == .bool { c[i] = rng.nextDouble() < 0.5 ? a[i] : b[i]; continue }
                guard rng.nextDouble() < 0.5, abs(a[i] - b[i]) > 1e-14 else { continue }
                let y1 = min(a[i], b[i]), y2 = max(a[i], b[i])
                let lb = g.min, ub = g.max, u = rng.nextDouble()
                // Deb & Agrawal bounded SBX
                let beta = 1 + 2 * min(y1 - lb, ub - y2) / (y2 - y1)
                let alpha = 2 - pow(max(beta, 1e-12), -(sbxEta + 1))
                let bq = u <= 1 / alpha ? pow(u * alpha, 1 / (sbxEta + 1)) : pow(1 / max(1e-12, 2 - u * alpha), 1 / (sbxEta + 1))
                let c1 = 0.5 * ((y1 + y2) - bq * (y2 - y1)), c2 = 0.5 * ((y1 + y2) + bq * (y2 - y1))
                c[i] = rng.nextDouble() < 0.5 ? c1 : c2
            }
        }
        layout.legalize(&c)
        return c
    }

    // MARK: mutation

    /// Mutates each gene with probability `rate`. Bool genes flip; int/real genes get a step.
    public static func mutate(_ method: MutationMethod, _ v: [Double], layout: GenomeLayout, rate: Double,
                              sigmaScale: Double = 1, polyEta: Double = 20, rng: inout EvoRNG) -> [Double] {
        var c = v
        for i in 0..<min(c.count, layout.count) where rng.nextDouble() < rate {
            let g = layout.genes[i]
            switch g.kind {
            case .bool: c[i] = c[i] >= 0.5 ? 0 : 1
            default:
                switch method {
                case .gaussian:
                    var step = rng.gaussian() * g.mutationScale * sigmaScale
                    if g.kind == .int && abs(step) < 0.5 { step = step < 0 ? -1 : 1 }
                    c[i] += step
                case .polynomial:
                    let lb = g.min, ub = g.max, d = ub - lb
                    guard d > 0 else { continue }
                    let y = c[i], d1 = (y - lb) / d, d2 = (ub - y) / d, u = rng.nextDouble(), p = 1 / (polyEta + 1)
                    let dq: Double
                    if u < 0.5 { dq = pow(2 * u + (1 - 2 * u) * pow(1 - d1, polyEta + 1), p) - 1 }
                    else { dq = 1 - pow(2 * (1 - u) + 2 * (u - 0.5) * pow(1 - d2, polyEta + 1), p) }
                    var step = dq * d
                    if g.kind == .int && abs(step) < 0.5 { step = step < 0 ? -1 : 1 }
                    c[i] = y + step
                }
            }
        }
        layout.legalize(&c)
        return c
    }

    /// Isotropic gaussian step on every gene (used by MAP-Elites / novelty / NEAT flat genes).
    public static func gaussianAll(_ v: [Double], layout: GenomeLayout, sigma: Double, rng: inout EvoRNG) -> [Double] {
        mutate(.gaussian, v, layout: layout, rate: 1, sigmaScale: sigma, rng: &rng)
    }

    /// Iso+line variation (Vassiliades & Mouret 2018), scaled per gene by mutationScale.
    public static func isoLine(_ a: [Double], _ b: [Double], layout: GenomeLayout, isoSigma: Double, lineSigma: Double, rng: inout EvoRNG) -> [Double] {
        var c = a
        let line = rng.gaussian() * lineSigma
        for i in 0..<min(c.count, layout.count) {
            let g = layout.genes[i]
            if g.kind == .bool { if rng.nextDouble() < 0.5 / Double(max(1, layout.count)) * 2 { c[i] = c[i] >= 0.5 ? 0 : 1 }; continue }
            c[i] += rng.gaussian() * isoSigma * g.mutationScale + line * (b[i] - a[i])
        }
        layout.legalize(&c)
        return c
    }
}
