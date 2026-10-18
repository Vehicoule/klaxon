// Tabs widget (Phase 2d.1, M3E batch 1) — primary top tab row.
//
// Ported from .ref/material3/TabRow.kt (`TabRowImpl` measure policy,
// `TabIndicatorOffsetNode`, `TabRowDefaults.PrimaryIndicator`) and
// .ref/material3/Tab.kt (`TabImpl` placement, `HorizontalTextPadding`) with
// tokens from .ref/material3/tokens/PrimaryNavigationTabTokens.kt:
//   - equal tab cells: tabWidth = rowWidth / tabCount, content centered,
//   - row height = the tallest tab (48 label-only / 72 icon+label via the
//     `height` option — PrimaryNavigationTabTokens.ContainerHeight /
//     IconAndLabelTextContainerHeight),
//   - divider: 1dp HorizontalDivider (outline_variant), at the bottom,
//   - active indicator: the PRIMARY pill — 3dp tall, RoundedCornerShape(3dp),
//     primary, anchored at the selected cell's LEADING edge with the tab's
//     CONTENT width (`TabPosition.left` + `contentWidth`, minimum 24dp),
//     sitting on the divider,
//   - indication = a bounded ripple in the SELECTED content color (primary),
//     on any tab (Tab.kt:166 `ripple(bounded = true, color =
//     selectedContentColor)` on the whole tab's selectable): each cell gets
//     a per-item Tracker + animated StateLayer + Ripples set; presses spawn
//     the ink at the press point (bounded → clipped to the cell rect),
//     hover/focus ride the layer, Enter/Space presses at the cell's center.
//
// `TabPosition.contentWidth` upstream = intrinsic width minus the `Tab`
// composable's own 16dp horizontal padding ×2. Klaxon tab children ARE the
// bare content — their measured width already excludes padding — so the
// content width is `min(childW, tabW)` with the same 24dp floor.
//
// The indicator glides between tabs with the theme's default spring —
// `TabIndicatorOffsetNode` animates the offset toward `position.left` and the
// width toward `contentWidth`; RTL renders the mirrored offset (`-left` → the
// pill hugs the cell's right edge). Without a timeline it snaps. Selection is
// a Signal(usize) owned by the app. Items get a `.tab` semantic (checked
// follows the selection; Enter/Space activates, arrows move the selection).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const i18n_mod = @import("../ui/i18n.zig");
const anim = ui.anim;
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

/// PrimaryNavigationTabTokens: the indicator's minimum content width 24dp,
/// 3dp height, 3dp corner radius; the divider is a 1dp HorizontalDivider.
const indicator_min_w: f32 = 24; // "Enforce minimum touch target of 24.dp"
const indicator_radius: f32 = 3; // ActiveIndicatorShape RoundedCornerShape(3dp)

pub const TabsOptions = struct {
    theme: Theme = theme_mod.light,
    /// Row height floor — the tab's declared height upstream: TabBaselineLayout
    /// picks SmallTabHeight = PrimaryNavigationTabTokens.ContainerHeight 48
    /// (label-only OR icon-only) / LargeTabHeight 72 (icon+label, the literal
    /// in Tab.kt — not the unused 64dp IconAndLabelTextContainerHeight token);
    /// taller children grow it. Label-only rows pass 48.
    height: f32 = 72,
    indicator_height: f32 = 3, // ActiveIndicatorHeight
    divider_height: f32 = 1, // bottom divider (inside the container height)
    /// The semantics label — null resolves the localized "Tabs"
    /// (an app string is verbatim).
    label: ?[]const u8 = null,
};

/// Per-cell indication state (the upstream per-tab MutableInteractionSource
/// + the selectable's bounded ripple). Heap-allocated: the StateLayer's
/// timeline channel takes `l`'s address, so the struct must never move
/// once wired.
const ItemFx = struct {
    inter: ui.interactions.Tracker = .{},
    layer: ui.state_layer.StateLayer = .{},
    ripples: ui.ripple.Ripples = .{},
    press_id: u32 = 0, // the live press's tracker id (0 = none)

    fn create(allocator: std.mem.Allocator, n: *Node, t: Theme) !*ItemFx {
        const fx = try allocator.create(ItemFx);
        fx.* = .{};
        fx.inter.node = n;
        fx.layer.node = n;
        fx.layer.alphas = .{ .hover = t.state.hover, .focus = t.state.focus, .pressed = t.state.pressed, .drag = t.state.drag };
        fx.ripples = .{ .bounded = true, .node = n, .pressed_alpha = t.state.pressed };
        // Tab.kt:166 — the ripple's explicit color is selectedContentColor
        // (= the primary tab's Active*ContentColor = primary); the layer
        // gets the same color per-paint.
        fx.ripples.color = t.colors.primary;
        return fx;
    }

    fn destroy(fx: *ItemFx, allocator: std.mem.Allocator) void {
        fx.layer.deinit(); // in-flight tween userdata = `l`
        fx.ripples.deinit(); // the live ticker userdata = `r`
        allocator.destroy(fx);
    }
};

const TabsState = struct {
    sig: *ui.state.Signal(usize),
    opts: TabsOptions,
    hovered: ?usize = null,
    pressed: ?usize = null,
    /// Per-tab layout cache: the cell rects (hit-testing) and the content
    /// sizes (centering).
    cells: std.array_list.Managed(Rect),
    content_sizes: std.array_list.Managed(Size),
    /// Per-cell indication (parallel to `cells` — same count/order).
    fx: std.array_list.Managed(*ItemFx),
    semantics_attached: bool = false,
    // Animated indicator (x/w of the active tab's indicator).
    indicator_x: f32 = 0,
    indicator_w: f32 = 0,
    anim_to_x: f32 = 0, // current animation target (identity of the target)
    anim_to_w: f32 = 0,
    laid_out: bool = false,
    anim_channel: u8 = 0, // channel marker (stable address): one indicator animation
    i18n: ?*i18n_mod.I18n = null,
};

fn stateOf(n: *Node) *TabsState {
    return @ptrCast(@alignCast(n.state.?));
}

/// The tab (child index) under a window-space point, or null.
fn tabAtPoint(n: *Node, s: *TabsState, raw_x: f32, raw_y: f32) ?usize {
    const p = Node.mapPointToParentSpace(n, raw_x, raw_y);
    for (s.cells.items, 0..) |cell, i| {
        if (cell.contains(p.x, p.y)) return i;
    }
    return null;
}

/// Attach (or update) the `.tab` semantic on every tab — the label/hint of
/// an existing descriptor is preserved.
fn syncTabSemantics(n: *Node, s: *TabsState) void {
    const sel = s.sig.peek();
    for (n.children.items, 0..) |child, i| {
        const checked = i == sel;
        if (child.semantics) |sem| {
            sem.role = .tab;
            sem.focusable = true;
            sem.checked = checked;
            sem.actions = ui.semantics.Actions.initOne(.activate);
        } else {
            ui.semantics.attach(child, .{ .role = .tab, .focusable = true, .checked = checked, .actions = ui.semantics.Actions.initOne(.activate) });
        }
    }
}

/// The child index containing the focused node (keyboard activation).
fn focusedTab(n: *Node) ?usize {
    const router = input.current() orelse return null;
    const f = router.focusedNode() orelse return null;
    var cur: ?*Node = f;
    while (cur) |c| : (cur = c.parent) {
        if (c == n) return null;
        for (n.children.items, 0..) |child, i| {
            if (child == c) return i;
        }
    }
    return null;
}

fn indicatorUpdateCb(userdata: ?*anyopaque, v: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.indicator_x = v[0];
    s.indicator_w = v[1];
    n.markDirty();
}

/// Glide the indicator to a new target (theme default spring); without a
/// timeline the indicator snaps.
fn animateIndicator(n: *Node, s: *TabsState, to_x: f32, to_w: f32) void {
    s.anim_to_x = to_x;
    s.anim_to_w = to_w;
    const from: anim.Vec4 = .{ s.indicator_x, s.indicator_w, 0, 0 };
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.springAnim(from, .{ to_x, to_w, 0, 0 }, s.opts.theme.motion.springs.default_spring, .{ 0, 0, 0, 0 }),
            .from = from,
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = indicatorUpdateCb, .userdata = n },
        });
    } else {
        s.indicator_x = to_x;
        s.indicator_w = to_w;
    }
}

fn tabsMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const count: f32 = @floatFromInt(n.children.items.len);
    const w = if (std.math.isFinite(c.max_w)) c.max_w else count * 90;
    // TabRowImpl: the row height is the tallest tab's intrinsic height (each
    // Tab declares 48/72). `opts.height` plays the declared-height role
    // since Klaxon children are bare content; a taller child still grows it.
    const tab_w = if (count > 0) w / count else w;
    var h: f32 = s.opts.height;
    for (n.children.items) |child| {
        h = @max(h, child.measure(.{ .max_w = tab_w }).h);
    }
    return c.constrain(.{ .w = w, .h = h });
}

fn tabsLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    const count = n.children.items.len;
    // The indication set tracks the child count: removed tabs' machinery
    // dies with them (upstream's interaction set dies with the tab).
    while (s.fx.items.len > count) {
        const fx = s.fx.pop().?;
        fx.destroy(n.allocator);
    }
    while (s.fx.items.len < count) {
        s.fx.append(ItemFx.create(n.allocator, n, s.opts.theme) catch @panic("klaxon: out of memory")) catch @panic("klaxon: out of memory");
    }
    // The indices die with the shrunk tabs (the interactions inside the
    // removed fx are already gone with it).
    if (s.hovered != null and s.hovered.? >= count) s.hovered = null;
    if (s.pressed != null and s.pressed.? >= count) s.pressed = null;
    if (count == 0) return;
    const tab_w = bounds.w / @as(f32, @floatFromInt(count));
    if (s.cells.items.len != count) {
        s.cells.clearRetainingCapacity();
        s.content_sizes.clearRetainingCapacity();
        for (0..count) |_| {
            s.cells.append(.{}) catch @panic("klaxon: out of memory");
            s.content_sizes.append(.{}) catch @panic("klaxon: out of memory");
        }
    }
    const loose: Constraints = .{ .max_w = tab_w, .max_h = bounds.h };
    const rtl = ui.i18n.direction() == .rtl;
    for (n.children.items, 0..) |child, i| {
        const cs = child.measure(loose);
        // RTL: cell 0 is the rightmost — index order mirrors visually.
        const x = if (rtl) bounds.x + bounds.w - @as(f32, @floatFromInt(i + 1)) * tab_w else bounds.x + @as(f32, @floatFromInt(i)) * tab_w;
        s.cells.items[i] = .{ .x = x, .y = bounds.y, .w = tab_w, .h = bounds.h };
        s.content_sizes.items[i] = cs;
        child.layout(.{
            .x = x + (tab_w - cs.w) / 2,
            .y = bounds.y + (bounds.h - cs.h) / 2,
            .w = cs.w,
            .h = cs.h,
        });
    }
    if (!s.semantics_attached) {
        s.semantics_attached = true;
        syncTabSemantics(n, s);
    }
    // TabIndicatorOffsetNode: the pill animates its OFFSET toward
    // `position.left` (the cell's leading edge) and its WIDTH toward
    // `position.contentWidth` — min(intrinsic, tabWidth) minus the Tab
    // composable's padding ×2, floored at 24dp. Klaxon children are bare
    // content (no embedded padding): contentWidth = min(childW, tabW).
    const sel = @min(s.sig.peek(), count - 1);
    const cell = s.cells.items[sel];
    const cs = s.content_sizes.items[sel];
    const target_w = @max(indicator_min_w, @min(cs.w, cell.w));
    // Leading-edge anchor: LTR at the cell's left; RTL mirrors to the cell's
    // right edge (upstream negates the offset under `placeRelative`).
    const target_x = if (rtl) cell.x + cell.w - target_w else cell.x;
    if (!s.laid_out) {
        // First layout: the indicator appears directly under the selection.
        s.indicator_x = target_x;
        s.indicator_w = target_w;
        s.anim_to_x = target_x;
        s.anim_to_w = target_w;
        s.laid_out = true;
    } else if (target_x != s.anim_to_x or target_w != s.anim_to_w) {
        animateIndicator(n, s, target_x, target_w);
    }
}

fn tabsPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, t.colors.surface);
    // The indication (Tab.kt:166): the animated state layer + the bounded
    // ink in the SELECTED content color (primary) — the layer is the same
    // src-over result the old stateLayer() pre-blend produced. Painted in
    // the row's own pass: under the tab content, like upstream's
    // background-level indication modifier.
    for (s.cells.items, 0..) |cell, i| {
        const fx = s.fx.items[i];
        // The tab's focus is its child node's (the .tab) — polled, there
        // is no focus-gained hook.
        fx.inter.setFocused(input.isFocused(n.children.items[i]));
        fx.layer.sync(&fx.inter, t.colors.primary);
        if (fx.layer.paintColor()) |lc| {
            ui.paint.fillRect(ctx, cell.x, cell.y, cell.w, cell.h, lc);
        }
        fx.ripples.paintIn(ctx, cell, .rect);
    }
    // HorizontalDivider: 1dp outline_variant, at the bottom of the row.
    const dh = s.opts.divider_height;
    ui.paint.fillRect(ctx, b.x, b.y + b.h - dh, b.w, dh, t.colors.outline_variant);
    // PrimaryIndicator: a pill at the animated leading-edge offset — 3dp tall,
    // ActiveIndicatorShape (radius 3 → capsule at 3dp), on the divider.
    const ih = s.opts.indicator_height;
    ui.paint.fillRRect(ctx, s.indicator_x, b.y + b.h - dh - ih, s.indicator_w, ih, @min(indicator_radius, ih / 2), t.colors.primary);
}

/// End a cell's live press (release = up, cancel = pointer-off/outside) —
/// the tracker entry and its ripple pair on `press_id`.
fn tabsEndPress(s: *TabsState, i: usize, now_ms: u64, cancel: bool) void {
    const fx = s.fx.items[i];
    if (fx.press_id == 0) return;
    if (cancel) fx.inter.cancel(fx.press_id) else fx.inter.release(fx.press_id);
    fx.ripples.release(fx.press_id, now_ms);
    fx.press_id = 0;
}

/// Move the hover interaction to a new cell (null = none).
fn tabsSetHover(s: *TabsState, h: ?usize) void {
    if (h == s.hovered) return;
    if (s.hovered) |old| s.fx.items[old].inter.endHover();
    s.hovered = h;
    if (s.hovered) |new| _ = s.fx.items[new].inter.hoverEnter();
}

fn tabsOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    switch (ev.phase) {
        .down => {
            if (tabAtPoint(n, s, ev.raw_x, ev.raw_y)) |i| {
                const fx = s.fx.items[i];
                // a second pointer supersedes the live press
                if (fx.press_id != 0) tabsEndPress(s, i, ev.time_ms, true);
                fx.press_id = fx.inter.pressDown(ev.x, ev.y);
                fx.ripples.spawn(fx.press_id, ev.x, ev.y, ev.time_ms);
                s.pressed = i;
                return true;
            }
            return false;
        },
        .up => {
            const up_tab = tabAtPoint(n, s, ev.raw_x, ev.raw_y);
            const was = s.pressed;
            s.pressed = null;
            if (was != null) {
                tabsEndPress(s, was.?, ev.time_ms, false);
                if (up_tab != null and up_tab.? == was.?) {
                    s.sig.set(up_tab.?);
                    n.markLayoutDirty(); // the indicator target moved
                }
                return true; // the press is consumed even when released outside
            }
            return false;
        },
        .enter => {
            tabsSetHover(s, tabAtPoint(n, s, ev.raw_x, ev.raw_y));
            return true;
        },
        .leave => {
            tabsSetHover(s, null);
            return true;
        },
        .move => {
            // upstream selectable cancels the press when the pointer leaves
            // the tab — the move stays claimed while pressed
            if (s.pressed) |p| {
                if (tabAtPoint(n, s, ev.raw_x, ev.raw_y) != p) {
                    tabsEndPress(s, p, ev.time_ms, true);
                    s.pressed = null;
                }
                return true;
            }
            return false;
        },
        .outside_down => {
            if (s.pressed) |p| {
                tabsEndPress(s, p, ev.time_ms, true);
                s.pressed = null;
                return true; // it owned the interaction
            }
            return false;
        },
        // Uncaptured hover over an unchanged deepest node: track the hovered
        // cell (the enter/leave pair only fires when the node changes).
        .hover_move => {
            tabsSetHover(s, tabAtPoint(n, s, ev.raw_x, ev.raw_y));
            return true;
        },
    }
}

fn tabsOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            if (focusedTab(n)) |i| {
                // A key press lands at the cell's center (upstream's
                // keyboard press position = the component center); the
                // ripple releases immediately but still expands + fades.
                if (i < s.fx.items.len and i < s.cells.items.len) {
                    const fx = s.fx.items[i];
                    const cell = s.cells.items[i];
                    const cx = cell.x + cell.w / 2;
                    const cy = cell.y + cell.h / 2;
                    const pid = fx.inter.pressDown(cx, cy);
                    fx.ripples.spawn(pid, cx, cy, 0);
                    fx.inter.release(pid);
                    fx.ripples.release(pid, 0);
                }
                s.sig.set(i);
                n.markLayoutDirty();
                return true;
            }
            return false;
        },
        .left, .right => {
            const sel = s.sig.peek();
            // Arrow direction mirrors in RTL (cells are laid out mirrored).
            const fwd: i32 = if (ev.key == .right) 1 else -1;
            const step: i32 = if (ui.i18n.direction() == .rtl) -fwd else fwd;
            const next_i = @as(i32, @intCast(sel)) + step;
            if (next_i >= 0 and next_i < @as(i32, @intCast(n.children.items.len))) {
                const next: usize = @intCast(next_i);
                s.sig.set(next);
                n.markLayoutDirty();
                input.requestFocus(n.children.items[next]); // selection-follows-focus, both ways
                return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Selection changed: sync the tabs' checked state, repaint, announce.
fn tabsSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.semantics_attached) syncTabSemantics(n, s);
    n.markDirty();
    n.markLayoutDirty(); // the indicator target moved
    ui.semantics.notifyControlChanged(n); // a11y: the selection changed
}

fn tabsDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel)); // the update cb points at this node
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = tabsSyncCb, .userdata = n } });
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = tabsLocaleCb, .userdata = n });
    input.releaseNode(n);
    for (s.fx.items) |fx| fx.destroy(n.allocator);
    s.fx.deinit();
    s.cells.deinit();
    s.content_sizes.deinit();
    n.allocator.destroy(s);
}

/// The group label is tr()-resolved — the locale callback re-attaches in
/// the new locale (the tab children carry app labels, verbatim).
fn tabsLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    ui.semantics.attach(n, .{ .role = .group, .label = s.opts.label orelse i18n_mod.tr("Tabs") });
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

const tabs_vtable = ui.node.VTable{
    .measure = tabsMeasure,
    .layout = tabsLayout,
    .paint = tabsPaint,
    .deinit = tabsDeinit,
    .on_pointer = tabsOnPointer,
    .on_key = tabsOnKey,
};

/// Primary tab row (M3E). Children = the tabs (passive icon+label content);
/// the row owns selection, the gliding indicator, state layers and the
/// divider. `selected` is app-owned; the row subscribes and unsubscribes at
/// deinit.
pub fn tabs(allocator: std.mem.Allocator, selected: *ui.state.Signal(usize), opts: TabsOptions) !*Node {
    const node = try Node.create(allocator, &tabs_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(TabsState);
    errdefer allocator.destroy(s);
    s.* = .{ .sig = selected, .opts = opts, .cells = .init(allocator), .content_sizes = .init(allocator), .fx = .init(allocator) };
    node.state = s;
    tabsLocaleCb(node); // Phase 2c — the same path resolves the label
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = tabsLocaleCb, .userdata = node });
    selected.subscribe(.{ .callback = .{ .fn_ptr = tabsSyncCb, .userdata = node } });
    return node;
}

// --- tests ---

const text_w = @import("text.zig");

fn testTab(a: std.mem.Allocator, label: []const u8) !*Node {
    return text_w.text(a, label, .{ .size = 14, .color = 0x000000FF });
}

test "tabs: measure fills the width and reports the M3E height" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const row = try tabs(std.testing.allocator, sel, .{});
    defer row.deinit();
    row.add(try testTab(std.testing.allocator, "One"));
    const m = row.measure(.{ .max_w = 480, .max_h = 600 });
    try std.testing.expectEqual(@as(f32, 480), m.w);
    try std.testing.expectEqual(@as(f32, 72), m.h);
}

test "tabs: layout splits the width equally; the indicator snaps without a timeline" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const row = try tabs(std.testing.allocator, sel, .{});
    defer row.deinit();
    row.add(try testTab(std.testing.allocator, "One"));
    row.add(try testTab(std.testing.allocator, "Two"));
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    const s = stateOf(row);
    try std.testing.expectEqual(@as(usize, 2), s.cells.items.len);
    try std.testing.expectEqual(@as(f32, 0), s.cells.items[0].x);
    try std.testing.expectEqual(@as(f32, 200), s.cells.items[0].w);
    try std.testing.expectEqual(@as(f32, 200), s.cells.items[1].x);
    // upstream TabIndicatorOffsetNode: the pill anchors at the selected cell's
    // leading edge with the tab's content width (min(childW, tabW), ≥24)
    const w0 = @max(@as(f32, 24), @min(s.content_sizes.items[0].w, @as(f32, 200)));
    const w1 = @max(@as(f32, 24), @min(s.content_sizes.items[1].w, @as(f32, 200)));
    try std.testing.expectEqual(@as(f32, 0), s.indicator_x);
    try std.testing.expectEqual(w0, s.indicator_w);
    // selection change + relayout: snap (no timeline installed)
    sel.set(1);
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    try std.testing.expectEqual(@as(f32, 200), s.indicator_x);
    try std.testing.expectEqual(w1, s.indicator_w);
}

test "tabs: with a timeline the indicator glides (spring) to the target" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const row = try tabs(std.testing.allocator, sel, .{});
    defer row.deinit();
    row.add(try testTab(std.testing.allocator, "One"));
    row.add(try testTab(std.testing.allocator, "Two"));
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    const s = stateOf(row);
    try std.testing.expectEqual(@as(f32, 0), s.indicator_x);
    sel.set(1);
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 }); // launches the spring
    try std.testing.expect(tl.hasActive());
    tl.tick(0); // lazy start: the value is still `from`
    try std.testing.expectEqual(@as(f32, 0), s.indicator_x);
    tl.tick(50); // mid-flight: strictly between the two targets
    try std.testing.expect(s.indicator_x > 0 and s.indicator_x < 200);
    tl.tick(10_000); // settled: exactly on target — the cell's leading edge
    try std.testing.expectEqual(@as(f32, 200), s.indicator_x);
    const w1 = @max(@as(f32, 24), @min(s.content_sizes.items[1].w, @as(f32, 200)));
    try std.testing.expectEqual(w1, s.indicator_w);
    try std.testing.expect(!tl.hasActive());
}

test "tabs: items get .tab semantics with checked following the selection" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const row = try tabs(std.testing.allocator, sel, .{});
    defer row.deinit();
    row.add(try testTab(std.testing.allocator, "One"));
    row.add(try testTab(std.testing.allocator, "Two"));
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    try std.testing.expect(row.children.items[0].semantics.?.checked.?);
    try std.testing.expect(!row.children.items[1].semantics.?.checked.?);
    sel.set(1);
    try std.testing.expect(!row.children.items[0].semantics.?.checked.?);
    try std.testing.expect(row.children.items[1].semantics.?.checked.?);
}

test "tabs: click selects the tab under the pointer" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const row = try tabs(std.testing.allocator, sel, .{});
    defer row.deinit();
    row.add(try testTab(std.testing.allocator, "One"));
    row.add(try testTab(std.testing.allocator, "Two"));
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    var router = input.InputRouter{};
    router.dispatchPointer(row, .{ .phase = .down, .x = 300, .y = 32 });
    router.dispatchPointer(row, .{ .phase = .up, .x = 300, .y = 32 });
    try std.testing.expectEqual(@as(usize, 1), sel.peek());
}

test "tabs: arrows move the selection AND the focus; hover tracks across cells" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const row = try tabs(std.testing.allocator, sel, .{});
    defer row.deinit();
    const a = try testTab(std.testing.allocator, "One");
    const b = try testTab(std.testing.allocator, "Two");
    row.add(a);
    row.add(b);
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // focus followed the selection: Enter activates the NEW tab
    input.requestFocus(a);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .right }));
    try std.testing.expectEqual(@as(usize, 1), sel.peek());
    try std.testing.expect(router.focusedNode() == b);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .enter }));
    try std.testing.expectEqual(@as(usize, 1), sel.peek());
    // hover_move: y=4 is inside the row but above the centered content —
    // moving between such spots keeps the same deepest node (the row).
    const s = stateOf(row);
    router.dispatchPointer(row, .{ .phase = .move, .x = 50, .y = 4 });
    try std.testing.expectEqual(@as(?usize, 0), s.hovered);
    router.dispatchPointer(row, .{ .phase = .move, .x = 250, .y = 4 });
    try std.testing.expectEqual(@as(?usize, 1), s.hovered);
}

test "golden: tabs paint the surface, the divider and the primary indicator" {
    const t = theme_mod.light;
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const row = try tabs(std.testing.allocator, sel, .{ .theme = t });
    defer row.deinit();
    row.add(try testTab(std.testing.allocator, "One"));
    row.add(try testTab(std.testing.allocator, "Two"));
    var r = try golden.Renderer.init(std.testing.allocator, 400, 64);
    defer r.deinit();
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    r.paint(row, 0x000000FF);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    // container
    try std.testing.expect(f1.countColor(t.colors.surface) > 400 * 64 - 3000);
    // divider: the bottom 1dp row is outline_variant (HorizontalDivider)
    try std.testing.expect(f1.countColorIn(.{ .x = 0, .y = 63, .w = 400, .h = 1 }, t.colors.outline_variant) == 400);
    // content-width pill anchored at tab 0's leading edge only
    try std.testing.expect(f1.countColorIn(.{ .x = 0, .y = 0, .w = 200, .h = 64 }, t.colors.primary) > 40);
    try std.testing.expect(f1.countColorIn(.{ .x = 200, .y = 0, .w = 200, .h = 64 }, t.colors.primary) == 0);
    // select tab 1 (no timeline: snap on relayout)
    sel.set(1);
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    r.paint(row, 0x000000FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expect(f2.countColorIn(.{ .x = 0, .y = 0, .w = 200, .h = 64 }, t.colors.primary) == 0);
    try std.testing.expect(f2.countColorIn(.{ .x = 200, .y = 0, .w = 200, .h = 64 }, t.colors.primary) > 40);
}

test "tabs: i18n — the default label localizes + re-resolves on a locale switch" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Tabs\": \"Pestañas\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const sel = try ui.state.Signal(usize).init(a, 0);
    defer sel.deinit();
    const row = try tabs(a, sel, .{});
    defer row.deinit();
    try std.testing.expectEqualStrings("Pestañas", row.semantics.?.label);
    try i18n.setLocale("en");
    try std.testing.expectEqualStrings("Tabs", row.semantics.?.label);
}
