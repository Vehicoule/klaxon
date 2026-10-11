#pragma once

#include <QImage>
#include <QQuickImageProvider>

// The images_ramp scene's test image: ONE 64x64 RGBA checkerboard (8px
// cells), generated once — the spec's "decoded once per runner" (startup
// cost excluded). Served as image://bench/checker64; the Image items share
// the engine's response cache (cache: true), so every delegate samples the
// same decoded image and the scene measures sampling/draw, not decode.
class BenchImageProvider : public QQuickImageProvider {
public:
    BenchImageProvider() : QQuickImageProvider(QQuickImageProvider::Image) {}

    QImage requestImage(const QString &id, QSize *size,
                        const QSize &requestedSize) override {
        Q_UNUSED(id);
        Q_UNUSED(requestedSize);
        static const QImage checker = makeChecker();
        if (size)
            *size = checker.size();
        return checker;
    }

private:
    static QImage makeChecker() {
        QImage img(64, 64, QImage::Format_RGBA8888);
        for (int y = 0; y < 64; ++y) {
            uchar *line = img.scanLine(y);
            for (int x = 0; x < 64; ++x) {
                const bool a = ((x / 8) + (y / 8)) % 2 == 0;
                uchar *px = line + x * 4; // RGBA order
                px[0] = a ? 0x7C : 0x03;
                px[1] = a ? 0x4D : 0xDA;
                px[2] = a ? 0xFF : 0xC6;
                px[3] = 0xFF;
            }
        }
        return img;
    }
};
