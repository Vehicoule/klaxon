# Benchmark Scene Catalogue — cross-framework conformance spec

Canonical spec for the Klaxon bench suite (`src/bench.zig`) and every
cross-framework runner (`bench/runners/{flutter,compose,qt}`). Phase 4c.6.

A scene is comparable ONLY if all four runners build the same logical tree,
run the same per-frame workload, and emit the same metrics. Where a framework
has no exact equivalent, the runner implements the closest idiom and documents
the gap in `bench/runners/<fw>/README.md` — never silently substitutes.

## Harness contract (all runners)

- Surface: **640×480 logical px**, opaque background `#14141CFF`.
- Timing: `warmup 10 frames + 120 measured frames`, monotonic clock
  (`SDL_GetTicksNS` / `Stopwatch` / `System.nanoTime` / equivalent).
- Metrics per scene (JSON, schema version 2):
  - `frame_time_avg_ms`, `frame_time_p50_ms`, `frame_time_p99_ms`,
    **`frame_time_p999_ms` (new)**,
    **`jank_frames` + `jank_pct` (new)** — a frame is jank if
    `frame_ms > 16.67` (60 Hz budget, Macrobenchmark/JankStats convention),
  - `fps` (= 1000/avg), `draw_calls_per_frame`, `rss_mb`, `ttff_ms`,
    `frames_rendered`,
  - scene-extra fields (below) under `extra: {}`.
- Runners may add fields; they may NOT rename or drop contract fields.
  Missing optional fields serialize as `null`.

## Family A — `list_ops` (krausest js-framework-benchmark, native adaptation)

One shared row widget: 48 dp height, label `"Row NNNN — klaxon bench"` left,
small square (16×16) filled `#7C4DFFFF` right. List of plain rows in a
scrollable column, 640×480 viewport. Each op = one scene; the metric is
`extra.op_ms` = wall time of the operation itself (build/mutate + one full
render pass). Frame timing metrics collected over 60 frames after the op.

| scene | operation |
|---|---|
| `list_create_1k` | render 1000 rows from empty → `op_ms` = first-complete-render time |
| `list_replace_1k` | swap all 1000 row models → full rebuild render |
| `list_update_10th` | mutate every 10th row label (100 updates) |
| `list_swap_rows` | swap row 5 ↔ row 995 contents (not widgets) |
| `list_remove_row` | delete middle row |
| `list_clear_1k` | remove all rows → render empty state |

Framework notes: Compose = LazyColumn items + mutable state list; Flutter =
ListView.builder + setState; Qt = ListView + ListModel ops; Klaxon = the
virtualized list widget (scroll_10k infra) — virtualization stays ON (it is
the framework's idiom); the op measures the model→render path, not layout of
1000 live nodes.

## Family B — `ramp` (MotionMark methodology)

Headless adaptation: stepped ramp instead of continuous. Steps
`N = 10, 25, 50, 100, 200, 400, 800, 1600, 3200`; 20 measured frames per step
(same warmup contract per step). Report per-step `frame_time_p50` in
`extra.ramp[]` and `extra.n_max_60fps` = largest step with p50 ≤ 16.67 ms.
This is the "how much until it breaks" metric — far more comparative than a
fixed N.

| scene | per-item workload |
|---|---|
| `shapes_ramp` | N rounded rects (r=8dp, 40×24, alternating `#7C4DFF`/`#03DAC6`, each translating 4px/frame on a Lissajous path) |
| `paths_ramp` | N identical 12-point closed bezier paths (~200 pts of tessellation), rotating 1°/frame |
| `text_ramp` | N instances of `"The quick brown fox 0123456789"` at 14sp, horizontal offset oscillating |
| `images_ramp` | N copies of ONE 64×64 RGBA test image (checkerboard 8px, generated at startup), each scaled 0.75× and moving |

Notes: images must be decoded ONCE per runner (startup cost excluded —
measures sampling/draw, not decode). Flutter = Image.memory + CustomPainter
or positioned widgets; Compose = Canvas + drawImage; Qt = Image items or
Canvas; Klaxon = image widget/atlas path.

## Family C — `stress` (known-divergence scenarios)

| scene | construction + per-frame work |
|---|---|
| `overdraw_stack` | 24 full-screen rects, each `alpha=0x1F` over the last, alternating `#7C4DFF`/`#03DAC6` — forces saveLayer/compositing cost; static (the cost is in paint, not anim) |
| `elevation_grid` | 10×10 grid of 48×40 cards, M3 elevation shadow (r=12, dy=2, blur=6, `rgba(0,0,0,0.30)`) — every shadow re-rasterized per frame while card fill color oscillates ±4% lightness |
| `relayout_storm` | 200 rows each animating width 200↔440 dp (2s loop) — forces per-frame measure+layout of the subtree (NOT a compositable transform) |
| `mount_churn` | every frame: destroy 50 widgets, create 50 new ones (label+icon card, random id), steady-state pool 500 — the GC/allocator pressure test |
| `scroll_anim` | scroll_10k list scrolling at 600 dp/s WHILE 30 embedded row icons pulse opacity — mixed scroll+anim jank |
| `text_rich` | 60 paragraphs × 3 lines, mixed: bold/italic spans, 3 font sizes (12/16/20sp), one LTR+RTL bidi line per paragraph (`"مختصر Klaxon عربي test اختبار"`) — shaping stress |
| `chart_live` | line chart, 1000 points, polyline rebuilt fully every frame + axes/grid (10×8) — the real dashboard case |
| `clip_path` | 120 nodes each clipped by a 6-point star path, contents scrolling under the clip |
| `theme_switch` | full gallery-like tree (200+ nodes), alternate light/dark theme every 30 frames — global invalidation cost |
| `backdrop_scroll` | scrolling content (200 items) under a fixed 640×160 backdrop-blur band (σ=12) + 60% scrim — mobile's worst case |

## Family D — `system` (non-paint paths)

| scene | measurement |
|---|---|
| `input_latency` | inject synthetic pointer event → frames until the visual response paints; `extra.latency_frames`, `extra.latency_ms` |
| `pointer_storm` | 1000 hit-test queries/frame over a 500-node tree (no paint change) — pure hit-test cost |
| `semantics_build` | build/diff the a11y semantics tree of a 1000-node tree each frame — `extra.nodes_per_frame` |
| `app_switch` | pause→resume cycle every 60 frames: teardown cost `extra.teardown_ms`, resume-to-frame `extra.resume_ms` |

## Harness additions (schema v2)

- `frame_time_p999_ms`, `jank_frames`, `jank_pct` added to `Metrics` —
  computed from the same `frame_times` array, zero extra renders.
- Ramp scenes set `extra.ramp` (array of {n, p50_ms}) + `extra.n_max_60fps`.
- Op scenes set `extra.op_ms`.
- `bench/report.html` + `scripts/bench-report.py` render new fields;
  missing `extra` = blank cell (older results stay valid).

## Scene naming + JSON

`BenchScene` enum names are the contract — `kebab_case` in JSON/CLI,
`snake_case` in code. Unknown scene name = runner exits non-zero (fail loud).

## Out of scope (documented, not implemented)

- GPU-vs-raster per scene (all runners render raster for determinism —
  GPU comparison is a separate device-lab effort).
- Multi-window, video decode (video_playback already approximates),
  real network images.
