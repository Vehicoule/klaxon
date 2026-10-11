import QtQuick
import Qt5Compat.GraphicalEffects

// Spec stress: 10x10 grid of 48x40 cards, M3 elevation shadow (r=12, dy=2,
// blur=6, rgba(0,0,0,0.30)) — every shadow re-rasterized per frame while
// card fill color oscillates +/-4% lightness. RectangularGlow is Qt's
// closest idiom for the elevation shadow (a blurred rounded-rect glow
// behind the card).
Item {
    id: root

    Grid {
        id: grid
        anchors.centerIn: parent
        columns: 10
        spacing: 7 // 10*48 + 9*7 = 543 wide, 10*40 + 9*7 = 463 tall
        Repeater {
            id: rep
            model: 100
            Item {
                // exposed for the tick's color oscillation
                property alias card: cardRect
                width: 48
                height: 40
                RectangularGlow {
                    y: 2 // dy=2
                    width: 48
                    height: 40
                    glowRadius: 6  // blur=6
                    spread: 0.0
                    cornerRadius: 12 // r=12
                    color: "#4D000000" // rgba(0,0,0,0.30)
                }
                Rectangle {
                    id: cardRect
                    anchors.fill: parent
                    radius: 12
                    color: "#8E8AA8"
                }
            }
        }
    }

    Connections {
        target: bench
        property var cards: null
        function onTickFrame(frame) {
            if (!cards || cards.length !== 100) {
                cards = []
                for (let i = 0; i < 100; ++i) {
                    const it = rep.itemAt(i)
                    if (!it)
                        return
                    cards.push(it.card)
                }
            }
            // Card fill oscillates +-4% lightness (hsl 0.66, 0.18, ~0.55);
            // the fill change forces each shadow's region to re-rasterize.
            for (let i = 0; i < 100; ++i) {
                const l = 0.55 + 0.04 * Math.sin(0.07 * frame + i * 0.31)
                cards[i].color = Qt.hsla(0.66, 0.18, l, 1.0)
            }
        }
    }
}
