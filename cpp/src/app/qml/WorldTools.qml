pragma Singleton
import QtQuick

// WORLD brush tools: one table drives the inspector grid, the floating tool palette and the number-key shortcuts.
QtObject {
    readonly property var terrainTools: [
        { id: "orbit",   icon: "✥", label: qsTr("Look"),    key: "1", tip: qsTr("Orbit and pan the camera (no editing)") },
        { id: "raise",   icon: "▲", label: qsTr("Raise"),   key: "2", tip: qsTr("Raise terrain under the brush") },
        { id: "lower",   icon: "▼", label: qsTr("Lower"),   key: "3", tip: qsTr("Lower terrain under the brush") },
        { id: "smooth",  icon: "≈", label: qsTr("Smooth"),  key: "4", tip: qsTr("Smooth bumps and ridges") },
        { id: "flatten", icon: "▬", label: qsTr("Flatten"), key: "5", tip: qsTr("Flatten to the height where the stroke started") },
        { id: "paint",   icon: "◐", label: qsTr("Paint"),   key: "6", tip: qsTr("Paint ground material (grass, rock, sand, snow)") },
        { id: "trees",   icon: "♣", label: qsTr("Trees"),   key: "7", tip: qsTr("Plant trees") },
        { id: "erase",   icon: "⌫", label: qsTr("Clear"),   key: "8", tip: qsTr("Remove trees") },
        { id: "grass",   icon: "⁂", label: qsTr("Grass"),   key: "9", tip: qsTr("Paint grass density") },
        { id: "prop",    icon: "■", label: qsTr("Prop"),    key: "P", tip: qsTr("Click to place the selected object") },
        { id: "lake",    icon: "◯", label: qsTr("Lake"),    key: "L", tip: qsTr("Click to add a lake that fills the basin") },
        { id: "spawn",   icon: "✈", label: qsTr("Spawn"),   key: "O", tip: qsTr("Click to move the craft spawn point") }
    ]
    function byKey(k) { for (const t of terrainTools) if (t.key === k) return t.id; return "" }
    function info(id) { for (const t of terrainTools) if (t.id === id) return t; return terrainTools[0] }
}
