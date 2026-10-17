import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

// BUILD › selected part: identity, transform, type parameters, links, actions and mesh cut.
ColumnLayout {
    id: insp
    readonly property var p: App.selected
    readonly property bool has: p && p.id !== undefined
    spacing: Theme.s3
    Layout.fillWidth: true
    function focusName() { nameField.forceActiveFocus(); nameField.selectAll() }

    PwSection {
        title: insp.has ? "Part · " + insp.p.type : "Part"
        PwCard {
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s2
                Rectangle {
                    id: swatch
                    width: 22; height: 22; radius: Theme.radiusSmall
                    color: insp.p.color || "#888888"
                    border.color: Theme.separator
                    activeFocusOnTab: true
                    Keys.onSpacePressed: colorDialog.open()
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: colorDialog.open() }
                    HoverHandler { id: swHover }
                    ToolTip.visible: swHover.hovered
                    ToolTip.delay: Theme.tooltipDelay
                    ToolTip.text: "Colour " + (insp.p.color || "") + " — click to change"
                }
                TextField {
                    id: nameField
                    Layout.fillWidth: true
                    text: insp.p.name || ""
                    placeholderText: "Part name"
                    selectByMouse: true
                    onEditingFinished: if (insp.has && text !== insp.p.name) App.setPartField(insp.p.id, "name", text)
                    Keys.onEscapePressed: { text = insp.p.name; focus = false }
                    ToolTip.visible: hovered && !activeFocus
                    ToolTip.delay: Theme.tooltipDelay
                    ToolTip.text: Theme.tip("Rename part", "Return")
                }
            }
            PwPropertyRow {
                label: "Mass"
                tip: "Dry mass of this part in kg (fuel is added for tanks, jets and solids)"
                PwNumberField {
                    value: insp.p.mass || 0; step: 0.1; decimals: 3; minimum: 0; suffix: "kg"
                    tip: "Mass (kg)"
                    onCommitted: (v) => App.setPartField(insp.p.id, "mass", v)
                }
            }
            PwVecField {
                label: "Position"
                value: insp.p.pos || [0, 0, 0]
                step: 0.05
                tip: "Position (m, craft frame: +X forward, +Y up, +Z right)"
                onCommitted: (a, v) => App.setPartVector(insp.p.id, "pos", a, v)
            }
            PwVecField {
                label: "Rotation °"
                value: insp.p.rot || [0, 0, 0]
                step: 5; decimals: 2
                tip: "Euler XYZ rotation (degrees)"
                onCommitted: (a, v) => App.setPartVector(insp.p.id, "rot", a, v)
            }
        }
    }

    PwSection {
        title: "Parameters"
        visible: insp.has && insp.p.params && insp.p.params.length > 0
        PwCard {
            Repeater {
                model: insp.p.params || []
                delegate: PwPropertyRow {
                    id: prow
                    required property var modelData
                    label: modelData.label + (modelData.unit ? " (" + modelData.unit + ")" : "")
                    tip: modelData.tip
                    Item {
                        readonly property var row: prow.modelData
                        implicitHeight: Math.max(nf.visible ? nf.implicitHeight : 0, cb.visible ? cb.implicitHeight : 0, co.visible ? co.implicitHeight : 0, tf.visible ? tf.implicitHeight : 0)
                        PwNumberField { id: nf; width: parent.width; visible: row.kind === "number"; value: visible ? row.value : 0; step: row.step || 0.01; decimals: 4; tip: row.tip
                            onCommitted: (v) => App.setPartParam(insp.p.id, row.key, v) }
                        CheckBox { id: cb; visible: row.kind === "bool"; checked: row.value === true; onToggled: App.setPartParam(insp.p.id, row.key, checked) }
                        ComboBox { id: co; width: parent.width; visible: row.kind === "string" && !!row.choices; model: row.choices || []
                            currentIndex: row.choices ? Math.max(0, row.choices.indexOf(row.value)) : -1; font.pixelSize: Theme.small
                            onActivated: (i) => App.setPartParam(insp.p.id, row.key, row.choices[i]) }
                        TextField { id: tf; width: parent.width; visible: row.kind === "string" && !row.choices; text: visible ? row.value : ""; font.pixelSize: Theme.small; selectByMouse: true
                            onEditingFinished: if (text !== row.value) App.setPartParam(insp.p.id, row.key, text) }
                    }
                }
            }
            Label {
                visible: insp.p.isSensor === true
                text: insp.p.sensorSummary || ""
                color: Theme.textMuted; font.pixelSize: Theme.caption
                wrapMode: Text.WordWrap; Layout.fillWidth: true
            }
        }
    }

    PwSection {
        title: "Links"
        visible: insp.has && (insp.p.canServo || insp.p.canMotor || (!!insp.p.drives && insp.p.drives.length > 0))
        PwCard {
            PwPropertyRow {
                visible: insp.p.canServo === true
                label: "Servo"
                tip: "Servo that deflects this part (control surfaces, steering)"
                ComboBox {
                    model: insp.p.servoChoices || []
                    textRole: "name"; valueRole: "id"
                    font.pixelSize: Theme.small
                    currentIndex: { const l = insp.p.servoChoices || []; for (let i = 0; i < l.length; ++i) if (l[i].id === insp.p.servo) return i; return 0 }
                    onActivated: (i) => App.setPartField(insp.p.id, "servo", model[i].id)
                }
            }
            CheckBox {
                visible: insp.p.canServo === true && insp.p.servo !== ""
                text: "Invert servo direction"
                checked: insp.p.invert === true
                onToggled: App.setPartField(insp.p.id, "invert", checked)
            }
            PwPropertyRow {
                visible: insp.p.canMotor === true
                label: "Motor"
                tip: "Motor that drives this wheel / prop; none = an automatic motor output in FLY"
                ComboBox {
                    model: insp.p.motorChoices || []
                    textRole: "name"; valueRole: "id"
                    font.pixelSize: Theme.small
                    currentIndex: { const l = insp.p.motorChoices || []; for (let i = 0; i < l.length; ++i) if (l[i].id === insp.p.motor) return i; return 0 }
                    onActivated: (i) => App.setPartField(insp.p.id, "motor", model[i].id)
                }
            }
            Label {
                visible: !!insp.p.drives && insp.p.drives.length > 0
                text: "Drives: " + (insp.p.drives || []).join(", ")
                color: Theme.textMuted; font.pixelSize: Theme.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true
            }
        }
    }

    PwSection {
        title: "Actions"
        visible: insp.has
        Flow {
            Layout.fillWidth: true
            spacing: Theme.s1
            Button { text: "Duplicate"; font.pixelSize: Theme.small; onClicked: App.duplicateSelected(false)
                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.tip("Duplicate part", "Ctrl+D") }
            Button { text: "Mirror L/R"; font.pixelSize: Theme.small; onClicked: App.duplicateSelected(true)
                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.tip("Mirrored copy across the centre line (Z → −Z)", "M") }
            Button { text: "Delete"; font.pixelSize: Theme.small; onClicked: App.deleteSelected()
                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.tip("Delete part (undoable)", "Backspace") }
        }
    }

    PwSection {
        title: "Mesh cut"
        expanded: false
        visible: insp.has
        hint: "Split the selected part with a plane into two closed CAD parts"
        PwCard {
            PwSegmented { id: cutAxis; model: [{ text: "X", tip: "Plane normal X (forward)" }, { text: "Y", tip: "Plane normal Y (up)" }, { text: "Z", tip: "Plane normal Z (right)" }] }
            PwSlider { id: cutOffset; label: "Offset from part origin"; from: -5; to: 5; step: 0.01; value: 0; defaultValue: 0; unit: "m" }
            Button { text: "Cut selected part"; onClicked: App.cutSelected(cutAxis.currentIndex, cutOffset.value) }
        }
    }

    ColorDialog {
        id: colorDialog
        title: "Part colour"
        selectedColor: insp.p.color || "#888888"
        onAccepted: {
            const c = selectedColor
            const h = (x) => ("0" + Math.round(x * 255).toString(16)).slice(-2)
            App.setPartField(insp.p.id, "color", "#" + h(c.r) + h(c.g) + h(c.b))
        }
    }
}
