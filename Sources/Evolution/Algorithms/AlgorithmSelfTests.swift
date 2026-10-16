// OWNED BY algorithms builder. Selftests for Sources/Evolution/Algorithms (group "evolution-algo").
//   PlaneWorld --selftest evolution-algo
// Registered from App/main.swift via `AlgorithmSelfTests.register()` (integrator).
import Foundation
import PWCore

public enum AlgorithmSelfTests {
    static func box(_ n: Int, _ lo: Double, _ hi: Double) -> GenomeLayout {
        GenomeLayout(genes: (0..<n).map { GeneSpec(name: "x\($0)", min: lo, max: hi) })
    }
    static func sphere(_ x: [Double]) -> Double { x.reduce(0) { $0 + $1 * $1 } }
    static func rastrigin(_ x: [Double]) -> Double { 10 * Double(x.count) + x.reduce(0) { $0 + $1 * $1 - 10 * cos(2 * .pi * $1) } }
    static func rosenbrock(_ x: [Double]) -> Double {
        var s = 0.0; for i in 0..<(x.count - 1) { let a = x[i + 1] - x[i] * x[i], b = 1 - x[i]; s += 100 * a * a + b * b }; return s
    }

    /// Runs `gens` generations minimising `f`; returns best-so-far (as cost) per generation.
    @discardableResult
    static func minimise(_ a: any EvolutionAlgorithm, gens: Int, _ f: ([Double]) -> Double) throws -> [Double] {
        var hist: [Double] = []
        for _ in 0..<gens {
            let pop = try a.ask()
            try a.tell(pop, pop.map { Fitness(total: -f($0.values)) })
            hist.append(-(a.best?.fitness.total ?? -.infinity))
        }
        return hist
    }

    static func make(_ kind: String, _ layout: GenomeLayout, pop: Int, seed: UInt64 = 7, _ v: [String: JSONValue] = [:]) throws -> any EvolutionAlgorithm {
        try AlgorithmRegistry.make(AlgorithmParams(kind: kind, values: v), layout: layout, population: pop, seed: seed)
    }

    // toy QD problem: descriptor = first two genes, fitness = -sphere
    static let qdAxes = [DescriptorAxis(name: "a", min: -1, max: 1, bins: 20), DescriptorAxis(name: "b", min: -1, max: 1, bins: 20)]
    static func qdParams() throws -> JSONValue { try JSONIO.decode(JSONValue.self, from: try JSONIO.encode(qdAxes, pretty: false)) }
    static func qdEval(_ g: Genome) -> Fitness {
        let v = g.values
        // descriptor: nonlinear, concentrated near the centre for uniform genomes (so random search alone covers poorly)
        return Fitness(total: -sphere(v), terms: [:], descriptor: [v[0] * v[1] * v[2], v[3] * v[4] * v[5]])
    }

    static func xorFitness(_ g: Genome, _ nl: NEATLayout) throws -> (Double, Bool) {
        let net = try NEATNetwork(genome: g.neat!, layout: nl)
        var err = 0.0, ok = true
        for (a, b) in [(0.0, 0.0), (0, 1), (1, 0), (1, 1)] {
            net.reset()
            let y = net.evaluate([a, b])[0], t = (a != b) ? 1.0 : 0.0
            err += (y - t) * (y - t); if (y > 0.5) != (t > 0.5) { ok = false }
        }
        return (4 - err, ok)
    }

    public static func register() {
        SelfTestRegistry.register("evolution-algo", "cmaes-sphere") { ctx in
            for n in [10, 20] {
                let a = try make("cmaes", box(n, -5, 5), pop: 0, ["sigma0": .number(2)])
                let h = try minimise(a, gens: 900, sphere)
                ctx.log("cmaes sphere \(n)D: \(h.last!) after \(h.count) gens, sigma \(a.diagnostics["sigma"] ?? 0)")
                ctx.expect(h.last! < 1e-8, "CMA-ES sphere \(n)D < 1e-8 (got \(h.last!))")
            }
        }
        SelfTestRegistry.register("evolution-algo", "cmaes-rosenbrock") { ctx in
            let a = try make("cmaes", box(10, -5, 5), pop: 0, ["sigma0": .number(1), "restarts": .string("ipop")])
            let h = try minimise(a, gens: 2500, rosenbrock)
            ctx.log("cmaes rosenbrock 10D: \(h.last!)")
            ctx.expect(h.last! < 1e-6, "CMA-ES Rosenbrock 10D < 1e-6 (got \(h.last!))")
        }
        SelfTestRegistry.register("evolution-algo", "cmaes-ipop-rastrigin") { ctx in
            let a = try make("cmaes", box(10, -5.12, 5.12), pop: 0, ["sigma0": .number(2), "restarts": .string("ipop"), "tolFun": .number(1e-9)])
            let h = try minimise(a, gens: 1500, rastrigin)
            let r = a.diagnostics["restarts"] ?? 0
            ctx.log("ipop-cmaes rastrigin 10D: \(h.last!) restarts \(r) lambda \(a.diagnostics["lambda"] ?? 0)")
            ctx.expect(r >= 1, "IPOP restarted at least once")
            ctx.expect(h.last! < 5, "IPOP-CMA-ES Rastrigin 10D < 5 (got \(h.last!))")
            let b = try make("cmaes", box(10, -5.12, 5.12), pop: 0, ["sigma0": .number(2), "restarts": .string("bipop")])
            let hb = try minimise(b, gens: 1500, rastrigin)
            ctx.log("bipop-cmaes rastrigin 10D: \(hb.last!) restarts \(b.diagnostics["restarts"] ?? 0)")
            ctx.expect((b.diagnostics["restarts"] ?? 0) >= 1 && hb.last! < 20, "BIPOP restarts and makes progress")
        }
        SelfTestRegistry.register("evolution-algo", "sep-cmaes-sphere-30d") { ctx in
            let a = try make("sep-cmaes", box(30, -5, 5), pop: 0, ["sigma0": .number(2)])
            let h = try minimise(a, gens: 1500, sphere)
            ctx.log("sep-cmaes sphere 30D: \(h.last!)")
            ctx.expect(h.last! < 1e-8, "sep-CMA-ES sphere 30D < 1e-8 (got \(h.last!))")
            let b = try make("sep-cmaes", box(30, -5, 5), pop: 0, ["sigma0": .number(1)])
            let hr = try minimise(b, gens: 3000, rosenbrock)
            ctx.log("sep-cmaes rosenbrock 30D: \(hr.first!) -> \(hr.last!)")
            ctx.expect(hr.last! < 30, "sep-CMA-ES Rosenbrock 30D progresses (got \(hr.last!))")
        }
        SelfTestRegistry.register("evolution-algo", "openai-es-sphere") { ctx in
            for opt in ["adam", "sgd"] {
                let a = try make("openai-es", box(20, -5, 5), pop: 50, ["optimizer": .string(opt), "lr": .number(opt == "adam" ? 0.1 : 0.02), "sigma": .number(0.3)])
                let h = try minimise(a, gens: 400, sphere)
                let m = (a as! OpenAIES).meanValues
                ctx.log("openai-es(\(opt)) sphere 20D: best \(h.first!) -> \(h.last!), mean \(sphere(m))")
                ctx.expect(sphere(m) < 0.5 && h.last! < h.first! * 0.01, "OpenAI-ES (\(opt)) converges on sphere 20D (mean f = \(sphere(m)))")
            }
        }
        SelfTestRegistry.register("evolution-algo", "ga-benchmarks") { ctx in
            let configs: [[String: JSONValue]] = [
                ["selection": .string("tournament"), "crossover": .string("sbx"), "mutation": .string("polynomial")],
                ["selection": .string("roulette"), "crossover": .string("blend"), "mutation": .string("gaussian"), "adaptive": .bool(true)],
                ["selection": .string("rank"), "crossover": .string("uniform"), "mutation": .string("gaussian")],
                ["selection": .string("tournament"), "crossover": .string("one-point"), "mutation": .string("gaussian"), "adaptive": .bool(true)],
            ]
            for (fname, f, lo, hi) in [("rastrigin", rastrigin as ([Double]) -> Double, -5.12, 5.12), ("sphere", sphere, -5, 5), ("rosenbrock", rosenbrock, -2.048, 2.048)] {
                for c in configs {
                    let a = try make("ga", box(10, lo, hi), pop: 100, c)
                    let h = try minimise(a, gens: 300, f)
                    let mono = zip(h, h.dropFirst()).allSatisfy { $1 <= $0 }
                    ctx.log("ga \(c["selection"]!.string!)/\(c["crossover"]!.string!)/\(c["mutation"]!.string!) \(fname) 10D: \(h.first!) -> \(h.last!)  \(a.diagnostics.map { "\($0.key)=\(String(format: "%.3g", $0.value))" }.sorted().joined(separator: " "))")
                    ctx.expect(mono, "GA best is monotone non-increasing (\(fname))")
                    ctx.expect(h.last! < h.first! * 0.1, "GA improves \(fname) at least 10× (\(h.first!) -> \(h.last!))")
                }
            }
            // bool + int genes stay legal
            let mixed = GenomeLayout(genes: [GeneSpec(name: "b", kind: .bool, min: 0, max: 1), GeneSpec(name: "i", kind: .int, min: 0, max: 10), GeneSpec(name: "r", min: -1, max: 1)])
            let g = try make("ga", mixed, pop: 30)
            try minimise(g, gens: 30) { v in (v[0] == 1 ? 0 : 1) + abs(v[1] - 7) + v[2] * v[2] }
            ctx.expect(g.best!.genome.values[0] == 1 && g.best!.genome.values[1] == 7, "GA solves mixed bool/int problem (\(g.best!.genome.values))")
            for _ in 0..<3 { for x in try g.ask() { ctx.expect((x.values[0] == 0 || x.values[0] == 1) && x.values[1] == x.values[1].rounded(), "legal bool/int genes") } ; let p = try g.ask(); try g.tell(p, p.map { _ in Fitness(total: 0) }) }
        }
        SelfTestRegistry.register("evolution-algo", "neat-xor") { ctx in
            var nl = NEATLayout(inputs: ["a", "b"], outputs: ["y"]); nl.outputActivation = "sigmoid"
            let layout = GenomeLayout(genes: [], neat: nl)
            var solvedAt: Int? = nil, attempts = 0
            for seed in [1, 2, 3] as [UInt64] {
                attempts += 1
                let a = try make("neat", layout, pop: 150, seed: seed)
                for gen in 0..<300 {
                    let pop = try a.ask()
                    var fit: [Fitness] = []
                    for g in pop { let (f, _) = try xorFitness(g, nl); fit.append(Fitness(total: f)) }
                    try a.tell(pop, fit)
                    if let b = a.best, try xorFitness(b.genome, nl).1, b.fitness.total > 3.6 { solvedAt = gen; break }
                }
                let d = a.diagnostics
                ctx.log("neat seed \(seed): solved at gen \(solvedAt.map(String.init) ?? "-"), best \(a.best!.fitness.total), species \(a.species.count), hidden \(d["bestHidden"] ?? 0), conns \(d["bestConnections"] ?? 0)")
                ctx.expect(!a.species.isEmpty, "species reported")
                if solvedAt != nil { break }
            }
            ctx.expect(solvedAt != nil, "NEAT solves XOR within 300 generations (\(attempts) seeds)")
        }
        SelfTestRegistry.register("evolution-algo", "neat-species-control") { ctx in
            // adaptive threshold must settle: after warm-up, species count stays within [target/2, 2*target]
            var nl = NEATLayout(inputs: ["a", "b"], outputs: ["y"]); nl.outputActivation = "sigmoid"
            let layout = GenomeLayout(genes: [], neat: nl)
            let a = try make("neat", layout, pop: 96, seed: 5, ["targetSpecies": .number(8), "stagnation": .number(1000)])  // no stagnation culling: isolate the threshold controller
            var counts: [Int] = []
            for _ in 0..<60 {
                let pop = try a.ask()
                try a.tell(pop, try pop.map { Fitness(total: try xorFitness($0, nl).0) })
                counts.append(a.species.count)
            }
            let tail = Array(counts.dropFirst(20))
            ctx.log("species per gen: \(counts.map(String.init).joined(separator: " "))")
            ctx.expect(tail.allSatisfy { $0 >= 4 && $0 <= 16 }, "species within [4,16] after warm-up (min \(tail.min()!), max \(tail.max()!))")
        }
        SelfTestRegistry.register("evolution-algo", "neat-network") { ctx in
            // hand-built: y = tanh(1*a + hidden), hidden = tanh(2*b), plus a recurrent self-loop variant
            var nl = NEATLayout(inputs: ["a", "b"], outputs: ["y"]); nl.outputActivation = "linear"
            let g = NEATGenome(nodes: [NEATNode(id: 0, kind: .input), NEATNode(id: 1, kind: .input), NEATNode(id: 2, kind: .bias), NEATNode(id: 3, kind: .output, activation: "linear"), NEATNode(id: 4, kind: .hidden, activation: "tanh", bias: 0.5)],
                               connections: [NEATConnection(innovation: 1, from: 0, to: 3, weight: 1), NEATConnection(innovation: 2, from: 1, to: 4, weight: 2), NEATConnection(innovation: 3, from: 4, to: 3, weight: 1), NEATConnection(innovation: 4, from: 2, to: 3, weight: 0.25, enabled: true)])
            let net = try NEATNetwork(genome: g, layout: nl)
            let y = net.evaluate([0.3, -0.2])[0]
            ctx.expectClose(y, 0.3 + tanh(-0.4 + 0.5) + 0.25, tol: 1e-12, "feed-forward NEAT output")
            var rl = nl; rl.recurrent = true
            var rg = g; rg.connections.append(NEATConnection(innovation: 5, from: 3, to: 4, weight: 0.5))
            let rn = try NEATNetwork(genome: rg, layout: rl)
            let y1 = rn.evaluate([1, 0])[0], y2 = rn.evaluate([1, 0])[0]
            ctx.expect(y1 != y2, "recurrent network has state (\(y1), \(y2))")
            rn.reset(); ctx.expectClose(rn.evaluate([1, 0])[0], y1, tol: 1e-12, "reset restores initial state")
            if AllocationCounter.install() {
                var x: [Double] = [0.1, 0.2], out: [Double] = [0]
                let before = AllocationCounter.count
                x.withUnsafeBufferPointer { xb in out.withUnsafeMutableBufferPointer { yb in for _ in 0..<1000 { net.forward(xb.baseAddress!, yb.baseAddress!); rn.forward(xb.baseAddress!, yb.baseAddress!) } } }
                let allocs = AllocationCounter.count - before
                ctx.expect(allocs == 0, "NEATNetwork.forward allocates nothing (\(allocs))")
            } else { ctx.log("allocation hook unavailable — not measured") }
        }
        SelfTestRegistry.register("evolution-algo", "map-elites-coverage") { ctx in
            let layout = box(6, -1, 1)
            let a = try make("map-elites", layout, pop: 100, ["axes": try qdParams()])
            let r = try make("random", layout, pop: 100)
            for _ in 0..<100 {
                let p = try a.ask(); try a.tell(p, p.map(qdEval))
                let q = try r.ask(); try r.tell(q, q.map(qdEval))
            }
            // coverage random search would get with the same budget
            var arch = EliteArchive(axes: qdAxes); var rng = EvoRNG(seed: 99)
            for _ in 0..<10000 { let v = layout.randomValues(&rng); if let c = arch.cellIndex(qdEval(Genome(id: 0, values: v)).descriptor!) { arch.cells[c] = .init(genome: Genome(id: 0, values: v), fitness: Fitness(total: 0), generation: 0) } }
            let cov = a.archive!.coverage
            ctx.log("map-elites coverage \(cov) (random search \(arch.coverage)), qd \(a.diagnostics["qdScore"] ?? 0)")
            ctx.expect(cov > 0.6, "MAP-Elites fills > 60 % of the 2D archive (\(cov))")
            ctx.expect(cov > arch.coverage, "MAP-Elites beats random coverage")
            let cvt = try make("map-elites", layout, pop: 100, ["axes": try qdParams(), "cvt": .number(64)])
            for _ in 0..<50 { let p = try cvt.ask(); try cvt.tell(p, p.map(qdEval)) }
            ctx.log("cvt-map-elites coverage \(cvt.diagnostics["coverage"] ?? 0)")
            ctx.expect((cvt.diagnostics["coverage"] ?? 0) > 0.6, "CVT-MAP-Elites fills > 60 % of 64 centroids")
        }
        SelfTestRegistry.register("evolution-algo", "novelty") { ctx in
            let layout = box(6, -1, 1)
            let a = try make("novelty", layout, pop: 100, ["axes": try qdParams()])
            for _ in 0..<60 { let p = try a.ask(); try a.tell(p, p.map(qdEval)) }
            let d = a.diagnostics
            ctx.log("novelty: archive \(d["archiveSize"] ?? 0), cells \(a.archive!.cells.count), threshold \(d["threshold"] ?? 0), mean novelty \(d["meanNovelty"] ?? 0)")
            ctx.expect((d["archiveSize"] ?? 0) > 20, "novelty archive grows")
            let g = try make("ga", layout, pop: 100)
            var gaArch = EliteArchive(axes: qdAxes)
            for _ in 0..<60 { let p = try g.ask(); let f = p.map(qdEval); try g.tell(p, f); for (x, y) in zip(p, f) { if let c = gaArch.cellIndex(y.descriptor!) { gaArch.cells[c] = .init(genome: x, fitness: y, generation: 0) } } }
            ctx.log("explored cells: novelty \(a.archive!.coverage), fitness-driven GA \(gaArch.coverage)")
            ctx.expect(a.archive!.coverage > 0.6 && a.archive!.coverage > gaArch.coverage, "novelty search explores more of the descriptor space than a fitness GA")
            ctx.expect(a.best?.fitness.novelty != nil, "Fitness.novelty filled")
        }
        SelfTestRegistry.register("evolution-algo", "checkpoint-roundtrip") { ctx in
            var nl = NEATLayout(inputs: ["a", "b"], outputs: ["y"]); nl.outputActivation = "sigmoid"
            let flat = box(8, -2, 2)
            let cases: [(String, GenomeLayout, [String: JSONValue])] = [
                ("ga", flat, ["adaptive": .bool(true)]), ("cmaes", flat, ["restarts": .string("bipop")]), ("sep-cmaes", flat, [:]),
                ("openai-es", flat, [:]), ("neat", GenomeLayout(genes: [GeneSpec(name: "k", min: 0, max: 1)], neat: nl), [:]),
                ("map-elites", flat, ["axes": try qdParams()]), ("novelty", flat, ["axes": try qdParams()]),
            ]
            for (kind, layout, params) in cases {
                func eval(_ g: Genome) throws -> Fitness {
                    if kind == "neat" { return Fitness(total: try xorFitness(g, nl).0 + g.values[0]) }
                    var f = qdEval(Genome(id: 0, values: Array(g.values.prefix(6)))); f.total = -rastrigin(g.values); return f
                }
                let a = try make(kind, layout, pop: 24, seed: 3, params)
                for _ in 0..<4 { let p = try a.ask(); try a.tell(p, try p.map(eval)) }
                let b = try make(kind, layout, pop: 24, seed: 3, params)
                try b.restore(try a.saveState())
                var same = true
                for _ in 0..<4 {
                    let pa = try a.ask(), pb = try b.ask()
                    if pa != pb { same = false }
                    try a.tell(pa, try pa.map(eval)); try b.tell(pb, try pb.map(eval))
                }
                // (Int-keyed dictionaries encode in hash order, so compare behaviour rather than bytes)
                same = same && a.best?.genome == b.best?.genome && a.generation == 8 && b.generation == 8
                // determinism from scratch
                let c = try make(kind, layout, pop: 24, seed: 3, params)
                for _ in 0..<8 { let p = try c.ask(); try c.tell(p, try p.map(eval)) }
                let ca = try c.ask(), aa = try a.ask(); let det = c.best?.genome == a.best?.genome && ca == aa
                ctx.expect(same, "\(kind): restore continues bit-identically")
                ctx.expect(det, "\(kind): deterministic given seed")
                let ids = try b.ask().map(\.id)
                ctx.expect(Set(ids).count == ids.count, "\(kind): unique genome ids")
            }
        }
        SelfTestRegistry.register("evolution-algo", "hooks") { ctx in
            final class H: AlgorithmHooks {
                var sel = 0, cx = 0, mu = 0
                func select(population: [Genome], fitness: [Fitness], count: Int, rng: inout EvoRNG) throws -> [Int]? { sel += 1; return (0..<count).map { _ in 0 } }
                func crossover(_ a: Genome, _ b: Genome, layout: GenomeLayout, rng: inout EvoRNG) throws -> [Double]? { cx += 1; return nil }
                func mutate(_ g: Genome, layout: GenomeLayout, rate: Double, rng: inout EvoRNG) throws -> [Double]? { mu += 1; return g.values.map { _ in 0.25 } }
            }
            for kind in ["ga", "cmaes", "sep-cmaes", "openai-es", "novelty"] {
                let h = H()
                let a = try make(kind, box(4, -1, 1), pop: 10, ["axes": try qdParams()]); a.hooks = h
                for _ in 0..<2 { let p = try a.ask(); try a.tell(p, p.map(qdEval)) }
                let p = try a.ask()
                ctx.expect(h.mu > 0 && p.filter { $0.origin != "elite" }.allSatisfy { $0.values == [0.25, 0.25, 0.25, 0.25] }, "\(kind): mutate hook output used")
                if kind == "ga" || kind == "novelty" { ctx.expect(h.sel > 0, "\(kind): select hook consulted") }
            }
        }
    }
}
