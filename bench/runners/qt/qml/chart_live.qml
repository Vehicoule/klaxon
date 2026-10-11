import QtQuick

// Spec stress: line chart, 1000 points, polyline rebuilt fully every frame
// + axes/grid (10x8) — the real dashboard case. A Canvas repaints the grid
// and a freshly recomputed 1000-segment polyline every frame.
Item {
    Canvas {
        id: chart
        anchors.fill: parent
        property int phase: 0
        onPaint: {
            const ctx = getContext("2d")
            const W = width, H = height
            const L = 48, R = 12, T = 16, B = 32
            const pw = W - L - R, ph = H - T - B
            ctx.clearRect(0, 0, W, H)
            // grid 10x8
            ctx.strokeStyle = "#2A2A3E"
            ctx.lineWidth = 1
            ctx.beginPath()
            for (let v = 1; v <= 10; ++v) {
                const x = L + v * pw / 11
                ctx.moveTo(x, T)
                ctx.lineTo(x, T + ph)
            }
            for (let h = 1; h <= 8; ++h) {
                const y = T + h * ph / 9
                ctx.moveTo(L, y)
                ctx.lineTo(L + pw, y)
            }
            ctx.stroke()
            // axes
            ctx.strokeStyle = "#9A9AB0"
            ctx.beginPath()
            ctx.moveTo(L, T)
            ctx.lineTo(L, T + ph)
            ctx.lineTo(L + pw, T + ph)
            ctx.stroke()
            // polyline: 1000 points rebuilt fully every frame
            ctx.strokeStyle = "#03DAC6"
            ctx.lineWidth = 2
            ctx.beginPath()
            for (let i = 0; i < 1000; ++i) {
                const x = L + i * pw / 999
                const y = T + ph / 2
                    + ph * 0.32 * Math.sin(i * 0.045 + phase * 0.05)
                    + ph * 0.14 * Math.sin(i * 0.13 - phase * 0.021)
                if (i === 0)
                    ctx.moveTo(x, y)
                else
                    ctx.lineTo(x, y)
            }
            ctx.stroke()
        }
    }
    Connections {
        target: bench
        function onTickFrame(frame) {
            chart.phase = frame
            chart.requestPaint()
        }
    }
}
