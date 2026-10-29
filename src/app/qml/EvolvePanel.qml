import QtQuick
import QtQml.Models
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import "EvolveBlocks.js" as Blocks
import "EvolveGoals.js" as Goals

// EVOLVE inspector as a guided flow. Page "Set up": ① craft & world, ② what evolves (diagram + wiring canvas),
// ③ goal (a preset or your own blocks, summarised in plain language), ④ algorithm (sensible defaults, advanced
// folded away). Page "Train": ⑤ big Train button with live progress (generation, best score, ETA, chart) and
// ⑥ results (replay, fly with the autopilot, export). Page "Goal": the goal as blocks (EvolveBlockEditor) or as the
// JavaScript they generate, which can also be written by hand.
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

    // read through xp (not ev.get) so bindings follow the document, e.g. after Open
    function num(path, def) { let v = root.xp; for (const k of path.split(".")) { if (v === undefined || v === null) break; v = v[k] } return v === undefined || v === null ? def : v }
    // palette "EVOLVE: show controller wiring" / Goal › Wiring › Change: Set up page, the wiring canvas open and scrolled into view
    function showWiring() { root.page = 0; ioSection.expanded = true; Qt.callLater(() => { const f = setupScroll.contentItem; f.contentY = Math.max(0, ioSection.mapToItem(f.contentItem, 0, 0).y - Theme.s4) }) }
    // palette "EVOLVE: show algorithm settings" / "EVOLVE: compare algorithms": Set up page, step ④ explained and in view
    function showAlgorithm(compare) { root.page = 0; algoSettings.reveal(); Qt.callLater(() => { const f = setupScroll.contentItem; f.contentY = Math.max(0, algoTitle.mapToItem(f.contentItem, 0, 0).y - Theme.s4); if (compare) algoSettings.compare() }) }
    // palette "EVOLVE: edit the goal …": Goal page, Blocks (0) or JavaScript (1)
    function showGoal(view) { root.page = 2; goalView.currentIndex = view }
    function train() { root.page = 1; ev.running ? ev.pause() : (ev.hasRun && ev.runState === "idle" ? ev.resume() : ev.start()) }
    readonly property bool hasResults: ev.hasRun && ev.generations.length > 0
    readonly property color stateColor: ev.runState === "running" ? Theme.good : ev.runState === "stopping" || ev.runState === "preparing" ? Theme.warn
                                      : ev.runState === "failed" ? Theme.bad : ev.runState === "finished" ? Theme.info : Theme.textFaint
    readonly property string stateText: ({ idle: hasResults ? qsTr("Paused") : qsTr("Ready"), preparing: qsTr("Preparing…"), running: qsTr("Training"),
                                           stopping: qsTr("Stopping…"), finished: qsTr("Finished"), failed: qsTr("Failed") })[ev.runState] || ev.runState
    readonly property string trainLabel: ev.running ? qsTr("Pause") : (ev.hasRun && ev.runState === "idle" ? qsTr("Resume training") : hasResults ? qsTr("Train again") : qsTr("Start training"))

    // goal blocks (EvolveBlocks.js). Presets are for controller experiments; a scripted autopilot's script also flies
    // the craft, so it stays JavaScript unless you replace it with blocks.
    readonly property bool goalsApply: xp.controller ? (xp.controller.mode === "mlp" || xp.controller.mode === "neat") : true
    readonly property string neuralPreset: ev.presetScript("neural")
    readonly property var program: Blocks.programFor(xp.scripts, neuralPreset)            // null: hand-written
    readonly property string blockState: Blocks.state(xp.scripts, neuralPreset)          // "blocks" | "edited" | "script"
    // your saved presets (EvolveModel.goalPresets, files in <experiments>/goal-presets) next to the built-in ones
    readonly property var userGoals: Blocks.userGoals(ev.goalPresets)
    readonly property var goalDef: blockState === "blocks" ? Blocks.goalOf(program, userGoals) : null
    function commitBlocks(p) { ev.setBlocks(p, Blocks.compile(p, neuralPreset), Blocks.terms(p)) }
    function applyGoal(id) { const g = Blocks.goalById(id, userGoals); if (g) replaceGoal(g.program()) }
    // the preset lists show the presets for this kind of craft (Blocks.goalsFor), plus the goal in use; "Show presets
    // for other crafts" adds the rest, faded and saying who they are for
    readonly property string craftKind: ev.io.craftKind || ""
    property bool showAllGoals: false
    readonly property int otherGoals: Blocks.otherCount(craftKind, userGoals)
    readonly property var goalList: Blocks.goalsFor(craftKind, showAllGoals, userGoals, goalDef)
    // after a craft switch: a preset goal that doesn't suit the new craft becomes that kind's preset (the start is
    // kept; Hover takes the air-start height). Own blocks, saved presets and hand-written scripts are never replaced.
    function fitGoalToCraft() {
        if (!goalDef || goalDef.user || Blocks.suits(goalDef, craftKind)) return
        const g = Blocks.defaultGoal(craftKind)
        if (!g || g === goalDef) return
        const h = g.id === "hover" && num("episode.spawn.mode", "runway") === "air" ? num("episode.spawn.altitudeAGL", 0) : 0
        commitBlocks(g.program(h > 0 ? h : undefined))
        ev.appendStatus(qsTr("Goal is now “%1”, which suits %2").arg(g.title, Blocks.kindWords[craftKind]))
    }
    // replacing a hand-written or hand-edited script asks first (there is no undo in EVOLVE)
    function replaceGoal(p) { if (blockState === "blocks") commitBlocks(p); else { replaceDlg.program = p; replaceDlg.open() } }
    MessageDialog {
        id: replaceDlg
        property var program
        title: qsTr("Replace the script?")
        text: root.blockState === "edited" ? qsTr("Your hand edits to the JavaScript will be lost.") : qsTr("The hand-written JavaScript goal will be replaced by blocks.")
        buttons: MessageDialog.Ok | MessageDialog.Cancel
        onAccepted: root.commitBlocks(program)
    }
    // Goal page "Save as preset…": the current blocks under a name, for this kind of craft (same name = replace)
    Dialog {
        id: savePresetDlg
        title: qsTr("Save as preset")
        modal: true
        anchors.centerIn: Overlay.overlay
        standardButtons: Dialog.Save | Dialog.Cancel
        onAboutToShow: { presetName.text = root.goalDef ? root.goalDef.title : ""; presetName.selectAll(); presetName.forceActiveFocus() }
        onAccepted: {
            const name = presetName.text.trim()
            if (!name || !root.program) return
            const file = ev.saveGoalPreset(name, root.program, Blocks.kindWords[root.craftKind] ? [root.craftKind] : [])
            ev.appendStatus(file ? qsTr("Saved the preset “%1”").arg(name) : qsTr("Could not save the preset “%1”").arg(name))
        }
        ColumnLayout {
            spacing: Theme.s2
            TextField { id: presetName; Layout.preferredWidth: 300; placeholderText: qsTr("Name"); onAccepted: savePresetDlg.accept() }
            Label { Layout.preferredWidth: 300; wrapMode: Text.WordWrap; color: Theme.textMuted; font.pixelSize: Theme.caption
                text: (Blocks.kindWords[root.craftKind] ? qsTr("It will be listed for %1.").arg(Blocks.kindWords[root.craftKind]) : qsTr("It will be listed for every craft."))
                      + " " + qsTr("A preset with the same name is replaced.") }
        }
    }
    MessageDialog {
        id: deletePresetDlg
        property var goal
        title: qsTr("Delete the saved preset?")
        text: goal ? qsTr("“%1” will be removed from the preset lists. Goals that use it keep their blocks.").arg(goal.title) : ""
        buttons: MessageDialog.Ok | MessageDialog.Cancel
        onAccepted: ev.removeGoalPreset(goal.file)
    }
    function deletePreset(g) { deletePresetDlg.goal = g; deletePresetDlg.open() }
    // A behaviour's default name: short words for the goal preset ("Hover"), else its title, else the experiment's name.
    function behaviourName() {
        const short = { hold: qsTr("Hold height"), hover: qsTr("Hover"), target: qsTr("Fly to target"), distance: qsTr("Fly far"), drive: qsTr("Drive to point") }
        if (root.goalDef) return short[root.goalDef.id] || root.goalDef.title
        return xp.name || qsTr("Autopilot")
    }
    // palette "EVOLVE: add best to a craft as a behaviour": Train page, the dialog open
    function addBehaviour() { if (!root.hasResults) return; root.page = 1; behaviourDlg.show(behaviourName()) }
    function brainText() {
        const c = xp.controller ? xp.controller.mode : "mlp"
        if (c === "neat") return qsTr("NEAT controller")
        if (c === "script") return qsTr("script control()")
        if (c === "none") return qsTr("no controller")
        const used = (l) => (l || []).filter(x => x.used).length
        const hidden = xp.genome && xp.genome.mlp ? xp.genome.mlp.hidden.reduce((a, b) => a + b, 0) : 0
        return qsTr("controller\n%1 neurons").arg(hidden)
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
            model: [qsTr("Set up"), qsTr("Train"), qsTr("Goal")]
            tips: [qsTr("Steps 1–4: craft, what evolves, goal, algorithm   Alt+1"), qsTr("Steps 5–6: run it and use the result   Alt+2"),
                   qsTr("How each flight is scored, as blocks or JavaScript   Alt+3")]
            badges: ["", ev.running ? "●" : (ev.generations.length > 0 ? String(ev.generations.length) : ""), ev.scriptErrorLine > 0 || (root.program && Blocks.problems(root.program).length > 0) ? "●" : ""]
            tints: ({ "Set up": Theme.tabTint["EVOLVE"], "Train": Theme.tabTint["EVOLVE"], "Goal": Theme.tabTint["EVOLVE"] })
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
                            linkColor: Theme.link
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
                                onActivated: { ev.setCraft(currentText); root.fitGoalToCraft() }
                            }
                        }
                        Label { visible: ev.io.error !== undefined && ev.io.error !== ""; text: ev.io.error || ""; color: Theme.bad; wrapMode: Text.Wrap; Layout.fillWidth: true; font.pixelSize: Theme.caption }
                        Button { visible: !!ev.io.miswired; text: qsTr("Re-wire for %1").arg(ev.io.craft); onClicked: { ev.setCraft(ev.io.craft); root.fitGoalToCraft() }
                            ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Drop the missing sensors and controls; the controller moves every control this craft has") }
                        Label { text: qsTr("Training worlds"); color: Theme.textMuted; font.pixelSize: Theme.small; Layout.topMargin: Theme.s1 }
                        TrainingWorlds { Layout.fillWidth: true }
                        Label { text: qsTr("Each flight"); color: Theme.textMuted; font.pixelSize: Theme.small; Layout.topMargin: Theme.s1 }
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

                        // controller wiring: sensors → controller → controls as a node canvas
                        PwSection {
                            id: ioSection
                            visible: xp.genome && xp.genome.preset !== "design"
                            title: qsTr("Sensors → controls  (%1 in · %2 out)").arg((ev.io.inputs || []).filter(x => x.used).length).arg((ev.io.outputs || []).filter(x => x.used).length)
                            hint: qsTr("Which sensors the controller reads and which controls it moves")
                            expanded: false
                            WiringCanvas {
                                Layout.fillWidth: true
                                io: ev.io
                                mode: xp.controller ? xp.controller.mode : "mlp"
                                hidden: xp.genome && xp.genome.mlp ? xp.genome.mlp.hidden : []
                                onToggled: (which, name, on) => ev.toggleIO(which, name, on)
                                onScaleEdited: (name, v) => ev.setInputScale(name, v)
                                onRewireRequested: { ev.setCraft(ev.io.craft); root.fitGoalToCraft() }
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
                    StepTitle { number: 3; title: qsTr("Goal"); summary: root.goalDef ? root.goalDef.title : root.blockState === "script" ? qsTr("hand-written script") : qsTr("your own blocks") }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        spacing: Theme.s2
                        Hint { text: qsTr("The goal turns each flight into a score (its fitness). Evolution keeps whatever scores highest, so the goal decides what “flying well” means.") }
                        PwPropertyRow { visible: root.goalsApply || root.blockState !== "script"; label: qsTr("Goal"); Layout.fillWidth: true
                            ComboBox {
                                id: goalCombo
                                Layout.fillWidth: true
                                readonly property bool own: !root.goalDef
                                model: root.goalList.map(g => Blocks.goalLabel(g, root.craftKind)).concat(own ? [root.blockState === "script" ? qsTr("Hand-written script") : qsTr("Your own blocks")] : [])
                                currentIndex: root.goalDef ? root.goalList.indexOf(root.goalDef) : root.goalList.length
                                onActivated: (i) => { if (i < root.goalList.length) root.applyGoal(root.goalList[i].id) }
                                delegate: ItemDelegate {
                                    id: goalItem
                                    required property int index
                                    required property var modelData
                                    readonly property var goal: index < root.goalList.length ? root.goalList[index] : null
                                    width: ListView.view ? ListView.view.width : implicitWidth
                                    text: modelData
                                    rightPadding: delBtn.visible ? delBtn.width + Theme.s2 : padding
                                    highlighted: ListView.view ? ListView.view.currentIndex === index : false
                                    // presets for other kinds of craft stay pickable, just quieter
                                    opacity: goal && !Blocks.suits(goal, root.craftKind) ? 0.55 : 1
                                    ToolButton { id: delBtn; visible: !!goalItem.goal && !!goalItem.goal.user; text: "×"
                                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                        onClicked: { goalCombo.popup.close(); root.deletePreset(goalItem.goal) }
                                        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Delete this saved preset") }
                                }
                            }
                        }
                        CheckBox { visible: root.otherGoals > 0 && (root.goalsApply || root.blockState !== "script"); text: qsTr("Show presets for other crafts")
                            checked: root.showAllGoals; onToggled: { root.showAllGoals = checked; checked = Qt.binding(() => root.showAllGoals) }
                            font.pixelSize: Theme.caption; padding: 0 }
                        PwPropertyRow { visible: !!root.goalDef && !!root.goalDef.param; label: root.goalDef && root.goalDef.param ? root.goalDef.param.label : ""; Layout.fillWidth: true
                            PwNumberField {
                                value: root.goalDef && root.goalDef.param ? Number(root.goalDef.param.get(root.program)) : 0
                                suffix: root.goalDef && root.goalDef.param ? root.goalDef.param.unit : ""
                                decimals: 0; step: 10
                                minimum: root.goalDef && root.goalDef.param ? root.goalDef.param.min : 0
                                onCommitted: (v) => root.commitBlocks(root.goalDef.program(Math.round(v)))
                            }
                        }
                        PwCard {
                            Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.small
                                text: root.goalDef ? root.goalDef.blurb
                                     : root.blockState === "blocks" ? qsTr("Your own goal, built from blocks.")
                                     : root.blockState === "edited" ? qsTr("Built from blocks, then edited by hand: training uses the edited JavaScript.")
                                     : xp.genome && xp.genome.preset === "design" ? qsTr("An autopilot script flies every design; designs that climb well for their weight score highest.")
                                     : qsTr("A hand-written goal: the Goal page shows exactly how it scores.") }
                            Label { text: qsTr("HOW IT IS SCORED"); color: Theme.textFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking; Layout.topMargin: Theme.s1 }
                            Repeater {
                                model: root.blockState === "blocks" ? Blocks.describe(root.program) : (xp.rewardTerms || []).map(t => ({ name: t, plain: Goals.designTerms[t] || "" }))
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: Theme.s2
                                    Label { text: modelData.name; font.family: Theme.mono; font.pixelSize: Theme.caption; color: Theme.tabTint["EVOLVE"]; Layout.preferredWidth: 72; Layout.alignment: Qt.AlignTop; elide: Text.ElideRight }
                                    Label { text: modelData.plain || qsTr("defined in the script"); Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.textMuted }
                                }
                            }
                            Label { Layout.fillWidth: true; font.pixelSize: Theme.caption; color: Theme.accent
                                linkColor: Theme.link
                                text: root.program ? qsTr("<a href='#'>Change it with blocks</a>") : qsTr("<a href='#'>See or edit the script</a>"); onLinkActivated: root.page = 2 }
                        }
                    }

                    // ---------------- ④ algorithm
                    StepTitle { id: algoTitle; number: 4; title: qsTr("Algorithm"); summary: algoSettings.displayName + " · " + qsTr("%1 × %2").arg(xp.population || 0).arg(xp.generations > 0 ? xp.generations : "∞") }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.leftMargin: Theme.s4; Layout.rightMargin: Theme.s4
                        spacing: Theme.s2
                        Hint { text: qsTr("The defaults work; bigger numbers search harder but take longer.") }
                        PwPropertyRow { label: qsTr("Population"); tip: Goals.glossary[2][1]; Layout.fillWidth: true
                            PwNumberField { value: xp.population || 64; decimals: 0; step: 4; minimum: 2; maximum: 100000; tip: Goals.glossary[2][1]; onCommitted: (v) => ev.set("population", Math.round(v)) } }
                        PwPropertyRow { label: qsTr("Generations"); tip: Goals.glossary[3][1] + qsTr(" 0 = until you stop it."); Layout.fillWidth: true
                            PwNumberField { value: xp.generations || 0; decimals: 0; step: 10; minimum: 0; tip: qsTr("0 = until stopped"); onCommitted: (v) => ev.set("generations", Math.round(v)) } }

                        // optimiser cards (ⓘ: how it works, pros / cons), "Compare all", and a folded "Tune …" section
                        AlgorithmSettings { id: algoSettings }

                        PwSection {
                            title: qsTr("Advanced")
                            hint: qsTr("Randomness, threads, checkpoints and episode details")
                            expanded: false
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
                        Hint { visible: !root.hasResults; text: qsTr("After the first generation you can replay the best flight here, fly it yourself with the evolved autopilot, or add it to a craft as a behaviour you start with a key.") }
                        Button {
                            Layout.fillWidth: true
                            highlighted: root.hasResults && !ev.running
                            enabled: root.hasResults
                            text: qsTr("✈︎  Fly it with the evolved autopilot")
                            onClicked: ev.flyWithAutopilot(root.behaviourName())
                            ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Opens the best candidate in FLY with its controller driving the outputs")
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.s1
                            Button { Layout.fillWidth: true; Layout.preferredWidth: 1; text: qsTr("Replay best"); enabled: root.hasResults; onClicked: ev.replay("best")
                                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Watch the best flight so far in the 3D view (Space plays / pauses)") }
                        }
                        Button {
                            Layout.fillWidth: true
                            text: qsTr("Add to craft as a behaviour…")
                            enabled: root.hasResults
                            onClicked: behaviourDlg.show(root.behaviourName())
                            ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay
                            ToolTip.text: qsTr("Keeps this controller on a craft under a name and a key, so in FLY you press the key and it flies (a craft can carry several)")
                        }
                        BehaviourDialog { id: behaviourDlg }

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

            // ======================================================== GOAL (blocks / JavaScript)
            ColumnLayout {
                spacing: Theme.s2
                PwSegmented {
                    id: goalView
                    Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3; Layout.topMargin: Theme.s2
                    model: [{ text: qsTr("Blocks"), tip: qsTr("Build the goal from blocks") }, { text: qsTr("JavaScript"), tip: qsTr("The script the blocks generate, or your own") }]
                    currentIndex: root.blockState === "script" && !root.goalsApply ? 1 : 0
                }
                StackLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumWidth: 0
                    Layout.preferredWidth: 0
                    currentIndex: goalView.currentIndex

                    // ---------------- blocks
                    ScrollView {
                        id: blocksScroll
                        contentWidth: availableWidth
                        clip: true
                        ColumnLayout {
                            width: blocksScroll.availableWidth
                            spacing: Theme.s2
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3
                                Label { Layout.fillWidth: true; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; font.weight: Font.DemiBold
                                    text: root.goalDef ? root.goalDef.title : root.blockState === "script" ? qsTr("Hand-written script") : root.blockState === "edited" ? qsTr("Blocks (edited by hand)") : qsTr("Your own blocks") }
                                Button { text: qsTr("Start from…"); onClicked: startMenu.popup(); visible: root.goalsApply || root.blockState !== "script"
                                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Replace the goal with a preset (its blocks are a good starting point)")
                                    Menu { id: startMenu; width: Math.max(implicitWidth, 360)
                                        // Instantiator, not Repeater: the list changes size (craft kind, saved presets) and Menu would append new items at the end
                                        Instantiator { model: root.goalList; onObjectAdded: (i, o) => startMenu.insertItem(i, o); onObjectRemoved: (i, o) => startMenu.removeItem(o); MenuItem { required property var modelData; text: Blocks.goalLabel(modelData, root.craftKind)
                                            opacity: Blocks.suits(modelData, root.craftKind) ? 1 : 0.55; onTriggered: root.applyGoal(modelData.id) } }
                                        MenuSeparator {}
                                        MenuItem { text: qsTr("Empty goal"); onTriggered: root.replaceGoal(Blocks.newProgram()) }
                                        MenuItem { text: qsTr("Show presets for other crafts"); checkable: true; checked: root.showAllGoals; enabled: root.otherGoals > 0
                                            onTriggered: { root.showAllGoals = checked; checked = Qt.binding(() => root.showAllGoals) } } } }
                                Button { text: qsTr("Save as preset…"); visible: root.blockState === "blocks"; onClicked: savePresetDlg.open()
                                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Keep these blocks as a preset of your own, listed with the others for this kind of craft") }
                                ToolButton { text: "×"; visible: !!root.goalDef && !!root.goalDef.user; onClicked: root.deletePreset(root.goalDef)
                                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Delete this saved preset") }
                            }
                            PwCard {
                                Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3
                                visible: root.blockState === "edited"
                                color: Theme.alpha(Theme.warn, 0.12); border.color: Theme.alpha(Theme.warn, 0.4)
                                Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.small
                                    text: qsTr("The JavaScript was edited by hand, so training uses that, not these blocks (shown faded below).") }
                                RowLayout {
                                    Layout.fillWidth: true
                                    Button { text: qsTr("Discard my edits"); onClicked: root.commitBlocks(root.program)
                                        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Go back to the script these blocks write") }
                                    Button { text: qsTr("Keep my edits"); onClicked: ev.setBlocks(null, xp.scripts.source, xp.rewardTerms || [])
                                        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Forget the blocks; the goal becomes a hand-written script") }
                                }
                            }
                            PwEmptyState {
                                Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3
                                visible: root.blockState === "script"
                                title: ""
                                text: root.goalsApply ? qsTr("Blocks can't read any code, so this goal stays JavaScript. “Start from…” builds a new goal from blocks instead, replacing this script.")
                                                      : qsTr("This script also flies the craft, so it stays JavaScript.")
                            }
                            Button {
                                Layout.leftMargin: Theme.s3
                                visible: root.blockState === "script"
                                highlighted: true
                                text: qsTr("Open the JavaScript")
                                onClicked: goalView.currentIndex = 1
                            }
                            EvolveBlockEditor {
                                Layout.fillWidth: true; Layout.minimumWidth: 0; Layout.preferredWidth: 0; Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3
                                visible: root.blockState !== "script"
                                program: root.program || Blocks.newProgram()
                                locked: root.blockState === "edited"
                                io: ev.io
                                brain: root.brainText()
                                onEdited: (p) => root.commitBlocks(p)
                                onWiringRequested: root.showWiring()
                                onRewireRequested: { ev.setCraft(ev.io.craft); root.fitGoalToCraft() }
                            }
                            Item { height: Theme.s4 }
                        }
                    }

                    // ---------------- javascript
                    ColumnLayout {
                        Layout.minimumWidth: 0
                        Layout.preferredWidth: 0
                        spacing: Theme.s2
                        Hint {
                            Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3; Layout.topMargin: Theme.s2
                            text: root.blockState === "script" ? qsTr("reward() scores every control tick, fitness() totals a flight, terminate() can end it early.")
                                  : root.blockState === "edited" ? qsTr("Edited by hand: training uses this script, not the blocks. The Blocks view can go back to them.")
                                  : qsTr("Generated from the blocks. Editing it here makes it a hand-written script (the blocks are kept, so you can go back).")
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: Theme.s3; Layout.rightMargin: Theme.s3
                            Flow {
                                Layout.fillWidth: true
                                spacing: Theme.s1
                                Repeater {
                                    model: jsTools.definedHooks(xp.scripts ? xp.scripts.source : "")
                                    Rectangle {
                                        required property string modelData
                                        radius: height / 2; color: Theme.accentSoft
                                        implicitWidth: hl.implicitWidth + Theme.s3; implicitHeight: hl.implicitHeight + 4
                                        Text { id: hl; anchors.centerIn: parent; text: modelData; color: Theme.text; font.pixelSize: Theme.micro; font.family: Theme.mono }
                                    }
                                }
                            }
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
                            Button { text: qsTr("Start from…"); onClicked: tplMenu.popup()
                                Menu { id: tplMenu; width: Math.max(implicitWidth, 360)
                                    Instantiator { model: root.goalList; onObjectAdded: (i, o) => tplMenu.insertItem(i, o); onObjectRemoved: (i, o) => tplMenu.removeItem(o); MenuItem { required property var modelData; text: qsTr("Goal: %1").arg(Blocks.goalLabel(modelData, root.craftKind))
                                        opacity: Blocks.suits(modelData, root.craftKind) ? 1 : 0.55; onTriggered: root.applyGoal(modelData.id) } }
                                    MenuSeparator {}
                                    MenuItem { text: qsTr("Craft design preset (autopilot)"); onTriggered: ev.setScript(ev.presetScript("design")) }
                                    MenuItem { text: qsTr("Show presets for other crafts"); checkable: true; checked: root.showAllGoals; enabled: root.otherGoals > 0
                                        onTriggered: { root.showAllGoals = checked; checked = Qt.binding(() => root.showAllGoals) } } } }
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
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator; visible: ev.status !== "" }
        Label { Layout.fillWidth: true; Layout.margins: Theme.s3; visible: ev.status !== ""; text: ev.status; color: Theme.textMuted; font.pixelSize: Theme.caption
                wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight }
    }
}
