// App bar widget (Phase 2d.1, M3E batch 1) — top app bar.
//
// Upstream: .ref/material3/AppBar.kt (SingleRowTopAppBar, TwoRowsTopAppBar,
// TopAppBarLayout, TopAppBarMeasurePolicy.placeTopAppBar, TopAppBarDefaults)
// + tokens/AppBarTokens.kt, AppBarSmall/Medium/Large(Flexible)Tokens.kt:
//   - AppBarTokens: ContainerColor Surface, OnScrollContainerColor
//     SurfaceContainer, ContainerShape CornerNone, ContainerElevation Level0
//     (OnScrollContainerElevation Level2 — Klaxon paints tonal containers
//     without shadow geometry; the scrolled state signals through the
//     container color like upstream's color transition)
//   - heights: AppBarSmallTokens.ContainerHeight 64,
//     AppBarMediumTokens.ContainerHeight 112,
//     AppBarLargeTokens.ContainerHeight 152 (flexible variants:
//     MediumFlexible 112/136, LargeFlexible 120/152 — use `height`)
//   - TopAppBarHorizontalPadding = 4 wraps every slot; TopAppBarTitleInset
//     = 16 - 4 = 12; the title placeable adds horizontal padding 4 on both
//     sides → the title text starts at 16dp without a nav icon and at
//     navIconWidth + 4 + 4 = 56dp with a 48dp one
//   - the title/subtitle slot is a Column(horizontalAlignment =
//     titleHorizontalAlignment) when a subtitle exists — M3E small/flexible
//     app bars support subtitles (AppBarSmallTokens.SubtitleFont LabelMedium)
//   - MediumTitleBottomPadding 24 / LargeTitleBottomPadding 28 for the
//     two-rows expanded row (titleVerticalArrangement = Bottom)
//   - placeRelative → RTL mirrors every slot
//
// Deviations: Klaxon has no app-bar scroll-collapse machinery, so a
// two-rows bar always renders the expanded state (collapsedFraction 0:
// the collapsed row's small title is alpha-0/semantics-hidden upstream —
// placing the `title` node in the expanded row only is the identical
// render). Compose pads the title from its text baseline; our slot nodes
// expose no baseline, so `title_bottom_padding` applies to the title
// placeable's bottom edge (upstream's LastBaseline fallback is 0, which
// would sit the title flush to the row bottom — bottom-edge padding is
// the closer spec read).
//
// The bar owns no interaction: the leading/title/subtitle/actions slots
// are ordinary widgets with their own semantics. The widget is a pure
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
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

/// AppBar.kt / tokens, verbatim:
pub const small_height: f32 = 64; // AppBarSmallTokens.ContainerHeight
pub const medium_height: f32 = 112; // AppBarMediumTokens.ContainerHeight
pub const large_height: f32 = 152; // AppBarLargeTokens.ContainerHeight
pub const collapsed_height: f32 = 64; // Medium/LargeAppBarCollapsedHeight (AppBarSmallTokens.ContainerHeight)
pub const medium_title_bottom_padding: f32 = 24; // MediumTitleBottomPadding
pub const large_title_bottom_padding: f32 = 28; // LargeTitleBottomPadding
const padding_h: f32 = 4; // TopAppBarHorizontalPadding
const title_inset: f32 = 12; // TopAppBarTitleInset = 16 - padding_h

pub const AppBarOptions = struct {
    theme: Theme = theme_mod.light,
    /// Expanded container height — small_height (default) / medium_height /
    /// large_height / the flexible tokens' container heights.
    height: f32 = small_height,
    /// Two-rows mode (medium/large TopAppBar): when > 0 the bar is a
    /// collapsed row of `collapsed_height` (nav icon + actions) over an
    /// expanded row of `height - collapsed_height` (title + subtitle,
    /// bottom-aligned with `title_bottom_padding`). Pass collapsed_height /
    /// medium_title_bottom_padding / large_title_bottom_padding.
    collapsed_height: f32 = 0,
    /// MediumTitleBottomPadding (24) / LargeTitleBottomPadding (28) — the
    /// gap under the expanded row's title block (see the baseline note in
    /// the file header).
    title_bottom_padding: f32 = 0,
    leading: ?*Node = null, // navigationIcon slot
    title: ?*Node = null, // title slot (title_text_style content)
    subtitle: ?*Node = null, // subtitle slot under the title (Column)
    actions: ?*Node = null, // actionIcons slot (a row of icon buttons)
    centered: bool = false, // CenterAlignedTopAppBar → titleHorizontalAlignment = CenterHorizontally
    scrolled: bool = false, // content scrolled under the bar (initial state)
};

const AppBarState = struct { opts: AppBarOptions, scrolled: bool, i18n: ?*i18n_mod.I18n = null };

fn stateOf(n: *Node) *AppBarState {
    return @ptrCast(@alignCast(n.state.?));
}

/// The "title" placeable in TopAppBarLayout: a Column(horizontalAlignment)
/// of title + subtitle inside horizontal padding_h — or a plain padded Box
/// when there is no subtitle (identical geometry for one child).
const TitleColumn = struct { col_w: f32, col_h: f32, title: Size, subtitle: Size };

fn measureTitleColumn(s: *const AppBarState, max_placeable_w: f32, loose: Constraints) TitleColumn {
    const inner: Constraints = .{ .max_w = @max(0, max_placeable_w - padding_h * 2), .max_h = loose.max_h };
    var r: TitleColumn = .{ .col_w = 0, .col_h = 0, .title = .{}, .subtitle = .{} };
    if (s.opts.title) |t| {
        r.title = t.measure(inner);
        r.col_w = @max(r.col_w, r.title.w);
        r.col_h += r.title.h;
    }
    if (s.opts.subtitle) |sub| {
        r.subtitle = sub.measure(inner);
        r.col_w = @max(r.col_w, r.subtitle.w);
        r.col_h += r.subtitle.h;
    }
    return r;
}

fn appBarMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const loose = c.loosen();
    // navigationIcon placeable: node + start padding_h; actionIcons: node +
    // end padding_h; title placeable: column + padding_h on both sides.
    var nav_p_w: f32 = padding_h;
    if (s.opts.leading) |leading| nav_p_w += leading.measure(loose).w;
    var act_p_w: f32 = padding_h;
    if (s.opts.actions) |actions| act_p_w += actions.measure(loose).w;
    const title_start = @max(title_inset, nav_p_w);
    const max_title_w = @max(0, c.max_w - title_start - act_p_w);
    const col = measureTitleColumn(s, max_title_w, loose);
    // maxLayoutHeight = max(height, titlePlaceable.height); two-rows adds
    // the collapsed row on top.
    var h = @max(s.opts.height, col.col_h);
    if (s.opts.collapsed_height > 0 and s.opts.collapsed_height < h)
        h = @max(s.opts.height, s.opts.collapsed_height + col.col_h);
    const w = if (std.math.isFinite(c.max_w)) c.max_w else title_start + col.col_w + padding_h * 2 + act_p_w;
    return c.constrain(.{ .w = w, .h = h });
}

/// TopAppBarMeasurePolicy.placeTopAppBar for one row, verbatim: computes
/// LTR placeable positions, then placeRelative-mirrors for RTL.
fn layoutRow(s: *const AppBarState, b: Rect, nav: ?*Node, title_col: bool, actions: ?*Node, bottom_title: bool) void {
    const loose: Constraints = .{ .max_w = b.w, .max_h = b.h };
    const rtl = ui.i18n.direction() == .rtl;
    // navigationIconPlaceable = Box(padding start 4){ nav } — the node sits
    // 4 inside the placeable; an empty slot still occupies the 4dp padding.
    var nav_p_w: f32 = padding_h;
    if (nav) |nd| nav_p_w += nd.measure(loose).w;
    var act_p_w: f32 = padding_h;
    if (actions) |nd| act_p_w += nd.measure(loose).w;
    const title_start = @max(title_inset, nav_p_w);
    const max_title_w = @max(0, b.w - title_start - act_p_w);
    const col = if (title_col) measureTitleColumn(s, max_title_w, loose) else TitleColumn{ .col_w = 0, .col_h = 0, .title = .{}, .subtitle = .{} };
    const title_p_w = col.col_w + padding_h * 2;
    const title_p_h = col.col_h;

    // titleX: titleHorizontalAlignment.align(placeable, maxWidth, Ltr),
    // then repelled by the nav (start) and actions (end) extents.
    var title_x: f32 = if (s.opts.centered) (b.w - title_p_w) / 2 else 0;
    if (title_x < title_start) {
        title_x = title_start; // += startPadding(0) + (start - titleX)
    } else if (title_x + title_p_w > b.w - act_p_w) {
        title_x = b.w - act_p_w - title_p_w; // += startPadding + (maxW-end)-(titleX+pw)
    }
    // titleY: Arrangement.Center or Arrangement.Bottom + titleBottomPadding.
    // Compose measures the padding from the title's baseline; our slots
    // carry no baseline, so it applies to the placeable's bottom edge.
    const title_y: f32 = if (bottom_title)
        @max(0, b.h - title_p_h - s.opts.title_bottom_padding)
    else
        (b.h - title_p_h) / 2;

    const mx = struct {
        rtl: bool,
        w: f32,
        fn f(self: @This(), x: f32, w: f32) f32 {
            return if (self.rtl) self.w - x - w else x;
        }
    }{ .rtl = rtl, .w = b.w };

    if (nav) |nd| {
        const cs = nd.measure(loose);
        // placeable x = startPadding(0); node at placeable + padding_h.
        nd.layout(.{ .x = b.x + mx.f(padding_h, cs.w), .y = b.y + (b.h - cs.h) / 2, .w = cs.w, .h = cs.h });
    }
    if (actions) |nd| {
        const cs = nd.measure(loose);
        // placeable x = maxW - placeableW - endPadding(0); node at placeable
        // x (the 4dp padding trails the content).
        nd.layout(.{ .x = b.x + mx.f(b.w - act_p_w, cs.w), .y = b.y + (b.h - cs.h) / 2, .w = cs.w, .h = cs.h });
    }
    if (title_col) {
        // The column's children align per titleHorizontalAlignment inside
        // col_w (Alignment.Start is RTL-aware upstream — the placeRelative
        // mirror of the whole column produces the same result).
        const col_ltr_x = title_x + padding_h;
        var cy = b.y + title_y;
        if (s.opts.title) |t| {
            const off: f32 = if (s.opts.centered) (col.col_w - col.title.w) / 2 else 0;
            t.layout(.{ .x = b.x + mx.f(col_ltr_x + off, col.title.w), .y = cy, .w = col.title.w, .h = col.title.h });
            cy += col.title.h;
        }
        if (s.opts.subtitle) |sub| {
            const off: f32 = if (s.opts.centered) (col.col_w - col.subtitle.w) / 2 else 0;
            sub.layout(.{ .x = b.x + mx.f(col_ltr_x + off, col.subtitle.w), .y = cy, .w = col.subtitle.w, .h = col.subtitle.h });
        }
    }
}

fn appBarLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    const b = bounds;
    const ch = s.opts.collapsed_height;
    if (ch > 0 and ch < b.h) {
        // TwoRowsTopAppBar at collapsedFraction 0: row 1 (collapsedHeight)
        // carries the nav icon + actions (the upstream small-title renders
        // at alpha 0 / semantics-hidden there, so it is not placed); row 2
        // (expandedHeight - collapsedHeight) carries title + subtitle,
        // bottom-aligned with titleBottomPadding.
        layoutRow(s, .{ .x = b.x, .y = b.y, .w = b.w, .h = ch }, s.opts.leading, false, s.opts.actions, false);
        layoutRow(s, .{ .x = b.x, .y = b.y + ch, .w = b.w, .h = b.h - ch }, null, true, null, true);
    } else {
        // SingleRowTopAppBar: titleVerticalArrangement = Center.
        layoutRow(s, b, s.opts.leading, true, s.opts.actions, false);
    }
}

fn appBarPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const c = s.opts.theme.colors;
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, if (s.scrolled) c.surface_container else c.surface);
}

fn appBarDeinit(n: *Node) void {
    i18n_mod.unsubscribeLocale(stateOf(n).i18n, .{ .fn_ptr = appBarLocaleCb, .userdata = n });
    n.allocator.destroy(stateOf(n));
}

/// The a11y label is tr()-resolved — the locale callback re-attaches in
/// the new locale.
fn appBarLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    ui.semantics.attach(n, .{ .role = .group, .label = i18n_mod.tr("App bar") });
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

const app_bar_vtable = ui.node.VTable{
    .measure = appBarMeasure,
    .layout = appBarLayout,
    .paint = appBarPaint,
    .deinit = appBarDeinit,
};

/// Top app bar (M3E). Slots: `leading` (navigationIcon), `title`,
/// `subtitle` (Column'd under the title), `actions` (actionIcons).
/// `height` = expandedHeight; set `collapsed_height` +
/// `title_bottom_padding` for the TwoRowsTopAppBar medium/large form.
/// Ownership: the slots are attached as children — the tree owns them.
pub fn appBar(allocator: std.mem.Allocator, opts: AppBarOptions) !*Node {
    const node = try Node.create(allocator, &app_bar_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(AppBarState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .scrolled = opts.scrolled };
    node.state = s;
    if (opts.leading) |leading| node.add(leading);
    if (opts.title) |title| node.add(title);
    if (opts.subtitle) |subtitle| node.add(subtitle);
    if (opts.actions) |actions| node.add(actions);
    appBarLocaleCb(node); // Phase 2c — the same path resolves the label
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = appBarLocaleCb, .userdata = node });
    return node;
}

/// Scrolled state: M3E lifts the bar through the container color (surface →
/// surface_container), not elevation. The host calls this when the content
/// scrolls under/away from the bar — e.g. wired to a scroll view's offset.
pub fn setScrolled(n: *Node, scrolled: bool) void {
    const s = stateOf(n);
    if (s.scrolled == scrolled) return;
    s.scrolled = scrolled;
    n.markDirty();
}

pub fn isScrolled(n: *Node) bool {
    return stateOf(n).scrolled;
}

// --- tests ---

test "app_bar: measure fills the width and reports the M3E height" {
    const bar = try appBar(std.testing.allocator, .{});
    defer bar.deinit();
    const m = bar.measure(.{ .max_w = 480, .max_h = 600 });
    try std.testing.expectEqual(@as(f32, 480), m.w);
    try std.testing.expectEqual(@as(f32, 64), m.h);
}

test "app_bar: layout places leading/title/actions per the M3E insets" {
    const text_w = @import("text.zig");
    const leading = try golden.solidBox(std.testing.allocator, 48, 48, 0xFF0000FF);
    const title = try text_w.text(std.testing.allocator, "Title", .{});
    const actions = try golden.solidBox(std.testing.allocator, 96, 48, 0x00FF00FF);
    const bar = try appBar(std.testing.allocator, .{ .leading = leading, .title = title, .actions = actions });
    defer bar.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 480, .h = 64 });
    // leading at start+4, 48x48, vertically centered
    try std.testing.expectEqual(@as(f32, 4), leading.bounds.x);
    try std.testing.expectEqual(@as(f32, 8), leading.bounds.y);
    try std.testing.expectEqual(@as(f32, 48), leading.bounds.w);
    // title at 4 + 48 + 4 = 56
    try std.testing.expectEqual(@as(f32, 56), title.bounds.x);
    // actions end-inset 4: x = 480 - 4 - 96 = 380
    try std.testing.expectEqual(@as(f32, 380), actions.bounds.x);
    try std.testing.expectEqual(@as(f32, 8), actions.bounds.y);
}

test "app_bar: layout without leading insets the title by 16" {
    const text_w = @import("text.zig");
    const title = try text_w.text(std.testing.allocator, "Title", .{});
    const bar = try appBar(std.testing.allocator, .{ .title = title });
    defer bar.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 480, .h = 64 });
    try std.testing.expectEqual(@as(f32, 16), title.bounds.x);
}

test "golden: app_bar paints the M3 surface container color" {
    const text_w = @import("text.zig");
    const bar = try appBar(std.testing.allocator, .{ .title = try text_w.text(std.testing.allocator, "Hello", .{ .color = theme_mod.light.colors.on_surface }) });
    defer bar.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 128, 64);
    defer r.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 128, .h = 64 });
    r.paint(bar, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const surface = theme_mod.light.colors.surface;
    // the whole bar is the surface color except the text ink
    try std.testing.expect(f.countColor(surface) > 128 * 64 - 800);
    try std.testing.expect(f.countNot(surface) > 0); // the title's ink
}

test "golden: scrolled app_bar paints surface_container" {
    const text_w = @import("text.zig");
    const bar = try appBar(std.testing.allocator, .{ .title = try text_w.text(std.testing.allocator, "Hi", .{ .color = theme_mod.light.colors.on_surface }) });
    defer bar.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 128, 64);
    defer r.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 128, .h = 64 });
    setScrolled(bar, true);
    r.paint(bar, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const cs = theme_mod.light.colors;
    try std.testing.expect(f.countColor(cs.surface_container) > 128 * 64 - 800);
    try std.testing.expectEqual(@as(u32, 0), f.countColor(cs.surface));
}

test "app_bar: i18n — the framework label localizes + re-resolves on a locale switch" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"App bar\": \"Barra de aplicaciones\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const n = try appBar(a, .{});
    defer n.deinit();
    try std.testing.expectEqualStrings("Barra de aplicaciones", n.semantics.?.label);
    try i18n.setLocale("en");
    try std.testing.expectEqualStrings("App bar", n.semantics.?.label);
}
