import QtQuick

// Klaxon bench.zig buildTextCjk: column(padding 24, gap 10) of 5 texts —
// CJK shaping stress (Chinese / Japanese / Korean + emoji).
Item {
    Column {
        padding: 24
        spacing: 10
        width: parent.width

        Text {
            text: "text_cjk — CJK shaping (中文 / 日本語 / 한국어)"
            color: "#CCCCCC"
            font.pixelSize: 14
        }
        Text {
            text: "你好，世界！Klaxon 是一个用 Zig 编写的 UI 框架。"
            color: "#FFFFFF"
            font.pixelSize: 22
        }
        Text {
            text: "こんにちは、世界！Klaxon は Zig で書かれた UI フレームワークです。"
            color: "#FFFFFF"
            font.pixelSize: 22
        }
        Text {
            text: "안녕하세요, 세계! Klaxon은 Zig로 작성된 UI 프레임워크입니다."
            color: "#FFFFFF"
            font.pixelSize: 22
        }
        Text {
            text: "混ぜるな危険 — CJK + Latin + emoji 🌍🎉"
            color: "#FFD54F"
            font.pixelSize: 18
        }
    }
}
