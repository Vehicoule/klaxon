// Icon widget (Phase 1b P0) — a named icon painted as vector geometry in a
// 24dp box, recolored by the theme. Built-in names are geometry (font-
// independent); `codepoint` remains for external/custom icon fonts.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;

pub const IconName = enum {
    play,
    pause,
    stop,
    circle,
    square,
    triangle_right,
    triangle_left,
    triangle_up,
    triangle_down,
    arrow_right,
    arrow_left,
    arrow_up,
    arrow_down,
    chevron_right,
    chevron_left,
    check,
    close,
    menu,
    search,
    star,
    heart,
    plus,
    minus,
    home,
};

/// Unicode codepoint for a built-in icon name (Geometric Shapes / Arrows /
/// Dingbats blocks — covered by DejaVu Sans and the system fonts).
pub fn codepoint(name: IconName) u21 {
    return switch (name) {
        .play => 0x25B6, // ▶
        .pause => 0x275A, // ❚
        .stop => 0x25A0, // ■
        .circle => 0x25CF, // ●
        .square => 0x25A1, // □
        .triangle_right => 0x25B6, // ▶
        .triangle_left => 0x25C0, // ◀
        .triangle_up => 0x25B2, // ▲
        .triangle_down => 0x25BC, // ▼
        .arrow_right => 0x2192, // →
        .arrow_left => 0x2190, // ←
        .arrow_up => 0x2191, // ↑
        .arrow_down => 0x2193, // ↓
        .chevron_right => 0x203A, // ›
        .chevron_left => 0x2039, // ‹
        .check => 0x2713, // ✓
        .close => 0x2715, // ✕
        .menu => 0x2261, // ≡
        .search => 0x2315, // ⌕
        .star => 0x2605, // ★
        .heart => 0x2665, // ♥
        .plus => 0x002B, // +
        .minus => 0x2212, // −
        .home => 0x2302, // ⌂
    };
}

pub const IconOptions = struct {
    size: f32 = 24,
    color: Color = 0x000000FF, // opaque black (0xRRGGBBAA)
    label: []const u8 = "", // accessibility label (alt text, Phase 2c)
};

const IconState = struct {
    name: IconName,
    opts: IconOptions,
};

fn iconMeasure(n: *Node, c: Constraints) Size {
    const s: *IconState = @ptrCast(@alignCast(n.state.?));
    return c.constrain(.{ .w = s.opts.size, .h = s.opts.size });
}
fn iconLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
// Built-in icons paint as VECTOR GEOMETRY in a normalized 24dp box — not
// font glyphs. Text fallback resolves pictographs (▶ ● ★ ♥) through the
// platform color-emoji font: theme-independent bitmaps, per-OS glyph sets,
// platform-dependent metrics. Geometry is deterministic, recolors with the
// theme, and is identical on every backend.
fn iconPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *IconState = @ptrCast(@alignCast(n.state.?));
    const size = s.opts.size;
    const ox = n.bounds.x + (n.bounds.w - size) / 2;
    const oy = n.bounds.y + (n.bounds.h - size) / 2;
    drawIcon(ctx, s.name, ox, oy, size / 24.0, s.opts.color);
}

fn poly(ctx: *kx.Ctx, ox: f32, oy: f32, k: f32, comptime pts: []const [2]f32, color: Color) void {
    var xs: [pts.len]f32 = undefined;
    var ys: [pts.len]f32 = undefined;
    for (pts, 0..) |p, i| {
        xs[i] = ox + p[0] * k;
        ys[i] = oy + p[1] * k;
    }
    ui.paint.fillPolygon(ctx, &xs, &ys, color);
}

fn pline(ctx: *kx.Ctx, ox: f32, oy: f32, k: f32, comptime pts: []const [2]f32, w: f32, color: Color) void {
    var xs: [pts.len]f32 = undefined;
    var ys: [pts.len]f32 = undefined;
    for (pts, 0..) |p, i| {
        xs[i] = ox + p[0] * k;
        ys[i] = oy + p[1] * k;
    }
    ui.paint.strokePolyline(ctx, &xs, &ys, w * k, true, color);
}

/// Draw a built-in icon into a `24*k` box at (ox,oy). Shared by the icon
/// widget and widgets that paint icons inline (navigation rail, FAB, etc.).
pub fn drawIcon(ctx: *kx.Ctx, name: IconName, ox: f32, oy: f32, k: f32, color: Color) void {
    const X = struct {
        fn f(ox_: f32, k_: f32, v: f32) f32 {
            return ox_ + v * k_;
        }
    };
    switch (name) {
        .play, .triangle_right => poly(ctx, ox, oy, k, &.{ .{ 7, 4.5 }, .{ 19, 12 }, .{ 7, 19.5 } }, color),
        .triangle_left => poly(ctx, ox, oy, k, &.{ .{ 17, 4.5 }, .{ 5, 12 }, .{ 17, 19.5 } }, color),
        .triangle_up => poly(ctx, ox, oy, k, &.{ .{ 12, 5 }, .{ 19.5, 18 }, .{ 4.5, 18 } }, color),
        .triangle_down => poly(ctx, ox, oy, k, &.{ .{ 4.5, 6 }, .{ 19.5, 6 }, .{ 12, 19 } }, color),
        .pause => {
            ui.paint.fillRect(ctx, X.f(ox, k, 6.5), X.f(oy, k, 4.5), 4 * k, 15 * k, color);
            ui.paint.fillRect(ctx, X.f(ox, k, 13.5), X.f(oy, k, 4.5), 4 * k, 15 * k, color);
        },
        .stop => ui.paint.fillRect(ctx, X.f(ox, k, 5), X.f(oy, k, 5), 14 * k, 14 * k, color),
        .circle => ui.paint.fillRRect(ctx, X.f(ox, k, 4), X.f(oy, k, 4), 16 * k, 16 * k, 8 * k, color),
        .square => ui.paint.strokeRRect(ctx, X.f(ox, k, 4.5), X.f(oy, k, 4.5), 15 * k, 15 * k, 1 * k, 2 * k, color),
        .arrow_right => poly(ctx, ox, oy, k, &.{ .{ 4, 10.5 }, .{ 14, 10.5 }, .{ 14, 6.5 }, .{ 21, 12 }, .{ 14, 17.5 }, .{ 14, 13.5 }, .{ 4, 13.5 } }, color),
        .arrow_left => poly(ctx, ox, oy, k, &.{ .{ 20, 10.5 }, .{ 10, 10.5 }, .{ 10, 6.5 }, .{ 3, 12 }, .{ 10, 17.5 }, .{ 10, 13.5 }, .{ 20, 13.5 } }, color),
        .arrow_up => poly(ctx, ox, oy, k, &.{ .{ 10.5, 20 }, .{ 10.5, 10 }, .{ 6.5, 10 }, .{ 12, 3 }, .{ 17.5, 10 }, .{ 13.5, 10 }, .{ 13.5, 20 } }, color),
        .arrow_down => poly(ctx, ox, oy, k, &.{ .{ 10.5, 4 }, .{ 10.5, 14 }, .{ 6.5, 14 }, .{ 12, 21 }, .{ 17.5, 14 }, .{ 13.5, 14 }, .{ 13.5, 4 } }, color),
        .chevron_right => pline(ctx, ox, oy, k, &.{ .{ 9, 5 }, .{ 16, 12 }, .{ 9, 19 } }, 2, color),
        .chevron_left => pline(ctx, ox, oy, k, &.{ .{ 15, 5 }, .{ 8, 12 }, .{ 15, 19 } }, 2, color),
        .check => pline(ctx, ox, oy, k, &.{ .{ 4.5, 12.5 }, .{ 10, 18 }, .{ 19.5, 7 } }, 2.2, color),
        .close => {
            pline(ctx, ox, oy, k, &.{ .{ 6, 6 }, .{ 18, 18 } }, 2, color);
            pline(ctx, ox, oy, k, &.{ .{ 18, 6 }, .{ 6, 18 } }, 2, color);
        },
        .menu => {
            pline(ctx, ox, oy, k, &.{ .{ 4, 6.7 }, .{ 20, 6.7 } }, 2, color);
            pline(ctx, ox, oy, k, &.{ .{ 4, 12 }, .{ 20, 12 } }, 2, color);
            pline(ctx, ox, oy, k, &.{ .{ 4, 17.3 }, .{ 20, 17.3 } }, 2, color);
        },
        .search => {
            ui.paint.strokeRRect(ctx, X.f(ox, k, 5.5), X.f(oy, k, 5.5), 11 * k, 11 * k, 5.5 * k, 2 * k, color);
            pline(ctx, ox, oy, k, &.{ .{ 14.8, 14.8 }, .{ 20, 20 } }, 2, color);
        },
        .star => poly(ctx, ox, oy, k, &.{ .{ 12, 2 }, .{ 14.9, 8.6 }, .{ 22, 9.3 }, .{ 16.7, 14.1 }, .{ 18.5, 21 }, .{ 12, 17.3 }, .{ 5.5, 21 }, .{ 7.3, 14.1 }, .{ 2, 9.3 }, .{ 9.1, 8.6 } }, color),
        .heart => poly(ctx, ox, oy, k, &.{ .{ 12, 21 }, .{ 4.5, 13.5 }, .{ 2, 9.5 }, .{ 2.5, 5.5 }, .{ 5.5, 3 }, .{ 9, 3.5 }, .{ 12, 7 }, .{ 15, 3.5 }, .{ 18.5, 3 }, .{ 21.5, 5.5 }, .{ 22, 9.5 }, .{ 19.5, 13.5 } }, color),
        .plus => poly(ctx, ox, oy, k, &.{ .{ 10.5, 4.5 }, .{ 13.5, 4.5 }, .{ 13.5, 10.5 }, .{ 19.5, 10.5 }, .{ 19.5, 13.5 }, .{ 13.5, 13.5 }, .{ 13.5, 19.5 }, .{ 10.5, 19.5 }, .{ 10.5, 13.5 }, .{ 4.5, 13.5 }, .{ 4.5, 10.5 }, .{ 10.5, 10.5 } }, color),
        .minus => ui.paint.fillRect(ctx, X.f(ox, k, 4.5), X.f(oy, k, 10.5), 15 * k, 3 * k, color),
        .home => poly(ctx, ox, oy, k, &.{ .{ 12, 3 }, .{ 22, 12 }, .{ 19.5, 12 }, .{ 19.5, 21 }, .{ 14.5, 21 }, .{ 14.5, 15 }, .{ 9.5, 15 }, .{ 9.5, 21 }, .{ 4.5, 21 }, .{ 4.5, 12 }, .{ 2, 12 } }, color),
    }
}
fn iconDeinit(n: *Node) void {
    n.allocator.destroy(@as(*IconState, @ptrCast(@alignCast(n.state.?))));
}
const icon_vtable = ui.node.VTable{ .measure = iconMeasure, .layout = iconLayout, .paint = iconPaint, .deinit = iconDeinit };

pub fn icon(allocator: std.mem.Allocator, name: IconName, opts: IconOptions) !*Node {
    const node = try Node.create(allocator, &icon_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(IconState);
    errdefer allocator.destroy(s);
    s.* = .{ .name = name, .opts = opts };
    node.state = s;
    ui.semantics.attach(node, .{ .role = .image, .label = opts.label }); // Phase 2c
    return node;
}

/// Recolor a live icon (signal-driven widgets recolor their icon on state
/// change — e.g. the M3E icon toggle button's checked state).
pub fn setColor(n: *Node, color: Color) void {
    const s: *IconState = @ptrCast(@alignCast(n.state.?));
    s.opts.color = color;
    n.markDirty();
}

// --- tests ---

test "icon codepoints are stable (golden data)" {
    try std.testing.expectEqual(@as(u21, 0x25CF), codepoint(.circle));
    try std.testing.expectEqual(@as(u21, 0x25A1), codepoint(.square));
    try std.testing.expectEqual(@as(u21, 0x2192), codepoint(.arrow_right));
    try std.testing.expectEqual(@as(u21, 0x2713), codepoint(.check));
}

test "icon measures a square of its size" {
    const ic = try icon(std.testing.allocator, .star, .{ .size = 32 });
    defer ic.deinit();
    const size = ic.measure(.{});
    try std.testing.expectEqual(@as(f32, 32), size.w);
    try std.testing.expectEqual(@as(f32, 32), size.h);
}

test "golden: icon renders ink centered in its bounds" {
    const bg = 0x101010FF;
    const white = 0xFFFFFFFF;
    const root = try icon(std.testing.allocator, .circle, .{ .size = 24, .color = white });
    var frame = try golden.render(std.testing.allocator, root, 64, 64, bg);
    defer frame.deinit();
    // ● (U+25CF) is covered by DejaVu/system fonts: ink must be present,
    // roughly centered in the 64x64 canvas.
    const ink = frame.countNotIn(.{ .x = 16, .y = 16, .w = 32, .h = 32 }, bg);
    try std.testing.expect(ink > 0);
    try std.testing.expectEqual(@as(u64, 0), frame.countNotIn(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, bg));
}
