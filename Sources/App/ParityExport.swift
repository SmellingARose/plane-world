// Parity harness reference export for the C++ port (docs/PORT_PLAN.md, cpp/tests/parity/).
//   PlaneWorld --export-parity <dir>
// For every bundled craft plus examples/crafts/ducted-rocket.json, under each fast aero profile, two scenarios
// (ground: resting spawn; air: 300 m up at 40 m/s along +x) are run 3 s at 1 kHz (dt = 1 ms, one substep per step)
// with a fixed scripted output schedule (below), sampled every 10 ms. Also writes units.json (wing/prop/wake).
// Doubles are written as shortest round-trip decimals so the exact bits survive.
import Foundation
import PWCore
import PWPhysics
import PWCraft

enum ParityExport {
    /// Scripted command for output `i` of kind `kind` at time t (s). Deterministic, documented for the C++ side:
    ///   servo:        0.6·sin(2π(0.7+0.3i)t + 0.5i)
    ///   motor:        0 for t<0.2, then min(1,(t-0.2)/0.5)·(0.8 + 0.2·sin(3t))
    ///   jet:          0 for t<0.1, then 1
    ///   solid:        0 for t<0.5, then 1 (ignites)
    static func command(kind: OutputKind, index i: Int, t: Double) -> Double {
        switch kind {
        case .servo: return 0.6 * sin(2 * Double.pi * (0.7 + 0.3 * Double(i)) * t + 0.5 * Double(i))
        case .motor: return t < 0.2 ? 0 : min(1, (t - 0.2) / 0.5) * (0.8 + 0.2 * sin(3 * t))
        case .jet: return t < 0.1 ? 0 : 1
        case .solid: return t < 0.5 ? 0 : 1
        }
    }

    static func run(_ args: [String]) -> Int32 {
        guard let dir = TrainCLI.value(args, "--export-parity") else { print("usage: PlaneWorld --export-parity <dir>"); return 2 }
        let root = URL(fileURLWithPath: dir, isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: root.appendingPathComponent("trajectories"), withIntermediateDirectories: true)
        var docs = CraftLibrary.loadBundled(from: .module).map { ($0, "bundled") }
        let duct = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("examples/crafts/ducted-rocket.json")
        if let d = try? JSONIO.decode(CraftDocument.self, file: duct) { docs.append((d, "examples/crafts/ducted-rocket.json")) }
        else { print("error: \(duct.path) not found (run from the repo root)"); return 1 }
        let profiles = ["fast.classic", "fast.slipstream", "fast.plus"]
        var index: [String] = []
        func n(_ d: Double) -> String { ParityUnits.num(d) }
        for (raw, source) in docs {
            let craft = CraftOutputs.prepareForFlight(raw)
            // Craft input exactly as simulated, so the C++ loader starts from the same document.
            if let data = try? JSONIO.encode(craft) {
                try? data.write(to: root.appendingPathComponent("crafts/\(slug(craft.name)).json").creatingParent())
            }
            for pid in profiles {
                guard let prof = AeroProfiles.profile(pid) else { continue }
                let aero = prof.settings()
                for scenario in ["ground", "air"] {
                    let sim = CraftSim()
                    sim.fastToggles = aero.toggles; sim.slipstream = aero.toggles.slipstream
                    sim.turbulence = 0
                    do { try sim.load(craft) } catch { print("error: \(craft.name): \(error)"); return 1 }
                    let spawn = sim.restingSpawn()
                    if scenario == "air" {
                        sim.reset(spawn: Transform(position: spawn.position + Vec3d(0, 300, 0)))
                        sim.holdState(position: sim.position, orientation: sim.orientation, velocity: Vec3d(40, 0, 0))
                    } else { sim.reset(spawn: spawn) }
                    let env0 = SimEnvironment()
                    var rows: [String] = []
                    func sample() {
                        let p = sim.position, v = sim.velocity, q = sim.orientation, w = sim.angularVelocityWorld
                        let outs = sim.outputs.map { n($0.value) }.joined(separator: ",")
                        rows.append("[\(n(sim.time)),\(n(p.x)),\(n(p.y)),\(n(p.z)),\(n(v.x)),\(n(v.y)),\(n(v.z)),\(n(q.vector.x)),\(n(q.vector.y)),\(n(q.vector.z)),\(n(q.vector.w)),\(n(w.x)),\(n(w.y)),\(n(w.z)),[\(outs)]]")
                    }
                    sample()
                    let dt = 0.001
                    for k in 0..<3000 {
                        let t = Double(k) * dt
                        for (i, o) in sim.outputs.enumerated() { sim.setOutput(index: i, value: command(kind: o.kind, index: i, t: t)) }
                        var env = env0; env.time = t
                        sim.step(dt: dt, env: env)
                        if (k + 1) % 10 == 0 { sample() }
                    }
                    let outsMeta = sim.outputs.map { "{\"id\":\"\($0.id)\",\"name\":\"\(esc($0.name))\",\"kind\":\"\($0.kind)\"}" }.joined(separator: ",")
                    let json = """
                    {"schema":"planeworld.parity.trajectory/1","craft":"\(esc(craft.name))","craftFile":"crafts/\(slug(craft.name)).json","source":"\(source)",
                    "profile":"\(pid)","scenario":"\(scenario)","dt":0.001,"substepHz":\(n(sim.substepHz)),"steps":3000,"sampleEvery":10,"turbulence":0,
                    "spawn":{"position":[\(n(spawn.position.x)),\(n(scenario == "air" ? spawn.position.y + 300 : spawn.position.y)),\(n(spawn.position.z))],"velocity":[\(scenario == "air" ? "40,0,0" : "0,0,0")]},
                    "outputs":[\(outsMeta)],
                    "columns":["t","px","py","pz","vx","vy","vz","qx","qy","qz","qw","wx","wy","wz","outputs"],
                    "samples":[
                    \(rows.joined(separator: ",\n"))
                    ]}

                    """
                    let name = "\(slug(craft.name))__\(pid)__\(scenario).json"
                    do { try json.write(to: root.appendingPathComponent("trajectories/\(name)"), atomically: true, encoding: .utf8) }
                    catch { print("error: \(error)"); return 1 }
                    index.append("{\"file\":\"trajectories/\(name)\",\"craft\":\"\(esc(craft.name))\",\"profile\":\"\(pid)\",\"scenario\":\"\(scenario)\"}")
                    print("wrote \(name)  final pos (\(String(format: "%.3f, %.3f, %.3f", sim.position.x, sim.position.y, sim.position.z)))")
                }
            }
        }
        do {
            try ParityUnits.json().write(to: root.appendingPathComponent("units.json"), atomically: true, encoding: .utf8)
            try ("{\"schema\":\"planeworld.parity.index/1\",\"tolerance\":{\"relative\":1e-9},\"files\":[\n" + index.joined(separator: ",\n") + "]}\n")
                .write(to: root.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        } catch { print("error: \(error)"); return 1 }
        print("parity export: \(index.count) trajectories + units.json -> \(root.path)")
        return 0
    }
    static func slug(_ s: String) -> String { s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) } }
    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
}

private extension URL {
    func creatingParent() -> URL { try? FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true); return self }
}
