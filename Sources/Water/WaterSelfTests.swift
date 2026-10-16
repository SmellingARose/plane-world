// OWNED BY water builder. Headless self-tests: `PlaneWorld --selftest water`.
import Foundation
import Metal
import simd
import PWCore
import PWRender

public enum WaterSelfTests {
    /// Minimal 6-DOF rigid body integrator (semi-implicit Euler) for buoyancy tests.
    struct TestBody {
        var state: BodyState
        var mass: Double
        var inertiaBody: Vec3d   // principal moments
        mutating func step(_ ft: ForceTorque, dt: Double) {
            let g = Vec3d(0, -kGravity, 0)
            state.linearVelocity += (ft.force / mass + g) * dt
            let R = Mat3d(state.transform.rotation)
            let Iw = R * Mat3d(diagonal: inertiaBody) * R.transpose
            state.angularVelocity += Iw.inverse * ft.torque * dt
            state.transform.position += state.linearVelocity * dt
            let w = state.angularVelocity
            let dq = Quatd(ix: w.x * dt * 0.5, iy: w.y * dt * 0.5, iz: w.z * dt * 0.5, r: 0) * state.transform.rotation
            state.transform.rotation = Quatd(vector: state.transform.rotation.vector + dq.vector).normalized
            state.centerOfMass = state.transform.position
        }
    }

    static func boxHull(_ size: Vec3) -> HullMesh { MeshBuilder.box(size).hull }

    static func outDir() -> URL {
        ProcessInfo.processInfo.environment["PW_SELFTEST_OUT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
    }

    public static func register() {
        SelfTestRegistry.register("water", "shaders") { ctx in
            guard let gpu = GPU.shared else { ctx.fail("no Metal device"); return }
            _ = try ShaderLibrary.shared.library(named: "water.ocean", source: WaterShaders.ocean, device: gpu.device)
            _ = try ShaderLibrary.shared.library(named: "water.fluid", source: WaterShaders.fluid, device: gpu.device)
            _ = try WaterSystem.makePipelines(device: gpu.device, sampleCount: 1)
            _ = try WaterSystem.makePipelines(device: gpu.device, sampleCount: 4)
        }

        SelfTestRegistry.register("water", "buoyancy-static") { ctx in
            // 2×1×2 m box with its bottom 0.5 m under a flat lake: displaced volume 2 m³ exactly.
            let water = WaterSystem(gpu: nil)
            water.addLake(Lake(center: [0, 0], radius: 100, level: 0))
            let hull = boxHull([2, 1, 2])
            let st = BodyState(transform: Transform(position: [0, 0, 0]), centerOfMass: [0, 0, 0])   // centre at the surface → half submerged
            let (ft, vol) = water.submergedForces(hull: hull, state: st, time: 0)
            ctx.expectClose(vol, 2.0, tol: 1e-9, "submerged volume")
            ctx.expectClose(ft.force.y, 1000 * kGravity * 2.0, tol: 1e-6, "buoyancy = ρgV")
            ctx.expect(simd_length(Vec3d(ft.force.x, 0, ft.force.z)) < 1e-9 && simd_length(ft.torque) < 1e-9, "no lateral force/torque when level")
            // Inside-out hull must give the same answer.
            var inv = hull; for t in stride(from: 0, to: inv.indices.count, by: 3) { inv.indices.swapAt(t + 1, t + 2) }
            let (ft2, vol2) = water.submergedForces(hull: inv, state: st, time: 0)
            ctx.expectClose(vol2, vol, tol: 1e-9, "winding-independent volume"); ctx.expectClose(ft2.force.y, ft.force.y, tol: 1e-6, "winding-independent force")
            // Heeled 20°: righting moment must oppose the heel (positive metacentric height for this box).
            var s2 = st; s2.transform.rotation = Quatd(angle: 20 * kDeg, axis: [0, 0, 1])
            let (ft3, _) = water.submergedForces(hull: hull, state: s2, time: 0)
            ctx.expect(ft3.torque.z < 0, "righting moment opposes heel (τz=\(ft3.torque.z))")
            // Large (parallel path) sphere half-submerged: V = half the mesh volume.
            let sphere = MeshBuilder.sphere(radius: 1, segments: 96, rings: 48).hull
            let meshVol = abs(Hydrodynamics.signedVolume(sphere))
            let (fs, vs) = water.submergedForces(hull: sphere, state: st, time: 0)
            ctx.expectClose(vs, meshVol / 2, tol: meshVol * 0.002, "half-submerged sphere volume (\(sphere.indices.count / 3) tris)")
            ctx.expectClose(fs.force.y, 1000 * kGravity * vs, tol: 1e-6 * fs.force.y, "sphere buoyancy")
            ctx.log(String(format: "box V=%.6f m³ F=%.2f N; sphere V=%.4f (mesh/2 %.4f) τ_heel=%.1f N·m", vol, ft.force.y, vs, meshVol / 2, ft3.torque.z))
        }

        SelfTestRegistry.register("water", "floating-box-equilibrium") { ctx in
            // Box 2×1×2 m, 2000 kg (ρ_box = 500) in fresh water: Archimedes draft = m/(ρ A) = 0.5 m.
            let water = WaterSystem(gpu: nil)
            water.addLake(Lake(center: [0, 0], radius: 100, level: 0))
            let hull = boxHull([2, 1, 2])
            let m = 2000.0
            let I = Vec3d(m / 12 * (1 + 4), m / 12 * (4 + 4), m / 12 * (4 + 1))
            var b = TestBody(state: BodyState(transform: Transform(position: [0, 1.2, 0], rotation: Quatd(angle: 12 * kDeg, axis: [0.3, 0, 1]).normalized),
                                              centerOfMass: [0, 1.2, 0]), mass: m, inertiaBody: I)
            let dt = 1.0 / 600
            var t = 0.0
            var trace: [String] = []
            for i in 0..<(600 * 40) {
                let (ft, _) = water.submergedForces(hull: hull, state: b.state, time: t)
                b.step(ft, dt: dt); t += dt
                if i % 3000 == 0 { let u = b.state.transform.rotation.act(Vec3d(0, 1, 0)); trace.append(String(format: "%.0fs:%.2f°/%.3fm", t, acos(min(1, u.y)) / kDeg, b.state.transform.position.y)) }
            }
            ctx.log("trace " + trace.joined(separator: " "))
            let up = b.state.transform.rotation.act(Vec3d(0, 1, 0))
            let draft = 0.5 - b.state.transform.position.y    // centre height → bottom depth
            let expected = m / (1000 * 4)
            ctx.expectClose(draft, expected, tol: expected * 0.02, "equilibrium draft (Archimedes)")
            // Barge roll is lightly damped in reality (ζ ≈ 1–5 %): require clear decay of the 12° initial heel.
            ctx.expect(acos(min(1, up.y)) < 4 * kDeg, "box rights itself (tilt \(acos(min(1, up.y)) / kDeg)° from 12°)")
            ctx.expect(simd_length(b.state.linearVelocity) < 0.01, "settled (v=\(simd_length(b.state.linearVelocity)))")
            ctx.log(String(format: "draft %.4f m (Archimedes %.4f, error %.3f%%), tilt %.3f°", draft, expected, abs(draft - expected) / expected * 100, acos(min(1, up.y)) / kDeg))
        }

        SelfTestRegistry.register("water", "ocean-gpu-vs-reference") { ctx in
            guard GPU.shared != nil else { ctx.fail("no Metal device"); return }
            var s = OceanSettings(); s.windSpeed = 12; s.windDirectionDeg = 30
            let water = WaterSystem()
            water.setOcean(s); water.oceanEnabled = true
            guard let ocean = water.ocean else { ctx.fail("ocean init"); return }
            let T = 123.456
            let t0 = Date()
            water.updateOceanSync(time: T)
            ctx.log(String(format: "Hs = %.2f m, GPU update %.3f ms (wall %.1f ms incl. sync)", ocean.spectrum.significantWaveHeight, ocean.lastGPUTimeMs, Date().timeIntervalSince(t0) * 1000))
            guard let (cur, _) = ocean.snapshots() else { ctx.fail("no snapshot"); return }
            let Hs = ocean.spectrum.significantWaveHeight
            ctx.expect(Hs > 1 && Hs < 6, "plausible Hs for U10=12 m/s, 100 km fetch (\(Hs))")
            // (a) Each cascade's FFT output at grid points vs exact direct sum.
            var rng = PCG32(seed: 5)
            var maxErr = 0.0
            let N = ocean.N
            for c in 0..<ocean.cascades {
                let L = ocean.spectrum.cascades[c].L
                let p = cur.dispBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self) + c * N * N
                for _ in 0..<3 {
                    let ix = Int(rng.next32() % UInt32(N)), iy = Int(rng.next32() % UInt32(N))
                    let ref = ocean.spectrum.referenceDisplacement(x: Double(ix) * L / Double(N), z: Double(iy) * L / Double(N), time: T, cascade: c)
                    let g = p[iy * N + ix]
                    maxErr = max(maxErr, abs(Double(g.y) - ref.y), abs(Double(g.x) - ref.x), abs(Double(g.z) - ref.z))
                }
            }
            ctx.expect(maxErr < 2e-3 * max(Hs, 1), "GPU FFT matches direct sum at grid points (max err \(maxErr) m)")
            // (b) Public height query (choppy inversion + interpolation) vs exact surface at arbitrary points.
            var maxH = 0.0, sumH = 0.0
            let pts = 12
            for _ in 0..<pts {
                let x = rng.unit() * 2000 - 1000, z = rng.unit() * 2000 - 1000
                // exact: solve p + D(p) = x with the reference displacement
                var p = Vec2d(x, z)
                for _ in 0..<8 { let d = ocean.spectrum.referenceDisplacement(x: p.x, z: p.y, time: T); p = Vec2d(x - d.x, z - d.z) }
                let exact = ocean.spectrum.referenceDisplacement(x: p.x, z: p.y, time: T).y
                let q = water.sample(x: x, z: z, time: T).surfaceHeight
                maxH = max(maxH, abs(q - exact)); sumH += abs(q - exact)
            }
            ctx.expect(maxH < 0.02 * Hs, "height query within 2% Hs of exact surface (max \(maxH) m)")
            ctx.log(String(format: "FFT grid max err %.2e m; height query max err %.4f m, mean %.4f m (Hs %.2f m)", maxErr, maxH, sumH / Double(pts), Hs))
            // Throughput of the thread-safe query from all cores.
            let n = 200_000
            let t1 = Date()
            JobSystem.shared.parallelFor(n, grain: 2048) { r in for i in r { _ = water.surfaceHeight(x: Double(i) * 0.37, z: Double(i) * 0.11, time: T) } }
            let qps1 = Double(n) / Date().timeIntervalSince(t1) / 1e6
            let hs = water.heightSampler(time: T)
            let t2 = Date()
            JobSystem.shared.parallelFor(n * 5, grain: 4096) { r in for i in r { _ = hs(Double(i) * 0.37, Double(i) * 0.11) } }
            ctx.log(String(format: "surfaceHeight: %.1f M queries/s, heightSampler (hull path): %.1f M queries/s (all cores)", qps1, Double(n * 5) / Date().timeIntervalSince(t2) / 1e6))
        }

        SelfTestRegistry.register("water", "buoyancy-cpu-vs-gpu") { ctx in
            // Placement decision for hull buoyancy. The physics step needs the force synchronously every substep, so
            // a GPU path costs at least one commit + wait round trip. Measure that floor against the CPU path.
            guard let gpu = GPU.shared else { ctx.fail("no Metal device"); return }
            var rt: [Double] = []
            for _ in 0..<200 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let cb = gpu.queue.makeCommandBuffer()!; cb.commit(); cb.waitUntilCompleted()
                rt.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e3)
            }
            rt.sort()
            var s = OceanSettings(); s.windSpeed = 8
            let water = WaterSystem(); water.setOcean(s); water.oceanEnabled = true; water.updateOceanSync(time: 1)
            var line = ""
            for (seg, rings) in [(16, 8), (48, 24), (128, 64)] {
                let m = MeshBuilder.sphere(radius: 2, segments: seg, rings: rings)
                let hull = HullMesh(positions: m.vertices.map { Vec3($0.px, $0.py, $0.pz) * Vec3(3, 1, 1) }, indices: m.indices)
                let st = BodyState(transform: Transform(position: [0, 0.3, 0]), linearVelocity: [3, 0, 0], centerOfMass: [0, 0.3, 0])
                var best = Double.infinity
                for _ in 0..<30 {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    _ = water.submergedForces(hull: hull, state: st, time: 1)
                    best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e3)
                }
                line += String(format: "%d tris %.1f µs; ", m.indices.count / 3, best)
            }
            ctx.log(String(format: "GPU empty commit+wait: median %.1f µs, min %.1f µs; CPU buoyancy (min): %@", rt[rt.count / 2], rt[0], line))
        }

        SelfTestRegistry.register("water", "ocean-floating-box") { ctx in
            guard GPU.shared != nil else { ctx.fail("no Metal device"); return }
            // Box in moderate sea: must stay afloat, mean draft close to Archimedes and heave with the waves.
            var s = OceanSettings(); s.windSpeed = 7
            let water = WaterSystem(); water.setOcean(s); water.oceanEnabled = true
            let hull = boxHull([4, 2, 4]); let m = 4.0 * 4 * 2 * 400
            var b = TestBody(state: BodyState(transform: Transform(position: [0, 0.5, 0]), centerOfMass: [0, 0.5, 0]), mass: m,
                             inertiaBody: Vec3d(m / 12 * 20, m / 12 * 32, m / 12 * 20))
            let dt = 1.0 / 600
            var t = 0.0, minY = 1e9, maxY = -1e9, sumDraft = 0.0, nD = 0
            let t0 = Date()
            for i in 0..<(600 * 30) {
                if i % 10 == 0 { water.step(dt: dt * 10, time: t) }
                let (ft, _) = water.submergedForces(hull: hull, state: b.state, time: t)
                b.step(ft, dt: dt); t += dt
                if t > 10 { minY = min(minY, b.state.transform.position.y); maxY = max(maxY, b.state.transform.position.y)
                    sumDraft += water.surfaceHeight(x: b.state.transform.position.x, z: b.state.transform.position.z, time: t) - (b.state.transform.position.y - 1); nD += 1 }
            }
            let wall = Date().timeIntervalSince(t0)
            let draft = sumDraft / Double(nD), expected = m / (1025 * 16)
            ctx.expect(minY > -3 && maxY < 3, "stays afloat (y ∈ [\(minY), \(maxY)])")
            ctx.expect(abs(draft - expected) < 0.25, "mean draft \(draft) ≈ \(expected)")
            ctx.log(String(format: "Hs %.2f m, heave range %.2f m, mean draft %.3f m (calm-water %.3f m), %.0f substeps/s wall", water.significantWaveHeight, maxY - minY, draft, expected, 600 * 30 / wall))
        }

        SelfTestRegistry.register("water", "fluid-dambreak") { ctx in
            guard let gpu = GPU.shared else { ctx.fail("no Metal device"); return }
            let zone = try FluidZone(device: gpu.device, queue: gpu.queue, origin: .zero, dims: [64, 64, 64], cellSize: 4.0 / 64, fill: .damBreak)
            let s0 = zone.stats()
            ctx.log("particles: \(zone.particleCount), cells 64³, h = \(zone.cellSize) m, max stable dt \(String(format: "%.4f", zone.maxStableDt)) s")
            let t0 = Date()
            var gpuMs = 0.0, frames = 0, worstSpeed = 0.0
            while zone.simulatedTime < 5 - 1e-9 {
                zone.stepSync(dt: 1.0 / 60); frames += 1; gpuMs += zone.lastGPUTimeMs
                if frames % 30 == 0 { let st = zone.stats(); worstSpeed = max(worstSpeed, st.maxSpeed)
                    if st.nonFinite > 0 || st.outOfBounds > 0 { break } }
            }
            let wall = Date().timeIntervalSince(t0)
            let s1 = zone.stats()
            ctx.expect(s1.nonFinite == 0, "no NaN particles (\(s1.nonFinite))")
            ctx.expect(s1.outOfBounds == 0, "all particles inside the domain (\(s1.outOfBounds))")
            ctx.expect(worstSpeed < 15, "velocities bounded (max \(worstSpeed) m/s; free-fall bound ≈ 8.9)")
            ctx.expect(s1.centerOfMass.y < s0.centerOfMass.y - 0.3, "column collapsed (COM y \(s0.centerOfMass.y) → \(s1.centerOfMass.y))")
            ctx.expect(s1.centerOfMass.x > s0.centerOfMass.x + 0.4, "water spread across the tank (COM x \(s0.centerOfMass.x) → \(s1.centerOfMass.x))")
            ctx.log(String(format: "5 s simulated in %.2f s wall (%d frames), GPU %.2f ms/frame avg; COM (%.2f,%.2f)→(%.2f,%.2f); KE %.2f J/kg", wall, frames, gpuMs / Double(frames),
                           s0.centerOfMass.x, s0.centerOfMass.y, s1.centerOfMass.x, s1.centerOfMass.y, s1.kineticEnergyPerKg))
        }

        SelfTestRegistry.register("water", "fluid-profile") { ctx in
            guard let gpu = GPU.shared else { ctx.fail("no Metal device"); return }
            for res in [64, 48, 32] {
                let zone = try FluidZone(device: gpu.device, queue: gpu.queue, origin: .zero, dims: [res, res, res], cellSize: 4.0 / Double(res), fill: .damBreak)
                for iters in [30, 0] {
                    zone.pressureIterations = iters
                    var ms = 0.0
                    for _ in 0..<10 { zone.stepSync(dt: 1.0 / 120); ms += zone.lastGPUTimeMs }
                    ctx.log(String(format: "%d³, pressure sweeps %d: %.2f ms per substep (%d particles)", res, iters, ms / 10, zone.particleCount))
                }
            }
        }

        SelfTestRegistry.register("water", "fluid-sort-ab") { ctx in
            // Does ordering particles by cell speed up the GPU step? Interleaved A/B on a mixed (post dam-break) zone.
            guard let gpu = GPU.shared else { ctx.fail("no Metal device"); return }
            let zone = try FluidZone(device: gpu.device, queue: gpu.queue, origin: .zero, dims: [64, 64, 64], cellSize: 4.0 / 64, fill: .damBreak)
            zone.autoSortInterval = 0
            for _ in 0..<60 { zone.stepSync(dt: 1.0 / 120) }
            // shuffle to emulate long-run mixing
            let p = zone.posBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self), v = zone.velBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            var rng = PCG32(seed: 7)
            for i in stride(from: zone.particleCount - 1, to: 0, by: -1) { let j = Int(rng.next32() % UInt32(i + 1)); swap(&p[i], &p[j]); swap(&v[i], &v[j]) }
            var a: [Double] = [], b: [Double] = []
            for _ in 0..<3 {
                for _ in 0..<5 { zone.stepSync(dt: 1.0 / 120); a.append(zone.lastGPUTimeMs) }
                let t0 = Date(); zone.sortParticlesByCell(); let sortMs = Date().timeIntervalSince(t0) * 1000
                for _ in 0..<5 { zone.stepSync(dt: 1.0 / 120); b.append(zone.lastGPUTimeMs) }
                ctx.log(String(format: "CPU counting sort of %d particles: %.2f ms", zone.particleCount, sortMs))
                for i in stride(from: zone.particleCount - 1, to: 0, by: -1) { let j = Int(rng.next32() % UInt32(i + 1)); swap(&p[i], &p[j]); swap(&v[i], &v[j]) }
            }
            a.sort(); b.sort()
            ctx.log(String(format: "64³ GPU ms per substep: shuffled median %.2f min %.2f; sorted median %.2f min %.2f", a[a.count / 2], a[0], b[b.count / 2], b[0]))
            ctx.expect(zone.stats().nonFinite == 0, "finite after sort")
        }

        SelfTestRegistry.register("water", "fluid-coupling") { ctx in
            guard let gpu = GPU.shared else { ctx.fail("no Metal device"); return }
            // A fixed 1×0.5×1 m block half-immersed in a still pool: fluid pressure force ≈ ρ g V_sub upward.
            let zone = try FluidZone(device: gpu.device, queue: gpu.queue, origin: .zero, dims: [48, 48, 48], cellSize: 3.0 / 48, fill: .pool, fillLevel: 1.5)
            let level = 1.5
            let st = BodyState(transform: Transform(position: [1.5, level, 1.5]), centerOfMass: [1.5, level, 1.5])
            zone.setObstacle(id: 1, state: st, halfExtents: [0.5, 0.25, 0.5])
            for _ in 0..<120 { zone.stepSync(dt: 1.0 / 60) }
            var avg = Vec3d.zero
            for _ in 0..<30 { zone.stepSync(dt: 1.0 / 60); avg += zone.obstacleForce(id: 1).force / 30 }
            let expected = 1000 * kGravity * (1 * 0.25 * 1)
            ctx.expect(avg.y > 0.6 * expected && avg.y < 1.6 * expected, "two-way coupling force \(avg.y) N ≈ ρgV = \(expected) N")
            ctx.log(String(format: "fluid force on block (%.0f, %.0f, %.0f) N vs ρgV_sub %.0f N (grid h=%.3f m, level drifts as particles settle)", avg.x, avg.y, avg.z, expected, zone.cellSize))
        }

        SelfTestRegistry.register("water", "spec-roundtrip") { ctx in
            var spec = WaterSpec()
            spec.oceanEnabled = true; spec.seaLevel = 2; spec.windSpeed = 10
            spec.lakes = [["x": .number(100), "z": .number(-50), "radius": .number(40), "level": .number(12), "custom": .string("keep")]]
            spec.rivers = [["points": .array([.array([.number(0), .number(5), .number(0)]), .array([.number(100), .number(3), .number(20)]), .array([.number(200), .number(1), .number(0)])]),
                            "width": .number(10), "speed": .number(2)]]
            let water = WaterSystem(gpu: nil)
            try water.load(spec: spec)
            let out = water.makeSpec()
            ctx.expect(out.lakes.first?["custom"] == .string("keep"), "unknown lake keys preserved")
            ctx.expect(out.oceanEnabled && out.seaLevel == 2 && out.windSpeed == 10, "ocean params round-trip")
            let s = water.sample(x: 100, z: -50, time: 0)
            ctx.expectClose(s.surfaceHeight, 12, tol: 1e-9, "lake level wins over sea level inside the lake")
            let f = water.flow(x: 100, z: 18)
            ctx.expect(f.x > 1, "river flows downstream at centre-line (\(f))")
            let data = try JSONIO.encode(out); let back = try JSONIO.decode(WaterSpec.self, from: data)
            ctx.expect(back == out, "WaterSpec JSON round-trip")
        }

        SelfTestRegistry.register("water", "ocean-fft-ab") { ctx in
            // A/B of the fused 2-dispatch ocean FFT vs the original 4-pass path, interleaved so GPU clock and
            // contention from other work affect both equally. Also checks both produce the same surface.
            guard let gpu = GPU.shared else { ctx.fail("no Metal device"); return }
            var s = OceanSettings(); s.windSpeed = 8
            let o = try OceanGPU(device: gpu.device, queue: gpu.queue, settings: s)
            var ta: [Double] = [], tb: [Double] = []
            var maxDiff = 0.0
            for i in 0..<120 {
                let T = 10 + Double(i) * 0.016
                o.fused = false; o.updateSync(time: T); if i >= 20 { ta.append(o.lastGPUTimeMs) }
                let ha = o.views()!.0.height(x: 37, z: -12)
                o.fused = true; o.updateSync(time: T + 1e-9); if i >= 20 { tb.append(o.lastGPUTimeMs) }
                let hb = o.views()!.0.height(x: 37, z: -12)
                maxDiff = max(maxDiff, abs(ha - hb))
            }
            ta.sort(); tb.sort()
            ctx.log(String(format: "ocean FFT GPU ms  4-pass: median %.3f min %.3f   fused: median %.3f min %.3f   max |dh| %.2e m",
                           ta[ta.count / 2], ta[0], tb[tb.count / 2], tb[0], maxDiff))
            ctx.expect(maxDiff < 1e-3, "fused and 4-pass FFT agree (max |dh| \(maxDiff) m)")
        }

        SelfTestRegistry.register("water", "render") { ctx in
            guard let gpu = GPU.shared else { ctx.fail("no Metal device"); return }
            let water = WaterSystem()
            // Note: RenderRegistry's init is internal to PWRender, so this uses the shared registry (empty in headless runs).
            let registry = RenderRegistry.shared
            let r = try Renderer(device: gpu.device, queue: gpu.queue, registry: registry)
            defer { registry.remove(water) }
            var s = OceanSettings(); s.windSpeed = 10
            water.setOcean(s); water.oceanEnabled = true
            water.terrainHeight = { x, z in -20 + 0.02 * (x - 300) }       // sloping sea floor rising to a beach at x ≈ 1300
            let zone = water.spawnLocalFluidZone(around: [0, 0, -6], size: 4, resolution: 48)
            for _ in 0..<40 { zone?.stepSync(dt: 1.0 / 60) }
            water.splashes.emit(at: [2, 0.3, -4], velocity: [0, 5, 0], count: 300, spread: 0.5)
            registry.add(water)
            var cam = Camera(); cam.lookAt([0, 0, -30], from: [0, 6, 12])
            for aa in AntiAliasing.allCases {
                r.settings.antiAliasing = aa
                guard let px = RenderSelfTests.renderOffscreen(renderer: r, camera: cam, width: 640, height: 360) else { ctx.fail("render failed"); continue }
                // Bottom half is water: expect non-black, blue-ish, and not identical to the sky colour.
                var b = 0, g = 0, rr = 0, n = 0
                for y in 200..<360 { for x in stride(from: 0, to: 640, by: 4) { let i = (y * 640 + x) * 4; b += Int(px[i]); g += Int(px[i + 1]); rr += Int(px[i + 2]); n += 1 } }
                ctx.expect(b / n > 15 && b >= rr, "\(aa): water visible and blue-dominant (B=\(b / n) G=\(g / n) R=\(rr / n))")
                let url = outDir().appendingPathComponent("pw-water-\(aa.rawValue).png")
                RenderSelfTests.writePNG(px, width: 640, height: 360, to: url)
                ctx.log("\(aa): wrote \(url.path), frame GPU \(String(format: "%.2f", r.lastGPUTimeMs)) ms, ocean FFT \(String(format: "%.3f", water.oceanGPUTimeMs)) ms")
            }
        }
    }
}
