import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// FLY › World: one list for where to fly — flat ground, the world open in WORLD, or any saved world (picking a saved
// world opens it in WORLD, asking first about unsaved edits), plus the saved-worlds manager.
ComboBox {
    id: box
    readonly property var entries: WorldFlow.choices().concat([{ kind: "manage", name: "", label: qsTr("Manage saved worlds…"), detail: "" }])
    model: entries
    textRole: "label"
    currentIndex: App.flyInWorld ? 1 : 0
    onActivated: (i) => {
        const e = entries[i]
        if (e.kind === "flat") App.flyInWorld = false
        else if (e.kind === "open") App.flyInWorld = true
        else if (e.kind === "saved") WorldFlow.open(e.name, () => App.flyInWorld = true)
        else WorldFlow.manage()
        currentIndex = Qt.binding(() => App.flyInWorld ? 1 : 0)
    }
    delegate: ItemDelegate {
        required property var modelData
        required property int index
        width: ListView.view ? ListView.view.width : 280
        highlighted: box.highlightedIndex === index
        contentItem: ColumnLayout {
            spacing: 0
            Rectangle {   // separators: before saved worlds and before the manager entry
                visible: index > 0 && (modelData.kind === "manage" || (modelData.kind === "saved" && box.entries[index - 1].kind !== "saved"))
                Layout.fillWidth: true; Layout.bottomMargin: Theme.s1; height: 1; color: Theme.separator
            }
            Label { text: modelData.label; font.weight: modelData.kind === "manage" ? Font.Normal : Font.DemiBold
                    color: modelData.kind === "manage" ? Theme.accent : Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
            Label { visible: modelData.detail !== ""; text: modelData.detail; color: Theme.textFaint; font.pixelSize: Theme.caption }
        }
    }
}
