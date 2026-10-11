// Klaxon x Qt comparison benchmark runner (roadmap Phase 4c.4, scene
// catalogue v2 — docs/specs/bench-scenes.md).
//
// Renders the canonical bench scenes (the 9 Phase-4c.4 scenes plus the 24
// catalogue-v2 scenes: 6 list_ops + 4 ramp + 10 stress + 4 system) with Qt 6
// Quick and emits the SAME JSON report (schema v2, src/bench_main.zig +
// docs/specs/bench-scenes.md), so the frameworks can be compared
// head-to-head.
//
// Harness contract (docs/specs/bench-scenes.md):
//   - 640x480, opaque background #14141CFF.
//   - 10 warmup + 120 measured frames, UNPACED loop (render as fast as the
//     raster backend allows — no vsync, no pacing timer). The 9 Phase-4c.4
//     scenes ran 600 measured frames under the old contract; schema v2
//     codifies 120 for every standard scene (bench.zig RunOptions.frames
//     defaults to 120 — the published numbers used -Dbench-frames=600).
//   - list_ops scenes: the operation runs once between warmup and the
//     measured phase and is timed separately (extra.op_ms = op + one full
//     render pass); frame timing metrics are collected over the 60 frames
//     after the op.
//   - ramp scenes: N = 10..3200, 10 warmup + 20 measured frames per step;
//     per-step p50 goes to extra.ramp[]; extra.n_max_60fps = largest step
//     with p50 <= 16.67 ms. The top-level frame metrics aggregate all 180
//     measured frames.
//   - system scenes: input_latency injects a synthetic pointer event during
//     the measured run and counts frames until the response paints
//     (extra.latency_frames, extra.latency_ms); app_switch unloads/reloads
//     the scene every 60 frames (extra.teardown_ms, extra.resume_ms);
//     semantics_build walks the item tree once per frame inside the tick
//     (extra.nodes_per_frame); pointer_storm's hit-test loop is inside its
//     tick (no extras).
//   - per-frame WORK = scene tick + layout + render, timed per frame.
//   - fps = 1000 / frame_time_avg_ms; frame_time avg/p50/p99/p999 over the
//     measured frames (nearest-rank percentile). A frame is jank when
//     frame_ms > 16.67 (the 60 Hz budget — Macrobenchmark/JankStats
//     convention); jank_frames/jank_pct report it.
//   - draw_calls_per_frame = visible painted nodes: the number of visible
//     QQuickItems under the scene's root item, counted after the final frame.
//   - rss_mb = process RSS (mach_task_basic_info resident_size).
//   - ttff_ms = run start (scene load included) -> the END of the first
//     completed frame.
//   - frames_rendered = every frame painted (warmup + measured + the op
//     frame for list_ops; 270 for ramp scenes).
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
// Scene selection: argv[1] = one scene, no argument = all 33. The JSON report
// goes to stdout and to $KLAXON_BENCH_OUT_DIR/<ISO8601-timestamp>.json
// (default bench/results/qt; run.sh points it at the repo's bench/results/qt).

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QMetaObject>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickView>
#include <QTextStream>

#include <mach/mach.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <vector>

#include "BenchDriver.h"
#include "BenchImageProvider.h"
#include "StarClipItem.h"
#include "VideoItem.h"

namespace {

constexpr int kWidth = 640;
constexpr int kHeight = 480;
constexpr int kWarmupFrames = 10;
constexpr int kMeasuredFrames = 120;        // schema v2 contract
constexpr int kListOpMeasuredFrames = 60;   // "60 frames after the op"
constexpr int kRampStepFrames = 20;         // measured frames per ramp step
constexpr double kJankBudgetMs = 16.67;     // 60 Hz frame budget

// The 33 canonical scenes, in catalogue order: the 9 Phase-4c.4 scenes, then
// list_ops, ramp, stress, system (docs/specs/bench-scenes.md).
enum class SceneKind {
    Standard,      // 10 warmup + 120 measured, optional extras
    ListOp,        // 10 warmup + timed op + 60 measured, extra.op_ms
    Ramp,          // 9 steps x (10 warmup + 20 measured), extra.ramp/n_max_60fps
    InputLatency,  // standard + injected pointer event, extra.latency_*
    AppSwitch,     // standard + teardown/resume cycles, extra.teardown/resume_ms
};

struct SceneDef {
    const char *name;
    SceneKind kind;
};

const SceneDef kScenes[] = {
    // Phase-4c.4 catalogue
    {"hello", SceneKind::Standard},
    {"scroll_10k", SceneKind::Standard},
    {"text_cjk", SceneKind::Standard},
    {"glass_blur", SceneKind::Standard},
    {"anim_100", SceneKind::Standard},
    {"gallery", SceneKind::Standard},
    {"resize", SceneKind::Standard},
    {"input_ime", SceneKind::Standard},
    {"video_playback", SceneKind::Standard},
    // list_ops (krausest js-framework-benchmark adaptation)
    {"list_create_1k", SceneKind::ListOp},
    {"list_replace_1k", SceneKind::ListOp},
    {"list_update_10th", SceneKind::ListOp},
    {"list_swap_rows", SceneKind::ListOp},
    {"list_remove_row", SceneKind::ListOp},
    {"list_clear_1k", SceneKind::ListOp},
    // ramp (MotionMark methodology)
    {"shapes_ramp", SceneKind::Ramp},
    {"paths_ramp", SceneKind::Ramp},
    {"text_ramp", SceneKind::Ramp},
    {"images_ramp", SceneKind::Ramp},
    // stress
    {"overdraw_stack", SceneKind::Standard},
    {"elevation_grid", SceneKind::Standard},
    {"relayout_storm", SceneKind::Standard},
    {"mount_churn", SceneKind::Standard},
    {"scroll_anim", SceneKind::Standard},
    {"text_rich", SceneKind::Standard},
    {"chart_live", SceneKind::Standard},
    {"clip_path", SceneKind::Standard},
    {"theme_switch", SceneKind::Standard},
    {"backdrop_scroll", SceneKind::Standard},
    // system
    {"input_latency", SceneKind::InputLatency},
    {"pointer_storm", SceneKind::Standard},
    {"semantics_build", SceneKind::Standard},
    {"app_switch", SceneKind::AppSwitch},
};
constexpr int kSceneCount = int(sizeof(kScenes) / sizeof(kScenes[0]));

const int kRampSteps[] = {10, 25, 50, 100, 200, 400, 800, 1600, 3200};
constexpr int kRampStepCount = int(sizeof(kRampSteps) / sizeof(kRampSteps[0]));

struct Metrics {
    double fps = 0;
    double frameTimeAvgMs = 0;
    double frameTimeP50Ms = 0;
    double frameTimeP99Ms = 0;
    double frameTimeP999Ms = 0;
    quint64 jankFrames = 0;
    double jankPct = 0;
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

// Nearest-rank percentile of an ascending-sorted sample (bench.zig). p is in
// percent (50/99); the p99.9 tail uses the per-mille overload below.
double percentile(const std::vector<double> &sorted, int p) {
    if (sorted.empty())
        return 0;
    const size_t n = sorted.size();
    const size_t idx = std::min((n * size_t(p)) / 100, n - 1);
    return sorted[idx];
}

double percentilePerMille(const std::vector<double> &sorted, int pMille) {
    if (sorted.empty())
        return 0;
    const size_t n = sorted.size();
    const size_t idx = std::min((n * size_t(pMille)) / 1000, n - 1);
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
    // The body of the JSON "extra" object ("" -> serialized as null).
    QString extra;
};

// Warm the QML compile cache for a scene file: QML compilation is a
// load-time cost, and Klaxon's scenes are compiled into its binary (its
// ttff has no compile step) — so ttff here measures scene construction +
// first frame, the same span Klaxon's ttff covers.
void warmScene(QQuickView &view, const QString &path) {
    const QUrl url = QUrl::fromLocalFile(path);
    view.setSource(url);
    if (view.status() != QQuickView::Ready) {
        qWarning() << "klaxon-bench-qt: cannot load" << path << "-" << view.errors();
        std::exit(1);
    }
    view.setSource(QUrl());
    QCoreApplication::processEvents(QEventLoop::AllEvents, 0);
}

// The timed scene load (inside the runStart -> first-frame span).
void loadScene(QQuickView &view, const QString &path) {
    view.setSource(QUrl::fromLocalFile(path));
    if (view.status() != QQuickView::Ready) {
        qWarning() << "klaxon-bench-qt: cannot load" << path << "-" << view.errors();
        std::exit(1);
    }
}

// One driven frame: the scene tick plus the frame's work (polish + sync +
// render via grabWindow), then an untimed event drain. Klaxon's loop repaints
// every frame unconditionally; grabWindow() drives exactly that (see the
// header comment). Returns the frame's work time in ms and the frame image.
double driveFrame(QQuickView &view, BenchDriver &driver, int frame, QImage *imgOut) {
    const auto t0 = Clock::now();
    driver.tickFrame(frame); // the scene's tick (QML Connections handler)
    const QImage img = view.grabWindow(); // the frame's work
    const auto t1 = Clock::now();
    // Untimed drain: deferred deletions (delegate churn, mount_churn's
    // destroy()) and window resize events are delivered here, outside the
    // measured region.
    QCoreApplication::processEvents(QEventLoop::AllEvents, 0);
    if (imgOut)
        *imgOut = img;
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// Stats over the measured frames (bench.zig run() + schema v2).
void computeStats(std::vector<double> &times, Metrics &m) {
    if (times.empty())
        return;
    double avg = 0;
    quint64 jank = 0;
    for (double t : times) {
        avg += t;
        if (t > kJankBudgetMs)
            ++jank;
    }
    avg /= double(times.size());
    std::sort(times.begin(), times.end());
    m.fps = avg > 0 ? 1000.0 / avg : 0;
    m.frameTimeAvgMs = avg;
    m.frameTimeP50Ms = percentile(times, 50);
    m.frameTimeP99Ms = percentile(times, 99);
    m.frameTimeP999Ms = percentilePerMille(times, 999);
    m.jankFrames = jank;
    m.jankPct = 100.0 * double(jank) / double(times.size());
}

// Post-run render verification (stderr, always on): proves frames actually
// render offscreen — the grabbed pixels change when the scene animates
// (static scenes keep an equal hash) and the freshly grabbed frame contains
// ink (content really painted, not a blank/cached image).
void renderCheck(QQuickView &view, const QString &scene, quint64 hashA, quint64 hashB, bool isStatic) {
    const QImage check = view.grabWindow();
    const QRgb corner = check.pixel(2, 2);
    int ink = 0;
    for (int y = 0; y < check.height(); y += 3)
        for (int x = 0; x < check.width(); x += 3)
            if (check.pixel(x, y) != corner)
                ++ink;
    // The corner pixel too: overdraw_stack composites to a single uniform
    // color (ink-samples is legitimately 0 — every pixel equals the
    // corner), so the corner value is what proves the stack painted.
    qInfo().noquote() << QStringLiteral("klaxon-bench-qt: %1 render-check — corner:#%2 ink-samples:%3 pixels-change:%4 (static:%5)")
                             .arg(scene)
                             .arg(corner & 0xFFFFFF, 6, 16, QLatin1Char('0'))
                             .arg(ink)
                             .arg(hashA != hashB)
                             .arg(isStatic);
}

// The scenes whose rendered pixels stay identical between the two hash
// probes (frame ~30 and the last frame): everything else must animate.
bool isStaticScene(const QString &scene) {
    static const char *const kStatic[] = {
        // Phase-4c.4
        "hello", "text_cjk", "glass_blur", "gallery",
        // list_ops: the op runs once, then the scene is static for the 60
        // measured frames (the hash probes land after the op).
        "list_create_1k", "list_replace_1k", "list_update_10th",
        "list_swap_rows", "list_remove_row", "list_clear_1k",
        // stress/system with static pixels
        "overdraw_stack", "text_rich", "pointer_storm", "semantics_build",
        "app_switch", // reloads the identical tree -> identical pixels
    };
    for (const char *const s : kStatic)
        if (scene == QLatin1String(s))
            return true;
    return false;
}

// The standard scene path: 10 warmup + N measured frames (tick + render).
// `extraFn` (optional) collects scene extras after the run.
SceneResult runStandard(QQuickView &view, BenchDriver &driver, const QString &scene,
                        int measuredFrames) {
    const QString path =
        QStringLiteral(KLAXON_QML_DIR) + QLatin1Char('/') + scene + QStringLiteral(".qml");
    SceneResult result;
    Metrics &m = result.metrics;
    warmScene(view, path);
    const auto runStart = Clock::now();
    loadScene(view, path);

    const int total = kWarmupFrames + measuredFrames;
    std::vector<double> times;
    times.reserve(size_t(measuredFrames));
    quint64 hashA = 0, hashB = 0;

    for (int i = 0; i < total; ++i) {
        QImage img;
        const double ms = driveFrame(view, driver, i, &img);
        if (i == 0)
            m.ttffMs = std::chrono::duration<double, std::milli>(Clock::now() - runStart).count();
        if (i >= kWarmupFrames)
            times.push_back(ms);
        if (i == 30)
            hashA = imageHash(img);
        if (i == total - 1)
            hashB = imageHash(img);
    }

    computeStats(times, m);
    m.drawCallsPerFrame = countVisibleItems(view.rootObject());
    m.rssMb = readRssMb();
    m.framesRendered = quint64(total);

    renderCheck(view, scene, hashA, hashB, isStaticScene(scene));
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
    if (scene == QLatin1String("semantics_build")) {
        // extra.nodes_per_frame: nodes walked per frame by the tick's
        // semantics build (bench.collectSemantics()).
        result.extra = QStringLiteral("\"nodes_per_frame\": %1").arg(driver.semanticsNodes());
        qInfo().noquote() << QStringLiteral("klaxon-bench-qt: %1 render-check — semantics nodes/frame: %2")
                                 .arg(scene)
                                 .arg(driver.semanticsNodes());
    }

    view.setSource(QUrl());
    QCoreApplication::processEvents(QEventLoop::AllEvents, 0);
    return result;
}

// The list_ops path (krausest adaptation): 10 warmup frames, then the op
// (extra.op_ms = the model mutation + one full render pass), then 60
// measured frames.
SceneResult runListOp(QQuickView &view, BenchDriver &driver, const QString &scene) {
    const QString path =
        QStringLiteral(KLAXON_QML_DIR) + QLatin1Char('/') + scene + QStringLiteral(".qml");
    SceneResult result;
    Metrics &m = result.metrics;
    warmScene(view, path);
    const auto runStart = Clock::now();
    loadScene(view, path);

    const int total = kWarmupFrames + 1 + kListOpMeasuredFrames; // 71
    std::vector<double> times;
    times.reserve(kListOpMeasuredFrames);
    quint64 hashA = 0, hashB = 0;
    double opMs = 0;

    for (int i = 0; i < total; ++i) {
        if (i == kWarmupFrames) {
            // The op: mutate the model (runBenchOp in QML) + one full render
            // pass — timed as extra.op_ms. Its frame is painted (it counts in
            // frames_rendered) but not in the measured frame stats.
            const auto t0 = Clock::now();
            driver.tickFrame(i);
            QMetaObject::invokeMethod(view.rootObject(), "runBenchOp");
            const QImage img = view.grabWindow(); // the op's render pass
            const auto t1 = Clock::now();
            opMs = std::chrono::duration<double, std::milli>(t1 - t0).count();
            QCoreApplication::processEvents(QEventLoop::AllEvents, 0);
            continue;
        }
        QImage img;
        const double ms = driveFrame(view, driver, i, &img);
        if (i == 0)
            m.ttffMs = std::chrono::duration<double, std::milli>(Clock::now() - runStart).count();
        if (i > kWarmupFrames)
            times.push_back(ms);
        if (i == 30)
            hashA = imageHash(img);
        if (i == total - 1)
            hashB = imageHash(img);
    }

    computeStats(times, m);
    m.drawCallsPerFrame = countVisibleItems(view.rootObject());
    m.rssMb = readRssMb();
    m.framesRendered = quint64(total);
    result.extra = QStringLiteral("\"op_ms\": %1").arg(QString::number(opMs, 'f', 2));

    renderCheck(view, scene, hashA, hashB, isStaticScene(scene));
    if (auto *list = view.rootObject()->findChild<QQuickItem *>(QStringLiteral("benchList"))) {
        qInfo().noquote() << QStringLiteral("klaxon-bench-qt: %1 render-check — list count: %2, visible items under list: %3")
                                 .arg(scene)
                                 .arg(list->property("count").toInt())
                                 .arg(countVisibleItems(list));
    }

    view.setSource(QUrl());
    QCoreApplication::processEvents(QEventLoop::AllEvents, 0);
    return result;
}

// The ramp path (MotionMark): steps N = 10..3200, each with the same warmup
// contract (10 warmup + 20 measured). Per-step p50 goes to extra.ramp[];
// extra.n_max_60fps = the largest N whose p50 is within the 60 Hz budget.
// Top-level frame metrics aggregate all 9 x 20 measured frames.
SceneResult runRamp(QQuickView &view, BenchDriver &driver, const QString &scene) {
    const QString path =
        QStringLiteral(KLAXON_QML_DIR) + QLatin1Char('/') + scene + QStringLiteral(".qml");
    SceneResult result;
    Metrics &m = result.metrics;
    warmScene(view, path);
    const auto runStart = Clock::now();
    loadScene(view, path);

    std::vector<double> allTimes;
    allTimes.reserve(size_t(kRampStepCount * kRampStepFrames));
    quint64 hashA = 0, hashB = 0;
    QString rampJson;
    int nMax60 = 0;
    int frame = 0; // continuous across steps (uninterrupted animation)

    for (int s = 0; s < kRampStepCount; ++s) {
        const int n = kRampSteps[s];
        view.rootObject()->setProperty("benchN", n);
        std::vector<double> stepTimes;
        stepTimes.reserve(kRampStepFrames);
        for (int i = 0; i < kWarmupFrames + kRampStepFrames; ++i, ++frame) {
            QImage img;
            const double ms = driveFrame(view, driver, frame, &img);
            if (frame == 0)
                m.ttffMs = std::chrono::duration<double, std::milli>(Clock::now() - runStart).count();
            if (i >= kWarmupFrames) {
                stepTimes.push_back(ms);
                allTimes.push_back(ms);
            }
            if (frame == 30)
                hashA = imageHash(img);
        }
        std::vector<double> sorted = stepTimes;
        std::sort(sorted.begin(), sorted.end());
        const double p50 = percentile(sorted, 50);
        if (p50 <= kJankBudgetMs)
            nMax60 = n;
        if (s > 0)
            rampJson += QLatin1Char(',');
        rampJson += QStringLiteral("{\"n\": %1, \"p50_ms\": %2}")
                        .arg(n)
                        .arg(QString::number(p50, 'f', 2));
        qInfo().noquote() << QStringLiteral("klaxon-bench-qt: %1 step n=%2 — p50 %3 ms")
                                 .arg(scene)
                                 .arg(n)
                                 .arg(QString::number(p50, 'f', 2));
        hashB = 0;
    }
    // Last-frame hash probe.
    {
        const QImage img = view.grabWindow();
        hashB = imageHash(img);
    }

    computeStats(allTimes, m);
    m.drawCallsPerFrame = countVisibleItems(view.rootObject());
    m.rssMb = readRssMb();
    m.framesRendered = quint64(kRampStepCount * (kWarmupFrames + kRampStepFrames)); // 270
    result.extra = QStringLiteral("\"ramp\": [%1], \"n_max_60fps\": %2")
                       .arg(rampJson)
                       .arg(nMax60);

    renderCheck(view, scene, hashA, hashB, isStaticScene(scene));
    view.setSource(QUrl());
    QCoreApplication::processEvents(QEventLoop::AllEvents, 0);
    return result;
}

// The input_latency path: the standard loop, plus one synthetic pointer
// event injected after a fixed measured frame. extra.latency_frames counts
// frames from the injection until the visual response is in the grabbed
// pixels; extra.latency_ms is the wall span injection -> painting frame.
SceneResult runInputLatency(QQuickView &view, BenchDriver &driver, const QString &scene) {
    const QString path =
        QStringLiteral(KLAXON_QML_DIR) + QLatin1Char('/') + scene + QStringLiteral(".qml");
    SceneResult result;
    Metrics &m = result.metrics;
    warmScene(view, path);
    const auto runStart = Clock::now();
    loadScene(view, path);

    auto *target = view.rootObject()->findChild<QQuickItem *>(
        QStringLiteral("latencyBox"), Qt::FindChildrenRecursively);
    if (!target) {
        qWarning() << "klaxon-bench-qt:" << scene << "has no latencyBox item";
        std::exit(1);
    }
    const QPointF center =
        target->mapToScene(QPointF(target->width() / 2, target->height() / 2));
    // The probe samples the response fill, not the centered label glyph —
    // a point inside the target's top-left region (past the corner radius).
    const QPoint px =
        target->mapToScene(QPointF(30, 30)).toPoint();

    const int total = kWarmupFrames + kMeasuredFrames;
    const int injectFrame = kWarmupFrames + 30; // mid-run injection
    std::vector<double> times;
    times.reserve(kMeasuredFrames);
    quint64 hashA = 0, hashB = 0;
    QRgb baseline = 0;
    int latencyFrames = -1;
    double latencyMs = 0;
    Clock::time_point injectedAt{};

    for (int i = 0; i < total; ++i) {
        if (i == injectFrame) {
            // Sample the target's current paint, then inject the pointer
            // event between frames: the response can only appear in a
            // subsequent frame, so latency counts real event->paint frames.
            const QImage probe = view.grabWindow();
            baseline = probe.pixel(px);
            driver.pressAt(center.x(), center.y());
            injectedAt = Clock::now();
        }
        QImage img;
        const double ms = driveFrame(view, driver, i, &img);
        if (i == 0)
            m.ttffMs = std::chrono::duration<double, std::milli>(Clock::now() - runStart).count();
        if (i >= kWarmupFrames)
            times.push_back(ms);
        if (i == 30)
            hashA = imageHash(img);
        if (i == total - 1)
            hashB = imageHash(img);
        if (i >= injectFrame && latencyFrames < 0 && img.pixel(px) != baseline) {
            latencyFrames = i - injectFrame + 1;
            latencyMs = std::chrono::duration<double, std::milli>(Clock::now() - injectedAt).count();
        }
    }
    if (latencyFrames < 0) {
        qWarning() << "klaxon-bench-qt:" << scene
                   << "pointer response never painted at" << px;
        latencyFrames = -1;
        latencyMs = -1;
    }

    computeStats(times, m);
    m.drawCallsPerFrame = countVisibleItems(view.rootObject());
    m.rssMb = readRssMb();
    m.framesRendered = quint64(total);
    result.extra = QStringLiteral("\"latency_frames\": %1, \"latency_ms\": %2")
                       .arg(latencyFrames)
                       .arg(QString::number(latencyMs, 'f', 2));

    renderCheck(view, scene, hashA, hashB, isStaticScene(scene));
    qInfo().noquote() << QStringLiteral("klaxon-bench-qt: %1 render-check — latency %2 frames / %3 ms")
                             .arg(scene)
                             .arg(latencyFrames)
                             .arg(QString::number(latencyMs, 'f', 2));

    view.setSource(QUrl());
    QCoreApplication::processEvents(QEventLoop::AllEvents, 0);
    return result;
}

// The app_switch path: the standard loop, plus a pause->resume cycle every
// 60 frames (teardown = unload + destruction, resume = reload -> first
// painted frame). extra.teardown_ms / extra.resume_ms average the cycles.
SceneResult runAppSwitch(QQuickView &view, BenchDriver &driver, const QString &scene) {
    const QString path =
        QStringLiteral(KLAXON_QML_DIR) + QLatin1Char('/') + scene + QStringLiteral(".qml");
    const QUrl url = QUrl::fromLocalFile(path);
    SceneResult result;
    Metrics &m = result.metrics;
    warmScene(view, path);
    const auto runStart = Clock::now();
    loadScene(view, path);

    const int total = kWarmupFrames + kMeasuredFrames;
    std::vector<double> times;
    times.reserve(kMeasuredFrames);
    quint64 hashA = 0, hashB = 0;
    double teardownSum = 0, resumeSum = 0;
    int cycles = 0;

    for (int i = 0; i < total; ++i) {
        if (i > 0 && i % 60 == 0) {
            // Pause: unload the scene (root destruction included).
            const auto t0 = Clock::now();
            view.setSource(QUrl());
            QCoreApplication::processEvents(QEventLoop::AllEvents, 0);
            const auto t1 = Clock::now();
            // Resume: reload and paint the first frame — resume_ms spans
            // reconstruction to the end of the first completed frame (the
            // frame's ms is this resume span).
            const auto t2 = Clock::now();
            view.setSource(url);
            if (view.status() != QQuickView::Ready) {
                qWarning() << "klaxon-bench-qt: cannot reload" << path << "-" << view.errors();
                std::exit(1);
            }
            driver.tickFrame(i);
            const QImage img = view.grabWindow();
            const auto t3 = Clock::now();
            teardownSum += std::chrono::duration<double, std::milli>(t1 - t0).count();
            resumeSum += std::chrono::duration<double, std::milli>(t3 - t2).count();
            ++cycles;
            const double ms = std::chrono::duration<double, std::milli>(t3 - t2).count();
            if (i >= kWarmupFrames)
                times.push_back(ms);
            if (i == total - 1)
                hashB = imageHash(img);
            continue;
        }
        QImage img;
        const double ms = driveFrame(view, driver, i, &img);
        if (i == 0)
            m.ttffMs = std::chrono::duration<double, std::milli>(Clock::now() - runStart).count();
        if (i >= kWarmupFrames)
            times.push_back(ms);
        if (i == 30)
            hashA = imageHash(img);
        if (i == total - 1)
            hashB = imageHash(img);
    }

    computeStats(times, m);
    m.drawCallsPerFrame = countVisibleItems(view.rootObject());
    m.rssMb = readRssMb();
    m.framesRendered = quint64(total);
    const double teardownAvg = cycles ? teardownSum / cycles : 0;
    const double resumeAvg = cycles ? resumeSum / cycles : 0;
    result.extra = QStringLiteral("\"teardown_ms\": %1, \"resume_ms\": %2")
                       .arg(QString::number(teardownAvg, 'f', 2))
                       .arg(QString::number(resumeAvg, 'f', 2));

    renderCheck(view, scene, hashA, hashB, isStaticScene(scene));
    qInfo().noquote() << QStringLiteral("klaxon-bench-qt: %1 render-check — %2 switch cycles, teardown %3 ms, resume %4 ms")
                             .arg(scene)
                             .arg(cycles)
                             .arg(QString::number(teardownAvg, 'f', 2))
                             .arg(QString::number(resumeAvg, 'f', 2));

    view.setSource(QUrl());
    QCoreApplication::processEvents(QEventLoop::AllEvents, 0);
    return result;
}

SceneResult runScene(QQuickView &view, BenchDriver &driver, const SceneDef &def) {
    const QString scene = QLatin1String(def.name);
    switch (def.kind) {
    case SceneKind::ListOp:
        return runListOp(view, driver, scene);
    case SceneKind::Ramp:
        return runRamp(view, driver, scene);
    case SceneKind::InputLatency:
        return runInputLatency(view, driver, scene);
    case SceneKind::AppSwitch:
        return runAppSwitch(view, driver, scene);
    case SceneKind::Standard:
        return runStandard(view, driver, scene, kMeasuredFrames);
    }
    return SceneResult{};
}

} // namespace

int main(int argc, char *argv[]) {
    // Deterministic QML loading: no on-disk QML cache (keeps the source tree
    // clean and the per-scene compile warm-up in charge of ttff).
    qputenv("QML_DISABLE_DISK_CACHE", "1");
    QGuiApplication app(argc, argv);
    qmlRegisterType<VideoItem>("klaxonbench", 1, 0, "VideoItem");
    qmlRegisterType<StarClipItem>("klaxonbench", 1, 0, "StarClipItem");

    // Scene selection: argv[1] runs one scene, no argument runs all 33
    // (bench_main.zig: -Dbench-scene=NAME or all). Unknown name = non-zero.
    std::vector<QString> scenes;
    const QStringList args = app.arguments();
    if (args.size() > 1) {
        const QString &only = args.at(1);
        bool found = false;
        for (const SceneDef &def : kScenes) {
            if (only == QLatin1String(def.name)) {
                scenes.push_back(only);
                found = true;
                break;
            }
        }
        if (!found) {
            QTextStream err(stderr);
            err << "klaxon-bench-qt: unknown scene '" << only << "' — valid scenes:";
            for (const SceneDef &def : kScenes)
                err << " " << def.name;
            err << "\n";
            return 1;
        }
    } else {
        for (const SceneDef &def : kScenes)
            scenes.emplace_back(QLatin1String(def.name));
    }

    QQuickView view;
    view.setResizeMode(QQuickView::SizeRootObjectToView);
    view.setColor(QColor("#14141C")); // the bench BG clear (#14141CFF)
    view.resize(kWidth, kHeight);
    view.engine()->addImageProvider(QStringLiteral("bench"), new BenchImageProvider);
    BenchDriver driver(&view);
    view.rootContext()->setContextProperty(QStringLiteral("bench"), &driver);
    int frameSwapped = 0;
    QObject::connect(&view, &QQuickView::frameSwapped, &app, [&]() { ++frameSwapped; });
    view.show(); // offscreen: no real window; makes the scene graph live

    std::vector<SceneResult> results;
    results.reserve(scenes.size());
    for (size_t i = 0; i < scenes.size(); ++i) {
        const SceneDef *def = nullptr;
        for (const SceneDef &d : kScenes)
            if (scenes[i] == QLatin1String(d.name))
                def = &d;
        view.resize(kWidth, kHeight); // reset (the resize scene changes it)
        qInfo().noquote() << QStringLiteral("klaxon-bench-qt: %1 (%2/%3)...")
                                 .arg(scenes[i])
                                 .arg(i + 1)
                                 .arg(scenes.size());
        const int before = frameSwapped;
        results.push_back(runScene(view, driver, *def));
        results.back().frameSwapped = frameSwapped - before;
        qInfo().noquote() << QStringLiteral("klaxon-bench-qt: %1 done — frameSwapped +%2 (fires when the tick requested an update)")
                                 .arg(scenes[i])
                                 .arg(results.back().frameSwapped);
    }
    qInfo() << "klaxon-bench-qt: frameSwapped total:" << frameSwapped;

    // --- JSON report: the bench_main.zig formatReport shape + schema v2 ---
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
          << "      \"frame_time_p999_ms\": " << QString::number(m.frameTimeP999Ms, 'f', 1) << ",\n"
          << "      \"jank_frames\": " << m.jankFrames << ",\n"
          << "      \"jank_pct\": " << QString::number(m.jankPct, 'f', 1) << ",\n"
          << "      \"draw_calls_per_frame\": " << m.drawCallsPerFrame << ",\n"
          << "      \"rss_mb\": " << QString::number(m.rssMb, 'f', 1) << ",\n"
          << "      \"ttff_ms\": " << QString::number(m.ttffMs, 'f', 1) << ",\n"
          << "      \"frames_rendered\": " << m.framesRendered << ",\n"
          << "      \"extra\": "
          << (results[i].extra.isEmpty() ? QStringLiteral("null")
                                        : QStringLiteral("{") + results[i].extra + QStringLiteral("}"))
          << "\n"
          << "    }";
    }
    s << "\n  ],\n"
      << "  \"schema_version\": 2,\n"
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
