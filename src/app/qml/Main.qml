import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

ApplicationWindow {
    id: win
    width: 1280
    height: 800
    minimumWidth: 760
    minimumHeight: 480
    visible: true
    title: "Plane World"
    color: Theme.window

    readonly property var tabs: ["BUILD", "FLY", "WORLD", "EVOLVE"]
    property int currentTab: Math.max(0, tabs.indexOf((pwInitialTab || "").toUpperCase()))
    property bool inspectorVisible: true
    // read by main.cpp for the CI smoke test
    property string viewportError: activeViewport.error
    property string viewportBackend: activeViewport.backendName

    readonly property var sectionsByTab: ({
        "BUILD": [ { title: "Craft", rows: [["New craft", "Ctrl+N"], ["Open craft…", "Ctrl+O"], ["Save", "Ctrl+S"]] },
                   { title: "Edit", rows: [["Undo", "Ctrl+Z"], ["Redo", "Ctrl+Shift+Z"], ["Add part", "A"], ["Delete part", "Backspace"]] },
                   { title: "Parts", rows: [["Wings, props, jets, rockets, wheels, servos, CAD bodies", ""]] } ],
        "FLY":   [ { title: "Flight", rows: [["Launch / reset", "R"], ["Pause", "Space"], ["Camera", "C"]] },
                   { title: "World", rows: [["Flies in the WORLD tab's world", ""], ["Edit world", "Ctrl+3"]] },
                   { title: "Aero model", rows: [["Fast · classic", ""], ["Fast · slipstream", ""], ["Fast+ (all effects)", ""]] },
                   { title: "Outputs", rows: [["Per-output sliders and key bindings", ""]] } ],
        "WORLD": [ { title: "Terrain", rows: [["Heightfield, water, vegetation", ""], ["Undo", "Ctrl+Z"]] },
                   { title: "Use it", rows: [["Fly here", "Ctrl+Shift+2"]] },
                   { title: "Objects", rows: [["Place prop", "P"], ["Breakables and buildings", ""]] } ],
        "EVOLVE":[ { title: "Experiment", rows: [["New experiment", "Ctrl+E"], ["Start / stop training", "Ctrl+Return"]] },
                   { title: "Algorithms", rows: [["GA · NEAT · CMA-ES · MAP-Elites · novelty", ""]] },
                   { title: "Runtime", rows: [["JavaScriptCore scripts (QuickJS fallback)", ""]] } ]
    })

    function selectTab(i) { currentTab = i }
    // main.cpp --command "<palette entry>": run a command-palette entry by exact name (screenshots, scripted demos)
    function runCommand(name) { for (const c of commands) if (c.name === name) { c.run(); return true } return false }
    readonly property var undoTarget: currentTab <= 1 ? App : currentTab === 2 ? WorldModel : null

    readonly property var commands: baseCommands.concat(appCommands.commands)
    readonly property var baseCommands: [
        { name: "Go to BUILD", shortcut: "Ctrl+1", run: () => selectTab(0) },
        { name: "Go to FLY", shortcut: "Ctrl+2", run: () => selectTab(1) },
        { name: "Go to WORLD", shortcut: "Ctrl+3", run: () => selectTab(2) },
        { name: "Go to EVOLVE", shortcut: "Ctrl+4", run: () => selectTab(3) },
        { name: "Toggle inspector", shortcut: "Ctrl+I", run: () => inspectorVisible = !inspectorVisible },
        { name: "Toggle full screen", shortcut: "Ctrl+Shift+F", run: () => win.visibility = (win.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen) },
        { name: "About Plane World", shortcut: "", run: () => about.open() },
        { name: "Settings…", shortcut: "Ctrl+,", run: () => settingsDlg.open() },
        { name: "Show the welcome tour", shortcut: "", run: () => tour.start() },
        { name: "WORLD: generate terrain", shortcut: "Ctrl+G", run: () => { selectTab(2); WorldModel.generate() } },
        { name: "WORLD: save world", shortcut: "", run: () => WorldFlow.save() },
        { name: "WORLD: saved worlds (open / delete)", shortcut: "", run: () => WorldFlow.manage() },
        { name: "WORLD: fly here (start a flight at the view centre)", shortcut: "Ctrl+Shift+2", run: () => { selectTab(2); if (worldLoader.item) worldLoader.item.flyHere() } },
        { name: "FLY: fly in the WORLD tab's world", shortcut: "", run: () => { App.flyInWorld = true; selectTab(1) } },
        { name: "FLY: fly over flat ground", shortcut: "", run: () => { App.flyInWorld = false; selectTab(1) } },
        { name: "WORLD: new Manhattan (Midtown) world", shortcut: "", run: () => { selectTab(2); WorldFlow.newWorld("manhattan") } },
        { name: "WORLD: new mountains world", shortcut: "", run: () => { selectTab(2); WorldFlow.newWorld("mountains") } },
        { name: "EVOLVE: start / pause training", shortcut: "Ctrl+Return", run: () => { selectTab(3); if (evolveLoader.item) evolveLoader.item.train() } },
        { name: "EVOLVE: quick start (learns to hold altitude in ~10 s)", shortcut: "", run: () => { selectTab(3); EvolveModel.quickStart() } },
        { name: "EVOLVE: check script", shortcut: "", run: () => { selectTab(3); EvolveModel.checkScript() } },
        { name: "EVOLVE: fly best with the evolved autopilot", shortcut: "", run: () => EvolveModel.flyWithAutopilot() },
        { name: "FLY: toggle evolved autopilot", shortcut: "O", run: () => { App.autopilot = !App.autopilot } },
        { name: "EVOLVE: show controller wiring", shortcut: "", run: () => { selectTab(3); if (evolveLoader.item) evolveLoader.item.showWiring() } },
        { name: "EVOLVE: replay best", shortcut: "", run: () => { selectTab(3); EvolveModel.replay("best") } },
        { name: "Quit", shortcut: "Ctrl+Q", run: () => Qt.quit() }
    ]

    Shortcut { sequence: "Ctrl+1"; onActivated: selectTab(0) }
    Shortcut { sequence: "Ctrl+2"; onActivated: selectTab(1) }
    Shortcut { sequence: "Ctrl+3"; onActivated: selectTab(2) }
    Shortcut { sequence: "Ctrl+4"; onActivated: selectTab(3) }
    Shortcut { sequence: "Ctrl+K"; onActivated: cmdPalette.opened ? cmdPalette.close() : cmdPalette.open() }
    Shortcut { sequence: "Ctrl+I"; onActivated: inspectorVisible = !inspectorVisible }
    Shortcut { sequence: "Ctrl+Shift+F"; onActivated: commands[5].run() }
    Shortcut { sequences: [StandardKey.Quit]; onActivated: Qt.quit() }

    header: ToolBar {
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.s3
            anchors.rightMargin: Theme.s3
            spacing: Theme.s4
            Label { text: "Plane World"; font.weight: Font.DemiBold; font.pixelSize: Theme.title }
            PwTabBar {
                id: bar
                Layout.fillHeight: true
                model: win.tabs
                tints: Theme.tabTint
                readonly property var blurbs: ["Design the craft (FLY and EVOLVE use it)", "Fly the craft in the WORLD tab's world",
                                               "Shape the world FLY and EVOLVE use", "Evolve a controller or design, then fly it"]
                tips: win.tabs.map((t, i) => t + " — " + blurbs[i] + "   " + Theme.shortcutText("Ctrl+" + (i + 1)))
                currentIndex: win.currentTab
                onCurrentIndexChanged: win.currentTab = currentIndex
            }
            Item { Layout.fillWidth: true }
            // undo / redo act on the document of the visible tab (craft in BUILD/FLY, world in WORLD)
            PwIconButton { text: "↩\uFE0E"; font.pixelSize: Theme.title; enabled: win.undoTarget ? win.undoTarget.canUndo : false
                tip: enabled ? "Undo " + win.undoTarget.undoText : "Nothing to undo"; shortcut: "Ctrl+Z"; onClicked: win.undoTarget.undo() }
            PwIconButton { text: "↪\uFE0E"; font.pixelSize: Theme.title; enabled: win.undoTarget ? win.undoTarget.canRedo : false
                tip: enabled ? "Redo " + (win.undoTarget.redoText || "") : "Nothing to redo"; shortcut: "Ctrl+Shift+Z"; onClicked: win.undoTarget.redo() }
            ToolButton {
                text: "Commands  " + Theme.shortcutText("Ctrl+K")
                onClicked: cmdPalette.open()
                ToolTip.visible: hovered; ToolTip.delay: 600; ToolTip.text: "Search every action"
            }
            ToolButton {
                text: inspectorVisible ? "Hide inspector" : "Show inspector"
                onClicked: inspectorVisible = !inspectorVisible
                ToolTip.visible: hovered; ToolTip.delay: 600; ToolTip.text: Theme.shortcutText("Ctrl+I")
            }
        }
    }

    // Tab identity strip: animates under the toolbar when switching tabs.
    Rectangle {
        id: strip
        z: 2
        width: parent.width; height: 2
        color: Theme.tabTint[win.tabs[win.currentTab]]
        Behavior on color { ColorAnimation { duration: Theme.normal } }
    }

    TabPage {
        id: work
        anchors.fill: parent
        visible: win.currentTab < 2
        tab: win.tabs[win.currentTab]
        sections: win.sectionsByTab[tab]
        inspectorVisible: win.inspectorVisible
    }
    // P5b: WORLD and EVOLVE pages (own world viewport; created on first visit, kept afterwards)
    Loader {
        id: worldLoader
        anchors.fill: parent
        active: win.currentTab === 2 || item !== null
        visible: win.currentTab === 2
        sourceComponent: WorldPage { inspectorVisible: win.inspectorVisible }
    }
    Loader {
        id: evolveLoader
        anchors.fill: parent
        active: win.currentTab === 3 || item !== null
        visible: win.currentTab === 3
        sourceComponent: EvolvePage {
            inspectorVisible: win.inspectorVisible
            onFlyRequested: (path) => { App.openFile(path); win.selectTab(1); App.autopilot = true }
        }
    }
    readonly property var activeViewport: win.currentTab === 2 && worldLoader.item ? worldLoader.item.viewport
                                        : win.currentTab === 3 && evolveLoader.item ? evolveLoader.item.viewport : work.viewport
    AppTour { id: tour; parent: Overlay.overlay }
    AppSettings { id: settingsDlg; parent: Overlay.overlay; onTourRequested: tour.start() }
    Shortcut { sequences: [StandardKey.Preferences, "Ctrl+,"]; onActivated: settingsDlg.open() }

    footer: StatusBar { tab: win.tabs[win.currentTab]; viewport: work.viewport }

    AppCommands {
        id: appCommands
        tab: win.tabs[win.currentTab]
        viewport: work.viewport
        onOpenRequested: openDialog.open()
        onSaveAsRequested: saveDialog.open()
        onImportRequested: (into) => { cadDialog.intoCurrent = into; cadDialog.open() }
        onAddPartRequested: cmdPalette.openWith("add ")
        onShowEquationsRequested: if (work.inspector.panel && work.inspector.panel.equationsItem) work.inspector.scrollTo(work.inspector.panel.equationsItem)
        onFocusPartName: if (work.inspector.panel && work.inspector.panel.focusPartName) work.inspector.panel.focusPartName()
    }
    Connections {
        target: work.inspector.panel
        ignoreUnknownSignals: true
        function onOpenRequested() { openDialog.open() }
        function onSaveAsRequested() { saveDialog.open() }
        function onImportRequested(into) { cadDialog.intoCurrent = into; cadDialog.open() }
    }

    FileDialog {
        id: openDialog
        title: "Open craft or CAD file"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Crafts and CAD (*.json " + App.cadExtensions.map(e => "*." + e).join(" ") + ")", "Craft JSON (*.json)", "All files (*)"]
        onAccepted: { App.openFile(selectedFile); win.currentTab = 0 }
    }
    FileDialog {
        id: saveDialog
        title: "Save craft"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "json"
        nameFilters: ["Craft JSON (*.json)"]
        onAccepted: App.saveFile(selectedFile)
    }
    FileDialog {
        id: cadDialog
        property bool intoCurrent: false
        title: intoCurrent ? "Add CAD parts to " + App.craftName : "Import CAD as a new craft"
        fileMode: FileDialog.OpenFiles
        nameFilters: ["CAD (" + App.cadExtensions.map(e => "*." + e).join(" ") + ")", "All files (*)"]
        onAccepted: { App.importFiles(selectedFiles, intoCurrent); win.currentTab = 0 }
    }

    CadDropOverlay {
        parent: Overlay.overlay
        anchors.fill: parent
        onFileDropped: win.currentTab = 0
    }
    PwToast { id: toast; parent: Overlay.overlay }
    WorldDialogs { parent: Overlay.overlay }
    Connections { target: App; function onNotify(text, kind) { toast.show(text, kind) }
                               function onTabRequested(t) { const i = win.tabs.indexOf(t); if (i >= 0) win.selectTab(i) } }

    // Unsaved edits: ask before quitting (the craft first, then the world).
    property bool closeConfirmed: false
    property bool worldCloseConfirmed: false
    onClosing: (close) => {
        if (App.dirty && !closeConfirmed) { close.accepted = false; unsaved.open() }
        else if (WorldModel.dirty && !worldCloseConfirmed) {
            close.accepted = false
            WorldFlow.whenSaved(() => { win.worldCloseConfirmed = true; win.close() })
        }
    }
    Dialog {
        id: unsaved
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        title: "Save changes to \u201c" + App.craftName + "\u201d?"
        standardButtons: Dialog.Save | Dialog.Discard | Dialog.Cancel
        Label { text: "Your edits will be lost if you don't save them."; wrapMode: Text.WordWrap }
        onAccepted: { if (App.filePath !== "" ? App.saveFile("") : (App.saveToLibrary(), true)) { win.closeConfirmed = true; win.close() } }
        onDiscarded: { win.closeConfirmed = true; win.close() }
    }

    CommandPalette { id: cmdPalette; parent: Overlay.overlay; commands: win.commands }

    Dialog {
        id: about
        parent: Overlay.overlay
        anchors.centerIn: parent
        title: "Plane World"
        standardButtons: Dialog.Ok
        modal: true
        width: Math.min(460, win.width - Theme.s6 * 2)
        Label {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "C++ / Qt 6 port, version " + pwVersion + "\n" + pwCpu + "\nRenderer: " + (work.viewport.backendName || "?") + " — " + work.viewport.adapterName }
    }
}
