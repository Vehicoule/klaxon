// Scene: paths_ramp — N copies of a 12-point closed bezier path rotating
// 1 deg/frame (ramp family).
// bench-scenes.md Family B: N identical 12-point closed bezier paths
// (~200 pts of tessellation), rotating 1 deg/frame. The path is built once
// and reused; each frame re-rasterizes N filled copies under a rotation
// transform — the rasterizer's flattening of the 12 quadratic segments is
// the ~200-point tessellation the spec refers to.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../harness.dart';
import 'ramp_base.dart';

class PathsRampScene extends RampScene {
  PathsRampScene() : super('paths_ramp');

  /// The shared 12-point closed bezier path (~120 px across), built once.
  final Path path = _buildPath();

  /// A 12-lobed closed shape: 12 anchors on a 60 px radius joined by
  /// quadratic beziers bulging to 80 px between anchors.
  static Path _buildPath() {
    final Path p = Path();
    const int points = 12;
    for (int i = 0; i < points; i++) {
      final double a0 = i / points * 2 * math.pi;
      final double a1 = (i + 0.5) / points * 2 * math.pi;
      final double a2 = (i + 1) / points * 2 * math.pi;
      if (i == 0) p.moveTo(60 * math.cos(a0), 60 * math.sin(a0));
      p.quadraticBezierTo(80 * math.cos(a1), 80 * math.sin(a1),
          60 * math.cos(a2), 60 * math.sin(a2));
    }
    p.close();
    return p;
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(kViewportWidth, kViewportHeight),
      painter: _PathsPainter(this),
    );
  }
}

class _PathsPainter extends CustomPainter {
  _PathsPainter(this.scene);

  final PathsRampScene scene;
  final Paint _fill = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final int n = scene.itemCount;
    final double angle = scene.frame * math.pi / 180; // 1 deg/frame
    for (int i = 0; i < n; i++) {
      // Deterministic scatter: coprime strides cover the viewport for any N.
      final double x = (i * 157) % 560 + 40;
      final double y = (i * 109) % 400 + 40;
      _fill.color = i.isEven ? kBenchPurple : kBenchTeal;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(angle);
      canvas.drawPath(scene.path, _fill);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _PathsPainter oldDelegate) => true;
}
