import QtQuick

// Keycap showing a shortcut in the platform's notation. `hud` = light-on-dark for viewport overlays;
// `active` lights it up (held keys in FLY).
Rectangle {
    id: cap
    property string sequence
    property bool hud: false
    property bool active: false
    property bool raw: false                     // show `sequence` verbatim (key names like "↑", "Space")
    implicitWidth: Math.max(implicitHeight, label.implicitWidth + Theme.s2 + 2)
    implicitHeight: label.implicitHeight + Theme.s0 * 2
    radius: Theme.radiusSmall - 1
    color: active ? Theme.accent : (hud ? Qt.rgba(1, 1, 1, 0.08) : Theme.alpha(Theme.text, 0.05))
    border.color: active ? Theme.accent : (hud ? Qt.rgba(1, 1, 1, 0.28) : Theme.separator)
    Behavior on color { ColorAnimation { duration: Theme.fast } }
    Text {
        id: label
        anchors.centerIn: parent
        text: cap.raw ? cap.sequence : Theme.shortcutText(cap.sequence)
        color: cap.active ? Theme.accentText : (cap.hud ? Theme.hudText : Theme.textMuted)
        font.pixelSize: Theme.micro + 1
        font.weight: Font.DemiBold
    }
}
