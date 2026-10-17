// Floating toolbar (M3E) — 1:1 port of Compose material3 FloatingToolbar.kt
// (HorizontalFloatingToolbar / HorizontalFloatingToolbarWithFabLayout).
//
// Upstream sources (.ref/material3, androidx-main):
//   - FloatingToolbar.kt: HorizontalFloatingToolbarWithFabLayout (the FAB
//     sits BESIDE the pill with a ToolbarToFabGap 8dp gap; the bar shrinks
//     to width*expandedProgress toward the FAB edge while the FAB lerps
//     FabSizeRange FabBaseline..FabMedium = 56..80)
//   - tokens/FloatingToolbarTokens.kt: ContainerHeight 64, Leading/Trailing
//     Space 8, CornerFull, Standard SurfaceContainer, Vibrant
//     PrimaryContainer
//   - colors (defaultFloatingToolbar{Standard,Vibrant}Colors): content =
//     contentColorFor(container); FAB = PrimaryContainer (standard) /
//     TertiaryContainer (vibrant); elevation = Level0 no-FAB / Level1
//     expanded-with-FAB, FAB Level2 (hover Level3)
//
// Ported: the 64dp pill with adjacent 48dp icon cells (the upstream Row
// has no spacedBy — cells touch), the beside-FAB expand/collapse morph
// (bar width lerp + FAB 56↔80 + elevation lerp, FastSpatial-ish tween),
// vibrant color pair fix, RTL mirroring.
//
// Deviations: the slots are chrome painted by the widget (a leaf — Compose
// takes arbitrary composable children); up/down arrows are not claimed;
// no scrollBehavior wiring (the expanded flag is a Signal the app or the
// scroll host drives); FAB position = End only (Start mirrors in RTL).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const i18n_mod = @import("../ui/i18n.zig");
const anim = ui.anim;
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const icon_w = @import("icon.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

/// One toolbar slot: an icon action, or a group separator when `divider`
/// is set (icon/on_press/enabled are then ignored). The factory copies
/// `a11y_label`; null names the item after its icon's tag ("search", ...).
pub const ToolbarItem = struct {
    icon: icon_w.IconName = .star,
    on_press: ?Callback = null,
    enabled: bool = true,
    /// The accessible name (null = the icon's tag name).
    a11y_label: ?[]const u8 = null,
    /// true = a 1dp x 24dp OutlineVariant vertical separator, not a button.
    divider: bool = false,
};

pub const ToolbarOptions = struct {
    /// M3E vibrant variant: PrimaryContainer pill + OnPrimaryContainer
    /// content, TertiaryContainer FAB (the standard variant is
    /// SurfaceContainer/OnSurfaceVariant + PrimaryContainer FAB).
    vibrant: bool = false,
    /// A FAB beside the pill's END edge, 8dp away (null = no FAB slot).
    /// With `expanded` set, collapsing shrinks the bar to nothing and grows
    /// the FAB 56→80 (HorizontalFloatingToolbarWithFabLayout).
    fab_icon: ?icon_w.IconName = null,
    on_fab_press: ?Callback = null,
    /// The docked FAB's accessible name (an icon-only control) — null
    /// resolves the localized "Action".
    fab_a11y_label: ?[]const u8 = null,
    /// Live expanded state (null = always expanded). Collapsed = just the
    /// FAB (or an empty pill without one).
    expanded: ?*ui.state.Signal(bool) = null,
    /// The group's accessible name — null resolves the localized "Toolbar"
    /// (an app string is verbatim).
    a11y_label: ?[]const u8 = null,
    theme: Theme = theme_mod.light,
};

/// M3E tokens (FloatingToolbarTokens + FloatingToolbarDefaults).
const bar_height: f32 = 64; // ContainerHeight
const bar_outer_height: f32 = 80; // with-FAB min height = FabSizeRange.end (FabMedium)
const h_pad: f32 = 8; // ContainerLeadingSpace / ContainerTrailingSpace
// A standard icon-button cell is the a11y floor: theme.platform
// .hit_target_min (48 mobile / 24 desktop) — read from s.opts.theme.
const icon_size: f32 = 24; // IconSize
const divider_w: f32 = 1; // the separator's thickness
const divider_h: f32 = 24; // the separator's length
const fab_min: f32 = 56; // FabBaselineTokens.ContainerWidth (expanded)
const fab_max: f32 = 80; // FabMediumTokens.ContainerWidth (collapsed)
const toolbar_fab_gap: f32 = 8; // ToolbarToFabGap
const fab_corner: f32 = 16; // CornerLarge squircle
const fab_icon_size: f32 = 24;
const bar_elevation_expanded: f32 = 1; // ContainerExpandedElevationWithFab = Level1
const fab_elevation: f32 = 3; // Level2 (default toolbar FAB)
const fab_elevation_hover: f32 = 6; // Level3
// The expand/collapse tween rides theme.motion.durations.medium2 (300ms —
// upstream MotionScheme FastSpatial ~300ms).
const shadow_spill: f32 = 16; // paint/damage overflow covering the shadows

/// Per-slot indication machinery — upstream's toolbar children are ordinary
/// composables: each icon slot is an IconButton carrying its own
/// interactionSource + clickable ripple, and the docked FAB is a
/// FloatingActionButton with the same set. items.items never re-allocs
/// after init (same guarantee the a11y children rely on) — the
/// ticker/channel userdata pointers stay stable.
const ItemFx = struct {
    inter: ui.interactions.Tracker = .{},
    layer: ui.state_layer.StateLayer = .{},
    ripples: ui.ripple.Ripples = .{},
    /// The live press's tracker id (0 = none) — pairs tracker.release and
    /// ripples.release for this slot.
    press_id: u32 = 0,

    fn wire(fx: *ItemFx, n: *Node, t: Theme) void {
        fx.inter.node = n;
        fx.layer.node = n;
        fx.layer.alphas = .{ .hover = t.state.hover, .focus = t.state.focus, .pressed = t.state.pressed, .drag = t.state.drag };
        fx.ripples = .{ .bounded = true, .node = n, .pressed_alpha = t.state.pressed };
    }

    fn unwire(fx: *ItemFx) void {
        fx.layer.deinit(); // the in-flight tween's userdata is `l`
        fx.ripples.deinit(); // the live ticker's userdata is `r`
    }
};

const ItemDef = struct {
    label: [:0]const u8, // owned
    icon: icon_w.IconName,
    on_press: ?Callback,
    enabled: bool,
    divider: bool,
    /// The slot's own interaction set (wired in toolbar() once the list
    /// is final; a divider's sits unused — it gets no interactions).
    fx: ItemFx = .{},
};

const ToolbarState = struct {
    items: std.array_list.Managed(ItemDef), // owned defs
    /// Live per-slot a11y descriptors — the semantics tree's virtual
    /// children borrow this slice (item slots, then the trailing FAB).
    sem_children: std.array_list.Managed(ui.semantics.Semantics),
    opts: ToolbarOptions,
    fab_label: [:0]const u8, // owned
    /// The slot index under the finger/pen — items.len = the docked FAB
    /// (-1 = none).
    pressed: i32 = -1,
    hovered: i32 = -1,
    /// The keyboard-active slot (arrows move it; Enter/Space activates it;
    /// the focus state layer paints on it while the group is focused).
    active: i32 = -1,
    /// The docked FAB's own interaction set (a FloatingActionButton
    /// upstream — its own clickable + ripple).
    fab_fx: ItemFx = .{},
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — gestures.SLOP).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
    i18n: ?*i18n_mod.I18n = null,
    /// Expand/collapse (FloatingToolbarWithFabLayout): 1 = the bar is fully
    /// expanded (FAB at FabBaseline 56), 0 = collapsed (bar width 0, FAB at
    /// FabMedium 80). Animated with the FastSpatial-ish tween.
    expand_progress: f32 = 1,
    expand_target: f32 = 1,
    expand_channel: u8 = 0, // channel marker (stable address)
};

fn stateOf(n: *Node) *ToolbarState {
    return @ptrCast(@alignCast(n.state.?));
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

fn hasFab(s: *const ToolbarState) bool {
    return s.opts.fab_icon != null;
}

fn cellW(t: Theme, def: ItemDef) f32 {
    return if (def.divider) divider_w else t.platform.hit_target_min;
}

/// The virtual slot count: the item cells, then the docked FAB.
fn slotCount(s: *const ToolbarState) usize {
    return s.items.items.len + @intFromBool(hasFab(s));
}

/// Interactive slots only (an enabled action, or the always-on FAB).
fn pressable(s: *const ToolbarState, idx: i32) bool {
    if (idx < 0) return false;
    const i: usize = @intCast(idx);
    if (i == s.items.items.len) return hasFab(s);
    return i < s.items.items.len and s.items.items[i].enabled and !s.items.items[i].divider;
}

/// The bar content's intrinsic width (upstream maxToolbarPlaceableWidth):
/// the 8dp leading/trailing spaces around the adjacent cells.
fn barContentWidth(s: *const ToolbarState) f32 {
    var w: f32 = h_pad * 2;
    for (s.items.items) |def| w += cellW(s.opts.theme, def);
    return w;
}

/// The whole widget's width (upstream `width` = maxBarW + gap + fabMin).
fn totalWidth(s: *const ToolbarState) f32 {
    var w = barContentWidth(s);
    if (hasFab(s)) w += toolbar_fab_gap + fab_min;
    return w;
}

/// The FAB's current size: 80 collapsed → 56 expanded (upstream lerps
/// FabSizeRange by 1 - expandedProgress).
fn fabSize(s: *const ToolbarState) f32 {
    return fab_max + (fab_min - fab_max) * s.expand_progress;
}

/// The bar pill rect in LTR space: its END edge is pinned at
/// b.x + barContentWidth; collapsing slides the start edge toward it
/// (upstream toolbarX = maxBarW - barW).
fn barRectLtr(s: *const ToolbarState, b: Rect) Rect {
    const cw = barContentWidth(s);
    const bw = cw * s.expand_progress;
    return .{
        .x = b.x + (cw - bw),
        .y = b.y + (b.h - bar_height) / 2,
        .w = bw,
        .h = bar_height,
    };
}

/// The FAB rect in LTR space: its END edge is pinned at the widget's end
/// edge (upstream fabX = width - fabW), vertically centered.
fn fabRectLtr(s: *const ToolbarState, b: Rect) Rect {
    const fs = fabSize(s);
    return .{
        .x = b.x + b.w - fs,
        .y = b.y + (b.h - fs) / 2,
        .w = fs,
        .h = fs,
    };
}

/// Slot `index`'s rect in LTR space: 0..items.len = the item cells inside
/// the bar (they ride the shrinking pill — x follows barRectLtr), a
/// divider's is its 1dp x 24dp line; items.len = the FAB beside the pill.
/// The caller mirrors for RTL.
fn slotRectLtr(s: *const ToolbarState, b: Rect, index: usize) Rect {
    const count = s.items.items.len;
    if (index == count) return fabRectLtr(s, b);
    const bar = barRectLtr(s, b);
    var x = bar.x + h_pad;
    for (0..index) |i| x += cellW(s.opts.theme, s.items.items[i]);
    const def = s.items.items[index];
    if (def.divider) {
        return .{ .x = x, .y = b.y + (b.h - divider_h) / 2, .w = divider_w, .h = divider_h };
    }
    const cell = s.opts.theme.platform.hit_target_min;
    return .{ .x = x, .y = b.y + (b.h - cell) / 2, .w = cell, .h = cell };
}

fn mirrorX(b: Rect, r: Rect) Rect {
    return .{ .x = b.x + b.w - (r.x - b.x) - r.w, .y = r.y, .w = r.w, .h = r.h };
}

/// Slot `index`'s rect in the widget's parent space (RTL mirrors).
fn slotRect(s: *const ToolbarState, b: Rect, index: usize) Rect {
    var r = slotRectLtr(s, b, index);
    if (ui.i18n.direction() == .rtl) r = mirrorX(b, r);
    return r;
}

/// The slot under the point (-1 = none), in the widget's parent space. The
/// item cells are hit only inside the (possibly shrunken) bar rect — a
/// collapsing bar's clipped items don't press. The whole column is the hit
/// zone (the cells' tight height is only the painted affordance).
fn slotAt(s: *const ToolbarState, b: Rect, x: f32, y: f32) i32 {
    const bar_l = barRectLtr(s, b);
    const bar = if (ui.i18n.direction() == .rtl) mirrorX(b, bar_l) else bar_l;
    const in_bar = x >= bar.x and x < bar.x + bar.w;
    for (0..slotCount(s)) |i| {
        const r = slotRect(s, b, i);
        const is_fab = i == s.items.items.len;
        if (!is_fab and !in_bar) continue;
        if (x >= r.x and x < r.x + r.w and y >= b.y and y < b.y + b.h) return @intCast(i);
    }
    return -1;
}

/// Slot `index`'s rect in NODE-LOCAL space (Semantics.child_bounds — the
/// a11y bridge maps it to window space for highlights and activation taps).
fn slotChildBounds(n: *Node, index: usize) Rect {
    const s = stateOf(n);
    const local = Rect{ .x = 0, .y = 0, .w = n.bounds.w, .h = n.bounds.h };
    return slotRect(s, local, index);
}

/// The next pressable slot from `from` stepping `step`, wrapping (-1 =
/// none — an all-disabled, FAB-less toolbar has nothing to move to).
fn nextPressable(s: *const ToolbarState, from: i32, step: i32) i32 {
    const total: i32 = @intCast(slotCount(s));
    if (total == 0) return -1;
    var i: i32 = from;
    var guard: i32 = 0;
    while (guard < total) : (guard += 1) {
        i = @mod(i + step, total);
        if (pressable(s, i)) return i;
    }
    return -1;
}

/// Fire a slot's callback: an item's on_press, or the docked FAB's
/// on_fab_press (index == items.len). Inert slots do nothing.
fn slotActivate(n: *Node, idx: usize) void {
    const s = stateOf(n);
    if (idx == s.items.items.len) {
        if (hasFab(s)) {
            s.active = @intCast(idx);
            if (s.opts.on_fab_press) |cb| cb.fn_ptr(cb.userdata);
        }
        return;
    }
    if (!pressable(s, @intCast(idx))) return;
    s.active = @intCast(idx);
    if (s.items.items[idx].on_press) |cb| cb.fn_ptr(cb.userdata);
}

fn toolbarMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    // upstream: defaultMinSize(minHeight = FabSizeRange.endInclusive) — the
    // with-FAB toolbar is 80 tall (the collapsed FAB fills it)
    const h = if (hasFab(s)) bar_outer_height else bar_height;
    return c.constrain(.{ .w = totalWidth(s), .h = h });
}

fn toolbarLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: the slots are computed from the bounds at paint/hit
}

/// Paint an icon in a size x size box — vector geometry (icon.zig), not a
/// font glyph.
fn paintIcon(ctx: *kx.Ctx, name: icon_w.IconName, x: f32, y: f32, size: f32, color: Color) void {
    if (color & 0xFF == 0) return;
    icon_w.drawIcon(ctx, name, x, y, size / 24.0, color);
}

fn toolbarPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const cs = t.colors;
    const b = n.bounds;
    // upstream vibrant = PrimaryContainer/OnPrimaryContainer pill,
    // TertiaryContainer FAB; standard = SurfaceContainer/OnSurfaceVariant,
    // PrimaryContainer FAB
    const container: Color = if (s.opts.vibrant) cs.primary_container else cs.surface_container;
    const on: Color = if (s.opts.vibrant) cs.on_primary_container else cs.on_surface_variant;
    const fab_bg: Color = if (s.opts.vibrant) cs.tertiary_container else cs.primary_container;
    const fab_fg: Color = if (s.opts.vibrant) cs.on_tertiary_container else cs.on_primary_container;
    const focused = input.isFocused(n);
    const bar_l = barRectLtr(s, b);
    const bar = if (ui.i18n.direction() == .rtl) mirrorX(b, bar_l) else bar_l;
    const count = s.items.items.len;
    if (bar.w > 0.5) {
        // the pill: with-FAB elevation lerps Level0→Level1 by progress,
        // no-FAB is flat (upstream ContainerExpandedElevation = Level0)
        const elev = if (hasFab(s)) bar_elevation_expanded * s.expand_progress else 0;
        if (elev > 0.01) ui.paint.elevationShadow(ctx, bar.x, bar.y, bar.w, bar.h, bar.h / 2, elev, cs.shadow);
        ui.paint.fillRRect(ctx, bar.x, bar.y, bar.w, bar.h, bar.h / 2, container);
        // the items clip to the shrinking pill (upstream clip=true)
        ui.paint.clipRect(ctx, bar.x, bar.y, bar.w, bar.h);
        for (0..count) |i| {
            const idx: i32 = @intCast(i);
            const r = slotRect(s, b, i);
            if (s.items.items[i].divider) {
                ui.paint.fillRect(ctx, r.x, r.y, r.w, r.h, cs.outline_variant);
                continue;
            }
            const enabled = pressable(s, idx);
            // the indication (enabled slots only — upstream's enabled=false
            // drops the whole interaction set): the animated state layer +
            // the bounded ink, clipped to the cell's full circle (the slot
            // is an IconButton upstream — IconButton.kt's indication clips
            // to the CornerFull container)
            if (enabled) {
                const fx = &s.items.items[i].fx;
                fx.inter.setFocused(focused and s.active == idx);
                fx.layer.sync(&fx.inter, on);
                if (fx.layer.paintColor()) |lc| {
                    ui.paint.fillRRect(ctx, r.x, r.y, r.w, r.h, r.h / 2, lc);
                }
                fx.ripples.color = on;
                fx.ripples.paintIn(ctx, r, .{ .rrect = r.h / 2 });
            }
            // the icon (centered in the cell; disabled = OnSurface @ 0.38)
            const fg: Color = if (enabled) on else ui.paint.withAlphaScaled(cs.on_surface, 0.38);
            paintIcon(ctx, s.items.items[i].icon, r.x + (r.w - icon_size) / 2, r.y + (r.h - icon_size) / 2, icon_size, fg);
        }
        ui.paint.clipReset(ctx);
    }
    // the beside-FAB paints OUTSIDE the pill clip (Level2 squircle, Level3
    // hovered — upstream FloatingActionButtonDefaults elevation; the hover
    // read is the tracker's, like FloatingActionButton.kt's elevation)
    if (hasFab(s)) {
        const idx: i32 = @intCast(count);
        const r = slotRect(s, b, count);
        const fx = &s.fab_fx;
        const elev = if (fx.inter.isHovered()) fab_elevation_hover else fab_elevation;
        ui.paint.elevationShadow(ctx, r.x, r.y, r.w, r.h, fab_corner, elev, cs.shadow);
        ui.paint.fillRRect(ctx, r.x, r.y, r.w, r.h, fab_corner, fab_bg);
        // the FAB's own indication: animated layer + bounded ink clipped
        // to the squircle, in the FAB's content color
        fx.inter.setFocused(focused and s.active == idx);
        fx.layer.sync(&fx.inter, fab_fg);
        if (fx.layer.paintColor()) |lc| {
            ui.paint.fillRRect(ctx, r.x, r.y, r.w, r.h, fab_corner, lc);
        }
        fx.ripples.color = fab_fg;
        fx.ripples.paintIn(ctx, r, .{ .rrect = fab_corner });
        paintIcon(ctx, s.opts.fab_icon.?, r.x + (r.w - fab_icon_size) / 2, r.y + (r.h - fab_icon_size) / 2, fab_icon_size, fab_fg);
    }
}

/// The interaction set of slot `idx` — items.len is the docked FAB's.
fn slotFx(s: *ToolbarState, idx: i32) *ItemFx {
    const i: usize = @intCast(idx);
    return if (i == s.items.items.len) &s.fab_fx else &s.items.items[i].fx;
}

/// End a slot's live press (release = up, cancel = drag-off/outside) — the
/// tracker entry and its ripple pair on `press_id`.
fn toolbarEndPress(s: *ToolbarState, idx: i32, now_ms: u64, cancel: bool) void {
    const fx = slotFx(s, idx);
    if (fx.press_id == 0) return;
    if (cancel) fx.inter.cancel(fx.press_id) else fx.inter.release(fx.press_id);
    fx.ripples.release(fx.press_id, now_ms);
    fx.press_id = 0;
}

/// Move the hover interaction to a new slot (-1 = none). Inert slots get
/// no tracker entry (upstream: enabled=false drops the interaction set);
/// `hovered` still records the index.
fn toolbarSetHover(s: *ToolbarState, idx: i32) void {
    if (idx == s.hovered) return;
    if (s.hovered >= 0) slotFx(s, s.hovered).inter.endHover();
    s.hovered = idx;
    if (pressable(s, idx)) _ = slotFx(s, idx).inter.hoverEnter();
}

fn toolbarOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    const idx = slotAt(s, n.bounds, ev.x, ev.y);
    switch (ev.phase) {
        .down => {
            if (!pressable(s, idx)) return false;
            // a second pointer supersedes the live press
            if (s.pressed >= 0) toolbarEndPress(s, s.pressed, ev.time_ms, true);
            const fx = slotFx(s, idx);
            fx.press_id = fx.inter.pressDown(ev.x, ev.y);
            fx.ripples.spawn(fx.press_id, ev.x, ev.y, ev.time_ms);
            s.pressed = idx;
            s.active = idx;
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            input.requestFocus(n); // a pressed slot takes the keyboard focus
            return true;
        },
        .up => {
            const was = s.pressed;
            s.pressed = -1;
            if (was >= 0) toolbarEndPress(s, was, ev.time_ms, false);
            if (was >= 0 and idx == was) slotActivate(n, @intCast(was));
            return true;
        },
        .move => {
            // A drag beyond the touch slop is a scroll, not a press: cancel
            // the press. The move is NOT claimed (return false) so it keeps
            // bubbling to scrollable ancestors.
            if (s.pressed >= 0) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    toolbarEndPress(s, s.pressed, ev.time_ms, true);
                    s.pressed = -1;
                }
            }
            return false;
        },
        // the pointer went down outside while we held the capture: cancel
        .outside_down => {
            if (s.pressed >= 0) {
                toolbarEndPress(s, s.pressed, ev.time_ms, true);
                s.pressed = -1;
            }
            return true;
        },
        .enter => {
            toolbarSetHover(s, idx);
            return true;
        },
        // moving across slots within the leaf emits hover_move (not
        // enter/leave): re-resolve the slot under the pointer
        .hover_move => {
            toolbarSetHover(s, idx);
            return true;
        },
        .leave => {
            toolbarSetHover(s, -1);
            return true;
        },
    }
    return false;
}

/// Keyboard: the group is focusable; left/right move the ACTIVE slot,
/// skipping dividers and disabled items and wrapping (RTL flips
/// left/right); Enter/Space activates it.
fn toolbarOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .left, .right => {
            const rtl = ui.i18n.direction() == .rtl;
            var step: i32 = if (ev.key == .right) 1 else -1;
            if (rtl) step = -step; // the visual order flips
            const next = nextPressable(s, s.active, step);
            if (next < 0) return false;
            s.active = next;
            n.markDirty();
            return true;
        },
        .enter, .space => {
            if (s.active < 0) return false;
            // upstream's keyPress emits Press+Release on the slot's
            // interactionSource — a centered bounded ripple over its zone
            // (the icon cell's circle / the FAB's squircle) that still
            // runs its full expand + fade-out.
            const fx = slotFx(s, s.active);
            const r = slotRect(s, n.bounds, @intCast(s.active));
            const cx = r.x + r.w / 2;
            const cy = r.y + r.h / 2;
            const pid = fx.inter.pressDown(cx, cy);
            fx.ripples.spawn(pid, cx, cy, 0);
            fx.inter.release(pid);
            fx.ripples.release(pid, 0);
            slotActivate(n, @intCast(s.active));
            return true;
        },
        else => {},
    }
    return false;
}

/// Expand/collapse (upstream expandedProgress): a tween toward the target
/// — snaps without a timeline.
fn retargetExpand(n: *Node, s: *ToolbarState, target: f32) void {
    if (target == s.expand_target) return;
    s.expand_target = target;
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.tweenAnim(.{ target, 0, 0, 0 }, s.opts.theme.motion.durations.medium2, .{ .ease = .standard }),
            .from = .{ s.expand_progress, 0, 0, 0 },
            .channel = @ptrCast(&s.expand_channel),
            .on_update = .{ .fn_ptr = expandCb, .userdata = n },
        });
    } else {
        s.expand_progress = target;
        n.markDirty();
    }
}

fn expandCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.expand_progress = value[0];
    n.markDirty();
}

fn expandSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const target: f32 = if (s.opts.expanded.?.peek()) 1 else 0;
    retargetExpand(n, s, target);
}

fn toolbarDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.expand_channel));
    if (s.opts.expanded) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = expandSyncCb, .userdata = n } });
    input.releaseNode(n);
    for (s.items.items) |*def| {
        def.fx.unwire(); // ticker + tween userdata die before the state
        n.allocator.free(def.label);
    }
    s.fab_fx.unwire();
    s.items.deinit();
    s.sem_children.deinit();
    n.allocator.free(s.fab_label);
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = toolbarLocaleCb, .userdata = n });
    n.allocator.destroy(s);
}

/// The group label + a defaulted FAB name are tr()-resolved — the locale
/// callback re-dupes the FAB label and re-attaches in the new locale (the
/// item labels are app strings, verbatim).
fn toolbarLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (hasFab(s) and s.opts.fab_a11y_label == null) {
        n.allocator.free(s.fab_label);
        s.fab_label = dupeZ(n.allocator, i18n_mod.tr("Action")) catch @panic("klaxon: out of memory");
        s.sem_children.items[s.sem_children.items.len - 1].label = s.fab_label;
    }
    ui.semantics.attach(n, .{
        .role = .group,
        .label = s.opts.a11y_label orelse i18n_mod.tr("Toolbar"),
        .focusable = s.active >= 0, // takes the keyboard focus when it has an action
        .children = s.sem_children.items,
        .child_bounds = slotChildBounds,
    });
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

/// The interactive target: ≥ hit_target_min tall centered on the container
/// (a constrained-short pill still meets the a11y touch floor).
fn toolbarHitBounds(n: *Node) Rect {
    const s = stateOf(n);
    const b = n.bounds;
    const h = @max(b.h, s.opts.theme.platform.hit_target_min);
    return .{ .x = b.x, .y = b.y + (b.h - h) / 2, .w = b.w, .h = h };
}

const toolbar_vtable = ui.node.VTable{
    .measure = toolbarMeasure,
    .layout = toolbarLayout,
    .paint = toolbarPaint,
    .deinit = toolbarDeinit,
    .on_pointer = toolbarOnPointer,
    .on_key = toolbarOnKey,
    .hit_bounds = toolbarHitBounds,
};

/// An M3E floating toolbar. The items are internal chrome painted by the
/// widget (a leaf — no document children). `items` are copied (the labels
/// are owned). `opts.fab_icon` adds a FAB beside the pill's end edge;
/// `opts.expanded` (a live signal) collapses the bar into the FAB
/// (upstream HorizontalFloatingToolbarWithFabLayout); `opts.vibrant` swaps
/// the SurfaceContainer/OnSurfaceVariant + PrimaryContainer-FAB palette
/// for PrimaryContainer/OnPrimaryContainer + TertiaryContainer-FAB.
pub fn toolbar(allocator: std.mem.Allocator, items: []const ToolbarItem, opts: ToolbarOptions) !*Node {
    const node = try Node.create(allocator, &toolbar_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(ToolbarState);
    errdefer allocator.destroy(s);
    s.* = .{
        .items = std.array_list.Managed(ItemDef).init(allocator),
        .sem_children = std.array_list.Managed(ui.semantics.Semantics).init(allocator),
        .opts = opts,
        .fab_label = "",
    };
    // One ownership boundary: on ANY failure this errdefer frees the
    // appended defs' labels (toolbarDeinit owns them only once returned).
    errdefer {
        for (s.items.items) |*def| allocator.free(def.label);
        s.items.deinit();
    }
    for (items) |item| {
        const label = try dupeZ(allocator, if (item.divider) "" else item.a11y_label orelse @tagName(item.icon));
        errdefer allocator.free(label); // iteration scope: freed only if THIS iteration fails before the append
        // No catch-free here: on append failure the errdefer frees the copy.
        try s.items.append(.{ .label = label, .icon = item.icon, .on_press = item.on_press, .enabled = item.enabled, .divider = item.divider });
    }
    s.fab_label = try dupeZ(allocator, opts.fab_a11y_label orelse i18n_mod.tr("Action"));
    errdefer allocator.free(s.fab_label);
    s.active = nextPressable(s, -1, 1); // the keyboard focus starts on the first action
    if (opts.expanded) |sig| {
        s.expand_progress = if (sig.peek()) 1 else 0;
        s.expand_target = s.expand_progress;
        sig.subscribe(.{ .callback = .{ .fn_ptr = expandSyncCb, .userdata = node } });
    }
    node.state = s;
    // The per-slot indication sets (items fixed at construction → stable
    // addresses): mutations + ticks damage the toolbar node; the layer
    // alphas + the pressed ink come from the theme state table.
    for (s.items.items) |*def| def.fx.wire(node, opts.theme);
    s.fab_fx.wire(node, opts.theme);
    // the pill/fab shadows paint past the bounds — declare the spill so the
    // paint/damage rect contract covers them
    node.damage_overflow = .{ .left = shadow_spill, .top = shadow_spill, .right = shadow_spill, .bottom = shadow_spill };
    // Per-slot virtual a11y children — VoiceOver reads/activates each
    // action (a separator per divider, a trailing button for the FAB), not
    // just an opaque group. The borrowed slice is stable (the lists never
    // re-alloc after init).
    for (s.items.items) |*def| {
        s.sem_children.append(.{
            .role = if (def.divider) .separator else .button,
            .label = def.label,
            .disabled = def.divider or !def.enabled,
            .actions = if (!def.divider and def.enabled) ui.semantics.Actions.initOne(.activate) else .{},
        }) catch @panic("klaxon: out of memory");
    }
    if (hasFab(s)) {
        s.sem_children.append(.{
            .role = .button,
            .label = s.fab_label,
            .actions = ui.semantics.Actions.initOne(.activate),
        }) catch @panic("klaxon: out of memory");
    }
    toolbarLocaleCb(node); // Phase 2c — the same path resolves the labels
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = toolbarLocaleCb, .userdata = node });
    return node;
}

// --- tests ---

fn pressCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "toolbar: measures the pill (8dp padding, adjacent 48dp cells); 64dp tall" {
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{ .{ .icon = .search }, .{ .icon = .plus }, .{ .divider = true }, .{ .icon = .star } }, .{});
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    // 8 + 48 + 48 + 1 + 48 + 8 = 161 (cells touch — the upstream Row has no spacing)
    try std.testing.expectApproxEqAbs(@as(f32, 2 * h_pad + 3 * theme_mod.light.platform.hit_target_min + divider_w), sz.w, 0.001);
    try std.testing.expectEqual(bar_height, sz.h);
    // the FAB sits BESIDE the pill: +8 gap + 56 (FabBaseline), outer height 80
    const f = try toolbar(a, &.{.{ .icon = .plus }}, .{ .fab_icon = .check });
    defer f.deinit();
    const szf = f.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(@as(f32, 2 * h_pad + theme_mod.light.platform.hit_target_min + toolbar_fab_gap + fab_min), szf.w, 0.001);
    try std.testing.expectEqual(bar_outer_height, szf.h);
    // an empty toolbar is just the padding
    const e = try toolbar(a, &.{}, .{});
    defer e.deinit();
    const sze = e.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(@as(f32, 2 * h_pad), sze.w);
    try std.testing.expectEqual(bar_height, sze.h);
}

test "toolbar: a click fires the item's on_press; disabled slots and dividers don't" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var hit_a: u32 = 0;
    var hit_b: u32 = 0;
    var fab_hits: u32 = 0;
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{
        .{ .icon = .search, .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &hit_a } },
        .{ .icon = .plus, .enabled = false, .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &hit_b } },
        .{ .divider = true },
        .{ .icon = .star, .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &hit_b } },
    }, .{ .fab_icon = .check, .on_fab_press = .{ .fn_ptr = pressCounterCb, .userdata = &fab_hits } });
    defer n.deinit();
    // bar content = 8 + 48+48+1+48 + 8 = 161; + 8 gap + 56 FAB = 225 x 80
    n.layout(.{ .x = 0, .y = 0, .w = 225, .h = 80 });
    const down_up = struct {
        fn f(nn: *Node, x: f32) void {
            _ = nn.vtable.on_pointer.?(nn, .{ .phase = .down, .x = x, .y = 40, .raw_x = x, .raw_y = 40 });
            _ = nn.vtable.on_pointer.?(nn, .{ .phase = .up, .x = x, .y = 40, .raw_x = x, .raw_y = 40 });
        }
    }.f;
    down_up(n, 8 + 24); // item 0 (cell at bar.x+8 = 8..56)
    try std.testing.expectEqual(@as(u32, 1), hit_a);
    try std.testing.expectEqual(@as(i32, 0), stateOf(n).active); // the press moves the active slot
    // the disabled item (cell at x = 56..104) doesn't press — its down is unclaimed
    try std.testing.expect(!n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 56 + 24, .y = 40, .raw_x = 56 + 24, .raw_y = 40 }));
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 56 + 24, .y = 40, .raw_x = 56 + 24, .raw_y = 40 });
    try std.testing.expectEqual(@as(u32, 0), hit_b);
    // the divider column (x = 104) is inert too
    try std.testing.expect(!n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 104, .y = 40, .raw_x = 104, .raw_y = 40 }));
    try std.testing.expectEqual(@as(u32, 0), hit_b);
    down_up(n, 105 + 24); // item 3 (cell 105..153)
    try std.testing.expectEqual(@as(u32, 1), hit_b);
    // the beside-FAB (x = 225-56 = 169..225) fires on_fab_press
    down_up(n, 169 + 28);
    try std.testing.expectEqual(@as(u32, 1), fab_hits);
    try std.testing.expectEqual(@as(i32, 4), stateOf(n).active);
    // the 8dp gap between the pill end (161) and the FAB (169) hits nothing
    try std.testing.expectEqual(@as(i32, -1), slotAt(stateOf(n), n.bounds, 165, 40));
}

test "toolbar: left/right move the active slot (skipping disabled + dividers, wrapping); Enter activates" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var hits: u32 = 0;
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{
        .{ .icon = .search, .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &hits } },
        .{ .icon = .plus, .enabled = false },
        .{ .divider = true },
        .{ .icon = .star, .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &hits } },
    }, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 161, .h = 64 });
    input.requestFocus(n);
    try std.testing.expectEqual(@as(i32, 0), stateOf(n).active); // the first action is active
    // right skips the disabled item AND the divider to the last action
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .right });
    try std.testing.expectEqual(@as(i32, 3), stateOf(n).active);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .right }); // wraps
    try std.testing.expectEqual(@as(i32, 0), stateOf(n).active);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .left }); // wraps back
    try std.testing.expectEqual(@as(i32, 3), stateOf(n).active);
    // Enter activates the active item
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 1), hits);
    // up/down are NOT claimed (they bubble to scrollables)
    try std.testing.expect(!n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .up }));
}

test "toolbar: semantics — a focusable group with virtual button children, a separator, the FAB" {
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{
        .{ .icon = .search, .a11y_label = "Search" },
        .{ .divider = true },
        .{ .icon = .star, .enabled = false },
    }, .{ .fab_icon = .check, .fab_a11y_label = "Done" });
    defer n.deinit();
    // intrinsic: bar content 8+48+1+48+8 = 113; +8 gap +56 FAB = 177 x 80
    n.layout(.{ .x = 0, .y = 0, .w = 177, .h = 80 });
    const sem = n.semantics.?;
    try std.testing.expectEqual(ui.semantics.Role.group, sem.role);
    try std.testing.expect(sem.focusable);
    try std.testing.expectEqualStrings("Toolbar", sem.label);
    // [button, separator, disabled button, FAB button]
    try std.testing.expectEqual(@as(usize, 4), sem.children.len);
    try std.testing.expectEqual(ui.semantics.Role.button, sem.children[0].role);
    try std.testing.expectEqualStrings("Search", sem.children[0].label);
    try std.testing.expect(sem.children[0].actions.contains(.activate));
    try std.testing.expectEqual(ui.semantics.Role.separator, sem.children[1].role);
    try std.testing.expectEqual(ui.semantics.Role.button, sem.children[2].role);
    try std.testing.expect(sem.children[2].disabled);
    try std.testing.expectEqualStrings("star", sem.children[2].label); // @tagName fallback
    try std.testing.expectEqual(ui.semantics.Role.button, sem.children[3].role);
    try std.testing.expectEqualStrings("Done", sem.children[3].label);
    // child_bounds in node-local space: item 0's cell at bar.x+8 = 8;
    // the FAB slot pinned at the end edge (177-56 = 121), 56 wide expanded.
    const r0 = sem.child_bounds.?(n, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 8), r0.x, 0.001);
    const rf = sem.child_bounds.?(n, 3);
    try std.testing.expectEqual(fab_min, rf.w);
    try std.testing.expectApproxEqAbs(@as(f32, 177 - fab_min), rf.x, 0.001);
}

test "toolbar: the 48dp a11y floor is the hit target when the pill is constrained short" {
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{.{ .icon = .plus }}, .{});
    defer n.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 80, .h = 40 }); // constrained below 48
    const hb = n.vtable.hit_bounds.?(n);
    try std.testing.expectEqual(@as(f32, 48), hb.h);
    try std.testing.expectEqual(@as(f32, 10 - 4), hb.y); // centered on the 40dp bounds
}

test "golden: the pill paints SurfaceContainer + on_surface_variant icons; the divider column is outline_variant" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{ .{ .icon = .search }, .{ .divider = true }, .{ .icon = .star } }, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 96);
    defer r.deinit();
    // intrinsic: 8 + 48+1+48 + 8 = 113 x 64
    n.layout(.{ .x = 20, .y = 20, .w = 113, .h = 64 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the pill fill inside cell 1's padding (star icon sits at x = 88..112)
    try std.testing.expectEqual(t.colors.surface_container, f.pixelAt(118, 52));
    // the first cell's icon ink (the 24dp box at x = 20+8+12 = 40..64)
    try std.testing.expect(f.countColorIn(.{ .x = 40, .y = 40, .w = 24, .h = 24 }, t.colors.on_surface_variant) > 0);
    // the divider column: 1dp of outline_variant at x = 20+8+48 = 76, y = 40..64
    try std.testing.expectEqual(t.colors.outline_variant, f.pixelAt(76, 52));
    try std.testing.expectEqual(t.colors.outline_variant, f.pixelAt(76, 41));
    try std.testing.expectEqual(t.colors.outline_variant, f.pixelAt(76, 63));
    try std.testing.expectEqual(t.colors.surface_container, f.pixelAt(76, 38)); // above the line
    // the pill's full-rounded corner (r = 32): the corner box has no container
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(.{ .x = 20, .y = 20, .w = 8, .h = 8 }, t.colors.surface_container));
}

test "golden: a pressed item's ripple inks the on-color circle over the container" {
    var tl = ui.anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    ui.anim.setCurrent(&tl);
    defer ui.anim.setCurrent(null);
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{ .{ .icon = .search }, .{ .icon = .star } }, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 96);
    defer r.deinit();
    n.layout(.{ .x = 20, .y = 20, .w = 112, .h = 64 }); // 8 + 96 + 8
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 52, .y = 52, .raw_x = 52, .raw_y = 52 }); // time_ms 0 = the clock's now
    tl.tick(300); // past fadeIn (75ms) + the 225ms radius expansion
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // upstream's pressed state is the ripple ink (Ripple.kt), not a static
    // layer: fully open it's on_surface_variant @ pressed over the
    // container, clipped to the cell's circle — (32,52) is inside cell 0's
    // circle (center 52, r = 24), clear of the icon ink
    const ink = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface_variant, t.state.pressed), t.colors.surface_container);
    try golden.expectPixelApprox(f, 32, 52, ink);
    // the unpressed second cell still shows the bare container (past the
    // icon's ink box at x = 88..112)
    try std.testing.expectEqual(t.colors.surface_container, f.pixelAt(118, 52));
}

test "golden: the vibrant variant paints PrimaryContainer + on_primary_container content" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{ .{ .icon = .search }, .{ .icon = .star, .enabled = false } }, .{ .theme = t, .vibrant = true });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 96);
    defer r.deinit();
    n.layout(.{ .x = 20, .y = 20, .w = 112, .h = 64 }); // 8 + 96 + 8
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // upstream vibrant = PrimaryContainer / OnPrimaryContainer (cell 1's
    // padding — the icon's ink box is x = 88..112)
    try std.testing.expectEqual(t.colors.primary_container, f.pixelAt(118, 52));
    try std.testing.expect(f.countColorIn(.{ .x = 40, .y = 40, .w = 24, .h = 24 }, t.colors.on_primary_container) > 0);
    // the disabled icon: on_surface @ 0.38 over the primary_container pill
    const dis = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), t.colors.primary_container);
    try std.testing.expect(f.countColorApproxIn(.{ .x = 88, .y = 40, .w = 24, .h = 24 }, dis) > 0);
}

test "golden: the beside-FAB paints a PrimaryContainer squircle + on_primary_container icon at the end" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{.{ .icon = .search }}, .{ .theme = t, .fab_icon = .check });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 96);
    defer r.deinit();
    // bar content = 8+48+8 = 64; +8 gap +56 FAB = 128 x 80
    n.layout(.{ .x = 20, .y = 8, .w = 128, .h = 80 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the FAB: end edge at 20+128 = 148 → x = 92..148, y = 8+12 = 20..76
    // (probe beside the icon — the glyph's AA edges bleed faint ink nearby)
    try std.testing.expectEqual(t.colors.primary_container, f.pixelAt(96, 60)); // mid-height start edge
    try std.testing.expectEqual(t.colors.primary_container, f.pixelAt(144, 60)); // near the end edge
    try std.testing.expect(f.countColorIn(.{ .x = 108, .y = 48, .w = 24, .h = 24 }, t.colors.on_primary_container) > 0);
    // the FAB's squircle corner (16dp radius): the deep corner pixels stay
    // background (the r-16 arc doesn't reach the corner 4px)
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(.{ .x = 92, .y = 20, .w = 4, .h = 4 }, t.colors.primary_container));
    // the pill is a separate surface, 8dp away (gap at x = 84..92)
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(.{ .x = 85, .y = 40, .w = 6, .h = 20 }, t.colors.surface_container));
    try std.testing.expectEqual(t.colors.surface_container, f.pixelAt(82, 48));
}

test "toolbar: collapsing shrinks the bar toward the FAB and grows it 56→80" {
    const a = std.testing.allocator;
    const expanded = try ui.state.Signal(bool).init(a, true);
    defer expanded.deinit();
    const n = try toolbar(a, &.{ .{ .icon = .search }, .{ .icon = .star } }, .{ .fab_icon = .check, .expanded = expanded });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 176, .h = 80 }); // bar 112 + 8 + 56
    const s = stateOf(n);
    // expanded: bar at full 112, FAB at 56
    try std.testing.expectApproxEqAbs(@as(f32, 112), barRectLtr(s, n.bounds).w, 0.001);
    try std.testing.expectEqual(fab_min, fabRectLtr(s, n.bounds).w);
    // collapse (no timeline → snap): the bar vanishes, the FAB is 80 and
    // its end edge stays pinned (x = 176-80 = 96)
    expanded.set(false);
    try std.testing.expectEqual(@as(f32, 0), s.expand_progress);
    try std.testing.expectEqual(@as(f32, 0), barRectLtr(s, n.bounds).w);
    const fr = fabRectLtr(s, n.bounds);
    try std.testing.expectEqual(fab_max, fr.w);
    try std.testing.expectApproxEqAbs(@as(f32, 176 - fab_max), fr.x, 0.001);
    // a collapsed bar's item slot does not hit (outside the 0-width bar)
    try std.testing.expectEqual(@as(i32, -1), slotAt(s, n.bounds, 32, 40));
    try std.testing.expect(slotAt(s, n.bounds, 120, 40) >= 0); // the FAB still hits
    // re-expand snaps back
    expanded.set(true);
    try std.testing.expectEqual(@as(f32, 1), s.expand_progress);
}

test "toolbar: RTL mirrors the row (the first item sits at the end side, the FAB at the start)" {
    const a = std.testing.allocator;
    const i18n = try ui.i18n.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var hits: u32 = 0;
    const n = try toolbar(a, &.{
        .{ .icon = .search, .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &hits } },
        .{ .icon = .star },
    }, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 112, .h = 64 }); // 8 + 96 + 8
    // LTR item 0 cell [8, 56) mirrors to [112-56, 112-8) = [56, 104)
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 80, .y = 32, .raw_x = 80, .raw_y = 32 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 80, .y = 32, .raw_x = 80, .raw_y = 32 });
    try std.testing.expectEqual(@as(u32, 1), hits); // the right-side cell is item 0
    // left moves forward (toward the visual left = increasing index in RTL)
    input.requestFocus(n);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .left });
    try std.testing.expectEqual(@as(i32, 1), stateOf(n).active);
}

test "toolbar: i18n — the group + defaulted FAB labels localize and re-resolve" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Toolbar\": \"Barra de herramientas\", \"Action\": \"Acción\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const n = try toolbar(a, &.{.{ .icon = .search }}, .{ .fab_icon = .check });
    defer n.deinit();
    const sem = n.semantics.?;
    try std.testing.expectEqualStrings("Barra de herramientas", sem.label);
    // the FAB is the last virtual child — its defaulted name localized
    try std.testing.expectEqualStrings("Acción", sem.children[sem.children.len - 1].label);
    try i18n.setLocale("en");
    const sem2 = n.semantics.?;
    try std.testing.expectEqualStrings("Toolbar", sem2.label);
    try std.testing.expectEqualStrings("Action", sem2.children[sem2.children.len - 1].label);
}
