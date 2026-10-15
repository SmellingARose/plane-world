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
        NSApp.mainMenu = main
    }
}
