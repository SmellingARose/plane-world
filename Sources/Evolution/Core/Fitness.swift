// OWNED BY architect. ------------------------------------------------------------------------------
// Fitness of one candidate (aggregated over its episodes). Algorithms MAXIMISE `total`.
import Foundation
import PWCore

public struct Fitness: Codable, Sendable, Equatable {
    /// Scalar to maximise (after episode aggregation). -inf never: failures get `EvolutionConstants.failedFitness`.
    public var total: Double
    /// Named reward terms ("points"), aggregated like `total`. Order is `ExperimentRuntimeInfo.termNames`.
    public var terms: [String: Double] = [:]
    /// Behaviour descriptor for MAP-Elites / novelty (fixed length per experiment), nil if not defined.
    public var descriptor: [Double]? = nil
    /// Novelty score (filled by novelty search; nil otherwise).
    public var novelty: Double? = nil
    public var episodes: Int = 0
    public var simSeconds: Double = 0
    public var controlTicks: Int = 0
    /// Non-nil when evaluation failed (script exception, timeout, NaN state). Message is user-facing.
    public var error: String? = nil
    public init(total: Double, terms: [String: Double] = [:], descriptor: [Double]? = nil) { self.total = total; self.terms = terms; self.descriptor = descriptor }
    public static func failed(_ msg: String) -> Fitness { var f = Fitness(total: EvolutionConstants.failedFitness); f.error = msg; return f }
}

public enum EvolutionConstants {
    /// Fitness assigned to candidates whose evaluation threw (finite, so sorting/stats stay sane).
    public static let failedFitness = -1e12
    public static let formatVersion = 1
}

public enum EvolutionError: Error, CustomStringConvertible, Sendable {
    case notImplemented(String)
    case invalidExperiment(String)
    case script(ScriptError)
    case io(String)
    public var description: String {
        switch self {
        case .notImplemented(let s): return "not implemented: \(s)"
        case .invalidExperiment(let s): return "invalid experiment: \(s)"
        case .script(let e): return e.description
        case .io(let s): return "I/O: \(s)"
        }
    }
}

/// Order statistics helper (used by run history and charts).
public enum Stats {
    public static func summary(_ xs: [Double]) -> (best: Double, mean: Double, median: Double, worst: Double, std: Double) {
        let v = xs.filter { $0.isFinite && $0 > EvolutionConstants.failedFitness }
        guard !v.isEmpty else { return (0, 0, 0, 0, 0) }
        let s = v.sorted(), n = Double(v.count), mean = v.reduce(0, +) / n
        let med = s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
        let std = (v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n).squareRoot()
        return (s.last!, mean, med, s.first!, std)
    }
}
