# Compose Multiplatform adapter — DSL → Compose mapping

Port of `src/conformance.zig` + `src/conformance_main.zig` to Kotlin/JVM
running on **Jetpack Compose Multiplatform 1.8.2 (desktop)** with the
**Skiko** software rasterizer. The runner is a plain JVM program — no
window, no GPU, no vsync — that drives a real
`androidx.compose.ui.scene.CanvasLayersComposeScene` into a CPU
`org.jetbrains.skia.Surface` and reads the pixels back.

```
conformance/runners/compose/
  build.gradle.kts   Kotlin/JVM 2.1.21 + Compose plugin, jvmToolchain(21)
  run.sh             one-command build+run (./gradlew fatJar → java -jar)
  src/main/kotlin/conf/compose/
    Json.kt          minimal JSON parser/writer (spec-conformant escapes)
    Core.kt          KNode tree, Constraints2/Rect2, layout, damage,
                     hit-test + input router, focus manager, semantics
                     (ports of src/ui/{node,layout,input,semantics}.zig)
    State.kt         Signal/TextSignal/Effect/Memo (src/ui/state.zig)
    I18n.kt          ARB tables, plurals, ICU-style number/date
                     formatting, direction (src/ui/i18n.zig)
    Nav.kt           routes, paths, page stack, back (src/ui/navigator.zig)
    Gestures.kt      gesture arena: tap/double/long-press/pan/swipe/
                     pinch/rotate (src/ui/gestures.zig)
    Widgets.kt       DSL widget behaviors (src/widgets/*.zig)
    Engine.kt        vector setup, action replay, expectation checks,
                     report model (src/conformance.zig)
    ComposeHost.kt   the Compose-side host: scene, raster surface,
                     semantics bridge, text measuring, input feed
    Main.kt          CLI: domain order, console summary, JSON report
                     (src/conformance_main.zig)
```

## Architecture: model + real Compose

The DSL's semantics are Klaxon's own (constraint model, parent-space
rects, damage accumulation, arbiter ordering), not Compose's — e.g. a DSL
`column` cross-stretches children to the column width and shrink-wraps
the cross axis of loose children, which is *not* what
`androidx.compose.foundation.layout.Column` computes. Per ADAPTERS.md
("implement the DSL type on top of what exists and document the
approximation"), the adapter therefore runs a faithful Kotlin port of the
reference model for layout/routing semantics and maps each model node to
real Compose machinery for everything Compose can own natively:

| Concern          | Mapping |
|------------------|---------|
| Tree             | One `KNode` → one `Layout` composable (recursive `NodeView`) |
| Measurement      | Model `measure(c: Constraints2)` (port of `src/ui/layout.zig`); the Compose `MeasurePolicy` reports `node.bounds` and places children at model coordinates — Compose performs the real measure/layout pass over that policy |
| Placement        | `place(child.bounds - parent.bounds)`; scroll children placed at `-offset` inside a real `Modifier.clipToBounds` |
| Painting         | `Modifier.drawBehind` → `ComposeSink` (real `DrawScope`/`SkCanvas` ops: `drawRect`, `drawRoundRect`, `TextLine`) |
| Pixels           | `scene.render(canvas, nanoTime)` into `Surface.makeRasterN32Premul`, `makeImageSnapshot` + `Bitmap` readback → real framework raster |
| Text measure     | `Skiko Font.measureTextWidth` + `FontMetrics` (same Skia stack the reference's `kx_measure_text` uses) |
| Text draw        | `TextLine.make` + `Canvas.drawTextLine` at baseline |
| Semantics        | Each node publishes its `Semantics2` descriptor through a `Modifier.semantics` custom `SemanticsPropertyKey`; the adapter reads the **real** `SemanticsOwner.unmergedRootSemanticsNode` back (via the scene's `mainOwner` bridge) and converts it — so `a11y` expectations exercise Compose's actual semantics tree, not the model's |
| Damage           | Model accumulator (mapped rects unioned at the root) — Compose has no public damage API; the model is the observability surface the vectors assert |
| Input router     | Port of `src/ui/input.zig` (capture, bubbling, hover, focus dispatch). Vectors assert the reference's arbiter ordering, which differs from `Modifier.pointerInput`'s — the router feeds Compose's scene for paint only |
| Focus            | Port of the reference `FocusManager`; `focused` rect painted through the real pipeline |
| Signals/effects  | `State.kt` port — `KSignal.set` notifies subscribers that call `KNode.markDirty`, which is bridged to Compose by bumping a `mutableLongStateOf` observed in `RootContent` → real recompose on the next `scene.render` |
| Scrolling        | Model scroll offset; rendered through a real `clipToBounds` + translated placement |
| Gestures         | Port of `src/ui/gestures.zig` — the DSL recognizer graph (arena claim order, co-firing two-finger gestures, double-tap suppression) has no `detectTapGestures`-equivalent mapping; pointer events are fed through the model router |
| i18n / navigation| `I18n.kt`/`Nav.kt` ports — framework-neutral subsystems, no Compose equivalent required |

## DSL type → host mapping

| DSL `type` | Host mapping |
|------------|--------------|
| `column`, `row`, `stack`, `box`, `container`, `padding`, `padding_directional`, `expanded`, `constrained`, `align` variants | `KNode` + `Layout` (measure/place delegated to the model policy) |
| `text`, `localized_text` | `KNode` + text `paintFn` → `TextLine` |
| `button`, `toggle`, `checkbox`, `slider`, `text_field` | `KNode` + widget handlers (pointer/key → signal/semantics); drawn via `drawBehind` |
| `gesture_detector` | `KNode` wrapper + gesture arena |
| `scroll_view`, `list` | `KNode` + scroll state, `clipToBounds`, item virtualization |
| `canvas`, `progress_bar`, misc paint nodes | `KNode` + `paintFn` |

## Deterministic globals

- **Clock**: `Harness.timeline` — `tick` actions advance the virtual
  frame clock; `scene.render` gets `System.nanoTime()` (monotonic, but
  all asserted timing is gesture/long-press driven by virtual ms in the
  model).
- **Input router / focus / a11y log / i18n / navigator**: per-test fresh
  instances in `Engine`, mirroring the reference's single-window globals.
- **Tolerance**: `0.01` default, per-vector override, identical to the
  reference.

## Unsupported behavior and limitations

1. **Compose's own layout/focus/gesture pipelines are not the asserted
   surface.** DSL semantics that have no Compose-equivalent contract
   (cross-stretch column, the gesture arena claim order, the focus
   ring's semantic-order traversal, damage rects) are computed by the
   Kotlin port of the reference and only *displayed* through Compose.
   What is genuinely Compose: the composition/measure/layout pass,
   `clipToBounds`, `drawBehind`/Skia rasterization, `TextLine` shaping,
   and the `SemanticsOwner` tree readback. A vector that asserts Compose
   pipeline behavior the DSL doesn't define would not exist — by design.
2. **Damage is model-side.** Compose does not expose its dirty-rect
   scheduler; `damage` expectations are answered from the model's
   mapped-rect accumulator (same math as the reference).
3. **Reflection bridge for semantics.** `ComposeScene` exposes no owner
   accessor, so `ComposeHost` reads `mainOwner` → `getOwner()` →
   `getSemanticsOwner()` reflectively. If that fails, checks fall back to
   `modelSemanticTree()` — the current run uses the real tree (the
   `a11y` domain passes on it).
4. **Text is the Skiko stack, not the reference's font file.**
   `FontMgr.default.legacyMakeTypeface("", …)` resolves the host default
   family; the corpus only asserts widths/heights for the built-in
   measure contract (ASCII + CJK-adjacent codepoints), which Skia's
   default font covers on macOS. On a host without a default Latin font
   `text` vectors would fail honestly.
5. **Platform**: the fat jar ships macOS-arm64 Skiko natives only
   (Gradle `currentOs` artifact). Linux/Windows runs resolve their own
   `skiko` native jars through the regular `run` task / classpath.
6. **No GPU/vsync**: CPU raster `Surface`; `paint` vectors assert RGBA
   pixel values and counts which are rasterizer-deterministic.
7. **Router back handler**: not wired (matches the reference harness,
   which leaves `back_handler` unset — `dispatchBack` still walks the
   focused ESCAPE chain and modal back stack).

## Test plan

```bash
# Full corpus, console summary + results-<ts>.json under
# conformance/results/compose/:
conformance/runners/compose/run.sh

# Equivalent direct Gradle invocation:
cd conformance/runners/compose
JAVA_HOME=/opt/homebrew/opt/openjdk@21 ./gradlew run \
  --args="--dir=$PWD/../../tests --out=$PWD/../../results/compose/results-<ts>.json"

# Single domain / single vector:
run.sh --file=../../tests/paint.json
run.sh --test=LAYOUT-003
run.sh --verbose     # print PASS lines too
run.sh --min-score=100   # exit 1 below the bar
```

Report shape (same as the reference runner, `framework: "compose"`):
`score_pct`, `by_domain` tallies, per-test `id/domain/rule/passed/failures`.

## Current scores

`75/75 — 100.0%` (see `conformance/results/compose/`):

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
