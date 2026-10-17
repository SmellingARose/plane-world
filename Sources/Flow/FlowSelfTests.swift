// "flow" selftests: GPU LBM validation against textbook/experimental values (coarse grids, broad bands — the
// measured numbers are printed so docs/CFD.md can quote them). Heavier per-preset sweeps run only with
// PW_FLOW_VALIDATE=1 (`PlaneWorld --selftest flow.validate`).
import Foundation
import simd
import Metal
import PWCore

public enum FlowSelfTests {
    /// Runs one fixed body in a uniform wind and returns the time-averaged force/torque over the second half.
    struct RunResult { var force = Vec3d.zero, torque = Vec3d.zero, sample = Vec3d.zero, msPerUpdate = 0.0, msPerLatticeStep = 0.0, diag = CFDDiagnostics(), cells = 0 }

    static func run(_ solver: LBMSolver, parts: [AeroPartGeometry], poses: [AeroPartPose], rotors: [AeroRotorSource] = [],
                    settings: CFDSettings, wind: Vec3d, seconds: Double, dt: Double = 0.004) throws -> RunResult {
        try solver.configure(parts: parts, settings: settings)
        var env = AeroEnvironmentSample(); env.wind = wind
        let count = max(poses.count, 1)
        var forces = [ForceTorque](repeating: .zero, count: count), vels = [Vec3d](repeating: .zero, count: count)
        let steps = Int(seconds / dt)
        var res = RunResult(); var avgN = 0; var gpu = 0.0, lat = 0.0
        poses.withUnsafeBufferPointer { pp in rotors.withUnsafeBufferPointer { rp in
            let rdummy = UnsafeMutablePointer<AeroRotorSource>.allocate(capacity: 1); defer { rdummy.deallocate() }
            for s in 0..<steps {
                solver.submit(com: .zero, velocity: .zero, orientation: Quatd(ix: 0, iy: 0, iz: 0, r: 1), poses: pp.baseAddress!, poseCount: poses.count,
                              rotors: rp.baseAddress ?? UnsafePointer(rdummy), rotorCount: rotors.count, env: env, dt: dt)
                _ = solver.collect(forces: &forces, sampleVelocity: &vels, count: count)
                if s >= steps / 2 {
                    for f in forces { res.force += f.force; res.torque += f.torque }
                    res.sample += vels[0]; avgN += 1
                    gpu += solver.diagnostics.gpuMsPerStep; lat += solver.gpuMsPerLatticeStep
                }
            }
        }}
        let k = 1 / Double(max(avgN, 1))
        res.force *= k; res.torque *= k; res.sample *= k; res.msPerUpdate = gpu * k; res.msPerLatticeStep = lat * k
        res.diag = solver.diagnostics
        res.cells = Int(res.diag.gridCells.x) * Int(res.diag.gridCells.y) * Int(res.diag.gridCells.z)
        return res
    }

    static func geom(_ m: ([Vec3], [UInt32]), part: Int = 0, kind: String = "body") -> AeroPartGeometry {
        AeroPartGeometry(partIndex: part, kind: kind, positions: m.0, indices: m.1, isRotor: false)
    }

    static func bodySettings(cpm: Double, maxCells: Int = 128) -> CFDSettings {
        var s = CFDSettings.preset(.medium)
        s.cellsPerMeter = cpm; s.maxCellsPerAxis = maxCells
        s.collision = .regularized; s.turbulence = .smagorinsky
        s.padUpstream = 1.5; s.padDownstream = 3; s.padLateral = 1.5
        s.convergenceEvery = 0
        return s
    }

    static func sphereCd(cpm: Double, settings: CFDSettings? = nil, seconds: Double = 0.3) throws -> (Double, RunResult) {
        let D = 0.2, U = 10.0
        let s = settings ?? bodySettings(cpm: cpm)
        let r = try run(LBMSolver(), parts: [geom(FlowShapes.sphere(radius: Float(D / 2)))], poses: [AeroPartPose()], settings: s,
                        wind: Vec3d(U, 0, 0), seconds: seconds)
        return (r.force.x / (0.5 * 1.225 * U * U * .pi * D * D / 4), r)
    }

    public static func register() {
        SelfTestRegistry.register("flow", "kernels-compile") { ctx in
            let s = LBMSolver()
            guard s.isAvailable else { ctx.fail("LBM unavailable: \(s.lastError ?? "?")"); return }
            for q in [19, 27] { do { _ = try LBMPipelines.get(s.device!, q: q) } catch { ctx.fail("D3Q\(q): \(error)") } }
        }

        SelfTestRegistry.register("flow", "sphere-drag") { ctx in
            // Re = UD/ν = 10·0.2/1.5e-5 ≈ 1.3e5 (subcritical, experiment C_D ≈ 0.45–0.5). 16 cells per diameter.
            let (cd, r) = try sphereCd(cpm: 80)
            ctx.log(String(format: "sphere Re=1.3e5, 16 cells/D, %d cells: C_D = %.3f (exp ≈ 0.47)  %.2f ms/update, %.3f ms/LBM step, max Ma_lat %.3f, Δρ %.2e",
                           r.cells, cd, r.msPerUpdate, r.msPerLatticeStep, r.diag.maxLatticeMach, r.diag.massDrift))
            ctx.expect(!r.diag.diverged, "diverged")
            ctx.expect(cd > 0.25 && cd < 1.0, "sphere C_D \(cd) outside the coarse-grid band 0.25–1.0")
            ctx.expect(abs(r.force.y) < 0.35 * abs(r.force.x) && abs(r.force.z) < 0.35 * abs(r.force.x), "sphere side force too large: \(r.force)")
        }

        SelfTestRegistry.register("flow", "cube-drag") { ctx in
            let a = 0.2, U = 10.0
            var s = bodySettings(cpm: 80, maxCells: 96); s.padUpstream = 1; s.padDownstream = 2; s.padLateral = 1.5
            let r = try run(LBMSolver(), parts: [geom(FlowShapes.box(half: Vec3(repeating: Float(a / 2))))], poses: [AeroPartPose()],
                            settings: s, wind: Vec3d(U, 0, 0), seconds: 0.2)
            let cd = r.force.x / (0.5 * 1.225 * U * U * a * a)
            ctx.log(String(format: "cube face-on Re=1.3e5, 16 cells/side: C_D = %.3f (exp ≈ 1.05)", cd))
            ctx.expect(!r.diag.diverged, "diverged")
            ctx.expect(cd > 0.6 && cd < 1.7, "cube C_D \(cd) outside 0.6–1.7")
        }

        SelfTestRegistry.register("flow", "wing-lift-slope") { ctx in
            // NACA 0012 wing, chord 0.15 m, span 0.3 m (AR 2), α = ±6°, Re ≈ 1e5, 20 cells per chord.
            // Finite-wing slope: Helmbold 2πA/(2+√(A²+4)) = 2.60 /rad (lifting line 2π/(1+2/A) = 3.14).
            // At 20 cells/chord the boundary layer is unresolved (thick, separating), so lift is strongly
            // under-predicted — the band below only guards sign and order of magnitude; see docs/CFD.md.
            let c = 0.15, b = 0.3, U = 10.0, al = 6.0 * .pi / 180
            let wing = geom(FlowShapes.nacaWing(chord: Float(c), span: Float(b)))
            var cls: [Double] = [], cd = 0.0
            for sgn in [1.0, -1.0] {
                var p = AeroPartPose(); p.rotation = Quatd(angle: -sgn * al, axis: Vec3d(0, 0, 1))   // +θ about z is nose-down
                var s = bodySettings(cpm: 133, maxCells: 128); s.padUpstream = 1; s.padDownstream = 2; s.padLateral = 1
                let r = try run(LBMSolver(), parts: [wing], poses: [p], settings: s, wind: Vec3d(U, 0, 0), seconds: 0.12)
                let q = 0.5 * 1.225 * U * U * c * b
                cls.append(r.force.y / q); cd = r.force.x / q
                ctx.expect(!r.diag.diverged, "diverged")
            }
            let slope = (cls[0] - cls[1]) / (2 * al), helm = 2 * Double.pi * 2 / (2 + (4.0 + 4).squareRoot())
            ctx.log(String(format: "NACA0012 AR2 α=±6°, 20 cells/chord: C_L = %+.3f / %+.3f, slope %.2f /rad (Helmbold %.2f), C_D(6°) %.3f", cls[0], cls[1], slope, helm, cd))
            ctx.expect(slope > 0.15 * helm && slope < 1.5 * helm, "lift slope \(slope) outside 0.15–1.5 × \(helm)")
        }

        SelfTestRegistry.register("flow", "actuator-disk") { ctx in
            // Static disk R = 0.15 m, T = 10 N: momentum theory v_i = √(T/(2ρA)) ≈ 7.6 m/s at the disk.
            var ro = AeroRotorSource(); ro.partIndex = 0; ro.radius = 0.15; ro.thrust = 10; ro.axis = Vec3d(0, 1, 0); ro.torque = 0.3; ro.omega = 300
            let empty = AeroPartGeometry(partIndex: 0, kind: "prop", positions: [], indices: [], isRotor: true)
            var s = CFDSettings.preset(.medium); s.cellsPerMeter = 40; s.convergenceEvery = 0; s.padDownstream = 4
            let r = try run(LBMSolver(), parts: [empty], poses: [AeroPartPose()], rotors: [ro], settings: s, wind: .zero, seconds: 0.5)
            let vi = (10 / (2 * 1.225 * Double.pi * 0.15 * 0.15)).squareRoot()
            ctx.log(String(format: "actuator disk T=10 N R=0.15: v_disk = %.2f m/s down (momentum theory %.2f), swirl %.2f m/s", -r.sample.y, vi, simd_length(SIMD2(r.sample.x, r.sample.z))))
            ctx.expect(!r.diag.diverged, "diverged")
            ctx.expect(-r.sample.y > 0.6 * vi && -r.sample.y < 1.4 * vi, "disk velocity \(-r.sample.y) vs \(vi)")
        }

        SelfTestRegistry.register("flow", "operators-stable") { ctx in
            // Every lattice × collision × turbulence combination runs a sphere without diverging.
            for lat in CFDLattice.allCases { for col in CFDCollision.allCases { for tb in CFDTurbulence.allCases {
                var s = bodySettings(cpm: 40, maxCells: 64); s.lattice = lat; s.collision = col; s.turbulence = tb
                if tb == .none && col == .bgk { continue }   // BGK without LES at Re 1e5 is expected to blow up
                let (cd, r) = try sphereCd(cpm: 40, settings: s, seconds: 0.1)
                if r.diag.diverged || !cd.isFinite { ctx.fail("\(lat)/\(col)/\(tb) diverged") }
                ctx.log(String(format: "%@ %@ %@: C_D %.3f, %.3f ms/LBM step", lat.rawValue, col.rawValue, tb.rawValue, cd, r.msPerLatticeStep))
            }}}
        }

        SelfTestRegistry.register("flow", "rotating-part-torque") { ctx in
            // A box spinning about y in still air must feel a resisting torque (moving-wall bounce-back + momentum exchange).
            var p = AeroPartPose(); p.angVel = Vec3d(0, 40, 0)
            var s = bodySettings(cpm: 60, maxCells: 64)
            s.padUpstream = 1; s.padDownstream = 1; s.padLateral = 1
            let solver = LBMSolver()
            try solver.configure(parts: [geom(FlowShapes.box(half: Vec3(0.15, 0.03, 0.03)))], settings: s)
            var forces = [ForceTorque](repeating: .zero, count: 1), vels = [Vec3d](repeating: .zero, count: 1)
            var ty = 0.0
            for i in 0..<60 {
                let ang = 40 * Double(i) * 0.004
                p.rotation = Quatd(angle: ang, axis: Vec3d(0, 1, 0))
                [p].withUnsafeBufferPointer { pp in
                    let rd = UnsafeMutablePointer<AeroRotorSource>.allocate(capacity: 1); defer { rd.deallocate() }
                    solver.submit(com: .zero, velocity: .zero, orientation: Quatd(ix: 0, iy: 0, iz: 0, r: 1), poses: pp.baseAddress!, poseCount: 1,
                                  rotors: rd, rotorCount: 0, env: AeroEnvironmentSample(), dt: 0.004)
                }
                _ = solver.collect(forces: &forces, sampleVelocity: &vels, count: 1)
                if i >= 30 { ty += forces[0].torque.y / 30 }
            }
            ctx.log(String(format: "rotating bar ω=40 rad/s: aero torque_y = %.4f N·m (must oppose ω)", ty))
            ctx.expect(ty < 0, "spinning bar torque should oppose rotation, got \(ty)")
        }

        SelfTestRegistry.register("flow", "pool-matches-single") { ctx in
            let s = bodySettings(cpm: 40, maxCells: 64)
            let g = [geom(FlowShapes.sphere(radius: 0.1))]
            let single = LBMSolver(); try single.configure(parts: g, settings: s)
            let pool = LBMDomainPool(lanes: 2)
            for i in 0..<2 { try pool.backend(i).configure(parts: g, settings: s) }
            var env = AeroEnvironmentSample(); env.wind = Vec3d(10, 0, 0)
            var f1 = [ForceTorque](repeating: .zero, count: 1), f2 = f1, f3 = f1, v = [Vec3d](repeating: .zero, count: 1)
            let pose = [AeroPartPose()]
            let rd = UnsafeMutablePointer<AeroRotorSource>.allocate(capacity: 1); defer { rd.deallocate() }
            let id = Quatd(ix: 0, iy: 0, iz: 0, r: 1)
            for _ in 0..<20 {
                pose.withUnsafeBufferPointer { pp in
                    single.submit(com: .zero, velocity: .zero, orientation: id, poses: pp.baseAddress!, poseCount: 1, rotors: rd, rotorCount: 0, env: env, dt: 0.004)
                    for i in 0..<2 { pool.backend(i).submit(com: .zero, velocity: .zero, orientation: id, poses: pp.baseAddress!, poseCount: 1, rotors: rd, rotorCount: 0, env: env, dt: 0.004) }
                }
                pool.flush()
                _ = single.collect(forces: &f1, sampleVelocity: &v, count: 1)
                _ = pool.backend(0).collect(forces: &f2, sampleVelocity: &v, count: 1)
                _ = pool.backend(1).collect(forces: &f3, sampleVelocity: &v, count: 1)
            }
            let d = simd_length(f1[0].force - f2[0].force) + simd_length(f2[0].force - f3[0].force)
            ctx.log(String(format: "pool lane force %.4f N vs single %.4f N", f2[0].force.x, f1[0].force.x))
            ctx.expect(d < 1e-3 * max(1, simd_length(f1[0].force)), "pooled lanes differ from single domain by \(d)")
        }

        SelfTestRegistry.register("flow", "convergence-shadow") { ctx in
            var s = bodySettings(cpm: 60, maxCells: 96); s.convergenceEvery = 20
            let (_, r) = try sphereCd(cpm: 60, settings: s, seconds: 0.2)
            ctx.log(String(format: "fine vs 2x-coarse shadow: Δ = %.1f%%, Richardson error ≈ %.1f%%", r.diag.coarseDelta * 100, r.diag.richardsonError * 100))
            ctx.expect(r.diag.coarseDelta.isFinite, "no convergence estimate produced")
        }

        SelfTestRegistry.register("flow", "visualization") { ctx in
            var s = bodySettings(cpm: 40, maxCells: 64)
            s.visualization.enabled = true; s.visualization.field = .speed; s.visualization.sliceAxis = 2
            s.visualization.particles = true; s.visualization.particleCount = 2048
            let sv = LBMSolver()
            _ = try run(sv, parts: [geom(FlowShapes.sphere(radius: 0.1))], poses: [AeroPartPose()], settings: s, wind: Vec3d(10, 0, 0), seconds: 0.08)
            guard let sl = sv.slice else { ctx.fail("no slice produced"); return }
            let t = sl.texture
            var px = [UInt8](repeating: 0, count: t.width * t.height * 4)
            t.getBytes(&px, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
            var lit = 0, solid = 0
            for i in 0..<(t.width * t.height) { if px[4 * i + 3] > 200 && px[4 * i] == 20 { solid += 1 } else if px[4 * i + 3] > 0 { lit += 1 } }
            var moved = 0
            if let pb = sv.particleBuffer {
                let p = pb.contents().bindMemory(to: SIMD4<Float>.self, capacity: sv.particleCount)
                for i in 0..<sv.particleCount where p[i].x >= 0 && p[i].w > 0 { moved += 1 }
            }
            ctx.log("slice \(t.width)x\(t.height): \(lit) flow texels, \(solid) solid texels; \(moved)/\(sv.particleCount) particles advected")
            ctx.expect(lit > t.width * t.height / 2 && solid > 10, "slice texture looks empty")
            ctx.expect(moved > sv.particleCount / 2, "particles did not advect")
        }

        SelfTestRegistry.register("flow", "voxel-volume") { ctx in
            for (name, m, vol) in [("sphere", FlowShapes.sphere(radius: 0.1), 4.18879e-3), ("naca", FlowShapes.nacaWing(chord: 0.15, span: 0.6), 0.0821 * 0.15 * 0.15 * 0.6), ("box", FlowShapes.box(half: Vec3(0.1, 0.05, 0.1)), 0.004)] {
                let sv = LBMSolver(); var st = bodySettings(cpm: 80, maxCells: 128)
                _ = try run(sv, parts: [geom(m)], poses: [AeroPartPose()], settings: st, wind: Vec3d(10, 0, 0), seconds: 0.008)
                st.cellsPerMeter = 80
                let v = Double(sv.solidCellCount) * pow(sv.dx, 3)
                ctx.log(String(format: "%@: voxel volume %.5f m3 vs exact %.5f (dx %.4f)", name, v, vol, sv.dx))
            }
        }

        SelfTestRegistry.register("flow", "validate") { ctx in
            guard ProcessInfo.processInfo.environment["PW_FLOW_VALIDATE"] == "1" else { ctx.log("skipped (set PW_FLOW_VALIDATE=1)"); return }
            for (name, cpm) in [("draft", 40.0), ("medium", 80.0), ("high", 120.0), ("ultra", 160.0)] {
                var s = bodySettings(cpm: cpm, maxCells: 256)
                if name == "ultra" { s.lattice = .d3q27; s.turbulence = .wale }
                let (cd, r) = try sphereCd(cpm: cpm, settings: s, seconds: 0.4)
                ctx.log(String(format: "sphere %@ (%.0f cells/D, %d cells, %@/%@): C_D %.3f, %.2f ms/update(4 ms), %.3f ms/LBM step",
                               name, cpm * 0.2, r.cells, s.lattice.rawValue, s.turbulence.rawValue, cd, r.msPerUpdate, r.msPerLatticeStep))
            }
        }
    }
}
