import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Labelled slider: label left, live value right, native slider below. Double-click resets to `defaultValue`;
// arrow keys step by `step` (Shift = x10). Emits `moved(value)` while dragging and `committed(value)` on release
// (so undo records one step per drag).
ColumnLayout {
    id: ls
    property string label
    property real from: 0
    property real to: 1
    property real value: 0
    property real step: 0
    property real defaultValue: NaN
    property int decimals: 2
    property string unit: ""
    property string tip: ""
    property var format: null                    // optional function(value) -> string
    signal moved(real value)
    signal committed(real value)
    spacing: 0
    Layout.fillWidth: true

    RowLayout {
        Layout.fillWidth: true
        Label { text: ls.label; font.pixelSize: Theme.small; color: Theme.textMuted; Layout.fillWidth: true; elide: Text.ElideRight }
        Label {
            text: ls.format ? ls.format(slider.value) : slider.value.toFixed(ls.decimals) + (ls.unit ? " " + ls.unit : "")
            font.pixelSize: Theme.small; font.family: Theme.mono
        }
    }
    Slider {
        id: slider
        Layout.fillWidth: true
        from: ls.from; to: ls.to
        stepSize: ls.step
        value: ls.value
        live: true
        onMoved: ls.moved(value)
        onPressedChanged: if (!pressed) ls.committed(value)
        Keys.onPressed: (e) => {
            const s = (ls.step > 0 ? ls.step : (ls.to - ls.from) / 100) * ((e.modifiers & Qt.ShiftModifier) ? 10 : 1)
            let v = value
            if (e.key === Qt.Key_Left || e.key === Qt.Key_Down) v -= s
            else if (e.key === Qt.Key_Right || e.key === Qt.Key_Up) v += s
            else if (e.key === Qt.Key_Home) v = ls.from
            else if (e.key === Qt.Key_End) v = ls.to
            else return
            v = Math.max(ls.from, Math.min(ls.to, v))
            value = v; ls.moved(v); ls.committed(v); e.accepted = true
        }
        TapHandler {
            acceptedButtons: Qt.LeftButton
            onDoubleTapped: if (!isNaN(ls.defaultValue)) { slider.value = ls.defaultValue; ls.moved(ls.defaultValue); ls.committed(ls.defaultValue) }
        }
        ToolTip.visible: hovered && ls.tip !== ""
        ToolTip.delay: Theme.tooltipDelay
        ToolTip.text: ls.tip + (isNaN(ls.defaultValue) ? "" : "\nDouble-click to reset")
    }
}
