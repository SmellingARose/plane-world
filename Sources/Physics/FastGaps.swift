// OWNED BY physics (fast-model) builder. New fast-model effects (docs/FIDELITY.md, FastAeroToggles), each used only
// when `CraftSim.slipstream` is on and its toggle is set, so the slipstream-off digest stays bit-identical:
//   • gyro      – rotor/wheel angular momentum coupling (inline in substepCore: τ = −ω × h_r)
//   • pFactor   – asymmetric disk loading at incidence (thrust-centre offset + in-plane normal force)
//   • downwash  – horseshoe-vortex induced velocity of upstream wing groups on other surfaces (Slipstream.swift)
//   • blockage  – body shadows in rotor wakes + coaxial swirl recovery by a downstream rotor
//   • cadWash   – CAD panels sample wakes + downwash per panel (PanelAero.swift)
// Plus the allocation-free equation capture for the EQUATIONS panel (only on a requested substep).
import Foundation
import simd
import PWCore

extension CraftSim {
    // MARK: P-factor

    struct PFactorLoads { var offset = Vec3d.zero, normal = Vec3d.zero, vc = 0.0, mu = 0.0, alphaDeg = 0.0 }

    /// Propeller at incidence. `rel` = air velocity relative to the disk, `dir` = thrust direction, `omega` signed
    /// spin about `dir`. Crossflow v_c = |rel⊥| gives the advance ratio along the disk μ = v_c/(|Ω|R).
    ///  • Thrust-centre offset: blade-element thrust ∝ (Ωr + v_c sin ψ)² puts the centroid at e = μ·R toward the blade
    ///    advancing into the crossflow; induced-inflow relief roughly halves it, so e = ½·μ·R (capped at 0.3 R).
    ///    The advancing side is d̂ = (Ω̂ × v̂_c). Moment M = e·d̂ × T·dir (left-turning tendency of a clockwise prop
    ///    seen from behind, nose-up).
    ///  • In-plane normal force: the disk turns a fraction k_N = ½ of the crossflow of its mass flow,
    ///    N = k_N·ρA(V_ax + v_i)·v_c along the crossflow (momentum / "ram drag" estimate).
    @inline(__always) static func pFactorLoads(dir: Vec3d, rel: Vec3d, thrust T: Double, omega: Double, radius R: Double,
                                               rho: Double, axial: Double, vi: Double) -> PFactorLoads {
        var out = PFactorLoads()
        let ax = simd_dot(rel, dir)
        let vc = rel - dir * ax, vcs = simd_length(vc)
        if vcs < 1e-3 || abs(omega) < 1e-6 { return out }
        let ch = vc / vcs
        out.vc = vcs
        out.mu = vcs / (abs(omega) * R)
        out.alphaDeg = atan2(vcs, max(abs(ax), 1e-9)) / kDegF
        let e = min(0.3 * R, 0.5 * out.mu * R)
        let wHat = omega >= 0 ? dir : -dir
        let adv = simd_cross(wHat, ch)
        out.offset = adv * e
        out.normal = ch * (0.5 * rho * Double.pi * R * R * (max(0, axial) + vi) * vcs)
        return out
    }

    // MARK: Blockage

    /// Bodies inside each rotor wake shadow it (up to 4 nearest per wake), and a coaxial downstream rotor takes over
    /// the upstream wake's swirl (angular-momentum flux of the pair = Σ shaft torques, so a counter-rotating pair
    /// leaves almost no swirl behind it).
    @inline(never) func applyBlockage(_ P: UnsafeMutablePointer<SimPart>, _ np: Int, _ q: Quatd, _ origin: Vec3d, _ cap: EquationCapture?) {
        for k in 0..<wakeCount {
            var w = wakeBuf[k]
            let R = w.radius
            w.nBlk = 0
            for j in 0..<np where P[j].isBlocker {
                let qp = q * P[j].effQ
                let c = origin + q.act(P[j].basePos + P[j].effQ.act(P[j].ctr))
                let d = c - w.center, s = simd_dot(d, w.axis)
                if s <= 0.1 * R || s > WakeField.mixingRadii * 4 * R { continue }
                let lat = simd_length(d - w.axis * s)
                if lat > R { continue }
                let a = qp.inverse.act(w.axis), sz = P[j].size
                let A = abs(a.x) * sz.y * sz.z + abs(a.y) * sz.x * sz.z + abs(a.z) * sz.x * sz.y
                if A < 1e-6 { continue }
                let rb = (A / Double.pi).squareRoot()
                let len = 0.5 * (abs(a.x) * sz.x + abs(a.y) * sz.y + abs(a.z) * sz.z)
                // keep the nearest RotorWake.maxBlockers (insertion by s)
                var slot = w.nBlk
                if slot == RotorWake.maxBlockers { if s >= w.blkS[slot - 1] { continue }; slot -= 1 } else { w.nBlk += 1 }
                while slot > 0 && w.blkS[slot - 1] > s {
                    w.blkS[slot] = w.blkS[slot - 1]; w.blkR[slot] = w.blkR[slot - 1]; w.blkLen[slot] = w.blkLen[slot - 1]
                    w.blkX[slot] = w.blkX[slot - 1]; w.blkY[slot] = w.blkY[slot - 1]; w.blkZ[slot] = w.blkZ[slot - 1]
                    slot -= 1
                }
                w.blkS[slot] = s; w.blkR[slot] = rb; w.blkLen[slot] = len; w.blkX[slot] = c.x; w.blkY[slot] = c.y; w.blkZ[slot] = c.z
                if let cap {
                    var r = EquationRecord(); r.id = .blockage; r.partIndex = Int32(j)
                    r.set(0, s); r.set(1, rb); r.set(2, A); r.set(3, R); r.set(4, 1 - RotorWake.blockDepth)
                    cap.append(r)
                }
            }
            wakeBuf[k] = w
        }
        // Coaxial swirl recovery (one level: the nearest downstream rotor inside the wake core).
        for k in 0..<wakeCount {
            let wk = wakeBuf[k]
            var best = -1, bestS = Double.infinity
            for j in 0..<wakeCount where j != k {
                let d = wakeBuf[j].center - wk.center, s = simd_dot(d, wk.axis)
                if s <= 0 || s > WakeField.mixingRadii * 4 * wk.radius { continue }
                if simd_length(d - wk.axis * s) > wk.radius || simd_dot(wakeBuf[j].axis, wk.axis) < 0.8 { continue }
                if s < bestS { bestS = s; best = j }
            }
            if best >= 0 { wakeBuf[k].swirlEnd = bestS; wakeBuf[best].swirl += wk.swirl0 }
        }
    }

    // MARK: Downwash

    /// Build this substep's horseshoes from the previous substep's group lift and relative wind.
    @inline(never) func buildHorseshoes(_ q: Quatd, _ origin: Vec3d, _ rho: Double) {
        var n = 0
        for g in 0..<wingGroups.count {
            let G = wingGroups[g], st = groupState[g]
            let Lm = simd_length(st.lift), Vm = simd_length(st.air)
            if Vm < 1 || Lm < 1e-6 || rho < 1e-6 { continue }
            let ax = q.act(G.axis), Lh = st.lift / Lm, Vh = st.air / Vm
            let gh = simd_cross(Lh, Vh)               // Kutta–Joukowski: ρV×Γ = L  ⇒  Γ̂ = L̂ × V̂
            let al = simd_dot(ax, gh)
            if abs(al) < 0.3 { continue }               // lift not across the span: no meaningful bound vortex
            let bp = Double.pi / 4 * G.span
            let c = origin + q.act(G.center)
            let half = ax * ((al >= 0 ? 0.5 : -0.5) * bp)
            let rc = max(0.05 * bp, 0.3 * G.chord)
            horseshoes[n] = Horseshoe(a: c - half, b: c + half, u: Vh, gamma: Lm / (rho * Vm * bp), rc2: rc * rc, group: g, chord: G.chord)
            n += 1
        }
        horseshoeCount = n
    }

    /// Group index of a wing part (−1 if none) and its static description (tests / UI).
    public func wingGroupIndex(partID: String) -> Int { parts.first { $0.doc.id == partID }?.wingGroup ?? -1 }
    public var wingGroupCount: Int { wingGroups.count }

    // MARK: Gyroscopic coupling

    /// Σ −ω × h_r over spinning props (h = I_r·Ω·x̂_part) and wheels (rolling forward spins about −axle: h = −I_r·Ω·ẑ_part).
    @inline(never) func gyroTorque(_ P: UnsafeMutablePointer<SimPart>, _ np: Int, _ q: Quatd, _ wW: Vec3d, _ cap: EquationCapture?) -> Vec3d {
        var T = Vec3d.zero
        for i in 0..<np where P[i].kIrot > 0 && P[i].omega != 0 {
            let hv: Vec3d
            if P[i].type == .prop { hv = q.act(P[i].effQ.act(Vec3d(1, 0, 0))) * (P[i].kIrot * P[i].omega) }
            else if P[i].type == .wheel { hv = q.act(P[i].effQ.act(Vec3d(0, 0, 1))) * (-P[i].kIrot * P[i].omega) }
            else { continue }
            let tq = -simd_cross(wW, hv)
            T += tq
            if let cap {
                var r = EquationRecord(); r.id = .gyroscopic; r.partIndex = Int32(i)
                r.set(0, P[i].kIrot); r.set(1, abs(P[i].omega)); r.set(2, simd_length(wW)); r.set(3, simd_length(hv)); r.set(4, simd_length(tq))
                r.result = ForceTorque(force: .zero, torque: tq); cap.append(r)
            }
        }
        return T
    }

    // MARK: Equation capture (requested substeps only)

    @inline(never) func captureBodyDrag(_ i: Int, rho: Double, speed sp: Double, cd: Double, area A: Double, v: Vec3d, pw: Vec3d, cap: EquationCapture) {
        var r = EquationRecord(); r.id = .bodyDrag; r.partIndex = Int32(i)
        r.set(0, rho); r.set(1, sp); r.set(2, cd); r.set(3, A); r.set(4, 0.5 * rho * sp * sp * cd * A)
        let f = v * (-0.5 * rho * sp * cd * A); r.result = ForceTorque(force: f, torque: simd_cross(pw - position, f)); cap.append(r)
    }

    @inline(never) func capturePFactor(_ i: Int, _ P: UnsafeMutablePointer<SimPart>, _ pf: PFactorLoads, dir: Vec3d, pw: Vec3d, thrust Tn: Double, cap: EquationCapture) {
        var rec = EquationRecord(); rec.id = .pFactor; rec.partIndex = Int32(i)
        rec.set(0, pf.alphaDeg); rec.set(1, pf.vc); rec.set(2, abs(P[i].omega)); rec.set(3, max(0.05, P[i].kD / 2)); rec.set(4, pf.mu)
        rec.set(5, simd_length(pf.offset)); rec.set(6, Tn); rec.set(7, simd_length(pf.normal))
        let mom = simd_cross(pf.offset, dir * Tn); rec.set(8, simd_length(mom))
        rec.result = ForceTorque(force: pf.normal, torque: mom + simd_cross(pw - position, pf.normal)); cap.append(rec)
    }

    /// Sum this substep's strip lift per wing group and record the group's relative wind (used next substep).
    @inline(never) func accumulateGroupLift(_ buf: UnsafeMutablePointer<StripResult>, _ ns: Int, _ P: UnsafeMutablePointer<SimPart>,
                                            _ q: Quatd, _ origin: Vec3d, _ windHere: Vec3d, _ velocity: Vec3d, _ wW: Vec3d,
                                            _ wakes: WakeView) {
        let ng = wingGroups.count
        for g in 0..<ng { groupState[g].accLift = .zero }
        strips.withUnsafeBufferPointer { sb in
            for si in 0..<ns { let g = P[sb[si].part].wingGroup; if g >= 0 { groupState[g].accLift += buf[si].lift } }
        }
        wingGroups.withUnsafeBufferPointer { G in
            for g in 0..<ng {
                let cw = origin + q.act(G[g].center)
                groupState[g].lift = groupState[g].accLift
                // Local stream at the group centre, rotor wakes included: Γ = L/(ρVb') must use the speed the wing
                // actually sees. With the free stream only, a vane in a hovering craft's jet (free stream ≈ 1 m/s,
                // jet ≈ 20 m/s) got a ~20× circulation and the explicit vane↔vane coupling diverged to NaN.
                groupState[g].air = windHere + wakes.velocity(at: cw) - (velocity + simd_cross(wW, cw - position))
            }
        }
    }

    @inline(never) func captureStrips(_ buf: UnsafeMutablePointer<StripResult>, _ ns: Int,
                                      _ P: UnsafeMutablePointer<SimPart>, rho: Double, sos: Double, dw: DownwashView, cap: EquationCapture) {
        strips.withUnsafeBufferPointer { sbp in
        let sb = sbp.baseAddress!
        for si in 0..<ns {
            let r = buf[si], pi = sb[si].part
            if r.speed < 0.3 { continue }
            let k = P[pi].wing, p = k.params, area = sb[si].area
            let M = min(r.speed / sos, 0.8), beta = (1 - M * M).squareRoot()
            let slope = Aero.liftSlope(aspectRatio: p.aspectRatio, mach: r.speed / sos) * r.gain
            var cl0 = p.camberCl0 / beta, dcl = 0.0
            if p.flapChordFraction > 0 && r.flap != 0 {
                let eff = 0.75 - 0.25 * smoothstep(15 * kDegF, 40 * kDegF, abs(r.flap))
                dcl = slope * k.flapTau * eff * r.flap; cl0 += dcl
                var f = EquationRecord(); f.id = .flapIncrement; f.partIndex = Int32(pi)
                f.set(0, k.flapTau); f.set(1, eff); f.set(2, r.flap / kDegF); f.set(3, slope); f.set(4, dcl); cap.append(f)
            }
            let qS = 0.5 * rho * r.speed * r.speed * area
            let ft = r.ft
            var l = EquationRecord(); l.id = .wingLift; l.partIndex = Int32(pi)
            l.set(0, slope); l.set(1, r.alpha / kDegF); l.set(2, -cl0 / slope / kDegF); l.set(3, rho); l.set(4, r.speed); l.set(5, area)
            l.set(6, r.cl); l.set(7, r.cl * qS)
            l.result = ForceTorque(force: r.lift, torque: .zero); cap.append(l)
            var d = EquationRecord(); d.id = .wingDrag; d.partIndex = Int32(pi)
            let cf = 0.455 / pow(log10(max(r.re, 1e4)), 2.58), cd0 = 2 * cf * k.thickFactor
            d.set(0, rho); d.set(1, r.speed); d.set(2, area); d.set(3, cd0); d.set(4, r.cl); d.set(5, p.aspectRatio); d.set(6, 0.8)
            d.set(7, r.phi); d.set(8, r.cd); d.set(9, r.cd * qS)
            d.result = ForceTorque(force: ft.force - r.lift, torque: .zero); cap.append(d)
            var m = EquationRecord(); m.id = .wingMoment; m.partIndex = Int32(pi)
            m.set(0, r.cp); m.set(1, P[pi].kChord); m.set(2, r.ch); m.set(3, r.hinge)
            m.result = ft; cap.append(m)
            let stall = (11 + 5 * smoothstep(5, 7, log10(max(r.re, 1e3))) - k.stallThick) * kDegF
            let aZL = r.alpha + cl0 / slope
            if r.stalled || abs(aZL) > 0.8 * stall {
                var s = EquationRecord(); s.id = .stall; s.partIndex = Int32(pi)
                s.set(0, aZL / kDegF); s.set(1, stall / kDegF); s.set(2, r.re); s.set(3, (abs(aZL) - stall) / kDegF); s.set(4, r.cl); cap.append(s)
            }
            if dw.count > 0 {
                let v = dw.velocity(at: r.pac, excludeGroup: P[pi].wingGroup)
                // downwash component normal to the local flow, positive downward relative to the strip's lift
                let lh = simd_length(r.lift) > 1e-9 ? r.lift / simd_length(r.lift) : Vec3d(0, 1, 0)
                let wv = -simd_dot(v, lh)
                var e = EquationRecord(); e.id = .downwash; e.partIndex = Int32(pi)
                var gam = 0.0, bp = 0.0
                for h in 0..<dw.count where dw.buf![h].group != P[pi].wingGroup { gam = max(gam, dw.buf![h].gamma); bp = max(bp, simd_length(dw.buf![h].b - dw.buf![h].a)) }
                e.set(0, gam); e.set(1, bp); e.set(2, wv); e.set(3, r.speed); e.set(4, atan2(wv, r.speed) / kDegF); cap.append(e)
            }
        }
        }
    }

    @inline(never) func captureProp(_ i: Int, _ P: UnsafeMutablePointer<SimPart>, dir: Vec3d, pw: Vec3d, P0: Double, vax: Double, thrust Tn: Double,
                                    dEff: Double, targetOmega: Double, rho: Double, slip: Bool, groundH: Double, inflow: Vec3d, cap: EquationCapture) {
        let R = max(0.05, P[i].kD / 2), A = Double.pi * dEff * dEff / 4
        let f = dir * Tn, ft = ForceTorque(force: f, torque: simd_cross(pw - position, f))
        let vi = slip ? P[i].vi : WakeField.diskVelocity(thrust: max(Tn, 0), rho: rho, area: A, axial: vax, ducted: false)
        var m = EquationRecord(); m.id = .propMomentum; m.partIndex = Int32(i)
        m.set(0, 0.75); m.set(1, P0); m.set(2, vax); m.set(3, vi); m.set(4, rho); m.set(5, A); m.set(6, Tn); m.result = ft; cap.append(m)
        var t = EquationRecord(); t.id = .propTorque; t.partIndex = Int32(i)
        let Q = abs(targetOmega) > 1 ? P0 * 0.75 / abs(targetOmega) : 0
        t.set(0, 0.75); t.set(1, P0); t.set(2, abs(targetOmega)); t.set(3, slip ? Q : 0.25 * Q)
        t.result = ForceTorque(force: .zero, torque: -dir * ((slip ? Q : 0.25 * Q) * (P[i].omega >= 0 ? 1 : -1))); cap.append(t)
        guard slip else { return }
        if P[i].kDucted {
            var d = EquationRecord(); d.id = .ductThrust; d.partIndex = Int32(i)
            d.set(0, 1); d.set(1, P[i].kD); d.set(2, dEff); d.set(3, Tn); cap.append(d)
        }
        var g = EquationRecord(); g.id = .rotorGroundEffect; g.partIndex = Int32(i)
        g.set(0, groundH); g.set(1, R); g.set(2, max(groundH, 0.5 * R) / R); g.set(3, dir.y)
        g.set(4, WakeField.groundEffectGain(height: groundH, radius: R, wakeDown: dir.y)); cap.append(g)
        var s = EquationRecord(); s.id = .slipstreamVelocity; s.partIndex = Int32(i)
        s.set(0, P[i].vi); s.set(1, R); s.set(2, P[i].kDucted ? P[i].vi : 2 * P[i].vi); s.set(3, simd_length(inflow)); cap.append(s)
    }

    @inline(never) func capturePanels(_ i: Int, _ P: UnsafeMutablePointer<SimPart>, _ ft: ForceTorque, _ pb: PanelBatch,
                                      rho: Double, nu: Double, sos: Double, cap: EquationCapture) {
        let slot = P[i].meshSlot
        let b = pb.meshes[slot].breakdown(toWorld: pb.qp[slot], origin: pb.op[slot], com: pb.com, linVel: pb.linVel, angVel: pb.angVel,
                                          wind: pb.wind, wash: pb.washOn ? pb.wash : nil, rho: rho, nu: nu, speedOfSound: sos)
        var n = EquationRecord(); n.id = .panelNewtonian; n.partIndex = Int32(i)
        n.set(0, Double(b.panels)); n.set(1, Double(b.windward)); n.set(2, Double(b.shadowedWindward)); n.set(3, b.maxQ); n.set(4, simd_length(b.pressure))
        n.result = ForceTorque(force: b.pressure, torque: .zero); cap.append(n)
        var f = EquationRecord(); f.id = .panelFriction; f.partIndex = Int32(i)
        f.set(0, b.meanRe); f.set(1, b.meanCf); f.set(2, simd_length(b.friction))
        f.result = ForceTorque(force: b.friction, torque: .zero); cap.append(f)
        if pb.washOn {
            var w = EquationRecord(); w.id = .cadWash; w.partIndex = Int32(i)
            w.set(0, Double(b.panels)); w.set(1, b.washMean); w.set(2, b.washMax); w.result = ft; cap.append(w)
        }
    }
}
