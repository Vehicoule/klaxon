import QtQuick

// Spec Family B (ramp): N rounded rects (r=8dp, 40x24, alternating
// #7C4DFF/#03DAC6), each translating 4px/frame on a Lissajous path. The
// harness drives benchN through the 9 steps (10..3200) and reads per-step
// p50 for extra.ramp[].
Item {
    id: root
    property int benchN: 10

    Repeater {
        id: rep
        model: root.benchN
        Rectangle {
            width: 40
            height: 24
            radius: 8
            color: index % 2 === 0 ? "#7C4DFF" : "#03DAC6"
        }
    }

    Connections {
        target: bench
        property var items: null
        property var centers: null
        function onTickFrame(frame) {
            if (!items || items.length !== root.benchN) {
                items = []
                centers = []
                for (let i = 0; i < root.benchN; ++i) {
                    const it = rep.itemAt(i)
                    if (!it)
                        return // delegates still instantiating; next frame fills in
                    items.push(it)
                    // deterministic scatter of the Lissajous centers
                    centers.push([60 + (i * 101) % 520, 40 + (i * 67) % 400])
                }
            }
            // Lissajous path, max 4px/frame per axis (amplitude * omega = 4):
            // dx <= 40*0.1 = 4, dy <= 30*0.1333 = 4.
            for (let i = 0; i < root.benchN; ++i) {
                const it = items[i]
                const c = centers[i]
                it.x = c[0] + 40 * Math.sin(0.10 * frame + i * 0.31)
                it.y = c[1] + 30 * Math.sin(0.1333 * frame + i * 0.17)
            }
        }
    }
}
