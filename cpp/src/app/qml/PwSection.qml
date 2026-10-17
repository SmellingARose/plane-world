import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Inspector section: small-caps header (click or Return/Space to collapse) + content column.
// Usage: PwSection { title: "Outputs"; trailing: Label {...}; ColumnLayout-children... }
ColumnLayout {
    id: sec
    property string title
    property bool collapsible: true
    property bool expanded: true
    property string hint: ""                 // tooltip on the header
    property alias trailing: trailingSlot.data
    default property alias content: body.data
    spacing: Theme.s2
    Layout.fillWidth: true

    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Theme.s1
        spacing: Theme.s1
        Item {
            id: header
            Layout.fillWidth: true
            implicitHeight: hdr.implicitHeight + Theme.s1
            activeFocusOnTab: sec.collapsible
            Keys.onReturnPressed: if (sec.collapsible) sec.expanded = !sec.expanded
            Keys.onSpacePressed: if (sec.collapsible) sec.expanded = !sec.expanded
            Row {
                id: hdr
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.s1
                Text {
                    visible: sec.collapsible
                    text: "›"
                    color: Theme.textFaint
                    font.pixelSize: Theme.caption + 2
                    rotation: sec.expanded ? 90 : 0
                    Behavior on rotation { NumberAnimation { duration: Theme.fast; easing.type: Theme.easing } }
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: sec.title.toUpperCase()
                    color: header.activeFocus ? Theme.accent : Theme.textMuted
                    font.pixelSize: Theme.micro + 1
                    font.weight: Font.DemiBold
                    font.letterSpacing: Theme.sectionTracking
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            MouseArea {
                anchors.fill: parent
                enabled: sec.collapsible
                cursorShape: Qt.PointingHandCursor
                hoverEnabled: true
                onClicked: sec.expanded = !sec.expanded
                ToolTip.visible: containsMouse && sec.hint !== ""
                ToolTip.delay: Theme.tooltipDelay
                ToolTip.text: sec.hint
            }
        }
        Row { id: trailingSlot; spacing: Theme.s1; Layout.alignment: Qt.AlignVCenter }
    }
    ColumnLayout {
        id: body
        Layout.fillWidth: true
        spacing: Theme.s2
        visible: sec.expanded
        opacity: sec.expanded ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
    }
}
