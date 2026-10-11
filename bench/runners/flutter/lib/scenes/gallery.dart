// Scene: gallery — a representative multi-widget page.
//
// SIMPLIFICATION (documented in README): Klaxon's gallery scene renders the
// full showcase app (src/gallery.zig — every widget, dark theme, dialogs, a
// 10k list). This port is a representative page in the same spirit — header,
// stat cards, buttons/switch/checkbox/slider, and a short list — not a port
// of the whole gallery tree.

import 'package:flutter/material.dart';

import '../harness.dart';

class GalleryScene extends BenchScene {
  GalleryScene() : super('gallery');

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.dashboard, color: Colors.white),
              const SizedBox(width: 8),
              const Text('Klaxon Gallery — Flutter comparison',
                  style: kBenchTitleStyle),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              _statCard('610', 'Frames/run'),
              const SizedBox(width: 12),
              _statCard('9', 'Scenes'),
              const SizedBox(width: 12),
              _statCard('640x480', 'Viewport'),
            ],
          ),
          const SizedBox(height: 12),
          Text('Controls',
              style: TextStyle(
                  fontSize: 14,
                  color: Colors.white,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              FilledButton(onPressed: () {}, child: const Text('Save')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () {}, child: const Text('Cancel')),
              const SizedBox(width: 8),
              IconButton(
                  onPressed: () {}, icon: const Icon(Icons.favorite)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Switch(value: true, onChanged: (bool v) {}),
              Checkbox(value: true, onChanged: (bool? v) {}),
              const Expanded(child: Slider(value: 0.5, onChanged: null)),
            ],
          ),
          const SizedBox(height: 12),
          Text('Items',
              style: TextStyle(
                  fontSize: 14,
                  color: Colors.white,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (int i = 0; i < 3; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 8),
            _listRow(i),
          ],
        ],
      ),
    );
  }

  Widget _statCard(String value, String label) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(value,
              style: const TextStyle(fontSize: 18, color: Colors.white)),
          Text(label, style: kBenchTitleStyle),
        ],
      ),
    );
  }

  Widget _listRow(int i) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.star, size: 14, color: Color(0xFFFFD54F)),
          const SizedBox(width: 8),
          Expanded(child: Text('Gallery item $i', style: kBenchBodyStyle)),
          const Icon(Icons.chevron_right, color: Color(0xFFCCCCCC)),
        ],
      ),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {}
}
