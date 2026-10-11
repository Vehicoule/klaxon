import QtQuick

// Spec system (semantics_build): build/diff the a11y semantics tree of a
// 1000-node tree each frame — extra.nodes_per_frame. The tree is 50 rows x
// 20 text nodes (1000 semantics leaves); the tick calls
// bench.collectSemantics(), which walks the item tree building one
// semantics record per node and diffs against the previous frame's build
// (the closest Qt idiom — see README.md).
Item {
    clip: true
    Column {
        spacing: 1
        Repeater {
            model: 50
            Row {
                spacing: 4
                Repeater {
                    model: 20
                    Text {
                        text: "S" + index
                        color: "#CCCCCC"
                        font.pixelSize: 8
                    }
                }
            }
        }
    }

    Connections {
        target: bench
        function onTickFrame(frame) {
            bench.collectSemantics()
        }
    }
}
