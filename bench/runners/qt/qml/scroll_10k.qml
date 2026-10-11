import QtQuick

// Klaxon bench.zig buildScrollList: column(padding 16, gap 12) [ title,
// constrainedBox(max 880x300) [ listView(10 000 items, item_height 36,
// row = card(#2A2A3E, radius 6, padding 8/6) [ star icon 14 #FFD54F,
// "Item #N" 14 white ]) ] ].
// QListView virtualizes: only the rows intersecting the viewport are alive
// (~10 live delegates), matching Klaxon's ~10 live nodes.
Item {
    Column {
        padding: 16
        spacing: 12
        width: parent.width

        Text {
            text: "scroll_10k — 10 000 items, virtualized (~10 live nodes)"
            color: "#CCCCCC"
            font.pixelSize: 14
        }
        ListView {
            id: list
            objectName: "benchList"
            width: parent.width - 32 // the column's padding
            height: 300 // constrainedBox max_h
            clip: true
            model: 10000
            cacheBuffer: 0 // Klaxon's window is viewport-only (~10 live rows)
            delegate: Rectangle {
                width: list.width
                height: 36 // item_height
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
            // bench.zig: off = (frame * 37) mod (maxScrollOffset + 1)
            const maxOff = list.contentHeight - list.height
            list.contentY = (frame * 37) % (maxOff + 1)
        }
    }
}
