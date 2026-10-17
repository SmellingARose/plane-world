import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

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

    readonly property var commands: [
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

    footer: Rectangle {
        height: footRow.implicitHeight + Theme.s1 * 2
        color: Theme.surface
        Rectangle { width: parent.width; height: 1; color: Theme.separator }
        RowLayout {
            id: footRow
            anchors.fill: parent
            anchors.leftMargin: Theme.s3; anchors.rightMargin: Theme.s3
            Label { text: win.tabs[win.currentTab] + " · ready"; color: Theme.textMuted; font.pixelSize: Theme.caption }
            Item { Layout.fillWidth: true }
            Label { text: (work.viewport.backendName || "GPU") + " · " + pwCpu; color: Theme.textFaint; font.pixelSize: Theme.caption; elide: Text.ElideMiddle }
            Label { text: "v" + pwVersion; color: Theme.textFaint; font.pixelSize: Theme.caption }
        }
    }

    CommandPalette { id: cmdPalette; parent: Overlay.overlay; commands: win.commands }

    Dialog {
        id: about
        parent: Overlay.overlay
        anchors.centerIn: parent
        title: "Plane World"
        standardButtons: Dialog.Ok
        modal: true
        Label { text: "C++ / Qt 6 port, version " + pwVersion + "\n" + pwCpu + "\nRenderer: " + (work.viewport.backendName || "?") + " — " + work.viewport.adapterName }
    }
}
