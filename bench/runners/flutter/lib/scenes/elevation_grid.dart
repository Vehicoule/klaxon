// Scene: elevation_grid — 10x10 grid of shadowed cards (stress family).
// bench-scenes.md Family C: 10x10 grid of 48x40 cards, M3 elevation shadow
// (r=12, dy=2, blur=6, rgba(0,0,0,0.30)) — every shadow re-rasterized per
// frame while the card fill color oscillates +/-4% lightness.
//
// The grid is centered with 8 px gaps (10*48 + 9*8 = 552 x 10*40 + 9*8 =
// 472 — fits the 640x480 viewport). Fill base is the suite card color
// #2A2A3E (HSL lightness ~0.236) oscillating +/-0.04 per card with a
// per-card phase offset; shadows re-rasterize every frame because the fill
// changes.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../harness.dart';

class ElevationGridScene extends BenchScene {
  ElevationGridScene() : super('elevation_grid');

  static const int kGrid = 10;
  static const double kGap = 8;

  final ValueNotifier<int> _notifier = ValueNotifier<int>(0);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int r = 0; r < kGrid; r++)
            Padding(
              padding: EdgeInsets.only(bottom: r == kGrid - 1 ? 0 : kGap),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (int c = 0; c < kGrid; c++) ...<Widget>[
                    if (c > 0) const SizedBox(width: kGap),
                    _ShadowCard(
                        index: r * kGrid + c, notifier: _notifier),
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
    _notifier.value++;
  }

  @override
  void dispose() {
    _notifier.dispose();
    super.dispose();
  }
}

class _ShadowCard extends StatelessWidget {
  const _ShadowCard({required this.index, required this.notifier});

  final int index;
  final ValueNotifier<int> notifier;

  /// #2A2A3E in HSL: h=240, s=0.19, l=0.204.
  static const double kBaseLightness = 0.204;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: notifier,
      builder: (BuildContext context, Widget? child) {
        final double l = (kBaseLightness +
                0.04 * math.sin(notifier.value * 0.12 + index * 0.35))
            .clamp(0.0, 1.0);
        return Container(
          width: 48,
          height: 40,
          decoration: BoxDecoration(
            color: HSLColor.fromAHSL(1.0, 240, 0.19, l).toColor(),
            borderRadius: BorderRadius.circular(12),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x4D000000), // rgba(0,0,0,0.30)
                offset: Offset(0, 2), // dy = 2
                blurRadius: 6,
              ),
            ],
          ),
        );
      },
    );
  }
}
