// Scene: scroll_10k — a virtualized list of 10 000 items.
// Port of src/bench.zig buildScrollList/benchListItem: a title, then a
// ListView.builder over 10 000 fixed-extent rows inside a bounded box. The
// tick auto-scrolls ~37px/frame, wrapping at maxScrollExtent + 1 (Klaxon's
// `off = frame * 37 mod (max_off + 1)`).

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../harness.dart';

/// One list row (bench.zig's benchListItem): a rounded card with a star icon
/// and an "Item #N" label.
Widget benchListRow(int index) {
  return Container(
    padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
    decoration: BoxDecoration(
      color: const Color(0xFF2A2A3E),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        const Icon(Icons.star, size: 14, color: Color(0xFFFFD54F)),
        const SizedBox(width: 8),
        Text('Item #$index', style: kBenchBodyStyle),
      ],
    ),
  );
}

class Scroll10kScene extends BenchScene {
  Scroll10kScene() : super('scroll_10k');

  static const int itemCount = 10000;
  static const double itemExtent = 36; // bench.zig item_height = 36
  final ScrollController _controller = ScrollController();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
              'scroll_10k — 10 000 items, virtualized (~10 live nodes)',
              style: kBenchTitleStyle),
          const SizedBox(height: 12),
          // The list needs a bounded viewport (Klaxon: ConstrainedBox 880x300).
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880, maxHeight: 300),
            child: ListView.builder(
              controller: _controller,
              itemCount: itemCount,
              itemExtent: itemExtent,
              // ~1 extra row of cache on each side: Klaxon keeps ~10 live
              // nodes; Flutter's default 250px cacheExtent would keep ~22.
              scrollCacheExtent: ScrollCacheExtent.pixels(itemExtent),
              itemBuilder: (BuildContext context, int index) =>
                  benchListRow(index),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    if (!_controller.hasClients) return;
    final ScrollPosition position = _controller.position;
    // The extents exist only after the viewport's first layout
    // (ScrollPosition.hasContentDimensions); the first tick can run before it.
    if (!position.hasContentDimensions) return;
    final double max = position.maxScrollExtent;
    final double off = (frame * 37.0) % (max + 1.0);
    if (position.pixels != off) position.jumpTo(off);
  }

  @override
  void dispose() {
    _controller.dispose();
  }
}
