// Navigation bar widget (Phase 2d.1, M3E batch 1) — bottom navigation bar.
//
// Spec: m3.material.io/components/navigation-bar (M3E) + Compose
// NavigationBarTokens / NavigationBarVerticalItemTokens:
//   - container height 80 (tall), color surface_container,
//   - items split the width equally (64dp minimum touch width each); an
//     item is passive content — `destination()` builds the M3E icon+label
//     content and recolors it on selection — the bar owns the interaction,
//   - active indicator: 56x32 pill (corner full), color secondary_container,
//     centered on the item's icon (wrapping the icon, not the label);
//     active label/icon colors are the app's (M3E: secondary /
//     on_secondary_container — destination() supplies them), inactive
//     on_surface_variant,
//   - state layers: on_secondary_container over the active indicator,
//     on_surface_variant over the indicator zone when inactive.
//
// The selection is a Signal(usize) owned by the app; the bar subscribes
// (visual + semantic sync) and unsubscribes at deinit. Items get a `.tab`
// semantic (checked follows the selection; Enter/Space activates, arrows
// move the selection — M3E selection-follows-focus).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const icon_w = @import("icon.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

/// M3E measurement tokens: active indicator 56x32, icon 24, item horizontal
/// padding 8 (the indicator never exceeds item width - 16), item minimum
/// touch width 64.
const indicator_w: f32 = 56;
const indicator_h: f32 = 32;
const icon_size: f32 = 24;
const item_padding_h: f32 = 8;
const min_item_w: f32 = 64;

pub const NavBarOptions = struct {
    theme: Theme = theme_mod.light,
    height: f32 = 80, // M3E tall container height
    label: []const u8 = "Navigation bar", // semantic label (borrowed)
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
    semantics_attached: bool = false,
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
    const f = router.focused orelse return null;
    var cur: ?*Node = f;
    while (cur) |c| : (cur = c.parent) {
        if (c == n) return null;
        for (n.children.items, 0..) |child, i| {
            if (child == c) return i;
        }
    }
    return null;
}

fn navBarMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const count: f32 = @floatFromInt(n.children.items.len);
    var w = if (std.math.isFinite(c.max_w)) c.max_w else count * 80;
    // M3E: each destination keeps a 64dp minimum touch width — the request
    // asks for it; a tighter parent still wins through constrain().
    w = @max(w, count * min_item_w);
    return c.constrain(.{ .w = w, .h = s.opts.height });
}

fn navBarLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    const count = n.children.items.len;
    if (count == 0) return;
    const item_w = bounds.w / @as(f32, @floatFromInt(count));
    if (s.cells.items.len != count) {
        s.cells.clearRetainingCapacity();
        s.content_sizes.clearRetainingCapacity();
        for (0..count) |_| {
            s.cells.append(.{}) catch @panic("klaxon: out of memory");
            s.content_sizes.append(.{}) catch @panic("klaxon: out of memory");
        }
    }
    const loose: Constraints = .{ .max_w = item_w, .max_h = bounds.h };
    const rtl = ui.i18n.direction() == .rtl;
    for (n.children.items, 0..) |child, i| {
        const cs = child.measure(loose);
        // RTL: cell 0 is the rightmost — index order mirrors visually.
        const x = if (rtl) bounds.x + bounds.w - @as(f32, @floatFromInt(i + 1)) * item_w else bounds.x + @as(f32, @floatFromInt(i)) * item_w;
        s.cells.items[i] = .{ .x = x, .y = bounds.y, .w = item_w, .h = bounds.h };
        s.content_sizes.items[i] = cs;
        child.layout(.{
            .x = x + (item_w - cs.w) / 2,
            .y = bounds.y + (bounds.h - cs.h) / 2,
            .w = cs.w,
            .h = cs.h,
        });
    }
    if (!s.semantics_attached) {
        s.semantics_attached = true;
        syncItemSemantics(n, s);
    }
}

fn navBarPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, t.colors.surface_container);
    const sel = s.sig.peek();
    for (s.cells.items, 0..) |cell, i| {
        // Indicator zone: 56 wide max (item width - 2*8), 32 high, centered
        // horizontally; vertically it wraps the ICON, not the label — the
        // item's content is laid out icon-first (the bar centers the
        // content block), so the pill's center is the icon's center:
        // content_top + icon/2 - pill/2.
        const iw = @min(indicator_w, cell.w - item_padding_h * 2);
        const content_h = s.content_sizes.items[i].h;
        const iy = cell.y + (cell.h - content_h) / 2 - (indicator_h - icon_size) / 2;
        const ix = cell.x + (cell.w - iw) / 2;
        const hovered = s.hovered != null and s.hovered.? == i;
        const pressed = s.pressed != null and s.pressed.? == i;
        if (i == sel) {
            var c = t.colors.secondary_container;
            if (pressed) {
                c = theme_mod.stateLayer(c, t.colors.on_secondary_container, t.state.pressed);
            } else if (hovered) {
                c = theme_mod.stateLayer(c, t.colors.on_secondary_container, t.state.hover);
            }
            ui.paint.fillRRect(ctx, ix, iy, iw, indicator_h, indicator_h / 2, c);
        } else if (hovered or pressed) {
            const alpha = if (pressed) t.state.pressed else t.state.hover;
            ui.paint.fillRRect(ctx, ix, iy, iw, indicator_h, indicator_h / 2, theme_mod.stateLayer(t.colors.surface_container, t.colors.on_surface_variant, alpha));
        }
    }
}

fn navBarOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    switch (ev.phase) {
        .down => {
            s.pressed = itemAtPoint(n, s, ev.raw_x, ev.raw_y);
            if (s.pressed != null) {
                n.markDirty();
                return true;
            }
            return false;
        },
        .up => {
            const up_item = itemAtPoint(n, s, ev.raw_x, ev.raw_y);
            const was = s.pressed;
            s.pressed = null;
            n.markDirty();
            if (was != null) {
                if (up_item != null and up_item.? == was.?) s.sig.set(up_item.?);
                return true; // the press is consumed even when released outside
            }
            return false;
        },
        .enter => {
            s.hovered = itemAtPoint(n, s, ev.raw_x, ev.raw_y);
            n.markDirty();
            return true;
        },
        .leave => {
            if (s.hovered != null) {
                s.hovered = null;
                n.markDirty();
            }
            return true;
        },
        .move => return s.pressed != null,
        // Uncaptured hover over an unchanged deepest node: track the hovered
        // cell (the enter/leave pair only fires when the node changes).
        .hover_move => {
            const h = itemAtPoint(n, s, ev.raw_x, ev.raw_y);
            if (h != s.hovered) {
                s.hovered = h;
                n.markDirty();
            }
            return true;
        },
        else => return false,
    }
}

fn navBarOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            if (focusedItem(n)) |i| {
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
    input.releaseNode(n);
    s.cells.deinit();
    s.content_sizes.deinit();
    n.allocator.destroy(s);
}

const nav_bar_vtable = ui.node.VTable{
    .measure = navBarMeasure,
    .layout = navBarLayout,
    .paint = navBarPaint,
    .deinit = navBarDeinit,
    .on_pointer = navBarOnPointer,
    .on_key = navBarOnKey,
};

/// Bottom navigation bar (M3E). Children = the destinations (passive
/// icon+label content); the bar owns selection, indicator and state layers.
/// `selected` is app-owned; the bar subscribes and unsubscribes at deinit.
pub fn navBar(allocator: std.mem.Allocator, selected: *ui.state.Signal(usize), opts: NavBarOptions) !*Node {
    const node = try Node.create(allocator, &nav_bar_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(NavBarState);
    errdefer allocator.destroy(s);
    s.* = .{ .sig = selected, .opts = opts, .cells = .init(allocator), .content_sizes = .init(allocator) };
    node.state = s;
    ui.semantics.attach(node, .{ .role = .group, .label = opts.label }); // Phase 2c
    selected.subscribe(.{ .callback = .{ .fn_ptr = navBarSyncCb, .userdata = node } });
    return node;
}

// --- destination item ---
// navBar()'s children are passive content — but the M3E destination look
// (icon over label, ink recoloring on selection) is what the bar's
// indicator math assumes. `destination` builds exactly that: a 24dp icon
// at the content's top, the label_medium label 4dp below, both recolored
// from the parent bar's selection at paint time — active: the icon inks
// on_secondary_container (it sits on the secondary_container pill) and the
// label inks secondary; inactive: on_surface_variant. A destination used
// outside a nav bar paints the inactive colors of the light theme.

const dest_icon_label_gap: f32 = 4;

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

test "nav_bar: layout splits the width equally and centers the content" {
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
    try std.testing.expectEqual(@as(usize, 2), s.cells.items.len);
    try std.testing.expectEqual(@as(f32, 0), s.cells.items[0].x);
    try std.testing.expectEqual(@as(f32, 200), s.cells.items[0].w);
    try std.testing.expectEqual(@as(f32, 200), s.cells.items[1].x);
    // the content is centered in its cell
    try std.testing.expectEqual(@as(f32, (200 - a.bounds.w) / 2), a.bounds.x);
    try std.testing.expectEqual(@as(f32, (80 - a.bounds.h) / 2), a.bounds.y);
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
    try std.testing.expect(router.focused == b);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .enter }));
    try std.testing.expectEqual(@as(usize, 1), sel.peek());
    // clamped at the end: nothing to do, the key is not handled
    try std.testing.expect(!router.dispatchKey(.{ .kind = .key_down, .key = .right }));
    try std.testing.expectEqual(@as(usize, 1), sel.peek());
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .left }));
    try std.testing.expect(router.focused == a);
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
