// Klaxon conformance runner (Phase 4c.7) — `zig build conformance`.
// Reads every domain file under conformance/tests/, executes the vectors
// through src/conformance.zig against the real widget tree (headless, raster
// backend), then writes conformance/results-<ts>.json + a console summary.
//
// Flags:
//   --dir=<path>        tests directory (default "conformance/tests")
//   --file=<path>       run a single vector file
//   --test=<substr>     run only tests whose id contains the substring
//   --out=<path>        report path (default "conformance/results-<ts>.json")
//   --no-report         skip the report file (console only)
//   --min-score=<pct>   exit 1 below the score (default 100)
//   --verbose           print every test, not just failures
const std = @import("std");
const conformance = @import("conformance.zig");
const value_mod = @import("ui.zig").value;

const Allocator = std.mem.Allocator;

/// The corpus is one file per domain — fixed names keep the run order (and
/// the per-domain report) deterministic.
const DOMAIN_FILES = [_][]const u8{
    "layout.json",
    "paint.json",
    "gestures.json",
    "i18n.json",
    "focus.json",
    "a11y.json",
    "navigation.json",
    "scrolling.json",
    "state.json",
};

const Options = struct {
    dir: []const u8 = "conformance/tests",
    file: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    out: ?[]const u8 = null,
    report: bool = true,
    min_score: f64 = 100,
    verbose: bool = false,
};

const DomainScore = struct {
    pass: u32 = 0,
    fail: u32 = 0,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opts = try optsFromArgs(init.args, allocator);

    var results = std.array_list.Managed(conformance.TestResult).init(allocator);
    var by_domain = std.StringArrayHashMap(DomainScore).init(allocator);
    var skipped_files = std.array_list.Managed([]const u8).init(allocator);

    if (opts.file) |path| {
        try runFile(allocator, path, opts, &results, &by_domain);
    } else {
        for (DOMAIN_FILES) |name| {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ opts.dir, name });
            runFile(allocator, path, opts, &results, &by_domain) catch |e| {
                if (e == error.FileNotFound or e == error.CannotOpenFile) {
                    try skipped_files.append(try std.fmt.allocPrint(allocator, "{s} ({s})", .{ name, @errorName(e) }));
                    continue;
                }
                return e;
            };
        }
    }

    // --- console summary ---
    var total: u32 = 0;
    var passed: u32 = 0;
    for (results.items) |r| {
        total += 1;
        if (r.passed) passed += 1;
        if (opts.verbose or !r.passed) {
            std.debug.print("{s} {s}", .{ if (r.passed) "PASS" else "FAIL", r.id });
            for (r.failures.items) |f| std.debug.print(" — {s}", .{f});
            std.debug.print("\n", .{});
        }
    }
    var it = by_domain.iterator();
    while (it.next()) |e| {
        const s = e.value_ptr.*;
        std.debug.print("  {s:<11} {d}/{d}\n", .{ e.key_ptr.*, s.pass, s.pass + s.fail });
    }
    const score: f64 = if (total == 0) 0 else @as(f64, @floatFromInt(passed)) * 100.0 / @as(f64, @floatFromInt(total));
    std.debug.print("klaxon conformance: {d}/{d} passed ({d:.1}%)\n", .{ passed, total, score });
    for (skipped_files.items) |s| std.debug.print("  (skipped {s})\n", .{s});

    if (opts.report and total > 0) {
        const ts = try timestampIso8601(allocator);
        const out = opts.out orelse try std.fmt.allocPrint(allocator, "conformance/results-{s}.json", .{ts});
        const json = try formatReport(allocator, results.items, &by_domain, score, ts);
        writeFile(allocator, out, json) catch |e| {
            std.debug.print("klaxon conformance: cannot write '{s}': {t}\n", .{ out, e });
            return e;
        };
        std.debug.print("  report: {s}\n", .{out});
    }

    if (score < opts.min_score) return error.ScoreBelowThreshold;
    if (total == 0) return error.NoTestsRan;
}

fn optsFromArgs(args: std.process.Args, allocator: Allocator) !Options {
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    var opts = Options{};
    _ = it.next(); // exe name
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--dir=")) {
            opts.dir = try allocator.dupe(u8, arg[6..]);
        } else if (std.mem.startsWith(u8, arg, "--file=")) {
            opts.file = try allocator.dupe(u8, arg[7..]);
        } else if (std.mem.startsWith(u8, arg, "--test=")) {
            opts.filter = try allocator.dupe(u8, arg[7..]);
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            opts.out = try allocator.dupe(u8, arg[6..]);
        } else if (std.mem.eql(u8, arg, "--no-report")) {
            opts.report = false;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.startsWith(u8, arg, "--min-score=")) {
            opts.min_score = std.fmt.parseFloat(f64, arg[12..]) catch opts.min_score;
        }
    }
    return opts;
}

fn readFile(allocator: Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    const f = std.c.fopen(path_z, "rb") orelse return error.CannotOpenFile;
    defer _ = std.c.fclose(f);
    if (std.c.fseek(f, 0, std.c.SEEK.END) != 0) return error.CannotReadFile;
    const size = std.c.ftell(f);
    if (size <= 0) return error.CannotReadFile;
    _ = std.c.fseek(f, 0, std.c.SEEK_SET);
    const buf = try allocator.alloc(u8, @intCast(size));
    const n = std.c.fread(buf.ptr, 1, buf.len, f);
    if (n != buf.len) return error.CannotReadFile;
    return buf;
}

fn runFile(
    allocator: Allocator,
    path: []const u8,
    opts: Options,
    results: *std.array_list.Managed(conformance.TestResult),
    by_domain: *std.StringArrayHashMap(DomainScore),
) !void {
    const text = try readFile(allocator, path);
    const doc = try value_mod.parseJson(allocator, text);
    const tests = doc.get("tests") orelse return error.NoTests;
    if (tests != .array) return error.NoTests;
    for (tests.array) |tv| {
        const id = valueToStr(tv.get("id"));
        if (opts.filter) |f| {
            if (std.mem.indexOf(u8, id, f) == null) continue;
        }
        const res = conformance.runTest(allocator, tv);
        try results.append(res);
        const gop = try by_domain.getOrPut(res.domain);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        if (res.passed) gop.value_ptr.pass += 1 else gop.value_ptr.fail += 1;
    }
}

fn valueToStr(v: ?value_mod.Value) []const u8 {
    const x = v orelse return "?";
    return if (x == .string) x.string else "?";
}

/// The report contract (conformance/ADAPTERS.md §report): framework, score,
/// per-domain tallies, per-test pass/fail + failures.
fn formatReport(
    allocator: Allocator,
    results: []const conformance.TestResult,
    by_domain: *std.StringArrayHashMap(DomainScore),
    score: f64,
    ts: []const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(allocator, "{\n  \"framework\": \"klaxon\",\n  \"version\": \"p0\",\n");
    try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "  \"timestamp\": \"{s}\",\n  \"score_pct\": {d:.2},\n", .{ ts, score }));
    try buf.appendSlice(allocator, "  \"by_domain\": {");
    var first = true;
    var it = by_domain.iterator();
    while (it.next()) |e| {
        if (!first) try buf.appendSlice(allocator, ",");
        first = false;
        try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\n    \"{s}\": {{\"pass\": {d}, \"fail\": {d}}}", .{ e.key_ptr.*, e.value_ptr.pass, e.value_ptr.fail }));
    }
    try buf.appendSlice(allocator, "\n  },\n  \"tests\": [\n");
    for (results, 0..) |r, i| {
        if (i > 0) try buf.appendSlice(allocator, ",\n");
        try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "    {{\"id\": \"{s}\", \"domain\": \"{s}\", \"rule\": \"{s}\", \"passed\": {s}", .{
            r.id, r.domain, r.rule, if (r.passed) "true" else "false",
        }));
        if (r.failures.items.len > 0) {
            try buf.appendSlice(allocator, ", \"failures\": [");
            for (r.failures.items, 0..) |f, j| {
                if (j > 0) try buf.appendSlice(allocator, ", ");
                try appendJsonString(allocator, &buf, f);
            }
            try buf.appendSlice(allocator, "]");
        }
        try buf.appendSlice(allocator, "}");
    }
    try buf.appendSlice(allocator, "\n  ]\n}\n");
    return buf.items;
}

/// JSON-escape a string into the buffer (with surrounding quotes).
fn appendJsonString(allocator: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            else => try buf.append(allocator, ch),
        }
    }
    try buf.append(allocator, '"');
}

/// Current UTC time, ISO 8601 — same helper the bench runner uses.
fn timestampIso8601(allocator: Allocator) ![]const u8 {
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
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_sec.getHoursIntoDay(),
        day_sec.getMinutesIntoHour(),
        day_sec.getSecondsIntoMinute(),
    });
}

fn writeFile(allocator: Allocator, path: []const u8, json: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| makePath(allocator, dir) catch {};
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    const f = std.c.fopen(path_z, "wb") orelse return error.CannotWriteReport;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(json.ptr, 1, json.len, f);
}

fn makePath(allocator: Allocator, dir: []const u8) !void {
    var i: usize = 0;
    while (i < dir.len) : (i += 1) {
        if (dir[i] == '/' or i == dir.len - 1) {
            const prefix_z = try allocator.dupeSentinel(u8, dir[0 .. i + 1], 0);
            _ = std.c.mkdir(prefix_z, 0o755);
        }
    }
}
