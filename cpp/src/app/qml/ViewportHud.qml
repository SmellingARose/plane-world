import QtQuick

// Translucent viewport overlay: active backend, adapter and frame rate (top-left), hints (bottom).
Item {
    property string backend
    property string adapter
    property real fps
    property string error
    property string tab

    Rectangle {
        x: Theme.s3; y: Theme.s3
        radius: Theme.radius
        color: Theme.hud
        width: hudRow.implicitWidth + Theme.s3 * 2
        height: hudRow.implicitHeight + Theme.s2 * 2
        Row {
            id: hudRow
            anchors.centerIn: parent
            spacing: Theme.s3
            Rectangle { width: 8; height: 8; radius: 4; anchors.verticalCenter: parent.verticalCenter
                color: error !== "" ? "#e5534b" : (backend !== "" ? "#3fb950" : "#d29922") }
            Text { color: Theme.hudText; font.pixelSize: Theme.caption; font.weight: Font.DemiBold
                text: error !== "" ? "GPU error" : (backend !== "" ? backend : "Starting GPU…") }
            Text { color: Qt.rgba(1, 1, 1, 0.7); font.pixelSize: Theme.caption; text: adapter; visible: adapter !== "" }
            Text { color: Qt.rgba(1, 1, 1, 0.7); font.pixelSize: Theme.caption; font.family: Theme.mono
                text: fps > 0 ? fps.toFixed(0) + " fps" : ""; visible: fps > 0 }
        }
    }
    Text {
        anchors.centerIn: parent
        width: parent.width * 0.7
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        visible: error !== ""
        color: Theme.hudText
        text: error
    }
}
