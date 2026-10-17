# Pixel-fidelity harness — Klaxon × Compose Material 3

Renders the **same scene matrix** through both widget stacks and pixel-diffs
the results, so "Klaxon matches M3E" is a measurement instead of a claim.

```
fidelity/scenes.json            the ONE shared scene matrix (66 scenes)
src/fidelity_main.zig           Klaxon runner  → fidelity/out/klaxon/<id>.ppm + <id>.json
fidelity/compose/               Compose runner → fidelity/out/compose/<id>.ppm + <id>.json
tools/fidelity_diff.py          tolerant diff → out/diff/<id>.ppm, report.json, report.html
```

## Run it

```sh
# 1. Klaxon side (Zig, headless Skiko raster, ~2s)
zig build fidelity                    # [-- --scene=<substr> --scenes=... --out=...]

# 2. Compose side (JVM, headless ImageComposeScene, ~30s first build)
fidelity/compose/run.sh               # [--scene=<substr>]

# 3. Diff + report
python3 tools/fidelity_diff.py        # exit 2 if any pair is missing
open fidelity/report.html
```

Each scene produces a pair of same-size P6 PPMs plus a JSON sidecar with the
resolved `widget_bounds` and the theme `colors` actually used, so layout drift
is visible in metadata before you ever open an image.

## The scene matrix

`scenes.json` covers the 14 starter widgets — button, icon_button, checkbox,
radio, switch, slider, card, divider, badge, nav_bar, tabs, fab, chip,
text_field — in a representative subset of the full cross-product:

- **states** `default` `hover` `pressed` `focused` `disabled` (plus selection
  flags like `checked`/`selected` where the widget has them);
- **themes** `light` and `dark`;
- **directions** `ltr` and `rtl`;
- **variants** (filled/tonal/outlined/elevated/text buttons, FAB sizes, chip
  kinds, text-field filled/outlined/error, divider orientation, badge
  dot/count, …);
- `viewport` per scene and `t_ms` virtual time.

Schema per scene: `{id, widget, options, state, theme, dir, viewport, t_ms}`.
`nav_bar`/`tabs` scenes also carry `options.items` — destination/tab titles
both sides expand into real `NavigationBarItem`/`Tab` children.

## Determinism contract

Both sides agree on everything that could move a pixel:

| knob | Klaxon | Compose |
|---|---|---|
| frame | `golden.Renderer`, viewport-sized | `ImageComposeScene`, viewport-sized |
| density | 1.0 | `Density(1f, 1f)` |
| theme | `theme.light` / `theme.dark` | `lightColorScheme()` / `darkColorScheme()` |
| direction | `i18n` ltr/rtl | `LayoutDirection` ltr/rtl |
| font | `KLAXON_FONT_DIR=deps/fonts` → DejaVu Sans | `ResourceFont("DejaVuSans.ttf")` from the same `deps/fonts` |
| clock | `anim.Timeline.tick(t_ms)` | `scene.render(t0 + t_ms·1e6 ns)` |
| placement | widget centered in the viewport | widget centered in a `Surface`-colored frame |

State is seeded, not simulated: `pressed` = pointer held at the widget's
centre (per-item centre for nav_bar/tabs — the middle destination), `hover` =
`HoverInteraction.Enter` / pointer move to the centre, `focused` =
`FocusInteraction.Focus` / focus-manager injection, `disabled` =
`enabled=false`. Compose `tryEmit` is sent between the layout frame and the
t0 frame so the ripple/press animation is at the same age (`t_ms`) on both
sides.

## Tolerance rationale — what a diff *means*

`tools/fidelity_diff.py` counts a pixel as mismatched when **any channel
differs by > 8** — that absorbs 1–2-LSB rounding noise between two Skia
builds' premultiplied-alpha readbacks — and then **forgives pixels within
1px of a strong edge** (luma gradient > 48) in either image, which covers
sub-pixel AA fringes around shapes and glyphs. What remains — the number in
`report.json` — is real geometry/colour/state drift:

- ~0% on quiescent control scenes means Klaxon is pixel-faithful;
- residual % on `hover`/`pressed` scenes is mostly ripple/state-layer shape
  (M3E ripples are asymmetric and t_ms-quantized differently per engine);
- the `diff/` PPMs paint mismatches red, forgiven AA edges amber, matches
  grey.

Known divergences (documented so a bump isn't mistaken for a regression):

- **Text rasterisation.** Both sides rasterise DejaVu Sans, but Klaxon's
  vendored Skia and Skiko's Skia are different builds — stem-darkening and
  LCD/AA filters differ slightly. Edge erosion eats most of it; dense text
  scenes still carry a small floor.
- **`fab_disabled` (~14%)**: M3's `FloatingActionButton` has no `enabled`
  parameter at all — disabled FABs aren't a thing in Compose M3 — so the
  Compose frame renders the enabled look while Klaxon dims to the disabled
  tokens. Largest single-scene gap in the matrix, kept as a deliberate
  marker of a real API asymmetry rather than a rendering bug.
- **Pressed ripples** (radio/slider/switch/checkbox ~3–6%): the ripple mask
  and press-state overlay are engine-specific; bounds and colour are still
  asserted by the metadata sidecars.
- **`button_large_icon`**: Klaxon's icon-text gap vs Compose's
  `ButtonDefaults` spacing differs at large sizes.

The threshold gate in `gates/thresholds.json` (`metric:
"pixel_mismatch_pct"`) expresses the aspirational bar; CI can consume
`fidelity/report.json` (`summary.mean_mismatch_pct`, `worst_mismatch_pct`,
per-scene `mismatch_pct`) directly.

## Version pins

| component | version | why |
|---|---|---|
| JB Compose plugin | `1.13.0-alpha02` | M3 Expressive APIs (expressive button/icon-button shapes, `PrimaryTabRow`, emphasized typography) — bundles androidx m3 ~1.5.0-alpha |
| Kotlin | `2.2.21` | the line the 1.13 plugin is built for |
| kotlinx-serialization | `1.9.0` | scenes.json parsing |
| kotlinx-coroutines | `1.10.2` | `ImageComposeScene` composition context |
| JDK | 21 (Homebrew openjdk@21) | `run.sh` exports `JAVA_HOME`; `/usr/bin/java` is a stub on this machine |

The Compose runner is a **separate project** from
`conformance/runners/compose` (pinned at Compose 1.8.2): the 1.13
`ComposeScene` API changed (`CanvasLayersComposeScene` takes a
`FrameRecomposer`, `render()` split into `draw()` + `measureAndLayout()`)
and bumping the conformance runner would break `ComposeHost.kt`. The
vendored androidx m3 reference in `.ref/` is pinned at `677148640cfc` —
drift between that snapshot and the alpha jar is a known, documented
source of residual diffs.
