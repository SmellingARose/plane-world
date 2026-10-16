// OWNED BY architect. ------------------------------------------------------------------------------
// Native genome decoders: MLP controller weights and craft design parameters. Both run without JS so the
// common presets are fast; the JS decode()/control() hooks run AFTER these (and may override them).
import Foundation
import PWCore

/// A controller network evaluated every control tick. `forward` must not allocate.
public protocol PolicyNetwork: AnyObject {
    var inputCount: Int { get }
    var outputCount: Int { get }
    func reset()
    func forward(_ x: UnsafePointer<Double>, _ y: UnsafeMutablePointer<Double>)
}

@inline(__always) func activate(_ kind: UInt8, _ x: Double) -> Double {
    switch kind {
    case 1: return max(0, x)
    case 2: return 1 / (1 + exp(-x))
    case 3: return x
    default: return tanh(x)
    }
}
func activationCode(_ s: String) -> UInt8 { switch s { case "relu": 1; case "sigmoid": 2; case "linear": 3; default: 0 } }

/// Fully connected MLP. Weight layout in the genome (contiguous, group "mlp"), per layer L (in → out):
///   W_L row-major [out][in] then b_L [out]. Gene names: "mlp.L.w.o.i", "mlp.L.b.o".
public final class MLPPolicy: PolicyNetwork {
    public let sizes: [Int]
    let hiddenAct: UInt8, outAct: UInt8
    let weights: UnsafeMutablePointer<Double>
    public let weightCount: Int
    let bufA: UnsafeMutablePointer<Double>, bufB: UnsafeMutablePointer<Double>
    public var inputCount: Int { sizes.first ?? 0 }
    public var outputCount: Int { sizes.last ?? 0 }

    public init(sizes: [Int], hiddenActivation: String = "tanh", outputActivation: String = "tanh") {
        precondition(sizes.count >= 2)
        self.sizes = sizes
        hiddenAct = activationCode(hiddenActivation); outAct = activationCode(outputActivation)
        weightCount = Self.parameterCount(sizes)
        weights = .allocate(capacity: max(1, weightCount)); weights.initialize(repeating: 0, count: max(1, weightCount))
        let m = sizes.max() ?? 1
        bufA = .allocate(capacity: m); bufB = .allocate(capacity: m)
        bufA.initialize(repeating: 0, count: m); bufB.initialize(repeating: 0, count: m)
    }
    deinit { weights.deallocate(); bufA.deallocate(); bufB.deallocate() }

    public static func parameterCount(_ sizes: [Int]) -> Int {
        var n = 0; for l in 0..<(sizes.count - 1) { n += sizes[l + 1] * sizes[l] + sizes[l + 1] }; return n
    }
    public static func layout(_ sizes: [Int], range: Double) -> GenomeLayout {
        var g: [GeneSpec] = []; g.reserveCapacity(parameterCount(sizes))
        for l in 0..<(sizes.count - 1) {
            let fanIn = Double(sizes[l]), s = 1 / fanIn.squareRoot()
            for o in 0..<sizes[l + 1] { for i in 0..<sizes[l] {
                g.append(GeneSpec(name: "mlp.\(l).w.\(o).\(i)", min: -range, max: range, initial: nil, sigma: 0.1 * max(s, 0.1), group: "mlp"))
            } }
            for o in 0..<sizes[l + 1] { g.append(GeneSpec(name: "mlp.\(l).b.\(o)", min: -range, max: range, initial: 0, sigma: 0.1, group: "mlp")) }
        }
        return GenomeLayout(genes: g)
    }

    /// Copy weights from a genome slice (no allocation).
    public func load(_ values: UnsafeBufferPointer<Double>) {
        let n = min(values.count, weightCount)
        if n > 0 { weights.update(from: values.baseAddress!, count: n) }
    }
    public func reset() {}
    public func forward(_ x: UnsafePointer<Double>, _ y: UnsafeMutablePointer<Double>) {
        var src = UnsafeMutablePointer(mutating: x), w = weights
        let L = sizes.count - 1
        for l in 0..<L {
            let nIn = sizes[l], nOut = sizes[l + 1]
            let dst = l == L - 1 ? y : (l % 2 == 0 ? bufA : bufB)
            let act = l == L - 1 ? outAct : hiddenAct
            let b = w + nOut * nIn
            for o in 0..<nOut {
                var acc = b[o]; let row = w + o * nIn
                for i in 0..<nIn { acc += row[i] * src[i] }
                dst[o] = activate(act, acc)
            }
            w = b + nOut
            src = dst
        }
    }
}

/// Applies design genes to a craft document (native, before the JS decode hook).
public enum DesignDecoder {
    public static func layout(_ genes: [DesignGene]) -> GenomeLayout {
        GenomeLayout(genes: genes.map { GeneSpec(name: $0.geneName, kind: $0.kind, min: $0.min, max: $0.max, initial: $0.initial, group: "design") })
    }

    static func matches(_ p: CraftPart, _ sel: String) -> Bool {
        if sel.hasSuffix("*") { let pre = String(sel.dropLast()); return p.id.hasPrefix(pre) || p.name.hasPrefix(pre) }
        return p.id == sel || p.name == sel
    }

    /// Returns a modified copy. `values` are the design genes in `genes` order (already legalised).
    public static func apply(_ genes: [DesignGene], values: ArraySlice<Double>, to doc: CraftDocument) throws -> CraftDocument {
        var d = doc
        var removed = Set<String>()
        for (k, g) in genes.enumerated() {
            let v = values[values.startIndex + k]
            var hit = false
            for i in d.parts.indices {
                let p = d.parts[i]
                let direct = matches(p, g.part), mirrored = g.mirror.contains(p.name) || g.mirror.contains(p.id)
                guard direct || mirrored else { continue }
                hit = true
                let val = (mirrored && !direct && g.field == "pos.2") ? -v : v
                try set(&d.parts[i], field: g.field, value: val, removed: &removed)
            }
            if !hit { throw EvolutionError.invalidExperiment("design gene '\(g.geneName)': no part matches '\(g.part)'") }
        }
        if !removed.isEmpty {
            d.parts.removeAll { removed.contains($0.id) }
            for i in d.parts.indices {
                if let s = d.parts[i].servo, removed.contains(s) { d.parts[i].servo = nil }
                if let m = d.parts[i].motor, removed.contains(m) { d.parts[i].motor = nil }
            }
        }
        return d
    }

    static func set(_ p: inout CraftPart, field: String, value v: Double, removed: inout Set<String>) throws {
        if field == "mass" { p.mass = max(0, v); return }
        if field == "enabled" { if v < 0.5 { removed.insert(p.id) }; return }
        if field.hasPrefix("p.") { p.p[String(field.dropFirst(2))] = .number(v); return }
        let comps = field.split(separator: ".")
        if comps.count == 2, let i = Int(comps[1]), (0..<3).contains(i) {
            if comps[0] == "pos" { while p.pos.count < 3 { p.pos.append(0) }; p.pos[i] = v; return }
            if comps[0] == "rot" { while p.rot.count < 3 { p.rot.append(0) }; p.rot[i] = v; return }
        }
        throw EvolutionError.invalidExperiment("design gene field '\(field)' not understood (mass | enabled | p.<key> | pos.N | rot.N)")
    }
}
