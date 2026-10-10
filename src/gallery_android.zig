// gallery_android.zig — Android root for the gallery app (Phase 3d).
//
// Wraps gallery_main.zig and declares std_options_debug_io to avoid
// std.Io.Threaded: its TLS Local Exec relocations (R_AARCH64_TLSLE_*)
// cannot link into a shared library (libmain.so) on Android.
// ios_io.zig routes stderr through SDL_Log (visible in logcat).
const ios_io = @import("ios_io.zig");
const std = @import("std");
const builtin = @import("builtin");

pub const std_options_debug_io: std.Io = ios_io.io;
/// Null out debug_threaded_io so std.Options never references
/// Io.Threaded.global_single_threaded (TLS Local Exec → .so link failure).
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;
/// Required when debug_threaded_io is null — the panic handler needs
/// debug info search paths. Return none on Android (no debuginfod).
pub const std_options_elf_debug_info_search_paths: ?fn (exe_path: []const u8) switch (builtin.object_format) {
    .elf => std.debug.ElfFile.DebugInfoSearchPaths,
    else => void,
} = struct {
    fn search(_: []const u8) std.debug.ElfFile.DebugInfoSearchPaths {
        return .none;
    }
}.search;

// Pull in gallery_main.zig — its @export(&SDL_main) lands in the same
// compilation unit, so the symbol is visible to the NDK linker.
comptime {
    _ = @import("gallery_main.zig");
}

/// Custom panic handler: avoids std.debug's panic_stage (threadlocal TLS)
/// and Thread.getCurrentId (tls_thread_id TLS) — both generate TLS Local
/// Exec relocations that cannot link into Android's libmain.so.
const sdl = @import("sdl.zig");

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    var buf: [1024]u8 = undefined;
    const len = @min(msg.len, buf.len - 1);
    @memcpy(buf[0..len], msg[0..len]);
    buf[len] = 0;
    sdl.c.SDL_Log("PANIC: %s", buf[0..len :0].ptr);
    std.c.abort();
}
