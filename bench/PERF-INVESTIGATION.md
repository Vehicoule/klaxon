# Perf investigation — `bench/results/20261011-124018.json` anomalies

Branch `fix/bench-perf-scenes`. Investigated the two alarming scenes from the
official run: `gallery` (fps 19.3, frame p99 114.5 ms, TTFF 227 ms) and
`scroll_10k` (fps 361.8, frame p99 40.1 ms vs avg 2.8 ms).

**Verdicts up front:**

- `gallery` — **real engine bottleneck**, not a pathological scene. The scene
  is the real gallery app rendered under the bench's documented contract
  (every frame is a full repaint). ~91% of its frame cost is spent painting
  nodes that are entirely outside the viewport clip: the engine has no
  paint-time culling, and every `Text` node re-shapes and re-measures its
  string every frame. Fix belongs in `src/ui/node.zig` /
  `src/widgets/text.zig` / `kx_skia` — NOT fixed here (engine is read-only
  for this task); see "Root causes" below.
- `scroll_10k` — **scene is healthy; the p99 spikes are measurement-host
  noise**, not scene logic. On this machine the scene runs 3010 frames with
  p99 = 0.75 ms and max = 1.6 ms; the official run shows the same ~15–40 ms
  p99 band on *every* scene (even `input_ime` at 3 draw calls, p50 0.4 → p99
  21.1), which no scene mechanism explains.

## Tooling added (this branch)

`src/bench.zig` gained env-var-gated diagnostics (no change to the JSON
report contract); wired in `src/bench_main.zig`:

| Env var | Effect |
| --- | --- |
| `KLAXON_BENCH_PHASES=1` | stderr: per-phase tick/layout/paint avg/p50/p99 + the 8 slowest frames with their phase split + relayout count |
| `KLAXON_BENCH_TRACE_DIR=<dir>` | per-frame CSV `<dir>/<scene>.csv`: `frame,tick_ms,layout_ms,paint_ms,total_ms,relayout,had_damage` |
| `KLAXON_BENCH_PROFILE=1` | after the measured run, 8 extra frames with per-node **own-paint** timing bucketed per vtable (+ per gallery section), including how much own-paint lands on nodes fully OFF-surface |
| `KLAXON_BENCH_HIDE_SCROLL_CONTENT=1` | gallery counterfactual: hides the ScrollView content column (≈ "what if paint-time culling existed") |

The frame loop also clears the root damage accumulator after each paint
(mirroring `host.zig`), so the trace's `had_damage` column answers "would a
real app's host repaint this frame clipped or not at all".

## Numbers — healthy host vs official run

Mac dev host (Apple Silicon), `zig build bench` (ReleaseSmall, 600 measured
+ 10 warmup frames, 640×480 raster — the bench contract size shared with the
Flutter/Qt/Compose runners):

| scene | fps | avg ms | p50 | p99 | draw calls | RSS MB | TTFF |
| --- | --- | --- | --- | --- | --- | --- | --- |
| hello | 31725 | 0.03 | 0.03 | 0.1 | 2 | 17.0 | 24.1 |
| scroll_10k | 2657 | 0.38 | 0.37 | 0.6 | 60 | 18.1 | 1.3 |
| text_cjk | 12454 | 0.08 | 0.08 | 0.2 | 6 | 18.3 | 0.6 |
| glass_blur | 2282 | 0.44 | 0.43 | 0.6 | 15 | 20.7 | 0.5 |
| anim_100 | 4850 | 0.21 | 0.20 | 0.3 | 101 | 21.1 | 0.2 |
| **gallery** | **149** | **6.7** | **6.7** | **7.5** | **696** | 105.4 | 33.5 |
| resize | 2784 | 0.36 | 0.3 | 0.8 | 47 | 109.4 | 1.2 |
| input_ime | 5773 | 0.17 | 0.2 | 0.4 | 3 | 109.8 | 0.4 |
| video_playback | 4302 | 0.23 | 0.2 | 0.3 | 3 | 110.1 | 0.5 |

Saved as `bench/reference-20261011-localmac.json` — deliberately NOT under
`bench/results/` so `scripts/bench-report.py` doesn't merge it over the
official run (it globs `bench/results/**/*.json`).

The official-run host is ~7–8× slower across *all* scenes (hello paint
0.03 ms here vs ~0.06–0.1 there; scroll_10k avg 0.38 vs 2.8) and its RSS
baseline (≈17–45 MB, vs ≈100 MB on macOS) matches the Linux CI proxy noted
in docs/STATUS.md. So the absolute official numbers are host-scaled, but the
*relative* anomalies (gallery ~20× hello; the p99 spike band) are real
signals investigated below.

## `gallery` — where the 52/6.7 ms goes

Phase split (`KLAXON_BENCH_PHASES=1`):

```
tick   avg 0.000 ms   (scene is fully static — no per-frame work)
layout avg 0.000 ms   (1 relayout in 610 frames: the initial build)
paint  avg 6.73 ms    p50 6.70  p99 7.54  max 17.2 (frame 0 = cold caches)
total  avg 6.81 ms
```

100% of the frame is `renderer.paint` = `kx_begin_frame` + `kx_clear` +
`root.paint` + overlay + `kx_end_frame`. `had_damage` is 1 on frame 0 only —
a real app's host loop would paint this tree once then idle **unless an
animation runs** (the real gallery has indeterminate loading/progress
indicators whose tickers mark damage every frame; the bench scene doesn't
install a Timeline, so it measures the equivalent of "host repaints every
frame" = the app's steady-state under animation/scroll).

Per-node own-paint profile (`KLAXON_BENCH_PROFILE=1`), 8 extra frames:

```
697 node-paints/frame, own-paint ≈ 6.7 ms/frame
6.10 ms/frame (91%) on nodes fully OFF-surface      ← the headline
3 deferred/overlay nodes per pass

text        177 calls/f   2.91 ms/f   16.4 µs avg   2.55 ms offscreen
group         1 call      0.57 ms/f   (sample label: "Date picker")
icon         57 calls/f   0.51 ms/f    9.0 µs avg
group         1 call      0.36 ms/f   ("Calendar")
group         2 calls     0.31 ms/f   ("Navigation rail")
group         1 call      0.28 ms/f   ("Time picker")
list_item     7 calls/f   0.19 ms/f
text         18 calls/f   0.18 ms/f   ("Pressed 0 times" — BoundText)
group         1 call      0.17 ms/f   ("Data table")
…container ×77 0.03 ms/f, button ×17+2 0.06 ms/f, text_field ×6 0.12 ms/f…
```

Per-section bucket (own-paint summed over each content-column child):

```
Date picker 0.61 · Buttons 0.50 · Scroll (10k list + grid) 0.46 ·
Calendar 0.39 · Navigation rail 0.36 · Time picker 0.33 ·
Typography & media 0.32 · Navigation chrome 0.30 · Chips 0.29 ·
Pull to refresh 0.28 · Input 0.27 · … (spread across all 33 sections)
```

**Counterfactual** (`KLAXON_BENCH_HIDE_SCROLL_CONTENT=1`, scroll content
hidden): **0.11 ms/frame, 15 draw calls** vs 6.7 ms / 696. The ScrollView
clips children to the viewport at the canvas level but still *walks and
paints every node*; nearly all of the cost is below the fold.

### Root causes (engine — documented, not fixed)

1. **No paint-time culling.** `Node.paint` (`src/ui/node.zig:268-278`)
   calls `vtable.paint` on every visible node and recurses into every
   non-`defer_paint` child unconditionally. `ScrollView`
   (`src/widgets/scroll_view.zig:76-85`) wraps children in
   `kx_clip_rect`+`translate` — Skia's rasterizer culls the clipped
   geometry, but only *after* each op's CPU-side setup (paint objects,
   path building, and — worst — text shaping) is already paid. The widget
   tree itself is correct (a real app does retain the whole scroll
   content); the paint traversal just can't skip it.
   *Minimal repro:* `zig build bench -Dbench-scene=gallery` vs
   `KLAXON_BENCH_HIDE_SCROLL_CONTENT=1 zig build bench -Dbench-scene=gallery`
   → 6.7 ms → 0.11 ms.
   *Fix direction:* early-out in `Node.paint` when the node's bounds
   (mapped through ancestor `map_paint_rect` transforms — `mapRectToRoot`,
   node.zig:360) don't intersect the current damage/clip region. The root
   already accumulates `damage` (node.zig:135-139, 202-219); the host
   clips the repaint to it, so damage-intersection culling inside the
   traversal would let clipped repaints skip whole off-damage subtrees.
   Alternative: a `quickReject` hook letting scrollables skip child
   ranges outside the viewport.

2. **Text is re-shaped and re-measured every frame.**
   `textPaint` (`src/widgets/text.zig:49-55`) calls
   `ui.paint.measureText` *and* `ui.paint.text` per paint. Each crosses the
   ABI into `kx_draw_text_styled`/`kx_measure_text`
   (`kx_skia/src/kx_skia_common.cpp:120-146`), which calls
   `kx_make_font` → `kx_fonts()->legacyMakeTypeface(...)` (a font-mgr
   lookup per call) and `drawSimpleText` (UTF-8 decode + shaping + strike
   lookup per call). ~200 text-ish nodes → ~400+ font operations per
   frame; measured ~16 µs per `text` node → **≈3.2 ms/frame, ~48% of the
   gallery frame**, and the `group` panels (date picker 565 µs, calendar
   365 µs, nav rail, time picker, table, tree — single nodes that draw
   cell grids internally) pay the same per-string cost inside their own
   paint.
   *Fix direction:* cache `measureText` per (text, size, bold) in the
   Text node's state (invalidate on set), or cache a `SkTextBlob` per
   string in the shim; either turns per-frame shaping into a lookup.

3. **`kx_layer_alpha` pushes a full-clip saveLayer.**
   `kx_skia_common.cpp:298-305` calls `saveLayerAlphaf(nullptr, a)` —
   `nullptr` bounds = an offscreen bitmap the size of the *current clip*.
   On the host path (clip = damage rect) this is already bounded; on the
   bench's unclipped pass it's a whole-surface alloc+composite per alpha
   layer (glass/dialogs/snackbar/fades). Minor here (~0.2 ms/f for the
   group's layers) but it scales with surface area.
   *Fix direction:* pass the node's damage-expanded bounds instead of
   `nullptr` (the paint.zig wrapper knows the rect at every call site).

### Why the official run showed 114.5 ms p99 / 51.9 avg

Same 696-node full repaint on a ~7.7× slower (Linux CI-class) host; the
p99-vs-p50 gap there is the same host noise that hits `scroll_10k` (below).
Nothing gallery-specific beyond the big per-frame paint bill.

### STATUS.md "~3.3 ms smoke" discrepancy — explained

The ~3.3–3.5 ms figure in docs/STATUS.md was measured:

- through `zig build gallery`'s host loop on the dev Mac — same
  full-repaint work per rendered frame as the bench (the host renders
  every iteration when `on_frame` is set; dirty-rect only shrinks the
  *raster* area, not the node-walk/draw-issue cost that dominates here);
- at Phase 2b/2d-0/2d.1 when the gallery was **~31–44 widgets**; it now
  hosts **~80 widgets / 33 sections (~696 nodes)** — roughly 2× the tree,
  matching 3.3 → 6.7 ms.

So both numbers are "whole-tree repaint" of the real app — the discrepancy
is tree growth, not a methodology break.

## `scroll_10k` — p99 spikes

Phase split here (600 measured frames; every frame relayouts — the window
churns ~1–2 items/frame via `syncItemWindow`):

```
tick   avg 0.006 ms   (setScrollOffset + window re-diff)
layout avg 0.067 ms   (re-layout of the ~10-row live window)
paint  avg 0.303 ms   (≈60 painted nodes = ~10 rows × icon/text/card + chrome)
total  avg 0.376 ms   p50 0.367  p99 0.563  max 0.738
```

3010-frame run (`-Dbench-frames=3000` + `KLAXON_BENCH_TRACE_DIR`): p99
0.75 ms, max 1.6 ms, **no frames above 2 ms**. The only >1 ms frames are
frame 0 (warmup boundary) and a late-run cluster (~frames 2960–2985, offset
≈ item 3050+) where rows cost ~2× baseline — mild, bounded (likely wider
4-digit labels hitting slightly different shape/strike paths), and nowhere
near 40 ms.

**What happens per frame is uniform by construction**: offset advances
37 px/frame (≈1 row), `syncItemWindow` drops ~1 row at one edge and
creates ~1 row at the other (card+row+icon+text ≈ 4 nodes), `markDirty` +
`markLayoutDirty` → relayout of the live window, paint. No periodic heavy
event exists in the scene: the `@mod` wrap (a full window re-create, ~10
rows) can't trigger inside 610 frames (offset maxes at ~22.5k px of
~359.7k; wrap would need frame ≈9728).

**Why the official run spikes to 40 ms:** the band is identical across
*all* scenes on that run — `input_ime` (3 draw calls) p99 21.1 ms,
`text_cjk` (static, 6 draw calls) p99 13.9 ms, `hello` (0.06 ms frames —
the only scene whose entire 610-frame run fits in ~40 ms of wall time, so
it plausibly dodged the stalls) is the only exception. A stall hitting
trivial and complex scenes alike at the same magnitude is host noise
(CPU contention / throttling on the bench host), not scene logic. Scene-
internal candidates were ruled out by the trace: no window re-anchor
(jump), no layout blowup, no allocator cliff (RSS stays ~18 MB; note the
arena in `bench_main` never reclaims destroyed rows — bounded churn, ~1–2
rows/frame). Worth re-running the official host with
`KLAXON_BENCH_TRACE_DIR` to confirm the spikes land on wall-clock
boundaries there.

## Files changed

- `src/bench.zig` — `RunOptions` diagnostics fields; per-phase frame
  timing + `clearDamage` after paint; CSV trace writer; per-node own-paint
  profiler (`profileNode`/`profileOverlay`) with vtable probes,
  off-surface accounting, and gallery per-section bucketing.
- `src/bench_main.zig` — `KLAXON_BENCH_*` env vars → `RunOptions`.
- `bench/reference-20261011-localmac.json` — fresh healthy-host reference
  run (this machine, unchanged scenes); kept outside `bench/results/` so
  the report generator doesn't merge it over the official numbers.
- `bench/PERF-INVESTIGATION.md` — this document.

No scene definitions changed: both anomalies trace to (documented) engine
behavior or host noise — the scenes measure what a real app would.
