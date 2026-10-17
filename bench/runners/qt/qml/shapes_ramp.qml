import QtQuick

// Spec Family B (ramp): N rounded rects (r=8dp, 40x24, alternating
// #7C4DFF/#03DAC6), each translating 4px/frame on a Lissajous path. The
// harness drives benchN through the 9 steps (10..3200) and reads per-step
// p50 for extra.ramp[].
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
            const n = root.benchN
            const f = root.animFrame
            for (let i = 0; i < n; ++i) {
                const cx = 60 + (i * 101) % 520
                const cy = 40 + (i * 67) % 400
                const x = cx + 40 * Math.sin(0.10 * f + i * 0.31)
                const y = cy + 30 * Math.sin(0.1333 * f + i * 0.17)
                ctx.fillStyle = (i % 2 === 0) ? "#7C4DFF" : "#03DAC6"
                ctx.beginPath()
                ctx.roundedRect(x, y, 40, 24, 8, 8)
                ctx.fill()
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
