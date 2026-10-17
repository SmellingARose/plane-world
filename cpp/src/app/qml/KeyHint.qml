import QtQuick

// Small keycap showing a shortcut in the platform's notation.
Rectangle {
    property string sequence
    implicitWidth: label.implicitWidth + Theme.s2 * 1.5
    implicitHeight: label.implicitHeight + Theme.s1
    radius: Theme.radiusSmall
    color: "transparent"
    border.color: Theme.separator
    Text {
        id: label
        anchors.centerIn: parent
        text: Theme.shortcutText(parent.sequence)
        color: Theme.textMuted
        font.pixelSize: Theme.caption
    }
}
