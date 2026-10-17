import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Aero model list shared by FLY and EVOLVE: fast profiles, Full CFD presets and Custom (App.aeroModels),
// with the selected model's one-line summary underneath.
ColumnLayout {
    id: picker
    property string currentId
    signal picked(string id)
    spacing: Theme.s1
    readonly property var models: App.aeroModels
    readonly property var current: { for (let i = 0; i < models.length; ++i) if (models[i].id === currentId) return models[i]; return null }

    ComboBox {
        id: box
        Layout.fillWidth: true
        model: picker.models
        textRole: "name"
        valueRole: "id"
        displayText: picker.current ? picker.current.name : picker.currentId.startsWith("full.") ? "Full CFD · Custom" : "Custom"
        currentIndex: picker.models.indexOf(picker.current)
        onActivated: (i) => picker.picked(picker.models[i].id)
        delegate: ItemDelegate {
            required property var modelData
            required property int index
            width: ListView.view ? ListView.view.width : 300
            enabled: !modelData.full || App.fullAvailable
            highlighted: box.highlightedIndex === index
            contentItem: ColumnLayout {
                spacing: 1
                Label { text: modelData.name; font.weight: Font.DemiBold; color: modelData.full ? Theme.cfd : Theme.text }
                Label { text: modelData.summary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.caption; color: Theme.textMuted }
            }
        }
    }
    Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: Theme.textMuted; font.pixelSize: Theme.caption
        text: picker.current ? picker.current.summary : picker.currentId.startsWith("full.") ? "GPU lattice-Boltzmann with hand-tuned CFD settings." : "Custom combination of fast-model effects."
    }
}
