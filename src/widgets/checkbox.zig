// Checkbox (Phase 2d.2 PR B2, M3E) — the M3E checkbox (with the error
// variant).
//
// Ported from .ref/material3/Checkbox.kt (verbatim behavior):
//   - CheckboxImpl (the isCheckboxStylingFixEnabled / M3E path — 18dp
//     CheckboxTokens.ContainerSize box, no legacy 2dp CheckboxDefaultPadding):
//     drawBox + drawCheck + the checkDrawFraction /
//     checkCenterGravitationShiftFraction transition specs +
//     colorAnimationSpecForState + defaultCheckboxColors
//   - drawBox: box == border → fill the 18x18 r2 box; else a 14x14 inner fill
//     (inset by the 2dp stroke) + a centered 2dp rrect ring inset 1dp (the
//     ring's outer edge is flush with the box bounds, inner corner square)
//   - drawCheck + CheckDrawingCache: the check is a 3-point polyline at
//     (0.25,0.5) → (0.4,0.65) → (0.75,0.3) of the box, drawn to
//     pathMeasure.length * checkFraction (the draw-on animation); the stroke
//     is floor(2dp) = 2px, StrokeCap.Square (kx polyline butt — square extends
//     the caps by half the stroke, a 1px cosmetic delta)
//   - checkDrawFraction: Off→On springs with MotionSchemeKeyTokens.
//     DefaultSpatial (the theme spatial spring); →Off is a snap() with a
//     100ms SnapAnimationDelay — modeled as a 0ms tween on a 100ms delay
//     (headless: snaps). The checkCenterGravitationShiftFraction only moves
//     for the Indeterminate state — this widget is binary (the public API is
//     Signal(bool)); the gravitation term stays 0.
//   - box/border/checkmark colors animate with colorAnimationSpecForState
//     (DefaultEffects entering, FastEffects leaving — both map to the theme
//     effects spring); disabled colors snap (rememberUpdatedState).
//   - indication (Checkbox.kt:553-560): the triStateToggleable carries
//     `ripple(bounded = false, radius = CheckboxTokens.StateLayerSize / 2,
//     color = rippleColor, focusRingShape = RoundedCornerShape(25))` —
//     StateLayerSize = 40dp → an unbounded 20dp-radius ink disc centered on
//     the box (the indication's own bounds), drawn OVER the canvas like
//     upstream's draw modifier. Interactions run through the shared
//     machinery: Tracker (press/hover/focus ordering), StateLayer (the
//     animated 40dp hover/focus layer — presses go to the ripple, never
//     the layer), Ripples (75ms fade-in / 225ms expand / 150ms fade-out).
//     The ink is rippleColor = colors.indicatorColor(state) (Checkbox.kt
//     :510-512): checked → the box color (Primary / Error). Unchecked:
//     upstream's flag-on path passes uncheckedBoxColor (Transparent) — an
//     upstream quirk that would drop the layer entirely; the spec table's
//     unselected layer is On Surface, which is also what the flag-off
//     Unspecified ripple resolves to (contentColor) — used here.
//     Enter/Space emits Press+Release → a centered unbounded ripple.
//   - the unselected border uses the Unselected*{Hover,Focus,Pressed}
//     OutlineColor tokens (all OnSurface — the style system resolves them;
//     defaultCheckboxColors itself is interaction-static)
//   - hit target: 48x48 centered on the box (minimumInteractiveComponentSize —
//     the a11y floor is the hit area, never the painted box)
//
// Remaining deviations (public-API-bound or upstream-quirk):
//   - no indeterminate state (the API is binary)
//   - disabled colors are straight-alpha (upstream composites over surface)
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

/// M3E measurement tokens (CheckboxTokens + Checkbox.kt).
const box_size: f32 = 18;
const box_radius: f32 = 2;
const outline_width: f32 = 2;
const check_stroke: f32 = 2;
const state_layer_size: f32 = 40;
// Compose minimumInteractiveComponentSize (the a11y hit-target floor) =
// theme.platform.hit_target_min — read from s.opts.theme where used.

pub const CheckboxOptions = struct {
    enabled: bool = true,
    /// The error variant (Error container / outline).
    @"error": bool = false,
    /// The accessible name (a checkbox is usually paired with a visible label
    /// built by the app; this is the control's own name).
    a11y_label: []const u8 = "",
    theme: Theme = theme_mod.light,
};

/// CheckDrawingCache's path geometry (Checkbox.kt). Fractions of the box.
/// `gravit` is checkCenterGravitationShiftFraction — only nonzero for the
/// Indeterminate state (out of scope for the binary API); kept in the math
/// so the port matches the upstream function shape.
const CheckPoint = struct { x: f32, y: f32 };
// flag-on (M3E) point fractions: (0.25,0.5) → (0.4,0.65) → (0.75,0.3)
const check_left: CheckPoint = .{ .x = 0.25, .y = 0.5 };
const check_cross: CheckPoint = .{ .x = 0.4, .y = 0.65 };
const check_right: CheckPoint = .{ .x = 0.75, .y = 0.3 };

const CheckboxState = struct {
    opts: CheckboxOptions,
    sig: *ui.state.Signal(bool),
    on_changed: ?Callback = null,
    /// The upstream interaction machinery (interactions.zig): ordered
    /// press/hover/focus entries — the tracker damages the node on every
    /// mutation (the manual markDirty on press/hover is gone).
    inter: ui.interactions.Tracker = .{},
    /// The animated interaction-state overlay (the 40dp disc's alpha —
    /// hover/focus only; presses go to the ripple).
    layer: ui.state_layer.StateLayer = .{},
    /// The unbounded 20dp-radius ripple set (CommonRipple's ripples map).
    ripples: ui.ripple.Ripples = .{},
    /// The live press's interaction id (0 = none) — pairs tracker.release
    /// and ripples.release.
    press_id: u32 = 0,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — see PointerEvent.raw_x/raw_y).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
    /// checkDrawFraction: 0 unchecked … 1 fully drawn (drawn-on animation).
    check_frac: f32 = 0,
    /// The animated box / border / checkmark colors.
    box_color: Color = 0,
    border_color: Color = 0,
    check_color: Color = 0,
    /// Animation channel markers (stable addresses).
    frac_channel: u8 = 0,
    box_channel: u8 = 0,
    border_channel: u8 = 0,
    check_channel: u8 = 0,
};

fn stateOf(n: *Node) *CheckboxState {
    return @ptrCast(@alignCast(n.state.?));
}

fn isChecked(s: *CheckboxState) bool {
    return s.sig.peek();
}

/// The target colors for the current state — defaultCheckboxColors
/// (Checkbox.kt: CheckedContainerColor Selected → Primary/Error, Transparent
/// unselected; CheckedBorderColor == container; UnselectedBorderColor →
/// Unselected*OutlineColor tokens — OnSurfaceVariant at rest, OnSurface
/// interacting, Error in the error variant; SelectedIconColor OnPrimary/
/// OnError; disabled → OnSurface@0.38 box, OnSurface@0.38 border, Surface
/// checkmark).
const CBColors = struct { box: Color, outline: Color, check: Color, indicator: Color };

fn currentColors(s: *CheckboxState) CBColors {
    const cs = s.opts.theme.colors;
    const err = s.opts.@"error";
    if (!s.opts.enabled) {
        if (isChecked(s)) {
            return .{
                .box = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
                .outline = ui.paint.withAlphaScaled(cs.on_surface, 0.38), // CheckedBorderColor == container
                .check = cs.surface,
                .indicator = 0x00000000,
            };
        }
        return .{
            .box = 0x00000000,
            .outline = ui.paint.withAlphaScaled(cs.on_surface, 0.38), // UnselectedDisabledOutlineColor
            .check = 0x00000000,
            .indicator = 0x00000000,
        };
    }
    // the Unselected{Hover,Focus,Pressed}OutlineColor tokens — all OnSurface
    // (defaultCheckboxColors itself is interaction-static; the style system
    // resolves these)
    const interacting = s.inter.len > 0;
    if (isChecked(s)) {
        const c = if (err) cs.@"error" else cs.primary;
        return .{ .box = c, .outline = c, .check = if (err) cs.on_error else cs.on_primary, .indicator = c };
    }
    const outline = if (interacting or err) (if (err) cs.@"error" else cs.on_surface) else cs.on_surface_variant;
    // the spec's unselected state layer is On Surface (upstream's flag-on
    // ripple would pass the Transparent uncheckedBoxColor — the flag-off
    // Unspecified ripple resolves to ≈OnSurface via contentColor, so
    // OnSurface is the spec color either way)
    const indicator = if (err) cs.@"error" else cs.on_surface;
    return .{ .box = 0x00000000, .outline = outline, .check = 0x00000000, .indicator = indicator };
}

fn checkboxMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = box_size, .h = box_size });
}

/// The interactive target: hit_target_min x hit_target_min centered on the
/// box (48x48 under the mobile theme).
fn checkboxHitBounds(n: *Node) Rect {
    const s = stateOf(n);
    const b = n.bounds;
    const min_target = s.opts.theme.platform.hit_target_min;
    return .{
        .x = b.x + (b.w - min_target) / 2,
        .y = b.y + (b.h - min_target) / 2,
        .w = min_target,
        .h = min_target,
    };
}

fn lerpF(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// DrawScope.drawBox (Checkbox.kt): box == border → fill the whole r2 box;
/// otherwise a 14x14 inner fill inset by the stroke (square corners —
/// max(0, radius - stroke)) under a 2dp ring inset by half the stroke
/// (corner radius 1). `stroke.width` = floor(StrokeWidth) = 2.
fn drawBox(ctx: *kx.Ctx, x: f32, y: f32, size: f32, box_color: Color, border_color: Color) void {
    if (box_color == border_color) {
        ui.paint.fillRRect(ctx, x, y, size, size, box_radius, box_color);
    } else {
        ui.paint.fillRRect(ctx, x + outline_width, y + outline_width, size - outline_width * 2, size - outline_width * 2, 0, box_color);
        const half = outline_width / 2;
        ui.paint.strokeRRect(ctx, x + half, y + half, size - outline_width, size - outline_width, box_radius - half, outline_width, border_color);
    }
}

/// DrawScope.drawCheck (Checkbox.kt): the check is a 3-point polyline drawn
/// to `pathMeasure.length * checkFraction`. Gravitated fractions —
/// crossX/crossY/end-Y lerp toward 0.5 as crossCenterGravitation → 1 (the
/// indeterminate morph; 0 for this binary widget). The stroke is
/// floor(2dp) = 2px, StrokeCap.Square upstream — the kx polyline's flat cap
/// is the closest available primitive (the square cap extends endpoints by
/// half the stroke: a sub-pixel cosmetic delta).
fn drawCheck(ctx: *kx.Ctx, x: f32, y: f32, size: f32, check_color: Color, check_frac: f32, gravit: f32) void {
    if (check_frac <= 0) return;
    const p0 = CheckPoint{ .x = check_left.x * size, .y = lerpF(check_left.y, 0.5, gravit) * size };
    const p1 = CheckPoint{ .x = lerpF(check_cross.x, 0.5, gravit) * size, .y = lerpF(check_cross.y, 0.5, gravit) * size };
    const p2 = CheckPoint{ .x = check_right.x * size, .y = lerpF(check_right.y, 0.5, gravit) * size };
    const l1 = @sqrt((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y));
    const l2 = @sqrt((p2.x - p1.x) * (p2.x - p1.x) + (p2.y - p1.y) * (p2.y - p1.y));
    const d = (l1 + l2) * check_frac; // getSegment(0, length * fraction)
    var xs: [3]f32 = undefined;
    var ys: [3]f32 = undefined;
    var count: usize = 2;
    xs[0] = x + p0.x;
    ys[0] = y + p0.y;
    if (d <= l1) {
        // a partial first segment: lerp from p0 toward p1
        const t = if (l1 > 0) d / l1 else 0;
        xs[1] = x + p0.x + (p1.x - p0.x) * t;
        ys[1] = y + p0.y + (p1.y - p0.y) * t;
    } else {
        xs[1] = x + p1.x;
        ys[1] = y + p1.y;
        if (d < l1 + l2) {
            const t = (d - l1) / l2;
            xs[2] = x + p1.x + (p2.x - p1.x) * t;
            ys[2] = y + p1.y + (p2.y - p1.y) * t;
            count = 3;
        } else {
            xs[2] = x + p2.x;
            ys[2] = y + p2.y;
            count = 3;
        }
    }
    ui.paint.strokePolyline(ctx, xs[0..count], ys[0..count], check_stroke, false, check_color);
}

fn checkboxPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const cc = currentColors(s);
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    // The signal-animated colors apply to the check-state transition; the
    // unselected outline's interaction variants (the *Hover/*Focus/*Pressed
    // tokens) resolve instantly like the rest of the interaction-state
    // painting (upstream's default colors are interaction-static — the
    // variants come from the style system and apply per-state).
    const border = if (s.opts.enabled and !isChecked(s)) cc.outline else s.border_color;
    // the box — the animated colors decide which drawBox branch runs
    drawBox(ctx, b.x, b.y, b.w, s.box_color, border);
    // the checkmark draws through checkDrawFraction (drawn on/off)
    drawCheck(ctx, b.x, b.y, b.w, s.check_color, s.check_frac, 0);
    // The indication draws over the canvas like upstream's draw modifier
    // (the triStateToggleable wraps the Canvas). Focus has no widget
    // callback — poll the router and let the tracker derive the target.
    if (s.opts.enabled) {
        s.inter.setFocused(input.isFocused(n));
        s.layer.sync(&s.inter, cc.indicator);
        // the animated state layer: the same 40dp disc centered on the box
        if (s.layer.paintColor()) |c| {
            ui.paint.fillRRect(ctx, cx - state_layer_size / 2, cy - state_layer_size / 2, state_layer_size, state_layer_size, state_layer_size / 2, c);
        }
        // the unbounded ink (radius 20dp, centered on the box — the
        // indication's bounds are the canvas's)
        s.ripples.color = cc.indicator;
        s.ripples.paint(ctx, n, .none);
    }
}

fn checkboxOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    switch (ev.phase) {
        .down => {
            s.press_id = s.inter.pressDown(ev.x, ev.y);
            s.ripples.spawn(s.press_id, ev.x, ev.y, ev.time_ms);
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            return true;
        },
        .up => {
            const was_pressed = s.press_id != 0;
            s.inter.release(s.press_id);
            s.ripples.release(s.press_id, ev.time_ms);
            s.press_id = 0;
            // the click lands in the 48dp hit target, not necessarily in the
            // 18dp box (the a11y floor is the interactive area)
            if (was_pressed and checkboxHitBounds(n).contains(ev.x, ev.y)) {
                s.sig.set(!s.sig.peek());
                if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            }
            return true;
        },
        .move => {
            // a drag past the touch slop cancels the press (a scroll); the
            // move is NOT claimed so it keeps bubbling to scrollables
            if (s.press_id != 0) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.inter.cancel(s.press_id);
                    s.ripples.release(s.press_id, ev.time_ms);
                    s.press_id = 0;
                }
            }
            return false;
        },
        .outside_down => {
            s.inter.cancel(s.press_id);
            s.ripples.release(s.press_id, ev.time_ms);
            s.press_id = 0;
            return true;
        },
        .enter => {
            _ = s.inter.hoverEnter();
            return true;
        },
        .leave => {
            s.inter.endHover();
            return true;
        },
        else => {},
    }
    return false;
}

/// Keyboard activation (Phase 2c): Enter/Space toggle the focused checkbox.
/// Upstream's toggleable emits Press → Release for a key activation, so the
/// centered unbounded ripple spawns + releases (the indication's bounds are
/// the box — unbounded spawn is centered regardless of x/y).
fn checkboxOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            const b = n.bounds;
            const pid = s.inter.pressDown(b.x + b.w / 2, b.y + b.h / 2);
            s.ripples.spawn(pid, b.x + b.w / 2, b.y + b.h / 2, 0);
            s.inter.release(pid);
            s.ripples.release(pid, 0);
            s.sig.set(!s.sig.peek());
            if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        else => {},
    }
    return false;
}

/// animateColorAsState(colorAnimationSpecForState): Off → FastEffects, else
/// DefaultEffects. Both motion tokens map to the theme effects spring; the
/// lanes are the color's RGBA (lerpColor semantics). Disabled → snap
/// (rememberUpdatedState — no animation across enabled/disabled).
fn animateColor(s: *CheckboxState, current: Color, target: Color, channel: *anyopaque, cb: ui.anim.Animation.UpdateCallback) Color {
    if (ui.anim.timeline()) |tl| {
        const from = ui.anim.colorToVec4(current);
        const to = ui.anim.colorToVec4(target);
        _ = tl.play(.{
            .kind = ui.anim.Animation.springAnim(from, to, s.opts.theme.motion.springs.effects_spring, .{ 0, 0, 0, 0 }),
            .from = from,
            .channel = channel,
            .on_update = cb,
        });
        return current;
    }
    return target;
}

fn boxColorCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).box_color = ui.anim.vec4ToColor(v);
    n.markDirty();
}
fn borderColorCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).border_color = ui.anim.vec4ToColor(v);
    n.markDirty();
}
fn checkColorCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).check_color = ui.anim.vec4ToColor(v);
    n.markDirty();
}
fn checkFracCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).check_frac = v[0];
    n.markDirty();
}

/// The checkbox transition specs (Checkbox.kt): Off→On springs the check on
/// with DefaultSpatial (the theme spatial spring); →Off is snap(100ms) — the
/// check lingers while the box fades, then vanishes. No timeline → snap.
fn animateCheckFrac(n: *Node, s: *CheckboxState, checked: bool) void {
    const target: f32 = if (checked) 1 else 0;
    if (ui.anim.timeline()) |tl| {
        const from: ui.anim.Vec4 = .{ s.check_frac, 0, 0, 0 };
        if (checked) {
            _ = tl.play(.{
                .kind = ui.anim.Animation.springAnim(from, .{ 1, 0, 0, 0 }, s.opts.theme.motion.springs.spatial_spring, .{ 0, 0, 0, 0 }),
                .from = from,
                .channel = @ptrCast(&s.frac_channel),
                .on_update = .{ .fn_ptr = checkFracCb, .userdata = n },
            });
        } else {
            _ = tl.play(.{
                .kind = ui.anim.Animation.tweenAnim(.{ 0, 0, 0, 0 }, 0, .{ .ease = .linear }),
                .from = from,
                .delay_ms = 100, // SnapAnimationDelay
                .channel = @ptrCast(&s.frac_channel),
                .on_update = .{ .fn_ptr = checkFracCb, .userdata = n },
            });
        }
    } else {
        s.check_frac = target;
    }
}

/// Signal-driven repaint + semantic checked sync + the upstream transitions
/// (checkDrawFraction + the three animated colors).
fn checkboxSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const checked = s.sig.peek();
    if (n.semantics) |sem| sem.checked = checked;
    const cc = currentColors(s);
    if (s.opts.enabled) {
        s.box_color = animateColor(s, s.box_color, cc.box, @ptrCast(&s.box_channel), .{ .fn_ptr = boxColorCb, .userdata = n });
        s.border_color = animateColor(s, s.border_color, cc.outline, @ptrCast(&s.border_channel), .{ .fn_ptr = borderColorCb, .userdata = n });
        s.check_color = animateColor(s, s.check_color, cc.check, @ptrCast(&s.check_channel), .{ .fn_ptr = checkColorCb, .userdata = n });
        animateCheckFrac(n, s, checked);
    } else {
        s.box_color = cc.box;
        s.border_color = cc.outline;
        s.check_color = cc.check;
        s.check_frac = if (checked) 1 else 0;
        if (ui.anim.timeline()) |tl| {
            tl.cancelChannel(@ptrCast(&s.frac_channel));
            tl.cancelChannel(@ptrCast(&s.box_channel));
            tl.cancelChannel(@ptrCast(&s.border_channel));
            tl.cancelChannel(@ptrCast(&s.check_channel));
        }
    }
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the value changed
}

fn checkboxDeinit(n: *Node) void {
    const s = stateOf(n);
    // the ripple ticker's userdata is `s.ripples` — unregister before the
    // state is freed; the layer's tween channel likewise.
    s.ripples.deinit();
    s.layer.deinit();
    if (ui.anim.timeline()) |tl| {
        tl.cancelChannel(@ptrCast(&s.frac_channel));
        tl.cancelChannel(@ptrCast(&s.box_channel));
        tl.cancelChannel(@ptrCast(&s.border_channel));
        tl.cancelChannel(@ptrCast(&s.check_channel));
    }
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = checkboxSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const checkbox_vtable = ui.node.VTable{
    .measure = checkboxMeasure,
    .layout = null_layout,
    .paint = checkboxPaint,
    .deinit = checkboxDeinit,
    .on_pointer = checkboxOnPointer,
    .on_key = checkboxOnKey,
    .hit_bounds = checkboxHitBounds,
};

fn null_layout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: bounds come from the parent
}

/// An M3E checkbox bound to `sig` (a click or Enter/Space flips it; the
/// visual + semantic state follows the signal).
pub fn checkbox(allocator: std.mem.Allocator, sig: *ui.state.Signal(bool), on_changed: ?Callback, opts: CheckboxOptions) !*Node {
    const node = try Node.create(allocator, &checkbox_vtable);
    errdefer allocator.destroy(node); // no state yet
    const s = try allocator.create(CheckboxState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .sig = sig, .on_changed = on_changed };
    node.state = s;
    // seed the animated state at the current values (upstream's
    // remember/animateColorAsState starts at the target — no intro animation)
    const cc = currentColors(s);
    s.box_color = cc.box;
    s.border_color = cc.outline;
    s.check_color = cc.check;
    s.check_frac = if (sig.peek()) 1 else 0;
    // the interaction machinery: the tracker + the tweened state layer
    // (alphas from the theme state table) + the unbounded 20dp-radius ink
    s.inter.node = node;
    s.layer.node = node;
    s.layer.alphas = .{ .hover = opts.theme.state.hover, .focus = opts.theme.state.focus, .pressed = opts.theme.state.pressed, .drag = opts.theme.state.drag };
    s.ripples = .{ .bounded = false, .radius = state_layer_size / 2, .node = node, .pressed_alpha = opts.theme.state.pressed };
    // the layer disc and the ripple ink reach radius+~1px past the box
    // center on every side — the same 11dp the static layer needed
    node.damage_overflow = ui.ripple.overflowFor(box_size, box_size, state_layer_size / 2);
    ui.semantics.attach(node, .{
        .role = .checkbox,
        .label = opts.a11y_label,
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
        .checked = sig.peek(),
        .actions = ui.semantics.Actions.initOne(.activate),
    });
    sig.subscribe(.{ .callback = .{ .fn_ptr = checkboxSyncCb, .userdata = node } }); // visual + semantic updates on set
    return node;
}

// --- tests ---

test "checkbox: measures the 18dp box; the 48dp floor is the hit target" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try checkbox(std.testing.allocator, sig, null, .{ .a11y_label = "x" });
    defer b.deinit();
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(box_size, m.w);
    try std.testing.expectEqual(box_size, m.h);
    b.layout(.{ .x = 100, .y = 100, .w = 18, .h = 18 });
    const hb = b.vtable.hit_bounds.?(b);
    const min_target = theme_mod.light.platform.hit_target_min;
    try std.testing.expectEqual(min_target, hb.w);
    try std.testing.expectEqual(min_target, hb.h);
    try std.testing.expectEqual(@as(f32, 100 - 15), hb.x); // (18-48)/2
    try std.testing.expectEqual(@as(f32, 100 - 15), hb.y);
}

test "checkbox: click and Enter/Space toggle the signal + fire the callback" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = struct {
        fn f(ud: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ud.?));
            c.* += 1;
        }
    }.f, .userdata = &count };
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try checkbox(std.testing.allocator, sig, cb, .{ .a11y_label = "x" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 18, .h = 18 });
    const on_pointer = b.vtable.on_pointer.?;
    // a drag past the slop cancels (a scroll, not a click)
    _ = on_pointer(b, .{ .phase = .down, .x = 9, .y = 9, .raw_x = 9, .raw_y = 9 });
    _ = on_pointer(b, .{ .phase = .move, .x = 9, .y = 30, .raw_x = 9, .raw_y = 30 });
    _ = on_pointer(b, .{ .phase = .up, .x = 9, .y = 9, .raw_x = 9, .raw_y = 9 });
    try std.testing.expect(!sig.peek());
    try std.testing.expectEqual(@as(u32, 0), count);
    // a plain click toggles — inside the 48dp hit target (the box is 18dp at
    // the origin, the hit target is centered on it: [-15, 33))
    _ = on_pointer(b, .{ .phase = .down, .x = 9, .y = 9, .raw_x = 9, .raw_y = 9 });
    _ = on_pointer(b, .{ .phase = .up, .x = 9, .y = 9, .raw_x = 9, .raw_y = 9 });
    try std.testing.expect(sig.peek());
    try std.testing.expectEqual(@as(u32, 1), count);
    _ = on_pointer(b, .{ .phase = .down, .x = 30, .y = 30, .raw_x = 30, .raw_y = 30 });
    _ = on_pointer(b, .{ .phase = .up, .x = 30, .y = 30, .raw_x = 30, .raw_y = 30 });
    try std.testing.expect(!sig.peek()); // toggled from the hit margin
    try std.testing.expectEqual(@as(u32, 2), count);
    _ = on_pointer(b, .{ .phase = .down, .x = 9, .y = 9, .raw_x = 9, .raw_y = 9 });
    _ = on_pointer(b, .{ .phase = .up, .x = 9, .y = 9, .raw_x = 9, .raw_y = 9 });
    try std.testing.expect(sig.peek());
    try std.testing.expectEqual(@as(u32, 3), count);
    // keyboard
    const on_key = b.vtable.on_key.?;
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .space }));
    try std.testing.expect(!sig.peek());
    try std.testing.expectEqual(@as(u32, 4), count);
    try std.testing.expect(!on_key(b, .{ .kind = .key_down, .key = .left }));
}

test "checkbox: semantics — role checkbox, checked sync, disabled" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const b = try checkbox(std.testing.allocator, sig, null, .{ .a11y_label = "Accept" });
    defer b.deinit();
    try std.testing.expectEqual(ui.semantics.Role.checkbox, b.semantics.?.role);
    try std.testing.expectEqual(true, b.semantics.?.checked);
    try std.testing.expectEqualStrings("Accept", b.semantics.?.label);
    sig.set(false);
    try std.testing.expectEqual(false, b.semantics.?.checked); // follows the signal
    const dis = try checkbox(std.testing.allocator, sig, null, .{ .enabled = false, .a11y_label = "x" });
    defer dis.deinit();
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
}

test "golden: checked checkbox paints the primary box + the checkmark ink" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const b = try checkbox(std.testing.allocator, sig, null, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 48, 48);
    defer r.deinit();
    b.layout(.{ .x = 15, .y = 15, .w = 18, .h = 18 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // inside the box, off the checkmark ink: primary
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(17, 17));
    // the checkmark stroke is on_primary ink somewhere along the check path
    try std.testing.expect(f.countColorIn(.{ .x = 15, .y = 15, .w = 18, .h = 18 }, t.colors.on_primary) > 0);
    // outside the box + the 40dp state layer (idle: none): bg
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(2, 2));
}

test "golden: unchecked checkbox strokes the OnSurfaceVariant outline, transparent inside" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try checkbox(std.testing.allocator, sig, null, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 48, 48);
    defer r.deinit();
    // half-pixel offset: the 2dp outline is centered on the edge
    b.layout(.{ .x = 15.5, .y = 15.5, .w = 18, .h = 18 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the top outline, mid-edge: on_surface_variant — the ported drawBox
    // insets the ring by half the stroke so its outer edge is flush with the
    // box edge; the solid stroke band is y∈[15.5,17.5] → sample row 16
    try std.testing.expectEqual(t.colors.on_surface_variant, f.pixelAt(24, 16));
    // inside: transparent → bg
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(24, 24));
}

test "golden: disabled checked checkbox paints the OnSurface@0.38 box" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const b = try checkbox(std.testing.allocator, sig, null, .{ .enabled = false, .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 48, 48);
    defer r.deinit();
    b.layout(.{ .x = 15, .y = 15, .w = 18, .h = 18 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try golden.expectPixelApprox(f, 17, 17, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), 0xFFFFFFFF));
}

test "checkbox: paintRect covers the 40dp state layer (culling/damage contract)" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try checkbox(std.testing.allocator, sig, null, .{});
    defer b.deinit();
    b.layout(.{ .x = 100, .y = 100, .w = 18, .h = 18 });
    // the layer is centered on the box: 40dp → 109±20 = 89..129
    try std.testing.expectEqual(ui.node.Rect{ .x = 89, .y = 89, .w = 40, .h = 40 }, b.paintRect());
}
