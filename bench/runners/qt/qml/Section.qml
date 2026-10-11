import QtQuick

// One titled gallery section (Klaxon gallery.zig's `section(...)` helper: a
// heading over a content column).
Item {
    id: section
    property alias title: heading.text
    default property alias content: body.data
    implicitHeight: heading.implicitHeight + 8 + body.implicitHeight
    width: parent.width

    Text {
        id: heading
        color: "#CAC4D0" // on_surface_variant
        font.pixelSize: 14
        font.bold: true
    }
    Column {
        id: body
        anchors.top: heading.bottom
        anchors.topMargin: 8
        width: parent.width
        spacing: 8
    }
}
