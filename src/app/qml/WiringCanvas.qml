pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import "EvolveBlocks.js" as Blocks

// EVOLVE controller wiring as a node canvas (n8n look): the craft's sensors on the left, the controller in the
// middle, the craft's controls on the right, with a curved wire for every sensor the controller reads and every
// control it moves. Unused nodes are dim with an empty port.
//   click a node or its port / Space / Return   connect or disconnect it
//   drag a port onto the controller              connect it; drag a wired port off into empty space to disconnect
//   the ÷ field on a sensor                      the reading is divided by it before the controller sees it
// Columns are laid out automatically and squeeze to the inspector width; a tall canvas scrolls inside itself, and the
// controller (and a short controls column) stay in view while you scroll through the sensors.
// Used by EvolvePanel (Set up › What evolves), which connects the signals to EvolveModel.
Item {
    id: cv
    property var io: ({})                 // EvolveModel.io
    property string mode: "mlp"           // controller.mode: mlp | neat | script | none
    property var hidden: []               // genome.mlp.hidden (MLP layer sizes)
    property real maxViewHeight: 440
    signal toggled(string which, string name, bool on)
    signal scaleEdited(string name, real scale)
    signal rewireRequested()

    readonly property var ins: io.inputs || []
    readonly property var outs: io.outputs || []
    readonly property int nIn: ins.filter(x => x.used).length
    readonly property int nOut: outs.filter(x => x.used).length
    readonly property color hot: Theme.tabTint["EVOLVE"]
    readonly property bool noControls: outs.length > 0 && nOut === 0
    readonly property bool noSensors: ins.length > 0 && nIn === 0
    readonly property bool broken: noControls || noSensors || (outs.length === 0 && !!io.craft)
    readonly property color wireTint: broken ? Theme.bad : hot

    // ---- layout (content coordinates)
    readonly property bool narrow: width < 460
    readonly property real ctrlW: narrow ? 78 : 120
    readonly property real ctrlH: 84
    readonly property bool scrolls: contentH > maxViewHeight
    readonly property real laneW: width - (scrolls ? 12 : 0)          // keep the right column clear of the scroll bar
    readonly property real nodeW: Math.max(70, Math.min(230, (laneW - ctrlW - 2 * (narrow ? 26 : 56)) / 2))
    readonly property real gap: (laneW - ctrlW - 2 * nodeW) / 2
    readonly property real sensorH: 50
    readonly property real controlH: 40
    readonly property real rowGap: 6
    readonly property real padY: 8
    readonly property real ctrlX: nodeW + gap
    readonly property real outX: laneW - nodeW
    readonly property real sensorsH: Math.max(1, ins.length) * (sensorH + rowGap) - rowGap
    readonly property real controlsH: Math.max(1, outs.length) * (controlH + rowGap) - rowGap
    readonly property real contentH: Math.max(sensorsH, controlsH, ctrlH) + 2 * padY
    // sticky: a column shorter than the view follows the scroll, so its wires stay visible
    function stickyY(h) {
        if (h + 2 * padY >= contentH) return padY
        return Math.max(padY, Math.min(contentH - padY - h, flick.contentY + flick.height / 2 - h / 2))
    }
    readonly property real ctrlY: stickyY(ctrlH)
    readonly property real controlsY: controlsH + 2 * padY < flick.height ? stickyY(controlsH) : (contentH - controlsH) / 2
    readonly property real sensorsY: (contentH - sensorsH) / 2
    function sensorPortY(i) { return sensorsY + i * (sensorH + rowGap) + sensorH / 2 }
    function controlPortY(i) { return controlsY + i * (controlH + rowGap) + controlH / 2 }

    // a port being dragged: { which, name, used, x0, y0 }, and the pointer in content coordinates
    property var dragging: null
    property point dragPos: Qt.point(0, 0)
    function overController(p) { return p.x >= ctrlX - 10 && p.x <= ctrlX + ctrlW + 10 && p.y >= ctrlY - 10 && p.y <= ctrlY + ctrlH + 10 }

    function kindWords(o) {
        return ({ servo: qsTr("surface"), motor: qsTr("motor"), jet: qsTr("jet throttle"), rocket: qsTr("rocket throttle"),
                  solid: qsTr("solid booster"), gimbal: qsTr("engine tilt") })[o.kind] || o.kind
    }
    function toggleText(used) { return used ? qsTr("Click or press Space to disconnect.") : qsTr("Click or press Space to connect.") }
    readonly property string ctrlTitle: ({ mlp: qsTr("Controller"), neat: qsTr("NEAT"), script: qsTr("Script"), none: qsTr("No controller") })[mode] || mode
    readonly property string ctrlSub: {
        if (mode === "neat") return qsTr("grows its own network")
        if (mode === "script") return qsTr("flies with control()")
        if (mode === "none") return qsTr("nothing learns")
        return qsTr("%1 neurons").arg((hidden || []).reduce((a, b) => a + b, 0))
    }
    // "rotor +0.38, -0.22 m  CW  9.8 N" -> "+0.38,-0.22 CW" for the node (the tooltip has it all)
    function whereShort(w) { const m = /rotor ([-+][\d.]+), ([-+][\d.]+) m\s+(CW|CCW)/.exec(w); return m ? m[1] + "," + m[2] + " " + m[3] : w }
    function rangeWords(o) { return o.lo === -1 && o.hi === 1 ? "±1" : o.lo + "…" + o.hi }
    readonly property string ctrlLayers: mode === "mlp" ? ((hidden || []).length ? (hidden || []).join(" · ") : qsTr("no hidden layer")) : ""

    implicitHeight: col.implicitHeight

    component Head: Label { color: Theme.textFaint; font.pixelSize: Theme.micro; font.letterSpacing: Theme.sectionTracking; elide: Text.ElideRight }

    // a bezier wire, horizontal at both ends
    component Wire: Shape {
        id: w
        property real x0
        property real y0
        property real x1
        property real y1
        property color color: cv.wireTint
        property bool dashed: false
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: w.color; strokeWidth: 1.6; fillColor: "transparent"
            strokeStyle: w.dashed ? ShapePath.DashLine : ShapePath.SolidLine; dashPattern: [3, 3]
            startX: w.x0; startY: w.y0
            PathCubic {
                x: w.x1; y: w.y1
                control1X: w.x0 + Math.max(16, (w.x1 - w.x0) * 0.55); control1Y: w.y0
                control2X: w.x1 - Math.max(16, (w.x1 - w.x0) * 0.55); control2Y: w.y1
            }
        }
    }

    // a port: filled when wired, a hollow ring when not. Click toggles; drag onto the controller connects, dragging a
    // wired port off anywhere else disconnects.
    component Port: Item {
        id: port
        property string which
        property var node
        property bool used
        width: 18; height: 18
        Rectangle {
            anchors.centerIn: parent
            width: pma.containsMouse ? 12 : 10; height: width; radius: width / 2
            color: port.used ? cv.wireTint : Theme.surfaceRaised
            border.color: port.used ? cv.wireTint : Theme.textFaint; border.width: 1.5
            Behavior on width { NumberAnimation { duration: Theme.fast } }
        }
        MouseArea {
            id: pma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.CrossCursor
            preventStealing: true
            property point start
            onPressed: (m) => start = Qt.point(m.x, m.y)
            onPositionChanged: (m) => {
                if (!pressed) return
                if (!cv.dragging && Math.hypot(m.x - start.x, m.y - start.y) > 4) {
                    const c = port.mapToItem(flick.contentItem, port.width / 2, port.height / 2)
                    cv.dragging = { which: port.which, name: port.node.name, used: port.used, x0: c.x, y0: c.y }
                }
                if (cv.dragging) cv.dragPos = mapToItem(flick.contentItem, m.x, m.y)
            }
            onReleased: {
                const d = cv.dragging
                cv.dragging = null
                if (!d) { cv.toggled(port.which, port.node.name, !port.used); return }
                const over = cv.overController(cv.dragPos)
                if (over && !d.used) cv.toggled(d.which, d.name, true)
                else if (!over && d.used) cv.toggled(d.which, d.name, false)
            }
            onCanceled: cv.dragging = null
            ToolTip.visible: containsMouse && !pressed
            ToolTip.delay: Theme.tooltipDelay
            ToolTip.text: port.used ? qsTr("Wired. Click, or drag the wire away, to disconnect.")
                                    : qsTr("Not wired. Click, or drag onto the controller, to connect.")
        }
    }

    // a node card (sensor or control): click, Space or Return toggles it
    component NodeCard: Rectangle {
        id: card
        property string which
        property var node
        property string tip
        readonly property bool used: !!node && node.used
        activeFocusOnTab: true
        radius: Theme.radiusSmall
        color: used ? Theme.surfaceRaised : Theme.alpha(Theme.surfaceRaised, 0.4)
        border.color: activeFocus ? Theme.accent : used ? Theme.alpha(cv.wireTint, 0.7) : Theme.separator
        border.width: activeFocus ? 2 : 1
        Behavior on color { ColorAnimation { duration: Theme.fast } }
        Accessible.role: Accessible.CheckBox
        Accessible.checkable: true
        Accessible.checked: used
        // VoiceOver / assistive "press" and "toggle" wire it in or out, like a click
        Accessible.onPressAction: cv.toggled(which, node.name, !used)
        Accessible.onToggleAction: cv.toggled(which, node.name, !used)
        Keys.onSpacePressed: cv.toggled(which, node.name, !used)
        Keys.onReturnPressed: cv.toggled(which, node.name, !used)
        // keep the focused node in view
        onActiveFocusChanged: if (activeFocus) {
            if (y < flick.contentY) flick.contentY = Math.max(0, y - cv.padY)
            else if (y + height > flick.contentY + flick.height) flick.contentY = Math.min(flick.contentHeight - flick.height, y + height - flick.height + cv.padY)
        }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { card.forceActiveFocus(); cv.toggled(card.which, card.node.name, !card.used) }
            ToolTip.visible: containsMouse
            ToolTip.delay: Theme.tooltipDelay
            ToolTip.text: card.tip
        }
    }

    Column {
        id: col
        width: cv.width
        spacing: Theme.s2

        // ---- problems
        Rectangle {
            id: banner
            readonly property string text: !!cv.io.error ? cv.io.error
                : cv.outs.length === 0 && !!cv.io.craft ? qsTr("%1 has no controls the controller could move.").arg(cv.io.craft)
                : cv.noControls ? qsTr("The controller moves nothing: connect at least one control on the right.")
                : cv.noSensors ? qsTr("The controller is blind: connect at least one sensor on the left.") : ""
            visible: text !== ""
            width: parent.width
            height: visible ? bcol.implicitHeight + 2 * Theme.s2 : 0
            radius: Theme.radiusSmall
            color: Theme.alpha(Theme.bad, 0.10); border.color: Theme.alpha(Theme.bad, 0.4)
            Column {
                id: bcol
                x: Theme.s2; y: Theme.s2; width: parent.width - 2 * Theme.s2
                spacing: Theme.s1
                Label { width: parent.width; text: "⚠︎ " + banner.text; color: Theme.bad; wrapMode: Text.Wrap; font.pixelSize: Theme.caption }
                Button { visible: !!cv.io.miswired; text: qsTr("Re-wire for %1").arg(cv.io.craft); onClicked: cv.rewireRequested()
                    ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: qsTr("Drop the missing sensors and controls; the controller moves every control this craft has") }
            }
        }

        // ---- column headers
        Item {
            width: parent.width; height: hdrIn.implicitHeight
            Head { id: hdrIn; x: 0; width: cv.nodeW; text: qsTr("SENSORS  %1/%2").arg(cv.nIn).arg(cv.ins.length) }
            Head { x: cv.outX; width: cv.nodeW; horizontalAlignment: Text.AlignRight; text: qsTr("CONTROLS  %1/%2").arg(cv.nOut).arg(cv.outs.length) }
        }

        // ---- the canvas
        Rectangle {
            width: parent.width
            height: Math.min(cv.contentH, cv.maxViewHeight)
            radius: Theme.radius
            color: Theme.surfaceSunken
            border.color: Theme.separator
            clip: true

            Flickable {
                id: flick
                anchors.fill: parent
                contentWidth: width
                contentHeight: cv.contentH
                interactive: contentHeight > height + 1
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                ScrollBar.vertical: ScrollBar { policy: flick.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }

                // dotted grid
                Canvas {
                    width: flick.contentWidth; height: flick.contentHeight
                    property color dot: Theme.alpha(Theme.text, Theme.dark ? 0.10 : 0.12)
                    onDotChanged: requestPaint()
                    onHeightChanged: requestPaint()
                    onWidthChanged: requestPaint()
                    onPaint: {
                        const c = getContext("2d"); c.reset(); c.fillStyle = dot
                        for (let y = 8; y < height; y += 16) for (let x = 8; x < width; x += 16) c.fillRect(x, y, 1.2, 1.2)
                    }
                }

                // ---- wires (under the nodes)
                Item {
                    width: flick.contentWidth; height: flick.contentHeight
                    Repeater {
                        model: cv.ins
                        Wire { required property var modelData; required property int index
                            visible: modelData.used
                            x0: cv.nodeW; y0: cv.sensorPortY(index); x1: cv.ctrlX; y1: cv.ctrlY + cv.ctrlH / 2 }
                    }
                    Repeater {
                        model: cv.outs
                        Wire { required property var modelData; required property int index
                            visible: modelData.used
                            x0: cv.ctrlX + cv.ctrlW; y0: cv.ctrlY + cv.ctrlH / 2; x1: cv.outX; y1: cv.controlPortY(index) }
                    }
                    // the wire being dragged (drawn left to right either way)
                    Wire {
                        visible: cv.dragging !== null
                        readonly property bool fromSensor: !!cv.dragging && cv.dragging.which === "inputs"
                        x0: !cv.dragging ? 0 : fromSensor ? cv.dragging.x0 : cv.dragPos.x
                        y0: !cv.dragging ? 0 : fromSensor ? cv.dragging.y0 : cv.dragPos.y
                        x1: !cv.dragging ? 0 : fromSensor ? cv.dragPos.x : cv.dragging.x0
                        y1: !cv.dragging ? 0 : fromSensor ? cv.dragPos.y : cv.dragging.y0
                        dashed: true
                        color: cv.dragging && cv.overController(cv.dragPos) ? Theme.good : Theme.textMuted
                    }
                }

                // ---- sensors
                Repeater {
                    model: cv.ins
                    NodeCard {
                        id: sn
                        required property var modelData
                        required property int index
                        readonly property string label: Blocks.sensorLabel(modelData.name)
                        which: "inputs"; node: modelData
                        Accessible.name: qsTr("Sensor %1").arg(label)
                        x: 0; y: cv.sensorsY + index * (cv.sensorH + cv.rowGap)
                        width: cv.nodeW; height: cv.sensorH
                        tip: qsTr("%1 (%2), in %3.\nThe controller sees the reading divided by %4.\n%5")
                             .arg(label).arg(modelData.name).arg(modelData.unit || qsTr("no unit")).arg(modelData.scale).arg(cv.toggleText(modelData.used))
                        Label {
                            id: unitText
                            anchors.right: parent.right; anchors.rightMargin: 10; anchors.baseline: nameText.baseline
                            text: sn.modelData.unit || ""
                            font.pixelSize: Theme.micro; color: Theme.textFaint
                        }
                        Label {
                            id: nameText
                            x: 7; y: 4; width: unitText.x - x - 4
                            text: sn.label
                            font.pixelSize: Theme.caption; font.weight: sn.used ? Font.DemiBold : Font.Normal
                            color: sn.used ? Theme.text : Theme.textFaint; elide: Text.ElideRight
                        }
                        Label {
                            x: 7; anchors.verticalCenter: scaleField.verticalCenter; width: scaleField.x - 18
                            text: sn.label !== sn.modelData.name ? sn.modelData.name : ""
                            font.pixelSize: Theme.micro; font.family: Theme.mono; color: Theme.textFaint; elide: Text.ElideMiddle
                        }
                        Text { anchors.right: scaleField.left; anchors.rightMargin: 2; anchors.verticalCenter: scaleField.verticalCenter
                               text: "÷"; color: Theme.textFaint; font.pixelSize: Theme.micro }
                        PwNumberField {
                            id: scaleField
                            anchors.right: parent.right; anchors.rightMargin: 10; y: parent.height - height - 7
                            width: 40; height: 19; implicitHeight: 19
                            topPadding: 0; bottomPadding: 0; leftPadding: 3; rightPadding: 4; verticalAlignment: TextInput.AlignVCenter
                            font.pixelSize: Theme.micro
                            opacity: sn.used ? 1 : 0.6
                            value: sn.modelData.scale; decimals: 2; step: 0.5; minimum: 0.001
                            tip: qsTr("The reading is divided by this before the controller sees it (about its usual size)")
                            onCommitted: (v) => cv.scaleEdited(sn.modelData.name, v)
                        }
                        Port { which: "inputs"; node: sn.modelData; used: sn.used
                               x: parent.width - width / 2; anchors.verticalCenter: parent.verticalCenter }
                    }
                }
                // a craft without sensors of its own
                Rectangle {
                    visible: cv.ins.length === 0
                    x: 0; y: cv.sensorsY; width: cv.nodeW; height: Math.max(cv.sensorH, ns.implicitHeight + 8)
                    radius: Theme.radiusSmall; color: "transparent"; border.color: Theme.separator
                    Label { id: ns; x: 6; y: 4; width: parent.width - 12; wrapMode: Text.Wrap; font.pixelSize: Theme.micro; color: Theme.textMuted
                            text: qsTr("No sensors on this craft: standard flight sensors are added when the run starts.") }
                }

                // ---- controls
                Repeater {
                    model: cv.outs
                    NodeCard {
                        id: cn
                        required property var modelData
                        required property int index
                        which: "outputs"; node: modelData
                        Accessible.name: qsTr("Control %1").arg(modelData.name)
                        x: cv.outX; y: cv.controlsY + index * (cv.controlH + cv.rowGap)
                        width: cv.nodeW; height: cv.controlH
                        tip: qsTr("%1: %2, moves between %3 and %4.%5\n%6").arg(modelData.name).arg(cv.kindWords(modelData)).arg(modelData.lo).arg(modelData.hi)
                             .arg(modelData.where ? "\n" + modelData.where : "").arg(cv.toggleText(modelData.used))
                        Label {
                            x: 10; y: 4; width: parent.width - 16
                            text: cn.modelData.name
                            font.pixelSize: Theme.caption; font.weight: cn.used ? Font.DemiBold : Font.Normal
                            color: cn.used ? Theme.text : Theme.textFaint; elide: Text.ElideMiddle
                        }
                        Label {
                            x: 10; y: parent.height - height - 5; width: parent.width - 16
                            text: cn.modelData.where ? cv.whereShort(cn.modelData.where) : cv.kindWords(cn.modelData) + " · " + cv.rangeWords(cn.modelData)
                            font.pixelSize: Theme.micro; font.family: cn.modelData.where ? Theme.mono : Theme.baseFont.family
                            color: cn.modelData.where && cn.used ? Theme.textMuted : Theme.textFaint; elide: Text.ElideRight
                        }
                        Port { which: "outputs"; node: cn.modelData; used: cn.used
                               x: -width / 2; anchors.verticalCenter: parent.verticalCenter }
                    }
                }

                // ---- the controller
                Rectangle {
                    id: brain
                    x: cv.ctrlX; y: cv.ctrlY; width: cv.ctrlW; height: cv.ctrlH
                    readonly property bool target: cv.dragging !== null && cv.overController(cv.dragPos)
                    radius: Theme.radius
                    color: cv.broken ? Theme.alpha(Theme.bad, Theme.dark ? 0.22 : 0.10)
                         : Theme.alpha(cv.hot, target ? 0.34 : Theme.dark ? 0.24 : 0.14)
                    border.color: target ? Theme.good : cv.wireTint
                    border.width: target ? 2 : 1.5
                    Column {
                        anchors.centerIn: parent
                        width: parent.width - 8
                        spacing: 1
                        Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: cv.ctrlTitle; elide: Text.ElideRight
                                font.pixelSize: Theme.small; font.weight: Font.DemiBold; color: cv.broken ? Theme.bad : Theme.text }
                        Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: cv.ctrlSub; wrapMode: Text.Wrap
                                font.pixelSize: Theme.micro; color: Theme.textMuted }
                        Label { visible: text !== ""; width: parent.width; horizontalAlignment: Text.AlignHCenter; text: (cv.hidden || []).length > 1 ? cv.ctrlLayers : ""; elide: Text.ElideRight
                                font.pixelSize: Theme.micro; font.family: Theme.mono; color: Theme.textFaint }
                        Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: qsTr("%1 in → %2 out").arg(cv.nIn).arg(cv.nOut)
                                font.pixelSize: Theme.micro; color: cv.broken ? Theme.bad : Theme.textMuted }
                    }
                    // in / out ports
                    Rectangle { x: -5; anchors.verticalCenter: parent.verticalCenter; width: 10; height: 10; radius: 5
                                color: cv.nIn > 0 ? cv.wireTint : Theme.surfaceRaised; border.color: cv.wireTint; border.width: 1.5 }
                    Rectangle { x: parent.width - 5; anchors.verticalCenter: parent.verticalCenter; width: 10; height: 10; radius: 5
                                color: cv.nOut > 0 ? cv.wireTint : Theme.surfaceRaised; border.color: cv.wireTint; border.width: 1.5 }
                    HoverHandler { id: bh }
                    ToolTip.visible: bh.hovered && cv.dragging === null
                    ToolTip.delay: Theme.tooltipDelay
                    ToolTip.text: cv.mode === "mlp" ? qsTr("A neural network: %1 sensors in → hidden layers of %2 neurons → %3 controls out.\nChange its size in Controller details.")
                                                        .arg(cv.nIn).arg(cv.ctrlLayers).arg(cv.nOut)
                                : cv.mode === "neat" ? qsTr("NEAT grows its own network: it starts from the wired sensors and controls and adds neurons as it evolves.")
                                : cv.mode === "script" ? qsTr("Your script's control() flies the craft; the wiring says what it reads and moves.")
                                : qsTr("No controller: nothing reads the sensors.")
                }
            }
        }

        Label {
            width: parent.width; wrapMode: Text.Wrap; color: Theme.textMuted; font.pixelSize: Theme.caption
            text: qsTr("Click a sensor or control to wire it in or out, or drag its dot onto the controller.")
        }
    }
}
