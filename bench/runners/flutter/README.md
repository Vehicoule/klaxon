# Flutter comparison bench runner (roadmap Phase 4c.4 + bench-scenes.md v2)

Renders the same scenes as Klaxon's own bench (`src/bench.zig`,
`src/bench_main.zig`, `docs/specs/bench-scenes.md`) through Flutter on
macOS, collects the same metrics, and emits the **same JSON report**
(schema v2), so Klaxon and Flutter can be compared head-to-head. This
directory is self-contained: it does not touch `src/`, `kx_skia/`,
`build.zig`, or `scripts/`.

## Usage

```sh
bench/runners/flutter/run.sh                 # build (first time) + run all 33 scenes
bench/runners/flutter/run.sh hello anim_100  # run a subset
```

`run.sh` runs `flutter build macos --release` on first use (the first build
downloads ~1 GB of engine artifacts and takes a while), then runs the built
.app once **per scene** from the repo root. Each run prints the JSON report
to stdout and writes it to `bench/results/flutter/<ISO8601-timestamp>.json`
(colons in the timestamp are replaced with `-` for filesystem safety; the
output directory can be overridden with `KLAXON_BENCH_OUT_DIR`).

The binary also accepts a scene name directly (one scene) or no argument
(all 33, one process) — same selection contract as `klaxon bench`:

```sh
APP=bench/runners/flutter/build/macos/Build/Products/Release/klaxon_bench.app
"$APP/Contents/MacOS/klaxon_bench" hello     # one scene
"$APP/Contents/MacOS/klaxon_bench"           # all 33
```

## Scene mapping

### Original 9 scenes (`src/bench.zig`)

| Klaxon | Flutter port (`lib/scenes/`) | Notes |
|---|---|---|
| `hello` | `hello.dart` | Klaxon: Center + Text. Port per 4c.4 spec: Column of Text + FilledButton + Card (static hero UI). |
| `scroll_10k` | `scroll_10k.dart` | `ListView.builder(itemCount: 10000, itemExtent: 36)` in a 880x300-bounded box; `ScrollController.jumpTo(frame*37 mod (max+1))` per frame; `scrollCacheExtent` = 1 row so ~10 children stay live (Klaxon: ~10 live nodes). |
| `text_cjk` | `text_cjk.dart` | Same 4 CJK paragraphs + title. The default macOS Flutter font has no CJK glyphs, so the texts carry `fontFamilyFallback: [PingFang SC, Hiragino Sans, Apple SD Gothic Neo, ...]`. |
| `glass_blur` | `glass_blur.dart` | Dark backdrop + 3 deco panels + 3 glass cards (300x110, 0.45 tint, radius 16, 3 frosted bars). Klaxon's raster has no blur primitive (saveLayer + alpha tint); Flutter uses a real `BackdropFilter(ImageFilter.blur(16))`. |
| `anim_100` | `anim_100.dart` | 100 `AnimatedBuilder` widgets in a 10x10 grid (Column of Rows), phase = `frame*0.06 + i*0.17`, height `24+16*sin(phase)`, color lerp `0x3F51B5 -> 0xE91E63`. Klaxon retargets 100 spring signals per frame; the port sets the values directly (no spring smoothing). |
| `gallery` | `gallery.dart` | **Simplification**: Klaxon renders its full showcase app (`src/gallery.zig`). This is a representative multi-widget page (header, stat cards, buttons/switch/checkbox/slider, list rows) in the same spirit, not a port of the whole tree. |
| `resize` | `resize.dart` | `AnimatedContainer` cycling Klaxon's `RESIZE_SIZES` (640x480, 480x320, 320x240, 800x600, 240x400, 960x640) per frame index, forcing a full relayout of title + 3 cards + a 2000-item virtualized list. |
| `input_ime` | `input_ime.dart` | `TextField` + `FocusNode`; frame 0 requests focus (Klaxon's pointer click), then a simulated IME commit (Klaxon's `IME_STRINGS`, CJK + emoji) every frame via `TextEditingController`, backspace (grapheme-safe) every 12th frame. No real keyboard involved. |
| `video_playback` | `video_playback.dart` | `CustomPainter` regenerating the frame every paint: the same CPU pixel buffer as Klaxon's `videoPaint` (320x180 RGBA, r/g gradient field + sliding 24px bar, deterministic in the frame index) plus a frame-dependent display list (gradient + scanlines + bar). |

### bench-scenes.md v2 — Family A `list_ops` (krausest)

Shared row widget: 48 dp tall, `"Row NNNN — klaxon bench"` left, 16x16
`#7C4DFF` square right, in a `ListView.builder` (the spec's Flutter idiom;
virtualization stays ON). Each scene performs its op on the last warmup
frame; `extra.op_ms` = wall time of the op's own render pass, and frame
timing is collected over the 60 frames after the op (per the spec's
"60 frames after the op" — these scenes render 10 warmup + 60 measured =
70 frames, not 130).

| scene | operation |
|---|---|
| `list_create_1k` | `list_create_1k.dart` — setState from empty -> 1000 rows |
| `list_replace_1k` | `list_replace_1k.dart` — all 1000 row models swapped -> full rebuild |
| `list_update_10th` | `list_update_10th.dart` — every 10th row label mutated (100 updates) |
| `list_swap_rows` | `list_swap_rows.dart` — row 5 <-> row 995 model contents swapped |
| `list_remove_row` | `list_remove_row.dart` — middle row deleted |
| `list_clear_1k` | `list_clear_1k.dart` — all rows removed -> empty state |

### v2 — Family B `ramp` (MotionMark methodology)

Shared base `ramp_base.dart`: steps `N = 10,25,50,100,200,400,800,1600,3200`,
10 warmup + 20 measured frames per step (270 frames total — the per-step
warmup overrides the global 10+120 contract per spec). `extra.ramp[]` =
`{n, p50_ms}` per step; `extra.n_max_60fps` = largest step with p50 <=
16.67 ms. Items follow a deterministic Lissajous path (~4 px/frame).

| scene | Flutter idiom |
|---|---|
| `shapes_ramp` | N `CustomPaint` rounded rects (r=8, 40x24, alternating `#7C4DFF`/`#03DAC6`) |
| `paths_ramp` | N identical 12-point closed bezier paths, rotating 1 deg/frame |
| `text_ramp` | N `Text`/`TextPainter` instances of "The quick brown fox 0123456789" at 14, oscillating |
| `images_ramp` | N copies of ONE generated 64x64 RGBA checkerboard `ui.Image`, scaled 0.75x, moving |

### v2 — Family C `stress`

| scene | Flutter port | gap notes |
|---|---|---|
| `overdraw_stack` | 24 full-screen `Stack` layers at alpha 0x1F, alternating purple/teal | Impeller alpha-blends inline (no saveLayer is forced); the cost is 24 full-screen blends, documented vs Klaxon's saveLayer path. |
| `elevation_grid` | 10x10 `Container` cards (48x40) with `BoxShadow` r=12, dy=2, blur=6, 30% black; fill oscillates | — |
| `relayout_storm` | 200 rows animating width 200<->440 over 2 s (explicit width = layout, not transform) | — |
| `mount_churn` | steady-state pool 500; 50 widgets unmounted + 50 fresh (new `ValueKey`) each frame | — |
| `scroll_anim` | 10k `ListView` scrolling 600 dp/s (10 px/frame) while 30 embedded row icons pulse opacity | — |
| `text_rich` | 60 paragraphs x 3 lines `RichText`/`Text.rich`: bold/italic spans, 12/16/20 pt, one bidi line each (`"مختصر Klaxon عربي test اختبار"`) | sp -> logical px (no font scaling configured) |
| `clip_path` | 120 `ClipPath` nodes, 6-point star clips, contents scroll under the clip | — |
| `theme_switch` | shared `benchGalleryTree` (~230 widgets) under `Theme(data:)`; light/dark flip every 30 frames | — |
| `backdrop_scroll` | 200 scrolling items under a fixed 640x160 `BackdropFilter` blur band (sigma 12) + 60% scrim | — |

### v2 — Family D `system`

| scene | Flutter port | gap notes |
|---|---|---|
| `input_latency` | Real `PointerDownEvent` injected through `GestureBinding.handlePointerEvent` (the framework's own hit-test + gesture path) in a post-frame callback; tap handler flips a target color. `extra.latency_frames` = frames injection -> response frame; `extra.latency_ms` = wall time to that frame's raster finish (includes ~1 frame of pacing). | — |
| `pointer_storm` | 50x10 grid (500 leaf nodes); 1000 `RenderBox.hitTest` queries per frame at deterministic fixed-seed positions, run inside build() so they land in the measured frame work. | — |
| `semantics_build` | `SemanticsBinding.ensureSemantics()` enables collection; 1000 labelled `Semantics` cells are marked dirty and `PipelineOwner.flushSemantics()` recompiles the tree inside the build phase. `extra.nodes_per_frame` = live SemanticsNodes under the owner root (~1002). | The scene subtree is owned by the `View` element's child `PipelineOwner` (the root manifold owner cannot hold a root node) — marks, flush, and node query all go through `ro.owner`. |
| `app_switch` | `pause`/`resume` every 60 frames: the ~230-node gallery tree unmounts to a placeholder (teardown) then remounts (resume); each transition's wall time to its rendered frame is a `beginWallOp` measurement. `extra.teardown_ms`/`resume_ms` = mean over the 2 cycles in 120 measured frames. | Real `AppLifecycleState` transitions cannot be injected from Dart — the scene's own unmount/remount is the closest measurable idiom. |

## Methodology

- **Viewport**: the macOS window is fixed at **640x480 logical points**
  (`macos/Runner/MainFlutterWindow.swift` sets the content size). Every scene
  renders inside a fixed 640x480 `SizedBox` centered in the window, inside a
  `RepaintBoundary` (so the forced per-frame repaint is scoped to the scene,
  like Klaxon painting only its tree). The harness chrome is minimal
  (`Directionality` + `Localizations` + `Theme` + `Material` + a bare `Overlay`
  — what `TextField` and `Slider` need; no `MaterialApp`/`Navigator`).
  Framework errors and `debugPrint` are rerouted to **stderr** so the JSON
  stream on stdout stays clean.
- **Frame loop**: a `Ticker` drives one frame per tick (vsync-paced by the
  window; the loop is not unpaced like Klaxon's headless loop — see
  non-parities). **10 warmup + 120 measured frames = 130** per the
  bench-scenes.md contract (the 9 original scenes also now use 130).
  list_ops scenes render 70 (op on last warmup frame + 60 measured);
  ramp scenes render 270 (9 steps x 30). The scene root is
  `markNeedsPaint()`-ed every frame so static scenes still measure a real
  paint + raster pass, matching Klaxon's `renderer.paint` on every frame.
- **Timing**: `SchedulerBinding.addTimingsCallback` receives one
  `FrameTiming` per presented frame. **Frame work = buildDuration +
  rasterDuration**. Flutter 3.47's `FrameTiming` has no separate layout phase
  — the engine folds layout into `buildDuration` — so build + raster is
  Flutter's analog of Klaxon's tick + layout + paint. `fps =
  1000 / avg(frame work)`; `frame_time` avg/p50/p99/p99.9 over the measured
  frames (nearest-rank percentile, same as `bench.zig`). In release builds
  the engine batches FrameTimings (~1 Hz); each batch still carries one
  FrameTiming per presented frame, and the first frame's timing is delivered
  immediately.
- **jank (schema v2)**: a frame is jank if `frame_ms > 16.67` (60 Hz budget,
  Macrobenchmark/JankStats convention); `jank_frames` = count,
  `jank_pct` = percent of measured frames.
- **Wall-clock op timing (`extra.op_ms`, `latency_ms`, `teardown_ms`/
  `resume_ms`)**: `BenchHarnessState.beginWallOp` records the wall clock at
  the mutation and the current engine `frameData.frameNumber`; it completes
  on the `FrameTiming` carrying that frame (+ `waitFrames`), reporting
  `rasterFinishWallTime - start` — i.e. mutate + build + one full render
  pass. The engine can run ahead of the ticker (animated scenes produce >1
  frame per tick), so after the frame plan ends the harness drains in-flight
  timings for up to 2 s to let pending ops resolve; an op whose completing
  frame never renders is reported as unresolved on stderr.
- **draw_calls_per_frame**: the number of `RenderObject`s under the scene
  root (walked via a `GlobalKey` + `visitChildren` at the end of the run),
  sampled once the scene finishes. Klaxon counts visible painted nodes;
  Flutter's retained render tree is the analog — `ListView.builder`
  virtualization keeps this small for the scroll scenes (~10 live rows).
- **rss_mb**: `ProcessInfo.currentRss / 1e6`, sampled at the end of the scene.
- **ttff_ms**: scene start → the scene's first completed frame (arrival of
  its first `FrameTiming`). Running one process per scene (as `run.sh` does)
  keeps this clean: the first frame's timing is sent immediately without
  batching. In the single-process all-scenes mode, later scenes may include
  the engine's ~1 s timing-batch delay in `ttff_ms`.
- **frames_rendered**: the scene's frame plan (130 default; 70 list_ops;
  270 ramp), per the contract.
- **binary_size_bytes**: size of the running .app's main executable
  (`Platform.resolvedExecutable`).

## Known non-parities (read before comparing numbers)

1. **Engine RSS floor**: a Flutter macOS app carries the engine
   (`libFlutterMacOS.framework` + Dart AOT runtime) — expect ~100-300 MB RSS
   before any scene work, vs Klaxon's single-digit/low-tens MB binary.
2. **Raster backend**: Flutter 3.47 on macOS defaults to **Impeller**;
   Klaxon rasterizes through **Skia** (`kx_skia`). The GPU pipelines differ.
3. **Device pixel ratio**: the 640x480 logical window rasterizes at the
   display's DPR (2x on retina = 1280x960 physical pixels); Klaxon's headless
   raster target is 640x480 physical. Raster-bound scenes (glass_blur,
   video_playback, backdrop_scroll) raster ~4x the pixels.
4. **Reactive rebuild**: Flutter rebuilds dirty widgets every frame (the
   build phase); Klaxon is a retained tree (tick + layout-if-dirty + paint).
   Flutter's per-frame work includes widget rebuilds; Klaxon's does not.
   Static scenes measure build ~0 (nothing rebuilds) + forced repaint.
5. **Vsync pacing**: frames are presented at the display rate; the metric is
   per-frame *work* (build + raster), not wall time, so pacing does not
   affect the numbers — but it does mean ~130 frames take a few seconds per
   scene.
6. **resize scene**: Klaxon recreates the raster surface at sizes up to
   960x640; the Flutter window stays 640x480, so sizes above 640x480 clamp
   (the constraint cycle still relayouts every frame where the clamped size
   changes).
7. **video_playback**: Klaxon uploads a fresh texture per frame (CPU pixel
   loop + texture create/draw/destroy). Dart has no synchronous texture
   upload (`ui.Image` creation is async), so the Flutter port regenerates the
   pixel buffer (same CPU loop) + a frame-dependent display list instead.
8. **glass_blur / backdrop_scroll**: Klaxon's "blur" is a saveLayer + alpha
   tint (no real blur); Flutter's `BackdropFilter` is a real backdrop blur —
   expect the Flutter scene to do strictly more raster work in both scenes.
9. **input_ime**: the caret blink schedules a few extra near-zero-work
   frames that are counted as measured frames.
10. **binary_size_bytes**: the Flutter number is the thin .app main
    executable; the engine lives in `libFlutterMacOS.framework` (~tens of MB)
    and is not counted. Klaxon's number is its whole statically-linked
    binary. Not comparable as "app size" — see the .app bundle size for
    that.
11. **overdraw_stack**: `Stack` children with alpha are blended inline by
    Impeller (no `saveLayer` is allocated per layer unless the scene forces
    one); the spec's "forces saveLayer/compositing cost" maps to 24
    full-screen alpha blends, not 24 saveLayer records.
12. **images_ramp decode**: `ui.Image` decode is async in Dart; the scene
    requests it at construction and the harness awaits it in `prepare()`
    before the frame clock starts — no warmup or measured frame can draw
    without the image (startup decode excluded, per spec).
13. **app_switch**: real OS lifecycle transitions (`AppLifecycleState`) are
    engine-driven and cannot be injected from Dart. The port measures the
    closest idiom — unmount + remount of a ~230-node tree — so
    `teardown_ms`/`resume_ms` measure widget teardown/remount cost, not a
    platform suspend.
14. **input_latency**: the injected pointer event is a real framework event
    (hit test + gesture dispatch run), but OS->Dart IPC latency is not part
    of the measurement — `latency_ms` starts at injection inside the app.
15. **semantics_build**: `nodes_per_frame` counts the live `SemanticsNode`
    tree once built (~1002 = 1000 labelled cells + merge nodes + root). The
    per-frame rebuild is driven by `markNeedsSemanticsUpdate` + a manual
    `flushSemantics()` inside the build phase so the compile cost lands in
    `buildDuration` (drawFrame's own flush happens after compositeFrame).
16. **text sizes**: the spec's `sp` values are rendered at the same logical
    size (Flutter has no separate text-scale factor configured), i.e.
    14sp -> 14 logical px.
17. **list_ops frames_rendered = 70 / ramp = 270**: per the spec these
    families measure 60 post-op frames and 9x30 stepped frames
    respectively, not the default 130.

## Files

```
bench/runners/flutter/
├── lib/main.dart            entry point: scene selection + JSON report (schema v2)
├── lib/harness.dart         frame loop, metrics, wall-op timing, JSON-scene plumbing
├── lib/scenes/*.dart        the 33 scenes + the registry (scenes.dart) + shared
│                            bases (list_ops_base, ramp_base, gallery_tree)
├── macos/                   flutter create --platforms macos scaffold
│   └── Runner/MainFlutterWindow.swift   fixed 640x480 window
├── run.sh                   build + run all scenes, save JSONs
├── pubspec.yaml
└── .gitignore               (.dart_tool/, build/, macos/Flutter/ephemeral, ...)
bench/results/flutter/       one JSON report per run (committed)
```

Do not commit `build/` or `.dart_tool/` (gitignored).
