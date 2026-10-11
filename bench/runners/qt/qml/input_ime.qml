import QtQuick

// Klaxon bench.zig buildInputIme: column(padding 24, gap 12) [ title,
// textField(variant .filled, label "Message", placeholder "こんにちは…",
// supporting "type CJK / emoji — the buffer follows the caret", theme light)
// ]. The tick focuses the field with a click on frame 0, then commits IME
// text (CJK + emoji) every frame with a backspace every 12th frame.
Item {
    Column {
        padding: 24
        spacing: 12
        width: parent.width

        Text {
            text: "input_ime — text field, IME text_input commits (CJK + emoji)"
            color: "#CCCCCC"
            font.pixelSize: 14
        }
        // M3 filled text field, light theme
        Item {
            id: field
            width: parent.width - 48 // the column's padding
            height: 56 + 4 + supporting.implicitHeight

            Rectangle {
                id: fieldBg
                width: parent.width
                height: 56
                color: "#E7E0EC" // M3 light filled-container
                radius: 6
            }
            Text {
                x: 16
                y: 8
                text: "Message"
                color: "#6750A4" // M3 light primary label
                font.pixelSize: 12
            }
            TextInput {
                id: input
                objectName: "imeInput"
                x: 16
                y: 26
                width: parent.width - 32
                color: "#1D1B20"
                font.pixelSize: 16
            }
            Text {
                x: 16
                y: 29
                visible: input.text.length === 0
                text: "こんにちは…"
                color: "#79747E"
                font.pixelSize: 16
            }
            Text {
                id: supporting
                y: 60
                width: parent.width
                text: "type CJK / emoji — the buffer follows the caret"
                color: "#79747E"
                font.pixelSize: 12
            }
        }
    }
    Connections {
        target: bench
        // bench.zig IME_STRINGS
        property var imeStrings: ["こんにちは", "世界", "안녕하세요", "你好，世界", "🌍 ", "🎉 "]
        function onTickFrame(frame) {
            if (frame === 0) {
                // bench.zig: click the field center (pointer down+up) to focus
                const p = fieldBg.mapToItem(null, fieldBg.width / 2, fieldBg.height / 2)
                bench.clickAt(p.x, p.y)
            }
            if (frame % 12 === 11)
                bench.sendBackspace()
            else
                bench.sendText(imeStrings[frame % 6])
        }
    }
}
