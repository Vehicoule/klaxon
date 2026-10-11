// Scene: overdraw_stack — 24 full-screen translucent rects (stress family).
// bench-scenes.md Family C: 24 full-screen rects, each alpha=0x1F over the
// last, alternating #7C4DFF / #03DAC6 — forces saveLayer/compositing cost;
// static (the cost is in paint, not anim).
//
// Gap (documented in README): Klaxon pushes an explicit saveLayer per rect.
// Flutter has no public saveLayer primitive for this — a translucent fill is
// alpha-blended inline by Impeller, so the measured cost is 24 full-screen
// blends (the same overdraw intent) without per-rect layer allocation.

import 'package:flutter/material.dart';

import '../harness.dart';

class OverdrawStackScene extends BenchScene {
  OverdrawStackScene() : super('overdraw_stack');

  static const int kRects = 24;
  static const double kAlpha = 0x1F / 0xFF;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (int i = 0; i < kRects; i++)
          Container(
            color: (i.isEven ? kBenchPurple : kBenchTeal)
                .withValues(alpha: kAlpha),
          ),
      ],
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {}
}
