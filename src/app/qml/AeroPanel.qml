import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// FLY › Aero model: model picker (fast-model profiles) and the fast-model effect toggles.
ColumnLayout {
    id: aero
    spacing: Theme.s3

    PwSection {
        title: "Aero model"
        hint: "Aero forces come from closed-form models (see EQUATIONS). Cycle with " + Theme.shortcutText("Ctrl+Shift+M")
        trailing: Rectangle {
            radius: 3; implicitWidth: badge.implicitWidth + 10; implicitHeight: badge.implicitHeight + 4
            color: Theme.alpha(Theme.accent, 0.18)
            Text { id: badge; anchors.centerIn: parent; font.pixelSize: Theme.micro + 1; font.weight: Font.DemiBold
                color: Theme.accent; text: "ANALYTIC" }
        }
        PwCard {
            AeroModelPicker {
                Layout.fillWidth: true
                currentId: App.aeroModel
                onPicked: (id) => App.aeroModel = id
            }
            PwSection {
                title: "Fast-model effects"
                expanded: false
                Repeater {
                    model: [
                        { k: "slipstream", t: "Prop slipstream (wakes, ducts)", h: "Actuator-disk prop wakes feed downstream parts; duct and rotor ground effect." },
                        { k: "gyro", t: "Gyroscopic rotors", h: "Prop / wheel angular momentum couples into body rotation (ω × H)." },
                        { k: "pFactor", t: "Prop P-factor", h: "Asymmetric disk loading at incidence: normal force + yaw / pitch moment." },
                        { k: "downwash", t: "Wing downwash", h: "Horseshoe-vortex induced velocity from upstream wings onto the tail." },
                        { k: "blockage", t: "Wake blockage", h: "Bodies attenuate / deflect prop wakes behind them." },
                        { k: "cadWash", t: "CAD panels in slipstream", h: "CAD panels sample the slipstream per panel." } ]
                    CheckBox {
                        required property var modelData
                        text: modelData.t
                        font.pixelSize: Theme.small
                        enabled: modelData.k === "slipstream" || App.fastToggles.slipstream
                        checked: App.fastToggles[modelData.k] === true
                        onToggled: App.setFastToggle(modelData.k, checked)
                        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: modelData.h
                    }
                }
                Label { text: "Effects other than slipstream need the slipstream model on."; color: Theme.textFaint; font.pixelSize: Theme.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            }
        }
    }
}
