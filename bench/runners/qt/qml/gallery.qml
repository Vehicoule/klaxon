import QtQuick

// Klaxon gallery.zig buildTree — a representative port of the gallery app:
// a header card (title + subtitle + theme toggle) over a scroll view whose
// content column holds the showcase sections (buttons, chips, text fields,
// cards, list items, pickers, the 10 000-item virtualized list, …), dark M3
// theme. Klaxon's gallery has 32 sections; this port covers the main widget
// categories with the same structure (header + scrollable section column +
// virtualized 10k list) — see README.md's non-parities.
Item {
    id: root

    // --- small M3 building blocks ---
    component FilledButton: Rectangle {
        property alias label: btnText.text
        implicitWidth: btnText.implicitWidth + 32
        implicitHeight: 36
        radius: 18
        color: "#D0BCFF" // primary
        Text {
            id: btnText
            anchors.centerIn: parent
            color: "#381E72" // on_primary
            font.pixelSize: 14
        }
    }
    component TonalButton: Rectangle {
        property alias label: btnText.text
        implicitWidth: btnText.implicitWidth + 32
        implicitHeight: 36
        radius: 18
        color: "#4A4458" // secondary_container
        Text {
            id: btnText
            anchors.centerIn: parent
            color: "#E8DEF8" // on_secondary_container
            font.pixelSize: 14
        }
    }
    component OutlinedButton: Rectangle {
        property alias label: btnText.text
        implicitWidth: btnText.implicitWidth + 32
        implicitHeight: 36
        radius: 18
        color: "transparent"
        border.color: "#49454F" // outline_variant
        border.width: 1
        Text {
            id: btnText
            anchors.centerIn: parent
            color: "#D0BCFF"
            font.pixelSize: 14
        }
    }
    component Chip: Rectangle {
        property alias label: chipText.text
        implicitWidth: chipText.implicitWidth + 24
        implicitHeight: 32
        radius: 16
        color: "#36343B" // surface_container_highest
        Text {
            id: chipText
            anchors.centerIn: parent
            color: "#E8DEF8"
            font.pixelSize: 13
        }
    }
    component Avatar: Rectangle {
        property alias label: avText.text
        width: 40
        height: 40
        radius: 20
        color: "#4A4458"
        Text {
            id: avText
            anchors.centerIn: parent
            color: "#E8DEF8"
            font.pixelSize: 16
        }
    }
    component IconButton: Rectangle {
        property alias glyph: ibText.text
        width: 40
        height: 40
        radius: 20
        color: "transparent"
        Text {
            id: ibText
            anchors.centerIn: parent
            color: "#CAC4D0"
            font.pixelSize: 18
        }
    }
    component M3Switch: Rectangle {
        property bool on: true
        width: 52
        height: 32
        radius: 16
        color: on ? "#D0BCFF" : "#36343B"
        Rectangle {
            x: on ? 24 : 4
            y: 4
            width: 24
            height: 24
            radius: 12
            color: on ? "#381E72" : "#CAC4D0"
        }
    }
    component FilledField: Item {
        property alias label: fLabel.text
        property alias value: fValue.text
        property alias placeholder: fPh.text
        implicitHeight: 56
        width: parent.width
        Rectangle {
            width: parent.width
            height: 56
            color: "#36343B"
            radius: 6
        }
        Text {
            id: fLabel
            x: 16
            y: 8
            color: "#D0BCFF"
            font.pixelSize: 12
        }
        Text {
            id: fValue
            x: 16
            y: 28
            color: "#E6E0E9"
            font.pixelSize: 16
        }
        Text {
            id: fPh
            x: 16
            y: 31
            visible: fValue.text.length === 0
            color: "#CAC4D0"
            font.pixelSize: 16
        }
    }
    component Card: Rectangle {
        property alias heading: cHead.text
        property alias bodyText: cBody.text
        implicitWidth: 160
        implicitHeight: cCol.implicitHeight + 24
        radius: 12
        color: "#211F26" // surface_container
        Column {
            id: cCol
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 4
            Text {
                id: cHead
                color: "#E6E0E9"
                font.pixelSize: 15
                font.bold: true
            }
            Text {
                id: cBody
                width: parent.width
                wrapMode: Text.WordWrap
                color: "#CAC4D0"
                font.pixelSize: 13
            }
        }
    }
    component ListRow: Rectangle {
        property alias title: lrTitle.text
        property alias subtitle: lrSub.text
        property alias badge: lrBadge.text
        implicitWidth: parent.width
        implicitHeight: 56
        radius: 8
        color: "#211F26"
        Row {
            x: 12
            y: 8
            width: parent.width - 24
            spacing: 12
            Avatar {
                label: "AB"
                anchors.verticalCenter: parent.verticalCenter
            }
            Column {
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    id: lrTitle
                    color: "#E6E0E9"
                    font.pixelSize: 14
                }
                Text {
                    id: lrSub
                    color: "#CAC4D0"
                    font.pixelSize: 12
                }
            }
            Text {
                id: lrBadge
                anchors.verticalCenter: parent.verticalCenter
                color: "#D0BCFF"
                font.pixelSize: 12
            }
        }
    }

    // --- header (Klaxon: container surface_container, radius 12, padding 12) ---
    Rectangle {
        id: header
        x: 16
        y: 16
        width: parent.width - 32
        height: headerRow.implicitHeight + 24
        color: "#211F26"
        radius: 12
        Row {
            id: headerRow
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 12
            Column {
                spacing: 2
                width: parent.width - 120
                Text {
                    text: "Klaxon Gallery"
                    color: "#E6E0E9"
                    font.pixelSize: 24
                    font.bold: true
                }
                Text {
                    text: "31 widgets · dark/light themes · gestures · animations · scroll 10k"
                    color: "#CAC4D0"
                    font.pixelSize: 12
                }
            }
            M3Switch {
                anchors.verticalCenter: parent.verticalCenter
            }
            M3Switch {
                on: false
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // --- scroll view (Klaxon: scrollView wrapping the content column) ---
    Flickable {
        id: flick
        x: 16
        y: header.y + header.height + 12
        width: parent.width - 32
        height: parent.height - y - 16
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        Column {
            id: content
            width: flick.width
            spacing: 16

            Section {
                title: "Input"
                Row {
                    spacing: 12
                    FilledButton {
                        label: "Press me"
                    }
                    Text {
                        text: "pressed 0 times"
                        color: "#CAC4D0"
                        font.pixelSize: 13
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
            Section {
                title: "Buttons (M3E)"
                Row {
                    spacing: 8
                    FilledButton {
                        label: "Filled"
                    }
                    TonalButton {
                        label: "Tonal"
                    }
                    OutlinedButton {
                        label: "Outlined"
                    }
                }
            }
            Section {
                title: "Icon buttons (M3E)"
                Row {
                    spacing: 8
                    IconButton {
                        glyph: "★"
                    }
                    IconButton {
                        glyph: "♥"
                    }
                    IconButton {
                        glyph: "✚"
                    }
                    IconButton {
                        glyph: "⌫"
                    }
                }
            }
            Section {
                title: "Selection controls (M3E)"
                Row {
                    spacing: 16
                    Rectangle {
                        width: 20
                        height: 20
                        radius: 4
                        color: "#D0BCFF"
                        Text {
                            anchors.centerIn: parent
                            text: "✓"
                            color: "#381E72"
                            font.pixelSize: 14
                        }
                    }
                    Rectangle {
                        width: 20
                        height: 20
                        radius: 4
                        color: "transparent"
                        border.color: "#CAC4D0"
                        border.width: 2
                    }
                    M3Switch {}
                }
            }
            Section {
                title: "Chips (M3E)"
                Row {
                    spacing: 8
                    Chip {
                        label: "Filter"
                    }
                    Chip {
                        label: "Suggestion"
                    }
                    Chip {
                        label: "Input"
                    }
                }
            }
            Section {
                title: "Text fields (M3E)"
                Column {
                    spacing: 12
                    FilledField {
                        label: "Email"
                        placeholder: "you@example.com"
                    }
                    FilledField {
                        label: "Password"
                        value: "••••••••"
                    }
                }
            }
            Section {
                title: "Cards (M3E)"
                Row {
                    spacing: 12
                    Card {
                        heading: "Card title"
                        bodyText: "A supporting card with a short body text."
                    }
                    Card {
                        heading: "Another card"
                        bodyText: "Cards group related content and actions."
                    }
                }
            }
            Section {
                title: "List items (M3E)"
                Column {
                    spacing: 8
                    ListRow {
                        title: "List item one"
                        subtitle: "A two-line list row"
                        badge: "1"
                    }
                    ListRow {
                        title: "List item two"
                        subtitle: "With a trailing badge"
                        badge: "2"
                    }
                }
            }
            Section {
                title: "Segmented buttons (M3E)"
                Rectangle {
                    width: 220
                    height: 40
                    radius: 20
                    color: "transparent"
                    border.color: "#49454F"
                    border.width: 1
                    Row {
                        x: 4
                        y: 4
                        spacing: 4
                        Rectangle {
                            width: 100
                            height: 32
                            radius: 16
                            color: "#4A4458"
                            Text {
                                anchors.centerIn: parent
                                text: "Day"
                                color: "#E8DEF8"
                                font.pixelSize: 13
                            }
                        }
                        Text {
                            width: 100
                            height: 32
                            text: "Week"
                            color: "#CAC4D0"
                            font.pixelSize: 13
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }
            Section {
                title: "Search bar (M3E)"
                Rectangle {
                    width: parent.width
                    height: 48
                    radius: 24
                    color: "#36343B"
                    Text {
                        x: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: "🔍  Search the gallery…"
                        color: "#CAC4D0"
                        font.pixelSize: 14
                    }
                }
            }
            Section {
                title: "Loading indicator (M3E)"
                Column {
                    spacing: 8
                    Text {
                        text: "Loading…"
                        color: "#CAC4D0"
                        font.pixelSize: 13
                    }
                    Rectangle {
                        width: parent.width
                        height: 4
                        radius: 2
                        color: "#36343B"
                        Rectangle {
                            width: parent.width * 0.6
                            height: 4
                            radius: 2
                            color: "#D0BCFF"
                        }
                    }
                }
            }
            Section {
                title: "Avatars (M3E)"
                Row {
                    spacing: 8
                    Avatar {
                        label: "AB"
                    }
                    Avatar {
                        label: "CD"
                    }
                    Avatar {
                        label: "EF"
                    }
                }
            }
            Section {
                title: "Color picker (M3E)"
                Row {
                    spacing: 8
                    Repeater {
                        model: ["#E91E63", "#3F51B5", "#00ACC1", "#FFD54F", "#80FF87"]
                        Rectangle {
                            width: 36
                            height: 36
                            radius: 18
                            color: modelData
                        }
                    }
                }
            }
            Section {
                title: "Calendar (M3E)"
                Column {
                    spacing: 4
                    Text {
                        text: "October 2026"
                        color: "#E6E0E9"
                        font.pixelSize: 14
                    }
                    Grid {
                        columns: 7
                        spacing: 4
                        Repeater {
                            model: 35
                            Rectangle {
                                width: 28
                                height: 28
                                radius: 14
                                color: index === 10 ? "#D0BCFF" : "transparent"
                                Text {
                                    anchors.centerIn: parent
                                    text: String(index + 1)
                                    color: index === 10 ? "#381E72" : "#CAC4D0"
                                    font.pixelSize: 11
                                }
                            }
                        }
                    }
                }
            }
            Section {
                title: "Table (M3E)"
                Column {
                    spacing: 2
                    Repeater {
                        model: 4
                        Row {
                            spacing: 2
                            Repeater {
                                model: 4
                                Rectangle {
                                    width: (root.width - 32 - 6) / 4
                                    height: 28
                                    color: "#211F26"
                                    border.color: "#49454F"
                                    border.width: 1
                                    Text {
                                        anchors.centerIn: parent
                                        text: "cell"
                                        color: "#CAC4D0"
                                        font.pixelSize: 11
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Section {
                title: "Typography & media"
                Column {
                    spacing: 4
                    Text {
                        text: "Headline"
                        color: "#E6E0E9"
                        font.pixelSize: 22
                        font.bold: true
                    }
                    Text {
                        text: "Title — a gallery section heading"
                        color: "#E6E0E9"
                        font.pixelSize: 16
                    }
                    Text {
                        text: "Body text for the gallery showcase, with CJK 你好 and emoji 🌍."
                        color: "#CAC4D0"
                        font.pixelSize: 14
                    }
                    Text {
                        text: "Caption"
                        color: "#CAC4D0"
                        font.pixelSize: 12
                    }
                }
            }
            Section {
                title: "Scroll"
                Column {
                    spacing: 8
                    Text {
                        text: "10 000 items below (virtualized)"
                        color: "#CAC4D0"
                        font.pixelSize: 13
                    }
                    ListView {
                        id: list10k
                        width: parent.width
                        height: 240
                        clip: true
                        model: 10000
                        cacheBuffer: 0
                        delegate: Rectangle {
                            width: list10k.width
                            height: 32
                            color: "#2A2A3E"
                            radius: 6
                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 8
                                Text {
                                    text: "★"
                                    color: "#FFD54F"
                                    font.pixelSize: 14
                                }
                                Text {
                                    text: "Item #" + index
                                    color: "#FFFFFF"
                                    font.pixelSize: 14
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
