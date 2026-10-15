// ListView (Phase 1f) — virtualized vertical list.
//
// Virtualization: only the items intersecting the viewport ± `margin` are
// alive as child nodes (10k items → ~10 nodes). The window diffs on scroll
// (scroll_util.syncItemWindow): items leaving are destroyed, items entering
// are created by the factory.
//
// Scroll input: wheel (on_scroll), drag (on_pointer .move while captured —
// items consume down/up for taps, moves bubble up), programmatic
// (scrollBy / setScrollOffset). Children paint translated by -offset and
// clipped to the viewport (pre/post_children_paint); hit-testing and damage
// map through the same transform (pre_children_hit / map_paint_rect).
//
// P0: fixed item height; fills the (bounded) constraints — a ListView needs
// a bounded viewport (like Flutter without shrinkWrap).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const scroll_mod = @import("../ui/scroll.zig");
const scroll_util = @import("scroll_util.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;

fn stateOf(comptime T: type, n: *Node) *T {
    return @ptrCast(@alignCast(n.state.?));
}

pub const ItemFactory = scroll_util.ItemFactory;

pub const ListViewOptions = struct {
    item_count: usize,
    factory: ItemFactory,
    item_height: f32 = 48,
    gap: f32 = 0,
    margin: usize = 2, // items kept alive beyond the viewport (each side)
    wheel_speed: f32 = 48, // px per wheel click
};

const ListState = struct {
    opts: ListViewOptions,
    scroll: scroll_mod.ScrollState = .{},
    input: scroll_util.ScrollInput = .{},
    first: usize = 0, // item index of children[0]
    // Backing store for the scroll-copy fast path: the composited viewport
    // image plus the offset/window/size it was rendered at.
    backing: u64 = 0,
    backing_ctx: ?*kx.Ctx = null,
    backing_offset: f32 = 0,
    backing_first: usize = 0,
    backing_w: i32 = 0,
    backing_h: i32 = 0,
    /// Child-set fingerprint when the backing rendered — pure scroll shifts
    /// survive (dy != 0 covers them: entering rows repaint, leaving rows
    /// scroll off), but a content change at the SAME offset (rows removed,
    /// clear) leaves stale pixels the repaint band can't see.
    backing_sig: usize = 0,
};

/// Fingerprint of the child set a backing image was rendered from:
/// window position + count + identities. Compare at dy==0 reuse only.
fn childrenSig(s: *const ListState, n: *Node) usize {
    var sig = s.first ^ n.children.items.len;
    for (n.children.items) |c| sig = sig *% 31 +% @intFromPtr(c);
    return sig;
}

fn dropBacking(s: *ListState) void {
    if (s.backing != 0) {
        if (s.backing_ctx) |c| ui.paint.imageDestroy(c, s.backing);
    }
    s.backing = 0;
    s.backing_ctx = null;
}

fn strideOf(s: *const ListState) f32 {
    return s.opts.item_height + s.opts.gap;
}

fn contentHeight(s: *const ListState) f32 {
    if (s.opts.item_count == 0) return 0;
    return @as(f32, @floatFromInt(s.opts.item_count)) * strideOf(s) - s.opts.gap;
}

fn listMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = c.max_w, .h = c.max_h }); // fill the viewport
}

fn layoutItem(n: *Node, child: *Node, index: usize) void {
    const s = stateOf(ListState, n);
    // The item-texture idiom: a clean row re-blits while the list scrolls
    // (the canvas translate shifts it) instead of repainting its content —
    // rows that DO animate per frame drop the cache for free (auto policy
    // skips the raster on dirty frames). Raster 0.26→0.08; Metal pays the
    // entering row's raster (~0.06/frame) — net positive cross-backend.
    child.auto_retain = true;
    child.layout(.{
        .x = n.bounds.x,
        .y = n.bounds.y + @as(f32, @floatFromInt(index)) * strideOf(s),
        .w = n.bounds.w,
        .h = s.opts.item_height,
    });
}

fn listLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(ListState, n);
    s.scroll.viewport = bounds.h;
    s.scroll.content = contentHeight(s);
    // Re-clamp after a resize: if the clamp moved the offset the whole
    // viewport shifts — damage it (layout must not teleport content).
    if (s.scroll.setOffset(s.scroll.offset)) n.markDirty();
    if (s.scroll.viewport > 0) {
        const range = scroll_mod.visibleRange(s.opts.item_count, strideOf(s), s.scroll.viewport, s.scroll.offset, s.opts.margin);
        scroll_util.syncItemWindow(n, &s.first, s.opts.factory, range, layoutItem);
    }
    // Re-lay out every child (bounds may have changed — resize).
    for (n.children.items, 0..) |child, i| layoutItem(n, child, s.first + i);
}

fn listPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx; // children paint via the transform hooks below
}

/// Scroll-copy — the backing-store idiom (QBackingStore, composited
/// scroller layers): the previous frame's composited viewport shifts by the
/// scroll delta, one blit carries every unchanged row, and only the
/// newly-exposed strip plus dirty rows repaint into a fresh backing image.
/// Fractional deltas resample the shifted image — identical semantics to a
/// compositor translating a layer. Returns false → the normal per-child
/// pass runs (first paint, a slid virtualization window, a stale backing,
/// or a nested offscreen pass where none is available).
fn listScrollChildrenPaint(n: *Node, ctx: *kx.Ctx, child_region: Rect) bool {
    const s = stateOf(ListState, n);
    // GPU + row atlas: every retained row is a slot blit that joins the
    // sprite batch (ONE mesh for the viewport) — cheaper than the
    // backing-store path's offscreen pass + two viewport-sized blits.
    // Raster/GLES keep scroll-copy (their per-op cost is low, uploads are
    // not).
    if (std.c.getenv("KLAXON_NO_SCROLLCOPY") != null) return false;
    const b = n.bounds;
    const ix = @floor(b.x);
    const iy = @floor(b.y);
    const iw: i32 = @intFromFloat(@ceil(b.x + b.w) - ix);
    const ih: i32 = @intFromFloat(@ceil(b.y + b.h) - iy);
    if (iw <= 0 or ih <= 0) return true; // nothing to composite — consumed
    const w: f32 = @floatFromInt(iw);
    const h: f32 = @floatFromInt(ih);
    // Empty window: nothing to composite — and whatever the backing held
    // belongs to rows that no longer exist (drop it rather than re-blit
    // stale pixels).
    if (n.children.items.len == 0) {
        dropBacking(s);
        return true;
    }

    const dy = s.scroll.offset - s.backing_offset;
    const usable = s.backing != 0 and s.backing_ctx == ctx and
        s.backing_w == iw and s.backing_h == ih and
        (dy != 0 or childrenSig(s, n) == s.backing_sig);
    if (usable and @abs(dy) >= h) dropBacking(s); // a full page: no shared pixels
    const have = usable and @abs(dy) < h;

    // The repaint band in image space: the strip the shift uncovered, union
    // every dirty child (a fresh virtualization-window row is dirty, so a
    // sliding window still paints the entering row here — backing_first is
    // deliberately NOT part of the check).
    var repaint = Rect{ .x = 0, .y = 0, .w = w, .h = h };
    var any_dirty = false;
    if (std.c.getenv("KLAXON_DBG_LIST") != null) std.debug.print("  scrollcp: backing={} usable={} dy={d:.0} sig={x} stored={x}\n", .{ s.backing, usable, dy, childrenSig(s, n), s.backing_sig });
    if (have) {
        repaint = if (dy > 0)
            .{ .x = 0, .y = h - dy, .w = w, .h = dy }
        else if (dy < 0)
            .{ .x = 0, .y = 0, .w = w, .h = -dy }
        else
            .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        for (n.children.items) |c| {
            if (c.defer_paint or c.zombie) continue;
            if (!(c.dirty or c.layout_dirty)) continue;
            any_dirty = true;
            repaint = ui.node.rectUnion(repaint, .{
                .x = c.bounds.x - ix, .y = c.bounds.y - s.scroll.offset - iy,
                .w = c.bounds.w, .h = c.bounds.h,
            });
        }
        // Churning content (animated rows each frame): the offscreen pass +
        // two blits costs more than repainting the rows directly — stay on
        // the normal path. The backing stays valid; dy keeps tracking it.
        if (repaint.w * repaint.h > w * h * 0.7) return false;
    } else {
        for (n.children.items) |c| {
            if (!(c.defer_paint or c.zombie) and (c.dirty or c.layout_dirty)) {
                any_dirty = true;
                break;
            }
        }
        // No backing AND churning rows: building one costs an offscreen
        // pass + a forced mid-frame submit of it on Graphite (sampling the
        // freshly-written texture resolves the task ordering — measured
        // ~0.4ms, MORE than the direct row blits it replaces).
        if (any_dirty) return false;
    }
    if (!ui.paint.offscreenBegin(ctx, iw, ih)) {
        dropBacking(s);
        return false;
    }
    if (have) ui.paint.imageDraw(ctx, s.backing, 0, -dy, w, h);
    if (repaint.w > 0 and repaint.h > 0) {
        ui.paint.clipRect(ctx, repaint.x, repaint.y, repaint.w, repaint.h);
        // Image space → content space: a child's own bounds place it at
        // bounds.y - offset on screen; the image's top-left is (ix, iy).
        ui.paint.translate(ctx, -ix, -iy - s.scroll.offset);
        // Cull in the same screen space the normal pass uses (children map
        // their paint rects through the list's map_paint_rect).
        const band_screen = ui.node.rectIntersect(child_region, .{
            .x = ix, .y = iy + repaint.y, .w = repaint.w, .h = repaint.h,
        });
        ui.paint.spriteBatchBegin(ctx); // row atlas blits → one mesh
        for (n.children.items) |c| {
            if (c.defer_paint or c.zombie) continue;
            c.paint(ctx, band_screen);
        }
        ui.paint.spriteBatchEnd(ctx); // flush BEFORE clipReset reorders it
        ui.paint.clipReset(ctx);
    }
    const img = ui.paint.offscreenEndImage(ctx);
    dropBacking(s);
    if (img != 0) {
        s.backing = img;
        s.backing_ctx = ctx;
        s.backing_offset = s.scroll.offset;
        s.backing_w = iw;
        s.backing_h = ih;
        s.backing_sig = childrenSig(s, n);
        ui.paint.imageDraw(ctx, img, ix, iy, w, h);
    }
    return true;
}

/// Clip to the viewport, then translate the content by -offset.
fn listPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(ListState, n);
    const b = n.bounds;
    ui.paint.clipRect(ctx, b.x, b.y, b.w, b.h);
    ui.paint.translate(ctx, 0, -s.scroll.offset);
    // Row atlas blits accumulate into ONE textured mesh (GPU only) — must
    // end before clipReset so the flush draws under the viewport clip.
    ui.paint.spriteBatchBegin(ctx);
}
fn listPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.spriteBatchEnd(ctx);
    ui.paint.clipReset(ctx);
}
fn listMapPaintRect(n: *Node, rect: Rect) Rect {
    const s = stateOf(ListState, n);
    return .{ .x = rect.x, .y = rect.y - s.scroll.offset, .w = rect.w, .h = rect.h };
}
fn listChildClip(n: *Node) Rect {
    return n.bounds; // the viewport clip pushed in pre_children_paint
}
fn listPreChildrenHit(n: *Node, px: f32, py: f32) ui.node.HitPoint {
    const s = stateOf(ListState, n);
    return .{ .x = px, .y = py + s.scroll.offset };
}

fn listOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(ListState, n);
    return s.input.onPointer(ev, &s.scroll, setScrollOffset, n);
}
fn listOnScroll(n: *Node, ev: input.ScrollEvent) bool {
    const s = stateOf(ListState, n);
    return s.input.onScroll(ev, &s.scroll, s.opts.wheel_speed, setScrollOffset, n);
}
fn listScrollInfo(n: *Node) scroll_mod.ScrollInfo {
    return stateOf(ListState, n).scroll.info();
}
fn listScrollSetOffset(n: *Node, value: f32) void {
    _ = setScrollOffset(n, value);
}
fn listDeinit(n: *Node) void {
    const s = stateOf(ListState, n);
    dropBacking(s);
    input.releaseNode(n);
    n.allocator.destroy(s);
}
const list_vtable = ui.node.VTable{
    .measure = listMeasure,
    .measure_pure = true, // fills the constraints — reads nothing else
    .layout = listLayout,
    .paint = listPaint,
    .deinit = listDeinit,
    .on_pointer = listOnPointer,
    .on_scroll = listOnScroll,
    .scroll_info = listScrollInfo,
    .scroll_set_offset = listScrollSetOffset,
    .scroll_children_paint = listScrollChildrenPaint,
    .pre_children_paint = listPreChildrenPaint,
    .post_children_paint = listPostChildrenPaint,
    .map_paint_rect = listMapPaintRect,
    .child_clip = listChildClip,
    .pre_children_hit = listPreChildrenHit,
    // auto_retain: the viewport clip bounds the extent — an idle list is
    // one blit. Scrolling dirties it → direct paint (cache drops).
    .auto_retain = true,
};

pub fn listView(allocator: std.mem.Allocator, opts: ListViewOptions) !*Node {
    const node = try Node.create(allocator, &list_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(ListState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts };
    node.state = s;
    return node;
}

// --- scroll API (programmatic + Scrollbar) ---

pub fn scrollOffset(n: *Node) f32 {
    return stateOf(ListState, n).scroll.offset;
}

/// Set the scroll offset (clamped). Shifts the virtualization window.
/// Returns true if the offset changed.
pub fn setScrollOffset(n: *Node, value: f32) bool {
    const s = stateOf(ListState, n);
    if (!s.scroll.setOffset(value)) return false;
    if (s.scroll.viewport > 0) {
        const range = scroll_mod.visibleRange(s.opts.item_count, strideOf(s), s.scroll.viewport, s.scroll.offset, s.opts.margin);
        scroll_util.syncItemWindow(n, &s.first, s.opts.factory, range, layoutItem);
    }
    n.markDirty();
    return true;
}

pub fn scrollBy(n: *Node, dy: f32) void {
    _ = setScrollOffset(n, stateOf(ListState, n).scroll.offset + dy);
}

pub fn maxScrollOffset(n: *Node) f32 {
    return stateOf(ListState, n).scroll.maxOffset();
}

/// Re-create the live window from the factory: the model changed (row
/// content is re-created, not diffed per node — the krausest-style list ops
/// benchmark drives this). Keeps the scroll offset + window position.
/// A rebind-capable factory rewrites the live rows in place instead —
/// the RecyclerView notifyDataSetChanged idiom (no node churn).
pub fn reloadItems(n: *Node) void {
    const s = stateOf(ListState, n);
    if (s.opts.factory.rebind) |rebind| {
        // Re-sync the window FIRST (a count change trims/recycles rows) —
        // rebinding rows that are about to be dropped is wasted work.
        if (s.scroll.viewport > 0) {
            const range = scroll_mod.visibleRange(s.opts.item_count, strideOf(s), s.scroll.viewport, s.scroll.offset, s.opts.margin);
            scroll_util.syncItemWindow(n, &s.first, s.opts.factory, range, layoutItem);
        } else {
            s.first = 0;
        }
        var i: usize = 0;
        while (i < n.children.items.len) : (i += 1) {
            const child = n.children.items[i];
            const index = s.first + i;
            if (rebind(s.opts.factory.userdata, index, child)) {
                // Content size may follow the model — re-lay the row out.
                layoutItem(n, child, index);
            } else {
                // Declined: swap a fresh node into the same slot (the
                // detach-then-deinit order holds — deinit defers destroys).
                _ = n.remove(child);
                child.deinit();
                const fresh = s.opts.factory.fn_ptr(s.opts.factory.userdata, index);
                n.insert(i, fresh);
                layoutItem(n, fresh, index);
            }
        }
        // Damage stays row-scoped: the rebinds/adds/removes mark their own
        // rects — a no-change reload repaints nothing.
        n.markLayoutDirty();
        return;
    }
    // Detach-then-deinit from the back — the scroll_util.syncItemWindow
    // invariant. child.deinit()'s sweep orderedRemoves the child from
    // n.children AND frees the struct: a for-loop over n.children.items
    // would iterate a mutating slice whose stale tail points at freed
    // memory (UAF — deterministic crash under the debug allocator).
    while (n.children.items.len > 0) {
        const child = n.children.items[n.children.items.len - 1];
        _ = n.remove(child); // detach then deinit — never the reverse
        child.deinit();
    }
    if (s.scroll.viewport > 0) {
        const range = scroll_mod.visibleRange(s.opts.item_count, strideOf(s), s.scroll.viewport, s.scroll.offset, s.opts.margin);
        s.first = range.first;
        scroll_util.syncItemWindow(n, &s.first, s.opts.factory, range, layoutItem);
    } else {
        s.first = 0;
    }
    n.markLayoutDirty();
    n.markDirty();
}

/// Change the item count (model size changed — insert/remove/clear) and
/// reload the window, re-clamping the scroll offset.
pub fn setItemCount(n: *Node, count: usize) void {
    const s = stateOf(ListState, n);
    s.opts.item_count = count;
    s.scroll.content = contentHeight(s);
    _ = s.scroll.setOffset(s.scroll.offset); // re-clamp
    reloadItems(n);
}

// --- tests ---

const red: Color = 0xFF0000FF;
const green: Color = 0x00FF00FF;
const blue: Color = 0x0000FFFF;

fn testItem(userdata: ?*anyopaque, index: usize) *Node {
    _ = userdata;
    const colors = [_]Color{ red, green, blue };
    // Deliberately no error path: OOM is fatal (Node.add convention).
    return golden.solidBox(std.testing.allocator, 100, 48, colors[index % 3]) catch @panic("klaxon: out of memory");
}

const test_factory = ItemFactory{ .fn_ptr = testItem, .userdata = null };

fn testList(count: usize) !*Node {
    return listView(std.testing.allocator, .{
        .item_count = count,
        .factory = test_factory,
        .item_height = 48,
    });
}

test "listView: virtualizes — 10k items keep ~7 children alive" {
    const list = try testList(10_000);
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    // viewport 200 / stride 48 → 5 intersecting + 2 margin = 7 items
    try std.testing.expectEqual(@as(usize, 7), list.children.items.len);
    try std.testing.expectEqual(@as(usize, 0), stateOf(ListState, list).first);
    // scroll deep: the window follows (5 intersecting + 2 margin each side = 9)
    _ = setScrollOffset(list, 48 * 5000);
    try std.testing.expectEqual(@as(usize, 4998), stateOf(ListState, list).first); // floor(5000) - 2
    try std.testing.expectEqual(@as(usize, 9), list.children.items.len);
    // clamp at the end: first = 10000 - 7
    _ = setScrollOffset(list, 48 * 100_000);
    try std.testing.expectEqual(@as(usize, 10_000 - 7), stateOf(ListState, list).first);
    try std.testing.expectEqual(@as(usize, 7), list.children.items.len);
}

test "listView: children lay out at content positions (translated at paint)" {
    const list = try testList(100);
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    try std.testing.expectEqual(@as(f32, 0), list.children.items[0].bounds.y);
    try std.testing.expectEqual(@as(f32, 48), list.children.items[1].bounds.y);
    try std.testing.expectEqual(@as(f32, 96), list.children.items[2].bounds.y);
    try std.testing.expectEqual(@as(f32, 48), list.children.items[0].bounds.h);
}

test "listView: scroll API clamps and reports" {
    const list = try testList(10); // content 480
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 }); // max offset 280
    try std.testing.expectEqual(@as(f32, 280), maxScrollOffset(list));
    scrollBy(list, 100);
    try std.testing.expectEqual(@as(f32, 100), scrollOffset(list));
    scrollBy(list, 10_000);
    try std.testing.expectEqual(@as(f32, 280), scrollOffset(list));
    _ = setScrollOffset(list, -50);
    try std.testing.expectEqual(@as(f32, 0), scrollOffset(list));
    // scroll_info for the Scrollbar
    const info = list.vtable.scroll_info.?(list);
    try std.testing.expect(info.canScroll());
    try std.testing.expectEqual(@as(f32, 480), info.content);
    try std.testing.expectEqual(@as(f32, 200), info.viewport);
}

test "listView: wheel scrolls, drag scrolls, hover does not" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const list = try testList(100);
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    // wheel down (delta_y = -1 → offset += 48)
    router.dispatchScroll(list, .{ .x = 50, .y = 50, .delta_y = -1 });
    try std.testing.expectEqual(@as(f32, 48), scrollOffset(list));
    // drag: down at y=100, move DOWN to y=130 → content follows → offset -= 30
    router.dispatchPointer(list, .{ .phase = .down, .x = 50, .y = 100 });
    router.dispatchPointer(list, .{ .phase = .move, .x = 50, .y = 130 });
    try std.testing.expectEqual(@as(f32, 18), scrollOffset(list));
    router.dispatchPointer(list, .{ .phase = .up, .x = 50, .y = 130 });
    // hover move (no capture) → no scroll
    router.dispatchPointer(list, .{ .phase = .move, .x = 50, .y = 10 });
    try std.testing.expectEqual(@as(f32, 18), scrollOffset(list));
}

test "golden: listView paints only the visible window, clipped" {
    const bg: Color = 0x000000FF;
    const list = try testList(10); // 10 items of 48 = 480 content, viewport 100
    defer list.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 100, 100);
    defer r.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    r.paint(list, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    // items 0 (red) and 1 (green) fill the viewport; item 2+ clipped out
    try std.testing.expectEqual(red, f1.pixelAt(50, 10));
    try std.testing.expectEqual(green, f1.pixelAt(50, 60));
    try std.testing.expectEqual(@as(u64, 48 * 100), f1.countColor(red));
    try std.testing.expectEqual(@as(u64, 48 * 100), f1.countColor(green));
    try std.testing.expectEqual(@as(u64, 4 * 100), f1.countColor(blue)); // margin item 2 peeks 4px
    // scrolled by one item: green at top, blue below, item 3 (red) peeks 4px
    _ = setScrollOffset(list, 48);
    r.paint(list, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(green, f2.pixelAt(50, 10));
    try std.testing.expectEqual(blue, f2.pixelAt(50, 60));
    try std.testing.expectEqual(@as(u64, 4 * 100), f2.countColor(red)); // item 3, 4px
    try std.testing.expectEqual(@as(u64, 0), f2.countColorIn(.{ .x = 0, .y = 0, .w = 100, .h = 48 }, red)); // item 0 gone
}

test "listView: hit-testing lands on the item under the pointer" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const list = try testList(100);
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    _ = setScrollOffset(list, 48 * 10); // offset 480 → window [8, 17)
    try std.testing.expectEqual(@as(usize, 8), stateOf(ListState, list).first);
    // pointer at viewport y=10 → content y = 10 + 480 = 490 → item 10 = children[2]
    const hit = list.hitTest(50, 10).?;
    try std.testing.expectEqual(list.children.items[2], hit);
    // scroll further: the hit follows the window
    _ = setScrollOffset(list, 48 * 20); // window [18, 27)
    try std.testing.expectEqual(@as(usize, 18), stateOf(ListState, list).first);
    const hit2 = list.hitTest(50, 10).?;
    try std.testing.expectEqual(list.children.items[2], hit2); // item 20
}

test "listView: a large backward jump rebuilds only the new window" {
    const list = try testList(10_000);
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    _ = setScrollOffset(list, 48 * 5000);
    try std.testing.expectEqual(@as(usize, 9), list.children.items.len);
    // jump back to the top: ~7 children, NOT 5000 materialized
    _ = setScrollOffset(list, 0);
    try std.testing.expectEqual(@as(usize, 7), list.children.items.len);
    try std.testing.expectEqual(@as(usize, 0), stateOf(ListState, list).first);
}

test "listView: scrolling away a captured item releases the router capture" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const list = try testList(100);
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    router.dispatchPointer(list, .{ .phase = .down, .x = 50, .y = 10 });
    try std.testing.expect(router.capturedNode(0) != null);
    _ = setScrollOffset(list, 48 * 50); // the captured item is virtualized out
    try std.testing.expect(router.capturedNode(0) == null); // no dangling capture
    router.dispatchPointer(list, .{ .phase = .move, .x = 50, .y = 10 }); // safe (hover path)
}

test "listView: growing the viewport re-clamps the offset" {
    const list = try testList(10); // content 480
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    _ = setScrollOffset(list, 280); // max at viewport 200
    try std.testing.expectEqual(@as(f32, 280), scrollOffset(list));
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 400 }); // viewport grows → max 80
    try std.testing.expectEqual(@as(f32, 80), scrollOffset(list));
}

test "listView: concurrent fingers drag independently (per-pointer tracks)" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const list = try testList(100);
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    // two fingers press items and drag up 10px each
    router.dispatchPointer(list, .{ .phase = .down, .x = 50, .y = 100, .pointer = 1 });
    router.dispatchPointer(list, .{ .phase = .down, .x = 50, .y = 50, .pointer = 2 });
    router.dispatchPointer(list, .{ .phase = .move, .x = 50, .y = 90, .pointer = 1 });
    router.dispatchPointer(list, .{ .phase = .move, .x = 50, .y = 40, .pointer = 2 });
    // 10 + 10 — a shared drag position would scroll 60 on the second finger
    try std.testing.expectEqual(@as(f32, 20), scrollOffset(list));
    router.dispatchPointer(list, .{ .phase = .up, .x = 50, .y = 90, .pointer = 1 });
    router.dispatchPointer(list, .{ .phase = .up, .x = 50, .y = 40, .pointer = 2 });
}

test "listView: setItemCount + reloadItems rebind the model in place" {
    const list = try testList(100);
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    try std.testing.expectEqual(@as(usize, 7), list.children.items.len);
    setItemCount(list, 3);
    try std.testing.expectEqual(@as(usize, 3), list.children.items.len);
    setItemCount(list, 10_000);
    try std.testing.expectEqual(@as(usize, 7), list.children.items.len);
    // window follows a deep scroll, then a reload keeps it
    _ = setScrollOffset(list, 48 * 5000);
    try std.testing.expectEqual(@as(usize, 9), list.children.items.len);
    reloadItems(list);
    try std.testing.expectEqual(@as(usize, 9), list.children.items.len);
    try std.testing.expectEqual(@as(usize, 4998), stateOf(ListState, list).first);
    // clear → empty viewport
    setItemCount(list, 0);
    try std.testing.expectEqual(@as(usize, 0), list.children.items.len);
}

const input_widgets = @import("input.zig");

fn countPressedCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

fn btnItem(userdata: ?*anyopaque, index: usize) *Node {
    _ = index;
    const cb: ui.state.Callback = .{ .fn_ptr = countPressedCb, .userdata = userdata };
    return input_widgets.button(std.testing.allocator, cb, .{}) catch @panic("klaxon: out of memory");
}

test "listView: a button inside a scrolled item receives clicks at its visual position" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var pressed: u32 = 0;
    const list = try listView(std.testing.allocator, .{
        .item_count = 100,
        .factory = .{ .fn_ptr = btnItem, .userdata = &pressed },
        .item_height = 48,
    });
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    _ = setScrollOffset(list, 48 * 10); // item 10's button at content y 480
    // click at viewport (50, 10) → content (50, 490) → inside the button
    router.dispatchPointer(list, .{ .phase = .down, .x = 50, .y = 10 });
    router.dispatchPointer(list, .{ .phase = .up, .x = 50, .y = 10 });
    try std.testing.expectEqual(@as(u32, 1), pressed);
}

test "listView: 10k items render a frame fast (virtualized)" {
    const bg: Color = 0x000000FF;
    const list = try testList(10_000);
    defer list.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 100, 200);
    defer r.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    const io = std.Io.Threaded.global_single_threaded.io();
    const t0 = std.Io.Clock.awake.now(io);
    r.paint(list, bg);
    const elapsed_ns = t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    const elapsed_ms: f32 = @as(f32, @floatFromInt(elapsed_ns)) / 1e6;
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // virtualized: ~7 children painted regardless of the 10k item count
    try std.testing.expectEqual(@as(usize, 7), list.children.items.len);
    try std.testing.expect(f.countNot(bg) > 0);
    // loose CI-safe bound: a virtualized frame is ~visible-items cost
    try std.testing.expect(elapsed_ms < 100);
}
