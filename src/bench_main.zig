// Klaxon benchmark runner (Phase 4c.3) — executable entry point + JSON report.
// bench.zig (4c.1/4c.2/4c.6) owns the scene catalogue and the metrics
// collector; this file drives it: run every scene (or the single
// -Dbench-scene), then print the JSON report to stdout (and to
// -Dbench-output when set).
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

    // Scene selection: -Dbench-scene=NAME runs one scene, otherwise the full
    // catalogue (33 scenes).
    const scene_names = @typeInfo(bench.BenchScene).@"enum".field_names;
    var scenes: [scene_names.len]bench.BenchScene = undefined;
    var count: usize = 0;
    if (build_options.bench_scene) |only| {
        // The spec writes scene names snake_case in the catalogue but calls
        // them "kebab_case in JSON/CLI" — accept both (normalize - → _).
        var name_buf: [64]u8 = undefined;
        const norm = if (only.len <= name_buf.len) blk: {
            for (only, 0..) |ch, j| name_buf[j] = if (ch == '-') '_' else ch;
            break :blk name_buf[0..only.len];
        } else only;
        const scene = std.meta.stringToEnum(bench.BenchScene, norm) orelse {
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

    // Diagnostics (investigation tooling; not part of the JSON report):
    //   KLAXON_BENCH_TRACE_DIR=<dir>  per-frame CSV → <dir>/<scene>.csv
    //   KLAXON_BENCH_PHASES=1         stderr tick/layout/paint breakdown
    //   KLAXON_BENCH_PROFILE=1        per-node own-paint profile (extra frames)
    var opts: bench.RunOptions = .{ .frames = build_options.bench_frames };
    if (std.c.getenv("KLAXON_BENCH_TRACE_DIR")) |dir| opts.trace_dir = std.mem.span(dir);
    if (std.c.getenv("KLAXON_BENCH_PHASES") != null) opts.phase_breakdown = true;
    if (std.c.getenv("KLAXON_BENCH_PROFILE") != null) opts.paint_profile = true;
    if (std.c.getenv("KLAXON_BENCH_HIDE_SCROLL_CONTENT") != null) opts.hide_scroll_content = true;

    // Run each scene headlessly (bench.zig renders through golden.Renderer on
    // the raster backend — no window) and collect its metrics. Progress goes
    // to stderr so the JSON stream on stdout stays clean.
    var metrics: [scene_names.len]bench.Metrics = undefined;
    for (scenes[0..count], 0..) |scene, i| {
        std.debug.print("klaxon bench: {s} ({d}/{d})...\n", .{ scene.name(), i + 1, count });
        metrics[i] = try bench.runSceneWithOpts(scene, allocator, opts);
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

/// JSON report — the 4c.3 output contract, schema version 2 (spec
/// docs/specs/bench-scenes.md), keep the shape stable:
/// { "scenes": [ { "name", "fps", "frame_time_avg_ms", "frame_time_p50_ms",
///                 "frame_time_p99_ms", "frame_time_p999_ms", "jank_frames",
///                 "jank_pct", "draw_calls_per_frame", "rss_mb", "ttff_ms",
///                 "frames_rendered", "extra": {…} } ],
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
            \\      "frame_time_avg_ms": {d:.2},
            \\      "frame_time_p50_ms": {d:.2},
            \\      "frame_time_p99_ms": {d:.2},
            \\      "frame_time_p999_ms": {d:.2},
            \\      "jank_frames": {d},
            \\      "jank_pct": {d:.1},
            \\      "draw_calls_per_frame": {d},
            \\      "rss_mb": {d:.1},
            \\      "ttff_ms": {d:.1},
            \\      "frames_rendered": {d},
            \\      "extra": {s}
            \\    }}
        , .{
            scene.name(),
            m.fps,
            m.frame_time_avg_ms,
            m.frame_time_p50_ms,
            m.frame_time_p99_ms,
            m.frame_time_p999_ms,
            m.jank_frames,
            m.jank_pct,
            m.draw_calls_per_frame,
            m.rss_mb,
            m.ttff_ms,
            m.frames_rendered,
            try formatExtra(allocator, m.extra),
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

/// The scene-extra object (schema v2): every contract field is emitted;
/// fields the scene didn't produce serialize as null.
fn formatExtra(allocator: std.mem.Allocator, e: bench.Extra) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"op_ms\": ");
    try appendOptF(&buf, allocator, e.op_ms);
    try buf.appendSlice(allocator, ", \"ramp\": ");
    if (e.ramp_len == 0) {
        try buf.appendSlice(allocator, "null");
    } else {
        try buf.appendSlice(allocator, "[");
        for (e.ramp[0..e.ramp_len], 0..) |p, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{{\"n\": {d}, \"p50_ms\": {d:.2}}}", .{ p.n, p.p50_ms }));
        }
        try buf.appendSlice(allocator, "]");
    }
    try buf.appendSlice(allocator, ", \"n_max_60fps\": ");
    try appendOptU(&buf, allocator, e.n_max_60fps);
    try buf.appendSlice(allocator, ", \"latency_ms\": ");
    try appendOptF(&buf, allocator, e.latency_ms);
    try buf.appendSlice(allocator, ", \"latency_frames\": ");
    try appendOptU(&buf, allocator, e.latency_frames);
    try buf.appendSlice(allocator, ", \"nodes_per_frame\": ");
    try appendOptU(&buf, allocator, e.nodes_per_frame);
    try buf.appendSlice(allocator, ", \"teardown_ms\": ");
    try appendOptF(&buf, allocator, e.teardown_ms);
    try buf.appendSlice(allocator, ", \"resume_ms\": ");
    try appendOptF(&buf, allocator, e.resume_ms);
    try buf.appendSlice(allocator, "}");
    return buf.items;
}

fn appendOptF(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: ?f64) !void {
    if (v) |x| {
        try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d:.3}", .{x}));
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn appendOptU(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: ?u64) !void {
    if (v) |x| {
        try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{x}));
    } else {
        try buf.appendSlice(allocator, "null");
    }
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
    const builtin = @import("builtin");
    const secs: u64 = if (builtin.os.tag == .windows)
        @intCast(@divFloor(@as(i64, @intCast(std.os.windows.ntdll.RtlGetSystemTimePrecise())), 10_000_000) - 11644473600)
    else blk: {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        break :blk @intCast(ts.sec);
    };
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
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
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        // /dev/stdout doesn't exist; write to the real output handle.
        const k32 = struct {
            pub extern "kernel32" fn GetStdHandle(id: u32) ?std.os.windows.HANDLE;
            pub extern "kernel32" fn WriteFile(
                h: std.os.windows.HANDLE,
                buf: [*]const u8,
                n: u32,
                written: ?*u32,
                overlapped: ?*anyopaque,
            ) std.os.windows.BOOL;
        };
        const h = k32.GetStdHandle(@bitCast(@as(i32, -11))) orelse return; // STD_OUTPUT_HANDLE
        var written: u32 = 0;
        _ = k32.WriteFile(h, json.ptr, @intCast(json.len), &written, null);
        return;
    }
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
