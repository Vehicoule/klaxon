# Deviations & audit register

Single register for places where Klaxon deliberately (or knowingly) deviates
from upstream Material 3 Expressive / platform behavior. Anything here is
**honest incompleteness**, not a hidden fake — silent approximations are
treated as bugs (see docs/M3E-PORT.md: "replace approximated draw/measure
code; don't patch it").

## Fixed in the 2026-10-16 audit

| Finding | Fix |
|---|---|
| GestureDetector + Scrollbar registered timeline tickers only at construction (lost long-press/thumb tracking when built before the timeline) | lazy `ensureTicker` retry on pointer-down / first paint (`66e2b1e`) |
| 200 ms `TAP_TIMEOUT_MS` swallowed presses held 200–499 ms | tap now bounded by the long-press timeout, per upstream (`66e2b1e`) |
| `easings.emphasized_accelerate` = (0.3,0.1,0.2,1), wrong vs MotionTokens (0.3,0,0.8,0.15), and unreachable | constant fixed + `anim.Ease.emphasized_accelerate` added (`66e2b1e`) |
| Spring presets matched no published scheme; effects ζ 0.9 underdamped | full ExpressiveMotionTokens set: default/spatial (380,0.8), effects (1600,1.0) critically damped, fast/slow variants; Switch thumb + TextField label → `fast_spatial`, drawer close → `fast_effects` (`66e2b1e`) |
| `SDL_UpdateTexture` failure left stale texels in the damage rect forever | `present_failed` forces one full repaint + one-shot log (`66e2b1e`) |
| WASM without generated font header linked a silently empty font manager | runtime diagnostic in `platform_font_mgr` (`66e2b1e`) |
| Outlined text-field cutout = surface-colored patch over the stroke (wrong on non-surface backgrounds) | `kx_clip_rect_diff` (ABI 0.20.0, `SkClipOp::kDifference`) — the border gets a real hole (`cfc8828`) |
| `gpu_begin_offscreen`/`gpu_end_offscreen` stubs on iOS → `kx_gpu_warmup` silently no-op'd | ported the macOS Graphite warmup implementation verbatim |
| Signal/Memo/TextSignal `deinit` twice during `notify` → duplicate zombie → double-free; TextSignal freed its buffer before the deferred gate → subscriber UAF | `dying`-first guard + buffer freed inside the deferred destroy (`91a6817`, regression tests) |
| `listView`/`gridView` inside `scrollView` measured `h=inf` → `@intFromFloat` panic on first paint | unbounded height now reports natural content height + `isFinite` guard at the cast (`91a6817`) |
| Carousel `@intFromFloat` panics on crafted options (`spacing == -item_width`, non-finite viewport, ratio > u32); `snapOffset` could hang on a denormal stride | guards + ratio clamps; snap candidates bounded by the item count (`cd0c8b3`) |
| `scroll.visibleRange` panicked on denormal strides; `mapPointToParentSpace` truncated ancestors past 64; `flex_total` u32 overflow; damage `present_rect` could land 1px outside the pixel surface (desynced upload pitch); `kx_fill/stroke_path` trusted verb/point agreement across the ABI; navigator hero back-pointer UAF on view deinit; `KLAXON_DPR=inf` → non-finite display scale | all hardened (`cd0c8b3`) |
| Node-bound signal subscriptions were convention-only (a missed `unsubscribe` = `.node` markDirty UAF) | `Node.bound_signals` + `state.unbindAll` in `deinitBody`; `SignalBase.detachBoundNodes` for the signal-dies-first ordering (`978c909`) |
| Theme `platform.hit_target_min` / `control_height` / `motion.durations` populated but unread — a custom theme silently did nothing | wired into 27 files (`8b6618d`); `Shadow`/`Elevation`/`Spacing` documented reference-only (widgets raster via SkShadowUtils) |

## Open — needs design work, not a one-liner

- **ATK action callbacks run on the a11y thread** (`kx_a11y_linux.cpp:384-390,420-424`) — `grab_focus`/`do_action` walk the Zig node tree while the render thread owns it. The header documents the window; the real fix is marshalling through an SDL user event — deferred to a dedicated a11y-threading task.
- **`AtkValue` reports a fixed 0–100 range** (`kx_a11y_linux.cpp:453-456`) — currently *correct*: every numeric role emits a percent string (`slider` formats `{d:.0}%`). Latent trap only if a widget ever reports non-percent values; the fix is carrying min/max in the Semantics struct + dump.
- **`optionsFromValue` ignores unknown option keys** (`src/ui/value.zig:321`) — a typo'd serialized field silently renders defaults. Deliberate forward-compat choice (new fields don't break old docs); could grow a strict/diagnostic mode later.
- **`input_ime` on macOS is a win (7.8× vs Qt) but Android/iOS could not be measured** — SkParagraph re-shapes the growing buffer O(n) per commit; an incremental path would need paragraph-level caching that doesn't exist in SkParagraph.

## Register — documented incompleteness in widget code

Each widget's header carries the same list; these are the tracked ones
(file:line is approximate — headers move):

- `input.zig` — legacy P0 controls co-exported alongside the M3E ports.
- `segmented_button.zig` — single-choice only; equal-width = widest content
  (upstream weight(1f) distributes the mean); no checked-icon crossfade.
- `icon_button.zig` — no elevation shadows; instant shape morphs.
- `switch.zig` — mid-flight re-press restarts the spring from 0 velocity.
- `slider.zig` — continuous only: no steps/ticks, no value indicator.
- `split_button.zig` — trailing half is pointer-only (a11y activation pending).
- `text_field.zig` — single-line only; static caret at text end (no blink/
  selection/click-to-position); label lerps size, not weight/tracking; the
  text run stays LTR under RTL chrome.
- `time_picker.zig` — no text-input variant; en-only strings.
- `table.zig` — no sorting/selection/scroll/sticky header; text-only cells.
- `tree.zig` — no keyboard nav/lazy loading/drag-drop/icons.
- `carousel.zig` — no contentPadding, no hero/center-aligned strategy, no
  parallax.
- `progress.zig` — progress changes snap (no spring); wave attach
  micro-animations skipped.
- `drawer.zig` — no predictive back, window-inset padding, content
  scale-down during overshoot, or `confirmStateChange`.
- `gestures.zig` — `SLOP = 12` fixed px (px == dp; ~4dp effective at 3×);
  first tap fires immediately (no double-tap hold); long-press without a
  timeline fires on the first event after the deadline.
- `i18n.zig` — number/date tables cover en/fr/ja/ar only; no native digits
  (ar renders Latin digits); ICU/CLDR is the upgrade path.
- `color_picker.zig` — no alpha slider (forced 0xFF), no RGB/HSL inputs,
  no eyedropper.
- `kx_skia_android.cpp` — font family/fallback hardcode Roboto/Droid Sans;
  the directory-scan manager covers devices without them.
- `kx_skia_android_fontmgr_stub.cpp` — `GetSystemFontFamilies` clears the
  vector to satisfy a prebuilt-Skia symbol (bypassed in production; a
  latent trap if the NDK parser path is ever consulted).
- `kx_a11y_linux.cpp:746-750` — ATK < 2.46 drops live-region announcements
  silently (no `announcement` signal exists).
- `ios_io.zig` — `std.Io` shim: stderr→SDL_Log is real, all other ops are
  `failing*` stubs (a compile workaround, never app I/O).
- `inspector.zig` — O(expanded × rows) rebuild; debug-tool only.

## Benchmark-honesty invariants (do not regress)

- `presented_fps` = wall cadence incl. flush+swap; `fps` = unthrottled work;
  jank is measured on the 16.67 ms work budget, not presentation.
- Damage-skip scenes report ~0 ms of work *because nothing repainted* —
  retained content must still be correct; frozen paint on a scene whose
  reference updates is a fake win (see `scroll_anim` comment in bench.zig).
- `mount_churn` measures real mount cost: ~2.5 µs/node on desktop including
  a genuine Skia measure of unique strings — pooling the bench's card list
  would change what the scene measures vs Compose.
