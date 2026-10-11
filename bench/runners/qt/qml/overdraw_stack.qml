import QtQuick

// Spec stress: 24 full-screen rects, each alpha=0x1F over the last,
// alternating #7C4DFF/#03DAC6 — forces saveLayer/compositing cost; static
// (the cost is in paint, not anim). The fill carries the alpha (the
// translucent-fill analog of Klaxon's saveLayer stack).
Item {
    Repeater {
        model: 24
        Rectangle {
            anchors.fill: parent
            color: index % 2 === 0 ? "#1F7C4DFF" : "#1F03DAC6"
        }
    }
}
