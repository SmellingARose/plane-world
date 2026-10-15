// Fixed-step simulation clock. Real time is accumulated and consumed in fixed substeps
// (default 1/600 s, configurable 500–1000 Hz). Rendering interpolates with `alpha`.
import Foundation

public final class SimulationClock: @unchecked Sendable {
    public var substepHz: Double { didSet { substepHz = clamp(substepHz, 60, 2000) } }
    public var timeScale: Double = 1
    public var paused = false
    /// Never simulate more than this much real time per frame (avoids spiral of death).
    public var maxFrameTime: Double = 0.1
    public private(set) var simTime: Double = 0
    public private(set) var accumulator: Double = 0
    public private(set) var lastSubsteps = 0
    public var dt: Double { 1 / substepHz }
    /// Interpolation factor between previous and current substep state, for rendering.
    public var alpha: Double { accumulator / dt }

    public init(substepHz: Double = 600) { self.substepHz = clamp(substepHz, 60, 2000) }

    /// Advance by real elapsed seconds; calls `step(dt)` for each fixed substep. Returns substep count.
    @discardableResult
    public func advance(realDelta: Double, step: (Double) -> Void) -> Int {
        guard !paused else { lastSubsteps = 0; return 0 }
        accumulator += min(max(realDelta, 0), maxFrameTime) * timeScale
        var n = 0
        let h = dt
        while accumulator >= h {
            step(h); simTime += h; accumulator -= h; n += 1
        }
        lastSubsteps = n
        return n
    }
    public func reset() { simTime = 0; accumulator = 0 }
}
