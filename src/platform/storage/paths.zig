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
/// The fallback chain (no backend installed — tests, headless) reads the
/// platform's own conventions: XDG dirs / $HOME on Linux, ~/Library on
/// Apple, %APPDATA%/%LOCALAPPDATA% on Windows, $TMPDIR for temp — never a
/// system directory an app could not write to.
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
    const unavailable = error.DirectoryUnavailable;

    return switch (kind) {
        .temp => tempFallback(allocator),
        .app_data => switch (builtin.os.tag) {
            .windows => if (env("APPDATA")) |b|
                std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ b, clean_org, clean_app })
            else if (env("USERPROFILE")) |up|
                std.fmt.allocPrint(allocator, "{s}/AppData/Roaming/{s}/{s}", .{ up, clean_org, clean_app })
            else
                unavailable,
            .macos, .ios => if (env("HOME")) |h|
                std.fmt.allocPrint(allocator, "{s}/Library/Application Support/{s}/{s}", .{ h, clean_org, clean_app })
            else
                unavailable,
            else => if (env("XDG_DATA_HOME")) |b|
                std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ b, clean_org, clean_app })
            else if (env("HOME")) |h|
                std.fmt.allocPrint(allocator, "{s}/.local/share/{s}/{s}", .{ h, clean_org, clean_app })
            else
                unavailable,
        },
        .cache => switch (builtin.os.tag) {
            .windows => if (env("LOCALAPPDATA")) |b|
                std.fmt.allocPrint(allocator, "{s}/{s}/{s}/Cache", .{ b, clean_org, clean_app })
            else if (env("USERPROFILE")) |up|
                std.fmt.allocPrint(allocator, "{s}/AppData/Local/{s}/{s}/Cache", .{ up, clean_org, clean_app })
            else
                unavailable,
            .macos, .ios => if (env("HOME")) |h|
                std.fmt.allocPrint(allocator, "{s}/Library/Caches/{s}/{s}", .{ h, clean_org, clean_app })
            else
                unavailable,
            else => if (env("XDG_CACHE_HOME")) |b|
                std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ b, clean_org, clean_app })
            else if (env("HOME")) |h|
                std.fmt.allocPrint(allocator, "{s}/.cache/{s}/{s}", .{ h, clean_org, clean_app })
            else
                unavailable,
        },
        .config => switch (builtin.os.tag) {
            .windows => if (env("APPDATA")) |b|
                std.fmt.allocPrint(allocator, "{s}/{s}/{s}/Config", .{ b, clean_org, clean_app })
            else if (env("USERPROFILE")) |up|
                std.fmt.allocPrint(allocator, "{s}/AppData/Roaming/{s}/{s}/Config", .{ up, clean_org, clean_app })
            else
                unavailable,
            .macos, .ios => if (env("HOME")) |h|
                std.fmt.allocPrint(allocator, "{s}/Library/Preferences/{s}/{s}", .{ h, clean_org, clean_app })
            else
                unavailable,
            else => if (env("XDG_CONFIG_HOME")) |b|
                std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ b, clean_org, clean_app })
            else if (env("HOME")) |h|
                std.fmt.allocPrint(allocator, "{s}/.config/{s}/{s}", .{ h, clean_org, clean_app })
            else
                unavailable,
        },
        .executable => allocator.dupe(u8, "."),
    };
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

fn tempFallback(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (env("TEMP") orelse env("TMP")) |t| return allocator.dupe(u8, t);
        if (env("LOCALAPPDATA")) |la| return std.fmt.allocPrint(allocator, "{s}/Temp", .{la});
        return allocator.dupe(u8, ".");
    }
    // $TMPDIR may carry a trailing slash — trim for a canonical form.
    return allocator.dupe(u8, std.mem.trimEnd(u8, env("TMPDIR") orelse "/tmp", "/"));
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
