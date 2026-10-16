// OWNED BY neat-qd builder (algorithms builder). -----------------------------------------------------------
// NEAT (Stanley & Miikkulainen 2002): historical markings (innovation numbers, persistent for the whole run so
// identical structural mutations in different generations share a number), speciation by compatibility
// distance δ = c1·E/N + c2·D/N + c3·W̄, explicit fitness sharing, stagnation culling, per-species elitism,
// crossover of matching (random parent) / disjoint + excess (fitter parent) genes, add-node / add-connection /
// weight / bias / enable-toggle mutations. Feed-forward unless `NEATLayout.recurrent`.
// Params (defaults): compatThreshold (3), c1 (1), c2 (1), c3 (0.4), targetSpecies (0 = fixed threshold,
// otherwise the threshold adapts toward it multiplicatively, at most compatStep/3 (10%) per generation, deadband ±20%, floor 0.1), survivalThreshold (0.2), crossoverRate (0.75),
// weightMutateRate (0.8), weightPerturbSigma (0.5), weightReplaceRate (0.1), weightRange (8), biasMutateRate
// (0.7), addNodeRate (0.03), addConnRate (0.05), disableRate (0.01), interspeciesRate (0.001), stagnation (15),
// elitismPerSpecies (1, for species with ≥ 5 members), initialWeightSigma (1), valueMutationRate (max(1/n,0.1)).
// Co-evolution: `Genome.values` (the layout's flat genes) are crossed uniformly and mutated with gaussian steps
// of GeneSpec.mutationScale; the JS crossover/mutate hooks apply to those flat genes only. The select hook is
// not consulted (NEAT selection is per species).
import Foundation
import PWCore

public final class NEAT: EvolutionAlgorithm {
    public static let kind = "neat"
    public var hooks: (any AlgorithmHooks)?

    struct Species: Codable {
        var id: Int
        var representative: NEATGenome
        var members: [Int] = []          // indices into the evaluated population (transient per tell)
        var bestEver: Double = -.greatestFiniteMagnitude
        var staleness: Int = 0
        var created: Int
    }
    struct State: Codable {
        var rng: EvoRNG; var generation: Int; var nextID: UInt64
        var nextNodeID: Int; var nextInnovation: Int
        var innovations: [String: Int] = [:]
        var splitNodes: [Int: Int] = [:]
        var pending: [Genome] = []
        var species: [Species] = []
        var nextSpeciesID = 1
        var compatThreshold: Double
        var best: Genome?; var bestFit: Fitness?
        var speciesInfo: [SpeciesInfo] = []
        var stagnation = 0
    }
    struct P {
        var c1 = 1.0, c2 = 1.0, c3 = 0.4, targetSpecies = 0, compatStep = 0.3, survival = 0.2, crossoverRate = 0.75
        var wRate = 0.8, wSigma = 0.5, wReplace = 0.1, wRange = 8.0, bRate = 0.7, addNode = 0.03, addConn = 0.05
        var disable = 0.01, interspecies = 0.001, stagnation = 15, elitism = 1, initSigma = 1.0, valueRate = 0.1
    }

    let layout: GenomeLayout, nl: NEATLayout, popSize: Int, p: P
    var st: State
    var nIn: Int { nl.inputs.count }
    var nOut: Int { nl.outputs.count }

    public init(layout: GenomeLayout, params: AlgorithmParams, population: Int, seed: UInt64) throws {
        guard let nl = layout.neat else { throw EvolutionError.invalidExperiment("neat needs a NEAT layout (controller mode 'neat' or genome.neat)") }
        guard !nl.outputs.isEmpty else { throw EvolutionError.invalidExperiment("neat needs at least one output") }
        self.layout = layout; self.nl = nl; popSize = max(2, population)
        var q = P()
        q.c1 = params.double("c1", q.c1); q.c2 = params.double("c2", q.c2); q.c3 = params.double("c3", q.c3)
        q.targetSpecies = params.int("targetSpecies", 0); q.compatStep = params.double("compatStep", q.compatStep)
        q.survival = params.double("survivalThreshold", q.survival); q.crossoverRate = params.double("crossoverRate", q.crossoverRate)
        q.wRate = params.double("weightMutateRate", q.wRate); q.wSigma = params.double("weightPerturbSigma", q.wSigma)
        q.wReplace = params.double("weightReplaceRate", q.wReplace); q.wRange = params.double("weightRange", q.wRange)
        q.bRate = params.double("biasMutateRate", q.bRate)
        q.addNode = params.double("addNodeRate", q.addNode); q.addConn = params.double("addConnRate", q.addConn)
        q.disable = params.double("disableRate", q.disable); q.interspecies = params.double("interspeciesRate", q.interspecies)
        q.stagnation = max(1, params.int("stagnation", q.stagnation)); q.elitism = max(0, params.int("elitismPerSpecies", q.elitism))
        q.initSigma = params.double("initialWeightSigma", q.initSigma)
        q.valueRate = params.double("valueMutationRate", max(1 / Double(max(1, layout.count)), 0.1))
        p = q
        let nIn = nl.inputs.count, nOut = nl.outputs.count
        st = State(rng: EvoRNG(seed: seed), generation: 0, nextID: 1, nextNodeID: nIn + 1 + nOut, nextInnovation: 1,
                   compatThreshold: params.double("compatThreshold", 3))
        // initial population
        var conn: Double = 1
        switch nl.initialConnectivity {
        case "full": conn = 1
        case "none": conn = 0
        default:
            guard let f = Double(nl.initialConnectivity), f >= 0, f <= 1 else { throw EvolutionError.invalidExperiment("neat: initialConnectivity must be full|none|0..1") }
            conn = f
        }
        for _ in 0..<popSize {
            var g = NEATGenome()
            for i in 0..<nIn { g.nodes.append(NEATNode(id: i, kind: .input, activation: "linear")) }
            g.nodes.append(NEATNode(id: nIn, kind: .bias, activation: "linear"))
            for o in 0..<nOut { g.nodes.append(NEATNode(id: nIn + 1 + o, kind: .output, activation: nl.outputActivation)) }
            for f in 0...nIn { for o in 0..<nOut where conn >= 1 || st.rng.nextDouble() < conn {
                let to = nIn + 1 + o
                g.connections.append(NEATConnection(innovation: innovation(f, to), from: f, to: to, weight: st.rng.gaussian() * p.initSigma))
            } }
            g.connections.sort { $0.innovation < $1.innovation }
            st.pending.append(Genome(id: st.nextID, values: layout.randomValues(&st.rng), neat: g, origin: "init", generation: 0))
            st.nextID += 1
        }
    }

    public var generation: Int { st.generation }

    func innovation(_ from: Int, _ to: Int) -> Int {
        let k = "\(from)>\(to)"
        if let i = st.innovations[k] { return i }
        let i = st.nextInnovation; st.nextInnovation += 1; st.innovations[k] = i
        return i
    }

    public func ask() throws -> [Genome] { st.pending }

    // MARK: distance

    func distance(_ a: NEATGenome, _ b: NEATGenome) -> Double {
        let ca = a.connections, cb = b.connections
        var i = 0, j = 0, matching = 0, disjoint = 0, excess = 0, wdiff = 0.0
        let maxA = ca.last?.innovation ?? 0, maxB = cb.last?.innovation ?? 0
        while i < ca.count || j < cb.count {
            if i < ca.count && j < cb.count {
                if ca[i].innovation == cb[j].innovation { matching += 1; wdiff += abs(ca[i].weight - cb[j].weight); i += 1; j += 1 }
                else if ca[i].innovation < cb[j].innovation { if ca[i].innovation > maxB { excess += 1 } else { disjoint += 1 }; i += 1 }
                else { if cb[j].innovation > maxA { excess += 1 } else { disjoint += 1 }; j += 1 }
            } else if i < ca.count { excess += 1; i += 1 } else { excess += 1; j += 1 }
        }
        // node bias differences count as weight differences for shared hidden/output nodes
        let n = max(ca.count, cb.count)
        let N = n < 20 ? 1.0 : Double(n)
        return p.c1 * Double(excess) / N + p.c2 * Double(disjoint) / N + p.c3 * (matching > 0 ? wdiff / Double(matching) : 0)
    }

    // MARK: tell

    public func tell(_ genomes: [Genome], _ fitness: [Fitness]) throws {
        precondition(genomes.count == fitness.count)
        let scores = fitness.map(Operators.score)
        let prevBest = st.bestFit.map(Operators.score) ?? -.infinity
        for (g, f) in zip(genomes, fitness) where Operators.score(f) > (st.bestFit.map(Operators.score) ?? -.infinity) { st.best = g; st.bestFit = f }
        st.stagnation = (st.bestFit.map(Operators.score) ?? -.infinity) > prevBest ? 0 : st.stagnation + 1

        // 1. speciate
        for k in st.species.indices { st.species[k].members = [] }
        for (i, g) in genomes.enumerated() {
            guard let ng = g.neat else { throw EvolutionError.invalidExperiment("neat: candidate \(g.id) has no NEAT genome") }
            var placed = false
            for k in st.species.indices where distance(ng, st.species[k].representative) < st.compatThreshold {
                st.species[k].members.append(i); placed = true; break
            }
            if !placed {
                st.species.append(Species(id: st.nextSpeciesID, representative: ng, members: [i], created: st.generation))
                st.nextSpeciesID += 1
            }
        }
        st.species.removeAll { $0.members.isEmpty }

        // 2. fitness stats + stagnation
        for k in st.species.indices {
            let b = st.species[k].members.map { scores[$0] }.max()!
            if b > st.species[k].bestEver { st.species[k].bestEver = b; st.species[k].staleness = 0 } else { st.species[k].staleness += 1 }
        }
        let ranked = st.species.indices.sorted { st.species[$0].bestEver != st.species[$1].bestEver ? st.species[$0].bestEver > st.species[$1].bestEver : st.species[$0].id < st.species[$1].id }
        let protected = Set(ranked.prefix(2).map { st.species[$0].id })
        var alive = st.species.filter { $0.staleness < p.stagnation || protected.contains($0.id) }
        if alive.isEmpty { alive = st.species }

        st.speciesInfo = alive.map { s in
            let v = s.members.map { scores[$0] }
            return SpeciesInfo(id: s.id, size: s.members.count, bestFitness: v.max()!, meanFitness: v.reduce(0, +) / Double(v.count), staleness: s.staleness)
        }

        // 3. offspring allocation by shared (adjusted) fitness
        let minS = alive.flatMap { $0.members.map { scores[$0] } }.min()!
        let maxS = alive.flatMap { $0.members.map { scores[$0] } }.max()!
        let span = max(maxS - minS, 1e-12)
        let adj = alive.map { s in s.members.reduce(0.0) { $0 + ((scores[$1] - minS) / span + 0.01) } / Double(s.members.count) }
        let total = adj.reduce(0, +)
        var quota = adj.map { Double(popSize) * $0 / total }
        var counts = quota.map { Int($0) }
        var rem = popSize - counts.reduce(0, +)
        let byFrac = quota.indices.sorted { (quota[$0] - Double(counts[$0])) > (quota[$1] - Double(counts[$1])) || ((quota[$0] - Double(counts[$0])) == (quota[$1] - Double(counts[$1])) && $0 < $1) }
        var fi = 0
        while rem > 0 { counts[byFrac[fi % byFrac.count]] += 1; rem -= 1; fi += 1 }
        quota = []

        // 4. reproduce
        let pools: [[Int]] = alive.map { s in
            let m = s.members.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
            return Array(m.prefix(max(1, Int((Double(m.count) * p.survival).rounded(.up)))))
        }
        var next: [Genome] = []
        for (k, s) in alive.enumerated() {
            var n = counts[k]
            guard n > 0 else { continue }
            let sorted = s.members.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
            if s.members.count >= 5 {
                for i in sorted.prefix(min(p.elitism, n)) {
                    var e = genomes[i]; e.parents = [e.id]; e.id = st.nextID; st.nextID += 1
                    e.origin = "elite"; e.generation = st.generation + 1; e.neat?.species = s.id
                    next.append(e); n -= 1
                }
            }
            let pool = pools[k]
            for _ in 0..<n {
                let ia = pool[st.rng.int(below: pool.count)]
                var child: Genome
                if pool.count > 1 || alive.count > 1, st.rng.nextDouble() < p.crossoverRate {
                    var ib = pool[st.rng.int(below: pool.count)]
                    if alive.count > 1 && st.rng.nextDouble() < p.interspecies {
                        let other = pools[st.rng.int(below: pools.count)]; ib = other[st.rng.int(below: other.count)]
                    }
                    let (fa, fb) = scores[ia] >= scores[ib] ? (ia, ib) : (ib, ia)
                    child = try crossover(genomes[fa], genomes[fb], equal: scores[ia] == scores[ib])
                } else {
                    child = genomes[ia]; child.parents = [genomes[ia].id]; child.origin = "mutation"
                }
                try mutate(&child)
                child.id = st.nextID; st.nextID += 1
                child.generation = st.generation + 1; child.neat?.species = s.id
                next.append(child)
            }
        }

        // 5. new representatives (random member of this generation) + threshold control
        for k in alive.indices {
            let m = alive[k].members
            alive[k].representative = genomes[m[st.rng.int(below: m.count)]].neat!
            alive[k].members = []
        }
        st.species = alive
        if p.targetSpecies > 0 {
            // Damped, scale-free proportional control with a deadband (±max(1, 20% of target)): the threshold is
            // multiplied by exp(rate * clamp(relErr, -1, 1)), rate = compatStep / 3 (default 10%/gen). Species count
            // reacts very non-linearly near the typical weight-only distance, so small relative steps avoid the
            // bang-bang overshoot (1 -> 40+ species) of a fixed ±compatStep rule. Floor 0.1.
            let target = Double(p.targetSpecies)
            let err = (Double(alive.count) - target) / target
            if abs(err) > max(1.0, 0.2 * target) / target {
                st.compatThreshold = max(0.1, st.compatThreshold * exp(p.compatStep / 3 * max(-1, min(1, err))))
            }
        }
        st.pending = next
        st.generation += 1
    }

    // MARK: operators

    func crossover(_ a: Genome, _ b: Genome, equal: Bool) throws -> Genome {
        guard let ga = a.neat, let gb = b.neat else { throw EvolutionError.invalidExperiment("neat: missing NEAT genome") }
        var bmap: [Int: NEATConnection] = [:]
        for c in gb.connections { bmap[c.innovation] = c }
        var conns: [NEATConnection] = []
        for c in ga.connections {
            if let o = bmap[c.innovation] {
                var x = st.rng.nextDouble() < 0.5 ? c : o
                x.enabled = (!c.enabled || !o.enabled) ? st.rng.nextDouble() >= 0.75 : true
                conns.append(x)
            } else { conns.append(c) }
        }
        var nodes = ga.nodes
        if equal {
            // equal fitness: also inherit b's disjoint/excess genes (if their nodes can be added)
            let have = Set(conns.map(\.innovation))
            var nodeIDs = Set(nodes.map(\.id))
            for c in gb.connections where !have.contains(c.innovation) {
                for id in [c.from, c.to] where !nodeIDs.contains(id) { if let n = gb.nodes.first(where: { $0.id == id }) { nodes.append(n); nodeIDs.insert(id) } }
                conns.append(c)
            }
            nodes.sort { $0.id < $1.id }
            conns.sort { $0.innovation < $1.innovation }
            if !nl.recurrent && hasCycle(nodes: nodes, conns: conns) { conns = conns.filter { c in ga.connections.contains { $0.innovation == c.innovation } }; nodes = ga.nodes }
        }
        let bnodes = Dictionary(gb.nodes.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        for i in nodes.indices where nodes[i].kind == .hidden || nodes[i].kind == .output {
            if let o = bnodes[nodes[i].id], st.rng.nextDouble() < 0.5 { nodes[i].bias = o.bias }
        }
        var values = a.values
        if !layout.genes.isEmpty {
            if let h = hooks, let v = try h.crossover(a, b, layout: layout, rng: &st.rng) { values = v }
            else { values = Operators.crossover(.uniform, a.values, b.values, layout: layout, rng: &st.rng) }
        }
        return Genome(id: 0, values: values, neat: NEATGenome(nodes: nodes, connections: conns), parents: [a.id, b.id], origin: "crossover")
    }

    func hasCycle(nodes: [NEATNode], conns: [NEATConnection]) -> Bool {
        var adj: [Int: [Int]] = [:]
        for c in conns where c.enabled { adj[c.from, default: []].append(c.to) }
        var state: [Int: UInt8] = [:]
        func dfs(_ u: Int) -> Bool {
            state[u] = 1
            for v in adj[u] ?? [] {
                if state[v] == 1 { return true }
                if state[v] == nil && dfs(v) { return true }
            }
            state[u] = 2; return false
        }
        for n in nodes where state[n.id] == nil { if dfs(n.id) { return true } }
        return false
    }

    /// Does `from` reach `to` through enabled connections?
    func reaches(_ g: NEATGenome, _ from: Int, _ to: Int) -> Bool {
        if from == to { return true }
        var stack = [from], seen: Set<Int> = [from]
        while let u = stack.popLast() {
            for c in g.connections where c.enabled && c.from == u {
                if c.to == to { return true }
                if seen.insert(c.to).inserted { stack.append(c.to) }
            }
        }
        return false
    }

    func mutate(_ child: inout Genome) throws {
        guard var g = child.neat else { return }
        // weights
        if st.rng.nextDouble() < p.wRate {
            for i in g.connections.indices {
                if st.rng.nextDouble() < p.wReplace { g.connections[i].weight = st.rng.gaussian() * p.initSigma }
                else { g.connections[i].weight += st.rng.gaussian() * p.wSigma }
                g.connections[i].weight = min(max(g.connections[i].weight, -p.wRange), p.wRange)
            }
        }
        if st.rng.nextDouble() < p.bRate {
            for i in g.nodes.indices where g.nodes[i].kind == .hidden || g.nodes[i].kind == .output {
                if st.rng.nextDouble() < p.wReplace { g.nodes[i].bias = st.rng.gaussian() * p.initSigma }
                else { g.nodes[i].bias += st.rng.gaussian() * p.wSigma }
                g.nodes[i].bias = min(max(g.nodes[i].bias, -p.wRange), p.wRange)
            }
        }
        // add connection
        if st.rng.nextDouble() < p.addConn {
            let froms = g.nodes.filter { nl.recurrent || $0.kind != .output }
            let tos = g.nodes.filter { $0.kind == .hidden || $0.kind == .output }
            for _ in 0..<20 where !froms.isEmpty && !tos.isEmpty {
                let f = froms[st.rng.int(below: froms.count)].id, t = tos[st.rng.int(below: tos.count)].id
                if let k = g.connections.firstIndex(where: { $0.from == f && $0.to == t }) {
                    if !g.connections[k].enabled && (nl.recurrent || !reaches(g, t, f)) { g.connections[k].enabled = true; break }
                    continue
                }
                if !nl.recurrent && reaches(g, t, f) { continue }
                g.connections.append(NEATConnection(innovation: innovation(f, t), from: f, to: t, weight: st.rng.gaussian() * p.initSigma))
                g.connections.sort { $0.innovation < $1.innovation }
                break
            }
        }
        // add node (split an enabled connection)
        if st.rng.nextDouble() < p.addNode {
            let enabled = g.connections.indices.filter { g.connections[$0].enabled }
            if !enabled.isEmpty {
                let k = enabled[st.rng.int(below: enabled.count)]
                let c = g.connections[k]
                g.connections[k].enabled = false
                var nid: Int
                if let s = st.splitNodes[c.innovation], !g.nodes.contains(where: { $0.id == s }) { nid = s }
                else { nid = st.nextNodeID; st.nextNodeID += 1; if st.splitNodes[c.innovation] == nil { st.splitNodes[c.innovation] = nid } }
                g.nodes.append(NEATNode(id: nid, kind: .hidden, activation: nl.hiddenActivation))
                g.nodes.sort { $0.id < $1.id }
                g.connections.append(NEATConnection(innovation: innovation(c.from, nid), from: c.from, to: nid, weight: 1))
                g.connections.append(NEATConnection(innovation: innovation(nid, c.to), from: nid, to: c.to, weight: c.weight))
                g.connections.sort { $0.innovation < $1.innovation }
            }
        }
        // toggle enable
        if st.rng.nextDouble() < p.disable, !g.connections.isEmpty {
            let k = st.rng.int(below: g.connections.count)
            if g.connections[k].enabled { g.connections[k].enabled = false }
            else if nl.recurrent || !reaches(g, g.connections[k].to, g.connections[k].from) { g.connections[k].enabled = true }
        }
        child.neat = g
        // flat co-evolved genes
        if !layout.genes.isEmpty {
            if let h = hooks, let v = try h.mutate(child, layout: layout, rate: p.valueRate, rng: &st.rng) { child.values = v }
            else { child.values = Operators.mutate(.gaussian, child.values, layout: layout, rate: p.valueRate, rng: &st.rng) }
            guard child.values.count == layout.count else { throw EvolutionError.invalidExperiment("mutate hook returned \(child.values.count) genes, expected \(layout.count)") }
            layout.legalize(&child.values)
        }
    }

    public var best: (genome: Genome, fitness: Fitness)? { st.best.flatMap { g in st.bestFit.map { (g, $0) } } }
    public var archive: EliteArchive? { nil }
    public var species: [SpeciesInfo] { st.speciesInfo }
    public var diagnostics: [String: Double] {
        let hidden = st.best?.neat?.nodes.filter { $0.kind == .hidden }.count ?? 0
        let conns = st.best?.neat?.connections.filter(\.enabled).count ?? 0
        return ["species": Double(st.species.count), "compatThreshold": st.compatThreshold, "innovations": Double(st.nextInnovation - 1),
                "bestHidden": Double(hidden), "bestConnections": Double(conns), "stagnation": Double(st.stagnation)]
    }
    public func saveState() throws -> Data { try AlgorithmState.encode(st) }
    public func restore(_ state: Data) throws { st = try AlgorithmState.decode(State.self, state) }
}
