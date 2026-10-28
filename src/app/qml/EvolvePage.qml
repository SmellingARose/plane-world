import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// EVOLVE tab: the world viewport (replays fly in it) with a replay transport + live output bars, and the EVOLVE
// inspector. Keys while shown: Ctrl+Return train / pause, Space play / pause replay, ←/→ scrub (with the replay
// focused), Esc closes the replay, panel pages Set up / Train / Goal via Alt+1..3, Ctrl+Shift+E large editor.
SplitView {
    id: page
    property bool inspectorVisible: true
    property alias viewport: vp
    orientation: Qt.Horizontal
    readonly property var ev: EvolveModel
    signal flyRequested(string craftPath)

    Connections { target: EvolveModel; function onFlyRequested(p) { page.flyRequested(p) } }

    function train() { panel.train() }
    function showWiring() { panel.showWiring() }
    function showAlgorithm(compare) { panel.showAlgorithm(compare) }
    function showGoal(view) { panel.showGoal(view) }
    Shortcut { sequence: "Ctrl+Return"; enabled: page.visible; onActivated: panel.train() }
    Shortcut { sequences: [StandardKey.Save]; enabled: page.visible; onActivated: ev.save() }
    Shortcut { sequence: "Ctrl+Shift+S"; enabled: page.visible; onActivated: panel.saveFileAs() }
    Shortcut { sequences: [StandardKey.Open]; enabled: page.visible; onActivated: panel.openFile() }
    Shortcut { sequence: "Ctrl+Shift+E"; enabled: page.visible; onActivated: bigEditor.show() }
    Shortcut { sequence: "Alt+1"; enabled: page.visible; onActivated: panel.page = 0 }
    Shortcut { sequence: "Alt+2"; enabled: page.visible; onActivated: panel.page = 1 }
    Shortcut { sequence: "Alt+3"; enabled: page.visible; onActivated: panel.page = 2 }
    Shortcut { sequence: "Esc"; enabled: page.visible && ev.replayActive; onActivated: ev.stopReplay() }

    Item {
        SplitView.fillWidth: true
        SplitView.minimumWidth: 320
        WorldViewport {
            id: vp
            objectName: "evolveViewport"
            anchors.fill: parent
            visible: page.visible
            focus: true
            editWorld: false
            showReplay: true
            Keys.onSpacePressed: ev.replayPlaying = !ev.replayPlaying
        }

        // empty / busy hint under the parked craft
        Rectangle {
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: Theme.s6 }
            visible: !ev.replayActive
            radius: Theme.radiusLarge; color: Theme.hud
            width: hintCol.implicitWidth + Theme.s5 * 2; height: hintCol.implicitHeight + Theme.s4 * 2
            opacity: vp.interacting ? 0.2 : 0.92
            Behavior on opacity { NumberAnimation { duration: Theme.normal } }
            Column {
                id: hintCol
                anchors.centerIn: parent
                spacing: Theme.s2
                BusyIndicator { anchors.horizontalCenter: parent.horizontalCenter; running: ev.replayBusy || ev.preparing; visible: running; implicitWidth: 28; implicitHeight: 28 }
                Text { anchors.horizontalCenter: parent.horizontalCenter; color: Theme.hudText; font.pixelSize: Theme.title; font.weight: Font.DemiBold
                    text: ev.replayBusy ? qsTr("Re-simulating…") : ev.preparing ? qsTr("Preparing run…") : ev.running ? qsTr("Training") : qsTr("Evolve a flyer") }
                Text { anchors.horizontalCenter: parent.horizontalCenter; color: Theme.hudMuted; font.pixelSize: Theme.caption; horizontalAlignment: Text.AlignHCenter
                    text: ev.generations.length > 0 ? qsTr("Click a generation in the chart or table to replay it here")
                                                   : qsTr("Follow steps 1–4 on the right (or keep the quick start), then Start training  %1").arg(Theme.shortcutText("Ctrl+Return")) }
            }
        }

        // replay transport
        Rectangle {
            id: transport
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: Theme.s3 }
            height: tCol.implicitHeight + Theme.s2 * 2
            radius: Theme.radiusLarge; color: Theme.hudStrong
            opacity: ev.replayActive ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: Theme.normal; easing.type: Theme.easing } }
            ColumnLayout {
                id: tCol
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: Theme.s3 }
                spacing: Theme.s1
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.s2
                    ToolButton { text: ev.replayPlaying ? "❚❚" : "▶"; onClicked: ev.replayPlaying = !ev.replayPlaying
                        palette.buttonText: Theme.hudText; ToolTip.visible: hovered; ToolTip.text: qsTr("Play / pause  Space") }
                    Text { text: ev.replayTime.toFixed(1) + " / " + ev.replayDuration.toFixed(1) + " s"; color: Theme.hudText; font.family: Theme.mono; font.pixelSize: Theme.caption }
                    Slider {
                        id: scrub
                        Layout.fillWidth: true
                        from: 0; to: Math.max(0.01, ev.replayDuration)
                        value: ev.replayTime
                        onMoved: { ev.replayPlaying = false; ev.replayTime = value }
                    }
                    ComboBox {
                        model: ["0.25×", "0.5×", "1×", "2×", "4×"]
                        readonly property var speeds: [0.25, 0.5, 1, 2, 4]
                        currentIndex: Math.max(0, speeds.indexOf(ev.replaySpeed))
                        onActivated: (i) => ev.replaySpeed = speeds[i]
                        implicitWidth: 76
                    }
                    ToolButton { text: "✕"; onClicked: ev.stopReplay(); palette.buttonText: Theme.hudText; ToolTip.visible: hovered; ToolTip.text: qsTr("Close replay  Esc") }
                }
                Text { Layout.fillWidth: true; text: ev.selected + "  ·  " + ev.replayInfo; color: Theme.hudMuted; font.pixelSize: Theme.micro; elide: Text.ElideRight }
            }
        }

        // flight telemetry (altitude, vertical speed, tilt, distance) of the replayed episode
        Rectangle {
            id: telem
            readonly property var tm: ev.replayTelemetry
            anchors { left: parent.left; top: parent.top; margins: Theme.s3 }
            visible: ev.replayActive && tm.alt !== undefined
            radius: Theme.radius; color: Theme.hud
            width: 236; height: telCol.implicitHeight + Theme.s3 * 2
            Column {
                id: telCol
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: Theme.s3 }
                spacing: 2
                Text { text: qsTr("FLIGHT  ·  T+%1 s").arg(telem.tm.t !== undefined ? telem.tm.t.toFixed(1) : "0.0"); color: Theme.hudFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking }
                Repeater {
                    model: [
                        { k: qsTr("ALT"), v: telem.tm.alt, d: 1, u: "m", warn: false },
                        { k: qsTr("V/S"), v: telem.tm.vs, d: 1, u: "m/s", warn: telem.tm.alt < 3 && telem.tm.vs < -3 },
                        { k: qsTr("TILT"), v: telem.tm.tilt, d: 1, u: "°", warn: telem.tm.tilt > 20 },
                        { k: qsTr("PAD"), v: telem.tm.dist, d: 1, u: "m", warn: false }
                    ]
                    Row {
                        required property var modelData
                        spacing: Theme.s2
                        Text { width: 52; text: modelData.k; color: Theme.hudMuted; font.family: Theme.mono; font.pixelSize: Theme.body; anchors.baseline: val.baseline }
                        Text { id: val; width: 110; horizontalAlignment: Text.AlignRight
                            text: modelData.v !== undefined ? (modelData.v >= 0 && modelData.k === qsTr("V/S") ? "+" : "") + modelData.v.toFixed(modelData.d) : "–"
                            color: modelData.warn ? "#ff7a6b" : Theme.hudText; font.family: Theme.mono; font.pixelSize: Theme.display; font.weight: Font.DemiBold }
                        Text { text: modelData.u; color: Theme.hudMuted; font.family: Theme.mono; font.pixelSize: Theme.caption; anchors.baseline: val.baseline }
                    }
                }
                Text { visible: telem.tm.ended === true; text: telem.tm.doneReason === "crash" ? qsTr("CRASHED") : telem.tm.doneReason === "script" ? qsTr("TOUCHDOWN") : qsTr("END: %1").arg(telem.tm.doneReason || "time")
                    color: telem.tm.doneReason === "crash" ? "#ff7a6b" : "#7be08a"; font.pixelSize: Theme.title; font.weight: Font.Bold; font.letterSpacing: Theme.sectionTracking }
            }
        }

        // live outputs (what the controller is doing right now)
        Rectangle {
            anchors { right: parent.right; top: parent.top; margins: Theme.s3 }
            visible: ev.replayActive && ev.replayOutputs.length > 0
            radius: Theme.radius; color: Theme.hud
            width: 210; height: outCol.implicitHeight + Theme.s2 * 2
            Column {
                id: outCol
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: Theme.s2 }
                spacing: 3
                Text { text: qsTr("CONTROLLER OUTPUTS"); color: Theme.hudFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking }
                Repeater {
                    model: ev.replayOutputs
                    Item {
                        required property var modelData
                        width: outCol.width; height: 14
                        Text { id: on; text: modelData.name; color: Theme.hudMuted; font.pixelSize: Theme.micro; width: 80; elide: Text.ElideRight; anchors.verticalCenter: parent.verticalCenter }
                        Rectangle {
                            anchors { left: on.right; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 4 }
                            height: 6; radius: 3; color: Qt.rgba(1, 1, 1, 0.12)
                            Rectangle {
                                readonly property real v: Math.max(-1, Math.min(1, modelData.value))
                                x: v >= 0 ? parent.width / 2 : parent.width / 2 * (1 + v)
                                width: Math.abs(v) * parent.width / 2; height: parent.height; radius: 3
                                color: Theme.tabTint["EVOLVE"]
                            }
                            Rectangle { x: parent.width / 2; width: 1; height: parent.height; color: Qt.rgba(1, 1, 1, 0.4) }
                        }
                    }
                }
            }
        }
    }

    EvolvePanel {
        id: panel
        visible: page.inspectorVisible
        SplitView.preferredWidth: 400
        SplitView.minimumWidth: 300
        SplitView.maximumWidth: 720
        onOpenEditorWindow: bigEditor.show()
    }

    // large script editor window (same document; edits flow through EvolveModel)
    ApplicationWindow {
        id: bigEditor
        title: qsTr("%1 — script").arg(ev.name)
        width: 900; height: 700
        color: Theme.window
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.s3
            spacing: Theme.s2
            EvolveCodeEditor {
                id: bigEd
                Layout.fillWidth: true; Layout.fillHeight: true
                text: ev.experiment.scripts ? ev.experiment.scripts.source : ""
                errorLine: ev.scriptErrorLine
                errorMessage: ev.scriptMessage
                onEdited: (t) => ev.setScript(t)
                onCheckRequested: ev.checkScript()
                Connections { target: EvolveModel; function onExperimentChanged() { const s = EvolveModel.experiment.scripts ? EvolveModel.experiment.scripts.source : ""; if (s !== bigEd.text) bigEd.text = s } }
            }
            RowLayout {
                Button { text: qsTr("Check"); onClicked: ev.checkScript() }
                Label { Layout.fillWidth: true; text: ev.scriptMessage; color: ev.scriptOk ? Theme.good : Theme.bad; elide: Text.ElideRight; font.family: Theme.mono; font.pixelSize: Theme.caption }
                Button { text: qsTr("Close"); onClicked: bigEditor.close() }
            }
        }
        Shortcut { sequence: "Esc"; onActivated: bigEditor.close() }
    }
}
