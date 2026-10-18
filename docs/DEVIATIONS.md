# Deviations & audit register

Single register for places where Klaxon deliberately (or knowingly) deviates
from upstream Material 3 Expressive / platform behavior. Anything here is
**honest incompleteness**, not a hidden fake — silent approximations are
treated as bugs (see docs/M3E-PORT.md: "replace approximated draw/measure
code; don't patch it").

## Fixed in the 2026-10-17 technical audit ("Roast")

See [`docs/DECISIONS.md`](file:///Users/btw/Documents/projects/Klaxon/docs/DECISIONS.md) for the full 6-part remediation record:
- **Benchmark fairness**: removed forced static-scene repaints (`ro?.markNeedsPaint()` in Flutter, `view.update()`/`grabWindow()` in Qt), unified `shapes_ramp`/`paths_ramp`/`text_ramp`/`images_ramp` onto single-Canvas batching across Compose and Qt, removed the dead 230,400-byte CPU loop in Flutter `video_playback.dart`, and switched Klaxon's `runListOp` post-op frames to `paintDamage`.
- **Binary size & WAMR**: guarded the 4.02 MB embedded `kx_font_wasm.h` array behind `#ifdef __EMSCRIPTEN__` with a runtime disk-asset fallback (`KLAXON_DEFAULT_FONT_PATH` / `assets/fonts/DejaVuSans.ttf`) for deterministic headless tests, and removed WAMR from `klaxon doctor` and `scripts/{fetch,check,pack}-deps.sh` per ADR-0006.
- **Platform layer & C ABI**: added `src/platform/` (`storage/kv.zig`, `storage/paths.zig`, `net/http.zig`, `os/window_insets.zig`, `os/url.zig`, `os/haptics.zig`, `os/file_picker.zig`, `os/share.zig`, `os/notifications.zig`, `media/video.zig`, `runtime/plugin.zig`), `include/klaxon.h` + `src/c_abi.zig` with compile-time layout assertions, and `gates/thresholds.json`.
- **GPU backends & HiDPI**: persisted `skgpu::graphite::Recorder` at context lifetime across Linux Vulkan, Windows Dawn/D3D12, and WebGPU (eliminating the per-frame `offscreen_pools`/`images`/`atlas` wipe in `kx_begin_frame`), unified root HiDPI scaling after `kx_begin_frame` across all platforms (fixing iOS 1× scale), scaled `kx_offscreen_acquire` by `display_scale`, shared a single `MTLCommandQueue` on iOS, fixed MRC `+1` leaks on macOS/iOS, fixed RTL sub-run ordering in `shape_line_runs`, fixed Linux `platform_font_mgr`/`platform_font_family`, and fixed the `kx_atlas_alloc` free-slot leak.
- **6-platform accessibility & modal trapping**: fixed `kx_a11y_dump_tree`/`kx_a11y_free_string` capacity mismatch via `toOwnedSliceSentinel(0)`, trapped focus/semantics to open modals (`Dialog`, `Drawer`, `BottomSheet`, `SideSheet`), and overhauled all 6 native accessibility bridges (macOS, iOS, Android, Windows, Linux, Web).
- **Backend-request honesty & Layer-4 services**: `gpu_init` on Android/macOS/wasm now rejects backend requests it cannot honor instead of silently labelling a different renderer (e.g. a Ganesh-GLES context reported as Graphite-Vulkan), and the Android raster path presents through SDL like the desktop instead of a dead surface. `host.zig` installs real SDL backends for the Layer-4 contracts: `openUrl` → `SDL_OpenURL`, the file picker → `SDL_ShowFileDialogWithProperties` (title/location/filters/many, results marshalled to the main thread, `Status` distinguishing `ok`/`cancelled`/`unavailable`/`err`), and `paths.resolve` → `SDL_GetPrefPath`/`SDL_GetBasePath` — with env-convention fallbacks (`XDG_*`/`$HOME`/`%APPDATA%`) replacing the bogus `/etc`, `/var/lib`, system `/Library` and `C:\Users\Default` placeholders. Haptics stays uninstalled: SDL has no UI-haptic API (it is an honest no-op, not a fake). Safe-area/keyboard wiring detailed in the drawer entry below.
- **UI engine, M3E widgets, registry & build/CLI**: fixed `i18n.zig` cross-allocator free, `carousel.zig` `cancelChannel` UAF and keyline stack OOB, `list_view.zig`/`image.zig` `ctxSerialAlive` checks, `registry.zig` `BuildCtx.rollback` UAF + registered all 16 missing widgets, `text_field.zig`/`search_bar.zig` horizontal scroll + IME preedit reset + duplicate `errdefer`, `color_picker.zig` `#RRGGBB` alpha preservation, `anim.zig` scale guards, `node.zig` `.measure_pure = true` + `impure_descendant` recomputation + negative scale culling, `navigator.zig` query-string navigation + Hero transforms, `devtools.zig` `dt_ms` recording, and `build.zig` cross-target `mcu_sources` / `-Dapp-root`.

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

- `theme.zig` — `surfaceColorAtElevation`/`applyTonalElevation` are ported
  (ColorScheme.kt:1157/1566) with `Theme.tonal_elevation_enabled` standing
  in for LocalTonalElevationEnabled. Two simplifications vs upstream: (1)
  no `LocalAbsoluteTonalElevation` accumulation — Klaxon has no Surface
  primitive or composition locals, so a widget's own elevation is the
  whole term (a `surface` container inside an elevated parent won't
  inherit the parent's tint); (2) the audit found **zero** baseline-theme
  tint anywhere in the pinned M3E sources — every upstream `tonalElevation
  > 0` call site resolves to a `surface_container_*` / `*Container` /
  `inverse_*` container, and every `surface` container sits at Level0 — so
  the gate is wired only where upstream passes a nonzero elevation
  (`fab.zig`, `time_picker.zig`; both no-ops in the baselines, kept for
  custom themes that collapse a container role onto `surface`).
- `ui/interactions.zig` + `ui/state_layer.zig` + `ui/ripple.zig` — the
  Compose indication machinery (InteractionSource semantics, the animated
  StateLayer, and RippleAnimation/CommonRipple) is wired into the
  interactive catalog:

  - actions: `button`, `icon_button`, `button_group`, `split_button`,
    `fab`, `fab_menu`, `toolbar` — per-element Tracker/StateLayer/Ripples
    sets (per segment / per half / per slot / per docked FAB);
  - selection: `checkbox`, `radio`, `switch`, `slider`, `chip`,
    `segmented_button`, `tabs` — unbounded centered ink for the
    thumb/selection controls (Switch.kt:191-199 anchors the indication
    on the animated thumb rect), bounded per-segment ink clipped to the
    per-corner itemShape for segmented_button (a `.path` clip),
    primary-colored cell ripple for tabs (Tab.kt:166); slider press
    graduates to drag;
  - navigation/surfaces: `nav_bar`, `navigation_rail`, `list_item`,
    `menu`, `card` run a per-item/per-node Tracker → animated layer →
    bounded ripple (the pill/row-clipped indication upstream's
    `indication(offsetInteractionSource, ripple)` produces); `app_bar`,
    `bottom_app_bar` and `drawer` carry no indication upstream and own
    none here.

  A held press no longer paints a static overlay anywhere in the
  migrated set — it's the expanding ink (Ripple.kt), and keyboard
  activation mints centered bounded ripples. The remaining widgets
  (pickers, snackbar, text fields, tooltip…) still paint fixed-alpha
  interaction overlays; their migration lands in follow-up batches.
  Deliberate port deltas inside the machinery itself: concurrent ripples
  capped at 4 (upstream's
  scatter map is unbounded, though every `addRipple` finishes all live
  ripples anyway — overflow retires the oldest instantly); active
  interactions capped at 8 = InputRouter's pointer slots (upstream's list
  is unbounded; `MutableSharedFlow`'s DROP_OLDEST policy applies on
  overflow); the bounded clip supports `.rrect`/`.path` beyond upstream's
  `clipRect` (material3 clips indication to the component shape; the
  vendored material-ripple predates that); pointer-provenance focus
  (`focus_via`) is explicit so the focus state layer can be gated
  focus-visible — upstream gets this for free since `clickable` never
  requests focus on press.
- `input.zig` — legacy P0 controls co-exported alongside the M3E ports.
- `segmented_button.zig` — the check icon is upstream's
  AnimatedVisibility (fade + scale-in from bottom-left, instant exit,
  the label offset springing concurrently) and the equal width is the
  weight(1f) mean over the intrinsic contents; squeezed segments wrap
  their label through the paragraph ABI and the row grows past
  ContainerHeight. Remaining gap: the multi-choice row
  (`segmentedButtonMulti`) is a u64 bitmask capped at 64 segments.
- `icon_button.zig` — no deviations: upstream IconButton.kt carries no
  elevation/shadow either (the variants are flat); shape morphs spring
  via the timeline (AnimatedShape parity).
- `button.zig` — the pressed corner morph springs on effects_spring
  (MotionSchemeKeyTokens.DefaultEffects — upstream picks it expressly
  "to prevent any bounce"; icon_button does the same); the ripple clip
  tracks the live radius.
- `fab.zig` — the checked/unchecked toggle morph springs the container
  size + radius on spatial_spring; ink rides the interpolated rect.
- `nav_bar.zig` / `navigation_rail.zig` — the active indicator's width
  expands on fast_spatial per item (NavigationBar.kt:561,
  NavigationItem.kt:694/924) around the collapsed center / the expanded
  leading edge; the state layer + ripple stay on the unanimated pill
  like upstream's indicatorRipple measure.
- `switch.zig` — no deviations beyond the header (mid-flight retargets
  carry channel velocity since `Animation.velocityAt`).
- `slider.zig` — the value indicator now morphs on the timeline (150ms
  emphasized fade + pop from the tail tip, like upstream's label
  animation) instead of popping. Steps/ticks, the pressed value
  bubble, the corner-inset thumb mapping and PageUp/PageDown
  (actualSteps/10 clamped to [1,10] ticks) match upstream.
- `split_button.zig` — filled only; no embedded menu. The inner-corner
  morphs run on the effects spring, `splitSetTrailingChecked` morphs the
  trailing half to CircleShape with the contentColor@0.12 scrim, and the
  trailing icon rides upstream's `horizontalCenterOptically` — 0.11 ×
  (avgStart − avgEnd) corner radii toward the gap, clamped to the
  content padding, mirrored in RTL, tracking the live morph. (a11y:
  the halves are virtual button children and ArrowDown activates the
  trailing — ARIA menu-button.)
- `text_field.zig` / `search_bar.zig` / `search_view.zig` — text_field
  grows multiline (`multiline`/`min_lines`/`max_lines`: soft wrap, Enter
  inserts '\n', wheel-scrolled capped viewport, caret-follow on input);
  search_bar/search_view stay single-line (upstream DockedSearchBar is
  single-line too). No selection handles or undo; the text_field label
  lerps size AND letter spacing (bodyLarge→bodySmall on both axes — the
  weight is 400 at both ends). All three ride the shared
  `text_edit.zig` core: real caret (click-to-position hit test, 500ms
  blink), selection
  (shift/drag + highlight + range edits), grapheme-cluster arrows and
  double-click word select via ICU UBRK (ABI 0.23.0), Cmd/Ctrl+A/C/X/V
  on the platform clipboard. Caret geometry is direction-aware (ABI
  0.24.0): arrows step in the arrow's SCREEN direction, home/end land on
  the visual run edges, the painted caret uses the paragraph's caret
  rect, and the selection paints one box per bidi run — under RTL the
  hit test, motion and paint all agree with the mirrored run. The legacy
  `input.zig` textField (conformance-only) rides the same `text_edit.zig`
  core — caret,
  selection, grapheme arrows, word select, clipboard, underlined IME
  preedit.
- **Type-scale fidelity** — every `type_scale` call site now paints at
  the style's real `weight` + `letter_spacing` (the old bool path
  collapsed weight>=500 → synthetic Bold and dropped tracking): buttons,
  chips, segmented/split buttons + groups, FAB menu, nav bar/rail,
  menus, list items, tables, trees, steppers, calendar/date/time
  pickers, sliders, search bar/view and text fields. The
  measure/paint/caret paths share the same styled metrics
  (`measureTextStyled`/`textStyled`/`measureTextLenStyled` + the
  `text_edit` `hit_weight`/`hit_spacing` bake), so layout, ink and hit
  tests agree. Native side: `kx_text_style` now carries weight +
  letterSpacing through the paragraph cache (the bool APIs delegate at
  700/400); `TextOptions`/`TextSpan` keep `.bold` as the public toggle —
  it resolves to 700 unless `.weight` overrides.
- `time_picker.zig` — the text-input variant (`opts.mode = .input`,
  upstream `TimeInput`) landed on the shared `text_edit.zig` core: the
  selected field is a real editable box (caret/selection/clipboard,
  `transformAfterEdit` = upstream `TimeInputTransformation` — non-digit /
  >2-char / >99 edits revert wholesale, a lone char in a full field rolls
  to just that char, a complete valid hour auto-advances, out-of-range
  values paint the error state without touching the signal); the other
  field is the borderless `TimeSelector` plate. `opts.mode_toggle` is the
  footer dial⇄keyboard affordance (upstream's `toggle` slot). The labels,
  error texts, AM/PM halves, Cancel/OK and the a11y strings localize via
  `i18n.tr()` (English literals as msgid keys — the app's ARB overrides)
  plus CLDR `am_label`/`pm_label` locale data; a locale switch re-resolves
  and rebuilds the semantics tree. The supporting texts wrap through the
  paragraph ABI at the field width — one tr() sentence key each (upstream
  `TimePicker24HourError`/`HourError`/`MinuteError`). A field turning
  invalid announces its error politely (`semantics.announce`, upstream
  liveRegion). The vibrant overload (`opts.vibrant`, upstream
  `TimeInput(state, shapes, vibrantColors())`) lands the 100x120
  CornerLarge fields, the 56x120 side period column with circle/squircle
  pills, the compact panel and the invalid-only support box. Remaining:
  the uncontained vibrant style (the side control column variant); the
  auto-advance always runs
  (upstream suppresses it while an a11y service is enabled — no
  equivalent query here); Tab reaches the focused node before the global
  focus traversal — the picker consumes it to walk hour⇄minute
  directionally and bubbles it off the edge — and the AM/PM column is
  pointer-only (as in the dial variant). The dial itself is now a focus
  stop: arrows step a focused numeral in composition order (outer ring,
  then the 24h dial's inner ring), Enter/Space commits it without the
  pointer path's auto-advance, Tab bubbles. Upstream gates numeral focus
  on `inputMode != Touch`; with no input-modality query ours is always a
  stop — a pointer tap just clears the focused numeral — and the
  per-numeral virtual a11y children upstream synthesizes are not ported
  (screen readers get the group value).
- `table.zig` — sorting (a `sortable` column's header toggles a real
  stable asc/desc sort + the arrow icon), selection (the checkbox column +
  select-all with the tristate dash), and a wheel/drag body scroll under a
  pinned header are real, and the sort arrow's rotation rides the
  default spring (upstream's animateFloatAsState — a same-column flip
  animates 0↔180, a column switch snaps); column resizing is real too
  (`resizable` + `on_col_resize` — a ±4dp grab zone on each data
  column's trailing header border drags the width, clamped to the
  column minimum, persisted in the widget and reported live + on
  settle); row paint is windowed by index math and column widths are
  memoized (virtualized in the flat-data sense); remaining: text-only
  cells (`cell_paint` takes over a cell's draw — no child widgets in
  cells).
- `tree.zig` — drag-and-drop reordering landed (`draggable` +
  `on_move`): slop-promoted pointer drags, primary insertion-gap
  indicator, self-subtree drops rejected, in-place model move reported by
  `userdata` tokens. (Keyboard nav with selection-follows-focus,
  synchronous lazy children providers, per-node icons and per-row
  virtual a11y children also landed.)
- `carousel.zig` — the hero/center-aligned strategy landed (upstream's
  `HorizontalCenteredHeroCarousel`: even small count flanking a centered
  focal run, start-aligned fallback under 3 items) and
  `padding_before`/`padding_after` is upstream's main-axis
  `contentPadding` (the resting edge steps shrink keylines by
  padding/count). The parallax is the ported `Modifier.carouselItem`
  mask+translation — item content stays full-size inside a moving clip
  band, upstream's mechanism verbatim. No end-aligned variant (upstream
  exposes only the centered hero).
- `progress.zig` — a brand-new node can't animate from the previous
  one's value (no diffing layer); in-place updates DO spring: the
  `progress_sig` path and the new `progressSetValue` setter both ride
  the ProgressAnimationSpec spring with velocity-carrying retargets
  (upstream `animateFloatAsState` semantics). The wavy amplitude runs
  the upstream `updateAmplitudeAnimation` spec: a 500ms tween (standard
  easing up, emphasized-accelerate down, quantized to 1/12 morph steps)
  between the ring and the rounded-star path.
- `drawer.zig` — no predictive back (no system back-progress events to
  feed `DrawerPredictiveBackHandler`; Escape/edge dismissal works). The
  overshoot gap upstream covers with `horizontalScaleUp` +
  `horizontalScaleDown` is covered by stretching the panel surface fill —
  the children never distort, so no counter-scale is needed. `confirm_state_change`
  gates only drawer-initiated
  transitions (the app owns the signal). The sheet `content` slot is
  padded by `platform.window_insets.safeArea()` (Vertical + Start,
  matching `DrawerDefaults.windowInsets`; the surface still paints
  edge-to-edge) — the host reads `SDL_GetWindowSafeArea` (per-window
  status/nav-bar + cutout insets on Android, UIKit `safeAreaInsets` on
  iOS, the display notch on macOS) on safe-area/keyboard/geometry events
  and marks the tree layout-dirty when an inset changes, so content
  re-lays out on the next frame. `window_insets.keyboardHeight()` is real
  too: Android unions `WindowInsets.Type.ime()` into the reported bottom
  edge (the host splits it back out via `SDL_ScreenKeyboardShown` + the
  nav baseline), iOS reads the observed `UIKeyboardWillChangeFrame` end
  height (`kx_ios_keyboard_height`), and `SDL_EVENT_SCREEN_KEYBOARD_*`
  trigger the resync.
- `gestures.zig` — the long-press fires at its deadline without a pointer
  event (the arena registers a timeline ticker on pointer-down;
  `hasPendingTimeWork` wakes the host); in headless no-timeline tests it
  fires on the next event. (Slop is pointer-type aware; a tap holds for
  the double-tap window when `on_double_tap` exists.)
- `i18n.zig` — number/date tables cover en/fr/ja/ar/es/de/zh/hi/pt/ru/ko/
  it/nl/tr, with CLDR plural rules (incl. ru's one/few/many and hi/pt's
  0-or-1 `one`), Arabic-Indic and Devanagari digit sets, the Indian 3/2
  grouping and CLDR day-period markers (`am_label`/`pm_label`). The long
  tail of locales stays on the documented ICU upgrade path. (The paragraph bidi base direction follows the locale —
  fixed audit row above.) `subscribeLocale`/`unsubscribeLocale` pair a
  widget callback to `locale_sig`; the modal chrome (dialog, bottom and
  side sheets, drawer) resolves its scrim/panel/close-button labels via
  `tr()` and re-attaches them on a switch — a caller-supplied `label`
  stays verbatim. The same holds for every other framework-owned label —
  menu, navigation rail, app bar, segmented/button groups, progress,
  loading indicator, data table, stepper, avatar and the color picker,
  and the calendar's painted weekday letters ride the CLDR
  `weekday_letter` table. The structural defaults too — nav bar, tabs,
  bottom app bar, pull-to-refresh and carousel labels are nullable
  (`null` = `tr()`), tree/expansion-panel expanded-state values
  localize, the toolbar's defaulted FAB name and the search view's
  region label re-dupe on a switch, the split button's trailing label
  resolves "Expand", the snackbar dismiss button gets the upstream
  "Dismiss" content description and the expansion panel's default title
  localizes.
- `color_picker.zig` — no preset swatches, no eyedropper. (The alpha
  slider shipped: checkerboard + gradient bar feeding the Signal's alpha
  byte. The hex field + the two numeric rows — R/G/B bytes and the
  H/S/L triplet in degrees/percents — ride the shared `text_edit.zig`
  core (real caret, selection, clipboard, IME session via
  `wants_text_input`), commit on Enter and revert on blur/Escape. The
  numeric rows are digit-filtered and range-checked (255 / 360 / 100);
  RGB writes the byte, HSL round-trips through `hslToColor` preserving
  alpha, and every commit resyncs the SV square, hue and alpha sliders.)
- `kx_skia_android.cpp` — the default/fallback families are resolved
  from the device at first use (Roboto → first Latin-covering family;
  Droid Sans → a second Latin family), never the clock face that sorts
  first in /system/fonts.
- `kx_skia_android_fontmgr_stub.cpp` — `GetSystemFontFamilies` clears the
  vector to satisfy a prebuilt-Skia symbol (bypassed in production; a
  latent trap if the NDK parser path is ever consulted).
- `kx_a11y_linux.cpp:746-750` — ATK < 2.46 drops live-region announcements
  silently (no `announcement` signal exists).
- `ios_io.zig` — `std.Io` shim: stderr→SDL_Log is real, all other ops are
  `failing*` stubs (a compile workaround, never app I/O).
- `inspector.zig` — debug-tool only. (The rebuild is now O(rows) — a
  node→row index map serves the prune, select and selection-resync.)

## Fidelity harness — known reference-runner deltas (do not "fix" by regressing Klaxon)

`fidelity/` compares our Skia raster output against a Compose M3 desktop
runner (66 scenes, `tools/fidelity_diff.py`, mean 0.156%). The residual
nonzero scenes are version deltas in the runner's material3, not Klaxon
bugs — the vendored `.ref/material3` spec is authoritative:

- `checkbox_checked_pressed` (~3.9%) — the runner's checkbox is the
  legacy 20dp box with gray on_surface ink; the spec (styling-fix path)
  is 18dp with checkedBoxColor/primary ink. The published material3 lib
  (1.9.0) predates `isCheckboxStylingFixEnabled` — `TriStateCheckbox`
  hardcodes `ripple(color=Unspecified)` → on_surface. Ours matches spec.
- `chip_filter_selected`/`chip_filter_hover` (~0.7%) — residual glyph AA
  on the check icon + label after the layout fix (fixed 3-slot row,
  spacedBy 8dp — see below). Spec unselected-hover label/layer =
  OnSurfaceVariant (FilterChipTokens).
- `fab_default`/`fab_small_pressed` (~0.7-1.1%) — shadow fringe: ambient
  0.08/spot 0.10 calibrated against the runner's renderer; remaining
  pixels are ±2-4 in the blurred band plus the pressed-ripple edge.
- `card_*`/`nav_bar_*` (<0.3%) — anti-alias noise on card outline and the
  indicator pill's rounded ends.
- `slider_pressed` resolved (0.000%): upstream drives the value indicator
  off `isDragging` only (Slider.kt:920) and the pinned Slider.kt has no
  ValueIndicator paint path at all (tokens exist but are unused) — the
  bubble is drag-gated in Klaxon, matching both the upstream model and
  the runner. Slider measured height is 48dp — upstream
  `minimumInteractiveComponentSize()` inflates the composable's own
  bounds (Slider.kt:979), not just the hit area.
- `chip` width model: upstream ChipContent is three FIXED slots
  ([leading|Spacer0, label, trailing|Spacer0], Chip.kt:3392-3412) with
  spacedBy(8) — a label-only chip measures label+32, not label+16. The
  selected filter chip's check is caller-provided `leadingIcon` (no
  automatic check upstream); the scene supplies `leading_icon: "check"`.
- Runner-side fixes: a settle frame before `seedState` (the published
  lib's NavigationBar/Rail item swaps in a fresh MappedInteractionSource
  once itemWidth resolves at frame 2 — a press emitted earlier is
  collected by the stale instance and lost); scene icons wrapped in
  fixed-size boxes (`iconSlot`) because upstream icon slots are
  token-sized and the indicator pill derives its width from the icon
  slot (56 = 24+2·16), not the glyph advance.

## Benchmark-honesty invariants (do not regress)

- `presented_fps` = wall cadence incl. flush+swap; `fps` = unthrottled work;
  jank is measured on the 16.67 ms work budget, not presentation.
- Damage-skip scenes report ~0 ms of work *because nothing repainted* —
  retained content must still be correct; frozen paint on a scene whose
  reference updates is a fake win (see `scroll_anim` comment in bench.zig).
- `mount_churn` measures real mount cost: ~2.5 µs/node on desktop including
  a genuine Skia measure of unique strings — pooling the bench's card list
  would change what the scene measures vs Compose.
