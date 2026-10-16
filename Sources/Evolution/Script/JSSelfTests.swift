// OWNED BY script builder. ---------------------------------------------------------------------------
// Self-tests for the JavaScriptCore runtime, group "evolution-js".
//   PlaneWorld --selftest evolution-js
//   PlaneWorld --selftest evolution-js.throughput        (calls/sec per core; use a release build)
//   PlaneWorld --selftest evolution-js.presets-learn     (short training runs of the three presets)
// The App must call `JSScriptSelfTests.register()` from registerAllSelfTests() (integrator).
import Foundation
import PWCore
import PWPhysics

public enum JSScriptSelfTests {
    static func trainer() -> CraftDocument { ExperimentPresets.addStandardSensors(PhysicsPresets.trainer()) }

    static func compiled(_ src: String, _ e: ExperimentDocument = ExperimentDocument(), budget: Double = 5) throws -> JSScriptRuntime {
        var b = ScriptBundle(); b.source = src; b.callBudgetMs = budget
        let rt = JSScriptRuntime(); rt.logLimit = 0
        try rt.compile(b, experiment: e)
        return rt
    }

    /// A frame with the trainer's names, filled with plausible values.
    static func frame(terms: [String] = ["a", "b"]) throws -> ControlFrame {
        let sim = CraftSim(); try sim.load(trainer())
        let f = ControlFrame(inputNames: sim.inputs.map(\.name), outputNames: sim.outputs.map(\.name), termNames: terms)
        for i in 0..<f.inputs.count { f.inputs[i] = Double(i) * 0.5 }
        f.state.airspeed = 30; f.state.agl = 120; f.state.roll = 5
        f.info.controlDt = 0.02; f.info.seed = 0x1234_5678_9ABC_DEF0; f.info.duration = 10
        return f
    }

    static func experiment(_ preset: String, algorithm: String? = nil, population: Int = 16, duration: Double = 8) -> ExperimentDocument {
        var e = ExperimentPresets.make(preset)
        if let algorithm { e.algorithm = AlgorithmParams(kind: algorithm) }
        e.population = population; e.episode.duration = duration; e.episode.episodesPerCandidate = 1
        e.checkpointEvery = 0
        return e
    }

    /// The preset's own algorithm when its builder has implemented it, otherwise simple-es (reported in the log).
    static func usableAlgorithm(_ e: ExperimentDocument, layoutCount: Int) -> String {
        let probe = GenomeLayout(genes: (0..<max(2, layoutCount)).map { GeneSpec(name: "g\($0)") })
        if let a = try? AlgorithmRegistry.make(e.algorithm, layout: probe, population: 8, seed: 1), (try? a.ask()) != nil { return e.algorithm.kind }
        return "simple-es"
    }

    public static func register() {
        ScriptedAlgorithmRegistration.register()

        SelfTestRegistry.register("evolution-js", "presets-compile") { ctx in
            ctx.expect(JSScriptRuntime.watchdogAvailable, "JavaScriptCore watchdog SPI available")
            for name in ExperimentPresets.names {
                let e = ExperimentPresets.make(name)
                do {
                    let rt = try compiled(e.scripts.source, e)
                    ctx.expect(rt.definedHooks.isSuperset(of: [.terms, .reward, .fitness]), "\(name): hooks \(rt.definedHooks.map(\.rawValue).sorted())")
                    let tn = try rt.termNames(default: [])
                    ctx.expect(tn == e.rewardTerms, "\(name): terms() matches rewardTerms")
                    let r = try EvolutionRun(experiment: { var x = e; x.workers = 2; x.checkpointEvery = 0; return x }(), craft: trainer(), world: .flat(), runID: "js-selftest")
                    ctx.expect(r.layout.count > 0 && r.termNames == e.rewardTerms, "\(name): run builds (\(r.layout.count) genes)")
                } catch { ctx.fail("\(name): \(error)") }
            }
            // syntax error → compile error with the user's line number
            do { _ = try compiled("function control(ctx) {\n  var x = 1;\n  var y = ;\n}"); ctx.fail("syntax error not reported") }
            catch let s as ScriptError { ctx.expect(s.hook == "compile" && s.line == 3, "syntax error at line 3 (got \(s))") }
            // runtime error → hook + line
            let rt = try compiled("function terms() { return ['a', 'b']; }\nfunction control(ctx) {\n  if (ctx.tick === 3)\n    undefinedThing.foo = 1;\n}")
            let f = try frame()
            try rt.beginEpisode(genome: Genome(id: 1, values: []), frame: f)
            do { for k in 0..<5 { f.tick = k; try rt.tick(f) }; ctx.fail("runtime error not reported") }
            catch let s as ScriptError { ctx.expect(s.hook == "control" && s.line == 4 && s.message.contains("undefinedThing"), "runtime error in control line 4 (got \(s))") }
            // unknown output / reward term names are errors, unknown inputs read 0
            let rt2 = try compiled("function control(ctx) { ctx.out.Elevatr = 1; }")
            try rt2.beginEpisode(genome: Genome(id: 1, values: []), frame: f)
            do { try rt2.tick(f); ctx.fail("typo'd output accepted") } catch let s as ScriptError { ctx.expect(s.message.contains("unknown output 'Elevatr'"), "typo'd output: \(s.message)") }
            let rt3 = try compiled("function reward(ctx) { return { nope: ctx.in.doesNotExist + 1 }; }")
            try rt3.beginEpisode(genome: Genome(id: 1, values: []), frame: f)
            do { try rt3.tick(f); ctx.fail("unknown term accepted") } catch let s as ScriptError { ctx.expect(s.hook == "reward" && s.message.contains("unknown reward term 'nope'"), "unknown term: \(s)") }
        }

        SelfTestRegistry.register("evolution-js", "ctx-api") { ctx in
            let src = """
            function terms() { return ["a", "b"]; }
            function init(ctx) { ctx.memory.n = 0; ctx.memory.r0 = Math.random(); }
            function control(ctx) {
              ctx.memory.n++;
              ctx.out.Elevator = ctx.in["att.pitch"] + ctx.inputs[0];
              ctx.outputs[0] = ctx.state.airspeed;
              ctx.reward.b = ctx.genome.values[1];
            }
            function reward(ctx) { return { a: ctx.dt }; }
            function terminate(ctx) { return ctx.memory.n >= 3; }
            function fitness(ctx) { return { fitness: ctx.memory.n * 10 + (ctx.state.crashed ? 1 : 0), terms: { bonus: 7 }, descriptor: [ctx.t, Date.now()] }; }
            """
            let rt = try compiled(src)
            let f = try frame()
            let g = Genome(id: 42, values: [0.25, 0.75])
            try rt.beginEpisode(genome: g, frame: f)
            var k = 0
            while !f.done && k < 10 {
                f.tick = k; f.state.t = Double(k) * 0.02
                for i in 0..<f.terms.count { f.terms[i] = 0 }
                try rt.tick(f)
                for i in 0..<f.termSums.count { f.termSums[i] += f.terms[i] }
                k += 1
            }
            let pitch = f.inputs[f.inputNames.firstIndex(of: "att.pitch")!]
            let elev = f.outputs[f.outputNames.firstIndex(of: "Elevator")!]
            ctx.expect(k == 3 && f.done, "terminate() after 3 ticks (k \(k))")
            ctx.expectClose(elev, pitch + f.inputs[0], tol: 0, "ctx.out writes through to the frame")
            ctx.expectClose(f.outputs[0], 30, tol: 0, "ctx.outputs aliases frame.outputs")
            ctx.expectClose(f.termSums[0], 0.06, tol: 1e-12, "reward() object deltas summed")
            ctx.expectClose(f.termSums[1], 2.25, tol: 1e-12, "ctx.reward writable + ctx.genome.values")
            let out = try rt.endEpisode(f)
            ctx.expect(out.fitness == 30 && out.terms["bonus"] == 7 && out.descriptor?.count == 2, "fitness object (\(out))")
            ctx.expectClose(out.descriptor?[1] ?? -1, 40, tol: 1e-9, "Date.now() is sim time in ms")
            // helpers
            let h = try compiled("""
            var R = {};
            function fitness(ctx) {
              var p = pid(2, 0, 0); var v = vec.cross([1,0,0],[0,1,0]);
              var w = new Float64Array(nn.paramCount([3, 4, 2])); for (var i = 0; i < w.length; i++) w[i] = Math.sin(i);
              var y = nn.mlp([3, 4, 2], w, [0.1, -0.2, 0.3]);
              var d = nn.dense([[1, 2], [3, 4]], [0.5, -0.5], [1, 1], "linear");
              return { fitness: clamp(5, 0, 1) + lerp(0, 10, 0.5) + p.update(1, 0.1) + v[2] + vec.len(3, 4, 0), descriptor: [y[0], y[1], d[0], d[1], ctx.rng.gaussian()] };
            }
            """)
            try h.beginEpisode(genome: Genome(id: 1, values: []), frame: f)
            let o2 = try h.endEpisode(f)
            ctx.expectClose(o2.fitness ?? 0, 1 + 5 + 2 + 1 + 5, tol: 1e-12, "clamp/lerp/pid/vec helpers")
            let m = MLPPolicy(sizes: [3, 4, 2]); let w = (0..<MLPPolicy.parameterCount([3, 4, 2])).map { sin(Double($0)) }
            w.withUnsafeBufferPointer { m.load($0) }
            var y = [0.0, 0.0]; let x = [0.1, -0.2, 0.3]
            x.withUnsafeBufferPointer { xp in y.withUnsafeMutableBufferPointer { m.forward(xp.baseAddress!, $0.baseAddress!) } }
            ctx.expect(o2.descriptor?[0] == y[0] && o2.descriptor?[1] == y[1], "native nn.mlp equals MLPPolicy bit for bit")
            ctx.expect(o2.descriptor?[2] == 3.5 && o2.descriptor?[3] == 6.5, "nn.dense")
            // genome() hook + gene names reach worker runtimes
            var e = ExperimentPresets.neuralController()
            e.scripts.source = ExperimentPresets.neuralJS + "\nfunction genome(base) { base.genes.push({ name: 'gain', min: 0, max: 2, initial: 1 }); return base; }\nvar G = 0;\nfunction init(ctx) { G = ctx.genome.get('gain'); }\nfunction descriptor(ctx) { return [G]; }"
            e.workers = 2; e.population = 4; e.episode.duration = 1; e.checkpointEvery = 0; e.algorithm = AlgorithmParams(kind: "simple-es")
            let run = try EvolutionRun(experiment: e, craft: trainer(), world: .flat(), runID: "js-ctx")
            ctx.expect(run.layout.genes.last?.name == "gain" && run.layout.genes.last?.group == "script", "genome() appended a script gene")
            var v = run.layout.genes.map { $0.initial ?? 0 }; v[v.count - 1] = 1.5
            let fit = run.evaluator.evaluate([Genome(id: 1, values: v)], generation: 0, cancel: nil)
            ctx.expect(fit[0].error == nil, "evaluates: \(fit[0].error ?? "")")
            ctx.expect(fit[0].descriptor == [1.5], "ctx.genome.get('gain') works in worker runtimes (descriptor \(fit[0].descriptor ?? []))")
        }

        SelfTestRegistry.register("evolution-js", "runaway-killed") { ctx in
            let rt = try compiled("function control(ctx) { if (ctx.tick === 2) { while (true) {} } }\nfunction fitness(ctx) { var s = 0; for (;;) s++; }", budget: 5)
            let f = try frame()
            try rt.beginEpisode(genome: Genome(id: 1, values: []), frame: f)
            let t0 = Date()
            var err: ScriptError?
            do { for k in 0..<5 { f.tick = k; try rt.tick(f) } } catch let s as ScriptError { err = s }
            let ms = Date().timeIntervalSince(t0) * 1000
            ctx.expect(err?.timedOut == true && err?.hook == "control", "runaway control() killed (\(err.map { "\($0)" } ?? "no error"))")
            ctx.expect(ms < 500, "killed promptly (\(String(format: "%.1f", ms)) ms for a 5 ms budget)")
            ctx.log(String(format: "control() runaway killed after %.1f ms (budget 5 ms)", ms))
            // the context is still usable, and the 20x budget applies to fitness()
            f.tick = 3
            let t1 = Date()
            do { _ = try rt.endEpisode(f); ctx.fail("runaway fitness() not killed") }
            catch let s as ScriptError { ctx.expect(s.timedOut && s.hook == "fitness", "runaway fitness() killed: \(s)") }
            let ms2 = Date().timeIntervalSince(t1) * 1000
            ctx.expect(ms2 >= 50 && ms2 < 1500, "fitness() budget is 20× (\(String(format: "%.0f", ms2)) ms)")
            try rt.beginEpisode(genome: Genome(id: 1, values: []), frame: f)
            f.tick = 0; try rt.tick(f)
            ctx.expect(true, "runtime usable after a timeout")
            // top-level runaway during compile
            do { _ = try compiled("while (true) {}"); ctx.fail("runaway top-level code not killed") }
            catch let s as ScriptError { ctx.expect(s.timedOut, "top-level runaway killed: \(s)") }
            // in a run, a runaway candidate fails with failedFitness and the run continues
            var e = experiment("Neural controller", algorithm: "simple-es", population: 4, duration: 1)
            e.scripts.source = ExperimentPresets.neuralJS + "\nfunction control(ctx) { if (ctx.genome.values[0] > 0.0 && ctx.tick == 5) while (true) {} }"
            e.workers = 2
            let r = try EvolutionRun(experiment: e, craft: trainer(), world: .flat(), runID: "js-runaway")
            let pos = Genome(id: 1, values: r.layout.genes.map { _ in 0.1 }), neg = Genome(id: 2, values: r.layout.genes.map { _ in -0.1 })
            let fit = r.evaluator.evaluate([pos, neg], generation: 0, cancel: nil)
            ctx.expect(fit[0].total == EvolutionConstants.failedFitness && fit[0].error?.contains("time budget") == true, "runaway candidate failed: \(fit[0].error ?? "-")")
            ctx.expect(fit[1].error == nil, "other candidate unaffected: \(fit[1].error ?? "")")
        }

        SelfTestRegistry.register("evolution-js", "determinism") { ctx in
            var e = experiment("Neural controller", algorithm: "simple-es", population: 10, duration: 3)
            e.episode.episodesPerCandidate = 2
            e.episode.spawn.jitterHeadingDeg = 5
            // Math.random and ctx.rng inside the controller must be episode-seeded
            e.scripts.source = ExperimentPresets.neuralJS + "\nfunction control(ctx) { ctx.out.Rudder = 0.2 * (Math.random() - 0.5) + 0.1 * ctx.rng.gaussian(); }"
            func run(_ w: Int) throws -> EvolutionRun { var x = e; x.workers = w; return try EvolutionRun(experiment: x, craft: trainer(), world: .flat(), runID: "js-det") }
            let r1 = try run(1), rN = try run(0)
            var rng = EvoRNG(seed: 77)
            let pop = (0..<10).map { Genome(id: UInt64($0 + 1), values: r1.layout.genes.map { g in g.legalize(rng.uniform(g.min, g.max) * 0.3) }) }
            let a = r1.evaluator.evaluate(pop, generation: 2, cancel: nil), b = rN.evaluator.evaluate(pop, generation: 2, cancel: nil)
            let c = rN.evaluator.evaluate(pop, generation: 2, cancel: nil)
            ctx.expect(a.allSatisfy { $0.error == nil }, "no failures: \(a.compactMap(\.error).first ?? "")")
            ctx.expect(a.map(\.total) == b.map(\.total) && a.map(\.terms) == b.map(\.terms), "1 worker vs \((rN.evaluator as! SimEvaluator).workerCount) workers identical")
            ctx.expect(b.map(\.total) == c.map(\.total), "repeat evaluation identical")
            let d = rN.evaluator.evaluate(pop, generation: 3, cancel: nil)
            ctx.expect(d.map(\.total) != c.map(\.total), "different generation seed → different episodes")
            // JS preset vs the native Swift equivalent (architect's test runtime): identical fitness
            var en = e; en.scripts.source = ExperimentPresets.neuralJS; en.workers = 0
            let js = try EvolutionRun(experiment: en, craft: trainer(), world: .flat(), runID: "js-eq")
            var nat = en; nat.scripts.source = ""
            let nv = try EvolutionRun(experiment: nat, craft: trainer(), world: .flat(), runID: "native-eq", runtimeFactory: { EvolutionSelfTests.nativeNeuralRuntime() })
            let fj = js.evaluator.evaluate(pop, generation: 0, cancel: nil), fn = nv.evaluator.evaluate(pop, generation: 0, cancel: nil)
            ctx.expect(fj.map(\.total) == fn.map(\.total), "neural preset JS == native Swift scoring, bit for bit (\(fj.first?.total ?? 0) vs \(fn.first?.total ?? 0))")
        }

        SelfTestRegistry.register("evolution-js", "throughput") { ctx in
            let f = try frame(terms: ["altitude", "speed", "level", "crash"])
            func measure(_ src: String, _ label: String, n: Int = 200_000) throws -> Double {
                let rt = try compiled(src, budget: 50)
                try rt.beginEpisode(genome: Genome(id: 1, values: []), frame: f)
                for k in 0..<2000 { f.tick = k; try rt.tick(f) }           // JIT warm-up
                let t0 = DispatchTime.now().uptimeNanoseconds
                for k in 0..<n { f.tick = k; f.state.t = Double(k) * 0.02; try rt.tick(f) }
                let s = Double(DispatchTime.now().uptimeNanoseconds - t0) * 1e-9
                ctx.log(String(format: "%@: %.2f µs/tick → %.0f k calls/s per core", label, s / Double(n) * 1e6, Double(n) / s / 1000))
                return s / Double(n) * 1e6
            }
            let trivial = try measure("function control(ctx) { ctx.out.Engine = 1; }", "trivial control()")
            let preset = try measure(ExperimentPresets.neuralJS, "neural preset (control+reward+terminate)")
            let pidSrc = ExperimentPresets.designJS
            let rtd = try compiled(pidSrc, budget: 50)          // design preset needs init() for its PIDs
            let fd = try frame(terms: ["climb", "efficiency", "crash"])
            try rtd.beginEpisode(genome: Genome(id: 1, values: []), frame: fd)
            let t0 = DispatchTime.now().uptimeNanoseconds
            for k in 0..<100_000 { fd.tick = k; try rtd.tick(fd) }
            let us = Double(DispatchTime.now().uptimeNanoseconds - t0) * 1e-9 / 100_000 * 1e6
            ctx.log(String(format: "design preset PID autopilot: %.2f µs/tick", us))
            let nnSrc = "var W = new Float64Array(nn.paramCount([9, 12, 4]));\nfunction control(ctx) { var y = nn.mlp([9, 12, 4], W, ctx.inputs); ctx.out.Elevator = y[0]; }"
            let nnUs = try measure(nnSrc, "JS control() with native nn.mlp 9-12-4")
            #if DEBUG
            ctx.log("debug build: thresholds not enforced")
            #else
            ctx.expect(trivial < 5, "trivial control() overhead under 5 µs/tick (\(trivial))")
            ctx.expect(preset < 15 && nnUs < 15, "preset / nn ticks under 15 µs")
            #endif
        }

        SelfTestRegistry.register("evolution-js", "script-algorithm") { ctx in
            let algo = """
            function ask(state, layout, rng, info) {
              if (!state.mean) { state.mean = layout.genes.map(function (g) { return g.initial !== undefined ? g.initial : 0; }); state.sigma = 0.3; }
              var out = [];
              for (var i = 0; i < info.population; i++) out.push(state.mean.map(function (m) { return m + state.sigma * rng.gaussian(); }));
              return out;
            }
            function tell(state, pop, rng) {
              pop.sort(function (a, b) { return b.fitness - a.fitness; });
              var top = pop.slice(0, 4);
              state.mean = state.mean.map(function (_, j) { var s = 0; top.forEach(function (p) { s += p.values[j]; }); return s / top.length; });
              state.sigma *= 0.97 + 0.02 * Math.random();
            }
            function mutate(g, layout, rate, rng) { return Array.from(g.values, function (v) { return v + 0.01 * rng.gaussian(); }); }
            """
            var e = experiment("Neural controller", algorithm: "script", population: 8, duration: 2)
            e.scripts.source = ExperimentPresets.neuralJS + "\n" + algo
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pw-evo-js-\(getpid())")
            defer { try? FileManager.default.removeItem(at: dir) }
            let a = try EvolutionRun(experiment: e, craft: trainer(), world: .flat(), runID: "js-algo", directory: dir)
            ctx.expect(a.algorithm is ScriptedAlgorithm, "kind 'script' → ScriptedAlgorithm")
            for _ in 0..<2 { try a.runGeneration() }
            try a.checkpoint(to: dir)
            let b = try EvolutionRun.resume(from: dir, world: .flat())
            for _ in 0..<2 { try a.runGeneration(); try b.runGeneration() }
            ctx.expect(a.history.count == 4 && a.history.map(\.best) == b.history.map(\.best), "resumed script algorithm continues identically (\(a.history.map(\.best)) vs \(b.history.map(\.best)))")
            ctx.expect(a.history.allSatisfy { $0.failures == 0 }, "no failures: \(a.history.compactMap(\.firstError).first ?? "")")
            // operator hooks through JSAlgorithmHooks (simple-es consults mutate())
            var e2 = e; e2.algorithm = AlgorithmParams(kind: "simple-es")
            let c = try EvolutionRun(experiment: e2, craft: trainer(), world: .flat(), runID: "js-hooks")
            ctx.expect(c.algorithm.hooks is JSAlgorithmHooks, "JS mutate() installed as algorithm hook")
            let pop = try c.algorithm.ask()
            ctx.expect(pop.count == 8, "hooked ask works")
        }

        SelfTestRegistry.register("evolution-js", "presets-learn") { ctx in
            // Each preset's JS, Trainer, flat world, short episodes. Learning = best fitness clearly improves.
            #if DEBUG
            let gens = 3
            #else
            let gens = 8
            #endif
            for name in ExperimentPresets.names {
                var e = experiment(name, population: 16, duration: 30)
                let probe = try EvolutionRun(experiment: e, craft: trainer(), world: .flat(), runID: "probe")
                let kind = usableAlgorithm(e, layoutCount: probe.layout.count)
                e.algorithm = kind == e.algorithm.kind ? e.algorithm : AlgorithmParams(kind: kind)
                let r = try EvolutionRun(experiment: e, craft: trainer(), world: .flat(), runID: "learn")
                let t0 = Date()
                for _ in 0..<gens { try r.runGeneration() }
                let h = r.history
                let first = h.first!.best, best = h.map(\.best).max()!, lastMean = h.last!.mean, firstMean = h.first!.mean
                ctx.log(String(format: "%@ [%@, %d genes]: gen0 best %.2f mean %.2f → best %.2f, last mean %.2f (%.1f s, %.0f sim-s/s)",
                               name, kind, r.layout.count, first, firstMean, best, lastMean, Date().timeIntervalSince(t0), h.last!.simSecondsPerWallSecond))
                ctx.expect(h.allSatisfy { $0.failures == 0 }, "\(name): no script failures (\(h.compactMap(\.firstError).first ?? ""))")
                #if !DEBUG
                ctx.expect(best > first + max(0.5, 0.05 * abs(first)), "\(name): learns (best \(first) → \(best), mean \(firstMean) → \(lastMean))")
                #endif
            }
        }
    }
}
