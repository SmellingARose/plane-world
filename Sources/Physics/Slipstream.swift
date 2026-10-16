// Propeller / rotor slipstream (induced-flow) model.
//
// Each propeller is an actuator disk. Momentum theory gives the induced velocity at the disk, and the classic
// vortex-cylinder solution gives the axial velocity increment along the wake axis:
//     Δv(s) = v_i · (1 + s / √(s² + R²))      (s = distance downstream of the disk; 0 far upstream, 2·v_i far downstream)
// The wake contracts by continuity, convects with the crossflow, carries swirl in the rotor's rotation sense, and
// decays by turbulent mixing. A ducted rotor (σ = 1) has no contraction and its exit velocity equals the disk velocity.
// Every point that samples the air (wing strips, bodies, other propellers) adds the wakes of all *other* rotors,
// so coaxial / tandem rotors, prop wash over tails and fins, and duct effects are captured.
// Wake state is taken from the previous substep, so the field is explicit and deterministic.
import Foundation
import simd
import PWCore

struct RotorWake {
    var center = Vec3d.zero        // disk centre (world)
    var axis = Vec3d.zero          // direction the slipstream flows (unit, world) = -thrust direction
    var radius = 0.0               // disk radius
    var vi = 0.0                   // induced velocity at the disk (m/s)
    var vAxial = 0.0               // freestream component through the disk along `axis` (m/s, ≥ 0)
    var cross = Vec3d.zero         // crossflow of the air relative to the disk (m/s, ⟂ axis) — the wake drifts with it
    var swirl = 0.0                // signed swirl strength Q / (ρ π R²) (m³/s²); sign = rotation sense about thrust dir
    var ducted = false
    var owner = -1                 // part index of the rotor (its own wake is excluded from its own inflow)
}

/// Fixed-capacity wake list (no allocation in the step loop).
final class WakeField {
    private(set) var count = 0
    private var buf: UnsafeMutablePointer<RotorWake>
    private let cap: Int
    /// Wakes decay by mixing over this many radii downstream.
    static let mixingRadii = 14.0

    init(capacity: Int) { cap = max(1, capacity); buf = .allocate(capacity: cap); buf.initialize(repeating: RotorWake(), count: cap) }
    deinit { buf.deinitialize(count: cap); buf.deallocate() }

    @inline(__always) func reset() { count = 0 }
    @inline(__always) func add(_ w: RotorWake) { if count < cap { buf[count] = w; count += 1 } }
    var isEmpty: Bool { count == 0 }

    /// Raw view for worker jobs (keeps job structs free of class references).
    var view: WakeView { WakeView(buf: UnsafePointer(buf), count: count) }

    /// Induced air velocity (world, m/s) at `p` from every wake except `exclude`'s.
    @inline(__always) func velocity(at p: Vec3d, exclude: Int = -1) -> Vec3d { view.velocity(at: p, exclude: exclude) }

    @inline(__always) static func induced(_ w: RotorWake, at p: Vec3d) -> Vec3d {
        guard w.vi > 1e-6, w.radius > 1e-6 else { return .zero }
        let R = w.radius
        let d = p - w.center
        let s = simd_dot(d, w.axis)
        if s < -4 * R || s > mixingRadii * 4 * R { return .zero }
        // Axial increment along the centreline.
        let dv: Double
        if w.ducted { dv = s >= 0 ? w.vi : w.vi * (1 + s / (s * s + R * R).squareRoot()) }
        else { dv = w.vi * (1 + s / (s * s + R * R).squareRoot()) }
        // Wake radius: continuity (open rotor contracts towards R·√((V+vi)/(V+2vi))); ducted keeps R.
        let Rs = w.ducted || s <= 0 ? R : R * ((w.vAxial + w.vi) / max(w.vAxial + dv, 1e-6)).squareRoot()
        // The wake is carried sideways by the crossflow during the transit time to depth s.
        let drift = s > 0 ? w.cross * (s / max(w.vAxial + dv, 0.5)) : .zero
        let rv = d - w.axis * s - drift
        let r = simd_length(rv)
        // Soft edge (shear layer) between 0.85·Rs and 1.15·Rs; upstream the influence spreads wider.
        let edge0 = s <= 0 ? 1.0 * Rs : 0.85 * Rs, edge1 = s <= 0 ? 2.0 * Rs : 1.15 * Rs
        var prof = 1.0
        if r >= edge1 { prof = 0 } else if r > edge0 { let t = (r - edge0) / (edge1 - edge0); prof = 1 - t * t * (3 - 2 * t) }
        if prof <= 0 { return .zero }
        let decay = s > 0 ? exp(-s / (mixingRadii * R)) : 1
        var v = w.axis * (dv * prof * decay)
        // Swirl: tangential velocity in the rotor's rotation sense, ~ Q / (ρ A (V+Δv) r), only downstream.
        if s > 0 && r > 1e-6 && w.swirl != 0 {
            let rEff = max(r, 0.3 * Rs)
            let vt = w.swirl / (max(w.vAxial + dv, 0.5) * rEff) * prof * decay
            v += simd_cross(-w.axis, rv / r) * vt      // -axis = thrust direction: right-hand rotation about it
        }
        return v
    }

    /// Momentum-theory induced velocity at the disk for thrust T: open rotor T = 2ρA(V+vi)vi,
    /// ducted rotor (exit area = disk area) T = ρA(V+w)w.
    @inline(__always) static func diskVelocity(thrust T: Double, rho: Double, area A: Double, axial V: Double, ducted: Bool) -> Double {
        guard T > 0, rho > 1e-6, A > 1e-9 else { return 0 }
        let Va = max(0, V)
        let k = ducted ? 4.0 : 2.0
        return 0.5 * (-Va + (Va * Va + k * T / (rho * A)).squareRoot())
    }

    /// Cheeseman–Bennett rotor ground effect: T_IGE / T_OGE at constant power, for a disk `h` above ground
    /// (only when the wake points at the ground). Clamped to the validity range z/R ≥ 0.5.
    @inline(__always) static func groundEffectGain(height h: Double, radius R: Double, wakeDown: Double) -> Double {
        guard wakeDown > 0.3, R > 1e-6, h.isFinite else { return 1 }
        let z = max(h, 0.5 * R)
        let x = R / (4 * z)
        let g = 1 / (1 - x * x)
        return 1 + (g - 1) * min(1, (wakeDown - 0.3) / 0.6)
    }
}

/// Read-only, allocation-free view of a WakeField for the current substep.
struct WakeView {
    let buf: UnsafePointer<RotorWake>?
    let count: Int
    static let empty = WakeView(buf: nil, count: 0)
    @inline(__always) func velocity(at p: Vec3d, exclude: Int = -1) -> Vec3d {
        guard let buf else { return .zero }
        var v = Vec3d.zero
        for k in 0..<count where buf[k].owner != exclude { v += WakeField.induced(buf[k], at: p) }
        return v
    }
}

extension CraftSim {
    /// Mark rotors that sit inside a ring of structure (a duct): parts whose centres lie within 1.0–1.7 disk
    /// radii of the rotor axis, near the disk plane, covering at least 9 of 12 sectors around it.
    /// Prop param `duct`: -1 = auto (default), 0 = open, 1 = ducted.
    func detectDucts() {
        for i in parts.indices where parts[i].type == .prop {
            let forced = parts[i].p("duct", -1)
            if forced >= 0 { parts[i].kDucted = forced >= 0.5; continue }
            let axis = simd_normalize(parts[i].baseQ.act([1, 0, 0]))
            let c0 = parts[i].basePos, R = max(0.05, parts[i].kD / 2)
            let ref: Vec3d = abs(axis.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
            let e1 = simd_normalize(simd_cross(axis, ref)), e2 = simd_cross(axis, e1)
            var bins = [Bool](repeating: false, count: 12)
            for j in parts.indices where j != i && (parts[j].isBody || parts[j].isWing) && parts[j].type != .prop {
                let c = parts[j].basePos + parts[j].baseQ.act(parts[j].ctr) - c0
                let s = simd_dot(c, axis)
                let halfLen = 0.5 * max(parts[j].size.x, max(parts[j].size.y, parts[j].size.z))
                if abs(s) > halfLen + 0.25 * R { continue }
                let rv = c - axis * s, r = simd_length(rv)
                if r < 1.0 * R || r > 1.7 * R { continue }
                // Angular coverage: a part's half-width across the ring (middle of its three extents) seen from the axis.
                let ext = [parts[j].size.x, parts[j].size.y, parts[j].size.z].sorted()
                let halfAng = asin(min(1, 0.5 * ext[1] / r))
                let ang = atan2(simd_dot(rv, e2), simd_dot(rv, e1))
                for k in 0..<12 {
                    let mid = -Double.pi + (Double(k) + 0.5) * (2 * Double.pi / 12)
                    var dA = abs(mid - ang); if dA > Double.pi { dA = 2 * Double.pi - dA }
                    if dA <= halfAng + Double.pi / 12 * 0.5 { bins[k] = true }
                }
            }
            parts[i].kDucted = bins.filter { $0 }.count >= 9
        }
    }
}
