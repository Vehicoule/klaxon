// State — fine-grained reactivity: Signal, Memo, Effect, Store (Phase 1a).
// SolidJS-style: reading a signal inside an Effect tracks a dependency; setting
// it notifies subscribers (effects re-run, nodes mark dirty, callbacks fire).
//
// ADR-0009: the public shape is C-ABI-compatible — plain data, fn ptrs +
// userdata, opaque handles — so guest languages can subscribe via thin bindings.
// The hot path (frame loop) never crosses this layer: subscriptions fire on
// change (cold path), not per frame. A set() that changes nothing notifies
// nobody (no spurious re-renders).
const std = @import("std");
const node_mod = @import("node.zig");

const Node = node_mod.Node;

var current_effect: ?*Effect = null;

// --- Subscriber (ADR-0009: maps 1:1 to C fn ptrs + userdata) ---

pub const Callback = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque) void,
    userdata: ?*anyopaque,
};

pub const Subscriber = union(enum) {
    effect: *Effect,
    node: *Node,
    callback: Callback,

    pub fn notify(sub: Subscriber) void {
        switch (sub) {
            .effect => |e| e.run(),
            .node => |n| n.markDirty(),
            .callback => |cb| cb.fn_ptr(cb.userdata),
        }
    }

    fn same(a: Subscriber, b: Subscriber) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .effect => |e| e == b.effect,
            .node => |n| n == b.node,
            .callback => |cb| cb.fn_ptr == b.callback.fn_ptr and cb.userdata == b.callback.userdata,
        };
    }
};

// --- SignalBase — type-erased core shared by Signal(T) and dependency tracking ---

pub const SignalBase = struct {
    version: u64 = 0,
    subscribers: std.array_list.Managed(Subscriber),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SignalBase {
        return .{
            .subscribers = std.array_list.Managed(Subscriber).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn subscribe(base: *SignalBase, sub: Subscriber) void {
        base.subscribers.append(sub) catch @panic("klaxon: out of memory");
    }

    pub fn unsubscribe(base: *SignalBase, sub: Subscriber) void {
        var i: usize = 0;
        while (i < base.subscribers.items.len) {
            if (Subscriber.same(base.subscribers.items[i], sub)) {
                _ = base.subscribers.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn notify(base: *SignalBase) void {
        base.version += 1;
        // Iterate a snapshot: subscribers may (un)subscribe during notify.
        const snapshot = base.allocator.dupe(Subscriber, base.subscribers.items) catch @panic("klaxon: out of memory");
        defer base.allocator.free(snapshot);
        for (snapshot) |sub| sub.notify();
    }

    pub fn deinit(base: *SignalBase) void {
        base.subscribers.deinit();
    }
};

// --- Signal(T) — a reactive value ---

pub fn Signal(comptime T: type) type {
    return struct {
        const Self = @This();

        base: SignalBase,
        value: T,

        pub fn init(allocator: std.mem.Allocator, initial: T) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .base = SignalBase.init(allocator),
                .value = initial,
            };
            return self;
        }

        /// Read the value. Inside an Effect, this tracks a dependency.
        pub fn get(self: *Self) T {
            if (current_effect) |e| e.track(&self.base);
            return self.value;
        }

        /// Read the value WITHOUT tracking a dependency (animation drivers
        /// read the displayed value inside an Effect without re-triggering).
        pub fn peek(self: *Self) T {
            return self.value;
        }

        /// Set the value. No-op (no notifications) if unchanged.
        pub fn set(self: *Self, new_value: T) void {
            if (std.meta.eql(self.value, new_value)) return;
            self.value = new_value;
            self.base.notify();
        }

        /// Force-notify subscribers even when the value is unchanged (hot
        /// reload: the underlying data changed, not the tag).
        pub fn notify(self: *Self) void {
            self.base.notify();
        }

        pub fn subscribe(self: *Self, sub: Subscriber) void {
            self.base.subscribe(sub);
        }

        pub fn unsubscribe(self: *Self, sub: Subscriber) void {
            self.base.unsubscribe(sub);
        }

        pub fn deinit(self: *Self) void {
            self.base.deinit();
            self.base.allocator.destroy(self);
        }
    };
}

// --- Effect — runs a fn ptr, re-runs when any dependency changes ---

pub const Effect = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque) void,
    userdata: ?*anyopaque,
    dependencies: std.array_list.Managed(*SignalBase),
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        fn_ptr: *const fn (userdata: ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) !*Effect {
        const effect = try allocator.create(Effect);
        effect.* = .{
            .fn_ptr = fn_ptr,
            .userdata = userdata,
            .dependencies = std.array_list.Managed(*SignalBase).init(allocator),
            .allocator = allocator,
        };
        return effect;
    }

    /// Run (or re-run) the effect: unsubscribes from stale dependencies, then
    /// re-tracks by running the fn with this effect as the current observer.
    pub fn run(effect: *Effect) void {
        for (effect.dependencies.items) |dep| dep.unsubscribe(.{ .effect = effect });
        effect.dependencies.clearRetainingCapacity();
        const prev = current_effect;
        current_effect = effect;
        defer current_effect = prev;
        effect.fn_ptr(effect.userdata);
    }

    fn track(effect: *Effect, base: *SignalBase) void {
        effect.dependencies.append(base) catch @panic("klaxon: out of memory");
        base.subscribe(.{ .effect = effect });
    }

    pub fn deinit(effect: *Effect) void {
        for (effect.dependencies.items) |dep| dep.unsubscribe(.{ .effect = effect });
        effect.dependencies.deinit();
        effect.allocator.destroy(effect);
    }
};

// --- Memo(T) — cached derived value, recomputed when dependencies change ---

pub fn Memo(comptime T: type, comptime compute: fn () T) type {
    return struct {
        const Self = @This();

        base: SignalBase,
        cache: T,
        effect: *Effect,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .base = SignalBase.init(allocator),
                .cache = undefined,
                .effect = undefined,
                .allocator = allocator,
            };
            self.effect = try Effect.init(allocator, recompute, self);
            self.effect.run(); // initial compute
            return self;
        }

        fn recompute(userdata: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            self.cache = compute();
            self.base.notify();
        }

        pub fn get(self: *Self) T {
            if (current_effect) |e| e.track(&self.base);
            return self.cache;
        }

        pub fn subscribe(self: *Self, sub: Subscriber) void {
            self.base.subscribe(sub);
        }

        pub fn deinit(self: *Self) void {
            self.effect.deinit();
            self.base.deinit();
            self.allocator.destroy(self);
        }
    };
}

// --- Store(T) — process-global signal per type (cross-widget shared state) ---
// Global lifetime (page allocator, never freed). First call to get() wins.

pub fn Store(comptime T: type) type {
    return struct {
        var signal: ?*Signal(T) = null;

        pub fn get(initial: T) *Signal(T) {
            if (signal == null) {
                signal = Signal(T).init(std.heap.page_allocator, initial) catch @panic("klaxon: out of memory");
            }
            return signal.?;
        }
    };
}

/// Bind a node to a signal: on change, the node is marked dirty (re-rendered).
pub fn bindNode(node: *Node, signal: anytype) void {
    signal.subscribe(.{ .node = node });
}

// --- tests ---

test "signal set/get + version bump + no-op on equal value" {
    const sig = try Signal(u32).init(std.testing.allocator, 1);
    defer sig.deinit();
    try std.testing.expectEqual(@as(u32, 1), sig.get());
    sig.set(2);
    try std.testing.expectEqual(@as(u32, 2), sig.get());
    try std.testing.expectEqual(@as(u64, 1), sig.base.version);
    sig.set(2); // unchanged → no notify
    try std.testing.expectEqual(@as(u64, 1), sig.base.version);
}

const EffectCtx = struct {
    sig: *Signal(u32),
    runs: u32 = 0,
    last: u32 = 0,
};

fn effectCb(userdata: ?*anyopaque) void {
    const ctx: *EffectCtx = @ptrCast(@alignCast(userdata.?));
    ctx.runs += 1;
    ctx.last = ctx.sig.get(); // read inside the effect → tracks the dependency
}

test "effect auto-subscribes on read and re-runs on change" {
    const sig = try Signal(u32).init(std.testing.allocator, 0);
    defer sig.deinit();
    var ctx = EffectCtx{ .sig = sig };
    const effect = try Effect.init(std.testing.allocator, effectCb, &ctx);
    defer effect.deinit();
    effect.run();
    try std.testing.expectEqual(@as(u32, 1), ctx.runs);
    try std.testing.expectEqual(@as(u32, 0), ctx.last);
    sig.set(42);
    try std.testing.expectEqual(@as(u32, 2), ctx.runs);
    try std.testing.expectEqual(@as(u32, 42), ctx.last);
}

var test_sig_a: *Signal(u32) = undefined;
var test_sig_b: *Signal(u32) = undefined;

fn computeSum() u32 {
    return test_sig_a.get() + test_sig_b.get();
}

test "memo recomputes when a dependency changes" {
    test_sig_a = try Signal(u32).init(std.testing.allocator, 1);
    defer test_sig_a.deinit();
    test_sig_b = try Signal(u32).init(std.testing.allocator, 2);
    defer test_sig_b.deinit();
    const memo = try Memo(u32, computeSum).init(std.testing.allocator);
    defer memo.deinit();
    try std.testing.expectEqual(@as(u32, 3), memo.get());
    test_sig_a.set(10);
    try std.testing.expectEqual(@as(u32, 12), memo.get());
}

var callback_fired: u32 = 0;

fn testCallback(userdata: ?*anyopaque) void {
    const counter: *u32 = @ptrCast(@alignCast(userdata.?));
    counter.* += 1;
}

test "callback subscriber fires with userdata (ADR-0009 C shape)" {
    const sig = try Signal(u32).init(std.testing.allocator, 0);
    defer sig.deinit();
    var fired: u32 = 0;
    sig.subscribe(.{ .callback = .{ .fn_ptr = testCallback, .userdata = &fired } });
    sig.set(1);
    try std.testing.expectEqual(@as(u32, 1), fired);
}

test "store: global signal shared per type" {
    const s1 = Store(u32).get(7);
    const s2 = Store(u32).get(99); // already initialized → same signal
    try std.testing.expect(s1 == s2);
    try std.testing.expectEqual(@as(u32, 7), s1.get());
}

test "signal peek reads the value without tracking a dependency" {
    const sig = try Signal(u32).init(std.testing.allocator, 5);
    defer sig.deinit();
    var ctx = EffectCtx{ .sig = sig };
    // an effect reading via peek records no dependency → never re-runs
    const peek_effect = try Effect.init(std.testing.allocator, struct {
        fn cb(userdata: ?*anyopaque) void {
            const c: *EffectCtx = @ptrCast(@alignCast(userdata.?));
            c.runs += 1;
            c.last = c.sig.peek();
        }
    }.cb, &ctx);
    defer peek_effect.deinit();
    peek_effect.run();
    try std.testing.expectEqual(@as(u32, 1), ctx.runs);
    try std.testing.expectEqual(@as(u32, 5), ctx.last);
    sig.set(9);
    try std.testing.expectEqual(@as(u32, 1), ctx.runs); // no re-run
    try std.testing.expectEqual(@as(u32, 9), sig.peek());
}

test "signal notify force-notifies subscribers on an unchanged value" {
    const sig = try Signal(u32).init(std.testing.allocator, 3);
    defer sig.deinit();
    var fired: u32 = 0;
    sig.subscribe(.{ .callback = .{ .fn_ptr = testCallback, .userdata = &fired } });
    sig.set(3); // unchanged → no notify
    try std.testing.expectEqual(@as(u32, 0), fired);
    try std.testing.expectEqual(@as(u64, 0), sig.base.version);
    sig.notify(); // forced (hot reload: the data changed, not the tag)
    try std.testing.expectEqual(@as(u32, 1), fired);
    try std.testing.expectEqual(@as(u64, 1), sig.base.version);
    try std.testing.expectEqual(@as(u32, 3), sig.get()); // the value itself is unchanged
}

test "unsubscribe removes the subscriber; an unknown one is a no-op" {
    const sig = try Signal(u32).init(std.testing.allocator, 0);
    defer sig.deinit();
    var a: u32 = 0;
    var b: u32 = 0;
    const sub_a = Subscriber{ .callback = .{ .fn_ptr = testCallback, .userdata = &a } };
    const sub_b = Subscriber{ .callback = .{ .fn_ptr = testCallback, .userdata = &b } };
    sig.subscribe(sub_a);
    sig.subscribe(sub_b);
    sig.unsubscribe(sub_a);
    sig.set(1);
    try std.testing.expectEqual(@as(u32, 0), a);
    try std.testing.expectEqual(@as(u32, 1), b);
    // unsubscribing a missing subscriber changes nothing (same fn + userdata
    // matches by value, so a re-created equal subscriber is also "missing")
    sig.unsubscribe(sub_a);
    sig.unsubscribe(.{ .callback = .{ .fn_ptr = testCallback, .userdata = &a } });
    sig.set(2);
    try std.testing.expectEqual(@as(u32, 0), a);
    try std.testing.expectEqual(@as(u32, 2), b);
}

const kx_mod = @import("../kx.zig");

fn stubMeasure(_: *Node, c: node_mod.Constraints) node_mod.Size {
    return c.constrain(.{ .w = 10, .h = 10 });
}
fn stubLayout(_: *Node, _: node_mod.Rect) void {}
fn stubPaint(_: *Node, _: *kx_mod.Ctx) void {}
const stub_vtable = node_mod.VTable{ .measure = stubMeasure, .layout = stubLayout, .paint = stubPaint };

test "bindNode: a signal change marks the bound node dirty" {
    const node = try Node.create(std.testing.allocator, &stub_vtable);
    defer node.deinit();
    node.dirty = false;
    const sig = try Signal(u32).init(std.testing.allocator, 0);
    defer sig.deinit();
    bindNode(node, sig);
    try std.testing.expect(!node.dirty);
    sig.set(1);
    try std.testing.expect(node.dirty);
    // an unchanged set does not re-dirty (a clean node stays clean)
    node.dirty = false;
    sig.set(1);
    try std.testing.expect(!node.dirty);
}

var flag_sig: *Signal(bool) = undefined;
var dep_a: *Signal(u32) = undefined;
var dep_b: *Signal(u32) = undefined;

fn conditionalCb(userdata: ?*anyopaque) void {
    const ctx: *EffectCtx = @ptrCast(@alignCast(userdata.?));
    ctx.runs += 1;
    if (flag_sig.get()) {
        ctx.last = dep_a.get();
    } else {
        ctx.last = dep_b.get();
    }
}

test "effect drops stale dependencies between runs" {
    flag_sig = try Signal(bool).init(std.testing.allocator, true);
    defer flag_sig.deinit();
    dep_a = try Signal(u32).init(std.testing.allocator, 1);
    defer dep_a.deinit();
    dep_b = try Signal(u32).init(std.testing.allocator, 2);
    defer dep_b.deinit();
    var ctx = EffectCtx{ .sig = dep_a };
    const effect = try Effect.init(std.testing.allocator, conditionalCb, &ctx);
    defer effect.deinit();
    effect.run(); // tracks flag + a
    try std.testing.expectEqual(@as(u32, 1), ctx.runs);
    try std.testing.expectEqual(@as(u32, 1), ctx.last);
    dep_b.set(20); // not a dependency yet → no re-run
    try std.testing.expectEqual(@as(u32, 1), ctx.runs);
    flag_sig.set(false); // re-run: tracks flag + b; a is now stale
    try std.testing.expectEqual(@as(u32, 2), ctx.runs);
    try std.testing.expectEqual(@as(u32, 20), ctx.last); // b's value set above
    dep_a.set(100); // stale dependency → no re-run
    try std.testing.expectEqual(@as(u32, 2), ctx.runs);
    dep_b.set(21); // live dependency → re-runs
    try std.testing.expectEqual(@as(u32, 3), ctx.runs);
    try std.testing.expectEqual(@as(u32, 21), ctx.last);
}

var memo_calls: u32 = 0;

fn computeDoubled() u32 {
    memo_calls += 1;
    return test_sig_a.get() * 2;
}

test "memo caches the computed value until a dependency changes" {
    memo_calls = 0;
    test_sig_a = try Signal(u32).init(std.testing.allocator, 3);
    defer test_sig_a.deinit();
    const memo = try Memo(u32, computeDoubled).init(std.testing.allocator);
    defer memo.deinit();
    try std.testing.expectEqual(@as(u32, 1), memo_calls); // the initial compute
    try std.testing.expectEqual(@as(u32, 6), memo.get());
    try std.testing.expectEqual(@as(u32, 6), memo.get()); // a cached read: no recompute
    try std.testing.expectEqual(@as(u32, 1), memo_calls);
    test_sig_a.set(4);
    try std.testing.expectEqual(@as(u32, 2), memo_calls);
    try std.testing.expectEqual(@as(u32, 8), memo.get());
}
