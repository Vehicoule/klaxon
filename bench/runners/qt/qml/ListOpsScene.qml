import QtQuick

// Spec Family A (list_ops, docs/specs/bench-scenes.md): one shared row
// widget — 48dp height, label "Row NNNN — klaxon bench" left, small square
// (16x16) filled #7C4DFF right. A ListView + ListModel of plain rows in a
// scrollable column, 640x480 viewport (ListView virtualization stays ON —
// it is the framework's idiom). The harness calls runBenchOp() once between
// the 10 warmup frames and the 60 measured frames; extra.op_ms times the
// model mutation + one full render pass.
Item {
    id: root

    // One of: "create" | "replace" | "update10" | "swap" | "remove" | "clear"
    property string benchOp: "create"
    property int generation: 0

    // "Row NNNN — klaxon bench" — NNNN is the row index, zero-padded. The
    // generation offset keeps mutated/replaced labels distinguishable in
    // the pixel hash (gen 1 -> Row 1000…Row 1999).
    function rowLabel(i, gen) {
        return "Row " + ("0000" + (i + gen * 1000)).slice(-4) + " — klaxon bench"
    }

    function fill(gen) {
        rowModel.clear()
        for (let i = 0; i < 1000; ++i)
            rowModel.append({ "label": root.rowLabel(i, gen) })
    }

    // Called by the C++ harness as the timed op (QMetaObject::invokeMethod).
    function runBenchOp() {
        switch (benchOp) {
        case "create":   // render 1000 rows from empty
            generation += 1
            fill(generation)
            break
        case "replace":  // swap all 1000 row models -> full rebuild
            generation += 1
            fill(generation)
            break
        case "update10": // mutate every 10th row label (100 updates)
            generation += 1
            for (let i = 0; i < 1000; i += 10)
                rowModel.setProperty(i, "label", root.rowLabel(i, generation))
            break
        case "swap":     // swap row 5 <-> row 995 contents (not widgets)
            {
                const a = rowModel.get(5).label
                rowModel.setProperty(5, "label", rowModel.get(995).label)
                rowModel.setProperty(995, "label", a)
            }
            break
        case "remove":   // delete the middle row
            rowModel.remove(500)
            break
        case "clear":    // remove all rows -> render the empty state
            rowModel.clear()
            break
        }
    }

    Component.onCompleted: {
        // The non-create ops start from a populated list; building it is
        // scene construction (ttff), not part of the timed op.
        if (benchOp !== "create")
            root.fill(0)
    }

    ListView {
        id: list
        objectName: "benchList"
        anchors.fill: parent
        clip: true
        model: ListModel { id: rowModel }
        cacheBuffer: 0 // Klaxon's window is viewport-only (~10 live rows)
        delegate: Rectangle {
            width: list.width
            height: 48 // the shared row widget is 48dp
            color: "#2A2A3E"
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: label
                color: "#FFFFFF"
                font.pixelSize: 14
            }
            Rectangle {
                anchors.right: parent.right
                anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                width: 16
                height: 16
                color: "#7C4DFF"
            }
        }
    }
}
