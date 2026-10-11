// Scene: resize — the viewport cycles through several sizes, relayout every
// frame. Port of src/bench.zig buildResize + the tick's kx_resize cycle:
// RESIZE_SIZES = [640x480, 480x320, 320x240, 800x600, 240x400, 960x640],
// one size per frame index.
//
// Flutter cannot recreate the render surface per frame from Dart, so the
// resize is simulated: an AnimatedContainer inside the fixed 640x480 harness
// box cycles its constraints every frame, forcing a full relayout of the
// tree (title + 3 cards + a 2000-item virtualized list). Sizes above 640x480
// clamp to the window (documented non-parity — Klaxon resizes the surface).

import 'package:flutter/material.dart';

import '../harness.dart';
import 'scroll_10k.dart' show benchListRow;

class ResizeScene extends BenchScene {
  ResizeScene() : super('resize');

  /// bench.zig RESIZE_SIZES.
  static const List<Size> kSizes = <Size>[
    Size(640, 480),
    Size(480, 320),
    Size(320, 240),
    Size(800, 600),
    Size(240, 400),
    Size(960, 640),
  ];

  Size _size = kSizes.first;
  final ScrollController _controller = ScrollController();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AnimatedContainer(
        duration: Duration.zero,
        width: _size.width,
        height: _size.height,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                  'resize — the viewport cycles every frame (layout stress)',
                  style: kBenchTitleStyle),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  for (int i = 0; i < 3; i++) ...<Widget>[
                    if (i > 0) const SizedBox(width: 12),
                    _card(),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 880, maxHeight: 200),
                child: ListView.builder(
                  controller: _controller,
                  itemCount: 2000,
                  itemExtent: 32,
                  itemBuilder: (BuildContext context, int index) =>
                      benchListRow(index),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('Card', style: kBenchBodyStyle),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    _size = kSizes[frame % kSizes.length];
    harness.refresh();
  }

  @override
  void dispose() {
    _controller.dispose();
  }
}
