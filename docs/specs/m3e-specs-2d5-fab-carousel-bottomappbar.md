# M3E specs — 2d.5: FAB + extended FAB + carousel + bottom app bar

Sources: `m3.material.io/components/floating-action-buttons`,
`m3.material.io/components/carousel`, `m3.material.io/components/bottom-app-bar`
+ androidx `compose/material3/FloatingActionButton.kt`
(`FabSmallTokens`/`FabBaselineTokens`/`FabMediumTokens`/`FabLargeTokens`,
`ExtendedFabSmallTokens`/`ExtendedFabMediumTokens`/`ExtendedFabLargeTokens`,
`FabMenuBaselineTokens`) + `compose/material3/Carousel.kt` + `Keyline.kt` +
`KeylineList.kt` + `Strategy.kt` (`CarouselDefaults`) +
`compose/material3/AppBar.kt` (`BottomAppBar`) + `BottomAppBarTokens.kt`
(v0_210). The M3E FAB tertiary/surface token files are not published —
the families map straight onto the documented color roles.

## Tokens (FAB — FabSmall/Baseline/Medium/LargeTokens)

| Token | Value | Used for |
|---|---|---|
| container size (small) | 40dp | `size = .small` |
| container size (baseline) | 56dp | `size = .standard` |
| container size (medium) | 80dp | `size = .medium` |
| container size (large) | 96dp | `size = .large` |
| `IconSize` | 24 / 24 / 28 / 32dp | the icon (large paints 36 — the Compose `LargeFabIconSize` default, see deviations) |
| `ContainerShape` | CornerMedium 12 / CornerLarge 16 / CornerLargeIncreased 20 / CornerExtraLarge 28 | the container radius (theme shape scale) |
| `ContainerColor` | `*Container` of the family | the container fill |
| `IconColor` | `On*Container` of the family | the icon ink |
| elevation | Level3 (hovered Level4) | approximated flat — see deviations |
| min interactive size | 48dp | `hit_bounds` (never the painted size) |
| disabled | `OnSurface` @ 0.12 container / @ 0.38 icon | `enabled = false` |
| state layers | `On*Container` @ hover 0.08 / focus 0.10 / pressed 0.12 | hover/focus/press |

The color families (Compose `*FloatingActionButtonTokens`): `primary` =
`PrimaryContainer`/`OnPrimaryContainer`, `secondary` =
`SecondaryContainer`/`OnSecondaryContainer`, `tertiary` =
`TertiaryContainer`/`OnTertiaryContainer`, `surface` =
`SurfaceContainerHighest`/`Primary`.

## Tokens (Extended FAB — ExtendedFabSmall/Medium/LargeTokens)

| Token | Value | Used for |
|---|---|---|
| container height | 56 / 80 / 96dp | `size = .small/.medium/.large` |
| `ContainerShape` | CornerLarge 16 / CornerLargeIncreased 20 / CornerExtraLarge 28 | the container radius |
| icon size | 24 / 28 / 32dp | the leading icon |
| leading/trailing space | 16 / 26 / 28dp | edge insets |
| icon-label space | 8 / 12 / 16dp | the gap (the tokens file's 8/16/20 is marked incorrect — Compose uses 8/12/16) |
| label type | TitleMedium / TitleLarge / HeadlineSmall | the label |
| min width | = container height | the per-size minimum square |
| colors / states / disabled / hit target | same as the FAB | all four families |

## Tokens (toggle FAB — FabMenuBaselineTokens)

| Token | Value | Used for |
|---|---|---|
| `CloseButtonContainerShape` | CornerFull | the checked morph target (56dp circle) |
| `CloseButtonIconSize` | 20dp | the checked icon size |
| checked colors | the family's `*`/`On*` solid pair (primary/on_primary, …) | checked container + icon |
| semantics | role `.toggle`, `checked` | the toggle state |

The M3E `ToggleFloatingActionButton` is icon-only — the extended FAB has
no toggle. `checked_icon` defaults to the same icon at the 20dp token
size; a custom icon swaps instead.

## Tokens (BottomAppBarTokens)

| Token | Value | Used for |
|---|---|---|
| `ContainerHeight` | 80dp | the bar height |
| `ContainerColor` | `SurfaceContainer` | the bar fill |
| `ContainerShape` | CornerNone | a flat rect |
| `ContainerElevation` | Level2 | approximated flat — see deviations |
| content padding | 4dp all around (`16 - 12`: the icon buttons' own 12dp touch expansion makes the visual icon land 16dp from the edge) | the actions row |
| FAB slot extra padding | top 8 / end 12 (`12 - 4`, `16 - 4`) | the docked FAB |

So: the actions row packs at `start+4`, vertically centered, filling up
to the FAB slot (`Row.weight(1f)`, `Arrangement.Start` — the slot keeps
its natural width here so a bare icon button is not stretched). The FAB's
end edge sits at `end-16`, its top at `+12` — the standard 56dp FAB is
vertically centered; taller FABs stay top-aligned (Compose
`Alignment.TopStart` inside the padded slot — an 80dp FAB overflows the
bottom edge, matching Compose). RTL mirrors every `start`/`end`: the FAB
docks at the left, the actions flow from the right.

## Tokens (carousel — CarouselDefaults, `Carousel.kt`/`KeylineList.kt`/`Strategy.kt`)

| Token | Value | Used for |
|---|---|---|
| `MinSmallItemSize` / `MaxSmallItemSize` | 40 / 56dp | the small keyline clamp |
| `AnchorSize` | 10dp | the edge "peek" sliver keyline |
| `MediumLargeItemDiffThreshold` | 0.85 | when medium/large sizes are close enough the medium keylines collapse into larges |
| `ItemSpacing` | 0dp default, 8dp per the spec/every sample | the inter-item gap |
| `MaxNonFocalVisibleItemCount` | 2 (multi-browse) / 0 (uncontained) | at most one M + one S zone beyond the focal run |

**multi_browse** (`multiBrowseKeylineList`): `targetLarge =
min(preferredItemSize, carouselMainAxisSize)`, `small =
clamp(targetLarge/3, 40, 56)`, `medium = (large + small) / 2`. Candidate
arrangements `[L][M][S]`, `[L][L][M][S]`, `[L][L][L][M][S]` pick the
lowest `|targetLarge - largeSize| * priority` fit inside the viewport
(spacing excluded), then `Arrangement.fit` adjusts small → medium →
large sizes until it fits, and `itemCount` trims surplus zones: small
keylines first, then medium while at least one medium remains (the
spec's "larges never fill the strip alone" rule). Item centers sit at
`itemMainAxisSize + itemSpacing` intervals; a keyline list maps every
position to a keyline size — the item's painted width is the
interpolation of the two keylines around its center (the morph). Items
outside the keyline range morph to the nearest anchor sliver.

**uncontained** (`uncontainedKeylineList`): `largeItemSize =
min(itemWidth + itemSpacing, carouselMainAxisSize)` — the slot INCLUDES
the inter-item gap, so an `item_width` of 150 paints 158dp-wide items
(Compose's exact behavior: `itemSizeWithSpacing` = the stride between
item centers, `itemMainAxisSize` = the focal mask size). The strategy
fits as many larges as the viewport allows, places a partially-visible
medium item in the remaining space, and pads both ends with anchor
slivers (`max(min(AnchorSize, itemWidth), medium * 0.5)` on the leading
edge).

**Snap**: on release the offset lands on the nearest "item at a focal
keyline" alignment — either the scroll-start list (item `i` at focal
`f`: `i*stride - f*stride`) or the scroll-end list (item `i` at the END
focal: `i*stride + F*stride + large - viewport`, where `F` = the focal
count). Both lists are candidates — the end-shifted list is what makes
the strip rest with an item aligned to the END focal instead of
overshooting. Wheel scrolls stay free; the snap applies on the next drag
release.

## Widgets

### fab (`src/widgets/fab.zig`)

- `fab(allocator, sig, on_pressed, opts)` — `sig == null` → an action
  FAB (role `.button`); `sig != null` → a toggle FAB (role `.toggle`,
  `checked` follows the signal, the click flips it, the 56dp
  CornerFull morph paints the family's solid/on-solid pair).
- The four sizes carry the token table above; `hit_bounds` expands to
  the 48dp platform minimum (the small 40dp FAB's painted size stays 40).
- The icon is internal chrome (`internal` + `exclude_semantics` — the
  `a11y_label` is the accessible name).
- Press lifecycle: `.down` captures + pressed layer, `.up` inside the hit
  bounds fires `on_pressed`; a drag past the touch slop cancels the
  press (pointer capture release / `.outside_down` clears `pressed`).
  Enter/Space fire `on_pressed` while focused.
- RTL: the icon stays centered (no directional chrome); the extended
  FAB's content row mirrors around the inner box.
- `extendedFab(allocator, on_pressed, opts)` — the icon + label row,
  per-size paddings/gaps/type from the token table; children paint
  clipped to the container bounds; same state layers / disabled /
  keyboard / hit-target contract. No toggle (M3E ToggleFAB is icon-only).

### carousel (`src/widgets/carousel.zig`)

- `carousel(allocator, opts)` — a container: the children ARE the items
  (document data, not chrome). `variant = .multi_browse` (fitted
  keylines) or `.uncontained` (fixed `item_width` + the spacing slot).
- Height = the tallest item's measured height; width fills the
  constraints (default 400 unconstrained).
- Horizontal drag scrolls (raw window-space x per pointer — the
  `ScrollInput` convention: moves bubble from the items while the router
  has a capture); release snaps to the nearest item-focal alignment.
  Wheel scrolls (horizontal delta preferred, vertical delta as fallback);
  left/right arrows step one item (`itemMainAxisSize + spacing`), RTL
  mirrors both drag and arrow direction.
- A11y: the strip is a focusable `.list`; plain-container children get
  `.list_item` + `focusable` on every layout (interactive children keep
  their own semantics — a button in an item stays a button).
- `scroll_info`/`scroll_set_offset` hooks for the scrollbar/drag model;
  `scrollOffset`/`setScrollOffset` public accessors (the scroll_view
  convention — the gallery saves/restores the offset across rebuilds).
- Children paint/hit inside the strip's clipped, offset-translated space
  (`pre/post_children_paint` + `pre_children_hit` + `child_clip`).

### bottom_app_bar (`src/widgets/bottom_app_bar.zig`)

- `bottomAppBar(allocator, opts)` — a pure chrome container (like the
  top `appBar`): the `actions` and `fab` option slots are attached as
  children (the tree owns them); the bar owns no interaction.
- Layout: `actions` at `start+4` vertically centered (natural width,
  clamped to the region before the FAB), `fab` at `end-16`/`top+12`
  (Compose's `16 - 4`/`12 - 4` padding math). RTL mirrors both slots.
- Paint: `SurfaceContainer` flat rect (CornerNone). Group semantics,
  label "Bottom app bar" (configurable).

## Registry

| Entry | Category | Notes |
|---|---|---|
| `fab` | `input` | `size`/`color`/`icon`/`enabled`/`a11y_label` automatic; a non-null `checked` drives a live bool signal (toggle FAB); `skip_children` (icon is internal chrome) |
| `extended_fab` | `input` | `size`/`color`/`icon`/`label`/`enabled` automatic; `skip_children` (icon + text chrome) |
| `carousel` | `display` | `variant`/`item_width`/`item_spacing`/`label` automatic; the children ARE the items (document data) |
| `bottom_app_bar` | `navigation` | `actions`/`fab` are slot subtrees; `height`/`label` automatic; `skip_children` (slots are the content) |

50 registered widgets (46 → 50).

## Deviations

- **Elevation is flat** (both FAB and the bottom app bar): the framework
  paints tonal containers without shadow geometry — the M3 level-3/4
  (FAB) and level-2 (bar) shadows are approximated by the container
  color, matching every prior elevation-bearing widget (card, app bar).
- **FAB elevation on hover** (level 3 → 4 in Compose) is likewise flat —
  the hover affordance is the state layer only.
- **Large FAB icon 36dp**: the `FabLargeTokens.IconSize` token is 32 but
  Compose's `LargeFloatingActionButton` uses `LargeFabIconSize` = 36 —
  the visible behavior (and every screenshot) is 36. The toggle's
  checked icon is the `CloseButtonIconSize` 20dp token at every size.
- **Carousel `ItemSpacing` default is 8, not 0**: the token default is
  0 but the spec + every Compose sample space items at 8; the option
  stays editable.
- **Carousel `maxNonFocalVisibleItemCount`** is fixed at the multi-browse
  value (2) for both variants — it only bounds the arrangement search,
  which already limits the zones.
- **Carousel fling** is not modeled (no fling behavior — the drag is
  direct + snap; keyboard/wheel are discrete). Compose's
  `singleAdvanceFlingBehavior` targets one item per fling; our snap
  already aligns to the nearest item.
- **Uncontained `item_width` paints `item_width + item_spacing`**-wide
  items (158 for 150+8): the slot includes the gap, exactly like
  Compose's `largeItemSize = min(itemSize + itemSpacing, viewport)`. The
  option docs call this the "slot width".
- **Carousel item semantics**: `.list`/`.list_item` — the framework's
  `Action` enum has no scroll-specific actions (`activate` only), so the
  strip advertises keyboard scrolling through focus, not actions.
- **Bottom app bar** is the simple (non-flexible) M3E variant — the
  `DockedToolbar`/flexible bottom app bar (scroll behavior, height
  offset) is out of scope.

## Skipped

- Scroll-driven `BottomAppBarScrollBehavior` (hide-on-scroll) — needs
  the nested-scroll plumbing the framework doesn't have.
- Carousel fling physics + `horizontalCentered`/`vertical` variants
  (the M3 carousel is horizontal-only here).
- The M3E `DockedToolbar` (the flexible bottom app bar overload) and
  the `bottom_app_bar` overflow menu.
- FAB elevation shadows (see deviations — no shadow API yet).
