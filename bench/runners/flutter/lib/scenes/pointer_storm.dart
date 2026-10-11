// Scene: pointer_storm — 1000 hit-test queries/frame over a 500-node tree
// (system family).
// bench-scenes.md Family D: 1000 hit-test queries/frame over a 500-node
// tree (no paint change) — pure hit-test cost.
//
// The tree: a 50x10 grid of small bars = 500 leaf nodes (+ 50 rows + the
// column ≈ 551 render objects). Every frame, 1000 RenderBox.hitTest queries
// run over the scene subtree at deterministic positions (a fixed-seed RNG,
// so every frame probes the same 1000 points — hit tests are not cached).
//
// The queries run inside build() — the widget build phase is inside
// FrameTiming's buildDuration window, so the storm lands in the measured
// frame work regardless of where the engine timestamps the ticker phase.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../harness.dart';

class PointerStormScene extends BenchScene {
  PointerStormScene() : super('pointer_storm');

  static const int kQueries = 1000;
  static const int kCols = 10;
  static const int kRows = 50;

  final GlobalKey _probeKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    // 1000 hit-test queries over the previous frame's laid-out tree (the
    // scene's own subtree via _probeKey). Frame 0 has no tree yet — skipped.
    final RenderObject? ro = _probeKey.currentContext?.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      final math.Random rng = math.Random(0xBEC);
      for (int q = 0; q < kQueries; q++) {
        ro.hitTest(
          BoxHitTestResult(),
          position: Offset(
              rng.nextDouble() * kViewportWidth,
              rng.nextDouble() * kViewportHeight),
        );
      }
    }
    return _tree();
  }

  Widget _tree() {
    return KeyedSubtree(
      key: _probeKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int r = 0; r < kRows; r++)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (int c = 0; c < kCols; c++)
                  Container(
                    width: 58,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    color: (r + c).isEven ? kBenchCardColor : kBenchPurple,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    harness.refresh(); // run the storm inside this frame's build
  }
}
