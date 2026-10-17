// OWNED BY physics (fast-model) builder. Self-tests for the new fast-model effects (FastGaps.swift) and the
// equation capture. Registered from PhysicsSelfTests.register().
import Foundation
import simd
import PWCore

enum FastGapsSelfTests {
    typealias Pt = PhysicsPresets
    static let zeroG = SimEnvironment(gravity: .zero)

    /// Run one 1 ms substep on two otherwise identical sims and return the angular-momentum change difference (on − off).
    static func deltaL(_ make: () throws -> CraftSim, configure: (CraftSim, Bool) -> Void, env: SimEnvironment = zeroG) rethrows -> (Vec3d, CraftSim) {
        var dL = [Vec3d](), last: CraftSim? = nil
        for on in [true, false] {
            let s = try make(); configure(s, on)
            let L0 = s.angularMomentum
            s.step(dt: 0.001, env: env)
            dL.append(s.angularMomentum - L0); if on { last = s }
        }
        return (dL[0] - dL[1], last!)
    }

    static func register() {
        SelfTestRegistry.register("physics", "gyro-precession") { ctx in
            // Prop spinning about +x (h = I·Ω x̂) under a pitch rate q ẑ: τ = −ω × h = −qIΩ (ẑ × x̂) = −qIΩ ŷ (yaw).
            func make() throws -> CraftSim {
                let s = CraftSim(); s.groundEnabled = false; s.aeroEnabled = false
                try s.load(CraftDocument(name: "gyro", parts: [
                    Pt.part(.box, "b", "Body", pos: [0, 0, 0], mass: 10, p: Pt.n(["sx": 1, "sy": 1, "sz": 1])),
                    Pt.part(.prop, "p", "Prop", pos: [0.6, 0, 0], mass: 2, p: Pt.n(["d": 1.0, "thrust": 50, "vmax": 40])),
                ]))
                s.reset(spawn: Transform(position: [0, 500, 0]))
                return s
            }
            let q = 1.0, omega0 = 300.0
            let (d, s) = try deltaL(make) { s, on in
                s.fastToggles.gyro = on
                s.parts[1].omega = omega0
                s.setVelocity(linear: .zero, angular: [0, 0, q])
            }
            let I = s.parts[1].kIrot, omega = s.parts[1].omega   // Ω after the substep's spin-down (gyro uses it)
            let expect = Vec3d(0, -q * I * omega * 0.001, 0)
            ctx.log(String(format: "I_r %.4f kg·m², Ω %.1f rad/s, ΔL(on−off) = (%.3e, %.3e, %.3e), expected (0, %.3e, 0)", I, omega, d.x, d.y, d.z, expect.y))
            ctx.expect(d.y < 0, "pitch-up with a +x spinning rotor precesses about −y")
            ctx.expectClose(d.y, expect.y, tol: abs(expect.y) * 0.02, "precession torque magnitude q·I·Ω")
            ctx.expect(abs(d.x) + abs(d.z) < abs(expect.y) * 1e-3, "no torque along the spin or pitch axis")
            // Wheel: rolling forward (+x) spins about −axle; a yaw rate then produces a roll torque.
            let w = CraftSim(); w.groundEnabled = false; w.aeroEnabled = false
            try w.load(CraftDocument(name: "wheel", parts: [
                Pt.part(.box, "b", "Body", pos: [0, 0, 0], mass: 10, p: Pt.n(["sx": 1, "sy": 0.2, "sz": 1])),
                Pt.part(.wheel, "w", "Wheel", pos: [0, -0.4, 0], mass: 5, p: Pt.n(["r": 0.4, "width": 0.1])),
            ]))
            let (dw, _) = deltaL({ let s = CraftSim(); s.groundEnabled = false; s.aeroEnabled = false; try! s.load(w.craft!); s.reset(spawn: Transform(position: [0, 500, 0])); return s }) { s, on in
                s.fastToggles.gyro = on; s.parts[1].omega = 50; s.setVelocity(linear: .zero, angular: [0, 1, 0])
            }
            // h = −I·Ω·ẑ, ω = ŷ: τ = −ŷ × (−IΩẑ) = IΩ (ŷ × ẑ) = +IΩ x̂
            ctx.log(String(format: "wheel: ΔL(on−off) = (%.3e, %.3e, %.3e)", dw.x, dw.y, dw.z))
            ctx.expect(dw.x > 0, "yawing a forward-rolling wheel gives a +x (roll) gyroscopic torque")
        }

        SelfTestRegistry.register("physics", "p-factor") { ctx in
            // Trainer (clockwise prop seen from the cockpit: spin +1 about +x), nose-up incidence: the descending blade
            // (right side, +z) carries more thrust, giving a yaw-left moment (+y), i.e. the classic left-turning tendency.
            func run(aoa: Double) throws -> (Vec3d, CraftSim) {
                try deltaL({ let s = CraftSim(); s.groundEnabled = false; try s.load(PhysicsPresets.trainer()); s.reset(spawn: Transform(position: [0, 1000, 0])); return s }) { s, on in
                    s.fastToggles.pFactor = on
                    let pi = s.parts.firstIndex { $0.type == .prop }!
                    s.parts[pi].omega = 310
                    s.setOutput(id: "eng", value: 1)
                    s.setVelocity(linear: Vec3d(cos(aoa * kDeg), -sin(aoa * kDeg), 0) * 30, angular: .zero)
                }
            }
            let (d15, s) = try run(aoa: 15), (d0, _) = try run(aoa: 0)
            let pi = s.parts.firstIndex { $0.type == .prop }!
            let T = s.parts[pi].thrustNow, R = s.parts[pi].kD / 2
            let vc = 30 * sin(15 * kDeg), mu = vc / (abs(s.parts[pi].omega) * R)
            let eM = min(0.3 * R, 0.5 * mu * R) * T          // offset moment e·T
            ctx.log(String(format: "AoA 15°: ΔL(on−off) = (%.4f, %.4f, %.4f) N·m·s per ms; AoA 0°: |ΔL| %.2e; T %.0f N, μ %.3f, e·T %.1f N·m",
                           d15.x, d15.y, d15.z, simd_length(d0), T, mu, eM))
            ctx.expect(d15.y > 0, "nose-up incidence yaws the nose left (+y moment) for a clockwise prop")
            ctx.expect(simd_length(d0) < 1e-3 * abs(d15.y), "no P-factor without incidence")
            // The moment about the CoM also contains the normal force N (in-plane, along the crossflow +y) acting at the
            // prop arm (prop is 3.7 m ahead: N·arm about +z), so compare the yaw axis only.
            ctx.expectClose(d15.y / 0.001, eM, tol: 0.1 * eM, "yaw moment = e·T")
            ctx.expect(d15.z > 0, "normal force ahead of the CoM pitches the nose up (destabilising, +z)")
        }

        SelfTestRegistry.register("physics", "wing-downwash") { ctx in
            // Split main wing (left + right halves, 0.1 m gap) and a tail 4 m behind. The halves must form one
            // horseshoe; the tail sees ε ≈ 2C_L/(πAR) (textbook); far downstream the horseshoe gives 16C_L/(π³AR).
            let wingP = Pt.n(["span": 3, "chord": 1, "camber": 0.2, "ar": 6])
            let doc = CraftDocument(name: "dw", parts: [
                Pt.part(.box, "f", "Fuselage", pos: [-1.5, 0, 0], mass: 100, p: Pt.n(["sx": 5, "sy": 0.4, "sz": 0.4, "cd": 0.1])),
                Pt.part(.wing, "wl", "Wing L", pos: [0, 0, -1.55], mass: 10, p: wingP),
                Pt.part(.wing, "wr", "Wing R", pos: [0, 0, 1.55], mass: 10, p: wingP),
                Pt.part(.wing, "t", "Tail", pos: [-4, 0, 0], mass: 3, p: Pt.n(["span": 2, "chord": 0.6, "camber": 0, "ar": 3.3])),
            ])
            func make(_ on: Bool) throws -> CraftSim {
                let s = CraftSim(); s.groundEnabled = false; s.fastToggles.downwash = on
                try s.load(doc); s.reset(spawn: Transform(position: [0, 1000, 0]))
                s.setVelocity(linear: Vec3d(cos(5 * kDeg), -sin(5 * kDeg), 0) * 40, angular: .zero)
                return s
            }
            let s = try make(true), off = try make(false)
            let gW = s.wingGroupIndex(partID: "wl"), gT = s.wingGroupIndex(partID: "t")
            ctx.expect(gW >= 0 && gW == s.wingGroupIndex(partID: "wr") && gT != gW && s.wingGroupCount == 2, "split wing halves share one horseshoe group")
            s.step(dt: 0.001, env: zeroG); off.step(dt: 0.001, env: zeroG)
            s.step(dt: 0.001, env: zeroG); off.step(dt: 0.001, env: zeroG)
            let G = s.wingGroups[gW], st = s.groupState[gW]
            let V = simd_length(st.air), rho = Atmosphere.isa(altitude: s.position.y).density
            let CL = simd_length(st.lift) / (0.5 * rho * V * V * G.area), AR = G.span * G.span / G.area
            let o = s.originTransform
            let tailQC = o.position + o.rotation.act(Vec3d(-4 + 0.25 * 0.6, 0, 0))
            let lh = st.lift / simd_length(st.lift)
            func eps(_ p: Vec3d) -> Double { atan2(-simd_dot(s.downwashVelocity(at: p, excludeGroup: gT), lh), V) }
            let eTail = eps(tailQC), eText = 2 * CL / (Double.pi * AR)
            let c = o.position + o.rotation.act(G.center), far = c + st.air / V * 200
            let eFar = eps(far), eFarHS = 16 * CL / (pow(Double.pi, 3) * AR)
            // tail lift with and without downwash (strip results of the tail part)
            func tailLift(_ x: CraftSim) -> Double { var L = 0.0; for k in 0..<x.strips.count where x.strips[k].part == 3 { L += simd_dot(x.stripBuf![k].lift, lh) }; return L }
            let Lon = tailLift(s), Loff = tailLift(off)
            ctx.log(String(format: "C_L %.3f, AR %.2f, ε tail %.2f° (2C_L/πAR = %.2f°, ratio %.2f), ε far %.2f° (horseshoe 16C_L/π³AR = %.2f°), tail lift %.1f N vs %.1f N without",
                           CL, AR, eTail / kDeg, eText / kDeg, eTail / eText, eFar / kDeg, eFarHS / kDeg, Lon, Loff))
            ctx.expect(eTail > 0.5 * eText && eTail < 1.2 * eText, "tail downwash angle ≈ 2C_L/(πAR)")
            ctx.expectClose(eFar, eFarHS, tol: 0.05 * eFarHS, "far-field horseshoe downwash 16C_L/(π³AR)")
            ctx.expect(Lon < Loff - 1, "downwash reduces tail lift")
            // ahead of the wing: upwash
            let ahead = c - st.air / V * 3
            ctx.expect(eps(ahead) < 0, "upwash ahead of the bound vortex")
        }

        SelfTestRegistry.register("physics", "wake-blockage") { ctx in
            // Prop at x = 1 blowing toward −x, a 0.4 m box in the wake at x = −0.5: behind it the wake is attenuated,
            // beside the shadow it is not. Coaxial counter-rotating pair: the lower rotor takes over the upper swirl.
            let doc = CraftDocument(name: "blk", parts: [
                Pt.part(.box, "b", "Block", pos: [-0.5, 0, 0], mass: 10, p: Pt.n(["sx": 0.4, "sy": 0.4, "sz": 0.4])),
                Pt.part(.prop, "p", "Prop", pos: [1, 0, 0], mass: 1, p: Pt.n(["d": 1.2, "thrust": 200, "vmax": 40])),
            ])
            func wakeAt(_ on: Bool, _ pts: [Vec3d]) throws -> [Vec3d] {
                let s = CraftSim(); s.groundEnabled = false; s.fastToggles.blockage = on
                try s.load(doc); s.reset(spawn: Transform(position: [0, 1000, 0]))
                for o in s.outputs { s.setOutput(id: o.id, value: 1) }
                for _ in 0..<500 { s.step(dt: 0.001, env: zeroG); s.setVelocity(linear: .zero, angular: .zero) }
                let o = s.originTransform
                return pts.map { WakeView(buf: UnsafePointer(s.wakeBuf), count: s.wakeCount).velocity(at: o.position + o.rotation.act($0)) }
            }
            let pts: [Vec3d] = [[-1.0, 0, 0], [-3.0, 0, 0], [-1.0, 0.45, 0]]
            let on = try wakeAt(true, pts), off = try wakeAt(false, pts)
            let r = (0..<3).map { simd_length(on[$0]) / max(simd_length(off[$0]), 1e-9) }
            ctx.log(String(format: "wake |v| behind block: %.2f vs %.2f m/s (×%.2f); 2.5 m behind: ×%.2f; beside shadow: ×%.2f",
                           simd_length(on[0]), simd_length(off[0]), r[0], r[1], r[2]))
            ctx.expect(r[0] < 0.5, "wake right behind a body is strongly attenuated")
            ctx.expect(r[1] > r[0], "wake recovers downstream by mixing")
            ctx.expect(abs(r[2] - 1) < 1e-9, "wake outside the body shadow unchanged")
            // coaxial swirl recovery
            let coax = CraftDocument(name: "coax", parts: [
                Pt.part(.motor, "m", "Lift", pos: [0, 1, 0], mass: 3, p: Pt.n(["torque": 20])),
                Pt.part(.cylinder, "b", "Body", pos: [0, 1.6, 0], mass: 10, p: Pt.n(["r": 0.1, "h": 0.4, "cd": 0.3])),
                Pt.part(.prop, "a", "A", pos: [0, 0.8, 0], rot: [0, 0, 90], mass: 0.4, p: Pt.n(["d": 0.55, "thrust": 120, "vmax": 40, "spin": 1]), motor: "m"),
                Pt.part(.prop, "c", "B", pos: [0, 1.2, 0], rot: [0, 0, 90], mass: 0.4, p: Pt.n(["d": 0.55, "thrust": 120, "vmax": 40, "spin": -1]), motor: "m"),
            ])
            func swirlBelow(_ on: Bool) throws -> Double {
                let s = CraftSim(); s.groundEnabled = false; s.fastToggles.blockage = on
                try s.load(coax); s.reset(spawn: Transform(position: [0, 1000, 0])); s.setOutput(id: "m", value: 1)
                for _ in 0..<800 { s.step(dt: 0.001, env: zeroG); s.setVelocity(linear: .zero, angular: .zero) }
                let o = s.originTransform, p = o.position + o.rotation.act(Vec3d(0.15, 0.4, 0))
                let v = WakeView(buf: UnsafePointer(s.wakeBuf), count: s.wakeCount).velocity(at: p)
                return v.z    // tangential at +x offset about the y axis
            }
            let sOn = try swirlBelow(true), sOff = try swirlBelow(false)
            ctx.log(String(format: "coaxial counter-rotating: swirl below the pair %.3f m/s (recovery on) vs %.3f m/s (off)", sOn, sOff))
            ctx.expect(abs(sOn) < 0.25 * abs(sOff), "counter-rotating lower rotor cancels the upper rotor's swirl")
        }

        SelfTestRegistry.register("physics", "cad-wash") { ctx in
            // CAD cube 1.5 m behind a prop, craft at rest: without per-panel wash the panels see still air (no force);
            // with it they feel the slipstream drag toward −x.
            var doc = CraftDocument(name: "cw", parts: [
                Pt.part(.box, "b", "Hub", pos: [1.3, 0, 0], mass: 10, p: Pt.n(["sx": 0.1, "sy": 0.1, "sz": 0.1])),
                Pt.part(.prop, "p", "Prop", pos: [1, 0, 0], mass: 1, p: Pt.n(["d": 1.2, "thrust": 200, "vmax": 40])),
                Pt.part(.cad, "cad", "Pod", pos: [-0.5, 0, 0], mass: 5),
            ])
            doc.parts[0].mass = 10
            let soup = PanelMesh.boxSoup(center: .zero, size: [0.4, 0.4, 0.4])
            func force(_ on: Bool) throws -> (Vec3d, Double) {
                let s = CraftSim(); s.groundEnabled = false; s.fastToggles.cadWash = on
                try s.load(doc); s.setPartMesh(partID: "cad", soup: soup); s.reset(spawn: Transform(position: [0, 1000, 0]))
                for o in s.outputs { s.setOutput(id: o.id, value: 1) }
                for _ in 0..<500 { s.step(dt: 0.001, env: zeroG); s.setVelocity(linear: .zero, angular: .zero) }
                let ci = s.parts.firstIndex { $0.doc.id == "cad" }!
                let o = s.originTransform
                let vw = WakeView(buf: UnsafePointer(s.wakeBuf), count: s.wakeCount).velocity(at: o.position + o.rotation.act(Vec3d(-0.5, 0, 0)))
                return (s.panels.out[s.parts[ci].itemStart].force, simd_length(vw))
            }
            let (fOn, vw) = try force(true), (fOff, _) = try force(false)
            let cdEq = simd_length(fOn) / (0.5 * 1.112 * vw * vw * 0.16)
            ctx.log(String(format: "CAD pod in wash (%.1f m/s at centre): F = (%.2f, %.2f, %.2f) N with cadWash, |F| %.2e N without; C_D(eq.) ≈ %.2f",
                           vw, fOn.x, fOn.y, fOn.z, simd_length(fOff), cdEq))
            ctx.expect(fOn.x < -1, "panels in the slipstream are pushed downstream")
            ctx.expect(simd_length(fOff) < 1e-9, "without cadWash the panels see still air")
        }

        SelfTestRegistry.register("physics", "equation-capture") { ctx in
            let s = CraftSim(); s.groundEnabled = false
            try s.load(PhysicsPresets.trainer()); s.reset(spawn: Transform(position: [0, 800, 0]))
            s.setVelocity(linear: Vec3d(cos(8 * kDeg), -sin(8 * kDeg), 0) * 35, angular: [0, 0, 0.2])
            s.setOutput(id: "eng", value: 1)
            s.step(dt: 0.1, env: SimEnvironment())
            let cap = EquationCapture(); s.equationCapture = cap
            let before = PhysicsSelfTests.stateBits(s)
            cap.request()
            s.step(dt: 0.001, env: SimEnvironment())
            ctx.expect(cap.ready && !cap.requested, "capture fulfilled on the next substep")
            var seen = Set<UInt16>()
            var liftOK = true
            for k in 0..<cap.count {
                let r = cap.records[k]; seen.insert(r.id.rawValue)
                if r.id == .wingLift {
                    let L = 0.5 * r.value(3) * r.value(4) * r.value(4) * r.value(5) * r.value(6)
                    if abs(L - r.value(7)) > 1e-9 * max(1, L) { liftOK = false }
                }
                if r.id == .propMomentum {
                    let lhs = r.value(6) * (r.value(2) + r.value(3)), rhs = r.value(0) * r.value(1)
                    ctx.log(String(format: "prop: T(V+v_i) = %.0f W vs ηP = %.0f W (fixed-pitch unloading lowers T)", lhs, rhs))
                    ctx.expect(lhs <= rhs * 1.001, "T(V+v_i) ≤ ηP")
                }
            }
            let names = EquationID.allCases.filter { seen.contains($0.rawValue) }.map { "\($0)" }
            ctx.log("\(cap.count) records: " + names.joined(separator: ", "))
            for id in [EquationID.wingLift, .wingDrag, .wingMoment, .propMomentum, .propTorque, .slipstreamVelocity, .rotorGroundEffect,
                       .gyroscopic, .pFactor, .downwash, .blockage, .bodyDrag] {
                ctx.expect(seen.contains(id.rawValue), "captured \(id)")
            }
            ctx.expect(liftOK, "wingLift record satisfies L = ½ρV²S·C_L")
            for id in EquationID.allCases where id != .none {
                ctx.expect(!EquationCatalog.info(id).formula.contains("TODO") && !EquationCatalog.info(id).formula.isEmpty, "catalog entry for \(id)")
            }
            // capture must not perturb the trajectory: compare with an identical sim that never captures
            let t = CraftSim(); t.groundEnabled = false
            try t.load(PhysicsPresets.trainer()); t.reset(spawn: Transform(position: [0, 800, 0]))
            t.setVelocity(linear: Vec3d(cos(8 * kDeg), -sin(8 * kDeg), 0) * 35, angular: [0, 0, 0.2]); t.setOutput(id: "eng", value: 1)
            t.step(dt: 0.1, env: SimEnvironment())
            ctx.expect(PhysicsSelfTests.stateBits(t) == before, "same state before capture")
            t.step(dt: 0.001, env: SimEnvironment())
            ctx.expect(PhysicsSelfTests.stateBits(t) == PhysicsSelfTests.stateBits(s), "capture leaves the trajectory bit-identical")
        }
    }
}

extension PhysicsSelfTests {
    static func stateBits(_ s: CraftSim) -> [UInt64] {
        [s.position.x, s.position.y, s.position.z, s.velocity.x, s.velocity.y, s.velocity.z,
         s.angularMomentum.x, s.angularMomentum.y, s.angularMomentum.z, s.orientation.vector.x, s.orientation.vector.w].map { $0.bitPattern }
    }
}
