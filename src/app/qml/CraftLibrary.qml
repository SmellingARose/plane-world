import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// BUILD › Craft library: every built-in and saved craft as a picture card. Click (or Return) opens a craft; your own
// crafts can be renamed, duplicated and moved to the Trash (Delete asks first). Type to search; ←↑→↓ move.
// Pictures come from App.libraryThumbnails (rendered offscreen and cached; a placeholder shows until one is ready).
Popup {
    id: lib
    signal openFileRequested()
    property string query: ""
    property int filter: 0                 // 0 all, 1 built-in, 2 yours
    readonly property var all: App.library
    readonly property var shown: {
        const q = query.trim().toLowerCase()
        const r = []
        for (let i = 0; i < all.length; ++i) {
            const e = all[i]
            if (filter === 1 && !e.builtIn) continue
            if (filter === 2 && e.builtIn) continue
            if (q !== "" && (e.name + " " + kindName(e.kind) + " " + (e.builtIn ? "built-in" : "yours")).toLowerCase().indexOf(q) < 0) continue
            r.push(i)
        }
        return r
    }
    readonly property int yoursCount: all.filter(e => !e.builtIn).length
    readonly property var current: grid.currentIndex >= 0 && grid.currentIndex < shown.length ? all[shown[grid.currentIndex]] : null
    readonly property int currentIndex: grid.currentIndex >= 0 && grid.currentIndex < shown.length ? shown[grid.currentIndex] : -1

    function kindName(k) { return ({ plane: "Plane", rotor: "Multirotor", rocket: "Rocket", ground: "Ground vehicle" })[k] || "Craft" }
    function massText(kg) { return kg >= 1000 ? (kg / 1000).toFixed(kg >= 10000 ? 0 : 1) + " t" : (kg >= 100 ? Math.round(kg) : kg.toFixed(1)) + " kg" }
    function isOpen(e) { return e.builtIn ? (App.filePath === "" && e.name === App.craftName) : e.path === App.filePath }
    function openEntry(i) { if (i < 0) return; close(); App.loadLibraryCraft(i) }
    // the hint bar's Ctrl+D / F2 work wherever the focus is in the library (it usually starts in the search box)
    Shortcut { sequence: "Ctrl+D"; enabled: lib.opened && !renameDlg.opened && !delConfirm.opened; onActivated: lib.duplicate(lib.currentIndex) }
    Shortcut { sequence: "F2"; enabled: lib.opened && !renameDlg.opened && !delConfirm.opened; onActivated: lib.askRename(lib.currentIndex) }
    function askDelete(i) {
        if (i < 0) return
        if (all[i].builtIn) { notice.text = "Built-in crafts can't be deleted. Duplicate one to make it yours."; return }
        delConfirm.target = i; delConfirm.open()
    }
    function askRename(i) {
        if (i < 0) return
        if (all[i].builtIn) { notice.text = "Built-in crafts can't be renamed. Duplicate one to make it yours."; return }
        renameDlg.target = i; renameDlg.open()
    }
    function duplicate(i) {
        const n = App.duplicateLibraryCraft(i)
        if (n < 0) return
        query = ""; search.text = ""; if (filter === 1) filter = 0
        select(n)
    }
    function select(libIndex) {
        const k = shown.indexOf(libIndex)
        grid.currentIndex = k >= 0 ? k : (shown.length > 0 ? 0 : -1)
        grid.positionViewAtIndex(grid.currentIndex, GridView.Contain)
    }

    modal: true
    focus: true
    dim: true
    padding: 0
    width: parent ? Math.min(1000, parent.width - Theme.s5 * 2) : 800
    height: parent ? Math.min(760, parent.height - Theme.s5 * 2) : 600
    x: parent ? (parent.width - width) / 2 : 0
    y: parent ? (parent.height - height) / 2 : 0
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    Overlay.modal: Rectangle { color: Theme.overlay }
    enter: Transition { ParallelAnimation {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.fast; easing.type: Theme.easing }
        NumberAnimation { property: "scale"; from: 0.98; to: 1; duration: Theme.normal; easing.type: Theme.easing } } }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: Theme.fast } }
    onAboutToShow: {
        App.requestLibraryThumbnails()
        query = ""; search.text = ""; notice.text = ""
        let open = -1
        for (let i = 0; i < all.length; ++i) if (isOpen(all[i])) { open = i; break }
        select(open)
        grid.forceActiveFocus()
    }
    // keep the selection on the same craft when the list changes (rename, duplicate, delete, a picture arriving)
    property int keep: -1
    onShownChanged: if (opened) Qt.callLater(() => { if (keep >= 0) select(keep); keep = -1 })

    background: Rectangle { radius: Theme.radiusLarge; color: Theme.surfaceRaised; border.color: Theme.separator }

    contentItem: ColumnLayout {
        spacing: 0
        // ---- header: title, search, filter
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Theme.s4
            Layout.bottomMargin: Theme.s3
            spacing: Theme.s3
            ColumnLayout {
                spacing: 0
                Label { text: "Craft library"; font.pixelSize: Theme.title; font.weight: Font.DemiBold }
                Label { text: lib.all.length + " crafts · " + lib.yoursCount + " yours"; color: Theme.textFaint; font.pixelSize: Theme.caption }
            }
            Item { Layout.fillWidth: true }
            TextField {
                id: search
                Layout.preferredWidth: Math.min(260, lib.width * 0.32)
                placeholderText: "Search crafts"
                selectByMouse: true
                onTextChanged: { lib.query = text; grid.currentIndex = lib.shown.length > 0 ? 0 : -1 }
                Keys.onDownPressed: grid.forceActiveFocus()
                Keys.onReturnPressed: lib.openEntry(lib.currentIndex)
                Keys.onEnterPressed: lib.openEntry(lib.currentIndex)
                Keys.onEscapePressed: (e) => { if (text !== "") { text = ""; e.accepted = true } else lib.close() }
            }
            PwSegmented {
                Layout.fillWidth: false
                Layout.preferredWidth: 230
                model: ["All", "Built-in", "Yours"]
                currentIndex: lib.filter
                onActivated: (i) => { lib.filter = i; grid.currentIndex = lib.shown.length > 0 ? 0 : -1; grid.forceActiveFocus() }
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }

        // ---- cards
        GridView {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3
            topMargin: Theme.s3; bottomMargin: Theme.s3
            clip: true
            model: lib.shown
            readonly property int columns: Math.max(1, Math.floor(width / 210))
            cellWidth: Math.floor(width / columns)
            cellHeight: Math.round((cellWidth - Theme.s3) * 0.625) + 50 + Theme.s3
            keyNavigationEnabled: true
            highlightFollowsCurrentItem: false
            boundsBehavior: Flickable.StopAtBounds
            activeFocusOnTab: true
            ScrollBar.vertical: ScrollBar {}
            Keys.onReturnPressed: lib.openEntry(lib.currentIndex)
            Keys.onEnterPressed: lib.openEntry(lib.currentIndex)
            Keys.onDeletePressed: lib.askDelete(lib.currentIndex)
            Keys.onPressed: (e) => {
                if (e.key === Qt.Key_Backspace) { lib.askDelete(lib.currentIndex); e.accepted = true }
                else if (e.text.length === 1 && e.text > " " && !(e.modifiers & (Qt.ControlModifier | Qt.MetaModifier))) {
                    search.text += e.text; search.forceActiveFocus(); e.accepted = true   // type to search
                }
            }

            delegate: Item {
                id: cell
                required property int modelData
                required property int index
                readonly property var entry: lib.all[modelData] || ({})
                readonly property bool selected: GridView.isCurrentItem
                readonly property bool openNow: lib.isOpen(entry)
                readonly property string pic: App.libraryThumbnails[entry.key] || ""
                width: grid.cellWidth
                height: grid.cellHeight

                Rectangle {
                    id: card
                    anchors.fill: parent
                    anchors.margins: Theme.s3 / 2
                    radius: Theme.radius
                    color: hover.hovered ? Theme.alpha(Theme.text, Theme.dark ? 0.07 : 0.03) : Theme.card
                    border.width: cell.selected ? 2 : 1
                    border.color: cell.selected ? Theme.accent : Theme.separator
                    Behavior on color { ColorAnimation { duration: Theme.fast } }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: cell.selected ? 2 : 1
                        spacing: 0
                        // picture
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.round(width * 0.625)
                            radius: Theme.radius - 1
                            color: Theme.surfaceSunken
                            clip: true
                            Text {
                                anchors.centerIn: parent
                                visible: img.status !== Image.Ready
                                text: App.libraryThumbnailsUnavailable ? lib.kindName(cell.entry.kind) : "Drawing picture…"
                                color: Theme.textFaint; font.pixelSize: Theme.caption
                            }
                            Image {
                                id: img
                                anchors.fill: parent
                                source: cell.pic
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                smooth: true; mipmap: true
                                sourceSize.width: 480
                                opacity: status === Image.Ready ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: Theme.normal } }
                            }
                            Rectangle {
                                anchors.left: parent.left; anchors.top: parent.top; anchors.margins: Theme.s2
                                radius: height / 2
                                implicitWidth: badge.implicitWidth + Theme.s2 * 2; implicitHeight: badge.implicitHeight + Theme.s0 * 2
                                color: cell.entry.builtIn ? Theme.hudStrong : Theme.alpha(Theme.tabTint["BUILD"], 0.92)
                                Text { id: badge; anchors.centerIn: parent; text: cell.entry.builtIn ? "Built-in" : "Yours"
                                       color: "#ffffff"; font.pixelSize: Theme.micro + 1; font.weight: Font.DemiBold }
                            }
                            Rectangle {
                                visible: cell.openNow
                                anchors.right: parent.right; anchors.top: parent.top; anchors.margins: Theme.s2
                                radius: height / 2
                                implicitWidth: openLbl.implicitWidth + Theme.s2 * 2; implicitHeight: openLbl.implicitHeight + Theme.s0 * 2
                                color: Theme.accent
                                Text { id: openLbl; anchors.centerIn: parent; text: App.dirty ? "Open · edited" : "Open now"
                                       color: Theme.accentText; font.pixelSize: Theme.micro + 1; font.weight: Font.DemiBold }
                            }
                        }
                        // name, facts, actions
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s1
                            Layout.topMargin: Theme.s2
                            spacing: Theme.s1
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1
                                Label { Layout.fillWidth: true; text: cell.entry.name || ""; elide: Text.ElideRight
                                        font.pixelSize: Theme.body; font.weight: Font.DemiBold }
                                Label { Layout.fillWidth: true; elide: Text.ElideRight; color: Theme.textMuted; font.pixelSize: Theme.caption
                                        text: lib.kindName(cell.entry.kind) + " · " + cell.entry.parts + (cell.entry.parts === 1 ? " part · " : " parts · ") + lib.massText(cell.entry.mass || 0) }
                            }
                            ToolButton {
                                id: more
                                text: "⋯"
                                font.pixelSize: Theme.title
                                focusPolicy: Qt.NoFocus
                                implicitWidth: 30; implicitHeight: 30   // showing it on hover must not move the text
                                visible: hover.hovered || cell.selected || menu.visible   // hidden: the facts get the width
                                onClicked: { grid.currentIndex = cell.index; menu.popup(more, 0, more.height) }
                                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: "More actions"
                            }
                        }
                        Item { Layout.fillHeight: true }
                    }
                    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: { grid.currentIndex = cell.index; lib.openEntry(cell.modelData) }
                    }
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onTapped: { grid.currentIndex = cell.index; menu.popup() }
                    }
                }
                Menu {
                    id: menu
                    MenuItem { text: "Open"; onTriggered: lib.openEntry(cell.modelData) }
                    MenuItem { text: cell.entry.builtIn ? "Duplicate into your crafts" : "Duplicate"; onTriggered: { lib.keep = -1; lib.duplicate(cell.modelData) } }
                    MenuItem { text: "Rename…"; visible: !cell.entry.builtIn; height: visible ? implicitHeight : 0
                               onTriggered: lib.askRename(cell.modelData) }
                    MenuSeparator { visible: !cell.entry.builtIn; height: visible ? implicitHeight : 0 }
                    MenuItem { text: "Move to Trash…"; visible: !cell.entry.builtIn; height: visible ? implicitHeight : 0
                               onTriggered: lib.askDelete(cell.modelData) }
                }
            }

            PwEmptyState {
                anchors.centerIn: parent
                width: Math.min(360, parent.width - Theme.s5 * 2)
                visible: lib.shown.length === 0
                title: lib.query !== "" ? "Nothing matches “" + lib.query + "”" : "None of your own crafts yet"
                text: lib.query !== "" ? "Try another word, or clear the search." : "Save the craft you're building and it shows up here."
                shortcut: lib.query !== "" ? "" : "Ctrl+Shift+L"
                shortcutLabel: "Save to library"
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }

        // ---- footer: notice or keyboard help, file actions
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Theme.s3
            Layout.leftMargin: Theme.s4
            spacing: Theme.s2
            Label {
                id: notice
                visible: text !== ""
                Layout.fillWidth: true
                elide: Text.ElideRight
                color: Theme.warn
                font.pixelSize: Theme.caption
            }
            Flow {
                visible: notice.text === ""
                Layout.fillWidth: true
                spacing: Theme.s3
                Repeater {
                    model: [["←↑→↓", "Move"], ["Return", "Open"], ["F2", "Rename"], ["Ctrl+D", "Duplicate"], ["Delete", "Move to Trash"]]
                    Row {
                        required property var modelData
                        spacing: Theme.s1
                        KeyHint { sequence: modelData[0]; raw: modelData[0] !== "Ctrl+D" }
                        Text { text: modelData[1]; color: Theme.textFaint; font.pixelSize: Theme.caption; anchors.verticalCenter: parent.verticalCenter }
                    }
                }
            }
            Button { text: "New craft"; font.pixelSize: Theme.small; onClicked: { lib.close(); App.newCraft() } }
            Button { text: "Open file…"; font.pixelSize: Theme.small; onClicked: { lib.close(); lib.openFileRequested() } }
        }
    }

    // ---- confirmations (inside the app, not native dialogs)
    Dialog {
        id: delConfirm
        property int target: -1
        readonly property var entry: target >= 0 && target < lib.all.length ? lib.all[target] : null
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(420, parent ? parent.width - Theme.s6 * 2 : 420)
        modal: true
        title: entry ? "Move “" + entry.name + "” to the Trash?" : ""
        standardButtons: Dialog.Cancel | Dialog.Ok
        Component.onCompleted: standardButton(Dialog.Ok).text = "Move to Trash"
        Label {
            width: parent.width
            wrapMode: Text.WordWrap
            text: delConfirm.entry && lib.isOpen(delConfirm.entry)
                  ? "It's open right now: it stays open here, but unsaved. You can restore the file from the Trash."
                  : "It leaves your craft library. You can restore the file from the Trash."
        }
        onOpened: standardButton(Dialog.Ok).forceActiveFocus()
        onAccepted: {
            const k = grid.currentIndex
            if (App.deleteLibraryCraft(target)) { lib.keep = -1; Qt.callLater(() => { grid.currentIndex = Math.min(k, lib.shown.length - 1) }) }
        }
        onClosed: grid.forceActiveFocus()
    }
    Dialog {
        id: renameDlg
        property int target: -1
        readonly property string problem: target >= 0 ? App.libraryNameProblem(target, nameField.text) : ""
        readonly property bool unchanged: target >= 0 && target < lib.all.length && nameField.text.trim() === lib.all[target].name
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(420, parent ? parent.width - Theme.s6 * 2 : 420)
        modal: true
        title: "Rename craft"
        standardButtons: Dialog.Cancel | Dialog.Ok
        onAboutToShow: { nameField.text = target >= 0 ? lib.all[target].name : ""; nameField.selectAll(); nameField.forceActiveFocus() }
        onOpened: { nameField.selectAll(); nameField.forceActiveFocus() }
        function commit() {
            if (problem !== "") return
            if (!unchanged) {
                const name = nameField.text.trim()
                if (App.renameLibraryCraft(target, name)) {
                    for (let i = 0; i < lib.all.length; ++i) if (!lib.all[i].builtIn && lib.all[i].name === name) { lib.keep = i; break }
                }
            }
            close()
        }
        onAccepted: commit()
        ColumnLayout {
            width: parent.width
            spacing: Theme.s2
            TextField {
                id: nameField
                Layout.fillWidth: true
                selectByMouse: true
                placeholderText: "Craft name"
                Keys.onReturnPressed: renameDlg.commit()
                Keys.onEnterPressed: renameDlg.commit()
            }
            Label { text: renameDlg.problem; visible: text !== "" && !renameDlg.unchanged; color: Theme.bad; font.pixelSize: Theme.caption
                    wrapMode: Text.WordWrap; Layout.fillWidth: true }
        }
        Component.onCompleted: {
            standardButton(Dialog.Ok).text = "Rename"
            standardButton(Dialog.Ok).enabled = Qt.binding(() => renameDlg.problem === "" || renameDlg.unchanged)
        }
        onClosed: grid.forceActiveFocus()
    }
}
