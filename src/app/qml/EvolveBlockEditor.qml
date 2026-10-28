import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "EvolveBlocks.js" as Blocks

// EVOLVE Goal › Blocks: the goal as stacked blocks (EvolveBlocks.js) instead of JavaScript. Top to bottom it reads
// like the flight: the wiring the controller learns on (sensors → brain → controls), an optional target point, what
// scores every second, what ends a flight early, one-off points at the end, and (folded) a custom-code block.
// Every edit emits `edited(program)`; EvolvePanel compiles it and stores program + JavaScript together.
ColumnLayout {
    id: ed
    property var program: Blocks.newProgram()
    property var io: ({})               // EvolveModel.io (sensors / controls of the craft)
    property string brain: ""           // "12 neurons" etc.
    property bool locked: false         // the JavaScript was edited by hand: blocks are shown, not editable
    signal edited(var program)
    signal wiringRequested()
    signal rewireRequested()
    spacing: Theme.s2

    // apply fn to a copy of the program and emit it
    function edit(fn) { const p = Blocks.clone(program); fn(p); edited(p) }
    function addTarget(p) { if (!p.target) p.target = { ahead: 500, side: 0 } }
    readonly property var problems: Blocks.problems(program)
    readonly property color scoreTint: Theme.good
    readonly property color penaltyTint: Theme.dark ? "#f0883e" : "#bc4c00"   // orange: not the warning amber
    readonly property color stopTint: Theme.dark ? "#8b949e" : "#57606a"
    readonly property color pointsTint: Theme.dark ? "#39c5bb" : "#1b7c83"

    component SectionLabel: Label {
        Layout.fillWidth: true; Layout.topMargin: Theme.s2
        color: Theme.textFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking; wrapMode: Text.Wrap
    }
    // dashed-look full-width "+ Add …" placeholder in the section's colour; menu items explain themselves on hover
    component AddBlock: Rectangle {
        id: add
        property string text
        property color tint: Theme.accent
        property Menu menu
        signal clicked()
        Layout.fillWidth: true
        implicitHeight: addLabel.implicitHeight + Theme.s2 * 2
        radius: Theme.radius
        color: addHover.hovered ? Theme.alpha(tint, 0.10) : "transparent"
        border.color: Theme.alpha(tint, 0.5); border.width: Theme.hairline
        Label { id: addLabel; anchors.centerIn: parent; text: add.text; color: add.tint; font.pixelSize: Theme.small }
        HoverHandler { id: addHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: add.menu ? add.menu.popup() : add.clicked() }
    }
    component HintItem: MenuItem {
        property string hint
        ToolTip.visible: hovered && hint !== ""; ToolTip.delay: 300; ToolTip.text: hint
    }

    // One block: tinted card that reads as a sentence: title, fields, "worth × n", "as name", remove.
    component Block: Rectangle {
        id: blk
        property color tint: Theme.accent
        property string title
        property var spec: []            // field specs (EvolveBlocks.js)
        property var item: ({})          // the block's object in the program
        property bool named: false
        property bool weighted: false
        property string plain: ""
        signal field(string key, var value)
        signal remove()
        Layout.fillWidth: true
        implicitHeight: bcol.implicitHeight + Theme.s2 * 2
        radius: Theme.radius
        color: Theme.alpha(tint, Theme.dark ? 0.14 : 0.08)
        border.color: Theme.alpha(tint, 0.38); border.width: Theme.hairline
        Rectangle { width: 3; radius: 1.5; color: blk.tint; anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: Theme.s1 } }
        Label {
            id: removeBtn
            anchors { right: parent.right; top: parent.top; rightMargin: Theme.s2; topMargin: Theme.s1 }
            text: "✕"; color: rh.hovered ? Theme.bad : Theme.textFaint; font.pixelSize: Theme.small; padding: 2
            HoverHandler { id: rh; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: blk.remove() }
            ToolTip.visible: rh.hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Remove this block")
        }
        ColumnLayout {
            id: bcol
            anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: Theme.s3; rightMargin: Theme.s2 + removeBtn.width; topMargin: Theme.s2 }
            spacing: Theme.s1
            // "Stay near [height above ground] at [150 m] full penalty when off by [150 m] worth × [1] as [altitude]"
            Flow {
                Layout.fillWidth: true
                spacing: Theme.s1
                Label { text: blk.title; color: blk.tint; font.weight: Font.DemiBold; font.pixelSize: Theme.small; height: Theme.rowHeight; verticalAlignment: Text.AlignVCenter }
                Repeater {
                    model: blk.spec
                    Row {
                        id: fr
                        required property var modelData
                        readonly property var f: modelData
                        spacing: Theme.s1
                        Label { visible: fr.f.type !== "check" && fr.f.type !== "signal" && !!fr.f.label; text: fr.f.label || ""; color: Theme.textMuted; font.pixelSize: Theme.caption
                                anchors.verticalCenter: parent.verticalCenter }
                        Loader {
                            anchors.verticalCenter: parent.verticalCenter
                            sourceComponent: fr.f.type === "signal" ? signalField : fr.f.type === "when" ? whenField : fr.f.type === "check" ? checkField : numberField
                            Component { id: signalField
                                ComboBox {
                                    model: Blocks.signals.map(s => s.label)
                                    currentIndex: Math.max(0, Blocks.signals.findIndex(s => s.id === blk.item[fr.f.key]))
                                    font.pixelSize: Theme.caption
                                    onActivated: (i) => blk.field(fr.f.key, Blocks.signals[i].id) } }
                            Component { id: whenField
                                ComboBox {
                                    model: Blocks.stopKinds.map(k => k.endTitle)
                                    currentIndex: Math.max(0, Blocks.stopKinds.findIndex(k => k.id === blk.item[fr.f.key]))
                                    font.pixelSize: Theme.caption
                                    onActivated: (i) => blk.field(fr.f.key, Blocks.stopKinds[i].id) } }
                            Component { id: numberField
                                PwNumberField {
                                    value: Number(blk.item[fr.f.key]) || 0
                                    suffix: fr.f.unit === "@" ? Blocks.signal(blk.item.signal).unit : fr.f.unit
                                    decimals: 2; step: 1; minimum: fr.f.min !== undefined ? fr.f.min : -1e9
                                    onCommitted: (v) => blk.field(fr.f.key, v) } }
                            Component { id: checkField
                                CheckBox { text: fr.f.label; checked: !!blk.item[fr.f.key]; font.pixelSize: Theme.caption; padding: 0
                                    onToggled: blk.field(fr.f.key, checked) } }
                        }
                    }
                }
            }
            // "worth × 1   as altitude": how much it counts and its name in the charts, on their own line
            RowLayout {
                visible: blk.weighted || blk.named
                Layout.fillWidth: true
                spacing: Theme.s3
                Row {
                    visible: blk.weighted
                    spacing: Theme.s1
                    Label { text: qsTr("worth ×"); color: Theme.textMuted; font.pixelSize: Theme.caption; anchors.verticalCenter: parent.verticalCenter }
                    PwNumberField { implicitWidth: 52; value: Number(blk.item.weight); decimals: 3; step: 0.1
                        tip: qsTr("How much this score counts. Keep helper scores small next to the main one.")
                        onCommitted: (v) => blk.field("weight", v) }
                }
                Row {
                    visible: blk.named
                    spacing: Theme.s1
                    Label { text: qsTr("as"); color: Theme.textFaint; font.pixelSize: Theme.caption; anchors.verticalCenter: parent.verticalCenter }
                    TextField {
                        implicitWidth: 96
                        text: blk.item.name || ""
                        color: Theme.textMuted
                        font.family: Theme.mono; font.pixelSize: Theme.caption
                        validator: RegularExpressionValidator { regularExpression: /^[A-Za-z_$][\w$ ]*$/ }
                        onEditingFinished: { const n = text.trim().replace(/\s+/g, "_"); if (n !== blk.item.name) blk.field("name", n); else text = n }
                        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("The name this score has in the charts and history.csv")
                    }
                }
            }
            Label { visible: blk.plain !== ""; text: blk.plain; Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.textMuted; font.pixelSize: Theme.caption }
        }
    }

    // ---------------- problems first: they decide whether the goal works at all
    PwCard {
        visible: ed.problems.length > 0
        color: Theme.alpha(Theme.bad, 0.10); border.color: Theme.alpha(Theme.bad, 0.4)
        Repeater {
            model: ed.problems
            Label { required property string modelData; text: "⚠︎ " + modelData; color: Theme.bad; wrapMode: Text.Wrap; Layout.fillWidth: true; font.pixelSize: Theme.caption }
        }
        Button { visible: !ed.program.target && ed.problems.some(x => x.indexOf("target") >= 0); text: qsTr("Set a target point")
                 onClicked: ed.edit(p => ed.addTarget(p)) }
    }

    // ---------------- wiring: what the controller reads and drives (the craft's own names)
    PwCard {
        id: wiring
        padding: Theme.s2
        readonly property var ins: (ed.io.inputs || []).filter(x => x.used)
        readonly property var outs: (ed.io.outputs || []).filter(x => x.used)
        border.color: outs.length === 0 || !!ed.io.error ? Theme.alpha(Theme.bad, 0.5) : Theme.separator
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.s1
            Label { text: qsTr("WIRING"); color: Theme.textFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking; Layout.fillWidth: true }
            Label { text: qsTr("<a href='#'>Change</a>"); linkColor: Theme.link; font.pixelSize: Theme.caption; onLinkActivated: ed.wiringRequested()
                ToolTip.visible: wch.hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Choose the sensors and controls in Set up › What evolves"); HoverHandler { id: wch } }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.s1
            ColumnLayout {
                Layout.fillWidth: true; Layout.preferredWidth: 1; spacing: 0
                Label { text: qsTr("reads %1 sensors").arg(wiring.ins.length); font.pixelSize: Theme.caption; font.weight: Font.DemiBold }
                Label { Layout.fillWidth: true; text: wiring.ins.map(x => Blocks.sensorLabel(x.name)).join(", "); color: Theme.textMuted; font.pixelSize: Theme.micro; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight }
            }
            Label { text: "→"; color: Theme.textFaint }
            Label { text: ed.brain; font.pixelSize: Theme.caption; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; Layout.maximumWidth: 80 }
            Label { text: "→"; color: Theme.textFaint }
            ColumnLayout {
                Layout.fillWidth: true; Layout.preferredWidth: 1; spacing: 0
                Label { text: qsTr("moves %1 controls").arg(wiring.outs.length); font.pixelSize: Theme.caption; font.weight: Font.DemiBold; color: wiring.outs.length === 0 ? Theme.bad : Theme.text }
                Label { Layout.fillWidth: true; text: wiring.outs.map(x => x.name).join(", "); color: Theme.textMuted; font.pixelSize: Theme.micro; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight }
            }
        }
        Label { visible: !!ed.io.error; text: ed.io.error || ""; color: Theme.bad; wrapMode: Text.Wrap; Layout.fillWidth: true; font.pixelSize: Theme.caption }
        Button { visible: !!ed.io.miswired; text: qsTr("Re-wire for %1").arg(ed.io.craft); onClicked: ed.rewireRequested() }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.s2
        enabled: !ed.locked
        opacity: ed.locked ? 0.55 : 1

        // ---------------- target point (only while a block needs it, or the user added one)
        SectionLabel { visible: !!ed.program.target; text: qsTr("TARGET POINT, FROM THE START") }
        Block {
            visible: !!ed.program.target
            tint: Theme.info; title: qsTr("Target")
            item: ed.program.target || ({})
            spec: [{ key: "ahead", label: qsTr("ahead"), type: "number", unit: "m" }, { key: "side", label: qsTr("to the right"), type: "number", unit: "m" }]
            plain: qsTr("Negative values go behind / to the left.")
            onField: (k, v) => ed.edit(p => p.target[k] = v)
            onRemove: ed.edit(p => p.target = null)
        }

        // ---------------- per-tick scores
        SectionLabel { text: qsTr("EVERY SECOND OF FLIGHT, SCORE") }
        Repeater {
            model: ed.program.terms || []
            Block {
                required property var modelData
                required property int index
                readonly property var k: Blocks.termKind(modelData.kind)
                tint: k && k.color === "penalty" ? ed.penaltyTint : ed.scoreTint
                title: k ? k.title : modelData.kind
                named: true; weighted: true
                spec: k ? k.fields : []
                item: modelData
                plain: k ? k.plain(modelData) : ""
                onField: (key, v) => ed.edit(p => { p.terms[index][key] = v; if (key === "signal" && Blocks.signal(v).needsTarget) ed.addTarget(p) })
                onRemove: ed.edit(p => p.terms.splice(index, 1))
            }
        }
        AddBlock { text: qsTr("+ Add a score"); tint: ed.scoreTint; menu: termMenu
            Menu { id: termMenu
                Repeater { model: Blocks.termKinds
                    HintItem { required property var modelData; text: modelData.title; hint: modelData.hint
                        onTriggered: ed.edit(p => { p.terms.push(Blocks.newTerm(modelData.id, p)); if (modelData.needsTarget) ed.addTarget(p) }) } } } }

        // ---------------- early stops
        SectionLabel { text: qsTr("END THE FLIGHT EARLY IF") }
        Repeater {
            model: ed.program.stops || []
            Block {
                required property var modelData
                required property int index
                readonly property var k: Blocks.stopKind(modelData.kind)
                tint: ed.stopTint; title: k ? k.title : modelData.kind
                spec: k ? k.fields : []
                item: modelData
                onField: (key, v) => ed.edit(p => p.stops[index][key] = v)
                onRemove: ed.edit(p => p.stops.splice(index, 1))
            }
        }
        Label { visible: (ed.program.stops || []).length === 0; text: qsTr("Every flight runs its full length."); color: Theme.textFaint; font.pixelSize: Theme.caption }
        AddBlock { text: qsTr("+ Add a reason to stop"); tint: ed.stopTint; menu: stopMenu
            Menu { id: stopMenu
                Repeater { model: Blocks.stopKinds
                    HintItem { required property var modelData; text: modelData.title; hint: modelData.hint
                        enabled: !(ed.program.stops || []).some(x => x.kind === modelData.id)
                        onTriggered: ed.edit(p => { p.stops.push(Blocks.newStop(modelData.id)); if (modelData.needsTarget) ed.addTarget(p) }) } } } }

        // ---------------- end-of-flight points: "If [it crashes] add [-20 points] + up to [10] for time left"
        SectionLabel { text: qsTr("WHEN THE FLIGHT ENDS") }
        Repeater {
            model: ed.program.bonuses || []
            Block {
                required property var modelData
                required property int index
                tint: ed.pointsTint; title: qsTr("If"); named: true
                spec: [{ key: "when", type: "when" }, { key: "points", label: qsTr("give"), type: "number", unit: qsTr("points") }]
                      .concat(modelData.when === "reached" ? [{ key: "timeBonus", label: qsTr("plus up to"), type: "number", unit: qsTr("more for arriving early"), min: 0 }] : [])
                item: modelData
                plain: Blocks.describe({ terms: [], stops: [], bonuses: [modelData] })[0].plain
                onField: (key, v) => ed.edit(p => { p.bonuses[index][key] = v; if (key === "when" && Blocks.stopKind(v).needsTarget) ed.addTarget(p) })
                onRemove: ed.edit(p => p.bonuses.splice(index, 1))
            }
        }
        AddBlock { text: qsTr("+ Add points at the end"); tint: ed.pointsTint; onClicked: ed.edit(p => p.bonuses.push(Blocks.newBonus(p))) }

        // ---------------- escape hatch, folded unless used
        PwSection {
            Layout.topMargin: Theme.s2
            title: qsTr("Custom code")
            hint: qsTr("JavaScript added after the blocks, for anything they can't say")
            expanded: !!(ed.program.code || "").trim()
            Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.textMuted; font.pixelSize: Theme.caption
                text: qsTr("Added after the blocks: helper functions, control() to fly the craft yourself, descriptor() for MAP-Elites. The blocks already write terms(), reward(), terminate() and fitness().") }
            ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.max(56, Math.min(200, codeArea.implicitHeight))
                TextArea {
                    id: codeArea
                    text: ed.program.code || ""
                    placeholderText: "function descriptor(ctx) { return [ctx.state.x, ctx.state.agl]; }"
                    font.family: Theme.mono; font.pixelSize: Theme.caption
                    wrapMode: TextEdit.NoWrap
                    onEditingFinished: if (text !== (ed.program.code || "")) ed.edit(p => p.code = text)
                }
            }
        }
    }
}
