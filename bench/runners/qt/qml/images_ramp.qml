import QtQuick

// Spec Family B (ramp): N copies of ONE 64x64 RGBA test image (checkerboard
// 8px, generated at startup by the C++ image provider — decoded once, the
// cache is shared across all delegates), each scaled 0.75x (64 -> 48) and
// moving on the same Lissajous path as shapes_ramp.
Item {
    id: root
    property int benchN: 10

    Repeater {
        id: rep
        model: root.benchN
        Image {
            source: "image://bench/checker64"
            width: 48   // 64 * 0.75
            height: 48
            smooth: true
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
                        return
                    items.push(it)
                    centers.push([60 + (i * 101) % 540, 40 + (i * 67) % 400])
                }
            }
            for (let i = 0; i < root.benchN; ++i) {
                const it = items[i]
                const c = centers[i]
                it.x = c[0] + 40 * Math.sin(0.10 * frame + i * 0.31)
                it.y = c[1] + 30 * Math.sin(0.1333 * frame + i * 0.17)
            }
        }
    }
}
