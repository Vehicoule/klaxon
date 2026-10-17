// Chip (Phase 2d.2 PR C1, M3E) — the five M3E chip variants: assist,
// elevated, filter, input, suggestion.
//
// Ported from .ref/material3/Chip.kt (verbatim behavior):
//   - Chip()/SelectableChip() + ChipContent: the Surface carries the
//     container color, the BorderStroke (drawn INSIDE the chip edge) and the
//     label color as LocalContentColor; content is a Row(minHeight=32,
//     spacedBy 8dp, centered) inside ContentPadding
//   - measurement: minHeight 32 (ContainerHeight); horizontal padding =
//     {Assist,Suggestion,Filter}ChipDefaults.ContentPadding (8dp each side);
//     the input chip's inputChipPadding: start = 8 with a leading icon else
//     4 (no avatar in this API), end = 8 with a trailing icon else 4. The
//     icon-label gap is HorizontalElementsPadding = 8; icons are the token
//     18dp (LeadingIconSize/IconSize); labels LabelLarge. Measured width
//     caps at maxChipWidth = 1000
//   - shape: action chips (assist/elevated/suggestion) use ContainerShape =
//     CornerSmall (8dp). Selectable chips (filter/input) use the expressive
//     ChipShapes path — shapeByInteraction: pressed → CornerSmall (8),
//     selected → CornerFull (16 on the 32dp chip), else CornerMedium (12) —
//     corner radius animating with FastSpatial (the theme spatial spring)
//     like upstream's rememberAnimatedShape
//   - colors (assistChipColors/suggestionChipColors + elevated variants,
//     filterChipColors, inputChipColors): assist/suggestion flat =
//     transparent + FlatOutlineColor OutlineVariant 1dp, label OnSurface /
//     OnSurfaceVariant, icons Primary; elevated = ElevatedContainerColor
//     SurfaceContainerLow, no border; filter/input unselected = transparent
//     + unselected outline 1dp (FlatUnselectedOutlineColor /
//     UnselectedOutlineColor = OutlineVariant), selected = FlatSelected-/
//     SelectedContainerColor SecondaryContainer with a 0dp border
//   - label colors per state: selected → OnSecondaryContainer, unselected →
//     OnSurfaceVariant (filter/input); assist OnSurface / suggestion
//     OnSurfaceVariant. Leading icons: filter Primary→OnSecondaryContainer;
//     input OnSurfaceVariant→Primary; trailing: OnSurfaceVariant→
//     OnSecondaryContainer. Disabled: label/icons OnSurface@0.38; containers
//     OnSurface@0.12 (elevated + selected); unselected outlines OnSurface
//     @0.12 (Flat/DisabledUnselectedOutlineOpacity)
//   - state layer: the Surface's bounded ripple — the content (label)
//     color @ hover 0.08 / focus 0.10 / pressed 0.12 over the container
//   - hit target: the painted bounds grown to the 48dp a11y floor per axis
//     (minimumInteractiveComponentSize)
//   - RTL: the Row's reading order mirrors + start/end padding flips; the
//     children paint clipped to the chip's bounds (Surface clips content to
//     the shape — a rect clip here)
//   - the filter chip's automatic check mark (when no leading icon is
//     given): upstream animates the leading icon's appear/disappear with
//     expandHorizontally+fadeIn (FastSpatial/DefaultEffects) — this impl
//     toggles its visibility instantly (the width still changes layout)
//
// Remaining deviations: elevation shadows are not painted (the elevation
// tokens are read but shadows aren't drawn); the input chip's 24dp avatar
// isn't modeled (its padding branch applies start=4 like a no-icon chip);
// a mid-flight re-press restarts the shape spring from 0 velocity; upstream
// maps selectable chips to Role.Checkbox — Klaxon keeps its uniform .toggle
// role.
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
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

pub const ChipVariant = enum { assist, elevated, filter, input, suggestion };

pub const ChipOptions = struct {
    variant: ChipVariant = .assist,
    enabled: bool = true,
    /// The chip's text (the accessible name too — a chip has a visible label).
    label: []const u8 = "",
    /// The selected state (filter/input chips only; driven by `sig` when the
    /// factory gets one, fixed otherwise).
    selected: bool = false,
    /// Optional leading icon (filter: replaced by a check mark when selected
    /// and no leading icon is given).
    leading_icon: ?icon_w.IconName = null,
    /// Optional trailing icon (input chips: the close affordance).
    trailing_icon: ?icon_w.IconName = null,
    theme: Theme = theme_mod.light,
};

/// M3E measurement tokens (the *ChipTokens + Chip.kt defaults).
const chip_h: f32 = 32; // ContainerHeight
const radius_rest: f32 = 8; // ContainerShape = CornerSmall (action chips)
const radius_unselected: f32 = 12; // ChipsTokens.UnselectedShape = CornerMedium
const radius_selected: f32 = 16; // ChipsTokens.SelectedShape = CornerFull (on 32h)
const radius_pressed: f32 = 8; // ChipsTokens.PressedShape = CornerSmall
const h_padding: f32 = 8;
const icon_size: f32 = 18;
const icon_gap: f32 = 8; // HorizontalElementsPadding
const outline_width: f32 = 1;
const max_chip_width: f32 = 1000; // Chip.kt maxChipWidth
// Compose minimumInteractiveComponentSize (the a11y hit-target floor) =
// theme.platform.hit_target_min — read from s.opts.theme where used.

const ChipState = struct {
    opts: ChipOptions,
    /// null = action chip (assist/elevated/suggestion, or a fixed selected
    /// state); non-null = toggle (filter/input: the click flips it).
    sig: ?*ui.state.Signal(bool),
    on_click: ?Callback = null,
    /// Explicit child references for the signal-driven recolor: a
    /// trailing-only chip's first child is its trailing icon (position
    /// inference would misclassify it). lead_child is the automatic filter
    /// check when no leading icon is given — its visibility follows the
    /// selected state (kept as a child: adding/removing would churn layout).
    lead_child: ?*Node = null,
    trail_child: ?*Node = null,
    pressed: bool = false,
    hovered: bool = false,
    /// shapeByInteraction's animated corner radius (selectable chips only —
    /// action chips rest at CornerSmall=8).
    shape_radius: f32 = radius_rest,
    /// Animation channel marker (stable address).
    shape_channel: u8 = 0,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — see PointerEvent.raw_x/raw_y).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
};

fn stateOf(n: *Node) *ChipState {
    return @ptrCast(@alignCast(n.state.?));
}

fn isSelected(s: *ChipState) bool {
    return if (s.sig) |sig| sig.peek() else s.opts.selected;
}

/// The container color, outline color, label color, leading/trailing icon
/// colors and the state layer's on-color for the current state.
const ChipColors = struct { container: Color, outline: Color, label: Color, leading_icon: Color, trailing_icon: Color, on: Color };

fn currentColors(s: *ChipState) ChipColors {
    const cs = s.opts.theme.colors;
    const transparent: Color = 0x00000000;
    const dis_label = ui.paint.withAlphaScaled(cs.on_surface, 0.38);
    const dis_icon = ui.paint.withAlphaScaled(cs.on_surface, 0.38);
    const dis_container = ui.paint.withAlphaScaled(cs.on_surface, 0.12);
    const dis_outline = ui.paint.withAlphaScaled(cs.on_surface, 0.12);
    if (!s.opts.enabled) {
        return switch (s.opts.variant) {
            .assist, .suggestion => .{ .container = transparent, .outline = dis_outline, .label = dis_label, .leading_icon = dis_icon, .trailing_icon = dis_icon, .on = dis_label },
            .elevated => .{ .container = dis_container, .outline = transparent, .label = dis_label, .leading_icon = dis_icon, .trailing_icon = dis_icon, .on = dis_label },
            .filter, .input => if (isSelected(s))
                .{ .container = dis_container, .outline = transparent, .label = dis_label, .leading_icon = dis_icon, .trailing_icon = dis_icon, .on = dis_label }
            else
                .{ .container = transparent, .outline = dis_outline, .label = dis_label, .leading_icon = dis_icon, .trailing_icon = dis_icon, .on = dis_label },
        };
    }
    return switch (s.opts.variant) {
        .assist => .{ .container = transparent, .outline = cs.outline_variant, .label = cs.on_surface, .leading_icon = cs.primary, .trailing_icon = cs.primary, .on = cs.on_surface },
        .elevated => .{ .container = cs.surface_container_low, .outline = transparent, .label = cs.on_surface, .leading_icon = cs.primary, .trailing_icon = cs.primary, .on = cs.on_surface },
        .suggestion => .{ .container = transparent, .outline = cs.outline_variant, .label = cs.on_surface_variant, .leading_icon = cs.primary, .trailing_icon = cs.primary, .on = cs.on_surface_variant },
        .filter => if (isSelected(s))
            .{ .container = cs.secondary_container, .outline = transparent, .label = cs.on_secondary_container, .leading_icon = cs.on_secondary_container, .trailing_icon = cs.on_secondary_container, .on = cs.on_secondary_container }
        else
            .{ .container = transparent, .outline = cs.outline_variant, .label = cs.on_surface_variant, .leading_icon = cs.primary, .trailing_icon = cs.on_surface_variant, .on = cs.on_surface_variant },
        .input => if (isSelected(s))
            .{ .container = cs.secondary_container, .outline = transparent, .label = cs.on_secondary_container, .leading_icon = cs.primary, .trailing_icon = cs.on_secondary_container, .on = cs.on_secondary_container }
        else
            .{ .container = transparent, .outline = cs.outline_variant, .label = cs.on_surface_variant, .leading_icon = cs.on_surface_variant, .trailing_icon = cs.on_surface_variant, .on = cs.on_surface_variant },
    };
}

/// The chip's start/end padding in reading direction (Chip.kt
/// paddingValues): flat chips use ContentPadding 8dp each side; the input
/// chip's inputChipPadding — start = 8 with a leading icon else 4 (no
/// avatar in this API → the !hasLeadingIcon branch), end = 8 with a
/// trailing icon else 4.
fn padStart(s: *ChipState) f32 {
    if (s.opts.variant == .input) return if (s.lead_child != null) 8 else 4;
    return h_padding;
}
fn padEnd(s: *ChipState) f32 {
    if (s.opts.variant == .input) return if (s.trail_child != null) 8 else 4;
    return h_padding;
}

fn chipMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const pad = padStart(s) + padEnd(s);
    var content_w: f32 = 0;
    var content_h: f32 = 0;
    var first = true;
    for (n.children.items) |child| {
        if (!child.visible) continue; // the hidden filter check takes no space
        const cs = child.measure(c.deflateEdge(.{ .left = padStart(s), .top = 0, .right = padEnd(s), .bottom = 0 }));
        if (!first) content_w += icon_gap;
        content_w += cs.w;
        content_h = @max(content_h, cs.h);
        first = false;
    }
    return c.constrain(.{ .w = @min(content_w + pad, max_chip_width), .h = chip_h });
}

fn chipLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    // the start/end padding in absolute x (flips in RTL)
    const rtl = ui.i18n.direction() == .rtl;
    const pad_l = if (rtl) padEnd(s) else padStart(s);
    const pad_r = if (rtl) padStart(s) else padEnd(s);
    // the content row [leading?, label, trailing?] centered, gap 8
    var sizes: [3]Size = .{ .{}, .{}, .{} };
    var content_w: f32 = 0;
    var count: usize = 0;
    for (n.children.items) |child| {
        if (!child.visible) continue; // the hidden filter check takes no space
        // Fixed chrome slots (avatar/icon + label + trailing): grafted
        // extras are ignored, never written past `sizes`.
        if (count == sizes.len) break;
        const cs = child.measure(.{ .max_w = bounds.w, .max_h = bounds.h });
        sizes[count] = cs;
        content_w += cs.w;
        count += 1;
    }
    if (count > 1) content_w += icon_gap * @as(f32, @floatFromInt(count - 1));
    const inner_x = bounds.x + pad_l;
    const inner_w = @max(0, bounds.w - pad_l - pad_r);
    var x = inner_x + @max(0, (inner_w - content_w) / 2);
    var i: usize = 0;
    for (n.children.items) |child| {
        if (!child.visible) continue;
        if (i >= sizes.len) break;
        const cs = sizes[i];
        child.layout(.{
            .x = x,
            .y = bounds.y + (bounds.h - cs.h) / 2,
            .w = cs.w,
            .h = cs.h,
        });
        x += cs.w;
        i += 1;
        if (i < count) x += icon_gap;
    }
    // RTL: mirror the row around the inner box — the leading icon moves to
    // the end side (the gap is preserved)
    if (ui.i18n.direction() == .rtl) {
        for (n.children.items) |child| {
            if (!child.visible) continue;
            child.bounds.x = inner_x + inner_w - (child.bounds.x - inner_x) - child.bounds.w;
        }
    }
}

/// The interactive target: the painted bounds grown to the a11y floor
/// (theme.platform.hit_target_min) per axis, centered (a wide chip is
/// clickable along its whole width; a short chip keeps the floor vertically).
fn chipHitBounds(n: *Node) Rect {
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

/// The children (label + icons) paint clipped to the chip's bounds: a
/// constrained chip never lets its label ink cross the container edge.
fn chipPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    ui.paint.clipRect(ctx, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h); // saves
}

fn chipPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.clipReset(ctx); // restores
}

fn chipChildClip(n: *Node) Rect {
    return n.bounds; // the bounds clip pushed in pre_children_paint
}

/// shapeByInteraction: selectable chips morph pressed → CornerSmall (8),
/// selected → CornerFull (16), else CornerMedium (12); action chips rest at
/// ContainerShape = CornerSmall (8). Animated like rememberAnimatedShape —
/// FastSpatial (the theme spatial spring).
fn shapeTarget(s: *ChipState) f32 {
    switch (s.opts.variant) {
        .filter, .input => {
            if (s.pressed) return radius_pressed;
            if (isSelected(s)) return radius_selected;
            return radius_unselected;
        },
        else => return radius_rest,
    }
}

fn shapeRadiusCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).shape_radius = v[0];
    n.markDirty();
}

fn retargetShape(n: *Node, s: *ChipState) void {
    const target = shapeTarget(s);
    if (ui.anim.timeline()) |tl| {
        if (s.shape_radius == target) return;
        const from: ui.anim.Vec4 = .{ s.shape_radius, 0, 0, 0 };
        _ = tl.play(.{
            .kind = ui.anim.Animation.springAnim(from, .{ target, 0, 0, 0 }, s.opts.theme.motion.springs.spatial_spring, .{ 0, 0, 0, 0 }),
            .from = from,
            .channel = @ptrCast(&s.shape_channel),
            .on_update = .{ .fn_ptr = shapeRadiusCb, .userdata = n },
        });
    } else {
        s.shape_radius = target;
    }
}

fn chipPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const cc = currentColors(s);
    const radius = @min(s.shape_radius, @min(b.w, b.h) / 2);
    // container
    if (cc.container & 0xFF != 0) {
        ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, radius, cc.container);
    }
    // state layer (enabled only): the label color blended over the container —
    // AT the state alpha over a transparent container (the button fix pattern)
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
            const layer = if (cc.container & 0xFF == 0)
                ui.paint.withAlphaScaled(cc.on, alpha)
            else
                theme_mod.stateLayer(cc.container, cc.on, alpha);
            ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, radius, layer);
        }
    }
    // outline (flat variants): the BorderStroke draws INSIDE the chip edge —
    // the ring's outer edge is flush with the bounds
    if (cc.outline & 0xFF != 0) {
        ui.paint.strokeRRect(ctx, b.x + outline_width / 2, b.y + outline_width / 2, b.w - outline_width, b.h - outline_width, @max(0, radius - outline_width / 2), outline_width, cc.outline);
    }
}

fn chipOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    switch (ev.phase) {
        .down => {
            s.pressed = true;
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            retargetShape(n, s); // pressed → CornerSmall
            n.markDirty();
            return true;
        },
        .up => {
            const was_pressed = s.pressed;
            s.pressed = false;
            retargetShape(n, s); // released → back to selected/unselected
            n.markDirty();
            // the click lands in the 48dp hit target, not necessarily in the
            // 32-high chip (the a11y floor is the interactive area)
            if (was_pressed and chipHitBounds(n).contains(ev.x, ev.y)) {
                if (s.sig) |sig| sig.set(!sig.peek());
                if (s.on_click) |cb| cb.fn_ptr(cb.userdata);
            }
            return true;
        },
        .move => {
            // a drag past the touch slop cancels the press (a scroll); the
            // move is NOT claimed so it keeps bubbling to scrollables
            if (s.pressed) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.pressed = false;
                    retargetShape(n, s); // cancel → back to selected/unselected
                    n.markDirty();
                }
            }
            return false;
        },
        .outside_down => {
            s.pressed = false;
            retargetShape(n, s); // cancel → back to selected/unselected
            n.markDirty();
            return true;
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

/// Keyboard activation (Phase 2c): Enter/Space press the focused chip.
fn chipOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            if (s.sig) |sig| sig.set(!sig.peek());
            if (s.on_click) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        else => {},
    }
    return false;
}

/// Signal-driven repaint + semantic checked sync + child recolor (toggle).
fn chipSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const cc = currentColors(s);
    var layout_changed = false;
    // the automatic filter check follows the selected state (its visibility
    // changes the measured width → the layout must re-run)
    if (s.opts.variant == .filter and s.opts.leading_icon == null) {
        if (s.lead_child) |lc| {
            const want = isSelected(s);
            if (lc.visible != want) {
                lc.setVisible(want);
                layout_changed = true;
            }
        }
    }
    // recolor the children (label + icons) to the current state's colors —
    // via the explicit child references (a trailing-only chip's first child
    // is its trailing icon)
    for (n.children.items) |child| {
        // icons carry the .image role, the label the .text role (the icon
        // paint fn is private — the semantics role is the public tell)
        if (child.semantics.?.role == .image) {
            icon_w.setColor(child, if (child == s.trail_child) cc.trailing_icon else cc.leading_icon);
        } else {
            text_w.setColor(child, cc.label);
        }
    }
    if (n.semantics) |sem| sem.checked = isSelected(s);
    retargetShape(n, s); // the selected change morphs the corner radius
    if (layout_changed) n.markLayoutDirty();
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the value changed
}

fn chipDeinit(n: *Node) void {
    const s = stateOf(n);
    if (ui.anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.shape_channel));
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = chipSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const chip_vtable = ui.node.VTable{
    .measure = chipMeasure,
    .layout = chipLayout,
    .paint = chipPaint,
    .deinit = chipDeinit,
    .on_pointer = chipOnPointer,
    .on_key = chipOnKey,
    .hit_bounds = chipHitBounds,
    .pre_children_paint = chipPreChildrenPaint,
    .post_children_paint = chipPostChildrenPaint,
    .child_clip = chipChildClip,
};

/// An M3E chip. `sig` = null → an action chip (or a fixed selected state);
/// non-null → a toggle (the click flips it; filter/input). `on_click` fires
/// on click (pointer up inside after a down) and on Enter/Space. The label
/// and icons are internal chrome built from the options (styled per the
/// variant) — they are not document children.
pub fn chip(allocator: std.mem.Allocator, sig: ?*ui.state.Signal(bool), on_click: ?Callback, opts: ChipOptions) !*Node {
    const node = try Node.create(allocator, &chip_vtable);
    errdefer allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(ChipState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .sig = sig, .on_click = on_click };
    node.state = s;
    const cc = currentColors(s);
    s.shape_radius = shapeTarget(s); // rememberAnimatedShape starts at rest
    const t = opts.theme;
    // leading icon (filter without one: a check mark, shown only when
    // selected — its visibility follows the signal in chipSyncCb)
    const lead_name = if (opts.leading_icon) |i| i else if (opts.variant == .filter) icon_w.IconName.check else null;
    const lead = if (lead_name) |iname| blk: {
        const ic = try icon_w.icon(allocator, iname, .{ .size = icon_size, .color = cc.leading_icon });
        ic.setVisible(if (opts.leading_icon != null) true else isSelected(s));
        break :blk ic;
    } else null;
    errdefer if (lead) |ic| ic.deinit();
    const txt = if (opts.label.len > 0) try text_w.text(allocator, opts.label, .{
        .size = t.type_scale.label_large.size,
        .color = cc.label,
        .bold = t.type_scale.label_large.weight >= 500,
    }) else null;
    errdefer if (txt) |txn| txn.deinit();
    const trail = if (opts.trailing_icon) |iname| try icon_w.icon(allocator, iname, .{ .size = icon_size, .color = cc.trailing_icon }) else null;
    errdefer if (trail) |ic| ic.deinit();
    // no fallible ops past this point: the errdefers above never double-free
    s.lead_child = lead; // explicit refs for the signal-driven recolor
    s.trail_child = trail;
    if (lead) |ic| {
        ic.internal = true; // chrome: not document data (registry)
        ic.exclude_semantics = true; // decorative: the label is the a11y name
        node.add(ic);
    }
    if (txt) |txn| {
        txn.internal = true;
        node.add(txn);
    }
    if (trail) |ic| {
        ic.internal = true;
        ic.exclude_semantics = true;
        node.add(ic);
    }
    if (sig) |sg| {
        ui.semantics.attach(node, .{
            .role = .toggle,
            .label = opts.label,
            .focusable = opts.enabled,
            .disabled = !opts.enabled,
            .checked = isSelected(s),
            .actions = ui.semantics.Actions.initOne(.activate),
        });
        sg.subscribe(.{ .callback = .{ .fn_ptr = chipSyncCb, .userdata = node } }); // visual + semantic updates on set
    } else {
        ui.semantics.attach(node, .{
            .role = .button,
            .label = opts.label,
            .focusable = opts.enabled,
            .disabled = !opts.enabled,
            .actions = ui.semantics.Actions.initOne(.activate),
        });
    }
    return node;
}

// --- tests ---

fn clickCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "chip: measures height 32 + content + 16dp padding; the 48dp floor is the hit target" {
    const b = try chip(std.testing.allocator, null, null, .{ .label = "Chip" });
    defer b.deinit();
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(chip_h, m.h);
    const tw = ui.paint.measureText("Chip", 14, true).width;
    try std.testing.expectEqual(tw + 16, m.w); // label_large (14, 500 -> bold) + 8*2
    b.layout(.{ .x = 100, .y = 100, .w = m.w, .h = 32 });
    const hb = b.vtable.hit_bounds.?(b);
    const min_target = theme_mod.light.platform.hit_target_min;
    try std.testing.expectEqual(@max(m.w, min_target), hb.w);
    try std.testing.expectEqual(min_target, hb.h);
    try std.testing.expectEqual(@as(f32, 100 - 8), hb.y); // (32-48)/2
    // a wide chip: the hit target covers the full painted width (the edges
    // are clickable, not only the centered 48dp)
    const wide = try chip(std.testing.allocator, null, null, .{ .label = "A much longer chip label" });
    defer wide.deinit();
    wide.layout(.{ .x = 0, .y = 0, .w = 220, .h = 32 });
    const hbw = wide.vtable.hit_bounds.?(wide);
    try std.testing.expectEqual(@as(f32, 220), hbw.w);
    try std.testing.expectEqual(@as(f32, 0), hbw.x);
    try std.testing.expectEqual(min_target, hbw.h);
}

test "chip: the automatic filter check follows the selected state" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try chip(std.testing.allocator, sig, null, .{ .variant = .filter, .label = "News" });
    defer b.deinit();
    // the check child always exists (no layout churn) but is hidden while
    // unselected — it takes no space
    try std.testing.expectEqual(@as(usize, 2), b.children.items.len);
    const check = b.children.items[0];
    try std.testing.expect(!check.visible);
    const w0 = b.measure(.{ .max_w = 2000, .max_h = 2000 }).w;
    b.layout_dirty = false;
    ui.node.bumpMarkEpoch(); // manual flag clear models a consumed layout pass
    sig.set(true);
    try std.testing.expect(check.visible); // the check shows
    try std.testing.expect(b.layout_dirty); // the width changed → re-layout
    const w1 = b.measure(.{ .max_w = 2000, .max_h = 2000 }).w;
    try std.testing.expectApproxEqAbs(w0 + icon_size + icon_gap, w1, 0.001);
    sig.set(false);
    try std.testing.expect(!check.visible); // and hides again
    // starts selected: the check is visible from the start
    const sig2 = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig2.deinit();
    const b2 = try chip(std.testing.allocator, sig2, null, .{ .variant = .filter, .label = "News" });
    defer b2.deinit();
    try std.testing.expect(b2.children.items[0].visible);
    // an explicit leading icon never hides (no automatic check)
    const b3 = try chip(std.testing.allocator, sig2, null, .{ .variant = .filter, .label = "News", .leading_icon = .star });
    defer b3.deinit();
    try std.testing.expect(b3.children.items[0].visible);
    sig2.set(false);
    try std.testing.expect(b3.children.items[0].visible); // stays visible
}

test "chip: RTL mirrors the content row (the leading icon moves to the end side)" {
    const i18n = try ui.i18n.I18n.init(std.testing.allocator, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    const b = try chip(std.testing.allocator, null, null, .{ .label = "OK", .leading_icon = .star });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 200, .h = 32 });
    const ic = b.children.items[0];
    const lb = b.children.items[1];
    // mirrored: the label is on the start (left) side, the icon on the end
    // (right) side, the 8dp gap preserved
    try std.testing.expect(ic.bounds.x > lb.bounds.x);
    try std.testing.expectEqual(lb.bounds.x + lb.bounds.w + 8, ic.bounds.x);
}

test "chip: the content row lays out centered with the 8dp icon gap" {
    const b = try chip(std.testing.allocator, null, null, .{ .label = "OK", .leading_icon = .star, .trailing_icon = .close });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 120, .h = 32 });
    try std.testing.expectEqual(@as(usize, 3), b.children.items.len);
    const lead = b.children.items[0];
    const lb = b.children.items[1];
    const trail = b.children.items[2];
    try std.testing.expectEqual(icon_size, lead.bounds.w);
    // row = 18 + 8 + label + 8 + 18, centered in 120-16 = 104
    const content_w = lead.bounds.w + icon_gap + lb.bounds.w + icon_gap + trail.bounds.w;
    try std.testing.expectEqual(8 + (104 - content_w) / 2, lead.bounds.x);
    try std.testing.expectEqual(lead.bounds.x + 18 + 8, lb.bounds.x);
    try std.testing.expectEqual(lb.bounds.x + lb.bounds.w + 8, trail.bounds.x);
    // vertically centered
    try std.testing.expectEqual((32 - 18) / 2, lead.bounds.y);
}

test "chip: click fires on_click; a toggle flips its signal; disabled swallows input" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = clickCounterCb, .userdata = &count };
    // action chip (sig = null): the callback fires, no selected state
    const a = try chip(std.testing.allocator, null, cb, .{ .label = "Go" });
    defer a.deinit();
    a.layout(.{ .x = 0, .y = 0, .w = 60, .h = 32 });
    const on_pointer_a = a.vtable.on_pointer.?;
    _ = on_pointer_a(a, .{ .phase = .down, .x = 30, .y = 16, .raw_x = 30, .raw_y = 16 });
    _ = on_pointer_a(a, .{ .phase = .up, .x = 30, .y = 16, .raw_x = 30, .raw_y = 16 });
    try std.testing.expectEqual(@as(u32, 1), count);
    // a drag past the slop cancels (a scroll, not a click)
    _ = on_pointer_a(a, .{ .phase = .down, .x = 30, .y = 16, .raw_x = 30, .raw_y = 16 });
    _ = on_pointer_a(a, .{ .phase = .move, .x = 30, .y = 40, .raw_x = 30, .raw_y = 40 });
    _ = on_pointer_a(a, .{ .phase = .up, .x = 30, .y = 16, .raw_x = 30, .raw_y = 16 });
    try std.testing.expectEqual(@as(u32, 1), count);
    // toggle chip: the click flips the signal + fires the callback
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const t = try chip(std.testing.allocator, sig, cb, .{ .variant = .filter, .label = "Filter" });
    defer t.deinit();
    t.layout(.{ .x = 0, .y = 0, .w = 80, .h = 32 });
    const on_pointer = t.vtable.on_pointer.?;
    _ = on_pointer(t, .{ .phase = .down, .x = 40, .y = 16, .raw_x = 40, .raw_y = 16 });
    _ = on_pointer(t, .{ .phase = .up, .x = 40, .y = 16, .raw_x = 40, .raw_y = 16 });
    try std.testing.expect(sig.peek());
    try std.testing.expectEqual(@as(u32, 2), count);
    // keyboard
    const on_key = t.vtable.on_key.?;
    try std.testing.expect(on_key(t, .{ .kind = .key_down, .key = .space }));
    try std.testing.expect(!sig.peek());
    try std.testing.expectEqual(@as(u32, 3), count);
    // disabled
    const dis = try chip(std.testing.allocator, sig, cb, .{ .enabled = false, .label = "x" });
    defer dis.deinit();
    dis.layout(.{ .x = 0, .y = 0, .w = 60, .h = 32 });
    try std.testing.expect(!dis.vtable.on_pointer.?(dis, .{ .phase = .down, .x = 30, .y = 16 }));
    try std.testing.expect(sig.peek() == false);
    try std.testing.expectEqual(@as(u32, 3), count);
}

test "chip: semantics — toggle role + checked sync (selected); action role button" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const t = try chip(std.testing.allocator, sig, null, .{ .variant = .filter, .label = "News" });
    defer t.deinit();
    try std.testing.expectEqual(ui.semantics.Role.toggle, t.semantics.?.role);
    try std.testing.expectEqual(true, t.semantics.?.checked);
    try std.testing.expectEqualStrings("News", t.semantics.?.label);
    sig.set(false);
    try std.testing.expectEqual(false, t.semantics.?.checked); // follows the signal
    const a = try chip(std.testing.allocator, null, null, .{ .variant = .assist, .label = "Add" });
    defer a.deinit();
    try std.testing.expectEqual(ui.semantics.Role.button, a.semantics.?.role);
    try std.testing.expect(a.semantics.?.actions.contains(.activate));
    try std.testing.expect(a.semantics.?.checked == null);
    const dis = try chip(std.testing.allocator, null, null, .{ .enabled = false, .label = "x" });
    defer dis.deinit();
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
}

test "golden: assist chip strokes the outline_variant border, transparent inside" {
    const t = theme_mod.light;
    const b = try chip(std.testing.allocator, null, null, .{ .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 48);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 8, .w = 80, .h = 32 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the top border, mid-edge — the BorderStroke draws INSIDE the chip
    // edge (inset 0.5 + 1px band covers pixel row 8 fully)
    try std.testing.expectEqual(t.colors.outline_variant, f.pixelAt(60, 8));
    // inside, away from the label ink: transparent → bg
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(24, 24));
}

test "golden: elevated chip paints the surface_container_low container" {
    const t = theme_mod.light;
    const b = try chip(std.testing.allocator, null, null, .{ .variant = .elevated, .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 48);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 8, .w = 80, .h = 32 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // inside, in the padding zone (no label ink): surface_container_low
    try std.testing.expectEqual(t.colors.surface_container_low, f.pixelAt(23, 24));
}

test "golden: filter chip selected paints the secondary_container + the check icon" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const b = try chip(std.testing.allocator, sig, null, .{ .variant = .filter, .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 48);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 8, .w = 80, .h = 32 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the container: secondary_container
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(23, 24));
    // the automatic check icon (selected, no leading icon): on_secondary_container ink
    try std.testing.expect(f.countColorIn(.{ .x = 20, .y = 8, .w = 80, .h = 32 }, t.colors.on_secondary_container) > 0);
}

test "golden: a trailing-only input chip recolors its close icon on selection" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try chip(std.testing.allocator, sig, null, .{ .variant = .input, .label = "In", .trailing_icon = .close, .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 160, 48);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 8, .w = 100, .h = 32 });
    const trail = b.children.items[b.children.items.len - 1]; // the close icon
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // unselected: the trailing icon ink is OnSurfaceVariant
    try std.testing.expect(f.countColorIn(trail.bounds, t.colors.on_surface_variant) > 0);
    // selected: it recolors as TRAILING (OnSecondaryContainer) — a
    // trailing-only chip's first child is not misclassified as leading
    sig.set(true);
    r.paint(b, 0xFFFFFFFF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expect(f2.countColorIn(trail.bounds, t.colors.on_secondary_container) > 0);
}

test "golden: a constrained chip clips its label ink to the bounds" {
    const t = theme_mod.light;
    const b = try chip(std.testing.allocator, null, null, .{ .label = "A very long chip label that overflows", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 48);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 8, .w = 60, .h = 32 }); // narrower than the content
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // no label ink (on_surface) outside the chip's horizontal bounds — the
    // outline stroke is a different color and stays inside
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(.{ .x = 0, .y = 0, .w = 19, .h = 48 }, t.colors.on_surface));
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(.{ .x = 81, .y = 0, .w = 39, .h = 48 }, t.colors.on_surface));
}

test "golden: disabled chip paints the OnSurface@0.12 outline" {
    const t = theme_mod.light;
    const b = try chip(std.testing.allocator, null, null, .{ .enabled = false, .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 48);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 8, .w = 80, .h = 32 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the top border: on_surface @ 0.12 over white (alpha color, not
    // pre-composited — the border draws inside the edge now)
    try golden.expectPixelApprox(f, 60, 8, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.12), 0xFFFFFFFF));
}
