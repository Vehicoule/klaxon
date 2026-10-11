// Harness for the Flutter comparison benchmark (roadmap Phase 4c.4,
// extended to the bench-scenes.md v2 catalogue).
//
// Replicates the Klaxon bench contract (src/bench.zig + docs/specs/
// bench-scenes.md):
//   - fixed 640x480 logical viewport,
//   - 10 warmup + 120 measured frames per scene (spec harness contract),
//     one frame per ticker tick; individual scenes may override the frame
//     plan (list_ops: 60 measured after the op; ramp: 9 x (10+20)),
//   - frame work = FrameTiming(build + raster) — layout is folded into
//     buildDuration in Flutter 3.47's FrameTiming; this is Flutter's analog
//     of Klaxon's tick + layout + paint,
//   - jank: a frame is jank if frame_ms > 16.67 (60 Hz budget,
//     Macrobenchmark/JankStats convention — spec schema v2),
//   - fps = 1000 / avg(frame work),
//   - draw_calls_per_frame = number of RenderObjects under the scene root
//     (Klaxon's "visible painted nodes"; ListView.builder virtualization keeps
//     this small for the scroll scenes),
//   - rss_mb = ProcessInfo.currentRss / 1e6,
//   - ttff_ms = scene start -> the scene's first completed frame (FrameTiming),
//   - frames_rendered = the scene's totalFrames (default 130),
//   - scene extras under extra{} (op_ms, ramp, latency_*, nodes_per_frame,
//     teardown_ms/resume_ms).
//
// The scene root is force-repainted (markNeedsPaint) every frame so that
// static scenes still measure a real paint + raster pass, matching Klaxon's
// renderer.paint(root, BG) on every frame.
//
// Wall-clock op timing: scenes that measure an operation's wall time
// (op_ms, input latency, teardown/resume) call beginWallOp(). It records the
// wall clock (DateTime.now().microsecondsSinceEpoch) and the current engine
// frame number (PlatformDispatcher.frameData.frameNumber), and completes
// when the FrameTiming carrying that frame (or a later waitFrames offset)
// arrives — the op's own render pass is inside that frame, so the elapsed
// wall time = mutate/build + one full render pass. FrameTiming delivery is
// batched in release builds, so completion is matched on
// FrameTiming.frameNumber + rasterFinishWallTime (a wall-clock timestamp on
// DateTime's epoch), not on arrival order.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// Run options (bench-scenes.md harness contract: 10 warmup + 120 measured).
const int kWarmupFrames = 10;
const int kMeasuredFrames = 120;
const int kTotalFrames = kWarmupFrames + kMeasuredFrames; // 130

/// The 60 Hz frame budget for the jank metric (spec: frame is jank if
/// frame_ms > 16.67).
const double kJankBudgetMs = 16.67;

/// The harness viewport (bench.zig: 640x480).
const double kViewportWidth = 640;
const double kViewportHeight = 480;

/// The surface background (bench.zig BG = 0x14141CFF).
const Color kBenchBackground = Color(0xFF14141C);

/// Shared text styles (bench.zig's title/body colors).
const TextStyle kBenchTitleStyle =
    TextStyle(fontSize: 14, color: Color(0xFFCCCCCC));
const TextStyle kBenchBodyStyle = TextStyle(fontSize: 14, color: Colors.white);

/// The spec's two accent colors (used across the new scenes).
const Color kBenchPurple = Color(0xFF7C4DFF);
const Color kBenchTeal = Color(0xFF03DAC6);

/// The suite card/panel color (bench.zig's container color).
const Color kBenchCardColor = Color(0xFF2A2A3E);

/// Nearest-rank percentile over a set of frame times (bench.zig's
/// percentile: idx = min(n*p/100, n-1)). 0 for an empty set.
double percentileOf(List<double> values, double p) {
  if (values.isEmpty) return 0;
  final List<double> sorted = List<double>.of(values)..sort();
  final int idx =
      math.min((sorted.length * p / 100).floor(), sorted.length - 1);
  return sorted[idx];
}

/// One canonical bench scene (the Flutter port of a bench-scenes.md scene).
abstract class BenchScene {
  BenchScene(this.name);

  final String name;

  /// The scene's widget tree, rebuilt from the scene's mutable state.
  Widget build(BuildContext context);

  /// Per-frame scene logic (Klaxon's SceneRunner.tick), driven once per
  /// rendered frame with the 0-based frame index (warmup frames included).
  void tick(int frame, BenchHarnessState harness);

  /// Total frames this scene renders (warmup + measured). Default: the
  /// spec contract, 10 + 120 = 130. list_ops scenes render 70 (the op is
  /// timed on the last warmup frame, then 60 frames are measured);
  /// ramp scenes render 270 (9 steps x (10 warmup + 20 measured)).
  int get totalFrames => kTotalFrames;

  /// Whether the 0-based frame index counts toward frame_times.
  /// Default: the 120 frames after the 10 warmup frames.
  bool isMeasuredFrame(int frame) => frame >= kWarmupFrames;

  /// Called once per measured frame, in order, with its frame-work ms —
  /// scenes that bucket timings per step (ramp) override this.
  void onMeasuredFrame(int frame, double frameMs) {}

  /// Optional async setup awaited BEFORE the scene's clock starts —
  /// counters (_tickCount, _framesCompleted, _sceneStart) only begin once
  /// this completes, so startup work (e.g. the images_ramp image decode)
  /// is excluded from ttff and every measured frame (spec: "decoded once
  /// at startup, startup cost excluded").
  Future<void> prepare() async {}

  /// Scene-specific metrics emitted under "extra" in the JSON report
  /// (missing values serialize as null).
  Map<String, Object?> extra() => const <String, Object?>{};

  /// Release scene-owned resources (controllers, focus nodes, ...).
  void dispose() {}
}

/// Collected metrics for one scene (mirrors bench.zig's Metrics + the
/// schema v2 additions: p99.9, jank, extra).
class SceneMetrics {
  SceneMetrics(this.name);

  final String name;
  final List<double> frameTimesMs = <double>[]; // measured frames only
  double ttffMs = 0;
  int drawCallsPerFrame = 0;
  double rssMb = 0;
  int framesRendered = kTotalFrames;
  Map<String, Object?> extra = const <String, Object?>{};

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
  double percentile(double p) => percentileOf(frameTimesMs, p);

  /// A frame is jank if its work exceeds the 60 Hz budget (16.67 ms).
  int get jankFrames {
    var count = 0;
    for (final double t in frameTimesMs) {
      if (t > kJankBudgetMs) count++;
    }
    return count;
  }

  double get jankPct =>
      frameTimesMs.isEmpty ? 0 : jankFrames * 100.0 / frameTimesMs.length;
}

/// A pending wall-clock op measurement. Completes when a FrameTiming arrives
/// whose frameNumber >= startFrame + waitFrames (frameNumber matching makes
/// this robust against the engine's ~1 Hz timing batching in release builds).
class _WallOp {
  _WallOp({
    required this.startWallUs,
    required this.startFrame,
    required this.waitFrames,
    required this.onDone,
  });

  final int startWallUs; // DateTime.now().microsecondsSinceEpoch
  final int startFrame; // PlatformDispatcher.frameData.frameNumber
  final int waitFrames;
  final void Function(double ms, int frames) onDone;
}

/// The benchmark app: renders the active scene in a fixed 640x480 box and
/// drives 130 frames per scene from a Ticker (one frame per tick).
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
  final List<_WallOp> _wallOps = <_WallOp>[];
  late final Ticker _ticker;
  Timer? _watchdog;
  Timer? _drainTimer; // forces scene finish if wall-op drain stalls
  int _sceneIndex = 0;
  int _tickCount = 0; // ticker ticks since scene activation (drives tick)
  int _framesCompleted = 0; // FrameTimings received since scene activation
  bool _collecting = false;
  bool _finished = false;
  DateTime _sceneStart = DateTime.now();
  DateTime _lastProgress = DateTime.now();
  SceneMetrics? _current;

  BenchScene get _scene => widget.scenes[_sceneIndex];

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
    _drainTimer?.cancel();
    _ticker.dispose();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  /// Called by scenes that need the widget tree rebuilt after a tick.
  void refresh() {
    if (mounted) setState(() {});
  }

  /// Begin a wall-clock op measurement (op_ms, input latency,
  /// teardown/resume). Records the wall clock now; completes on the
  /// FrameTiming whose frameNumber is the current frame's + [waitFrames]
  /// (0 = the frame currently being built — the op's own render pass; 1 =
  /// the next frame — e.g. an input event handled between frames whose
  /// response paints one frame later). [onDone] receives the elapsed wall
  /// ms and the number of frames elapsed.
  void beginWallOp({
    int waitFrames = 0,
    required void Function(double ms, int frames) onDone,
  }) {
    _wallOps.add(_WallOp(
      startWallUs: DateTime.now().microsecondsSinceEpoch,
      startFrame: ui.PlatformDispatcher.instance.frameData.frameNumber,
      waitFrames: waitFrames,
      onDone: onDone,
    ));
  }

  void _activateScene(int i) {
    _sceneIndex = i;
    _wallOps.clear();
    _drainTimer?.cancel();
    _drainTimer = null;
    stderr.writeln('klaxon bench (flutter): ${widget.scenes[i].name} '
        '(${i + 1}/${widget.scenes.length})...');
    unawaited(_startScene(i));
  }

  /// Awaits the scene's async setup, then starts its clock. Ticks and
  /// FrameTimings produced during prepare() are ignored (_collecting is
  /// still false), so scene startup costs stay out of every metric.
  Future<void> _startScene(int i) async {
    await widget.scenes[i].prepare();
    if (!mounted || _finished || _sceneIndex != i) return;
    _tickCount = 0;
    _framesCompleted = 0;
    _current = SceneMetrics(widget.scenes[i].name);
    _sceneStart = DateTime.now();
    _lastProgress = DateTime.now();
    _collecting = true;
    setState(() {});
  }

  void _onTick(Duration elapsed) {
    if (_finished || !_collecting) return;
    if (_tickCount >= _scene.totalFrames) {
      // The scene's frame plan is done; the ticker idles while in-flight
      // FrameTimings for already-produced frames drain (they may still
      // resolve pending wall-ops). No new ticks -> no new scene mutations.
      return;
    }
    try {
      _scene.tick(_tickCount, this);
    } catch (e, st) {
      // Fail fast: an exception in a ticker callback stops the ticker, which
      // would otherwise hang the run until the watchdog fires.
      stderr.writeln('klaxon bench (flutter): scene '
          '${_scene.name} tick($_tickCount) threw: $e\n$st');
      exit(1);
    }
    _tickCount++;
    // Klaxon paints the whole tree every frame; without this, Flutter skips
    // paint (and raster) entirely for unchanged trees and static scenes would
    // measure ~0 work.
    final RenderObject? ro = _sceneKey.currentContext?.findRenderObject();
    ro?.markNeedsPaint();
  }

  /// The scene's frame plan is fulfilled when the TICKER has run the full
  /// plan (all ticks executed) AND every produced frame has been counted.
  /// Gating on _framesCompleted alone truncated animated scenes: the engine
  /// produces >1 frame per tick there, so the frame counter could reach
  /// totalFrames while half the ticks (later ramp steps, app-switch
  /// transitions) had never run.
  bool get _planDone =>
      _tickCount >= _scene.totalFrames &&
      _framesCompleted >= _scene.totalFrames;

  void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      if (_finished) return;
      if (!_collecting || _current == null) continue;
      _lastProgress = DateTime.now();
      _resolveWallOps(t);
      if (_planDone) {
        // Frame plan done. Keep draining in-flight timings while wall-ops
        // are pending: the engine may run ahead of the ticker (animated
        // scenes produce >1 frame per tick), so an op's resolving frame was
        // already produced but its timing is still in the ~1 Hz batch
        // pipeline. A 2 s backstop finishes anyway if delivery stalls (or
        // the op's frame genuinely never rendered).
        if (_wallOps.isEmpty) {
          _finishScene();
          return;
        }
        _drainTimer ??= Timer(const Duration(seconds: 2), () {
          if (_collecting && !_finished) _finishScene();
        });
        continue;
      }
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
      // Frames past the plan (engine ran ahead of the ticker) count toward
      // completion but are not attributed — a completed-index beyond the
      // plan would overflow per-step buckets (ramp) or inflate the measured
      // set beyond 120 entries.
      if (completed < _scene.totalFrames &&
          _scene.isMeasuredFrame(completed)) {
        _current!.frameTimesMs.add(workMs);
        _scene.onMeasuredFrame(completed, workMs);
      }
      _framesCompleted++;
      if (_planDone && _wallOps.isEmpty) {
        _finishScene();
        return;
      }
      // Wall-ops still pending: the next timing enters the drain branch
      // above; a 2 s backstop timer finishes the scene regardless.
    }
  }

  void _resolveWallOps(FrameTiming t) {
    for (int i = _wallOps.length - 1; i >= 0; i--) {
      final _WallOp op = _wallOps[i];
      if (t.frameNumber >= op.startFrame + op.waitFrames) {
        _wallOps.removeAt(i);
        // rasterFinishWallTime is a wall-clock timestamp on DateTime's epoch
        // — wall time of the op's own render pass (mutate + build + raster).
        // Fallback (platforms that report 0): the frame's work time.
        final int rasterWallUs =
            t.timestampInMicroseconds(ui.FramePhase.rasterFinishWallTime);
        final double ms = rasterWallUs > op.startWallUs
            ? (rasterWallUs - op.startWallUs) / 1000.0
            : (t.buildDuration + t.rasterDuration).inMicroseconds / 1000.0;
        op.onDone(ms, t.frameNumber - op.startFrame);
      }
    }
  }

  void _finishScene() {
    _drainTimer?.cancel();
    _drainTimer = null;
    final SceneMetrics m = _current!;
    if (_wallOps.isNotEmpty) {
      // A wall-op whose completing frame never arrived (e.g. an injected
      // event that produced no frame) reports null — surface it loudly.
      stderr.writeln('klaxon bench (flutter): ${_scene.name}: '
          '${_wallOps.length} wall-op(s) left unresolved');
      _wallOps.clear();
    }
    m.drawCallsPerFrame = _countSceneRenderObjects();
    m.rssMb = ProcessInfo.currentRss / 1e6;
    m.framesRendered = _scene.totalFrames;
    m.extra = _scene.extra();
    stderr.writeln('klaxon bench (flutter): ${_scene.name} done — '
        'fps ${m.fps.toStringAsFixed(1)}, '
        'avg ${m.frameTimeAvgMs.toStringAsFixed(2)} ms, '
        'draw_calls ${m.drawCallsPerFrame}');
    _results.add(m);
    _scene.dispose();
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
                      child: _scene.build(context),
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
