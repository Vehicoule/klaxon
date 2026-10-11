// Scene: relayout_storm — 200 rows animating width 200<->440 dp (stress).
// bench-scenes.md Family C: 200 rows each animating width 200<->440 dp
// (2 s loop) — forces per-frame measure+layout of the subtree (NOT a
// compositable transform).
//
// The rows are 2 dp bars so all 200 stay mounted inside the 480 px viewport
// (a scrollable/virtualized list would only layout the visible window — the
// storm requires all 200 to measure+layout every frame). 2 s at the 60 Hz
// vsync pace = a 120-frame loop; the width is a layout property, so every
// frame relayouts each row's RenderBox.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../harness.dart';

class RelayoutStormScene extends BenchScene {
  RelayoutStormScene() : super('relayout_storm');

  static const int kRows = 200;

  final ValueNotifier<int> _notifier = ValueNotifier<int>(0);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < kRows; i++)
          _StormRow(index: i, notifier: _notifier),
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

class _StormRow extends StatelessWidget {
  const _StormRow({required this.index, required this.notifier});

  final int index;
  final ValueNotifier<int> notifier;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: notifier,
      builder: (BuildContext context, Widget? child) {
        // 200 <-> 440 dp, 2 s loop (120 frames at 60 Hz), per-row phase.
        final double w = 320 +
            120 *
                math.sin(2 * math.pi * notifier.value / 120 + index * 0.15);
        return Container(
          width: w,
          height: 2,
          color: index.isEven ? kBenchPurple : kBenchTeal,
        );
      },
    );
  }
}
