import QtQuick
import QtQuick.Controls

// Transient status message at the bottom of the window (saves, imports, errors). show(text, kind) where
// kind is "info" | "good" | "warn" | "bad". Hover pauses the timeout; click dismisses.
Rectangle {
    id: toast
    property string message
    property string kind: "info"
    function show(text, k) { message = text; kind = k || "info"; opacity = 1; hide.restart() }
    anchors.horizontalCenter: parent.horizontalCenter
    y: parent.height - height - Theme.s5 - (opacity < 1 ? (1 - opacity) * -12 : 0)
    width: Math.min(row.implicitWidth + Theme.s4 * 2, parent.width - Theme.s6 * 2)
    height: row.implicitHeight + Theme.s2 * 2
    radius: Theme.radius
    color: Theme.hudStrong
    opacity: 0
    visible: opacity > 0.01
    z: 1000
    Behavior on opacity { NumberAnimation { duration: Theme.normal; easing.type: Theme.easing } }
    Timer { id: hide; interval: toast.kind === "bad" ? 6000 : 3200; onTriggered: if (!ma.containsMouse) toast.opacity = 0; else restart() }
    Row {
        id: row
        anchors.centerIn: parent
        spacing: Theme.s2
        Rectangle { width: 8; height: 8; radius: 4; anchors.verticalCenter: parent.verticalCenter
            color: toast.kind === "good" ? Theme.good : toast.kind === "warn" ? Theme.warn : toast.kind === "bad" ? Theme.bad : Theme.info }
        Text { text: toast.message; color: Theme.hudText; font.pixelSize: Theme.small; elide: Text.ElideMiddle
            width: Math.min(implicitWidth, toast.parent ? toast.parent.width - Theme.s6 * 3 : 600) }
    }
    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: toast.opacity = 0 }
}
