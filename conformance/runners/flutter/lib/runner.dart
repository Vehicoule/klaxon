/// The per-vector interpreter — a faithful port of `src/conformance.zig`'s
/// Harness/runAction/checkExpect driving a real Flutter widget tree.
///
/// Determinism model: `h.nowMs` is the DSL virtual clock (set per action,
/// default 0). `tester.sendEventToBinding` performs real hit-testing;
/// Klaxon's gesture arena is ticked explicitly (no wall-clock reliance).
library;

import 'dart:convert' show jsonDecode;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart'
    show RenderBox, RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart' show WidgetTester, find;

import 'harness.dart';
import 'i18n.dart' show KxDateKind, KxDir, KxI18n, KxNumberOpts;
import 'model.dart';
import 'nav.dart';
import 'state.dart';
import 'widgets.dart' show buildNode, numOf, intOf, boolOf, strOf, KxRoot;

const double kDefaultTolerance = 0.01; // Klaxon DEFAULT_TOLERANCE

/// One test outcome — `TestResult` in the Zig harness.
class KxResult {
  KxResult({required this.id, required this.domain, required this.rule});
  final String id;
  final String domain;
  final String rule;
  bool passed = false;
  final List<String> failures = [];
}

class KxCheck {
  KxCheck(this.failures, this.tol);
  final List<String> failures;
  final double tol;

  void fail(String m) => failures.add(m);
  bool nearEq(num a, num b) => (a - b).abs() <= tol;
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

void _setupSignals(Harness h, Map<String, dynamic> sigs) {
  for (final e in sigs.entries) {
    final v = e.value;
    switch (v) {
      case bool b:
        h.sigBool[e.key] = KxSignal<bool>(b);
      case int i:
        h.sigI64[e.key] = KxSignal<int>(i);
      case double f:
        h.sigF32[e.key] = KxSignal<double>(f);
      case String s:
        h.sigText[e.key] = KxTextSignal(s);
      case Map m:
        if (m['type'] == 'text') {
          h.sigText[e.key] = KxTextSignal(strOf(m['value'], ''));
        }
    }
  }
}

void _setupEffects(Harness h, List<dynamic>? defs) {
  if (defs == null) return;
  for (final dv in defs.whereType<Map>()) {
    final name = strOf(dv['name'], 'effect');
    final reads = ((dv['reads'] as List?) ?? const []).whereType<String>().toList();
    final op = strOf(dv['op'], 'add');
    final eff = KxEffect(() {
      int acc = op == 'mul' ? 1 : 0;
      var first = true;
      for (final r in reads) {
        final v = h.readRef(r) ?? 0;
        switch (op) {
          case 'add':
            acc += v;
          case 'mul':
            acc *= v;
          case 'first':
            if (first) acc = v;
        }
        first = false;
      }
      h.effectLog.add('$name=$acc');
    });
    eff.run(); // first run: resolve + subscribe
  }
}

void _setupMemo(Harness h, Map<String, dynamic>? def) {
  if (def == null) return;
  final args = def['args'];
  if (args is! List || args.length < 2) return;
  final a = h.sigI64[strOf(args[0], '')], b = h.sigI64[strOf(args[1], '')];
  if (a == null || b == null) return;
  final op = strOf(def['op'], 'add');
  h.memoName = strOf(def['name'], 'memo');
  h.memo = KxMemo<int>(() => switch (op) {
        'sub' => a.get() - b.get(),
        'mul' => a.get() * b.get(),
        _ => a.get() + b.get(),
      });
}

void _setupI18n(Harness h, Map<String, dynamic>? v) {
  if (v == null) return;
  final i18n = KxI18n(strOf(v['fallback'], 'en'));
  h.i18n = i18n;
  final dirs = (v['dirs'] as Map?)?.cast<String, dynamic>() ?? const {};
  if (v['locales'] is Map) {
    for (final e in (v['locales'] as Map).entries) {
      final tag = '${e.key}';
      final dir = strOf(dirs[tag], 'ltr') == 'rtl' ? KxDir.rtl : KxDir.ltr;
      final arb = e.value;
      final Map<String, dynamic> arbMap = switch (arb) {
        String s => (jsonDecode(s) as Map).cast<String, dynamic>(),
        Map m => m.cast<String, dynamic>(),
        _ => const <String, dynamic>{},
      };
      i18n.addArb(tag, arbMap, dir);
    }
  }
  if (v['locale'] is String) i18n.setLocale(v['locale'] as String);
}

void _setupNavigator(Harness h, Map<String, dynamic>? v) {
  if (v == null) return;
  final nv = KxNavigator();
  h.nav = nv;
  nv.onChange = (kind) => h.events.add('nav:${kind.name}');
  if (v['routes'] is List) {
    for (final rv in v['routes'] as List) {
      if (rv is! Map) continue;
      final pattern = strOf(rv['pattern'], '');
      if (pattern.isEmpty) continue;
      nv.define(pattern, _transitionOf(strOf(rv['transition'], 'slide')));
    }
  }
}

KxTransition _transitionOf(String s) => switch (s) {
      'none' => KxTransition.none,
      'slide_up' => KxTransition.slide_up,
      'fade' => KxTransition.fade,
      'scale' => KxTransition.scale,
      _ => KxTransition.slide,
    };

KxParams _paramsOf(Object? v) {
  final p = KxParams();
  if (v is Map) {
    for (final e in v.entries) {
      if (!p.add('${e.key}', '${e.value}')) throw const KxError('TooManyParams');
    }
  }
  return p;
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

Future<void> _pumpFrame(Harness h) async {
  // pumpWidget re-supplies the root so relayout/set_locale propagate
  // direction+viewport like Klaxon's root.layout.
  if (h.rootModel != null && h.rootBuilder != null) {
    await h.tester.pumpWidget(h.rootBuilder!());
  }
  await h.tester.pump();
  // Klaxon's contract treats overflow/bad-layout as clipped, never fatal —
  // a framework assert must fail the *vector's* expectations (via missing
  // rects), not the whole suite, so pending test exceptions are drained.
  while (h.tester.takeException() != null) {}
}

Future<void> runAction(Harness h, Map<String, dynamic> av) async {
  try {
    await _runActionInner(h, av);
  } on KxError catch (e) {
    h.lastError = e.name;
  } catch (e) {
    h.lastError = '$e';
  }
  await _pumpFrame(h);
}

Future<void> _sendPointer(Harness h, PointerEvent ev) {
  return h.tester.sendEventToBinding(ev);
}

Future<void> _runActionInner(Harness h, Map<String, dynamic> av) async {
  final op = strOf(av['op'], '');
  final t = intOf(av['t'], 0);
  switch (op) {
    case 'pointer':
      if (h.rootModel == null) throw const KxError('NoTree');
      h.nowMs = t;
      final phase = strOf(av['phase'], 'move');
      final pos = Offset(numOf(av['x'], 0), numOf(av['y'], 0));
      final pid = math.max(0, intOf(av['pointer'], 0));
      const kind = PointerDeviceKind.touch;
      switch (phase) {
        case 'down':
          await _sendPointer(h, PointerDownEvent(
            timeStamp: Duration(milliseconds: t), pointer: pid, position: pos,
            kind: kind, buttons: kPrimaryButton,
          ));
          h.activePointers.add(pid);
        case 'move':
          final last = h.lastPointerPos[pid] ?? pos;
          await _sendPointer(h, PointerMoveEvent(
            timeStamp: Duration(milliseconds: t), pointer: pid, position: pos,
            delta: pos - last, kind: kind, buttons: kPrimaryButton,
          ));
        case 'up':
          await _sendPointer(h, PointerUpEvent(
            timeStamp: Duration(milliseconds: t), pointer: pid, position: pos,
            kind: kind,
          ));
          h.activePointers.remove(pid);
        case 'cancel':
          await _sendPointer(h, PointerCancelEvent(
            timeStamp: Duration(milliseconds: t), pointer: pid, position: pos,
            kind: kind,
          ));
          h.activePointers.remove(pid);
        case 'enter' || 'leave':
          for (final a in h.gestureArenas) {
            a.cancel();
          }
      }
      h.lastPointerPos[pid] = pos;

    case 'scroll':
      if (h.rootModel == null) throw const KxError('NoTree');
      h.nowMs = t;
      await _sendPointer(h, PointerScrollEvent(
        timeStamp: Duration(milliseconds: t),
        position: Offset(numOf(av['x'], 0), numOf(av['y'], 0)),
        scrollDelta: Offset(numOf(av['dx'], 0), numOf(av['dy'], 0)),
      ));

    case 'key':
      await _dispatchKey(h, strOf(av['key'], 'unknown'), shift: boolOf(av['shift'], false));

    case 'text_input':
      h.focusedNode?.textInput?.call(strOf(av['text'], ''));

    case 'tick':
      h.nowMs = math.max(0, intOf(av['ms'], 0));
      for (final a in h.gestureArenas) {
        a.tick(h.nowMs);
      }

    case 'focus':
      final id = av['id'];
      if (id == null) {
        h.setFocused(null);
        FocusManager.instance.primaryFocus?.unfocus();
      } else {
        final kn = h.ids[strOf(id, '')] ?? (throw const KxError('UnknownNode'));
        h.setFocused(kn);
      }

    case 'mark_dirty':
      final kn = h.ids[strOf(av['id'], '')] ?? (throw const KxError('UnknownNode'));
      final r = _globalRect(h, kn.id);
      if (r != null) {
        h.unionDamage(Rect.fromLTRB(
          r.left - kn.overflowL, r.top - kn.overflowT,
          r.right + kn.overflowR, r.bottom + kn.overflowB,
        ));
      }

    case 'mark_dirty_rect':
      final kn = h.ids[strOf(av['id'], '')] ?? (throw const KxError('UnknownNode'));
      final rl = av['rect'];
      if (rl is! List) throw const KxError('BadRect');
      // The rect is in the node's *parent* (DSL container) space. The render
      // tree above the node contains transparent proxies (cap boxes, wrapper
      // renders) that share the node's own origin — the container is the
      // first ancestor with a different global origin. (parentData.offset is
      // unreliable here: several renders carry plain ParentData.)
      final ro = _elementOf(h, kn.id)?.findRenderObject();
      RenderBox? pro;
      if (ro is RenderBox) {
        final origin = ro.localToGlobal(Offset.zero);
        Object? p = ro.parent;
        while (p is RenderBox &&
            p.parent is RenderObject &&
            p.localToGlobal(Offset.zero) == origin) {
          p = p.parent;
        }
        if (p is RenderBox) pro = p;
      }
      final p0 = pro?.localToGlobal(Offset(numOf(rl[0], 0), numOf(rl[1], 0)));
      if (p0 != null) {
        h.unionDamage(Rect.fromLTWH(p0.dx, p0.dy, numOf(rl[2], 0), numOf(rl[3], 0)));
      }

    case 'relayout':
      h.viewport = Size(
        numOf(av['w'], h.viewport.width),
        numOf(av['h'], h.viewport.height),
      );
      // _pumpFrame rebuilds the root with the new viewport/direction.

    case 'paint':
      // Rendering happens every pump; painting consumes the damage region.
      h.clearDamage();

    case 'set_scroll':
      final kn = h.ids[strOf(av['id'], '')] ?? (throw const KxError('UnknownNode'));
      kn.setScrollOffset?.call(numOf(av['offset'], 0));

    case 'list_count':
      final kn = h.ids[strOf(av['id'], '')] ?? (throw const KxError('UnknownNode'));
      kn.setItemCount?.call(math.max(0, intOf(av['count'], 0)));

    case 'list_reload':
      final kn = h.ids[strOf(av['id'], '')] ?? (throw const KxError('UnknownNode'));
      kn.reloadItems?.call();

    case 'set_locale':
      final i18n = h.i18n ?? (throw const KxError('MissingI18n'));
      i18n.setLocale(strOf(av['tag'], ''));

    case 'signal_set':
      final name = strOf(av['name'], '');
      final v = av['value'] ?? 0;
      if (h.sigI64[name] case final s?) {
        s.set(intOf(v, 0));
      } else if (h.sigBool[name] case final s?) {
        s.set(boolOf(v, false));
      } else if (h.sigF32[name] case final s?) {
        s.set(numOf(v, 0));
      } else if (h.sigText[name] case final s?) {
        if (av['len'] != null) {
          // `len` generates filler bytes — exercises the 1 MiB cap.
          s.set('x' * math.max(0, intOf(av['len'], 0)));
        } else {
          s.set(strOf(v, ''));
        }
      } else {
        throw const KxError('UnknownSignal');
      }

    case 'signal_notify':
      final name = strOf(av['name'], '');
      if (h.sigI64[name] case final s?) {
        s.forceNotify();
      } else if (h.sigText[name] case final s?) {
        s.forceNotify();
      } else {
        throw const KxError('UnknownSignal');
      }

    case 'nav_push':
      final nv = h.nav ?? (throw const KxError('MissingNavigator'));
      nv.push(strOf(av['pattern'], ''), _paramsOf(av['params']));

    case 'nav_push_path':
      final nv = h.nav ?? (throw const KxError('MissingNavigator'));
      nv.pushPath(strOf(av['path'], ''), _paramsOf(av['params']));

    case 'navigate':
      final nv = h.nav ?? (throw const KxError('MissingNavigator'));
      nv.navigateTo(strOf(av['uri'], ''));

    case 'nav_replace':
      final nv = h.nav ?? (throw const KxError('MissingNavigator'));
      nv.replace(strOf(av['pattern'], ''), _paramsOf(av['params']));

    case 'nav_pop':
      final nv = h.nav ?? (throw const KxError('MissingNavigator'));
      nv.pop();

    case 'nav_back':
      final nv = h.nav ?? (throw const KxError('MissingNavigator'));
      nv.onBack();

    case 'nav_pop_to_root':
      final nv = h.nav ?? (throw const KxError('MissingNavigator'));
      nv.popToRoot();

    case 'announce':
      h.a11yEvents.add(KxA11yEvent('announce',
          text: strOf(av['text'], ''),
          region: strOf(av['region'], 'polite') == 'assertive' ? KxLiveRegion.assertive : KxLiveRegion.polite));

    default:
      throw const KxError('UnknownOp');
  }
}

/// Klaxon key dispatch (host.zig order): Escape/Back → dispatchBack (focused
/// chain, then navigator); Tab → focus manager traversal; anything else → the
/// focused node's on_key, then the FM's activation fallback (Enter/Space →
/// synthetic pointer press when the node declares .activate).
Future<void> _dispatchKey(Harness h, String key, {bool shift = false}) async {
  if (key == 'escape' || key == 'back') {
    if (h.focusedNode?.onKey?.call(key) == true) return;
    h.nav?.onBack();
    return;
  }
  if (key == 'tab') {
    if (h.rootModel == null) return;
    final order = focusOrderOf(h.rootModel!);
    if (order.isEmpty) return;
    final cur = h.focusedNode;
    final idx = cur == null ? -1 : order.indexOf(cur);
    final next = shift
        ? order[(idx <= 0 ? order.length : idx) - 1]
        : order[(idx + 1) % order.length];
    h.setFocused(next);
    return;
  }
  // Non-traversal keys: focused node's handler first.
  if (h.focusedNode?.onKey?.call(key, shift: shift) == true) return;
  // FM activation fallback: Enter/Space synthesizes a pointer press at the
  // node's visual center — routed through the real hit-test path.
  if (key == 'enter' || key == 'space') {
    final kn = h.focusedNode;
    if (kn != null && (kn.sem?.actions.contains(KxAction.activate) ?? false)) {
      final r = _globalRect(h, kn.id);
      if (r != null) {
        final c = r.center;
        await _sendPointer(h, PointerDownEvent(
          timeStamp: Duration(milliseconds: h.nowMs), pointer: 0, position: c,
          kind: PointerDeviceKind.touch, buttons: kPrimaryButton,
        ));
        await _sendPointer(h, PointerUpEvent(
          timeStamp: Duration(milliseconds: h.nowMs), pointer: 0, position: c,
          kind: PointerDeviceKind.touch,
        ));
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Expectations (mirrors checkExpect)
// ---------------------------------------------------------------------------

Element? _elementOf(Harness h, String id) {
  final finder = find.byKey(ValueKey<String>(id));
  final els = finder.evaluate();
  return els.isEmpty ? null : els.first;
}

Rect? _globalRect(Harness h, String id) {
  final ro = _elementOf(h, id)?.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return null;
  final p = ro.localToGlobal(Offset.zero);
  return p & ro.size;
}

/// Klaxon `liveNode` — the node must exist AND be mounted in the tree.
RenderBox? _liveRender(Harness h, KxCheck c, String id) {
  if (!h.ids.containsKey(id) && !id.contains('.item')) {
    c.fail('unknown node id "$id"');
    return null;
  }
  final ro = _elementOf(h, id)?.findRenderObject();
  if (ro is! RenderBox || !ro.attached) {
    c.fail('node "$id" is no longer in the tree');
    return null;
  }
  return ro;
}

void _expectSeq(KxCheck c, String key, List<dynamic> want, List<String> got) {
  for (var i = 0; i < math.max(want.length, got.length); i++) {
    final w = i < want.length ? '${want[i]}' : '<missing>';
    final g = i < got.length ? got[i] : '<missing>';
    if (w != g) {
      c.fail('$key[$i]: expected "$w", got "$g" (full got: $got)');
      return;
    }
  }
}

void _expectRects(Harness h, KxCheck c, Map<String, dynamic> v) {
  for (final e in v.entries) {
    final ro = _liveRender(h, c, e.key);
    if (ro == null) continue;
    final wv = e.value;
    if (wv is! List) {
      c.fail('rects.${e.key}: expected [x,y,w,h]');
      continue;
    }
    final want = Rect.fromLTWH(numOf(wv[0], 0), numOf(wv[1], 0), numOf(wv[2], 0), numOf(wv[3], 0));
    final p = ro.localToGlobal(Offset.zero);
    final got = p & ro.size;
    if (!c.nearEq(got.left, want.left) || !c.nearEq(got.top, want.top) ||
        !c.nearEq(got.width, want.width) || !c.nearEq(got.height, want.height)) {
      c.fail('rects.${e.key}: expected [${want.left},${want.top},${want.width},${want.height}] '
          'got [${got.left},${got.top},${got.width},${got.height}]');
    }
  }
}

void _expectMeasured(Harness h, KxCheck c, Map<String, dynamic> v) {
  for (final e in v.entries) {
    final ro = _liveRender(h, c, e.key);
    if (ro == null) continue;
    final wv = e.value;
    if (wv is! List) {
      c.fail('measured.${e.key}: expected [w,h]');
      continue;
    }
    // Klaxon re-measures under viewport constraints — dry layout is the
    // public equivalent (computes desired size without mutating state).
    final got = ro.getDryLayout(BoxConstraints(
      maxWidth: h.viewport.width,
      maxHeight: h.viewport.height,
    ));
    if (!c.nearEq(got.width, numOf(wv[0], 0)) || !c.nearEq(got.height, numOf(wv[1], 0))) {
      c.fail('measured.${e.key}: expected [${wv[0]},${wv[1]}] got [${got.width},${got.height}]');
    }
  }
}

void _expectDamage(Harness h, KxCheck c, Object? v) {
  if (v == null) {
    if (h.damageValid) {
      final d = h.damage!;
      c.fail('damage: expected none, got [${d.left},${d.top},${d.width},${d.height}]');
    }
    return;
  }
  if (v is! List) {
    c.fail('damage: expected [x,y,w,h] or null');
    return;
  }
  final want = Rect.fromLTWH(numOf(v[0], 0), numOf(v[1], 0), numOf(v[2], 0), numOf(v[3], 0));
  final got = h.damage;
  if (got == null) {
    c.fail('damage: expected [${want.left},${want.top},${want.width},${want.height}] got none');
    return;
  }
  if (!c.nearEq(got.left, want.left) || !c.nearEq(got.top, want.top) ||
      !c.nearEq(got.width, want.width) || !c.nearEq(got.height, want.height)) {
    c.fail('damage: expected [${want.left},${want.top},${want.width},${want.height}] '
        'got [${got.left},${got.top},${got.width},${got.height}]');
  }
}

void _expectFocused(Harness h, KxCheck c, Object? v, bool routerSide) {
  final key = routerSide ? 'router_focused' : 'focused';
  final n = h.focusedNode;
  if (v == null) {
    if (n != null) c.fail('$key: expected null, got "${n.id}"');
    return;
  }
  final want = strOf(v, '');
  if (n == null || n.id != want) {
    c.fail('$key: expected "$want", got ${n == null ? 'null' : '"${n.id}"'}');
  }
}

void _expectSignals(Harness h, KxCheck c, Map<String, dynamic> v) {
  for (final e in v.entries) {
    if (h.sigI64[e.key] case final s?) {
      final want = intOf(e.value, 0);
      if (s.peek() != want) c.fail('signals.${e.key}: expected $want, got ${s.peek()}');
    } else if (h.sigBool[e.key] case final s?) {
      final want = boolOf(e.value, false);
      if (s.peek() != want) c.fail('signals.${e.key}: expected $want, got ${s.peek()}');
    } else if (h.sigF32[e.key] case final s?) {
      final want = numOf(e.value, 0);
      if (!c.nearEq(s.peek(), want)) c.fail('signals.${e.key}: expected $want, got ${s.peek()}');
    } else if (h.sigText[e.key] case final s?) {
      final want = strOf(e.value, '');
      if (s.peek() != want) c.fail('signals.${e.key}: expected "$want", got "${s.peek()}"');
    } else {
      c.fail('signals.${e.key}: unknown signal');
    }
  }
}

void _expectA11y(Harness h, KxCheck c, List<dynamic> v) {
  final root = h.rootModel;
  if (root == null) return;
  final list = flattenSemantics(root);
  if (v.length != list.length) {
    c.fail('a11y: expected ${v.length} semantic nodes, got ${list.length}');
    return;
  }
  for (var i = 0; i < v.length; i++) {
    final ev = v[i], got = list[i];
    if (ev is! Map) continue;
    if (ev['role'] is String && got.sem.role.name != ev['role']) {
      c.fail('a11y role: expected "${ev['role']}", got "${got.sem.role.name}"');
    }
    if (ev['label'] is String && got.label != ev['label']) {
      c.fail('a11y label: expected "${ev['label']}", got "${got.label}"');
    }
    if (ev['hint'] is String && got.sem.hint != ev['hint']) {
      c.fail('a11y hint: expected "${ev['hint']}", got "${got.sem.hint}"');
    }
    if (ev['value'] is String && got.sem.value != ev['value']) {
      c.fail('a11y value: expected "${ev['value']}", got "${got.sem.value}"');
    }
    if (ev['checked'] != null) {
      final want = boolOf(ev['checked'], false);
      final g = got.sem.checked ?? false;
      if (g != want) c.fail('a11y checked: expected $want, got $g');
    }
    if (ev['focusable'] != null) {
      final want = boolOf(ev['focusable'], false);
      if (got.sem.focusable != want) {
        c.fail('a11y focusable: expected $want, got ${got.sem.focusable}');
      }
    }
    if (ev['disabled'] != null) {
      final want = boolOf(ev['disabled'], false);
      if (got.sem.disabled != want) {
        c.fail('a11y disabled: expected $want, got ${got.sem.disabled}');
      }
    }
  }
}

void _expectA11yEvents(Harness h, KxCheck c, List<dynamic> v) {
  for (var i = 0; i < v.length; i++) {
    if (i >= h.a11yEvents.length) {
      c.fail('a11y_events[$i]: expected "${v[i] is Map ? v[i]['kind'] : '?'}", log ended at ${h.a11yEvents.length} events');
      return;
    }
    final ev = v[i], got = h.a11yEvents[i];
    if (ev is Map) {
      if (ev['kind'] is String && ev['kind'] != got.kind) {
        c.fail('a11y_events[$i]: expected kind "${ev['kind']}", got "${got.kind}"');
        return;
      }
      if (ev['text'] is String && ev['text'] != got.text) {
        c.fail('a11y_events[$i]: expected text "${ev['text']}", got "${got.text}"');
        return;
      }
    }
  }
  if (h.a11yEvents.length != v.length) {
    c.fail('a11y_events: expected ${v.length} events, got ${h.a11yEvents.length}');
  }
}

void _expectText(Harness h, KxCheck c, Map<String, dynamic> v) {
  for (final e in v.entries) {
    final kn = h.ids[e.key];
    if (kn == null) {
      c.fail('unknown node id "${e.key}"');
      continue;
    }
    final s = kn.sem;
    if (s == null) {
      c.fail('text.${e.key}: node has no semantics');
      continue;
    }
    final got = kn.readText?.call() ?? (s.label.isNotEmpty ? s.label : s.value);
    final want = strOf(e.value, '');
    if (got != want) c.fail('text.${e.key}: expected "$want", got "$got"');
  }
}

void _expectI18n(Harness h, KxCheck c, Map<String, dynamic> v) {
  final i18n = h.i18n;
  if (i18n == null) {
    c.fail('i18n expects require setup.i18n');
    return;
  }
  for (final e in v.entries) {
    final want = strOf(e.value, '');
    var got = '';
    final k = e.key;
    if (k == 'direction') {
      got = i18n.direction.name;
    } else if (k.startsWith('tr:')) {
      got = i18n.tr(k.substring(3));
    } else if (k.startsWith('plural:')) {
      final rest = k.substring(7);
      final ci = rest.lastIndexOf(':');
      if (ci >= 0) {
        got = i18n.trPlural(rest.substring(0, ci), int.tryParse(rest.substring(ci + 1)) ?? 0);
      }
    } else if (k.startsWith('num:')) {
      final rest = k.substring(4);
      final opts = KxNumberOpts();
      var valstr = rest;
      final ci = rest.indexOf(':');
      if (ci >= 0) {
        valstr = rest.substring(0, ci);
        for (final tok in rest.substring(ci + 1).split(',')) {
          if (tok == 'pct') opts.percent = true;
          if (tok == 'nogroup') opts.grouping = false;
          if (tok.startsWith('dec=')) opts.decimals = int.tryParse(tok.substring(4));
        }
      }
      final loc = i18n.current;
      if (loc == null) continue;
      got = loc.formatNumber(double.tryParse(valstr) ?? 0, opts);
    } else if (k.startsWith('date:')) {
      final rest = k.substring(5);
      final ci = rest.lastIndexOf(':');
      if (ci >= 0) {
        final kind = switch (rest.substring(ci + 1)) {
          'long' => KxDateKind.long,
          'medium' => KxDateKind.medium,
          _ => KxDateKind.short,
        };
        final parts = rest.substring(0, ci).split('-');
        final y = int.tryParse(parts[0]) ?? 0;
        final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
        final d = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;
        final loc = i18n.current;
        if (loc == null) continue;
        got = loc.formatDate(y, m, d, kind);
      }
    }
    if (got != want) c.fail('i18n.$k: expected "$want", got "$got"');
  }
}

// --- raster readback ---------------------------------------------------------

class _Frame {
  _Frame(this.w, this.h, this.bytes);
  final int w, h;
  final ByteData bytes;

  int pixelAt(int x, int y) {
    if (x < 0 || y < 0 || x >= w || y >= h) return 0;
    final o = (y * w + x) * 4;
    return (bytes.getUint8(o) << 24) |
        (bytes.getUint8(o + 1) << 16) |
        (bytes.getUint8(o + 2) << 8) |
        bytes.getUint8(o + 3); // RRGGBBAA — same packing as the DSL
  }

  int countColor(int color, [Rect? rect]) {
    final x0 = rect == null ? 0 : math.max(0, rect.left.floor());
    final y0 = rect == null ? 0 : math.max(0, rect.top.floor());
    final x1 = rect == null ? w : math.min(w, rect.right.ceil());
    final y1 = rect == null ? h : math.min(h, rect.bottom.ceil());
    var n = 0;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        if (pixelAt(x, y) == color) n += 1;
      }
    }
    return n;
  }
}

int? _parseColorInt(Object? v) {
  if (v is String && v.startsWith('#') && v.length == 9) {
    return int.tryParse(v.substring(1), radix: 16); // stays RRGGBBAA
  }
  return null;
}

Future<_Frame?> _renderFrame(Harness h) async {
  final el = _elementOf(h, 'kx.frame');
  if (el == null) return null;
  final ro = el.findRenderObject();
  if (ro is! RenderRepaintBoundary) return null;
  _Frame? frame;
  await h.tester.runAsync(() async {
    final img = ro.toImageSync(pixelRatio: 1.0);
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (bd != null) frame = _Frame(img.width, img.height, bd);
  });
  return frame;
}

Future<void> _expectPixels(Harness h, KxCheck c, List<dynamic> v) async {
  final frame = await _renderFrame(h);
  if (frame == null) {
    c.fail('pixels: render failed');
    return;
  }
  for (var i = 0; i < v.length; i++) {
    final pv = v[i];
    if (pv is! Map) continue;
    final want = _parseColorInt(pv['color']);
    if (want == null) {
      c.fail('pixels[$i]: missing color');
      continue;
    }
    final got = frame.pixelAt(intOf(pv['x'], 0), intOf(pv['y'], 0));
    final approx = boolOf(pv['approx'], false);
    var ok = got == want;
    if (!ok && approx) {
      ok = true;
      for (var s = 24; s >= 0; s -= 8) {
        if ((((got >> s) & 0xFF) - ((want >> s) & 0xFF)).abs() > 2) ok = false;
      }
    }
    if (!ok) {
      c.fail('pixels[$i] at (${pv['x']},${pv['y']}): expected '
          '#${want.toRadixString(16).padLeft(8, '0')}, got #${got.toRadixString(16).padLeft(8, '0')}');
    }
  }
}

Future<void> _expectPixelCounts(Harness h, KxCheck c, List<dynamic> v) async {
  final frame = await _renderFrame(h);
  if (frame == null) {
    c.fail('pixel_counts: render failed');
    return;
  }
  for (var i = 0; i < v.length; i++) {
    final pv = v[i];
    if (pv is! Map) continue;
    final color = _parseColorInt(pv['color']);
    if (color == null) {
      c.fail('pixel_counts[$i]: missing color');
      continue;
    }
    Rect? rect;
    final rv = pv['rect'];
    if (rv is List && rv.length >= 4) {
      rect = Rect.fromLTWH(numOf(rv[0], 0), numOf(rv[1], 0), numOf(rv[2], 0), numOf(rv[3], 0));
    }
    final n = frame.countColor(color, rect);
    if (pv['exact'] != null) {
      final want = math.max(0, intOf(pv['exact'], 0));
      if (n != want) {
        c.fail('pixel_counts[$i]: expected exactly $want of '
            '#${color.toRadixString(16).padLeft(8, '0')}, got $n');
      }
    }
    if (pv['min'] != null) {
      final want = math.max(0, intOf(pv['min'], 0));
      if (n < want) c.fail('pixel_counts[$i]: expected ≥$want of $color, got $n');
    }
    if (pv['max'] != null) {
      final want = math.max(0, intOf(pv['max'], 0));
      if (n > want) c.fail('pixel_counts[$i]: expected ≤$want of $color, got $n');
    }
  }
}

// --- scroll / children / nav --------------------------------------------------

void _expectScroll(Harness h, KxCheck c, Map<String, dynamic> v) {
  for (final e in v.entries) {
    final kn = h.ids[e.key];
    if (kn == null) {
      c.fail('unknown node id "${e.key}"');
      continue;
    }
    final got = kn.scrollOffset?.call() ?? 0;
    final want = numOf(e.value, 0);
    if (!c.nearEq(got, want)) c.fail('scroll.${e.key}: expected $want, got $got');
  }
}

void _expectScrollInfo(Harness h, KxCheck c, Map<String, dynamic> v) {
  for (final e in v.entries) {
    final kn = h.ids[e.key];
    if (kn == null) {
      c.fail('unknown node id "${e.key}"');
      continue;
    }
    final info = kn.scrollInfo?.call();
    if (info == null) {
      c.fail('scroll_info.${e.key}: node is not scrollable');
      continue;
    }
    if (e.value is Map) {
      for (final fe in (e.value as Map).entries) {
        final got = info['${fe.key}'];
        if (got == null) continue;
        final want = numOf(fe.value, 0);
        if (!c.nearEq(got, want)) {
          c.fail('scroll_info.${e.key}.${fe.key}: expected $want, got $got');
        }
      }
    }
  }
}

void _expectChildren(Harness h, KxCheck c, Map<String, dynamic> v) {
  for (final e in v.entries) {
    final kn = h.ids[e.key];
    if (kn == null) {
      c.fail('unknown node id "${e.key}"');
      continue;
    }
    final got = kn.liveItems?.call().length ?? kn.children.length;
    final want = math.max(0, intOf(e.value, 0));
    if (got != want) c.fail('children.${e.key}: expected $want, got $got');
  }
}

void _expectFirstItem(Harness h, KxCheck c, Map<String, dynamic> v) {
  for (final e in v.entries) {
    final kn = h.ids[e.key];
    if (kn == null) {
      c.fail('unknown node id "${e.key}"');
      continue;
    }
    final items = kn.liveItems?.call() ?? const <int>[];
    if (items.isEmpty) {
      c.fail('first_item.${e.key}: no live items');
      continue;
    }
    items.sort();
    final want = math.max(0, intOf(e.value, 0));
    if (items.first != want) {
      c.fail('first_item.${e.key}: expected $want, got ${items.first}');
    }
  }
}

void _expectNav(Harness h, KxCheck c, Map<String, dynamic> v) {
  final nv = h.nav;
  if (nv == null) {
    c.fail('nav expects require setup.navigator');
    return;
  }
  if (v['depth'] != null) {
    final want = math.max(0, intOf(v['depth'], 0));
    if (nv.depth != want) c.fail('nav.depth: expected $want, got ${nv.depth}');
  }
  if (v['current'] is String) {
    final got = nv.current?.route.path ?? '';
    if (got != v['current']) c.fail('nav.current: expected "${v['current']}", got "$got"');
  }
  if (v['params'] is Map) {
    final cur = nv.current;
    if (cur == null) {
      c.fail('nav.params: stack empty');
      return;
    }
    for (final e in (v['params'] as Map).entries) {
      final got = cur.route.params.get('${e.key}') ?? '';
      if (got != '${e.value}') {
        c.fail('nav.params.${e.key}: expected "${e.value}", got "$got"');
      }
    }
  }
}

Future<void> _checkExpect(Harness h, KxCheck c, String key, Object? v) async {
  switch (key) {
    case 'rects':
      if (v is Map) _expectRects(h, c, v.cast<String, dynamic>());
    case 'measured':
      if (v is Map) _expectMeasured(h, c, v.cast<String, dynamic>());
    case 'damage':
      _expectDamage(h, c, v);
    case 'focused':
      _expectFocused(h, c, v, false);
    case 'router_focused':
      _expectFocused(h, c, v, true);
    case 'focus_order':
      if (v is List) {
        final order = h.rootModel == null
            ? const <String>[]
            : focusOrderOf(h.rootModel!).map((n) => n.id).toList();
        _expectSeq(c, 'focus_order', v, order);
      }
    case 'gestures':
      if (v is List) _expectSeq(c, 'gestures', v, h.gestures);
    case 'events':
      if (v is List) _expectSeq(c, 'events', v, h.events);
    case 'effect_log':
      if (v is List) _expectSeq(c, 'effect_log', v, h.effectLog);
    case 'signals':
      if (v is Map) _expectSignals(h, c, v.cast<String, dynamic>());
    case 'memo_value':
      final m = h.memo;
      if (m == null) {
        c.fail('memo_value: no memo in setup');
      } else {
        final want = intOf(v, 0);
        if (m.get() != want) c.fail('memo_value: expected $want, got ${m.get()}');
      }
    case 'a11y':
      if (v is List) _expectA11y(h, c, v);
    case 'a11y_events':
      if (v is List) _expectA11yEvents(h, c, v);
    case 'text':
      if (v is Map) _expectText(h, c, v.cast<String, dynamic>());
    case 'i18n':
      if (v is Map) _expectI18n(h, c, v.cast<String, dynamic>());
    case 'pixels':
      if (v is List) await _expectPixels(h, c, v);
    case 'pixel_counts':
      if (v is List) await _expectPixelCounts(h, c, v);
    case 'scroll':
      if (v is Map) _expectScroll(h, c, v.cast<String, dynamic>());
    case 'scroll_info':
      if (v is Map) _expectScrollInfo(h, c, v.cast<String, dynamic>());
    case 'children':
      if (v is Map) _expectChildren(h, c, v.cast<String, dynamic>());
    case 'first_item':
      if (v is Map) _expectFirstItem(h, c, v.cast<String, dynamic>());
    case 'nav':
      if (v is Map) _expectNav(h, c, v.cast<String, dynamic>());
    case 'action_error':
      final want = strOf(v, '');
      final got = h.lastError ?? '';
      if (got != want) c.fail('action_error: expected "$want", got "$got"');
    default:
      c.fail('unknown expect key "$key"');
  }
}

// ---------------------------------------------------------------------------
// Vector runner
// ---------------------------------------------------------------------------

/// Runs one test vector end-to-end through the real Flutter pipeline.
Future<KxResult> runVector(WidgetTester tester, Map<String, dynamic> tv) async {
  final res = KxResult(
    id: strOf(tv['id'], '?'),
    domain: strOf(tv['domain'], '?'),
    rule: strOf(tv['rule'], ''),
  );
  final c = KxCheck(res.failures, numOf(tv['tolerance'], kDefaultTolerance));
  try {
    await _runVectorInner(tester, tv, c);
  } on KxError catch (e) {
    c.fail('error: ${e.name}');
  } catch (e) {
    c.fail('error: $e');
  }
  res.passed = res.failures.isEmpty;
  return res;
}

Future<void> _runVectorInner(WidgetTester tester, Map<String, dynamic> tv, KxCheck c) async {
  final h = Harness(tester);
  final setup = (tv['setup'] as Map?)?.cast<String, dynamic>() ?? const {};
  if (setup['viewport'] is List) {
    final vp = setup['viewport'] as List;
    h.viewport = Size(numOf(vp[0], 800), numOf(vp[1], 100));
  }
  _setupSignals(h, (setup['signals'] as Map?)?.cast<String, dynamic>() ?? const {});
  _setupI18n(h, (setup['i18n'] as Map?)?.cast<String, dynamic>());
  _setupNavigator(h, (setup['navigator'] as Map?)?.cast<String, dynamic>());
  _setupEffects(h, setup['effects'] as List?);
  _setupMemo(h, (setup['memo'] as Map?)?.cast<String, dynamic>());

  if (setup['tree'] is Map) {
    final tree = (setup['tree'] as Map).cast<String, dynamic>();
    final child = buildNode(h, tree, null, inSemanticTree: true);
    // ObjectKey(h): a fresh element tree per vector — otherwise Flutter
    // would reuse element slots across vectors and stale State objects
    // (signal subscriptions, controllers, gesture arenas bound to the
    // previous Harness) would leak into the next test.
    h.rootBuilder = () => KxRoot(key: ObjectKey(h), viewport: h.viewport, dir: h.i18n?.direction ?? KxDir.ltr, child: child);
    await tester.pumpWidget(h.rootBuilder!());
    await tester.pump();
    while (tester.takeException() != null) {}
    h.clearDamage(); // frame-0 boundary
  }

  if (tv['actions'] is List) {
    for (final av in tv['actions'] as List) {
      if (av is Map) await runAction(h, av.cast<String, dynamic>());
    }
  }

  final expect = tv['expect'];
  if (expect is Map) {
    for (final e in expect.entries) {
      await _checkExpect(h, c, e.key, e.value);
    }
  }

  // Release any pointers still down so the next vector starts clean.
  for (final pid in h.activePointers.toList()) {
    await _sendPointer(h, PointerCancelEvent(
      pointer: pid,
      position: h.lastPointerPos[pid] ?? Offset.zero,
      kind: PointerDeviceKind.touch,
    ));
  }
  h.activePointers.clear();
}
