// OWNED BY architect. ------------------------------------------------------------------------------
// Parallel headless evaluation. `SimEvaluator` owns one `EvalWorker` per JobSystem thread; each worker has its
// own CraftSim(s), ScriptRuntime (own JSContext), MLP buffers and ControlFrame. Candidates are distributed
// with JobSystem.parallelFor(grain: 1); a worker is checked out for the whole candidate (all its episodes).
// Results depend only on (genome, experiment, run seed, generation, candidate index) — never on scheduling.
import Foundation
import simd
import PWCore
import PWPhysics

/// Everything resolved for a run (crafts loaded, world baked, layout built). Immutable; shared by workers.
public final class ExperimentContext: @unchecked Sendable {
    public let experiment: ExperimentDocument
    /// Flight-prepared craft (the App applies CraftOutputs.prepareForFlight before passing it in).
    public let craft: CraftDocument
    public let world: HeadlessWorld
    public internal(set) var layout = GenomeLayout()
    public internal(set) var termNames: [String] = []
    /// Input/output names of the BASE craft (frame order). Decoded designs are mapped onto these by name.
    public let inputNames: [String], outputNames: [String]
    public let outputRanges: [ClosedRange<Double>]
    public internal(set) var mlpSizes: [Int] = []
    public internal(set) var mlpInputs: [Int] = []      // frame input indices feeding the MLP
    public internal(set) var mlpOutputs: [Int] = []     // frame output indices driven by the MLP
    public internal(set) var mlpInputScale: [Double] = []
    /// NEAT I/O by name (layout.neat.inputs/outputs → frame indices); inputs scaled like the MLP (genome.mlp.inputScale).
    public internal(set) var neatInputs: [Int] = [], neatOutputs: [Int] = [], neatInputScale: [Double] = []
    public var mlpRange: Range<Int>? { layout.range(group: "mlp") }
    public var designRange: Range<Int>? { layout.range(group: "design") }
    public internal(set) var needsPerCandidateCraft = false

    public init(experiment: ExperimentDocument, craft: CraftDocument, world: HeadlessWorld) throws {
        self.experiment = experiment; self.craft = craft; self.world = world
        if experiment.crafts.count > 1 {
            throw EvolutionError.invalidExperiment("experiment lists \(experiment.crafts.count) crafts; only one craft per episode is supported (multi-craft episodes are not implemented). Remove the extra crafts.")
        }
        let probe = CraftSim()
        try probe.load(craft)
        inputNames = probe.inputs.map(\.name)
        outputNames = probe.outputs.map(\.name)
        outputRanges = probe.outputs.map(\.range)
    }

    /// Build the genome layout: native part (preset) + script genome(base) hook. Called once by the Run.
    func buildLayout(orchestrator rt: any ScriptRuntime) throws {
        let e = experiment
        var base = GenomeLayout()
        let wantsDesign = e.genome.preset == "design" || e.genome.preset == "coevolve"
        let wantsMLP = (e.genome.preset == "neural" || e.genome.preset == "coevolve") && e.controller.mode == "mlp"
        if wantsDesign { base = base + DesignDecoder.layout(e.genome.design) }
        if wantsMLP {
            let spec = e.genome.mlp ?? MLPSpec()
            func idx(_ names: [String], _ all: [String], _ what: String) throws -> [Int] {
                if names.isEmpty { return Array(all.indices) }
                return try names.map { n in
                    guard let i = all.firstIndex(of: n) else { throw EvolutionError.invalidExperiment("MLP \(what) '\(n)' not found (craft has: \(all.joined(separator: ", ")))") }
                    return i
                }
            }
            mlpInputs = try idx(spec.inputs, inputNames, "input")
            mlpOutputs = try idx(spec.outputs, outputNames, "output")
            if mlpInputs.isEmpty { throw EvolutionError.invalidExperiment("neural controller needs at least one sensor input — add a sensor part in BUILD") }
            if mlpOutputs.isEmpty { throw EvolutionError.invalidExperiment("neural controller needs at least one output") }
            mlpInputScale = mlpInputs.map { 1 / max(1e-9, spec.inputScale[inputNames[$0]] ?? 1) }
            mlpSizes = [mlpInputs.count] + spec.hidden.filter { $0 > 0 } + [mlpOutputs.count]
            base = base + MLPPolicy.layout(mlpSizes, range: spec.weightRange)
        }
        if e.controller.mode == "neat" || e.algorithm.kind == "neat" {
            base.neat = e.genome.neat ?? NEATLayout(inputs: inputNames, outputs: outputNames)
        }
        layout = try rt.genome(base: base)
        termNames = try rt.termNames(default: e.rewardTerms)
        if let nl = layout.neat {
            neatInputs = try nl.inputs.map { n in
                guard let i = inputNames.firstIndex(of: n) else { throw EvolutionError.invalidExperiment("NEAT input '\(n)' not found (craft has: \(inputNames.joined(separator: ", ")))") }
                return i }
            neatOutputs = try nl.outputs.map { n in
                guard let i = outputNames.firstIndex(of: n) else { throw EvolutionError.invalidExperiment("NEAT output '\(n)' not found (craft has: \(outputNames.joined(separator: ", ")))") }
                return i }
            let sc = e.genome.mlp?.inputScale ?? [:]
            neatInputScale = neatInputs.map { 1 / max(1e-9, sc[inputNames[$0]] ?? 1) }
        }
        needsPerCandidateCraft = wantsDesign || rt.definedHooks.contains(.decode)
        if layout.count == 0 && layout.neat == nil { throw EvolutionError.invalidExperiment("empty genome: choose a preset or define genome() in the script") }
    }
}

public struct EvalStats: Sendable, Equatable {
    public var candidates = 0, episodes = 0, controlTicks = 0
    public var simSeconds = 0.0, wallSeconds = 0.0
    public var simsPerSecond: Double { wallSeconds > 0 ? Double(episodes) / wallSeconds : 0 }
    public var simSecondsPerWallSecond: Double { wallSeconds > 0 ? simSeconds / wallSeconds : 0 }
    public init() {}
}

public protocol Evaluator: AnyObject {
    /// Evaluate a batch; returns one Fitness per genome, same order. Never throws: failures become Fitness.failed.
    func evaluate(_ genomes: [Genome], generation: Int, cancel: (() -> Bool)?) -> [Fitness]
    var lastStats: EvalStats { get }
}

/// Per-tick observer used by replay recording (not used during training).
public typealias TickObserver = (CraftSim, ControlFrame) -> Void

/// One worker's private simulation + script state.
public final class EvalWorker {
    let ctx: ExperimentContext
    let runtime: any ScriptRuntime
    let frame: ControlFrame
    let baseSim: CraftSim
    var sim: CraftSim
    var inMap: [Int] = [], outMap: [Int] = []          // frame index → sim index (-1 = absent in this design)
    var simInputs: UnsafeMutablePointer<Double>
    var simInputCap: Int
    let mlp: MLPPolicy?
    let mlpX: UnsafeMutablePointer<Double>, mlpY: UnsafeMutablePointer<Double>
    var neat: (any PolicyNetwork)?
    // swept-corner buffers for static headless obstacles (reallocated only when the design grows)
    var cornersPrev: UnsafeMutablePointer<Vec3d> = .allocate(capacity: 1), cornersCur: UnsafeMutablePointer<Vec3d> = .allocate(capacity: 1)
    var cornerCap = 1

    public init(context: ExperimentContext, runtime: any ScriptRuntime) throws {
        ctx = context; self.runtime = runtime
        try runtime.compile(context.experiment.scripts, experiment: context.experiment)
        frame = ControlFrame(inputNames: context.inputNames, outputNames: context.outputNames, termNames: context.termNames)
        baseSim = CraftSim()
        try baseSim.load(context.craft)
        baseSim.substepHz = context.experiment.episode.physicsHz
        baseSim.crashSpeed = context.experiment.episode.crashSpeed
        sim = baseSim
        simInputCap = max(1, baseSim.inputCount)
        simInputs = .allocate(capacity: simInputCap); simInputs.initialize(repeating: 0, count: simInputCap)
        mlp = context.mlpSizes.count >= 2 ? MLPPolicy(sizes: context.mlpSizes, hiddenActivation: context.experiment.genome.mlp?.activation ?? "tanh",
                                                       outputActivation: context.experiment.genome.mlp?.outputActivation ?? "tanh") : nil
        let m = max(1, context.mlpSizes.max() ?? 1, context.neatInputs.count, context.neatOutputs.count)
        mlpX = .allocate(capacity: m); mlpY = .allocate(capacity: m)
        mlpX.initialize(repeating: 0, count: m); mlpY.initialize(repeating: 0, count: m)
        remap()
    }
    deinit { simInputs.deallocate(); mlpX.deallocate(); mlpY.deallocate(); cornersPrev.deallocate(); cornersCur.deallocate() }

    func remap() {
        let ins = sim.inputs.map(\.name), outs = sim.outputs.map(\.name)
        inMap = ctx.inputNames.map { ins.firstIndex(of: $0) ?? -1 }
        outMap = ctx.outputNames.map { outs.firstIndex(of: $0) ?? -1 }
        if sim.inputCount > simInputCap {
            simInputs.deallocate(); simInputCap = sim.inputCount
            simInputs = .allocate(capacity: simInputCap); simInputs.initialize(repeating: 0, count: simInputCap)
        }
        if sim.cornerCount > cornerCap {
            cornersPrev.deallocate(); cornersCur.deallocate(); cornerCap = sim.cornerCount
            cornersPrev = .allocate(capacity: cornerCap); cornersCur = .allocate(capacity: cornerCap)
        }
    }

    /// Prepare sim + policy for a genome (allocates only when the design changes per candidate).
    public func prepare(_ g: Genome) throws -> CraftDocument {
        var doc = ctx.craft
        if ctx.needsPerCandidateCraft {
            if let r = ctx.designRange { doc = try DesignDecoder.apply(ctx.experiment.genome.design, values: g.values[r], to: doc) }
            doc = try runtime.decode(genome: g, layout: ctx.layout, craft: doc)
            let s = CraftSim()
            try s.load(doc)
            s.substepHz = ctx.experiment.episode.physicsHz
            s.crashSpeed = ctx.experiment.episode.crashSpeed
            sim = s
            remap()
        } else if sim !== baseSim { sim = baseSim; remap() }
        if let mlp, let r = ctx.mlpRange { g.values.withUnsafeBufferPointer { mlp.load(UnsafeBufferPointer(rebasing: $0[r])) } }
        if ctx.experiment.controller.mode == "neat" {
            guard let ng = g.neat, let nl = ctx.layout.neat else { throw EvolutionError.invalidExperiment("controller mode 'neat' needs a NEAT genome (algorithm 'neat')") }
            neat = try NEATNetwork(genome: ng, layout: nl)
        } else { neat = nil }
        return doc
    }

    /// Evaluate one candidate over all its episodes.
    public func evaluate(_ g: Genome, generation: Int, candidate: Int) -> Fitness {
        let e = ctx.experiment.episode
        do {
            _ = try prepare(g)
            let n = max(1, e.episodesPerCandidate)
            var totals: [Double] = [], termRows: [[Double]] = [], descs: [[Double]] = []
            var extraTerms: [String: [Double]] = [:]
            var ticks = 0, simT = 0.0
            for ep in 0..<n {
                let seed = e.commonRandomNumbers ? EvoRNG.derive(ctx.experiment.seed, generation, -1, ep) : EvoRNG.derive(ctx.experiment.seed, generation, candidate, ep)
                let (out, sums, t, k) = try runEpisode(g, generation: generation, candidate: candidate, episode: ep, seed: seed, observer: nil)
                var row = sums
                for (name, v) in out.terms {
                    if let i = ctx.termNames.firstIndex(of: name) { row[i] = v } else { extraTerms[name, default: []].append(v) }
                }
                totals.append(out.fitness ?? row.reduce(0, +))
                termRows.append(row)
                if let d = out.descriptor { descs.append(d) }
                ticks += k; simT += t
            }
            func agg(_ xs: [Double]) -> Double {
                guard !xs.isEmpty else { return 0 }
                switch e.aggregate {
                case "min": return xs.min()!
                case "median": let s = xs.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
                default: return xs.reduce(0, +) / Double(xs.count)
                }
            }
            var f = Fitness(total: agg(totals))
            for (i, name) in ctx.termNames.enumerated() { f.terms[name] = agg(termRows.map { $0[i] }) }
            for (k, v) in extraTerms { f.terms[k] = agg(v) }
            if let d0 = descs.first, descs.allSatisfy({ $0.count == d0.count }) {
                f.descriptor = (0..<d0.count).map { j in descs.reduce(0) { $0 + $1[j] } / Double(descs.count) }
            }
            f.episodes = n; f.simSeconds = simT; f.controlTicks = ticks
            if !f.total.isFinite { return .failed("fitness is not finite (\(f.total))") }
            return f
        } catch let s as ScriptError {
            return .failed(s.description)
        } catch {
            return .failed("\(error)")
        }
    }

    /// Spawn transform + initial velocity for an episode.
    func spawn(_ rng: inout EvoRNG) -> (Transform, Vec3d) {
        let s = ctx.experiment.episode.spawn, w = ctx.world
        var p = s.position.map { $0.count >= 3 ? Vec3d($0[0], $0[1], $0[2]) : w.spawn.position } ?? w.spawn.position
        if s.jitterPosition > 0 { p.x += rng.uniform(-1, 1) * s.jitterPosition; p.z += rng.uniform(-1, 1) * s.jitterPosition }
        let heading = s.headingDeg + (s.jitterHeadingDeg > 0 ? rng.uniform(-1, 1) * s.jitterHeadingDeg : 0)
        let att = s.jitterAttitudeDeg > 0 ? Vec3d(rng.uniform(-1, 1) * s.jitterAttitudeDeg, 0, rng.uniform(-1, 1) * s.jitterAttitudeDeg) : .zero
        let q = (w.spawn.rotation * Quatd(angle: -heading * kDeg, axis: [0, 1, 0]) * Quatd(eulerXYZDegrees: att)).normalized
        let ground = w.surfaceHeight(x: p.x, z: p.z)
        switch s.mode {
        case "air":
            p.y = ground + max(1, s.altitudeAGL)
            let v = max(0, s.speed + (s.jitterSpeed > 0 ? rng.uniform(-1, 1) * s.jitterSpeed : 0))
            return (Transform(position: p, rotation: q), q.act([1, 0, 0]) * v)
        case "custom":
            return (Transform(position: p, rotation: q), q.act([1, 0, 0]) * s.speed)
        default: // runway: rest on the ground
            let rest = sim.restingSpawn(groundHeight: ground)
            p.y = rest.position.y
            return (Transform(position: p, rotation: q), .zero)
        }
    }

    @inline(__always) func fillState(_ env: SimEnvironment, spawnXZ: Vec2d) {
        frame.state = CraftStateSnapshot.capture(sim, time: env.time, surface: ctx.world.surfaceHeight(x: sim.position.x, z: sim.position.z), spawnXZ: spawnXZ)
    }

    @inline(__always) func observe(_ env: SimEnvironment) {
        sim.readSensors(env: env, into: simInputs)
        for i in 0..<inMap.count { let j = inMap[i]; frame.inputs[i] = j >= 0 ? simInputs[j] : 0 }
    }

    /// Run one episode. Returns (script outcome, term sums in termNames order, sim seconds, control ticks).
    /// The per-tick loop performs no heap allocation (with a NullScriptRuntime / allocation-free runtime).
    public func runEpisode(_ g: Genome, generation: Int, candidate: Int, episode: Int, seed: UInt64,
                           observer: TickObserver?) throws -> (EpisodeOutcome, [Double], Double, Int) {
        let e = ctx.experiment
        var rng = EvoRNG(seed: seed)
        let (sp, v0) = spawn(&rng)
        let windSpeed = e.episode.wind.speedMax > e.episode.wind.speedMin ? rng.uniform(e.episode.wind.speedMin, e.episode.wind.speedMax) : e.episode.wind.speedMin
        let windDir = rng.uniform(e.episode.wind.directionMinDeg, e.episode.wind.directionMaxDeg) * kDeg
        sim.turbulence = e.episode.wind.turbulence
        sim.sensorNoiseSeed = EvoRNG.derive(seed, 7)
        sim.reset(spawn: sp)
        if simd_length(v0) > 0 { sim.setVelocity(linear: v0, angular: .zero) }
        for i in 0..<sim.outputs.count { sim.setOutput(index: i, value: 0) }
        neat?.reset(); mlp?.reset()

        var env = ctx.world.makeEnvironment(wind: Vec3d(sin(windDir), 0, cos(windDir)) * windSpeed, time: 0)
        let hz = max(1, e.controller.hz), dt = 1 / hz
        let steps = max(1, Int((e.episode.duration * hz).rounded()))
        let spawnXZ = Vec2d(sp.position.x, sp.position.z)
        frame.tick = 0; frame.done = false; frame.doneReason = ""
        var info = EpisodeInfo()
        info.generation = generation; info.candidate = candidate; info.episode = episode; info.seed = seed
        info.duration = e.episode.duration; info.controlDt = dt
        frame.info = info
        for i in 0..<frame.outputs.count { frame.outputs[i] = 0 }
        for i in 0..<frame.termSums.count { frame.termSums[i] = 0 }
        let bounds = ctx.world.terrain?.bounds
        let mode = e.controller.mode
        fillState(env, spawnXZ: spawnXZ); observe(env)
        try runtime.beginEpisode(genome: g, frame: frame)
        let obstacles = ctx.world.obstacles
        var nCorners = obstacles != nil ? sim.writeWorldCorners(cornersPrev, capacity: cornerCap) : 0
        var prevPos = sim.position

        var k = 0
        while k < steps {
            frame.tick = k
            // native policy
            if mode == "mlp", let mlp {
                for j in 0..<ctx.mlpInputs.count { mlpX[j] = frame.inputs[ctx.mlpInputs[j]] * ctx.mlpInputScale[j] }
                mlp.forward(mlpX, mlpY)
                for j in 0..<ctx.mlpOutputs.count {
                    let o = ctx.mlpOutputs[j], r = ctx.outputRanges[o]
                    frame.outputs[o] = r.lowerBound + (mlpY[j] + 1) * 0.5 * (r.upperBound - r.lowerBound)
                }
            } else if mode == "neat", let net = neat {
                // by name, scaled inputs; tanh outputs [-1, 1] mapped onto each output's range (as in mlp mode)
                for j in 0..<ctx.neatInputs.count { mlpX[j] = frame.inputs[ctx.neatInputs[j]] * ctx.neatInputScale[j] }
                net.forward(UnsafePointer(mlpX), mlpY)
                for j in 0..<ctx.neatOutputs.count {
                    let o = ctx.neatOutputs[j], r = ctx.outputRanges[o]
                    frame.outputs[o] = r.lowerBound + (max(-1, min(1, mlpY[j])) + 1) * 0.5 * (r.upperBound - r.lowerBound)
                }
            }
            for i in 0..<frame.terms.count { frame.terms[i] = 0 }
            try runtime.tick(frame)
            for i in 0..<frame.termSums.count { frame.termSums[i] += frame.terms[i] }
            for i in 0..<outMap.count where outMap[i] >= 0 { sim.setOutput(index: outMap[i], value: frame.outputs[i]) }
            observer?(sim, frame)
            if frame.done { break }
            sim.step(dt: dt, env: env)
            env.time += dt; k += 1
            if let obstacles {
                nCorners = sim.writeWorldCorners(cornersCur, capacity: cornerCap)
                let travel = simd_length(sim.position - prevPos)
                if obstacles.hit(center: sim.position, radius: sim.collisionRadius, prev: cornersPrev, cur: cornersCur, count: nCorners, travel: travel) {
                    sim.markObstacleHit(impactSpeed: simd_length(sim.velocity))
                }
                swap(&cornersPrev, &cornersCur); prevPos = sim.position
            }
            fillState(env, spawnXZ: spawnXZ); observe(env)
            if !(sim.position.x.isFinite && sim.position.y.isFinite && sim.velocity.y.isFinite) { frame.done = true; frame.doneReason = "nan"; break }
            if e.episode.stopOnCrash && sim.crashed { frame.done = true; frame.doneReason = "crash"; break }
            if let b = bounds, sim.position.x < b.min.x || sim.position.x > b.max.x || sim.position.z < b.min.z || sim.position.z > b.max.z {
                frame.done = true; frame.doneReason = "bounds"; break
            }
        }
        if !frame.done { frame.doneReason = "time" } else if frame.doneReason.isEmpty { frame.doneReason = "script" }
        frame.tick = k
        observer?(sim, frame)
        let out = try runtime.endEpisode(frame)
        return (out, Array(frame.termSums), env.time, k)
    }

}

/// The evaluator's workers (one per JobSystem thread by default).
final class WorkerPool: @unchecked Sendable {
    let all: [EvalWorker]
    init(_ workers: [EvalWorker]) { all = workers }
}

public final class SimEvaluator: Evaluator {
    public let context: ExperimentContext
    let pool: WorkerPool
    let jobs: JobSystem
    public private(set) var lastStats = EvalStats()

    /// `workers` = 0 → one per JobSystem thread. `runtimeFactory` makes one ScriptRuntime per worker.
    public init(context: ExperimentContext, workers: Int = 0, jobs: JobSystem = .shared, runtimeFactory: ScriptRuntimeFactory) throws {
        self.context = context; self.jobs = jobs
        let n = workers > 0 ? workers : jobs.threadCount
        pool = WorkerPool(try (0..<n).map { _ in try EvalWorker(context: context, runtime: runtimeFactory()) })
    }
    public var workerCount: Int { pool.all.count }

    public func evaluate(_ genomes: [Genome], generation: Int, cancel: (() -> Bool)? = nil) -> [Fitness] {
        let n = genomes.count
        let out = UnsafeMutablePointer<Fitness>.allocate(capacity: max(1, n))
        let t0 = DispatchTime.now().uptimeNanoseconds
        // One job per worker; each pulls the next candidate index (dynamic balancing, workers never shared).
        let workers = pool.all
        let lock = NSLock()
        var next = 0
        let body: (Range<Int>) -> Void = { r in
            for wi in r {
                let w = workers[wi]
                while true {
                    lock.lock(); let i = next; next += 1; lock.unlock()
                    if i >= n { break }
                    if cancel?() == true { (out + i).initialize(to: .failed("cancelled")); continue }
                    (out + i).initialize(to: w.evaluate(genomes[i], generation: generation, candidate: i))
                }
            }
        }
        let jobsN = min(workers.count, n)
        if jobsN <= 1 { body(0..<1) } else { jobs.parallelFor(jobsN, grain: 1, label: "evolution.eval", body) }
        let res = Array(UnsafeBufferPointer(start: out, count: n))
        out.deinitialize(count: n); out.deallocate()
        var s = EvalStats()
        s.candidates = n
        s.wallSeconds = Double(DispatchTime.now().uptimeNanoseconds - t0) * 1e-9
        for f in res { s.episodes += f.episodes; s.simSeconds += f.simSeconds; s.controlTicks += f.controlTicks }
        lastStats = s
        return res
    }

    /// A worker for single-threaded use on the caller's thread (replay, export checks). Not part of the pool.
    public func makeStandaloneWorker(runtime: any ScriptRuntime) throws -> EvalWorker { try EvalWorker(context: context, runtime: runtime) }
}

extension CraftStateSnapshot {
    /// Ground-truth snapshot of a sim (allocation-free). `surface` = terrain/water height under the CoM.
    @inline(__always) public static func capture(_ s: CraftSim, time: Double, surface: Double, spawnXZ: Vec2d) -> CraftStateSnapshot {
        let q = s.orientation, tel = s.telemetry
        let fwd = q.act([1, 0, 0]), up = q.act([0, 1, 0]), right = q.act([0, 0, 1])
        let wb = q.inverse.act(s.angularVelocityWorld)
        var st = CraftStateSnapshot()
        st.t = time
        st.x = s.position.x; st.y = s.position.y; st.z = s.position.z
        st.vx = s.velocity.x; st.vy = s.velocity.y; st.vz = s.velocity.z
        st.pitch = asin(clamp(fwd.y, -1, 1)) / kDeg; st.roll = atan2(-right.y, up.y) / kDeg; st.yaw = atan2(fwd.z, fwd.x) / kDeg
        st.rollRate = wb.x / kDeg; st.pitchRate = wb.z / kDeg; st.yawRate = -wb.y / kDeg
        st.airspeed = tel.airspeed; st.groundSpeed = tel.groundSpeed; st.altitude = s.position.y
        st.agl = s.position.y - surface
        st.aoa = tel.angleOfAttackDeg; st.sideslip = tel.sideslipDeg; st.gLoad = tel.gLoad
        st.fuel = s.totalFuel; st.mass = s.mass; st.thrust = tel.thrustN
        st.distance = simd_length(Vec2d(s.position.x, s.position.z) - spawnXZ)
        st.crashed = s.crashed; st.contact = s.groundContact; st.impactSpeed = s.maxImpactSpeed
        return st
    }
}
