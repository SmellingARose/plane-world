// Germ War — native macOS (Metal + all-core simulation + live JS mods).
//   GermWar                 play
//   GermWar --bench [N]     headless: simulate N germs vs a base, compare 1 thread vs all cores
//   GermWar --quit-after S  launch, then quit (smoke test)
import AppKit
import MetalKit
import SwiftUI
import PWCore
import PWRender

final class GameView: MTKView {
    weak var game: Game?
    private var downAt: CGPoint?, dragged = false, rightDown: CGPoint?, rightDragged = false
    override var acceptsFirstResponder: Bool { true }
    private func top(_ e: NSEvent) -> CGPoint { let p = convert(e.locationInWindow, from: nil); return CGPoint(x: p.x, y: bounds.height - p.y) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with e: NSEvent) { game?.mouseMoved(top(e)) }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); downAt = top(e); dragged = false }
    override func mouseDragged(with e: NSEvent) {
        guard let g = game, let a = downAt else { return }
        let p = top(e)
        if !dragged && hypot(p.x - a.x, p.y - a.y) > 5 { dragged = true }
        guard dragged else { return }
        if g.buildType != nil || g.placeType != nil { orbit(e) } else { g.boxRect = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y)) }
        g.mouseMoved(p)
    }
    override func mouseUp(with e: NSEvent) {
        guard let g = game else { return }
        let shift = e.modifierFlags.contains(.shift)
        if !dragged { g.click(top(e), right: false, shift: shift) }
        else if let r = g.boxRect { g.boxSelect(r, shift: shift) }
        g.boxRect = nil; downAt = nil
    }
    override func rightMouseDown(with e: NSEvent) { rightDown = top(e); rightDragged = false }
    override func rightMouseDragged(with e: NSEvent) { rightDragged = true; orbit(e) }
    override func rightMouseUp(with e: NSEvent) { if !rightDragged { game?.click(top(e), right: true, shift: e.modifierFlags.contains(.shift)) } }
    override func otherMouseDragged(with e: NSEvent) { orbit(e) }
    private func orbit(_ e: NSEvent) {
        guard let g = game else { return }
        g.yaw += Float(e.deltaX) * 0.005; g.pitch = min(1.45, max(0.18, g.pitch + Float(e.deltaY) * 0.005))
    }
    override func scrollWheel(with e: NSEvent) {
        guard let g = game else { return }
        let d = Float(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 1 : 10)
        g.dist = min(2600, max(120, g.dist * (1 - d * 0.002)))
    }
    override func magnify(with e: NSEvent) { game.map { $0.dist = min(2600, max(120, $0.dist * Float(1 - e.magnification))) } }
    override func keyDown(with e: NSEvent) { if !e.isARepeat || e.keyCode < 20 { game?.key(e.keyCode, chars: e.charactersIgnoringModifiers ?? "", down: true) } }
    override func keyUp(with e: NSEvent) { game?.key(e.keyCode, chars: e.charactersIgnoringModifiers ?? "", down: false) }
}

final class GameController: NSViewController, MTKViewDelegate {
    var game: Game!
    private var renderer: Renderer!
    private var last = CACurrentMediaTime()
    override func loadView() {
        guard let gpu = GPU.shared else { fatalError("Metal is not available") }
        let v = GameView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000), device: gpu.device)
        v.colorPixelFormat = .bgra8Unorm_srgb; v.depthStencilPixelFormat = .invalid; v.framebufferOnly = true
        v.preferredFramesPerSecond = 120; v.delegate = self
        renderer = try! Renderer(device: gpu.device, queue: gpu.queue, outputFormat: v.colorPixelFormat)
        renderer.environment.timeOfDayHours = 16.8
        renderer.environment.sunAzimuthDeg = 200
        renderer.environment.fogDensity = 0.8
        renderer.settings.exposure = 0.5
        renderer.settings.bloomStrength = 0.03
        renderer.settings.shadowDistance = 2400
        game = Game(device: gpu.device)
        v.game = game
        let overlay = NSHostingView(rootView: GameOverlay(game: game))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(overlay)
        NSLayoutConstraint.activate([overlay.leadingAnchor.constraint(equalTo: v.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                                     overlay.topAnchor.constraint(equalTo: v.topAnchor), overlay.bottomAnchor.constraint(equalTo: v.bottomAnchor)])
        view = v
    }
    override func viewDidAppear() { view.window?.makeFirstResponder(view); view.window?.acceptsMouseMovedEvents = true }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        let now = CACurrentMediaTime(), dt = min(0.1, now - last); last = now
        game.viewSize = view.bounds.size
        game.tick(dt)
        guard let d = view.currentDrawable else { return }
        renderer.render(to: d.texture, camera: game.camera, time: Double(game.sim.time)) { cb in cb.present(d) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var quitAfter: Double?
    func applicationDidFinishLaunching(_ n: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Germ War"
        w.contentViewController = GameController()
        w.setContentSize(NSSize(width: 1600, height: 1000)); w.center(); w.makeKeyAndOrderFront(nil)
        window = w
        let main = NSMenu(), item = NSMenuItem(); main.addItem(item)
        let m = NSMenu(); m.addItem(withTitle: "Quit Germ War", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = m
        NSApp.mainMenu = main
        NSApp.activate(ignoringOtherApps: true)
        if let q = quitAfter { DispatchQueue.main.asyncAfter(deadline: .now() + q) { NSApp.terminate(nil) } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

func bench(_ n: Int) {
    guard let gpu = GPU.shared else { print("no Metal"); return }
    let g = Game(headless: gpu.device)
    for (t, x, z) in [("turret", 80, 0), ("turret", -80, 0), ("tesla", 0, 90), ("laser", 0, -90), ("turret", 60, 60)] as [(String, Float, Float)] { g.sim.spawn(t, Vec2(x, z)) }
    g.sim.god = true
    g.stressTest(n)
    func run(_ label: String) -> Double {
        var total = 0.0
        for _ in 0..<240 { g.sim.step(1.0 / 60); total += g.sim.lastStepMs }
        let ms = total / 240
        print(String(format: "%@: %.2f ms/step  (%d alive)", label, ms, g.sim.aliveCount)); return ms
    }
    g.sim.forceSerial = true; let s = run("1 thread  ")
    g.sim.forceSerial = false; let p = run("\(g.sim.threads) threads")
    print(String(format: "speedup %.1f×", s / p))
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--bench") {
    bench(i + 1 < args.count ? Int(args[i + 1]) ?? 20000 : 20000); exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
if let i = args.firstIndex(of: "--quit-after"), i + 1 < args.count { delegate.quitAfter = Double(args[i + 1]) }
app.delegate = delegate
app.run()
