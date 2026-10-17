// Accessibility (Phase 2c) — semantic tree, keyboard focus, live regions.
//
//   - Semantics: a per-node descriptor (role, label, hint, value, checked
//     state, actions). Widgets attach one in their factory (Text → .text,
//     Button → .button, Toggle → .toggle, Slider → .slider, TextField →
//     .text_field, Icon → .image, ...).
//   - Semantic tree: the flattened view assistive tech consumes. Nodes
//     without semantics are transparent (their children are lifted);
//     `Node.exclude_semantics` hides decorative subtrees entirely.
//   - FocusManager: keyboard focus order (Tab / Shift+Tab), activation
//     (Enter/Space = a synthesized click at the node's visual center),
//     and the focus ring the host paints around the focused node.
//   - Live regions: polite/assertive announcements for dynamic changes.
//   - SemanticsBridge (ADR-0009 C ABI): the interface an OS bridge
//     implements (AT-SPI/D-Bus on Linux, NSAccessibility on macOS, UIA on
//     Windows, TalkBack on Android, ARIA on web). The default is LogBridge,
//     which records events (testable headless).
//
// The AT-SPI/D-Bus bridge itself lands with the Linux target (Phase 3a) —
// it needs a session bus + the AT-SPI registry daemon, neither of which
// exists on the dev Mac. The interface is ready for it.
const std = @import("std");
const kx = @import("../kx.zig");
const node_mod = @import("node.zig");
const state_mod = @import("state.zig");
const input_mod = @import("input.zig");
const paint_mod = @import("paint.zig");
const golden = @import("../golden.zig");

const layout_mod = @import("layout.zig");
const Node = node_mod.Node;
const Rect = node_mod.Rect;
const Size = layout_mod.Size;
const Color = paint_mod.Color;

pub const Role = enum {
    none,
    text,
    heading,
    button,
    link,
    image,
    text_field,
    toggle,
    checkbox,
    radio,
    slider,
    progress,
    scrollbar,
    list,
    list_item,
    dialog,
    alert,
    menu,
    menu_item,
    tab,
    tab_panel,
    separator,
    group,
};

pub const Action = enum { activate, increment, decrement, delete };
pub const Actions = std.enums.EnumSet(Action);

pub const LiveRegion = enum { off, polite, assertive };

/// The numeric range of a value-bearing role (slider, progress, scrollbar).
/// `value` remains the display string; min/max/now are what AtkValue and
/// ARIA aria-valuemin/max/now report. Convention: the emitting widgets
/// express percent (0–100), matching their "{d}%" value strings — a widget
/// with a different unit fills its true range instead.
pub const ValueRange = struct { min: f64, max: f64, now: f64 };

/// The per-node accessibility descriptor (attached by the widget factory;
/// the node owns it — string fields are borrowed: literals or app-lifetime
/// data).
pub const Semantics = struct {
    role: Role = .none,
    label: []const u8 = "",
    hint: []const u8 = "",
    value: []const u8 = "",
    /// Numeric value range (see ValueRange). Null = display string only.
    value_range: ?ValueRange = null,
    checked: ?bool = null,
    disabled: bool = false,
    focusable: bool = false,
    /// True when this node is a modal container (dialog, modal drawer, modal
    /// bottom/side sheet). While visible, buildSemanticTree and FocusManager
    /// trap assistive traversal and Tab/Shift+Tab focus within this modal.
    modal: bool = false,
    actions: Actions = .{},
    live: LiveRegion = .off,
    /// Virtual per-item children for compound widgets (segmented buttons,
    /// nav rails, steppers): each entry becomes a semantic node without a
    /// Node of its own — activation dispatches at the item's rect, so the
    /// parent's hit-test resolves the item like a real tap. Borrowed —
    /// the widget owns the slice and updates it before a tree_dirty.
    children: []const Semantics = &.{},
    /// Bounds of virtual child `index` in the node's LOCAL space (0,0 =
    /// the node's top-left). Needed for highlight rects and targeted
    /// activation when `children` is non-empty.
    child_bounds: ?*const fn (node: *Node, index: usize) Rect = null,
};

/// Attach (or replace) a node's accessibility descriptor.
pub fn attach(node: *Node, sem: Semantics) void {
    if (node.semantics) |old| node.allocator.destroy(old);
    const s = node.allocator.create(Semantics) catch @panic("klaxon: out of memory");
    s.* = sem;
    node.semantics = s;
}

// --- Semantic tree (flattened view for assistive tech) ---

pub const SemanticNode = struct {
    node: *Node,
    role: Role,
    label: []const u8,
    hint: []const u8,
    value: []const u8,
    value_range: ?ValueRange = null,
    checked: ?bool,
    disabled: bool,
    focusable: bool,
    modal: bool = false,
    actions: Actions,
    live: LiveRegion,
    children: []SemanticNode, // owned (flat builds: a sub-slice of `backing`)
    /// Set on a virtual child (Semantics.children entry): `node` is the
    /// owning widget and `virtual_index` picks the item. Virtual nodes
    /// never expand — they are a11y leaves.
    virtual_index: ?usize = null,
    /// Window-space rect for a virtual child (from Semantics.child_bounds).
    /// Null → callers fall back to node.mapRectToRoot(node.bounds).
    bounds_override: ?Rect = null,
    /// The single allocation every `children` slice in the tree is cut
    /// from — buildSemanticTree's flat layout. Set on the ROOT only:
    /// deinit frees it once instead of walking the tree freeing per-node
    /// slices. Sub-slices must never be freed individually, so always
    /// deinit the root, not a detached child.
    backing: ?[]SemanticNode = null,

    pub fn deinit(self: *SemanticNode, allocator: std.mem.Allocator) void {
        if (self.backing) |b| {
            allocator.free(b);
            self.backing = null;
            return;
        }
        for (self.children) |*c| c.deinit(allocator);
        allocator.free(self.children);
    }
};

/// First descendant (depth-first) with a non-empty label — the fallback for
/// container-ish roles (a Button's label is its Text child).
fn firstDescendantLabel(n: *Node) ?[]const u8 {
    for (n.children.items) |c| {
        if (c.exclude_semantics or !c.visible) continue;
        if (c.semantics) |sem| {
            if (sem.label.len > 0) return sem.label;
        }
        if (firstDescendantLabel(c)) |l| return l;
    }
    return null;
}

/// The flatten predicate: the subtree contributes nothing when excluded,
/// invisible, or not hit-testable (a zero-size hit_bounds — e.g. a
/// navigator background page mid-transition).
fn semanticSkipped(n: *Node) bool {
    if (n.exclude_semantics or !n.visible) return true;
    if (n.vtable.hit_bounds) |hb| {
        const b = hb(n);
        if (b.w <= 0 or b.h <= 0) return true;
    }
    return false;
}

/// The number of semantic nodes `n`'s subtree contributes — the emit pass
/// below writes exactly this many: every non-skipped node with a
/// descriptor lands somewhere in the tree (transparent ones lift their
/// descendants instead).
fn countEmitted(n: *Node) usize {
    if (semanticSkipped(n)) return 0;
    var s: usize = if (n.semantics) |sem| 1 + sem.children.len else 0;
    for (n.children.items) |c| s += countEmitted(c);
    return s;
}

/// Return the last (topmost in paint order) non-skipped node in `n`'s
/// subtree whose semantics descriptor sets `.modal = true`.
pub fn findActiveModal(n: *Node) ?*Node {
    if (semanticSkipped(n)) return null;
    var found: ?*Node = null;
    if (n.semantics) |sem| {
        if (sem.modal) found = n;
    }
    for (n.children.items) |c| {
        if (findActiveModal(c)) |m| found = m;
    }
    return found;
}

/// Find the visible scrim sibling immediately preceding `modal_node` in its
/// parent (dialog/drawer/bottom_sheet/side_sheet attach a non-focusable
/// activate button on `s.scrim`).
fn findModalScrim(modal_node: *Node) ?*Node {
    const parent = modal_node.parent orelse return null;
    var scrim: ?*Node = null;
    for (parent.children.items) |sib| {
        if (sib == modal_node) break;
        if (semanticSkipped(sib)) continue;
        if (sib.semantics) |sem| {
            if (sem.role == .button and !sem.focusable and sem.actions.contains(.activate) and sib.children.items.len == 0) {
                scrim = sib;
            }
        }
    }
    return scrim;
}

fn countModalEmitted(scrim_opt: ?*Node, modal_node: *Node) usize {
    return (if (scrim_opt) |sc| countEmitted(sc) else 0) + countEmitted(modal_node);
}

/// The SemanticNode value for `n` (children are patched in by the fill
/// pass once their buffer range is known). inline: the ~100-byte return
/// does NOT get inlined under ReleaseSmall — an sret call + memcpy per
/// node dominated the per-frame rebuild (≈30µs/1000 nodes).
inline fn semanticValue(n: *Node, sem: *const Semantics) SemanticNode {
    return .{
        .node = n,
        .role = sem.role,
        .label = if (sem.label.len > 0) sem.label else firstDescendantLabel(n) orelse "",
        .hint = sem.hint,
        .value = sem.value,
        .value_range = sem.value_range,
        .checked = sem.checked,
        .disabled = sem.disabled,
        .focusable = sem.focusable,
        .modal = sem.modal,
        .actions = sem.actions,
        .live = sem.live,
        .children = &.{},
    };
}

/// A virtual child's SemanticNode: owned by `parent`'s widget, leaf in
/// the tree, rect mapped from node-local space (child_bounds) into window
/// space for the bridges' highlight/activation.
fn virtualValue(parent: *Node, vc: *const Semantics, index: usize, bounds_cb: ?*const fn (*Node, usize) Rect) SemanticNode {
    var r: ?Rect = null;
    if (bounds_cb) |cb| {
        var b = cb(parent, index);
        b.x += parent.bounds.x;
        b.y += parent.bounds.y;
        r = parent.mapRectToRoot(b);
    }
    return .{
        .node = parent,
        .role = vc.role,
        .label = vc.label,
        .hint = vc.hint,
        .value = vc.value,
        .value_range = vc.value_range,
        .checked = vc.checked,
        .disabled = vc.disabled,
        .focusable = vc.focusable,
        .modal = vc.modal,
        .actions = vc.actions,
        .live = vc.live,
        .children = &.{},
        .virtual_index = index,
        .bounds_override = r,
    };
}

/// Emit `n`'s semantic frontier — the semantic descendants with no other
/// semantic ancestor between them and `n` — into buf[w..]. `n` itself is
/// assumed emitted/skipped by the caller. error.Overflow = buf is full
/// (the caller retries with an exact-size buffer).
fn emitFrontier(n: *Node, buf: []SemanticNode, w: *usize) error{Overflow}!void {
    // Virtual per-item children first — they are the widget's own items
    // (segmented button segments, nav rail destinations).
    if (n.semantics) |sem| {
        for (sem.children, 0..) |*vc, vi| {
            if (w.* == buf.len) return error.Overflow;
            buf[w.*] = virtualValue(n, vc, vi, sem.child_bounds);
            w.* += 1;
        }
    }
    for (n.children.items) |c| {
        if (semanticSkipped(c)) continue;
        if (c.semantics) |sem| {
            if (w.* == buf.len) return error.Overflow;
            buf[w.*] = semanticValue(c, sem);
            w.* += 1;
        } else try emitFrontier(c, buf, w); // transparent: children lift
    }
}

const FillResult = struct { top: usize, total: usize };

/// Modal-scoped breadth fill: emits only the active modal (and its optional
/// scrim barrier) so background siblings/cousins are excluded from both
/// assistive technology dumps and FocusManager.focusOrder.
fn fillModalTree(scrim_opt: ?*Node, modal_node: *Node, buf: []SemanticNode) error{Overflow}!FillResult {
    var w: usize = 0;
    if (scrim_opt) |sc| {
        if (sc.semantics) |sem| {
            if (w == buf.len) return error.Overflow;
            buf[w] = semanticValue(sc, sem);
            w += 1;
        }
    }
    if (modal_node.semantics) |sem| {
        if (w == buf.len) return error.Overflow;
        buf[w] = semanticValue(modal_node, sem);
        w += 1;
    }
    const top = w;
    var r: usize = 0;
    while (r < w) : (r += 1) {
        if (buf[r].virtual_index != null) {
            buf[r].children = &.{};
            continue;
        }
        const start = w;
        try emitFrontier(buf[r].node, buf, &w);
        buf[r].children = buf[start..w];
    }
    return .{ .top = top, .total = w };
}

/// The breadth fill: `root`'s frontier first, then parents in buffer
/// order claiming the next contiguous range for their own frontier —
/// every node's children stay contiguous.
fn fillTree(root: *Node, buf: []SemanticNode) error{Overflow}!FillResult {
    var w: usize = 0;
    if (!semanticSkipped(root)) {
        if (root.semantics) |sem| {
            if (w == buf.len) return error.Overflow;
            buf[0] = semanticValue(root, sem);
            w = 1;
        } else {
            try emitFrontier(root, buf, &w);
        }
    }
    const top = w; // the top-level frontier — the group wrapper's children
    var r: usize = 0;
    while (r < w) : (r += 1) {
        // A virtual child is an a11y leaf — re-expanding its `node` (the
        // owning widget) would emit the widget's frontier a second time.
        if (buf[r].virtual_index != null) {
            buf[r].children = &.{};
            continue;
        }
        const start = w;
        try emitFrontier(buf[r].node, buf, &w);
        buf[r].children = buf[start..w];
    }
    return .{ .top = top, .total = w };
}

/// The last build's node count — a capacity hint so a stable tree (the
/// common case: bridges rebuild the whole tree on every tree_dirty)
/// sizes its single buffer exactly on the first try. A bigger tree
/// overflows the guess mid-fill and falls back to an exact count.
var sem_size_hint: usize = 0;

/// Build the semantic tree. When the root itself has no descriptor, the
/// result is a .group wrapper around the top-level semantic nodes. The
/// caller owns the tree (deinit the root once — it frees the flat
/// backing buffer the whole tree is cut from).
pub fn buildSemanticTree(allocator: std.mem.Allocator, root: *Node) !SemanticNode {
    const active_modal = findActiveModal(root);
    const modal_scrim = if (active_modal) |m| findModalScrim(m) else null;
    // One allocation for the whole tree (per-node ArrayLists + their
    // growth/frees dominated the per-frame rebuild cost). The buffer is
    // sized by the previous build's count first; on overflow the subtree
    // is counted exactly and the fill restarts.
    var buf = try allocator.alloc(SemanticNode, @max(sem_size_hint, 8));
    errdefer allocator.free(buf);
    const res = (if (active_modal) |m|
        fillModalTree(modal_scrim, m, buf)
    else
        fillTree(root, buf)) catch |err| switch (err) {
        error.Overflow => blk: {
            allocator.free(buf);
            buf = &.{}; // released — keep errdefer from freeing it twice
            const exact = if (active_modal) |m| countModalEmitted(modal_scrim, m) else countEmitted(root);
            buf = try allocator.alloc(SemanticNode, exact);
            break :blk (if (active_modal) |m|
                fillModalTree(modal_scrim, m, buf)
            else
                fillTree(root, buf)) catch unreachable; // exact size cannot overflow
        },
    };
    sem_size_hint = res.total;
    const top = res.top;
    if (top == 1) {
        var sn = buf[0];
        sn.backing = buf;
        return sn;
    }
    return .{
        .node = root,
        .role = .group,
        .label = "",
        .hint = "",
        .value = "",
        .checked = null,
        .disabled = false,
        .focusable = false,
        .actions = .{},
        .live = .off,
        .children = buf[0..top],
        .backing = buf,
    };
}

// --- Bridge (ADR-0009 C ABI) + live regions ---

pub const BridgeEvent = struct {
    pub const Kind = enum { tree_dirty, focus_changed, announce, control_changed };
    kind: Kind,
    node: ?*Node = null,
    text: []const u8 = "", // announce payload (borrowed during the call)
    region: LiveRegion = .off,
};

pub const SemanticsBridge = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, event: BridgeEvent) void,
    userdata: ?*anyopaque,
};

var current_bridge: ?SemanticsBridge = null;

pub fn setBridge(b: ?SemanticsBridge) void {
    current_bridge = b;
}

pub fn bridge() ?SemanticsBridge {
    return current_bridge;
}

fn notifyBridge(ev: BridgeEvent) void {
    if (current_bridge) |b| b.fn_ptr(b.userdata, ev);
    if (bridge_c) |b| b.fn_ptr(b.userdata, .{
        .kind = @backingInt(ev.kind),
        .node_id = if (ev.node) |n| @intFromPtr(n) else 0,
        .text = ev.text.ptr,
        .text_len = ev.text.len,
        .region = @backingInt(ev.region),
    });
}

/// The extern event representation (ADR-0009 C boundary) + C-callable
/// registration for native bridges.
pub const BridgeEventC = extern struct {
    kind: u32, // BridgeEvent.Kind
    node_id: u64,
    text: [*]const u8,
    text_len: usize,
    region: u32, // LiveRegion
};

const BridgeC = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, event: BridgeEventC) callconv(.c) void,
    userdata: ?*anyopaque,
};

var bridge_c: ?BridgeC = null;

/// Install a C-callable bridge (extern event representation, ADR-0009).
pub fn setBridgeC(fn_ptr: ?*const fn (userdata: ?*anyopaque, event: BridgeEventC) callconv(.c) void, userdata: ?*anyopaque) void {
    bridge_c = if (fn_ptr) |f| .{ .fn_ptr = f, .userdata = userdata } else null;
}

/// The semantic tree changed (structure/layout) — bridges rebuild their view.
pub fn notifyTreeDirty() void {
    notifyBridge(.{ .kind = .tree_dirty });
}

/// Announce a dynamic change (live region) to the installed bridge.
pub fn announce(text: []const u8, region: LiveRegion) void {
    notifyBridge(.{ .kind = .announce, .text = text, .region = region });
}

/// A control's semantic value/checked changed (toggle, slider, ...) — bridges
/// refresh that node's value without a full tree rebuild.
pub fn notifyControlChanged(node: *Node) void {
    notifyBridge(.{ .kind = .control_changed, .node = node });
}

/// LogBridge: records every event (tests + the a11y demo). Install it with
/// `setBridge(lb.bridge())` — a11y never crashes the app.
pub const LogBridge = struct {
    allocator: std.mem.Allocator,
    events: std.array_list.Managed(LoggedEvent),

    pub const LoggedEvent = struct {
        kind: BridgeEvent.Kind,
        node_id: u64, // @intFromPtr(node) or 0
        text: []const u8, // owned
        region: LiveRegion,
    };

    pub fn init(allocator: std.mem.Allocator) !*LogBridge {
        const lb = try allocator.create(LogBridge);
        lb.* = .{
            .allocator = allocator,
            .events = std.array_list.Managed(LoggedEvent).init(allocator),
        };
        return lb;
    }

    pub fn deinit(lb: *LogBridge) void {
        for (lb.events.items) |e| lb.allocator.free(e.text);
        lb.events.deinit();
        lb.allocator.destroy(lb);
    }

    pub fn bridge(lb: *LogBridge) SemanticsBridge {
        return .{ .fn_ptr = logBridgeCb, .userdata = lb };
    }
};

fn logBridgeCb(userdata: ?*anyopaque, ev: BridgeEvent) void {
    const lb: *LogBridge = @ptrCast(@alignCast(userdata.?));
    lb.events.append(.{
        .kind = ev.kind,
        .node_id = if (ev.node) |n| @intFromPtr(n) else 0,
        .text = lb.allocator.dupe(u8, ev.text) catch @panic("klaxon: out of memory"),
        .region = ev.region,
    }) catch @panic("klaxon: out of memory");
}

// --- FocusManager (keyboard focus + focus ring) ---

/// The focus ring rect: the node's bounds expanded by `margin`; the ring
/// itself is painted on the ring rect's inner edge (ring_width thick).
fn ringRect(n: *Node, margin: f32) Rect {
    const r = n.mapRectToRoot(n.bounds);
    return .{ .x = r.x - margin, .y = r.y - margin, .w = r.w + 2 * margin, .h = r.h + 2 * margin };
}

pub const FocusManager = struct {
    allocator: std.mem.Allocator,
    /// Weak node ids: both outlive the traversal that set them — a
    /// destroyed node resolves null instead of dangling (resolve through
    /// rootNode()/focusedNode()).
    root: ?u64 = null,
    focused: ?u64 = null,
    focused_sig: *state_mod.Signal(?*Node),
    ring_color: Color = 0x1C7ED6FF,
    ring_width: f32 = 2, // theme.platform.focus_ring_width
    ring_offset: f32 = 3, // theme.platform.focus_ring_offset

    pub fn init(allocator: std.mem.Allocator) !*FocusManager {
        const fm = try allocator.create(FocusManager);
        fm.* = .{
            .allocator = allocator,
            .focused_sig = try state_mod.Signal(?*Node).init(allocator, null),
        };
        return fm;
    }

    pub fn deinit(fm: *FocusManager) void {
        fm.focused_sig.deinit();
        fm.allocator.destroy(fm);
    }

    pub fn setRoot(fm: *FocusManager, root: *Node) void {
        fm.root = root.ref();
    }

    /// The focus tree root (setRoot), if it is still alive.
    pub fn rootNode(fm: *FocusManager) ?*Node {
        return if (fm.root) |id| node_mod.resolve(id) else null;
    }

    /// The focused node, if it is still alive — a destroyed focus target
    /// resolves null (no stale pointer, no notification needed).
    pub fn focusedNode(fm: *FocusManager) ?*Node {
        return if (fm.focused) |id| node_mod.resolve(id) else null;
    }

    /// The focusable nodes in semantic-tree order (freshly computed — the
    /// tree is retained, but subtrees come and go).
    pub fn focusOrder(fm: *FocusManager, allocator: std.mem.Allocator) ![]*Node {
        const root = fm.rootNode() orelse return &.{};
        var tree = try buildSemanticTree(allocator, root);
        defer tree.deinit(allocator);
        var list = std.array_list.Managed(*Node).init(allocator);
        errdefer list.deinit();
        try collectFocusable(&tree, &list);
        return list.toOwnedSlice();
    }

    fn collectFocusable(sn: *const SemanticNode, list: *std.array_list.Managed(*Node)) !void {
        if (sn.focusable) try list.append(sn.node);
        for (sn.children) |*c| try collectFocusable(c, list);
    }

    pub fn focusNode(fm: *FocusManager, node: ?*Node) void {
        fm.setFocused(node);
        input_mod.requestFocus(node); // the router delivers keys to the focused node
    }

    /// The input router's focus changed from outside (pointer click on a
    /// TextField, Escape blur) — sync the ring/signal/bridge without
    /// re-entering the router.
    pub fn onRouterFocusChanged(fm: *FocusManager, node: ?*Node) void {
        fm.setFocused(node);
    }

    fn setFocused(fm: *FocusManager, node: ?*Node) void {
        const new_id: ?u64 = if (node) |n| n.ref() else null;
        if (fm.focused == new_id) return;
        // Damage the old + new ring regions (mapped to window space) so the
        // host repaints exactly what the ring vacated/occupies. The old node
        // is also marked dirty (wakeup): its focus styling must repaint, and
        // its damage_overflow covers paint beyond its bounds (a text field's
        // cutout label) that the ring rect (ring_offset) would miss.
        if (fm.rootNode()) |r| {
            if (fm.focusedNode()) |old| {
                old.markDirty();
                r.markDirtyRect(ringRect(old, fm.ring_offset));
            }
            if (node) |new| r.markDirtyRect(ringRect(new, fm.ring_offset));
        }
        fm.focused = new_id;
        fm.focused_sig.set(node);
        if (node) |n| n.markDirty();
        notifyBridge(.{ .kind = .focus_changed, .node = node });
    }

    pub fn focusNext(fm: *FocusManager) void {
        const order = fm.focusOrder(fm.allocator) catch @panic("klaxon: out of memory");
        defer fm.allocator.free(order);
        if (order.len == 0) return;
        // No focus yet → start at the first node.
        const idx = indexOf(order, fm.focused) orelse order.len - 1;
        fm.focusNode(order[(idx + 1) % order.len]);
    }

    pub fn focusPrev(fm: *FocusManager) void {
        const order = fm.focusOrder(fm.allocator) catch @panic("klaxon: out of memory");
        defer fm.allocator.free(order);
        if (order.len == 0) return;
        const idx = indexOf(order, fm.focused) orelse 0;
        fm.focusNode(order[(idx + order.len - 1) % order.len]);
    }

    fn indexOf(order: []const *Node, id: ?u64) ?usize {
        for (order, 0..) |n, i| {
            if (n.id == id) return i;
        }
        return null;
    }

    /// Keyboard handling for the focused node: Tab/Shift+Tab move the focus,
    /// Enter/Space activate (a synthesized click at the node's visual
    /// center). Returns true when the event was consumed. Other keys are
    /// left to the focused node (the router dispatches them first).
    pub fn handleKey(fm: *FocusManager, ev: input_mod.KeyEvent) bool {
        if (ev.kind != .key_down) return false;
        switch (ev.key) {
            .tab => {
                if (ev.shift) {
                    fm.focusPrev();
                } else {
                    fm.focusNext();
                }
                return true;
            },
            .enter, .space => {
                const n = fm.focusedNode() orelse return false;
                // Only nodes advertising the activate action are activated:
                // a slider has increment/decrement — a center click would
                // reset its value to 50%.
                const sem = n.semantics orelse return false;
                if (!sem.actions.contains(.activate)) return false;
                activateNode(fm, n);
                return true;
            },
            else => return false,
        }
    }

    /// Activate a node = synthesize down+up at its center, delivered straight
    /// to the node's own on_pointer (coordinates in the node's parent space,
    /// which is what on_pointer handlers compare against bounds). Bubbles up
    /// when the node has no pointer handler. Bypasses the router's hit-test
    /// on purpose: the deepest child (e.g. a Button's Text) would receive
    /// the event with child-local coordinates.
    fn activateNode(fm: *FocusManager, node: *Node) void {
        // Dispatch through the router like a real tap (kx_a11y_activate_node
        // does the same): each phase re-hit-tests, so a .down handler that
        // tears down its own subtree can't make the .up dereference freed
        // nodes — the direct down+up-on-the-same-node loop did.
        if (fm.rootNode()) |root| {
            if (input_mod.current()) |router| {
                const r = node.mapRectToRoot(node.bounds);
                router.dispatchPointer(root, .{ .phase = .down, .x = r.x + r.w / 2, .y = r.y + r.h / 2 });
                router.dispatchPointer(root, .{ .phase = .up, .x = r.x + r.w / 2, .y = r.y + r.h / 2 });
                return;
            }
        }
        // No router in context (unit tests, headless callers): synthesize
        // down+up on the nearest pointer-handling ancestor directly. The
        // traversal freeze matters here too: a .down handler that deinits
        // its subtree defers the destroy, so .up can't land on freed state.
        node_mod.traversalBegin();
        defer node_mod.traversalEnd();
        var n: ?*Node = node;
        while (n) |cur| {
            if (cur.zombie) return; // freed by the .down
            if (cur.vtable.on_pointer) |op| {
                const cx = cur.bounds.x + cur.bounds.w / 2;
                const cy = cur.bounds.y + cur.bounds.h / 2;
                _ = op(cur, .{ .phase = .down, .x = cx, .y = cy });
                if (!cur.zombie) _ = op(cur, .{ .phase = .up, .x = cx, .y = cy });
                return;
            }
            n = cur.parent;
        }
    }

    /// Paint the focus ring around the focused node (the host calls this
    /// after painting the tree). 4 fillRects — no stroke primitive needed.
    pub fn paintRing(fm: *FocusManager, ctx: *kx.Ctx) void {
        const n = fm.focusedNode() orelse return;
        const r = ringRect(n, fm.ring_offset);
        const w = fm.ring_width;
        const c = fm.ring_color;
        paint_mod.fillRect(ctx, r.x, r.y, r.w, w, c); // top
        paint_mod.fillRect(ctx, r.x, r.y + r.h - w, r.w, w, c); // bottom
        paint_mod.fillRect(ctx, r.x, r.y, w, r.h, c); // left
        paint_mod.fillRect(ctx, r.x + r.w - w, r.y, w, r.h, c); // right
    }
};

// --- process-global focus manager (single-window P0, like the router) ---

var current_focus: ?*FocusManager = null;

pub fn setCurrentFocus(fm: ?*FocusManager) void {
    current_focus = fm;
}

pub fn currentFocus() ?*FocusManager {
    return current_focus;
}

/// The router's focus moved (pointer) — sync the process-global focus manager.
pub fn routerFocusChanged(node: ?*Node) void {
    if (current_focus) |fm| fm.onRouterFocusChanged(node);
}

/// First focusable node in `n`'s subtree (depth-first, skipping invisible
/// or semantics-excluded subtrees).
pub fn firstFocusableIn(n: *Node) ?*Node {
    if (semanticSkipped(n)) return null;
    if (n.semantics) |sem| {
        if (sem.focusable and !sem.disabled) return n;
    }
    for (n.children.items) |c| {
        if (firstFocusableIn(c)) |f| return f;
    }
    return null;
}

fn nodeContains(root: *Node, target: *Node) bool {
    if (root == target) return true;
    for (root.children.items) |c| {
        if (nodeContains(c, target)) return true;
    }
    return false;
}

/// Move keyboard focus into `panel` when a modal opens (saving the prior
/// focus), and restore the prior focus when the modal closes. `saved_focus`
/// holds a weak node id — the saved node may be destroyed while the modal
/// is open, and a dead id simply resolves to no restore.
pub fn syncModalFocus(panel: *Node, is_open: bool, saved_focus: *?u64, focus_saved: *bool) void {
    if (is_open) {
        if (!focus_saved.*) {
            const fm_opt = currentFocus();
            const cur = if (fm_opt) |fm| fm.focusedNode() else if (input_mod.current()) |r| r.focusedNode() else null;
            saved_focus.* = if (cur) |c| c.ref() else null;
            focus_saved.* = true;
            const target = firstFocusableIn(panel);
            if (target != null or (cur != null and !nodeContains(panel, cur.?))) {
                if (fm_opt) |fm| {
                    fm.focusNode(target);
                } else {
                    input_mod.requestFocus(target);
                }
            }
            notifyTreeDirty();
        }
    } else {
        if (focus_saved.*) {
            focus_saved.* = false;
            const prev = saved_focus.*;
            saved_focus.* = null;
            // A destroyed saved focus resolves null — the zombie check it
            // replaces. A survivor detached from the tree (a replaced page)
            // is dropped too.
            const valid_prev: ?*Node = if (prev) |pid| blk: {
                const p = node_mod.resolve(pid) orelse break :blk null;
                if (currentFocus()) |fm| {
                    if (fm.rootNode()) |r| {
                        if (!nodeContains(r, p)) break :blk null;
                    }
                }
                break :blk p;
            } else null;
            if (currentFocus()) |fm| {
                fm.focusNode(valid_prev);
            } else {
                input_mod.requestFocus(valid_prev);
            }
            notifyTreeDirty();
        }
    }
}

// --- tests ---

// A leaf node with a fixed size + a click counter (stands in for a Button).
const ClickState = struct { clicks: u32 = 0 };

fn clickMeasure(n: *Node, c: layout_mod.Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = 100, .h = 40 });
}
fn clickLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn clickPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}
fn clickOnPointer(n: *Node, ev: input_mod.PointerEvent) bool {
    const s: *ClickState = @ptrCast(@alignCast(n.state.?));
    switch (ev.phase) {
        .down => return true,
        .up => {
            if (n.bounds.contains(ev.x, ev.y)) s.clicks += 1;
            return true;
        },
        else => {},
    }
    return false;
}
fn clickDeinit(n: *Node) void {
    n.allocator.destroy(@as(*ClickState, @ptrCast(@alignCast(n.state.?))));
}
const click_vtable = node_mod.VTable{
    .measure = clickMeasure,
    .layout = clickLayout,
    .paint = clickPaint,
    .deinit = clickDeinit,
    .on_pointer = clickOnPointer,
};

fn clickNode(allocator: std.mem.Allocator) !*Node {
    const node = try Node.create(allocator, &click_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(ClickState);
    errdefer allocator.destroy(s);
    s.* = .{};
    node.state = s;
    return node;
}

fn countFired(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "semantic tree: flatten, label fallback, exclude_semantics, nesting" {
    const a = std.testing.allocator;
    const root = try clickNode(a); // transparent container (no semantics)
    defer root.deinit();
    const hello = try clickNode(a);
    attach(hello, .{ .role = .text, .label = "Hello" });
    root.add(hello);
    const btn = try clickNode(a);
    attach(btn, .{ .role = .button, .focusable = true, .actions = Actions.initOne(.activate) });
    root.add(btn);
    const submit = try clickNode(a);
    attach(submit, .{ .role = .text, .label = "Submit" });
    btn.add(submit); // the button's label falls back to its Text child
    const hidden = try clickNode(a);
    attach(hidden, .{ .role = .text, .label = "Hidden" });
    hidden.exclude_semantics = true;
    root.add(hidden);
    const list = try clickNode(a);
    attach(list, .{ .role = .list });
    root.add(list);
    const item = try clickNode(a);
    attach(item, .{ .role = .list_item, .label = "One" });
    list.add(item);

    var tree = try buildSemanticTree(a, root);
    defer tree.deinit(a);
    try std.testing.expectEqual(Role.group, tree.role);
    try std.testing.expectEqual(@as(usize, 3), tree.children.len); // hello, btn, list (hidden excluded)
    try std.testing.expectEqual(Role.text, tree.children[0].role);
    try std.testing.expectEqualStrings("Hello", tree.children[0].label);
    try std.testing.expectEqual(Role.button, tree.children[1].role);
    try std.testing.expectEqualStrings("Submit", tree.children[1].label); // fallback
    try std.testing.expect(tree.children[1].focusable);
    try std.testing.expect(tree.children[1].actions.contains(.activate));
    try std.testing.expectEqual(Role.list, tree.children[2].role);
    try std.testing.expectEqual(@as(usize, 1), tree.children[2].children.len);
    try std.testing.expectEqual(Role.list_item, tree.children[2].children[0].role);
}

test "focus order: next/prev wrap around the semantic tree" {
    const a = std.testing.allocator;
    const root = try clickNode(a);
    defer root.deinit();
    const first = try clickNode(a);
    attach(first, .{ .role = .button, .focusable = true });
    root.add(first);
    const plain = try clickNode(a); // not focusable
    root.add(plain);
    const second = try clickNode(a);
    attach(second, .{ .role = .toggle, .focusable = true, .checked = false });
    root.add(second);

    const fm = try FocusManager.init(a);
    defer fm.deinit();
    fm.setRoot(root);

    const order = try fm.focusOrder(a);
    defer a.free(order);
    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expect(order[0] == first and order[1] == second);

    fm.focusNext();
    try std.testing.expect(fm.focusedNode() == first);
    fm.focusNext();
    try std.testing.expect(fm.focusedNode() == second);
    fm.focusNext(); // wraps
    try std.testing.expect(fm.focusedNode() == first);
    fm.focusPrev(); // wraps back
    try std.testing.expect(fm.focusedNode() == second);
}

test "focusNode: signal fires, router focuses, bridge notified" {
    const a = std.testing.allocator;
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    const lb = try LogBridge.init(a);
    defer lb.deinit();
    setBridge(lb.bridge());
    defer setBridge(null);

    const root = try clickNode(a);
    defer root.deinit();
    const node = try clickNode(a);
    attach(node, .{ .role = .button, .focusable = true });
    root.add(node);

    const fm = try FocusManager.init(a);
    defer fm.deinit();
    fm.setRoot(root);
    var sig_fired: u32 = 0;
    fm.focused_sig.subscribe(.{ .callback = .{ .fn_ptr = countFired, .userdata = &sig_fired } });

    fm.focusNode(node);
    try std.testing.expectEqual(@as(u32, 1), sig_fired);
    try std.testing.expect(router.focusedNode() == node);
    try std.testing.expectEqual(@as(usize, 1), lb.events.items.len);
    try std.testing.expectEqual(BridgeEvent.Kind.focus_changed, lb.events.items[0].kind);
    try std.testing.expectEqual(@intFromPtr(node), lb.events.items[0].node_id);
    fm.focusNode(node); // no-op: no signal, no event
    try std.testing.expectEqual(@as(u32, 1), sig_fired);
    try std.testing.expectEqual(@as(usize, 1), lb.events.items.len);
    fm.focusNode(null);
    try std.testing.expectEqual(@as(u32, 2), sig_fired);
    try std.testing.expect(router.focused == null);
}

test "handleKey: tab moves focus, enter/space activate (synthesized click)" {
    const a = std.testing.allocator;
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);

    const root = try clickNode(a); // the root IS the button (no parent transforms)
    defer root.deinit();
    attach(root, .{ .role = .button, .focusable = true, .actions = Actions.initOne(.activate) });
    root.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    const clicks = &@as(*ClickState, @ptrCast(@alignCast(root.state.?))).clicks;

    const fm = try FocusManager.init(a);
    defer fm.deinit();
    fm.setRoot(root);
    fm.focusNode(root);
    try std.testing.expectEqual(@as(u32, 0), clicks.*);

    // Tab with a single focusable wraps onto itself.
    try std.testing.expect(fm.handleKey(.{ .kind = .key_down, .key = .tab }));
    try std.testing.expect(fm.focusedNode() == root);
    try std.testing.expect(fm.handleKey(.{ .kind = .key_down, .key = .tab, .shift = true }));
    try std.testing.expect(fm.focusedNode() == root);

    // Enter/Space activate: a synthesized click at the visual center.
    try std.testing.expect(fm.handleKey(.{ .kind = .key_down, .key = .enter }));
    try std.testing.expectEqual(@as(u32, 1), clicks.*);
    try std.testing.expect(fm.handleKey(.{ .kind = .key_down, .key = .space }));
    try std.testing.expectEqual(@as(u32, 2), clicks.*);

    // Other keys are not consumed by the focus manager (the node's on_key
    // gets them first via the router).
    try std.testing.expect(!fm.handleKey(.{ .kind = .key_down, .key = .left }));
    try std.testing.expect(!fm.handleKey(.{ .kind = .text_input, .text = "x" }));
}

test "announce + LogBridge records live-region events" {
    const a = std.testing.allocator;
    const lb = try LogBridge.init(a);
    defer lb.deinit();
    setBridge(lb.bridge());
    defer setBridge(null);
    announce("3 items added", .polite);
    notifyTreeDirty();
    try std.testing.expectEqual(@as(usize, 2), lb.events.items.len);
    try std.testing.expectEqual(BridgeEvent.Kind.announce, lb.events.items[0].kind);
    try std.testing.expectEqualStrings("3 items added", lb.events.items[0].text);
    try std.testing.expectEqual(LiveRegion.polite, lb.events.items[0].region);
    try std.testing.expectEqual(BridgeEvent.Kind.tree_dirty, lb.events.items[1].kind);
}

test "a destroyed focused node resolves to no focus" {
    const a = std.testing.allocator;
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    const root = try clickNode(a);
    defer root.deinit();
    const node = try clickNode(a);
    attach(node, .{ .role = .button, .focusable = true });
    root.add(node);
    const fm = try FocusManager.init(a);
    defer fm.deinit();
    setCurrentFocus(fm);
    defer setCurrentFocus(null);
    fm.setRoot(root);
    fm.focusNode(node);
    try std.testing.expect(fm.focusedNode() == node);
    _ = root.remove(node);
    node.deinit(); // the weak id dies with the node — no notification needed
    try std.testing.expect(fm.focusedNode() == null);
    try std.testing.expect(router.focusedNode() == null);
    // And the focus still moves normally afterwards.
    fm.focusNode(root);
    try std.testing.expect(fm.focusedNode() == root);
}

test "routerFocusChanged: pointer focus syncs the focus manager" {
    const a = std.testing.allocator;
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    const root = try clickNode(a);
    defer root.deinit();
    const node = try clickNode(a);
    attach(node, .{ .role = .text_field, .focusable = true });
    root.add(node);
    const fm = try FocusManager.init(a);
    defer fm.deinit();
    setCurrentFocus(fm);
    defer setCurrentFocus(null);
    fm.setRoot(root);
    input_mod.requestFocus(node); // pointer path (TextField click)
    try std.testing.expect(fm.focusedNode() == node);
    try std.testing.expect(router.focusedNode() == node);
    input_mod.requestFocus(null); // Escape blur
    try std.testing.expect(fm.focusedNode() == null);
}

test "handleKey: enter/space activate only nodes advertising .activate" {
    const a = std.testing.allocator;
    const root = try clickNode(a); // no activate action — like a slider
    defer root.deinit();
    attach(root, .{ .role = .slider, .focusable = true, .actions = Actions.init(.{ .increment = true, .decrement = true }) });
    root.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    const clicks = &@as(*ClickState, @ptrCast(@alignCast(root.state.?))).clicks;
    const fm = try FocusManager.init(a);
    defer fm.deinit();
    fm.setRoot(root);
    fm.focusNode(root);
    try std.testing.expect(!fm.handleKey(.{ .kind = .key_down, .key = .enter }));
    try std.testing.expectEqual(@as(u32, 0), clicks.*); // the pointer handler never ran
    // A node WITH .activate is activated.
    attach(root, .{ .role = .button, .focusable = true, .actions = Actions.initOne(.activate) });
    try std.testing.expect(fm.handleKey(.{ .kind = .key_down, .key = .space }));
    try std.testing.expectEqual(@as(u32, 1), clicks.*);
}

const CRec = struct {
    count: u32 = 0,
    last_kind: u32 = 0,
    last_region: u32 = 0,
    last_text: [64]u8 = undefined,
    last_text_len: usize = 0,
};

fn cCb(userdata: ?*anyopaque, ev: BridgeEventC) callconv(.c) void {
    const r: *CRec = @ptrCast(@alignCast(userdata.?));
    r.count += 1;
    r.last_kind = ev.kind;
    r.last_region = ev.region;
    const n = @min(ev.text_len, r.last_text.len);
    @memcpy(r.last_text[0..n], ev.text[0..n]);
    r.last_text_len = n;
}

test "setBridgeC: the C-callable bridge receives extern events" {
    var rec = CRec{};
    setBridgeC(cCb, &rec);
    defer setBridgeC(null, null);
    announce("hi", .assertive);
    try std.testing.expectEqual(@as(u32, 1), rec.count);
    try std.testing.expectEqual(@backingInt(BridgeEvent.Kind.announce), rec.last_kind);
    try std.testing.expectEqual(@backingInt(LiveRegion.assertive), rec.last_region);
    try std.testing.expectEqual(@as(usize, 2), rec.last_text_len);
    try std.testing.expectEqualStrings("hi", rec.last_text[0..rec.last_text_len]);
}

test "golden: focus ring paints around the focused node (exact pixels)" {
    const a = std.testing.allocator;
    const bg: Color = 0x000000FF;
    const ring: Color = 0x1C7ED6FF;
    const box: Color = 0xFF0000FF;
    const root = try golden.solidBox(a, 40, 20, box);
    defer root.deinit();
    const fm = try FocusManager.init(a);
    defer fm.deinit();
    fm.ring_color = ring;
    fm.setRoot(root);
    root.layout(.{ .x = 20, .y = 20, .w = 40, .h = 20 });
    var r = try golden.Renderer.init(a, 128, 64);
    defer r.deinit();

    // No focus → no ring.
    r.paint(root, bg);
    var f1 = try r.readback(a);
    defer f1.deinit();
    try std.testing.expectEqual(@as(u64, 0), f1.countColor(ring));

    // Focused → ring around the box (bounds 20,20,40,20 → ring rect 17,17,46,26).
    // The ring paints INSIDE the frame (the host paints it before end_frame).
    fm.focusNode(root);
    kx.c.kx_begin_frame(r.ctx);
    kx.c.kx_clear(r.ctx, bg);
    root.paint(r.ctx, .{ .x = 0, .y = 0, .w = 128, .h = 64 });
    fm.paintRing(r.ctx);
    kx.c.kx_end_frame(r.ctx);
    var f2 = try r.readback(a);
    defer f2.deinit();
    try std.testing.expect(f2.countColor(ring) > 0);
    try std.testing.expectEqual(ring, f2.pixelAt(18, 30)); // left bar (x 17..19)
    try std.testing.expectEqual(ring, f2.pixelAt(40, 18)); // top bar (y 17..19)
    try std.testing.expectEqual(box, f2.pixelAt(40, 30)); // center: the box, not the ring
}

test "focus ring: the offset expands the bounds; the tokens carry width + offset" {
    const n = try clickNode(std.testing.allocator);
    defer n.deinit();
    n.layout(.{ .x = 10, .y = 20, .w = 30, .h = 40 });
    const r = ringRect(n, 4);
    try std.testing.expectEqual(@as(f32, 6), r.x);
    try std.testing.expectEqual(@as(f32, 16), r.y);
    try std.testing.expectEqual(@as(f32, 38), r.w);
    try std.testing.expectEqual(@as(f32, 48), r.h);
    // the FocusManager carries the tokens (mobile defaults)
    const fm = try FocusManager.init(std.testing.allocator);
    defer fm.deinit();
    try std.testing.expectEqual(@as(f32, 2), fm.ring_width);
    try std.testing.expectEqual(@as(f32, 3), fm.ring_offset);
}

test "semantic tree: virtual children emit as leaves with mapped bounds" {
    const a = std.testing.allocator;
    const root = try clickNode(a);
    defer root.deinit();
    const host = try clickNode(a);
    root.add(host);
    root.bounds = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    host.bounds = .{ .x = 10, .y = 5, .w = 80, .h = 40 };
    var kids = [_]Semantics{
        .{ .role = .tab, .label = "One", .checked = true, .actions = Actions.initOne(.activate) },
        .{ .role = .tab, .label = "Two", .checked = false, .disabled = true },
    };
    const S = struct {
        fn childBounds(n: *Node, i: usize) Rect {
            _ = n;
            return .{ .x = @floatFromInt(i * 40), .y = 0, .w = 40, .h = 40 };
        }
    };
    attach(host, .{
        .role = .group,
        .label = "Tabs",
        .children = &kids,
        .child_bounds = S.childBounds,
    });

    var tree = try buildSemanticTree(a, root);
    defer tree.deinit(a);
    // root is transparent and host's group is the sole frontier node — it
    // IS the returned root (no extra wrapper).
    const grp = tree;
    try std.testing.expectEqualStrings("Tabs", grp.label);
    try std.testing.expectEqual(@as(usize, 2), grp.children.len);
    const t0 = grp.children[0];
    try std.testing.expectEqual(Role.tab, t0.role);
    try std.testing.expectEqualStrings("One", t0.label);
    try std.testing.expect(t0.checked.?);
    try std.testing.expect(t0.virtual_index != null);
    try std.testing.expectEqual(@as(usize, 0), t0.children.len); // leaf
    // Bounds: child_bounds is node-local → window space via mapRectToRoot.
    const r0 = t0.bounds_override.?;
    try std.testing.expectEqual(@as(f32, 10), r0.x); // host.x + item x
    try std.testing.expectEqual(@as(f32, 5), r0.y);
    const t1 = grp.children[1];
    try std.testing.expect(t1.disabled);
    try std.testing.expectEqual(@as(f32, 50), t1.bounds_override.?.x);
}

test "modal semantics: active modal scopes semantic tree + focusOrder and restores focus on close" {
    const a = std.testing.allocator;
    const fm = try FocusManager.init(a);
    defer fm.deinit();
    setCurrentFocus(fm);
    defer setCurrentFocus(null);

    const root = try clickNode(a);
    defer root.deinit();
    fm.setRoot(root);
    const bg_btn = try clickNode(a);
    attach(bg_btn, .{ .role = .button, .label = "Background", .focusable = true });
    root.add(bg_btn);

    const modal_panel = try clickNode(a);
    attach(modal_panel, .{ .role = .dialog, .label = "Confirm", .modal = true });
    modal_panel.visible = false;
    const modal_btn = try clickNode(a);
    attach(modal_btn, .{ .role = .button, .label = "OK", .focusable = true });
    modal_panel.add(modal_btn);
    root.add(modal_panel);

    fm.focusNode(bg_btn);
    try std.testing.expect(fm.focusedNode() == bg_btn);

    var saved: ?u64 = null;
    var is_saved: bool = false;
    modal_panel.visible = true;
    syncModalFocus(modal_panel, true, &saved, &is_saved);
    try std.testing.expect(fm.focusedNode() == modal_btn);

    const order = try fm.focusOrder(a);
    defer a.free(order);
    try std.testing.expectEqual(@as(usize, 1), order.len);
    try std.testing.expect(order[0] == modal_btn);

    modal_panel.visible = false;
    syncModalFocus(modal_panel, false, &saved, &is_saved);
    try std.testing.expect(fm.focusedNode() == bg_btn);
}
