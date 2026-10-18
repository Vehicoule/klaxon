// Menu (Phase 2d.3 PR D2, M3E) — the Material 3 Expressive dropdown menu:
// an anchor + a popup panel of item rows, opened/closed by a signal, with
// hover/pressed/highlight state layers and keyboard navigation.
//
// Spec: m3.material.io/components/menus + Compose Menu.kt / MenuDefaults.kt /
// MenuTokens (the M3E menu item IS a list item with menu colors):
//   - panel: SurfaceContainer, radius 4 (CornerExtraSmall), vertical padding
//     8 (DropdownMenuVerticalPadding); flat in v1 (Level2 — Phase 3)
//   - item rows: height 48 (MenuListItemContainerHeight), horizontal padding
//     12 (DropdownMenuItemHorizontalPadding), leading icon 24dp at x=12 +
//     16dp to the label (LeadingContentEndPadding), trailing text (label_small)
//     8dp before the end padding; label body_large
//   - colors: label OnSurface; the leading icon OnSecondaryContainer (the
//     menu quirk — MenuListItemLeadingIconColor); trailing text
//     OnSurfaceVariant; the state layer = on_surface @ hover 0.08 /
//     focus 0.10 / pressed 0.12 over the panel; disabled items OnSurface@0.38
//   - position: below the anchor, start-aligned, intrinsic width (the widest
//     item), clamped to the window width (a long label stays onscreen)
//
// Indication (Menu.kt:2155-2160): each item row is upstream's
// `Modifier.clickable(interactionSource, indication = ripple(true))` — a
// bounded ripple clipped to the row rect + the animated state layer, fed
// by the row's own interactions.Tracker. The keyboard highlight maps to a
// focus interaction (upstream items take real focus); Enter on the
// highlighted row presses at its center.
//
// The menu is a wrapper: the anchor is a document child (it sizes the menu);
// the item rows are internal chrome overlaying below the anchor (the P0
// dropdown pattern: hidden children + the router's open-popup barrier closes
// the menu on an outside click). On open the menu takes the keyboard focus
// (arrow/enter/escape navigation); on close the focus returns to the anchor.
// The panel + rows paint in the popup OVERLAY pass (the host paints the open
// popup after the tree): the panel overflows below the anchor into later
// siblings' territory and must render above them (the rows are defer_paint
// children — they never paint in the normal children pass).
//
// v1 deviations (documented, fixed later):
//   - Flat panel (no Level2 shadow — Phase 3); no submenus, no checkable
//     items, no group labels/dividers; no scroll for long menus; no M3E shape
//     morph. RTL mirrors the panel and the item rows (the text runs stay LTR
//     — no bidi, same as text.zig).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const anim = ui.anim;
const input = @import("../ui/input.zig");
const i18n_mod = @import("../ui/i18n.zig");
const theme_mod = @import("../theme.zig");
const icon_w = @import("icon.zig");
const layout_w = @import("layout.zig"); // tests
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

/// A menu item (the factory copies the strings).
pub const MenuItem = struct {
    label: []const u8,
    leading_icon: ?icon_w.IconName = null,
    trailing_text: []const u8 = "",
    enabled: bool = true,
};

pub const MenuOptions = struct {
    theme: Theme = theme_mod.light,
};

/// M3E tokens (MenuTokens + Menu.kt/MenuDefaults.kt).
const item_h: f32 = 48; // MenuListItemContainerHeight
const item_h_pad: f32 = 12; // DropdownMenuItemHorizontalPadding
const icon_size: f32 = 24;
const icon_gap: f32 = 12; // icon→label (DropdownMenuItemHorizontalPadding, icon present)
const trail_gap: f32 = 12; // label→trailing (DropdownMenuItemHorizontalPadding, trailing present)
const item_min_w: f32 = 112; // DropdownMenuItemDefaultMinWidth
const item_max_w: f32 = 280; // DropdownMenuItemDefaultMaxWidth
const menu_h_margin: f32 = 8; // MenuHorizontalMargin — min inset to the window edge
const menu_v_margin: f32 = 48; // MenuVerticalMargin — fit margin top/bottom
const panel_v_pad: f32 = 8; // DropdownMenuVerticalPadding
const panel_radius: f32 = 4; // CornerExtraSmall
// The open anim (scale 0.8→1 + alpha 0→1, Menu.kt) rides
// theme.motion.durations.short3 (150ms).

const ItemDef = struct {
    label: [:0]const u8, // owned
    leading_icon: ?icon_w.IconName,
    trailing_text: [:0]const u8, // owned
    enabled: bool,
};

const MenuState = struct {
    items: std.array_list.Managed(ItemDef), // owned defs
    anchor: *Node, // the anchor child (document data — sizes the menu)
    opts: MenuOptions,
    sig: ?*ui.state.Signal(bool) = null,
    on_select: ?Callback = null,
    open: bool = false,
    /// The hovered/highlighted item (-1 = none; keyboard nav moves it too).
    /// Maps to a focus interaction on the highlighted row's tracker
    /// (upstream rows take real focus).
    highlight: i32 = -1,
    /// The last selected index (pub accessor `selectedIndex`).
    selected: usize = 0,
    /// Open/close animation progress: 0..1 lerps scale 0.8→1 and alpha
    /// (upstream ExpandedScaleTarget/ClosedScaleTarget).
    open_progress: f32 = 0,
    open_target: f32 = 0,
    open_channel: u8 = 0, // channel marker (stable address)
    /// The laid-out panel rect (overlay pass + flips when it would overflow).
    panel: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    i18n: ?*i18n_mod.I18n = null,
};

fn stateOf(n: *Node) *MenuState {
    return @ptrCast(@alignCast(n.state.?));
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

/// The panel width: the widest item's content + paddings, clamped to the
/// upstream item band [DropdownMenuItemDefaultMinWidth 112,
/// DropdownMenuItemDefaultMaxWidth 280].
fn panelWidth(s: *MenuState, t: Theme) f32 {
    var w: f32 = 0;
    for (s.items.items) |def| {
        var cw = item_h_pad * 2 + ui.paint.measureTextStyled(def.label, t.type_scale.label_large.size, t.type_scale.label_large.weight, t.type_scale.label_large.letter_spacing).width;
        if (def.leading_icon != null) cw += icon_size + icon_gap;
        if (def.trailing_text.len > 0) cw += trail_gap + ui.paint.measureTextStyled(def.trailing_text, t.type_scale.label_small.size, t.type_scale.label_small.weight, t.type_scale.label_small.letter_spacing).width;
        w = @max(w, cw);
    }
    return @min(@max(w, item_min_w), item_max_w);
}

/// The panel width clamped to the window (MenuHorizontalMargin 8 from the
/// screen edge): a long label must not push the panel offscreen. The
/// available width runs from the panel's start edge to the root's end
/// (RTL: the window's start to the panel's end edge). A standalone menu
/// (no parent — tests/goldens) is unclamped.
fn panelWidthFit(n: *Node, s: *MenuState, t: Theme, bounds: Rect) f32 {
    const pw = panelWidth(s, t);
    const parent = n.parent orelse return pw;
    var root = parent;
    while (root.parent) |p| root = p;
    const rtl = ui.i18n.direction() == .rtl;
    const px = if (rtl) bounds.x + bounds.w - pw else bounds.x;
    const avail = if (rtl) px - root.bounds.x else root.bounds.x + root.bounds.w - px;
    return @min(pw, @max(avail - menu_h_margin, 0));
}

/// Damage covers the anchor AND the item rows: the panel paints below the
/// menu's bounds (overflow), so the dirty-rect clip must include it for the
/// panel to appear (open) and disappear (close).
fn markMenuDirty(n: *Node) void {
    var region = n.bounds;
    for (n.children.items) |child| region = ui.node.rectUnion(region, child.bounds);
    n.markDirtyRect(region);
}

/// Drive the open animation (scale+alpha); snaps without a timeline.
fn retargetOpen(n: *Node, s: *MenuState, target: f32) void {
    if (target == s.open_target) return;
    s.open_target = target;
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.tweenAnim(.{ target, 0, 0, 0 }, s.opts.theme.motion.durations.short3, .{ .ease = .standard }),
            .from = .{ s.open_progress, 0, 0, 0 },
            .channel = @ptrCast(&s.open_channel),
            .on_update = .{ .fn_ptr = openAnimCb, .userdata = n },
            .on_complete = .{ .fn_ptr = openDoneCb, .userdata = n },
        });
    } else {
        s.open_progress = target;
        if (target == 0) hideRows(n, s);
        markMenuDirty(n);
    }
}

fn openAnimCb(userdata: ?*anyopaque, v: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).open_progress = v[0];
    markMenuDirty(n);
}

fn openDoneCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.open_target == 0) hideRows(n, s); // faded out: drop the rows
}

fn hideRows(n: *Node, s: *MenuState) void {
    _ = s;
    for (n.children.items[1..]) |child| child.setVisible(false);
}

/// Apply the open state (the single transition path — the signal and the
/// programmatic setOpen both land here).
fn applyOpen(n: *Node, s: *MenuState, open: bool) void {
    if (s.open == open) return;
    s.open = open;
    if (open) for (n.children.items[1..]) |child| child.setVisible(true); // fade in from 0
    s.highlight = -1;
    // The interaction set dies with the open state (upstream's per-item
    // MutableInteractionSource lives in the composed row): a close
    // mid-press, or a reopen, never inherits a stale press/hover.
    for (n.children.items[1..]) |child| {
        const is_ = itemStateOf(child);
        is_.inter.clear();
        is_.press_id = 0;
        is_.ripples.releaseAll(0);
    }
    markMenuDirty(n);
    if (open) {
        input.setOpenPopup(n); // the router's barrier closes on outside clicks
        input.requestFocus(n); // keyboard focus while open (arrow/enter/escape)
    } else {
        input.setOpenPopup(null);
        // M3: dismiss returns the focus to the invoker (the anchor). The
        // anchor lives and dies with the menu — restoring it can never
        // dangle across a tree rebuild (unlike a captured prev focus).
        input.requestFocus(s.anchor);
    }
    retargetOpen(n, s, if (open) 1 else 0);
}

fn menuSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    applyOpen(n, s, s.sig.?.peek());
}

/// Open/close the menu (the pub API without a signal; with one, this sets
/// the signal — the sync callback applies the transition).
pub fn setOpen(n: *Node, open: bool) void {
    const s = stateOf(n);
    if (s.sig) |sig| {
        sig.set(open);
    } else {
        applyOpen(n, s, open);
    }
}

pub fn isOpen(n: *Node) bool {
    return stateOf(n).open;
}

/// The last selected item's index (valid after a selection).
pub fn selectedIndex(n: *Node) usize {
    return stateOf(n).selected;
}

fn menuSelect(owner: *Node, index: usize) void {
    const s = stateOf(owner);
    if (index >= s.items.items.len) return;
    if (!s.items.items[index].enabled) return;
    s.selected = index;
    if (owner.semantics) |sem| {
        sem.value = s.items.items[index].label; // a11y: the value follows the selection
        ui.semantics.notifyControlChanged(owner);
    }
    setOpen(owner, false);
    if (s.on_select) |cb| cb.fn_ptr(cb.userdata);
}

// --- menu item row (internal chrome child) ---

const ItemState = struct {
    def_index: usize,
    owner: *Node,
    /// The shared indication machinery (upstream's clickable
    /// interactionSource + ripple(true) indication): the ordered
    /// interaction set, the animated state layer, the bounded ink ripples.
    inter: ui.interactions.Tracker = .{},
    layer: ui.state_layer.StateLayer = .{},
    ripples: ui.ripple.Ripples = .{},
    press_id: u32 = 0, // the live press's tracker id (0 = none)
};

fn itemStateOf(n: *Node) *ItemState {
    return @ptrCast(@alignCast(n.state.?));
}

fn itemMeasure(n: *Node, c: Constraints) Size {
    const s = itemStateOf(n);
    const ms = stateOf(s.owner);
    const t = ms.opts.theme;
    const def = ms.items.items[s.def_index];
    var w = item_h_pad * 2 + ui.paint.measureTextStyled(def.label, t.type_scale.label_large.size, t.type_scale.label_large.weight, t.type_scale.label_large.letter_spacing).width;
    if (def.leading_icon != null) w += icon_size + icon_gap;
    if (def.trailing_text.len > 0) w += trail_gap + ui.paint.measureTextStyled(def.trailing_text, t.type_scale.label_small.size, t.type_scale.label_small.weight, t.type_scale.label_small.letter_spacing).width;
    return c.constrain(.{ .w = @min(@max(w, item_min_w), item_max_w), .h = item_h });
}

fn itemLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf
}

/// Paint an icon glyph centered in a 24x24 box.
fn paintIcon(ctx: *kx.Ctx, name: ?icon_w.IconName, x: f32, y: f32, color: Color) void {
    const iname = name orelse return;
    if (color & 0xFF == 0) return;
    icon_w.drawIcon(ctx, iname, x, y, icon_size / 24.0, color);
}

fn itemPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = itemStateOf(n);
    const ms = stateOf(s.owner);
    const t = ms.opts.theme;
    const cs = t.colors;
    const def = ms.items.items[s.def_index];
    const b = n.bounds;
    const rtl = ui.i18n.direction() == .rtl;
    const mx = struct {
        fn f(bx: f32, bw: f32, x: f32, w: f32, rtl_flag: bool) f32 {
            return if (rtl_flag) bx + bw - (x - bx) - w else x;
        }
    }.f;
    const label_col = if (def.enabled) cs.on_surface else ui.paint.withAlphaScaled(cs.on_surface, 0.38);
    const icon_col = if (def.enabled) cs.on_secondary_container else ui.paint.withAlphaScaled(cs.on_surface, 0.38);
    const trail_col = if (def.enabled) cs.on_surface_variant else ui.paint.withAlphaScaled(cs.on_surface, 0.38);
    // the indication (enabled only): the keyboard/hover highlight maps to
    // a focus interaction (upstream rows take real focus — the row lights
    // at the focus alpha while the open menu holds the keyboard focus);
    // then the animated state layer + the bounded ink ripple over the row.
    if (def.enabled) {
        s.inter.setFocused(ms.highlight == @as(i32, @intCast(s.def_index)) and input.isFocused(s.owner));
        s.layer.sync(&s.inter, cs.on_surface);
        if (s.layer.paintColor()) |lc| {
            ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, lc);
        }
        s.ripples.paint(ctx, n, .rect);
    }
    // the label (vertically centered, upstream ProvideTextStyle labelLarge)
    const lm = ui.paint.measureTextStyled(def.label, t.type_scale.label_large.size, t.type_scale.label_large.weight, t.type_scale.label_large.letter_spacing);
    const label_x = b.x + item_h_pad + (if (def.leading_icon != null) icon_size + icon_gap else 0);
    const label_y = b.y + (b.h - lm.height) / 2 + lm.ascent;
    ui.paint.textStyled(ctx, def.label, mx(b.x, b.w, label_x, lm.width, rtl), label_y, t.type_scale.label_large.size, t.type_scale.label_large.weight, t.type_scale.label_large.letter_spacing, label_col);
    // the leading icon (start side, vertically centered)
    if (def.leading_icon) |iname| {
        const ix = mx(b.x, b.w, b.x + item_h_pad, icon_size, rtl);
        paintIcon(ctx, iname, ix, b.y + (b.h - icon_size) / 2, icon_col);
    }
    // the trailing text (end side, vertically centered)
    if (def.trailing_text.len > 0) {
        const tm = ui.paint.measureTextStyled(def.trailing_text, t.type_scale.label_small.size, t.type_scale.label_small.weight, t.type_scale.label_small.letter_spacing);
        const ty = b.y + (b.h - tm.height) / 2 + tm.ascent;
        const tx = mx(b.x, b.w, b.x + b.w - item_h_pad - tm.width, tm.width, rtl);
        ui.paint.textStyled(ctx, def.trailing_text, tx, ty, t.type_scale.label_small.size, t.type_scale.label_small.weight, t.type_scale.label_small.letter_spacing, trail_col);
    }
}

/// End the row's live press (release = up, cancel = drag-off/outside) —
/// the tracker entry and its ripple pair on `press_id`.
fn itemEndPress(s: *ItemState, now_ms: u64, cancel: bool) void {
    if (s.press_id == 0) return;
    if (cancel) s.inter.cancel(s.press_id) else s.inter.release(s.press_id);
    s.ripples.release(s.press_id, now_ms);
    s.press_id = 0;
}

fn itemOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = itemStateOf(n);
    const ms = stateOf(s.owner);
    const def = ms.items.items[s.def_index];
    if (!def.enabled) return false;
    const idx: i32 = @intCast(s.def_index);
    switch (ev.phase) {
        .enter => {
            _ = s.inter.hoverEnter();
            ms.highlight = idx;
            markMenuDirty(s.owner);
            return true;
        },
        .leave => {
            s.inter.endHover();
            if (ms.highlight == idx) ms.highlight = -1;
            markMenuDirty(s.owner);
            return true;
        },
        .down => {
            if (s.press_id != 0) itemEndPress(s, ev.time_ms, true); // a second pointer supersedes
            s.press_id = s.inter.pressDown(ev.x, ev.y);
            s.ripples.spawn(s.press_id, ev.x, ev.y, ev.time_ms);
            markMenuDirty(s.owner);
            return true;
        },
        .up => {
            const was = s.press_id != 0;
            itemEndPress(s, ev.time_ms, false);
            if (was and n.bounds.contains(ev.x, ev.y)) {
                menuSelect(s.owner, s.def_index);
            } else {
                markMenuDirty(s.owner);
            }
            return true;
        },
        .move => {
            // upstream clickable cancels the press when the pointer leaves
            // the row — the move itself keeps bubbling (not claimed)
            if (s.press_id != 0 and !n.bounds.contains(ev.x, ev.y)) {
                itemEndPress(s, ev.time_ms, true);
                markMenuDirty(s.owner);
            }
            return false;
        },
        .outside_down => {
            itemEndPress(s, ev.time_ms, true);
            return false; // the owner's outside_down closes the menu
        },
        else => {},
    }
    return false;
}

fn itemDeinit(n: *Node) void {
    const s = itemStateOf(n);
    s.layer.deinit(); // in-flight tween userdata = `l`
    s.ripples.deinit(); // the live ticker userdata = `r`
    n.allocator.destroy(s);
}

const item_vtable = ui.node.VTable{
    .measure = itemMeasure,
    .layout = itemLayout,
    .paint = itemPaint,
    .deinit = itemDeinit,
    .on_pointer = itemOnPointer,
};

// --- the menu widget ---

fn menuMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    return s.anchor.measure(c); // the items are overlay chrome (not measured)
}

/// The panel rect: upstream `DropdownMenuPositionProvider` (MenuAnchorPosition
/// .Below) tries candidates in order and takes the first that fits the window
/// (with margins); the last is unconditional.
///   x: startToAnchorStart → endToAnchorEnd → window edge (by anchor half)
///   y: topToAnchorBottom → bottomToAnchorTop → centerToAnchorTop → window edge
/// A standalone menu (no parent — tests/goldens) always opens below.
fn panelRect(n: *Node, s: *MenuState, t: Theme, b: Rect) Rect {
    const pw = panelWidthFit(n, s, t, b);
    const ph = panel_v_pad * 2 + @as(f32, @floatFromInt(s.items.items.len)) * item_h;
    const rtl = ui.i18n.direction() == .rtl;
    var root: ?*Node = null;
    if (n.parent) |p| {
        var r = p;
        while (r.parent) |pp| r = pp;
        root = r;
    }
    const win = if (root) |r| r.bounds else return .{
        .x = if (rtl) b.x + b.w - pw else b.x,
        .y = b.y + b.h,
        .w = pw,
        .h = ph,
    };
    // x candidates — RTL resolves start/end to the opposite edges.
    const x_start = if (rtl) b.x + b.w - pw else b.x;
    const x_end = if (rtl) b.x else b.x + b.w - pw;
    const x_win = if (b.x + b.w / 2 < win.x + win.w / 2)
        win.x + menu_h_margin
    else
        win.x + win.w - menu_h_margin - pw;
    const xs = [3]f32{ x_start, x_end, x_win };
    var px = x_win;
    for (xs, 0..) |cx, i| {
        if (i == xs.len - 1 or (cx >= win.x and cx + pw <= win.x + win.w)) {
            px = cx;
            break;
        }
    }
    // y candidates: below → above → centered on the anchor's top edge →
    // window-aligned, gated on the MenuVerticalMargin fit band.
    const y_win = if (b.y + b.h / 2 < win.y + win.h / 2)
        win.y + menu_v_margin
    else
        win.y + win.h - menu_v_margin - ph;
    const ys = [4]f32{ b.y + b.h, b.y - ph, b.y - ph / 2, y_win };
    var py = y_win;
    for (ys, 0..) |cy, i| {
        if (i == ys.len - 1 or (cy >= win.y + menu_v_margin and cy + ph <= win.y + win.h - menu_v_margin)) {
            py = cy;
            break;
        }
    }
    return .{ .x = px, .y = py, .w = pw, .h = ph };
}

fn menuLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    // the anchor fills the menu's bounds (the menu sizes to the anchor)
    s.anchor.layout(bounds);
    // the panel overlays relative to the anchor (positioned by panelRect —
    // flips above when below would overflow), items fill its interior
    s.panel = panelRect(n, s, t, bounds);
    for (n.children.items[1..], 0..) |child, i| {
        child.layout(.{
            .x = s.panel.x,
            .y = s.panel.y + panel_v_pad + @as(f32, @floatFromInt(i)) * item_h,
            .w = s.panel.w,
            .h = item_h,
        });
    }
}

fn menuPaint(n: *Node, ctx: *kx.Ctx) void {
    // Nothing here: the panel + item rows paint in the popup OVERLAY pass
    // (paint_overlay) — the panel overflows below the anchor into later
    // siblings' territory and must render above them. The anchor child
    // paints itself in the normal pass.
    _ = n;
    _ = ctx;
}

/// Upstream calculateTransformOrigin: the scale pivot = the horizontal
/// center of the anchor∩panel intersection (0/1 when disjoint); a
/// below-anchor menu pivots on its top edge.
fn transformOriginX(b: Rect, px: f32, pw: f32) f32 {
    if (px >= b.x + b.w) return px; // panel starts at the anchor's end
    if (px + pw <= b.x) return px + pw;
    const lo = @max(b.x, px);
    const hi = @min(b.x + b.w, px + pw);
    return (lo + hi) / 2;
}

/// The popup overlay pass (the host paints the open popup after the tree):
/// the panel + the visible item rows, above any later sibling.
fn menuPaintOverlay(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    if (!s.open and s.open_progress <= 0) return;
    const t = s.opts.theme;
    const b = n.bounds;
    const panel = s.panel;
    // the open animation: scale 0.8→1 from the anchor's overlap center +
    // fade 0→1 (upstream ExpandedScaleTarget/ExpandedAlphaTarget). The
    // vertical pivot is the panel edge toward the anchor — top below,
    // bottom when flipped, the overlap midpoint when they intersect.
    const p = std.math.clamp(s.open_progress, 0, 1);
    const sc = 0.8 + 0.2 * p;
    const ox = transformOriginX(b, panel.x, panel.w);
    const oy = if (panel.y >= b.y + b.h)
        panel.y
    else if (panel.y + panel.h <= b.y)
        panel.y + panel.h
    else
        (@max(b.y, panel.y) + @min(b.y + b.h, panel.y + panel.h)) / 2;
    ui.paint.save(ctx);
    ui.paint.translate(ctx, ox, oy);
    ui.paint.scale(ctx, sc, sc);
    ui.paint.translate(ctx, -ox, -oy);
    ui.paint.layerAlpha(ctx, p);
    // M3 menu elevation = 2dp.
    ui.paint.elevationShadow(ctx, panel.x, panel.y, panel.w, panel.h, panel_radius, 2, t.colors.shadow);
    ui.paint.fillRRect(ctx, panel.x, panel.y, panel.w, panel.h, panel_radius, t.colors.surface_container);
    for (n.children.items[1..]) |child| { // [0] = the anchor
        if (child.visible) itemPaint(child, ctx);
    }
    ui.paint.restore(ctx); // layer alpha
    ui.paint.restore(ctx); // own save
}

fn menuOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (ev.phase == .outside_down and s.open) {
        setOpen(n, false); // the router's barrier sends this on outside clicks
        return true;
    }
    return false;
}

/// Keyboard navigation while open: up/down move the highlight (skipping
/// disabled items), Enter selects it, Escape closes.
fn menuOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.open) return false;
    if (ev.kind != .key_down) return false;
    const count: i32 = @intCast(s.items.items.len);
    switch (ev.key) {
        .up, .down => {
            if (count == 0) return true;
            const step: i32 = if (ev.key == .down) 1 else -1;
            var i: i32 = if (s.highlight < 0) (if (step > 0) -1 else count) else s.highlight;
            var guard: i32 = 0;
            while (guard < count) : (guard += 1) {
                i = @mod(i + step, count);
                if (s.items.items[@intCast(i)].enabled) break;
            }
            s.highlight = i;
            markMenuDirty(n);
            return true;
        },
        .enter => {
            if (s.highlight >= 0) {
                const hi: usize = @intCast(s.highlight);
                // A key press lands at the row's center (upstream's
                // keyboard press position = the component center); the
                // ripple releases immediately but still runs its full
                // expand + fade-out.
                if (hi < s.items.items.len) {
                    const row = n.children.items[1 + hi];
                    const is_ = itemStateOf(row);
                    const cx = row.bounds.x + row.bounds.w / 2;
                    const cy = row.bounds.y + row.bounds.h / 2;
                    const pid = is_.inter.pressDown(cx, cy);
                    is_.ripples.spawn(pid, cx, cy, 0);
                    is_.inter.release(pid);
                    is_.ripples.release(pid, 0);
                }
                menuSelect(n, hi);
            }
            return true;
        },
        .escape => {
            setOpen(n, false);
            return true;
        },
        else => {},
    }
    return false;
}

fn menuDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.open_channel));
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = menuSyncCb, .userdata = n } });
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = menuLocaleCb, .userdata = n });
    // Node.deinit calls input.releaseNode(n) FIRST: it clears the router's
    // open_popup only when it still points to THIS node. No unconditional
    // setOpenPopup(null) here — a rebuild replaces an open menu with a new
    // one (which re-registers); clearing unconditionally would strip the new
    // menu's popup registration (outside-click dismissal + overlay hit-test).
    input.releaseNode(n);
    for (s.items.items) |*def| {
        n.allocator.free(def.label);
        n.allocator.free(def.trailing_text);
    }
    s.items.deinit();
    n.allocator.destroy(s);
}

/// The a11y label is tr()-resolved — the locale callback re-attaches in
/// the new locale.
fn attachMenuSemantics(n: *Node) void {
    const s = stateOf(n);
    ui.semantics.attach(n, .{
        .role = .menu,
        .label = i18n_mod.tr("Menu"),
        .focusable = true, // takes the keyboard focus while open
        .value = if (s.items.items.len > 0) s.items.items[0].label else "",
    });
}

fn menuLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    attachMenuSemantics(n);
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

const menu_vtable = ui.node.VTable{
    .measure = menuMeasure,
    .layout = menuLayout,
    .paint = menuPaint,
    .paint_overlay = menuPaintOverlay,
    .deinit = menuDeinit,
    .on_pointer = menuOnPointer,
    .on_key = menuOnKey,
};

/// An M3E dropdown menu. `anchor` is a document child (it sizes the menu and
/// keeps its own interaction — the app opens the menu via the signal or
/// `setOpen`). `items` are copied (the labels/texts are owned). `sig` drives
/// the open state (round-trips); `on_select` fires with `selectedIndex(n)`
/// valid. The item rows are internal chrome (skip_children for the registry).
pub fn menu(allocator: std.mem.Allocator, anchor: *Node, items: []const MenuItem, sig: ?*ui.state.Signal(bool), on_select: ?Callback, opts: MenuOptions) !*Node {
    const node = try Node.create(allocator, &menu_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(MenuState);
    errdefer allocator.destroy(s);
    s.* = .{
        .items = std.array_list.Managed(ItemDef).init(allocator),
        .anchor = anchor,
        .opts = opts,
        .sig = sig,
        .on_select = on_select,
    };
    // One ownership boundary: on ANY failure below, this errdefer frees the
    // appended defs' strings (menuDeinit owns them only once the node is
    // returned to the caller).
    errdefer {
        for (s.items.items) |*def| {
            allocator.free(def.label);
            allocator.free(def.trailing_text);
        }
        s.items.deinit();
    }
    for (items) |item| {
        const label = try dupeZ(allocator, item.label);
        errdefer allocator.free(label); // iteration scope: runs only if THIS iteration fails before the append
        const trailing = try dupeZ(allocator, item.trailing_text);
        errdefer allocator.free(trailing);
        // No catch-free here: on append failure the iteration errdefers free
        // the unappended copies (the outer errdefer owns the appended ones).
        try s.items.append(.{
            .label = label,
            .leading_icon = item.leading_icon,
            .trailing_text = trailing,
            .enabled = item.enabled,
        });
    }
    node.state = s;
    // The item rows (internal chrome, hidden until open): created UNATTACHED
    // — on failure the errdefer deinits exactly the rows created so far.
    const rows = try allocator.alloc(*Node, s.items.items.len);
    var row_count: usize = 0;
    errdefer {
        for (rows[0..row_count]) |rn| rn.deinit(); // unattached: frees the row + its state
        allocator.free(rows);
    }
    for (0..s.items.items.len) |i| {
        const item_node = try Node.create(allocator, &item_vtable);
        errdefer item_node.allocator.destroy(item_node); // no state yet
        const is = try allocator.create(ItemState);
        errdefer allocator.destroy(is);
        is.* = .{ .def_index = i, .owner = node };
        item_node.state = is;
        // The indication machinery: mutations + ticks damage the row node;
        // the layer alpha table + the ripple ink come from the theme (the
        // row's contentColor is OnSurface).
        const mt = opts.theme;
        is.inter.node = item_node;
        is.layer.node = item_node;
        is.layer.alphas = .{ .hover = mt.state.hover, .focus = mt.state.focus, .pressed = mt.state.pressed, .drag = mt.state.drag };
        is.ripples.node = item_node;
        is.ripples.color = mt.colors.on_surface;
        is.ripples.pressed_alpha = mt.state.pressed;
        item_node.setVisible(false);
        item_node.internal = true; // chrome: never serialized
        // NOT exclude_semantics: each row carries its own .menu_item
        // semantics — VoiceOver navigates/activates items individually
        // (item bounds are laid out at their overlay position). Closed
        // items are !visible → the flatten drops them automatically.
        item_node.defer_paint = true; // the rows paint in the popup overlay pass
        ui.semantics.attach(item_node, .{
            .role = .menu_item,
            .label = s.items.items[i].label,
            .disabled = !s.items.items[i].enabled,
            .actions = ui.semantics.Actions.initOne(.activate),
        });
        rows[row_count] = item_node;
        row_count += 1;
    }
    // Everything fallible has succeeded — attach (Node.add is infallible).
    // The anchor FIRST (children[0] — it sizes the menu; the rows follow at
    // children[1..]). The anchor stays caller-owned until here: on any
    // failure above, the caller's errdefer still owns it (no double
    // ownership). It is slot-owned (the registry round-trips it through the
    // "anchor" option — document children never serialize for this widget),
    // so it is marked internal like the item rows: child-walking serializers
    // must not see it as document data. No effect on hit-testing, painting
    // or semantics — the anchor stays fully interactive.
    anchor.internal = true;
    node.add(anchor);
    for (rows) |item_node| node.add(item_node);
    allocator.free(rows);
    attachMenuSemantics(node); // Phase 2c
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = menuLocaleCb, .userdata = node });
    if (sig) |sg| {
        sg.subscribe(.{ .callback = .{ .fn_ptr = menuSyncCb, .userdata = node } });
        if (sg.peek()) applyOpen(node, s, true); // starts open
    }
    return node;
}

// --- tests ---

fn selectCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

fn anchorBox(allocator: std.mem.Allocator, w: f32, h: f32) !*Node {
    return golden.solidBox(allocator, w, h, 0x888888FF);
}

test "menu: measures like the anchor; lays the panel out below it (start-aligned)" {
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{ .{ .label = "Copy" }, .{ .label = "Paste", .leading_icon = .star }, .{ .label = "Delete", .trailing_text = "Del" } }, null, null, .{});
    defer m.deinit();
    const sz = m.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(@as(f32, 120), sz.w);
    try std.testing.expectEqual(@as(f32, 40), sz.h);
    m.layout(.{ .x = 100, .y = 200, .w = 120, .h = 40 });
    // the anchor fills the menu's bounds
    try std.testing.expectEqual(@as(f32, 100), anchor.bounds.x);
    try std.testing.expectEqual(@as(f32, 200), anchor.bounds.y);
    // the panel: below the anchor + 8dp vertical padding, intrinsic width
    const item0 = m.children.items[1];
    try std.testing.expectEqual(@as(f32, 100), item0.bounds.x);
    try std.testing.expectEqual(@as(f32, 200 + 40 + 8), item0.bounds.y);
    try std.testing.expectEqual(item_h, item0.bounds.h);
    const item1 = m.children.items[2];
    try std.testing.expectEqual(@as(f32, 200 + 40 + 8 + 48), item1.bounds.y);
    // the panel width = the widest item (icon + label + trailing text),
    // clamped to the upstream [112, 280] item band
    const t = theme_mod.light;
    const ls = t.type_scale.label_large;
    const ts = t.type_scale.label_small;
    const w_copy = item_h_pad * 2 + ui.paint.measureTextStyled("Copy", ls.size, ls.weight, ls.letter_spacing).width;
    const w_paste = item_h_pad * 2 + icon_size + icon_gap + ui.paint.measureTextStyled("Paste", ls.size, ls.weight, ls.letter_spacing).width;
    const w_delete = item_h_pad * 2 + ui.paint.measureTextStyled("Delete", ls.size, ls.weight, ls.letter_spacing).width + trail_gap + ui.paint.measureTextStyled("Del", ts.size, ts.weight, ts.letter_spacing).width;
    const expect_w = @min(@max(@max(w_copy, @max(w_paste, w_delete)), item_min_w), item_max_w);
    try std.testing.expectApproxEqAbs(expect_w, item0.bounds.w, 0.001);
}

test "menu: open/close via the signal; item click selects + closes; keyboard nav" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = selectCounterCb, .userdata = &count };
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{ .{ .label = "Copy" }, .{ .label = "Cut", .enabled = false }, .{ .label = "Paste" } }, sig, cb, .{});
    defer m.deinit();
    m.layout(.{ .x = 0, .y = 0, .w = 120, .h = 40 });
    try std.testing.expect(!isOpen(m));
    try std.testing.expect(!m.children.items[1].visible);
    // open via the signal
    sig.set(true);
    try std.testing.expect(isOpen(m));
    try std.testing.expect(m.children.items[1].visible);
    try std.testing.expect(input.isFocused(m)); // took the keyboard focus
    // keyboard: down skips the disabled item, enter selects it
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(m)); // "Paste" (index 1 skipped)
    try std.testing.expect(!isOpen(m)); // closed after the selection
    try std.testing.expect(!input.isFocused(m));
    try std.testing.expect(input.isFocused(anchor)); // the focus returns to the anchor (the invoker)
    try std.testing.expectEqualStrings("Paste", m.semantics.?.value); // a11y follows
    // pointer: open, hover highlights, click selects (the item row is at
    // y = 40 + 8 = 48..96 — the click lands inside its bounds)
    sig.set(true);
    const item0 = m.children.items[1];
    _ = item0.vtable.on_pointer.?(item0, .{ .phase = .enter, .x = 10, .y = 58 });
    try std.testing.expectEqual(@as(i32, 0), stateOf(m).highlight);
    _ = item0.vtable.on_pointer.?(item0, .{ .phase = .down, .x = 10, .y = 58, .raw_x = 10, .raw_y = 58 });
    _ = item0.vtable.on_pointer.?(item0, .{ .phase = .up, .x = 10, .y = 58, .raw_x = 10, .raw_y = 58 });
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(m));
    try std.testing.expect(!isOpen(m));
    // outside click closes (the router's barrier sends outside_down)
    sig.set(true);
    try std.testing.expect(isOpen(m));
    _ = m.vtable.on_pointer.?(m, .{ .phase = .outside_down, .x = 500, .y = 500 });
    try std.testing.expect(!isOpen(m));
    // escape closes
    sig.set(true);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .escape });
    try std.testing.expect(!isOpen(m));
}

test "menu: mouse hover over a row highlights it (the popup-aware hover)" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{ .{ .label = "Copy" }, .{ .label = "Paste" } }, null, null, .{});
    defer m.deinit();
    m.layout(.{ .x = 0, .y = 0, .w = 120, .h = 40 });
    setOpen(m, true);
    // the first item row is at y = 48..96 — OUTSIDE the menu's bounds (the
    // panel overflows): the router's hover must still hit it
    router.dispatchPointer(m, .{ .phase = .move, .x = 10, .y = 60 });
    try std.testing.expectEqual(@as(i32, 0), stateOf(m).highlight);
    // moving to the second row moves the highlight (leave + enter)
    router.dispatchPointer(m, .{ .phase = .move, .x = 10, .y = 60 + 48 });
    try std.testing.expectEqual(@as(i32, 1), stateOf(m).highlight);
}

test "menu: the panel width is clamped to the window (a long label stays onscreen)" {
    const a = std.testing.allocator;
    var buf: [300]u8 = undefined;
    @memset(&buf, 'a');
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{.{ .label = &buf }}, null, null, .{});
    const win = try layout_w.column(a, .{});
    win.add(m);
    defer win.deinit();
    win.layout(.{ .x = 0, .y = 0, .w = 200, .h = 400 });
    // the intrinsic width (clamped to 280 max) exceeds the window: the panel
    // is clamped to the width available from its start edge to the window's
    // end minus the upstream 8dp MenuHorizontalMargin
    const intrinsic = panelWidth(stateOf(m), theme_mod.light);
    const avail = 200 - m.bounds.x - menu_h_margin;
    try std.testing.expect(intrinsic > avail); // the label is really too wide
    const item0 = m.children.items[1];
    try std.testing.expectEqual(@min(intrinsic, avail), item0.bounds.w);
}

test "menu: semantics — role menu, focusable, value follows the selection" {
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{ .{ .label = "Copy" }, .{ .label = "Paste" } }, null, null, .{});
    defer m.deinit();
    try std.testing.expectEqual(ui.semantics.Role.menu, m.semantics.?.role);
    try std.testing.expect(m.semantics.?.focusable);
    try std.testing.expectEqualStrings("Copy", m.semantics.?.value);
}

test "golden: open menu paints the SurfaceContainer panel + item labels" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{ .{ .label = "Copy" }, .{ .label = "Paste", .leading_icon = .star } }, null, null, .{ .theme = t });
    defer m.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 260, 200);
    defer r.deinit();
    m.layout(.{ .x = 20, .y = 20, .w = 120, .h = 40 });
    setOpen(m, true);
    r.paint(m, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the panel: SurfaceContainer, its top at the anchor's bottom edge
    // (20 + 40 = 60; the 8dp vertical padding is inside the panel)
    try std.testing.expectEqual(t.colors.surface_container, f.pixelAt(80, 70));
    // the panel's rounded corner (radius 4): no container ink — the 2dp
    // elevation shadow may tint it but never with the panel color
    try std.testing.expect(f.pixelAt(20, 60) != t.colors.surface_container);
    // the first item's label ink (on_surface) in its row
    try std.testing.expect(f.countColorIn(.{ .x = 32, .y = 68 + 8 + 12, .w = 80, .h = 24 }, t.colors.on_surface) > 0);
    // the second item's leading icon ink (on_secondary_container — the menu quirk)
    try std.testing.expect(f.countColorIn(.{ .x = 32, .y = 68 + 8 + 48 + 12, .w = 24, .h = 24 }, t.colors.on_secondary_container) > 0);
}

test "golden: hovered menu item paints the on_surface state layer" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{.{ .label = "Copy" }}, null, null, .{ .theme = t });
    defer m.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 260, 200);
    defer r.deinit();
    m.layout(.{ .x = 20, .y = 20, .w = 120, .h = 40 });
    setOpen(m, true);
    const item0 = m.children.items[1];
    _ = item0.vtable.on_pointer.?(item0, .{ .phase = .enter, .x = 10, .y = 10 });
    r.paint(m, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the row (past the label ink): on_surface @ 0.08 over surface_container
    try golden.expectPixelApprox(f, 70, 68 + 8 + 24, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, t.state.hover), t.colors.surface_container));
}

test "golden: disabled menu item paints the OnSurface@0.38 label" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{.{ .label = "Copy", .enabled = false }}, null, null, .{ .theme = t });
    defer m.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 260, 200);
    defer r.deinit();
    m.layout(.{ .x = 20, .y = 20, .w = 120, .h = 40 });
    setOpen(m, true);
    r.paint(m, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the label ink: on_surface @ 0.38 over the panel
    const dis = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), t.colors.surface_container);
    try std.testing.expect(f.countColorIn(.{ .x = 32, .y = 68 + 8 + 12, .w = 80, .h = 24 }, dis) > 0);
}

test "golden: the open menu paints ABOVE a later sibling (the overlay pass)" {
    // The panel overflows below the anchor into the next sibling's territory:
    // the overlay pass must paint it over the sibling's opaque background.
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{ .{ .label = "Copy" }, .{ .label = "Paste" } }, null, null, .{ .theme = t });
    const cover = try golden.solidBox(a, 300, 200, 0xFF00FFFF); // opaque magenta
    const col = try layout_w.column(a, .{ .gap = 0 });
    const spacer = try golden.solidBox(a, 320, 60, 0xFFFFFFFF);
    col.add(spacer);
    col.add(m);
    col.add(cover);
    defer col.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 320, 320);
    defer r.deinit();
    col.layout(.{ .x = 0, .y = 0, .w = 320, .h = 320 });
    setOpen(m, true);
    r.paint(col, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the anchor paints in the normal pass (y = 60..100)
    try std.testing.expectEqual(@as(Color, 0x888888FF), f.pixelAt(60, 80));
    // the panel's top padding (y = 100..108) is NOT covered by the magenta box:
    // it paints in the overlay pass, above the later sibling
    try std.testing.expectEqual(t.colors.surface_container, f.pixelAt(30, 104));
    // below the panel (y > 100 + 8 + 96 + 8 = 212) the sibling shows through
    try std.testing.expectEqual(@as(Color, 0xFF00FFFF), f.pixelAt(30, 260));
}

test "menu: the panel flips above the anchor when below overflows the window" {
    // Upstream DropdownMenuPositionProvider: topToAnchorBottom →
    // bottomToAnchorTop → centerToAnchorTop → window edge, gated on the
    // 48dp MenuVerticalMargin fit band.
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{ .{ .label = "Copy" }, .{ .label = "Paste" } }, null, null, .{});
    const col = try layout_w.column(a, .{ .gap = 0 });
    col.add(m);
    defer col.deinit();
    // 260 window: below the anchor (y = 220) ends at 332 > 212 (260-48) →
    // flips above at y = 180 - 112 = 68 (inside the 48..212 margin band)
    col.layout(.{ .x = 0, .y = 0, .w = 320, .h = 260 });
    m.layout(.{ .x = 0, .y = 180, .w = 120, .h = 40 });
    const s = stateOf(m);
    try std.testing.expect(std.math.approxEqAbs(f32, 68, s.panel.y, 0.01));
    try std.testing.expect(std.math.approxEqAbs(f32, 112, s.panel.h, 0.01));
    // a mid-window anchor still opens below
    m.layout(.{ .x = 0, .y = 60, .w = 120, .h = 40 });
    try std.testing.expect(std.math.approxEqAbs(f32, 100, s.panel.y, 0.01));
    // an anchor flush with the window bottom can't satisfy either anchored
    // candidate → bottomToWindowBottom (panel bottom at window - margin)
    m.layout(.{ .x = 0, .y = 220, .w = 120, .h = 40 });
    try std.testing.expect(std.math.approxEqAbs(f32, 260 - menu_v_margin - 112, s.panel.y, 0.01));
}

test "menu: i18n — the framework label localizes + re-resolves on a locale switch" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Menu\": \"Menú\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{ .{ .label = "Copy" }, .{ .label = "Paste" } }, null, null, .{});
    defer m.deinit();
    try std.testing.expectEqualStrings("Menú", m.semantics.?.label);
    try i18n.setLocale("en");
    try std.testing.expectEqualStrings("Menu", m.semantics.?.label);
    // the item labels are app strings — untouched
    try std.testing.expectEqualStrings("Copy", m.semantics.?.value);
}
