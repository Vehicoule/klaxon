// SnackBar — 1:1 port of Compose material3 Snackbar.kt.
//
// Upstream sources (.ref/material3, androidx-main):
//   - Snackbar.kt: OneRowSnackbar (text + action + dismiss row layout),
//     NewLineButtonSnackbar (action_on_new_line two-row Column), the
//     SnackbarHost 12dp bottom margin + SnackbarHostState timeout behavior
//   - tokens/SnackbarTokens.kt: ContainerColor InverseSurface, shape
//     CornerExtraSmall (4dp), elevation Level3 (6dp), SingleLine 48 /
//     TwoLines 68 heights, SupportingText InverseOnSurface BodyMedium,
//     ActionLabelTextColor InversePrimary LabelLarge, IconColor
//     InverseOnSurface 24dp
//   - constants (Snackbar.kt file privates): ContainerMaxWidth 600,
//     HorizontalSpacing 16, TextEndExtraSpacing 8, SnackbarVerticalPadding
//     14, HeightToFirstLine 30, LongButtonVerticalOffset 12,
//     ActionButtonBottomPadding 4, SeparateButtonExtraY 2
//
// Ported: the row layout (text start, action+dismiss end, end padding 8
// without dismiss / 0 with), the new-line variant (action+dismiss row
// aligned end under the text, container fillMaxWidth up to 600), RTL
// mirroring (upstream placeRelative), the slide-up+fade enter/exit, the
// auto-dismiss ticker on the timeline, dismiss-on-action-press.
//
// Deviations: the text is a single-line label (upstream wraps BodyMedium
// over two lines — our text widget doesn't wrap; the action_on_new_line
// variant covers the long-text cases); the paddingFromBaseline text top
// offset is approximated as 30 - 0.8*textH (no font baseline plumbing);
// slide/fade is a 200ms standard-ease tween (upstream uses the platform
// in/out animation).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const i18n_mod = @import("../ui/i18n.zig");
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

/// M3E measurement tokens (Compose SnackbarTokens / Snackbar.kt).
const max_width: f32 = 600; // ContainerMaxWidth
const min_height: f32 = 48; // SingleLineContainerHeight
const corner: f32 = 4; // ContainerShape CornerExtraSmall
const start_padding: f32 = 16; // HorizontalSpacing
const end_padding: f32 = 8; // TextEndExtraSpacing (0 when a dismiss action)
const button_side_spacing: f32 = 8; // HorizontalSpacingButtonSide
const vertical_padding: f32 = 14; // SnackbarVerticalPadding
const first_line_h: f32 = 30; // HeightToFirstLine (new-line variant)
const long_btn_v_off: f32 = 12; // LongButtonVerticalOffset
const action_bottom_pad: f32 = 4; // ActionButtonBottomPadding
const separate_btn_extra_y: f32 = 2; // SeparateButtonExtraY
const two_lines_min_h: f32 = 68; // TwoLinesContainerHeight
const action_gap: f32 = 8;
// The slide/fade-in rides theme.motion.durations.short4 (200ms).

pub const SnackBarOptions = struct {
    text: []const u8 = "",
    action_label: ?[]const u8 = null,
    /// upstream actionOnNewLine — the action + dismiss move to a second row
    /// (recommended when the text is long / the action label is wide).
    action_on_new_line: bool = false,
    dismiss: bool = true, // show the dismiss icon button
    timeout_ms: u32 = 4000, // 0 = no auto-dismiss
    bottom_margin: f32 = 12, // from the parent's bottom edge (SnackbarHost)
    theme: Theme = theme_mod.light,
};

const Callback = ui.state.Callback;

const SnackBarState = struct {
    sig: *ui.state.Signal(bool),
    opts: SnackBarOptions,
    on_action: ?Callback = null,
    on_dismiss: ?Callback = null,
    bg: *Node, // internal background child
    content: Rect = .{}, // the content rect within the (possibly full-window) bounds
    progress: f32 = 0, // 0 = hidden, 1 = shown (animated)
    anim_to: f32 = 0,
    laid_out: bool = false,
    anim_channel: u8 = 0, // channel marker (stable address)
    ticker: anim.Timeline.Ticker = .{ .fn_ptr = struct {
        fn noop(_: ?*anyopaque, _: u64) void {}
    }.noop, .userdata = null },
    ticker_registered: bool = false, // the ticker is on the timeline
    timeout_armed: bool = false, // a deadline is being counted (ticker)
    timeout_deadline: ?u64 = null,
    /// The dismiss icon button — its a11y label re-resolves on a locale
    /// switch (null when `opts.dismiss` is false).
    dismiss_btn: ?*Node = null,
    i18n: ?*i18n_mod.I18n = null,
};

fn stateOf(n: *Node) *SnackBarState {
    return @ptrCast(@alignCast(n.state.?));
}

// --- measure / layout ---

fn snackMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    if (s.opts.action_on_new_line and s.opts.action_label != null) {
        // NewLineButtonSnackbar: the container fills the width (cap 600);
        // the height = text zone (baseline 30 + 12 bottom) + the
        // action/dismiss row + the column's bottom 2dp.
        const w = @min(c.max_w, max_width);
        var row_h: f32 = 0;
        var i: usize = 2; // [bg, text, action?, dismiss?] — action at 2
        while (i < n.children.items.len) : (i += 1) {
            const cs = n.children.items[i].measure(.{ .max_w = w, .max_h = c.max_h });
            row_h = @max(row_h, cs.h);
        }
        const text = n.children.items[1];
        const ts = text.measure(.{ .max_w = w - start_padding - button_side_spacing, .max_h = c.max_h });
        const text_zone = @max(0, first_line_h - 0.8 * ts.h) + ts.h + long_btn_v_off;
        const h = @max(two_lines_min_h, text_zone + row_h + separate_btn_extra_y);
        return c.constrain(.{ .w = w, .h = h });
    }
    var content_w: f32 = 0;
    var content_h: f32 = 0;
    for (n.children.items) |child| {
        if (child == s.bg) continue;
        const cs = child.measure(.{ .max_w = c.max_w, .max_h = c.max_h });
        content_w += cs.w;
        content_h = @max(content_h, cs.h);
    }
    // one gap, before the action (the dismiss icon button has its own padding)
    const gaps: f32 = if (s.opts.action_label != null) action_gap else 0;
    const end_pad: f32 = if (s.opts.dismiss) 0 else end_padding;
    const w = start_padding + content_w + gaps + end_pad;
    const h = @max(min_height, vertical_padding * 2 + content_h);
    return c.constrain(.{ .w = @min(w, max_width), .h = h });
}

fn snackLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    // Self-positioning: the content rect sits at the bottom-center of the
    // given bounds (which may be the whole window — a fill child of a Stack)
    // with the bottom margin.
    const ms = snackMeasure(n, .{ .max_w = bounds.w, .max_h = bounds.h });
    const cw = @min(ms.w, bounds.w);
    const ch = @min(ms.h, bounds.h);
    s.content = .{
        .x = bounds.x + (bounds.w - cw) / 2,
        .y = bounds.y + bounds.h - s.opts.bottom_margin - ch,
        .w = cw,
        .h = ch,
    };
    const b = s.content;
    // background fills the content rect
    s.bg.layout(b);
    const rtl = ui.i18n.direction() == .rtl;
    if (s.opts.action_on_new_line and s.opts.action_label != null and n.children.items.len > 2) {
        // NewLineButtonSnackbar: Column { text(+baseline pads); Row(End)
        // {action, dismiss} } — the row sits at the container's end.
        const text = n.children.items[1];
        const ts = text.measure(.{ .max_w = b.w - start_padding - button_side_spacing, .max_h = b.h });
        const tx = if (rtl) b.x + b.w - start_padding - ts.w else b.x + start_padding;
        text.layout(.{ .x = tx, .y = b.y + @max(0, first_line_h - 0.8 * ts.h), .w = ts.w, .h = ts.h });
        // the action row (children 2..end = [action, dismiss]) End-aligned,
        // bottom = b.bottom - separate_btn_extra_y - action_bottom_pad
        var row_w: f32 = 0;
        var row_h: f32 = 0;
        for (2..n.children.items.len) |i| {
            const cs = n.children.items[i].measure(.{ .max_w = b.w, .max_h = b.h });
            row_w += cs.w;
            row_h = @max(row_h, cs.h);
        }
        const row_y = b.y + b.h - separate_btn_extra_y - row_h;
        var cx = if (rtl) b.x + @as(f32, if (s.opts.dismiss) 0 else button_side_spacing) else b.x + b.w - row_w - @as(f32, if (s.opts.dismiss) 0 else button_side_spacing);
        for (2..n.children.items.len) |i| {
            const child = n.children.items[i];
            const cs = child.measure(.{ .max_w = b.w, .max_h = b.h });
            // upstream Row default verticalAlignment = Top
            child.layout(.{ .x = cx, .y = row_y, .w = cs.w, .h = cs.h });
            cx += cs.w;
        }
    } else {
        // OneRowSnackbar: text start-aligned, action + dismiss end-aligned,
        // vertically centered. Children: [bg, text, (action), (dismiss)].
        const mid_y = b.y + b.h / 2;
        const end_pad: f32 = if (s.opts.dismiss) 0 else end_padding;
        // walk the trailing children from the end edge: dismiss, then
        // action (mirrored in RTL — the end edge is the LEFT)
        var i = n.children.items.len;
        var cursor: f32 = if (rtl) b.x + end_pad else b.x + b.w - end_pad;
        while (i > 1) {
            i -= 1;
            const child = n.children.items[i];
            const cs = child.measure(.{ .max_w = b.w, .max_h = b.h });
            if (rtl) {
                child.layout(.{ .x = cursor, .y = mid_y - cs.h / 2, .w = cs.w, .h = cs.h });
                cursor += cs.w;
            } else {
                cursor -= cs.w;
                child.layout(.{ .x = cursor, .y = mid_y - cs.h / 2, .w = cs.w, .h = cs.h });
            }
        }
        // the text (index 1) at the start
        const text = n.children.items[1];
        const cs = text.measure(.{ .max_w = b.w, .max_h = b.h });
        const tx = if (rtl) b.x + b.w - start_padding - cs.w else b.x + start_padding;
        text.layout(.{ .x = tx, .y = mid_y - cs.h / 2, .w = cs.w, .h = cs.h });
    }
    const target: f32 = if (s.sig.peek()) 1 else 0;
    if (!s.laid_out) {
        s.anim_to = target;
        applyProgress(n, s, target);
        s.laid_out = true;
    } else if (target != s.anim_to) {
        animateProgress(n, s, target);
    }
}

fn snackPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx; // transparent chrome: the background child paints (transformed)
}

/// The slide + fade transform wraps the children (bg + content): own save +
/// the layer's save (saveLayerAlphaf pushes one) — both are restored in
/// post_children_paint so a caller's canvas state survives. The slide offset
/// is the CONTENT height (the node's bounds may be the whole window).
fn snackPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    ui.paint.save(ctx);
    const s = stateOf(n);
    ui.paint.translate(ctx, 0, s.content.h * (1 - s.progress));
    ui.paint.layerAlpha(ctx, s.progress);
}

fn snackPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.restore(ctx); // pops the layer
    ui.paint.restore(ctx); // pops the own save
}

fn snackMapPaintRect(n: *Node, r: Rect) Rect {
    const s = stateOf(n);
    const dy = s.content.h * (1 - s.progress);
    return .{ .x = r.x, .y = r.y + dy, .w = r.w, .h = r.h };
}

fn snackPreChildrenHit(n: *Node, px: f32, py: f32) node_mod.HitPoint {
    const s = stateOf(n);
    const dy = s.content.h * (1 - s.progress);
    return .{ .x = px, .y = py - dy };
}

/// Hit-testing covers the CONTENT rect only (translated by the slide) — an
/// overlay snackbar never shadows the content below it.
fn snackHitBounds(n: *Node) Rect {
    const s = stateOf(n);
    const b = s.content;
    const dy = b.h * (1 - s.progress);
    return .{ .x = b.x, .y = b.y + dy, .w = b.w, .h = b.h };
}

fn snackDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| {
        tl.cancelChannel(@ptrCast(&s.anim_channel));
        if (s.ticker_registered) tl.removeTicker(s.ticker);
    }
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = snackSyncCb, .userdata = n } });
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = snackLocaleCb, .userdata = n });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

/// The dismiss button's label (upstream dismissActionContentDescription)
/// is tr()-resolved — the locale callback re-resolves it in place (the
/// alert label is the app's text, verbatim).
fn snackLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.dismiss_btn) |b| {
        if (b.semantics) |sem| sem.label = i18n_mod.tr("Dismiss");
    }
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

const snack_vtable = ui.node.VTable{
    .measure = snackMeasure,
    .layout = snackLayout,
    .paint = snackPaint,
    .pre_children_paint = snackPreChildrenPaint,
    .post_children_paint = snackPostChildrenPaint,
    .map_paint_rect = snackMapPaintRect,
    .hit_bounds = snackHitBounds,
    .pre_children_hit = snackPreChildrenHit,
    .deinit = snackDeinit,
};

// --- background child ---

fn bgPaint(n: *Node, ctx: *kx.Ctx) void {
    const b = n.bounds;
    const t = stateOf(n.parent.?).opts.theme;
    // Snackbar elevation = 6dp — it must read over whatever it covers.
    ui.paint.elevationShadow(ctx, b.x, b.y, b.w, b.h, corner, 6, t.colors.shadow);
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, corner, t.colors.inverse_surface);
}

const bg_vtable = ui.node.VTable{
    .measure = struct {
        fn m(n: *Node, c: Constraints) Size {
            _ = n;
            return c.constrain(.{});
        }
    }.m,
    .layout = struct {
        fn l(n: *Node, b: Rect) void {
            _ = n;
            _ = b;
        }
    }.l,
    .paint = bgPaint,
};

// --- animation + timeout ---

fn animateProgress(n: *Node, s: *SnackBarState, to: f32) void {
    s.anim_to = to;
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.tweenAnim(.{ to, 0, 0, 0 }, s.opts.theme.motion.durations.short4, .{ .ease = .standard }),
            .from = .{ s.progress, 0, 0, 0 },
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = snackAnimUpdateCb, .userdata = n },
            .on_complete = .{ .fn_ptr = snackAnimCompleteCb, .userdata = n },
        });
    } else {
        applyProgress(n, s, to);
    }
}

fn applyProgress(n: *Node, s: *SnackBarState, progress: f32) void {
    s.progress = progress;
    n.setVisible(progress > 0.001);
    n.markDirty();
}

fn snackAnimUpdateCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    applyProgress(n, stateOf(n), value[0]);
}

fn snackAnimCompleteCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    applyProgress(n, s, s.anim_to);
}

/// Open state changed (app set the signal): animate (or snap before the
/// first layout — the first layout applies the current state directly).
fn snackSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.sig.peek()) {
        s.timeout_armed = s.opts.timeout_ms > 0; // the ticker counts the deadline
        registerTicker(n, s); // lazy: the timeline may appear after construction
    } else {
        s.timeout_armed = false;
        s.timeout_deadline = null;
        if (s.on_dismiss) |cb| cb.fn_ptr(cb.userdata);
    }
    if (!s.laid_out) return;
    const target: f32 = if (s.sig.peek()) 1 else 0;
    if (target != s.anim_to) animateProgress(n, s, target);
}

/// Register the auto-dismiss ticker on the current timeline (once). Lazy: a
/// snackbar built before the host installs its timeline still auto-dismisses
/// (the first show registers it).
fn registerTicker(n: *Node, s: *SnackBarState) void {
    if (s.ticker_registered) return;
    if (s.opts.timeout_ms <= 0) return;
    const tl = anim.timeline() orelse return;
    s.ticker = .{ .fn_ptr = snackTickerCb, .userdata = n, .has_pending = snackTickerPendingCb };
    tl.addTicker(s.ticker);
    s.ticker_registered = true;
}

/// The auto-dismiss ticker: arms the deadline on the first tick after show,
/// hides the snackbar when it passes. has_pending keeps the host awake (the
/// timeout fires even at true idle).
fn snackTickerCb(userdata: ?*anyopaque, now_ms: u64) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (!s.timeout_armed) return;
    if (s.timeout_deadline == null) {
        s.timeout_deadline = now_ms + s.opts.timeout_ms;
        return;
    }
    if (now_ms >= s.timeout_deadline.?) {
        s.sig.set(false); // snackSyncCb fires on_dismiss + hides
    }
}

fn snackTickerPendingCb(userdata: ?*anyopaque) bool {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    return s.timeout_armed;
}

fn hideSnack(n: *Node) void {
    const s = stateOf(n);
    s.sig.set(false); // snackSyncCb fires on_dismiss + animates out
}

// --- factories ---

const text_w = @import("text.zig");
const input_w = @import("input.zig");
const icon_w = @import("icon.zig");

/// A snackbar. `visible` is app-owned; the snackbar subscribes (slide/fade +
/// auto-dismiss) and unsubscribes at deinit. `on_action` fires when the action
/// is pressed (the press also dismisses); `on_dismiss` fires on any dismissal
/// (timeout, dismiss icon, action).
pub fn snackBar(allocator: std.mem.Allocator, visible: *ui.state.Signal(bool), on_action: ?Callback, on_dismiss: ?Callback, opts: SnackBarOptions) !*Node {
    const node = try Node.create(allocator, &snack_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(SnackBarState);
    errdefer allocator.destroy(s);
    const t = opts.theme;
    // Internal background (the container surface, inside the transform).
    const bg = try Node.create(allocator, &bg_vtable);
    errdefer allocator.destroy(bg);
    // Text content (body_medium, inverse_on_surface).
    const label = try text_w.text(allocator, opts.text, .{
        .size = t.type_scale.body_medium.size,
        .color = t.colors.inverse_on_surface,
    });
    node.add(bg);
    node.add(label);
    // Optional action: a text button (inverse_primary label_large, state layer).
    if (opts.action_label) |action_label| {
        const on_press: Callback = .{
            .fn_ptr = struct {
                fn cb(ud: ?*anyopaque) void {
                    const n: *Node = @ptrCast(@alignCast(ud.?));
                    const st = stateOf(n);
                    if (st.on_action) |a| a.fn_ptr(a.userdata);
                    hideSnack(n); // M3: the action press dismisses the snackbar
                }
            }.cb,
            .userdata = node,
        };
        const btn = try input_w.button(allocator, on_press, .{
            .bg = 0x00000000,
            .bg_hover = theme_mod.stateLayer(t.colors.inverse_surface, t.colors.inverse_primary, t.state.hover),
            .bg_pressed = theme_mod.stateLayer(t.colors.inverse_surface, t.colors.inverse_primary, t.state.pressed),
            .padding = ui.layout.EdgeInsets.symmetric(8, 4),
        });
        btn.add(try text_w.text(allocator, action_label, .{
            .size = t.type_scale.label_large.size,
            .color = t.colors.inverse_primary,
        }));
        node.add(btn);
    }
    // Optional dismiss icon button (24dp close icon, inverse_on_surface).
    var dismiss_btn: ?*Node = null;
    if (opts.dismiss) {
        const on_press: Callback = .{ .fn_ptr = struct {
            fn cb(ud: ?*anyopaque) void {
                hideSnack(@ptrCast(@alignCast(ud.?)));
            }
        }.cb, .userdata = node };
        const btn = try input_w.button(allocator, on_press, .{
            .bg = 0x00000000,
            .bg_hover = theme_mod.stateLayer(t.colors.inverse_surface, t.colors.inverse_on_surface, t.state.hover),
            .bg_pressed = theme_mod.stateLayer(t.colors.inverse_surface, t.colors.inverse_on_surface, t.state.pressed),
            .padding = ui.layout.EdgeInsets.all(12),
        });
        btn.add(try icon_w.icon(allocator, .close, .{ .size = 24, .color = t.colors.inverse_on_surface }));
        if (btn.semantics) |sem| sem.label = i18n_mod.tr("Dismiss"); // upstream dismissActionContentDescription
        node.add(btn);
        dismiss_btn = btn;
    }
    s.* = .{
        .sig = visible,
        .opts = opts,
        .on_action = on_action,
        .on_dismiss = on_dismiss,
        .bg = bg,
        .dismiss_btn = dismiss_btn,
        // arm the auto-dismiss at construction too: subscribing does not
        // replay the signal's initial value (a visible=true document would
        // otherwise never time out)
        .timeout_armed = opts.timeout_ms > 0 and visible.peek(),
    };
    node.state = s;
    // Auto-dismiss ticker (registered once, lazily — no-ops while disarmed).
    registerTicker(node, s);
    ui.semantics.attach(node, .{ .role = .alert, .label = opts.text }); // Phase 2c
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = snackLocaleCb, .userdata = node });
    visible.subscribe(.{ .callback = .{ .fn_ptr = snackSyncCb, .userdata = node } });
    return node;
}

// --- tests ---

const layout_w = @import("layout.zig");

test "snackbar: content-sized, min height 48, capped at 600 wide" {
    const visible = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer visible.deinit();
    const sb = try snackBar(std.testing.allocator, visible, null, null, .{ .text = "Saved" });
    defer sb.deinit();
    const m = sb.measure(.{ .max_w = 900, .max_h = 400 });
    try std.testing.expect(m.h >= min_height);
    try std.testing.expect(m.w <= max_width);
    try std.testing.expect(m.w > start_padding);
}

test "snackbar: action_on_new_line — full width, text top, action row bottom-end" {
    const visible = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer visible.deinit();
    const sb = try snackBar(std.testing.allocator, visible, null, null, .{
        .text = "A long message that wraps the action",
        .action_label = "Undo",
        .dismiss = true,
        .action_on_new_line = true,
        .timeout_ms = 0,
    });
    defer sb.deinit();
    sb.layout(.{ .x = 0, .y = 0, .w = 500, .h = 300 });
    const s = stateOf(sb);
    // the container fills the width (upstream fillMaxWidth, cap 600)
    try std.testing.expectEqual(@as(f32, 500), s.content.w);
    // children: [bg, text, action, dismiss]
    const tb = sb.children.items[1].bounds;
    const ab = sb.children.items[2].bounds;
    const db = sb.children.items[3].bounds;
    // text in the top zone (baseline ~30dp), action row at the bottom end
    try std.testing.expect(tb.y < ab.y);
    try std.testing.expectApproxEqAbs(ab.y, db.y, 1.0);
    try std.testing.expectApproxEqAbs(db.x + db.w, s.content.x + s.content.w, 1.0);
    try std.testing.expect(ab.x + ab.w <= db.x + 1.0);
    // the container bottom = row bottom + SeparateButtonExtraY (2)
    const row_bottom = @max(ab.y + ab.h, db.y + db.h);
    try std.testing.expectApproxEqAbs(s.content.y + s.content.h, row_bottom + separate_btn_extra_y, 1.0);
    // without the flag the same options stay one-row
    const sb2 = try snackBar(std.testing.allocator, visible, null, null, .{
        .text = "A long message that wraps the action",
        .action_label = "Undo",
        .dismiss = true,
        .timeout_ms = 0,
    });
    defer sb2.deinit();
    sb2.layout(.{ .x = 0, .y = 0, .w = 500, .h = 300 });
    const t2 = sb2.children.items[1].bounds;
    const a2 = sb2.children.items[2].bounds;
    try std.testing.expectApproxEqAbs(t2.y + t2.h / 2, a2.y + a2.h / 2, 1.0);
}

test "snackbar: hidden by default; show snaps (no timeline); dismiss icon closes it" {
    const visible = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer visible.deinit();
    var dismissed: u32 = 0;
    const on_dismiss: Callback = .{ .fn_ptr = struct {
        fn cb(ud: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ud.?));
            c.* += 1;
        }
    }.cb, .userdata = &dismissed };
    const sb = try snackBar(std.testing.allocator, visible, null, on_dismiss, .{
        .text = "Saved",
    });
    defer sb.deinit();
    sb.layout(.{ .x = 0, .y = 100, .w = 200, .h = 48 });
    try std.testing.expect(!sb.visible);
    // show: snaps (no timeline)
    visible.set(true);
    sb.layout(.{ .x = 0, .y = 100, .w = 200, .h = 48 });
    try std.testing.expect(sb.visible);
    try std.testing.expectEqual(@as(f32, 1), stateOf(sb).progress);
    // the dismiss icon button (last child) closes it
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const dismiss_btn = sb.children.items[sb.children.items.len - 1];
    const bb = dismiss_btn.bounds;
    router.dispatchPointer(sb, .{ .phase = .down, .x = bb.x + bb.w / 2, .y = bb.y + bb.h / 2 });
    router.dispatchPointer(sb, .{ .phase = .up, .x = bb.x + bb.w / 2, .y = bb.y + bb.h / 2 });
    try std.testing.expect(!visible.peek());
    try std.testing.expectEqual(@as(u32, 1), dismissed);
    sb.layout(.{ .x = 0, .y = 100, .w = 200, .h = 48 });
    try std.testing.expect(!sb.visible);
}

test "snackbar: the action press fires on_action and dismisses" {
    const visible = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer visible.deinit();
    var acted: u32 = 0;
    var dismissed: u32 = 0;
    const on_action: Callback = .{ .fn_ptr = struct {
        fn cb(ud: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ud.?));
            c.* += 1;
        }
    }.cb, .userdata = &acted };
    const on_dismiss: Callback = .{ .fn_ptr = struct {
        fn cb(ud: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ud.?));
            c.* += 1;
        }
    }.cb, .userdata = &dismissed };
    const sb = try snackBar(std.testing.allocator, visible, on_action, on_dismiss, .{
        .text = "Deleted",
        .action_label = "Undo",
        .timeout_ms = 0, // no auto-dismiss in this test
    });
    defer sb.deinit();
    sb.layout(.{ .x = 0, .y = 100, .w = 260, .h = 48 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // the action button is the 3rd child (bg, text, action, dismiss)
    const action_btn = sb.children.items[2];
    const bb = action_btn.bounds;
    router.dispatchPointer(sb, .{ .phase = .down, .x = bb.x + bb.w / 2, .y = bb.y + bb.h / 2 });
    router.dispatchPointer(sb, .{ .phase = .up, .x = bb.x + bb.w / 2, .y = bb.y + bb.h / 2 });
    try std.testing.expectEqual(@as(u32, 1), acted);
    try std.testing.expect(!visible.peek());
    try std.testing.expectEqual(@as(u32, 1), dismissed);
}

test "snackbar: the action keeps its 8dp gap after the text (reserved by the measure)" {
    const visible = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer visible.deinit();
    // no dismiss: the action is the last child (flush right, end padding)
    const sb = try snackBar(std.testing.allocator, visible, null, null, .{
        .text = "Saved",
        .action_label = "Undo",
        .dismiss = false,
        .timeout_ms = 0,
    });
    defer sb.deinit();
    sb.layout(.{ .x = 0, .y = 0, .w = 400, .h = 48 });
    // children: [bg, text, action]
    const tb = sb.children.items[1].bounds;
    const ab = sb.children.items[2].bounds;
    try std.testing.expectApproxEqAbs(tb.x + tb.w + action_gap, ab.x, 1.0);
    // with a dismiss icon: same gap before the action, the icon flush right
    const sb2 = try snackBar(std.testing.allocator, visible, null, null, .{
        .text = "Saved",
        .action_label = "Undo",
        .dismiss = true,
        .timeout_ms = 0,
    });
    defer sb2.deinit();
    sb2.layout(.{ .x = 0, .y = 0, .w = 400, .h = 48 });
    // children: [bg, text, action, dismiss]
    const t2 = sb2.children.items[1].bounds;
    const a2 = sb2.children.items[2].bounds;
    const d2 = sb2.children.items[3].bounds;
    try std.testing.expectApproxEqAbs(t2.x + t2.w + action_gap, a2.x, 1.0);
    const c2 = stateOf(sb2).content;
    try std.testing.expectApproxEqAbs(c2.x + c2.w, d2.x + d2.w, 1.0);
}

test "snackbar: auto-dismisses after timeout_ms (timeline ticker)" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const visible = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer visible.deinit();
    var dismissed: u32 = 0;
    const on_dismiss: Callback = .{ .fn_ptr = struct {
        fn cb(ud: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ud.?));
            c.* += 1;
        }
    }.cb, .userdata = &dismissed };
    const sb = try snackBar(std.testing.allocator, visible, null, on_dismiss, .{
        .text = "Saved",
        .timeout_ms = 1000,
    });
    defer sb.deinit();
    sb.layout(.{ .x = 0, .y = 0, .w = 200, .h = 48 });
    visible.set(true); // syncCb arms the timeout + launches the show tween
    try std.testing.expect(stateOf(sb).timeout_armed);
    tl.tick(0); // tween start; the ticker arms the deadline (0 + 1000)
    tl.tick(250); // the slide tween (200ms) settled: shown
    try std.testing.expect(sb.visible);
    tl.tick(1001); // deadline passed: the snackbar hides itself
    try std.testing.expect(!visible.peek());
    tl.tick(1300); // the hide tween settled
    try std.testing.expect(!sb.visible);
    try std.testing.expectEqual(@as(u32, 1), dismissed);
}

test "snackbar: initially visible also auto-dismisses (the factory arms the timeout)" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const visible = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer visible.deinit();
    const sb = try snackBar(std.testing.allocator, visible, null, null, .{
        .text = "Saved",
        .timeout_ms = 500,
    });
    defer sb.deinit();
    sb.layout(.{ .x = 0, .y = 0, .w = 200, .h = 48 });
    // armed at construction (subscribing never replays the initial value)
    try std.testing.expect(stateOf(sb).timeout_armed);
    tl.tick(0); // deadline = 500
    try std.testing.expect(visible.peek());
    tl.tick(600); // deadline passed: hidden (the hide tween starts)
    try std.testing.expect(!visible.peek());
    tl.tick(900); // the hide tween settled
    try std.testing.expect(!sb.visible);
}

test "snackbar: the ticker registers lazily when the timeline appears after construction" {
    const visible = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer visible.deinit();
    // built WITHOUT a timeline: no ticker yet
    const sb = try snackBar(std.testing.allocator, visible, null, null, .{
        .text = "Saved",
        .timeout_ms = 500,
    });
    defer sb.deinit();
    try std.testing.expect(!stateOf(sb).ticker_registered);
    sb.layout(.{ .x = 0, .y = 0, .w = 200, .h = 48 });
    // the host installs its timeline later; the first show registers it
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    visible.set(true);
    try std.testing.expect(stateOf(sb).ticker_registered);
    tl.tick(0); // deadline = 500
    tl.tick(600); // deadline passed: hidden
    try std.testing.expect(!visible.peek());
}

test "golden: snackbar paints the inverse_surface container with the text" {
    const t = theme_mod.light;
    const visible = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer visible.deinit();
    const sb = try snackBar(std.testing.allocator, visible, null, null, .{ .text = "Saved", .theme = t });
    defer sb.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 240, 80);
    defer r.deinit();
    // the snackbar self-positions: given a 200x48 area at (20,20), the content
    // rect sits at the bottom-center with a 12dp margin
    sb.layout(.{ .x = 20, .y = 20, .w = 200, .h = 48 });
    const c = stateOf(sb).content;
    r.paint(sb, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the container is inverse_surface — minus the text/dismiss ink, the
    // corner + edge AA (the RRect edges fall between pixels: ~300px)
    const cr: ui.node.Rect = .{ .x = c.x, .y = c.y, .w = c.w, .h = c.h };
    try std.testing.expect(@as(f32, @floatFromInt(f.countColorIn(cr, t.colors.inverse_surface))) > c.w * c.h - 600);
    try std.testing.expectEqual(t.colors.inverse_surface, f.pixelAt(@intFromFloat(c.x + 4), @intFromFloat(c.y + c.h - 4))); // interior, off the ink
    // hidden: nothing painted
    visible.set(false);
    sb.layout(.{ .x = 20, .y = 20, .w = 200, .h = 48 });
    r.paint(sb, 0x000000FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(@as(Color, 0x000000FF), f2.pixelAt(@intFromFloat(c.x + 4), @intFromFloat(c.y + c.h - 4)));
}

test "golden: snackbar with an action paints the inverse_primary action label" {
    const t = theme_mod.light;
    const visible = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer visible.deinit();
    const sb = try snackBar(std.testing.allocator, visible, null, null, .{ .text = "Saved", .action_label = "Undo", .theme = t });
    defer sb.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 300, 80);
    defer r.deinit();
    sb.layout(.{ .x = 20, .y = 20, .w = 260, .h = 48 });
    const c = stateOf(sb).content;
    r.paint(sb, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the container rect: the action's label ink (inverse_primary) is present
    // inside it (the body text is inverse_on_surface — a different color)
    const cr: ui.node.Rect = .{ .x = c.x, .y = c.y, .w = c.w, .h = c.h };
    try std.testing.expect(f.countColorIn(cr, t.colors.inverse_primary) > 0);
    // the container itself still fills most of its rect (the inverse_surface
    // background, minus the text/action ink and the AA edge)
    try std.testing.expect(@as(f32, @floatFromInt(f.countColorIn(cr, t.colors.inverse_surface))) > c.w * c.h / 2);
}

test "snackbar: i18n — the dismiss button's label localizes + re-resolves" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Dismiss\": \"Descartar\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const visible = try ui.state.Signal(bool).init(a, true);
    defer visible.deinit();
    const sb = try snackBar(a, visible, null, null, .{ .text = "Saved" });
    defer sb.deinit();
    const btn = stateOf(sb).dismiss_btn.?;
    try std.testing.expectEqualStrings("Descartar", btn.semantics.?.label);
    try i18n.setLocale("en");
    try std.testing.expectEqualStrings("Dismiss", btn.semantics.?.label);
}
