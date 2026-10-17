import QtQuick
import QtQuick.Controls

// One tab: GPU viewport (+ per-tab overlays) and the collapsible inspector, split with a draggable divider.
SplitView {
    id: page
    property string tab
    property var sections: []
    property bool inspectorVisible: true
    property alias viewport: vp
    property alias inspector: insp
    orientation: Qt.Horizontal

    // The App model follows the visible tab: BUILD edits, FLY simulates, other tabs leave the craft at rest.
    onTabChanged: App.mode = tab === "FLY" ? "fly" : tab === "BUILD" ? "build" : "other"
    Component.onCompleted: App.mode = tab === "FLY" ? "fly" : tab === "BUILD" ? "build" : "other"

    Item {
        SplitView.fillWidth: true
        SplitView.minimumWidth: 320
        GpuViewport {
            id: vp
            anchors.fill: parent
            visible: page.visible
            focus: true
        }
        ViewportHud {
            anchors.fill: parent
            backend: vp.backendName; adapter: vp.adapterName; fps: vp.fps; gpuMs: vp.gpuMs; passes: vp.passTimings
            asyncCompute: vp.asyncCompute; showStats: vp.showStats; timeOfDay: vp.timeOfDay; craft: vp.craftName
            error: vp.error; tab: page.tab
            interacting: vp.interacting
            compact: page.tab === "FLY"
        }
        BuildHud { anchors.fill: parent; viewport: vp; visible: page.tab === "BUILD" }
        FlyHud { anchors.fill: parent; visible: page.tab === "FLY" }
    }
    Inspector {
        id: insp
        tab: page.tab
        sections: page.sections
        visible: page.inspectorVisible
        SplitView.preferredWidth: Theme.inspectorWidth
        SplitView.minimumWidth: 260
        SplitView.maximumWidth: 560
    }
}
