// Window safe-area & soft-keyboard insets (Layer 4 — platform/os/window_insets.zig).
// Exposes safe-area insets (notches, home indicator, status/navigation bars)
// and soft-keyboard height in logical dp.

const std = @import("std");

pub const SafeArea = struct {
    top: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
    right: f32 = 0,

    pub fn eql(a: SafeArea, b: SafeArea) bool {
        return a.top == b.top and a.bottom == b.bottom and a.left == b.left and a.right == b.right;
    }
};

pub const WindowInsets = struct {
    safe_area: SafeArea = .{},
    keyboard_height: f32 = 0,
};

var current_insets: WindowInsets = .{};

pub fn get() WindowInsets {
    return current_insets;
}

pub fn safeArea() SafeArea {
    return current_insets.safe_area;
}

pub fn keyboardHeight() f32 {
    return current_insets.keyboard_height;
}

pub fn set(insets: WindowInsets) void {
    current_insets = .{
        .safe_area = .{
            .top = @max(0, insets.safe_area.top),
            .bottom = @max(0, insets.safe_area.bottom),
            .left = @max(0, insets.safe_area.left),
            .right = @max(0, insets.safe_area.right),
        },
        .keyboard_height = @max(0, insets.keyboard_height),
    };
}

pub fn setSafeArea(sa: SafeArea) void {
    var next = current_insets;
    next.safe_area = sa;
    set(next);
}

pub fn setKeyboardHeight(h: f32) void {
    var next = current_insets;
    next.keyboard_height = h;
    set(next);
}

test "window_insets: safe area and keyboard height clamp negatives to zero" {
    defer set(.{});
    setSafeArea(.{ .top = 47, .bottom = 34, .left = -4, .right = 0 });
    setKeyboardHeight(290);
    const sa = safeArea();
    try std.testing.expectEqual(@as(f32, 47), sa.top);
    try std.testing.expectEqual(@as(f32, 34), sa.bottom);
    try std.testing.expectEqual(@as(f32, 0), sa.left);
    try std.testing.expectEqual(@as(f32, 290), keyboardHeight());
}
