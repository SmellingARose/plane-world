// OWNED BY ga-es builder (algorithms builder). ------------------------------------------------------------
// ES family.
//  * "cmaes"     — full-covariance CMA-ES (Hansen 2016 tutorial defaults): weighted recombination, cumulative
//                  step-size adaptation (CSA), rank-one + rank-μ covariance update, lazy eigendecomposition
//                  (Jacobi), restarts "none" | "ipop" | "bipop".
//  * "sep-cmaes" — the same with a diagonal covariance (Ros & Hansen 2008 learning rates); O(n) per sample.
//  * "openai-es" — Salimans et al. 2017: antithetic sampling, centered-rank fitness shaping, Adam/SGD, L2 decay.
// All search happens in a normalised space u_i = x_i / GeneSpec.mutationScale, so `sigma0` / `sigma` are in
// units of each gene's mutation scale. Every candidate is legalised; updates use the legalised (evaluated)
// vectors, so hooks, clamping and int/bool rounding are reflected in the learned distribution.
// Params: sigma0 (1), lambda (population), mu (lambda/2), restarts ("none"), tolX (1e-12), tolFun (1e-12);
// OpenAI-ES: lr (0.05), sigma (0.5), antithetic (true), weightDecay (0), optimizer "adam"|"sgd",
// fitnessShaping "rank"|"none". The mutate hook (if defined) post-processes each sample.
import Foundation
import PWCore

// MARK: - CMA engine (shared by full + separable)

struct CMAEngine: Codable {
    var n: Int
    var diagonal: Bool
    var restarts: String
    var sigma0: Double, tolX: Double, tolFun: Double
    var lambdaDefault: Int, muParam: Int?
    // per-run (reset on restart)
    var lambda: Int
    var mean: [Double]
    var sigma: Double
    var pc: [Double], ps: [Double]
    var C: [Double]          // n*n (full) or n (diag)
    var B: [Double]          // n*n (full) or empty
    var D: [Double]          // sqrt eigenvalues (full) / sqrt(C) (diag)
    var eigenEval = 0
    var countEval = 0
    var runGeneration = 0
    var bestHistory: [Double] = []
    // restart bookkeeping
    var restartCount = 0
    var largeRuns = 0
    var largeBudget = 0, smallBudget = 0
    var currentIsLarge = true
    var lastTermination = ""

    struct Consts { var mu: Int; var w: [Double]; var mueff, cc, cs, c1, cmu, damps, chiN: Double }

    func consts() -> Consts {
        let N = Double(n)
        let mu = max(1, min(lambda, muParam ?? lambda / 2))
        var w = (0..<mu).map { log(Double(mu) + 0.5) - log(Double($0) + 1) }
        let ws = w.reduce(0, +); w = w.map { $0 / ws }
        let mueff = 1 / w.reduce(0) { $0 + $1 * $1 }
        let cc = (4 + mueff / N) / (N + 4 + 2 * mueff / N)
        let cs = (mueff + 2) / (N + mueff + 5)
        var c1 = 2 / ((N + 1.3) * (N + 1.3) + mueff)
        var cmu = min(1 - c1, 2 * (mueff - 2 + 1 / mueff) / ((N + 2) * (N + 2) + mueff))
        if diagonal { let f = (N + 2) / 3; c1 = min(1, c1 * f); cmu = min(1 - c1, cmu * f) }
        let damps = 1 + 2 * max(0, ((mueff - 1) / (N + 1)).squareRoot() - 1) + cs
        let chiN = N.squareRoot() * (1 - 1 / (4 * N) + 1 / (21 * N * N))
        return Consts(mu: mu, w: w, mueff: mueff, cc: cc, cs: cs, c1: c1, cmu: cmu, damps: damps, chiN: chiN)
    }

    init(n: Int, diagonal: Bool, params: AlgorithmParams, population: Int, mean: [Double]) throws {
        self.n = n; self.diagonal = diagonal
        restarts = params.string("restarts", "none")
        guard ["none", "ipop", "bipop"].contains(restarts) else { throw EvolutionError.invalidExperiment("cmaes: restarts must be none|ipop|bipop (got '\(restarts)')") }
        sigma0 = params.double("sigma0", 1)
        guard sigma0 > 0 else { throw EvolutionError.invalidExperiment("cmaes: sigma0 must be > 0") }
        tolX = params.double("tolX", 1e-12); tolFun = params.double("tolFun", 1e-12)
        lambdaDefault = max(4, params.int("lambda", population > 1 ? population : 4 + Int(3 * log(Double(n)))))
        muParam = params.values["mu"] != nil ? max(1, params.int("mu", 1)) : nil
        lambda = lambdaDefault
        self.mean = mean; sigma = sigma0
        pc = []; ps = []; C = []; B = []; D = []
        resetDistribution(mean: mean, sigma: sigma0)
    }

    mutating func resetDistribution(mean m: [Double], sigma s: Double) {
        mean = m; sigma = s
        pc = [Double](repeating: 0, count: n); ps = pc
        D = [Double](repeating: 1, count: n)
        if diagonal { C = D; B = [] }
        else {
            C = [Double](repeating: 0, count: n * n); B = C
            for i in 0..<n { C[i * n + i] = 1; B[i * n + i] = 1 }
        }
        eigenEval = countEval; runGeneration = 0; bestHistory = []
    }

    /// y = B D z
    func transform(_ z: [Double]) -> [Double] {
        if diagonal { return (0..<n).map { D[$0] * z[$0] } }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n { var a = 0.0; for j in 0..<n { a += B[i * n + j] * D[j] * z[j] }; y[i] = a }
        return y
    }

    /// C^{-1/2} y
    func invSqrt(_ y: [Double]) -> [Double] {
        if diagonal { return (0..<n).map { y[$0] / D[$0] } }
        var t = [Double](repeating: 0, count: n)
        for j in 0..<n { var a = 0.0; for i in 0..<n { a += B[i * n + j] * y[i] }; t[j] = a / D[j] }
        var r = [Double](repeating: 0, count: n)
        for i in 0..<n { var a = 0.0; for j in 0..<n { a += B[i * n + j] * t[j] }; r[i] = a }
        return r
    }

    func sample(_ rng: inout EvoRNG) -> [Double] {
        let z = (0..<n).map { _ in rng.gaussian() }
        let y = transform(z)
        return (0..<n).map { mean[$0] + sigma * y[$0] }
    }

    /// `xs` normalised candidates, `scores` higher = better. Returns termination reason if a criterion hit.
    mutating func update(_ xs: [[Double]], _ scores: [Double]) -> String? {
        let k = consts(), N = Double(n)
        let order = Operators.rankOrder(scores)
        let old = mean
        var yw = [Double](repeating: 0, count: n)
        var ys: [[Double]] = []
        for (r, i) in order.prefix(k.mu).enumerated() {
            let y = (0..<n).map { (xs[i][$0] - old[$0]) / sigma }
            ys.append(y)
            for j in 0..<n { yw[j] += k.w[r] * y[j] }
        }
        for j in 0..<n { mean[j] = old[j] + sigma * yw[j] }
        countEval += xs.count; runGeneration += 1
        // CSA
        let cy = invSqrt(yw)
        let csn = (k.cs * (2 - k.cs) * k.mueff).squareRoot()
        for j in 0..<n { ps[j] = (1 - k.cs) * ps[j] + csn * cy[j] }
        let psn = ps.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let hsig = psn / (1 - pow(1 - k.cs, 2 * Double(runGeneration))).squareRoot() / k.chiN < 1.4 + 2 / (N + 1)
        let ccn = (k.cc * (2 - k.cc) * k.mueff).squareRoot()
        for j in 0..<n { pc[j] = (1 - k.cc) * pc[j] + (hsig ? ccn * yw[j] : 0) }
        let dh = hsig ? 0 : k.cc * (2 - k.cc)
        let decay = 1 - k.c1 - k.cmu
        if diagonal {
            for j in 0..<n {
                var rmu = 0.0; for (r, y) in ys.enumerated() { rmu += k.w[r] * y[j] * y[j] }
                C[j] = decay * C[j] + k.c1 * (pc[j] * pc[j] + dh * C[j]) + k.cmu * rmu
                C[j] = max(C[j], 1e-300); D[j] = C[j].squareRoot()
            }
        } else {
            for a in 0..<n { for b in 0...a {
                var rmu = 0.0; for (r, y) in ys.enumerated() { rmu += k.w[r] * y[a] * y[b] }
                let v = decay * C[a * n + b] + k.c1 * (pc[a] * pc[b] + dh * C[a * n + b]) + k.cmu * rmu
                C[a * n + b] = v; C[b * n + a] = v
            } }
        }
        sigma *= exp((k.cs / k.damps) * (psn / k.chiN - 1))
        sigma = min(sigma, 1e8)
        if !diagonal && Double(countEval - eigenEval) > Double(lambda) / (k.c1 + k.cmu) / N / 10 {
            eigenEval = countEval
            let (vals, vecs) = Jacobi.eigen(C, n)
            B = vecs; D = vals.map { max($0, 1e-300).squareRoot() }
        }
        // termination tests
        bestHistory.append(scores[order[0]])
        let histLen = 10 + Int((30 * N / Double(lambda)).rounded(.up))
        if bestHistory.count > histLen { bestHistory.removeFirst(bestHistory.count - histLen) }
        let maxD = D.max() ?? 1, minD = D.min() ?? 1
        if sigma * maxD < tolX * sigma0 { return "tolX" }
        if maxD / minD > 1e7 { return "conditionCov" }
        if bestHistory.count >= histLen {
            let all = bestHistory + scores.filter { $0 > EvolutionConstants.failedFitness }
            if let lo = all.min(), let hi = all.max(), hi - lo < tolFun { return "tolFun" }
        }
        if !sigma.isFinite || mean.contains(where: { !$0.isFinite }) { return "numerical" }
        return nil
    }

    /// Applies the restart strategy. Returns true if a restart happened.
    mutating func maybeRestart(reason: String, rng: inout EvoRNG, newMean: [Double]) -> Bool {
        lastTermination = reason
        guard restarts != "none" else {
            if reason == "numerical" { resetDistribution(mean: newMean, sigma: sigma0) }
            return false
        }
        let used = countEval
        if currentIsLarge { largeBudget += used - (largeBudget + smallBudget) } else { smallBudget += used - (largeBudget + smallBudget) }
        restartCount += 1
        var s = sigma0
        if restarts == "ipop" {
            largeRuns += 1; lambda = lambdaDefault << min(largeRuns, 10); currentIsLarge = true
        } else {
            if largeRuns == 0 || smallBudget >= largeBudget {
                largeRuns += 1; lambda = lambdaDefault << min(largeRuns, 10); currentIsLarge = true
            } else {
                let u = rng.nextDouble()
                let lLarge = Double(lambdaDefault << min(largeRuns, 10))
                lambda = max(4, Int(Double(lambdaDefault) * pow(0.5 * lLarge / Double(lambdaDefault), u * u)))
                s = sigma0 * pow(10, -2 * rng.nextDouble()); currentIsLarge = false
            }
        }
        resetDistribution(mean: newMean, sigma: s)
        return true
    }
}

/// Cyclic Jacobi eigen-solver for a symmetric n×n row-major matrix. Returns (eigenvalues, eigenvectors as
/// columns of a row-major matrix).
enum Jacobi {
    static func eigen(_ m: [Double], _ n: Int) -> ([Double], [Double]) {
        var a = m
        var v = [Double](repeating: 0, count: n * n)
        for i in 0..<n { v[i * n + i] = 1 }
        for _ in 0..<60 {
            var off = 0.0
            for p in 0..<n { for q in (p + 1)..<max(p + 1, n) { off += a[p * n + q] * a[p * n + q] } }
            if off < 1e-30 { break }
            for p in 0..<n { for q in (p + 1)..<max(p + 1, n) {
                let apq = a[p * n + q]
                if abs(apq) < 1e-300 { continue }
                let theta = (a[q * n + q] - a[p * n + p]) / (2 * apq)
                let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot(), s = t * c
                for k in 0..<n {
                    let akp = a[k * n + p], akq = a[k * n + q]
                    a[k * n + p] = c * akp - s * akq; a[k * n + q] = s * akp + c * akq
                }
                for k in 0..<n {
                    let apk = a[p * n + k], aqk = a[q * n + k]
                    a[p * n + k] = c * apk - s * aqk; a[q * n + k] = s * apk + c * aqk
                }
                for k in 0..<n {
                    let vkp = v[k * n + p], vkq = v[k * n + q]
                    v[k * n + p] = c * vkp - s * vkq; v[k * n + q] = s * vkp + c * vkq
                }
            } }
        }
        return ((0..<n).map { a[$0 * n + $0] }, v)
    }
}

/// Shared ask/tell wrapper around CMAEngine.
final class CMACore {
    struct State: Codable {
        var rng: EvoRNG; var generation: Int; var nextID: UInt64
        var engine: CMAEngine
        var best: Genome?; var bestFit: Fitness?
    }
    let layout: GenomeLayout, scale: [Double], label: String
    var st: State
    weak var owner: AnyObject?

    init(layout: GenomeLayout, params: AlgorithmParams, population: Int, seed: UInt64, diagonal: Bool, label: String) throws {
        guard layout.count > 0 else { throw EvolutionError.invalidExperiment("\(label) needs at least one gene") }
        self.layout = layout; self.label = label
        scale = layout.genes.map { $0.mutationScale }
        var rng = EvoRNG(seed: seed)
        let m0 = layout.randomValues(&rng)
        let sc = scale
        let mean = (0..<layout.count).map { m0[$0] / sc[$0] }
        st = State(rng: rng, generation: 0, nextID: 1,
                   engine: try CMAEngine(n: layout.count, diagonal: diagonal, params: params, population: population, mean: mean),
                   best: nil, bestFit: nil)
    }

    func ask(hooks: (any AlgorithmHooks)?) throws -> [Genome] {
        var out: [Genome] = []
        for _ in 0..<st.engine.lambda {
            let u = st.engine.sample(&st.rng)
            var v = (0..<layout.count).map { u[$0] * scale[$0] }
            if let h = hooks, let m = try h.mutate(Genome(id: 0, values: v), layout: layout, rate: st.engine.sigma, rng: &st.rng) {
                guard m.count == layout.count else { throw EvolutionError.invalidExperiment("mutate hook returned \(m.count) genes, expected \(layout.count)") }
                v = m
            }
            layout.legalize(&v)
            out.append(Genome(id: st.nextID, values: v, origin: "sample", generation: st.generation)); st.nextID += 1
        }
        return out
    }

    func tell(_ genomes: [Genome], _ fitness: [Fitness]) throws {
        precondition(genomes.count == fitness.count)
        let scores = fitness.map(Operators.score)
        for (g, f) in zip(genomes, fitness) where Operators.score(f) > (st.bestFit.map(Operators.score) ?? -.infinity) { st.best = g; st.bestFit = f }
        let xs = genomes.map { g in (0..<layout.count).map { g.values[$0] / scale[$0] } }
        if let reason = st.engine.update(xs, scores) {
            var nm = layout.randomValues(&st.rng)
            for i in nm.indices { nm[i] /= scale[i] }
            _ = st.engine.maybeRestart(reason: reason, rng: &st.rng, newMean: nm)
        }
        st.generation += 1
    }

    var best: (genome: Genome, fitness: Fitness)? { st.best.flatMap { g in st.bestFit.map { (g, $0) } } }
    var diagnostics: [String: Double] {
        let e = st.engine
        return ["sigma": e.sigma, "lambda": Double(e.lambda), "restarts": Double(e.restartCount),
                "axisRatio": (e.D.max() ?? 1) / max(1e-300, e.D.min() ?? 1), "evaluations": Double(e.countEval)]
    }
    /// Current distribution mean in gene space (legalised).
    var meanValues: [Double] { var v = (0..<layout.count).map { st.engine.mean[$0] * scale[$0] }; layout.legalize(&v); return v }
}

/// Full-covariance CMA-ES (Hansen 2016 tutorial defaults).
public final class CMAES: EvolutionAlgorithm {
    public static let kind = "cmaes"
    public var hooks: (any AlgorithmHooks)?
    let core: CMACore
    public init(layout: GenomeLayout, params: AlgorithmParams, population: Int, seed: UInt64) throws {
        if layout.count > 400 { throw EvolutionError.invalidExperiment("cmaes: \(layout.count) genes is too many for a full covariance — use sep-cmaes") }
        core = try CMACore(layout: layout, params: params, population: population, seed: seed, diagonal: false, label: "cmaes")
    }
    public var generation: Int { core.st.generation }
    public func ask() throws -> [Genome] { try core.ask(hooks: hooks) }
    public func tell(_ genomes: [Genome], _ fitness: [Fitness]) throws { try core.tell(genomes, fitness) }
    public var best: (genome: Genome, fitness: Fitness)? { core.best }
    public var archive: EliteArchive? { nil }
    public var species: [SpeciesInfo] { [] }
    public var diagnostics: [String: Double] { core.diagnostics }
    public var meanValues: [Double] { core.meanValues }
    public func saveState() throws -> Data { try AlgorithmState.encode(core.st) }
    public func restore(_ state: Data) throws { core.st = try AlgorithmState.decode(CMACore.State.self, state) }
}

/// Diagonal (separable) CMA-ES for large genomes (e.g. MLP weights).
public final class SeparableCMAES: EvolutionAlgorithm {
    public static let kind = "sep-cmaes"
    public var hooks: (any AlgorithmHooks)?
    let core: CMACore
    public init(layout: GenomeLayout, params: AlgorithmParams, population: Int, seed: UInt64) throws {
        core = try CMACore(layout: layout, params: params, population: population, seed: seed, diagonal: true, label: "sep-cmaes")
    }
    public var generation: Int { core.st.generation }
    public func ask() throws -> [Genome] { try core.ask(hooks: hooks) }
    public func tell(_ genomes: [Genome], _ fitness: [Fitness]) throws { try core.tell(genomes, fitness) }
    public var best: (genome: Genome, fitness: Fitness)? { core.best }
    public var archive: EliteArchive? { nil }
    public var species: [SpeciesInfo] { [] }
    public var diagnostics: [String: Double] { core.diagnostics }
    public var meanValues: [Double] { core.meanValues }
    public func saveState() throws -> Data { try AlgorithmState.encode(core.st) }
    public func restore(_ state: Data) throws { core.st = try AlgorithmState.decode(CMACore.State.self, state) }
}

/// OpenAI-ES (Salimans 2017): antithetic sampling, rank shaping, Adam.
public final class OpenAIES: EvolutionAlgorithm {
    public static let kind = "openai-es"
    public var hooks: (any AlgorithmHooks)?
    struct State: Codable {
        var rng: EvoRNG; var generation: Int; var nextID: UInt64
        var theta: [Double]; var m: [Double]; var v: [Double]; var t: Int
        var best: Genome?; var bestFit: Fitness?
        var gradNorm = 0.0
    }
    let layout: GenomeLayout, scale: [Double], popSize: Int
    let lr: Double, sigma: Double, antithetic: Bool, weightDecay: Double, adam: Bool, rankShaping: Bool
    var st: State

    public init(layout: GenomeLayout, params: AlgorithmParams, population: Int, seed: UInt64) throws {
        guard layout.count > 0 else { throw EvolutionError.invalidExperiment("openai-es needs at least one gene") }
        self.layout = layout
        scale = layout.genes.map { $0.mutationScale }
        lr = params.double("lr", 0.05); sigma = params.double("sigma", 0.5)
        guard sigma > 0, lr > 0 else { throw EvolutionError.invalidExperiment("openai-es: lr and sigma must be > 0") }
        antithetic = params.bool("antithetic", true); weightDecay = params.double("weightDecay", 0)
        let opt = params.string("optimizer", "adam"), shaping = params.string("fitnessShaping", "rank")
        guard opt == "adam" || opt == "sgd" else { throw EvolutionError.invalidExperiment("openai-es: optimizer must be adam|sgd") }
        guard shaping == "rank" || shaping == "none" else { throw EvolutionError.invalidExperiment("openai-es: fitnessShaping must be rank|none") }
        adam = opt == "adam"; rankShaping = shaping == "rank"
        var p = max(2, population); if antithetic && p % 2 == 1 { p += 1 }
        popSize = p
        var rng = EvoRNG(seed: seed)
        let x0 = layout.randomValues(&rng)
        let n = layout.count
        let sc = scale
        st = State(rng: rng, generation: 0, nextID: 1, theta: (0..<n).map { x0[$0] / sc[$0] },
                   m: [Double](repeating: 0, count: n), v: [Double](repeating: 0, count: n), t: 0)
    }
    public var generation: Int { st.generation }

    public func ask() throws -> [Genome] {
        let n = layout.count
        var out: [Genome] = []
        var eps = [Double](repeating: 0, count: n)
        for k in 0..<popSize {
            if !antithetic || k % 2 == 0 { for i in 0..<n { eps[i] = st.rng.gaussian() } }
            let sgn = antithetic && k % 2 == 1 ? -1.0 : 1.0
            var x = (0..<n).map { (st.theta[$0] + sgn * sigma * eps[$0]) * scale[$0] }
            if let h = hooks, let m = try h.mutate(Genome(id: 0, values: x), layout: layout, rate: sigma, rng: &st.rng) {
                guard m.count == n else { throw EvolutionError.invalidExperiment("mutate hook returned \(m.count) genes, expected \(n)") }
                x = m
            }
            layout.legalize(&x)
            out.append(Genome(id: st.nextID, values: x, origin: "sample", generation: st.generation)); st.nextID += 1
        }
        return out
    }

    public func tell(_ genomes: [Genome], _ fitness: [Fitness]) throws {
        precondition(genomes.count == fitness.count)
        let n = layout.count, P = genomes.count
        let s = fitness.map(Operators.score)
        for (g, f) in zip(genomes, fitness) where Operators.score(f) > (st.bestFit.map(Operators.score) ?? -.infinity) { st.best = g; st.bestFit = f }
        var u = [Double](repeating: 0, count: P)
        if rankShaping {
            let order = Operators.rankOrder(s)   // best first
            for (r, i) in order.enumerated() { u[i] = P > 1 ? Double(P - 1 - r) / Double(P - 1) - 0.5 : 0 }
        } else {
            let mean = s.reduce(0, +) / Double(P)
            let sd = max(1e-12, (s.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(P)).squareRoot())
            u = s.map { ($0 - mean) / sd }
        }
        var grad = [Double](repeating: 0, count: n)
        for k in 0..<P {
            for i in 0..<n {
                let e = (genomes[k].values[i] / scale[i] - st.theta[i]) / sigma
                grad[i] += u[k] * e
            }
        }
        var gn = 0.0
        for i in 0..<n { grad[i] = grad[i] / (Double(P) * sigma) - weightDecay * st.theta[i]; gn += grad[i] * grad[i] }
        st.gradNorm = gn.squareRoot()
        st.t += 1
        if adam {
            let b1 = 0.9, b2 = 0.999
            let c1 = 1 - pow(b1, Double(st.t)), c2 = 1 - pow(b2, Double(st.t))
            for i in 0..<n {
                st.m[i] = b1 * st.m[i] + (1 - b1) * grad[i]
                st.v[i] = b2 * st.v[i] + (1 - b2) * grad[i] * grad[i]
                st.theta[i] += lr * (st.m[i] / c1) / ((st.v[i] / c2).squareRoot() + 1e-8)
            }
        } else {
            for i in 0..<n { st.m[i] = 0.9 * st.m[i] + grad[i]; st.theta[i] += lr * st.m[i] }
        }
        // keep theta inside the legal box (normalised)
        for i in 0..<n {
            let g = layout.genes[i]
            st.theta[i] = min(max(st.theta[i], g.min / scale[i]), g.max / scale[i])
        }
        st.generation += 1
    }

    public var best: (genome: Genome, fitness: Fitness)? { st.best.flatMap { g in st.bestFit.map { (g, $0) } } }
    public var archive: EliteArchive? { nil }
    public var species: [SpeciesInfo] { [] }
    public var diagnostics: [String: Double] { ["sigma": sigma, "lr": lr, "gradNorm": st.gradNorm] }
    public var meanValues: [Double] { var v = (0..<layout.count).map { st.theta[$0] * scale[$0] }; layout.legalize(&v); return v }
    public func saveState() throws -> Data { try AlgorithmState.encode(st) }
    public func restore(_ state: Data) throws { st = try AlgorithmState.decode(State.self, state) }
}
