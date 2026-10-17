// `.full` aero model call site (docs/FIDELITY.md "The .full step"): per-part CFD forces from an AeroBackend
// (PWFlow LBMSolver) replace the fast wing-strip / body / CAD-panel aero. Props keep the momentum model: their
// thrust and shaft torque are applied as before AND handed to the CFD as actuator-disk sources (blades are not
// meshed). Forces lag one CFD update: update k submits poses at substep k·N and collects at substep (k+1)·N, so
// the GPU runs while the CPU integrates the next N substeps (N = cfd.updateEvery).
// Not wired: `sampleVelocity` is collected but does not yet feed servo hinge loads or the airspeed sensors
// (servo hinge load is 0 in `.full`; sensors keep using the free-stream + wind model).
import Foundation
import simd
import PWCore

/// Buffers allocated once when `.full` is switched on (no allocation per substep on the CPU side; the Metal
/// command buffer per CFD update is the backend's own cost).
final class FullAeroBuffers {
    let count: Int
    let poses: UnsafeMutablePointer<AeroPartPose>
    let rotors: UnsafeMutablePointer<AeroRotorSource>
    var rotorCount = 0
    let forces: UnsafeMutablePointer<ForceTorque>       // last collected CFD force/torque about the CoM, per part
    let sample: UnsafeMutablePointer<Vec3d>
    let fast: UnsafeMutablePointer<ForceTorque>         // fast-model per-part force on a capture substep (comparison)
    var pending = false
    var counter = 0
    var collected = 0
    weak var backend: AeroBackend?
    init(count n: Int) {
        count = n
        poses = .allocate(capacity: max(1, n)); poses.initialize(repeating: AeroPartPose(), count: max(1, n))
        rotors = .allocate(capacity: max(1, n)); rotors.initialize(repeating: AeroRotorSource(), count: max(1, n))
        forces = .allocate(capacity: max(1, n)); forces.initialize(repeating: .zero, count: max(1, n))
        sample = .allocate(capacity: max(1, n)); sample.initialize(repeating: .zero, count: max(1, n))
        fast = .allocate(capacity: max(1, n)); fast.initialize(repeating: .zero, count: max(1, n))
    }
    deinit { poses.deallocate(); rotors.deallocate(); forces.deallocate(); sample.deallocate(); fast.deallocate() }
}

extension CraftSim {
    /// Number of CFD updates collected since `.full` was enabled / reset (tests, diagnostics).
    public var fullAeroUpdates: Int { full?.collected ?? 0 }
    /// Last collected CFD force/torque on part `i` (world frame, torque about the CoM). nil when not running full.
    public func cfdForce(part i: Int) -> ForceTorque? {
        guard let f = full, fullActive || aeroModel == .full, i >= 0, i < f.count else { return nil }
        return f.forces[i]
    }
    /// Is the sim actually running the CFD backend this substep (model `.full`, backend set, buffers ready)?
    public var isRunningFull: Bool { aeroModel == .full && aeroBackend != nil && full != nil }

    /// (Re)allocate buffers when the part count or backend changed. Returns true when `.full` can run.
    func prepareFull() -> Bool {
        guard let b = aeroBackend, b.isAvailable else { return false }
        if let f = full, f.count == parts.count, f.backend === b { return true }
        let f = FullAeroBuffers(count: parts.count); f.backend = b
        full = f
        return true
    }

    /// Drop pending CFD state (called from `reset`): the backend restarts from a uniform flow at the new pose.
    func resetFull() {
        guard let f = full else { return }
        if f.pending, let b = aeroBackend { _ = b.collect(forces: f.forces, sampleVelocity: f.sample, count: f.count) }
        f.pending = false; f.counter = 0; f.collected = 0
        for i in 0..<f.count { f.forces[i] = .zero }
        aeroBackend?.reset()
    }

    /// Start of a substep: if an update was submitted N substeps ago, wait for it and take its forces.
    func fullCollect() {
        guard let f = full, let b = aeroBackend else { return }
        if equationCapture?.requested == true { for i in 0..<f.count { f.fast[i] = .zero } }
        let every = max(1, b.settings.updateEvery)
        guard f.pending, f.counter % every == 0 else { return }
        if b.collect(forces: f.forces, sampleVelocity: f.sample, count: f.count) { f.collected += 1 }
        f.pending = false
    }

    /// End of a substep: every `updateEvery` substeps, send the current part poses + rotor disks to the backend.
    func fullSubmit(_ h: Double, _ env: SimEnvironment) {
        guard let f = full, let b = aeroBackend else { return }
        let every = max(1, b.settings.updateEvery)
        f.counter += 1
        guard f.counter % every == 0, !f.pending else { return }
        let q = orientation, origin = position - q.act(comLocal), wW = omegaWorld(q)
        var nr = 0
        for i in 0..<min(f.count, parts.count) {
            let p = parts[i]
            var rq = q * p.effQ
            if p.type == .wheel { rq = rq * Quatd(angle: -p.spinAngle, axis: Vec3d(0, 0, 1)) }
            let pw = origin + q.act(p.basePos)
            var pose = AeroPartPose()
            pose.position = pw; pose.rotation = rq.normalized
            pose.linVel = velocity + simd_cross(wW, pw - position); pose.angVel = wW
            f.poses[i] = pose
            if p.type == .prop && p.thrustNow > 0 {
                var r = AeroRotorSource()
                r.partIndex = i; r.center = pw; r.axis = q.act(p.effQ.act(Vec3d(1, 0, 0)))
                r.radius = max(0.05, p.kD / 2); r.thrust = p.thrustNow; r.torque = p.wakeQ; r.omega = p.omega
                f.rotors[nr] = r; nr += 1
            }
        }
        f.rotorCount = nr
        let atm = env.atmosphere(at: position.y)
        var e = AeroEnvironmentSample()
        e.rho = atm.density; e.nu = Aero.viscosity(temperature: atm.temperature) / max(atm.density, 1e-9)
        e.speedOfSound = atm.speedOfSound
        e.wind = WindField(mean: env.wind, turbulence: 0).velocity(at: position, heightAGL: position.y - groundHeight(env, position.x, position.z), time: env.time)
        e.groundHeight = groundEnabled ? groundHeight(env, position.x, position.z) : -Double.infinity
        b.submit(com: position, velocity: velocity, orientation: q, poses: f.poses, poseCount: f.count,
                 rotors: f.rotors, rotorCount: nr, env: e, dt: h * Double(every))
        f.pending = true
    }

    /// Capture substep in `.full`: per-part fast force (strips + CAD panels; primitive-body drag is written inline).
    func fullFastBreakdown(_ P: UnsafeMutablePointer<SimPart>, _ np: Int, _ ns: Int) {
        guard let f = full else { return }
        if ns > 0, let buf = stripBuf {
            strips.withUnsafeBufferPointer { sb in
                for si in 0..<ns { let k = sb[si].part; f.fast[k] = f.fast[k] + buf[si].ft }
            }
        }
        let pb = panels
        for i in 0..<np where P[i].isBody && P[i].meshSlot >= 0 {
            var ft = ForceTorque.zero
            for k in P[i].itemStart..<(P[i].itemStart + P[i].itemCount) { ft = ft + pb.out[k] }
            f.fast[i] = ft
        }
    }

    /// One `.cfdMomentumExchange` record per non-rotor part: values = fast F (3), fast T (3), |F_fast|, |F_cfd|,
    /// % difference of |F|; result = the CFD force/torque.
    func fullCaptureRecords(_ P: UnsafeMutablePointer<SimPart>, _ np: Int, _ cap: EquationCapture) {
        guard let f = full else { return }
        for i in 0..<min(np, f.count) where P[i].type != .prop {
            let a = f.fast[i], c = f.forces[i]
            let fa = simd_length(a.force), fc = simd_length(c.force)
            if fa < 1e-9 && fc < 1e-9 { continue }
            var r = EquationRecord(); r.id = .cfdMomentumExchange; r.partIndex = Int32(i)
            r.set(0, a.force.x); r.set(1, a.force.y); r.set(2, a.force.z)
            r.set(3, a.torque.x); r.set(4, a.torque.y); r.set(5, a.torque.z)
            r.set(6, fa); r.set(7, fc); r.set(8, fa > 1e-9 ? (fc - fa) / fa * 100 : 0)
            r.result = c
            cap.append(r)
        }
    }
}


extension CraftSim {
    /// Debug text: per-part spin / wake state (PW_NAN_TRAP in the evaluator).
    public func debugDump() -> String {
        parts.enumerated().filter { $0.element.type == .prop || $0.element.type == .servo || $0.element.type == .wing }.map { i, p in
            "  #\(i) \(p.doc.name) omega=\(p.omega) vi=\(p.vi) wakeQ=\(p.wakeQ) thrust=\(p.thrustNow) angle=\(p.angle) out=\(p.out) kIrot=\(p.kIrot)"
        }.joined(separator: "\n") + "\n  mass=\(mass) inertia=\(inertia) L=\(angularMomentum)"
    }
}
