// Scene: shapes_ramp — N rounded rects on a Lissajous path (ramp family).
// bench-scenes.md Family B: N = 10..3200 rounded rects (r=8dp, 40x24,
// alternating #7C4DFF / #03DAC6), each translating ~4 px/frame on a
// Lissajous path. Flutter idiom: one CustomPainter drawing all N (the draw
// workload scales with N; the widget tree stays constant).

import 'package:flutter/material.dart';

import '../harness.dart';
import 'ramp_base.dart';

class ShapesRampScene extends RampScene {
  ShapesRampScene() : super('shapes_ramp');

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(kViewportWidth, kViewportHeight),
      painter: _ShapesPainter(this),
    );
  }
}

class _ShapesPainter extends CustomPainter {
  _ShapesPainter(this.scene);

  final ShapesRampScene scene;
  final Paint _fill = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final int n = scene.itemCount;
    final int frame = scene.frame;
    for (int i = 0; i < n; i++) {
      final Offset p = rampLissajous(i, frame);
      _fill.color =
          i.isEven ? kBenchPurple : kBenchTeal;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: p, width: 40, height: 24),
          const Radius.circular(8),
        ),
        _fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ShapesPainter oldDelegate) => true;
}
