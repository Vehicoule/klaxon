// Platform directory resolution (Layer 4 — platform/storage/paths.zig).
// Resolves standard application directories (app data, cache, config, temp)
// across desktop, mobile, and web targets. Uses an installable backend with
// deterministic environment/fallback paths when running headless or in tests.

const std = @import("std");
const builtin = @import("builtin");

pub const DirKind = enum {
    app_data,
    cache,
    config,
    temp,
    executable,
};

pub const Impl = struct {
    resolve: ?*const fn (allocator: std.mem.Allocator, kind: DirKind, org: []const u8, app: []const u8) ?[]u8 = null,
};

var impl: Impl = .{};

pub fn install(i: Impl) void {
    impl = i;
}

/// Resolve a platform directory path for `(org, app)`. Caller owns the returned slice.
pub fn resolveDir(
    allocator: std.mem.Allocator,
    kind: DirKind,
    org: []const u8,
    app: []const u8,
) ![]u8 {
    if (impl.resolve) |f| {
        if (f(allocator, kind, org, app)) |p| return p;
    }
    const clean_org = if (org.len == 0) "klaxon" else org;
    const clean_app = if (app.len == 0) "app" else app;

    return switch (kind) {
        .temp => allocator.dupe(u8, if (builtin.os.tag == .windows) "C:\\Temp" else "/tmp"),
        .app_data => switch (builtin.os.tag) {
            .macos, .ios => std.fmt.allocPrint(allocator, "/Library/Application Support/{s}/{s}", .{ clean_org, clean_app }),
            .windows => std.fmt.allocPrint(allocator, "C:\\Users\\Default\\AppData\\Roaming\\{s}\\{s}", .{ clean_org, clean_app }),
            else => std.fmt.allocPrint(allocator, "/var/lib/{s}/{s}", .{ clean_org, clean_app }),
        },
        .cache => switch (builtin.os.tag) {
            .macos, .ios => std.fmt.allocPrint(allocator, "/Library/Caches/{s}/{s}", .{ clean_org, clean_app }),
            .windows => std.fmt.allocPrint(allocator, "C:\\Users\\Default\\AppData\\Local\\{s}\\{s}\\Cache", .{ clean_org, clean_app }),
            else => std.fmt.allocPrint(allocator, "/var/cache/{s}/{s}", .{ clean_org, clean_app }),
        },
        .config => switch (builtin.os.tag) {
            .macos, .ios => std.fmt.allocPrint(allocator, "/Library/Preferences/{s}/{s}", .{ clean_org, clean_app }),
            .windows => std.fmt.allocPrint(allocator, "C:\\Users\\Default\\AppData\\Roaming\\{s}\\{s}\\Config", .{ clean_org, clean_app }),
            else => std.fmt.allocPrint(allocator, "/etc/{s}/{s}", .{ clean_org, clean_app }),
        },
        .executable => allocator.dupe(u8, "."),
    };
}

pub fn appDataDir(allocator: std.mem.Allocator, org: []const u8, app: []const u8) ![]u8 {
    return resolveDir(allocator, .app_data, org, app);
}

pub fn cacheDir(allocator: std.mem.Allocator, org: []const u8, app: []const u8) ![]u8 {
    return resolveDir(allocator, .cache, org, app);
}

pub fn configDir(allocator: std.mem.Allocator, org: []const u8, app: []const u8) ![]u8 {
    return resolveDir(allocator, .config, org, app);
}

pub fn tempDir(allocator: std.mem.Allocator) ![]u8 {
    return resolveDir(allocator, .temp, "klaxon", "app");
}

test "paths: default resolution includes org and app" {
    install(.{});
    const alloc = std.testing.allocator;
    const data = try appDataDir(alloc, "vehicule", "player");
    defer alloc.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "vehicule") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "player") != null);

    const cache = try cacheDir(alloc, "vehicule", "player");
    defer alloc.free(cache);
    try std.testing.expect(std.mem.indexOf(u8, cache, "player") != null);

    const tmp = try tempDir(alloc);
    defer alloc.free(tmp);
    try std.testing.expect(tmp.len > 0);
}

test "paths: custom backend override" {
    const Mock = struct {
        fn resolve(allocator: std.mem.Allocator, kind: DirKind, org: []const u8, app: []const u8) ?[]u8 {
            return std.fmt.allocPrint(allocator, "/custom/{s}/{s}/{s}", .{ @tagName(kind), org, app }) catch null;
        }
    };
    install(.{ .resolve = Mock.resolve });
    defer install(.{});

    const alloc = std.testing.allocator;
    const p = try configDir(alloc, "acme", "studio");
    defer alloc.free(p);
    try std.testing.expectEqualStrings("/custom/config/acme/studio", p);
}
