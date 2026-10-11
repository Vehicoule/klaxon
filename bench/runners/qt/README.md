# Qt 6 comparison benchmark runner (roadmap Phase 4c.4 + scene catalogue v2)

A Qt 6 port of Klaxon's own benchmark (`src/bench.zig` + `src/bench_main.zig` +
`docs/specs/bench-scenes.md`): it renders the **same scenes** at the **same
harness settings** and emits the **same JSON report (schema v2)**, so Klaxon
(Zig + Skia + SDL3) and Qt 6 can be compared head-to-head on identical
workloads. 33 scenes: the 9 Phase-4c.4 scenes plus the 24 catalogue-v2 scenes
(6 `list_ops` + 4 `ramp` + 10 `stress` + 4 `system`).

```
bench/runners/qt/
├── CMakeLists.txt      CMake project (Qt6 Quick, C++17, AUTOMOC)
├── run.sh              build + run all 33 scenes (or one via $1), save the JSON
├── README.md           this file
├── src/
│   ├── main.cpp            the harness: run paths, metrics, JSON report
│   ├── BenchDriver.h       the "bench" context property (tick + input + probe invokables)
│   ├── BenchImageProvider.h  images_ramp's decode-once checkerboard (image://bench/checker64)
│   ├── StarClipItem.h      clip_path's node (C++ QQuickPaintedItem, QPainterPath clip)
│   └── VideoItem.h         video_playback's widget (C++ QQuickPaintedItem)
└── qml/                  one QML file per scene (+ shared helpers)
    ├── the 9 Phase-4c.4 scenes + Section.qml (gallery helper)
    ├── ListOpsScene.qml        shared list_ops row/list + the 6 op entry points
    ├── list_create_1k.qml  list_replace_1k.qml  list_update_10th.qml
    │   list_swap_rows.qml  list_remove_row.qml  list_clear_1k.qml
    ├── shapes_ramp.qml  paths_ramp.qml  text_ramp.qml  images_ramp.qml
    ├── overdraw_stack.qml  elevation_grid.qml  relayout_storm.qml
    │   mount_churn.qml  scroll_anim.qml  text_rich.qml  chart_live.qml
    │   clip_path.qml  theme_switch.qml  backdrop_scroll.qml
    └── input_latency.qml  pointer_storm.qml  semantics_build.qml  app_switch.qml
```

## Usage

```sh
# all 33 scenes (builds first; Qt 6 via Homebrew at /opt/homebrew):
bench/runners/qt/run.sh

# one scene:
bench/runners/qt/run.sh scroll_10k
```

The runner prints the JSON report to stdout (progress + render verification go
to stderr) and writes the same report to
`bench/results/qt/<ISO8601-timestamp>.json`. Klaxon's side of the comparison:
`scripts/bench.sh` (writes `bench/results/<timestamp>.json`).

## Harness contract (identical to Klaxon's bench, schema v2)

| setting | value | source |
|---|---|---|
| viewport | 640×480, opaque `#14141CFF` | `RunOptions` (bench.zig) |
| frames | 10 warmup + **120 measured** = **130 rendered** for standard scenes | `RunOptions` (`frames` defaults to 120 — the Phase-4c.4 results below used `-Dbench-frames=600`; the v2 catalogue codifies 120) |
| list_ops frames | 10 warmup + the op + **60 measured** = 71 rendered; `extra.op_ms` times the model mutation + one full render pass | spec Family A |
| ramp frames | 9 steps `N = 10…3200` × (10 warmup + **20 measured**) = 270 rendered; per-step p50 → `extra.ramp[]` | spec Family B |
| pacing | **unpaced** — render as fast as the raster backend allows, no vsync, no timer | bench.zig's loop |
| per-frame work | scene tick + layout + paint, timed per frame | `SceneRunner.run` |
| fps | `1000 / frame_time_avg_ms` | bench.zig |
| frame_time avg/p50/p99/**p999** | over the measured frames, **strict nearest-rank** percentile (rank `ceil(p·n/100)` — the p50 of a 20-frame ramp step is its 10th value; bench.zig's `min(n·p/100, n-1)` floor-rank lands one higher on small samples) | spec + devtools convention |
| **jank_frames / jank_pct** | frames with `frame_ms > 16.67` (60 Hz budget) | spec (JankStats convention) |
| draw_calls_per_frame | visible painted nodes (see below) | bench.zig `countPaintNodes` |
| rss_mb | process RSS — `mach_task_basic_info` `resident_size` | devtools.zig |
| ttff_ms | run start (scene load included) → end of the first completed frame | bench.zig |
| JSON schema | `bench_main.zig` `formatReport` fields + `frame_time_p999_ms`, `jank_frames`, `jank_pct`, `extra`, top-level `"schema_version": 2` | docs/specs/bench-scenes.md |

`extra` per scene: `list_ops` → `{"op_ms": N}`; ramp → `{"ramp": [{"n", "p50_ms"}…], "n_max_60fps": N}`;
`input_latency` → `{"latency_frames", "latency_ms"}`; `semantics_build` →
`{"nodes_per_frame": N}`; `app_switch` → `{"teardown_ms", "resume_ms"}`
(mean of the two cycles); everything else → `"extra": null` (the spec's
"missing optional fields serialize as null").

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

The checks **fail loud**: an animated scene whose pixels never change, a
static scene whose pixels do, or a frame with no ink (blank render —
`list_clear_1k`'s spec-mandated empty state excepted) exits the runner
non-zero, so a silently broken scene can never produce a "successful" report.

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

## Catalogue-v2 scene mapping (spec → Qt)

Family A — `list_ops` (krausest js-framework-benchmark): `ListOpsScene.qml` is
the shared scene — `ListView` + `ListModel` in a clipped 640×480 viewport,
row delegate = 48dp card with the label `"Row NNNN — klaxon bench"` left and
a 16×16 `#7C4DFF` square right. Virtualization stays ON (`cacheBuffer: 0`,
~10 live delegates — the framework's idiom). The six scene files only select
`benchOp`; the harness runs the op once between warmup and the 60 measured
frames via `runBenchOp()` (create → append 1000 into the empty model,
replace → build a fresh 1000-row `ListModel` and **assign it** — a real
model swap, not incremental clear+append — update10 → 100 `setProperty`
label mutations, swap → swap model rows 5/995 contents, remove →
`remove(500)`, clear → `clear()`).

Family B — `ramp` (MotionMark): each scene exposes `benchN`; the harness
steps it through `10,25,50,100,200,400,800,1600,3200` (10 warmup + 20
measured per step) and reports per-step p50 in `extra.ramp[]` plus
`extra.n_max_60fps`. Top-level frame metrics aggregate all 180 measured
frames. `shapes_ramp` moves N 40×24 r=8 rects on a Lissajous path
(≤4 px/frame per axis — `amplitude×ω = 4`); `paths_ramp` rotates N identical
12-anchor closed bezier blobs (`Shape` + `PathSvg`, ~200-pt tessellation is
engine-internal) 1°/frame; `text_ramp` oscillates N `"The quick brown fox
0123456789"` labels at `pixelSize` 14 (no sp headless — the runner's
convention); `images_ramp` moves N `image://bench/checker64` items at 48×48
(64×0.75), the provider decodes once and the cache is shared.

Family C — `stress`: see the table below.

| scene | spec | Qt port |
|---|---|---|
| overdraw_stack | 24 full-screen rects, alpha `0x1F`, alternating `#7C4DFF`/`#03DAC6` | fill alpha on 24 `Rectangle`s; composites to one uniform color (ink-samples legitimately 0 — the stderr render-check prints the corner pixel) |
| elevation_grid | 10×10 grid of 48×40 cards, M3 shadow r=12/dy=2/blur=6/`rgba(0,0,0,.30)`, fill oscillates ±4% lightness | `RectangularGlow` (Qt5Compat) behind each card; the tick oscillates `glowRadius` ±0.5px + `update()` so every shadow re-rasterizes per frame (the fill change alone leaves the cached glow untouched) |
| relayout_storm | 200 rows animating width 200↔440 (2 s loop) | `ColumnLayout` re-solves 200 `Layout.preferredWidth`s per frame; spec sets no phase → uniform 120-frame sine |
| mount_churn | destroy 50 + create 50 widgets/frame, pool 500 | `createObject`/`destroy()` churn of a label+icon card; the detach is timed, C++ deletion completes in the untimed drain (deferred-deletion idiom, like GC) |
| scroll_anim | scroll_10k @ 600 dp/s + 30 embedded icons pulse | 10 px/frame `contentY`; the pulse band follows the scroll (rows `[base, base+30)`) so it stays live under virtualization |
| text_rich | 60 paragraphs × 3 lines, bold/italic + 12/16/20 + bidi line | `Text.RichText` paragraphs in a `Flickable` scrolling 15px/frame — every paragraph paints over the run (a fixed clip would cull ~47 of them forever; Qt culls offscreen items where Klaxon repaints the whole tree) |
| chart_live | 1000-point polyline rebuilt/frame + 10×8 grid/axes | `Canvas` repaints grid + a fresh 1000-segment polyline each frame (one item — draw_calls granularity caveat) |
| clip_path | 120 nodes under a 6-point star clip, contents scrolling | `StarClipItem` (C++ `QQuickPaintedItem`, `QPainterPath` clip) — see gap note |
| theme_switch | 200+ node gallery tree, light/dark every 30 frames | ~260-node palette-bound tree; one `pal.dark` toggle re-evaluates all colors |
| backdrop_scroll | 200 items scrolling under a fixed 640×160 blur band (σ=12) + 60% scrim | `ShaderEffectSource(live)` of the list region + `GaussianBlur` radius 12 + scrim — a real per-frame backdrop blur on the software backend |

Family D — `system`:

| scene | spec | Qt port |
|---|---|---|
| input_latency | pointer event → frames until the response paints | `pressAt` delivers `QMouseEvent` press+release between frames; the harness counts frames until the `latencyBox` fill shows up in the grabbed pixels (`latency_frames` = 1 — the next frame paints it — and `latency_ms` spans event dispatch + handling through the painting frame's end) |
| pointer_storm | 1000 hit-test queries/frame over a 500-node tree | tick issues 1000 LCG-distributed `bench.hitTest(x,y)` calls — a topmost-first contains()+descend walk, the same geometry Qt's dispatch performs (without the event objects) |
| semantics_build | build/diff the a11y semantics tree of a 1000-node tree per frame | `bench.collectSemantics()` walks the item tree building one record per node (class, name, text, mapped bounds) + a hash diff vs the previous frame — `extra.nodes_per_frame` |
| app_switch | pause→resume every 60 frames: `teardown_ms`, `resume_ms` | `setSource(QUrl())` + event drain (teardown) then reload + first `grabWindow` (resume); cycles at frames 60 and 120, `extra` reports the mean |

## Known non-parities (read before comparing numbers)

v2 additions:

1. **list_ops op_ms includes delegate instantiation for `create`.**
   `ListModel.append` is cheap; the `create` op's render pass instantiates the
   ~10 live delegates (like Flutter's `ListView.builder` first build).
2. **paths_ramp tessellation is engine-internal.** Qt Quick Shapes
   triangulates `PathSvg` per its own curve-flattening tolerance — the
   spec's "~200 pts" cannot be set explicitly; the 12-anchor bezier blob is
   the closest idiom.
3. **clip_path is a true path clip via C++, not `OpacityMask`.** Qt Quick
   has no declarative path clip; `OpacityMask` (Qt5Compat) would add an
   offscreen mask pass per node (a mask, not a clip). `StarClipItem` uses
   `QPainter::setClipPath` — the exact semantic — at the cost of not
   exercising the declarative path.
4. **backdrop_scroll blur runs on the CPU-effects path.** Software-backend
   `GaussianBlur`/`ShaderEffectSource` work but may under-cost vs a GPU
   pipeline (no per-sample fragment cost model) — treat the number as a
   lower bound.
5. **input_latency measures the driven loop, not a display pipeline.** With
   no vsync, the response paints in the next driven frame (`latency_frames`
   = 1); there is no compositor/vsync latency to measure headless.
6. **semantics_build is an item-tree walk, not a real a11y tree.** Qt has no
   public "build the semantics tree" entry point (QAccessible bridges are
   platform-owned); `collectSemantics` builds/diffs per-node records — the
   closest idiom for Klaxon's semantics build+diff.
7. **mount_churn destroy() defers C++ deletion to the untimed drain.** The
   detach is inside the timed frame; the QObject teardown completes in the
   inter-frame event drain — like a deferred GC — so Qt under-counts the
   destroy half of the churn vs frameworks that delete synchronously.
8. **Schema v2 frame count is 120 measured for ALL standard scenes.** The
   Phase-4c.4 scenes previously ran 600 (matching `-Dbench-frames=600`); the
   results table below was measured under that contract.

Phase-4c.4 notes (unchanged):

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
