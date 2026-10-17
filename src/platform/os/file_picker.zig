// Native file picker service (Layer 4 — platform/os/file_picker.zig).
// Bridges open/save file dialogs (SDL_ShowOpenFileDialog / SDL_ShowSaveFileDialog
// or native mobile document pickers).

const std = @import("std");

pub const FileFilter = struct {
    name: []const u8,
    pattern: []const u8, // e.g. "png;jpg" or "*"
};

pub const OpenOptions = struct {
    title: ?[]const u8 = null,
    default_path: ?[]const u8 = null,
    filters: []const FileFilter = &.{},
    allow_multiple: bool = false,
};

pub const SaveOptions = struct {
    title: ?[]const u8 = null,
    default_path: ?[]const u8 = null,
    filters: []const FileFilter = &.{},
};

/// Invoked with selected paths (empty slice on cancel).
pub const Callback = *const fn (userdata: ?*anyopaque, paths: []const []const u8) void;

pub const Impl = struct {
    open_file: ?*const fn (opts: OpenOptions, cb: Callback, userdata: ?*anyopaque) void = null,
    save_file: ?*const fn (opts: SaveOptions, cb: Callback, userdata: ?*anyopaque) void = null,
};

var impl: Impl = .{};

pub fn install(i: Impl) void {
    impl = i;
}

pub fn openFile(opts: OpenOptions, cb: Callback, userdata: ?*anyopaque) void {
    if (impl.open_file) |f| {
        f(opts, cb, userdata);
    } else {
        cb(userdata, &.{});
    }
}

pub fn saveFile(opts: SaveOptions, cb: Callback, userdata: ?*anyopaque) void {
    if (impl.save_file) |f| {
        f(opts, cb, userdata);
    } else {
        cb(userdata, &.{});
    }
}

test "file_picker: uninstalled invokes callback with empty selection" {
    install(.{});
    var called = false;
    var count: usize = 99;
    const Ctx = struct {
        called: *bool,
        count: *usize,
        fn cb(ud: ?*anyopaque, paths: []const []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.called.* = true;
            self.count.* = paths.len;
        }
    };
    var ctx: Ctx = .{ .called = &called, .count = &count };
    openFile(.{}, Ctx.cb, &ctx);
    try std.testing.expect(called);
    try std.testing.expectEqual(@as(usize, 0), count);
}
