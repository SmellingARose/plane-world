// OWNED BY integrator. Fast vs full (CFD) per-part force comparison at a held flight condition.
//   PlaneWorld --aero-compare <craft name | craft.json> [--speed V] [--alpha deg] [--alt m] [--throttle 0..1]
//              [--seconds s] [--cfd-preset draft|medium|high|ultra] [--cells-per-m N] [--max-cells N]
// The craft is pinned (holdState) at the condition for --seconds of sim time so the CFD flow develops, then one
// equation capture records fast and CFD forces per part (CFD forces lag one update; see docs/CFD.md).
import Foundation
import simd
import PWCore
import PWPhysics
import PWCraft
import PWFlow

enum AeroCompareCLI {
    static func run(_ args: [String]) -> Int32 {
        let v = { (f: String) in TrainCLI.value(args, f) }
        guard let ref = v("--aero-compare") else { print("usage: see Sources/App/AeroCompareCLI.swift"); return 2 }
        var doc: CraftDocument?
        if ref.hasSuffix(".json") { doc = try? JSONIO.decode(CraftDocument.self, file: URL(fileURLWithPath: ref)) }
        else { doc = (CraftLibrary.loadBundled(from: .module) + CraftLibrary.loadUserCrafts()).first { $0.name == ref } ?? (ref == "Trainer" ? PhysicsPresets.trainer() : nil) }
        guard let craft = doc.map({ CraftOutputs.prepareForFlight($0) }) else { print("error: craft '\(ref)' not found"); return 1 }
        let speed = v("--speed").flatMap(Double.init) ?? 0, alpha = v("--alpha").flatMap(Double.init) ?? 0
        let alt = v("--alt").flatMap(Double.init) ?? 200, thr = v("--throttle").flatMap(Double.init) ?? 0
        let secs = v("--seconds").flatMap(Double.init) ?? 1.0
        var cfd = CFDSettings.preset(v("--cfd-preset").flatMap(CFDQualityPreset.init(rawValue:)) ?? .medium)
        if let c = v("--cells-per-m").flatMap(Double.init) { cfd.cellsPerMeter = c; cfd.preset = .custom }
        if let c = v("--max-cells").flatMap(Int.init) { cfd.maxCellsPerAxis = c; cfd.preset = .custom }
        if args.contains("--convergence") { cfd.convergenceEvery = 64 }

        let sim = CraftSim()
        do { try sim.load(craft) } catch { print("error: \(error)"); return 1 }
        for o in sim.outputs where o.kind == .motor { sim.setOutput(id: o.id, value: thr) }
        do { try AeroGeometry.enableFull(on: sim, settings: cfd) } catch { print("error: \(error)"); return 1 }
        let cap = EquationCapture(capacity: 4096); sim.equationCapture = cap
        let q = Quatd(angle: alpha * Double.pi / 180, axis: Vec3d(0, 0, 1))
        let pos = Vec3d(0, alt, 0), vel = Vec3d(speed, 0, 0)
        sim.reset(spawn: Transform(position: pos, rotation: q))
        let env = SimEnvironment()
        let dt = 1.0 / 60, steps = Int((secs / dt).rounded())
        let t0 = Date()
        for k in 0..<steps {
            sim.holdState(position: pos, orientation: q, velocity: vel)
            if k == steps - 1 { cap.request(part: -1) }
            sim.step(dt: dt, env: env)
        }
        let wall = Date().timeIntervalSince(t0)
        let d = sim.aeroBackend!.diagnostics
        print("craft \(craft.name)  V=\(speed) m/s  alpha=\(alpha) deg  alt=\(alt) m  throttle=\(thr)  held \(secs) s sim in \(String(format: "%.1f", wall)) s wall (\(String(format: "%.2f", secs / wall))x real time)")
        print("CFD preset \(cfd.preset.rawValue): grid \(d.gridCells.x)x\(d.gridCells.y)x\(d.gridCells.z) dx=\(String(format: "%.4f", d.dx)) m  dt_lattice=\(String(format: "%.2e", d.dtLattice)) s  maxMa=\(String(format: "%.3f", d.maxLatticeMach))  massDrift=\(String(format: "%.2e", d.massDrift))  gpu=\(String(format: "%.2f", d.gpuMsPerStep)) ms/update  updates=\(sim.fullAeroUpdates)\(d.diverged ? "  DIVERGED" : "")" + (cfd.convergenceEvery > 0 ? String(format: "  coarseDelta=%.1f%%  richardson=%.1f%%", d.coarseDelta * 100, d.richardsonError * 100) : ""))
        // Lift/drag axes: drag along -V (or world -y "down" component at hover), lift = world +y.
        print("part                     | fast Fx    Fy    Fz (N)          | CFD Fx    Fy    Fz (N)           | |F| fast  |F| CFD   diff")
        var tf = Vec3d.zero, tc = Vec3d.zero
        for i in 0..<cap.count where cap.records[i].id == .cfdMomentumExchange {
            let r = cap.records[i], pi = Int(r.partIndex)
            let name = pi < craft.parts.count ? "\(craft.parts[pi].name) (\(craft.parts[pi].type))" : "#\(pi)"
            let f = Vec3d(r.value(0), r.value(1), r.value(2)), c = r.result.force
            tf += f; tc += c
            let diff = r.value(6) < 1 ? "   n/a" : String(format: "%+5.0f%%", r.value(8))   // |F_fast| < 1 N: % meaningless
            print(String(format: "%@| %7.2f %7.2f %7.2f         | %7.2f %7.2f %7.2f          | %7.2f  %7.2f  %@",
                         TrainCLI.pad(name, 25), f.x, f.y, f.z, c.x, c.y, c.z, r.value(6), r.value(7), diff))
        }
        print(String(format: "%@| %7.2f %7.2f %7.2f         | %7.2f %7.2f %7.2f          | %7.2f  %7.2f  %+6.0f%%",
                     TrainCLI.pad("TOTAL (non-rotor parts)", 25), tf.x, tf.y, tf.z, tc.x, tc.y, tc.z, simd_length(tf), simd_length(tc),
                     simd_length(tf) > 1e-9 ? (simd_length(tc) - simd_length(tf)) / simd_length(tf) * 100 : 0))
        return 0
    }
}
extension TrainCLI {
    static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }
}

/// Debug: random-control episodes on a craft until the state goes non-finite; prints the last finite state.
///   PlaneWorld --nan-hunt <craft.json> [--episodes N]
enum NaNHunt {
    static func run(_ args: [String]) -> Int32 {
        guard let p = TrainCLI.value(args, "--nan-hunt"), let doc = try? JSONIO.decode(CraftDocument.self, file: URL(fileURLWithPath: p)) else { return 2 }
        let craft = CraftOutputs.prepareForFlight(doc)
        let eps = TrainCLI.value(args, "--episodes").flatMap(Int.init) ?? 200
        var rng = SplitMix(seed: 7)
        var env = SimEnvironment()
        let shared = CraftSim(); try? shared.load(craft)
        if args.contains("--scenario") {
            let sim = shared; sim.turbulence = 0.2
            let names = sim.outputs.map(\.name); print(names)
            func set(_ n: String, _ x: Double) { if let i = names.firstIndex(of: n) { sim.setOutput(index: i, value: x) } }
            set("Lift upper", 1); set("Lift lower", 0)
            for _ in 0..<30 { sim.step(dt: 0.02, env: env) }
            sim.reset(spawn: sim.restingSpawn())
            set("Lift upper", 0.004); set("Lift lower", 0); set("Vane X", -1); set("Vane Z", 0.987)
            for k in 0..<100 { sim.step(dt: 0.02, env: env); if k % 5 == 0 || simd_length(sim.angularVelocityWorld) > 50 { print(k, sim.position, sim.angularVelocityWorld) }; if simd_length(sim.angularVelocityWorld) > 1e3 { print(sim.debugDump()); break } }
            return 0
        }
        for e in 0..<eps {
            let sim: CraftSim
            if args.contains("--reuse") { sim = shared; sim.reset(spawn: sim.restingSpawn()) } else { sim = CraftSim(); try? sim.load(craft) }
            sim.turbulence = 0.2
            env.wind = Vec3d(rng.next() * 2 - 1, 0, rng.next() * 2 - 1) * 1.4
            if let off = TrainCLI.value(args, "--off") {
                var t = sim.fastToggles
                for k in off.split(separator: ",") { switch k { case "gyro": t.gyro = false; case "pFactor": t.pFactor = false; case "downwash": t.downwash = false; case "blockage": t.blockage = false; case "cadWash": t.cadWash = false; default: break } }
                sim.fastToggles = t
            }
            var outs = sim.outputs.map { _ in rng.next() * 2 - 1 }
            for k in 0..<1200 {
                if k % 6 == 0 { for i in outs.indices { outs[i] = args.contains("--bang") ? (rng.next() < 0.5 ? -1 : 1) : max(-1, min(1, outs[i] + (rng.next() - 0.5) * 0.6)); sim.setOutput(index: i, value: outs[i]) } }
                let before = (sim.position, sim.velocity, sim.angularMomentum, sim.angularVelocityWorld)
                env.time = Double(k) / 60; sim.step(dt: 1.0 / 60, env: env)
                if !(sim.position.x.isFinite && sim.angularMomentum.x.isFinite && sim.angularMomentum.y.isFinite) {
                    print("episode \(e) step \(k): non-finite. before: pos \(before.0) vel \(before.1) L \(before.2) w \(before.3)")
                    print("outputs \(outs)")
                    return 1
                }
            }
        }
        print("no NaN in \(eps) episodes"); return 0
    }
    struct SplitMix { var s: UInt64; init(seed: UInt64) { s = seed }
        mutating func next() -> Double { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; z ^= z >> 31; return Double(z >> 11) / Double(1 << 53) } }
}
