import QtQuick

// Spec Family B (ramp): N identical 12-point closed bezier paths (~200 pts
// of tessellation), rotating 1 deg/frame. The path is a 12-anchor blob —
// alternating outer/inner radii around a circle, closed with cubic segments
// (~200 triangle points when the software raster engine triangulates it).
Item {
    id: root
    property int benchN: 10
    property int animFrame: 0

    // SVG path string, built once: 12 anchors (radius 22 outer / 11 inner,
    // center 24,24) joined by cubic segments whose control points sit at
    // 1.2x the anchor radius on the angular midpoint.
    property string blobPath: {
        const cx = 24, cy = 24
        const pts = []
        for (let i = 0; i < 12; ++i) {
            const r = (i % 2 === 0) ? 22 : 11
            const a = Math.PI * i / 6 - Math.PI / 2
            pts.push([cx + r * Math.cos(a), cy + r * Math.sin(a), r, a])
        }
        let d = "M " + pts[0][0].toFixed(2) + " " + pts[0][1].toFixed(2)
        for (let i = 0; i < 12; ++i) {
            const a0 = pts[i]
            const a1 = pts[(i + 1) % 12]
            const mid = a0[3] + Math.PI / 12
            const rc = a0[2] * 1.18
            const c1x = cx + rc * Math.cos(mid - Math.PI / 24)
            const c1y = cy + rc * Math.sin(mid - Math.PI / 24)
            const c2x = cx + rc * Math.cos(mid + Math.PI / 24)
            const c2y = cy + rc * Math.sin(mid + Math.PI / 24)
            d += " C " + c1x.toFixed(2) + " " + c1y.toFixed(2)
               + " " + c2x.toFixed(2) + " " + c2y.toFixed(2)
               + " " + a1[0].toFixed(2) + " " + a1[1].toFixed(2)
        }
        return d + " Z"
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        renderTarget: Canvas.Image
        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            const n = root.benchN
            const rotBase = root.animFrame % 360
            const p = root.blobPath
            for (let i = 0; i < n; ++i) {
                const ox = 8 + (i * 89) % 584
                const oy = 8 + (i * 61) % 424
                const rad = ((rotBase + i * 7) % 360) * Math.PI / 180
                ctx.save()
                ctx.translate(ox + 24, oy + 24)
                ctx.rotate(rad)
                ctx.translate(-24, -24)
                ctx.fillStyle = (i % 2 === 0) ? "#7C4DFF" : "#03DAC6"
                ctx.beginPath()
                ctx.path = p
                ctx.fill()
                ctx.restore()
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
