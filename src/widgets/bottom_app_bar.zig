// Bottom app bar widget (Phase 2d.5, M3E batch 4) — the M3E bottom app bar.
//
// Spec: m3.material.io/components/bottom-app-bar + Compose AppBar.kt
// (BottomAppBar) / BottomAppBarTokens:
//   - container height 80, color surface_container, shape CornerNone,
//   - content padding 4 all around (BottomAppBarHorizontalPadding =
//     16 - 12 — the icon buttons' own 12dp touch-target expansion makes
//     the visual icon land 16dp from the bar edge),
//   - the actions row packs at the start edge, vertically centered,
//     and fills the width up to the FAB (Row weight(1f), Arrangement.Start),
//   - an optional FAB docks at the END edge: FAB top = content top + 8
//     (12 - 4), FAB end edge = content end - 12 (16 - 4) → the standard
//     56dp FAB sits vertically centered with a 16dp end margin,
//   - RTL: `start`/`end` follow the text direction — the FAB docks at the
//     left and the actions flow right-to-left.
//
// The bar owns no interaction: the actions/fab slots are ordinary widgets
// (icon buttons, FABs) with their own semantics. The widget is a pure
// chrome container: measure/layout/paint + a group semantic.
//
// Elevation (M3 level 2) is approximated flat: the framework paints tonal
// containers without shadow geometry — see docs/specs for the deviation.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Theme = theme_mod.Theme;

/// M3E measurement tokens (Compose AppBar.kt):
///   content padding 4 (= 16 - IconButton's 12dp touch expansion),
///   extra FAB padding top 8 (= 12 - 4) and end 12 (= 16 - 4).
const content_padding: f32 = 4;
const fab_padding_top: f32 = 8;
const fab_padding_end: f32 = 12;
/// Total insets used by the layout: FAB top 12, FAB end edge 16.
const fab_top: f32 = content_padding + fab_padding_top;
const fab_end: f32 = content_padding + fab_padding_end;

pub const BottomAppBarOptions = struct {
    theme: Theme = theme_mod.light,
    height: f32 = 80, // M3E bottom app bar container height
    actions: ?*Node = null, // start slot — typically a row of icon buttons
    fab: ?*Node = null, // floating action button docked at the end edge
    label: []const u8 = "Bottom app bar", // semantic label (borrowed)
};

const BottomAppBarState = struct { opts: BottomAppBarOptions };

fn stateOf(n: *Node) *BottomAppBarState {
    return @ptrCast(@alignCast(n.state.?));
}

fn bottomAppBarMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const loose = c.loosen();
    var content_w: f32 = content_padding * 2;
    if (s.opts.actions) |actions| content_w += actions.measure(loose).w;
    if (s.opts.fab) |fab| content_w += fab.measure(loose).w + fab_padding_end;
    const w = if (std.math.isFinite(c.max_w)) c.max_w else content_w;
    return c.constrain(.{ .w = w, .h = s.opts.height });
}

fn bottomAppBarLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    const b = bounds;
    const rtl = ui.i18n.direction() == .rtl;
    const loose: Constraints = .{ .max_w = b.w, .max_h = b.h };
    // The FAB docks at the END edge: end-inset 16, top 12 — the 56dp FAB
    // ends up vertically centered; taller FABs stay top-aligned (Compose
    // Alignment.TopStart inside the padded slot).
    var fab_w: f32 = 0;
    if (s.opts.fab) |fab| {
        const fs = fab.measure(loose);
        fab_w = fs.w;
        const fx = if (rtl) b.x + fab_end else b.x + b.w - fab_end - fs.w;
        fab.layout(.{ .x = fx, .y = b.y + fab_top, .w = fs.w, .h = fs.h });
    }
    // Actions: the start-edge row (Compose weight(1f) fills the region up
    // to the FAB slot — here the region is a limit, the slot keeps its
    // natural width so a bare icon button is not stretched).
    const actions_start = if (rtl) b.x + b.w - content_padding else b.x + content_padding;
    const region_w = @max(0, b.w - content_padding * 2 - fab_w - if (fab_w > 0) fab_padding_end else 0);
    if (s.opts.actions) |actions| {
        const acs = actions.measure(loose);
        const aw = @min(acs.w, region_w);
        const ah = @min(acs.h, b.h - content_padding * 2);
        const ax = if (rtl) actions_start - aw else actions_start;
        actions.layout(.{ .x = ax, .y = b.y + (b.h - ah) / 2, .w = aw, .h = ah });
    }
}

fn bottomAppBarPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, s.opts.theme.colors.surface_container);
}

fn bottomAppBarDeinit(n: *Node) void {
    n.allocator.destroy(stateOf(n));
}

const bottom_app_bar_vtable = ui.node.VTable{
    .measure = bottomAppBarMeasure,
    .layout = bottomAppBarLayout,
    .paint = bottomAppBarPaint,
    .deinit = bottomAppBarDeinit,
};

/// Bottom app bar (M3E). Slots: `actions` (the start-edge row — typically
/// a `layout.row` of icon buttons), `fab` (docked at the end edge).
/// Ownership: the slots are attached as children — the tree owns them.
pub fn bottomAppBar(allocator: std.mem.Allocator, opts: BottomAppBarOptions) !*Node {
    const node = try Node.create(allocator, &bottom_app_bar_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(BottomAppBarState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts };
    node.state = s;
    if (opts.actions) |actions| node.add(actions);
    if (opts.fab) |fab| node.add(fab);
    ui.semantics.attach(node, .{ .role = .group, .label = opts.label });
    return node;
}

// --- tests ---

const rtl_arb =
    \\{"@@locale": "ar", "x": "x"}
;

fn testRtlI18n() !*ui.i18n.I18n {
    const i18n = try ui.i18n.I18n.init(std.testing.allocator, "ar");
    errdefer i18n.deinit();
    try i18n.addArb("ar", rtl_arb, .rtl);
    try i18n.setLocale("ar");
    return i18n;
}

test "bottom_app_bar: measure fills the width and reports the M3E height" {
    const bar = try bottomAppBar(std.testing.allocator, .{});
    defer bar.deinit();
    const m = bar.measure(.{ .max_w = 480, .max_h = 600 });
    try std.testing.expectEqual(@as(f32, 480), m.w);
    try std.testing.expectEqual(@as(f32, 80), m.h);
}

test "bottom_app_bar: layout insets the actions 4 and docks the FAB at end-16" {
    const actions = try golden.solidBox(std.testing.allocator, 104, 48, 0x0000FFFF);
    const fab = try golden.solidBox(std.testing.allocator, 56, 56, 0xFF0000FF);
    const bar = try bottomAppBar(std.testing.allocator, .{ .actions = actions, .fab = fab });
    defer bar.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 400, .h = 80 });
    // actions at start+4, vertically centered
    try std.testing.expectEqual(@as(f32, 4), actions.bounds.x);
    try std.testing.expectEqual(@as(f32, (80 - 48) / 2), actions.bounds.y);
    // FAB: end edge at w - 16, top at 12 (a 56 FAB is centered in 80)
    try std.testing.expectEqual(@as(f32, 400 - 16 - 56), fab.bounds.x);
    try std.testing.expectEqual(@as(f32, 12), fab.bounds.y);
}

test "bottom_app_bar: without a FAB the actions still start at start+4" {
    const actions = try golden.solidBox(std.testing.allocator, 200, 48, 0x0000FFFF);
    const bar = try bottomAppBar(std.testing.allocator, .{ .actions = actions });
    defer bar.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 400, .h = 80 });
    try std.testing.expectEqual(@as(f32, 4), actions.bounds.x);
    try std.testing.expectEqual(@as(f32, 200), actions.bounds.w); // natural width
}

test "bottom_app_bar: the actions width clamps to the region before the FAB" {
    const actions = try golden.solidBox(std.testing.allocator, 500, 48, 0x0000FFFF);
    const fab = try golden.solidBox(std.testing.allocator, 56, 56, 0xFF0000FF);
    const bar = try bottomAppBar(std.testing.allocator, .{ .actions = actions, .fab = fab });
    defer bar.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 400, .h = 80 });
    // region = 400 - 2*4 - 56 - 12 = 324
    try std.testing.expectEqual(@as(f32, 324), actions.bounds.w);
    try std.testing.expect(actions.bounds.x + actions.bounds.w <= fab.bounds.x);
}

test "bottom_app_bar: RTL docks the FAB at the left and mirrors the actions" {
    const i18n = try testRtlI18n();
    defer i18n.deinit();
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    const actions = try golden.solidBox(std.testing.allocator, 104, 48, 0x0000FFFF);
    const fab = try golden.solidBox(std.testing.allocator, 56, 56, 0xFF0000FF);
    const bar = try bottomAppBar(std.testing.allocator, .{ .actions = actions, .fab = fab });
    defer bar.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 400, .h = 80 });
    // the FAB docks at the left edge (start = right in RTL)
    try std.testing.expectEqual(@as(f32, 16), fab.bounds.x);
    // the actions flow from the right edge: right edge at w - 4
    try std.testing.expectEqual(@as(f32, 400 - 4 - 104), actions.bounds.x);
}

test "bottom_app_bar: group semantics + children keep their own" {
    const fab_w = @import("fab.zig");
    const actions = try golden.solidBox(std.testing.allocator, 104, 48, 0x0000FFFF);
    const f = try fab_w.fab(std.testing.allocator, null, null, .{ .a11y_label = "Add" });
    const bar = try bottomAppBar(std.testing.allocator, .{ .actions = actions, .fab = f });
    defer bar.deinit();
    try std.testing.expectEqual(ui.semantics.Role.group, bar.semantics.?.role);
    try std.testing.expectEqualStrings("Bottom app bar", bar.semantics.?.label);
    try std.testing.expectEqual(ui.semantics.Role.button, f.semantics.?.role);
}

test "golden: bottom_app_bar paints the surface_container and the docked FAB" {
    const t = theme_mod.light;
    const fab_w = @import("fab.zig");
    const actions = try golden.solidBox(std.testing.allocator, 96, 48, 0x0000FFFF);
    const f = try fab_w.fab(std.testing.allocator, null, null, .{ .theme = t, .a11y_label = "Add" });
    const bar = try bottomAppBar(std.testing.allocator, .{ .theme = t, .actions = actions, .fab = f });
    defer bar.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 400, 80);
    defer r.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 400, .h = 80 });
    r.paint(bar, 0x000000FF);
    var fr = try r.readback(std.testing.allocator);
    defer fr.deinit();
    // the bar is the surface_container except the action/FAB ink
    try std.testing.expect(fr.countColor(t.colors.surface_container) > 400 * 80 - 8000);
    // the FAB's primary_container squircle shows at the end edge
    try std.testing.expect(fr.countColorIn(.{ .x = 400 - 16 - 56, .y = 12, .w = 56, .h = 56 }, t.colors.primary_container) > 1500);
    // nothing past the end margin
    try std.testing.expectEqual(@as(u32, 0), fr.countColorIn(.{ .x = 396, .y = 0, .w = 4, .h = 80 }, t.colors.primary_container));
}

test "golden: bottom_app_bar RTL docks the FAB at the left edge" {
    const t = theme_mod.light;
    const i18n = try testRtlI18n();
    defer i18n.deinit();
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    const fab_w = @import("fab.zig");
    const f = try fab_w.fab(std.testing.allocator, null, null, .{ .theme = t, .a11y_label = "Add" });
    const bar = try bottomAppBar(std.testing.allocator, .{ .theme = t, .fab = f });
    defer bar.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 400, 80);
    defer r.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 400, .h = 80 });
    r.paint(bar, 0x000000FF);
    var fr = try r.readback(std.testing.allocator);
    defer fr.deinit();
    try std.testing.expect(fr.countColorIn(.{ .x = 16, .y = 12, .w = 56, .h = 56 }, t.colors.primary_container) > 1500);
    try std.testing.expectEqual(@as(u32, 0), fr.countColorIn(.{ .x = 400 - 72, .y = 12, .w = 56, .h = 56 }, t.colors.primary_container));
}
