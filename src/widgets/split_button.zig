// An M3E split button (filled style): a leading action button + a trailing
// toggle button (the dropdown arrow), joined with a 2dp gap; both are
// Primary/OnPrimary pills whose INNER corners (where they meet) use the
// size's InnerCornerCornerSize (ExtraSmall→Medium by size) and morph to
// InnerPressedCornerCornerSize while that half is pressed.
//
// Spec: m3.material.io/components/split-buttons + Compose SplitButton.kt
// (SplitButtonLayout / SplitButtonDefaults.LeadingButton / TrailingButton)
// + SplitButton{XSmall,Small,Medium,Large,XLarge}Tokens:
//   - sizes (height / leading pad L+R / trailing icon / trailing pad L=R):
//     XS 32 / 12+10 / 22 / 13; S 40 / 16+12 / 22 / 13; M 56 / 24+24 / 26 / 15;
//     L 96 / 48+48 / 38 / 29; XL 136 / 64+64 / 50 / 43
//   - BetweenSpace = 2dp; LeadingButtonMinWidth = TrailingButtonMinWidth = 48
//   - leading button: label label_large + optional leading icon at the
//     size's iconSizeFor (20/20/24/32/40) with the size's iconSpacingFor
//     gap (4/8/8/12/16), centered; trailing button: the trailing icon
//     centered
//   - shapes: both CornerFull (pill = h/2) on the OUTER corners; the inner
//     corners (leading's end / trailing's start) = InnerCornerCornerSize —
//     4/4/4/8/12 (XS/S/M/L/XL). The PRESSED half morphs its inner corners
//     to InnerPressedCornerCornerSize — 8/12/12/20/20 — on the effects
//     spring (upstream's rememberAnimatedShape). The CHECKED trailing
//     half morphs to CircleShape and fills it with contentColor@0.12
//     (upstream's drawWithContent scrim over the content).
//   - colors: filled = Primary container + OnPrimary content; disabled =
//     container OnSurface @ 0.10, content OnSurfaceVariant @ 0.38 (same as
//     the M3E filled button)
//   - state layer: OnPrimary @ hover 0.08 / focus 0.10 / pressed 0.12 over
//     the container, per half
//   - input: each half is its own press zone (a drag past the touch slop is
//     a scroll, not a press); Enter/Space fires the LEADING action,
//     ArrowDown the trailing (ARIA menu-button); a11y exposes the two
//     halves as virtual button children whose activation taps land in the
//     half's zone
//
// v1 deviations (documented):
//   - Filled style only (tonal / elevated / outlined variants are
//     follow-ups — same structure, different colors).
//   - The trailing icon sits at the geometric center — upstream nudges it
//     toward the gap via an optical-centering modifier we can't reproduce
//     without its private source.
//   - No embedded menu: the trailing button fires `on_trailing` and the app
//     opens a menu and drives `trailing_checked` (the M3E menu widget,
//     PR D2).
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

pub const SplitButtonSize = enum { xsmall, small, medium, large, xlarge };

pub const SplitButtonOptions = struct {
    size: SplitButtonSize = .small,
    enabled: bool = true,
    label: []const u8 = "",
    /// Optional leading icon (20dp, in the label color; mirrors to the end
    /// side in RTL).
    leading_icon: ?icon_w.IconName = null,
    trailing_icon: icon_w.IconName = .arrow_down,
    /// The trailing half's a11y label (upstream contentDescription — the
    /// trailing button is its own semantic node).
    trailing_label: []const u8 = "Expand",
    /// The trailing half's initial checked state (upstream `checked` —
    /// the app drives it as its menu opens/closes via
    /// splitSetTrailingChecked; checked morphs the half to a circle and
    /// paints the content-color state layer).
    trailing_checked: bool = false,
    theme: Theme = theme_mod.light,
};

/// Per-size tokens (SplitButton*Tokens + leadingButtonIconSizeFor =
/// ButtonDefaults.iconSizeFor + the leading icon's iconSpacingFor gap +
/// the size's InnerCornerCornerSize / InnerPressedCornerCornerSize).
const Dims = struct {
    height: f32,
    lead_pad_l: f32,
    lead_pad_r: f32,
    trail_icon: f32,
    trail_pad: f32,
    inner_rest: f32, // InnerCornerCornerSize
    inner_pressed: f32, // InnerPressedCornerCornerSize (the pressed half morphs)
    lead_icon: f32, // leadingButtonIconSizeFor (= Button's iconSizeFor)
    lead_icon_gap: f32, // icon-label gap (= iconSpacingFor)
};

fn dimsFor(size: SplitButtonSize) Dims {
    return switch (size) {
        .xsmall => .{ .height = 32, .lead_pad_l = 12, .lead_pad_r = 10, .trail_icon = 22, .trail_pad = 13, .inner_rest = 4, .inner_pressed = 8, .lead_icon = 20, .lead_icon_gap = 4 },
        .small => .{ .height = 40, .lead_pad_l = 16, .lead_pad_r = 12, .trail_icon = 22, .trail_pad = 13, .inner_rest = 4, .inner_pressed = 12, .lead_icon = 20, .lead_icon_gap = 8 },
        .medium => .{ .height = 56, .lead_pad_l = 24, .lead_pad_r = 24, .trail_icon = 26, .trail_pad = 15, .inner_rest = 4, .inner_pressed = 12, .lead_icon = 24, .lead_icon_gap = 8 },
        .large => .{ .height = 96, .lead_pad_l = 48, .lead_pad_r = 48, .trail_icon = 38, .trail_pad = 29, .inner_rest = 8, .inner_pressed = 20, .lead_icon = 32, .lead_icon_gap = 12 },
        .xlarge => .{ .height = 136, .lead_pad_l = 64, .lead_pad_r = 64, .trail_icon = 50, .trail_pad = 43, .inner_rest = 12, .inner_pressed = 20, .lead_icon = 40, .lead_icon_gap = 16 },
    };
}

const min_w: f32 = 48; // LeadingButtonMinWidth = TrailingButtonMinWidth
// The a11y touch-target floor is theme.platform.hit_target_min (48 mobile /
// 24 desktop) — read from s.opts.theme where used.
const between: f32 = 2; // BetweenSpace

const SplitState = struct {
    label: [:0]const u8, // owned
    opts: SplitButtonOptions,
    on_press: ?Callback = null,
    on_trailing: ?Callback = null,
    /// The pressed half: 0 = none, 1 = leading, 2 = trailing.
    pressed: u8 = 0,
    hovered: u8 = 0,
    /// The trailing half's checked state (upstream `checked` on the
    /// TrailingButton — morphs to CircleShape + the contentColor@0.12
    /// overlay). splitSetTrailingChecked drives it.
    trailing_checked: bool = false,
    /// The halves' CURRENT inner corner radii — upstream's
    /// rememberAnimatedShape morphs the corner SIZE between rest /
    /// pressed / checked(circle) via the effects spring; these carry the
    /// live value (snapped when no timeline exists).
    lead_inner: f32 = 0,
    trail_inner: f32 = 0,
    lead_chan: u8 = 0, // channel markers (stable addresses)
    trail_chan: u8 = 0,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — gestures.SLOP).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
    /// The two halves as virtual a11y children (upstream: two sibling
    /// composables — TalkBack/VoiceOver focus each half separately).
    /// Fixed-size: the halves never change count; the slice is borrowed.
    sem_children: [2]ui.semantics.Semantics = undefined,
};

fn stateOf(n: *Node) *SplitState {
    return @ptrCast(@alignCast(n.state.?));
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

/// The trailing half's width (fixed: max(48, 2*pad + icon)).
fn trailWidth(s: *SplitState) f32 {
    const d = dimsFor(s.opts.size);
    return @max(min_w, d.trail_pad * 2 + d.trail_icon);
}

/// The press zone under the point: 0 = none (outside the button or in the
/// gap), 1 = leading, 2 = trailing.
fn zoneAt(s: *SplitState, b: Rect, x: f32, y: f32) u8 {
    if (y < b.y or y >= b.y + b.h) return 0;
    const rtl = ui.i18n.direction() == .rtl;
    const lx = if (rtl) b.x + b.w - (x - b.x) else x; // the point in LTR space
    if (lx < b.x or lx >= b.x + b.w) return 0; // outside horizontally
    const tw = trailWidth(s);
    const lead_w = @max(b.w - between - tw, 0);
    if (lx < b.x + lead_w) return 1; // the leading half
    if (lx < b.x + lead_w + between) return 0; // the 2dp gap: no zone
    return 2; // the trailing half
}

fn splitMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const t = s.opts.theme;
    const d = dimsFor(s.opts.size);
    const ls = t.type_scale.label_large;
    const bold = ls.weight >= 500;
    var lead_w = d.lead_pad_l + d.lead_pad_r + ui.paint.measureText(s.label, ls.size, bold).width;
    if (s.opts.leading_icon != null) lead_w += d.lead_icon + d.lead_icon_gap;
    lead_w = @max(lead_w, min_w);
    const tw = trailWidth(s);
    return c.constrain(.{ .w = lead_w + between + tw, .h = d.height });
}

fn splitLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: the halves are computed from the bounds at paint/hit
}

/// The leading half's inner-corner target (upstream shapeByInteraction —
/// pressed wins; the leading button has no checkedShape).
fn leadInnerTarget(s: *SplitState) f32 {
    const d = dimsFor(s.opts.size);
    return if (s.pressed == 1) d.inner_pressed else d.inner_rest;
}

/// The trailing half's inner-corner target: pressed wins, else the
/// checked state morphs to CircleShape (h/2), else InnerCornerSize.
fn trailInnerTarget(s: *SplitState) f32 {
    const d = dimsFor(s.opts.size);
    if (s.pressed == 2) return d.inner_pressed;
    if (s.trailing_checked) return d.height / 2;
    return d.inner_rest;
}

fn leadInnerCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).lead_inner = v[0];
    n.markDirty();
}

fn trailInnerCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).trail_inner = v[0];
    n.markDirty();
}

/// Retarget a half's inner corner on the effects spring (upstream's
/// rememberAnimatedShape). Mid-flight retargets carry the channel
/// velocity; no timeline → snap.
fn morphInner(n: *Node, s: *SplitState, trailing: bool) void {
    const target = if (trailing) trailInnerTarget(s) else leadInnerTarget(s);
    const val = if (trailing) &s.trail_inner else &s.lead_inner;
    const chan = if (trailing) &s.trail_chan else &s.lead_chan;
    if (val.* == target) return;
    if (ui.anim.timeline()) |tl| {
        const from: ui.anim.Vec4 = .{ val.*, 0, 0, 0 };
        _ = tl.play(.{
            .kind = ui.anim.Animation.springAnim(from, .{ target, 0, 0, 0 }, s.opts.theme.motion.springs.effects_spring, tl.channelVelocity(@ptrCast(chan))),
            .from = from,
            .channel = @ptrCast(chan),
            .on_update = .{ .fn_ptr = if (trailing) trailInnerCb else leadInnerCb, .userdata = n },
        });
    } else {
        val.* = target;
        n.markDirty();
    }
}

/// Drive the trailing half's checked state (upstream `checked` — the app
/// calls this when its menu opens/closes): morphs to CircleShape and
/// syncs the a11y child's `checked`.
pub fn splitSetTrailingChecked(n: *Node, checked: bool) void {
    const s = stateOf(n);
    if (s.trailing_checked == checked) return;
    s.trailing_checked = checked;
    morphInner(n, s, true);
    s.sem_children[1].checked = checked;
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

/// The trailing half's checked state (pub accessor).
pub fn splitTrailingChecked(n: *Node) bool {
    return stateOf(n).trailing_checked;
}

/// Paint an icon centered in a size x size box — vector geometry (icon.zig),
/// not a font glyph (emoji-capable codepoints bypass the theme ink).
fn paintIcon(ctx: *kx.Ctx, name: icon_w.IconName, x: f32, y: f32, size: f32, color: Color) void {
    if (color & 0xFF == 0) return;
    icon_w.drawIcon(ctx, name, x, y, size / 24.0, color);
}

fn splitPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const d = dimsFor(s.opts.size);
    const cs = t.colors;
    const rtl = ui.i18n.direction() == .rtl;
    const focused = input.isFocused(n);
    const half = b.h / 2; // CornerFull on the outer corners
    const tw = trailWidth(s);
    const lead_w = @max(b.w - between - tw, 0); // never negative (constrained)
    // LTR: leading [0, lead_w), gap, trailing [lead_w + between, w)
    const lead_x = b.x;
    const trail_x = b.x + lead_w + between;
    const mirror = struct {
        fn f(bx: f32, bw: f32, x: f32, w: f32, rtl_flag: bool) f32 {
            return if (rtl_flag) bx + bw - (x - bx) - w else x;
        }
    }.f;
    const lx = mirror(b.x, b.w, lead_x, lead_w, rtl);
    const tx = mirror(b.x, b.w, trail_x, tw, rtl);
    const container: Color = if (s.opts.enabled) cs.primary else ui.paint.withAlphaScaled(cs.on_surface, 0.10);
    const fg: Color = if (s.opts.enabled) cs.on_primary else ui.paint.withAlphaScaled(cs.on_surface_variant, 0.38);
    const ls = t.type_scale.label_large;
    const bold = ls.weight >= 500;
    // --- the leading half: pill on the start side, the size's inner corner
    // on the end (s.lead_inner morphs rest ↔ pressed on the effects
    // spring — upstream's rememberAnimatedShape). Its content is clipped
    // to the half (a constrained width never bleeds into the trailing half
    // or outside the node).
    const lead_inner: f32 = s.lead_inner;
    if (lead_w > 0) {
        var tl: f32 = half;
        var tr: f32 = lead_inner;
        var br: f32 = lead_inner;
        var bl: f32 = half;
        if (rtl) {
            const t2 = tl;
            tl = tr;
            tr = t2;
            const b2 = bl;
            bl = br;
            br = b2;
        }
        ui.paint.clipRect(ctx, lx, b.y, lead_w, b.h); // saves
        if (container & 0xFF != 0) ui.paint.fillRRectCorners(ctx, lx, b.y, lead_w, b.h, tl, tr, br, bl, container);
        if (s.opts.enabled) {
            const alpha: f32 = if (s.pressed == 1)
                t.state.pressed
            else if (focused)
                t.state.focus
            else if (s.hovered == 1)
                t.state.hover
            else
                0;
            if (alpha > 0) {
                ui.paint.fillRRectCorners(ctx, lx, b.y, lead_w, b.h, tl, tr, br, bl, theme_mod.stateLayer(container, cs.on_primary, alpha));
            }
        }
        // content: [icon, gap, label] centered (mirrored in RTL: the leading
        // icon moves to the end side)
        const lm = ui.paint.measureText(s.label, ls.size, bold);
        var content_w = lm.width;
        if (s.opts.leading_icon != null) content_w += d.lead_icon + d.lead_icon_gap;
        var icon_x = lx + (lead_w - content_w) / 2;
        var label_x = icon_x;
        if (s.opts.leading_icon != null) label_x += d.lead_icon + d.lead_icon_gap;
        if (rtl) {
            icon_x = mirror(lx, lead_w, icon_x, d.lead_icon, true);
            label_x = mirror(lx, lead_w, label_x, lm.width, true);
        }
        const baseline = b.y + (b.h - lm.height) / 2 + lm.ascent;
        if (s.opts.leading_icon) |iname| {
            paintIcon(ctx, iname, icon_x, b.y + (b.h - d.lead_icon) / 2, d.lead_icon, fg);
        }
        ui.paint.text(ctx, s.label, label_x, baseline, ls.size, bold, fg);
        ui.paint.clipReset(ctx); // restores
    }
    // --- the trailing half: the size's inner corner on the start side
    // (s.trail_inner morphs rest ↔ pressed ↔ checked-circle on the
    // effects spring), pill on the end, clipped to the node's right edge
    // (a width below the halves' minimum never paints outside the node)
    const trail_inner: f32 = s.trail_inner;
    const tclip_w = @max(@min(tw, b.x + b.w - tx), 0);
    if (tclip_w > 0) {
        var tl: f32 = trail_inner;
        var tr: f32 = half;
        var br: f32 = half;
        var bl: f32 = trail_inner;
        if (rtl) {
            const t2 = tl;
            tl = tr;
            tr = t2;
            const b2 = bl;
            bl = br;
            br = b2;
        }
        ui.paint.clipRect(ctx, tx, b.y, tclip_w, b.h); // saves
        if (container & 0xFF != 0) ui.paint.fillRRectCorners(ctx, tx, b.y, tw, b.h, tl, tr, br, bl, container);
        if (s.opts.enabled) {
            const alpha: f32 = if (s.pressed == 2)
                t.state.pressed
            else if (focused)
                t.state.focus
            else if (s.hovered == 2)
                t.state.hover
            else
                0;
            if (alpha > 0) {
                ui.paint.fillRRectCorners(ctx, tx, b.y, tw, b.h, tl, tr, br, bl, theme_mod.stateLayer(container, cs.on_primary, alpha));
            }
        }
        paintIcon(ctx, s.opts.trailing_icon, tx + (tw - d.trail_icon) / 2, b.y + (b.h - d.trail_icon) / 2, d.trail_icon, fg);
        // upstream drawWithContent: the checked trailing button fills its
        // (circle) shape with contentColor @ pressed opacity — a scrim
        // over the half, content included
        if (s.opts.enabled and s.trailing_checked) {
            ui.paint.fillRRectCorners(ctx, tx, b.y, tw, b.h, tl, tr, br, bl, ui.paint.withAlphaScaled(cs.on_primary, t.state.pressed));
        }
        ui.paint.clipReset(ctx); // restores
    }
}

fn splitOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    const zone = zoneAt(s, n.bounds, ev.x, ev.y);
    switch (ev.phase) {
        .down => {
            if (zone == 0) return false;
            s.pressed = zone;
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            morphInner(n, s, true); // the pressed half morphs (both, a
            morphInner(n, s, false); // direct 1→2 switch unmorphs the other)
            n.markDirty();
            return true;
        },
        .up => {
            const was = s.pressed;
            s.pressed = 0;
            morphInner(n, s, true);
            morphInner(n, s, false);
            n.markDirty();
            if (was != 0 and zone == was) {
                if (was == 1) {
                    if (s.on_press) |cb| cb.fn_ptr(cb.userdata);
                } else {
                    if (s.on_trailing) |cb| cb.fn_ptr(cb.userdata);
                }
            }
            return true;
        },
        .move => {
            // A drag beyond the touch slop is a scroll, not a press: cancel
            // the pressed state. The move is NOT claimed (return false) so
            // it keeps bubbling to scrollable ancestors.
            if (s.pressed != 0) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.pressed = 0;
                    morphInner(n, s, true);
                    morphInner(n, s, false);
                    n.markDirty();
                }
            }
            return false;
        },
        // the pointer went down outside while we held the capture: cancel
        .outside_down => {
            s.pressed = 0;
            morphInner(n, s, true);
            morphInner(n, s, false);
            n.markDirty();
            return true;
        },
        .enter => {
            s.hovered = zone;
            n.markDirty();
            return true;
        },
        // moving across the halves within the leaf emits hover_move (not
        // enter/leave): re-resolve the zone under the pointer
        .hover_move => {
            const z = zoneAt(s, n.bounds, ev.x, ev.y);
            if (z != s.hovered) {
                s.hovered = z;
                n.markDirty();
            }
            return true;
        },
        .leave => {
            s.hovered = 0;
            n.markDirty();
            return true;
        },
    }
    return false;
}

/// Half `index`'s rect in NODE-LOCAL space (Semantics.child_bounds — the
/// a11y bridge maps it to window space; an activation tap lands in the
/// half's zone and the pointer path resolves it like a real click).
fn splitChildBounds(n: *Node, index: usize) Rect {
    const s = stateOf(n);
    const b = n.bounds;
    const local = Rect{ .x = 0, .y = 0, .w = b.w, .h = b.h };
    const tw = trailWidth(s);
    const lead_w = @max(b.w - between - tw, 0);
    var r: Rect = if (index == 0)
        .{ .x = 0, .y = 0, .w = lead_w, .h = local.h }
    else
        .{ .x = lead_w + between, .y = 0, .w = @max(local.w - lead_w - between, 0), .h = local.h };
    if (ui.i18n.direction() == .rtl) r = .{ .x = local.w - r.x - r.w, .y = r.y, .w = r.w, .h = r.h };
    return r;
}

/// Keyboard activation: Enter/Space fire the leading action; ArrowDown
/// fires the trailing action — the ARIA menu-button pattern (the trailing
/// icon is a chevron-down; the half opens the menu).
fn splitOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            if (s.on_press) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        .down => {
            if (s.on_trailing) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        else => {},
    }
    return false;
}

fn splitDeinit(n: *Node) void {
    const s = stateOf(n);
    if (ui.anim.timeline()) |tl| {
        tl.cancelChannel(@ptrCast(&s.lead_chan)); // the update cbs point at this node
        tl.cancelChannel(@ptrCast(&s.trail_chan));
    }
    input.releaseNode(n);
    n.allocator.free(s.label);
    n.allocator.destroy(s);
}

/// The interactive target: ≥ hit_target_min tall centered on the button —
/// the 40dp halves were below the a11y touch floor.
fn splitHitBounds(n: *Node) Rect {
    const s = stateOf(n);
    const b = n.bounds;
    const h = @max(b.h, s.opts.theme.platform.hit_target_min);
    return .{
        .x = b.x,
        .y = b.y + (b.h - h) / 2,
        .w = b.w,
        .h = h,
    };
}

const split_vtable = ui.node.VTable{
    .measure = splitMeasure,
    .layout = splitLayout,
    .paint = splitPaint,
    .deinit = splitDeinit,
    .on_pointer = splitOnPointer,
    .on_key = splitOnKey,
    .hit_bounds = splitHitBounds,
};

/// An M3E split button (filled style). The two halves are internal chrome
/// painted by the widget (a leaf — no document children). `on_press` fires
/// on a leading-half click (and on Enter/Space while focused);
/// `on_trailing` fires on a trailing-half click (the app opens a menu).
pub fn splitButton(allocator: std.mem.Allocator, on_press: ?Callback, on_trailing: ?Callback, opts: SplitButtonOptions) !*Node {
    const node = try Node.create(allocator, &split_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(SplitState);
    errdefer allocator.destroy(s);
    const label = try dupeZ(allocator, opts.label);
    errdefer allocator.free(label);
    s.* = .{
        .label = label,
        .opts = opts,
        .on_press = on_press,
        .on_trailing = on_trailing,
        .trailing_checked = opts.trailing_checked,
    };
    node.state = s;
    // the initial corners are settled — no construction animation
    s.lead_inner = leadInnerTarget(s);
    s.trail_inner = trailInnerTarget(s);
    // The two halves as a11y children — TalkBack/VoiceOver expose the
    // trailing button separately like upstream's two composables, and an
    // activate lands in its zone (resolved by the pointer path).
    s.sem_children = .{
        .{ .role = .button, .label = s.label, .disabled = !opts.enabled, .actions = ui.semantics.Actions.initOne(.activate) },
        .{ .role = .button, .label = s.opts.trailing_label, .checked = s.trailing_checked, .disabled = !opts.enabled, .actions = ui.semantics.Actions.initOne(.activate) },
    };
    ui.semantics.attach(node, .{
        .role = .button,
        .label = s.label,
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
        .actions = ui.semantics.Actions.initOne(.activate),
        .children = &s.sem_children,
        .child_bounds = splitChildBounds,
    }); // Phase 2c
    return node;
}

// --- tests ---

fn pressCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "split_button: measures the two halves + the gap; the container height per size" {
    const a = std.testing.allocator;
    const n = try splitButton(a, null, null, .{ .label = "Save" });
    defer n.deinit();
    const t = theme_mod.light;
    const ls = t.type_scale.label_large;
    const d = dimsFor(.small);
    const lead_w = @max(min_w, d.lead_pad_l + d.lead_pad_r + ui.paint.measureText("Save", ls.size, true).width);
    const tw = @max(min_w, d.trail_pad * 2 + d.trail_icon);
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(lead_w + between + tw, sz.w, 0.001);
    try std.testing.expectEqual(d.height, sz.h);
    // every size's height
    const sizes = [_]SplitButtonSize{ .xsmall, .small, .medium, .large, .xlarge };
    const heights = [_]f32{ 32, 40, 56, 96, 136 };
    for (sizes, heights) |sz2, h| {
        const b = try splitButton(a, null, null, .{ .size = sz2, .label = "OK" });
        defer b.deinit();
        const m = b.measure(.{ .max_w = 4000, .max_h = 4000 });
        try std.testing.expectEqual(h, m.h);
    }
}

test "split_button: the leading and trailing halves fire their callbacks; keyboard fires the leading" {
    var lead: u32 = 0;
    var trail: u32 = 0;
    const cb_lead = Callback{ .fn_ptr = pressCounterCb, .userdata = &lead };
    const cb_trail = Callback{ .fn_ptr = pressCounterCb, .userdata = &trail };
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try splitButton(a, cb_lead, cb_trail, .{ .label = "Save" });
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    n.layout(.{ .x = 0, .y = 0, .w = sz.w, .h = sz.h });
    const tw = trailWidth(stateOf(n));
    const lead_w = sz.w - between - tw;
    // click the leading half
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = lead_w / 2, .y = 20, .raw_x = lead_w / 2, .raw_y = 20 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = lead_w / 2, .y = 20, .raw_x = lead_w / 2, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), lead);
    try std.testing.expectEqual(@as(u32, 0), trail);
    // click the trailing half
    const tx = lead_w + between + tw / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = tx, .y = 20, .raw_x = tx, .raw_y = 20 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = tx, .y = 20, .raw_x = tx, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), lead);
    try std.testing.expectEqual(@as(u32, 1), trail);
    // a click that crosses halves (down on leading, up on trailing) fires nothing
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = lead_w / 2, .y = 20, .raw_x = lead_w / 2, .raw_y = 20 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = tx, .y = 20, .raw_x = tx, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), lead);
    try std.testing.expectEqual(@as(u32, 1), trail);
    // keyboard: Enter fires the leading action; ArrowDown the trailing
    // (the ARIA menu-button pattern — the trailing half opens the menu)
    input.requestFocus(n);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 2), lead);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    try std.testing.expectEqual(@as(u32, 2), trail);
    // a11y: the two halves are virtual button children; an activation tap
    // in the trailing child's rect resolves through the pointer path
    try std.testing.expectEqual(@as(usize, 2), n.semantics.?.children.len);
    try std.testing.expectEqualStrings("Expand", n.semantics.?.children[1].label);
    const tr = n.semantics.?.child_bounds.?(n, 1);
    try std.testing.expectApproxEqAbs(lead_w + between, tr.x, 0.001);
    try std.testing.expectApproxEqAbs(tw, tr.w, 0.001);
    // disabled: no interaction
    const dis = try splitButton(a, cb_lead, cb_trail, .{ .label = "Save", .enabled = false });
    defer dis.deinit();
    dis.layout(.{ .x = 0, .y = 0, .w = sz.w, .h = sz.h });
    try std.testing.expect(!dis.vtable.on_pointer.?(dis, .{ .phase = .down, .x = lead_w / 2, .y = 20, .raw_x = lead_w / 2, .raw_y = 20 }));
}

test "golden: the split button paints two Primary halves with a gap and ExtraSmall inner corners" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try splitButton(a, null, null, .{ .label = "Save", .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 80);
    defer r.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    // integer width: the halves land on integer edges (exact corner pixels)
    n.layout(.{ .x = 20, .y = 20, .w = @round(sz.w), .h = sz.h });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const tw = trailWidth(stateOf(n));
    const lead_w = @round(sz.w) - between - tw;
    // the leading half's fill: Primary at its start side (clear of the
    // centered label ink)
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(24, 40));
    // the trailing half's fill: Primary near its end edge (clear of the
    // centered trailing icon)
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(20 + @as(i32, @intFromFloat(lead_w + between + tw)) - 4, 40));
    // the 2dp gap between the halves: background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20 + @as(i32, @intFromFloat(lead_w)) + 1, 40));
    // the leading half's outer (start) corner: pill (radius h/2 = 20) — the
    // exact corner stays background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20, 20));
    // the leading half's INNER (end) corner: ExtraSmall 4dp — the exact corner
    // is cut (background), 4dp down it is filled
    const lead_end = 20 + @as(i32, @intFromFloat(lead_w)); // the end edge
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(lead_end - 1, 20));
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(lead_end - 2, 24));
}

test "golden: a hovered trailing half paints the on_primary state layer" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try splitButton(a, null, null, .{ .label = "Save", .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 80);
    defer r.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    n.layout(.{ .x = 20, .y = 20, .w = sz.w, .h = sz.h });
    const tw = trailWidth(stateOf(n));
    const lead_w = sz.w - between - tw;
    const tx = lead_w + between + tw - 4; // near the trailing half's end edge (no icon ink)
    _ = n.vtable.on_pointer.?(n, .{ .phase = .enter, .x = 20 + tx, .y = 40 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try golden.expectPixelApprox(f, 20 + @as(i32, @intFromFloat(tx)), 40, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_primary, t.state.hover), t.colors.primary));
}

test "split_button: releases outside the button or in the gap fire nothing" {
    var lead: u32 = 0;
    var trail: u32 = 0;
    const cb_lead = Callback{ .fn_ptr = pressCounterCb, .userdata = &lead };
    const cb_trail = Callback{ .fn_ptr = pressCounterCb, .userdata = &trail };
    const a = std.testing.allocator;
    const n = try splitButton(a, cb_lead, cb_trail, .{ .label = "Save" });
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    n.layout(.{ .x = 100, .y = 20, .w = @round(sz.w), .h = sz.h });
    const tw = trailWidth(stateOf(n));
    const lead_w = @round(sz.w) - between - tw;
    // a release beyond the LEFT edge (down on the leading half, up outside)
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 110, .y = 40, .raw_x = 110, .raw_y = 40 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 90, .y = 40, .raw_x = 90, .raw_y = 40 });
    try std.testing.expectEqual(@as(u32, 0), lead);
    // a release beyond the RIGHT edge (down on the trailing half, up outside)
    const tx = 100 + lead_w + between + tw / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = tx, .y = 40, .raw_x = tx, .raw_y = 40 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 100 + @as(f32, @floatFromInt(@as(i32, @intFromFloat(@round(sz.w))))) + 30, .y = 40, .raw_x = 130, .raw_y = 40 });
    try std.testing.expectEqual(@as(u32, 0), trail);
    // a click in the 2dp GAP fires nothing
    const gx = 100 + lead_w + 1;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = gx, .y = 40, .raw_x = gx, .raw_y = 40 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = gx, .y = 40, .raw_x = gx, .raw_y = 40 });
    try std.testing.expectEqual(@as(u32, 0), lead);
    try std.testing.expectEqual(@as(u32, 0), trail);
    // hover_move re-resolves the half under the pointer
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.dispatchPointer(n, .{ .phase = .move, .x = 110, .y = 40 });
    try std.testing.expectEqual(@as(u8, 1), stateOf(n).hovered);
    router.dispatchPointer(n, .{ .phase = .move, .x = tx, .y = 40 });
    try std.testing.expectEqual(@as(u8, 2), stateOf(n).hovered);
    router.dispatchPointer(n, .{ .phase = .move, .x = gx, .y = 40 });
    try std.testing.expectEqual(@as(u8, 0), stateOf(n).hovered); // the gap: no zone
}

test "golden: a width below the halves' minimum clips (no paint outside the node)" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try splitButton(a, null, null, .{ .label = "Save", .theme = t });
    defer n.deinit();
    // 30 < between(2) + trail_w(48): the trailing half is clipped at the edge
    n.layout(.{ .x = 20, .y = 20, .w = 30, .h = 40 });
    var r = try golden.Renderer.init(std.testing.allocator, 200, 80);
    defer r.deinit();
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the trailing half's fill shows (clipped): primary inside the node
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(30, 40));
    // nothing beyond the node's right edge (x = 50)
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(51, 40));
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(51, 25));
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(60, 40));
}

test "split_button: RTL mirrors the content row (the leading icon moves to the end side)" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const i18n = try ui.i18n.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    const n = try splitButton(a, null, null, .{ .label = "Save", .leading_icon = .star, .theme = t });
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    const bw = @round(sz.w);
    n.layout(.{ .x = 20, .y = 20, .w = bw, .h = sz.h });
    var r = try golden.Renderer.init(a, 220, 80);
    defer r.deinit();
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    // the content row's geometry as the widget computes it (LTR), then the
    // widget-mirrored positions the RTL paint must use
    const ls = t.type_scale.label_large;
    const lm = ui.paint.measureText("Save", ls.size, true);
    const tw = trailWidth(stateOf(n));
    const lead_w = bw - between - tw;
    const dd = dimsFor(.small); // the default size
    const content_w = dd.lead_icon + dd.lead_icon_gap + lm.width;
    const cx = 20 + (lead_w - content_w) / 2; // the icon's LTR x
    // the icon lands at the mirrored position (the end side of the content row)
    const icon_x = 2 * 20 + bw - cx - dd.lead_icon;
    try std.testing.expect(f.countColorIn(.{ .x = icon_x, .y = 20 + (sz.h - dd.lead_icon) / 2, .w = dd.lead_icon, .h = dd.lead_icon }, t.colors.on_primary) > 0);
    // the label lands at its mirrored position (before the icon)
    const label_x = 2 * 20 + bw - (cx + dd.lead_icon + dd.lead_icon_gap) - lm.width;
    try std.testing.expect(label_x < icon_x); // the icon is at the end side
    try std.testing.expect(f.countColorIn(.{ .x = label_x, .y = 30, .w = lm.width, .h = 14 }, t.colors.on_primary) > 0);
}

test "golden: a disabled split button paints the OnSurface@0.10 container + @0.38 content" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try splitButton(a, null, null, .{ .label = "Save", .enabled = false, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 80);
    defer r.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    n.layout(.{ .x = 20, .y = 20, .w = sz.w, .h = sz.h });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the container: on_surface @ 0.10 over the background (at the leading
    // half's start side — clear of the centered label ink)
    const cont = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.10), 0xFFFFFFFF);
    const tw = trailWidth(stateOf(n));
    const lead_w = sz.w - between - tw;
    try std.testing.expectEqual(cont, f.pixelAt(24, 40));
    // the label ink: on_surface_variant @ 0.38 over the container (a double
    // translucent blend — the raster's rounding is ±1; count pixels within
    // ±2 over the whole label zone: glyph positions are platform-dependent,
    // so no single-pixel assertion)
    const dis = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface_variant, 0.38), cont);
    try std.testing.expect(f.countColorApproxIn(.{ .x = 24, .y = 30, .w = lead_w, .h = 20 }, dis) > 4);
}

test "split_button: the pressed half's inner corner morphs on the effects spring" {
    var tl = ui.anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    ui.anim.setCurrent(&tl);
    defer ui.anim.setCurrent(null);
    const a = std.testing.allocator;
    const n = try splitButton(a, null, null, .{ .label = "Save" });
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    n.layout(.{ .x = 0, .y = 0, .w = sz.w, .h = sz.h });
    const s = stateOf(n);
    const d = dimsFor(.small);
    try std.testing.expectEqual(d.inner_rest, s.lead_inner);
    // press the leading half → its inner corner springs toward pressed
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 20, .y = 20, .raw_x = 20, .raw_y = 20 });
    tl.tick(0); // lazy start
    tl.tick(60); // mid-flight
    try std.testing.expect(s.lead_inner > d.inner_rest and s.lead_inner < d.inner_pressed);
    tl.tick(600); // effects_spring (1600/1.0) settles fast
    try std.testing.expectApproxEqAbs(d.inner_pressed, s.lead_inner, 0.01);
    // release → back to rest (the retarget starts lazily at the next tick)
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 20, .y = 20, .raw_x = 20, .raw_y = 20 });
    tl.tick(1200); // lazy start
    tl.tick(2000);
    try std.testing.expectApproxEqAbs(d.inner_rest, s.lead_inner, 0.01);
}

test "split_button: checked trailing morphs to a circle + paints the contentColor scrim + a11y checked" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try splitButton(a, null, null, .{ .label = "Save", .trailing_checked = true, .theme = t });
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    n.layout(.{ .x = 20, .y = 20, .w = sz.w, .h = sz.h });
    const s = stateOf(n);
    // the trailing inner corners settled at h/2 (CircleShape)
    try std.testing.expectEqual(sz.h / 2, s.trail_inner);
    try std.testing.expect(splitTrailingChecked(n));
    try std.testing.expect(n.semantics.?.children[1].checked.?);
    var r = try golden.Renderer.init(std.testing.allocator, 260, 80);
    defer r.deinit();
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    const tw = trailWidth(s);
    const tx = 20 + sz.w - tw;
    // the checked scrim: primary + on_primary@0.12 over it (the trailing
    // half's edge near its start side, above the icon's y band)
    const checked_fill = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_primary, t.state.pressed), t.colors.primary);
    try golden.expectPixelApprox(f, @intFromFloat(tx + tw - 8), 40, checked_fill); // inside the circle, right of the icon
    // unchecking: the circle morphs back (no timeline → snap) and the
    // scrim lifts
    splitSetTrailingChecked(n, false);
    try std.testing.expectEqual(dimsFor(.small).inner_rest, s.trail_inner);
    try std.testing.expect(!n.semantics.?.children[1].checked.?);
    r.paint(n, 0xFFFFFFFF);
    f.deinit();
    f = try r.readback(a);
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(@intFromFloat(tx + tw - 8), 40));
}
