// Harness for the Flutter comparison benchmark (roadmap Phase 4c.4).
//
// Replicates the Klaxon bench contract (src/bench.zig + src/bench_main.zig):
//   - fixed 640x480 logical viewport,
//   - 10 warmup + 600 measured frames per scene, one frame per ticker tick,
//   - frame work = FrameTiming(build + raster) — layout is folded into
//     buildDuration in Flutter 3.47's FrameTiming; this is Flutter's analog
//     of Klaxon's tick + layout + paint,
//   - fps = 1000 / avg(frame work),
//   - draw_calls_per_frame = number of RenderObjects under the scene root
//     (Klaxon's "visible painted nodes"; ListView.builder virtualization keeps
//     this small for the scroll scenes),
//   - rss_mb = ProcessInfo.currentRss / 1e6,
//   - ttff_ms = scene start -> the scene's first completed frame (FrameTiming),
//   - frames_rendered = 610.
//
// The scene root is force-repainted (markNeedsPaint) every frame so that
// static scenes still measure a real paint + raster pass, matching Klaxon's
// renderer.paint(root, BG) on every frame.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// Run options (src/bench.zig RunOptions, with bench_frames = 600).
const int kWarmupFrames = 10;
const int kMeasuredFrames = 600;
const int kTotalFrames = kWarmupFrames + kMeasuredFrames; // 610

/// The harness viewport (bench.zig: 640x480).
const double kViewportWidth = 640;
const double kViewportHeight = 480;

/// The surface background (bench.zig BG = 0x14141CFF).
const Color kBenchBackground = Color(0xFF14141C);

/// Shared text styles (bench.zig's title/body colors).
const TextStyle kBenchTitleStyle = TextStyle(fontSize: 14, color: Color(0xFFCCCCCC));
const TextStyle kBenchBodyStyle = TextStyle(fontSize: 14, color: Colors.white);

/// One canonical bench scene (the Flutter port of a src/bench.zig scene).
abstract class BenchScene {
  BenchScene(this.name);

  final String name;

  /// The scene's widget tree, rebuilt from the scene's mutable state.
  Widget build(BuildContext context);

  /// Per-frame scene logic (Klaxon's SceneRunner.tick), driven once per
  /// rendered frame with the 0-based frame index (warmup frames included).
  void tick(int frame, BenchHarnessState harness);

  /// Release scene-owned resources (controllers, focus nodes, ...).
  void dispose() {}
}

/// Collected metrics for one scene (mirrors bench.zig's Metrics).
class SceneMetrics {
  SceneMetrics(this.name);

  final String name;
  final List<double> frameTimesMs = <double>[]; // measured frames only
  double ttffMs = 0;
  int drawCallsPerFrame = 0;
  double rssMb = 0;
  int framesRendered = kTotalFrames;

  double get frameTimeAvgMs {
    if (frameTimesMs.isEmpty) return 0;
    var sum = 0.0;
    for (final double t in frameTimesMs) {
      sum += t;
    }
    return sum / frameTimesMs.length;
  }

  double get fps => frameTimeAvgMs > 0 ? 1000.0 / frameTimeAvgMs : 0;

  /// Nearest-rank percentile (bench.zig's percentile: idx = min(n*p/100, n-1)).
  double percentile(int p) {
    if (frameTimesMs.isEmpty) return 0;
    final List<double> sorted = List<double>.of(frameTimesMs)..sort();
    final int idx = math.min((sorted.length * p) ~/ 100, sorted.length - 1);
    return sorted[idx];
  }
}

/// The benchmark app: renders the active scene in a fixed 640x480 box and
/// drives 610 frames per scene from a Ticker (one frame per tick).
class BenchHarness extends StatefulWidget {
  const BenchHarness({super.key, required this.scenes, required this.onAllDone});

  final List<BenchScene> scenes;
  final void Function(List<SceneMetrics> results) onAllDone;

  @override
  State<BenchHarness> createState() => BenchHarnessState();
}

class BenchHarnessState extends State<BenchHarness>
    with SingleTickerProviderStateMixin {
  final GlobalKey _sceneKey = GlobalKey();
  final List<SceneMetrics> _results = <SceneMetrics>[];
  late final Ticker _ticker;
  Timer? _watchdog;
  int _sceneIndex = 0;
  int _tickCount = 0; // ticker ticks since scene activation (drives tick)
  int _framesCompleted = 0; // FrameTimings received since scene activation
  bool _collecting = false;
  bool _finished = false;
  DateTime _sceneStart = DateTime.now();
  DateTime _lastProgress = DateTime.now();
  SceneMetrics? _current;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _ticker = createTicker(_onTick);
    _activateScene(0);
    _ticker.start();
    _watchdog = Timer.periodic(const Duration(seconds: 15), _onWatchdog);
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _ticker.dispose();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  /// Called by scenes that need the widget tree rebuilt after a tick.
  void refresh() {
    if (mounted) setState(() {});
  }

  void _activateScene(int i) {
    _sceneIndex = i;
    _tickCount = 0;
    _framesCompleted = 0;
    _current = SceneMetrics(widget.scenes[i].name);
    _sceneStart = DateTime.now();
    _collecting = true;
    stderr.writeln('klaxon bench (flutter): ${widget.scenes[i].name} '
        '(${i + 1}/${widget.scenes.length})...');
  }

  void _onTick(Duration elapsed) {
    if (_finished || !_collecting) return;
    try {
      widget.scenes[_sceneIndex].tick(_tickCount, this);
    } catch (e, st) {
      // Fail fast: an exception in a ticker callback stops the ticker, which
      // would otherwise hang the run until the watchdog fires.
      stderr.writeln('klaxon bench (flutter): scene '
          '${widget.scenes[_sceneIndex].name} tick($_tickCount) threw: $e\n$st');
      exit(1);
    }
    _tickCount++;
    // Klaxon paints the whole tree every frame; without this, Flutter skips
    // paint (and raster) entirely for unchanged trees and static scenes would
    // measure ~0 work.
    final RenderObject? ro = _sceneKey.currentContext?.findRenderObject();
    ro?.markNeedsPaint();
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      if (_finished) return;
      if (!_collecting || _current == null) continue;
      _lastProgress = DateTime.now();
      // Frame work = build + raster. Flutter 3.47's FrameTiming has no
      // separate layout phase — the engine folds layout into buildDuration
      // (FramePhase: vsyncStart/buildStart/buildFinish/rasterStart/
      // rasterFinish) — so build + raster is Flutter's analog of Klaxon's
      // tick + layout + paint. In release builds the engine batches
      // FrameTimings (~1 Hz); each batch still carries one FrameTiming per
      // presented frame.
      final double workMs =
          (t.buildDuration + t.rasterDuration).inMicroseconds / 1000.0;
      final int completed = _framesCompleted;
      if (completed == 0) {
        _current!.ttffMs =
            _lastProgress.difference(_sceneStart).inMicroseconds / 1000.0;
      }
      if (completed >= kWarmupFrames) _current!.frameTimesMs.add(workMs);
      _framesCompleted++;
      if (_framesCompleted >= kTotalFrames) {
        _finishScene();
        return;
      }
    }
  }

  void _finishScene() {
    final BenchScene scene = widget.scenes[_sceneIndex];
    final SceneMetrics m = _current!;
    m.drawCallsPerFrame = _countSceneRenderObjects();
    m.rssMb = ProcessInfo.currentRss / 1e6;
    stderr.writeln('klaxon bench (flutter): ${scene.name} done — '
        'fps ${m.fps.toStringAsFixed(1)}, '
        'avg ${m.frameTimeAvgMs.toStringAsFixed(2)} ms, '
        'draw_calls ${m.drawCallsPerFrame}');
    _results.add(m);
    scene.dispose();
    _collecting = false;
    if (_sceneIndex + 1 < widget.scenes.length) {
      setState(() => _activateScene(_sceneIndex + 1));
    } else {
      _finished = true;
      _ticker.stop();
      widget.onAllDone(_results);
    }
  }

  /// draw_calls_per_frame: the number of RenderObjects under the scene root
  /// (Klaxon counts visible painted nodes; Flutter's retained render tree is
  /// the analog — virtualized lists only keep their live window attached).
  int _countSceneRenderObjects() {
    final BuildContext? ctx = _sceneKey.currentContext;
    final RenderObject? ro = ctx?.findRenderObject();
    if (ro == null) return 0;
    var count = 0;
    void visit(RenderObject node) {
      count++;
      node.visitChildren(visit);
    }

    visit(ro);
    return count;
  }

  void _onWatchdog(Timer timer) {
    if (_finished) {
      timer.cancel();
      return;
    }
    final int stale = DateTime.now().difference(_lastProgress).inSeconds;
    if (stale > 60) {
      stderr.writeln('klaxon bench (flutter): no frame timings for ${stale}s — '
          'aborting (is a display/window server attached?)');
      exit(2);
    }
  }

  @override
  Widget build(BuildContext context) {
    final BenchScene scene = widget.scenes[_sceneIndex];
    // Minimal chrome (no MaterialApp/Navigator): Localizations + Theme +
    // Material are what TextField & friends need; everything else would just
    // add per-frame paint work that Klaxon does not have.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Localizations(
        locale: const Locale('en'),
        delegates: const <LocalizationsDelegate<dynamic>>[
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        child: Theme(
          data: ThemeData.dark(useMaterial3: true),
          child: Material(
            color: kBenchBackground,
            // Overlay ancestor: Slider (gallery scene) builds an OverlayPortal
            // for its value indicator and requires one. Minimal chrome — a
            // bare Overlay, no Navigator/MaterialApp.
            child: Overlay.wrap(
              child: Center(
                child: SizedBox(
                  width: kViewportWidth,
                  height: kViewportHeight,
                  child: RepaintBoundary(
                    child: KeyedSubtree(
                      key: _sceneKey,
                      child: scene.build(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
