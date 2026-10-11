// Scene: anim_100 — 100 widgets with concurrent per-frame animations.
// Port of src/bench.zig buildAnim100: a 10x10 grid of widgets whose height
// (24 + 16*sin(phase)) and color (indigo -> pink lerp) retarget every frame
// with a per-widget phase offset (frame*0.06 + i*0.17).
//
// Klaxon animates 100 spring signals toward moving targets; the Flutter port
// follows the 4c.4 runner spec: 100 AnimatedBuilder widgets listening to one
// per-frame notifier, each computing its phase from the frame index. The grid
// is a Column of Rows (deterministic 10-per-row; a GridView would either
// virtualize or clamp the animated heights to the cell size).

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../harness.dart';

class Anim100Scene extends BenchScene {
  Anim100Scene() : super('anim_100');

  static const int widgetCount = 100;
  final ValueNotifier<int> _notifier = ValueNotifier<int>(0);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int r = 0; r < 10; r++)
            Padding(
              padding: EdgeInsets.only(bottom: r == 9 ? 0 : 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (int c = 0; c < 10; c++) ...<Widget>[
                    if (c > 0) const SizedBox(width: 8),
                    _AnimCell(index: r * 10 + c, notifier: _notifier),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    // Retarget every widget (phase-offset per widget); the 100
    // AnimatedBuilders rebuild from the notifier.
    _notifier.value++;
  }

  @override
  void dispose() {
    _notifier.dispose();
  }
}

class _AnimCell extends StatelessWidget {
  const _AnimCell({required this.index, required this.notifier});

  final int index;
  final ValueNotifier<int> notifier;

  /// Cell width: (640 - 2*16 padding - 9*8 gaps) / 10 columns.
  static const double cellWidth = (640 - 32 - 9 * 8) / 10;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: notifier,
      builder: (BuildContext context, Widget? child) {
        final double phase = notifier.value * 0.06 + index * 0.17;
        final double height = 24 + 16 * math.sin(phase);
        final double t = (math.sin(phase) + 1) / 2;
        return Container(
          width: cellWidth,
          height: height,
          decoration: BoxDecoration(
            color: Color.lerp(
                const Color(0xFF3F51B5), const Color(0xFFE91E63), t),
            borderRadius: BorderRadius.circular(8),
          ),
        );
      },
    );
  }
}
