// OWNED BY architect. ------------------------------------------------------------------------------
// Ask/tell optimiser contract. Every built-in (GA, NEAT, CMA-ES family, MAP-Elites, novelty) and the JS
// "custom algorithm" adapter implement `EvolutionAlgorithm`. The Run calls, once per generation:
//     let pop = try algo.ask()                 // candidates to evaluate (any count >= 1)
//     let fit = evaluator.evaluate(pop, ...)   // same order, same count
//     try algo.tell(pop, fit)
// Algorithms run on the Run's orchestrator thread only (never concurrently with themselves).
// Determinism: algorithms draw randomness ONLY from the EvoRNG they were given (state is checkpointed).
import Foundation
import PWCore

public protocol EvolutionAlgorithm: AnyObject {
    /// Registry key, e.g. "ga".
    static var kind: String { get }
    init(layout: GenomeLayout, params: AlgorithmParams, population: Int, seed: UInt64) throws
    /// Generations completed (number of `tell` calls).
    var generation: Int { get }
    func ask() throws -> [Genome]
    func tell(_ genomes: [Genome], _ fitness: [Fitness]) throws
    /// Best ever (genome, fitness) — for MAP-Elites the best elite.
    var best: (genome: Genome, fitness: Fitness)? { get }
    /// Quality-diversity archive (MAP-Elites, novelty) — nil for others.
    var archive: EliteArchive? { get }
    /// NEAT species summary — empty for others.
    var species: [SpeciesInfo] { get }
    /// Algorithm-specific numbers for the UI (e.g. "sigma", "mutationRate", "stagnation").
    var diagnostics: [String: Double] { get }
    /// Custom operator overrides (JS select/crossover/mutate). The algorithm consults them where it has
    /// the corresponding step; nil hooks / nil results mean "use built-in".
    var hooks: (any AlgorithmHooks)? { get set }
    /// Opaque checkpoint of the full internal state, including RNG. `restore` on a freshly-initialised
    /// instance with the same layout/params must continue bit-identically.
    func saveState() throws -> Data
    func restore(_ state: Data) throws
}

/// Optional user operators (implemented by the script runtime on the orchestrator thread). Each returns nil
/// to defer to the built-in operator.
public protocol AlgorithmHooks: AnyObject {
    /// Pick `count` parent indices from the evaluated population.
    func select(population: [Genome], fitness: [Fitness], count: Int, rng: inout EvoRNG) throws -> [Int]?
    func crossover(_ a: Genome, _ b: Genome, layout: GenomeLayout, rng: inout EvoRNG) throws -> [Double]?
    func mutate(_ g: Genome, layout: GenomeLayout, rate: Double, rng: inout EvoRNG) throws -> [Double]?
}

/// MAP-Elites style archive. Cells are keyed by flattened bin index.
public struct EliteArchive: Codable, Sendable, Equatable {
    public var axes: [DescriptorAxis]
    public var cells: [Int: Elite] = [:]
    /// Novelty archive members (behaviour descriptors only) for novelty search.
    public var noveltyPoints: [[Double]] = []
    public init(axes: [DescriptorAxis]) { self.axes = axes }
    public struct Elite: Codable, Sendable, Equatable {
        public var genome: Genome
        public var fitness: Fitness
        public var generation: Int
        public init(genome: Genome, fitness: Fitness, generation: Int) { self.genome = genome; self.fitness = fitness; self.generation = generation }
    }
    public var capacity: Int { axes.reduce(1) { $0 * max(1, $1.bins) } }
    public var coverage: Double { Double(cells.count) / Double(max(1, capacity)) }
    /// Flattened cell index of a descriptor (nil if wrong length / NaN). Row-major, axis 0 slowest.
    public func cellIndex(_ d: [Double]) -> Int? {
        guard d.count == axes.count else { return nil }
        var idx = 0
        for (a, x) in zip(axes, d) {
            guard x.isFinite else { return nil }
            let b = max(1, a.bins)
            let t = (x - a.min) / max(1e-12, a.max - a.min)
            idx = idx * b + min(b - 1, max(0, Int(t * Double(b))))
        }
        return idx
    }
    public func coordinates(of cell: Int) -> [Int] {
        var c = [Int](repeating: 0, count: axes.count), r = cell
        for i in stride(from: axes.count - 1, through: 0, by: -1) { let b = max(1, axes[i].bins); c[i] = r % b; r /= b }
        return c
    }
}

public struct SpeciesInfo: Codable, Sendable, Equatable {
    public var id: Int
    public var size: Int
    public var bestFitness: Double
    public var meanFitness: Double
    public var staleness: Int
    public init(id: Int, size: Int, bestFitness: Double, meanFitness: Double, staleness: Int) {
        self.id = id; self.size = size; self.bestFitness = bestFitness; self.meanFitness = meanFitness; self.staleness = staleness
    }
}

/// Kind → factory. Builders add their types to `builtins` (one line each).
public enum AlgorithmRegistry {
    public typealias Factory = (GenomeLayout, AlgorithmParams, Int, UInt64) throws -> any EvolutionAlgorithm
    public static let builtins: [String: Factory] = [
        RandomSearch.kind: { try RandomSearch(layout: $0, params: $1, population: $2, seed: $3) },
        SimpleES.kind: { try SimpleES(layout: $0, params: $1, population: $2, seed: $3) },
        ClassicGA.kind: { try ClassicGA(layout: $0, params: $1, population: $2, seed: $3) },
        CMAES.kind: { try CMAES(layout: $0, params: $1, population: $2, seed: $3) },
        SeparableCMAES.kind: { try SeparableCMAES(layout: $0, params: $1, population: $2, seed: $3) },
        OpenAIES.kind: { try OpenAIES(layout: $0, params: $1, population: $2, seed: $3) },
        NEAT.kind: { try NEAT(layout: $0, params: $1, population: $2, seed: $3) },
        MAPElites.kind: { try MAPElites(layout: $0, params: $1, population: $2, seed: $3) },
        NoveltySearch.kind: { try NoveltySearch(layout: $0, params: $1, population: $2, seed: $3) },
    ]
    /// Extra factories registered at runtime (e.g. "script" by the script runtime).
    nonisolated(unsafe) public static var extra: [String: Factory] = [:]
    public static var kinds: [String] { (Array(builtins.keys) + Array(extra.keys)).sorted() }
    public static func make(_ params: AlgorithmParams, layout: GenomeLayout, population: Int, seed: UInt64) throws -> any EvolutionAlgorithm {
        guard let f = extra[params.kind] ?? builtins[params.kind] else { throw EvolutionError.invalidExperiment("unknown algorithm '\(params.kind)' (known: \(kinds.joined(separator: ", ")))") }
        return try f(layout, params, population, seed)
    }
}

/// Shared Codable checkpoint helper for algorithms whose state is a Codable struct.
public enum AlgorithmState {
    public static func encode<T: Encodable>(_ v: T) throws -> Data { try JSONIO.encode(v, pretty: false) }
    public static func decode<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T { try JSONIO.decode(t, from: d) }
}
