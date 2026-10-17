// An M3E button group: a row of connected buttons separated by 2dp whose
// adjacent (inner) corners collapse to a small radius while the outer
// corners keep the button shape; the pressed button's INNER corners morph
// tighter (the M3E squeeze signature — instant, not animated).
//
// Spec: m3.material.io/components/button-groups + Compose ButtonGroup.kt
// (ButtonGroupDefaults.ConnectedButtonSpaceBetween /
// connectedLeading/Trailing/MiddleButtonShapes +
// ConnectedButtonGroupSmallTokens):
//   - spacing between connected buttons: 2dp (ConnectedButtonSpaceBetween =
//     BetweenSpace)
//   - shapes: the FIRST/LAST outer corners keep the button shape (round =
//     CornerFull = h/2; square = the size's square_corner); every INNER
//     corner uses InnerCornerCornerSize = CornerValueSmall (8dp); the
//     PRESSED item morphs its inner corners to
//     PressedInnerCornerCornerSize = CornerValueExtraSmall (4dp) — outer
//     corners stay (upstream connectedLeading/TrailingButtonPressShape; a
//     pressed middle item morphs all four corners)
//   - states: same as button — hover 0.08 / focus 0.10 / pressed 0.12 state
//     layer of the on-color over the container; disabled = OnSurface @ 0.38
//     content over OnSurface @ 0.10 container
//   - sizing: items size to content (the same dims as button.zig — 24dp
//     h-padding, icon + 8dp gap + label for medium); a constrained group
//     shrinks items proportionally (each keeps its share of the content
//     space — Compose weight(1f) on a fixed-width group splits evenly; the
//     proportional split matches it when the items are symmetric)
//   - input: same contract as button/segmented — click = down+up inside,
//     a drag past gestures.SLOP cancels (and bubbles to scrollables),
//     arrows move the focus between items (RTL mirrors the row so the
//     start-side shape follows the reading direction)
//
// v1 deviations (documented, fixed later):
//   - No animated corner morph or pressed-width expansion — upstream
//     animates the pressed item to grow ~15% while compressing its
//     neighbours; v1 keeps static proportional widths + instant corners.
//   - No overflow menu (ButtonGroup overflow → the trailing "more" slot).
//   - Action-only: no toggle/selected state (upstream's checked = CornerFull
//     has no signal in this API; single-choice groups are the segmented
//     button's job).

const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const i18n_mod = @import("../ui/i18n.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const button_w = @import("button.zig");
const icon_w = @import("icon.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

/// A group item (the factory copies the label).
pub const ButtonGroupItem = struct {
    label: []const u8,
    icon: ?icon_w.IconName = null,
    on_press: ?Callback = null,
    enabled: bool = true,
};

pub const ButtonGroupOptions = struct {
    variant: button_w.ButtonVariant = .filled,
    size: button_w.ButtonSize = .medium,
    shape: button_w.ButtonShape = .round,
    theme: Theme = theme_mod.light,
};

/// ButtonGroupDefaults.ConnectedButtonSpaceBetween.
const space_between: f32 = 2;
/// ConnectedButtonGroupSmallTokens.InnerCornerCornerSize (CornerValueSmall).
const inner_corner: f32 = 8;
/// ConnectedButtonGroupSmallTokens.PressedInnerCornerCornerSize
/// (CornerValueExtraSmall) — the pressed item's INNER corners morph to it
/// (upstream connectedLeading/TrailingButtonPressShape; a pressed middle
/// item's connectedMiddleButtonPressShape morphs all four).
const inner_corner_pressed: f32 = 4;
// The a11y touch-target floor is theme.platform.hit_target_min (48 mobile /
// 24 desktop) — read from s.opts.theme where used.

const ItemDef = struct {
    label: [:0]const u8, // owned
    icon: ?icon_w.IconName,
    on_press: ?Callback,
    enabled: bool,
};

const GroupState = struct {
    items: std.array_list.Managed(ItemDef), // owned defs
    /// Per-item intrinsic content widths, measured once at init (the label
    /// text never changes).
    widths: std.array_list.Managed(f32),
    /// Live per-item a11y descriptors — the semantics tree's virtual
    /// children borrow this slice.
    sem_children: std.array_list.Managed(ui.semantics.Semantics),
    opts: ButtonGroupOptions,
    pressed: i32 = -1,
    hovered: i32 = -1,
    focus_idx: i32 = -1, // arrow-key focus (not the node focus itself)
    /// The down position in raw (window) coordinates — drag deltas are
    /// physical finger motion (PointerEvent.raw_x/raw_y).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
    i18n: ?*i18n_mod.I18n = null,
};

fn stateOf(n: *Node) *GroupState {
    return @ptrCast(@alignCast(n.state.?));
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

/// An item's intrinsic width: h_padding + [icon + gap] + label + h_padding
/// (the button's own content metrics).
fn itemContentWidth(t: Theme, opts: ButtonGroupOptions, def: ItemDef) f32 {
    const d = button_w.dimsFor(opts.size);
    const ls = button_w.labelStyle(t, opts.size);
    var w: f32 = 2 * d.h_padding + ui.paint.measureText(def.label, ls.size, ls.weight >= 500).width;
    if (def.icon != null) w += d.icon + d.icon_gap;
    return w;
}

/// The proportional scale applied to the intrinsic widths when the row is
/// constrained (1 when it fits).
fn widthScale(s: *GroupState, b: Rect) f32 {
    const count = s.items.items.len;
    var total: f32 = 0;
    for (s.widths.items) |w| total += w;
    const avail_content = @max(b.w - space_between * @as(f32, @floatFromInt(count - 1)), 0);
    return if (total > 0 and total > avail_content) avail_content / total else 1;
}

fn mirrorX(b: Rect, r: Rect) Rect {
    return .{ .x = b.x + b.w - (r.x - b.x) - r.w, .y = r.y, .w = r.w, .h = r.h };
}

/// Item `index`'s rect in LTR space; the caller mirrors for RTL.
fn itemRectLtr(s: *GroupState, b: Rect, index: usize) Rect {
    const scale = widthScale(s, b);
    var x = b.x;
    for (0..index) |i| x += s.widths.items[i] * scale + space_between;
    return .{ .x = x, .y = b.y, .w = s.widths.items[index] * scale, .h = b.h };
}

/// The item's rect in NODE-LOCAL space (Semantics.child_bounds maps it to
/// window space for per-item highlights + targeted activation taps).
fn groupChildBounds(n: *Node, index: usize) Rect {
    const s = stateOf(n);
    const local = Rect{ .x = 0, .y = 0, .w = n.bounds.w, .h = n.bounds.h };
    var r = itemRectLtr(s, local, index);
    if (ui.i18n.direction() == .rtl) r = mirrorX(local, r);
    return r;
}

const Corners = struct { tl: f32, tr: f32, br: f32, bl: f32 };

/// The item's corner radii (upstream connectedLeading/Trailing/Middle
/// ButtonShapes): the row's outer corners keep the button shape, the inner
/// corners take inner_corner; the PRESSED item morphs only its inner
/// corners to inner_corner_pressed — outer corners stay (a pressed middle
/// item morphs all four; a single item has no inner sides, so press shows
/// the state layer only). Instant morph (upstream animates it).
fn itemCorners(s: *GroupState, h: f32, i: usize) Corners {
    const count = s.items.items.len;
    const outer: f32 = if (s.opts.shape == .round) h / 2 else button_w.dimsFor(s.opts.size).square_corner;
    const inner: f32 = if (s.pressed == @as(i32, @intCast(i))) inner_corner_pressed else inner_corner;
    return .{
        .tl = if (i == 0) outer else inner,
        .bl = if (i == 0) outer else inner,
        .tr = if (i == count - 1) outer else inner,
        .br = if (i == count - 1) outer else inner,
    };
}

/// Item index at a node-local x (returns -1 in the 2dp gaps).
fn itemAt(s: *GroupState, b: Rect, x: f32) i32 {
    for (0..s.items.items.len) |i| {
        var r = itemRectLtr(s, b, i);
        if (ui.i18n.direction() == .rtl) r = mirrorX(b, r);
        if (x >= r.x and x < r.x + r.w) return @intCast(i);
    }
    return -1;
}

fn groupMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const d = button_w.dimsFor(s.opts.size);
    var w: f32 = 0;
    for (s.widths.items, 0..) |iw, i| {
        if (i > 0) w += space_between;
        w += iw;
    }
    return c.constrain(.{ .w = w, .h = @max(d.height, s.opts.theme.platform.hit_target_min) });
}

fn groupLayout(n: *Node, bounds: Rect) void {
    // The item rects are resolved in paint/hit/child-bounds from the
    // intrinsic widths (no per-item node to lay out). Nothing to do here —
    // the function exists to keep the vtable shape uniform.
    _ = stateOf(n);
    _ = bounds;
}

/// Paint an icon centered in a size x size box — vector geometry (icon.zig),
/// not a font glyph.
fn paintIcon(ctx: *kx.Ctx, name: icon_w.IconName, x: f32, y: f32, size: f32, color: Color) void {
    if (color & 0xFF == 0) return;
    icon_w.drawIcon(ctx, name, x, y, size / 24.0, color);
}

fn groupPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const count = s.items.items.len;
    if (count == 0) return;
    const vc = button_w.variantColors(t, s.opts.variant);
    const d = button_w.dimsFor(s.opts.size);
    const ls = button_w.labelStyle(t, s.opts.size);
    const bold = ls.weight >= 500;
    const focused = input.isFocused(n);
    for (0..count) |i| {
        const def = s.items.items[i];
        const idx: i32 = @intCast(i);
        var r = itemRectLtr(s, b, i);
        if (ui.i18n.direction() == .rtl) r = mirrorX(b, r);
        const cor = itemCorners(s, r.h, i);
        ui.paint.clipRect(ctx, r.x, r.y, r.w, r.h); // saves
        const container = if (def.enabled) vc.container else vc.disabled_container;
        if (container & 0xFF != 0) {
            ui.paint.fillRRectCorners(ctx, r.x, r.y, r.w, r.h, cor.tl, cor.tr, cor.br, cor.bl, container);
        }
        // state layer (enabled only): the on-color blended over the
        // container; over a transparent container the layer is the
        // on-color AT the state alpha (lerping from transparent black
        // would scale the RGB by the alpha twice in the src-over blend).
        if (def.enabled) {
            const alpha: f32 = if (s.pressed == idx)
                t.state.pressed
            else if (focused and s.focus_idx == idx)
                t.state.focus
            else if (s.hovered == idx)
                t.state.hover
            else
                0;
            if (alpha > 0) {
                const layer = if (container & 0xFF == 0)
                    ui.paint.withAlphaScaled(vc.on, alpha)
                else
                    theme_mod.stateLayer(container, vc.on, alpha);
                ui.paint.fillRRectCorners(ctx, r.x, r.y, r.w, r.h, cor.tl, cor.tr, cor.br, cor.bl, layer);
            }
        }
        // content: [icon, gap, label] centered
        const fg: Color = if (def.enabled) vc.on else vc.disabled_on;
        const lm = ui.paint.measureText(def.label, ls.size, bold);
        var content_w = lm.width;
        if (def.icon != null) content_w += d.icon + d.icon_gap;
        const cx = r.x + (r.w - content_w) / 2;
        const baseline = r.y + (r.h - lm.height) / 2 + lm.ascent;
        var tx = cx;
        if (def.icon) |iname| {
            paintIcon(ctx, iname, tx, r.y + (r.h - d.icon) / 2, d.icon, fg);
            tx += d.icon + d.icon_gap;
        }
        ui.paint.text(ctx, def.label, tx, baseline, ls.size, bold, fg);
        ui.paint.clipReset(ctx); // restores
        // outline variant's border — over the state layer, centered on the
        // edge like the button's own stroke.
        if (s.opts.variant == .outlined) {
            const oc: Color = if (def.enabled) vc.outline else vc.disabled_outline;
            ui.paint.strokeRRectCorners(ctx, r.x, r.y, r.w, r.h, cor.tl, cor.tr, cor.br, cor.bl, d.outline_width, oc);
        }
    }
}

fn groupOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    const b = n.bounds;
    switch (ev.phase) {
        .down => {
            const hit = itemAt(s, b, ev.x); // rects and events are window-space
            if (hit < 0) return false;
            if (!s.items.items[@intCast(hit)].enabled) return true; // claim, don't press
            s.pressed = hit;
            s.focus_idx = hit;
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            n.markDirty();
            return true;
        },
        .up => {
            // Click = down + up on the same item (the router captured us).
            const was = s.pressed;
            s.pressed = -1;
            n.markDirty();
            if (was >= 0 and itemAt(s, b, ev.x) == was) {
                const def = s.items.items[@intCast(was)];
                if (def.on_press) |cb| cb.fn_ptr(cb.userdata);
            }
            return true;
        },
        .move => {
            // A drag past the touch slop is a scroll, not a press: cancel
            // and bubble (return false → the scrollable ancestor claims).
            if (s.pressed >= 0) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.pressed = -1;
                    n.markDirty();
                }
            }
            // hover follows the item under the pointer (hover_move re-enters)
            const hit = itemAt(s, b, ev.x);
            if (hit != s.hovered) {
                s.hovered = hit;
                n.markDirty();
            }
            return s.pressed >= 0;
        },
        // the pointer went down outside while we held the capture: cancel
        .outside_down => {
            s.pressed = -1;
            n.markDirty();
            return true;
        },
        .enter => {
            s.hovered = itemAt(s, b, ev.x);
            n.markDirty();
            return true;
        },
        .leave => {
            s.hovered = -1;
            n.markDirty();
            return true;
        },
        else => {},
    }
    return false;
}

/// Arrows move the focus between enabled items (RTL flips left/right —
/// the row itself is already mirrored); Enter/Space fires the focused item.
fn groupOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind != .key_down) return false;
    const count: i32 = @intCast(s.items.items.len);
    if (count == 0) return false;
    const rtl = ui.i18n.direction() == .rtl;
    switch (ev.key) {
        .left, .right => {
            const fwd = (ev.key == .right) != rtl;
            var i = s.focus_idx;
            var step: usize = 0;
            while (step < @as(usize, @intCast(count))) : (step += 1) {
                i = if (fwd)
                    @mod(i + 1, count)
                else
                    @mod(i - 1, count);
                if (s.items.items[@intCast(i)].enabled) break;
            }
            if (i != s.focus_idx) {
                s.focus_idx = i;
                s.hovered = i;
                n.markDirty();
            }
            return true;
        },
        .enter, .space => {
            if (s.focus_idx >= 0) {
                const def = s.items.items[@intCast(s.focus_idx)];
                if (def.enabled) {
                    if (def.on_press) |cb| cb.fn_ptr(cb.userdata);
                    return true;
                }
            }
            return false;
        },
        else => {},
    }
    return false;
}

fn groupDeinit(n: *Node) void {
    const s = stateOf(n);
    for (s.items.items) |*def| n.allocator.free(def.label);
    s.items.deinit();
    s.widths.deinit();
    s.sem_children.deinit();
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = groupLocaleCb, .userdata = n });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

/// The interactive target: ≥ hit_target_min tall centered on the group —
/// medium/large heights already exceed it; the smaller ones pad the hit
/// area only.
fn groupHitBounds(n: *Node) Rect {
    const s = stateOf(n);
    const b = n.bounds;
    const h = @max(b.h, s.opts.theme.platform.hit_target_min);
    return .{ .x = b.x, .y = b.y + (b.h - h) / 2, .w = b.w, .h = h };
}

/// The group label is tr()-resolved — the locale callback re-attaches in
/// the new locale (the item children are app strings, verbatim).
fn attachGroupSemantics(n: *Node) void {
    const s = stateOf(n);
    ui.semantics.attach(n, .{
        .role = .group,
        .label = i18n_mod.tr("Button group"),
        .focusable = true, // takes the keyboard focus (arrow nav)
        .children = s.sem_children.items,
        .child_bounds = groupChildBounds,
    });
}

fn groupLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    attachGroupSemantics(n);
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

const group_vtable = ui.node.VTable{
    .measure = groupMeasure,
    .layout = groupLayout,
    .paint = groupPaint,
    .deinit = groupDeinit,
    .on_pointer = groupOnPointer,
    .on_key = groupOnKey,
    .hit_bounds = groupHitBounds,
};

/// An M3E button group. The items are internal chrome painted by the widget
/// (a leaf — no document children). `items` are copied (the labels are
/// owned); each item fires its own `on_press` on click (or Enter/Space when
/// focused).
pub fn buttonGroup(allocator: std.mem.Allocator, items: []const ButtonGroupItem, opts: ButtonGroupOptions) !*Node {
    const node = try Node.create(allocator, &group_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(GroupState);
    errdefer allocator.destroy(s);
    s.* = .{
        .items = std.array_list.Managed(ItemDef).init(allocator),
        .widths = std.array_list.Managed(f32).init(allocator),
        .sem_children = std.array_list.Managed(ui.semantics.Semantics).init(allocator),
        .opts = opts,
    };
    // One ownership boundary: on ANY failure this errdefer frees the
    // appended defs' labels (groupDeinit owns them only once returned).
    errdefer {
        for (s.items.items) |*def| allocator.free(def.label);
        s.items.deinit();
        s.widths.deinit();
    }
    for (items) |item| {
        const label = try dupeZ(allocator, item.label);
        errdefer allocator.free(label); // iteration scope
        try s.items.append(.{ .label = label, .icon = item.icon, .on_press = item.on_press, .enabled = item.enabled });
        try s.widths.append(itemContentWidth(opts.theme, opts, s.items.items[s.items.items.len - 1]));
    }
    node.state = s;
    // Per-item virtual a11y children — VoiceOver reads/activates each
    // button, not just an opaque group.
    for (s.items.items) |*def| {
        s.sem_children.append(.{
            .role = .button,
            .label = def.label,
            .disabled = !def.enabled,
            .actions = ui.semantics.Actions.initOne(.activate),
        }) catch @panic("klaxon: out of memory");
    }
    attachGroupSemantics(node);
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = groupLocaleCb, .userdata = node });
    return node;
}

// --- tests ---

var press_count: u32 = 0;
fn pressCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "golden: connected row — outer corners full, inner corners collapsed" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try buttonGroup(a, &.{ .{ .label = "Copy" }, .{ .label = "Paste" } }, .{ .theme = t });
    defer n.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 240, .h = 56 });
    var r = try golden.Renderer.init(std.testing.allocator, 280, 80);
    defer r.deinit();
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the primary fill covers the row
    try golden.expectPixelApprox(f, 30, 38, t.colors.primary);
    // the outer corner (first item's left edge, top) is rounded — the fill
    // must not reach the corner pixel
    try golden.expectPixelApprox(f, 10, 10, 0xFFFFFFFF);
    // the 2dp gap between items shows the background through the seam's
    // vertical center
    const s = stateOf(n);
    const scale = widthScale(s, n.bounds);
    const seam_x: i32 = @intFromFloat(10 + s.widths.items[0] * scale + 1);
    try golden.expectPixelApprox(f, seam_x, 38, 0xFFFFFFFF);
}

test "button_group: click fires the item under the pointer" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    var c1: u32 = 0;
    var c2: u32 = 0;
    const n = try buttonGroup(a, &.{
        .{ .label = "Copy", .on_press = .{ .fn_ptr = pressCb, .userdata = &c1 } },
        .{ .label = "Paste", .on_press = .{ .fn_ptr = pressCb, .userdata = &c2 } },
    }, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 200, .h = 56 });
    const s = stateOf(n);
    const r2 = itemRectLtr(s, n.bounds, 1);
    const r1 = itemRectLtr(s, n.bounds, 0);
    // click item 2
    router.dispatchPointer(n, .{ .phase = .down, .x = r2.x + r2.w / 2, .y = 28 });
    router.dispatchPointer(n, .{ .phase = .up, .x = r2.x + r2.w / 2, .y = 28 });
    try std.testing.expectEqual(@as(u32, 0), c1);
    try std.testing.expectEqual(@as(u32, 1), c2);
    // click item 1
    router.dispatchPointer(n, .{ .phase = .down, .x = r1.x + r1.w / 2, .y = 28 });
    router.dispatchPointer(n, .{ .phase = .up, .x = r1.x + r1.w / 2, .y = 28 });
    try std.testing.expectEqual(@as(u32, 1), c1);
    // the 2dp seam between items is a dead zone
    router.dispatchPointer(n, .{ .phase = .down, .x = r1.x + r1.w + 1, .y = 28 });
    router.dispatchPointer(n, .{ .phase = .up, .x = r1.x + r1.w + 1, .y = 28 });
    try std.testing.expectEqual(@as(u32, 1), c1);
    try std.testing.expectEqual(@as(u32, 1), c2);
}

test "button_group: pressed item morphs its inner corners to extra-small (M3E squeeze)" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try buttonGroup(a, &.{ .{ .label = "Copy" }, .{ .label = "Paste" }, .{ .label = "Cut" } }, .{ .theme = t });
    defer n.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 300, .h = 56 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // press the middle item — all four of its corners are inner, so all
    // four take PressedInnerCornerCornerSize (4dp)
    const r2 = itemRectLtr(stateOf(n), n.bounds, 1);
    const mid_x = r2.x + r2.w / 2;
    router.dispatchPointer(n, .{ .phase = .down, .x = mid_x, .y = 38 });
    try std.testing.expectEqual(@as(i32, 1), stateOf(n).pressed);
    const cor = itemCorners(stateOf(n), r2.h, 1);
    try std.testing.expectEqual(inner_corner_pressed, cor.tl);
    try std.testing.expectEqual(inner_corner_pressed, cor.tr);
    // an END item's outer corners keep the button shape while its inner
    // corners morph
    const cor0 = itemCorners(stateOf(n), r2.h, 0);
    try std.testing.expectEqual(r2.h / 2, cor0.tl); // untouched while unpressed
    router.dispatchPointer(n, .{ .phase = .up, .x = mid_x, .y = 38 });
    // press item 0: its inner (right) corners morph; outer (left) stay round
    const r1 = itemRectLtr(stateOf(n), n.bounds, 0);
    router.dispatchPointer(n, .{ .phase = .down, .x = r1.x + r1.w / 2, .y = 38 });
    const cor0p = itemCorners(stateOf(n), r2.h, 0);
    try std.testing.expectEqual(r2.h / 2, cor0p.tl); // outer stays
    try std.testing.expectEqual(inner_corner_pressed, cor0p.tr); // inner morphs
    router.dispatchPointer(n, .{ .phase = .up, .x = r1.x + r1.w / 2, .y = 38 });
}

test "button_group: disabled item claims but does not fire" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    var c: u32 = 0;
    const n = try buttonGroup(a, &.{
        .{ .label = "Copy", .on_press = .{ .fn_ptr = pressCb, .userdata = &c }, .enabled = false },
        .{ .label = "Paste", .on_press = .{ .fn_ptr = pressCb, .userdata = &c } },
    }, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 200, .h = 56 });
    router.dispatchPointer(n, .{ .phase = .down, .x = 20, .y = 28 });
    router.dispatchPointer(n, .{ .phase = .up, .x = 20, .y = 28 });
    try std.testing.expectEqual(@as(u32, 0), c);
    try std.testing.expectEqual(@as(i32, -1), stateOf(n).pressed); // never pressed
}

test "button_group: i18n — the framework label localizes + re-resolves on a locale switch" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Button group\": \"Grupo de botones\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const n = try buttonGroup(a, &.{ .{ .label = "Copy" }, .{ .label = "Paste" } }, .{});
    defer n.deinit();
    try std.testing.expectEqualStrings("Grupo de botones", n.semantics.?.label);
    try i18n.setLocale("en");
    const sem = n.semantics.?;
    try std.testing.expectEqualStrings("Button group", sem.label);
    try std.testing.expectEqual(@as(usize, 2), sem.children.len);
}
