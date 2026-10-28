import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Segmented choice from native buttons (macOS / Windows styles render a joined group look via checked state).
// model: ["Speed", "Pressure"] or [{ text, tip }]. ←/→ move the selection when focused.
RowLayout {
    id: seg
    property var model: []
    property int currentIndex: 0
    signal activated(int index)
    spacing: 0
    Layout.fillWidth: true
    activeFocusOnTab: true
    Keys.onLeftPressed: if (currentIndex > 0) { currentIndex--; activated(currentIndex) }
    Keys.onRightPressed: if (currentIndex < model.length - 1) { currentIndex++; activated(currentIndex) }
    ButtonGroup { id: grp }
    Repeater {
        model: seg.model
        Button {
            required property var modelData
            required property int index
            Layout.fillWidth: true
            text: typeof modelData === "string" ? modelData : modelData.text
            readonly property bool selected: index === seg.currentIndex
            // macOS paints a checked button solid blue while the window is active (and plain otherwise), so there the
            // selection is only the overlay below: one look, focused or not
            checkable: !Theme.mac
            checked: selected && !Theme.mac
            ButtonGroup.group: grp
            font.pixelSize: Theme.small
            focusPolicy: Qt.NoFocus
            highlighted: checked
            onClicked: { seg.currentIndex = index; seg.activated(index) }
            Rectangle {
                visible: Theme.mac && parent.selected
                anchors.fill: parent; anchors.margins: 3
                radius: Theme.radiusSmall
                color: Theme.accentSoft
                border.width: 1.5; border.color: Theme.accent
                z: 1
            }
            ToolTip.visible: hovered && typeof modelData !== "string" && !!modelData.tip
            ToolTip.delay: Theme.tooltipDelay
            ToolTip.text: typeof modelData === "string" ? "" : (modelData.tip || "")
        }
    }
}
