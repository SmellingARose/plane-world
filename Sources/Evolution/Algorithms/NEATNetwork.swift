// OWNED BY neat-qd builder (algorithms builder). -----------------------------------------------------------
// Phenotype of a NEATGenome used by the episode runner when controller.mode == "neat" (and by the FLY
// autopilot). Compiled once per candidate; `forward` is allocation-free (flat preallocated buffers).
// Feed-forward: nodes evaluated in topological order of enabled connections (nodes caught in a cycle are
// evaluated afterwards in id order using their previous value for the back edge).
// Recurrent (layout.recurrent): one synchronous update of every non-input node per call.
import Foundation
import PWCore

public final class NEATNetwork: PolicyNetwork {
    public let inputCount: Int
    public let outputCount: Int
    let nodeCount: Int
    let recurrent: Bool
    // node arrays (indexed by compact node index)
    let values: UnsafeMutablePointer<Double>
    let scratch: UnsafeMutablePointer<Double>
    let bias: UnsafeMutablePointer<Double>
    let act: UnsafeMutablePointer<UInt8>
    // evaluation order (compact indices of non-input nodes) and CSR incoming edges per order slot
    let order: UnsafeMutablePointer<Int32>
    let orderCount: Int
    let edgeStart: UnsafeMutablePointer<Int32>   // orderCount + 1
    let edgeFrom: UnsafeMutablePointer<Int32>
    let edgeW: UnsafeMutablePointer<Double>
    let inputIdx: UnsafeMutablePointer<Int32>
    let outputIdx: UnsafeMutablePointer<Int32>
    let biasIdx: Int

    public init(genome: NEATGenome, layout: NEATLayout) throws {
        let nIn = layout.inputs.count, nOut = layout.outputs.count
        inputCount = nIn; outputCount = nOut; recurrent = layout.recurrent
        var index: [Int: Int] = [:]
        var nodes = genome.nodes
        // make sure the canonical input/bias/output nodes exist
        func ensure(_ id: Int, _ k: NEATNodeKind, _ a: String) { if !nodes.contains(where: { $0.id == id }) { nodes.append(NEATNode(id: id, kind: k, activation: a)) } }
        for i in 0..<nIn { ensure(i, .input, "linear") }
        ensure(nIn, .bias, "linear")
        for o in 0..<nOut { ensure(nIn + 1 + o, .output, layout.outputActivation) }
        nodes.sort { $0.id < $1.id }
        for (i, n) in nodes.enumerated() {
            guard index[n.id] == nil else { throw EvolutionError.invalidExperiment("NEAT genome has duplicate node id \(n.id)") }
            index[n.id] = i
        }
        nodeCount = nodes.count
        values = .allocate(capacity: nodeCount); values.initialize(repeating: 0, count: nodeCount)
        scratch = .allocate(capacity: nodeCount); scratch.initialize(repeating: 0, count: nodeCount)
        bias = .allocate(capacity: nodeCount); act = .allocate(capacity: nodeCount)
        for (i, n) in nodes.enumerated() { bias[i] = n.bias; act[i] = activationCode(n.activation) }
        biasIdx = index[nIn]!
        inputIdx = .allocate(capacity: max(1, nIn)); outputIdx = .allocate(capacity: max(1, nOut))
        for i in 0..<nIn { inputIdx[i] = Int32(index[i]!) }
        for o in 0..<nOut { outputIdx[o] = Int32(index[nIn + 1 + o]!) }

        // incoming enabled edges per node
        var incoming = [[(Int, Double)]](repeating: [], count: nodeCount)
        var outgoing = [[Int]](repeating: [], count: nodeCount)
        for c in genome.connections where c.enabled {
            guard let f = index[c.from], let t = index[c.to] else { throw EvolutionError.invalidExperiment("NEAT connection \(c.innovation) references a missing node") }
            if nodes[t].kind == .input || nodes[t].kind == .bias { continue }
            incoming[t].append((f, c.weight)); outgoing[f].append(t)
        }
        let isSource: (Int) -> Bool = { nodes[$0].kind == .input || nodes[$0].kind == .bias }
        var ord: [Int] = []
        if recurrent {
            ord = (0..<nodeCount).filter { !isSource($0) }
        } else {
            // Kahn over non-source nodes (edges from sources are always ready)
            var indeg = [Int](repeating: 0, count: nodeCount)
            for t in 0..<nodeCount where !isSource(t) { indeg[t] = incoming[t].filter { !isSource($0.0) }.count }
            var queue = (0..<nodeCount).filter { !isSource($0) && indeg[$0] == 0 }
            var done = [Bool](repeating: false, count: nodeCount)
            var qi = 0
            while qi < queue.count {
                let u = queue[qi]; qi += 1; ord.append(u); done[u] = true
                for t in outgoing[u] where !isSource(t) { indeg[t] -= 1; if indeg[t] == 0 { queue.append(t) } }
            }
            for u in 0..<nodeCount where !isSource(u) && !done[u] { ord.append(u) }   // cycles: id order
        }
        orderCount = ord.count
        order = .allocate(capacity: max(1, orderCount))
        edgeStart = .allocate(capacity: orderCount + 1)
        let ne = ord.reduce(0) { $0 + incoming[$1].count }
        edgeFrom = .allocate(capacity: max(1, ne)); edgeW = .allocate(capacity: max(1, ne))
        var e = 0
        for (k, u) in ord.enumerated() {
            order[k] = Int32(u); edgeStart[k] = Int32(e)
            for (f, w) in incoming[u] { edgeFrom[e] = Int32(f); edgeW[e] = w; e += 1 }
        }
        edgeStart[orderCount] = Int32(e)
        reset()
    }

    deinit {
        values.deallocate(); scratch.deallocate(); bias.deallocate(); act.deallocate(); order.deallocate()
        edgeStart.deallocate(); edgeFrom.deallocate(); edgeW.deallocate(); inputIdx.deallocate(); outputIdx.deallocate()
    }

    public func reset() {
        values.update(repeating: 0, count: nodeCount)
        values[biasIdx] = 1
    }

    public func forward(_ x: UnsafePointer<Double>, _ y: UnsafeMutablePointer<Double>) {
        for i in 0..<inputCount { values[Int(inputIdx[i])] = x[i] }
        values[biasIdx] = 1
        if recurrent {
            for k in 0..<orderCount {
                let u = Int(order[k])
                var s = bias[u]
                for e in Int(edgeStart[k])..<Int(edgeStart[k + 1]) { s += edgeW[e] * values[Int(edgeFrom[e])] }
                scratch[u] = activate(act[u], s)
            }
            for k in 0..<orderCount { let u = Int(order[k]); values[u] = scratch[u] }
        } else {
            for k in 0..<orderCount {
                let u = Int(order[k])
                var s = bias[u]
                for e in Int(edgeStart[k])..<Int(edgeStart[k + 1]) { s += edgeW[e] * values[Int(edgeFrom[e])] }
                values[u] = activate(act[u], s)
            }
        }
        for o in 0..<outputCount { y[o] = values[Int(outputIdx[o])] }
    }

    /// Convenience (allocates): evaluate one input vector.
    public func evaluate(_ x: [Double]) -> [Double] {
        var y = [Double](repeating: 0, count: outputCount)
        x.withUnsafeBufferPointer { xb in y.withUnsafeMutableBufferPointer { yb in forward(xb.baseAddress!, yb.baseAddress!) } }
        return y
    }
}
