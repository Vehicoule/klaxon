# Qt6 conformance adapter — mapping notes

`run.sh` builds `klaxon-qt-conformance`, a Qt6 (Core/Gui/Widgets) executable
that runs every vector in `conformance/tests/*.json` against a port of the
Klaxon widget tree, then emits the same report shape as
`src/conformance_main.zig` (`framework: "qt6"`).

## Architecture

| File | Contents |
| --- | --- |
| `src/kx.h` / `src/kx.cpp` | Framework-neutral core: `KxNode` tree, measure/layout, paint traversal with damage tracking, `InputRouter` (capture/bubbling/hover/keys/scroll/back), `FocusManager`, semantics tree + `LogBridge`, signals/effects/memo/`TextSignal`, `Timeline`, gesture arena, `ScrollState` + virtualization, `I18n`/`KxLocale` (ARB + CLDR plurals + number/date tables), `Navigator`, `KxSurface` (`QWidget` host). |
| `src/widgets.cpp` | Every DSL widget as a `KxNode` subclass (Zig vtable+state → C++ subclass): flex row/column, stack, grid, padding, directional padding, align/center, constrained box, expanded, container, text, button, toggle, checkbox, slider, text field, gesture detector, scroll view, list view, `l10n_text`, `l10n_plural`, `l10n_plural` with a count signal. |
| `src/main.cpp` | Harness (`src/conformance.zig` port): JSON loading via `QJsonDocument`, the DSL builder, every `action` op, all 23 `expect` keys, the report/CLI (`conformance_main.zig` port). The conformance `box` leaf (`BoxNode`) lives here since it is harness-specific. |

What Qt actually does: `QPainter` rasterises into `QImage`
(`KxSurface::renderFrame` — the same paint path `paintEvent` uses on-screen),
`QFontMetrics`/`QFont` measure and draw text, `QApplication` runs offscreen
(`QT_QPA_PLATFORM=offscreen`, also forced by the binary when unset), and
`QJsonDocument` parses vectors. Nothing embeds expected outputs: every
expectation compares against observed adapter behavior, and mismatch text
keeps the `expected X got Y` wording.

## CLI

`--dir`, `--file`, `--test`, `--out`, `--no-report`, `--min-score`,
`--verbose` — same `=`-joined syntax and semantics as the Zig runner.
`--dir` defaults to `conformance/tests` (run from the repo root).

## Mapping decisions worth knowing

- **Zig vtable + allocator state → C++ subclass fields.** One `KxNode`
  subclass per widget; `vtable.deinit` → `teardown()` (the zombie sweep then
  `delete`s the node). Subscription teardown uses the callback-subscriber key
  (the node address), mirroring `userdata`-keyed unsubscription.
- **Text metrics.** Zig measures through its raster backend; the adapter
  asks `QFontMetricsF` (ascent + horizontal advance). The corpus's
  text-bearing vectors assert structure and values rather than exact glyph
  widths, and `measured`/`rects` expectations hold with Qt's metrics at the
  suite tolerance (0.01).
- **`TextSignal` cap** is enforced on UTF-8 *bytes* (`max_len = 1 MiB`),
  matching Zig's byte buffer; `signal_set` with `len` fills 'x' bytes so the
  cap is exercised without embedding it.
- **JSON number typing.** Zig's parser distinguishes `.int`/`.float`;
  `QJsonValue` only exposes `double`. `setupSignals` treats integral values
  as `i64` signals and non-integral ones as `f32`. Corpus signal values are
  integral except sliders (non-integral), so the mapping is exact there.
- **`expect` key order.** `QJsonObject` iterates keys sorted, while Zig
  walks them in file order. The only side-effectful expects are `pixels` /
  `pixel_counts` (a render clears the damage accumulator); sorted order
  still evaluates `damage` before any render key, and no vector relies on
  the opposite order (verified across the corpus).
- **Gesture arena** is a straight port (slop 12, tap 200 ms, double-tap
  300 ms, long-press 500 ms, swipe 500 px/s over a 100 ms window). The
  detector feeds window-space coordinates (`raw_x/raw_y`) like the host, so
  scrolling under a held pointer doesn't corrupt pan/velocity/pinch.
- **Locale formatting.** `KxLocale` ports the Zig lookup tables (CLDR plural
  categories, day/month names, grouping rules) instead of delegating to
  `QLocale`. Rationale: `QLocale` emits U+202F narrow no-break spaces as
  the French group separator while the vectors assert the ported table's
  plain space (`"1 234,5"`); using `QLocale` would report an honest but
  different-correct result for `i18n` vectors. This is the adapter's one
  deliberate deviation from "let Qt decide". See the `num:` cases in
  `conformance/tests/i18n.json`.
- **Accessibility** is the semantic-tree/`LogBridge` port, not a real
  `QAccessible` implementation: the vectors assert tree shape and event
  sequences, which the bridge records verbatim. `QAccessibleInterface`
  integration isn't required by any vector and isn't wired.
- **Navigation pages** are owned by the harness (the DSL never parents
  them) — each page is a fixed 10x10 box since nav semantics don't depend
  on page content; the harness deinits them at teardown.
- **`same()` callback-subscriber keys** compare by `key` pointer (the
  subscriber `this`), matching `userdata`-keyed unsubscribe.

## Known limitations / unsupported features

- **Host integration is minimal.** `KxSurface` is a real `QWidget`, but the
  suite drives it headless: actions call the `InputRouter` directly instead
  of going through `QTest`/`QMouseEvent` synthesis, and there is no event
  loop pumping between actions. `tick` actions advance the `Timeline`
  deterministically instead (gesture long-press registers as a timeline
  ticker, same as the native idle loop).
- **No `QWidget` controls.** DSL widgets are `KxNode` subclasses that paint
  themselves — a `QPushButton`/`QLineEdit` wouldn't accept the vectors'
  coordinate-space events or the exact-pixel painting the corpus asserts.
  Qt supplies rasterisation, fonts, and the host shell; widget *behavior*
  is the ported spec.
- **`approx` pixel tolerance** allows ±2 per channel (like Zig) to absorb
  rasterizer rounding at shape edges; exact matches are still required
  everywhere else.
- **Two-finger gestures (pinch/rotate)** are ported and logged, but no
  vector currently feeds multi-pointer streams, so they're covered only by
  unit-level faithfulness.
- **i18n formatting tables** cover the locales the corpus uses; other
  `QLocale` territories would need table additions rather than being free.
- **Leaks during a run are bounded**: builders, signals, effects, nav pages
  and the tree are all torn down per test (`Harness::deinit`); the binary
  is a short-lived process regardless.

## Running

```sh
cd conformance/runners/qt
./run.sh                       # configure + build + run all nine domain files
./run.sh --test FOCUS --verbose
./run.sh -- -DCMAKE_PREFIX_PATH=/path/to/Qt/6.x/lib/cmake
```

Expected output: `klaxon-qt conformance: 75/75 passed (100.0%)` with
per-domain lines matching `zig build conformance` (layout 8/8, paint 9/9,
gestures 10/10, i18n 8/8, focus 8/8, a11y 8/8, navigation 8/8,
scrolling 9/9, state 7/7).
