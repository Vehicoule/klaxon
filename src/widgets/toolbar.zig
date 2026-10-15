// Floating toolbar (M3E) — a pill-shaped container floating above content,
// packing 24dp icon actions (plus optional vertical-divider group
// separators) and an optional FAB docked inside the end padding. Standard
// and vibrant variants; each item owns its own on_press callback — a
// toolbar of actions, not a selection control (no selection signal).
//
// Spec: m3.material.io/components/toolbars + Compose FloatingToolbar.kt
// (HorizontalFloatingToolbar / FloatingToolbarDefaults):
//   - container: a 56dp CornerFull pill (radius = h/2), SurfaceContainer —
//     the M3E "vibrant" variant swaps in TertiaryContainer — lifted 3dp
//     (the elevationShadow level is dp) above the content
//   - children: standard icon buttons = 48dp cells (the a11y touch-target
//     floor) with the 24dp icon centered, 8dp between cells, 16dp end
//     padding
//   - colors: icons OnSurfaceVariant; vibrant = OnTertiaryContainer;
//     disabled = OnSurface @ 0.38; state layers = the on-color blended
//     over the (opaque) container at hover 0.08 / focus 0.10 / pressed
//     0.12 (theme.state)
//   - divider (`.divider = true` on an item): a group separator — 1dp
//     OutlineVariant line, 24dp long, cell = the thickness (the 8dp gaps
//     space it from its neighbours)
//   - docked FAB (the vibrant look): a 48dp CornerLarge (16dp) squircle,
//     PrimaryContainer + OnPrimaryContainer icon, small elevation — v1
//     docks it INSIDE the end padding (the spec look overlaps the pill's
//     end edge by ~8dp)
//   - input: per-item down/up press (a drag past the touch slop —
//     gestures.SLOP, raw coords — is a scroll, not a press); hover
//     tracking; left/right arrows move the ACTIVE item (RTL flips),
//     Enter/Space activates it; a pressed slot takes the keyboard focus
//     so the arrows continue from it
//   - semantics: a focusable group exposing virtual children — a button
//     per action, a separator per divider, a trailing button for the FAB;
//     a targeted activation dispatches a tap at the child's rect, hit-
//     tested like a real pointer
//   - RTL: the row mirrors — the first item sits at the end side and the
//     FAB docks at the start edge
//
// v1 deviations (documented, fixed later):
//   - Fixed 56dp height: the vibrant/FAB-docked 64dp container token and
//     the FAB's ~8dp pill-edge overlap are not implemented (the FAB docks
//     inside the 16dp end padding).
//   - Ripple-less: the state layer paints instantly (the M3E ripple lands
//     with the animation system, Phase 3).
//   - No overflow scrolling — a narrower-than-intrinsic assignment clips
//     the end items inside the pill (the content row centers when wider).
//   - The slots are chrome painted by the widget (a leaf — no document
//     children); Compose's FloatingToolbar takes arbitrary composable
//     children, v1 is icon actions + dividers only.
//   - up/down arrows are NOT claimed (they bubble to scrollables) — only
//     left/right move the active item in the horizontal pill.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
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

/// One toolbar slot: an icon action, or a group separator when `divider`
/// is set (icon/on_press/enabled are then ignored). The factory copies
/// `a11y_label`; null names the item after its icon's tag ("search", ...).
pub const ToolbarItem = struct {
    icon: icon_w.IconName = .star,
    on_press: ?Callback = null,
    enabled: bool = true,
    /// The accessible name (null = the icon's tag name).
    a11y_label: ?[]const u8 = null,
    /// true = a 1dp x 24dp OutlineVariant vertical separator, not a button.
    divider: bool = false,
};

pub const ToolbarOptions = struct {
    /// M3E vibrant variant: TertiaryContainer pill + OnTertiaryContainer
    /// content (the standard variant is SurfaceContainer/OnSurfaceVariant).
    vibrant: bool = false,
    /// A 48dp PrimaryContainer FAB docked inside the END padding (null =
    /// no FAB slot).
    fab_icon: ?icon_w.IconName = null,
    on_fab_press: ?Callback = null,
    /// The docked FAB's accessible name (an icon-only control).
    fab_a11y_label: []const u8 = "Action",
    /// The group's accessible name.
    a11y_label: []const u8 = "Toolbar",
    theme: Theme = theme_mod.light,
};

/// M3E tokens (FloatingToolbarTokens + FloatingToolbarDefaults).
const bar_height: f32 = 56; // standard ContainerHeight (vibrant+fab = 64: v1 keeps 56)
const h_pad: f32 = 16; // horizontal end padding
const item_cell: f32 = 48; // a standard icon-button cell (the a11y floor)
const icon_size: f32 = 24; // IconSize
const item_gap: f32 = 8; // spacing between the cells
const divider_w: f32 = 1; // the separator's thickness
const divider_h: f32 = 24; // the separator's length
const fab_size: f32 = 48; // docked FAB container
const fab_corner: f32 = 16; // CornerLarge squircle
const fab_icon_size: f32 = 24;
const bar_elevation: f32 = 3; // the floating pill's lift (dp)
const fab_elevation: f32 = 2; // the docked FAB's lift (dp)
const min_target: f32 = 48; // a11y touch-target floor
const shadow_spill: f32 = 16; // paint/damage overflow covering the shadows

const ItemDef = struct {
    label: [:0]const u8, // owned
    icon: icon_w.IconName,
    on_press: ?Callback,
    enabled: bool,
    divider: bool,
};

const ToolbarState = struct {
    items: std.array_list.Managed(ItemDef), // owned defs
    /// Live per-slot a11y descriptors — the semantics tree's virtual
    /// children borrow this slice (item slots, then the trailing FAB).
    sem_children: std.array_list.Managed(ui.semantics.Semantics),
    opts: ToolbarOptions,
    fab_label: [:0]const u8, // owned
    /// The slot index under the finger/pen — items.len = the docked FAB
    /// (-1 = none).
    pressed: i32 = -1,
    hovered: i32 = -1,
    /// The keyboard-active slot (arrows move it; Enter/Space activates it;
    /// the focus state layer paints on it while the group is focused).
    active: i32 = -1,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — gestures.SLOP).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
};

fn stateOf(n: *Node) *ToolbarState {
    return @ptrCast(@alignCast(n.state.?));
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

fn hasFab(s: *const ToolbarState) bool {
    return s.opts.fab_icon != null;
}

fn cellW(def: ItemDef) f32 {
    return if (def.divider) divider_w else item_cell;
}

/// The virtual slot count: the item cells, then the docked FAB.
fn slotCount(s: *const ToolbarState) usize {
    return s.items.items.len + @intFromBool(hasFab(s));
}

/// Interactive slots only (an enabled action, or the always-on FAB).
fn pressable(s: *const ToolbarState, idx: i32) bool {
    if (idx < 0) return false;
    const i: usize = @intCast(idx);
    if (i == s.items.items.len) return hasFab(s);
    return i < s.items.items.len and s.items.items[i].enabled and !s.items.items[i].divider;
}

/// The row's intrinsic width (the end paddings, the FAB slot included).
fn contentWidth(s: *const ToolbarState) f32 {
    const count = s.items.items.len;
    var w: f32 = h_pad * 2;
    for (s.items.items) |def| w += cellW(def);
    if (count > 0) w += @as(f32, @floatFromInt(count - 1)) * item_gap;
    if (hasFab(s)) w += (if (count > 0) item_gap else 0) + fab_size;
    return w;
}

/// The content block's left edge: centered in any slack (the pill hugs its
/// content at intrinsic size), start-pinned — then clipped — when narrower.
fn contentX(s: *const ToolbarState, b: Rect) f32 {
    return b.x + @max(0, (b.w - contentWidth(s)) / 2);
}

/// Slot `index`'s rect in LTR space: 0..items.len = the item cells (a
/// divider's is its 1dp x 24dp line), items.len = the FAB docked inside
/// the end padding. The caller mirrors for RTL.
fn slotRectLtr(s: *const ToolbarState, b: Rect, index: usize) Rect {
    const count = s.items.items.len;
    if (index == count) {
        return .{
            .x = contentX(s, b) + contentWidth(s) - h_pad - fab_size,
            .y = b.y + (b.h - fab_size) / 2,
            .w = fab_size,
            .h = fab_size,
        };
    }
    var x = contentX(s, b) + h_pad;
    for (0..index) |i| x += cellW(s.items.items[i]) + item_gap;
    const def = s.items.items[index];
    if (def.divider) {
        return .{ .x = x, .y = b.y + (b.h - divider_h) / 2, .w = divider_w, .h = divider_h };
    }
    return .{ .x = x, .y = b.y + (b.h - item_cell) / 2, .w = item_cell, .h = item_cell };
}

fn mirrorX(b: Rect, r: Rect) Rect {
    return .{ .x = b.x + b.w - (r.x - b.x) - r.w, .y = r.y, .w = r.w, .h = r.h };
}

/// Slot `index`'s rect in the widget's parent space (RTL mirrors).
fn slotRect(s: *const ToolbarState, b: Rect, index: usize) Rect {
    var r = slotRectLtr(s, b, index);
    if (ui.i18n.direction() == .rtl) r = mirrorX(b, r);
    return r;
}

/// The slot under the point (-1 = none), in the widget's parent space. The
/// whole pill column is the target — the cells' tight 48dp height is only
/// the painted affordance.
fn slotAt(s: *const ToolbarState, b: Rect, x: f32, y: f32) i32 {
    if (y < b.y or y >= b.y + b.h) return -1;
    for (0..slotCount(s)) |i| {
        const r = slotRect(s, b, i);
        if (x >= r.x and x < r.x + r.w) return @intCast(i);
    }
    return -1;
}

/// Slot `index`'s rect in NODE-LOCAL space (Semantics.child_bounds — the
/// a11y bridge maps it to window space for highlights and activation taps).
fn slotChildBounds(n: *Node, index: usize) Rect {
    const s = stateOf(n);
    const local = Rect{ .x = 0, .y = 0, .w = n.bounds.w, .h = n.bounds.h };
    return slotRect(s, local, index);
}

/// The next pressable slot from `from` stepping `step`, wrapping (-1 =
/// none — an all-disabled, FAB-less toolbar has nothing to move to).
fn nextPressable(s: *const ToolbarState, from: i32, step: i32) i32 {
    const total: i32 = @intCast(slotCount(s));
    if (total == 0) return -1;
    var i: i32 = from;
    var guard: i32 = 0;
    while (guard < total) : (guard += 1) {
        i = @mod(i + step, total);
        if (pressable(s, i)) return i;
    }
    return -1;
}

/// Fire a slot's callback: an item's on_press, or the docked FAB's
/// on_fab_press (index == items.len). Inert slots do nothing.
fn slotActivate(n: *Node, idx: usize) void {
    const s = stateOf(n);
    if (idx == s.items.items.len) {
        if (hasFab(s)) {
            s.active = @intCast(idx);
            if (s.opts.on_fab_press) |cb| cb.fn_ptr(cb.userdata);
        }
        return;
    }
    if (!pressable(s, @intCast(idx))) return;
    s.active = @intCast(idx);
    if (s.items.items[idx].on_press) |cb| cb.fn_ptr(cb.userdata);
}

fn toolbarMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    return c.constrain(.{ .w = contentWidth(s), .h = bar_height });
}

fn toolbarLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: the slots are computed from the bounds at paint/hit
}

/// Paint an icon in a size x size box — vector geometry (icon.zig), not a
/// font glyph.
fn paintIcon(ctx: *kx.Ctx, name: icon_w.IconName, x: f32, y: f32, size: f32, color: Color) void {
    if (color & 0xFF == 0) return;
    icon_w.drawIcon(ctx, name, x, y, size / 24.0, color);
}

fn toolbarPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const cs = t.colors;
    const b = n.bounds;
    const container: Color = if (s.opts.vibrant) cs.tertiary_container else cs.surface_container;
    const on: Color = if (s.opts.vibrant) cs.on_tertiary_container else cs.on_surface_variant;
    const focused = input.isFocused(n);
    // the floating pill: a level-3 ambient+spot shadow under the CornerFull
    // container (the spill is declared via damage_overflow at init)
    ui.paint.elevationShadow(ctx, b.x, b.y, b.w, b.h, b.h / 2, bar_elevation, cs.shadow);
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, b.h / 2, container);
    // the slots clip to the pill: a narrower-than-intrinsic assignment
    // truncates the end items instead of painting outside the node
    ui.paint.clipRect(ctx, b.x, b.y, b.w, b.h);
    for (0..slotCount(s)) |i| {
        const idx: i32 = @intCast(i);
        const r = slotRect(s, b, i);
        const is_fab = i == s.items.items.len;
        if (!is_fab and s.items.items[i].divider) {
            ui.paint.fillRect(ctx, r.x, r.y, r.w, r.h, cs.outline_variant);
            continue;
        }
        const base: Color = if (is_fab) cs.primary_container else container;
        const on_c: Color = if (is_fab) cs.on_primary_container else on;
        const enabled = pressable(s, idx);
        if (is_fab) {
            // the docked FAB: a small lift under the CornerLarge squircle
            ui.paint.elevationShadow(ctx, r.x, r.y, r.w, r.h, fab_corner, fab_elevation, cs.shadow);
            ui.paint.fillRRect(ctx, r.x, r.y, r.w, r.h, fab_corner, cs.primary_container);
        }
        // the state layer (enabled slots only): the on-color blended over
        // the container — an opaque lerp, the container is always opaque
        if (enabled) {
            const alpha: f32 = if (s.pressed == idx)
                t.state.pressed
            else if (focused and s.active == idx)
                t.state.focus
            else if (s.hovered == idx)
                t.state.hover
            else
                0;
            if (alpha > 0) {
                const layer = theme_mod.stateLayer(base, on_c, alpha);
                ui.paint.fillRRect(ctx, r.x, r.y, r.w, r.h, if (is_fab) fab_corner else r.h / 2, layer);
            }
        }
        // the icon (centered in the cell; disabled = OnSurface @ 0.38)
        const fg: Color = if (enabled) on_c else ui.paint.withAlphaScaled(cs.on_surface, 0.38);
        const isz: f32 = if (is_fab) fab_icon_size else icon_size;
        const icon_name = if (is_fab) s.opts.fab_icon.? else s.items.items[i].icon;
        paintIcon(ctx, icon_name, r.x + (r.w - isz) / 2, r.y + (r.h - isz) / 2, isz, fg);
    }
    ui.paint.clipReset(ctx); // the pill-bounds clip
}

fn toolbarOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    const idx = slotAt(s, n.bounds, ev.x, ev.y);
    switch (ev.phase) {
        .down => {
            if (!pressable(s, idx)) return false;
            s.pressed = idx;
            s.active = idx;
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            input.requestFocus(n); // a pressed slot takes the keyboard focus
            n.markDirty();
            return true;
        },
        .up => {
            const was = s.pressed;
            s.pressed = -1;
            n.markDirty();
            if (was >= 0 and idx == was) slotActivate(n, @intCast(was));
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
                    s.pressed = -1;
                    n.markDirty();
                }
            }
            return false;
        },
        // the pointer went down outside while we held the capture: cancel
        .outside_down => {
            s.pressed = -1;
            n.markDirty();
            return true;
        },
        .enter => {
            s.hovered = idx;
            n.markDirty();
            return true;
        },
        // moving across slots within the leaf emits hover_move (not
        // enter/leave): re-resolve the slot under the pointer
        .hover_move => {
            if (idx != s.hovered) {
                s.hovered = idx;
                n.markDirty();
            }
            return true;
        },
        .leave => {
            s.hovered = -1;
            n.markDirty();
            return true;
        },
    }
    return false;
}

/// Keyboard: the group is focusable; left/right move the ACTIVE slot,
/// skipping dividers and disabled items and wrapping (RTL flips
/// left/right); Enter/Space activates it.
fn toolbarOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .left, .right => {
            const rtl = ui.i18n.direction() == .rtl;
            var step: i32 = if (ev.key == .right) 1 else -1;
            if (rtl) step = -step; // the visual order flips
            const next = nextPressable(s, s.active, step);
            if (next < 0) return false;
            s.active = next;
            n.markDirty();
            return true;
        },
        .enter, .space => {
            if (s.active < 0) return false;
            slotActivate(n, @intCast(s.active));
            return true;
        },
        else => {},
    }
    return false;
}

fn toolbarDeinit(n: *Node) void {
    const s = stateOf(n);
    input.releaseNode(n);
    for (s.items.items) |*def| n.allocator.free(def.label);
    s.items.deinit();
    s.sem_children.deinit();
    n.allocator.free(s.fab_label);
    n.allocator.destroy(s);
}

/// The interactive target: ≥48dp tall centered on the container (a
/// constrained-short pill still meets the a11y touch floor).
fn toolbarHitBounds(n: *Node) Rect {
    const b = n.bounds;
    const h = @max(b.h, min_target);
    return .{ .x = b.x, .y = b.y + (b.h - h) / 2, .w = b.w, .h = h };
}

const toolbar_vtable = ui.node.VTable{
    .measure = toolbarMeasure,
    .layout = toolbarLayout,
    .paint = toolbarPaint,
    .deinit = toolbarDeinit,
    .on_pointer = toolbarOnPointer,
    .on_key = toolbarOnKey,
    .hit_bounds = toolbarHitBounds,
};

/// An M3E floating toolbar. The items are internal chrome painted by the
/// widget (a leaf — no document children). `items` are copied (the labels
/// are owned). `opts.fab_icon` docks a 48dp FAB inside the end padding;
/// `opts.vibrant` swaps the SurfaceContainer/OnSurfaceVariant pair for
/// TertiaryContainer/OnTertiaryContainer.
pub fn toolbar(allocator: std.mem.Allocator, items: []const ToolbarItem, opts: ToolbarOptions) !*Node {
    const node = try Node.create(allocator, &toolbar_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(ToolbarState);
    errdefer allocator.destroy(s);
    s.* = .{
        .items = std.array_list.Managed(ItemDef).init(allocator),
        .sem_children = std.array_list.Managed(ui.semantics.Semantics).init(allocator),
        .opts = opts,
        .fab_label = "",
    };
    // One ownership boundary: on ANY failure this errdefer frees the
    // appended defs' labels (toolbarDeinit owns them only once returned).
    errdefer {
        for (s.items.items) |*def| allocator.free(def.label);
        s.items.deinit();
    }
    for (items) |item| {
        const label = try dupeZ(allocator, if (item.divider) "" else item.a11y_label orelse @tagName(item.icon));
        errdefer allocator.free(label); // iteration scope: freed only if THIS iteration fails before the append
        // No catch-free here: on append failure the errdefer frees the copy.
        try s.items.append(.{ .label = label, .icon = item.icon, .on_press = item.on_press, .enabled = item.enabled, .divider = item.divider });
    }
    s.fab_label = try dupeZ(allocator, opts.fab_a11y_label);
    errdefer allocator.free(s.fab_label);
    s.active = nextPressable(s, -1, 1); // the keyboard focus starts on the first action
    node.state = s;
    // the pill/fab shadows paint past the bounds — declare the spill so the
    // paint/damage rect contract covers them
    node.damage_overflow = .{ .left = shadow_spill, .top = shadow_spill, .right = shadow_spill, .bottom = shadow_spill };
    // Per-slot virtual a11y children — VoiceOver reads/activates each
    // action (a separator per divider, a trailing button for the FAB), not
    // just an opaque group. The borrowed slice is stable (the lists never
    // re-alloc after init).
    for (s.items.items) |*def| {
        s.sem_children.append(.{
            .role = if (def.divider) .separator else .button,
            .label = def.label,
            .disabled = def.divider or !def.enabled,
            .actions = if (!def.divider and def.enabled) ui.semantics.Actions.initOne(.activate) else .{},
        }) catch @panic("klaxon: out of memory");
    }
    if (hasFab(s)) {
        s.sem_children.append(.{
            .role = .button,
            .label = s.fab_label,
            .actions = ui.semantics.Actions.initOne(.activate),
        }) catch @panic("klaxon: out of memory");
    }
    ui.semantics.attach(node, .{
        .role = .group,
        .label = opts.a11y_label,
        .focusable = s.active >= 0, // takes the keyboard focus when it has an action
        .children = s.sem_children.items,
        .child_bounds = slotChildBounds,
    }); // Phase 2c
    return node;
}

// --- tests ---

fn pressCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "toolbar: measures the pill (16dp end padding, 48dp cells, 8dp gaps); 56dp tall" {
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{ .{ .icon = .search }, .{ .icon = .plus }, .{ .divider = true }, .{ .icon = .star } }, .{});
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    // 16 + 48 + 8 + 48 + 8 + 1 + 8 + 48 + 16 = 201
    try std.testing.expectApproxEqAbs(@as(f32, 2 * h_pad + 3 * item_cell + divider_w + 3 * item_gap), sz.w, 0.001);
    try std.testing.expectEqual(bar_height, sz.h);
    // the FAB docks inside the end padding (+8 gap + 48)
    const f = try toolbar(a, &.{.{ .icon = .plus }}, .{ .fab_icon = .check });
    defer f.deinit();
    const szf = f.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(@as(f32, 2 * h_pad + item_cell + item_gap + fab_size), szf.w, 0.001);
    // an empty toolbar is just the padding
    const e = try toolbar(a, &.{}, .{});
    defer e.deinit();
    const sze = e.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(@as(f32, 2 * h_pad), sze.w);
    try std.testing.expectEqual(bar_height, sze.h);
}

test "toolbar: a click fires the item's on_press; disabled slots and dividers don't" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var hit_a: u32 = 0;
    var hit_b: u32 = 0;
    var fab_hits: u32 = 0;
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{
        .{ .icon = .search, .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &hit_a } },
        .{ .icon = .plus, .enabled = false, .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &hit_b } },
        .{ .divider = true },
        .{ .icon = .star, .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &hit_b } },
    }, .{ .fab_icon = .check, .on_fab_press = .{ .fn_ptr = pressCounterCb, .userdata = &fab_hits } });
    defer n.deinit();
    // 16 + [48 +8+ 48 +8+ 1 +8+ 48] +8+ 48 +16 = 257
    n.layout(.{ .x = 0, .y = 0, .w = 257, .h = 56 });
    const down_up = struct {
        fn f(nn: *Node, x: f32) void {
            _ = nn.vtable.on_pointer.?(nn, .{ .phase = .down, .x = x, .y = 28, .raw_x = x, .raw_y = 28 });
            _ = nn.vtable.on_pointer.?(nn, .{ .phase = .up, .x = x, .y = 28, .raw_x = x, .raw_y = 28 });
        }
    }.f;
    down_up(n, 16 + 24); // item 0
    try std.testing.expectEqual(@as(u32, 1), hit_a);
    try std.testing.expectEqual(@as(i32, 0), stateOf(n).active); // the press moves the active slot
    // the disabled item (cell at x = 72) doesn't press — its down is unclaimed
    try std.testing.expect(!n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 72 + 24, .y = 28, .raw_x = 72 + 24, .raw_y = 28 }));
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 72 + 24, .y = 28, .raw_x = 72 + 24, .raw_y = 28 });
    try std.testing.expectEqual(@as(u32, 0), hit_b);
    // the divider column (x = 128) is inert too
    try std.testing.expect(!n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 128, .y = 28, .raw_x = 128, .raw_y = 28 }));
    try std.testing.expectEqual(@as(u32, 0), hit_b);
    down_up(n, 136 + 24); // item 3
    try std.testing.expectEqual(@as(u32, 1), hit_b);
    // the docked FAB (x = 193..241) fires on_fab_press
    down_up(n, 193 + 24);
    try std.testing.expectEqual(@as(u32, 1), fab_hits);
    try std.testing.expectEqual(@as(i32, 4), stateOf(n).active);
    // a gap between the cells hits nothing
    try std.testing.expectEqual(@as(i32, -1), slotAt(stateOf(n), n.bounds, 68, 28));
}

test "toolbar: left/right move the active slot (skipping disabled + dividers, wrapping); Enter activates" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var hits: u32 = 0;
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{
        .{ .icon = .search, .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &hits } },
        .{ .icon = .plus, .enabled = false },
        .{ .divider = true },
        .{ .icon = .star, .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &hits } },
    }, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 201, .h = 56 });
    input.requestFocus(n);
    try std.testing.expectEqual(@as(i32, 0), stateOf(n).active); // the first action is active
    // right skips the disabled item AND the divider to the last action
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .right });
    try std.testing.expectEqual(@as(i32, 3), stateOf(n).active);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .right }); // wraps
    try std.testing.expectEqual(@as(i32, 0), stateOf(n).active);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .left }); // wraps back
    try std.testing.expectEqual(@as(i32, 3), stateOf(n).active);
    // Enter activates the active item
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 1), hits);
    // up/down are NOT claimed (they bubble to scrollables)
    try std.testing.expect(!n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .up }));
}

test "toolbar: semantics — a focusable group with virtual button children, a separator, the FAB" {
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{
        .{ .icon = .search, .a11y_label = "Search" },
        .{ .divider = true },
        .{ .icon = .star, .enabled = false },
    }, .{ .fab_icon = .check, .fab_a11y_label = "Done" });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 250, .h = 56 });
    const sem = n.semantics.?;
    try std.testing.expectEqual(ui.semantics.Role.group, sem.role);
    try std.testing.expect(sem.focusable);
    try std.testing.expectEqualStrings("Toolbar", sem.label);
    // [button, separator, disabled button, FAB button]
    try std.testing.expectEqual(@as(usize, 4), sem.children.len);
    try std.testing.expectEqual(ui.semantics.Role.button, sem.children[0].role);
    try std.testing.expectEqualStrings("Search", sem.children[0].label);
    try std.testing.expect(sem.children[0].actions.contains(.activate));
    try std.testing.expectEqual(ui.semantics.Role.separator, sem.children[1].role);
    try std.testing.expectEqual(ui.semantics.Role.button, sem.children[2].role);
    try std.testing.expect(sem.children[2].disabled);
    try std.testing.expectEqualStrings("star", sem.children[2].label); // @tagName fallback
    try std.testing.expectEqual(ui.semantics.Role.button, sem.children[3].role);
    try std.testing.expectEqualStrings("Done", sem.children[3].label);
    // child_bounds in node-local space: item 0's cell, then the FAB slot.
    // The 201dp content centers in the 250dp assignment: x0 = 24.5 + 16.
    const r0 = sem.child_bounds.?(n, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 40.5), r0.x, 0.001);
    const rf = sem.child_bounds.?(n, 3);
    try std.testing.expectEqual(fab_size, rf.w);
    try std.testing.expectApproxEqAbs(@as(f32, 24.5 + 201 - h_pad - fab_size), rf.x, 0.001);
}

test "toolbar: the 48dp a11y floor is the hit target when the pill is constrained short" {
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{.{ .icon = .plus }}, .{});
    defer n.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 80, .h = 40 }); // constrained below 48
    const hb = n.vtable.hit_bounds.?(n);
    try std.testing.expectEqual(@as(f32, 48), hb.h);
    try std.testing.expectEqual(@as(f32, 10 - 4), hb.y); // centered on the 40dp bounds
}

test "golden: the pill paints SurfaceContainer + on_surface_variant icons; the divider column is outline_variant" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{ .{ .icon = .search }, .{ .divider = true }, .{ .icon = .star } }, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 96);
    defer r.deinit();
    // intrinsic: 32 + 48+1+48 + 2*8 = 145
    n.layout(.{ .x = 20, .y = 20, .w = 145, .h = 56 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the pill fill at the gap between cell 0 and the divider (x = 20+16+48+4)
    try std.testing.expectEqual(t.colors.surface_container, f.pixelAt(88, 48));
    // the first cell's icon ink (the 24dp box inside the 48dp cell)
    try std.testing.expect(f.countColorIn(.{ .x = 48, .y = 36, .w = 24, .h = 24 }, t.colors.on_surface_variant) > 0);
    // the divider column: 1dp of outline_variant at x = 92, y = 36..60
    try std.testing.expectEqual(t.colors.outline_variant, f.pixelAt(92, 48));
    try std.testing.expectEqual(t.colors.outline_variant, f.pixelAt(92, 36));
    try std.testing.expectEqual(t.colors.outline_variant, f.pixelAt(92, 59));
    try std.testing.expectEqual(t.colors.surface_container, f.pixelAt(92, 34)); // above the line
    // the pill's full-rounded corner (r = 28): the corner box has no container
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(.{ .x = 20, .y = 20, .w = 8, .h = 8 }, t.colors.surface_container));
}

test "golden: a pressed item paints the on-color state layer circle over the container" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{ .{ .icon = .search }, .{ .icon = .star } }, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 96);
    defer r.deinit();
    n.layout(.{ .x = 20, .y = 20, .w = 136, .h = 56 }); // 32 + 96 + 8
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 60, .y = 48, .raw_x = 60, .raw_y = 48 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // inside the state-layer circle, clear of the icon ink (cell 0 at
    // x = 36..84, center 60): the left interior edge shows the blend
    const layer = theme_mod.stateLayer(t.colors.surface_container, t.colors.on_surface_variant, t.state.pressed);
    try golden.expectPixelApprox(f, 40, 48, layer);
    // the unpressed second cell still shows the bare container
    try std.testing.expectEqual(t.colors.surface_container, f.pixelAt(108, 32));
}

test "golden: the vibrant variant paints TertiaryContainer + on_tertiary_container content" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{ .{ .icon = .search }, .{ .icon = .star, .enabled = false } }, .{ .theme = t, .vibrant = true });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 96);
    defer r.deinit();
    n.layout(.{ .x = 20, .y = 20, .w = 136, .h = 56 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try std.testing.expectEqual(t.colors.tertiary_container, f.pixelAt(80, 48)); // the gap between the cells
    try std.testing.expect(f.countColorIn(.{ .x = 48, .y = 36, .w = 24, .h = 24 }, t.colors.on_tertiary_container) > 0);
    // the disabled icon: on_surface @ 0.38 over the tertiary_container pill
    const dis = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), t.colors.tertiary_container);
    try std.testing.expect(f.countColorApproxIn(.{ .x = 104, .y = 36, .w = 24, .h = 24 }, dis) > 0);
}

test "golden: the docked FAB paints a PrimaryContainer squircle + on_primary_container icon at the end" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try toolbar(a, &.{.{ .icon = .search }}, .{ .theme = t, .fab_icon = .check });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 96);
    defer r.deinit();
    n.layout(.{ .x = 20, .y = 20, .w = 136, .h = 56 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the FAB slot: end edge inside the end padding → x = 20+136-16-48 = 92
    // (probe beside the icon — the glyph's AA edges bleed faint ink nearby)
    try std.testing.expectEqual(t.colors.primary_container, f.pixelAt(96, 48)); // mid-height start edge
    try std.testing.expectEqual(t.colors.primary_container, f.pixelAt(138, 48)); // near the end edge
    try std.testing.expect(f.countColorIn(.{ .x = 104, .y = 36, .w = 24, .h = 24 }, t.colors.on_primary_container) > 0);
    // the FAB's squircle corner (16dp radius): the deep corner pixels stay
    // container-colored (the r-16 arc doesn't reach the corner 4px)
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(.{ .x = 92, .y = 24, .w = 4, .h = 4 }, t.colors.primary_container));
}

test "toolbar: RTL mirrors the row (the first item sits at the end side, the FAB at the start)" {
    const a = std.testing.allocator;
    const i18n = try ui.i18n.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var hits: u32 = 0;
    const n = try toolbar(a, &.{
        .{ .icon = .search, .on_press = .{ .fn_ptr = pressCounterCb, .userdata = &hits } },
        .{ .icon = .star },
    }, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 136, .h = 56 }); // 32 + 96 + 8
    // LTR item 0 cell [16, 64) mirrors to [136-64, 136-16) = [72, 120)
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 96, .y = 28, .raw_x = 96, .raw_y = 28 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 96, .y = 28, .raw_x = 96, .raw_y = 28 });
    try std.testing.expectEqual(@as(u32, 1), hits); // the right-side cell is item 0
    // left moves forward (toward the visual left = increasing index in RTL)
    input.requestFocus(n);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .left });
    try std.testing.expectEqual(@as(i32, 1), stateOf(n).active);
}