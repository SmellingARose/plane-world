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
    Settings { id: store; category: "tour"; property bool done: false }

    readonly property var steps: [
        { tint: "#4caf6a", title: qsTr("Welcome to Plane World"), body: qsTr("Build aircraft from parts, fly them through a physically simulated world, shape that world, and evolve controllers and designs that fly by themselves.") },
        { tint: Theme.tabTint["BUILD"], title: qsTr("BUILD  %1").arg(Theme.shortcutText("Ctrl+1")), body: qsTr("Add wings, props, jets and sensors; drag the gizmo to place them. Every part's numbers live in the inspector on the right.") },
        { tint: Theme.tabTint["FLY"], title: qsTr("FLY  %1").arg(Theme.shortcutText("Ctrl+2")), body: qsTr("Fly with the keyboard bindings you choose. Switch the aero model from fast panels to full GPU CFD and watch the flow.") },
        { tint: Theme.tabTint["WORLD"], title: qsTr("WORLD  %1").arg(Theme.shortcutText("Ctrl+3")), body: qsTr("Generate terrain or load a real place, then sculpt, paint, plant trees, add lakes and props. Number keys pick tools; [ and ] size the brush.") },
        { tint: Theme.tabTint["EVOLVE"], title: qsTr("EVOLVE  %1").arg(Theme.shortcutText("Ctrl+4")), body: qsTr("Choose what evolves, tune the algorithm, edit the JavaScript reward, press %1 and watch fitness climb. Click any generation to replay it in 3D, then fly it on autopilot.").arg(Theme.shortcutText("Ctrl+Return")) },
        { tint: Theme.accent, title: qsTr("Everything is a keystroke away"), body: qsTr("%1 opens the command palette: every action, searchable. %2 opens settings.").arg(Theme.shortcutText("Ctrl+K")).arg(Theme.shortcutText("Ctrl+,")) }
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
