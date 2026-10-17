import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Flat tab strip used for the main tabs and inspector sub-pages. Replaces the stock TabBar, whose macOS style
// paints inactive tabs as grey slabs with white text (low contrast, reads as disabled). Keyboard: Tab focuses
// the strip, ←/→ move, Home/End jump. Active tab gets a tinted underline; `tints` maps label → colour.
FocusScope {
    id: bar
    property var model: []                 // labels
    property var badges: []                // optional trailing text per tab ("●", "12")
    property var tints: ({})
    property var tips: []
    property int currentIndex: 0
    property real fontSize: Theme.body
    property bool fill: false              // stretch tabs to full width
    implicitHeight: row.implicitHeight
    implicitWidth: row.implicitWidth
    activeFocusOnTab: true
    Keys.onLeftPressed: currentIndex = Math.max(0, currentIndex - 1)
    Keys.onRightPressed: currentIndex = Math.min(model.length - 1, currentIndex + 1)
    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Home) { currentIndex = 0; e.accepted = true }
        else if (e.key === Qt.Key_End) { currentIndex = model.length - 1; e.accepted = true }
    }
    RowLayout {
        id: row
        anchors.fill: parent
        spacing: Theme.s1
        Repeater {
            model: bar.model
            delegate: Item {
                id: tab
                required property string modelData
                required property int index
                readonly property bool active: index === bar.currentIndex
                readonly property color tint: bar.tints[modelData] || Theme.accent
                Layout.fillWidth: bar.fill
                Layout.preferredWidth: bar.fill ? 1 : lbl.implicitWidth + Theme.s4 * 2
                Layout.fillHeight: true
                implicitHeight: lbl.implicitHeight + Theme.s2 * 2
                Rectangle {
                    anchors.fill: parent; anchors.margins: 2
                    radius: Theme.radiusSmall
                    color: ma.pressed ? Theme.separator : ma.containsMouse && !tab.active ? Theme.hover : "transparent"
                    border.width: bar.activeFocus && tab.active ? 2 : 0
                    border.color: Theme.accent
                    Behavior on color { ColorAnimation { duration: Theme.fast } }
                }
                Text {
                    id: lbl
                    anchors.centerIn: parent
                    text: tab.modelData + (bar.badges[tab.index] ? "  " + bar.badges[tab.index] : "")
                    color: tab.active ? Theme.text : Theme.textMuted
                    font.pixelSize: bar.fontSize
                    font.weight: tab.active ? Font.DemiBold : Font.Normal
                    font.letterSpacing: 0.3
                }
                Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: 2; radius: 1
                    width: tab.active ? parent.width - Theme.s3 * 2 : 0
                    color: tab.tint
                    Behavior on width { NumberAnimation { duration: Theme.normal; easing.type: Theme.easing } }
                }
                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: bar.currentIndex = tab.index
                }
                ToolTip.visible: ma.containsMouse && !!bar.tips[index]
                ToolTip.delay: Theme.tooltipDelay
                ToolTip.text: bar.tips[index] || ""
            }
        }
    }
}
