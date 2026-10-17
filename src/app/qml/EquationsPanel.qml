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
        // Integer models: cards and value labels are created once and only their text updates at the 10 Hz capture
        // rate. (A JS-array model rebuilt every card each capture, which hitched the frame — visible as flight jitter.)
        Repeater {
            model: App.equationsLive ? App.equations.length : 0
            delegate: ColumnLayout {
                id: card
                required property int index
                readonly property var modelData: App.equations[index] || ({ title: "", part: "", formula: "", values: [], force: [0, 0, 0], fmag: 0, torque: [0, 0, 0], tmag: 0, source: "" })
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
                        model: card.modelData.values.length
                        Text { required property int index
                            readonly property var v: card.modelData.values[index] || ({ symbol: "", value: 0 })
                            text: v.symbol + " = " + Theme.num(v.value)
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
