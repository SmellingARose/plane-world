// OWNED BY architect. ------------------------------------------------------------------------------
// Two small but complete reference algorithms. They exist so the Run/Evaluator/checkpoint pipeline is
// testable end-to-end and to show builders the expected shape (state struct + saveState/restore).
//   * "random"    — uniform random search (baseline).
//   * "simple-es" — (μ/μ_w, λ) evolution strategy with weighted recombination, per-gene sigma from the
//                   layout's mutationScale times a global step size adapted by the 1/5th success rule,
//                   plus one elite carried over unchanged. Params: mu (λ/4), sigma (1.0 = layout scale),
//                   elite (1).
import Foundation
import PWCore

public final class RandomSearch: EvolutionAlgorithm {
    public static let kind = "random"
    struct State: Codable { var rng: EvoRNG; var generation: Int; var nextID: UInt64; var best: Genome?; var bestFit: Fitness? }
    let layout: GenomeLayout, popSize: Int
    var st: State
    public var hooks: (any AlgorithmHooks)?
    public init(layout: GenomeLayout, params: AlgorithmParams, population: Int, seed: UInt64) throws {
        guard layout.count > 0 else { throw EvolutionError.invalidExperiment("random search needs at least one gene") }
        self.layout = layout; popSize = max(1, population)
        st = State(rng: EvoRNG(seed: seed), generation: 0, nextID: 1, best: nil, bestFit: nil)
    }
    public var generation: Int { st.generation }
    public func ask() throws -> [Genome] {
        (0..<popSize).map { _ in
            defer { st.nextID += 1 }
            return Genome(id: st.nextID, values: layout.randomValues(&st.rng), origin: "random", generation: st.generation)
        }
    }
    public func tell(_ genomes: [Genome], _ fitness: [Fitness]) throws {
        for (g, f) in zip(genomes, fitness) where f.total > (st.bestFit?.total ?? -.infinity) { st.best = g; st.bestFit = f }
        st.generation += 1
    }
    public var best: (genome: Genome, fitness: Fitness)? { st.best.flatMap { g in st.bestFit.map { (g, $0) } } }
    public var archive: EliteArchive? { nil }
    public var species: [SpeciesInfo] { [] }
    public var diagnostics: [String: Double] { [:] }
    public func saveState() throws -> Data { try AlgorithmState.encode(st) }
    public func restore(_ state: Data) throws { st = try AlgorithmState.decode(State.self, state) }
}

public final class SimpleES: EvolutionAlgorithm {
    public static let kind = "simple-es"
    struct State: Codable {
        var rng: EvoRNG; var generation: Int; var nextID: UInt64
        var mean: [Double]; var stepSize: Double
        var elite: Genome?; var eliteFit: Fitness?
    }
    let layout: GenomeLayout, lambda: Int, mu: Int, eliteCount: Int
    var st: State
    public var hooks: (any AlgorithmHooks)?

    public init(layout: GenomeLayout, params: AlgorithmParams, population: Int, seed: UInt64) throws {
        guard layout.count > 0 else { throw EvolutionError.invalidExperiment("simple-es needs at least one gene") }
        self.layout = layout
        lambda = max(2, population)
        mu = max(1, min(lambda, params.int("mu", lambda / 4)))
        eliteCount = max(0, min(1, params.int("elite", 1)))
        var rng = EvoRNG(seed: seed)
        let m = layout.randomValues(&rng)
        st = State(rng: rng, generation: 0, nextID: 1, mean: m, stepSize: params.double("sigma", 1.0), elite: nil, eliteFit: nil)
    }
    public var generation: Int { st.generation }

    public func ask() throws -> [Genome] {
        var out: [Genome] = []
        if eliteCount > 0, var e = st.elite { e.origin = "elite"; e.generation = st.generation; out.append(e) }
        while out.count < lambda {
            var v = st.mean
            for i in v.indices { v[i] += st.rng.gaussian() * layout.genes[i].mutationScale * st.stepSize }
            if let h = hooks, let m = try h.mutate(Genome(id: 0, values: st.mean), layout: layout, rate: st.stepSize, rng: &st.rng) { v = m }
            layout.legalize(&v)
            out.append(Genome(id: st.nextID, values: v, origin: "mutation", generation: st.generation)); st.nextID += 1
        }
        return out
    }

    public func tell(_ genomes: [Genome], _ fitness: [Fitness]) throws {
        precondition(genomes.count == fitness.count)
        let order = fitness.indices.sorted { fitness[$0].total > fitness[$1].total }
        // weighted recombination of the μ best (log weights)
        let w = (0..<mu).map { log(Double(mu) + 0.5) - log(Double($0) + 1) }, ws = w.reduce(0, +)
        var m = [Double](repeating: 0, count: layout.count)
        for (k, i) in order.prefix(mu).enumerated() { for j in m.indices { m[j] += genomes[i].values[j] * w[k] / ws } }
        // 1/5th success rule against the previous elite
        let prevBest = st.eliteFit?.total ?? -.infinity
        let successes = fitness.filter { $0.total > prevBest }.count
        let rate = Double(successes) / Double(max(1, fitness.count))
        st.stepSize *= rate > 0.2 ? 1.22 : 0.85
        st.stepSize = min(max(st.stepSize, 1e-6), 10)
        layout.legalize(&m); st.mean = m
        if let b = order.first, fitness[b].total > prevBest { st.elite = genomes[b]; st.eliteFit = fitness[b] }
        st.generation += 1
    }
    public var best: (genome: Genome, fitness: Fitness)? { st.elite.flatMap { g in st.eliteFit.map { (g, $0) } } }
    public var archive: EliteArchive? { nil }
    public var species: [SpeciesInfo] { [] }
    public var diagnostics: [String: Double] { ["stepSize": st.stepSize] }
    public func saveState() throws -> Data { try AlgorithmState.encode(st) }
    public func restore(_ state: Data) throws { st = try AlgorithmState.decode(State.self, state) }
}
