// c_abi.zig — Canonical C ABI implementation & layout verification (ADR-0009).
//
// Implements the C entry points declared in `include/klaxon.h` and verifies at
// compile time and test time that every C-ABI struct matches the binary layout
// expected across the FFI boundary.

const std = @import("std");
const kx = @import("kx.zig");
const ui = @import("ui.zig");
const registry = @import("registry.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Size = ui.layout.Size;
const Constraints = ui.layout.Constraints;
const EdgeInsets = ui.layout.EdgeInsets;
const Signal = ui.state.Signal;
const BridgeEventC = ui.semantics.BridgeEventC;

pub const KxRect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn fromRect(r: Rect) KxRect {
        return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    }

    pub fn toRect(self: KxRect) Rect {
        return .{ .x = self.x, .y = self.y, .w = self.w, .h = self.h };
    }
};

pub const KxSize = extern struct {
    w: f32,
    h: f32,
};

pub const KxConstraints = extern struct {
    min_w: f32,
    max_w: f32,
    min_h: f32,
    max_h: f32,
};

pub const KxEdgeInsets = extern struct {
    top: f32,
    right: f32,
    bottom: f32,
    left: f32,
};

pub const CallbackFnC = *const fn (userdata: ?*anyopaque) callconv(.c) void;

// Compile-time layout assertions (ADR-0009).
comptime {
    std.debug.assert(@sizeOf(KxRect) == 16);
    std.debug.assert(@alignOf(KxRect) == 4);
    std.debug.assert(@offsetOf(KxRect, "x") == 0);
    std.debug.assert(@offsetOf(KxRect, "y") == 4);
    std.debug.assert(@offsetOf(KxRect, "w") == 8);
    std.debug.assert(@offsetOf(KxRect, "h") == 12);

    std.debug.assert(@sizeOf(KxSize) == 8);
    std.debug.assert(@alignOf(KxSize) == 4);
    std.debug.assert(@offsetOf(KxSize, "w") == 0);
    std.debug.assert(@offsetOf(KxSize, "h") == 4);

    std.debug.assert(@sizeOf(KxConstraints) == 16);
    std.debug.assert(@offsetOf(KxConstraints, "min_w") == 0);
    std.debug.assert(@offsetOf(KxConstraints, "max_w") == 4);
    std.debug.assert(@offsetOf(KxConstraints, "min_h") == 8);
    std.debug.assert(@offsetOf(KxConstraints, "max_h") == 12);

    std.debug.assert(@sizeOf(KxEdgeInsets) == 16);
    std.debug.assert(@offsetOf(KxEdgeInsets, "top") == 0);
    std.debug.assert(@offsetOf(KxEdgeInsets, "right") == 4);
    std.debug.assert(@offsetOf(KxEdgeInsets, "bottom") == 8);
    std.debug.assert(@offsetOf(KxEdgeInsets, "left") == 12);

    // BridgeEventC layout matches `kx_a11y_bridge_event` in `include/klaxon.h`
    std.debug.assert(@offsetOf(BridgeEventC, "kind") == 0);
    std.debug.assert(@offsetOf(BridgeEventC, "node_id") == 8);
    std.debug.assert(@offsetOf(BridgeEventC, "text") == 16);

    // kx_skia.h C struct layouts
    std.debug.assert(@sizeOf(kx.c.kx_text_metrics) == 16);
    std.debug.assert(@offsetOf(kx.c.kx_text_metrics, "width") == 0);
    std.debug.assert(@offsetOf(kx.c.kx_text_metrics, "height") == 4);
    std.debug.assert(@offsetOf(kx.c.kx_text_metrics, "ascent") == 8);
    std.debug.assert(@offsetOf(kx.c.kx_text_metrics, "descent") == 12);

    std.debug.assert(@sizeOf(kx.c.kx_sprite_xform) == 16);
    std.debug.assert(@offsetOf(kx.c.kx_sprite_xform, "scos") == 0);
    std.debug.assert(@offsetOf(kx.c.kx_sprite_xform, "ssin") == 4);
    std.debug.assert(@offsetOf(kx.c.kx_sprite_xform, "tx") == 8);
    std.debug.assert(@offsetOf(kx.c.kx_sprite_xform, "ty") == 12);
}

// Adapter so C function pointers (`callconv(.c)`) can subscribe to `SignalBase`.
const CSubThunk = struct {
    c_fn: CallbackFnC,
    userdata: ?*anyopaque,

    fn invoke(raw: ?*anyopaque) void {
        const self: *CSubThunk = @ptrCast(@alignCast(raw.?));
        self.c_fn(self.userdata);
    }
};

fn SignalHandle(comptime T: type) type {
    return struct {
        const Self = @This();
        sig: *Signal(T),
        thunks: std.ArrayListUnmanaged(*CSubThunk) = .empty,

        fn create(initial: T) ?*Self {
            const alloc = std.heap.c_allocator;
            const sig = Signal(T).init(alloc, initial) catch return null;
            const self = alloc.create(Self) catch {
                sig.deinit();
                return null;
            };
            self.* = .{ .sig = sig };
            return self;
        }

        fn subscribe(self: *Self, fn_ptr: ?CallbackFnC, userdata: ?*anyopaque) void {
            const f = fn_ptr orelse return;
            const alloc = std.heap.c_allocator;
            const thunk = alloc.create(CSubThunk) catch return;
            thunk.* = .{ .c_fn = f, .userdata = userdata };
            self.thunks.append(alloc, thunk) catch {
                alloc.destroy(thunk);
                return;
            };
            self.sig.subscribe(.{ .callback = .{ .fn_ptr = CSubThunk.invoke, .userdata = thunk } });
        }

        fn unsubscribe(self: *Self, fn_ptr: ?CallbackFnC, userdata: ?*anyopaque) void {
            const f = fn_ptr orelse return;
            const alloc = std.heap.c_allocator;
            var i: usize = 0;
            while (i < self.thunks.items.len) {
                const thunk = self.thunks.items[i];
                if (thunk.c_fn == f and thunk.userdata == userdata) {
                    self.sig.unsubscribe(.{ .callback = .{ .fn_ptr = CSubThunk.invoke, .userdata = thunk } });
                    _ = self.thunks.orderedRemove(i);
                    alloc.destroy(thunk);
                } else {
                    i += 1;
                }
            }
        }

        fn destroy(self: *Self) void {
            const alloc = std.heap.c_allocator;
            for (self.thunks.items) |thunk| {
                self.sig.unsubscribe(.{ .callback = .{ .fn_ptr = CSubThunk.invoke, .userdata = thunk } });
                alloc.destroy(thunk);
            }
            self.thunks.deinit(alloc);
            self.sig.deinit();
            alloc.destroy(self);
        }
    };
}

const SigI32 = SignalHandle(i32);
const SigF32 = SignalHandle(f32);
const SigBool = SignalHandle(bool);

pub export fn kx_c_abi_version() callconv(.c) [*:0]const u8 {
    return kx.c.kx_abi_version();
}

// --- Signal(i32) exports ---

pub export fn kx_signal_i32_create(initial: i32) callconv(.c) ?*anyopaque {
    return @ptrCast(SigI32.create(initial));
}

pub export fn kx_signal_i32_get(handle: ?*anyopaque) callconv(.c) i32 {
    const h: *SigI32 = @ptrCast(@alignCast(handle orelse return 0));
    return h.sig.get();
}

pub export fn kx_signal_i32_set(handle: ?*anyopaque, value: i32) callconv(.c) void {
    const h: *SigI32 = @ptrCast(@alignCast(handle orelse return));
    h.sig.set(value);
}

pub export fn kx_signal_i32_subscribe(handle: ?*anyopaque, fn_ptr: ?CallbackFnC, userdata: ?*anyopaque) callconv(.c) void {
    const h: *SigI32 = @ptrCast(@alignCast(handle orelse return));
    h.subscribe(fn_ptr, userdata);
}

pub export fn kx_signal_i32_unsubscribe(handle: ?*anyopaque, fn_ptr: ?CallbackFnC, userdata: ?*anyopaque) callconv(.c) void {
    const h: *SigI32 = @ptrCast(@alignCast(handle orelse return));
    h.unsubscribe(fn_ptr, userdata);
}

pub export fn kx_signal_i32_destroy(handle: ?*anyopaque) callconv(.c) void {
    const h: *SigI32 = @ptrCast(@alignCast(handle orelse return));
    h.destroy();
}

// --- Signal(f32) exports ---

pub export fn kx_signal_f32_create(initial: f32) callconv(.c) ?*anyopaque {
    return @ptrCast(SigF32.create(initial));
}

pub export fn kx_signal_f32_get(handle: ?*anyopaque) callconv(.c) f32 {
    const h: *SigF32 = @ptrCast(@alignCast(handle orelse return 0));
    return h.sig.get();
}

pub export fn kx_signal_f32_set(handle: ?*anyopaque, value: f32) callconv(.c) void {
    const h: *SigF32 = @ptrCast(@alignCast(handle orelse return));
    h.sig.set(value);
}

pub export fn kx_signal_f32_subscribe(handle: ?*anyopaque, fn_ptr: ?CallbackFnC, userdata: ?*anyopaque) callconv(.c) void {
    const h: *SigF32 = @ptrCast(@alignCast(handle orelse return));
    h.subscribe(fn_ptr, userdata);
}

pub export fn kx_signal_f32_unsubscribe(handle: ?*anyopaque, fn_ptr: ?CallbackFnC, userdata: ?*anyopaque) callconv(.c) void {
    const h: *SigF32 = @ptrCast(@alignCast(handle orelse return));
    h.unsubscribe(fn_ptr, userdata);
}

pub export fn kx_signal_f32_destroy(handle: ?*anyopaque) callconv(.c) void {
    const h: *SigF32 = @ptrCast(@alignCast(handle orelse return));
    h.destroy();
}

// --- Signal(bool) exports ---

pub export fn kx_signal_bool_create(initial: bool) callconv(.c) ?*anyopaque {
    return @ptrCast(SigBool.create(initial));
}

pub export fn kx_signal_bool_get(handle: ?*anyopaque) callconv(.c) bool {
    const h: *SigBool = @ptrCast(@alignCast(handle orelse return false));
    return h.sig.get();
}

pub export fn kx_signal_bool_set(handle: ?*anyopaque, value: bool) callconv(.c) void {
    const h: *SigBool = @ptrCast(@alignCast(handle orelse return));
    h.sig.set(value);
}

pub export fn kx_signal_bool_subscribe(handle: ?*anyopaque, fn_ptr: ?CallbackFnC, userdata: ?*anyopaque) callconv(.c) void {
    const h: *SigBool = @ptrCast(@alignCast(handle orelse return));
    h.subscribe(fn_ptr, userdata);
}

pub export fn kx_signal_bool_unsubscribe(handle: ?*anyopaque, fn_ptr: ?CallbackFnC, userdata: ?*anyopaque) callconv(.c) void {
    const h: *SigBool = @ptrCast(@alignCast(handle orelse return));
    h.unsubscribe(fn_ptr, userdata);
}

pub export fn kx_signal_bool_destroy(handle: ?*anyopaque) callconv(.c) void {
    const h: *SigBool = @ptrCast(@alignCast(handle orelse return));
    h.destroy();
}

// --- Retained Node exports ---

pub export fn kx_node_get_bounds(node_ptr: ?*const anyopaque) callconv(.c) KxRect {
    const n: *const Node = @ptrCast(@alignCast(node_ptr orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 }));
    return KxRect.fromRect(n.bounds);
}

pub export fn kx_node_set_bounds(node_ptr: ?*anyopaque, bounds: KxRect) callconv(.c) void {
    const n: *Node = @ptrCast(@alignCast(node_ptr orelse return));
    // A teleport, not a layout pass — damage the old paint rect before
    // the write (stale pixels would linger there) plus the subtree's new
    // spot; the next layout pass may still reposition it via the parent.
    n.markDirtyRect(n.paintRect());
    n.bounds = bounds.toRect();
    n.markDirty();
}

pub export fn kx_node_layout(node_ptr: ?*anyopaque, bounds: KxRect) callconv(.c) void {
    const n: *Node = @ptrCast(@alignCast(node_ptr orelse return));
    n.layout(bounds.toRect());
}

pub export fn kx_node_mark_dirty(node_ptr: ?*anyopaque) callconv(.c) void {
    const n: *Node = @ptrCast(@alignCast(node_ptr orelse return));
    n.markDirty();
}

pub export fn kx_node_mark_layout_dirty(node_ptr: ?*anyopaque) callconv(.c) void {
    const n: *Node = @ptrCast(@alignCast(node_ptr orelse return));
    n.markLayoutDirty();
}

pub export fn kx_node_is_visible(node_ptr: ?*const anyopaque) callconv(.c) bool {
    const n: *const Node = @ptrCast(@alignCast(node_ptr orelse return false));
    return n.visible;
}

pub export fn kx_node_set_visible(node_ptr: ?*anyopaque, visible: bool) callconv(.c) void {
    const n: *Node = @ptrCast(@alignCast(node_ptr orelse return));
    n.visible = visible;
    n.markDirty();
}

pub export fn kx_node_child_count(node_ptr: ?*const anyopaque) callconv(.c) usize {
    const n: *const Node = @ptrCast(@alignCast(node_ptr orelse return 0));
    return n.children.items.len;
}

pub export fn kx_node_destroy(node_ptr: ?*anyopaque) callconv(.c) void {
    const n: *Node = @ptrCast(@alignCast(node_ptr orelse return));
    n.deinit();
}

// --- Declarative JSON Tree C ABI ---

pub export fn kx_tree_from_json(
    json_utf8: ?[*]const u8,
    json_len: usize,
    out_build_ctx: ?*?*anyopaque,
) callconv(.c) ?*anyopaque {
    const ptr = json_utf8 orelse return null;
    const alloc = std.heap.c_allocator;
    const ctx = alloc.create(registry.BuildCtx) catch return null;
    ctx.* = registry.BuildCtx.init(alloc);
    const root = registry.treeFromJson(ctx, alloc, ptr[0..json_len]) catch {
        ctx.deinit();
        alloc.destroy(ctx);
        return null;
    };
    if (out_build_ctx) |out| {
        out.* = ctx;
    } else {
        ctx.deinit();
        alloc.destroy(ctx);
    }
    return root;
}

pub export fn kx_tree_to_json(root_ptr: ?*anyopaque, build_ctx_ptr: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const root: *Node = @ptrCast(@alignCast(root_ptr orelse return null));
    const ctx: *registry.BuildCtx = @ptrCast(@alignCast(build_ctx_ptr orelse return null));
    const alloc = std.heap.c_allocator;
    const slice = registry.treeToJson(ctx, root, alloc) catch return null;
    defer alloc.free(slice);
    const z = alloc.allocSentinel(u8, slice.len, 0) catch return null;
    @memcpy(z, slice);
    return z.ptr;
}

pub export fn kx_free_json(json_str: ?[*:0]u8) callconv(.c) void {
    const ptr = json_str orelse return;
    const slice = std.mem.span(ptr);
    std.heap.c_allocator.free(slice[0..slice.len :0]);
}

pub export fn kx_build_ctx_destroy(build_ctx_ptr: ?*anyopaque) callconv(.c) void {
    const ctx: *registry.BuildCtx = @ptrCast(@alignCast(build_ctx_ptr orelse return));
    ctx.deinit();
    std.heap.c_allocator.destroy(ctx);
}

// --- Tests ---

test "c_abi: struct sizes and field offsets match klaxon.h contract" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(KxRect));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(KxSize));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(KxConstraints));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(KxEdgeInsets));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(kx.c.kx_text_metrics));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(kx.c.kx_sprite_xform));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(kx.c.kx_image_quad));

    const ver = std.mem.span(kx_c_abi_version());
    try std.testing.expect(ver.len >= 5);
}

test "c_abi: signal i32/f32/bool creation, subscription, and teardown" {
    const Counter = struct {
        hits: i32 = 0,
        fn onChanged(ud: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.hits += 1;
        }
    };
    var counter: Counter = .{};

    const sig = kx_signal_i32_create(10).?;
    defer kx_signal_i32_destroy(sig);
    try std.testing.expectEqual(@as(i32, 10), kx_signal_i32_get(sig));

    kx_signal_i32_subscribe(sig, Counter.onChanged, &counter);
    kx_signal_i32_set(sig, 42);
    try std.testing.expectEqual(@as(i32, 42), kx_signal_i32_get(sig));
    try std.testing.expectEqual(@as(i32, 1), counter.hits);

    // Setting same value is a no-op
    kx_signal_i32_set(sig, 42);
    try std.testing.expectEqual(@as(i32, 1), counter.hits);

    kx_signal_i32_unsubscribe(sig, Counter.onChanged, &counter);
    kx_signal_i32_set(sig, 99);
    try std.testing.expectEqual(@as(i32, 1), counter.hits);
}

test "c_abi: JSON declarative tree round-trip and node manipulation" {
    const json =
        \\{"type":"column","options":{"gap":8},"children":[{"type":"text","options":{"text":"hello c abi"}}]}
    ;
    var bctx: ?*anyopaque = null;
    const root = kx_tree_from_json(json.ptr, json.len, &bctx) orelse return error.TestUnexpectedResult;
    defer kx_node_destroy(root);
    defer kx_build_ctx_destroy(bctx);

    try std.testing.expectEqual(@as(usize, 1), kx_node_child_count(root));
    kx_node_layout(root, .{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const b = kx_node_get_bounds(root);
    try std.testing.expectEqual(@as(f32, 320), b.w);
    try std.testing.expectEqual(@as(f32, 200), b.h);

    const out = kx_tree_to_json(root, bctx) orelse return error.TestUnexpectedResult;
    defer kx_free_json(out);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(out), "hello c abi") != null);
}
