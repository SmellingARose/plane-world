// OWNED BY neat-qd builder (algorithms builder). -----------------------------------------------------------
// Novelty search (Lehman & Stanley 2011): novelty = mean distance to the k nearest neighbours among the current
// population + the novelty archive (descriptors normalised by the axis ranges when axes are given).
// Selection score = (1 - fitnessWeight)·rank(novelty) + fitnessWeight·rank(fitness)  (ranks in [0, 1]).
// Params: k (15), fitnessWeight (0 = pure novelty), threshold (0 = adaptive: starts at the first generation's
// median novelty, ×1.2 when > 4 added in a generation, ×0.95 after 5 generations with none), archiveAddProbability
// (0.0 extra random additions), maxArchive (5000), tournamentSize (3), elitism (1, by score), mutationRate (1/n),
// mutationSigma (1), crossoverRate (0.3, uniform). Candidates without a descriptor get novelty 0.
// `Fitness.novelty` is filled on the copies the algorithm keeps (best, archive cells); `lastNovelty` exposes the
// scores of the last told generation in order.
// When axes are given every evaluated candidate competes for its grid cell in `archive.cells` (best fitness per
// cell), so the UI heatmap shows the explored behaviour space. JS hooks: select, crossover, mutate.
import Foundation
import PWCore

public final class NoveltySearch: EvolutionAlgorithm {
    public static let kind = "novelty"
    public var hooks: (any AlgorithmHooks)?

    struct State: Codable {
        var rng: EvoRNG; var generation: Int; var nextID: UInt64
        var population: [Genome] = []; var fitness: [Fitness] = []; var scores: [Double] = []
        var archive: EliteArchive
        var threshold: Double
        var noAddStreak = 0, lastAdded = 0
        var best: Genome?; var bestFit: Fitness?
        var lastNovelty: [Double] = []
    }
    let layout: GenomeLayout, popSize: Int, k: Int, fitnessWeight: Double, addProb: Double, maxArchive: Int
    let tournament: Int, elitism: Int, mutationRate: Double, mutationSigma: Double, crossoverRate: Double
    var st: State

    public init(layout: GenomeLayout, params: AlgorithmParams, population: Int, seed: UInt64) throws {
        guard layout.count > 0 else { throw EvolutionError.invalidExperiment("novelty needs at least one flat gene") }
        self.layout = layout; popSize = max(2, population)
        k = max(1, params.int("k", 15)); fitnessWeight = min(1, max(0, params.double("fitnessWeight", 0)))
        addProb = params.double("archiveAddProbability", 0); maxArchive = max(1, params.int("maxArchive", 5000))
        tournament = max(1, params.int("tournamentSize", 3)); elitism = max(0, min(popSize - 1, params.int("elitism", 1)))
        mutationRate = params.double("mutationRate", 1 / Double(layout.count)); mutationSigma = params.double("mutationSigma", 1)
        crossoverRate = params.double("crossoverRate", 0.3)
        st = State(rng: EvoRNG(seed: seed), generation: 0, nextID: 1, archive: EliteArchive(axes: try MAPElites.axes(params)),
                   threshold: params.double("threshold", 0))
    }
    public var generation: Int { st.generation }
    public var lastNovelty: [Double] { st.lastNovelty }

    public func ask() throws -> [Genome] {
        func mk(_ v: [Double], _ o: String, _ p: [UInt64]) -> Genome { defer { st.nextID += 1 }; return Genome(id: st.nextID, values: v, parents: p, origin: o, generation: st.generation) }
        if st.population.isEmpty { return (0..<popSize).map { _ in mk(layout.randomValues(&st.rng), "init", []) } }
        let pop = st.population, s = st.scores
        var out: [Genome] = []
        for i in Operators.rankOrder(s).prefix(elitism) { var e = pop[i]; e.parents = [e.id]; e.id = st.nextID; st.nextID += 1; e.origin = "elite"; e.generation = st.generation; out.append(e) }
        let nc = popSize - out.count
        var sel: [Int]? = nil
        if let h = hooks { sel = try h.select(population: pop, fitness: st.fitness, count: 2 * nc, rng: &st.rng) }
        if let p = sel, p.count < 2 * nc || p.contains(where: { $0 < 0 || $0 >= pop.count }) { throw EvolutionError.invalidExperiment("select() must return \(2 * nc) indices in 0..<\(pop.count)") }
        let parents = sel ?? Operators.select(.tournament, scores: s, count: 2 * nc, tournamentSize: tournament, rng: &st.rng)
        for c in 0..<nc {
            let a = pop[parents[2 * c]], b = pop[parents[2 * c + 1]]
            var v = a.values, o = "mutation", par = [a.id]
            if st.rng.nextDouble() < crossoverRate {
                if let h = hooks, let x = try h.crossover(a, b, layout: layout, rng: &st.rng) { v = x }
                else { v = Operators.crossover(.uniform, a.values, b.values, layout: layout, rng: &st.rng) }
                o = "crossover"; par = [a.id, b.id]
            }
            if let h = hooks, let m = try h.mutate(Genome(id: 0, values: v), layout: layout, rate: mutationRate, rng: &st.rng) { v = m }
            else { v = Operators.mutate(.gaussian, v, layout: layout, rate: mutationRate, sigmaScale: mutationSigma, rng: &st.rng) }
            guard v.count == layout.count else { throw EvolutionError.invalidExperiment("hook returned \(v.count) genes, expected \(layout.count)") }
            layout.legalize(&v)
            out.append(mk(v, o, par))
        }
        return out
    }

    func normalise(_ d: [Double]) -> [Double] {
        let ax = st.archive.axes
        guard ax.count == d.count else { return d }
        return zip(d, ax).map { v, a in (v - a.min) / max(1e-12, a.max - a.min) }
    }

    /// Mean distance to the k nearest points in `pool` (excluding index `selfIndex` of the pool).
    static func knn(_ x: [Double], _ pool: [[Double]], k: Int, exclude: Int) -> Double {
        var ds: [Double] = []; ds.reserveCapacity(pool.count)
        for (j, p) in pool.enumerated() where j != exclude && p.count == x.count {
            var s = 0.0; for q in 0..<x.count { let t = p[q] - x[q]; s += t * t }; ds.append(s.squareRoot())
        }
        guard !ds.isEmpty else { return 0 }
        ds.sort()
        let m = min(k, ds.count)
        return ds.prefix(m).reduce(0, +) / Double(m)
    }

    public func tell(_ genomes: [Genome], _ fitness: [Fitness]) throws {
        precondition(genomes.count == fitness.count)
        let descs: [[Double]?] = fitness.map { f in f.error == nil ? f.descriptor.flatMap { d in d.allSatisfy(\.isFinite) ? normalise(d) : nil } : nil }
        let popPts = descs.compactMap { $0 }
        let pool = popPts + st.archive.noveltyPoints
        var nov = [Double](repeating: 0, count: genomes.count)
        var pi = 0
        for i in genomes.indices { if let d = descs[i] { nov[i] = Self.knn(d, pool, k: k, exclude: pi); pi += 1 } }
        st.lastNovelty = nov
        // archive additions
        if st.threshold <= 0 {
            let v = nov.filter { $0 > 0 }.sorted()
            st.threshold = v.isEmpty ? 0 : v[v.count / 2]
        }
        var added = 0
        for i in genomes.indices {
            guard let d = descs[i] else { continue }
            if (st.threshold > 0 && nov[i] > st.threshold) || st.rng.nextDouble() < addProb {
                st.archive.noveltyPoints.append(d); added += 1
            }
            // every evaluated candidate competes for its grid cell (UI heatmap of explored behaviour space)
            var f = fitness[i]; f.novelty = nov[i]
            if let raw = fitness[i].descriptor, let c = st.archive.cellIndex(raw) {
                if let e = st.archive.cells[c], Operators.score(e.fitness) >= Operators.score(f) { } else {
                    st.archive.cells[c] = .init(genome: genomes[i], fitness: f, generation: st.generation)
                }
            }
        }
        if st.archive.noveltyPoints.count > maxArchive { st.archive.noveltyPoints.removeFirst(st.archive.noveltyPoints.count - maxArchive) }
        if added > 4 { st.threshold *= 1.2; st.noAddStreak = 0 }
        else if added == 0 { st.noAddStreak += 1; if st.noAddStreak >= 5 { st.threshold *= 0.95; st.noAddStreak = 0 } }
        else { st.noAddStreak = 0 }
        st.lastAdded = added
        // selection scores
        let fs = fitness.map(Operators.score)
        func ranks(_ x: [Double]) -> [Double] {
            var r = [Double](repeating: 0, count: x.count)
            let o = Operators.rankOrder(x)
            for (k, i) in o.enumerated() { r[i] = x.count > 1 ? Double(x.count - 1 - k) / Double(x.count - 1) : 1 }
            return r
        }
        let rn = ranks(nov), rf = ranks(fs)
        st.scores = genomes.indices.map { (1 - fitnessWeight) * rn[$0] + fitnessWeight * rf[$0] }
        for i in genomes.indices where fs[i] > (st.bestFit.map(Operators.score) ?? -.infinity) {
            st.best = genomes[i]; var f = fitness[i]; f.novelty = nov[i]; st.bestFit = f
        }
        st.population = genomes; st.fitness = fitness.enumerated().map { var f = $0.element; f.novelty = nov[$0.offset]; return f }
        st.generation += 1
    }

    public var best: (genome: Genome, fitness: Fitness)? { st.best.flatMap { g in st.bestFit.map { (g, $0) } } }
    public var archive: EliteArchive? { st.archive }
    public var species: [SpeciesInfo] { [] }
    public var diagnostics: [String: Double] {
        let m = st.lastNovelty.isEmpty ? 0 : st.lastNovelty.reduce(0, +) / Double(st.lastNovelty.count)
        return ["archiveSize": Double(st.archive.noveltyPoints.count), "threshold": st.threshold, "added": Double(st.lastAdded),
                "meanNovelty": m, "maxNovelty": st.lastNovelty.max() ?? 0]
    }
    public func saveState() throws -> Data { try AlgorithmState.encode(st) }
    public func restore(_ state: Data) throws { st = try AlgorithmState.decode(State.self, state) }
}
