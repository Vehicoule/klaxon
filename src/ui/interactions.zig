// Interactions — the per-widget interaction tracker, porting upstream's
// InteractionSource semantics:
//   .ref/foundation-interaction/InteractionSource.kt — MutableInteractionSource:
//     an ordered stream of Interaction events the widget emits and the
//     indication consumes (Ripple.kt:362-376 collects it per component).
//   .ref/foundation-interaction/PressInteraction.kt — Press(pressPosition) /
//     Release(press) / Cancel(press); collectIsPressedAsState keeps a list
//     (:82-93: several concurrent presses may be active — multi-touch).
//   .ref/foundation-interaction/HoverInteraction.kt — Enter / Exit(enter).
//   .ref/foundation-interaction/FocusInteraction.kt — Focus / Unfocus(focus).
//   .ref/foundation-interaction/DragInteraction.kt — Start / Stop(start) /
//     Cancel(start).
//   .ref/material-ripple/Ripple.kt:436-466 — the StateLayer's `interactions`
//     list: Enter/Focus/Start add, Exit/Unfocus/Stop/Cancel remove THEIR OWN
//     start instance, and `lastOrNull()` is the interaction to display —
//     the "last interaction wins" rule the widgets hand-roll today (a press
//     overrides a hover for elevation; Button.kt paints it as
//     `hovered and !pressed`).
//
// Upstream emits Interaction OBJECTS into a MutableSharedFlow; collectors
// keep the live ones in a MutableList (Release removes its own Press). This
// port keeps the same semantics allocation-free: a fixed array of active
// entries, each carrying a monotonically increasing id so the end event
// pairs with exactly its start (Release(press), Exit(enter), …).
//
// Focus provenance (focus-visible): upstream has no pointer-driven focus —
// Modifier.clickable never requests focus on press, so a Focus interaction
// there is always keyboard or programmatic. Klaxon widgets DO requestFocus()
// on pointer-down (text fields, toolbar slots); those record .pointer via
// noteFocusVia() so the state layer can gate on it: layerKind() excludes a
// pointer-provenance focus exactly like upstream never emits one. The router
// focus itself is unaffected (keyboard continuity stays).
//
// Not ported: the Flow/stream itself (widgets call the tracker directly),
// rememberInComposition, upstream's unbounded list — max_active caps it at
// MAX_POINTERS (8); past that the OLDEST entry is evicted, the same
// drop-oldest policy MutableSharedFlow applies on buffer overflow
// (InteractionSource.kt:136-140).
//
// WIDGET INTEGRATION (the migration contract — see also state_layer.zig and
// ripple.zig): the widget embeds a Tracker in its state struct, sets
// `tracker.node = n` once at init (every mutation then damages the node
// automatically — it replaces today's manual markDirty on press/hover), and
// translates pointer/focus phases into calls:
//   .down        → press_id = tracker.pressDown(ev.x, ev.y)
//                  + tracker.noteFocusVia(.pointer) BEFORE requestFocus(n)
//                  + ripples.spawn(press_id, ev.x, ev.y, ev.time_ms)
//   .up          → tracker.release(press_id); ripples.release(press_id, ...)
//   drag past    → tracker.cancel(press_id); ripples.release(press_id, ...)
//   the slop / .outside_down
//   .enter/.leave→ hover_id = tracker.hoverEnter() / tracker.endHover()
//   drag start   → drag_id = tracker.dragStart() / tracker.endDrag()
//   focus sync   → tracker.setFocused(input.isFocused(n)) — there is no
//                  focus-gained vtable hook; poll it in paint/on_key.
const std = @import("std");
const node_mod = @import("node.zig");

const Node = node_mod.Node;

/// The four upstream Interaction families (the Interaction.kt subclasses).
pub const Kind = enum { press, hover, focus, drag };

/// How a focus interaction arrived — the focus-visible input modality.
/// Upstream implicitly knows (a Focus interaction can only come from
/// keyboard/programmatic focus); Klaxon widgets record it explicitly.
pub const FocusVia = enum {
    /// Keyboard navigation (Tab traversal, arrows) — the upstream case.
    key,
    /// The widget called requestFocus() from a pointer path. Invisible to
    /// the state layer (upstream never focuses on click).
    pointer,
    /// App/a11y-driven focus (FocusManager.focusNode) — shows like .key.
    program,
};

/// Bound on simultaneously active interactions. Upstream's MutableList is
/// unbounded, but real multiplicity is ≤ live pointers + hover + focus +
/// drag; InputRouter itself captures at most MAX_POINTERS (8). On overflow
/// the oldest entry is evicted (MutableSharedFlow's DROP_OLDEST).
pub const max_active = 8;

/// One active interaction — an upstream start instance plus the id its end
/// event pairs against.
pub const Entry = struct {
    kind: Kind,
    /// Unique per emit; Release/Exit/Unfocus/Stop pair on it.
    id: u32,
    /// Press origin in the node's PARENT space — the PointerEvent.x/y a
    /// widget's on_pointer compares against bounds (upstream pressPosition
    /// is component-local; our paint coords are parent-space too, so the
    /// same values feed the ripple).
    x: f32 = 0,
    y: f32 = 0,
    /// Focus entries only: how this focus was granted (FocusVia).
    focus_via: FocusVia = .key,
};

pub const Tracker = struct {
    /// Ordered live interactions — the StateLayer's `interactions` list
    /// (Ripple.kt:436). Index order is emit order; the last entry is the
    /// interaction to display.
    entries: [max_active]Entry = undefined,
    len: u8 = 0,
    next_id: u32 = 1,
    /// Provenance applied by the NEXT setFocused(true), then reset to .key —
    /// see noteFocusVia.
    pending_focus_via: FocusVia = .key,
    /// Every mutation damages this node — the widget sets it once at init
    /// and the tracker replaces the per-phase `n.markDirty()` calls. Weak
    /// handles aren't needed: the node owns the tracker (it lives inside
    /// the widget's state struct and dies with it).
    node: ?*Node = null,

    fn mark(s: *Tracker) void {
        if (s.node) |n| n.markDirty();
    }

    fn add(s: *Tracker, kind: Kind, x: f32, y: f32, via: FocusVia) u32 {
        if (s.len == max_active) {
            // Past capacity: evict the oldest (upstream's flow drops oldest
            // on overflow; unreachable in practice past 8 pointers).
            std.mem.copyForwards(Entry, s.entries[0 .. max_active - 1], s.entries[1..max_active]);
            s.len -= 1;
        }
        const id = s.next_id;
        s.next_id += 1;
        s.entries[s.len] = .{ .kind = kind, .id = id, .x = x, .y = y, .focus_via = via };
        s.len += 1;
        s.mark();
        return id;
    }

    fn removeAt(s: *Tracker, i: usize) void {
        std.mem.copyForwards(Entry, s.entries[i .. s.len - 1], s.entries[i + 1 .. s.len]);
        s.len -= 1;
        s.mark();
    }

    /// Release(press) / Exit(enter) / Unfocus(focus) / Stop(start): remove
    /// the entry whose id matches — and whose KIND matches (a stale or
    /// mismatched id is a no-op, never removes another kind's entry).
    fn removeKindId(s: *Tracker, kind: Kind, id: u32) void {
        for (s.entries[0..s.len], 0..) |e, i| {
            if (e.id == id and e.kind == kind) {
                s.removeAt(i);
                return;
            }
        }
    }

    /// The newest active entry of `kind` — the end*() convenience paths and
    /// the single-instance queries share it.
    fn newestId(s: *const Tracker, kind: Kind) ?u32 {
        var i = s.len;
        while (i > 0) {
            i -= 1;
            if (s.entries[i].kind == kind) return s.entries[i].id;
        }
        return null;
    }

    // --- emit (MutableInteractionSource.emit equivalents) ---

    /// PressInteraction.Press (PressInteraction.kt:50): a pointer went down
    /// at (x, y) — the PointerEvent coords. Pair the returned id with
    /// release()/cancel() (and use it as the ripple's press key).
    pub fn pressDown(s: *Tracker, x: f32, y: f32) u32 {
        return s.add(.press, x, y, .key);
    }

    /// PressInteraction.Release (:59): the press ended normally.
    pub fn release(s: *Tracker, id: u32) void {
        s.removeKindId(.press, id);
    }

    /// PressInteraction.Cancel (:67): the press was interrupted (drag past
    /// the slop, outside_down, capture moved) — upstream treats Cancel
    /// exactly like Release in every collector.
    pub fn cancel(s: *Tracker, id: u32) void {
        s.removeKindId(.press, id);
    }

    /// Release the newest press — the single-press convenience path.
    pub fn endPress(s: *Tracker) void {
        if (s.newestId(.press)) |id| s.removeKindId(.press, id);
    }

    /// HoverInteraction.Enter (HoverInteraction.kt).
    pub fn hoverEnter(s: *Tracker) u32 {
        return s.add(.hover, 0, 0, .key);
    }

    /// HoverInteraction.Exit(enter).
    pub fn hoverExit(s: *Tracker, id: u32) void {
        s.removeKindId(.hover, id);
    }

    /// Exit the newest hover — the common single-hover path.
    pub fn endHover(s: *Tracker) void {
        if (s.newestId(.hover)) |id| s.removeKindId(.hover, id);
    }

    /// DragInteraction.Start (DragInteraction.kt).
    pub fn dragStart(s: *Tracker) u32 {
        return s.add(.drag, 0, 0, .key);
    }

    /// DragInteraction.Stop/Cancel — same removal either way upstream.
    pub fn dragEnd(s: *Tracker, id: u32) void {
        s.removeKindId(.drag, id);
    }

    /// End the newest drag.
    pub fn endDrag(s: *Tracker) void {
        if (s.newestId(.drag)) |id| s.removeKindId(.drag, id);
    }

    /// Record HOW the imminent focus arrives — call right before
    /// input.requestFocus(n) on a pointer path:
    ///     s.inter.noteFocusVia(.pointer); input.requestFocus(n);
    /// The next setFocused(true) consumes it; it then resets to .key (the
    /// upstream default — a Focus interaction there is never pointer-made).
    pub fn noteFocusVia(s: *Tracker, via: FocusVia) void {
        s.pending_focus_via = via;
    }

    /// FocusInteraction.Focus/Unfocus — sync the focus entry to the polled
    /// truth. There is no focus-gained vtable hook (the router notifies only
    /// the node LOSING focus via on_blur), so widgets poll isFocused() —
    /// typically at the top of on_pointer/on_key/paint:
    ///     s.inter.setFocused(input.isFocused(n));
    /// Repeated calls with the same state are no-ops; noteFocusVia applies
    /// only to the transition edge (and is consumed either way, so a stray
    /// note can't poison a later focus cycle).
    pub fn setFocused(s: *Tracker, focused: bool) void {
        const has = s.newestId(.focus) != null;
        if (focused) {
            if (!has) _ = s.add(.focus, 0, 0, s.pending_focus_via);
            s.pending_focus_via = .key;
        } else if (has) {
            s.removeKindId(.focus, s.newestId(.focus).?);
            s.pending_focus_via = .key;
        }
    }

    /// Remove every interaction — teardown / a widget going disabled
    /// mid-press (upstream's interaction set dies with the component).
    pub fn clear(s: *Tracker) void {
        if (s.len == 0) return;
        s.len = 0;
        s.pending_focus_via = .key;
        s.mark();
    }

    // --- query (the collectIs*AsState collectors + last-wins) ---

    /// The entry for `id`, if still active.
    pub fn get(s: *const Tracker, id: u32) ?Entry {
        for (s.entries[0..s.len]) |e| {
            if (e.id == id) return e;
        }
        return null;
    }

    /// interactions.lastOrNull() — the LAST active interaction wins
    /// (Ripple.kt:466): a press emitted while hovered supersedes the hover
    /// for elevation — the rule Button hand-rolls as `hovered and !pressed`.
    pub fn current(s: *const Tracker) ?Entry {
        if (s.len == 0) return null;
        return s.entries[s.len - 1];
    }

    pub fn countKind(s: *const Tracker, kind: Kind) usize {
        var n: usize = 0;
        for (s.entries[0..s.len]) |e| n += @intFromBool(e.kind == kind);
        return n;
    }

    /// collectIsPressedAsState (PressInteraction.kt:81-94) — one or more
    /// presses active.
    pub fn isPressed(s: *const Tracker) bool {
        return s.countKind(.press) > 0;
    }

    /// collectIsHoveredAsState (HoverInteraction.kt).
    pub fn isHovered(s: *const Tracker) bool {
        return s.countKind(.hover) > 0;
    }

    /// collectIsFocusedAsState (FocusInteraction.kt).
    pub fn isFocused(s: *const Tracker) bool {
        return s.countKind(.focus) > 0;
    }

    /// collectIsDraggedAsState (DragInteraction.kt).
    pub fn isDragged(s: *const Tracker) bool {
        return s.countKind(.drag) > 0;
    }

    /// The newest focus entry's provenance, if focused at all.
    pub fn focusVia(s: *const Tracker) ?FocusVia {
        var i = s.len;
        while (i > 0) {
            i -= 1;
            if (s.entries[i].kind == .focus) return s.entries[i].focus_via;
        }
        return null;
    }

    /// Focus-visible: focused AND the focus didn't come from a pointer.
    /// Upstream has this for free (click never focuses); Klaxon widgets that
    /// take pointer focus gate the focus layer on this so a mouse click
    /// doesn't light the keyboard-focus overlay.
    pub fn focusVisible(s: *const Tracker) bool {
        const via = s.focusVia() orelse return false;
        return via != .pointer;
    }

    /// The interaction the STATE LAYER shows — the newest of
    /// hover/focus/drag. Two upstream rules fold in here:
    ///   - press never enters the layer (Ripple.kt:365-375 routes
    ///     PressInteraction to addRipple/removeRipple — the ripple IS the
    ///     press layer — and never to updateStateLayer), so a press does not
    ///     clear a hover underneath it;
    ///   - a pointer-provenance focus is excluded (focusVisible) — upstream
    ///     never emits it in the first place.
    /// Scanning past an excluded entry is what upstream's list semantics do:
    /// an interaction that was never added can't shadow the one before it.
    pub fn layerKind(s: *const Tracker) ?Kind {
        var i = s.len;
        while (i > 0) {
            i -= 1;
            const e = s.entries[i];
            switch (e.kind) {
                .press => continue,
                .focus => {
                    if (e.focus_via != .pointer) return .focus;
                },
                else => return e.kind,
            }
        }
        return null;
    }
};

// --- tests ---

fn trackerFixture() Tracker {
    return .{};
}

test "press/release pair by id; two presses stay until both released" {
    var t = trackerFixture();
    const p1 = t.pressDown(4, 5);
    const p2 = t.pressDown(7, 8);
    try std.testing.expect(t.isPressed());
    try std.testing.expectEqual(@as(usize, 2), t.countKind(.press));
    // The entry carries the press position (PressInteraction.Press).
    const e = t.get(p1).?;
    try std.testing.expectEqual(Kind.press, e.kind);
    try std.testing.expectEqual(@as(f32, 4), e.x);
    try std.testing.expectEqual(@as(f32, 5), e.y);
    t.release(p1);
    try std.testing.expect(t.isPressed()); // p2 still held (collectIsPressedAsState)
    t.cancel(p2);
    try std.testing.expect(!t.isPressed());
    // Releasing an unknown id is a no-op; a press id can't end a hover.
    const h = t.hoverEnter();
    t.release(h);
    try std.testing.expect(t.isHovered());
    t.endHover();
    try std.testing.expect(!t.isHovered());
}

test "last interaction wins (upstream lastOrNull)" {
    var t = trackerFixture();
    _ = t.hoverEnter();
    try std.testing.expectEqual(Kind.hover, t.current().?.kind);
    const p = t.pressDown(1, 1);
    // A press emitted while hovered supersedes it — Button's
    // `hovered and !pressed` elevation rule as data.
    try std.testing.expectEqual(Kind.press, t.current().?.kind);
    try std.testing.expect(t.isHovered()); // the hover is still in the set
    t.release(p);
    try std.testing.expectEqual(Kind.hover, t.current().?.kind);
    t.endHover();
    try std.testing.expect(t.current() == null);
}

test "layerKind: press never enters the layer; it doesn't shadow the hover under it" {
    var t = trackerFixture();
    _ = t.hoverEnter();
    const p = t.pressDown(2, 2);
    // Upstream routes Press to addRipple, not updateStateLayer — the hover
    // layer keeps painting under the expanding ripple.
    try std.testing.expectEqual(Kind.hover, t.layerKind().?);
    t.release(p);
    try std.testing.expectEqual(Kind.hover, t.layerKind().?);
    t.endHover();
    try std.testing.expect(t.layerKind() == null);
}

test "layerKind: drag and key-focus shadow the hover; drag-end falls back" {
    var t = trackerFixture();
    _ = t.hoverEnter();
    const d = t.dragStart();
    try std.testing.expectEqual(Kind.drag, t.layerKind().?);
    t.dragEnd(d);
    try std.testing.expectEqual(Kind.hover, t.layerKind().?);
    t.setFocused(true); // default via .key — keyboard/programmatic focus
    try std.testing.expect(t.isFocused());
    try std.testing.expect(t.focusVisible());
    try std.testing.expectEqual(Kind.focus, t.layerKind().?);
    t.setFocused(false);
    try std.testing.expectEqual(Kind.hover, t.layerKind().?);
}

test "focus-visible gating: pointer-provenance focus is invisible to the layer" {
    var t = trackerFixture();
    _ = t.hoverEnter();
    // The pointer path: note BEFORE requestFocus, then sync the truth.
    t.noteFocusVia(.pointer);
    t.setFocused(true);
    try std.testing.expect(t.isFocused()); // collectIsFocusedAsState — raw truth
    try std.testing.expect(!t.focusVisible());
    // Upstream never emits the focus at all here → the hover still shows.
    try std.testing.expectEqual(Kind.hover, t.layerKind().?);
    t.setFocused(false);
    // Keyboard focus shows the layer.
    t.setFocused(true);
    try std.testing.expect(t.focusVisible());
    try std.testing.expectEqual(Kind.focus, t.layerKind().?);
    // A stray note on an already-focused node is consumed, not stored:
    // the focus keeps its keyboard provenance like upstream's live Focus.
    t.noteFocusVia(.pointer);
    t.setFocused(true);
    try std.testing.expect(t.focusVisible());
}

test "overflow evicts the oldest entry (upstream drop-oldest)" {
    var t = trackerFixture();
    var ids: [max_active]u32 = undefined;
    for (&ids) |*id| id.* = t.hoverEnter();
    try std.testing.expectEqual(@as(usize, max_active), t.countKind(.hover));
    _ = t.hoverEnter(); // +1 over capacity → oldest out
    try std.testing.expectEqual(@as(usize, max_active), t.countKind(.hover));
    try std.testing.expect(t.get(ids[0]) == null);
    try std.testing.expect(t.get(ids[max_active - 1]) != null);
    // The evicted start can still be "ended" harmlessly.
    t.hoverExit(ids[0]);
    try std.testing.expectEqual(@as(usize, max_active), t.countKind(.hover));
    t.clear();
    try std.testing.expectEqual(@as(usize, 0), t.len);
}
