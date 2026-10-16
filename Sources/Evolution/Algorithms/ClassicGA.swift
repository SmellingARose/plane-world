// OWNED BY ga-es builder (algorithms builder). ------------------------------------------------------------
// Classic generational GA. Params (docs §5.1): selection "tournament"|"roulette"|"rank", tournamentSize (3),
// elitism (2), crossover "uniform"|"one-point"|"blend"|"sbx" (sbx), crossoverRate (0.9), blendAlpha (0.5),
// sbxEta (15), mutation "gaussian"|"polynomial" (gaussian), mutationRate (1/n), mutationSigma (1, × GeneSpec
// mutationScale), polyEta (20), adaptive (false): 1/5th-success-rule adaptation of mutationRate and
// mutationSigma (success = child beats its best parent and the previous median), reported in diagnostics.
// JS hooks: select (once per generation for all parent slots), crossover, mutate (nil → built-in).
import Foundation
import PWCore

public final class ClassicGA: EvolutionAlgorithm {
    public static let kind = "ga"
    public var hooks: (any AlgorithmHooks)?

    struct State: Codable {
        var rng: EvoRNG; var generation: Int; var nextID: UInt64
        var population: [Genome] = []; var fitness: [Fitness] = []
        var best: Genome?; var bestFit: Fitness?
        var mutationRate: Double; var mutationSigma: Double
        var successRate: Double = 0; var stagnation: Int = 0
    }
    let layout: GenomeLayout, popSize: Int
    let selection: SelectionMethod, tournamentSize: Int, elitism: Int
    let crossoverMethod: CrossoverMethod, crossoverRate: Double, blendAlpha: Double, sbxEta: Double
    let mutationMethod: MutationMethod, polyEta: Double, adaptive: Bool
    var st: State

    public init(layout: GenomeLayout, params: AlgorithmParams, population: Int, seed: UInt64) throws {
        guard layout.count > 0 else { throw EvolutionError.invalidExperiment("ga needs at least one gene") }
        self.layout = layout; popSize = max(2, population)
        func parse<T: RawRepresentable>(_ k: String, _ d: T) throws -> T where T.RawValue == String {
            let s = params.string(k, d.rawValue)
            guard let v = T(rawValue: s) else { throw EvolutionError.invalidExperiment("ga: unknown \(k) '\(s)'") }
            return v
        }
        selection = try parse("selection", SelectionMethod.tournament)
        crossoverMethod = try parse("crossover", CrossoverMethod.sbx)
        mutationMethod = try parse("mutation", MutationMethod.gaussian)
        tournamentSize = max(1, params.int("tournamentSize", 3))
        elitism = max(0, min(popSize - 1, params.int("elitism", 2)))
        crossoverRate = params.double("crossoverRate", 0.9)
        blendAlpha = params.double("blendAlpha", 0.5)
        sbxEta = params.double("sbxEta", 15)
        polyEta = params.double("polyEta", 20)
        adaptive = params.bool("adaptive", false)
        st = State(rng: EvoRNG(seed: seed), generation: 0, nextID: 1,
                   mutationRate: params.double("mutationRate", 1 / Double(layout.count)),
                   mutationSigma: params.double("mutationSigma", 1))
    }

    public var generation: Int { st.generation }

    func make(_ v: [Double], origin: String, parents: [UInt64]) -> Genome {
        defer { st.nextID += 1 }
        return Genome(id: st.nextID, values: v, parents: parents, origin: origin, generation: st.generation)
    }

    public func ask() throws -> [Genome] {
        if st.population.isEmpty {
            return (0..<popSize).map { _ in make(layout.randomValues(&st.rng), origin: "init", parents: []) }
        }
        let pop = st.population, fit = st.fitness
        let scores = fit.map(Operators.score)
        let order = Operators.rankOrder(scores)
        var out: [Genome] = []
        for i in order.prefix(elitism) { var e = pop[i]; e.origin = "elite"; e.generation = st.generation; e.parents = [pop[i].id]; e.id = st.nextID; st.nextID += 1; out.append(e) }
        let nChildren = popSize - out.count
        var parents: [Int]? = nil
        if let h = hooks { parents = try h.select(population: pop, fitness: fit, count: 2 * nChildren, rng: &st.rng) }
        if let p = parents, p.count < 2 * nChildren || p.contains(where: { $0 < 0 || $0 >= pop.count }) {
            throw EvolutionError.invalidExperiment("select() must return \(2 * nChildren) indices in 0..<\(pop.count)")
        }
        let sel = parents ?? Operators.select(selection, scores: scores, count: 2 * nChildren, tournamentSize: tournamentSize, rng: &st.rng)
        for c in 0..<nChildren {
            let a = pop[sel[2 * c]], b = pop[sel[2 * c + 1]]
            var v = a.values, origin = "mutation", par = [a.id]
            if rng01() < crossoverRate {
                if let h = hooks, let x = try h.crossover(a, b, layout: layout, rng: &st.rng) { v = x }
                else { v = Operators.crossover(crossoverMethod, a.values, b.values, layout: layout, blendAlpha: blendAlpha, sbxEta: sbxEta, rng: &st.rng) }
                origin = "crossover"; par = [a.id, b.id]
            }
            let tmp = Genome(id: 0, values: v)
            if let h = hooks, let m = try h.mutate(tmp, layout: layout, rate: st.mutationRate, rng: &st.rng) { v = m }
            else { v = Operators.mutate(mutationMethod, v, layout: layout, rate: st.mutationRate, sigmaScale: st.mutationSigma, polyEta: polyEta, rng: &st.rng) }
            if v.count != layout.count { throw EvolutionError.invalidExperiment("crossover/mutate hook returned \(v.count) genes, expected \(layout.count)") }
            layout.legalize(&v)
            out.append(make(v, origin: origin, parents: par))
        }
        return out
    }

    @inline(__always) func rng01() -> Double { st.rng.nextDouble() }

    public func tell(_ genomes: [Genome], _ fitness: [Fitness]) throws {
        precondition(genomes.count == fitness.count)
        // offspring success vs parents (for adaptation + diagnostics)
        var prev: [UInt64: Double] = [:]
        for (g, f) in zip(st.population, st.fitness) { prev[g.id] = Operators.score(f) }
        let prevScores = st.fitness.map(Operators.score).sorted()
        let prevMedian = prevScores.isEmpty ? -Double.infinity : prevScores[prevScores.count / 2]
        var tried = 0, won = 0
        for (g, f) in zip(genomes, fitness) where g.origin != "elite" && g.origin != "init" {
            let ps = g.parents.compactMap { prev[$0] }
            guard !ps.isEmpty else { continue }
            tried += 1; if Operators.score(f) > max(ps.max()!, prevMedian) { won += 1 }
        }
        st.successRate = tried > 0 ? Double(won) / Double(tried) : 0
        if adaptive && tried > 0 {
            let up = st.successRate > 0.2
            st.mutationSigma = min(3, max(1e-4, st.mutationSigma * (up ? 1.22 : 0.85)))
            st.mutationRate = min(0.5, max(0.5 / Double(layout.count), st.mutationRate * (up ? 1.1 : 0.93)))
        }
        let prevBest = st.bestFit.map(Operators.score) ?? -.infinity
        for (g, f) in zip(genomes, fitness) where Operators.score(f) > (st.bestFit.map(Operators.score) ?? -.infinity) { st.best = g; st.bestFit = f }
        st.stagnation = (st.bestFit.map(Operators.score) ?? -.infinity) > prevBest ? 0 : st.stagnation + 1
        st.population = genomes; st.fitness = fitness
        st.generation += 1
    }

    public var best: (genome: Genome, fitness: Fitness)? { st.best.flatMap { g in st.bestFit.map { (g, $0) } } }
    public var archive: EliteArchive? { nil }
    public var species: [SpeciesInfo] { [] }
    public var diagnostics: [String: Double] {
        ["mutationRate": st.mutationRate, "mutationSigma": st.mutationSigma, "successRate": st.successRate, "stagnation": Double(st.stagnation)]
    }
    public func saveState() throws -> Data { try AlgorithmState.encode(st) }
    public func restore(_ state: Data) throws { st = try AlgorithmState.decode(State.self, state) }
}
