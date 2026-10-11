import QtQuick

// Klaxon bench.zig buildGlassBlur: backdrop #101426 [ stack [ deco column
// (3 full-width panels #E91E63/#3F51B5/#00ACC1, height 150, radius 12,
// gap 12), 3 glass cards (300x110, radius 16) at center / top_right /
// bottom_left ] ].
//
// Klaxon's glass card is an alpha LAYER (ui.paint.layerAlpha 0.45 — the
// documented "blur stand-in": the kx_skia ABI has no blur primitive): a
// translucent rounded rect + 3 frosted bars, composited at 45%. Qt's
// layer.enabled + opacity 0.45 is the same saveLayer-at-alpha composite, so
// the scene does the same work as Klaxon's (no real backdrop blur on either
// side — see README.md).
Rectangle {
    id: backdrop
    color: "#101426"

    Column {
        id: deco
        width: parent.width
        spacing: 12
        Repeater {
            model: ["#E91E63", "#3F51B5", "#00ACC1"]
            Rectangle {
                width: deco.width
                height: 150
                color: modelData
                radius: 12
            }
        }
    }

    // glass card: tint + 3 frosted bars, composited at 45% (layerAlpha 0.45)
    Item {
        width: 300
        height: 110
        anchors.centerIn: parent
        layer.enabled: true
        opacity: 0.45
        Rectangle {
            anchors.fill: parent
            color: "#FFFFFF"
            radius: 16
        }
        Rectangle {
            x: 12
            y: 12
            width: parent.width - 24
            height: 6
            color: "#FFFFFF"
        }
        Rectangle {
            x: 12
            y: 24
            width: (parent.width - 24) * 0.62
            height: 6
            color: "#B3FFFFFF"
        }
        Rectangle {
            x: 12
            y: 36
            width: (parent.width - 24) * 0.4
            height: 6
            color: "#80FFFFFF"
        }
    }
    Item {
        width: 300
        height: 110
        anchors.top: parent.top
        anchors.right: parent.right
        layer.enabled: true
        opacity: 0.45
        Rectangle {
            anchors.fill: parent
            color: "#FFD54F"
            radius: 16
        }
        Rectangle {
            x: 12
            y: 12
            width: parent.width - 24
            height: 6
            color: "#FFFFFF"
        }
        Rectangle {
            x: 12
            y: 24
            width: (parent.width - 24) * 0.62
            height: 6
            color: "#B3FFFFFF"
        }
        Rectangle {
            x: 12
            y: 36
            width: (parent.width - 24) * 0.4
            height: 6
            color: "#80FFFFFF"
        }
    }
    Item {
        width: 300
        height: 110
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        layer.enabled: true
        opacity: 0.45
        Rectangle {
            anchors.fill: parent
            color: "#80FF87"
            radius: 16
        }
        Rectangle {
            x: 12
            y: 12
            width: parent.width - 24
            height: 6
            color: "#FFFFFF"
        }
        Rectangle {
            x: 12
            y: 24
            width: (parent.width - 24) * 0.62
            height: 6
            color: "#B3FFFFFF"
        }
        Rectangle {
            x: 12
            y: 36
            width: (parent.width - 24) * 0.4
            height: 6
            color: "#80FFFFFF"
        }
    }
}
