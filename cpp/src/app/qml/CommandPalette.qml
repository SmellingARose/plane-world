import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// ⌘K / Ctrl+K command palette: type to filter, ↑/↓ to move, Return to run, Esc to close.
Popup {
    id: pal
    property var commands: []          // [{ name, shortcut, run: function }]
    property var filtered: []
    modal: true
    focus: true
    dim: true
    padding: 0
    width: Math.min(560, parent ? parent.width - Theme.s6 * 2 : 560)
    x: parent ? (parent.width - width) / 2 : 0
    y: parent ? parent.height * 0.16 : 0
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    Overlay.modal: Rectangle { color: Theme.overlay; Behavior on opacity { NumberAnimation { duration: Theme.fast } } }
    enter: Transition { ParallelAnimation {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.fast; easing.type: Theme.easing }
        NumberAnimation { property: "scale"; from: 0.97; to: 1; duration: Theme.normal; easing.type: Theme.easing } } }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: Theme.fast } }

    function refilter() {
        const q = field.text.toLowerCase().trim()
        filtered = commands.filter(c => q === "" || fuzzy(c.name.toLowerCase(), q))
        list.currentIndex = filtered.length > 0 ? 0 : -1
    }
    function fuzzy(s, q) { let i = 0; for (const ch of s) { if (ch === q[i]) i++; if (i === q.length) return true } return i === q.length }
    function runCurrent() {
        if (list.currentIndex < 0) return
        const c = filtered[list.currentIndex]
        close()
        c.run()
    }
    onAboutToShow: { field.text = ""; refilter(); field.forceActiveFocus() }

    background: Rectangle {
        radius: Theme.radius + 2
        color: Theme.surfaceRaised
        border.color: Theme.separator
    }

    contentItem: ColumnLayout {
        spacing: 0
        TextField {
            id: field
            Layout.fillWidth: true
            Layout.margins: Theme.s3
            placeholderText: "Type a command…"
            onTextChanged: pal.refilter()
            Keys.onDownPressed: list.incrementCurrentIndex()
            Keys.onUpPressed: list.decrementCurrentIndex()
            Keys.onReturnPressed: pal.runCurrent()
            Keys.onEnterPressed: pal.runCurrent()
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, 340)
            Layout.margins: Theme.s1
            clip: true
            model: pal.filtered
            highlightMoveDuration: Theme.fast
            highlight: Rectangle { radius: Theme.radiusSmall; color: Theme.accent }
            delegate: Item {
                required property var modelData
                required property int index
                width: ListView.view.width
                height: row.implicitHeight + Theme.s2 * 2
                RowLayout {
                    id: row
                    anchors.fill: parent
                    anchors.leftMargin: Theme.s3; anchors.rightMargin: Theme.s3
                    Label { text: modelData.name; Layout.fillWidth: true
                        color: index === list.currentIndex ? Theme.accentText : Theme.text }
                    Label { text: Theme.shortcutText(modelData.shortcut || ""); font.pixelSize: Theme.caption
                        color: index === list.currentIndex ? Theme.accentText : Theme.textMuted }
                }
                MouseArea { anchors.fill: parent; hoverEnabled: true
                    onEntered: list.currentIndex = index
                    onClicked: { list.currentIndex = index; pal.runCurrent() } }
            }
        }
        Label {
            Layout.margins: Theme.s3
            visible: pal.filtered.length === 0
            text: "No matching commands"
            color: Theme.textMuted
        }
    }
}
