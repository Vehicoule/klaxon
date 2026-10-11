import QtQuick

// Spec Family B (ramp): N instances of "The quick brown fox 0123456789" at
// 14sp, horizontal offset oscillating (Qt has no sp headless — pixelSize 14
// is the runner's convention, matching the other scenes).
Item {
    id: root
    property int benchN: 10

    Repeater {
        id: rep
        model: root.benchN
        Text {
            text: "The quick brown fox 0123456789"
            color: "#FFFFFF"
            font.pixelSize: 14
        }
    }

    Connections {
        target: bench
        property var items: null
        property var baseX: null
        property var baseY: null
        function onTickFrame(frame) {
            if (!items || items.length !== root.benchN) {
                items = []
                baseX = []
                baseY = []
                for (let i = 0; i < root.benchN; ++i) {
                    const it = rep.itemAt(i)
                    if (!it)
                        return
                    items.push(it)
                    baseX.push(8 + (i * 97) % 520)
                    baseY.push(8 + (i * 53) % 456)
                }
            }
            // horizontal offset oscillating (amplitude 30)
            for (let i = 0; i < root.benchN; ++i) {
                items[i].x = baseX[i] + 30 * Math.sin(0.08 * frame + i * 0.23)
                items[i].y = baseY[i]
            }
        }
    }
}
