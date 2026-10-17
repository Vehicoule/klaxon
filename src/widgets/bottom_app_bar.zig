// Bottom app bar widget (Phase 2d.5, M3E batch 4) — the M3E bottom app bar.
//
// Upstream: .ref/material3/AppBar.kt (BottomAppBar, BottomAppBarLayout,
// BottomAppBarDefaults) + tokens/BottomAppBarTokens.kt:
//   - ContainerHeight 80, ContainerColor SurfaceContainer, ContainerShape
//     CornerNone, ContainerElevation 0 (BottomAppBarDefaults overrides the
//     Level2 token — flat IS the upstream render)
//   - Row: fillMaxWidth x height(ContainerHeight),
//     padding(all = BottomAppBarContentPadding(4)), Arrangement.Start,
//     Alignment.CenterVertically
//   - actions in a weight(1f) Row at the start; the FAB sits in a trailing
//     Box with padding(top = FABVerticalPadding(8), end =
//     FABHorizontalPadding(12)) → FAB top = 4 + 8 = 12 and its end edge
//     lands 4 + 12 = 16 inside the bar's end edge (the standard 56dp FAB
//     ends up vertically centered)
//   - placeRelative → RTL mirrors the whole layout: the FAB docks at the
//     left and the actions flow right-to-left
//
// The bar owns no interaction: the actions/fab slots are ordinary widgets
// (icon buttons, FABs) with their own semantics. The widget is a pure
// chrome container: measure/layout/paint + a group semantic.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const i18n_mod = @import("../ui/i18n.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Theme = theme_mod.Theme;

/// AppBar.kt BottomAppBar section (verbatim):
///   BottomAppBarContentPadding = 4 on all sides; the FAB box carries
///   padding(top = FABVerticalPadding = 8, end = FABHorizontalPadding = 12).
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
    /// The semantics label — null resolves the localized "Bottom app bar"
    /// (an app string is verbatim).
    label: ?[]const u8 = null,
};

const BottomAppBarState = struct { opts: BottomAppBarOptions, i18n: ?*i18n_mod.I18n = null };

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
    i18n_mod.unsubscribeLocale(stateOf(n).i18n, .{ .fn_ptr = babLocaleCb, .userdata = n });
    n.allocator.destroy(stateOf(n));
}

/// The group label is tr()-resolved — the locale callback re-attaches in
/// the new locale.
fn babLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    ui.semantics.attach(n, .{ .role = .group, .label = s.opts.label orelse i18n_mod.tr("Bottom app bar") });
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
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
    babLocaleCb(node);
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = babLocaleCb, .userdata = node });
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
    // the bar is the surface_container except the action/FAB ink — sample
    // the middle strip so the FAB's elevation shadow can't dilute the count
    try std.testing.expect(fr.countColorIn(.{ .x = 120, .y = 10, .w = 180, .h = 60 }, t.colors.surface_container) > 180 * 60 - 500);
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

test "bottom_app_bar: i18n — the default label localizes + re-resolves on a locale switch" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Bottom app bar\": \"Barra inferior\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const bar = try bottomAppBar(a, .{});
    defer bar.deinit();
    try std.testing.expectEqualStrings("Barra inferior", bar.semantics.?.label);
    try i18n.setLocale("en");
    try std.testing.expectEqualStrings("Bottom app bar", bar.semantics.?.label);
}
