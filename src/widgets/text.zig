// Text widgets (Phase 1b P0) — Text (single line) and RichText (styled spans).
// Metrics come from the kx_skia ABI (kx_measure_text — real font metrics, not
// approximations). Shaped text / ellipsis / overflow land with SkParagraph later.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const TextAlign = ui.layout.TextAlign;
const Color = ui.paint.Color;

pub const TextOptions = struct {
    size: f32 = 16,
    color: Color = 0x000000FF, // opaque black (0xRRGGBBAA)
    bold: bool = false,
    text_align: TextAlign = .left, // named text_align — `align` is a Zig keyword
};

const TextState = struct {
    text: [:0]const u8, // owned, null-terminated
    opts: TextOptions,
    /// Metrics measured once at construction: a Text's string and the
    /// metrics-relevant opts (size, bold) are immutable for the node's
    /// lifetime — only the color mutates (setColor, which doesn't affect
    /// measurement). measure/paint/paintBounds read this instead of
    /// re-measuring every frame.
    m: ui.paint.TextMetrics,
};

fn textMeasure(n: *Node, c: Constraints) Size {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    return c.constrain(.{ .w = s.m.width, .h = s.m.height });
}
fn textLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: bounds come from the parent
}
/// The text's x for an alignment (start/end resolve against the current
/// text direction — Phase 2b).
fn textX(n: *Node, m: ui.paint.TextMetrics, text_align: ui.layout.TextAlign) f32 {
    const resolved = ui.layout.resolveAlign(text_align, ui.i18n.direction());
    return switch (resolved) {
        .left => n.bounds.x,
        .center => n.bounds.x + (n.bounds.w - m.width) / 2,
        .right => n.bounds.x + n.bounds.w - m.width,
        .start, .end => unreachable, // resolved above
    };
}

fn textPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    const x = textX(n, s.m, s.opts.text_align);
    // Skia draws from the baseline: one ascent below the top.
    ui.paint.text(ctx, s.text, x, n.bounds.y + s.m.ascent, s.opts.size, s.opts.bold, s.opts.color);
}
fn textDeinit(n: *Node) void {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    n.allocator.free(s.text);
    n.allocator.destroy(s);
}
/// The glyphs' actual rect: the alignment may place them outside the bounds
/// (a constrained right-aligned text paints left of its box). Culling and
/// damage consult it.
fn textPaintBounds(n: *Node) Rect {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    return .{ .x = textX(n, s.m, s.opts.text_align), .y = n.bounds.y, .w = s.m.width, .h = s.m.height };
}
const text_vtable = ui.node.VTable{ .measure = textMeasure, .layout = textLayout, .paint = textPaint, .deinit = textDeinit, .paint_bounds = textPaintBounds };

pub fn text(allocator: std.mem.Allocator, str: []const u8, opts: TextOptions) !*Node {
    const node = try Node.create(allocator, &text_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(TextState);
    errdefer allocator.destroy(s);
    const buf = try allocator.alloc(u8, str.len + 1);
    errdefer allocator.free(buf);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    s.* = .{ .text = buf[0..str.len :0], .opts = opts, .m = ui.paint.measureText(buf[0..str.len :0], opts.size, opts.bold) };
    node.state = s;
    ui.semantics.attach(node, .{ .role = .text, .label = s.text }); // Phase 2c
    return node;
}

/// Recolor a live text (signal-driven widgets recolor their label on state
/// change — e.g. the M3E chip's selected state).
pub fn setColor(n: *Node, color: Color) void {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    s.opts.color = color;
    n.markDirty();
}

// --- BoundText: a Text whose string follows a signal ---

/// The signal a BoundText value rides: text rides the growable TextSignal
/// (Signal(T) stores T by value — it could not own the string's bytes
/// without a double-free); scalars ride Signal(T).
fn SignalFor(comptime T: type) type {
    return if (T == [:0]const u8) ui.state.TextSignal else ui.state.Signal(T);
}

/// Text bound to a signal: the string is `fmt(sig.peek())`, reformatted and
/// re-measured on every change (the size may change → markLayoutDirty, not
/// just markDirty). `fmt` writes into the provided buffer and returns the
/// slice used — or NULL when it does not fit (the widget retries with a
/// bigger buffer, up to ui.state.TextSignal.max_len; over the cap the node
/// paints empty rather than truncating).
pub fn BoundText(comptime T: type) type {
    return struct {
        const State = struct {
            sig: *SignalFor(T),
            fmt: *const fn (T, []u8) ?[]const u8,
            opts: TextOptions,
            /// The formatted text — allocator-owned, kept null-terminated
            /// (kx_draw_text takes a char*). sem.label borrows it: bound()
            /// re-points the label on every format (a grow may move it).
            buf: std.array_list.Managed(u8),
            /// The buf is stale — the signal changed since the last format.
            /// bound() reformats only when this is set, so measure()+paint()
            /// in one frame don't repeat the copy (dirtyCb re-arms it).
            dirty: bool,
            /// Metrics of the CURRENT buf contents — refreshed inside
            /// bound()'s reformat: the same `dirty` flag that gates the
            /// reformat gates the re-measure, so measure()/paint()/
            /// paintBounds() never measure a stale or repeated string.
            m: ui.paint.TextMetrics,
        };

        fn bound(n: *Node) [:0]const u8 {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            if (!s.dirty)
                return s.buf.items.ptr[0..s.buf.items.len :0];
            s.dirty = false;
            if (s.buf.capacity == 0)
                s.buf.ensureTotalCapacity(128) catch @panic("klaxon: out of memory");
            while (true) {
                const scratch = s.buf.allocatedSlice();
                const out = s.fmt(s.sig.peek(), scratch) orelse {
                    if (scratch.len > ui.state.TextSignal.max_len) {
                        s.buf.items.len = 0; // over the cap: paint empty, never truncated
                        break;
                    }
                    s.buf.ensureTotalCapacity(@min(scratch.len * 2, ui.state.TextSignal.max_len + 1)) catch @panic("klaxon: out of memory");
                    continue;
                };
                if (out.len >= scratch.len) {
                    // The text fits but the sentinel would not — grow + retry.
                    s.buf.ensureTotalCapacity(out.len + 1) catch @panic("klaxon: out of memory");
                    continue;
                }
                const lo = @intFromPtr(scratch.ptr);
                const out_ptr = @intFromPtr(out.ptr);
                if (out_ptr < lo or out_ptr + out.len > lo + scratch.len) {
                    @memcpy(scratch[0..out.len], out); // a literal result → copy in
                } else if (out_ptr != lo) {
                    std.mem.copyForwards(u8, scratch[0..out.len], out); // an offset slice → move to the front
                }
                s.buf.items.len = out.len;
                break;
            }
            // The null sentinel at items[len] (capacity > len is guaranteed).
            s.buf.items.len += 1;
            s.buf.items[s.buf.items.len - 1] = 0;
            s.buf.items.len -= 1;
            const str = s.buf.items.ptr[0..s.buf.items.len :0];
            s.m = ui.paint.measureText(str, s.opts.size, s.opts.bold); // reformatted → re-measure once
            if (n.semantics) |sem| sem.label = str; // re-point: a grow may have moved the buffer
            return str;
        }

        fn measure(n: *Node, c: Constraints) Size {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            _ = bound(n); // refresh buf + metrics when the signal changed
            return c.constrain(.{ .w = s.m.width, .h = s.m.height });
        }
        fn layout(n: *Node, bounds: Rect) void {
            _ = n;
            _ = bounds; // leaf: bounds come from the parent
        }
        fn paint(n: *Node, ctx: *kx.Ctx) void {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            const str = bound(n);
            const x = textX(n, s.m, s.opts.text_align);
            ui.paint.text(ctx, str, x, n.bounds.y + s.m.ascent, s.opts.size, s.opts.bold, s.opts.color);
        }
        fn dirtyCb(userdata: ?*anyopaque) void {
            const n: *Node = @ptrCast(@alignCast(userdata.?));
            const s: *State = @ptrCast(@alignCast(n.state.?));
            s.dirty = true;
            _ = bound(n); // refresh the text + the a11y label for the new value
            n.markLayoutDirty(); // the text (and its size) changed
            n.markDirty(); // wake the dirty-flag render path (idle repaint)
        }
        fn deinit(n: *Node) void {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = dirtyCb, .userdata = n } });
            s.buf.deinit();
            n.allocator.destroy(s);
        }
        fn paintBounds(n: *Node) Rect {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            _ = bound(n); // keep metrics in step with the current string
            return .{ .x = textX(n, s.m, s.opts.text_align), .y = n.bounds.y, .w = s.m.width, .h = s.m.height };
        }
        const vtable = ui.node.VTable{ .measure = measure, .layout = layout, .paint = paint, .deinit = deinit, .paint_bounds = paintBounds };

        pub fn text(allocator: std.mem.Allocator, sig: *SignalFor(T), fmt: *const fn (T, []u8) ?[]const u8, opts: TextOptions) !*Node {
            const node = try Node.create(allocator, &vtable);
            errdefer node.allocator.destroy(node); // no state yet
            const s = try allocator.create(State);
            errdefer allocator.destroy(s);
            s.* = .{ .sig = sig, .fmt = fmt, .opts = opts, .buf = std.array_list.Managed(u8).init(allocator), .dirty = true, .m = std.mem.zeroes(ui.paint.TextMetrics) };
            errdefer s.buf.deinit();
            node.state = s;
            // Phase 2c: the label is the initial text — dynamic changes go
            // through live regions (semantics.announce).
            ui.semantics.attach(node, .{ .role = .text, .label = bound(node) });
            sig.subscribe(.{ .callback = .{ .fn_ptr = dirtyCb, .userdata = node } });
            return node;
        }
    };
}

// --- RichText ---

pub const TextSpan = struct {
    text: []const u8,
    size: f32 = 16,
    color: Color = 0x000000FF, // opaque black (0xRRGGBBAA)
    bold: bool = false,
};

const SpanState = struct {
    text: [:0]const u8, // owned, null-terminated
    size: f32,
    color: Color,
    bold: bool,
    /// Metrics measured once at construction — spans are immutable, so
    /// measure/paint/paintBounds read this instead of re-measuring.
    m: ui.paint.TextMetrics,
};

const RichTextState = struct {
    spans: std.array_list.Managed(SpanState),
};

fn richTextMeasure(n: *Node, c: Constraints) Size {
    const s: *RichTextState = @ptrCast(@alignCast(n.state.?));
    var w: f32 = 0;
    var h: f32 = 0;
    for (s.spans.items) |span| {
        w += span.m.width;
        h = @max(h, span.m.height);
    }
    return c.constrain(.{ .w = w, .h = h });
}
fn richTextLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn richTextPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *RichTextState = @ptrCast(@alignCast(n.state.?));
    // Shared baseline: the tallest span's ascent.
    var ascent: f32 = 0;
    for (s.spans.items) |span| {
        ascent = @max(ascent, span.m.ascent);
    }
    const baseline = n.bounds.y + ascent;
    var x = n.bounds.x;
    for (s.spans.items) |span| {
        ui.paint.text(ctx, span.text, x, baseline, span.size, span.bold, span.color);
        x += span.m.width;
    }
}
fn richTextDeinit(n: *Node) void {
    const s: *RichTextState = @ptrCast(@alignCast(n.state.?));
    for (s.spans.items) |span| n.allocator.free(span.text);
    s.spans.deinit();
    n.allocator.destroy(s);
}
/// The spans' actual extent: they flow from bounds.x without wrapping, so
/// the glyph run may exceed the bounds' width (and its height when the
/// bounds are shorter than the tallest span).
fn richTextPaintBounds(n: *Node) Rect {
    const s: *RichTextState = @ptrCast(@alignCast(n.state.?));
    var w: f32 = 0;
    var h: f32 = 0;
    for (s.spans.items) |span| {
        w += span.m.width;
        h = @max(h, span.m.height);
    }
    return .{ .x = n.bounds.x, .y = n.bounds.y, .w = w, .h = h };
}
const rich_text_vtable = ui.node.VTable{ .measure = richTextMeasure, .layout = richTextLayout, .paint = richTextPaint, .deinit = richTextDeinit, .paint_bounds = richTextPaintBounds };

/// RichText — a single line of styled spans. Copies the span strings.
/// Error-safe: spans are copied first; on failure everything is freed.
pub fn richText(allocator: std.mem.Allocator, spans: []const TextSpan) !*Node {
    var owned = std.array_list.Managed(SpanState).init(allocator);
    errdefer {
        for (owned.items) |span| allocator.free(span.text);
        owned.deinit();
    }
    for (spans) |span| {
        const buf = try allocator.alloc(u8, span.text.len + 1);
        @memcpy(buf[0..span.text.len], span.text);
        buf[span.text.len] = 0;
        owned.append(.{
            .text = buf[0..span.text.len :0],
            .size = span.size,
            .color = span.color,
            .bold = span.bold,
            .m = ui.paint.measureText(buf[0..span.text.len :0], span.size, span.bold),
        }) catch {
            allocator.free(buf);
            return error.OutOfMemory;
        };
    }
    const node = try Node.create(allocator, &rich_text_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(RichTextState);
    errdefer allocator.destroy(s);
    s.* = .{ .spans = owned }; // moves the list (no fallible ops after this)
    node.state = s;
    return node;
}

// --- tests ---

test "text measure uses real font metrics" {
    const t = try text(std.testing.allocator, "Hi", .{ .size = 24 });
    defer t.deinit();
    const size = t.measure(.{});
    try std.testing.expect(size.w > 0);
    try std.testing.expect(size.h > 0);
    // Height tracks the font size (ascent + descent).
    try std.testing.expect(size.h > 24 * 0.8);
    try std.testing.expect(size.h < 24 * 2);
    // Longer strings measure wider (monotonic, font-agnostic).
    const long = try text(std.testing.allocator, "Hi Hi Hi Hi", .{ .size = 24 });
    defer long.deinit();
    try std.testing.expect(long.measure(.{}).w > size.w);
}

test "rich text measure sums span widths, max height" {
    const rt = try richText(std.testing.allocator, &.{
        .{ .text = "Hello ", .size = 16, .color = 0xFFFFFFFF },
        .{ .text = "world", .size = 32, .color = 0xFF0000FF, .bold = true },
    });
    defer rt.deinit();
    const single = try text(std.testing.allocator, "Hello ", .{ .size = 16 });
    defer single.deinit();
    const world = try text(std.testing.allocator, "world", .{ .size = 32, .bold = true });
    defer world.deinit();
    const size = rt.measure(.{});
    const expected_w = single.measure(.{}).w + world.measure(.{}).w;
    try std.testing.expectApproxEqAbs(expected_w, size.w, 0.001);
    try std.testing.expectApproxEqAbs(world.measure(.{}).h, size.h, 0.001);
}

test "golden: text renders ink inside its bounds, none outside" {
    const bg = 0x101010FF;
    const white = 0xFFFFFFFF;
    const root = try text(std.testing.allocator, "Hi", .{ .size = 24, .color = white });
    var frame = try golden.render(std.testing.allocator, root, 128, 64, bg);
    defer frame.deinit();
    const m = ui.paint.measureText("Hi", 24, false);
    try std.testing.expect(m.width > 0); // requires fonts (CI runners have them)
    const ink = frame.countNotIn(.{ .x = 0, .y = 0, .w = m.width, .h = 64 }, bg);
    try std.testing.expect(ink > 0);
    // Right of the text: pure background.
    const margin_x = @as(i32, @intFromFloat(m.width)) + 4;
    try std.testing.expectEqual(@as(u64, 0), frame.countNotIn(.{
        .x = @floatFromInt(margin_x),
        .y = 0,
        .w = @floatFromInt(128 - margin_x),
        .h = 64,
    }, bg));
}

test "golden: rich text paints both spans" {
    const bg = 0x101010FF;
    const white = 0xFFFFFFFF;
    const red = 0xFF0000FF;
    const rt = try richText(std.testing.allocator, &.{
        .{ .text = "ab", .size = 24, .color = white },
        .{ .text = "cd", .size = 24, .color = red },
    });
    var frame = try golden.render(std.testing.allocator, rt, 128, 64, bg);
    defer frame.deinit();
    // White and red ink are both present (AA blends differ per span color).
    try std.testing.expect(frame.countNot(bg) > 0);
    try std.testing.expect(frame.countColor(white) > 0);
    try std.testing.expect(frame.countColor(red) > 0);
}

fn fmtBoundCount(v: u32, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "Pressed {d} times", .{v}) catch null;
}

test "boundText: follows the signal and re-layouts on change" {
    const sig = try ui.state.Signal(u32).init(std.testing.allocator, 1);
    defer sig.deinit();
    const node = try BoundText(u32).text(std.testing.allocator, sig, fmtBoundCount, .{ .size = 16, .color = 0xFFFFFFFF });
    defer node.deinit();
    const m1 = ui.paint.measureText("Pressed 1 times", 16, false);
    const s1 = node.measure(.{ .max_w = 400, .max_h = 20 });
    try std.testing.expectApproxEqAbs(m1.width, s1.w, 0.01);
    try std.testing.expectApproxEqAbs(m1.height, s1.h, 0.01);
    node.layout_dirty = false;
    node.dirty = false;
    sig.set(12345); // value changed → the node must re-layout (size changes)
    try std.testing.expect(node.layout_dirty);
    try std.testing.expect(node.dirty); // and repaint (idle host renders only when dirty)
    const m2 = ui.paint.measureText("Pressed 12345 times", 16, false);
    const s2 = node.measure(.{ .max_w = 400, .max_h = 20 });
    try std.testing.expectApproxEqAbs(m2.width, s2.w, 0.01);
    // no-op set: no re-layout
    node.layout_dirty = false;
    sig.set(12345);
    try std.testing.expect(!node.layout_dirty);
}

fn fmtEcho(v: [:0]const u8, buf: []u8) ?[]const u8 {
    if (v.len > buf.len) return null;
    @memcpy(buf[0..v.len], v);
    return buf[0..v.len];
}

test "boundText: text signals grow past the old 128-byte formatter cap" {
    const sig = try ui.state.TextSignal.init(std.testing.allocator, "hi");
    defer sig.deinit();
    const node = try BoundText([:0]const u8).text(std.testing.allocator, sig, fmtEcho, .{ .size = 16 });
    defer node.deinit();
    const m1 = node.measure(.{ .max_w = 4000, .max_h = 20 });
    const e1 = ui.paint.measureText("hi", 16, false);
    try std.testing.expectApproxEqAbs(e1.width, m1.w, 0.01);
    // a value far over the old fixed [128]u8 formatter buffer lands whole
    var long_buf: [406]u8 = undefined;
    @memcpy(long_buf[0..5], "echo ");
    @memset(long_buf[5..405], 'z');
    long_buf[405] = 0;
    const long: [:0]const u8 = long_buf[0..405 :0];
    try sig.set(long);
    try std.testing.expect(node.layout_dirty);
    try std.testing.expectEqualStrings(long, node.semantics.?.label);
    const m2 = node.measure(.{ .max_w = 4000, .max_h = 20 });
    const e2 = ui.paint.measureText(long, 16, false);
    try std.testing.expectApproxEqAbs(e2.width, m2.w, 0.01);
}

test "golden: boundText paints the current signal value" {
    const bg = 0x101010FF;
    const white = 0xFFFFFFFF;
    const sig = try ui.state.Signal(u32).init(std.testing.allocator, 7);
    defer sig.deinit();
    // Deinit order: the tree BEFORE the renderer (ctx-bound resources rule).
    var r = try golden.Renderer.init(std.testing.allocator, 384, 64);
    defer r.deinit(); // runs LAST
    const root = try BoundText(u32).text(std.testing.allocator, sig, fmtBoundCount, .{ .size = 24, .color = white });
    defer root.deinit(); // runs FIRST (LIFO)
    root.layout(.{ .x = 0, .y = 0, .w = 384, .h = 64 });
    r.paint(root, bg);
    var frame = try r.readback(std.testing.allocator);
    defer frame.deinit();
    const m = ui.paint.measureText("Pressed 7 times", 24, false);
    try std.testing.expect(frame.countNotIn(.{ .x = 0, .y = 0, .w = m.width, .h = 64 }, bg) > 0);
    // after a change + relayout + repaint, the wider string paints wider ink
    sig.set(100000);
    root.layout(.{ .x = 0, .y = 0, .w = 384, .h = 64 });
    r.paint(root, bg);
    var frame2 = try r.readback(std.testing.allocator);
    defer frame2.deinit();
    const m2 = ui.paint.measureText("Pressed 100000 times", 24, false);
    try std.testing.expect(m2.width > m.width);
    try std.testing.expect(frame2.countNotIn(.{ .x = 0, .y = 0, .w = m2.width, .h = 64 }, bg) > 0);
}

test "BoundText: the semantic label follows the signal (a11y)" {
    const sig = try ui.state.Signal(u32).init(std.testing.allocator, 1);
    defer sig.deinit();
    const node = try BoundText(u32).text(std.testing.allocator, sig, fmtBoundCount, .{});
    defer node.deinit();
    try std.testing.expectEqualStrings("Pressed 1 times", node.semantics.?.label);
    sig.set(42);
    try std.testing.expectEqualStrings("Pressed 42 times", node.semantics.?.label);
}
