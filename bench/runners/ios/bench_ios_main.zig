// bench_ios_main.zig — iOS tier-2 bench app root (bench/runners/ios/).
//
// iOS counterpart of src/bench.zig's runAndroidSuite() (the Android path is
// triggered by `adb shell setprop debug.klaxon.bench 1`; iOS has no system
// properties, so the bench is a separate .app — same trick, different
// packaging). The file provides the four SDL main callbacks
// (SDL_MAIN_USE_CALLBACKS) that kx_skia/src/kx_ios_sdl_main.c anchors — the
// same surface src/platform_ios.zig exports for the gallery — and drives
// the 33-scene catalogue one scene per SDL_AppIterate, so the UIKit run
// loop turns between scenes (the bench window's implicit CATransaction can
// commit and the CAMetalLayer maps before the paced frames run).
//
// Module wiring (see scripts/bench-ios-sim.sh): this file is compiled by a
// bare `zig build-lib` outside build.zig, so src/ files are reached as
// named modules — `bench` → src/bench.zig (it re-pulls the rest of src/
// via relative imports inside its own module), `sdl_c`/`kx_c` → the same
// zig translate-c products build.zig makes (this file uses the raw C
// bindings directly — `sdl`/`ios_io` can't be modules alongside `bench`:
// a file may live in only one module).
//
// Report: written to SDL_GetPrefPath("klaxon","bench")/bench.json — the
// app's Application Support dir inside its data container — pulled from the
// host via `xcrun simctl get_app_container <udid> com.klaxon.bench data`.
//
// Launch args (SDL_AppInit's argc/argv — `xcrun simctl launch <dev>
// com.klaxon.bench <args>`):
//   --frames=N       measured frames per scene (default 600, the zig build
//                    bench -Dbench-frames default; ramp/list-op scenes keep
//                    their per-step/op counts)
//   --only=<scene>   run a single scene (snake_case name)
//   --skip=<scene>   drop a scene (repeatable, comma list allowed) — crash
//                    isolation without recompiling
//   --backend=<n>    kx_backend int (auto=9, raster=0, graphite-metal=1)
//
// Guard: iOS-only root — the @compileError keeps native builds honest.
const std = @import("std");
const builtin = @import("builtin");
const bench = @import("bench");
const sdl = struct {
    pub const c = @import("sdl_c"); // same shape as src/sdl.zig
};
const ios_io = @import("ios_io.zig");

comptime {
    if (builtin.os.tag != .ios) @compileError("bench_ios_main.zig is iOS-only (aarch64-ios)");
}

// Same Zig 0.17 std.Io.Threaded-on-iOS fix as main_ios.zig: route
// std.debug.print / @panic through SDL_Log, never std's Threaded io
// (ios_io.zig here is a verbatim port of src/ios_io.zig — it can't be a
// module import: sdl.zig already lives in the `bench` module's tree).
pub const std_options_debug_io: std.Io = ios_io.io;

const CONTINUE: sdl.c.SDL_AppResult = sdl.c.SDL_APP_CONTINUE;
const SUCCESS: sdl.c.SDL_AppResult = sdl.c.SDL_APP_SUCCESS;
const FAILURE: sdl.c.SDL_AppResult = sdl.c.SDL_APP_FAILURE;

// kx_backend values (kx_skia/include/kx_skia.h — c_uint on the Zig side;
// kept as ints so this module needs no kx_c import of its own).
const KX_BACKEND_RASTER = 0;
const KX_BACKEND_GRAPHITE_METAL = 1;
const KX_BACKEND_GANESH_GLES = 3;
const KX_BACKEND_GANESH_METAL = 8;
const KX_BACKEND_AUTO = 9;

const MAX_SCENES = 64;

const SuiteState = struct {
    frames: u64 = 600,
    backend: @FieldType(bench.RunOptions, "backend") = KX_BACKEND_AUTO,
    only: ?[]const u8 = null,
    skip: [16][]const u8 = @splat(""),
    skip_len: usize = 0,
    // Progress: next index into the catalogue, plus the collected
    // (scene, metrics) pairs for scenes that completed.
    next: usize = 0,
    scenes: [MAX_SCENES]bench.BenchScene = undefined,
    metrics: [MAX_SCENES]bench.Metrics = undefined,
    done: usize = 0,
    failed: usize = 0,
    quit: bool = false,
    quit_failure: bool = false,
};

fn backendFor(name: []const u8) ?u32 {
    const pairs = .{
        .{ "raster", KX_BACKEND_RASTER },
        .{ "graphite-metal", KX_BACKEND_GRAPHITE_METAL },
        .{ "ganesh-gles", KX_BACKEND_GANESH_GLES },
        .{ "ganesh-metal", KX_BACKEND_GANESH_METAL },
        .{ "auto", KX_BACKEND_AUTO },
    };
    inline for (pairs) |p| {
        if (std.mem.eql(u8, name, p[0])) return p[1];
    }
    return null;
}

export fn SDL_AppInit(appstate: [*c]?*anyopaque, argc: c_int, argv: [*c][*c]u8) callconv(.c) sdl.c.SDL_AppResult {
    const st = std.heap.c_allocator.create(SuiteState) catch return FAILURE;
    st.* = .{};
    var i: usize = 1;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const a = std.mem.span(argv[i]);
        if (std.mem.startsWith(u8, a, "--frames=")) {
            st.frames = std.fmt.parseInt(u64, a["--frames=".len..], 10) catch st.frames;
        } else if (std.mem.startsWith(u8, a, "--only=")) {
            st.only = a["--only=".len..];
        } else if (std.mem.startsWith(u8, a, "--skip=")) {
            var it = std.mem.splitScalar(u8, a["--skip=".len..], ',');
            while (it.next()) |s| {
                if (s.len > 0 and st.skip_len < st.skip.len) {
                    st.skip[st.skip_len] = s;
                    st.skip_len += 1;
                }
            }
        } else if (std.mem.startsWith(u8, a, "--backend=")) {
            if (backendFor(a["--backend=".len..])) |b| st.backend = b;
        }
    }
    sdl.c.SDL_Log("klaxon bench: suite start (frames=%d)", @as(c_int, @intCast(st.frames)));
    appstate.* = st;
    return CONTINUE;
}

fn skipped(st: *SuiteState, name: []const u8) bool {
    for (st.skip[0..st.skip_len]) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

/// One scene per iterate: returns CONTINUE while scenes remain, SUCCESS
/// once the report is written (FAILURE if the report can't be written).
export fn SDL_AppIterate(appstate: ?*anyopaque) callconv(.c) sdl.c.SDL_AppResult {
    const st: *SuiteState = @ptrCast(@alignCast(appstate.?));
    if (st.quit) return if (st.quit_failure) FAILURE else SUCCESS;

    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scene_names = @typeInfo(bench.BenchScene).@"enum".field_names;
    var scenes: [scene_names.len]bench.BenchScene = undefined;
    inline for (scene_names, 0..) |n, i| scenes[i] = @field(bench.BenchScene, n);

    if (st.only) |only| {
        // Single-scene mode: run once, then write the report and quit.
        if (st.done + st.failed > 0) {
            writeReport(allocator, st) catch |e| {
                sdl.c.SDL_Log("klaxon bench: report failed: %s", @errorName(e).ptr);
                st.quit_failure = true;
            };
            st.quit = true;
            return if (st.quit_failure) FAILURE else SUCCESS;
        }
        const scene = std.meta.stringToEnum(bench.BenchScene, only) orelse {
            sdl.c.SDL_Log("klaxon bench: unknown scene %s", only.ptr);
            return FAILURE;
        };
        if (skipped(st, scene.name())) {
            sdl.c.SDL_Log("klaxon bench: scene %s skipped by --skip", only.ptr);
            st.failed += 1; // count so the done+failed check advances
            return CONTINUE;
        }
        runOne(st, scene, scenes.len);
        return CONTINUE;
    }

    while (st.next < scenes.len) : (st.next += 1) {
        const scene = scenes[st.next];
        if (skipped(st, scene.name())) continue;
        st.next += 1;
        runOne(st, scene, scenes.len);
        return CONTINUE; // one scene per iterate — let the run loop breathe
    }

    // All scenes done (or skipped): emit the report.
    writeReport(allocator, st) catch |e| {
        sdl.c.SDL_Log("klaxon bench: report failed: %s", @errorName(e).ptr);
        st.quit_failure = true;
    };
    st.quit = true;
    return if (st.quit_failure) FAILURE else SUCCESS;
}

fn runOne(st: *SuiteState, scene: bench.BenchScene, total: usize) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    sdl.c.SDL_Log("klaxon bench: %s (%d/%d)...", scene.name().ptr, @as(c_int, @intCast(st.done + st.failed + 1)), @as(c_int, @intCast(total)));
    const opts: bench.RunOptions = .{ .windowed = true, .backend = st.backend, .frames = st.frames };
    const m = bench.runSceneWithOpts(scene, arena.allocator(), opts) catch |e| {
        sdl.c.SDL_Log("klaxon bench: scene %s FAILED: %s", scene.name().ptr, @errorName(e).ptr);
        st.failed += 1;
        return;
    };
    if (st.done < MAX_SCENES) {
        st.scenes[st.done] = scene;
        st.metrics[st.done] = m;
        st.done += 1;
    }
}

/// binary_size_bytes analog: the installed Bench executable inside the app
/// bundle (SDL_GetBasePath → <Bench.app>/). 0 when unreadable.
fn binarySizeBytes() u64 {
    const base = sdl.c.SDL_GetBasePath() orelse return 0;
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "{s}Bench", .{std.mem.span(base)}, 0) catch return 0;
    const f = std.c.fopen(path, "rb") orelse return 0;
    defer _ = std.c.fclose(f);
    if (fseek(f, 0, std.c.SEEK.END) != 0) return 0;
    const size = ftell(f);
    return if (size > 0) @intCast(size) else 0;
}

// std.c has no fseek/ftell — same libc externs as bench_main.zig.
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

fn writeReport(allocator: std.mem.Allocator, st: *SuiteState) !void {
    const json = try bench.formatReport(
        allocator,
        st.scenes[0..st.done],
        st.metrics[0..st.done],
        binarySizeBytes(),
        bench.resolved_backend orelse "auto",
    );
    const pref = sdl.c.SDL_GetPrefPath("klaxon", "bench") orelse return error.NoPrefPath;
    defer sdl.c.SDL_free(pref);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}bench.json", .{std.mem.span(pref)}, 0);
    const f = std.c.fopen(path, "wb") orelse return error.CannotWriteReport;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(json.ptr, 1, json.len, f);
    sdl.c.SDL_Log("klaxon bench: report written to %s (%d scenes, %d failed)", path.ptr, @as(c_int, @intCast(st.done)), @as(c_int, @intCast(st.failed)));
}

export fn SDL_AppEvent(appstate: ?*anyopaque, event: *sdl.c.SDL_Event) callconv(.c) sdl.c.SDL_AppResult {
    _ = appstate;
    if (event.type == sdl.c.SDL_EVENT_QUIT) return SUCCESS;
    return CONTINUE;
}

export fn SDL_AppQuit(appstate: ?*anyopaque, result: sdl.c.SDL_AppResult) callconv(.c) void {
    _ = result;
    if (appstate) |a| {
        const st: *SuiteState = @ptrCast(@alignCast(a));
        std.heap.c_allocator.destroy(st);
    }
}
