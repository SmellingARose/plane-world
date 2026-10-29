import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// EVOLVE › Results › "Add to craft as a behaviour…": the selected candidate becomes a named behaviour on a key,
// added to the experiment's saved craft (updated in the library), another saved craft, or a new copy. FLY lists it
// under Behaviours; its key engages it. Keys FLY already uses with that craft are refused and listed.
Dialog {
    id: dlg
    property string defaultName: ""          // from the goal preset ("Hover"), else the experiment's name
    property var targets: ({})
    property string targetPath: ""             // "" = a new copy
    property string keyName: ""
    property bool keyTouched: false
    readonly property var keys: EvolveModel.behaviourKeys(targetPath, nameField.text, keyName)
    readonly property string conflict: keys.conflict || ""
    readonly property bool designOnly: !!targets.designChanges

    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(460, (parent ? parent.width : 800) - Theme.s6 * 2)
    modal: true
    title: qsTr("Add to craft as a behaviour")
    padding: Theme.s4

    function show(name) {
        targets = EvolveModel.behaviourTargets()
        defaultName = name
        nameField.text = name
        targetPath = !designOnly && targets.craftPath ? targets.craftPath : ""
        newName.text = targets.newName || ""
        keyTouched = false
        keyName = EvolveModel.behaviourKeys(targetPath, name, "").suggested || ""
        open()
        nameField.forceActiveFocus(); nameField.selectAll()
    }
    // the suggestion follows the name and target until a key is picked by hand
    function resuggest() { if (!keyTouched) keyName = EvolveModel.behaviourKeys(targetPath, nameField.text, "").suggested || "" }
    function add(fly) {
        if (conflict !== "" || nameField.text.trim() === "") return
        if (EvolveModel.addBehaviour(nameField.text.trim(), keyName, targetPath, newName.text, fly) !== "") close()
    }

    // target choices: [label, path]
    readonly property var choices: {
        const r = []
        const own = targets.craftPath || ""
        if (own !== "" && !designOnly) r.push({ text: qsTr("Update “%1” in my crafts").arg(targets.craftName), path: own })
        r.push({ text: qsTr("A new craft"), path: "" })
        if (!designOnly) for (const c of targets.crafts || []) if (c.path !== own)
            r.push({ text: qsTr("Add to “%1”").arg(c.name) + (c.behaviours > 0 ? qsTr("  (%1 already)").arg(c.behaviours) : ""), path: c.path })
        return r
    }

    contentItem: ColumnLayout {
        spacing: Theme.s3

        Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Theme.textMuted
            font.pixelSize: Theme.small
            text: qsTr("The craft keeps this controller as a behaviour. In FLY, press its key to let it fly from wherever you are; press it again or move a stick to take over.")
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Theme.s3
            rowSpacing: Theme.s2

            Label { text: qsTr("Name"); color: Theme.textMuted; font.pixelSize: Theme.small }
            TextField {
                id: nameField
                Layout.fillWidth: true
                placeholderText: qsTr("e.g. Hover")
                selectByMouse: true
                onTextEdited: dlg.resuggest()
                onAccepted: dlg.add(false)
            }

            Label { text: qsTr("Key"); color: Theme.textMuted; font.pixelSize: Theme.small }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s2
                KeyCaptureButton {
                    keyName: dlg.keyName
                    role: qsTr("starts and stops this behaviour in FLY")
                    onCaptured: (n) => { dlg.keyName = n; dlg.keyTouched = true }
                }
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.caption
                    color: dlg.conflict !== "" ? Theme.warn : Theme.textFaint
                    text: dlg.conflict !== "" ? dlg.conflict + qsTr(" — pick another key")
                        : dlg.keyName === "" ? qsTr("No key: start it from the FLY list")
                        : dlg.keyTouched ? qsTr("Free") : qsTr("Suggested — click it to pick another")
                }
            }

            Label { text: qsTr("Craft"); color: Theme.textMuted; font.pixelSize: Theme.small }
            ComboBox {
                id: targetBox
                Layout.fillWidth: true
                model: dlg.choices
                textRole: "text"
                currentIndex: Math.max(0, dlg.choices.findIndex(c => c.path === dlg.targetPath))
                onActivated: (i) => { dlg.targetPath = dlg.choices[i].path; dlg.resuggest() }
            }

            Item { visible: dlg.targetPath === ""; implicitWidth: 1 }
            TextField {
                id: newName
                visible: dlg.targetPath === ""
                Layout.fillWidth: true
                placeholderText: qsTr("Name of the new craft")
                selectByMouse: true
            }
        }

        Label {
            visible: dlg.designOnly
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Theme.textFaint
            font.pixelSize: Theme.caption
            text: qsTr("This run changes the craft's shape too, so the behaviour goes on a new craft built to that shape.")
        }

        // keys FLY already uses with the target craft
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.s1
            Label { text: qsTr("Keys already in use"); color: Theme.textMuted; font.pixelSize: Theme.caption; font.weight: Font.DemiBold }
            Flow {
                Layout.fillWidth: true
                spacing: Theme.s2
                Repeater {
                    model: dlg.keys.used || []
                    Row {
                        required property var modelData
                        spacing: Theme.s1
                        KeyHint { raw: true; sequence: modelData.label; active: modelData.key === dlg.keyName; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: modelData.what; color: Theme.textFaint; font.pixelSize: Theme.caption; anchors.verticalCenter: parent.verticalCenter }
                    }
                }
            }
        }
    }

    footer: DialogButtonBox {
        Button { text: qsTr("Cancel"); DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
        Button {
            text: qsTr("Add and fly")
            enabled: dlg.conflict === "" && nameField.text.trim() !== ""
            onClicked: dlg.add(true)
            ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay
            ToolTip.text: qsTr("Adds it, then opens the craft in FLY with this behaviour flying")
        }
        Button {
            text: qsTr("Add")
            highlighted: true
            enabled: dlg.conflict === "" && nameField.text.trim() !== ""
            onClicked: dlg.add(false)
        }
        onRejected: dlg.close()
    }
}
