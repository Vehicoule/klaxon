// Pull-to-refresh (Phase 2d.3 PR D5, M3E) — a container that wraps ONE
// content child (typically a scroll_view) and shows the M3E indicator while
// the user pulls the content down at scroll top.
//
// Spec: m3.material.io/components/progress-indicators (pull-to-refresh) +
// Compose pulltorefresh/PullToRefresh.kt (PullToRefreshDefaults):
//   - PositionalThreshold 80dp: the raw pull distance that triggers a refresh
//   - DragMultiplier 0.5: the adjusted (indicator + content offset) distance
//   - the indicator: a 40dp circle (SurfaceContainerHigh, Level2 shadow);
//     while pulling it shows the CircularArrowProgressIndicator — a
//     butt-capped arc (ArrowValues: first 40% discarded, 0.8 max arc,
//     rotation + tension) with a stroked 10x5dp arrowhead — and while
//     refreshing the indeterminate 16dp CircularProgressIndicator
//   - releasing with adjusted > 80dp (raw pull > 160) fires onRefresh;
//     while refreshing the content holds at the 80dp offset and the
//     indicator rests at the 40..80dp band (indicator bottom = adjusted)
//
// Behavior: a drag DOWN while the content is at scroll top pulls — the
// content translates down by `adjusted = pull × 0.5` (paint/hit-time, like
// the drawer's panel) and the indicator rides the content's top edge. While
// the content is scrolled, the scroll view scrolls normally and the PTR
// ignores the drag. "At scroll top" = the content child is not a scroll view
// or its offset is 0 (scroll_view.isScrollView). While refreshing, the
// gesture is ignored.
//
// Gesture model: the PTR starts as a passive observer — the content's scroll
// view claims the moves that actually scroll (bubbling stops there). The
// first downward move the PTR sees at scroll top ANCHORS the pull origin (the
// scroll-to-top transition is invisible to the wrapper: it never saw the
// consumed moves) and STEALS the pointer capture (input.captureNode; the
// previous owner is canceled with .outside_down). From then on every move
// and the release are the PTR's — a clickable child can no longer strand the
// indicator, and an upward drag shrinks the pull, then scrolls the content
// (Flutter's overscroll model). A fresh down cancels any in-flight snap-back
// spring. Residual imprecision (sub-frame): the overscroll within the final
// scroll-consuming move (a drag crossing from scrolled to top mid-move) is
// not counted — the pull origin is the first move seen past the top.
//
// The refreshing state is a Signal(bool) owned by the app (two-way): the PTR
// sets it on trigger; the app clears it when the refresh completes.
// `on_refresh` fires at the trigger. The adjusted value animates with the
// theme's SPATIAL spring (snaps without a timeline).
//
// The indicator is painted in post_children_paint (above the content) and
// clipped to the container's bounds; the content is clipped to the bounds
// and translated in pre_children_paint.
//
// v1 deviations (documented, fixed later):
//   - The at-scroll-top check looks at the DIRECT content child only (no
//     nested-scroll coordination).
//   - The M3E LoadingIndicator variant (ContainedLoadingIndicator — the
//     alternate upstream indicator) is a follow-up.
//   - The refreshing spinner runs the circular-indeterminate schedule from
//     progress.zig (shared helpers), not a separate keyframe port.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const anim = ui.anim;
const node_mod = ui.node;
const theme_mod = @import("../theme.zig");
const scroll_view = @import("scroll_view.zig");
const progress_w = @import("progress.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

pub const PullToRefreshOptions = struct {
    theme: Theme = theme_mod.light,
    label: []const u8 = "Pull to refresh",
};

/// M3E measurement tokens (PullToRefreshDefaults + the private vals).
const threshold: f32 = 80; // PositionalThreshold (raw pull → trigger)
const drag_multiplier: f32 = 0.5;
const resting: f32 = 80; // the refreshing offset = thresholdPx (upstream: verticalOffset = thresholdPx while refreshing)
const indicator_d: f32 = 40; // SpinnerContainerSize / IndicatorBox
const indicator_elev: f32 = 3; // PullToRefreshDefaults.Elevation = Level2
const arc_radius: f32 = 6.75; // ArcRadius 5.5 + StrokeWidth/2 (the arc centerline)
const arc_stroke: f32 = 2.5; // StrokeWidth
const arrow_w: f32 = 10; // ArrowWidth
const arrow_h: f32 = 5; // ArrowHeight
const max_progress_arc: f32 = 0.8; // MaxProgressArc (× 360°)
const min_alpha: f32 = 0.3; // MinAlpha
const arc_segments: usize = 24;
const spinner_size: f32 = 16; // SpinnerSize (the refreshing spinner box)

const Track = struct {
    pointer: u64 = 0,
    y: f32 = 0,
    active: bool = false,
};

const PtrState = struct {
    sig: *ui.state.Signal(bool),
    opts: PullToRefreshOptions,
    on_refresh: ?Callback = null,
    adjusted: f32 = 0, // the content offset (0 = hidden, resting = 40)
    anim_to: f32 = 0,
    laid_out: bool = false,
    pull: f32 = 0, // the raw pull distance (≥ 0 while pulling)
    pulling: bool = false,
    track: Track = .{},
    anim_channel: u8 = 0, // channel marker (stable address)
    // --- refreshing spinner clock (the indeterminate CircularProgressIndicator
    // shown while refreshing — same schedule as progress.zig circular) ---
    elapsed_ms: f64 = 0,
    last_phase: f32 = 0,
    spin_channel: u8 = 0, // channel marker (stable address)
    spin_running: bool = false,
};

const Callback = ui.state.Callback;

fn stateOf(n: *Node) *PtrState {
    return @ptrCast(@alignCast(n.state.?));
}

/// The current adjusted offset (pub accessor — tests + the app).
pub fn adjusted(n: *Node) f32 {
    return stateOf(n).adjusted;
}

/// The content child's scroll offset (0 when it is not a scroll view).
fn contentOffset(n: *Node) f32 {
    if (n.children.items.len == 0) return 0;
    const content = n.children.items[0];
    if (!scroll_view.isScrollView(content)) return 0;
    return scroll_view.scrollOffset(content);
}

/// Whether the content child is at scroll top (not a scroll view, or offset 0).
fn contentAtTop(n: *Node) bool {
    return contentOffset(n) <= 0.001;
}

/// Scroll the content child (a no-op when it is not a scroll view).
fn scrollContent(n: *Node, delta: f32) void {
    if (n.children.items.len == 0) return;
    const content = n.children.items[0];
    if (!scroll_view.isScrollView(content)) return;
    scroll_view.scrollBy(content, delta);
}

/// The PTR owns the gesture (it holds the capture): every move delta is
/// ours. Dragging down pulls at scroll top (scrolling back toward the top
/// first); dragging up shrinks the pull, then scrolls the content.
fn handleCapturedMove(n: *Node, s: *PtrState, dy: f32) void {
    if (dy > 0) {
        if (s.pull > 0) {
            s.pull += dy;
        } else if (contentOffset(n) > 0.001) {
            scrollContent(n, -dy); // scroll back toward the top
            return;
        } else {
            s.pull = dy; // the overscroll (re-)starts
        }
    } else if (dy < 0) {
        const up = -dy;
        if (s.pull > 0) {
            const absorbed = @min(s.pull, up);
            s.pull -= absorbed;
            const excess = up - absorbed;
            if (excess > 0.001) scrollContent(n, excess); // resume scrolling
        } else {
            scrollContent(n, up);
        }
    }
    applyAdjusted(n, s, s.pull * drag_multiplier);
}

fn ptrMeasure(n: *Node, c: Constraints) Size {
    var size = Size{};
    if (n.children.items.len > 0) size = n.children.items[0].measure(c);
    const w = if (std.math.isFinite(c.max_w)) c.max_w else size.w;
    const h = if (std.math.isFinite(c.max_h)) c.max_h else size.h;
    return c.constrain(.{ .w = w, .h = h });
}

fn ptrLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    if (n.children.items.len > 0) {
        const content = n.children.items[0];
        content.layout(bounds);
        // The PTR supplies the top-edge elastic feedback (pull × 0.5) —
        // the scrollable's own rubber band stays off or it double-stretches
        // and eats the moves the pull needs.
        if (scroll_view.isScrollView(content)) scroll_view.setBounces(content, false);
    }
    const target: f32 = if (s.sig.peek()) resting else 0;
    if (!s.laid_out) {
        s.anim_to = target;
        applyAdjusted(n, s, target);
        s.laid_out = true;
    } else if (target != s.anim_to and !s.pulling) {
        animateAdjusted(n, s, target);
    }
    if (s.sig.peek() and !s.spin_running) startSpin(n, s); // lazy retry (no timeline at attach)
}

fn ptrPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx; // transparent: the content child paints (translated)
}

/// Upstream calculateVerticalOffset: the content offset is the adjusted
/// pull up to the threshold, then a non-linear tension (capped at 2×).
fn verticalOffset(adj: f32) f32 {
    if (adj <= threshold) return adj;
    const overshoot = @abs(adj / threshold) - 1;
    const lt = std.math.clamp(overshoot, 0, 2);
    return threshold + threshold * (lt - lt * lt / 4);
}

/// Upstream ArrowValues: the pull progress drives the arc rotation/sweep
/// and the arrowhead scale.
const ArrowValues = struct { rotation: f32, start: f32, end: f32, scale: f32 };
fn arrowValues(progress: f32) ArrowValues {
    const adjusted_p = @max(@min(1, progress) - 0.4, 0) * 5.0 / 3.0;
    const overshoot = @abs(progress) - 1;
    const lt = std.math.clamp(overshoot, 0, 2);
    const tension = lt - lt * lt / 4;
    const end_trim = adjusted_p * max_progress_arc;
    const rotation = (-0.25 + 0.4 * adjusted_p + tension) * 0.5;
    return .{
        .rotation = rotation,
        .start = rotation * 360,
        .end = (rotation + end_trim) * 360,
        .scale = @min(1, adjusted_p),
    };
}

fn ptrPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    // clipRect pushes its own save — clipReset pops it, restoring the
    // enclosing clip (scroll view, damage rect) intact. The content is
    // clipped to the container and translated down by the tension-capped
    // vertical offset.
    ui.paint.clipRect(ctx, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h);
    ui.paint.translate(ctx, 0, verticalOffset(s.adjusted));
}

fn ptrPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    ui.paint.clipReset(ctx); // the content's clip + translate
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const refreshing = s.sig.peek();
    if (s.adjusted <= 0.001 and !refreshing) return;
    const progress = s.adjusted / threshold; // upstream distanceFraction
    // the IndicatorBox rides the pull: its bottom edge = adjusted distance
    const cx = b.x + b.w / 2;
    const edge_y = b.y + s.adjusted;
    const acy = edge_y - indicator_d / 2; // the container's center y
    ui.paint.clipRect(ctx, b.x, b.y, b.w, b.h); // saves
    // the container: a 40dp circle at Level2 elevation (upstream IndicatorBox)
    ui.paint.elevationShadow(ctx, cx - indicator_d / 2, edge_y - indicator_d, indicator_d, indicator_d, indicator_d / 2, indicator_elev, t.colors.shadow);
    ui.paint.fillRRect(ctx, cx - indicator_d / 2, edge_y - indicator_d, indicator_d, indicator_d, indicator_d / 2, t.colors.surface_container_high);
    if (refreshing) {
        // upstream: CircularProgressIndicator (indeterminate) at SpinnerSize
        // 16dp — the same keyframe schedule as progress.zig's circular
        // indeterminate, at the PTR's 5.5+stroke/2 radius / 2.5 stroke.
        const t_ms = @mod(@as(f32, @floatCast(s.elapsed_ms)), @as(f32, @floatFromInt(progress_w.circular_indet_ms)));
        const sweep = @max(progress_w.circIndetProgress(t_ms) * 360, 0.1);
        const rot = (t_ms / @as(f32, @floatFromInt(progress_w.circular_indet_ms))) * 1080 + progress_w.circAddRotation(t_ms);
        var xs: [arc_segments + 1]f32 = undefined;
        var ys: [arc_segments + 1]f32 = undefined;
        const na = progress_w.arcPolyline(&xs, &ys, cx, acy, arc_radius, rot, sweep);
        ui.paint.strokePolyline(ctx, xs[0..na], ys[0..na], arc_stroke, true, t.colors.on_surface_variant);
    } else if (progress > 0.01) {
        // upstream CircularArrowProgressIndicator: butt-capped arc +
        // a stroked arrowhead at the leading end.
        const v = arrowValues(progress);
        const alpha: f32 = if (progress >= 1) 1 else min_alpha;
        const color = ui.paint.withAlphaScaled(t.colors.on_surface_variant, alpha);
        var xs: [arc_segments + 1]f32 = undefined;
        var ys: [arc_segments + 1]f32 = undefined;
        const na = progress_w.arcPolyline(&xs, &ys, cx, acy, arc_radius, v.start, v.end - v.start);
        ui.paint.strokePolyline(ctx, xs[0..na], ys[0..na], arc_stroke, false, color);
        // the arrowhead: an open triangle stroked at 2.5dp, placed at the
        // arc's end and rotated about the center by (end - strokeWidth) deg
        const sc = v.scale;
        const lx = [3]f32{ 0, arrow_w * sc / 2, arrow_w * sc };
        const ly = [3]f32{ 0, arrow_h * sc, 0 };
        // translate: (cx + radius - inset, cy - strokeWidth); radius = the
        // spinner box's half-size (8dp), inset = ArrowWidth*scale/2
        const inset = arrow_w * sc / 2;
        const ox = cx + spinner_size / 2 - inset;
        const oy = acy - arc_stroke;
        const rot_deg = (v.end - arc_stroke) * std.math.pi / 180;
        const cosr = @cos(rot_deg);
        const sinr = @sin(rot_deg);
        var ax: [3]f32 = undefined;
        var ay: [3]f32 = undefined;
        for (0..3) |i| {
            const px = ox + lx[i] - cx;
            const py = oy + ly[i] - acy;
            ax[i] = cx + px * cosr - py * sinr;
            ay[i] = acy + px * sinr + py * cosr;
        }
        ui.paint.strokePolyline(ctx, &ax, &ay, arc_stroke, false, color);
    }
    ui.paint.clipReset(ctx); // restores
}

fn ptrMapPaintRect(n: *Node, r: Rect) Rect {
    const dy = verticalOffset(stateOf(n).adjusted);
    return .{ .x = r.x, .y = r.y + dy, .w = r.w, .h = r.h };
}

fn ptrChildClip(n: *Node) Rect {
    return n.bounds; // the container clip pushed in pre_children_paint
}

fn ptrPreChildrenHit(n: *Node, px: f32, py: f32) node_mod.HitPoint {
    const dy = verticalOffset(stateOf(n).adjusted);
    return .{ .x = px, .y = py - dy };
}

fn ptrOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    switch (ev.phase) {
        .down => {
            if (s.track.active) return false; // one pull gesture at a time
            // A fresh gesture takes control: cancel any in-flight snap-back
            // spring (its next tick would overwrite the new pull).
            if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel));
            // Record the track (a drag may start here); the content handles
            // taps. A claiming child (a button) may consume this down before
            // it bubbles here — the track then self-heals on the first move.
            s.track = .{ .pointer = ev.pointer, .y = ev.raw_y, .active = true };
            s.pull = 0;
            s.pulling = false;
            return false;
        },
        .move => {},
        .up, .outside_down => {
            if (s.track.active and s.track.pointer != ev.pointer) return false; // another finger
            const was = s.pulling;
            const pull = s.pull; // captured before the reset (finishPull reads it)
            s.pull = 0;
            s.pulling = false;
            s.track.active = false;
            if (was) {
                finishPull(n, s, pull);
                return true;
            }
            return false;
        },
        else => return false,
    }
    // .move
    if (s.sig.peek()) return false; // no pull while refreshing
    if (s.track.active and s.track.pointer != ev.pointer) return false; // another finger
    const router = input.current() orelse return false;
    const last = if (s.track.active and s.track.pointer == ev.pointer) s.track.y else ev.raw_y;
    s.track = .{ .pointer = ev.pointer, .y = ev.raw_y, .active = true };
    const self_captured = router.capturedNode(ev.pointer) == n;
    if (!self_captured and !s.pulling) {
        // Bubbling: the scroll view claimed the moves that scrolled. The
        // first move we see at scroll top anchors the pull origin (the
        // scroll-to-top transition was invisible to us) and steals the
        // capture: from now on every move and the release are ours.
        const dy = ev.raw_y - last;
        if (dy > 0 and contentAtTop(n)) {
            s.pulling = true;
            s.pull = 0; // this move only anchors
            router.captureNode(ev, n, n);
            return true;
        }
        return false;
    }
    // The PTR owns the gesture: every delta is ours (see handleCapturedMove).
    handleCapturedMove(n, s, ev.raw_y - last);
    return true;
}

/// The refreshing spinner clock: a looping 0..1 linear tween (the driving
/// loop period); the update callback accumulates real elapsed time so the
/// indeterminate schedule never drifts. Without a timeline it stays static.
fn startSpin(n: *Node, s: *PtrState) void {
    const tl = anim.timeline() orelse return;
    _ = tl.play(.{
        .kind = anim.Animation.tweenAnim(.{ 1, 0, 0, 0 }, progress_w.circular_indet_ms, .{ .ease = .linear }),
        .from = .{ 0, 0, 0, 0 },
        .channel = @ptrCast(&s.spin_channel),
        .on_update = .{ .fn_ptr = spinUpdateCb, .userdata = n },
        .on_complete = .{ .fn_ptr = spinLoopCb, .userdata = n },
    });
    s.spin_running = true;
}

fn stopSpin(n: *Node, s: *PtrState) void {
    if (!s.spin_running) return;
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.spin_channel));
    s.spin_running = false;
    n.markDirtyRect(n.bounds);
}

fn spinUpdateCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    var d = value[0] - s.last_phase;
    if (d < 0) d += 1;
    s.elapsed_ms += @as(f64, d) * @as(f64, @floatFromInt(progress_w.circular_indet_ms));
    s.last_phase = value[0];
    n.markDirtyRect(n.bounds);
}

fn spinLoopCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.spin_running = false;
    if (s.sig.peek()) startSpin(n, s); // loop while refreshing
}

fn ptrDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| {
        tl.cancelChannel(@ptrCast(&s.anim_channel));
        tl.cancelChannel(@ptrCast(&s.spin_channel));
    }
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = ptrSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const ptr_vtable = ui.node.VTable{
    .measure = ptrMeasure,
    .layout = ptrLayout,
    .paint = ptrPaint,
    .deinit = ptrDeinit,
    .on_pointer = ptrOnPointer,
    .pre_children_paint = ptrPreChildrenPaint,
    .post_children_paint = ptrPostChildrenPaint,
    .map_paint_rect = ptrMapPaintRect,
    .child_clip = ptrChildClip,
    .pre_children_hit = ptrPreChildrenHit,
};

fn applyAdjusted(n: *Node, s: *PtrState, value: f32) void {
    s.adjusted = value;
    n.markDirtyRect(n.bounds); // the content (translated) + the indicator
}

/// Animate the adjusted offset with the spatial spring; without a timeline,
/// snap.
fn animateAdjusted(n: *Node, s: *PtrState, to: f32) void {
    s.anim_to = to;
    const from: anim.Vec4 = .{ s.adjusted, 0, 0, 0 };
    const target: anim.Vec4 = .{ to, 0, 0, 0 };
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.springAnim(from, target, s.opts.theme.motion.springs.spatial_spring, .{ 0, 0, 0, 0 }),
            .from = from,
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = ptrAnimUpdateCb, .userdata = n },
            .on_complete = .{ .fn_ptr = ptrAnimCompleteCb, .userdata = n },
        });
    } else {
        applyAdjusted(n, s, to);
    }
}

fn ptrAnimUpdateCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    applyAdjusted(n, stateOf(n), value[0]);
}

fn ptrAnimCompleteCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    applyAdjusted(n, stateOf(n), stateOf(n).anim_to);
}

/// The release: past the threshold → on_refresh + the refreshing signal (the
/// sync animates to the resting offset); below → snap back.
fn finishPull(n: *Node, s: *PtrState, pull: f32) void {
    // upstream onRelease: adjustedDistancePulled (= pull × 0.5) > thresholdPx
    if (pull * drag_multiplier > threshold) {
        if (s.on_refresh) |cb| cb.fn_ptr(cb.userdata);
        s.sig.set(true);
    } else {
        animateAdjusted(n, s, 0);
    }
}

/// The refreshing signal changed (the app): hold at rest while refreshing,
/// hide when done (the finger wins while pulling).
fn ptrSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.sig.peek()) {
        if (s.laid_out) startSpin(n, s);
    } else {
        stopSpin(n, s);
    }
    if (!s.laid_out or s.pulling) return;
    const target: f32 = if (s.sig.peek()) resting else 0;
    if (target != s.adjusted) animateAdjusted(n, s, target);
}

/// A pull-to-refresh container. The content is a DOCUMENT child — attach it
/// with `node.add(content)` (typically a scroll_view). `refreshing` is
/// app-owned (two-way): the PTR sets it on trigger; the app clears it when
/// the refresh completes. `on_refresh` fires at the trigger.
pub fn pullToRefresh(allocator: std.mem.Allocator, refreshing: *ui.state.Signal(bool), on_refresh: ?Callback, opts: PullToRefreshOptions) !*Node {
    const node = try Node.create(allocator, &ptr_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(PtrState);
    errdefer allocator.destroy(s);
    s.* = .{ .sig = refreshing, .opts = opts, .on_refresh = on_refresh };
    node.state = s;
    ui.semantics.attach(node, .{ .role = .group, .label = opts.label }); // Phase 2c
    refreshing.subscribe(.{ .callback = .{ .fn_ptr = ptrSyncCb, .userdata = node } });
    return node;
}

// --- tests ---

fn refreshCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

/// A PTR wrapping a scroll view (content 500 tall in a 200 viewport).
fn ptrWithScroll(a: std.mem.Allocator, refreshing: *ui.state.Signal(bool), on_refresh: ?Callback) !*Node {
    const ptr = try pullToRefresh(a, refreshing, on_refresh, .{});
    errdefer ptr.deinit();
    const sv = try scroll_view.scrollView(a, .{});
    sv.add(try golden.solidBox(a, 100, 500, 0xFF0000FF));
    ptr.add(sv);
    return ptr;
}

test "pull_to_refresh: measures/layouts like its content (fills the parent)" {
    const a = std.testing.allocator;
    const refreshing = try ui.state.Signal(bool).init(a, false);
    defer refreshing.deinit();
    const ptr = try ptrWithScroll(a, refreshing, null);
    defer ptr.deinit();
    const m = ptr.measure(.{ .max_w = 100, .max_h = 200 });
    try std.testing.expectEqual(@as(f32, 100), m.w);
    try std.testing.expectEqual(@as(f32, 200), m.h); // the viewport, not the content
    ptr.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    try std.testing.expectEqual(@as(f32, 500), ptr.children.items[0].children.items[0].bounds.h);
    try std.testing.expectEqual(@as(f32, 0), adjusted(ptr)); // hidden
}

test "pull_to_refresh: a drag down at scroll top pulls; release past the adjusted threshold triggers; below snaps back" {
    var fired: u32 = 0;
    const cb = Callback{ .fn_ptr = refreshCounterCb, .userdata = &fired };
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const refreshing = try ui.state.Signal(bool).init(a, false);
    defer refreshing.deinit();
    const ptr = try ptrWithScroll(a, refreshing, cb);
    defer ptr.deinit();
    ptr.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    // a short pull (30 < 80): no trigger, snaps back. The first move past
    // the top anchors the pull origin; the next ones pull.
    router.dispatchPointer(ptr, .{ .phase = .down, .x = 50, .y = 100, .raw_x = 50, .raw_y = 100 });
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 130, .raw_x = 50, .raw_y = 130 }); // anchor
    try std.testing.expectEqual(@as(f32, 0), adjusted(ptr));
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 160, .raw_x = 50, .raw_y = 160 }); // pull 30
    try std.testing.expectEqual(@as(f32, 15), adjusted(ptr)); // 30 × 0.5
    router.dispatchPointer(ptr, .{ .phase = .up, .x = 50, .y = 160, .raw_x = 50, .raw_y = 160 });
    try std.testing.expectEqual(@as(f32, 0), adjusted(ptr)); // snapped back
    try std.testing.expectEqual(@as(u32, 0), fired);
    try std.testing.expect(!refreshing.peek());
    // a pull of 100 → adjusted 50 < 80: still no trigger (upstream compares
    // the ADJUSTED distance to the 80dp threshold)
    router.dispatchPointer(ptr, .{ .phase = .down, .x = 50, .y = 100, .raw_x = 50, .raw_y = 100 });
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 130, .raw_x = 50, .raw_y = 130 }); // anchor
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 230, .raw_x = 50, .raw_y = 230 }); // pull 100
    try std.testing.expectEqual(@as(f32, 50), adjusted(ptr)); // 100 × 0.5
    router.dispatchPointer(ptr, .{ .phase = .up, .x = 50, .y = 230, .raw_x = 50, .raw_y = 230 });
    try std.testing.expectEqual(@as(u32, 0), fired);
    // a pull of 200 → adjusted 100 > 80: triggers
    router.dispatchPointer(ptr, .{ .phase = .down, .x = 50, .y = 100, .raw_x = 50, .raw_y = 100 });
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 130, .raw_x = 50, .raw_y = 130 }); // anchor
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 330, .raw_x = 50, .raw_y = 330 }); // pull 200
    try std.testing.expectEqual(@as(f32, 100), adjusted(ptr)); // 200 × 0.5
    router.dispatchPointer(ptr, .{ .phase = .up, .x = 50, .y = 330, .raw_x = 50, .raw_y = 330 });
    try std.testing.expectEqual(@as(u32, 1), fired); // on_refresh fired
    try std.testing.expect(refreshing.peek()); // the signal round-trips
    try std.testing.expectEqual(resting, adjusted(ptr)); // held at rest
    // while refreshing, the gesture is ignored
    router.dispatchPointer(ptr, .{ .phase = .down, .x = 50, .y = 100, .raw_x = 50, .raw_y = 100 });
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 150, .raw_x = 50, .raw_y = 150 });
    try std.testing.expectEqual(resting, adjusted(ptr)); // unchanged
    // the app clears the refreshing state → the indicator hides
    refreshing.set(false);
    try std.testing.expectEqual(@as(f32, 0), adjusted(ptr));
}

test "pull_to_refresh: a drag does NOT pull when the content is scrolled" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const refreshing = try ui.state.Signal(bool).init(a, false);
    defer refreshing.deinit();
    const ptr = try ptrWithScroll(a, refreshing, null);
    defer ptr.deinit();
    ptr.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    const sv = ptr.children.items[0];
    _ = scroll_view.setScrollOffset(sv, 100); // scrolled: not at top
    // drag down: the scroll view scrolls (offset decreases), the PTR ignores
    router.dispatchPointer(ptr, .{ .phase = .down, .x = 50, .y = 100, .raw_x = 50, .raw_y = 100 });
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 150, .raw_x = 50, .raw_y = 150 }); // down 50
    try std.testing.expectEqual(@as(f32, 0), adjusted(ptr)); // no pull
    try std.testing.expectEqual(@as(f32, 50), scroll_view.scrollOffset(sv)); // scrolled 100 → 50
    router.dispatchPointer(ptr, .{ .phase = .up, .x = 50, .y = 150, .raw_x = 50, .raw_y = 150 });
    // back at the top mid-drag: the first move past the top anchors the pull
    // origin (the scroll-to-top transition was invisible to the PTR), then
    // the capture is stolen and the next moves pull
    router.dispatchPointer(ptr, .{ .phase = .down, .x = 50, .y = 100, .raw_x = 50, .raw_y = 100 });
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 140, .raw_x = 50, .raw_y = 140 }); // down 40 → scrolls 50 → 10 (claimed)
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 150, .raw_x = 50, .raw_y = 150 }); // down 10 → scrolls 10 → 0 (claimed)
    try std.testing.expectEqual(@as(f32, 0), adjusted(ptr)); // the PTR has not seen a move yet
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 160, .raw_x = 50, .raw_y = 160 }); // anchor: the capture is stolen
    try std.testing.expectEqual(@as(f32, 0), adjusted(ptr)); // the anchor move itself does not pull
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 180, .raw_x = 50, .raw_y = 180 }); // pulls 20
    try std.testing.expectEqual(@as(f32, 10), adjusted(ptr)); // 20 × 0.5
    try std.testing.expectEqual(@as(f32, 0), scroll_view.scrollOffset(sv)); // still at the top
    router.dispatchPointer(ptr, .{ .phase = .up, .x = 50, .y = 180, .raw_x = 50, .raw_y = 180 });
    try std.testing.expectEqual(@as(f32, 0), adjusted(ptr)); // below the threshold → snapped back
}

test "pull_to_refresh: the refreshing signal drives the indicator (no gesture)" {
    const a = std.testing.allocator;
    const refreshing = try ui.state.Signal(bool).init(a, false);
    defer refreshing.deinit();
    const ptr = try ptrWithScroll(a, refreshing, null);
    defer ptr.deinit();
    ptr.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    try std.testing.expectEqual(@as(f32, 0), adjusted(ptr));
    refreshing.set(true);
    try std.testing.expectEqual(resting, adjusted(ptr)); // held at rest
    refreshing.set(false);
    try std.testing.expectEqual(@as(f32, 0), adjusted(ptr)); // hidden
}

test "golden: the indicator paints the container circle + the arc; the content translates down" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const refreshing = try ui.state.Signal(bool).init(a, false);
    defer refreshing.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const ptr = try ptrWithScroll(a, refreshing, null);
    defer ptr.deinit();
    // pull 100 → adjusted 50: progress = 50/80 = 0.625 (above the arrow
    // indicator's 0.4 floor). The indicator's bottom rides the pull edge
    // (y = 10 + 50 = 60), the container spans y = 20..60, center (60, 40)
    ptr.layout(.{ .x = 10, .y = 10, .w = 100, .h = 200 });
    router.dispatchPointer(ptr, .{ .phase = .down, .x = 60, .y = 100, .raw_x = 60, .raw_y = 100 });
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 60, .y = 120, .raw_x = 60, .raw_y = 120 }); // anchor
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 60, .y = 220, .raw_x = 60, .raw_y = 220 }); // pull 100
    var r = try golden.Renderer.init(a, 120, 220);
    defer r.deinit();
    r.paint(ptr, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    // the container circle (surface_container_high) at the top-center
    try std.testing.expectEqual(t.colors.surface_container_high, f.pixelAt(60, 40));
    // the arrow-indicator ink inside the container (blended over it, so not
    // the exact role color)
    try std.testing.expect(f.countNotIn(.{ .x = 52, .y = 32, .w = 16, .h = 16 }, t.colors.surface_container_high) > 0);
    // the content translated down by the vertical offset (50 < 80 → 50):
    // the red content starts at y = 60
    try std.testing.expectEqual(@as(Color, 0xFF0000FF), f.pixelAt(60, 70));
    // left of the container (x = 20 is outside the 40dp circle), above the
    // content: untouched background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20, 45));
    router.dispatchPointer(ptr, .{ .phase = .up, .x = 60, .y = 220, .raw_x = 60, .raw_y = 220 });
}

test "pull_to_refresh: a drag that scrolls to the top first does not count the scrolled distance as pull" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    var fired: u32 = 0;
    const cb = Callback{ .fn_ptr = refreshCounterCb, .userdata = &fired };
    const refreshing = try ui.state.Signal(bool).init(a, false);
    defer refreshing.deinit();
    const ptr = try ptrWithScroll(a, refreshing, cb);
    defer ptr.deinit();
    ptr.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    const sv = ptr.children.items[0];
    _ = scroll_view.setScrollOffset(sv, 100); // scrolled
    // drag down 100: the scroll view scrolls to the top (it claims the moves)
    router.dispatchPointer(ptr, .{ .phase = .down, .x = 50, .y = 100, .raw_x = 50, .raw_y = 100 });
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 200, .raw_x = 50, .raw_y = 200 });
    try std.testing.expectEqual(@as(f32, 0), scroll_view.scrollOffset(sv)); // at the top
    try std.testing.expectEqual(@as(f32, 0), adjusted(ptr)); // the PTR has seen no move
    // past the top: the first move anchors the pull origin (the scrolled
    // distance is NOT pull), the next ones pull
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 240, .raw_x = 50, .raw_y = 240 }); // anchor
    try std.testing.expectEqual(@as(f32, 0), adjusted(ptr));
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 310, .raw_x = 50, .raw_y = 310 }); // pull 70
    try std.testing.expectEqual(@as(f32, 35), adjusted(ptr)); // 70 × 0.5
    router.dispatchPointer(ptr, .{ .phase = .up, .x = 50, .y = 310, .raw_x = 50, .raw_y = 310 });
    try std.testing.expectEqual(@as(u32, 0), fired); // 70 < 80: no refresh
    try std.testing.expectEqual(@as(f32, 0), adjusted(ptr)); // snapped back
}

test "pull_to_refresh: reversing a pull shrinks it and scrolls instead of refreshing" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    var fired: u32 = 0;
    const cb = Callback{ .fn_ptr = refreshCounterCb, .userdata = &fired };
    const refreshing = try ui.state.Signal(bool).init(a, false);
    defer refreshing.deinit();
    const ptr = try ptrWithScroll(a, refreshing, cb);
    defer ptr.deinit();
    ptr.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    const sv = ptr.children.items[0];
    // pull 100 down (past the threshold), then drag back up 150: the pull
    // shrinks to 0 and the excess scrolls the content (the PTR owns the
    // gesture, so the scroll view cannot consume the return move)
    router.dispatchPointer(ptr, .{ .phase = .down, .x = 50, .y = 100, .raw_x = 50, .raw_y = 100 });
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 130, .raw_x = 50, .raw_y = 130 }); // anchor
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 230, .raw_x = 50, .raw_y = 230 }); // pull 100
    try std.testing.expectEqual(@as(f32, 50), adjusted(ptr));
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 80, .raw_x = 50, .raw_y = 80 }); // up 150
    try std.testing.expectEqual(@as(f32, 0), adjusted(ptr)); // the pull is gone
    try std.testing.expectEqual(@as(f32, 50), scroll_view.scrollOffset(sv)); // 100 absorbed the pull, 50 scrolled
    router.dispatchPointer(ptr, .{ .phase = .up, .x = 50, .y = 80, .raw_x = 50, .raw_y = 80 });
    try std.testing.expectEqual(@as(u32, 0), fired); // no refresh
    try std.testing.expect(!refreshing.peek());
}

test "pull_to_refresh: a pull starting over a button still triggers (the release is not stranded)" {
    const button_w = @import("button.zig");
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    var fired: u32 = 0;
    var btn_fired: u32 = 0;
    const refreshing = try ui.state.Signal(bool).init(a, false);
    defer refreshing.deinit();
    const ptr = try pullToRefresh(a, refreshing, .{ .fn_ptr = refreshCounterCb, .userdata = &fired }, .{});
    defer ptr.deinit();
    const sv = try scroll_view.scrollView(a, .{});
    sv.add(try button_w.button(a, .{ .fn_ptr = refreshCounterCb, .userdata = &btn_fired }, .{ .label = "Pull" }));
    ptr.add(sv);
    ptr.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    // press the button, drag down past the threshold, release: the PTR steals
    // the capture at the first move past the top, so the release reaches it
    // (the button's click was canceled by the drag)
    router.dispatchPointer(ptr, .{ .phase = .down, .x = 25, .y = 20, .raw_x = 25, .raw_y = 20 });
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 25, .y = 120, .raw_x = 25, .raw_y = 120 }); // the button cancels; the PTR's track self-heals
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 25, .y = 220, .raw_x = 25, .raw_y = 220 }); // anchor: the capture is stolen
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 25, .y = 420, .raw_x = 25, .raw_y = 420 }); // pull 200
    try std.testing.expectEqual(@as(f32, 100), adjusted(ptr));
    router.dispatchPointer(ptr, .{ .phase = .up, .x = 25, .y = 420, .raw_x = 25, .raw_y = 420 });
    try std.testing.expectEqual(@as(u32, 1), fired); // the refresh fired
    try std.testing.expectEqual(@as(u32, 0), btn_fired); // the button's click was canceled
    try std.testing.expect(refreshing.peek());
}

test "pull_to_refresh: a fresh gesture cancels the in-flight snap-back spring" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const refreshing = try ui.state.Signal(bool).init(a, false);
    defer refreshing.deinit();
    const ptr = try ptrWithScroll(a, refreshing, null);
    defer ptr.deinit();
    ptr.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    tl.tick(0); // lazy start
    // a short pull (30 < 80): the release starts a snap-back spring
    router.dispatchPointer(ptr, .{ .phase = .down, .x = 50, .y = 100, .raw_x = 50, .raw_y = 100 });
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 130, .raw_x = 50, .raw_y = 130 }); // anchor
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 160, .raw_x = 50, .raw_y = 160 }); // pull 30
    try std.testing.expectEqual(@as(f32, 15), adjusted(ptr));
    router.dispatchPointer(ptr, .{ .phase = .up, .x = 50, .y = 160, .raw_x = 50, .raw_y = 160 });
    try std.testing.expect(tl.hasActive()); // the snap-back spring runs
    // a new pull before the spring settles: the down cancels the spring
    router.dispatchPointer(ptr, .{ .phase = .down, .x = 50, .y = 100, .raw_x = 50, .raw_y = 100 });
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 130, .raw_x = 50, .raw_y = 130 }); // anchor
    router.dispatchPointer(ptr, .{ .phase = .move, .x = 50, .y = 330, .raw_x = 50, .raw_y = 330 }); // pull 200
    try std.testing.expectEqual(@as(f32, 100), adjusted(ptr));
    tl.tick(50); // the canceled spring must not overwrite the new pull
    try std.testing.expectEqual(@as(f32, 100), adjusted(ptr));
    router.dispatchPointer(ptr, .{ .phase = .up, .x = 50, .y = 330, .raw_x = 50, .raw_y = 330 });
    try std.testing.expect(refreshing.peek()); // adjusted 100 > 80 → triggered
}
