// StateLayer — the animated interaction-state overlay, porting upstream's
// private StateLayer class:
//   .ref/material-ripple/Ripple.kt:412-503 — StateLayer: one Animatable
//     alpha, a list of active interactions, `currentInteraction =
//     lastOrNull()`, and the retarget rule (:468-487): a NEW interaction
//     tweens the alpha in with ITS incoming spec; returning to no state
//     tweens out with the OUTGOING spec of the interaction being left.
//     (Upstream's two-layer incoming+outgoing design is deliberately
//     skipped upstream too — see the comment at :414-432 — we match the
//     single-layer result.)
//   .ref/material-ripple/Ripple.kt:505-529 — incoming/
//     outgoingStateLayerAnimationSpecFor: Hover → DefaultTweenSpec;
//     Focus/Drag → TweenSpec(45ms, Linear); drag-OUT → 150ms Linear;
//     everything else → DefaultTweenSpec = 15ms Linear (:529).
//   .ref/material-ripple/RippleTheme.kt:141-146 — the RippleAlpha record
//     (dragged/focused/hovered/pressed alphas). Default values here are the
//     Klaxon theme.state table (hover 0.08 / focus 0.10 / pressed 0.12 /
//     drag 0.16): upstream's material3 StateTokens use pressed 0.10
//     (.ref/material3/tokens/StateTokens.kt:25), while the legacy
//     material-ripple low-contrast table (RippleTheme.kt:211-217) uses
//     0.12 — Klaxon standardizes on 0.12 and widgets pass theme.state
//     through regardless.
//
// Upstream's StateLayer owns the interaction list; here interactions.zig's
// Tracker owns it — this module is just the animated alpha + the spec
// table. The widget keeps one StateLayer in its state struct (embed by
// value — `channel` and the timeline callback take its address), calls
//   s.layer.set(s.inter.layerKind() orelse .none? — see sync()) — or
//   s.layer.sync(&s.inter, on_color)
// whenever the interaction set may have changed, then each paint reads
//   if (s.layer.paintColor()) |c| ui.paint.fillRRect(ctx, ..., c);
// and paints it over the container fill, under the ripple + content (the
// node's own paint always runs before its children's — upstream's
// RippleNode.draw order is drawContent → stateLayer → ripples).
//
// `.press` as a set() target: upstream never routes presses into the layer
// (its `else -> 0f` would even draw one at 0 — Ripple.kt:476). Kind.press is
// kept in the API so a widget WITHOUT a wired ripple can still show the
// pressed overlay through the same animated path (today's static overlay).
// With ripples wired, leave press to ripple.zig — sync() already does.
const std = @import("std");
const anim = @import("anim.zig");
const paint_mod = @import("paint.zig");
const node_mod = @import("node.zig");
const interactions = @import("interactions.zig");

const Node = node_mod.Node;
const Color = paint_mod.Color;

pub const Kind = interactions.Kind;

/// DefaultTweenSpec = TweenSpec(15ms, LinearEasing) (Ripple.kt:529) — the
/// fallback for every incoming/outgoing case not listed upstream.
pub const default_tween_ms: u32 = 15;
/// Focus/Drag incoming: TweenSpec(45, Linear) (:512-513).
pub const focus_in_ms: u32 = 45;
pub const drag_in_ms: u32 = 45;
/// Drag outgoing: TweenSpec(150, Linear) (:523) — the only non-default exit.
pub const drag_out_ms: u32 = 150;

/// RippleAlpha (RippleTheme.kt:141-146) — per-interaction overlay opacity.
/// Field names match Klaxon's theme.state (pressed/focus/hover/drag).
pub const Alphas = struct {
    hover: f32 = 0.08, // HoverStateLayerOpacity (StateTokens.kt:24)
    focus: f32 = 0.10, // FocusStateLayerOpacity (:23)
    pressed: f32 = 0.12, // theme.state.pressed — see header note vs tokens' 0.10
    drag: f32 = 0.16, // DraggedStateLayerOpacity (:22)

    /// The when(newInteraction) target table (Ripple.kt:471-477).
    pub fn target(a: Alphas, kind: Kind) f32 {
        return switch (kind) {
            .hover => a.hover,
            .focus => a.focus,
            .press => a.pressed,
            .drag => a.drag,
        };
    }
};

/// incomingStateLayerAnimationSpecFor (Ripple.kt:509-516) — every upstream
/// spec is LinearEasing, so only the duration varies.
pub fn incomingMs(kind: Kind) u32 {
    return switch (kind) {
        .focus => focus_in_ms,
        .drag => drag_in_ms,
        else => default_tween_ms, // Hover → default; press/others → default
    };
}

/// outgoingStateLayerAnimationSpecFor (Ripple.kt:519-526) — keyed on the
/// interaction being LEFT, not the one being entered.
pub fn outgoingMs(prev: ?Kind) u32 {
    return switch (prev orelse return default_tween_ms) {
        .drag => drag_out_ms,
        else => default_tween_ms, // Hover/Focus → default
    };
}

pub const StateLayer = struct {
    /// The opacity table (theme.state drives it in widgets).
    alphas: Alphas = .{},
    /// The on-color the last set() recorded — paintColor() modulates it.
    /// Upstream reads the color fresh each draw; retargeting it without a
    /// kind change does NOT restart the animation, only repaints.
    color: Color = 0,
    /// animatedAlpha (Ripple.kt:434) — the current layer opacity.
    alpha_now: f32 = 0,
    /// currentInteraction (:437) — the kind the layer is showing (or headed
    /// to; null = no state). The interaction set lives in the Tracker.
    kind: ?Kind = null,
    /// Timeline channel marker — a stable field address, like the widgets'
    /// *_channel members. Embed StateLayer by value inside the widget state
    /// and never move it after the first set() (the running tween's
    /// userdata is `l`).
    channel: u8 = 0,
    /// Repaint hook: marked dirty on every alpha update + every set().
    node: ?*Node = null,

    /// StateLayer.handleInteraction's retarget half (Ripple.kt:468-487):
    /// a kind change tweens alpha_now → the target with the incoming spec of
    /// the NEW kind, or → 0 with the outgoing spec of the kind being left.
    /// Upstream's Animatable continues from the in-flight value — ours does
    /// the same (alpha_now is the last ticked value; a channel retarget
    /// replaces the previous tween in place).
    pub fn set(l: *StateLayer, target: ?Kind, color: Color) void {
        const changed = target != l.kind;
        if (!changed and color == l.color) return;
        const prev = l.kind;
        l.kind = target;
        l.color = color;
        if (l.node) |n| n.markDirty();
        if (!changed) return; // color-only update: repaint, don't retarget
        const to: f32 = if (target) |k| l.alphas.target(k) else 0;
        const ms: u32 = if (target != null) incomingMs(target.?) else outgoingMs(prev);
        if (anim.timeline()) |tl| {
            _ = tl.play(.{
                .kind = anim.Animation.tweenAnim(.{ to, 0, 0, 0 }, ms, .{ .ease = .linear }),
                .from = .{ l.alpha_now, 0, 0, 0 },
                .channel = @ptrCast(&l.channel),
                .on_update = .{ .fn_ptr = alphaCb, .userdata = l },
            });
        } else {
            l.alpha_now = to; // no timeline → snap (the widgets' convention)
        }
    }

    /// Recompute the layer target from the tracker — upstream's per-event
    /// `else -> updateStateLayer(interaction)` collect as a poll. Call after
    /// mutating the tracker (end of on_pointer/on_blur) or per-paint; it's
    /// cheap and idempotent when nothing changed.
    pub fn sync(l: *StateLayer, t: *const interactions.Tracker, color: Color) void {
        l.set(t.layerKind(), color);
    }

    /// animatedAlpha.value (Ripple.kt:491).
    pub fn alpha(l: *const StateLayer) f32 {
        return l.alpha_now;
    }

    /// The modulated draw color — `color.copy(alpha = alpha)` (Ripple.kt:494):
    /// the layer alpha REPLACES the color's alpha channel (absolute, not
    /// multiplied). Null when alpha <= 0 (the `alpha > 0f` draw gate :493).
    pub fn paintColor(l: *const StateLayer) ?Color {
        if (l.alpha_now <= 0) return null;
        return copyAlpha(l.color, l.alpha_now);
    }

    /// Widget teardown: cancel the in-flight tween before the state struct
    /// is freed — the channel slot and the callback's userdata are `l` and
    /// would dangle otherwise. Call from the widget's deinit.
    pub fn deinit(l: *StateLayer) void {
        if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&l.channel));
    }

    fn alphaCb(userdata: ?*anyopaque, v: anim.Vec4) void {
        const l: *StateLayer = @ptrCast(@alignCast(userdata.?));
        l.alpha_now = v[0];
        if (l.node) |n| n.markDirty();
    }
};

/// Color.copy(alpha = a) — set the alpha channel absolutely (upstream's
/// modulatedColor for the state layer, Ripple.kt:494; the ripple multiplies
/// instead — see ripple.zig).
pub fn copyAlpha(c: Color, a: f32) Color {
    const b: u32 = @intFromFloat(std.math.clamp(a, 0, 1) * 255 + 0.5);
    return (c & 0xFFFFFF00) | @min(b, 255);
}

// --- tests ---

fn testLayer() StateLayer {
    return .{ .alphas = .{ .hover = 0.08, .focus = 0.10, .pressed = 0.12, .drag = 0.16 } };
}

const on_color: Color = 0x112233FF;

test "hover tweens in over the default spec, out the same way" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var l = testLayer();
    l.set(.hover, on_color);
    try std.testing.expectEqual(@as(?Kind, .hover), l.kind);
    tl.tick(0); // lazy start: start_ms = 0
    try std.testing.expectApproxEqAbs(@as(f32, 0), l.alpha(), 1e-4);
    tl.tick(15); // DefaultTweenSpec 15ms → done
    try std.testing.expectApproxEqAbs(@as(f32, 0.08), l.alpha(), 1e-4);
    // Back to none: outgoing spec of Hover = default 15ms.
    l.set(null, on_color);
    tl.tick(15); // lazy start at 15
    tl.tick(22);
    try std.testing.expect(l.alpha() < 0.08 and l.alpha() > 0); // mid-fade
    tl.tick(30);
    try std.testing.expectApproxEqAbs(@as(f32, 0), l.alpha(), 1e-4);
    try std.testing.expect(l.paintColor() == null);
}

test "focus uses the 45ms incoming spec" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var l = testLayer();
    l.set(.focus, on_color);
    tl.tick(0);
    tl.tick(15);
    try std.testing.expectApproxEqAbs(@as(f32, 0.10 * 15.0 / 45.0), l.alpha(), 1e-3);
    tl.tick(45);
    try std.testing.expectApproxEqAbs(@as(f32, 0.10), l.alpha(), 1e-4);
}

test "state→state retarget: hover → focus keeps the in-flight alpha" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var l = testLayer();
    l.set(.hover, on_color);
    tl.tick(0);
    tl.tick(15); // fully in at 0.08
    l.set(.focus, on_color); // retarget: 0.08 → 0.10 over 45ms
    tl.tick(15); // lazy start
    tl.tick(15 + 45);
    try std.testing.expectApproxEqAbs(@as(f32, 0.10), l.alpha(), 1e-4);
    // A mid-flight retarget continues from the current value, not from 0.
    l.set(.hover, on_color);
    tl.tick(60);
    tl.tick(60 + 15); // 15ms default → 0.08
    try std.testing.expectApproxEqAbs(@as(f32, 0.08), l.alpha(), 1e-4);
}

test "drag: 45ms in, the long 150ms out" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var l = testLayer();
    l.set(.drag, on_color);
    tl.tick(0);
    tl.tick(45);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), l.alpha(), 1e-4);
    l.set(null, on_color); // outgoing spec of Drag = 150ms
    tl.tick(45);
    tl.tick(45 + 75); // halfway → 0.08
    try std.testing.expectApproxEqAbs(@as(f32, 0.08), l.alpha(), 1e-3);
    tl.tick(45 + 150);
    try std.testing.expectApproxEqAbs(@as(f32, 0), l.alpha(), 1e-4);
}

test "sync reads the tracker: hover → press keeps hover, release restores it" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var l = testLayer();
    var t = interactions.Tracker{};
    _ = t.hoverEnter();
    l.sync(&t, on_color);
    tl.tick(0);
    tl.tick(15);
    try std.testing.expectApproxEqAbs(@as(f32, 0.08), l.alpha(), 1e-4);
    // A press doesn't retarget the layer (its ink is the ripple).
    const p = t.pressDown(0, 0);
    l.sync(&t, on_color);
    tl.tick(30);
    try std.testing.expectApproxEqAbs(@as(f32, 0.08), l.alpha(), 1e-4);
    // Focus (keyboard) shadows the hover — upstream lastOrNull.
    t.setFocused(true);
    l.sync(&t, on_color);
    tl.tick(30); // lazy start of the 45ms focus-in
    tl.tick(75);
    try std.testing.expectApproxEqAbs(@as(f32, 0.10), l.alpha(), 1e-4);
    t.setFocused(false);
    t.release(p);
    l.sync(&t, on_color);
    tl.tick(75);
    tl.tick(90); // 15ms back to hover 0.08
    try std.testing.expectApproxEqAbs(@as(f32, 0.08), l.alpha(), 1e-4);
}

test "press target is opt-in for non-ripple widgets (static-overlay parity)" {
    var l = testLayer(); // no timeline → snap
    l.set(.press, on_color);
    try std.testing.expectApproxEqAbs(@as(f32, 0.12), l.alpha(), 1e-4);
    const c = l.paintColor().?;
    try std.testing.expectEqual(@as(u32, 0x1F), c & 0xFF); // copy(alpha=0.12) → round(0.12*255)
    try std.testing.expectEqual(@as(u32, 0x11223300), c & 0xFFFFFF00);
}

test "no timeline: set() snaps straight to the target" {
    var l = testLayer();
    l.set(.hover, on_color);
    try std.testing.expectApproxEqAbs(@as(f32, 0.08), l.alpha(), 1e-4);
    l.set(null, on_color);
    try std.testing.expectApproxEqAbs(@as(f32, 0), l.alpha(), 1e-4);
}

test "same-kind set() repaints but doesn't restart the tween" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var l = testLayer();
    l.set(.hover, on_color);
    tl.tick(0);
    tl.tick(15); // done at 0.08
    l.set(.hover, 0xAABBCCFF); // new color, same kind → no retarget
    tl.tick(30);
    try std.testing.expectApproxEqAbs(@as(f32, 0.08), l.alpha(), 1e-4);
    try std.testing.expectEqual(@as(u32, 0xAABBCC00), l.paintColor().? & 0xFFFFFF00);
}
