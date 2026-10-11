// Scene: input_latency — synthetic pointer event -> frames until the visual
// response paints (system family).
// bench-scenes.md Family D: inject a synthetic pointer event -> frames until
// the visual response paints; extra.latency_frames, extra.latency_ms.
//
// Flutter idiom: a real pointer event is injected through the framework's
// own input path — GestureBinding.handlePointerEvent runs the engine's hit
// test + gesture dispatch, exactly what an OS event triggers. Real events
// arrive BETWEEN frames, so the injection happens in a post-frame callback
// after the last warmup frame; the tap-down handler setStates a visual
// response (target color flips) which paints in the next frame.
// extra.latency_frames = frames from injection to the response's frame;
// extra.latency_ms = wall time injection -> the response frame's raster
// finish (rasterFinishWallTime), so it includes frame pacing (~1 frame).

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../harness.dart';

class InputLatencyScene extends BenchScene {
  InputLatencyScene() : super('input_latency');

  static const int _injectFrame = kWarmupFrames - 1; // last warmup frame

  final GlobalKey _targetKey = GlobalKey();
  BenchHarnessState? _harness;
  bool _responded = false;
  double? _latencyMs;
  int? _latencyFrames;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTapDown: (_) {
          // The visual response: repaint the target in the accent color.
          _responded = true;
          _harness?.refresh();
        },
        child: Container(
          key: _targetKey,
          width: 160,
          height: 100,
          decoration: BoxDecoration(
            color: _responded ? kBenchTeal : kBenchCardColor,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Text(
            _responded ? 'responded' : 'tap target',
            style: kBenchBodyStyle,
          ),
        ),
      ),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    _harness = harness;
    if (frame == _injectFrame) {
      // Post-frame injection — between-frame delivery like a real OS event.
      WidgetsBinding.instance.addPostFrameCallback((_) => _inject());
    }
  }

  void _inject() {
    final RenderObject? ro = _targetKey.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return;
    final Offset center = ro.localToGlobal(ro.size.center(Offset.zero));
    // waitFrames: 1 — the event lands between frames; the response paints in
    // the NEXT frame.
    _harness?.beginWallOp(
      waitFrames: 1,
      onDone: (double ms, int frames) {
        _latencyMs = ms;
        _latencyFrames = frames;
      },
    );
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(position: center),
    );
  }

  @override
  Map<String, Object?> extra() => <String, Object?>{
        'latency_ms': _latencyMs,
        'latency_frames': _latencyFrames,
      };
}
