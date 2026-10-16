// Tooltip — ported 1:1 from Compose Tooltip.kt (PlainTooltip + RichTooltip).
//
// Upstream: .ref/material3/Tooltip.kt — PlainTooltip, RichTooltip,
// TooltipDefaults (caretSize 16×8, plainTooltipMaxWidth 200,
// richTooltipMaxWidth 320), TooltipPositionProvider (TooltipAnchorPosition:
// Above/Below/Left/Right/Start/End, SpacingBetweenTooltipAndAnchor = 4),
// DefaultTooltipCaretShape (triangle), internal metrics
// (TooltipMinHeight 24, TooltipMinWidth 40, PlainTooltipContentPadding 8/4,
// RichTooltipHorizontalPadding 16, HeightToSubheadFirstLine 28,
// HeightFromSubheadToTextFirstLine 24, TextBottomPadding 16,
// ActionLabelMinHeight 36, ActionLabelBottomPadding 8).
// Tokens: PlainTooltipTokens (inverse_surface, CornerExtraSmall,
// inverse_on_surface body_small), RichTooltipTokens (surface_container,
// CornerMedium, Level2, title_small + body_medium on_surface_variant,
// label_large primary).
//
// Not ported: Popup machinery, mutator-mutex single-tooltip arbitration,
// touch long-press invocation, isPersistent click-outside dismiss — our
// wrapper is hover-driven (the Compose equivalent of a non-persistent
// tooltip triggered by pointer hover).
//
// Structure: the wrapper holds an internal bubble (child 0, `internal` —
// skipped by registry serialization, rebuilt by the factory) and the anchor
// (document data — the wrapper finds it as its first non-internal child, so
// child order does not matter). The bubble paints OUTSIDE the wrapper's bounds
// (above the anchor) and is not hit-testable (hit_bounds = empty rect), so
// moving the pointer onto it reads as leaving the anchor. The fade is a
// layer-alpha around the bubble's children (ABI 0.4.0, save-balanced).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const anim = ui.anim;
const node_mod = ui.node;
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

/// M3E measurement tokens (Compose Tooltip.kt / PlainTooltipTokens).
const max_width: f32 = 200; // plainTooltipMaxWidth
const rich_max_width: f32 = 320; // richTooltipMaxWidth
const min_height: f32 = 24; // TooltipMinHeight
const min_width: f32 = 40; // TooltipMinWidth
const padding_h: f32 = 8; // PlainTooltipHorizontalPadding
const padding_v: f32 = 4; // PlainTooltipVerticalPadding
const anchor_spacing: f32 = 4; // SpacingBetweenTooltipAndAnchor
const corner: f32 = 4; // CornerExtraSmall
const fade_ms: u32 = 150;
// caret (TooltipDefaults.caretSize = 16×8dp)
const caret_w: f32 = 16;
const caret_h: f32 = 8;
// rich tooltip internals (Tooltip.kt)
const rich_padding_h: f32 = 16; // RichTooltipHorizontalPadding
const rich_corner: f32 = 12; // CornerMedium
const title_baseline_top: f32 = 28; // HeightToSubheadFirstLine
const text_baseline_top: f32 = 24; // HeightFromSubheadToTextFirstLine
const text_bottom: f32 = 16; // TextBottomPadding
const action_min_h: f32 = 36; // ActionLabelMinHeight
const action_bottom: f32 = 8; // ActionLabelBottomPadding

/// TooltipAnchorPosition — the side of the anchor the tooltip sits on.
/// start/end are layout-direction aware (start = left in LTR, right in RTL).
pub const Placement = enum { above, below, start, end };

pub const TooltipOptions = struct {
    text: []const u8 = "",
    theme: Theme = theme_mod.light,
    /// Draw the upstream 16×8dp caret pointing at the anchor.
    caret: bool = false,
    placement: Placement = .above,
};

/// Rich tooltip content: an optional title, the supporting text, an optional
/// action label — `richTooltip` builds the upstream column (title_small /
/// body_medium on_surface_variant, label_large primary action).
pub const RichTooltipOptions = struct {
    title: ?[]const u8 = null,
    text: []const u8 = "",
    action: ?[]const u8 = null,
    theme: Theme = theme_mod.light,
    caret: bool = false,
    placement: Placement = .above,
};

const TooltipState = struct {
    theme: Theme,
    caret: bool,
    placement: Placement,
    rich: bool = false, // plain | rich variant (tokens + bubble vtable differ)
    has_title: bool = false, // rich: a subhead child precedes the text
    has_action: bool = false, // rich: an action label follows the text
    bubble: *Node, // internal bubble node
    alpha: f32 = 0, // 0 = hidden, 1 = shown
    anim_to: f32 = 0,
    anim_channel: u8 = 0, // channel marker (stable address)
};

fn stateOf(n: *Node) *TooltipState {
    return @ptrCast(@alignCast(n.state.?));
}

// --- wrapper (anchor + bubble) ---

/// The anchor: the first non-internal child (the bubble is internal chrome;
/// child order does not matter — the registry appends document children).
fn anchorOf(n: *Node) ?*Node {
    for (n.children.items) |child| {
        if (!child.internal) return child;
    }
    return null;
}

fn tooltipMeasure(n: *Node, c: Constraints) Size {
    // the wrapper is the anchor's size — the bubble never expands it
    const anchor = anchorOf(n) orelse return c.constrain(.{});
    return anchor.measure(c);
}

/// Resolve `placement` to a concrete side (start/end follow the layout
/// direction: start = left in LTR, right in RTL).
fn sideOf(s: *const TooltipState) enum { above, below, left, right } {
    const rtl = ui.i18n.direction() == .rtl;
    return switch (s.placement) {
        .above => .above,
        .below => .below,
        .start => if (rtl) .right else .left,
        .end => if (rtl) .left else .right,
    };
}

fn tooltipLayout(n: *Node, bounds: Rect) void {
    const anchor = anchorOf(n) orelse return;
    anchor.layout(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bounds.h });
    const s = stateOf(n);
    const bubble = s.bubble;
    // measure the bubble (capped at the variant's max width), place it on the
    // resolved side, centered on the anchor, 4dp spacing
    const mw = if (s.rich) rich_max_width else max_width;
    const cs = bubble.measure(.{ .max_w = mw, .max_h = 400 });
    const bw = @min(@max(min_width, cs.w), mw);
    const bh = @max(min_height, cs.h);
    const br: Rect = switch (sideOf(s)) {
        .above => .{ .x = bounds.x + (bounds.w - bw) / 2, .y = bounds.y - anchor_spacing - bh, .w = bw, .h = bh },
        .below => .{ .x = bounds.x + (bounds.w - bw) / 2, .y = bounds.y + bounds.h + anchor_spacing, .w = bw, .h = bh },
        .left => .{ .x = bounds.x - anchor_spacing - bw, .y = bounds.y + (bounds.h - bh) / 2, .w = bw, .h = bh },
        .right => .{ .x = bounds.x + bounds.w + anchor_spacing, .y = bounds.y + (bounds.h - bh) / 2, .w = bw, .h = bh },
    };
    bubble.layout(br);
}

fn tooltipOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    switch (ev.phase) {
        .enter, .hover_move => {
            // hover_move: the deepest node under the pointer changed within
            // the anchor's subtree — still hovering the anchor
            setShown(n, s, true);
            return true;
        },
        .leave => {
            setShown(n, s, false);
            return true;
        },
        else => return false,
    }
}

fn tooltipDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel));
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const tooltip_vtable = ui.node.VTable{
    .measure = tooltipMeasure,
    .layout = tooltipLayout,
    .paint = struct {
        fn p(n: *Node, ctx: *kx.Ctx) void {
            _ = n;
            _ = ctx; // transparent: the anchor child paints
        }
    }.p,
    .on_pointer = tooltipOnPointer,
    .deinit = tooltipDeinit,
};

/// Show/hide: fade the bubble's alpha (tween; snaps without a timeline).
fn setShown(n: *Node, s: *TooltipState, shown: bool) void {
    const target: f32 = if (shown) 1 else 0;
    if (target == s.anim_to) return;
    s.anim_to = target;
    s.bubble.setVisible(true); // paint while fading (even out)
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.tweenAnim(.{ target, 0, 0, 0 }, fade_ms, .{ .ease = .standard }),
            .from = .{ s.alpha, 0, 0, 0 },
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = tooltipAlphaCb, .userdata = n },
            .on_complete = .{ .fn_ptr = tooltipAlphaDoneCb, .userdata = n },
        });
    } else {
        s.alpha = target;
        if (!shown) s.bubble.setVisible(false);
        s.bubble.markDirty();
    }
}

fn tooltipAlphaCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.alpha = value[0];
    s.bubble.markDirty();
}

fn tooltipAlphaDoneCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.anim_to < 0.5) s.bubble.setVisible(false); // faded out: skip the paint
}

// --- bubble (internal): container + text, faded via a layer alpha ---

fn bubblePreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    // own save + the layer's save (saveLayerAlphaf pushes one): both are
    // restored in post_children_paint so a caller's canvas state survives
    ui.paint.save(ctx);
    const s = stateOf(n.parent.?);
    ui.paint.layerAlpha(ctx, s.alpha);
}

fn bubblePostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.restore(ctx); // pops the layer
    ui.paint.restore(ctx); // pops the own save
}

fn bubbleHitBounds(n: *Node) Rect {
    _ = n;
    return .{}; // not hit-testable: the pointer over the bubble reads as left
}

fn bubbleDeinit(n: *Node) void {
    _ = n; // children freed by Node.deinit; no state
}

const bubble_vtable = ui.node.VTable{
    .measure = struct {
        fn m(n: *Node, c: Constraints) Size {
            // content (text) + padding; the wrapper caps the width
            var size = Size{};
            for (n.children.items) |child| {
                const cs = child.measure(c);
                size = .{ .w = @max(size.w, cs.w), .h = @max(size.h, cs.h) };
            }
            return c.constrain(.{
                .w = size.w + padding_h * 2,
                .h = @max(min_height, size.h + padding_v * 2),
            });
        }
    }.m,
    .layout = struct {
        fn l(n: *Node, bounds: Rect) void {
            for (n.children.items) |child| {
                const cs = child.measure(.{ .max_w = bounds.w - padding_h * 2, .max_h = bounds.h - padding_v * 2 });
                child.layout(.{
                    .x = bounds.x + (bounds.w - cs.w) / 2,
                    .y = bounds.y + (bounds.h - cs.h) / 2,
                    .w = cs.w,
                    .h = cs.h,
                });
            }
        }
    }.l,
    .paint = struct {
        fn p(n: *Node, ctx: *kx.Ctx) void {
            const b = n.bounds;
            const s = stateOf(n.parent.?);
            const c = tooltipBubbleColor(n);
            ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, corner, c);
            if (s.caret) paintCaret(n, ctx, b, c);
        }
    }.p,
    .pre_children_paint = bubblePreChildrenPaint,
    .post_children_paint = bubblePostChildrenPaint,
    .hit_bounds = bubbleHitBounds,
    .deinit = bubbleDeinit,
};

fn tooltipBubbleColor(n: *Node) Color {
    const s = stateOf(n.parent.?);
    return if (s.rich) s.theme.colors.surface_container else s.theme.colors.inverse_surface;
}

/// The 16×8dp caret (DefaultTooltipCaretShape): a triangle whose base sits on
/// the anchor-facing edge, apex 8dp toward the anchor — painted the container
/// color so it reads as part of the shape (upstream unions it into the path).
fn paintCaret(bubble: *Node, ctx: *kx.Ctx, b: Rect, color: Color) void {
    const parent = bubble.parent.?;
    const s = stateOf(parent);
    const anchor = anchorOf(parent) orelse return;
    const a = anchor.bounds;
    var xs: [3]f32 = undefined;
    var ys: [3]f32 = undefined;
    switch (sideOf(s)) {
        .above => {
            // hangs below the bubble, pointing down; centered on the anchor
            const cx = @min(@max(a.x + a.w / 2, b.x + caret_w / 2 + corner), b.x + b.w - caret_w / 2 - corner);
            xs = .{ cx - caret_w / 2, cx + caret_w / 2, cx };
            ys = .{ b.y + b.h - 1, b.y + b.h - 1, b.y + b.h - 1 + caret_h };
        },
        .below => {
            const cx = @min(@max(a.x + a.w / 2, b.x + caret_w / 2 + corner), b.x + b.w - caret_w / 2 - corner);
            xs = .{ cx - caret_w / 2, cx + caret_w / 2, cx };
            ys = .{ b.y + 1, b.y + 1, b.y + 1 - caret_h };
        },
        .left => {
            const cy = @min(@max(a.y + a.h / 2, b.y + caret_w / 2 + corner), b.y + b.h - caret_w / 2 - corner);
            xs = .{ b.x + b.w - 1, b.x + b.w - 1, b.x + b.w - 1 + caret_h };
            ys = .{ cy - caret_w / 2, cy + caret_w / 2, cy };
        },
        .right => {
            const cy = @min(@max(a.y + a.h / 2, b.y + caret_w / 2 + corner), b.y + b.h - caret_w / 2 - corner);
            xs = .{ b.x + 1, b.x + 1, b.x + 1 - caret_h };
            ys = .{ cy - caret_w / 2, cy + caret_w / 2, cy };
        },
    }
    ui.paint.fillPolygon(ctx, &xs, &ys, color);
}

/// A plain tooltip over `anchor`: hover shows the bubble above the anchor
/// (fade), leaving hides it. The anchor is the document child; the bubble is
/// internal chrome (rebuilt by this factory, skipped by serialization).
pub fn tooltip(allocator: std.mem.Allocator, anchor: *Node, opts: TooltipOptions) !*Node {
    const node = try tooltipShell(allocator, opts);
    errdefer allocator.destroy(node);
    node.add(anchor);
    return node;
}

/// The tooltip wrapper without the anchor (the registry builds document
/// children after the node — the wrapper finds the anchor as its first
/// non-internal child).
pub fn tooltipShell(allocator: std.mem.Allocator, opts: TooltipOptions) !*Node {
    const node = try Node.create(allocator, &tooltip_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(TooltipState);
    errdefer allocator.destroy(s);
    // Internal bubble: inverse_surface container + the label text.
    const bubble = try Node.create(allocator, &bubble_vtable);
    errdefer allocator.destroy(bubble);
    bubble.internal = true; // registry: not document data
    bubble.setVisible(false); // hidden until the first hover
    const t = opts.theme;
    bubble.add(try text_w.text(allocator, opts.text, .{
        .size = t.type_scale.body_small.size,
        .color = t.colors.inverse_on_surface,
    }));
    ui.semantics.attach(bubble.children.items[0], .{ .role = .text, .label = opts.text });
    s.* = .{ .theme = t, .caret = opts.caret, .placement = opts.placement, .bubble = bubble };
    node.state = s;
    node.add(bubble);
    return node;
}

// --- rich tooltip (RichTooltip.kt): title + supporting text + action ---

const text_w = @import("text.zig");

const rich_bubble_vtable = ui.node.VTable{
    .measure = struct {
        fn m(n: *Node, c: Constraints) Size {
            // children: [title?, text, action?] — width = widest + 2×16,
            // height = the baseline-driven column (see layout)
            const s = stateOf(n.parent.?);
            const inner: Constraints = .{ .max_w = @max(0, c.max_w - rich_padding_h * 2), .max_h = c.max_h };
            var w: f32 = 0;
            var h: f32 = 0;
            var i: usize = 0;
            for (n.children.items) |child| {
                const cs = child.measure(inner);
                w = @max(w, cs.w);
                const body = i == (if (s.has_title) @as(usize, 1) else 0);
                const baseline = text_w.textBaseline(child);
                if (body) {
                    // textVerticalPadding: plain 4/4 when alone, else
                    // baseline 24 top + TextBottomPadding 16
                    h += if (s.has_title or s.has_action)
                        (text_baseline_top - baseline) + cs.h + text_bottom
                    else
                        padding_v * 2 + cs.h;
                } else if (i == 0 and s.has_title) {
                    h += title_baseline_top - baseline + cs.h; // subhead box
                } else {
                    h += @max(action_min_h, cs.h + action_bottom); // action box
                }
                i += 1;
            }
            return c.constrain(.{ .w = @max(min_width, w + rich_padding_h * 2), .h = @max(min_height, h) });
        }
    }.m,
    .layout = struct {
        fn l(n: *Node, bounds: Rect) void {
            const s = stateOf(n.parent.?);
            const inner_w = bounds.w - rich_padding_h * 2;
            const inner: Constraints = .{ .max_w = inner_w, .max_h = bounds.h };
            var y = bounds.y;
            var i: usize = 0;
            for (n.children.items) |child| {
                const cs = child.measure(inner);
                const body = i == (if (s.has_title) @as(usize, 1) else 0);
                const baseline = text_w.textBaseline(child);
                const extras = s.has_title or s.has_action;
                if (body) {
                    const top_pad = if (extras) text_baseline_top - baseline else padding_v;
                    const bot_pad = if (extras) text_bottom else padding_v;
                    child.layout(.{ .x = bounds.x + rich_padding_h, .y = y + top_pad, .w = cs.w, .h = cs.h });
                    y += top_pad + cs.h + bot_pad;
                } else if (i == 0 and s.has_title) {
                    // subhead: first baseline 28 below the box top
                    child.layout(.{ .x = bounds.x + rich_padding_h, .y = y + title_baseline_top - baseline, .w = cs.w, .h = cs.h });
                    y += title_baseline_top - baseline + cs.h;
                } else {
                    // action label: ≥36 box, 8 bottom padding, label at top
                    child.layout(.{ .x = bounds.x + rich_padding_h, .y = y, .w = cs.w, .h = cs.h });
                    y += @max(action_min_h, cs.h + action_bottom);
                }
                i += 1;
            }
        }
    }.l,
    .paint = struct {
        fn p(n: *Node, ctx: *kx.Ctx) void {
            const b = n.bounds;
            const s = stateOf(n.parent.?);
            const c = tooltipBubbleColor(n);
            // RichTooltipTokens.ContainerElevation = Level2
            ui.paint.elevationShadow(ctx, b.x, b.y, b.w, b.h, rich_corner, 3, s.theme.colors.shadow);
            ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, rich_corner, c);
            if (s.caret) paintCaret(n, ctx, b, c);
        }
    }.p,
    .pre_children_paint = bubblePreChildrenPaint,
    .post_children_paint = bubblePostChildrenPaint,
    .hit_bounds = bubbleHitBounds,
    .deinit = bubbleDeinit,
};

/// A rich tooltip: title (title_small), supporting text (body_medium) and an
/// optional action label (label_large primary) in a surface_container card.
pub fn richTooltip(allocator: std.mem.Allocator, anchor: *Node, opts: RichTooltipOptions) !*Node {
    const node = try richTooltipShell(allocator, opts);
    errdefer allocator.destroy(node);
    node.add(anchor);
    return node;
}

pub fn richTooltipShell(allocator: std.mem.Allocator, opts: RichTooltipOptions) !*Node {
    const node = try Node.create(allocator, &tooltip_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(TooltipState);
    errdefer allocator.destroy(s);
    const bubble = try Node.create(allocator, &rich_bubble_vtable);
    errdefer allocator.destroy(bubble);
    bubble.internal = true;
    bubble.setVisible(false);
    const t = opts.theme;
    if (opts.title) |title| {
        bubble.add(try text_w.text(allocator, title, .{
            .size = t.type_scale.title_small.size,
            .color = t.colors.on_surface_variant,
        }));
    }
    bubble.add(try text_w.text(allocator, opts.text, .{
        .size = t.type_scale.body_medium.size,
        .color = t.colors.on_surface_variant,
    }));
    if (opts.action) |action| {
        bubble.add(try text_w.text(allocator, action, .{
            .size = t.type_scale.label_large.size,
            .color = t.colors.primary,
        }));
    }
    ui.semantics.attach(bubble.children.items[if (opts.title != null) 1 else 0], .{ .role = .text, .label = opts.text });
    s.* = .{ .theme = t, .caret = opts.caret, .placement = opts.placement, .rich = true, .has_title = opts.title != null, .has_action = opts.action != null, .bubble = bubble };
    node.state = s;
    node.add(bubble);
    return node;
}

// --- tests ---

const layout_w = @import("layout.zig");

test "tooltip: the wrapper measures the anchor; the bubble sits above it" {
    const t = theme_mod.light;
    const anchor = try golden.solidBox(std.testing.allocator, 80, 24, 0x112233FF);
    const tip = try tooltip(std.testing.allocator, anchor, .{ .text = "Save", .theme = t });
    defer tip.deinit();
    const m = tip.measure(.{ .max_w = 400, .max_h = 400 });
    try std.testing.expectEqual(@as(f32, 80), m.w);
    try std.testing.expectEqual(@as(f32, 24), m.h);
    tip.layout(.{ .x = 100, .y = 100, .w = 80, .h = 24 });
    const s = stateOf(tip);
    const bb = s.bubble.bounds;
    // above the anchor, horizontally centered, 4dp spacing, min height 24
    try std.testing.expect(bb.y + bb.h <= 100 - anchor_spacing + 0.01);
    try std.testing.expect(bb.h >= min_height);
    try std.testing.expect(bb.w >= min_width);
    try std.testing.expect(bb.w <= max_width);
    try std.testing.expect(std.math.approxEqAbs(f32, 100 + 40, bb.x + bb.w / 2, 0.01)); // centered on the anchor
    // hidden until hovered; the bubble is internal (not document data)
    try std.testing.expect(!s.bubble.visible);
    try std.testing.expect(s.bubble.internal);
}

test "tooltip: hover shows the bubble (snap without a timeline), leave hides it" {
    const anchor = try golden.solidBox(std.testing.allocator, 80, 24, 0x112233FF);
    const tip = try tooltip(std.testing.allocator, anchor, .{ .text = "Save" });
    defer tip.deinit();
    tip.layout(.{ .x = 0, .y = 100, .w = 80, .h = 24 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const s = stateOf(tip);
    try std.testing.expect(!s.bubble.visible);
    // hover the anchor: the router hit-tests the anchor (deepest node), the
    // enter bubbles to the wrapper
    router.dispatchPointer(tip, .{ .phase = .move, .x = 40, .y = 112 });
    try std.testing.expect(s.bubble.visible);
    try std.testing.expectEqual(@as(f32, 1), s.alpha);
    // leave: hidden again
    router.dispatchPointer(tip, .{ .phase = .move, .x = 40, .y = 200 });
    try std.testing.expect(!s.bubble.visible);
    try std.testing.expectEqual(@as(f32, 0), s.alpha);
}

test "golden: the tooltip bubble paints the inverse surface over the anchor" {
    const t = theme_mod.light;
    const anchor = try golden.solidBox(std.testing.allocator, 80, 24, 0x112233FF);
    const tip = try tooltip(std.testing.allocator, anchor, .{ .text = "Save", .theme = t });
    defer tip.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 200);
    defer r.deinit();
    tip.layout(.{ .x = 60, .y = 100, .w = 80, .h = 24 });
    const s = stateOf(tip);
    // force the shown state (no timeline in tests: snap)
    setShown(tip, s, true);
    r.paint(tip, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const bb = s.bubble.bounds;
    // the bubble's center is the inverse surface color (the text ink sits on top)
    const cx: i32 = @intFromFloat(bb.x + 4);
    const cy: i32 = @intFromFloat(bb.y + bb.h / 2);
    try std.testing.expectEqual(t.colors.inverse_surface, f.pixelAt(cx, cy));
    // the anchor still paints at its own position
    try std.testing.expectEqual(@as(Color, 0x112233FF), f.pixelAt(100, 112));
}

test "tooltip: placement puts the bubble on each side of the anchor" {
    const anchor = try golden.solidBox(std.testing.allocator, 80, 24, 0x112233FF);
    const tip = try tooltip(std.testing.allocator, anchor, .{ .text = "Save" });
    defer tip.deinit();
    const s = stateOf(tip);
    tip.layout(.{ .x = 100, .y = 100, .w = 80, .h = 24 });
    // below: the bubble's top is 4dp under the anchor's bottom
    s.placement = .below;
    tip.markLayoutDirty();
    tip.layout(.{ .x = 100, .y = 100, .w = 80, .h = 24 });
    try std.testing.expect(std.math.approxEqAbs(f32, 124 + anchor_spacing, s.bubble.bounds.y, 0.01));
    try std.testing.expect(std.math.approxEqAbs(f32, 140, s.bubble.bounds.x + s.bubble.bounds.w / 2, 0.01));
    // end (LTR → right of the anchor), vertically centered
    s.placement = .end;
    tip.markLayoutDirty();
    tip.layout(.{ .x = 100, .y = 100, .w = 80, .h = 24 });
    try std.testing.expect(std.math.approxEqAbs(f32, 180 + anchor_spacing, s.bubble.bounds.x, 0.01));
    try std.testing.expect(std.math.approxEqAbs(f32, 112, s.bubble.bounds.y + s.bubble.bounds.h / 2, 0.01));
    // start (LTR → left of the anchor)
    s.placement = .start;
    tip.markLayoutDirty();
    tip.layout(.{ .x = 100, .y = 100, .w = 80, .h = 24 });
    try std.testing.expect(std.math.approxEqAbs(f32, 100 - anchor_spacing, s.bubble.bounds.x + s.bubble.bounds.w, 0.01));
}

test "golden: a caret tooltip paints the 16x8 caret pointing at the anchor" {
    const t = theme_mod.light;
    const anchor = try golden.solidBox(std.testing.allocator, 80, 24, 0x112233FF);
    const tip = try tooltip(std.testing.allocator, anchor, .{ .text = "Save", .theme = t, .caret = true });
    defer tip.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 200);
    defer r.deinit();
    tip.layout(.{ .x = 60, .y = 100, .w = 80, .h = 24 });
    const s = stateOf(tip);
    setShown(tip, s, true);
    r.paint(tip, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const bb = s.bubble.bounds;
    // the caret: below the bubble's bottom edge, centered on the anchor
    // (100 = anchor center x) — probed mid-triangle so AA edges don't matter
    try std.testing.expectEqual(t.colors.inverse_surface, f.pixelAt(100, @intFromFloat(bb.y + bb.h + 2)));
    // the caret is bounded to ±8 around the anchor center: 16px out, the
    // same row is the anchor's own fill (not the bubble color)
    const side_x: i32 = @intFromFloat(bb.x + bb.w / 2 + caret_w);
    try std.testing.expectEqual(@as(Color, 0x112233FF), f.pixelAt(@min(side_x, 199), @intFromFloat(bb.y + bb.h + 4)));
}

test "tooltip: a rich tooltip lays title/text/action on the upstream baselines" {
    const t = theme_mod.light;
    const anchor = try golden.solidBox(std.testing.allocator, 80, 24, 0x112233FF);
    const tip = try richTooltip(std.testing.allocator, anchor, .{
        .title = "Permit",
        .text = "Allow the app to save files?",
        .action = "ALLOW",
        .theme = t,
    });
    defer tip.deinit();
    tip.layout(.{ .x = 100, .y = 200, .w = 80, .h = 24 });
    const s = stateOf(tip);
    const bb = s.bubble.bounds;
    // children: title, text, action — the title's first baseline sits 28dp
    // below the bubble top (HeightToSubheadFirstLine)
    const title_n = s.bubble.children.items[0];
    const body_n = s.bubble.children.items[1];
    const action_n = s.bubble.children.items[2];
    try std.testing.expect(std.math.approxEqAbs(f32, bb.y + title_baseline_top, title_n.bounds.y + text_w.textBaseline(title_n), 0.5));
    // the text's first baseline sits 24 below its box top
    // (HeightFromSubheadToTextFirstLine); the action box is ≥36
    try std.testing.expect(body_n.bounds.y > title_n.bounds.y);
    try std.testing.expect(action_n.bounds.y >= body_n.bounds.y + body_n.bounds.h + text_bottom - 0.01);
    try std.testing.expectEqual(t.colors.surface_container, blk: {
        var r = try golden.Renderer.init(std.testing.allocator, 320, 400);
        defer r.deinit();
        setShown(tip, s, true);
        r.paint(tip, 0x000000FF);
        var f = try r.readback(std.testing.allocator);
        defer f.deinit();
        break :blk f.pixelAt(@intFromFloat(bb.x + 4), @intFromFloat(bb.y + bb.h / 2));
    });
}

test "golden: an unhovered tooltip paints nothing above the anchor" {
    const t = theme_mod.light;
    const anchor = try golden.solidBox(std.testing.allocator, 80, 24, 0x112233FF);
    const tip = try tooltip(std.testing.allocator, anchor, .{ .text = "Save", .theme = t });
    defer tip.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 200);
    defer r.deinit();
    tip.layout(.{ .x = 60, .y = 100, .w = 80, .h = 24 });
    const s = stateOf(tip);
    const bb = s.bubble.bounds;
    // no hover: the bubble is invisible → its whole rect stays background
    try std.testing.expect(!s.bubble.visible);
    r.paint(tip, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const br: ui.node.Rect = .{ .x = bb.x, .y = bb.y, .w = bb.w, .h = bb.h };
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(br, t.colors.inverse_surface));
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(br, t.colors.inverse_on_surface));
    // the anchor still paints at its own position
    try std.testing.expectEqual(@as(Color, 0x112233FF), f.pixelAt(100, 112));
}
