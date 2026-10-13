// klaxon — the Klaxon CLI (Phase 5a, docs/BUILD.md).
//
// A thin launcher over the project's own build scripts: every command shells
// out (`zig build <step>`, `scripts/package.sh`, `scripts/fetch-deps.sh`) with
// stdio inherited, so child output streams through and exit codes propagate.
//
// Project root discovery: commands walk up from the cwd looking for a
// directory that contains `build.zig` plus `src/main.zig` (or a `.klaxon`
// marker file, which `klaxon create` writes — it also records the klaxon
// checkout path for doctor/deps/package).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const Allocator = std.mem.Allocator;

const Cli = struct {
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    environ: *std.process.Environ.Map,
    argv0: []const u8 = "",

    fn print(cli: *const Cli, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        Io.File.writeStreamingAll(.stdout(), cli.io, s) catch {};
    }

    fn eprint(comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt, args);
    }
};

pub fn main(init: std.process.Init) u8 {
    var cli: Cli = .{
        .io = init.io,
        .gpa = init.gpa,
        .arena = init.arena.allocator(),
        .environ = init.environ_map,
    };
    return run(&cli, init.minimal.args) catch |err| {
        // Errors the CLI already explained itself.
        switch (err) {
            error.NoProjectRoot, error.NoKlaxonRoot, error.NotKlaxonRoot, error.BadKlaxonHome => return 2,
            else => {},
        }
        Cli.eprint("klaxon: {t}\n", .{err});
        return 2;
    };
}

fn run(cli: *Cli, args_vec: std.process.Args) !u8 {
    var it = try std.process.Args.Iterator.initAllocator(args_vec, cli.gpa);
    defer it.deinit();
    if (it.next()) |a0| cli.argv0 = a0;

    var args: std.ArrayList([]const u8) = .empty;
    while (it.next()) |a| try args.append(cli.arena, a);

    if (args.items.len == 0) {
        usage(cli);
        return 0;
    }
    const cmd = args.items[0];
    const rest = args.items[1..];

    if (isHelp(cmd)) {
        usage(cli);
        return 0;
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        cli.print("klaxon {s} (zig {f})\n", .{ cli_version, builtin.zig_version });
        return 0;
    } else if (std.mem.eql(u8, cmd, "create")) {
        return cmdCreate(cli, rest);
    } else if (std.mem.eql(u8, cmd, "doctor")) {
        return cmdDoctor(cli);
    } else if (std.mem.eql(u8, cmd, "run")) {
        const root = try projectRoot(cli);
        return cmdZigRun(cli, root, rest);
    } else if (std.mem.eql(u8, cmd, "build")) {
        const root = try projectRoot(cli);
        return cmdZig(cli, root, &.{"-Doptimize=ReleaseSmall"}, rest);
    } else if (std.mem.eql(u8, cmd, "test")) {
        const root = try projectRoot(cli);
        var code = try cmdZig(cli, root, &.{"test"}, &.{});
        if (code != 0) return code;
        code = try cmdZig(cli, root, &.{"test-golden"}, &.{});
        return code;
    } else if (std.mem.eql(u8, cmd, "test-golden")) {
        const root = try klaxonRootForCommand(cli, "test-golden");
        return cmdZig(cli, root, &.{"test-golden"}, rest);
    } else if (std.mem.eql(u8, cmd, "bench")) {
        const root = try klaxonRootForCommand(cli, "bench");
        var steps: std.ArrayList([]const u8) = .empty;
        try steps.append(cli.arena, "bench");
        var extra = rest;
        if (rest.len > 0 and rest[0].len > 0 and rest[0][0] != '-') {
            try steps.append(cli.arena, try std.fmt.allocPrint(cli.arena, "-Dbench-scene={s}", .{rest[0]}));
            extra = rest[1..];
        }
        return cmdZig(cli, root, steps.items, extra);
    } else if (std.mem.eql(u8, cmd, "gallery")) {
        const root = try klaxonRootForCommand(cli, "gallery");
        return cmdZig(cli, root, &.{"gallery"}, rest);
    } else if (std.mem.eql(u8, cmd, "package")) {
        return cmdPackage(cli, rest);
    } else if (std.mem.eql(u8, cmd, "deps")) {
        const root = try klaxonRoot(cli);
        return spawnExit(cli, &.{ "bash", try std.fs.path.join(cli.arena, &.{ root, "scripts", "fetch-deps.sh" }) }, root);
    }
    Cli.eprint("klaxon: unknown command '{s}'\n\n", .{cmd});
    usage(cli);
    return 2;
}

const cli_version = "0.1.0";

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn usage(cli: *const Cli) void {
    cli.print(
        \\klaxon — the Klaxon UI framework CLI
        \\
        \\Usage: klaxon <command> [args]
        \\
        \\  create <name>     Scaffold a new standalone project in ./<name>
        \\  run [-- args]     Build + run the app (debug); args go to the app
        \\  build             Build release (-Doptimize=ReleaseSmall)
        \\  test              Unit tests + golden tests
        \\  test-golden       Golden tests only
        \\  bench [scene]     Benchmarks (optionally a single scene)
        \\  package [plat]    Package for a platform (scripts/package.sh)
        \\  doctor            Check the environment (zig, deps, SDKs)
        \\  gallery           Run the widget gallery
        \\  deps              Fetch/build third-party deps (scripts/fetch-deps.sh)
        \\  help              Show this text
        \\
        \\Commands run in the project root: the nearest parent directory
        \\containing build.zig + src/main.zig (or a .klaxon marker file).
        \\test-golden/bench/gallery/package/deps only work inside the klaxon
        \\repository itself; `create` works anywhere (set KLAXON_HOME to the
        \\klaxon checkout if it cannot be found automatically).
        \\
    , .{});
}

// --- process spawning -------------------------------------------------------

/// Spawn argv with stdio inherited; return the child's exit code (1 on
/// signal/unknown termination).
fn spawnExit(cli: *const Cli, argv: []const []const u8, cwd: []const u8) !u8 {
    var child = std.process.spawn(cli.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
    }) catch |err| {
        Cli.eprint("klaxon: failed to spawn '{s}': {t}\n", .{ argv[0], err });
        return error.SpawnFailed;
    };
    const term = try child.wait(cli.io);
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

/// `zig build <steps> <extra>` at `root` — extra args go to the build itself
/// (e.g. `klaxon bench -Dbench-frames=100`); a leading `--` is dropped.
fn cmdZig(cli: *const Cli, root: []const u8, steps: []const []const u8, extra: []const []const u8) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(cli.arena, "zig");
    try argv.append(cli.arena, "build");
    try argv.appendSlice(cli.arena, steps);
    var fwd = extra;
    if (fwd.len > 0 and std.mem.eql(u8, fwd[0], "--")) fwd = fwd[1..];
    try argv.appendSlice(cli.arena, fwd);
    return spawnExit(cli, argv.items, root);
}

/// `klaxon run` — `zig build run -- <extra>`: extra args reach the app
/// verbatim (zig build's run-args separator).
fn cmdZigRun(cli: *const Cli, root: []const u8, extra: []const []const u8) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(cli.arena, "zig");
    try argv.append(cli.arena, "build");
    try argv.append(cli.arena, "run");
    var fwd = extra;
    if (fwd.len > 0 and std.mem.eql(u8, fwd[0], "--")) fwd = fwd[1..];
    if (fwd.len > 0) {
        try argv.append(cli.arena, "--");
        try argv.appendSlice(cli.arena, fwd);
    }
    return spawnExit(cli, argv.items, root);
}

fn cmdPackage(cli: *const Cli, rest: []const []const u8) !u8 {
    const root = try klaxonRootForCommand(cli, "package");
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(cli.arena, "bash");
    try argv.append(cli.arena, try std.fs.path.join(cli.arena, &.{ root, "scripts", "package.sh" }));
    try argv.appendSlice(cli.arena, rest);
    return spawnExit(cli, argv.items, root);
}

// --- project / klaxon root discovery ---------------------------------------

fn joinPath(arena: Allocator, parts: []const []const u8) ![]const u8 {
    return std.fs.path.join(arena, parts);
}

fn exists(cli: *const Cli, path: []const u8) bool {
    Io.Dir.cwd().access(cli.io, path, .{}) catch return false;
    return true;
}

fn existsDir(cli: *const Cli, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(cli.io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// A directory that looks like a project root: build.zig + src/main.zig, or
/// build.zig + a .klaxon marker (written by `klaxon create`).
fn isProjectRoot(cli: *const Cli, dir: []const u8) bool {
    const build_zig = joinPath(cli.arena, &.{ dir, "build.zig" }) catch return false;
    if (!exists(cli, build_zig)) return false;
    const main_zig = joinPath(cli.arena, &.{ dir, "src", "main.zig" }) catch return false;
    if (exists(cli, main_zig)) return true;
    const marker = joinPath(cli.arena, &.{ dir, ".klaxon" }) catch return false;
    return exists(cli, marker);
}

/// The klaxon repository itself: build.zig + src/kx.zig + kx_skia/.
fn isKlaxonRoot(cli: *const Cli, dir: []const u8) bool {
    if (!isProjectRoot(cli, dir)) return false;
    const kx = joinPath(cli.arena, &.{ dir, "src", "kx.zig" }) catch return false;
    if (!exists(cli, kx)) return false;
    const shim = joinPath(cli.arena, &.{ dir, "kx_skia" }) catch return false;
    return existsDir(cli, shim);
}

fn walkUp(cli: *const Cli, start: []const u8, pred: *const fn (*const Cli, []const u8) bool) !?[]const u8 {
    var dir: []const u8 = try cli.arena.dupe(u8, start);
    while (true) {
        if (pred(cli, dir)) return dir;
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

fn cwdAlloc(cli: *const Cli) ![]const u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(cli.io, &buf);
    return cli.arena.dupe(u8, buf[0..n]);
}

/// Nearest project root walking up from cwd, else an error.
fn projectRoot(cli: *const Cli) ![]const u8 {
    const cwd = try cwdAlloc(cli);
    if (try walkUp(cli, cwd, isProjectRoot)) |root| return root;
    Cli.eprint("klaxon: not inside a klaxon project (no build.zig + src/main.zig found above {s})\n", .{cwd});
    return error.NoProjectRoot;
}

/// The klaxon checkout. Order: $KLAXON_HOME → klaxon repo walking up from cwd
/// → .klaxon marker at the project root → klaxon repo walking up from the
/// executable's directory (covers zig-out/bin/klaxon).
fn klaxonRoot(cli: *const Cli) ![]const u8 {
    if (cli.environ.get("KLAXON_HOME")) |home| {
        if (home.len == 0) {
            // Empty counts as unset.
        } else if (isKlaxonRoot(cli, home)) {
            return try cli.arena.dupe(u8, home);
        } else {
            Cli.eprint("klaxon: KLAXON_HOME={s} is not a klaxon checkout\n", .{home});
            return error.BadKlaxonHome;
        }
    }
    const cwd = try cwdAlloc(cli);
    if (try walkUp(cli, cwd, isKlaxonRoot)) |root| return root;
    if (projectRoot(cli)) |root| {
        const marker = try joinPath(cli.arena, &.{ root, ".klaxon" });
        if (Io.Dir.cwd().openFile(cli.io, marker, .{})) |f| {
            defer f.close(cli.io);
            var buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const n = f.readStreaming(cli.io, &.{buf[0..]}) catch 0;
            const path = std.mem.trim(u8, buf[0..n], " \r\n\t");
            if (isKlaxonRoot(cli, path)) return try cli.arena.dupe(u8, path);
        } else |_| {}
    } else |_| {}
    // exe-relative: <repo>/zig-out/bin/klaxon — useful right after `zig build cli`.
    if (std.mem.indexOfScalar(u8, cli.argv0, std.fs.path.sep) != null) {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        if (Io.Dir.cwd().realPathFile(cli.io, cli.argv0, &buf)) |n| {
            if (std.fs.path.dirname(buf[0..n])) |exe_dir| {
                if (try walkUp(cli, try cli.arena.dupe(u8, exe_dir), isKlaxonRoot)) |root| return root;
            }
        } else |_| {}
    }
    Cli.eprint("klaxon: cannot find the klaxon checkout — set KLAXON_HOME\n", .{});
    return error.NoKlaxonRoot;
}

/// Commands that only make sense inside the klaxon repository (they map to
/// in-repo build steps / scripts): fail with a clear message elsewhere.
fn klaxonRootForCommand(cli: *const Cli, cmd: []const u8) ![]const u8 {
    const root = try projectRoot(cli);
    if (isKlaxonRoot(cli, root)) return root;
    Cli.eprint("klaxon: '{s}' only works inside the klaxon repository\n", .{cmd});
    return error.NotKlaxonRoot;
}

// --- klaxon doctor ----------------------------------------------------------

const CheckKind = enum { essential, optional };
const Status = enum { ok, missing };

const Check = struct {
    name: []const u8,
    status: Status,
    detail: []const u8 = "",
    hint: []const u8 = "",
    kind: CheckKind,
};

/// `argv[0] ...` on PATH → true when the child exits 0.
fn probeOk(cli: *const Cli, argv: []const []const u8) bool {
    const res = std.process.run(cli.gpa, cli.io, .{ .argv = argv }) catch return false;
    defer {
        cli.gpa.free(res.stdout);
        cli.gpa.free(res.stderr);
    }
    return res.term.success();
}

/// Like probeOk but returns the first stdout line ("" on failure).
fn probeOut(cli: *const Cli, argv: []const []const u8) []const u8 {
    const res = std.process.run(cli.gpa, cli.io, .{ .argv = argv }) catch return "";
    defer {
        cli.gpa.free(res.stdout);
        cli.gpa.free(res.stderr);
    }
    if (!res.term.success()) return "";
    const line_end = std.mem.indexOfAny(u8, res.stdout, "\r\n") orelse res.stdout.len;
    return cli.arena.dupe(u8, res.stdout[0..line_end]) catch "";
}

fn cmdDoctor(cli: *const Cli) !u8 {
    const host_tag: []const u8 = switch (builtin.os.tag) {
        .macos => "macos-arm64",
        .linux => if (builtin.cpu.arch == .x86_64) "linux-x64" else "linux-arm64",
        .windows => if (builtin.cpu.arch == .x86_64) "windows-x64" else "windows-arm64",
        else => "unsupported",
    };

    // Deps live in the klaxon checkout — locate it, but don't hard-fail:
    // falling back to <project>/deps keeps doctor honest in a bare checkout.
    var deps_root: []const u8 = ".";
    var deps_where: []const u8 = "current directory";
    if (klaxonRoot(cli)) |root| {
        deps_root = root;
        deps_where = "klaxon checkout";
    } else |_| {
        if (projectRoot(cli)) |root| {
            deps_root = root;
            deps_where = "project root";
        } else |_| {}
    }

    var checks: std.ArrayList(Check) = .empty;

    // --- essential: zig 0.17.x ---
    const zig_ver = probeOut(cli, &.{ "zig", "version" });
    if (std.mem.startsWith(u8, zig_ver, "0.17.")) {
        try checks.append(cli.arena, .{ .name = "zig 0.17.x", .status = .ok, .detail = zig_ver, .kind = .essential });
    } else {
        try checks.append(cli.arena, .{
            .name = "zig 0.17.x",
            .status = .missing,
            .detail = if (zig_ver.len > 0) zig_ver else "not found",
            .hint = "install Zig 0.17.x — https://ziglang.org/download/ or `brew install zig`",
            .kind = .essential,
        });
    }

    // --- essential: vendored deps (mirrors scripts/check-deps.sh) ---
    const deps_dir = try joinPath(cli.arena, &.{ deps_root, "deps" });
    const sdl_lib = try std.fmt.allocPrint(cli.arena, "{s}/SDL/build-{s}/libSDL3.a", .{ deps_dir, host_tag });
    const skia_lib = try std.fmt.allocPrint(cli.arena, "{s}/skia/out/{s}/libskia.a", .{ deps_dir, host_tag });
    const wamr_lib = try std.fmt.allocPrint(cli.arena, "{s}/wamr/build-{s}/libiwasm.a", .{ deps_dir, host_tag });
    const sdl_ok = existsDir(cli, try joinPath(cli.arena, &.{ deps_dir, "SDL" })) and exists(cli, sdl_lib);
    const skia_ok = exists(cli, skia_lib);
    const wamr_ok = exists(cli, wamr_lib);
    try checks.append(cli.arena, .{
        .name = "deps/SDL3",
        .status = if (sdl_ok) .ok else .missing,
        .detail = try std.fmt.allocPrint(cli.arena, "build-{s}", .{host_tag}),
        .hint = "run `klaxon deps` (scripts/fetch-deps.sh) inside the klaxon checkout",
        .kind = .essential,
    });
    try checks.append(cli.arena, .{
        .name = "deps/skia",
        .status = if (skia_ok) .ok else .missing,
        .detail = try std.fmt.allocPrint(cli.arena, "out/{s}/libskia.a", .{host_tag}),
        .hint = "run `klaxon deps` (scripts/fetch-deps.sh) inside the klaxon checkout",
        .kind = .essential,
    });
    try checks.append(cli.arena, .{
        .name = "deps/wamr",
        .status = if (wamr_ok) .ok else .missing,
        .detail = try std.fmt.allocPrint(cli.arena, "build-{s}", .{host_tag}),
        .hint = "run `klaxon deps` (scripts/fetch-deps.sh) inside the klaxon checkout",
        .kind = .essential,
    });

    // --- essential: platform toolchain ---
    switch (builtin.os.tag) {
        .macos => {
            const ok = probeOk(cli, &.{ "xcode-select", "-p" });
            try checks.append(cli.arena, .{
                .name = "xcode command line tools",
                .status = if (ok) .ok else .missing,
                .hint = "run `xcode-select --install`",
                .kind = .essential,
            });
        },
        .linux => {
            const pc_ok = probeOk(cli, &.{ "pkg-config", "--version" });
            try checks.append(cli.arena, .{
                .name = "pkg-config",
                .status = if (pc_ok) .ok else .missing,
                .hint = "install pkg-config via your distro (e.g. `apt install pkg-config`)",
                .kind = .essential,
            });
            const atk_ok = pc_ok and probeOk(cli, &.{ "pkg-config", "--exists", "atk-1.0", "atk-bridge-2.0" });
            try checks.append(cli.arena, .{
                .name = "atk/at-spi dev libs",
                .status = if (atk_ok) .ok else .missing,
                .hint = "install libatk1.0-dev + libatk-bridge2.0-dev (pulls libatspi)",
                .kind = .essential,
            });
        },
        .windows => {
            // Best-effort MSVC probe: vswhere in the Installer dir or on PATH.
            var ok = probeOk(cli, &.{ "vswhere", "-latest", "-property", "installationPath" });
            if (!ok) {
                if (cli.environ.get("ProgramFiles(x86)")) |pf| {
                    const p = try std.fmt.allocPrint(cli.arena, "{s}\\Microsoft Visual Studio\\Installer\\vswhere.exe", .{pf});
                    ok = exists(cli, p);
                }
            }
            try checks.append(cli.arena, .{
                .name = "MSVC toolchain (vswhere)",
                .status = if (ok) .ok else .missing,
                .hint = "install Visual Studio 2022 Build Tools (C++ workload)",
                .kind = .essential,
            });
        },
        else => {},
    }

    // --- optional SDKs ---
    const emcc_ver = probeOut(cli, &.{ "emcc", "--version" });
    // Vendored emsdk (deps/emsdk) satisfies the web target even without an
    // emcc on PATH — the wasm build invokes it by absolute path.
    const emcc_vendored = exists(cli, try joinPath(cli.arena, &.{ deps_dir, "emsdk", "upstream", "emscripten", "emcc" }));
    try checks.append(cli.arena, .{
        .name = "emscripten (web)",
        .status = if (emcc_ver.len > 0 or emcc_vendored) .ok else .missing,
        .detail = if (emcc_ver.len > 0) emcc_ver else if (emcc_vendored) "deps/emsdk" else "",
        .hint = "needed for `zig build web` / package web — deps/emsdk via `klaxon deps`",
        .kind = .optional,
    });
    const android_sdk = cli.environ.get("ANDROID_SDK_ROOT") orelse cli.environ.get("ANDROID_HOME") orelse "";
    const android_ok = android_sdk.len > 0 and existsDir(cli, android_sdk);
    try checks.append(cli.arena, .{
        .name = "android SDK/NDK",
        .status = if (android_ok) .ok else .missing,
        .detail = if (android_ok) android_sdk else "",
        .hint = "set ANDROID_SDK_ROOT (with an NDK installed) for android targets",
        .kind = .optional,
    });
    if (builtin.os.tag == .macos) {
        const sim_ok = probeOk(cli, &.{ "xcrun", "simctl", "list", "devices" });
        try checks.append(cli.arena, .{
            .name = "ios simulator",
            .status = if (sim_ok) .ok else .missing,
            .hint = "install Xcode + a simulator runtime for ios targets",
            .kind = .optional,
        });
    }

    // --- report ---
    cli.print("klaxon doctor — deps root: {s} ({s})\n\n", .{ deps_root, deps_where });
    var essential_missing: usize = 0;
    var optional_missing: usize = 0;
    for (checks.items) |c| {
        const mark: []const u8 = if (c.status == .ok) "OK     " else if (c.kind == .essential) "MISSING" else "warn   ";
        cli.print("  {s}  {s}", .{ mark, c.name });
        if (c.detail.len > 0) cli.print("  ({s})", .{c.detail});
        cli.print("\n", .{});
        if (c.status == .missing) {
            if (c.hint.len > 0) cli.print("         -> {s}\n", .{c.hint});
            if (c.kind == .essential) essential_missing += 1 else optional_missing += 1;
        }
    }
    cli.print("\n", .{});
    if (essential_missing > 0) {
        cli.print("{d} essential item(s) missing — fix the hints above, then re-run `klaxon doctor`.\n", .{essential_missing});
        return 1;
    }
    if (optional_missing > 0) cli.print("{d} optional item(s) missing — only needed for their targets.\n", .{optional_missing});
    cli.print("environment OK\n", .{});
    return 0;
}

// --- klaxon create ----------------------------------------------------------

/// zig package names are bare identifiers: [a-zA-Z_][a-zA-Z0-9_]*.
fn validPkgName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name, 0..) |ch, i| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_' or (i > 0 and ch >= '0' and ch <= '9');
        if (!ok) return false;
    }
    return true;
}

fn fingerprintFor(cli: *const Cli, name: []const u8) u64 {
    // std.Build package fingerprint: high 32 bits = crc32(name), low 32 = id.
    const seed: u64 = @truncate(@as(u96, @bitCast(std.Io.Timestamp.now(cli.io, .real).nanoseconds)));
    var rng = std.Random.DefaultPrng.init(seed);
    return (@as(u64, std.hash.Crc32.hash(name)) << 32) | rng.random().int(u32);
}

fn cmdCreate(cli: *const Cli, rest: []const []const u8) !u8 {
    if (rest.len == 0 or isHelp(rest[0])) {
        Cli.eprint("usage: klaxon create <name>   (name must be a zig identifier)\n", .{});
        return 2;
    }
    const name = rest[0];
    if (!validPkgName(name)) {
        Cli.eprint("klaxon: '{s}' is not a valid project name — use [a-zA-Z_][a-zA-Z0-9_]*\n", .{name});
        return 2;
    }
    const klaxon_root = try klaxonRoot(cli);
    const cwd = try cwdAlloc(cli);
    const dest = try joinPath(cli.arena, &.{ cwd, name });
    if (exists(cli, dest)) {
        Cli.eprint("klaxon: {s} already exists\n", .{dest});
        return 1;
    }

    const dir = Io.Dir.cwd();
    try dir.createDirPath(cli.io, try joinPath(cli.arena, &.{ dest, "src" }));
    try dir.createDirPath(cli.io, try joinPath(cli.arena, &.{ dest, "assets" }));

    // Zig 0.17 dependency paths must be relative to the build root — the
    // .klaxon marker keeps the absolute path for doctor/create lookups.
    // Zon paths are posix-separator on every host, so \ → / on Windows.
    var klaxon_path = try std.fs.path.relativeAlloc(cli.arena, cwd, cli.environ, dest, klaxon_root);
    if (builtin.os.tag == .windows) {
        klaxon_path = try cli.arena.dupe(u8, klaxon_path);
        for (klaxon_path) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        }
    }

    const zon = try std.fmt.allocPrint(cli.arena,
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x{x},
        \\    .minimum_zig_version = "0.17.0",
        \\    .dependencies = .{{
        \\        .klaxon = .{{ .path = "{s}" }},
        \\    }},
        \\    .paths = .{{ "build.zig", "build.zig.zon", "src", "assets" }},
        \\}}
        \\
    , .{ name, fingerprintFor(cli, name), klaxon_path });
    try dir.writeFile(cli.io, .{ .sub_path = try joinPath(cli.arena, &.{ dest, "build.zig.zon" }), .data = zon });
    try dir.writeFile(cli.io, .{ .sub_path = try joinPath(cli.arena, &.{ dest, "build.zig" }), .data = template_build_zig });
    try dir.writeFile(cli.io, .{ .sub_path = try joinPath(cli.arena, &.{ dest, "src", "main.zig" }), .data = template_main_zig });
    try dir.writeFile(cli.io, .{ .sub_path = try joinPath(cli.arena, &.{ dest, ".klaxon" }), .data = try std.fmt.allocPrint(cli.arena, "{s}\n", .{klaxon_root}) });
    try dir.writeFile(cli.io, .{ .sub_path = try joinPath(cli.arena, &.{ dest, "assets", ".gitkeep" }), .data = "" });
    const readme = try std.fmt.allocPrint(cli.arena, template_readme, .{ name, klaxon_root });
    try dir.writeFile(cli.io, .{ .sub_path = try joinPath(cli.arena, &.{ dest, "README.md" }), .data = readme });

    cli.print("created {s}/ — klaxon project scaffolded against {s}\n\n", .{ name, klaxon_root });
    cli.print("  cd {s} && klaxon run\n", .{name});
    cli.print("  (first build needs deps: run `klaxon doctor` if it fails)\n", .{});
    return 0;
}

const template_build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    // Klaxon compiles the app: -Dapp-root points its build at this
    \\    // project's src/main.zig (which imports the framework as
    \\    // `@import("klaxon")`), and the binary registers as the "app"
    \\    // artifact inside the klaxon dependency.
    \\    const klaxon = b.dependency("klaxon", .{
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .@"app-root" = b.root.root_dir.path orelse ".",
    \\    });
    \\    const app = klaxon.artifact("app");
    \\    b.installArtifact(app);
    \\
    \\    const run = b.addRunArtifact(app);
    \\    run.step.dependOn(b.getInstallStep());
    \\    const run_step = b.step("run", "Build and run the app");
    \\    run_step.dependOn(&run.step);
    \\}
    \\
;

const template_main_zig =
    \\// main.zig — a Klaxon app (scaffolded by `klaxon create`).
    \\// The framework arrives as the "klaxon" module — see build.zig.
    \\const std = @import("std");
    \\const klaxon = @import("klaxon");
    \\
    \\const ui = klaxon.ui;
    \\const widgets = klaxon.widgets;
    \\const host_mod = klaxon.host;
    \\
    \\const width: c_int = 640;
    \\const height: c_int = 480;
    \\
    \\pub fn main(init: std.process.Init.Minimal) !void {
    \\    _ = init;
    \\    var debug_alloc = std.heap.DebugAllocator(.{}){};
    \\    defer _ = debug_alloc.deinit();
    \\    const allocator = debug_alloc.allocator();
    \\
    \\    // Window + event loop. KX_BACKEND_AUTO walks the platform chain
    \\    // (graphite → ganesh → raster) — see docs/ARCHITECTURE.md.
    \\    var host = try host_mod.Host.init(allocator, width, height, klaxon.kx.c.KX_BACKEND_AUTO, null);
    \\    defer host.deinit();
    \\    ui.input.setCurrent(&host.input); // the router is process-global (single-window P0)
    \\    ui.anim.setCurrent(&host.timeline); // the animation timeline, same pattern
    \\
    \\    // Widget tree: a padded column — replace this with your UI.
    \\    const root = try widgets.container.container(allocator, .{
    \\        .color = 0x181828FF,
    \\        .padding = .all(24),
    \\    });
    \\    defer root.deinit();
    \\    const col = try widgets.layout.column(allocator, .{ .gap = 16 });
    \\    root.add(col);
    \\    col.add(try widgets.text.text(allocator, "Hello from Klaxon", .{ .size = 28, .color = 0xFFFFFFFF }));
    \\    col.add(try widgets.text.text(allocator, "scaffolded by `klaxon create`", .{ .size = 16, .color = 0xAAAAAAFF }));
    \\
    \\    root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) });
    \\
    \\    std.debug.print("klaxon app — {d}x{d}, close the window to quit\n", .{ width, height });
    \\    try host.run(root, 0, null, null); // max_frames = 0 → run until close
    \\}
    \\
;

const template_readme =
    \\# {s}
    \\
    \\A [Klaxon]({s}) app, scaffolded by `klaxon create`.
    \\
    \\```sh
    \\klaxon run      # build + run (or: zig build run)
    \\klaxon build    # release build (zig build -Doptimize=ReleaseSmall)
    \\klaxon doctor   # check the environment (deps, SDKs)
    \\```
    \\
    \\The klaxon checkout is a path dependency (build.zig.zon) — the `.klaxon`
    \\marker records where it lives so `klaxon doctor` can check its deps/.
    \\
;
