// a11y_bridge.zig — Zig side of the OS accessibility bridges (Phase 3a/3de).
//
// Exposes C-callable functions consumed by kx_a11y_macos.mm (NSAccessibility)
// and kx_a11y_ios.mm (UIAccessibility):
//   - kx_a11y_set_bridge: registers the C bridge callback (wraps setBridgeC)
//   - kx_a11y_dump_tree: serializes the semantic tree to a flat text dump
//   - kx_a11y_free_string: frees a string allocated by kx_a11y_dump_tree
//   - kx_a11y_focus_node / kx_a11y_activate_node: VoiceOver → Klaxon (the
//     iOS bridge calls them when VoiceOver focuses/activates an element)
//
// The dump format (one line per visible semantic node):
//   "depth|role|label|value|focusable|ptr|checked|x|y|w|h\n"
// depth is the indentation level (0 = root). ptr is the Node pointer in
// decimal — bridges match it against the node_id of focus_changed /
// control_changed events. checked is 0 = null, 1 = false, 2 = true.
// x/y/w/h are the node's bounds mapped to window space (mapRectToRoot) —
// the native bridges position their accessibility elements from these
// (the macOS parser reads them positionally; the web parser ignores them).
const std = @import("std");
const ui = @import("ui.zig");
const kx = @import("kx.zig");
const Node = ui.node.Node;
const sem = ui.semantics;
const input_mod = ui.input;

const c = @import("kx.zig").c;

/// Install (or clear) the C bridge callback. Wraps semantics.setBridgeC.
export fn kx_a11y_set_bridge(
    fn_ptr: ?*const fn (userdata: ?*anyopaque, event: sem.BridgeEventC) callconv(.c) void,
    userdata: ?*anyopaque,
) void {
    sem.setBridgeC(fn_ptr, userdata);
}

/// Serialize the semantic tree to a flat text dump. Returns a malloc'd
/// C string (caller must free with kx_a11y_free_string) or null on error.
export fn kx_a11y_dump_tree(root_node: ?*anyopaque) callconv(.c) ?[*]u8 {
    const root: *Node = @ptrCast(@alignCast(root_node orelse return null));
    var tree = sem.buildSemanticTree(std.heap.c_allocator, root) catch return null;
    defer tree.deinit(std.heap.c_allocator);

    var buf = std.array_list.Managed(u8).init(std.heap.c_allocator);
    dumpNode(&tree, 0, &buf) catch {
        buf.deinit();
        return null;
    };
    // Null-terminate. On success the buffer's ownership transfers to the
    // caller (kx_a11y_free_string) — it must NOT be deinited here (the
    // returned pointer would dangle: use-after-free on the bridge side).
    buf.append(0) catch {
        buf.deinit();
        return null;
    };
    const result: [*]u8 = buf.items.ptr;
    return result;
}

/// Free a string allocated by kx_a11y_dump_tree.
export fn kx_a11y_free_string(s: ?[*]u8) callconv(.c) void {
    if (s) |ptr| {
        // Find the length (null-terminated).
        var len: usize = 0;
        while (ptr[len] != 0) : (len += 1) {}
        std.heap.c_allocator.free(ptr[0..len :0]);
    }
}

/// VoiceOver focused an element (accessibilityElementDidBecomeFocused on
/// iOS) — move Klaxon's focus to the matching node. `ptr` is the Node
/// pointer from the dump (matched against @intFromPtr).
export fn kx_a11y_focus_node(root: ?*anyopaque, ptr: u64) callconv(.c) void {
    const root_node: *Node = @ptrCast(@alignCast(root orelse return));
    const node = findNodeByPtr(root_node, ptr) orelse return;
    if (sem.currentFocus()) |fm| fm.focusNode(node);
}

/// VoiceOver double-tap (accessibilityActivate on iOS) — synthesize
/// down+up at the node's visual center through the input router (a click
/// at window coordinates: mapRectToRoot(bounds) center).
export fn kx_a11y_activate_node(root: ?*anyopaque, ptr: u64) callconv(.c) void {
    const root_node: *Node = @ptrCast(@alignCast(root orelse return));
    const node = findNodeByPtr(root_node, ptr) orelse return;
    const router = input_mod.current() orelse return;
    const r = node.mapRectToRoot(node.bounds);
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    router.dispatchPointer(root_node, .{ .phase = .down, .x = cx, .y = cy });
    router.dispatchPointer(root_node, .{ .phase = .up, .x = cx, .y = cy });
}

/// Depth-first search for the node whose pointer is `ptr` (the dump's ptr
/// field — semantic nodes only, but the raw tree is walked so any node
/// matches).
fn findNodeByPtr(node: *Node, ptr: u64) ?*Node {
    if (@intFromPtr(node) == ptr) return node;
    for (node.children.items) |child| {
        if (findNodeByPtr(child, ptr)) |n| return n;
    }
    return null;
}

fn dumpNode(sn: *sem.SemanticNode, depth: usize, buf: *std.array_list.Managed(u8)) !void {
    // Format: "depth|role|label|value|focusable|ptr|checked|x|y|w|h\n"
    const role_str = @tagName(sn.role);
    const label = if (sn.label.len > 0) sn.label else "";
    const value = if (sn.value.len > 0) sn.value else "";
    const focusable: u8 = if (sn.focusable) 1 else 0;
    const ptr: u64 = @intFromPtr(sn.node);
    // checked: 0 = null, 1 = false, 2 = true (?bool unwrapped — Zig does
    // not switch on an optional directly).
    const checked: u8 = if (sn.checked) |on| (if (on) 2 else 1) else 0;
    // Real rect: the node's bounds in window space — the bridges position
    // their elements from these (Phase 3de; was 0|0|0|0).
    const r = sn.node.mapRectToRoot(sn.node.bounds);

    var line_buf: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{d}|{s}|{s}|{s}|{d}|{d}|{d}|{d}|{d}|{d}|{d}\n", .{
        depth, role_str, label, value, focusable, ptr, checked, r.x, r.y, r.w, r.h,
    }) catch return;
    try buf.appendSlice(line);

    for (sn.children) |*child| {
        try dumpNode(child, depth + 1, buf);
    }
}

// --- tests ---

// A fixed-size node with a click counter (stands in for a Button).
const ClickState = struct { clicks: u32 = 0 };

fn tMeasure(n: *Node, cons: ui.layout.Constraints) ui.layout.Size {
    _ = n;
    return cons.constrain(.{ .w = 100, .h = 40 });
}
fn tLayout(n: *Node, bounds: ui.node.Rect) void {
    _ = n;
    _ = bounds;
}
fn tPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}
fn tOnPointer(n: *Node, ev: ui.input.PointerEvent) bool {
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
fn tDeinit(n: *Node) void {
    n.allocator.destroy(@as(*ClickState, @ptrCast(@alignCast(n.state.?))));
}
const t_vtable = ui.node.VTable{
    .measure = tMeasure,
    .layout = tLayout,
    .paint = tPaint,
    .deinit = tDeinit,
    .on_pointer = tOnPointer,
};

fn tNode(a: std.mem.Allocator) !*Node {
    const node = try Node.create(a, &t_vtable);
    errdefer node.allocator.destroy(node);
    const s = try a.create(ClickState);
    errdefer a.destroy(s);
    s.* = .{};
    node.state = s;
    return node;
}

fn fieldAt(line: []const u8, idx: usize) ?[]const u8 {
    var it = std.mem.splitScalar(u8, line, '|');
    var i: usize = 0;
    while (it.next()) |f| : (i += 1) {
        if (i == idx) return f;
    }
    return null;
}

fn countFields(line: []const u8) usize {
    var it = std.mem.splitScalar(u8, line, '|');
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

test "dump tree: 11 positional fields with real window-space rects" {
    const a = std.testing.allocator;
    const root = try tNode(a);
    defer root.deinit();
    const btn = try tNode(a);
    sem.attach(btn, .{ .role = .button, .label = "OK", .focusable = true });
    root.add(btn);
    const toggle = try tNode(a);
    sem.attach(toggle, .{ .role = .toggle, .label = "Wi-Fi", .focusable = true, .checked = true });
    root.add(toggle);
    root.layout(.{ .x = 0, .y = 0, .w = 640, .h = 480 });
    btn.layout(.{ .x = 10, .y = 20, .w = 100, .h = 40 });
    toggle.layout(.{ .x = 10, .y = 70, .w = 100, .h = 40 });

    const root_any: ?*anyopaque = @ptrCast(root);
    const dump_ptr = kx_a11y_dump_tree(root_any) orelse return error.TestUnexpectedResult;
    defer kx_a11y_free_string(dump_ptr);
    const dump: [:0]const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(dump_ptr)));

    // 3 lines: the synthetic wrapper group (depth 0) + button + toggle.
    var lines: [3][]const u8 = undefined;
    var n_lines: usize = 0;
    var it = std.mem.splitScalar(u8, dump, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(n_lines < lines.len);
        lines[n_lines] = line;
        n_lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n_lines);

    // Wrapper group: empty label/value, the root's rect (0,0,640,480).
    try std.testing.expectEqual(@as(usize, 11), countFields(lines[0]));
    try std.testing.expectEqualStrings("0", fieldAt(lines[0], 0).?);
    try std.testing.expectEqualStrings("group", fieldAt(lines[0], 1).?);
    try std.testing.expectEqualStrings("0", fieldAt(lines[0], 4).?);
    try std.testing.expectEqual(@intFromPtr(root), try std.fmt.parseInt(u64, fieldAt(lines[0], 5).?, 10));
    try std.testing.expectEqualStrings("0", fieldAt(lines[0], 7).?);
    try std.testing.expectEqualStrings("0", fieldAt(lines[0], 8).?);
    try std.testing.expectEqualStrings("640", fieldAt(lines[0], 9).?);
    try std.testing.expectEqualStrings("480", fieldAt(lines[0], 10).?);

    // Button: label, focusable, its real rect — not 0|0|0|0.
    try std.testing.expectEqual(@as(usize, 11), countFields(lines[1]));
    try std.testing.expectEqualStrings("1", fieldAt(lines[1], 0).?);
    try std.testing.expectEqualStrings("button", fieldAt(lines[1], 1).?);
    try std.testing.expectEqualStrings("OK", fieldAt(lines[1], 2).?);
    try std.testing.expectEqualStrings("1", fieldAt(lines[1], 4).?);
    try std.testing.expectEqual(@intFromPtr(btn), try std.fmt.parseInt(u64, fieldAt(lines[1], 5).?, 10));
    try std.testing.expectEqualStrings("0", fieldAt(lines[1], 6).?); // checked = null
    try std.testing.expectEqualStrings("10", fieldAt(lines[1], 7).?);
    try std.testing.expectEqualStrings("20", fieldAt(lines[1], 8).?);
    try std.testing.expectEqualStrings("100", fieldAt(lines[1], 9).?);
    try std.testing.expectEqualStrings("40", fieldAt(lines[1], 10).?);

    // Toggle: checked = 2 (true), its real rect.
    try std.testing.expectEqual(@as(usize, 11), countFields(lines[2]));
    try std.testing.expectEqualStrings("toggle", fieldAt(lines[2], 1).?);
    try std.testing.expectEqualStrings("2", fieldAt(lines[2], 6).?);
    try std.testing.expectEqualStrings("10", fieldAt(lines[2], 7).?);
    try std.testing.expectEqualStrings("70", fieldAt(lines[2], 8).?);
    try std.testing.expectEqualStrings("100", fieldAt(lines[2], 9).?);
    try std.testing.expectEqualStrings("40", fieldAt(lines[2], 10).?);
}

test "kx_a11y_focus_node: VoiceOver focus moves Klaxon's focus to the node" {
    const a = std.testing.allocator;
    var router = ui.input.InputRouter{};
    ui.input.setCurrent(&router);
    defer ui.input.setCurrent(null);
    const fm = try sem.FocusManager.init(a);
    defer fm.deinit();
    sem.setCurrentFocus(fm);
    defer sem.setCurrentFocus(null);

    const root = try tNode(a);
    defer root.deinit();
    const btn = try tNode(a);
    sem.attach(btn, .{ .role = .button, .label = "OK", .focusable = true });
    root.add(btn);
    root.layout(.{ .x = 0, .y = 0, .w = 640, .h = 480 });
    btn.layout(.{ .x = 10, .y = 20, .w = 100, .h = 40 });
    fm.setRoot(root);

    const root_any: ?*anyopaque = @ptrCast(root);
    kx_a11y_focus_node(root_any, @intFromPtr(btn));
    try std.testing.expect(fm.focused == btn);
    try std.testing.expect(router.focused == btn);

    // Unknown ptr / null root: no-op.
    kx_a11y_focus_node(root_any, 0xDEAD_BEEF);
    try std.testing.expect(fm.focused == btn);
    kx_a11y_focus_node(null, @intFromPtr(btn));
    try std.testing.expect(fm.focused == btn);
}

test "kx_a11y_activate_node: double-tap synthesizes down+up at the node's center" {
    const a = std.testing.allocator;
    var router = ui.input.InputRouter{};
    ui.input.setCurrent(&router);
    defer ui.input.setCurrent(null);

    const root = try tNode(a);
    defer root.deinit();
    const btn = try tNode(a);
    sem.attach(btn, .{ .role = .button, .label = "OK", .focusable = true });
    root.add(btn);
    root.layout(.{ .x = 0, .y = 0, .w = 640, .h = 480 });
    btn.layout(.{ .x = 10, .y = 20, .w = 100, .h = 40 });
    const clicks = &@as(*ClickState, @ptrCast(@alignCast(btn.state.?))).clicks;

    const root_any: ?*anyopaque = @ptrCast(root);
    kx_a11y_activate_node(root_any, @intFromPtr(btn));
    try std.testing.expectEqual(@as(u32, 1), clicks.*);

    // Unknown ptr / null root: no click.
    kx_a11y_activate_node(root_any, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 1), clicks.*);
    kx_a11y_activate_node(null, @intFromPtr(btn));
    try std.testing.expectEqual(@as(u32, 1), clicks.*);
}

test "dump_tree(null) returns null; free_string(null) is a no-op" {
    try std.testing.expect(kx_a11y_dump_tree(null) == null);
    kx_a11y_free_string(null); // must not crash
}

test "dump tree: checked=false serializes as 1 and the value lands at field 3" {
    const a = std.testing.allocator;
    const root = try tNode(a);
    defer root.deinit();
    const sw = try tNode(a);
    sem.attach(sw, .{ .role = .toggle, .label = "Wi-Fi", .value = "off", .focusable = true, .checked = false });
    root.add(sw);
    root.layout(.{ .x = 0, .y = 0, .w = 640, .h = 480 });
    sw.layout(.{ .x = 5, .y = 6, .w = 100, .h = 40 });

    const dump_ptr = kx_a11y_dump_tree(@ptrCast(root)) orelse return error.TestUnexpectedResult;
    defer kx_a11y_free_string(dump_ptr);
    const dump: [:0]const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(dump_ptr)));

    // a single semantic node is the root itself — no synthetic wrapper group
    var it = std.mem.splitScalar(u8, dump, '\n');
    const line = it.next().?;
    try std.testing.expectEqual(@as(usize, 11), countFields(line));
    try std.testing.expectEqualStrings("0", fieldAt(line, 0).?); // depth
    try std.testing.expectEqualStrings("toggle", fieldAt(line, 1).?);
    try std.testing.expectEqualStrings("Wi-Fi", fieldAt(line, 2).?); // label
    try std.testing.expectEqualStrings("off", fieldAt(line, 3).?); // value
    try std.testing.expectEqualStrings("1", fieldAt(line, 4).?); // focusable
    try std.testing.expectEqualStrings("1", fieldAt(line, 6).?); // checked = false → 1
    try std.testing.expectEqualStrings("5", fieldAt(line, 7).?); // the real rect
    try std.testing.expectEqualStrings("6", fieldAt(line, 8).?);
    try std.testing.expectEqualStrings("100", fieldAt(line, 9).?);
    try std.testing.expectEqualStrings("40", fieldAt(line, 10).?);
    // only the trailing newline remains
    const rest = it.next();
    try std.testing.expect(rest != null);
    try std.testing.expectEqual(@as(usize, 0), rest.?.len);
    try std.testing.expect(it.next() == null);
}

test "dump tree: grandchildren are depth-first at depth 2" {
    const a = std.testing.allocator;
    const root = try tNode(a);
    defer root.deinit();
    const first = try tNode(a);
    sem.attach(first, .{ .role = .button, .label = "A", .focusable = true });
    const parent = try tNode(a);
    sem.attach(parent, .{ .role = .group, .label = "P" });
    const child = try tNode(a);
    sem.attach(child, .{ .role = .button, .label = "C", .focusable = true });
    root.add(first);
    root.add(parent);
    parent.add(child);
    root.layout(.{ .x = 0, .y = 0, .w = 640, .h = 480 });
    first.layout(.{ .x = 1, .y = 2, .w = 100, .h = 40 });
    parent.layout(.{ .x = 5, .y = 6, .w = 100, .h = 100 });
    child.layout(.{ .x = 3, .y = 4, .w = 50, .h = 20 });

    const dump_ptr = kx_a11y_dump_tree(@ptrCast(root)) orelse return error.TestUnexpectedResult;
    defer kx_a11y_free_string(dump_ptr);
    const dump: [:0]const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(dump_ptr)));

    // two top-level semantic nodes → a synthetic wrapper group; depth-first:
    // wrapper(0) → A(1) → P(1) → C(2)
    var depths: [4][]const u8 = undefined;
    var labels: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, dump, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(n < depths.len);
        depths[n] = fieldAt(line, 0).?;
        labels[n] = fieldAt(line, 2).?;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("0", depths[0]);
    try std.testing.expectEqualStrings("1", depths[1]);
    try std.testing.expectEqualStrings("1", depths[2]);
    try std.testing.expectEqualStrings("2", depths[3]);
    try std.testing.expectEqualStrings("A", labels[1]);
    try std.testing.expectEqualStrings("P", labels[2]);
    try std.testing.expectEqualStrings("C", labels[3]);

    // the grandchild's own rect (the t_vtable has no paint transform: 1:1)
    var it2 = std.mem.splitScalar(u8, dump, '\n');
    var line: []const u8 = undefined;
    var i: usize = 0;
    while (it2.next()) |l| {
        if (l.len == 0) continue;
        if (i == 3) {
            line = l;
            break;
        }
        i += 1;
    }
    try std.testing.expectEqualStrings("C", fieldAt(line, 2).?);
    try std.testing.expectEqualStrings("3", fieldAt(line, 7).?);
    try std.testing.expectEqualStrings("4", fieldAt(line, 8).?);
}

var bridge_events: u32 = 0;
var bridge_last_kind: u32 = 0;

fn testBridgeC(userdata: ?*anyopaque, event: sem.BridgeEventC) callconv(.c) void {
    _ = userdata;
    bridge_events += 1;
    bridge_last_kind = event.kind;
}

test "set_bridge registers the C bridge callback; clearing stops the events" {
    bridge_events = 0;
    kx_a11y_set_bridge(testBridgeC, null);
    sem.notifyTreeDirty();
    try std.testing.expectEqual(@as(u32, 1), bridge_events);
    try std.testing.expectEqual(@as(u32, @intFromEnum(sem.BridgeEvent.Kind.tree_dirty)), bridge_last_kind);
    kx_a11y_set_bridge(null, null); // clear
    sem.notifyTreeDirty();
    try std.testing.expectEqual(@as(u32, 1), bridge_events); // no more events
}

test "activate_node without a router is a no-op" {
    const a = std.testing.allocator;
    ui.input.setCurrent(null); // defensive: the tests share the process-global router
    const root = try tNode(a);
    defer root.deinit();
    const btn = try tNode(a);
    root.add(btn);
    root.layout(.{ .x = 0, .y = 0, .w = 640, .h = 480 });
    btn.layout(.{ .x = 10, .y = 20, .w = 100, .h = 40 });
    const clicks = &@as(*ClickState, @ptrCast(@alignCast(btn.state.?))).clicks;
    // no router installed: the activation returns before dispatching
    kx_a11y_activate_node(@ptrCast(root), @intFromPtr(btn));
    try std.testing.expectEqual(@as(u32, 0), clicks.*);
}
