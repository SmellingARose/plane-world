// OWNED BY aero/physics builder.
// Full craft simulation (conforms to CraftSimulation): 6-DOF rigid body in double precision with a full
// inertia tensor, integrated with a semi-implicit scheme at >= 1 kHz substeps (linear: symplectic Euler;
// angular: world angular momentum + midpoint exponential-map attitude update, so torque-free motion
// conserves |L| exactly and kinetic energy to O(h²)). Forces: spanwise-strip wing aero, bounding-box
// drag or mesh-panel aero (CAD), propellers, jets, solid rockets, gravity, penalty ground contacts,
// Pacejka-lite wheels with spring/damper suspension, buoyancy via WaterProvider, wind/turbulence.
import Foundation
import simd
import PWCore
import PWCollision

struct SimPart {
    var doc: CraftPart
    var type: PartType?
    var basePos: Vec3d, baseQ: Quatd, effQ: Quatd
    var size: Vec3d, ctr: Vec3d
    var fuel = 0.0, fuelCapacity = 0.0
    var servo: Int? = nil, motor: Int? = nil
    var out = 0.0                 // command (outputs)
    var angle = 0.0, load = 0.0, loadShown = 0.0, overload = false   // servo
    var spinAngle = 0.0, omega = 0.0      // wheel / prop rotation (visual + wheel DOF)
    var thrustNow = 0.0, burning = false, ignitedAt = 0.0, spool = 0.0
    var corners: [Vec3d] = []
    var mesh: PanelMesh? = nil
    var flapChord = 0.0
    var autoMotor = false         // unlinked wheel/prop: drives itself from its own synthesized output
    var compression = 0.0, contact = false
    var mass: Double { doc.mass + fuel }
    func p(_ k: String, _ d: Double = 0) -> Double { doc.param(k, d) }
}

/// One spanwise wing strip evaluated per substep (possibly in parallel).
struct WingStrip { var part: Int; var spanOffset: Double; var area: Double }
struct StripResult { var ft = ForceTorque.zero; var hinge = 0.0; var stalled = false; var bigStall = false }

public final class CraftSim: CraftSimulation {
    // configuration
    public var substepHz: Double = 1000
    public var aeroEnabled = true
    public var groundEnabled = true
    public var turbulence = 0.0
    public var stripsPerWing = 4
    /// Number of force items (strips + panels) above which evaluation goes parallel.
    public var parallelThreshold = 256

    public private(set) var craft: CraftDocument?
    public private(set) var outputs: [CraftOutput] = []
    public private(set) var telemetry = CraftTelemetry()
    var parts: [SimPart] = []
    var strips: [WingStrip] = []
    var outputTargets: [String: Int] = [:]    // output id -> part index

    // mass properties (craft frame)
    public private(set) var mass = 1.0
    public private(set) var comLocal = Vec3d.zero
    public private(set) var inertia = Mat3d(diagonal: [1, 1, 1])
    var inertiaInv = Mat3d(diagonal: [1, 1, 1])
    // state
    public private(set) var position = Vec3d.zero      // CoM, world
    public private(set) var orientation = Quatd.identity
    public private(set) var velocity = Vec3d.zero
    public private(set) var angularMomentum = Vec3d.zero  // world
    public private(set) var time = 0.0
    var stepCounter = 0
    var lastForce = Vec3d.zero
    var hull: HullMesh?
    var boundingRadius = 1.0
    var stripBuf: UnsafeMutablePointer<StripResult>?, stripCap = 0
    var panelBuf: UnsafeMutablePointer<ForceTorque>?, panelCap = 0

    public init() {}
    deinit { stripBuf?.deallocate(); panelBuf?.deallocate() }

    // MARK: load / outputs
    public func load(_ craft: CraftDocument) throws {
        self.craft = craft
        let idIndex = Dictionary(craft.parts.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        parts = craft.parts.map { d in
            let t = d.partType
            var sp = SimPart(doc: d, type: t, basePos: d.position, baseQ: d.rotation, effQ: d.rotation, size: .one, ctr: .zero)
            (sp.size, sp.ctr) = Self.bounds(d)
            sp.servo = d.servo.flatMap { idIndex[$0] }
            sp.motor = d.motor.flatMap { idIndex[$0] }
            if t == .wing {
                let named = d.name.lowercased().contains("flap")
                sp.flapChord = d.p["flap"]?.double ?? (named ? 0.3 : 0)
            }
            if t == .cad, let b = d.cad, let soup = PanelMesh.decodePrototypeCAD(b, scale: d.param("scale", 1)) {
                let m = PanelMesh(soup: soup); if m.count > 0 { sp.mesh = m }
            }
            if (t == .wheel || t == .prop) && sp.motor == nil { sp.autoMotor = true }
            if BODY_TYPES.contains(t ?? .box) || t == .wing {
                let h = sp.size * 0.5
                for sx in [-1.0, 1] { for sy in [-1.0, 1] { for sz in [-1.0, 1] { sp.corners.append(sp.ctr + Vec3d(sx, sy, sz) * h) } } }
            }
            return sp
        }
        // validate links point to the right kinds
        for i in parts.indices {
            if let s = parts[i].servo, parts[s].type != .servo { parts[i].servo = nil }
            if let m = parts[i].motor, parts[m].type != .motor { parts[i].motor = nil; if parts[i].type == .wheel || parts[i].type == .prop { parts[i].autoMotor = true } }
        }
        rebuildStrips()
        outputs = Self.makeOutputs(craft)
        outputTargets = [:]
        for (i, p) in parts.enumerated() {
            if p.type?.isOutput == true { outputTargets[p.doc.id] = i }
            if p.autoMotor {
                let id = "auto-motor:" + p.doc.id
                outputTargets[id] = i
                let info = p.type == .prop ? "auto motor · prop \(Int(p.p("thrust"))) N static" : "auto motor · \(Int(Self.autoWheelTorque)) N·m"
                outputs.append(CraftOutput(id: id, name: p.doc.name + " motor", kind: .motor, range: p.type == .wheel ? -1...1 : 0...1, info: info))
            }
        }
        buildHull()
        resetFuel()
        updateMassProperties(keepOrigin: false)
        reset(spawn: restingSpawn())
    }

    static let autoWheelTorque = 120.0
    static let BODY_TYPES_SET: Set<PartType> = [.box, .cylinder, .cone, .sphere, .cad, .tank, .jet, .solid, .motor]
    var BODY_TYPES: Set<PartType> { Self.BODY_TYPES_SET }

    /// Prototype output rules: every servo/motor/jet/solid part is an output (auto motors for unlinked wheels/props are appended at load).
    public static func makeOutputs(_ craft: CraftDocument) -> [CraftOutput] {
        craft.parts.compactMap { p -> CraftOutput? in
            guard let t = p.partType, t.isOutput else { return nil }
            let linked = craft.parts.filter { $0.servo == p.id || $0.motor == p.id }.count
            switch t {
            case .servo: return CraftOutput(id: p.id, name: p.name, kind: .servo, range: -1...1,
                                            info: "servo ±\(Int(p.param("range")))° · \(Int(p.param("torque"))) N·m · \(linked) linked")
            case .motor: let rev = p.param("reversible") != 0
                return CraftOutput(id: p.id, name: p.name, kind: .motor, range: rev ? -1...1 : 0...1, info: "motor \(Int(p.param("torque"))) N·m · \(linked) linked")
            case .jet: return CraftOutput(id: p.id, name: p.name, kind: .jet, range: 0...1, info: "jet \(Int(p.param("thrust"))) N")
            case .solid: return CraftOutput(id: p.id, name: p.name, kind: .solid, range: 0...1, info: "solid \(Int(p.param("thrust"))) N × \(p.param("burn"))s · ignites >50%")
            default: return nil
            }
        }
    }

    public func setOutput(id: String, value: Double) {
        guard let i = outputs.firstIndex(where: { $0.id == id }) else { return }
        let v = clamp(value, outputs[i].range.lowerBound, outputs[i].range.upperBound)
        outputs[i].value = v
        if let pi = outputTargets[id] { parts[pi].out = v }
    }

    /// Replace a CAD part's aero mesh (body-local triangle soup, part frame) — used by the Craft importer.
    public func setPartMesh(partID: String, soup: [Vec3d]) {
        guard let i = parts.firstIndex(where: { $0.doc.id == partID }) else { return }
        let m = PanelMesh(soup: soup); parts[i].mesh = m.count > 0 ? m : nil
        if let m = parts[i].mesh {
            var bb = AABB.empty; for c in m.tris { bb.expand(c.0); bb.expand(c.1); bb.expand(c.2) }
            parts[i].size = bb.max - bb.min; parts[i].ctr = bb.center
        }
        buildHull(); updateMassProperties(keepOrigin: true)
    }

    // MARK: geometry
    static func bounds(_ d: CraftPart) -> (Vec3d, Vec3d) {
        let p = { (k: String) in d.param(k) }
        switch d.partType {
        case .box: return (Vec3d(p("sx"), p("sy"), p("sz")), .zero)
        case .cylinder, .cone: return (Vec3d(2 * p("r"), p("h"), 2 * p("r")), .zero)
        case .sphere: return (Vec3d(repeating: 2 * p("r")), .zero)
        case .wing: return (Vec3d(p("chord"), p("thick"), p("span")), .zero)
        case .servo: return (Vec3d(0.14, 0.08, 0.08), .zero)
        case .wheel: return (Vec3d(2 * p("r"), 2 * p("r"), p("width")), .zero)
        case .motor: return (Vec3d(0.5, 0.5, 0.5), .zero)
        case .prop: return (Vec3d(0.06, p("d"), 0.14), .zero)
        case .jet, .tank, .solid: return (Vec3d(p("len"), 2 * p("r"), 2 * p("r")), .zero)
        case .cad:
            if let b = d.cad, let s = PanelMesh.decodePrototypeCAD(b, scale: d.param("scale", 1)), !s.isEmpty {
                var bb = AABB.empty; s.forEach { bb.expand($0) }; return (simd_max(bb.max - bb.min, Vec3d(repeating: 0.01)), bb.center)
            }
            return (Vec3d(repeating: 0.5), .zero)
        case nil: return (Vec3d(repeating: 0.2), .zero)
        }
    }

    func rebuildStrips() {
        strips = []
        for (i, p) in parts.enumerated() where p.type == .wing {
            let n = max(1, stripsPerWing), span = p.p("span"), chord = p.p("chord")
            for k in 0..<n {
                let off = -span / 2 + span * (Double(k) + 0.5) / Double(n)
                strips.append(WingStrip(part: i, spanOffset: off, area: span * chord / Double(n)))
            }
        }
    }

    func buildHull() {
        var soup: [Vec3d] = []
        var r = 0.5
        for p in parts {
            if let m = p.mesh { for t in m.tris { soup += [p.basePos + p.baseQ.act(t.0), p.basePos + p.baseQ.act(t.1), p.basePos + p.baseQ.act(t.2)] } }
            else if p.type != .prop && p.type != .servo { soup += PanelMesh.boxSoup(center: p.basePos + p.baseQ.act(p.ctr), size: p.size, rotation: p.baseQ) }
            r = max(r, simd_length(p.basePos) + simd_length(p.size) / 2)
        }
        boundingRadius = r
        hull = HullMesh(positions: soup.map { $0.float }, indices: (0..<UInt32(soup.count)).map { $0 })
    }

    func resetFuel() {
        for i in parts.indices {
            switch parts[i].type {
            case .tank: parts[i].fuelCapacity = parts[i].p("capacity"); parts[i].fuel = parts[i].fuelCapacity * clamp(parts[i].p("fill"), 0, 1)
            case .solid: parts[i].fuelCapacity = parts[i].p("fuel"); parts[i].fuel = parts[i].fuelCapacity; parts[i].burning = false
            default: break
            }
            parts[i].angle = 0; parts[i].spinAngle = 0; parts[i].omega = 0; parts[i].spool = 0; parts[i].load = 0
        }
    }

    /// Principal inertia of a part's shape (part frame) for mass m.
    static func shapeInertia(_ p: SimPart, mass m: Double) -> Vec3d {
        let s = p.size
        switch p.type {
        case .sphere: let r = s.x / 2; return Vec3d(repeating: 0.4 * m * r * r)
        case .cylinder, .cone:
            let r = s.x / 2, h = s.y, k = p.type == .cone ? 0.3 : 0.5
            let ia = k * m * r * r, it = m * (3 * r * r + h * h) / 12 * (p.type == .cone ? 0.8 : 1)
            return Vec3d(it, ia, it)
        case .wheel: let r = s.x / 2, w = s.z; return Vec3d(m * (3 * r * r + w * w) / 12, m * (3 * r * r + w * w) / 12, 0.5 * m * r * r)
        default: return Vec3d(m / 12 * (s.y * s.y + s.z * s.z), m / 12 * (s.x * s.x + s.z * s.z), m / 12 * (s.x * s.x + s.y * s.y))
        }
    }

    /// Recompute mass, CoM and inertia. Liquid/propellant is treated as a non-rotating point mass at the
    /// container centre (no slosh). keepOrigin keeps the craft origin fixed in the world when the CoM moves.
    func updateMassProperties(keepOrigin: Bool) {
        let oldOrigin = position - orientation.act(comLocal)
        let oldOmega = angularVelocityWorld
        var M = 0.0, com = Vec3d.zero
        for p in parts { let m = p.mass; M += m; com += (p.basePos + p.baseQ.act(p.ctr)) * m }
        M = max(M, 1e-3); com /= M
        var I = Mat3d(diagonal: [0, 0, 0])
        for p in parts {
            let R = Mat3d(p.baseQ)
            let D = Mat3d(diagonal: Self.shapeInertia(p, mass: p.doc.mass))
            I += R * D * R.transpose
            let d = p.basePos + p.baseQ.act(p.ctr) - com, m = p.mass
            I += (Mat3d(diagonal: Vec3d(repeating: simd_dot(d, d))) - Mat3d(columns: (d * d.x, d * d.y, d * d.z))) * m
        }
        I += Mat3d(diagonal: Vec3d(repeating: 1e-4 * M))   // keep invertible for degenerate crafts
        mass = M; comLocal = com; inertia = I; inertiaInv = I.inverse
        if keepOrigin {
            position = oldOrigin + orientation.act(comLocal)
            let R = Mat3d(orientation)
            angularMomentum = R * inertia * R.transpose * oldOmega
        }
    }

    public var angularVelocityWorld: Vec3d {
        let R = Mat3d(orientation); return R * (inertiaInv * (R.transpose * angularMomentum))
    }
    func omegaWorld(_ q: Quatd) -> Vec3d { let R = Mat3d(q); return R * (inertiaInv * (R.transpose * angularMomentum)) }

    // MARK: reset / state
    /// Spawn transform (craft origin) that rests the craft's lowest point 2 cm above y = 0.
    public func restingSpawn(groundHeight: Double = 0) -> Transform {
        var minY = Double.infinity
        for p in parts {
            for c in p.corners { minY = min(minY, p.basePos.y + p.baseQ.act(c).y) }
            if p.type == .wheel { minY = min(minY, p.basePos.y - p.p("r")) }
        }
        if !minY.isFinite { minY = 0 }
        return Transform(position: [0, groundHeight - minY + 0.02, 0])
    }

    public func reset(spawn: Transform) {
        resetFuel()
        for i in parts.indices { parts[i].burning = false; parts[i].thrustNow = 0 }
        orientation = spawn.rotation.normalized
        updateMassProperties(keepOrigin: false)
        position = spawn.position + orientation.act(comLocal)
        velocity = .zero; angularMomentum = .zero; time = 0; stepCounter = 0
        updateEffective()
    }

    /// Set CoM linear velocity and world angular velocity (tests / spawning in flight).
    public func setVelocity(linear: Vec3d, angular: Vec3d) {
        velocity = linear
        let R = Mat3d(orientation); angularMomentum = R * inertia * R.transpose * angular
    }

    public var originTransform: Transform { Transform(position: position - orientation.act(comLocal), rotation: orientation) }
    public var bodyState: BodyState {
        BodyState(transform: originTransform, linearVelocity: velocity, angularVelocity: angularVelocityWorld, centerOfMass: position)
    }
    /// Total mechanical energy (J) relative to y = 0 for gravity g (energy-conservation checks).
    public func mechanicalEnergy(gravity g: Vec3d = [0, -kGravity, 0]) -> Double {
        0.5 * mass * simd_length_squared(velocity) + 0.5 * simd_dot(angularVelocityWorld, angularMomentum) - mass * simd_dot(g, position)
    }

    public func partPoses() -> [PartPose] {
        let o = originTransform
        return parts.map { p in
            var q = p.effQ
            if p.type == .prop { q = q * Quatd(angle: p.spinAngle, axis: [1, 0, 0]) }
            if p.type == .wheel { q = q * Quatd(angle: -p.spinAngle, axis: [0, 0, 1]) }
            return PartPose(partID: p.doc.id, transform: o * Transform(position: p.basePos, rotation: q))
        }
    }

    // MARK: stepping
    public func step(dt: Double, env: SimEnvironment) {
        guard !parts.isEmpty, dt > 0 else { return }
        let n = max(1, Int((dt * substepHz - 1e-9).rounded(.up)))
        let h = dt / Double(n)
        var e = env
        for k in 0..<n { e.time = env.time + Double(k) * h; substep(h, e) }
    }

    func updateEffective() {
        for i in parts.indices {
            var q = parts[i].baseQ
            if let s = parts[i].servo, parts[i].flapChord == 0 {
                let axisName = parts[s].doc.paramString("axis", "z")
                let ax: Vec3d = axisName == "x" ? [1, 0, 0] : axisName == "y" ? [0, 1, 0] : [0, 0, 1]
                let axis = parts[s].baseQ.act(ax)
                q = Quatd(angle: parts[s].angle * (parts[i].doc.invert ? -1 : 1), axis: axis) * q
            }
            parts[i].effQ = q.normalized
        }
    }

    func groundHeight(_ env: SimEnvironment, _ x: Double, _ z: Double) -> Double { env.terrain?.height(x: x, z: z) ?? 0 }
    func groundNormal(_ env: SimEnvironment, _ x: Double, _ z: Double) -> Vec3d { env.terrain?.normal(x: x, z: z) ?? [0, 1, 0] }

    func substep(_ h: Double, _ env: SimEnvironment) {
        // --- servos (torque/speed limited, back-driven by the previous step's hinge load)
        for i in parts.indices where parts[i].type == .servo {
            let s = parts[i]
            let tgt = clamp(s.out, -1, 1) * s.p("range") * kDeg, cap = max(1e-3, s.p("torque")), load = s.load
            var a = s.angle
            let overload = load > cap
            if !overload { let rate = s.p("speed") * kDeg * max(0.05, 1 - 0.8 * load / cap); a += clamp(tgt - a, -rate * h, rate * h) }
            else { let rate = s.p("speed") * kDeg * min(1, load / cap - 1); a += clamp(-a, -rate * h, rate * h) }
            parts[i].angle = a; parts[i].overload = overload; parts[i].loadShown = load; parts[i].load = 0
        }
        updateEffective()

        let q = orientation, origin = position - q.act(comLocal)
        let wW = omegaWorld(q)
        let atm = env.atmosphere(at: position.y)
        let rho = atm.density, nu = Aero.viscosity(temperature: atm.temperature) / max(rho, 1e-9)
        let groundUnder = groundHeight(env, position.x, position.z)
        let wind = WindField(mean: env.wind, turbulence: turbulence)
        let windHere = wind.velocity(at: position, heightAGL: position.y - groundUnder, time: env.time)
        var F = Vec3d.zero, T = Vec3d.zero
        @inline(__always) func apply(_ f: Vec3d, at pw: Vec3d) { F += f; T += simd_cross(pw - position, f) }
        @inline(__always) func pointVel(_ pw: Vec3d) -> Vec3d { velocity + simd_cross(wW, pw - position) }
        let air = rho > 1e-6 && aeroEnabled
        var stalledCount = 0, thrustTotal = 0.0

        // --- wing strips
        if air && !strips.isEmpty {
            if stripCap < strips.count { stripBuf?.deallocate(); stripBuf = .allocate(capacity: strips.count); stripCap = strips.count }
            let buf = stripBuf!
            let partsCopy = parts, stripsCopy = strips, pos = position, vel = velocity
            let terrain = env.terrain, time = env.time, sos = atm.speedOfSound
            let eval: (Range<Int>) -> Void = { range in
                for si in range {
                    let st = stripsCopy[si], p = partsCopy[st.part]
                    let qw = q * p.effQ
                    let nrm = qw.act([0, 1, 0]), c = qw.act([1, 0, 0]), s = qw.act([0, 0, 1])
                    let chord = p.p("chord")
                    let pac = origin + q.act(p.basePos) + c * (chord * 0.25) + s * st.spanOffset
                    let gh = terrain?.height(x: pac.x, z: pac.z) ?? 0
                    let wl = wind.velocity(at: pac, heightAGL: pac.y - gh, time: time)
                    var a3 = -(vel + simd_cross(wW, pac - pos) - wl)       // relative airflow
                    a3 -= s * simd_dot(a3, s)
                    let sp = simd_length(a3)
                    if sp < 0.3 { buf[si] = StripResult(); continue }
                    let alpha = atan2(simd_dot(a3, nrm), -simd_dot(a3, c))
                    var flapDelta = 0.0
                    if p.flapChord > 0, let sv = p.servo { flapDelta = partsCopy[sv].angle * (p.doc.invert ? -1 : 1) }
                    let ge = Aero.groundEffect(height: pac.y - gh, span: max(2 * p.p("span"), chord))
                    let wp = Aero.WingParams(aspectRatio: p.p("ar", 7), camberCl0: p.p("camber"), thicknessRatio: p.p("thick") / max(chord, 1e-3), flapChordFraction: p.flapChord)
                    let co = Aero.wing(alpha: alpha, mach: sp / sos, reynolds: sp * chord / nu, params: wp, flapDeflection: flapDelta,
                                       groundEffectInduced: ge.phi, groundLiftGain: ge.liftGain)
                    let qS = 0.5 * rho * sp * sp * st.area
                    let dd = a3 / sp
                    let ld = simd_normalize(simd_cross(dd, s))
                    let f = ld * (co.cl * qS) + dd * (co.cd * qS)
                    let pcp = pac + c * (chord * (0.25 - co.centerOfPressure))
                    var hinge = 0.0
                    if p.servo != nil {
                        if p.flapChord > 0 { let cf = p.flapChord * chord; hinge = abs(co.hingeCh) * 0.5 * rho * sp * sp * st.area * p.flapChord * cf }
                        else { hinge = simd_length(f) * 0.12 * chord + abs(co.cl) * qS * 0.02 }   // prototype hinge-load model
                    }
                    buf[si] = StripResult(ft: ForceTorque(force: f, torque: simd_cross(pcp - pos, f)), hinge: hinge,
                                          stalled: co.stalled, bigStall: co.stalled && p.p("span") * chord > 2)
                }
            }
            if strips.count >= parallelThreshold { JobSystem.shared.parallelFor(strips.count, grain: 32, label: "physics.wings", eval) }
            else { eval(0..<strips.count) }
            for si in 0..<strips.count {
                let r = buf[si]; F += r.ft.force; T += r.ft.torque
                if r.hinge > 0, let sv = parts[strips[si].part].servo { parts[sv].load += r.hinge }
                if r.bigStall { stalledCount += 1 }
            }
        }

        // --- bodies: projected-area drag, or mesh panels for CAD
        if air {
            for i in parts.indices {
                let p = parts[i]; guard let t = p.type, BODY_TYPES.contains(t) else { continue }
                if let m = p.mesh {
                    let qp = q * p.effQ, op = origin + q.act(p.basePos)
                    let vb = qp.inverse.act(velocity - windHere)
                    if simd_length(vb) > 0.5 { m.updateShadows(flowDir: -simd_normalize(vb)) }
                    let ft: ForceTorque
                    if m.count >= parallelThreshold {
                        let chunks = max(1, min(JobSystem.shared.threadCount * 2, m.count / 128))
                        if panelCap < chunks { panelBuf?.deallocate(); panelBuf = .allocate(capacity: chunks); panelCap = chunks }
                        let pb = panelBuf!, cnt = m.count, pos = position, vel = velocity, rhoL = rho, sos = atm.speedOfSound, wv = windHere
                        JobSystem.shared.parallelFor(chunks, grain: 1, label: "physics.panels") { r in
                            for c in r {
                                let lo = cnt * c / chunks, hi = cnt * (c + 1) / chunks
                                pb[c] = m.evaluate(range: lo..<hi, toWorld: qp, origin: op, com: pos, linVel: vel, angVel: wW, wind: wv, rho: rhoL, nu: nu, speedOfSound: sos)
                            }
                        }
                        var acc = ForceTorque.zero; for c in 0..<chunks { acc = acc + pb[c] }; ft = acc
                    } else {
                        ft = m.evaluate(range: 0..<m.count, toWorld: qp, origin: op, com: position, linVel: velocity, angVel: wW, wind: windHere, rho: rho, nu: nu, speedOfSound: atm.speedOfSound)
                    }
                    F += ft.force; T += ft.torque
                } else {
                    let pw = origin + q.act(p.basePos + p.effQ.act(p.ctr))
                    let v = pointVel(pw) - windHere, sp = simd_length(v); if sp < 0.1 { continue }
                    let vl = (q * p.effQ).inverse.act(v) / sp, s = p.size
                    let A = abs(vl.x) * s.y * s.z + abs(vl.y) * s.x * s.z + abs(vl.z) * s.x * s.y
                    let cd = p.p("cd", 0.3) * (sp / atm.speedOfSound > 0.8 ? 1 + 6 * pow(sp / atm.speedOfSound - 0.8, 2) : 1)
                    apply(v * (-0.5 * rho * sp * cd * A), at: pw)
                }
            }
        }

        // --- propulsion
        var liquid = 0.0; for p in parts where p.type == .tank { liquid += p.fuel }
        var liquidUse = 0.0
        for i in parts.indices {
            let p = parts[i]
            parts[i].thrustNow = 0
            switch p.type {
            case .prop:
                let thr: Double = p.autoMotor ? p.out : (p.motor.map { clamp(parts[$0].out, -1, 1) } ?? 0)
                let dir = q.act(p.effQ.act([1, 0, 0])), pw = origin + q.act(p.basePos)
                let vax = simd_dot(pointVel(pw) - windHere, dir)
                let P = Propulsion.propPower(staticThrust: p.p("thrust"), diameter: max(0.1, p.p("d"))) * abs(thr) * (rho / 1.225)
                let r = Propulsion.propThrust(power: P, diameter: max(0.1, p.p("d")), rho: max(rho, 1e-6), axialSpeed: thr >= 0 ? vax : -vax, pitchSpeed: p.p("vmax", 80))
                let Tn = (thr >= 0 ? 1 : -0.5) * r.thrust
                apply(dir * Tn, at: pw)
                let targetOmega = 2 * Double.pi * r.rps * abs(thr) * (thr >= 0 ? 1 : -1)
                parts[i].omega += (targetOmega - parts[i].omega) * min(1, h / 0.4)
                parts[i].spinAngle = (parts[i].spinAngle + parts[i].omega * h).truncatingRemainder(dividingBy: 2 * Double.pi)
                if abs(parts[i].omega) > 1 { T -= dir * (P * 0.75 / parts[i].omega) * 0.25 }  // reaction torque (partly cancelled by slipstream)
                parts[i].thrustNow = abs(Tn); thrustTotal += abs(Tn)
            case .jet:
                let cmd = liquid > 0 ? clamp(p.out, 0, 1) : 0
                parts[i].spool = Propulsion.spool(p.spool, command: cmd, dt: h)
                if liquid > 0 && parts[i].spool > 0.01 {
                    let dir = q.act(p.effQ.act([1, 0, 0])), pw = origin + q.act(p.basePos)
                    let M = simd_length(velocity - windHere) / atm.speedOfSound
                    let Tn = p.p("thrust") * parts[i].spool * Propulsion.jetLapse(rho: rho, mach: M)
                    apply(dir * Tn, at: pw)
                    liquidUse += p.p("flow") * (0.05 + 0.95 * parts[i].spool) * h * (rho / 1.225 * 0.5 + 0.5)
                    parts[i].thrustNow = Tn; thrustTotal += Tn
                }
                parts[i].spinAngle += parts[i].spool * 300 * h
            case .solid:
                if !p.burning && p.out > 0.5 && p.fuel > 0 { parts[i].burning = true; parts[i].ignitedAt = time }
                if parts[i].burning {
                    let dir = q.act(p.effQ.act([1, 0, 0])), pw = origin + q.act(p.basePos)
                    let frac = p.fuel / max(p.fuelCapacity, 1e-9)
                    let k = Propulsion.solidProfile(fuelFraction: frac, sinceIgnition: time - parts[i].ignitedAt, ambientPressure: atm.pressure)
                    let Tn = p.p("thrust") * k
                    apply(dir * Tn, at: pw)
                    // mass flow ∝ thrust so total impulse = thrust × burn
                    parts[i].fuel -= p.fuelCapacity / max(p.p("burn"), 1e-3) * k * h
                    if parts[i].fuel <= 0 { parts[i].fuel = 0; parts[i].burning = false }
                    parts[i].thrustNow = Tn; thrustTotal += Tn
                }
            default: break
            }
        }
        var massDirty = false
        if liquidUse > 0 && liquid > 0 {
            let k = max(0, 1 - liquidUse / liquid)
            for i in parts.indices where parts[i].type == .tank { parts[i].fuel *= k }
            massDirty = true
        }
        if parts.contains(where: { $0.burning }) { massDirty = true }

        // --- gravity
        F += env.gravity * mass

        // --- ground: rigid bounding-box corners (penalty spring-damper + Coulomb friction)
        if groundEnabled {
            // Gains are per craft; split them across the corners currently penetrating so total
            // stiffness/damping does not scale with contact count (explicit stability: h*cB_tot/m <= 0.04).
            var nContact = 0
            for p in parts where !p.corners.isEmpty {
                let qp = q * p.effQ, op = origin + q.act(p.basePos)
                for c in p.corners { let pw = op + qp.act(c); if pw.y < groundHeight(env, pw.x, pw.z) { nContact += 1 } }
            }
            let share = 1.0 / Double(max(1, nContact))
            let kB = mass * 2000 * share, cB = mass * 60 * share
            for p in parts where !p.corners.isEmpty {
                let qp = q * p.effQ, op = origin + q.act(p.basePos)
                for c in p.corners {
                    let pw = op + qp.act(c)
                    let gh = groundHeight(env, pw.x, pw.z); if pw.y >= gh { continue }
                    let n = groundNormal(env, pw.x, pw.z)
                    let pen = (gh - pw.y) * n.y
                    let vp = pointVel(pw)
                    let vn = simd_dot(vp, n)
                    let N = max(0, pen * kB - vn * cB); if N <= 0 { continue }
                    let mu = env.terrain?.material(x: pw.x, z: pw.z).friction ?? 0.6
                    let vt = vp - n * vn, vts = simd_length(vt)
                    var f = n * N
                    if vts > 1e-4 { f -= vt * (min(mu * N, vts * cB) / vts) }
                    apply(f, at: pw)
                }
            }
            // --- wheels: suspension + Pacejka-lite tyre with implicit wheel-spin DOF
            let nW = max(1, parts.filter { $0.type == .wheel }.count)
            let kW = mass * kGravity / (Double(nW) * 0.08)
            let cW = 2 * 0.6 * (kW * mass / Double(nW)).squareRoot()
            for i in parts.indices where parts[i].type == .wheel {
                let p = parts[i]
                let r = max(0.02, p.p("r")), Iw = max(0.05, 0.5 * p.doc.mass * r * r)
                let hub = origin + q.act(p.basePos)
                let axle = q.act(p.effQ.act([0, 0, 1]))
                var omega = p.omega
                let n = groundNormal(env, hub.x, hub.z)
                var down = -n + axle * simd_dot(axle, n)
                var contact = false
                var motorT = 0.0
                if p.autoMotor { motorT = Self.autoWheelTorque * clamp(p.out, -1, 1) }
                else if let m = p.motor {
                    let mp = parts[m], lo = mp.p("reversible") != 0 ? -1.0 : 0
                    motorT = mp.p("torque") * clamp(mp.out, lo, 1)
                    let vmax = mp.p("vmax", 20)
                    motorT *= clamp(1 - (omega * r * (motorT >= 0 ? 1 : -1)) / max(vmax, 0.1), 0, 1)
                }
                if simd_length_squared(down) > 1e-4 {
                    down = simd_normalize(down)
                    let cp = hub + down * r
                    let gh = groundHeight(env, cp.x, cp.z)
                    let pen = (gh - cp.y) * n.y
                    let fwdRaw = simd_cross(n, axle)
                    if pen > 0 && simd_length_squared(fwdRaw) > 1e-6 {
                        contact = true
                        let fwd = simd_normalize(fwdRaw), lat = simd_cross(fwd, n)
                        let vp = pointVel(cp)
                        let N = max(0, pen * kW - simd_dot(vp, n) * cW)
                        let mat = env.terrain?.material(x: cp.x, z: cp.z) ?? TerrainMaterialSample()
                        let mu = p.p("grip", 0.9) * mat.friction / 0.9
                        let D = mu * N
                        let vf = simd_dot(vp, fwd), vl = simd_dot(vp, lat)
                        let den = max(abs(vf), 1.0)
                        // longitudinal: slip ratio κ = (ωr − v)/max(|v|,1), Fx = D sin(C atan(Bκ)); implicit ω update
                        let Bx = 10.0, Cx = 1.65
                        let kappa0 = (omega * r - vf) / den
                        let fx0 = D * sin(Cx * atan(Bx * kappa0))
                        let slope = D * Cx * Bx * r / den
                        omega = omega + h * (motorT - r * fx0) / (Iw + h * r * slope)
                        let kappa = (omega * r - vf) / den
                        var fx = D * sin(Cx * atan(Bx * kappa))
                        // lateral: slip angle α, Fy = −D sin(C atan(Bα))
                        let alpha = atan2(vl, den)
                        var fy = -D * sin(1.3 * atan(8 * alpha))
                        let mag = (fx * fx + fy * fy).squareRoot()
                        if mag > D && mag > 0 { fx *= D / mag; fy *= D / mag }
                        let roll = -clamp(vf * 4, -1, 1) * p.p("roll", 0.02) * mat.rollingResistance * N
                        apply(n * N + fwd * (fx + roll) + lat * fy, at: cp)
                        parts[i].compression = pen
                        if let s = p.servo { parts[s].load += abs(fy) * 0.04 }
                    }
                }
                if !contact { omega += h * motorT / Iw; omega *= (1 - 0.2 * h) }
                parts[i].omega = omega; parts[i].contact = contact
                parts[i].spinAngle = (parts[i].spinAngle + omega * h).truncatingRemainder(dividingBy: 2 * Double.pi)
            }
        }

        // --- buoyancy / hydrodynamics
        if let water = env.water, let hull {
            let ws = water.sample(x: position.x, z: position.z, time: env.time)
            if position.y - boundingRadius < ws.surfaceHeight + 1 {
                let st = BodyState(transform: originTransform, linearVelocity: velocity, angularVelocity: wW, centerOfMass: position)
                let (ft, _) = water.submergedForces(hull: hull, state: st, time: env.time)
                F += ft.force; T += ft.torque
            }
        }

        // --- integrate: symplectic Euler (linear), angular momentum + midpoint exp-map (angular)
        // linear: velocity Verlet with force held over the step (exact for constant force, symplectic)
        let vOld = velocity
        velocity += F / mass * h
        position += (vOld + velocity) * (0.5 * h)
        angularMomentum += T * h
        let w0 = omegaWorld(orientation)
        let qHalf = Self.rotate(orientation, by: w0, dt: h * 0.5)
        let wHalf = omegaWorld(qHalf)
        orientation = Self.rotate(orientation, by: wHalf, dt: h)
        time += h; stepCounter += 1
        lastForce = F - env.gravity * mass

        if massDirty && stepCounter % 10 == 0 { updateMassProperties(keepOrigin: true) }
        updateTelemetry(env: env, atm: atm, windHere: windHere, stalled: stalledCount, thrust: thrustTotal, ground: groundUnder)
    }

    @inline(__always) static func rotate(_ q: Quatd, by w: Vec3d, dt: Double) -> Quatd {
        let a = simd_length(w) * dt
        if a < 1e-15 { return q }
        return (Quatd(angle: a, axis: w / simd_length(w)) * q).normalized
    }

    func updateTelemetry(env: SimEnvironment, atm: Atmosphere, windHere: Vec3d, stalled: Int, thrust: Double, ground: Double) {
        var t = CraftTelemetry()
        let vAir = velocity - windHere
        let vb = orientation.inverse.act(vAir)
        t.airspeed = simd_length(vAir)
        t.groundSpeed = simd_length(Vec2d(velocity.x, velocity.z))
        t.altitude = position.y
        t.verticalSpeed = velocity.y
        t.angleOfAttackDeg = t.airspeed > 0.5 ? atan2(-vb.y, vb.x) / kDeg : 0
        t.sideslipDeg = t.airspeed > 0.5 ? asin(clamp(vb.z / t.airspeed, -1, 1)) / kDeg : 0
        t.mach = t.airspeed / atm.speedOfSound
        t.gLoad = simd_dot(lastForce / mass, orientation.act([0, 1, 0])) / kGravity
        t.fuelKg = parts.reduce(0) { $0 + $1.fuel }
        t.massKg = mass
        t.thrustN = thrust
        t.stalledSurfaces = stalled
        telemetry = t
    }

    // MARK: introspection for UI / tests
    public func servoAngleDeg(_ id: String) -> Double? { parts.first { $0.doc.id == id }.map { $0.angle / kDeg } }
    public func partFuel(_ id: String) -> Double? { parts.first { $0.doc.id == id }?.fuel }
    public var heading: Vec3d { orientation.act([1, 0, 0]) }
    /// Names of servos whose aerodynamic/tyre hinge load currently exceeds their torque (HUD warning). [integrator]
    public var overloadedServos: [String] { parts.filter { $0.overload }.map { $0.doc.name } }
    /// Total remaining fuel/propellant (kg) over all parts. [integrator]
    public var totalFuel: Double { parts.reduce(0) { $0 + $1.fuel } }
    public var pitchDeg: Double { asin(clamp(heading.y, -1, 1)) / kDeg }
}

/// Source compatibility with the architect's stub name (App wires `StubCraftSimulation()`).
public typealias StubCraftSimulation = CraftSim
