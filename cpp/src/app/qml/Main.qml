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
    property string viewportError: work.viewport.error
    property string viewportBackend: work.viewport.backendName

    readonly property var sectionsByTab: ({
        "BUILD": [ { title: "Craft", rows: [["New craft", "Ctrl+N"], ["Open craft…", "Ctrl+O"], ["Save", "Ctrl+S"]] },
                   { title: "Edit", rows: [["Undo", "Ctrl+Z"], ["Redo", "Ctrl+Shift+Z"], ["Add part", "A"], ["Delete part", "Backspace"]] },
                   { title: "Parts", rows: [["Wings, props, jets, rockets, wheels, servos, CAD bodies", ""]] } ],
        "FLY":   [ { title: "Flight", rows: [["Launch / reset", "R"], ["Pause", "Space"], ["Camera", "C"]] },
                   { title: "Aero model", rows: [["Fast · classic", ""], ["Fast · slipstream", ""], ["Fast+ (all effects)", ""], ["Full CFD presets", ""]] },
                   { title: "Outputs", rows: [["Per-output sliders and key bindings", ""]] } ],
        "WORLD": [ { title: "Terrain", rows: [["Heightfield, water, vegetation", ""], ["Undo", "Ctrl+Z"]] },
                   { title: "Objects", rows: [["Place prop", "P"], ["Breakables and buildings", ""]] } ],
        "EVOLVE":[ { title: "Experiment", rows: [["New experiment", "Ctrl+E"], ["Start / stop training", "Ctrl+Return"]] },
                   { title: "Algorithms", rows: [["GA · NEAT · CMA-ES · MAP-Elites · novelty", ""]] },
                   { title: "Runtime", rows: [["JavaScriptCore scripts (QuickJS fallback)", ""]] } ]
    })

    function selectTab(i) { currentTab = i }

    readonly property var commands: baseCommands.concat(appCommands.commands)
    readonly property var baseCommands: [
        { name: "Go to BUILD", shortcut: "Ctrl+1", run: () => selectTab(0) },
        { name: "Go to FLY", shortcut: "Ctrl+2", run: () => selectTab(1) },
        { name: "Go to WORLD", shortcut: "Ctrl+3", run: () => selectTab(2) },
        { name: "Go to EVOLVE", shortcut: "Ctrl+4", run: () => selectTab(3) },
        { name: "Toggle inspector", shortcut: "Ctrl+I", run: () => inspectorVisible = !inspectorVisible },
        { name: "Toggle full screen", shortcut: "Ctrl+Shift+F", run: () => win.visibility = (win.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen) },
        { name: "About Plane World", shortcut: "", run: () => about.open() },
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
            TabBar {
                id: bar
                currentIndex: win.currentTab
                onCurrentIndexChanged: win.currentTab = currentIndex
                Repeater {
                    model: win.tabs
                    TabButton {
                        required property string modelData
                        required property int index
                        text: modelData
                        width: implicitWidth + Theme.s4
                        ToolTip.visible: hovered
                        ToolTip.delay: 600
                        ToolTip.text: modelData + "  " + Theme.shortcutText("Ctrl+" + (index + 1))
                    }
                }
            }
            Item { Layout.fillWidth: true }
            PwIconButton { text: "↶"; font.pixelSize: Theme.title; enabled: App.canUndo; tip: App.canUndo ? "Undo " + App.undoText : "Nothing to undo"; shortcut: "Ctrl+Z"; onClicked: App.undo() }
            PwIconButton { text: "↷"; font.pixelSize: Theme.title; enabled: App.canRedo; tip: App.canRedo ? "Redo " + App.redoText : "Nothing to redo"; shortcut: "Ctrl+Shift+Z"; onClicked: App.redo() }
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
        tab: win.tabs[win.currentTab]
        sections: win.sectionsByTab[tab]
        inspectorVisible: win.inspectorVisible
    }

    footer: StatusBar { tab: win.tabs[win.currentTab]; viewport: work.viewport }

    AppCommands {
        id: appCommands
        tab: win.tabs[win.currentTab]
        viewport: work.viewport
        onOpenRequested: openDialog.open()
        onSaveAsRequested: saveDialog.open()
        onImportRequested: (into) => { cadDialog.intoCurrent = into; cadDialog.open() }
        onAddPartRequested: cmdPalette.openWith("add ")
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
    Connections { target: App; function onNotify(text, kind) { toast.show(text, kind) } }

    // Unsaved edits: ask before quitting.
    property bool closeConfirmed: false
    onClosing: (close) => { if (App.dirty && !closeConfirmed) { close.accepted = false; unsaved.open() } }
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
