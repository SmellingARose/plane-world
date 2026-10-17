import QtQuick
import QtQuick.Controls

// Native tool button whose tooltip always carries the shortcut. `shortcut` is display-only (bind the action
// with a Shortcut / the command list so it works when the button is hidden).
ToolButton {
    id: b
    property string tip
    property string shortcut: ""
    focusPolicy: Qt.TabFocus
    font.pixelSize: Theme.small
    ToolTip.visible: hovered && (tip !== "" || shortcut !== "")
    ToolTip.delay: Theme.tooltipDelay
    ToolTip.text: Theme.tip(tip || text, shortcut)
}
