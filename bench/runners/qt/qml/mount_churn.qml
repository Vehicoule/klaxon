import QtQuick

// Spec stress: every frame destroy 50 widgets, create 50 new ones
// (label+icon card, random id), steady-state pool 500 — the GC/allocator
// pressure test. Card ids come from a deterministic LCG (reproducible
// runs); createObject+destroy() is the declarative mount churn.
Item {
    id: root

    Component {
        id: cardComp
        Rectangle {
            property int cardId: 0
            width: 56
            height: 44
            color: "#2A2A3E"
            radius: 6
            Rectangle { // the icon
                x: 6
                y: 6
                width: 12
                height: 12
                color: "#7C4DFF"
            }
            Text { // the label
                x: 6
                y: 24
                text: "C " + cardId
                color: "#FFFFFF"
                font.pixelSize: 12
            }
        }
    }

    property var pool: []   // the steady-state pool of 500 live cards
    property int nextId: 0

    function spawn() {
        const id = nextId++
        // deterministic scatter (id-driven LCG) over the viewport
        const x = (id * 137) % 584
        const y = (id * 211) % 436
        pool.push(cardComp.createObject(root, { "cardId": id, "x": x, "y": y }))
    }

    Component.onCompleted: {
        for (let i = 0; i < 500; ++i)
            spawn()
    }

    Connections {
        target: bench
        function onTickFrame(frame) {
            // destroy the 50 oldest, create 50 new — steady state 500
            for (let i = 0; i < 50; ++i) {
                const c = pool.shift()
                if (c) {
                    c.parent = null // unmount in this frame
                    c.destroy()     // deletion completes in the untimed drain
                }
            }
            for (let i = 0; i < 50; ++i)
                root.spawn()
        }
    }
}
