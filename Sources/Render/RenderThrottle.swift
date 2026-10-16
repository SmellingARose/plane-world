// Render-on-demand gate. While `idle` is true (e.g. EVOLVE training running headless), the view should skip
// frames unless something requested one, so CPU/GPU go to training. Integrator wiring (App, not owned here):
//   in MTKView draw(in:):  guard RenderThrottle.shared.shouldRender() else { return }
//   or set mtkView.isPaused = throttle.idle; mtkView.enableSetNeedsDisplay = throttle.idle and call setNeedsDisplay
//   from requestFrame callbacks.
import Foundation

public final class RenderThrottle: @unchecked Sendable {
    public static let shared = RenderThrottle()
    private let lock = NSLock()
    private var _idle = false
    private var pending = 1
    private var lastFrame = 0.0
    /// When idle, still render at most this often (Hz) so UI overlays/charts stay alive. 0 = only on request.
    public var idleRefreshHz: Double = 4
    /// Called when a frame is requested while idle (hook for MTKView.setNeedsDisplay).
    public var onRequest: (@Sendable () -> Void)?

    public var idle: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _idle }
        set { lock.lock(); _idle = newValue; pending = 1; lock.unlock() }
    }
    public func requestFrame(count: Int = 1) {
        lock.lock(); pending = max(pending, count); let cb = _idle ? onRequest : nil; lock.unlock()
        cb?()
    }
    /// True when a frame should be rendered now. Always true when not idle.
    public func shouldRender(now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !_idle { lastFrame = now; return true }
        if pending > 0 { pending -= 1; lastFrame = now; return true }
        if idleRefreshHz > 0, now - lastFrame >= 1 / idleRefreshHz { lastFrame = now; return true }
        return false
    }
}
