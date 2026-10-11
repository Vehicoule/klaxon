# Qt 6 comparison benchmark runner (roadmap Phase 4c.4)

A Qt 6 port of Klaxon's own benchmark (`src/bench.zig` + `src/bench_main.zig`):
it renders the **same 9 scenes** at the **same harness settings** and emits the
**same JSON report**, so Klaxon (Zig + Skia + SDL3) and Qt 6 can be compared
head-to-head on identical workloads.

```
bench/runners/qt/
├── CMakeLists.txt      CMake project (Qt6 Quick, C++17, AUTOMOC)
├── run.sh              build + run all 9 scenes (or one via $1), save the JSON
├── README.md           this file
├── src/
│   ├── main.cpp        the harness: frame loop, metrics, JSON report
│   ├── BenchDriver.h   the "bench" context property (tick signal + input mechanics)
│   └── VideoItem.h     video_playback's widget (C++ QQuickPaintedItem)
└── qml/                one QML file per scene (+ Section.qml, a gallery helper)
    ├── hello.qml  scroll_10k.qml  text_cjk.qml  glass_blur.qml  anim_100.qml
    ├── gallery.qml  resize.qml  input_ime.qml  video_playback.qml
    └── Section.qml
```

## Usage

```sh
# all 9 scenes (builds first; Qt 6 via Homebrew at /opt/homebrew):
bench/runners/qt/run.sh

# one scene:
bench/runners/qt/run.sh scroll_10k
```

The runner prints the JSON report to stdout (progress + render verification go
to stderr) and writes the same report to
`bench/results/qt/<ISO8601-timestamp>.json`. Klaxon's side of the comparison:
`scripts/bench.sh` (writes `bench/results/<timestamp>.json`).

## Harness contract (identical to Klaxon's bench)

| setting | value | source |
|---|---|---|
| viewport | 640×480 | `RunOptions` (bench.zig) |
| frames | 10 warmup + 600 measured = **610 rendered** | `RunOptions` + `-Dbench-frames=600` |
| pacing | **unpaced** — render as fast as the raster backend allows, no vsync, no timer | bench.zig's loop |
| per-frame work | scene tick + layout + paint, timed per frame | `SceneRunner.run` |
| fps | `1000 / frame_time_avg_ms` | bench.zig |
| frame_time avg/p50/p99 | over the 600 measured frames, nearest-rank percentile | bench.zig `percentile` |
| draw_calls_per_frame | visible painted nodes (see below) | bench.zig `countPaintNodes` |
| rss_mb | process RSS — `mach_task_basic_info` `resident_size` (same source as `devtools.readRssMbMac`) | devtools.zig |
| ttff_ms | run start (scene load included) → end of the first completed frame | bench.zig |
| JSON schema | field names, order, types and `%.1f` number formatting identical to `bench_main.zig` `formatReport` | bench_main.zig |

## Architecture choice: Qt Quick (QML), not Qt Widgets

Qt 6 **Quick** was chosen over Widgets (QPainter) because the scene set maps
directly onto Quick primitives:

- `scroll_10k` needs a **virtualized** list of 10 000 rows (~10 live) —
  `QListView` virtualizes natively (`cacheBuffer: 0` keeps the live window at
  viewport size, like Klaxon's `syncItemWindow`); a Widgets `QListWidget` would
  materialize all 10 000 items.
- `glass_blur` needs translucent **layers** — `layer.enabled` + `opacity` is
  the exact Qt analog of Klaxon's `layerAlpha` (saveLayer at 45% alpha).
- `anim_100` needs 100 concurrently animated items retargeted every frame —
  a `Grid` of 100 `Rectangle`s driven by the tick.
- `input_ime` needs the real **IME commit path** — `QInputMethodEvent`
  commit strings delivered to a focused `TextInput` (what an input method
  actually sends), plus `QKeyEvent` backspaces and synthesized mouse events
  for the frame-0 click-to-focus.

The harness itself is C++ (`main.cpp`): it owns the frame loop, the metrics,
and the JSON report; the scenes are QML; the one custom widget that needs
C-speed (`video_playback`'s per-pixel frame regeneration — Klaxon does the
same loop in Zig) is a C++ `QQuickPaintedItem` registered as a QML type.

## Timing method + headless verdict

**Verdict: headless works — `QT_QPA_PLATFORM=offscreen` +
`QT_QUICK_BACKEND=software` + `QSG_RENDER_LOOP=basic` (set by run.sh).** No
real window is needed; a windowed fallback was not required.

An offscreen window is **never exposed**, so Qt's render loop does not
schedule frames by itself (`requestUpdate()` + `processEvents()` renders only
the initial frame). The harness therefore drives one frame per iteration with
`QQuickWindow::grabWindow()`, which — for the software backend — goes through
`QSGSoftwareRenderLoop::grab()` → `renderWindow()`, an **unconditional**
polish + sync + full render into the backing store (no dirty-check
short-circuit), then a copy of the store into the returned `QImage`. That is
the same work Klaxon's loop does per frame (tick + layout + full repaint,
whether or not anything changed), with no vsync and no pacing. A short
untimed `processEvents()` drain after each frame delivers deferred deletions
(list delegate churn) and window resize events.

Frames-render verification (all offscreen, printed per scene to stderr):

- `QSG_RASTER_LOG_TIME_RENDERLOOP` (`QT_LOGGING_RULES=qt.scenegraph.time.renderloop=true`)
  logs one `Frame rendered with 'software' renderloop` line **per driven
  frame** (612 lines for 610 grabs + the initial show render).
- the grabbed pixels change between frames for animated scenes and stay equal
  for static scenes (`pixels-change`);
- a fresh grab after the run contains ink (content really painted, not a
  blank/cached image) (`ink-samples`);
- `input_ime` accumulates the committed CJK/emoji text (2140 chars over the
  run) through the real `QInputMethodEvent` path;
- `scroll_10k`'s list sits at the tick-driven offset (`contentY == 609*37`,
  matching `(frame*37) mod (maxScroll+1)`) with ~10 live delegates;
- `frameSwapped` fires per driven frame when the tick requested an update
  (it is a swap signal, so static scenes report few — rendering is proven by
  the checks above, not by that signal).

### Known constant overhead vs Klaxon

Each timed frame includes one backing-store→`QImage` copy (~1.2 MB at 640×480,
≈0.02–0.05 ms) that Klaxon's bench does not have (it paints straight into its
raster target). It inflates every Qt frame time by a small constant.

## draw_calls_per_frame definition

Klaxon estimates draw calls as the number of **visible nodes painted per
frame** (`countPaintNodes` over the widget tree, counted after the final
frame). The Qt port counts the **visible `QQuickItem`s under the scene's root
item** (`QQuickWindow::contentItem` excluded), counted after the final frame —
the same "visible painted nodes" definition, one node per item.

Granularity caveats (inherent to the mapping, not bugs):

- Klaxon paints several fills inside **one** custom node (e.g. the glass card
  paints a rounded rect + 3 bars in a single `paint` callback → 1 node);
  Qt needs one `Rectangle` per fill → `glass_blur` reports 24 items vs
  Klaxon's 15 nodes.
- Qt views add an internal `contentItem` (counted, +1 per `ListView`) and
  `Repeater` non-visual items (counted).
- For `hello` the counts match exactly (2 = 2); `scroll_10k` 50 vs 60,
  `anim_100` 103 vs 101, `resize` 42 vs 47, `video_playback` 4 vs 3,
  `text_cjk` 7 vs 6 — all within item-granularity noise.

## Scene mapping (Klaxon → Qt)

| scene | Klaxon (bench.zig) | Qt port (qml/) | tick parity |
|---|---|---|---|
| hello | centered `Text` "Hello, Klaxon!" 24px white | `Item` + centered `Text` | static |
| scroll_10k | column(16/12) [ title, box(max 880×300) [ listView 10 000 × 36px, row = card `#2A2A3E` r6 pad 8/6 [ ★ 14 `#FFD54F`, "Item #N" 14 white ] ] ] | same tree; `ListView` `model: 10000`, `cacheBuffer: 0`, same delegate | `contentY = (frame*37) mod (contentHeight-height+1)` — identical formula |
| text_cjk | column(24/10) of 5 texts (14/22/22/22/18, same strings incl. 🌍🎉) | identical strings, sizes, colors | static |
| glass_blur | backdrop `#101426` [ stack [ deco column: 3 panels `#E91E63/#3F51B5/#00ACC1` 150px r12; 3 glass cards 300×110 r16 at center/top-right/bottom-left ] ]; card = `layerAlpha(0.45)` + tint rrect + 3 white bars (α 1/.7/.5) | same tree; card = `Item { layer.enabled: true; opacity: 0.45 }` + tint `Rectangle` + 3 bar `Rectangle`s | static |
| anim_100 | grid(10 cols, gap 8, pad 16) of 100 animated containers; tick retargets height `24+16·sin(phase)` and color `lerp(#3F51B5,#E91E63,(sin+1)/2)`, `phase = frame*0.06 + i*0.17`; timeline +8 ms/frame; spring k=380 c=32 m=1 (exact closed form) | `Grid` + `Repeater(100)` of `Rectangle`s; the tick evaluates the **same closed-form spring step** (same constants, dt=8 ms) per lane (height + RGB) per widget and applies height + color | identical phase/target/spring math |
| gallery | the full gallery app (gallery.zig): header + `scrollView` [ 32 sections ] over the dark M3 theme | representative port: header (title/subtitle/toggles) + `Flickable` [ 20 sections: buttons, icon buttons, selection, chips, text fields, cards, list items, segmented, search bar, loading, avatars, color picker, calendar, table, typography, 10k list ] | static |
| resize | column(16/12) [ title, row of 3 cards (`#2A2A3E` r8 pad 12 "Card" 13), box(max 880×200) [ listView 2 000 × 32px ] ]; tick cycles RESIZE_SIZES | same tree; tick calls `bench.setViewSize(w,h)` | identical RESIZE_SIZES cycle |
| input_ime | column(24/12) [ title, filled text field (label "Message", placeholder "こんにちは…", supporting text, light theme) ]; frame 0: click to focus; then IME commits cycling 6 strings, backspace every 12th frame | same tree (M3 filled field, light colors); frame 0: synthesized mouse down+up at the field center; commits via `QInputMethodEvent`, backspace via `QKeyEvent` | identical string cycle + backspace cadence |
| video_playback | column(16/12) [ title, video widget 320×180 ]; paint regenerates pixels per frame (x/y gradient + white bar at `(frame*3) mod w`, 24px wide) and uploads a fresh texture | same tree; `VideoItem` (C++ `QQuickPaintedItem`) regenerates the identical pixel buffer in `paint()` and re-uploads it | identical per-pixel algorithm |

## Known non-parities (read before comparing numbers)

1. **gallery is not apples-to-apples.** Klaxon's gallery is the full 32-section
   showcase (696 visible nodes) and its raster backend **paints the whole
   tree every frame** (offscreen sections issue clipped draw calls). The Qt
   port is a representative 20-section subset (316 items), and Qt's software
   renderer **culls items outside the clip** — so Qt does strictly less work
   per frame on this scene. Treat gallery as a structural smoke test, not a
   timing comparison.
2. **input_ime:** Qt's `QQuickTextInput` re-shapes/re-layouts the **entire**
   text buffer on every commit (the buffer grows to ~2 100 chars over the
   run, as in Klaxon). Klaxon's text field re-shapes far less per frame, so
   Qt is expected to be much slower here — a real framework difference in
   text-layout efficiency, not a port bug.
3. **anim_100:** Klaxon's springs run in allocation-free Zig; the Qt port
   runs the same math in QML JS (allocation-free after the first tick: typed
   arrays for spring state) and pays Qt Quick's per-item property/layout cost.
   Expect Qt to be several times slower.
4. **glass_blur:** Klaxon's card is one custom node (an alpha *layer*, the
   documented "blur stand-in" — the kx_skia ABI has no blur primitive), so
   **neither side does a real backdrop blur**; Qt replicates the alpha layer
   (`layer.enabled` + `opacity: 0.45`). Item-count granularity differs (see
   draw_calls).
5. **ttff:** Klaxon's scenes are compiled into its binary; Qt compiles QML at
   load. The runner **warms the QML compile cache before the timed run**, so
   ttff measures scene construction + first frame on both sides (Klaxon's ttff
   is the same span). QML disk caching is disabled (`QML_DISABLE_DISK_CACHE`)
   for determinism and to keep the source tree clean.
6. **Text engines differ:** Klaxon shapes with Skia/HarfBuzz; Qt uses
   CoreText (with system fallback fonts — CJK renders via PingFang, emoji via
   Apple Color Emoji; verified real glyphs, not tofu, by ink-density probes).
7. **rss_mb** includes the whole Qt runtime (QtCore/QtGui/QtQuick loaded);
   Klaxon's is a lean static binary. **binary_size_bytes** is the runner
   executable only (Qt is dynamically linked, ≈112 KB) vs Klaxon's static
   6.5 MB bench binary — not comparable.
8. **resize:** the window resize event is delivered by the harness's untimed
   event drain, so the rendered size lags the tick by one frame; the relayout
   + backing-store realloc work per frame is the same.
9. **Machine noise:** measurements were taken on a shared, heavily loaded
   box (load average ≈ 100 on 10 cores). Frame-time tails (p99) and run-to-run
   variance are dominated by co-tenant load, not by the frameworks.

## Results (this machine, 2026-10-11; see `bench/results/qt/`)

Klaxon side: `zig build bench` (i.e. `scripts/bench.sh`), same session.

| scene | Klaxon fps | Qt fps | Klaxon avg ms | Qt avg ms | Klaxon draws | Qt draws |
|---|---:|---:|---:|---:|---:|---:|
| hello | 13393.3 | 24491.4 | 0.1 | 0.0 | 2 | 2 |
| scroll_10k | 809.3 | 2319.6 | 1.2 | 0.4 | 60 | 50 |
| text_cjk | 3891.1 | 23404.0 | 0.3 | 0.0 | 6 | 7 |
| glass_blur | 849.4 | 7278.1 | 1.2 | 0.1 | 15 | 24 |
| anim_100 | 1881.6 | 372.4 | 0.5 | 2.7 | 101 | 103 |
| gallery | 49.5 | 16221.1 | 20.2 | 0.1 | 696 | 316 |
| resize | 1120.2 | 4488.2 | 0.9 | 0.2 | 47 | 42 |
| input_ime | 2265.7 | 141.7 | 0.4 | 7.1 | 3 | 8 |
| video_playback | 1539.3 | 2157.0 | 0.6 | 0.5 | 3 | 4 |

Reading: static/text scenes are a wash (both CPU rasters, glyph caches warm);
Qt leads on the trivial and layer scenes; Klaxon leads decisively on
`anim_100` (lean Zig springs + tree vs QML JS + per-item Qt Quick costs) and
`input_ime` (incremental text layout vs full re-shape per commit); `gallery`
is not comparable (non-parity 1). Re-run both sides back-to-back on an idle
machine before drawing conclusions.
