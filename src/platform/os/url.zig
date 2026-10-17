// URL launcher service (Layer 4 — platform/os/url.zig).
// Validates schemes before delegating to the host's installed opener (e.g. SDL_OpenURL).

const std = @import("std");

pub const Impl = struct {
    open: ?*const fn (url: []const u8) bool = null,
};

var impl: Impl = .{};

pub fn install(i: Impl) void {
    impl = i;
}

/// Returns true only for safe external/deep-link schemes (`https://`, `http://`,
/// `mailto:`, `klaxon://`) with no ASCII control characters.
pub fn isAllowedUrl(url: []const u8) bool {
    if (url.len == 0) return false;
    for (url) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }
    const allowed_prefixes = [_][]const u8{
        "https://",
        "http://",
        "mailto:",
        "klaxon://",
    };
    for (allowed_prefixes) |p| {
        if (std.mem.startsWith(u8, url, p)) {
            return url.len > p.len;
        }
    }
    return false;
}

/// Open `url` in the system browser / handler. Returns false if disallowed or no backend installed.
pub fn openUrl(url: []const u8) bool {
    if (!isAllowedUrl(url)) return false;
    const f = impl.open orelse return false;
    return f(url);
}

test "url: scheme allowlist and backend dispatch" {
    const Mock = struct {
        var last_len: usize = 0;
        fn open(u: []const u8) bool {
            last_len = u.len;
            return true;
        }
    };
    install(.{ .open = Mock.open });
    defer install(.{});

    try std.testing.expect(!openUrl("javascript:alert(1)"));
    try std.testing.expect(!openUrl("file:///etc/passwd"));
    try std.testing.expect(!openUrl("https://"));
    try std.testing.expect(openUrl("https://example.com/docs"));
    try std.testing.expectEqual(@as(usize, 24), Mock.last_len);
}
