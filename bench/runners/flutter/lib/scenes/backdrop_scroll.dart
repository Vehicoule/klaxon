// Scene: backdrop_scroll — scrolling content under a fixed backdrop-blur
// band (stress family).
// bench-scenes.md Family C: scrolling content (200 items) under a fixed
// 640x160 backdrop-blur band (sigma=12) + 60% scrim — mobile's worst case.
//
// A ListView of 200 rows auto-scrolls (~4 px/frame, wrapping at the max
// extent — the spec fixes the blur band and item count, not the scroll
// rate); a centered 640x160 BackdropFilter(ImageFilter.blur(12)) with a 60%
// black scrim floats over it. The blurred band re-rasterizes every frame as
// the content scrolls under it.

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../harness.dart';
import 'scroll_10k.dart' show benchListRow;

class BackdropScrollScene extends BenchScene {
  BackdropScrollScene() : super('backdrop_scroll');

  static const int itemCount = 200;
  static const double itemExtent = 36;
  static const double kDpPerFrame = 4;

  final ScrollController _controller = ScrollController();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        ListView.builder(
          controller: _controller,
          itemCount: itemCount,
          itemExtent: itemExtent,
          itemBuilder: (BuildContext context, int index) =>
              benchListRow(index),
        ),
        // The fixed 640x160 backdrop-blur band, centered vertically, with
        // the 60% black scrim as the filter's child.
        Positioned(
          top: (kViewportHeight - 160) / 2,
          left: 0,
          right: 0,
          height: 160,
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(color: Colors.black.withValues(alpha: 0.6)),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    if (!_controller.hasClients) return;
    final ScrollPosition position = _controller.position;
    if (!position.hasContentDimensions) return;
    final double off = (frame * kDpPerFrame) % (position.maxScrollExtent + 1);
    if (position.pixels != off) position.jumpTo(off);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
