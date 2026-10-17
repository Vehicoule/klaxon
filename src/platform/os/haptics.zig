// Haptics feedback service (Layer 4 — platform/os/haptics.zig).
// Provides tactile feedback primitives across mobile and gamepad/trackpad targets.

const std = @import("std");

pub const ImpactStyle = enum {
    light,
    medium,
    heavy,
    selection,
    success,
    warning,
    err,
};

pub const Impl = struct {
    trigger: ?*const fn (style: ImpactStyle) void = null,
};

var impl: Impl = .{};

pub fn install(i: Impl) void {
    impl = i;
}

pub fn trigger(style: ImpactStyle) void {
    if (impl.trigger) |f| f(style);
}

test "haptics: uninstalled is no-op and installed receives style" {
    install(.{});
    trigger(.light);

    const Mock = struct {
        var last: ?ImpactStyle = null;
        fn onTrigger(s: ImpactStyle) void {
            last = s;
        }
    };
    install(.{ .trigger = Mock.onTrigger });
    defer install(.{});

    trigger(.heavy);
    try std.testing.expectEqual(@as(?ImpactStyle, .heavy), Mock.last);
}
