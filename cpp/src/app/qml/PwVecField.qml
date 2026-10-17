import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Labelled x / y / z row of number fields with axis colour ticks. Emits committed(axis, value).
RowLayout {
    id: v
    property string label
    property var value: [0, 0, 0]
    property real step: 0.01
    property int decimals: 3
    property string tip: ""
    signal committed(int axis, real value)
    Layout.fillWidth: true
    spacing: Theme.s1
    Label { text: v.label; color: Theme.textMuted; font.pixelSize: Theme.small; Layout.preferredWidth: Theme.labelColumn - Theme.s5; elide: Text.ElideRight }
    Repeater {
        model: 3
        RowLayout {
            required property int index
            spacing: 2
            Layout.fillWidth: true
            Rectangle { width: 3; height: 14; radius: 1.5; color: [Theme.axisX, Theme.axisY, Theme.axisZ][index] }
            PwNumberField {
                Layout.fillWidth: true
                implicitWidth: 52
                value: v.value && v.value.length > index ? v.value[index] : 0
                step: v.step; decimals: v.decimals
                tip: v.tip ? v.tip + " " + "XYZ"[index] : ""
                onCommitted: (x) => v.committed(index, x)
            }
        }
    }
}
