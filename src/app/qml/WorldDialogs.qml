import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

// The dialogs behind WorldFlow: name the world when saving, ask before unsaved edits are lost, and the saved-worlds
// manager (open, delete, browse for a file elsewhere). One instance lives in Main's overlay.
Item {
    id: dlgs
    anchors.fill: parent
    property var pendingAction: null   // what to do after the unsaved-changes question or a save

    Connections {
        target: WorldFlow
        function onSaveNameRequested(after) { nameDlg.after = after; nameDlg.open() }
        function onUnsavedCheckRequested(action) { dlgs.pendingAction = action; unsavedDlg.open() }
        function onManagerRequested() { manager.open() }
    }
    function runPending() { const a = pendingAction; pendingAction = null; if (a) a() }

    // ---- name the world
    Dialog {
        id: nameDlg
        property var after: null
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(420, parent.width - Theme.s6 * 2)
        modal: true
        title: qsTr("Save world")
        readonly property string name: field.text.trim()
        readonly property bool replaces: name !== "" && WorldModel.libraryHas(name)
        onOpened: {
            field.text = WorldModel.filePath === "" && WorldModel.name === "Untitled world" ? "" : WorldModel.name
            field.selectAll(); field.forceActiveFocus()
        }
        ColumnLayout {
            width: parent.width
            spacing: Theme.s2
            Label { text: qsTr("Name"); color: Theme.textMuted; font.pixelSize: Theme.small }
            TextField {
                id: field
                Layout.fillWidth: true
                placeholderText: qsTr("e.g. Alpine valley")
                onAccepted: if (nameDlg.name !== "") nameDlg.accept()
            }
            Label {
                Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption
                color: nameDlg.replaces ? Theme.warn : Theme.textFaint
                text: nameDlg.replaces ? qsTr("A saved world is already called “%1”. Saving replaces it.").arg(nameDlg.name)
                                       : qsTr("Saved worlds appear in FLY and EVOLVE, ready to pick.")
            }
            Label {
                text: "<a href='#'>" + qsTr("Save to another folder…") + "</a>"
                font.pixelSize: Theme.caption; color: Theme.accent
                onLinkActivated: { nameDlg.close(); fileDlg.after = nameDlg.after; fileDlg.open() }
            }
        }
        footer: DialogButtonBox {
            Button { text: qsTr("Cancel"); DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
            Button { text: nameDlg.replaces ? qsTr("Replace") : qsTr("Save"); highlighted: true; enabled: nameDlg.name !== ""
                     DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
        }
        onAccepted: { if (WorldModel.saveToLibrary(name) && after) after(); after = null }
        onRejected: after = null
    }
    FileDialog {
        id: fileDlg
        property var after: null
        title: qsTr("Save world as")
        fileMode: FileDialog.SaveFile
        defaultSuffix: "json"
        nameFilters: [qsTr("World (*.json)")]
        currentFolder: (Qt.platform.os === "windows" ? "file:///" : "file://") + WorldModel.libraryDir
        onAccepted: { if (WorldModel.saveAs(selectedFile) && after) after(); after = null }
        onRejected: after = null
    }

    // ---- unsaved edits
    Dialog {
        id: unsavedDlg
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(420, parent.width - Theme.s6 * 2)
        modal: true
        title: qsTr("Save changes to “%1”?").arg(WorldModel.name)
        standardButtons: Dialog.Save | Dialog.Discard | Dialog.Cancel
        Label { width: parent.width; wrapMode: Text.WordWrap; text: qsTr("The world has edits that are not saved yet.") }
        onAccepted: WorldFlow.save(() => dlgs.runPending())
        onDiscarded: { close(); dlgs.runPending() }
        onRejected: dlgs.pendingAction = null
    }

    // ---- saved worlds
    Dialog {
        id: manager
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(520, parent.width - Theme.s6 * 2)
        height: Math.min(560, parent.height - Theme.s6 * 2)
        modal: true
        title: qsTr("Saved worlds")
        standardButtons: Dialog.Close
        ColumnLayout {
            anchors.fill: parent
            spacing: Theme.s2
            Label {
                Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.textMuted; font.pixelSize: Theme.caption
                text: qsTr("Open a world to edit it in WORLD and fly it in FLY. Deleting moves the file to the Trash.")
            }
            ListView {
                id: list
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true
                spacing: 2
                model: WorldModel.libraryInfo
                delegate: ItemDelegate {
                    required property var modelData
                    width: ListView.view.width
                    onClicked: { manager.close(); WorldFlow.open(modelData.name) }
                    contentItem: RowLayout {
                        spacing: Theme.s2
                        Rectangle { width: 4; Layout.fillHeight: true; radius: 2; color: modelData.current ? Theme.tabTint["WORLD"] : "transparent" }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Label { Layout.fillWidth: true; elide: Text.ElideRight; font.weight: Font.DemiBold; text: modelData.name }
                            Label { color: Theme.textFaint; font.pixelSize: Theme.caption
                                    text: (modelData.current ? qsTr("Open now · ") : "") + qsTr("Saved %1").arg(modelData.modified) }
                        }
                        ToolButton {
                            text: "🗑︎"
                            onClicked: { delConfirm.target = modelData.name; delConfirm.open() }
                            ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Move to the Trash")
                        }
                    }
                }
                PwEmptyState { anchors.centerIn: parent; visible: list.count === 0; text: qsTr("No saved worlds yet. Save one from the WORLD tab.") }
            }
            RowLayout {
                Layout.fillWidth: true
                Button { text: qsTr("New world"); onClicked: newMenu.popup()
                    Menu {
                        id: newMenu
                        MenuItem { text: qsTr("Flat"); onTriggered: { manager.close(); WorldFlow.newWorld("flat") } }
                        MenuItem { text: qsTr("Rolling hills"); onTriggered: { manager.close(); WorldFlow.newWorld("hills") } }
                        MenuItem { text: qsTr("Islands"); onTriggered: { manager.close(); WorldFlow.newWorld("islands") } }
                        MenuItem { text: qsTr("Mountains"); onTriggered: { manager.close(); WorldFlow.newWorld("mountains") } }
                        MenuItem { text: qsTr("Manhattan (Midtown)"); onTriggered: { manager.close(); WorldFlow.newWorld("manhattan") } }
                    }
                }
                Item { Layout.fillWidth: true }
                Button { text: qsTr("Open file…"); onClicked: openDlg.open() }
            }
        }
    }
    Dialog {
        id: delConfirm
        property string target
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        title: qsTr("Move “%1” to the Trash?").arg(target)
        standardButtons: Dialog.Cancel | Dialog.Ok
        Label { text: qsTr("You can restore it from the Trash later.") }
        onAccepted: WorldModel.removeFromLibrary(target)
    }
    FileDialog {
        id: openDlg
        title: qsTr("Open world")
        nameFilters: [qsTr("World (*.json)")]
        currentFolder: (Qt.platform.os === "windows" ? "file:///" : "file://") + WorldModel.libraryDir
        onAccepted: { manager.close(); WorldFlow.open(selectedFile) }
    }
}
