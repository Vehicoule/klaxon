/// The per-vector harness — the adapter's equivalent of `conformance.zig`'s
/// `Harness`: deterministic globals, registries, logs and the damage model.
library;

import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/widgets.dart' show Widget;
import 'package:flutter_test/flutter_test.dart' show WidgetTester;

import 'gestures.dart';
import 'i18n.dart';
import 'model.dart';
import 'nav.dart';
import 'state.dart';

/// Signal kinds Klaxon declares per name (typed maps, like the Zig harness).
class Harness {
  Harness(this.tester);

  final WidgetTester tester;

  // --- deterministic globals ---
  Size viewport = const Size(800, 600); // logical px, origin top-left
  int nowMs = 0; // virtual time; `pointer.t`/`tick` advance it

  // --- registries ---
  final Map<String, KxNode> ids = {};
  final Map<String, KxSignal<int>> sigI64 = {};
  final Map<String, KxSignal<bool>> sigBool = {};
  final Map<String, KxSignal<double>> sigF32 = {};
  final Map<String, KxTextSignal> sigText = {};
  KxMemo<int>? memo;
  String memoName = 'memo';
  KxI18n? i18n;
  KxNavigator? nav;
  KxNode? rootModel;

  // --- logs ---
  final List<String> gestures = [];
  final List<String> events = [];
  final List<String> effectLog = [];
  final List<KxA11yEvent> a11yEvents = [];

  // --- gesture arenas (one per gesture_detector node) + build counter ---
  final List<KxGestureArena> gestureArenas = [];
  int buildSeq = 0; // pre-order counter → FocusTraversalOrder

  // --- focus (Klaxon's FocusManager + InputRouter.focused — always in sync here) ---
  KxNode? focusedNode;

  // --- pointer bookkeeping for the injector ---
  final Set<int> activePointers = {};
  final Map<int, Offset> lastPointerPos = {};

  /// Rebuilds the root widget (viewport/direction propagate on re-pump).
  Widget Function()? rootBuilder;

  // --- damage (root-accumulated, mapped to root space) ---
  Rect? damage;
  bool get damageValid => damage != null;
  void unionDamage(Rect r) => damage = unionRect(damage, r);
  void clearDamage() => damage = null;

  String? lastError;

  // ---------------------------------------------------------------------------

  KxSignal<int> sigInt(String name, int initial) =>
      sigI64.putIfAbsent(name, () => KxSignal<int>(initial));
  KxSignal<bool> sigBoolOf(String name, bool initial) =>
      sigBool.putIfAbsent(name, () => KxSignal<bool>(initial));
  KxSignal<double> sigFloatOf(String name, double initial) =>
      sigF32.putIfAbsent(name, () => KxSignal<double>(initial));

  /// "a" → tracked read; "peek:a" → untracked; "memo" → the test's memo.
  int? readRef(String ref) {
    if (ref == 'memo') return memo?.get();
    if (ref.startsWith('peek:')) return sigI64[ref.substring(5)]?.peek();
    return sigI64[ref]?.get();
  }

  /// Klaxon `FocusManager.focusNode` + `requestFocus` fused: model state,
  /// the a11y `focus_changed` event, and the real FocusNode.
  void setFocused(KxNode? node, {bool realFocus = true}) {
    if (identical(focusedNode, node)) return;
    focusedNode = node;
    a11yEvents.add(KxA11yEvent('focus_changed', nodeId: node?.id));
    if (realFocus) {
      if (node?.focusNode != null) {
        node!.focusNode!.requestFocus();
      } else if (node == null) {
        // Escape / explicit unfocus.
        // (FocusManager.instance.primaryFocus?.unfocus() is called by the
        // caller — keep model first.)
      }
    }
  }
}
