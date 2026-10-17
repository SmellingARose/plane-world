import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// FLY › EQUATIONS: the fast-model equations evaluated this frame for one part (or all), with every symbol's live value
// and the resulting force / moment. Full model: fast vs CFD comparison for the part first.
PwSection {
    id: eq
    title: "Equations"
    hint: "Live equation capture (~10 Hz). E toggles."
    trailing: Switch {
        checked: App.equationsLive
        onToggled: App.equationsLive = checked
        scale: 0.8
        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.tip("Live capture", "E")
    }
    PwCard {
        ComboBox {
            id: partBox
            Layout.fillWidth: true
            font.pixelSize: Theme.small
            model: [{ id: "", name: "All parts" }].concat(App.parts.map(p => ({ id: p.id, name: p.name + " · " + p.type })))
            textRole: "name"; valueRole: "id"
            currentIndex: Math.max(0, indexOfValue(App.equationsPart))
            onActivated: (i) => App.equationsPart = model[i].id
            ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: "Equations are captured for this part (the BUILD selection carries over)"
        }
        ColumnLayout {
            visible: App.fullModel && App.equationsPart !== ""
            Layout.fillWidth: true
            spacing: 2
            Label { text: "Fast vs CFD (this part, aero only)"; font.weight: Font.DemiBold; font.pixelSize: Theme.small }
            PwStatRow { label: "Fast |F|"; value: App.comparison.fast !== undefined ? Theme.num(App.comparison.fast) + " N" : "–" }
            PwStatRow { label: "CFD |F| (momentum exchange)"; value: App.comparison.cfd !== undefined ? Theme.num(App.comparison.cfd) + " N" : "–" }
            PwStatRow { label: "Difference"; value: App.comparison.diff !== undefined ? App.comparison.diff.toFixed(1) + " %" : "no CFD force yet"
                warn: Math.abs(App.comparison.diff || 0) > 20 }
        }
        PwEmptyState {
            visible: !App.equationsLive || App.equations.length === 0
            text: !App.equationsLive ? "Live capture off." : App.paused ? "Unpause the flight to capture equations." : "Waiting for the simulation to report equations for this part…"
            shortcut: !App.equationsLive ? "E" : (App.paused ? "P" : "")
            shortcutLabel: !App.equationsLive ? "turn on" : "resume"
        }
        Repeater {
            model: App.equationsLive ? App.equations : []
            delegate: ColumnLayout {
                id: card
                required property var modelData
                Layout.fillWidth: true
                spacing: 2
                RowLayout {
                    Layout.fillWidth: true
                    Label { text: card.modelData.title; font.weight: Font.DemiBold; font.pixelSize: Theme.small; Layout.fillWidth: true; elide: Text.ElideRight }
                    Label { text: card.modelData.part; color: Theme.textFaint; font.pixelSize: Theme.caption; elide: Text.ElideRight; Layout.maximumWidth: 110 }
                }
                TextEdit {
                    Layout.fillWidth: true
                    text: card.modelData.formula
                    readOnly: true; selectByMouse: true
                    wrapMode: Text.WordWrap
                    font.family: Theme.serif; font.italic: true; font.pixelSize: Theme.body
                    color: Theme.text
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.s2
                    Repeater {
                        model: card.modelData.values
                        Text { required property var modelData; text: modelData.symbol + " = " + Theme.num(modelData.value)
                            font.family: Theme.mono; font.pixelSize: Theme.caption; color: Theme.textMuted }
                    }
                }
                Text {
                    text: "→ F = (" + card.modelData.force.map(Theme.num).join(", ") + ") N   |F| = " + Theme.num(card.modelData.fmag) + " N"
                    font.family: Theme.mono; font.pixelSize: Theme.caption; color: Theme.accent; wrapMode: Text.WordWrap; Layout.fillWidth: true
                }
                Text {
                    visible: card.modelData.tmag > 0
                    text: "   M = (" + card.modelData.torque.map(Theme.num).join(", ") + ") N·m"
                    font.family: Theme.mono; font.pixelSize: Theme.caption; color: Theme.textMuted; wrapMode: Text.WordWrap; Layout.fillWidth: true
                }
                Text { visible: card.modelData.source !== ""; text: card.modelData.source; font.pixelSize: Theme.micro + 1; color: Theme.textFaint; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator; opacity: 0.6; Layout.topMargin: Theme.s1 }
            }
        }
        Label {
            text: "<a href='https://github.com/SmellingARose/plane-world/blob/main/docs/PHYSICS.md'>All equations with sources → docs/PHYSICS.md</a>"
            textFormat: Text.RichText; font.pixelSize: Theme.caption
            onLinkActivated: (l) => Qt.openUrlExternally(l)
            HoverHandler { cursorShape: Qt.PointingHandCursor }
        }
    }
}
