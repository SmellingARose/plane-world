// OWNED BY profiler. Benchmark harness (release builds; numbers from debug builds are meaningless).
//   PlaneWorld --bench <name|group|all|list> [--reps N] [--quick] [--json out.json]
// Every benchmark runs `reps` repetitions (after a warm-up) and prints median / min / max per metric.
// Groups: physics, headless, train, js, nn, render, cpu, terrain, water, fluid, buoyancy. See docs/PERF.md.
import Foundation
import Metal
import simd
import Darwin
import PWCore
import PWRender
import PWPhysics
import PWCraft
import PWTerrain
import PWWater
import PWEvolution

// MARK: - allocation counter (malloc_logger hook; counts every allocation in the process while armed)

nonisolated(unsafe) var benchAllocCount = 0
nonisolated(unsafe) var benchAllocArmed = false
typealias BenchMallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
let benchMallocHook: BenchMallocLogger = { type, _, _, _, _, _ in
    if benchAllocArmed && (type & 2) != 0 { benchAllocCount += 1 }   // MALLOC_LOG_TYPE_ALLOCATE
}
enum AllocCounter {
    static let slot: UnsafeMutablePointer<BenchMallocLogger?>? = {
        guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }   // RTLD_DEFAULT
        return s.assumingMemoryBound(to: BenchMallocLogger?.self)
    }()
    /// Allocations made by `body` (all threads; benchmarks keep the pool idle while counting). nil if unavailable.
    static func count(_ body: () -> Void) -> Int? {
        guard let slot, slot.pointee == nil else { body(); return nil }
        benchAllocCount = 0; slot.pointee = benchMallocHook; benchAllocArmed = true
        body()
        benchAllocArmed = false; slot.pointee = nil
        return benchAllocCount
    }
}

@inline(__always) func benchNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

// MARK: - harness

struct BenchResult { var name: String; var metric: String; var unit: String; var samples: [Double]
    var median: Double { let s = samples.sorted(); return s.isEmpty ? .nan : s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2]) }
}

@MainActor
final class Bench {
    var reps = 7
    var quick = false
    var results: [BenchResult] = []

    func record(_ name: String, _ metric: String, _ unit: String, _ samples: [Double]) {
        let r = BenchResult(name: name, metric: metric, unit: unit, samples: samples)
        results.append(r)
        let s = samples.sorted()
        let spread = s.count > 1 && r.median != 0 ? String(format: "±%4.1f%%", 100 * (s.last! - s.first!) / 2 / abs(r.median)) : "      "
        print(Self.pad(name, 36) + Self.pad(metric, 28) + String(format: "%12.4g ", r.median) + Self.pad(unit, 7)
              + String(format: "min %10.4g  max %10.4g  %@  n=%d", s.first ?? .nan, s.last ?? .nan, spread, s.count))
        fflush(stdout)
    }
    nonisolated static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count) }
    /// Run `body` reps times (+1 warm-up); body returns metric → value.
    func repeatRun(_ name: String, reps n: Int? = nil, units: [String: String], _ body: () throws -> [String: Double]) rethrows {
        _ = try body()
        var acc: [String: [Double]] = [:]
        for _ in 0..<(n ?? reps) { for (k, v) in try body() { acc[k, default: []].append(v) } }
        for k in acc.keys.sorted() { record(name, k, units[k] ?? "", acc[k]!) }
    }

    static let all: [(String, (Bench) throws -> Void)] = [
        ("physics.substep", { try $0.physicsSubstep() }),
        ("physics.batch", { try $0.physicsBatch() }),
        ("headless.episode", { try $0.headlessEpisode() }),
        ("js.controller-call", { try $0.jsCall() }),
        ("nn.forward", { $0.nnForward() }),
        ("train.scaling", { try $0.trainScaling() }),
        ("train.generation", { try $0.trainGeneration() }),
        ("train.batch", { try $0.trainBatch() }),
        ("terrain.erosion", { try $0.erosion() }),
        ("water.fft", { try $0.waterFFT() }),
        ("buoyancy", { try $0.buoyancy() }),
        ("fluid.step", { try $0.fluidStep() }),
        ("render.frame", { try $0.renderFrame() }),   // also emits cpu.frame
        ("placement.gpu-latency", { try $0.placementGPULatency() }),
        ("placement.train-mix", { try $0.placementTrainMix() }),
        ("placement.train-pool", { try $0.placementTrainPool() }),
        ("placement.coexist", { try $0.placementCoexist() }),
    ]

    // MARK: physics.substep

    static func flightCraft(_ name: String) -> CraftDocument? {
        let doc: CraftDocument? = name == "Trainer" ? (CraftPresets.load("Trainer") ?? PhysicsPresets.trainer()) : CraftPresets.load(name)
        return doc.map { CraftOutputs.prepareForFlight(ExperimentPresets.addStandardSensors($0)) }
    }

    /// Trainer + CAD parts (sphere panel meshes) up to `parts` total parts.
    static func cadCraft(parts total: Int, segments: Int = 12, rings: Int = 6) throws -> (CraftSim, panels: Int) {
        var doc = flightCraft("Trainer")!
        let extra = max(0, total - doc.parts.count)
        let sphere = MeshBuilder.sphere(radius: 0.35, segments: segments, rings: rings)
        var soup: [Vec3d] = []
        for t in stride(from: 0, to: sphere.indices.count, by: 3) {
            for k in 0..<3 { let v = sphere.vertices[Int(sphere.indices[t + k])]; soup.append(Vec3d(Double(v.px), Double(v.py), Double(v.pz))) }
        }
        for i in 0..<extra {
            var p = CraftPart(id: "cad\(i)", type: .cad, name: "pod \(i)", pos: Vec3d(-2 + Double(i % 15) * 0.3, 0.4 + Double(i / 15) * 0.2, Double(i % 3 - 1) * 0.6))
            p.mass = 2
            doc.parts.append(p)
        }
        let s = CraftSim()
        try s.load(doc)
        for i in 0..<extra { s.setPartMesh(partID: "cad\(i)", soup: soup) }
        return (s, extra * soup.count / 3)
    }

    func physicsSubstep() throws {
        let world = HeadlessWorld.flat()
        let n = quick ? 2000 : 10000
        func bench(_ label: String, _ sim: CraftSim, air: Bool) {
            sim.substepHz = 1000
            let env0 = world.makeEnvironment(wind: Vec3d(2, 0, 1), time: 0)
            func resetSim() {
                if air {
                    sim.reset(spawn: Transform(position: [0, 300, 0]))
                    sim.setVelocity(linear: [45, 0, 0], angular: .zero)
                } else { sim.reset(spawn: sim.restingSpawn(groundHeight: 0)) }
                sim.turbulence = 0.3
                for i in 0..<sim.outputs.count { sim.setOutput(index: i, value: sim.outputs[i].kind == .motor ? 0.8 : 0.1) }
            }
            var allocs = 0
            repeatRun("physics.substep." + label, units: ["us/substep": "µs", "allocs/substep": "count"]) {
                resetSim()
                var env = env0
                let t0 = benchNow()
                for _ in 0..<(n / 20) { sim.step(dt: 0.02, env: env); env.time += 0.02 }
                let us = Double(benchNow() - t0) / 1e3 / Double(n)
                var e2 = env
                let a = AllocCounter.count { for _ in 0..<5 { sim.step(dt: 0.02, env: e2); e2.time += 0.02 } } ?? -1
                allocs = a
                return ["us/substep": us, "allocs/substep": Double(a) / 100]
            }
            _ = allocs
        }
        for (label, name) in [("trainer", "Trainer"), ("jet", "Jet trainer"), ("rover", "Rover"), ("rocket", "Sounding rocket")] {
            guard let doc = Self.flightCraft(name) else { print("physics.substep.\(label): craft '\(name)' missing"); continue }
            let s = CraftSim(); try s.load(doc)
            bench(label + (label == "rover" ? ".ground" : ".air"), s, air: label != "rover")
            if label == "trainer" { let g = CraftSim(); try g.load(doc); bench("trainer.runway", g, air: false) }
        }
        let (cad, panels) = try Self.cadCraft(parts: 60)
        print("  cad60: 60 parts, \(panels) CAD panels (serial per mesh: each < parallelThreshold \(cad.parallelThreshold))")
        bench("cad60.air", cad, air: true)
        let (big, bigPanels) = try Self.cadCraft(parts: 60, segments: 24, rings: 12)
        print("  cad60.big: \(bigPanels) CAD panels (parallelFor per mesh)")
        bench("cad60big.air", big, air: true)
        big.parallelThreshold = .max
        bench("cad60big.air.serial", big, air: true)
    }

    // MARK: physics.batch (SIMD lanes: K candidates per thread in lockstep)

    /// Runs `body` on a fresh thread with the given QoS (background → E-cores on Apple silicon) and waits.
    nonisolated static func onThread<T>(_ qos: QualityOfService, _ body: @escaping () -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        let box = UnsafeMutablePointer<T?>.allocate(capacity: 1); box.initialize(to: nil)
        let th = Thread { box.pointee = body(); done.signal() }
        th.qualityOfService = qos; th.stackSize = 4 << 20; th.start(); done.wait()
        let r = box.pointee!; box.deinitialize(count: 1); box.deallocate(); return r
    }

    /// Lane throughput of `CraftSimBatch` (K = 2/4/8) against K scalar sims (K = 1), on a P-core and an E-core.
    func physicsBatch() throws {
        let world = HeadlessWorld.flat()
        let seconds = quick ? 2.0 : 8.0   // simulated seconds per lane per rep
        func measure(_ doc: CraftDocument, air: Bool, K: Int, qos: QualityOfService) throws -> Double {
            var sims: [CraftSim] = []
            for l in 0..<K {
                let s = CraftSim(); try s.load(doc); s.substepHz = 1000; s.turbulence = Double(ProcessInfo.processInfo.environment["PW_BATCH_TURB"] ?? "") ?? 0.3
                if air { s.reset(spawn: Transform(position: [Double(l) * 3, 300, 0])); s.setVelocity(linear: [45, 0, 0], angular: .zero) }
                else { s.reset(spawn: s.restingSpawn(groundHeight: 0)) }
                for i in 0..<s.outputs.count { s.setOutput(index: i, value: s.outputs[i].kind == .motor ? 0.8 : 0.1 * Double(l + 1) / Double(K)) }
                sims.append(s)
            }
            let batch = K > 1 ? CraftSimBatch(lanes: K, template: sims[0]) : nil
            for l in 0..<K { batch?.attach(sims[l], lane: l) }
            let envs = UnsafeMutablePointer<SimEnvironment>.allocate(capacity: K)
            for l in 0..<K { (envs + l).initialize(to: world.makeEnvironment(wind: Vec3d(2, 0, 1), time: 0)) }
            defer { envs.deinitialize(count: K); envs.deallocate() }
            let steps = Int(seconds / 0.02)
            let wall: Double = Self.onThread(qos) {
                let t0 = benchNow()
                for _ in 0..<steps {
                    if let batch { batch.step(dt: 0.02, envs: envs) } else { for l in 0..<K { sims[l].step(dt: 0.02, env: envs[l]) } }
                    for l in 0..<K { envs[l].time += 0.02 }
                }
                return Double(benchNow() - t0) / 1e9
            }
            return Double(K) * seconds / wall   // lane sim-seconds per wall-second (physics only)
        }
        // PW_BATCH_FILTER=<substring> restricts the variants (e.g. "trainer.air.P"); PW_BATCH_K="1,4" the lane counts.
        let filter = ProcessInfo.processInfo.environment["PW_BATCH_FILTER"] ?? ""
        let ks = (ProcessInfo.processInfo.environment["PW_BATCH_K"] ?? "1,2,4,8").split(separator: ",").compactMap { Int($0) }
        for (label, name, air) in [("trainer.air", "Trainer", true), ("trainer.runway", "Trainer", false), ("jet.air", "Jet trainer", true), ("rover.ground", "Rover", false)] {
            guard let doc = Self.flightCraft(name) else { print("physics.batch.\(label): craft '\(name)' missing"); continue }
            for (core, qos) in [("P", QualityOfService.userInteractive), ("E", .background)] where filter.isEmpty || "\(label).\(core)".contains(filter) {
                for K in ks {
                    try repeatRun("physics.batch.\(label).\(core)", units: ["sim-s/s K=\(K)": "x", "us/lane-substep K=\(K)": "µs"]) {
                        let r = try measure(doc, air: air, K: K, qos: qos)
                        return ["sim-s/s K=\(K)": r, "us/lane-substep K=\(K)": 1e6 / (r * 1000)]
                    }
                }
            }
        }
    }

    // MARK: training

    struct TrainSetup { let exp: ExperimentDocument; let craft: CraftDocument; let world: HeadlessWorld }
    static func trainSetup(_ path: String = "examples/experiments/neural.json") throws -> TrainSetup {
        let url = URL(fileURLWithPath: path)
        let e = try ExperimentDocument.load(url)
        guard let craft = TrainCLI.resolveCraft(e.crafts.first, experimentURL: url) else { throw EvolutionError.invalidExperiment("craft not found") }
        let world = try HeadlessWorld.resolve(e.world, experimentURL: url, options: e.headless, seed: e.seed, current: { .flat() })
        return TrainSetup(exp: e, craft: craft, world: world)
    }
    static func makeRun(_ s: TrainSetup, workers: Int, population: Int, runtime: ScriptRuntimeFactory? = nil) throws -> EvolutionRun {
        var e = s.exp; e.workers = workers; e.population = population
        return try EvolutionRun(experiment: e, craft: s.craft, world: s.world, directory: FileManager.default.temporaryDirectory.appendingPathComponent("pw-bench-run"),
                                runtimeFactory: runtime)
    }

    func headlessEpisode() throws {
        let s = try Self.trainSetup()
        let run = try Self.makeRun(s, workers: 1, population: 16)
        let pop = try run.algorithm.ask()
        guard let ev = run.evaluator as? SimEvaluator else { return }
        for (label, rt) in [("js", ScriptRuntimes.make(for: s.exp.scripts)), ("null-script", NullScriptRuntime() as any ScriptRuntime)] {
            let w = try ev.makeStandaloneWorker(runtime: rt)
            var idx = 0
            repeatRun("headless.episode." + label, units: ["ms/episode": "ms", "sim-s/wall-s": "x", "us/substep": "µs", "ticks": "count"]) {
                var simT = 0.0, eps = 0, ticks = 0
                let t0 = benchNow()
                for _ in 0..<(quick ? 2 : 4) {
                    let f = w.evaluate(pop[idx % pop.count], generation: 0, candidate: idx % pop.count); idx += 1
                    simT += f.simSeconds; eps += f.episodes; ticks += f.controlTicks
                }
                let wall = Double(benchNow() - t0) / 1e9
                return ["ms/episode": wall * 1e3 / Double(max(1, eps)), "sim-s/wall-s": simT / wall, "us/substep": wall * 1e6 / max(1e-9, simT * s.exp.episode.physicsHz),
                        "ticks": Double(ticks) / Double(max(1, eps))]
            }
        }
    }

    /// Free-running throughput: N threads, each with a private worker, no generation barrier.
    /// Separates hardware scaling (P/E cores, caches, bandwidth) from barrier/tail effects of train.generation.
    func trainScaling() throws {
        let s = try Self.trainSetup()
        let run = try Self.makeRun(s, workers: 1, population: 64)
        let pop = try run.algorithm.ask()
        guard let ev = run.evaluator as? SimEvaluator else { return }
        let maxN = ProcessInfo.processInfo.activeProcessorCount
        let workers = try (0..<maxN).map { _ in try ev.makeStandaloneWorker(runtime: ScriptRuntimes.make(for: s.exp.scripts)) }
        let seconds = quick ? 2.0 : 5.0
        // Same workload, but every thread's worker comes from its own run built from a freshly decoded experiment +
        // craft, so no Swift heap object (CraftDocument dictionaries/arrays, context) is shared between threads.
        var isolated: [EvalWorker] = []
        for _ in 0..<maxN {
            let si = try Self.trainSetup()
            let ri = try Self.makeRun(si, workers: 1, population: 64)
            if let evi = ri.evaluator as? SimEvaluator { isolated.append(try evi.makeStandaloneWorker(runtime: ScriptRuntimes.make(for: si.exp.scripts))) }
        }
        func measure(_ n: Int, qos: QualityOfService, isolatedWorkers: Bool = false) -> Double {
            let workers = isolatedWorkers ? isolated : workers
            let lock = NSLock(); var total = 0.0
            let done = DispatchSemaphore(value: 0)
            let stop = UnsafeMutablePointer<Bool>.allocate(capacity: 1); stop.initialize(to: false)
            let start = DispatchSemaphore(value: 0)
            for t in 0..<n {
                let w = workers[t]
                let th = Thread {
                    start.wait()
                    var simT = 0.0, i = t * 7
                    while !stop.pointee {
                        let c = i % pop.count
                        simT += w.evaluate(pop[c], generation: 0, candidate: c).simSeconds
                        i += 1
                    }
                    lock.lock(); total += simT; lock.unlock()
                    done.signal()
                }
                th.qualityOfService = qos; th.stackSize = 4 << 20; th.start()
            }
            let t0 = benchNow()
            for _ in 0..<n { start.signal() }
            Thread.sleep(forTimeInterval: seconds)
            stop.pointee = true
            for _ in 0..<n { done.wait() }
            let wall = Double(benchNow() - t0) / 1e9   // includes the last in-flight candidate of every thread
            stop.deallocate()
            return total / wall
        }
        let r = reps >= 5 && !quick ? 3 : 1
        var base = 0.0
        for n in [1, 2, 4, 6, 8, 10] where n <= maxN {
            let v = (0..<r).map { _ in measure(n, qos: .userInteractive) }
            record("train.scaling.free-running", "sim-s/s @\(n)T", "x", v)
            let m = BenchResult(name: "", metric: "", unit: "", samples: v).median
            if n == 1 { base = m } else { record("train.scaling.free-running", "efficiency @\(n)T", "%", [100 * m / (Double(n) * base)]) }
        }
        for n in [4, 10] where n <= maxN {
            record("train.scaling.isolated-heap", "sim-s/s @\(n)T", "x", (0..<r).map { _ in measure(n, qos: .userInteractive, isolatedWorkers: true) })
        }
        let e1 = (0..<r).map { _ in measure(1, qos: .background) }
        record("train.scaling.free-running", "sim-s/s @1T E-core(bg)", "x", e1)
        let e6 = (0..<r).map { _ in measure(6, qos: .background) }
        record("train.scaling.free-running", "sim-s/s @6T E-cores(bg)", "x", e6)
    }

    func trainGeneration() throws {
        let s = try Self.trainSetup()
        for (w, pop) in [(1, 16), (4, 64), (10, 64)] {
            let run = try Self.makeRun(s, workers: w, population: pop)
            _ = try run.runGeneration()                 // warm-up generation (also moves CMA-ES off its start point)
            var sims: [Double] = [], simsec: [Double] = []
            for _ in 0..<(quick ? 1 : 3) { let rec = try run.runGeneration(); sims.append(rec.simsPerSecond); simsec.append(rec.simSecondsPerWallSecond) }
            record("train.generation.\(w)w.pop\(pop)", "sims/s", "1/s", sims)
            record("train.generation.\(w)w.pop\(pop)", "sim-s/wall-s", "x", simsec)
        }
        print("  (scaling efficiency = rate(N) / (N × rate(1)); compare with train.scaling.free-running for the barrier/tail loss)")
    }

    /// Evaluator throughput with SIMD lanes (ExperimentDocument.batchLanes = K): one generation on one P-core
    /// thread, on one E-core thread (background QoS), and on 10 workers. K = 1 is the scalar CraftSim path.
    /// Every K produces bit-identical fitness (checked here too). PW_BATCH_K / PW_BATCH_FILTER ("P", "E", "10w").
    func trainBatch() throws {
        let s = try Self.trainSetup()
        let filter = ProcessInfo.processInfo.environment["PW_BATCH_FILTER"] ?? ""
        let ks = (ProcessInfo.processInfo.environment["PW_BATCH_K"] ?? "1,2,4,8").split(separator: ",").compactMap { Int($0) }
        var reference: [String: [UInt64]] = [:]
        func check(_ key: String, _ f: [Fitness]) {
            let b = f.map { $0.total.bitPattern }
            if let r = reference[key] { if r != b { print("  !! \(key): fitness differs from K=1") } } else { reference[key] = b }
        }
        for (label, qos, workers, pop) in [("P", QualityOfService.userInteractive, 1, 8), ("E", .background, 1, 4), ("10w", .userInteractive, Int(ProcessInfo.processInfo.environment["PW_BATCH_WORKERS"] ?? "") ?? 10, Int(ProcessInfo.processInfo.environment["PW_BATCH_POP"] ?? "") ?? 64)]
            where filter.isEmpty || label == filter {
            for K in ks {
                var e = s.exp; e.batchLanes = K
                let run = try Self.makeRun(TrainSetup(exp: e, craft: s.craft, world: s.world), workers: workers, population: pop)
                let genomes = try run.algorithm.ask()
                guard let ev = run.evaluator as? SimEvaluator else { return }
                try repeatRun("train.batch.\(label)", units: ["sim-s/s K=\(K)": "x"]) {
                    let (f, wall): ([Fitness], Double) = workers == 1
                        ? Self.onThread(qos) { let t0 = benchNow(); let f = ev.evaluate(genomes, generation: 0, cancel: nil); return (f, Double(benchNow() - t0) / 1e9) }
                        : { let t0 = benchNow(); let f = ev.evaluate(genomes, generation: 0, cancel: nil); return (f, Double(benchNow() - t0) / 1e9) }()
                    check(label, f)
                    return ["sim-s/s K=\(K)": f.reduce(0) { $0 + $1.simSeconds } / wall]
                }
            }
        }
    }

    // MARK: js / nn

    func jsCall() throws {
        let s = try Self.trainSetup()
        let run = try Self.makeRun(s, workers: 1, population: 4)
        let g = try run.algorithm.ask()[0]
        guard let ev = run.evaluator as? SimEvaluator else { return }
        let w = try ev.makeStandaloneWorker(runtime: NullScriptRuntime())
        _ = w   // context built; drive the JS runtime directly on a frame
        let sim = CraftSim(); try sim.load(s.craft)
        let frame = ControlFrame(inputNames: sim.inputs.map(\.name), outputNames: sim.outputs.map(\.name), termNames: run.termNames)
        for (label, rt) in [("js", JSScriptRuntime() as any ScriptRuntime), ("null", NullScriptRuntime() as any ScriptRuntime)] {
            try rt.compile(s.exp.scripts, experiment: s.exp)
            _ = try rt.termNames(default: s.exp.rewardTerms)
            let n = quick ? 20000 : 100000
            try repeatRun("js.controller-call." + label, units: ["us/tick": "µs"]) {
                try rt.beginEpisode(genome: g, frame: frame)
                let t0 = benchNow()
                for k in 0..<n { frame.tick = k; frame.state.y = Double(k % 300); try rt.tick(frame) }
                return ["us/tick": Double(benchNow() - t0) / 1e3 / Double(n)]
            }
        }
    }

    func nnForward() {
        for sizes in [[9, 12, 4], [32, 64, 64, 8], [128, 256, 256, 16]] {
            let mlp = MLPPolicy(sizes: sizes)
            var rng = EvoRNG(seed: 3)
            let w = (0..<MLPPolicy.parameterCount(sizes)).map { _ in rng.uniform(-0.3, 0.3) }
            w.withUnsafeBufferPointer { mlp.load($0) }
            let x = UnsafeMutablePointer<Double>.allocate(capacity: sizes[0]); let y = UnsafeMutablePointer<Double>.allocate(capacity: sizes.last!)
            for i in 0..<sizes[0] { x[i] = rng.uniform(-1, 1) }
            let macs = zip(sizes, sizes.dropFirst()).reduce(0) { $0 + $1.0 * $1.1 }
            let n = max(1000, (quick ? 2_000_000 : 10_000_000) / macs)
            repeatRun("nn.forward." + sizes.map(String.init).joined(separator: "-"), units: ["ns/forward": "ns", "GFLOP/s": "GF/s"]) {
                let t0 = benchNow()
                for _ in 0..<n { mlp.forward(x, y); x[0] = y[0] * 0.5 }
                let ns = Double(benchNow() - t0) / Double(n)
                return ["ns/forward": ns, "GFLOP/s": 2 * Double(macs) / ns]
            }
            x.deallocate(); y.deallocate()
        }
    }

    // MARK: terrain / water / fluid

    func erosion() throws {
        guard GPU.shared != nil else { print("terrain.erosion: no GPU"); return }
        for size in quick ? [1025] : [1025, 2049] {
            var p = ProceduralParams(); p.size = size; p.spacing = 8; p.erosionIterations = 0; p.thermalIterations = 0
            let half = Double(size - 1) * 4
            let src = HeightField(width: size, height: size, spacing: 8, origin: Vec2d(-half, -half))
            ProceduralTerrain.generate(into: src, seed: 1, params: p)
            let base = Array(src.base.buffer)
            var ep = ErosionParams(); ep.iterations = 160; ep.thermalIterations = 40
            try repeatRun("terrain.erosion.\(size)", reps: quick ? 1 : 3, units: ["gpu ms": "ms", "wall ms": "ms", "us/iteration(gpu)": "µs"]) {
                base.withUnsafeBufferPointer { b in src.base.ptr.update(from: b.baseAddress!, count: b.count) }
                let t0 = benchNow()
                let r = try TerrainErosion.run(field: src, params: ep)
                return ["gpu ms": r.gpuMs, "wall ms": Double(benchNow() - t0) / 1e6, "us/iteration(gpu)": r.gpuMs * 1e3 / 200]
            }
            let t0 = benchNow(); ProceduralTerrain.generate(into: src, seed: 1, params: p)
            record("terrain.noise.\(size)", "cpu ms", "ms", [Double(benchNow() - t0) / 1e6])
        }
    }

    func waterFFT() throws {
        guard let gpu = GPU.shared else { print("water.fft: no GPU"); return }
        let water = WaterSystem(gpu: gpu)
        var spec = WaterSpec(); spec.oceanEnabled = true; spec.windSpeed = 8
        try water.load(spec: spec)
        var t = 0.0
        repeatRun("water.fft", units: ["gpu ms/update": "ms", "cpu us/step": "µs", "sample ns": "ns"]) {
            var g: [Double] = [], c: [Double] = []
            for _ in 0..<20 {
                t += 1.0 / 60
                let t0 = benchNow(); water.step(dt: 1.0 / 60, time: t); c.append(Double(benchNow() - t0) / 1e3)
                Thread.sleep(forTimeInterval: 0.012)
                g.append(water.oceanGPUTimeMs)
            }
            let n = 20000; var acc = 0.0
            let t1 = benchNow()
            for i in 0..<n { acc += water.sample(x: Double(i % 200), z: Double(i / 200), time: t).surfaceHeight }
            let ns = Double(benchNow() - t1) / Double(n)
            if acc.isNaN { print("nan") }
            return ["gpu ms/update": g.sorted()[g.count / 2], "cpu us/step": c.sorted()[c.count / 2], "sample ns": ns]
        }
    }

    func buoyancy() throws {
        let water = WaterSystem(gpu: GPU.shared)
        var spec = WaterSpec(); spec.oceanEnabled = true; spec.windSpeed = 8
        try water.load(spec: spec)
        for _ in 0..<30 { water.step(dt: 1.0 / 60, time: 0); Thread.sleep(forTimeInterval: 0.005) }
        for (seg, rings) in [(16, 8), (48, 24), (128, 64)] {
            let m = MeshBuilder.sphere(radius: 2, segments: seg, rings: rings)
            let hull = HullMesh(positions: m.vertices.map { Vec3($0.px, $0.py, $0.pz) * Vec3(3, 1, 1) }, indices: m.indices)
            let st = BodyState(transform: Transform(position: [0, 0.3, 0]), linearVelocity: [3, 0, 0], angularVelocity: [0, 0.1, 0], centerOfMass: [0, 0.3, 0])
            let n = max(20, 400_000 / (m.indices.count / 3))
            repeatRun("buoyancy.\(m.indices.count / 3)tris", units: ["us/call": "µs"]) {
                let t0 = benchNow()
                for i in 0..<n { _ = water.submergedForces(hull: hull, state: st, time: Double(i) * 0.001) }
                return ["us/call": Double(benchNow() - t0) / 1e3 / Double(n)]
            }
        }
    }

    func fluidStep() throws {
        guard let gpu = GPU.shared else { print("fluid.step: no GPU"); return }
        for dims in quick ? [SIMD3<Int>(64, 64, 64)] : [SIMD3<Int>(32, 32, 32), SIMD3<Int>(64, 64, 64)] {
            let z = try FluidZone(device: gpu.device, queue: gpu.queue, origin: .zero, dims: dims, cellSize: 4.0 / Double(dims.x))
            repeatRun("fluid.step.\(dims.x)^3", units: ["ms/frame(1/60s)": "ms"]) {
                let t0 = benchNow(); z.stepSync(dt: 1.0 / 60)
                return ["ms/frame(1/60s)": Double(benchNow() - t0) / 1e6]
            }
        }
    }

    // MARK: render.frame + cpu.frame (headless AppModel, offscreen target at native res)

    func renderFrame() throws {
        guard let gpu = GPU.shared else { print("render.frame: no GPU"); return }
        let W = 3200, H = 1920
        let model = AppModel()
        let r = try Renderer(device: gpu.device, queue: gpu.queue, outputFormat: .bgra8Unorm_srgb)
        model.attachRenderer(r)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: W, height: H, mipmapped: false)
        d.usage = [.renderTarget]; d.storageMode = .private
        guard let tex = gpu.device.makeTexture(descriptor: d) else { return }
        let frames = quick ? 30 : 90
        func run(_ label: String, frames: Int, cpu: Bool) {
            var tick: [Double] = [], enc: [Double] = [], gpuT: [Double] = [], wall: [Double] = []
            var passes: [String: [Double]] = [:]
            let tStart = benchNow()
            for i in 0..<frames {
                let t0 = benchNow()
                model.tick(dt: 1.0 / 60)
                let t1 = benchNow()
                r.render(to: tex, camera: model.camera.camera, time: model.services.clock.simTime, waitUntilCompleted: true)
                let t2 = benchNow()
                if i >= 5 {
                    tick.append(Double(t1 - t0) / 1e6); wall.append(Double(t2 - t0) / 1e6); gpuT.append(r.lastGPUTimeMs)
                    for (k, v) in r.passTimesMs { passes[k, default: []].append(v) }
                }
            }
            _ = tStart
            // encode time: render() with completion wait excluded (3 frames in flight, measure call duration only)
            // CPU encode time: the frame before is waited on, so render() never blocks on the in-flight semaphore.
            for _ in 0..<12 {
                model.tick(dt: 1.0 / 60)
                r.render(to: tex, camera: model.camera.camera, time: model.services.clock.simTime, waitUntilCompleted: true)
                let t0 = benchNow(); r.render(to: tex, camera: model.camera.camera, time: model.services.clock.simTime); enc.append(Double(benchNow() - t0) / 1e6)
            }
            enc = Array(enc.dropFirst(4))
            r.render(to: tex, camera: model.camera.camera, time: 0, waitUntilCompleted: true)
            // GPU total without timestamp sampling (stage-boundary counters can serialise passes on TBDR).
            var s2 = r.settings; s2.passTimings = false; r.settings = s2
            var g2: [Double] = []
            for i in 0..<30 { model.tick(dt: 1.0 / 60); r.render(to: tex, camera: model.camera.camera, time: model.services.clock.simTime, waitUntilCompleted: true); if i >= 5 { g2.append(r.lastGPUTimeMs) } }
            s2.passTimings = true; r.settings = s2
            record("render.frame.\(label)", "gpu total (no timestamps)", "ms", g2)
            record("render.frame.\(label)", "gpu total", "ms", gpuT)
            for k in Renderer.timedPassNames { if let v = passes[k] { record("render.frame.\(label)", "pass " + k, "ms", v) } }
            if cpu {
                record("cpu.frame.\(label)", "model.tick (main)", "ms", tick)
                record("cpu.frame.\(label)", "render() encode", "ms", enc)
                record("cpu.frame.\(label)", "frame wall (sync)", "ms", wall)
            }
        }
        func hdr(_ label: String) -> Double {
            var v: [Double] = []
            for i in 0..<40 {
                model.tick(dt: 1.0 / 60)
                r.render(to: tex, camera: model.camera.camera, time: model.services.clock.simTime, waitUntilCompleted: true)
                if i >= 8 { let p = r.passTimesMs; v.append((p["hdr"] ?? 0) + (p["shadow0"] ?? 0) + (p["shadow1"] ?? 0) + (p["shadow2"] ?? 0) + (p["shadow3"] ?? 0)) }
            }
            return BenchResult(name: "", metric: "", unit: "", samples: v).median
        }
        for tab in [AppTab.fly, AppTab.world] {
            model.tab = tab
            for _ in 0..<5 { model.tick(dt: 1.0 / 60) }
            let label = tab == .fly ? "FLY" : "WORLD"
            print("  render.frame.\(label): \(W)x\(H) offscreen, TAA, \(model.vegetation.aliveTreeCount) trees")
            run(label, frames: frames, cpu: true)
            // Per-renderable cost by subtraction (hdr + shadow passes, everything else unchanged).
            let full = hdr(label)
            if let vr = model.vegRenderable {
                vr.settings.grassEnabled = false; let noGrass = hdr(label); vr.settings.grassEnabled = true
                RenderRegistry.shared.remove(vr); let noVeg = hdr(label); RenderRegistry.shared.add(vr)
                record("render.frame.\(label)", "Δ grass (hdr+shadow)", "ms", [full - noGrass])
                record("render.frame.\(label)", "Δ trees (hdr+shadow)", "ms", [noGrass - noVeg])
            }
            if let tr = model.terrain.renderable {
                RenderRegistry.shared.remove(tr); let v = hdr(label); RenderRegistry.shared.add(tr)
                record("render.frame.\(label)", "Δ terrain (hdr+shadow)", "ms", [full - v])
            }
            RenderRegistry.shared.remove(model.water); let nw = hdr(label); RenderRegistry.shared.add(model.water)
            record("render.frame.\(label)", "Δ water (hdr+shadow)", "ms", [full - nw])
            let others = RenderRegistry.shared.all
            for o in others { RenderRegistry.shared.remove(o) }
            let sky = hdr(label)
            for o in others { RenderRegistry.shared.add(o) }
            record("render.frame.\(label)", "sky+empty hdr/shadow", "ms", [sky])
        }
    }

    // MARK: entry

    nonisolated static func run(_ args: [String]) -> Int32 {
        MainActor.assumeIsolated {
            let b = Bench()
            if let r = TrainCLI.value(args, "--reps").flatMap(Int.init) { b.reps = max(1, r) }
            b.quick = args.contains("--quick")
            if b.quick && TrainCLI.value(args, "--reps") == nil { b.reps = 3 }
            let name = TrainCLI.value(args, "--bench") ?? "all"
            if name == "list" { for (n, _) in all { print(n) }; return 0 }
            ScriptedAlgorithmRegistration.register()
            JSScriptRuntime.logHandler = nil
            let sel = all.filter { name == "all" || $0.0 == name || $0.0.hasPrefix(name + ".") || name.hasPrefix($0.0) || ($0.0 == "render.frame" && name == "cpu.frame") }
            if sel.isEmpty { print("unknown bench '\(name)'; --bench list"); return 2 }
            #if DEBUG
            print("WARNING: debug build — numbers are not representative. Use swift build -c release.")
            #endif
            print("PlaneWorld bench  \(ProcessInfo.processInfo.activeProcessorCount) cores  GPU \(GPU.shared?.device.name ?? "none")  reps \(b.reps)\(b.quick ? " (quick)" : "")")
            print(pad("bench", 36) + pad("metric", 28) + "      median unit")
            var ok = true
            for (n, f) in sel {
                let t0 = benchNow()
                do { try f(b) } catch { print("\(n): error \(error)"); ok = false }
                print(String(format: "  [%@ took %.1f s]", n as NSString, Double(benchNow() - t0) / 1e9))
            }
            if let out = TrainCLI.value(args, "--json") {
                let rows = b.results.map { ["name": $0.name, "metric": $0.metric, "unit": $0.unit, "median": $0.median, "samples": $0.samples] as [String: Any] }
                if let d = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) { try? d.write(to: URL(fileURLWithPath: out)) }
            }
            return ok ? 0 : 1
        }
    }
}
