// OWNED BY architect. ------------------------------------------------------------------------------
// Replay = deterministic re-simulation. Training never records trajectories (zero overhead); to show a
// candidate in 3D, the UI asks ReplayRecorder to re-run the exact episode (same genome, generation,
// candidate index, episode index → same seed) with a per-tick observer, producing a Trajectory the renderer
// plays back with the normal craft scene (part poses per frame). The re-run's fitness must equal the
// training fitness bit-for-bit; `Trajectory.fitnessMatches` reports it (a selftest enforces it).
//
// EvolvedAutopilot flies an exported craft (EmbeddedController) live in FLY.
import Foundation
import simd
import PWCore
import PWPhysics

public struct ReplayFrame: Codable, Sendable {
    public var t: Double
    public var origin: Transform               // craft origin transform (CraftSim.originTransform)
    public var parts: [Transform]              // per part, CraftSim.partPoses() order (= trajectory.craft.parts order)
    public var outputs: [Double]               // frame outputs (experiment output names order)
    public var termSums: [Double]
}

public struct Trajectory: Codable, Sendable {
    public var craft: CraftDocument            // decoded craft actually flown
    public var partIDs: [String]
    public var outputNames: [String]
    public var termNames: [String]
    public var frames: [ReplayFrame]
    public var outcome: Double                 // episode fitness of the re-run
    public var doneReason: String
    public var trainingFitness: Double?
    public var fitnessMatches: Bool?
    /// Interpolated sample at time t (clamped).
    public func sample(at t: Double) -> ReplayFrame? {
        guard let f0 = frames.first else { return nil }
        if t <= f0.t { return f0 }
        guard let last = frames.last, t < last.t else { return frames.last }
        var lo = 0, hi = frames.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if frames[m].t <= t { lo = m } else { hi = m } }
        let a = frames[lo], b = frames[hi], u = (t - a.t) / max(1e-9, b.t - a.t)
        func lerp(_ x: Transform, _ y: Transform) -> Transform {
            Transform(position: x.position + (y.position - x.position) * u, rotation: simd_slerp(x.rotation, y.rotation, u))
        }
        var f = a
        f.t = t; f.origin = lerp(a.origin, b.origin)
        if a.parts.count == b.parts.count { f.parts = zip(a.parts, b.parts).map { lerp($0, $1) } }
        return f
    }
}

public enum ReplayRecorder {
    /// Re-simulate one episode of `genome` exactly as training did. For a hall-of-fame entry pass its
    /// generation; `candidate` is only needed when commonRandomNumbers is off (then use the index in that
    /// generation's population; the hall of fame stores the genome — the UI passes -1 → episode seeds of CRN).
    public static func record(context: ExperimentContext, genome: Genome, generation: Int, candidate: Int = 0,
                              episode: Int = 0, trainingFitness: Double? = nil,
                              runtime: (any ScriptRuntime)? = nil) throws -> Trajectory {
        let w = try EvalWorker(context: context, runtime: runtime ?? ScriptRuntimes.make(for: context.experiment.scripts))
        let craft = try w.prepare(genome)
        let e = context.experiment.episode
        let seed = e.commonRandomNumbers ? EvoRNG.derive(context.experiment.seed, generation, -1, episode)
                                         : EvoRNG.derive(context.experiment.seed, generation, candidate, episode)
        var frames: [ReplayFrame] = []
        frames.reserveCapacity(Int(e.duration * context.experiment.controller.hz) + 2)
        let (out, sums, _, _) = try w.runEpisode(genome, generation: generation, candidate: candidate, episode: episode, seed: seed) { sim, frame in
            frames.append(ReplayFrame(t: frame.state.t, origin: sim.originTransform, parts: sim.partPoses().map(\.transform),
                                      outputs: Array(frame.outputs), termSums: Array(frame.termSums)))
        }
        let total = out.fitness ?? sums.reduce(0, +)
        var match: Bool? = nil
        if let tf = trainingFitness, e.episodesPerCandidate == 1 { match = tf == total }
        return Trajectory(craft: craft, partIDs: craft.parts.map(\.id), outputNames: context.outputNames, termNames: context.termNames,
                          frames: frames, outcome: total, doneReason: w.frame.doneReason, trainingFitness: trainingFitness, fitnessMatches: match)
    }
}

/// Live autopilot for FLY: runs an exported controller against the app's CraftSim each frame.
public final class EvolvedAutopilot {
    public let controller: EmbeddedController
    let runtime: any ScriptRuntime
    let frame: ControlFrame
    let mlp: MLPPolicy?
    var neat: (any PolicyNetwork)?
    var mlpIn: [Int] = [], mlpOut: [Int] = [], scale: [Double] = []
    var inMap: [Int] = [], outMap: [Int] = []
    var simInputs: [Double] = []
    var x: [Double] = [], y: [Double] = []
    var accumulator = 0.0
    public private(set) var lastError: String?

    public init(craft: CraftDocument, sim: CraftSim) throws {
        guard let c = EmbeddedController.find(in: craft) else { throw EvolutionError.invalidExperiment("craft has no evolved controller") }
        controller = c
        var exp = ExperimentDocument(); exp.scripts = c.script; exp.rewardTerms = c.termNames
        runtime = ScriptRuntimes.make(for: c.script)
        try runtime.compile(c.script, experiment: exp)
        frame = ControlFrame(inputNames: c.inputNames, outputNames: c.outputNames, termNames: c.termNames)
        if c.mode == "mlp", let spec = c.mlp, let r = c.layout.range(group: "mlp") {
            mlpIn = spec.inputs.isEmpty ? Array(c.inputNames.indices) : spec.inputs.compactMap { c.inputNames.firstIndex(of: $0) }
            mlpOut = spec.outputs.isEmpty ? Array(c.outputNames.indices) : spec.outputs.compactMap { c.outputNames.firstIndex(of: $0) }
            scale = mlpIn.map { 1 / max(1e-9, spec.inputScale[c.inputNames[$0]] ?? 1) }
            let m = MLPPolicy(sizes: [mlpIn.count] + spec.hidden.filter { $0 > 0 } + [mlpOut.count], hiddenActivation: spec.activation, outputActivation: spec.outputActivation)
            c.genome.values.withUnsafeBufferPointer { m.load(UnsafeBufferPointer(rebasing: $0[r])) }
            mlp = m
            x = [Double](repeating: 0, count: mlpIn.count); y = [Double](repeating: 0, count: mlpOut.count)
        } else { mlp = nil }
        if c.mode == "neat", let ng = c.genome.neat, let nl = c.layout.neat {
            neat = try NEATNetwork(genome: ng, layout: nl)
            mlpIn = nl.inputs.compactMap { c.inputNames.firstIndex(of: $0) }
            mlpOut = nl.outputs.compactMap { c.outputNames.firstIndex(of: $0) }
            let sc = c.mlp?.inputScale ?? [:]
            scale = mlpIn.map { 1 / max(1e-9, sc[c.inputNames[$0]] ?? 1) }
            x = [Double](repeating: 0, count: nl.inputs.count); y = [Double](repeating: 0, count: max(1, nl.outputs.count))
        }
        attach(sim)
        try runtime.beginEpisode(genome: c.genome, frame: frame)
    }

    /// Re-map names after the sim (re)loads the craft.
    public func attach(_ sim: CraftSim) {
        let ins = sim.inputs.map(\.name), outs = sim.outputs.map(\.name)
        inMap = controller.inputNames.map { ins.firstIndex(of: $0) ?? -1 }
        outMap = controller.outputNames.map { outs.firstIndex(of: $0) ?? -1 }
        simInputs = [Double](repeating: 0, count: max(1, sim.inputCount))
        accumulator = 0
    }

    /// Call every frame (before sim.step) with the frame's dt; ticks the controller at its own rate.
    public func update(sim: CraftSim, env: SimEnvironment, dt: Double) {
        accumulator += dt
        let cdt = 1 / max(1, controller.hz)
        guard accumulator >= cdt else { return }
        accumulator = min(accumulator - cdt, cdt)
        simInputs.withUnsafeMutableBufferPointer { sim.readSensors(env: env, into: $0.baseAddress!) }
        for i in inMap.indices { frame.inputs[i] = inMap[i] >= 0 ? simInputs[inMap[i]] : 0 }
        for i in outMap.indices where outMap[i] >= 0 { frame.outputs[i] = sim.outputs[outMap[i]].value }
        if let mlp {
            for j in mlpIn.indices { x[j] = frame.inputs[mlpIn[j]] * scale[j] }
            x.withUnsafeBufferPointer { xp in y.withUnsafeMutableBufferPointer { yp in mlp.forward(xp.baseAddress!, yp.baseAddress!) } }
            for j in mlpOut.indices {
                let o = mlpOut[j]; guard outMap[o] >= 0 else { continue }
                let r = sim.outputs[outMap[o]].range
                frame.outputs[o] = r.lowerBound + (y[j] + 1) * 0.5 * (r.upperBound - r.lowerBound)
            }
        }
        if let neat {
            for j in mlpIn.indices { x[j] = frame.inputs[mlpIn[j]] * scale[j] }
            x.withUnsafeBufferPointer { xp in y.withUnsafeMutableBufferPointer { yp in neat.forward(xp.baseAddress!, yp.baseAddress!) } }
            for j in mlpOut.indices {
                let o = mlpOut[j]; guard outMap[o] >= 0 else { continue }
                let r = sim.outputs[outMap[o]].range
                frame.outputs[o] = r.lowerBound + (max(-1, min(1, y[j])) + 1) * 0.5 * (r.upperBound - r.lowerBound)
            }
        }
        frame.state = CraftStateSnapshot.capture(sim, time: env.time, surface: env.terrain?.height(x: sim.position.x, z: sim.position.z) ?? 0, spawnXZ: .zero)
        do { try runtime.tick(frame); lastError = nil } catch { lastError = "\(error)" }
        frame.tick += 1
        for i in outMap.indices where outMap[i] >= 0 { sim.setOutput(index: outMap[i], value: frame.outputs[i]) }
    }
}
