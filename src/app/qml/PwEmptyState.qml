import QtQuick
import QtQuick.Layouts

// Quiet placeholder for empty lists: title, explanation and an optional keyboard hint.
ColumnLayout {
    property string title
    property string text
    property string shortcut: ""
    property string shortcutLabel: ""
    Layout.fillWidth: true
    spacing: Theme.s1
    Text { text: parent.title; color: Theme.textMuted; font.pixelSize: Theme.small; font.weight: Font.DemiBold; visible: text !== "" }
    Text { text: parent.text; color: Theme.textFaint; font.pixelSize: Theme.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true }
    Row {
        visible: parent.shortcut !== ""
        spacing: Theme.s1
        KeyHint { sequence: parent.parent.shortcut }
        Text { text: parent.parent.shortcutLabel; color: Theme.textFaint; font.pixelSize: Theme.caption; anchors.verticalCenter: parent.verticalCenter }
    }
}
