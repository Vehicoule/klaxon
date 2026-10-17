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
|| `gestures.SLOP = 12` fixed for every pointer kind — mouse/stylus drags had a finger-sized dead zone | `panSlop(pointer)`: precision pointers engage pan at 2dp (Flutter `kPrecisePointerPanSlop`), touch keeps 12dp; tap/press dead zones unchanged (`b035a19`) |
|| Determinate progress snapped on value changes | `ProgressOptions.progress_sig` binds a `Signal(f32)`; changes animate with upstream `ProgressAnimationSpec` (ζ=1.0 / stiffness 50) and snap when no timeline exists (`b035a19`) |
|| ATK action callbacks walked the node tree from the a11y thread | marshalled through an SDL user event onto the UI thread; `AtkValue` carries real min/max/now from `Semantics.value_range` (`d0e9124`) |
|| The IME stack was dormant: `SDL_StartTextInput` never ran outside desktop (no soft keyboard on Android/iOS), composition/preedit events were dropped | focus-gated `SDL_StartTextInput`/`StopTextInput` + `SDL_SetTextInputArea` anchoring on `VTable.wants_text_input`; `SDL_EVENT_TEXT_EDITING` routed through `KeyEvent.text_editing` into TextField/SearchBar/SearchView composition buffers (below) |
|| Char-level font fallback resolved on macOS only — every `SkFontMgr_Custom` family (Android/Linux/Windows/WASM, iOS directory path) returned nullptr from `onMatchFamilyStyleCharacter` → non-Latin codepoints shaped to `.notdef` | `KxCachingFontMgr::scanForCoverage`: bounded covering-scan over the manager's family list (emoji-locale pre-pass for `und-Zsye`), memoized per (family, style, locale, codepoint) (below) |
|| SkParagraph always built paragraphs on an LTR base — trailing neutrals and weak-direction runs landed on the wrong side under an RTL locale | ABI 0.21.0 `kx_set_text_direction` process-global, mirrored from `i18n.direction()`; the text cache keys on it for bidi-relevant strings only (below) |
|| TextField's caret was static at the text end — no click-to-position, no blink, edits only appended/popped | ABI 0.22.0 `kx_text_position_at` (SkParagraph `getGlyphPositionAtCoordinate`) + `kx_measure_text_len` for prefix geometry; caret = a byte offset that click/arrows/home/end move and edits apply at, blinking at Compose's 500ms cadence via a focus-gated ticker; the IME cursor (`comp_start`) positions inside the composition |
|| No text selection anywhere | caret+anchor range: drag-select and shift+arrows/home/end, primary@0.4 highlight behind glyphs (upstream TextSelectionColors), edits replace the range; Cmd/Ctrl+A/C/X/V through `ui.clipboard` (SDL-backed, widgets stay SDL-free); `Key.home`/`.end` + `command`/`chr` modifiers added to the input model |
|| `kx_measure_text("")` degenerated the paragraph path into -FLT_MAX metrics | len-0 returns the font's own metrics + zero width (no cache entry, no shaping) |

## Open — needs design work, not a one-liner

- **`optionsFromValue` ignores unknown option keys** (`src/ui/value.zig:321`) — a typo'd serialized field silently renders defaults. Deliberate forward-compat choice (new fields don't break old docs); could grow a strict/diagnostic mode later.
- **`input_ime` measures synthetic commit injection, not a real IME round-trip** — like-for-like with all three runners (each injects commit strings too), and the real path is now wired (focus-gated text input + composition routing, above), but the bench can't drive an OS-level IME. Separately: SkParagraph re-shapes the growing buffer O(n) per commit; an incremental path would need paragraph-level caching that doesn't exist in SkParagraph.

## Register — documented incompleteness in widget code

Each widget's header carries the same list; these are the tracked ones
(file:line is approximate — headers move):

- `input.zig` — legacy P0 controls co-exported alongside the M3E ports.
- `segmented_button.zig` — equal-width = widest content (upstream
  weight(1f) distributes the mean); no checked-icon crossfade; the
  multi-choice row (`segmentedButtonMulti`) is a u64 bitmask capped at 64
  segments.
- `icon_button.zig` — no elevation shadows. (Shape morphs now spring via
  the timeline — AnimatedShape parity.)
- `switch.zig` — no deviations beyond the header (mid-flight retargets
  carry channel velocity since `Animation.velocityAt`).
- `slider.zig` — the value indicator doesn't morph its shape (upstream's
  label animates in on drag start). Steps/ticks, the pressed value
  bubble, the corner-inset thumb mapping and PageUp/PageDown
  (actualSteps/10 clamped to [1,10] ticks) match upstream.
- `split_button.zig` — filled only; no checked trailing morph; trailing
  icon geometric center (upstream optical nudge); instant corner morph;
  no embedded menu. (a11y: the halves are virtual button children and
  ArrowDown activates the trailing — ARIA menu-button.)
- `text_field.zig` / `search_bar.zig` / `search_view.zig` — single-line
  only; no selection handles or undo; the text run stays LTR under RTL
  chrome (arrows move logically under RTL); the text_field label lerps
  size, not weight/tracking. All three ride the shared `text_edit.zig`
  core: real caret (click-to-position hit test, 500ms blink), selection
  (shift/drag + highlight + range edits), grapheme-cluster arrows and
  double-click word select via ICU UBRK (ABI 0.23.0), Cmd/Ctrl+A/C/X/V
  on the platform clipboard.
  The legacy `input.zig` textField (conformance-only) still end-caret.
- `time_picker.zig` — the text-input variant (`opts.mode = .input`,
  upstream `TimeInput`) landed on the shared `text_edit.zig` core: the
  selected field is a real editable box (caret/selection/clipboard,
  `transformAfterEdit` = upstream `TimeInputTransformation` — non-digit /
  >2-char / >99 edits revert wholesale, a lone char in a full field rolls
  to just that char, a complete valid hour auto-advances, out-of-range
  values paint the error state without touching the signal); the other
  field is the borderless `TimeSelector` plate. `opts.mode_toggle` is the
  footer dial⇄keyboard affordance (upstream's `toggle` slot). Remaining:
  en-only strings; the classic (non-vibrant) `TimeInput` only — no
  100x120 CornerFull style; supporting texts hand-wrapped (no real text
  wrap, no liveRegion on the error text); the auto-advance always runs
  (upstream suppresses it while an a11y service is enabled — no
  equivalent query here); Tab walks the fields only in tests — the host
  maps Tab to the global focus traversal, so in-app field navigation is
  tap / auto-advance / Enter, and the AM/PM column is pointer-only (as in
  the dial variant).
- `table.zig` — sorting (a `sortable` column's header toggles a real
  stable asc/desc sort + the arrow icon), selection (the checkbox column +
  select-all with the tristate dash), and a wheel/drag body scroll under a
  pinned header are real; remaining: text-only cells (`cell_paint` takes
  over a cell's draw — no child widgets in cells), the arrow's rotation
  snaps (upstream animates it), no column resizing, no virtualization.
- `tree.zig` — no drag-and-drop reordering. (Keyboard nav with
  selection-follows-focus, synchronous lazy children providers, per-node
  icons and per-row virtual a11y children landed.)
- `carousel.zig` — no contentPadding, no hero/center-aligned strategy, no
  parallax.
- `progress.zig` — static `progress` snaps on rebuild (the spring runs on
  `progress_sig` writes). The wavy amplitude runs the upstream
  `updateAmplitudeAnimation` spec: a 500ms tween (standard easing up,
  emphasized-accelerate down, quantized to 1/12 morph steps) between the
  ring and the rounded-star path.
- `drawer.zig` — no predictive back, window-inset padding, or content
  scale-down during overshoot; `confirm_state_change` gates only
  drawer-initiated transitions (the app owns the signal).
- `gestures.zig` — long-press without a timeline fires on the first event
  after the deadline. (Slop is pointer-type aware — fixed audit row; the
  tap now holds for the double-tap window when on_double_tap exists.)
- `i18n.zig` — number/date tables cover en/fr/ja/ar/es; ar renders CLDR
  Arabic-Indic digits/separators (other native digit sets need the ICU
  upgrade path). (The paragraph bidi base direction follows the locale —
  fixed audit row above.)
- `color_picker.zig` — no RGB/HSL inputs, no eyedropper. (The alpha slider
  shipped: checkerboard + gradient bar feeding the Signal's alpha byte.)
- `kx_skia_android.cpp` — font family/fallback hardcode Roboto/Droid Sans;
  the directory-scan manager covers devices without them.
- `kx_skia_android_fontmgr_stub.cpp` — `GetSystemFontFamilies` clears the
  vector to satisfy a prebuilt-Skia symbol (bypassed in production; a
  latent trap if the NDK parser path is ever consulted).
- `kx_a11y_linux.cpp:746-750` — ATK < 2.46 drops live-region announcements
  silently (no `announcement` signal exists).
- `ios_io.zig` — `std.Io` shim: stderr→SDL_Log is real, all other ops are
  `failing*` stubs (a compile workaround, never app I/O).
- `inspector.zig` — debug-tool only. (The rebuild is now O(rows) — a
  node→row index map serves the prune, select and selection-resync.)

## Benchmark-honesty invariants (do not regress)

- `presented_fps` = wall cadence incl. flush+swap; `fps` = unthrottled work;
  jank is measured on the 16.67 ms work budget, not presentation.
- Damage-skip scenes report ~0 ms of work *because nothing repainted* —
  retained content must still be correct; frozen paint on a scene whose
  reference updates is a fake win (see `scroll_anim` comment in bench.zig).
- `mount_churn` measures real mount cost: ~2.5 µs/node on desktop including
  a genuine Skia measure of unique strings — pooling the bench's card list
  would change what the scene measures vs Compose.
