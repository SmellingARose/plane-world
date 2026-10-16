// OWNED BY neat-qd builder (algorithms builder). -----------------------------------------------------------
// MAP-Elites (Mouret & Clune 2015) with iso+line variation (Vassiliades & Mouret 2018).
// Params: axes (from ExperimentDocument.descriptorAxes, passed by the Run as params.values["axes"]),
// initialRandom (population: random candidates before emitting from the archive), batch (population),
// isoSigma (0.5 × mutationScale), lineSigma (0.2), mutationSigma (alias of isoSigma), cvt (0 = grid;
// N > 0 = CVT-MAP-Elites with N centroids from k-means over uniform samples in the descriptor box; cell keys are
// then centroid indices, so the grid heatmap shows a coarse projection — see diagnostics "cvt").
// JS hooks: crossover (replaces the line term with a 2-parent child) and mutate (replaces the iso step).
import Foundation
import PWCore

public final class MAPElites: EvolutionAlgorithm {
    public static let kind = "map-elites"
    public var hooks: (any AlgorithmHooks)?

    struct State: Codable {
        var rng: EvoRNG; var generation: Int; var nextID: UInt64
        var archive: EliteArchive
        var evaluated = 0
        var centroids: [[Double]] = []
        var lastInserted = 0, lastImproved = 0
    }
    let layout: GenomeLayout, batch: Int, initialRandom: Int, isoSigma: Double, lineSigma: Double
    var st: State

    static func axes(_ params: AlgorithmParams) throws -> [DescriptorAxis] {
        guard let a = params.values["axes"] else { return [] }
        do { return try JSONIO.decode([DescriptorAxis].self, from: try JSONIO.encode(a, pretty: false)) }
        catch { throw EvolutionError.invalidExperiment("descriptor axes malformed: \(error)") }
    }

    public init(layout: GenomeLayout, params: AlgorithmParams, population: Int, seed: UInt64) throws {
        guard layout.count > 0 else { throw EvolutionError.invalidExperiment("map-elites needs at least one flat gene (NEAT genomes are not supported)") }
        let axes = try Self.axes(params)
        guard !axes.isEmpty else { throw EvolutionError.invalidExperiment("map-elites needs descriptor axes (experiment.descriptorAxes) and a descriptor() hook") }
        for a in axes where !(a.max > a.min) || a.bins < 1 { throw EvolutionError.invalidExperiment("descriptor axis '\(a.name)': need max > min and bins >= 1") }
        self.layout = layout
        batch = max(1, params.int("batch", population))
        initialRandom = max(1, params.int("initialRandom", population))
        isoSigma = params.double("isoSigma", params.double("mutationSigma", 0.5))
        lineSigma = params.double("lineSigma", 0.2)
        var rng = EvoRNG(seed: seed)
        var cent: [[Double]] = []
        let cvt = params.int("cvt", 0)
        if cvt > 0 { cent = Self.cvtCentroids(axes: axes, k: cvt, rng: &rng) }
        st = State(rng: rng, generation: 0, nextID: 1, archive: EliteArchive(axes: axes), centroids: cent)
    }

    /// Lloyd's k-means over uniform samples in the (normalised) descriptor box.
    static func cvtCentroids(axes: [DescriptorAxis], k: Int, rng: inout EvoRNG) -> [[Double]] {
        let d = axes.count, ns = max(k * 25, 2000)
        let samples = (0..<ns).map { _ in (0..<d).map { _ in rng.nextDouble() } }
        var c = (0..<k).map { _ in samples[rng.int(below: ns)] }
        for _ in 0..<30 {
            var sum = [[Double]](repeating: [Double](repeating: 0, count: d), count: k), cnt = [Int](repeating: 0, count: k)
            for s in samples { let j = nearest(c, s); cnt[j] += 1; for q in 0..<d { sum[j][q] += s[q] } }
            for j in 0..<k where cnt[j] > 0 { c[j] = sum[j].map { $0 / Double(cnt[j]) } }
        }
        return c
    }
    static func nearest(_ c: [[Double]], _ x: [Double]) -> Int {
        var b = 0, bd = Double.infinity
        for (j, p) in c.enumerated() { var s = 0.0; for q in 0..<x.count { let t = p[q] - x[q]; s += t * t }; if s < bd { bd = s; b = j } }
        return b
    }

    func cell(_ d: [Double]) -> Int? {
        if st.centroids.isEmpty { return st.archive.cellIndex(d) }
        guard d.count == st.archive.axes.count, d.allSatisfy(\.isFinite) else { return nil }
        let x = zip(d, st.archive.axes).map { v, a in min(1, max(0, (v - a.min) / (a.max - a.min))) }
        return Self.nearest(st.centroids, x)
    }

    public var generation: Int { st.generation }

    public func ask() throws -> [Genome] {
        var out: [Genome] = []
        let keys = st.archive.cells.keys.sorted()
        let random = st.evaluated < initialRandom || keys.isEmpty
        for _ in 0..<batch {
            var v: [Double], origin: String, parents: [UInt64] = []
            if random {
                v = layout.randomValues(&st.rng); origin = "random"
            } else {
                let a = st.archive.cells[keys[st.rng.int(below: keys.count)]]!.genome
                let b = st.archive.cells[keys[st.rng.int(below: keys.count)]]!.genome
                parents = [a.id, b.id]; origin = "emitter"
                if let h = hooks, let x = try h.crossover(a, b, layout: layout, rng: &st.rng) { v = x }
                else if hooks != nil, let m = try hooks!.mutate(a, layout: layout, rate: isoSigma, rng: &st.rng) { v = m }
                else { v = Operators.isoLine(a.values, b.values, layout: layout, isoSigma: isoSigma, lineSigma: lineSigma, rng: &st.rng) }
                guard v.count == layout.count else { throw EvolutionError.invalidExperiment("hook returned \(v.count) genes, expected \(layout.count)") }
            }
            layout.legalize(&v)
            out.append(Genome(id: st.nextID, values: v, parents: parents, origin: origin, generation: st.generation)); st.nextID += 1
        }
        return out
    }

    public func tell(_ genomes: [Genome], _ fitness: [Fitness]) throws {
        precondition(genomes.count == fitness.count)
        var ins = 0, imp = 0
        for (g, f) in zip(genomes, fitness) {
            guard f.error == nil, let d = f.descriptor, let c = cell(d) else { continue }
            if let e = st.archive.cells[c] {
                if Operators.score(f) > Operators.score(e.fitness) { st.archive.cells[c] = .init(genome: g, fitness: f, generation: st.generation); imp += 1 }
            } else { st.archive.cells[c] = .init(genome: g, fitness: f, generation: st.generation); ins += 1 }
        }
        st.lastInserted = ins; st.lastImproved = imp
        st.evaluated += genomes.count
        st.generation += 1
    }

    public var best: (genome: Genome, fitness: Fitness)? {
        st.archive.cells.values.max { Operators.score($0.fitness) != Operators.score($1.fitness) ? Operators.score($0.fitness) < Operators.score($1.fitness) : $0.genome.id > $1.genome.id }.map { ($0.genome, $0.fitness) }
    }
    public var archive: EliteArchive? { st.archive }
    public var species: [SpeciesInfo] { [] }
    public var diagnostics: [String: Double] {
        let cap = st.centroids.isEmpty ? st.archive.capacity : st.centroids.count
        let qd = st.archive.cells.values.reduce(0.0) { $0 + Operators.score($1.fitness) }
        return ["coverage": Double(st.archive.cells.count) / Double(max(1, cap)), "filled": Double(st.archive.cells.count),
                "qdScore": qd, "inserted": Double(st.lastInserted), "improved": Double(st.lastImproved), "cvt": Double(st.centroids.count)]
    }
    public func saveState() throws -> Data { try AlgorithmState.encode(st) }
    public func restore(_ state: Data) throws { st = try AlgorithmState.decode(State.self, state) }
}
