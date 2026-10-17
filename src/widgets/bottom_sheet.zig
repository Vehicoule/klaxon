// Bottom sheet (Phase 2d.1 PR B, M3E batch 1) — modal bottom sheet.
//
// Spec: m3.material.io/components/bottom-sheets + Compose SheetBottomTokens /
// SheetDefaults / ModalBottomSheet.kt:
//   - container: surface_container_low, CornerExtraLargeTop (28dp top corners),
//     elevation level1 (the raster shadow pass lands in Phase 3 — v1 draws
//     the flat container)
//   - width: full width up to 640dp; when the parent is wider, 56dp side
//     margins (max width = parent - 112), horizontally centered
//   - expanded top margin 72dp: the panel height is capped at parent - 72
//   - drag handle (optional): 32x4 pill (extraLarge shape), on_surface_variant,
//     22dp vertical padding, centered
//   - scrim: the scrim token at 32% opacity; a click on it closes the sheet
//   - motion: the panel slides up/down with the theme's SPATIAL spring; the
//     scrim alpha rides along. Without a timeline both snap.
//
// Structure: like the drawer — the sheet node holds the `body` slot (behind),
// an internal scrim, and an internal panel. The panel holds an internal
// background child (the rounded-top container surface, translated with the
// slide), the optional drag handle, and the `content` slot. The open state is
// a Signal(bool) owned by the app; the sheet subscribes (animation) and
// unsubscribes at deinit. While open it registers on the router's modal back
// stack (Escape / hardware back closes it even when focus is outside).
//
// Sizing: the sheet fills FINITE constraints — a modal is screen-height, so
// it measures to 100% of a bounded parent (window/overlay). Inside an
// unbounded parent (a scroll column), wrap it in a bounded box (e.g.
// constrainedBox with min_h = max_h). No drag-to-dismiss in v1: the state is
// signal-driven (a button or a gesture detector sets it).
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

/// M3E measurement tokens (Compose SheetBottomTokens / BottomSheetDefaults).
const max_width: f32 = 640;
const side_margin: f32 = 56;
const top_margin: f32 = 72;
const corner_top: f32 = 28;
const handle_w: f32 = 32;
const handle_h: f32 = 4;
const handle_v_padding: f32 = 22;
const scrim_max_alpha: f32 = 0.32;

pub const BottomSheetOptions = struct {
    body: ?*Node = null, // the page content (behind)
    content: ?*Node = null, // the sheet content (panel)
    drag_handle: bool = true,
    /// Upstream skipPartiallyExpanded: when false and the sheet is taller
    /// than half the parent, releasing a drag mid-way settles at the
    /// PartiallyExpanded anchor (the sheet occupies the bottom half).
    skip_partially: bool = false,
    theme: Theme = theme_mod.light,
    /// The semantics label — null resolves the localized "Bottom sheet"
    /// (an app string is verbatim).
    label: ?[]const u8 = null,
};

const SheetState = struct {
    sig: *ui.state.Signal(bool),
    opts: BottomSheetOptions,
    on_closed: ?Callback = null,
    scrim: *Node, // internal scrim node
    panel: *Node, // internal panel node
    progress: f32 = 0, // 0 = closed, 1 = open (animated)
    anim_to: f32 = 0,
    laid_out: bool = false,
    last_sig: bool = false, // sig value seen at the last layout (drags don't fight)
    panel_h: f32 = 0, // laid-out panel height (drives the slide offset)
    /// The PartiallyExpanded anchor as a progress fraction (0 = no partial
    /// state — the sheet fits inside the bottom half anyway).
    partial_p: f32 = 0,
    anim_channel: u8 = 0, // channel marker (stable address)
    back_registered: bool = false, // on the router's modal back stack while open
    i18n: ?*i18n_mod.I18n = null,
    saved_focus: ?*Node = null,
    focus_saved: bool = false,
};

const Callback = ui.state.Callback;

fn stateOf(n: *Node) *SheetState {
    return @ptrCast(@alignCast(n.state.?));
}

// --- scrim ---

const ScrimState = struct {
    sheet: *Node,
    alpha: f32 = 0, // final opacity, 0..scrim_max_alpha (animated)
};

fn scrimStateOf(n: *Node) *ScrimState {
    return @ptrCast(@alignCast(n.state.?));
}

fn scrimPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = scrimStateOf(n);
    const b = n.bounds;
    if (s.alpha <= 0) return;
    const t = stateOf(s.sheet).opts.theme;
    // s.alpha is the final opacity (0..scrim_max_alpha, applied once — at
    // storage; multiplying again here would square the scrim alpha)
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, withAlpha(t.colors.scrim, s.alpha));
}

fn withAlpha(c: Color, a: f32) Color {
    const r: u32 = (c >> 24) & 0xFF;
    const g: u32 = (c >> 16) & 0xFF;
    const b: u32 = (c >> 8) & 0xFF;
    const alpha: u32 = @intFromFloat(std.math.clamp(a, 0, 1) * 255);
    return (r << 24) | (g << 16) | (b << 8) | alpha;
}

fn scrimOnPointer(n: *Node, ev: input.PointerEvent) bool {
    if (ev.phase != .up) return ev.phase == .down; // consume the press, act on release
    const s = scrimStateOf(n);
    if (stateOf(s.sheet).sig.peek()) {
        closeSheet(s.sheet); // M3 barrier: a scrim click dismisses
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
            return c.constrain(.{}); // zero-size; the sheet lays the scrim out
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

// --- panel background (translated with the slide) ---

const PanelBgState = struct {
    sheet: *Node,
};

fn panelBgStateOf(n: *Node) *PanelBgState {
    return @ptrCast(@alignCast(n.state.?));
}

fn panelBgPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(panelBgStateOf(n).sheet);
    const b = n.bounds;
    // CornerExtraLargeTop: 28dp on the top corners only; modal sheet = 1dp.
    ui.paint.elevationShadow(ctx, b.x, b.y, b.w, b.h, corner_top, 1, s.opts.theme.colors.shadow);
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, corner_top, s.opts.theme.colors.surface_container_low);
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
    .deinit = struct {
        fn d(n: *Node) void {
            n.allocator.destroy(panelBgStateOf(n));
        }
    }.d,
};

// --- drag handle ---

fn handlePaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(panelStateOf(n.parent.?).sheet);
    const b = n.bounds;
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, b.h / 2, s.opts.theme.colors.on_surface_variant);
}

const handle_vtable = ui.node.VTable{
    .measure = struct {
        fn m(n: *Node, c: Constraints) Size {
            _ = n;
            return c.constrain(.{ .w = handle_w, .h = handle_h });
        }
    }.m,
    .layout = struct {
        fn l(n: *Node, b: Rect) void {
            _ = n;
            _ = b;
        }
    }.l,
    .paint = handlePaint,
};

// --- panel (slides vertically) ---

const PanelState = struct {
    sheet: *Node,
    offset_y: f32 = 0, // slide offset (positive = down = hidden)
    // --- drag-to-dismiss (upstream anchored draggable on the drag handle) ---
    drag_active: bool = false,
    drag_y0: f32 = 0, // raw y at grab
    drag_p0: f32 = 0, // progress at grab
    drag_vy: f32 = 0, // smoothed velocity, px/ms (positive = down)
    drag_last_y: f32 = 0,
    drag_last_t: u64 = 0,
};

fn panelStateOf(n: *Node) *PanelState {
    return @ptrCast(@alignCast(n.state.?));
}

fn panelPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    // own save: the restore in post_children_paint must not pop a caller's
    // canvas state (enclosing clips survive)
    ui.paint.save(ctx);
    ui.paint.translate(ctx, 0, panelStateOf(n).offset_y);
}

fn panelPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.restore(ctx);
}

fn panelMapPaintRect(n: *Node, r: Rect) Rect {
    const dy = panelStateOf(n).offset_y;
    return .{ .x = r.x, .y = r.y + dy, .w = r.w, .h = r.h };
}

fn panelPreChildrenHit(n: *Node, px: f32, py: f32) node_mod.HitPoint {
    const dy = panelStateOf(n).offset_y;
    return .{ .x = px, .y = py - dy };
}

fn panelHitBounds(n: *Node) Rect {
    const b = n.bounds;
    const dy = panelStateOf(n).offset_y;
    return .{ .x = b.x, .y = b.y + dy, .w = b.w, .h = b.h };
}

/// Upstream VelocityThreshold (125.dp/s → px/ms). A fling past it settles at
/// the next anchor in its direction; a slower release at the nearest one.
const fling_thresh: f32 = 0.125;

/// Drag-to-dismiss: the handle block at the panel's top is the grab zone
/// (the upstream affordance — content keeps its own interactions).
fn panelOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const ps = panelStateOf(n);
    const sheet = ps.sheet;
    const s = stateOf(sheet);
    const b = n.bounds;
    switch (ev.phase) {
        .down => {
            const grab_h = if (s.opts.drag_handle) handle_h + handle_v_padding * 2 else @as(f32, 32);
            const in_grab = ev.y >= b.y and ev.y <= b.y + grab_h; // hit-space = pre-translation bounds
            if (!s.sig.peek() or s.panel_h <= 0 or !in_grab) return false;
            ps.drag_active = true;
            ps.drag_y0 = ev.raw_y;
            ps.drag_p0 = s.progress;
            ps.drag_vy = 0;
            ps.drag_last_y = ev.raw_y;
            ps.drag_last_t = ev.time_ms;
            return true;
        },
        .move => {
            if (!ps.drag_active) return false;
            // smoothed velocity (px/ms)
            const dt = ev.time_ms - ps.drag_last_t;
            if (dt > 0) {
                const inst = (ev.raw_y - ps.drag_last_y) / @as(f32, @floatFromInt(dt));
                ps.drag_vy = ps.drag_vy * 0.6 + inst * 0.4;
            }
            ps.drag_last_y = ev.raw_y;
            ps.drag_last_t = ev.time_ms;
            const p = std.math.clamp(ps.drag_p0 - (ev.raw_y - ps.drag_y0) / s.panel_h, 0, 1);
            if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel)); // the finger drives
            applyProgress(sheet, s, p, p * scrim_max_alpha);
            return true;
        },
        .up, .leave => {
            if (!ps.drag_active) return ev.phase == .up;
            ps.drag_active = false;
            settleSheet(sheet, s, ps.drag_vy);
            return true;
        },
        else => {},
    }
    return false;
}

/// Release: settle at an anchor (Hidden / PartiallyExpanded / Expanded) —
/// a fling takes the next anchor in its direction, else the nearest one.
fn settleSheet(n: *Node, s: *SheetState, vy_ms: f32) void {
    const anchors = [3]f32{ 0, s.partial_p, 1 };
    const p = s.progress;
    var target: f32 = 1;
    if (vy_ms > fling_thresh) { // fling down → the anchor just below
        target = 0;
        for (anchors) |a| {
            if (a < p - 0.001 and a > target) target = a;
        }
    } else if (vy_ms < -fling_thresh) { // fling up → the anchor just above
        for (anchors) |a| {
            if (a > p + 0.001 and a < target) target = a;
        }
    } else { // the nearest anchor
        var best: f32 = 1e9;
        for (anchors) |a| {
            const d = @abs(p - a);
            if (d < best) {
                best = d;
                target = a;
            }
        }
    }
    if (target <= 0.001) {
        closeSheet(n); // Hidden → the signal + on_closed
    } else {
        s.anim_to = target;
        animateProgress(n, s, target); // PartiallyExpanded or Expanded — still open
    }
}

fn panelDeinit(n: *Node) void {
    n.allocator.destroy(panelStateOf(n));
}

const panel_vtable = ui.node.VTable{
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
    .paint = struct {
        fn p(n: *Node, ctx: *kx.Ctx) void {
            _ = n;
            _ = ctx; // transparent: the background child paints (translated)
        }
    }.p,
    .pre_children_paint = panelPreChildrenPaint,
    .post_children_paint = panelPostChildrenPaint,
    .map_paint_rect = panelMapPaintRect,
    .hit_bounds = panelHitBounds,
    .pre_children_hit = panelPreChildrenHit,
    .on_pointer = panelOnPointer,
    .deinit = panelDeinit,
};

// --- sheet ---

fn sheetMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    var size = Size{};
    if (s.opts.body) |body| size = body.measure(c);
    const w = if (std.math.isFinite(c.max_w)) c.max_w else size.w;
    const h = if (std.math.isFinite(c.max_h)) c.max_h else size.h;
    return c.constrain(.{ .w = w, .h = h });
}

fn sheetLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    if (s.opts.body) |body| body.layout(bounds);
    s.scrim.layout(bounds);
    // Panel: bottom-anchored, content-height (capped at parent - top margin),
    // width capped at 640 with 56dp side margins when the parent is wider.
    const pw = @min(max_width, @max(0, bounds.w - (if (bounds.w > max_width + side_margin * 2) side_margin * 2 else 0)));
    const px = bounds.x + (bounds.w - pw) / 2;
    const handle_block_h: f32 = if (s.opts.drag_handle) handle_h + handle_v_padding * 2 else 0;
    var ph = handle_block_h;
    if (s.opts.content) |content| {
        const cs = content.measure(.{ .max_w = pw, .max_h = @max(0, bounds.h - top_margin) });
        ph += cs.h;
    }
    ph = @min(ph, @max(0, bounds.h - top_margin));
    const py = bounds.y + bounds.h - ph;
    s.panel_h = ph;
    // The PartiallyExpanded anchor: the sheet occupies the bottom half —
    // only exists when it doesn't already fit inside it (upstream).
    s.partial_p = if (!s.opts.skip_partially and ph > bounds.h / 2) (bounds.h / 2) / ph else 0;
    s.panel.layout(.{ .x = px, .y = py, .w = pw, .h = ph });
    // Panel children in factory order: background (fills the panel), the
    // optional drag handle (centered in its block), the content slot (fills
    // what the handle block leaves). Laid out by role, not by index.
    const panel = s.panel;
    var next: usize = 0;
    if (panel.children.items.len > 0) {
        panel.children.items[0].layout(.{ .x = px, .y = py, .w = pw, .h = ph }); // background
        next = 1;
    }
    if (s.opts.drag_handle and panel.children.items.len > next) {
        panel.children.items[next].layout(.{ .x = px + (pw - handle_w) / 2, .y = py + handle_v_padding, .w = handle_w, .h = handle_h });
        next += 1;
    }
    if (s.opts.content != null and panel.children.items.len > next) {
        panel.children.items[next].layout(.{ .x = px, .y = py + handle_block_h, .w = pw, .h = @max(0, ph - handle_block_h) });
    }
    const sig_now = s.sig.peek();
    if (!s.laid_out) {
        const target: f32 = if (sig_now) 1 else 0;
        s.anim_to = target;
        applyProgress(n, s, target, target * scrim_max_alpha);
        s.laid_out = true;
    } else if (sig_now != s.last_sig) {
        // The sig changed between layouts (a programmatic set — the drag
        // settle only touches progress/partial_p and must not fight it).
        animateProgress(n, s, if (sig_now) 1 else 0);
    }
    s.last_sig = sig_now;
}

fn sheetPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx; // transparent chrome: the body slot paints behind
}

fn sheetOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind == .key_down and ev.key == .escape and s.sig.peek()) {
        closeSheet(n); // M3: Escape dismisses the modal sheet
        return true;
    }
    return false;
}

fn sheetDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel));
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = sheetSyncCb, .userdata = n } });
    if (s.back_registered) {
        if (input.current()) |r| r.popBackHandler(n); // destroyed while open
        s.back_registered = false;
    }
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = sheetLocaleCb, .userdata = n });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

/// The scrim + panel a11y labels — tr()-resolved, so the locale callback
/// re-attaches in the new locale.
fn attachSheetSemantics(n: *Node) void {
    const s = stateOf(n);
    ui.semantics.attach(s.scrim, .{ .role = .button, .label = i18n_mod.tr("Close sheet"), .actions = ui.semantics.Actions.initOne(.activate) });
    ui.semantics.attach(s.panel, .{
        .role = .group,
        .label = s.opts.label orelse i18n_mod.tr("Bottom sheet"),
        .modal = true,
    });
}

fn sheetLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    attachSheetSemantics(n);
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

const sheet_vtable = ui.node.VTable{
    .measure = sheetMeasure,
    .layout = sheetLayout,
    .paint = sheetPaint,
    .deinit = sheetDeinit,
    .on_key = sheetOnKey,
};

/// Slide the panel + fade the scrim to `to` (0/1) with the spatial spring;
/// without a timeline, snap.
fn animateProgress(n: *Node, s: *SheetState, to: f32) void {
    s.anim_to = to;
    const from: anim.Vec4 = .{ s.progress, scrimStateOf(s.scrim).alpha, 0, 0 };
    const target: anim.Vec4 = .{ to, to * scrim_max_alpha, 0, 0 };
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.springAnim(from, target, s.opts.theme.motion.springs.spatial_spring, .{ 0, 0, 0, 0 }),
            .from = from,
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = sheetAnimUpdateCb, .userdata = n },
            .on_complete = .{ .fn_ptr = sheetAnimCompleteCb, .userdata = n },
        });
    } else {
        applyProgress(n, s, to, to * scrim_max_alpha);
    }
}

fn applyProgress(n: *Node, s: *SheetState, progress: f32, scrim_alpha: f32) void {
    s.progress = progress;
    scrimStateOf(s.scrim).alpha = scrim_alpha;
    s.scrim.setVisible(scrim_alpha > 0.001);
    // The panel slides DOWN out of view when closed (bottom-anchored). The
    // slide is paint-time translation — a fully closed panel still sat in
    // its bounds and painted/hit-tested below them (a ghost over whatever
    // follows the sheet in the layout). Hide the subtree outright: a closed
    // sheet paints nothing.
    panelStateOf(s.panel).offset_y = s.panel_h * (1 - progress);
    const open = progress > 0.001;
    s.panel.setVisible(open);
    ui.semantics.syncModalFocus(s.panel, open, &s.saved_focus, &s.focus_saved);
    markInternalsDirty(n, s);
}

/// Repaint the panel (covering the swept region) and the scrim.
fn markInternalsDirty(n: *Node, s: *SheetState) void {
    _ = n;
    const b = s.panel.bounds;
    const dy = panelStateOf(s.panel).offset_y;
    const visual = Rect{ .x = b.x, .y = b.y + dy, .w = b.w, .h = b.h };
    s.panel.markDirtyRect(node_mod.rectUnion(b, visual));
    s.scrim.markDirty();
}

fn sheetAnimUpdateCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    applyProgress(n, s, value[0], value[1]);
}

fn sheetAnimCompleteCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    applyProgress(n, s, s.anim_to, s.anim_to * scrim_max_alpha);
}

/// Open state changed (app set the signal): animate (or snap before the
/// first layout — the first layout applies the current state directly).
fn sheetSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    syncBackHandler(n, s); // before the laid_out gate: registration tracks state
    if (!s.laid_out) return;
    const target: f32 = if (s.sig.peek()) 1 else 0;
    if (target != s.anim_to) animateProgress(n, s, target);
}

fn closeSheet(n: *Node) void {
    const s = stateOf(n);
    s.sig.set(false);
    if (s.on_closed) |cb| cb.fn_ptr(cb.userdata);
}

/// Escape / hardware-back while the sheet is open (the router consults the
/// modal back stack before the navigator — dispatchBack).
fn sheetBackCb(userdata: ?*anyopaque) bool {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (!s.sig.peek()) return false;
    closeSheet(n); // the signal sync pops the handler
    return true;
}

/// Keep the router's modal back stack in sync with the open state.
fn syncBackHandler(n: *Node, s: *SheetState) void {
    const want = s.sig.peek();
    if (want == s.back_registered) return;
    const router = input.current() orelse return;
    if (want) {
        if (router.pushBackHandler(.{ .fn_ptr = sheetBackCb, .userdata = n })) s.back_registered = true;
    } else {
        router.popBackHandler(n);
        s.back_registered = false;
    }
}

/// Modal bottom sheet (M3E). Slots: `content` (the panel), `body` (the page
/// behind). `open` is app-owned; the sheet subscribes (slide + scrim
/// animation) and unsubscribes at deinit. `on_closed` fires when the sheet is
/// dismissed (scrim click / Escape / back button).
pub fn bottomSheet(allocator: std.mem.Allocator, open: *ui.state.Signal(bool), on_closed: ?Callback, opts: BottomSheetOptions) !*Node {
    const node = try Node.create(allocator, &sheet_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(SheetState);
    errdefer allocator.destroy(s);
    // Internal scrim.
    const scrim = try Node.create(allocator, &scrim_vtable);
    errdefer allocator.destroy(scrim);
    const ss = try allocator.create(ScrimState);
    errdefer allocator.destroy(ss);
    ss.* = .{ .sheet = node, .alpha = 0 };
    scrim.state = ss;
    // Internal panel + its background child (the translated container surface)
    // + the optional drag handle.
    const panel = try Node.create(allocator, &panel_vtable);
    errdefer allocator.destroy(panel);
    const ps = try allocator.create(PanelState);
    errdefer allocator.destroy(ps);
    ps.* = .{ .sheet = node, .offset_y = 0 };
    panel.state = ps;
    const panel_bg = try Node.create(allocator, &panel_bg_vtable);
    errdefer allocator.destroy(panel_bg);
    const bgs = try allocator.create(PanelBgState);
    errdefer allocator.destroy(bgs);
    bgs.* = .{ .sheet = node };
    panel_bg.state = bgs;
    panel.add(panel_bg);
    if (opts.drag_handle) {
        const handle = try Node.create(allocator, &handle_vtable);
        errdefer allocator.destroy(handle);
        panel.add(handle);
    }
    s.* = .{ .sig = open, .opts = opts, .on_closed = on_closed, .panel = panel, .scrim = scrim };
    node.state = s;
    // Paint order: body (behind), scrim, panel (front); the panel holds the
    // background child first, then the handle, then the content slot.
    if (opts.body) |body| node.add(body);
    node.add(scrim);
    node.add(panel);
    if (opts.content) |content| panel.add(content);
    attachSheetSemantics(node); // Phase 2c
    open.subscribe(.{ .callback = .{ .fn_ptr = sheetSyncCb, .userdata = node } });
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = sheetLocaleCb, .userdata = node });
    syncBackHandler(node, s); // already open at build: register immediately
    return node;
}

// --- tests ---

const text_w = @import("text.zig");
const layout_w = @import("layout.zig");

test "bottom_sheet: closed by default — the scrim is hidden, the panel off-screen" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const d = try bottomSheet(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
        .content = try text_w.text(std.testing.allocator, "Sheet", .{}),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s = stateOf(d);
    try std.testing.expect(!s.scrim.visible);
    try std.testing.expectEqual(@as(f32, 0), s.progress);
    // closed: the panel is translated fully below its laid-out position AND
    // hidden — translation alone would still paint/hit-test past the edge
    try std.testing.expectEqual(s.panel_h, panelStateOf(s.panel).offset_y);
    try std.testing.expect(!s.panel.visible);
}

test "bottom_sheet: measure/layout fill the parent; the panel is bottom-anchored, capped at 640" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const d = try bottomSheet(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
        .content = try text_w.text(std.testing.allocator, "Sheet", .{}),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s = stateOf(d);
    const pb = s.panel.bounds;
    // bottom-anchored: the panel's bottom edge is the parent's bottom edge
    try std.testing.expectEqual(@as(f32, 200), pb.y + pb.h);
    // open: no slide offset
    try std.testing.expectEqual(@as(f32, 0), panelStateOf(s.panel).offset_y);
    try std.testing.expect(s.scrim.visible);
    // wide parent: the panel is capped at 640, centered with 56dp margins
    d.layout(.{ .x = 0, .y = 0, .w = 900, .h = 400 });
    const pb2 = s.panel.bounds;
    try std.testing.expectEqual(@as(f32, 640), pb2.w);
    try std.testing.expectEqual(@as(f32, 130), pb2.x); // (900 - 640) / 2
    // narrow parent: full width
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    try std.testing.expectEqual(@as(f32, 320), s.panel.bounds.w);
}

test "bottom_sheet: without a timeline the panel snaps open/closed on the signal" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const d = try bottomSheet(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s = stateOf(d);
    open.set(true);
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    try std.testing.expectEqual(@as(f32, 1), s.progress);
    try std.testing.expectEqual(@as(f32, 0), panelStateOf(s.panel).offset_y);
    try std.testing.expect(s.panel.visible);
    open.set(false);
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    try std.testing.expectEqual(@as(f32, 0), s.progress);
    try std.testing.expectEqual(s.panel_h, panelStateOf(s.panel).offset_y);
    try std.testing.expect(!s.panel.visible);
}

test "bottom_sheet: dragging the handle zone moves the sheet; a slow release settles at the nearest anchor" {
    var closed: u32 = 0;
    const cb = Callback{ .fn_ptr = struct {
        fn f(u: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(u.?));
            c.* += 1;
        }
    }.f, .userdata = &closed };
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const d = try bottomSheet(std.testing.allocator, open, cb, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 400, 0x112233FF),
        .content = try text_w.text(std.testing.allocator, "Sheet", .{}),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 400 });
    const s = stateOf(d);
    const ps = panelStateOf(s.panel);
    const on_pointer = s.panel.vtable.on_pointer.?;
    const pb = s.panel.bounds;
    // grab inside the handle zone (the panel's top block)
    _ = on_pointer(s.panel, .{ .phase = .down, .x = pb.x + 10, .y = pb.y + 10, .raw_x = pb.x + 10, .raw_y = pb.y + 10, .time_ms = 0 });
    try std.testing.expect(ps.drag_active);
    // drag down 60% of the panel height → progress ~0.4
    _ = on_pointer(s.panel, .{ .phase = .move, .x = pb.x + 10, .y = pb.y + 10, .raw_x = pb.x + 10, .raw_y = pb.y + 10 + s.panel_h * 0.6, .time_ms = 100 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), s.progress, 0.01);
    // slow release: the sheet is short (no partial anchor) → settles at Hidden
    _ = on_pointer(s.panel, .{ .phase = .up, .x = pb.x + 10, .y = pb.y + 10, .raw_x = pb.x + 10, .raw_y = pb.y + 10 + s.panel_h * 0.6, .time_ms = 200 });
    try std.testing.expect(!ps.drag_active);
    try std.testing.expect(!open.peek()); // dismissed through the signal
    try std.testing.expectEqual(@as(u32, 1), closed);
    // a short drag settles back at Expanded
    open.set(true);
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 400 });
    _ = on_pointer(s.panel, .{ .phase = .down, .x = pb.x + 10, .y = pb.y + 10, .raw_x = pb.x + 10, .raw_y = pb.y + 10, .time_ms = 300 });
    _ = on_pointer(s.panel, .{ .phase = .move, .x = pb.x + 10, .y = pb.y + 10, .raw_x = pb.x + 10, .raw_y = pb.y + 10 + s.panel_h * 0.1, .time_ms = 400 });
    _ = on_pointer(s.panel, .{ .phase = .up, .x = pb.x + 10, .y = pb.y + 10, .raw_x = pb.x + 10, .raw_y = pb.y + 10 + s.panel_h * 0.1, .time_ms = 500 });
    try std.testing.expect(open.peek());
    try std.testing.expectEqual(@as(f32, 1), s.progress);
}

test "bottom_sheet: a tall sheet settles at the PartiallyExpanded anchor (bottom half)" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    // content taller than half the parent → the partial anchor exists
    const d = try bottomSheet(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 400, 0x112233FF),
        .content = try golden.solidBox(std.testing.allocator, 300, 260, 0x334455FF),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 400 });
    const s = stateOf(d);
    // panel_h = 260 + the handle block (52) = 312 > 200 → partial = 200/312
    try std.testing.expectApproxEqAbs(@as(f32, 200.0 / 312.0), s.partial_p, 0.01);
    const on_pointer = s.panel.vtable.on_pointer.?;
    const pb = s.panel.bounds;
    // drag down to ~55% progress and release slowly → PartiallyExpanded
    _ = on_pointer(s.panel, .{ .phase = .down, .x = pb.x + 10, .y = pb.y + 10, .raw_x = pb.x + 10, .raw_y = pb.y + 10, .time_ms = 0 });
    _ = on_pointer(s.panel, .{ .phase = .move, .x = pb.x + 10, .y = pb.y + 10, .raw_x = pb.x + 10, .raw_y = pb.y + 10 + s.panel_h * 0.45, .time_ms = 100 });
    // small slow moves decay the smoothed velocity below the fling threshold
    var t_ms: u64 = 200;
    var yy = pb.y + 10 + s.panel_h * 0.45;
    for (0..6) |_| {
        yy += 1;
        t_ms += 100;
        _ = on_pointer(s.panel, .{ .phase = .move, .x = pb.x + 10, .y = pb.y + 10, .raw_x = pb.x + 10, .raw_y = yy, .time_ms = t_ms });
    }
    _ = on_pointer(s.panel, .{ .phase = .up, .x = pb.x + 10, .y = pb.y + 10, .raw_x = pb.x + 10, .raw_y = yy, .time_ms = t_ms + 100 });
    try std.testing.expect(open.peek()); // still open
    try std.testing.expectApproxEqAbs(s.partial_p, s.progress, 0.01);
}

test "bottom_sheet: the content fills what the handle block leaves (no overlap, no phantom offset)" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const handle_block: f32 = handle_h + handle_v_padding * 2;
    // with a handle: [bg, handle, content]
    const d = try bottomSheet(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
        .content = try golden.solidBox(std.testing.allocator, 100, 40, 0xFF),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s = stateOf(d);
    const panel = s.panel;
    try std.testing.expectEqual(@as(usize, 3), panel.children.items.len);
    const hb = panel.children.items[1].bounds;
    const cb = panel.children.items[2].bounds;
    // the handle is centered in its block (22dp top padding)
    try std.testing.expectEqual(panel.bounds.y + handle_v_padding, hb.y);
    try std.testing.expectEqual(handle_h, hb.h);
    // the content starts below the FULL handle block and fills the rest
    try std.testing.expectEqual(panel.bounds.y + handle_block, cb.y);
    try std.testing.expectEqual(@max(0, panel.bounds.h - handle_block), cb.h);
    try std.testing.expect(cb.y >= hb.y + hb.h); // no overlap
    // without a handle: [bg, content] — the content fills the panel from its top
    const d2 = try bottomSheet(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
        .content = try golden.solidBox(std.testing.allocator, 100, 40, 0xFF),
        .drag_handle = false,
    });
    defer d2.deinit();
    d2.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s2 = stateOf(d2);
    try std.testing.expectEqual(@as(usize, 2), s2.panel.children.items.len);
    const c2 = s2.panel.children.items[1].bounds;
    try std.testing.expectEqual(s2.panel.bounds.y, c2.y);
    try std.testing.expectEqual(s2.panel.bounds.h, c2.h);
    // a handle without content is still laid out: [bg, handle]
    const d3 = try bottomSheet(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
    });
    defer d3.deinit();
    d3.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s3 = stateOf(d3);
    try std.testing.expectEqual(@as(usize, 2), s3.panel.children.items.len);
    const h3 = s3.panel.children.items[1].bounds;
    try std.testing.expectEqual(handle_w, h3.w);
    try std.testing.expectEqual(handle_h, h3.h);
}

test "bottom_sheet: a scrim click closes it; the global back path too" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    var closed: u32 = 0;
    const d = try bottomSheet(std.testing.allocator, open, .{ .fn_ptr = struct {
        fn cb(ud: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ud.?));
            c.* += 1;
        }
    }.cb, .userdata = &closed }, .{
        .body = try golden.solidBox(std.testing.allocator, 480, 200, 0xFF),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // a click anywhere on the scrim (the sheet is 480 wide; the panel is
    // content-height at the bottom — the top area is scrim) closes it
    router.dispatchPointer(d, .{ .phase = .down, .x = 240, .y = 20 });
    router.dispatchPointer(d, .{ .phase = .up, .x = 240, .y = 20 });
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 1), closed);
    // reopen; the back path closes it (focus is outside the sheet)
    open.set(true);
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    try std.testing.expectEqual(@as(usize, 1), router.back_stack_len);
    try std.testing.expect(router.dispatchBack());
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 2), closed);
    try std.testing.expectEqual(@as(usize, 0), router.back_stack_len);
}

test "golden: bottom sheet paints the body, the scrim and the panel (open)" {
    const t = theme_mod.light;
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const body = try golden.solidBox(std.testing.allocator, 480, 200, 0x112233FF);
    const content = try layout_w.padding(std.testing.allocator, .{ .left = 16, .top = 16, .right = 16, .bottom = 16 });
    content.add(try text_w.text(std.testing.allocator, "Sheet content", .{ .color = t.colors.on_surface }));
    const d = try bottomSheet(std.testing.allocator, open, null, .{ .theme = t, .body = body, .content = content });
    defer d.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 480, 200);
    defer r.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    r.paint(d, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const s = stateOf(d);
    const pb = s.panel.bounds;
    // the panel (surface_container_low, 28dp top corners) is bottom-anchored
    try std.testing.expect(@as(f32, @floatFromInt(f.countColorIn(.{ .x = pb.x, .y = pb.y + 40, .w = pb.w, .h = 40 }, t.colors.surface_container_low))) > pb.w * 30);
    // the scrim dims the body above the panel
    try std.testing.expect(f.countColorIn(.{ .x = 200, .y = 20, .w = 80, .h = 60 }, 0x112233FF) == 0);
    // closed: no panel, no scrim — the body shows through
    open.set(false);
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    r.paint(d, 0x000000FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expect(f2.countColorIn(.{ .x = pb.x, .y = pb.y + 40, .w = pb.w, .h = 40 }, t.colors.surface_container_low) == 0);
    try std.testing.expect(f2.countColorIn(.{ .x = 200, .y = 20, .w = 80, .h = 60 }, 0x112233FF) > 80 * 60 - 40);
}

test "golden: a closed bottom sheet paints nothing past its bounds — no ghost over siblings" {
    const t = theme_mod.light;
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const bg: Color = 0x445566FF;
    const d = try bottomSheet(std.testing.allocator, open, null, .{
        .theme = t,
        .body = try golden.solidBox(std.testing.allocator, 480, 200, 0x112233FF),
        .content = try text_w.text(std.testing.allocator, "Sheet", .{ .color = t.colors.on_surface }),
    });
    defer d.deinit();
    // The sheet lives in a bounded box (gallery demo style) with room below:
    // the closed panel's translated pixels must never land outside its box.
    var r = try golden.Renderer.init(std.testing.allocator, 480, 320);
    defer r.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    r.paint(d, bg);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const below = Rect{ .x = 0, .y = 200, .w = 480, .h = 120 };
    try std.testing.expectEqual(@as(u64, 0), f.countNotIn(below, bg));
}

test "bottom_sheet: i18n — the framework labels localize + re-resolve on a locale switch" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Bottom sheet\": \"Hoja inferior\", \"Close sheet\": \"Cerrar hoja\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const open = try ui.state.Signal(bool).init(a, false);
    defer open.deinit();
    const d = try bottomSheet(a, open, null, .{});
    defer d.deinit();
    const s = stateOf(d);
    try std.testing.expectEqualStrings("Cerrar hoja", s.scrim.semantics.?.label);
    try std.testing.expectEqualStrings("Hoja inferior", s.panel.semantics.?.label);
    try i18n.setLocale("en");
    try std.testing.expectEqualStrings("Close sheet", s.scrim.semantics.?.label);
    try std.testing.expectEqualStrings("Bottom sheet", s.panel.semantics.?.label);
    const d2 = try bottomSheet(a, open, null, .{ .label = "My sheet" });
    defer d2.deinit();
    try i18n.setLocale("es");
    try std.testing.expectEqualStrings("My sheet", stateOf(d2).panel.semantics.?.label);
}
