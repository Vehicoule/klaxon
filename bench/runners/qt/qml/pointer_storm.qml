import QtQuick

// Spec system (pointer_storm): 1000 hit-test queries/frame over a 500-node
// tree (no paint change) — pure hit-test cost. The tree is 25 rows x 20
// leaf rects (500 hit-test targets); the tick issues 1000 deterministic
// LCG-distributed queries through bench.hitTest, the same topmost-first
// contains()+descend walk Qt's pointer dispatch performs.
Item {
    id: root

    Column {
        anchors.centerIn: parent
        spacing: 2
        Repeater {
            model: 25
            Row {
                spacing: 2
                Repeater {
                    model: 20
                    Rectangle {
                        width: 24
                        height: 14
                        radius: 2
                        color: "#2A2A3E"
                    }
                }
            }
        }
    }

    Connections {
        target: bench
        property int seed: 1
        function onTickFrame(frame) {
            // deterministic LCG -> query coordinates over the viewport
            let s = seed + frame * 7919
            for (let i = 0; i < 1000; ++i) {
                s = (Math.imul(s, 1103515245) + 12345) & 0x7FFFFFFF
                const x = s % 640
                s = (Math.imul(s, 1103515245) + 12345) & 0x7FFFFFFF
                const y = s % 480
                bench.hitTest(x, y)
            }
            seed = s
        }
    }
}
