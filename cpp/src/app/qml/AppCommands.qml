import QtQuick
import QtQuick.Controls

// BUILD / FLY keyboard map and command-palette entries. Every action here is in the palette (Ctrl+K) with its
// shortcut, so the UI is fully keyboard drivable. Bare-letter shortcuts are BUILD-only; in FLY the App event filter
// owns plain keys (output bindings win, then R / P / Space / C / E).
Item {
    id: cmds
    property string tab: "BUILD"
    property var viewport: null
    signal openRequested()
    signal saveAsRequested()
    signal importRequested(bool intoCurrent)
    signal addPartRequested()
    signal focusPartName()
    readonly property bool building: tab === "BUILD"
    // craft-document shortcuts; WORLD / EVOLVE pages bind their own Ctrl+Z/S/O (two enabled Shortcuts on one
    // key are "ambiguous" in Qt and neither fires)
    readonly property bool craftTab: tab === "BUILD" || tab === "FLY"
    readonly property bool flying: tab === "FLY"
    // arrow / page nudges only while the 3D view has focus, so lists, fields and popups keep their arrow keys
    readonly property bool nudging: building && App.selectedId !== "" && viewport !== null && viewport.activeFocus

    function saveOrSaveAs() { if (App.filePath !== "") App.saveFile(""); else saveAsRequested() }
    function cycleAero() {
        const l = App.aeroModels; let i = 0
        for (let k = 0; k < l.length; ++k) if (l[k].id === App.aeroModel) i = k
        for (let s = 1; s <= l.length; ++s) { const m = l[(i + s) % l.length]; if (!m.full || App.fullAvailable) { App.aeroModel = m.id; return } }
    }

    readonly property var commands: {
        let c = [
            { name: "Undo" + (App.undoText ? " " + App.undoText : ""), shortcut: "Ctrl+Z", run: () => App.undo() },
            { name: "Redo" + (App.redoText ? " " + App.redoText : ""), shortcut: "Ctrl+Shift+Z", run: () => App.redo() },
            { name: "New craft", shortcut: "Ctrl+N", run: () => App.newCraft() },
            { name: "Open craft or CAD file…", shortcut: "Ctrl+O", run: () => cmds.openRequested() },
            { name: "Save craft", shortcut: "Ctrl+S", run: () => cmds.saveOrSaveAs() },
            { name: "Save craft as…", shortcut: "Ctrl+Shift+S", run: () => cmds.saveAsRequested() },
            { name: "Save craft to library", shortcut: "Ctrl+Shift+L", run: () => App.saveToLibrary() },
            { name: "Import CAD as new craft…", shortcut: "Ctrl+Shift+I", run: () => cmds.importRequested(false) },
            { name: "Import CAD into current craft…", shortcut: "", run: () => cmds.importRequested(true) },
            { name: "Auto-rig current craft", shortcut: "", run: () => App.autoRig() },
            { name: "Add part…", shortcut: "A", run: () => cmds.addPartRequested() },
            { name: "Duplicate part", shortcut: "Ctrl+D", run: () => App.duplicateSelected(false) },
            { name: "Mirror part L/R", shortcut: "M", run: () => App.duplicateSelected(true) },
            { name: "Delete part", shortcut: "Backspace", run: () => App.deleteSelected() },
            { name: "Rename part", shortcut: "Return", run: () => cmds.focusPartName() },
            { name: "Next part", shortcut: "Alt+Down", run: () => App.selectNext(1) },
            { name: "Previous part", shortcut: "Alt+Up", run: () => App.selectNext(-1) },
            { name: "Deselect", shortcut: "Escape", run: () => App.selectedId = "" },
            { name: "Frame craft", shortcut: "F", run: () => cmds.viewport && cmds.viewport.frameCraft() },
            { name: "View: front", shortcut: "", run: () => cmds.viewport && cmds.viewport.setView("front") },
            { name: "View: side (right)", shortcut: "", run: () => cmds.viewport && cmds.viewport.setView("right") },
            { name: "View: side (left)", shortcut: "", run: () => cmds.viewport && cmds.viewport.setView("left") },
            { name: "View: back", shortcut: "", run: () => cmds.viewport && cmds.viewport.setView("back") },
            { name: "View: top", shortcut: "", run: () => cmds.viewport && cmds.viewport.setView("top") },
            { name: "Fly: reset flight", shortcut: "R", run: () => App.resetFlight() },
            { name: "Fly: pause / resume", shortcut: "P", run: () => App.paused = !App.paused },
            { name: "Fly: cycle camera", shortcut: "C", run: () => App.cycleCamera() },
            { name: "Fly: camera chase", shortcut: "", run: () => App.cameraMode = "chase" },
            { name: "Fly: camera orbit", shortcut: "", run: () => App.cameraMode = "orbit" },
            { name: "Fly: camera cockpit", shortcut: "", run: () => App.cameraMode = "cockpit" },
            { name: "Fly: toggle live equations", shortcut: "E", run: () => App.equationsLive = !App.equationsLive },
            { name: "Aero: cycle model", shortcut: "Ctrl+Shift+M", run: () => cmds.cycleAero() },
            { name: "Aero: toggle flow slice", shortcut: "", run: () => App.setCfd("visEnabled", !App.cfd.visEnabled) }
        ]
        const l = App.aeroModels
        for (let i = 0; i < l.length; ++i) { const m = l[i]; c.push({ name: "Aero model: " + m.name, shortcut: "", run: () => App.aeroModel = m.id }) }
        const t = App.partTypes
        for (let i = 0; i < t.length; ++i) { const ty = t[i]; c.push({ name: "Add " + ty, shortcut: "", run: () => App.addPart(ty) }) }
        const lib = App.library
        for (let i = 0; i < lib.length; ++i) { const k = i; c.push({ name: "Load craft: " + lib[i].name, shortcut: "", run: () => App.loadLibraryCraft(k) }) }
        return c
    }

    // global (any tab)
    Shortcut { enabled: cmds.craftTab; sequences: [StandardKey.Undo]; onActivated: App.undo() }
    Shortcut { enabled: cmds.craftTab; sequences: [StandardKey.Redo, "Ctrl+Shift+Z"]; onActivated: App.redo() }
    Shortcut { enabled: cmds.craftTab; sequences: [StandardKey.New]; onActivated: App.newCraft() }
    Shortcut { enabled: cmds.craftTab; sequences: [StandardKey.Open]; onActivated: cmds.openRequested() }
    Shortcut { enabled: cmds.craftTab; sequences: [StandardKey.Save]; onActivated: cmds.saveOrSaveAs() }
    Shortcut { enabled: cmds.craftTab; sequence: "Ctrl+Shift+S"; onActivated: cmds.saveAsRequested() }
    Shortcut { enabled: cmds.craftTab; sequence: "Ctrl+Shift+L"; onActivated: App.saveToLibrary() }
    Shortcut { enabled: cmds.craftTab; sequence: "Ctrl+Shift+I"; onActivated: cmds.importRequested(false) }
    Shortcut { sequence: "Ctrl+Shift+M"; onActivated: cmds.cycleAero() }
    // BUILD
    Shortcut { enabled: cmds.building; sequences: ["Backspace", "Delete"]; onActivated: App.deleteSelected() }
    Shortcut { enabled: cmds.building; sequence: "Ctrl+D"; onActivated: App.duplicateSelected(false) }
    Shortcut { enabled: cmds.building; sequence: "M"; onActivated: App.duplicateSelected(true) }
    Shortcut { enabled: cmds.building; sequence: "A"; onActivated: cmds.addPartRequested() }
    Shortcut { enabled: cmds.building; sequence: "Escape"; onActivated: App.selectedId = "" }
    Shortcut { enabled: cmds.building && App.selectedId !== ""; sequences: ["Return", "Enter"]; onActivated: cmds.focusPartName() }
    Shortcut { enabled: cmds.building; sequence: "Alt+Down"; onActivated: App.selectNext(1) }
    Shortcut { enabled: cmds.building; sequence: "Alt+Up"; onActivated: App.selectNext(-1) }
    // nudge: arrows move in the horizontal plane (↑↓ = X fore/aft, ←→ = Z), PgUp/PgDn = Y; Shift ×10
    Shortcut { enabled: cmds.nudging; sequence: "Up"; onActivated: App.nudgeSelected(1, 0, 0, false) }
    Shortcut { enabled: cmds.nudging; sequence: "Down"; onActivated: App.nudgeSelected(-1, 0, 0, false) }
    Shortcut { enabled: cmds.nudging; sequence: "Left"; onActivated: App.nudgeSelected(0, 0, -1, false) }
    Shortcut { enabled: cmds.nudging; sequence: "Right"; onActivated: App.nudgeSelected(0, 0, 1, false) }
    Shortcut { enabled: cmds.nudging; sequence: "PgUp"; onActivated: App.nudgeSelected(0, 1, 0, false) }
    Shortcut { enabled: cmds.nudging; sequence: "PgDown"; onActivated: App.nudgeSelected(0, -1, 0, false) }
    Shortcut { enabled: cmds.nudging; sequence: "Shift+Up"; onActivated: App.nudgeSelected(1, 0, 0, true) }
    Shortcut { enabled: cmds.nudging; sequence: "Shift+Down"; onActivated: App.nudgeSelected(-1, 0, 0, true) }
    Shortcut { enabled: cmds.nudging; sequence: "Shift+Left"; onActivated: App.nudgeSelected(0, 0, -1, true) }
    Shortcut { enabled: cmds.nudging; sequence: "Shift+Right"; onActivated: App.nudgeSelected(0, 0, 1, true) }
    Shortcut { enabled: cmds.nudging; sequence: "Shift+PgUp"; onActivated: App.nudgeSelected(0, 1, 0, true) }
    Shortcut { enabled: cmds.nudging; sequence: "Shift+PgDown"; onActivated: App.nudgeSelected(0, -1, 0, true) }
    // rotate about Y: Q / E 15° (Shift 1°)
    Shortcut { enabled: cmds.building && App.selectedId !== ""; sequence: "Q"; onActivated: App.rotateSelected(1, 15) }
    Shortcut { enabled: cmds.building && App.selectedId !== ""; sequence: "E"; onActivated: App.rotateSelected(1, -15) }
    Shortcut { enabled: cmds.building && App.selectedId !== ""; sequence: "Shift+Q"; onActivated: App.rotateSelected(1, 1) }
    Shortcut { enabled: cmds.building && App.selectedId !== ""; sequence: "Shift+E"; onActivated: App.rotateSelected(1, -1) }
}
