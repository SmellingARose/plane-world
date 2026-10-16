// OWNED BY architect. ------------------------------------------------------------------------------
// A Run orchestrates generations: ask → evaluate (parallel) → tell → record history → checkpoint.
// Threading: `start()` runs the loop on a dedicated background Thread (the orchestrator). Algorithms and the
// orchestrator ScriptRuntime are only touched there. UI reads `snapshot()` (lock-protected copies) or
// subscribes to `onGeneration` (called on the orchestrator thread — hop to main yourself).
//
// Checkpoint directory layout (docs/EVOLUTION.md §8.3):
//   <run>/run.json          RunCheckpoint (experiment copy, layout, history, hall of fame, algorithm kind)
//   <run>/algorithm.state   opaque EvolutionAlgorithm.saveState() bytes
//   <run>/archive.json      EliteArchive (MAP-Elites / novelty), if any
import Foundation
import PWCore

public struct GenerationRecord: Codable, Sendable, Equatable {
    public var generation: Int
    public var best: Double, mean: Double, median: Double, worst: Double, std: Double
    /// Per reward term: best-candidate value and population mean.
    public var termsBest: [String: Double] = [:]
    public var termsMean: [String: Double] = [:]
    public var bestGenomeID: UInt64 = 0
    public var failures = 0
    public var firstError: String? = nil
    public var evaluations = 0
    public var wallSeconds = 0.0, simSeconds = 0.0
    public var simsPerSecond = 0.0, simSecondsPerWallSecond = 0.0
    public var speciesCount = 0
    public var archiveCoverage: Double? = nil
    public var diagnostics: [String: Double] = [:]
}

/// Best candidate of a generation (click-to-replay in the UI).
public struct HallOfFameEntry: Codable, Sendable, Equatable {
    public var generation: Int
    public var genome: Genome
    public var fitness: Fitness
}

public struct RunCheckpoint: Codable, Sendable {
    public var formatVersion = EvolutionConstants.formatVersion
    public var runID: String
    public var experiment: ExperimentDocument
    public var craft: CraftDocument
    public var layout: GenomeLayout
    public var termNames: [String]
    public var algorithmKind: String
    public var generation: Int
    public var history: [GenerationRecord]
    public var hallOfFame: [HallOfFameEntry]
    public var savedAt: Date
}

public enum RunState: String, Sendable { case idle, running, stopping, finished, failed }

public final class EvolutionRun: @unchecked Sendable {
    public let runID: String
    public let context: ExperimentContext
    public let evaluator: any Evaluator
    public private(set) var algorithm: any EvolutionAlgorithm
    let orchestratorRuntime: any ScriptRuntime
    public var directory: URL?
    /// Called on the orchestrator thread after each generation.
    public var onGeneration: ((GenerationRecord) -> Void)?
    public var onStateChange: ((RunState, String?) -> Void)?

    private let lock = NSLock()
    private var _history: [GenerationRecord] = []
    private var _hall: [HallOfFameEntry] = []
    private var _state: RunState = .idle
    private var _error: String?
    private var stopFlag = false
    private var thread: Thread?

    /// Build a run. `world` must already be resolved (HeadlessWorld.resolve), `craft` flight-prepared.
    /// `runtimeFactory` defaults to ScriptRuntimes.make(for:) (JS when the bundle has source).
    public init(experiment: ExperimentDocument, craft: CraftDocument, world: HeadlessWorld,
                runID: String = EvolutionRun.newRunID(), directory: URL? = nil,
                runtimeFactory: ScriptRuntimeFactory? = nil, jobs: JobSystem = .shared) throws {
        self.runID = runID
        let factory: ScriptRuntimeFactory = runtimeFactory ?? { ScriptRuntimes.make(for: experiment.scripts) }
        let ctx = try ExperimentContext(experiment: experiment, craft: craft, world: world)
        let rt = factory()
        try rt.compile(experiment.scripts, experiment: experiment)
        try ctx.buildLayout(orchestrator: rt)
        context = ctx; orchestratorRuntime = rt
        evaluator = try SimEvaluator(context: ctx, workers: experiment.workers, jobs: jobs, runtimeFactory: factory)
        var params = experiment.algorithm
        if !experiment.descriptorAxes.isEmpty, params.values["axes"] == nil,
           let data = try? JSONIO.encode(experiment.descriptorAxes, pretty: false), let j = try? JSONIO.decode(JSONValue.self, from: data) {
            params.values["axes"] = j
        }
        algorithm = try AlgorithmRegistry.make(params, layout: ctx.layout, population: experiment.population, seed: EvoRNG.derive(experiment.seed, -100))
        let hookNames: Set<ScriptHook> = [.select, .crossover, .mutate]
        if !rt.definedHooks.isDisjoint(with: hookNames) { algorithm.hooks = JSAlgorithmHooks(runtime: rt) }
        self.directory = directory ?? experiment.runDirectory(runID: runID)
    }

    public static func newRunID() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    // MARK: state access (any thread)
    public var state: RunState { lock.lock(); defer { lock.unlock() }; return _state }
    public var lastError: String? { lock.lock(); defer { lock.unlock() }; return _error }
    public var history: [GenerationRecord] { lock.lock(); defer { lock.unlock() }; return _history }
    public var hallOfFame: [HallOfFameEntry] { lock.lock(); defer { lock.unlock() }; return _hall }
    public var layout: GenomeLayout { context.layout }
    public var termNames: [String] { context.termNames }

    private func setState(_ s: RunState, _ err: String? = nil) {
        lock.lock(); _state = s; if err != nil { _error = err }; lock.unlock()
        onStateChange?(s, err)
    }

    // MARK: stepping
    /// Run exactly one generation synchronously on the calling thread (tests / CLI). Returns its record.
    @discardableResult
    public func runGeneration() throws -> GenerationRecord {
        let gen = algorithm.generation
        let pop = try algorithm.ask()
        guard !pop.isEmpty else { throw EvolutionError.invalidExperiment("algorithm returned an empty population") }
        let fit = evaluator.evaluate(pop, generation: gen, cancel: { [weak self] in self?.stopRequested ?? false })
        try algorithm.tell(pop, fit)
        let rec = record(gen, pop, fit)
        if let d = directory, context.experiment.checkpointEvery > 0, (gen + 1) % context.experiment.checkpointEvery == 0 { try checkpoint(to: d) }
        return rec
    }

    var stopRequested: Bool { lock.lock(); defer { lock.unlock() }; return stopFlag }

    func record(_ gen: Int, _ pop: [Genome], _ fit: [Fitness]) -> GenerationRecord {
        let st = Stats.summary(fit.map(\.total))
        var r = GenerationRecord(generation: gen, best: st.best, mean: st.mean, median: st.median, worst: st.worst, std: st.std)
        let bi = fit.indices.max { fit[$0].total < fit[$1].total } ?? 0
        r.bestGenomeID = pop[bi].id
        r.termsBest = fit[bi].terms
        var names = context.termNames; for f in fit { for k in f.terms.keys where !names.contains(k) { names.append(k) } }
        for k in names {
            let v = fit.compactMap { $0.error == nil ? $0.terms[k] : nil }
            r.termsMean[k] = v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
        }
        r.failures = fit.filter { $0.error != nil }.count
        r.firstError = fit.first { $0.error != nil }?.error
        let es = evaluator.lastStats
        r.evaluations = pop.count; r.wallSeconds = es.wallSeconds; r.simSeconds = es.simSeconds
        r.simsPerSecond = es.simsPerSecond; r.simSecondsPerWallSecond = es.simSecondsPerWallSecond
        r.speciesCount = algorithm.species.count
        r.archiveCoverage = algorithm.archive?.coverage
        r.diagnostics = algorithm.diagnostics
        lock.lock()
        _history.append(r)
        _hall.append(HallOfFameEntry(generation: gen, genome: pop[bi], fitness: fit[bi]))
        lock.unlock()
        onGeneration?(r)
        return r
    }

    /// Start the background loop (until `experiment.generations` reached or `stop()`).
    public func start() {
        lock.lock(); guard _state != .running else { lock.unlock(); return }; stopFlag = false; _state = .running; lock.unlock()
        onStateChange?(.running, nil)
        let t = Thread { [self] in
            let limit = context.experiment.generations
            do {
                while !stopRequested && (limit <= 0 || algorithm.generation < limit) { try runGeneration() }
                if let d = directory { try checkpoint(to: d) }
                setState(stopRequested ? .idle : .finished)
            } catch {
                setState(.failed, "\(error)")
            }
        }
        t.name = "evolution.orchestrator"; t.qualityOfService = .userInitiated; t.stackSize = 8 << 20
        thread = t; t.start()
    }
    /// Request stop; the current generation finishes (candidates not yet started are cancelled).
    public func stop() { lock.lock(); stopFlag = true; if _state == .running { _state = .stopping }; lock.unlock() }

    // MARK: checkpoints
    public func checkpoint(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cp = RunCheckpoint(runID: runID, experiment: context.experiment, craft: context.craft, layout: context.layout,
                               termNames: context.termNames, algorithmKind: context.experiment.algorithm.kind,
                               generation: algorithm.generation, history: history, hallOfFame: hallOfFame, savedAt: Date())
        try JSONIO.write(cp, to: dir.appendingPathComponent("run.json"), pretty: false)
        try algorithm.saveState().write(to: dir.appendingPathComponent("algorithm.state"), options: .atomic)
        if let a = algorithm.archive { try JSONIO.write(a, to: dir.appendingPathComponent("archive.json"), pretty: false) }
    }

    /// Resume from a checkpoint directory. The world is re-resolved by the caller (same rules as a new run).
    public static func resume(from dir: URL, world: HeadlessWorld, runtimeFactory: ScriptRuntimeFactory? = nil, jobs: JobSystem = .shared) throws -> EvolutionRun {
        let cp = try JSONIO.decode(RunCheckpoint.self, file: dir.appendingPathComponent("run.json"))
        let run = try EvolutionRun(experiment: cp.experiment, craft: cp.craft, world: world, runID: cp.runID, directory: dir,
                                   runtimeFactory: runtimeFactory, jobs: jobs)
        guard run.context.layout == cp.layout else { throw EvolutionError.invalidExperiment("genome layout changed since the checkpoint (script or craft edited)") }
        try run.algorithm.restore(Data(contentsOf: dir.appendingPathComponent("algorithm.state")))
        run.lock.lock(); run._history = cp.history; run._hall = cp.hallOfFame; run.lock.unlock()
        return run
    }

    // MARK: export
    /// The craft as decoded for `genome`, with the controller embedded under `extra["evolvedController"]`
    /// (EmbeddedController JSON) so FLY's "autopilot from evolved controller" can fly it.
    public func exportCraft(_ genome: Genome, fitness: Fitness? = nil) throws -> CraftDocument {
        let w = try EvalWorker(context: context, runtime: ScriptRuntimes.make(for: context.experiment.scripts))
        var doc = try w.prepare(genome)
        let ec = EmbeddedController(experimentName: context.experiment.name, runID: runID, mode: context.experiment.controller.mode,
                                    hz: context.experiment.controller.hz, script: context.experiment.scripts, layout: context.layout,
                                    genome: genome, inputNames: context.inputNames, outputNames: context.outputNames,
                                    termNames: context.termNames, mlp: context.experiment.genome.mlp, fitness: fitness?.total)
        let data = try JSONIO.encode(ec, pretty: false)
        doc.name = "\(context.craft.name) (evolved g\(genome.generation))"
        var out = doc
        // CraftDocument has no `extra`; the controller rides on the first part's extra (round-trips through
        // CraftPart.extra unchanged) — EmbeddedController.find(in:) locates it.
        if !out.parts.isEmpty { out.parts[0].extra[EmbeddedController.key] = try JSONIO.decode(JSONValue.self, from: data) }
        return out
    }
}

/// Controller + genome embedded in an exported craft (docs/EVOLUTION.md §8.4).
public struct EmbeddedController: Codable, Sendable, Equatable {
    public static let key = "evolvedController"
    public var version = EvolutionConstants.formatVersion
    public var experimentName: String
    public var runID: String
    public var mode: String
    public var hz: Double
    public var script: ScriptBundle
    public var layout: GenomeLayout
    public var genome: Genome
    public var inputNames: [String]
    public var outputNames: [String]
    public var termNames: [String]
    public var mlp: MLPSpec?
    public var fitness: Double?

    public static func find(in craft: CraftDocument) -> EmbeddedController? {
        for p in craft.parts {
            if let v = p.extra[key], let d = try? JSONIO.encode(v, pretty: false), let c = try? JSONIO.decode(EmbeddedController.self, from: d) { return c }
        }
        return nil
    }
}
