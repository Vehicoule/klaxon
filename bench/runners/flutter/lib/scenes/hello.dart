// Scene: hello — a static hero UI (title, subtitle, button, card).
// Klaxon's src/bench.zig buildHello is a centered text; the Flutter port
// follows the 4c.4 runner spec (Column of Text + FilledButton + Card).

import 'package:flutter/material.dart';

import '../harness.dart';

class HelloScene extends BenchScene {
  HelloScene() : super('hello');

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text('Hello, Klaxon!',
              style: TextStyle(fontSize: 24, color: Colors.white)),
          const SizedBox(height: 8),
          const Text('The Flutter comparison runner — hello scene',
              style: kBenchTitleStyle),
          const SizedBox(height: 16),
          FilledButton(onPressed: () {}, child: const Text('Get started')),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('A card', style: kBenchBodyStyle),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {}
}
