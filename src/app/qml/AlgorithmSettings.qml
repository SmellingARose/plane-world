pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "EvolveAlgorithms.js" as Algos

// EVOLVE step ④ "how it searches": the optimiser as readable cards (plain name, what it does, best for; ⓘ opens how it
// works with a pros / cons / best-for table; "Compare all" opens AlgorithmCompare), then a folded "Tune …" section:
// how the step size changes (with this experiment's numbers), the common parameters with plain labels, explanation,
// higher / lower effects and ↺ default, and an "Expert" fold for the rest. The stored values (algorithm.kind and the
// raw keys from EvolveModel.algorithmSchema) are unchanged; all words come from EvolveAlgorithms.js.
ColumnLayout {
    id: algo
    readonly property var ev: EvolveModel
    readonly property var xp: EvolveModel.experiment
    readonly property string kind: xp.algorithm ? xp.algorithm.kind : "simple-es"
    readonly property var vals: xp.algorithm && xp.algorithm.values ? xp.algorithm.values : ({})   // stored as algorithm.values.<key>
    readonly property string displayName: Algos.name(kind)
    readonly property var kinds: Algos.ordered(ev.algorithmKinds)
    readonly property var schema: ev.algorithmSchema(kind)
    readonly property var story: Algos.stepStory(kind, xp, vals, ev.geneCount)
    property bool browsing: false        // all cards listed (else only the current one)
    property string detailsKind: ""      // card whose "how it works" is open
    Layout.fillWidth: true
    spacing: Theme.s2

    // palette "EVOLVE: show algorithm settings": the tuning section open (ⓘ on the card stays as the user left it)
    function reveal() { tune.expanded = true }
    function compare() { cmp.open() }
    function choose(k) { if (k !== kind) ev.set("algorithm.kind", k); browsing = false }

    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Theme.s1
        Label { text: qsTr("HOW IT SEARCHES"); color: Theme.textFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking; Layout.fillWidth: true }
        Label { font.pixelSize: Theme.caption; linkColor: Theme.link; text: "<a href='#'>" + qsTr("Compare all") + "</a>"; onLinkActivated: cmp.open()
            HoverHandler { cursorShape: Qt.PointingHandCursor } }
    }

    Repeater {
        model: algo.kinds
        delegate: AlgoCard {}
    }
    Label {
        font.pixelSize: Theme.caption
        linkColor: Theme.link
        text: "<a href='#'>" + (algo.browsing ? qsTr("Done") : qsTr("Choose a different method (%1 more)").arg(algo.kinds.length - 1)) + "</a>"
        onLinkActivated: algo.browsing = !algo.browsing
        HoverHandler { cursorShape: Qt.PointingHandCursor }
    }

    PwSection {
        id: tune
        title: qsTr("Tune %1").arg(algo.displayName)
        hint: qsTr("Step size, mutation and the other settings of this method")
        expanded: false
        Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.textMuted; font.pixelSize: Theme.caption
            text: algo.schema.length ? qsTr("Every setting has a working default; ↺ puts one back.")
                                     : qsTr("This method has no settings of its own.") }
        PwCard {
            visible: algo.story !== null
            Label { text: algo.story ? algo.story.title : ""; font.weight: Font.DemiBold; font.pixelSize: Theme.small }
            Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.textMuted; text: algo.story ? algo.story.text : "" }
        }
        Repeater { model: Algos.rows(algo.kind, algo.schema, "common"); delegate: ParamRow {} }
        PwSection {
            id: expert
            readonly property var rows: Algos.rows(algo.kind, algo.schema, "expert")
            visible: rows.length > 0
            title: qsTr("Expert settings (%1)").arg(rows.length)
            expanded: false
            Repeater { model: expert.rows; delegate: ParamRow {} }
        }
    }

    AlgorithmCompare { id: cmp; current: algo.kind; recommended: Algos.recommended(algo.xp); kinds: algo.kinds; onChosen: (k) => algo.choose(k) }

    // ---------------------------------------------------------------- one optimiser
    component AlgoCard: Rectangle {
        id: card
        required property string modelData
        readonly property var info: Algos.info(modelData)
        readonly property bool current: modelData === algo.kind
        readonly property bool open: algo.detailsKind === modelData
        readonly property string issue: Algos.problem(modelData, algo.xp, algo.ev.geneCount)
        visible: algo.browsing || current
        Layout.fillWidth: true
        implicitHeight: col.implicitHeight + Theme.s3 * 2
        radius: Theme.radius
        color: current ? Theme.accentSoft : ma.containsMouse ? Theme.hover : Theme.card
        border.width: current ? 1.5 : Theme.hairline
        border.color: current ? Theme.accent : Theme.separator
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: card.current ? Qt.ArrowCursor : Qt.PointingHandCursor
            onClicked: algo.choose(card.modelData)
        }
        ColumnLayout {
            id: col
            x: Theme.s3; y: Theme.s3
            width: card.width - Theme.s3 * 2
            spacing: Theme.s1
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s2
                Rectangle { implicitWidth: 12; implicitHeight: 12; radius: 6; color: "transparent"; border.width: 1.5; border.color: card.current ? Theme.accent : Theme.textFaint
                    Rectangle { anchors.centerIn: parent; width: 6; height: 6; radius: 3; color: Theme.accent; visible: card.current } }
                Label { text: card.info.name; font.weight: Font.DemiBold; font.pixelSize: Theme.body }
                Rectangle {
                    visible: Algos.recommended(algo.xp) === card.modelData
                    implicitWidth: rec.implicitWidth + Theme.s2; implicitHeight: rec.implicitHeight + 2; radius: height / 2
                    color: Qt.rgba(Theme.good.r, Theme.good.g, Theme.good.b, 0.16)
                    Label { id: rec; anchors.centerIn: parent; text: qsTr("Recommended"); color: Theme.good; font.pixelSize: Theme.micro; font.weight: Font.DemiBold }
                }
                Item { Layout.fillWidth: true }
                ToolButton {
                    text: card.open ? "ⓘ ▴" : "ⓘ"
                    font.pixelSize: Theme.small
                    implicitHeight: 22
                    onClicked: algo.detailsKind = card.open ? "" : card.modelData
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay
                    ToolTip.text: card.open ? qsTr("Hide the explanation") : qsTr("How it works, pros and cons")
                }
            }
            Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.textMuted; text: card.info.tagline }
            Label { visible: card.issue !== ""; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.warn; text: "⚠ " + card.issue }

            ColumnLayout {
                visible: card.open
                Layout.fillWidth: true
                Layout.topMargin: Theme.s1
                spacing: Theme.s2
                Rectangle { Layout.fillWidth: true; implicitHeight: Theme.hairline; color: Theme.separator }
                Label { visible: card.info.how !== ""; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; text: card.info.how }
                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: Theme.s2; rowSpacing: Theme.s1
                    FactLabel { text: qsTr("Good at") }
                    FactList { items: card.info.pros; mark: "+"; markColor: Theme.good }
                    FactLabel { text: qsTr("Watch out") }
                    FactList { items: card.info.cons; mark: "−"; markColor: Theme.warn }
                    FactLabel { text: qsTr("Best for") }
                    FactText { text: card.info.bestFor }
                    FactLabel { text: qsTr("Genes"); visible: card.info.genes !== "" }
                    FactText { text: card.info.genes }
                    FactLabel { text: qsTr("Step size") }
                    FactText { text: card.info.step }
                    FactLabel { text: qsTr("Needs"); visible: !!card.info.needs }
                    FactText { text: card.info.needs || ""; visible: !!card.info.needs }
                }
                Button {
                    visible: !card.current
                    text: qsTr("Use %1").arg(card.info.name)
                    onClicked: algo.choose(card.modelData)
                }
            }
        }
    }
    component FactLabel: Label {
        Layout.alignment: Qt.AlignTop | Qt.AlignLeft
        Layout.preferredWidth: 64
        color: Theme.textFaint; font.pixelSize: Theme.micro; font.weight: Font.DemiBold
        wrapMode: Text.WordWrap
    }
    component FactText: Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption }
    component FactList: ColumnLayout {
        id: fl
        property var items: []
        property string mark
        property color markColor
        Layout.fillWidth: true
        spacing: 2
        Repeater {
            model: fl.items
            delegate: RowLayout {
                id: fact
                required property string modelData
                Layout.fillWidth: true
                spacing: Theme.s1
                Label { text: fl.mark; color: fl.markColor; font.pixelSize: Theme.caption; font.weight: Font.Bold; Layout.alignment: Qt.AlignTop; Layout.preferredWidth: 8 }
                Label { text: fact.modelData; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption }
            }
        }
    }

    // ---------------------------------------------------------------- one parameter
    // Plain label (raw key on hover), editor, ↺ default; explanation, the chosen option in words, higher / lower effect.
    component ParamRow: ColumnLayout {
        id: pr
        required property var modelData          // { key, type, help, options, default } from algorithmSchema
        readonly property string key: modelData.key
        readonly property var meta: Algos.param(algo.kind, key, modelData.help)
        readonly property bool isSet: algo.vals[key] !== undefined
        readonly property var cur: isSet ? algo.vals[key] : modelData["default"]
        readonly property bool isAuto: !!meta.auto && !(Number(cur) > 0)
        readonly property bool changed: isSet && String(cur) !== String(modelData["default"]) && !(modelData.type === "flag" && !!cur === !!modelData["default"])
        readonly property var autoVal: Algos.autoValue(algo.kind, key, algo.xp, algo.vals, algo.ev.geneCount)
        readonly property string unused: Algos.unusedBecause(algo.kind, key, algo.vals, algo.schema)
        function put(v) { algo.ev.set("algorithm.values." + key, v) }
        Layout.fillWidth: true
        Layout.topMargin: Theme.s1
        spacing: 2

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.s1
            opacity: pr.unused !== "" ? 0.5 : 1
            Label {
                Layout.fillWidth: true
                text: pr.meta.label
                font.pixelSize: Theme.small
                elide: Text.ElideRight
                HoverHandler { id: lh }
                ToolTip.visible: lh.hovered
                ToolTip.delay: Theme.tooltipDelay
                ToolTip.text: qsTr("algorithm.values.%1 · default %2").arg(pr.key).arg(String(pr.modelData["default"])) + (pr.modelData.help ? "\n" + pr.modelData.help : "")
            }
            Label {
                visible: pr.modelData.type === "number" && (pr.isAuto || !!pr.meta.unit)
                text: pr.isAuto ? (pr.autoVal !== undefined ? qsTr("auto · %1").arg(pr.autoVal) : qsTr("auto")) : (pr.meta.unit || "")
                color: Theme.textFaint; font.pixelSize: Theme.caption
            }
            PwNumberField {
                visible: pr.modelData.type === "number"
                Layout.preferredWidth: 72
                value: Number(pr.cur)
                decimals: pr.meta.decimals !== undefined ? pr.meta.decimals : 4
                step: pr.meta.step || 0.01
                minimum: pr.meta.min !== undefined ? pr.meta.min : -1e9
                maximum: pr.meta.max !== undefined ? pr.meta.max : 1e9
                tip: pr.meta.label
                onCommitted: (v) => pr.put(pr.meta.auto && v <= 0 ? null : (pr.meta.decimals === 0 ? Math.round(v) : v))
            }
            Switch {
                visible: pr.modelData.type === "flag"
                checked: !!pr.cur && pr.cur !== 0
                onToggled: pr.put(checked)
            }
            ComboBox {
                visible: pr.modelData.type === "choice" && (pr.modelData.options || []).length > 3
                Layout.preferredWidth: 130
                model: (pr.modelData.options || []).map(o => (pr.meta.optionNames || {})[o] || o)
                currentIndex: Math.max(0, (pr.modelData.options || []).indexOf(String(pr.cur)))
                onActivated: (i) => pr.put(pr.modelData.options[i])
            }
            ToolButton {
                text: "↺"
                enabled: pr.changed
                opacity: pr.changed ? 1 : 0.25
                implicitWidth: 24; implicitHeight: 22
                onClicked: pr.put(null)
                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay
                ToolTip.text: qsTr("Back to the default (%1)").arg(String(pr.modelData["default"]))
            }
        }
        PwSegmented {
            visible: pr.modelData.type === "choice" && (pr.modelData.options || []).length <= 3
            model: (pr.modelData.options || []).map(o => (pr.meta.optionNames || {})[o] || o)
            currentIndex: Math.max(0, (pr.modelData.options || []).indexOf(String(pr.cur)))
            onActivated: (i) => pr.put(pr.modelData.options[i])
        }
        Label {
            visible: pr.unused !== ""
            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.warn
            text: pr.unused
        }
        Label {
            visible: !!pr.meta.help
            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.textMuted
            text: pr.meta.help || ""
        }
        Label {
            readonly property string chosen: pr.modelData.type === "choice" && pr.meta.options ? (pr.meta.options[String(pr.cur)] || "") : ""
            visible: chosen !== ""
            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption
            text: "▸ " + chosen
        }
        Label {
            visible: !!pr.meta.effect
            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.textFaint
            textFormat: Text.StyledText
            text: pr.meta.effect ? qsTr("<b>Higher</b>: %1<br><b>Lower</b>: %2").arg(pr.meta.effect.up).arg(pr.meta.effect.down) : ""
        }
    }
}
