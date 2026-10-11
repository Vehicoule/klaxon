// Scene: clip_path — 120 nodes clipped by a 6-point star (stress family).
// bench-scenes.md Family C: 120 nodes each clipped by a 6-point star path,
// contents scrolling under the clip.
//
// A 12x10 grid of ~53x48 cells; each cell is a ClipPath with a 6-point star
// clipper over a column of stripes that translates upward ~2 px/frame (the
// clip region is static in the cell's space — the contents scroll under it).
// Every frame re-rasterizes 120 star-clipped regions.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../harness.dart';

class ClipPathScene extends BenchScene {
  ClipPathScene() : super('clip_path');

  static const int kCols = 12;
  static const int kRows = 10;
  static const double kCellW = kViewportWidth / kCols; // ~53.3
  static const double kCellH = kViewportHeight / kRows; // 48

  final ValueNotifier<int> _notifier = ValueNotifier<int>(0);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int r = 0; r < kRows; r++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int c = 0; c < kCols; c++)
                _StarCell(index: r * kCols + c, notifier: _notifier),
            ],
          ),
      ],
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    _notifier.value++;
  }

  @override
  void dispose() {
    _notifier.dispose();
    super.dispose();
  }
}

class _StarCell extends StatelessWidget {
  const _StarCell({required this.index, required this.notifier});

  final int index;
  final ValueNotifier<int> notifier;

  /// The scrolling stripe period (5 stripes x 8 px = 40 px loop).
  static const double kPeriod = 40;

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: const _StarClipper(),
      child: SizedBox(
        width: ClipPathScene.kCellW,
        height: ClipPathScene.kCellH,
        child: AnimatedBuilder(
          animation: notifier,
          builder: (BuildContext context, Widget? child) {
            // Contents scroll under the clip: stripes translate up ~2
            // px/frame, wrapping each period.
            final double dy =
                -((notifier.value * 2.0 + index * 13.0) % kPeriod);
            return Transform.translate(
              offset: Offset(0, dy),
              child: child,
            );
          },
          child: Column(
            children: <Widget>[
              for (int s = 0; s < 12; s++)
                Container(
                  width: ClipPathScene.kCellW,
                  height: 8,
                  color: s.isEven
                      ? kBenchPurple.withValues(alpha: 0.75)
                      : kBenchCardColor,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A 6-point star path filling the cell (outer R, inner 0.45R, centered).
class _StarClipper extends CustomClipper<Path> {
  const _StarClipper();

  @override
  Path getClip(Size size) {
    final Path p = Path();
    final Offset c = size.center(Offset.zero);
    final double outer = math.min(size.width, size.height) / 2;
    final double inner = outer * 0.45;
    for (int i = 0; i < 12; i++) {
      final double a = i * math.pi / 6 - math.pi / 2;
      final double r = i.isEven ? outer : inner;
      final double x = c.dx + r * math.cos(a);
      final double y = c.dy + r * math.sin(a);
      if (i == 0) {
        p.moveTo(x, y);
      } else {
        p.lineTo(x, y);
      }
    }
    p.close();
    return p;
  }

  @override
  bool shouldReclip(covariant _StarClipper oldClipper) => false;
}
