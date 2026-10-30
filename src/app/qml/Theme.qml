pragma Singleton
import QtQuick

// Plane World design system (shared by every tab: BUILD / FLY by P5a, WORLD / EVOLVE by P5b).
//
// Rules
//  * Native first: standard Qt Quick Controls (macOS / Windows native styles) for every input. The Pw* components
//    in this module only arrange native controls and add the few things the platforms lack (keycaps, stat rows,
//    sections, toasts). Never restyle a native control's chrome.
//  * Colours come from roles below, never literals in views. Roles derive from the system palette so light / dark
//    mode and the user's accent colour follow the OS live.
//  * Spacing is a 4 px grid (s1..s6). Type is a scale relative to the system font (caption / body / title / display).
//  * Motion: `fast` for hover / press feedback, `normal` for layout and panels, always `easing` (OutCubic).
//    Respect reduced motion via `motion` (0 disables animation durations).
//  * Every action is reachable from the keyboard and the command palette; tooltips show the shortcut
//    (use Theme.tip("Frame craft", "F")).
QtObject {
    id: theme
    readonly property SystemPalette sys: SystemPalette { colorGroup: SystemPalette.Active }
    readonly property SystemPalette sysDisabled: SystemPalette { colorGroup: SystemPalette.Disabled }
    /// Follows the OS live (native controls do too, so we never force a scheme).
    readonly property bool dark: Qt.styleHints.colorScheme === Qt.ColorScheme.Dark
    readonly property bool mac: Qt.platform.os === "osx"

    // ---- spacing (4 px grid)
    readonly property int s0: 2
    readonly property int s1: 4
    readonly property int s2: 8
    readonly property int s3: 12
    readonly property int s4: 16
    readonly property int s5: 24
    readonly property int s6: 32
    readonly property int rowHeight: 26          // compact inspector row
    readonly property int inspectorWidth: 320
    readonly property int labelColumn: 104       // label width in inspector rows

    // ---- type scale relative to the system font
    readonly property font baseFont: Qt.application.font
    readonly property real body: baseFont.pixelSize > 0 ? baseFont.pixelSize : 13
    readonly property real small: Math.round(body * 0.92)
    readonly property real caption: Math.round(body * 0.85)
    readonly property real micro: Math.max(9, Math.round(body * 0.77))
    readonly property real title: Math.round(body * 1.25)
    readonly property real display: Math.round(body * 1.8)
    readonly property string mono: mac ? "Menlo" : "Consolas"
    readonly property string serif: mac ? "Times New Roman" : "Cambria Math"
    readonly property real sectionTracking: 0.9

    // ---- shape
    readonly property int radius: 8
    readonly property int radiusSmall: 5
    readonly property int radiusLarge: 12
    readonly property int hairline: 1

    // ---- motion
    property real motion: 1                      // 0 = reduced motion
    readonly property int fast: 120 * motion
    readonly property int normal: 200 * motion
    readonly property int slow: 320 * motion
    readonly property int easing: Easing.OutCubic
    readonly property int tooltipDelay: 550

    // ---- colour roles
    readonly property color window: sys.window
    readonly property color text: sys.windowText
    readonly property color textMuted: Qt.rgba(text.r, text.g, text.b, 0.64)
    readonly property color textFaint: Qt.rgba(text.r, text.g, text.b, 0.42)
    // macOS: SystemPalette.highlight is the pale *selection* colour, so text/fills tinted with it wash out in light
    // mode; the user's accent colour (QPalette::Accent, Qt 6.6+) is the right brand tint on both platforms.
    readonly property color accent: sys.accent !== undefined ? sys.accent : sys.highlight
    readonly property color accentText: sys.highlightedText
    readonly property color link: dark ? "#58a6ff" : accent   // text links: the system accent is too dark on dark panels
    readonly property color accentSoft: Qt.rgba(accent.r, accent.g, accent.b, dark ? 0.24 : 0.14)
    readonly property color surface: dark ? Qt.lighter(window, 1.18) : Qt.darker(window, 1.03)
    readonly property color surfaceRaised: dark ? Qt.lighter(window, 1.38) : "#ffffff"
    readonly property color surfaceSunken: dark ? Qt.darker(window, 1.25) : Qt.darker(window, 1.07)
    readonly property color card: dark ? Qt.rgba(1, 1, 1, 0.045) : Qt.rgba(1, 1, 1, 0.62)
    readonly property color hover: Qt.rgba(text.r, text.g, text.b, dark ? 0.08 : 0.06)
    readonly property color separator: Qt.rgba(text.r, text.g, text.b, dark ? 0.14 : 0.12)
    readonly property color overlay: Qt.rgba(0, 0, 0, dark ? 0.55 : 0.28)
    readonly property color shadow: Qt.rgba(0, 0, 0, dark ? 0.5 : 0.18)
    readonly property color hud: Qt.rgba(0.06, 0.07, 0.09, 0.66)
    readonly property color hudStrong: Qt.rgba(0.05, 0.06, 0.08, 0.82)
    readonly property color hudText: "#f2f4f7"
    readonly property color hudMuted: Qt.rgba(0.95, 0.96, 0.97, 0.66)
    readonly property color hudFaint: Qt.rgba(0.95, 0.96, 0.97, 0.38)

    // semantic
    readonly property color good: dark ? "#3fb950" : "#1a7f37"
    readonly property color warn: dark ? "#d29922" : "#9a6700"
    readonly property color bad: dark ? "#f85149" : "#cf222e"
    readonly property color info: dark ? "#58a6ff" : "#0969da"
    // axis colours (gizmos, vectors): +X forward red, +Y up green, +Z right blue
    readonly property color axisX: "#e5534b"
    readonly property color axisY: "#57ab5a"
    readonly property color axisZ: "#539bf5"

    // viewport
    readonly property color viewportClear: dark ? "#16181c" : "#2a2f37"
    readonly property color viewportSky: dark ? "#33507a" : "#5b87c4"

    // per-tab tint (subtle identity: tab indicator, empty states, inspector header)
    readonly property var tabTint: ({ "BUILD": "#e0913a", "FLY": "#3a8ee0", "WORLD": "#4caf6a", "EVOLVE": "#a368d8" })
    // part type tint (BUILD parts list chips)
    readonly property var partTint: ({ "box": "#8b949e", "cylinder": "#8b949e", "cone": "#8b949e", "sphere": "#8b949e",
        "wing": "#539bf5", "servo": "#e0913a", "wheel": "#6e7681", "motor": "#c69026", "prop": "#d4a72c",
        "jet": "#e5534b", "tank": "#57ab5a", "solid": "#f47067", "cad": "#a371f7", "sensor": "#39c5bb" })

    // ---- helpers
    /// "Ctrl+K" -> "⌘K" on macOS (Qt maps Ctrl to Command there); Windows keeps the text form.
    function shortcutText(seq) {
        if (!seq) return ""
        if (!mac) return seq
        return seq.replace(/Ctrl\+/g, "⌘").replace(/Meta\+/g, "⌃").replace(/Shift\+/g, "⇧").replace(/Alt\+/g, "⌥")
                  .replace("Backspace", "⌫").replace("Delete", "⌦").replace("Return", "↩").replace("Escape", "Esc")
    }
    /// Tooltip text with the shortcut appended: tip("Undo", "Ctrl+Z") -> "Undo  ⌘Z".
    function tip(text, seq) { return seq ? text + "    " + shortcutText(seq) : text }
    /// Engineering number formatting used in every panel (Swift fmtNum).
    function num(v) {
        if (v === undefined || v === null || !isFinite(v)) return "–"
        const a = Math.abs(v)
        if (a === 0) return "0"
        if (a >= 1e4 || a < 1e-3) return v.toExponential(2)
        if (a >= 100) return v.toFixed(1)
        return v.toFixed(3)
    }
    function fixed(v, d) { return (v === undefined || !isFinite(v)) ? "–" : v.toFixed(d) }
    function signed(v, d) { return (v === undefined || !isFinite(v)) ? "–" : (v >= 0 ? "+" : "") + v.toFixed(d) }
    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
}
