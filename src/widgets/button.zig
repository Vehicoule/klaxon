// Button (Phase 2d.2 PR A, M3E) — the five M3E button variants (filled,
// filled tonal, elevated, outlined, text) in the five M3E sizes (XS 32,
// S 40, M 56, L 96, XL 136).
//
// Ported verbatim from Compose .ref/material3/Button.kt + tokens —
//   Button()'s defaultMinSize/Row/Arrangement.Center layout,
//   ButtonDefaults.contentPaddingFor / iconSizeFor / iconSpacingFor /
//   textStyleFor / buttonShapesFor, ButtonElevation state tables
//   (buttonElevation / elevatedButtonElevation / filledTonalButtonElevation),
//   the *ButtonColors defaults, and outlinedButtonBorder:
//   - sizes: heights 32/40/56/96/136, icon 20/20/24/32/40, icon-label gap
//     4/8/8/12/16 (iconSpacingFor — ExtraSmallIconSpacing is hardcoded 4dp,
//     not the broader token's 8), content padding (h/v) 12/6, 16/8, 24/16,
//     48/32, 64/48 — every variant including text
//   - shapes: round (default) = CornerFull (pill = height/2); square =
//     CornerMedium 12 (XS/S), CornerLarge 16 (M), CornerExtraLarge 28 (L/XL)
//   - shape morph: pressed = CornerSmall 8 (XS/S), CornerMedium 12 (M),
//     CornerLarge 16 (L/XL) — both round and square buttons
//   - label styles: label_large (XS/S), title_medium (M), headline_small (L),
//     headline_large (XL)
//   - min width 58dp and min height = the container height, all sizes
//     (ButtonDefaults.MinWidth in the shared Button() composable)
//   - colors per variant (see variantColors); disabled: container OnSurface
//     @0.10 (0.12 tonal), label/icon OnSurfaceVariant @0.38 (OnSurface @0.38
//     tonal), outlined border OutlineVariant @0.10, text container
//     transparent; tonal small icon = 18dp; text label = Primary (upstream
//     hardcodes Primary — the TextButtonTokens label token is wrong)
//   - outline width 1dp for every size (outlinedButtonBorder always uses
//     ButtonSmallTokens.OutlinedOutlineWidth — the L/XL tokens' 2/3 are not
//     wired to the composable default)
//   - elevation: elevated = Level1 rest/press/focus, Level2 hovered;
//     filled + tonal cast a Level1 shadow on hover only; a press overrides
//     the hover (upstream's last-interaction rule — Button.kt:155 asks the
//     interaction source for its LAST entry, presses included, so
//     isPressed() wins over isHovered() in the elev switch below)
//   - indication: upstream delegates to Surface's clickable indication —
//     `ripple(focusRingShape = shape)` (Surface.kt:253-259), BOUNDED and
//     clipped to the current shape — wired via ui.interactions.Tracker +
//     ui.state_layer.StateLayer + ui.ripple.Ripples. The animated layer
//     carries hover 0.08 / focus 0.10 (theme.state); the pressed state is
//     the expanding ripple ink (pressed alpha 0.12), NOT a static layer —
//     over a transparent container (outlined/text) the layer is the
//     on-color AT that alpha (lerping from transparent black would
//     double-scale the RGB in the src-over blend). The ripple clip uses
//     the LIVE pressed/rest corner so the ink follows the shape morph.
//   - input: a drag past the touch slop (ui/gestures.SLOP, raw coords) is a
//     scroll, not a press — the press interaction + ripple are cancelled
//     and the move keeps bubbling to scrollable ancestors; outside_down
//     cancels too. Enter/Space mint a synthetic key press and spawn a
//     CENTERED bounded ripple (upstream's keyPress path).
//   - layout: the content row mirrors in RTL (the leading icon moves to the
//     end side); the children paint clipped to the button's bounds (a
//     constrained button never lets label ink cross the container edge)
//
//   - Shape morph on press springs through the fast_spatial spec on the
//     timeline (upstream's AnimatedShape + MotionScheme.fast — the corner
//     radius retargets on every press state change).
//   - Upstream's asymmetric per-icon content padding
//     (contentPaddingFor(hasStartIcon/hasEndIcon)) is opt-in upstream and
//     never used by the composable defaults — not exposed in this API.
//   - Label weight: the Text widget has a bold flag, not a weight axis —
//     weight >= 500 renders bold (label_large / title_medium), 400 renders
//     regular (headline_small / headline_large).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const text_w = @import("text.zig");
const icon_w = @import("icon.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const EdgeInsets = ui.layout.EdgeInsets;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

pub const ButtonVariant = enum { filled, filled_tonal, elevated, outlined, text };
pub const ButtonSize = enum { xsmall, small, medium, large, xlarge };
/// round = CornerFull (pill); square = the size's corner token.
pub const ButtonShape = enum { round, square };

pub const ButtonOptions = struct {
    variant: ButtonVariant = .filled,
    size: ButtonSize = .small,
    shape: ButtonShape = .round,
    enabled: bool = true,
    /// The label text (null = icon-only button). Rendered as internal chrome
    /// with the variant's label style/color — not document data.
    label: ?[]const u8 = null,
    /// Accessible name for icon-only buttons (a11y). The visible label wins
    /// when both are set.
    a11y_label: ?[]const u8 = null,
    /// Optional leading icon (rendered at the size's icon token, in the
    /// label color; mirrors to the end side in RTL).
    icon: ?icon_w.IconName = null,
    theme: Theme = theme_mod.light,
};

/// Per-size measurement tokens (Compose Button*Tokens + Button.kt paddings).
pub const Dims = struct {
    height: f32,
    icon: f32,
    icon_gap: f32,
    h_padding: f32,
    v_padding: f32,
    square_corner: f32,
    pressed_corner: f32,
    outline_width: f32,
};

pub fn dimsFor(size: ButtonSize) Dims {
    return switch (size) {
        // icon_gap = ButtonDefaults.iconSpacingFor (ExtraSmallIconSpacing is
        // hardcoded 4dp in Button.kt — the broader token's 8 is not used).
        // outline_width = ButtonDefaults.outlinedButtonBorder, which always
        // uses ButtonSmallTokens.OutlinedOutlineWidth (1dp) for every size
        // (the L/XL OutlinedOutlineWidth tokens are not wired to the
        // composable's default border).
        .xsmall => .{ .height = 32, .icon = 20, .icon_gap = 4, .h_padding = 12, .v_padding = 6, .square_corner = 12, .pressed_corner = 8, .outline_width = 1 },
        .small => .{ .height = 40, .icon = 20, .icon_gap = 8, .h_padding = 16, .v_padding = 8, .square_corner = 12, .pressed_corner = 8, .outline_width = 1 },
        .medium => .{ .height = 56, .icon = 24, .icon_gap = 8, .h_padding = 24, .v_padding = 16, .square_corner = 16, .pressed_corner = 12, .outline_width = 1 },
        .large => .{ .height = 96, .icon = 32, .icon_gap = 12, .h_padding = 48, .v_padding = 32, .square_corner = 28, .pressed_corner = 16, .outline_width = 1 },
        .xlarge => .{ .height = 136, .icon = 40, .icon_gap = 16, .h_padding = 64, .v_padding = 48, .square_corner = 28, .pressed_corner = 16, .outline_width = 1 },
    };
}

/// Compose ButtonDefaults.MinWidth — applies to every size (the shared
/// Button() composable's defaultMinSize).
const min_width: f32 = 58;
// The a11y touch-target floor is theme.platform.hit_target_min (48 mobile /
// 24 desktop) — see buttonHitBounds.
/// FilledTonalButtonTokens.IconSize (the small tonal icon is 18dp).
const tonal_icon_small: f32 = 18;

pub const VariantColors = struct {
    container: Color, // enabled (transparent for outlined/text)
    on: Color, // label/icon color + the state layer's on-color
    disabled_container: Color,
    disabled_on: Color,
    outline: Color, // outlined variant only
    disabled_outline: Color,
};

pub fn variantColors(t: Theme, variant: ButtonVariant) VariantColors {
    const cs = t.colors;
    const transparent: Color = 0x00000000;
    return switch (variant) {
        .filled => .{
            .container = cs.primary,
            .on = cs.on_primary,
            .disabled_container = ui.paint.withAlphaScaled(cs.on_surface, 0.10),
            .disabled_on = ui.paint.withAlphaScaled(cs.on_surface_variant, 0.38),
            .outline = transparent,
            .disabled_outline = transparent,
        },
        .filled_tonal => .{
            .container = cs.secondary_container,
            .on = cs.on_secondary_container,
            .disabled_container = ui.paint.withAlphaScaled(cs.on_surface, 0.12),
            .disabled_on = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
            .outline = transparent,
            .disabled_outline = transparent,
        },
        .elevated => .{
            .container = cs.surface_container_low,
            .on = cs.primary,
            .disabled_container = ui.paint.withAlphaScaled(cs.on_surface, 0.10),
            .disabled_on = ui.paint.withAlphaScaled(cs.on_surface_variant, 0.38),
            .outline = transparent,
            .disabled_outline = transparent,
        },
        .outlined => .{
            .container = transparent,
            .on = cs.on_surface_variant,
            .disabled_container = transparent,
            .disabled_on = ui.paint.withAlphaScaled(cs.on_surface_variant, 0.38),
            .outline = cs.outline_variant,
            .disabled_outline = ui.paint.withAlphaScaled(cs.outline_variant, 0.10),
        },
        .text => .{
            .container = transparent,
            // upstream textButtonColors hardcodes Primary (the token's
            // OnSurfaceVariant is marked incorrect in Button.kt)
            .on = cs.primary,
            .disabled_container = transparent, // upstream: Color.Transparent
            .disabled_on = ui.paint.withAlphaScaled(cs.on_surface_variant, 0.38),
            .outline = transparent,
            .disabled_outline = transparent,
        },
    };
}

/// The label's type style per size (Compose ButtonDefaults.textStyleFor).
pub fn labelStyle(t: Theme, size: ButtonSize) theme_mod.TypeStyle {
    return switch (size) {
        .xsmall, .small => t.type_scale.label_large,
        .medium => t.type_scale.title_medium,
        .large => t.type_scale.headline_small,
        .xlarge => t.type_scale.headline_large,
    };
}

/// Content padding (Compose ButtonDefaults.contentPaddingFor — every M3E
/// variant including TextButton delegates to the same per-size padding;
/// the asymmetric icon paddings upstream offers are opt-in params the
/// composable defaults never pass).
pub fn contentPadding(opts: ButtonOptions) EdgeInsets {
    const d = dimsFor(opts.size);
    return .{ .left = d.h_padding, .top = d.v_padding, .right = d.h_padding, .bottom = d.v_padding };
}

const ButtonState = struct {
    opts: ButtonOptions,
    on_pressed: ?Callback = null,
    /// The Compose interaction set (press/hover/focus entries, last-wins) —
    /// drives the corner morph + elevation rule + state layer via
    /// isPressed()/isHovered()/layerKind(); `node` marks dirty on every
    /// mutation (replaces the old pressed/hovered bools + markDirty).
    inter: ui.interactions.Tracker = .{},
    /// The animated state layer (hover/focus ink; the pressed state is the
    /// ripple's, per upstream's RippleAnimation owning it).
    layer: ui.state_layer.StateLayer = .{},
    /// Bounded ripples clipped to the current shape (upstream's
    /// `ripple(focusRingShape = shape)` through Surface).
    ripples: ui.ripple.Ripples = .{},
    /// The live press's interaction id (0 = none) — pairs release/cancel
    /// with the exact pressDown, so the matching ripple finishes.
    press_id: u32 = 0,
    /// The down position in raw (window) coordinates — drag deltas are
    /// physical finger motion, immune to the content scrolling under the
    /// finger (PointerEvent.raw_x/raw_y doc).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
    /// The painted corner radius — springs toward `buttonCornerTarget` on
    /// every press state change (upstream's AnimatedShape morph), -1 =
    /// uninitialized (the first paint snaps, like icon_button.zig).
    corner: f32 = -1,
    /// Animation channel marker (a stable address — see icon_button.zig).
    corner_channel: u8 = 0,
};

fn stateOf(n: *Node) *ButtonState {
    return @ptrCast(@alignCast(n.state.?));
}

/// The corner radius TARGET for the current press state — the paint reads
/// `s.corner`, which `buttonRetargetCorner` springs toward this value
/// (upstream's AnimatedShape: every interaction change morphs the
/// ContainerShape between PressedContainerShape and the rest shape).
fn buttonCornerTarget(s: *ButtonState, height: f32) f32 {
    const d = dimsFor(s.opts.size);
    if (s.inter.isPressed()) return d.pressed_corner;
    return if (s.opts.shape == .round) height / 2 else d.square_corner;
}

fn buttonCornerCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).corner = v[0];
    n.markDirty();
}

/// Retarget the corner spring toward the current press state's target —
/// the channel's velocity carries through a mid-flight retarget (the
/// Animatable upstream drives). No timeline (headless/tests) → snaps.
fn buttonRetargetCorner(n: *Node, s: *ButtonState) void {
    if (n.bounds.h <= 0) return; // unlaid-out: the first paint snaps
    const target = buttonCornerTarget(s, n.bounds.h);
    if (ui.anim.timeline()) |tl| {
        if (s.corner >= 0 and s.corner != target) {
            _ = tl.play(.{
                // Button.kt:253-255 — DefaultEffects "to prevent any
                // bounce": the corner morph rides the effects spring.
                .kind = ui.anim.Animation.springAnim(.{ s.corner, 0, 0, 0 }, .{ target, 0, 0, 0 }, s.opts.theme.motion.springs.effects_spring, tl.channelVelocity(@ptrCast(&s.corner_channel))),
                .from = .{ s.corner, 0, 0, 0 },
                .channel = @ptrCast(&s.corner_channel),
                .on_update = .{ .fn_ptr = buttonCornerCb, .userdata = n },
            });
            return;
        }
    }
    s.corner = target;
}

fn buttonMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const d = dimsFor(s.opts.size);
    const pad = contentPadding(s.opts);
    var content_w: f32 = 0;
    var content_h: f32 = 0;
    var first = true;
    for (n.children.items) |child| {
        const cs = child.measure(c.deflateEdge(pad));
        if (!first) content_w += d.icon_gap;
        content_w += cs.w;
        content_h = @max(content_h, cs.h);
        first = false;
    }
    var size = Size{ .w = content_w + pad.hSum(), .h = content_h + pad.vSum() };
    size.h = @max(size.h, d.height); // the container height is the minimum
    // upstream: defaultMinSize(minWidth = MinWidth) in the shared Button()
    // composable — the 58dp floor applies to every size, not just small
    size.w = @max(size.w, min_width);
    return c.constrain(size);
}

fn buttonLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    const d = dimsFor(s.opts.size);
    const pad = contentPadding(s.opts);
    const inner = Rect{
        .x = bounds.x + pad.left,
        .y = bounds.y + pad.top,
        .w = @max(0, bounds.w - pad.hSum()),
        .h = @max(0, bounds.h - pad.vSum()),
    };
    // the content row: [icon, gap, label], centered in the padded box
    var sizes: [2]Size = .{ .{}, .{} };
    var content_w: f32 = 0;
    var content_h: f32 = 0;
    var count: usize = 0;
    for (n.children.items) |child| {
        const cs = child.measure(.{ .max_w = inner.w, .max_h = inner.h });
        sizes[count] = cs;
        content_w += cs.w;
        content_h = @max(content_h, cs.h);
        count += 1;
    }
    if (count > 1) content_w += d.icon_gap;
    var x = inner.x + (inner.w - content_w) / 2;
    for (n.children.items, 0..) |child, i| {
        const cs = sizes[i];
        child.layout(.{
            .x = x,
            .y = inner.y + (inner.h - cs.h) / 2,
            .w = cs.w,
            .h = cs.h,
        });
        x += cs.w;
        if (i + 1 < count) x += d.icon_gap;
    }
    // RTL: mirror the row around the inner box — the leading icon moves to
    // the end side (the gap is preserved)
    if (ui.i18n.direction() == .rtl) {
        for (n.children.items) |child| {
            child.bounds.x = inner.x + inner.w - (child.bounds.x - inner.x) - child.bounds.w;
        }
    }
}

/// The children (icon + label) paint clipped to the button's bounds: a
/// constrained button never lets its label ink cross the container edge.
fn buttonPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    ui.paint.clipRect(ctx, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h); // saves
}

fn buttonPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.clipReset(ctx); // restores
}

fn buttonChildClip(n: *Node) Rect {
    return n.bounds; // the bounds clip pushed in pre_children_paint
}

fn buttonPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const d = dimsFor(s.opts.size);
    const vc = variantColors(t, s.opts.variant);
    // No focus-gained vtable hook — poll the router (Tracker contract).
    // The button never requestFocus()es on pointer down, so every focus
    // entry is keyboard-provenance and visible to the state layer.
    s.inter.setFocused(input.isFocused(n));
    const pressed = s.inter.isPressed();
    // shape morph: the painted corner springs toward the press target
    // (AnimatedShape — pressed = the pressed corner, round and square
    // alike); the first paint snaps.
    if (s.corner < 0) s.corner = buttonCornerTarget(s, b.h);
    const radius: f32 = s.corner;
    // Elevation (upstream ButtonElevation state tables): filled/tonal are
    // flat except a Level-1 hover shadow (Hovered/HoverContainerElevation);
    // elevated rests at Level 1, lifts to Level 2 hovered, Level 1
    // pressed/focused, 0 disabled. Upstream reads the LAST interaction
    // (presses included — Button.kt:155's interactions.lastOrNull()): a
    // press always wins over an older hover, matching `!pressed` here.
    // Painted under the container so the state layer composites on top of it.
    if (s.opts.enabled) {
        const elev: f32 = switch (s.opts.variant) {
            .filled, .filled_tonal => if (s.inter.isHovered() and !pressed) 1 else 0,
            .elevated => if (s.inter.isHovered() and !pressed) 3 else 1,
            else => 0,
        };
        if (elev > 0) ui.paint.elevationShadow(ctx, b.x, b.y, b.w, b.h, radius, elev, t.colors.shadow);
    }
    // container
    const container = if (s.opts.enabled) vc.container else vc.disabled_container;
    if (container & 0xFF != 0) {
        ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, radius, container);
    }
    // outline (outlined variant) — upstream Surface draws the border into
    // the surface, then the indication composites OVER it (Surface.kt:
    // .surface(...) then .clickable(indication = ripple(...)))
    if (s.opts.variant == .outlined) {
        const oc = if (s.opts.enabled) vc.outline else vc.disabled_outline;
        ui.paint.strokeRRect(ctx, b.x, b.y, b.w, b.h, radius, d.outline_width, oc);
    }
    if (s.opts.enabled) {
        // The animated state layer: hover 0.08 / focus 0.10 over the
        // container AND the border; the pressed state is the ripple's ink,
        // not a static layer (RippleAnimation owns it upstream).
        s.layer.sync(&s.inter, vc.on);
        if (s.layer.paintColor()) |layer| {
            ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, radius, layer);
        }
        // Bounded ripple at the pressed alpha, clipped to the CURRENT
        // corner so the ink follows the pressed-shape morph.
        s.ripples.color = vc.on;
        s.ripples.pressed_alpha = t.state.pressed;
        s.ripples.paint(ctx, n, .{ .rrect = radius });
    }
}

fn buttonOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    switch (ev.phase) {
        .down => {
            // A second finger down replaces the press (the router could
            // deliver one while a press is still captured): upstream's
            // spawn finishes any live ripple; the tracker ends the stale
            // press entry the same way.
            s.inter.endPress();
            s.press_id = s.inter.pressDown(ev.x, ev.y);
            s.ripples.spawn(s.press_id, ev.x, ev.y, ev.time_ms);
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            buttonRetargetCorner(n, s); // the press morph springs
            return true;
        },
        .up => {
            // Click = down + up on the same node (the router captured us).
            // A cancelled press (outside_down, or a drag past the touch
            // slop) must not fire on a later up.
            const was_pressed = s.press_id != 0;
            if (was_pressed) {
                s.inter.release(s.press_id);
                s.ripples.release(s.press_id, ev.time_ms);
                s.press_id = 0;
            }
            buttonRetargetCorner(n, s); // release → morph back
            if (was_pressed and n.bounds.contains(ev.x, ev.y)) {
                if (s.on_pressed) |cb| cb.fn_ptr(cb.userdata);
            }
            return true;
        },
        .move => {
            // A drag beyond the touch slop is a scroll, not a press: cancel
            // the press interaction + finish its ripple. The move is NOT
            // claimed (return false) so it keeps bubbling to scrollable
            // ancestors (scroll_util.zig).
            if (s.press_id != 0) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.inter.cancel(s.press_id);
                    s.ripples.release(s.press_id, ev.time_ms); // upstream treats Cancel like Release
                    s.press_id = 0;
                    buttonRetargetCorner(n, s);
                }
            }
            return false;
        },
        // the pointer went down outside while we held the capture: cancel
        .outside_down => {
            if (s.press_id != 0) {
                s.inter.cancel(s.press_id);
                s.ripples.release(s.press_id, ev.time_ms);
                s.press_id = 0;
                buttonRetargetCorner(n, s);
            }
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

/// Keyboard activation (Phase 2c): Enter/Space press the focused button.
/// Upstream's keyPress mints a press interaction + a CENTERED bounded
/// ripple; Klaxon has no key-up events, so the press releases immediately
/// (the ripple still expands + fades out on its own timeline).
fn buttonOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            const b = n.bounds;
            const cx = b.x + b.w / 2;
            const cy = b.y + b.h / 2;
            const pid = s.inter.pressDown(cx, cy);
            s.ripples.spawn(pid, cx, cy, 0); // 0 = the timeline clock's now
            s.inter.release(pid);
            s.ripples.release(pid, 0);
            if (s.on_pressed) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        else => {},
    }
    return false;
}

fn buttonDeinit(n: *Node) void {
    const s = stateOf(n);
    if (ui.anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.corner_channel));
    s.layer.deinit();
    s.ripples.deinit(); // drops the timeline ticker before the state frees
    input.releaseNode(n);
    n.allocator.destroy(stateOf(n));
}

/// The interactive target: ≥ hit_target_min² centered on the button —
/// xsmall (32dp) and small (40dp) heights were below the a11y touch floor.
fn buttonHitBounds(n: *Node) Rect {
    const s = stateOf(n);
    const b = n.bounds;
    const w = @max(b.w, s.opts.theme.platform.hit_target_min);
    const h = @max(b.h, s.opts.theme.platform.hit_target_min);
    return .{
        .x = b.x + (b.w - w) / 2,
        .y = b.y + (b.h - h) / 2,
        .w = w,
        .h = h,
    };
}

const button_vtable = ui.node.VTable{
    .measure = buttonMeasure,
    .layout = buttonLayout,
    .paint = buttonPaint,
    .deinit = buttonDeinit,
    .on_pointer = buttonOnPointer,
    .on_key = buttonOnKey,
    .pre_children_paint = buttonPreChildrenPaint,
    .post_children_paint = buttonPostChildrenPaint,
    .child_clip = buttonChildClip,
    .hit_bounds = buttonHitBounds,
};

/// An M3E button. `on_pressed` fires on click (pointer up inside after a
/// down) and on Enter/Space while focused. The label and icon are internal
/// chrome built from the options (styled per the variant) — they are not
/// document children.
pub fn button(allocator: std.mem.Allocator, on_pressed: ?Callback, opts: ButtonOptions) !*Node {
    const node = try Node.create(allocator, &button_vtable);
    errdefer allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(ButtonState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .on_pressed = on_pressed };
    node.state = s;
    // Interaction machinery: the tracker + layer + ripples damage this node
    // on every mutation/tick (init-time wiring per the integration contract).
    s.inter.node = node;
    s.layer.node = node;
    s.layer.alphas = .{
        .hover = opts.theme.state.hover,
        .focus = opts.theme.state.focus,
        .pressed = opts.theme.state.pressed,
        .drag = opts.theme.state.drag,
    };
    s.ripples.node = node;
    const t = opts.theme;
    const d = dimsFor(opts.size);
    const vc = variantColors(t, opts.variant);
    const fg = if (opts.enabled) vc.on else vc.disabled_on;
    const ic = if (opts.icon) |iname| try icon_w.icon(allocator, iname, .{
        .size = if (opts.variant == .filled_tonal and opts.size == .small) tonal_icon_small else d.icon,
        .color = fg,
    }) else null;
    errdefer if (ic) |icn| icn.deinit();
    const txt = if (opts.label) |label| try text_w.text(allocator, label, .{
        .size = labelStyle(t, opts.size).size,
        .color = fg,
        .bold = labelStyle(t, opts.size).weight >= 500,
    }) else null;
    errdefer if (txt) |txtn| txtn.deinit();
    if (ic) |icn| {
        icn.internal = true; // chrome: not document data (registry)
        icn.exclude_semantics = true; // decorative: the button's label is the a11y name
        node.add(icn);
    }
    if (txt) |txtn| {
        txtn.internal = true;
        node.add(txtn);
    }
    ui.semantics.attach(node, .{
        .role = .button,
        .label = opts.label orelse opts.a11y_label orelse "",
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
        .actions = ui.semantics.Actions.initOne(.activate),
    });
    return node;
}

// --- tests ---

fn pressCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "button: every size measures its M3E container height (minimum)" {
    const sizes = [_]ButtonSize{ .xsmall, .small, .medium, .large, .xlarge };
    for (sizes) |sz| {
        const b = try button(std.testing.allocator, null, .{ .size = sz, .label = "OK" });
        defer b.deinit();
        const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
        try std.testing.expectEqual(dimsFor(sz).height, m.h);
    }
}

test "button: small hugs the content + 16dp padding and enforces the 58dp min width" {
    const b = try button(std.testing.allocator, null, .{ .label = "Add to cart" });
    defer b.deinit();
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    // label_large (14, weight 500 → bold) + 16dp horizontal padding
    const tw = ui.paint.measureText("Add to cart", 14, true).width;
    try std.testing.expect(tw + 32 > min_width); // this label exceeds the min width
    try std.testing.expectEqual(tw + 32, m.w);
    // a short label clamps to the 58dp min width
    const short = try button(std.testing.allocator, null, .{ .label = "OK" });
    defer short.deinit();
    const ms = short.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(min_width, ms.w);
    // an empty small button still measures the 58dp min width
    const empty = try button(std.testing.allocator, null, .{});
    defer empty.deinit();
    const me = empty.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(min_width, me.w);
    try std.testing.expectEqual(@as(f32, 40), me.h);
}

test "button: icon + label lay out centered with the size's icon gap" {
    const b = try button(std.testing.allocator, null, .{ .label = "OK", .icon = .star });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 200, .h = 40 });
    try std.testing.expectEqual(@as(usize, 2), b.children.items.len);
    const ic = b.children.items[0];
    const lb = b.children.items[1];
    try std.testing.expectEqual(@as(f32, 20), ic.bounds.w); // small icon token
    try std.testing.expectEqual(@as(f32, 20), ic.bounds.h);
    // the row [icon, 8, label] is centered in the padded box (200-32 wide)
    const content_w = ic.bounds.w + 8 + lb.bounds.w;
    try std.testing.expectEqual(16 + (168 - content_w) / 2, ic.bounds.x);
    try std.testing.expectEqual(ic.bounds.x + 20 + 8, lb.bounds.x);
    // vertically centered in the padded box (40-16 high)
    try std.testing.expectEqual(8 + (24 - 20) / 2, ic.bounds.y);
    try std.testing.expectEqual(8 + (24 - lb.bounds.h) / 2, lb.bounds.y);
}

test "button: press fires the callback; release outside does not; outside_down cancels" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = pressCounterCb, .userdata = &count };
    const b = try button(std.testing.allocator, cb, .{ .label = "OK" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 100, .h = 40 });
    const on_pointer = b.vtable.on_pointer.?;
    // down + up inside → fired
    _ = on_pointer(b, .{ .phase = .down, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    try std.testing.expect(stateOf(b).inter.isPressed());
    _ = on_pointer(b, .{ .phase = .up, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expect(!stateOf(b).inter.isPressed());
    // down inside, up outside → not fired
    _ = on_pointer(b, .{ .phase = .down, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    _ = on_pointer(b, .{ .phase = .up, .x = 500, .y = 20, .raw_x = 500, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), count);
    // down, then the pointer goes down outside (capture held): the press is
    // cancelled and a later up must not fire
    _ = on_pointer(b, .{ .phase = .down, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    try std.testing.expect(stateOf(b).inter.isPressed());
    _ = on_pointer(b, .{ .phase = .outside_down, .x = 500, .y = 20, .raw_x = 500, .raw_y = 20 });
    try std.testing.expect(!stateOf(b).inter.isPressed());
    _ = on_pointer(b, .{ .phase = .up, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), count);
    // a drag past the touch slop is a scroll: the press is cancelled and the
    // move is NOT claimed (bubbles to scrollable ancestors)
    _ = on_pointer(b, .{ .phase = .down, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    try std.testing.expect(stateOf(b).inter.isPressed());
    try std.testing.expect(!on_pointer(b, .{ .phase = .move, .x = 50, .y = 40, .raw_x = 50, .raw_y = 40 })); // 20px > slop
    try std.testing.expect(!stateOf(b).inter.isPressed());
    _ = on_pointer(b, .{ .phase = .up, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), count);
    // a small move within the slop keeps the press
    _ = on_pointer(b, .{ .phase = .down, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    _ = on_pointer(b, .{ .phase = .move, .x = 53, .y = 23, .raw_x = 53, .raw_y = 23 }); // ~4px < slop
    try std.testing.expect(stateOf(b).inter.isPressed());
    _ = on_pointer(b, .{ .phase = .up, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 2), count);
    // hover notifications toggle the hovered state
    _ = on_pointer(b, .{ .phase = .enter, .x = 50, .y = 20 });
    try std.testing.expect(stateOf(b).inter.isHovered());
    _ = on_pointer(b, .{ .phase = .leave, .x = 50, .y = 20 });
    try std.testing.expect(!stateOf(b).inter.isHovered());
}

test "button: icon-only buttons take their accessible name from a11y_label" {
    const b = try button(std.testing.allocator, null, .{ .icon = .star, .a11y_label = "Favorite" });
    defer b.deinit();
    try std.testing.expectEqualStrings("Favorite", b.semantics.?.label);
    try std.testing.expect(b.semantics.?.focusable);
    // no label, no a11y_label: empty name (the caller's responsibility)
    const bare = try button(std.testing.allocator, null, .{ .icon = .star });
    defer bare.deinit();
    try std.testing.expectEqualStrings("", bare.semantics.?.label);
    // the visible label wins over a11y_label
    const both = try button(std.testing.allocator, null, .{ .label = "OK", .a11y_label = "Other" });
    defer both.deinit();
    try std.testing.expectEqualStrings("OK", both.semantics.?.label);
}

test "button: RTL mirrors the content row (the leading icon moves to the end side)" {
    const i18n = try ui.i18n.I18n.init(std.testing.allocator, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    const b = try button(std.testing.allocator, null, .{ .label = "OK", .icon = .star });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 200, .h = 40 });
    const ic = b.children.items[0];
    const lb = b.children.items[1];
    // mirrored: the label is on the start (left) side, the icon on the end
    // (right) side, the 8dp gap preserved
    try std.testing.expect(ic.bounds.x > lb.bounds.x);
    try std.testing.expectEqual(lb.bounds.x + lb.bounds.w + 8, ic.bounds.x);
}

test "button: disabled swallows pointer input and fires nothing" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = pressCounterCb, .userdata = &count };
    const b = try button(std.testing.allocator, cb, .{ .label = "OK", .enabled = false });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 100, .h = 40 });
    const on_pointer = b.vtable.on_pointer.?;
    try std.testing.expect(!on_pointer(b, .{ .phase = .down, .x = 50, .y = 20 }));
    try std.testing.expect(!on_pointer(b, .{ .phase = .up, .x = 50, .y = 20 }));
    try std.testing.expect(!on_pointer(b, .{ .phase = .enter, .x = 50, .y = 20 }));
    try std.testing.expectEqual(@as(u32, 0), count);
    try std.testing.expect(!stateOf(b).inter.isPressed());
    try std.testing.expect(!stateOf(b).inter.isHovered());
}

test "button: Enter/Space activate the focused button (keyboard)" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = pressCounterCb, .userdata = &count };
    const b = try button(std.testing.allocator, cb, .{ .label = "OK" });
    defer b.deinit();
    const on_key = b.vtable.on_key.?;
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .enter }));
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .space }));
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expect(!on_key(b, .{ .kind = .key_down, .key = .left }));
    try std.testing.expect(!on_key(b, .{ .kind = .text_input, .key = .enter, .text = "x" }));
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "button: semantics — role button, focusable, disabled flag, activate action" {
    const b = try button(std.testing.allocator, null, .{ .label = "OK" });
    defer b.deinit();
    const sem = b.semantics.?;
    try std.testing.expectEqual(ui.semantics.Role.button, sem.role);
    try std.testing.expect(sem.focusable);
    try std.testing.expect(!sem.disabled);
    try std.testing.expectEqualStrings("OK", sem.label);
    try std.testing.expect(sem.actions.contains(.activate));
    const d = try button(std.testing.allocator, null, .{ .label = "OK", .enabled = false });
    defer d.deinit();
    try std.testing.expect(!d.semantics.?.focusable);
    try std.testing.expect(d.semantics.?.disabled);
}

test "golden: filled button paints the primary pill (round = height/2)" {
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    b.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // inside the pill, in the left padding zone (no label ink): primary
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(14, 30));
    // outside the pill: the top-left corner is clipped by the 20px radius
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(11, 11));
}

test "golden: outlined button strokes the outline_variant border, transparent inside" {
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .variant = .outlined, .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    // half-pixel offset: the 1dp stroke is centered on the edge → pixel-aligned
    b.layout(.{ .x = 10.5, .y = 10.5, .w = 100, .h = 40 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the top border, mid-edge: outline_variant
    try std.testing.expectEqual(t.colors.outline_variant, f.pixelAt(60, 10));
    // inside, away from the label ink: the container is transparent → bg
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(14, 30));
}

test "golden: hover paints the 0.08 state layer over the container" {
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    b.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    _ = b.vtable.on_pointer.?(b, .{ .phase = .enter, .x = 50, .y = 30 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the animated layer snaps to the full 0.08 without a timeline; the
    // pixel is the on-color src-over'd at that alpha (≈ the stateLayer
    // lerp, modulo rounding)
    try golden.expectPixelApprox(f, 14, 30, golden.blendOver(
        ui.paint.withAlphaScaled(t.colors.on_primary, t.state.hover),
        t.colors.primary,
    ));
}

test "golden: pressed morphs the round button to the pressed corner (8dp small)" {
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    b.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    // unpressed (radius 20): the (3,3) corner is outside the pill → bg
    r.paint(b, 0xFFFFFFFF);
    var f1 = try r.readback(std.testing.allocator);
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f1.pixelAt(13, 13));
    f1.deinit();
    // pressed (radius 8): the corner is inside. The pressed ink is the
    // ripple, which only paints through the animation timeline — without
    // one (ripple.zig's eval runs on the ticker) the press shows the
    // morphed shape + bare container here.
    _ = b.vtable.on_pointer.?(b, .{ .phase = .down, .x = 50, .y = 30 });
    r.paint(b, 0xFFFFFFFF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(13, 13));
}

test "golden: the press ripple expands from the touch point, clipped to the live corner" {
    var tl = ui.anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    ui.anim.setCurrent(&tl);
    defer ui.anim.setCurrent(null);
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    b.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    _ = b.vtable.on_pointer.?(b, .{ .phase = .down, .x = 50, .y = 30 }); // time_ms 0 = the clock's now
    tl.tick(300); // past fadeIn (75ms) + the 225ms radius expansion
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // fully open: on_primary @ 0.12 over primary, clipped to the PRESSED
    // corner (8) — (15,15) sits deep inside it, (11,11) outside both
    // corners (points ~1px off an AA edge are avoided intentionally)
    const ink = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_primary, t.state.pressed), t.colors.primary);
    try golden.expectPixelApprox(f, 14, 30, ink);
    try golden.expectPixelApprox(f, 15, 15, ink);
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(11, 11));
}

test "golden: Enter mints a centered bounded ripple (keyPress)" {
    var tl = ui.anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    ui.anim.setCurrent(&tl);
    defer ui.anim.setCurrent(null);
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    b.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    _ = b.vtable.on_key.?(b, .{ .kind = .key_down, .key = .enter });
    tl.tick(225); // expanded + still fully inked (release waits out fadeIn)
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // no press is held → the clip is the RESTING 20px corner; the ink is
    // centered on the bounds and covers the whole pill
    const ink = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_primary, t.state.pressed), t.colors.primary);
    try golden.expectPixelApprox(f, 14, 30, ink);
    try golden.expectPixelApprox(f, 96, 44, ink);
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(11, 11)); // outside the corner
}

test "golden: disabled filled button paints the OnSurface@0.10 container" {
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .label = "OK", .enabled = false, .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    b.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    r.paint(b, 0xFFFFFFFF); // white bg
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // src-over blend of on_surface@0.10 over white
    try golden.expectPixelApprox(f, 14, 30, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.10), 0xFFFFFFFF));
}

test "golden: text button hover paints the on-color at the state alpha (transparent container)" {
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .variant = .text, .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    b.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    _ = b.vtable.on_pointer.?(b, .{ .phase = .enter, .x = 50, .y = 30 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the layer is primary AT 0.08 (NOT lerped from transparent black — the
    // RGB must stay the full primary in the src-over blend)
    try golden.expectPixelApprox(f, 14, 30, golden.blendOver(ui.paint.withAlphaScaled(t.colors.primary, t.state.hover), 0xFFFFFFFF));
}

test "golden: a constrained button clips its label ink to the container bounds" {
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .label = "Add to cart", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    // 60 wide: the label's natural width (~70px) overflows the bounds
    b.layout(.{ .x = 10, .y = 10, .w = 60, .h = 40 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // just outside the right edge: no label ink (the children paint clipped)
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(72, 30));
}
