// Navigation bar widget (Phase 2d.1, M3E batch 1) — bottom navigation bar.
//
// Upstream: .ref/material3/NavigationBar.kt (NavigationBar,
// NavigationBarItem's NavigationBarItemLayout / placeLabelAndIcon /
// placeIcon) + tokens/NavigationBarTokens.kt and
// NavigationBarVerticalItemTokens.kt:
//   - NavigationBarTokens: TallContainerHeight 80 (NavigationBarHeight),
//     ContainerColor SurfaceContainer, ContainerElevation Level0 (flat)
//   - items are a weight(1f) Row with
//     Arrangement.spacedBy(NavigationBarItemHorizontalPadding = 8): equal
//     cells with 8dp gaps between them — the gaps belong to no item
//   - the item layout (placeLabelAndIcon):
//       contentHeight = icon(24) + IndicatorVerticalPadding(4) +
//         NavigationBarIndicatorToLabelPadding(4) + labelH
//       contentVerticalPadding = max((minHeight 80 - contentHeight)/2, 4)
//       icon at contentVerticalPadding; label 8dp below the icon's bottom;
//       the item's layout height = contentHeight + 2*cvp, centered in the
//       cell (the bar's Row does not stretch items vertically)
//   - active indicator: ActiveIndicatorWidth 56 x ActiveIndicatorHeight 32
//     = icon + 2*IndicatorHorizontalPadding(16) x icon + 2*IVP(4),
//     CornerFull, SecondaryContainer, centered on the icon
//   - item ink: active icon OnSecondaryContainer, active label Secondary,
//     inactive both OnSurfaceVariant — destination() supplies the colors
//   - unbounded measure: an item's natural width = icon +
//     2*NavigationBarItemToIconMinimumPadding(44)
//   - state layers + ripple: on_surface over the indicator pill zone —
//     the upstream ripple's LocalContentColor (the bar's contentColor =
//     contentColorFor(SurfaceContainer) = OnSurface)
//
// Indication (NavigationBar.kt:221-228,247-272): the whole item is
// `selectable(interactionSource, indication = null)` — the indication is
// instead a separate indicator-sized Box,
// `.clip(indicatorShape).indication(offsetInteractionSource,
// ripple(focusRingShape = indicatorShape))`: a bounded ripple clipped to
// the 56x32 CornerFull pill, fed by a per-item interactions.Tracker (the
// upstream MappedInteractionSource remaps press coords into the pill —
// free here, since the press position already lands in the pill's own
// coordinate space). Press = the ripple; hover/focus = the animated
// state layer. Enter/Space presses at the pill's center.
//
// Deviations: Klaxon nodes are content-sized, so a generic child's "icon"
// is its content top — the destination() child reproduces the upstream
// icon-first content exactly; icon-only children take the same formula
// (which is still exact, since IVP = 4 in both axes). Compose animates the
// indicator width 0→full on selection; Klaxon paints the final state.
//
// The selection is a Signal(usize) owned by the app; the bar subscribes
// (visual + semantic sync) and unsubscribes at deinit. Items get a `.tab`
// semantic (checked follows the selection; Enter/Space activates, arrows
// move the selection — M3E selection-follows-focus).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const i18n_mod = @import("../ui/i18n.zig");
const icon_w = @import("icon.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

/// NavigationBar.kt / tokens, verbatim:
const item_min_h: f32 = 80; // NavigationBarTokens.TallContainerHeight (NavigationBarHeight)
const indicator_w: f32 = 56; // NavigationBarVerticalItemTokens.ActiveIndicatorWidth = icon + 2*IndicatorHorizontalPadding
const indicator_h: f32 = 32; // NavigationBarVerticalItemTokens.ActiveIndicatorHeight = icon + 2*IndicatorVerticalPadding
const icon_size: f32 = 24; // NavigationBarVerticalItemTokens.IconSize
const ind_h_pad: f32 = (indicator_w - icon_size) / 2; // IndicatorHorizontalPadding = 16
const ind_v_pad: f32 = (indicator_h - icon_size) / 2; // IndicatorVerticalPadding = 4
const ind_to_label: f32 = 4; // NavigationBarIndicatorToLabelPadding
const item_gap: f32 = 8; // NavigationBarItemHorizontalPadding (Row spacedBy)
const item_min_icon_pad: f32 = 44; // NavigationBarItemToIconMinimumPadding

pub const NavBarOptions = struct {
    theme: Theme = theme_mod.light,
    height: f32 = 80, // M3E tall container height
    /// The semantics label — null resolves the localized "Navigation bar"
    /// (an app string is verbatim).
    label: ?[]const u8 = null,
};

/// Per-item indication state (the upstream per-item MutableInteractionSource
/// + the indicator Box's ripple). Heap-allocated: the StateLayer's timeline
/// channel takes `l`'s address, so the struct must never move once wired.
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
        fx.ripples.node = n;
        fx.ripples.color = t.colors.on_surface;
        fx.ripples.pressed_alpha = t.state.pressed;
        return fx;
    }

    fn destroy(fx: *ItemFx, allocator: std.mem.Allocator) void {
        fx.layer.deinit(); // in-flight tween userdata = `l`
        fx.ripples.deinit(); // the live ticker userdata = `r`
        allocator.destroy(fx);
    }
};

const NavBarState = struct {
    sig: *ui.state.Signal(usize),
    opts: NavBarOptions,
    hovered: ?usize = null,
    pressed: ?usize = null,
    /// Per-item layout cache: the cell rects (hit-testing + indicator
    /// centering) and the content sizes (indicator vertical placement).
    cells: std.array_list.Managed(Rect),
    content_sizes: std.array_list.Managed(Size),
    /// Per-item indication (parallel to `cells` — same count/order).
    fx: std.array_list.Managed(*ItemFx),
    semantics_attached: bool = false,
    i18n: ?*i18n_mod.I18n = null,
};

fn stateOf(n: *Node) *NavBarState {
    return @ptrCast(@alignCast(n.state.?));
}

/// The item (child index) under a window-space point, or null.
fn itemAtPoint(n: *Node, s: *NavBarState, raw_x: f32, raw_y: f32) ?usize {
    const p = Node.mapPointToParentSpace(n, raw_x, raw_y);
    for (s.cells.items, 0..) |cell, i| {
        if (cell.contains(p.x, p.y)) return i;
    }
    return null;
}

/// Attach (or update) the `.tab` semantic on every item — the label/hint of
/// an existing descriptor is preserved. Runs once at the first layout, then
/// on every selection change (checked sync).
fn syncItemSemantics(n: *Node, s: *NavBarState) void {
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
fn focusedItem(n: *Node) ?usize {
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

/// placeLabelAndIcon/placeIcon verticals for one item: the item's layout
/// frame is contentHeight + 2*contentVerticalPadding (≥ the item's 80dp
/// defaultMinSize), centered in the cell. Returns the frame's top offset
/// and the contentVerticalPadding — the child's top sits at frame + cvp
/// and the indicator at frame + cvp - IndicatorVerticalPadding.
fn itemVerticals(content_h: f32) struct { frame_h: f32, cvp: f32 } {
    const cvp = @max((item_min_h - content_h) / 2, ind_v_pad);
    return .{ .frame_h = content_h + cvp * 2, .cvp = cvp };
}

fn navBarMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const count: f32 = @floatFromInt(n.children.items.len);
    const gaps = @max(0, count - 1) * item_gap;
    // Unbounded width: an item's natural width is its icon +
    // 2*NavigationBarItemToIconMinimumPadding (upstream ignores the label).
    const w = if (std.math.isFinite(c.max_w)) c.max_w else count * (icon_size + item_min_icon_pad * 2) + gaps;
    // The row is defaultMinSize(minHeight = TallContainerHeight); an item's
    // layout height is max(80, contentH + IVP + IndicatorToLabelPadding +
    // IVP) — a taller item grows the bar.
    var h = s.opts.height;
    const loose: Constraints = .{ .max_w = c.max_w, .max_h = c.max_h };
    for (n.children.items) |child| {
        const cs = child.measure(loose);
        h = @max(h, cs.h + ind_v_pad * 2);
    }
    return c.constrain(.{ .w = w, .h = h });
}

fn navBarLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    const count = n.children.items.len;
    if (s.cells.items.len != count) {
        s.cells.clearRetainingCapacity();
        s.content_sizes.clearRetainingCapacity();
        for (0..count) |_| {
            s.cells.append(.{}) catch @panic("klaxon: out of memory");
            s.content_sizes.append(.{}) catch @panic("klaxon: out of memory");
        }
    }
    // The indication set tracks the child count: removed items' modules
    // die with them (upstream's interaction set dies with the row).
    while (s.fx.items.len > count) {
        const fx = s.fx.pop().?;
        fx.destroy(n.allocator);
    }
    while (s.fx.items.len < count) {
        s.fx.append(ItemFx.create(n.allocator, n, s.opts.theme) catch @panic("klaxon: out of memory")) catch @panic("klaxon: out of memory");
    }
    // The indices die with the shrunk items (the interactions inside the
    // removed fx are already gone with it).
    if (s.hovered != null and s.hovered.? >= count) s.hovered = null;
    if (s.pressed != null and s.pressed.? >= count) s.pressed = null;
    if (count == 0) return;
    // Arrangement.spacedBy(NavigationBarItemHorizontalPadding) between
    // weight(1f) cells: equal cells with 8dp gaps that belong to no item.
    const gaps = @as(f32, @floatFromInt(count - 1)) * item_gap;
    const cell_w = @max(0, (bounds.w - gaps) / @as(f32, @floatFromInt(count)));
    const loose: Constraints = .{ .max_w = cell_w, .max_h = bounds.h };
    const rtl = ui.i18n.direction() == .rtl;
    for (n.children.items, 0..) |child, i| {
        const cs = child.measure(loose);
        // RTL: cell 0 is the rightmost — index order mirrors visually.
        const x = if (rtl) bounds.x + bounds.w - (@as(f32, @floatFromInt(i)) + 1) * (cell_w + item_gap) + item_gap else bounds.x + @as(f32, @floatFromInt(i)) * (cell_w + item_gap);
        s.cells.items[i] = .{ .x = x, .y = bounds.y, .w = cell_w, .h = bounds.h };
        s.content_sizes.items[i] = cs;
        // The item's layout frame (content + 2*cvp) centers in the cell;
        // inside it the content starts cvp from the top.
        const v = itemVerticals(cs.h);
        child.layout(.{
            .x = x + (cell_w - cs.w) / 2,
            .y = bounds.y + (bounds.h - v.frame_h) / 2 + v.cvp,
            .w = cs.w,
            .h = cs.h,
        });
    }
    if (!s.semantics_attached) {
        s.semantics_attached = true;
        syncItemSemantics(n, s);
    }
}

/// The item's indicator rect (the 56x32 pill) in parent space — upstream:
/// icon + 2*IndicatorHorizontalPadding(16) wide x icon +
/// 2*IndicatorVerticalPadding(4) high, centered horizontally, vertically
/// at contentVerticalPadding - IVP (it wraps the icon, not the label).
/// Shared by the paint path and the keyboard ripple.
fn indicatorRect(s: *NavBarState, cell: Rect, i: usize) Rect {
    const v = itemVerticals(s.content_sizes.items[i].h);
    return .{
        .x = cell.x + (cell.w - indicator_w) / 2,
        .y = cell.y + (cell.h - v.frame_h) / 2 + v.cvp - ind_v_pad,
        .w = indicator_w,
        .h = indicator_h,
    };
}

fn navBarPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, t.colors.surface_container);
    const sel = s.sig.peek();
    for (s.cells.items, 0..) |cell, i| {
        const pill = indicatorRect(s, cell, i);
        // The active indicator (secondary_container, CornerFull).
        if (i == sel) {
            ui.paint.fillRRect(ctx, pill.x, pill.y, pill.w, pill.h, pill.h / 2, t.colors.secondary_container);
        }
    }
}

/// The indication pass — upstream's `indicatorRipplePlaceable` places LAST
/// (NavigationBar.kt:711-714: indicator, label, icon, then the ripple), so
/// the layer + ink paint OVER the destination's icon/label — hence the
/// post-children hook rather than the bar's own paint.
fn navBarPostPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    for (s.cells.items, 0..) |cell, i| {
        const pill = indicatorRect(s, cell, i);
        const fx = s.fx.items[i];
        // The item's focus is its child node's (the .tab) — polled, there
        // is no focus-gained hook.
        fx.inter.setFocused(input.isFocused(n.children.items[i]));
        fx.layer.sync(&fx.inter, t.colors.on_surface);
        if (fx.layer.paintColor()) |lc| {
            ui.paint.fillRRect(ctx, pill.x, pill.y, pill.w, pill.h, pill.h / 2, lc);
        }
        // Ripples.paint reads n.bounds for the clip + geometry — rebind it
        // to the pill rect (a shallow proxy; only .bounds is consulted).
        if (fx.ripples.live()) {
            var proxy = n.*;
            proxy.bounds = pill;
            fx.ripples.paint(ctx, &proxy, .{ .rrect = pill.h / 2 });
        }
    }
}

/// End an item's live press (release = up, cancel = drag-off/outside) —
/// the tracker entry and its ripple pair on `press_id`.
fn navBarEndPress(s: *NavBarState, i: usize, now_ms: u64, cancel: bool) void {
    const fx = s.fx.items[i];
    if (fx.press_id == 0) return;
    if (cancel) fx.inter.cancel(fx.press_id) else fx.inter.release(fx.press_id);
    fx.ripples.release(fx.press_id, now_ms);
    fx.press_id = 0;
}

/// Move the hover interaction to a new item (null = none).
fn navBarSetHover(s: *NavBarState, h: ?usize) void {
    if (h == s.hovered) return;
    if (s.hovered) |old| s.fx.items[old].inter.endHover();
    s.hovered = h;
    if (s.hovered) |new| _ = s.fx.items[new].inter.hoverEnter();
}

fn navBarOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    switch (ev.phase) {
        .down => {
            if (itemAtPoint(n, s, ev.raw_x, ev.raw_y)) |i| {
                const fx = s.fx.items[i];
                if (fx.press_id != 0) navBarEndPress(s, i, ev.time_ms, true); // a second pointer supersedes
                fx.press_id = fx.inter.pressDown(ev.x, ev.y);
                fx.ripples.spawn(fx.press_id, ev.x, ev.y, ev.time_ms);
                s.pressed = i;
                return true;
            }
            return false;
        },
        .up => {
            const up_item = itemAtPoint(n, s, ev.raw_x, ev.raw_y);
            const was = s.pressed;
            s.pressed = null;
            if (was != null) {
                navBarEndPress(s, was.?, ev.time_ms, false);
                if (up_item != null and up_item.? == was.?) s.sig.set(up_item.?);
                return true; // the press is consumed even when released outside
            }
            return false;
        },
        .enter => {
            navBarSetHover(s, itemAtPoint(n, s, ev.raw_x, ev.raw_y));
            return true;
        },
        .leave => {
            navBarSetHover(s, null);
            return true;
        },
        .move => {
            // upstream selectable cancels the press when the pointer
            // leaves the item — the move stays claimed while pressed
            if (s.pressed) |p| {
                if (itemAtPoint(n, s, ev.raw_x, ev.raw_y) != p) {
                    navBarEndPress(s, p, ev.time_ms, true);
                    s.pressed = null;
                }
                return true;
            }
            return false;
        },
        .outside_down => {
            if (s.pressed) |p| {
                navBarEndPress(s, p, ev.time_ms, true);
                s.pressed = null;
                return true; // it owned the interaction
            }
            return false;
        },
        // Uncaptured hover over an unchanged deepest node: track the hovered
        // cell (the enter/leave pair only fires when the node changes).
        .hover_move => {
            navBarSetHover(s, itemAtPoint(n, s, ev.raw_x, ev.raw_y));
            return true;
        },
    }
}

fn navBarOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            if (focusedItem(n)) |i| {
                // A key press lands at the indication's center — the pill
                // (upstream's keyboard press position = the component
                // center); released immediately, the ripple still expands.
                if (i < s.fx.items.len and i < s.cells.items.len) {
                    const fx = s.fx.items[i];
                    const pill = indicatorRect(s, s.cells.items[i], i);
                    const cx = pill.x + pill.w / 2;
                    const cy = pill.y + pill.h / 2;
                    const pid = fx.inter.pressDown(cx, cy);
                    fx.ripples.spawn(pid, cx, cy, 0);
                    fx.inter.release(pid);
                    fx.ripples.release(pid, 0);
                }
                s.sig.set(i);
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
                input.requestFocus(n.children.items[next]); // selection-follows-focus, both ways
                return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Selection changed: sync the items' checked state, repaint, announce.
fn navBarSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.semantics_attached) syncItemSemantics(n, s);
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the selection changed
}

fn navBarDeinit(n: *Node) void {
    const s = stateOf(n);
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = navBarSyncCb, .userdata = n } });
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = navBarLocaleCb, .userdata = n });
    input.releaseNode(n);
    for (s.fx.items) |fx| fx.destroy(n.allocator);
    s.fx.deinit();
    s.cells.deinit();
    s.content_sizes.deinit();
    n.allocator.destroy(s);
}

/// The group label is tr()-resolved — the locale callback re-attaches in
/// the new locale (the destination children carry app labels, verbatim).
fn navBarLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    ui.semantics.attach(n, .{ .role = .group, .label = s.opts.label orelse i18n_mod.tr("Navigation bar") });
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

const nav_bar_vtable = ui.node.VTable{
    .measure = navBarMeasure,
    .layout = navBarLayout,
    .paint = navBarPaint,
    .deinit = navBarDeinit,
    .on_pointer = navBarOnPointer,
    .on_key = navBarOnKey,
    .post_children_paint = navBarPostPaint,
};

/// Bottom navigation bar (M3E). Children = the destinations (passive
/// icon+label content); the bar owns selection, indicator and state layers.
/// `selected` is app-owned; the bar subscribes and unsubscribes at deinit.
pub fn navBar(allocator: std.mem.Allocator, selected: *ui.state.Signal(usize), opts: NavBarOptions) !*Node {
    const node = try Node.create(allocator, &nav_bar_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(NavBarState);
    errdefer allocator.destroy(s);
    s.* = .{ .sig = selected, .opts = opts, .cells = .init(allocator), .content_sizes = .init(allocator), .fx = .init(allocator) };
    node.state = s;
    navBarLocaleCb(node); // Phase 2c — the same path resolves the label
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = navBarLocaleCb, .userdata = node });
    selected.subscribe(.{ .callback = .{ .fn_ptr = navBarSyncCb, .userdata = node } });
    return node;
}

// --- destination item ---
// navBar()'s children are passive content — but the M3E destination look
// (icon over label, ink recoloring on selection) is what the bar's
// indicator math assumes. `destination` builds exactly that: a 24dp icon
// at the content's top, the label_medium label
// IndicatorVerticalPadding + NavigationBarIndicatorToLabelPadding (8dp)
// below the icon's bottom, both recolored from the parent bar's selection
// at paint time — active: the icon inks on_secondary_container (it sits on
// the secondary_container pill) and the label inks secondary
// (NavigationBarTokens.ItemActiveLabelTextColor); inactive:
// on_surface_variant. A destination used outside a nav bar paints the
// inactive colors of the light theme.

/// label top = icon bottom + IndicatorVerticalPadding (4) +
/// NavigationBarIndicatorToLabelPadding (4).
const dest_icon_label_gap: f32 = ind_v_pad + ind_to_label;

const DestState = struct {
    icon: icon_w.IconName,
    label: [:0]const u8, // owned
    m: ui.paint.TextMetrics,
};

fn destState(n: *Node) *DestState {
    return @ptrCast(@alignCast(n.state.?));
}

/// The parent bar's theme + this item's index/selection (standalone use:
/// the light theme, never active).
fn destContext(n: *Node) struct { theme: Theme, active: bool } {
    if (n.parent) |p| {
        if (p.vtable == &nav_bar_vtable) {
            const ps = stateOf(p);
            const sel = ps.sig.peek();
            for (p.children.items, 0..) |ch, i| {
                if (ch == n) return .{ .theme = ps.opts.theme, .active = i == sel };
            }
            return .{ .theme = ps.opts.theme, .active = false };
        }
    }
    return .{ .theme = theme_mod.light, .active = false };
}

fn destMeasure(n: *Node, c: Constraints) Size {
    const s = destState(n);
    // Refresh metrics against the live theme — the type style comes from
    // the parent bar, not from construction-time options.
    const ls = destContext(n).theme.type_scale.label_medium;
    s.m = ui.paint.measureText(s.label, ls.size, ls.weight >= 500);
    return c.constrain(.{ .w = @max(icon_size, s.m.width), .h = icon_size + dest_icon_label_gap + s.m.height });
}

fn destLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}

fn destPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = destState(n);
    const dc = destContext(n);
    const cs = dc.theme.colors;
    const icon_c = if (dc.active) cs.on_secondary_container else cs.on_surface_variant;
    const label_c = if (dc.active) cs.secondary else cs.on_surface_variant;
    // Icon at the content's TOP — the bar centers its 56x32 pill on it.
    const ix = n.bounds.x + (n.bounds.w - icon_size) / 2;
    icon_w.drawIcon(ctx, s.icon, ix, n.bounds.y, icon_size / 24.0, icon_c);
    const ls = dc.theme.type_scale.label_medium;
    const lx = n.bounds.x + (n.bounds.w - s.m.width) / 2;
    ui.paint.text(ctx, s.label, lx, n.bounds.y + icon_size + dest_icon_label_gap + s.m.ascent, ls.size, ls.weight >= 500, label_c);
}

fn destDeinit(n: *Node) void {
    const s = destState(n);
    n.allocator.free(s.label);
    n.allocator.destroy(s);
}

const dest_vtable = ui.node.VTable{ .measure = destMeasure, .layout = destLayout, .paint = destPaint, .deinit = destDeinit, .measure_pure = false };

/// A nav-bar destination: 24dp icon over a label_medium label, recoloring
/// with the parent bar's selection. `label` is copied.
pub fn destination(allocator: std.mem.Allocator, icon: icon_w.IconName, label: []const u8) !*Node {
    const node = try Node.create(allocator, &dest_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(DestState);
    errdefer allocator.destroy(s);
    const buf = try allocator.alloc(u8, label.len + 1);
    errdefer allocator.free(buf);
    @memcpy(buf[0..label.len], label);
    buf[label.len] = 0;
    const ls = theme_mod.light.type_scale.label_medium;
    s.* = .{ .icon = icon, .label = buf[0..label.len :0], .m = ui.paint.measureText(buf[0..label.len :0], ls.size, ls.weight >= 500) };
    node.state = s;
    // The bar's syncItemSemantics upgrades this descriptor (focusable,
    // checked, actions) while keeping the label.
    ui.semantics.attach(node, .{ .role = .tab, .label = s.label, .focusable = true });
    return node;
}

// --- tests ---

const text_w = @import("text.zig");

fn testItem(a: std.mem.Allocator, label: []const u8) !*Node {
    return text_w.text(a, label, .{ .size = 12, .color = 0x000000FF });
}

test "nav_bar: measure fills the width and reports the M3E height" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const bar = try navBar(std.testing.allocator, sel, .{});
    defer bar.deinit();
    bar.add(try testItem(std.testing.allocator, "One"));
    const m = bar.measure(.{ .max_w = 480, .max_h = 600 });
    try std.testing.expectEqual(@as(f32, 480), m.w);
    try std.testing.expectEqual(@as(f32, 80), m.h);
}

test "nav_bar: layout splits the width into equal cells with 8dp gaps" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const bar = try navBar(std.testing.allocator, sel, .{});
    defer bar.deinit();
    const a = try testItem(std.testing.allocator, "One");
    const b = try testItem(std.testing.allocator, "Two");
    bar.add(a);
    bar.add(b);
    bar.layout(.{ .x = 0, .y = 0, .w = 400, .h = 80 });
    const s = stateOf(bar);
    // upstream Row: weight(1f) cells + spacedBy(8) → (400-8)/2 cells
    try std.testing.expectEqual(@as(usize, 2), s.cells.items.len);
    try std.testing.expectEqual(@as(f32, 0), s.cells.items[0].x);
    try std.testing.expectEqual(@as(f32, 196), s.cells.items[0].w);
    try std.testing.expectEqual(@as(f32, 204), s.cells.items[1].x);
    // the content is centered in its cell
    try std.testing.expectEqual(@as(f32, (196 - a.bounds.w) / 2), a.bounds.x);
    const v = itemVerticals(a.bounds.h);
    try std.testing.expectEqual(@as(f32, (80 - v.frame_h) / 2 + v.cvp), a.bounds.y);
}

test "nav_bar: items get .tab semantics with checked following the selection" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const bar = try navBar(std.testing.allocator, sel, .{});
    defer bar.deinit();
    bar.add(try testItem(std.testing.allocator, "One"));
    bar.add(try testItem(std.testing.allocator, "Two"));
    bar.layout(.{ .x = 0, .y = 0, .w = 400, .h = 80 });
    try std.testing.expect(bar.children.items[0].semantics.?.checked.?);
    try std.testing.expect(!bar.children.items[1].semantics.?.checked.?);
    sel.set(1);
    try std.testing.expect(!bar.children.items[0].semantics.?.checked.?);
    try std.testing.expect(bar.children.items[1].semantics.?.checked.?);
}

test "nav_bar: click selects the item under the pointer" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const bar = try navBar(std.testing.allocator, sel, .{});
    defer bar.deinit();
    bar.add(try testItem(std.testing.allocator, "One"));
    bar.add(try testItem(std.testing.allocator, "Two"));
    bar.layout(.{ .x = 0, .y = 0, .w = 400, .h = 80 });
    var router = input.InputRouter{};
    router.dispatchPointer(bar, .{ .phase = .down, .x = 300, .y = 40 });
    router.dispatchPointer(bar, .{ .phase = .up, .x = 300, .y = 40 });
    try std.testing.expectEqual(@as(usize, 1), sel.peek());
    // press on item 0, release outside: no change
    router.dispatchPointer(bar, .{ .phase = .down, .x = 50, .y = 40 });
    router.dispatchPointer(bar, .{ .phase = .up, .x = 500, .y = 400 });
    try std.testing.expectEqual(@as(usize, 1), sel.peek());
}

test "nav_bar: arrows move the selection, Enter activates the focused item" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const bar = try navBar(std.testing.allocator, sel, .{});
    defer bar.deinit();
    const a = try testItem(std.testing.allocator, "One");
    const b = try testItem(std.testing.allocator, "Two");
    bar.add(a);
    bar.add(b);
    bar.layout(.{ .x = 0, .y = 0, .w = 400, .h = 80 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    input.requestFocus(a); // arrows move the selection (selection-follows-focus)
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .right }));
    try std.testing.expectEqual(@as(usize, 1), sel.peek());
    // focus followed the selection: Enter activates the NEW item, not the old one
    try std.testing.expect(router.focusedNode() == b);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .enter }));
    try std.testing.expectEqual(@as(usize, 1), sel.peek());
    // clamped at the end: nothing to do, the key is not handled
    try std.testing.expect(!router.dispatchKey(.{ .kind = .key_down, .key = .right }));
    try std.testing.expectEqual(@as(usize, 1), sel.peek());
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .left }));
    try std.testing.expect(router.focusedNode() == a);
    try std.testing.expectEqual(@as(usize, 0), sel.peek());
}

test "nav_bar: hover tracks across empty cell space (hover_move)" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const bar = try navBar(std.testing.allocator, sel, .{});
    defer bar.deinit();
    bar.add(try testItem(std.testing.allocator, "One"));
    bar.add(try testItem(std.testing.allocator, "Two"));
    bar.add(try testItem(std.testing.allocator, "Three"));
    bar.layout(.{ .x = 0, .y = 0, .w = 300, .h = 80 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const s = stateOf(bar);
    // y=4 is inside the bar but above the centered item content: the deepest
    // hit node is the bar itself — moving between such spots changes no node,
    // so the router delivers hover_move and the highlight must follow.
    router.dispatchPointer(bar, .{ .phase = .move, .x = 50, .y = 4 });
    try std.testing.expectEqual(@as(?usize, 0), s.hovered);
    router.dispatchPointer(bar, .{ .phase = .move, .x = 175, .y = 4 });
    try std.testing.expectEqual(@as(?usize, 1), s.hovered);
    router.dispatchPointer(bar, .{ .phase = .move, .x = 275, .y = 4 });
    try std.testing.expectEqual(@as(?usize, 2), s.hovered);
    // off the bar: leave clears the hover
    router.dispatchPointer(bar, .{ .phase = .move, .x = 50, .y = 200 });
    try std.testing.expectEqual(@as(?usize, null), s.hovered);
}

test "golden: nav_bar paints the surface container and the active indicator" {
    const t = theme_mod.light;
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const bar = try navBar(std.testing.allocator, sel, .{ .theme = t });
    defer bar.deinit();
    bar.add(try testItem(std.testing.allocator, "One"));
    bar.add(try testItem(std.testing.allocator, "Two"));
    var r = try golden.Renderer.init(std.testing.allocator, 400, 80);
    defer r.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 400, .h = 80 });
    r.paint(bar, 0x000000FF);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    // container + the active indicator under item 0
    try std.testing.expect(f1.countColor(t.colors.surface_container) > 400 * 80 - 3000);
    try std.testing.expect(f1.countColorIn(.{ .x = 0, .y = 0, .w = 200, .h = 80 }, t.colors.secondary_container) > 500);
    try std.testing.expect(f1.countColorIn(.{ .x = 200, .y = 0, .w = 200, .h = 80 }, t.colors.secondary_container) == 0);
    // select item 1: the indicator moves
    sel.set(1);
    r.paint(bar, 0x000000FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expect(f2.countColorIn(.{ .x = 0, .y = 0, .w = 200, .h = 80 }, t.colors.secondary_container) == 0);
    try std.testing.expect(f2.countColorIn(.{ .x = 200, .y = 0, .w = 200, .h = 80 }, t.colors.secondary_container) > 500);
}

test "golden: destination items recolor ink with the selection" {
    const t = theme_mod.light;
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const bar = try navBar(std.testing.allocator, sel, .{ .theme = t });
    defer bar.deinit();
    bar.add(try destination(std.testing.allocator, .home, "One"));
    bar.add(try destination(std.testing.allocator, .star, "Two"));
    var r = try golden.Renderer.init(std.testing.allocator, 400, 80);
    defer r.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 400, .h = 80 });
    r.paint(bar, 0x000000FF);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    // Item 0 active: on_secondary_container icon ink over the pill +
    // secondary label; item 1 inactive: on_surface_variant ink only.
    try std.testing.expect(f1.countColorIn(.{ .x = 0, .y = 0, .w = 200, .h = 80 }, t.colors.on_secondary_container) > 0);
    try std.testing.expect(f1.countColorIn(.{ .x = 0, .y = 0, .w = 200, .h = 80 }, t.colors.secondary) > 0);
    try std.testing.expectEqual(@as(u64, 0), f1.countColorIn(.{ .x = 200, .y = 0, .w = 200, .h = 80 }, t.colors.on_secondary_container));
    try std.testing.expectEqual(@as(u64, 0), f1.countColorIn(.{ .x = 200, .y = 0, .w = 200, .h = 80 }, t.colors.secondary));
    try std.testing.expect(f1.countColorIn(.{ .x = 200, .y = 0, .w = 200, .h = 80 }, t.colors.on_surface_variant) > 0);
}

test "golden: nav_bar paints a state layer on hover" {
    const t = theme_mod.light;
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const bar = try navBar(std.testing.allocator, sel, .{ .theme = t });
    defer bar.deinit();
    bar.add(try testItem(std.testing.allocator, "One"));
    var r = try golden.Renderer.init(std.testing.allocator, 200, 80);
    defer r.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 200, .h = 80 });
    var router = input.InputRouter{};
    router.dispatchPointer(bar, .{ .phase = .move, .x = 300, .y = 400 }); // away: no hover
    r.paint(bar, 0x000000FF);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    try std.testing.expect(f1.countColor(t.colors.secondary_container) > 500); // indicator, no state layer
    // hover item 0 (selected): state layer over the indicator
    router.dispatchPointer(bar, .{ .phase = .move, .x = 100, .y = 40 });
    r.paint(bar, 0x000000FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expect(f2.countColor(t.colors.secondary_container) < f1.countColor(t.colors.secondary_container)); // covered by the layer
}

test "nav_bar: i18n — the default label localizes + re-resolves on a locale switch" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Navigation bar\": \"Barra de navegación\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const sel = try ui.state.Signal(usize).init(a, 0);
    defer sel.deinit();
    const bar = try navBar(a, sel, .{});
    defer bar.deinit();
    try std.testing.expectEqualStrings("Barra de navegación", bar.semantics.?.label);
    try i18n.setLocale("en");
    try std.testing.expectEqualStrings("Navigation bar", bar.semantics.?.label);
    // an app-supplied label is verbatim — a switch leaves it alone
    const bar2 = try navBar(a, sel, .{ .label = "My nav" });
    defer bar2.deinit();
    try i18n.setLocale("es");
    try std.testing.expectEqualStrings("My nav", bar2.semantics.?.label);
}
