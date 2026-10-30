import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// FLY inspector: flight controls, camera, output sliders with keybind badges, aero model, sensors, equations.
ColumnLayout {
    id: fly
    spacing: Theme.s3
    readonly property alias equationsItem: equations

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.s1
        Label { text: App.craftName; font.pixelSize: Theme.title; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
        PwIconButton { text: App.paused ? "▶" : "❚❚"; tip: App.paused ? "Resume" : "Pause"; shortcut: "P"; onClicked: App.paused = !App.paused }
        PwIconButton { text: "↺"; tip: "Reset flight"; shortcut: "R"; onClicked: App.resetFlight() }
    }
    // Evolved controllers the craft carries, each on its own key (EVOLVE › Results › "Add to craft as a behaviour")
    BehaviourList {}
    PwSegmented {
        model: [{ text: "Chase", tip: "Swings behind the flight path" }, { text: "Orbit", tip: "Free orbit around the craft" }, { text: "Cockpit", tip: "Pilot's eye; drag to look around" }]
        currentIndex: ["chase", "orbit", "cockpit"].indexOf(App.cameraMode)
        onActivated: (i) => App.cameraMode = ["chase", "orbit", "cockpit"][i]
        ToolTip.visible: false
    }
    Label { text: "C cycles the camera"; color: Theme.textFaint; font.pixelSize: Theme.caption; Layout.topMargin: -Theme.s2 }

    // Where you fly: flat ground, the world open in WORLD (terrain, water, trees, props, wind all count) or a saved world.
    PwSection {
        title: "World"
        hint: "Pick flat ground, the world open in the WORLD tab, or a saved world. Edits in WORLD show up here immediately."
        PwCard {
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s2
                Rectangle { width: 4; Layout.fillHeight: true; radius: 2; color: App.flyInWorld ? Theme.tabTint["WORLD"] : Theme.separator }
                WorldPicker { Layout.fillWidth: true }
            }
            Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.textMuted; font.pixelSize: Theme.caption; text: App.worldSummary }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s1
                Button { Layout.fillWidth: true; Layout.preferredWidth: 1; text: "Edit world"; onClicked: App.requestTab("WORLD")
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.tip("Sculpt terrain, add water, trees and props, move the spawn", "Ctrl+3") }
                Button { Layout.fillWidth: true; Layout.preferredWidth: 1; text: "Air start"; onClicked: App.airStart(150, 35)
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: "Restart 150 m above the start point at 35 m/s" }
            }
            Label { visible: App.worldSummary.indexOf("custom start") >= 0; Layout.fillWidth: true; font.pixelSize: Theme.caption; color: Theme.accent
                text: "<a href='#'>Use the world's spawn point again</a>"; onLinkActivated: App.clearFlyFrom() }
        }
    }

    // Pilot axes (pw/sim/controls.h): keys drive named axes, the craft's controller turns them into outputs.
    PwSection {
        visible: App.controller !== "direct"
        title: "Pilot (" + App.controller + ")"
        hint: App.controller === "multirotor" ? "Flight controller: throttle sets climb rate (release to hold altitude), arrows tilt (release to level), yaw turns." : ""
        PwCard {
            Repeater {
                model: App.controlAxes
                delegate: RowLayout {
                    id: ax
                    required property var modelData
                    required property int index
                    readonly property real v: App.axisValues[index] !== undefined ? App.axisValues[index] : 0
                    Layout.fillWidth: true
                    spacing: Theme.s1
                    Label { text: ax.modelData.name; font.pixelSize: Theme.small; font.weight: Font.Medium; Layout.fillWidth: true }
                    KeyHint { visible: ax.modelData.negLabel !== ""; raw: true; sequence: ax.modelData.negLabel; active: App.heldKeys.indexOf(ax.modelData.neg) >= 0 }
                    KeyHint { visible: ax.modelData.posLabel !== ""; raw: true; sequence: ax.modelData.posLabel; active: App.heldKeys.indexOf(ax.modelData.pos) >= 0 }
                    Label { text: Theme.signed(ax.v, 2); font.family: Theme.mono; font.pixelSize: Theme.small; color: Theme.accent; Layout.preferredWidth: 46; horizontalAlignment: Text.AlignRight }
                }
            }
        }
    }

    PwSection {
        title: "Controls (" + App.outputs.length + ")"
        hint: "Drag a slider or use its keys; held keys light up. Bind keys in BUILD › Outputs."
        PwCard {
            Repeater {
                model: App.outputs
                delegate: ColumnLayout {
                    id: oc
                    required property var modelData
                    required property int index
                    readonly property real v: App.outputValues[index] !== undefined ? App.outputValues[index] : 0
                    Layout.fillWidth: true
                    spacing: 0
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.s1
                        Label { text: oc.modelData.name; font.pixelSize: Theme.small; font.weight: Font.Medium; Layout.fillWidth: true; elide: Text.ElideRight }
                        KeyHint { visible: oc.modelData.negLabel !== ""; raw: true; sequence: oc.modelData.negLabel; active: App.heldKeys.indexOf(oc.modelData.neg) >= 0 }
                        KeyHint { visible: oc.modelData.posLabel !== ""; raw: true; sequence: oc.modelData.posLabel; active: App.heldKeys.indexOf(oc.modelData.pos) >= 0 }
                        Label { text: Theme.signed(oc.v, 2); font.family: Theme.mono; font.pixelSize: Theme.small; color: Theme.accent; Layout.preferredWidth: 46; horizontalAlignment: Text.AlignRight }
                    }
                    Slider {
                        Layout.fillWidth: true
                        from: oc.modelData.lo; to: oc.modelData.hi
                        value: oc.v
                        enabled: !oc.modelData.owned   // driven by the flight controller
                        focusPolicy: Qt.TabFocus
                        onMoved: App.setOutputValue(oc.modelData.id, value)
                        TapHandler { onDoubleTapped: App.setOutputValue(oc.modelData.id, oc.modelData.lo <= 0 && oc.modelData.hi >= 0 ? 0 : oc.modelData.lo) }
                        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay
                        ToolTip.text: oc.modelData.info + (oc.modelData.bound ? "\nKeys: " + (oc.modelData.posLabel || "·") + " more, " + (oc.modelData.negLabel || "·") + " less (" + oc.modelData.mode + ")" : "") + "\nDouble-click to centre"
                    }
                }
            }
            PwEmptyState { visible: App.outputs.length === 0; text: "This craft has no outputs. Add servos, motors, jets or boosters in BUILD." }
        }
    }

    AeroPanel {}

    PwSection {
        title: "Sensors"
        visible: App.inputs.length > 0
        PwCard {
            Repeater {
                model: App.inputs
                PwStatRow { required property var modelData; label: modelData.name; value: Theme.fixed(modelData.value, 2) + (modelData.unit ? " " + modelData.unit : "") }
            }
        }
    }

    EquationsPanel { id: equations }

    PwSection {
        title: "Simulation"
        expanded: false
        PwCard {
            PwStatRow { label: "Physics"; value: (App.perf.substepHz || 0).toFixed(0) + " Hz substeps" }
            PwStatRow { label: "Sim CPU per frame"; value: Theme.fixed(App.perf.simMs, 2) + " ms" }
            PwStatRow { label: "Real-time factor"; value: "×" + Theme.fixed(App.perf.rtf, 2); warn: App.perf.rtf > 0 && App.perf.rtf < 0.95 && !App.paused }
            PwStatRow { label: "Sim time"; value: Theme.fixed(App.telemetry.time, 1) + " s" }
        }
    }
}
