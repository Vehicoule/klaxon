# Flutter adapter — DSL → Flutter mapping

Dart port of `src/conformance.zig` + `src/conformance_main.zig` running on
**Flutter 3.47 (Dart 3.13)** under **`flutter test`** — a real widget
tree, real `RenderObject` layout/paint, real pointer-event dispatch —
headless, no GPU, deterministic virtual time.

```
conformance/runners/flutter/
  pubspec.yaml            flutter_test-only package (no app target)
  lib/
    state.dart            KxSignal/KxTextSignal/KxEffect/KxMemo
                          (src/ui/state.zig)
    i18n.dart             ARB tables, plurals, number/date formatting,
                          direction (src/ui/i18n.zig)
    nav.dart              routes, paths, page stack, back
                          (src/ui/navigator.zig)
    gestures.dart         KxGestureArena: tap/double/long-press/pan/
                          swipe/pinch/rotate (src/ui/gestures.zig)
    model.dart            KxNode tree + KxSem observability model:
                          semantic flatten, focus order, damage,
                          scroll info, list materialization
    harness.dart          KxHarness: viewport, virtual clock,
                          registries, logs, focus, damage
    widgets.dart          DSL type → Flutter widget builders + the
                          custom render objects the DSL contract needs
    runner.dart           vector setup, action replay, expectation
                          checks, report model (src/conformance.zig)
  test/
    conformance_test.dart corpus loader, domain order, console
                          summary, JSON report
                          (src/conformance_main.zig)
```

## Architecture: real Flutter + observability model

Unlike the Compose adapter (which re-implements the whole layout engine
and uses Compose for pixels only), this adapter builds the tree with
**real Flutter widgets** — `Row`/`Column`/`Stack`/`Align`/
`SingleChildScrollView`/`ListView`/`EditableText` are what measure,
place, clip and paint. Flutter's layout pass computes every asserted
`rect`/`measured` value; `paint` vectors read pixels off a real raster
snapshot.

Where the DSL contract has no Flutter-equivalent observable (damage
rects, the semantic flattening the vectors assert, list
materialization counts, Klaxon's gesture-arena arbitration), a parallel
`KxNode`/`KxSem` model — a faithful port of the reference — is the
observability surface. Each widget registers/updates its model node in
its `build`/`State` lifecycle, so the model always mirrors the real
tree.

| Concern          | Mapping |
|------------------|---------|
| Tree             | One DSL node → one Flutter widget (`KeyedSubtree(ValueKey(id))`); parallel `KxNode` updated in `build` |
| Layout           | Real `RenderFlex`/`RenderStack`/`RenderPositionedBox`/`RenderConstrainedBox`; custom `RenderKxPadBox`/`RenderKxGrid` where the DSL contract diverges (below) |
| Pixels           | Root wrapped in `RepaintBoundary`; `toImage` + `getBytes` RGBA readback → real framework raster |
| Pointer input    | `WidgetTester.sendEventToBinding(PointerDown/Move/Up)` with `timeStamp` from the vector's virtual clock; widgets receive them through a `Listener` |
| Gestures         | `KxGestureArena` port fed by the raw `Listener` — **not** Flutter's `GestureRecognizer`s (see *Gesture arbitration* below) |
| Scrolling        | Real `SingleChildScrollView` / `ListView.builder` + `ScrollController`; wheel deltas injected via `Listener.onPointerSignal`-equivalent raw path with `NeverScrollableScrollPhysics`-style clamped setters |
| Text fields      | Real `EditableText` + `TextEditingController` (widgets layer — no Material dependency); focus + IME text exercised for real |
| Signals/effects  | `KxSignal` port; `set` marks the owning `KxNode` dirty and schedules a `setState` on the subscribed `State` → real rebuild next `pump` |
| Focus            | Real `Focus`/`FocusNode` for `text_field`; the asserted focus ring/order is the model's port of `FocusManager` |
| Semantics/a11y   | Model `KxSem` flatten (port of `src/ui/semantics.zig`) — Flutter's `SemanticsNode` tree is not the asserted surface |
| Damage           | Model accumulator — Flutter exposes no dirty-rect API; rects unioned in root space, same math as the reference |
| i18n / navigation| `I18n`/`KxNav` ports — framework-neutral subsystems |
| Clock            | `KxHarness.nowMs` virtual ms; `tick` actions advance it and drive `KxGestureArena.tick` (long-press fires at exactly 500 ms) |

## DSL type → widget mapping

| DSL `type` | Flutter mapping |
|------------|-----------------|
| `column`, `row` | `Column`/`Row` with `mainAxis`/`crossAxis` alignments; `gap` via padded child wrappers; `padding` via `KxTightPad` |
| `expanded` | `Expanded(flex: weight)` |
| `stack` | `Stack(fit: StackFit.loose/expand)` + `Align`/`Positioned` per `alignment` |
| `grid` | Custom `RenderKxGrid` — Klaxon tracks are *fixed* fractions of the container, not Flutter's `GridView` tiles |
| `padding` | `KxTightPad` → `RenderKxPadBox` (`RenderShiftedBox`): measures the child, then assigns tight size child+padding and offsets it — Klaxon's two-phase measure/assign, which `RenderPadding` approximates but doesn't offset |
| `padding_directional` | Same render object, edge insets resolved under ambient `Directionality` |
| `center`, `align` | `Center` / `Align(alignment)` |
| `constrained_box` | `ConstrainedBox(BoxConstraints(min/max))` |
| `container` | `Container(color, padding)` — real paint |
| `text`, `l10n_text`, `l10n_plural` | `Text`/`RichText` fed by the `I18n` resolver; direction propagated via `Directionality` |
| `button` | `KxButton` — `Listener` + model press log `press:<id>` |
| `toggle`, `checkbox`, `radio`, `slider` | Custom controls (`KxToggle`/`KxCheckbox`/`KxRadio`/`KxSlider`) — Klaxon semantics (signal write + `control_changed` + `checked` semantics) differ from Material widgets; real hit-testing/paint still apply |
| `text_field` | `EditableText` + `Focus` — real IME-style `text_input` bursts and key events; `initial`/`placeholder` honored |
| `gesture_detector` | `KxPressRegion` — `Listener` + `KxGestureArena` subscription for the declared `gestures` subset |
| `scroll_view` | `SingleChildScrollView` + `ScrollController` (vertical) |
| `list_view` | `ListView.builder` + `ScrollController`; materialized-item count read back from the viewport |
| `navigator_view` | Model `KxNav` — declared routes rendered as the current page's subtree |

## Gesture arbitration — why not `GestureRecognizer`

The DSL gesture contract **is** the reference arena
(`src/ui/gestures.zig`), and Flutter's stock recognizers encode a
different one:

| Contract | Klaxon (DSL) | Flutter stock |
|----------|--------------|-----------------|
| Slop | 12 px | `kTouchSlop` 18 / `kPanSlop` 36 |
| Tap timeout | 200 ms | `kPressTimeout` 100 ms |
| Double-tap window | 300 ms | `kDoubleTapTimeout` 300 ms |
| Long press | 500 ms, fired by a `tick` on the virtual clock | `kLongPressTimeout` 500 ms on real time |
| Two-finger | pinch/rotate processed **before** single-pointer recognizers and suppress competitors | separate recognizers in one arena |
| Dispatch | per-callback: a swipe recognizer's internal pan events are *not* emitted as `pan_*` | pan callbacks fire during a swipe recognizer's motion |

Because the vectors assert the reference arbitration exactly (and long
press must fire on *virtual* time), `widgets.dart` feeds raw pointer
events through `Listener` into `KxGestureArena` — a direct port —
rather than wiring `GestureDetector` recognizers.

## Deterministic globals

- **Clock**: `h.nowMs` — `tick` actions advance it; pointer
  `timeStamp`s and long-press use it exclusively.
- **Fresh identity per vector**: the root widget is keyed
  `ObjectKey(h)` so each vector gets a fresh element tree — no
  `State`/`ScrollController`/arena/focus leaks between vectors
  (this was the fix for the a11y/text-field/scroll stale-state
  failures seen mid-development).
- **Overflow**: Klaxon clips overflow rather than erroring; the
  adapter drains `FlutterError`s raised by debug-mode
  `RenderFlex`-overflow asserts after every `pump` so they never fail
  a vector.
- **Tolerance**: `0.01` default, per-vector override, identical to the
  reference.

## Unsupported behavior and limitations

1. **Flutter's own gesture/focus/a11y pipelines are not the asserted
   surface.** Gesture arbitration, the focus ring's traversal, and the
   semantic flatten are computed by the Dart ports of the reference and
   *driven* by real Flutter input/rendering. What is genuinely Flutter:
   the widget tree, the layout pass, clipping, rasterization, text
   shaping, `EditableText`, and `Scrollable` physics.
2. **Damage is model-side.** Flutter exposes no dirty-rect scheduler;
   `damage` expectations are answered from the model's root-space
   accumulator (same union math as the reference).
3. **A11y is the model tree.** `KxSem` flatten is a port of
   `src/ui/semantics.zig`; Flutter's `SemanticsNode` tree is not
   consulted — asserting against it would test Flutter's accessibility
   contract, not the DSL's.
4. **Flex cross-stretch approximation.** Klaxon assigns measured-size
   bounds then stretches children to the container cross axis; this is
   mapped with `LayoutBuilder` + `ConstrainedBox` caps +
   `IntrinsicWidth`/`IntrinsicHeight`. The combination of `Expanded`
   children *and* cross-stretch under an **unbounded** cross
   constraint falls back to `RenderFlex` stretch — the corpus does not
   cover that corner.
5. **Pointer `enter`/`leave`/`hover` phases** map to arena cancel only;
   the corpus exercises none.
6. **Unused DSL types** (`dropdown`, `chip`) have no builder and would
   report `UnknownType`, matching the reference for uncovered types.
7. **Text metrics** come from Flutter's text stack, not the
   reference's font file; the corpus asserts DSL-level measure/text
   contracts that hold under it. A host without a default Latin font
   would fail `text` vectors honestly.
8. **Headless**: `flutter test` on macOS-arm64. Pixels come from the
   `RepaintBoundary` raster snapshot — rasterizer-deterministic.
   Impeller vs Skia backend is irrelevant to the asserted RGBA values.
9. **`scroll_info.content`** reports Klaxon's content-extent contract
   (port), not Flutter's `ScrollMetrics.maxScrollExtent` + viewport —
   the two differ under overscroll/physics.

## Test plan

```bash
cd conformance/runners/flutter
flutter pub get
flutter test          # full corpus → console summary +
                      # ../../results/flutter/results-<ts>.json
flutter analyze       # clean
```

Report shape is identical to the reference/compose runners
(`framework: "flutter"`, `version: "p0"`): `score_pct`,
`by_domain` tallies, per-test `id/domain/rule/passed/failures`,
plus `viewport`, `tests`, `passed` counts.

## Current scores

`75/75 — 100.0%` (see `conformance/results/flutter/`):

| domain     | score |
|------------|-------|
| layout     | 8/8   |
| paint      | 9/9   |
| gestures   | 10/10 |
| i18n       | 8/8   |
| focus      | 8/8   |
| a11y       | 8/8   |
| navigation | 8/8   |
| scrolling  | 9/9   |
| state      | 7/7   |
