import QtQuick
import QtQuick.Controls

// Keycap button that captures the next key press as an output binding. Click (or Space / Return when focused),
// then press a key; Esc clears, Tab / clicking away cancels. While listening the FLY key handler ignores input
// (pwKeyCapture), so a key already bound elsewhere can be captured.
Button {
    id: cap
    property string keyName: ""             // current binding ("a", "up", "space", ...)
    property bool listening: false
    property bool pwKeyCapture: listening
    property string role: ""                // tooltip context, e.g. "pushes Elevator up"
    signal captured(string name)
    implicitWidth: Math.max(44, contentItem.implicitWidth + Theme.s3)
    font.family: listening ? Theme.baseFont.family : Theme.mono
    font.pixelSize: Theme.small
    text: listening ? "press…" : (keyName === "" ? "·" : App.keyDisplay(keyName))
    highlighted: listening
    focusPolicy: Qt.StrongFocus
    onClicked: { listening = !listening; if (listening) forceActiveFocus() }
    onActiveFocusChanged: if (!activeFocus) listening = false
    Keys.onPressed: (e) => {
        if (!listening) {
            if (e.key === Qt.Key_Space || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { listening = true; e.accepted = true }
            return
        }
        if (e.key === Qt.Key_Shift || e.key === Qt.Key_Control || e.key === Qt.Key_Alt || e.key === Qt.Key_Meta) return
        if (e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab) { listening = false; return }
        e.accepted = true
        if (e.key === Qt.Key_Escape || e.key === Qt.Key_Backspace || e.key === Qt.Key_Delete) { listening = false; captured(""); return }
        const n = App.keyName(e.key, e.text)
        if (n !== "") { listening = false; captured(n) }
    }
    SequentialAnimation on opacity {
        running: cap.listening; loops: Animation.Infinite
        NumberAnimation { to: 0.55; duration: 420 } NumberAnimation { to: 1; duration: 420 }
        onRunningChanged: if (!running) cap.opacity = 1
    }
    ToolTip.visible: hovered && !listening
    ToolTip.delay: Theme.tooltipDelay
    ToolTip.text: (role !== "" ? "Key that " + role + "\n" : "") + "Click, then press a key · Esc clears"
}
