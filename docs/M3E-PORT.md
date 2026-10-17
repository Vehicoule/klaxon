# M3E 1:1 port index

Every M3E widget in `src/widgets/` is ported verbatim from its upstream
Compose material3 source (draw math, measure logic, state layers, tokens) —
not approximated. The vendored Kotlin sources live in `.ref/` (Apache-2.0,
`androidx/androidx`), **pinned** to the commit in `.ref/LOCK`
(androidx-main `677148640cfc`, 2026-10-17): `material3/` widgets+tokens,
`material-ripple/` + `foundation-interaction/` + `animation/` for the
indication/interaction machinery. Re-fetch with
`scripts/fetch-m3e-ref.sh`; check upstream drift with
`scripts/m3e-drift.sh`.

Port contract per widget:

- Same public factory signature + options + signal/semantics API (existing
  tests and goldens keep passing; intentional pixel changes get regenerated
  goldens and a note in the port header).
- Header comment lists the upstream file(s) and the functions ported.
- Replace approximated draw/measure code; don't patch it.
- What does NOT port: composable/modifier machinery, coroutines, predictive
  back, Compose semantics nodes (we have our own a11y model).

| Klaxon widget | Upstream source | Tokens | Status |
|---|---|---|---|
| slider | Slider.kt | SliderTokens | ported (gap/corners/stop dot/handle morph/RTL) |
| dialog | AlertDialog.kt | DialogTokens | **ported** |
| app_bar | AppBar.kt | AppBarTokens + Small/Medium/Large(Flexible) | **ported** |
| bottom_app_bar | AppBar.kt | BottomAppBarTokens | **ported** |
| badge | Badge.kt | BadgeTokens | **ported** |
| bottom_sheet | ModalBottomSheet.kt + SheetDefaults.kt + DragHandle.kt | SheetBottomTokens, DragHandleTokens | **ported** |
| button | Button.kt | Button(S-XL)Tokens, Filled/Tonal/Outlined/TextButtonTokens | **ported** |
| button_group | ButtonGroup.kt | ButtonGroupSmallTokens, ConnectedButtonGroupSmallTokens | **ported** |
| card | Card.kt | FilledCardTokens, ElevatedCardTokens, OutlinedCardTokens | **ported** |
| carousel | carousel/Carousel.kt + Keylines.kt + KeylineList.kt + Strategy.kt + KeylineSnapPosition.kt | — | **ported** |
| checkbox | Checkbox.kt | CheckboxTokens | ported |
| chip | Chip.kt | ChipsTokens, FilterChipTokens, InputChipTokens | ported |
| date_picker | DatePicker.kt | DatePickerModalTokens | **ported** (calendar + YearPickerMenuButton/YearPicker grid; no date-input/range/docked) |
| divider | Divider.kt | DividerTokens | **ported** |
| drawer | NavigationDrawer.kt | NavigationDrawerTokens | ported (modal/dismissible/permanent) |
| fab | FloatingActionButton.kt | FabTokens, Fab(S/M/L)Tokens, ExtendedFab*, Fab*ContainerTokens | **ported** |
| fab_menu | FloatingActionButtonMenu.kt | FabMenuBaselineTokens | **ported** |
| icon_button | IconButton.kt | IconButtonTokens, Filled/Tonal(S/X/XL)IconButtonTokens | **ported** |
| list_item | ListItem.kt | ListTokens | **ported** |
| loading_indicator | LoadingIndicator.kt | LoadingIndicatorTokens | **ported** |
| menu | Menu.kt | MenuTokens, StandardMenuTokens | **ported** |
| nav_bar | NavigationBar.kt | NavigationBarTokens | **ported** |
| navigation_rail | NavigationRail.kt | NavigationRailTokens | **ported** |
| progress | ProgressIndicator.kt + WavyProgressIndicator.kt + internal-(Linear|Circular)WavyProgressModifiers.kt | (Linear|Circular)ProgressIndicatorTokens | **ported** (linear + circular wavy: star/circle ring geometry, arc-length tables, gap/rotate/wave-scroll; no progress spring or 450ms amplitude morph) |
| pull_to_refresh | pulltorefresh/PullToRefresh.kt | PullToRefreshTokens | **ported** (nested-drag/capture semantics; arrow indicator + Level2 shadow) |
| radio | RadioButton.kt | RadioButtonTokens | ported |
| search_bar | SearchBar.kt | SearchBarTokens, SearchViewTokens | **ported** (collapsed bar; the expanded view is `search_view` below) |
| search_view | SearchBar.kt (ExpandedFullScreenSearchView + SearchBarImpl animation) | SearchViewTokens, ListTokens | **ported** (72dp header, full expansion spec: surface morph from the anchor + radius→CornerNone, field/content fades; no predictive-back scrubbing) |
| segmented_button | SegmentedButton.kt | SegmentedButtonTokens | **ported** |
| side_sheet | NavigationDrawer.kt (side-sheet variant) + MDA SideSheetBehavior | SheetBottomTokens | **ported** |
| snackbar | Snackbar.kt | SnackbarTokens | ported |
| split_button | SplitButton.kt | SplitButtonTokens | **ported** |
| switch | Switch.kt | SwitchTokens | ported |
| tabs | Tab.kt + TabRow.kt | TabTokens, Primary/SecondaryNavigationTabTokens | ported |
| text_field | TextField.kt + OutlinedTextField.kt + TextFieldDefaults.kt + TextFieldImpl.kt | FilledTextFieldTokens, OutlinedTextFieldTokens | ported |
| time_picker | TimePicker.kt | TimePickerTokens, TimeInputTokens | **ported** (dial + autoSwitchToMinute; no text-input variant) |
| toolbar | FloatingToolbar.kt | FloatingToolbarTokens, FabBaseline/MediumTokens | ported |
| tooltip | Tooltip.kt | PlainTooltipTokens, RichTooltipTokens | **ported** (plain + rich variant, caret, 4-side placement; no popup/long-press machinery) |

No upstream counterpart (Klaxon-native, M3-styled): avatar, calendar,
color_picker, expansion_panel, stepper, table, tree.

Framework primitives (not widgets): anim, container, gestures, grid_view,
i18n, image, input, layout, list_view, navigator, scroll_*, scrollbar, text.
