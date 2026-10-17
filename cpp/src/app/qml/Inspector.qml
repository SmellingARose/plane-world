import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Right-hand inspector. Phase 0 shows what each tab will hold and its keyboard map; the real editors land in phase 5.
Rectangle {
    id: root
    property string tab: "BUILD"
    property var sections: []
    color: Theme.surface

    Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.separator }

    Flickable {
        anchors.fill: parent
        anchors.margins: Theme.s4
        contentHeight: col.implicitHeight
        clip: true
        ScrollBar.vertical: ScrollBar {}
        ColumnLayout {
            id: col
            width: parent.width
            spacing: Theme.s4
            RowLayout {
                spacing: Theme.s2
                Rectangle { width: 4; Layout.fillHeight: true; radius: 2; color: Theme.tabTint[root.tab] }
                ColumnLayout {
                    spacing: 2
                    Label { text: root.tab; font.pixelSize: Theme.title; font.weight: Font.DemiBold }
                    Label { text: "Inspector"; color: Theme.textMuted; font.pixelSize: Theme.caption }
                }
            }
            Repeater {
                model: root.sections
                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
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
            Label {
                Layout.fillWidth: true
                Layout.topMargin: Theme.s3
                wrapMode: Text.WordWrap
                color: Theme.textFaint
                font.pixelSize: Theme.caption
                text: "C++ port, phase 0. Editors arrive in phase 5; the Swift app remains the shipping version."
            }
        }
    }
}
