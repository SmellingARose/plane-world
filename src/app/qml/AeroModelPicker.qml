import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Aero model list shared by FLY and EVOLVE (App.aeroModels), grouped by method so the kinds of aero are distinct:
// Fast (analytic) | CFD · Lattice Boltzmann (real-time GPU) | CFD · Navier–Stokes FV (GPU, URANS, slower) | Custom.
// Each group starts with a header that says what the method is, what it costs and how accurate it is; the selected
// model's one-line summary sits underneath. `evolveOnly` hides models training cannot use (Navier–Stokes FV).
ColumnLayout {
    id: picker
    property string currentId
    property bool evolveOnly: false
    signal picked(string id)
    spacing: Theme.s1
    readonly property var models: {
        const all = App.aeroModels, out = []
        let last = ""
        for (let i = 0; i < all.length; ++i) {
            if (evolveOnly && !all[i].evolve) continue
            const m = Object.assign({}, all[i])
            m.firstInGroup = m.group !== last
            last = m.group
            out.push(m)
        }
        return out
    }
    readonly property var current: { for (let i = 0; i < models.length; ++i) if (models[i].id === currentId) return models[i]; return null }

    ComboBox {
        id: box
        Layout.fillWidth: true
        model: picker.models
        textRole: "name"
        valueRole: "id"
        displayText: picker.current ? picker.current.name
                   : picker.currentId.startsWith("full.") ? "CFD · Lattice Boltzmann · Custom"
                   : picker.currentId.startsWith("ns.") ? "CFD · Navier–Stokes FV · Custom" : "Custom"
        currentIndex: picker.models.indexOf(picker.current)
        onActivated: (i) => picker.picked(picker.models[i].id)
        delegate: ItemDelegate {
            required property var modelData
            required property int index
            width: ListView.view ? ListView.view.width : 300
            enabled: !modelData.full || modelData.group === "ns" || App.fullAvailable
            highlighted: box.highlightedIndex === index
            contentItem: ColumnLayout {
                spacing: 1
                ColumnLayout {
                    visible: modelData.firstInGroup && modelData.group !== "custom"
                    Layout.fillWidth: true
                    Layout.bottomMargin: Theme.s1
                    spacing: 1
                    Label { text: modelData.groupLabel.toUpperCase(); font.pixelSize: Theme.micro + 1; font.weight: Font.DemiBold; font.letterSpacing: 0.6
                            color: modelData.full ? Theme.cfd : Theme.accent }
                    Label { text: modelData.groupSummary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.caption; color: Theme.textFaint }
                }
                Label { text: modelData.name; font.weight: Font.DemiBold; color: modelData.full ? Theme.cfd : Theme.text }
                Label { text: modelData.summary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.caption; color: Theme.textMuted }
            }
        }
    }
    Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: Theme.textMuted; font.pixelSize: Theme.caption
        text: picker.current ? picker.current.summary
            : picker.currentId.startsWith("full.") ? "GPU lattice-Boltzmann with hand-tuned CFD settings."
            : picker.currentId.startsWith("ns.") ? "GPU finite-volume Navier–Stokes (URANS) with hand-tuned CFD settings."
            : "Custom combination of fast-model effects."
    }
}
