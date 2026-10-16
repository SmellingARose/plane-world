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

    // Hot constants baked once at load (`bake()`): the substep reads only these plain fields, never
    // `doc` (string-keyed dictionaries), so the hot loop does no hashing and no ARC traffic. Every value
    // is exactly `doc.param(...)` so results are bit-identical to reading the parameters directly.
    var isBody = false, isWing = false, invert = false, docMass = 0.0
    var kRange = 0.0, kTorque = 0.0, kSpeed = 0.0            // servo / motor
    var kCd = 0.3                                              // body drag
    var kThrust = 0.0, kD = 0.0, kPropVmax = 80.0, kSpin = 1.0, kDucted = false, vi = 0.0, wakeQ = 0.0              // prop / jet / solid
    var kFlow = 0.0, kBurn = 0.0
    var kR = 0.0, kGrip = 0.9, kRoll = 0.02                    // wheel
    var kReversible = 0.0, kMotorVmax = 20.0                   // motor
    var kChord = 0.0, kSpan = 0.0                              // wing
    var wing = Aero.WingConst.zero
    var baseQN = Quatd.identity                               // baseQ.normalized
    var servoAxis = Vec3d(0, 0, 1)                             // servo axis (part frame) from "axis"
    var servoAxisBase = Vec3d(0, 0, 1)                         // baseQ.act(servoAxis)
    var kPropPower = 0.0                                       // Propulsion.propPower(thrust, max(0.1, d))
    var cornerStart = 0, cornerCount = 0                      // range in CraftSim.cornerFlat
    var meshSlot = -1, itemStart = 0, itemCount = 0           // CAD panel work items in CraftSim.panels

    mutating func bake() {
        let t = type
        isBody = t.map { CraftSim.BODY_TYPES_SET.contains($0) } ?? false
        isWing = t == .wing
        invert = doc.invert; docMass = doc.mass
        kRange = p("range"); kTorque = p("torque"); kSpeed = p("speed")
        kCd = p("cd", 0.3)
        kThrust = p("thrust"); kD = p("d"); kPropVmax = p("vmax", 80); kSpin = p("spin", 1) < 0 ? -1 : 1
        kFlow = p("flow"); kBurn = p("burn")
        kR = p("r"); kGrip = p("grip", 0.9); kRoll = p("roll", 0.02)
        kReversible = p("reversible"); kMotorVmax = p("vmax", 20)
        kChord = p("chord"); kSpan = p("span")
        if t == .wing {
            wing = Aero.WingConst(Aero.WingParams(aspectRatio: p("ar", 7), camberCl0: p("camber"), thicknessRatio: p("thick") / max(kChord, 1e-3), flapChordFraction: flapChord))
        }
        baseQN = baseQ.normalized
        let axisName = doc.paramString("axis", "z")
        servoAxis = axisName == "x" ? [1, 0, 0] : axisName == "y" ? [0, 1, 0] : [0, 0, 1]
        servoAxisBase = baseQ.act(servoAxis)
        kPropPower = Propulsion.propPower(staticThrust: kThrust, diameter: max(0.1, kD))
    }
}

/// All CAD panel meshes of a craft as fixed-size work items (≤ `chunk` panels each). Built at load; every
/// substep evaluates the items serially or with one reusable `ParallelLoop` (no allocations). Item
/// boundaries depend only on the meshes, so results do not depend on the thread count, and a mesh of
/// ≤ `chunk` panels is one item, bit-identical to evaluating it inline.
final class PanelBatch {
    static let chunk = 2048
    /// Total panels at or above which a substep evaluates items in parallel (fork/join costs ~10-20 µs).
    static let parallelMinPanels = 4096
    struct Item { var slot: Int; var lo: Int; var hi: Int }
    var meshes: [PanelMesh] = []
    var items: [Item] = []
    var totalPanels = 0
    var qp: UnsafeMutablePointer<Quatd>, op: UnsafeMutablePointer<Vec3d>, out: UnsafeMutablePointer<ForceTorque>
    var com = Vec3d.zero, linVel = Vec3d.zero, angVel = Vec3d.zero, wind = Vec3d.zero
    var rho = 0.0, nu = 0.0, sos = 340.0
    lazy var loop = ParallelLoop { [unowned(unsafe) self] r in self.runItems(r) }

    init(meshes: [PanelMesh]) {
        self.meshes = meshes
        for (slot, m) in meshes.enumerated() {
            var lo = 0
            repeat { let hi = min(m.count, lo + Self.chunk); items.append(Item(slot: slot, lo: lo, hi: hi)); lo = hi } while lo < m.count
            totalPanels += m.count
        }
        qp = .allocate(capacity: max(1, meshes.count)); op = .allocate(capacity: max(1, meshes.count))
        out = .allocate(capacity: max(1, items.count))
    }
    deinit { qp.deallocate(); op.deallocate(); out.deallocate() }

    func runItems(_ r: Range<Int>) {
        for k in r {
            let it = items[k], s = it.slot
            out[k] = meshes[s].evaluate(range: it.lo..<it.hi, toWorld: qp[s], origin: op[s], com: com, linVel: linVel, angVel: angVel,
                                        wind: wind, rho: rho, nu: nu, speedOfSound: sos)
        }
    }
}

/// One spanwise wing strip evaluated per substep (possibly in parallel).
struct WingStrip { var part: Int; var spanOffset: Double; var area: Double }
struct StripResult { var ft = ForceTorque.zero; var hinge = 0.0; var stalled = false; var bigStall = false }

public final class CraftSim: CraftSimulation {
    // configuration
    public var substepHz: Double = 1000
    public var aeroEnabled = true
    /// Rotor slipstream / induced-flow coupling (see Slipstream.swift). Off reproduces the isolated-part model.
    public var slipstream = CraftSim.slipstreamDefault
    /// `PW_SLIPSTREAM=0` turns the model off process-wide (A/B comparisons).
    public static let slipstreamDefault = ProcessInfo.processInfo.environment["PW_SLIPSTREAM"] != "0"
    var wakeBuf = UnsafeMutablePointer<RotorWake>.allocate(capacity: 1), wakeCap = 1, wakeCount = 0
    func allocWakes() {
        wakeBuf.deallocate(); wakeCap = max(1, parts.filter { $0.type == .prop }.count)
        wakeBuf = .allocate(capacity: wakeCap); wakeBuf.initialize(repeating: RotorWake(), count: wakeCap); wakeCount = 0
    }
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
    var cornerFlat: [Vec3d] = []
    var panels = PanelBatch(meshes: [])
    var cornerTmp: UnsafeMutablePointer<SIMD4<Double>>?   // per-substep corner world pos (xyz) + ground height (w)
    var contactRadius = 0.0                    // max distance of any corner / wheel contact point from the origin               // all part corners, part i at cornerStart..<cornerStart+cornerCount
    var outputTargets: [String: Int] = [:]    // output id -> part index
    var outputTargetCache: [Int] = []         // output index -> part index (-1 none)

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
    var wheelCount = 0
    // contact / crash flags (sensors + evolution termination). Latched until reset.
    /// Impact speed (m/s, into the ground) above which a non-wheel corner contact counts as a crash.
    public var crashSpeed = 8.0
    public private(set) var crashed = false
    public private(set) var groundContact = false      // any corner or wheel touching this substep
    public private(set) var maxImpactSpeed = 0.0
    // sensors (see Sensors.swift)
    public internal(set) var inputs: [CraftInput] = []
    var sensorSlots: [SensorSlot] = []
    var noiseState: UInt64 = 0x9E3779B97F4A7C15
    public var sensorNoiseSeed: UInt64 = 0x9E3779B97F4A7C15

    public init() {}
    deinit { stripBuf?.deallocate(); cornerTmp?.deallocate(); wakeBuf.deallocate() }

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
        bakeParts()
        detectDucts(); allocWakes()
        rebuildPanelBatch()
        rebuildStrips()
        wheelCount = parts.filter { $0.type == .wheel }.count
        outputs = Self.makeOutputs(craft)
        outputTargets = [:]; outputTargetCache = []
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
        buildSensors()
        resetFuel()
        updateMassProperties(keepOrigin: false)
        reset(spawn: restingSpawn())
    }

    /// Bake per-part hot constants and flatten all part corners into `cornerFlat` (SoA for the ground loop).
    func bakeParts() {
        cornerFlat = []
        for i in parts.indices {
            parts[i].bake()
            parts[i].cornerStart = cornerFlat.count; parts[i].cornerCount = parts[i].corners.count
            cornerFlat += parts[i].corners
        }
        var r = 0.0
        for p in parts {
            for c in p.corners { r = max(r, simd_length(p.basePos) + simd_length(c)) }
            if p.type == .wheel { r = max(r, simd_length(p.basePos) + max(0.02, p.kR)) }
        }
        contactRadius = r
        cornerTmp?.deallocate(); cornerTmp = .allocate(capacity: max(1, cornerFlat.count))
    }

    /// Assign CAD meshes of body parts to `panels` slots and work items (call after any mesh change).
    func rebuildPanelBatch() {
        var meshes: [PanelMesh] = []
        var item = 0
        for i in parts.indices {
            parts[i].meshSlot = -1; parts[i].itemStart = 0; parts[i].itemCount = 0
            guard parts[i].isBody, let m = parts[i].mesh else { continue }
            parts[i].meshSlot = meshes.count; meshes.append(m)
            let n = max(1, (m.count + PanelBatch.chunk - 1) / PanelBatch.chunk)
            parts[i].itemStart = item; parts[i].itemCount = n; item += n
        }
        panels = PanelBatch(meshes: meshes)
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
        setOutput(index: i, value: value)
    }
    /// Index of an output by id or (user-visible) name, for resolving once before a hot loop.
    public func outputIndex(_ idOrName: String) -> Int? { outputs.firstIndex { $0.id == idOrName } ?? outputs.firstIndex { $0.name == idOrName } }
    /// Allocation-free output write (index into `outputs`). Used by evolution controllers every control tick.
    public func setOutput(index i: Int, value: Double) {
        guard i >= 0 && i < outputs.count else { return }
        let v = clamp(value.isFinite ? value : 0, outputs[i].range.lowerBound, outputs[i].range.upperBound)
        outputs[i].value = v
        if let pi = outputTargetIndex(i) { parts[pi].out = v }
    }
    @inline(__always) func outputTargetIndex(_ i: Int) -> Int? {
        if outputTargetCache.count != outputs.count { outputTargetCache = outputs.map { outputTargets[$0.id] ?? -1 } }
        let t = outputTargetCache[i]; return t >= 0 ? t : nil
    }

    /// Replace a CAD part's aero mesh (body-local triangle soup, part frame) — used by the Craft importer.
    public func setPartMesh(partID: String, soup: [Vec3d]) {
        guard let i = parts.firstIndex(where: { $0.doc.id == partID }) else { return }
        let m = PanelMesh(soup: soup); parts[i].mesh = m.count > 0 ? m : nil
        if let m = parts[i].mesh {
            var bb = AABB.empty; for c in m.tris { bb.expand(c.0); bb.expand(c.1); bb.expand(c.2) }
            parts[i].size = bb.max - bb.min; parts[i].ctr = bb.center
        }
        rebuildPanelBatch()
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
        case .sensor: return (Vec3d(repeating: 0.12), .zero)
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
            else if p.type != .prop && p.type != .servo && p.type != .sensor { soup += PanelMesh.boxSoup(center: p.basePos + p.baseQ.act(p.ctr), size: p.size, rotation: p.baseQ) }
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
            parts[i].angle = 0; parts[i].spinAngle = 0; parts[i].omega = 0; parts[i].spool = 0; parts[i].load = 0; parts[i].vi = 0; parts[i].wakeQ = 0
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
        crashed = false; groundContact = false; maxImpactSpeed = 0; lastForce = .zero; noiseState = sensorNoiseSeed | 1
        for i in parts.indices { parts[i].contact = false; parts[i].compression = 0 }
        telemetry = CraftTelemetry()
        updateEffective()
    }

    /// Total number of part bounding-box corners (for preallocating `writeWorldCorners` buffers).
    public var cornerCount: Int { var n = 0; for p in parts { n += p.corners.count }; return n }
    /// Bounding radius of the craft about its CoM (m).
    public var collisionRadius: Double { boundingRadius }
    /// Writes world-space part corners into `out` (up to `capacity`); returns the count. Allocation-free.
    public func writeWorldCorners(_ out: UnsafeMutablePointer<Vec3d>, capacity: Int) -> Int {
        let q = orientation, origin = position - q.act(comLocal)
        var n = 0
        for p in parts where !p.corners.isEmpty {
            let qp = q * p.effQ, op = origin + q.act(p.basePos)
            for c in p.corners { if n >= capacity { return n }; out[n] = op + qp.act(c); n += 1 }
        }
        return n
    }
    /// Contact with a static headless obstacle (tree/prop/breakable). Headless obstacles have no contact
    /// response, so any contact latches `crashed`; `impactSpeed` feeds maxImpactSpeed.
    public func markObstacleHit(impactSpeed: Double) {
        crashed = true
        if impactSpeed > maxImpactSpeed { maxImpactSpeed = impactSpeed }
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
        guard !parts.isEmpty else { return }
        parts.withUnsafeMutableBufferPointer { b in Self.updateEffective(b.baseAddress!, b.count) }
    }
    @inline(__always) static func updateEffective(_ P: UnsafeMutablePointer<SimPart>, _ n: Int) {
        for i in 0..<n {
            if let s = P[i].servo, P[i].flapChord == 0 {
                let q = Quatd(angle: P[s].angle * (P[i].invert ? -1 : 1), axis: P[s].servoAxisBase) * P[i].baseQ
                P[i].effQ = q.normalized
            } else {
                P[i].effQ = P[i].baseQN
            }
        }
    }

    @inline(__always) func groundHeight(_ env: SimEnvironment, _ x: Double, _ z: Double) -> Double { env.terrain?.height(x: x, z: z) ?? 0 }
    @inline(__always) func groundNormal(_ env: SimEnvironment, _ x: Double, _ z: Double) -> Vec3d { env.terrain?.normal(x: x, z: z) ?? [0, 1, 0] }

    /// Per-substep values handed from the pointer-based core back to the array-based epilogue.
    struct SubstepOut { var massDirty = false; var stalled = 0; var thrust = 0.0; var fuel = 0.0; var windHere = Vec3d.zero; var ground = 0.0; var atm = Atmosphere.isa(altitude: 0) }

    func substep(_ h: Double, _ env: SimEnvironment) {
        // The core works on raw pointers into `parts` / `cornerFlat`: no SimPart copies (each copy used to
        // retain/release ~10 heap objects of `doc`), no bounds checks, no dictionary lookups.
        let o: SubstepOut = parts.withUnsafeMutableBufferPointer { pb in
            cornerFlat.withUnsafeBufferPointer { cb in substepCore(pb.baseAddress!, pb.count, cb.baseAddress, h, env) }
        }
        if o.massDirty && stepCounter % 10 == 0 { updateMassProperties(keepOrigin: true) }
        updateTelemetry(env: env, atm: o.atm, windHere: o.windHere, stalled: o.stalled, thrust: o.thrust, ground: o.ground, fuel: o.fuel)
    }

    // @inline(never): when inlined into `substep`, the optimiser boxes a closure context on the heap every substep.
    @inline(never) func substepCore(_ P: UnsafeMutablePointer<SimPart>, _ np: Int, _ CF: UnsafePointer<Vec3d>?, _ h: Double, _ env: SimEnvironment) -> SubstepOut {
        var out = SubstepOut()
        // --- servos (torque/speed limited, back-driven by the previous step's hinge load)
        for i in 0..<np where P[i].type == .servo {
            let tgt = clamp(P[i].out, -1, 1) * P[i].kRange * kDegF, cap = max(1e-3, P[i].kTorque), load = P[i].load
            var a = P[i].angle
            let overload = load > cap
            if !overload { let rate = P[i].kSpeed * kDegF * max(0.05, 1 - 0.8 * load / cap); a += clamp(tgt - a, -rate * h, rate * h) }
            else { let rate = P[i].kSpeed * kDegF * min(1, load / cap - 1); a += clamp(-a, -rate * h, rate * h) }
            P[i].angle = a; P[i].overload = overload; P[i].loadShown = load; P[i].load = 0
        }
        Self.updateEffective(P, np)

        let q = orientation, origin = position - q.act(comLocal)
        let wW = omegaWorld(q)
        let atm = env.atmosphere(at: position.y)
        let rho = atm.density, nu = Aero.viscosity(temperature: atm.temperature) / max(rho, 1e-9)
        let groundUnder = groundHeight(env, position.x, position.z)
        let wind = WindField(mean: env.wind, turbulence: turbulence)
        let windHere = wind.velocity(at: position, heightAGL: position.y - groundUnder, time: env.time)
        let position = self.position, velocity = self.velocity
        var F = Vec3d.zero, T = Vec3d.zero
        @inline(__always) func apply(_ f: Vec3d, at pw: Vec3d) { F += f; T += simd_cross(pw - position, f) }
        @inline(__always) func pointVel(_ pw: Vec3d) -> Vec3d { velocity + simd_cross(wW, pw - position) }
        let air = rho > 1e-6 && aeroEnabled
        // --- rotor wakes from the previous substep's disk state
        wakeCount = 0
        if air && slipstream {
            for i in 0..<np where P[i].type == .prop && P[i].vi > 1e-6 {
                let dir = q.act(P[i].effQ.act([1, 0, 0])), pw = origin + q.act(P[i].basePos)
                let rel = windHere - (velocity + simd_cross(wW, pw - position))   // air relative to the disk (inlined: keeps the pointVel context on the stack)
                let axis = -dir, va = max(0, simd_dot(rel, axis))
                let R = max(0.05, P[i].kD / 2)
                if wakeCount < wakeCap { wakeBuf[wakeCount] = RotorWake(center: pw, axis: axis, radius: R, vi: P[i].vi, vAxial: va, cross: rel - axis * simd_dot(rel, axis),
                                 swirl: (P[i].omega >= 0 ? 1 : -1) * P[i].wakeQ / (rho * Double.pi * R * R), ducted: P[i].kDucted, owner: i); wakeCount += 1 }
            }
        }
        let wakeView = WakeView(buf: wakeCount > 0 ? UnsafePointer(wakeBuf) : nil, count: wakeCount)
        var stalledCount = 0, thrustTotal = 0.0

        // --- wing strips
        let ns = strips.count
        if air && ns > 0 {
            if stripCap < ns { stripBuf?.deallocate(); stripBuf = .allocate(capacity: ns); stripCap = ns }
            let buf = stripBuf!
            strips.withUnsafeBufferPointer { sb in
                let job = StripJob(buf: buf, parts: P, strips: sb.baseAddress!, q: q, origin: origin, wW: wW, pos: position, vel: velocity,
                                   sos: atm.speedOfSound, rho: rho, nu: nu, wind: WindField.Prepared(wind, time: env.time), wakes: wakeView)
                // Serial path calls the struct directly (no closure context allocation, and the terrain
                // existential is passed borrowed: no retain/release of the shared terrain per substep).
                if ns >= parallelThreshold { JobSystem.shared.parallelFor(ns, grain: 32, label: "physics.wings") { job.run($0, terrain: env.terrain) } }
                else { job.run(0..<ns, terrain: env.terrain) }
                for si in 0..<ns {
                    let r = buf[si]; F += r.ft.force; T += r.ft.torque
                    if r.hinge > 0, let sv = P[sb[si].part].servo { P[sv].load += r.hinge }
                    if r.bigStall { stalledCount += 1 }
                }
            }
        }

        // --- bodies: projected-area drag, or mesh panels for CAD
        if air {
            // CAD panels first (they do not depend on the accumulated force), serial or one reusable parallel loop
            let pb = panels
            if pb.totalPanels > 0 {
                for i in 0..<np where P[i].meshSlot >= 0 {
                    let slot = P[i].meshSlot, m = pb.meshes[slot]
                    let qp = q * P[i].effQ, op = origin + q.act(P[i].basePos)
                    let vb = qp.inverse.act(velocity - windHere)
                    if simd_length(vb) > 0.5 { m.updateShadows(flowDir: -simd_normalize(vb)) }
                    pb.qp[slot] = qp; pb.op[slot] = op
                }
                pb.com = position; pb.linVel = velocity; pb.angVel = wW; pb.wind = windHere
                pb.rho = rho; pb.nu = nu; pb.sos = atm.speedOfSound
                if pb.items.count > 1 && pb.totalPanels >= max(parallelThreshold, PanelBatch.parallelMinPanels) {
                    JobSystem.shared.run(pb.loop, count: pb.items.count, grain: 1)
                } else {
                    pb.runItems(0..<pb.items.count)
                }
            }
            for i in 0..<np where P[i].isBody {
                if P[i].meshSlot >= 0 {
                    let s0 = P[i].itemStart, nItems = P[i].itemCount
                    var ft = pb.out[s0]
                    if nItems > 1 { ft = .zero; for k in s0..<(s0 + nItems) { ft = ft + pb.out[k] } }
                    F += ft.force; T += ft.torque
                } else {
                    let pw = origin + q.act(P[i].basePos + P[i].effQ.act(P[i].ctr))
                    let v = pointVel(pw) - windHere - wakeView.velocity(at: pw), sp = simd_length(v); if sp < 0.1 { continue }
                    let vl = (q * P[i].effQ).inverse.act(v) / sp, s = P[i].size
                    let A = abs(vl.x) * s.y * s.z + abs(vl.y) * s.x * s.z + abs(vl.z) * s.x * s.y
                    let cd = P[i].kCd * (sp / atm.speedOfSound > 0.8 ? 1 + 6 * pow(sp / atm.speedOfSound - 0.8, 2) : 1)
                    apply(v * (-0.5 * rho * sp * cd * A), at: pw)
                }
            }
        }

        // --- propulsion
        var liquid = 0.0; for i in 0..<np where P[i].type == .tank { liquid += P[i].fuel }
        var liquidUse = 0.0
        for i in 0..<np {
            P[i].thrustNow = 0
            switch P[i].type {
            case .prop:
                let thr: Double = P[i].autoMotor ? P[i].out : (P[i].motor.map { clamp(P[$0].out, -1, 1) } ?? 0)
                let dir = q.act(P[i].effQ.act([1, 0, 0])), pw = origin + q.act(P[i].basePos)
                let inflowWind = windHere + wakeView.velocity(at: pw, exclude: i)   // other rotors' wakes
                let vax = simd_dot(pointVel(pw) - inflowWind, dir)
                let P0 = P[i].kPropPower * abs(thr) * (rho / 1.225)
                let slip = slipstream && air
                // A duct (exit area = disk area) carries part of the thrust: same power as an open rotor of √2× diameter.
                let dEff = max(0.1, P[i].kD) * (slip && P[i].kDucted ? 2.0.squareRoot() : 1)
                let r = Propulsion.propThrust(power: P0, diameter: dEff, rho: max(rho, 1e-6), axialSpeed: thr >= 0 ? vax : -vax, pitchSpeed: P[i].kPropVmax)
                var Tn = (thr >= 0 ? 1 : -0.5) * r.thrust
                if slip && Tn > 0 {
                    Tn *= WakeField.groundEffectGain(height: pw.y - groundHeight(env, pw.x, pw.z), radius: max(0.05, P[i].kD / 2), wakeDown: dir.y)
                    let Rd = max(0.05, P[i].kD / 2)
                    P[i].vi = WakeField.diskVelocity(thrust: Tn, rho: rho, area: Double.pi * Rd * Rd, axial: vax, ducted: P[i].kDucted)
                } else { P[i].vi = 0 }
                apply(dir * Tn, at: pw)
                let targetOmega = 2 * Double.pi * r.rps * abs(thr) * (thr >= 0 ? 1 : -1) * P[i].kSpin  // spin: +1 / -1 rotation sense; flips reaction torque
                P[i].omega += (targetOmega - P[i].omega) * min(1, h / 0.4)
                P[i].spinAngle = (P[i].spinAngle + P[i].omega * h).truncatingRemainder(dividingBy: 2 * Double.pi)
                if abs(P[i].omega) > 1 {
                    // Full shaft reaction torque on the airframe when the wake swirl is modelled (surfaces in the
                    // slipstream recover part of it); the old isolated model used a fixed 25 %.
                    if slip {
                        // Shaft torque at the operating point (target speed): while the rotor spins up, the surplus
                        // torque accelerates the rotor itself rather than twisting the airframe or the air.
                        let Q = abs(targetOmega) > 1 ? P0 * 0.75 / abs(targetOmega) : 0
                        P[i].wakeQ = Q
                        T -= dir * (Q * (P[i].omega >= 0 ? 1 : -1))
                    } else {
                        P[i].wakeQ = 0
                        T -= dir * (P0 * 0.75 / P[i].omega) * 0.25
                    }
                } else { P[i].wakeQ = 0 }
                P[i].thrustNow = abs(Tn); thrustTotal += abs(Tn)
            case .jet:
                let cmd = liquid > 0 ? clamp(P[i].out, 0, 1) : 0
                P[i].spool = Propulsion.spool(P[i].spool, command: cmd, dt: h)
                if liquid > 0 && P[i].spool > 0.01 {
                    let dir = q.act(P[i].effQ.act([1, 0, 0])), pw = origin + q.act(P[i].basePos)
                    let M = simd_length(velocity - windHere) / atm.speedOfSound
                    let Tn = P[i].kThrust * P[i].spool * Propulsion.jetLapse(rho: rho, mach: M)
                    apply(dir * Tn, at: pw)
                    liquidUse += P[i].kFlow * (0.05 + 0.95 * P[i].spool) * h * (rho / 1.225 * 0.5 + 0.5)
                    P[i].thrustNow = Tn; thrustTotal += Tn
                }
                P[i].spinAngle += P[i].spool * 300 * h
            case .solid:
                if !P[i].burning && P[i].out > 0.5 && P[i].fuel > 0 { P[i].burning = true; P[i].ignitedAt = time }
                if P[i].burning {
                    let dir = q.act(P[i].effQ.act([1, 0, 0])), pw = origin + q.act(P[i].basePos)
                    let frac = P[i].fuel / max(P[i].fuelCapacity, 1e-9)
                    let k = Propulsion.solidProfile(fuelFraction: frac, sinceIgnition: time - P[i].ignitedAt, ambientPressure: atm.pressure)
                    let Tn = P[i].kThrust * k
                    apply(dir * Tn, at: pw)
                    // mass flow ∝ thrust so total impulse = thrust × burn
                    P[i].fuel -= P[i].fuelCapacity / max(P[i].kBurn, 1e-3) * k * h
                    if P[i].fuel <= 0 { P[i].fuel = 0; P[i].burning = false }
                    P[i].thrustNow = Tn; thrustTotal += Tn
                }
            default: break
            }
        }
        var massDirty = false
        if liquidUse > 0 && liquid > 0 {
            let k = max(0, 1 - liquidUse / liquid)
            for i in 0..<np where P[i].type == .tank { P[i].fuel *= k }
            massDirty = true
        }
        for i in 0..<np where P[i].burning { massDirty = true; break }

        // --- gravity
        F += env.gravity * mass

        // --- ground: rigid bounding-box corners (penalty spring-damper + Coulomb friction)
        if groundEnabled {
            // Gains are per craft; split them across the corners currently penetrating so total
            // stiffness/damping does not scale with contact count (explicit stability: h*cB_tot/m <= 0.04).
            var nContact = 0
            var anyContact = false
            // Conservative clearance: every corner / wheel contact point lies within `contactRadius` of the
            // craft origin; when that sphere is above the terrain's maximum height (TerrainProvider.bounds)
            // no ground query can report contact, so all of them are skipped. Exact: a skipped corner would
            // have failed `pw.y < gh` anyway.
            let ceiling = env.terrain.map { $0.bounds.max.y } ?? 0
            let clear = origin.y - contactRadius > ceiling + 1
            if let CF, !clear {
                let tmp = cornerTmp!
                for i in 0..<np where P[i].cornerCount > 0 {
                    let qp = q * P[i].effQ, op = origin + q.act(P[i].basePos)
                    let c0 = P[i].cornerStart
                    for k in c0..<(c0 + P[i].cornerCount) {
                        let pw = op + qp.act(CF[k]), gh = groundHeight(env, pw.x, pw.z)
                        tmp[k] = SIMD4(pw, gh)
                        if pw.y < gh { nContact += 1 }
                    }
                }
                let share = 1.0 / Double(max(1, nContact))
                let kB = mass * 2000 * share, cB = mass * 60 * share
                for k in 0..<cornerFlat.count {   // same part/corner order as above (cornerFlat is part-ordered)
                    let t = tmp[k]
                    let pw = Vec3d(t.x, t.y, t.z), gh = t.w
                    if pw.y >= gh { continue }
                    let n = groundNormal(env, pw.x, pw.z)
                    let pen = (gh - pw.y) * n.y
                    let vp = pointVel(pw)
                    let vn = simd_dot(vp, n)
                    anyContact = true
                    if -vn > maxImpactSpeed { maxImpactSpeed = -vn }
                    if -vn > crashSpeed { crashed = true }
                    let N = max(0, pen * kB - vn * cB); if N <= 0 { continue }
                    let mu = env.terrain?.material(x: pw.x, z: pw.z).friction ?? 0.6
                    let vt = vp - n * vn, vts = simd_length(vt)
                    var f = n * N
                    if vts > 1e-4 { f -= vt * (min(mu * N, vts * cB) / vts) }
                    apply(f, at: pw)
                }
            }
            // --- wheels: suspension + Pacejka-lite tyre with implicit wheel-spin DOF
            let nW = max(1, wheelCount)
            let kW = mass * kGravity / (Double(nW) * 0.08)
            let cW = 2 * 0.6 * (kW * mass / Double(nW)).squareRoot()
            for i in 0..<np where P[i].type == .wheel {
                let r = max(0.02, P[i].kR), Iw = max(0.05, 0.5 * P[i].docMass * r * r)
                let hub = origin + q.act(P[i].basePos)
                let axle = q.act(P[i].effQ.act([0, 0, 1]))
                var omega = P[i].omega
                var contact = false
                var motorT = 0.0
                if P[i].autoMotor { motorT = Self.autoWheelTorque * clamp(P[i].out, -1, 1) }
                else if let m = P[i].motor {
                    let lo = P[m].kReversible != 0 ? -1.0 : 0
                    motorT = P[m].kTorque * clamp(P[m].out, lo, 1)
                    let vmax = P[m].kMotorVmax
                    motorT *= clamp(1 - (omega * r * (motorT >= 0 ? 1 : -1)) / max(vmax, 0.1), 0, 1)
                }
                let n = clear ? Vec3d(0, 1, 0) : groundNormal(env, hub.x, hub.z)
                var down = -n + axle * simd_dot(axle, n)
                if !clear && simd_length_squared(down) > 1e-4 {
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
                        let mu = P[i].kGrip * mat.friction / 0.9
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
                        let roll = -clamp(vf * 4, -1, 1) * P[i].kRoll * mat.rollingResistance * N
                        apply(n * N + fwd * (fx + roll) + lat * fy, at: cp)
                        P[i].compression = pen
                        if let s = P[i].servo { P[s].load += abs(fy) * 0.04 }
                    }
                }
                if !contact { omega += h * motorT / Iw; omega *= (1 - 0.2 * h) }
                P[i].omega = omega; P[i].contact = contact
                if contact { anyContact = true }
                P[i].spinAngle = (P[i].spinAngle + omega * h).truncatingRemainder(dividingBy: 2 * Double.pi)
            }
            groundContact = anyContact
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
        self.velocity += F / mass * h
        self.position += (vOld + self.velocity) * (0.5 * h)
        angularMomentum += T * h
        let w0 = omegaWorld(orientation)
        let qHalf = Self.rotate(orientation, by: w0, dt: h * 0.5)
        let wHalf = omegaWorld(qHalf)
        orientation = Self.rotate(orientation, by: wHalf, dt: h)
        time += h; stepCounter += 1
        lastForce = F - env.gravity * mass

        var fuel = 0.0; for i in 0..<np { fuel += P[i].fuel }
        out.massDirty = massDirty; out.stalled = stalledCount; out.thrust = thrustTotal; out.fuel = fuel
        out.windHere = windHere; out.ground = groundUnder; out.atm = atm
        return out
    }

    @inline(__always) static func rotate(_ q: Quatd, by w: Vec3d, dt: Double) -> Quatd {
        let a = simd_length(w) * dt
        if a < 1e-15 { return q }
        return (Quatd(angle: a, axis: w / simd_length(w)) * q).normalized
    }

    func updateTelemetry(env: SimEnvironment, atm: Atmosphere, windHere: Vec3d, stalled: Int, thrust: Double, ground: Double, fuel: Double) {
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
        t.fuelKg = fuel
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

extension CraftSim {
    /// Independent copy sharing nothing mutable (CAD panel meshes are deep-copied). Cheaper than `load`
    /// (no JSON/param parsing, no hull rebuild). The copy keeps the current state; call `reset` as needed.
    public func clone() -> CraftSim {
        let c = CraftSim()
        c.substepHz = substepHz; c.aeroEnabled = aeroEnabled; c.groundEnabled = groundEnabled
        c.slipstream = slipstream
        c.turbulence = turbulence; c.stripsPerWing = stripsPerWing; c.parallelThreshold = parallelThreshold
        c.craft = craft; c.outputs = outputs; c.telemetry = telemetry
        c.parts = parts
        for i in c.parts.indices { if let m = c.parts[i].mesh { c.parts[i].mesh = m.deepCopy() } }
        c.rebuildPanelBatch()
        c.cornerFlat = cornerFlat; c.contactRadius = contactRadius
        c.cornerTmp = .allocate(capacity: max(1, cornerFlat.count))
        c.allocWakes()
        c.strips = strips; c.outputTargets = outputTargets; c.outputTargetCache = outputTargetCache
        c.mass = mass; c.comLocal = comLocal; c.inertia = inertia; c.inertiaInv = inertiaInv
        c.position = position; c.orientation = orientation; c.velocity = velocity; c.angularMomentum = angularMomentum
        c.time = time; c.stepCounter = stepCounter; c.lastForce = lastForce
        c.hull = hull; c.boundingRadius = boundingRadius
        c.wheelCount = wheelCount; c.crashSpeed = crashSpeed; c.crashed = crashed; c.groundContact = groundContact
        c.maxImpactSpeed = maxImpactSpeed
        c.inputs = inputs; c.sensorSlots = sensorSlots; c.noiseState = noiseState; c.sensorNoiseSeed = sensorNoiseSeed
        return c
    }
}

/// Source compatibility with the architect's stub name (App wires `StubCraftSimulation()`).
public typealias StubCraftSimulation = CraftSim

/// Wing-strip evaluation context (value type over raw pointers so the serial path allocates nothing and
/// does no ARC traffic: it never copies a SimPart).
struct StripJob {
    let buf: UnsafeMutablePointer<StripResult>
    let parts: UnsafeMutablePointer<SimPart>, strips: UnsafePointer<WingStrip>
    let q: Quatd, origin: Vec3d, wW: Vec3d, pos: Vec3d, vel: Vec3d
    let sos: Double, rho: Double, nu: Double
    let wind: WindField.Prepared
    let wakes: WakeView

    func run(_ range: Range<Int>, terrain: (any TerrainProvider)?) {
        // Per-part frame, reused by consecutive strips of the same wing (strips are part-ordered).
        // Same expressions as the per-strip form, so bit-identical.
        var lastPart = -1
        var nrm = Vec3d.zero, c = Vec3d.zero, s = Vec3d.zero, pacBase = Vec3d.zero
        var chord = 0.0, span = 0.0, flapChord = 0.0, flapDelta = 0.0, hasServo = false
        var wing = Aero.WingConst.zero
        var geSpan = 0.0
        for si in range {
            let st = strips[si]
            if st.part != lastPart {
                lastPart = st.part
                let p = UnsafePointer(parts + st.part)
                let qw = q * p.pointee.effQ
                nrm = qw.act([0, 1, 0]); c = qw.act([1, 0, 0]); s = qw.act([0, 0, 1])
                chord = p.pointee.kChord; span = p.pointee.kSpan
                pacBase = origin + q.act(p.pointee.basePos) + c * (chord * 0.25)
                flapChord = p.pointee.flapChord
                let servo = p.pointee.servo; hasServo = servo != nil
                flapDelta = 0
                if flapChord > 0, let sv = servo { flapDelta = parts[sv].angle * (p.pointee.invert ? -1 : 1) }
                wing = p.pointee.wing
                geSpan = max(2 * span, chord)
            }
            let pac = pacBase + s * st.spanOffset
            let gh = terrain?.height(x: pac.x, z: pac.z) ?? 0
            var wl = wind.velocity(at: pac, heightAGL: pac.y - gh)
            if wakes.count > 0 { wl += wakes.velocity(at: pac) }
            var a3 = -(vel + simd_cross(wW, pac - pos) - wl)       // relative airflow
            a3 -= s * simd_dot(a3, s)
            let sp = simd_length(a3)
            if sp < 0.3 { buf[si] = StripResult(); continue }
            let alpha = atan2(simd_dot(a3, nrm), -simd_dot(a3, c))
            let ge = Aero.groundEffect(height: pac.y - gh, span: geSpan)
            let co = Aero.wing(alpha: alpha, mach: sp / sos, reynolds: sp * chord / nu, const: wing, flapDeflection: flapDelta,
                               groundEffectInduced: ge.phi, groundLiftGain: ge.liftGain)
            let qS = 0.5 * rho * sp * sp * st.area
            let dd = a3 / sp
            let ld = simd_normalize(simd_cross(dd, s))
            let f = ld * (co.cl * qS) + dd * (co.cd * qS)
            let pcp = pac + c * (chord * (0.25 - co.centerOfPressure))
            var hinge = 0.0
            if hasServo {
                if flapChord > 0 { let cf = flapChord * chord; hinge = abs(co.hingeCh) * 0.5 * rho * sp * sp * st.area * flapChord * cf }
                else { hinge = simd_length(f) * 0.12 * chord + abs(co.cl) * qS * 0.02 }   // prototype hinge-load model
            }
            buf[si] = StripResult(ft: ForceTorque(force: f, torque: simd_cross(pcp - pos, f)), hinge: hinge,
                                  stalled: co.stalled, bigStall: co.stalled && span * chord > 2)
        }
    }
}

extension CraftSim {
    /// CraftSimBatch support: write a lane's body state back into this sim (setters are private to this file).
    func batchStore(position p: Vec3d, orientation q: Quatd, velocity v: Vec3d, angularMomentum L: Vec3d, time t: Double,
                    crashed c: Bool, groundContact g: Bool, maxImpactSpeed m: Double) {
        position = p; orientation = q; velocity = v; angularMomentum = L; time = t
        crashed = c; groundContact = g; maxImpactSpeed = m
    }
    /// CraftSimBatch support: mass properties recomputed by `updateMassProperties` read back by the batch.
    var batchMassProperties: (mass: Double, comLocal: Vec3d, inertiaInv: Mat3d) { (mass, comLocal, inertiaInv) }
}
