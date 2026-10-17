import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

// WORLD inspector: file, terrain source, brush, water, vegetation, objects, sky.
Rectangle {
    id: root
    property var viewport: null
    color: Theme.surface
    Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.separator }

    readonly property var layers: ["Grass", "Rock", "Sand / dirt", "Snow"]
    readonly property var species: ["Pine", "Oak", "Birch", "Palm"]
    readonly property bool sculptTool: ["raise", "lower", "smooth", "flatten", "paint"].indexOf(WorldModel.tool) >= 0
    readonly property bool natureTool: ["trees", "erase", "grass"].indexOf(WorldModel.tool) >= 0

    function openFile() { openDlg.open() }
    function saveFileAs() { saveDlg.open() }
    FileDialog {
        id: openDlg
        title: "Open world"
        nameFilters: ["World (*.json)"]
        currentFolder: "file://" + WorldModel.libraryDir
        onAccepted: WorldModel.open(selectedFile)
    }
    FileDialog {
        id: saveDlg
        title: "Save world as"
        fileMode: FileDialog.SaveFile
        nameFilters: ["World (*.json)"]
        currentFolder: "file://" + WorldModel.libraryDir
        onAccepted: WorldModel.saveAs(selectedFile)
    }
    FileDialog {
        id: hmDlg
        title: "Import heightmap"
        nameFilters: ["Images (*.png *.jpg *.jpeg)", "Raw 16-bit (*.r16 *.raw)"]
        onAccepted: { WorldModel.heightmapPath = selectedFile.toString(); WorldModel.terrainKind = "heightmap" }
    }
    Shortcut { sequences: [StandardKey.Open]; enabled: root.visible; onActivated: openDlg.open() }
    Shortcut { sequence: "Ctrl+Shift+S"; enabled: root.visible; onActivated: saveDlg.open() }

    ScrollView {
        id: sv
        anchors.fill: parent
        anchors.leftMargin: 1
        contentWidth: availableWidth
        ColumnLayout {
            width: sv.availableWidth
            spacing: 0

            // ---- header
            ColumnLayout { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                Layout.fillWidth: true
                Layout.margins: Theme.s4
                Layout.bottomMargin: Theme.s2
                spacing: Theme.s2
                RowLayout {
                    spacing: Theme.s2
                    Rectangle { width: 4; Layout.fillHeight: true; radius: 2; color: Theme.tabTint["WORLD"] }
                    TextField {
                        Layout.fillWidth: true
                        text: WorldModel.name
                        font.pixelSize: Theme.title; font.weight: Font.DemiBold
                        onEditingFinished: WorldModel.name = text
                        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: "World name"
                    }
                    Rectangle { visible: WorldModel.dirty; width: 8; height: 8; radius: 4; color: Theme.warn
                        ToolTip.visible: dirtyMa.containsMouse; ToolTip.text: "Unsaved changes"
                        MouseArea { id: dirtyMa; anchors.fill: parent; hoverEnabled: true } }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.s1
                    Button { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.minimumWidth: 0
                        text: "New"
                        onClicked: newMenu.popup()
                        Menu {
                            id: newMenu
                            MenuItem { text: "Flat"; onTriggered: WorldModel.newWorld("flat") }
                            MenuItem { text: "Rolling hills"; onTriggered: WorldModel.newWorld("hills") }
                            MenuItem { text: "Islands"; onTriggered: WorldModel.newWorld("islands") }
                            MenuItem { text: "Mountains"; onTriggered: WorldModel.newWorld("mountains") }
                        }
                    }
                    Button { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.minimumWidth: 0
                        text: "Open"
                        onClicked: { WorldModel.refreshLibrary(); openMenu.popup() }
                        Menu {
                            id: openMenu
                            Repeater {
                                model: WorldModel.library
                                MenuItem { required property string modelData; text: modelData; onTriggered: WorldModel.open(modelData) }
                            }
                            MenuItem { text: "No saved worlds"; enabled: false; visible: WorldModel.library.length === 0; height: visible ? implicitHeight : 0 }
                            MenuSeparator {}
                            MenuItem { text: "Browse…  " + Theme.shortcutText("Ctrl+O"); onTriggered: openDlg.open() }
                        }
                    }
                    Button { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.minimumWidth: 0; text: "Save"; onClicked: WorldModel.save(); enabled: !WorldModel.busy
                        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.tip("Save to the world library", "Ctrl+S") }
                    Button { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.minimumWidth: 0; text: "Save as…"; onClicked: saveDlg.open(); enabled: !WorldModel.busy }
                                        ToolButton { text: "↶"; enabled: WorldModel.canUndo; onClicked: WorldModel.undo()
                        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.tip("Undo " + WorldModel.undoText, "Ctrl+Z") }
                    ToolButton { text: "↷"; enabled: WorldModel.canRedo; onClicked: WorldModel.redo()
                        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.tip("Redo " + WorldModel.redoText, "Ctrl+Shift+Z") }
                }
                Label { Layout.fillWidth: true; text: WorldModel.terrainInfo; color: Theme.textFaint; font.pixelSize: Theme.caption; wrapMode: Text.WordWrap }
            }

            // ---- brush (context of the active tool)
            PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                title: WorldModel.tool === "orbit" ? "Tools" : "Brush · " + WorldModel.tool
                Layout.fillWidth: true
                Label {
                    visible: WorldModel.tool === "orbit"
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.textMuted; font.pixelSize: Theme.small
                    text: "Pick a tool from the palette above the viewport (or press its key) to sculpt, paint, plant or place. Orbit tool: the viewport only moves the camera."
                }
                PwSlider {
                    visible: root.sculptTool || root.natureTool
                    label: "Radius"; from: 2; to: 400; value: WorldModel.brushRadius; decimals: 0; unit: "m"; defaultValue: 40
                    tip: "Brush radius ( [ and ] change it in the viewport )"
                    onMoved: (v) => WorldModel.brushRadius = v
                }
                PwSlider {
                    visible: root.sculptTool || WorldModel.tool === "trees" || WorldModel.tool === "grass"
                    label: WorldModel.tool === "trees" ? "Density" : "Strength"; from: 0.5; to: 60; value: WorldModel.brushStrength; decimals: 1; defaultValue: 10
                    unit: ["raise", "lower"].indexOf(WorldModel.tool) >= 0 ? "m/s" : ""
                    onMoved: (v) => WorldModel.brushStrength = v
                }
                PwPropertyRow {
                    visible: WorldModel.tool === "paint"
                    label: "Material"
                    ComboBox { Layout.fillWidth: true; model: root.layers; currentIndex: WorldModel.paintLayer; onActivated: (i) => WorldModel.paintLayer = i }
                }
                PwPropertyRow {
                    visible: WorldModel.tool === "trees"
                    label: "Species"
                    ComboBox { Layout.fillWidth: true; model: ["Mix (weights below)"].concat(root.species)
                        currentIndex: WorldModel.treeSpecies + 1; onActivated: (i) => WorldModel.treeSpecies = i - 1 }
                }
                PwPropertyRow {
                    visible: WorldModel.tool === "prop"
                    label: "Prop"
                    ComboBox { id: propBox; Layout.fillWidth: true
                        model: ["box", "crate", "building", "tower", "ramp", "pylon"]
                        currentIndex: Math.max(0, model.indexOf(WorldModel.propKind))
                        onActivated: (i) => WorldModel.propKind = model[i] }
                }
                CheckBox { visible: WorldModel.tool === "prop"; text: "Breakable"; checked: WorldModel.propBreakable; onToggled: WorldModel.propBreakable = checked }
                PwSlider {
                    visible: WorldModel.tool === "lake"
                    label: "Lake radius"; from: 10; to: 1000; value: WorldModel.lakeRadius; decimals: 0; unit: "m"; defaultValue: 80
                    onMoved: (v) => WorldModel.lakeRadius = v
                }
                RowLayout {
                    visible: root.sculptTool
                    Button { text: "Clear sculpt & paint"; enabled: WorldModel.hasEdits; onClicked: WorldModel.clearEdits() }
                }
                RowLayout {
                    visible: root.natureTool
                    Button { text: "Clear strokes"; onClicked: WorldModel.clearVegetationStrokes() }
                }
            }

            // ---- terrain source
            PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                title: "Terrain"
                Layout.fillWidth: true
                hint: "Where the base heightfield comes from. Sculpt and paint edits are layered on top."
                PwSegmented {
                    model: [{ text: "Flat", tip: "Level ground" }, { text: "Procedural", tip: "Noise + erosion from a seed" },
                            { text: "Real", tip: "Real-world elevation (AWS terrain tiles)" }, { text: "Image", tip: "Import a heightmap image" }]
                    currentIndex: ["flat", "procedural", "realWorld", "heightmap"].indexOf(WorldModel.terrainKind)
                    onActivated: (i) => WorldModel.terrainKind = ["flat", "procedural", "realWorld", "heightmap"][i]
                }
                PwPropertyRow {
                    visible: WorldModel.terrainKind === "flat"
                    label: "Level"
                    PwNumberField { Layout.fillWidth: true; value: WorldModel.flatLevel; decimals: 1; suffix: " m"; onCommitted: (v) => WorldModel.flatLevel = v }
                }
                ColumnLayout {
                    visible: WorldModel.terrainKind === "procedural"
                    Layout.fillWidth: true
                    spacing: Theme.s1
                    PwPropertyRow {
                        label: "Seed"
                        RowLayout {
                            Layout.fillWidth: true
                            PwNumberField { Layout.fillWidth: true; value: WorldModel.seed; decimals: 0; step: 1; minimum: 1; onCommitted: (v) => WorldModel.seed = Math.round(v) }
                            ToolButton { text: "⚄"; onClicked: WorldModel.randomizeSeed()
                                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: "Random seed" }
                        }
                    }
                    PwPropertyRow {
                        label: "Size"
                        ComboBox { Layout.fillWidth: true
                            model: ["513 (fast)", "1025", "2049 (detailed)"]
                            readonly property var sizes: [513, 1025, 2049]
                            currentIndex: Math.max(0, sizes.indexOf(WorldModel.procSize))
                            onActivated: (i) => WorldModel.procSize = sizes[i] }
                    }
                    PwSlider { label: "Cell spacing"; from: 1; to: 32; value: WorldModel.procSpacing; decimals: 1; unit: "m"; defaultValue: 8
                        tip: "Metres between samples (world span = size × spacing)"; onMoved: (v) => WorldModel.procSpacing = v }
                    PwSlider { label: "Height"; from: 20; to: 4000; value: WorldModel.procHeight; decimals: 0; unit: "m"; defaultValue: 1200; onMoved: (v) => WorldModel.procHeight = v }
                    PwSlider { label: "Feature size"; from: 200; to: 20000; value: WorldModel.procFeature; decimals: 0; unit: "m"; defaultValue: 5000; onMoved: (v) => WorldModel.procFeature = v }
                    PwSlider { label: "Ridges"; from: 0; to: 1; value: WorldModel.procRidged; defaultValue: 0.6; onMoved: (v) => WorldModel.procRidged = v }
                    PwSlider { label: "Domain warp"; from: 0; to: 1; value: WorldModel.procWarp; defaultValue: 0.35; onMoved: (v) => WorldModel.procWarp = v }
                    PwSlider { label: "Sea fraction"; from: 0; to: 0.8; value: WorldModel.procSeaFraction; defaultValue: 0.12; onMoved: (v) => WorldModel.procSeaFraction = v }
                    PwSlider { label: "Erosion iterations"; from: 0; to: 600; step: 10; value: WorldModel.procErosion; decimals: 0; defaultValue: 120
                        tip: "Hydraulic erosion passes (GPU when available)"; onMoved: (v) => WorldModel.procErosion = Math.round(v) }
                }
                ColumnLayout {
                    visible: WorldModel.terrainKind === "realWorld"
                    Layout.fillWidth: true
                    spacing: Theme.s1
                    PwPropertyRow { label: "Place"
                        ComboBox { Layout.fillWidth: true
                            readonly property var places: [
                                { name: "Mount Rainier", lat: 46.85, lon: -121.76 }, { name: "Grand Canyon", lat: 36.10, lon: -112.11 },
                                { name: "Matterhorn", lat: 45.976, lon: 7.658 }, { name: "Yosemite Valley", lat: 37.745, lon: -119.59 },
                                { name: "Mount Fuji", lat: 35.36, lon: 138.73 }, { name: "Innsbruck", lat: 47.27, lon: 11.39 }]
                            model: places.map(p => p.name).concat(["Custom"])
                            currentIndex: { for (let i = 0; i < places.length; ++i)
                                if (Math.abs(places[i].lat - WorldModel.latitude) < 0.01 && Math.abs(places[i].lon - WorldModel.longitude) < 0.01) return i
                                return places.length }
                            onActivated: (i) => { if (i < places.length) WorldModel.setLocation(places[i].lat, places[i].lon, WorldModel.zoom) }
                        }
                    }
                    PwPropertyRow { label: "Latitude"; PwNumberField { Layout.fillWidth: true; value: WorldModel.latitude; decimals: 4; minimum: -85; maximum: 85; suffix: "°"; onCommitted: (v) => WorldModel.latitude = v } }
                    PwPropertyRow { label: "Longitude"; PwNumberField { Layout.fillWidth: true; value: WorldModel.longitude; decimals: 4; minimum: -180; maximum: 180; suffix: "°"; onCommitted: (v) => WorldModel.longitude = v } }
                    PwPropertyRow { label: "Zoom"
                        SpinBox { Layout.fillWidth: true; from: 8; to: 14; value: WorldModel.zoom; onValueModified: WorldModel.zoom = value
                            ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: "Tile zoom: higher = more detail, smaller area" } }
                    PwPropertyRow { label: "Radius"
                        SpinBox { Layout.fillWidth: true; from: 1; to: 4; value: WorldModel.radiusTiles; onValueModified: WorldModel.radiusTiles = value
                            textFromValue: (v) => v + " tiles" } }
                    Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.textFaint; font.pixelSize: Theme.caption
                        text: "Elevation from the public AWS Terrain Tiles; tiles are cached on disk." }
                }
                ColumnLayout {
                    visible: WorldModel.terrainKind === "heightmap"
                    Layout.fillWidth: true
                    spacing: Theme.s1
                    RowLayout {
                        Layout.fillWidth: true
                        Label { Layout.fillWidth: true; elide: Text.ElideMiddle; color: WorldModel.heightmapPath ? Theme.text : Theme.textFaint
                            text: WorldModel.heightmapPath ? WorldModel.heightmapPath.replace(/^file:\/\//, "") : "No image chosen" }
                        Button { text: "Choose…"; onClicked: hmDlg.open() }
                    }
                    PwPropertyRow { label: "m / pixel"; PwNumberField { Layout.fillWidth: true; value: WorldModel.metersPerPixel; decimals: 2; minimum: 0.1; onCommitted: (v) => WorldModel.metersPerPixel = v } }
                    PwPropertyRow { label: "Height scale"; PwNumberField { Layout.fillWidth: true; value: WorldModel.heightScale; decimals: 0; minimum: 1; suffix: " m"; onCommitted: (v) => WorldModel.heightScale = v } }
                }
                Button {
                    Layout.fillWidth: true
                    highlighted: true
                    enabled: !WorldModel.busy && (WorldModel.terrainKind !== "heightmap" || WorldModel.heightmapPath !== "")
                    text: WorldModel.busy ? WorldModel.busyText : (WorldModel.terrainKind === "realWorld" ? "Load terrain" : "Generate terrain")
                    onClicked: WorldModel.generate()
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay
                    ToolTip.text: Theme.tip("Rebuild the base terrain (edits, water, trees and props are kept)", "Ctrl+G")
                }
            }

            // ---- water
            PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                title: "Water"
                Layout.fillWidth: true
                expanded: false
                Switch { text: "Ocean"; checked: WorldModel.oceanEnabled; onToggled: WorldModel.oceanEnabled = checked }
                PwPropertyRow { label: "Sea level"; enabled: WorldModel.oceanEnabled
                    PwNumberField { Layout.fillWidth: true; value: WorldModel.seaLevel; decimals: 1; suffix: " m"; onCommitted: (v) => WorldModel.seaLevel = v } }
                PwSlider { enabled: WorldModel.oceanEnabled; label: "Wave wind"; from: 0.5; to: 30; value: WorldModel.waveWind; decimals: 1; unit: "m/s"; defaultValue: 8
                    tip: "Wind speed driving the ocean spectrum"; onCommitted: (v) => WorldModel.waveWind = v }
                PwSlider { enabled: WorldModel.oceanEnabled; label: "Wave direction"; from: 0; to: 360; value: WorldModel.waveDirection; decimals: 0; unit: "°"; defaultValue: 0
                    onCommitted: (v) => WorldModel.waveDirection = v }
                PwSlider { enabled: WorldModel.oceanEnabled; label: "Fetch"; from: 1; to: 1000; value: WorldModel.fetchKm; decimals: 0; unit: "km"; defaultValue: 100
                    tip: "Distance the wind blows over water (longer = bigger waves)"; onCommitted: (v) => WorldModel.fetchKm = v }
                RowLayout {
                    Layout.fillWidth: true
                    Label { Layout.fillWidth: true; color: Theme.textMuted; font.pixelSize: Theme.small
                        text: WorldModel.lakeCount + (WorldModel.lakeCount === 1 ? " lake" : " lakes") + " · " + WorldModel.riverCount + (WorldModel.riverCount === 1 ? " river" : " rivers") }
                    Button { text: "Add lake"; onClicked: WorldModel.tool = "lake"
                        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.tip("Lake tool: click the terrain", "K") }
                    Button { text: "Remove all"; enabled: WorldModel.lakeCount + WorldModel.riverCount > 0; onClicked: WorldModel.removeAllWater() }
                }
            }

            // ---- vegetation
            PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                title: "Vegetation"
                Layout.fillWidth: true
                expanded: false
                RowLayout {
                    Layout.fillWidth: true
                    Switch { text: "Trees & grass"; checked: WorldModel.vegEnabled; onToggled: WorldModel.vegEnabled = checked }
                    Item { Layout.fillWidth: true }
                    Label { text: WorldModel.treeCount.toLocaleString(Qt.locale(), "f", 0) + " trees"; color: Theme.textMuted; font.pixelSize: Theme.small }
                }
                PwSlider { enabled: WorldModel.vegEnabled; label: "Tree density"; from: 0; to: 200; value: WorldModel.treeDensity; decimals: 0; unit: "/ha"; defaultValue: 45
                    onCommitted: (v) => { WorldModel.treeDensity = v; WorldModel.regenerateVegetation() } }
                Repeater {
                    model: root.species
                    PwSlider {
                        required property string modelData
                        required property int index
                        enabled: WorldModel.vegEnabled
                        label: modelData; from: 0; to: 3; value: WorldModel.speciesWeights[index] || 0; defaultValue: 1
                        onCommitted: (v) => { const w = WorldModel.speciesWeights.slice(); w[index] = v; WorldModel.speciesWeights = w; WorldModel.regenerateVegetation() }
                    }
                }
                PwSlider { enabled: WorldModel.vegEnabled; label: "Grass density"; from: 0; to: 3; value: WorldModel.grassDensity; defaultValue: 1; onMoved: (v) => WorldModel.grassDensity = v }
                PwSlider { enabled: WorldModel.vegEnabled; label: "Grass height"; from: 0.05; to: 1.5; value: WorldModel.grassHeight; unit: "m"; defaultValue: 0.45; onMoved: (v) => WorldModel.grassHeight = v }
            }

            // ---- objects
            PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                title: "Objects (" + WorldModel.objects.length + ")"
                Layout.fillWidth: true
                expanded: false
                PwEmptyState {
                    visible: WorldModel.objects.length === 0
                    Layout.fillWidth: true
                    title: "No props yet"
                    text: "Choose the Prop tool and click the terrain."
                    shortcut: "P"; shortcutLabel: "Prop tool"
                }
                ListView {
                    id: objList
                    visible: WorldModel.objects.length > 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 220)
                    clip: true
                    model: WorldModel.objects
                    keyNavigationEnabled: true
                    activeFocusOnTab: true
                    Keys.onDeletePressed: if (currentIndex >= 0) WorldModel.removeObject(WorldModel.objects[currentIndex].id)
                    Keys.onPressed: (e) => { if (e.key === Qt.Key_Backspace && currentIndex >= 0) { WorldModel.removeObject(WorldModel.objects[currentIndex].id); e.accepted = true } }
                    delegate: ItemDelegate {
                        required property var modelData
                        required property int index
                        width: objList.width
                        highlighted: ListView.isCurrentItem
                        onClicked: { objList.currentIndex = index; objList.forceActiveFocus(); if (root.viewport) root.viewport.lookAtWorld(modelData.x, modelData.z) }
                        contentItem: RowLayout {
                            spacing: Theme.s2
                            Label { text: modelData.kind + (modelData.breakable ? " · breakable" : ""); Layout.fillWidth: true; elide: Text.ElideRight }
                            Label { text: modelData.x.toFixed(0) + ", " + modelData.z.toFixed(0); color: Theme.textFaint; font.family: Theme.mono; font.pixelSize: Theme.caption }
                            ToolButton { text: "✕"; onClicked: WorldModel.removeObject(modelData.id); focusPolicy: Qt.NoFocus
                                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.tip("Delete", "Backspace") }
                        }
                    }
                }
                Button { visible: WorldModel.objects.length > 1; text: "Delete all"; onClicked: WorldModel.clearObjects() }
            }

            // ---- sky
            PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                title: "Sky & wind"
                Layout.fillWidth: true
                expanded: false
                PwSlider { label: "Time of day"; from: 0; to: 24; step: 0.05; value: WorldModel.timeOfDay; defaultValue: 10
                    format: (v) => { const h = Math.floor(v), m = Math.round((v - h) * 60) % 60; return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m }
                    onMoved: (v) => WorldModel.timeOfDay = v }
                PwSlider { label: "Sun azimuth"; from: 0; to: 360; value: WorldModel.sunAzimuth; decimals: 0; unit: "°"; defaultValue: 135; onMoved: (v) => WorldModel.sunAzimuth = v }
                PwSlider { label: "Wind speed"; from: 0; to: 30; value: WorldModel.windSpeed; decimals: 1; unit: "m/s"; defaultValue: 3; onMoved: (v) => WorldModel.windSpeed = v }
                PwSlider { label: "Wind from"; from: 0; to: 360; value: WorldModel.windDirection; decimals: 0; unit: "°"; defaultValue: 270; onMoved: (v) => WorldModel.windDirection = v }
                PwSlider { label: "Haze"; from: 1; to: 10; value: WorldModel.turbidity; decimals: 1; defaultValue: 2; onMoved: (v) => WorldModel.turbidity = v }
                PwSlider { label: "Fog"; from: 0; to: 5; value: WorldModel.fogDensity; decimals: 2; defaultValue: 1; onMoved: (v) => WorldModel.fogDensity = v }
            }

            Label {
                Layout.fillWidth: true
                Layout.margins: Theme.s4
                text: WorldModel.status
                color: Theme.textFaint; font.pixelSize: Theme.caption; wrapMode: Text.WordWrap
            }
        }
    }
}
