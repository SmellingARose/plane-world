// OWNED BY aero/physics builder.
// Propulsion models: propeller (actuator-disk momentum theory with fixed-pitch advance-ratio unloading),
// turbojet (density/Mach thrust lapse + first-order spool lag), solid rocket (ignition latch, ramp,
// tail-off, ambient-pressure correction).
import Foundation
import PWCore

public enum Propulsion {
    /// Shaft power (W) implied by a static-thrust rating via ideal momentum theory: P = sqrt(T³ / (2ρA)), η_static = 0.75.
    @inlinable public static func propPower(staticThrust T0: Double, diameter d: Double, rho0: Double = 1.225) -> Double {
        let A = Double.pi * d * d / 4
        return (T0 * T0 * T0 / (2 * rho0 * A)).squareRoot() / 0.75
    }

    /// Propeller thrust (N) at axial inflow `V` (m/s, + = flying forward) for shaft power `P`.
    /// Momentum theory T·(V + v_i) = η·P solved by Newton, then fixed-pitch unloading as V approaches pitch speed.
    public static func propThrust(power P: Double, diameter d: Double, rho: Double, axialSpeed V: Double, pitchSpeed vmax: Double) -> (thrust: Double, advanceRatio: Double, rps: Double) {
        guard P > 0, rho > 1e-6 else { return (0, 0, 0) }
        let A = Double.pi * d * d / 4, eta = 0.75
        let Va = max(0, V)
        // solve f(T) = T*(Va + vi(T)) - eta*P = 0, vi = -Va/2 + sqrt(Va²/4 + T/(2ρA))
        var T = pow(2 * rho * A * eta * eta * P * P, 1.0 / 3.0)
        for _ in 0..<8 {
            let s = (Va * Va / 4 + T / (2 * rho * A)).squareRoot()
            let vi = -Va / 2 + s
            let f = T * (Va + vi) - eta * P
            let df = (Va + vi) + T / (4 * rho * A * s)
            T = max(0, T - f / df)
        }
        let pitchRatio = 0.8
        let rps = vmax / (pitchRatio * d)
        let J = Va / max(rps * d, 1e-6)
        let unload = max(0, 1 - pow(Va / max(vmax, 1), 3))
        return (T * unload, J, rps)
    }

    /// Turbojet thrust lapse: T/T0 = σ^0.7 · (1 − 0.25 M + 0.45 M²), σ = ρ/ρ0.
    @inlinable public static func jetLapse(rho: Double, mach M: Double) -> Double {
        pow(max(rho, 0) / 1.225, 0.7) * max(0, 1 - 0.25 * M + 0.45 * M * M)
    }
    /// Spool dynamics: dN/dt = (N_cmd − N)/τ, faster spool-down.
    @inlinable public static func spool(_ N: Double, command: Double, dt: Double) -> Double {
        let tau = command > N ? 1.6 : 0.9
        return N + (command - N) * min(1, dt / tau)
    }
    /// Solid motor thrust multiplier vs. time since ignition (0.08 s ramp, 4% tail-off of the propellant).
    @inlinable public static func solidProfile(fuelFraction f: Double, sinceIgnition t: Double, ambientPressure p: Double) -> Double {
        let ramp = min(1, t / 0.08)
        let tail = f < 0.04 ? f / 0.04 : 1
        return ramp * (0.3 + 0.7 * tail) * (1 + 0.08 * (1 - p / 101325))   // nozzle pressure-thrust term
    }
}
