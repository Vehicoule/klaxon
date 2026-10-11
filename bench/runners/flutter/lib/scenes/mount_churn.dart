// Scene: mount_churn — destroy 50 widgets + create 50 new every frame
// (stress family).
// bench-scenes.md Family C: every frame destroy 50 widgets and create 50 new
// ones (label+icon card, new id), steady-state pool 500 — the GC/allocator
// pressure test.
//
// Flutter idiom: a keyed widget pool — removing the 50 oldest ids and
// appending 50 fresh ids (monotonic counter = always-new key identity,
// the deterministic equivalent of the spec's "random id") makes the element
// tree unmount 50 and mount 50 every frame. The 500-card pool lives in a
// Wrap inside a SingleChildScrollView so every card stays mounted
// (a ListView would virtualize the pool away).

import 'package:flutter/material.dart';

import '../harness.dart';

class MountChurnScene extends BenchScene {
  MountChurnScene() : super('mount_churn');

  static const int kPoolSize = 500;
  static const int kChurn = 50;

  final List<int> _ids = <int>[for (int i = 0; i < kPoolSize; i++) i];
  int _nextId = kPoolSize;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Wrap(
        children: <Widget>[
          for (final int id in _ids) _ChurnCard(key: ValueKey<int>(id), id: id),
        ],
      ),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    _ids.removeRange(0, kChurn); // destroy the 50 oldest
    for (int i = 0; i < kChurn; i++) {
      _ids.add(_nextId++); // create 50 new
    }
    harness.refresh();
  }
}

/// A small label+icon card (spec).
class _ChurnCard extends StatelessWidget {
  const _ChurnCard({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(2),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: kBenchCardColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.circle, size: 8, color: kBenchPurple),
          const SizedBox(width: 3),
          Text('item $id',
              style: const TextStyle(fontSize: 8, color: Colors.white)),
        ],
      ),
    );
  }
}
