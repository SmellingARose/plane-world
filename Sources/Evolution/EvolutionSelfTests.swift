// OWNED BY architect. Builders ADD their own tests (register more names under group "evolution"; script
// builder: "evolution-js"; algorithm builders: "evolution-algo").
//   PlaneWorld --selftest evolution            all architect tests
//   PlaneWorld --selftest evolution.bench-headless   throughput numbers (use a release build)
import Foundation
import simd
import Synchronization
import PWCore
import PWPhysics
import PWTerrain

// MARK: - allocation counter (test-only): swaps the default malloc zone's entry points

private let allocCounter = Atomic<Int>(0)
private let countedThread = Atomic<UInt>(0)
private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

nonisolated(unsafe) let traceBuf = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 32)
nonisolated(unsafe) let traceAt = Int(ProcessInfo.processInfo.environment["PW_ALLOC_TRACE"] ?? "") ?? 0

enum AllocationCounter {
    nonisolated(unsafe) static var installed = false
    /// Counts heap allocations made by the thread that called install() through libmalloc's `malloc_logger` hook (the one
    /// MallocStackLogging uses). Self-checks; returns false if the hook is unavailable/ineffective.
    static func install() -> Bool {
        if !installed {
            countedThread.store(UInt(bitPattern: pthread_self()), ordering: .relaxed); _ = allocCounter.load(ordering: .relaxed); _ = traceBuf; _ = traceAt   // force lazy globals before hooking
            guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return false }   // RTLD_DEFAULT
            let slot = sym.assumingMemoryBound(to: Optional<MallocLogger>.self)
            slot.pointee = { type, _, _, _, _, _ in   // MALLOC_LOG_TYPE_ALLOCATE, counted on the measuring thread only
                if type & 2 != 0 && UInt(bitPattern: pthread_self()) == countedThread.load(ordering: .relaxed) {
                    let c = allocCounter.add(1, ordering: .relaxed).newValue
                    // PW_ALLOC_TRACE=N: dump the stack of allocations N..N+2 (malloc-free: backtrace_symbols_fd)
                    if traceAt > 0 && c >= traceAt && c < traceAt + 20000 { let n = backtrace(traceBuf, 24); backtrace_symbols_fd(traceBuf, n, 2) }
                }
            }
            installed = true
        }
        countedThread.store(UInt(bitPattern: pthread_self()), ordering: .relaxed)
        let a = count
        let probe = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16); probe.deallocate()
        let arr = [Double](repeating: 1, count: 1000 + Int(getpid() % 7)); _ = arr.count
        return count > a
    }
    static var count: Int { allocCounter.load(ordering: .relaxed) }
}

public enum EvolutionSelfTests {
    /// Trainer + standard sensors, flight-ready.
    static func trainer() -> CraftDocument { ExperimentPresets.addStandardSensors(PhysicsPresets.trainer()) }

    /// Native equivalent of ExperimentPresets.neuralJS (no JavaScript needed).
    static func nativeNeuralRuntime() -> NativeScriptRuntime {
        let rt = NativeScriptRuntime(terms: ["altitude", "speed", "level", "crash"])
        rt.onTick = { f in
            let s = f.state, dt = f.info.controlDt
            f.terms[0] = -min(abs(s.agl - 150) / 150, 1) * dt
            f.terms[1] = min(s.airspeed, 45) / 45 * dt * 0.5
            f.terms[2] = -min(abs(s.roll) / 90, 1) * dt * 0.5
            if s.crashed { f.done = true }
        }
        rt.onEnd = { f in
            let crash = f.state.crashed ? -20.0 : 0
            return EpisodeOutcome(fitness: f.termSums[0] + f.termSums[1] + f.termSums[2] + crash, terms: ["crash": crash],
                                  descriptor: [f.state.x / 1000, f.state.agl / 300])
        }
        return rt
    }

    static func neuralExperiment(duration: Double = 20, episodes: Int = 1) -> ExperimentDocument {
        var e = ExperimentPresets.neuralController()
        e.scripts.source = ""            // native runtime supplies the hooks in tests
        e.algorithm = AlgorithmParams(kind: "simple-es")
        e.population = 16; e.generations = 3
        e.episode.duration = duration; e.episode.episodesPerCandidate = episodes
        e.checkpointEvery = 0
        return e
    }

    static func makeRun(_ e: ExperimentDocument, workers: Int = 0, dir: URL? = nil) throws -> EvolutionRun {
        var e = e; e.workers = workers
        return try EvolutionRun(experiment: e, craft: trainer(), world: .flat(), runID: "selftest", directory: dir,
                                runtimeFactory: { nativeNeuralRuntime() })
    }

    public static func register() {
        BatchSelfTests.register()
        SelfTestRegistry.register("evolution", "rng-determinism") { ctx in
            var a = EvoRNG(seed: 42), b = EvoRNG(seed: 42), c = EvoRNG(seed: 43)
            let xa = (0..<100).map { _ in a.next() }, xb = (0..<100).map { _ in b.next() }, xc = (0..<100).map { _ in c.next() }
            ctx.expect(xa == xb, "same seed → same stream")
            ctx.expect(xa != xc, "different seed → different stream")
            ctx.expect(EvoRNG.derive(1, 2, 3) == EvoRNG.derive(1, 2, 3) && EvoRNG.derive(1, 2, 3) != EvoRNG.derive(1, 3, 2), "derive is stable and order-sensitive")
            var g = EvoRNG(seed: 9); var s = 0.0, s2 = 0.0
            for _ in 0..<20000 { let x = g.gaussian(); s += x; s2 += x * x }
            ctx.expectClose(s / 20000, 0, tol: 0.03, "gaussian mean"); ctx.expectClose(s2 / 20000, 1, tol: 0.05, "gaussian variance")
            let d = try JSONIO.encode(a), a2 = try JSONIO.decode(EvoRNG.self, from: d)
            ctx.expect(a2 == a, "RNG state round-trips through JSON")
        }

        SelfTestRegistry.register("evolution", "mlp-policy") { ctx in
            let sizes = [3, 4, 2]
            let lay = MLPPolicy.layout(sizes, range: 3)
            ctx.expect(lay.count == 3 * 4 + 4 + 4 * 2 + 2 && lay.count == MLPPolicy.parameterCount(sizes), "parameter count")
            let m = MLPPolicy(sizes: sizes, hiddenActivation: "linear", outputActivation: "linear")
            var w = [Double](repeating: 0, count: lay.count)
            for i in 0..<3 { w[i * 3 + i] = 1 }             // hidden h_i = x_i (i < 3), h_3 = bias
            w[12 + 3] = 0.5                                   // b_hidden[3]
            w[16 + 0] = 1; w[16 + 1] = 1                      // y0 = h0 + h1
            w[16 + 4 + 3] = 2                                 // y1 = 2 h3
            w.withUnsafeBufferPointer { m.load($0) }
            let x: [Double] = [1, 2, 3]; var y: [Double] = [0, 0]
            x.withUnsafeBufferPointer { xp in y.withUnsafeMutableBufferPointer { m.forward(xp.baseAddress!, $0.baseAddress!) } }
            ctx.expectClose(y[0], 3, tol: 1e-12, "y0"); ctx.expectClose(y[1], 1, tol: 1e-12, "y1")
        }

        SelfTestRegistry.register("evolution", "design-decoder") { ctx in
            var span = DesignGene(part: "Wing L", field: "p.span", min: 2, max: 6); span.mirror = ["Wing R"]
            var y = DesignGene(part: "Wing L", field: "pos.2", min: -4, max: -1); y.mirror = ["Wing R"]
            let off = DesignGene(part: "Rudder", field: "enabled", min: 0, max: 1, kind: .bool)
            let m = DesignGene(part: "fus", field: "mass", min: 100, max: 500)
            let d = try DesignDecoder.apply([span, y, off, m], values: [5, -3, 0, 250][...], to: PhysicsPresets.trainer())
            ctx.expect(d.part("wl")?.param("span") == 5 && d.part("wr")?.param("span") == 5, "span applied to both wings")
            ctx.expect(d.part("wl")?.pos[2] == -3 && d.part("wr")?.pos[2] == 3, "mirrored pos.2 negated")
            ctx.expect(d.part("rud") == nil && d.part("fin")?.servo == nil && d.part("nw")?.servo == nil, "disabled servo removed with its links")
            ctx.expect(d.part("fus")?.mass == 250, "mass gene")
            let bad = try? DesignDecoder.apply([DesignGene(part: "nope", field: "mass", min: 0, max: 1)], values: [0][...], to: d)
            ctx.expect(bad == nil, "unknown part rejected")
        }

        SelfTestRegistry.register("evolution", "headless-bake") { ctx in
            let src = HeightField(width: 65, height: 65, spacing: 8, origin: Vec2d(-256, -256))
            for y in 0..<65 { for x in 0..<65 { src.base[x, y] = Float(10 * sin(Double(x) * 0.3) + 5 * cos(Double(y) * 0.2)) } }
            src.recompute(src.fullRect)
            let w = HeadlessWorld.bake(field: src, water: nil, spawn: .identity, environment: EnvironmentSpec())
            guard let t = w.terrain else { ctx.fail("no terrain"); return }
            var maxErr = 0.0
            for i in 0..<200 { let x = -300 + Double(i) * 3.1, z = 200 - Double(i) * 2.3; maxErr = max(maxErr, abs(t.height(x: x, z: z) - src.sampleHeight(x: x, z: z))) }
            ctx.expect(maxErr == 0, "baked heights identical to source (max err \(maxErr))")
            src.base[30, 30] = 999; src.recompute(src.fullRect)
            ctx.expect(abs(t.height(x: -256 + 240, z: -256 + 240) - 999) > 100, "bake is a copy (later edits do not leak)")
            let hit = t.raycast(Ray(origin: [0, 100, 0], direction: [0, -1, 0]), maxDistance: 500)
            ctx.expectClose(hit?.position.y ?? .nan, t.height(x: 0, z: 0), tol: 1e-3, "raycast hits baked surface")
            var ws = WaterSpec(); ws.oceanEnabled = true; ws.seaLevel = 2
            let ww = HeadlessWorld.bake(field: src, water: ws, spawn: .identity, environment: EnvironmentSpec(), options: { var o = HeadlessOptions(); o.oceanWaves = true; return o }())
            let a = ww.water!.sample(x: 10, z: 20, time: 3).surfaceHeight, b = ww.water!.sample(x: 10, z: 20, time: 3).surfaceHeight
            ctx.expect(a == b && abs(a - 2) < 5, "analytic swell deterministic around sea level (\(a))")
        }

        SelfTestRegistry.register("evolution", "headless-obstacles") { ctx in
            let o = HeadlessObstacles()
            o.addTrees([(id: 1, transform: Transform(position: [50, 5, 0]), shape: .capsule(radius: 0.3, halfHeight: 4.7), breakImpulse: 1)])
            var wo = WorldObject(id: "w", kind: "breakable", asset: "Brick wall", transform: Transform(position: [0, 1, 40])); wo.breakable = true
            o.addObjects([wo])
            let a = UnsafeMutablePointer<Vec3d>.allocate(capacity: 1), b = UnsafeMutablePointer<Vec3d>.allocate(capacity: 1)
            defer { a.deallocate(); b.deallocate() }
            // corner sweeps 1.2 m per tick straight through the 0.6 m trunk (no sample lands inside without sweeping)
            a[0] = [49.4, 3, 0]; b[0] = [50.6, 3, 0]
            ctx.expect(o.hit(center: b[0], radius: 1, prev: a, cur: b, count: 1, travel: 1.2), "swept corner hits thin trunk")
            a[0] = [49.4, 3, 2]; b[0] = [50.6, 3, 2]
            ctx.expect(!o.hit(center: b[0], radius: 1, prev: a, cur: b, count: 1, travel: 1.2), "miss beside trunk")
            a[0] = [-0.5, 1, 40.5]; b[0] = [0.5, 1, 40.5]
            ctx.expect(o.hit(center: b[0], radius: 1, prev: a, cur: b, count: 1, travel: 1), "hits wall box")
            a[0] = [-0.5, 2.5, 40.5]; b[0] = [0.5, 2.5, 40.5]
            ctx.expect(!o.hit(center: b[0], radius: 1, prev: a, cur: b, count: 1, travel: 1), "passes over 2 m wall")
            // world wiring: flags off -> no obstacles
            var opt = HeadlessOptions(); opt.vegetation = false; opt.breakables = false
            let w0 = HeadlessWorld.bake(field: nil, water: nil, spawn: Transform(), environment: EnvironmentSpec(), options: opt, objects: [wo])
            opt.breakables = true
            let w1 = HeadlessWorld.bake(field: nil, water: nil, spawn: Transform(), environment: EnvironmentSpec(), options: opt, objects: [wo])
            ctx.expect(w0.obstacles == nil && w1.obstacles?.objectCount == 1, "breakables flag adds objects")
        }
        SelfTestRegistry.register("evolution", "experiment-json") { ctx in
            for n in ExperimentPresets.names {
                let e = ExperimentPresets.make(n)
                let d = try JSONIO.encode(e), e2 = try JSONIO.decode(ExperimentDocument.self, from: d)
                ctx.expect(e2 == e, "\(n) round-trips")
            }
            let minimal = try JSONIO.decode(ExperimentDocument.self, from: Data(#"{"name":"x","population":8,"unknownKey":1}"#.utf8))
            ctx.expect(minimal.name == "x" && minimal.population == 8 && minimal.episode.duration == 30, "tolerant decode with defaults")
        }

        SelfTestRegistry.register("evolution", "evaluator-determinism") { ctx in
            let e = neuralExperiment(duration: 4, episodes: 2)
            let r1 = try makeRun(e, workers: 1), rN = try makeRun(e, workers: 0)
            var rng = EvoRNG(seed: 5)
            let pop = (0..<10).map { Genome(id: UInt64($0 + 1), values: r1.layout.randomValues(&rng)) }
            let f1 = r1.evaluator.evaluate(pop, generation: 3, cancel: nil)
            let fN = rN.evaluator.evaluate(pop, generation: 3, cancel: nil)
            let fN2 = rN.evaluator.evaluate(pop, generation: 3, cancel: nil)
            ctx.expect(f1.map(\.total) == fN.map(\.total), "1 worker vs \((rN.evaluator as! SimEvaluator).workerCount) workers identical")
            ctx.expect(fN.map(\.total) == fN2.map(\.total), "repeat evaluation identical")
            ctx.expect(f1.allSatisfy { $0.error == nil && $0.episodes == 2 }, "no failures: \(f1.compactMap(\.error).first ?? "")")
            ctx.expect(Set(f1.map(\.total)).count > 6, "different genomes → different fitness")
            ctx.expect(f1[0].terms.keys.sorted() == ["altitude", "crash", "level", "speed"], "terms reported: \(f1[0].terms.keys.sorted())")
            ctx.expect(f1[0].descriptor?.count == 2, "descriptor reported")
            ctx.log("layout \(r1.layout.count) genes · fitness range \(String(format: "%.2f…%.2f", f1.map(\.total).min()!, f1.map(\.total).max()!))")
        }

        SelfTestRegistry.register("evolution", "run-checkpoint-resume") { ctx in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pw-evo-selftest-\(getpid())")
            defer { try? FileManager.default.removeItem(at: dir) }
            let e = neuralExperiment(duration: 5)
            let a = try makeRun(e, dir: dir)
            for _ in 0..<2 { try a.runGeneration() }
            try a.checkpoint(to: dir)
            let b = try EvolutionRun.resume(from: dir, world: .flat(), runtimeFactory: { nativeNeuralRuntime() })
            for _ in 0..<2 { try a.runGeneration(); try b.runGeneration() }
            ctx.expect(a.history.map(\.best) == b.history.map(\.best) && a.history.count == 4, "resumed run continues identically (\(a.history.map(\.best)) vs \(b.history.map(\.best)))")
            ctx.expect(b.hallOfFame.count == 4, "hall of fame restored + extended")
            let best = a.hallOfFame.max { $0.fitness.total < $1.fitness.total }!
            let craft = try a.exportCraft(best.genome, fitness: best.fitness)
            let ec = EmbeddedController.find(in: try JSONIO.decode(CraftDocument.self, from: try JSONIO.encode(craft)))
            ctx.expect(ec?.genome == best.genome && ec?.mode == "mlp", "exported craft embeds controller + genome")
            let sim = CraftSim(); try sim.load(craft)
            let ap = try EvolvedAutopilot(craft: craft, sim: sim)
            for _ in 0..<60 { ap.update(sim: sim, env: SimEnvironment(), dt: 1.0 / 60); sim.step(dt: 1.0 / 60, env: SimEnvironment()) }
            ctx.expect(ap.lastError == nil && sim.outputs.contains { $0.name == "Engine" && $0.value != 0 }, "autopilot drives outputs")
        }

        SelfTestRegistry.register("evolution", "replay-matches-training") { ctx in
            let e = neuralExperiment(duration: 6)
            let r = try makeRun(e)
            try r.runGeneration()
            let h = r.hallOfFame[0]
            let tr = try ReplayRecorder.record(context: r.context, genome: h.genome, generation: h.generation, trainingFitness: h.fitness.total,
                                               runtime: nativeNeuralRuntime())
            ctx.expect(tr.fitnessMatches == true, "replay fitness \(tr.outcome) == training \(h.fitness.total)")
            ctx.expect(tr.frames.count > 10 && tr.frames[0].parts.count == tr.craft.parts.count, "frames with part poses (\(tr.frames.count))")
            ctx.expect(tr.sample(at: 1.234) != nil, "interpolated sampling")
        }

        SelfTestRegistry.register("evolution", "zero-alloc-step") { ctx in
            guard AllocationCounter.install() else { ctx.log("allocation hook unavailable — not measured"); return }
            let e = neuralExperiment(duration: 1)
            let r = try makeRun(e, workers: 1)
            let w = try EvalWorker(context: r.context, runtime: nativeNeuralRuntime())
            var rng = EvoRNG(seed: 1)
            let g = Genome(id: 1, values: r.layout.randomValues(&rng))
            _ = try w.prepare(g)
            func allocs(_ duration: Double) throws -> Int {
                var ex = e; ex.episode.duration = duration; ex.episode.stopOnCrash = false
                let ctx2 = try ExperimentContext(experiment: ex, craft: trainer(), world: .flat())
                try ctx2.buildLayout(orchestrator: nativeNeuralRuntime())
                let w2 = try EvalWorker(context: ctx2, runtime: nativeNeuralRuntime()); _ = try w2.prepare(g)
                _ = try w2.runEpisode(g, generation: 0, candidate: 0, episode: 0, seed: 1, observer: nil)  // warm-up
                let a = AllocationCounter.count
                _ = try w2.runEpisode(g, generation: 0, candidate: 0, episode: 0, seed: 1, observer: nil)
                return AllocationCounter.count - a
            }
            let short = try allocs(1), long = try allocs(11)
            let perTick = Double(long - short) / (10 * e.controller.hz)
            ctx.log(String(format: "allocations: 1 s episode %d, 11 s episode %d → %.3f per control tick (%d physics substeps each)",
                           short, long, perTick, Int(e.episode.physicsHz / e.controller.hz)))
            ctx.expect(perTick < 0.05, "no per-step heap allocations in the episode loop (\(perTick)/tick)")
            // and the plain physics step
            let sim = CraftSim(); try sim.load(trainer()); let env = HeadlessWorld.flat().makeEnvironment(wind: [2, 0, 1])
            for _ in 0..<10 { sim.step(dt: 0.02, env: env) }
            let buf = UnsafeMutablePointer<Double>.allocate(capacity: sim.inputCount); defer { buf.deallocate() }
            let a0 = AllocationCounter.count
            for _ in 0..<200 { sim.step(dt: 0.02, env: env); sim.readSensors(env: env, into: buf) }
            let a1 = AllocationCounter.count - a0
            ctx.expect(a1 == 0, "CraftSim.step + readSensors allocate nothing (\(a1) in 4000 substeps)")
        }

        SelfTestRegistry.register("evolution", "bench-headless") { ctx in
            #if DEBUG
            ctx.log("skipped in debug builds (numbers meaningless) — run a release build"); return
            #endif
            // Trainer, 1 kHz physics, 50 Hz MLP control, flat baked terrain. Reports sim-seconds per wall-second.
            var e = neuralExperiment(duration: 30)
            e.episode.stopOnCrash = false
            let r1 = try makeRun(e, workers: 1)
            var rng = EvoRNG(seed: 11)
            let pop1 = (0..<4).map { Genome(id: UInt64($0), values: r1.layout.randomValues(&rng)) }
            _ = r1.evaluator.evaluate(pop1, generation: 0, cancel: nil)
            let s1 = r1.evaluator.lastStats
            let rN = try makeRun(e, workers: 0)
            let nW = (rN.evaluator as! SimEvaluator).workerCount
            let popN = (0..<(nW * 4)).map { Genome(id: UInt64($0), values: rN.layout.randomValues(&rng)) }
            _ = rN.evaluator.evaluate(popN, generation: 0, cancel: nil)
            let sN = rN.evaluator.lastStats
            ctx.log(String(format: "1 core : %3d episodes × 30 s in %.2f s wall → %.0f sim-s/wall-s, %.2f sims/s, %.2f µs/substep",
                           s1.episodes, s1.wallSeconds, s1.simSecondsPerWallSecond, s1.simsPerSecond, s1.wallSeconds / (s1.simSeconds * 1000) * 1e6))
            ctx.log(String(format: "%d cores: %3d episodes × 30 s in %.2f s wall → %.0f sim-s/wall-s, %.2f sims/s (speedup %.1f×)",
                           nW, sN.episodes, sN.wallSeconds, sN.simSecondsPerWallSecond, sN.simsPerSecond, sN.simSecondsPerWallSecond / max(1e-9, s1.simSecondsPerWallSecond)))
            ctx.expect(s1.simSecondsPerWallSecond > 1 && sN.simSecondsPerWallSecond > s1.simSecondsPerWallSecond, "headless faster than real time and scales")
        }
    }
}
