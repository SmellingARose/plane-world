// OWNED BY aero/physics builder. Bit-exactness of the batched (SIMD-lane) simulator against the scalar CraftSim.
//   PlaneWorld --selftest physics.batch-bitexact
// Lives in PWEvolution because it needs the headless world (baked terrain, analytic water) and the presets.
import Foundation
import simd
import PWCore
import PWPhysics
import PWTerrain
import PWWater

public enum BatchSelfTests {
    struct Scenario {
        var name: String
        var doc: CraftDocument
        var mesh: [Vec3d]? = nil
        var world: HeadlessWorld
        var air: Bool
        var altitude = 300.0
        var speed = 45.0
    }

    /// Per-candidate numeric variation (what design genes do): masses, sizes, thrusts, positions. Topology unchanged.
    static func vary(_ d: CraftDocument, _ rng: inout EvoRNG) -> CraftDocument {
        var d = d
        for i in d.parts.indices {
            d.parts[i].mass *= rng.uniform(0.85, 1.15)
            for k in ["span", "chord", "thrust", "torque", "fuel", "capacity", "sx", "sz", "d", "speed", "range", "grip", "flow", "burn"] {
                if let v = d.parts[i].p[k]?.double { d.parts[i].p[k] = .number(v * rng.uniform(0.9, 1.1)) }
            }
            if d.parts[i].pos.count >= 3 { for a in 0..<3 { d.parts[i].pos[a] += rng.uniform(-0.03, 0.03) } }
        }
        return d
    }

    static func jet() -> CraftDocument {
        var jet = PhysicsPresets.trainer()
        jet.parts.removeAll { $0.id == "prop" || $0.id == "eng" || $0.id == "spin" }
        var tank = CraftPart(id: "tank", type: .tank, name: "Tank", pos: [0, 0, 0]); tank.mass = 20
        tank.p.merge(["capacity": .number(200), "fill": .number(1), "r": .number(0.3), "len": .number(1.5)]) { $1 }
        var j = CraftPart(id: "jet", type: .jet, name: "Jet", pos: [-2, 0, 0]); j.mass = 80
        j.p.merge(["thrust": .number(6000), "flow": .number(0.4), "r": .number(0.3), "len": .number(1.5)]) { $1 }
        jet.parts += [tank, j]
        return jet
    }

    static func cad() -> (CraftDocument, [Vec3d]) {
        var c = PhysicsPresets.trainer()
        var pod = CraftPart(id: "cad", type: .cad, name: "Pod", pos: [0, -0.4, 0]); pod.mass = 20
        c.parts.append(pod)
        var soup: [Vec3d] = []
        for i in 0..<12 { soup += PanelMesh.boxSoup(center: [Double(i % 4) * 0.3, Double(i / 4) * 0.3, 0], size: [0.25, 0.2, 0.3]) }
        return (c, soup)
    }

    static func hillyField(base: Double) -> HeightField {
        let f = HeightField(width: 129, height: 129, spacing: 8, origin: Vec2d(-512, -512))
        for y in 0..<129 { for x in 0..<129 { f.base[x, y] = Float(base + 6 * sin(Double(x) * 0.21) + 4 * cos(Double(y) * 0.17) + 0.3 * Double((x * 7 + y * 13) % 5)) } }
        f.recompute(f.fullRect)
        return f
    }

    static func scenarios() -> [Scenario] {
        let flat = HeadlessWorld.flat()
        let hills = HeadlessWorld.bake(field: hillyField(base: 0), water: nil, spawn: .identity, environment: EnvironmentSpec())
        var ws = WaterSpec(); ws.oceanEnabled = true; ws.seaLevel = 2
        var opt = HeadlessOptions(); opt.oceanWaves = true
        let sea = HeadlessWorld.bake(field: hillyField(base: -20), water: ws, spawn: .identity, environment: EnvironmentSpec(), options: opt, seed: 3)
        let (cadDoc, soup) = cad()
        return [
            Scenario(name: "trainer.air.flat", doc: PhysicsPresets.trainer(), world: flat, air: true),
            Scenario(name: "trainer.runway.hills", doc: PhysicsPresets.trainer(), world: hills, air: false),
            Scenario(name: "trainer.low.hills", doc: PhysicsPresets.trainer(), world: hills, air: true, altitude: 12, speed: 30),
            Scenario(name: "jet.air", doc: jet(), world: flat, air: true),
            Scenario(name: "rover.hills", doc: PhysicsPresets.rover(), world: hills, air: false),
            Scenario(name: "rocket.ground", doc: PhysicsPresets.rocket(), world: flat, air: false),
            Scenario(name: "cad.air", doc: cadDoc, mesh: soup, world: flat, air: true),
            Scenario(name: "trainer.sea-ditch", doc: PhysicsPresets.trainer(), world: sea, air: true, altitude: 4, speed: 20),
        ]
    }

    /// Runs one scenario with K lanes through both paths; returns (mismatching lane-steps, compared lane-steps, first mismatch).
    static func compare(_ sc: Scenario, lanes K: Int, steps: Int, seed: UInt64) throws -> (bad: Int, total: Int, first: String?) {
        var rng = EvoRNG(seed: seed)
        let dt = 0.02
        func makePair(_ rng: inout EvoRNG) throws -> (CraftSim, CraftSim) {
            let d = vary(sc.doc, &rng)
            let a = CraftSim(), b = CraftSim()
            try a.load(d); try b.load(d)
            if let m = sc.mesh { a.setPartMesh(partID: "cad", soup: m); b.setPartMesh(partID: "cad", soup: m) }
            let turb = rng.uniform(0, 0.8)
            let ground = sc.world.surfaceHeight(x: 0, z: 0)
            let spawn: Transform
            var lin = Vec3d.zero, ang = Vec3d.zero
            if sc.air {
                let q = Quatd(eulerXYZDegrees: [rng.uniform(-8, 8), rng.uniform(-20, 20), rng.uniform(-8, 8)])
                spawn = Transform(position: [rng.uniform(-30, 30), ground + sc.altitude + rng.uniform(-2, 2), rng.uniform(-30, 30)], rotation: q)
                lin = q.act([1, 0, 0]) * (sc.speed * rng.uniform(0.8, 1.2)); ang = Vec3d(rng.uniform(-0.1, 0.1), rng.uniform(-0.1, 0.1), rng.uniform(-0.1, 0.1))
            } else {
                let x = rng.uniform(-20, 20), z = rng.uniform(-20, 20)
                var r = a.restingSpawn(groundHeight: sc.world.surfaceHeight(x: x, z: z)); r.position.x = x; r.position.z = z
                spawn = r
            }
            for s in [a, b] {
                s.turbulence = turb; s.reset(spawn: spawn)
                if sc.air { s.setVelocity(linear: lin, angular: ang) }
                for i in 0..<s.outputs.count { s.setOutput(index: i, value: 0) }
            }
            return (a, b)
        }
        var ref: [CraftSim] = [], lane: [CraftSim] = []
        for _ in 0..<K { let (a, b) = try makePair(&rng); ref.append(a); lane.append(b) }
        let batch = CraftSimBatch(lanes: K, template: lane[0])
        for l in 0..<K { batch.attach(lane[l], lane: l) }
        let envs = UnsafeMutablePointer<SimEnvironment>.allocate(capacity: K)
        defer { envs.deallocate() }
        for l in 0..<K {
            let a = rng.uniform(0, 2 * .pi), sp = rng.uniform(0, 8)
            (envs + l).initialize(to: sc.world.makeEnvironment(wind: Vec3d(sin(a), 0, cos(a)) * sp, time: 0))
        }
        var active = [Bool](repeating: true, count: K)
        var bad = 0, total = 0, first: String? = nil
        for k in 0..<steps {
            // lane refill (different time base) and lane retirement
            if k == steps / 3 && K > 1 {
                batch.detach(lane: 1)
                let (a, b) = try makePair(&rng); ref[1] = a; lane[1] = b
                envs[1].time = 0
                batch.attach(b, lane: 1)
            }
            if k == 2 * steps / 3 { batch.detach(lane: 0); active[0] = false }
            for l in 0..<K where active[l] {
                for i in 0..<ref[l].outputs.count {
                    let o = ref[l].outputs[i]
                    var v = rng.uniform(o.range.lowerBound, o.range.upperBound)
                    if o.kind == .motor || o.kind == .jet { v = max(v, 0.3 * o.range.upperBound) }
                    if o.kind == .solid { v = k > 10 ? 1 : 0 }
                    ref[l].setOutput(index: i, value: v); lane[l].setOutput(index: i, value: v)
                }
                if k % 37 == 17 && l == K - 1 { ref[l].markObstacleHit(impactSpeed: 3); lane[l].markObstacleHit(impactSpeed: 3) }
            }
            for l in 0..<K where active[l] { ref[l].step(dt: dt, env: envs[l]) }
            batch.step(dt: dt, envs: envs)
            for l in 0..<K where active[l] {
                envs[l].time += dt
                total += 1
                let wa = ref[l].stateWords(), wb = lane[l].stateWords()
                if wa != wb {
                    bad += 1
                    if first == nil {
                        let idx = zip(wa, wb).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
                        first = "\(sc.name) K=\(K) lane \(l) step \(k): first differing word \(idx) of \(wa.count)"
                            + (idx >= 0 ? String(format: " (%.17g vs %.17g)", Double(bitPattern: wa[idx]), Double(bitPattern: wb[idx])) : "")
                    }
                }
            }
        }
        return (bad, total, first)
    }

    /// Fitness bits of an evaluation (total, terms, descriptor, episodes, ticks, errors) for exact comparison.
    static func bits(_ fs: [Fitness]) -> [String] {
        fs.map { f in
            var t = "\(f.total.bitPattern)|\(f.episodes)|\(f.controlTicks)|\(f.simSeconds.bitPattern)|\(f.error ?? "")"
            for k in f.terms.keys.sorted() { t += "|\(k)=\(f.terms[k]!.bitPattern)" }
            for d in f.descriptor ?? [] { t += "|d\(d.bitPattern)" }
            return t
        }
    }

    /// Neural controller + design genes (span, mass, and a part toggle that changes the topology → scalar fallback).
    static func coevolveExperiment() -> ExperimentDocument {
        var e = EvolutionSelfTests.neuralExperiment(duration: 5, episodes: 2)
        e.genome.preset = "coevolve"
        var span = DesignGene(part: "Wing L", field: "p.span", min: 3.5, max: 5); span.mirror = ["Wing R"]
        let mass = DesignGene(part: "Fuselage", field: "mass", min: 250, max: 400)
        let rud = DesignGene(part: "Rudder", field: "enabled", min: 0, max: 1, kind: .bool)
        e.genome.design = [span, mass, rud]
        return e
    }

    public static func register() {
        SelfTestRegistry.register("physics", "batch-zero-alloc") { ctx in
            guard AllocationCounter.install() else { ctx.log("allocation hook unavailable — not measured"); return }
            let hills = HeadlessWorld.bake(field: hillyField(base: 0), water: nil, spawn: .identity, environment: EnvironmentSpec())
            let (cadDoc, soup) = cad()
            for (name, doc, mesh) in [("trainer", PhysicsPresets.trainer(), nil), ("jet", jet(), nil), ("rover", PhysicsPresets.rover(), nil),
                                      ("rocket", PhysicsPresets.rocket(), nil), ("cad", cadDoc, Optional(soup))] as [(String, CraftDocument, [Vec3d]?)] {
                for K in CraftSimBatch.supportedLanes {
                    var sims: [CraftSim] = []
                    for l in 0..<K {
                        let s = CraftSim(); try s.load(doc); if let mesh { s.setPartMesh(partID: "cad", soup: mesh) }
                        // CAD: steady flow only. PanelMesh.updateShadows (scalar code, shared by both paths) rebuilds
                        // its occlusion grid with temporary arrays whenever the flow turns by > 3°.
                        s.turbulence = mesh == nil ? 0.5 : 0
                        if l % 2 == 0 || mesh != nil { s.reset(spawn: Transform(position: [Double(l) * 4, 40, 0])); s.setVelocity(linear: [40, 0, 0], angular: .zero) }
                        else { s.reset(spawn: s.restingSpawn(groundHeight: hills.surfaceHeight(x: 0, z: 0))) }
                        for i in 0..<s.outputs.count { s.setOutput(index: i, value: 0.6) }
                        sims.append(s)
                    }
                    let b = CraftSimBatch(lanes: K, template: sims[0])
                    for l in 0..<K { b.attach(sims[l], lane: l) }
                    let envs = UnsafeMutablePointer<SimEnvironment>.allocate(capacity: K)
                    for l in 0..<K { (envs + l).initialize(to: hills.makeEnvironment(wind: mesh == nil ? [3, 0, 1] : .zero)) }
                    for _ in 0..<5 { b.step(dt: 0.02, envs: envs) }
                    let a0 = AllocationCounter.count
                    for _ in 0..<50 { b.step(dt: 0.02, envs: envs); for l in 0..<K { envs[l].time += 0.02 } }
                    let n = AllocationCounter.count - a0
                    if mesh == nil {
                        ctx.expect(n == 0, "\(name) K=\(K): CraftSimBatch.step allocates nothing (\(n) in \(50 * 20) substeps)")
                    } else {
                        // same lanes on the scalar path: the batch must not allocate more than it does
                        var ref: [CraftSim] = []
                        for l in 0..<K {
                            let s = CraftSim(); try s.load(doc); s.setPartMesh(partID: "cad", soup: soup); s.turbulence = 0
                            s.reset(spawn: Transform(position: [Double(l) * 4, 40, 0])); s.setVelocity(linear: [40, 0, 0], angular: .zero)
                            for i in 0..<s.outputs.count { s.setOutput(index: i, value: 0.6) }
                            ref.append(s)
                        }
                        let env = hills.makeEnvironment(wind: .zero)
                        for _ in 0..<5 { for r in ref { r.step(dt: 0.02, env: env) } }
                        let s0 = AllocationCounter.count
                        var e2 = env
                        for _ in 0..<50 { for r in ref { r.step(dt: 0.02, env: e2) }; e2.time += 0.02 }
                        let ns = AllocationCounter.count - s0
                        ctx.expect(n <= ns, "\(name) K=\(K): batch allocations (\(n)) ≤ scalar path (\(ns)); both are PanelMesh shadow rebuilds")
                        if K == 2 { ctx.log("CAD: \(n) allocations per 1000 batched substeps vs \(ns) scalar (PanelMesh.updateShadows rebuilds, shared scalar code)") }
                    }
                    envs.deinitialize(count: K); envs.deallocate()
                }
            }
            ctx.log("batched step: 0 allocations (trainer, jet, rover, rocket; K = 2, 4, 8; hills, wind, turbulence)")
        }

        SelfTestRegistry.register("evolution", "batch-determinism") { ctx in
            // Same population through the scalar and the batched evaluator, 1 and 4 workers: identical fitness bits.
            for (label, e0) in [("neural (split episodes)", EvolutionSelfTests.neuralExperiment(duration: 6, episodes: 2)),
                                ("coevolve (per-candidate crafts, topology change)", coevolveExperiment())] {
                var ref: [String]? = nil
                var fallbacks: [String] = []
                var rng = EvoRNG(seed: 11)
                var pop: [Genome] = []
                for K in [1, 2, 4, 8] {
                    for w in [1, 4] {
                        var e = e0; e.batchLanes = K
                        let r = try EvolutionSelfTests.makeRun(e, workers: w)
                        if pop.isEmpty { pop = (0..<14).map { Genome(id: UInt64($0 + 1), values: r.layout.randomValues(&rng)) } }
                        let f = r.evaluator.evaluate(pop, generation: 2, cancel: nil)
                        let ev = r.evaluator as! SimEvaluator
                        if K > 1 { fallbacks.append("K\(K)w\(w):\(ev.lastFallbackEpisodes)") }
                        let b = bits(f)
                        if ref == nil { ref = b; ctx.expect(f.allSatisfy { $0.error == nil }, "\(label): no failures (\(f.compactMap(\.error).first ?? ""))") }
                        ctx.expect(b == ref!, "\(label): K=\(K), \(w) workers bit-identical to scalar 1 worker")
                    }
                }
                ctx.log("\(label): K = 1/2/4/8 × 1/4 workers identical; scalar-fallback episodes \(fallbacks.joined(separator: " "))")
            }
            // Whole seeded runs: history and algorithm state identical for K = 1 and K = 4.
            var hs: [[GenerationRecord]] = []
            for K in [1, 4] {
                var e = EvolutionSelfTests.neuralExperiment(duration: 4, episodes: 2); e.batchLanes = K
                let r = try EvolutionSelfTests.makeRun(e, workers: 0)
                for _ in 0..<3 { try r.runGeneration() }
                hs.append(r.history.map { var g = $0; g.wallSeconds = 0; g.simsPerSecond = 0; g.simSecondsPerWallSecond = 0; return g })
            }
            ctx.expect(hs[0] == hs[1], "3-generation run: history identical for K = 1 and K = 4")
            // No per-tick allocations in the batched evaluator.
            if AllocationCounter.install() {
                func allocs(_ duration: Double) throws -> Int {
                    var e = EvolutionSelfTests.neuralExperiment(duration: duration, episodes: 1); e.batchLanes = 4; e.episode.stopOnCrash = false
                    let r = try EvolutionSelfTests.makeRun(e, workers: 1)
                    var g = EvoRNG(seed: 3)
                    let pop = (0..<4).map { Genome(id: UInt64($0 + 1), values: r.layout.randomValues(&g)) }
                    _ = r.evaluator.evaluate(pop, generation: 0, cancel: nil)
                    let a = AllocationCounter.count
                    _ = r.evaluator.evaluate(pop, generation: 0, cancel: nil)
                    return AllocationCounter.count - a
                }
                let short = try allocs(1), long = try allocs(11)
                let perTick = Double(long - short) / (10 * 50 * 4)
                ctx.log(String(format: "batched evaluator allocations: 1 s %d, 11 s %d → %.3f per lane-tick", short, long, perTick))
                ctx.expect(perTick < 0.05, "no per-tick heap allocations in the batched episode loop (\(perTick)/lane-tick)")
            }
        }

        SelfTestRegistry.register("physics", "batch-bitexact") { ctx in
            #if DEBUG
            // The scalar reference's FMA contraction differs at -Onone (see physics.trajectory-digest); the batch
            // path reproduces the release build. Debug runs report but do not fail.
            let strict = false
            #else
            let strict = true
            #endif
            let prim = CraftSimBatch.primitiveMismatches(samples: 20000)
            ctx.log("lane primitives vs simd (3 × 20000 random samples, ±0 / tiny / huge): " + (prim.isEmpty ? "all bit-exact" : "\(prim)"))
            if strict { ctx.expect(prim.isEmpty, "lane primitives bit-exact: \(prim)") }
            var allBad = 0, allTotal = 0
            for sc in scenarios() {
                for K in CraftSimBatch.supportedLanes {
                    let r = try compare(sc, lanes: K, steps: 150, seed: UInt64(K * 1000 + sc.name.count))
                    allBad += r.bad; allTotal += r.total
                    if let f = r.first { ctx.log("MISMATCH " + f) }
                    if strict { ctx.expect(r.bad == 0, "\(sc.name) K=\(K): \(r.bad)/\(r.total) lane-steps differ") }
                }
            }
            ctx.log("\(allTotal - allBad)/\(allTotal) lane-steps bit-identical (8 scenarios × K = 2, 4, 8; lane refill + retirement)")
        }
    }
}
