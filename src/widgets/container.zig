// Container widget (Phase 1b P0) — decoration (color, corner radius, border)
// + padding around a single child. Fill semantics: the child's bounds are the
// inner rect (see widgets/layout.zig for the container contract).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const golden = @import("../golden.zig");
const layout_w = @import("layout.zig");
const shapes = @import("../ui/shapes.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const EdgeInsets = ui.layout.EdgeInsets;
const Color = ui.paint.Color;

pub const ContainerOptions = struct {
    color: ?Color = null,
    radius: f32 = 0,
    /// M3E expressive shape (a ui.shapes RoundedPolygon preset) — replaces
    /// `radius`: the normalized unit-box outline scales to the bounds at
    /// paint time through kx_fill_path. A non-uniform bounds stretches the
    /// shape (and the border width along with it).
    shape: ?shapes.Preset = null,
    border_color: ?Color = null,
    border_width: f32 = 0,
    padding: EdgeInsets = .{},
};

const ContainerState = struct {
    opts: ContainerOptions,
    /// The emitted unit-space path for `opts.shape` — built lazily on the
    /// first paint (the widget may be created off-allocator in tests where
    /// no canvas exists), reused for the widget's life: paint allocates
    /// nothing. The emitted slices cover the whole allocations — deinit
    /// frees them directly.
    path_pts: []f32 = &.{},
    path_verbs: []i32 = &.{},
};

fn containerMeasure(n: *Node, c: Constraints) Size {
    const s: *ContainerState = @ptrCast(@alignCast(n.state.?));
    const inner = c.deflateEdge(s.opts.padding);
    var size = Size{};
    if (n.children.items.len > 0) {
        const cs = n.children.items[0].measure(inner);
        size = .{ .w = cs.w + s.opts.padding.hSum(), .h = cs.h + s.opts.padding.vSum() };
    }
    return c.constrain(size);
}
fn containerLayout(n: *Node, bounds: Rect) void {
    const s: *ContainerState = @ptrCast(@alignCast(n.state.?));
    if (n.children.items.len == 0) return;
    n.children.items[0].layout(.{
        .x = bounds.x + s.opts.padding.left,
        .y = bounds.y + s.opts.padding.top,
        .w = @max(0, bounds.w - s.opts.padding.hSum()),
        .h = @max(0, bounds.h - s.opts.padding.vSum()),
    });
}
fn containerPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *ContainerState = @ptrCast(@alignCast(n.state.?));
    const b = n.bounds;
    const bw = s.opts.border_width;
    if (s.opts.shape != null) {
        paintShaped(n, s, ctx, b);
        return;
    }
    if (s.opts.border_color) |border| {
        // Border = outer shape in the border color; the fill covers the inside.
        if (s.opts.radius > 0) {
            ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, s.opts.radius, border);
        } else {
            ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, border);
        }
        if (s.opts.color) |fill| {
            const inner = Rect{ .x = b.x + bw, .y = b.y + bw, .w = @max(0, b.w - bw * 2), .h = @max(0, b.h - bw * 2) };
            if (s.opts.radius > 0) {
                ui.paint.fillRRect(ctx, inner.x, inner.y, inner.w, inner.h, @max(0, s.opts.radius - bw), fill);
            } else {
                ui.paint.fillRect(ctx, inner.x, inner.y, inner.w, inner.h, fill);
            }
        }
    } else if (s.opts.color) |fill| {
        if (s.opts.radius > 0) {
            ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, s.opts.radius, fill);
        } else {
            ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, fill);
        }
    }
    // Children paint after (Node.paint), on top of the decoration.
}

/// Expressive-shape decoration: the preset's emitted unit-box path fills (and
/// strokes) through the canvas transform — bounds-space raster, zero per-frame
/// allocation (the path is emitted once into owned scratch).
fn paintShaped(n: *Node, s: *ContainerState, ctx: *kx.Ctx, b: Rect) void {
    if (s.path_pts.len == 0) {
        var poly = shapes.presetShape(n.allocator, s.opts.shape.?) catch return;
        defer poly.deinit();
        const counts = shapes.pathCounts(poly.cubics.len);
        const pts = n.allocator.alloc(f32, counts.pts) catch return;
        const verbs = n.allocator.alloc(i32, counts.verbs) catch {
            n.allocator.free(pts);
            return;
        };
        const emitted = poly.emitPath(pts, verbs);
        s.path_pts = @constCast(emitted.pts);
        s.path_verbs = @constCast(emitted.verbs);
    }
    ui.paint.save(ctx);
    ui.paint.translate(ctx, b.x + b.w / 2, b.y + b.h / 2);
    ui.paint.scale(ctx, b.w, b.h);
    ui.paint.translate(ctx, -0.5, -0.5);
    if (s.opts.border_color) |border| {
        // The border strokes inside the scaled space: a non-square bounds
        // stretches its width along the long axis (documented on the option).
        const sw = s.opts.border_width / @min(b.w, b.h);
        ui.paint.strokePath(ctx, s.path_pts, s.path_verbs, sw, border, false);
        if (s.opts.color) |fill|
            ui.paint.fillPath(ctx, s.path_pts, s.path_verbs, fill, false);
    } else if (s.opts.color) |fill| {
        ui.paint.fillPath(ctx, s.path_pts, s.path_verbs, fill, false);
    }
    ui.paint.restore(ctx);
}
fn containerDeinit(n: *Node) void {
    const s: *ContainerState = @ptrCast(@alignCast(n.state.?));
    if (s.path_pts.len > 0) n.allocator.free(s.path_pts);
    if (s.path_verbs.len > 0) n.allocator.free(s.path_verbs);
    n.allocator.destroy(s);
}
// auto_retain: the decoration paints strictly inside bounds and the child
// layout is deterministic — a clean Container subtree can replay its cached
// raster (e.g. a static card next to a repainting sibling).
const container_vtable = ui.node.VTable{ .measure = containerMeasure, .layout = containerLayout, .paint = containerPaint, .deinit = containerDeinit, .auto_retain = true, .measure_pure = true };

pub fn container(allocator: std.mem.Allocator, opts: ContainerOptions) !*Node {
    const node = try Node.create(allocator, &container_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(ContainerState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts };
    node.state = s;
    return node;
}

// --- tests ---

test "container measure adds padding around the child" {
    const root = try container(std.testing.allocator, .{ .padding = EdgeInsets.all(8) });
    defer root.deinit();
    root.add(try golden.solidBox(std.testing.allocator, 32, 32, 0xFF000000));
    const size = root.measure(.{ .max_w = 128, .max_h = 128 });
    try std.testing.expectEqual(@as(f32, 48), size.w);
    try std.testing.expectEqual(@as(f32, 48), size.h);
}

test "container layout insets the child by the padding" {
    const root = try container(std.testing.allocator, .{ .padding = EdgeInsets{ .left = 4, .top = 6, .right = 8, .bottom = 10 } });
    defer root.deinit();
    const child = try golden.solidBox(std.testing.allocator, 32, 32, 0xFF000000);
    root.add(child);
    root.layout(.{ .x = 0, .y = 0, .w = 64, .h = 64 });
    try std.testing.expectEqual(@as(f32, 4), child.bounds.x);
    try std.testing.expectEqual(@as(f32, 6), child.bounds.y);
    try std.testing.expectEqual(@as(f32, 52), child.bounds.w); // 64 - 4 - 8
    try std.testing.expectEqual(@as(f32, 48), child.bounds.h); // 64 - 6 - 10
}

test "golden: container paints fill + border exactly (radius 0)" {
    const bg = 0x000000FF;
    const red = 0xFF0000FF;
    const blue = 0x0000FFFF;
    // Container fills the root; padding insets it to (10,10,100,100).
    const root = try layout_w.padding(std.testing.allocator, EdgeInsets.all(10));
    const box = try container(std.testing.allocator, .{ .color = red, .border_color = blue, .border_width = 2 });
    root.add(box);
    var frame = try golden.render(std.testing.allocator, root, 120, 120, bg);
    defer frame.deinit();
    try std.testing.expectEqual(@as(u64, 100 * 100 - 96 * 96), frame.countColor(blue)); // 2px border ring
    try std.testing.expectEqual(@as(u64, 96 * 96), frame.countColor(red)); // fill
    try std.testing.expectEqual(blue, frame.pixelAt(10, 10));
    try std.testing.expectEqual(red, frame.pixelAt(12, 12));
    try std.testing.expectEqual(bg, frame.pixelAt(9, 9)); // outside the container
}

test "golden: container with a child paints the child on top of the fill" {
    const bg = 0x000000FF;
    const red = 0xFF0000FF;
    const green = 0x00FF00FF;
    const root = try container(std.testing.allocator, .{ .color = red });
    root.add(try golden.solidBox(std.testing.allocator, 10, 10, green));
    var frame = try golden.render(std.testing.allocator, root, 40, 40, bg);
    defer frame.deinit();
    try std.testing.expectEqual(green, frame.pixelAt(5, 5)); // child (fills the container)
    try std.testing.expectEqual(@as(u64, 40 * 40), frame.countColor(green));
    try std.testing.expectEqual(@as(u64, 0), frame.countColor(red)); // fully covered
}

test "golden: container shape fills the preset outline, not the rect" {
    const bg = 0x000000FF;
    const red = 0xFF0000FF;
    const root = try container(std.testing.allocator, .{ .color = red, .shape = .diamond });
    var frame = try golden.render(std.testing.allocator, root, 60, 60, bg);
    defer frame.deinit();
    // Diamond: the center is filled, the corner is background — a rounded
    // rect would cover the corner; the polygon path must not.
    try std.testing.expectEqual(red, frame.pixelAt(30, 30));
    try std.testing.expectEqual(bg, frame.pixelAt(2, 2));
    try std.testing.expectEqual(bg, frame.pixelAt(57, 2));
    // Edge midpoint is the diamond's vertex — covered.
    try std.testing.expectEqual(red, frame.pixelAt(30, 1));
}

test "golden: container shape + border strokes the outline" {
    const bg = 0x000000FF;
    const red = 0xFF0000FF;
    const blue = 0x0000FFFF;
    const root = try container(std.testing.allocator, .{ .color = red, .shape = .diamond, .border_color = blue, .border_width = 4 });
    var frame = try golden.render(std.testing.allocator, root, 60, 60, bg);
    defer frame.deinit();
    try std.testing.expectEqual(red, frame.pixelAt(30, 30));
    try std.testing.expectEqual(bg, frame.pixelAt(2, 2));
    // The outline stroke is anti-aliased — count any blue ink rather than
    // probing a single pixel (the stroke ring is non-empty).
    try std.testing.expect(frame.countColor(blue) > 0);
}
