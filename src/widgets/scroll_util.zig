// Scroll widget internals (Phase 1f) — shared by ListView, GridView and
// ScrollView. Not a widget module (no exports in widgets.zig).
//
//   ItemFactory    — creates one item node per index (ADR-0009: fn ptr + userdata)
//   ScrollInput    — drag-to-scroll + wheel handlers (embedded in widget state)
//   syncItemWindow — the virtualization diff: trims items that left the
//                    visible window, creates the ones that entered
const std = @import("std");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const scroll_mod = @import("../ui/scroll.zig");

const Node = ui.node.Node;

/// Creates one item node for `index`. OOM inside the factory is fatal (same
/// convention as Node.add).
pub const ItemFactory = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, index: usize) *Node,
    userdata: ?*anyopaque,
};

/// Drag-to-scroll + wheel input, embedded in a scrollable's state.
///
/// Drag: .move events reach the scrollable by bubbling (items consume
/// down/up for taps but not moves). A move only scrolls while the router
/// has a capture for the pointer (a real drag — hover moves never scroll).
/// Each pointer has its own track (down/hover/drag positions) so concurrent
/// fingers never jump the content, and a new drag starts without a jump.
/// Tracks live in window space (raw_*): the delta is physical finger
/// motion — the content scrolling under a held finger must not cancel it.
///
/// `set_offset` is the widget's apply function: it clamps, shifts the
/// virtualization window and marks the node dirty — and returns whether the
/// offset changed.
pub const ScrollInput = struct {
    pub const MAX_TRACKS = 8; // matches input.MAX_POINTERS
    /// y is window-space (raw_y) — see the struct doc above.
    const Track = struct { pointer: u64 = 0, y: f32 = 0, active: bool = false };
    tracks: [MAX_TRACKS]Track = std.mem.zeroes([MAX_TRACKS]Track),

    pub const SetOffset = *const fn (n: *Node, value: f32) bool;

    fn trackFor(inp: *ScrollInput, pointer: u64) *Track {
        for (&inp.tracks) |*t| {
            if (t.active and t.pointer == pointer) return t;
        }
        for (&inp.tracks) |*t| {
            if (!t.active) return t;
        }
        return &inp.tracks[0]; // full: reuse slot 0 (P0)
    }

    fn releaseTrack(inp: *ScrollInput, pointer: u64) void {
        for (&inp.tracks) |*t| {
            if (t.active and t.pointer == pointer) t.active = false;
        }
    }

    /// Call from the widget's on_pointer.
    pub fn onPointer(inp: *ScrollInput, ev: input.PointerEvent, scroll: *scroll_mod.ScrollState, set_offset: SetOffset, n: *Node) bool {
        switch (ev.phase) {
            .down => {
                const t = inp.trackFor(ev.pointer);
                t.* = .{ .pointer = ev.pointer, .y = ev.raw_y, .active = true };
                return false; // items handle taps
            },
            .up, .outside_down => {
                inp.releaseTrack(ev.pointer);
                return false;
            },
            .move => {},
            else => return false,
        }
        const router = input.current() orelse return false;
        const dragging = router.capturedNode(ev.pointer) != null;
        const t = inp.trackFor(ev.pointer);
        const last = if (t.active and t.pointer == ev.pointer) t.y else ev.raw_y;
        t.* = .{ .pointer = ev.pointer, .y = ev.raw_y, .active = true };
        if (!dragging) return false; // hover move: no scroll
        const dy = ev.raw_y - last;
        if (dy == 0) return false;
        // The finger drags the content: moving up (dy < 0) increases the offset.
        return set_offset(n, scroll.offset - dy);
    }

    /// Call from the widget's on_scroll (wheel). Positive delta_y = scroll
    /// up = offset decreases.
    pub fn onScroll(inp: *ScrollInput, ev: input.ScrollEvent, scroll: *scroll_mod.ScrollState, wheel_speed: f32, set_offset: SetOffset, n: *Node) bool {
        _ = inp;
        if (!scroll.info().canScroll()) return false;
        return set_offset(n, scroll.offset - ev.delta_y * wheel_speed);
    }
};

/// The virtualization diff: children[0] is item `first`; the window is
/// [range.first, range.last). Trims items that left (front then back),
/// creates the ones that entered (front then back), laying out each new
/// child at its content position via `layout_item`.
pub fn syncItemWindow(
    n: *Node,
    first: *usize,
    factory: ItemFactory,
    range: scroll_mod.Range,
    layout_item: *const fn (n: *Node, child: *Node, index: usize) void,
) void {
    // Non-overlapping windows (or an empty window): drop everything and
    // re-anchor — a large jump must NOT materialize the intervening items.
    const old_last = first.* + n.children.items.len;
    const overlaps = first.* < range.last and range.first < old_last;
    if (!overlaps) {
        for (n.children.items) |child| child.deinit();
        n.children.clearRetainingCapacity();
        first.* = range.first;
    }
    // Trim items that left the window (front): destroy the child and
    // advance `first` — advancing continues past an empty window (the
    // children were never created or are already gone).
    while (first.* < range.first) {
        if (n.children.items.len > 0) {
            const child = n.children.items[0];
            _ = n.children.orderedRemove(0);
            child.deinit();
        }
        first.* += 1;
    }
    // Trim items that left the window (back).
    while (first.* + n.children.items.len > range.last and n.children.items.len > 0) {
        const last = n.children.items.len - 1;
        const child = n.children.items[last];
        _ = n.children.orderedRemove(last);
        child.deinit();
    }
    // Items entering at the front (scrolled up): prepend.
    while (first.* > range.first) {
        first.* -= 1;
        const node = factory.fn_ptr(factory.userdata, first.*);
        n.children.insert(0, node) catch @panic("klaxon: out of memory");
        node.parent = n;
        layout_item(n, node, first.*);
    }
    // Items entering at the back (scrolled down): append.
    while (first.* + n.children.items.len < range.last) {
        const index = first.* + n.children.items.len;
        const node = factory.fn_ptr(factory.userdata, index);
        n.add(node); // sets parent + marks dirty
        layout_item(n, node, index);
    }
}

// --- tests ---

const kx = @import("../kx.zig");
const golden = @import("../golden.zig");

// --- syncItemWindow (a counting item factory + a solid-box parent) ---

const ItemRec = struct { created: *u32, last_index: *usize };

fn countItem(userdata: ?*anyopaque, index: usize) *Node {
    const rec: *ItemRec = @ptrCast(@alignCast(userdata.?));
    rec.created.* += 1;
    rec.last_index.* = index;
    // Deliberately no error path: OOM is fatal (Node.add convention).
    return golden.solidBox(std.testing.allocator, 10, 10, 0xFF0000FF) catch @panic("klaxon: out of memory");
}

fn noopLayoutItem(_: *Node, _: *Node, _: usize) void {}

test "syncItemWindow: fills, trims front/back, prepends and appends" {
    const parent = try golden.solidBox(std.testing.allocator, 100, 100, 0xFFFFFFFF);
    defer parent.deinit();
    var created: u32 = 0;
    var last_index: usize = 0;
    var rec = ItemRec{ .created = &created, .last_index = &last_index };
    const factory = ItemFactory{ .fn_ptr = countItem, .userdata = &rec };
    var first: usize = 0;
    // initial fill [0, 5)
    syncItemWindow(parent, &first, factory, .{ .first = 0, .last = 5 }, noopLayoutItem);
    try std.testing.expectEqual(@as(usize, 5), parent.children.items.len);
    try std.testing.expectEqual(@as(u32, 5), created);
    // scroll down: [2, 7) → trim 2 at the front, append 2 at the back
    syncItemWindow(parent, &first, factory, .{ .first = 2, .last = 7 }, noopLayoutItem);
    try std.testing.expectEqual(@as(usize, 2), first);
    try std.testing.expectEqual(@as(usize, 5), parent.children.items.len);
    try std.testing.expectEqual(@as(u32, 7), created); // only the 2 new items
    try std.testing.expectEqual(@as(usize, 6), last_index); // the last appended index
    // scroll up: [0, 3) → prepend 2 at the front, trim 4 at the back
    syncItemWindow(parent, &first, factory, .{ .first = 0, .last = 3 }, noopLayoutItem);
    try std.testing.expectEqual(@as(usize, 0), first);
    try std.testing.expectEqual(@as(usize, 3), parent.children.items.len);
    try std.testing.expectEqual(@as(u32, 9), created);
}

test "syncItemWindow: a non-overlapping jump re-anchors without materializing the gap" {
    const parent = try golden.solidBox(std.testing.allocator, 100, 100, 0xFFFFFFFF);
    defer parent.deinit();
    var created: u32 = 0;
    var last_index: usize = 0;
    var rec = ItemRec{ .created = &created, .last_index = &last_index };
    const factory = ItemFactory{ .fn_ptr = countItem, .userdata = &rec };
    var first: usize = 0;
    syncItemWindow(parent, &first, factory, .{ .first = 0, .last = 5 }, noopLayoutItem);
    try std.testing.expectEqual(@as(u32, 5), created);
    // jump far ahead: [1000, 1005) — drop everything, re-anchor (NOT 1000 items)
    syncItemWindow(parent, &first, factory, .{ .first = 1000, .last = 1005 }, noopLayoutItem);
    try std.testing.expectEqual(@as(usize, 1000), first);
    try std.testing.expectEqual(@as(usize, 5), parent.children.items.len);
    try std.testing.expectEqual(@as(u32, 10), created); // only the 5 new ones
    // an empty window drops everything
    syncItemWindow(parent, &first, factory, .{ .first = 0, .last = 0 }, noopLayoutItem);
    try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);
    try std.testing.expectEqual(@as(u32, 10), created); // nothing re-created
}

// --- ScrollInput (a stub scrollable widget wired like ListView) ---

const ScrollWidget = struct {
    input: ScrollInput = .{},
    scroll: scroll_mod.ScrollState = .{},
    set_calls: u32 = 0,
    last_value: f32 = 0,
};

fn swSetOffset(n: *Node, value: f32) bool {
    const s: *ScrollWidget = @ptrCast(@alignCast(n.state.?));
    s.set_calls += 1;
    s.last_value = value;
    return s.scroll.setOffset(value);
}
fn swMeasure(_: *Node, c: ui.layout.Constraints) ui.layout.Size {
    return c.constrain(.{ .w = 100, .h = 100 });
}
fn swLayout(_: *Node, _: ui.node.Rect) void {}
fn swPaint(_: *Node, _: *kx.Ctx) void {}
fn swOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s: *ScrollWidget = @ptrCast(@alignCast(n.state.?));
    return s.input.onPointer(ev, &s.scroll, swSetOffset, n);
}
fn swOnScroll(n: *Node, ev: input.ScrollEvent) bool {
    const s: *ScrollWidget = @ptrCast(@alignCast(n.state.?));
    return s.input.onScroll(ev, &s.scroll, 48, swSetOffset, n);
}
fn swDeinit(n: *Node) void {
    n.allocator.destroy(@as(*ScrollWidget, @ptrCast(@alignCast(n.state.?))));
}
const sw_vtable = ui.node.VTable{
    .measure = swMeasure,
    .layout = swLayout,
    .paint = swPaint,
    .deinit = swDeinit,
    .on_pointer = swOnPointer,
    .on_scroll = swOnScroll,
};

fn scrollWidget() !*Node {
    const n = try Node.create(std.testing.allocator, &sw_vtable);
    errdefer n.allocator.destroy(n);
    const s = try std.testing.allocator.create(ScrollWidget);
    errdefer std.testing.allocator.destroy(s);
    s.* = .{ .scroll = .{ .content = 1000, .viewport = 200 } };
    n.state = s;
    n.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    return n;
}

fn swState(n: *Node) *ScrollWidget {
    return @ptrCast(@alignCast(n.state.?));
}

test "ScrollInput: a drag scrolls (finger up = offset up); a hover move does not" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const n = try scrollWidget();
    defer n.deinit();
    const s = swState(n);
    // a hover move (no capture) never scrolls
    router.dispatchPointer(n, .{ .phase = .move, .x = 50, .y = 100 });
    try std.testing.expectEqual(@as(f32, 0), s.scroll.offset);
    try std.testing.expectEqual(@as(u32, 0), s.set_calls);
    // press (capture + track), then drag DOWN 30px: the content follows → offset -30 → clamped 0
    router.dispatchPointer(n, .{ .phase = .down, .x = 50, .y = 100 });
    router.dispatchPointer(n, .{ .phase = .move, .x = 50, .y = 130 });
    try std.testing.expectEqual(@as(f32, 0), s.scroll.offset); // clamped at 0
    try std.testing.expectEqual(@as(u32, 1), s.set_calls);
    try std.testing.expectEqual(@as(f32, -30), s.last_value); // the requested (unclamped) value
    // drag UP 50px from there: offset +50
    router.dispatchPointer(n, .{ .phase = .move, .x = 50, .y = 80 });
    try std.testing.expectEqual(@as(f32, 50), s.scroll.offset);
    try std.testing.expectEqual(@as(u32, 2), s.set_calls);
    try std.testing.expectEqual(@as(f32, 50), s.last_value);
    // release: the track ends; a later hover move does not scroll
    router.dispatchPointer(n, .{ .phase = .up, .x = 50, .y = 80 });
    router.dispatchPointer(n, .{ .phase = .move, .x = 50, .y = 10 });
    try std.testing.expectEqual(@as(f32, 50), s.scroll.offset);
    try std.testing.expectEqual(@as(u32, 2), s.set_calls);
}

test "ScrollInput: the wheel scrolls by delta * speed; an unscrollable ignores it" {
    var router = input.InputRouter{};
    const n = try scrollWidget();
    defer n.deinit();
    const s = swState(n);
    // wheel down (delta_y = -1) at speed 48 → offset += 48
    router.dispatchScroll(n, .{ .x = 50, .y = 50, .delta_y = -1 });
    try std.testing.expectEqual(@as(f32, 48), s.scroll.offset);
    // wheel up (delta_y = +1) → offset -= 48
    router.dispatchScroll(n, .{ .x = 50, .y = 50, .delta_y = 1 });
    try std.testing.expectEqual(@as(f32, 0), s.scroll.offset);
    // content smaller than the viewport: canScroll is false → ignored
    s.scroll = .{ .content = 100, .viewport = 200 };
    router.dispatchScroll(n, .{ .x = 50, .y = 50, .delta_y = -1 });
    try std.testing.expectEqual(@as(f32, 0), s.scroll.offset);
    try std.testing.expectEqual(@as(u32, 2), s.set_calls); // no extra set_offset call
}

test "ScrollInput: tracks are per-pointer; up releases the track" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const n = try scrollWidget();
    defer n.deinit();
    const s = swState(n);
    // two fingers down at the same spot
    router.dispatchPointer(n, .{ .phase = .down, .x = 50, .y = 100, .pointer = 1 });
    router.dispatchPointer(n, .{ .phase = .down, .x = 50, .y = 100, .pointer = 2 });
    // finger 1 moves up 40 → offset 40
    router.dispatchPointer(n, .{ .phase = .move, .x = 50, .y = 60, .pointer = 1 });
    try std.testing.expectEqual(@as(f32, 40), s.scroll.offset);
    // finger 2 moves down 10 from ITS OWN start (raw_y 100 → 110) → offset 30
    // (a shared track would compute the delta against finger 1's last y=60
    // and clamp to 0 instead)
    router.dispatchPointer(n, .{ .phase = .move, .x = 50, .y = 110, .pointer = 2 });
    try std.testing.expectEqual(@as(f32, 30), s.scroll.offset);
    // release finger 1 (router + track); a fresh drag starts without a jump
    router.dispatchPointer(n, .{ .phase = .up, .x = 50, .y = 60, .pointer = 1 });
    router.dispatchPointer(n, .{ .phase = .down, .x = 50, .y = 150, .pointer = 1 });
    router.dispatchPointer(n, .{ .phase = .move, .x = 50, .y = 140, .pointer = 1 });
    try std.testing.expectEqual(@as(f32, 40), s.scroll.offset); // 30 + 10
}
