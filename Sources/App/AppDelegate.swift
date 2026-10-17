import AppKit
import SwiftUI
import PWCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var controller: MainViewController?
    var quitAfter: Double?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vc = MainViewController()
        controller = vc
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 960),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Plane World"
        w.contentViewController = vc
        w.setContentSize(NSSize(width: 1600, height: 960))
        w.center()
        w.makeKeyAndOrderFront(nil)
        w.toolbar = vc.makeToolbar()
        w.toolbarStyle = .unified
        window = w
        print("[App] windowNumber \(w.windowNumber)"); fflush(stdout)
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--tab"), i + 1 < args.count, let t = AppTab.allCases.first(where: { $0.rawValue.lowercased() == args[i + 1].lowercased() }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { vc.selectTab(t) }
        }
        if let i = args.firstIndex(of: "--aero"), i + 1 < args.count, let m = AeroModel(rawValue: args[i + 1].lowercased()) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated {
                var a = vc.model.aero
                if let j = args.firstIndex(of: "--cfd-preset"), j + 1 < args.count, let p = CFDQualityPreset(rawValue: args[j + 1]) { a.cfd = .preset(p) }
                if args.contains("--flow-viz") { a.cfd.visualization.enabled = true; a.cfd.visualization.particles = true; a.cfd.visualization.sliceAxis = 1 }
                a.model = m
                vc.model.aero = a
            } }
        }
        if let i = args.firstIndex(of: "--air-start"), i + 1 < args.count, let v = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { MainActor.assumeIsolated { vc.model.airStart(speed: v) } }
        }
        if let i = args.firstIndex(of: "--select-part"), i + 1 < args.count {
            let id = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { MainActor.assumeIsolated { vc.model.selectedPartID = id } }
        }
        if args.contains("--show-equations") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { MainActor.assumeIsolated { vc.model.showEquations = true; vc.model.equationsScrollRequest += 1 } }
        }
        if let q = quitAfter { DispatchQueue.main.asyncAfter(deadline: .now() + q) { NSApp.terminate(nil) } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Plane World", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Craft…", action: #selector(MainViewController.openCraft(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Save Craft…", action: #selector(MainViewController.saveCraft(_:)), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Import CAD…", action: #selector(MainViewController.importCAD(_:)), keyEquivalent: "i")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Open World…", action: #selector(MainViewController.openWorld(_:)), keyEquivalent: "O")
        fileMenu.addItem(withTitle: "Save World…", action: #selector(MainViewController.saveWorld(_:)), keyEquivalent: "S")
        fileItem.submenu = fileMenu
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        for (i, t) in AppTab.allCases.enumerated() {
            let it = viewMenu.addItem(withTitle: t.rawValue.capitalized, action: #selector(MainViewController.selectTabMenu(_:)), keyEquivalent: "\(i + 1)")
            it.tag = i
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Toggle Aero Model (Fast / Full CFD)", action: #selector(MainViewController.toggleAeroModel(_:)), keyEquivalent: "m").keyEquivalentModifierMask = [.command, .shift]
        viewItem.submenu = viewMenu
        NSApp.mainMenu = main
    }
}
