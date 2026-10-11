// Scene: theme_switch — full gallery-like tree, light/dark flip every 30
// frames (stress family).
// bench-scenes.md Family C: full gallery-like tree (200+ nodes), alternate
// light/dark theme every 30 frames — global invalidation cost.
//
// The tree is the shared benchGalleryTree (~230 Material widgets — header,
// stat cards, controls, 40 list rows). Flutter idiom: swapping
// ThemeData.light()/.dark() on the enclosing Theme invalidates every
// descendant that resolves Theme.of(context) — the global-invalidation
// analog.

import 'package:flutter/material.dart';

import '../harness.dart';
import 'gallery_tree.dart';

class ThemeSwitchScene extends BenchScene {
  ThemeSwitchScene() : super('theme_switch');

  bool _dark = false;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _dark ? ThemeData.dark(useMaterial3: true)
          : ThemeData.light(useMaterial3: true),
      child: ColoredBox(
        // The theme's surface color makes the flip visible over the harness
        // background without adding a full Scaffold.
        color: _dark ? const Color(0xFF1C1B1F) : const Color(0xFFFFFBFE),
        child: SingleChildScrollView(
          child: benchGalleryTree(dark: _dark),
        ),
      ),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    // Alternate light/dark every 30 frames (spec).
    if (frame > 0 && frame % 30 == 0) {
      _dark = !_dark;
      harness.refresh();
    }
  }
}
