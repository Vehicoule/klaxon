// Dialog (Phase 2d.1 PR B, M3E batch 1) — basic alert dialog +
// full-screen dialog variant (Phase 2d.3 follow-up, M3E).
//
// Spec: m3.material.io/components/dialogs + Compose DialogTokens /
// AlertDialog.kt (basic) / FullScreenDialog.kt (full-screen):
//   - container: surface_container_high, CornerExtraLarge (28dp), elevation
//     level3 (the raster shadow pass lands in Phase 3 — v1 draws the flat
//     container)
//   - width: min 280, max 560; container padding 24dp all
//   - icon (optional): 24dp, secondary, 16dp bottom padding
//   - headline (optional): headline_small, on_surface, 16dp bottom padding
//   - supporting text: body_medium, on_surface_variant
//   - actions: text buttons (primary, label_large), end-aligned, 8dp spacing,
//     24dp above (16 gap + 8)
//   - scrim: the scrim token at 32% opacity; a click outside closes the
//     dialog (and Escape / hardware back via the modal back stack)
//   - motion: v1 fades the panel (layer alpha); M3E scales+fades with the
//     spatial spring — the scale lands with the Phase 3 shadow pass
//
// Full-screen variant (.variant = .full_screen, M3E + Compose
// FullScreenDialog.kt): the panel covers the WHOLE bounds — a full-bleed
// Surface (CornerNone, no scrim: the surface itself covers the content
// behind) with a 64dp top bar (AppBarTokens.ContainerHeight) holding an
// internal close icon button (24dp .close icon, standard variant) at the
// start, the title slot expanded over the middle (so the action lands at
// the end — TopAppBarTitleInset), and the `action` slot (a text button the
// caller builds, e.g. button(..., .{ .variant = .text, .label = "Save" }))
// at the end. The content slot fills the remainder. Escape/back dismisses
// like the basic dialog (the shared signal/back-stack machinery); a scrim
// click can't happen — there is no scrim.
//
// Structure: the dialog node holds an internal scrim and an internal panel.
// For .basic the panel holds an internal background child (the rounded
// container) and an internal content column with the option slots: icon,
// title, content, actions. For .full_screen the panel holds the background
// (flat full-bleed surface), the top bar row (close button + expanded title
// + action), and the content slot. The open state is a Signal(bool) owned
// by the app; the dialog subscribes (fade) and unsubscribes at deinit.
// While open it registers on the router's modal back stack.
//
// Sizing: the dialog fills FINITE constraints — a modal is screen-sized, so
// it measures to 100% of a bounded parent (window/overlay). Inside an
// unbounded parent (a scroll column), wrap it in a bounded box.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const anim = ui.anim;
const node_mod = ui.node;
const theme_mod = @import("../theme.zig");
const icon_button_w = @import("icon_button.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

/// M3E measurement tokens (Compose DialogTokens / AlertDialog.kt).
const min_width: f32 = 280;
const max_width: f32 = 560;
const container_padding: f32 = 24;
const corner: f32 = 28;
const icon_size: f32 = 24;
const gap: f32 = 16;
const actions_top_extra: f32 = 8; // 16 gap + 8 = 24dp above the actions
const scrim_max_alpha: f32 = 0.32;
const fade_ms: u32 = 200;

/// Full-screen dialog tokens (Compose FullScreenDialog.kt — the top bar is
/// a single-row TopAppBar: AppBarTokens.ContainerHeight 64, 4dp edge
/// padding, the title 4dp in from the nav icon).
const fs_top_bar_h: f32 = 64;
const fs_top_bar_pad: f32 = 4; // TopAppBarHorizontalPadding
const fs_top_bar_gap: f32 = 4; // the title/action gap (TopAppBarTitleInset)

pub const DialogVariant = enum { basic, full_screen };

pub const DialogOptions = struct {
    /// basic: the centered 280–560dp alert panel over a scrim;
    /// full_screen: the full-bleed surface + top bar (see the file header).
    variant: DialogVariant = .basic,
    icon: ?*Node = null, // 24x24 slot (secondary) — basic only
    title: ?*Node = null, // headline slot (basic: headline_small, on_surface;
    // full-screen: title_large, on_surface)
    content: ?*Node = null, // supporting text slot (body_medium, on_surface_variant)
    actions: ?*Node = null, // basic only: a row of text buttons (end-aligned, 8dp gap)
    /// full_screen only: the confirm action in the top bar's end slot (a
    /// text-button node the caller builds — it owns its own callback).
    action: ?*Node = null,
    theme: Theme = theme_mod.light,
    label: []const u8 = "Dialog",
};

const DialogState = struct {
    sig: *ui.state.Signal(bool),
    opts: DialogOptions,
    on_closed: ?Callback = null,
    scrim: *Node, // internal scrim node
    panel: *Node, // internal panel node
    alpha: f32 = 0, // 0 = closed, 1 = open (animated)
    anim_to: f32 = 0,
    laid_out: bool = false,
    anim_channel: u8 = 0, // channel marker (stable address)
    back_registered: bool = false, // on the router's modal back stack while open
};

const Callback = ui.state.Callback;

fn stateOf(n: *Node) *DialogState {
    return @ptrCast(@alignCast(n.state.?));
}

// --- scrim ---

const ScrimState = struct {
    dialog: *Node,
    alpha: f32 = 0, // final opacity, 0..scrim_max_alpha (animated)
};

fn scrimStateOf(n: *Node) *ScrimState {
    return @ptrCast(@alignCast(n.state.?));
}

fn withAlpha(c: Color, a: f32) Color {
    const r: u32 = (c >> 24) & 0xFF;
    const g: u32 = (c >> 16) & 0xFF;
    const b: u32 = (c >> 8) & 0xFF;
    const alpha: u32 = @intFromFloat(std.math.clamp(a, 0, 1) * 255);
    return (r << 24) | (g << 16) | (b << 8) | alpha;
}

fn scrimPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = scrimStateOf(n);
    const b = n.bounds;
    if (s.alpha <= 0) return;
    const t = stateOf(s.dialog).opts.theme;
    // s.alpha is the final opacity (0..scrim_max_alpha, applied once — at
    // storage; multiplying again here would square the scrim alpha)
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, withAlpha(t.colors.scrim, s.alpha));
}

fn scrimOnPointer(n: *Node, ev: input.PointerEvent) bool {
    if (ev.phase != .up) return ev.phase == .down; // consume the press, act on release
    const s = scrimStateOf(n);
    if (stateOf(s.dialog).sig.peek()) {
        closeDialog(s.dialog); // M3 barrier: a click outside dismisses
        return true;
    }
    return false;
}

fn scrimDeinit(n: *Node) void {
    n.allocator.destroy(scrimStateOf(n));
}

const scrim_vtable = ui.node.VTable{
    .measure = struct {
        fn m(n: *Node, c: Constraints) Size {
            _ = n;
            return c.constrain(.{}); // zero-size; the dialog lays the scrim out
        }
    }.m,
    .layout = struct {
        fn l(n: *Node, b: Rect) void {
            _ = n;
            _ = b;
        }
    }.l,
    .paint = scrimPaint,
    .on_pointer = scrimOnPointer,
    .deinit = scrimDeinit,
};

// --- panel (fades via a layer alpha around its children) ---

const PanelState = struct {
    dialog: *Node,
};

fn panelStateOf(n: *Node) *PanelState {
    return @ptrCast(@alignCast(n.state.?));
}

fn panelMeasure(n: *Node, c: Constraints) Size {
    // the panel is the content column's size (the background child is zero)
    var size = Size{};
    for (n.children.items) |child| {
        const cs = child.measure(c);
        size = .{ .w = @max(size.w, cs.w), .h = @max(size.h, cs.h) };
    }
    return c.constrain(size);
}

fn panelBgPaint(n: *Node, ctx: *kx.Ctx) void {
    // the bg child has no state: reach the dialog through the panel (parent)
    const s = stateOf(panelStateOf(n.parent.?).dialog);
    const b = n.bounds;
    if (s.opts.variant == .full_screen) {
        // Full-bleed Surface — CornerNone, no elevation: the panel IS the
        // page (no scrim to float over).
        ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, s.opts.theme.colors.surface);
        return;
    }
    // M3 dialog elevation = 6dp — the panel floats over the scrim.
    ui.paint.elevationShadow(ctx, b.x, b.y, b.w, b.h, corner, 6,
        s.opts.theme.colors.shadow);
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, corner, s.opts.theme.colors.surface_container_high);
}

fn panelBgDeinit(n: *Node) void {
    _ = n; // no state on the bg child (the panel state is freed by panelDeinit)
}

const panel_bg_vtable = ui.node.VTable{
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
    .paint = panelBgPaint,
    .deinit = panelBgDeinit,
};

fn panelPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    // own save + the layer's save (saveLayerAlphaf pushes one): both are
    // restored in post_children_paint so a caller's canvas state survives
    ui.paint.save(ctx);
    ui.paint.layerAlpha(ctx, stateOf(panelStateOf(n).dialog).alpha);
}

fn panelPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.restore(ctx); // pops the layer
    ui.paint.restore(ctx); // pops the own save
}

fn panelDeinit(n: *Node) void {
    n.allocator.destroy(panelStateOf(n));
}

const panel_vtable = ui.node.VTable{
    .measure = panelMeasure,
    .layout = struct {
        fn l(n: *Node, b: Rect) void {
            _ = n;
            _ = b;
        }
    }.l,
    .paint = struct {
        fn p(n: *Node, ctx: *kx.Ctx) void {
            _ = n;
            _ = ctx; // transparent: the background child paints (faded)
        }
    }.p,
    .pre_children_paint = panelPreChildrenPaint,
    .post_children_paint = panelPostChildrenPaint,
    .deinit = panelDeinit,
};

// --- dialog ---

fn dialogMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    const size = Size{};
    const w = if (std.math.isFinite(c.max_w)) c.max_w else size.w;
    const h = if (std.math.isFinite(c.max_h)) c.max_h else size.h;
    return c.constrain(.{ .w = w, .h = h });
}

fn dialogLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    s.scrim.layout(bounds);
    const panel = s.panel;
    if (s.opts.variant == .full_screen) {
        // The panel covers the whole bounds (the surface IS the page).
        // Children: the background fills it, the top bar takes the top 64dp,
        // the content slot fills the remainder (the factory's order).
        panel.layout(bounds);
        const p = panel.bounds;
        for (panel.children.items, 0..) |child, ci| {
            child.layout(switch (ci) {
                0 => p,
                1 => .{ .x = p.x, .y = p.y, .w = p.w, .h = fs_top_bar_h },
                else => .{ .x = p.x, .y = p.y + fs_top_bar_h, .w = p.w, .h = @max(0, p.h - fs_top_bar_h) },
            });
        }
    } else {
        // Panel: content-sized, clamped to [280, 560] wide, centered. A host
        // narrower than 280 makes the lower bound unreachable — let the panel
        // take the full width instead of asserting inside clamp.
        const cs = panel.measure(.{ .max_w = bounds.w, .max_h = bounds.h });
        const max_w = @min(max_width, bounds.w);
        const pw = std.math.clamp(cs.w, @min(min_width, max_w), max_w);
        const ph = @min(cs.h, bounds.h);
        panel.layout(.{
            .x = bounds.x + (bounds.w - pw) / 2,
            .y = bounds.y + (bounds.h - ph) / 2,
            .w = pw,
            .h = ph,
        });
        // Panel children: the background and the content column both fill the panel.
        for (panel.children.items) |child| {
            child.layout(.{ .x = panel.bounds.x, .y = panel.bounds.y, .w = pw, .h = ph });
        }
    }
    const target: f32 = if (s.sig.peek()) 1 else 0;
    if (!s.laid_out) {
        s.anim_to = target;
        applyAlpha(n, s, target, scrimTarget(s, target));
        s.laid_out = true;
    } else if (target != s.anim_to) {
        animateAlpha(n, s, target);
    }
}

fn dialogPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx; // transparent chrome
}

fn dialogOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind == .key_down and ev.key == .escape and s.sig.peek()) {
        closeDialog(n); // M3: Escape dismisses the dialog
        return true;
    }
    return false;
}

fn dialogDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel));
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = dialogSyncCb, .userdata = n } });
    if (s.back_registered) {
        if (input.current()) |r| r.popBackHandler(n); // destroyed while open
        s.back_registered = false;
    }
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const dialog_vtable = ui.node.VTable{
    .measure = dialogMeasure,
    .layout = dialogLayout,
    .paint = dialogPaint,
    .deinit = dialogDeinit,
    .on_key = dialogOnKey,
};

/// The scrim's target opacity for a given panel alpha — 0 for the
/// full-screen variant (no scrim: the surface covers the window).
fn scrimTarget(s: *DialogState, panel_alpha: f32) f32 {
    return if (s.opts.variant == .full_screen) 0 else panel_alpha * scrim_max_alpha;
}

/// Fade the panel + scrim to `to` (0/1); without a timeline, snap.
fn animateAlpha(n: *Node, s: *DialogState, to: f32) void {
    s.anim_to = to;
    const from: anim.Vec4 = .{ s.alpha, scrimStateOf(s.scrim).alpha, 0, 0 };
    const target: anim.Vec4 = .{ to, scrimTarget(s, to), 0, 0 };
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.tweenAnim(target, fade_ms, .{ .ease = .standard }),
            .from = from,
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = dialogAnimUpdateCb, .userdata = n },
            .on_complete = .{ .fn_ptr = dialogAnimCompleteCb, .userdata = n },
        });
    } else {
        applyAlpha(n, s, to, scrimTarget(s, to));
    }
}

fn applyAlpha(n: *Node, s: *DialogState, alpha: f32, scrim_alpha: f32) void {
    s.alpha = alpha;
    scrimStateOf(s.scrim).alpha = scrim_alpha;
    s.scrim.setVisible(scrim_alpha > 0.001);
    s.panel.setVisible(alpha > 0.001);
    s.panel.markDirty();
    s.scrim.markDirty();
    _ = n;
}

fn dialogAnimUpdateCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    applyAlpha(n, stateOf(n), value[0], value[1]);
}

fn dialogAnimCompleteCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    applyAlpha(n, s, s.anim_to, scrimTarget(s, s.anim_to));
}

/// Open state changed (app set the signal): animate (or snap before the
/// first layout — the first layout applies the current state directly).
fn dialogSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    syncBackHandler(n, s); // before the laid_out gate: registration tracks state
    if (!s.laid_out) return;
    const target: f32 = if (s.sig.peek()) 1 else 0;
    if (target != s.anim_to) animateAlpha(n, s, target);
}

fn closeDialog(n: *Node) void {
    const s = stateOf(n);
    s.sig.set(false);
    if (s.on_closed) |cb| cb.fn_ptr(cb.userdata);
}

/// The full-screen top bar's close icon button (M3: the navigation icon
/// dismisses). userdata = the dialog node.
fn closeTopBarCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    closeDialog(n);
}

/// Escape / hardware-back while the dialog is open (the router consults the
/// modal back stack before the navigator — dispatchBack).
fn dialogBackCb(userdata: ?*anyopaque) bool {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (!s.sig.peek()) return false;
    closeDialog(n); // the signal sync pops the handler
    return true;
}

/// Keep the router's modal back stack in sync with the open state.
fn syncBackHandler(n: *Node, s: *DialogState) void {
    const want = s.sig.peek();
    if (want == s.back_registered) return;
    const router = input.current() orelse return;
    if (want) {
        if (router.pushBackHandler(.{ .fn_ptr = dialogBackCb, .userdata = n })) s.back_registered = true;
    } else {
        router.popBackHandler(n);
        s.back_registered = false;
    }
}

/// Alert dialog (M3E). `.basic` slots: `icon` (24dp), `title` (headline),
/// `content` (supporting text), `actions` (a row of text buttons).
/// `.full_screen` slots: `title` (title_large top-bar text), `action` (a
/// text-button node at the top bar's end, e.g. "Save"), `content` (fills
/// the remainder); the close X is internal chrome. `open` is app-owned;
/// the dialog subscribes (fade) and unsubscribes at deinit. `on_closed`
/// fires when the dialog is dismissed (scrim click / top-bar X / Escape /
/// back button).
pub fn dialog(allocator: std.mem.Allocator, open: *ui.state.Signal(bool), on_closed: ?Callback, opts: DialogOptions) !*Node {
    const node = try Node.create(allocator, &dialog_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(DialogState);
    errdefer allocator.destroy(s);
    // Internal scrim (the full-screen variant keeps it but pins its alpha
    // to 0 — the surface itself covers the window, no dimming).
    const scrim = try Node.create(allocator, &scrim_vtable);
    errdefer allocator.destroy(scrim);
    const ss = try allocator.create(ScrimState);
    errdefer allocator.destroy(ss);
    ss.* = .{ .dialog = node, .alpha = 0 };
    scrim.state = ss;
    // Internal panel + its background child (the variant's structure
    // differs — see the file header).
    const panel = try Node.create(allocator, &panel_vtable);
    errdefer allocator.destroy(panel);
    const ps = try allocator.create(PanelState);
    errdefer allocator.destroy(ps);
    ps.* = .{ .dialog = node };
    panel.state = ps;
    const panel_bg = try Node.create(allocator, &panel_bg_vtable);
    errdefer allocator.destroy(panel_bg);
    panel.add(panel_bg);
    const layout_w = @import("layout.zig");
    if (opts.variant == .full_screen) {
        // The top bar (AppBarTokens single-row): the close icon button at
        // the start, the title slot expanded over the middle (the action
        // lands at the end), the action slot at the end.
        const top_bar = try layout_w.row(allocator, .{
            .gap = fs_top_bar_gap,
            .padding = fs_top_bar_pad,
            .cross_align = .center,
        });
        errdefer top_bar.deinit(); // owns whatever was added before a failure
        const close_btn = try icon_button_w.iconButton(allocator, null, .{ .fn_ptr = closeTopBarCb, .userdata = node }, .{
            .icon = .close,
            .variant = .standard,
            .a11y_label = "Close dialog",
            .theme = opts.theme,
        });
        top_bar.add(close_btn);
        const title_slot = try layout_w.expanded(allocator, 1);
        top_bar.add(title_slot);
        if (opts.title) |title| title_slot.add(title);
        if (opts.action) |action| top_bar.add(action);
        panel.add(top_bar);
        if (opts.content) |content| panel.add(content);
    } else {
        // Content column: padding 24, gap 16, centered with an icon /
        // start-aligned without. Actions get 8dp extra top padding (24dp
        // total above them).
        const col = try layout_w.column(allocator, .{
            .gap = gap,
            .padding = container_padding,
            .cross_align = if (opts.icon != null) .center else .start,
        });
        if (opts.icon) |ic| {
            const icon_box = try layout_w.constrainedBox(allocator, .{ .min_w = icon_size, .max_w = icon_size, .min_h = icon_size, .max_h = icon_size });
            icon_box.add(ic);
            col.add(icon_box);
        }
        if (opts.title) |title| col.add(title);
        if (opts.content) |content| col.add(content);
        if (opts.actions) |actions| {
            // actions are end-aligned (M3); 24dp above them (16 gap + 8 padding).
            // v1: center_right (LTR) — RTL cross-axis mirroring is a follow-up.
            const actions_end = try layout_w.alignTo(allocator, .{ .alignment = .center_right });
            const actions_pad = try layout_w.padding(allocator, ui.layout.EdgeInsets{ .top = actions_top_extra });
            actions_pad.add(actions);
            actions_end.add(actions_pad);
            col.add(actions_end);
        }
        panel.add(col);
    }
    s.* = .{ .sig = open, .opts = opts, .on_closed = on_closed, .panel = panel, .scrim = scrim };
    node.state = s;
    // Paint order: scrim (behind), panel (front).
    node.add(scrim);
    node.add(panel);
    ui.semantics.attach(scrim, .{ .role = .button, .label = "Close dialog", .actions = ui.semantics.Actions.initOne(.activate) }); // Phase 2c
    // full-screen is a plain dialog (assertive alert is the basic variant's)
    ui.semantics.attach(panel, .{ .role = if (opts.variant == .full_screen) .dialog else .alert, .label = opts.label }); // Phase 2c
    open.subscribe(.{ .callback = .{ .fn_ptr = dialogSyncCb, .userdata = node } });
    syncBackHandler(node, s); // already open at build: register immediately
    return node;
}

// --- tests ---

const text_w = @import("text.zig");

test "dialog: closed by default — the scrim and the panel are hidden" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const d = try dialog(std.testing.allocator, open, null, .{
        .title = try text_w.text(std.testing.allocator, "Delete?", .{}),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    const s = stateOf(d);
    try std.testing.expect(!s.scrim.visible);
    try std.testing.expect(!s.panel.visible);
    try std.testing.expectEqual(@as(f32, 0), s.alpha);
}

test "dialog: open — the panel is centered, clamped to [280, 560]" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const d = try dialog(std.testing.allocator, open, null, .{
        .title = try text_w.text(std.testing.allocator, "Title", .{}),
        .content = try text_w.text(std.testing.allocator, "Supporting text", .{}),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    const s = stateOf(d);
    const pb = s.panel.bounds;
    try std.testing.expect(pb.w >= min_width);
    try std.testing.expect(pb.w <= max_width);
    // centered
    try std.testing.expect(std.math.approxEqAbs(f32, 480 / 2, pb.x + pb.w / 2, 0.01));
    try std.testing.expect(std.math.approxEqAbs(f32, 320 / 2, pb.y + pb.h / 2, 0.01));
    try std.testing.expect(s.scrim.visible);
    try std.testing.expect(s.panel.visible);
    try std.testing.expectEqual(@as(f32, 1), s.alpha);
}

test "dialog: a scrim click closes it; the global back path too" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    var closed: u32 = 0;
    const d = try dialog(std.testing.allocator, open, .{ .fn_ptr = struct {
        fn cb(ud: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ud.?));
            c.* += 1;
        }
    }.cb, .userdata = &closed }, .{
        .title = try text_w.text(std.testing.allocator, "Title", .{}),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // the panel is centered (280 wide): a click at the corner hits the scrim
    router.dispatchPointer(d, .{ .phase = .down, .x = 20, .y = 20 });
    router.dispatchPointer(d, .{ .phase = .up, .x = 20, .y = 20 });
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 1), closed);
    // reopen; the back path closes it (focus is outside the dialog)
    open.set(true);
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    try std.testing.expectEqual(@as(usize, 1), router.back_stack_len);
    try std.testing.expect(router.dispatchBack());
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 2), closed);
    try std.testing.expectEqual(@as(usize, 0), router.back_stack_len);
}

test "golden: dialog paints the scrim and the centered panel (open)" {
    const t = theme_mod.light;
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const d = try dialog(std.testing.allocator, open, null, .{
        .theme = t,
        .title = try text_w.text(std.testing.allocator, "Delete?", .{ .size = t.type_scale.headline_small.size, .color = t.colors.on_surface }),
        .content = try text_w.text(std.testing.allocator, "This cannot be undone.", .{ .size = t.type_scale.body_medium.size, .color = t.colors.on_surface_variant }),
    });
    defer d.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 480, 320);
    defer r.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    r.paint(d, 0x112233FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const s = stateOf(d);
    const pb = s.panel.bounds;
    // the panel center is the surface_container_high color (text ink on top)
    try std.testing.expect(@as(f32, @floatFromInt(f.countColorIn(.{ .x = pb.x + 4, .y = pb.y + 4, .w = pb.w - 8, .h = pb.h - 8 }, t.colors.surface_container_high))) > (pb.w - 8) * (pb.h - 8) / 2);
    // the corner (outside the panel) is the scrim over the body: not the pure body color
    try std.testing.expect(f.pixelAt(2, 2) != 0x112233FF);
    // closed: no panel, no scrim — the body shows through
    open.set(false);
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    r.paint(d, 0x112233FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(@as(Color, 0x112233FF), f2.pixelAt(2, 2));
    try std.testing.expect(f2.countColorIn(.{ .x = pb.x, .y = pb.y, .w = pb.w, .h = pb.h }, t.colors.surface_container_high) == 0);
}

test "golden: dialog with actions paints the primary action labels in the panel" {
    const t = theme_mod.light;
    const layout_w = @import("layout.zig");
    const input_w = @import("input.zig");
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    // the M3E actions row: Cancel / Delete text buttons (primary label_large)
    const actions = try layout_w.row(std.testing.allocator, .{ .gap = 8 });
    const cancel = try input_w.button(std.testing.allocator, null, .{
        .bg = 0x00000000,
        .bg_hover = theme_mod.stateLayer(t.colors.surface_container_high, t.colors.primary, t.state.hover),
        .bg_pressed = theme_mod.stateLayer(t.colors.surface_container_high, t.colors.primary, t.state.pressed),
        .padding = ui.layout.EdgeInsets.symmetric(8, 4),
    });
    cancel.add(try text_w.text(std.testing.allocator, "Cancel", .{ .size = t.type_scale.label_large.size, .color = t.colors.primary }));
    actions.add(cancel);
    const del = try input_w.button(std.testing.allocator, null, .{
        .bg = 0x00000000,
        .bg_hover = theme_mod.stateLayer(t.colors.surface_container_high, t.colors.primary, t.state.hover),
        .bg_pressed = theme_mod.stateLayer(t.colors.surface_container_high, t.colors.primary, t.state.pressed),
        .padding = ui.layout.EdgeInsets.symmetric(8, 4),
    });
    del.add(try text_w.text(std.testing.allocator, "Delete", .{ .size = t.type_scale.label_large.size, .color = t.colors.primary }));
    actions.add(del);
    const d = try dialog(std.testing.allocator, open, null, .{
        .theme = t,
        .title = try text_w.text(std.testing.allocator, "Delete?", .{ .size = t.type_scale.headline_small.size, .color = t.colors.on_surface }),
        .actions = actions,
    });
    defer d.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 480, 320);
    defer r.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    r.paint(d, 0x112233FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the action labels' ink (primary) is present inside the panel (the title
    // is on_surface — a different color; the scrim lies outside the panel)
    const pb = stateOf(d).panel.bounds;
    const panel_rect: ui.node.Rect = .{ .x = pb.x, .y = pb.y, .w = pb.w, .h = pb.h };
    try std.testing.expect(f.countColorIn(panel_rect, t.colors.primary) > 0);
}

// --- full-screen variant ---

test "dialog: full-screen — the panel fills the bounds; no scrim, no corner" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const button_w = @import("button.zig");
    const d = try dialog(std.testing.allocator, open, null, .{
        .variant = .full_screen,
        .title = try text_w.text(std.testing.allocator, "Edit", .{}),
        .action = try button_w.button(std.testing.allocator, null, .{ .variant = .text, .label = "Save" }),
        .content = try golden.solidBox(std.testing.allocator, 480, 200, 0x0000FFFF),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    const s = stateOf(d);
    const pb = s.panel.bounds;
    // the panel IS the window — full bleed, no clamp, no scrim
    try std.testing.expectEqual(@as(f32, 0), pb.x);
    try std.testing.expectEqual(@as(f32, 0), pb.y);
    try std.testing.expectEqual(@as(f32, 480), pb.w);
    try std.testing.expectEqual(@as(f32, 320), pb.h);
    try std.testing.expect(!s.scrim.visible);
    try std.testing.expectEqual(@as(f32, 0), scrimStateOf(s.scrim).alpha);
    try std.testing.expect(s.panel.visible);
    // the top bar takes the top 64dp; the content fills the remainder
    const top_bar = s.panel.children.items[1];
    try std.testing.expectEqual(@as(f32, 0), top_bar.bounds.y);
    try std.testing.expectEqual(@as(f32, fs_top_bar_h), top_bar.bounds.h);
    try std.testing.expectEqual(@as(f32, 480), top_bar.bounds.w);
    const content = s.panel.children.items[2];
    try std.testing.expectEqual(@as(f32, fs_top_bar_h), content.bounds.y);
    try std.testing.expectEqual(@as(f32, 320 - fs_top_bar_h), content.bounds.h);
    // the panel semantics describe a plain dialog (not the basic's alert)
    try std.testing.expectEqual(ui.semantics.Role.dialog, s.panel.semantics.?.role);
}

test "dialog: full-screen — the top bar X and the back path both close" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    var closed: u32 = 0;
    const d = try dialog(std.testing.allocator, open, .{ .fn_ptr = struct {
        fn cb(ud: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ud.?));
            c.* += 1;
        }
    }.cb, .userdata = &closed }, .{
        .variant = .full_screen,
        .title = try text_w.text(std.testing.allocator, "Edit", .{}),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // open with the router live: the modal back handler registers
    open.set(true);
    try std.testing.expectEqual(@as(usize, 1), router.back_stack_len);
    // the internal close icon button — top bar's start, a 48dp hit target
    const top_bar = stateOf(d).panel.children.items[1];
    const close_btn = top_bar.children.items[0];
    const hb = close_btn.vtable.hit_bounds.?(close_btn);
    router.dispatchPointer(d, .{ .phase = .down, .x = hb.x + hb.w / 2, .y = hb.y + hb.h / 2 });
    router.dispatchPointer(d, .{ .phase = .up, .x = hb.x + hb.w / 2, .y = hb.y + hb.h / 2 });
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 1), closed);
    // reopen: the modal back stack (Escape / hardware back) closes it too
    open.set(true);
    try std.testing.expect(router.dispatchBack());
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 2), closed);
    try std.testing.expectEqual(@as(usize, 0), router.back_stack_len);
}

test "golden: dialog full-screen paints the surface everywhere + the top bar" {
    const t = theme_mod.light;
    const button_w = @import("button.zig");
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const d = try dialog(std.testing.allocator, open, null, .{
        .theme = t,
        .variant = .full_screen,
        .title = try text_w.text(std.testing.allocator, "Edit", .{ .size = t.type_scale.title_large.size, .color = t.colors.on_surface }),
        .action = try button_w.button(std.testing.allocator, null, .{ .variant = .text, .label = "Save", .theme = t }),
        .content = try text_w.text(std.testing.allocator, "Body content", .{ .size = t.type_scale.body_medium.size, .color = t.colors.on_surface_variant }),
    });
    defer d.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 480, 320);
    defer r.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    r.paint(d, 0x112233FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the surface covers the whole frame — NO scrim: the corners are the
    // pure surface color (the basic variant would dim them over the body)
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(2, 2));
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(478, 318));
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(240, 32)); // mid-bar
    // the close X ink (on_surface_variant) in the top bar's start
    try std.testing.expect(f.countColorIn(.{ .x = 4, .y = 8, .w = 44, .h = 48 }, t.colors.on_surface_variant) > 0);
    // the title's on_surface ink after the close button
    try std.testing.expect(f.countColorIn(.{ .x = 52, .y = 0, .w = 120, .h = fs_top_bar_h }, t.colors.on_surface) > 0);
    // the action's primary label ink in the top bar's end region
    try std.testing.expect(f.countColorIn(.{ .x = 380, .y = 0, .w = 100, .h = fs_top_bar_h }, t.colors.primary) > 0);
    // the content slot paints below the bar (the body text's ink lands there)
    try std.testing.expect(f.countNotIn(.{ .x = 0, .y = fs_top_bar_h + 8, .w = 200, .h = 40 }, t.colors.surface) > 0);
    // closed: nothing paints — the body shows through
    open.set(false);
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    r.paint(d, 0x112233FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(@as(Color, 0x112233FF), f2.pixelAt(2, 2));
    try std.testing.expectEqual(@as(Color, 0x112233FF), f2.pixelAt(240, 160));
}
