# Klaxon Conformance Suite — SPEC

The WPT-style behavioral contract for UI frameworks. A **vector** is a JSON
object describing setup (tree + signals + locale + navigator), a sequence of
input/time actions, and expectations. Any framework that implements the DSL
semantics in this document can be scored by executing `tests/*.json` —
Klaxon runs them through `zig build conformance` against the real widget
tree; other frameworks port the harness per `ADAPTERS.md`.

## 1. Model

A vector builds a **retained widget tree** under a fixed `viewport`, then
replays `actions` and checks `expect`. Everything the vector observes is
deterministic: virtual time, a seeded input router, a logging a11y bridge,
and a fixed set of locales. There is no hidden framework state.

Coordinate system: logical pixels, origin top-left, `x` right, `y` down.
All rects are `[x, y, w, h]`. Colors are `0xRRGGBBAA`.

`"tolerance"` (default `0.01`) is the float-epsilon applied to every
numeric comparison in `expect` — positions, sizes, scroll offsets, signal
values, pixel-count bands.

## 2. Setup

| Key | Meaning |
|---|---|
| `viewport` | `[w, h]` — the root constraints |
| `tree` | node DSL (below); optional for tree-less state tests |
| `signals` | `{name: initial}` — typed signals (`bool`/`number`/`string`/`{min,max}`) |
| `effects` | named effects subscribed to signals — appends `signal:name` to `effect_log` on each run |
| `memo` | `{name: {deps: [sig...], fn: "sum|concat|clamp"|expr}}` — derived values |
| `locales` | `{locale: {key: "template"}}` — ARB tables; `{x}` placeholders |
| `locale` | initial locale (default `en`) |
| `navigator` | `{routes: [{pattern, ...}]}` + initial stack |
| `item_focusable` | whether list items get `focusable` semantics |

### Node DSL

`{"type": T, "id"?: str, "props"?: {...}, "children"?: [...]}`.

`id` registers the node in the `rects`/`text`/`measured`/action maps.
Universal props applied to every node: `flex` (int, flex weight),
`visible` (bool), `exclude_semantics` (bool), `damage_overflow`
(`[l,t,r,b]` — extra damage region past bounds), and **prop semantics**
(`role`, `label`, `hint`, `value`, `checked`, `disabled`, `focusable`,
`actions`) which merge into the node's a11y descriptor.

| `type` | props |
|---|---|
| `box` | `w`, `h`, `color`, `on_press` (test leaf: solid fill, optional press log) |
| `text` | `text`, `size`, `bold`, `color`, `text_align` |
| `row` / `column` | `gap`, `padding`, `main_align`, `cross_align` |
| `stack` | `fit` (`loose`\|`expand`), `alignment` (`[ax, ay]` or `{x,y}` name) |
| `grid` | `columns`, `gap`, `padding` |
| `padding` | `padding` (scalar or `{left,top,right,bottom}`) |
| `padding_directional` | `padding` `{start,top,end,bottom}` (RTL-aware) |
| `center` | — |
| `align` | `alignment` |
| `constrained_box` | `min_w`, `min_h`, `max_w`, `max_h` |
| `expanded` | `weight` — fills remaining main-axis space in a flex parent |
| `container` | `color`, `padding` |
| `button` | — (presses log `press:<id>`) |
| `toggle` | `signal`, `checked` |
| `checkbox` | `signal`, `checked` |
| `radio` | `group`, `value` |
| `slider` | `signal`, `value`, `width` |
| `text_field` | `placeholder`, `initial` |
| `dropdown` | `items`, `selected` |
| `gesture_detector` | `gestures` — subset of `tap,double_tap,long_press,pan_start,pan_update,pan_end,swipe,pinch,rotate` |
| `scroll_view` | — single-child vertical scroller |
| `list_view` | `count`, `item_height`, `item_focusable` |
| `l10n_text` / `l10n_plural` | `key`, `args`/`count` |
| `navigator_view` | `routes` |

## 3. Actions (`actions[]`)

| `op` | fields | effect |
|---|---|---|
| `pointer` | `phase` (`move\|down\|up\|cancel`), `x`, `y`, `t` (ms), `pointer` | routed through hit-test + capture |
| `key` | `key` (name or single char), `kind` (`press\|release`) | keyboard dispatch to focused chain |
| `text_input` | `text` | text commit event |
| `scroll` | `x`, `y`, `dx`, `dy` | wheel/drag scroll at point |
| `tick` | `dt` (ms) | advance virtual time — drives animations/timers |
| `relayout` | `w`, `h` | resize the viewport, re-run layout |
| `mark_dirty` / `mark_dirty_rect` | `id` / `id`+`[x,y,w,h]` | damage marking for repaint assertions |
| `set_scroll` | `offset` | jump a scroll position |
| `signal_set` / `signal_notify` | `name`, `value` | write/notify a declared signal |
| `nav_push` `nav_pop` `nav_replace` `nav_back` `nav_pop_to_root` `nav_push_path` `navigate` | `route`/`path`/`index` | navigator stack ops |
| `list_count` / `list_reload` | `count` | mutate a `list_view` model |
| `focus` | `id` | request focus on a node |
| `announce` | `text`, `region` (`polite\|assertive`) | a11y live-region announce |
| `paint` | — | run one paint pass (records the frame) |

## 4. Expectations (`expect`)

Every key is optional; each present key must fully match.

| key | checks |
|---|---|
| `rects` | `{id: [x,y,w,h]}` final bounds |
| `measured` | `{id: [w,h]}` measured size under the setup constraints |
| `pixels` | `{[x,y]: 0xRRGGBBAA}` exact framebuffer samples after `paint` |
| `pixel_counts` | `{0xRRGGBBAA: [min, max]}` region color bands |
| `damage` | accumulated dirty rect `[x,y,w,h]` after actions |
| `children` | `{id: [child ids...]}` live children of a virtualized list |
| `first_item` | index of the first materialized list row |
| `scroll` | `{id: offset}` scroll offsets |
| `scroll_info` | `{id: {offset, viewport, max}}` |
| `signals` | `{name: value}` final signal values |
| `effect_log` | `[signal:name, ...]` effect run order |
| `memo_value` | `{name: value}` memoized results |
| `events` | ordered `press:`/`change:`/`submit:` widget callback log |
| `gestures` | ordered recognized-gesture log (`tap`, `swipe:left`, `pinch:1.5`, ...) |
| `text` | `{id: "content"}` text-field/displayed strings |
| `focus_order` | `[id...]` tab order (focusable pre-order) |
| `focused` / `router_focused` | id of the focused node / router-captured node |
| `a11y` | ordered flattened semantic nodes: `{role,label,hint,value,checked,disabled,focusable}` |
| `a11y_events` | ordered bridge events `{kind,text,checked,focusable,disabled}` |
| `nav` | `{stack:[route...], index, params}` navigator state |
| `action_error` | the error an action raised (expected failure) |
| `i18n` | `{key: "translated"}` resolved strings |

## 5. Behavioral contract (the rules)

### LAYOUT — constraint propagation

- **LAYOUT-001** `column` stacks children top-down at their measured heights.
- **LAYOUT-002** `row` lays children left-to-right at their measured widths.
- **LAYOUT-003** `expanded` children share remaining main-axis space by `weight`.
- **LAYOUT-004** `main_align`/`cross_align` position children in the free space (`start|center|end|space_between|space_around`).
- **LAYOUT-005** `padding` shrinks the child region by the insets (fill semantics — child gets the inner rect).
- **LAYOUT-006** `stack.fit: expand` tightens the stack to the parent-offered size AND each child to the stack bounds; `loose` shrink-wraps to the largest child and aligns. (Flutter semantics: inside a `column`, `expand` claims the full offered height — overflow is the caller's problem; use `expanded` for fill-remaining.)
- **LAYOUT-007** `grid` gives every cell `floor((w - padding*2 - gap*(cols-1)) / cols)`; children fill their cells.
- **LAYOUT-008** `constrained_box` clamps the child's measured size to `[min,max]` on both axes.

### PAINT — damage + raster contract

- **PAINT-001** a `box` paints exactly its bounds in its color.
- **PAINT-002** z-order is document order — later siblings paint over earlier.
- **PAINT-003** `mark_dirty`/`mark_dirty_rect` accumulate into the damage region.
- **PAINT-004** `damage_overflow` extends a node's damage past its bounds (state layers, glow).
- **PAINT-005** `container` paints its fill (and border) under the child.
- **PAINT-006** state changes repaint the affected region only.

### GEST — gesture arena

- **GEST-001** `down`-`up` inside the slop is `tap`.
- **GEST-002** two taps within the double-tap window is `double_tap` (and the second tap does NOT re-fire `tap`).
- **GEST-003** press held past the long-press timeout without moving is `long_press`.
- **GEST-004** drag emits `pan_start` → `pan_update`×n → `pan_end`.
- **GEST-005** a fast fling emits `swipe:<dir>` with dominant-axis direction.
- **GEST-006** two pointers produce `pinch` (scale factor) — and suppress `pan`.
- **GEST-007** two-pointer rotation emits `rotate` (radians).
- Arena rule: exactly one recognizer wins a pointer sequence; losers get `cancel`.

### STATE — fine-grained reactivity

- **STATE-001** writing a signal re-runs dependent effects once, in order.
- **STATE-002** batching: multiple writes inside one flush coalesce effect runs.
- **STATE-003** effects only re-run when a *read* dependency changed.
- **STATE-004** `memo` caches; recomputes iff a dep changed; effects reading it see the new value once.
- **STATE-005** untracked reads do not subscribe (no accidental reactivity).
- **STATE-006** widget-bound signals repaint the widget (and fire `change` events) on write.
- **STATE-007** writing an undeclared signal raises `action_error`.

### SCROLL — virtualized lists

- **SCROLL-001** `scroll_view` clamps offset to `[0, content - viewport]`.
- **SCROLL-002** `set_scroll` jumps directly (same clamp).
- **SCROLL-003** `scroll_info` reports `{offset, viewport, max}`.
- **SCROLL-004** `list_view` materializes only the visible window (`children` ≈ `viewport/item_height + overscan`); `first_item` tracks the offset.
- **SCROLL-005** scrolling a list updates the window without touching offscreen items.
- **SCROLL-006** `list_count`/`list_reload` rebind the model in place (scroll kept).

### NAV — page stack

- **NAV-001** `push` appends; `back`/`pop` removes the top.
- **NAV-002** `replace` swaps the top, `pop_to_root` clears to the first.
- **NAV-003** route params bind `{name}` path segments; `navigate` resolves deep links.
- **NAV-004** unknown routes raise `action_error` (no silent push).
- **NAV-005** `push_path` expands a multi-segment path into multiple stack entries.
- **NAV-006** back events reach the navigator via the focused chain first.
- **NAV-007** the stack/index stay consistent across mixed ops.

### FOCUS — keyboard navigation

- **FOCUS-001** `focus_order` is the pre-order of focusable nodes (skips `exclude_semantics` and `visible:false` subtrees).
- **FOCUS-002** `tab`/`shift+tab` move focus cyclically through that order.
- **FOCUS-003** `enter`/`space` on a focused button fires its press.
- **FOCUS-004** a focused `text_field` swallows text keys (types) and `enter` submits.
- **FOCUS-005** arrows on a focused slider increment/decrement its signal.
- **FOCUS-006** a pointer press on a focusable node moves focus to it.

### A11Y — semantic contract

- **A11Y-001** every widget emits its role; containers without semantics are transparent (children lift).
- **A11Y-002** `exclude_semantics` hides the node and its subtree.
- **A11Y-003** `label`/`hint`/`value`/`disabled`/`focusable`/`checked` surface from the descriptor (or prop semantics).
- **A11Y-004** interactive controls report `role`, `checked`, `focusable` (toggle/checkbox/slider/...).
- **A11Y-005** `announce` produces `live_region` bridge events in order.
- **A11Y-006** control changes emit `control_changed` bridge events.
- **A11Y-007** text fields announce their *current* content — including the initial value (a pre-filled field is not silent).

### I18N — locale + direction

- **I18N-001** `tr` resolves the key in the active locale, falls back to `en`, then to the key itself.
- **I18N-002** `{arg}` interpolation substitutes positional/named args.
- **I18N-003** `plural` selects the CLDR category (`zero|one|two|few|many|other`) per locale.
- **I18N-004** `set_locale` switches resolution live (signals re-evaluate).
- **I18N-005** number/date formatting follows the locale (`pct`, `nogroup`, `dec=N` options).
- **I18N-006** RTL mirrors the main axis and resolves directional insets (`start`/`end`) per direction.
- **I18N-007** `l10n_plural` re-renders on count change and locale switch.

## 6. Scoring

A vector **passes** iff zero mismatches. Score = `passed / total` per
domain and overall. `zig build conformance` exits non-zero below
`--min-score` (default `1.0`). The JSON report (machine-readable) lands in
`conformance/results-<utc>.json`.
