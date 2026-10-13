/// Adapter-side model layer: the per-DSL-node record that backs the
/// expectations Flutter has no direct equivalent for (semantic flatten,
/// focus order, damage accumulation, text/state reads).
///
/// The widget tree is real Flutter; this model is the *observability
/// instrumentation* the ADAPTERS contract explicitly allows: every field
/// here mirrors a property Klaxon exposes on its retained Nodes.
library;

import 'dart:ui' show Rect;

import 'package:flutter/widgets.dart' show FocusNode;

enum KxRole {
  none, text, heading, button, link, image, text_field, toggle, checkbox,
  radio, slider, progress, scrollbar, list, list_item, dialog, alert, menu,
  menu_item, tab, tab_panel, separator, group,
}

enum KxAction { activate, increment, decrement, delete }

enum KxLiveRegion { off, polite, assertive }

KxRole? kxRoleOf(String s) {
  for (final r in KxRole.values) {
    if (r.name == s) return r;
  }
  return null;
}

KxAction? kxActionOf(String s) {
  for (final a in KxAction.values) {
    if (a.name == s) return a;
  }
  return null;
}

/// The semantic descriptor — Klaxon's `semantics.Semantics`.
class KxSem {
  KxRole role = KxRole.none;
  String label = '';
  String hint = '';
  String value = '';
  bool? checked;
  bool disabled = false;
  bool focusable = false;
  final Set<KxAction> actions = {};
  KxLiveRegion live = KxLiveRegion.off;
}

/// A logged accessibility-bridge event (Klaxon's `LogBridge` entry).
class KxA11yEvent {
  KxA11yEvent(this.kind, {this.nodeId, this.text = '', this.region = KxLiveRegion.off});
  final String kind; // tree_dirty | focus_changed | announce | control_changed
  final String? nodeId;
  final String text;
  final KxLiveRegion region;
}

/// The model node — one per DSL node. `renderKey` locates the corresponding
/// element/render object for rects/measured/damage lookups.
class KxNode {
  KxNode(this.type, this.id);

  final String type;
  final String id;
  KxNode? parent;
  final List<KxNode> children = [];

  // --- DSL universal props ---
  bool visible = true;
  bool excludeSemantics = false;
  double overflowL = 0, overflowT = 0, overflowR = 0, overflowB = 0;
  int traversalSeq = -1; // pre-order index among focusable nodes

  // --- semantics ---
  KxSem? sem;
  // true when the node sits inside the semantic tree (not hidden by an
  // invisible/excluded ancestor — used for real Focus widgets).
  bool inSemanticTree = true;

  // --- wiring ---
  FocusNode? focusNode;
  /// The widget attaches its own [FocusNode] inside its build (text_field) —
  /// the props layer must not wrap it in a second Focus.
  bool ownsFocus = false;
  void Function(String event)? logEvent; // press/change/submit emitters
  String Function()? readText; // `text` expect: label else value
  void Function(double offset)? setScrollOffset;
  double Function()? scrollOffset;
  Map<String, double> Function()? scrollInfo;
  List<int> Function()? liveItems; // list_view materialized indices
  void Function(int count)? setItemCount;
  void Function()? reloadItems;
  void Function(String burst)? textInput; // text_field burst append
  void Function(bool shift)? keyHandle; // per-node key handler hook (unused)

  /// Klaxon `on_key` — dispatches a key DOWN to this node when focused.
  /// Returns true when the key was consumed (Klaxon chain order). Set by
  /// widgets with intrinsic key behavior (text_field, slider).
  bool Function(String key, {bool shift})? onKey;
}

// --- Semantic tree (flattened view for assistive tech) ---------------------

class KxSemNode {
  KxSemNode({required this.node, required this.sem, this.labelOverride});
  final KxNode node;
  final KxSem sem;
  final String? labelOverride;
  final List<KxSemNode> children = [];

  String get label =>
      (sem.label.isNotEmpty ? sem.label : null) ??
      (labelOverride != null && labelOverride!.isNotEmpty ? labelOverride : null) ??
      '';
}

/// First descendant (depth-first) with a non-empty label — Klaxon's
/// label fallback for container-ish roles.
String? firstDescendantLabel(KxNode n) {
  for (final c in n.children) {
    if (c.excludeSemantics || !c.visible) continue;
    final s = c.sem;
    if (s != null && s.label.isNotEmpty) return s.label;
    final l = firstDescendantLabel(c);
    if (l != null) return l;
  }
  return null;
}

void _flattenInto(KxNode n, List<KxSemNode> list) {
  if (n.excludeSemantics || !n.visible) return;
  final s = n.sem;
  if (s != null) {
    final sn = KxSemNode(node: n, sem: s, labelOverride: firstDescendantLabel(n));
    list.add(sn);
    for (final c in n.children) {
      _flattenInto(c, sn.children);
    }
  } else {
    for (final c in n.children) {
      _flattenInto(c, list);
    }
  }
}

/// Flattened semantic list (pre-order). Klaxon's `buildSemanticTree` wraps
/// the top-level semantic nodes in a `.group` when the root has no
/// descriptor of its own, and the checker drops that wrapper again — so the
/// observed list is simply the pre-order traversal of all semantic nodes.
List<KxSemNode> flattenSemantics(KxNode root) {
  final top = <KxSemNode>[];
  _flattenInto(root, top);
  final out = <KxSemNode>[];
  void walk(KxSemNode sn) {
    out.add(sn);
    for (final c in sn.children) {
      walk(c);
    }
  }

  for (final sn in top) {
    walk(sn);
  }
  return out;
}

/// Focus order = focusable nodes in semantic pre-order (Klaxon
/// `FocusManager.focusOrder` → `collectFocusable`).
List<KxNode> focusOrderOf(KxNode root) {
  final out = <KxNode>[];
  for (final sn in flattenSemantics(root)) {
    if (sn.sem.focusable) out.add(sn.node);
  }
  return out;
}

/// Rect union helper for the damage model.
Rect? unionRect(Rect? a, Rect b) {
  if (a == null) return b;
  return Rect.fromLTRB(
    a.left < b.left ? a.left : b.left,
    a.top < b.top ? a.top : b.top,
    a.right > b.right ? a.right : b.right,
    a.bottom > b.bottom ? a.bottom : b.bottom,
  );
}
