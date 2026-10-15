// Paint — drawing state for a node, emitted through the kx_skia ABI.
// Solid colors (fill/stroke), rects, rrects, text + text metrics, images.
// Path, gradients, blur land later as the widget library grows the ABI.
const std = @import("std");
const kx = @import("../kx.zig");

/// Color: 0xRRGGBBAA (R in the high byte, alpha in the low byte).
pub const Color = u32;

pub const Style = enum { fill, stroke };

pub const Paint = struct {
    color: Color = 0x000000FF, // opaque black (0xRRGGBBAA)
    style: Style = .fill,
    stroke_width: f32 = 1.0,

    pub fn fill(color: Color) Paint {
        return .{ .color = color };
    }

    pub fn stroke(color: Color, width: f32) Paint {
        return .{ .color = color, .style = .stroke, .stroke_width = width };
    }
};

// --- Emission (called from node paint with the kx context) ---

// Canvas state + transforms (Phase 1e, ABI 0.3.0). save/restore must be
// balanced within a frame; widgets wrap their children's paint in a pair.
pub fn save(ctx: *kx.Ctx) void {
    kx.c.kx_save(ctx);
}

pub fn restore(ctx: *kx.Ctx) void {
    kx.c.kx_restore(ctx);
}

pub fn translate(ctx: *kx.Ctx, dx: f32, dy: f32) void {
    kx.c.kx_translate(ctx, dx, dy);
}

pub fn scale(ctx: *kx.Ctx, sx: f32, sy: f32) void {
    kx.c.kx_scale(ctx, sx, sy);
}

/// Rotate the canvas clockwise by `degrees` around the current origin
/// (ABI 0.12.0). Pair with translate() to rotate about a point.
pub fn rotate(ctx: *kx.Ctx, degrees: f32) void {
    kx.c.kx_rotate(ctx, degrees);
}

/// Clip the current frame to a rect (save + intersect clip).
/// Balanced with clipReset (restores the canvas state).
pub fn clipRect(ctx: *kx.Ctx, x: f32, y: f32, w: f32, h: f32) void {
    kx.c.kx_clip_rect(ctx, x, y, w, h);
}

pub fn clipReset(ctx: *kx.Ctx) void {
    kx.c.kx_clip_reset(ctx);
}

/// Clip the current frame to the closed polygon through (xs, ys) (ABI
/// 0.12.0) — intersect clip, balanced with clipReset() like clipRect.
/// `aa` picks the anti-aliased mask (smooth edges, slower raster); pass
/// false for the hard scanline clip (matches Qt's default setClipPath).
/// Star masks and avatar cutouts are polygons generated in Zig.
pub fn clipPath(ctx: *kx.Ctx, xs: []const f32, ys: []const f32, aa: bool) void {
    // Mismatched arrays would make C++ read past the shorter one.
    const n = @min(xs.len, ys.len);
    std.debug.assert(n == xs.len);
    kx.c.kx_clip_path(ctx, xs.ptr, ys.ptr, @intCast(n), @intFromBool(aa));
}

/// Push an alpha layer (saveLayer with alpha, ABI 0.4.0): everything painted
/// until the matching restore() composites at `alpha` opacity — fade
/// transitions (Phase 2a) and hero dimming.
pub fn layerAlpha(ctx: *kx.Ctx, alpha: f32) void {
    kx.c.kx_layer_alpha(ctx, alpha);
}

/// Scale a color's alpha channel by `k` (0..1) — fades that preserve the
/// color's own opacity (scrollbar show/hide, Phase 2d-0.5).
pub fn withAlphaScaled(c: Color, k: f32) Color {
    if (!std.math.isFinite(k)) return c; // NaN/inf scale — keep the alpha as-is
    const r: u32 = (c >> 24) & 0xFF;
    const g: u32 = (c >> 16) & 0xFF;
    const b: u32 = (c >> 8) & 0xFF;
    const base: f32 = @floatFromInt(c & 0xFF);
    const a: u32 = @intFromFloat(std.math.clamp(base * std.math.clamp(k, 0, 1), 0, 255));
    return (r << 24) | (g << 16) | (b << 8) | a;
}

pub fn fillRect(ctx: *kx.Ctx, x: f32, y: f32, w: f32, h: f32, color: Color) void {
    kx.c.kx_fill_rect(ctx, x, y, w, h, color);
}

pub fn fillRRect(ctx: *kx.Ctx, x: f32, y: f32, w: f32, h: f32, radius: f32, color: Color) void {
    kx.c.kx_fill_rrect(ctx, x, y, w, h, radius, color);
}

/// Fill a rounded rectangle with PER-CORNER radii (ABI 0.7.0), in SkRRect
/// order: top-left, top-right, bottom-right, bottom-left.
pub fn fillRRectCorners(ctx: *kx.Ctx, x: f32, y: f32, w: f32, h: f32, tl: f32, tr: f32, br: f32, bl: f32, color: Color) void {
    kx.c.kx_fill_rrect_corners(ctx, x, y, w, h, tl, tr, br, bl, color);
}

/// Stroke a rounded rectangle's outline (ABI 0.6.0) — centered on the edge.
pub fn strokeRRect(ctx: *kx.Ctx, x: f32, y: f32, w: f32, h: f32, radius: f32, stroke_w: f32, color: Color) void {
    kx.c.kx_stroke_rrect(ctx, x, y, w, h, radius, stroke_w, color);
}

/// Stroke a rounded rectangle's outline with PER-CORNER radii (ABI 0.8.0),
/// in SkRRect order: top-left, top-right, bottom-right, bottom-left — the
/// M3E segmented/split buttons' 1dp borders on start/end/middle shapes.
pub fn strokeRRectCorners(ctx: *kx.Ctx, x: f32, y: f32, w: f32, h: f32, tl: f32, tr: f32, br: f32, bl: f32, stroke_w: f32, color: Color) void {
    kx.c.kx_stroke_rrect_corners(ctx, x, y, w, h, tl, tr, br, bl, stroke_w, color);
}

/// Stroke a polyline through (xs, ys) (ABI 0.5.0) — arcs and wavy progress
/// indicators are polylines generated in Zig; no path type crosses the ABI.
pub fn strokePolyline(ctx: *kx.Ctx, xs: []const f32, ys: []const f32, stroke_w: f32, round_cap: bool, color: Color) void {
    // Mismatched arrays would make C++ read past the shorter one.
    const n = @min(xs.len, ys.len);
    std.debug.assert(n == xs.len);
    kx.c.kx_stroke_polyline(ctx, xs.ptr, ys.ptr, @intCast(n), stroke_w, round_cap, color);
}

/// Fill a closed polygon through (xs, ys) (ABI 0.9.0) — the M3E loading
/// indicator's shapes are polygons generated in Zig; no path type crosses
/// the ABI.
pub fn fillPolygon(ctx: *kx.Ctx, xs: []const f32, ys: []const f32, color: Color) void {
    // Mismatched arrays would make C++ read past the shorter one.
    const n = @min(xs.len, ys.len);
    std.debug.assert(n == xs.len);
    kx.c.kx_fill_polygon(ctx, xs.ptr, ys.ptr, @intCast(n), color);
}

/// Fill an rrect with a linear gradient (ABI 0.10.0): 2..8 evenly-spaced
/// color stops from (x0,y0) to (x1,y1), clipped to the rounded rect. The color
/// picker's gradients (the SV square's overlays, the hue slider) are stop
/// lists generated in Zig; no shader type crosses the ABI.
pub fn fillRRectGradient(ctx: *kx.Ctx, x: f32, y: f32, w: f32, h: f32, radius: f32, x0: f32, y0: f32, x1: f32, y1: f32, colors: []const Color) void {
    kx.c.kx_fill_rrect_gradient(ctx, x, y, w, h, radius, x0, y0, x1, y1, colors.ptr, @intCast(colors.len));
}

pub fn text(ctx: *kx.Ctx, str: [:0]const u8, x: f32, baseline_y: f32, size: f32, bold: bool, color: Color) void {
    kx.c.kx_draw_text_styled(ctx, str, x, baseline_y, size, bold, color);
}

// --- Text metrics (layout-time; ctx-independent, fonts are process-global) ---

pub const TextMetrics = kx.c.kx_text_metrics;

pub fn measureText(str: [:0]const u8, size: f32, bold: bool) TextMetrics {
    return kx.c.kx_measure_text(str, size, bold);
}

// --- Multi-style shaped text (ABI 0.15.0) ---
// A Paragraph laid out once from styled spans — real rich text: per-span
// weight (100..900), italic, letter-spacing and color, with HarfBuzz
// shaping, ICU bidi + line breaking and font fallback inside the run.

pub const TextStyle = kx.c.kx_text_style;
pub const TextLayout = kx.c.kx_text_layout;

// --- Variable fonts (ABI 0.17.0) ---
// OpenType variation design coordinates on a TextStyle: a 'wght' coordinate
// overrides `weight` on variable fonts (M3E animates weight per state —
// the axis is what makes a 400→700 transition smooth rather than a jump).
// Axes absent from the resolved font are ignored.

/// One variation coordinate: an OpenType axis tag + a design-space value.
pub const FontAxis = struct { axis: u32, value: f32 };

/// Common registered axis tags (big-endian packed 4-char tags).
pub const axis_wght: u32 = axisTag("wght");
pub const axis_wdth: u32 = axisTag("wdth");
pub const axis_slnt: u32 = axisTag("slnt");
pub const axis_ital: u32 = axisTag("ital");
pub const axis_opsz: u32 = axisTag("opsz");

/// Pack a 4-char axis tag ("wght") into its big-endian u32 form.
pub fn axisTag(comptime tag: *const [4]u8) u32 {
    return std.mem.readInt(u32, tag, .big);
}

/// Maximum variation coordinates a TextStyle carries (ABI-fixed array).
pub const max_font_variations = 8;

/// Base style for a span: zero-initialized (variation_count 0) with the
/// scalar fields set. Callers add axes via `withVariations`.
pub fn textStyle(size: f32, weight: i32, slant: i32, letter_spacing: f32, color: Color) TextStyle {
    var s = std.mem.zeroes(TextStyle);
    s.size = size;
    s.weight = weight;
    s.slant = slant;
    s.letter_spacing = letter_spacing;
    s.color = color;
    return s;
}

/// Copy `axes` (clamped to the ABI capacity) into the style's variation slots.
pub fn withVariations(s: *TextStyle, axes: []const FontAxis) void {
    const n: usize = @min(axes.len, max_font_variations);
    for (axes[0..n], 0..) |a, i| {
        s.variation_axes[i] = a.axis;
        s.variation_values[i] = a.value;
    }
    s.variation_count = @intCast(n);
}

/// Font family override ("SF Compact", "New York", a PostScript name — 0 = platform
/// default). Consumed synchronously by textLayoutSpan: `family` need only
/// outlive that call. This is what makes variation axes reachable — 'wght'
/// only moves glyphs when the resolved face is variable.
pub fn withFamily(s: *TextStyle, family: ?[*:0]const u8) void {
    s.family = family;
}

/// Begin a layout. `max_width <= 0` lays out unconstrained (longest line =
/// intrinsic width). Returns null when the paragraph backend is missing.
pub fn textLayoutBegin(max_width: f32) ?*TextLayout {
    return kx.c.kx_text_layout_begin(max_width);
}

/// Push one styled span. Spans after the first metric/paint call are ignored
/// (the paragraph is already built).
pub fn textLayoutSpan(l: *TextLayout, str: [:0]const u8, style: TextStyle) void {
    kx.c.kx_text_layout_span(l, str, &style);
}

/// Longest laid-out line width — builds + lays out on first call.
pub fn textLayoutWidth(l: *TextLayout) f32 {
    return kx.c.kx_text_layout_width(l);
}
pub fn textLayoutHeight(l: *TextLayout) f32 {
    return kx.c.kx_text_layout_height(l);
}
/// First line's alphabetic baseline (distance from the paragraph's top).
pub fn textLayoutBaseline(l: *TextLayout) f32 {
    return kx.c.kx_text_layout_baseline(l);
}
/// Paint; `baseline_y` is the first-line BASELINE — same convention as text().
pub fn textLayoutPaint(ctx: *kx.Ctx, l: *const TextLayout, x: f32, baseline_y: f32) void {
    kx.c.kx_text_paint_layout(ctx, l, x, baseline_y);
}
pub fn textLayoutDestroy(l: *TextLayout) void {
    kx.c.kx_text_layout_destroy(l);
}

// --- Images (per-ctx registry; create once, draw many) ---

pub fn imageCreate(ctx: *kx.Ctx, rgba: [*]const u8, w: i32, h: i32) u64 {
    return kx.c.kx_image_create(ctx, rgba, w, h);
}

pub fn imageDestroy(ctx: *kx.Ctx, id: u64) void {
    kx.c.kx_image_destroy(ctx, id);
}

pub fn imageDraw(ctx: *kx.Ctx, id: u64, x: f32, y: f32, w: f32, h: f32) void {
    kx.c.kx_draw_image(ctx, id, x, y, w, h);
}

/// Batched sprite draw (ABI 0.18.0): one submission for N sprites of the
/// same image — SkCanvas::drawAtlas underneath (QSG's quad-batch idiom).
/// xforms map the image rect: rotate+scale columns [scos,ssin], then
/// translate. Plain blit at (x,y) size w×h of an iw×ih image:
/// { .scos = w/iw, .ssin = 0, .tx = x, .ty = y }.
pub const SpriteXform = extern struct { scos: f32, ssin: f32, tx: f32, ty: f32 };

pub fn imageDrawAtlas(ctx: *kx.Ctx, id: u64, xforms: []const SpriteXform) void {
    if (xforms.len == 0) return;
    kx.c.kx_draw_image_atlas(ctx, id, @ptrCast(xforms.ptr), null, @intCast(xforms.len));
}

/// Batched distinct-image draw (ABI 0.18.0): one submission for N quads
/// that may each sample a different registered image (retained-row scroll).
/// (No Zig wrapper — the C++ op-replay path calls kx_draw_image_set
/// directly; kx_image_quad is the wire type.)
pub const ImageQuad = extern struct {
    image: u64,
    sx: f32, sy: f32, sw: f32, sh: f32, // source rect (sw/sh <= 0 = full image)
    dx: f32, dy: f32, dw: f32, dh: f32, // destination rect
};

// --- Row atlas + sprite batch (ABI 0.18.0) ---
// Retained subtrees rasterize straight into slots of ONE shared texture —
// no per-row texture alloc/upload (the dominant Graphite scroll cost) — and
// blit by sampling their rect; an open sprite batch merges them into one
// drawVertices submission.

/// Begin painting into a fresh atlas slot ≥ w×h. On success returns the
/// slot rect via `out` (x,y,w,h); paint in local space, then atlasEnd.
/// False when nested/full — caller falls back to the image path.
pub fn atlasBegin(ctx: *kx.Ctx, w: i32, h: i32, out: *[4]f32) bool {
    return kx.c.kx_atlas_begin(ctx, w, h, @ptrCast(out));
}
pub fn atlasEnd(ctx: *kx.Ctx) void {
    kx.c.kx_atlas_end(ctx);
}
/// The shared atlas texture's registry id (0 until the first pass ends).
pub fn atlasImage(ctx: *kx.Ctx) u64 {
    return kx.c.kx_atlas_image(ctx);
}
/// Return a slot to its shelf when the retained row is evicted.
pub fn atlasFree(ctx: *kx.Ctx, slot: [4]f32) void {
    kx.c.kx_atlas_free(ctx, slot[0], slot[1], slot[2], slot[3]);
}
/// Atlas generation — bumps on every recreate, so a cached slot is stale
/// when the current gen differs (the texture it was written into is gone).
pub fn atlasGen(ctx: *kx.Ctx) u32 {
    return kx.c.kx_atlas_gen(ctx);
}
/// True only while the ATLAS write pass owns the canvas — atlas-slot blits
/// there would self-sample the texture being written (illegal on GPU). An
/// offscreen pass may still blit atlas slots: different surfaces.
pub fn inAtlasPass(ctx: *kx.Ctx) bool {
    return kx.c.kx_in_atlas_pass(ctx) != 0;
}
/// Process-unique ctx id — a freed ctx's address is recycled, so caches
/// must key on the serial, never the pointer.
pub fn ctxSerial(ctx: *kx.Ctx) u64 {
    return kx.c.kx_ctx_serial(ctx);
}
/// True while the ctx owning `serial` is still alive — entries for a dead
/// ctx are dropped (its teardown freed their resources), never freed twice.
pub fn ctxSerialAlive(serial: u64) bool {
    return kx.c.kx_ctx_serial_alive(serial) != 0;
}
/// Blit a sub-rect of an image to a dst rect (atlas slots included).
pub fn imageDrawRegion(ctx: *kx.Ctx, id: u64, sx: f32, sy: f32, sw: f32, sh: f32, dx: f32, dy: f32, dw: f32, dh: f32) void {
    kx.c.kx_draw_image_region(ctx, id, sx, sy, sw, sh, dx, dy, dw, dh);
}
/// imageDrawRegion under an rgba tint — the mesh carries it per-sprite,
/// so opacity-animated atlas blits never re-raster (QSG opacity idiom).
pub fn imageDrawRegionTinted(ctx: *kx.Ctx, id: u64, sx: f32, sy: f32, sw: f32, sh: f32, dx: f32, dy: f32, dw: f32, dh: f32, rgba: u32) void {
    kx.c.kx_draw_image_region_tinted(ctx, id, sx, sy, sw, sh, dx, dy, dw, dh, rgba);
}
/// Bracket a children pass: atlas blits inside accumulate into ONE
/// drawVertices (GPU only — no-op on raster/while recording layers).
pub fn spriteBatchBegin(ctx: *kx.Ctx) void {
    kx.c.kx_sprite_batch_begin(ctx);
}
pub fn spriteBatchEnd(ctx: *kx.Ctx) void {
    kx.c.kx_sprite_batch_end(ctx);
}

/// True when every pixel of the image is fully opaque (ABI 0.13.0) — a
/// full-coverage opaque blit lets the caller skip the destination clear.
pub fn imageIsOpaque(ctx: *kx.Ctx, id: u64) bool {
    return kx.c.kx_image_is_opaque(ctx, id) != 0;
}

/// Zero-copy draw (ABI 0.12.0): draw raw RGBA pixels into the rect without
/// the registry round-trip — the buffer is borrowed for the synchronous
/// draw (video texture-upload idiom: decoded frames are drawn, not kept).
pub fn drawPixels(ctx: *kx.Ctx, rgba: [*]const u8, w: i32, h: i32, x: f32, y: f32, dw: f32, dh: f32) void {
    kx.c.kx_draw_pixels(ctx, rgba, w, h, x, y, dw, dh);
}

/// Render-to-image (ABI 0.12.0): offscreenBegin switches the ctx's draw
/// target to a fresh w×h transparent raster surface; everything drawn until
/// offscreenEndImage lands there and registers like an imageCreate image.
/// The retained-cache idiom: rasterize a stable subtree once, blit it while
/// it stays clean (Compose's graphicsLayer / QML layer.enabled). Passes are
/// stackable — an offscreen regen may contain nested offscreen/atlas
/// writes (the C++ keeps a per-depth surface pool).
pub fn offscreenBegin(ctx: *kx.Ctx, w: i32, h: i32) bool {
    return kx.c.kx_offscreen_begin(ctx, w, h);
}

// --- Real primitives (ABI 0.16.0) ---

/// Push a content-blur layer: draws until layerClose() rasterize once and
/// composite through a Gaussian image filter — real glass blur, not an
/// alpha stand-in. Balanced by the same layerClose as layerAlpha.
/// (kx_layer_blur is also emitted by the C++ op-replay for recorded blur
/// layers.)
pub fn layerBlur(ctx: *kx.Ctx, sigma: f32) void {
    kx.c.kx_layer_blur(ctx, sigma);
}

/// Blur what's already painted within the rect (the backdrop filter path —
/// the glass-over-content primitive).
pub fn backdropBlur(ctx: *kx.Ctx, x: f32, y: f32, w: f32, h: f32, sigma: f32) void {
    kx.c.kx_backdrop_blur(ctx, x, y, w, h, sigma);
}

/// Material elevation shadow (SkShadowUtils ambient+spot, M3 key light).
/// `transparent_occluder` for glass/translucent fills.
pub fn shadowRRect(ctx: *kx.Ctx, x: f32, y: f32, w: f32, h: f32, radius: f32, elevation: f32, ambient: Color, spot: Color, transparent_occluder: bool) void {
    kx.c.kx_shadow_rrect(ctx, x, y, w, h, radius, elevation, ambient, spot, @intFromBool(transparent_occluder));
}

/// Path verbs for fillPath/strokePath — pts consumed per verb.
pub const PathVerb = enum(i32) { move = 0, line = 1, quad = 2, cubic = 3, close = 4 };

/// Fill an arbitrary path (verbs: move/line/quad/cubic/close). fill_rule:
/// 0 winding, 1 even-odd.
pub fn fillPath(ctx: *kx.Ctx, pts: []const f32, verbs: []const i32, color: Color, fill_rule: bool) void {
    kx.c.kx_fill_path(ctx, pts.ptr, verbs.ptr, @intCast(verbs.len), color, @intFromBool(fill_rule));
}
/// Stroke an arbitrary path.
pub fn strokePath(ctx: *kx.Ctx, pts: []const f32, verbs: []const i32, stroke_w: f32, color: Color, fill_rule: bool) void {
    kx.c.kx_stroke_path(ctx, pts.ptr, verbs.ptr, @intCast(verbs.len), stroke_w, color, @intFromBool(fill_rule));
}

pub fn offscreenEndImage(ctx: *kx.Ctx) u64 {
    return kx.c.kx_offscreen_end_image(ctx);
}

// --- tests ---

test "kx ABI version reports 0.18.0 (atlas + sprite batch)" {
    try std.testing.expectEqualStrings("0.18.0", std.mem.span(kx.c.kx_abi_version()));
}

test "shaped text paints ink inside the measured box" {
    const golden = @import("../golden.zig");
    var r = try golden.Renderer.init(std.testing.allocator, 200, 100);
    defer r.deinit();
    // Reproduce the widget path: measure first (cache miss builds the
    // paragraph), then draw hits the SAME cached entry.
    _ = kx.c.kx_measure_text("AB", 22.4, true);
    r.beginFrame();
    kx.c.kx_clear(r.ctx, 0xFFFFFFFF);
    kx.c.kx_draw_text_styled(r.ctx, "AB", 20, 60, 22.4, true, 0x21005DFF);
    r.endFrame();
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try std.testing.expect(f.countColorIn(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, 0x21005DFF) > 0);
}

test "cached paragraph recolors across draws (white then dark)" {
    const golden = @import("../golden.zig");
    var r = try golden.Renderer.init(std.testing.allocator, 100, 80);
    defer r.deinit();
    r.beginFrame();
    kx.c.kx_clear(r.ctx, 0xFF00FFFF);
    // First draw in WHITE on a colored bg — an earlier user of the cached
    // paragraph must not pin its foreground (the PaintID indirection).
    kx.c.kx_draw_text_styled(r.ctx, "AB", 10, 40, 22.4, true, 0xFFFFFFFF);
    kx.c.kx_draw_text_styled(r.ctx, "AB", 10, 70, 22.4, true, 0x21005DFF);
    r.endFrame();
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try std.testing.expect(f.countColorIn(.{ .x = 0, .y = 15, .w = 100, .h = 30 }, 0xFFFFFFFF) > 0);
    try std.testing.expect(f.countColorIn(.{ .x = 0, .y = 50, .w = 100, .h = 30 }, 0x21005DFF) > 0);
}

test "backdrop_blur large-sigma path produces a true blur, not shifted content" {
    const golden = @import("../golden.zig");
    var r = try golden.Renderer.init(std.testing.allocator, 200, 120);
    defer r.deinit();
    r.beginFrame();
    // Sharp boundary the blur must smear: black top half, white bottom.
    kx.c.kx_clear(r.ctx, 0xFFFFFFFF);
    kx.c.kx_fill_rect(r.ctx, 0, 0, 200, 60, 0x000000FF);
    // sigma=12 over a 200x60 band engages the half-res chain — a wrong
    // transform would leave sharp or misplaced pixels.
    kx.c.kx_backdrop_blur(r.ctx, 0, 30, 200, 60, 12.0);
    r.endFrame();
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const chan = struct {
        fn r_(c: u32) u8 {
            return @intCast((c >> 24) & 0xFF);
        }
    }.r_;
    // Outside the band: untouched (black above y=30 is composited-away? —
    // no: the band only rewrites [30,90) — y=10 stays pure black).
    try std.testing.expectEqual(@as(u8, 0), chan(f.pixelAt(100, 10)));
    try std.testing.expectEqual(@as(u8, 255), chan(f.pixelAt(100, 100)));
    // Deep inside the black zone of the band: still dark.
    try std.testing.expect(chan(f.pixelAt(100, 40)) < 80);
    // Just below the boundary: white blurred toward black — light grey.
    const below = chan(f.pixelAt(100, 75));
    try std.testing.expect(below > 100 and below < 255);
    // At the boundary: a real smear — mid grey, neither pure black nor white.
    const mid = chan(f.pixelAt(100, 60));
    try std.testing.expect(mid > 40 and mid < 220);
}

test "CJK + Arabic resolve through font fallback (nonzero ink + real advances)" {
    const golden = @import("../golden.zig");
    var r = try golden.Renderer.init(std.testing.allocator, 400, 80);
    defer r.deinit();
    r.beginFrame();
    kx.c.kx_clear(r.ctx, 0xFFFFFFFF);
    kx.c.kx_draw_text(r.ctx, "你好世界", 10, 40, 20, 0x000000FF);
    kx.c.kx_draw_text(r.ctx, "مرحبا", 200, 40, 20, 0x000000FF);
    r.endFrame();
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const mc = kx.c.kx_measure_text("你好世界", 20, false);
    const ma = kx.c.kx_measure_text("مرحبا", 20, false);
    // Both scripts produce real shaped advances and ink on the surface.
    try std.testing.expect(mc.width > 30); // 4 CJK glyphs ≈ 4×20px
    try std.testing.expect(ma.width > 20);
    try std.testing.expect(f.countNotIn(.{ .x = 0, .y = 0, .w = 400, .h = 80 }, 0xFFFFFFFF) > 0);
    // Shaped Arabic is NARROWER than its codepoint count × advance — the
    // contextual ligature/combining actually ran (5 codepoints ≪ 100px).
    try std.testing.expect(ma.width < 100);
}

test "paint constructors: fill keeps the defaults, stroke carries color + width" {
    const f = Paint.fill(0x11223344);
    try std.testing.expectEqual(@as(Color, 0x11223344), f.color);
    try std.testing.expectEqual(Style.fill, f.style);
    try std.testing.expectEqual(@as(f32, 1.0), f.stroke_width); // the default
    const s = Paint.stroke(0xFF0000FF, 2.5);
    try std.testing.expectEqual(@as(Color, 0xFF0000FF), s.color);
    try std.testing.expectEqual(Style.stroke, s.style);
    try std.testing.expectEqual(@as(f32, 2.5), s.stroke_width);
}

test "withAlphaScaled scales only the alpha channel and clamps k to [0, 1]" {
    const c: Color = 0x11223480; // alpha 128
    // k = 1 → unchanged; k = 0 → fully transparent; RGB preserved throughout
    try std.testing.expectEqual(@as(Color, 0x11223480), withAlphaScaled(c, 1));
    try std.testing.expectEqual(@as(Color, 0x11223400), withAlphaScaled(c, 0));
    try std.testing.expectEqual(@as(Color, 0x11223440), withAlphaScaled(c, 0.5)); // 128 * 0.5 = 64
    // k outside [0, 1] clamps (a fade factor is never negative or > 1)
    try std.testing.expectEqual(@as(Color, 0x11223480), withAlphaScaled(c, 2));
    try std.testing.expectEqual(@as(Color, 0x11223400), withAlphaScaled(c, -1));
    // an opaque color scaled to 0.5 truncates (255 * 0.5 = 127.5 → 127)
    try std.testing.expectEqual(@as(Color, 0xA0B0C07F), withAlphaScaled(0xA0B0C0FF, 0.5));
}
