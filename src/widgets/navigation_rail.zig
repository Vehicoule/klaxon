// NavigationRail (Phase 2d.3 PR D4, M3E) — the Material 3 Expressive
// navigation rail: a Surface column of items driven by an external
// Signal(usize) (single choice = tab-group semantics: the arrow keys move
// AND select).
//
// Upstream (collapsed): .ref/material3/WideNavigationRail.kt's
// WideNavigationRailLayout at expanded = false + NavigationItem.kt's
// AnimatedNavigationItemLayout at iconPositionProgress = 0 (the
// WideNavigationRailItem top-icon item):
//   - container Surface/CornerNone/Level0; CollapsedRailWidth =
//     NavigationRailCollapsedTokens.ContainerWidth = 96 fixed (a narrower
//     parent caps it); ContentPadding = (0, TopSpace 44, 0, 0); items
//     Arrangement.Top, spacedBy ItemVerticalSpace 4
//   - labeled item (placeAnimatedLabelAndIcon at progress 0): width =
//     constrain(max(labelW, icon 24 + 2*indicatorHPad 16 + 2*itemHPad 20)
//     = 96) — the item always spans the rail; content height = indicator
//     32 + IconLabelSpace 4 + labelH, minHeight'd to TopIconItemMinHeight
//     (ContainerHeight) 64 by the rail and vertically centered in it. The
//     56x32 CornerFull indicator sits at x = 20 (centered in 96), the
//     icon 4 inside it, the LabelMedium label centered at
//     indicator_bottom + IconLabelSpace.
//   - icon-only item (placeIcon via TopIconOrIconOnlyMeasurePolicy): the
//     56x56 CornerFull circle centered in the 96x64 item
//   - colors: active icon OnSecondaryContainer, active label Secondary
//     (ItemActiveLabelText), inactive both OnSurfaceVariant, disabled
//     OnSurfaceVariant @ 0.38, indicator SecondaryContainer, state layer +
//     ripple OnSurface over the indicator only (the upstream ripple's
//     LocalContentColor = the rail's contentColor =
//     contentColorFor(Surface) = OnSurface)
//
// Indication (NavigationRail.kt:222-231 + NavigationItem.kt:379-386,
// 1275-1280): the whole item is `selectable(interactionSource,
// indication = null)` — the indication is a separate indicator-sized
// composable, `.clip(indicatorShape).indication(mappedSource,
// ripple(focusRingShape = indicatorShape))`: a bounded ripple clipped to
// the CornerFull indicator (the 56x32 pill / the icon-only 56x56 circle /
// the expanded start-icon pill), fed by a per-item
// interactions.Tracker. Press = the ripple; hover/focus = the animated
// state layer. The group focus lands on the selected item's layer;
// Enter/Space presses at the indicator's center.
//   - the plain NavigationRail.kt widget (widthIn(min = 80), 4dp
//     padding, spacedBy 4) is NOT what this widget models: it has no
//     expanded state — Klaxon's `expanded` flag is WideNavigationRail's
//
// Upstream (expanded): .ref/material3/WideNavigationRail.kt +
// NavigationItem.kt (the start-icon item at progress 1):
//   - ContentPadding top = NavigationRailCollapsedTokens.TopSpace 44;
//     items spacedBy 0 (the collapsed WNR's 4 is not used when expanded)
//   - rail width = coerceAtMost(360, max(220, widestItemWidth +
//     WNRItemHorizontalPadding 20)) where an item's width = pill + 20 →
//     rail = clamp(220, pill + 40, 360), capped by the parent's max
//   - the item is a start-icon row at x = 0 of width pill + 20 and height
//     56: the pill (56 tall, CornerFull, width = icon 24 + IconLabelSpace
//     8 + label + 2*16 expanded padding) starts at x = 20, the icon at
//     +16 inside it, the LabelLarge label at icon + 24 + 8 — all
//     vertically centered
//   - active icon + label OnSecondaryContainer (start-icon position);
//     inactive OnSurfaceVariant; same state-layer tokens
//   - input: a click selects (and focuses the group); up/down arrows move
//     the selection, skipping disabled items and wrapping; a drag past the
//     touch slop (ui/gestures.SLOP, raw coords) is a scroll, not a press
//
// The widget is a LEAF: the items (icon + label + indicator) are internal
// chrome painted by the widget (skip_children — document children never
// serialize; the items come from the options array).
//
// Deviations: NavRailItem.label is required — an empty string is treated
// as the upstream label == null case (the 56x56 circle; upstream would
// keep the labeled layout for an empty-string label). No header (FAB) /
// footer slots, no modal variant (SurfaceContainer, CornerLarge, Level2 +
// scrim), no collapsed<->expanded animation (the state switch is
// instant). RTL mirrors the expanded row; the label run stays LTR.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const i18n_mod = @import("../ui/i18n.zig");
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

/// A rail item (the factory copies the label).
pub const NavRailItem = struct {
    label: []const u8,
    icon: icon_w.IconName = .home,
    enabled: bool = true,
};

pub const NavigationRailOptions = struct {
    /// Expanded rails show icon+label rows (220-360dp); collapsed rails are
    /// the narrow NavigationRail (80dp, label under the icon).
    expanded: bool = false,
    /// The fixed selection when no signal is given (with one, the signal is
    /// the source of truth and this is only the fallback).
    selected: usize = 0,
    theme: Theme = theme_mod.light,
};

// --- WideNavigationRail.kt (collapsed) ---
const collapsed_w: f32 = 96; // CollapsedRailWidth = NavigationRailCollapsedTokens.ContainerWidth
const collapsed_top: f32 = 44; // ContentPadding.top = WNRTopPadding = CollapsedTokens.TopSpace
const item_gap: f32 = 4; // NavigationRailCollapsedTokens.ItemVerticalSpace (collapsed spacedBy)
const item_h_min: f32 = 64; // TopIconItemMinHeight = NavigationRailBaselineItemTokens.ContainerHeight
const indicator_w: f32 = 56; // VerticalItemTokens.ActiveIndicatorWidth = icon + 2*16
const ind_h_label: f32 = 32; // VerticalItemTokens.ActiveIndicatorHeight = icon + 2*4
const ind_h_nolabel: f32 = 56; // icon + 2*WNRItemNoLabelIndicatorPadding(16) — the circle
const ind_ivp: f32 = (ind_h_label - icon_size) / 2; // ItemTopIconIndicatorVerticalPadding = 4
const col_icon_label_gap: f32 = 4; // VerticalItemTokens.IconLabelSpace (indicator->label)
// --- WideNavigationRail.kt (expanded) ---
const wnr_top_pad: f32 = 44; // NavigationRailCollapsedTokens.TopSpace
const expanded_min_w: f32 = 220; // NavigationRailExpandedTokens.ContainerWidthMinimum
const expanded_max_w: f32 = 360; // NavigationRailExpandedTokens.ContainerWidthMaximum
const item_hpad: f32 = 20; // WNRItemHorizontalPadding
// minimumA11ySize (InteractiveComponentSize) — the a11y floor is
// theme.platform.hit_target_min (48 mobile / 24 desktop), read per-theme
// where the expanded item width is clamped.
const pill_lead: f32 = 16; // HorizontalItemTokens.FullWidthLeadingSpace (+ trailing 16)
const pill_h: f32 = 56; // HorizontalItemTokens.ActiveIndicatorHeight
const icon_size: f32 = 24; // BaselineItemTokens.IconSize
const icon_label_gap: f32 = 8; // HorizontalItemTokens.IconLabelSpace

const ItemDef = struct {
    label: [:0]const u8, // owned
    icon: icon_w.IconName,
    enabled: bool,
};

/// Per-item indication state (the upstream per-item MutableInteractionSource
/// + the indicator composable's ripple). Items are fixed at construction,
/// so a stable slice holds them — the StateLayer's timeline channel takes
/// `l`'s address and must never move once wired.
const ItemFx = struct {
    inter: ui.interactions.Tracker = .{},
    layer: ui.state_layer.StateLayer = .{},
    ripples: ui.ripple.Ripples = .{},
    press_id: u32 = 0, // the live press's tracker id (0 = none)
};

const RailState = struct {
    items: std.array_list.Managed(ItemDef), // owned defs
    /// Live per-item a11y descriptors — the semantics tree's virtual
    /// children borrow this slice; railSelect updates `checked` in place.
    sem_children: std.array_list.Managed(ui.semantics.Semantics),
    /// Per-item indication (parallel to `items` — same count/order, fixed).
    fx: []ItemFx = &.{},
    opts: NavigationRailOptions,
    sig: ?*ui.state.Signal(usize) = null,
    on_change: ?Callback = null,
    selected: usize = 0,
    pressed: i32 = -1,
    hovered: i32 = -1,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — gestures.SLOP).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
    i18n: ?*i18n_mod.I18n = null,
};

fn stateOf(n: *Node) *RailState {
    return @ptrCast(@alignCast(n.state.?));
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

/// Item `index`'s rect in NODE-LOCAL space (Semantics.child_bounds).
fn railChildBounds(n: *Node, index: usize) Rect {
    return itemGeom(stateOf(n), .{ .x = 0, .y = 0, .w = n.bounds.w, .h = n.bounds.h }, index);
}

/// The item's label metrics against the item's type style (collapsed:
/// LabelMedium — VerticalItemTokens.LabelTextFont; expanded: LabelLarge —
/// HorizontalItemTokens.LabelTextFont).
fn labelMetrics(s: *RailState, def: ItemDef) ui.paint.TextMetrics {
    const ls = if (s.opts.expanded) s.opts.theme.type_scale.label_large else s.opts.theme.type_scale.label_medium;
    return ui.paint.measureText(def.label, ls.size, ls.weight >= 500);
}

/// The collapsed labeled item's verticals (placeAnimatedLabelAndIcon at
/// progress 0, inside the TopIconItemMinHeight item the rail imposes):
/// content = indicator 32 + IconLabelSpace 4 + label, ≥ 64 tall, and the
/// Box(contentAlignment = Center) centers it — so the indicator's top is
/// (h - content)/2, the icon 4 inside it, the label at
/// indicator_bottom + IconLabelSpace.
fn collapsedVerticals(lm: ui.paint.TextMetrics) struct { h: f32, ind_y: f32 } {
    const content_h = ind_h_label + col_icon_label_gap + lm.height;
    const h = @max(item_h_min, content_h);
    return .{ .h = h, .ind_y = (h - content_h) / 2 };
}

/// The collapsed item's height: a labeled item is max(64, 36 + labelH);
/// an icon-only item is max(64, 56) = 64 (the 56-circle centered).
fn collapsedItemH(s: *RailState, def: ItemDef) f32 {
    if (def.label.len == 0) return item_h_min;
    return collapsedVerticals(labelMetrics(s, def)).h;
}

/// The expanded item's pill width: icon 24 + IconLabelSpace 8 + label +
/// 2*16 (the start-icon indicator's expanded horizontal padding). The
/// label is measured within itemMaxWidth - (icon + gap) like upstream.
fn pillWidth(s: *RailState, b: Rect, def: ItemDef) f32 {
    const lw = @min(labelMetrics(s, def).width, @max(0, b.w - item_hpad - icon_size - icon_label_gap));
    return icon_size + icon_label_gap + lw + pill_lead * 2;
}

/// The expanded item's width: constrain(pill + WNRItemHorizontalPadding),
/// min the a11y size, max the rail's width - WNRItemHorizontalPadding.
fn expandedItemW(s: *RailState, b: Rect, def: ItemDef) f32 {
    const a11y = s.opts.theme.platform.hit_target_min;
    return std.math.clamp(pillWidth(s, b, def) + item_hpad, a11y, @max(a11y, b.w - item_hpad));
}

/// The item's rect in the widget's parent space.
///   collapsed: placeRelative(0, y) — the item spans the rail's full
///     width, stacked below the 44dp top padding with 4dp between items
///   expanded: a start-icon row at x = 0 of width pill + 20 and height 56,
///     top padding 44, no spacing (mirrored in RTL)
fn itemGeom(s: *RailState, b: Rect, i: usize) Rect {
    if (s.opts.expanded) {
        const def = s.items.items[i];
        const w = expandedItemW(s, b, def);
        const x = if (ui.i18n.direction() == .rtl) b.x + b.w - w else b.x; // placeRelative(0, y)
        return .{ .x = x, .y = b.y + wnr_top_pad + @as(f32, @floatFromInt(i)) * pill_h, .w = w, .h = pill_h };
    }
    var y = b.y + collapsed_top;
    for (s.items.items[0..i]) |prev| y += collapsedItemH(s, prev) + item_gap;
    return .{ .x = b.x, .y = y, .w = b.w, .h = collapsedItemH(s, s.items.items[i]) };
}

/// The item's indication zone — upstream's separate indicator-sized
/// composable (`.clip(indicatorShape).indication(...)`): the 56x32 pill
/// (labeled collapsed), the 56x56 circle (icon-only) or the expanded
/// start-icon pill. Shared by the paint path and the keyboard ripple —
/// the press/hover/focus chrome clips to exactly this rect.
fn indicatorRect(s: *RailState, b: Rect, i: usize) Rect {
    const def = s.items.items[i];
    const ir = itemGeom(s, b, i);
    if (s.opts.expanded) {
        const pw = pillWidth(s, b, def);
        // placeRelative inside the already-mirrored item rect (itemGeom).
        const x = if (ui.i18n.direction() == .rtl) ir.x + ir.w - item_hpad - pw else ir.x + item_hpad;
        return .{ .x = x, .y = ir.y, .w = pw, .h = pill_h };
    }
    if (def.label.len > 0) {
        const v = collapsedVerticals(labelMetrics(s, def));
        return .{ .x = ir.x + (ir.w - indicator_w) / 2, .y = ir.y + v.ind_y, .w = indicator_w, .h = ind_h_label };
    }
    return .{ .x = ir.x + (ir.w - ind_h_nolabel) / 2, .y = ir.y + (ir.h - ind_h_nolabel) / 2, .w = ind_h_nolabel, .h = ind_h_nolabel };
}

/// The item under the point (-1 = none), in the widget's parent space.
fn itemAt(s: *RailState, b: Rect, x: f32, y: f32) i32 {
    for (s.items.items, 0..) |_, i| {
        const r = itemGeom(s, b, i);
        if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) return @intCast(i);
    }
    return -1;
}

/// Select an item: the state + the signal (if any) + focus + the a11y
/// value, then on_change. Tab-group semantics: the selection follows.
fn railSelect(n: *Node, index: usize) void {
    const s = stateOf(n);
    if (index >= s.items.items.len) return;
    if (!s.items.items[index].enabled) return;
    s.selected = index;
    input.requestFocus(n); // a clicked/arrow-selected tab takes the focus
    if (s.sig) |sig| sig.set(index); // the sync callback re-reads (idempotent)
    n.markDirty();
    if (n.semantics) |sem| {
        sem.value = s.items.items[index].label; // a11y: the value follows
        for (s.sem_children.items, 0..) |*c, i| c.checked = (i == index);
        ui.semantics.notifyControlChanged(n);
    }
    if (s.on_change) |cb| cb.fn_ptr(cb.userdata);
}

/// The signal -> widget sync (the app moved the selection externally).
fn railSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const v = s.sig.?.peek();
    if (v < s.items.items.len and v != s.selected) {
        s.selected = v;
        if (n.semantics) |sem| {
            sem.value = s.items.items[v].label;
            for (s.sem_children.items, 0..) |*c, i| c.checked = (i == v);
            ui.semantics.notifyControlChanged(n); // a11y follows external changes
        }
        n.markDirty();
    }
}

/// The last selected index (pub accessor).
pub fn selectedIndex(n: *Node) usize {
    return stateOf(n).selected;
}

fn railMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    if (s.opts.expanded) {
        // WideNavigationRailLayout, expanded: width = coerceAtMost(360,
        // max(220, widest item + WNRItemHorizontalPadding)), honoring a
        // nonzero minWidth exactly; fillMaxHeight on the height.
        var widest: f32 = 0;
        const item_max_w = @max(s.opts.theme.platform.hit_target_min, c.max_w - item_hpad);
        for (s.items.items) |def| {
            const lb: Rect = .{ .x = 0, .y = 0, .w = c.max_w, .h = 0 };
            widest = @max(widest, @min(pillWidth(s, lb, def) + item_hpad, item_max_w));
        }
        var w = @min(expanded_max_w, @min(c.max_w, @max(@min(expanded_min_w, c.max_w), widest + item_hpad)));
        if (c.min_w > 0) w = c.min_w;
        const h = if (std.math.isFinite(c.max_h)) c.max_h else wnr_top_pad + @as(f32, @floatFromInt(s.items.items.len)) * pill_h;
        return c.constrain(.{ .w = w, .h = h });
    }
    // WideNavigationRailLayout, collapsed: width = actualMinWidth =
    // CollapsedRailWidth coerceAtMost the parent's max (a nonzero
    // minWidth wins exactly); fillMaxHeight on the height.
    var w = @min(collapsed_w, c.max_w);
    if (c.min_w > 0) w = c.min_w;
    var h = collapsed_top; // ContentPadding.top; bottom padding is 0
    for (s.items.items, 0..) |def, i| {
        if (i > 0) h += item_gap; // ItemVerticalSpace between items
        h += collapsedItemH(s, def);
    }
    const height = if (std.math.isFinite(c.max_h)) c.max_h else h;
    return c.constrain(.{ .w = w, .h = height });
}

fn railLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: the items are computed from the bounds at paint/hit
}

/// Paint an icon centered in a 24x24 box — vector geometry (icon.zig), not
/// a font glyph: text fallback resolves pictographs via the color-emoji
/// font, which ignores the theme ink.
fn paintIcon(ctx: *kx.Ctx, name: icon_w.IconName, x: f32, y: f32, color: Color) void {
    if (color & 0xFF == 0) return;
    icon_w.drawIcon(ctx, name, x, y, icon_size / 24.0, color);
}

fn railPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const cs = t.colors;
    const rtl = ui.i18n.direction() == .rtl;
    const ls = if (s.opts.expanded) t.type_scale.label_large else t.type_scale.label_medium;
    const bold = ls.weight >= 500;
    const group_focused = input.isFocused(n);

    // the container (Surface, CornerNone)
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, cs.surface);

    // the items clip to the rail's bounds: an overflowing destination never
    // paints over nearby content (hit-testing already bounds-checks)
    ui.paint.clipRect(ctx, b.x, b.y, b.w, b.h);
    for (s.items.items, 0..) |def, i| {
        const ir = itemGeom(s, b, i);
        const selected = i == s.selected;
        const has_label = def.label.len > 0;
        const lm = labelMetrics(s, def);
        // content colors: the icon is ItemActiveIcon (OnSecondaryContainer);
        // the label is ItemActiveLabelText (Secondary) in the collapsed
        // top-icon position and ItemActiveIcon (OnSecondaryContainer) in
        // the expanded start-icon position; disabled is the inactive color
        // at DisabledAlpha.
        const icon_c: Color = if (!def.enabled)
            ui.paint.withAlphaScaled(cs.on_surface_variant, 0.38)
        else if (selected)
            cs.on_secondary_container
        else
            cs.on_surface_variant;
        const label_c: Color = if (!def.enabled)
            ui.paint.withAlphaScaled(cs.on_surface_variant, 0.38)
        else if (!selected)
            cs.on_surface_variant
        else if (s.opts.expanded)
            cs.on_secondary_container
        else
            cs.secondary;
        // the indicator geometry — the indication zone (a bounded ripple
        // clipped to it); icon/label offsets stay per-branch like upstream's
        // placeAnimatedLabelAndIcon/placeIcon.
        const ind = indicatorRect(s, b, i);
        var icon_x: f32 = undefined;
        var icon_y: f32 = undefined;
        var label_x: f32 = 0;
        var label_y: f32 = 0;
        if (s.opts.expanded) {
            // placeRelative offsets inside the ITEM: the pill leads
            // WNRItemHorizontalPadding, the icon leads
            // FullWidthLeadingSpace inside it, the label follows the icon +
            // IconLabelSpace. The item rect is already mirrored (itemGeom),
            // so the elements mirror within it — the pill ends up at the
            // item's near edge (ir.w - 20 - pw = 0 for a tight item).
            const im = struct {
                x: f32,
                w: f32,
                rtl: bool,
                fn f(self: @This(), off: f32, w: f32) f32 {
                    return if (self.rtl) self.x + self.w - off - w else self.x + off;
                }
            }{ .x = ir.x, .w = ir.w, .rtl = rtl };
            icon_x = im.f(item_hpad + pill_lead, icon_size);
            icon_y = ir.y + (pill_h - icon_size) / 2;
            label_x = im.f(item_hpad + pill_lead + icon_size + icon_label_gap, lm.width);
            label_y = ir.y + (pill_h - lm.height) / 2;
        } else if (has_label) {
            // placeAnimatedLabelAndIcon at progress 0: the 56x32 indicator
            // centered horizontally (= x + itemHPad 20 in a 96 item), its
            // top at the centered content's top; the icon 4 inside it; the
            // label centered at indicator_bottom + IconLabelSpace 4.
            const v = collapsedVerticals(lm);
            icon_x = ir.x + (ir.w - icon_size) / 2;
            icon_y = ir.y + v.ind_y + ind_ivp;
            label_x = ir.x + (ir.w - lm.width) / 2;
            label_y = ir.y + v.ind_y + ind_h_label + col_icon_label_gap;
        } else {
            // placeIcon: the 56x56 circle + icon centered in the item.
            icon_x = ir.x + (ir.w - icon_size) / 2;
            icon_y = ir.y + (ir.h - icon_size) / 2;
        }
        // the active indicator (CornerFull: a pill, or the icon-only circle)
        if (selected) {
            ui.paint.fillRRect(ctx, ind.x, ind.y, ind.w, ind.h, ind.h / 2, cs.secondary_container);
        }
        // the icon (24dp)
        paintIcon(ctx, def.icon, icon_x, icon_y, icon_c);
        // the label: LabelMedium under the icon (collapsed) / LabelLarge
        // inside the pill (expanded); the rail-bounds clip covers overflow
        if (has_label) {
            ui.paint.text(ctx, def.label, label_x, label_y + lm.ascent, ls.size, bold, label_c);
        }
        // The indication — upstream's indicator ripple composable places
        // LAST in the item (over the icon+label): the animated state layer
        // + the bounded ink ripple over the indicator, clipped CornerFull.
        // A disabled item has no interaction set at all (upstream's
        // enabled=false drops the selectable). The rail's single group
        // focus lands on the SELECTED item's layer.
        if (def.enabled) {
            const fx = &s.fx[i];
            fx.inter.setFocused(group_focused and selected);
            fx.layer.sync(&fx.inter, cs.on_surface);
            if (fx.layer.paintColor()) |lc| {
                ui.paint.fillRRect(ctx, ind.x, ind.y, ind.w, ind.h, ind.h / 2, lc);
            }
            // Ripples.paint reads n.bounds for the clip + geometry — rebind
            // it to the indicator rect (a shallow proxy; only .bounds is
            // consulted).
            if (fx.ripples.live()) {
                var proxy = n.*;
                proxy.bounds = ind;
                fx.ripples.paint(ctx, &proxy, .{ .rrect = ind.h / 2 });
            }
        }
    }
    ui.paint.clipReset(ctx); // the rail-bounds clip
}

/// End an item's live press (release = up, cancel = slop/outside) — the
/// tracker entry and its ripple pair on `press_id`.
fn railEndPress(s: *RailState, i: usize, now_ms: u64, cancel: bool) void {
    const fx = &s.fx[i];
    if (fx.press_id == 0) return;
    if (cancel) fx.inter.cancel(fx.press_id) else fx.inter.release(fx.press_id);
    fx.ripples.release(fx.press_id, now_ms);
    fx.press_id = 0;
}

/// Move the hover interaction to a new item (-1 = none). A disabled item
/// gets no tracker entry (upstream's enabled = false drops the whole
/// interaction set); `hovered` still records it — the geometry/tests use
/// the bookkeeping, the layer the tracker.
fn railSetHover(s: *RailState, idx: i32) void {
    if (idx == s.hovered) return;
    if (s.hovered >= 0) s.fx[@intCast(s.hovered)].inter.endHover();
    s.hovered = idx;
    if (idx >= 0 and s.items.items[@intCast(idx)].enabled) {
        _ = s.fx[@intCast(idx)].inter.hoverEnter();
    }
}

fn railOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    const idx = itemAt(s, n.bounds, ev.x, ev.y);
    switch (ev.phase) {
        .down => {
            if (idx < 0 or !s.items.items[@intCast(idx)].enabled) return false;
            // a second pointer supersedes the live press (single-press
            // bookkeeping — the tracker itself supports more)
            if (s.pressed >= 0) railEndPress(s, @intCast(s.pressed), ev.time_ms, true);
            const i: usize = @intCast(idx);
            const fx = &s.fx[i];
            fx.press_id = fx.inter.pressDown(ev.x, ev.y);
            fx.ripples.spawn(fx.press_id, ev.x, ev.y, ev.time_ms);
            s.pressed = idx;
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            return true;
        },
        .up => {
            const was = s.pressed;
            s.pressed = -1;
            if (was >= 0) {
                const w: usize = @intCast(was);
                railEndPress(s, w, ev.time_ms, false);
                if (idx == was) {
                    // the click's router focus is pointer-provenance —
                    // upstream never emits a Focus interaction on click;
                    // noted BEFORE railSelect's requestFocus so the next
                    // setFocused(true) records .pointer and the layer
                    // stays invisible (focus-visible gating).
                    s.fx[w].inter.noteFocusVia(.pointer);
                    railSelect(n, w);
                }
            }
            return true;
        },
        .move => {
            // A drag beyond the touch slop is a scroll, not a press: cancel
            // the pressed state. The move is NOT claimed (return false) so
            // it keeps bubbling to scrollable ancestors.
            if (s.pressed >= 0) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    railEndPress(s, @intCast(s.pressed), ev.time_ms, true);
                    s.pressed = -1;
                }
            }
            return false;
        },
        // the pointer went down outside while we held the capture: cancel
        .outside_down => {
            if (s.pressed >= 0) {
                railEndPress(s, @intCast(s.pressed), ev.time_ms, true);
                s.pressed = -1;
            }
            return true;
        },
        .enter => {
            railSetHover(s, idx);
            return true;
        },
        // moving across items within the leaf emits hover_move (not
        // enter/leave): re-resolve the item under the pointer
        .hover_move => {
            railSetHover(s, itemAt(s, n.bounds, ev.x, ev.y));
            return true;
        },
        .leave => {
            railSetHover(s, -1);
            return true;
        },
    }
}

/// Keyboard: the rail is a focusable group; up/down move AND select
/// (tab-group semantics), skipping disabled items and wrapping.
fn railOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind != .key_down) return false;
    const count: i32 = @intCast(s.items.items.len);
    if (count == 0) return false;
    switch (ev.key) {
        .up, .down => {
            const step: i32 = if (ev.key == .down) 1 else -1;
            var i: i32 = @intCast(@min(s.selected, s.items.items.len - 1));
            var guard: i32 = 0;
            while (guard < count) : (guard += 1) {
                i = @mod(i + step, count);
                if (s.items.items[@intCast(i)].enabled) break;
            }
            railSelect(n, @intCast(i));
            return true;
        },
        .enter, .space => {
            // Activate the focused item — the group's selected one
            // (selection-follows-focus means it's already selected; the
            // key press still emits the upstream activation ripple at the
            // indicator's center and re-fires on_change like a click).
            const i = @min(s.selected, s.items.items.len - 1);
            const fx = &s.fx[i];
            const ind = indicatorRect(s, n.bounds, i);
            const cx = ind.x + ind.w / 2;
            const cy = ind.y + ind.h / 2;
            const pid = fx.inter.pressDown(cx, cy);
            fx.ripples.spawn(pid, cx, cy, 0);
            fx.inter.release(pid);
            fx.ripples.release(pid, 0);
            railSelect(n, i);
            return true;
        },
        else => {},
    }
    return false;
}

fn railDeinit(n: *Node) void {
    const s = stateOf(n);
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = railSyncCb, .userdata = n } });
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = railLocaleCb, .userdata = n });
    input.releaseNode(n);
    // in-flight tween userdata = `l` / live ticker userdata = `r` — both
    // die with the state struct; cancel before freeing.
    for (s.fx) |*fx| {
        fx.layer.deinit();
        fx.ripples.deinit();
    }
    n.allocator.free(s.fx);
    for (s.items.items) |*def| n.allocator.free(def.label);
    s.items.deinit();
    s.sem_children.deinit();
    n.allocator.destroy(s);
}

/// The group label is tr()-resolved — the locale callback re-attaches in
/// the new locale (the item children are app strings, verbatim).
fn attachRailSemantics(n: *Node) void {
    const s = stateOf(n);
    ui.semantics.attach(n, .{
        .role = .group, // a tab group (single choice)
        .label = i18n_mod.tr("Navigation rail"),
        .focusable = true, // takes the keyboard focus (arrow nav)
        .value = if (s.items.items.len > 0) s.items.items[s.selected].label else "",
        .children = s.sem_children.items,
        .child_bounds = railChildBounds,
    });
}

fn railLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    attachRailSemantics(n);
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

const rail_vtable = ui.node.VTable{
    .measure = railMeasure,
    .layout = railLayout,
    .paint = railPaint,
    .deinit = railDeinit,
    .on_pointer = railOnPointer,
    .on_key = railOnKey,
};

/// An M3E navigation rail. The items are internal chrome painted by the
/// widget (a leaf — no document children). `items` are copied (the labels
/// are owned). `sig` drives the selection (round-trips); `on_change` fires
/// with `selectedIndex(n)` valid after a click or an arrow-key selection.
pub fn navigationRail(allocator: std.mem.Allocator, items: []const NavRailItem, sig: ?*ui.state.Signal(usize), on_change: ?Callback, opts: NavigationRailOptions) !*Node {
    const node = try Node.create(allocator, &rail_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(RailState);
    errdefer allocator.destroy(s);
    s.* = .{
        .items = std.array_list.Managed(ItemDef).init(allocator),
        .sem_children = std.array_list.Managed(ui.semantics.Semantics).init(allocator),
        .opts = opts,
        .sig = sig,
        .on_change = on_change,
        .selected = opts.selected,
    };
    // One ownership boundary: on ANY failure this errdefer frees the
    // appended defs' labels (railDeinit owns them only once returned).
    errdefer {
        for (s.items.items) |*def| allocator.free(def.label);
        s.items.deinit();
    }
    for (items) |item| {
        const label = try dupeZ(allocator, item.label);
        errdefer allocator.free(label); // iteration scope: freed only if THIS iteration fails before the append
        // No catch-free here: on append failure the errdefer frees the copy.
        try s.items.append(.{ .label = label, .icon = item.icon, .enabled = item.enabled });
    }
    node.state = s;
    // The per-item indication set (upstream's per-item interactionSource +
    // the indicator composable's ripple): mutations + ticks damage the rail
    // node; the layer alphas + ripple ink come straight from the theme (the
    // rail's contentColor = OnSurface).
    s.fx = try allocator.alloc(ItemFx, s.items.items.len);
    errdefer allocator.free(s.fx);
    for (s.fx) |*fx| {
        fx.* = .{};
        fx.inter.node = node;
        fx.layer.node = node;
        fx.layer.alphas = .{ .hover = opts.theme.state.hover, .focus = opts.theme.state.focus, .pressed = opts.theme.state.pressed, .drag = opts.theme.state.drag };
        fx.ripples.node = node;
        fx.ripples.color = opts.theme.colors.on_surface;
        fx.ripples.pressed_alpha = opts.theme.state.pressed;
    }
    if (sig) |sg| {
        sg.subscribe(.{ .callback = .{ .fn_ptr = railSyncCb, .userdata = node } });
        const v = sg.peek();
        if (v < s.items.items.len) s.selected = v; // the signal wins
    }
    if (s.selected >= s.items.items.len) s.selected = 0; // clamp bad data
    // Per-destination virtual a11y children — VoiceOver reads/selects
    // each tab, not just an opaque group.
    for (s.items.items, 0..) |*def, i| {
        s.sem_children.append(.{
            .role = .tab,
            .label = def.label,
            .checked = i == s.selected,
            .disabled = !def.enabled,
            .actions = ui.semantics.Actions.initOne(.activate),
        }) catch @panic("klaxon: out of memory");
    }
    attachRailSemantics(node); // Phase 2c
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = railLocaleCb, .userdata = node });
    return node;
}

// --- tests ---

fn changeCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "navigation_rail: measures the collapsed 96dp width; expanded clamps to [220, 360]; height fills" {
    const a = std.testing.allocator;
    const t = theme_mod.light;
    const items = [_]NavRailItem{ .{ .label = "Home", .icon = .home }, .{ .label = "Music", .icon = .play } };
    const c = try navigationRail(a, &items, null, null, .{ .theme = t });
    defer c.deinit();
    const m = c.measure(.{ .max_w = 2000, .max_h = std.math.inf(f32) });
    try std.testing.expectEqual(collapsed_w, m.w);
    // 44dp top + item(64) + 4 gap + item(64); no bottom padding
    const s = stateOf(c);
    try std.testing.expectEqual(collapsed_top + collapsedItemH(s, s.items.items[0]) + item_gap + collapsedItemH(s, s.items.items[1]), m.h);
    // fills a bounded height
    const mf = c.measure(.{ .max_w = 2000, .max_h = 400 });
    try std.testing.expectEqual(@as(f32, 400), mf.h);
    // expanded: the rail is the widest item (pill + 20) + 20 clamped to
    // [220, 360] — item + pill are capped by the parent's max width
    const e = try navigationRail(a, &items, null, null, .{ .expanded = true, .theme = t });
    defer e.deinit();
    const ls = t.type_scale.label_large;
    const lw = ui.paint.measureText("Music", ls.size, true).width;
    const pw = icon_size + icon_label_gap + lw + pill_lead * 2;
    const em = e.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(@max(expanded_min_w, pw + item_hpad * 2), em.w, 0.001);
    // a long label clamps at 360
    const long = try navigationRail(a, &.{.{ .label = "A very long destination label that overflows" }}, null, null, .{ .expanded = true, .theme = t });
    defer long.deinit();
    try std.testing.expectEqual(expanded_max_w, long.measure(.{ .max_w = 2000, .max_h = 2000 }).w);
}

test "navigation_rail: click selects (signal + on_change + focus); arrows move AND select; a11y follows" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = changeCounterCb, .userdata = &count };
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sig.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try navigationRail(a, &.{
        .{ .label = "Home", .icon = .home },
        .{ .label = "Music", .icon = .play, .enabled = false },
        .{ .label = "Books", .icon = .star },
    }, sig, cb, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 96, .h = 400 });
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n));
    try std.testing.expectEqualStrings("Home", n.semantics.?.value);
    // click the 3rd item (the 2nd is disabled)
    const r3 = itemGeom(stateOf(n), n.bounds, 2);
    const y3 = r3.y + r3.h / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 40, .y = y3, .raw_x = 40, .raw_y = y3 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 40, .y = y3, .raw_x = 40, .raw_y = y3 });
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(n));
    try std.testing.expectEqual(@as(usize, 2), sig.peek()); // the signal round-trips
    try std.testing.expectEqual(@as(u32, 1), count); // on_change fired
    try std.testing.expect(input.isFocused(n)); // the click focused the group
    try std.testing.expectEqualStrings("Books", n.semantics.?.value); // a11y follows
    // keyboard: up wraps AND selects (skipping the disabled middle item)
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .up });
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n)); // wrapped from 2 (1 disabled)
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(n)); // 0 -> skips 1 -> 2
    try std.testing.expectEqual(@as(u32, 3), count);
    // the external signal moves the selection too
    sig.set(0);
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n));
    try std.testing.expectEqualStrings("Home", n.semantics.?.value);
}

test "navigation_rail: semantics — role group, focusable, value follows the selection" {
    const a = std.testing.allocator;
    const n = try navigationRail(a, &.{ .{ .label = "A" }, .{ .label = "B" } }, null, null, .{ .selected = 1 });
    defer n.deinit();
    try std.testing.expectEqual(ui.semantics.Role.group, n.semantics.?.role);
    try std.testing.expect(n.semantics.?.focusable);
    try std.testing.expectEqualStrings("B", n.semantics.?.value);
    try std.testing.expectEqual(@as(usize, 1), selectedIndex(n));
}

test "golden: collapsed — the selected item paints the 56x32 pill + OnSecondaryContainer icon + Secondary label" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try navigationRail(a, &.{
        .{ .label = "Home", .icon = .home },
        .{ .label = "Music", .icon = .play },
    }, null, null, .{ .selected = 0, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(a, 120, 200);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 96, .h = 180 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    const s = stateOf(n);
    const ir = itemGeom(s, n.bounds, 0);
    const lm = labelMetrics(s, s.items.items[0]);
    const v = collapsedVerticals(lm);
    // the rail background: surface
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(15, 15));
    // the first item's 56x32 pill: centered horizontally, at the centered
    // content's top + 16 (its vertical center)
    const ind_x = ir.x + (ir.w - indicator_w) / 2;
    const ind_y = ir.y + v.ind_y;
    // the pill's interior (4dp inside the left edge — the edge itself is
    // AA'd and Skia's rrect fill rounding differs ±1): secondary_container
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(@as(i32, @intFromFloat(ind_x)) + 4, @intFromFloat(ind_y + 16)));
    // above the pill stays background
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(@intFromFloat(ind_x + 28), @intFromFloat(ind_y - 1)));
    // the icon ink (on_secondary_container) inside the pill
    try std.testing.expect(f.countColorIn(.{ .x = ir.x + (ir.w - 24) / 2, .y = ir.y + v.ind_y + ind_ivp, .w = 24, .h = 24 }, t.colors.on_secondary_container) > 0);
    // the LabelMedium label ink (secondary) below the icon
    const label_y = ir.y + v.ind_y + ind_h_label + col_icon_label_gap;
    try std.testing.expect(f.countColorIn(.{ .x = ir.x, .y = label_y, .w = ir.w, .h = lm.height }, t.colors.secondary) > 0);
    // the second (unselected) item: no indicator — plain surface in the
    // indicator zone; on_surface_variant icon + label ink
    const ir2 = itemGeom(s, n.bounds, 1);
    const v2 = collapsedVerticals(labelMetrics(s, s.items.items[1]));
    // the zone's left edge (off the centered 24dp icon) stays surface
    const ind2_x = ir2.x + (ir2.w - indicator_w) / 2;
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(@as(i32, @intFromFloat(ind2_x)) + 2, @intFromFloat(ir2.y + v2.ind_y + 16)));
    try std.testing.expect(f.countColorIn(.{ .x = ir2.x + (ir2.w - 24) / 2, .y = ir2.y + v2.ind_y + ind_ivp, .w = 24, .h = 24 }, t.colors.on_surface_variant) > 0);
    const label2_y = ir2.y + v2.ind_y + ind_h_label + col_icon_label_gap;
    try std.testing.expect(f.countColorIn(.{ .x = ir2.x, .y = label2_y, .w = ir2.w, .h = lm.height }, t.colors.on_surface_variant) > 0);
}

test "golden: expanded — the selected item paints the pill (label_w + 64) at x = 20 + icon + label ink" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try navigationRail(a, &.{
        .{ .label = "Home", .icon = .home },
        .{ .label = "Music", .icon = .play },
    }, null, null, .{ .expanded = true, .selected = 1, .theme = t });
    defer n.deinit();
    const ls = t.type_scale.label_large;
    const lw = ui.paint.measureText("Music", ls.size, true).width;
    const pw = icon_size + icon_label_gap + lw + pill_lead * 2;
    var r = try golden.Renderer.init(a, 300, 200);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 260, .h = 180 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    // the second item's row: y = 10 + 44 + 56 = 110 (items space 0 apart)
    const iy = 10 + wnr_top_pad + pill_h;
    // the pill: x = 10 + 20 = 30, w = pw, h = 56 → its interior midpoints
    // (4dp inside the edges — the edges themselves are AA'd)
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(34, @intFromFloat(iy + pill_h / 2)));
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(@as(i32, @intFromFloat(30 + pw)) - 4, @intFromFloat(iy + pill_h / 2)));
    // just past the pill: surface again
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(@as(i32, @intFromFloat(30 + pw)) + 4, @intFromFloat(iy + pill_h / 2)));
    // the icon ink (on_secondary_container) at pill_x + 16
    try std.testing.expect(f.countColorIn(.{ .x = 30 + pill_lead, .y = iy + 16, .w = 24, .h = 24 }, t.colors.on_secondary_container) > 0);
    // the label ink (on_secondary_container, start-icon position) at icon_x + 32
    try std.testing.expect(f.countColorIn(.{ .x = 30 + pill_lead + icon_size + icon_label_gap, .y = iy + 18, .w = lw, .h = 20 }, t.colors.on_secondary_container) > 0);
    // the first (unselected) item: no pill
    const iy0 = 10 + wnr_top_pad;
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(30, @intFromFloat(iy0 + pill_h / 2)));
    // the unselected label ink (on_surface_variant)
    try std.testing.expect(f.countColorIn(.{ .x = 30 + pill_lead + icon_size + icon_label_gap, .y = iy0 + 18, .w = 60, .h = 20 }, t.colors.on_surface_variant) > 0);
}

test "golden: a hovered item paints the OnSurface state layer over the indicator" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try navigationRail(a, &.{ .{ .label = "Home", .icon = .home }, .{ .label = "Music", .icon = .play } }, null, null, .{ .selected = 0, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(a, 120, 200);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 96, .h = 180 });
    // hover the 2nd (unselected) item — the tracker's hover feeds the
    // animated state layer (no timeline → it snaps to the target alpha)
    const s = stateOf(n);
    const ir2 = itemGeom(s, n.bounds, 1);
    const y2 = ir2.y + ir2.h / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .enter, .x = ir2.x + ir2.w / 2, .y = y2 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    // the state layer: on_surface @ 0.08 over the surface (the rail's
    // contentColor — the upstream ripple's LocalContentColor), at the
    // pill's left edge midpoint (the unselected indicator zone)
    const v2 = collapsedVerticals(labelMetrics(s, s.items.items[1]));
    const ind_x = ir2.x + (ir2.w - indicator_w) / 2;
    const ind_y = ir2.y + v2.ind_y;
    try golden.expectPixelApprox(f, @as(i32, @intFromFloat(ind_x)) + 1, @intFromFloat(ind_y + ind_h_label / 2), golden.blendOver(ui.state_layer.copyAlpha(t.colors.on_surface, t.state.hover), t.colors.surface));
}

test "navigation_rail: hover_move re-resolves the item under the pointer" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try navigationRail(a, &.{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } }, null, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 96, .h = 400 });
    const s = stateOf(n);
    // hover the 1st item, then move across to the 3rd within the leaf
    const r0 = itemGeom(s, n.bounds, 0);
    router.dispatchPointer(n, .{ .phase = .move, .x = r0.x + r0.w / 2, .y = r0.y + 10 });
    try std.testing.expectEqual(@as(i32, 0), s.hovered);
    const r2 = itemGeom(s, n.bounds, 2);
    router.dispatchPointer(n, .{ .phase = .move, .x = r2.x + r2.w / 2, .y = r2.y + 10 });
    try std.testing.expectEqual(@as(i32, 2), s.hovered);
    // moving above the items clears the highlight (leave)
    router.dispatchPointer(n, .{ .phase = .move, .x = 40, .y = 1 });
    try std.testing.expectEqual(@as(i32, -1), s.hovered);
}

test "navigation_rail: RTL mirrors the expanded row (the icon sits at the end side)" {
    const a = std.testing.allocator;
    const i18n = try ui.i18n.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    const t = theme_mod.light;
    const n = try navigationRail(a, &.{.{ .label = "Home", .icon = .home }}, null, null, .{ .expanded = true, .selected = 0, .theme = t });
    defer n.deinit();
    const ls = t.type_scale.label_large;
    const lw = ui.paint.measureText("Home", ls.size, true).width;
    const pw = icon_size + icon_label_gap + lw + pill_lead * 2;
    var r = try golden.Renderer.init(a, 300, 200);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 260, .h = 180 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    const iy = 10 + wnr_top_pad;
    // the pill is mirrored: the item sits at the end edge (x = 260 - pw -
    // 20), its pill at the item's near edge → 10 + 260 - 20 - pw
    const pill_x = 10 + 260 - item_hpad - pw;
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(@as(i32, @intFromFloat(pill_x)) + 4, @intFromFloat(iy + pill_h / 2)));
    // the icon ink moved to the end side (pill end - 16 - 24)
    try std.testing.expect(f.countColorIn(.{ .x = pill_x + pw - pill_lead - icon_size, .y = iy + 16, .w = 24, .h = 24 }, t.colors.on_secondary_container) > 0);
}

test "navigation_rail: an empty rail measures the padding, not the items" {
    const a = std.testing.allocator;
    const n = try navigationRail(a, &.{}, null, null, .{});
    defer n.deinit();
    const m = n.measure(.{ .max_w = 2000, .max_h = std.math.inf(f32) });
    try std.testing.expectEqual(collapsed_top, m.h); // collapsed: 44 top, 0 bottom
    const e = try navigationRail(a, &.{}, null, null, .{ .expanded = true });
    defer e.deinit();
    const em = e.measure(.{ .max_w = 2000, .max_h = std.math.inf(f32) });
    try std.testing.expectEqual(wnr_top_pad, em.h); // expanded: 44 top
}

test "golden: an icon-only collapsed item paints the 56x56 circle" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try navigationRail(a, &.{.{ .label = "", .icon = .home }}, null, null, .{ .selected = 0, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(a, 120, 120);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 96, .h = 100 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    // the item spans the 96-wide rail at y = 10 + 44 = 54; the 56x56
    // circle centers in the 64-tall item → x = 10 + (96-56)/2 = 30,
    // y = 54 + 4 = 58; center at (58, 86)
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(34, 86));
    // the exact circle corner stays background (a circle, not a square)
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(30, 58));
    // the icon ink (on_secondary_container) at the center
    try std.testing.expect(f.countColorIn(.{ .x = 46, .y = 74, .w = 24, .h = 24 }, t.colors.on_secondary_container) > 0);
}

test "golden: an overflowing rail clips its items to its bounds" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    // 4 items need 44 + 4*64 + 3*4 = 312; the rail gets 180 — the last two
    // items overflow and must not paint below the rail's bottom edge (190)
    const n = try navigationRail(a, &.{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" }, .{ .label = "D" } }, null, null, .{ .selected = 3, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(a, 120, 220);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 96, .h = 180 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    const s = stateOf(n);
    // the 4th (selected) item sits below the rail's bottom edge: nothing
    // paints there
    const r3 = itemGeom(s, n.bounds, 3);
    try std.testing.expect(r3.y + r3.h > 190);
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(50, 200));
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(50, 210));
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(50, 195));
    // control: inside the rail the unselected items paint normally — no
    // indicator (surface in the indicator zone), but their icon ink shows
    const r1 = itemGeom(s, n.bounds, 1);
    const v1 = collapsedVerticals(labelMetrics(s, s.items.items[1]));
    const ind_x = r1.x + (r1.w - indicator_w) / 2;
    const ind_y = r1.y + v1.ind_y;
    // the zone's left edge (off the centered 24dp icon) stays surface
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(@as(i32, @intFromFloat(ind_x)) + 2, @intFromFloat(ind_y + 16)));
    try std.testing.expect(f.countColorIn(.{ .x = r1.x + (r1.w - 24) / 2, .y = r1.y + v1.ind_y + ind_ivp, .w = 24, .h = 24 }, t.colors.on_surface_variant) > 0); // item 1's icon
}

test "navigation_rail: i18n — the framework label localizes + re-resolves on a locale switch" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Navigation rail\": \"Barra lateral\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const items = [_]NavRailItem{ .{ .label = "Home", .icon = .home }, .{ .label = "Music", .icon = .play } };
    const n = try navigationRail(a, &items, null, null, .{});
    defer n.deinit();
    try std.testing.expectEqualStrings("Barra lateral", n.semantics.?.label);
    try i18n.setLocale("en");
    const sem = n.semantics.?; // re-attached by the locale callback
    try std.testing.expectEqualStrings("Navigation rail", sem.label);
    // the virtual children survive the re-attach (app labels, verbatim)
    try std.testing.expectEqual(@as(usize, 2), sem.children.len);
    try std.testing.expectEqualStrings("Home", sem.children[0].label);
}
