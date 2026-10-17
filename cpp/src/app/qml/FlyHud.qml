import QtQuick
import QtQuick.Layouts

// FLY viewport overlay: primary flight readouts (airspeed, altitude, vertical speed, attitude, AoA, G), an
// attitude ladder, warnings, throttle-style output bars with held keys, and the paused / crashed states.
Item {
    id: hud
    readonly property var t: App.telemetry
    visible: App.mode === "fly"

    component Readout: Column {
        property string label
        property string value
        property string unit
        property bool warn: false
        spacing: 0
        Text { text: label; color: Theme.hudFaint; font.pixelSize: Theme.micro + 1; font.weight: Font.DemiBold; font.letterSpacing: 0.8 }
        Row {
            spacing: 3
            Text { text: value; color: warn ? Theme.warn : Theme.hudText; font.pixelSize: Theme.title + 4; font.family: Theme.mono; font.weight: Font.DemiBold }
            Text { text: unit; color: Theme.hudMuted; font.pixelSize: Theme.caption; anchors.baseline: parent.children[0].baseline }
        }
    }

    // ---- left: speed column
    Rectangle {
        id: speedBox
        anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: Theme.s3 }
        radius: Theme.radius; color: Theme.hud
        width: speedCol.implicitWidth + Theme.s3 * 2; height: speedCol.implicitHeight + Theme.s3 * 2
        Column {
            id: speedCol
            anchors.centerIn: parent
            spacing: Theme.s2
            Readout { label: "IAS"; value: Theme.fixed(hud.t.ias, 1); unit: "m/s" }
            Readout { label: "GS"; value: Theme.fixed(hud.t.gs, 1); unit: "m/s" }
            Readout { label: "MACH"; value: Theme.fixed(hud.t.mach, 2); unit: "" }
            Readout { label: "AOA"; value: Theme.signed(hud.t.aoa, 1); unit: "°"; warn: (hud.t.stalled || 0) > 0 }
        }
    }
    // ---- right: altitude column
    Rectangle {
        anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: Theme.s3 }
        radius: Theme.radius; color: Theme.hud
        width: altCol.implicitWidth + Theme.s3 * 2; height: altCol.implicitHeight + Theme.s3 * 2
        Column {
            id: altCol
            anchors.centerIn: parent
            spacing: Theme.s2
            Readout { label: "ALT MSL"; value: Theme.fixed(hud.t.alt, 0); unit: "m" }
            Readout { label: "AGL"; value: Theme.fixed(hud.t.agl, 1); unit: "m"; warn: hud.t.agl < 5 && hud.t.vs < -3 }
            Readout { label: "VS"; value: Theme.signed(hud.t.vs, 1); unit: "m/s" }
            Readout { label: "G"; value: Theme.fixed(hud.t.g, 2); unit: ""; warn: Math.abs(hud.t.g || 1) > 6 }
        }
    }

    // ---- centre: attitude ladder (pitch lines move, horizon rolls)
    Item {
        id: att
        width: Math.min(parent.width * 0.32, 300); height: width * 0.62
        anchors.centerIn: parent
        opacity: 0.85
        clip: true
        readonly property real pxPerDeg: height / 40
        Item {
            anchors.centerIn: parent
            width: parent.width * 1.6; height: parent.height * 4
            rotation: -(hud.t.roll || 0)
            Behavior on rotation { NumberAnimation { duration: 80 } }
            Repeater {
                model: [-30, -20, -10, 0, 10, 20, 30]
                Item {
                    required property int modelData
                    width: parent.width; height: 14
                    y: parent.height / 2 - height / 2 - (modelData - (hud.t.pitch || 0)) * att.pxPerDeg
                    Rectangle { anchors.centerIn: parent; width: modelData === 0 ? parent.width : att.width * 0.34; height: modelData === 0 ? 1.5 : 1
                        color: modelData === 0 ? Theme.hudMuted : Theme.hudFaint }
                    Text { visible: modelData !== 0; x: parent.width / 2 + att.width * 0.19; anchors.verticalCenter: parent.verticalCenter
                        text: modelData; color: Theme.hudFaint; font.pixelSize: Theme.micro; font.family: Theme.mono }
                }
            }
        }
        // fixed aircraft symbol
        Row {
            anchors.centerIn: parent
            spacing: 14
            Rectangle { width: 26; height: 2; color: "#ffd166"; anchors.verticalCenter: parent.verticalCenter }
            Rectangle { width: 6; height: 6; radius: 3; color: "#ffd166" }
            Rectangle { width: 26; height: 2; color: "#ffd166"; anchors.verticalCenter: parent.verticalCenter }
        }
    }
    // heading tape
    Rectangle {
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: Theme.s3 }
        radius: Theme.radius; color: Theme.hud
        width: hdg.implicitWidth + Theme.s4 * 2; height: hdg.implicitHeight + Theme.s1 * 2
        Text { id: hdg; anchors.centerIn: parent; color: Theme.hudText; font.family: Theme.mono; font.pixelSize: Theme.body; font.weight: Font.DemiBold
            text: "HDG " + ("00" + Math.round(hud.t.heading || 0) % 360).slice(-3) + "°   pitch " + Theme.signed(hud.t.pitch, 0) + "°   roll " + Theme.signed(hud.t.roll, 0) + "°" }
    }

    // ---- warnings
    Column {
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: Theme.s6 + Theme.s4 }
        spacing: Theme.s1
        Repeater {
            model: App.warnings
            Rectangle {
                required property string modelData
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Theme.radiusSmall
                color: modelData.startsWith("CRASH") ? Theme.alpha(Theme.bad, 0.85) : Theme.alpha(Theme.warn, 0.85)
                width: wt.implicitWidth + Theme.s3 * 2; height: wt.implicitHeight + Theme.s1 * 2
                Text { id: wt; anchors.centerIn: parent; text: modelData; color: "white"; font.pixelSize: Theme.small; font.weight: Font.Bold; font.letterSpacing: 0.6 }
                SequentialAnimation on opacity { running: modelData.startsWith("STALL"); loops: Animation.Infinite
                    NumberAnimation { to: 0.55; duration: 300 } NumberAnimation { to: 1; duration: 300 } }
            }
        }
    }

    // ---- bottom: mass / fuel / thrust and the aero badge
    Rectangle {
        anchors { left: parent.left; bottom: parent.bottom; margins: Theme.s3 }
        radius: Theme.radius; color: Theme.hud
        width: bottomRow.implicitWidth + Theme.s3 * 2; height: bottomRow.implicitHeight + Theme.s2 * 2
        Row {
            id: bottomRow
            anchors.centerIn: parent
            spacing: Theme.s4
            Text { color: Theme.hudMuted; font.pixelSize: Theme.caption; font.family: Theme.mono; text: "mass " + Theme.fixed(hud.t.mass, 0) + " kg" }
            Text { color: Theme.hudMuted; font.pixelSize: Theme.caption; font.family: Theme.mono; text: "fuel " + Theme.fixed(hud.t.fuel, 1) + " kg" }
            Text { color: Theme.hudMuted; font.pixelSize: Theme.caption; font.family: Theme.mono; text: "thrust " + Theme.fixed(hud.t.thrust, 0) + " N" }
            Text { color: App.fullModel ? Theme.cfd : Theme.hudMuted; font.pixelSize: Theme.caption; font.weight: Font.DemiBold
                text: App.fullModel ? (App.aeroError === "" ? "CFD" : "CFD → fast") : "FAST" }
        }
    }

    // ---- paused veil
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.25)
        opacity: App.paused ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.normal } }
        Column {
            anchors.centerIn: parent
            spacing: Theme.s2
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "PAUSED"; color: Theme.hudText; font.pixelSize: Theme.display; font.weight: Font.Bold; font.letterSpacing: 4 }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.s2
                KeyHint { hud: true; raw: true; sequence: "P" } Text { text: "resume"; color: Theme.hudMuted; font.pixelSize: Theme.caption }
                KeyHint { hud: true; raw: true; sequence: "R" } Text { text: "reset"; color: Theme.hudMuted; font.pixelSize: Theme.caption }
            }
        }
    }
}
