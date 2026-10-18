// RadioButton (Phase 2d.2 PR B2, M3E) — the M3E radio button. A radio group
// is a shared Signal(usize): each radio carries its `index`; checked =
// (signal == index); a click selects it.
//
// Ported from .ref/material3/RadioButton.kt (verbatim behavior):
//   - RadioButtonImpl: the Canvas is padding(RadioButtonPadding=2dp) +
//     requiredSize(IconSize=20dp) → the node measures 24x24 with the 20dp
//     drawing centered; the draw scope is the 20dp icon
//   - the ring: drawCircle(radius = IconSize/2 - strokeWidth/2 = 9,
//     Stroke(2)) → a 2dp stroke centered on the 9dp radius (outer Ø 20)
//   - the dot: animateDpAsState(RadioButtonDotSize/2 = 6dp when selected,
//     MotionSchemeKeyTokens.FastSpatial — the theme spatial spring); drawn
//     filled at radius dotRadius - strokeWidth/2 (= 5dp → Ø 10), skipped
//     while the animated radius is 0
//   - colors: radioColor(enabled, selected) — defaultRadioButtonColors:
//     SelectedIconColor = Primary, UnselectedIconColor = OnSurfaceVariant,
//     disabled both OnSurface@0.38 (Disabled*IconOpacity). Animated with
//     MotionSchemeKeyTokens.DefaultEffects (the theme effects spring);
//     disabled snaps (rememberUpdatedState). The Unselected{Hover,Focus,
//     Pressed}IconColor tokens (all OnSurface — the style system resolves
//     them; the default colors are interaction-static) apply like the spec
//     states table.
//   - indication (RadioButton.kt:163-166): the selectable carries
//     `ripple(bounded = false, radius = RadioButtonTokens.StateLayerSize /
//     2, focusRingShape = CircleShape)` — StateLayerSize = 40dp → an
//     unbounded 20dp-radius ink disc centered on the ring (no color arg →
//     the ripple theme's content color = the effective icon color here),
//     drawn OVER the canvas like upstream's draw modifier. Interactions
//     run through the shared machinery: Tracker (press/hover/focus
//     ordering), StateLayer (the animated 40dp hover/focus layer —
//     presses go to the ripple, never the layer), Ripples (75ms fade-in /
//     225ms expand / 150ms fade-out). Enter/Space emits Press+Release → a
//     centered unbounded ripple.
//   - hit target: 48x48 centered on the ring
//     (minimumInteractiveComponentSize — the a11y floor is the hit area,
//     never the painted circle)
//
// Remaining deviations (upstream-quirk / API-bound): none beyond the
//   interaction-variant note above — a re-tap mid-animation restarts the
//   spring from 0 velocity (velocity continuity isn't carried).
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
const Theme = theme_mod.Theme;

/// M3E measurement tokens (RadioButtonTokens + RadioButton.kt).
const icon_size: f32 = 20; // RadioButtonTokens.IconSize (the draw scope)
const padding: f32 = 2; // RadioButtonPadding — the node measures icon+2*pad
const circle_size: f32 = 24;
const circle_radius: f32 = 9; // IconSize/2 - strokeWidth/2 (the stroke is centered)
const stroke_width: f32 = 2;
const dot_radius: f32 = 6; // RadioButtonDotSize/2 (the animation target)
const state_layer_size: f32 = 40;
// Compose minimumInteractiveComponentSize (the a11y hit-target floor) =
// theme.platform.hit_target_min — read from s.opts.theme where used.

pub const RadioOptions = struct {
    enabled: bool = true,
    /// The accessible name (a radio is usually paired with a visible label
    /// built by the app; this is the control's own name).
    a11y_label: []const u8 = "",
    theme: Theme = theme_mod.light,
};

const RadioState = struct {
    opts: RadioOptions,
    sig: *ui.state.Signal(usize),
    index: u32,
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
    /// animateDpAsState(RadioButtonDotSize/2, FastSpatial): 0 … 6.
    dot_r: f32 = 0,
    /// animateColorAsState(DefaultEffects): the ring/dot color.
    circle_color: Color = 0,
    /// Animation channel markers (stable addresses).
    dot_channel: u8 = 0,
    color_channel: u8 = 0,
};

fn stateOf(n: *Node) *RadioState {
    return @ptrCast(@alignCast(n.state.?));
}

fn isChecked(s: *RadioState) bool {
    return s.sig.peek() == s.index;
}

/// The rest-state circle color (radioColor(enabled, selected) at the
/// resting interaction state) + the state layer's on-color.
const RColors = struct { circle: Color, on: Color };

fn currentColors(s: *RadioState) RColors {
    const cs = s.opts.theme.colors;
    if (!s.opts.enabled) return .{ .circle = ui.paint.withAlphaScaled(cs.on_surface, 0.38), .on = ui.paint.withAlphaScaled(cs.on_surface, 0.38) };
    // defaultRadioButtonColors is interaction-static (radioColor keys on
    // {enabled, selected}); the Unselected*IconColor tokens resolve only in
    // custom styles. The ink is the ripple's unspecified color → the
    // content color ≈ OnSurface in either selection state.
    if (isChecked(s)) return .{ .circle = cs.primary, .on = cs.on_surface };
    return .{ .circle = cs.on_surface_variant, .on = cs.on_surface };
}

fn radioMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    // padding(2dp) + requiredSize(IconSize) → 24x24, the icon centered
    return c.constrain(.{ .w = circle_size, .h = circle_size });
}

/// The interactive target: hit_target_min x hit_target_min centered on the
/// circle (48x48 under the mobile theme).
fn radioHitBounds(n: *Node) Rect {
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

fn radioPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const cc = currentColors(s);
    // the 20dp icon centers in the (24dp) node — wrapContentSize centers the
    // canvas in whatever space remains after the padding
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    // The signal-animated color carries the check-state transition; the
    // unselected icon's interaction variants (the *Hover/*Focus/*Pressed
    // tokens) resolve instantly like the other interaction-state painting
    // (defaultRadioButtonColors is interaction-static).
    const circle = if (s.opts.enabled and !isChecked(s)) cc.circle else s.circle_color;
    // the ring: drawCircle(radius=9, Stroke(2)) — the 2dp stroke centers on
    // the r=9 circle (the rrect path), so the ring's outer edge is the 20dp
    // icon edge
    ui.paint.strokeRRect(ctx, cx - circle_radius, cy - circle_radius, circle_radius * 2, circle_radius * 2, circle_radius, stroke_width, circle);
    // the dot: filled circle radius dotRadius - strokeWidth/2, only while the
    // animated radius is > 0
    if (s.dot_r > 0) {
        const dr = s.dot_r - stroke_width / 2;
        if (dr > 0) {
            ui.paint.fillRRect(ctx, cx - dr, cy - dr, dr * 2, dr * 2, dr, circle);
        }
    }
    // The indication draws over the canvas like upstream's draw modifier
    // (the selectable wraps the Canvas). Focus has no widget callback —
    // poll the router and let the tracker derive the layer target.
    if (s.opts.enabled) {
        s.inter.setFocused(input.isFocused(n));
        s.layer.sync(&s.inter, cc.on);
        // the animated state layer: the same 40dp disc centered on the ring
        if (s.layer.paintColor()) |c| {
            ui.paint.fillRRect(ctx, cx - state_layer_size / 2, cy - state_layer_size / 2, state_layer_size, state_layer_size, state_layer_size / 2, c);
        }
        // the unbounded ink (radius 20dp, centered on the ring)
        s.ripples.color = cc.on;
        s.ripples.paint(ctx, n, .none);
    }
}

fn radioOnPointer(n: *Node, ev: input.PointerEvent) bool {
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
            // 20dp circle (the a11y floor is the interactive area)
            if (was_pressed and radioHitBounds(n).contains(ev.x, ev.y)) {
                s.sig.set(s.index);
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

/// Keyboard activation (Phase 2c): Enter/Space select the focused radio.
/// Upstream's selectable emits Press → Release for a key activation, so
/// the centered unbounded ripple spawns + releases (unbounded spawn is
/// centered on the indication's bounds regardless of x/y).
fn radioOnKey(n: *Node, ev: input.KeyEvent) bool {
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
            s.sig.set(s.index);
            return true;
        },
        else => {},
    }
    return false;
}

fn dotRadiusCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).dot_r = v[0];
    n.markDirty();
}
fn circleColorCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).circle_color = ui.anim.vec4ToColor(v);
    n.markDirty();
}

/// Signal-driven repaint + semantic checked sync + the upstream
/// transitions: animateDpAsState(dotRadius, FastSpatial → the theme spatial
/// spring) for the dot; animateColorAsState(DefaultEffects → the theme
/// effects spring) for the ring/dot color (snapped when disabled —
/// rememberUpdatedState).
fn radioSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const checked = isChecked(s);
    if (n.semantics) |sem| sem.checked = checked;
    const cc = currentColors(s);
    const dot_target: f32 = if (checked) dot_radius else 0;
    if (s.opts.enabled) {
        if (ui.anim.timeline()) |tl| {
            const dfrom: ui.anim.Vec4 = .{ s.dot_r, 0, 0, 0 };
            _ = tl.play(.{
                .kind = ui.anim.Animation.springAnim(dfrom, .{ dot_target, 0, 0, 0 }, s.opts.theme.motion.springs.spatial_spring, .{ 0, 0, 0, 0 }),
                .from = dfrom,
                .channel = @ptrCast(&s.dot_channel),
                .on_update = .{ .fn_ptr = dotRadiusCb, .userdata = n },
            });
            const cfrom = ui.anim.colorToVec4(s.circle_color);
            _ = tl.play(.{
                .kind = ui.anim.Animation.springAnim(cfrom, ui.anim.colorToVec4(cc.circle), s.opts.theme.motion.springs.effects_spring, .{ 0, 0, 0, 0 }),
                .from = cfrom,
                .channel = @ptrCast(&s.color_channel),
                .on_update = .{ .fn_ptr = circleColorCb, .userdata = n },
            });
        } else {
            s.dot_r = dot_target;
            s.circle_color = cc.circle;
        }
    } else {
        s.dot_r = dot_target;
        s.circle_color = cc.circle;
        if (ui.anim.timeline()) |tl| {
            tl.cancelChannel(@ptrCast(&s.dot_channel));
            tl.cancelChannel(@ptrCast(&s.color_channel));
        }
    }
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the value changed
}

fn radioDeinit(n: *Node) void {
    const s = stateOf(n);
    // the ripple ticker's userdata is `s.ripples` — unregister before the
    // state is freed; the layer's tween channel likewise.
    s.ripples.deinit();
    s.layer.deinit();
    if (ui.anim.timeline()) |tl| {
        tl.cancelChannel(@ptrCast(&s.dot_channel));
        tl.cancelChannel(@ptrCast(&s.color_channel));
    }
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = radioSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const radio_vtable = ui.node.VTable{
    .measure = radioMeasure,
    .layout = null_layout,
    .paint = radioPaint,
    .deinit = radioDeinit,
    .on_pointer = radioOnPointer,
    .on_key = radioOnKey,
    .hit_bounds = radioHitBounds,
};

fn null_layout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: bounds come from the parent
}

/// An M3E radio button bound to the group's shared `sig` (a click or
/// Enter/Space selects it: `sig.set(index)`; the visual + semantic state
/// follows the signal).
pub fn radio(allocator: std.mem.Allocator, sig: *ui.state.Signal(usize), index: u32, opts: RadioOptions) !*Node {
    const node = try Node.create(allocator, &radio_vtable);
    errdefer allocator.destroy(node); // no state yet
    const s = try allocator.create(RadioState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .sig = sig, .index = index };
    node.state = s;
    // seed the animated state at the current values (upstream's
    // animate*AsState starts at the target — no intro animation)
    s.circle_color = currentColors(s).circle;
    s.dot_r = if (sig.peek() == index) dot_radius else 0;
    // the interaction machinery: the tracker + the tweened state layer
    // (alphas from the theme state table) + the unbounded 20dp-radius ink
    s.inter.node = node;
    s.layer.node = node;
    s.layer.alphas = .{ .hover = opts.theme.state.hover, .focus = opts.theme.state.focus, .pressed = opts.theme.state.pressed, .drag = opts.theme.state.drag };
    s.ripples = .{ .bounded = false, .radius = state_layer_size / 2, .node = node, .pressed_alpha = opts.theme.state.pressed };
    // the layer disc and the ripple ink reach radius 20dp past the
    // circle's center (the bounds center) — against a minimal 20dp
    // bounds that's 10dp past each edge, same as the static layer needed
    node.damage_overflow = .{ .left = state_layer_size / 2 - icon_size / 2, .right = state_layer_size / 2 - icon_size / 2, .top = state_layer_size / 2 - icon_size / 2, .bottom = state_layer_size / 2 - icon_size / 2 };
    ui.semantics.attach(node, .{
        .role = .radio,
        .label = opts.a11y_label,
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
        .checked = isChecked(s),
        .actions = ui.semantics.Actions.initOne(.activate),
    });
    sig.subscribe(.{ .callback = .{ .fn_ptr = radioSyncCb, .userdata = node } }); // visual + semantic updates on set
    return node;
}

// --- tests ---

test "radio: measures the 24dp node (2dp pad + 20dp icon); the 48dp floor is the hit target" {
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sig.deinit();
    const b = try radio(std.testing.allocator, sig, 0, .{ .a11y_label = "x" });
    defer b.deinit();
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    // padding(2dp) + requiredSize(IconSize=20dp) → a 24dp node
    try std.testing.expectEqual(circle_size, m.w);
    try std.testing.expectEqual(circle_size, m.h);
    b.layout(.{ .x = 100, .y = 100, .w = 20, .h = 20 });
    const hb = b.vtable.hit_bounds.?(b);
    try std.testing.expectEqual(theme_mod.light.platform.hit_target_min, hb.w);
    try std.testing.expectEqual(@as(f32, 100 - 14), hb.x); // (20-48)/2
}

test "radio: click and Enter/Space select the radio (the group signal)" {
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sig.deinit();
    const a = try radio(std.testing.allocator, sig, 0, .{ .a11y_label = "A" });
    defer a.deinit();
    const b = try radio(std.testing.allocator, sig, 1, .{ .a11y_label = "B" });
    defer b.deinit();
    a.layout(.{ .x = 0, .y = 0, .w = 20, .h = 20 });
    b.layout(.{ .x = 40, .y = 0, .w = 20, .h = 20 });
    try std.testing.expect(isChecked(stateOf(a)));
    try std.testing.expect(!isChecked(stateOf(b)));
    // click B (from the hit margin: the hit target is 48 wide centered on B)
    const on_pointer = b.vtable.on_pointer.?;
    _ = on_pointer(b, .{ .phase = .down, .x = 60, .y = 10, .raw_x = 60, .raw_y = 10 });
    _ = on_pointer(b, .{ .phase = .up, .x = 60, .y = 10, .raw_x = 60, .raw_y = 10 });
    try std.testing.expectEqual(@as(usize, 1), sig.peek());
    try std.testing.expect(!isChecked(stateOf(a))); // the semantic state followed
    try std.testing.expect(isChecked(stateOf(b)));
    // keyboard on A
    const on_key = a.vtable.on_key.?;
    try std.testing.expect(on_key(a, .{ .kind = .key_down, .key = .enter }));
    try std.testing.expectEqual(@as(usize, 0), sig.peek());
    try std.testing.expect(!on_key(a, .{ .kind = .key_down, .key = .left }));
}

test "radio: semantics — role radio, checked sync, disabled" {
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 2);
    defer sig.deinit();
    const b = try radio(std.testing.allocator, sig, 2, .{ .a11y_label = "Two" });
    defer b.deinit();
    try std.testing.expectEqual(ui.semantics.Role.radio, b.semantics.?.role);
    try std.testing.expectEqual(true, b.semantics.?.checked);
    try std.testing.expectEqualStrings("Two", b.semantics.?.label);
    sig.set(0);
    try std.testing.expectEqual(false, b.semantics.?.checked);
    const dis = try radio(std.testing.allocator, sig, 2, .{ .enabled = false, .a11y_label = "x" });
    defer dis.deinit();
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
}

test "golden: selected radio paints the primary circle + the dot" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sig.deinit();
    const b = try radio(std.testing.allocator, sig, 0, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 48, 48);
    defer r.deinit();
    b.layout(.{ .x = 14, .y = 14, .w = 20, .h = 20 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the dot center: primary
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(24, 24));
    // the circle outline: primary ink present (the circle's edge is curved —
    // AA — so assert presence, not an exact pixel)
    try std.testing.expect(f.countColorIn(.{ .x = 14, .y = 14, .w = 20, .h = 20 }, t.colors.primary) > 0);
    // outside the circle + the 40dp state layer (idle): bg
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(2, 2));
}

test "golden: unselected radio strokes the OnSurfaceVariant circle, no dot" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 1);
    defer sig.deinit();
    const b = try radio(std.testing.allocator, sig, 0, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 48, 48);
    defer r.deinit();
    b.layout(.{ .x = 14.5, .y = 14.5, .w = 20, .h = 20 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the circle outline: on_surface_variant ink present
    try std.testing.expect(f.countColorIn(.{ .x = 14, .y = 14, .w = 20, .h = 20 }, t.colors.on_surface_variant) > 0);
    // the center: no dot → transparent → bg
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(24, 24));
}

test "radio: paintRect covers the 40dp state layer (culling/damage contract)" {
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sig.deinit();
    const b = try radio(std.testing.allocator, sig, 0, .{});
    defer b.deinit();
    b.layout(.{ .x = 100, .y = 100, .w = 20, .h = 20 });
    try std.testing.expectEqual(ui.node.Rect{ .x = 90, .y = 90, .w = 40, .h = 40 }, b.paintRect());
}
