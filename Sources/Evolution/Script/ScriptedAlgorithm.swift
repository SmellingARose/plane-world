// OWNED BY script builder. ---------------------------------------------------------------------------
// (1) `ScriptedAlgorithm` — algorithm kind "script": the user's JS ask()/tell() implement the whole optimiser
//     (docs/EVOLUTION.md §4.6). Registered in AlgorithmRegistry.extra["script"] the first time any
//     JSScriptRuntime compiles (and by the evolution-js self-tests).
// (2) `JSAlgorithmHooks` — AlgorithmHooks backed by JS select()/crossover()/mutate() on the orchestrator
//     JSContext. Both run only on the Run's orchestrator thread.
//
// Where the script source comes from: AlgorithmRegistry factories only receive (layout, params, population,
// seed). The source is taken from `params.values["source"]` when present, otherwise from the script the calling
// thread compiled last (EvolutionRun.init compiles the orchestrator runtime on the same thread right before it
// builds the algorithm; resume does the same).
//
// JS signatures (extension of §4.6: a 4th `info` argument):
//   function ask(state, layout, rng, info) { return [values, ...]; }   info = { generation, population, params }
//   function tell(state, population, rng) {}   population = [{ id, values, fitness, terms, descriptor, error }]
// `state` must be JSON-serialisable. It is re-parsed from its JSON text before every call, so a resumed run sees
// exactly what a live run sees (bit-identical continuation).
import Foundation
import PWCore

public final class JSAlgorithmHooks: AlgorithmHooks {
    let rt: JSScriptRuntime?
    public init(runtime: any ScriptRuntime) { rt = runtime as? JSScriptRuntime }
    public func select(population: [Genome], fitness: [Fitness], count: Int, rng: inout EvoRNG) throws -> [Int]? {
        try rt?.select(population: population, fitness: fitness, count: count, rng: &rng)
    }
    public func crossover(_ a: Genome, _ b: Genome, layout: GenomeLayout, rng: inout EvoRNG) throws -> [Double]? {
        try rt?.crossover(a, b, layout: layout, rng: &rng)
    }
    public func mutate(_ g: Genome, layout: GenomeLayout, rate: Double, rng: inout EvoRNG) throws -> [Double]? {
        try rt?.mutate(g, layout: layout, rate: rate, rng: &rng)
    }
}

public final class ScriptedAlgorithm: EvolutionAlgorithm {
    public static let kind = "script"
    struct State: Codable {
        var rng: EvoRNG; var generation: Int; var nextID: UInt64
        var best: Genome?; var bestFit: Fitness?
        var js: String
        var lastBest: Double?
        var lastCount: Int
    }
    let layout: GenomeLayout, popSize: Int, params: AlgorithmParams
    let runtime: JSScriptRuntime
    var st: State
    public var hooks: (any AlgorithmHooks)?

    public init(layout: GenomeLayout, params: AlgorithmParams, population: Int, seed: UInt64) throws {
        self.layout = layout; self.params = params; popSize = max(1, population)
        var bundle: ScriptBundle, exp: ExperimentDocument
        if let src = params.values["source"]?.string {
            bundle = ScriptBundle(); bundle.source = src; exp = ExperimentDocument()
        } else if let box = Thread.current.threadDictionary["PWEvolution.lastCompiledScript"] as? CompiledScriptBox {
            bundle = box.bundle; exp = box.experiment
        } else {
            throw EvolutionError.invalidExperiment("algorithm 'script' needs JavaScript ask()/tell() in the experiment script")
        }
        runtime = JSScriptRuntime()
        try runtime.compile(bundle, experiment: exp)
        guard runtime.definedHooks.contains(.ask), runtime.definedHooks.contains(.tell) else {
            throw EvolutionError.invalidExperiment("algorithm 'script' needs both ask(state, layout, rng, info) and tell(state, population, rng) in the script")
        }
        st = State(rng: EvoRNG(seed: seed), generation: 0, nextID: 1, best: nil, bestFit: nil, js: "{}", lastBest: nil, lastCount: 0)
    }

    public var generation: Int { st.generation }

    struct Info: Encodable { var generation: Int; var population: Int; var params: [String: JSONValue] }

    public func ask() throws -> [Genome] {
        let info = String(decoding: try JSONIO.encode(Info(generation: st.generation, population: popSize, params: params.values.filter { $0.key != "source" }), pretty: false), as: UTF8.self)
        let (newState, vectors) = try runtime.ask(state: st.js, layout: layout, info: info, rng: &st.rng)
        var out: [Genome] = []
        for (i, v) in vectors.enumerated() {
            guard v.count == layout.count else {
                throw EvolutionError.script(ScriptError(hook: "ask", message: "ask() candidate \(i) has \(v.count) genes, layout has \(layout.count)"))
            }
            var x = v; layout.legalize(&x)
            out.append(Genome(id: st.nextID, values: x, origin: "script", generation: st.generation)); st.nextID += 1
        }
        st.js = newState
        return out
    }

    public func tell(_ genomes: [Genome], _ fitness: [Fitness]) throws {
        st.js = try runtime.tell(state: st.js, population: genomes, fitness: fitness, rng: &st.rng)
        for (g, f) in zip(genomes, fitness) where f.error == nil && f.total > (st.bestFit?.total ?? -.infinity) { st.best = g; st.bestFit = f }
        st.lastBest = fitness.map(\.total).max(); st.lastCount = genomes.count
        st.generation += 1
    }

    public var best: (genome: Genome, fitness: Fitness)? { st.best.flatMap { g in st.bestFit.map { (g, $0) } } }
    public var archive: EliteArchive? { nil }
    public var species: [SpeciesInfo] { [] }
    public var diagnostics: [String: Double] {
        var d: [String: Double] = ["stateBytes": Double(st.js.utf8.count), "candidates": Double(st.lastCount)]
        if let b = st.lastBest { d["generationBest"] = b }
        return d
    }
    public func saveState() throws -> Data { try AlgorithmState.encode(st) }
    public func restore(_ state: Data) throws { st = try AlgorithmState.decode(State.self, state) }
}

public enum ScriptedAlgorithmRegistration {
    /// Runs once per process (thread-safe lazy static).
    static let once: Void = {
        AlgorithmRegistry.extra[ScriptedAlgorithm.kind] = { try ScriptedAlgorithm(layout: $0, params: $1, population: $2, seed: $3) }
    }()
    public static func register() { _ = once }
}
