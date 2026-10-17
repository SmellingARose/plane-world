// Parity exporter support (docs/PORT_PLAN.md): unit-level reference samples of the wing, propeller and rotor-wake
// models for the C++ port. Read-only use of the models; nothing here runs in the simulation.
import Foundation
import simd
import PWCore

public enum ParityUnits {
    /// Shortest round-trip decimal for a Double (null for non-finite), so JSON readers recover the exact bits.
    public static func num(_ d: Double) -> String { d.isFinite ? "\(d)" : "null" }
    static func arr(_ v: [Double]) -> String { "[" + v.map(num).joined(separator: ",") + "]" }

    /// JSON document: wing coefficient sweeps, propeller thrust sweeps, disk velocity and wake induced-velocity samples.
    public static func json() -> String {
        var out: [String] = []
        // Wing: several planforms x alpha -30..30 deg x Mach/Re pairs x flap deflections; both the reference and the
        // hoisted-constant path (must be bit-identical).
        var wing: [String] = []
        let params: [Aero.WingParams] = [
            .init(aspectRatio: 6, camberCl0: 0.25, thicknessRatio: 0.12, flapChordFraction: 0),
            .init(aspectRatio: 8, camberCl0: 0.3, thicknessRatio: 0.15, flapChordFraction: 0.25),
            .init(aspectRatio: 3, camberCl0: 0, thicknessRatio: 0.06, flapChordFraction: 0.3),
            .init(aspectRatio: 1.2, camberCl0: 0.1, thicknessRatio: 0.03, flapChordFraction: 0),
        ]
        let conds: [(Double, Double)] = [(0.05, 2e5), (0.3, 3e6), (0.75, 1e7), (0.0, 5e3)]
        for (pi, p) in params.enumerated() {
            let k = Aero.WingConst(p)
            for (m, re) in conds {
                for delta in [0.0, 10 * kDeg, -25 * kDeg] {
                    for ai in stride(from: -30, through: 30, by: 2) {
                        let a = Double(ai) * kDeg
                        let c = Aero.wing(alpha: a, mach: m, reynolds: re, params: p, flapDeflection: delta)
                        let c2 = Aero.wing(alpha: a, mach: m, reynolds: re, const: k, flapDeflection: delta)
                        let g = Aero.groundEffect(height: 0.5 + Double(ai + 30) * 0.05, span: 4)
                        wing.append("{\"p\":\(pi),\"in\":\(arr([a, m, re, delta])),\"ref\":\(arr([c.cl, c.cd, c.stalled ? 1 : 0, c.centerOfPressure, c.hingeCh])),\"hoisted\":\(arr([c2.cl, c2.cd, c2.stalled ? 1 : 0, c2.centerOfPressure, c2.hingeCh])),\"ge\":\(arr([g.phi, g.liftGain]))}")
                    }
                }
            }
        }
        out.append("\"wingParams\":[" + params.map { arr([$0.aspectRatio, $0.camberCl0, $0.thicknessRatio, $0.flapChordFraction]) }.joined(separator: ",") + "]")
        out.append("\"wing\":[\n" + wing.joined(separator: ",\n") + "]")
        // Propeller: power from static thrust, then thrust over axial speed.
        var prop: [String] = []
        for (t0, d, vmax) in [(50.0, 0.5, 40.0), (400.0, 1.2, 70.0), (8.0, 0.2, 25.0)] {
            let P = Propulsion.propPower(staticThrust: t0, diameter: d)
            for rho in [1.225, 0.9] {
                for vi in stride(from: -5, through: 80, by: 5) {
                    let r = Propulsion.propThrust(power: P, diameter: d, rho: rho, axialSpeed: Double(vi), pitchSpeed: vmax)
                    prop.append("{\"in\":\(arr([t0, d, vmax, rho, Double(vi)])),\"power\":\(num(P)),\"out\":\(arr([r.thrust, r.advanceRatio, r.rps]))}")
                }
            }
        }
        out.append("\"prop\":[\n" + prop.joined(separator: ",\n") + "]")
        var misc: [String] = []
        for M in [0.0, 0.4, 0.9] { for rho in [1.225, 0.6] { misc.append("{\"fn\":\"jetLapse\",\"in\":\(arr([rho, M])),\"out\":\(num(Propulsion.jetLapse(rho: rho, mach: M)))}") } }
        for (n, c) in [(0.0, 1.0), (0.8, 0.2)] { misc.append("{\"fn\":\"spool\",\"in\":\(arr([n, c, 0.001])),\"out\":\(num(Propulsion.spool(n, command: c, dt: 0.001)))}") }
        for (f, t) in [(1.0, 0.02), (0.5, 1.0), (0.02, 3.0)] { misc.append("{\"fn\":\"solidProfile\",\"in\":\(arr([f, t, 80000])),\"out\":\(num(Propulsion.solidProfile(fuelFraction: f, sinceIgnition: t, ambientPressure: 80000)))}") }
        for (T, V, d) in [(100.0, 0.0, false), (100.0, 20.0, false), (100.0, 5.0, true), (0.0, 5.0, false)] {
            misc.append("{\"fn\":\"diskVelocity\",\"in\":\(arr([T, 1.225, 0.5, V, d ? 1 : 0])),\"out\":\(num(WakeField.diskVelocity(thrust: T, rho: 1.225, area: 0.5, axial: V, ducted: d)))}")
        }
        for h in [0.1, 0.5, 1.0, 3.0] { misc.append("{\"fn\":\"rotorGroundEffect\",\"in\":\(arr([h, 0.4, 0.8])),\"out\":\(num(WakeField.groundEffectGain(height: h, radius: 0.4, wakeDown: 0.8)))}") }
        out.append("\"misc\":[\n" + misc.joined(separator: ",\n") + "]")
        // Wake: a few rotor wakes sampled on a line grid around the disk (axial, radial, swirl, crossflow drift).
        var wakes: [String] = []
        var ws: [RotorWake] = []
        var w = RotorWake(); w.center = Vec3d(0, 1, 0); w.axis = Vec3d(-1, 0, 0); w.radius = 0.4; w.vi = 8; w.vAxial = 10
        w.cross = Vec3d(0, 0, 1.5); w.swirl = 3; w.owner = 0; ws.append(w)
        var wd = w; wd.ducted = true; wd.swirl = -2; wd.cross = .zero; ws.append(wd)
        var wb = w; wb.nBlk = 1; wb.blkX = SIMD4(-0.8, 0, 0, 0); wb.blkY = SIMD4(1, 0, 0, 0); wb.blkZ = SIMD4(0, 0, 0, 0)
        wb.blkS = SIMD4(0.8, 0, 0, 0); wb.blkR = SIMD4(0.15, 0, 0, 0); wb.blkLen = SIMD4(0.2, 0, 0, 0); wb.swirlEnd = 2; ws.append(wb)
        for (wi, wk) in ws.enumerated() {
            for s in stride(from: -2.0, through: 8.0, by: 0.5) {
                for r in [0.0, 0.2, 0.36, 0.42, 0.5, 0.9] {
                    let p = wk.center + wk.axis * s + Vec3d(0, r * 0.6, r * 0.8)
                    let v = WakeField.induced(wk, at: p)
                    wakes.append("{\"w\":\(wi),\"p\":\(arr([p.x, p.y, p.z])),\"v\":\(arr([v.x, v.y, v.z]))}")
                }
            }
        }
        out.append("\"wakeDefs\":[" + ws.map { k in
            "{\"center\":\(arr([k.center.x, k.center.y, k.center.z])),\"axis\":\(arr([k.axis.x, k.axis.y, k.axis.z])),\"radius\":\(num(k.radius)),\"vi\":\(num(k.vi)),\"vAxial\":\(num(k.vAxial)),\"cross\":\(arr([k.cross.x, k.cross.y, k.cross.z])),\"swirl\":\(num(k.swirl)),\"ducted\":\(k.ducted),\"swirlEnd\":\(k.swirlEnd.isFinite ? num(k.swirlEnd) : "\"inf\""),\"nBlk\":\(k.nBlk),\"blk\":[\(arr([k.blkX[0], k.blkY[0], k.blkZ[0], k.blkS[0], k.blkR[0], k.blkLen[0]]))]}"
        }.joined(separator: ",") + "]")
        out.append("\"wake\":[\n" + wakes.joined(separator: ",\n") + "]")
        return "{\"schema\":\"planeworld.parity.units/1\",\n" + out.joined(separator: ",\n") + "}\n"
    }
}
