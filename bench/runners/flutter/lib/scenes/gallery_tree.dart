// Shared "gallery-like" tree for the theme_switch and app_switch scenes
// (bench-scenes.md Family C/D): a representative multi-widget page of
// ~230 widgets — header, stat cards, controls, and 40 list rows — built from
// theme-driven Material widgets so a ThemeData swap repaints the whole
// subtree. Larger than the 480 viewport on purpose (the callers wrap it in a
// SingleChildScrollView — no virtualization, every node stays mounted).

import 'package:flutter/material.dart';

import '../harness.dart';

Widget benchGalleryTree({required bool dark}) {
  return Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.dashboard, size: 20),
            const SizedBox(width: 8),
            Text('Klaxon bench — gallery tree',
                style: kBenchTitleStyle.copyWith(
                    color: dark ? Colors.white : Colors.black87)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            _statCard('130', 'Frames'),
            const SizedBox(width: 8),
            _statCard('24', 'Scenes'),
            const SizedBox(width: 8),
            _statCard('640x480', 'Viewport'),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            FilledButton(onPressed: () {}, child: const Text('Save')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: () {}, child: const Text('Cancel')),
            IconButton(onPressed: () {}, icon: const Icon(Icons.favorite)),
            Switch(value: true, onChanged: (bool v) {}),
            Checkbox(value: true, onChanged: (bool? v) {}),
          ],
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < 40; i++) _listRow(i),
      ],
    ),
  );
}

Widget _statCard(String value, String label) {
  return Expanded(
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(value, style: const TextStyle(fontSize: 18)),
            Text(label, style: kBenchTitleStyle),
          ],
        ),
      ),
    ),
  );
}

Widget _listRow(int i) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: <Widget>[
            const Icon(Icons.star, size: 14),
            const SizedBox(width: 8),
            Expanded(child: Text('Gallery row $i', style: kBenchBodyStyle)),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    ),
  );
}
