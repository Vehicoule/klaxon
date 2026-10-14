# Jetpack Compose Android benchmark runner (Klaxon comparison)

An on-device sibling of `bench/runners/compose` (desktop Compose
Multiplatform): it renders a **subset of the same scenes** at the **same
harness contract** on a real Android surface and emits the **same JSON
report** as Klaxon's own tier-2 Android run (`src/bench.zig
runAndroidSuite`, `files/bench.json`) — so Jetpack Compose and Klaxon
(Zig + Skia + SDL3, Ganesh GLES on both sides) can be compared on identical
workloads on the same device.

```
bench/runners/compose-android/
├── build.gradle.kts        AGP 8.7.3 / Kotlin 2.1.21 / compose-compiler plugin pins
├── settings.gradle.kts     google + mavenCentral + gradlePluginPortal
├── gradle.properties       workers.max=2, 2 GB heaps (shared machine)
├── gradlew + gradle/       Gradle 8.12 wrapper (distribution cached in ~/.gradle)
├── local.properties        sdk.dir=… (not committed)
├── run.sh                  build + install + launch + pull the JSON report
├── README.md               this file
└── app/src/main/java/bench/compose/
    ├── BenchmarkActivity.kt  launcher activity + root composable + intent extras
    ├── Bench.kt              the harness: draw-driven scene clock, FrameMetrics
    │                         collector, stats, Klaxon-compatible JSON report
    ├── Scenes.kt             hello, scroll_10k, anim_100, input_ime + SceneState
    ├── ScenesRamp.kt         shapes_ramp, text_ramp, images_ramp (Lissajous)
    └── ScenesStress.kt       elevation_grid, mount_churn
```

## Usage

```sh
# everything at once (build → install → run all 9 scenes → pull JSON):
bench/runners/compose-android/run.sh                 # device: first adb device
bench/runners/compose-android/run.sh emulator-5554   # or pick one

# manual:
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew assembleRelease
adb -s emulator-5554 install -r app/build/outputs/apk/release/app-release.apk

# launch = bench run (like Klaxon's debug.klaxon.bench=1):
adb -s emulator-5554 shell am start \
    -n com.klaxon.bench.compose/bench.compose.BenchmarkActivity

# intent extras:
#   -e scenes "hello,scroll_10k"   comma-separated subset (default: all 9)
#   --ei warmup N --ei frames N    frame counts (default 10 / 120; ramps are fixed)
#   --ez debug true                logcat: per-frame phase dumps (tag KlaxonBench)

# pull the report (both are written; run-as needs isDebuggable, which we set):
adb -s emulator-5554 shell run-as com.klaxon.bench.compose cat files/bench-compose.json
adb -s emulator-5554 pull \
    /sdcard/Android/data/com.klaxon.bench.compose/files/bench-compose.json
```

Watch progress live: `adb logcat -s KlaxonBench` (one `scene … presented=N
drawn=N avg=X ms` line per scene).

## Harness contract (vs Klaxon's Android bench)

| setting | this runner | Klaxon (`runAndroidSuite`) |
|---|---|---|
| surface | full-panel HWUI window, `decorFitsSystemWindows=false`, density forced to 1.0 (dp/sp = raw px) | SDL fullscreen window on the emulator panel |
| frames | 10 warmup + 120 measured = **130 presented** (RAMP: 9 steps × 30 = 270) | 130 rendered (same schema-v2 contract) |
| pacing | draw-driven: each recorded frame re-invalidates for the next → frames as fast as the pipeline takes them | `eglSwapInterval(1)` vsync-paced loop |
| per-frame work | `INPUT_HANDLING + ANIMATION + LAYOUT_MEASURE + DRAW + SYNC + COMMAND_ISSUE` (FrameMetrics phases) — recompose + measure/layout + display-list draw + RT sync + GPU command issue | tick + layout + paint (Skia emission + GLES submit) − `last_frame_wait_ns` |
| excluded | `UNKNOWN_DELAY` (vsync→traversal scheduling gap), `SWAP_BUFFERS` (present/queue wait) | eglSwapBuffers paced wait (`last_frame_wait_ns`) |
| fps | `1000 / frame_time_avg_ms` — work rate | same |
| frame_time avg/p50/p99/p999 | over measured presented frames, nearest-rank | same |
| jank | `frame_ms > 16.67` | same (60 Hz budget) |
| draw_calls_per_frame | placed `LayoutNode`s after the last frame (reflection bridge, like the desktop runner) | `countPaintNodes` |
| rss_mb | `/proc/self/status` VmRSS | devtools.zig analog |
| ttff_ms | scene publish → end of first presented frame | same idea |
| extra | Klaxon's 8 contract keys; `ramp[]` + `n_max_60fps` on ramp scenes | same |
| backend | `"compose-hwui-gles"` | `"ganesh-gles"` |

Extra fields this report adds (all sibling keys, Klaxon schema untouched):
`presented_fps` (wall presentation rate), `dropped_frames` (HWUI dropCount),
`drawn_frames` (frames the UI thread actually recorded — ≈ presented +
pipeline tail), `gpu_frame_time_avg_ms` (`FrameMetrics.GPU_DURATION`, API
33+ — async raster; `null` if the platform doesn't report it).

## The scene clock: one tick per *recorded* frame

Klaxon calls `tick()` then paints once per loop iteration. An idiomatic
Compose runner **can't tick per vsync**: when the render pipeline presents
slower than vsync (this emulator's SwiftShader stack presents ~30–60 fps on
a 60 Hz panel), two vsync ticks' worth of mutations would merge into one
presented frame — `mount_churn` would pay 100 widget swaps in a frame
instead of 50, ramp step boundaries would bisect measured windows.

So the scene tick runs **inside the root `drawBehind` lambda**
(`BenchRunner.onSceneFrame`, `Bench.kt`): exactly one `tick()` per frame the
UI thread records, and the lambda's heartbeat state self-write
re-invalidates it for the next traversal. The `frame` argument the scenes
see is therefore the presented-frame index — the sequence of *drawn* frames
steps scroll offsets, animation phases, IME commits, churn batches and ramp
step boundaries exactly like Klaxon's per-frame sequence. Draws are produced
as fast as HWUI will record them; the loop stops the moment the run ends.

Measurement is `Window.OnFrameMetricsAvailableListener` (the same pipeline
JankStats/Macrobenchmark read): one event per presented frame, collected
until the 10+120 (or 9×30) quota is met. `fps` stays the honest *work rate*
like Klaxon's unpaced number; `presented_fps` shows what actually hit the
display.

## Scene subset (9 of the 33-scene catalogue)

Implemented — prioritized for framework-overhead and render-cost coverage:

`hello`, `scroll_10k` (LazyColumn, 10 000 rows, same `off = frame*37`
formula), `anim_100` (same closed-form spring step per lane per frame),
`input_ime` (M3 `TextField`, same commit strings/backspace cadence),
`elevation_grid` (`Modifier.shadow` + `drawBehind` fill), `mount_churn`
(`SnapshotStateList` + `key(id)`, same LCG), `shapes_ramp`, `text_ramp`,
`images_ramp` (same Lissajous path, same checkerboard at 0.75×).

Skipped, and why:

- **list_ops (6), gallery, resize, video_playback, text_cjk, glass_blur** —
  time-boxed subset; `list_ops` needs the op-frame/`op_ms` protocol,
  `resize`/`video_playback` need custom surface/texture plumbing that HWUI
  doesn't expose cleanly. Desktop runner covers them.
- **paths_ramp, overdraw_stack, relayout_storm, scroll_anim, text_rich,
  chart_live, clip_path, theme_switch, backdrop_scroll** — same family as
  implemented scenes (more of the same primitives); ramp + stress coverage
  is already representative.
- **input_latency, pointer_storm, semantics_build, app_switch** — need real
  pointer injection / semantics-tree access / activity lifecycle cycling;
  the input-path one is documented under non-parities instead.

## Known non-parities (read before comparing numbers)

1. **Emulator + SwiftShader.** This run is on `emulator-5554` (1080×2400,
   API 34, ANGLE→SwiftShader software raster, GLES 3.1). Numbers are
   emulator-specific: `gpu_frame_time_avg_ms` (~9–23 ms) is software
   rasterization cost that hardware GLES wouldn't pay, and `presented_fps`
   is often GPU-bound rather than CPU-bound. Klaxon's `tier2-android-gles`
   numbers on the same emulator carry the same caveat.
2. **Surface size.** Spec scenes are authored for a 640×480 logical surface;
   both runners use the full panel (1080×2400) like Klaxon's tier-2 run —
   more pixels for the GPU than the spec assumes (see caveat 1), same for
   both sides. Density is forced to 1.0 so dp/sp values equal the spec's px.
3. **`input_ime` has no real IME.** The tick drives the `TextField`'s
   `value` state with the same commit strings — the programmatic analog of
   Klaxon's `text_input` events (the desktop port does the same). And like
   the desktop port, the M3 `TextField` re-lays-out/re-shapes the **whole
   buffer** per commit — a real framework difference, expected slower.
4. **`anim_100` does strictly more layout work than Klaxon** (springs are
   stepped toward moving targets and re-layout every frame; Klaxon's
   retarget cancels the in-flight animation and paints at t=0). Same caveat
   as the desktop/Qt ports — the scene's comment describes the intended
   relayout+repaint.
5. **`elevation_grid` shadow mapping:** `Modifier.shadow(elevation, shape)`
   — 6 dp stands in for the spec's blur=6/dy=2 (no separate control);
   elevation oscillates 4–8 dp so shadows re-rasterize every frame.
6. **Work attribution under drops.** The tick runs in the frame's draw
   phase; when HWUI drops a traversal between vsyncs, that vsync never gets
   a tick (the scene clock doesn't advance) — so no work "escapes" between
   measured frames by construction. The ~1–2-frame in-flight pipeline tail
   is recorded but its samples land inside the run's warmup or are counted
   in `drawn_frames` only.
7. **JVM/JIT + RSS.** Compose on ART JIT-warms during warmup frames and the
   process RSS (≈137–290 MB here) is inherently larger than Klaxon's native
   RSS (~110 MB) — same caveat as the desktop port.
8. **`draw_calls_per_frame` granularity.** Placed LayoutNodes ≈ Klaxon's
   painted-node count, but Compose widgets decompose into more internal
   nodes (an M3 `TextField` is ~15 nodes; `mount_churn`'s 500 rows ≈ 1504).
   Same caveat as the desktop runner.
9. **`hello`'s 5-node draw + ~7 ms CPU work** is dominated by COMMAND_ISSUE
   (RenderThread GLES submission on the emulator's SwiftShader GLES
   translator). `gpu_frame_time_avg_ms` is the rest of the story.

## Sample numbers (`emulator-5554`, 2026-10-14, this checkout)

| scene | fps | presented | frame_avg | p99 | jank% | gpu_avg | nodes |
|---|---|---|---|---|---|---|---|
| hello | 141.2 | 60.0 | 7.08 | 8.34 | 0.0 | 16.87 | 5 |
| scroll_10k | 70.6 | 60.0 | 14.16 | 19.12 | 11.7 | 16.89 | 52 |
| anim_100 | 108.8 | 60.2 | 9.20 | 13.39 | 0.0 | 16.82 | 104 |
| input_ime | 134.8 | 60.0 | 7.42 | 9.52 | 0.0 | 16.90 | 17 |
| elevation_grid | 79.3 | 59.5 | 12.61 | 18.25 | 4.2 | 17.02 | 104 |
| mount_churn | 13.8 | 13.7 | 72.25 | 87.77 | 100.0 | 22.22 | 1504 |
| shapes_ramp | 85.2 | 51.4 | 11.74 | 37.66 | 22.2 | 11.97 | 3204 |
| text_ramp | 63.7 | 44.2 | 15.70 | 66.46 | 27.2 | 19.11 | 3204 |
| images_ramp | 84.2 | 50.0 | 11.87 | 43.82 | 21.7 | 16.00 | 6404 |

Ramp p50 by n (ms): shapes 7.5→34.4, text 7.1→58.4, images 7.7→36.9 across
n=10→3200; `n_max_60fps` = 800 for all three. `binary_size_bytes` = ~9.4 MB
(APK; the Klaxon side reports native-lib size). Re-runs vary ±10–40% on
lighter scenes (JIT warmup, emulator host scheduling); mount_churn is
stable at ~72 ms. Saved reports land in `bench/results/compose-android/`.
