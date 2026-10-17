pragma Singleton
import QtQuick

// Design system: one place for spacing, type, radii, motion and colour roles. Colours derive from the native
// system palette so light/dark mode and the accent colour follow the OS; custom surfaces use these roles only.
QtObject {
    readonly property SystemPalette sys: SystemPalette { colorGroup: SystemPalette.Active }
    readonly property bool dark: Qt.styleHints.colorScheme === Qt.ColorScheme.Dark

    // spacing scale (4 pt grid)
    readonly property int s1: 4
    readonly property int s2: 8
    readonly property int s3: 12
    readonly property int s4: 16
    readonly property int s5: 24
    readonly property int s6: 32

    // type scale relative to the system font
    readonly property font baseFont: Qt.application.font
    readonly property real body: baseFont.pixelSize > 0 ? baseFont.pixelSize : 13
    readonly property real caption: Math.round(body * 0.85)
    readonly property real title: Math.round(body * 1.25)
    readonly property real display: Math.round(body * 1.8)
    readonly property string mono: Qt.platform.os === "osx" ? "Menlo" : "Consolas"

    readonly property int radius: 8
    readonly property int radiusSmall: 5

    // motion
    readonly property int fast: 120
    readonly property int normal: 200
    readonly property int easing: Easing.OutCubic

    // colour roles
    readonly property color window: sys.window
    readonly property color text: sys.windowText
    readonly property color textMuted: Qt.rgba(text.r, text.g, text.b, 0.62)
    readonly property color textFaint: Qt.rgba(text.r, text.g, text.b, 0.40)
    readonly property color accent: sys.highlight
    readonly property color accentText: sys.highlightedText
    readonly property color surface: dark ? Qt.lighter(sys.window, 1.18) : Qt.darker(sys.window, 1.03)
    readonly property color surfaceRaised: dark ? Qt.lighter(sys.window, 1.35) : "#ffffff"
    readonly property color separator: Qt.rgba(text.r, text.g, text.b, dark ? 0.14 : 0.12)
    readonly property color overlay: Qt.rgba(0, 0, 0, dark ? 0.55 : 0.28)
    readonly property color hud: Qt.rgba(0.06, 0.07, 0.09, 0.62)
    readonly property color hudText: "#f2f4f7"

    // viewport
    readonly property color viewportClear: dark ? "#16181c" : "#2a2f37"
    readonly property color viewportSky: dark ? "#33507a" : "#5b87c4"

    // per-tab tint (subtle identity, used for the tab indicator and empty states)
    readonly property var tabTint: ({ "BUILD": "#e0913a", "FLY": "#3a8ee0", "WORLD": "#4caf6a", "EVOLVE": "#a368d8" })

    function shortcutText(seq) {   // "Ctrl+K" -> "⌘K" on macOS
        if (Qt.platform.os !== "osx") return seq
        return seq.replace("Ctrl+", "⌘").replace("Shift+", "⇧").replace("Alt+", "⌥")
    }
}
