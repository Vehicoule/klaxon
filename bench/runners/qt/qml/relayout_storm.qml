import QtQuick
import QtQuick.Layouts

// Spec stress: 200 rows each animating width 200<->440 dp (2s loop) —
// forces per-frame measure+layout of the subtree (NOT a compositable
// transform). A ColumnLayout re-solves all 200 preferred widths every
// frame — the layout-engine analog of Klaxon's relayout. The spec sets no
// row phase, so all rows share the same 120-frame sine (2s at 60Hz).
Item {
    id: root

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        Repeater {
            id: rep
            model: 200
            Rectangle {
                // preferredHeight 20 x 200 rows in 480px: the layout engine
                // distributes and the width change forces a full re-solve.
                Layout.preferredWidth: 320
                Layout.preferredHeight: 20
                Layout.maximumHeight: 20
                color: index % 2 === 0 ? "#7C4DFF" : "#03DAC6"
            }
        }
    }

    Connections {
        target: bench
        property var rows: null
        function onTickFrame(frame) {
            if (!rows || rows.length !== 200) {
                rows = []
                for (let i = 0; i < 200; ++i) {
                    const it = rep.itemAt(i)
                    if (!it)
                        return
                    rows.push(it)
                }
            }
            // 200 <-> 440, 2s loop (120 frames at 60Hz)
            const w = 320 + 120 * Math.sin(Math.PI * frame / 60)
            for (let i = 0; i < 200; ++i)
                rows[i].Layout.preferredWidth = w
        }
    }
}
