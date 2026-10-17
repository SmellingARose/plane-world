import QtQuick
import QtQuick.Layouts

// Window-wide drop target for CAD files and craft JSON. While dragging it shows two zones: the left half imports
// as a new craft, the right half adds the parts to the current craft. Drops switch to BUILD.
DropArea {
    id: drop
    signal fileDropped()
    keys: ["text/uri-list"]
    property bool intoCurrent: drag.x > width / 2
    onDropped: (e) => {
        if (!e.hasUrls) return
        drop.fileDropped()
        App.importFiles(e.urls, intoCurrent)
        e.acceptProposedAction()
    }
    Rectangle {
        anchors.fill: parent
        color: Theme.overlay
        opacity: drop.containsDrag ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
        RowLayout {
            anchors.fill: parent
            anchors.margins: Theme.s6
            spacing: Theme.s4
            Repeater {
                model: [{ t: "New craft", s: "Import the assembly as a new craft" + (App.autoRigOnImport ? " and auto-rig it" : "") },
                        { t: "Add to " + App.craftName, s: "Append the parts to the current craft" }]
                Rectangle {
                    required property var modelData
                    required property int index
                    readonly property bool hot: (index === 1) === drop.intoCurrent
                    Layout.fillWidth: true; Layout.fillHeight: true
                    radius: Theme.radiusLarge
                    color: hot ? Theme.alpha(Theme.accent, 0.28) : Theme.alpha(Theme.surfaceRaised, 0.25)
                    border.color: hot ? Theme.accent : Theme.alpha("#ffffff", 0.35)
                    border.width: 2
                    Behavior on color { ColorAnimation { duration: Theme.fast } }
                    Column {
                        anchors.centerIn: parent
                        spacing: Theme.s2
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.t; color: "white"; font.pixelSize: Theme.display; font.weight: Font.DemiBold }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.s; color: Qt.rgba(1, 1, 1, 0.8); font.pixelSize: Theme.body }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: App.cadExtensions.join(" · ") + " · json"; color: Qt.rgba(1, 1, 1, 0.55); font.pixelSize: Theme.caption }
                    }
                }
            }
        }
    }
}
