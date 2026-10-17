import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

// EVOLVE inspector in three pages: Setup (experiment library, craft & world, what evolves + diagram, controller
// I/O table, algorithm form, episode), Script (JS editor with error markers) and Train (run controls, live charts,
// generation table, replay, export / fly). Ctrl+Return starts / pauses from anywhere in the tab.
Rectangle {
    id: root
    color: Theme.surface
    readonly property var ev: EvolveModel
    readonly property var xp: EvolveModel.experiment
    property alias page: pageBar.currentIndex
    signal openEditorWindow()
    JsHighlighter { id: jsTools }

    Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.separator }

    FileDialog { id: openDlg; title: qsTr("Open experiment"); nameFilters: [qsTr("Experiments (*.json)")]; currentFolder: "file://" + ev.libraryDir; onAccepted: ev.open(selectedFile) }
    FileDialog { id: saveDlg; title: qsTr("Save experiment as"); fileMode: FileDialog.SaveFile; nameFilters: [qsTr("Experiments (*.json)")]; currentFolder: "file://" + ev.libraryDir; onAccepted: ev.saveAs(selectedFile) }
    function openFile() { openDlg.open() }
    function saveFileAs() { saveDlg.open() }

    function num(path, def) { const v = ev.get(path); return v === undefined || v === null ? def : v }
    readonly property color stateColor: ev.runState === "running" ? Theme.good : ev.runState === "stopping" || ev.runState === "preparing" ? Theme.warn
                                      : ev.runState === "failed" ? Theme.bad : ev.runState === "finished" ? Theme.info : Theme.textFaint

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // header
        ColumnLayout {
            Layout.fillWidth: true
            Layout.margins: Theme.s4
            Layout.minimumWidth: 0
            Layout.preferredWidth: 0
            Layout.bottomMargin: Theme.s2
            spacing: Theme.s2
            RowLayout {
                spacing: Theme.s2
                Rectangle { width: 4; Layout.fillHeight: true; radius: 2; color: Theme.tabTint["EVOLVE"] }
                TextField {
                    Layout.fillWidth: true
                    text: ev.name
                    font.pixelSize: Theme.title; font.weight: Font.DemiBold
                    background: null
                    onEditingFinished: if (text !== ev.name) ev.set("name", text)
                }
                Rectangle { width: 8; height: 8; radius: 4; color: Theme.warn; visible: ev.dirty
                    ToolTip.visible: dh.hovered; ToolTip.text: qsTr("Unsaved changes"); HoverHandler { id: dh } }
            }
            RowLayout {
                spacing: Theme.s1
                Button { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.minimumWidth: 0
                    text: qsTr("New"); onClicked: newMenu.popup()
                    Menu { id: newMenu
                        Repeater { model: ev.presets; MenuItem { required property string modelData; text: modelData; onTriggered: ev.newFromPreset(modelData) } } }
                }
                Button { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.minimumWidth: 0;
                    text: qsTr("Library"); onClicked: { ev.refreshLibrary(); libMenu.popup() }
                    Menu { id: libMenu
                        Repeater { model: ev.library; MenuItem { required property var modelData; text: modelData.name; onTriggered: ev.open(modelData.path) } }
                        MenuSeparator { visible: ev.library.length > 0 }
                        MenuItem { text: qsTr("Browse…"); onTriggered: openDlg.open() } }
                }
                Button { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.minimumWidth: 0; text: qsTr("Save"); onClicked: ev.save(); ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.shortcutText("Ctrl+S") }
                Button { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.minimumWidth: 0; text: qsTr("Duplicate"); onClicked: ev.duplicate() }
            }
            // run state chip + primary action
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s2
                Rectangle { width: 8; height: 8; radius: 4; color: root.stateColor
                    SequentialAnimation on opacity { running: ev.running; loops: Animation.Infinite; NumberAnimation { to: 0.35; duration: 700 } NumberAnimation { to: 1; duration: 700 } } }
                Label {
                    Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: Theme.caption
                    text: ev.runState + (ev.last.generation !== undefined ? "  ·  " + qsTr("gen %1/%2").arg(ev.last.generation + 1).arg(xp.generations > 0 ? xp.generations : "∞")
                                                                         + "  ·  " + qsTr("best %1").arg(Theme.fixed(ev.last.best, 3)) : "")
                }
                Button {
                    highlighted: !ev.running
                    enabled: !ev.preparing && ev.runState !== "stopping"
                    text: ev.running ? qsTr("Pause") : (ev.hasRun && ev.runState !== "finished" && ev.runState !== "failed" ? qsTr("Resume") : qsTr("Train"))
                    onClicked: ev.running ? ev.pause() : (ev.hasRun && ev.runState === "idle" ? ev.resume() : ev.start())
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.shortcutText("Ctrl+Return")
                }
            }
            ProgressBar {
                Layout.fillWidth: true
                visible: ev.running && xp.generations > 0
                value: ev.last.generation !== undefined ? (ev.last.generation + 1) / xp.generations : 0
                Behavior on value { NumberAnimation { duration: Theme.normal } }
            }
            Label { visible: ev.runError !== ""; Layout.fillWidth: true; text: ev.runError; color: Theme.bad; wrapMode: Text.Wrap; font.pixelSize: Theme.caption }
        }

        PwTabBar {
            id: pageBar
            Layout.fillWidth: true
            Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3
            fill: true
            model: [qsTr("Setup"), qsTr("Script"), qsTr("Train")]
            badges: ["", ev.scriptErrorLine > 0 ? "●" : "", ev.generations.length > 0 ? String(ev.generations.length) : ""]
            tints: ({ "Setup": Theme.tabTint["EVOLVE"], "Script": Theme.tabTint["EVOLVE"], "Train": Theme.tabTint["EVOLVE"] })
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }

        StackLayout {
            Layout.minimumWidth: 0
            Layout.preferredWidth: 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: pageBar.currentIndex

            // ================= SETUP
            ScrollView {
                id: setupScroll
                contentWidth: availableWidth
                clip: true
                ColumnLayout {
                    width: setupScroll.availableWidth
                    spacing: Theme.s3
                    Item { height: Theme.s1 }

                    PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        title: qsTr("Craft & world")
                        PwPropertyRow { label: qsTr("Craft"); Layout.fillWidth: true
                            ComboBox {
                                Layout.fillWidth: true
                                model: ev.crafts
                                currentIndex: ev.crafts.indexOf(ev.io.craft)
                                onActivated: ev.set("crafts", [{ name: currentText }])
                            }
                        }
                        Label { visible: ev.io.error !== undefined && ev.io.error !== ""; text: ev.io.error || ""; color: Theme.bad; wrapMode: Text.Wrap; Layout.fillWidth: true; font.pixelSize: Theme.caption }
                        PwPropertyRow { label: qsTr("World"); Layout.fillWidth: true
                            ComboBox {
                                Layout.fillWidth: true
                                readonly property var keys: ["current", "flat", "file", "inline"]
                                model: [qsTr("Open world (WORLD tab)"), qsTr("Flat"), qsTr("File"), qsTr("Embedded")]
                                currentIndex: Math.max(0, keys.indexOf(xp.world ? xp.world.source : "current"))
                                onActivated: (i) => ev.set("world.source", keys[i])
                            }
                        }
                        GridLayout {
                            columns: 2; Layout.fillWidth: true; columnSpacing: Theme.s2; rowSpacing: 0
                            CheckBox { text: qsTr("Terrain"); checked: num("headless.terrain", true); onToggled: ev.set("headless.terrain", checked) }
                            CheckBox { text: qsTr("Water"); checked: num("headless.water", true); onToggled: ev.set("headless.water", checked) }
                            CheckBox { text: qsTr("Ocean waves"); checked: num("headless.oceanWaves", false); onToggled: ev.set("headless.oceanWaves", checked) }
                            CheckBox { text: qsTr("Trees"); checked: num("headless.vegetation", false); onToggled: ev.set("headless.vegetation", checked)
                                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Static obstacles; contact = crash") }
                            CheckBox { text: qsTr("Props"); checked: num("headless.breakables", false); onToggled: ev.set("headless.breakables", checked) }
                        }
                        PwPropertyRow { label: qsTr("Aero model"); Layout.fillWidth: true
                            PwSegmented {
                                Layout.fillWidth: true
                                model: [{ text: qsTr("Fast"), tip: qsTr("Panel aero, thousands of sims/s") }, { text: qsTr("Full CFD"), tip: qsTr("GPU lattice-Boltzmann per worker; far slower") }]
                                currentIndex: num("aero.model", "fast") === "full" ? 1 : 0
                                onActivated: (i) => ev.set("aero.model", i === 1 ? "full" : "fast")
                            }
                        }
                    }

                    PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        title: qsTr("What evolves")
                        hint: qsTr("What the algorithm mutates. Controller: neural-network weights (craft fixed). Craft: part sizes, positions, masses. Both: together. Custom: genes your script declares in genome().")
                        PwSegmented {
                            Layout.fillWidth: true
                            readonly property var keys: ["neural", "design", "coevolve", "script"]
                            model: [{ text: qsTr("Controller"), tip: qsTr("Neural network weights") }, { text: qsTr("Craft"), tip: qsTr("Parts and parameters") },
                                    { text: qsTr("Both"), tip: qsTr("Craft + controller together") }, { text: qsTr("Custom"), tip: qsTr("Genes defined in script") }]
                            currentIndex: Math.max(0, keys.indexOf(xp.genome ? xp.genome.preset : "neural"))
                            onActivated: (i) => ev.setPreset(keys[i])
                        }
                        EvolveModeDiagram {
                            Layout.fillWidth: true
                            mode: xp.genome ? xp.genome.preset : "neural"
                            genes: ev.geneCount
                            designGenes: xp.genome && xp.genome.design ? xp.genome.design.length : 0
                            inputs: (ev.io.inputs || []).filter(x => x.used).length
                            outputs: (ev.io.outputs || []).filter(x => x.used).length
                        }
                        PwPropertyRow { label: qsTr("Controller"); Layout.fillWidth: true
                            ComboBox {
                                Layout.fillWidth: true
                                readonly property var keys: ["mlp", "neat", "script", "none"]
                                model: [qsTr("Neural net (MLP)"), qsTr("NEAT (evolving topology)"), qsTr("Script control()"), qsTr("None")]
                                currentIndex: Math.max(0, keys.indexOf(xp.controller ? xp.controller.mode : "mlp"))
                                onActivated: (i) => ev.set("controller.mode", keys[i])
                            }
                        }
                        PwPropertyRow { label: qsTr("Control rate"); Layout.fillWidth: true
                            PwNumberField { value: num("controller.hz", 50); suffix: " Hz"; decimals: 0; step: 5; minimum: 1; maximum: 1000; onCommitted: (v) => ev.set("controller.hz", v) } }

                        // MLP shape
                        ColumnLayout {
                            visible: xp.genome && (xp.genome.preset === "neural" || xp.genome.preset === "coevolve")
                            Layout.fillWidth: true
                            spacing: Theme.s1
                            PwPropertyRow { label: qsTr("Hidden layers"); Layout.fillWidth: true
                                TextField {
                                    Layout.fillWidth: true
                                    text: xp.genome && xp.genome.mlp ? xp.genome.mlp.hidden.join(", ") : ""
                                    placeholderText: "16, 16"
                                    validator: RegularExpressionValidator { regularExpression: /^\s*\d+(\s*,\s*\d+)*\s*$|^$/ }
                                    onEditingFinished: ev.set("genome.mlp.hidden", text.split(",").map(s => parseInt(s)).filter(n => n > 0))
                                }
                            }
                            PwPropertyRow { label: qsTr("Activation"); Layout.fillWidth: true
                                ComboBox { Layout.fillWidth: true; model: ["tanh", "relu", "sigmoid", "linear"]
                                    currentIndex: Math.max(0, model.indexOf(num("genome.mlp.activation", "tanh"))); onActivated: ev.set("genome.mlp.activation", currentText) } }
                            PwPropertyRow { label: qsTr("Weight range"); Layout.fillWidth: true
                                PwNumberField { value: num("genome.mlp.weightRange", 3); decimals: 2; step: 0.5; minimum: 0.1; onCommitted: (v) => ev.set("genome.mlp.weightRange", v) } }
                        }

                        // controller I/O table
                        Label { text: qsTr("WHAT THE CONTROLLER SEES"); color: Theme.textFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking; Layout.topMargin: Theme.s2 }
                        Repeater {
                            model: ev.io.inputs || []
                            delegate: RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: Theme.s1
                                CheckBox { checked: modelData.used; onToggled: ev.toggleIO("inputs", modelData.name, checked); padding: 0 }
                                Label { text: modelData.name; Layout.fillWidth: true; elide: Text.ElideRight; color: modelData.used ? Theme.text : Theme.textFaint; font.pixelSize: Theme.small }
                                Label { text: modelData.unit; color: Theme.textFaint; font.pixelSize: Theme.micro }
                                PwNumberField { Layout.preferredWidth: 56; value: modelData.scale; decimals: 2; step: 0.5; minimum: 0.001; tip: qsTr("Input is divided by this scale")
                                    onCommitted: (v) => ev.setInputScale(modelData.name, v) }
                            }
                        }
                        Label { visible: (ev.io.inputs || []).length === 0; text: qsTr("This craft has no sensors: standard flight sensors are added when the run starts."); color: Theme.textFaint; wrapMode: Text.Wrap; Layout.fillWidth: true; font.pixelSize: Theme.caption }
                        Label { text: qsTr("WHAT IT DRIVES"); color: Theme.textFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking; Layout.topMargin: Theme.s2 }
                        Repeater {
                            model: ev.io.outputs || []
                            delegate: RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                CheckBox { checked: modelData.used; onToggled: ev.toggleIO("outputs", modelData.name, checked); padding: 0 }
                                Label { text: modelData.name; Layout.fillWidth: true; elide: Text.ElideRight; color: modelData.used ? Theme.text : Theme.textFaint; font.pixelSize: Theme.small }
                                Label { text: modelData.kind + "  " + modelData.lo + "…" + modelData.hi; color: Theme.textFaint; font.pixelSize: Theme.micro; font.family: Theme.mono }
                            }
                        }

                        // design genes
                        ColumnLayout {
                            visible: xp.genome && (xp.genome.preset === "design" || xp.genome.preset === "coevolve")
                            Layout.fillWidth: true
                            spacing: Theme.s1
                            Label { text: qsTr("DESIGN GENES"); color: Theme.textFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking; Layout.topMargin: Theme.s2 }
                            Repeater {
                                model: xp.genome ? xp.genome.design : []
                                delegate: PwCard {
                                    required property var modelData
                                    required property int index
                                    Layout.fillWidth: true
                                    RowLayout {
                                        Layout.fillWidth: true
                                        ComboBox { Layout.fillWidth: true; model: ev.craftParts(); currentIndex: model.indexOf(modelData.part)
                                            onActivated: ev.set("genome.design." + index + ".part", currentText) }
                                        ComboBox { Layout.fillWidth: true; model: ev.geneFields(modelData.part); currentIndex: model.indexOf(modelData.field)
                                            onActivated: ev.set("genome.design." + index + ".field", currentText) }
                                        ToolButton { text: "✕"; onClicked: ev.removeDesignGene(index) }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        PwNumberField { Layout.fillWidth: true; value: modelData.min; decimals: 3; tip: qsTr("min"); onCommitted: (v) => ev.set("genome.design." + index + ".min", v) }
                                        Label { text: "…"; color: Theme.textFaint }
                                        PwNumberField { Layout.fillWidth: true; value: modelData.max; decimals: 3; tip: qsTr("max"); onCommitted: (v) => ev.set("genome.design." + index + ".max", v) }
                                        ComboBox { model: ["real", "int", "bool"]; currentIndex: Math.max(0, model.indexOf(modelData.kind)); onActivated: ev.set("genome.design." + index + ".kind", currentText) }
                                    }
                                }
                            }
                            Button { text: qsTr("Add gene"); onClicked: ev.addDesignGene() }
                        }
                    }

                    PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        title: qsTr("Algorithm")
                        PwPropertyRow { label: qsTr("Kind"); Layout.fillWidth: true
                            ComboBox { Layout.fillWidth: true; model: ev.algorithmKinds; currentIndex: model.indexOf(xp.algorithm ? xp.algorithm.kind : "simple-es")
                                onActivated: ev.set("algorithm.kind", currentText) } }
                        Repeater {
                            model: ev.algorithmSchema(xp.algorithm ? xp.algorithm.kind : "")
                            delegate: PwPropertyRow {
                                id: prow
                                required property var modelData
                                Layout.fillWidth: true
                                label: modelData.key
                                tip: modelData.help
                                readonly property var cur: (xp.algorithm && xp.algorithm[modelData.key] !== undefined) ? xp.algorithm[modelData.key] : modelData["default"]
                                Loader {
                                    Layout.fillWidth: true
                                    sourceComponent: modelData.type === "choice" ? choiceC : modelData.type === "flag" ? flagC : numC
                                    Component { id: numC; PwNumberField { value: Number(prow.cur); decimals: 4; step: 0.01; tip: prow.modelData.help; onCommitted: (v) => ev.set("algorithm." + prow.modelData.key, v) } }
                                    Component { id: choiceC; ComboBox { model: prow.modelData.options; currentIndex: Math.max(0, model.indexOf(String(prow.cur))); onActivated: ev.set("algorithm." + prow.modelData.key, currentText) } }
                                    Component { id: flagC; Switch { checked: !!prow.cur && prow.cur !== 0; onToggled: ev.set("algorithm." + prow.modelData.key, checked) } }
                                }
                            }
                        }
                        PwPropertyRow { label: qsTr("Population"); Layout.fillWidth: true
                            PwNumberField { value: xp.population || 64; decimals: 0; step: 4; minimum: 2; maximum: 100000; onCommitted: (v) => ev.set("population", Math.round(v)) } }
                        PwPropertyRow { label: qsTr("Generations"); tip: qsTr("0 = until stopped"); Layout.fillWidth: true
                            PwNumberField { value: xp.generations || 0; decimals: 0; step: 10; minimum: 0; onCommitted: (v) => ev.set("generations", Math.round(v)) } }
                        PwPropertyRow { label: qsTr("Seed"); Layout.fillWidth: true
                            PwNumberField { value: xp.seed || 1; decimals: 0; step: 1; minimum: 0; onCommitted: (v) => ev.set("seed", Math.round(v)) } }
                        PwPropertyRow { label: qsTr("Workers"); tip: qsTr("0 = all cores"); Layout.fillWidth: true
                            PwNumberField { value: xp.workers || 0; decimals: 0; step: 1; minimum: 0; maximum: 256; onCommitted: (v) => ev.set("workers", Math.round(v)) } }
                        PwPropertyRow { label: qsTr("Checkpoint"); tip: qsTr("Every N generations"); Layout.fillWidth: true
                            PwNumberField { value: xp.checkpointEvery || 5; decimals: 0; step: 1; minimum: 0; onCommitted: (v) => ev.set("checkpointEvery", Math.round(v)) } }
                        ColumnLayout {
                            visible: xp.algorithm && (xp.algorithm.kind === "map-elites" || xp.algorithm.kind === "novelty")
                            Layout.fillWidth: true
                            Label { text: qsTr("BEHAVIOUR AXES — descriptor() returns one value per axis"); color: Theme.textFaint; font.pixelSize: Theme.micro; wrapMode: Text.Wrap; Layout.fillWidth: true }
                            Repeater {
                                model: xp.descriptorAxes || []
                                RowLayout {
                                    required property var modelData
                                    required property int index
                                    Layout.fillWidth: true
                                    TextField { Layout.fillWidth: true; text: modelData.name; onEditingFinished: ev.set("descriptorAxes." + index + ".name", text) }
                                    PwNumberField { Layout.preferredWidth: 52; value: modelData.min; decimals: 2; onCommitted: (v) => ev.set("descriptorAxes." + index + ".min", v) }
                                    PwNumberField { Layout.preferredWidth: 52; value: modelData.max; decimals: 2; onCommitted: (v) => ev.set("descriptorAxes." + index + ".max", v) }
                                    PwNumberField { Layout.preferredWidth: 40; value: modelData.bins; decimals: 0; minimum: 1; onCommitted: (v) => ev.set("descriptorAxes." + index + ".bins", Math.round(v)) }
                                    ToolButton { text: "✕"; onClicked: ev.removeAxis(index) }
                                }
                            }
                            Button { text: qsTr("Add axis"); onClicked: ev.addAxis() }
                        }
                    }

                    PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        title: qsTr("Episode")
                        PwPropertyRow { label: qsTr("Duration"); Layout.fillWidth: true
                            PwNumberField { value: num("episode.duration", 30); suffix: " s"; decimals: 1; step: 1; minimum: 0.5; onCommitted: (v) => ev.set("episode.duration", v) } }
                        PwPropertyRow { label: qsTr("Physics"); Layout.fillWidth: true
                            PwNumberField { value: num("episode.physicsHz", 1000); suffix: " Hz"; decimals: 0; step: 100; minimum: 50; onCommitted: (v) => ev.set("episode.physicsHz", v) } }
                        PwPropertyRow { label: qsTr("Episodes"); tip: qsTr("Per candidate"); Layout.fillWidth: true
                            PwNumberField { value: num("episode.episodesPerCandidate", 1); decimals: 0; step: 1; minimum: 1; onCommitted: (v) => ev.set("episode.episodesPerCandidate", Math.round(v)) } }
                        PwPropertyRow { label: qsTr("Aggregate"); Layout.fillWidth: true
                            PwSegmented { Layout.fillWidth: true; model: ["mean", "min", "median"]; currentIndex: Math.max(0, ["mean", "min", "median"].indexOf(num("episode.aggregate", "mean")))
                                onActivated: (i) => ev.set("episode.aggregate", ["mean", "min", "median"][i]) } }
                        CheckBox { text: qsTr("Common random numbers"); checked: num("episode.commonRandomNumbers", true); onToggled: ev.set("episode.commonRandomNumbers", checked) }
                        CheckBox { text: qsTr("Stop on crash"); checked: num("episode.stopOnCrash", true); onToggled: ev.set("episode.stopOnCrash", checked) }
                        PwPropertyRow { label: qsTr("Spawn"); Layout.fillWidth: true
                            ComboBox { Layout.fillWidth: true; model: ["runway", "air", "custom"]; currentIndex: Math.max(0, model.indexOf(num("episode.spawn.mode", "runway")))
                                onActivated: ev.set("episode.spawn.mode", currentText) } }
                        PwPropertyRow { label: qsTr("Altitude AGL"); Layout.fillWidth: true; visible: num("episode.spawn.mode", "runway") !== "runway"
                            PwNumberField { value: num("episode.spawn.altitudeAGL", 0); suffix: " m"; decimals: 0; step: 10; onCommitted: (v) => ev.set("episode.spawn.altitudeAGL", v) } }
                        PwPropertyRow { label: qsTr("Speed"); Layout.fillWidth: true
                            PwNumberField { value: num("episode.spawn.speed", 0); suffix: " m/s"; decimals: 1; step: 1; onCommitted: (v) => ev.set("episode.spawn.speed", v) } }
                        PwPropertyRow { label: qsTr("Jitter heading"); Layout.fillWidth: true
                            PwNumberField { value: num("episode.spawn.jitterHeadingDeg", 0); suffix: "°"; decimals: 1; step: 1; onCommitted: (v) => ev.set("episode.spawn.jitterHeadingDeg", v) } }
                        PwPropertyRow { label: qsTr("Wind max"); Layout.fillWidth: true
                            PwNumberField { value: num("episode.wind.speedMax", 0); suffix: " m/s"; decimals: 1; step: 0.5; minimum: 0; onCommitted: (v) => ev.set("episode.wind.speedMax", v) } }
                        PwPropertyRow { label: qsTr("Turbulence"); Layout.fillWidth: true
                            PwNumberField { value: num("episode.wind.turbulence", 0); decimals: 2; step: 0.05; minimum: 0; onCommitted: (v) => ev.set("episode.wind.turbulence", v) } }
                    }
                    Item { height: Theme.s4 }
                }
            }

            // ================= SCRIPT
            ColumnLayout {
                spacing: Theme.s2
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3; Layout.topMargin: Theme.s2
                    Repeater {
                        model: jsTools.definedHooks(xp.scripts ? xp.scripts.source : "")
                        Rectangle {
                            required property string modelData
                            radius: height / 2; color: Theme.accentSoft
                            implicitWidth: hl.implicitWidth + Theme.s3; implicitHeight: hl.implicitHeight + 4
                            Text { id: hl; anchors.centerIn: parent; text: modelData; color: Theme.text; font.pixelSize: Theme.micro; font.family: Theme.mono }
                        }
                    }
                    Item { Layout.fillWidth: true }
                    ToolButton { text: "⤢"; onClicked: root.openEditorWindow(); ToolTip.visible: hovered; ToolTip.text: qsTr("Open in a large editor  %1").arg(Theme.shortcutText("Ctrl+Shift+E")) }
                }
                EvolveCodeEditor {
                    id: editor
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3
                    text: xp.scripts ? xp.scripts.source : ""
                    errorLine: ev.scriptErrorLine
                    errorMessage: ev.scriptMessage
                    onEdited: (t) => ev.setScript(t)
                    onCheckRequested: ev.checkScript()
                    Connections {
                        target: EvolveModel
                        function onExperimentChanged() { const s = EvolveModel.experiment.scripts ? EvolveModel.experiment.scripts.source : ""; if (s !== editor.text) editor.text = s }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3
                    Button { text: ev.checking ? qsTr("Checking…") : qsTr("Check"); enabled: !ev.checking; onClicked: ev.checkScript()
                        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.shortcutText("Ctrl+Return") + qsTr(" in the editor") }
                    Button { text: qsTr("Templates"); onClicked: tplMenu.popup()
                        Menu { id: tplMenu
                            MenuItem { text: qsTr("Neural controller preset"); onTriggered: ev.setScript(ev.presetScript("neural")) }
                            MenuItem { text: qsTr("Craft design preset"); onTriggered: ev.setScript(ev.presetScript("design")) } } }
                    Item { Layout.fillWidth: true }
                    Label { text: qsTr("Budget"); color: Theme.textMuted; font.pixelSize: Theme.caption }
                    PwNumberField { Layout.preferredWidth: 64; value: num("scripts.callBudgetMs", 5); suffix: " ms"; decimals: 1; step: 1; minimum: 0.5; onCommitted: (v) => ev.set("scripts.callBudgetMs", v) }
                }
                Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3; Layout.bottomMargin: Theme.s3
                    visible: ev.scriptMessage !== ""
                    text: ev.scriptMessage + (ev.scriptErrorLine > 0 ? "   — " + qsTr("click to jump") : "")
                    color: ev.scriptOk ? Theme.good : Theme.bad
                    wrapMode: Text.Wrap; font.family: Theme.mono; font.pixelSize: Theme.caption
                    MouseArea { anchors.fill: parent; enabled: ev.scriptErrorLine > 0; cursorShape: Qt.PointingHandCursor; onClicked: editor.goToLine(ev.scriptErrorLine) }
                }
                Label { Layout.leftMargin: Theme.s3; Layout.bottomMargin: Theme.s2; text: qsTr("Engine: %1").arg(ev.engineName); color: Theme.textFaint; font.pixelSize: Theme.micro }
            }

            // ================= TRAIN
            ScrollView {
                id: trainScroll
                contentWidth: availableWidth
                clip: true
                ColumnLayout {
                    width: trainScroll.availableWidth
                    spacing: Theme.s3
                    Item { height: Theme.s1 }

                    PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        title: qsTr("Run")
                        RowLayout {
                            Button { text: qsTr("Stop"); enabled: ev.running; onClicked: ev.stop() }
                            Button { text: qsTr("New run"); enabled: !ev.running && ev.hasRun; onClicked: ev.newRun() }
                            Item { Layout.fillWidth: true }
                            Button { text: qsTr("Checkpoints"); enabled: !ev.running; onClicked: runsMenu.popup()
                                Menu { id: runsMenu
                                    Repeater { model: ev.runDirs; MenuItem { required property string modelData; text: qsTr("Resume %1").arg(modelData.split("/").pop()); onTriggered: ev.resumeDir(modelData) } }
                                    MenuItem { enabled: false; visible: ev.runDirs.length === 0; text: qsTr("No checkpoints for this experiment") } } }
                        }
                        PwStatRow { Layout.fillWidth: true; label: qsTr("Throughput"); value: ev.last.sps !== undefined ? qsTr("%1 sims/s · %2× real time").arg(Theme.fixed(ev.last.sps, 0)).arg(Theme.fixed(ev.last.speed, 0)) : "–" }
                        PwStatRow { Layout.fillWidth: true; label: qsTr("Generation time"); value: ev.last.wall !== undefined ? Theme.fixed(ev.last.wall, 2) + " s" : "–" }
                        PwStatRow { Layout.fillWidth: true; label: qsTr("Failures"); value: ev.last.failures !== undefined ? String(ev.last.failures) : "–"; warn: ev.last.failures > 0; tip: ev.last.error || "" }
                        Label { visible: !!ev.last.error; text: ev.last.error || ""; color: Theme.warn; wrapMode: Text.Wrap; Layout.fillWidth: true; font.pixelSize: Theme.caption }
                    }

                    PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        title: qsTr("Fitness")
                        hint: qsTr("Click a generation to replay its best candidate in 3D")
                        EvolveChart {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 160
                            xs: ev.chart.generation || []
                            band: ({ lo: ev.chart.worst || [], hi: ev.chart.best || [], color: Theme.alpha(Theme.tabTint["EVOLVE"], 0.12) })
                            series: [ { name: qsTr("best"), values: ev.chart.best || [], color: Theme.tabTint["EVOLVE"], width: 2 },
                                      { name: qsTr("mean"), values: ev.chart.mean || [], color: Theme.info, width: 1.5 },
                                      { name: qsTr("median"), values: ev.chart.median || [], color: Theme.textMuted, width: 1, dash: true } ]
                            selected: ev.selected.startsWith("g") ? (ev.chart.generation || []).indexOf(parseInt(ev.selected.substring(1))) : -1
                            onPicked: (i) => ev.replay("g" + ev.chart.generation[i])
                        }
                    }

                    PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        visible: ev.termNames.length > 0
                        title: qsTr("Reward terms (best)")
                        EvolveChart {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 120
                            xs: ev.chart.generation || []
                            readonly property var termColors: ["#e0913a", "#3a8ee0", "#4caf6a", "#a368d8", "#e5534b", "#39c5bb", "#d29922"]
                            series: ev.termNames.map((t, i) => ({ name: t, values: (ev.chart.terms || {})[t] || [], color: termColors[i % palette.length], width: 1.5 }))
                            onPicked: (i) => ev.replay("g" + ev.chart.generation[i])
                        }
                    }

                    PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        visible: ev.archive.cells !== undefined
                        title: qsTr("Archive · %1% covered").arg(ev.archive.coverage !== undefined ? (ev.archive.coverage * 100).toFixed(1) : "0")
                        hint: qsTr("MAP-Elites cells coloured by fitness; click one to replay that elite")
                        Item {
                            id: heat
                            Layout.fillWidth: true
                            Layout.preferredHeight: width * 0.6
                            readonly property int bx: ev.archive.axes ? ev.archive.axes[0].bins : 1
                            readonly property int by: ev.archive.axes && ev.archive.axes.length > 1 ? ev.archive.axes[1].bins : 1
                            Rectangle { anchors.fill: parent; color: Theme.surfaceSunken; radius: Theme.radiusSmall }
                            Repeater {
                                model: ev.archive.cells || []
                                Rectangle {
                                    required property var modelData
                                    x: modelData.x * heat.width / heat.bx; y: heat.height - (modelData.y + 1) * heat.height / heat.by
                                    width: Math.max(2, heat.width / heat.bx - 1); height: Math.max(2, heat.height / heat.by - 1)
                                    color: Qt.hsla(0.75 - 0.6 * modelData.t, 0.65, Theme.dark ? 0.55 : 0.5, 1)
                                    border.color: ev.selected === "cell" + modelData.cell ? Theme.text : "transparent"
                                    MouseArea { anchors.fill: parent; onClicked: ev.replay("cell" + modelData.cell); hoverEnabled: true
                                        ToolTip.visible: containsMouse; ToolTip.text: qsTr("cell %1 · %2").arg(modelData.cell).arg(modelData.fitness.toFixed(3)) }
                                }
                            }
                        }
                    }

                    PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        title: qsTr("Generations")
                        PwEmptyState {
                            visible: ev.generations.length === 0
                            Layout.fillWidth: true
                            title: qsTr("No generations yet")
                            text: qsTr("Start training to fill this table. Each row is one generation; select one and press Return to replay its best.")
                            shortcut: "Ctrl+Return"; shortcutLabel: qsTr("train")
                        }
                        // header
                        RowLayout {
                            visible: ev.generations.length > 0
                            Layout.fillWidth: true
                            Repeater {
                                model: [[qsTr("gen"), 40], [qsTr("best"), 0], [qsTr("mean"), 0], [qsTr("worst"), 0], [qsTr("fail"), 34]]
                                Label { required property var modelData; text: modelData[0]; color: Theme.textFaint; font.pixelSize: Theme.micro
                                    Layout.preferredWidth: modelData[1] > 0 ? modelData[1] : -1; Layout.fillWidth: modelData[1] === 0; horizontalAlignment: Text.AlignRight }
                            }
                        }
                        ListView {
                            id: genList
                            visible: ev.generations.length > 0
                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.min(contentHeight, 260)
                            clip: true
                            model: ev.generations
                            keyNavigationEnabled: true
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar {}
                            delegate: ItemDelegate {
                                required property var modelData
                                required property int index
                                width: ListView.view.width
                                height: Theme.rowHeight
                                highlighted: ev.selected === "g" + modelData.generation
                                padding: 0
                                contentItem: RowLayout {
                                    spacing: Theme.s1
                                    Label { text: modelData.generation; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight; font.family: Theme.mono; font.pixelSize: Theme.caption; color: Theme.textMuted }
                                    Label { text: Theme.fixed(modelData.best, 3); Layout.fillWidth: true; horizontalAlignment: Text.AlignRight; font.family: Theme.mono; font.pixelSize: Theme.caption; font.weight: Font.DemiBold }
                                    Label { text: Theme.fixed(modelData.mean, 3); Layout.fillWidth: true; horizontalAlignment: Text.AlignRight; font.family: Theme.mono; font.pixelSize: Theme.caption }
                                    Label { text: Theme.fixed(modelData.worst, 3); Layout.fillWidth: true; horizontalAlignment: Text.AlignRight; font.family: Theme.mono; font.pixelSize: Theme.caption; color: Theme.textMuted }
                                    Label { text: modelData.failures; Layout.preferredWidth: 34; horizontalAlignment: Text.AlignRight; font.family: Theme.mono; font.pixelSize: Theme.caption; color: modelData.failures > 0 ? Theme.warn : Theme.textFaint }
                                }
                                onClicked: { genList.currentIndex = index; genList.forceActiveFocus(); ev.replay("g" + modelData.generation) }
                            }
                            Keys.onReturnPressed: if (currentIndex >= 0) ev.replay("g" + ev.generations[currentIndex].generation)
                        }
                    }

                    PwSection { Layout.minimumWidth: 0; Layout.preferredWidth: 0
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        title: qsTr("Use the result")
                        RowLayout {
                            Layout.fillWidth: true
                            Button { text: qsTr("Replay best"); enabled: ev.hasRun && ev.generations.length > 0; onClicked: ev.replay("best") }
                            Button { text: qsTr("Export craft"); enabled: ev.hasRun && ev.generations.length > 0; onClicked: ev.exportBest()
                                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Saves the craft with the evolved controller embedded to your craft library") }
                        }
                        Button {
                            Layout.fillWidth: true
                            highlighted: true
                            enabled: ev.hasRun && ev.generations.length > 0
                            text: qsTr("Fly it with the evolved autopilot")
                            onClicked: ev.flyWithAutopilot()
                        }
                    }
                    Item { height: Theme.s4 }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator; visible: ev.status !== "" }
        Label { Layout.fillWidth: true; Layout.margins: Theme.s3; visible: ev.status !== ""; text: ev.status; color: Theme.textMuted; font.pixelSize: Theme.caption; elide: Text.ElideRight }
    }
}
