import QtQuick

// Spec stress: 60 paragraphs x 3 lines, mixed: bold/italic spans, 3 font
// sizes (12/16/20sp), one LTR+RTL bidi line per paragraph
// ("مختصر Klaxon عربي test اختبار") — shaping stress. Rich text per
// paragraph. The column scrolls continuously so every one of the 60
// paragraphs is painted over the run — a fixed clip would leave ~47 of
// them outside the viewport forever (Qt's renderer culls offscreen items,
// unlike Klaxon which repaints the whole tree each frame).
Item {
    Flickable {
        id: flick
        anchors.fill: parent
        clip: true
        interactive: false // harness-driven, like every scene's tick scroll
        contentWidth: col.width
        contentHeight: col.height

        Column {
            id: col
            x: 16
            width: 608
            spacing: 4
            Repeater {
                model: 60
                Text {
                    width: 608
                    textFormat: Text.RichText
                    color: "#FFFFFF"
                    font.pixelSize: 14
                    text: "<b>Bold lead " + index + "</b> <i>italic span</i> "
                        + "<span style='font-size:20px'>large 20</span> "
                        + "<span style='font-size:12px'>small 12</span><br/>"
                        + "مختصر Klaxon عربي test اختبار<br/>"
                        + "<span style='font-size:16px'>Mid 16</span> plain tail " + index
                }
            }
        }
    }

    Connections {
        target: bench
        function onTickFrame(frame) {
            // steady scroll through the full column (wraps at the end)
            const maxOff = flick.contentHeight - flick.height
            flick.contentY = (frame * 15) % (maxOff + 1)
        }
    }
}
