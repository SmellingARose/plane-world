import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// JavaScript editor: line-number gutter with the error marker, syntax colouring (JsHighlighter), current-line
// highlight, auto-indent on Return, Tab / Shift+Tab (un)indent, Ctrl+/ toggles comments, Ctrl+Return checks.
// Edits are pushed to EvolveModel after a short idle so typing never stalls.
Rectangle {
    id: ed
    property alias text: area.text
    property int errorLine: 0
    property string errorMessage: ""
    signal edited(string text)
    signal checkRequested()
    color: Theme.surfaceSunken
    radius: Theme.radiusSmall
    border.color: area.activeFocus ? Theme.accent : Theme.separator
    border.width: area.activeFocus ? 1.5 : 1

    function goToLine(line) {
        area.cursorPosition = jsTools.lineStart(area.text, line)
        area.forceActiveFocus()
        const y = (line - 1) * lineHeight
        if (y < flick.contentY || y > flick.contentY + flick.height - lineHeight) flick.contentY = Math.max(0, y - flick.height / 3)
    }
    readonly property real lineHeight: metrics.height
    FontMetrics { id: metrics; font: area.font }

    Timer { id: push; interval: 350; onTriggered: ed.edited(area.text) }

    RowLayout {
        anchors.fill: parent
        anchors.margins: 1
        spacing: 0

        // gutter
        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: gutterCol.width + Theme.s2 * 2
            color: Theme.alpha(Theme.text, 0.03)
            clip: true
            Column {
                id: gutterCol
                y: area.topPadding - flick.contentY
                x: Theme.s2
                width: Math.max(2, String(area.lineCount).length) * metrics.averageCharacterWidth + 12
                Repeater {
                    model: area.lineCount
                    Item {
                        required property int index
                        width: gutterCol.width; height: ed.lineHeight
                        readonly property bool err: index + 1 === ed.errorLine
                        Rectangle { visible: parent.err; anchors.verticalCenter: parent.verticalCenter; x: 0; width: 8; height: 8; radius: 4; color: Theme.bad
                            ToolTip.visible: errHover.hovered; ToolTip.text: ed.errorMessage
                            HoverHandler { id: errHover } }
                        Text {
                            anchors.right: parent.right
                            text: index + 1
                            color: parent.err ? Theme.bad : Theme.textFaint
                            font.family: Theme.mono; font.pixelSize: area.font.pixelSize
                        }
                    }
                }
            }
        }

        Flickable {
            id: flick
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: Math.max(width, area.contentWidth + area.leftPadding + area.rightPadding)
            contentHeight: area.contentHeight + area.topPadding + area.bottomPadding
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            ScrollBar.horizontal: ScrollBar {}
            function ensureVisible(r) {
                if (contentX >= r.x) contentX = r.x
                else if (contentX + width <= r.x + r.width) contentX = r.x + r.width - width
                if (contentY >= r.y) contentY = r.y
                else if (contentY + height <= r.y + r.height + area.bottomPadding) contentY = r.y + r.height + area.bottomPadding - height
            }

            // current line + error line backgrounds
            Rectangle {
                y: area.topPadding + (ed.errorLine - 1) * ed.lineHeight
                width: flick.contentWidth; height: ed.lineHeight
                visible: ed.errorLine > 0
                color: Theme.alpha(Theme.bad, 0.12)
            }
            Rectangle {
                y: area.cursorRectangle.y
                width: flick.contentWidth; height: area.cursorRectangle.height
                visible: area.activeFocus
                color: Theme.alpha(Theme.text, 0.05)
            }

            TextEdit {
                id: area
                width: flick.width
                leftPadding: Theme.s2; topPadding: Theme.s2; rightPadding: Theme.s2; bottomPadding: Theme.s2
                font.family: Theme.mono
                font.pixelSize: Math.round(Theme.body * 0.95)
                color: Theme.text
                selectionColor: Theme.accentSoft
                selectedTextColor: Theme.text
                selectByMouse: true
                persistentSelection: true
                wrapMode: TextEdit.NoWrap
                tabStopDistance: metrics.averageCharacterWidth * 4
                onCursorRectangleChanged: flick.ensureVisible(cursorRectangle)
                onTextChanged: if (activeFocus) push.restart()
                onActiveFocusChanged: if (!activeFocus && push.running) { push.stop(); ed.edited(text) }

                function replaceAll(t, s, e) { const sy = flick.contentY; area.text = t; area.select(s, e); flick.contentY = sy; push.restart() }
                Keys.onPressed: (ev) => {
                    if (ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter) {
                        if (ev.modifiers & Qt.ControlModifier) { push.stop(); ed.edited(text); ed.checkRequested(); ev.accepted = true; return }
                        const ins = jsTools.newlineIndent(text, cursorPosition)
                        area.remove(selectionStart, selectionEnd)
                        area.insert(cursorPosition, ins)
                        ev.accepted = true
                    } else if (ev.key === Qt.Key_Tab && !(ev.modifiers & Qt.ShiftModifier)) {
                        if (selectionStart !== selectionEnd) { const r = jsTools.transformLines(text, selectionStart, selectionEnd, "indent"); replaceAll(r.text, r.start, r.end) }
                        else area.insert(cursorPosition, "    ")
                        ev.accepted = true
                    } else if (ev.key === Qt.Key_Backtab || (ev.key === Qt.Key_Tab && (ev.modifiers & Qt.ShiftModifier))) {
                        const r = jsTools.transformLines(text, selectionStart, selectionEnd, "unindent"); replaceAll(r.text, r.start, r.end)
                        ev.accepted = true
                    } else if (ev.key === Qt.Key_Slash && (ev.modifiers & Qt.ControlModifier)) {
                        const r = jsTools.transformLines(text, selectionStart, selectionEnd, "comment"); replaceAll(r.text, r.start, r.end)
                        ev.accepted = true
                    } else if (ev.key === Qt.Key_BraceRight) {
                        // dedent a lone closing brace
                        const ls = text.lastIndexOf("\n", cursorPosition - 1) + 1
                        const before = text.substring(ls, cursorPosition)
                        if (/^\s+$/.test(before) && before.length >= 4) area.remove(cursorPosition - 4, cursorPosition)
                    }
                }
            }
            JsHighlighter {
                id: jsTools
                document: area.textDocument
                errorLine: ed.errorLine
                keywordColor: Theme.dark ? "#c792ea" : "#8839ef"
                stringColor: Theme.dark ? "#a5d6a7" : "#2e7d32"
                numberColor: Theme.dark ? "#f2a65a" : "#b5520a"
                commentColor: Theme.textFaint
                functionColor: Theme.dark ? "#82aaff" : "#1e66f5"
                hookColor: Theme.dark ? "#ffcb6b" : "#a0610b"
                errorColor: Theme.bad
            }
        }
    }
}
