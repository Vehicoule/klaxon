import QtQuick
import Qt5Compat.GraphicalEffects

// Spec stress: scrolling content (200 items) under a fixed 640x160
// backdrop-blur band (sigma=12) + 60% scrim — mobile's worst case.
// ShaderEffectSource(live) snapshots the scrolling list's pixels behind the
// band each frame and GaussianBlur blurs them — a real per-frame backdrop
// blur on the software backend.
Item {
    id: root

    ListView {
        id: list
        objectName: "benchList"
        anchors.fill: parent
        clip: true
        model: 200
        cacheBuffer: 0
        delegate: Rectangle {
            width: list.width
            height: 48
            color: "#2A2A3E"
            Row {
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10
                Rectangle {
                    width: 16
                    height: 16
                    color: "#7C4DFF"
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: "Backdrop item " + index
                    color: "#FFFFFF"
                    font.pixelSize: 14
                }
            }
        }
    }

    // The fixed blur band at y=160: blur what the list paints at the same
    // screen region (sourceRect is in the list's own coordinates — the
    // band's region), sampled live every frame.
    Item {
        x: 0
        y: 160
        width: 640
        height: 160
        clip: true
        ShaderEffectSource {
            id: snap
            anchors.fill: parent
            sourceItem: list
            sourceRect: Qt.rect(0, 160, 640, 160)
            live: true
            hideSource: false
        }
        GaussianBlur {
            anchors.fill: parent
            source: snap
            radius: 12   // sigma=12
            samples: 25  // >= 2*radius for the gaussian approximation
            deviation: 6
        }
        Rectangle { // 60% scrim
            anchors.fill: parent
            color: "#99000000"
        }
    }

    Connections {
        target: bench
        function onTickFrame(frame) {
            const maxOff = list.contentHeight - list.height
            list.contentY = (frame * 8) % (maxOff + 1) // steady scroll, 8px/frame
        }
    }
}
