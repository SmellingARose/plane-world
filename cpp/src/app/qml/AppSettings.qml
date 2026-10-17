import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore

// Settings (Ctrl+, / ⌘,). Persisted with QSettings (QtCore Settings) per user; applied live.
Dialog {
    id: dlg
    modal: true
    anchors.centerIn: parent
    width: Math.min(560, (parent ? parent.width : 800) - Theme.s6 * 2)
    title: qsTr("Settings")
    standardButtons: Dialog.Close

    Settings {
        id: ui
        category: "ui"
        property bool reduceMotion: false
        property bool inspectorRight: true
    }
    Settings {
        id: world
        category: "world"
        property int defaultResolution: 1025
        property double defaultBrush: 40
    }
    Settings {
        id: evolve
        category: "evolve"
        property int replaySpeedIndex: 2
    }
    Settings { id: tourStore; category: "tour"; property bool done: false }

    // apply on start-up and on change
    Binding { target: Theme; property: "motion"; value: ui.reduceMotion ? 0 : 1 }
    Component.onCompleted: { WorldModel.procSize = world.defaultResolution; WorldModel.brushRadius = world.defaultBrush }

    contentItem: ColumnLayout {
        spacing: Theme.s4
        PwSection {
            Layout.fillWidth: true
            title: qsTr("Interface")
            Switch { text: qsTr("Reduce motion"); checked: ui.reduceMotion; onToggled: ui.reduceMotion = checked
                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Turns off interface animations") }
            Label { Layout.fillWidth: true; wrapMode: Text.Wrap; color: Theme.textFaint; font.pixelSize: Theme.caption
                text: qsTr("Colours, accent and light / dark mode follow your system settings.") }
            Button { text: qsTr("Show the welcome tour again"); onClicked: { tourStore.done = false; dlg.close(); tourRequested() } }
        }
        PwSection {
            Layout.fillWidth: true
            title: qsTr("World")
            PwPropertyRow { label: qsTr("New terrain"); Layout.fillWidth: true
                ComboBox { Layout.fillWidth: true; model: ["513", "1025", "2049"]; currentIndex: Math.max(0, model.indexOf(String(world.defaultResolution)))
                    onActivated: { world.defaultResolution = parseInt(currentText); WorldModel.procSize = world.defaultResolution } } }
            PwPropertyRow { label: qsTr("Brush radius"); Layout.fillWidth: true
                PwNumberField { value: world.defaultBrush; suffix: " m"; decimals: 0; step: 5; minimum: 2; maximum: 500
                    onCommitted: (v) => { world.defaultBrush = v; WorldModel.brushRadius = v } } }
            PwStatRow { Layout.fillWidth: true; label: qsTr("World library"); value: WorldModel.libraryDir }
        }
        PwSection {
            Layout.fillWidth: true
            title: qsTr("Evolve")
            PwStatRow { Layout.fillWidth: true; label: qsTr("Script engine"); value: EvolveModel.engineName }
            PwStatRow { Layout.fillWidth: true; label: qsTr("Experiments"); value: EvolveModel.libraryDir }
            Label { Layout.fillWidth: true; wrapMode: Text.Wrap; color: Theme.textFaint; font.pixelSize: Theme.caption
                text: qsTr("Set PW_SCRIPT_ENGINE=quickjs to force QuickJS; worker count is per experiment (0 = all cores).") }
        }
    }
    signal tourRequested()
}
