// Scene: text_ramp — N text instances oscillating horizontally (ramp family).
// bench-scenes.md Family B: N instances of "The quick brown fox 0123456789"
// at 14sp, horizontal offset oscillating. Flutter idiom: one CustomPainter
// painting a shared TextPainter N times (layout once, N glyph draws — the
// draw workload scales with N; N real Text widgets would measure widget
// build cost instead of the draw cost the ramp is for).

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../harness.dart';
import 'ramp_base.dart';

class TextRampScene extends RampScene {
  TextRampScene() : super('text_ramp');

  /// The shared laid-out text (spec: "The quick brown fox 0123456789", 14sp).
  final TextPainter textPainter = TextPainter(
    text: const TextSpan(
      text: 'The quick brown fox 0123456789',
      style: TextStyle(fontSize: 14, color: Colors.white),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(kViewportWidth, kViewportHeight),
      painter: _TextPainter(this),
    );
  }
}

class _TextPainter extends CustomPainter {
  _TextPainter(this.scene);

  final TextRampScene scene;

  @override
  void paint(Canvas canvas, Size size) {
    final int n = scene.itemCount;
    final int frame = scene.frame;
    for (int i = 0; i < n; i++) {
      // Deterministic scatter + horizontal oscillation.
      final double x = (i * 137) % 540 + 10;
      final double y = (i * 29) % 460 + 8;
      final double dx = 28 * math.sin(frame * 0.08 + i * 0.55);
      scene.textPainter.paint(canvas, Offset(x + dx, y));
    }
  }

  @override
  bool shouldRepaint(covariant _TextPainter oldDelegate) => true;
}
