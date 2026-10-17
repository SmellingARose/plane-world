import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Right-hand inspector. Each tab's panel is a QML file listed in `panelFiles` (BUILD / FLY: P5a, WORLD / EVOLVE: P5b
// add theirs); tabs without one show their keyboard map from `sections`.
Rectangle {
    id: root
    property string tab: "BUILD"
    property var sections: []
    property var panelFiles: ({ "BUILD": "BuildPanel.qml", "FLY": "FlyPanel.qml" })
    readonly property alias panel: loader.item
    function scrollTo(item) { if (item) scroll.contentItem.contentY = Math.max(0, item.mapToItem(col, 0, 0).y - Theme.s2) }
    color: Theme.surface

    Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.separator; z: 2 }

    ScrollView {
        id: scroll
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ColumnLayout {
            id: col
            width: scroll.availableWidth
            spacing: Theme.s3
            Item { implicitHeight: Theme.s1 }
            Loader {
                id: loader
                Layout.fillWidth: true
                Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                active: !!root.panelFiles[root.tab]
                source: active ? root.panelFiles[root.tab] : ""
                opacity: status === Loader.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.normal; easing.type: Theme.easing } }
            }
            // fallback: keyboard map for tabs without a panel yet
            Repeater {
                model: loader.active ? [] : root.sections
                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                    spacing: Theme.s2
                    Label { text: modelData.title.toUpperCase(); color: Theme.textFaint; font.pixelSize: Theme.caption; font.letterSpacing: 0.8 }
                    Repeater {
                        model: modelData.rows
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: Theme.s2
                            Label { text: modelData[0]; Layout.fillWidth: true; elide: Text.ElideRight }
                            KeyHint { sequence: modelData[1]; visible: modelData[1] !== "" }
                        }
                    }
                }
            }
            Item { implicitHeight: Theme.s5 }
        }
    }
}
