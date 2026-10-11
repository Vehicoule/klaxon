import QtQuick
import klaxonbench 1.0

// Spec stress: 120 nodes each clipped by a 6-point star path, contents
// scrolling under the clip. StarClipItem (C++ QQuickPaintedItem) paints
// stripes sliding 2px/frame under a star-shaped QPainterPath clip — the
// exact path-clip idiom (see README.md for the OpacityMask gap).
Item {
    id: root
    clip: true
    property int phase: 0

    Grid {
        columns: 11
        spacing: 4
        x: 12
        y: 12
        Repeater {
            model: 120
            StarClipItem {
                width: 56
                height: 56
                phase: root.phase
            }
        }
    }

    Connections {
        target: bench
        function onTickFrame(frame) {
            root.phase = frame * 2 // contents scroll 2px/frame under the clip
        }
    }
}
