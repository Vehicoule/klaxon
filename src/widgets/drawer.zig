// Navigation drawer widget (Phase 2d.1, M3E batch 1) — modal / dismissible /
// permanent drawer + NavigationDrawerItem rows.
//
// Ported from Compose NavigationDrawer.kt (vendored .ref/material3/
// NavigationDrawer.kt) — upstream functions: ModalNavigationDrawer,
// DismissibleNavigationDrawer, PermanentNavigationDrawer, ModalDrawerSheet /
// DismissibleDrawerSheet / PermanentDrawerSheet (all funnel into
// DrawerSheet), DrawerDefaults, NavigationDrawerItem +
// NavigationDrawerItemDefaults. Tokens: NavigationDrawerTokens,
// ScrimTokens, ElevationTokens, ShapeKeyTokens, motion scheme keys
// (DefaultSpatial / FastEffects / anchoredDraggable DefaultSpatial).
//
// Variants (DrawerOptions.kind):
//   - .modal (ModalNavigationDrawer): the sheet slides over the body behind
//     a Scrim (ScrimTokens.ContainerColor @ ContainerOpacity 0.32 × the
//     open fraction), corner shape CornerLargeEnd (16dp on the content
//     side, RTL-mirrored), ModalContainerColor = SurfaceContainerLow,
//     DrawerDefaults.ModalDrawerElevation = ElevationTokens.Level0 — the
//     M3E modal sheet is FLAT (NavigationDrawerTokens.ModalContainerElevation
//     Level1 exists but DrawerDefaults feeds Level0 into the Surface).
//   - .dismissible (DismissibleNavigationDrawer + DismissibleDrawerSheet):
//     no scrim; the BODY slides forward with the sheet (contentX = sheet
//     width + offset → progress × panel width); square RectangleShape,
//     StandardContainerColor = Surface, StandardContainerElevation = Level0.
//   - .permanent (PermanentNavigationDrawer + PermanentDrawerSheet): a Row —
//     the sheet never slides, the body is inset by the sheet width; square,
//     Surface, Level0; the open signal is ignored (always visible).
//
// Sheet geometry (DrawerSheet): width clamps to [MinimumDrawerWidth 240,
//   NavigationDrawerTokens.ContainerWidth 360], height = 100%
//   (ContainerHeightPercent). The `content` slot inside is padded by the
//   window safe-area insets — upstream wraps the content Column in
//   windowInsetsPadding(DrawerDefaults.windowInsets = systemBars
//   Vertical + Start): status/nav bars top + bottom plus the cutout on
//   the anchored start edge, on all three sheet variants; the surface
//   still paints edge-to-edge behind the system bars.
//   AnchoredDraggable horizontal drag follows the
//   finger (offset in [-width, 0], reverseDirection under RTL); release
//   settles with DrawerPositionalThreshold 0.5 (fraction of the travel) and
//   DrawerVelocityThreshold 400dp/s, then animates to the anchor with the
//   release velocity — open rides DefaultSpatial (Klaxon spatial_spring),
//   close FastEffects (fast_effects); a positive overshoot stretches the
//   container horizontally into the screen-edge gap (upstream
//   horizontalScaleUp — the flat bg widens toward the edge; the content
//   counter-scale is deferred). While invisible (fraction 0) the sheet is
//   not placed — Klaxon hides the subtree so keyboard focus can't reach
//   offscreen items (same reason upstream skips placement).
// Scrim: Scrim.kt — color × alpha fraction, tap dismisses (enabled only
//   while open), semantics "Close drawer".
// Keyboard/focus: Escape on key-UP closes (upstream onKeyEvent), hardware
//   back/Escape via the router's modal back stack while open; on open the
//   focus moves to the first focusable item inside the sheet
//   (focusRequester → "first element of the drawer"), on close it returns
//   to the node that had it (or clears if that node is gone).
// NavigationDrawerItem: 56dp min height (ActiveIndicatorHeight) with the
//   CornerFull active indicator (ActiveIndicatorColor SecondaryContainer),
//   the 12dp horizontal ItemPadding baked into the indicator (336dp inside
//   the 360dp sheet = ActiveIndicatorWidth); content insets start 16 / end
//   24 with a 12dp icon→label gap and a 12dp badge gap; icon 24
//   (IconSize), label LabelLarge, Active* = OnSecondaryContainer,
//   Inactive* = OnSurfaceVariant; selected rows also carry the .checked
//   semantic (upstream Role.Tab + selected state).
//   Indication: this widget ships no drawer-item node — the `content`
//   slot is app-composed (list_item carries the row indication).
//   Upstream's NavigationDrawerItem delegates to Surface(selected,
//   onClick, interactionSource) — `clickable(interactionSource,
//   indication = ripple(focusRingShape = shape))` over the
//   CornerFull indicator zone (NavigationDrawer.kt:1123-1165) — so a
//   row built from listItem/card-style nodes gets the shared
//   Tracker + StateLayer + Ripples behavior for free. The scrim is a
//   plain tap-catcher (Scrim.kt carries no indication).
//
// Structure: the drawer node holds three internal children — a body
// wrapper (translates the `body` slot for dismissible/permanent), an
// internal scrim node, and an internal panel node (a translate transform
// holding the bg surface + the `content` slot). The open/closed state is a
// Signal(bool) owned by the app; the drawer subscribes (animation) and
// unsubscribes at deinit.
//
// Sizing: the drawer fills FINITE constraints — a modal is screen-height, so
// it measures to 100% of a bounded parent (window/overlay). Inside an
// unbounded parent (a scroll column), it would swallow all the remaining
// main-axis space: wrap it in a bounded box (e.g. constrainedBox with
// min_h = max_h) to give it a fixed stage.
//
// Remaining deviations (upstream behavior Klaxon does not reproduce):
//   - Predictive back (DrawerPredictiveBackHandler + the predictiveBack*
//     scale modifiers on Android 14+) is deferred — Klaxon has no system
//     back-progress events; Escape/edge dismissal works.
//   - horizontalScaleUp's goal is covered differently: the panel surface
//     fill stretches into the screen-edge gap on overshoot (panelBgPaint's
//     `extra`) rather than scaling the container layer, so the children
//     never distort and horizontalScaleDown's counter-scale has nothing
//     to undo (same visual result, cheaper path).
//   - The drag gesture engages only on events that reach the drawer via
//     bubbling: a child that consumes .move (a horizontal scrollable)
//     keeps the gesture (content wins — close to upstream's nested-scroll
//     interplay). The slop starts counting at the first .move the drawer
//     sees (downs claimed by children are re-synthesized), so a drag on a
//     button needs ~2×12px before it engages vs upstream's ~1 slop.
//   - confirm_state_change gates drawer-INITIATED transitions only; the
//     app's own sig.set writes are unguarded (the app owns the signal).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const i18n_mod = @import("../ui/i18n.zig");
const anim = ui.anim;
const node_mod = ui.node;
const theme_mod = @import("../theme.zig");
const icon_w = @import("icon.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;
const Callback = ui.state.Callback;

/// M3 drawer tokens (NavigationDrawerTokens + ScrimTokens + DrawerDefaults).
const scrim_max_alpha: f32 = 0.32; // ScrimTokens.ContainerOpacity
const panel_radius: f32 = 16; // ContainerShape = CornerLargeEnd (modal only)
const minimum_w: f32 = 240; // MinimumDrawerWidth (DrawerSheet sizeIn)
const drag_positional: f32 = 0.5; // DrawerPositionalThreshold (fraction)
const drag_velocity: f32 = 400; // DrawerVelocityThreshold (dp/s)

/// Which upstream drawer this node ports (DrawerOptions.kind).
pub const DrawerKind = enum {
    modal, // ModalNavigationDrawer — scrim + CornerLargeEnd sheet over the body
    dismissible, // DismissibleNavigationDrawer — no scrim; the body slides with it
    permanent, // PermanentNavigationDrawer — a Row: fixed sheet + inset body
};

pub const DrawerOptions = struct {
    theme: Theme = theme_mod.light,
    kind: DrawerKind = .modal,
    width: f32 = 360, // NavigationDrawerTokens.ContainerWidth (max)
    /// The panel semantics label — null resolves the localized
    /// "Navigation drawer" (an app string is verbatim).
    label: ?[]const u8 = null,
    gestures_enabled: bool = true, // upstream gesturesEnabled (anchoredDraggable)
    /// Upstream DrawerState.confirmStateChange: vetoes drawer-initiated
    /// transitions (scrim tap, Escape/back, drag settle). Called with the
    /// desired open state; false refuses the change. App-side sig.set is
    /// NOT gated — the app owns the signal.
    confirm_state_change: ?*const fn (userdata: ?*anyopaque, open: bool) bool = null,
    confirm_userdata: ?*anyopaque = null,
    content: ?*Node = null, // the panel content
    body: ?*Node = null, // the page content (behind the scrim)
};

const DrawerState = struct {
    sig: *ui.state.Signal(bool),
    opts: DrawerOptions,
    on_closed: ?Callback = null,
    panel: *Node, // internal panel node
    scrim: *Node, // internal scrim node
    progress: f32 = 0, // 0 = closed, 1 = open (animated)
    anim_to: f32 = 0, // current animation target
    laid_out: bool = false,
    panel_w: f32 = 0, // laid-out panel width (drives the slide offset)
    anim_channel: u8 = 0, // channel marker (stable address)
    back_registered: bool = false, // on the router's modal back stack while open
    /// The anchoredDraggable pan recognizer (horizontal slide; sees events
    /// that bubble up unconsumed).
    pan: ui.gestures.Recognizer = .{ .kind = .pan },
    i18n: ?*i18n_mod.I18n = null,
    dragging: bool = false, // the drawer claimed the pointer (capture moved)
    /// Weak id of the node holding keyboard focus when the drawer opened —
    /// restored on close while it is still in the tree (a destroyed node
    /// resolves null → no restore).
    saved_focus: ?u64 = null,
    focus_saved: bool = false,
};

fn stateOf(n: *Node) *DrawerState {
    return @ptrCast(@alignCast(n.state.?));
}

/// The direction the panel hides towards when closed: -1 in LTR (off the
/// start side = left), +1 in RTL.
fn hideSign() f32 {
    return if (ui.i18n.direction() == .rtl) 1 else -1;
}

/// The direction the panel OPENS towards: +1 in LTR, -1 in RTL (upstream
/// anchoredDraggable's reverseDirection = isRtl — "forward" motion opens).
fn forwardSign() f32 {
    return -hideSign();
}

// --- internal panel node ---
//
// The panel is a transparent transform node (its pre_children_paint applies
// the animated slide): its children — an internal background node and the
// `content` slot — paint translated. The background is a child (not the
// panel's own paint) so the slide moves it too.

const PanelState = struct {
    drawer: *Node, // back-pointer (reads theme + width)
    offset_x: f32 = 0, // animated translation (paint-time)
};

fn panelStateOf(n: *Node) *PanelState {
    return @ptrCast(@alignCast(n.state.?));
}

fn panelMeasure(n: *Node, c: Constraints) Size {
    const s = panelStateOf(n);
    const opts = stateOf(s.drawer).opts;
    // DrawerSheet sizeIn(minWidth = 240, maxWidth = ContainerWidth): a
    // narrower parent still yields a 240-wide sheet (it overflows).
    var w = opts.width;
    if (std.math.isFinite(c.max_w)) w = @min(w, @max(c.max_w, minimum_w));
    const h = if (std.math.isFinite(c.max_h)) c.max_h else 0;
    return c.constrain(.{ .w = w, .h = h });
}
fn panelLayout(n: *Node, bounds: Rect) void {
    // Fill semantics: the background fills the panel edge-to-edge (the
    // Surface draws under the system bars); the content slot is padded by
    // the window safe-area insets — upstream wraps the content Column in
    // windowInsetsPadding(windowInsets), and DrawerDefaults.windowInsets
    // is systemBars Vertical + Start (status/nav bars top + bottom, the
    // cutout on the anchored start edge) for all three sheet variants.
    // The global is re-read each layout; an inset change applies on the
    // next pass (the platform layer exposes no change signal yet).
    const ds = stateOf(panelStateOf(n).drawer);
    const dir = ui.i18n.direction();
    const sa = ui.platform.window_insets.safeArea();
    const e = (ui.layout.EdgeInsetsDirectional{
        .start = if (dir == .rtl) sa.right else sa.left,
        .top = sa.top,
        .bottom = sa.bottom,
    }).resolve(dir);
    for (n.children.items) |child| {
        if (ds.opts.content != null and child == ds.opts.content.?) {
            child.layout(.{
                .x = bounds.x + e.left,
                .y = bounds.y + e.top,
                .w = @max(0, bounds.w - e.hSum()),
                .h = @max(0, bounds.h - e.vSum()),
            });
        } else {
            child.layout(bounds);
        }
    }
}
fn panelPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx; // transparent: the background child paints (translated)
}
fn panelPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    // Own save: the restore in post_children_paint must not pop a caller's
    // canvas state — an enclosing clip (scroll view, damage rect) survives.
    ui.paint.save(ctx);
    ui.paint.translate(ctx, panelStateOf(n).offset_x, 0);
}
fn panelPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.restore(ctx);
}
fn panelMapPaintRect(n: *Node, r: Rect) Rect {
    const dx = panelStateOf(n).offset_x;
    return .{ .x = r.x + dx, .y = r.y, .w = r.w, .h = r.h };
}
fn panelPreChildrenHit(n: *Node, px: f32, py: f32) node_mod.HitPoint {
    const dx = panelStateOf(n).offset_x;
    return .{ .x = px - dx, .y = py };
}
fn panelHitBounds(n: *Node) Rect {
    const b = n.bounds;
    const dx = panelStateOf(n).offset_x;
    return .{ .x = b.x + dx, .y = b.y, .w = b.w, .h = b.h };
}
fn panelDeinit(n: *Node) void {
    n.allocator.destroy(panelStateOf(n));
}
const panel_vtable = ui.node.VTable{
    .measure = panelMeasure,
    .layout = panelLayout,
    .paint = panelPaint,
    .deinit = panelDeinit,
    .pre_children_paint = panelPreChildrenPaint,
    .post_children_paint = panelPostChildrenPaint,
    .map_paint_rect = panelMapPaintRect,
    .hit_bounds = panelHitBounds,
    .pre_children_hit = panelPreChildrenHit,
};

// --- internal panel background node (the translated container surface) ---

const PanelBgState = struct { drawer: *Node };

fn panelBgStateOf(n: *Node) *PanelBgState {
    return @ptrCast(@alignCast(n.state.?));
}

fn panelBgMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = c.max_w, .h = c.max_h });
}
fn panelBgLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn panelBgPaint(n: *Node, ctx: *kx.Ctx) void {
    const ds = stateOf(panelBgStateOf(n).drawer);
    const t = ds.opts.theme;
    const b = n.bounds;
    // Modal: CornerLargeEnd (16dp on the content side) on surface_container_low.
    // Dismissible + permanent sheets are RectangleShape on surface. All flat —
    // upstream DrawerDefaults feeds ElevationTokens.Level0 for both variants.
    const modal = ds.opts.kind == .modal;
    const radius: f32 = if (modal) panel_radius else 0;
    const color = if (modal) t.colors.surface_container_low else t.colors.surface;
    // horizontalScaleUp: while the spring overshoots past the open anchor the
    // surface stretches into the screen-edge gap (offset past zero).
    const ps = panelStateOf(ds.panel);
    const extra = @max(0, ps.offset_x * forwardSign());
    const rtl = ui.i18n.direction() == .rtl;
    // Build the fill rect: a CornerLargeEnd pill is a 16-rounded rect
    // extended past the screen-edge side so that side's corners land
    // outside the clip and read square. LTR: [b.x-16, b.x+b.w] rounds the
    // right edge; RTL: [b.x, b.x+b.w+16] rounds the left edge.
    var x = b.x;
    var w = b.w;
    var cx = b.x;
    var cw = b.w;
    if (modal) {
        if (rtl) {
            w += radius;
        } else {
            x -= radius;
            w += radius;
        }
    }
    if (rtl) {
        w += extra;
        cw += extra;
    } else {
        x -= extra;
        w += extra;
        cx -= extra;
        cw += extra;
    }
    // clipRect pushes its own save (clipReset pops it); for the square
    // variants the clip just bounds the (already exact) fill.
    ui.paint.clipRect(ctx, cx, b.y, cw, b.h);
    if (radius > 0) {
        ui.paint.fillRRect(ctx, x, b.y, w, b.h, radius, color);
    } else {
        ui.paint.fillRect(ctx, x, b.y, w, b.h, color);
    }
    ui.paint.clipReset(ctx);
}
fn panelBgDeinit(n: *Node) void {
    n.allocator.destroy(panelBgStateOf(n));
}
const panel_bg_vtable = ui.node.VTable{
    .measure = panelBgMeasure,
    .layout = panelBgLayout,
    .paint = panelBgPaint,
    .deinit = panelBgDeinit,
};

// --- internal scrim node ---

const ScrimState = struct {
    drawer: *Node, // back-pointer (reads theme + close)
    alpha: f32 = 0, // 0..scrim_max_alpha (animated)
    saw_move: bool = false, // the press turned into a drag — not a tap
};

fn scrimStateOf(n: *Node) *ScrimState {
    return @ptrCast(@alignCast(n.state.?));
}

fn scrimMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = c.max_w, .h = c.max_h });
}
fn scrimLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn scrimPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = scrimStateOf(n);
    const t = stateOf(s.drawer).opts.theme;
    const b = n.bounds;
    const a: u32 = @intFromFloat(std.math.clamp(s.alpha, 0, 1) * 255);
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, (t.colors.scrim & 0xFFFFFF00) | a);
}
fn scrimOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = scrimStateOf(n);
    // The scrim exists only on the modal variant (dismissible/permanent
    // sheets have none — clicks fall through to the body).
    if (stateOf(s.drawer).opts.kind != .modal) return false;
    switch (ev.phase) {
        .down => return true, // capture the press
        .up => {
            if (n.bounds.contains(ev.x, ev.y)) closeDrawer(s.drawer);
            return true;
        },
        else => return true,
    }
}
fn scrimDeinit(n: *Node) void {
    input.releaseNode(n);
    n.allocator.destroy(scrimStateOf(n));
}
const scrim_vtable = ui.node.VTable{
    .measure = scrimMeasure,
    .layout = scrimLayout,
    .paint = scrimPaint,
    .deinit = scrimDeinit,
    .on_pointer = scrimOnPointer,
};

// --- drawer node ---

/// Snap to a progress value (first layout / no timeline): offset + alpha +
/// scrim visibility, then repaint both internals.
fn applyProgress(n: *Node, s: *DrawerState, progress: f32, alpha: f32) void {
    s.progress = progress;
    panelStateOf(s.panel).offset_x = hideSign() * (s.panel_w * (1 - progress));
    scrimStateOf(s.scrim).alpha = alpha;
    // The scrim is modal-variant chrome — hidden for dismissible/permanent.
    s.scrim.setVisible(progress > 0.01 and s.opts.kind == .modal);
    // The slide is paint-time translation — a fully closed panel still sat
    // in its bounds and painted/hit-tested past the sheet edge (a ghost
    // over sibling content). Hide the subtree outright: a closed drawer
    // paints nothing.
    const open = progress > 0.001;
    s.panel.setVisible(open);
    if (s.opts.kind == .modal) {
        ui.semantics.syncModalFocus(s.panel, open, &s.saved_focus, &s.focus_saved);
    }
    markInternalsDirty(n, s);
}

/// Repaint the panel (covering the swept region) and the scrim.
fn markInternalsDirty(n: *Node, s: *DrawerState) void {
    _ = n;
    const b = s.panel.bounds;
    const dx = panelStateOf(s.panel).offset_x;
    const visual = Rect{ .x = b.x + dx, .y = b.y, .w = b.w, .h = b.h };
    s.panel.markDirtyRect(node_mod.rectUnion(b, visual));
    s.scrim.markDirty();
}

fn drawerAnimUpdateCb(userdata: ?*anyopaque, v: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    applyProgress(n, stateOf(n), v[0], v[1]);
}

/// Springs settle within 0.1 units — snap to the exact target so no residue
/// remains on the panel offset / scrim alpha.
fn drawerAnimCompleteCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    applyProgress(n, s, s.anim_to, s.anim_to * scrim_max_alpha);
}

/// Slide the panel + fade the scrim to `to` (0/1); without a timeline, snap.
/// Upstream splits the spec by direction — open rides DefaultSpatial, close
/// FastEffects (NavigationDrawer.kt:353-355, 501-502). `v0` seeds the spring
/// (a drag settle animates to the anchor WITH the release velocity).
fn animateProgress(n: *Node, s: *DrawerState, to: f32, v0: anim.Vec4) void {
    s.anim_to = to;
    const from: anim.Vec4 = .{ s.progress, scrimStateOf(s.scrim).alpha, 0, 0 };
    const target: anim.Vec4 = .{ to, to * scrim_max_alpha, 0, 0 };
    const springs = s.opts.theme.motion.springs;
    const spec = if (to == 0) springs.fast_effects else springs.spatial_spring;
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.springAnim(from, target, spec, v0),
            .from = from,
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = drawerAnimUpdateCb, .userdata = n },
            .on_complete = .{ .fn_ptr = drawerAnimCompleteCb, .userdata = n },
        });
    } else {
        applyProgress(n, s, to, to * scrim_max_alpha);
    }
}

/// Open state changed (app set the signal): animate (or snap before the
/// first layout — the first layout applies the current state directly).
/// The permanent variant ignores the signal (the sheet never slides).
fn drawerSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.opts.kind == .permanent) return;
    syncBackHandler(n, s); // before the laid_out gate: registration tracks state
    if (!s.laid_out) return;
    const target: f32 = if (s.sig.peek()) 1 else 0;
    if (target != s.anim_to) animateProgress(n, s, target, .{ 0, 0, 0, 0 });
}

fn closeDrawer(n: *Node) void {
    const s = stateOf(n);
    // Upstream confirmStateChange gates drawer-initiated closes.
    if (s.opts.confirm_state_change) |f| {
        if (!f(s.opts.confirm_userdata, false)) return;
    }
    s.sig.set(false);
    if (s.on_closed) |cb| cb.fn_ptr(cb.userdata);
}

/// AnchoredDraggable drag step: forward motion (open direction) increases
/// progress by dx/panel_w; the running channel is cancelled so the spring
/// can't overwrite the finger's position.
fn dragStep(n: *Node, s: *DrawerState, dx: f32) void {
    if (s.panel_w <= 0) return;
    const p = std.math.clamp(s.progress + dx * forwardSign() / s.panel_w, 0, 1);
    applyProgress(n, s, p, p * scrim_max_alpha);
}

/// Upstream settleToVelocity: the release velocity decides past
/// DrawerVelocityThreshold (400dp/s), else the positional threshold
/// (progress vs 0.5); the settle animates WITH the release velocity —
/// and confirmStateChange vetoes the change (animate back to the signal).
fn settleDrag(n: *Node, s: *DrawerState, vx: f32) void {
    const fwd_v = vx * forwardSign();
    const want_open = if (fwd_v >= drag_velocity)
        true
    else if (fwd_v <= -drag_velocity)
        false
    else
        s.progress >= drag_positional;
    if (want_open) {
        if (s.opts.confirm_state_change) |f| {
            if (!f(s.opts.confirm_userdata, true)) {
                s.dragging = false;
                animateProgress(n, s, if (s.sig.peek()) 1 else 0, .{ 0, 0, 0, 0 });
                return;
            }
        }
        s.sig.set(true); // drawerSyncCb animates; the velocity play below wins
    } else {
        closeDrawer(n); // confirm + on_closed inside; a veto keeps it open
    }
    s.dragging = false;
    const v_prog = fwd_v / @max(s.panel_w, 1);
    animateProgress(n, s, if (s.sig.peek()) 1 else 0, .{ v_prog, v_prog * scrim_max_alpha, 0, 0 });
}

/// AnchoredDraggable: pointer events that bubble up unconsumed feed the
/// horizontal pan recognizer (a child claiming .move — a horizontal
/// scrollable — wins, content-first like upstream's nested-scroll
/// interplay). On engage the capture moves to the drawer mid-gesture; a
/// down a child claimed is re-synthesized at the first move (slop counts
/// from there).
fn drawerOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (s.opts.kind == .permanent or !s.opts.gestures_enabled) return false;
    switch (ev.phase) {
        .down => {
            _ = s.pan.feed(ev);
            return false; // don't claim: children may still take the press
        },
        .move => {
            if (s.pan.tracking == null and !s.dragging) {
                var synth = ev;
                synth.phase = .down;
                _ = s.pan.feed(synth); // the missed down, re-synthesized here
            }
            if (s.pan.feed(ev)) |fire| switch (fire) {
                .pan_start => |d| {
                    // Horizontal drags only — a vertical pan keeps bubbling
                    // (a scrollable ancestor or the page handles it).
                    if (@abs(d.dy) > @abs(d.dx)) {
                        s.pan.reset();
                        return false;
                    }
                    s.dragging = true;
                    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel));
                    // except = n: the previous owner's .outside_down bubbles
                    // through us — without the skip it would reset this drag.
                    if (input.current()) |r| r.captureNode(ev, n, n);
                    dragStep(n, s, d.dx);
                    return true;
                },
                .pan_update => |d| {
                    dragStep(n, s, d.dx);
                    return true;
                },
                else => {},
            };
            return s.dragging;
        },
        .up => {
            if (s.pan.feed(ev)) |fire| switch (fire) {
                .pan_end => |d| {
                    dragStep(n, s, d.dx); // the last move→up displacement
                    settleDrag(n, s, d.vx);
                    return true;
                },
                else => {},
            };
            if (s.dragging) {
                settleDrag(n, s, 0);
                return true;
            }
            return false;
        },
        .outside_down => {
            s.dragging = false;
            s.pan.reset();
            return false;
        },
        else => return false,
    }
}

/// Escape / hardware-back while the drawer is open (the router consults the
/// modal back stack before the navigator — dispatchBack).
fn drawerBackCb(userdata: ?*anyopaque) bool {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (!s.sig.peek()) return false;
    closeDrawer(n); // the signal sync pops the handler
    return true;
}

/// Keep the router's modal back stack in sync with the open state: while open,
/// Escape dismisses the drawer even when keyboard focus is outside it.
fn syncBackHandler(n: *Node, s: *DrawerState) void {
    const want = s.sig.peek();
    if (want == s.back_registered) return;
    const router = input.current() orelse return;
    if (want) {
        if (router.pushBackHandler(.{ .fn_ptr = drawerBackCb, .userdata = n })) s.back_registered = true;
    } else {
        router.popBackHandler(n);
        s.back_registered = false;
    }
}

fn drawerMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    var size = Size{};
    if (s.opts.body) |body| size = body.measure(c);
    const w = if (std.math.isFinite(c.max_w)) c.max_w else size.w;
    const h = if (std.math.isFinite(c.max_h)) c.max_h else size.h;
    return c.constrain(.{ .w = w, .h = h });
}

fn drawerLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    s.panel_w = @min(s.opts.width, bounds.w);
    const rtl = ui.i18n.direction() == .rtl;
    // The body slot by kind: modal covers the whole area (the sheet floats
    // over it); dismissible slides the body forward with the sheet
    // (progress × sheet width toward the end); permanent is a Row — the
    // body is inset by the sheet width on the start side.
    if (s.opts.body) |body| {
        switch (s.opts.kind) {
            .modal => body.layout(bounds),
            .dismissible => {
                const dx = s.progress * s.panel_w * if (rtl) @as(f32, -1) else 1;
                body.layout(.{ .x = bounds.x + dx, .y = bounds.y, .w = bounds.w, .h = bounds.h });
            },
            .permanent => {
                if (rtl) {
                    body.layout(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w - s.panel_w, .h = bounds.h });
                } else {
                    body.layout(.{ .x = bounds.x + s.panel_w, .y = bounds.y, .w = bounds.w - s.panel_w, .h = bounds.h });
                }
            },
        }
    }
    s.scrim.layout(bounds);
    // The panel sits at the start side, full height (its paint-time
    // translation slides it in/out).
    const px = if (rtl) bounds.x + bounds.w - s.panel_w else bounds.x;
    s.panel.layout(.{ .x = px, .y = bounds.y, .w = s.panel_w, .h = bounds.h });
    // permanent: the sheet never slides — force progress 1 and ignore the
    // signal (upstream PermanentNavigationDrawer has no open state).
    const target: f32 = if (s.opts.kind == .permanent) 1 else if (s.sig.peek()) 1 else 0;
    if (!s.laid_out) {
        s.anim_to = target;
        applyProgress(n, s, target, target * scrim_max_alpha);
        s.laid_out = true;
    } else if (target != s.anim_to) {
        animateProgress(n, s, target, .{ 0, 0, 0, 0 });
    }
}

fn drawerPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx; // transparent chrome: the body slot paints behind
}

fn drawerOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (s.opts.kind == .permanent) return false; // no dismiss concept
    if (ev.kind == .key_down and ev.key == .escape and s.sig.peek()) {
        closeDrawer(n); // M3: Escape dismisses the modal/dismissible drawer
        return true;
    }
    return false;
}

fn drawerDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel)); // the update cb points at this node
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = drawerSyncCb, .userdata = n } });
    if (s.back_registered) {
        if (input.current()) |r| r.popBackHandler(n); // destroyed while open
        s.back_registered = false;
    }
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = drawerLocaleCb, .userdata = n });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

/// The scrim + panel a11y labels — tr()-resolved, so the locale callback
/// re-attaches in the new locale.
fn attachDrawerSemantics(n: *Node) void {
    const s = stateOf(n);
    ui.semantics.attach(s.scrim, .{ .role = .button, .label = i18n_mod.tr("Close drawer"), .actions = ui.semantics.Actions.initOne(.activate) });
    ui.semantics.attach(s.panel, .{
        .role = .group,
        .label = s.opts.label orelse i18n_mod.tr("Navigation drawer"),
        .modal = s.opts.kind == .modal,
    });
}

fn drawerLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    attachDrawerSemantics(n);
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

const drawer_vtable = ui.node.VTable{
    .measure = drawerMeasure,
    .layout = drawerLayout,
    .paint = drawerPaint,
    .deinit = drawerDeinit,
    .on_pointer = drawerOnPointer,
    .on_key = drawerOnKey,
};

/// Modal navigation drawer (M3E). Slots: `content` (the panel), `body` (the
/// page behind). `open` is app-owned; the drawer subscribes (slide + scrim
/// animation) and unsubscribes at deinit. `on_closed` fires when the drawer
/// is dismissed (scrim click / Escape).
pub fn drawer(allocator: std.mem.Allocator, open: *ui.state.Signal(bool), on_closed: ?Callback, opts: DrawerOptions) !*Node {
    const node = try Node.create(allocator, &drawer_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(DrawerState);
    errdefer allocator.destroy(s);
    // Internal scrim.
    const scrim = try Node.create(allocator, &scrim_vtable);
    errdefer allocator.destroy(scrim);
    const ss = try allocator.create(ScrimState);
    errdefer allocator.destroy(ss);
    ss.* = .{ .drawer = node, .alpha = 0 };
    scrim.state = ss;
    // Internal panel + its background child (the translated container surface).
    const panel = try Node.create(allocator, &panel_vtable);
    errdefer allocator.destroy(panel);
    const ps = try allocator.create(PanelState);
    errdefer allocator.destroy(ps);
    ps.* = .{ .drawer = node, .offset_x = 0 };
    panel.state = ps;
    const panel_bg = try Node.create(allocator, &panel_bg_vtable);
    errdefer allocator.destroy(panel_bg);
    const bgs = try allocator.create(PanelBgState);
    errdefer allocator.destroy(bgs);
    bgs.* = .{ .drawer = node };
    panel_bg.state = bgs;
    panel.add(panel_bg);
    s.* = .{ .sig = open, .opts = opts, .on_closed = on_closed, .panel = panel, .scrim = scrim };
    node.state = s;
    // Paint order: body (behind), scrim, panel (front); the panel holds the
    // background child first, then the content slot.
    if (opts.body) |body| node.add(body);
    node.add(scrim);
    node.add(panel);
    if (opts.content) |content| panel.add(content);
    attachDrawerSemantics(node); // Phase 2c
    open.subscribe(.{ .callback = .{ .fn_ptr = drawerSyncCb, .userdata = node } });
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = drawerLocaleCb, .userdata = node });
    if (opts.kind != .permanent) syncBackHandler(node, s); // already open at build: register immediately
    return node;
}

// --- tests ---

const text_w = @import("text.zig");
const layout_w = @import("layout.zig");

test "drawer: closed by default — the scrim is hidden, the panel off-screen" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const d = try drawer(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
        .content = try text_w.text(std.testing.allocator, "Panel", .{}),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s = stateOf(d);
    try std.testing.expectEqual(@as(f32, 0), s.progress);
    try std.testing.expect(!s.scrim.visible);
    try std.testing.expectEqual(@as(f32, -320), panelStateOf(s.panel).offset_x); // panel_w = min(360, 320) = 320
    // hidden too — translation alone would still paint/hit-test past the edge
    try std.testing.expect(!s.panel.visible);
    try std.testing.expectEqual(@as(f32, 0), scrimStateOf(s.scrim).alpha);
}

test "drawer: measure/layout fill the parent; the panel is 360 wide max" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const body = try golden.solidBox(std.testing.allocator, 100, 100, 0xFF);
    const d = try drawer(std.testing.allocator, open, null, .{ .body = body });
    defer d.deinit();
    const m = d.measure(.{ .max_w = 480, .max_h = 600 });
    try std.testing.expectEqual(@as(f32, 480), m.w);
    try std.testing.expectEqual(@as(f32, 600), m.h);
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 600 });
    const s = stateOf(d);
    try std.testing.expectEqual(@as(f32, 360), s.panel.bounds.w);
    try std.testing.expectEqual(@as(f32, 600), s.panel.bounds.h);
    try std.testing.expectEqual(@as(f32, 0), s.panel.bounds.x); // start side (LTR)
    try std.testing.expectEqual(@as(f32, 1), s.progress); // open: snapped at first layout
    try std.testing.expect(s.scrim.visible);
    try std.testing.expectApproxEqAbs(scrim_max_alpha, scrimStateOf(s.scrim).alpha, 1e-6);
}

test "drawer: the content slot is padded by the window safe-area insets" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const content = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF);
    const d = try drawer(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 480, 200, 0xFF),
        .content = content,
    });
    defer d.deinit();
    // The host pushes the system-bar/cutout insets (test injection point);
    // restore the zero default for the other tests.
    ui.platform.window_insets.setSafeArea(.{ .top = 24, .bottom = 16, .left = 8, .right = 4 });
    defer ui.platform.window_insets.set(.{});
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    // LTR start = left: the content insets to (8, 24) → 352×160 inside
    // the 360×200 panel. The END-side inset (right = 4) does NOT apply —
    // DrawerDefaults.windowInsets is Vertical + Start only.
    try std.testing.expectEqual(@as(f32, 8), content.bounds.x);
    try std.testing.expectEqual(@as(f32, 24), content.bounds.y);
    try std.testing.expectEqual(@as(f32, 352), content.bounds.w);
    try std.testing.expectEqual(@as(f32, 160), content.bounds.h);
    // the background surface still paints edge-to-edge under the bars
    const bg = stateOf(d).panel.children.items[0];
    try std.testing.expectEqual(@as(f32, 0), bg.bounds.x);
    try std.testing.expectEqual(@as(f32, 0), bg.bounds.y);
    try std.testing.expectEqual(@as(f32, 360), bg.bounds.w);
    try std.testing.expectEqual(@as(f32, 200), bg.bounds.h);
}

test "drawer: without a timeline the panel snaps open/closed on the signal" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const d = try drawer(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0xFF),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s = stateOf(d);
    open.set(true);
    try std.testing.expectEqual(@as(f32, 1), s.progress);
    try std.testing.expectEqual(@as(f32, 0), panelStateOf(s.panel).offset_x);
    try std.testing.expect(s.scrim.visible);
    try std.testing.expect(s.panel.visible);
    open.set(false);
    try std.testing.expectEqual(@as(f32, 0), s.progress);
    try std.testing.expectEqual(@as(f32, -320), panelStateOf(s.panel).offset_x);
    try std.testing.expect(!s.scrim.visible);
    try std.testing.expect(!s.panel.visible);
}

test "drawer: with a timeline the panel slides (spatial spring) and the scrim fades" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const d = try drawer(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0xFF),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s = stateOf(d);
    open.set(true); // launches the spring
    try std.testing.expect(tl.hasActive());
    tl.tick(0); // lazy start
    try std.testing.expectEqual(@as(f32, 0), s.progress);
    tl.tick(50); // mid-flight: strictly between closed and open
    try std.testing.expect(s.progress > 0 and s.progress < 1);
    try std.testing.expect(panelStateOf(s.panel).offset_x > -320 and panelStateOf(s.panel).offset_x < 0);
    try std.testing.expect(s.scrim.visible); // alpha > 0 as soon as progress > 0.01
    tl.tick(10_000); // settled: exactly open
    try std.testing.expectEqual(@as(f32, 1), s.progress);
    try std.testing.expectEqual(@as(f32, 0), panelStateOf(s.panel).offset_x);
    try std.testing.expectApproxEqAbs(scrim_max_alpha, scrimStateOf(s.scrim).alpha, 1e-4);
    try std.testing.expect(!tl.hasActive());
}

test "drawer: a scrim click closes it (and fires on_closed); Escape too" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    var closed: u32 = 0;
    const d = try drawer(std.testing.allocator, open, .{ .fn_ptr = struct {
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
    // the panel is 360 wide (start side): a click at x=400 hits the scrim
    router.dispatchPointer(d, .{ .phase = .down, .x = 400, .y = 100 });
    router.dispatchPointer(d, .{ .phase = .up, .x = 400, .y = 100 });
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 1), closed);
    // Escape closes too (the focus is inside the drawer's subtree)
    open.set(true);
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    var router2 = input.InputRouter{};
    input.setCurrent(&router2);
    defer input.setCurrent(null);
    const body_node = d.children.items[0];
    input.requestFocus(body_node);
    try std.testing.expect(router2.dispatchKey(.{ .kind = .key_down, .key = .escape }));
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 2), closed);
}

test "drawer: the global back path closes it even when focus is outside" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const d = try drawer(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 480, 200, 0xFF),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // a navigator back handler is registered (would pop a page)
    var popped: u32 = 0;
    router.setBackHandler(.{ .fn_ptr = struct {
        fn cb(ud: ?*anyopaque) bool {
            const p: *u32 = @ptrCast(@alignCast(ud.?));
            p.* += 1;
            return true;
        }
    }.cb, .userdata = &popped });
    // open the drawer with no focus inside it: it registers on the back stack
    open.set(true);
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    try std.testing.expectEqual(@as(usize, 1), router.back_stack_len);
    // back request: the drawer dismisses itself, the navigator is NOT popped
    try std.testing.expect(router.dispatchBack());
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 0), popped);
    try std.testing.expectEqual(@as(usize, 0), router.back_stack_len);
    // closed: back falls through to the navigator
    try std.testing.expect(router.dispatchBack());
    try std.testing.expectEqual(@as(u32, 1), popped);
}

test "drawer: an anchored drag opens/closes by position and velocity; confirm vetoes" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    var vetoes: u32 = 0;
    const d = try drawer(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 480, 200, 0xFF),
        .confirm_state_change = struct {
            fn f(ud: ?*anyopaque, want_open: bool) bool {
                const c: *u32 = @ptrCast(@alignCast(ud.?));
                c.* += 1;
                return want_open; // refuse every close
            }
        }.f,
        .confirm_userdata = &vetoes,
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const s = stateOf(d);
    // drag open past the 0.5 positional threshold (panel_w 360 → >180px)
    router.dispatchPointer(d, .{ .phase = .down, .x = 10, .y = 100, .time_ms = 0 });
    for ([_]f32{ 40, 100, 160, 220, 260 }, 1..) |x, i| {
        router.dispatchPointer(d, .{ .phase = .move, .x = x, .y = 100, .time_ms = @intCast(i * 16) });
    }
    try std.testing.expect(s.dragging);
    router.dispatchPointer(d, .{ .phase = .up, .x = 260, .y = 100, .time_ms = 96 });
    try std.testing.expect(open.peek()); // progress ~0.72 → opened
    try std.testing.expectEqual(@as(u32, 1), vetoes); // confirm consulted
    // a short drag with a fast CLOSE velocity (<-400dp/s) closes — but the
    // veto keeps it open
    router.dispatchPointer(d, .{ .phase = .down, .x = 200, .y = 100, .time_ms = 200 });
    router.dispatchPointer(d, .{ .phase = .move, .x = 150, .y = 100, .time_ms = 216 });
    router.dispatchPointer(d, .{ .phase = .move, .x = 100, .y = 100, .time_ms = 232 }); // ~-3000dp/s over the window
    router.dispatchPointer(d, .{ .phase = .up, .x = 90, .y = 100, .time_ms = 248 });
    try std.testing.expect(open.peek()); // the veto refused the close
    try std.testing.expectEqual(@as(u32, 2), vetoes);
    // a tap (no drag) does not toggle anything
    router.dispatchPointer(d, .{ .phase = .down, .x = 200, .y = 100, .time_ms = 300 });
    router.dispatchPointer(d, .{ .phase = .up, .x = 200, .y = 100, .time_ms = 316 });
    try std.testing.expect(open.peek());
}

test "golden: drawer paints the body, the scrim and the panel (open)" {
    const t = theme_mod.light;
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const body = try golden.solidBox(std.testing.allocator, 480, 200, 0x112233FF);
    const panel_content = try layout_w.padding(std.testing.allocator, .{ .left = 16, .top = 16, .right = 16, .bottom = 16 });
    panel_content.add(try text_w.text(std.testing.allocator, "Drawer", .{ .color = t.colors.on_surface }));
    const d = try drawer(std.testing.allocator, open, null, .{ .theme = t, .body = body, .content = panel_content });
    defer d.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 480, 200);
    defer r.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    r.paint(d, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // panel (360 wide, surface_container_low) on the start side
    try std.testing.expect(f.countColorIn(.{ .x = 0, .y = 0, .w = 360, .h = 200 }, t.colors.surface_container_low) > 300 * 180);
    // scrim over the body (right of the panel): the pure body color is gone
    // (blended with the 32% black scrim)
    try std.testing.expect(f.countColorIn(.{ .x = 400, .y = 100, .w = 60, .h = 80 }, 0x112233FF) == 0);
    try std.testing.expect(f.countNotIn(.{ .x = 400, .y = 100, .w = 60, .h = 80 }, 0x112233FF) > 60 * 80 - 40);
    // closed: no panel, no scrim — the body shows through
    open.set(false);
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    r.paint(d, 0x000000FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expect(f2.countColorIn(.{ .x = 0, .y = 0, .w = 360, .h = 200 }, t.colors.surface_container_low) == 0);
    try std.testing.expect(f2.countColorIn(.{ .x = 400, .y = 100, .w = 60, .h = 80 }, 0x112233FF) > 60 * 80 - 40);
}

test "golden: a closed drawer paints nothing past its bounds — no ghost over siblings" {
    const t = theme_mod.light;
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const bg: Color = 0x445566FF;
    const d = try drawer(std.testing.allocator, open, null, .{
        .theme = t,
        .body = try golden.solidBox(std.testing.allocator, 360, 200, 0x112233FF),
        .content = try text_w.text(std.testing.allocator, "Drawer", .{ .color = t.colors.on_surface }),
    });
    defer d.deinit();
    // The drawer lives in a bounded box inset from the frame's left edge:
    // the closed panel's translated pixels must never land left of the box.
    var r = try golden.Renderer.init(std.testing.allocator, 480, 200);
    defer r.deinit();
    d.layout(.{ .x = 120, .y = 0, .w = 360, .h = 200 });
    r.paint(d, bg);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const left = Rect{ .x = 0, .y = 0, .w = 120, .h = 200 };
    try std.testing.expectEqual(@as(u64, 0), f.countNotIn(left, bg));
}

test "drawer: i18n — the framework labels localize + re-resolve on a locale switch" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Navigation drawer\": \"Cajón de navegación\", \"Close drawer\": \"Cerrar cajón\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const open = try ui.state.Signal(bool).init(a, false);
    defer open.deinit();
    const d = try drawer(a, open, null, .{});
    defer d.deinit();
    const s = stateOf(d);
    try std.testing.expectEqualStrings("Cerrar cajón", s.scrim.semantics.?.label);
    try std.testing.expectEqualStrings("Cajón de navegación", s.panel.semantics.?.label);
    try i18n.setLocale("en");
    try std.testing.expectEqualStrings("Close drawer", s.scrim.semantics.?.label);
    try std.testing.expectEqualStrings("Navigation drawer", s.panel.semantics.?.label);
}
