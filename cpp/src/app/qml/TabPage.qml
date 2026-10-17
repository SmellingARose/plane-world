import QtQuick
import QtQuick.Controls

// One tab: GPU viewport + collapsible inspector, split with a draggable divider.
SplitView {
    id: page
    property string tab
    property var sections: []
    property bool inspectorVisible: true
    property alias viewport: vp
    orientation: Qt.Horizontal

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
        }
    }
    Inspector {
        tab: page.tab
        sections: page.sections
        visible: page.inspectorVisible
        SplitView.preferredWidth: 300
        SplitView.minimumWidth: 220
        SplitView.maximumWidth: 520
    }
}
