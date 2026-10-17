import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// BUILD › Outputs: one controllable output (servo / motor / jet / solid) with rename, info and its keybind editor.
ColumnLayout {
    id: row
    required property var modelData
    readonly property var output: modelData
    spacing: Theme.s1
    Layout.fillWidth: true

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.s2
        Rectangle { width: 6; height: 6; radius: 3; color: Theme.partTint[row.output.kind] || Theme.textFaint; Layout.alignment: Qt.AlignVCenter }
        TextField {
            id: nameField
            Layout.fillWidth: true
            text: row.output.name
            enabled: row.output.editable
            font.weight: Font.DemiBold
            font.pixelSize: Theme.small
            selectByMouse: true
            onEditingFinished: if (text !== row.output.name) App.renameOutput(row.output.id, text)
            Keys.onEscapePressed: { text = row.output.name; focus = false }
            ToolTip.visible: hovered && !activeFocus
            ToolTip.delay: Theme.tooltipDelay
            ToolTip.text: row.output.editable ? "Rename (Return applies)" : "Automatic motor output for unlinked wheels / props"
        }
        Label { text: row.output.kind; color: Theme.textFaint; font.pixelSize: Theme.caption }
    }
    Label {
        text: row.output.info
        visible: text !== ""
        color: Theme.textMuted; font.pixelSize: Theme.caption
        elide: Text.ElideRight; Layout.fillWidth: true
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.s1
        visible: row.output.editable
        KeyCaptureButton {
            keyName: row.output.pos
            role: "pushes " + row.output.name + " toward its maximum"
            onCaptured: (n) => App.setKeybind(row.output.id, n, row.output.neg, row.output.mode, 0)
        }
        Label { text: "+"; color: Theme.textFaint; font.pixelSize: Theme.caption }
        KeyCaptureButton {
            keyName: row.output.neg
            role: "pushes " + row.output.name + " toward its minimum"
            onCaptured: (n) => App.setKeybind(row.output.id, row.output.pos, n, row.output.mode, 0)
        }
        Label { text: "−"; color: Theme.textFaint; font.pixelSize: Theme.caption }
        Item { Layout.fillWidth: true }
        ComboBox {
            id: modeBox
            model: ["spring", "ramp"]
            currentIndex: row.output.mode === "ramp" ? 1 : 0
            font.pixelSize: Theme.small
            implicitWidth: 92
            onActivated: (i) => App.setKeybind(row.output.id, row.output.pos, row.output.neg, model[i], 0)
            ToolTip.visible: hovered
            ToolTip.delay: Theme.tooltipDelay
            ToolTip.text: "spring: returns to rest when released (stick, rudder)\nramp: stays where you leave it (throttle)"
        }
        Label {
            visible: row.output.conflict
            text: "⚠"
            color: Theme.warn
            HoverHandler { id: wh }
            ToolTip.visible: wh.hovered
            ToolTip.text: "Also a FLY shortcut (R reset, P / Space pause, C camera, E equations). The binding wins for this craft."
        }
    }
    Rectangle { Layout.fillWidth: true; Layout.topMargin: Theme.s1; height: 1; color: Theme.separator; opacity: 0.6 }
}
