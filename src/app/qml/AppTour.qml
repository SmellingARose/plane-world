import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore

// First-run tour: a short card sequence over a dimmed window. Shown once (Settings "tour/done"); reopen from the
// command palette ("Show the welcome tour") or Settings. ←/→ or Return to move, Esc to skip.
Popup {
    id: tour
    modal: true
    focus: true
    anchors.centerIn: parent
    width: Math.min(520, (parent ? parent.width : 800) - Theme.s6 * 2)
    padding: Theme.s5
    closePolicy: Popup.CloseOnEscape
    property int step: 0
    Settings { id: store; category: "tour2"; property bool done: false }   // v2: shows the tab loop once to existing users too

    readonly property var steps: [
        { tint: "#4caf6a", flow: true, title: qsTr("Welcome to Plane World"), body: qsTr("Four tabs, one loop: build a craft, shape the world it flies in, fly it there, and let evolution learn to fly it (or improve its design). The result goes straight back to FLY.") },
        { tint: Theme.tabTint["BUILD"], title: qsTr("1 · BUILD  %1").arg(Theme.shortcutText("Ctrl+1")), body: qsTr("Add wings, props, jets and sensors; drag the gizmo to place them. Every part's numbers live in the inspector on the right. FLY and EVOLVE always use the craft open here.") },
        { tint: Theme.tabTint["WORLD"], title: qsTr("2 · WORLD  %1").arg(Theme.shortcutText("Ctrl+3")), body: qsTr("Generate terrain or load a real place, then sculpt, paint, plant trees, add water and props. Changes are live in FLY and EVOLVE — no export step. “Fly here” (%1) starts a flight wherever you are looking.").arg(Theme.shortcutText("Ctrl+Shift+2")) },
        { tint: Theme.tabTint["FLY"], title: qsTr("3 · FLY  %1").arg(Theme.shortcutText("Ctrl+2")), body: qsTr("Fly with the keys shown next to each control. Terrain, trees, props and wind from WORLD are real obstacles. The chip at the top right names the world — click it to edit, or switch to flat ground in the inspector.") },
        { tint: Theme.tabTint["EVOLVE"], title: qsTr("4 · EVOLVE  %1").arg(Theme.shortcutText("Ctrl+4")), body: qsTr("Follow the numbered steps: craft & world, what evolves, the goal (picked in plain words), the algorithm — then Start training (%1). The default quick start learns to hold altitude in about ten seconds; then fly the result with its evolved autopilot.").arg(Theme.shortcutText("Ctrl+Return")) },
        { tint: Theme.accent, title: qsTr("Everything is a keystroke away"), body: qsTr("%1 opens the command palette: every action, searchable. %2 opens settings, where this tour lives too.").arg(Theme.shortcutText("Ctrl+K")).arg(Theme.shortcutText("Ctrl+,")) }
    ]

    function start() { step = 0; open() }
    function finish() { store.done = true; close() }
    Component.onCompleted: if (!store.done && Qt.application.arguments.indexOf("--quit-after") < 0) Qt.callLater(start)

    background: Rectangle { radius: Theme.radiusLarge; color: Theme.surfaceRaised; border.color: Theme.separator }
    Overlay.modal: Rectangle { color: Theme.overlay }
    enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.normal } NumberAnimation { property: "scale"; from: 0.96; to: 1; duration: Theme.normal; easing.type: Theme.easing } }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: Theme.fast } }

    contentItem: ColumnLayout {
        spacing: Theme.s4
        focus: true
        Keys.onRightPressed: if (tour.step < tour.steps.length - 1) tour.step++
        Keys.onLeftPressed: if (tour.step > 0) tour.step--
        Keys.onReturnPressed: tour.step < tour.steps.length - 1 ? tour.step++ : tour.finish()
        Rectangle { Layout.preferredWidth: 40; Layout.preferredHeight: 4; radius: 2; color: tour.steps[tour.step].tint
            Behavior on color { ColorAnimation { duration: Theme.normal } } }
        Label { Layout.fillWidth: true; text: tour.steps[tour.step].title; font.pixelSize: Theme.display * 0.8; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
        Label { Layout.fillWidth: true; text: tour.steps[tour.step].body; color: Theme.textMuted; wrapMode: Text.Wrap; lineHeight: 1.25 }
        // the loop between the tabs (welcome card)
        Row {
            visible: !!tour.steps[tour.step].flow
            Layout.alignment: Qt.AlignHCenter
            spacing: Theme.s1
            Repeater {
                model: [["BUILD", qsTr("craft")], ["WORLD", qsTr("place")], ["FLY", qsTr("try it")], ["EVOLVE", qsTr("learn")]]
                Row {
                    required property var modelData
                    required property int index
                    spacing: Theme.s1
                    Rectangle {
                        width: 84; height: 44; radius: Theme.radius
                        color: Theme.alpha(Theme.tabTint[modelData[0]], 0.16); border.color: Theme.tabTint[modelData[0]]
                        Column { anchors.centerIn: parent
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData[0]; color: Theme.text; font.pixelSize: Theme.caption; font.weight: Font.DemiBold }
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData[1]; color: Theme.textMuted; font.pixelSize: Theme.micro } }
                    }
                    Text { visible: index < 3; text: "→"; color: Theme.textFaint; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: Theme.title }
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Row {
                spacing: 6
                Repeater { model: tour.steps.length
                    Rectangle { required property int index; width: index === tour.step ? 18 : 6; height: 6; radius: 3
                        color: index === tour.step ? Theme.accent : Theme.separator
                        Behavior on width { NumberAnimation { duration: Theme.normal; easing.type: Theme.easing } }
                        MouseArea { anchors.fill: parent; onClicked: tour.step = index } } }
            }
            Item { Layout.fillWidth: true }
            Button { text: qsTr("Skip"); flat: true; visible: tour.step < tour.steps.length - 1; onClicked: tour.finish() }
            Button { text: qsTr("Back"); visible: tour.step > 0; onClicked: tour.step-- }
            Button { highlighted: true; text: tour.step < tour.steps.length - 1 ? qsTr("Next") : qsTr("Start"); onClicked: tour.step < tour.steps.length - 1 ? tour.step++ : tour.finish() }
        }
    }
    onClosed: store.done = true
}
