import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

// EVOLVE ① › Training worlds: the worlds every candidate is tested in, and how each generation uses them.
// One world trains a specialist; several (hills, islands, the city…) train a controller that copes with all of them.
// Reward scripts see the episode's world as ctx.info.world (index in this list) and ctx.info.worldCount.
ColumnLayout {
    id: tw
    spacing: Theme.s2
    readonly property var ev: EvolveModel
    readonly property var worlds: ev.worlds
    readonly property var schedule: ev.worldSchedule
    readonly property int flights: Math.max(1, ev.get("episode.episodesPerCandidate") || 1)
    readonly property int perGeneration: worlds.length <= 1 ? 1 : schedule.mode === "rotate" ? 1
                                       : schedule.mode === "sample" ? Math.min(schedule.perGeneration, worlds.length) : worlds.length
    property int replacing: -1   // row whose "Change" menu is open (-1: the Add menu)

    function times(n) { return n === 1 ? qsTr("once") : qsTr("%1 times").arg(n) }
    function tint(kind) { return kind === "flat" ? Theme.separator : kind === "open" ? Theme.tabTint["WORLD"] : kind === "embedded" ? Theme.tabTint["EVOLVE"] : Theme.accent }
    function pick(kind, arg) {
        if (replacing >= 0) ev.replaceWorld(replacing, kind, arg || "")
        else ev.addWorld(kind, arg || "")
    }
    function showMenu(row, anchor) { replacing = row; worldMenu.popup(anchor, 0, anchor.height) }

    // ---- the list
    Repeater {
        model: tw.worlds
        delegate: Rectangle {
            id: rowItem
            required property var modelData
            required property int index
            Layout.fillWidth: true
            implicitHeight: rowLayout.implicitHeight + Theme.s2 * 2
            radius: Theme.radius
            color: Theme.card
            border.color: modelData.missing ? Theme.bad : Theme.separator
            RowLayout {
                id: rowLayout
                anchors.fill: parent; anchors.margins: Theme.s2
                spacing: Theme.s2
                Rectangle { width: 4; Layout.fillHeight: true; radius: 2; color: tw.tint(rowItem.modelData.kind) }
                Label { text: rowItem.index + 1; color: Theme.textFaint; font.pixelSize: Theme.caption; font.family: Theme.mono
                        HoverHandler { id: numHover }
                        ToolTip.visible: numHover.hovered; ToolTip.delay: Theme.tooltipDelay
                        ToolTip.text: qsTr("Reward scripts see this world as ctx.info.world = %1").arg(rowItem.index) }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Label { Layout.fillWidth: true; elide: Text.ElideRight; font.weight: Font.DemiBold
                            text: rowItem.modelData.kind === "open" ? qsTr("Open world · %1").arg(WorldModel.name) : rowItem.modelData.label }
                    Label { Layout.fillWidth: true; elide: Text.ElideMiddle; font.pixelSize: Theme.caption
                            color: rowItem.modelData.missing ? Theme.bad : Theme.textFaint
                            text: rowItem.modelData.missing ? qsTr("File not found: %1").arg(rowItem.modelData.detail)
                                : rowItem.modelData.kind === "open" ? qsTr("As it is in WORLD when training starts") : rowItem.modelData.detail }
                }
                ToolButton { text: qsTr("Change"); font.pixelSize: Theme.small; onClicked: tw.showMenu(rowItem.index, this) }
                ToolButton {
                    visible: tw.worlds.length > 1
                    text: "✕"; font.pixelSize: Theme.small
                    onClicked: tw.ev.removeWorld(rowItem.index)
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Remove from training")
                }
            }
        }
    }
    Button {
        id: addBtn
        Layout.fillWidth: true
        text: qsTr("+ Add a world")
        onClicked: tw.showMenu(-1, addBtn)
        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay
        ToolTip.text: qsTr("Train in several worlds so the result works in all of them")
    }

    // ---- how generations use them
    ColumnLayout {
        visible: tw.worlds.length > 1
        Layout.fillWidth: true
        spacing: Theme.s1
        Label { text: qsTr("Each generation"); color: Theme.textMuted; font.pixelSize: Theme.small }
        PwSegmented {
            Layout.fillWidth: true
            readonly property var modes: ["all", "rotate", "sample"]
            model: [{ text: qsTr("Every world"), tip: qsTr("Every candidate flies in every world: the most robust, costs the most") },
                    { text: qsTr("One, in turn"), tip: qsTr("All candidates fly in one world, the next world next generation: cheap, scores jump between worlds") },
                    { text: qsTr("Random pick"), tip: qsTr("A random set of worlds each generation, the same for every candidate") }]
            currentIndex: Math.max(0, modes.indexOf(tw.schedule.mode))
            onActivated: (i) => tw.ev.setWorldSchedule(modes[i], tw.schedule.perGeneration)
        }
        PwPropertyRow {
            visible: tw.schedule.mode === "sample"
            label: qsTr("Worlds"); tip: qsTr("How many worlds each generation flies in"); Layout.fillWidth: true
            SpinBox { from: 1; to: tw.worlds.length; value: Math.min(tw.schedule.perGeneration, tw.worlds.length); editable: true
                      onValueModified: tw.ev.setWorldSchedule("sample", value) }
        }
    }
    Label {
        Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.textMuted; font.pixelSize: Theme.caption
        text: tw.worlds.length <= 1
              ? qsTr("Each candidate flies %1 per generation in this world.").arg(tw.times(tw.flights))
              : tw.perGeneration === 1
                ? qsTr("Each candidate flies %1 per generation, in one of the %2 worlds.").arg(tw.times(tw.flights)).arg(tw.worlds.length)
                : qsTr("Each candidate flies %1 in each of %2 worlds per generation, %3 flights in all. The score combines them (Aggregate, under Advanced).")
                    .arg(tw.times(tw.flights)).arg(tw.perGeneration).arg(tw.flights * tw.perGeneration)
    }

    // ---- add / change menu: same choices as FLY's world picker, plus embedding and files elsewhere
    Menu {
        id: worldMenu
        Repeater {
            model: WorldFlow.choices()
            MenuItem {
                required property var modelData
                text: modelData.kind === "open" ? qsTr("Open world (%1)").arg(WorldModel.name) : modelData.label
                onTriggered: tw.pick(modelData.kind, modelData.name)
            }
        }
        Menu { title: qsTr("Built-in city")
            MenuItem { text: qsTr("Manhattan (Midtown)"); onTriggered: tw.pick("city", "manhattan") }
            MenuItem { text: qsTr("Los Angeles (Downtown)"); onTriggered: tw.pick("city", "losangeles") }
            MenuItem { text: qsTr("Tel Aviv (Coast)"); onTriggered: tw.pick("city", "telaviv") }
            MenuItem { text: qsTr("Dubai (Downtown)"); onTriggered: tw.pick("city", "dubai") } }
        MenuSeparator {}
        MenuItem { text: qsTr("Embedded copy of the open world"); onTriggered: tw.pick("embedded")
                   ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Stored inside the experiment, so it travels with it") }
        MenuItem { text: qsTr("World file…"); onTriggered: fileDlg.open() }
        MenuItem { text: qsTr("Manage saved worlds…"); onTriggered: WorldFlow.manage() }
    }
    FileDialog {
        id: fileDlg
        title: qsTr("Choose a world file")
        nameFilters: [qsTr("World (*.json)")]
        currentFolder: (Qt.platform.os === "windows" ? "file:///" : "file://") + WorldModel.libraryDir
        onAccepted: tw.pick("file", selectedFile.toString())
    }
}
