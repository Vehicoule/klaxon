// Ripple — the expanding ink of a press, porting the vendored
// material-ripple implementation:
//   .ref/material-ripple/RippleAnimation.kt — the whole animation:
//     fadeIn() = three concurrent tweens (:83-104) — animatedAlpha 0→1 over
//     FadeInDuration (75ms, Linear), animatedRadiusPercent + animatedCenter-
//     Percent 0→1 over RadiusDuration (225ms; radius is FastOutSlowInEasing,
//     center Linear) — then animate() WAITS for the finish signal before
//     fadeOut() (:76-81): alpha 1→0 over FadeOutDuration (150ms, Linear).
//     An early finish can't cut the expansion short: the finish only lands
//     after fade-in completes, and while `finishRequested &&
//     !finishedFadingIn` the drawn alpha is forced to 1 (:134-139).
//     Draw math (:122-154): radius = lerp(startRadius, radius, radiusP),
//     center = lerp(origin, boundsCenter, centerP), modulatedColor =
//     color.copy(alpha = color.alpha * alpha); bounded draws inside
//     clipRect, unbounded unclipped.
//     getRippleStartRadius (:161) = max(w,h)*0.3; getRippleEndRadius
//     (:168-175) = bounds diagonal/2 (+ BoundedRippleExtraRadius 10dp when
//     bounded, :177-178 — Klaxon paints dp as px).
//   .ref/material-ripple/CommonRipple.kt:64-105 — CommonRippleNode: the
//     press→ripple map. addRipple finishes EVERY live ripple first (:74-76)
//     then appends; removeRipple finishes the one its press spawned
//     (:91-93); animate() removing itself from the map on completion
//     (:82-86); drawRipples paints color@pressedAlpha when alpha != 0
//     (:95-100). Ripple.kt:362-392 routes Press→addRipple, Release/Cancel→
//     removeRipple — Release and Cancel are identical.
//   .ref/material-ripple/Ripple.kt:388-392 — draw order:
//     drawContent() → stateLayer → drawRipples.
//
// Clock: upstream's three Animatables run as coroutines; our single ticker
// (registered only while ripples are live) evaluates the same time functions
// each tick — time-pure like ui.anim, so the tick rate never changes the
// result — and marks the node's damage each tick. has_pending keeps the
// host waking at animation granularity.
//
// Deliberately left out (documented, not silently approximated):
//   - RippleNode's pendingInteractions (:335-360): presses recorded before
//     the node's first measurement. Klaxon only delivers pointer events to
//     hit-tested (laid-out) nodes, so bounds always exist at spawn.
//   - upstream's unbounded ripple list (MutableScatterMap) — capped at
//     max_ripples = 4 (live pointers per InputRouter capture slot are 8,
//     and every spawn finishes all previous ripples anyway); a spawn past
//     the cap instantly retires the OLDEST ripple.
//   - the platform RippleDrawable bridge (API-level alpha clamping quirks,
//     RippleTheme.kt:121-133) — everything renders through kx here.
//
// WIDGET INTEGRATION CONTRACT:
//   - Keep `ripples: ripple.Ripples` in the widget state (by value — the
//     ticker's userdata is `r`), set `ripples.node = n` at init (ticker
//     damage = markDirty, covering bounds + damage_overflow), and
//     `ripples.deinit()` in the widget deinit BEFORE freeing the state
//     (the ticker userdata would dangle).
//   - .down      → ripples.spawn(press_id, ev.x, ev.y, ev.time_ms)
//                  (press_id = interactions pressDown's id; any u32 works —
//                  release() pairs on it; 0 for untracked use)
//   - .up        → ripples.release(press_id, ev.time_ms)
//   - drag past slop / .outside_down / detach
//                → ripples.releaseAll(ev.time_ms)  (upstream: Cancel ==
//                  Release for the ripple)
//   - paint      → ripples.paint(ctx, n, .{ .rrect = corner }) — AFTER the
//                  container fill + the state layer, BEFORE the children
//                  paint (the node's own paint runs before its children's,
//                  so this lands under the content like upstream).
//   - clip       → bounded: .rect (upstream clipRect), .rrect(radius) for a
//                  shaped container (material3 clips its indication to the
//                  component shape — the vendored material-ripple predates
//                  that), .path for a morphing outline. Unbounded: .none —
//                  and the widget MUST set damage_overflow to cover
//                  endRadius (see overflowFor) or the damage/cull contract
//                  breaks, same as the checkbox's layer_overflow today.
//   - No timeline installed → snap: the ripple paints fully open while the
//     press is held and vanishes on release (the widgets' no-timeline
//     convention; real fades need the host's ticker).
const std = @import("std");
const kx = @import("../kx.zig");
const anim = @import("anim.zig");
const paint_mod = @import("paint.zig");
const node_mod = @import("node.zig");
const layout_mod = @import("layout.zig");

const Node = node_mod.Node;
const Rect = node_mod.Rect;
const HitPoint = node_mod.HitPoint;
const Color = paint_mod.Color;

/// FadeInDuration — RippleAnimation.kt:180.
pub const fade_in_ms: u64 = 75;
/// RadiusDuration — :181 (radius percent AND center percent share it).
pub const radius_ms: u64 = 225;
/// FadeOutDuration — :182.
pub const fade_out_ms: u64 = 150;
/// BoundedRippleExtraRadius (:177-178) = 10.dp; Klaxon paints dp as px.
pub const bounded_extra_radius: f32 = 10;

/// Concurrent ripples per widget. Upstream keys an unbounded
/// MutableScatterMap by Press (CommonRipple.kt:71); every addRipple already
/// finishes all existing ripples, so >1 live ripple only happens across
// overlapping fade-outs or simultaneous pointers — 4 is ample headroom.
pub const max_ripples = 4;

/// getRippleStartRadius (RippleAnimation.kt:161): "the starting radius is
/// equal to 60% of the largest dimension" — i.e. a RADIUS of 30%.
pub fn startRadius(w: f32, h: f32) f32 {
    return @max(w, h) * 0.3;
}

/// Density.getRippleEndRadius (:168-175): half the bounds diagonal —
/// `Offset(w, h).getDistance() / 2f` — plus the 10dp overshoot for bounded
/// ripples (the clip hides it; it guarantees edge coverage while the circle
/// still expands). Unbounded: exactly covering the bounds.
pub fn endRadius(bounded: bool, w: f32, h: f32) f32 {
    const covering = @sqrt(w * w + h * h) / 2;
    return if (bounded) covering + bounded_extra_radius else covering;
}

/// The damage_overflow an unbounded ripple needs so every pixel it can
/// paint stays inside the node's paint contract (paintRect): the end radius
/// reaching past each edge. `explicit` = the widget's radius override, or
/// null for endRadius(false, w, h).
pub fn overflowFor(w: f32, h: f32, explicit: ?f32) layout_mod.EdgeInsets {
    const rad = explicit orelse endRadius(false, w, h);
    const hx = @max(0, rad - w / 2);
    const hy = @max(0, rad - h / 2);
    return .{ .left = hx, .right = hx, .top = hy, .bottom = hy };
}

/// How a bounded ripple is clipped (upstream: clipRect on the layout
/// bounds). All clip ops are balanced by paint's clipReset.
pub const Clip = union(enum) {
    /// No clip — the unbounded case, or the caller pushes its own.
    none,
    /// Upstream's clipRect on the bounds (RippleAnimation.kt:149-151).
    rect,
    /// The container's rounded rect — material3 clips indication to the
    /// component shape (vendored material-ripple predates it; the widgets'
    /// containers are all rrects).
    rrect: f32,
    /// An arbitrary outline (morphing shapes) — clipPath, anti-aliased.
    path: Path,

    pub const Path = struct { xs: []const f32, ys: []const f32 };
};

/// A per-corner-rounded rect as a `.path` clip — for containers whose
/// shape isn't a uniform rrect (segmented rows' itemShape, connected
/// button groups' morphing inner corners). Each rounded corner becomes a
/// 5-chord quarter-arc (an h/2 radius → ≈4dp chords — AA-fine at 40dp);
/// square corners emit their vertex once. `xs`/`ys` are caller scratch —
/// paint is synchronous, the slices only live for the call.
pub fn cornersClip(r: Rect, tl: f32, tr: f32, br: f32, bl: f32, xs: *[24]f32, ys: *[24]f32) Clip {
    // (corner center, radius) in clockwise order — y-down screen space,
    // where clockwise = the arc angle increasing.
    const corners = [4]struct { cx: f32, cy: f32, r: f32 }{
        .{ .cx = r.x + tl, .cy = r.y + tl, .r = tl },
        .{ .cx = r.x + r.w - tr, .cy = r.y + tr, .r = tr },
        .{ .cx = r.x + r.w - br, .cy = r.y + r.h - br, .r = br },
        .{ .cx = r.x + bl, .cy = r.y + r.h - bl, .r = bl },
    };
    const pi = std.math.pi;
    const arcs = [4][2]f32{
        .{ pi, pi * 1.5 }, // tl: left-edge tangent → top-edge tangent
        .{ pi * 1.5, pi * 2.0 }, // tr: top → right
        .{ 0.0, pi / 2.0 }, // br: right → bottom
        .{ pi / 2.0, pi }, // bl: bottom → left
    };
    var n: usize = 0;
    for (corners, arcs) |c, a| {
        if (c.r <= 0) {
            xs[n] = c.cx;
            ys[n] = c.cy;
            n += 1;
            continue;
        }
        for (0..6) |k| {
            const ang = a[0] + (a[1] - a[0]) * (@as(f32, @floatFromInt(k)) / 5.0);
            xs[n] = c.cx + c.r * @cos(ang);
            ys[n] = c.cy + c.r * @sin(ang);
            n += 1;
        }
    }
    return .{ .path = .{ .xs = xs[0..n], .ys = ys[0..n] } };
}

/// FastOutSlowInEasing = CubicBezierEasing(0.4, 0.0, 0.2, 1.0) — Compose's
/// standard "material" curve (androidx.compose.animation.core.Easing).
fn fastOutSlowIn(t: f32) f32 {
    return anim.cubicBezier(0.4, 0.0, 0.2, 1.0, t);
}

/// clamped elapsed fraction of `dur` ms.
fn frac(t_ms: u64, dur: u64) f32 {
    const t: f32 = @floatFromInt(t_ms);
    return std.math.clamp(t / @as(f32, @floatFromInt(dur)), 0, 1);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

const Ripple = struct {
    /// The Interactions press id this ripple was spawned for — the map key
    /// upstream (CommonRipple.kt:71): Release/Cancel pair on it.
    press_id: u32,
    /// RippleAnimation.origin (:59) — the press position; null = centered
    /// (unbounded spawns pass null upstream, CommonRipple.kt:76).
    origin: ?HitPoint,
    spawn_ms: u64,
    finish_ms: u64 = 0,
    finish_requested: bool = false, // finishRequested (:74)
    /// No-timeline snap state: fully open until released (no fades).
    snapped: bool = false,
    /// Values evaluated by the last tick — paint reads these (the ticker is
    /// the only writer; the eval is time-pure).
    alpha: f32 = 0, // drawn alpha incl. the early-finish override
    radius_p: f32 = 0, // animatedRadiusPercent (:68)
    center_p: f32 = 0, // animatedCenterPercent (:69)
    done: bool = false, // the coroutine returned → left the map (:82-86)

    /// RippleAnimation.animate (:76-115) as a pure function of time.
    fn eval(rp: *Ripple, now_ms: u64) void {
        if (rp.snapped) {
            // No timeline → paint fully open while held, gone on release.
            rp.alpha = 1;
            rp.radius_p = 1;
            rp.center_p = 1;
            rp.done = rp.finish_requested;
            return;
        }
        const t: u64 = now_ms -| rp.spawn_ms;
        // fadeIn completes when the longest of the three tweens does —
        // animated() then sets finishedFadingIn (:78) at t = RadiusDuration.
        const fading_in_done = t >= radius_ms;
        if (!rp.finish_requested) {
            rp.alpha = frac(t, fade_in_ms); // tween(75, Linear) :86-89
            rp.radius_p = fastOutSlowIn(frac(t, radius_ms)); // :91-95
            rp.center_p = frac(t, radius_ms); // :96-100 (Linear)
            return;
        }
        if (!fading_in_done) {
            // finishRequested && !finishedFadingIn: the drawn alpha is
            // forced to 1 (:134-139) while radius/center finish expanding —
            // the finishSignal only lands AFTER fadeIn returns (:77-79).
            rp.alpha = 1;
            rp.radius_p = fastOutSlowIn(frac(t, radius_ms));
            rp.center_p = frac(t, radius_ms);
            return;
        }
        // fadeOut (:106-115): the signal awaited past fade-in end — the
        // later of the release time vs. the fade-in's end.
        const out_start = @max(rp.finish_ms, rp.spawn_ms + radius_ms);
        const ot: u64 = now_ms -| out_start;
        rp.alpha = 1 - frac(ot, fade_out_ms);
        rp.radius_p = 1;
        rp.center_p = 1;
        rp.done = ot >= fade_out_ms;
    }

    /// finish() (:117-120): idempotent — the signal completes once; an
    /// already-finishing ripple keeps its first finish time.
    fn finish(rp: *Ripple, now_ms: u64) void {
        if (rp.snapped) {
            rp.finish_requested = true;
            rp.done = true;
            return;
        }
        if (!rp.finish_requested) {
            rp.finish_requested = true;
            rp.finish_ms = now_ms;
        }
    }
};

/// The per-widget ripple set — CommonRippleNode's `ripples` map.
pub const Ripples = struct {
    /// RippleNode.bounded (Ripple.kt:311): bounded ripples start at the
    /// press position and clip to the container; unbounded start centered
    /// and draw unclipped.
    bounded: bool = true,
    /// The explicit radius (Dp.Unspecified → null → endRadius at paint) —
    /// e.g. checkbox's unbounded 20dp state-layer circle.
    radius: ?f32 = null,
    /// rippleColor + RippleAlpha.pressedAlpha — the widget refreshes them
    /// per paint/state change like upstream re-reads them per draw
    /// (CommonRipple.kt:96-98).
    color: Color = 0,
    pressed_alpha: f32 = 0.12, // theme.state.pressed default
    /// The node damaged every tick while ripples are live (markDirty covers
    /// bounds + damage_overflow — an unbounded ripple relies on the widget
    /// declaring its overflow, see overflowFor).
    node: ?*Node = null,

    items: [max_ripples]Ripple = undefined,
    len: u8 = 0,
    ticker: ?anim.Timeline.Ticker = null,

    fn now() u64 {
        return if (anim.timeline()) |tl| tl.last_now_ms else 0;
    }

    fn mark(r: *Ripples) void {
        if (r.node) |n| n.markDirty();
    }

    /// CommonRippleNode.addRipple (:73-89): finish every live ripple, then
    /// append one for this press. `now_ms` should be the event's time_ms
    /// (same SDL clock the timeline ticks on); 0 = the last timeline tick.
    /// The spawn marks the node dirty so the first frame shows it.
    pub fn spawn(r: *Ripples, press_id: u32, x: f32, y: f32, now_ms: u64) void {
        const t = if (now_ms != 0) now_ms else now();
        // "Finish existing ripples" (:74-76) — they still fade out fully.
        for (r.items[0..r.len]) |*rp| rp.finish(t);
        if (r.len == max_ripples) {
            // Past the cap: retire the oldest instantly (unbounded upstream).
            std.mem.copyForwards(Ripple, r.items[0 .. max_ripples - 1], r.items[1..max_ripples]);
            r.len -= 1;
        }
        r.items[r.len] = .{
            .press_id = press_id,
            // `origin = if (bounded) pressPosition else null` (:76).
            .origin = if (r.bounded) .{ .x = x, .y = y } else null,
            .spawn_ms = t,
            .snapped = anim.timeline() == null,
        };
        r.len += 1;
        r.ensureTicker();
        r.mark();
    }

    /// removeRipple (:91-93): finish the ripple this press spawned —
    /// release or cancel, identical upstream (Ripple.kt:383-385).
    /// Unknown/finished ids no-op.
    pub fn release(r: *Ripples, press_id: u32, now_ms: u64) void {
        const t = if (now_ms != 0) now_ms else now();
        for (r.items[0..r.len]) |*rp| {
            if (rp.press_id == press_id) rp.finish(t);
        }
        r.mark();
    }

    /// Finish every unfinished ripple (outside_down, capture moved away,
    /// widget going disabled mid-press).
    pub fn releaseAll(r: *Ripples, now_ms: u64) void {
        const t = if (now_ms != 0) now_ms else now();
        for (r.items[0..r.len]) |*rp| rp.finish(t);
        r.mark();
    }

    /// True while any ripple is animating or waiting on its release.
    pub fn live(r: *const Ripples) bool {
        return r.len > 0;
    }

    /// DrawScope.drawRipples (CommonRipple.kt:95-100) + the per-ripple
    /// RippleAnimation.draw. Call from the widget's paint hook AFTER the
    /// container fill + state layer and BEFORE the children pass.
    /// `clip` applies to bounded ripples only; unbounded ignores it (draw
    /// unclipped, like :151-153).
    pub fn paint(r: *const Ripples, ctx: *kx.Ctx, n: *Node, clip: Clip) void {
        r.paintIn(ctx, n.bounds, clip);
    }

    /// paint() against an explicit rect — the indication's own layout
    /// bounds when they aren't the node's: Switch's `.indication` sits on
    /// the thumb's LayoutNode (Switch.kt:191-199 — the ripple anchors to
    /// the animated thumb rect, not the track), and row widgets
    /// (segmented button, tabs, toolbar slots, button-group items) carry
    /// one indication per cell rect.
    /// `b` is in the node's parent space, same as n.bounds.
    pub fn paintIn(r: *const Ripples, ctx: *kx.Ctx, b: Rect, clip: Clip) void {
        // `if (alpha != 0f)` (:96-97): pressedAlpha zero → nothing to draw.
        if (r.len == 0 or r.pressed_alpha <= 0) return;
        if (r.bounded) pushClip(ctx, b, clip);
        for (r.items[0..r.len]) |*rp| r.drawOne(rp, b, ctx);
        if (r.bounded) paint_mod.clipReset(ctx);
    }

    /// RippleAnimation.DrawScope.draw (:122-154).
    fn drawOne(r: *const Ripples, rp: *const Ripple, b: Rect, ctx: *kx.Ctx) void {
        // targetRadius: `if (radius.isUnspecified) getRippleEndRadius
        // (bounded, size) else radius.toPx()` (CommonRipple.kt:120-125).
        const target = r.radius orelse endRadius(r.bounded, b.w, b.h);
        const start = startRadius(b.w, b.h); // :124
        const cx0 = b.x + b.w / 2; // targetCenter (:129-131)
        const cy0 = b.y + b.h / 2;
        const ox = if (rp.origin) |o| o.x else cx0; // origin ?: center (:126-128)
        const oy = if (rp.origin) |o| o.y else cy0;
        const rad = lerp(start, target, rp.radius_p); // :141
        const cx = lerp(ox, cx0, rp.center_p); // centerOffset (:142-146)
        const cy = lerp(oy, cy0, rp.center_p);
        if (rad <= 0 or rp.alpha <= 0) return;
        // modulatedColor = color.copy(alpha = color.alpha * alpha) (:148) —
        // `color` here is rippleColor.copy(alpha = pressedAlpha) (:96-98):
        // the pressed alpha is an ABSOLUTE channel (upstream Color.copy
        // replaces it), then the animated alpha multiplies it.
        const a = std.math.clamp(r.pressed_alpha * rp.alpha, 0, 1);
        const byte: u32 = @intFromFloat(a * 255 + 0.5);
        const c = (r.color & 0xFFFFFF00) | @min(byte, 255);
        // drawCircle — no circle primitive crosses the ABI; a square rrect
        // at full radius IS the circle (the widgets' state-layer idiom).
        paint_mod.fillRRect(ctx, cx - rad, cy - rad, rad * 2, rad * 2, rad, c);
    }

    fn pushClip(ctx: *kx.Ctx, b: Rect, clip: Clip) void {
        switch (clip) {
            .none => {},
            .rect => paint_mod.clipRect(ctx, b.x, b.y, b.w, b.h),
            .rrect => |rad| paint_mod.clipRRect(ctx, b.x, b.y, b.w, b.h, rad),
            .path => |p| paint_mod.clipPath(ctx, p.xs, p.ys, true),
        }
    }

    // --- the timeline ticker (registered only while ripples are live) ---

    fn ensureTicker(r: *Ripples) void {
        if (r.ticker != null) return;
        const tl = anim.timeline() orelse return;
        const t = anim.Timeline.Ticker{
            .fn_ptr = tickCb,
            .userdata = r,
            .has_pending = hasPendingCb,
        };
        tl.addTicker(t);
        r.ticker = t;
    }

    fn tickCb(userdata: ?*anyopaque, now_ms: u64) void {
        const r: *Ripples = @ptrCast(@alignCast(userdata.?));
        var i: usize = 0;
        while (i < r.len) {
            r.items[i].eval(now_ms);
            if (r.items[i].done) {
                // `finally { ripples.remove(interaction) }` (:82-84).
                r.items[i] = r.items[r.len - 1];
                r.len -= 1;
                continue;
            }
            i += 1;
        }
        if (r.len == 0) {
            // animate() returned for the last ripple — the ticker idles
            // again until the next spawn (register-only-while-live).
            if (r.ticker) |t| {
                if (anim.timeline()) |tl| tl.removeTicker(t);
                r.ticker = null;
            }
        }
        // Damage the whole paint rect (bounds + damage_overflow) — bounded
        // ink can't exceed the clip, unbounded ink relies on the widget's
        // declared overflow; either way paintRect covers it.
        r.mark();
    }

    fn hasPendingCb(userdata: ?*anyopaque) bool {
        const r: *Ripples = @ptrCast(@alignCast(userdata.?));
        return r.len > 0;
    }

    /// onDetach + teardown (CommonRipple.kt:102-104): drop every ripple and
    /// unregister the ticker — its userdata is `r` and would dangle once
    /// the widget's state is freed. Call from the widget's deinit.
    pub fn deinit(r: *Ripples) void {
        r.len = 0;
        if (r.ticker) |t| {
            if (anim.timeline()) |tl| tl.removeTicker(t);
            r.ticker = null;
        }
    }
};

// --- tests ---

const TestState = struct {
    color: Color,
    corner: f32,
    ripples: Ripples,
    clip: Clip,
};

fn testMeasure(n: *Node, c: layout_mod.Constraints) layout_mod.Size {
    _ = n;
    return c.constrain(.{ .w = 100, .h = 60 });
}

fn testPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *TestState = @ptrCast(@alignCast(n.state.?));
    const b = n.bounds;
    paint_mod.fillRRect(ctx, b.x, b.y, b.w, b.h, s.corner, s.color);
    s.ripples.paint(ctx, n, s.clip);
}

fn testDeinit(n: *Node) void {
    const s: *TestState = @ptrCast(@alignCast(n.state.?));
    s.ripples.deinit();
    n.allocator.destroy(s);
}

const golden = @import("../golden.zig");

const test_vtable = node_mod.VTable{
    .measure = testMeasure,
    .layout = nullLayout,
    .paint = testPaint,
    .deinit = testDeinit,
};

fn nullLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}

fn testBox(allocator: std.mem.Allocator, color: Color, bounded: bool, clip: Clip) !*Node {
    const node = try Node.create(allocator, &test_vtable);
    const s = try allocator.create(TestState);
    s.* = .{
        .color = color,
        .corner = 0,
        .ripples = .{ .bounded = bounded, .node = node, .color = 0x000000FF, .pressed_alpha = 0.5 },
        .clip = clip,
    };
    node.state = s;
    return node;
}

fn stateOf(n: *Node) *TestState {
    return @ptrCast(@alignCast(n.state.?));
}

test "radius math: start 30% of max dim, end = half-diagonal (+10 bounded)" {
    try std.testing.expectApproxEqAbs(@as(f32, 30), startRadius(100, 60), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 18), startRadius(40, 60), 1e-4);
    const diag = @sqrt(100.0 * 100.0 + 60.0 * 60.0) / 2.0; // ≈ 58.31
    try std.testing.expectApproxEqAbs(@as(f32, diag + 10), endRadius(true, 100, 60), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, diag), endRadius(false, 100, 60), 1e-4);
    // overflowFor: radius beyond each half-extent.
    const o = overflowFor(18, 18, 20);
    try std.testing.expectApproxEqAbs(@as(f32, 11), o.left, 1e-4);
    const o2 = overflowFor(40, 40, null); // endRadius ≈ 28.3 > 20
    try std.testing.expect(o2.left > 0);
    const o3 = overflowFor(80, 40, null); // endRadius ≈ 44.7 < 40? no: 44.7 > 40? h/2=20 → 24.7 vert
    try std.testing.expectApproxEqAbs(@as(f32, @sqrt(80.0 * 80.0 + 40.0 * 40.0) / 2.0 - 20), o3.top, 1e-4);
}

test "timeline ticks advance the ripple deterministically" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var r = Ripples{ .bounded = true };
    r.spawn(1, 10, 30, 0);
    try std.testing.expect(r.live());
    try std.testing.expect(r.ticker != null); // registered while live
    tl.tick(0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.items[0].alpha, 1e-4);
    tl.tick(75); // fade-in end for alpha
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.items[0].alpha, 1e-4);
    // radius: 75/225 through FastOutSlowIn — slow start, so ≈0.46 at 1/3.
    const p75 = r.items[0].radius_p;
    try std.testing.expectApproxEqAbs(fastOutSlowIn(75.0 / 225.0), p75, 1e-4);
    try std.testing.expect(p75 > 0 and p75 < 1);
    try std.testing.expectApproxEqAbs(@as(f32, 75.0 / 225.0), r.items[0].center_p, 1e-4);
    tl.tick(225); // expansion complete, still held
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.items[0].radius_p, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.items[0].alpha, 1e-4);
    try std.testing.expect(r.live()); // waits for release
    r.release(1, 300);
    tl.tick(300); // out_start = 300 (past fade-in end)
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.items[0].alpha, 1e-4);
    tl.tick(375); // 75ms into the 150ms out
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), r.items[0].alpha, 1e-4);
    tl.tick(450); // 150ms → done, removed, ticker unregistered
    try std.testing.expect(!r.live());
    try std.testing.expect(r.ticker == null);
}

test "early release: expansion completes, then the fade runs" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var r = Ripples{};
    r.spawn(1, 0, 0, 0);
    r.release(1, 100); // released mid-expansion (fade-in ends at 225)
    tl.tick(150);
    const rp = &r.items[0];
    // finishRequested && !finishedFadingIn → drawn alpha forced to 1…
    try std.testing.expectApproxEqAbs(@as(f32, 1), rp.alpha, 1e-4);
    // …and the radius keeps expanding (the coroutineScope waits on it).
    try std.testing.expect(rp.radius_p > 0 and rp.radius_p < 1);
    tl.tick(225); // fade-in completes; the signal lands → fade-out starts NOW
    try std.testing.expectApproxEqAbs(@as(f32, 1), rp.radius_p, 1e-4);
    tl.tick(225 + 75); // 75ms into the 150ms out → alpha 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), r.items[0].alpha, 1e-4);
    tl.tick(225 + 150);
    try std.testing.expect(!r.live()); // animate() returned → removed
}

test "a new spawn finishes the live ripples; releaseAll cancels the rest" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var r = Ripples{};
    r.spawn(1, 0, 0, 0);
    r.spawn(2, 5, 5, 10); // addRipple finishes ALL existing (:74-76)
    try std.testing.expectEqual(@as(u8, 2), r.len);
    try std.testing.expect(r.items[0].finish_requested);
    try std.testing.expect(!r.items[1].finish_requested);
    r.release(1, 20); // already finishing — idempotent, keeps first finish_ms
    try std.testing.expectEqual(@as(u64, 10), r.items[0].finish_ms);
    r.releaseAll(30);
    try std.testing.expect(r.items[1].finish_requested);
}

test "spawn past the cap retires the oldest instantly" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var r = Ripples{};
    for (0..max_ripples) |i| r.spawn(@intCast(i + 1), 0, 0, @intCast(i));
    try std.testing.expectEqual(@as(u8, max_ripples), r.len);
    r.spawn(99, 0, 0, 100);
    try std.testing.expectEqual(@as(u8, max_ripples), r.len);
    try std.testing.expectEqual(@as(u32, 99), r.items[r.len - 1].press_id);
    // the oldest (press 1) was dropped
    for (r.items[0..r.len]) |rp| try std.testing.expect(rp.press_id != 1);
}

test "no timeline: held = fully open, release = gone (snap)" {
    var r = Ripples{ .pressed_alpha = 0.5 };
    r.spawn(1, 0, 0, 0); // anim.timeline() == null → snapped
    try std.testing.expect(r.live());
    r.items[0].eval(999);
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.items[0].alpha, 1e-4);
    try std.testing.expect(r.ticker == null); // nothing registered
    r.release(1, 1000);
    // finish on a snapped ripple is immediate.
    r.items[0].eval(1000);
    try std.testing.expect(r.items[0].done);
    r.deinit();
}

test "spawn marks the node dirty and the ticker damages it every tick" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const node = try Node.create(std.testing.allocator, &test_vtable);
    defer node.deinit();
    const s = try std.testing.allocator.create(TestState);
    s.* = .{ .color = 0xFFFFFFFF, .corner = 0, .ripples = .{ .node = node }, .clip = .none };
    node.state = s;
    node.bounds = .{ .x = 0, .y = 0, .w = 100, .h = 60 };
    node.dirty = false;
    s.ripples.spawn(1, 0, 0, 0);
    try std.testing.expect(node.dirty); // spawn damaged it
    node.dirty = false;
    node_mod.bumpMarkEpoch(); // model the clearing pass ending
    tl.tick(16);
    try std.testing.expect(node.dirty); // the tick damaged it again
}

test "golden: a bounded ripple expands from the press point and fades on release" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var r = try golden.Renderer.init(std.testing.allocator, 140, 100);
    defer r.deinit();
    const node = try testBox(std.testing.allocator, 0xFFFFFFFF, true, .{ .rrect = 8 });
    defer node.deinit();
    node.layout(.{ .x = 20, .y = 20, .w = 100, .h = 60 });
    const s = stateOf(node);

    // Held at full expansion: ripple over the press point, clipped to the
    // container, nothing outside the bounds.
    s.ripples.spawn(1, 30, 50, 0);
    tl.tick(225);
    r.paint(node, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // alpha 1 * pressed 0.5 → 0x00000080 over white ≈ mid gray.
    const at_press = f.pixelAt(30, 50);
    try std.testing.expect(golden.channelDiff(at_press, 0x808080FF, 24) <= 2);
    // The press point is covered; a corner of the rrect clip is NOT —
    // (20,20) is the bounds' top-left, outside the rounded corner.
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20, 20));
    // The ink can't escape the clip: pixel just outside the bounds = bg.
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(19, 50));

    // Released mid-fade-in of a fresh press: still finishes expanding…
    s.ripples.spawn(2, 80, 50, 225);
    tl.tick(225 + 75);
    r.paint(node, 0xFFFFFFFF);
    s.ripples.release(2, 225 + 100);
    tl.tick(225 + 150); // past fade-in end (225+225=450)? no: spawn 225 → fade-in ends at 450
    // now_ms 375 < 450 → still expanding, alpha forced 1 (early finish).
    f.deinit();
    f = try r.readback(std.testing.allocator);
    try std.testing.expect(f.pixelAt(80, 50) != 0xFFFFFFFF); // ink present
    // …and after fade-out completes the surface is clean white again.
    tl.tick(225 + 225 + 150 + 1); // out_start 450 + 150 → 601
    r.paint(node, 0xFFFFFFFF);
    f.deinit();
    f = try r.readback(std.testing.allocator);
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(80, 50));
    try std.testing.expect(!s.ripples.live());
}

test "golden: an unbounded ripple stays centered and can cross the bounds" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var r = try golden.Renderer.init(std.testing.allocator, 140, 100);
    defer r.deinit();
    // Unbounded with an explicit 40dp radius on the 100x60 box — the ink
    // reaches past the horizontal edges like upstream's unbounded circle.
    const node = try testBox(std.testing.allocator, 0xFFFFFFFF, false, .none);
    defer node.deinit();
    node.layout(.{ .x = 20, .y = 20, .w = 100, .h = 60 });
    const s = stateOf(node);
    s.ripples.radius = 55; // > half-diagonal → visibly overflows the bounds
    s.ripples.spawn(1, 30, 50, 0); // origin ignored for unbounded
    tl.tick(225);
    r.paint(node, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // Centered at the bounds center (70,50), radius 55 → (20,50) covered…
    // …and BEYOND the bounds: pixel (16,50) is outside the node but inside
    // the circle — unbounded = no clip.
    try std.testing.expect(f.pixelAt(16, 50) != 0xFFFFFFFF);
    try std.testing.expect(golden.channelDiff(f.pixelAt(70, 50), 0x808080FF, 24) <= 2);
}
