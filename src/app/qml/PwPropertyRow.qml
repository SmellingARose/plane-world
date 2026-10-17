import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Inspector row: fixed-width muted label + the editor (default child) filling the rest.
RowLayout {
    id: r
    property string label
    property string tip: ""
    default property alias editor: slot.data
    Layout.fillWidth: true
    spacing: Theme.s2
    Label {
        text: r.label
        color: Theme.textMuted
        font.pixelSize: Theme.small
        Layout.preferredWidth: Theme.labelColumn - Theme.s5
        elide: Text.ElideRight
        HoverHandler { id: hh }
        ToolTip.visible: hh.hovered && r.tip !== ""
        ToolTip.delay: Theme.tooltipDelay
        ToolTip.text: r.tip
    }
    Item {
        id: slot
        Layout.fillWidth: true
        implicitHeight: children.length > 0 ? children[0].implicitHeight : 0
        onChildrenChanged: { for (let i = 0; i < children.length; ++i) children[i].width = Qt.binding(() => slot.width) }
    }
}
