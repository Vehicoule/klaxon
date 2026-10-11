import QtQuick

// Spec stress: scroll_10k list scrolling at 600 dp/s WHILE 30 embedded row
// icons pulse opacity — mixed scroll+anim jank. 600 dp/s at the nominal
// 60Hz = 10px/frame. The 30 icons are embedded in row delegates; because
// the ListView virtualizes, the pulse band follows the scroll (the 30 rows
// starting at the viewport top) so the pulse stays live for the whole run.
Item {
    ListView {
        id: list
        objectName: "benchList"
        anchors.fill: parent
        clip: true
        model: 10000
        cacheBuffer: 0
        property real pulse: 1.0
        property int pulseBase: 0
        delegate: Rectangle {
            width: list.width
            height: 36
            color: "#2A2A3E"
            radius: 6
            Row {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                Text {
                    // the embedded row icon — pulses while in the band
                    text: "★"
                    color: "#FFD54F"
                    font.pixelSize: 14
                    opacity: (index >= list.pulseBase && index < list.pulseBase + 30)
                             ? list.pulse : 1.0
                }
                Text {
                    text: "Item #" + index
                    color: "#FFFFFF"
                    font.pixelSize: 14
                }
            }
        }
    }
    Connections {
        target: bench
        function onTickFrame(frame) {
            const maxOff = list.contentHeight - list.height
            list.contentY = (frame * 10) % (maxOff + 1) // 600 dp/s = 10px/frame
            list.pulseBase = Math.floor(list.contentY / 36)
            list.pulse = 0.5 + 0.5 * Math.sin(0.12 * frame)
        }
    }
}
