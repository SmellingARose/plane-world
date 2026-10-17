import QtQuick

// Translucent viewport overlay: status pill (backend, adapter, frame rate, GPU time) top-left, optional per-pass GPU
// timings (G), time of day, and a quiet row of interaction hints along the bottom that fades out while you work.
Item {
    id: hud
    property string backend
    property string adapter
    property real fps
    property real gpuMs
    property string passes
    property bool asyncCompute
    property bool showStats
    property real timeOfDay: 10
    property string craft
    property string error
    property string tab
    property bool interacting: false

    function clock(h) {
        const hh = Math.floor(h), mm = Math.round((h - hh) * 60)
        return (hh < 10 ? "0" : "") + hh + ":" + (mm < 10 ? "0" : "") + (mm % 60)
    }

    Rectangle {
        id: pill
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
                color: error !== "" ? "#e5534b" : (backend !== "" ? "#3fb950" : "#d29922")
                Behavior on color { ColorAnimation { duration: Theme.normal } } }
            Text { color: Theme.hudText; font.pixelSize: Theme.caption; font.weight: Font.DemiBold
                text: error !== "" ? "GPU error" : (backend !== "" ? backend : "Starting GPU…") }
            Text { color: Qt.rgba(1, 1, 1, 0.7); font.pixelSize: Theme.caption; text: adapter; visible: adapter !== "" }
            Text { color: Qt.rgba(1, 1, 1, 0.85); font.pixelSize: Theme.caption; font.family: Theme.mono
                text: fps > 0 ? fps.toFixed(0) + " fps" : ""; visible: fps > 0 }
            Text { color: Qt.rgba(1, 1, 1, 0.6); font.pixelSize: Theme.caption; font.family: Theme.mono
                text: gpuMs > 0 ? "GPU " + gpuMs.toFixed(2) + " ms" : ""; visible: gpuMs > 0 }
        }
    }

    // Per-pass GPU timings (toggle with G).
    Rectangle {
        anchors { left: pill.left; top: pill.bottom; topMargin: Theme.s2 }
        radius: Theme.radius
        color: Theme.hud
        width: statsCol.implicitWidth + Theme.s3 * 2
        height: statsCol.implicitHeight + Theme.s2 * 2
        opacity: showStats && passes !== "" ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.normal; easing.type: Theme.easing } }
        Column {
            id: statsCol
            anchors.centerIn: parent
            spacing: Theme.s1
            Text { color: Theme.hudText; font.pixelSize: Theme.caption; font.weight: Font.DemiBold
                text: "Frame graph" + (asyncCompute ? "  ·  async compute" : "") }
            Repeater {
                model: passes.split("  ").filter(s => s.length > 0)
                Text { color: Qt.rgba(1, 1, 1, 0.75); font.pixelSize: Theme.caption; font.family: Theme.mono; text: modelData }
            }
        }
    }

    // Craft + time of day, top-right.
    Rectangle {
        anchors { right: parent.right; top: parent.top; margins: Theme.s3 }
        radius: Theme.radius
        color: Theme.hud
        visible: backend !== "" && error === ""
        width: infoRow.implicitWidth + Theme.s3 * 2
        height: infoRow.implicitHeight + Theme.s2 * 2
        Row {
            id: infoRow
            anchors.centerIn: parent
            spacing: Theme.s3
            Text { color: Theme.hudText; font.pixelSize: Theme.caption; font.weight: Font.DemiBold; text: craft; visible: craft !== "" }
            Text { color: Qt.rgba(1, 1, 1, 0.7); font.pixelSize: Theme.caption; font.family: Theme.mono; text: "☀ " + clock(timeOfDay) }
        }
    }

    // Interaction hints (fade while the user is interacting).
    Rectangle {
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: Theme.s3 }
        radius: Theme.radius
        color: Theme.hud
        visible: backend !== "" && error === ""
        opacity: interacting ? 0.0 : 0.9
        Behavior on opacity { NumberAnimation { duration: Theme.normal; easing.type: Theme.easing } }
        width: hints.implicitWidth + Theme.s3 * 2
        height: hints.implicitHeight + Theme.s2 * 2
        Row {
            id: hints
            anchors.centerIn: parent
            spacing: Theme.s4
            Repeater {
                model: [["Drag", "orbit"], ["Scroll", "zoom"], ["F", "frame"], ["[ ]", "time of day"], ["G", "GPU stats"]]
                Row {
                    spacing: Theme.s1
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        radius: Theme.radiusSmall; color: "transparent"; border.color: Qt.rgba(1, 1, 1, 0.3)
                        width: k.implicitWidth + Theme.s2; height: k.implicitHeight + 2
                        Text { id: k; anchors.centerIn: parent; text: modelData[0]; color: Theme.hudText; font.pixelSize: Theme.caption }
                    }
                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData[1]; color: Qt.rgba(1, 1, 1, 0.7); font.pixelSize: Theme.caption }
                }
            }
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
