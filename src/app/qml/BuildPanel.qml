import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// BUILD inspector: craft, add part, parts list, selected part, outputs + keybinds, inputs, CAD import.
ColumnLayout {
    id: build
    spacing: Theme.s3
    signal openRequested()
    signal saveAsRequested()
    signal importRequested(bool intoCurrent)
    function focusPartName() { inspector.focusName() }

    PwSection {
        title: "Craft"
        PwCard {
            TextField {
                Layout.fillWidth: true
                text: App.craftName
                placeholderText: "Craft name"
                font.pixelSize: Theme.body
                font.weight: Font.DemiBold
                selectByMouse: true
                onEditingFinished: if (text !== App.craftName) App.craftName = text
                Keys.onEscapePressed: { text = App.craftName; focus = false }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s1
                ComboBox {
                    id: lib
                    Layout.fillWidth: true
                    model: App.library
                    textRole: "name"
                    displayText: "Load…"
                    font.pixelSize: Theme.small
                    delegate: ItemDelegate {
                        required property var modelData
                        required property int index
                        width: ListView.view ? ListView.view.width : 200
                        highlighted: lib.highlightedIndex === index
                        contentItem: RowLayout {
                            Label { text: modelData.name; Layout.fillWidth: true; elide: Text.ElideRight }
                            Label { text: modelData.source + " · " + modelData.parts; color: Theme.textFaint; font.pixelSize: Theme.caption }
                        }
                    }
                    onActivated: (i) => App.loadLibraryCraft(i)
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay
                    ToolTip.text: "Built-in presets and crafts saved to your library"
                }
                PwIconButton { text: "New"; tip: "New craft"; shortcut: "Ctrl+N"; onClicked: App.newCraft() }
                PwIconButton { text: "Open"; tip: "Open craft JSON or CAD file"; shortcut: "Ctrl+O"; onClicked: build.openRequested() }
                PwIconButton { text: "Save"; tip: App.filePath !== "" ? "Save " + App.filePath : "Save as…"; shortcut: "Ctrl+S"
                    onClicked: App.filePath !== "" ? App.saveFile("") : build.saveAsRequested() }
            }
            RowLayout {
                Layout.fillWidth: true
                Button { text: "Save to library"; font.pixelSize: Theme.small; onClicked: App.saveToLibrary()
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.tip("Save into the craft library", "Ctrl+Shift+L") }
                Item { Layout.fillWidth: true }
                Label { text: App.dirty ? "● edited" : ""; color: Theme.warn; font.pixelSize: Theme.caption }
            }
            Label { text: App.massSummary; font.family: Theme.mono; font.pixelSize: Theme.caption; color: Theme.textMuted; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        }
    }

    PwSection {
        title: "Add part"
        hint: "Adds above the selected part. Press A to search part types."
        GridLayout {
            Layout.fillWidth: true
            columns: 4
            columnSpacing: Theme.s1
            rowSpacing: Theme.s1
            Repeater {
                model: App.partTypes
                Button {
                    required property string modelData
                    Layout.fillWidth: true
                    text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                    font.pixelSize: Theme.small
                    focusPolicy: Qt.TabFocus
                    onClicked: App.addPart(modelData)
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay
                    ToolTip.text: "Add a " + modelData + " above the selected part"
                }
            }
        }
    }

    PwSection {
        title: "Parts (" + App.parts.length + ")"
        hint: "Click a part here or in the viewport. ⌥↑ / ⌥↓ step through parts."
        trailing: Text { text: App.selectedId !== "" ? "Esc deselects" : ""; color: Theme.textFaint; font.pixelSize: Theme.micro + 1 }
        PwCard {
            padding: Theme.s1
            ListView {
                id: partList
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(contentHeight, 260)
                clip: true
                model: App.parts
                boundsBehavior: Flickable.StopAtBounds
                currentIndex: { for (let i = 0; i < App.parts.length; ++i) if (App.parts[i].id === App.selectedId) return i; return -1 }
                highlightMoveDuration: Theme.fast
                highlight: Rectangle { radius: Theme.radiusSmall; color: Theme.accentSoft }
                keyNavigationEnabled: true
                activeFocusOnTab: true
                Keys.onUpPressed: if (currentIndex > 0) App.selectedId = App.parts[currentIndex - 1].id
                Keys.onDownPressed: if (currentIndex < App.parts.length - 1) App.selectedId = App.parts[currentIndex + 1].id
                Keys.onReturnPressed: build.focusPartName()
                ScrollBar.vertical: ScrollBar {}
                delegate: Item {
                    id: pd
                    required property var modelData
                    required property int index
                    width: ListView.view.width
                    height: Theme.rowHeight
                    Rectangle { anchors.fill: parent; radius: Theme.radiusSmall; color: Theme.hover; visible: ma.containsMouse && pd.modelData.id !== App.selectedId }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.s2; anchors.rightMargin: Theme.s4
                        spacing: Theme.s2
                        Rectangle { width: 9; height: 9; radius: 4.5; color: pd.modelData.color; border.color: Theme.separator }
                        Label { text: pd.modelData.name; Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: Theme.small
                            font.weight: pd.modelData.id === App.selectedId ? Font.DemiBold : Font.Normal }
                        Label { visible: pd.modelData.servo !== ""; text: "⛓"; color: Theme.partTint.servo; font.pixelSize: Theme.caption
                            ToolTip.visible: ma.containsMouse && visible; ToolTip.text: "Driven by a servo" }
                        Label { visible: pd.modelData.motor !== ""; text: "ϟ"; color: Theme.partTint.motor; font.pixelSize: Theme.caption }
                        Rectangle {
                            radius: 3; implicitWidth: tl.implicitWidth + 8; implicitHeight: tl.implicitHeight + 2
                            color: Theme.alpha(Theme.partTint[pd.modelData.type] || Theme.textFaint, 0.18)
                            Text { id: tl; anchors.centerIn: parent; text: pd.modelData.type; font.pixelSize: Theme.micro + 1
                                color: Theme.partTint[pd.modelData.type] || Theme.textMuted }
                        }
                    }
                    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true
                        onClicked: { App.selectedId = pd.modelData.id; partList.forceActiveFocus() }
                        onDoubleClicked: build.focusPartName() }
                }
            }
            PwEmptyState {
                visible: App.parts.length === 0
                title: "No parts yet"
                text: "Add a part above, or drop an STL / OBJ / glTF file anywhere in the window."
            }
        }
    }

    PartInspector { id: inspector; visible: App.selectedId !== "" }

    PwSection {
        title: "Outputs (" + App.outputs.length + ")"
        hint: "One FLY control per servo, motor, jet and solid booster. Bind keys here; they light up in FLY."
        PwCard {
            Repeater { model: App.outputs; OutputBindingRow {} }
            PwEmptyState { visible: App.outputs.length === 0; title: "No controllable parts"
                text: "Servos, motors, jets and solid boosters become outputs. Wheels and props get an automatic motor." }
        }
    }

    PwSection {
        title: "Inputs (" + App.inputs.length + ")"
        expanded: App.inputs.length > 0
        hint: "Named sensor channels that controllers and scripts read"
        PwCard {
            Repeater {
                model: App.inputs
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    Label { text: modelData.name; font.pixelSize: Theme.small; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                    Label { text: modelData.kind + (modelData.unit ? " · " + modelData.unit : ""); color: Theme.textFaint; font.pixelSize: Theme.caption }
                    TapHandler { onTapped: App.selectedId = modelData.partId }
                }
            }
            PwEmptyState { visible: App.inputs.length === 0; text: "No sensors. Add a sensor part; each adds named inputs (e.g. att.pitch) for controllers." }
        }
    }

    PwSection {
        title: "CAD import"
        expanded: false
        hint: "STL, OBJ, glTF / GLB" + (App.cadExtensions.indexOf("usdz") >= 0 ? ", USD" : "") + ". Drag files onto the window too."
        PwCard {
            Label { text: "Formats: " + App.cadExtensions.join(" · "); color: Theme.textMuted; font.pixelSize: Theme.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            RowLayout {
                CheckBox { text: "Z-up source"; checked: App.importUpZ; onToggled: App.importUpZ = checked
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: "The file uses Z as up (most CAD tools)" }
                CheckBox { text: "Auto-rig"; checked: App.autoRigOnImport; onToggled: App.autoRigOnImport = checked
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: "Name rules turn ailerons, elevators, props, wheels… into linked servos and motors" }
            }
            PwPropertyRow { label: "Scale"; tip: "Uniform scale (0.001 for millimetre files)"
                PwNumberField { value: App.importScale; step: 0.001; decimals: 4; minimum: 1e-6; onCommitted: (v) => App.importScale = v } }
            PwPropertyRow { label: "Yaw °"; tip: "Extra rotation about up after the axis fix"
                PwNumberField { value: App.importYaw; step: 90; decimals: 1; onCommitted: (v) => App.importYaw = v } }
            RowLayout {
                Button { text: "Import as craft…"; font.pixelSize: Theme.small; onClicked: build.importRequested(false)
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.tip("Import a CAD assembly as a new craft", "Ctrl+Shift+I") }
                Button { text: "Add to craft…"; font.pixelSize: Theme.small; onClicked: build.importRequested(true) }
            }
            Button { text: "Auto-rig current craft"; font.pixelSize: Theme.small; onClicked: App.autoRig() }
            Repeater {
                model: App.rigReport.slice(0, 30)
                Label { required property string modelData; text: modelData; font.family: Theme.mono; font.pixelSize: Theme.caption
                    color: modelData.startsWith("!") ? Theme.warn : Theme.textMuted }
            }
        }
    }
}
