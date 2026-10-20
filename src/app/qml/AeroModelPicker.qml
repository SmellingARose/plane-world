import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Aero model list shared by FLY and EVOLVE (App.aeroModels): Fast (analytic) profiles | Custom. The group starts with
// a header that says what the method is, what it costs and how accurate it is; the selected model's one-line summary
// sits underneath.
ColumnLayout {
    id: picker
    property string currentId
    signal picked(string id)
    spacing: Theme.s1
    readonly property var models: {
        const all = App.aeroModels, out = []
        let last = ""
        for (let i = 0; i < all.length; ++i) {
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
        displayText: picker.current ? picker.current.name : "Custom"
        currentIndex: picker.models.indexOf(picker.current)
        onActivated: (i) => picker.picked(picker.models[i].id)
        delegate: ItemDelegate {
            required property var modelData
            required property int index
            width: ListView.view ? ListView.view.width : 300
            highlighted: box.highlightedIndex === index
            contentItem: ColumnLayout {
                spacing: 1
                ColumnLayout {
                    visible: modelData.firstInGroup && modelData.group !== "custom"
                    Layout.fillWidth: true
                    Layout.bottomMargin: Theme.s1
                    spacing: 1
                    Label { text: modelData.groupLabel.toUpperCase(); font.pixelSize: Theme.micro + 1; font.weight: Font.DemiBold; font.letterSpacing: 0.6
                            color: Theme.accent }
                    Label { text: modelData.groupSummary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.caption; color: Theme.textFaint }
                }
                Label { text: modelData.name; font.weight: Font.DemiBold; color: Theme.text }
                Label { text: modelData.summary; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: Theme.caption; color: Theme.textMuted }
            }
        }
    }
    Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: Theme.textMuted; font.pixelSize: Theme.caption
        text: picker.current ? picker.current.summary : "Custom combination of fast-model effects."
    }
}
