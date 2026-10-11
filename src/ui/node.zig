// Node — retained widget tree with dirty flags (ADR-0004).
// Zig has no GC: the tree is retained and mutated in place. Dirty flags drive
// the frame loop — a clean tree renders 0 frames (0 wakeups at idle).
const std = @import("std");
const kx = @import("../kx.zig");
const paint_mod = @import("paint.zig");
const layout_mod = @import("layout.zig");
const input_mod = @import("input.zig");
const scroll_mod = @import("scroll.zig");
const semantics_mod = @import("semantics.zig");

pub const Paint = paint_mod.Paint;
pub const Constraints = layout_mod.Constraints;
pub const Size = layout_mod.Size;
pub const Axis = layout_mod.Axis;

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
    }

    pub fn main(r: Rect, axis: Axis) f32 {
        return switch (axis) {
            .horizontal => r.w,
            .vertical => r.h,
        };
    }

    pub fn cross(r: Rect, axis: Axis) f32 {
        return switch (axis) {
            .horizontal => r.h,
            .vertical => r.w,
        };
    }
};

/// Bounding box of two rects (the swept region of a monotonic translation).
pub fn rectUnion(a: Rect, b: Rect) Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + a.w, b.x + b.w);
    const y1 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// Pointer cursor shapes (Phase 2d-0.5): the host maps the hovered node to
/// a system cursor on desktop (SDL). A widget overrides via VTable.cursor;
/// otherwise the semantic role decides (.button/.link → hand, .text_field →
/// ibeam — ui/input.zig cursorForNode); the fallback is the default arrow.
pub const PointerCursor = enum { default, hand, ibeam, move, wait };

pub const VTable = struct {
    measure: *const fn (node: *Node, c: Constraints) Size,
    layout: *const fn (node: *Node, bounds: Rect) void,
    paint: *const fn (node: *Node, ctx: *kx.Ctx) void,
    deinit: ?*const fn (node: *Node) void = null,
    /// Pointer input (Phase 1c, dispatched by ui/input.zig). Returns true if
    /// handled — bubbling to the parent stops.
    on_pointer: ?*const fn (node: *Node, ev: input_mod.PointerEvent) bool = null,
    /// Keyboard input (Phase 1c) — delivered to the focused node's chain.
    on_key: ?*const fn (node: *Node, ev: input_mod.KeyEvent) bool = null,
    /// Scroll (wheel) input (Phase 1f) — bubbles up until a scrollable
    /// reports it handled.
    on_scroll: ?*const fn (node: *Node, ev: input_mod.ScrollEvent) bool = null,
    /// Pointer cursor override (Phase 2d-0.5, desktop): when set, wins over
    /// the semantic-role mapping (ui/input.zig cursorForNode).
    cursor: ?*const fn (node: *Node) PointerCursor = null,
    /// Scrollable interface (Phase 1f): the Scrollbar drives any scrollable
    /// through these hooks — no direct widget-to-widget dependency.
    scroll_info: ?*const fn (node: *Node) scroll_mod.ScrollInfo = null,
    scroll_set_offset: ?*const fn (node: *Node, offset: f32) void = null,
    /// Paint-time wrapper around the children's paint (Phase 1e): called
    /// after this node's own paint, before the children's — e.g. save +
    /// translate for an animated offset. Must be balanced with
    /// post_children_paint (the canvas state is restored right after).
    pre_children_paint: ?*const fn (node: *Node, ctx: *kx.Ctx) void = null,
    post_children_paint: ?*const fn (node: *Node, ctx: *kx.Ctx) void = null,
    /// Popup overlay pass (Phase 2d.3 PR D2): the host paints the open
    /// popup's hook after the whole tree (above later siblings — a popup's
    /// content overflows its anchor), before the focus ring. Children with
    /// defer_paint paint here, not in the normal children pass.
    paint_overlay: ?*const fn (node: *Node, ctx: *kx.Ctx) void = null,
    /// Map a rect from this node's child space into its parent space — the
    /// inverse of the paint transform (pre_children_paint). Dirty marks
    /// under a transformed ancestor land at the child's VISIBLE position.
    map_paint_rect: ?*const fn (node: *Node, rect: Rect) Rect = null,
    /// Effective hit-test rect (defaults to bounds). Transformed widgets
    /// return where their children actually paint.
    hit_bounds: ?*const fn (node: *Node) Rect = null,
    /// Map a point from this node's space into its children's coordinate
    /// space (matches the paint transform, inverted). Hit-testing through a
    /// transformed subtree lands on the visual position.
    pre_children_hit: ?*const fn (node: *Node, px: f32, py: f32) HitPoint = null,
};

/// A point in a transformed coordinate space (hit-testing, Phase 1e).
pub const HitPoint = struct { x: f32, y: f32 };

pub const Node = struct {
    allocator: std.mem.Allocator,
    parent: ?*Node = null,
    children: std.array_list.Managed(*Node),
    bounds: Rect = .{},
    dirty: bool = true,
    layout_dirty: bool = true,
    visible: bool = true, // invisible subtrees are neither painted nor hit-tested
    /// Flex weight on the parent's main axis (0 = natural size). Set by the
    /// Expanded wrapper (widgets/layout.zig); the flex algorithms distribute
    /// the REMAINING main space to flex children by weight.
    flex: u32 = 0,
    vtable: *const VTable,
    state: ?*anyopaque = null,
    /// Accessibility descriptor (Phase 2c, owned — freed at deinit). Widgets
    /// attach one in their factory; the semantic tree flattens the widget
    /// tree for assistive tech.
    semantics: ?*semantics_mod.Semantics = null,
    /// Hide this subtree from the semantic tree (decorative, Phase 2c).
    exclude_semantics: bool = false,
    /// Internal chrome owned by a widget (a tooltip bubble, a popup): the
    /// node is part of the tree (paint/hit-test) but is NOT document data —
    /// the registry's treeToValue skips it (the widget rebuilds it).
    internal: bool = false,
    /// Defer this node's paint to the popup overlay pass: the parent's
    /// children paint loop skips it, and the host paints the open popup's
    /// paint_overlay hook AFTER the tree — so popup content overflowing its
    /// anchor (a menu panel over later siblings) renders above them. The
    /// node still hit-tests normally (the router's popup barrier hit-tests
    /// popup children outside the ancestor-bounds gate).
    defer_paint: bool = false,
    // Dirty-rect (Phase 1e): the root accumulates the damaged region — the
    // union of every dirty mark's rect — and the host repaints the tree
    // clipped to it (the surface is retained between frames).
    damage: Rect = .{},
    damage_valid: bool = false,
    /// Paint that extends BEYOND the bounds (a floating label's upper half,
    /// a cutout stroke margin): markDirty damages the bounds EXPANDED by
    /// these insets (negative values would shrink — never set them). Widgets
    /// painting outside their bounds set this so focus/state changes repaint
    /// the overflow too (2d.2 PR C2: the outlined text field's cutout label).
    damage_overflow: layout_mod.EdgeInsets = .{},

    pub fn create(allocator: std.mem.Allocator, vtable: *const VTable) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .allocator = allocator,
            .children = std.array_list.Managed(*Node).init(allocator),
            .vtable = vtable,
        };
        return node;
    }

    /// Append a child. OOM while building the tree is fatal (same as Flutter).
    pub fn add(node: *Node, child: *Node) void {
        child.parent = node;
        node.children.append(child) catch @panic("klaxon: out of memory");
        node.markLayoutDirty();
        node.markDirty();
    }

    /// Insert a child at `index` (clamped to the end). Same ownership contract
    /// as add(): the child is parented, not owned. Re-insertion at the original
    /// index restores paint order (hero flight, Phase 2a).
    pub fn insert(node: *Node, index: usize, child: *Node) void {
        child.parent = node;
        const i = @min(index, node.children.items.len);
        node.children.insert(i, child) catch @panic("klaxon: out of memory");
        node.markLayoutDirty();
        node.markDirty();
    }

    /// Remove a child. The child is NOT deinited (the caller owns it) and its
    /// parent pointer is cleared. Returns false if it was not a child.
    /// Dynamic UI (conditional children, theme rebuilds) needs this: the tree
    /// is retained, but subtrees come and go.
    pub fn remove(node: *Node, child: *Node) bool {
        for (node.children.items, 0..) |c, i| {
            if (c == child) {
                _ = node.children.orderedRemove(i);
                child.parent = null;
                node.markLayoutDirty();
                node.markDirty();
                return true;
            }
        }
        return false;
    }

    fn markDirtyUp(node: *Node) void {
        var n = node;
        while (true) {
            n.dirty = true;
            const p = n.parent orelse return;
            n = p;
        }
    }

    fn unionDamage(root: *Node, rect: Rect) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        root.damage = if (root.damage_valid) rectUnion(root.damage, rect) else rect;
        root.damage_valid = true;
    }

    /// Map a rect (given in the node's parent space) up to the root, applying
    /// every transformed ancestor's map_paint_rect, and union it into the
    /// root's damage accumulator.
    fn damageRectUp(node: *Node, rect: Rect) void {
        var r = rect;
        var n = node;
        while (n.parent) |p| {
            if (p.vtable.map_paint_rect) |m| r = m(p, r);
            n = p;
        }
        unionDamage(n, r);
    }

    /// Mark this node (and its ancestors) dirty. The node's own bounds
    /// (expanded by damage_overflow) — mapped to its visible position through
    /// any transformed ancestors — are unioned into the root's damage region.
    pub fn markDirty(node: *Node) void {
        markDirtyUp(node);
        const o = node.damage_overflow;
        damageRectUp(node, .{
            .x = node.bounds.x - o.left,
            .y = node.bounds.y - o.top,
            .w = node.bounds.w + o.left + o.right,
            .h = node.bounds.h + o.top + o.bottom,
        });
    }

    /// Mark dirty + record an explicit damaged rect (given in the node's
    /// parent space) — e.g. an animated offset sweeping old → new position:
    /// the union of both regions.
    pub fn markDirtyRect(node: *Node, rect: Rect) void {
        markDirtyUp(node);
        damageRectUp(node, rect);
    }

    /// Clear the root's damage accumulator (called by the host after painting).
    pub fn clearDamage(node: *Node) void {
        node.damage = .{};
        node.damage_valid = false;
    }

    pub fn markLayoutDirty(node: *Node) void {
        node.layout_dirty = true;
        if (node.parent) |p| p.markLayoutDirty();
    }

    pub fn measure(node: *Node, c: Constraints) Size {
        return node.vtable.measure(node, c);
    }

    pub fn layout(node: *Node, bounds: Rect) void {
        node.bounds = bounds;
        node.layout_dirty = false;
        node.vtable.layout(node, bounds);
    }

    /// Paint the subtree and clear dirty flags. The whole tree paints every
    /// frame; the host clips to the damage region (dirty-rect, Phase 1e) and
    /// the vtable's pre/post_children_paint hooks wrap the children's paint
    /// in a canvas transform (animated offsets/scales).
    pub fn paint(node: *Node, ctx: *kx.Ctx) void {
        if (!node.visible) return;
        node.vtable.paint(node, ctx);
        if (node.vtable.pre_children_paint) |pre| pre(node, ctx);
        for (node.children.items) |child| {
            if (child.defer_paint) continue; // paints in the popup overlay pass
            child.paint(ctx);
        }
        if (node.vtable.post_children_paint) |post| post(node, ctx);
        node.dirty = false;
    }

    /// Deepest visible node containing the point (children are painted last,
    /// on top). Transformed subtrees (animated offset/scale) hit-test at
    /// their VISUAL position: hit_bounds + pre_children_hit mirror the paint
    /// transform.
    pub fn hitTest(node: *Node, px: f32, py: f32) ?*Node {
        if (!node.visible) return null;
        const b = if (node.vtable.hit_bounds) |hb| hb(node) else node.bounds;
        if (!b.contains(px, py)) return null;
        var cx = px;
        var cy = py;
        if (node.vtable.pre_children_hit) |pre| {
            const p = pre(node, px, py);
            cx = p.x;
            cy = p.y;
        }
        var i = node.children.items.len;
        while (i > 0) {
            i -= 1;
            if (node.children.items[i].hitTest(cx, cy)) |hit| return hit;
        }
        return node;
    }

    /// A hit-test result: the node + the point in the HIT NODE's parent
    /// space (transformed subtrees map viewport coordinates through their
    /// ancestors).
    pub const MappedHit = struct { node: *Node, x: f32, y: f32 };

    /// Hit-test that also returns the point in the hit node's parent space —
    /// the router delivers pointer events with those local coordinates so
    /// scrolled/transformed controls receive events at their visual position.
    pub fn hitTestMapped(node: *Node, px: f32, py: f32) ?MappedHit {
        if (!node.visible) return null;
        const b = if (node.vtable.hit_bounds) |hb| hb(node) else node.bounds;
        if (!b.contains(px, py)) return null;
        var cx = px;
        var cy = py;
        if (node.vtable.pre_children_hit) |pre| {
            const p = pre(node, px, py);
            cx = p.x;
            cy = p.y;
        }
        var i = node.children.items.len;
        while (i > 0) {
            i -= 1;
            if (node.children.items[i].hitTestMapped(cx, cy)) |hit| return hit;
        }
        return .{ .node = node, .x = px, .y = py };
    }

    /// Map a window-space point into `node`'s parent space: applies every
    /// strict ancestor's pre_children_hit, root-first. Used to deliver
    /// pointer events with local coordinates to captured nodes (Phase 1f).
    pub fn mapPointToParentSpace(node: *Node, px: f32, py: f32) HitPoint {
        var chain: [64]*Node = undefined;
        var depth: usize = 0;
        var n = node.parent;
        while (n) |p| : (n = p.parent) {
            if (depth < chain.len) {
                chain[depth] = p;
                depth += 1;
            }
        }
        var x = px;
        var y = py;
        while (depth > 0) {
            depth -= 1;
            const a = chain[depth];
            if (a.vtable.pre_children_hit) |pre| {
                const p = pre(a, x, y);
                x = p.x;
                y = p.y;
            }
        }
        return .{ .x = x, .y = y };
    }

    /// Map a rect (in the node's parent space) to window space: applies every
    /// transformed ancestor's map_paint_rect (the visual position). Used by
    /// the focus ring and semantic activation (Phase 2c).
    pub fn mapRectToRoot(node: *Node, rect: Rect) Rect {
        var r = rect;
        var n = node;
        while (n.parent) |p| {
            if (p.vtable.map_paint_rect) |m| r = m(p, r);
            n = p;
        }
        return r;
    }

    pub fn deinit(node: *Node) void {
        // Drop router references (capture/hover/focus/popup) BEFORE anything
        // is freed — virtualized lists destroy captured items on scroll.
        input_mod.releaseNode(node);
        semantics_mod.focusNodeDestroyed(node); // drop the a11y focus if it was focused (Phase 2c)
        for (node.children.items) |child| child.deinit();
        node.children.deinit();
        if (node.semantics) |sem| node.allocator.destroy(sem);
        if (node.vtable.deinit) |d| d(node);
        node.allocator.destroy(node);
    }
};

// --- tests (stub leaf widget) ---

const TestState = struct { w: f32, h: f32 };

fn testMeasure(n: *Node, c: Constraints) Size {
    const s: *TestState = @ptrCast(@alignCast(n.state.?));
    return c.constrain(.{ .w = s.w, .h = s.h });
}
fn testLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn testPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}
fn testDeinit(n: *Node) void {
    std.testing.allocator.destroy(@as(*TestState, @ptrCast(@alignCast(n.state.?))));
}
const test_vtable = VTable{ .measure = testMeasure, .layout = testLayout, .paint = testPaint, .deinit = testDeinit };

fn testNode(w: f32, h: f32) !*Node {
    const node = try Node.create(std.testing.allocator, &test_vtable);
    const s = try std.testing.allocator.create(TestState);
    s.* = .{ .w = w, .h = h };
    node.state = s;
    return node;
}

test "remove detaches a child without deiniting it" {
    const root = try testNode(100, 100);
    defer root.deinit();
    const a = try testNode(10, 10);
    const b = try testNode(10, 10);
    root.add(a);
    root.add(b);
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
    try std.testing.expect(root.remove(a));
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expectEqual(b, root.children.items[0]);
    try std.testing.expect(a.parent == null);
    try std.testing.expect(!root.remove(a)); // already detached
    a.deinit(); // caller owns the detached child
    // the remaining subtree still deinits cleanly
}

test "insert places a child at the index and keeps paint order" {
    const root = try testNode(100, 100);
    defer root.deinit();
    const a = try testNode(10, 10);
    const b = try testNode(10, 10);
    const c = try testNode(10, 10);
    root.add(a);
    root.add(c);
    root.insert(1, b);
    try std.testing.expectEqual(@as(usize, 3), root.children.items.len);
    try std.testing.expectEqual(a, root.children.items[0]);
    try std.testing.expectEqual(b, root.children.items[1]);
    try std.testing.expectEqual(c, root.children.items[2]);
    try std.testing.expectEqual(root, b.parent.?);
    // clamped past the end
    const d = try testNode(10, 10);
    root.insert(99, d);
    try std.testing.expectEqual(d, root.children.items[3]);
}

test "markDirty propagates up to the root" {
    const root = try testNode(100, 100);
    defer root.deinit();
    const child = try testNode(10, 10);
    root.add(child);
    root.dirty = false;
    child.markDirty();
    try std.testing.expect(root.dirty);
    try std.testing.expect(child.dirty);
}

test "hitTest returns the deepest node containing the point" {
    const root = try testNode(100, 100);
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    const child = try testNode(50, 50);
    root.add(child);
    child.layout(.{ .x = 10, .y = 10, .w = 50, .h = 50 });
    try std.testing.expectEqual(child, root.hitTest(20, 20).?);
    try std.testing.expectEqual(root, root.hitTest(80, 80).?);
    try std.testing.expect(root.hitTest(200, 200) == null);
}

test "markDirty accumulates the damage region at the root" {
    const root = try testNode(100, 100);
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    const child = try testNode(10, 10);
    root.add(child);
    child.layout(.{ .x = 20, .y = 30, .w = 10, .h = 10 });
    root.dirty = false;
    root.clearDamage();
    child.markDirty();
    try std.testing.expect(root.dirty);
    try std.testing.expect(root.damage_valid);
    try std.testing.expectEqual(@as(f32, 20), root.damage.x);
    try std.testing.expectEqual(@as(f32, 30), root.damage.y);
    try std.testing.expectEqual(@as(f32, 10), root.damage.w);
    try std.testing.expectEqual(@as(f32, 10), root.damage.h);
    // a second mark unions into the region (0,0,30,40)
    child.markDirtyRect(.{ .x = 0, .y = 0, .w = 5, .h = 5 });
    try std.testing.expectEqual(@as(f32, 0), root.damage.x);
    try std.testing.expectEqual(@as(f32, 0), root.damage.y);
    try std.testing.expectEqual(@as(f32, 30), root.damage.w);
    try std.testing.expectEqual(@as(f32, 40), root.damage.h);
    // empty rects (pre-layout) never corrupt the region
    root.clearDamage();
    child.markDirtyRect(.{});
    try std.testing.expect(!root.damage_valid);
}

test "rect: contains is half-open; main/cross pick the axis; rectUnion sweeps both" {
    const r = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try std.testing.expect(r.contains(10, 20)); // the top-left corner is inside
    try std.testing.expect(r.contains(39.9, 59.9));
    try std.testing.expect(!r.contains(40, 30)); // the right edge is exclusive
    try std.testing.expect(!r.contains(20, 60)); // the bottom edge is exclusive
    try std.testing.expect(!r.contains(9.9, 20));
    try std.testing.expectEqual(@as(f32, 30), r.main(.horizontal));
    try std.testing.expectEqual(@as(f32, 40), r.main(.vertical));
    try std.testing.expectEqual(@as(f32, 40), r.cross(.horizontal));
    try std.testing.expectEqual(@as(f32, 30), r.cross(.vertical));
    const u = rectUnion(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .x = 5, .y = 20, .w = 10, .h = 5 });
    try std.testing.expectEqual(@as(f32, 0), u.x);
    try std.testing.expectEqual(@as(f32, 0), u.y);
    try std.testing.expectEqual(@as(f32, 15), u.w); // spans 0..15
    try std.testing.expectEqual(@as(f32, 25), u.h); // spans 0..25
    // a rect unioned with itself is itself
    try std.testing.expectEqual(r, rectUnion(r, r));
}

test "add parents the child and marks the tree dirty + layout-dirty" {
    const root = try testNode(100, 100);
    defer root.deinit();
    root.dirty = false;
    root.layout_dirty = false;
    const child = try testNode(10, 10);
    root.add(child);
    try std.testing.expectEqual(root, child.parent.?);
    try std.testing.expect(root.dirty);
    try std.testing.expect(root.layout_dirty);
}

test "markLayoutDirty propagates up to the root" {
    const root = try testNode(100, 100);
    defer root.deinit();
    const mid = try testNode(50, 50);
    const leaf = try testNode(10, 10);
    root.add(mid);
    mid.add(leaf);
    root.layout_dirty = false;
    mid.layout_dirty = false;
    leaf.markLayoutDirty();
    try std.testing.expect(leaf.layout_dirty);
    try std.testing.expect(mid.layout_dirty);
    try std.testing.expect(root.layout_dirty);
}

// --- paint-pass recording stub (order + visibility assertions) ---

const PaintRec = struct {
    log: *std.array_list.Managed([]const u8),
    name: []const u8, // static literal — safe to store in the log
    pre_name: []u8, // owned ("pre:" ++ name) — the log stores slice pointers
    post_name: []u8, // owned ("post:" ++ name)
};

fn recPaintMeasure(_: *Node, c: Constraints) Size {
    return c.constrain(.{ .w = 10, .h = 10 });
}
fn recPaintPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = ctx;
    const s: *PaintRec = @ptrCast(@alignCast(n.state.?));
    s.log.append(s.name) catch @panic("klaxon: out of memory");
}
fn recPaintPre(n: *Node, ctx: *kx.Ctx) void {
    _ = ctx;
    const s: *PaintRec = @ptrCast(@alignCast(n.state.?));
    s.log.append(s.pre_name) catch @panic("klaxon: out of memory");
}
fn recPaintPost(n: *Node, ctx: *kx.Ctx) void {
    _ = ctx;
    const s: *PaintRec = @ptrCast(@alignCast(n.state.?));
    s.log.append(s.post_name) catch @panic("klaxon: out of memory");
}
fn recPaintDeinit(n: *Node) void {
    const s: *PaintRec = @ptrCast(@alignCast(n.state.?));
    n.allocator.free(s.pre_name);
    n.allocator.free(s.post_name);
    n.allocator.destroy(s);
}
const paint_rec_vtable = VTable{
    .measure = recPaintMeasure,
    .layout = testLayout,
    .paint = recPaintPaint,
    .deinit = recPaintDeinit,
    .pre_children_paint = recPaintPre,
    .post_children_paint = recPaintPost,
};

fn recPaintNode(log: *std.array_list.Managed([]const u8), name: []const u8) !*Node {
    const node = try Node.create(std.testing.allocator, &paint_rec_vtable);
    errdefer node.allocator.destroy(node);
    const s = try std.testing.allocator.create(PaintRec);
    errdefer std.testing.allocator.destroy(s);
    s.* = .{
        .log = log,
        .name = name,
        .pre_name = try std.fmt.allocPrint(std.testing.allocator, "pre:{s}", .{name}),
        .post_name = try std.fmt.allocPrint(std.testing.allocator, "post:{s}", .{name}),
    };
    node.state = s;
    return node;
}

test "paint: hooks wrap the children pass; invisible + defer_paint subtrees are skipped" {
    const ctx = kx.create(null, 64, 64, kx.c.KX_BACKEND_RASTER) orelse return error.TestUnexpectedResult;
    defer kx.c.kx_destroy(ctx);
    var log = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer log.deinit();
    const root = try recPaintNode(&log, "root");
    defer root.deinit();
    const child = try recPaintNode(&log, "child");
    const hidden = try recPaintNode(&log, "hidden");
    const deferred = try recPaintNode(&log, "deferred");
    root.add(child);
    root.add(hidden);
    root.add(deferred);
    hidden.visible = false;
    deferred.defer_paint = true;
    kx.c.kx_begin_frame(ctx);
    root.paint(ctx);
    kx.c.kx_end_frame(ctx);
    // own paint → pre → children (defer_paint skipped) → post
    const expected = [_][]const u8{ "root", "pre:root", "child", "pre:child", "post:child", "post:root" };
    try std.testing.expectEqual(expected.len, log.items.len);
    for (expected, log.items) |exp, act| {
        try std.testing.expectEqualStrings(exp, act);
    }
    // the painted nodes clear their dirty flag; the skipped ones keep it
    try std.testing.expect(!root.dirty);
    try std.testing.expect(!child.dirty);
    try std.testing.expect(hidden.dirty);
    try std.testing.expect(deferred.dirty);
}

const hit_bounds_vtable = blk: {
    var vt = test_vtable;
    vt.hit_bounds = struct {
        fn hb(_: *Node) Rect {
            return .{ .x = 50, .y = 50, .w = 20, .h = 20 };
        }
    }.hb;
    break :blk vt;
};

test "hitTest honors the hit_bounds hook over the raw bounds" {
    const root = try testNode(100, 100);
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    const shifted = try testNode(10, 10);
    shifted.vtable = &hit_bounds_vtable; // bounds at (0,0,10,10), hit rect at (50,50,20,20)
    root.add(shifted);
    shifted.layout(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try std.testing.expectEqual(shifted, root.hitTest(55, 55).?); // inside the hit rect
    try std.testing.expectEqual(root, root.hitTest(5, 5).?); // bounds say child, hit rect says no
}

const pre_hit_shift_vtable = blk: {
    var vt = test_vtable;
    vt.pre_children_hit = struct {
        fn pre(_: *Node, px: f32, py: f32) HitPoint {
            return .{ .x = px - 100, .y = py - 50 }; // content translated by (+100, +50)
        }
    }.pre;
    break :blk vt;
};

const pre_hit_shift2_vtable = blk: {
    var vt = test_vtable;
    vt.pre_children_hit = struct {
        fn pre(_: *Node, px: f32, py: f32) HitPoint {
            return .{ .x = px - 10, .y = py }; // content translated by (+10, 0)
        }
    }.pre;
    break :blk vt;
};

test "hitTestMapped maps through pre_children_hit and reports parent-space coords" {
    const root = try testNode(200, 200);
    defer root.deinit();
    root.vtable = &pre_hit_shift_vtable;
    root.layout(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    const child = try testNode(50, 50);
    root.add(child);
    child.layout(.{ .x = 10, .y = 10, .w = 50, .h = 50 }); // content space
    // window (120, 70) → child space (20, 20): inside the child
    const hit = root.hitTestMapped(120, 70).?;
    try std.testing.expectEqual(child, hit.node);
    try std.testing.expectEqual(@as(f32, 20), hit.x); // the hit node's parent space
    try std.testing.expectEqual(@as(f32, 20), hit.y);
    // a point outside the mapped child hits the root
    try std.testing.expectEqual(root, root.hitTestMapped(50, 20).?.node);
}

test "mapPointToParentSpace applies every ancestor's pre_children_hit, root-first" {
    const root = try testNode(300, 300);
    defer root.deinit();
    root.vtable = &pre_hit_shift_vtable; // window → root's child space: (-100, -50)
    const mid = try testNode(100, 100);
    mid.vtable = &pre_hit_shift2_vtable; // root's child space → mid's child space: (-10, 0)
    root.add(mid);
    const leaf = try testNode(10, 10);
    mid.add(leaf);
    // window (115, 55) → mid space (15, 5) → leaf's parent space (5, 5)
    const p = Node.mapPointToParentSpace(leaf, 115, 55);
    try std.testing.expectEqual(@as(f32, 5), p.x);
    try std.testing.expectEqual(@as(f32, 5), p.y);
    // a node without a parent maps 1:1 (identity)
    const free_leaf = try testNode(10, 10);
    defer free_leaf.deinit();
    const p2 = Node.mapPointToParentSpace(free_leaf, 115, 55);
    try std.testing.expectEqual(@as(f32, 115), p2.x);
    try std.testing.expectEqual(@as(f32, 55), p2.y);
}

const map_paint_vtable = blk: {
    var vt = test_vtable;
    vt.map_paint_rect = struct {
        fn m(_: *Node, rect: Rect) Rect {
            return .{ .x = rect.x + 100, .y = rect.y + 50, .w = rect.w, .h = rect.h };
        }
    }.m;
    break :blk vt;
};

test "mapRectToRoot applies every transformed ancestor's map_paint_rect" {
    const root = try testNode(300, 300);
    defer root.deinit();
    root.vtable = &map_paint_vtable; // translates child rects by (+100, +50)
    const leaf = try testNode(10, 10);
    root.add(leaf);
    const r = leaf.mapRectToRoot(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try std.testing.expectEqual(@as(f32, 100), r.x);
    try std.testing.expectEqual(@as(f32, 50), r.y);
    try std.testing.expectEqual(@as(f32, 10), r.w);
    try std.testing.expectEqual(@as(f32, 10), r.h);
    // without a transform hook the rect passes through unchanged
    const free_leaf = try testNode(10, 10);
    defer free_leaf.deinit();
    const r2 = free_leaf.mapRectToRoot(.{ .x = 1, .y = 2, .w = 3, .h = 4 });
    try std.testing.expectEqual(Rect{ .x = 1, .y = 2, .w = 3, .h = 4 }, r2);
}

test "deinit releases the node's router references (capture/hover/focus/popup)" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    const root = try testNode(100, 100);
    defer root.deinit();
    const child = try testNode(50, 50);
    root.add(child);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    child.layout(.{ .x = 0, .y = 0, .w = 50, .h = 50 });
    router.dispatchPointer(root, .{ .phase = .move, .x = 10, .y = 10 }); // hover the child
    router.dispatchPointer(root, .{ .phase = .down, .x = 10, .y = 10 }); // capture it
    router.focus(child);
    router.open_popup = child;
    try std.testing.expect(router.capturedNode(0) == child);
    try std.testing.expect(root.remove(child)); // detach first: the root must not double-free
    child.deinit();
    try std.testing.expect(router.capturedNode(0) == null);
    try std.testing.expect(router.hovered == null);
    try std.testing.expect(router.focused == null);
    try std.testing.expect(router.open_popup == null);
}
