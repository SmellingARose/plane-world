// OWNED BY aero/physics builder. Headless physics self-tests (`PlaneWorld --selftest physics`).
import Foundation
import simd
import PWCore

/// Prototype presets rebuilt in Swift (identical part lists to reference/flightsim.html).
public enum PhysicsPresets {
    static func part(_ t: PartType, _ id: String, _ name: String, pos: Vec3d, rot: Vec3d = .zero, mass: Double? = nil,
                     p: [String: JSONValue] = [:], servo: String? = nil, motor: String? = nil, invert: Bool = false) -> CraftPart {
        var c = CraftPart(id: id, type: t, name: name, pos: pos, rotDeg: rot)
        if let mass { c.mass = mass }
        c.p.merge(p) { $1 }; c.servo = servo; c.motor = motor; c.invert = invert
        return c
    }
    static func n(_ d: [String: Double]) -> [String: JSONValue] { d.mapValues { .number($0) } }

    public static func trainer() -> CraftDocument {
        var axisZ = n(["range": 20, "torque": 400, "speed": 120]); axisZ["axis"] = .string("z")
        var axisY = n(["range": 25, "torque": 400, "speed": 120]); axisY["axis"] = .string("y")
        let wingP = n(["span": 4.2, "chord": 1.5, "camber": 0.25, "ar": 7]), ailP = n(["span": 1.5, "chord": 1.3, "camber": 0.25, "ar": 7])
        return CraftDocument(name: "Trainer", parts: [
            part(.servo, "ail", "Ailerons", pos: [0.4, 0.6, 0], p: axisZ),
            part(.servo, "elev", "Elevator", pos: [-3.6, 0.2, 0], p: axisZ),
            part(.servo, "rud", "Rudder", pos: [-3.6, 0.9, 0], p: axisY),
            part(.motor, "eng", "Engine", pos: [3.2, 0, 0], mass: 120, p: n(["torque": 300])),
            part(.box, "fus", "Fuselage", pos: [0, 0, 0], mass: 330, p: n(["sx": 6, "sy": 1.1, "sz": 1.1, "cd": 0.12])),
            part(.cone, "spin", "Spinner", pos: [3.55, 0, 0], rot: [0, 0, -90], mass: 2, p: n(["r": 0.3, "h": 0.4, "cd": 0.1])),
            part(.prop, "prop", "Propeller", pos: [3.7, 0, 0], p: n(["d": 1.9, "thrust": 2800, "vmax": 75]), motor: "eng"),
            part(.wing, "wl", "Wing L", pos: [0.4, 0.6, -2.6], rot: [0, 0, 2], mass: 45, p: wingP),
            part(.wing, "wr", "Wing R", pos: [0.4, 0.6, 2.6], rot: [0, 0, 2], mass: 45, p: wingP),
            part(.wing, "al", "Aileron L", pos: [0.4, 0.6, -5.45], rot: [0, 0, 2], mass: 6, p: ailP, servo: "ail"),
            part(.wing, "ar", "Aileron R", pos: [0.4, 0.6, 5.45], rot: [0, 0, 2], mass: 6, p: ailP, servo: "ail", invert: true),
            part(.wing, "stab", "Stabilator", pos: [-3.6, 0.2, 0], rot: [0, 0, -1.5], mass: 15, p: n(["span": 3.4, "chord": 1.0, "camber": 0, "ar": 4]), servo: "elev", invert: true),
            part(.wing, "fin", "Fin", pos: [-3.6, 0.95, 0], rot: [90, 0, 0], mass: 10, p: n(["span": 1.5, "chord": 1.1, "camber": 0, "ar": 2]), servo: "rud"),
            part(.wheel, "nw", "Nose wheel", pos: [2.2, -1.0, 0], p: n(["r": 0.25]), servo: "rud", invert: true),
            part(.wheel, "ml", "Main L", pos: [-0.2, -1.0, -1.3]),
            part(.wheel, "mr", "Main R", pos: [-0.2, -1.0, 1.3]),
        ])
    }

    public static func rover() -> CraftDocument {
        var st = n(["range": 30, "torque": 200, "speed": 60]); st["axis"] = .string("y")
        var parts = [
            part(.motor, "drive", "Drive", pos: [0, 0, 0], mass: 30, p: n(["torque": 180, "reversible": 1])),
            part(.servo, "steer", "Steering", pos: [0.9, 0, 0], p: st),
            part(.box, "chassis", "Chassis", pos: [0, 0.1, 0], mass: 150, p: n(["sx": 2.4, "sy": 0.4, "sz": 1.3, "cd": 0.6])),
        ]
        for (i, (x, z)) in [(0.9, -0.85), (0.9, 0.85), (-0.9, -0.85), (-0.9, 0.85)].enumerated() {
            parts.append(part(.wheel, "w\(i)", (x > 0 ? "Front " : "Rear ") + (z < 0 ? "L" : "R"), pos: [x, -0.15, z],
                              p: n(["r": 0.35, "width": 0.2, "grip": 1.0]), servo: x > 0 ? "steer" : nil, motor: "drive", invert: true))
        }
        return CraftDocument(name: "Rover", parts: parts)
    }

    /// three.js Euler 'XYZ' (degrees) from an orthonormal basis (columns x, y, z).
    static func rotFromBasis(_ x: Vec3d, _ y: Vec3d, _ z: Vec3d) -> Vec3d {
        let m13 = z.x, m23 = z.y, m33 = z.z, m12 = y.x, m11 = x.x, m32 = y.z, m22 = y.y
        let ry = asin(clamp(m13, -1, 1))
        let rx: Double, rz: Double
        if abs(m13) < 0.9999999 { rx = atan2(-m23, m33); rz = atan2(-m12, m11) } else { rx = atan2(m32, m22); rz = 0 }
        return Vec3d(rx, ry, rz) / kDeg
    }

    public static func rocket() -> CraftDocument {
        let up: Vec3d = [0, 1, 0]
        var parts = [
            part(.cylinder, "body", "Body tube", pos: [0, 1.7, 0], mass: 6, p: n(["r": 0.12, "h": 3, "cd": 0.15])),
            part(.cone, "nose", "Nose cone", pos: [0, 3.5, 0], mass: 1.5, p: n(["r": 0.12, "h": 0.6, "cd": 0.1])),
            part(.solid, "boost", "Booster", pos: [0, 0.45, 0], rot: [0, 0, 90], p: n(["thrust": 700, "burn": 5, "fuel": 10, "r": 0.1, "len": 0.9])),
        ]
        for (i, (dx, dz)) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1)].enumerated() {
            let span = Vec3d(dx, 0, dz)
            parts.append(part(.wing, "fin\(i)", "Fin", pos: [dx * 0.3, 0.35, dz * 0.3], rot: rotFromBasis(up, -simd_cross(span, up), span), mass: 0.5,
                              p: n(["span": 0.3, "chord": 0.5, "thick": 0.02, "camber": 0, "ar": 1.2])))
        }
        return CraftDocument(name: "Sounding rocket", parts: parts)
    }
}

public enum PhysicsSelfTests {
    public static func register() {
        SelfTestRegistry.register("physics", "trainer-takeoff-climb") { ctx in
            let sim = CraftSim()
            try sim.load(PhysicsPresets.trainer())
            sim.reset(spawn: sim.restingSpawn())
            let env = SimEnvironment()
            sim.setOutput(id: "eng", value: 1)
            let frame = 1.0 / 60
            var liftoffT = -1.0, t = 0.0, maxAlt = 0.0
            let y0 = sim.position.y
            let t0 = Date()
            while t < 60 {
                // simple pilot: pitch to 8° once above 30 m/s, wings level with ailerons
                let tel = sim.telemetry
                let target = tel.airspeed > 30 ? 8.0 : 0
                let pitchRate = simd_dot(sim.angularVelocityWorld, simd_normalize(simd_cross(sim.heading, [0, 1, 0]))) // + = nose up
                sim.setOutput(id: "elev", value: clamp(0.08 * (target - sim.pitchDeg) - 0.5 * pitchRate, -1, 1))
                let right = sim.orientation.act([0, 0, 1])
                sim.setOutput(id: "ail", value: clamp(1.5 * right.y, -1, 1))
                sim.step(dt: frame, env: env); t += frame
                if liftoffT < 0 && sim.position.y > y0 + 3 { liftoffT = t }
                maxAlt = max(maxAlt, sim.position.y)
                if ProcessInfo.processInfo.environment["PW_TRACE"] != nil && Int(t * 60) % 15 == 0 {
                    print(String(format: "t=%4.1f y=%6.1f ias=%5.1f pitch=%6.1f aoa=%5.1f elev=%5.2f thrust=%5.0f vy=%5.1f", t, sim.position.y, tel.airspeed, sim.pitchDeg, tel.angleOfAttackDeg, clamp(0.08 * (target - sim.pitchDeg) - 0.5 * pitchRate, -1, 1), tel.thrustN, sim.velocity.y))
                }
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            ctx.log(String(format: "liftoff t=%.1fs  alt(60s)=%.0f m  vs=%.1f m/s  ias=%.1f m/s  pitch=%.1f°  (60 s sim in %.0f ms, %.2f µs/substep)",
                           liftoffT, sim.position.y, sim.velocity.y, sim.telemetry.airspeed, sim.pitchDeg, ms, ms * 1000 / 60000))
            ctx.expect(liftoffT > 0 && liftoffT < 40, "trainer should lift off within 40 s (t=\(liftoffT))")
            ctx.expect(sim.position.y > 100, "trainer should have climbed above 100 m (alt \(sim.position.y))")
            ctx.expect(sim.velocity.y > 0.5, "trainer should still be climbing (vs \(sim.velocity.y))")
            ctx.expect(sim.position.y.isFinite && sim.telemetry.airspeed < 90, "sane state")
        }

        SelfTestRegistry.register("physics", "rover-straight-and-steer") { ctx in
            let sim = CraftSim()
            try sim.load(PhysicsPresets.rover())
            sim.reset(spawn: sim.restingSpawn())
            let env = SimEnvironment()
            for _ in 0..<60 { sim.step(dt: 1.0 / 60, env: env) }   // settle
            let p0 = sim.position
            sim.setOutput(id: "drive", value: 1)
            for _ in 0..<(8 * 60) { sim.step(dt: 1.0 / 60, env: env) }
            let d = sim.position - p0
            let headingErr = atan2(sim.heading.z, sim.heading.x) / kDeg
            ctx.log(String(format: "straight: dx=%.1f m dz=%.2f m speed=%.1f m/s heading err=%.2f°", d.x, d.z, simd_length(sim.velocity), headingErr))
            ctx.expect(d.x > 20, "rover should drive forward > 20 m (\(d.x))")
            ctx.expect(abs(d.z) < 0.5 && abs(headingErr) < 2, "rover should drive straight (dz \(d.z), heading \(headingErr)°)")
            // steer right (+1 = right per prototype: front wheels inverted, servo axis y)
            sim.setOutput(id: "steer", value: 1)
            let h0 = atan2(sim.heading.z, sim.heading.x)
            for _ in 0..<(3 * 60) { sim.step(dt: 1.0 / 60, env: env) }
            let dh = (atan2(sim.heading.z, sim.heading.x) - h0) / kDeg
            ctx.log(String(format: "steer +1 for 3 s: heading change %.1f° toward +Z (right)", dh))
            ctx.expect(dh > 20, "rover should turn toward +Z (right) when steering +1 (Δheading \(dh)°)")
            sim.setOutput(id: "steer", value: -1)
            let h1 = atan2(sim.heading.z, sim.heading.x)
            for _ in 0..<(4 * 60) { sim.step(dt: 1.0 / 60, env: env) }
            let dh2 = (atan2(sim.heading.z, sim.heading.x) - h1) / kDeg
            ctx.log(String(format: "steer -1 for 4 s: heading change %.1f°", dh2))
            ctx.expect(dh2 < -20, "rover should turn left when steering -1 (\(dh2)°)")
            ctx.expect(sim.orientation.act([0, 1, 0]).y > 0.9, "rover stays upright")
        }

        SelfTestRegistry.register("physics", "rocket-500m") { ctx in
            let sim = CraftSim()
            try sim.load(PhysicsPresets.rocket())
            sim.reset(spawn: sim.restingSpawn())
            let env = SimEnvironment()
            sim.setOutput(id: "boost", value: 1)
            var apogee = 0.0, t = 0.0, maxV = 0.0
            while t < 40 { sim.step(dt: 1.0 / 60, env: env); t += 1.0 / 60; apogee = max(apogee, sim.position.y); maxV = max(maxV, simd_length(sim.velocity)) }
            ctx.log(String(format: "apogee %.0f m, max speed %.0f m/s, fuel left %.2f kg, horizontal drift %.0f m", apogee, maxV, sim.telemetry.fuelKg,
                           simd_length(Vec2d(sim.position.x, sim.position.z))))
            ctx.expect(apogee > 500, "rocket apogee should exceed 500 m (\(apogee))")
            ctx.expect(sim.telemetry.fuelKg < 1e-6, "propellant burned out")
        }

        SelfTestRegistry.register("physics", "many-part-resting-stable") { ctx in
            // 40-plate deck (80 bottom corners touching): contact must not inject energy.
            var doc = CraftDocument(name: "deck", parts: [])
            for i in 0..<40 {
                doc.parts.append(PhysicsPresets.part(.box, "b\(i)", "plate\(i)", pos: [Double(i % 8) * 0.5, 0, Double(i / 8) * 0.5], mass: 5,
                                                     p: PhysicsPresets.n(["sx": 0.5, "sy": 0.1, "sz": 0.5])))
            }
            let sim = CraftSim(); sim.aeroEnabled = false
            try sim.load(doc)
            sim.reset(spawn: sim.restingSpawn())
            let env = SimEnvironment()
            for _ in 0..<30 { sim.step(dt: 1.0 / 60, env: env) }
            let E0 = sim.mechanicalEnergy()
            var maxY = -1e9, maxE = E0
            for _ in 0..<(10 * 60) { sim.step(dt: 1.0 / 60, env: env); maxY = max(maxY, sim.position.y); maxE = max(maxE, sim.mechanicalEnergy()) }
            ctx.log(String(format: "E0 %.1f J, max E %.1f J, max y %.3f m, final |v| %.4f", E0, maxE, maxY, simd_length(sim.velocity)))
            ctx.expect(maxY < 0.3, "deck must stay on the ground (max y \(maxY))")
            ctx.expect(maxE - E0 < 0.01 * sim.mass * 9.81 + 1, "mechanical energy must not grow (\(maxE - E0) J)")
        }

        SelfTestRegistry.register("physics", "vacuum-energy") { ctx in
            // asymmetric tumbling body with gravity, no aero/ground: E must be conserved within 0.1 % over 60 s
            var doc = PhysicsPresets.trainer()
            doc.parts.removeAll { $0.partType == .servo || $0.partType == .motor }
            let sim = CraftSim(); sim.aeroEnabled = false; sim.groundEnabled = false
            try sim.load(doc)
            sim.reset(spawn: Transform(position: [0, 20000, 0], rotation: Quatd(angle: 0.3, axis: simd_normalize([1, 2, 3]))))
            sim.setVelocity(linear: [60, 40, -10], angular: [0.9, 2.5, -1.3])
            let env = SimEnvironment()
            let E0 = sim.mechanicalEnergy(), L0 = sim.angularMomentum
            let KE0 = 0.5 * sim.mass * simd_length_squared(sim.velocity) + 0.5 * simd_dot(sim.angularVelocityWorld, sim.angularMomentum)
            let RE0 = 0.5 * simd_dot(sim.angularVelocityWorld, sim.angularMomentum)
            for _ in 0..<(60 * 60) { sim.step(dt: 1.0 / 60, env: env) }
            let E1 = sim.mechanicalEnergy()
            let RE1 = 0.5 * simd_dot(sim.angularVelocityWorld, sim.angularMomentum)
            let rel = abs(E1 - E0) / KE0, relR = abs(RE1 - RE0) / RE0
            ctx.log(String(format: "ΔE/KE0 = %.2e, Δ(rot KE)/rotKE0 = %.2e, |ΔL| = %.2e", rel, relR, simd_length(sim.angularMomentum - L0)))
            ctx.expect(rel < 1e-3, "total energy conserved within 0.1% (\(rel))")
            ctx.expect(relR < 1e-3, "rotational energy conserved within 0.1% (\(relR))")
        }

        SelfTestRegistry.register("physics", "aero-coefficients") { ctx in
            let p = Aero.WingParams(aspectRatio: 7, camberCl0: 0.25, thicknessRatio: 0.12)
            let a0 = Aero.wing(alpha: 0, mach: 0, reynolds: 3e6, params: p, flapDeflection: 0)
            let a5 = Aero.wing(alpha: 5 * kDeg, mach: 0.1, reynolds: 3e6, params: p, flapDeflection: 0)
            let a30 = Aero.wing(alpha: 30 * kDeg, mach: 0.1, reynolds: 3e6, params: p, flapDeflection: 0)
            let a5m = Aero.wing(alpha: 5 * kDeg, mach: 0.7, reynolds: 3e6, params: p, flapDeflection: 0)
            let pf = Aero.WingParams(aspectRatio: 7, camberCl0: 0.25, thicknessRatio: 0.12, flapChordFraction: 0.3)
            let fl = Aero.wing(alpha: 5 * kDeg, mach: 0.1, reynolds: 3e6, params: pf, flapDeflection: 20 * kDeg)
            let ge = Aero.groundEffect(height: 0.5, span: 10)
            ctx.log(String(format: "Cl(0)=%.2f Cl(5)=%.2f Cl(5,M.7)=%.2f Cl(30)=%.2f stalled=%d CdFlap=%.3f ClFlap=%.2f GE φ=%.2f", a0.cl, a5.cl, a5m.cl, a30.cl, a30.stalled ? 1 : 0, fl.cd, fl.cl, ge.phi))
            ctx.expectClose(a0.cl, 0.25, tol: 1e-9, "Cl0 = camber")
            ctx.expect(a5.cl > 0.6 && a5.cl < 0.75, "finite-AR slope")
            ctx.expect(a5m.cl > a5.cl * 1.2, "Prandtl-Glauert increase")
            ctx.expect(a30.stalled && a30.cl < a5.cl * 2, "stall")
            ctx.expect(fl.cl > a5.cl + 0.3, "flap adds lift")
            ctx.expect(ge.phi < 0.5, "ground effect reduces induced drag")
            // propeller: static thrust reproduces rating, falls with speed
            let P = Propulsion.propPower(staticThrust: 2800, diameter: 1.9)
            let s = Propulsion.propThrust(power: P, diameter: 1.9, rho: 1.225, axialSpeed: 0, pitchSpeed: 75)
            let f = Propulsion.propThrust(power: P, diameter: 1.9, rho: 1.225, axialSpeed: 40, pitchSpeed: 75)
            ctx.log(String(format: "prop: P=%.0f kW, T(0)=%.0f N, T(40)=%.0f N, J(40)=%.2f", P / 1000, s.thrust, f.thrust, f.advanceRatio))
            ctx.expectClose(s.thrust, 2800, tol: 5, "static thrust matches rating")
            ctx.expect(f.thrust < s.thrust && f.thrust > 400, "thrust lapse with advance ratio")
        }

        SelfTestRegistry.register("physics", "panel-aero") { ctx in
            // 1 m cube via mesh panels: frontal drag coefficient should be ~1 (Newtonian Cp=1 front + base suction)
            let m = PanelMesh(soup: PanelMesh.boxSoup(center: .zero, size: [1, 1, 1]))
            m.updateShadows(flowDir: [-1, 0, 0])
            let ft = m.evaluate(range: 0..<m.count, toWorld: .identity, origin: .zero, com: .zero, linVel: [20, 0, 0], angVel: .zero,
                                wind: .zero, rho: 1.225, nu: 1.5e-5, speedOfSound: 340)
            let cd = -ft.force.x / (0.5 * 1.225 * 400 * 1)
            // two stacked cubes along the flow: the rear cube's front face must be shadowed
            let m2 = PanelMesh(soup: PanelMesh.boxSoup(center: [0, 0, 0], size: [1, 1, 1]) + PanelMesh.boxSoup(center: [-3, 0, 0], size: [1, 1, 1]))
            m2.updateShadows(flowDir: [-1, 0, 0])
            let ft2 = m2.evaluate(range: 0..<m2.count, toWorld: .identity, origin: .zero, com: .zero, linVel: [20, 0, 0], angVel: .zero,
                                  wind: .zero, rho: 1.225, nu: 1.5e-5, speedOfSound: 340)
            let cd2 = -ft2.force.x / (0.5 * 1.225 * 400 * 1)
            ctx.log(String(format: "cube Cd=%.2f, tandem cubes Cd=%.2f (shadowed %d panels)", cd, cd2, m2.shadowed.filter { $0 }.count))
            ctx.expect(cd > 0.9 && cd < 1.6, "cube drag coefficient plausible (\(cd))")
            ctx.expect(cd2 < 2 * cd * 0.8, "rear cube shadowed (\(cd2) vs \(cd))")
            ctx.expect(abs(ft.force.y) < 1e-6 && abs(ft.force.z) < 1e-6, "symmetric")
        }

        SelfTestRegistry.register("physics", "parallel-panels-match") { ctx in
            // Many-panel CAD-like body: parallel and serial evaluation agree; report timing
            var soup: [Vec3d] = []
            for i in 0..<400 { soup += PanelMesh.boxSoup(center: [Double(i % 20) * 0.3, Double(i / 20) * 0.3, 0], size: [0.25, 0.25, 0.25]) }
            var doc = CraftDocument(name: "cad", parts: [CraftPart(id: "c", type: .cad, name: "Body")])
            doc.parts[0].mass = 100
            let a = CraftSim(); a.groundEnabled = false; try a.load(doc); a.setPartMesh(partID: "c", soup: soup)
            let b = CraftSim(); b.groundEnabled = false; b.parallelThreshold = .max; try b.load(doc); b.setPartMesh(partID: "c", soup: soup)
            for s in [a, b] { s.reset(spawn: Transform(position: [0, 1000, 0])); s.setVelocity(linear: [50, 0, 5], angular: [0.1, 0.2, 0]) }
            let env = SimEnvironment()
            let t0 = Date(); a.step(dt: 0.1, env: env); let tp = Date().timeIntervalSince(t0)
            let t1 = Date(); b.step(dt: 0.1, env: env); let ts = Date().timeIntervalSince(t1)
            let err = simd_length(a.velocity - b.velocity) + simd_length(a.angularVelocityWorld - b.angularVelocityWorld)
            ctx.log(String(format: "%d panels: parallel %.2f ms/substep, serial %.2f ms/substep, speedup %.1fx, diff %.1e", soup.count / 3, tp * 10, ts * 10, ts / tp, err))
            ctx.expect(err < 1e-6, "parallel matches serial")
        }
    }
}
