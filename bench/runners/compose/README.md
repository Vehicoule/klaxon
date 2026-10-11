# Compose Multiplatform comparison benchmark runner (roadmap Phase 4c.4)

A Compose Multiplatform (Desktop, JVM) port of Klaxon's own benchmark
(`src/bench.zig` + `src/bench_main.zig`): it renders the **same 9 scenes** at
the **same harness settings** and emits the **same JSON report**, so Klaxon
(Zig + Skia + SDL3) and Compose can be compared head-to-head on identical
workloads.

```
bench/runners/compose/
├── build.gradle.kts        Kotlin/JVM project + org.jetbrains.compose plugin + fatJar task
├── settings.gradle.kts     plugin + dependency repositories
├── gradle.properties       workers.max=2 (shared machine), JVM/Kotlin daemon heaps
├── gradlew + gradle/       Gradle 8.12 wrapper (distribution cached in ~/.gradle)
├── run.sh                  build + run all 9 scenes (or one via $1), save the JSON
├── README.md               this file
├── .gitignore              build/, .gradle/
└── src/main/kotlin/bench/compose/
    ├── Bench.kt            the harness: frame loop, metrics, JSON report, --probe
    └── Scenes.kt           the 9 scenes + the per-frame tick + the anim_100 spring
```

## Usage

```sh
# all 9 scenes (builds first; OpenJDK 21 via Homebrew — run.sh sets JAVA_HOME):
bench/runners/compose/run.sh

# one scene:
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
| frames | 10 warmup + 600 measured = **610 rendered** | `RunOptions` + `-Dbench-frames=600` |
| pacing | **unpaced** — render as fast as the raster backend allows, no vsync, no timer | bench.zig's loop |
| per-frame work | scene tick + recomposition + layout + draw, timed per frame | `Harness.run` |
| fps | `1000 / frame_time_avg_ms` | bench.zig |
| frame_time avg/p50/p99 | over the 600 measured frames, nearest-rank percentile | bench.zig `percentile` |
| draw_calls_per_frame | placed Compose layout nodes (see below) | bench.zig `countPaintNodes` analog |
| rss_mb | process RSS — `ps -o rss= -p <pid>` (KiB → MiB), sampled after the last frame | devtools.zig analog |
| ttff_ms | run start (surface + scene + composition included) → end of the first completed frame | bench.zig |
| JSON schema | field names, order, types and `%.1f` number formatting identical to `bench_main.zig` `formatReport` | bench_main.zig |

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
timeline tick land. The loop is unpaced: 610 iterations back-to-back.

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
- layout-node counting walks the tree (3 placed nodes for a `Box { Text }`).

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

## Results (this machine, 2026-10-11; see `bench/results/compose/`)

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
