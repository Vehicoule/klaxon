// The canonical scenes, in Klaxon's bench order: the 9 original scenes
// (src/bench.zig BenchScene) then the 24 bench-scenes.md v2 scenes by
// family (list_ops, ramp, stress, system).

import '../harness.dart';
import 'anim_100.dart';
import 'app_switch.dart';
import 'backdrop_scroll.dart';
import 'chart_live.dart';
import 'clip_path.dart';
import 'elevation_grid.dart';
import 'gallery.dart';
import 'glass_blur.dart';
import 'hello.dart';
import 'images_ramp.dart';
import 'input_ime.dart';
import 'input_latency.dart';
import 'list_clear_1k.dart';
import 'list_create_1k.dart';
import 'list_remove_row.dart';
import 'list_replace_1k.dart';
import 'list_swap_rows.dart';
import 'list_update_10th.dart';
import 'mount_churn.dart';
import 'overdraw_stack.dart';
import 'paths_ramp.dart';
import 'pointer_storm.dart';
import 'relayout_storm.dart';
import 'resize.dart';
import 'scroll_10k.dart';
import 'scroll_anim.dart';
import 'semantics_build.dart';
import 'shapes_ramp.dart';
import 'text_cjk.dart';
import 'text_ramp.dart';
import 'text_rich.dart';
import 'theme_switch.dart';
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
  // Family A — list_ops (krausest)
  'list_create_1k',
  'list_replace_1k',
  'list_update_10th',
  'list_swap_rows',
  'list_remove_row',
  'list_clear_1k',
  // Family B — ramp (MotionMark)
  'shapes_ramp',
  'paths_ramp',
  'text_ramp',
  'images_ramp',
  // Family C — stress
  'overdraw_stack',
  'elevation_grid',
  'relayout_storm',
  'mount_churn',
  'scroll_anim',
  'text_rich',
  'chart_live',
  'clip_path',
  'theme_switch',
  'backdrop_scroll',
  // Family D — system
  'input_latency',
  'pointer_storm',
  'semantics_build',
  'app_switch',
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
      'list_create_1k' => ListCreate1kScene(),
      'list_replace_1k' => ListReplace1kScene(),
      'list_update_10th' => ListUpdate10thScene(),
      'list_swap_rows' => ListSwapRowsScene(),
      'list_remove_row' => ListRemoveRowScene(),
      'list_clear_1k' => ListClear1kScene(),
      'shapes_ramp' => ShapesRampScene(),
      'paths_ramp' => PathsRampScene(),
      'text_ramp' => TextRampScene(),
      'images_ramp' => ImagesRampScene(),
      'overdraw_stack' => OverdrawStackScene(),
      'elevation_grid' => ElevationGridScene(),
      'relayout_storm' => RelayoutStormScene(),
      'mount_churn' => MountChurnScene(),
      'scroll_anim' => ScrollAnimScene(),
      'text_rich' => TextRichScene(),
      'chart_live' => ChartLiveScene(),
      'clip_path' => ClipPathScene(),
      'theme_switch' => ThemeSwitchScene(),
      'backdrop_scroll' => BackdropScrollScene(),
      'input_latency' => InputLatencyScene(),
      'pointer_storm' => PointerStormScene(),
      'semantics_build' => SemanticsBuildScene(),
      'app_switch' => AppSwitchScene(),
      _ => throw ArgumentError('unknown scene: $name'),
    };
