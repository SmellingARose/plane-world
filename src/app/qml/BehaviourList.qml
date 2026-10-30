import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// FLY › Behaviours: the evolved controllers the craft carries ("behaviours" in the craft JSON). Each row: on / off
// state, name, its key and a Fly / Take over button. Click the row or press its key to hand the craft's outputs to
// it (where the craft is); press the key again or move any stick to take control back. Only one flies at a time.
// The ⋯ menu renames, clears the key or removes it (undoable; saved with the craft). Key: click the keycap, press a key.
PwSection {
    id: sec
    title: App.behaviours.length > 0 ? qsTr("Behaviours (%1)").arg(App.behaviours.length) : qsTr("Behaviours")
    hint: qsTr("Evolved controllers this craft carries. Press a behaviour's key to let it fly; press it again or move a stick to take over.")
    expanded: App.behaviours.length > 0   // a craft without any shows just the header (open it for how to add one)
    property int renaming: -1
    property string keyError: ""
    property int keyErrorRow: -1

    PwCard {
        spacing: Theme.s1
        padding: Theme.s2
        Repeater {
            model: App.behaviours
            delegate: ColumnLayout {
                id: row
                required property var modelData
                required property int index
                readonly property bool active: modelData.active
                Layout.fillWidth: true
                spacing: 0

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: line.implicitHeight + Theme.s1 * 2
                    radius: Theme.radiusSmall
                    color: row.active ? Theme.alpha(Qt.lighter(Theme.tabTint["EVOLVE"], 1), Theme.dark ? 0.24 : 0.14) : rowMa.containsMouse ? Theme.hover : "transparent"
                    border.color: row.active ? Theme.alpha(Qt.lighter(Theme.tabTint["EVOLVE"], 1), 0.6) : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fast } }
                    MouseArea {
                        id: rowMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: App.toggleBehaviour(row.index)
                        ToolTip.visible: containsMouse && sec.renaming !== row.index
                        ToolTip.delay: Theme.tooltipDelay
                        ToolTip.text: row.modelData.info + "\n" + (row.active ? qsTr("Click to take over") : qsTr("Click to let it fly from here"))
                    }
                    RowLayout {
                        id: line
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Theme.s2; rightMargin: Theme.s1 }
                        spacing: Theme.s1
                        Rectangle {   // on / off
                            implicitWidth: 8; implicitHeight: 8; radius: 4
                            color: row.active ? Theme.good : "transparent"
                            border.color: row.active ? Theme.good : Theme.textFaint
                            border.width: 1.5
                            SequentialAnimation on opacity {
                                running: row.active; loops: Animation.Infinite
                                NumberAnimation { to: 0.35; duration: 600 } NumberAnimation { to: 1; duration: 600 }
                                onRunningChanged: if (!running) parent.opacity = 1
                            }
                        }
                        Label {
                            visible: sec.renaming !== row.index
                            Layout.fillWidth: true
                            text: row.modelData.name
                            elide: Text.ElideRight
                            font.pixelSize: Theme.small
                            font.weight: row.active ? Font.DemiBold : Font.Medium
                        }
                        TextField {
                            id: nameField
                            visible: sec.renaming === row.index
                            Layout.fillWidth: true
                            font.pixelSize: Theme.small
                            text: row.modelData.name
                            selectByMouse: true
                            onVisibleChanged: if (visible) { text = row.modelData.name; forceActiveFocus(); selectAll() }
                            onAccepted: { App.renameBehaviour(row.index, text); sec.renaming = -1 }
                            Keys.onEscapePressed: sec.renaming = -1
                            onActiveFocusChanged: if (!activeFocus && sec.renaming === row.index) { App.renameBehaviour(row.index, text); sec.renaming = -1 }
                        }
                        KeyCaptureButton {
                            keyName: row.modelData.key
                            role: qsTr("starts and stops %1").arg(row.modelData.name)
                            onCaptured: (name) => {
                                const why = App.setBehaviourKey(row.index, name)
                                sec.keyError = why; sec.keyErrorRow = why !== "" ? row.index : -1
                            }
                        }
                        TextMetrics { id: takeOverText; text: qsTr("Take over"); font.pixelSize: Theme.small }
                        Button {
                            Layout.preferredWidth: Math.ceil(takeOverText.width) + Theme.s6 + Theme.s2   // same width on and off (native padding)
                            text: row.active ? qsTr("Take over") : qsTr("Fly")
                            highlighted: row.active
                            font.pixelSize: Theme.small
                            focusPolicy: Qt.TabFocus
                            onClicked: App.toggleBehaviour(row.index)
                        }
                        PwIconButton {
                            text: "⋯"
                            tip: qsTr("Rename, change the key or remove")
                            onClicked: menu.popup()
                            Menu {
                                id: menu
                                MenuItem { text: qsTr("Rename…"); onTriggered: sec.renaming = row.index }
                                MenuItem { text: qsTr("Clear key"); enabled: row.modelData.key !== ""; onTriggered: App.setBehaviourKey(row.index, "") }
                                MenuSeparator {}
                                MenuItem { text: qsTr("Remove from craft"); onTriggered: App.removeBehaviour(row.index) }
                            }
                        }
                    }
                }
                Label {   // why the key doesn't work / can't be used
                    readonly property string msg: sec.keyErrorRow === row.index && sec.keyError !== "" ? sec.keyError + qsTr(" — pick another key")
                                                : row.modelData.conflict !== "" ? row.modelData.conflict + qsTr(", so this key won't start it — pick another") : ""
                    visible: msg !== ""
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.s2 + 8 + Theme.s1
                    text: msg
                    color: Theme.warn
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.caption
                }
            }
        }
        Label {
            visible: App.behaviours.length > 0
            Layout.fillWidth: true
            Layout.topMargin: Theme.s1
            wrapMode: Text.WordWrap
            color: Theme.textFaint
            font.pixelSize: Theme.caption
            text: App.activeBehaviour >= 0 ? qsTr("Move any stick, or press the key again, to take over.")
                                           : qsTr("Press a key or click a row to let it fly from where you are. Save the craft to keep changes.")
        }
        PwEmptyState {
            visible: App.behaviours.length === 0
            text: qsTr("No behaviours yet. Train one in EVOLVE (like Hover), then use “Add to craft as a behaviour” to fly it on a key.")
        }
    }
}
