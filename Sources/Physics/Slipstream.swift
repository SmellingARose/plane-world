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
    // --- blockage (FastAeroToggles.blockage; defaults reproduce the unblocked wake bit-for-bit)
    /// Own swirl before coaxial recovery (a downstream rotor in this wake absorbs it; see CraftSim wake build).
    var swirl0 = 0.0
    /// Distance downstream at which this wake's swirl is taken over by a downstream rotor (∞ = never).
    var swirlEnd = Double.infinity
    /// Up to 4 bodies inside the wake: centre (world), distance downstream s, shadow radius r_b, half length along the axis.
    var nBlk = 0
    var blkX = SIMD4<Double>(), blkY = SIMD4<Double>(), blkZ = SIMD4<Double>()
    var blkS = SIMD4<Double>(), blkR = SIMD4<Double>(), blkLen = SIMD4<Double>()
    static let maxBlockers = 4
    /// Peak attenuation right behind a blocking body and its mixing-recovery length in shadow radii.
    static let blockDepth = 0.8, blockRecovery = 6.0

    /// Wake attenuation factor at point p (depth s downstream): product over blockers of
    /// 1 − k_b·w(r)·exp(−(s − s_b − ℓ_b)/(6 r_b)), w = 1 inside the body's shadow radius, smooth to 0 at 1.3 r_b.
    @inline(__always) func blockFactor(at p: Vec3d, s: Double) -> Double {
        var f = 1.0
        for k in 0..<nBlk {
            let s0 = blkS[k] + blkLen[k]
            if s <= s0 { continue }
            let d = p - Vec3d(blkX[k], blkY[k], blkZ[k])
            let lat = d - axis * simd_dot(d, axis)
            let r = simd_length(lat), rb = blkR[k]
            if r >= 1.3 * rb { continue }
            var w = 1.0
            if r > rb { let t = (r - rb) / (0.3 * rb); w = 1 - t * t * (3 - 2 * t) }
            f *= 1 - RotorWake.blockDepth * w * exp(-(s - s0) / (RotorWake.blockRecovery * rb))
        }
        return f
    }
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
        if s > 0 && r > 1e-6 && w.swirl != 0 && s < w.swirlEnd {
            let rEff = max(r, 0.3 * Rs)
            let vt = w.swirl / (max(w.vAxial + dv, 0.5) * rEff) * prof * decay
            v += simd_cross(-w.axis, rv / r) * vt      // -axis = thrust direction: right-hand rotation about it
        }
        if w.nBlk > 0 { v *= w.blockFactor(at: p, s: s) }
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

// MARK: - Wing downwash (FastAeroToggles.downwash)
//
// Each group of collinear wing parts (left + right wing + ailerons, a stabilator, a fin) is one horseshoe vortex:
// bound vortex along the group's quarter-chord line with Prandtl's rolled-up span b' = (π/4)·b, trailing legs
// running downstream along the local relative wind. Kutta–Joukowski on the previous substep's group lift gives
//     Γ = |L| / (ρ·V·b')
// and Biot–Savart (with a Rankine-like core r_c) gives the induced velocity at any other surface. Far behind an
// elliptic wing the centre-line downwash is ε = w/V = 16·C_L/(π³·AR) ≈ 0.52·C_L/AR (vs 2C_L/(πAR) ≈ 0.64·C_L/AR
// for the fully rolled-up lifting-line estimate used in stability texts; see docs/PHYSICS.md).
// A group never feels its own horseshoe (its self-induced downwash is already in the finite-AR lift slope).

struct Horseshoe {
    var a = Vec3d.zero, b = Vec3d.zero    // bound-vortex end points (world); vorticity runs a → b
    var u = Vec3d(1, 0, 0)                // downstream direction of the trailing legs (unit)
    var gamma = 0.0                       // circulation (m²/s), ≥ 0 (the a→b orientation carries the sign)
    var rc2 = 0.01                        // core radius squared
    var group = -1
    var chord = 0.0                       // mean chord of the source group (near-field fade, see `induced`)
}

/// Static description of a wing group (craft frame), built at load.
struct WingGroup {
    var center = Vec3d.zero               // quarter-chord midpoint of the span extent
    var axis = Vec3d(0, 0, 1)             // span direction
    var span = 0.0                        // geometric span b of the union of the members
    var chord = 0.0                       // mean chord
    var area = 0.0                        // planform area Σ span·chord
}

/// Per-substep state of a wing group: lift and relative wind from the previous substep (explicit, deterministic).
struct WingGroupState {
    var lift = Vec3d.zero, air = Vec3d.zero    // air = air velocity relative to the group centre
    var accLift = Vec3d.zero
}

struct DownwashView {
    let buf: UnsafePointer<Horseshoe>?
    let count: Int
    static let empty = DownwashView(buf: nil, count: 0)

    @inline(__always) func velocity(at p: Vec3d, excludeGroup g: Int) -> Vec3d {
        guard let buf else { return .zero }
        var v = Vec3d.zero
        for k in 0..<count where buf[k].group != g { v += DownwashView.induced(buf[k], at: p) }
        return v
    }

    /// Semi-infinite vortex line starting at `a` running along unit `u`: Γ/(4π)·(u×r)/(|u×r|²+r_c²)·(1 + u·r̂).
    @inline(__always) static func semiInfinite(_ a: Vec3d, _ u: Vec3d, _ p: Vec3d, rc2: Double) -> Vec3d {
        let r = p - a, rl = simd_length(r)
        if rl < 1e-9 { return .zero }
        let c = simd_cross(u, r)
        return c * ((1 + simd_dot(u, r) / rl) / (simd_length_squared(c) + rc2))
    }
    /// Finite segment a→b: Γ/(4π)·(r1×r2)/(|r1×r2|² + r_c²|r0|²)·r0·(r̂1 − r̂2).
    @inline(__always) static func segment(_ a: Vec3d, _ b: Vec3d, _ p: Vec3d, rc2: Double) -> Vec3d {
        let r1 = p - a, r2 = p - b, r0 = b - a
        let l1 = simd_length(r1), l2 = simd_length(r2)
        if l1 < 1e-9 || l2 < 1e-9 { return .zero }
        let c = simd_cross(r1, r2)
        let den = simd_length_squared(c) + rc2 * simd_length_squared(r0)
        if den < 1e-18 { return .zero }
        return c * (simd_dot(r0, r1 / l1 - r2 / l2) / den)
    }
    /// Horseshoe: leg from downstream infinity into a, bound a→b, leg from b to downstream infinity.
    @inline(__always) static func induced(_ h: Horseshoe, at p: Vec3d) -> Vec3d {
        if h.gamma == 0 { return .zero }
        // Near-field fade: a surface level with the bound vortex (|s| < ½c streamwise, e.g. crossed exhaust vanes)
        // gets no induced velocity, ramping to full at |s| = 1.5c. Without it two such groups feed each other
        // explicitly every substep with loop gain ≈ a·k/(4π·0.3) ≳ 1 (independent of V) and diverge to NaN.
        var fade = 1.0
        if h.chord > 0 {
            let s = abs(simd_dot(p - (h.a + h.b) * 0.5, h.u))
            if s < 1.5 * h.chord { fade = max(0, (s - 0.5 * h.chord) / h.chord); if fade == 0 { return .zero } }
        }
        let v = segment(h.a, h.b, p, rc2: h.rc2) + semiInfinite(h.b, h.u, p, rc2: h.rc2) - semiInfinite(h.a, h.u, p, rc2: h.rc2)
        return fade == 1 ? v * (h.gamma / (4 * Double.pi)) : v * (h.gamma / (4 * Double.pi) * fade)
    }
}

extension CraftSim {
    /// Group collinear wing parts (span axes within 10°, quarter-chord lines within half a chord, span gap below
    /// one chord) into horseshoe groups; sets `SimPart.wingGroup`.
    func buildWingGroups() {
        var groupOf = [Int](repeating: -1, count: parts.count)
        var groups: [WingGroup] = []
        let wings = parts.indices.filter { parts[$0].type == .wing }
        func qc(_ i: Int) -> Vec3d { parts[i].basePos + parts[i].baseQ.act([1, 0, 0]) * (parts[i].kChord * 0.25) }
        func zAxis(_ i: Int) -> Vec3d { simd_normalize(parts[i].baseQ.act([0, 0, 1])) }
        var parent = [Int: Int](); for i in wings { parent[i] = i }
        func find(_ i: Int) -> Int { var r = i; while parent[r]! != r { r = parent[r]! }; return r }
        for (ai, i) in wings.enumerated() {
            for j in wings[(ai + 1)...] {
                let zi = zAxis(i), zj = zAxis(j)
                if abs(simd_dot(zi, zj)) < 0.985 { continue }
                let d = qc(j) - qc(i), along = simd_dot(d, zi)
                let perp = simd_length(d - zi * along)
                let cmax = max(parts[i].kChord, parts[j].kChord)
                if perp > 0.5 * cmax { continue }
                let gap = abs(along) - 0.5 * (parts[i].kSpan + parts[j].kSpan)
                if gap > cmax { continue }
                parent[find(j)] = find(i)
            }
        }
        var rootToGroup = [Int: Int]()
        for i in wings {
            let r = find(i)
            if let g = rootToGroup[r] { groupOf[i] = g; continue }
            rootToGroup[r] = groups.count; groupOf[i] = groups.count; groups.append(WingGroup())
        }
        for g in groups.indices {
            let members = wings.filter { groupOf[$0] == g }
            let ax = zAxis(members[0]), ref = qc(members[0])
            var lo = Double.infinity, hi = -Double.infinity, perpSum = Vec3d.zero, area = 0.0
            for i in members {
                let along = simd_dot(qc(i) - ref, ax)
                lo = min(lo, along - parts[i].kSpan / 2); hi = max(hi, along + parts[i].kSpan / 2)
                let a = parts[i].kSpan * parts[i].kChord
                perpSum += (qc(i) - ax * simd_dot(qc(i), ax)) * a; area += a
            }
            let perp = area > 0 ? perpSum / area : ref - ax * simd_dot(ref, ax)
            let mid = simd_dot(ref, ax) + 0.5 * (lo + hi)
            groups[g] = WingGroup(center: perp + ax * mid, axis: ax, span: hi - lo, chord: area / max(hi - lo, 1e-6), area: area)
        }
        for i in parts.indices { parts[i].wingGroup = groupOf[i] }
        wingGroups = groups
        groupState.deallocate(); horseshoes.deallocate()
        groupState = .allocate(capacity: max(1, groups.count)); groupState.initialize(repeating: WingGroupState(), count: max(1, groups.count))
        horseshoes = .allocate(capacity: max(1, groups.count)); horseshoes.initialize(repeating: Horseshoe(), count: max(1, groups.count))
        horseshoeCount = 0
    }

    /// Induced (downwash/upwash) velocity of every wing group except `excludeGroup` at world point p, from the
    /// horseshoes of the last substep (tests / UI).
    public func downwashVelocity(at p: Vec3d, excludeGroup: Int = -1) -> Vec3d {
        DownwashView(buf: horseshoeCount > 0 ? UnsafePointer(horseshoes) : nil, count: horseshoeCount).velocity(at: p, excludeGroup: excludeGroup)
    }
}
