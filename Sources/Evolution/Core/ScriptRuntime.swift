// OWNED BY architect. ------------------------------------------------------------------------------
// Script runtime contract. One runtime instance per evaluator worker (and one on the orchestrator thread for
// genome()/algorithm hooks). The JavaScriptCore implementation lives in Script/ (script builder); this file
// also provides `NullScriptRuntime` (no hooks) and `NativeScriptRuntime` (Swift closures, tests/benchmarks).
//
// Call sequence per candidate (see docs/EVOLUTION.md §4 for the JS side):
//   compile(bundle)                                  once per worker
//   genome(base:)                                    once per run (orchestrator)
//   decode(genome:craft:)                            once per candidate (design genes)
//   for each episode:
//     beginEpisode(info, genome, frame)              JS init(ctx)
//     repeat each control tick: tick(frame)          JS control(ctx) → reward(ctx) → terminate(ctx)
//     endEpisode(frame) -> EpisodeOutcome            JS fitness(ctx) + descriptor(ctx)
import Foundation
import PWCore

public struct ScriptError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public var hook: String          // "compile", "control", ...
    public var message: String
    public var line: Int?            // 1-based line in ScriptBundle.source (prelude lines already subtracted)
    public var column: Int?
    public var stack: String?
    public var timedOut = false
    public init(hook: String, message: String, line: Int? = nil, column: Int? = nil, stack: String? = nil, timedOut: Bool = false) {
        self.hook = hook; self.message = message; self.line = line; self.column = column; self.stack = stack; self.timedOut = timedOut
    }
    public var description: String { "\(hook)\(line.map { " line \($0)" } ?? "")\(column.map { ":\($0)" } ?? ""): \(message)" }
}

public enum ScriptHook: String, CaseIterable, Codable, Sendable {
    case genome, terms, decode, `init`, control, reward, terminate, fitness, descriptor
    case select, crossover, mutate          // AlgorithmHooks
    case ask, tell                          // full custom algorithm ("script" kind)
}

/// Static per-run facts handed to scripts (`ctx.info`).
public struct EpisodeInfo: Sendable {
    public var generation = 0, candidate = 0, episode = 0
    public var seed: UInt64 = 0
    public var duration = 0.0, controlDt = 0.02
    public init() {}
}

/// Ground-truth craft state (not sensor readings) refreshed natively every control tick, zero allocation.
/// JS sees it as `ctx.state` (same field names). Angles in degrees; frames as in Physics/Sensors.swift.
public struct CraftStateSnapshot: Sendable {
    public var t = 0.0
    public var x = 0.0, y = 0.0, z = 0.0
    public var vx = 0.0, vy = 0.0, vz = 0.0
    public var pitch = 0.0, roll = 0.0, yaw = 0.0
    public var rollRate = 0.0, pitchRate = 0.0, yawRate = 0.0
    public var airspeed = 0.0, groundSpeed = 0.0, altitude = 0.0, agl = 0.0
    public var aoa = 0.0, sideslip = 0.0, gLoad = 1.0
    public var fuel = 0.0, mass = 0.0, thrust = 0.0
    public var distance = 0.0          // horizontal distance from spawn
    public var crashed = false, contact = false
    public var impactSpeed = 0.0
    public init() {}
    /// Field names in declaration order (JS bridge builds `ctx.state` from these).
    public static let fieldNames = ["t", "x", "y", "z", "vx", "vy", "vz", "pitch", "roll", "yaw", "rollRate", "pitchRate", "yawRate",
                                    "airspeed", "groundSpeed", "altitude", "agl", "aoa", "sideslip", "gLoad", "fuel", "mass", "thrust",
                                    "distance", "crashed", "contact", "impactSpeed"]
}

/// Per-worker, reused buffers for one episode tick. Owned by the episode runner; runtimes read/write in place.
public final class ControlFrame {
    public let inputNames: [String], outputNames: [String], termNames: [String]
    /// Sensor channels (craft inputs order). Read-only for scripts.
    public let inputs: UnsafeMutableBufferPointer<Double>
    /// Output commands (craft outputs order). Pre-filled with the native policy result (mlp/neat) or the
    /// previous tick's values (script mode). Scripts may overwrite. Clamped to output ranges afterwards.
    public let outputs: UnsafeMutableBufferPointer<Double>
    /// Reward deltas for THIS tick (zeroed by the runner before each tick), `termNames` order.
    public let terms: UnsafeMutableBufferPointer<Double>
    /// Running per-episode sums of `terms` (updated by the runner after each tick).
    public let termSums: UnsafeMutableBufferPointer<Double>
    public var state = CraftStateSnapshot()
    public var info = EpisodeInfo()
    public var tick = 0
    public var done = false
    public var doneReason = ""
    public init(inputNames: [String], outputNames: [String], termNames: [String]) {
        self.inputNames = inputNames; self.outputNames = outputNames; self.termNames = termNames
        func buf(_ n: Int) -> UnsafeMutableBufferPointer<Double> {
            let b = UnsafeMutableBufferPointer<Double>.allocate(capacity: max(1, n)); b.initialize(repeating: 0); return UnsafeMutableBufferPointer(rebasing: b[0..<n])
        }
        inputs = buf(inputNames.count); outputs = buf(outputNames.count); terms = buf(termNames.count); termSums = buf(termNames.count)
    }
    deinit {
        for b in [inputs, outputs, terms, termSums] { b.baseAddress.map { UnsafeMutablePointer(mutating: $0).deallocate() } }
    }
}

/// What a finished episode reports. nil fitness → runner uses sum of termSums.
public struct EpisodeOutcome: Sendable {
    public var fitness: Double?
    /// Overrides/additions to the episode's term sums (e.g. terminal bonuses computed in fitness()).
    public var terms: [String: Double] = [:]
    public var descriptor: [Double]?
    public init(fitness: Double? = nil, terms: [String: Double] = [:], descriptor: [Double]? = nil) { self.fitness = fitness; self.terms = terms; self.descriptor = descriptor }
}

public protocol ScriptRuntime: AnyObject {
    /// Compile the bundle (once per worker). Throws ScriptError with line numbers for syntax errors.
    func compile(_ bundle: ScriptBundle, experiment: ExperimentDocument) throws
    /// Hooks the compiled source defines.
    var definedHooks: Set<ScriptHook> { get }
    /// Extend/replace the native genome layout (JS genome(base)). Default: return `base`.
    func genome(base: GenomeLayout) throws -> GenomeLayout
    /// Term names (JS terms() or experiment.rewardTerms). Called once per run before any episode.
    func termNames(default: [String]) throws -> [String]
    /// Modify the craft for a genome (after native DesignDecoder). Default: return `craft`.
    func decode(genome: Genome, layout: GenomeLayout, craft: CraftDocument) throws -> CraftDocument
    func beginEpisode(genome: Genome, frame: ControlFrame) throws
    /// control → reward → terminate for one control tick. Sets frame.done to stop the episode early.
    func tick(_ frame: ControlFrame) throws
    func endEpisode(_ frame: ControlFrame) throws -> EpisodeOutcome
}

public typealias ScriptRuntimeFactory = () -> any ScriptRuntime

public enum ScriptRuntimes {
    /// Factory for runtimes executing ScriptBundle.source. Set to the JavaScriptCore runtime
    /// (Script/JSScriptRuntime.swift) — empty sources always use NullScriptRuntime.
    public static func make(for bundle: ScriptBundle) -> any ScriptRuntime {
        bundle.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NullScriptRuntime() : JSScriptRuntime()
    }
}

/// No script: native policy only, no rewards (fitness = 0 unless terms come from elsewhere).
public final class NullScriptRuntime: ScriptRuntime {
    var terms: [String] = []
    public init() {}
    public func compile(_ bundle: ScriptBundle, experiment: ExperimentDocument) throws { terms = experiment.rewardTerms }
    public var definedHooks: Set<ScriptHook> { [] }
    public func genome(base: GenomeLayout) throws -> GenomeLayout { base }
    public func termNames(default d: [String]) throws -> [String] { d }
    public func decode(genome: Genome, layout: GenomeLayout, craft: CraftDocument) throws -> CraftDocument { craft }
    public func beginEpisode(genome: Genome, frame: ControlFrame) throws {}
    public func tick(_ frame: ControlFrame) throws {}
    public func endEpisode(_ frame: ControlFrame) throws -> EpisodeOutcome { EpisodeOutcome() }
}

/// Swift-closure runtime (tests, benchmarks, built-in presets that need no JS). Closures must be pure
/// functions of their arguments (+ frame) to keep determinism.
public final class NativeScriptRuntime: ScriptRuntime {
    public var terms: [String]
    public var onBegin: ((Genome, ControlFrame) -> Void)?
    public var onTick: ((ControlFrame) -> Void)?
    public var onEnd: ((ControlFrame) -> EpisodeOutcome)?
    public var onDecode: ((Genome, GenomeLayout, CraftDocument) -> CraftDocument)?
    public var onGenome: ((GenomeLayout) -> GenomeLayout)?
    public init(terms: [String] = []) { self.terms = terms }
    public func compile(_ bundle: ScriptBundle, experiment: ExperimentDocument) throws {}
    public var definedHooks: Set<ScriptHook> {
        var s = Set<ScriptHook>()
        if onTick != nil { s.formUnion([.control, .reward, .terminate]) }
        if onEnd != nil { s.insert(.fitness) }; if onDecode != nil { s.insert(.decode) }; if onGenome != nil { s.insert(.genome) }
        return s
    }
    public func genome(base: GenomeLayout) throws -> GenomeLayout { onGenome?(base) ?? base }
    public func termNames(default d: [String]) throws -> [String] { terms.isEmpty ? d : terms }
    public func decode(genome: Genome, layout: GenomeLayout, craft: CraftDocument) throws -> CraftDocument { onDecode?(genome, layout, craft) ?? craft }
    public func beginEpisode(genome: Genome, frame: ControlFrame) throws { onBegin?(genome, frame) }
    public func tick(_ frame: ControlFrame) throws { onTick?(frame) }
    public func endEpisode(_ frame: ControlFrame) throws -> EpisodeOutcome { onEnd?(frame) ?? EpisodeOutcome() }
}
