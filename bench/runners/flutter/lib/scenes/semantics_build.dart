// Scene: semantics_build — build/diff the a11y semantics tree of a
// 1000-node tree each frame (system family).
// bench-scenes.md Family D: build/diff the a11y semantics tree of a
// 1000-node tree each frame — extra.nodes_per_frame.
//
// Flutter idiom: SemanticsBinding.ensureSemantics() turns on semantics
// collection, then every frame the whole render subtree is marked dirty
// (markNeedsSemanticsUpdate) and the scene's PipelineOwner.flushSemantics()
// recompiles the SemanticsNode tree. The mark+flush runs inside build() —
// drawFrame's own flushSemantics phase sits after compositeFrame (outside
// build+raster), so flushing inside the build phase is what lands the
// compile cost in the frame-work metric. Note the render subtree is owned
// by the View element's child PipelineOwner, not rootPipelineOwner (the
// manifold root cannot hold a root node), so marks, flush and the
// SemanticsOwner query all go through ro.owner.
// extra.nodes_per_frame = the semantics nodes compiled per frame (counted
// from the SemanticsOwner's root SemanticsNode once the tree exists).

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../harness.dart';

class SemanticsBuildScene extends BenchScene {
  SemanticsBuildScene() : super('semantics_build');

  static const int kNodes = 1000;

  final GlobalKey _probeKey = GlobalKey();
  SemanticsHandle? _handle;

  /// The PipelineOwner that actually owns this scene's render subtree.
  ///
  /// RendererBinding.rootPipelineOwner is a manifold root that cannot own a
  /// root node; the View element adopts its own child PipelineOwner, which is
  /// where the RenderView's SemanticsOwner and dirty sets live. Marks land on
  /// `ro.owner`, so the same owner must be flushed and queried.
  PipelineOwner? get _owner => _probeKey.currentContext?.findRenderObject()?.owner;

  @override
  Widget build(BuildContext context) {
    // Turns on semantics collection (the SemanticsHandle keeps the pipeline
    // owner's SemanticsOwner alive; released in dispose()).
    _handle ??= SemanticsBinding.instance.ensureSemantics();
    // Mark the previous frame's render subtree dirty + flush: ~1000
    // SemanticsNodes recompile every frame inside the build phase.
    final RenderObject? ro = _probeKey.currentContext?.findRenderObject();
    if (ro != null) {
      _markDirty(ro);
      _owner?.flushSemantics();
    }
    return _tree();
  }

  void _markDirty(RenderObject ro) {
    ro.markNeedsSemanticsUpdate();
    ro.visitChildren(_markDirty);
  }

  /// The 1000-node tree: 1000 labelled Semantics boundaries over colored
  /// cells (Wrap — every node stays mounted, no virtualization).
  Widget _tree() {
    return KeyedSubtree(
      key: _probeKey,
      child: Wrap(
        children: <Widget>[
          for (int i = 0; i < kNodes; i++)
            Semantics(
              label: 'node $i',
              child: Container(
                width: 12,
                height: 12,
                color: i.isEven ? kBenchCardColor : kBenchPurple,
              ),
            ),
        ],
      ),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    harness.refresh(); // mark + flush inside this frame's build
  }

  /// Count the live semantics nodes (the tree the engine diffs per frame).
  int _countSemanticsNodes() {
    final SemanticsOwner? owner = _owner?.semanticsOwner;
    final SemanticsNode? root = owner?.rootSemanticsNode;
    var count = 0;
    bool visit(SemanticsNode node) {
      count++;
      node.visitChildren(visit);
      return true;
    }

    if (root != null) visit(root);
    return count;
  }

  @override
  Map<String, Object?> extra() => <String, Object?>{
        'nodes_per_frame': _countSemanticsNodes(),
      };

  @override
  void dispose() {
    _handle?.dispose();
    _handle = null;
    super.dispose();
  }
}
