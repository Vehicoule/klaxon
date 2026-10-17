// M3E Tree (Phase 4d P2) — an expandable tree view.
//
// Spec: docs/specs/m3e-specs-4d-p2-tree.md
//
// Tokens:
//   - container: Surface, row height: 48dp, indent: 24dp/level
//   - chevron: 24dp OnSurfaceVariant (▼/▶)
//   - leading icon (optional): 24dp OnSurfaceVariant before the label
//   - label: BodyMedium / OnSurface
//   - hover (tappable): OnSurface @ 0.08; pressed: OnSurface @ 0.12;
//     focus (the keyboard cursor's row): OnSurface @ 0.10
//   - selected: SecondaryContainer fill
//
// Keyboard: the tree is focusable (a pointer-down grabs the focus).
// Up/Down move the focused row (selection follows it when tappable —
// upstream selection-follows-focus), Right expands a collapsed node or
// steps into its first child, Left collapses or exits to the parent,
// Home/End jump to the ends, Enter/Space activate the row (select +
// toggle — the label-tap semantics).
//
// Lazy children: `TreeNode.lazy` defers a node's children to its first
// expand — `TreeOptions.children_provider` answers them synchronously
// and they stay cached on the node (lazy nodes start collapsed; an empty
// answer resolves the node as a leaf). No async loading state in v1.
//
// a11y: a focusable .group; each visible row is a virtual .list_item
// child (label, "expanded"/"collapsed" value, checked = selected), the
// group value tracks the focused row's label.
//
// Remaining deviations: no drag-and-drop reordering.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const theme_mod = @import("../theme.zig");
const icon_w = @import("icon.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

pub const TreeNode = struct {
    label: []const u8,
    children: ?[]const TreeNode = null,
    /// Optional leading icon (24dp, OnSurfaceVariant) before the label.
    icon: ?icon_w.IconName = null,
    /// Lazy children: the tree asks `TreeOptions.children_provider` for
    /// them on the FIRST expand and caches the result on the node. Lazy
    /// nodes start collapsed.
    lazy: bool = false,
    /// App-defined token handed back to the children provider (the key
    /// it resolves the node's children by).
    userdata: ?*anyopaque = null,
};

/// Answers a lazy node's children on its first expand (synchronous v1 —
/// no async loading state). `userdata` is the provider context,
/// `node_userdata` the expanding node's `TreeNode.userdata`. The returned
/// nodes are copied — the slice may be freed after the call. Null = the
/// node resolves as a leaf.
pub const ChildrenProvider = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, node_userdata: ?*anyopaque) ?[]const TreeNode,
    userdata: ?*anyopaque,
};

pub const TreeOptions = struct {
    theme: Theme = theme_mod.light,
    tappable: bool = false,
    /// The lazy-children provider — expanding a `lazy` node calls it once.
    children_provider: ?ChildrenProvider = null,
    /// The accessible name.
    a11y_label: []const u8 = "Tree",
};

// --- Tokens ---
/// The row height is a control row — it rides the platform control height
/// (theme.platform.control_height: 48dp mobile / 40 desktop).
fn rowH(t: Theme) f32 {
    return t.platform.control_height;
}
/// The default-theme row height — test convenience; production uses rowH.
const row_h: f32 = theme_mod.light.platform.control_height;
const indent: f32 = 24;
const chevron_size: f32 = 24;
const icon_size: f32 = 24;
const label_pad: f32 = 8; // the 8dp gap between the row's content slots

// --- State ---

const TreeState = struct {
    opts: TreeOptions,
    root: TreeNodeDef, // owned tree
    on_select: ?Callback = null,
    hovered: i32 = -1, // flat visible index
    pressed: i32 = -1, // flat visible index held under the pointer
    selected: i32 = -1,
    /// The keyboard cursor — the flat visible index the arrows move.
    /// Selection follows it when tappable (upstream selection-follows-
    /// focus); collapse re-anchors it via the toggle fixups.
    focused: i32 = 0,
    /// Backing for the virtual a11y children (Semantics.children borrows
    /// the slice — resynced by syncSemantics on every change).
    sem_children: std.array_list.Managed(ui.semantics.Semantics),
};

const TreeNodeDef = struct {
    label: [:0]u8, // owned
    children: std.array_list.Managed(TreeNodeDef),
    expanded: bool = true,
    icon: ?icon_w.IconName = null,
    /// The node's children come from the provider on the first expand.
    lazy: bool = false,
    /// The provider already ran for this node (fires once — its answer,
    /// even an empty one, is cached).
    resolved: bool = false,
    userdata: ?*anyopaque = null,
};

fn stateOf(n: *Node) *TreeState {
    return @ptrCast(@alignCast(n.state.?));
}

/// A visible tree node entry (flat list for measure/paint/input).
const VisibleNode = struct {
    node: *TreeNodeDef,
    depth: usize,
};

/// Count visible nodes (expanded subtrees only). Returns the flat list
/// of visible nodes with their depths.
fn collectVisible(s: *TreeState, allocator: std.mem.Allocator) !std.array_list.Managed(VisibleNode) {
    var list = std.array_list.Managed(VisibleNode).init(allocator);
    try collectNode(&s.root, 0, &list);
    return list;
}

fn collectNode(node: *TreeNodeDef, depth: usize, list: *std.array_list.Managed(VisibleNode)) !void {
    try list.append(.{ .node = node, .depth = depth });
    if (node.expanded) {
        for (node.children.items) |*child| {
            try collectNode(child, depth + 1, list);
        }
    }
}

/// The node can expand: it has children, or its lazy children are not
/// resolved yet (the chevron affordance shows for both).
fn expandable(node: *const TreeNodeDef) bool {
    return node.children.items.len > 0 or (node.lazy and !node.resolved);
}

// --- Measure ---

fn treeMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const t = s.opts.theme;
    const bs = t.type_scale.body_medium;
    var max_w: f32 = 0;
    var count: usize = 0;
    // Walk visible nodes to compute max width + count.
    var stack = std.array_list.Managed(VisibleNode).init(n.allocator);
    defer stack.deinit();
    stack.append(.{ .node = &s.root, .depth = 0 }) catch {};
    while (stack.items.len > 0) {
        const item = stack.pop().?;
        const icon_extra: f32 = if (item.node.icon != null) icon_size + label_pad else 0;
        const w = indent * @as(f32, @floatFromInt(item.depth)) + chevron_size + label_pad + icon_extra + ui.paint.measureText(item.node.label, bs.size, false).width + 16;
        max_w = @max(max_w, w);
        count += 1;
        if (item.node.expanded) {
            var i = item.node.children.items.len;
            while (i > 0) {
                i -= 1;
                stack.append(.{ .node = &item.node.children.items[i], .depth = item.depth + 1 }) catch {};
            }
        }
    }
    const h = @as(f32, @floatFromInt(count)) * rowH(t);
    return .{
        .w = @max(c.min_w, @min(c.max_w, max_w)),
        .h = @max(c.min_h, @min(c.max_h, h)),
    };
}

fn treeLayout(_: *Node, _: Rect) void {}

// --- Paint ---

fn treePaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const bs = t.type_scale.body_medium;

    var list = collectVisible(s, n.allocator) catch return;
    defer list.deinit();

    var y = b.y;
    const focused = input.isFocused(n);
    for (list.items, 0..) |item, vi| {
        const row_y = y;
        const is_sel = s.selected == @as(i32, @intCast(vi));
        const is_foc = focused and s.focused == @as(i32, @intCast(vi));
        // The selected container paints first — the state layer blends
        // over it (hover/focus/press on a selected row still shows).
        if (is_sel) {
            ui.paint.fillRect(ctx, b.x, row_y, b.w, rowH(t), t.colors.secondary_container);
        }
        // One state layer (M3): pressed > focus > hover.
        const alpha: f32 = if (s.opts.tappable and s.pressed == @as(i32, @intCast(vi)))
            t.state.pressed
        else if (is_foc)
            t.state.focus
        else if (s.opts.tappable and s.hovered == @as(i32, @intCast(vi)))
            t.state.hover
        else
            0;
        if (alpha > 0) {
            const base = if (is_sel) t.colors.secondary_container else t.colors.surface;
            ui.paint.fillRect(ctx, b.x, row_y, b.w, rowH(t), theme_mod.stateLayer(base, t.colors.on_surface, alpha));
        }

        const node = item.node;
        const x0 = b.x + indent * @as(f32, @floatFromInt(item.depth));

        // Chevron (parents and unresolved lazy nodes).
        if (expandable(node)) {
            const chev: [:0]const u8 = if (node.expanded) "\u{25BC}" else "\u{25B6}"; // ▼ / ▶
            const cm = ui.paint.measureText(chev, chevron_size, false);
            ui.paint.text(ctx, chev, x0, row_y + (rowH(t) - cm.height) / 2 + cm.height * 0.8, chevron_size, false, t.colors.on_surface_variant);
        }

        // Leading icon (optional) in its own 24dp slot before the label.
        var lx = x0 + chevron_size + label_pad;
        if (node.icon) |iname| {
            const ic = if (is_sel) t.colors.on_secondary_container else t.colors.on_surface_variant;
            icon_w.drawIcon(ctx, iname, lx, row_y + (rowH(t) - icon_size) / 2, icon_size / 24.0, ic);
            lx += icon_size + label_pad;
        }

        // Label.
        const lm = ui.paint.measureText(node.label, bs.size, false);
        const ly = row_y + (rowH(t) - lm.height) / 2 + lm.height * 0.8;
        const label_color = if (is_sel) t.colors.on_secondary_container else t.colors.on_surface;
        ui.paint.text(ctx, node.label, lx, ly, bs.size, false, label_color);

        y += rowH(t);
    }
}

// --- Input ---

/// Row index under a pointer y (in the tree's parent space), or null.
fn rowAt(s: *TreeState, n: *Node, py: f32) ?usize {
    const dy = py - n.bounds.y;
    if (dy < 0) return null;
    const vi: usize = @intFromFloat(dy / rowH(s.opts.theme));
    var list = collectVisible(s, n.allocator) catch return null;
    defer list.deinit();
    if (vi >= list.items.len) return null;
    return vi;
}

fn treePointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (ev.phase != .up) {
        // `.move` only reaches a captured node; the tree never captures, so
        // row hover tracking lives on the hover_move notification.
        if (ev.phase == .hover_move and s.opts.tappable) {
            const b = n.bounds;
            if (ev.y >= b.y and ev.y <= b.y + n.measure(.{ .max_w = b.w, .max_h = 1e9 }).h) {
                const dy = ev.y - b.y;
                const vi = if (dy >= 0) @as(i32, @intFromFloat(dy / rowH(s.opts.theme))) else -1;
                if (vi != s.hovered) {
                    s.hovered = vi;
                    n.markDirty();
                }
            }
        } else if (ev.phase == .leave) {
            if (s.hovered != -1 or s.pressed != -1) {
                s.hovered = -1;
                s.pressed = -1;
                n.markDirty();
            }
        } else if (ev.phase == .down) {
            // A press grabs the keyboard focus; the row under it becomes
            // the cursor (roving index).
            input.requestFocus(n);
            const vi = rowAt(s, n, ev.y);
            if (vi != null and s.focused != @as(i32, @intCast(vi.?))) {
                s.focused = @intCast(vi.?);
                postChange(n, s, false);
            }
            // Press feedback (M3 pressed state layer) — the row stays
            // highlighted until the release; the tap itself is handled on
            // .up below (bubbling keeps the scroll view's drag take-over).
            if (s.opts.tappable and vi != null and vi.? != s.pressed) {
                s.pressed = @intCast(vi.?);
                n.markDirty();
            }
        }
        return false;
    }
    if (s.pressed != -1) {
        s.pressed = -1;
        n.markDirty();
    }
    const b = n.bounds;
    const dy2 = ev.y - b.y;
    const vi = if (dy2 >= 0) @as(usize, @intFromFloat(dy2 / rowH(s.opts.theme))) else 0;
    var list = collectVisible(s, n.allocator) catch return false;
    defer list.deinit();
    if (vi >= list.items.len) return false;
    const item = list.items[vi];
    const x0 = b.x + indent * @as(f32, @floatFromInt(item.depth));
    s.focused = @intCast(vi); // the tapped row is the cursor
    // Chevron tap = toggle.
    if (expandable(item.node) and ev.x >= x0 and ev.x <= x0 + chevron_size) {
        toggleExpanded(n, s, item.node, vi);
        postChange(n, s, true);
        return true;
    }
    // Label tap = select + toggle.
    if (s.opts.tappable) {
        s.selected = @intCast(vi);
        if (s.on_select) |cb| cb.fn_ptr(cb.userdata);
    }
    var structure = false;
    if (expandable(item.node)) {
        toggleExpanded(n, s, item.node, vi);
        structure = true;
    }
    postChange(n, s, structure);
    return true;
}

// --- Expand / lazy children ---

/// The rows a collapse hides / an expand adds: `node`'s descendants
/// visible through their own expanded flags (the node's own flag is
/// irrelevant — it gates the node itself, not the count).
fn revealedCount(node: *const TreeNodeDef) usize {
    var c: usize = 0;
    for (node.children.items) |*ch| {
        c += 1;
        if (ch.expanded) c += revealedCount(ch);
    }
    return c;
}

/// A flat index after `hidden` rows vanished under the collapsed node at
/// `ti`: inside rows re-anchor to `inside` (the collapsed row for the
/// cursor/selection, -1 for pointer states), later rows shift up.
fn collapseFixIndex(idx: *i32, ti: usize, hidden: usize, inside: i32) void {
    if (idx.* < 0) return;
    const i: usize = @intCast(idx.*);
    if (i > ti and i <= ti + hidden) {
        idx.* = inside;
    } else if (i > ti + hidden) {
        idx.* = @intCast(i - hidden);
    }
}

/// A flat index after `added` rows appeared under the expanded node at
/// `ti`: rows below it shift down.
fn expandFixIndex(idx: *i32, ti: usize, added: usize) void {
    if (idx.* < 0) return;
    if (@as(usize, @intCast(idx.*)) > ti) idx.* += @intCast(added);
}

/// Flip `node`'s expanded flag (flat row `ti`), resolving lazy children
/// on the first expand and re-anchoring the flat indices (focused,
/// selected, hovered, pressed) across the rows the toggle reveals/hides.
fn toggleExpanded(n: *Node, s: *TreeState, node: *TreeNodeDef, ti: usize) void {
    if (node.expanded) {
        const hidden = revealedCount(node);
        node.expanded = false;
        collapseFixIndex(&s.focused, ti, hidden, @intCast(ti));
        collapseFixIndex(&s.selected, ti, hidden, @intCast(ti));
        collapseFixIndex(&s.hovered, ti, hidden, -1);
        collapseFixIndex(&s.pressed, ti, hidden, -1);
    } else {
        resolveLazy(n, s, node);
        node.expanded = true;
        const added = revealedCount(node);
        expandFixIndex(&s.focused, ti, added);
        expandFixIndex(&s.selected, ti, added);
        expandFixIndex(&s.hovered, ti, added);
        expandFixIndex(&s.pressed, ti, added);
    }
    n.markDirty();
    n.markLayoutDirty();
}

/// The first expand of a `lazy` node asks the provider for its children —
/// once: the answer stays cached on the node (even an empty one resolves
/// it to a leaf).
fn resolveLazy(n: *Node, s: *TreeState, node: *TreeNodeDef) void {
    if (!node.lazy or node.resolved) return;
    node.resolved = true;
    const provider = s.opts.children_provider orelse return;
    const kids = provider.fn_ptr(provider.userdata, node.userdata) orelse return;
    for (kids) |*child| {
        const def = buildNodeDef(n.allocator, child) catch @panic("klaxon: out of memory");
        node.children.append(def) catch @panic("klaxon: out of memory");
    }
}

// --- Keyboard nav ---

/// The flat index of row `idx`'s visible parent — the nearest previous
/// row one level up.
fn parentIndex(list: []const VisibleNode, idx: usize) usize {
    const d = list[idx].depth;
    var i = idx;
    while (i > 0) {
        i -= 1;
        if (list[i].depth == d - 1) return i;
    }
    return 0;
}

/// Move the keyboard cursor to flat row `idx` (clamped); the selection
/// follows it when tappable (upstream selection-follows-focus — moving
/// IS selecting).
fn focusRow(n: *Node, s: *TreeState, list: []const VisibleNode, idx: i32) void {
    const last: i32 = @intCast(list.len - 1);
    const to = std.math.clamp(idx, 0, last);
    var changed = s.focused != to;
    s.focused = to;
    if (s.opts.tappable and s.selected != to) {
        s.selected = to;
        if (s.on_select) |cb| cb.fn_ptr(cb.userdata);
        changed = true;
    }
    if (changed) postChange(n, s, false);
}

/// Enter/Space on the focused row = the label-tap semantics (select +
/// toggle children).
fn activateRow(n: *Node, s: *TreeState, list: []const VisibleNode, cur: usize) void {
    const item = list[cur];
    s.focused = @intCast(cur);
    if (s.opts.tappable) {
        s.selected = @intCast(cur);
        if (s.on_select) |cb| cb.fn_ptr(cb.userdata);
    }
    var structure = false;
    if (expandable(item.node)) {
        toggleExpanded(n, s, item.node, cur);
        structure = true;
    }
    postChange(n, s, structure);
}

/// Keyboard nav (upstream tree semantics): up/down move the focused row,
/// right expands a collapsed node or steps into its first child, left
/// collapses or exits to the parent, Home/End jump to the ends,
/// Enter/Space activate the row.
fn treeOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind != .key_down) return false;
    var list = collectVisible(s, n.allocator) catch return false;
    defer list.deinit();
    if (list.items.len == 0) return false;
    const last: i32 = @intCast(list.items.len - 1);
    const cur = std.math.clamp(s.focused, 0, last);
    switch (ev.key) {
        .up => focusRow(n, s, list.items, cur - 1),
        .down => focusRow(n, s, list.items, cur + 1),
        .home => focusRow(n, s, list.items, 0),
        .end => focusRow(n, s, list.items, last),
        .right => {
            const item = list.items[@intCast(cur)];
            if (!expandable(item.node)) return true; // a leaf: nothing to do
            if (item.node.expanded) {
                focusRow(n, s, list.items, cur + 1); // into the first child
            } else {
                toggleExpanded(n, s, item.node, @intCast(cur));
                postChange(n, s, true);
            }
        },
        .left => {
            const item = list.items[@intCast(cur)];
            if (expandable(item.node) and item.node.expanded) {
                toggleExpanded(n, s, item.node, @intCast(cur));
                postChange(n, s, true);
            } else if (item.depth > 0) {
                focusRow(n, s, list.items, @intCast(parentIndex(list.items, @intCast(cur))));
            } else return true; // a root row: nowhere to exit
        },
        .enter, .space => activateRow(n, s, list.items, @intCast(cur)),
        else => return false,
    }
    return true;
}

// --- A11y mirror ---

/// Virtual-child bounds in node-local space (see Semantics.child_bounds):
/// row `index` is [0, w) x [index*rowH, +rowH).
fn rowChildBounds(n: *Node, index: usize) Rect {
    const s = stateOf(n);
    return .{ .x = 0, .y = @as(f32, @floatFromInt(index)) * rowH(s.opts.theme), .w = n.bounds.w, .h = rowH(s.opts.theme) };
}

/// Resync the a11y mirror (spec: each visible row is a .list_item —
/// label, "expanded"/"collapsed" value, checked = selected; the group's
/// value is the focused row's label). Cheap: O(visible rows).
fn syncSemantics(n: *Node, s: *TreeState) void {
    const sem = n.semantics orelse return;
    var list = collectVisible(s, n.allocator) catch return;
    defer list.deinit();
    s.sem_children.clearRetainingCapacity();
    for (list.items, 0..) |item, i| {
        s.sem_children.append(.{
            .role = .list_item,
            .label = item.node.label,
            .value = if (expandable(item.node))
                (if (item.node.expanded) "expanded" else "collapsed")
            else
                "",
            .checked = s.selected == @as(i32, @intCast(i)),
            .actions = ui.semantics.Actions.initOne(.activate),
        }) catch @panic("klaxon: out of memory");
    }
    sem.children = s.sem_children.items;
    if (list.items.len == 0) return;
    const fi: usize = @intCast(std.math.clamp(s.focused, 0, @as(i32, @intCast(list.items.len - 1))));
    sem.value = list.items[fi].node.label;
}

/// After a change: repaint + resync the a11y mirror. `structure` (a
/// toggle changed the row set) asks bridges for a tree rebuild; focus/
/// selection moves are a control change.
fn postChange(n: *Node, s: *TreeState, structure: bool) void {
    syncSemantics(n, s);
    n.markDirty();
    if (structure) {
        ui.semantics.notifyTreeDirty();
    } else {
        ui.semantics.notifyControlChanged(n);
    }
}

// --- Deinit ---

fn freeNode(allocator: std.mem.Allocator, node: *TreeNodeDef) void {
    allocator.free(node.label);
    for (node.children.items) |*child| freeNode(allocator, child);
    node.children.deinit();
}

fn treeDeinit(n: *Node) void {
    const s = stateOf(n);
    input.releaseNode(n); // the router may hold a capture/focus on us
    s.sem_children.deinit();
    freeNode(n.allocator, &s.root);
    n.allocator.destroy(s);
}

// --- VTable ---

const tree_vtable = ui.node.VTable{
    .measure = treeMeasure,
    .layout = treeLayout,
    .paint = treePaint,
    .on_pointer = treePointer,
    .on_key = treeOnKey,
    .deinit = treeDeinit,
};

// --- Factory ---

fn buildNodeDef(allocator: std.mem.Allocator, src: *const TreeNode) !TreeNodeDef {
    const buf = try allocator.alloc(u8, src.label.len + 1);
    @memcpy(buf[0..src.label.len], src.label);
    buf[src.label.len] = 0;
    var def = TreeNodeDef{
        .label = buf[0..src.label.len :0],
        .children = std.array_list.Managed(TreeNodeDef).init(allocator),
        // Lazy nodes start collapsed — their children resolve on expand.
        .expanded = !src.lazy,
        .icon = src.icon,
        .lazy = src.lazy,
        .userdata = src.userdata,
    };
    errdefer freeNode(allocator, &def);
    if (src.children) |children| {
        for (children) |*child| {
            try def.children.append(try buildNodeDef(allocator, child));
        }
    }
    return def;
}

/// An M3E expandable tree. `root` is copied into owned state; expansion
/// is internal (taps + arrows), selection is `on_select`-reported when
/// `opts.tappable`. Keyboard nav is always on (see the header); lazy
/// nodes resolve through `opts.children_provider` on first expand.
pub fn tree(
    allocator: std.mem.Allocator,
    root: *const TreeNode,
    on_select: ?Callback,
    opts: TreeOptions,
) !*Node {
    const node = try Node.create(allocator, &tree_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(TreeState);
    errdefer allocator.destroy(s);

    s.* = .{
        .opts = opts,
        .root = try buildNodeDef(allocator, root),
        .on_select = on_select,
        .sem_children = std.array_list.Managed(ui.semantics.Semantics).init(allocator),
    };
    errdefer freeNode(allocator, &s.root);
    node.state = @ptrCast(s);

    ui.semantics.attach(node, .{
        .role = .group,
        .label = opts.a11y_label,
        .focusable = true, // takes the keyboard focus (arrows/enter nav)
        .children = s.sem_children.items,
        .child_bounds = rowChildBounds,
    });
    syncSemantics(node, s); // first fill of the virtual rows + the value

    return node;
}

// --- Tests ---

test "tree: measure counts visible nodes" {
    const a = std.testing.allocator;
    const root = TreeNode{
        .label = "Root",
        .children = &.{ .{ .label = "Child1" }, .{ .label = "Child2", .children = &.{.{ .label = "Grandchild" }} } },
    };
    const n = try tree(a, &root, null, .{});
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    // All expanded by default: Root + Child1 + Child2 + Grandchild = 4 rows.
    try std.testing.expectApproxEqAbs(row_h * 4, sz.h, 0.001);
}

test "tree: tap chevron toggles expanded" {
    const a = std.testing.allocator;
    const root = TreeNode{
        .label = "Root",
        .children = &.{.{ .label = "Child" }},
    };
    const n = try tree(a, &root, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 300, .h = row_h * 2 });
    const s = stateOf(n);
    try std.testing.expect(s.root.expanded);
    try std.testing.expect(s.root.children.items[0].expanded);
    // Tap the root's chevron.
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 12, .y = 24, .raw_x = 12, .raw_y = 24 });
    try std.testing.expect(!s.root.expanded); // toggled
}

test "golden: the tree paints the root label" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const root = TreeNode{ .label = "RootNode" };
    const n = try tree(a, &root, null, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 80);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 180, .h = row_h });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // Root label ink (OnSurface) in the row.
    try std.testing.expect(f.countColorIn(.{ .x = 10, .y = 20, .w = 180, .h = 20 }, t.colors.on_surface) > 0);
}

test "tree: tappable tracks hover + press rows" {
    const a = std.testing.allocator;
    const root = TreeNode{
        .label = "Root",
        .children = &.{ .{ .label = "Child1" }, .{ .label = "Child2" } },
    };
    const n = try tree(a, &root, null, .{ .tappable = true });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 300, .h = row_h * 3 });
    const s = stateOf(n);
    try std.testing.expectEqual(@as(i32, -1), s.hovered);
    // Hover over row 1 (Child1): hover_move tracks it.
    _ = n.vtable.on_pointer.?(n, .{ .phase = .hover_move, .x = 40, .y = row_h + 10 });
    try std.testing.expectEqual(@as(i32, 1), s.hovered);
    // Press on row 1: the pressed layer follows until the release.
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 40, .y = row_h + 10 });
    try std.testing.expectEqual(@as(i32, 1), s.pressed);
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 40, .y = row_h + 10 });
    try std.testing.expectEqual(@as(i32, -1), s.pressed);
    try std.testing.expectEqual(@as(i32, 1), s.selected); // the tap also selects
    // Leaving the widget drops the hover marker.
    _ = n.vtable.on_pointer.?(n, .{ .phase = .leave, .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(i32, -1), s.hovered);
}

test "tree: non-tappable ignores hover/press tracking" {
    const a = std.testing.allocator;
    const root = TreeNode{ .label = "Root" };
    const n = try tree(a, &root, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 300, .h = row_h });
    const s = stateOf(n);
    _ = n.vtable.on_pointer.?(n, .{ .phase = .hover_move, .x = 40, .y = 10 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 40, .y = 10 });
    try std.testing.expectEqual(@as(i32, -1), s.hovered);
    try std.testing.expectEqual(@as(i32, -1), s.pressed);
}

test "golden: a collapsed root hides the child rows; expanding shows them" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const root_def = TreeNode{
        .label = "Root",
        .children = &.{.{ .label = "Child" }},
    };
    const n = try tree(a, &root_def, null, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(a, 300, 120);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 280, .h = 120 });
    // the child's row region (the second row)
    const child_row: Rect = .{ .x = 10, .y = 10 + row_h, .w = 280, .h = row_h };
    // expanded by default: the child's label ink is present
    r.paint(n, 0xFFFFFFFF);
    var f1 = try r.readback(a);
    try std.testing.expect(f1.countColorIn(child_row, t.colors.on_surface) > 0);
    f1.deinit();
    // collapse the root: the child row paints nothing
    stateOf(n).root.expanded = false;
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(a);
    defer f2.deinit();
    try std.testing.expectEqual(@as(u64, 0), f2.countColorIn(child_row, t.colors.on_surface));
    try std.testing.expectEqual(@as(u64, 0), f2.countColor(t.colors.secondary_container));
}

fn selectCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "tree: arrows move the focused row; selection follows when tappable" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    var selects: u32 = 0;
    const root = TreeNode{
        .label = "Root",
        .children = &.{ .{ .label = "Child1" }, .{ .label = "Child2" } },
    };
    const n = try tree(a, &root, .{ .fn_ptr = selectCounterCb, .userdata = &selects }, .{ .tappable = true });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 300, .h = row_h * 3 });
    input.requestFocus(n);
    const s = stateOf(n);
    try std.testing.expect(input.isFocused(n));
    try std.testing.expectEqual(@as(i32, 0), s.focused); // the cursor starts on the root
    // Down/up walk the visible rows; the selection follows each move.
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .down }));
    try std.testing.expectEqual(@as(i32, 1), s.focused);
    try std.testing.expectEqual(@as(i32, 1), s.selected);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .down }));
    try std.testing.expectEqual(@as(i32, 2), s.focused);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .down })); // clamps at the last row
    try std.testing.expectEqual(@as(i32, 2), s.focused);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .up }));
    try std.testing.expectEqual(@as(i32, 1), s.focused);
    // Home/End jump to the ends.
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .end }));
    try std.testing.expectEqual(@as(i32, 2), s.focused);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .home }));
    try std.testing.expectEqual(@as(i32, 0), s.focused);
    // Each effective move selected once; the a11y value tracks the row.
    try std.testing.expectEqual(@as(u32, 5), selects);
    try std.testing.expectEqualStrings("Root", n.semantics.?.value);
}

test "tree: right expands or enters the first child; left collapses or exits to the parent" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const root = TreeNode{
        .label = "Root",
        .children = &.{ .{ .label = "Child1" }, .{ .label = "Parent", .children = &.{.{ .label = "Grand" }} } },
    };
    const n = try tree(a, &root, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 300, .h = row_h * 4 });
    input.requestFocus(n);
    const s = stateOf(n);
    // Rows: 0=Root, 1=Child1, 2=Parent, 3=Grand. Right on the expanded
    // root steps into the first child.
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .right }));
    try std.testing.expectEqual(@as(i32, 1), s.focused);
    // Left on a leaf exits to its parent.
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .left }));
    try std.testing.expectEqual(@as(i32, 0), s.focused);
    // Left on the expanded root collapses it (one visible row).
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .left }));
    try std.testing.expect(!s.root.expanded);
    var sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(row_h, sz.h, 0.001);
    // Right re-expands it; a second Right enters the first child.
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .right }));
    try std.testing.expect(s.root.expanded);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .right }));
    try std.testing.expectEqual(@as(i32, 1), s.focused);
    // Down to Parent (row 2): Enter toggles (collapses) it.
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    try std.testing.expectEqual(@as(i32, 2), s.focused);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .enter }));
    try std.testing.expect(!s.root.children.items[1].expanded);
    sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(row_h * 3, sz.h, 0.001); // Grand hidden
    // Left on the collapsed parent exits to the parent chain (it is not
    // expanded, so the arrow moves instead of collapsing).
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .left }));
    try std.testing.expectEqual(@as(i32, 0), s.focused);
}

test "tree: the lazy provider fires once on the first expand; children stay cached" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    var calls: u32 = 0;
    const provider = struct {
        fn f(_: ?*anyopaque, node_userdata: ?*anyopaque) ?[]const TreeNode {
            const c: *u32 = @ptrCast(@alignCast(node_userdata.?));
            c.* += 1;
            return &.{ .{ .label = "Lazy1" }, .{ .label = "Lazy2" } };
        }
    }.f;
    const root = TreeNode{
        .label = "Root",
        .children = &.{
            .{ .label = "Lazy", .lazy = true, .userdata = &calls },
            .{ .label = "Tail" },
        },
    };
    const n = try tree(a, &root, null, .{ .children_provider = .{ .fn_ptr = provider, .userdata = null } });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 300, .h = row_h * 5 });
    input.requestFocus(n);
    const s = stateOf(n);
    const lazy = &s.root.children.items[0];
    // The lazy node starts collapsed: Root + Lazy + Tail = 3 rows.
    try std.testing.expect(!lazy.expanded);
    var sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(row_h * 3, sz.h, 0.001);
    // Focus the lazy row and expand it: the provider fires once and the
    // children appear (Root, Lazy, Lazy1, Lazy2, Tail = 5 rows).
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    try std.testing.expectEqual(@as(i32, 1), s.focused);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .right }));
    try std.testing.expectEqual(@as(u32, 1), calls);
    try std.testing.expectEqual(@as(usize, 2), lazy.children.items.len);
    sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(row_h * 5, sz.h, 0.001);
    // Collapse + re-expand: the cached children come back — no second call.
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .left }));
    try std.testing.expect(!lazy.expanded);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .right }));
    try std.testing.expect(lazy.expanded);
    try std.testing.expectEqual(@as(u32, 1), calls);
    sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(row_h * 5, sz.h, 0.001);
}

test "tree: semantics — a focusable group with virtual list_item rows" {
    const a = std.testing.allocator;
    const root = TreeNode{
        .label = "Root",
        .children = &.{ .{ .label = "Child1" }, .{ .label = "Parent", .children = &.{.{ .label = "Grand" }} } },
    };
    const n = try tree(a, &root, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 300, .h = row_h * 4 });
    const sem = n.semantics.?;
    try std.testing.expectEqual(ui.semantics.Role.group, sem.role);
    try std.testing.expect(sem.focusable);
    // One virtual .list_item per visible row, in flat order.
    try std.testing.expectEqual(@as(usize, 4), sem.children.len);
    try std.testing.expectEqual(ui.semantics.Role.list_item, sem.children[0].role);
    try std.testing.expectEqualStrings("Root", sem.children[0].label);
    try std.testing.expectEqualStrings("expanded", sem.children[0].value);
    try std.testing.expectEqualStrings("Child1", sem.children[1].label);
    try std.testing.expectEqualStrings("", sem.children[1].value); // a leaf reports no state
    try std.testing.expectEqual(@as(?bool, false), sem.children[1].checked);
    try std.testing.expectEqualStrings("Root", sem.value); // the focused row's label
    // Collapsing the root leaves a single virtual child.
    stateOf(n).root.expanded = false;
    syncSemantics(n, stateOf(n));
    try std.testing.expectEqual(@as(usize, 1), sem.children.len);
    try std.testing.expectEqualStrings("collapsed", sem.children[0].value);
}

test "golden: the focused row paints the focus state layer" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const root = TreeNode{
        .label = "Root",
        .children = &.{.{ .label = "Child" }},
    };
    const n = try tree(a, &root, null, .{ .theme = t });
    defer n.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 280, .h = row_h * 2 });
    var r = try golden.Renderer.init(a, 300, 120);
    defer r.deinit();
    const focus_layer = theme_mod.stateLayer(t.colors.surface, t.colors.on_surface, t.state.focus);
    const row1: Rect = .{ .x = 10, .y = 10 + row_h, .w = 280, .h = row_h };
    // Unfocused: no state layer anywhere.
    r.paint(n, 0xFFFFFFFF);
    var f1 = try r.readback(a);
    try std.testing.expectEqual(@as(u64, 0), f1.countColor(focus_layer));
    f1.deinit();
    // Focused on row 1 (Down): the layer paints across that row.
    input.requestFocus(n);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(a);
    defer f2.deinit();
    try std.testing.expect(f2.countColorIn(row1, focus_layer) > 0);
}

test "golden: a node icon paints in the leading slot before the label" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const root = TreeNode{ .label = "Root", .icon = .star };
    const n = try tree(a, &root, null, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(a, 200, 80);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 180, .h = row_h });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    // The icon slot: x0 + chevron + pad = 10 + 24 + 8, vertically centered.
    const icon_rect: Rect = .{ .x = 42, .y = 10 + (row_h - icon_size) / 2, .w = icon_size, .h = icon_size };
    try std.testing.expect(f.countColorIn(icon_rect, t.colors.on_surface_variant) > 0);
}
