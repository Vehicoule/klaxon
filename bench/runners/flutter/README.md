# Flutter comparison bench runner (roadmap Phase 4c.4)

Renders the same 9 scenes as Klaxon's own bench (`src/bench.zig`,
`src/bench_main.zig`) through Flutter on macOS, collects the same metrics,
and emits the **same JSON report**, so Klaxon and Flutter can be compared
head-to-head. This directory is self-contained: it does not touch `src/`,
`kx_skia/`, `build.zig`, or `scripts/`.

## Usage

```sh
bench/runners/flutter/run.sh                 # build (first time) + run all 9 scenes
bench/runners/flutter/run.sh hello anim_100  # run a subset
```

`run.sh` runs `flutter build macos --release` on first use (the first build
downloads ~1 GB of engine artifacts and takes a while), then runs the built
.app once **per scene** from the repo root. Each run prints the JSON report
to stdout and writes it to `bench/results/flutter/<ISO8601-timestamp>.json`
(colons in the timestamp are replaced with `-` for filesystem safety; the
output directory can be overridden with `KLAXON_BENCH_OUT_DIR`).

The binary also accepts a scene name directly (one scene) or no argument
(all 9, one process) — same selection contract as `klaxon bench`:

```sh
APP=bench/runners/flutter/build/macos/Build/Products/Release/klaxon_bench.app
"$APP/Contents/MacOS/klaxon_bench" hello     # one scene
"$APP/Contents/MacOS/klaxon_bench"           # all 9
```

## Scene mapping

| Klaxon (`src/bench.zig`) | Flutter port (`lib/scenes/`) | Notes |
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
  non-parities). 10 warmup + 600 measured frames per scene = **610 frames**.
  The scene root is `markNeedsPaint()`-ed every frame so static scenes still
  measure a real paint + raster pass, matching Klaxon's `renderer.paint` on
  every frame.
- **Timing**: `SchedulerBinding.addTimingsCallback` receives one
  `FrameTiming` per presented frame. **Frame work = buildDuration +
  rasterDuration**. Flutter 3.47's `FrameTiming` has no separate layout phase
  — the engine folds layout into `buildDuration` — so build + raster is
  Flutter's analog of Klaxon's tick + layout + paint. `fps =
  1000 / avg(frame work)`; `frame_time` avg/p50/p99 over the 600 measured
  frames (nearest-rank percentile, same as `bench.zig`). In release builds
  the engine batches FrameTimings (~1 Hz); each batch still carries one
  FrameTiming per presented frame, and the first frame's timing is delivered
  immediately.
- **draw_calls_per_frame**: the number of `RenderObject`s under the scene
  root (walked via a `GlobalKey` + `visitChildren` at the end of the run),
  sampled once the scene finishes. Klaxon counts visible painted nodes;
  Flutter's retained render tree is the analog — `ListView.builder`
  virtualization keeps this small for the scroll scenes (~10 live rows).
- **rss_mb**: `ProcessInfo.currentRss / 1e6`, sampled at the end of the scene.
- **ttff_ms**: scene start → the scene's first completed frame (arrival of
  its first `FrameTiming`). Running one process per scene (as `run.sh` does)
  keeps this clean: the first frame's timing is sent immediately without
  batching. In the single-process all-9 mode, scenes 2..9 may include the
  engine's ~1 s timing-batch delay in `ttff_ms`.
- **frames_rendered**: 610 (10 warmup + 600 measured), per the contract.
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
   video_playback) raster ~4x the pixels.
4. **Reactive rebuild**: Flutter rebuilds dirty widgets every frame (the
   build phase); Klaxon is a retained tree (tick + layout-if-dirty + paint).
   Flutter's per-frame work includes widget rebuilds; Klaxon's does not.
   Static scenes measure build ~0 (nothing rebuilds) + forced repaint.
5. **Vsync pacing**: frames are presented at the display rate; the metric is
   per-frame *work* (build + raster), not wall time, so pacing does not
   affect the numbers — but it does mean ~610 frames take ~5-10 s per scene.
6. **resize scene**: Klaxon recreates the raster surface at sizes up to
   960x640; the Flutter window stays 640x480, so sizes above 640x480 clamp
   (the constraint cycle still relayouts every frame where the clamped size
   changes).
7. **video_playback**: Klaxon uploads a fresh texture per frame (CPU pixel
   loop + texture create/draw/destroy). Dart has no synchronous texture
   upload (`ui.Image` creation is async), so the Flutter port regenerates the
   pixel buffer (same CPU loop) + a frame-dependent display list instead.
8. **glass_blur**: Klaxon's "blur" is a saveLayer + alpha tint (no real
   blur); Flutter's `BackdropFilter` is a real backdrop blur — expect the
   Flutter scene to do strictly more raster work here.
9. **input_ime**: the caret blink schedules a few extra near-zero-work
   frames that are counted as measured frames.
10. **binary_size_bytes**: the Flutter number is the thin .app main
    executable; the engine lives in `libFlutterMacOS.framework` (~tens of MB)
    and is not counted. Klaxon's number is its whole statically-linked
    binary. Not comparable as "app size" — see the .app bundle size for
    that.

## Files

```
bench/runners/flutter/
├── lib/main.dart            entry point: scene selection + JSON report
├── lib/harness.dart         frame loop, metrics, JSON-scene plumbing
├── lib/scenes/*.dart        the 9 scenes + the registry (scenes.dart)
├── macos/                   flutter create --platforms macos scaffold
│   └── Runner/MainFlutterWindow.swift   fixed 640x480 window
├── run.sh                   build + run all scenes, save JSONs
├── pubspec.yaml
└── .gitignore               (.dart_tool/, build/, macos/Flutter/ephemeral, ...)
bench/results/flutter/       one JSON report per run (committed)
```

Do not commit `build/` or `.dart_tool/` (gitignored).
