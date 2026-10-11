import QtQuick

// Spec stress: 60 paragraphs x 3 lines, mixed: bold/italic spans, 3 font
// sizes (12/16/20sp), one LTR+RTL bidi line per paragraph
// ("مختصر Klaxon عربي test اختبار") — shaping stress. Rich text per
// paragraph; the scene is static per frame (the unpaced loop re-rasterizes
// the 180 shaped lines each frame).
Item {
    clip: true
    Column {
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
