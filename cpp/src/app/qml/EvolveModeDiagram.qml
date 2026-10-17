import QtQuick
import QtQuick.Controls

// "What evolves" diagram: genome → (craft and/or controller) → flight → fitness, with the parts that mutate in the
// chosen mode highlighted. Pure QML shapes so it follows the theme in light and dark.
Item {
    id: d
    property string mode: "neural"      // neural | design | coevolve | script
    property int inputs: 0
    property int outputs: 0
    property int genes: 0
    property int designGenes: 0
    implicitHeight: 92

    readonly property bool craftEvolves: mode === "design" || mode === "coevolve"
    readonly property bool brainEvolves: mode === "neural" || mode === "coevolve"
    readonly property color hot: Theme.tabTint["EVOLVE"]

    component Node: Rectangle {
        property string title
        property string sub
        property bool on: false
        radius: Theme.radius
        color: on ? Theme.alpha(d.hot, Theme.dark ? 0.28 : 0.16) : Theme.card
        border.color: on ? d.hot : Theme.separator
        border.width: on ? 1.5 : 1
        Behavior on color { ColorAnimation { duration: Theme.normal } }
        Behavior on border.color { ColorAnimation { duration: Theme.normal } }
        Column {
            anchors.centerIn: parent
            spacing: 1
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: title; color: Theme.text; font.pixelSize: Theme.small; font.weight: Font.DemiBold }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: sub; color: Theme.textMuted; font.pixelSize: Theme.micro }
        }
    }
    component Arrow: Canvas {
        property bool on: false
        width: 18; height: 10
        onOnChanged: requestPaint()
        onPaint: {
            const c = getContext("2d"); c.reset()
            c.strokeStyle = on ? d.hot : Theme.textFaint; c.fillStyle = c.strokeStyle; c.lineWidth = 1.5
            c.beginPath(); c.moveTo(1, 5); c.lineTo(width - 5, 5); c.stroke()
            c.beginPath(); c.moveTo(width - 1, 5); c.lineTo(width - 7, 1); c.lineTo(width - 7, 9); c.closePath(); c.fill()
        }
    }

    readonly property real nodeW: (width - 3 * 18 - 3 * 4) / 4
    Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        Node { width: d.nodeW; height: 54; on: true; title: qsTr("Genome"); sub: qsTr("%L1 genes").arg(d.genes) }
        Arrow { anchors.verticalCenter: parent.verticalCenter; on: true }
        Column {
            spacing: 4
            anchors.verticalCenter: parent.verticalCenter
            Node { width: d.nodeW; height: 34; on: d.craftEvolves; title: qsTr("Craft"); sub: d.craftEvolves ? qsTr("%1 design genes").arg(d.designGenes) : qsTr("fixed") }
            Node { width: d.nodeW; height: 34; on: d.brainEvolves || d.mode === "script"
                title: qsTr("Controller"); sub: d.mode === "script" ? qsTr("script genes") : d.brainEvolves ? qsTr("%1 → %2").arg(d.inputs).arg(d.outputs) : qsTr("script") }
        }
        Arrow { anchors.verticalCenter: parent.verticalCenter }
        Node { width: d.nodeW; height: 54; title: qsTr("Flight"); sub: qsTr("headless sim") }
        Arrow { anchors.verticalCenter: parent.verticalCenter }
        Node { width: d.nodeW; height: 54; title: qsTr("Fitness"); sub: qsTr("reward terms") }
    }
}
