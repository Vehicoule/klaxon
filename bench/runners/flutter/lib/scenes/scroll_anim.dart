// Scene: scroll_anim — scroll_10k list scrolling at 600 dp/s while 30
// embedded row icons pulse opacity (stress family).
// bench-scenes.md Family C: scroll_10k list scrolling at 600 dp/s WHILE 30
// embedded row icons pulse opacity — mixed scroll+anim jank.
//
// Same list as scroll_10k (10 000 items, 36 dp rows, ~1 row of cache).
// 600 dp/s at the 60 Hz vsync pace = 10 px/frame; rows 0, 334, 668, ...
// (i % 334 == 0 -> exactly 30 rows) carry a star icon whose opacity pulses
// on a shared per-frame notifier, so the icons repaint independently of the
// scroll position.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../harness.dart';

class ScrollAnimScene extends BenchScene {
  ScrollAnimScene() : super('scroll_anim');

  static const int itemCount = 10000;
  static const double itemExtent = 36;

  /// 600 dp/s / 60 fps = 10 px/frame.
  static const double kDpPerFrame = 600 / 60;

  final ScrollController _controller = ScrollController();
  final ValueNotifier<int> _notifier = ValueNotifier<int>(0);

  /// The 30 designated pulsing rows (index 0, 334, ..., 9646).
  static bool pulses(int index) => index % 334 == 0 && index < 10000;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _controller,
      itemCount: itemCount,
      itemExtent: itemExtent,
      scrollCacheExtent: const ScrollCacheExtent.pixels(itemExtent),
      itemBuilder: (BuildContext context, int index) =>
          _scrollAnimRow(index, _notifier),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    _notifier.value = frame;
    if (!_controller.hasClients) return;
    final ScrollPosition position = _controller.position;
    if (!position.hasContentDimensions) return;
    final double max = position.maxScrollExtent;
    final double off = (frame * kDpPerFrame) % (max + 1.0);
    if (position.pixels != off) position.jumpTo(off);
  }

  @override
  void dispose() {
    _controller.dispose();
    _notifier.dispose();
    super.dispose();
  }
}

/// Same row shape as scroll_10k's benchListRow; designated rows' star icon
/// pulses opacity (0.2..1.0) with a per-row phase.
Widget _scrollAnimRow(int index, ValueNotifier<int> notifier) {
  final Widget icon = ScrollAnimScene.pulses(index)
      ? AnimatedBuilder(
          animation: notifier,
          builder: (BuildContext context, Widget? child) {
            final double t =
                0.5 + 0.5 * math.sin(notifier.value * 0.15 + index * 0.6);
            return Icon(Icons.star,
                size: 14,
                color: const Color(0xFFFFD54F)
                    .withValues(alpha: 0.2 + 0.8 * t));
          },
        )
      : const Icon(Icons.star, size: 14, color: Color(0xFFFFD54F));
  return Container(
    padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
    decoration: BoxDecoration(
      color: kBenchCardColor,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        icon,
        const SizedBox(width: 8),
        Text('Item #$index', style: kBenchBodyStyle),
      ],
    ),
  );
}
