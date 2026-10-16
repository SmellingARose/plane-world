// OWNED BY architect. ------------------------------------------------------------------------------
// Experiment document (JSON, like crafts and worlds). Saved in
// ~/Library/Application Support/PlaneWorld/experiments/<name>.json. Every field has a default so older /
// hand-written files load; unknown keys are ignored. Schema reference: docs/EVOLUTION.md §8.
import Foundation
import PWCore

/// Where a craft comes from. Resolution order: inline → path → library name.
public struct CraftRef: Codable, Sendable, Equatable {
    public var name: String? = nil          // library craft name (bundled or user)
    public var path: String? = nil          // JSON file (absolute or relative to the experiment file)
    public var inline: CraftDocument? = nil // embedded copy (always written on save so runs are reproducible)
    public init(name: String? = nil, path: String? = nil, inline: CraftDocument? = nil) { self.name = name; self.path = path; self.inline = inline }
}

public struct WorldRef: Codable, Sendable, Equatable {
    /// "current" = snapshot of the world open in the app when the run starts (terrain bake of the live field);
    /// "flat" = flat ground at y = 0, no water; "file" = `path`; "inline" = `inline`.
    public var source: String = "current"
    public var path: String? = nil
    public var inline: WorldDocument? = nil
    public init(source: String = "current") { self.source = source }
}

public struct HeadlessOptions: Codable, Sendable, Equatable {
    public var terrain = true
    public var water = true
    /// Deterministic analytic swell (sum of Gerstner-like sines) instead of the GPU FFT ocean. false = flat sea.
    public var oceanWaves = false
    /// Static obstacles headless (HeadlessObstacles): tree trunks / placed props and breakables. They never move
    /// or break headless; any contact latches crashed. Raycast sensors do not see them.
    public var vegetation = false
    public var breakables = false
    public init() {}
}

/// One design gene: a numeric field of a part (or its presence).
public struct DesignGene: Codable, Sendable, Equatable {
    /// Part id, or part name. Multiple parts: "name*" prefix match (same value applied to all, e.g. mirrored wings).
    public var part: String
    /// "mass" | "pos.0|1|2" | "rot.0|1|2" | "p.<key>" (any numeric param, e.g. "p.span") | "enabled" (bool: part present).
    public var field: String
    public var min: Double
    public var max: Double
    public var kind: GeneKind = .real
    public var initial: Double? = nil
    /// Mirror rule for symmetric parts: names listed here get the same value, with pos.2 negated when field is "pos.2".
    public var mirror: [String] = []
    public init(part: String, field: String, min: Double, max: Double, kind: GeneKind = .real, initial: Double? = nil) {
        self.part = part; self.field = field; self.min = min; self.max = max; self.kind = kind; self.initial = initial
    }
    public var geneName: String { "\(part).\(field)" }
}

public struct MLPSpec: Codable, Sendable, Equatable {
    public var hidden: [Int] = [16]
    public var activation = "tanh"          // tanh | relu | sigmoid | linear
    public var outputActivation = "tanh"
    /// Input names (craft inputs). Empty = all craft inputs in craft order.
    public var inputs: [String] = []
    /// Output names (craft outputs). Empty = all craft outputs.
    public var outputs: [String] = []
    /// Per-input scale applied before the network (name → divisor); missing = 1.
    public var inputScale: [String: Double] = [:]
    public var weightRange = 3.0
    public init() {}
}

public struct GenomeSource: Codable, Sendable, Equatable {
    /// "neural" | "design" | "coevolve" | "script" (script-only genes from genome()).
    public var preset = "neural"
    public var mlp: MLPSpec? = MLPSpec()
    public var design: [DesignGene] = []
    /// NEAT instead of a fixed MLP (requires algorithm "neat").
    public var neat: NEATLayout? = nil
    public init() {}
}

public struct ControllerSpec: Codable, Sendable, Equatable {
    /// "mlp" (native MLP from genome, then optional JS control() post-processing) | "neat" | "script" (JS control() only) | "none".
    public var mode = "mlp"
    /// Control ticks per second (sensors read, controller + reward + terminate called). Physics substeps stay at physicsHz.
    public var hz = 50.0
    public init() {}
}

public struct SpawnSettings: Codable, Sendable, Equatable {
    /// "runway" (resting on the world spawn), "air" (at altitudeAGL with speed), "custom" (position).
    public var mode = "runway"
    public var position: [Double]? = nil
    public var headingDeg = 0.0
    public var altitudeAGL = 0.0
    public var speed = 0.0
    /// Uniform random perturbations per episode (± values).
    public var jitterPosition = 0.0
    public var jitterHeadingDeg = 0.0
    public var jitterSpeed = 0.0
    public var jitterAttitudeDeg = 0.0
    public init() {}
}

public struct WindRandomization: Codable, Sendable, Equatable {
    public var speedMin = 0.0, speedMax = 0.0
    public var directionMinDeg = 0.0, directionMaxDeg = 360.0
    public var turbulence = 0.0
    public init() {}
}

public struct EpisodeSettings: Codable, Sendable, Equatable {
    public var duration = 30.0              // sim seconds
    public var physicsHz = 1000.0           // CraftSim substep rate
    public var episodesPerCandidate = 1
    /// "mean" | "min" | "median" — how per-episode fitness/terms combine.
    public var aggregate = "mean"
    /// Re-use the same episode seeds for every candidate in a generation (fair comparison). false = per candidate.
    public var commonRandomNumbers = true
    public var spawn = SpawnSettings()
    public var wind = WindRandomization()
    /// Built-in termination (before the script's terminate()): crash, NaN, leaving the baked terrain bounds.
    public var stopOnCrash = true
    public var crashSpeed = 8.0
    public init() {}
}

public struct ScriptBundle: Codable, Sendable, Equatable {
    public var language = "javascript"
    /// One JS source defining any of the hooks in docs/EVOLUTION.md §4.
    public var source = ""
    /// Per-call watchdog budget (ms) for per-tick hooks; whole-episode hooks get 20×.
    public var callBudgetMs = 5.0
    public init() {}
}

public struct AlgorithmParams: Codable, Sendable, Equatable {
    /// Registry kind: "ga", "neat", "cmaes", "sep-cmaes", "simple-es", "openai-es", "map-elites", "novelty", "script", "random".
    public var kind = "simple-es"
    public var values: [String: JSONValue] = [:]
    public init(kind: String = "simple-es", values: [String: JSONValue] = [:]) { self.kind = kind; self.values = values }
    public func double(_ k: String, _ d: Double) -> Double { values[k]?.double ?? d }
    public func int(_ k: String, _ d: Int) -> Int { values[k]?.double.map { Int($0) } ?? d }
    public func string(_ k: String, _ d: String) -> String { values[k]?.string ?? d }
    public func bool(_ k: String, _ d: Bool) -> Bool { values[k]?.double.map { $0 != 0 } ?? d }
}

public struct ExperimentDocument: Codable, Sendable, Equatable {
    public var version = EvolutionConstants.formatVersion
    public var name = "Untitled experiment"
    public var notes = ""
    /// Crafts flown per episode. Exactly one is supported: more than one is rejected by ExperimentContext (multi-craft episodes not implemented).
    public var crafts: [CraftRef] = []
    public var world = WorldRef()
    public var headless = HeadlessOptions()
    public var genome = GenomeSource()
    public var controller = ControllerSpec()
    public var algorithm = AlgorithmParams()
    public var population = 64
    /// 0 = run until stopped.
    public var generations = 100
    public var episode = EpisodeSettings()
    public var seed: UInt64 = 1
    public var scripts = ScriptBundle()
    /// Reward term names in display order (the script may add more; extras are appended in first-seen order).
    public var rewardTerms: [String] = []
    /// Behaviour descriptor axes for MAP-Elites (names + ranges + bins). Empty = no archive.
    public var descriptorAxes: [DescriptorAxis] = []
    public var checkpointEvery = 5
    /// Worker threads (0 = JobSystem thread count).
    public var workers = 0
    /// Candidates stepped in lockstep per worker as SIMD lanes (CraftSimBatch): 1 = scalar CraftSim, 2 / 4 / 8 =
    /// batched. Results are bit-identical for every value (docs/PERF.md "Batched lanes"); only speed differs.
    /// The environment variable PW_BATCH_LANES overrides it.
    public var batchLanes = ExperimentDocument.defaultBatchLanes
    /// Default for `batchLanes` (the best measured setting, docs/PERF.md "Batched lanes").
    public static let defaultBatchLanes = 1
    public init() {}

    public init(from d: any Decoder) throws {
        // tolerant decode: every key optional
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = ExperimentDocument()
        func v<T: Decodable>(_ k: CodingKeys, _ dv: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) .flatMap { $0 } ?? dv }
        version = v(.version, def.version); name = v(.name, def.name); notes = v(.notes, def.notes)
        crafts = v(.crafts, def.crafts); world = v(.world, def.world); headless = v(.headless, def.headless)
        genome = v(.genome, def.genome); controller = v(.controller, def.controller); algorithm = v(.algorithm, def.algorithm)
        population = v(.population, def.population); generations = v(.generations, def.generations)
        episode = v(.episode, def.episode); seed = v(.seed, def.seed); scripts = v(.scripts, def.scripts)
        rewardTerms = v(.rewardTerms, def.rewardTerms); descriptorAxes = v(.descriptorAxes, def.descriptorAxes)
        checkpointEvery = v(.checkpointEvery, def.checkpointEvery); workers = v(.workers, def.workers)
        batchLanes = v(.batchLanes, def.batchLanes)
    }

    public static var directory: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlaneWorld/experiments", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    public static func load(_ url: URL) throws -> ExperimentDocument { try JSONIO.decode(ExperimentDocument.self, file: url) }
    public func save(_ url: URL) throws { try JSONIO.write(self, to: url) }
    /// Run directory for checkpoints: experiments/<name>.runs/<runID>/
    public func runDirectory(runID: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        return Self.directory.appendingPathComponent("\(safe).runs/\(runID)", isDirectory: true)
    }
}

public struct DescriptorAxis: Codable, Sendable, Equatable {
    public var name: String
    public var min: Double
    public var max: Double
    public var bins: Int = 20
    public init(name: String, min: Double, max: Double, bins: Int = 20) { self.name = name; self.min = min; self.max = max; self.bins = bins }
}
