// Scene: glass_blur — glassmorphism cards with a backdrop blur over a
// colorful gradient backdrop. Port of src/bench.zig buildGlassBlur: a dark
// backdrop, three bright deco panels, and three 300x110 translucent glass
// cards (white / amber / mint tints) with frosted content bars, placed at
// center / top-right / bottom-left.
//
// Klaxon's raster backend has no blur primitive, so its glass card is a
// saveLayer + translucent tint (layerAlpha). Flutter has a real blur:
// BackdropFilter(ImageFilter.blur) — the closest analog, and considerably more
// raster work (see README "known non-parities").

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../harness.dart';

class GlassBlurScene extends BenchScene {
  GlassBlurScene() : super('glass_blur');

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF101426), // bench.zig backdrop 0x101426FF
      child: Stack(
        children: <Widget>[
          Column(
            children: <Widget>[
              _colorPanel(const Color(0xFFE91E63), 150),
              const SizedBox(height: 12),
              _colorPanel(const Color(0xFF3F51B5), 150),
              const SizedBox(height: 12),
              _colorPanel(const Color(0xFF00ACC1), 150),
            ],
          ),
          Align(
              alignment: Alignment.center,
              child: _glassCard(const Color(0xFFFFFFFF))),
          Align(
              alignment: Alignment.topRight,
              child: _glassCard(const Color(0xFFFFD54F))),
          Align(
              alignment: Alignment.bottomLeft,
              child: _glassCard(const Color(0xFF80FF87))),
        ],
      ),
    );
  }

  Widget _colorPanel(Color color, double height) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }

  /// The 300x110 glass card: blur + 0.45 tint + three frosted bars
  /// (bench.zig glassPaint: bars at y+12/24/36, heights 6, widths 1 / 0.62 /
  /// 0.4 of the content width, alphas 1.0 / 0xB3 / 0x80).
  Widget _glassCard(Color tint) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          width: 300,
          height: 110,
          padding: const EdgeInsets.all(12),
          color: tint.withValues(alpha: 0.45),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(height: 6, color: Colors.white),
              const SizedBox(height: 6),
              Container(
                  height: 6,
                  width: 276 * 0.62,
                  color: Colors.white.withValues(alpha: 0xB3 / 0xFF)),
              const SizedBox(height: 6),
              Container(
                  height: 6,
                  width: 276 * 0.40,
                  color: Colors.white.withValues(alpha: 0x80 / 0xFF)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {}
}
