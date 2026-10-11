import QtQuick
import QtQuick.Shapes

// Spec Family B (ramp): N identical 12-point closed bezier paths (~200 pts
// of tessellation), rotating 1 deg/frame. The path is a 12-anchor blob —
// alternating outer/inner radii around a circle, closed with cubic segments
// (~200 triangle points when the software raster engine triangulates it).
Item {
    id: root
    property int benchN: 10

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

    Repeater {
        id: rep
        model: root.benchN
        Shape {
            width: 48
            height: 48
            ShapePath {
                fillColor: index % 2 === 0 ? "#7C4DFF" : "#03DAC6"
                strokeColor: "transparent"
                PathSvg { path: root.blobPath }
            }
        }
    }

    Connections {
        target: bench
        property var items: null
        function onTickFrame(frame) {
            if (!items || items.length !== root.benchN) {
                items = []
                for (let i = 0; i < root.benchN; ++i) {
                    const it = rep.itemAt(i)
                    if (!it)
                        return
                    items.push(it)
                    // deterministic scatter (the item's rotation center)
                    it.x = 8 + (i * 89) % 584
                    it.y = 8 + (i * 61) % 424
                }
            }
            // 1 deg/frame rotation, a fixed phase offset per instance.
            const rot = frame % 360
            for (let i = 0; i < root.benchN; ++i)
                items[i].rotation = (rot + i * 7) % 360
        }
    }
}
