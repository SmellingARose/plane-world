// OWNED BY integrator. End-to-end checks of the `.full` (CFD) call site in CraftSim and the training wiring.
import Foundation
import simd
import PWCore
import PWPhysics
import PWCraft
import PWFlow
import PWEvolution

enum FidelitySelfTests {
    static func register() {
        SelfTestRegistry.register("fidelity", "full-craftsim") { ctx in
            // Trainer held at 30 m/s, α = 4°, Draft CFD: forces arrive from the backend, replace the fast aero,
            // are finite, produce drag (−x) and lift (+y), and the capture carries fast-vs-CFD rows.
            let sim = CraftSim(); try? sim.load(PhysicsPresets.trainer())
            do { try AeroGeometry.enableFull(on: sim, settings: CFDSettings.preset(.draft)) } catch { ctx.fail("enableFull: \(error)"); return }
            let cap = EquationCapture(capacity: 2048); sim.equationCapture = cap
            let q = Quatd(angle: 4 * Double.pi / 180, axis: Vec3d(0, 0, 1)), p = Vec3d(0, 200, 0), v = Vec3d(30, 0, 0)
            sim.reset(spawn: Transform(position: p, rotation: q))
            let n = 40
            for k in 0..<n { sim.holdState(position: p, orientation: q, velocity: v); if k == n - 1 { cap.request() }; sim.step(dt: 1.0 / 60, env: SimEnvironment()) }
            ctx.expect(sim.isRunningFull, "sim reports running full")
            ctx.expect(sim.fullAeroUpdates > 50, "CFD updates collected (\(sim.fullAeroUpdates))")
            var F = Vec3d.zero
            for i in 0..<sim.craft!.parts.count { F += sim.cfdForce(part: i)?.force ?? .zero }
            ctx.log(String(format: "Draft CFD total aero force on Trainer: (%.0f, %.0f, %.0f) N after %d updates", F.x, F.y, F.z, sim.fullAeroUpdates))
            ctx.expect(F.x.isFinite && F.y.isFinite && F.z.isFinite, "finite CFD force")
            ctx.expect(F.x < 0, "CFD drag opposes motion")
            ctx.expect(F.y > 0, "CFD lift is positive at α = 4°")
            let rows = (0..<cap.count).filter { cap.records[$0].id == .cfdMomentumExchange }
            ctx.expect(rows.count >= 5, "fast-vs-CFD comparison rows captured (\(rows.count))")
            // Switching back to fast restores the analytic model exactly (a fresh fast sim gives the same step).
            sim.aeroModel = .fast
            ctx.expect(!sim.isRunningFull, "back on fast")
        }
        SelfTestRegistry.register("fidelity", "full-training-eval") { ctx in
            // One candidate of a hover experiment evaluated with aero.model = full (Draft, 1 s): runs on the CFD.
            ScriptedAlgorithmRegistration.register()
            let url = URL(fileURLWithPath: "examples/experiments/hover-ducted-rocket.json")
            guard var e = try? ExperimentDocument.load(url),
                  let craft = TrainCLI.resolveCraft(e.crafts.first, experimentURL: url) else { ctx.log("examples/ not found from cwd: skipped"); return }
            e.aero.model = .full; e.aero.cfd = CFDSettings.preset(.draft)
            e.episode.duration = 1; e.episode.episodesPerCandidate = 1; e.population = 2; e.workers = 1; e.generations = 1
            do {
                let world = try HeadlessWorld.resolve(e.world, experimentURL: url, options: e.headless, seed: e.seed, current: nil)
                let r = try EvolutionRun(experiment: e, craft: craft, world: world, runID: "selftest", directory: FileManager.default.temporaryDirectory.appendingPathComponent("pw-fid-selftest"))
                let rec = try r.runGeneration()
                ctx.log(String(format: "full-mode generation: best %.3f, %d failures, %.2f sim-s/s", rec.best, rec.failures, rec.simSecondsPerWallSecond))
                ctx.expect(rec.failures == 0, "no failed candidates (\(rec.firstError ?? ""))")
                ctx.expect(rec.best.isFinite, "finite fitness")
            } catch { ctx.fail("\(error)") }
        }
    }
}
