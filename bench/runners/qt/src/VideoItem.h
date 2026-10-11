#pragma once

#include <QImage>
#include <QPainter>
#include <QQuickPaintedItem>

// The video_playback scene's widget (Klaxon bench.zig videoPaint): every
// paint regenerates the frame's pixels — a moving gradient plus a sliding
// bar, deterministic in the frame counter — and presents a FRESH texture
// (Klaxon: imageCreate copies the pixels, imageDraw, imageDestroy per frame).
// A C++ QQuickPaintedItem keeps the per-pixel loop at C++ speed, the same
// order of work as Klaxon's Zig loop (a JS Canvas loop would be ~10x slower
// and unfairly penalize Qt on this scene).
class VideoItem : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(int frame READ frame WRITE setFrame NOTIFY frameChanged)

public:
    explicit VideoItem(QQuickItem *parent = nullptr)
        : QQuickPaintedItem(parent), m_image(320, 180, QImage::Format_RGBA8888) {
        setImplicitSize(320, 180);
    }

    int frame() const { return m_frame; }
    void setFrame(int f) {
        if (f == m_frame)
            return;
        m_frame = f;
        update();
        emit frameChanged();
    }

    void paint(QPainter *painter) override {
        const int w = 320, h = 180;
        const int bar = int((quint64(m_frame) * 3) % quint64(w));
        for (int y = 0; y < h; ++y) {
            uchar *line = m_image.scanLine(y);
            for (int x = 0; x < w; ++x) {
                uchar *px = line + x * 4; // RGBA memory order, like Klaxon's buffer
                px[0] = uchar((x * 255) / (w - 1));
                px[1] = uchar((y * 255) / (h - 1));
                px[2] = 0x60;
                px[3] = 0xFF;
                if (x >= bar && x < bar + 24) {
                    px[0] = 0xFF;
                    px[1] = 0xFF;
                    px[2] = 0xFF;
                }
            }
        }
        painter->drawImage(QRectF(0, 0, width(), height()), m_image);
    }

signals:
    void frameChanged();

private:
    int m_frame = 0;
    QImage m_image;
};
