import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Window status bar (Swift StatusBar): aero model badge, sim / frame performance, per-tab key hints, version.
Rectangle {
    id: bar
    property string tab: "BUILD"
    property var viewport: null
    property var hintsByTab: ({
        "BUILD": [["Click", "select"], ["Drag arrow", "move axis"], ["⇧ drag", "move"], [Theme.shortcutText("Ctrl+") + "drag", "rotate"], ["⌫", "delete"], [Theme.shortcutText("Ctrl+Z"), "undo"]],
        "FLY": [["R", "reset"], ["P", "pause"], ["C", "camera"], ["E", "equations"], [Theme.shortcutText("Ctrl+K"), "commands"]],
        "WORLD": [["Click", "apply tool"], ["Right-drag", "pan"], ["WASD", "move"]],
        "EVOLVE": [[Theme.shortcutText("Ctrl+1–4"), "tabs"], [Theme.shortcutText("Ctrl+K"), "commands"]] })
    implicitHeight: row.implicitHeight + Theme.s1 * 2
    color: Theme.surface
    Rectangle { width: parent.width; height: 1; color: Theme.separator }
    RowLayout {
        id: row
        anchors.fill: parent
        anchors.leftMargin: Theme.s3; anchors.rightMargin: Theme.s3
        spacing: Theme.s3
        Rectangle {
            visible: bar.tab === "BUILD" || bar.tab === "FLY"
            radius: 3
            implicitWidth: mlabel.implicitWidth + 10; implicitHeight: mlabel.implicitHeight + 2
            color: Theme.alpha(App.fullModel && App.aeroError === "" ? Theme.cfd : Theme.accent, 0.16)
            Text { id: mlabel; anchors.centerIn: parent; font.pixelSize: Theme.caption; font.weight: Font.DemiBold
                color: App.fullModel && App.aeroError === "" ? Theme.cfd : Theme.accent
                text: App.fullModel && App.aeroError === "" ? (App.cfdMethod === "ns" ? "CFD · NS-FV URANS" : "CFD · LBM") : "FAST · analytic" }
            HoverHandler { id: mh }
            ToolTip.visible: mh.hovered; ToolTip.delay: Theme.tooltipDelay
            ToolTip.text: Theme.tip("Aero model in use (FLY › Aero model)", "Ctrl+Shift+M")
        }
        Text {
            visible: bar.tab === "FLY"
            color: Theme.textMuted; font.pixelSize: Theme.caption; font.family: Theme.mono
            text: (App.paused ? "paused" : "sim ×" + Theme.fixed(App.perf.rtf, 2)) + "  ·  " + (App.perf.substepHz || 0).toFixed(0) + " Hz  ·  sim "
                  + Theme.fixed(App.perf.simMs, 2) + " ms" + (App.perf.full ? "  ·  CFD " + Theme.fixed(App.perf.cfdMs, 2) + " ms" : "")
        }
        Text {
            color: Theme.textMuted; font.pixelSize: Theme.caption; font.family: Theme.mono
            visible: text !== ""
            text: bar.viewport ? (bar.viewport.fps > 0 ? bar.viewport.fps.toFixed(0) + " fps  ·  GPU " + bar.viewport.gpuMs.toFixed(2) + " ms" : (bar.viewport.backendName || "")) : ""
        }
        Item { Layout.fillWidth: true }
        Row {
            spacing: Theme.s3
            Repeater {
                model: bar.hintsByTab[bar.tab] || []
                Row {
                    required property var modelData
                    spacing: Theme.s1
                    KeyHint { raw: true; sequence: modelData[0] }
                    Text { text: modelData[1]; color: Theme.textFaint; font.pixelSize: Theme.caption; anchors.verticalCenter: parent.verticalCenter }
                }
            }
        }
        Text { text: "v" + pwVersion; color: Theme.textFaint; font.pixelSize: Theme.caption }
    }
}
