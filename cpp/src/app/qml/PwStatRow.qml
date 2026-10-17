import QtQuick
import QtQuick.Layouts

// Label · value row with tabular digits; `warn` tints the value.
RowLayout {
    property string label
    property string value
    property bool warn: false
    property bool bad: false
    property string tip: ""
    Layout.fillWidth: true
    spacing: Theme.s2
    Text { text: parent.label; color: Theme.textMuted; font.pixelSize: Theme.caption; Layout.fillWidth: true; elide: Text.ElideRight }
    Text {
        text: parent.value
        color: parent.bad ? Theme.bad : parent.warn ? Theme.warn : Theme.text
        font.pixelSize: Theme.caption
        font.family: Theme.mono
        font.features: { "tnum": 1 }
    }
}
