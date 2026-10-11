// The 9 canonical scenes, in Klaxon's bench order (src/bench.zig BenchScene).

import '../harness.dart';
import 'anim_100.dart';
import 'gallery.dart';
import 'glass_blur.dart';
import 'hello.dart';
import 'input_ime.dart';
import 'resize.dart';
import 'scroll_10k.dart';
import 'text_cjk.dart';
import 'video_playback.dart';

const List<String> kSceneNames = <String>[
  'hello',
  'scroll_10k',
  'text_cjk',
  'glass_blur',
  'anim_100',
  'gallery',
  'resize',
  'input_ime',
  'video_playback',
];

BenchScene createScene(String name) => switch (name) {
      'hello' => HelloScene(),
      'scroll_10k' => Scroll10kScene(),
      'text_cjk' => TextCjkScene(),
      'glass_blur' => GlassBlurScene(),
      'anim_100' => Anim100Scene(),
      'gallery' => GalleryScene(),
      'resize' => ResizeScene(),
      'input_ime' => InputImeScene(),
      'video_playback' => VideoPlaybackScene(),
      _ => throw ArgumentError('unknown scene: $name'),
    };
