// Shared base for the ramp family (bench-scenes.md Family B — the
// MotionMark "how much until it breaks" methodology, headless adaptation).
//
// Spec contract:
//   - stepped ramp, steps N = 10, 25, 50, 100, 200, 400, 800, 1600, 3200;
//   - 20 measured frames per step, same warmup contract per step
//     (10 warmup + 20 measured = 30 frames per step, 270 total);
//   - per-step frame_time_p50 in extra.ramp[] and extra.n_max_60fps =
//     the largest step with p50 <= 16.67 ms.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../harness.dart';

/// Shared deterministic Lissajous path for the ramp family (spec: items
/// translate ~4 px/frame on a Lissajous path). Centered on the 640x480
/// viewport: x = 320 + 280*sin(3θ + i*0.7), y = 240 + 200*sin(2θ); the path
/// derivative is bounded by ~930 px/rad, so θ' = 4/930 advances ≈4 px of arc
/// per frame; each item carries a golden-ratio phase offset.
Offset rampLissajous(int i, int frame) {
  const double kThetaPerFrame = 4.0 / 930.0;
  final double th = frame * kThetaPerFrame + i * 2.399963229728653;
  return Offset(
    320 + 280 * math.sin(3 * th + i * 0.7),
    240 + 200 * math.sin(2 * th),
  );
}

/// Base class for the four ramp scenes: drives the 9-step ramp, buckets the
/// measured frame times per step, and reports extra.ramp + extra.n_max_60fps.
abstract class RampScene extends BenchScene {
  RampScene(super.name);

  /// Spec steps.
  static const List<int> kSteps = <int>[
    10, 25, 50, 100, 200, 400, 800, 1600, 3200
  ];
  static const int kStepWarmup = kWarmupFrames; // 10 warmup per step
  static const int kStepMeasured = 20; // 20 measured per step
  static const int kStepFrames = kStepWarmup + kStepMeasured; // 30

  int _frame = 0;
  final List<List<double>> _stepTimes =
      <List<double>>[for (int i = 0; i < kSteps.length; i++) <double>[]];

  /// The current frame index (0-based, across all steps).
  int get frame => _frame;

  /// The current step index (0..8; clamped for the tail frames the ticker
  /// runs while the final timing batch is delivered).
  int get stepIndex =>
      math.min(_frame ~/ kStepFrames, kSteps.length - 1);

  /// N for the current step.
  int get itemCount => kSteps[stepIndex];

  @override
  int get totalFrames => kSteps.length * kStepFrames; // 270

  @override
  bool isMeasuredFrame(int frame) =>
      frame % kStepFrames >= kStepWarmup;

  @override
  void tick(int frame, BenchHarnessState harness) {
    _frame = frame;
  }

  @override
  void onMeasuredFrame(int frame, double frameMs) {
    _stepTimes[frame ~/ kStepFrames].add(frameMs);
  }

  static double _round2(double v) => (v * 100).round() / 100;

  @override
  Map<String, Object?> extra() {
    final List<Map<String, Object?>> ramp = <Map<String, Object?>>[];
    int nMax = 0;
    for (int i = 0; i < kSteps.length; i++) {
      final double p50 = percentileOf(_stepTimes[i], 50);
      ramp.add(<String, Object?>{'n': kSteps[i], 'p50_ms': _round2(p50)});
      if (p50 <= kJankBudgetMs && kSteps[i] > nMax) nMax = kSteps[i];
    }
    return <String, Object?>{'ramp': ramp, 'n_max_60fps': nMax};
  }
}
