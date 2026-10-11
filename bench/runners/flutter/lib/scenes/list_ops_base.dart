// Shared base for the list_ops family (bench-scenes.md Family A — the
// krausest js-framework-benchmark operations, adapted to a native list).
//
// Spec contract:
//   - one shared row widget: 48 dp height, label "Row NNNN — klaxon bench"
//     left, a small 16x16 square filled #7C4DFF right,
//   - a scrollable column of plain rows in the 640x480 viewport
//     (Flutter idiom: ListView.builder + setState — virtualization stays ON,
//     it is the framework's idiom),
//   - the metric is extra.op_ms = wall time of the operation itself
//     (build/mutate + one full render pass); frame timing metrics are
//     collected over 60 frames after the op.
//
// Harness adaptation: the op runs inside the LAST warmup frame (index
// kWarmupFrames-1 = 9) — the wall-op timer spans the mutation + that frame's
// build/layout/paint/raster — and the 60 measured frames (10..69) are then
// exactly "60 frames after the op". Scenes that start populated render their
// full list for the 9 warmup frames before the op (the krausest setup: a
// fully rendered list, then the op).

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../harness.dart';

/// One row model (krausest's {id, label}).
class ListRowModel {
  ListRowModel(this.id, this.label);

  final int id;
  String label;
}

/// The shared row widget (spec): 48 dp tall, label left, 16x16 #7C4DFF
/// square right.
Widget listOpsRow(ListRowModel row) {
  return SizedBox(
    height: ListOpsScene.kRowExtent,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(row.label,
                style: kBenchBodyStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          Container(width: 16, height: 16, color: kBenchPurple),
        ],
      ),
    ),
  );
}

/// Base class for the six list_ops scenes: owns the row models, performs the
// op on the last warmup frame inside a wall-op timing, and reports op_ms.
abstract class ListOpsScene extends BenchScene {
  ListOpsScene(super.name, {required bool startPopulated}) {
    if (startPopulated) populate(kRowCount);
  }

  /// Spec constants: 1000 rows, 48 dp row height.
  static const int kRowCount = 1000;
  static const double kRowExtent = 48;

  /// The op runs on the last warmup frame; the measured window is then the
  /// 60 frames after the op (spec: "frame timing metrics collected over 60
  /// frames after the op").
  static const int _opFrame = kWarmupFrames - 1;
  static const int _measuredAfterOp = 60;

  /// The scene's row models — mutated by [performOp].
  @protected
  final List<ListRowModel> rows = <ListRowModel>[];

  int _nextId = 1;
  double? _opMs;

  @override
  int get totalFrames => kWarmupFrames + _measuredAfterOp; // 70

  /// A fresh model: sequential ids, "Row NNNN — klaxon bench" (NNNN zero
  /// padded; ids keep increasing across ops so replace produces new labels).
  @protected
  ListRowModel newRow() {
    final int id = _nextId++;
    return ListRowModel(
        id, 'Row ${id.toString().padLeft(4, '0')} — klaxon bench');
  }

  /// Append [count] fresh models.
  @protected
  void populate(int count) {
    for (int i = 0; i < count; i++) {
      rows.add(newRow());
    }
  }

  /// The scene's krausest operation (the model mutation being measured).
  @protected
  void performOp();

  @override
  void tick(int frame, BenchHarnessState harness) {
    if (frame == _opFrame) {
      // The op: wall time = mutation + this frame's build/layout/paint/raster
      // (beginWallOp records wall-now; the completing FrameTiming's
      // rasterFinishWallTime ends it).
      harness.beginWallOp(
          onDone: (double ms, int frames) => _opMs = ms);
      performOp();
      harness.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      // The empty state (spec: list_clear_1k "renders empty state";
      // list_create_1k starts here).
      return const Center(child: Text('No rows', style: kBenchTitleStyle));
    }
    return ListView.builder(
      itemCount: rows.length,
      itemExtent: kRowExtent,
      // Same convention as scroll_10k: ~1 row of cache so the live window
      // matches Klaxon's virtualized list.
      scrollCacheExtent: const ScrollCacheExtent.pixels(kRowExtent),
      itemBuilder: (BuildContext context, int index) => listOpsRow(rows[index]),
    );
  }

  @override
  Map<String, Object?> extra() => <String, Object?>{'op_ms': _opMs};
}
