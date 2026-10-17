// Switch (Phase 2d.2 PR B2, M3E) — the M3E switch (icon-less and icon
// variants).
//
// Ported from .ref/material3/Switch.kt (verbatim behavior):
//   - SwitchImpl: the track Box is requiredSize(52x32) + border(2dp,
//     borderColor, CornerFull) + background(trackColor) — the border draws
//     inside the track edge → a 2dp ring flush with the pill edge, painted
//     over the fill. The thumb Box is CenterStart-aligned; its LayoutNode
//     (ThumbElement/ThumbNode.measure) sizes + offsets the content
//   - ThumbNode.measure: size = pressed → PressedHandleWidth (28); else
//     (thumbContent || checked) → ThumbDiameter (24) — so the icon variant's
//     UNCHECKED thumb is 24 too (hasContent); else UncheckedThumbDiameter
//     (16). offset = pressed&&checked → maxBound - TrackOutlineWidth (22);
//     pressed&&!checked → TrackOutlineWidth (2); checked → maxBound (24 =
//     TrackWidth - ThumbDiameter - ThumbPadding); else minBound
//     ((32 - size)/2 → 8, or 4 with an icon)
//   - the thumb's size/offset animate with MotionSchemeKeyTokens.FastSpatial
//     (the theme spatial spring) EXCEPT pressed-state changes, which snap
//     (SnapSpec) — pressing instantly grows to 28 and shifts to the ±2dp
//     offsets; releasing springs back. The first layout uses the raw values
//     (the Animatables are created lazily — no intro animation). Colors are
//     plain params upstream → they snap on state change (no
//     animateColorAsState in SwitchImpl)
//   - colors (defaultSwitchColors): unchecked track SurfaceContainerHighest
//     + border UnselectedFocusTrackOutlineColor (Outline) + thumb
//     UnselectedHandleColor (Outline); checked track Primary + thumb
//     SelectedHandleColor (OnPrimary) + border Transparent. The
//     Selected/Unselected{Hover,Focus,Pressed}HandleColor variants
//     (PrimaryContainer / OnSurfaceVariant — the style system resolves them;
//     the defaults are interaction-static) apply like the spec states table
//   - disabled colors compositeOver(surface) upstream — literal per the
//     token math: checked track OnSurface@0.12 over surface + thumb Surface;
//     unchecked track SurfaceContainerHighest@0.12 over surface + border
//     OnSurface@0.12 over surface + thumb OnSurface@0.38 over surface
//   - the thumb icon (thumbContent): a 16dp glyph centered in the thumb at
//     iconColor — SelectedIconColor OnPrimaryContainer / UnselectedIconColor
//     SurfaceContainerHighest (+ the disabled composites). show_icons draws
//     check/close like the M3E spec asset
//   - indication (Switch.kt:156-199): the track-level toggleable carries
//     `indication = null`; the THUMB's modifier chain attaches
//     `.indication(interactionSource, ripple(bounded = false, radius =
//     SwitchTokens.StateLayerSize / 2, enableFocusIndication = !useInsetRing))`
//     — StateLayerSize = 40dp → an unbounded 20dp-radius ink disc anchored
//     on the THUMB's own layout bounds (it follows the animated thumb
//     position, not the track center), drawn over the thumb fill + icon
//     like upstream's draw modifier. Interactions run through the shared
//     machinery: Tracker (press/hover/focus ordering), StateLayer (the
//     animated 40dp hover/focus disc on the thumb — presses go to the
//     ripple, never the layer), Ripples (75ms fade-in / 225ms expand /
//     150ms fade-out). The ink is the effective thumb color.
//     Enter/Space emits Press+Release → a centered ripple at the thumb.
//   - hit target: max(52,48) x max(32,48) centered on the track
//     (minimumInteractiveComponentSize — the a11y floor is the hit area)
//   - RTL: the CenterStart thumb + placeRelative(offset) mirror the track —
//     the offset counts from the end side (the checked thumb sits at the
//     start edge like upstream RTL)
//
// Remaining deviations: the InsetRing focus-ring
// configuration isn't modeled (the thumb layer carries focus like the
// default configuration).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const icon_w = @import("icon.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

/// M3E measurement tokens (SwitchTokens + Switch.kt).
const track_w: f32 = 52; // SwitchWidth = TrackWidth
const track_h: f32 = 32; // SwitchHeight = TrackHeight
const outline_width: f32 = 2; // TrackOutlineWidth
const handle_off: f32 = 16; // UncheckedThumbDiameter = UnselectedHandleWidth
const handle_on: f32 = 24; // ThumbDiameter = SelectedHandleWidth
const handle_pressed: f32 = 28; // PressedHandleWidth
const thumb_padding: f32 = (track_h - handle_on) / 2; // ThumbPadding = 4
/// thumbPathLength = SwitchWidth - ThumbDiameter - ThumbPadding → maxBound.
const max_bound: f32 = track_w - handle_on - thumb_padding;
const icon_size: f32 = 16; // Selected/UnselectedIconSize
const state_layer_size: f32 = 40;
// Compose minimumInteractiveComponentSize (the a11y hit-target floor) =
// theme.platform.hit_target_min — read from s.opts.theme where used.

pub const SwitchOptions = struct {
    enabled: bool = true,
    /// The accessible name (a switch is usually paired with a visible label
    /// built by the app; this is the control's own name).
    a11y_label: []const u8 = "",
    /// M3E icon variant: a 16dp check glyph in the checked handle, a close
    /// glyph in the unchecked one — painted in the track color (the token
    /// contrast pair: onPrimary handle carries the primary icon, and the
    /// outline handle carries the surfaceContainerHighest one).
    show_icons: bool = false,
    theme: Theme = theme_mod.light,
};

const SwitchState = struct {
    opts: SwitchOptions,
    sig: *ui.state.Signal(bool),
    on_changed: ?Callback = null,
    /// The upstream interaction machinery (interactions.zig): ordered
    /// press/hover/focus entries — the tracker damages the node on every
    /// mutation (the manual markDirty on press/hover is gone).
    inter: ui.interactions.Tracker = .{},
    /// The animated interaction-state overlay (the 40dp disc on the thumb —
    /// hover/focus only; presses go to the ripple).
    layer: ui.state_layer.StateLayer = .{},
    /// The unbounded 20dp-radius ripple set, anchored to the thumb's rect.
    ripples: ui.ripple.Ripples = .{},
    /// The live press's interaction id (0 = none) — pairs tracker.release
    /// and ripples.release.
    press_id: u32 = 0,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — see PointerEvent.raw_x/raw_y).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
    /// ThumbNode's sizeAnim/offsetAnim: the animated thumb diameter and its
    /// start-edge offset in track space (pre-RTL-mirror).
    thumb_size: f32 = 0,
    thumb_off: f32 = 0,
    /// Animation channel markers (stable addresses).
    size_channel: u8 = 0,
    off_channel: u8 = 0,
};

fn stateOf(n: *Node) *SwitchState {
    return @ptrCast(@alignCast(n.state.?));
}

fn isChecked(s: *SwitchState) bool {
    return s.sig.peek();
}

/// The track color, border color, thumb color, icon color and the state
/// layer's on-color for the current state.
const SWColors = struct { track: Color, outline: Color, handle: Color, icon: Color, on: Color };

/// c.copy(alpha = k).compositeOver(surface) — an opaque composite like
/// upstream's disabled color math.
fn overSurface(c: Color, k: f32, surface: Color) Color {
    const src = ui.paint.withAlphaScaled(c, k);
    const sa: f32 = @floatFromInt(src & 0xFF);
    const ch = struct {
        fn f(sv: u32, dv: u32, a: f32) u32 {
            const r = @round((@as(f32, @floatFromInt(sv)) * a + @as(f32, @floatFromInt(dv)) * (255 - a)) / 255);
            return @intFromFloat(r);
        }
    }.f;
    return (ch((src >> 24) & 0xFF, (surface >> 24) & 0xFF, sa) << 24) |
        (ch((src >> 16) & 0xFF, (surface >> 16) & 0xFF, sa) << 16) |
        (ch((src >> 8) & 0xFF, (surface >> 8) & 0xFF, sa) << 8) | 0xFF;
}

/// defaultSwitchColors + the per-state token variants (Switch.kt
/// thumbColor/trackColor/borderColor/iconColor). The interaction variants
/// come from the *Hover/*Focus/*Pressed tokens (the style system resolves
/// them — the defaults are interaction-static); disabled colors are the
/// upstream .copy(alpha).compositeOver(surface) results.
fn currentColors(s: *SwitchState) SWColors {
    const cs = s.opts.theme.colors;
    if (!s.opts.enabled) {
        if (isChecked(s)) {
            return .{
                .track = overSurface(cs.on_surface, 0.12, cs.surface), // DisabledSelectedTrackColor @ DisabledTrackOpacity
                .outline = 0x00000000, // disabledCheckedBorderColor = Transparent
                .handle = cs.surface, // DisabledSelectedHandleColor @ 1.0 → Surface
                .icon = overSurface(cs.on_surface, 0.38, cs.surface), // DisabledSelectedIconColor @ 0.38
                .on = cs.surface,
            };
        }
        return .{
            .track = overSurface(cs.surface_container_highest, 0.12, cs.surface), // SCH @ 0.12 over surface — NOT the opaque SCH
            .outline = overSurface(cs.on_surface, 0.12, cs.surface), // DisabledUnselectedTrackOutlineColor @ DisabledTrackOpacity
            .handle = overSurface(cs.on_surface, 0.38, cs.surface), // DisabledUnselectedHandleColor @ 0.38
            .icon = overSurface(cs.surface_container_highest, 0.38, cs.surface), // DisabledUnselectedIconColor @ 0.38
            .on = overSurface(cs.on_surface, 0.38, cs.surface),
        };
    }
    // the {Selected,Unselected}{Hover,Focus,Pressed}HandleColor tokens —
    // PrimaryContainer / OnSurfaceVariant, all equal per state (the style
    // system resolves them; the default colors are interaction-static)
    const interacting = s.inter.len > 0;
    if (isChecked(s)) {
        const h = if (interacting) cs.primary_container else cs.on_primary;
        return .{
            .track = cs.primary, // SelectedTrackColor
            .outline = 0x00000000, // checkedBorderColor = Transparent
            .handle = h, // SelectedHandleColor / *HandleColor
            .icon = cs.on_primary_container, // SelectedIconColor
            .on = h,
        };
    }
    const h = if (interacting) cs.on_surface_variant else cs.outline;
    return .{
        .track = cs.surface_container_highest, // UnselectedTrackColor
        .outline = cs.outline, // Unselected{Focus}TrackOutlineColor
        .handle = h, // UnselectedHandleColor / *HandleColor
        .icon = cs.surface_container_highest, // UnselectedIconColor
        .on = h,
    };
}

/// ThumbNode.measure's TARGET size/offset for the current state — the
/// values the anims glide toward (pressed snaps). `hasContent` is the icon
/// variant (thumbContent present → the unchecked thumb is 24).
fn thumbTargets(n: *Node, s: *SwitchState) struct { size: f32, off: f32 } {
    _ = n;
    const on = isChecked(s);
    const has_content = s.opts.show_icons;
    const pressed = s.inter.isPressed();
    const size: f32 = if (pressed) handle_pressed else if (has_content or on) handle_on else handle_off;
    const off: f32 = if (pressed)
        (if (on) max_bound - outline_width else outline_width) // maxBound - TrackOutlineWidth / TrackOutlineWidth
    else if (on)
        max_bound // thumbPathLength
    else
        (track_h - size) / 2; // minBound = thumbPaddingStart
    return .{ .size = size, .off = off };
}

/// The thumb's rect: the animated size/offset in track space, vertically
/// centered, mirrored in RTL (placeRelative counts the offset from the
/// start edge).
fn handleRect(n: *Node, s: *SwitchState) Rect {
    _ = n;
    const w = s.thumb_size;
    const x = if (ui.i18n.direction() == .rtl) track_w - s.thumb_off - w else s.thumb_off;
    return .{ .x = x, .y = (track_h - w) / 2, .w = w, .h = w };
}

fn switchMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = track_w, .h = track_h });
}

/// The interactive target: max(track dims, hit_target_min) centered on the
/// track (the a11y floor, 48 mobile / 24 desktop).
fn switchHitBounds(n: *Node) Rect {
    const s = stateOf(n);
    const b = n.bounds;
    const w = @max(b.w, s.opts.theme.platform.hit_target_min);
    const h = @max(b.h, s.opts.theme.platform.hit_target_min);
    return .{ .x = b.x + (b.w - w) / 2, .y = b.y + (b.h - h) / 2, .w = w, .h = h };
}

fn switchPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const cc = currentColors(s);
    // track (pill): background then the border ring — the border draws
    // INSIDE the track edge (Compose border() insets the ring), so its
    // outer edge is flush with the pill
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, track_h / 2, cc.track);
    if (cc.outline & 0xFF != 0) {
        ui.paint.strokeRRect(ctx, b.x + outline_width / 2, b.y + outline_width / 2, b.w - outline_width, b.h - outline_width, track_h / 2 - outline_width / 2, outline_width, cc.outline);
    }
    // thumb (absolute within the track; mirrored by handleRect for RTL)
    const hr = handleRect(n, s);
    const h = Rect{ .x = b.x + hr.x, .y = b.y + hr.y, .w = hr.w, .h = hr.h };
    ui.paint.fillRRect(ctx, h.x, h.y, h.w, h.h, h.w / 2, cc.handle);
    // the thumb icon (thumbContent): a 16dp glyph centered in the thumb at
    // iconColor — check when checked, close when not (the M3E spec asset)
    if (s.opts.show_icons) {
        const icon_name: icon_w.IconName = if (isChecked(s)) .check else .close;
        icon_w.drawIcon(ctx, icon_name, h.x + (h.w - icon_size) / 2, h.y + (h.h - icon_size) / 2, icon_size / 24.0, cc.icon);
    }
    // The indication draws over the thumb fill + icon like upstream's draw
    // modifier (it sits inside the thumb's Box chain, Switch.kt:191-199).
    // Focus has no widget callback — poll the router.
    if (s.opts.enabled) {
        s.inter.setFocused(input.isFocused(n));
        s.layer.sync(&s.inter, cc.on);
        const cx = h.x + h.w / 2;
        const cy = h.y + h.h / 2;
        // the animated state layer: the 40dp disc centered on the thumb
        if (s.layer.paintColor()) |c| {
            ui.paint.fillRRect(ctx, cx - state_layer_size / 2, cy - state_layer_size / 2, state_layer_size, state_layer_size, state_layer_size / 2, c);
        }
        // the unbounded ink: radius 20dp, anchored to the thumb's rect —
        // it follows the animated thumb position (the indication's own
        // bounds upstream are the thumb LayoutNode's)
        s.ripples.color = cc.on;
        s.ripples.paintIn(ctx, h, .none);
    }
}

fn thumbSizeCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).thumb_size = v[0];
    n.markDirty();
}
fn thumbOffCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).thumb_off = v[0];
    n.markDirty();
}

/// ThumbNode's animateTo calls: the thumb's size/offset retarget toward the
/// current state — pressed-state changes snap (SnapSpec), everything else
/// springs with FastSpatial (the theme spatial spring). No timeline → snap.
fn retargetThumb(n: *Node, s: *SwitchState) void {
    const t = thumbTargets(n, s);
    if (ui.anim.timeline()) |tl| {
        if (s.inter.isPressed()) {
            s.thumb_size = t.size;
            s.thumb_off = t.off;
            tl.cancelChannel(@ptrCast(&s.size_channel));
            tl.cancelChannel(@ptrCast(&s.off_channel));
            n.markDirty();
            return;
        }
        const from: ui.anim.Vec4 = .{ s.thumb_size, s.thumb_off, 0, 0 };
        // Velocity continuity: a mid-flight retarget carries the running
        // channel's velocity into the new spring (upstream passes the
        // Animatable's velocity through animateToAsState).
        _ = tl.play(.{
            .kind = ui.anim.Animation.springAnim(.{ from[0], 0, 0, 0 }, .{ t.size, 0, 0, 0 }, s.opts.theme.motion.springs.fast_spatial, tl.channelVelocity(@ptrCast(&s.size_channel))),
            .from = .{ from[0], 0, 0, 0 },
            .channel = @ptrCast(&s.size_channel),
            .on_update = .{ .fn_ptr = thumbSizeCb, .userdata = n },
        });
        _ = tl.play(.{
            .kind = ui.anim.Animation.springAnim(.{ from[1], 0, 0, 0 }, .{ t.off, 0, 0, 0 }, s.opts.theme.motion.springs.fast_spatial, tl.channelVelocity(@ptrCast(&s.off_channel))),
            .from = .{ from[1], 0, 0, 0 },
            .channel = @ptrCast(&s.off_channel),
            .on_update = .{ .fn_ptr = thumbOffCb, .userdata = n },
        });
    } else {
        s.thumb_size = t.size;
        s.thumb_off = t.off;
    }
}

fn switchOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    switch (ev.phase) {
        .down => {
            s.press_id = s.inter.pressDown(ev.x, ev.y);
            s.ripples.spawn(s.press_id, ev.x, ev.y, ev.time_ms);
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            retargetThumb(n, s); // pressed → snap to the pressed size/offset
            return true;
        },
        .up => {
            const was_pressed = s.press_id != 0;
            s.inter.release(s.press_id);
            s.ripples.release(s.press_id, ev.time_ms);
            s.press_id = 0;
            retargetThumb(n, s); // release → spring back
            // the click lands in the hit target, not necessarily in the track
            if (was_pressed and switchHitBounds(n).contains(ev.x, ev.y)) {
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
                    retargetThumb(n, s); // cancel → spring back
                }
            }
            return false;
        },
        .outside_down => {
            s.inter.cancel(s.press_id);
            s.ripples.release(s.press_id, ev.time_ms);
            s.press_id = 0;
            retargetThumb(n, s); // cancel → spring back
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

/// Keyboard activation (Phase 2c): Enter/Space toggle the focused switch.
/// Upstream's toggleable emits Press → Release for a key activation, so the
/// thumb-anchored unbounded ripple spawns + releases (unbounded spawn is
/// centered on the thumb's rect regardless of x/y).
fn switchOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            const hr = handleRect(n, s);
            const cx = n.bounds.x + hr.x + hr.w / 2;
            const cy = n.bounds.y + hr.y + hr.h / 2;
            const pid = s.inter.pressDown(cx, cy);
            s.ripples.spawn(pid, cx, cy, 0);
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

/// Signal-driven repaint + semantic checked sync + the ThumbNode retarget
/// (the check change springs the thumb's size/offset — or snaps mid-press,
/// matching upstream's `if (isPressed) SnapSpec else animationSpec`).
fn switchSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (n.semantics) |sem| sem.checked = s.sig.peek();
    retargetThumb(n, s);
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the value changed
}

fn switchDeinit(n: *Node) void {
    const s = stateOf(n);
    // the ripple ticker's userdata is `s.ripples` — unregister before the
    // state is freed; the layer's tween channel likewise.
    s.ripples.deinit();
    s.layer.deinit();
    if (ui.anim.timeline()) |tl| {
        tl.cancelChannel(@ptrCast(&s.size_channel));
        tl.cancelChannel(@ptrCast(&s.off_channel));
    }
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = switchSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

/// The region own-paint can touch. handleRect works in a fixed 52x32 track
/// space anchored at b.x — when bounds are narrower than 52 the checked
/// handle (and its 40dp layer / unbounded ripple ink) still paint past b's
/// right edge, so a constant damage_overflow under-reports. Cover the union
/// of both handle extremes plus the ink reach (thumb-center ± 21dp —
/// radius 20 + ~1px AA): track space [-5, 57] x [-5, 37], plus the bounds
/// themselves when wider/taller.
fn switchPaintBounds(n: *Node) Rect {
    const b = n.bounds;
    return .{
        .x = b.x - 5,
        .y = b.y - 5,
        .w = @max(b.w, track_w + 10), // ink reaches 57 in track space
        .h = @max(b.h, track_h + 10), // ink reaches 37
    };
}

const switch_vtable = ui.node.VTable{
    .measure = switchMeasure,
    .layout = null_layout,
    .paint = switchPaint,
    .deinit = switchDeinit,
    .on_pointer = switchOnPointer,
    .on_key = switchOnKey,
    .hit_bounds = switchHitBounds,
    .paint_bounds = switchPaintBounds,
};

fn null_layout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: bounds come from the parent
}

/// An M3E switch bound to `sig` (a click or Enter/Space flips it; the visual
/// + semantic state follows the signal).
pub fn @"switch"(allocator: std.mem.Allocator, sig: *ui.state.Signal(bool), on_changed: ?Callback, opts: SwitchOptions) !*Node {
    const node = try Node.create(allocator, &switch_vtable);
    errdefer allocator.destroy(node); // no state yet
    const s = try allocator.create(SwitchState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .sig = sig, .on_changed = on_changed };
    node.state = s;
    // seed the thumb at the raw targets (upstream's sizeAnim/offsetAnim are
    // lazy — the first measure uses the values, no intro animation)
    const t = thumbTargets(node, s);
    s.thumb_size = t.size;
    s.thumb_off = t.off;
    // the interaction machinery: the tracker + the tweened state layer
    // (alphas from the theme state table) + the unbounded 20dp-radius ink
    // on the thumb
    s.inter.node = node;
    s.layer.node = node;
    s.layer.alphas = .{ .hover = opts.theme.state.hover, .focus = opts.theme.state.focus, .pressed = opts.theme.state.pressed, .drag = opts.theme.state.drag };
    s.ripples = .{ .bounded = false, .radius = state_layer_size / 2, .node = node, .pressed_alpha = opts.theme.state.pressed };
    ui.semantics.attach(node, .{
        .role = .toggle,
        .label = opts.a11y_label,
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
        .checked = sig.peek(),
        .actions = ui.semantics.Actions.initOne(.activate),
    });
    sig.subscribe(.{ .callback = .{ .fn_ptr = switchSyncCb, .userdata = node } }); // visual + semantic updates on set
    return node;
}

// --- tests ---

fn changeCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "switch: measures the 52x32 track; the hit target floors at 48 high" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, null, .{ .a11y_label = "x" });
    defer b.deinit();
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(track_w, m.w);
    try std.testing.expectEqual(track_h, m.h);
    b.layout(.{ .x = 100, .y = 100, .w = 52, .h = 32 });
    const hb = b.vtable.hit_bounds.?(b);
    try std.testing.expectEqual(@as(f32, 52), hb.w);
    try std.testing.expectEqual(theme_mod.light.platform.hit_target_min, hb.h); // 32 -> 48
    try std.testing.expectEqual(@as(f32, 100 - 8), hb.y); // (32-48)/2
}

test "switch: the handle follows the state (off/on/pressed positions)" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, null, .{ .a11y_label = "x" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 52, .h = 32 });
    const s = stateOf(b);
    // off: 16x16 at (8, 8)
    var hr = handleRect(b, s);
    try std.testing.expectEqual(@as(f32, 8), hr.x);
    try std.testing.expectEqual(@as(f32, 8), hr.y);
    try std.testing.expectEqual(handle_off, hr.w);
    // on: 24x24 at (24, 4)
    sig.set(true);
    hr = handleRect(b, s);
    try std.testing.expectEqual(@as(f32, 24), hr.x);
    try std.testing.expectEqual(@as(f32, 4), hr.y);
    try std.testing.expectEqual(handle_on, hr.w);
    // pressed on: 28x28 at (22, 2) — the press path (down → retargetThumb)
    // snaps to the pressed size/offset like upstream's SnapSpec
    _ = s.inter.pressDown(16, 16);
    retargetThumb(b, s);
    hr = handleRect(b, s);
    try std.testing.expectEqual(@as(f32, 22), hr.x);
    try std.testing.expectEqual(@as(f32, 2), hr.y);
    try std.testing.expectEqual(handle_pressed, hr.w);
}

test "switch: click and Enter/Space toggle the signal + fire the callback" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = changeCounterCb, .userdata = &count };
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, cb, .{ .a11y_label = "x" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 52, .h = 32 });
    const on_pointer = b.vtable.on_pointer.?;
    // a drag past the slop cancels (a scroll, not a click)
    _ = on_pointer(b, .{ .phase = .down, .x = 26, .y = 16, .raw_x = 26, .raw_y = 16 });
    _ = on_pointer(b, .{ .phase = .move, .x = 26, .y = 40, .raw_x = 26, .raw_y = 40 });
    _ = on_pointer(b, .{ .phase = .up, .x = 26, .y = 16, .raw_x = 26, .raw_y = 16 });
    try std.testing.expect(!sig.peek());
    try std.testing.expectEqual(@as(u32, 0), count);
    // a plain click (from the hit margin: the hit target is 48 high, centered
    // on the 32-high track → y in [-8, 40))
    _ = on_pointer(b, .{ .phase = .down, .x = 26, .y = 38, .raw_x = 26, .raw_y = 38 });
    _ = on_pointer(b, .{ .phase = .up, .x = 26, .y = 38, .raw_x = 26, .raw_y = 38 });
    try std.testing.expect(sig.peek());
    try std.testing.expectEqual(@as(u32, 1), count);
    // keyboard
    const on_key = b.vtable.on_key.?;
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .enter }));
    try std.testing.expect(!sig.peek());
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "switch: semantics — role toggle, checked sync, disabled" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, null, .{ .a11y_label = "Wi-Fi" });
    defer b.deinit();
    try std.testing.expectEqual(ui.semantics.Role.toggle, b.semantics.?.role);
    try std.testing.expectEqual(true, b.semantics.?.checked);
    try std.testing.expectEqualStrings("Wi-Fi", b.semantics.?.label);
    sig.set(false);
    try std.testing.expectEqual(false, b.semantics.?.checked);
    const dis = try @"switch"(std.testing.allocator, sig, null, .{ .enabled = false, .a11y_label = "x" });
    defer dis.deinit();
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
}

test "golden: checked switch paints the primary track + the on_primary handle" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, null, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    b.layout(.{ .x = 6, .y = 16, .w = 52, .h = 32 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the track, left of the handle: primary
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(10, 32));
    // the handle center (24x24 at (30, 20) in window coords): on_primary
    try std.testing.expectEqual(t.colors.on_primary, f.pixelAt(42, 32));
}

test "golden: unchecked switch paints the surface_container_highest track + outline handle" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, null, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    b.layout(.{ .x = 6, .y = 16, .w = 52, .h = 32 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the track, right of the handle: surface_container_highest
    try std.testing.expectEqual(t.colors.surface_container_highest, f.pixelAt(50, 32));
    // the handle center (16x16 at (14, 24) in window coords): outline
    try std.testing.expectEqual(t.colors.outline, f.pixelAt(22, 32));
}

test "golden: disabled checked switch paints the OnSurface@0.12 track" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, null, .{ .enabled = false, .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    b.layout(.{ .x = 6, .y = 16, .w = 52, .h = 32 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // upstream composites the disabled track over `surface` (opaque), not
    // white — OnSurface@0.12 x surface
    try golden.expectPixelApprox(f, 10, 32, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.12), t.colors.surface));
}

test "switch: paintRect covers the thumb layer/ripple extremes (culling/damage contract)" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, null, .{});
    defer b.deinit();
    b.layout(.{ .x = 100, .y = 100, .w = 52, .h = 32 });
    // thumb cx ∈ [16, 36] + the 21dp ink reach → track space [-5, 57]
    try std.testing.expectEqual(ui.node.Rect{ .x = 95, .y = 95, .w = 62, .h = 42 }, b.paintRect());
    // constrained width: the handle still paints in track space 0..52 anchored
    // at b.x — the checked handle + ink must NOT be clipped by narrow bounds
    b.layout(.{ .x = 100, .y = 100, .w = 20, .h = 32 });
    try std.testing.expectEqual(ui.node.Rect{ .x = 95, .y = 95, .w = 62, .h = 42 }, b.paintRect());
}
