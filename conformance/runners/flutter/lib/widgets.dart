/// DSL → Flutter widget mapping (conformance/SPEC.md §nodes).
///
/// The tree is built from stock Flutter widgets wherever a real equivalent
/// exists; custom leaves exist only where Klaxon's contract has no native
/// primitive (the simplified control paints Klaxon's *conformance* widgets
/// draw, exact-size gesture arena behavior, model-only virtualization
/// bookkeeping). Every approximation is documented in MAPPING.md.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/rendering.dart'
    show BoxParentData, RenderBox, RenderShiftedBox, ScrollCacheExtent;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';

import 'gestures.dart';
import 'harness.dart';
import 'i18n.dart' show KxDir, KxI18n;
import 'model.dart';
import 'state.dart';

// ---------------------------------------------------------------------------

Color parseColor(Object? v, [Color fallback = const Color(0xFFCCCCCC)]) {
  if (v is String && v.startsWith('#') && v.length == 9) {
    final n = int.tryParse(v.substring(1), radix: 16);
    if (n != null) {
      // DSL colors are #RRGGBBAA; Dart Color is AARRGGBB.
      return Color(((n & 0xFF) << 24) | (n >> 8));
    }
  }
  return fallback;
}

double numOf(Object? v, double dflt) => switch (v) {
      num n => n.toDouble(),
      _ => dflt,
    };

int intOf(Object? v, int dflt) => switch (v) {
      num n => n.toInt(),
      bool b => b ? 1 : 0,
      _ => dflt,
    };

bool boolOf(Object? v, bool dflt) => switch (v) {
      bool b => b,
      num n => n != 0,
      _ => dflt,
    };

String strOf(Object? v, String dflt) => v is String ? v : dflt;

Map<String, dynamic> propsOf(Map<String, dynamic> tv) =>
    (tv['props'] as Map?)?.cast<String, dynamic>() ?? const {};

List<Map<String, dynamic>> childrenOf(Map<String, dynamic> tv) =>
    ((tv['children'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

/// DSL `padding` may be a scalar, [l,t,r,b], or {left,top,right,bottom}.
EdgeInsets parseInsets(Object? v) => switch (v) {
      num n => EdgeInsets.all(n.toDouble()),
      List l => EdgeInsets.fromLTRB(numOf(l[0], 0), numOf(l[1], 0), numOf(l[2], 0), numOf(l[3], 0)),
      Map m => EdgeInsets.fromLTRB(
          numOf(m['left'], 0), numOf(m['top'], 0), numOf(m['right'], 0), numOf(m['bottom'], 0)),
      _ => EdgeInsets.zero,
    };

EdgeInsetsDirectional parseDirInsets(Map<String, dynamic> props) =>
    EdgeInsetsDirectional.fromSTEB(
      numOf(props['start'], 0),
      numOf(props['top'], 0),
      numOf(props['end'], 0),
      numOf(props['bottom'], 0),
    );

MainAxisAlignment parseMainAlign(String s) => switch (s) {
      'center' => MainAxisAlignment.center,
      'end' => MainAxisAlignment.end,
      'space_between' => MainAxisAlignment.spaceBetween,
      'space_around' => MainAxisAlignment.spaceAround,
      'space_evenly' => MainAxisAlignment.spaceEvenly,
      _ => MainAxisAlignment.start,
    };

CrossAxisAlignment parseCrossAlign(String s) => switch (s) {
      'start' => CrossAxisAlignment.start,
      'center' => CrossAxisAlignment.center,
      'end' => CrossAxisAlignment.end,
      _ => CrossAxisAlignment.stretch, // Klaxon default
    };

/// Klaxon Alignment is directional [x,y] (mirrored under RTL) —
/// `AlignmentDirectional` resolves exactly that.
AlignmentDirectional parseAlign(Object? v, [AlignmentDirectional dflt = AlignmentDirectional.topStart]) {
  if (v is List && v.length >= 2) {
    return AlignmentDirectional(numOf(v[0], -1), numOf(v[1], -1));
  }
  if (v is String) {
    return switch (v) {
      'top_left' || 'top_start' => AlignmentDirectional.topStart,
      'top_right' || 'top_end' => AlignmentDirectional.topEnd,
      'bottom_left' || 'bottom_start' => AlignmentDirectional.bottomStart,
      'bottom_right' || 'bottom_end' => AlignmentDirectional.bottomEnd,
      'top_center' => AlignmentDirectional.topCenter,
      'bottom_center' => AlignmentDirectional.bottomCenter,
      'center_start' || 'center_left' => AlignmentDirectional.centerStart,
      'center_end' || 'center_right' => AlignmentDirectional.centerEnd,
      _ => AlignmentDirectional.center,
    };
  }
  return dflt;
}

TextAlign parseTextAlign(String s) => switch (s) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      'start' => TextAlign.start,
      'end' => TextAlign.end,
      _ => TextAlign.left,
    };

// ---------------------------------------------------------------------------

/// Build the widget tree for one DSL node and register its model.
///
/// `inSemanticTree` tracks Klaxon's `exclude_semantics`/`visible` lifting so
/// real Focus widgets never offer a node the model skips.
Widget buildNode(Harness h, Map<String, dynamic> tv, KxNode? parent, {required bool inSemanticTree}) {
  final type = strOf(tv['type'], '');
  if (type.isEmpty) throw const KxError('MissingType');
  final id = strOf(tv['id'], '');
  final props = propsOf(tv);
  final kn = KxNode(type, id)
    ..parent = parent
    ..traversalSeq = h.buildSeq++; // document pre-order (before children)
  if (parent != null) parent.children.add(kn);
  h.rootModel ??= kn;
  // Universal props that shape the children's semantic visibility must be
  // known BEFORE recursing (Klaxon reads them during applyNodeProps, but its
  // children attach to the same node — lifting is evaluated at flatten time).
  kn.visible = boolOf(props['visible'], true);
  kn.excludeSemantics = boolOf(props['exclude_semantics'], false);
  kn.inSemanticTree = inSemanticTree && kn.visible && !kn.excludeSemantics;

  final List<Widget> builtChildren = [
    for (final c in childrenOf(tv)) buildNode(h, c, kn, inSemanticTree: kn.inSemanticTree),
  ];

  final Widget core = _buildCore(h, kn, props, builtChildren);
  return _applyNodeProps(h, kn, tv, id, props, core);
}

/// Klaxon `applyNodeProps`: flex/visible/damage_overflow/exclude_semantics,
/// prop semantics, the Focus+FocusTraversalOrder wrappers, and id registry.
Widget _applyNodeProps(Harness h, KxNode kn, Map<String, dynamic> tv, String id, Map<String, dynamic> props, Widget w) {
  // universal props
  if (props['visible'] != null) kn.visible = boolOf(props['visible'], true);
  kn.inSemanticTree = kn.inSemanticTree && kn.visible;
  if (props['damage_overflow'] is List) {
    final r = props['damage_overflow'] as List;
    kn.overflowL = numOf(r[0], 0);
    kn.overflowT = numOf(r[1], 0);
    kn.overflowR = numOf(r[2], 0);
    kn.overflowB = numOf(r[3], 0);
  }
  if (boolOf(props['exclude_semantics'], false)) kn.excludeSemantics = true;
  kn.inSemanticTree = kn.inSemanticTree && !kn.excludeSemantics;

  // merge prop semantics over the widget's own descriptor
  _attachPropSemantics(kn, props);

  // A Flexible (DSL `expanded`) must remain the outermost render-level
  // widget: Flex parent-data is only honored directly under a Flex, so all
  // prop wrappers go INSIDE it.
  Flexible? flexSlot;
  if (w is Flexible) {
    flexSlot = w;
    w = flexSlot.child;
  }

  // visibility (layout space retained, paint/hit/semantics skipped)
  if (!kn.visible) {
    w = Visibility(
      visible: false,
      maintainState: true,
      maintainSize: true,
      maintainAnimation: true,
      child: w,
    );
  }

  // focus + traversal (real Flutter focus; the model drives expectations).
  // Nodes that own their FocusNode (text_field) skip the Focus wrapper —
  // the node is attached by the widget's internal focus machinery instead.
  final focusable = kn.inSemanticTree && (kn.sem?.focusable ?? false);
  if (kn.sem != null || props['focusable'] != null || kn.ownsFocus) {
    if (kn.focusNode == null) kn.focusNode = FocusNode(debugLabel: 'kx:$id');
    if (!kn.ownsFocus) {
      w = Focus(
        focusNode: kn.focusNode,
        canRequestFocus: kn.sem?.focusable ?? false,
        skipTraversal: !focusable,
        child: w,
      );
    }
    if (focusable) {
      w = FocusTraversalOrder(order: NumericFocusOrder(kn.traversalSeq.toDouble()), child: w);
    }
  }

  if (id.isNotEmpty) {
    if (h.ids.containsKey(id)) throw const KxError('DuplicateId');
    h.ids[id] = kn;
    w = KeyedSubtree(key: ValueKey<String>(id), child: w);
  }

  if (flexSlot != null) {
    w = Flexible(flex: flexSlot.flex, fit: flexSlot.fit, child: w);
  }
  return w;
}

void _attachPropSemantics(KxNode kn, Map<String, dynamic> props) {
  final has = ['role', 'label', 'hint', 'value', 'checked', 'disabled', 'focusable', 'actions']
      .any((k) => props.containsKey(k));
  if (!has) return;
  final s = kn.sem ??= KxSem();
  if (props['role'] is String) kn.sem!.role = kxRoleOf(props['role']) ?? KxRole.none;
  if (props['label'] is String) s.label = props['label'];
  if (props['hint'] is String) s.hint = props['hint'];
  if (props['value'] is String) s.value = props['value'];
  if (props['checked'] != null) s.checked = boolOf(props['checked'], false);
  if (props['disabled'] != null) s.disabled = boolOf(props['disabled'], false);
  if (props['focusable'] != null) s.focusable = boolOf(props['focusable'], false);
  if (props['actions'] is List) {
    for (final a in props['actions'] as List) {
      if (a is String) {
        final act = kxActionOf(a);
        if (act != null) s.actions.add(act);
      }
    }
  }
}

// ---------------------------------------------------------------------------

Widget _buildCore(Harness h, KxNode kn, Map<String, dynamic> props, List<Widget> kids) {
  final id = kn.id;
  switch (kn.type) {
    case 'box':
      final w = numOf(props['w'], 0), ht = numOf(props['h'], 0);
      Widget child = SizedBox(
        width: w,
        height: ht,
        child: ColoredBox(color: parseColor(props['color'])),
      );
      if (boolOf(props['on_press'], false)) {
        child = KxPressRegion(
          onPress: () => h.events.add('press:$id'),
          child: child,
        );
      }
      return child;

    case 'text':
      final content = strOf(props['text'], '');
      kn.sem = KxSem()
        ..role = KxRole.text
        ..label = content;
      kn.readText = () => kn.sem!.label.isNotEmpty ? kn.sem!.label : kn.sem!.value;
      return Text(
        content,
        style: TextStyle(
          fontSize: numOf(props['size'], 16),
          color: parseColor(props['color'], const Color(0xFF000000)),
          fontWeight: boolOf(props['bold'], false) ? FontWeight.bold : FontWeight.normal,
        ),
        textAlign: parseTextAlign(strOf(props['text_align'], 'left')),
      );

    case 'row' || 'column':
      final isRow = kn.type == 'row';
      final main = parseMainAlign(strOf(props['main_align'], 'start'));
      final cross = parseCrossAlign(strOf(props['cross_align'], 'stretch'));
      final gap = numOf(props['gap'], 0);
      final pad = numOf(props['padding'], 0);
      // Klaxon flex measures each child against the container's *own* inner
      // extents ({main: inner_main, cross: cross_avail}) — the main axis is
      // never offered unbounded. RenderFlex instead leaves the child main
      // axis unconstrained (a stack-fit:expand child then tightens itself to
      // +∞ and asserts). The LayoutBuilder + per-child ConstrainedBox caps
      // reproduce Klaxon's offered main extent exactly.
      final body = LayoutBuilder(
        builder: (ctx, cons) {
          final cap = isRow
              ? BoxConstraints(maxWidth: cons.maxWidth)
              : BoxConstraints(maxHeight: cons.maxHeight);
          final capped = [
            for (final k in kids)
              k is Flexible ? k : ConstrainedBox(constraints: cap, child: k),
          ];
          Widget f = isRow
              ? Row(
                  spacing: gap,
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: main,
                  crossAxisAlignment: cross,
                  children: capped,
                )
              : Column(
                  spacing: gap,
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: main,
                  crossAxisAlignment: cross,
                  children: capped,
                );
          if (cross == CrossAxisAlignment.stretch &&
              !capped.any((k) => k is Flexible)) {
            // Klaxon stretch: child cross := the flex's cross extent, where
            // the flex's cross is the max measured child cross. RenderFlex
            // would tighten to the incoming max (asserting on ∞):
            // IntrinsicHeight/IntrinsicWidth resolves the intrinsic max.
            // (Skipped with flex children: Intrinsic* can't dry-layout
            // Expanded — see MAPPING.md §layout.)
            f = isRow
                ? IntrinsicHeight(child: f)
                : (cons.hasBoundedWidth ? f : IntrinsicWidth(child: f));
          }
          return f;
        },
      );
      return pad != 0 ? Padding(padding: EdgeInsets.all(pad), child: body) : body;

    case 'stack':
      return Stack(
        fit: strOf(props['fit'], 'loose') == 'expand' ? StackFit.expand : StackFit.loose,
        alignment: parseAlign(props['alignment']),
        children: kids,
      );

    case 'grid':
      return KxGrid(
        columns: intOf(props['columns'], 2),
        gap: numOf(props['gap'], 0),
        padding: numOf(props['padding'], 0),
        children: kids,
      );

    case 'padding':
      return KxTightPad(insets: parseInsets(props['padding']), child: kids.isEmpty ? null : kids.first);

    case 'padding_directional':
      return KxTightPad.directional(dirInsets: parseDirInsets(props), child: kids.isEmpty ? null : kids.first);

    case 'center':
      return Center(child: kids.isEmpty ? null : kids.first);

    case 'align':
      return Align(alignment: parseAlign(props['alignment'], AlignmentDirectional.center), child: kids.isEmpty ? null : kids.first);

    case 'constrained_box':
      return ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: numOf(props['min_w'], 0),
          minHeight: numOf(props['min_h'], 0),
          maxWidth: numOf(props['max_w'], double.infinity),
          maxHeight: numOf(props['max_h'], double.infinity),
        ),
        child: kids.isEmpty ? const SizedBox.shrink() : kids.first,
      );

    case 'expanded':
      return Expanded(
        flex: math.max(1, intOf(props['weight'], 1)),
        child: kids.isEmpty ? const SizedBox.shrink() : kids.first,
      );

    case 'container':
      return KxTightPad(
        insets: props['padding'] != null ? parseInsets(props['padding']) : EdgeInsets.zero,
        color: props.containsKey('color') ? parseColor(props['color']) : null,
        child: kids.isEmpty ? null : kids.first,
      );

    case 'button':
      kn.sem = KxSem()
        ..role = KxRole.button
        ..focusable = true
        ..actions.add(KxAction.activate);
      return KxButton(
        id: id,
        onPressed: () => h.events.add('press:$id'),
        child: kids.isEmpty ? null : kids.first,
      );

    case 'toggle':
      final sig = h.sigBoolOf(strOf(props['signal'], id), boolOf(props['checked'], false));
      kn.sem = KxSem()
        ..role = KxRole.toggle
        ..focusable = true
        ..checked = sig.peek()
        ..actions.add(KxAction.activate);
      return KxToggle(h: h, kn: kn, sig: sig, id: id);

    case 'checkbox':
      final sig = h.sigBoolOf(strOf(props['signal'], id), boolOf(props['checked'], false));
      kn.sem = KxSem()
        ..role = KxRole.checkbox
        ..focusable = true
        ..checked = sig.peek()
        ..actions.add(KxAction.activate);
      return KxCheckbox(h: h, kn: kn, sig: sig, id: id);

    case 'radio':
      final sig = h.sigInt(strOf(props['signal'], id), 0);
      final val = intOf(props['value'], 0);
      kn.sem = KxSem()
        ..role = KxRole.radio
        ..focusable = true
        ..checked = sig.peek() == val
        ..actions.add(KxAction.activate);
      return KxRadio(h: h, kn: kn, sig: sig, value: val);

    case 'slider':
      final sig = h.sigFloatOf(strOf(props['signal'], id), numOf(props['value'], 0.5));
      kn.sem = KxSem()
        ..role = KxRole.slider
        ..focusable = true
        ..value = '${(sig.peek().clamp(0.0, 1.0) * 100).round()}%'
        ..actions.addAll([KxAction.increment, KxAction.decrement]);
      return KxSlider(h: h, kn: kn, sig: sig, id: id, defaultWidth: numOf(props['width'], 200));

    case 'text_field':
      kn.ownsFocus = true;
      kn.focusNode = FocusNode(debugLabel: 'kx.tf:$id');
      kn.sem = KxSem()
        ..role = KxRole.text_field
        ..focusable = true
        ..hint = strOf(props['placeholder'], '');
      return KxTextField(h: h, kn: kn, id: id, props: props);

    case 'gesture_detector':
      return KxGesture(h: h, gestures: ((props['gestures'] as List?) ?? const []).whereType<String>().toSet());

    case 'scroll_view':
      return KxScrollView(h: h, kn: kn, wheelSpeed: numOf(props['wheel_speed'], 48), child: kids.isEmpty ? const SizedBox.shrink() : kids.first);

    case 'list_view':
      return KxListView(
        h: h,
        kn: kn,
        itemCount: intOf(props['item_count'], 0),
        itemHeight: numOf(props['item_height'], 48),
        gap: numOf(props['gap'], 0),
        margin: intOf(props['margin'], 2),
        wheelSpeed: numOf(props['wheel_speed'], 48),
        itemFocusable: boolOf(props['item_focusable'], false),
        itemPress: boolOf(props['item_press'], false),
      );

    case 'l10n_text':
      final i18n = h.i18n;
      if (i18n == null) throw const KxError('MissingI18n');
      kn.sem = KxSem()..role = KxRole.text;
      return KxL10nText(h: h, kn: kn, i18n: i18n, textKey: strOf(props['key'], ''), size: numOf(props['size'], 14));

    case 'l10n_plural':
      final i18n = h.i18n;
      if (i18n == null) throw const KxError('MissingI18n');
      kn.sem = KxSem()..role = KxRole.text;
      return KxL10nPlural(
        h: h,
        kn: kn,
        i18n: i18n,
        textKey: strOf(props['key'], ''),
        countSignalName: props['count_signal'] is String ? props['count_signal'] as String : null,
        count: intOf(props['count'], 0),
      );

    case 'navigator_view' || 'dropdown' || 'chip':
      // Declared in the DSL but unused by the corpus — see MAPPING.md.
      throw const KxError('UnknownType');

    default:
      throw const KxError('UnknownType');
  }
}

// ---------------------------------------------------------------------------
// Press region — Klaxon's on_pointer contract: down claims the pointer, a
// following up *inside the bounds* fires. A pure Listener + bounds check;
// deliberately NOT a TapGestureRecognizer (no Flutter arena semantics — a
// drag that returns inside still fires, exactly like Klaxon).
// ---------------------------------------------------------------------------

class KxPressRegion extends StatefulWidget {
  const KxPressRegion({super.key, required this.onPress, required this.child});
  final VoidCallback onPress;
  final Widget child;

  @override
  State<KxPressRegion> createState() => _KxPressRegionState();
}

class _KxPressRegionState extends State<KxPressRegion> {
  final Set<int> _down = {};

  bool _inside(PointerEvent e) {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return false;
    final p = e.localPosition;
    return p.dx >= 0 && p.dy >= 0 && p.dx <= ro.size.width && p.dy <= ro.size.height;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => _down.add(e.pointer),
      onPointerUp: (e) {
        if (_down.remove(e.pointer) && _inside(e)) widget.onPress();
      },
      onPointerCancel: (e) => _down.remove(e.pointer),
      child: widget.child,
    );
  }
}

// ---------------------------------------------------------------------------
// Button — Klaxon conformance button: rrect bg (0x3B5BDB, hover/press
// variants), padding 16/8, press → 'press:<id>' on up-inside.
// ---------------------------------------------------------------------------

class KxButton extends StatefulWidget {
  const KxButton({super.key, required this.id, required this.onPressed, this.child});
  final String id;
  final VoidCallback onPressed;
  final Widget? child;

  @override
  State<KxButton> createState() => _KxButtonState();
}

class _KxButtonState extends State<KxButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bg = _pressed ? const Color(0xFF364FC7) : const Color(0xFF3B5BDB);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (e) {
        setState(() => _pressed = false);
        final ro = context.findRenderObject();
        if (ro is RenderBox && ro.hasSize) {
          final p = e.localPosition;
          if (p.dx >= 0 && p.dy >= 0 && p.dx <= ro.size.width && p.dy <= ro.size.height) {
            widget.onPressed();
          }
        }
      },
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: DecoratedBox(
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: widget.child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Toggle — Klaxon conformance toggle: 44×24 (constrained to the constraint
// range, so a stretch parent widens it), pill track + knob, up-inside flips
// the signal, then fires change:<id>.
// ---------------------------------------------------------------------------

class _KxControlState<T extends StatefulWidget> extends State<T> {
  void bindSignal(KxSignalBase sig, void Function() onChange) {
    _sig = sig;
    _onChange = onChange;
    sig.subscribe(_fire);
  }

  late KxSignalBase _sig;
  late void Function() _onChange;

  void _fire() {
    _onChange();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sig.unsubscribe(_fire);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

class KxToggle extends StatefulWidget {
  const KxToggle({super.key, required this.h, required this.kn, required this.sig, required this.id});
  final Harness h;
  final KxNode kn;
  final KxSignal<bool> sig;
  final String id;

  @override
  State<KxToggle> createState() => _KxToggleState();
}

class _KxToggleState extends _KxControlState<KxToggle> {
  @override
  void initState() {
    super.initState();
    bindSignal(widget.sig.base, () {
      widget.kn.sem?.checked = widget.sig.peek();
      widget.h.a11yEvents.add(KxA11yEvent('control_changed', nodeId: widget.id));
    });
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints.tightFor(width: 44, height: 24),
      child: KxPressRegion(
        onPress: () {
          widget.sig.set(!widget.sig.peek());
          widget.h.events.add('change:${widget.id}');
        },
        child: CustomPaint(painter: _TogglePainter(on: widget.sig.peek())),
      ),
    );
  }
}

class _TogglePainter extends CustomPainter {
  _TogglePainter({required this.on});
  final bool on;
  @override
  void paint(Canvas canvas, Size size) {
    final b = Offset.zero & size;
    final track = Paint()..color = on ? const Color(0xFF3B5BDB) : const Color(0xFF444455);
    canvas.drawRRect(RRect.fromRectXY(b, size.height / 2, size.height / 2), track);
    final ks = size.height - 4;
    final kx = on ? size.width - ks - 2 : 2.0;
    canvas.drawRRect(
      RRect.fromRectXY(Rect.fromLTWH(kx, 2, ks, ks), ks / 2, ks / 2),
      Paint()..color = const Color(0xFFFFFFFF),
    );
  }

  @override
  bool shouldRepaint(_TogglePainter old) => old.on != on;
}

class KxCheckbox extends StatefulWidget {
  const KxCheckbox({super.key, required this.h, required this.kn, required this.sig, required this.id});
  final Harness h;
  final KxNode kn;
  final KxSignal<bool> sig;
  final String id;

  @override
  State<KxCheckbox> createState() => _KxCheckboxState();
}

class _KxCheckboxState extends _KxControlState<KxCheckbox> {
  @override
  void initState() {
    super.initState();
    bindSignal(widget.sig.base, () {
      widget.kn.sem?.checked = widget.sig.peek();
      widget.h.a11yEvents.add(KxA11yEvent('control_changed', nodeId: widget.id));
    });
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints.tightFor(width: 20, height: 20),
      child: KxPressRegion(
        onPress: () {
          widget.sig.set(!widget.sig.peek());
          widget.h.events.add('change:${widget.id}');
        },
        child: CustomPaint(painter: _CheckboxPainter(on: widget.sig.peek())),
      ),
    );
  }
}

class _CheckboxPainter extends CustomPainter {
  _CheckboxPainter({required this.on});
  final bool on;
  @override
  void paint(Canvas canvas, Size size) {
    final b = Offset.zero & size;
    if (on) {
      canvas.drawRRect(RRect.fromRectXY(b, 4, 4), Paint()..color = const Color(0xFF3B5BDB));
      // Klaxon paints a '✓' glyph; a check path is the same shape.
      final p = Path()
        ..moveTo(size.width * 0.28, size.height * 0.52)
        ..lineTo(size.width * 0.44, size.height * 0.68)
        ..lineTo(size.width * 0.74, size.height * 0.32);
      canvas.drawPath(
        p,
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    } else {
      canvas.drawRRect(RRect.fromRectXY(b, 4, 4), Paint()..color = const Color(0xFF555566));
      canvas.drawRRect(
        RRect.fromRectXY(b.deflate(2), 2, 2),
        Paint()..color = const Color(0xFF282838),
      );
    }
  }

  @override
  bool shouldRepaint(_CheckboxPainter old) => old.on != on;
}

class KxRadio extends StatefulWidget {
  const KxRadio({super.key, required this.h, required this.kn, required this.sig, required this.value});
  final Harness h;
  final KxNode kn;
  final KxSignal<int> sig;
  final int value;

  @override
  State<KxRadio> createState() => _KxRadioState();
}

class _KxRadioState extends _KxControlState<KxRadio> {
  @override
  void initState() {
    super.initState();
    bindSignal(widget.sig.base, () {
      widget.kn.sem?.checked = widget.sig.peek() == widget.value;
      widget.h.a11yEvents.add(KxA11yEvent('control_changed', nodeId: widget.kn.id));
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.sig.peek() == widget.value;
    return ConstrainedBox(
      constraints: const BoxConstraints.tightFor(width: 20, height: 20),
      child: KxPressRegion(
        onPress: () => widget.sig.set(widget.value),
        child: CustomPaint(
          painter: _RadioPainter(selected: selected),
        ),
      ),
    );
  }
}

class _RadioPainter extends CustomPainter {
  _RadioPainter({required this.selected});
  final bool selected;
  @override
  void paint(Canvas canvas, Size size) {
    final b = Offset.zero & size;
    canvas.drawRRect(RRect.fromRectXY(b, size.width / 2, size.width / 2), Paint()..color = const Color(0xFF555566));
    canvas.drawRRect(RRect.fromRectXY(b.deflate(2), (size.width - 4) / 2, (size.width - 4) / 2), Paint()..color = const Color(0xFF282838));
    if (selected) {
      canvas.drawRRect(RRect.fromRectXY(b.deflate(6), (size.width - 12) / 2, (size.width - 12) / 2), Paint()..color = const Color(0xFF3B5BDB));
    }
  }

  @override
  bool shouldRepaint(_RadioPainter old) => old.selected != selected;
}

// ---------------------------------------------------------------------------
// Slider — Klaxon conformance slider: h=24, w = max_w if bounded else
// default_width; down/move sets value = localX/w; arrows ±0.05 when focused.
// ---------------------------------------------------------------------------

class KxSlider extends StatefulWidget {
  const KxSlider({super.key, required this.h, required this.kn, required this.sig, required this.id, required this.defaultWidth});
  final Harness h;
  final KxNode kn;
  final KxSignal<double> sig;
  final String id;
  final double defaultWidth;

  @override
  State<KxSlider> createState() => _KxSliderState();
}

class _KxSliderState extends _KxControlState<KxSlider> {
  @override
  void initState() {
    super.initState();
    bindSignal(widget.sig.base, () {
      widget.kn.sem?.value = '${(widget.sig.peek().clamp(0.0, 1.0) * 100).round()}%';
      widget.h.a11yEvents.add(KxA11yEvent('control_changed', nodeId: widget.id));
    });
    widget.kn.onKey = _onKey; // Klaxon dispatches keys to the focused node
  }

  void _setFromLocal(double localX, double w) {
    widget.sig.set((localX / w).clamp(0.0, 1.0));
    widget.h.events.add('change:${widget.id}');
  }

  bool _onKey(String key, {bool shift = false}) {
    const step = 0.05;
    if (key == 'left' || key == 'down') {
      widget.sig.set((widget.sig.peek() - step).clamp(0.0, 1.0));
      widget.h.events.add('change:${widget.id}');
      return true;
    }
    if (key == 'right' || key == 'up') {
      widget.sig.set((widget.sig.peek() + step).clamp(0.0, 1.0));
      widget.h.events.add('change:${widget.id}');
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, cons) {
        final w = cons.hasBoundedWidth ? cons.maxWidth : widget.defaultWidth;
        return SizedBox(
          width: w,
          height: 24,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) => _setFromLocal(e.localPosition.dx, w),
            onPointerMove: (e) {
              // Klaxon sets on every move while the pointer is captured.
              if (e.buttons != 0) _setFromLocal(e.localPosition.dx, w);
            },
            child: CustomPaint(painter: _SliderPainter(v: widget.sig.peek().clamp(0.0, 1.0))),
          ),
        );
      },
    );
  }
}

class _SliderPainter extends CustomPainter {
  _SliderPainter({required this.v});
  final double v;
  @override
  void paint(Canvas canvas, Size size) {
    const trackH = 4.0;
    final ty = (size.height - trackH) / 2;
    canvas.drawRRect(
      RRect.fromRectXY(Rect.fromLTWH(0, ty, size.width, trackH), trackH / 2, trackH / 2),
      Paint()..color = const Color(0xFF444455),
    );
    canvas.drawRRect(
      RRect.fromRectXY(Rect.fromLTWH(0, ty, size.width * v, trackH), trackH / 2, trackH / 2),
      Paint()..color = const Color(0xFF3B5BDB),
    );
    const ks = 16.0;
    canvas.drawRRect(
      RRect.fromRectXY(Rect.fromLTWH(size.width * v - ks / 2, (size.height - ks) / 2, ks, ks), ks / 2, ks / 2),
      Paint()..color = const Color(0xFFFFFFFF),
    );
  }

  @override
  bool shouldRepaint(_SliderPainter old) => old.v != v;
}

// ---------------------------------------------------------------------------
// TextField — the real Flutter TextField (focus on tap, EditableText keys),
// sized like Klaxon's measure (text + padding), with Klaxon's event contract:
// text_input appends (whole burst or nothing), enter submits, escape blurs.
// ---------------------------------------------------------------------------

class KxTextField extends StatefulWidget {
  const KxTextField({super.key, required this.h, required this.kn, required this.id, required this.props});
  final Harness h;
  final KxNode kn;
  final String id;
  final Map<String, dynamic> props;

  @override
  State<KxTextField> createState() => _KxTextFieldState();
}

class _KxTextFieldState extends State<KxTextField> {
  late final TextEditingController _controller;

  FocusNode get _node => widget.kn.focusNode!;

  @override
  void initState() {
    super.initState();
    final initial = strOf(widget.props['initial'], '');
    if (initial.length > KxTextSignal.maxLen) throw const KxError('TextTooLong');
    _controller = TextEditingController(text: initial);
    widget.kn.sem?.value = initial;
    widget.kn.readText = () => _controller.text;
    widget.kn.textInput = _appendBurst;
    widget.kn.onKey = _onKey;
    _node.addListener(_syncModelFocus);
  }

  /// Real focus ↔ model focus (Klaxon keeps FocusManager == InputRouter.focused).
  void _syncModelFocus() {
    if (_node.hasFocus) {
      widget.h.setFocused(widget.kn, realFocus: false);
    } else if (identical(widget.h.focusedNode, widget.kn)) {
      widget.h.setFocused(null, realFocus: false);
    }
  }

  /// Klaxon `text_input`: append the whole burst (or reject when it would
  /// exceed the 1 MiB cap), update the semantic value, emit change:<id>.
  void _appendBurst(String burst) {
    if (_controller.text.length + burst.length > KxTextSignal.maxLen) return;
    final t = _controller.text + burst;
    _controller.value = TextEditingValue(
      text: t,
      selection: TextSelection.collapsed(offset: t.length),
    );
    widget.kn.sem?.value = t;
    widget.h.events.add('change:${widget.id}');
  }

  /// Klaxon key contract on a text field: backspace deletes, enter submits,
  /// escape blurs.
  bool _onKey(String key, {bool shift = false}) {
    switch (key) {
      case 'enter':
        widget.h.events.add('submit:${widget.id}');
        return true;
      case 'escape':
        _node.unfocus();
        return true;
      case 'backspace':
        final t = _controller.text;
        if (t.isNotEmpty) {
          _appendDelete();
        }
        return true;
    }
    return false;
  }

  void _appendDelete() {
    final t = _controller.text.substring(0, _controller.text.length - 1);
    _controller.value = TextEditingValue(
      text: t,
      selection: TextSelection.collapsed(offset: t.length),
    );
    widget.kn.sem?.value = t;
    widget.h.events.add('change:${widget.id}');
  }

  @override
  void dispose() {
    _node.removeListener(_syncModelFocus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = numOf(widget.props['size'], 16.0);
    final placeholder = strOf(widget.props['placeholder'], '');
    // Klaxon measure: text/placeholder extent + hPad(16)+2 × vPad(12).
    // Flutter metrics differ; paint asserts never cover the field.
    final tp = TextPainter(
      text: TextSpan(
        text: _controller.text.isNotEmpty ? _controller.text : placeholder,
        style: TextStyle(fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // EditableText (widgets layer — no Material dependency). The semantic
    // contract (value/change/submit/blur) is driven through kn.onKey +
    // kn.textInput; the editable widget supplies real focus-on-tap.
    return SizedBox(
      width: tp.width + 18,
      height: tp.height + 12,
      child: ColoredBox(
        color: const Color(0xFF282838),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          child: Stack(
            children: [
              if (_controller.text.isEmpty && placeholder.isNotEmpty)
                Text(placeholder,
                    style: TextStyle(color: const Color(0xFF777788), fontSize: size)),
              EditableText(
                focusNode: _node,
                controller: _controller,
                style: TextStyle(color: const Color(0xFFFFFFFF), fontSize: size),
                cursorColor: const Color(0xFFFFFFFF),
                backgroundCursorColor: const Color(0xFF666677),
                maxLines: 1,
                onChanged: (t) {
                  widget.kn.sem?.value = t;
                  widget.h.events.add('change:${widget.id}');
                },
                onSubmitted: (_) => widget.h.events.add('submit:${widget.id}'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Grid — fixed columns, equal track widths, row heights = row maxima.
// Column of IntrinsicHeight+stretch Rows reproduces Klaxon's fixed grid.
// ---------------------------------------------------------------------------

class KxGrid extends StatelessWidget {
  const KxGrid({super.key, required this.columns, required this.gap, required this.padding, required this.children});
  final int columns;
  final double gap;
  final double padding;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cols = columns.clamp(1, 64);
    return LayoutBuilder(
      builder: (ctx, cons) {
        // Klaxon: fixed track width = (W − (cols−1)·gap)/cols; a short last
        // row keeps its track positions (does NOT redistribute).
        final track = cons.hasBoundedWidth
            ? (cons.maxWidth - (cols - 1) * gap) / cols
            : 0.0;
        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += cols) {
          final rowKids = <Widget>[];
          for (var j = i; j < math.min(i + cols, children.length); j++) {
            rowKids.add(SizedBox(width: track, child: children[j]));
          }
          rows.add(IntrinsicHeight(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: gap,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rowKids,
            ),
          ));
        }
        Widget grid = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: gap,
          children: rows,
        );
        if (padding != 0) grid = Padding(padding: EdgeInsets.all(padding), child: grid);
        return grid;
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Gesture detector — a faithful port of the Klaxon GestureArena (see
// gestures.dart) fed by raw Listener events and the harness's virtual clock.
// Stock Flutter recognizers cannot express the contract (see MAPPING.md).
// ---------------------------------------------------------------------------

class KxGesture extends StatefulWidget {
  const KxGesture({super.key, required this.h, required this.gestures});
  final Harness h;
  final Set<String> gestures;

  @override
  State<KxGesture> createState() => _KxGestureState();
}

class _KxGestureState extends State<KxGesture> {
  late final KxGestureArena _arena;

  @override
  void initState() {
    super.initState();
    _arena = KxGestureArena(widget.gestures, (name) => widget.h.gestures.add(name));
    widget.h.gestureArenas.add(_arena); // `tick` ops advance long-press clocks
  }

  @override
  void dispose() {
    widget.h.gestureArenas.remove(_arena);
    super.dispose();
  }

  void _feed(PointerEvent e) {
    final phase = switch (e) {
      PointerDownEvent() => 'down',
      PointerMoveEvent() => 'move',
      PointerUpEvent() => 'up',
      PointerCancelEvent() => 'cancel',
      _ => null,
    };
    if (phase == null) return;
    _arena.feed(KxPEvent(phase, e.position.dx, e.position.dy, widget.h.nowMs, e.pointer));
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _feed,
      onPointerMove: _feed,
      onPointerUp: _feed,
      onPointerCancel: _feed,
      child: const SizedBox.expand(),
    );
  }
}

// ---------------------------------------------------------------------------
// Tight padding/container — Klaxon assigns the child the *content rect*
// (tight), unlike Flutter's Padding which passes loose constraints. A
// LayoutBuilder + SizedBox reproduces it exactly (PAINT-007 proves it: a
// 0×0 `inner` fills the padded content area).
// ---------------------------------------------------------------------------

class KxTightPad extends StatelessWidget {
  const KxTightPad({super.key, this.insets, this.dirInsets, this.color, this.child});

  const KxTightPad.directional({Key? key, required EdgeInsetsDirectional dirInsets, Widget? child})
      : this(key: key, dirInsets: dirInsets, child: child);

  final EdgeInsets? insets;
  final EdgeInsetsDirectional? dirInsets;
  final Color? color;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final resolved = insets ?? dirInsets!.resolve(Directionality.of(context));
    Widget inner = _KxPadBox(
      insets: resolved,
      child: child ?? const SizedBox.shrink(),
    );
    if (color != null) inner = ColoredBox(color: color!, child: inner);
    return inner;
  }
}

/// Klaxon padding/container layout — two phases:
///   measure: child measured at `constraints.deflate(insets)` (loose);
///   assign:  bounds = constrain(measured + insets); the child is then
///            assigned the *tight* content rect `bounds − insets`.
/// Plain Padding can't express this (it always passes loose constraints),
/// so this is a real render object.
class _KxPadBox extends SingleChildRenderObjectWidget {
  const _KxPadBox({required this.insets, required super.child});
  final EdgeInsets insets;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderKxPadBox(insets);

  @override
  void updateRenderObject(BuildContext context, _RenderKxPadBox ro) {
    ro.insets = insets;
  }
}

class _RenderKxPadBox extends RenderShiftedBox {
  _RenderKxPadBox(this._insets) : super(null);

  EdgeInsets _insets;
  EdgeInsets get insets => _insets;
  set insets(EdgeInsets v) {
    if (v == _insets) return;
    _insets = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    // 1. measure at the deflated (loose) constraints
    child.layout(constraints.deflate(_insets), parentUsesSize: true);
    final measured = child.size;
    // 2. own bounds = constrain(measured + insets)
    size = constraints.constrain(Size(
      measured.width + _insets.horizontal,
      measured.height + _insets.vertical,
    ));
    // 3. assign the child the tight content rect bounds − insets
    final cw = math.max(0.0, size.width - _insets.horizontal);
    final ch = math.max(0.0, size.height - _insets.vertical);
    if (child.size.width != cw || child.size.height != ch) {
      child.layout(BoxConstraints.tight(Size(cw, ch)));
    }
    (child.parentData! as BoxParentData).offset = Offset(_insets.left, _insets.top);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final measured = child.getDryLayout(constraints.deflate(_insets));
    return constraints.constrain(Size(
      measured.width + _insets.horizontal,
      measured.height + _insets.vertical,
    ));
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      (child?.computeMinIntrinsicWidth(height) ?? 0) + _insets.horizontal;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      (child?.computeMaxIntrinsicWidth(height) ?? 0) + _insets.horizontal;

  @override
  double computeMinIntrinsicHeight(double width) =>
      (child?.computeMinIntrinsicHeight(width) ?? 0) + _insets.vertical;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      (child?.computeMaxIntrinsicHeight(width) ?? 0) + _insets.vertical;
}

// ---------------------------------------------------------------------------
// Scrollables — Klaxon's ScrollInput is a *raw-delta* model: no touch slop,
// no fling, per-pointer tracks in window space. Flutter's Scrollable owns the
// real position/extents; the deltas are applied via a Listener (the same
// bubbling path Klaxon uses — items claim taps, the scrollable sees the move).
// ---------------------------------------------------------------------------

class _KxScrollInput extends StatefulWidget {
  const _KxScrollInput({required this.controller, required this.wheelSpeed, required this.child});
  final ScrollController controller;
  final double wheelSpeed;
  final Widget child;

  @override
  State<_KxScrollInput> createState() => _KxScrollInputState();
}

class _KxScrollInputState extends State<_KxScrollInput> {
  final Map<int, double> _tracks = {}; // pointer → last window-space y

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => _tracks[e.pointer] = e.position.dy,
      onPointerMove: (e) {
        final last = _tracks[e.pointer];
        _tracks[e.pointer] = e.position.dy;
        if (last == null) return; // hover move (no capture) — never scrolls
        final dy = e.position.dy - last;
        if (dy == 0) return;
        final pos = widget.controller.position;
        // finger up (dy<0) → offset increases; content follows the finger
        pos.jumpTo((pos.pixels - dy).clamp(0.0, pos.maxScrollExtent));
      },
      onPointerUp: (e) => _tracks.remove(e.pointer),
      onPointerCancel: (e) => _tracks.remove(e.pointer),
      onPointerSignal: (e) {
        // Klaxon ScrollInput.on_scroll: offset -= delta_y * wheel_speed.
        // The scrollable's own wheel handling is disabled (_kxPhysics), so
        // this Listener is the only consumer on the hit path.
        if (e is PointerScrollEvent) {
          final pos = widget.controller.position;
          if (!pos.hasContentDimensions || pos.maxScrollExtent <= 0) return; // unscrollable ignores wheel
          pos.jumpTo((pos.pixels - e.scrollDelta.dy * widget.wheelSpeed).clamp(0.0, pos.maxScrollExtent));
        }
      },
      child: widget.child,
    );
  }
}

/// The scrollable's own gesture/drag/wheel machinery is disabled entirely —
/// `_KxScrollInput` (a raw Listener) owns every offset change with Klaxon's
/// raw-delta semantics (no slop, no fling, no bounce). `shouldAcceptUserOffset`
/// = false also keeps the framework's wheel handler from double-applying.
const _kxPhysics = NeverScrollableScrollPhysics();

class KxScrollView extends StatefulWidget {
  const KxScrollView({super.key, required this.h, required this.kn, required this.wheelSpeed, required this.child});
  final Harness h;
  final KxNode kn;
  final double wheelSpeed;
  final Widget child;

  @override
  State<KxScrollView> createState() => _KxScrollViewState();
}

class _KxScrollViewState extends State<KxScrollView> {
  final ScrollController _controller = ScrollController();
  final GlobalKey _contentKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    widget.kn.setScrollOffset = (v) {
      if (!_controller.hasClients) return;
      final pos = _controller.position;
      pos.jumpTo(v.clamp(0.0, pos.maxScrollExtent));
    };
    widget.kn.scrollOffset = () => _controller.hasClients ? _controller.offset : 0;
    widget.kn.scrollInfo = () => _info();
  }

  Map<String, double> _info() {
    if (!_controller.hasClients) {
      return {'offset': 0, 'max_offset': 0, 'viewport': 0, 'content': 0, 'thumb': 0};
    }
    final pos = _controller.position;
    final viewport = pos.viewportDimension;
    // Klaxon content = the content node's real extent — the render of the
    // wrapped child (maxScrollExtent+viewport is wrong when content fits).
    final content = (_contentKey.currentContext?.findRenderObject() as RenderBox?)
            ?.size.height ??
        (pos.extentBefore + pos.extentInside + pos.extentAfter);
    return {
      'offset': pos.pixels,
      'max_offset': pos.maxScrollExtent,
      'viewport': viewport,
      'content': content,
      'thumb': content > 0 ? (viewport / content).clamp(0.05, 1.0) : 0,
    };
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _KxScrollInput(
      controller: _controller,
      wheelSpeed: widget.wheelSpeed,
      child: SingleChildScrollView(
        controller: _controller,
        physics: _kxPhysics,
        // Klaxon lays the child out at the viewport width (tight), natural
        // height — LayoutBuilder forces the cross extent like bounds.w.
        child: LayoutBuilder(
          builder: (ctx, cons) => ConstrainedBox(
            constraints: BoxConstraints(minWidth: cons.maxWidth),
            child: KeyedSubtree(key: _contentKey, child: widget.child),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ListView — Klaxon's virtualized list: fixed item height + stride (incl.
// gap), visible window ± margin items, per-index item ids, in-place count
// updates. `itemExtent = stride` makes Flutter's window math identical;
// cacheExtent = margin × stride covers the margin on each side.
// ---------------------------------------------------------------------------

class KxListView extends StatefulWidget {
  const KxListView({
    super.key,
    required this.h,
    required this.kn,
    required this.itemCount,
    required this.itemHeight,
    required this.gap,
    required this.margin,
    required this.wheelSpeed,
    required this.itemFocusable,
    required this.itemPress,
  });
  final Harness h;
  final KxNode kn;
  final int itemCount;
  final double itemHeight;
  final double gap;
  final int margin;
  final double wheelSpeed;
  final bool itemFocusable;
  final bool itemPress;

  @override
  State<KxListView> createState() => KxListViewState();
}

/// The materialized item — registered under "<list>.item<i>" while live.
class KxListItem extends StatelessWidget {
  const KxListItem({super.key, required this.listId, required this.index, required this.focusable, required this.onPress});
  final String listId;
  final int index;
  final bool focusable;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    const palette = [Color(0xFFFF0000), Color(0xFF00FF00), Color(0xFF0000FF)];
    Widget w = ColoredBox(color: palette[index % 3]);
    if (onPress != null) w = KxPressRegion(onPress: onPress!, child: w);
    if (focusable) {
      w = Focus(canRequestFocus: true, child: w);
    }
    return KeyedSubtree(key: ValueKey<String>('$listId.item$index'), child: w);
  }
}

class KxListViewState extends State<KxListView> {
  final ScrollController _controller = ScrollController();
  late int _count = widget.itemCount;

  double get _stride => widget.itemHeight + widget.gap;

  @override
  void initState() {
    super.initState();
    widget.kn.setScrollOffset = (v) {
      if (!_controller.hasClients) return;
      final pos = _controller.position;
      pos.jumpTo(v.clamp(0.0, pos.maxScrollExtent));
    };
    widget.kn.scrollOffset = () => _controller.hasClients ? _controller.offset : 0;
    widget.kn.scrollInfo = () => _info();
    widget.kn.setItemCount = (c) => setState(() => _count = c);
    widget.kn.reloadItems = () => setState(() {});
    widget.kn.liveItems = () => _liveIndices();
  }

  Map<String, double> _info() {
    if (!_controller.hasClients) {
      return {'offset': 0, 'max_offset': 0, 'viewport': 0, 'content': 0, 'thumb': 0};
    }
    final pos = _controller.position;
    final viewport = pos.viewportDimension;
    // Klaxon content extent = item_count·item_height + (count−1)·gap —
    // computed from the model, not the render extents (an under-filled
    // list reports a content smaller than the viewport).
    final content = _count <= 0
        ? 0.0
        : _count * widget.itemHeight + (_count - 1) * widget.gap;
    return {
      'offset': pos.pixels,
      'max_offset': pos.maxScrollExtent,
      'viewport': viewport,
      'content': content,
      'thumb': content > 0 ? (viewport / content).clamp(0.05, 1.0) : 0,
    };
  }

  List<int> _liveIndices() {
    final out = <int>[];
    void visit(Element e) {
      final w = e.widget;
      if (w is KxListItem && w.listId == widget.kn.id) out.add(w.index);
      e.visitChildren(visit);
    }
    (context as Element).visitChildElements(visit);
    return out;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _item(BuildContext ctx, int index) {
    final focusable = widget.itemFocusable;
    VoidCallback? press;
    if (widget.itemPress) press = () => widget.h.events.add('press:${widget.kn.id}.item$index');
    Widget cell = KxListItem(
      listId: widget.kn.id,
      index: index,
      focusable: focusable,
      onPress: press,
    );
    if (widget.gap > 0) {
      // Klaxon stride = item_height + gap; the item sits at the cell top.
      cell = Align(
        alignment: Alignment.topCenter,
        child: SizedBox(height: widget.itemHeight, child: cell),
      );
    }
    return cell;
  }

  @override
  Widget build(BuildContext context) {
    return _KxScrollInput(
      controller: _controller,
      wheelSpeed: widget.wheelSpeed,
      child: ListView.builder(
        controller: _controller,
        physics: _kxPhysics,
        itemExtent: _stride,
        scrollCacheExtent: ScrollCacheExtent.pixels(widget.margin * _stride),
        itemCount: _count,
        itemBuilder: _item,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Localized text — resolves via the ported I18n; subscribes to the locale
// signal (and the count signal) like Klaxon's l10n widgets.
// ---------------------------------------------------------------------------

class KxL10nText extends StatefulWidget {
  const KxL10nText({super.key, required this.h, required this.kn, required this.i18n, required this.textKey, required this.size});
  final Harness h;
  final KxNode kn;
  final KxI18n i18n;
  final String textKey;
  final double size;

  @override
  State<KxL10nText> createState() => _KxL10nTextState();
}

class _KxL10nTextState extends State<KxL10nText> {
  @override
  void initState() {
    super.initState();
    _resolve();
    widget.i18n.localeSig.base.subscribe(_onLocale);
  }

  void _onLocale() {
    _resolve();
    if (mounted) setState(() {});
  }

  void _resolve() {
    final t = widget.i18n.tr(widget.textKey);
    widget.kn.sem?.label = t;
    widget.kn.readText = () => widget.kn.sem?.label ?? '';
  }

  @override
  void dispose() {
    widget.i18n.localeSig.base.unsubscribe(_onLocale);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(widget.i18n.tr(widget.textKey), style: TextStyle(fontSize: widget.size));
  }
}

class KxL10nPlural extends StatefulWidget {
  const KxL10nPlural({super.key, required this.h, required this.kn, required this.i18n, required this.textKey, this.countSignalName, required this.count});
  final Harness h;
  final KxNode kn;
  final KxI18n i18n;
  final String textKey;
  final String? countSignalName;
  final int count;

  @override
  State<KxL10nPlural> createState() => _KxL10nPluralState();
}

class _KxL10nPluralState extends State<KxL10nPlural> {
  KxSignal<int>? _countSig;

  @override
  void initState() {
    super.initState();
    final name = widget.countSignalName;
    if (name != null) _countSig = widget.h.sigInt(name, widget.count);
    _resolve();
    widget.i18n.localeSig.base.subscribe(_rebuild);
    _countSig?.base.subscribe(_rebuild);
  }

  int get _count => _countSig?.peek() ?? widget.count;

  void _rebuild() {
    _resolve();
    if (mounted) setState(() {});
  }

  void _resolve() {
    final t = widget.i18n.trPlural(widget.textKey, _count);
    widget.kn.sem?.label = t;
    widget.kn.readText = () => widget.kn.sem?.label ?? '';
  }

  @override
  void dispose() {
    widget.i18n.localeSig.base.unsubscribe(_rebuild);
    _countSig?.base.unsubscribe(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(widget.i18n.trPlural(widget.textKey, _count));
  }
}

// ---------------------------------------------------------------------------
// Root scaffold — the Klaxon "frame": black background, viewport-sized
// content, RepaintBoundary for raster readback, direction + traversal wiring.
// ---------------------------------------------------------------------------

class KxRoot extends StatelessWidget {
  const KxRoot({super.key, required this.viewport, required this.dir, required this.child});
  final Size viewport;
  final KxDir dir;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: viewport.width,
        height: viewport.height,
        // The RepaintBoundary is exactly the viewport — raster readback is
        // 1:1 with Klaxon's golden frame (bg black fills the viewport).
        child: RepaintBoundary(
          key: const ValueKey<String>('kx.frame'),
          child: ColoredBox(
            color: const Color(0xFF000000),
            child: Directionality(
              textDirection: dir == KxDir.rtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(secondary: ReadingOrderTraversalPolicy()),
                child: Shortcuts(
                  shortcuts: const <ShortcutActivator, Intent>{
                    SingleActivator(LogicalKeyboardKey.tab): NextFocusIntent(),
                    SingleActivator(LogicalKeyboardKey.tab, shift: true): PreviousFocusIntent(),
                  },
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      NextFocusIntent: NextFocusAction(),
                      PreviousFocusIntent: PreviousFocusAction(),
                    },
                    child: SizedBox.expand(child: child),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
