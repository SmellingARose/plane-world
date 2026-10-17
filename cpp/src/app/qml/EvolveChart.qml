import QtQuick
import QtQuick.Controls

// Line chart for per-generation series (Canvas; redraws only when data or size change). Hover shows a crosshair
// with every series' value; click emits picked(index) (EVOLVE replays that generation's best).
Item {
    id: chart
    property var xs: []                 // generation numbers
    property var series: []             // [{ name, values: [], color, width, dash }]
    property var band: null             // optional { lo: [], hi: [], color } shaded range (worst..best)
    property int selected: -1
    property string yLabel: ""
    signal picked(int index)
    implicitHeight: 150

    readonly property real padL: 44
    readonly property real padR: 8
    readonly property real padT: 8
    readonly property real padB: 18
    property int hover: -1

    function range() {
        let lo = Infinity, hi = -Infinity
        const take = (arr) => { for (const v of arr) if (isFinite(v) && v > -1e11) { lo = Math.min(lo, v); hi = Math.max(hi, v) } }
        for (const s of series) take(s.values || [])
        if (band) { take(band.lo || []); take(band.hi || []) }
        if (!isFinite(lo)) { lo = 0; hi = 1 }
        if (hi - lo < 1e-9) { hi += 0.5; lo -= 0.5 }
        const m = (hi - lo) * 0.06
        return [lo - m, hi + m]
    }
    function niceStep(span, n) {
        const raw = span / n, mag = Math.pow(10, Math.floor(Math.log10(raw))), f = raw / mag
        return (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * mag
    }
    function fmt(v) { const a = Math.abs(v); return a >= 1e4 || (a < 1e-2 && a > 0) ? v.toExponential(1) : v.toFixed(a >= 100 ? 0 : a >= 10 ? 1 : 2) }

    onXsChanged: canvas.requestPaint()
    onSeriesChanged: canvas.requestPaint()
    onSelectedChanged: canvas.requestPaint()
    onHoverChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()

    Canvas {
        id: canvas
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const w = width, h = height, n = chart.xs.length
            const pw = w - chart.padL - chart.padR, ph = h - chart.padT - chart.padB
            const r = chart.range()
            const X = (i) => chart.padL + (n <= 1 ? pw / 2 : pw * i / (n - 1))
            const Y = (v) => chart.padT + ph * (1 - (v - r[0]) / (r[1] - r[0]))
            // grid + labels
            ctx.font = Math.round(Theme.micro) + "px sans-serif"
            ctx.strokeStyle = Theme.separator; ctx.fillStyle = Theme.textFaint; ctx.lineWidth = 1
            const step = chart.niceStep(r[1] - r[0], 4)
            for (let v = Math.ceil(r[0] / step) * step; v <= r[1]; v += step) {
                const y = Math.round(Y(v)) + 0.5
                ctx.beginPath(); ctx.moveTo(chart.padL, y); ctx.lineTo(w - chart.padR, y); ctx.stroke()
                ctx.textAlign = "right"; ctx.fillText(chart.fmt(v), chart.padL - 4, y + 3)
            }
            if (n > 0) {
                ctx.textAlign = "left"; ctx.fillText(chart.xs[0], chart.padL, h - 4)
                ctx.textAlign = "right"; ctx.fillText(chart.xs[n - 1], w - chart.padR, h - 4)
            }
            if (n === 0) return
            if (chart.band && chart.band.lo && chart.band.hi) {
                ctx.fillStyle = chart.band.color
                ctx.beginPath()
                for (let i = 0; i < n; ++i) { const v = Math.max(r[0], chart.band.hi[i]); i ? ctx.lineTo(X(i), Y(v)) : ctx.moveTo(X(i), Y(v)) }
                for (let i = n - 1; i >= 0; --i) ctx.lineTo(X(i), Y(Math.max(r[0], chart.band.lo[i])))
                ctx.closePath(); ctx.fill()
            }
            for (const s of chart.series) {
                const vals = s.values || []
                ctx.strokeStyle = s.color; ctx.lineWidth = s.width || 1.5
                ctx.setLineDash(s.dash ? [4, 3] : [])
                ctx.beginPath()
                let started = false
                for (let i = 0; i < n && i < vals.length; ++i) {
                    if (!isFinite(vals[i]) || vals[i] < -1e11) { started = false; continue }
                    started ? ctx.lineTo(X(i), Y(vals[i])) : ctx.moveTo(X(i), Y(vals[i]))
                    started = true
                }
                ctx.stroke()
                if (n === 1 && vals.length) { ctx.fillStyle = s.color; ctx.beginPath(); ctx.arc(X(0), Y(vals[0]), 3, 0, Math.PI * 2); ctx.fill() }
            }
            ctx.setLineDash([])
            const mark = (i, col) => { ctx.strokeStyle = col; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(X(i) + 0.5, chart.padT); ctx.lineTo(X(i) + 0.5, h - chart.padB); ctx.stroke() }
            if (chart.selected >= 0 && chart.selected < n) mark(chart.selected, Theme.accent)
            if (chart.hover >= 0 && chart.hover < n) mark(chart.hover, Theme.textFaint)
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: chart.xs.length ? Qt.CrossCursor : Qt.ArrowCursor
        function indexAt(x) {
            const n = chart.xs.length; if (!n) return -1
            const pw = width - chart.padL - chart.padR
            return Math.max(0, Math.min(n - 1, Math.round((x - chart.padL) / pw * (n - 1))))
        }
        onPositionChanged: (m) => chart.hover = indexAt(m.x)
        onExited: chart.hover = -1
        onClicked: (m) => { const i = indexAt(m.x); if (i >= 0) chart.picked(i) }
    }

    // hover tooltip
    Rectangle {
        visible: chart.hover >= 0 && chart.hover < chart.xs.length
        x: Math.min(chart.width - width - 2, Math.max(chart.padL, chart.padL + (chart.width - chart.padL - chart.padR) * (chart.xs.length <= 1 ? 0.5 : chart.hover / (chart.xs.length - 1)) + 8))
        y: chart.padT
        radius: Theme.radiusSmall
        color: Theme.surfaceRaised; border.color: Theme.separator
        width: tipCol.implicitWidth + Theme.s2 * 2; height: tipCol.implicitHeight + Theme.s1 * 2
        Column {
            id: tipCol
            anchors.centerIn: parent
            Text { text: qsTr("gen %1").arg(chart.hover >= 0 ? chart.xs[chart.hover] : ""); color: Theme.textMuted; font.pixelSize: Theme.micro }
            Repeater {
                model: chart.series
                Text {
                    required property var modelData
                    text: "● " + modelData.name + "  " + (chart.hover >= 0 && modelData.values && isFinite(modelData.values[chart.hover]) ? chart.fmt(modelData.values[chart.hover]) : "–")
                    color: modelData.color; font.pixelSize: Theme.micro; font.family: Theme.mono
                }
            }
        }
    }
    Text {
        anchors.centerIn: parent
        visible: chart.xs.length === 0
        text: qsTr("No generations yet"); color: Theme.textFaint; font.pixelSize: Theme.caption
    }
}
