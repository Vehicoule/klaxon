import QtQuick

// Klaxon bench.zig buildResize: column(padding 16, gap 12) [ title, row
// (gap 12) of 3 cards (#2A2A3E, radius 8, padding 12, "Card" 13),
// constrainedBox(max 880x200) [ listView(2 000 items, item_height 32, same
// row delegate) ] ]. The tick cycles the viewport through RESIZE_SIZES —
// kx_resize (surface recreate) + a full relayout every frame.
Item {
    Column {
        padding: 16
        spacing: 12
        width: parent.width

        Text {
            text: "resize — the viewport cycles every frame (layout stress)"
            color: "#CCCCCC"
            font.pixelSize: 14
        }
        Row {
            spacing: 12
            Repeater {
                model: 3
                Rectangle {
                    color: "#2A2A3E"
                    radius: 8
                    width: label.implicitWidth + 24
                    height: label.implicitHeight + 24
                    Text {
                        id: label
                        anchors.centerIn: parent
                        text: "Card"
                        color: "#FFFFFF"
                        font.pixelSize: 13
                    }
                }
            }
        }
        ListView {
            id: list
            objectName: "benchList"
            width: parent.width - 32
            height: 200
            clip: true
            model: 2000
            cacheBuffer: 0
            delegate: Rectangle {
                width: list.width
                height: 32
                color: "#2A2A3E"
                radius: 6
                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8
                    Text {
                        text: "★"
                        color: "#FFD54F"
                        font.pixelSize: 14
                    }
                    Text {
                        text: "Item #" + index
                        color: "#FFFFFF"
                        font.pixelSize: 14
                    }
                }
            }
        }
    }
    Connections {
        target: bench
        function onTickFrame(frame) {
            // bench.zig RESIZE_SIZES — kx_resize + relayout every frame.
            // (The window resize event is delivered by the harness's untimed
            // event drain, so the rendered size lags the tick by one frame;
            // the relayout + backing-store realloc work is the same.)
            const sizes = [[640, 480], [480, 320], [320, 240], [800, 600], [240, 400], [960, 640]]
            const s = sizes[frame % 6]
            bench.setViewSize(s[0], s[1])
        }
    }
}
