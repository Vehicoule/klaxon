// Clipboard access — the widget layer never touches SDL directly; the
// host installs the platform implementation at startup (SDL_SetClipboard
// Text / SDL_GetClipboardText on desktop + mobile; a web shim under
// Emscripten). Until installed — headless tests, exotic backends — every
// op is a safe no-op/null.
//
// The string is always plain UTF-8 text (upstream ClipData text). get()
// returns an OWNED copy the caller frees — the SDL buffer is borrowed.

const std = @import("std");

pub const Impl = struct {
    /// Owned copy of the clipboard text; null when empty or unavailable.
    get: ?*const fn (allocator: std.mem.Allocator) ?[]u8 = null,
    /// Store plain UTF-8 text (replaces the clipboard).
    set: ?*const fn (text: []const u8) void = null,
};

var impl: Impl = .{};

pub fn install(i: Impl) void {
    impl = i;
}

/// Store `text` on the clipboard. No-op without a backend.
pub fn set(text: []const u8) void {
    if (impl.set) |f| f(text);
}

/// The clipboard's text (owned; caller frees), or null when empty/
/// unavailable. Callers treat null as "nothing to paste".
pub fn get(allocator: std.mem.Allocator) ?[]u8 {
    const f = impl.get orelse return null;
    return f(allocator);
}

test "clipboard: uninstalled backend is a safe no-op" {
    install(.{}); // reset for test isolation
    set("hi"); // must not crash
    try std.testing.expect(get(std.testing.allocator) == null);
}

test "clipboard: the installed impl round-trips" {
    const S = struct {
        var slot: [256]u8 = undefined;
        var len: usize = 0;
        fn getImpl(allocator: std.mem.Allocator) ?[]u8 {
            if (len == 0) return null;
            return allocator.dupe(u8, slot[0..len]) catch null;
        }
        fn setImpl(text: []const u8) void {
            len = @min(text.len, slot.len);
            @memcpy(slot[0..len], text[0..len]);
        }
    };
    install(.{ .get = S.getImpl, .set = S.setImpl });
    defer install(.{});
    set("hello");
    const got = get(std.testing.allocator).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello", got);
}
