import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import "EvolveGoals.js" as Goals

// EVOLVE inspector as a guided flow. Page "Set up": ① craft & world, ② what evolves (diagram + I/O table),
// ③ goal (plain-language reward picked from templates, or the script), ④ algorithm (sensible defaults, advanced
// folded away). Page "Train": ⑤ big Train button with live progress (generation, best score, ETA, chart) and
// ⑥ results (replay, fly with the autopilot, export). Page "Script": the JavaScript editor for hand-written goals.
// Ctrl+Return starts / pauses from anywhere in the tab; Alt+1..3 switch pages.
Rectangle {
    id: root
    color: Theme.surface
    readonly property var ev: EvolveModel
    readonly property var xp: EvolveModel.experiment
    property alias page: pageBar.currentIndex
    signal openEditorWindow()
    JsHighlighter { id: jsTools }

    Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.separator }

    FileDialog { id: openDlg; title: qsTr("Open experiment"); nameFilters: [qsTr("Experiments (*.json)")]; currentFolder: (Qt.platform.os === "windows" ? "file:///" : "file://") + ev.libraryDir; onAccepted: ev.open(selectedFile) }
    FileDialog { id: saveDlg; title: qsTr("Save experiment as"); fileMode: FileDialog.SaveFile; nameFilters: [qsTr("Experiments (*.json)")]; currentFolder: (Qt.platform.os === "windows" ? "file:///" : "file://") + ev.libraryDir; onAccepted: ev.saveAs(selectedFile) }
    function openFile() { openDlg.open() }
    function saveFileAs() { saveDlg.open() }

    function num(path, def) { const v = ev.get(path); return v === undefined || v === null ? def : v }
    // palette "EVOLVE: show controller wiring": Set up page, sensors -> controls table open and scrolled into view
    function showWiring() { root.page = 0; ioSection.expanded = true; Qt.callLater(() => { const f = setupScroll.contentItem; f.contentY = Math.max(0, driveLabel.mapToItem(f.contentItem, 0, 0).y - 120) }) }
    function train() { root.page = 1; ev.running ? ev.pause() : (ev.hasRun && ev.runState === "idle" ? ev.resume() : ev.start()) }
    readonly property bool hasResults: ev.hasRun && ev.generations.length > 0
    readonly property color stateColor: ev.runState === "running" ? Theme.good : ev.runState === "stopping" || ev.runState === "preparing" ? Theme.warn
                                      : ev.runState === "failed" ? Theme.bad : ev.runState === "finished" ? Theme.info : Theme.textFaint
    readonly property string stateText: ({ idle: hasResults ? qsTr("Paused") : qsTr("Ready"), preparing: qsTr("Preparing…"), running: qsTr("Training"),
                                           stopping: qsTr("Stopping…"), finished: qsTr("Finished"), failed: qsTr("Failed") })[ev.runState] || ev.runState
    readonly property string trainLabel: ev.running ? qsTr("Pause") : (ev.hasRun && ev.runState === "idle" ? qsTr("Resume training") : hasResults ? qsTr("Train again") : qsTr("Start training"))

    // goal picker state (controller experiments only; scripted autopilots keep their own script)
    readonly property bool goalsApply: xp.controller ? (xp.controller.mode === "mlp" || xp.controller.mode === "neat") : true
    readonly property var goal: Goals.detect(xp.scripts ? xp.scripts.source : "", ev.presetScript("neural"))
    readonly property var goalDef: goal ? Goals.byId(goal.id) : null
    function applyGoal(id, param) {
        const g = Goals.byId(id)
        if (!g) return
        const p = param !== undefined ? param : (g.param ? g.param.def : undefined)
        ev.set("rewardTerms", Goals.terms(g))
        ev.setScript(g.script ? g.script(p) : ev.presetScript("neural"))
    }

    // time estimate: seconds per generation × generations left
    function eta() {
        if (!ev.running || ev.last.wall === undefined || !(xp.generations > 0)) return ""
        const left = Math.max(0, xp.generations - ev.last.generation - 1) * ev.last.wall
        return left < 60 ? qsTr("%1 s left").arg(Math.ceil(left)) : qsTr("%1 min left").arg((left / 60).toFixed(1))
    }

    // numbered step header used in "Set up"
    component StepBadge: Rectangle {
        property int number: 1
        property bool done: false
        width: 20; height: 20; radius: 10
        color: done ? Theme.tabTint["EVOLVE"] : Theme.accentSoft
        Text { anchors.centerIn: parent; text: parent.number; color: parent.done ? "white" : Theme.text; font.pixelSize: Theme.caption; font.weight: Font.DemiBold }
    }
    component StepTitle: RowLayout {
        property int number: 1
        property string title
        property string summary
        Layout.fillWidth: true
        Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4; Layout.topMargin: Theme.s3
        spacing: Theme.s2
        StepBadge { number: parent.number; done: true }
        Label { text: parent.title; font.weight: Font.DemiBold; font.pixelSize: Theme.body }
        Label { Layout.fillWidth: true; text: parent.summary; color: Theme.textFaint; font.pixelSize: Theme.caption; elide: Text.ElideRight; horizontalAlignment: Text.AlignRight }
    }
    component Hint: Label {
        Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.textMuted; font.pixelSize: Theme.caption
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---------------- header: experiment file + run state + the primary action
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
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Experiment name")
                }
                Rectangle { width: 8; height: 8; radius: 4; color: Theme.warn; visible: ev.dirty
                    ToolTip.visible: dh.hovered; ToolTip.text: qsTr("Unsaved changes"); HoverHandler { id: dh } }
            }
            RowLayout {
                spacing: Theme.s1
                Button { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.minimumWidth: 0
                    text: qsTr("New"); onClicked: newMenu.popup()
                    Menu { id: newMenu
                        MenuItem { text: qsTr("Quick start — learns in ~10 s"); onTriggered: ev.quickStart() }
                        MenuSeparator {}
                        Repeater { model: ev.presets; MenuItem { required property string modelData; text: modelData; onTriggered: ev.newFromPreset(modelData) } }
                        MenuSeparator {}
                        // built-in example experiments (examples/experiments): any craft x any world x any reward
                        Menu { title: qsTr("Examples")
                            Repeater { model: ev.examples
                                MenuItem { required property var modelData; text: modelData.name; font.weight: modelData.showcase ? Font.DemiBold : Font.Normal
                                           onTriggered: ev.openExample(modelData.file)
                                           ToolTip.visible: hovered && modelData.notes !== ""; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: modelData.notes } } } }
                }
                Button { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.minimumWidth: 0;
                    text: qsTr("Open"); onClicked: { ev.refreshLibrary(); libMenu.popup() }
                    Menu { id: libMenu
                        Repeater { model: ev.library; MenuItem { required property var modelData; text: modelData.name; onTriggered: ev.open(modelData.path) } }
                        MenuItem { text: qsTr("No saved experiments"); enabled: false; visible: ev.library.length === 0; height: visible ? implicitHeight : 0 }
                        MenuSeparator {}
                        MenuItem { text: qsTr("Browse…  %1").arg(Theme.shortcutText("Ctrl+O")); onTriggered: openDlg.open() } }
                }
                Button { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.minimumWidth: 0; text: qsTr("Save"); onClicked: ev.save()
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.tip(qsTr("Save to the experiment library"), "Ctrl+S") }
                Button { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.minimumWidth: 0; text: qsTr("Duplicate"); onClicked: ev.duplicate() }
            }
            Label { visible: !!xp.notes; Layout.fillWidth: true; text: xp.notes || ""; color: Theme.textMuted; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; maximumLineCount: 3; elide: Text.ElideRight }
        }

        PwTabBar {
            id: pageBar
            Layout.fillWidth: true
            Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3
            fill: true
            model: [qsTr("Set up"), qsTr("Train"), qsTr("Script")]
            tips: [qsTr("Steps 1–4: craft, what evolves, goal, algorithm   Alt+1"), qsTr("Steps 5–6: run it and use the result   Alt+2"),
                   qsTr("Advanced: the JavaScript that scores each flight   Alt+3")]
            badges: ["", ev.running ? "●" : (ev.generations.length > 0 ? String(ev.generations.length) : ""), ev.scriptErrorLine > 0 ? "●" : ""]
            tints: ({ "Set up": Theme.tabTint["EVOLVE"], "Train": Theme.tabTint["EVOLVE"], "Script": Theme.tabTint["EVOLVE"] })
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }

        StackLayout {
            Layout.minimumWidth: 0
            Layout.preferredWidth: 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: pageBar.currentIndex

            // ======================================================== SET UP (steps 1–4)
            ScrollView {
                id: setupScroll
                contentWidth: availableWidth
                clip: true
                ColumnLayout {
                    width: setupScroll.availableWidth
                    spacing: Theme.s2

                    // what is this? (folded once you know)
                    PwCard {
                        Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4; Layout.topMargin: Theme.s3
                        color: Theme.accentSoft; border.color: "transparent"
                        Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.small
                            text: qsTr("Evolution tries many variations of a controller or a craft, scores each flight, keeps the best and varies them again — round after round — until they fly well. Pick the four settings below, then press Train.") }
                        Label { Layout.fillWidth: true; font.pixelSize: Theme.caption; color: Theme.accent
                            text: glossary.visible ? qsTr("<a href='#'>Hide the word list</a>") : qsTr("<a href='#'>What do fitness, generation, population… mean?</a>")
                            onLinkActivated: glossary.visible = !glossary.visible }
                        GridLayout {
                            id: glossary
                            visible: false
                            Layout.fillWidth: true
                            columns: 2; columnSpacing: Theme.s2; rowSpacing: Theme.s1
                            Repeater {
                                model: Goals.glossary.length * 2
                                Label { required property int index
                                    readonly property var e: Goals.glossary[Math.floor(index / 2)]
                                    text: index % 2 === 0 ? e[0] : e[1]
                                    font.weight: index % 2 === 0 ? Font.DemiBold : Font.Normal
                                    font.pixelSize: Theme.caption; wrapMode: Text.WordWrap
                                    Layout.fillWidth: index % 2 === 1; Layout.alignment: Qt.AlignTop }
                            }
                        }
                    }

                    // ---------------- ① craft & world
                    StepTitle { number: 1; title: qsTr("Craft & worlds")
                                summary: (ev.io.craft || "") + " · " + (ev.worlds.length === 1 ? (ev.worlds[0].kind === "open" ? qsTr("open world") : ev.worlds[0].label)
                                                                                                : qsTr("%1 worlds").arg(ev.worlds.length)) }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        spacing: Theme.s2
                        PwPropertyRow { label: qsTr("Craft"); tip: qsTr("The craft every candidate flies (built in BUILD or bundled)"); Layout.fillWidth: true
                            ComboBox {
                                Layout.fillWidth: true
                                model: ev.crafts
                                currentIndex: ev.crafts.indexOf(ev.io.craft)
                                onActivated: ev.set("crafts", [{ name: currentText }])
                            }
                        }
                        Label { visible: ev.io.error !== undefined && ev.io.error !== ""; text: ev.io.error || ""; color: Theme.bad; wrapMode: Text.Wrap; Layout.fillWidth: true; font.pixelSize: Theme.caption }
                        Label { text: qsTr("Training worlds"); color: Theme.textMuted; font.pixelSize: Theme.small; Layout.topMargin: Theme.s1 }
                        TrainingWorlds { Layout.fillWidth: true }
                        PwSection {
                            title: qsTr("World details & aero model")
                            expanded: false
                            GridLayout {
                                columns: 2; Layout.fillWidth: true; columnSpacing: Theme.s2; rowSpacing: 0
                                CheckBox { text: qsTr("Terrain"); checked: num("headless.terrain", true); onToggled: ev.set("headless.terrain", checked) }
                                CheckBox { text: qsTr("Water"); checked: num("headless.water", true); onToggled: ev.set("headless.water", checked) }
                                CheckBox { text: qsTr("Ocean waves"); checked: num("headless.oceanWaves", false); onToggled: ev.set("headless.oceanWaves", checked) }
                                CheckBox { text: qsTr("Trees"); checked: num("headless.vegetation", false); onToggled: ev.set("headless.vegetation", checked)
                                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Static obstacles; contact = crash") }
                                CheckBox { text: qsTr("Props"); checked: num("headless.breakables", false); onToggled: ev.set("headless.breakables", checked) }
                            }
                            Label { text: qsTr("Aero model"); color: Theme.textMuted; font.pixelSize: Theme.small }
                            AeroModelPicker {
                                Layout.fillWidth: true
                                currentId: !xp.aero ? "fast.plus" : (xp.aero.profile || "fast.plus")
                                onPicked: (id) => ev.setAero(id)
                            }
                        }
                    }

                    // ---------------- ② what evolves
                    StepTitle { number: 2; title: qsTr("What evolves"); summary: qsTr("%1 genes").arg(ev.geneCount) }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        spacing: Theme.s2
                        PwSegmented {
                            Layout.fillWidth: true
                            readonly property var keys: ["neural", "design", "coevolve", "script"]
                            model: [{ text: qsTr("Controller"), tip: qsTr("A neural network learns to fly the craft; the craft stays as built") },
                                    { text: qsTr("Craft"), tip: qsTr("Part sizes and positions change; an autopilot script flies every design") },
                                    { text: qsTr("Both"), tip: qsTr("Craft and controller evolve together") },
                                    { text: qsTr("Custom"), tip: qsTr("Genes declared by your script's genome()") }]
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

                        // controller I/O table
                        PwSection {
                            id: ioSection
                            visible: xp.genome && xp.genome.preset !== "design"
                            title: qsTr("Sensors → controls  (%1 in · %2 out)").arg((ev.io.inputs || []).filter(x => x.used).length).arg((ev.io.outputs || []).filter(x => x.used).length)
                            hint: qsTr("Tick what the controller can read and what it may move")
                            expanded: false
                            Label { text: qsTr("WHAT THE CONTROLLER SEES"); color: Theme.textFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking }
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
                            Label { id: driveLabel; text: qsTr("WHAT IT DRIVES"); color: Theme.textFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking; Layout.topMargin: Theme.s2 }
                            Repeater {
                                model: ev.io.outputs || []
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    CheckBox { checked: modelData.used; onToggled: ev.toggleIO("outputs", modelData.name, checked); padding: 0 }
                                    Label { text: modelData.name; Layout.fillWidth: true; elide: Text.ElideRight; color: modelData.used ? Theme.text : Theme.textFaint; font.pixelSize: Theme.small }
                                    Label { text: modelData.where ? "→ " + modelData.where : modelData.kind + "  " + modelData.lo + "…" + modelData.hi
                                            color: modelData.where ? Theme.text : Theme.textFaint; font.pixelSize: Theme.micro; font.family: Theme.mono }
                                }
                            }
                        }

                        // controller / network shape (advanced)
                        PwSection {
                            title: qsTr("Controller details")
                            expanded: false
                            PwPropertyRow { label: qsTr("Controller"); Layout.fillWidth: true
                                ComboBox {
                                    Layout.fillWidth: true
                                    readonly property var keys: ["mlp", "neat", "script", "none"]
                                    model: [qsTr("Neural net (MLP)"), qsTr("NEAT (evolving topology)"), qsTr("Script control()"), qsTr("None")]
                                    currentIndex: Math.max(0, keys.indexOf(xp.controller ? xp.controller.mode : "mlp"))
                                    onActivated: (i) => ev.set("controller.mode", keys[i])
                                }
                            }
                            PwPropertyRow { label: qsTr("Control rate"); tip: qsTr("How often per second the controller decides"); Layout.fillWidth: true
                                PwNumberField { value: num("controller.hz", 50); suffix: " Hz"; decimals: 0; step: 5; minimum: 1; maximum: 1000; onCommitted: (v) => ev.set("controller.hz", v) } }
                            ColumnLayout {
                                visible: xp.genome && (xp.genome.preset === "neural" || xp.genome.preset === "coevolve")
                                Layout.fillWidth: true
                                spacing: Theme.s1
                                PwPropertyRow { label: qsTr("Hidden layers"); tip: qsTr("Neurons per hidden layer, e.g. 12 or 16, 16"); Layout.fillWidth: true
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
                        }

                        // design genes
                        ColumnLayout {
                            visible: xp.genome && (xp.genome.preset === "design" || xp.genome.preset === "coevolve")
                            Layout.fillWidth: true
                            spacing: Theme.s1
                            Label { text: qsTr("CRAFT DIMENSIONS THAT EVOLVE (min … max)"); color: Theme.textFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking; Layout.topMargin: Theme.s1 }
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
                                        ToolButton { text: "✕"; onClicked: ev.removeDesignGene(index); ToolTip.visible: hovered; ToolTip.text: qsTr("Remove") }
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
                            Button { text: qsTr("Add dimension"); onClicked: ev.addDesignGene() }
                        }
                    }

                    // ---------------- ③ goal
                    StepTitle { number: 3; title: qsTr("Goal"); summary: root.goalDef ? root.goalDef.title : qsTr("custom script") }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        spacing: Theme.s2
                        Hint { text: qsTr("The goal turns each flight into a score (its fitness). Evolution keeps whatever scores highest, so the goal decides what “flying well” means.") }
                        PwPropertyRow { visible: root.goalsApply; label: qsTr("Goal"); Layout.fillWidth: true
                            ComboBox {
                                Layout.fillWidth: true
                                model: Goals.goals.map(g => g.title).concat([qsTr("Custom (edit the script)")])
                                currentIndex: root.goalDef ? Goals.goals.indexOf(root.goalDef) : Goals.goals.length
                                onActivated: (i) => i < Goals.goals.length ? root.applyGoal(Goals.goals[i].id) : root.page = 2
                            }
                        }
                        PwPropertyRow { visible: root.goalsApply && !!root.goalDef && !!root.goalDef.param; label: root.goalDef && root.goalDef.param ? root.goalDef.param.label : ""; Layout.fillWidth: true
                            PwNumberField {
                                value: root.goal && root.goal.param !== undefined ? root.goal.param : (root.goalDef && root.goalDef.param ? root.goalDef.param.def : 0)
                                suffix: root.goalDef && root.goalDef.param ? " " + root.goalDef.param.unit : ""
                                decimals: 0; step: 10
                                minimum: root.goalDef && root.goalDef.param ? root.goalDef.param.min : 0
                                maximum: root.goalDef && root.goalDef.param ? root.goalDef.param.max : 1e6
                                onCommitted: (v) => root.applyGoal(root.goalDef.id, Math.round(v))
                            }
                        }
                        PwCard {
                            Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.small
                                text: root.goalDef ? root.goalDef.blurb
                                     : (xp.genome && xp.genome.preset === "design" ? qsTr("An autopilot script flies every design; designs that climb well for their weight score highest.")
                                                                                 : qsTr("A hand-written goal: see the Script page for exactly how it scores.")) }
                            Label { text: qsTr("HOW IT IS SCORED"); color: Theme.textFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking; Layout.topMargin: Theme.s1 }
                            Repeater {
                                model: root.goalDef ? root.goalDef.terms : (xp.rewardTerms || []).map(t => ({ name: t, plain: Goals.designTerms[t] || "" }))
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: Theme.s2
                                    Label { text: modelData.name; font.family: Theme.mono; font.pixelSize: Theme.caption; color: Theme.tabTint["EVOLVE"]; Layout.preferredWidth: 72; Layout.alignment: Qt.AlignTop }
                                    Label { text: modelData.plain || qsTr("defined in the script"); Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.textMuted }
                                }
                            }
                            Label { Layout.fillWidth: true; font.pixelSize: Theme.caption; color: Theme.accent
                                text: qsTr("<a href='#'>See or edit the script</a>"); onLinkActivated: root.page = 2 }
                        }
                    }

                    // ---------------- ④ algorithm
                    StepTitle { number: 4; title: qsTr("Algorithm"); summary: (xp.algorithm ? xp.algorithm.kind : "") + " · " + qsTr("%1 × %2").arg(xp.population || 0).arg(xp.generations > 0 ? xp.generations : "∞") }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        spacing: Theme.s2
                        Hint { text: qsTr("The defaults work; bigger numbers search harder but take longer.") }
                        PwPropertyRow { label: qsTr("Population"); tip: Goals.glossary[2][1]; Layout.fillWidth: true
                            PwNumberField { value: xp.population || 64; decimals: 0; step: 4; minimum: 2; maximum: 100000; tip: Goals.glossary[2][1]; onCommitted: (v) => ev.set("population", Math.round(v)) } }
                        PwPropertyRow { label: qsTr("Generations"); tip: Goals.glossary[3][1] + qsTr(" 0 = until you stop it."); Layout.fillWidth: true
                            PwNumberField { value: xp.generations || 0; decimals: 0; step: 10; minimum: 0; tip: qsTr("0 = until stopped"); onCommitted: (v) => ev.set("generations", Math.round(v)) } }
                        PwPropertyRow { label: qsTr("Flight length"); tip: Goals.glossary[6][1]; Layout.fillWidth: true
                            PwNumberField { value: num("episode.duration", 30); suffix: " s"; decimals: 1; step: 1; minimum: 0.5; onCommitted: (v) => ev.set("episode.duration", v) } }
                        PwPropertyRow { label: qsTr("Start"); tip: qsTr("Runway: from a standstill on the ground. Air: already flying at the height and speed below."); Layout.fillWidth: true
                            PwSegmented { Layout.fillWidth: true
                                readonly property var keys: ["runway", "air", "custom"]
                                model: [{ text: qsTr("Runway"), tip: qsTr("Standing on the ground") }, { text: qsTr("In the air"), tip: qsTr("Already flying") }, { text: qsTr("Custom"), tip: qsTr("Position from the experiment") }]
                                currentIndex: Math.max(0, keys.indexOf(num("episode.spawn.mode", "runway")))
                                onActivated: (i) => ev.set("episode.spawn.mode", keys[i]) } }
                        RowLayout {
                            visible: num("episode.spawn.mode", "runway") !== "runway"
                            Layout.fillWidth: true
                            PwPropertyRow { label: qsTr("Height"); Layout.fillWidth: true
                                PwNumberField { value: num("episode.spawn.altitudeAGL", 0); suffix: " m"; decimals: 0; step: 10; onCommitted: (v) => ev.set("episode.spawn.altitudeAGL", v) } }
                        }
                        PwPropertyRow { visible: num("episode.spawn.mode", "runway") !== "runway"; label: qsTr("Speed"); Layout.fillWidth: true
                            PwNumberField { value: num("episode.spawn.speed", 0); suffix: " m/s"; decimals: 1; step: 1; onCommitted: (v) => ev.set("episode.spawn.speed", v) } }

                        PwSection {
                            title: qsTr("Advanced")
                            hint: qsTr("Optimiser, randomness, checkpoints and episode details")
                            expanded: false
                            PwPropertyRow { label: qsTr("Optimiser"); tip: qsTr("sep-cmaes adapts its own step size (good default for networks); ga suits craft dimensions"); Layout.fillWidth: true
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
                            PwPropertyRow { label: qsTr("Seed"); tip: qsTr("Same seed + same settings = same result"); Layout.fillWidth: true
                                PwNumberField { value: xp.seed || 1; decimals: 0; step: 1; minimum: 0; onCommitted: (v) => ev.set("seed", Math.round(v)) } }
                            PwPropertyRow { label: qsTr("Workers"); tip: qsTr("CPU threads; 0 = all cores"); Layout.fillWidth: true
                                PwNumberField { value: xp.workers || 0; decimals: 0; step: 1; minimum: 0; maximum: 256; onCommitted: (v) => ev.set("workers", Math.round(v)) } }
                            PwPropertyRow { label: qsTr("Checkpoint"); tip: qsTr("Save resumable progress every N generations"); Layout.fillWidth: true
                                PwNumberField { value: xp.checkpointEvery || 5; decimals: 0; step: 1; minimum: 0; onCommitted: (v) => ev.set("checkpointEvery", Math.round(v)) } }
                            PwPropertyRow { label: qsTr("Physics"); Layout.fillWidth: true
                                PwNumberField { value: num("episode.physicsHz", 1000); suffix: " Hz"; decimals: 0; step: 100; minimum: 50; onCommitted: (v) => ev.set("episode.physicsHz", v) } }
                            PwPropertyRow { label: qsTr("Flights each"); tip: qsTr("Episodes per candidate in each training world (with different wind / jitter); the score is aggregated"); Layout.fillWidth: true
                                PwNumberField { value: num("episode.episodesPerCandidate", 1); decimals: 0; step: 1; minimum: 1; onCommitted: (v) => ev.set("episode.episodesPerCandidate", Math.round(v)) } }
                            PwPropertyRow { label: qsTr("Aggregate"); Layout.fillWidth: true
                                PwSegmented { Layout.fillWidth: true; model: ["mean", "min", "median"]; currentIndex: Math.max(0, ["mean", "min", "median"].indexOf(num("episode.aggregate", "mean")))
                                    onActivated: (i) => ev.set("episode.aggregate", ["mean", "min", "median"][i]) } }
                            CheckBox { text: qsTr("Common random numbers"); checked: num("episode.commonRandomNumbers", true); onToggled: ev.set("episode.commonRandomNumbers", checked)
                                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Every candidate in a generation gets the same wind and jitter, so scores compare fairly") }
                            CheckBox { text: qsTr("Stop the flight on a crash"); checked: num("episode.stopOnCrash", true); onToggled: ev.set("episode.stopOnCrash", checked) }
                            PwPropertyRow { label: qsTr("Jitter heading"); Layout.fillWidth: true
                                PwNumberField { value: num("episode.spawn.jitterHeadingDeg", 0); suffix: "°"; decimals: 1; step: 1; onCommitted: (v) => ev.set("episode.spawn.jitterHeadingDeg", v) } }
                            PwPropertyRow { label: qsTr("Wind max"); Layout.fillWidth: true
                                PwNumberField { value: num("episode.wind.speedMax", 0); suffix: " m/s"; decimals: 1; step: 0.5; minimum: 0; onCommitted: (v) => ev.set("episode.wind.speedMax", v) } }
                            PwPropertyRow { label: qsTr("Turbulence"); Layout.fillWidth: true
                                PwNumberField { value: num("episode.wind.turbulence", 0); decimals: 2; step: 0.05; minimum: 0; onCommitted: (v) => ev.set("episode.wind.turbulence", v) } }
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
                    }

                    // ---------------- go
                    Button {
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4; Layout.topMargin: Theme.s3
                        highlighted: true
                        enabled: !ev.preparing && ev.runState !== "stopping"
                        text: ev.running ? qsTr("Training… show progress ›") : root.trainLabel + "  ›"
                        onClicked: ev.running ? root.page = 1 : root.train()
                        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.shortcutText("Ctrl+Return")
                    }
                    Item { height: Theme.s4 }
                }
            }

            // ======================================================== TRAIN (steps 5–6)
            ScrollView {
                id: trainScroll
                contentWidth: availableWidth
                clip: true
                ColumnLayout {
                    width: trainScroll.availableWidth
                    spacing: Theme.s2

                    StepTitle { number: 5; title: qsTr("Train"); summary: root.stateText }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        spacing: Theme.s2
                        Button {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 40
                            highlighted: !ev.running
                            enabled: !ev.preparing && ev.runState !== "stopping"
                            font.pixelSize: Theme.title; font.weight: Font.DemiBold
                            text: (ev.running ? "❚❚  " : "▶  ") + root.trainLabel
                            onClicked: root.train()
                            ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.shortcutText("Ctrl+Return")
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.s1
                            Button { Layout.fillWidth: true; Layout.preferredWidth: 1; text: qsTr("Stop"); enabled: ev.running; onClicked: ev.stop()
                                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("End this run (results stay)") }
                            Button { Layout.fillWidth: true; Layout.preferredWidth: 1; text: qsTr("Start over"); enabled: !ev.running && ev.hasRun; onClicked: ev.newRun()
                                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Clear the results and begin a fresh run") }
                            Button { Layout.fillWidth: true; Layout.preferredWidth: 1; text: qsTr("Checkpoints"); enabled: !ev.running; onClicked: runsMenu.popup()
                                Menu { id: runsMenu
                                    Repeater { model: ev.runDirs; MenuItem { required property string modelData; text: qsTr("Resume %1").arg(modelData.split("/").pop()); onTriggered: ev.resumeDir(modelData) } }
                                    MenuItem { enabled: false; visible: ev.runDirs.length === 0; text: qsTr("No checkpoints for this experiment") } } }
                        }
                        Label { visible: ev.runError !== ""; Layout.fillWidth: true; text: ev.runError; color: Theme.bad; wrapMode: Text.Wrap; font.pixelSize: Theme.caption }

                        // live progress
                        PwCard {
                            visible: ev.hasRun || ev.preparing
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.s2
                                Rectangle { width: 8; height: 8; radius: 4; color: root.stateColor
                                    SequentialAnimation on opacity { running: ev.running; loops: Animation.Infinite; NumberAnimation { to: 0.35; duration: 700 } NumberAnimation { to: 1; duration: 700 } } }
                                Label { text: root.stateText; font.weight: Font.DemiBold }
                                Item { Layout.fillWidth: true }
                                Label { text: root.eta(); color: Theme.textMuted; font.pixelSize: Theme.caption }
                            }
                            ProgressBar {
                                Layout.fillWidth: true
                                visible: xp.generations > 0
                                value: ev.last.generation !== undefined ? (ev.last.generation + 1) / xp.generations : 0
                                Behavior on value { NumberAnimation { duration: Theme.normal } }
                            }
                            GridLayout {
                                Layout.fillWidth: true
                                columns: 3; columnSpacing: Theme.s2; rowSpacing: 0
                                Repeater {
                                    model: [[qsTr("GENERATION"), ev.last.generation !== undefined ? (ev.last.generation + 1) + (xp.generations > 0 ? " / " + xp.generations : "") : "–", Goals.glossary[3][1]],
                                            [qsTr("BEST SCORE"), ev.last.best !== undefined ? Theme.fixed(ev.last.best, 2) : "–", qsTr("Fitness of the best candidate so far in this generation (higher is better)")],
                                            [qsTr("AVERAGE"), ev.last.mean !== undefined ? Theme.fixed(ev.last.mean, 2) : "–", qsTr("Mean fitness of the whole population; it rises as the population learns")]]
                                    ColumnLayout {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: 0
                                        Label { text: modelData[0]; color: Theme.textFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking }
                                        Label { text: modelData[1]; font.family: Theme.mono; font.pixelSize: Theme.title; font.weight: Font.DemiBold }
                                        HoverHandler { id: sh }
                                        ToolTip.visible: sh.hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: modelData[2]
                                    }
                                }
                            }
                        }
                        PwEmptyState {
                            visible: !ev.hasRun && !ev.preparing
                            title: qsTr("Nothing trained yet")
                            text: qsTr("Press Start training. Each generation flies the whole population and the chart below fills in; the 3D view shows the current best. Not sure where to begin? New › Quick start learns to hold altitude in about ten seconds.")
                            shortcut: "Ctrl+Return"; shortcutLabel: qsTr("start / pause")
                        }

                        PwSection {
                            title: qsTr("Score per generation")
                            hint: qsTr("Best, average and median fitness. Click a point to replay that generation's best in 3D")
                            visible: ev.generations.length > 0
                            EvolveChart {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 160
                                xs: ev.chart.generation || []
                                band: ({ lo: ev.chart.worst || [], hi: ev.chart.best || [], color: Theme.alpha(Theme.tabTint["EVOLVE"], 0.12) })
                                series: [ { name: qsTr("best"), values: ev.chart.best || [], color: Theme.tabTint["EVOLVE"], width: 2 },
                                          { name: qsTr("average"), values: ev.chart.mean || [], color: Theme.info, width: 1.5 },
                                          { name: qsTr("median"), values: ev.chart.median || [], color: Theme.textMuted, width: 1, dash: true } ]
                                selected: ev.selected.startsWith("g") ? (ev.chart.generation || []).indexOf(parseInt(ev.selected.substring(1))) : -1
                                onPicked: (i) => ev.replay("g" + ev.chart.generation[i])
                            }
                        }
                    }

                    // ---------------- ⑥ results
                    StepTitle { number: 6; title: qsTr("Results"); summary: root.hasResults ? qsTr("best %1").arg(Theme.fixed(Math.max.apply(null, ev.chart.best || [0]), 2)) : "" }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        spacing: Theme.s2
                        Hint { visible: !root.hasResults; text: qsTr("After the first generation you can replay the best flight here, fly it yourself with the evolved autopilot, or save it as a craft.") }
                        Button {
                            Layout.fillWidth: true
                            highlighted: root.hasResults && !ev.running
                            enabled: root.hasResults
                            text: qsTr("✈︎  Fly it with the evolved autopilot")
                            onClicked: ev.flyWithAutopilot()
                            ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Opens the best candidate in FLY with its controller driving the outputs")
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.s1
                            Button { Layout.fillWidth: true; Layout.preferredWidth: 1; text: qsTr("Replay best"); enabled: root.hasResults; onClicked: ev.replay("best")
                                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Watch the best flight so far in the 3D view (Space plays / pauses)") }
                            Button { Layout.fillWidth: true; Layout.preferredWidth: 1; text: qsTr("Save as craft"); enabled: root.hasResults; onClicked: ev.exportBest()
                                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Saves the craft with the evolved controller embedded to your craft library") }
                        }

                        PwSection {
                            visible: ev.termNames.length > 0
                            title: qsTr("Score breakdown (best)")
                            hint: qsTr("Each goal term of the best candidate per generation")
                            expanded: false
                            EvolveChart {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 120
                                xs: ev.chart.generation || []
                                readonly property var termColors: ["#e0913a", "#3a8ee0", "#4caf6a", "#a368d8", "#e5534b", "#39c5bb", "#d29922"]
                                series: ev.termNames.map((t, i) => ({ name: t, values: (ev.chart.terms || {})[t] || [], color: termColors[i % termColors.length], width: 1.5 }))
                                onPicked: (i) => ev.replay("g" + ev.chart.generation[i])
                            }
                        }

                        PwSection {
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

                        PwSection {
                            title: qsTr("All generations (%1)").arg(ev.generations.length)
                            hint: qsTr("Click a row (or select it and press Return) to replay that generation's best")
                            visible: ev.generations.length > 0
                            expanded: false
                            RowLayout {
                                Layout.fillWidth: true
                                Repeater {
                                    model: [[qsTr("gen"), 40], [qsTr("best"), 0], [qsTr("average"), 0], [qsTr("worst"), 0], [qsTr("fail"), 34]]
                                    Label { required property var modelData; text: modelData[0]; color: Theme.textFaint; font.pixelSize: Theme.micro
                                        Layout.preferredWidth: modelData[1] > 0 ? modelData[1] : -1; Layout.fillWidth: modelData[1] === 0; horizontalAlignment: Text.AlignRight }
                                }
                            }
                            ListView {
                                id: genList
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

                        PwSection {
                            title: qsTr("Run details")
                            visible: ev.hasRun
                            expanded: false
                            PwStatRow { Layout.fillWidth: true; label: qsTr("Throughput"); value: ev.last.sps !== undefined ? qsTr("%1 flights/s · %2× real time").arg(Theme.fixed(ev.last.sps, 0)).arg(Theme.fixed(ev.last.speed, 0)) : "–" }
                            PwStatRow { Layout.fillWidth: true; label: qsTr("Generation time"); value: ev.last.wall !== undefined ? Theme.fixed(ev.last.wall, 2) + " s" : "–" }
                            PwStatRow { Layout.fillWidth: true; label: qsTr("Failed flights"); value: ev.last.failures !== undefined ? String(ev.last.failures) : "–"; warn: ev.last.failures > 0; tip: ev.last.error || "" }
                            Label { visible: !!ev.last.error; text: ev.last.error || ""; color: Theme.warn; wrapMode: Text.Wrap; Layout.fillWidth: true; font.pixelSize: Theme.caption }
                        }
                    }
                    Item { height: Theme.s4 }
                }
            }

            // ======================================================== SCRIPT (advanced)
            ColumnLayout {
                spacing: Theme.s2
                Hint {
                    Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3; Layout.topMargin: Theme.s2
                    text: qsTr("reward() scores every control tick, fitness() totals a flight, terminate() can end it early. The goal picker in Set up writes this for you; anything you change here is kept.")
                }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3
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
                            Repeater { model: Goals.goals; MenuItem { required property var modelData; text: qsTr("Goal: %1").arg(modelData.title); onTriggered: root.applyGoal(modelData.id) } }
                            MenuSeparator {}
                            MenuItem { text: qsTr("Craft design preset (autopilot)"); onTriggered: ev.setScript(ev.presetScript("design")) } } }
                    Item { Layout.fillWidth: true }
                    Label { text: qsTr("Budget"); color: Theme.textMuted; font.pixelSize: Theme.caption }
                    PwNumberField { Layout.preferredWidth: 64; value: num("scripts.callBudgetMs", 5); suffix: " ms"; decimals: 1; step: 1; minimum: 0.5; tip: qsTr("Time limit per script call"); onCommitted: (v) => ev.set("scripts.callBudgetMs", v) }
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
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator; visible: ev.status !== "" }
        Label { Layout.fillWidth: true; Layout.margins: Theme.s3; visible: ev.status !== ""; text: ev.status; color: Theme.textMuted; font.pixelSize: Theme.caption; elide: Text.ElideRight }
    }
}
