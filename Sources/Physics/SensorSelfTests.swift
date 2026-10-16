// OWNED BY architect (evolution feature). Group "physics", names "sensors-*".
import Foundation
import simd
import PWCore

public enum SensorSelfTests {
    static func withSensors(_ kinds: [(String, String, [String: JSONValue])]) -> CraftDocument {
        var c = PhysicsPresets.trainer()
        for (name, kind, extra) in kinds {
            var p = CraftPart(id: "s-" + name, type: .sensor, name: name)
            p.p["kind"] = .string(kind); for (k, v) in extra { p.p[k] = v }
            c.parts.append(p)
        }
        return c
    }

    public static func register() {
        SelfTestRegistry.register("physics", "sensors-inputs-list") { ctx in
            let c = withSensors([("alt", "altitudeAGL", [:]), ("att", "attitude", [:]), ("att", "airspeed", [:])])
            let ins = CraftInputs.list(c)
            ctx.expect(ins.map(\.name) == ["alt", "att.pitch", "att.roll", "att.yaw", "att"], "names: \(ins.map(\.name))")
            let sim = CraftSim(); try sim.load(c)
            ctx.expect(sim.inputs.map(\.name) == ins.map(\.name), "sim inputs == document inputs")
            // JSON compatibility: sensor round-trips, docs without sensors are unchanged
            let d = try JSONIO.encode(c), c2 = try JSONIO.decode(CraftDocument.self, from: d)
            ctx.expect(c2 == c && c2.parts.last?.partType == .sensor, "sensor part round-trips")
            let t = PhysicsPresets.trainer()
            let t2 = try JSONIO.decode(CraftDocument.self, from: try JSONIO.encode(t))
            ctx.expect(t2 == t && CraftInputs.list(t).isEmpty, "no-sensor craft unchanged")
            let plain = CraftSim(); try plain.load(t)
            ctx.expect(sim.outputs.map(\.id) == plain.outputs.map(\.id), "sensors add no outputs")
            let dup = CraftInputs.list(withSensors([("a", "airspeed", [:]), ("a", "airspeed", [:])])).map(\.name)
            ctx.expect(dup == ["a", "a#2"], "duplicate names disambiguated: \(dup)")
        }

        SelfTestRegistry.register("physics", "sensors-values") { ctx in
            let c = withSensors([("alt", "altitudeAGL", [:]), ("msl", "altitudeMSL", [:]), ("att", "attitude", [:]), ("air", "airspeed", [:]),
                                 ("vs", "verticalSpeed", [:]), ("ray", "raycast", ["dir": .string("down"), "range": .number(500)]),
                                 ("tgt", "target", ["tx": .number(100), "ty": .number(0), "tz": .number(0)]),
                                 ("touch", "contact", [:]), ("rate", "angularRate", [:]), ("svo", "servoAngle", ["ref": .string("elev")])])
            let sim = CraftSim(); try sim.load(c)
            let env = SimEnvironment()
            for _ in 0..<120 { sim.step(dt: 1.0 / 60, env: env) }          // settle on the ground
            func v(_ n: String) -> Double { sim.updateInputValues(env: env); return sim.inputs.first { $0.name == n }!.value }
            let originY = sim.originTransform.position.y
            ctx.expectClose(v("alt"), originY, tol: 0.05, "AGL at origin on flat ground")
            ctx.expectClose(v("ray"), originY, tol: 0.05, "raycast down == AGL")
            ctx.expect(abs(v("att.roll")) < 1 && abs(v("att.pitch")) < 5, "level on ground (pitch \(v("att.pitch")))")
            ctx.expect(v("touch.ground") == 1 && v("touch.crashed") == 0, "ground contact, not crashed")
            ctx.expectClose(v("tgt.bearing"), 0, tol: 2, "target straight ahead"); ctx.expectClose(v("tgt.distance"), 100, tol: 2, "target distance")
            // in flight, heading +Z (yaw 90), 40 m/s
            sim.reset(spawn: Transform(position: [0, 300, 0], rotation: Quatd(angle: -.pi / 2, axis: [0, 1, 0])))
            sim.setVelocity(linear: [0, 0, 40], angular: [0, 0, 0])
            ctx.expectClose(v("att.yaw"), 90, tol: 0.5, "heading +Z = 90°")
            ctx.expectClose(v("air"), 40, tol: 0.5, "airspeed")
            ctx.expectClose(v("msl"), 300, tol: 0.5, "MSL altitude")
            ctx.expectClose(v("tgt.bearing"), -90, tol: 1, "target at +X is 90° left when heading +Z")
            sim.setOutput(id: "elev", value: 1)
            for _ in 0..<30 { sim.step(dt: 1.0 / 60, env: env) }
            ctx.expect(v("svo") > 0.5, "servo feedback follows command (\(v("svo")))")
            ctx.expect(v("touch.ground") == 0, "no contact in the air")
            // crash detection: drop flat from 30 m
            sim.reset(spawn: Transform(position: [0, 30, 0])); sim.setVelocity(linear: [0, -25, 0], angular: .zero)
            for _ in 0..<120 { sim.step(dt: 1.0 / 60, env: env) }
            ctx.expect(sim.crashed && v("touch.crashed") == 1, "hard impact latches crashed (impact \(sim.maxImpactSpeed) m/s)")
            sim.reset(spawn: sim.restingSpawn()); ctx.expect(!sim.crashed, "reset clears crash")
            // clone independence
            let k = sim.clone(); k.setVelocity(linear: [5, 0, 0], angular: .zero); k.step(dt: 0.1, env: env)
            ctx.expect(simd_length(sim.velocity) < 1e-9, "clone does not share state")
        }
    }
}
