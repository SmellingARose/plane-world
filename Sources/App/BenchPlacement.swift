// OWNED BY profiler. Placement benchmarks (CPU vs GPU, P vs E cores, training/render coexistence). See docs/PLACEMENT.md.
//   PlaneWorld --bench placement            # all of them
//   PlaneWorld --bench placement.train-mix | placement.train-pool | placement.coexist | placement.gpu-latency
import Foundation
import Metal
import Darwin
import PWCore
import PWRender
import PWEvolution

extension Bench {
    static func loadAvg() -> String {
        var l = [Double](repeating: 0, count: 3)
        _ = getloadavg(&l, 3)
        return String(format: "load %.1f %.1f %.1f", l[0], l[1], l[2])
    }

    /// Free-running training threads with a given QoS mix. Returns (total sim-s/s, per-thread sim-s/s).
    final class FreeRunner {
        let pop: [Genome]
        var workers: [EvalWorker] = []
        @MainActor init() throws {
            let s = try Bench.trainSetup()
            let run = try Bench.makeRun(s, workers: 1, population: 64)
            pop = try run.algorithm.ask()
            for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
                let si = try Bench.trainSetup()
                let ri = try Bench.makeRun(si, workers: 1, population: 64)
                if let evi = ri.evaluator as? SimEvaluator { workers.append(try evi.makeStandaloneWorker(runtime: ScriptRuntimes.make(for: si.exp.scripts))) }
            }
        }
        final class Handle { var stopPtr: UnsafeMutablePointer<Bool>?; var perThread: [Double] = []; var t0: UInt64 = 0; let lock = NSLock(); let done = DispatchSemaphore(value: 0); var n = 0 }
        /// Start threads; qos per thread. Call `finish` to stop and collect.
        func start(_ qos: [QualityOfService]) -> Handle {
            let h = Handle(); h.n = qos.count; h.perThread = Array(repeating: 0, count: qos.count)
            let go = DispatchSemaphore(value: 0)
            let stopPtr = UnsafeMutablePointer<Bool>.allocate(capacity: 1); stopPtr.initialize(to: false)
            h.stopPtr = stopPtr
            for (t, q) in qos.enumerated() {
                let w = workers[t]; let pop = pop
                let th = Thread {
                    go.wait()
                    var simT = 0.0, i = t * 7
                    while !stopPtr.pointee {
                        let c = i % pop.count
                        simT += w.evaluate(pop[c], generation: 0, candidate: c).simSeconds
                        i += 1
                    }
                    h.lock.lock(); h.perThread[t] = simT; h.lock.unlock()
                    h.done.signal()
                }
                th.qualityOfService = q; th.stackSize = 4 << 20; th.start()
            }
            h.t0 = benchNow()
            for _ in qos { go.signal() }
            return h
        }
        func finish(_ h: Handle) -> (Double, [Double]) {
            h.stopPtr?.pointee = true
            for _ in 0..<h.n { h.done.wait() }
            let wall = Double(benchNow() - h.t0) / 1e9
            h.stopPtr?.deallocate()
            let per = h.perThread.map { $0 / wall }
            return (per.reduce(0, +), per)
        }
        func measure(_ qos: [QualityOfService], seconds: Double) -> (Double, [Double]) {
            let h = start(qos); Thread.sleep(forTimeInterval: seconds); return finish(h)
        }
    }

    /// P/E mix: which threads land where, and what each core type delivers.
    func placementTrainMix() throws {
        let fr = try FreeRunner()
        let secs = quick ? 2.0 : 4.0
        let reps = quick ? 1 : 3
        let UI = QualityOfService.userInteractive, BG = QualityOfService.background, UT = QualityOfService.utility
        let configs: [(String, [QualityOfService])] = [
            ("1 UI", [UI]),
            ("1 BG (E-core)", [BG]),
            ("2 UI", Array(repeating: UI, count: 2)),
            ("4 UI (P-only)", Array(repeating: UI, count: 4)),
            ("5 UI", Array(repeating: UI, count: 5)),
            ("6 UI", Array(repeating: UI, count: 6)),
            ("8 UI", Array(repeating: UI, count: 8)),
            ("10 UI", Array(repeating: UI, count: 10)),
            ("10 UT (utility)", Array(repeating: UT, count: 10)),
            ("6 BG (E-only)", Array(repeating: BG, count: 6)),
            ("4 UI + 6 BG", Array(repeating: UI, count: 4) + Array(repeating: BG, count: 6)),
        ]
        print("  placement.train-mix: free-running neural.json, \(secs) s per sample, \(Self.loadAvg())")
        // Interleave configs across reps so drift in background load hits all of them equally.
        var tot: [String: [Double]] = [:], hi: [String: [Double]] = [:], lo: [String: [Double]] = [:]
        for _ in 0..<reps {
            for (name, q) in configs {
                let (t, per) = fr.measure(q, seconds: secs)
                let s = per.sorted(by: >)
                tot[name, default: []].append(t)
                hi[name, default: []].append(s.prefix(min(4, s.count)).reduce(0, +) / Double(min(4, s.count)))
                if s.count > 4 { lo[name, default: []].append(s.dropFirst(4).reduce(0, +) / Double(s.count - 4)) }
            }
        }
        for (name, _) in configs {
            record("placement.train-mix", "sim-s/s " + name, "x", tot[name]!)
            if lo[name] != nil {
                record("placement.train-mix", "per-thr top4 " + name, "x", hi[name]!)
                record("placement.train-mix", "per-thr rest " + name, "x", lo[name]!)
            }
        }
        print("  \(Self.loadAvg())")
    }

    /// Generation throughput with the shared pool vs a dedicated training pool at different QoS.
    func placementTrainPool() throws {
        let s = try Self.trainSetup()
        print("  placement.train-pool: \(Self.loadAvg())")
        let cases: [(String, () -> JobSystem)] = [
            ("shared pool (10 thr UI)", { JobSystem.shared }),
            ("own pool 9+caller UI", { JobSystem(workers: 9, qos: .userInteractive) }),
            ("own pool 9+caller utility", { JobSystem(workers: 9, qos: .utility) }),
            ("own pool 3+caller UI (P)", { JobSystem(workers: 3, qos: .userInteractive) }),
        ]
        var pools: [String: (EvolutionRun, JobSystem)] = [:]
        for (n, mk) in cases {
            let js = mk()
            var e = s.exp; e.workers = js.threadCount; e.population = 64
            let run = try EvolutionRun(experiment: e, craft: s.craft, world: s.world,
                                       directory: FileManager.default.temporaryDirectory.appendingPathComponent("pw-bench-run"), jobs: js)
            _ = try run.runGeneration()
            pools[n] = (run, js)
        }
        var acc: [String: [Double]] = [:]
        for _ in 0..<(quick ? 1 : 4) {
            for (n, _) in cases { acc[n, default: []].append(try pools[n]!.0.runGeneration().simSecondsPerWallSecond) }
        }
        for (n, _) in cases { record("placement.train-pool", "sim-s/s " + n, "x", acc[n]!) }
        print("  \(Self.loadAvg())")
    }

    /// Training and rendering at the same time: does each slow the other, and which QoS layout is best?
    func placementCoexist() throws {
        guard let gpu = GPU.shared else { print("placement.coexist: no GPU"); return }
        let fr = try FreeRunner()
        let W = 3200, H = 1920
        let model = AppModel()
        let r = try Renderer(device: gpu.device, queue: gpu.queue, outputFormat: .bgra8Unorm_srgb)
        model.attachRenderer(r)
        model.tab = .fly
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: W, height: H, mipmapped: false)
        d.usage = [.renderTarget]; d.storageMode = .private
        guard let tex = gpu.device.makeTexture(descriptor: d) else { return }
        var s2 = r.settings; s2.passTimings = false; r.settings = s2
        for _ in 0..<20 { model.tick(dt: 1.0 / 60); r.render(to: tex, camera: model.camera.camera, time: model.services.clock.simTime) }
        r.render(to: tex, camera: model.camera.camera, time: 0, waitUntilCompleted: true)
        let frames = quick ? 60 : 150
        /// Pipelined render loop (3 frames in flight, like the MTKView path). ms/frame, CPU ms (tick + encode), GPU ms.
        func renderLoop() -> (Double, Double, Double, Double) {
            var cpu: [Double] = [], g: [Double] = [], tickV: [Double] = []
            let t0 = benchNow()
            for _ in 0..<frames {
                let a = benchNow()
                model.tick(dt: 1.0 / 60)
                let b = benchNow()
                r.render(to: tex, camera: model.camera.camera, time: model.services.clock.simTime)
                let c = benchNow()
                tickV.append(Double(b - a) / 1e6); cpu.append(Double(c - a) / 1e6); g.append(r.lastGPUTimeMs)
            }
            r.render(to: tex, camera: model.camera.camera, time: 0, waitUntilCompleted: true)
            let wall = Double(benchNow() - t0) / 1e6 / Double(frames)
            func med(_ v: [Double]) -> Double { BenchResult(name: "", metric: "", unit: "", samples: v).median }
            return (wall, med(cpu), med(g), med(tickV))
        }
        let UI = QualityOfService.userInteractive, BG = QualityOfService.background, UT = QualityOfService.utility
        let layouts: [(String, [QualityOfService])] = [
            ("none", []),
            ("10 UI", Array(repeating: UI, count: 10)),
            ("9 UI", Array(repeating: UI, count: 9)),
            ("10 UT", Array(repeating: UT, count: 10)),
            ("9 UT", Array(repeating: UT, count: 9)),
            ("6 BG", Array(repeating: BG, count: 6)),
            ("3 UT + 6 BG", Array(repeating: UT, count: 3) + Array(repeating: BG, count: 6)),
        ]
        print("  placement.coexist: FLY \(W)x\(H), \(frames) frames pipelined, \(Self.loadAvg())")
        var res: [String: [String: [Double]]] = [:]
        for _ in 0..<(quick ? 1 : 3) {
            for (name, q) in layouts {
                // training alone (same duration as the render loop)
                if !q.isEmpty {
                    let (t, _) = fr.measure(q, seconds: quick ? 2 : 3)
                    res[name, default: [:]]["train alone sim-s/s", default: []].append(t)
                }
                let h = q.isEmpty ? nil : fr.start(q)
                if h != nil { Thread.sleep(forTimeInterval: 0.3) }
                let (wall, cpu, g, tk) = renderLoop()
                if let h { let (t, _) = fr.finish(h); res[name, default: [:]]["train w/ render sim-s/s", default: []].append(t) }
                res[name, default: [:]]["frame ms", default: []].append(wall)
                res[name, default: [:]]["cpu tick+encode ms", default: []].append(cpu)
                res[name, default: [:]]["tick ms", default: []].append(tk)
                res[name, default: [:]]["gpu ms", default: []].append(g)
            }
        }
        for (name, _) in layouts {
            for (k, v) in res[name]!.sorted(by: { $0.key < $1.key }) { record("placement.coexist." + name.replacingOccurrences(of: " ", with: ""), k, "", v) }
        }
        print("  \(Self.loadAvg())")
    }

    /// GPU round-trip latency: what a synchronous CPU->GPU->CPU dependency costs (the crossover floor).
    func placementGPULatency() throws {
        guard let gpu = GPU.shared else { print("placement.gpu-latency: no GPU"); return }
        let buf = gpu.device.makeBuffer(length: 1 << 20, options: .storageModeShared)!
        print("  placement.gpu-latency: \(Self.loadAvg())")
        repeatRun("placement.gpu-latency", units: ["empty cb us": "µs", "blit 1MB us": "µs", "memcpy 1MB us": "µs"]) {
            var e: [Double] = [], b: [Double] = [], m: [Double] = []
            let host = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 64)
            defer { host.deallocate() }
            for _ in 0..<200 {
                let t0 = benchNow()
                let cb = gpu.queue.makeCommandBuffer()!; cb.commit(); cb.waitUntilCompleted()
                let t1 = benchNow()
                let cb2 = gpu.queue.makeCommandBuffer()!
                let bl = cb2.makeBlitCommandEncoder()!; bl.fill(buffer: buf, range: 0..<(1 << 20), value: 1); bl.endEncoding()
                cb2.commit(); cb2.waitUntilCompleted()
                let t2 = benchNow()
                memcpy(host, buf.contents(), 1 << 20)
                let t3 = benchNow()
                e.append(Double(t1 - t0) / 1e3); b.append(Double(t2 - t1) / 1e3); m.append(Double(t3 - t2) / 1e3)
            }
            func med(_ v: [Double]) -> Double { BenchResult(name: "", metric: "", unit: "", samples: v).median }
            return ["empty cb us": med(e), "blit 1MB us": med(b), "memcpy 1MB us": med(m)]
        }
    }
}
