// Scene: video_playback — a "video" widget regenerating its frame content
// every frame. Port of src/bench.zig buildVideoPlayback + videoPaint: a
// simulated 320x180 stream; every paint regenerates the frame's pixels (a
// moving r/g gradient field + a sliding 24px white bar, deterministic in the
// frame counter).
//
// Klaxon writes a fresh RGBA pixel buffer and uploads + draws + destroys a
// texture per frame. Dart has no synchronous texture-upload API (ui.Image
// creation is async), so the Flutter analog regenerates the frame content
// every paint as (a) the same CPU pixel buffer (Klaxon's exact formula,
// kept in VideoState-like scratch) and (b) a frame-dependent display list
// (gradient + scanlines + sliding bar) that the rasterizer re-rasterizes
// every frame. See README "known non-parities".

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../harness.dart';

class VideoPlaybackScene extends BenchScene {
  VideoPlaybackScene() : super('video_playback');

  static const int width = 320;
  static const int height = 180;

  int frame = 0;
  final Uint8List pixels = Uint8List(width * height * 4);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
              'video_playback — simulated 320×180 stream (frame regenerated every frame)',
              style: kBenchTitleStyle),
          const SizedBox(height: 12),
          SizedBox(
            width: width.toDouble(),
            height: height.toDouble(),
            child: CustomPaint(painter: _VideoPainter(this)),
          ),
        ],
      ),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    this.frame = frame;
  }
}

class _VideoPainter extends CustomPainter {
  _VideoPainter(this.scene);

  final VideoPlaybackScene scene;

  @override
  void paint(Canvas canvas, Size size) {
    final int frame = scene.frame;
    const int w = VideoPlaybackScene.width;
    const int h = VideoPlaybackScene.height;
    final int bar = (frame * 3) % w;

    // (a) Regenerate the frame's pixel buffer — bench.zig videoPaint's loop:
    // r = x*255/(w-1), g = y*255/(h-1), b = 0x60, a = 0xFF, with the sliding
    // 24px bar forced to white.
    final Uint8List px = scene.pixels;
    for (int y = 0; y < h; y++) {
      final int gy = (y * 255) ~/ (h - 1);
      int i = y * w * 4;
      for (int x = 0; x < w; x++) {
        final bool inBar = x >= bar && x < bar + 24;
        px[i] = inBar ? 0xFF : (x * 255) ~/ (w - 1);
        px[i + 1] = inBar ? 0xFF : gy;
        px[i + 2] = 0x60;
        px[i + 3] = 0xFF;
        i += 4;
      }
    }

    // (b) Regenerate the frame's display list (frame-dependent gradient +
    // scanlines + the sliding bar).
    final double t = (frame % 60) / 60.0;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(w.toDouble(), h.toDouble()),
          <Color>[
            Color.fromARGB(0x60, (255 * t).round(), 0, 0x60),
            Color.fromARGB(0x60, 255, (255 * t).round(), 0x60),
          ],
        ),
    );
    final Paint scanline = Paint()..color = const Color.fromARGB(0x10, 255, 255, 255);
    for (int y = 0; y < h; y += 4) {
      canvas.drawRect(Rect.fromLTWH(0, y.toDouble(), w.toDouble(), 1), scanline);
    }
    canvas.drawRect(
      Rect.fromLTWH(bar.toDouble(), 0, 24, h.toDouble()),
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _VideoPainter oldDelegate) => true;
}
