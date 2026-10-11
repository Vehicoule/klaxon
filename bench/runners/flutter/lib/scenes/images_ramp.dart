// Scene: images_ramp — N copies of one 64x64 test image (ramp family).
// bench-scenes.md Family B: N copies of ONE 64x64 RGBA test image
// (checkerboard 8 px, generated at startup), each scaled 0.75x and moving.
// The image is decoded ONCE at scene init (startup cost excluded — this
// measures sampling/draw, not decode). Flutter idiom: ui.decodeImageFromPixels
// + a CustomPainter drawing N drawImageRect calls — the closest analog to
// "positioned image widgets" that keeps the draw workload scaling with N.
//
// Gap (documented in README): ui.Image decode is asynchronous in Dart; the
// scene requests it at construction and draws it as soon as it arrives
// (a 64x64 decode lands inside the first step's warmup, so no measured
// frame draws without the image).

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../harness.dart';
import 'ramp_base.dart';

class ImagesRampScene extends RampScene {
  ImagesRampScene() : super('images_ramp') {
    _decodeImage();
  }

  static const int kImageSize = 64;
  static const int kCheckerSize = 8;

  /// The shared test image (null until the async decode lands).
  ui.Image? image;

  /// 64x64 RGBA checkerboard, 8 px squares in the spec's accent colors.
  void _decodeImage() {
    final Uint8List px = Uint8List(kImageSize * kImageSize * 4);
    for (int y = 0; y < kImageSize; y++) {
      for (int x = 0; x < kImageSize; x++) {
        final bool a =
            ((x ~/ kCheckerSize) + (y ~/ kCheckerSize)).isEven;
        final int i = (y * kImageSize + x) * 4;
        px[i] = a ? 0x7C : 0x03;
        px[i + 1] = a ? 0x4D : 0xDA;
        px[i + 2] = a ? 0xFF : 0xC6;
        px[i + 3] = 0xFF;
      }
    }
    ui.decodeImageFromPixels(
      px,
      kImageSize,
      kImageSize,
      ui.PixelFormat.rgba8888,
      (ui.Image img) => image = img,
    );
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(kViewportWidth, kViewportHeight),
      painter: _ImagesPainter(this),
    );
  }

  @override
  void dispose() {
    image?.dispose();
    super.dispose();
  }
}

class _ImagesPainter extends CustomPainter {
  _ImagesPainter(this.scene);

  final ImagesRampScene scene;
  final Paint _paint = Paint();
  final Rect _src = const Rect.fromLTWH(0, 0, 64, 64);

  @override
  void paint(Canvas canvas, Size size) {
    final ui.Image? img = scene.image;
    if (img == null) return; // decode still in flight (first frames only)
    final int n = scene.itemCount;
    final int frame = scene.frame;
    for (int i = 0; i < n; i++) {
      final Offset p = rampLissajous(i, frame);
      // 0.75x scale (spec): 64 -> 48 px on a side.
      canvas.drawImageRect(
          img, _src, Rect.fromCenter(center: p, width: 48, height: 48), _paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ImagesPainter oldDelegate) => true;
}
