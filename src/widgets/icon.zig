// Icon widget (Phase 1b P0) — a named icon painted as vector geometry in a
// 24dp box, recolored by the theme. Built-in names fill the canonical
// Material Symbols outlines (comptime-parsed SVG path data → kx_fill_path;
// font-independent); `codepoint` remains for external/custom icon fonts.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;

pub const IconName = enum {
    play,
    pause,
    stop,
    circle,
    square,
    triangle_right,
    triangle_left,
    triangle_up,
    triangle_down,
    arrow_right,
    arrow_left,
    arrow_up,
    arrow_down,
    chevron_right,
    chevron_left,
    check,
    close,
    menu,
    search,
    star,
    heart,
    plus,
    minus,
    home,
    music_note,
    movie,
    library_books,
    history,
    north_west,
};

/// Unicode codepoint for a built-in icon name (Geometric Shapes / Arrows /
/// Dingbats blocks — covered by DejaVu Sans and the system fonts; the emoji
/// codepoints resolve through the platform color-emoji font).
pub fn codepoint(name: IconName) u21 {
    return switch (name) {
        .play => 0x25B6, // ▶
        .pause => 0x275A, // ❚
        .stop => 0x25A0, // ■
        .circle => 0x25CF, // ●
        .square => 0x25A1, // □
        .triangle_right => 0x25B6, // ▶
        .triangle_left => 0x25C0, // ◀
        .triangle_up => 0x25B2, // ▲
        .triangle_down => 0x25BC, // ▼
        .arrow_right => 0x2192, // →
        .arrow_left => 0x2190, // ←
        .arrow_up => 0x2191, // ↑
        .arrow_down => 0x2193, // ↓
        .chevron_right => 0x203A, // ›
        .chevron_left => 0x2039, // ‹
        .check => 0x2713, // ✓
        .close => 0x2715, // ✕
        .menu => 0x2261, // ≡
        .search => 0x2315, // ⌕
        .star => 0x2605, // ★
        .heart => 0x2665, // ♥
        .plus => 0x002B, // +
        .minus => 0x2212, // −
        .home => 0x2302, // ⌂
        .music_note => 0x266A, // ♪
        .movie => 0x1F3AC, // 🎬 (color-emoji font)
        .library_books => 0x1F4DA, // 📚 (color-emoji font)
        .history => 0x21BB, // ↻
        .north_west => 0x2196, // ↖
    };
}

pub const IconOptions = struct {
    size: f32 = 24,
    color: Color = 0x000000FF, // opaque black (0xRRGGBBAA)
    label: []const u8 = "", // accessibility label (alt text, Phase 2c)
};

const IconState = struct {
    name: IconName,
    opts: IconOptions,
};

fn iconMeasure(n: *Node, c: Constraints) Size {
    const s: *IconState = @ptrCast(@alignCast(n.state.?));
    return c.constrain(.{ .w = s.opts.size, .h = s.opts.size });
}
fn iconLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
// Built-in icons paint as VECTOR GEOMETRY in a normalized 24dp box — not
// font glyphs. Text fallback resolves pictographs (▶ ● ★ ♥) through the
// platform color-emoji font: theme-independent bitmaps, per-OS glyph sets,
// platform-dependent metrics. Geometry is deterministic, recolors with the
// theme, and is identical on every backend.
fn iconPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *IconState = @ptrCast(@alignCast(n.state.?));
    const size = s.opts.size;
    const ox = n.bounds.x + (n.bounds.w - size) / 2;
    const oy = n.bounds.y + (n.bounds.h - size) / 2;
    drawIcon(ctx, s.name, ox, oy, size / 24.0, s.opts.color);
}

// --- icon tile cache ---
// The built-in icons are the same 24dp geometry recolored — every painted
// frame used to re-tessellate the same paths (stroke tessellation ~25µs/op
// on Graphite, e.g. ~180µs/frame for a text_field with two icons). The
// glyph-cache idiom: rasterize each (icon, px size, fractional phase,
// color) once into a snapped tile — a slot of the row atlas on GPU (blits
// join the open sprite mesh) or a private image elsewhere — then blit.
// Padding keeps stroke overhang inside the tile; the snapped tile origin +
// fractional key make the blit pixel-identical to a direct paint.
const icon_cache_pad = 1;
const IconKey = struct {
    name: IconName,
    tw: i32, // snapped tile extent in LOGICAL units (the blit dst)
    th: i32,
    fx: u16, // fractional origin ×256 inside the tile
    fy: u16,
    color: Color,
    /// Device scale the tile was rasterized at (ABI 0.19.0: the atlas/
    /// offscreen pass consumes it internally). Quarter-step quantized —
    /// always ≥ the true scale so a scale-animating icon re-rasterizes a
    /// bounded number of times yet never blits undersampled pixels.
    ds_q: u16,
};
const IconEntry = struct {
    key: IconKey,
    ctx: ?*kx.Ctx = null, // owner — used to free resources, never for lookup
    serial: u64 = 0, // ctx instance id — a recycled address can't collide
    image: u64 = 0, // private image (raster / atlas fallback)
    slot: [4]f32 = .{ 0, 0, 0, 0 },
    atlas: bool = false,
    atlas_gen: u32 = 0,
};
var icon_cache: [128]IconEntry = undefined;
var icon_cache_len: usize = 0;
var icon_cache_next: usize = 0; // FIFO evict

fn iconCacheEvict(e: *IconEntry) void {
    // Free only into a LIVE ctx — a destroyed ctx already released its
    // images/atlas; freeing into a recycled address would be a UAF.
    const ctx = e.ctx;
    if (ctx != null and e.serial != 0 and ui.paint.ctxSerialAlive(e.serial)) {
        if (e.atlas) {
            if (e.atlas_gen == ui.paint.atlasGen(ctx.?)) ui.paint.atlasFree(ctx.?, e.slot);
        } else if (e.image != 0) {
            ui.paint.imageDestroy(ctx.?, e.image);
        }
    }
    e.* = .{ .key = undefined };
}

/// Blit the cached tile at its snapped integer origin. The slot/image is
/// device-sized (scale × logical); the dst stays the LOGICAL tile extent.
fn iconBlit(e: *const IconEntry, ctx: *kx.Ctx, tx: f32, ty: f32) void {
    if (e.atlas) {
        const img = ui.paint.atlasImage(ctx);
        if (img != 0) {
            ui.paint.imageDrawRegion(ctx, img, e.slot[0], e.slot[1], e.slot[2], e.slot[3],
                tx, ty, @floatFromInt(e.key.tw), @floatFromInt(e.key.th));
            return;
        }
    }
    if (e.image != 0)
        ui.paint.imageDraw(ctx, e.image, tx, ty, @floatFromInt(e.key.tw), @floatFromInt(e.key.th));
}

/// Draw a built-in icon into a `24*k` box at (ox,oy). Shared by the icon
/// widget and widgets that paint icons inline (navigation rail, FAB, etc.).
var icon_cache_off: ?bool = null; // env latch — KX_NO_ICON_CACHE disables

pub fn drawIcon(ctx: *kx.Ctx, name: IconName, ox: f32, oy: f32, k: f32, color: Color) void {
    const size = 24 * k;
    if (size <= 0) return;
    // Inside the ATLAS write pass (a retained row's own rasterize, a
    // scroll-copy strip written into the atlas) slot blits self-sample the
    // texture being written — the icon paints as geometry instead. An
    // offscreen pass may blit tiles safely (different surfaces).
    if (icon_cache_off == null) icon_cache_off = std.c.getenv("KX_NO_ICON_CACHE") != null;
    if (icon_cache_off.? or ui.paint.inAtlasPass(ctx)) {
        drawIconGeometry(ctx, name, ox, oy, k, color);
        return;
    }
    // Snapped tile covering the ink + 1px stroke overhang — the fractional
    // phase is part of the key so the blit lands bit-identically.
    const tx = @floor(ox) - icon_cache_pad;
    const ty = @floor(oy) - icon_cache_pad;
    const tw: i32 = @intFromFloat(@ceil(ox + size) - tx);
    const th: i32 = @intFromFloat(@ceil(oy + size) - ty);
    // Quarter-step quantized device scale — the tile rasterizes at device
    // density inside the atlas/offscreen pass (ABI 0.19.0); folding the
    // scale into the key keeps a Retina tile from serving a 1x display and
    // vice versa.
    const ds_q: u16 = @intFromFloat(@ceil(ui.paint.canvasScale(ctx) * 4));
    const key: IconKey = .{
        .name = name,
        .tw = tw,
        .th = th,
        .fx = @intFromFloat(@round((ox - tx) * 256)),
        .fy = @intFromFloat(@round((oy - ty) * 256)),
        .color = color,
        .ds_q = ds_q,
    };
    const gen = ui.paint.atlasGen(ctx);
    const serial = ui.paint.ctxSerial(ctx);
    for (icon_cache[0..icon_cache_len]) |*e| {
        if (e.serial == serial and std.meta.eql(e.key, key) and
            (!e.atlas or e.atlas_gen == gen))
        {
            iconBlit(e, ctx, tx, ty);
            return;
        }
    }
    // Miss — rasterize into the cache. GPU atlas tiles join the sprite
    // batch; raster/offscreen keep a private image (same pixels either way).
    const b = kx.c.kx_backend_of(ctx);
    const atlas_ok = b != kx.c.KX_BACKEND_RASTER and
        b != kx.c.KX_BACKEND_GANESH_GLES and b != kx.c.KX_BACKEND_GANESH_WEBGL2;
    var e: IconEntry = .{ .key = key, .ctx = ctx, .serial = serial };
    var ok = false;
    if (atlas_ok and ui.paint.atlasBegin(ctx, tw, th, &e.slot)) {
        // atlas_begin already translated to the slot origin — shift the
        // icon's absolute coords into the tile like the offscreen path.
        ui.paint.translate(ctx, -tx, -ty);
        drawIconGeometry(ctx, name, ox, oy, k, color);
        ui.paint.atlasEnd(ctx);
        e.atlas = true;
        e.atlas_gen = gen;
        ok = true;
    } else if (ui.paint.offscreenBegin(ctx, tw, th)) {
        ui.paint.translate(ctx, -tx, -ty);
        drawIconGeometry(ctx, name, ox, oy, k, color);
        e.image = ui.paint.offscreenEndImage(ctx);
        ok = e.image != 0;
    }
    if (!ok) { // nested offscreen pass — paint directly, cache nothing
        drawIconGeometry(ctx, name, ox, oy, k, color);
        return;
    }
    var slot_idx: usize = undefined;
    if (icon_cache_len < icon_cache.len) {
        slot_idx = icon_cache_len;
        icon_cache[icon_cache_len] = e;
        icon_cache_len += 1;
    } else {
        iconCacheEvict(&icon_cache[icon_cache_next]);
        icon_cache[icon_cache_next] = e;
        slot_idx = icon_cache_next;
        icon_cache_next = (icon_cache_next + 1) % icon_cache.len;
    }
    iconBlit(&icon_cache[slot_idx], ctx, tx, ty);
}

// --- glyph geometry: Material Symbols path data ---
// The built-in icons fill the canonical Material Symbols outlines — the
// same 24x24-grid path data the Material icon font's glyphs compile to,
// parsed at comptime from SVG path-data strings into the kx_fill_path
// wire format (paint.PathVerb: 0 move / 1 line / 2 quad / 3 cubic / 4
// close; points a flat x,y stream). A glyph is FILLED, never stroked:
// Material outlines carry their 2dp stroke weight in the geometry.

/// A parsed icon glyph — slices into comptime-built static arrays.
const Glyph = struct { pts: []const f32, verbs: []const i32 };

/// SVG path-data cursor. Only what icon `d` strings need: command letters,
/// numbers with signs/decimals/exponents, `,`/whitespace separators.
const Scanner = struct {
    d: []const u8,
    i: usize = 0,

    fn isSep(c: u8) bool {
        return c == ' ' or c == ',' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
    }
    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }
    fn skipSep(s: *Scanner) void {
        while (s.i < s.d.len and isSep(s.d[s.i])) s.i += 1;
    }
    /// Read a command letter at the cursor (e/E excluded — that is only
    /// ever an exponent marker). Returns null on a number or the end.
    fn command(s: *Scanner) ?u8 {
        s.skipSep();
        if (s.i >= s.d.len) return null;
        const c = s.d[s.i];
        const lower = c | 0x20;
        if (lower >= 'a' and lower <= 'z' and lower != 'e') {
            s.i += 1;
            return c;
        }
        return null;
    }
    fn hasNumber(s: *Scanner) bool {
        s.skipSep();
        if (s.i >= s.d.len) return false;
        const c = s.d[s.i];
        return isDigit(c) or c == '-' or c == '+' or c == '.';
    }
    /// A coordinate token. SVG allows "10.5.5" (the second '.' opens a new
    /// number) and "4-2" (the '-' likewise) — a '.' continues the current
    /// number once only, an exponent needs digits to follow.
    fn num(s: *Scanner) f32 {
        s.skipSep();
        const start = s.i;
        if (s.i < s.d.len and (s.d[s.i] == '-' or s.d[s.i] == '+')) s.i += 1;
        var saw_dot = false;
        while (s.i < s.d.len) {
            const c = s.d[s.i];
            if (isDigit(c)) {
                s.i += 1;
            } else if (c == '.') {
                if (saw_dot) break;
                saw_dot = true;
                s.i += 1;
            } else if (c == 'e' or c == 'E') {
                var j = s.i + 1;
                if (j < s.d.len and (s.d[j] == '-' or s.d[j] == '+')) j += 1;
                if (j < s.d.len and isDigit(s.d[j])) {
                    s.i = j + 1;
                    while (s.i < s.d.len and isDigit(s.d[s.i])) s.i += 1;
                } else break;
            } else break;
        }
        const tok = s.d[start..s.i];
        if (tok.len == 0) @compileError("icon path: expected a number");
        return std.fmt.parseFloat(f32, tok) catch
            @compileError("icon path: bad number '" ++ tok ++ "'");
    }
};

/// Unsized parse output — glyph() shrinks it to exact arrays.
const RawGlyph = struct {
    verbs: [512]i32 = undefined,
    pts: [4096]f32 = undefined,
    nv: usize = 0,
    np: usize = 0,
    fn verb(r: *RawGlyph, v: i32) void {
        if (r.nv >= r.verbs.len) @compileError("icon path: too many verbs");
        r.verbs[r.nv] = v;
        r.nv += 1;
    }
    fn pt(r: *RawGlyph, x: f32, y: f32) void {
        if (r.np + 1 >= r.pts.len) @compileError("icon path: too many points");
        r.pts[r.np] = x;
        r.pts[r.np + 1] = y;
        r.np += 2;
    }
};

/// Parse SVG path data into the verb/point wire format (comptime only).
/// M/L/H/V/C/S/Q/T/Z, absolute + relative, implicit coordinate-pair
/// repetition; arcs (A) are unused by the glyph set and rejected.
fn parseRaw(comptime d: []const u8) RawGlyph {
    @setEvalBranchQuota(2_000_000);
    var r: RawGlyph = .{};
    var s = Scanner{ .d = d };
    var cur = [2]f32{ 0, 0 };
    var start = cur; // the open subpath's anchor (Z returns to it)
    var prev_cubic_ctrl: ?[2]f32 = null; // C's last control — S reflects it
    var prev_quad_ctrl: ?[2]f32 = null; // Q's control — T reflects it
    var cmd: u8 = 0;
    while (true) {
        // No letter: the previous command repeats (implicit lineto
        // after a moveto is folded in below — 'm' rewrites `cmd`).
        const c = s.command() orelse (if (s.hasNumber()) cmd else break);
        const rel = c >= 'a' and c <= 'z';
        switch (c | 0x20) {
            'm' => {
                var x = s.num();
                var y = s.num();
                if (rel) {
                    x += cur[0];
                    y += cur[1];
                }
                r.verb(0);
                r.pt(x, y);
                cur = .{ x, y };
                start = cur;
                cmd = if (rel) 'l' else 'L'; // further pairs are lineto
                prev_cubic_ctrl = null;
                prev_quad_ctrl = null;
            },
            'l' => {
                var x = s.num();
                var y = s.num();
                if (rel) {
                    x += cur[0];
                    y += cur[1];
                }
                r.verb(1);
                r.pt(x, y);
                cur = .{ x, y };
                cmd = c;
                prev_cubic_ctrl = null;
                prev_quad_ctrl = null;
            },
            'h' => {
                var x = s.num();
                if (rel) x += cur[0];
                r.verb(1);
                r.pt(x, cur[1]);
                cur[0] = x;
                cmd = c;
                prev_cubic_ctrl = null;
                prev_quad_ctrl = null;
            },
            'v' => {
                var y = s.num();
                if (rel) y += cur[1];
                r.verb(1);
                r.pt(cur[0], y);
                cur[1] = y;
                cmd = c;
                prev_cubic_ctrl = null;
                prev_quad_ctrl = null;
            },
            'c' => {
                var x1 = s.num();
                var y1 = s.num();
                var x2 = s.num();
                var y2 = s.num();
                var x = s.num();
                var y = s.num();
                if (rel) {
                    x1 += cur[0];
                    y1 += cur[1];
                    x2 += cur[0];
                    y2 += cur[1];
                    x += cur[0];
                    y += cur[1];
                }
                r.verb(3);
                r.pt(x1, y1);
                r.pt(x2, y2);
                r.pt(x, y);
                prev_cubic_ctrl = .{ x2, y2 };
                prev_quad_ctrl = null;
                cur = .{ x, y };
                cmd = c;
            },
            's' => { // smooth cubic: c0 mirrors the previous cubic's c1
                const c0: [2]f32 = if (prev_cubic_ctrl) |p|
                    .{ 2 * cur[0] - p[0], 2 * cur[1] - p[1] }
                else
                    cur;
                var x2 = s.num();
                var y2 = s.num();
                var x = s.num();
                var y = s.num();
                if (rel) {
                    x2 += cur[0];
                    y2 += cur[1];
                    x += cur[0];
                    y += cur[1];
                }
                r.verb(3);
                r.pt(c0[0], c0[1]);
                r.pt(x2, y2);
                r.pt(x, y);
                prev_cubic_ctrl = .{ x2, y2 };
                prev_quad_ctrl = null;
                cur = .{ x, y };
                cmd = c;
            },
            'q' => {
                var x1 = s.num();
                var y1 = s.num();
                var x = s.num();
                var y = s.num();
                if (rel) {
                    x1 += cur[0];
                    y1 += cur[1];
                    x += cur[0];
                    y += cur[1];
                }
                r.verb(2);
                r.pt(x1, y1);
                r.pt(x, y);
                prev_quad_ctrl = .{ x1, y1 };
                prev_cubic_ctrl = null;
                cur = .{ x, y };
                cmd = c;
            },
            't' => { // smooth quad: the control mirrors the previous quad's
                const c0: [2]f32 = if (prev_quad_ctrl) |p|
                    .{ 2 * cur[0] - p[0], 2 * cur[1] - p[1] }
                else
                    cur;
                var x = s.num();
                var y = s.num();
                if (rel) {
                    x += cur[0];
                    y += cur[1];
                }
                r.verb(2);
                r.pt(c0[0], c0[1]);
                r.pt(x, y);
                prev_quad_ctrl = c0;
                prev_cubic_ctrl = null;
                cur = .{ x, y };
                cmd = c;
            },
            'z' => {
                r.verb(4);
                cur = start;
                prev_cubic_ctrl = null;
                prev_quad_ctrl = null;
                cmd = c;
            },
            else => @compileError("icon path: unsupported command (M/L/H/V/C/S/Q/T/Z only)"),
        }
    }
    return r;
}

fn GlyphData(comptime nv: usize, comptime np: usize) type {
    return struct { verbs: [nv]i32, pts: [np]f32 };
}

fn shrink(comptime r: RawGlyph) GlyphData(r.nv, r.np) {
    var out: GlyphData(r.nv, r.np) = undefined;
    @memcpy(&out.verbs, r.verbs[0..r.nv]);
    @memcpy(&out.pts, r.pts[0..r.np]);
    return out;
}

/// Parse `d` at comptime, returning slices into the static (per-`d`)
/// result — each distinct path string is one instantiation.
fn glyph(comptime d: []const u8) Glyph {
    const Static = struct {
        const data = shrink(parseRaw(d));
    };
    return .{ .verbs = &Static.data.verbs, .pts = &Static.data.pts };
}

/// The glyph table — canonical Material Symbols (filled) path data on the
/// 24dp grid. `triangle_*` map to Material's disclosure triangles
/// (arrow_left/arrow_right/arrow_drop_up/arrow_drop_down); `square` is the
/// outlined rounded square (check_box_outline_blank); the rest carry their
/// namesake glyph.
fn glyphFor(name: IconName) Glyph {
    return switch (name) {
        .play => glyph("M8 5v14l11-7z"),
        .pause => glyph("M6 19h4V5H6v14zm8-14v14h4V5h-4z"),
        .stop => glyph("M6 6h12v12H6z"),
        .circle => glyph("M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2z"),
        .square => glyph("M19 5v14H5V5h14zm0-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2z"),
        .triangle_right => glyph("M10 17l5-5-5-5v10z"),
        .triangle_left => glyph("M14 7l-5 5 5 5V7z"),
        .triangle_up => glyph("M7 14l5-5 5 5z"),
        .triangle_down => glyph("M7 10l5 5 5-5z"),
        .arrow_right => glyph("M12 4l-1.41 1.41L16.17 11H4v2h12.17l-5.58 5.59L12 20l8-8-8-8z"),
        .arrow_left => glyph("M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"),
        .arrow_up => glyph("M4 12l1.41 1.41L11 7.83V20h2V7.83l5.58 5.59L20 12l-8-8-8 8z"),
        .arrow_down => glyph("M20 12l-1.41-1.41L13 16.17V4h-2v12.17l-5.58-5.59L4 12l8 8 8-8z"),
        .chevron_right => glyph("M10 6L8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z"),
        .chevron_left => glyph("M15.41 7.41L14 6l-6 6 6 6 1.41-1.41L8.83 12z"),
        .check => glyph("M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"),
        .close => glyph("M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"),
        .menu => glyph("M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z"),
        .search => glyph("M15.5 14h-.79l-.28-.27C15.41 12.59 16 11.11 16 9.5 16 5.91 13.09 3 9.5 3S3 5.91 3 9.5 5.91 16 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"),
        .star => glyph("M12 17.27L18.18 21l-1.64-7.03L22 9.24l-7.19-.61L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21z"),
        .heart => glyph("M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"),
        .plus => glyph("M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"),
        .minus => glyph("M19 13H5v-2h14v2z"),
        .home => glyph("M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z"),
        .music_note => glyph("M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z"),
        .movie => glyph("M18 4l2 4h-3l-2-4h-2l2 4h-3l-2-4H8l2 4H7L5 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V4h-4z"),
        .library_books => glyph("M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-1 9H9V9h10v2zm-4 4H9v-2h6v2zm4-8H9V5h10v2z"),
        .history => glyph("M13 3c-4.97 0-9 4.03-9 9H1l3.89 3.89.07.14L9 12H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.94-2.06l-1.42 1.42C8.27 19.99 10.51 21 13 21c4.97 0 9-4.03 9-9s-4.03-9-9-9zm-1 5v5l4.28 2.54.72-1.21-3.5-2.08V8H12z"),
        .north_west => glyph("M5 15h2V8.41L18.59 20 20 18.59 8.41 7H15V5H5v10z"),
    };
}

/// The widest glyph point stream — the stack buffer a paint scales into.
const max_glyph_pts = blk: {
    var m: usize = 0;
    for (std.enums.values(IconName)) |n| m = @max(m, glyphFor(n).pts.len);
    break :blk m;
};

/// The icon's vector geometry — the pre-cache paint body.
fn drawIconGeometry(ctx: *kx.Ctx, name: IconName, ox: f32, oy: f32, k: f32, color: Color) void {
    const g = glyphFor(name);
    var pts: [max_glyph_pts]f32 = undefined;
    for (g.pts, 0..) |p, i| {
        pts[i] = (if (i % 2 == 0) ox else oy) + p * k;
    }
    // Material path data is authored for the nonzero (winding) fill rule.
    ui.paint.fillPath(ctx, pts[0..g.pts.len], g.verbs, color, false);
}

fn iconDeinit(n: *Node) void {
    n.allocator.destroy(@as(*IconState, @ptrCast(@alignCast(n.state.?))));
}
const icon_vtable = ui.node.VTable{ .measure = iconMeasure, .layout = iconLayout, .paint = iconPaint, .deinit = iconDeinit, .measure_pure = true };

pub fn icon(allocator: std.mem.Allocator, name: IconName, opts: IconOptions) !*Node {
    const node = try Node.create(allocator, &icon_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(IconState);
    errdefer allocator.destroy(s);
    s.* = .{ .name = name, .opts = opts };
    node.state = s;
    ui.semantics.attach(node, .{ .role = .image, .label = opts.label }); // Phase 2c
    return node;
}

/// Recolor a live icon (signal-driven widgets recolor their icon on state
/// change — e.g. the M3E icon toggle button's checked state).
pub fn setColor(n: *Node, color: Color) void {
    const s: *IconState = @ptrCast(@alignCast(n.state.?));
    s.opts.color = color;
    n.markDirty();
}

// --- tests ---

test "icon codepoints are stable (golden data)" {
    try std.testing.expectEqual(@as(u21, 0x25CF), codepoint(.circle));
    try std.testing.expectEqual(@as(u21, 0x25A1), codepoint(.square));
    try std.testing.expectEqual(@as(u21, 0x2192), codepoint(.arrow_right));
    try std.testing.expectEqual(@as(u21, 0x2713), codepoint(.check));
}

test "icon measures a square of its size" {
    const ic = try icon(std.testing.allocator, .star, .{ .size = 32 });
    defer ic.deinit();
    const size = ic.measure(.{});
    try std.testing.expectEqual(@as(f32, 32), size.w);
    try std.testing.expectEqual(@as(f32, 32), size.h);
}

test "golden: every built-in glyph paints ink (path data parses + fills)" {
    const bg = 0x00000000; // transparent — any filled pixel counts
    for (std.enums.values(IconName)) |name| {
        const ic = try icon(std.testing.allocator, name, .{ .size = 24, .color = 0xFFFFFFFF });
        var frame = try golden.render(std.testing.allocator, ic, 32, 32, bg);
        defer frame.deinit();
        // golden.render owns the tree (it deinits the root); the smallest
        // glyphs (minus, the disclosure triangles) still cover ~25 px.
        try std.testing.expect(frame.countNot(bg) > 10);
    }
}

test "golden: icon renders ink centered in its bounds" {
    const bg = 0x101010FF;
    const white = 0xFFFFFFFF;
    const root = try icon(std.testing.allocator, .circle, .{ .size = 24, .color = white });
    var frame = try golden.render(std.testing.allocator, root, 64, 64, bg);
    defer frame.deinit();
    // ● (U+25CF) is covered by DejaVu/system fonts: ink must be present,
    // roughly centered in the 64x64 canvas.
    const ink = frame.countNotIn(.{ .x = 16, .y = 16, .w = 32, .h = 32 }, bg);
    try std.testing.expect(ink > 0);
    try std.testing.expectEqual(@as(u64, 0), frame.countNotIn(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, bg));
}
