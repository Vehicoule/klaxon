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
    /// Row recycling (RecyclerView-style): rebind a leaving item node to a
    /// new index instead of destroy+create. Return false to decline — the
    /// caller destroys the node and rebuilds through fn_ptr. The rebound
    /// node must repaint identically to a fresh one: mark the subtree dirty
    /// inside (a retained node's cached image re-rasterizes on the next
    /// paint — the dirty flag drives that).
    rebind: ?*const fn (userdata: ?*anyopaque, index: usize, node: *Node) bool = null,
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
/// Physics: drags rubber-band past the edges (iOS-style diminishing
/// resistance), a fast release flings with exponential-decay momentum, and
/// an overscrolled rest position eases back to the edge. The flight runs on
/// the animation timeline — the ticker borrows the ScrollInput, so the
/// widget's deinit must call inp.deinit().
///
/// `set_offset` is the widget's apply function: it clamps, shifts the
/// virtualization window and marks the node dirty — and returns whether the
/// offset changed.
pub const ScrollInput = struct {
    pub const MAX_TRACKS = 8; // matches input.MAX_POINTERS
    /// y is window-space (raw_y) — see the struct doc above.
    const Track = struct {
        pointer: u64 = 0,
        y: f32 = 0,
        active: bool = false,
        /// Content-space velocity EMA in px/ms (finger up = positive —
        /// offsets grow). Drives the release fling.
        vel: f32 = 0,
        last_ms: u64 = 0,
    };
    tracks: [MAX_TRACKS]Track = std.mem.zeroes([MAX_TRACKS]Track),

    // Momentum state — one flight per scrollable. `fling_v` is the content
    // velocity (px/ms, positive scrolls down); the same ticker settles
    // rubber-band overscroll back to the edge (v=0 while overscrolled).
    fling_v: f32 = 0,
    fling_ms: u64 = 0,
    fling_on: bool = false,
    ticker_live: bool = false,
    fling_scroll: ?*scroll_mod.ScrollState = null,
    fling_set: ?SetOffset = null,
    fling_node: ?*Node = null,

    /// Rubber-band edges. A wrapping gesture consumer (pull-to-refresh)
    /// turns this off — it supplies its own elastic feedback instead.
    bounces: bool = true,

    /// Rubber-band: reach ~1/3 of the viewport, per-delta factor starts at
    /// the iOS 0.55 and shrinks quadratically as the band fills.
    const OVER_FRACTION: f32 = 0.30;
    const OVER_MIN: f32 = 24;
    const RESIST_C: f32 = 0.55;
    /// Momentum: releases slower than FLING_MIN px/ms settle in place.
    const FLING_MIN: f32 = 0.18;
    const FLING_DECEL: f32 = 0.0038; // exponential — ~55% left per 210ms
    const EDGE_DECEL: f32 = 0.02; // snap-back rate while overscrolled
    const FLING_EPS: f32 = 0.02; // dead velocity, px/ms
    const VEL_STALE_MS: u64 = 120; // a held-still finger doesn't fling

    pub const SetOffset = *const fn (n: *Node, value: f32) bool;

    fn overLimit(scroll: *const scroll_mod.ScrollState) f32 {
        return @max(OVER_MIN, scroll.viewport * OVER_FRACTION);
    }

    /// iOS rubber-band derivative: the fraction of a push-deeper delta that
    /// applies, shrinking quadratically as the band fills.
    fn resistFactor(over: f32, limit: f32) f32 {
        const denom = limit + RESIST_C * over;
        return RESIST_C * limit * limit / (denom * denom);
    }

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

    /// Apply a content offset target: the in-bounds part goes through the
    /// widget's setter (window sync + damage); the overshoot stretches the
    /// rubber band — resisted pushing deeper, free pulling back.
    fn applyTarget(inp: *ScrollInput, n: *Node, scroll: *scroll_mod.ScrollState, set_offset: SetOffset, target: f32) bool {
        const max = scroll.maxOffset();
        if (target >= 0 and target <= max) return set_offset(n, target);
        if (!inp.bounces) return set_offset(n, std.math.clamp(target, 0, max)); // a wrapper owns the edge
        const edge: f32 = if (target < 0) 0 else max;
        const want_over = target - edge; // signed
        const cur = scroll.overscroll();
        const d = want_over - cur;
        const pushing = @abs(want_over) > @abs(cur);
        const applied = if (pushing) d * resistFactor(@abs(cur), overLimit(scroll)) else d;
        const final = edge + cur + applied;
        _ = set_offset(n, edge);
        if (scroll.setOffsetLoose(final, overLimit(scroll))) n.markDirty();
        return true;
    }

    /// Call from the widget's on_pointer.
    pub fn onPointer(inp: *ScrollInput, ev: input.PointerEvent, scroll: *scroll_mod.ScrollState, set_offset: SetOffset, n: *Node) bool {
        switch (ev.phase) {
            .down => {
                const t = inp.trackFor(ev.pointer);
                t.* = .{ .pointer = ev.pointer, .y = ev.raw_y, .active = true, .last_ms = ev.time_ms };
                inp.stopFling(); // grabbing the content kills the flight
                return false; // items handle taps
            },
            .up, .outside_down => {
                // Fling with the release velocity; an overscrolled rest
                // snaps back regardless. A stale last move (finger held
                // still past VEL_STALE_MS) means no fling.
                var v: f32 = 0;
                for (&inp.tracks) |*t| {
                    if (t.active and t.pointer == ev.pointer) {
                        if (ev.time_ms -| t.last_ms <= VEL_STALE_MS) v = t.vel;
                        t.active = false;
                    }
                }
                if (scroll.overscroll() != 0 or @abs(v) > FLING_MIN)
                    inp.startFlight(n, scroll, set_offset, v, ev.time_ms);
                return false;
            },
            .move => {},
            else => return false,
        }
        const router = input.current() orelse return false;
        const dragging = router.capturedNode(ev.pointer) != null;
        const t = inp.trackFor(ev.pointer);
        const same = t.active and t.pointer == ev.pointer;
        const last = if (same) t.y else ev.raw_y;
        const last_ms = if (same) t.last_ms else ev.time_ms;
        var vel = if (same) t.vel else 0;
        // Velocity sample: content velocity is the finger's negated delta
        // (finger up → offset grows). EMA so one big event can't dominate.
        if (ev.time_ms > last_ms) {
            const inst = (last - ev.raw_y) / @as(f32, @floatFromInt(ev.time_ms - last_ms));
            vel = vel * 0.65 + inst * 0.35;
        }
        t.* = .{ .pointer = ev.pointer, .y = ev.raw_y, .active = true, .vel = vel, .last_ms = ev.time_ms };
        if (!dragging) return false; // hover move: no scroll
        const dy = ev.raw_y - last;
        if (dy == 0) return false;
        // The finger drags the content: moving up (dy < 0) increases the offset.
        return applyTarget(inp, n, scroll, set_offset, scroll.offset - dy);
    }

    /// Call from the widget's on_scroll (wheel). Positive delta_y = scroll
    /// up = offset decreases.
    pub fn onScroll(inp: *ScrollInput, ev: input.ScrollEvent, scroll: *scroll_mod.ScrollState, wheel_speed: f32, set_offset: SetOffset, n: *Node) bool {
        if (!scroll.info().canScroll()) return false;
        inp.stopFling(); // a wheel tick takes the content back
        // Wheel/trackpad deltas arrive already-momentized by the OS — apply
        // directly (no rubber band: desktops hard-stop at edges).
        const max = scroll.maxOffset();
        const inside = std.math.clamp(scroll.offset - ev.delta_y * wheel_speed, 0, max);
        return set_offset(n, inside);
    }

    /// Kill a running flight + drop the ticker. Widget deinits call this —
    /// the ticker borrows the ScrollInput, it must not outlive the state.
    pub fn deinit(inp: *ScrollInput) void {
        inp.stopFling();
    }

    fn startFlight(inp: *ScrollInput, n: *Node, scroll: *scroll_mod.ScrollState, set_offset: SetOffset, v: f32, now_ms: u64) void {
        inp.fling_v = v;
        inp.fling_ms = now_ms;
        inp.fling_on = true;
        inp.fling_scroll = scroll;
        inp.fling_set = set_offset;
        inp.fling_node = n;
        if (!inp.ticker_live) {
            const tl = ui.anim.timeline() orelse {
                inp.fling_on = false;
                // No timeline: settle synchronously — an overscroll must
                // never persist without the ticker that would unwind it.
                if (scroll.overscroll() != 0) {
                    _ = scroll.setOffsetLoose(std.math.clamp(scroll.offset, 0, scroll.maxOffset()), overLimit(scroll));
                    n.markDirty();
                }
                return;
            };
            tl.addTicker(.{ .fn_ptr = flightTickCb, .userdata = inp, .has_pending = flightPendingCb });
            inp.ticker_live = true;
        }
    }

    fn stopFling(inp: *ScrollInput) void {
        inp.fling_on = false;
        inp.fling_v = 0;
        if (inp.ticker_live) {
            if (ui.anim.timeline()) |tl|
                tl.removeTicker(.{ .fn_ptr = flightTickCb, .userdata = inp });
            inp.ticker_live = false;
        }
    }

    fn flightPendingCb(userdata: ?*anyopaque) bool {
        const inp: *ScrollInput = @ptrCast(@alignCast(userdata.?));
        return inp.fling_on;
    }

    fn flightTickCb(userdata: ?*anyopaque, now_ms: u64) void {
        const inp: *ScrollInput = @ptrCast(@alignCast(userdata.?));
        if (!inp.fling_on) return;
        const scroll = inp.fling_scroll.?;
        const n = inp.fling_node.?;
        const set_offset = inp.fling_set.?;
        const dt: f32 = @floatFromInt(@min(now_ms -| inp.fling_ms, 32));
        inp.fling_ms = now_ms;
        const max = scroll.maxOffset();
        const limit = overLimit(scroll);

        var v = inp.fling_v;
        var target = scroll.offset;
        if (v != 0) {
            var step = v * dt;
            // Momentum pushing deeper into the band is resisted like a drag.
            const cur = @abs(scroll.overscroll());
            if (cur > 0) step *= resistFactor(cur, limit);
            target += step;
            v *= @exp(-dt * FLING_DECEL);
            if (@abs(v) < FLING_EPS) v = 0;
        }
        // The rubber band pulls back to its edge — exponential settle.
        const over = overscrollOf(target, max);
        if (over != 0) {
            target -= over * (1 - @exp(-dt * EDGE_DECEL));
            v *= @exp(-dt * EDGE_DECEL); // the band eats leftover momentum
        }
        const inside = std.math.clamp(target, 0, max);
        _ = set_offset(n, inside);
        if (target != inside) {
            _ = scroll.setOffsetLoose(target, limit);
            n.markDirty();
        }
        inp.fling_v = v;
        if (v == 0 and scroll.overscroll() == 0) inp.stopFling();
    }

    fn overscrollOf(offset: f32, max: f32) f32 {
        if (offset < 0) return offset;
        return @max(0, offset - max);
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
    // Non-overlapping windows (or an empty window): re-anchor — a large
    // jump must NOT materialize the intervening items. With a rebind-capable
    // factory the live rows recycle in place (a jump still has zero
    // creates); a decline mid-window drops the stale tail and the fill
    // loop rebuilds the rest.
    const old_last = first.* + n.children.items.len;
    const overlaps = first.* < range.last and range.first < old_last;
    if (!overlaps) {
        var recycled: usize = 0;
        if (factory.rebind) |rebind| {
            while (recycled < n.children.items.len and
                range.first + recycled < range.last)
            {
                const child = n.children.items[recycled];
                if (!rebind(factory.userdata, range.first + recycled, child)) break;
                layout_item(n, child, range.first + recycled);
                recycled += 1;
            }
        }
        // Drop the un-recycled tail — detach-then-deinit from the back:
        // deinit() may DEFER the destroy (zombie), and the sweep's
        // parent.detach would shift the array under a for-loop's captured
        // slice.
        while (n.children.items.len > recycled) {
            const child = n.children.items[n.children.items.len - 1];
            _ = n.remove(child);
            child.deinit();
        }
        first.* = range.first;
    }
    // Trim items that left the window (front): when the factory can rebind
    // and the window still needs rows at the back, the leaving row recycles
    // straight into the entering slot — remove+rebind+add, zero create/
    // destroy (the scroll tick's dominant cost was one row lifecycle per
    // frame). Otherwise destroy and advance `first` — advancing continues
    // past an empty window (the children were never created or are already
    // gone).
    while (first.* < range.first) {
        if (n.children.items.len > 0) {
            const child = n.children.items[0];
            // After removing the front row the children span [first+1,
            // first+len): the fresh back slot is index first+len — computed
            // against the PRE-removal length.
            const recycle_to = first.* + n.children.items.len;
            _ = n.remove(child); // detach first — a rebind may mark dirty
            if (factory.rebind != null and recycle_to < range.last and
                factory.rebind.?(factory.userdata, recycle_to, child))
            {
                n.add(child);
                layout_item(n, child, recycle_to);
            } else {
                child.deinit();
            }
        }
        first.* += 1;
    }
    // Trim items that left the window (back) — symmetric recycling into a
    // needed front slot.
    while (first.* + n.children.items.len > range.last and n.children.items.len > 0) {
        const last = n.children.items.len - 1;
        const child = n.children.items[last];
        const recycle = factory.rebind != null and first.* > range.first;
        _ = n.remove(child); // detach then deinit — never the reverse
        if (recycle and factory.rebind.?(factory.userdata, first.* - 1, child)) {
            first.* -= 1;
            n.insert(0, child);
            layout_item(n, child, first.*);
        } else {
            child.deinit();
        }
    }
    // Items entering at the front (scrolled up): prepend. Route through
    // insert() — NOT a raw children.insert: the parent pointer, the
    // dirty/layout marks, and the overlay_subtree propagation must all run
    // (a prepended item painting over the viewport edge without a damage
    // mark would tear on a clipped repaint).
    while (first.* > range.first) {
        first.* -= 1;
        const node = factory.fn_ptr(factory.userdata, first.*);
        n.insert(0, node); // sets parent + marks dirty/layout + overlay
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
    // press (capture + track), then drag DOWN 30px: the finger pulls the
    // content past the top — the rubber band resists (-30 × 0.55 = -16.5)
    router.dispatchPointer(n, .{ .phase = .down, .x = 50, .y = 100 });
    router.dispatchPointer(n, .{ .phase = .move, .x = 50, .y = 130 });
    try std.testing.expectEqual(@as(f32, -16.5), s.scroll.offset); // stretched, not clamped
    try std.testing.expectEqual(@as(u32, 1), s.set_calls);
    try std.testing.expectEqual(@as(f32, 0), s.last_value); // the widget setter saw the edge
    // drag UP 50px from there: -16.5 + 50 = +33.5 (the band releases first)
    router.dispatchPointer(n, .{ .phase = .move, .x = 50, .y = 80 });
    try std.testing.expectEqual(@as(f32, 33.5), s.scroll.offset);
    try std.testing.expectEqual(@as(u32, 2), s.set_calls);
    try std.testing.expectEqual(@as(f32, 33.5), s.last_value);
    // release: the track ends; a later hover move does not scroll
    router.dispatchPointer(n, .{ .phase = .up, .x = 50, .y = 80 });
    router.dispatchPointer(n, .{ .phase = .move, .x = 50, .y = 10 });
    try std.testing.expectEqual(@as(f32, 33.5), s.scroll.offset);
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
