// Text widgets (Phase 1b P0) — Text (single line) and RichText (styled spans).
// Metrics come from the kx_skia ABI (kx_measure_text — real font metrics, not
// approximations); rich text shapes through kx_text_layout (SkParagraph —
// HarfBuzz + ICU bidi + fallback, ABI 0.15.0).
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
    /// Full M3E weight 100..900 (0 = derive from `bold` → 400/700) — the
    /// type_scale styles carry the real value (label_large is 500, not
    /// bold).
    weight: u16 = 0,
    /// px of tracking added between glyphs (0 = font default) — the
    /// type_scale styles carry the token letterSpacing.
    letter_spacing: f32 = 0,
    /// Line-height override in px (0 = font-intrinsic metrics) — Compose's
    /// TextStyle.lineHeight; the type_scale line_height tokens.
    line_height: f32 = 0,
    text_align: TextAlign = .left, // named text_align — `align` is a Zig keyword
    /// Variable-font axes (ABI 0.17.0): OpenType design coordinates, e.g.
    /// `.{ .axis = ui.paint.axis_wght, .value = 500 }`. A 'wght' axis
    /// overrides the bold→400/700 derivation on variable fonts. Caller-owned
    /// slice — copied at construction; animate via setAxisValue/setAxes.
    variations: []const ui.paint.FontAxis = &.{},
    /// Font family override (0.17.0) — "SF Compact", "New York", a
    /// PostScript name; null = platform default. Copied at construction
    /// (≤63 bytes kept). Selects a variable-capable face so `variations`
    /// actually move the glyphs.
    family: ?[]const u8 = null,
};

/// The resolved fontStyle weight — `weight` wins, else `bold` → 700/400.
fn textWeight(opts: TextOptions) i32 {
    return if (opts.weight != 0) @intCast(opts.weight) else if (opts.bold) 700 else 400;
}

/// Variable-font paint state shared by Text and BoundText: when `axes_n > 0`
/// or a family override is set the node paints through a retained
/// kx_text_layout (the simple kx_draw_text_styled path carries neither) and
/// `m` is filled from that layout's metrics. `layout_dirty` re-arms on
/// text/style/axis change — the next measure/paint rebuilds once.
const VarText = struct {
    axes: [ui.paint.max_font_variations]ui.paint.FontAxis = undefined,
    axes_n: u8 = 0,
    /// Family override bytes (≤63) + sentinel — copied at construction so
    /// the retained layout can rebuild long after opts.family dangles.
    family: [64]u8 = undefined,
    family_n: u8 = 0,
    layout: ?*ui.paint.TextLayout = null,
    layout_dirty: bool = false,
    /// A line-height override needs the paragraph path too (the simple draw
    /// call carries no line-box metric).
    line_height: f32 = 0,

    /// The layout path is needed for axes OR a family override OR a
    /// line-height override — the simple draw call carries none of them.
    fn needsLayout(self: *const VarText) bool {
        return self.axes_n > 0 or self.family_n > 0 or self.line_height > 0;
    }

    /// Copy the immutable-per-node font bits (axes + family + line height)
    /// out of opts — used at construction, BEFORE the node is attached (no
    /// dirty marks: layout_dirty is set so the first measure/paint builds
    /// once).
    fn seed(self: *VarText, opts: TextOptions) void {
        self.axes_n = @intCast(@min(opts.variations.len, ui.paint.max_font_variations));
        @memcpy(self.axes[0..self.axes_n], opts.variations[0..self.axes_n]);
        self.line_height = opts.line_height;
        if (opts.family) |f| {
            const n: u8 = @intCast(@min(f.len, self.family.len - 1));
            @memcpy(self.family[0..n], f[0..n]);
            self.family[n] = 0;
            self.family_n = n;
        }
        self.layout_dirty = self.needsLayout();
    }

    fn styleOf(self: *const VarText, opts: TextOptions) ui.paint.TextStyle {
        var st = ui.paint.textStyle(opts.size, textWeight(opts), 0, opts.letter_spacing, opts.color);
        st.line_height = opts.line_height;
        ui.paint.withVariations(&st, self.axes[0..self.axes_n]);
        if (self.family_n > 0)
            st.family = @ptrCast(self.family[0..self.family_n :0].ptr);
        return st;
    }

    fn ensureLayout(self: *VarText, opts: TextOptions, str: [:0]const u8, m: *ui.paint.TextMetrics) void {
        if (!self.needsLayout()) return;
        if (self.layout != null and !self.layout_dirty) return;
        if (self.layout) |l| ui.paint.textLayoutDestroy(l);
        self.layout = ui.paint.textLayoutBegin(0);
        if (self.layout) |l| {
            ui.paint.textLayoutSpan(l, str, self.styleOf(opts));
            const baseline = ui.paint.textLayoutBaseline(l);
            const height = ui.paint.textLayoutHeight(l);
            m.* = .{ .width = ui.paint.textLayoutWidth(l), .height = height, .ascent = baseline, .descent = height - baseline };
        }
        self.layout_dirty = false;
    }

    fn deinit(self: *VarText) void {
        if (self.layout) |l| ui.paint.textLayoutDestroy(l);
        self.layout = null;
    }

    /// Replace all axes (≤8 kept). No-op when identical — safe per tick.
    fn setAxes(self: *VarText, n: *Node, axes: []const ui.paint.FontAxis) void {
        const count: u8 = @intCast(@min(axes.len, ui.paint.max_font_variations));
        const same = count == self.axes_n and blk: {
            for (axes[0..count], self.axes[0..count]) |new, old|
                if (new.axis != old.axis or new.value != old.value) break :blk false;
            break :blk true;
        };
        if (same) return;
        @memcpy(self.axes[0..count], axes[0..count]);
        self.axes_n = count;
        self.layout_dirty = true;
        n.markLayoutDirty(); // axes move advances — metrics may change
        n.markDirty();
    }

    /// Animate one axis (a spring driving 'wght' 400→700). Appends the axis
    /// when absent and room remains. No-op when the value didn't move.
    fn setAxisValue(self: *VarText, n: *Node, axis: u32, value: f32) void {
        for (self.axes[0..self.axes_n]) |*a| {
            if (a.axis != axis) continue;
            if (a.value == value) return;
            a.value = value;
            break;
        } else {
            if (self.axes_n >= ui.paint.max_font_variations) return;
            self.axes[self.axes_n] = .{ .axis = axis, .value = value };
            self.axes_n += 1;
        }
        self.layout_dirty = true;
        n.markLayoutDirty();
        n.markDirty();
    }
};

const TextState = struct {
    text: [:0]const u8, // owned, null-terminated
    opts: TextOptions,
    /// Metrics measured once at construction: a Text's string and the
    /// metrics-relevant opts (size, bold) are immutable for the node's
    /// lifetime — only the color mutates (setColor, which doesn't affect
    /// measurement); variable axes refresh it via setAxes/setAxisValue.
    /// measure/paint/paintBounds read this instead of re-measuring every
    /// frame.
    m: ui.paint.TextMetrics,
    vt: VarText = .{},
};

fn textMeasure(n: *Node, c: Constraints) Size {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    s.vt.ensureLayout(s.opts, s.text, &s.m); // refresh axes-driven metrics
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
    s.vt.ensureLayout(s.opts, s.text, &s.m);
    const x = textX(n, s.m, s.opts.text_align);
    // Skia draws from the baseline: one ascent below the top.
    if (s.vt.layout) |l| {
        ui.paint.textLayoutPaint(ctx, l, x, n.bounds.y + s.m.ascent);
    } else {
        ui.paint.textStyled(ctx, s.text, x, n.bounds.y + s.m.ascent, s.opts.size, textWeight(s.opts), s.opts.letter_spacing, s.opts.color);
    }
}
fn textDeinit(n: *Node) void {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    s.vt.deinit();
    n.allocator.free(s.text);
    n.allocator.destroy(s);
}
/// The glyphs' actual rect: the alignment may place them outside the bounds
/// (a constrained right-aligned text paints left of its box). Culling and
/// damage consult it.
fn textPaintBounds(n: *Node) Rect {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    s.vt.ensureLayout(s.opts, s.text, &s.m);
    return .{ .x = textX(n, s.m, s.opts.text_align), .y = n.bounds.y, .w = s.m.width, .h = s.m.height };
}
const text_vtable = ui.node.VTable{ .measure = textMeasure, .layout = textLayout, .paint = textPaint, .deinit = textDeinit, .paint_bounds = textPaintBounds, .measure_pure = true };

/// The first-line baseline offset (ascent) of a Text node — the anchor for
/// baseline-driven layouts (e.g. Compose `paddingFromBaseline` in tooltips).
/// Call after the node has been measured at the intended constraints.
pub fn textBaseline(n: *Node) f32 {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    return s.m.ascent;
}

pub fn text(allocator: std.mem.Allocator, str: []const u8, opts: TextOptions) !*Node {
    const node = try Node.create(allocator, &text_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(TextState);
    errdefer allocator.destroy(s);
    const buf = try allocator.alloc(u8, str.len + 1);
    errdefer allocator.free(buf);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    s.* = .{ .text = buf[0..str.len :0], .opts = opts, .m = ui.paint.measureTextStyled(buf[0..str.len :0], opts.size, textWeight(opts), opts.letter_spacing) };
    // Seed the axes/family WITHOUT the dirty marks — setAxes dereferences
    // n.state for the damage paths and this node isn't attached yet.
    s.vt.seed(opts);
    if (s.vt.needsLayout())
        s.vt.ensureLayout(s.opts, s.text, &s.m); // seed metrics from the variable-font layout
    node.state = s;
    ui.semantics.attach(node, .{ .role = .text, .label = s.text }); // Phase 2c
    return node;
}

/// Replace the string on a live text (row recycling, counters, live labels):
/// re-measures — the bounds may change → layout dirty. The semantics label
/// follows the new bytes (it borrowed the old buffer, which may be freed).
/// The buffer is reused in place when the new string fits.
pub fn setText(n: *Node, str: []const u8) void {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    if (std.mem.eql(u8, s.text, str)) return;
    if (str.len <= s.text.len) {
        const buf = @constCast(s.text.ptr)[0 .. str.len + 1];
        @memcpy(buf[0..str.len], str);
        buf[str.len] = 0;
        s.text = buf[0..str.len :0];
    } else {
        const buf = n.allocator.alloc(u8, str.len + 1) catch @panic("klaxon: out of memory");
        @memcpy(buf[0..str.len], str);
        buf[str.len] = 0;
        n.allocator.free(@constCast(s.text.ptr)[0 .. s.text.len + 1]);
        s.text = buf[0..str.len :0];
    }
    s.m = ui.paint.measureTextStyled(s.text, s.opts.size, textWeight(s.opts), s.opts.letter_spacing);
    s.vt.layout_dirty = s.vt.needsLayout();
    if (n.semantics) |sem| {
        if (sem.role == .text) sem.label = s.text;
    }
    n.markLayoutDirty();
    n.markDirty();
}

/// Recolor a live text (signal-driven widgets recolor their label on state
/// change — e.g. the M3E chip's selected state).
pub fn setColor(n: *Node, color: Color) void {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    s.opts.color = color;
    if (s.vt.needsLayout()) s.vt.layout_dirty = true; // span color is baked at build
    n.markDirty();
}

/// Replace the variable-font axes (M3E weight/width animation).
pub fn setAxes(n: *Node, axes: []const ui.paint.FontAxis) void {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    s.vt.setAxes(n, axes);
}

/// Animate one axis in place — e.g. a spring writing 'wght' each tick.
/// No-op when the value didn't move.
pub fn setAxisValue(n: *Node, axis: u32, value: f32) void {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    s.vt.setAxisValue(n, axis, value);
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
            vt: VarText = .{},
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
            s.m = ui.paint.measureTextStyled(str, s.opts.size, textWeight(s.opts), s.opts.letter_spacing); // reformatted → re-measure once
            s.vt.layout_dirty = true; // new string → retained paragraph rebuilds on next use
            if (n.semantics) |sem| sem.label = str; // re-point: a grow may have moved the buffer
            return str;
        }

        fn measure(n: *Node, c: Constraints) Size {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            const str = bound(n); // refresh buf + metrics when the signal changed
            s.vt.ensureLayout(s.opts, str, &s.m);
            return c.constrain(.{ .w = s.m.width, .h = s.m.height });
        }
        fn layout(n: *Node, bounds: Rect) void {
            _ = n;
            _ = bounds; // leaf: bounds come from the parent
        }
        fn paint(n: *Node, ctx: *kx.Ctx) void {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            const str = bound(n);
            s.vt.ensureLayout(s.opts, str, &s.m);
            const x = textX(n, s.m, s.opts.text_align);
            if (s.vt.layout) |l| {
                ui.paint.textLayoutPaint(ctx, l, x, n.bounds.y + s.m.ascent);
            } else {
                ui.paint.textStyled(ctx, str, x, n.bounds.y + s.m.ascent, s.opts.size, textWeight(s.opts), s.opts.letter_spacing, s.opts.color);
            }
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
            s.vt.deinit();
            s.buf.deinit();
            n.allocator.destroy(s);
        }
        fn paintBounds(n: *Node) Rect {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            const str = bound(n); // keep metrics in step with the current string
            s.vt.ensureLayout(s.opts, str, &s.m);
            return .{ .x = textX(n, s.m, s.opts.text_align), .y = n.bounds.y, .w = s.m.width, .h = s.m.height };
        }
        const vtable = ui.node.VTable{ .measure = measure, .layout = layout, .paint = paint, .deinit = deinit, .paint_bounds = paintBounds };

        /// Variable-font axes — same semantics as text.setAxes/setAxisValue.
        pub fn setAxes(n: *Node, axes: []const ui.paint.FontAxis) void {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            s.vt.setAxes(n, axes);
        }
        pub fn setAxisValue(n: *Node, axis: u32, value: f32) void {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            s.vt.setAxisValue(n, axis, value);
        }

        pub fn text(allocator: std.mem.Allocator, sig: *SignalFor(T), fmt: *const fn (T, []u8) ?[]const u8, opts: TextOptions) !*Node {
            const node = try Node.create(allocator, &vtable);
            errdefer node.allocator.destroy(node); // no state yet
            const s = try allocator.create(State);
            errdefer allocator.destroy(s);
            s.* = .{ .sig = sig, .fmt = fmt, .opts = opts, .buf = std.array_list.Managed(u8).init(allocator), .dirty = true, .m = std.mem.zeroes(ui.paint.TextMetrics) };
            errdefer s.buf.deinit();
            s.vt.seed(opts);
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
    /// Full M3E weight axis 100..900 (0 = derive from `bold` → 400/700).
    weight: u16 = 0,
    italic: bool = false,
    letter_spacing: f32 = 0, // px added between glyphs (0 = font default)
    /// Variable-font axes for this span (0.17.0) — a 'wght' coord overrides
    /// weight on variable fonts. Caller-owned; copied at build.
    variations: []const ui.paint.FontAxis = &.{},
    /// Font family override for this span (0.17.0); null = platform
    /// default. Consumed at build (≤63 bytes kept).
    family: ?[]const u8 = null,
};

const RichTextState = struct {
    /// Concatenated span strings (owned, for the a11y label — the paragraph
    /// holds its own copy for rendering).
    label: [:0]const u8,
    /// One shaped paragraph for all spans — real rich text (the spans shape
    /// together: cross-span kerning, bidi-aware ordering, per-span weight/
    /// italic/letter-spacing/color). Built once at construction.
    layout: ?*ui.paint.TextLayout,
};

fn richTextMeasure(n: *Node, c: Constraints) Size {
    const s: *RichTextState = @ptrCast(@alignCast(n.state.?));
    if (s.layout) |l| {
        return c.constrain(.{ .w = ui.paint.textLayoutWidth(l), .h = ui.paint.textLayoutHeight(l) });
    }
    return c.constrain(.{ .w = 0, .h = 0 });
}
fn richTextLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn richTextPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *RichTextState = @ptrCast(@alignCast(n.state.?));
    if (s.layout) |l| {
        ui.paint.textLayoutPaint(ctx, l, n.bounds.x, n.bounds.y + ui.paint.textLayoutBaseline(l));
    }
}
fn richTextDeinit(n: *Node) void {
    const s: *RichTextState = @ptrCast(@alignCast(n.state.?));
    if (s.layout) |l| ui.paint.textLayoutDestroy(l);
    n.allocator.free(s.label);
    n.allocator.destroy(s);
}
/// The paragraph's actual extent (unconstrained: its longest line may
/// exceed the bounds' width).
fn richTextPaintBounds(n: *Node) Rect {
    const s: *RichTextState = @ptrCast(@alignCast(n.state.?));
    const w = if (s.layout) |l| ui.paint.textLayoutWidth(l) else 0;
    const h = if (s.layout) |l| ui.paint.textLayoutHeight(l) else 0;
    return .{ .x = n.bounds.x, .y = n.bounds.y, .w = w, .h = h };
}
const rich_text_vtable = ui.node.VTable{ .measure = richTextMeasure, .layout = richTextLayout, .paint = richTextPaint, .deinit = richTextDeinit, .paint_bounds = richTextPaintBounds };

/// RichText — styled spans shaped as ONE paragraph (ABI 0.15.0): per-span
/// weight/italic/letter-spacing/color, real shaping + bidi + fallback.
/// Copies the span strings. Error-safe: the label is built first; on
/// failure everything is freed.
pub fn richText(allocator: std.mem.Allocator, spans: []const TextSpan) !*Node {
    var label = std.array_list.Managed(u8).init(allocator);
    errdefer label.deinit();
    for (spans) |span| try label.appendSlice(span.text);
    const owned_label = try label.toOwnedSliceSentinel(0); // exactly-sized alloc — free(s.label) is a valid pair
    const l = ui.paint.textLayoutBegin(0); // unconstrained — one line
    for (spans) |span| {
        const weight: i32 = if (span.weight != 0) @intCast(span.weight) else if (span.bold) 700 else 400;
        // The paragraph copies the span text at span() time — a Zig-side
        // temporary sentinel suffices.
        const buf = try allocator.alloc(u8, span.text.len + 1);
        defer allocator.free(buf);
        @memcpy(buf[0..span.text.len], span.text);
        buf[span.text.len] = 0;
        if (l) |layout| {
            var st = ui.paint.textStyle(span.size, weight, if (span.italic) 1 else 0, span.letter_spacing, span.color);
            ui.paint.withVariations(&st, span.variations);
            var fam_buf: [64]u8 = undefined;
            if (span.family) |f| {
                const flen = @min(f.len, fam_buf.len - 1);
                @memcpy(fam_buf[0..flen], f[0..flen]);
                fam_buf[flen] = 0;
                st.family = @ptrCast(fam_buf[0..flen :0].ptr);
            }
            ui.paint.textLayoutSpan(layout, buf[0..span.text.len :0], st);
        }
    }
    const node = try Node.create(allocator, &rich_text_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(RichTextState);
    errdefer allocator.destroy(s);
    s.* = .{
        .label = owned_label,
        .layout = l,
    };
    node.state = s;
    ui.semantics.attach(node, .{ .role = .text, .label = s.label });
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
    // Real shaping kerns across the span boundary: a multi-span paragraph
    // accumulates span advances but is not bit-exact against separately
    // measured strings.
    try std.testing.expectApproxEqRel(expected_w, size.w, 0.1);
    try std.testing.expectApproxEqAbs(world.measure(.{}).h, size.h, 0.001);
    // Uniform-style spans must measure identically to the joined string.
    const joined = try richText(std.testing.allocator, &.{
        .{ .text = "Hello ", .size = 16 },
        .{ .text = "world", .size = 16 },
    });
    defer joined.deinit();
    const flat = try text(std.testing.allocator, "Hello world", .{ .size = 16 });
    defer flat.deinit();
    try std.testing.expectApproxEqAbs(flat.measure(.{}).w, joined.measure(.{}).w, 0.001);
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

test "variable font axes: layout path engages and animates in place" {
    const wght = ui.paint.axis_wght;
    const t = try text(std.testing.allocator, "Ag", .{
        .size = 24,
        .variations = &.{.{ .axis = wght, .value = 400 }},
    });
    defer t.deinit();
    const s: *TextState = @ptrCast(@alignCast(t.state.?));
    try std.testing.expect(s.vt.axes_n == 1);
    try std.testing.expect(s.vt.layout != null); // retained paragraph path
    const w400 = t.measure(.{}).w;
    try std.testing.expect(w400 > 0);

    // A spring-style per-tick write: same value is a no-op, a new value
    // rebuilds the retained paragraph and re-measures. (markLayoutDirty
    // consults paint_bounds synchronously, which consumes layout_dirty —
    // assert the metrics respond, not the flag.)
    setAxisValue(t, wght, 400);
    try std.testing.expect(s.vt.axes[0].value == 400);
    setAxisValue(t, wght, 700);
    try std.testing.expect(s.vt.axes[0].value == 700);
    const w700 = t.measure(.{}).w;
    try std.testing.expect(w700 > 0);
    // wght=700 widens 'Ag' on a variable font; a font without the axis keeps
    // the same advance — it must never shrink.
    try std.testing.expect(w700 >= w400 - 0.5);

    // setAxes replaces the whole axis set — 'wght' 700 + 'wdth' 100.
    setAxes(t, &.{ .{ .axis = wght, .value = 700 }, .{ .axis = ui.paint.axis_wdth, .value = 100 } });
    try std.testing.expect(s.vt.axes_n == 2);
    try std.testing.expect(t.measure(.{}).w > 0);
}

test "golden: variable-font text paints ink inside bounds" {
    const bg = 0x101010FF;
    const root = try text(std.testing.allocator, "Ag", .{
        .size = 24,
        .color = 0xFFFFFFFF,
        .variations = &.{.{ .axis = ui.paint.axis_wght, .value = 700 }},
    });
    const m = root.measure(.{}); // read before render — golden.render deinits the tree
    try std.testing.expect(m.w > 0);
    var frame = try golden.render(std.testing.allocator, root, 128, 64, bg);
    defer frame.deinit();
    try std.testing.expect(frame.countNotIn(.{ .x = 0, .y = 0, .w = m.w, .h = 64 }, bg) > 0);
}

test "rich text span honors a per-span variation axis" {
    const rt = try richText(std.testing.allocator, &.{
        .{ .text = "Aa", .size = 24, .color = 0xFFFFFFFF, .variations = &.{.{ .axis = ui.paint.axis_wght, .value = 300 }} },
        .{ .text = "Bb", .size = 24, .color = 0xFF0000FF, .variations = &.{.{ .axis = ui.paint.axis_wght, .value = 900 }} },
    });
    defer rt.deinit();
    try std.testing.expect(rt.measure(.{}).w > 0);
}

test "text family override: selects the face and reaches the wght axis" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    // "SF Compact" resolves to SFCompact.ttf — a variable face — so the wght
    // axis must actually move the advance.
    const light = try text(std.testing.allocator, "Ag", .{
        .size = 24,
        .family = "SF Compact",
        .variations = &.{.{ .axis = ui.paint.axis_wght, .value = 300 }},
    });
    defer light.deinit();
    const heavy = try text(std.testing.allocator, "Ag", .{
        .size = 24,
        .family = "SF Compact",
        .variations = &.{.{ .axis = ui.paint.axis_wght, .value = 900 }},
    });
    defer heavy.deinit();
    const s: *TextState = @ptrCast(@alignCast(heavy.state.?));
    try std.testing.expect(s.vt.family_n == 10); // "SF Compact" copied, layout path engaged
    const wl = light.measure(.{}).w;
    const wh = heavy.measure(.{}).w;
    try std.testing.expect(wl > 0 and wh > 0);
    // Hosts without SF Compact (CI runners) resolve it to the same
    // fallback a bogus family gets — nothing variable to exercise there.
    const bogus = try text(std.testing.allocator, "Ag", .{
        .size = 24,
        .family = "No Such Family 9x7",
        .variations = &.{.{ .axis = ui.paint.axis_wght, .value = 300 }},
    });
    defer bogus.deinit();
    if (wl == bogus.measure(.{}).w) return error.SkipZigTest;
    try std.testing.expect(@abs(wh - wl) > 0.5); // wght 300→900 moves a variable face
}
