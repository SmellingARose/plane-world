// OWNED BY architect (evolution feature), then aero/physics builder.
// Batched evaluation: one job steps K episodes in lockstep through CraftSimBatch (one SIMD lane each).
//
// A `BatchEvalDriver` owns K ordinary `EvalWorker`s (lanes): each lane keeps its own CraftSim, script runtime,
// ControlFrame and MLP, and runs exactly the scalar episode phases (EvalWorker.beginEpisode / controlTick /
// afterStep / finishEpisode). Only the physics step of all live lanes is one `CraftSimBatch.step`. A lane that
// finishes (time, crash, script `done`, bounds, NaN, error) immediately pulls the next work item from the shared
// counter and is re-attached, so lanes are never idle while work remains (lanes then run at different episode
// times; the batch keeps time per lane). Because every lane is bit-identical to the scalar CraftSim, results do
// not depend on K, on which lane an episode runs in, or on scheduling.
//
// Fallbacks (counted in `fallbackEpisodes`): a candidate whose craft cannot be attached (topology differs from
// the episodes currently in the batch, e.g. a design gene that removes a part) runs on the scalar path inline.
import Foundation
import Synchronization
import simd
import PWCore
import PWPhysics

final class BatchEvalDriver {
    let lanes: [EvalWorker]
    let K: Int
    var batch: CraftSimBatch?
    let envs: UnsafeMutablePointer<SimEnvironment>
    var mlpBatch: MLPBatch?
    /// Episodes that had to run on the scalar path (topology mismatch / unsupported craft).
    var fallbackEpisodes = 0

    struct Slot {
        var active = false
        /// The candidate's next episode is due (non-split); begun at the start of the next round, so a lane is
        /// never stepped before its first control tick.
        var pendingNext = false
        var item = -1, candidate = 0, episode = 0
        var run: EvalWorker.EpisodeRun? = nil
        var results: [EvalWorker.EpisodeResult] = []
    }
    var slots: [Slot]

    init(lanes: [EvalWorker]) {
        self.lanes = lanes; K = lanes.count
        envs = .allocate(capacity: K)
        for l in 0..<K { (envs + l).initialize(to: lanes[l].world.makeEnvironment(wind: .zero)) }
        slots = Array(repeating: Slot(), count: K)
        if let m = lanes[0].mlp, lanes[0].policyMode == 1 { mlpBatch = MLPBatch(like: m, lanes: K) }
    }
    deinit { envs.deinitialize(count: K); envs.deallocate() }

    /// Work description shared by all jobs of one `SimEvaluator.evaluate` call.
    struct Work {
        let genomes: [Genome], generation: Int, items: Int, split: Bool, E: Int
        /// Number of drivers sharing the work (tail balancing, see `run`).
        let drivers: Int
        let next: UnsafePointer<Atomic<Int>>
        let cancel: (() -> Bool)?
        let out: UnsafeMutablePointer<Fitness>                       // per candidate (non-split)
        let eps: UnsafeMutablePointer<EvalWorker.EpisodeResult>      // per item (split)
    }

    @inline(__always) static func result(_ body: () throws -> (EpisodeOutcome, [Double], Double, Int)) -> EvalWorker.EpisodeResult {
        do { let (o, s, t, k) = try body(); return EvalWorker.EpisodeResult(outcome: o, sums: s, simT: t, ticks: k) }
        catch let s as ScriptError { return EvalWorker.EpisodeResult(error: s.description) }
        catch { return EvalWorker.EpisodeResult(error: "\(error)") }
    }
    @inline(__always) static func failure(_ error: any Error) -> String { (error as? ScriptError)?.description ?? "\(error)" }

    /// Make `w.sim` attachable to the batch (creating / re-templating it when empty). False → scalar fallback.
    func attachable(_ w: EvalWorker) -> Bool {
        if !CraftSimBatch.unsupportedFeatures(w.sim).isEmpty { return false }
        if let b = batch, b.compatible(w.sim) { return true }
        if batch == nil || batch!.attachedCount == 0 { batch = CraftSimBatch(lanes: K, template: w.sim); return true }
        return false
    }

    /// Begin episode `slot.episode` of the lane's current item and attach it. False when it ended immediately (error).
    func beginAttached(_ l: Int, _ work: Work) -> Bool {
        let w = lanes[l]
        let g = work.genomes[slots[l].candidate]
        do {
            let run = try w.beginEpisode(g, generation: work.generation, candidate: slots[l].candidate, episode: slots[l].episode,
                                         seed: w.episodeSeed(generation: work.generation, candidate: slots[l].candidate, episode: slots[l].episode))
            slots[l].run = run
            batch!.attach(w.sim, lane: l)
            if let mb = mlpBatch, let m = w.mlp { mb.load(lane: l, from: m) }
            slots[l].active = true
            return true
        } catch {
            finishItem(l, EvalWorker.EpisodeResult(error: Self.failure(error)), work)
            return false
        }
    }

    /// Record a finished episode; continue with the candidate's next episode (non-split) or free the lane.
    func finishItem(_ l: Int, _ r: EvalWorker.EpisodeResult, _ work: Work) {
        if slots[l].active { batch?.detach(lane: l) }
        slots[l].active = false; slots[l].run = nil
        if work.split {
            (work.eps + slots[l].item).initialize(to: r)
            return
        }
        slots[l].results.append(r)
        if r.error == nil && slots[l].episode + 1 < work.E {
            slots[l].episode += 1
            slots[l].pendingNext = true
            return
        }
        let f = slots[l].results.withUnsafeBufferPointer { lanes[l].aggregate($0) }
        (work.out + slots[l].candidate).initialize(to: f)
        slots[l].results.removeAll(keepingCapacity: true)
    }

    /// Scalar fallback for the lane's current item (after `prepare`).
    func runScalar(_ l: Int, _ work: Work) {
        let w = lanes[l], s = slots[l]
        let g = work.genomes[s.candidate]
        if work.split {
            fallbackEpisodes += 1
            (work.eps + s.item).initialize(to: w.runEpisodeItem(g, generation: work.generation, candidate: s.candidate, episode: s.episode, prepared: true))
        } else {
            var eps: [EvalWorker.EpisodeResult] = []
            for ep in 0..<work.E {
                fallbackEpisodes += 1
                let r = w.runEpisodeItem(g, generation: work.generation, candidate: s.candidate, episode: ep, prepared: true)
                eps.append(r)
                if r.error != nil { break }
            }
            (work.out + s.candidate).initialize(to: eps.withUnsafeBufferPointer { w.aggregate($0) })
        }
    }

    /// Pull work items into lane `l` until one is attached or the work is exhausted. False = exhausted.
    func refill(_ l: Int, _ work: Work) -> Bool {
        let w = lanes[l]
        while slots[l].pendingNext {
            slots[l].pendingNext = false
            if beginAttached(l, work) { return true }
        }
        while true {
            let k = work.next.pointee.wrappingAdd(1, ordering: .relaxed).oldValue
            if k >= work.items { return false }
            slots[l].item = k
            if work.split { slots[l].candidate = k / work.E; slots[l].episode = k % work.E }
            else { slots[l].candidate = k; slots[l].episode = 0; slots[l].results.removeAll(keepingCapacity: true) }
            if work.cancel?() == true {
                if work.split { (work.eps + k).initialize(to: .init(error: "cancelled")) } else { (work.out + k).initialize(to: .failed("cancelled")) }
                continue
            }
            do { _ = try w.prepare(work.genomes[slots[l].candidate]) } catch {
                if work.split { (work.eps + k).initialize(to: .init(error: Self.failure(error))) } else { (work.out + k).initialize(to: .failed(Self.failure(error))) }
                continue
            }
            if !attachable(w) { runScalar(l, work); continue }
            if beginAttached(l, work) { return true }
            // ended at begin (error): recorded (split / last episode) or the next episode is pending (non-split)
            while slots[l].pendingNext {
                slots[l].pendingNext = false
                if beginAttached(l, work) { return true }
            }
        }
    }

    /// Run work items until the shared counter is exhausted and every lane has finished.
    func run(_ work: Work) {
        var exhausted = [Bool](repeating: false, count: K)
        let nativeMLP = mlpBatch != nil
        while true {
            // Tail balancing: once fewer items remain than drivers, only lane 0 takes new work, so the last items
            // spread over all drivers instead of piling up in the lanes of one (possibly slow E-core) driver.
            // (Scheduling only: every lane is bit-identical to the scalar path, so results do not change.)
            let tail = work.items - work.next.pointee.load(ordering: .relaxed) < work.drivers
            for l in 0..<K where !slots[l].active && !exhausted[l] && (l == 0 || !tail || slots[l].pendingNext) {
                if !refill(l, work) { exhausted[l] = true }
            }
            var anyActive = false
            for l in 0..<K where slots[l].active { anyActive = true; break }
            if !anyActive { break }

            // --- control (batched native MLP, then per-lane script tick)
            if nativeMLP, let mb = mlpBatch {
                for l in 0..<K where slots[l].active {
                    let w = lanes[l]
                    for j in 0..<w.mlpIn.count { mb.x[j * K + l] = w.frame.inputs[w.mlpIn[j]] * w.mlpScale[j] }
                }
                mb.forward()
                for l in 0..<K where slots[l].active {
                    let w = lanes[l]
                    for j in 0..<w.mlpOut.count {
                        let o = w.mlpOut[j], r = w.ranges[o]
                        w.frame.outputs[o] = r.lowerBound + (mb.y[j * K + l] + 1) * 0.5 * (r.upperBound - r.lowerBound)
                    }
                }
            }
            for l in 0..<K where slots[l].active {
                let w = lanes[l]
                do {
                    if !(try w.controlTick(&slots[l].run!, observer: nil, policyDone: nativeMLP)) {
                        let run = slots[l].run!
                        finishItem(l, Self.result { try w.finishEpisode(run, observer: nil) }, work)
                    }
                } catch { finishItem(l, EvalWorker.EpisodeResult(error: Self.failure(error)), work) }
            }

            // --- physics: one batched step for every live lane
            var dt = 0.0, live = false
            for l in 0..<K where slots[l].active { envs[l] = slots[l].run!.env; dt = slots[l].run!.dt; live = true }
            if !live { continue }
            batch!.step(dt: dt, envs: envs)

            // --- after step (per lane)
            for l in 0..<K where slots[l].active {
                let w = lanes[l]
                let cont = w.afterStep(&slots[l].run!)
                if !cont || slots[l].run!.k >= slots[l].run!.steps {
                    let run = slots[l].run!
                    finishItem(l, Self.result { try w.finishEpisode(run, observer: nil) }, work)
                }
            }
        }
    }
}
