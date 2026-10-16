// OWNED BY aero/physics builder.
// CraftSimBatch: K craft simulations of the SAME topology stepped in lockstep, one SIMD lane per candidate.
//
// Layout: structure-of-arrays across candidates. Every per-part / per-body quantity is a `V` (SIMD2/4/8 of
// Double), so one instruction advances K candidates. Per-candidate numeric parameters (design genes: masses,
// spans, thrusts, positions, …) are ordinary lane data; only the topology (part count and types, servo / motor
// links, corners, wing strips, CAD-mesh presence) must match across lanes (`CraftSimBatch.Topology`).
//
// Bit-exactness: every lane reproduces `CraftSim.substepCore` operation for operation (same order, same FMA
// contraction as the scalar release build, Swift.min/max/clamp operand order, signed zeros), so a lane's state
// is bit-identical to the scalar sim it mirrors. Branches become masked selects; work that is not lane-parallel
// or whose scalar implementation cannot be matched by vector code runs per lane with the scalar functions:
//   * transcendentals (sin, atan, atan2, pow, log, log10, fmod) — vector libm differs in the last ulp,
//   * world queries (terrain height / normal / material / bounds, water sample + buoyancy),
//   * CAD panel aero (the lane's own PanelMesh / PanelBatch), the turbulent wind field (12 sin per sample),
//   * mass-property refresh (every 10 substeps while fuel burns: `CraftSim.updateMassProperties`).
// Lanes that are not attached are not updated and never reach a per-lane scalar call.
//
// Ownership: each lane is bound to a regular `CraftSim` (`attach`). The batch owns the lane's physics state
// while attached; after every `step` it writes the state (body, parts, telemetry) back into the lane sim, so
// sensors, snapshots, obstacles and controllers keep using the ordinary scalar API. Before every `step` it
// reads back what callers may change between steps: outputs (`setOutput`), `crashed` / `maxImpactSpeed`
// (`markObstacleHit`) and `turbulence`.
import Foundation
import simd
import PWCore
import PWCollision

public final class CraftSimBatch {
    /// Everything that must be identical across lanes (numeric parameters may differ).
    public struct Topology: Equatable {
        var types: [Int8] = [], servo: [Int] = [], motor: [Int] = [], autoMotor: [Bool] = [], isBody: [Bool] = []
        var hasMesh: [Bool] = [], cornerCount: [Int] = [], stripPart: [Int] = []
        var wheelCount = 0, substepHz = 0.0, aeroEnabled = true, groundEnabled = true, outputCount = 0
        init(_ s: CraftSim) {
            for p in s.parts {
                types.append(p.type.map { Int8(PartType.allCases.firstIndex(of: $0) ?? 99) } ?? -1)
                servo.append(p.servo ?? -1); motor.append(p.motor ?? -1); autoMotor.append(p.autoMotor); isBody.append(p.isBody)
                hasMesh.append(p.meshSlot >= 0); cornerCount.append(p.cornerCount)
            }
            stripPart = s.strips.map(\.part)
            wheelCount = s.wheelCount; substepHz = s.substepHz; aeroEnabled = s.aeroEnabled; groundEnabled = s.groundEnabled
            outputCount = s.outputs.count
        }
    }

    public let lanes: Int
    public let topology: Topology
    public private(set) var sims: [CraftSim?]
    let impl: BatchImplBase

    /// Lane counts with a SIMD implementation.
    public static let supportedLanes = [2, 4, 8]

    /// `lanes` ∈ supportedLanes. `template` fixes the topology (it is not attached).
    public init(lanes: Int, template: CraftSim) {
        precondition(Self.supportedLanes.contains(lanes), "CraftSimBatch supports 2, 4 or 8 lanes")
        self.lanes = lanes
        topology = Topology(template)
        sims = Array(repeating: nil, count: lanes)
        switch lanes {
        case 2: impl = BatchLanes2(template)
        case 4: impl = BatchLanes4(template)
        default: impl = BatchLanes8(template)
        }
    }

    /// Features of `sim` the batch path cannot run (empty = fully supported). Currently only crafts without
    /// parts are rejected; every physics feature has a lane implementation or a per-lane scalar fallback.
    public static func unsupportedFeatures(_ sim: CraftSim) -> [String] {
        var r: [String] = []
        if sim.parts.isEmpty { r.append("empty craft") }
        return r
    }

    /// True when `sim` has the batch's topology (so it can be attached).
    public func compatible(_ sim: CraftSim) -> Bool { Topology(sim) == topology }
    public var attachedCount: Int { sims.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }

    /// Bind `sim` to `lane`, copying its parameters and full current state (call after reset / setVelocity).
    public func attach(_ sim: CraftSim, lane: Int) {
        precondition(compatible(sim), "CraftSimBatch.attach: topology mismatch")
        sims[lane] = sim
        impl.attach(sim, lane: lane)
    }
    /// Unbind a lane (its sim keeps the state of the last step).
    public func detach(lane: Int) { sims[lane] = nil; impl.detach(lane: lane) }

    /// Advance every attached lane by `dt` (same substep split as `CraftSim.step`). `envs[lane]` is the lane's
    /// environment (terrain / water / wind / gravity / time); entries of unattached lanes are ignored.
    /// Allocation-free.
    public func step(dt: Double, envs: UnsafePointer<SimEnvironment>) {
        guard dt > 0 else { return }
        impl.step(dt: dt, envs: envs, sims: sims)
    }
}

/// Type-erased lane implementation.
class BatchImplBase {
    func attach(_ sim: CraftSim, lane: Int) {}
    func detach(lane: Int) {}
    func step(dt: Double, envs: UnsafePointer<SimEnvironment>, sims: [CraftSim?]) {}
}

// Concrete (non-generic) forwarding shells. Virtual calls into a generic class run its UNSPECIALISED body
// (protocol-witness SIMD ops, ~100x slower), so the hot code lives in the non-polymorphic `BatchCore<V>` and is
// called from these shells with a concrete `V`: the optimiser specialises and inlines it for SIMD2/4/8.
final class BatchLanes2: BatchImplBase {
    let core: BatchCore<SIMD2<Double>>
    init(_ s: CraftSim) { core = BatchCore(s) }
    override func attach(_ sim: CraftSim, lane: Int) { core.attach(sim, lane: lane) }
    override func detach(lane: Int) { core.detach(lane: lane) }
    override func step(dt: Double, envs: UnsafePointer<SimEnvironment>, sims: [CraftSim?]) { core.step(dt: dt, envs: envs, sims: sims) }
}
final class BatchLanes4: BatchImplBase {
    let core: BatchCore<SIMD4<Double>>
    init(_ s: CraftSim) { core = BatchCore(s) }
    override func attach(_ sim: CraftSim, lane: Int) { core.attach(sim, lane: lane) }
    override func detach(lane: Int) { core.detach(lane: lane) }
    override func step(dt: Double, envs: UnsafePointer<SimEnvironment>, sims: [CraftSim?]) { core.step(dt: dt, envs: envs, sims: sims) }
}
final class BatchLanes8: BatchImplBase {
    let core: BatchCore<SIMD8<Double>>
    init(_ s: CraftSim) { core = BatchCore(s) }
    override func attach(_ sim: CraftSim, lane: Int) { core.attach(sim, lane: lane) }
    override func detach(lane: Int) { core.detach(lane: lane) }
    override func step(dt: Double, envs: UnsafePointer<SimEnvironment>, sims: [CraftSim?]) { core.step(dt: dt, envs: envs, sims: sims) }
}

/// Optional fast path for terrains: many heights in one call (bit-identical to `height(x:z:)` per point). The
/// batch otherwise pays an existential dispatch + retain/release per query (72 corners × lanes per substep).
public protocol TerrainBulkHeights: AnyObject {
    func heights(xs: UnsafePointer<Double>, zs: UnsafePointer<Double>, into out: UnsafeMutablePointer<Double>, count: Int)
}

/// F += f; T += (pw - com) × f
@inline(__always) func bApply<V: LaneVec>(_ F: inout BV3<V>, _ T: inout BV3<V>, _ f: BV3<V>, _ pw: BV3<V>, _ com: BV3<V>) {
    F += f; T += bcross(pw - com, f)
}
/// The same for the lanes in `m` only (others unchanged, not even +0).
@inline(__always) func bApplyM<V: LaneVec>(_ F: inout BV3<V>, _ T: inout BV3<V>, _ m: SIMDMask<V.MaskStorage>, _ f: BV3<V>, _ pw: BV3<V>, _ com: BV3<V>) {
    F = BV3.sel(m, F + f, F); T = BV3.sel(m, T + bcross(pw - com, f), T)
}
/// Velocity of a world point of the body.
@inline(__always) func bPointVel<V: LaneVec>(_ v: BV3<V>, _ w: BV3<V>, _ pw: BV3<V>, _ com: BV3<V>) -> BV3<V> { v + bcross(w, pw - com) }

/// Per-lane world references (see BatchCore.lw).
struct LaneWorld {
    unowned(unsafe) var terrain: (any TerrainProvider)? = nil
    unowned(unsafe) var bulk: (any TerrainBulkHeights)? = nil
    unowned(unsafe) var water: (any WaterProvider)? = nil
    var gravity = Vec3d.zero, wind = Vec3d.zero, ceiling = 0.0
}

/// Per-part lane data (structure of arrays across candidates).
struct BPart<V: LaneVec> {
    // constants (per lane)
    var docMass = V(), kRange = V(), kTorque = V(), kSpeed = V(), kCd = V(), kThrust = V(), kD = V(), kPropVmax = V()
    var kFlow = V(), kBurn = V(), kR = V(), kGrip = V(), kRoll = V(), kReversible = V(), kMotorVmax = V()
    var kChord = V(), kSpan = V(), invSign = V(), flapChord = V(), fuelCapacity = V(), kPropPower = V()
    var basePos = BV3<V>.zero, ctr = BV3<V>.zero, size = BV3<V>.zero, servoAxisBase = BV3<V>.zero
    var baseQ = BQ<V>.identity, baseQN = BQ<V>.identity
    // wing constants (Aero.WingConst)
    var wCamber = V(), wFlapFrac = V(), wLiftNum = V(), wAA = V(), wStallThick = V(), wThickFactor = V()
    var wInducedDen = V(), wMcritBase = V(), wFlapTau = V(), wFlapCd = V()
    // state
    var out = V(), angle = V(), load = V(), loadShown = V(), overload = V(), spinAngle = V(), omega = V()
    var thrustNow = V(), burning = V(), ignitedAt = V(), spool = V(), fuel = V(), compression = V(), contact = V()
    var effQ = BQ<V>.identity
}

final class BatchCore<V: LaneVec> {
    typealias M = SIMDMask<V.MaskStorage>
    @inline(__always) var K: Int { V.scalarCount }   // compile-time constant after specialisation: lane loops unroll
    let np: Int, ns: Int, nc: Int
    // uniform topology
    let ptype: [PartType?], pservo: [Int], pmotor: [Int], pauto: [Bool], pbody: [Bool], pmesh: [Bool]
    let pcStart: [Int], pcCount: [Int], stripPart: [Int]
    let wheelCount: Int, substepHz: Double, aeroEnabled: Bool, groundEnabled: Bool
    let servoIdx: [Int], wheelIdx: [Int], tankIdx: [Int], propulsionIdx: [Int], bodyIdx: [Int], wingRuns: [(part: Int, lo: Int, hi: Int)]
    let servoFlap: [Int]          // parts with a servo (effQ depends on it)
    let cornerParts: [Int]
    // lane data
    let P: UnsafeMutablePointer<BPart<V>>
    let stripOff: UnsafeMutablePointer<V>, stripArea: UnsafeMutablePointer<V>
    let CF: UnsafeMutablePointer<BV3<V>>, cTmp: UnsafeMutablePointer<BV3<V>>, cGh: UnsafeMutablePointer<V>
    var position = BV3<V>.zero, velocity = BV3<V>.zero, angularMomentum = BV3<V>.zero, lastForce = BV3<V>.zero
    var orientation = BQ<V>.identity
    var time = V(), crashed = V(), groundContact = V(), maxImpactSpeed = V()
    var mass = V(repeating: 1), comLocal = BV3<V>.zero, inertiaInv = BM3<V>.zero
    var crashSpeed = V(), turbulence = V(), contactRadius = V(), boundingRadius = V()
    var stepCounter: [Int]
    var live: [Bool]
    var liveMask: M = M(repeating: false)
    // per-step values for the telemetry of the last substep
    var tAtm: [Atmosphere] = [], tWind = BV3<V>.zero, tStalled = V(), tThrust = V(), tGround = V(), tFuel = V()

    init(_ s: CraftSim) {
        np = s.parts.count; ns = s.strips.count; nc = s.cornerFlat.count
        ptype = s.parts.map(\.type); pservo = s.parts.map { $0.servo ?? -1 }; pmotor = s.parts.map { $0.motor ?? -1 }
        pauto = s.parts.map(\.autoMotor); pbody = s.parts.map(\.isBody); pmesh = s.parts.map { $0.meshSlot >= 0 }
        pcStart = s.parts.map(\.cornerStart); pcCount = s.parts.map(\.cornerCount); stripPart = s.strips.map(\.part)
        wheelCount = s.wheelCount; substepHz = s.substepHz; aeroEnabled = s.aeroEnabled; groundEnabled = s.groundEnabled
        servoIdx = s.parts.indices.filter { s.parts[$0].type == .servo }
        wheelIdx = s.parts.indices.filter { s.parts[$0].type == .wheel }
        tankIdx = s.parts.indices.filter { s.parts[$0].type == .tank }
        propulsionIdx = s.parts.indices.filter { [.prop, .jet, .solid].contains(s.parts[$0].type) }
        bodyIdx = s.parts.indices.filter { s.parts[$0].isBody }
        servoFlap = s.parts.indices.filter { s.parts[$0].servo != nil }
        cornerParts = s.parts.indices.filter { s.parts[$0].cornerCount > 0 }
        var runs: [(Int, Int, Int)] = []
        var lo = 0
        while lo < s.strips.count { var hi = lo; while hi < s.strips.count && s.strips[hi].part == s.strips[lo].part { hi += 1 }; runs.append((s.strips[lo].part, lo, hi)); lo = hi }
        wingRuns = runs.map { (part: $0.0, lo: $0.1, hi: $0.2) }
        P = .allocate(capacity: max(1, np)); P.initialize(repeating: BPart<V>(), count: max(1, np))
        stripOff = .allocate(capacity: max(1, ns)); stripOff.initialize(repeating: V(), count: max(1, ns))
        stripArea = .allocate(capacity: max(1, ns)); stripArea.initialize(repeating: V(), count: max(1, ns))
        CF = .allocate(capacity: max(1, nc)); CF.initialize(repeating: .zero, count: max(1, nc))
        cTmp = .allocate(capacity: max(1, nc)); cTmp.initialize(repeating: .zero, count: max(1, nc))
        cGh = .allocate(capacity: max(1, nc)); cGh.initialize(repeating: V(), count: max(1, nc))
        stepCounter = Array(repeating: 0, count: V.scalarCount)
        live = Array(repeating: false, count: V.scalarCount)
        windPrep = .allocate(capacity: V.scalarCount); windPrep.initialize(repeating: WindField.Prepared(WindField(), time: 0), count: V.scalarCount)
        lw = .allocate(capacity: V.scalarCount); lw.initialize(repeating: LaneWorld(), count: V.scalarCount)
        let nq = max(1, ns, nc)
        qx = .allocate(capacity: nq); qz = .allocate(capacity: nq); qh = .allocate(capacity: nq)
        qx.initialize(repeating: 0, count: nq); qz.initialize(repeating: 0, count: nq); qh.initialize(repeating: 0, count: nq)
        sPac = .allocate(capacity: max(1, ns)); sPac.initialize(repeating: .zero, count: max(1, ns))
        sGh = .allocate(capacity: max(1, ns)); sGh.initialize(repeating: V(), count: max(1, ns))
        tAtm = Array(repeating: Atmosphere.isa(altitude: 0), count: V.scalarCount)
    }
    deinit {
        P.deinitialize(count: max(1, np)); P.deallocate(); stripOff.deallocate(); stripArea.deallocate()
        CF.deallocate(); cTmp.deallocate(); cGh.deallocate()
        windPrep.deinitialize(count: K); windPrep.deallocate(); lw.deinitialize(count: K); lw.deallocate()
        qx.deallocate(); qz.deallocate(); qh.deallocate(); sPac.deallocate(); sGh.deallocate()
    }

    func updateLiveMask() { var m = M(repeating: false); for l in 0..<K { m[l] = live[l] }; liveMask = m }

    // MARK: attach / detach / sync

    func attach(_ s: CraftSim, lane l: Int) {
        for i in 0..<np {
            let sp = s.parts[i]
            P[i].docMass[l] = sp.docMass; P[i].kRange[l] = sp.kRange; P[i].kTorque[l] = sp.kTorque; P[i].kSpeed[l] = sp.kSpeed
            P[i].kCd[l] = sp.kCd; P[i].kThrust[l] = sp.kThrust; P[i].kD[l] = sp.kD; P[i].kPropVmax[l] = sp.kPropVmax
            P[i].kFlow[l] = sp.kFlow; P[i].kBurn[l] = sp.kBurn; P[i].kR[l] = sp.kR; P[i].kGrip[l] = sp.kGrip; P[i].kRoll[l] = sp.kRoll
            P[i].kReversible[l] = sp.kReversible; P[i].kMotorVmax[l] = sp.kMotorVmax; P[i].kChord[l] = sp.kChord; P[i].kSpan[l] = sp.kSpan
            P[i].invSign[l] = sp.invert ? -1 : 1; P[i].flapChord[l] = sp.flapChord; P[i].fuelCapacity[l] = sp.fuelCapacity
            P[i].kPropPower[l] = sp.kPropPower
            P[i].basePos[lane: l] = sp.basePos; P[i].ctr[lane: l] = sp.ctr; P[i].size[lane: l] = sp.size; P[i].servoAxisBase[lane: l] = sp.servoAxisBase
            P[i].baseQ[lane: l] = sp.baseQ; P[i].baseQN[lane: l] = sp.baseQN
            let w = sp.wing
            P[i].wCamber[l] = w.params.camberCl0; P[i].wFlapFrac[l] = w.params.flapChordFraction; P[i].wLiftNum[l] = w.liftNum; P[i].wAA[l] = w.AA
            P[i].wStallThick[l] = w.stallThick; P[i].wThickFactor[l] = w.thickFactor; P[i].wInducedDen[l] = w.inducedDen
            P[i].wMcritBase[l] = w.mcritBase; P[i].wFlapTau[l] = w.flapTau; P[i].wFlapCd[l] = w.flapCd
            P[i].out[l] = sp.out; P[i].angle[l] = sp.angle; P[i].load[l] = sp.load; P[i].loadShown[l] = sp.loadShown
            P[i].overload[l] = sp.overload ? 1 : 0; P[i].spinAngle[l] = sp.spinAngle; P[i].omega[l] = sp.omega
            P[i].thrustNow[l] = sp.thrustNow; P[i].burning[l] = sp.burning ? 1 : 0; P[i].ignitedAt[l] = sp.ignitedAt
            P[i].spool[l] = sp.spool; P[i].fuel[l] = sp.fuel; P[i].compression[l] = sp.compression; P[i].contact[l] = sp.contact ? 1 : 0
            P[i].effQ[lane: l] = sp.effQ
        }
        for k in 0..<ns { stripOff[k][l] = s.strips[k].spanOffset; stripArea[k][l] = s.strips[k].area }
        for k in 0..<nc { CF[k][lane: l] = s.cornerFlat[k] }
        position[lane: l] = s.position; velocity[lane: l] = s.velocity; angularMomentum[lane: l] = s.angularMomentum
        lastForce[lane: l] = s.lastForce; orientation[lane: l] = s.orientation
        time[l] = s.time; crashed[l] = s.crashed ? 1 : 0; groundContact[l] = s.groundContact ? 1 : 0; maxImpactSpeed[l] = s.maxImpactSpeed
        mass[l] = s.mass; comLocal[lane: l] = s.comLocal; inertiaInv[lane: l] = s.inertiaInv
        crashSpeed[l] = s.crashSpeed; turbulence[l] = s.turbulence; contactRadius[l] = s.contactRadius; boundingRadius[l] = s.boundingRadius
        stepCounter[l] = s.stepCounter
        live[l] = true; updateLiveMask()
    }

    func detach(lane l: Int) { live[l] = false; updateLiveMask() }

    /// Inputs callers may change between steps.
    @inline(__always) func syncIn(_ s: CraftSim, _ l: Int) {
        s.parts.withUnsafeBufferPointer { sp in for i in 0..<np { P[i].out[l] = sp[i].out } }
        crashed[l] = s.crashed ? 1 : 0; maxImpactSpeed[l] = s.maxImpactSpeed; turbulence[l] = s.turbulence
    }
    /// Lane state → lane sim.
    @inline(__always) func syncOut(_ s: CraftSim, _ l: Int) {
        s.batchStore(position: position[lane: l], orientation: orientation[lane: l], velocity: velocity[lane: l],
                     angularMomentum: angularMomentum[lane: l], time: time[l], crashed: crashed[l] != 0,
                     groundContact: groundContact[l] != 0, maxImpactSpeed: maxImpactSpeed[l])
        s.stepCounter = stepCounter[l]; s.lastForce = lastForce[lane: l]
        s.parts.withUnsafeMutableBufferPointer { sp in
            for i in 0..<np {
                sp[i].angle = P[i].angle[l]; sp[i].load = P[i].load[l]; sp[i].loadShown = P[i].loadShown[l]
                sp[i].overload = P[i].overload[l] != 0; sp[i].spinAngle = P[i].spinAngle[l]; sp[i].omega = P[i].omega[l]
                sp[i].thrustNow = P[i].thrustNow[l]; sp[i].burning = P[i].burning[l] != 0; sp[i].ignitedAt = P[i].ignitedAt[l]
                sp[i].spool = P[i].spool[l]; sp[i].fuel = P[i].fuel[l]; sp[i].compression = P[i].compression[l]
                sp[i].contact = P[i].contact[l] != 0; sp[i].effQ = P[i].effQ[lane: l]
            }
        }
    }

    // MARK: stepping

    func step(dt: Double, envs: UnsafePointer<SimEnvironment>, sims: [CraftSim?]) {
        guard np > 0, any(liveMask) else { return }
        for l in 0..<K where live[l] { if let s = sims[l] { syncIn(s, l) } }
        let n = max(1, Int((dt * substepHz - 1e-9).rounded(.up)))
        let h = dt / Double(n)
        var et = V()
        for l in 0..<K where live[l] {
            et[l] = envs[l].time
            let t = envs[l].terrain
            lw[l].terrain = t; lw[l].bulk = t as? TerrainBulkHeights; lw[l].water = envs[l].water; lw[l].gravity = envs[l].gravity; lw[l].wind = envs[l].wind
            lw[l].ceiling = t.map { $0.bounds.max.y } ?? 0   // constant during a step (the scalar path asks every substep)
        }
        for k in 0..<n {
            let tk = et + Double(k) * h      // e.time = env.time + Double(k) * h
            substep(h, envs, tk, sims)
        }
        for l in 0..<K where live[l] {
            guard let s = sims[l] else { continue }
            syncOut(s, l)
            var e = envs[l]; e.time = et[l] + Double(n - 1) * h
            s.updateTelemetry(env: e, atm: tAtm[l],
                              windHere: tWind[lane: l], stalled: Int(tStalled[l]), thrust: tThrust[l], ground: tGround[l], fuel: tFuel[l])
        }
    }

    /// out[k] = terrain height under pts[k] for the lanes in `m` (0 without terrain), bulk when the terrain supports it.
    @inline(__always) func terrainHeights(_ pts: UnsafeMutablePointer<BV3<V>>, _ out: UnsafeMutablePointer<V>, _ n: Int, _ m: M) {
        for l in 0..<K where m[l] {
            if let b = lw[l].bulk {
                for k in 0..<n { qx[k] = pts[k].x[l]; qz[k] = pts[k].z[l] }
                b.heights(xs: qx, zs: qz, into: qh, count: n)
                for k in 0..<n { out[k][l] = qh[k] }
            } else if let t = lw[l].terrain {
                for k in 0..<n { out[k][l] = t.height(x: pts[k].x[l], z: pts[k].z[l]) }
            } else {
                for k in 0..<n { out[k][l] = 0 }
            }
        }
    }

    @inline(__always) func omegaWorld(_ q: BQ<V>) -> BV3<V> {
        let R = bmat(q); return bmul(R, bmul(inertiaInv, bmulT(R, angularMomentum)))
    }

    /// `CraftSim.rotate` per lane: Quatd(angle:axis:) (sin/cos) per lane, the rest in lanes.
    @inline(__always) func rotate(_ q: BQ<V>, _ w: BV3<V>, _ dt: Double) -> BQ<V> {
        let lw = blength(w)
        let a = lw * dt
        let small = a .< 1e-15
        let axis = w / lw
        var r = BQ<V>.identity
        for l in 0..<K where live[l] && !small[l] { r[lane: l] = Quatd(angle: a[l], axis: axis[lane: l]) }
        let res = bqnormalize(bqmul(r, q))
        return BQ.sel(small, q, res)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func substep(_ h: Double, _ envs: UnsafePointer<SimEnvironment>, _ etime: V, _ sims: [CraftSim?]) {
        let live = liveMask
        // --- servos
        for i in servoIdx {
            let tgt = vclamp(P[i].out, -1, 1) * P[i].kRange * kDegF
            let cap = vmax(V(repeating: 1e-3), P[i].kTorque), load = P[i].load
            let a = P[i].angle
            let overload = load .> cap
            let rateA = P[i].kSpeed * kDegF * vmax(V(repeating: 0.05), 1 - 0.8 * load / cap)
            let aA = a + vclamp(tgt - a, vneg(rateA) * h, rateA * h)
            let rateB = P[i].kSpeed * kDegF * vmin(V(repeating: 1), load / cap - 1)
            let aB = a + vclamp(vneg(a), vneg(rateB) * h, rateB * h)
            P[i].angle = vsel(overload, aB, aA); P[i].overload = vsel(overload, 1, 0); P[i].loadShown = load; P[i].load = V()
        }
        // updateEffective (only servo-driven parts change; others keep baseQN)
        for i in servoFlap {
            let s = pservo[i]
            let ang = P[s].angle * P[i].invSign
            var rq = BQ<V>.identity
            for l in 0..<K where live[l] { rq[lane: l] = Quatd(angle: ang[l], axis: P[s].servoAxisBase[lane: l]) }
            let q = bqnormalize(bqmul(rq, P[i].baseQ))
            P[i].effQ = BQ.sel(P[i].flapChord .== 0, q, P[i].baseQN)
        }

        let q = orientation, origin = position - bact(q, comLocal)
        let wW = omegaWorld(q)
        var atmP = V(), rho = V(), sos = V(), nu = V(), groundUnder = V(), windHere = BV3<V>.zero
        for l in 0..<K where live[l] {
            let atm = Atmosphere.isa(altitude: position.y[l])   // = SimEnvironment.atmosphere(at:)
            atmP[l] = atm.pressure; rho[l] = atm.density; sos[l] = atm.speedOfSound; tAtm[l] = atm
            nu[l] = Aero.viscosity(temperature: atm.temperature) / max(atm.density, 1e-9)
            let gu = lw[l].terrain?.height(x: position.x[l], z: position.z[l]) ?? 0
            groundUnder[l] = gu
            let wind = WindField(mean: lw[l].wind, turbulence: turbulence[l])
            windHere[lane: l] = wind.velocity(at: position[lane: l], heightAGL: position.y[l] - gu, time: etime[l])
            windPrep[l] = WindField.Prepared(wind, time: etime[l])
        }
        loadWind(live)
        let position = self.position, velocity = self.velocity
        var F = BV3<V>.zero, T = BV3<V>.zero
        // (force application / point velocity are free functions with explicit inout state: nested functions
        //  capturing `var F, T` get heap-boxed when the optimiser does not inline them, e.g. for SIMD8)
        let air = (rho .> 1e-6) .& (aeroEnabled ? live : M(repeating: false))
        var stalledCount = V(), thrustTotal = V()

        // --- wing strips
        if any(air) && ns > 0 {
            // pass 1: every strip's aerodynamic centre, then the terrain under all of them (one bulk call per lane)
            for run in wingRuns {
                let i = run.part
                let qw = bqmul(q, P[i].effQ)
                let c = bact(qw, BV3(Vec3d(1, 0, 0))), s = bact(qw, BV3(Vec3d(0, 0, 1)))
                let pacBase = origin + bact(q, P[i].basePos) + c * (P[i].kChord * 0.25)
                for si in run.lo..<run.hi { sPac[si] = pacBase + s * stripOff[si] }
            }
            terrainHeights(sPac, sGh, ns, air)
            // pass 2: aerodynamics per strip
            for run in wingRuns {
                let i = run.part
                let qw = bqmul(q, P[i].effQ)
                let nrm = bact(qw, BV3(Vec3d(0, 1, 0))), c = bact(qw, BV3(Vec3d(1, 0, 0))), s = bact(qw, BV3(Vec3d(0, 0, 1)))
                let chord = P[i].kChord, span = P[i].kSpan
                let pacBase = origin + bact(q, P[i].basePos) + c * (chord * 0.25)
                let flapChord = P[i].flapChord
                let sv = pservo[i], hasServo = sv >= 0
                var flapDelta = V()
                if hasServo { flapDelta = vsel(flapChord .> 0, P[sv].angle * P[i].invSign, V()) }
                let geSpan = vmax(2 * span, chord)
                for si in run.lo..<run.hi {
                    let pac = sPac[si], gh = sGh[si]
                    let wl = windAt(pac, pac.y - gh, air)
                    var a3 = -(velocity + bcross(wW, pac - position) - wl)
                    a3 -= s * bdot(a3, s)
                    let sp = blength(a3)
                    let valid = air .& .!(sp .< 0.3)
                    if !any(valid) { continue }   // every lane adds a zero StripResult: F + 0 … see below
                    let ay = bdot(a3, nrm), ax = vneg(bdot(a3, c))
                    let reynolds = sp * chord / nu
                    // Every transcendental of this strip in ONE per-lane scalar block (a single SIMD↔scalar round
                    // trip instead of one per call): atan2, log10, pow, sin exactly as Aero.wing evaluates them.
                    var lb = LibmBlock()
                    for l in 0..<K where valid[l] {
                        let a = atan2(ay[l], ax[l]); lb.alpha[l] = a
                        let re = reynolds[l]
                        let lg = log10(max(re, 1e3)); lb.lr[l] = lg
                        let l4 = re >= 1e4 ? lg : log10(max(re, 1e4))
                        lb.cfPow[l] = pow(l4, 2.58)
                        lb.s2a[l] = sin(2 * a); let s1 = sin(a); lb.sa2[l] = pow(s1, 2)
                    }
                    let alpha = lb.alpha
                    // ground effect
                    let gh0 = pac.y - gh
                    let geOK = (gh0 .> 0) .& (geSpan .> 0)
                    let gx = 16 * gh0 / geSpan, gx2 = gx * gx
                    let gphi = gx2 / (1 + gx2)
                    let phi = vsel(geOK, gphi, V(repeating: 1)), lgain = vsel(geOK, 1 + 0.15 * (1 - gphi), V(repeating: 1))
                    let co = wing(alpha: alpha, mach: sp / sos, libm: lb, part: i, flapDeflection: flapDelta,
                                  phi: phi, liftGain: lgain, lanes: valid)
                    let qS = 0.5 * rho * sp * sp * stripArea[si]
                    let dd = a3 / sp
                    let ld = bnormalize(bcross(dd, s))
                    let f = ld * (co.cl * qS) + dd * (co.cd * qS)
                    let pcp = pac + c * (chord * (0.25 - co.cp))
                    var hinge = V()
                    if hasServo {
                        let cf = flapChord * chord
                        let hFlap = V.vabs(co.ch) * 0.5 * rho * sp * sp * stripArea[si] * flapChord * cf
                        let hPlain = blength(f) * 0.12 * chord + V.vabs(co.cl) * qS * 0.02
                        hinge = vsel(flapChord .> 0, hFlap, hPlain)
                    }
                    // StripResult: zero for lanes below 0.3 m/s (F += 0 exactly as the scalar path does)
                    let fz = BV3.sel(valid, f, .zero)
                    let tz = BV3.sel(valid, bcross(pcp - position, f), .zero)
                    F = BV3.sel(air, F + fz, F); T = BV3.sel(air, T + tz, T)
                    if hasServo {
                        let hm = valid .& (hinge .> 0)
                        P[sv].load = vsel(hm, P[sv].load + hinge, P[sv].load)
                    }
                    let big = valid .& co.stalled .& (span * chord .> 2)
                    stalledCount = vsel(big, stalledCount + 1, stalledCount)
                }
            }
        }
        // NOTE on skipped strips: the scalar path adds `StripResult()` (zero force/torque) for a strip below
        // 0.3 m/s. F + (+0) differs from F only when F is -0; handled above by adding the selected zero.

        // --- bodies: projected-area drag, or mesh panels for CAD
        if any(air) {
            if pmesh.contains(true) {
                for l in 0..<K where air[l] {
                    guard let sim = sims[l] else { continue }
                    let pb = sim.panels
                    let ql = q[lane: l], ol = origin[lane: l], vl = velocity[lane: l], wh = windHere[lane: l]
                    sim.parts.withUnsafeBufferPointer { sp in
                        for i in 0..<np where pmesh[i] {
                            let slot = sp[i].meshSlot, m = pb.meshes[slot]
                            let qp = ql * P[i].effQ[lane: l], op = ol + ql.act(P[i].basePos[lane: l])
                            let vb = qp.inverse.act(vl - wh)
                            if simd_length(vb) > 0.5 { m.updateShadows(flowDir: -simd_normalize(vb)) }
                            pb.qp[slot] = qp; pb.op[slot] = op
                        }
                    }
                    pb.com = position[lane: l]; pb.linVel = vl; pb.angVel = wW[lane: l]; pb.wind = wh
                    pb.rho = rho[l]; pb.nu = nu[l]; pb.sos = sos[l]
                    pb.runItems(0..<pb.items.count)
                }
            }
            for i in bodyIdx {
                if pmesh[i] {
                    var fF = BV3<V>.zero, fT = BV3<V>.zero
                    for l in 0..<K where air[l] {
                        guard let sim = sims[l] else { continue }
                        let pb = sim.panels
                        let (s0, nItems) = sim.parts.withUnsafeBufferPointer { ($0[i].itemStart, $0[i].itemCount) }
                        var ft = pb.out[s0]
                        if nItems > 1 { ft = .zero; for k in s0..<(s0 + nItems) { ft = ft + pb.out[k] } }
                        fF[lane: l] = ft.force; fT[lane: l] = ft.torque
                    }
                    F = BV3.sel(air, F + fF, F); T = BV3.sel(air, T + fT, T)
                } else {
                    let pw = origin + bact(q, P[i].basePos + bact(P[i].effQ, P[i].ctr))
                    let v = bPointVel(velocity, wW, pw, position) - windHere, sp = blength(v)
                    let m = air .& .!(sp .< 0.1)
                    if !any(m) { continue }
                    let vl = bact(bqinverse(bqmul(q, P[i].effQ)), v) / sp, s = P[i].size
                    let A = V.vabs(vl.x) * s.y * s.z + V.vabs(vl.y) * s.x * s.z + V.vabs(vl.z) * s.x * s.y
                    let msos = sp / sos
                    let hi = msos .> 0.8
                    var fac = V(repeating: 1)
                    if any(hi .& m) { fac = vsel(hi, 1 + 6 * vmapMasked(hi .& m, msos - 0.8) { pow($0, 2) }, fac) }
                    let cd = P[i].kCd * fac
                    bApplyM(&F, &T, m, v * (-0.5 * rho * sp * cd * A), pw, position)
                }
            }
        }

        // --- propulsion
        var liquid = V(); for i in tankIdx { liquid = liquid + P[i].fuel }
        var liquidUse = V()
        for i in 0..<np { P[i].thrustNow = V() }
        for i in propulsionIdx {
            switch ptype[i] {
            case .prop:
                let thr: V = pauto[i] ? P[i].out : (pmotor[i] >= 0 ? vclamp(P[pmotor[i]].out, -1, 1) : V())
                let dir = bact(q, bact(P[i].effQ, BV3(Vec3d(1, 0, 0)))), pw = origin + bact(q, P[i].basePos)
                let vax = bdot(bPointVel(velocity, wW, pw, position) - windHere, dir)
                let P0 = P[i].kPropPower * V.vabs(thr) * (rho / 1.225)
                let pos = thr .>= 0
                let r = propThrust(power: P0, diameter: vmax(V(repeating: 0.1), P[i].kD), rho: vmax(rho, V(repeating: 1e-6)),
                                   axialSpeed: vsel(pos, vax, vneg(vax)), pitchSpeed: P[i].kPropVmax, lanes: live)
                let Tn = vsel(pos, 1, -0.5) * r.thrust
                bApply(&F, &T, dir * Tn, pw, position)
                let targetOmega = 2 * Double.pi * r.rps * V.vabs(thr) * vsel(pos, 1, -1)
                P[i].omega = P[i].omega + (targetOmega - P[i].omega) * min(1, h / 0.4)
                P[i].spinAngle = vmap(P[i].spinAngle + P[i].omega * h) { $0.truncatingRemainder(dividingBy: 2 * Double.pi) }
                let spinning = V.vabs(P[i].omega) .> 1
                if any(spinning) { T = BV3.sel(spinning, T - dir * (P0 * 0.75 / P[i].omega) * 0.25, T) }
                P[i].thrustNow = V.vabs(Tn); thrustTotal = thrustTotal + V.vabs(Tn)
            case .jet:
                let hasFuel = liquid .> 0
                let cmd = vsel(hasFuel, vclamp(P[i].out, 0, 1), V())
                let N = P[i].spool
                let tau: V = vsel(cmd .> N, 1.6, 0.9)
                P[i].spool = N + (cmd - N) * vmin(V(repeating: 1), h / tau)
                let on = hasFuel .& (P[i].spool .> 0.01) .& live
                if any(on) {
                    let dir = bact(q, bact(P[i].effQ, BV3(Vec3d(1, 0, 0)))), pw = origin + bact(q, P[i].basePos)
                    let Mach = blength(velocity - windHere) / sos
                    let lapse = vmapMasked(on, vmax(rho, V()) / 1.225) { pow($0, 0.7) } * vmax(V(), 1 - 0.25 * Mach + 0.45 * Mach * Mach)
                    let Tn = P[i].kThrust * P[i].spool * lapse
                    bApplyM(&F, &T, on, dir * Tn, pw, position)
                    liquidUse = vsel(on, liquidUse + P[i].kFlow * (0.05 + 0.95 * P[i].spool) * h * (rho / 1.225 * 0.5 + 0.5), liquidUse)
                    P[i].thrustNow = vsel(on, Tn, P[i].thrustNow); thrustTotal = vsel(on, thrustTotal + Tn, thrustTotal)
                }
                P[i].spinAngle = P[i].spinAngle + P[i].spool * 300 * h
            case .solid:
                let ignite = (P[i].burning .== 0) .& (P[i].out .> 0.5) .& (P[i].fuel .> 0)
                P[i].burning = vsel(ignite, V(repeating: 1), P[i].burning); P[i].ignitedAt = vsel(ignite, time, P[i].ignitedAt)
                let b = (P[i].burning .!= 0) .& live
                if any(b) {
                    let dir = bact(q, bact(P[i].effQ, BV3(Vec3d(1, 0, 0)))), pw = origin + bact(q, P[i].basePos)
                    let frac = P[i].fuel / vmax(P[i].fuelCapacity, V(repeating: 1e-9))
                    let t = time - P[i].ignitedAt
                    let ramp = vmin(V(repeating: 1), t / 0.08)
                    let tail = vsel(frac .< 0.04, frac / 0.04, V(repeating: 1))
                    let kk = ramp * (0.3 + 0.7 * tail) * (1 + 0.08 * (1 - atmP / 101325))
                    let Tn = P[i].kThrust * kk
                    bApplyM(&F, &T, b, dir * Tn, pw, position)
                    var fuel = P[i].fuel - P[i].fuelCapacity / vmax(P[i].kBurn, V(repeating: 1e-3)) * kk * h
                    let empty = fuel .<= 0
                    fuel = vsel(empty, V(), fuel)
                    P[i].fuel = vsel(b, fuel, P[i].fuel)
                    P[i].burning = vsel(b .& empty, V(), P[i].burning)
                    P[i].thrustNow = vsel(b, Tn, P[i].thrustNow); thrustTotal = vsel(b, thrustTotal + Tn, thrustTotal)
                }
            default: break
            }
        }
        var massDirty = M(repeating: false)
        if !tankIdx.isEmpty {
            let use = (liquidUse .> 0) .& (liquid .> 0)
            if any(use) {
                let k = vmax(V(), 1 - liquidUse / liquid)
                for i in tankIdx { P[i].fuel = vsel(use, P[i].fuel * k, P[i].fuel) }
                massDirty = use
            }
        }
        for i in propulsionIdx where ptype[i] == .solid { massDirty = massDirty .| (P[i].burning .!= 0) }

        // --- gravity
        var grav = BV3<V>.zero
        for l in 0..<K where live[l] { grav[lane: l] = lw[l].gravity }
        F += grav * mass

        // --- ground
        if groundEnabled {
            var anyContact = M(repeating: false)
            var clear = M(repeating: true)
            for l in 0..<K where live[l] {
                let ceiling = lw[l].ceiling
                clear[l] = origin.y[l] - contactRadius[l] > ceiling + 1
            }
            let near = live .& .!clear
            if nc > 0 && any(near) {
                var nContact = V()
                for i in cornerParts {
                    let qp = bqmul(q, P[i].effQ), op = origin + bact(q, P[i].basePos)
                    let c0 = pcStart[i]
                    for k in c0..<(c0 + pcCount[i]) { cTmp[k] = op + bact(qp, CF[k]) }
                }
                terrainHeights(cTmp, cGh, nc, near)
                for k in 0..<nc { nContact = vsel(near .& (cTmp[k].y .< cGh[k]), nContact + 1, nContact) }
                let share = 1.0 / vmax(V(repeating: 1), nContact)
                let kB = mass * 2000 * share, cB = mass * 60 * share
                for k in 0..<nc {
                    let pw = cTmp[k], gh = cGh[k]
                    let m = near .& .!(pw.y .>= gh)
                    if !any(m) { continue }
                    var n = BV3<V>.zero, mu = V()
                    for l in 0..<K where m[l] { n[lane: l] = lw[l].terrain?.normal(x: pw.x[l], z: pw.z[l]) ?? Vec3d(0, 1, 0) }
                    let pen = (gh - pw.y) * n.y
                    let vp = bPointVel(velocity, wW, pw, position)
                    let vn = bdot(vp, n)
                    anyContact = anyContact .| m
                    let nvn = vneg(vn)
                    maxImpactSpeed = vsel(m .& (nvn .> maxImpactSpeed), nvn, maxImpactSpeed)
                    crashed = vsel(m .& (nvn .> crashSpeed), V(repeating: 1), crashed)
                    let N = vmax(V(), pen * kB - vn * cB)
                    let m2 = m .& .!(N .<= 0)
                    if !any(m2) { continue }
                    for l in 0..<K where m2[l] { mu[l] = lw[l].terrain?.material(x: pw.x[l], z: pw.z[l]).friction ?? 0.6 }
                    let vt = vp - n * vn, vts = blength(vt)
                    var f = n * N
                    let slide = vts .> 1e-4
                    f = BV3.sel(slide, f - vt * (vmin(mu * N, vts * cB) / vts), f)
                    bApplyM(&F, &T, m2, f, pw, position)
                }
            }
            // --- wheels
            let nW = Double(max(1, wheelCount))
            let kW = mass * kGravity / (nW * 0.08)
            let cW = 2 * 0.6 * V.vsqrt(kW * mass / nW)
            for i in wheelIdx {
                let r = vmax(V(repeating: 0.02), P[i].kR), Iw = vmax(V(repeating: 0.05), 0.5 * P[i].docMass * r * r)
                let hub = origin + bact(q, P[i].basePos)
                let axle = bact(q, bact(P[i].effQ, BV3(Vec3d(0, 0, 1))))
                var omega = P[i].omega
                var motorT = V()
                if pauto[i] { motorT = CraftSim.autoWheelTorque * vclamp(P[i].out, -1, 1) }
                else if pmotor[i] >= 0 {
                    let m = pmotor[i]
                    let lo: V = vsel(P[m].kReversible .!= 0, -1.0, 0)
                    motorT = P[m].kTorque * vclamp(P[m].out, lo, V(repeating: 1))
                    let vm = P[m].kMotorVmax
                    motorT = motorT * vclamp(1 - (omega * r * vsel(motorT .>= 0, 1, -1)) / vmax(vm, V(repeating: 0.1)), 0, 1)
                }
                var n = BV3<V>(Vec3d(0, 1, 0))
                for l in 0..<K where live[l] && !clear[l] { n[lane: l] = lw[l].terrain?.normal(x: hub.x[l], z: hub.z[l]) ?? Vec3d(0, 1, 0) }
                var down = -n + axle * bdot(axle, n)
                let c1 = live .& .!clear .& (blength2(down) .> 1e-4)
                var contact = M(repeating: false)
                if any(c1) {
                    down = bnormalize(down)
                    let cp = hub + down * r
                    var gh = V()
                    for l in 0..<K where c1[l] { gh[l] = lw[l].terrain?.height(x: cp.x[l], z: cp.z[l]) ?? 0 }
                    let pen = (gh - cp.y) * n.y
                    let fwdRaw = bcross(n, axle)
                    let c2 = c1 .& (pen .> 0) .& (blength2(fwdRaw) .> 1e-6)
                    if any(c2) {
                        contact = c2
                        let fwd = bnormalize(fwdRaw), lat = bcross(fwd, n)
                        let vp = bPointVel(velocity, wW, cp, position)
                        let N = vmax(V(), pen * kW - bdot(vp, n) * cW)
                        var fric = V(repeating: 0.9), rr = V(repeating: 1)
                        for l in 0..<K where c2[l] {
                            let mat = lw[l].terrain?.material(x: cp.x[l], z: cp.z[l]) ?? TerrainMaterialSample()
                            fric[l] = mat.friction; rr[l] = mat.rollingResistance
                        }
                        let mu = P[i].kGrip * fric / 0.9
                        let D = mu * N
                        let vf = bdot(vp, fwd), vl = bdot(vp, lat)
                        let den = vmax(V.vabs(vf), V(repeating: 1))
                        let Bx = 10.0, Cx = 1.65
                        let kappa0 = (omega * r - vf) / den
                        let fx0 = D * vmapMasked(c2, Bx * kappa0) { sin(Cx * atan($0)) }
                        let slope = D * Cx * Bx * r / den
                        let omegaC = omega + h * (motorT - r * fx0) / (Iw + h * r * slope)
                        let kappa = (omegaC * r - vf) / den
                        var fx = D * vmapMasked(c2, Bx * kappa) { sin(Cx * atan($0)) }
                        var al = V()
                        for l in 0..<K where c2[l] { al[l] = atan2(vl[l], den[l]) }
                        var fy = vneg(D) * vmapMasked(c2, 8 * al) { sin(1.3 * atan($0)) }
                        let mag = V.vsqrt(fx * fx + fy * fy)
                        let lim = (mag .> D) .& (mag .> 0)
                        fx = vsel(lim, fx * (D / mag), fx); fy = vsel(lim, fy * (D / mag), fy)
                        let roll = vneg(vclamp(vf * 4, -1, 1)) * P[i].kRoll * rr * N
                        bApplyM(&F, &T, c2, n * N + fwd * (fx + roll) + lat * fy, cp, position)
                        P[i].compression = vsel(c2, pen, P[i].compression)
                        let s = pservo[i]
                        if s >= 0 { P[s].load = vsel(c2, P[s].load + V.vabs(fy) * 0.04, P[s].load) }
                        omega = vsel(c2, omegaC, omega)
                    }
                }
                let omegaNC = (omega + h * motorT / Iw) * (1 - 0.2 * h)
                omega = vsel(contact, omega, omegaNC)
                P[i].omega = omega; P[i].contact = vsel(contact, 1, 0)
                anyContact = anyContact .| contact
                P[i].spinAngle = vmap(P[i].spinAngle + omega * h) { $0.truncatingRemainder(dividingBy: 2 * Double.pi) }
            }
            groundContact = vsel(anyContact, 1, 0)
        }

        // --- buoyancy / hydrodynamics (per lane: the lane's own hull)
        for l in 0..<K where live[l] {
            guard let water = lw[l].water, let sim = sims[l], let hull = sim.hull else { continue }
            let pl = position[lane: l]
            let ws = water.sample(x: pl.x, z: pl.z, time: etime[l])
            if pl.y - boundingRadius[l] < ws.surfaceHeight + 1 {
                let ql = q[lane: l]
                let st = BodyState(transform: Transform(position: pl - ql.act(comLocal[lane: l]), rotation: ql), linearVelocity: velocity[lane: l],
                                   angularVelocity: wW[lane: l], centerOfMass: pl)
                let (ft, _) = water.submergedForces(hull: hull, state: st, time: etime[l])
                F[lane: l] = F[lane: l] + ft.force; T[lane: l] = T[lane: l] + ft.torque
            }
        }

        // --- integrate (attached lanes only)
        let vOld = velocity
        let vNew = velocity + F / mass * h
        let pNew = position + (vOld + vNew) * (0.5 * h)
        let LNew = angularMomentum + T * h
        let L0 = angularMomentum
        angularMomentum = LNew
        let w0 = omegaWorld(orientation)
        let qHalf = rotate(orientation, w0, h * 0.5)
        let wHalf = omegaWorld(qHalf)
        let qNew = rotate(orientation, wHalf, h)
        self.velocity = BV3.sel(live, vNew, vOld)
        self.position = BV3.sel(live, pNew, position)
        angularMomentum = BV3.sel(live, LNew, L0)
        orientation = BQ.sel(live, qNew, orientation)
        time = vsel(live, time + h, time)
        lastForce = BV3.sel(live, F - grav * mass, lastForce)

        var fuel = V(); for i in 0..<np { fuel = fuel + P[i].fuel }
        tWind = windHere
        tStalled = stalledCount; tThrust = thrustTotal; tGround = groundUnder; tFuel = fuel

        // --- mass properties (scalar, per lane; same cadence as CraftSim.substep)
        for l in 0..<K where live[l] {
            stepCounter[l] += 1
            if massDirty[l] && stepCounter[l] % 10 == 0, let s = sims[l] { refreshMass(s, l) }
        }
    }

    /// Lane → sim, `updateMassProperties(keepOrigin: true)`, sim → lane.
    func refreshMass(_ s: CraftSim, _ l: Int) {
        s.batchStore(position: position[lane: l], orientation: orientation[lane: l], velocity: velocity[lane: l],
                     angularMomentum: angularMomentum[lane: l], time: time[l], crashed: crashed[l] != 0,
                     groundContact: groundContact[l] != 0, maxImpactSpeed: maxImpactSpeed[l])
        s.parts.withUnsafeMutableBufferPointer { sp in for i in 0..<np { sp[i].fuel = P[i].fuel[l] } }
        s.updateMassProperties(keepOrigin: true)
        let mp = s.batchMassProperties
        mass[l] = mp.mass; comLocal[lane: l] = mp.comLocal; inertiaInv[lane: l] = mp.inertiaInv
        position[lane: l] = s.position; angularMomentum[lane: l] = s.angularMomentum
    }

    // MARK: lane versions of the aero / propulsion models

    struct WingOut { var cl: V, cd: V, stalled: SIMDMask<V.MaskStorage>, cp: V, ch: V }

    // MARK: wind field in lanes (WindField.Prepared.velocity, transcendentals per lane)

    struct BWind {
        var mean = BV3<V>.zero, turb = V(), sigmaBase = V(), shift = BV3<V>.zero, by = V()
        var bx: (V, V, V, V) = (V(), V(), V(), V()), bz: (V, V, V, V) = (V(), V(), V(), V())
        // lane-independent constants (identical in every lane's Prepared)
        var z0 = 0.03, lnRef = 1.0, amp = simd_double4(), amp6 = simd_double4(), k = simd_double4()
        var ax = simd_double4(), ay = simd_double4(), az = simd_double4()
    }
    var bw = BWind()

    /// Gather this substep's per-lane `WindField.Prepared` into lanes.
    @inline(__always) func loadWind(_ m: M) {
        var first = true
        for l in 0..<K where m[l] {
            let w = windPrep + l
            if first {
                first = false
                bw.z0 = w.pointee.z0; bw.lnRef = w.pointee.lnRef; bw.amp = w.pointee.amp; bw.amp6 = w.pointee.amp6; bw.k = w.pointee.k
                bw.ax = w.pointee.ax; bw.ay = w.pointee.ay; bw.az = w.pointee.az
            }
            bw.mean[lane: l] = w.pointee.mean; bw.turb[l] = w.pointee.turbulence; bw.sigmaBase[l] = w.pointee.sigmaBase
            bw.shift[lane: l] = w.pointee.shift; bw.by[l] = w.pointee.by
            bw.bx.0[l] = w.pointee.bx[0]; bw.bx.1[l] = w.pointee.bx[1]; bw.bx.2[l] = w.pointee.bx[2]; bw.bx.3[l] = w.pointee.bx[3]
            bw.bz.0[l] = w.pointee.bz[0]; bw.bz.1[l] = w.pointee.bz[1]; bw.bz.2[l] = w.pointee.bz[2]; bw.bz.3[l] = w.pointee.bz[3]
        }
    }

    /// `WindField.Prepared.velocity(at:heightAGL:)` for the lanes in `m`: arithmetic in lanes, the log and the
    /// 12 sines per lane with scalar libm (one round trip). Same operations, same order as the scalar version.
    @inline(__always) func windAt(_ p: BV3<V>, _ h: V, _ m: M) -> BV3<V> {
        let zc = vclamp(h, 0.2, 500)
        let ratio = zc / bw.z0
        let tm = m .& (bw.turb .> 0)
        let q = p - bw.shift
        @inline(__always) func args(_ o: Int, _ bxo: V, _ bzo: V) -> (V, V, V) {
            let kk = bw.k[o]
            return (kk * q.x * 1.3 + kk * q.z * 0.7 + bw.ax[o] + bxo,
                    kk * q.y * 1.1 - kk * q.x * 0.8 + bw.ay[o] + bw.by,
                    kk * q.z * 1.2 - kk * q.y * 0.5 + bw.az[o] + bzo)
        }
        let t0 = args(0, bw.bx.0, bw.bz.0), t1 = args(1, bw.bx.1, bw.bz.1), t2 = args(2, bw.bx.2, bw.bz.2), t3 = args(3, bw.bx.3, bw.bz.3)
        // Per lane: the log, the 12 sines and the octave accumulation (acc += amp * sin, in octave order), so only
        // four lane vectors are rebuilt from scalars.
        var lg = V(), ax = V(), ay = V(), az = V()
        let amp = bw.amp, amp6 = bw.amp6
        for l in 0..<K where m[l] {
            lg[l] = log(ratio[l])
            if tm[l] {
                var x = 0.0, y = 0.0, z = 0.0
                x += amp[0] * sin(t0.0[l]); y += amp6[0] * sin(t0.1[l]); z += amp[0] * sin(t0.2[l])
                x += amp[1] * sin(t1.0[l]); y += amp6[1] * sin(t1.1[l]); z += amp[1] * sin(t1.2[l])
                x += amp[2] * sin(t2.0[l]); y += amp6[2] * sin(t2.1[l]); z += amp[2] * sin(t2.2[l])
                x += amp[3] * sin(t3.0[l]); y += amp6[3] * sin(t3.1[l]); z += amp[3] * sin(t3.2[l])
                ax[l] = x; ay[l] = y; az[l] = z
            }
        }
        let profile = vclamp(lg / bw.lnRef, 0, 1.6)
        let w = bw.mean * profile
        if !any(tm) { return w }
        let sigma = bw.sigmaBase * (0.5 + 0.5 * vmin(V(repeating: 1), zc / 50))
        return BV3.sel(tm, w + BV3(ax, ay, az) * sigma, w)
    }

    /// Per-lane transcendentals of one wing strip (filled by one scalar loop; see the strip loop).
    struct LibmBlock { var alpha = V(), lr = V(), cfPow = V(), s2a = V(), sa2 = V() }

    /// `Aero.wing(alpha:mach:reynolds:const:flapDeflection:groundEffectInduced:groundLiftGain:)` per lane, with
    /// log10(max(Re,1e3)), pow(lr4, 2.58), sin(2a) and pow(sin a, 2) precomputed per lane in `lb`.
    @inline(__always) func wing(alpha a: V, mach: V, libm lb: LibmBlock, part i: Int, flapDeflection delta: V, phi: V, liftGain: V, lanes: M) -> WingOut {
        let p = P + i
        let Mm = vmin(mach, V(repeating: 0.8)), beta2 = 1 - Mm * Mm, beta = V.vsqrt(beta2)
        let slope = p.pointee.wLiftNum / (2 + V.vsqrt(p.pointee.wAA * beta2 / (0.95 * 0.95) + 4)) * liftGain
        var cl0 = p.pointee.wCamber / beta
        var ch = V(), dcdFlap = V()
        let flap = lanes .& (p.pointee.wFlapFrac .> 0) .& (delta .!= 0)
        if any(flap) {
            let eff = 0.75 - 0.25 * vsmoothstep(15 * kDegF, 40 * kDegF, V.vabs(delta))
            cl0 = vsel(flap, cl0 + slope * p.pointee.wFlapTau * eff * delta, cl0)
            dcdFlap = vsel(flap, p.pointee.wFlapCd * vmapMasked(flap, delta) { pow(abs(sin($0)), 1.5) }, dcdFlap)
            ch = vsel(flap, -0.55 * delta - 0.2 * a, ch)
        }
        let lr = lb.lr
        let stall = (11 + 5 * vsmoothstep(5, 7, lr) - p.pointee.wStallThick) * kDegF
        let aZL = a + cl0 / slope
        let flat = 1.05 * lb.s2a
        let ex = V.vabs(aZL) - stall
        let stalled = .!(ex .<= 0)
        var cl = slope * aZL
        if any(stalled .& lanes) {
            let t = vclamp(ex / (12 * kDegF), 0, 1)
            let peak = slope * stall * vsel(aZL .>= 0, 1, -1)
            cl = vsel(stalled, peak * (1 - t) + flat * t, cl)
        }
        let cf = 0.455 / lb.cfPow
        let cd0 = 2 * cf * p.pointee.wThickFactor
        let sa2 = lb.sa2
        var cd = cd0 + phi * cl * cl / p.pointee.wInducedDen + 0.02 * sa2 + dcdFlap
        if any(stalled .& lanes) { cd = vsel(stalled, cd + 1.2 * sa2 * vsmoothstep(0, 6 * kDegF, ex), cd) }
        let mcritEff = vmax(V(repeating: 0.55), p.pointee.wMcritBase - 0.1 * V.vabs(cl) - 0.108)
        let wave = lanes .& (mach .> mcritEff)
        if any(wave) { cd = vsel(wave, cd + 20 * vmapMasked(wave, mach - mcritEff) { pow($0, 4) }, cd) }
        var cp = V(repeating: 0.25)
        if any(stalled .& lanes) { cp = vsel(stalled, 0.25 + 0.2 * vsmoothstep(0, 12 * kDegF, ex), cp) }
        return WingOut(cl: cl, cd: cd, stalled: stalled, cp: cp, ch: ch)
    }

    /// `Propulsion.propThrust` per lane (Newton iterations in lanes, pow per lane).
    @inline(__always) func propThrust(power Pw: V, diameter d: V, rho: V, axialSpeed Vax: V, pitchSpeed vmaxP: V, lanes: M) -> (thrust: V, rps: V) {
        let ok = lanes .& (Pw .> 0) .& (rho .> 1e-6)
        if !any(ok) { return (V(), V()) }
        let A = Double.pi * d * d / 4, eta = 0.75
        let Va = vmax(V(), Vax)
        var T = vmapMasked(ok, 2 * rho * A * eta * eta * Pw * Pw) { pow($0, 1.0 / 3.0) }
        for _ in 0..<8 {
            let s = V.vsqrt(Va * Va / 4 + T / (2 * rho * A))
            let vi = vneg(Va) / 2 + s
            let f = T * (Va + vi) - eta * Pw
            let df = (Va + vi) + T / (4 * rho * A * s)
            T = vmax(V(), T - f / df)
        }
        let rps = vmaxP / (0.8 * d)
        let unload = vmax(V(), 1 - vmapMasked(ok, Va / vmax(vmaxP, V(repeating: 1))) { pow($0, 3) })
        return (vsel(ok, T * unload, V()), vsel(ok, rps, V()))
    }

    /// Per-lane wind field of the current substep (pointer storage: calling a method on an array element would
    /// copy the ~200-byte struct every strip).
    let windPrep: UnsafeMutablePointer<WindField.Prepared>
    /// Per-lane world references for the current step, held unowned(unsafe): no retain/release per query (the
    /// caller's `envs` keep them alive for the duration of `step`).
    let lw: UnsafeMutablePointer<LaneWorld>
    /// Scratch for bulk terrain queries (one lane at a time) and per-strip sample points.
    let qx: UnsafeMutablePointer<Double>, qz: UnsafeMutablePointer<Double>, qh: UnsafeMutablePointer<Double>
    let sPac: UnsafeMutablePointer<BV3<V>>, sGh: UnsafeMutablePointer<V>
}


// MARK: - verification support (self-tests)

extension CraftSim {
    /// Every bit of the dynamic state (body, parts, telemetry) for exact comparisons (allocates; tests only).
    public func stateWords() -> [UInt64] {
        var w: [UInt64] = []
        func d(_ x: Double) { w.append(x.bitPattern) }
        func v(_ x: Vec3d) { d(x.x); d(x.y); d(x.z) }
        func q(_ x: Quatd) { d(x.vector.x); d(x.vector.y); d(x.vector.z); d(x.vector.w) }
        v(position); q(orientation); v(velocity); v(angularMomentum); d(time); v(lastForce)
        w.append(UInt64(stepCounter)); w.append(crashed ? 1 : 0); w.append(groundContact ? 1 : 0); d(maxImpactSpeed)
        d(mass); v(comLocal); v(inertiaInv.columns.0); v(inertiaInv.columns.1); v(inertiaInv.columns.2)
        for p in parts {
            d(p.out); d(p.angle); d(p.load); d(p.loadShown); w.append(p.overload ? 1 : 0); d(p.spinAngle); d(p.omega)
            d(p.thrustNow); w.append(p.burning ? 1 : 0); d(p.ignitedAt); d(p.spool); d(p.fuel); d(p.compression)
            w.append(p.contact ? 1 : 0); q(p.effQ)
        }
        let t = telemetry
        for x in [t.airspeed, t.groundSpeed, t.altitude, t.verticalSpeed, t.angleOfAttackDeg, t.sideslipDeg, t.mach, t.gLoad, t.fuelKg, t.massKg, t.thrustN] { d(x) }
        w.append(UInt64(t.stalledSurfaces))
        return w
    }
}

extension CraftSimBatch {
    /// Bit-exactness of the lane primitives against the scalar simd functions on `samples` random inputs per
    /// lane width (including ±0, tiny and huge magnitudes). Returns mismatch counts by primitive (empty = exact).
    public static func primitiveMismatches(samples: Int = 20000, seed: UInt64 = 1) -> [String: Int] {
        var bad: [String: Int] = [:]
        var s = seed | 1
        func rnd() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let k = Int((s >> 33) % 20)
            if k == 0 { return 0 }; if k == 1 { return -0.0 }
            let u = Double(s >> 11) / Double(1 << 53) * 2 - 1
            return u * [1, 1e-3, 1e3, 7][k % 4]
        }
        func same(_ a: Double, _ b: Double) -> Bool { a.bitPattern == b.bitPattern || (a.isNaN && b.isNaN) }
        func chk(_ n: String, _ a: Vec3d, _ b: Vec3d) { if !(same(a.x, b.x) && same(a.y, b.y) && same(a.z, b.z)) { bad[n, default: 0] += 1 } }
        func chk(_ n: String, _ a: Double, _ b: Double) { if !same(a, b) { bad[n, default: 0] += 1 } }
        func chk(_ n: String, _ a: Quatd, _ b: Quatd) { for i in 0..<4 where !same(a.vector[i], b.vector[i]) { bad[n, default: 0] += 1; return } }
        func run<V: LaneVec>(_: V.Type) {
            for _ in 0..<samples {
                var A = BV3<V>.zero, B = BV3<V>.zero, Q = BQ<V>.identity, P = BQ<V>.identity
                var a: [Vec3d] = [], b: [Vec3d] = [], q: [Quatd] = [], p: [Quatd] = []
                for i in 0..<V.scalarCount {
                    a.append(Vec3d(rnd(), rnd(), rnd())); b.append(Vec3d(rnd(), rnd(), rnd()))
                    q.append(Quatd(vector: simd_double4(rnd(), rnd(), rnd(), rnd()))); p.append(Quatd(vector: simd_double4(rnd(), rnd(), rnd(), rnd())))
                    A[lane: i] = a[i]; B[lane: i] = b[i]; Q[lane: i] = q[i]; P[lane: i] = p[i]
                }
                let d = bdot(A, B), l = blength(A), nrm = bnormalize(A), c = bcross(A, B), m = bqmul(P, Q), act = bact(Q, A)
                let qn = bqnormalize(Q), qi = bqinverse(Q), M = bmat(Q), mv = bmul(M, A), mt = bmulT(M, A)
                let mn = vmin(A.x, B.x), mx = vmax(A.x, B.x), cl = vclamp(A.x, B.x, A.y), ss = vsmoothstep(-0.3, 0.7, A.x), ng = -A, nv = vneg(A.x)
                for i in 0..<V.scalarCount {
                    chk("dot", d[i], simd_dot(a[i], b[i])); chk("length", l[i], simd_length(a[i])); chk("normalize", nrm[lane: i], simd_normalize(a[i]))
                    chk("cross", c[lane: i], simd_cross(a[i], b[i])); chk("quat*quat", m[lane: i], p[i] * q[i]); chk("act", act[lane: i], q[i].act(a[i]))
                    chk("normalized", qn[lane: i], q[i].normalized); chk("inverse", qi[lane: i], q[i].inverse)
                    let MS = Mat3d(q[i])
                    chk("Mat3d(q)", M[lane: i].columns.0, MS.columns.0); chk("Mat3d(q)", M[lane: i].columns.1, MS.columns.1); chk("Mat3d(q)", M[lane: i].columns.2, MS.columns.2)
                    chk("M*v", mv[lane: i], MS * a[i]); chk("M^T*v", mt[lane: i], MS.transpose * a[i])
                    chk("min", mn[i], min(a[i].x, b[i].x)); chk("max", mx[i], max(a[i].x, b[i].x)); chk("clamp", cl[i], clamp(a[i].x, b[i].x, a[i].y))
                    chk("smoothstep", ss[i], smoothstep(-0.3, 0.7, a[i].x)); chk("-vec", ng[lane: i], -a[i]); chk("-double", nv[i], -a[i].x)
                }
            }
        }
        run(SIMD2<Double>.self); run(SIMD4<Double>.self); run(SIMD8<Double>.self)
        return bad
    }
}
