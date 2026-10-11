// Klaxon benchmark runner (Phase 4c.3) — executable entry point + JSON report.
// bench.zig (4c.1/4c.2) owns the 9 canonical scenes and the metrics collector;
// this file drives them: run every scene (or the single -Dbench-scene), then
// print the JSON report to stdout (and to -Dbench-output when set).
//
// Build options (build.zig "bench" step, via @import("build_options")):
//   bench_frames   : u32          — frames per scene (-Dbench-frames=N, default 600)
//   bench_scene    : ?[]const u8  — single-scene filter (-Dbench-scene=NAME, default null = all)
//   bench_output   : ?[]const u8  — extra report file (-Dbench-output=PATH, default null)
//   bench_exe_path : []const u8   — installed runner path (zig-out/bin/bench),
//                                   stat'd for binary_size_bytes
const std = @import("std");
const bench = @import("bench.zig");
const build_options = @import("build_options");

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Scene selection: -Dbench-scene=NAME runs one scene, otherwise all 9.
    const scene_names = @typeInfo(bench.BenchScene).@"enum".field_names;
    var scenes: [scene_names.len]bench.BenchScene = undefined;
    var count: usize = 0;
    if (build_options.bench_scene) |only| {
        const scene = std.meta.stringToEnum(bench.BenchScene, only) orelse {
            std.debug.print("klaxon bench: unknown scene '{s}' — valid scenes:", .{only});
            for (scene_names) |n| std.debug.print(" {s}", .{n});
            std.debug.print("\n", .{});
            return error.UnknownScene;
        };
        scenes[0] = scene;
        count = 1;
    } else {
        inline for (scene_names, 0..) |n, i| {
            scenes[i] = @field(bench.BenchScene, n);
            count += 1;
        }
    }

    // Run each scene headlessly (bench.zig renders through golden.Renderer on
    // the raster backend — no window) and collect its metrics. Progress goes
    // to stderr so the JSON stream on stdout stays clean.
    var metrics: [scene_names.len]bench.Metrics = undefined;
    for (scenes[0..count], 0..) |scene, i| {
        std.debug.print("klaxon bench: {s} ({d}/{d})...\n", .{ scene.name(), i + 1, count });
        metrics[i] = try bench.runSceneWithOpts(scene, allocator, .{ .frames = build_options.bench_frames });
    }

    const json = try formatReport(allocator, scenes[0..count], metrics[0..count]);
    writeStdout(json);
    if (build_options.bench_output) |path| {
        writeFile(allocator, path, json) catch |err| {
            std.debug.print("klaxon bench: cannot write report to '{s}': {t}\n", .{ path, err });
            return err;
        };
    }
}

/// JSON report — the 4c.3 output contract, keep the shape stable:
/// { "scenes": [ { "name", "fps", "frame_time_avg_ms", "frame_time_p50_ms",
///                 "frame_time_p99_ms", "draw_calls_per_frame", "rss_mb",
///                 "ttff_ms", "frames_rendered" } ],
///   "binary_size_bytes": N, "timestamp": "YYYY-MM-DDTHH:MM:SSZ" }
fn formatReport(allocator: std.mem.Allocator, scenes: []const bench.BenchScene, metrics: []const bench.Metrics) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\n  \"scenes\": [\n");
    for (scenes, metrics, 0..) |scene, m, i| {
        if (i > 0) try buf.appendSlice(allocator, ",\n");
        try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator,
            \\    {{
            \\      "name": "{s}",
            \\      "fps": {d:.1},
            \\      "frame_time_avg_ms": {d:.1},
            \\      "frame_time_p50_ms": {d:.1},
            \\      "frame_time_p99_ms": {d:.1},
            \\      "draw_calls_per_frame": {d},
            \\      "rss_mb": {d:.1},
            \\      "ttff_ms": {d:.1},
            \\      "frames_rendered": {d}
            \\    }}
        , .{
            scene.name(),
            m.fps,
            m.frame_time_avg_ms,
            m.frame_time_p50_ms,
            m.frame_time_p99_ms,
            m.draw_calls_per_frame,
            m.rss_mb,
            m.ttff_ms,
            m.frames_rendered,
        }));
    }
    try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\
        \\  ],
        \\  "binary_size_bytes": {d},
        \\  "timestamp": "{s}"
        \\}}
        \\
    , .{
        binarySizeBytes(allocator),
        try timestampIso8601(allocator),
    }));
    return buf.items;
}

// std.c has no fseek/ftell — declare the libc externs (native targets link
// libc; the bench runner is native-only).
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

/// Size of the installed bench binary in bytes (0 when unreadable — the
/// runner normally executes via `zig build bench`, which installs first).
fn binarySizeBytes(allocator: std.mem.Allocator) u64 {
    const path = allocator.dupeSentinel(u8, build_options.bench_exe_path, 0) catch return 0;
    const f = std.c.fopen(path, "rb") orelse return 0;
    defer _ = std.c.fclose(f);
    if (fseek(f, 0, std.c.SEEK.END) != 0) return 0;
    const size = ftell(f);
    return if (size > 0) @intCast(size) else 0;
}

/// Current UTC time, ISO 8601 ("2026-10-11T14:03:22Z").
fn timestampIso8601(allocator: std.mem.Allocator) ![]const u8 {
    const clock_id: std.posix.clockid_t = std.posix.CLOCK.REALTIME;
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(clock_id, &ts))) {
        .SUCCESS => {},
        else => return error.ClockUnavailable,
    }
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts.sec) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_sec = epoch.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_sec.getHoursIntoDay(),
        day_sec.getMinutesIntoHour(),
        day_sec.getSecondsIntoMinute(),
    });
}

/// Write the report to stdout. C stdio, same pattern as host.zig's dumpPpm:
/// std.debug.print writes to stderr and must not pollute the JSON stream.
fn writeStdout(json: []const u8) void {
    const f = std.c.fopen("/dev/stdout", "wb") orelse return;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(json.ptr, 1, json.len, f);
}

/// Write the report to a file, creating parent directories as needed.
fn writeFile(allocator: std.mem.Allocator, path: []const u8, json: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| makePath(allocator, dir) catch {};
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    const f = std.c.fopen(path_z, "wb") orelse return error.CannotWriteReport;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(json.ptr, 1, json.len, f);
}

/// mkdir -p over POSIX mkdir (EEXIST and friends are ignored — fopen reports
/// any real failure afterwards).
fn makePath(allocator: std.mem.Allocator, dir: []const u8) !void {
    var i: usize = 0;
    while (i < dir.len) : (i += 1) {
        if (dir[i] == '/' or i == dir.len - 1) {
            const prefix_z = try allocator.dupeSentinel(u8, dir[0 .. i + 1], 0);
            _ = std.c.mkdir(prefix_z, 0o755);
        }
    }
}
