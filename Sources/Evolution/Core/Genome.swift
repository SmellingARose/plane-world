// OWNED BY architect. ------------------------------------------------------------------------------
// Genome representation shared by every algorithm, the evaluator and the script runtime.
//  * A Genome is a flat Double vector (`values`) described by a `GenomeLayout` (one GeneSpec per value),
//    plus an optional structured NEAT genome (`neat`) for topology-evolving algorithms.
//  * Algorithms only ever see the layout + vectors; what the genes MEAN is decided by the experiment's
//    genome source (MLP weights, design parameters, script-defined genes) — see docs/EVOLUTION.md §3.
import Foundation
import PWCore

public enum GeneKind: String, Codable, Sendable { case real, int, bool }

public struct GeneSpec: Codable, Sendable, Equatable {
    public var name: String
    public var kind: GeneKind = .real
    public var min: Double = -1
    public var max: Double = 1
    /// Initial value; nil = uniform in [min, max] (real/int) or 50 % (bool).
    public var initial: Double? = nil
    /// Mutation scale hint (absolute). nil = 10 % of (max - min).
    public var sigma: Double? = nil
    /// Free-form group label ("mlp", "design", "script", ...) used by co-evolution and the UI.
    public var group: String = "script"
    public init(name: String, kind: GeneKind = .real, min: Double = -1, max: Double = 1, initial: Double? = nil, sigma: Double? = nil, group: String = "script") {
        self.name = name; self.kind = kind; self.min = min; self.max = max; self.initial = initial; self.sigma = sigma; self.group = group
    }
    public var mutationScale: Double { sigma ?? Swift.max(1e-9, (max - min) * 0.1) }
    /// Clamp/round a raw value into this gene's domain (bool: >= 0.5 → 1).
    @inlinable public func legalize(_ v: Double) -> Double {
        let x = v.isFinite ? Swift.min(Swift.max(v, min), max) : (initial ?? (min + max) / 2)
        switch kind { case .real: return x; case .int: return x.rounded(); case .bool: return x >= 0.5 ? 1 : 0 }
    }
}

/// NEAT network input/output declaration (topology genes live in NEATGenome).
public struct NEATLayout: Codable, Sendable, Equatable {
    public var inputs: [String]
    public var outputs: [String]
    public var hiddenActivation = "tanh"
    public var outputActivation = "tanh"
    /// "full" (all inputs→outputs), "none", or a fraction "0.5".
    public var initialConnectivity = "full"
    public var recurrent = false
    public init(inputs: [String], outputs: [String]) { self.inputs = inputs; self.outputs = outputs }
}

public struct GenomeLayout: Codable, Sendable, Equatable {
    public var genes: [GeneSpec] = []
    /// Non-nil when genomes carry a NEAT network (NEAT algorithm, or co-evolution with NEAT).
    public var neat: NEATLayout? = nil
    public init(genes: [GeneSpec] = [], neat: NEATLayout? = nil) { self.genes = genes; self.neat = neat }
    public var count: Int { genes.count }
    public func index(of name: String) -> Int? { genes.firstIndex { $0.name == name } }
    public func range(group: String) -> Range<Int>? {
        guard let a = genes.firstIndex(where: { $0.group == group }), let b = genes.lastIndex(where: { $0.group == group }) else { return nil }
        return a..<(b + 1)
    }
    public func legalize(_ v: inout [Double]) { for i in 0..<Swift.min(v.count, genes.count) { v[i] = genes[i].legalize(v[i]) } }
    /// A random genome vector (initial values where given).
    public func randomValues(_ rng: inout EvoRNG) -> [Double] {
        genes.map { g in
            if let i = g.initial { return g.legalize(i) }
            switch g.kind {
            case .bool: return rng.nextDouble() < 0.5 ? 0 : 1
            default: return g.legalize(g.min + (g.max - g.min) * rng.nextDouble())
            }
        }
    }
    public static func + (a: GenomeLayout, b: GenomeLayout) -> GenomeLayout { GenomeLayout(genes: a.genes + b.genes, neat: a.neat ?? b.neat) }
}

// MARK: - NEAT genome (data only; operators live in Algorithms/NEAT.swift)

public enum NEATNodeKind: String, Codable, Sendable { case input, bias, hidden, output }

public struct NEATNode: Codable, Sendable, Equatable {
    public var id: Int
    public var kind: NEATNodeKind
    public var activation: String = "tanh"
    public var bias: Double = 0
    public init(id: Int, kind: NEATNodeKind, activation: String = "tanh", bias: Double = 0) { self.id = id; self.kind = kind; self.activation = activation; self.bias = bias }
}

public struct NEATConnection: Codable, Sendable, Equatable {
    public var innovation: Int
    public var from: Int
    public var to: Int
    public var weight: Double
    public var enabled: Bool = true
    public init(innovation: Int, from: Int, to: Int, weight: Double, enabled: Bool = true) {
        self.innovation = innovation; self.from = from; self.to = to; self.weight = weight; self.enabled = enabled
    }
}

public struct NEATGenome: Codable, Sendable, Equatable {
    /// Node ids: inputs are 0..<nIn, bias is nIn, outputs nIn+1..., hidden afterwards (convention, see EVOLUTION.md §5.2).
    public var nodes: [NEATNode] = []
    public var connections: [NEATConnection] = []
    public var species: Int? = nil
    public init(nodes: [NEATNode] = [], connections: [NEATConnection] = []) { self.nodes = nodes; self.connections = connections }
}

// MARK: - Genome

public struct Genome: Codable, Sendable, Identifiable, Equatable {
    /// Unique within a run (assigned by the algorithm; monotonically increasing).
    public var id: UInt64
    public var values: [Double]
    public var neat: NEATGenome? = nil
    public var parents: [UInt64] = []
    /// How it was made: "init", "mutation", "crossover", "elite", "emitter", "script", ...
    public var origin: String = "init"
    public var generation: Int = 0
    public init(id: UInt64, values: [Double], neat: NEATGenome? = nil, parents: [UInt64] = [], origin: String = "init", generation: Int = 0) {
        self.id = id; self.values = values; self.neat = neat; self.parents = parents; self.origin = origin; self.generation = generation
    }
}
