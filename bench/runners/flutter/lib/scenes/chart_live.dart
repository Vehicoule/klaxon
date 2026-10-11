// Scene: chart_live — a live line chart (stress family).
// bench-scenes.md Family C: line chart, 1000 points, polyline rebuilt fully
// every frame + axes/grid (10x8) — the real dashboard case.
//
// A CustomPainter draws the 10x8 grid + the left/bottom axes + a 1000-point
// polyline rebuilt from scratch every paint (deterministic in the frame
// index: two superimposed sine components drifting with frame). Axes are
// axis/grid lines only — no tick labels (documented).

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../harness.dart';

class ChartLiveScene extends BenchScene {
  ChartLiveScene() : super('chart_live');

  int _frame = 0;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(kViewportWidth, kViewportHeight),
      painter: _ChartPainter(this),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    _frame = frame;
  }

  int get frame => _frame;
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.scene);

  final ChartLiveScene scene;

  /// The plot area (inset from the scene edge).
  static const Rect _plot = Rect.fromLTRB(40, 16, 628, 464);
  static const int kPoints = 1000;
  static const int kGridCols = 10;
  static const int kGridRows = 8;

  final Paint _grid = Paint()
    ..color = const Color(0xFF2A2A3E)
    ..strokeWidth = 1;
  final Paint _axis = Paint()
    ..color = const Color(0xFFCCCCCC)
    ..strokeWidth = 1;
  final Paint _line = Paint()
    ..color = kBenchTeal
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas canvas, Size size) {
    // Grid: 10 columns x 8 rows.
    for (int i = 0; i <= kGridCols; i++) {
      final double x = _plot.left + _plot.width * i / kGridCols;
      canvas.drawLine(Offset(x, _plot.top), Offset(x, _plot.bottom), _grid);
    }
    for (int j = 0; j <= kGridRows; j++) {
      final double y = _plot.top + _plot.height * j / kGridRows;
      canvas.drawLine(Offset(_plot.left, y), Offset(_plot.right, y), _grid);
    }
    // Axes: left + bottom.
    canvas.drawLine(_plot.bottomLeft, _plot.topLeft, _axis);
    canvas.drawLine(_plot.bottomLeft, _plot.bottomRight, _axis);

    // The polyline: 1000 points, fully rebuilt every frame.
    final int f = scene.frame;
    final Path path = Path();
    for (int i = 0; i < kPoints; i++) {
      final double x = _plot.left + _plot.width * i / (kPoints - 1);
      final double y = _plot.center.dy +
          _plot.height *
              (0.35 * math.sin(i * 0.05 + f * 0.2) +
                  0.12 * math.sin(i * 0.013 - f * 0.11));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, _line);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) => true;
}
