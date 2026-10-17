import QtQuick
import QtQuick.Controls

// Compact numeric field: type a value or an expression ("1.2*2"), Return / focus-out commits, Esc reverts,
// ↑/↓ nudge by `step` (Shift x10, Alt x0.1) and commit immediately. Drag horizontally on the label to scrub.
TextField {
    id: f
    property real value: 0
    property real step: 0.01
    property int decimals: 3
    property real minimum: -1e9
    property real maximum: 1e9
    property string suffix: ""
    property string tip: ""
    signal committed(real value)
    implicitWidth: 64
    selectByMouse: true
    horizontalAlignment: TextInput.AlignRight
    font.family: Theme.mono
    font.pixelSize: Theme.small
    function show() { text = (+value).toFixed(decimals).replace(/\.?0+$/, "") || "0" }
    Component.onCompleted: show()
    onValueChanged: if (!activeFocus) show()
    onActiveFocusChanged: if (activeFocus) selectAll(); else commit()
    function clamp(v) { return Math.max(minimum, Math.min(maximum, v)) }
    function commit() {
        let v = Number(text)
        if (isNaN(v)) {
            // allow simple arithmetic; only digits, operators, dots, parentheses and spaces
            if (/^[\d\s+\-*/().eE]+$/.test(text)) { try { v = Function("return (" + text + ")")() } catch (e) { v = NaN } }
        }
        if (isNaN(v) || !isFinite(v)) { show(); return }
        v = clamp(v)
        if (Math.abs(v - value) > 1e-12) committed(v)
        show()
    }
    onAccepted: { commit(); selectAll() }
    Keys.onEscapePressed: (e) => { show(); f.focus = false; e.accepted = true }
    Keys.onUpPressed: (e) => nudge(e, 1)
    Keys.onDownPressed: (e) => nudge(e, -1)
    function nudge(e, dir) {
        const m = (e.modifiers & Qt.ShiftModifier) ? 10 : (e.modifiers & Qt.AltModifier) ? 0.1 : 1
        const v = clamp(Math.round((value + dir * step * m) / (step * (m < 1 ? 0.1 : 1))) * (step * (m < 1 ? 0.1 : 1)))
        committed(v); text = v.toFixed(decimals).replace(/\.?0+$/, "") || "0"; selectAll(); e.accepted = true
    }
    ToolTip.visible: hovered && tip !== "" && !activeFocus
    ToolTip.delay: Theme.tooltipDelay
    ToolTip.text: tip + "\n↑/↓ nudge (⇧ ×10, ⌥ ×0.1)"
}
