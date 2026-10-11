import QtQuick

// Spec system (input_latency): inject a synthetic pointer event -> frames
// until the visual response paints (extra.latency_frames, extra.latency_ms).
// The harness presses the box center between two frames; the MouseArea
// flips the fill, and the harness counts frames until the grabbed pixels
// change.
Item {
    Rectangle {
        id: box
        objectName: "latencyBox" // the harness finds the probe point by name
        width: 200
        height: 200
        anchors.centerIn: parent
        color: "#2A2A3E"
        radius: 12
        Text {
            anchors.centerIn: parent
            text: "tap"
            color: "#FFFFFF"
            font.pixelSize: 18
        }
        MouseArea {
            anchors.fill: parent
            onPressed: box.color = "#03DAC6"
        }
    }
}
