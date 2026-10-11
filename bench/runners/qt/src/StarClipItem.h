#pragma once

#include <cmath>

#include <QPainter>
#include <QPainterPath>
#include <QQuickPaintedItem>

// The clip_path scene's node (docs/specs/bench-scenes.md: "120 nodes each
// clipped by a 6-point star path, contents scrolling under the clip"). One
// item paints a card fill plus scrolling stripes under a star-shaped
// QPainterPath clip — the exact Qt idiom for a path clip (Qt Quick has no
// declarative path clip; OpacityMask is a mask, not a clip, and forces an
// offscreen pass — see README.md). A C++ QQuickPaintedItem keeps the
// 120-node scene at paint cost, not 120 JS canvas callbacks (the same
// reason video_playback uses VideoItem).
class StarClipItem : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(int phase READ phase WRITE setPhase NOTIFY phaseChanged)

public:
    explicit StarClipItem(QQuickItem *parent = nullptr) : QQuickPaintedItem(parent) {
        setImplicitSize(56, 56);
    }

    int phase() const { return m_phase; }
    void setPhase(int p) {
        if (p == m_phase)
            return;
        m_phase = p;
        update();
        emit phaseChanged();
    }

    void paint(QPainter *painter) override {
        const qreal w = width(), h = height();
        // 6-point star path (6 outer + 6 inner vertices, inner radius 55%).
        QPainterPath star;
        const qreal cx = w / 2, cy = h / 2;
        const qreal rOut = qMin(w, h) / 2, rIn = rOut * 0.55;
        for (int i = 0; i < 12; ++i) {
            const qreal r = (i % 2 == 0) ? rOut : rIn;
            const qreal a = M_PI * i / 6.0 - M_PI / 2.0;
            const QPointF pt(cx + r * std::cos(a), cy + r * std::sin(a));
            if (i == 0)
                star.moveTo(pt);
            else
                star.lineTo(pt);
        }
        star.closeSubpath();
        painter->setClipPath(star);
        // Contents scrolling under the clip: a card fill + stripes that
        // slide 2px/frame (the phase is the frame counter * 2).
        painter->fillRect(QRectF(0, 0, w, h), QColor("#2A2A3E"));
        painter->setPen(Qt::NoPen);
        painter->setBrush(QColor("#7C4DFF"));
        const int stripe = 12;
        const int off = m_phase % (2 * stripe);
        for (qreal y = -2.0 * stripe + off; y < h + stripe; y += 2 * stripe)
            painter->drawRect(QRectF(0, y, w, stripe));
    }

signals:
    void phaseChanged();

private:
    int m_phase = 0;
};
