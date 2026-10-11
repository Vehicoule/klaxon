// Scene: app_switch — pause->resume cycle every 60 frames (system family).
// bench-scenes.md Family D: pause->resume cycle every 60 frames: teardown
// cost extra.teardown_ms, resume-to-frame extra.resume_ms.
//
// Flutter has no way to inject a real OS lifecycle transition from Dart
// (AppLifecycleState is engine-driven), so the closest idiom is used: the
// pause is the scene's own teardown — the gallery-like subtree (~230 nodes)
// unmounts and a paused placeholder paints; the resume remounts the whole
// tree and measures wall time to the resumed frame's raster finish. A cycle
// = pause on frame k%60==0, resume on k%60==1 (2 cycles across the 120
// measured frames); extras are the mean across cycles.
//
//   teardown_ms = wall: teardown setState -> the torn-down frame's raster
//                 finish (unmount + dispose happen in that frame's build);
//   resume_ms   = wall: resume setState -> the resumed frame's raster
//                 finish (remount + layout + paint + raster of the tree).

import 'package:flutter/material.dart';

import '../harness.dart';
import 'gallery_tree.dart';

class AppSwitchScene extends BenchScene {
  AppSwitchScene() : super('app_switch');

  bool _paused = false;
  final List<double> _teardownMs = <double>[];
  final List<double> _resumeMs = <double>[];

  @override
  Widget build(BuildContext context) {
    if (_paused) {
      // The "switched away" surface the teardown frame renders.
      return const ColoredBox(
        color: Color(0xFF101018),
        child: Center(child: Text('paused', style: kBenchTitleStyle)),
      );
    }
    return SingleChildScrollView(child: benchGalleryTree(dark: true));
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    if (frame > 0 && frame % 60 == 0) {
      // pause -> tear the tree down.
      harness.beginWallOp(
          onDone: (double ms, int frames) => _teardownMs.add(ms));
      _paused = true;
      harness.refresh();
    } else if (frame % 60 == 1 && _paused) {
      // resume -> remount + measure resume-to-frame.
      harness.beginWallOp(
          onDone: (double ms, int frames) => _resumeMs.add(ms));
      _paused = false;
      harness.refresh();
    }
  }

  static double _mean(List<double> xs) {
    if (xs.isEmpty) return 0;
    var sum = 0.0;
    for (final double x in xs) {
      sum += x;
    }
    return sum / xs.length;
  }

  @override
  Map<String, Object?> extra() => <String, Object?>{
        'teardown_ms': _teardownMs.isEmpty ? null : _mean(_teardownMs),
        'resume_ms': _resumeMs.isEmpty ? null : _mean(_resumeMs),
      };
}
