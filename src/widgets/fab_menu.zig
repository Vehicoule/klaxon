// FAB menu (the M3E "speed dial", Phase 2d.5 follow-up) — a toggle FAB plus
// a column of secondary action items revealed above it, driven by an
// optional Signal(bool) or the widget's own open state.
//
// Spec: m3.material.io/components/fab-menu + Compose Material3
// FloatingActionButtonMenu.kt / ToggleFloatingActionButton.kt +
// FabMenuBaselineTokens / FabBaselineTokens / MenuTokens:
//   - the toggle FAB is the baseline FAB look (fab.zig): 56x56, CornerLarge
//     (16), PrimaryContainer fill + OnPrimaryContainer 24dp icon, elevation
//     level3 (6dp rest, 8dp hovered); the 48dp a11y floor applies to the
//     HIT target, never the painted container
//   - open morph (FabMenuBaselineTokens.CloseButton* + the toggle FAB's
//     checked state): the FAB becomes the 56dp CornerFull close button in
//     the family's solid pair (Primary / OnPrimary) with the close icon at
//     20dp (CloseButtonIconSize). v1 swaps the icon INSTANTLY — close_icon
//     when the caller gives one, else the fab_icon at the close size
//   - items: a vertical column END-aligned to the FAB (Compose's
//     horizontalAlignment = Alignment.End; RTL mirrors it to the start
//     edge). Each row is the spec's two-part item: a label chip
//     (SurfaceContainer fill, 12dp corner, 8dp horizontal padding, text
//     label_large on OnSurface) sitting at the button's START side +
//     a 48dp item button (12dp corner, TertiaryContainer fill,
//     OnTertiaryContainer icon at 24dp — ListItemIconSize). The rows stack
//     upward: item[0] at the top, the last row closest to the FAB.
//     8dp between rows, 8dp between the column and the FAB
//     (CloseButtonBetweenSpace), 8dp chip↔button (ListItemIconLabelSpace)
//   - state layers: the item content color over the container at hover
//     0.08 / focus 0.10 / pressed 0.12; disabled items = OnSurface@0.38
//     content over OnSurface@0.12 container (chip included)
//   - behavior: the FAB click/Enter/Space toggles; an open menu registers
//     as the router's open popup (like menu.zig — item hit-testing works
//     outside the FAB's bounds and an outside click closes via the
//     barrier's outside_down); Escape closes; up/down move the item
//     highlight (skipping disabled), Enter activates it. Activating an
//     item fires its on_press and closes the menu
//   - semantics: the node is a .toggle (checked = open) exposing the items
//     as .menu_item virtual children only while open (segmented_button's
//     children + child_bounds pattern — a targeted activation lands on the
//     item's rect and resolves like a tap)
//
// v1 deviations (documented, fixed later):
//   - No staggered expand/collapse animation (Compose runs a per-item
//     spring + fade — the column pops in; the morph is instant) — Phase 3.
//   - The item is the spec-page chip + 48dp button pair; the newest Compose
//     tokens instead fold icon + label into ONE 56dp CornerFull pill
//     (ListItemContainerShape, leading/trailing space 24). The split
//     version implemented here matches the documented v1 brief.
//   - No scroll for menus taller than the screen (Compose lazies + clips
//     the column); the column can overflow the window's TOP edge — the
//     caller positions the FAB with room above it.
//   - opts.scrim paints the M3 scrim @ 0.32 over the widget's OWN paint
//     extent only (FAB bounds + item column — behind the controls), not
//     the whole window; a true modal scrim needs the host/overlay layer.
//   - Keyboard: no Tab-into-the-column focus chain (Compose moves focus
//     into the item column on open) — the single focused node handles
//     arrows/enter/escape for the whole menu.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
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

/// A FAB-menu item (the factory copies the label). `on_press` fires on
/// activation (click, a11y activate, Enter on the highlight) — each item
/// carries its own callback; `enabled = false` dims it and swallows input.
pub const FabMenuItem = struct {
    icon: icon_w.IconName,
    label: []const u8,
    on_press: ?Callback = null,
    enabled: bool = true,
};

pub const FabMenuOptions = struct {
    /// The open state when the caller supplies one (round-trips — the
    /// widget reads it back through the sync subscription); null keeps the
    /// open state internal (setOpen still toggles it).
    open: ?*ui.state.Signal(bool) = null,
    /// Fires on every USER-driven open-state change: the FAB click/key,
    /// Escape, an outside tap, an item selection. Programmatic setOpen /
    /// signal writes do not re-fire it.
    on_toggle: ?Callback = null,
    /// The closed-state FAB icon (the spec's "+").
    fab_icon: icon_w.IconName = .plus,
    /// The open-state (close-button) icon. null = keep `fab_icon` — only
    /// the shape/color morph applies.
    close_icon: ?icon_w.IconName = null,
    enabled: bool = true,
    /// The FAB's accessible name (it is icon-only — no visible label).
    a11y_label: []const u8 = "",
    /// Dim the widget's own extent while open (see the header's v1 note).
    scrim: bool = false,
    theme: Theme = theme_mod.light,
};

/// M3E tokens (FabMenuBaselineTokens + FabBaselineTokens + MenuTokens; the
/// corner radii resolve through the theme's shape scale).
const fab_size: f32 = 56; // FabBaselineTokens.ContainerHeight (= CloseButton)
const fab_icon_size: f32 = 24; // FabBaselineTokens.IconSize
const close_icon_size: f32 = 20; // FabMenuBaselineTokens.CloseButtonIconSize
const item_size: f32 = 48; // item button (the spec page's mini target)
const item_icon_size: f32 = 24; // FabMenuBaselineTokens.ListItemIconSize
const item_gap: f32 = 8; // rows spacing (spec range 4–8; token = 4)
const fab_gap: f32 = 8; // FabMenuBaselineTokens.CloseButtonBetweenSpace
const label_gap: f32 = 8; // FabMenuBaselineTokens.ListItemIconLabelSpace
const label_h_pad: f32 = 8; // chip content padding (start/end)
const label_v_pad: f32 = 6; // chip content padding (top/bottom) — v1 pick
const scrim_alpha: f32 = 0.32; // the M3 scrim opacity
const min_target: f32 = 48; // a11y touch-target floor

const ItemDef = struct {
    icon: icon_w.IconName,
    label: [:0]const u8, // owned
    on_press: ?Callback,
    enabled: bool,
};

const FabMenuState = struct {
    items: std.array_list.Managed(ItemDef), // owned defs
    /// Virtual a11y children — borrowed by the semantics descriptor only
    /// while open (the slice is stable; `children` flips between it and
    /// the empty slice on open transitions).
    sem_children: std.array_list.Managed(ui.semantics.Semantics),
    opts: FabMenuOptions,
    sig: ?*ui.state.Signal(bool) = null,
    open: bool = false,
    /// The pressed / hovered item index (-1 = none). The FAB tracks its
    /// own flags — a press on it is not an item press.
    pressed_item: i32 = -1,
    fab_pressed: bool = false,
    /// Pointer hover AND the keyboard highlight share this (menu.zig's
    /// convention): hover enter sets it, arrows move it, Enter activates.
    highlight: i32 = -1,
    fab_hovered: bool = false,
    /// The last activated item (pub accessor `selectedIndex`).
    selected: usize = 0,
    /// The down position in raw (window) coordinates — drag deltas are
    /// physical finger motion (gestures.SLOP).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
};

fn stateOf(n: *Node) *FabMenuState {
    return @ptrCast(@alignCast(n.state.?));
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

/// The painted FAB square centered in the bounds (bounds may exceed 56 —
/// the container is centered, like fab.zig's container rect).
fn fabRect(b: Rect) Rect {
    const size = @min(fab_size, @min(b.w, b.h));
    return .{ .x = b.x + (b.w - size) / 2, .y = b.y + (b.h - size) / 2, .w = size, .h = size };
}

/// The item column's total height (items + the inter-row gaps).
fn columnHeight(count: usize) f32 {
    if (count == 0) return 0;
    return @as(f32, @floatFromInt(count)) * item_size +
        @as(f32, @floatFromInt(count - 1)) * item_gap;
}

/// The label chip's size for `def` (label_large text + the chip padding).
fn chipSize(t: Theme, def: ItemDef) Size {
    const ls = t.type_scale.label_large;
    const lm = ui.paint.measureText(def.label, ls.size, ls.weight >= 500);
    return .{
        .w = label_h_pad * 2 + lm.width,
        .h = @min(item_size, lm.height + label_v_pad * 2), // never taller than the row
    };
}

/// The 48x48 item-button rect for `i`, END-aligned to the FAB rect (LTR:
/// the right edges share; RTL: the left edges). `i = 0` is the top row.
fn itemButtonRect(s: *FabMenuState, b: Rect, i: usize) Rect {
    const fr = fabRect(b);
    const col_h = columnHeight(s.items.items.len);
    const y = fr.y - fab_gap - col_h + @as(f32, @floatFromInt(i)) * (item_size + item_gap);
    const rtl = ui.i18n.direction() == .rtl;
    const x = if (rtl) fr.x else fr.x + fr.w - item_size;
    return .{ .x = x, .y = y, .w = item_size, .h = item_size };
}

/// The label chip's rect: start-side of the button, vertically centered
/// on the row (LTR: left of the button; RTL: right).
fn itemChipRect(s: *FabMenuState, t: Theme, b: Rect, i: usize) Rect {
    const br = itemButtonRect(s, b, i);
    const cs = chipSize(t, s.items.items[i]);
    const y = br.y + (br.h - cs.h) / 2;
    const rtl = ui.i18n.direction() == .rtl;
    const x = if (rtl) br.x + br.w + label_gap else br.x - label_gap - cs.w;
    return .{ .x = x, .y = y, .w = cs.w, .h = cs.h };
}

/// The item's full row rect (chip + gap + button) — the hit target and the
/// a11y child bounds.
fn itemRowRect(s: *FabMenuState, t: Theme, b: Rect, i: usize) Rect {
    const br = itemButtonRect(s, b, i);
    const cr = itemChipRect(s, t, b, i);
    return ui.node.rectUnion(br, cr);
}

/// The column's bounds-box (parent space) — rows + gaps. Empty when there
/// are no items. Valid open or closed (damage covers both transitions).
fn itemsRect(s: *FabMenuState, t: Theme, b: Rect) Rect {
    if (s.items.items.len == 0) return .{ .x = b.x, .y = b.y };
    var r = itemRowRect(s, t, b, 0);
    for (1..s.items.items.len) |i| r = ui.node.rectUnion(r, itemRowRect(s, t, b, i));
    return r;
}

/// The FAB's interactive rect: the 48dp a11y floor grown around the
/// container (Compose minimumInteractiveComponentSize).
fn fabHitRect(b: Rect) Rect {
    const fr = fabRect(b);
    const w = @max(fr.w, min_target);
    const h = @max(fr.h, min_target);
    return .{ .x = fr.x + (fr.w - w) / 2, .y = fr.y + (fr.h - h) / 2, .w = w, .h = h };
}

/// The item under the point in parent space (-1 = none). Only reachable
/// while open (the column doesn't exist visually otherwise).
fn itemAt(s: *FabMenuState, t: Theme, b: Rect, x: f32, y: f32) i32 {
    if (!s.open) return -1;
    for (0..s.items.items.len) |i| {
        if (itemRowRect(s, t, b, i).contains(x, y)) return @intCast(i);
    }
    return -1;
}

/// Damage covering the FAB AND the item column: the column paints above
/// the bounds (overflow), so the dirty rect must include it for the items
/// to appear (open) and disappear (close) under damage-clip repaints.
fn markMenuDirty(n: *Node) void {
    const s = stateOf(n);
    n.markDirtyRect(ui.node.rectUnion(n.bounds, itemsRect(s, s.opts.theme, n.bounds)));
}

/// Apply the open state (the single transition path — the signal sync and
/// the programmatic setOpen both land here).
fn applyOpen(n: *Node, s: *FabMenuState, open: bool) void {
    if (s.open == open) return;
    s.open = open;
    s.pressed_item = -1;
    s.fab_pressed = false;
    s.highlight = -1;
    if (n.semantics) |sem| {
        sem.checked = open;
        // the item children exist in the a11y tree only while open (the
        // same effect as menu.zig's !visible rows being flattened out)
        sem.children = if (open) s.sem_children.items else &.{};
    }
    markMenuDirty(n);
    if (open) {
        input.setOpenPopup(n); // the router's barrier closes on outside clicks
        input.requestFocus(n); // keyboard nav while open (arrows/enter/escape)
    } else {
        input.setOpenPopup(null);
    }
    ui.semantics.notifyControlChanged(n); // a11y: expanded state changed
}

/// The signal -> widget sync (the app moved the open state externally).
fn fabMenuSyncCb(userdata: ?*anyopaque) void {
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

/// The last activated item's index (valid after a selection).
pub fn selectedIndex(n: *Node) usize {
    return stateOf(n).selected;
}

/// The widget-driven open toggle (FAB click/key, Escape, outside tap):
/// applies the state and reports it through on_toggle.
fn toggleOpen(n: *Node, open: bool) void {
    const s = stateOf(n);
    if (s.open == open) return;
    setOpen(n, open);
    if (s.opts.on_toggle) |cb| cb.fn_ptr(cb.userdata);
}

/// Activate item `index`: fire its callback and close (a speed-dial
/// selection is one-shot). selectedIndex(n) is valid inside on_press.
fn itemSelect(n: *Node, index: usize) void {
    const s = stateOf(n);
    if (index >= s.items.items.len) return;
    if (!s.items.items[index].enabled) return;
    s.selected = index;
    if (n.semantics) |sem| sem.value = s.items.items[index].label; // a11y: the value follows
    const cb = s.items.items[index].on_press;
    toggleOpen(n, false);
    if (cb) |c| c.fn_ptr(c.userdata);
}

fn fabMenuMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    // the items are overlay chrome (not measured) — the node is the FAB
    return c.constrain(.{ .w = fab_size, .h = fab_size });
}

fn fabMenuLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: the FAB + the item rects derive from the bounds at paint/hit
}

/// The region own-paint can touch, in parent space: the FAB bounds plus —
/// while open — the item column (it overflows upward). markDirty's damage
/// then covers the items without per-mark unions, and retained-subtree
/// extents include them.
fn fabMenuPaintBounds(n: *Node) Rect {
    const s = stateOf(n);
    if (!s.open) return n.bounds;
    return ui.node.rectUnion(n.bounds, itemsRect(s, s.opts.theme, n.bounds));
}

/// The hit rect: the FAB's 48dp target, unioned with the item column while
/// open (column hits resolve to this leaf, then the geometry picks the row).
fn fabMenuHitBounds(n: *Node) Rect {
    const s = stateOf(n);
    var hb = fabHitRect(n.bounds);
    if (s.open) hb = ui.node.rectUnion(hb, itemsRect(s, s.opts.theme, n.bounds));
    return hb;
}

/// Paint an icon centered in a size x size box — vector geometry
/// (icon.zig), not a font glyph.
fn paintIcon(ctx: *kx.Ctx, name: icon_w.IconName, x: f32, y: f32, size: f32, color: Color) void {
    if (color & 0xFF == 0) return;
    icon_w.drawIcon(ctx, name, x, y, size / 24.0, color);
}

fn fabMenuPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const cs = t.colors;
    const b = n.bounds;
    const fr = fabRect(b);
    // The optional scrim (v1: over the widget's own extent, behind the
    // controls — the FAB/items repaint above it).
    if (s.opts.scrim and s.open) {
        const ext = ui.node.rectUnion(b, itemsRect(s, t, b));
        ui.paint.fillRect(ctx, ext.x, ext.y, ext.w, ext.h, ui.paint.withAlphaScaled(cs.scrim, scrim_alpha));
    }
    const open = s.open;
    const radius = if (open) fr.h / 2 else t.shape.large; // CornerFull close button
    const container: Color = if (!s.opts.enabled)
        ui.paint.withAlphaScaled(cs.on_surface, 0.12)
    else if (open)
        cs.primary // the toggle's checked state = the family's solid pair
    else
        cs.primary_container;
    const content: Color = if (!s.opts.enabled)
        ui.paint.withAlphaScaled(cs.on_surface, 0.38)
    else if (open)
        cs.on_primary
    else
        cs.on_primary_container;
    // M3 elevation level 3 (level 4 hovered) — the FAB's signature lift.
    if (s.opts.enabled) {
        ui.paint.elevationShadow(ctx, fr.x, fr.y, fr.w, fr.h, radius,
            if (s.fab_hovered) 8 else 6, cs.shadow);
    }
    if (container & 0xFF != 0) ui.paint.fillRRect(ctx, fr.x, fr.y, fr.w, fr.h, radius, container);
    // the state layer (enabled only): the content color over the container
    if (s.opts.enabled) {
        const alpha: f32 = if (s.fab_pressed)
            t.state.pressed
        else if (input.isFocused(n))
            t.state.focus
        else if (s.fab_hovered)
            t.state.hover
        else
            0;
        if (alpha > 0) ui.paint.fillRRect(ctx, fr.x, fr.y, fr.w, fr.h, radius, theme_mod.stateLayer(container, content, alpha));
    }
    // the icon: 24dp closed / the close icon at the 20dp close-button size
    const iname = if (open) (s.opts.close_icon orelse s.opts.fab_icon) else s.opts.fab_icon;
    const icon_px = if (open) close_icon_size else fab_icon_size;
    paintIcon(ctx, iname, fr.x + (fr.w - icon_px) / 2, fr.y + (fr.h - icon_px) / 2, icon_px, content);
}

/// The popup overlay pass (the host paints the open popup after the tree):
/// the item column, above any later sibling. Leaf — no children.
fn fabMenuPaintOverlay(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    if (!s.open) return;
    const t = s.opts.theme;
    const cs = t.colors;
    const b = n.bounds;
    const ls = t.type_scale.label_large;
    const bold = ls.weight >= 500;
    const focused = input.isFocused(n);
    for (s.items.items, 0..) |def, i| {
        const idx: i32 = @intCast(i);
        const br = itemButtonRect(s, b, i);
        const cr = itemChipRect(s, t, b, i);
        const btn_container: Color = if (def.enabled) cs.tertiary_container else ui.paint.withAlphaScaled(cs.on_surface, 0.12);
        const btn_content: Color = if (def.enabled) cs.on_tertiary_container else ui.paint.withAlphaScaled(cs.on_surface, 0.38);
        // the label chip (start side): Level2 shadow like the menu panel
        ui.paint.elevationShadow(ctx, cr.x, cr.y, cr.w, cr.h, t.shape.medium, 2, cs.shadow);
        ui.paint.fillRRect(ctx, cr.x, cr.y, cr.w, cr.h, t.shape.medium,
            if (def.enabled) cs.surface_container else ui.paint.withAlphaScaled(cs.on_surface, 0.12));
        const lm = ui.paint.measureText(def.label, ls.size, bold);
        const tx = cr.x + label_h_pad; // the label text itself stays LTR
        const baseline = cr.y + (cr.h - lm.height) / 2 + lm.ascent;
        ui.paint.text(ctx, def.label, tx, baseline, ls.size, bold, if (def.enabled) cs.on_surface else ui.paint.withAlphaScaled(cs.on_surface, 0.38));
        // the item button: Level3 shadow (ListItemContainerElevation)
        if (def.enabled) {
            ui.paint.elevationShadow(ctx, br.x, br.y, br.w, br.h, t.shape.medium, 6, cs.shadow);
        }
        ui.paint.fillRRect(ctx, br.x, br.y, br.w, br.h, t.shape.medium, btn_container);
        // state layer (enabled only): pressed > highlight — focus when the
        // menu holds the keyboard focus, hover otherwise (menu.zig's rule)
        if (def.enabled) {
            const alpha: f32 = if (s.pressed_item == idx)
                t.state.pressed
            else if (s.highlight == idx)
                if (focused) t.state.focus else t.state.hover
            else
                0;
            if (alpha > 0) ui.paint.fillRRect(ctx, br.x, br.y, br.w, br.h, t.shape.medium, theme_mod.stateLayer(btn_container, btn_content, alpha));
        }
        paintIcon(ctx, def.icon, br.x + (br.w - item_icon_size) / 2, br.y + (br.h - item_icon_size) / 2, item_icon_size, btn_content);
    }
}

fn fabMenuOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    const t = s.opts.theme;
    const b = n.bounds;
    switch (ev.phase) {
        .down => {
            const idx = itemAt(s, t, b, ev.x, ev.y);
            if (idx >= 0) {
                // a press on a disabled item is consumed (inside the menu —
                // an outside click dismisses, an inside one doesn't)
                if (s.items.items[@intCast(idx)].enabled) {
                    s.pressed_item = idx;
                    n.markDirty();
                }
                s.down_raw_x = ev.raw_x;
                s.down_raw_y = ev.raw_y;
                return true;
            }
            if (fabHitRect(b).contains(ev.x, ev.y)) {
                s.fab_pressed = true;
                s.down_raw_x = ev.raw_x;
                s.down_raw_y = ev.raw_y;
                n.markDirty();
                return true;
            }
            // inside the open column's box but on a gap: consume (it is not
            // an outside click) without starting a press
            return s.open;
        },
        .up => {
            const item_was = s.pressed_item;
            const fab_was = s.fab_pressed;
            s.pressed_item = -1;
            s.fab_pressed = false;
            n.markDirty();
            if (fab_was and fabHitRect(b).contains(ev.x, ev.y)) {
                toggleOpen(n, !s.open);
            } else if (item_was >= 0 and itemAt(s, t, b, ev.x, ev.y) == item_was) {
                itemSelect(n, @intCast(item_was));
            }
            return true;
        },
        .move => {
            // A drag past the touch slop is a scroll, not a press: cancel
            // both presses. The move is NOT claimed so it keeps bubbling
            // to scrollable ancestors.
            if (s.pressed_item >= 0 or s.fab_pressed) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.pressed_item = -1;
                    s.fab_pressed = false;
                    n.markDirty();
                }
            }
            return false;
        },
        // the pointer went down outside while we held the capture or the
        // popup is open: cancel + dismiss (the router's barrier sends this)
        .outside_down => {
            s.pressed_item = -1;
            s.fab_pressed = false;
            if (s.open) toggleOpen(n, false);
            markMenuDirty(n);
            return true;
        },
        .enter => {
            s.highlight = itemAt(s, t, b, ev.x, ev.y);
            s.fab_hovered = fabHitRect(b).contains(ev.x, ev.y);
            n.markDirty();
            return true;
        },
        // moving across the leaf's cells emits hover_move (not enter/leave):
        // re-resolve the cell under the pointer
        .hover_move => {
            const h = itemAt(s, t, b, ev.x, ev.y);
            const fh = fabHitRect(b).contains(ev.x, ev.y);
            if (h != s.highlight or fh != s.fab_hovered) {
                s.highlight = h;
                s.fab_hovered = fh;
                n.markDirty();
            }
            return true;
        },
        .leave => {
            s.highlight = -1;
            s.fab_hovered = false;
            n.markDirty();
            return true;
        },
    }
}

/// Keyboard: the FAB takes the focus; Enter/Space toggle it closed↔open.
/// While open the arrows move the item highlight (wrapping, skipping
/// disabled), Enter/Space activate it (or toggle the menu closed when
/// nothing is highlighted), Escape closes.
fn fabMenuOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    if (ev.kind != .key_down) return false;
    const count: i32 = @intCast(s.items.items.len);
    switch (ev.key) {
        .enter, .space => {
            if (s.open and s.highlight >= 0) {
                itemSelect(n, @intCast(s.highlight));
            } else {
                toggleOpen(n, !s.open);
            }
            return true;
        },
        .up, .down => {
            if (!s.open) return false;
            if (count == 0) return true;
            const step: i32 = if (ev.key == .down) 1 else -1;
            var i: i32 = if (s.highlight < 0) (if (step > 0) -1 else count) else s.highlight;
            var guard: i32 = 0;
            while (guard < count) : (guard += 1) {
                i = @mod(i + step, count);
                if (s.items.items[@intCast(i)].enabled) break;
            }
            s.highlight = i;
            n.markDirty();
            return true;
        },
        .escape => {
            if (!s.open) return false;
            toggleOpen(n, false);
            return true;
        },
        else => {},
    }
    return false;
}

/// Item `index`'s row rect in NODE-LOCAL space (Semantics.child_bounds —
/// the a11y bridge maps it to window space for highlights and targeted
/// activation taps).
fn fabMenuChildBounds(n: *Node, index: usize) Rect {
    const s = stateOf(n);
    const local = Rect{ .x = 0, .y = 0, .w = n.bounds.w, .h = n.bounds.h };
    const r = itemRowRect(s, s.opts.theme, local, index);
    return r;
}

fn fabMenuDeinit(n: *Node) void {
    const s = stateOf(n);
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = fabMenuSyncCb, .userdata = n } });
    // Node.deinit's releaseNode clears the router's open_popup only when it
    // still points to THIS node — no unconditional setOpenPopup(null) here
    // (a rebuild may have already registered the replacement menu).
    input.releaseNode(n);
    for (s.items.items) |*def| n.allocator.free(def.label);
    s.items.deinit();
    s.sem_children.deinit();
    n.allocator.destroy(s);
}

const fab_menu_vtable = ui.node.VTable{
    .measure = fabMenuMeasure,
    .layout = fabMenuLayout,
    .paint = fabMenuPaint,
    .paint_overlay = fabMenuPaintOverlay,
    .deinit = fabMenuDeinit,
    .on_pointer = fabMenuOnPointer,
    .on_key = fabMenuOnKey,
    .hit_bounds = fabMenuHitBounds,
    .paint_bounds = fabMenuPaintBounds,
};

/// An M3E FAB menu (speed dial): a toggle FAB with a column of labeled
/// item buttons revealed above it. A leaf — the items are internal chrome
/// painted in the popup overlay pass (they overflow the FAB's bounds and
/// must render above later siblings). `items` are copied (labels owned).
/// `opts.open` drives the open state (round-trips); without a signal the
/// widget toggles itself — setOpen/isOpen work either way. Each item's
/// `on_press` fires on activation and closes the menu; `selectedIndex(n)`
/// is valid inside the callback. `opts.on_toggle` fires on user-driven
/// open-state changes.
pub fn fabMenu(allocator: std.mem.Allocator, items: []const FabMenuItem, opts: FabMenuOptions) !*Node {
    const node = try Node.create(allocator, &fab_menu_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(FabMenuState);
    errdefer allocator.destroy(s);
    s.* = .{
        .items = std.array_list.Managed(ItemDef).init(allocator),
        .sem_children = std.array_list.Managed(ui.semantics.Semantics).init(allocator),
        .opts = opts,
        .sig = opts.open,
    };
    // One ownership boundary: on ANY failure this errdefer frees the
    // appended defs' labels (fabMenuDeinit owns them only once returned).
    errdefer {
        for (s.items.items) |*def| allocator.free(def.label);
        s.items.deinit();
    }
    try s.items.ensureTotalCapacity(items.len); // one allocation for the defs
    try s.sem_children.ensureTotalCapacity(items.len); // and one for the a11y children
    for (items) |item| {
        const label = try dupeZ(allocator, item.label);
        errdefer allocator.free(label); // iteration scope: freed only if THIS iteration fails before the append
        // No catch-free here: on append failure the errdefer frees the copy.
        s.items.appendAssumeCapacity(.{ .icon = item.icon, .label = label, .on_press = item.on_press, .enabled = item.enabled });
    }
    for (s.items.items) |*def| {
        s.sem_children.appendAssumeCapacity(.{
            .role = .menu_item,
            .label = def.label,
            .disabled = !def.enabled,
            .actions = ui.semantics.Actions.initOne(.activate),
        });
    }
    node.state = s;
    ui.semantics.attach(node, .{
        .role = .toggle, // the toggle FAB; checked = the menu's open state
        .label = opts.a11y_label,
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
        .checked = false,
        .actions = ui.semantics.Actions.initOne(.activate),
        .children = &.{}, // items join the a11y tree only while open
        .child_bounds = fabMenuChildBounds,
    }); // Phase 2c
    if (opts.open) |sg| {
        sg.subscribe(.{ .callback = .{ .fn_ptr = fabMenuSyncCb, .userdata = node } });
        if (sg.peek()) applyOpen(node, s, true); // starts open
    }
    return node;
}

// --- tests ---

fn pressCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

const two_items = [_]FabMenuItem{
    .{ .icon = .star, .label = "Star" },
    .{ .icon = .heart, .label = "Like" },
};

test "fab_menu: measures the baseline FAB square (56x56); items are overlay chrome" {
    const a = std.testing.allocator;
    const n = try fabMenu(a, &two_items, .{});
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(fab_size, sz.w);
    try std.testing.expectEqual(fab_size, sz.h);
    // the FAB stays a 56 square centered in a larger bounds
    n.layout(.{ .x = 10, .y = 200, .w = 200, .h = 100 });
    const fr = fabRect(n.bounds);
    try std.testing.expectEqual(@as(f32, 82), fr.x); // 10 + (200-56)/2
    try std.testing.expectEqual(@as(f32, 222), fr.y); // 200 + (100-56)/2
    // the column stacks ABOVE the FAB, end-aligned, 8dp between everything
    const s = stateOf(n);
    const t = theme_mod.light;
    const br0 = itemButtonRect(s, n.bounds, 0);
    const br1 = itemButtonRect(s, n.bounds, 1);
    try std.testing.expectEqual(fr.x + fr.w - item_size, br0.x); // right edges share (LTR)
    try std.testing.expectEqual(br0.y + item_size + item_gap, br1.y);
    try std.testing.expectEqual(fr.y - fab_gap, br1.y + item_size); // last row 8dp above the FAB
    // the chip sits on the button's START side
    const cr0 = itemChipRect(s, t, n.bounds, 0);
    try std.testing.expectEqual(br0.x - label_gap, cr0.x + cr0.w);
}

test "fab_menu: click toggles open (signal + on_toggle); signal drives it back" {
    var toggles: u32 = 0;
    const cb = Callback{ .fn_ptr = pressCounterCb, .userdata = &toggles };
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try fabMenu(a, &two_items, .{ .open = sig, .on_toggle = cb });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 200, .w = 56, .h = 56 });
    try std.testing.expect(!isOpen(n));
    try std.testing.expectEqual(@as(usize, 0), n.semantics.?.children.len); // items hidden while closed
    // click the FAB: opens, sets the signal, fires on_toggle
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 28, .y = 228, .raw_x = 28, .raw_y = 228 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 28, .y = 228, .raw_x = 28, .raw_y = 228 });
    try std.testing.expect(isOpen(n));
    try std.testing.expect(sig.peek());
    try std.testing.expectEqual(@as(u32, 1), toggles);
    try std.testing.expectEqual(@as(usize, 2), n.semantics.?.children.len);
    try std.testing.expectEqual(true, n.semantics.?.checked);
    // external close: no on_toggle (programmatic), state follows
    sig.set(false);
    try std.testing.expect(!isOpen(n));
    try std.testing.expectEqual(@as(u32, 1), toggles);
    try std.testing.expectEqual(@as(usize, 0), n.semantics.?.children.len);
    // a drag past the slop cancels the press (no toggle)
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 28, .y = 228, .raw_x = 28, .raw_y = 228 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .move, .x = 28, .y = 260, .raw_x = 28, .raw_y = 260 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 28, .y = 228, .raw_x = 28, .raw_y = 228 });
    try std.testing.expect(!isOpen(n));
    try std.testing.expectEqual(@as(u32, 1), toggles);
}

test "fab_menu: item click fires its callback and closes; disabled items don't fire" {
    var count0: u32 = 0;
    var count1: u32 = 0;
    var toggles: u32 = 0;
    const items = [_]FabMenuItem{
        .{ .icon = .star, .label = "Star", .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &count0 } },
        .{ .icon = .heart, .label = "Like", .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &count1 }, .enabled = false },
        .{ .icon = .check, .label = "Done", .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &count0 } },
    };
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try fabMenu(a, &items, .{ .on_toggle = .{ .fn_ptr = pressCounterCb, .userdata = &toggles } });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 300, .w = 56, .h = 56 });
    setOpen(n, true);
    try std.testing.expect(isOpen(n));
    const s = stateOf(n);
    // item 0's row (top of the column): a click on the chip's label area fires it
    const r0 = itemRowRect(s, theme_mod.light, n.bounds, 0);
    const x0 = r0.x + 4;
    const y0 = r0.y + r0.h / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = x0, .y = y0, .raw_x = x0, .raw_y = y0 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = x0, .y = y0, .raw_x = x0, .raw_y = y0 });
    try std.testing.expectEqual(@as(u32, 1), count0);
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n));
    try std.testing.expect(!isOpen(n)); // a selection closes the menu
    try std.testing.expectEqual(@as(u32, 1), toggles); // the close reports
    try std.testing.expectEqualStrings("Star", n.semantics.?.value);
    // the disabled item swallows its click (no fire, and the menu stays open)
    setOpen(n, true);
    const r1 = itemRowRect(s, theme_mod.light, n.bounds, 1);
    const x1 = r1.x + r1.w - 4;
    const y1 = r1.y + r1.h / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = x1, .y = y1, .raw_x = x1, .raw_y = y1 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = x1, .y = y1, .raw_x = x1, .raw_y = y1 });
    try std.testing.expectEqual(@as(u32, 0), count1);
    try std.testing.expect(isOpen(n));
    // the full router path: the popup-aware hit-test resolves the item row
    // outside the FAB's bounds and delivers the click to this leaf
    const rr0 = itemRowRect(s, theme_mod.light, n.bounds, 0);
    router.dispatchPointer(n, .{ .phase = .down, .x = rr0.x + rr0.w - 4, .y = rr0.y + rr0.h / 2 });
    router.dispatchPointer(n, .{ .phase = .up, .x = rr0.x + rr0.w - 4, .y = rr0.y + rr0.h / 2 });
    try std.testing.expectEqual(@as(u32, 2), count0);
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n));
    try std.testing.expect(!isOpen(n));
    // the router's barrier: an outside click closes the open menu
    setOpen(n, true);
    router.dispatchPointer(n, .{ .phase = .down, .x = 400, .y = 500 });
    try std.testing.expect(!isOpen(n));
    // Escape closes too
    setOpen(n, true);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .escape });
    try std.testing.expect(!isOpen(n));
}

test "fab_menu: keyboard — enter toggles, arrows highlight, enter activates" {
    var count: u32 = 0;
    const items = [_]FabMenuItem{
        .{ .icon = .star, .label = "Star", .enabled = false },
        .{ .icon = .heart, .label = "Like", .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &count } },
    };
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try fabMenu(a, &items, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 200, .w = 56, .h = 56 });
    input.requestFocus(n);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expect(isOpen(n));
    // down skips the disabled item 0 straight to 1
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    try std.testing.expectEqual(@as(i32, 1), stateOf(n).highlight);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    try std.testing.expectEqual(@as(i32, 1), stateOf(n).highlight); // wraps back to 1 (0 disabled)
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expect(!isOpen(n));
    try std.testing.expectEqual(@as(usize, 1), selectedIndex(n));
    // space with nothing highlighted just toggles
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .space });
    try std.testing.expect(isOpen(n));
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .escape });
    try std.testing.expect(!isOpen(n));
}

test "fab_menu: disabled FAB swallows input entirely" {
    const a = std.testing.allocator;
    const n = try fabMenu(a, &two_items, .{ .enabled = false });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 56, .h = 56 });
    try std.testing.expect(!n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 28, .y = 28 }));
    try std.testing.expect(!n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 28, .y = 28 }));
    try std.testing.expect(!n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .enter }));
    try std.testing.expect(!isOpen(n));
    try std.testing.expect(!n.semantics.?.focusable);
    try std.testing.expect(n.semantics.?.disabled);
}

test "fab_menu: RTL mirrors the column (button to the left, chip to its right)" {
    const a = std.testing.allocator;
    const i18n = try ui.i18n.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    var count: u32 = 0;
    const items = [_]FabMenuItem{
        .{ .icon = .star, .label = "Star", .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &count } },
    };
    const n = try fabMenu(a, &items, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 200, .w = 56, .h = 56 });
    const s = stateOf(n);
    const fr = fabRect(n.bounds);
    const br = itemButtonRect(s, n.bounds, 0);
    const cr = itemChipRect(s, theme_mod.light, n.bounds, 0);
    // RTL: the button's LEFT edge is the FAB's left edge; the chip is to its right
    try std.testing.expectEqual(fr.x, br.x);
    try std.testing.expectEqual(br.x + br.w + label_gap, cr.x);
    // a click on the row still fires (the row union covers chip..button)
    setOpen(n, true);
    const row = itemRowRect(s, theme_mod.light, n.bounds, 0);
    const x = cr.x + 4;
    const y = row.y + row.h / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = x, .y = y, .raw_x = x, .raw_y = y });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = x, .y = y, .raw_x = x, .raw_y = y });
    try std.testing.expectEqual(@as(u32, 1), count);
}

test "fab_menu: semantics — toggle role, checked follows open, menu_item children while open" {
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const n = try fabMenu(a, &two_items, .{ .open = sig, .a11y_label = "Actions" });
    defer n.deinit();
    try std.testing.expectEqual(ui.semantics.Role.toggle, n.semantics.?.role);
    try std.testing.expectEqualStrings("Actions", n.semantics.?.label);
    try std.testing.expectEqual(true, n.semantics.?.checked); // started open via the signal
    try std.testing.expect(isOpen(n));
    const kids = n.semantics.?.children;
    try std.testing.expectEqual(@as(usize, 2), kids.len);
    try std.testing.expectEqual(ui.semantics.Role.menu_item, kids[0].role);
    try std.testing.expectEqualStrings("Star", kids[0].label);
    try std.testing.expect(kids[0].actions.contains(.activate));
    // the child bounds are node-local row rects (item 0 sits above the FAB)
    n.layout(.{ .x = 100, .y = 300, .w = 56, .h = 56 });
    const cb0 = fabMenuChildBounds(n, 0);
    const s = stateOf(n);
    const row0 = itemRowRect(s, theme_mod.light, n.bounds, 0);
    try std.testing.expectEqual(row0.y - 300, cb0.y);
    try std.testing.expectEqual(row0.x - 100, cb0.x);
    sig.set(false);
    try std.testing.expectEqual(@as(usize, 0), n.semantics.?.children.len);
    try std.testing.expectEqual(false, n.semantics.?.checked);
}

test "golden: closed paints only the primary_container FAB (no items)" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try fabMenu(a, &two_items, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 160, 220);
    defer r.deinit();
    n.layout(.{ .x = 52, .y = 152, .w = 56, .h = 56 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // inside the FAB container, off the glyph ink: primary_container
    try std.testing.expectEqual(t.colors.primary_container, f.pixelAt(60, 180));
    // the item region far above the FAB stays background (the FAB's own
    // shadow can reach a few px above the container — the probe keeps out)
    try std.testing.expectEqual(@as(u64, 0), f.countNotIn(.{ .x = 0, .y = 0, .w = 160, .h = 120 }, 0xFFFFFFFF));
}

test "golden: open paints the item chips + tertiary buttons above the FAB" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try fabMenu(a, &two_items, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 260);
    defer r.deinit();
    n.layout(.{ .x = 80, .y = 190, .w = 56, .h = 56 });
    setOpen(n, true);
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const s = stateOf(n);
    // item 1's button (closest to the FAB): tertiary_container
    const br1 = itemButtonRect(s, n.bounds, 1);
    try std.testing.expectEqual(t.colors.tertiary_container, f.pixelAt(@intFromFloat(br1.x + 4), @intFromFloat(br1.y + 24)));
    // item 0's chip: surface_container; its label ink is on_surface
    const cr0 = itemChipRect(s, t, n.bounds, 0);
    try std.testing.expectEqual(t.colors.surface_container, f.pixelAt(@intFromFloat(cr0.x + 2), @intFromFloat(cr0.y + cr0.h / 2)));
    try std.testing.expect(f.countColorIn(cr0, t.colors.on_surface) > 0);
    // the open FAB is the solid-primary full circle: a point inside the
    // circle above the 20dp icon's ink; the corner misses the fill
    const fr = fabRect(n.bounds);
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(@intFromFloat(fr.x + fr.w / 2), @intFromFloat(fr.y + fr.h / 2 - 14)));
    try std.testing.expect(f.pixelAt(@intFromFloat(fr.x + 2), @intFromFloat(fr.y + 2)) != t.colors.primary);
    // items paint in the overlay pass above a later sibling's territory —
    // here simply: nothing else overwrote them (exact color inside)
    try std.testing.expect(f.countColor(t.colors.tertiary_container) > 0);
}

test "golden: open menu items paint ABOVE a later sibling (the overlay pass)" {
    // A stack keeps the FAB menu pinned bottom-right; the opaque magenta box
    // is a LATER child covering the item column's region — the items must
    // still win because they paint in the popup overlay pass.
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try fabMenu(a, &two_items, .{ .theme = t });
    const cover = try golden.solidBox(a, 200, 200, 0xFF00FFFF); // opaque magenta
    const st = try layout_w.stack(a, .{ .fit = .expand, .alignment = .bottom_right });
    st.add(n);
    st.add(cover);
    defer st.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 300);
    defer r.deinit();
    st.layout(.{ .x = 0, .y = 0, .w = 200, .h = 300 });
    setOpen(n, true);
    r.paint(st, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the FAB sits bottom-right (144,244); the items overflow upward into
    // the magenta box's region (y = 100..300) and must paint over it
    const s = stateOf(n);
    const br1 = itemButtonRect(s, n.bounds, 1);
    try std.testing.expect(br1.y < 244);
    // off the icon glyph (24dp centered): the container ink at the edge
    try std.testing.expectEqual(t.colors.tertiary_container, f.pixelAt(@intFromFloat(br1.x + 4), @intFromFloat(br1.y + 24)));
    // the magenta sibling shows through where nothing overlays it
    try std.testing.expectEqual(@as(Color, 0xFF00FFFF), f.pixelAt(20, 290));
}

test "golden: a pressed item paints the on_tertiary_container state layer" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try fabMenu(a, &two_items, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 260);
    defer r.deinit();
    n.layout(.{ .x = 80, .y = 190, .w = 56, .h = 56 });
    setOpen(n, true);
    const s = stateOf(n);
    const br0 = itemButtonRect(s, n.bounds, 0);
    const x = br0.x + 4; // off the icon glyph
    const y = br0.y + 24;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = x, .y = y, .raw_x = x, .raw_y = y });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try golden.expectPixelApprox(f, @intFromFloat(x), @intFromFloat(y), golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_tertiary_container, t.state.pressed), t.colors.tertiary_container));
}

test "golden: a disabled item paints the OnSurface@0.12 button + @0.38 icon" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const items = [_]FabMenuItem{
        .{ .icon = .star, .label = "Star", .enabled = false },
    };
    const n = try fabMenu(a, &items, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 180);
    defer r.deinit();
    n.layout(.{ .x = 80, .y = 110, .w = 56, .h = 56 });
    setOpen(n, true);
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const s = stateOf(n);
    const br = itemButtonRect(s, n.bounds, 0);
    // the button container: on_surface @ 0.12 over the background
    const dis = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.12), 0xFFFFFFFF);
    try golden.expectPixelApprox(f, @intFromFloat(br.x + 4), @intFromFloat(br.y + 24), dis);
    // the icon ink: on_surface @ 0.38 over the dimmed container
    try std.testing.expect(f.countColorApproxIn(br, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), dis)) > 0);
}

test "golden: scrim paints the M3 scrim over the widget's extent while open" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try fabMenu(a, &two_items, .{ .theme = t, .scrim = true });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 260);
    defer r.deinit();
    // a wide bounds: the FAB centers (x = 82..138); the extent's left strip
    // is inside the widget's own region but far from any shadow
    n.layout(.{ .x = 40, .y = 190, .w = 140, .h = 56 });
    setOpen(n, true);
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const expect = golden.blendOver(ui.paint.withAlphaScaled(t.colors.scrim, scrim_alpha), 0xFFFFFFFF);
    try golden.expectPixelApprox(f, 44, 218, expect);
}
