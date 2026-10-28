pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "EvolveAlgorithms.js" as Algos

// "Compare all" for EVOLVE step ④: every optimiser in one table (best for, how many genes it handles, whether it
// tunes its own step size). Wider than the inspector, centred over the window; clicking a row chooses that method.
Popup {
    id: pop
    property string current
    property string recommended
    property var kinds: []
    signal chosen(string kind)
    readonly property int nameWidth: 128
    readonly property int genesWidth: 56
    readonly property int stepWidth: 84
    parent: Overlay.overlay
    modal: true
    dim: true
    focus: true
    width: Math.min(parent ? parent.width - Theme.s6 : 600, 600)
    height: Math.min(parent ? parent.height - Theme.s6 * 2 : 600, body.implicitHeight + padding * 2)
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: Theme.s4
    background: Rectangle { color: Theme.surfaceRaised; radius: Theme.radiusLarge; border.color: Theme.separator; border.width: Theme.hairline }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ColumnLayout {
            id: body
            width: parent.width
            spacing: Theme.s2
            RowLayout {
                Layout.fillWidth: true
                Label { text: qsTr("Compare search methods"); font.pixelSize: Theme.title; font.weight: Font.DemiBold; Layout.fillWidth: true }
                ToolButton { text: "✕"; onClicked: pop.close(); ToolTip.visible: hovered; ToolTip.text: qsTr("Close (Esc)") }
            }
            Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.textMuted; font.pixelSize: Theme.caption
                text: qsTr("Not sure? Keep the recommended one: its defaults work. Click a row to use that method; ⓘ on its card in the panel explains it in full.") }
            // header
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.s1
                Layout.leftMargin: Theme.s1; Layout.rightMargin: Theme.s1
                spacing: Theme.s2
                Head { text: qsTr("Method"); Layout.preferredWidth: pop.nameWidth; Layout.maximumWidth: pop.nameWidth; Layout.minimumWidth: pop.nameWidth }
                Head { text: qsTr("What it does · best for"); Layout.fillWidth: true; Layout.preferredWidth: 0 }
                Head { text: qsTr("Genes"); Layout.preferredWidth: pop.genesWidth; Layout.maximumWidth: pop.genesWidth; Layout.minimumWidth: pop.genesWidth }
                Head { text: qsTr("Step size"); Layout.preferredWidth: pop.stepWidth; Layout.maximumWidth: pop.stepWidth; Layout.minimumWidth: pop.stepWidth }
            }
            Rectangle { Layout.fillWidth: true; implicitHeight: Theme.hairline; color: Theme.separator }
            Repeater {
                model: pop.kinds
                delegate: Rectangle {
                    id: row
                    required property string modelData
                    readonly property var info: Algos.info(modelData)
                    readonly property bool isCurrent: modelData === pop.current
                    Layout.fillWidth: true
                    implicitHeight: cells.implicitHeight + Theme.s2 * 2
                    radius: Theme.radiusSmall
                    color: isCurrent ? Theme.accentSoft : rh.hovered ? Theme.hover : "transparent"
                    HoverHandler { id: rh; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { pop.chosen(row.modelData); pop.close() } }
                    RowLayout {
                        id: cells
                        x: Theme.s1; y: Theme.s2
                        width: row.width - Theme.s1 * 2
                        spacing: Theme.s2
                        ColumnLayout {
                            Layout.preferredWidth: pop.nameWidth; Layout.maximumWidth: pop.nameWidth; Layout.minimumWidth: pop.nameWidth
                            Layout.alignment: Qt.AlignTop
                            spacing: 0
                            Label { text: row.info.name; font.weight: Font.DemiBold; font.pixelSize: Theme.small; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                            Label { text: row.isCurrent ? qsTr("in use") : row.modelData === pop.recommended ? qsTr("recommended") : row.modelData
                                color: row.isCurrent ? Theme.text : row.modelData === pop.recommended ? Theme.good : Theme.textFaint
                                font.pixelSize: Theme.micro; font.family: row.isCurrent || row.modelData === pop.recommended ? Theme.baseFont.family : Theme.mono }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.preferredWidth: 0          // take what the fixed columns leave; text wraps
                            Layout.alignment: Qt.AlignTop
                            spacing: 1
                            Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; text: row.info.tagline }
                            Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.textMuted
                                visible: row.info.bestFor !== ""; text: qsTr("Best for: %1").arg(row.info.bestFor) }
                        }
                        Label { Layout.preferredWidth: pop.genesWidth; Layout.maximumWidth: pop.genesWidth; Layout.minimumWidth: pop.genesWidth; Layout.alignment: Qt.AlignTop; font.pixelSize: Theme.caption; text: row.info.genes; wrapMode: Text.WordWrap }
                        Label { Layout.preferredWidth: pop.stepWidth; Layout.maximumWidth: pop.stepWidth; Layout.minimumWidth: pop.stepWidth; Layout.alignment: Qt.AlignTop; font.pixelSize: Theme.caption; text: row.info.step; wrapMode: Text.WordWrap
                            color: row.info.step === qsTr("adapts") ? Theme.good : Theme.text }
                    }
                }
            }
            Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.textFaint; font.pixelSize: Theme.micro; Layout.topMargin: Theme.s1
                text: qsTr("Genes: roughly how many genes (network weights, design values) it handles well. Step size: whether the method tunes its own mutation size as it goes (\"adapts\") or keeps what you set (\"fixed\").") }
        }
    }

    component Head: Label { color: Theme.textFaint; font.pixelSize: Theme.micro; font.weight: Font.DemiBold; font.letterSpacing: Theme.sectionTracking }
}
