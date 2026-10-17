// Fuzz harness: tree_json — bytes → JSON (`ui.value.parseJson` /
// `parseJsonSlice`) → `registry.treeFromJson` → `registry.treeToJson` →
// `treeFromJson` again (round-trip) → deinit. The whole run lives in the
// caller's BuildCtx (the pattern ui.zig's `init` uses for its retained
// window tree); `ctx.deinit` is the ownership sink, node `deinit`s free the
// tree structs.
//
// Inputs are either a raw fuzzed byte span (mode 0 — arbitrary JSON,
// including invalid) or a generated document built from the real widget
// registry names + option keys, so valid trees are built with real vtables
// — measure/layout/draw on them runs real widget code.
const std = @import("std");
const klaxon = @import("klaxon");
const ui = klaxon.ui;
const fuzz = @import("fuzz_common.zig");
const registry = klaxon.registry;

const Smith = std.testing.Smith;
const Reader = fuzz.Reader;

/// Option keys that exist somewhere in the real widget options — generated
/// documents use these so `valueToOptions` actually parses them.
const opt_keys = [_][]const u8{
    "text",          "enabled",     "checked",   "value",      "size",
    "variant",       "label",       "placeholder", "multiline", "min_lines",
    "max_lines",     "w",           "h",         "selected",   "disabled",
    "error",         "supporting",  "initial",   "horizontal", "vertical",
    "gap",           "alignment",   "a11y_label", "theme",     "size_hint",
    "fill_viewport", "steps",       "progress",  "open",       "title",
    "subtitle",      "badge",       "on",        "checked_icon", "id",
};

const strings = [_][]const u8{
    "a", "hello world", "こんにちは", "👨‍👩‍👧‍👦", "filled", "tonal", "outlined",
    "text", "elevated", "small", "medium", "large", "center", "start", "end",
    "space_between", "wrap", "primary", "secondary", "destructive", "true",
    "\\n\\t escaped", "‮rtl‬", "{bad json", "null",
};

fn genScalar(r: *Reader, w: *std.Io.Writer, depth: usize) void {
    switch (r.byte() % 8) {
        0, 1 => w.print("{d}", .{r.int(i16)}) catch {},
        2 => w.print("{}", .{r.int(u8) % 2 == 0}) catch {},
        3 => w.writeAll("null") catch {},
        4, 5 => w.print("\"{s}\"", .{r.pick([]const u8, &strings)}) catch {},
        6 => if (depth < 2) genObject(r, w, depth + 1) else w.writeAll("{}") catch {},
        else => {
            w.writeAll("[") catch {};
            const n = r.byte() % 3;
            for (0..n) |i| {
                if (i > 0) w.writeAll(",") catch {};
                genScalar(r, w, depth + 1);
            }
            w.writeAll("]") catch {};
        },
    }
}

fn genObject(r: *Reader, w: *std.Io.Writer, depth: usize) void {
    w.writeAll("{") catch {};
    const n = r.byte() % 4;
    for (0..n) |i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("\"{s}\":", .{r.pick([]const u8, &opt_keys)}) catch {};
        genScalar(r, w, depth);
    }
    w.writeAll("}") catch {};
}

/// Generate a `{"name","options","children"}` document recursively over the
/// real registered widget names.
fn genTree(r: *Reader, w: *std.Io.Writer, depth: usize) void {
    const name = registry.widgets[r.byte() % registry.widgets.len].name;
    w.print("{{\"name\":\"{s}\"", .{name}) catch return;
    if (r.byte() % 3 != 0) {
        w.writeAll(",\"options\":") catch {};
        genObject(r, w, depth);
    }
    if (depth < 4 and r.byte() % 2 == 0) {
        w.writeAll(",\"children\":[") catch {};
        const nch = 1 + r.byte() % 3;
        for (0..nch) |i| {
            if (i > 0) w.writeAll(",") catch {};
            genTree(r, w, depth + 1);
        }
        w.writeAll("]") catch {};
    }
    w.writeAll("}") catch {};
}

fn testOne(_: void, smith: *Smith) !void {
    const a = std.testing.allocator;
    var blob_buf: [8192]u8 = undefined;
    const blob = fuzz.blob(smith, &blob_buf, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .value(u8, '{', 8), .value(u8, '}', 8),
        .value(u8, '[', 4), .value(u8, ']', 4),
        .value(u8, '"', 8), .value(u8, ':', 4), .value(u8, ',', 4),
    });
    var r = Reader{ .in = blob };

    var json_buf: [24576]u8 = undefined;
    const json = if (r.byte() % 5 == 0) r.in else blk: {
        var w = std.Io.Writer.fixed(&json_buf);
        genTree(&r, &w, 0);
        break :blk w.buffered();
    };

    var ctx = registry.BuildCtx.init(a);
    defer ctx.deinit();

    const root = registry.treeFromJson(&ctx, a, json) catch return;
    defer root.deinit();

    // Touch the retained-resource + layout paths on whatever got built:
    // measure/layout the tree, then serialize and re-parse the output.
    _ = root.measure(.{ .max_w = 480, .max_h = 800 });
    root.layout(.{ .x = 0, .y = 0, .w = 480, .h = 800 });

    const out = registry.treeToJson(&ctx, root, a) catch return;
    defer a.free(out);
    const root2 = registry.treeFromJson(&ctx, a, out) catch return;
    defer root2.deinit();
}

test "fuzz: JSON → widget tree → JSON → tree" {
    try std.testing.fuzz({}, testOne, .{
        .corpus = &.{
            "\x01" ++ "{\"name\":\"column\",\"options\":{\"gap\":8},\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"hi\"}},{\"name\":\"button\",\"options\":{\"label\":\"ok\"}}]}",
            "\x01" ++ "{\"name\":\"text_field\",\"options\":{\"label\":\"Name\",\"initial\":\"abc\",\"multiline\":true}}",
            "\x01" ++ "{\"name\":\"row\",\"children\":[\"oops\",{\"name\":\"divider\"},{\"name\":\"nope\"}]}",
            "\x01" ++ "{\"name\":\"text\",\"options\":{\"text\":\"x\"}",
            "\x00" ++ "not json at all {]\",",
        },
    });
}
