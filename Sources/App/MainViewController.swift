// AppKit window content: SwiftUI side panel (per tab) + MetalKit viewport. Owned by architect, then integrator.
import AppKit
import MetalKit
import SwiftUI
import UniformTypeIdentifiers
import PWCore
import PWRender
import PWTerrain
import PWCraft

final class MainViewController: NSViewController, NSToolbarDelegate, MTKViewDelegate {
    let model = MainActor.assumeIsolated { AppModel() }
    private var mtkView: ViewportView!
    private var renderer: Renderer?
    private var lastTime = CACurrentMediaTime()
    private var tabControl: NSSegmentedControl!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 960))
        guard let gpu = GPU.shared else { fatalError("Metal is not available") }
        let v = ViewportView(frame: .zero, device: gpu.device)
        v.colorPixelFormat = .bgra8Unorm_srgb
        v.depthStencilPixelFormat = .invalid
        v.framebufferOnly = true
        v.preferredFramesPerSecond = 120
        v.delegate = self
        v.model = model
        mtkView = v
        do {
            let r = try Renderer(device: gpu.device, queue: gpu.queue, outputFormat: v.colorPixelFormat)
            renderer = r
            MainActor.assumeIsolated { model.attachRenderer(r) }
        } catch { print("[Render] init failed: \(error)") }

        let panel = NSHostingView(rootView: SidePanel().environmentObject(model))
        let hud = NSHostingView(rootView: HUDOverlay().environmentObject(model))
        let bar = NSHostingView(rootView: StatusBar().environmentObject(model))
        for x in [panel, v, hud, bar] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(x) }
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panel.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: 340),
            v.leadingAnchor.constraint(equalTo: panel.trailingAnchor),
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            v.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            v.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: panel.trailingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 24),
            hud.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            hud.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
        ])
        view = root
    }

    // MARK: toolbar with BUILD / FLY / WORLD

    func makeToolbar() -> NSToolbar {
        let t = NSToolbar(identifier: "main")
        t.delegate = self; t.displayMode = .iconOnly
        return t
    }
    private let tabsID = NSToolbarItem.Identifier("tabs")
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, tabsID, .flexibleSpace] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, tabsID] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == tabsID else { return nil }
        let seg = NSSegmentedControl(labels: AppTab.allCases.map(\.rawValue), trackingMode: .selectOne, target: self, action: #selector(tabChanged(_:)))
        seg.selectedSegment = 0
        seg.segmentStyle = .automatic
        for i in 0..<AppTab.allCases.count { seg.setWidth(110, forSegment: i) }
        tabControl = seg
        let item = NSToolbarItem(itemIdentifier: id); item.view = seg; item.label = "Mode"
        return item
    }
    @objc func tabChanged(_ s: NSSegmentedControl) {
        let tab = AppTab.allCases[s.selectedSegment]
        MainActor.assumeIsolated { model.tab = tab }
        view.window?.makeFirstResponder(mtkView)
    }

    // MARK: file actions

    @objc func openCraft(_ sender: Any?) { MainActor.assumeIsolated { FileDialogs.openCraftJSON(model) } }
    @objc func saveCraft(_ sender: Any?) { MainActor.assumeIsolated { FileDialogs.saveCraftJSON(model) } }
    @objc func openWorld(_ sender: Any?) { MainActor.assumeIsolated { FileDialogs.openWorld(model) } }
    @objc func saveWorld(_ sender: Any?) { MainActor.assumeIsolated { FileDialogs.saveWorld(model) } }
    @objc func importCAD(_ sender: Any?) { MainActor.assumeIsolated { FileDialogs.importCAD(model, into: false) } }
    @objc func selectTabMenu(_ sender: NSMenuItem) { selectTab(AppTab.allCases[max(0, min(AppTab.allCases.count - 1, sender.tag))]) }
    @objc func toggleAeroModel(_ sender: Any?) {
        MainActor.assumeIsolated { model.aero.model = model.aero.model == .fast ? .full : .fast }
    }
    func selectTab(_ t: AppTab) {
        MainActor.assumeIsolated { model.tab = t }
        tabControl?.selectedSegment = AppTab.allCases.firstIndex(of: t) ?? 0
    }

    // MARK: MTKViewDelegate — the main loop

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTime, 0.1); lastTime = now
        MainActor.assumeIsolated {
            model.tick(dt: dt)
            mtkView.applyKeyboard(dt: dt)
        }
        // While EVOLVE trains (and nothing is being replayed), render at ~4 Hz so the cores go to training.
        let idle = MainActor.assumeIsolated { model.tab == .evolve && model.evolve.isRunning && model.evolve.replay == nil }
        if RenderThrottle.shared.idle != idle { RenderThrottle.shared.idle = idle }
        guard RenderThrottle.shared.shouldRender() else { return }
        guard let renderer, let drawable = view.currentDrawable else { return }
        let cam = MainActor.assumeIsolated { model.camera.camera }
        let t = MainActor.assumeIsolated { model.services.clock.simTime }
        renderer.render(to: drawable.texture, camera: cam, time: t, present: { $0.present(drawable) })
    }
}

/// MTKView input. Navigate: left drag orbit · right/option drag pan · scroll/pinch zoom · WASD/QE move target.
/// BUILD: click selects a part, shift-drag moves it, cmd-drag rotates it. WORLD: with a tool, left click/drag applies it
/// (right drag orbits). FLY: R reset, P pause, C cycle camera, E toggle live equations.
final class ViewportView: MTKView {
    weak var model: AppModel?
    private var keys = Set<UInt16>()
    private var lastDragTime = CACurrentMediaTime()
    override var acceptsFirstResponder: Bool { true }

    private func ray(_ e: NSEvent) -> Ray? {
        guard let model else { return nil }
        let p = convert(e.locationInWindow, from: nil)
        let nx = Double(p.x / max(1, bounds.width)), ny = Double(1 - p.y / max(1, bounds.height))
        return MainActor.assumeIsolated { model.camera.ray(nx: nx, ny: ny, aspect: Double(bounds.width / max(1, bounds.height))) }
    }
    private var toolActive: Bool { MainActor.assumeIsolated { model?.tab == .world && model?.worldTool != WorldTool.none } }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model, let r = ray(e) else { return }
        MainActor.assumeIsolated {
            model.camera.userDragging = true
            if model.tab == .build, !e.modifierFlags.contains(.shift), !e.modifierFlags.contains(.command) {
                if let id = model.pickPart(ray: r) { model.selectedPartID = id }
            } else if model.tab == .world, model.worldTool != .none, let hit = model.terrain.raycast(r, maxDistance: 1e5) {
                model.flattenTarget = hit.position.y
                model.applyTool(at: hit.position, dt: 1.0 / 30, click: true)
                lastDragTime = CACurrentMediaTime()
            }
        }
    }
    override func mouseUp(with e: NSEvent) { MainActor.assumeIsolated { model?.camera.userDragging = false; model?.flattenTarget = nil } }
    override func mouseDragged(with e: NSEvent) {
        guard let model else { return }
        MainActor.assumeIsolated {
            if model.tab == .build, model.selectedPartID != nil, e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.command) {
                model.dragSelected(dx: e.deltaX, dy: e.deltaY, rotate: e.modifierFlags.contains(.command))
            } else if toolActive {
                let now = CACurrentMediaTime(); let dt = min(0.1, now - lastDragTime); lastDragTime = now
                let continuous: Set<WorldTool> = [.raise, .lower, .smooth, .flatten, .paint]
                if continuous.contains(model.worldTool), let r = ray(e), let hit = model.terrain.raycast(r, maxDistance: 1e5) {
                    model.applyTool(at: hit.position, dt: dt, click: false)
                }
            } else if e.modifierFlags.contains(.option) { model.camera.pan(dx: e.deltaX, dy: e.deltaY) }
            else { model.camera.orbit(dx: e.deltaX, dy: e.deltaY) }
        }
    }
    override func rightMouseDragged(with e: NSEvent) {
        MainActor.assumeIsolated {
            if toolActive && !e.modifierFlags.contains(.option) { model?.camera.orbit(dx: e.deltaX, dy: e.deltaY) }
            else { model?.camera.pan(dx: e.deltaX, dy: e.deltaY) }
        }
    }
    override func otherMouseDragged(with e: NSEvent) { MainActor.assumeIsolated { model?.camera.pan(dx: e.deltaX, dy: e.deltaY) } }
    override func scrollWheel(with e: NSEvent) { MainActor.assumeIsolated { model?.camera.zoom(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 10)) } }
    override func magnify(with e: NSEvent) { MainActor.assumeIsolated { model?.camera.zoom(e.magnification * 300) } }
    override func keyDown(with e: NSEvent) {
        guard let model else { return }
        MainActor.assumeIsolated {
            // Keys bound to one of this craft's outputs drive that output; app shortcuts only use unbound keys.
            if model.tab == .fly, !e.isARepeat, !model.isOutputKey(e.keyCode) {
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "r": model.resetFlight(); return
                case "p": model.paused.toggle(); return
                case "e": model.showEquations.toggle(); if model.showEquations { model.equationsScrollRequest += 1 }; return
                case "c": let all = CameraMode.allCases; model.cameraMode = all[((all.firstIndex(of: model.cameraMode) ?? 0) + 1) % all.count]; return
                default: break
                }
            }
            if model.tab == .build, e.keyCode == 51 || e.keyCode == 117 { model.deleteSelected(); return }   // ⌫ / ⌦
        }
        keys.insert(e.keyCode)
    }
    override func keyUp(with e: NSEvent) { keys.remove(e.keyCode) }
    @MainActor func applyKeyboard(dt: Double) {
        guard let model else { return }
        if model.tab == .fly { model.applyOutputKeybinds(held: keys, dt: dt); return }   // output keybinds (spring needs ticks with no key held)
        guard !keys.isEmpty else { return }
        let c = model.camera.camera
        var fwd = c.forward; fwd.y = 0; fwd = fwd.normalizedSafe
        var move = Vec3d.zero
        if keys.contains(13) { move += fwd }      // W
        if keys.contains(1) { move -= fwd }       // S
        if keys.contains(0) { move -= c.right }   // A
        if keys.contains(2) { move += c.right }   // D
        if keys.contains(12) { move.y -= 1 }      // Q
        if keys.contains(14) { move.y += 1 }      // E
        model.camera.target += move * dt * max(5, model.camera.distance)
    }
}
