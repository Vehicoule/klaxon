import QtQuick

// Spec Family B (ramp): N copies of ONE 64x64 RGBA test image (checkerboard
// 8px, generated at startup by the C++ image provider — decoded once, the
// cache is shared across all delegates), each scaled 0.75x (64 -> 48) and
// moving on the same Lissajous path as shapes_ramp.
Item {
    id: root
    property int benchN: 10
    property int animFrame: 0

    Image {
        id: checkerImg
        source: "image://bench/checker64"
        visible: false
    }

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
                const cx = 60 + (i * 101) % 540
                const cy = 40 + (i * 67) % 400
                const x = cx + 40 * Math.sin(0.10 * f + i * 0.31)
                const y = cy + 30 * Math.sin(0.1333 * f + i * 0.17)
                ctx.drawImage(checkerImg, x, y, 48, 48)
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
