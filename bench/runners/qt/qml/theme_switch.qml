import QtQuick

// Spec stress: full gallery-like tree (200+ nodes), alternate light/dark
// theme every 30 frames — global invalidation cost. Every node's color is
// bound to the shared palette, so one toggle re-evaluates and repaints the
// whole tree.
Item {
    id: root

    QtObject {
        id: pal
        property bool dark: true
        readonly property color bg: dark ? "#14141C" : "#F2F2F7"
        readonly property color card: dark ? "#2A2A3E" : "#FFFFFF"
        readonly property color fg: dark ? "#FFFFFF" : "#1A1A2E"
        readonly property color sub: dark ? "#9A9AB0" : "#5A5A6E"
        readonly property color accent: dark ? "#7C4DFF" : "#6750A4"
    }

    Rectangle { // the themed surface
        anchors.fill: parent
        color: pal.bg
    }

    Column {
        x: 12
        y: 10
        spacing: 8
        Repeater {
            model: 16
            Rectangle { // a gallery section card (~13 children -> 200+ nodes)
                width: 616
                height: 26
                radius: 8
                color: pal.card
                Row {
                    x: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10
                    Rectangle {
                        width: 14
                        height: 14
                        radius: 7
                        color: pal.accent
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: "Section " + index
                        color: pal.fg
                        font.pixelSize: 13
                        font.bold: true
                    }
                    Text {
                        text: "subtitle " + index
                        color: pal.sub
                        font.pixelSize: 12
                    }
                    Repeater {
                        model: 9
                        Rectangle {
                            width: 22
                            height: 14
                            radius: 4
                            color: index % 3 === 0 ? pal.accent : pal.sub
                        }
                    }
                    Text {
                        text: "done"
                        color: pal.sub
                        font.pixelSize: 11
                    }
                }
            }
        }
    }

    Connections {
        target: bench
        function onTickFrame(frame) {
            if (frame > 0 && frame % 30 === 0)
                pal.dark = !pal.dark
        }
    }
}
