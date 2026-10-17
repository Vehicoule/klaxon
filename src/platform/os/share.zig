// Share sheet service (Layer 4 — platform/os/share.zig).
// Invokes the OS share sheet on mobile/desktop or copies/opens fallback targets.

const std = @import("std");

pub const ShareItem = struct {
    title: ?[]const u8 = null,
    text: ?[]const u8 = null,
    url: ?[]const u8 = null,

    pub fn isEmpty(self: ShareItem) bool {
        const has_text = if (self.text) |t| t.len > 0 else false;
        const has_url = if (self.url) |u| u.len > 0 else false;
        return !has_text and !has_url;
    }
};

pub const Impl = struct {
    share: ?*const fn (item: ShareItem) bool = null,
};

var impl: Impl = .{};

pub fn install(i: Impl) void {
    impl = i;
}

pub fn share(item: ShareItem) bool {
    if (item.isEmpty()) return false;
    const f = impl.share orelse return false;
    return f(item);
}

test "share: rejects empty payload and dispatches valid item" {
    const Mock = struct {
        fn doShare(item: ShareItem) bool {
            return item.url != null or item.text != null;
        }
    };
    install(.{ .share = Mock.doShare });
    defer install(.{});

    try std.testing.expect(!share(.{}));
    try std.testing.expect(share(.{ .text = "Check this out", .url = "https://klaxon.dev" }));
}
