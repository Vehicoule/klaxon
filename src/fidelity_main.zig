// Klaxon pixel-fidelity runner — `zig build fidelity`.
// Reads fidelity/scenes.json (the same file the Compose runner consumes),
// builds each scene's widget tree through the registry, injects the scene
// state deterministically (pointer hover/press at the widget center, focus
// via the focus manager, disabled via options), advances the virtual
// timeline to t_ms, renders headless through the golden raster renderer,
// and writes fidelity/out/klaxon/<scene_id>.ppm (P6) + a JSON sidecar with
// geometry + resolved colors for the diff tool and reports.
//
// Determinism contract (fidelity/README.md): same scenes file, same
// viewport/density(1.0), theme = M3 baseline light|dark injected into every
// widget option, direction pinned through a minimal synthetic i18n locale,
// state seeded by synthetic input at t=0, animations armed at 0 and sampled
// at t_ms, font set fixed by KLAXON_FONT_DIR (assets/fonts — DejaVu Sans),
// no wall-clock dependence.
//
// Flags:
//   --scenes=<path>   scene matrix (default "fidelity/scenes.json")
//   --out=<dir>       image/metadata output dir (default "fidelity/out/klaxon")
//   --scene=<substr>  run only scenes whose id contains the substring
const std = @import("std");
const ui = @import("ui.zig");
const kx = @import("kx.zig");
const golden = @import("golden.zig");
const registry = @import("registry.zig");
const theme_mod = @import("theme.zig");
const widgets = @import("widgets.zig");

const Allocator = std.mem.Allocator;
const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Color = ui.paint.Color;
const input_mod = ui.input;
const anim_mod = ui.anim;
const sem = ui.semantics;
const i18n_mod = ui.i18n;
const value_mod = ui.value;
const layout_w = widgets.layout;
const text_w = @import("widgets/text.zig");
const icon_w = @import("widgets/icon.zig");
const nav_bar_w = @import("widgets/nav_bar.zig");

const Value = value_mod.Value;

const Options = struct {
    scenes: []const u8 = "fidelity/scenes.json",
    out: []const u8 = "fidelity/out/klaxon",
    filter: ?[]const u8 = null,
};

pub fn main(init: std.process.Init.Minimal) !void {
    // Same leak-detector pattern as conformance_main: DebugAllocator backs a
    // batch arena; anything the arena forgot trips the check on deinit.
    var debug_alloc = std.heap.DebugAllocator(.{}){};
    defer {
        if (debug_alloc.deinit() == .leak) {
            std.debug.print("klaxon fidelity: memory leak detected\n", .{});
            std.process.exit(1);
        }
    }
    var arena = std.heap.ArenaAllocator.init(debug_alloc.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // Pin the font set for BOTH sides: KLAXON_FONT_DIR makes the macOS/Linux
    // shim serve only the bundled DejaVu Sans (Compose pins the same TTF).
    // An explicit env always wins. assets/fonts wins over deps/fonts when
    // both exist (same precedence as the Windows search paths).
    if (std.c.getenv("KLAXON_FONT_DIR") == null) {
        const dir: [:0]const u8 = if (std.c.fopen("assets/fonts/DejaVuSans.ttf", "rb")) |f| blk: {
            _ = std.c.fclose(f);
            break :blk "assets/fonts";
        } else "deps/fonts";
        _ = setenv("KLAXON_FONT_DIR", dir, 0);
    }

    const opts = try optsFromArgs(init.args, allocator);
    const text = try readFile(allocator, opts.scenes);
    const doc = try value_mod.parseJson(allocator, text);
    const scenes = doc.get("scenes") orelse return error.NoScenes;
    if (scenes != .array) return error.NoScenes;

    var ran: u32 = 0;
    var failed: u32 = 0;
    for (scenes.array) |sv| {
        const id = strOr(sv.get("id"), "?");
        if (opts.filter) |f| {
            if (std.mem.indexOf(u8, id, f) == null) continue;
        }
        runScene(allocator, sv, opts) catch |e| {
            failed += 1;
            std.debug.print("FAIL {s} — {t}\n", .{ id, e });
            continue;
        };
        ran += 1;
        std.debug.print("ok   {s}\n", .{id});
    }
    std.debug.print("klaxon fidelity: {d} rendered, {d} failed -> {s}\n", .{ ran, failed, opts.out });
    if (failed > 0) return error.ScenesFailed;
    if (ran == 0) return error.NoScenesRan;
}

fn optsFromArgs(args: std.process.Args, allocator: Allocator) !Options {
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    var opts = Options{};
    _ = it.next(); // exe name
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--scenes=")) {
            opts.scenes = try allocator.dupe(u8, arg[9..]);
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            opts.out = try allocator.dupe(u8, arg[6..]);
        } else if (std.mem.startsWith(u8, arg, "--scene=")) {
            opts.filter = try allocator.dupe(u8, arg[8..]);
        }
    }
    return opts;
}

// --- JSON helpers (same shape as conformance.zig's) ---

fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn strOr(v: ?Value, default: []const u8) []const u8 {
    return str(v) orelse default;
}

fn num(v: ?Value, default: f32) f32 {
    const x = v orelse return default;
    return switch (x) {
        .int => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => default,
    };
}

// --- scene plumbing ---

const SceneState = enum { default, hover, pressed, focused, disabled };

fn parseState(s: []const u8) ?SceneState {
    return std.meta.stringToEnum(SceneState, s);
}

/// Per-scene globals — the widget tree reads the process-global router /
/// timeline / focus manager / i18n while it lives. Deinit order matches
/// conformance.Harness.deinit: tree first (deinit callbacks read the
/// globals), then the globals are cleared/freed.
const Globals = struct {
    router: input_mod.InputRouter = .{},
    timeline: anim_mod.Timeline,
    fm: *sem.FocusManager,
    i18n: *i18n_mod.I18n,

    /// Out-param init: the globals are process-wide pointers — they must be
    /// installed on the CALLER's `g`, not on a return-value temporary (the
    /// copy would leave `anim.timeline()` etc. dangling at the init-local).
    fn init(g: *Globals, arena: Allocator, dir: i18n_mod.Direction) !void {
        g.router = .{};
        g.timeline = anim_mod.Timeline.init(arena);
        g.fm = try sem.FocusManager.init(arena);
        g.i18n = try i18n_mod.I18n.init(arena, "en");
        // Pin direction with a synthetic locale — the same mechanism the
        // conformance i18n vectors use. Widgets mirror off
        // i18n_mod.direction().
        const tag: []const u8 = if (dir == .rtl) "ar" else "en";
        try g.i18n.addArb(tag, "{}", dir);
        try g.i18n.setLocale(tag);
        input_mod.setCurrent(&g.router);
        anim_mod.setCurrent(&g.timeline);
        sem.setCurrentFocus(g.fm);
        i18n_mod.setCurrent(g.i18n);
    }

    /// Clear the process globals first (widgets may still touch them while
    /// the tree deinits), then free the globals themselves — the scene
    /// arena reclaims everything either way, but explicit deinit keeps the
    /// DebugAllocator-under-arena leak check honest if this ever moves to
    /// a free-capable allocator.
    fn clear(g: *Globals) void {
        input_mod.setCurrent(null);
        anim_mod.setCurrent(null);
        sem.setCurrentFocus(null);
        i18n_mod.setCurrent(null);
        g.i18n.deinit();
        g.fm.deinit();
        g.timeline.deinit();
    }
};

fn runScene(allocator: Allocator, sv: Value, opts: Options) !void {
    var scene_arena = std.heap.ArenaAllocator.init(allocator);
    defer scene_arena.deinit();
    const a = scene_arena.allocator();

    if (sv != .object) return error.NotAnObject;
    const id = str(sv.get("id")) orelse return error.MissingId;
    const widget = str(sv.get("widget")) orelse return error.MissingWidget;
    const state = parseState(strOr(sv.get("state"), "default")) orelse return error.BadState;
    const dark = std.mem.eql(u8, strOr(sv.get("theme"), "light"), "dark");
    const dir: i18n_mod.Direction = if (std.mem.eql(u8, strOr(sv.get("dir"), "ltr"), "rtl")) .rtl else .ltr;
    const vp = sv.get("viewport") orelse return error.MissingViewport;
    if (vp != .array or vp.array.len < 2) return error.BadViewport;
    const vw = num(vp.array[0], 320);
    const vh = num(vp.array[1], 120);
    const t_ms: u64 = @intCast(@max(0, @as(i64, @intFromFloat(num(sv.get("t_ms"), 0)))));
    const theme: theme_mod.Theme = if (dark) theme_mod.dark else theme_mod.light;

    var g: Globals = undefined;
    try Globals.init(&g, a, dir);
    defer g.clear();

    // The scene's options + the resolved theme — widgets take their Theme
    // through optionsFromValue, which merges the serialized scheme onto the
    // field default (theme.light). Serializing the full Theme means a dark
    // scene flips every role, not just the ones the scene overrides.
    var opts_v = try (sv.get("options") orelse Value{ .object = &.{} }).dupe(a);
    if (opts_v != .object) return error.BadOptions;
    const theme_v = try value_mod.valueFromOptions(a, theme_mod.Theme, theme, null, null);
    try opts_v.set(a, "theme", theme_v);

    // Wrap the widget in `center` — the widget is centered in the viewport
    // on both runners; the surface clear fills the rest. `children` goes in
    // only when the scene provides it: skip_children widgets (button, badge,
    // fab, chip…) reject even an empty array.
    const has_children = sv.get("children") != null;
    const widget_fields = try a.alloc(value_mod.Field, if (has_children) 3 else 2);
    widget_fields[0] = .{ .name = "name", .value = .{ .string = widget } };
    widget_fields[1] = .{ .name = "options", .value = opts_v };
    if (sv.get("children")) |kids| {
        widget_fields[2] = .{ .name = "children", .value = kids };
    }
    const kids = try a.alloc(Value, 1);
    kids[0] = .{ .object = widget_fields };
    const root_fields = try a.alloc(value_mod.Field, 2);
    root_fields[0] = .{ .name = "name", .value = .{ .string = "center" } };
    root_fields[1] = .{ .name = "children", .value = .{ .array = kids } };
    const tree_v = Value{ .object = root_fields };

    var ctx = registry.BuildCtx.init(a);
    const root = registry.treeFromValue(&ctx, tree_v) catch |e| {
        ctx.deinit();
        return e;
    };
    defer {
        root.deinit(); // deinit callbacks read the still-live globals
        ctx.deinit(); // snapshots + tracked signals die with the tree
    }
    const widget_node = root.children.items[0];

    // nav_bar destinations / tab contents are factory chrome, not registry
    // nodes — synthesize them from options.items[{icon,label}] here (the
    // Compose runner mirrors this from the same field).
    if (std.mem.eql(u8, widget, "nav_bar")) try addNavDestinations(a, widget_node, opts_v);
    if (std.mem.eql(u8, widget, "tabs")) try addTabContents(a, widget_node, opts_v, theme, state);

    const viewport = Rect{ .x = 0, .y = 0, .w = vw, .h = vh };
    root.layout(viewport);

    // State injection at the widget bounds center (window coords).
    const cx = widget_node.bounds.x + widget_node.bounds.w / 2;
    const cy = widget_node.bounds.y + widget_node.bounds.h / 2;
    switch (state) {
        .hover => g.router.dispatchPointer(root, .{ .phase = .move, .x = cx, .y = cy }),
        .pressed => {
            // Press-only, matching the Compose runner's PressInteraction
            // (a touch-model press without hover — a preceding .move would
            // also raise Hover.Enter and stack the 0.08 layer under the ink).
            g.router.dispatchPointer(root, .{ .phase = .down, .x = cx, .y = cy });
        },
        .focused => g.fm.focusNode(widget_node),
        .default, .disabled => {},
    }

    // Timeline: handlers + the first paint play animations lazily — tick(0)
    // arms them at 0, then t_ms evaluates them (springs settle exactly; the
    // sample is time-based so the frame rate can't shift the result).
    var renderer = try golden.Renderer.init(a, @intFromFloat(vw), @intFromFloat(vh));
    defer renderer.deinit();
    g.timeline.tick(0);
    renderer.paint(root, theme.colors.surface); // warm: schedules paint-time anims
    root.clearDamage();
    g.timeline.tick(0);
    g.timeline.tick(t_ms);
    renderer.paint(root, theme.colors.surface);
    g.fm.paintRing(renderer.ctx); // the host paints the ring over the tree
    root.clearDamage();

    var frame = try renderer.readback(a);
    defer frame.deinit();

    try makePath(a, opts.out);
    const ppm = try std.fmt.allocPrintSentinel(a, "{s}/{s}.ppm", .{ opts.out, id }, 0);
    try writePpm(frame, ppm);
    const meta = try std.fmt.allocPrintSentinel(a, "{s}/{s}.json", .{ opts.out, id }, 0);
    try writeMeta(a, meta, sv, widget_node.bounds, theme);
}

fn addNavDestinations(a: Allocator, bar: *Node, opts_v: Value) !void {
    const items = opts_v.get("items") orelse return;
    if (items != .array) return;
    for (items.array) |it| {
        const icon_name = std.meta.stringToEnum(icon_w.IconName, strOr(it.get("icon"), "star")) orelse .star;
        const label = strOr(it.get("label"), "");
        bar.add(try nav_bar_w.destination(a, icon_name, label));
    }
}

/// Tab contents are bare content nodes (upstream TabImpl) — Klaxon does not
/// recolor them, so the runner applies the token colors itself: selected =
/// Primary, unselected = OnSurfaceVariant, unselected+pressed = OnSurface
/// (.ref/material3/tokens/PrimaryNavigationTabTokens.kt).
fn addTabContents(a: Allocator, row: *Node, opts_v: Value, theme: theme_mod.Theme, state: SceneState) !void {
    const items = opts_v.get("items") orelse return;
    if (items != .array) return;
    const sel: usize = blk: {
        const v = opts_v.get("selected") orelse break :blk 0;
        break :blk switch (v) {
            .int => |i| @intCast(@max(0, i)),
            else => 0,
        };
    };
    // `pressed` = pointer held at the row center → the middle tab (matching
    // the Klaxon hit test and the Compose interaction target).
    const pressed_i: usize = if (state == .pressed) items.array.len / 2 else std.math.maxInt(usize);
    for (items.array, 0..) |it, i| {
        const color: Color = if (i == sel)
            theme.colors.primary
        else if (i == pressed_i)
            theme.colors.on_surface
        else
            theme.colors.on_surface_variant;
        const col = try layout_w.column(a, .{ .main_align = .center, .cross_align = .center });
        const icon_name = std.meta.stringToEnum(icon_w.IconName, strOr(it.get("icon"), "star")) orelse .star;
        col.add(try icon_w.icon(a, icon_name, .{ .size = 24, .color = color }));
        col.add(try text_w.text(a, strOr(it.get("label"), ""), .{ .size = 14, .color = color }));
        row.add(col);
    }
}

// --- output ---

fn writePpm(frame: golden.Frame, path: [:0]const u8) !void {
    const f = std.c.fopen(path, "wb") orelse return error.CannotWriteImage;
    defer _ = std.c.fclose(f);
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrintSentinel(&header_buf, "P6\n{d} {d}\n255\n", .{ frame.w, frame.h }, 0) catch return error.CannotWriteImage;
    _ = std.c.fwrite(header.ptr, 1, header.len, f);
    var i: usize = 0;
    const n = @as(usize, @intCast(frame.w)) * @as(usize, @intCast(frame.h)) * 4;
    while (i < n) : (i += 4) {
        _ = std.c.fwrite(frame.pixels.ptr + i, 1, 3, f); // RGBA → RGB
    }
}

/// Sidecar metadata: the scene echo + the widget's laid-out bounds + the
/// resolved palette anchors. The diff tool and the HTML report read these.
fn writeMeta(a: Allocator, path: [:0]const u8, sv: Value, bounds: Rect, theme: theme_mod.Theme) !void {
    const id = strOr(sv.get("id"), "?");
    const json = try std.fmt.allocPrint(a,
        "{{\n  \"id\": \"{s}\",\n  \"widget\": \"{s}\",\n  \"state\": \"{s}\",\n  \"theme\": \"{s}\",\n  \"dir\": \"{s}\",\n" ++
        "  \"viewport\": [{d}, {d}],\n  \"t_ms\": {d},\n" ++
        "  \"widget_bounds\": [{d:.2}, {d:.2}, {d:.2}, {d:.2}],\n" ++
        "  \"colors\": {{\"surface\": \"{x:0>8}\", \"primary\": \"{x:0>8}\", \"on_surface\": \"{x:0>8}\", \"on_surface_variant\": \"{x:0>8}\"}}\n}}\n", .{
        id,
        strOr(sv.get("widget"), "?"),
        strOr(sv.get("state"), "default"),
        strOr(sv.get("theme"), "light"),
        strOr(sv.get("dir"), "ltr"),
        @as(i64, @intFromFloat(num((sv.get("viewport") orelse Value{ .array = &.{} }).array[0], 0))),
        @as(i64, @intFromFloat(num((sv.get("viewport") orelse Value{ .array = &.{} }).array[1], 0))),
        @as(i64, @intFromFloat(num(sv.get("t_ms"), 0))),
        bounds.x, bounds.y, bounds.w, bounds.h,
        theme.colors.surface, theme.colors.primary,
        theme.colors.on_surface, theme.colors.on_surface_variant,
    });
    const f = std.c.fopen(path, "wb") orelse return error.CannotWriteMeta;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(json.ptr, 1, json.len, f);
}

// std.c has no fseek/ftell/setenv — same extern pattern as conformance_main.zig.
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn readFile(allocator: Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    const f = std.c.fopen(path_z, "rb") orelse return error.CannotOpenFile;
    defer _ = std.c.fclose(f);
    if (fseek(f, 0, std.c.SEEK.END) != 0) return error.CannotReadFile;
    const size = ftell(f);
    if (size <= 0) return error.CannotReadFile;
    _ = fseek(f, 0, std.c.SEEK.SET);
    const buf = try allocator.alloc(u8, @intCast(size));
    const n = std.c.fread(buf.ptr, 1, buf.len, f);
    if (n != buf.len) return error.CannotReadFile;
    return buf;
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
