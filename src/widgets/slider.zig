// Slider (Phase 2d.2 PR B2, M3E) — the M3E slider (horizontal, continuous).
//
// Spec: m3.material.io/components/slider + Compose SliderTokens / Slider.kt:
//   - track 16dp high (InactiveTrackHeight), CornerFull (pill), inset by half
//     the thumb width (the thumb marks the value, the track spans between)
//   - the active track (0 → value) Primary, the inactive track
//     SecondaryContainer
//   - the thumb: a 4x44 vertical bar (HandleWidth x HandleHeight), CornerFull,
//     centered on the value position; focus/pressed → 2dp wide
//   - disabled: active track OnSurface@0.38, inactive track OnSurface@0.12,
//     thumb OnSurface@0.38
//   - state layer: a 40dp circle centered on the thumb, Primary @ hover 0.08 /
//     focus 0.10 / pressed 0.12
//   - hit target: max(width,48) x max(44,48) (the a11y floor is the hit area)
//   - input: a down/drag sets the value from the pointer x (the drag IS the
//     interaction — no slop cancel); arrows adjust by ±1% (keyboard,
//     upstream's rangeLength/100 — `steps+1` in discrete mode)
//
// Discrete mode (upstream `steps`): N>0 quantizes the value to the N+2
// tick fractions (snapValueToTick during drag, keyboard delta =
// range/(steps+1)), draws the stop-indicator ticks inside the corner-inset
// range (the endpoints' ticks: index 0 draws on the active track's corner
// center, the last is covered by the end stop dot), and maps the thumb
// through the inset range between the corner centers while it isn't on an
// endpoint. While pressed/dragging the value indicator bubble floats 12dp
// above the thumb (ValueIndicatorActiveBottomSpace) — InverseSurface pill
// with a tail, LabelLarge InverseOnSurface "{d}%" text.
//
// Remaining deviations (documented, fixed later):
//   - vertical sliders and range sliders are separate widgets; the bubble
//     doesn't morph its shape (upstream's label animates in on drag start).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

/// M3E measurement tokens (SliderTokens + Slider.kt).
const track_h: f32 = 16;
const thumb_w: f32 = 4; // HandleWidth
const thumb_w_active: f32 = 2; // FocusHandleWidth / PressedHandleWidth
const thumb_h: f32 = 44; // HandleHeight
const inset: f32 = thumb_w / 2; // the track is inset by half the thumb width
const state_layer_size: f32 = 40;
/// Upstream slideOnKeyEvents: delta = range/actualSteps — 1% continuous.
const keyboard_step: f32 = 0.01;
/// The bubble's gap above the thumb (ValueIndicatorActiveBottomSpace).
const indicator_gap: f32 = 12;
/// The bubble tail — a small downward point under the pill.
const indicator_tail_w: f32 = 10;
const indicator_tail_h: f32 = 6;
const indicator_h_pad: f32 = 12;
const indicator_v_pad: f32 = 6;
// Compose minimumInteractiveComponentSize (the a11y hit-target floor) =
// theme.platform.hit_target_min — read from s.opts.theme where used.
/// TrackCornerSize — CornerFull on a 16dp track.
const track_corner: f32 = track_h / 2;
/// TrackInsideCornerSize — the corners facing the handle gap.
const inside_corner: f32 = 2;
/// ThumbTrackGapSize — the gap between handle edge and track segment end.
const track_gap: f32 = 6;
/// TrackStopIndicatorSize — the dot at the inactive track's outer end.
const stop_d: f32 = 4;

pub const SliderOptions = struct {
    enabled: bool = true,
    /// The natural width when the parent does not constrain it.
    default_width: f32 = 160,
    /// Discrete stops BETWEEN the endpoints (upstream `steps`): 0 = the
    /// continuous slider; N>0 quantizes to i/(N+1) and draws the ticks.
    steps: u16 = 0,
    /// The accessible name.
    a11y_label: []const u8 = "",
    theme: Theme = theme_mod.light,
};

const SliderState = struct {
    opts: SliderOptions,
    sig: *ui.state.Signal(f32),
    on_changed: ?Callback = null,
    pressed: bool = false,
    hovered: bool = false,
    /// Gesture arbitration (raw coords): a horizontal drag edits the value,
    /// a vertical drag is a scroll and bubbles to the scrollable.
    dragging: bool = false,
    scroll_won: bool = false,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — see PointerEvent.raw_x/raw_y).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
    /// The handle width — 4dp resting, morphs to 2dp pressed/focused via the
    /// theme's fast spatial spring (M3E SliderTokens ActiveHandleWidth).
    handle_w: f32 = thumb_w,
    handle_target: f32 = thumb_w,
    anim_channel: u8 = 0, // channel marker (stable address)
    /// The semantic value string ("42%") — borrowed by the semantics.
    value_buf: [16]u8 = std.mem.zeroes([16]u8),
    value_len: usize = 0,
};

fn stateOf(n: *Node) *SliderState {
    return @ptrCast(@alignCast(n.state.?));
}

fn clampedValue(s: *SliderState) f32 {
    return std.math.clamp(s.sig.peek(), 0, 1);
}

/// Upstream snapValueToTick: with steps>0 the value quantizes to the
/// nearest tick fraction i/(steps+1); 0 keeps the continuous range.
fn snap(s: *SliderState, v: f32) f32 {
    const c = std.math.clamp(v, 0, 1);
    if (s.opts.steps == 0) return c;
    const n: f32 = @floatFromInt(s.opts.steps + 1);
    return @round(c * n) / n;
}

/// The active/inactive track colors + the thumb color for the current state.
const SLColors = struct { active: Color, inactive: Color, thumb: Color };

fn currentColors(s: *SliderState) SLColors {
    const cs = s.opts.theme.colors;
    if (!s.opts.enabled) {
        return .{
            .active = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
            .inactive = ui.paint.withAlphaScaled(cs.on_surface, 0.12),
            .thumb = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
        };
    }
    return .{ .active = cs.primary, .inactive = cs.secondary_container, .thumb = cs.primary };
}

fn sliderMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    return c.constrain(.{ .w = s.opts.default_width, .h = thumb_h });
}

/// The interactive target: max(width,hit) x max(height,hit) centered on the
/// node — hit = theme.platform.hit_target_min (48 mobile / 24 desktop).
fn sliderHitBounds(n: *Node) Rect {
    const s = stateOf(n);
    const b = n.bounds;
    const w = @max(b.w, s.opts.theme.platform.hit_target_min);
    const h = @max(b.h, s.opts.theme.platform.hit_target_min);
    return .{ .x = b.x + (b.w - w) / 2, .y = b.y + (b.h - h) / 2, .w = w, .h = h };
}

fn sliderPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const cc = currentColors(s);
    const cs = s.opts.theme.colors;
    const v = clampedValue(s);
    const rtl = ui.i18n.direction() == .rtl;
    // track: 16dp high, vertically centered, inset by half the thumb width
    const ty = b.y + (b.h - track_h) / 2;
    const tx = b.x + inset;
    const tw = @max(0, b.w - inset * 2);
    const cy = b.y + b.h / 2;
    // The handle narrows pressed/focused — the morph is sprung (M3E). Focus
    // has no widget callback, so the target is detected lazily here (paint
    // runs on every dirty → a focus change re-arms it the next frame).
    const want: f32 = if (s.pressed or input.isFocused(n)) thumb_w_active else thumb_w;
    if (want != s.handle_target) {
        s.handle_target = want;
        morphHandle(n, s, want);
    }
    const thw = s.handle_w;
    // Compose drawTrack: the track splits into an ACTIVE segment
    // (value-start → handle) and an INACTIVE segment (handle → value-end)
    // separated by a gap = handleW/2 + 6dp measured from the handle center.
    // Upstream drawTrack with steps: the value maps into the corner-inset
    // range [corner, tw - corner] so the endpoint ticks sit at the corner
    // centers — except while the value sits ON an endpoint (full range).
    const on_endpoint = v <= 0 or v >= 1;
    const value_x = if (s.opts.steps > 0 and !on_endpoint)
        track_corner + (tw - track_corner * 2) * v
    else
        tw * v; // handle center in the track's value space
    const gap = thw / 2 + track_gap;
    // Map a value-space x to a screen x (RTL mirrors the value direction).
    const vx = struct {
        fn f(tx0: f32, tw0: f32, xv: f32, flip: bool) f32 {
            return tx0 + (if (flip) tw0 - xv else xv);
        }
    }.f;
    const cx = vx(tx, tw, value_x, rtl);
    // Active segment: [0, value_x - gap] in value space — outer (value-start)
    // corner full, inner (handle side) corner 2dp. Painted only when wider
    // than its outer corner (Compose activeTrackThreshold).
    const a_w = value_x - gap;
    if (a_w > track_corner) {
        if (rtl) {
            ui.paint.fillRRectCorners(ctx, tx + tw - a_w, ty, a_w, track_h, inside_corner, track_corner, track_corner, inside_corner, cc.active);
        } else {
            ui.paint.fillRRectCorners(ctx, tx, ty, a_w, track_h, track_corner, inside_corner, inside_corner, track_corner, cc.active);
        }
    }
    // Inactive segment: [value_x + gap .. tw] — inner (handle side) 2dp,
    // outer (value-end) corner full. Painted only past cornerSize + gap.
    const i_x = value_x + gap;
    const i_w = tw - i_x;
    if (i_w > track_corner) {
        if (rtl) {
            ui.paint.fillRRectCorners(ctx, tx, ty, i_w, track_h, track_corner, inside_corner, inside_corner, track_corner, cc.inactive);
        } else {
            ui.paint.fillRRectCorners(ctx, tx + i_x, ty, i_w, track_h, inside_corner, track_corner, track_corner, inside_corner, cc.inactive);
        }
        // Stop indicator: a 4dp dot in the ACTIVE color, centered
        // inside-corner-inset from the track's value-end.
        const stop_x = vx(tx, tw, tw - track_corner, rtl);
        ui.paint.fillRRect(ctx, stop_x - stop_d / 2, cy - stop_d / 2, stop_d, stop_d, stop_d / 2, cc.active);
    }
    // Ticks (upstream tickFractions = i/(steps+1), i = 0..steps+1): a 4dp
    // dot at each stop inside the corner-inset range — active-segment ticks
    // punch in the inactive color and vice versa (the contrast inversion);
    // the last endpoint sits under the stop indicator (skipped), and a tick
    // covered by the handle gap is skipped.
    if (s.opts.steps > 0) {
        const n_frac: usize = @as(usize, s.opts.steps) + 2;
        for (0..n_frac) |i| {
            if (i == n_frac - 1) continue; // the end stop indicator's spot
            const f = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n_frac - 1));
            const t = track_corner + (tw - track_corner * 2) * f; // value-space x
            if (t >= value_x - gap and t <= value_x + gap) continue; // under the handle
            // activeTrack = [0, value_x - gap] — the painted segment minus
            // its gap, matching upstream's `centerTick in activeTrack`.
            const col = if (!s.opts.enabled)
                (if (t <= value_x - gap) ui.paint.withAlphaScaled(cs.on_surface, 0.12) else ui.paint.withAlphaScaled(cs.on_surface, 0.38))
            else if (t <= value_x - gap) cc.inactive else cc.active;
            ui.paint.fillRRect(ctx, vx(tx, tw, t, rtl) - stop_d / 2, cy - stop_d / 2, stop_d, stop_d, stop_d / 2, col);
        }
    }
    // Handle: a 4x44 vertical bar (2dp while pressed/focused) centered on
    // the value position, CornerFull.
    ui.paint.fillRRect(ctx, cx - thw / 2, b.y, thw, b.h, thw / 2, cc.thumb);
    // state layer (enabled only): a 40dp circle centered on the handle
    if (s.opts.enabled) {
        const alpha: f32 = if (s.pressed)
            s.opts.theme.state.pressed
        else if (input.isFocused(n))
            s.opts.theme.state.focus
        else if (s.hovered)
            s.opts.theme.state.hover
        else
            0;
        if (alpha > 0) {
            ui.paint.fillRRect(ctx, cx - state_layer_size / 2, cy - state_layer_size / 2, state_layer_size, state_layer_size, state_layer_size / 2, ui.paint.withAlphaScaled(cc.thumb, alpha));
        }
    }

    // --- value indicator (while pressed/dragging): the InverseSurface
    // pill + tail 12dp above the thumb's top (ValueIndicatorActiveBottom-
    // Space), LabelLarge InverseOnSurface value text ---
    if ((s.pressed or s.dragging) and s.opts.enabled) {
        const ls = s.opts.theme.type_scale.label_large;
        const txt = s.value_buf[0..s.value_len :0];
        const lm = ui.paint.measureText(txt, ls.size, false);
        const pw = @max(lm.width + indicator_h_pad * 2, 24);
        const ph = ls.line_height + indicator_v_pad * 2;
        const by = b.y - indicator_gap; // bubble bottom edge
        const bx = cx - pw / 2; // centered on the handle
        ui.paint.fillRRect(ctx, bx, by - ph, pw, ph, ph / 2, cs.inverse_surface);
        // the tail: a small downward point centered on the handle
        const pts = [6]f32{ cx - indicator_tail_w / 2, by, cx + indicator_tail_w / 2, by, cx, by + indicator_tail_h };
        const verbs = [4]i32{ @backingInt(ui.paint.PathVerb.move), @backingInt(ui.paint.PathVerb.line), @backingInt(ui.paint.PathVerb.line), @backingInt(ui.paint.PathVerb.close) };
        ui.paint.fillPath(ctx, &pts, &verbs, cs.inverse_surface, false);
        ui.paint.text(ctx, txt, cx - lm.width / 2, by - ph + (ph - (lm.ascent + lm.descent)) / 2 + lm.ascent, ls.size, false, cs.inverse_on_surface);
    }
}

/// The value for a pointer x (window coords): the track spans
/// [b.x + inset, b.x + w - inset]. RTL mirrors the value direction.
fn valueAt(s: *SliderState, b: Rect, x: f32) f32 {
    const tw = @max(0, b.w - inset * 2);
    if (tw <= 0) return 0;
    const f = std.math.clamp((x - b.x - inset) / tw, 0, 1);
    const raw = if (ui.i18n.direction() == .rtl) 1 - f else f;
    return snap(s, raw); // discrete: the nearest tick's value
}

fn sliderOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    switch (ev.phase) {
        .down => {
            s.pressed = true;
            s.dragging = false;
            s.scroll_won = false;
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            const v = valueAt(s, n.bounds, ev.x);
            s.sig.set(v);
            if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            n.markDirty();
            return true;
        },
        .move => {
            // the router only delivers move while we are captured (drag)
            if (s.scroll_won) return false; // the scroll owns the gesture
            if (!s.dragging) {
                // gesture arbitration: past the touch slop, the dominant axis
                // decides — horizontal = slider drag (claim), vertical =
                // scroll (release: bubble to the scrollable)
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    if (@abs(dy) > @abs(dx)) {
                        s.scroll_won = true;
                        s.pressed = false;
                        n.markDirty();
                        return false;
                    }
                    s.dragging = true;
                }
            }
            if (s.dragging) {
                s.pressed = true; // kept for the whole drag (pressed feedback)
                const v = valueAt(s, n.bounds, ev.x);
                s.sig.set(v);
                if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
                n.markDirty();
            }
            return s.dragging; // claim only the horizontal drag
        },
        .up => {
            const was_scrolling = s.scroll_won;
            s.pressed = false;
            s.dragging = false;
            s.scroll_won = false;
            n.markDirty();
            return !was_scrolling; // a scroll-owned gesture: the up bubbles
        },
        .enter => {
            s.hovered = true;
            n.markDirty();
            return true;
        },
        .leave => {
            s.hovered = false;
            n.markDirty();
            return true;
        },
        else => {},
    }
    return false;
}

/// Keyboard (Phase 2c): arrows adjust the value. Left/right follow the
/// VALUE direction — in RTL "right" decreases (a11y matches the drag).
fn sliderOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    if (ev.kind != .key_down) return false;
    const rtl = ui.i18n.direction() == .rtl;
    // Upstream slideOnKeyEvents: delta = range/(steps+1) discrete, 1% when
    // continuous; home/end jump to the range edges.
    const step: f32 = if (s.opts.steps > 0) 1.0 / @as(f32, @floatFromInt(s.opts.steps + 1)) else keyboard_step;
    switch (ev.key) {
        .left, .down => {
            const d: f32 = if (ev.key == .left and rtl) step else -step;
            s.sig.set(std.math.clamp(s.sig.peek() + d, 0, 1));
            if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        .right, .up => {
            const d: f32 = if (ev.key == .right and rtl) -step else step;
            s.sig.set(std.math.clamp(s.sig.peek() + d, 0, 1));
            if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        .home => {
            s.sig.set(0);
            if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        .end => {
            s.sig.set(1);
            if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        else => {},
    }
    return false;
}

/// Repaint + keep the semantic value in sync (Phase 2c). The announced value
/// is clamped — an out-of-range signal must not announce beyond 0-100.
/// The handle-width morph: 4dp resting ↔ 2dp pressed/focused, sprung with
/// the theme spatial spring (M3E fast-spatial handle morph). No timeline →
/// snap (headless tests render the target state).
fn morphHandle(n: *Node, s: *SliderState, target: f32) void {
    if (ui.anim.timeline()) |tl| {
        const from: ui.anim.Vec4 = .{ s.handle_w, 0, 0, 0 };
        _ = tl.play(.{
            .kind = ui.anim.Animation.springAnim(from, .{ target, 0, 0, 0 }, s.opts.theme.motion.springs.spatial_spring, .{ 0, 0, 0, 0 }),
            .from = from,
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = handleWCb, .userdata = n },
        });
    } else {
        s.handle_w = target;
        n.markDirty();
    }
}

fn handleWCb(userdata: ?*anyopaque, value: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).handle_w = value[0];
    n.markDirty();
}

fn sliderSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const str = std.fmt.bufPrint(&s.value_buf, "{d:.0}%", .{clampedValue(s) * 100}) catch return;
    s.value_len = str.len;
    s.value_buf[s.value_len] = 0; // sentinel for measureText/text (16-slot buffer)
    if (n.semantics) |sem| {
        sem.value = s.value_buf[0..s.value_len];
        // The numeric range is in percent units, matching the "{d}%"
        // display string (see Semantics.value_range).
        sem.value_range = .{ .min = 0, .max = 100, .now = clampedValue(s) * 100 };
    }
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the value changed
}

fn sliderDeinit(n: *Node) void {
    const s = stateOf(n);
    if (ui.anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel)); // the update cb points at this node
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = sliderSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

/// The region own-paint can touch: the bounds plus the 40dp state layer,
/// centered on the thumb — its cx runs [b.x + inset, b.x + inset + tw] with
/// tw = max(0, b.w - 2*inset) like the paint path, so the layer reaches
/// (state_layer_size/2 - inset) past the horizontal edges, and past the
/// vertical edges whenever the bounds are shorter than the layer (a
/// constrained slider). Culling and damage both consult it.
fn sliderPaintBounds(n: *Node) Rect {
    const s = stateOf(n);
    const b = n.bounds;
    const cy = b.y + b.h / 2;
    var top = @min(b.y, cy - state_layer_size / 2);
    // The value indicator floats above the bounds while pressed/dragging —
    // its top edge is gap + tail + pill above the thumb's top.
    const ls = s.opts.theme.type_scale.label_large;
    const bubble_top = b.y - indicator_gap - indicator_tail_h - (ls.line_height + indicator_v_pad * 2);
    top = @min(top, bubble_top);
    const bottom = @max(b.y + b.h, cy + state_layer_size / 2);
    // Horizontally the bubble can overhang the bounds at the track's ends.
    const bubble_half: f32 = 48 / 2 + 8; // widest "%" pill + tail margin
    const over = @max(state_layer_size / 2, bubble_half);
    return .{
        .x = b.x + inset - over,
        .y = top,
        .w = @max(0, b.w - inset * 2) + over * 2,
        .h = bottom - top,
    };
}

const slider_vtable = ui.node.VTable{
    .measure = sliderMeasure,
    .layout = null_layout,
    .paint = sliderPaint,
    .deinit = sliderDeinit,
    .on_pointer = sliderOnPointer,
    .on_key = sliderOnKey,
    .hit_bounds = sliderHitBounds,
    .paint_bounds = sliderPaintBounds,
};

fn null_layout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: bounds come from the parent
}

/// An M3E slider bound to `sig` (a value in 0..1). A down/drag sets the value
/// from the pointer x; the visual + semantic state follows the signal.
pub fn slider(allocator: std.mem.Allocator, sig: *ui.state.Signal(f32), on_changed: ?Callback, opts: SliderOptions) !*Node {
    const node = try Node.create(allocator, &slider_vtable);
    errdefer allocator.destroy(node); // no state yet
    const s = try allocator.create(SliderState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .sig = sig, .on_changed = on_changed };
    node.state = s;
    // the initial semantic value
    const str = std.fmt.bufPrint(&s.value_buf, "{d:.0}%", .{std.math.clamp(sig.peek(), 0, 1) * 100}) catch "";
    s.value_len = str.len;
    s.value_buf[s.value_len] = 0; // sentinel for the indicator's text
    ui.semantics.attach(node, .{
        .role = .slider,
        .label = opts.a11y_label,
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
        .value = s.value_buf[0..s.value_len],
        .value_range = .{ .min = 0, .max = 100, .now = std.math.clamp(sig.peek(), 0, 1) * 100 },
        .actions = ui.semantics.Actions.init(.{ .increment = true, .decrement = true }),
    });
    sig.subscribe(.{ .callback = .{ .fn_ptr = sliderSyncCb, .userdata = node } }); // visual + semantic updates on set
    return node;
}

// --- tests ---

fn changeCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "slider: measures default_width x 44; the hit target floors at 48 high" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "x" });
    defer b.deinit();
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(@as(f32, 160), m.w);
    try std.testing.expectEqual(thumb_h, m.h);
    b.layout(.{ .x = 0, .y = 0, .w = 160, .h = 44 });
    const hb = b.vtable.hit_bounds.?(b);
    try std.testing.expectEqual(@as(f32, 160), hb.w);
    try std.testing.expectEqual(theme_mod.light.platform.hit_target_min, hb.h); // 44 -> 48
    try std.testing.expectEqual(@as(f32, -2), hb.y); // (44-48)/2
}

test "slider: a down/drag sets the value from the pointer x (clamped)" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = changeCounterCb, .userdata = &count };
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, cb, .{ .a11y_label = "x" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 160, .h = 44 });
    const on_pointer = b.vtable.on_pointer.?;
    // down at the middle: (80-2)/156 = 0.5
    _ = on_pointer(b, .{ .phase = .down, .x = 80, .y = 22, .raw_x = 80, .raw_y = 22 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sig.peek(), 0.01);
    // drag to the left: (40-2)/156 ≈ 0.2436
    _ = on_pointer(b, .{ .phase = .move, .x = 40, .y = 22, .raw_x = 40, .raw_y = 22 });
    try std.testing.expectApproxEqAbs(@as(f32, 38.0 / 156.0), sig.peek(), 0.001);
    _ = on_pointer(b, .{ .phase = .up, .x = 40, .y = 22, .raw_x = 40, .raw_y = 22 });
    try std.testing.expectEqual(@as(u32, 2), count);
    // clamped at both ends
    _ = on_pointer(b, .{ .phase = .down, .x = 500, .y = 22 });
    try std.testing.expectEqual(@as(f32, 1), sig.peek());
    _ = on_pointer(b, .{ .phase = .down, .x = -50, .y = 22 });
    try std.testing.expectEqual(@as(f32, 0), sig.peek());
}

test "slider: gesture arbitration — a vertical drag is a scroll, not an edit" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "x" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 160, .h = 44 });
    const on_pointer = b.vtable.on_pointer.?;
    _ = on_pointer(b, .{ .phase = .down, .x = 80, .y = 22, .raw_x = 80, .raw_y = 22 });
    const v0 = sig.peek();
    // a vertical drag past the slop: the scroll wins (the move bubbles, the
    // value is frozen, the pressed feedback is dropped)
    try std.testing.expect(!on_pointer(b, .{ .phase = .move, .x = 80, .y = 45, .raw_x = 80, .raw_y = 45 }));
    try std.testing.expectEqual(v0, sig.peek());
    try std.testing.expect(!stateOf(b).pressed);
    try std.testing.expect(!on_pointer(b, .{ .phase = .move, .x = 80, .y = 60, .raw_x = 80, .raw_y = 60 }));
    try std.testing.expectEqual(v0, sig.peek());
    try std.testing.expect(!on_pointer(b, .{ .phase = .up, .x = 80, .y = 60, .raw_x = 80, .raw_y = 60 })); // bubbles
    // a horizontal drag edits the value and keeps the pressed feedback
    _ = on_pointer(b, .{ .phase = .down, .x = 80, .y = 22, .raw_x = 80, .raw_y = 22 });
    try std.testing.expect(on_pointer(b, .{ .phase = .move, .x = 100, .y = 22, .raw_x = 100, .raw_y = 22 }));
    try std.testing.expect(stateOf(b).pressed);
    try std.testing.expect(stateOf(b).dragging);
    try std.testing.expect(sig.peek() > v0);
    try std.testing.expect(on_pointer(b, .{ .phase = .up, .x = 100, .y = 22, .raw_x = 100, .raw_y = 22 }));
    try std.testing.expect(!stateOf(b).pressed);
}

test "slider: arrows adjust the value (keyboard)" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "x" });
    defer b.deinit();
    const on_key = b.vtable.on_key.?;
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .right }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.51), sig.peek(), 0.001); // upstream: range/100 continuous
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .left }));
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .left }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.49), sig.peek(), 0.001);
    try std.testing.expect(!on_key(b, .{ .kind = .key_down, .key = .enter }));
}

test "slider: semantics — role slider, value sync, increment/decrement actions" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "Volume" });
    defer b.deinit();
    try std.testing.expectEqual(ui.semantics.Role.slider, b.semantics.?.role);
    try std.testing.expectEqualStrings("50%", b.semantics.?.value);
    try std.testing.expectEqualStrings("Volume", b.semantics.?.label);
    try std.testing.expect(b.semantics.?.actions.contains(.increment));
    try std.testing.expect(b.semantics.?.actions.contains(.decrement));
    sig.set(0.25);
    try std.testing.expectEqualStrings("25%", b.semantics.?.value); // follows the signal
    const dis = try slider(std.testing.allocator, sig, null, .{ .enabled = false, .a11y_label = "x" });
    defer dis.deinit();
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
}

test "golden: slider paints the active/inactive track + the thumb at the value" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 160, 48);
    defer r.deinit();
    b.layout(.{ .x = 0, .y = 2, .w = 160, .h = 44 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // active track (0 → 50%): primary — mid-track height (y = 2+14..2+30)
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(40, 24));
    // inactive track (50% → 100%): secondary_container
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(120, 24));
    // the thumb (4x44 at x = 2 + 78 - 2 = 78): primary, above the track
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(80, 4));
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(80, 42));
}

test "slider: steps snap the pointer value to the nearest tick" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "x", .steps = 3 });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 200, .h = 44 });
    const on_pointer = b.vtable.on_pointer.?;
    // x=60 on the track [2, 198] → fraction ~0.296 → snaps to the 0.25 tick
    _ = on_pointer(b, .{ .phase = .down, .x = 60, .y = 22, .raw_x = 60, .raw_y = 22 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), sig.peek(), 0.001);
    _ = on_pointer(b, .{ .phase = .up, .x = 60, .y = 22, .raw_x = 60, .raw_y = 22 });
    // continuous mode (steps = 0) keeps the pointer fraction
    const sig2 = try ui.state.Signal(f32).init(std.testing.allocator, 0);
    defer sig2.deinit();
    const b2 = try slider(std.testing.allocator, sig2, null, .{ .a11y_label = "x" });
    defer b2.deinit();
    b2.layout(.{ .x = 0, .y = 0, .w = 200, .h = 44 });
    _ = b2.vtable.on_pointer.?(b2, .{ .phase = .down, .x = 60, .y = 22, .raw_x = 60, .raw_y = 22 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.296), sig2.peek(), 0.001);
}

test "slider: arrows step by 1/(steps+1) in discrete mode" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "x", .steps = 3 });
    defer b.deinit();
    const on_key = b.vtable.on_key.?;
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .right }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), sig.peek(), 0.001);
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .right }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sig.peek(), 0.001);
}

test "golden: slider steps paint the stop ticks with the contrast inversion" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "x", .steps = 3, .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 160, 48);
    defer r.deinit();
    b.layout(.{ .x = 0, .y = 2, .w = 160, .h = 44 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // steps=3 → ticks at f ∈ {0, .25, .5, .75, 1} minus the end stop. With
    // v=.5 the handle sits on the mid tick; the corner-inset mapping puts
    // the remaining ticks at x = 2 + 8 + 140·f → screen x 10 / 45 / 115.
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(10, 24)); // on the active track → inactive color
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(45, 24));
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(115, 24)); // on the inactive track → active color
}

test "golden: pressed slider paints the value indicator bubble above the track" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 160, 130);
    defer r.deinit();
    b.layout(.{ .x = 0, .y = 60, .w = 160, .h = 44 });
    // not pressed → no bubble (white above the bounds)
    r.paint(b, 0xFFFFFFFF);
    var f0 = try r.readback(std.testing.allocator);
    defer f0.deinit();
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), f0.pixelAt(80, 30));
    // pressed → the InverseSurface pill 12dp above the bounds
    _ = b.vtable.on_pointer.?(b, .{ .phase = .down, .x = 80, .y = 82, .raw_x = 80, .raw_y = 82 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // inside the pill's left padding — (80, 30) lands on the label glyphs
    try std.testing.expectEqual(t.colors.inverse_surface, f.pixelAt(60, 30));
    try std.testing.expectEqual(t.colors.inverse_surface, f.pixelAt(80, 50)); // tail tip
    // released → gone again
    _ = b.vtable.on_pointer.?(b, .{ .phase = .up, .x = 80, .y = 82, .raw_x = 80, .raw_y = 82 });
    r.paint(b, 0xFFFFFFFF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), f2.pixelAt(80, 30));
}

test "golden: slider hover paints the state layer over the inactive track" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 160, 48);
    defer r.deinit();
    b.layout(.{ .x = 0, .y = 2, .w = 160, .h = 44 });
    _ = b.vtable.on_pointer.?(b, .{ .phase = .enter, .x = 80, .y = 24 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the 40dp state layer circle centered on the thumb (80, 24): 15px right
    // of the thumb center, over the inactive track → primary @ 0.08 blended
    try std.testing.expectEqual(
        theme_mod.stateLayer(t.colors.secondary_container, t.colors.primary, t.state.hover),
        f.pixelAt(95, 24),
    );
}

test "golden: disabled slider paints the OnSurface@0.38 active track" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .enabled = false, .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 160, 48);
    defer r.deinit();
    b.layout(.{ .x = 0, .y = 2, .w = 160, .h = 44 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the active track (OnSurface@0.38) is its own segment — no inactive
    // track beneath the gap-split layout, so it blends straight onto white
    try golden.expectPixelApprox(f, 40, 24, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), 0xFFFFFFFF));
}

test "slider: paintBounds covers the thumb state layer at the track ends" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{});
    defer b.deinit();
    b.layout(.{ .x = 100, .y = 50, .w = 200, .h = 44 });
    // overhang: max(layer 40, bubble 64)/2 horizontally; the indicator's
    // bubble also reaches 12+6+32 above the top edge → y = 0
    try std.testing.expectEqual(ui.node.Rect{ .x = 70, .y = 0, .w = 260, .h = 94 }, b.paintRect());
    // a constrained height still covers the layer (cy ± 20)
    b.layout(.{ .x = 100, .y = 50, .w = 200, .h = 16 });
    try std.testing.expectEqual(ui.node.Rect{ .x = 70, .y = 0, .w = 260, .h = 78 }, b.paintRect());
}
