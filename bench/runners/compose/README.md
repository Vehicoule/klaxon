# Compose Multiplatform comparison benchmark runner (roadmap Phase 4c.4/4c.6)

A Compose Multiplatform (Desktop, JVM) port of Klaxon's own benchmark
(`src/bench.zig` + `src/bench_main.zig`): it renders the **same scenes** at
the **same harness settings** and emits the **same JSON report**, so Klaxon
(Zig + Skia + SDL3) and Compose can be compared head-to-head on identical
workloads. The catalogue is the 9 original `bench.zig` scenes plus the 24
schema-v2 scenes of `docs/specs/bench-scenes.md` (6 `list_ops`, 4 `ramp`,
10 `stress`, 4 `system`) — **33 scenes total**, one `java -jar` run.

```
bench/runners/compose/
├── build.gradle.kts        Kotlin/JVM project + org.jetbrains.compose plugin + fatJar task
├── settings.gradle.kts     plugin + dependency repositories
├── gradle.properties       workers.max=2 (shared machine), JVM/Kotlin daemon heaps
├── gradlew + gradle/       Gradle 8.12 wrapper (distribution cached in ~/.gradle)
├── run.sh                  build + run all 33 scenes (or one via $1), save the JSON
├── README.md               this file
├── .gitignore              build/, .gradle/
└── src/main/kotlin/bench/compose/
    ├── Bench.kt            the harness: frame loop, metrics v2, JSON report, --probe
    ├── Scenes.kt           the 9 original scenes + per-frame tick + SceneState
    ├── ScenesListOps.kt    Family A — the 6 list_ops scenes + shared row widget
    ├── ScenesRamp.kt       Family B — the 4 ramp scenes + the shared Lissajous
    ├── ScenesStress.kt     Family C — the 10 stress scenes
    └── ScenesSystem.kt     Family D — the 4 system scenes
```

## Usage

```sh
# all 33 scenes (builds first; OpenJDK 21 via Homebrew — run.sh sets JAVA_HOME):
bench/runners/compose/run.sh

# one scene (e.g. scroll_10k, list_create_1k, shapes_ramp, input_latency):
bench/runners/compose/run.sh scroll_10k

# headless render sanity checks (dev-only):
java -jar build/libs/klaxon-bench-compose-all.jar --probe
```

The runner prints the JSON report to stdout (progress + verification go to
stderr) and writes the same report to
`bench/results/compose/<ISO8601-timestamp>.json`. Klaxon's side of the
comparison: `scripts/bench.sh` (writes `bench/results/<timestamp>.json`).

## Harness contract (identical to Klaxon's bench)

| setting | value | source |
|---|---|---|
| viewport | 640×480 | `RunOptions` (bench.zig) |
| frames | 10 warmup + 120 measured = **130 rendered** (schema v2 contract — was 600 measured pre-v2) | `bench-scenes.md` harness contract |
| pacing | **unpaced** — render as fast as the raster backend allows, no vsync, no timer | bench.zig's loop |
| per-frame work | scene tick + recomposition + layout + draw (+ post-render work for `semantics_build`), timed per frame | `Harness.renderFrame` |
| fps | `1000 / frame_time_avg_ms` | bench.zig |
| frame_time avg/p50/p99/**p999** | over the measured frames, nearest-rank percentile | bench.zig `percentile` (+ schema v2) |
| jank_frames / jank_pct | frames with `frame_ms > 16.67` (60 Hz budget, Macrobenchmark/JankStats convention) | schema v2 |
| draw_calls_per_frame | placed Compose layout nodes (see below) | bench.zig `countPaintNodes` analog |
| rss_mb | process RSS — `ps -o rss= -p <pid>` (KiB → MiB), sampled after the last frame | devtools.zig analog |
| ttff_ms | run start (surface + scene + composition included) → end of the first completed frame | bench.zig |
| extra | per-scene fields under `extra: {}` — `op_ms`, `ramp[]`+`n_max_60fps`, `latency_frames`/`latency_ms`, `nodes_per_frame`, `teardown_ms`/`resume_ms`, plus runner-added `hit_tests_per_frame`/`switch_cycles` | schema v2 |
| JSON schema | field names, order, types and `%.1f` number formatting; scenes emit `"extra": {}` when they set none | bench_main.zig + schema v2 |

**Frame plans by scene kind** (`SceneKind`): `NORMAL` = 10+120; `LIST_OP` =
10 warmup + 1 op frame (timed as `extra.op_ms`, excluded from the frame stats)
+ 60 measured; `RAMP` = 9 steps (10, 25, 50, 100, 200, 400, 800, 1600, 3200)
× (10 warmup + 20 measured) = 270 rendered, per-step p50 in `extra.ramp[]`,
pooled 180 measured frames for the top-level metrics.

## Architecture choice: headless `ComposeScene`, not a windowed app

**Verdict: headless works — `androidx.compose.ui.scene.CanvasLayersComposeScene`
rendering into a CPU raster Skiko surface (`Surface.makeRasterN32Premul` +
`surface.canvas.asComposeCanvas()`).** No window, no GPU, no AWT event loop,
no vsync — the windowed fallback was not needed.

`CanvasLayersComposeScene` is the scene API Compose itself uses for offscreen
rendering (screenshot testing, `ImageComposeScene`). Its `render(canvas,
nanoTime)` runs, synchronously on the calling thread (verified against the
Compose Multiplatform 1.8.2 sources, `BaseComposeScene.render`):

```
flush composition effects → recomposition → frame clock → measure/layout → draw
```

That is the Compose analog of Klaxon's per-frame `tick + layout + paint`: the
harness mutates scene state in `tick(frame)` (the bench.zig `SceneRunner.tick`
port), then times one `scene.render(...)` call — recomposition picks the state
changes up inside the timed region, exactly where Klaxon's signal sets +
timeline tick land. The loop is unpaced: 130 iterations for normal scenes
(10 warmup + 120 measured), 71 for list_ops, 270 for the 9-step ramp ladder.

A windowed desktop app (`compose.desktop.application`) would have been
vsync-paced and window-driven; it was rejected for the same reason Klaxon's
bench is headless.

Frames-render verification (`--probe`, all headless, printed to stderr):

- a scene renders ink (a 100×100 box paints exactly 10 000 non-background
  pixels);
- a state change recomposes (the surface hash changes between frames);
- `runBlocking { lazyListState.scrollToItem(500) }` does not hang and applies
  (`firstVisibleItemIndex == 500`, pixels change) — this is the scroll_10k
  tick mechanism;
- CJK + emoji text renders real glyphs (4 640 ink pixels for a 22sp CJK/emoji
  line; Skiko shapes via CoreText with system fallback fonts — PingFang SC for
  CJK, Apple Color Emoji for emoji; verified by ink density, not tofu);
- layout-node counting walks the tree (3 placed nodes for a `Box { Text }`);
- `sendPointerEvent(Press)` reaches a `pointerInput` handler synchronously —
  the input_latency mechanism (schema v2);
- the merged semantics tree walks via the `SemanticsOwner` reflection bridge —
  the semantics_build mechanism (2 nodes for a `Box { Text }`).

### Known constant overhead vs Klaxon

`scene.render()` allocates a thin `SkiaBackedCanvas` wrapper per frame and runs
Compose's snapshot/recomposition bookkeeping that Klaxon's lean Zig tree does
not have. Both are small constants next to the per-frame work; the JVM also
JIT-warms during the run (Klaxon is AOT).

## draw_calls_per_frame definition

Klaxon estimates draw calls as the number of **visible nodes painted per
frame** (`countPaintNodes` over the widget tree, counted after the final
frame). The Compose port counts the **placed `LayoutNode`s in the scene's
layout tree** after the final frame — the same "visible painted nodes"
definition, one node per Compose layout node. Virtualized scenes only compose
their live window (LazyColumn), matching what a real frame paints.

The `ComposeScene` interface exposes no layout-tree accessor in Compose
Multiplatform 1.8.2, and `LayoutNode`/`Owner` are internal in the published
artifacts — so the count is a small reflection bridge, documented here:
`scene.mainOwner` (field) → `RootNodeOwner.getOwner()` → `Owner.getRoot()` →
walk `LayoutNode.getChildren()` / `LayoutNode.isPlaced()` (getters located by
name, setAccessible). No Compose internals are patched or relied on beyond
these reads.

Granularity caveats (inherent to the mapping, not bugs):

- Compose widgets are built from more internal layout nodes than Klaxon's
  widget-tree nodes: `input_ime` reports 15 nodes vs Klaxon's 3 (an M3
  `TextField` is container + input + label + supporting text + indicator +
  decorations), `glass_blur` 21 vs 15 (one `Box` per panel/bar/card layer vs
  Klaxon's custom single-node glass card).
- `hello` (3 vs 2), `scroll_10k` (55 vs 60), `text_cjk` (7 vs 6),
  `anim_100` (102 vs 101), `resize` (50 vs 47), `video_playback` (4 vs 3) are
  all within node-granularity noise.

## Scene mapping (Klaxon → Compose)

| scene | Klaxon (bench.zig) | Compose port (Scenes.kt) | tick parity |
|---|---|---|---|
| hello | centered `Text` "Hello, Klaxon!" 24px white | `Box(center) { Text }` | static |
| scroll_10k | column(16/12) [ title, box(max 880×300) [ listView 10 000 × 36px, row = card `#2A2A3E` r6 pad 8/6 [ ★ 14 `#FFD54F`, "Item #N" 14 white ] ] ] | same tree; `LazyColumn` `items(10000)`, same delegate (star drawn as a vector path) | `runBlocking { scrollToItem(off/36, off%36) }` with `off = (frame*37) mod (10_000*36-300+1)` — identical formula (frame 0 is the offset-0 no-op) |
| text_cjk | column(24/10) of 5 texts (14/22/22/22/18, same strings incl. 🌍🎉) | identical strings, sizes, colors | static |
| glass_blur | backdrop `#101426` [ stack [ deco column: 3 panels `#E91E63/#3F51B5/#00ACC1` 150px r12; 3 glass cards 300×110 r16 at center/top-right/bottom-left ] ]; card = `layerAlpha(0.45)` + tint rrect + 3 white bars (α 1/.7/.5) | same tree; card = `alpha(0.45f)` + tint + 3 bar `Box`es | static |
| anim_100 | grid(10 cols, gap 8, pad 16) of 100 animated containers; tick retargets height `24+16·sin(phase)` and color `lerp(#3F51B5,#E91E63,(sin+1)/2)`, `phase = frame*0.06 + i*0.17`; timeline +8 ms/frame; spring k=380 c=32 m=1 (exact closed form) | a custom non-virtualized `SimpleGrid` (1 layout node + 100 `Box`es — a `LazyVerticalGrid` would virtualize the overflow row away); the tick evaluates the **same closed-form spring step** (same constants, dt=8 ms, v0=0 per retarget) per lane (height + RGBA) per widget and writes the 200 snapshot states | identical phase/target/spring math |
| gallery | the full gallery app (gallery.zig): header + `scrollView` [ 32 sections ] over the dark M3 theme (696 visible nodes) | representative port: header (title/subtitle/2 chips) + a plain `Column` of 24 varied cards (button, switch, slider, progress, text field, checkbox, typography, list item — all live, overflow clipped like Klaxon's non-virtualized scroll view; 187 nodes) | static |
| resize | column(16/12) [ title, row of 3 cards (`#2A2A3E` r8 pad 12 "Card" 13), box(max 880×200) [ listView 2 000 × 32px ] ]; tick cycles RESIZE_SIZES | same tree; tick sets `scene.size` + recreates the raster surface (Klaxon's `kx_resize`) | identical RESIZE_SIZES cycle |
| input_ime | column(24/12) [ title, filled text field (label "Message", placeholder "こんにちは…", supporting text, light theme) ]; frame 0: click to focus; then IME commits cycling 6 strings, backspace every 12th frame | same tree (M3 filled `TextField`, light colors); commits drive the `value` state programmatically, backspace drops the last code point (surrogate-pair safe) | identical string cycle + backspace cadence |
| video_playback | column(16/12) [ title, video widget 320×180 ]; paint regenerates pixels per frame (x/y gradient + white bar at `(frame*3) mod w`, 24px wide) and uploads a fresh texture | same tree; a `Canvas` whose draw lambda regenerates the identical pixel buffer (N32 memory order) and uploads it through a fresh Skiko `Bitmap` (`installPixels` + `drawImage`) every frame | identical per-pixel algorithm |

## Schema-v2 scene mapping (bench-scenes.md → Compose)

| scene | spec | Compose idiom |
|---|---|---|
| list_create_1k … list_clear_1k | 48dp rows (`"Row NNNN — klaxon bench"` + 16×16 `#7C4DFF` square) in a scrollable 640×480 column; op timed as `op_ms` | `LazyColumn` (virtualization stays ON per spec) over a `SnapshotStateList<ListRowModel>`; the op mutates the list inside the frame-10 tick and `op_ms` = that tick + one full render pass. `NNNN` = zero-padded row id. `list_replace_1k` gets fresh ids (krausest rebuilds data); `list_swap_rows` swaps the label contents and keeps keys in place ("contents, not widgets") |
| shapes_ramp | N rounded rects 40×24 r8, alternating `#7C4DFF`/`#03DAC6`, translating 4px/frame on a Lissajous path | N `Box`es in one viewport `Box`; positions via `Modifier.offset{}` reading the shared frame clock (placement-phase read, no recomposition). Path: `x = 300+280·sin(t+i·0.61)`, `y = 228+200·sin(1.4t+i·0.83)`, `t = frame·0.015` (~4 px/frame peak per axis) |
| paths_ramp | N identical 12-point closed beziers (~200 pts tessellation), rotating 1°/frame | one shared 12-anchor Catmull-Rom gear `Path` drawn by N `Canvas` nodes at scattered offsets, `graphicsLayer { rotationZ = frame % 360 }` (draw-phase read) |
| text_ramp | N × `"The quick brown fox 0123456789"` 14sp, horizontal offset oscillating | N `Text` nodes at scattered positions, `offset{}` adds `40·sin(frame·0.1+i·0.5)` |
| images_ramp | N copies of ONE 64×64 RGBA checkerboard (8px), 0.75×, moving | one Skiko `Bitmap` built in the first composition (warmup covers startup, per spec); N `Canvas` nodes `drawImage(dstSize = 48×48)` on the shared Lissajous path |
| overdraw_stack | 24 fullscreen rects, `alpha=0x1F`, alternating | `Modifier.alpha(31/255).background(...)` — alpha<1 forces a compositing layer per rect; static |
| elevation_grid | 10×10 grid of 48×40 cards, M3 shadow r=12 dy=2 blur=6 `rgba(0,0,0,.30)`, fill ±4% lightness | `Modifier.shadow(6.dp, RoundedCornerShape(12.dp), ambient/spot = rgba(0,0,0,.30))` + `drawBehind` rrect fill scaled ±4% (draw-phase read repaints fill AND shadow). CMP 1.8.2 has no `dropShadow`; elevation 6.dp stands in for blur=6 and dy is not separately controllable — gap documented |
| relayout_storm | 200 rows animating width 200↔440dp, 2s loop | width read inside `Modifier.layout{}` — a **measure-phase** read: real per-frame measure+layout, explicitly not a composable transform |
| mount_churn | destroy 50 + create 50 label+icon cards per frame, pool 500 | `SnapshotStateList` of 500 ids in a non-virtualized `Column` with `key(id)`; deterministic LCG picks the 50 removals, 50 new ids append |
| scroll_anim | scroll_10k at 600dp/s + 30 embedded row icons pulsing opacity | `LazyColumn` 10k scrolled 10dp/frame (`scrollToItem`, the frame-time equivalent of 600dp/s at 60Hz); **2 pulsing icons per row** via `graphicsLayer{alpha}` — ~28 live in the ~14-row window vs the spec's 30 (closest idiom, gap documented) |
| text_rich | 60 paragraphs × 3 lines, bold/italic spans, 12/16/20sp, one bidi line each | 180 `Text` nodes (annotated spans + `"مختصر Klaxon عربي test اختبار"` 16sp + 20sp body) in a non-virtualized `Column`; static — Skiko caches shaped runs so steady-state cost is the full repaint (gap documented) |
| chart_live | 1000-pt polyline fully rebuilt + axes/grid 10×8 | one `Canvas`: `DoubleArray` slides 1 pt/frame (2 sines + LCG noise), `Path` rebuilt in the draw lambda, 10v+8h gridlines + axis rect |
| clip_path | 120 nodes star-clipped, contents scrolling | `SimpleGrid` of 120 `Box`es clipped by a `GenericShape` 6-point star; inner 2-band column scrolls via placement-phase `offset{}` |
| theme_switch | 200+-node gallery-like tree, light/dark every 30 frames | ~365-node themed tree (40 cards × ~9 nodes); palette object in snapshot state, toggled by the tick → full recompose + repaint |
| backdrop_scroll | 200 items under fixed 640×160 backdrop-blur band σ=12 + 60% scrim | closest idiom: a second non-scrollable `LazyColumn` inside the clipped band, scrolled in lockstep by the tick and blurred with `Modifier.blur(12.dp)` (σ≈radius px at density 1), scrim `rgba(0,0,0,.6)` on top |
| input_latency | inject pointer event → frames until visual response paints | `sendPointerEvent(Press)` at (320,240) inside frame 40; the target's `pointerInput` flips the response state → `latency_frames` counts renders until the frame that ran with the response set (dispatch is synchronous here: 1 frame), `latency_ms` = inject→that render's end |
| pointer_storm | 1000 hit-test queries/frame over a 500-node tree | 500 boxes with (empty) `pointerInput` handlers in a 25×20 `SimpleGrid`; the tick sends 1000 `Move` events at a deterministic pseudo-scatter — full hit-test dispatch, no paint change |
| semantics_build | build/diff the a11y tree of a 1000-node tree each frame | 1000 `Text` nodes (each a semantics node); the tick recomposes a rotating 100-node window (text+description change → real semantics diff) and the post-render hook walks the merged tree via `Owner.semanticsOwner` (reflection bridge like `countLayoutNodes`), counting `nodes_per_frame` (~1001) |
| app_switch | pause→resume every 60 frames; `teardown_ms`/`resume_ms` | headless has no lifecycle → closest idiom: `scene.close()` (teardown) then rebuild the `ComposeScene` + `setContent` through the end of the first rendered frame (resume-to-frame); cycles at frames 60/120, extras = averages |

## Known non-parities (read before comparing numbers)

1. **gallery is not apples-to-apples.** Klaxon's gallery is the full
   32-section showcase (696 visible nodes); the Compose port is a
   representative 24-card subset (187 nodes). Treat gallery as a structural
   smoke test, not a timing comparison (same caveat as the Qt port's 316
   items).
2. **input_ime:** the M3 `TextField` re-lays-out / re-shapes the **entire**
   text buffer on every commit (the buffer grows to ~2 100 chars over the
   run, as in Klaxon). Klaxon's text field re-shapes far less per frame, so
   Compose is expected to be much slower here — a real framework difference in
   text-layout efficiency, not a port bug (the Qt port shows the same effect:
   7.1 ms/frame).
3. **input_ime input path:** Klaxon dispatches real `text_input` events
   through its input router (and the Qt port delivers real
   `QInputMethodEvent`s). Headless Compose has no IME; the tick commits the
   same strings by driving the field's `value` state — the programmatic
   analog. No real keyboard events are synthesized.
4. **anim_100:** Klaxon's displayed spring values freeze at their initial
   values (each frame's retarget cancels the in-flight animation and the lazy
   start evaluates it at t=0 — see `Animation.valueAt` /
   `SceneRunner.tick`); its per-frame work is 200 signal sets + 200
   play/cancel + 200 t=0 evaluations + paint, with no relayout after frame 0.
   The Compose port (like the Qt port) **steps** the springs 8 ms/frame toward
   the moving targets, so it does the relayout + repaint of all 100 widgets
   every frame that the scene's own comment describes ("a relayout + repaint
   of all 100 every frame"). Compose therefore does strictly more per-frame
   layout work than Klaxon on this scene.
5. **glass_blur:** Klaxon's card is one custom node (an alpha *layer*, the
   documented "blur stand-in" — the kx_skia ABI has no blur primitive), so
   **neither side does a real backdrop blur**; Compose replicates the alpha
   layer with `Modifier.alpha(0.45f)`. Node-count granularity differs (see
   draw_calls).
6. **ttff:** Klaxon's scenes are compiled into its binary; the Compose runner
   pays JVM classloading + Compose runtime + Skiko native load + font-system
   init on the first scene (hello: ~267 ms vs Klaxon's 36 ms). Later scenes
   are warm (24–125 ms).
7. **rss_mb** is the JVM process RSS — a ~110–770 MB floor for the Compose
   runtime + Skiko natives + JIT/GC churn (Klaxon: 17–45 MB). The value is
   the honest end-of-run process RSS (a high-water mark: the JVM does not
   return memory eagerly; video_playback's per-frame bitmap churn and
   input_ime's 2 100-char buffer grow it). **binary_size_bytes** is the
   runnable fat jar (app + Compose runtime + macOS-arm64 Skiko natives,
   40 707 631 bytes) vs Klaxon's static 6.5 MB bench binary — not comparable
   (same caveat as Qt's 112 KB dynamically-linked runner).
8. **JIT vs AOT:** Compose scenes run interpreted/JIT-warmed during the 610
   frames (10 warmup frames only); Klaxon is AOT-compiled. This biases
   Compose's steady-state numbers slightly high (warm) on the early scenes
   and is a constant framework difference.
9. **Text engines differ:** Klaxon shapes with Skia/HarfBuzz; Compose desktop
   (Skiko) shapes with CoreText (system fallback fonts — PingFang SC for CJK,
   Apple Color Emoji for emoji; verified real glyphs by ink-density probes).
10. **resize:** the scene is resized via `scene.size` + a raster-surface
    recreation inside the timed tick (Klaxon's `kx_resize` analog); the
    relayout + surface-realloc work per frame is the same.
11. **Machine noise:** measurements were taken on a shared, heavily loaded
    box (another sub-agent may run builds concurrently). Frame-time tails
    (p99) and run-to-run variance are dominated by co-tenant load, not by the
    frameworks.
12. **Schema v2 frame budget:** the contract moved from 600 to 120 measured
    frames (plus kind-specific plans — see the contract table). Old
    `bench/results/compose/*.json` files are schema v1 (600 measured, no
    p999/jank/extra) and are NOT frame-count-comparable with v2 runs.
13. **scroll_anim icon count:** the spec's "30 embedded row icons" can't be
    literal — `LazyColumn` only composes the ~14-row live window. The port
    puts 2 pulsing icons on every row → ~28 live, the closest steady-state
    approximation.
14. **elevation_grid shadows:** CMP 1.8.2 has no `dropShadow`/`innerShadow`
    modifier, so the port uses `Modifier.shadow(elevation = 6.dp,
    RoundedCornerShape(12.dp), ambient = spot = rgba(0,0,0,.30))` — blur≈6
    maps to elevation, but dy=2 has no separate control (the stock shadow's
    offset derives from elevation). Real shadow re-rasterization either way.
15. **backdrop_scroll is a two-list approximation:** no stock backdrop-blur
    exists on desktop, so a second `LazyColumn` mirrors the scroller inside
    the clipped band under `Modifier.blur(12.dp)`. The cost shape is right
    (an extra composed+blurred row window per frame) but it is not a true
    "blur whatever is behind me" compositing op.
16. **app_switch pause/resume = dispose + recreate:** headless
    `ComposeScene` has no lifecycle hooks, so `teardown_ms` is `scene.close()`
    (composition disposal) and `resume_ms` is scene construction + `setContent`
    + first rendered frame — heavier than a real suspend/resume (which keeps
    the composition alive); that is the honest headless analog of the spec's
    "pause→resume cycle".
17. **input_latency counts render passes, not input-thread hops:** the
    synthetic `Press` is dispatched synchronously by `sendPointerEvent`, so
    `latency_frames` is 1 here — it measures how many renders a
    state-driven visual response takes to paint, not real device input
    latency (impossible headless; the same caveat as `input_ime`).
18. **semantics_build walks, it doesn't serialize:** `nodes_per_frame`
    counts nodes traversed in the merged `SemanticsOwner` tree plus the
    rotating 100-node subtree rebuild forced by per-frame text/description
    mutations. Real a11y diff/serialization is a platform-service path that
    doesn't exist headless — the traversal + incremental rebuild is the
    closest measurable idiom.
19. **pointer_storm hit tests are move-event dispatches:** each
    `sendPointerEvent(Move)` runs the full pointer hit-test + dispatch over
    the 500 `pointerInput` targets — the "query" includes event allocation
    and change-list processing a bare hit-test call wouldn't pay.

## Results (this machine, 2026-10-11; see `bench/results/compose/`)

> **Note:** the tables below are schema-v1 numbers (600 measured frames, no
> p999/jank/extra) from the original 9-scene suite — kept for history; v2
> results land in `bench/results/compose/*.json` as they are generated.

Compose side: `bench/runners/compose/run.sh` (all 9 scenes, one process).
Klaxon side: `zig build bench` (`scripts/bench.sh`), same session. Qt side:
`bench/runners/qt/run.sh`, same session (see `bench/runners/qt/README.md`).

| scene | Klaxon fps | Compose fps | Qt fps | Klaxon avg ms | Compose avg ms | Qt avg ms | Klaxon draws | Compose draws | Qt draws |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| hello | 16504.6 | 23862.0 | 24491.4 | 0.1 | 0.0 | 0.0 | 2 | 3 | 2 |
| scroll_10k | 361.8 | 732.1 | 2319.6 | 2.8 | 1.4 | 0.4 | 60 | 55 | 50 |
| text_cjk | 1903.9 | 12727.5 | 23404.0 | 0.5 | 0.1 | 0.0 | 6 | 7 | 7 |
| glass_blur | 335.3 | 3954.2 | 7278.1 | 3.0 | 0.3 | 0.1 | 15 | 21 | 24 |
| anim_100 | 719.1 | 887.6 | 372.4 | 1.4 | 1.1 | 2.7 | 101 | 102 | 103 |
| gallery | 19.3 | 4754.5 | 16221.1 | 51.9 | 0.2 | 0.1 | 696 | 187 | 316 |
| resize | 428.8 | 1280.1 | 4488.2 | 2.3 | 0.8 | 0.2 | 47 | 50 | 42 |
| input_ime | 892.2 | 132.7 | 141.7 | 1.1 | 7.5 | 7.1 | 3 | 15 | 8 |
| video_playback | 530.4 | 2788.1 | 2157.0 | 1.9 | 0.4 | 0.5 | 3 | 4 | 4 |

Full Compose-side metrics (fps / avg / p50 / p99 ms, draws, rss MB, ttff ms):

| scene | fps | avg | p50 | p99 | draws | rss | ttff |
|---|---:|---:|---:|---:|---:|---:|---:|
| hello | 23862.0 | 0.0 | 0.0 | 0.1 | 3 | 109.1 | 266.6 |
| scroll_10k | 732.1 | 1.4 | 1.1 | 3.8 | 55 | 189.0 | 125.3 |
| text_cjk | 12727.5 | 0.1 | 0.1 | 0.1 | 7 | 197.5 | 49.3 |
| glass_blur | 3954.2 | 0.3 | 0.3 | 0.3 | 21 | 197.7 | 24.5 |
| anim_100 | 887.6 | 1.1 | 1.1 | 1.8 | 102 | 220.2 | 26.3 |
| gallery | 4754.5 | 0.2 | 0.2 | 0.3 | 187 | 171.3 | 205.7 |
| resize | 1280.1 | 0.8 | 0.7 | 1.9 | 50 | 217.2 | 26.1 |
| input_ime | 132.7 | 7.5 | 7.3 | 14.2 | 15 | 655.5 | 34.3 |
| video_playback | 2788.1 | 0.4 | 0.3 | 0.8 | 4 | 767.6 | 27.9 |

Reading: on the trivial static/text scenes all three are in the same
thousands-of-fps wash (CPU rasters, warm glyph caches; Compose/JVM and Qt lead
Klaxon's per-node paint cost there). On `scroll_10k` and `resize` Compose sits
between Klaxon and Qt. On `anim_100` Compose beats Klaxon only because it
does the relayout+repaint work the scene intends (non-parity 4) — Klaxon's
frozen springs skip it. On `input_ime` Compose matches Qt's full-re-shape
behavior and is ~7× slower than Klaxon (non-parity 2). `gallery` is not
comparable (non-parity 1). Re-run all three sides back-to-back on an idle
machine before drawing conclusions.
