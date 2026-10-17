import QtQuick
import QtQuick.Controls

// BUILD viewport overlay: view snapping buttons (front / side / top / frame), the gizmo axis being hovered, and
// a short hint for the selected part.
Item {
    id: bh
    property var viewport: null
    visible: App.mode === "build"

    Row {
        anchors { right: parent.right; bottom: parent.bottom; margins: Theme.s3 }
        spacing: 2
        Repeater {
            model: [{ t: "Front", v: "front" }, { t: "Side", v: "right" }, { t: "Top", v: "top" }, { t: "Frame", v: "frame" }]
            Rectangle {
                required property var modelData
                width: lbl.implicitWidth + Theme.s3; height: lbl.implicitHeight + Theme.s1 * 2
                radius: Theme.radiusSmall
                color: ma.containsMouse ? Theme.hudStrong : Theme.hud
                Text { id: lbl; anchors.centerIn: parent; text: modelData.t; color: Theme.hudText; font.pixelSize: Theme.caption }
                MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: modelData.v === "frame" ? bh.viewport.frameCraft() : bh.viewport.setView(modelData.v) }
                ToolTip.visible: ma.containsMouse; ToolTip.delay: Theme.tooltipDelay
                ToolTip.text: modelData.v === "frame" ? Theme.tip("Frame the craft", "F") : "Snap to the " + modelData.t.toLowerCase() + " view (command palette: View)"
            }
        }
    }

    Rectangle {
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: Theme.s3 }
        visible: App.selectedId !== ""
        radius: Theme.radius; color: Theme.hud
        width: selRow.implicitWidth + Theme.s3 * 2; height: selRow.implicitHeight + Theme.s1 * 2
        Row {
            id: selRow
            anchors.centerIn: parent
            spacing: Theme.s2
            Rectangle { width: 8; height: 8; radius: 4; color: App.selected.color || "#888"; anchors.verticalCenter: parent.verticalCenter }
            Text { text: App.selected.name || ""; color: Theme.hudText; font.pixelSize: Theme.caption; font.weight: Font.DemiBold }
            Text {
                text: bh.viewport && bh.viewport.hoverAxis !== "" ? "drag to move along " + bh.viewport.hoverAxis
                    : "arrows nudge · Q/E rotate · drag an arrow to move"
                color: Theme.hudMuted; font.pixelSize: Theme.caption
            }
        }
    }
}
