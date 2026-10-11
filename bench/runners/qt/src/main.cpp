// Klaxon x Qt comparison benchmark runner (roadmap Phase 4c.4).
//
// Renders the same 9 scenes as Klaxon's own bench (src/bench.zig) with Qt 6
// Quick and emits the SAME JSON report (schema in src/bench_main.zig), so the
// two frameworks can be compared head-to-head.
//
// Harness contract (mirrors src/bench.zig + src/bench_main.zig):
//   - 640x480, 10 warmup + 600 measured frames, UNPACED loop (render as fast
//     as the raster backend allows — no vsync, no pacing timer).
//   - per-frame WORK = scene tick + layout + render, timed per frame.
//   - fps = 1000 / frame_time_avg_ms; frame_time avg/p50/p99 over the 600
//     measured frames (nearest-rank percentile, the devtools convention).
//   - draw_calls_per_frame = visible painted nodes: the number of visible
//     QQuickItems under the scene's root item, counted after the final frame
//     (Klaxon counts the visible nodes of its widget tree the same way).
//   - rss_mb = process RSS (mach_task_basic_info resident_size — the same
//     source devtools.readRssMb uses on macOS).
//   - ttff_ms = run start (scene load included) -> the END of the first
//     completed frame.
//   - frames_rendered = 610 (warmup + measured).
//
// Headless model: QT_QPA_PLATFORM=offscreen + QT_QUICK_BACKEND=software (set
// by run.sh) — CPU raster, no window, no GPU, no vsync — the closest Qt
// analog of Klaxon's headless raster bench. An offscreen window is never
// exposed, so Qt's render loop does not schedule frames by itself; the
// harness drives one frame per iteration with QQuickWindow::grabWindow(),
// which synchronously performs the frame's work (polish + sync + render into
// a raster image) and emits frameSwapped. The harness verifies frames really
// render: frameSwapped fires once per driven frame and the grabbed pixels
// change when the scene animates (see README.md).
//
// Scene selection: argv[1] = one scene, no argument = all 9. The JSON report
// goes to stdout and to $KLAXON_BENCH_OUT_DIR/<ISO8601-timestamp>.json
// (default bench/results/qt; run.sh points it at the repo's bench/results/qt).

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickView>
#include <QTextStream>

#include <mach/mach.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <vector>

#include "BenchDriver.h"
#include "VideoItem.h"

namespace {

constexpr int kWidth = 640;
constexpr int kHeight = 480;
constexpr int kWarmupFrames = 10;
constexpr int kMeasuredFrames = 600;
constexpr int kTotalFrames = kWarmupFrames + kMeasuredFrames; // 610

// The 9 canonical scenes, in BenchScene enum order (src/bench.zig).
const char *const kSceneNames[] = {
    "hello",   "scroll_10k", "text_cjk",  "glass_blur", "anim_100",
    "gallery", "resize",      "input_ime", "video_playback",
};
constexpr int kSceneCount = 9;

struct Metrics {
    double fps = 0;
    double frameTimeAvgMs = 0;
    double frameTimeP50Ms = 0;
    double frameTimeP99Ms = 0;
    quint64 drawCallsPerFrame = 0;
    double rssMb = 0;
    double ttffMs = 0;
    quint64 framesRendered = 0;
};

using Clock = std::chrono::steady_clock;

// Resident set size in MB — mach_task_basic_info's resident_size, the same
// source devtools.readRssMbMac uses.
double readRssMb() {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return 0.0;
    return double(info.resident_size) / (1024.0 * 1024.0);
}

// The draw-call estimate: visible QQuickItems under the scene's root item
// (QQuickWindow::contentItem excluded). Klaxon's countPaintNodes walks its
// widget tree the same way; the granularity differs where Klaxon paints
// several fills inside one custom node (see README.md).
quint64 countVisibleItems(const QQuickItem *item) {
    if (!item || !item->isVisible())
        return 0;
    quint64 n = 1;
    const QList<QQuickItem *> children = item->childItems();
    for (const QQuickItem *c : children)
        n += countVisibleItems(c);
    return n;
}

// Nearest-rank percentile of an ascending-sorted sample (bench.zig).
double percentile(const std::vector<double> &sorted, int p) {
    if (sorted.empty())
        return 0;
    const size_t n = sorted.size();
    const size_t idx = std::min((n * size_t(p)) / 100, n - 1);
    return sorted[idx];
}

quint64 imageHash(const QImage &img) {
    quint64 h = 1469598103934665603ULL;
    for (int y = 0; y < img.height(); y += 7)
        for (int x = 0; x < img.width(); x += 7) {
            h ^= quint64(img.pixel(x, y));
            h *= 1099511628211ULL;
        }
    return h;
}

struct SceneResult {
    Metrics metrics;
    int frameSwapped = 0;
};

SceneResult runScene(QQuickView &view, BenchDriver &driver, const QString &scene) {
    const QString path =
        QStringLiteral(KLAXON_QML_DIR) + QLatin1Char('/') + scene + QStringLiteral(".qml");
    const QUrl url = QUrl::fromLocalFile(path);
    SceneResult result;
    Metrics &m = result.metrics;

    // Warm the QML compile cache: QML compilation is a load-time cost, and
    // Klaxon's scenes are compiled into its binary (its ttff has no compile
    // step) — so ttff here measures scene construction + first frame, the
    // same span Klaxon's ttff covers.
    view.setSource(url);
    if (view.status() != QQuickView::Ready) {
        qWarning() << "klaxon-bench-qt: cannot load" << path << "-" << view.errors();
        std::exit(1);
    }
    view.setSource(QUrl());
    QCoreApplication::processEvents(QEventLoop::AllEvents, 0);

    const auto runStart = Clock::now();
    view.setSource(url);
    if (view.status() != QQuickView::Ready) {
        qWarning() << "klaxon-bench-qt: cannot load" << path << "-" << view.errors();
        std::exit(1);
    }

    std::vector<double> times;
    times.reserve(kMeasuredFrames);
    quint64 hashA = 0, hashB = 0;

    for (int i = 0; i < kTotalFrames; ++i) {
        const auto t0 = Clock::now();
        driver.tickFrame(i);            // the scene's tick (QML Connections handler)
        // Klaxon's loop repaints every frame unconditionally (renderer.paint
        // runs whether or not anything changed). grabWindow() drives exactly
        // that: the software render loop's grab path calls renderWindow()
        // unconditionally (polish + sync + full render into the backing
        // store, then a copy of the store into the returned image — verified
        // with QSG_RASTER_LOG_TIME_RENDERLOOP: one "Frame rendered" line per
        // driven frame).
        const QImage img = view.grabWindow(); // the frame's work: polish + sync + render
        const auto t1 = Clock::now();
        // Untimed drain: deferred deletions (list virtualization churn) and
        // window resize events (resize scene) are delivered here, outside the
        // measured region.
        QCoreApplication::processEvents(QEventLoop::AllEvents, 0);

        const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        if (i == 0)
            m.ttffMs = std::chrono::duration<double, std::milli>(t1 - runStart).count();
        if (i >= kWarmupFrames)
            times.push_back(ms);
        // Render verification (stderr): the grabbed pixels must change when
        // the scene animates and stay equal when it is static.
        if (i == 30)
            hashA = imageHash(img);
        if (i == kTotalFrames - 1)
            hashB = imageHash(img);
    }

    // --- stats over the measured frames (bench.zig run()) ---
    double avg = 0;
    for (double t : times)
        avg += t;
    avg /= double(times.size());
    std::sort(times.begin(), times.end());
    m.fps = avg > 0 ? 1000.0 / avg : 0;
    m.frameTimeAvgMs = avg;
    m.frameTimeP50Ms = percentile(times, 50);
    m.frameTimeP99Ms = percentile(times, 99);
    m.drawCallsPerFrame = countVisibleItems(view.rootObject());
    m.rssMb = readRssMb();
    m.framesRendered = kTotalFrames;

    // Render verification (stderr, always on): proves frames actually render
    // offscreen — the grabbed pixels change when the scene animates (static
    // scenes keep an equal hash), the freshly grabbed frame contains ink
    // (content really painted, not a blank/cached image), the IME field
    // accumulates text, and the virtualized list sits at the tick-driven
    // offset with a small live window.
    const QImage check = view.grabWindow();
    const QRgb corner = check.pixel(2, 2);
    int ink = 0;
    for (int y = 0; y < check.height(); y += 3)
        for (int x = 0; x < check.width(); x += 3)
            if (check.pixel(x, y) != corner)
                ++ink;
    const bool isStatic = scene == QLatin1String("hello") || scene == QLatin1String("text_cjk")
        || scene == QLatin1String("glass_blur") || scene == QLatin1String("gallery");
    qInfo().noquote() << QStringLiteral("klaxon-bench-qt: %1 render-check — ink-samples:%2 pixels-change:%3 (static:%4)")
                             .arg(scene)
                             .arg(ink)
                             .arg(hashA != hashB)
                             .arg(isStatic);
    if (auto *input = view.rootObject()->findChild<QQuickItem *>(QStringLiteral("imeInput"))) {
        const QString text = input->property("text").toString();
        qInfo().noquote() << QStringLiteral("klaxon-bench-qt: %1 render-check — imeInput text length: %2")
                                 .arg(scene)
                                 .arg(text.length());
    }
    if (auto *list = view.rootObject()->findChild<QQuickItem *>(QStringLiteral("benchList"))) {
        qInfo().noquote() << QStringLiteral("klaxon-bench-qt: %1 render-check — list contentY: %2, visible items under list: %3")
                                 .arg(scene)
                                 .arg(list->property("contentY").toReal())
                                 .arg(countVisibleItems(list));
    }

    // Teardown: unload the scene before the next one loads.
    view.setSource(QUrl());
    QCoreApplication::processEvents(QEventLoop::AllEvents, 0);
    return result;
}

} // namespace

int main(int argc, char *argv[]) {
    // Deterministic QML loading: no on-disk QML cache (keeps the source tree
    // clean and the per-scene compile warm-up in charge of ttff).
    qputenv("QML_DISABLE_DISK_CACHE", "1");
    QGuiApplication app(argc, argv);
    qmlRegisterType<VideoItem>("klaxonbench", 1, 0, "VideoItem");

    // Scene selection: argv[1] runs one scene, no argument runs all 9
    // (bench_main.zig: -Dbench-scene=NAME or all).
    std::vector<QString> scenes;
    const QStringList args = app.arguments();
    if (args.size() > 1) {
        const QString &only = args.at(1);
        bool found = false;
        for (const char *const name : kSceneNames) {
            if (only == QLatin1String(name)) {
                scenes.push_back(only);
                found = true;
                break;
            }
        }
        if (!found) {
            QTextStream err(stderr);
            err << "klaxon-bench-qt: unknown scene '" << only << "' — valid scenes:";
            for (const char *const name : kSceneNames)
                err << " " << name;
            err << "\n";
            return 1;
        }
    } else {
        for (const char *const name : kSceneNames)
            scenes.emplace_back(QLatin1String(name));
    }


    QQuickView view;
    view.setResizeMode(QQuickView::SizeRootObjectToView);
    view.setColor(QColor("#14141C")); // Klaxon's bench BG clear
    view.resize(kWidth, kHeight);
    BenchDriver driver(&view);
    view.rootContext()->setContextProperty(QStringLiteral("bench"), &driver);
    int frameSwapped = 0;
    QObject::connect(&view, &QQuickView::frameSwapped, &app, [&]() { ++frameSwapped; });
    view.show(); // offscreen: no real window; makes the scene graph live

    std::vector<SceneResult> results;
    results.reserve(scenes.size());
    for (size_t i = 0; i < scenes.size(); ++i) {
        view.resize(kWidth, kHeight); // reset (the resize scene changes it)
        qInfo().noquote() << QStringLiteral("klaxon-bench-qt: %1 (%2/%3)...")
                                 .arg(scenes[i])
                                 .arg(i + 1)
                                 .arg(scenes.size());
        const int before = frameSwapped;
        results.push_back(runScene(view, driver, scenes[i]));
        results.back().frameSwapped = frameSwapped - before;
        qInfo().noquote() << QStringLiteral("klaxon-bench-qt: %1 done — frameSwapped +%2 (fires when the tick requested an update)")
                                 .arg(scenes[i])
                                 .arg(results.back().frameSwapped);
    }
    qInfo() << "klaxon-bench-qt: frameSwapped total:" << frameSwapped;

    // --- JSON report: the bench_main.zig formatReport shape, field for field ---
    const QString tsIso = QDateTime::currentDateTimeUtc().toString(
        QStringLiteral("yyyy-MM-dd'T'HH:mm:ss'Z'"));
    const quint64 binarySize =
        quint64(QFileInfo(QCoreApplication::applicationFilePath()).size());

    QString json;
    QTextStream s(&json);
    s << "{\n  \"scenes\": [\n";
    for (size_t i = 0; i < scenes.size(); ++i) {
        if (i > 0)
            s << ",\n";
        const Metrics &m = results[i].metrics;
        s << "    {\n"
          << "      \"name\": \"" << scenes[i] << "\",\n"
          << "      \"fps\": " << QString::number(m.fps, 'f', 1) << ",\n"
          << "      \"frame_time_avg_ms\": " << QString::number(m.frameTimeAvgMs, 'f', 1) << ",\n"
          << "      \"frame_time_p50_ms\": " << QString::number(m.frameTimeP50Ms, 'f', 1) << ",\n"
          << "      \"frame_time_p99_ms\": " << QString::number(m.frameTimeP99Ms, 'f', 1) << ",\n"
          << "      \"draw_calls_per_frame\": " << m.drawCallsPerFrame << ",\n"
          << "      \"rss_mb\": " << QString::number(m.rssMb, 'f', 1) << ",\n"
          << "      \"ttff_ms\": " << QString::number(m.ttffMs, 'f', 1) << ",\n"
          << "      \"frames_rendered\": " << m.framesRendered << "\n"
          << "    }";
    }
    s << "\n  ],\n"
      << "  \"binary_size_bytes\": " << binarySize << ",\n"
      << "  \"timestamp\": \"" << tsIso << "\"\n"
      << "}\n";

    // stdout (progress went to stderr, so the JSON stream stays clean).
    QTextStream out(stdout);
    out << json;
    out.flush();

    // The same report to bench/results/qt/<ISO8601-timestamp>.json.
    QString outDir = qEnvironmentVariable("KLAXON_BENCH_OUT_DIR");
    if (outDir.isEmpty())
        outDir = QStringLiteral("bench/results/qt");
    QDir().mkpath(outDir);
    const QString tsFile = QDateTime::currentDateTimeUtc().toString(
        QStringLiteral("yyyy-MM-dd'T'HH-mm-ss'Z'"));
    const QString filePath = outDir + QLatin1Char('/') + tsFile + QStringLiteral(".json");
    QFile file(filePath);
    if (file.open(QIODevice::WriteOnly)) {
        file.write(json.toUtf8());
        file.close();
        qInfo() << "klaxon-bench-qt: report written to" << filePath;
    } else {
        qWarning() << "klaxon-bench-qt: cannot write report to" << filePath;
    }
    return 0;
}
