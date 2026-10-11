import QtQuick

// Spec system (app_switch): pause->resume cycle every 60 frames: teardown
// cost extra.teardown_ms, resume-to-frame extra.resume_ms. The harness
// unloads (setSource(QUrl())) and reloads this scene at frames 60 and 120;
// the tree is a representative ~170-node app surface (12 cards x ~13 nodes)
// so both directions do real work.
Item {
    Column {
        padding: 16
        spacing: 8
        width: parent.width
        Text {
            text: "app_switch — pause/resume every 60 frames"
            color: "#CCCCCC"
            font.pixelSize: 14
        }
        Repeater {
            model: 12
            Rectangle {
                width: 608
                height: 32
                radius: 8
                color: "#2A2A3E"
                Row {
                    x: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10
                    Rectangle {
                        width: 16
                        height: 16
                        radius: 8
                        color: "#7C4DFF"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: "Card " + index
                        color: "#FFFFFF"
                        font.pixelSize: 13
                        font.bold: true
                    }
                    Text {
                        text: "supporting text " + index
                        color: "#9A9AB0"
                        font.pixelSize: 12
                    }
                    Repeater {
                        model: 8
                        Rectangle {
                            width: 18
                            height: 12
                            radius: 3
                            color: index % 2 === 0 ? "#03DAC6" : "#4A4A5E"
                        }
                    }
                    Text {
                        text: ">"
                        color: "#9A9AB0"
                        font.pixelSize: 12
                    }
                }
            }
        }
    }
}
