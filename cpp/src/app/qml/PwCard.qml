import QtQuick
import QtQuick.Layouts

// Rounded group box for a section's controls (Swift Card).
Rectangle {
    id: card
    default property alias content: col.data
    property alias spacing: col.spacing
    property int padding: Theme.s3
    Layout.fillWidth: true
    implicitHeight: col.implicitHeight + padding * 2
    implicitWidth: col.implicitWidth + padding * 2
    radius: Theme.radius
    color: Theme.card
    border.color: Theme.separator
    border.width: Theme.hairline
    ColumnLayout {
        id: col
        x: card.padding; y: card.padding
        width: card.width - card.padding * 2
        spacing: Theme.s2
    }
}
