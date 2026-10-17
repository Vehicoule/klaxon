// Local notifications service (Layer 4 — platform/os/notifications.zig).
// Posts and cancels local user notifications across desktop, mobile, and web.

const std = @import("std");

pub const Notification = struct {
    id: u64 = 0,
    title: []const u8,
    body: []const u8 = "",
    subtitle: ?[]const u8 = null,
};

pub const Impl = struct {
    notify: ?*const fn (n: Notification) bool = null,
    cancel: ?*const fn (id: u64) void = null,
};

var impl: Impl = .{};

pub fn install(i: Impl) void {
    impl = i;
}

pub fn notify(n: Notification) bool {
    if (n.title.len == 0) return false;
    const f = impl.notify orelse return false;
    return f(n);
}

pub fn cancel(id: u64) void {
    if (impl.cancel) |f| f(id);
}

test "notifications: rejects empty title and dispatches valid notification" {
    const Mock = struct {
        var last_id: u64 = 0;
        fn onNotify(n: Notification) bool {
            last_id = n.id;
            return true;
        }
        fn onCancel(id: u64) void {
            if (last_id == id) last_id = 0;
        }
    };
    install(.{ .notify = Mock.onNotify, .cancel = Mock.onCancel });
    defer install(.{});

    try std.testing.expect(!notify(.{ .id = 1, .title = "" }));
    try std.testing.expect(notify(.{ .id = 42, .title = "Download complete", .body = "Track 01" }));
    try std.testing.expectEqual(@as(u64, 42), Mock.last_id);
    cancel(42);
    try std.testing.expectEqual(@as(u64, 0), Mock.last_id);
}
