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

/// Why the callback fired: `.ok` — `paths` holds the user's picks;
/// `.cancelled` — the user dismissed the dialog (paths empty);
/// `.unavailable` — no backend installed / platform cannot show dialogs;
/// `.err` — the backend failed (paths empty).
pub const Status = enum { ok, cancelled, unavailable, err };

/// Invoked with the outcome. `paths` slices are only valid for the call.
pub const Callback = *const fn (userdata: ?*anyopaque, status: Status, paths: []const []const u8) void;

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
        cb(userdata, .unavailable, &.{});
    }
}

pub fn saveFile(opts: SaveOptions, cb: Callback, userdata: ?*anyopaque) void {
    if (impl.save_file) |f| {
        f(opts, cb, userdata);
    } else {
        cb(userdata, .unavailable, &.{});
    }
}

test "file_picker: uninstalled reports unavailable, not a cancelled pick" {
    install(.{});
    var called = false;
    var st: Status = .ok;
    const Ctx = struct {
        called: *bool,
        st: *Status,
        fn cb(ud: ?*anyopaque, status: Status, paths: []const []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.called.* = true;
            self.st.* = status;
        }
    };
    var ctx: Ctx = .{ .called = &called, .st = &st };
    openFile(.{}, Ctx.cb, &ctx);
    try std.testing.expect(called);
    try std.testing.expectEqual(Status.unavailable, st);
}
