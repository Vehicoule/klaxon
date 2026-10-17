import QtQuick

// Spec Family B (ramp): N instances of "The quick brown fox 0123456789" at
// 14sp, horizontal offset oscillating (Qt has no sp headless — pixelSize 14
// is the runner's convention, matching the other scenes).
Item {
    id: root
    property int benchN: 10
    property int animFrame: 0

    Canvas {
        id: canvas
        anchors.fill: parent
        renderTarget: Canvas.Image
        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            ctx.fillStyle = "#FFFFFF"
            ctx.font = "14px sans-serif"
            const n = root.benchN
            const f = root.animFrame
            for (let i = 0; i < n; ++i) {
                const bx = 8 + (i * 97) % 520
                const by = 22 + (i * 53) % 456
                const x = bx + 30 * Math.sin(0.08 * f + i * 0.23)
                ctx.fillText("The quick brown fox 0123456789", x, by)
            }
        }
    }

    Connections {
        target: bench
        function onTickFrame(frame) {
            root.animFrame = frame
            canvas.requestPaint()
        }
    }
}
