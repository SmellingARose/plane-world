import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// WORLD tab: live world viewport with a floating tool palette + the WORLD inspector.
// Keys (while this tab is shown): 1–9 / P / L / O pick tools, Esc back to Look, Ctrl+Z / Ctrl+Shift+Z undo / redo,
// Ctrl+S save, Ctrl+Shift+S save as, Ctrl+O saved worlds, Ctrl+G generate terrain.
SplitView {
    id: page
    property bool inspectorVisible: true
    property alias viewport: vp
    function flyHere() { panel.flyHere() }
    orientation: Qt.Horizontal
    readonly property var wm: WorldModel

    Shortcut { sequence: "Esc"; enabled: page.visible && wm.tool !== "orbit"; onActivated: wm.tool = "orbit" }
    Shortcut { sequences: [StandardKey.Undo]; enabled: page.visible; onActivated: wm.undo() }
    Shortcut { sequences: [StandardKey.Redo, "Ctrl+Shift+Z"]; enabled: page.visible; onActivated: wm.redo() }
    Shortcut { sequences: [StandardKey.Save]; enabled: page.visible && !wm.busy; onActivated: WorldFlow.save() }
    Shortcut { sequence: "Ctrl+Shift+S"; enabled: page.visible && !wm.busy; onActivated: WorldFlow.saveAs() }
    Shortcut { sequences: [StandardKey.Open]; enabled: page.visible; onActivated: WorldFlow.manage() }
    Shortcut { sequence: "Ctrl+Shift+2"; enabled: page.visible && !wm.busy; onActivated: panel.flyHere() }
    Shortcut { sequence: "Ctrl+G"; enabled: page.visible && !wm.busy; onActivated: wm.generate() }

    Item {
        SplitView.fillWidth: true
        SplitView.minimumWidth: 320
        Repeater {
            model: WorldTools.terrainTools
            Item {
                required property var modelData
                Shortcut { sequence: modelData.key; enabled: page.visible; onActivated: wm.tool = modelData.id }
            }
        }
        WorldViewport {
            id: vp
            objectName: "worldViewport"
            anchors.fill: parent
            visible: page.visible
            focus: true
            editWorld: true
        }

        // floating tool palette
        Rectangle {
            id: palette
            anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: Theme.s3 }
            radius: Theme.radiusLarge
            color: Theme.hud
            width: toolRow.implicitWidth + Theme.s2 * 2
            height: toolRow.implicitHeight + Theme.s2 * 2
            opacity: vp.interacting && wm.tool === "orbit" ? 0.35 : 1
            Behavior on opacity { NumberAnimation { duration: Theme.normal } }
            Row {
                id: toolRow
                anchors.centerIn: parent
                spacing: 2
                Repeater {
                    model: WorldTools.terrainTools
                    delegate: Rectangle {
                        id: chip
                        required property var modelData
                        readonly property bool active: wm.tool === modelData.id
                        width: 34; height: 34; radius: Theme.radiusSmall
                        color: active ? Theme.accent : (ma.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : "transparent")
                        Behavior on color { ColorAnimation { duration: Theme.fast } }
                        Text { anchors.centerIn: parent; text: modelData.icon; color: chip.active ? Theme.accentText : Theme.hudText; font.pixelSize: 16 }
                        Text { anchors { right: parent.right; bottom: parent.bottom; margins: 2 } text: modelData.key; color: chip.active ? Theme.accentText : Theme.hudFaint; font.pixelSize: 8 }
                        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: wm.tool = modelData.id }
                        ToolTip.visible: ma.containsMouse; ToolTip.delay: Theme.tooltipDelay
                        ToolTip.text: modelData.label + " — " + modelData.tip + "   " + modelData.key
                    }
                }
            }
        }

        // brush readout / cursor coordinates (bottom left)
        Rectangle {
            anchors { left: parent.left; bottom: parent.bottom; margins: Theme.s3 }
            radius: Theme.radius
            color: Theme.hud
            width: readout.implicitWidth + Theme.s3 * 2
            height: readout.implicitHeight + Theme.s2 * 2
            Column {
                id: readout
                anchors.centerIn: parent
                spacing: 2
                Text {
                    color: Theme.hudText; font.pixelSize: Theme.caption; font.weight: Font.DemiBold
                    text: WorldTools.info(wm.tool).label + (["orbit", "prop", "spawn"].indexOf(wm.tool) < 0
                          ? "  ·  " + (wm.tool === "lake" ? wm.lakeRadius : wm.brushRadius).toFixed(0) + " m" : "")
                }
                Text {
                    visible: vp.cursorValid
                    color: Theme.hudMuted; font.pixelSize: Theme.caption; font.family: Theme.mono
                    text: "x %1  z %2  h %3 m".arg(vp.cursor.x.toFixed(0)).arg(vp.cursor.z.toFixed(0)).arg(vp.cursor.y.toFixed(1))
                }
                Text {
                    color: Theme.hudFaint; font.pixelSize: Theme.micro
                    text: wm.tool === "orbit" ? qsTr("Drag orbit · right-drag pan · WASD move · wheel zoom")
                                             : qsTr("Drag to apply · Alt-drag orbit · [ ] size · Esc stop")
                }
            }
        }

        // GPU status pill (top left), reused from the shared HUD look
        Rectangle {
            anchors { left: parent.left; top: parent.top; margins: Theme.s3 }
            radius: Theme.radius; color: Theme.hud
            width: st.implicitWidth + Theme.s3 * 2; height: st.implicitHeight + Theme.s2 * 2
            Text {
                id: st; anchors.centerIn: parent; color: vp.error !== "" ? Theme.bad : Theme.hudText; font.pixelSize: Theme.caption
                text: vp.error !== "" ? vp.error : (vp.backendName === "" ? qsTr("Starting GPU…") : vp.backendName + (vp.fps > 0 ? "  " + vp.fps.toFixed(0) + " fps" : ""))
            }
        }
    }

    WorldPanel {
        id: panel
        visible: page.inspectorVisible
        SplitView.preferredWidth: Theme.inspectorWidth + 20
        SplitView.minimumWidth: 260
        SplitView.maximumWidth: 560
        viewport: vp
    }
}
