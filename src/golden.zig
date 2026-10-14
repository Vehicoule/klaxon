// Golden — offscreen rendering + pixel assertions for widget tests (Phase 1b).
// Renders through the raster backend: no window, no GPU, hermetic on CI.
// The same helper will drive the gallery (Phase 1g) and the conformance
// suite (Phase 4c).
//
// Golden rule: assert STRUCTURAL properties — exact pixel counts for solid
// rects, presence/absence of a color for text and icons (glyph shapes are
// font-dependent and differ per platform). Never assert glyph bitmaps.
const std = @import("std");
const kx = @import("kx.zig");
const sdl = @import("sdl.zig");
const ui = @import("ui.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Color = ui.paint.Color;

/// One rendered frame's pixels (RGBA memory order). Pixels only — no ctx, no
/// tree: use Renderer for interactive (multi-frame) scenarios.
pub const Frame = struct {
    pixels: []u8, // RGBA memory order (R,G,B,A), w*h*4
    w: i32,
    h: i32,
    allocator: std.mem.Allocator,

    pub fn deinit(f: *Frame) void {
        f.allocator.free(f.pixels);
    }

    /// Pixel as 0xRRGGBBAA (matches ui.paint.Color). Out-of-frame probes
    /// return transparent black — layout-derived probe rects can extend
    /// past the framebuffer edge (widget paint bounds vs frame size).
    pub fn pixelAt(f: Frame, x: i32, y: i32) Color {
        if (x < 0 or y < 0 or x >= f.w or y >= f.h) return 0;
        const i = (@as(usize, @intCast(y)) * @as(usize, @intCast(f.w)) + @as(usize, @intCast(x))) * 4;
        return @as(u32, f.pixels[i]) << 24 |
            @as(u32, f.pixels[i + 1]) << 16 |
            @as(u32, f.pixels[i + 2]) << 8 |
            @as(u32, f.pixels[i + 3]);
    }

    /// Count pixels exactly equal to `color` in the whole frame.
    pub fn countColor(f: Frame, color: Color) u64 {
        const r: u8 = @intCast((color >> 24) & 0xFF);
        const g: u8 = @intCast((color >> 16) & 0xFF);
        const b: u8 = @intCast((color >> 8) & 0xFF);
        const a: u8 = @intCast(color & 0xFF);
        var n: u64 = 0;
        var i: usize = 0;
        while (i < f.pixels.len) : (i += 4) {
            if (f.pixels[i] == r and f.pixels[i + 1] == g and f.pixels[i + 2] == b and f.pixels[i + 3] == a) n += 1;
        }
        return n;
    }

    /// Count pixels different from `color` in the whole frame (text/icons: AA
    /// blends count as "not background").
    pub fn countNot(f: Frame, color: Color) u64 {
        const total: u64 = @intCast(f.pixels.len / 4);
        return total - f.countColor(color);
    }

    /// Rect clipped to the frame (integer bounds).
    fn clipToFrame(f: Frame, rect: Rect) Rect {
        const x0 = @max(0, @as(i32, @intFromFloat(rect.x)));
        const y0 = @max(0, @as(i32, @intFromFloat(rect.y)));
        const x1 = @min(f.w, @as(i32, @intFromFloat(rect.x + rect.w)));
        const y1 = @min(f.h, @as(i32, @intFromFloat(rect.y + rect.h)));
        return .{
            .x = @floatFromInt(x0),
            .y = @floatFromInt(y0),
            .w = @floatFromInt(@max(0, x1 - x0)),
            .h = @floatFromInt(@max(0, y1 - y0)),
        };
    }

    /// Count pixels exactly equal to `color` inside a rect (clipped to frame).
    pub fn countColorIn(f: Frame, rect: Rect, color: Color) u64 {
        const r = f.clipToFrame(rect);
        var n: u64 = 0;
        var y = @as(i32, @intFromFloat(r.y));
        while (y < @as(i32, @intFromFloat(r.y + r.h))) : (y += 1) {
            var x = @as(i32, @intFromFloat(r.x));
            while (x < @as(i32, @intFromFloat(r.x + r.w))) : (x += 1) {
                if (f.pixelAt(x, y) == color) n += 1;
            }
        }
        return n;
    }

    /// Count pixels different from `color` inside a rect (clipped to frame).
    pub fn countNotIn(f: Frame, rect: Rect, color: Color) u64 {
        const r = f.clipToFrame(rect);
        const w: u64 = @intCast(@as(i32, @intFromFloat(r.w)));
        const h: u64 = @intCast(@as(i32, @intFromFloat(r.h)));
        return w * h - f.countColorIn(rect, color);
    }

    /// Count pixels within ±2 per channel of `color` inside a rect (clipped
    /// to frame) — the raster's integer rounding of translucent blends makes
    /// exact matches unreliable over a translucent container.
    pub fn countColorApproxIn(f: Frame, rect: Rect, color: Color) u64 {
        const r = f.clipToFrame(rect);
        var n: u64 = 0;
        var y = @as(i32, @intFromFloat(r.y));
        while (y < @as(i32, @intFromFloat(r.y + r.h))) : (y += 1) {
            var x = @as(i32, @intFromFloat(r.x));
            while (x < @as(i32, @intFromFloat(r.x + r.w))) : (x += 1) {
                const c = f.pixelAt(x, y);
                if (channelDiff(c, color, 24) <= 2 and channelDiff(c, color, 16) <= 2 and channelDiff(c, color, 8) <= 2) n += 1;
            }
        }
        return n;
    }
};

/// Offscreen raster renderer — owns the kx ctx. For interactive golden tests:
/// lay out the tree, dispatch input events between frames, read back pixels.
/// The tree is NOT owned: destroy it before the Renderer (widgets may hold
/// ctx-bound GPU resources — destroying the ctx first is a use-after-free).
pub const Renderer = struct {
    ctx: *kx.Ctx,
    w: i32,
    h: i32,
    allocator: std.mem.Allocator,
    /// True while the ctx was created by `init`/`initWithCtx` — deinit
    /// destroys it. The windowed bench shares one SDL window across scenes
    /// but each scene still owns its ctx, so this stays true there too.
    owns_ctx: bool = true,
    /// The raster surface keeps its pixels between frames (damage-clip
    /// repaints are valid). GPU backends acquire a fresh drawable per frame
    /// — the previous pixels are gone, so damage repaints would drop
    /// content: those renderers always full-repaint (the host makes the
    /// same backend check per frame).
    retained_surface: bool = true,
    /// Set by paint/paintDamage: ns spent inside kx_begin_frame + kx_end_frame.
    /// On a vsync-paced GPU backend these are the presentation backpressure:
    /// Metal blocks in nextDrawable (begin), GLES blocks in eglSwapBuffers
    /// (end). Bench callers subtract it from frame work; raster → ~0.
    last_frame_wait_ns: u64 = 0,
    /// True once a frame has actually been painted on this surface. Gates
    /// the paintDamage no-op (a never-painted surface must render even a
    /// "clean" tree — the very first frame) AND the damage-clip path: on a
    /// fresh surface the pixels outside the damage region are undefined, so
    /// the first frame is always a full repaint. Cleared by resize() — the
    /// resized surface's contents are garbage.
    painted: bool = false,
    /// Frames that actually presented (paintDamage took the paint path) —
    /// the windowed bench derives presented_fps from this, not the total
    /// frame count (clean frames no-op without touching the swapchain).
    frames_presented: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, w: i32, h: i32) !Renderer {
        const ctx = kx.create(null, w, h, kx.c.KX_BACKEND_RASTER) orelse return error.KxCreateFailed;
        return .{ .ctx = ctx, .w = w, .h = h, .allocator = allocator };
    }

    /// Wrap an existing ctx (the caller's backend choice — a windowed GPU
    /// ctx for the tier-2 bench). The Renderer still owns the ctx.
    pub fn initWithCtx(allocator: std.mem.Allocator, ctx: *kx.Ctx, w: i32, h: i32) Renderer {
        return .{
            .ctx = ctx,
            .w = w,
            .h = h,
            .allocator = allocator,
            .retained_surface = kx.c.kx_backend_of(ctx) == kx.c.KX_BACKEND_RASTER,
        };
    }

    pub fn deinit(r: *Renderer) void {
        if (r.owns_ctx) kx.c.kx_destroy(r.ctx);
    }

    /// Resize the surface (and the tracked size — paint culls against it).
    /// The resized surface's pixels are undefined: the next paintDamage is
    /// a full repaint regardless of any stale damage accumulator.
    pub fn resize(r: *Renderer, w: i32, h: i32) void {
        kx.c.kx_resize(r.ctx, w, h);
        r.w = w;
        r.h = h;
        r.painted = false;
    }

    /// Frame begin/end split out so paced (vsync) drivers can measure the
    /// presentation wait separately — see last_frame_wait_ns.
    pub fn beginFrame(r: *Renderer) void {
        const t0 = sdl.c.SDL_GetTicksNS();
        kx.c.kx_begin_frame(r.ctx);
        r.last_frame_wait_ns = sdl.c.SDL_GetTicksNS() - t0;
    }

    pub fn endFrame(r: *Renderer) void {
        const t0 = sdl.c.SDL_GetTicksNS();
        kx.c.kx_end_frame(r.ctx);
        r.last_frame_wait_ns += sdl.c.SDL_GetTicksNS() - t0;
    }

    /// Paint one frame of `root` on a cleared `bg`.
    pub fn paint(r: *Renderer, root: *Node, bg: Color) void {
        r.beginFrame();
        root.clearDamage(); // a full repaint consumes the accumulated damage
        kx.c.kx_clear(r.ctx, bg);
        // Full repaint: the visible region is the whole surface.
        const surface = Rect{ .x = 0, .y = 0, .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
        root.paint(r.ctx, surface);
        paintOverlayPass(root, r.ctx); // the popup overlay, above the tree (like the host)
        r.endFrame();
        r.painted = true;
    }

    /// Paint one frame exactly like the host's raster path: when the root
    /// accumulated damage, the tree repaints clipped to the damaged region
    /// (the surface is retained between frames — undamaged pixels stay);
    /// otherwise a full repaint. The damage accumulator clears BEFORE the
    /// paint so marks raised mid-paint seed the next frame's region.
    ///
    /// NO-DAMAGE NO-OP: a tree that is neither dirty, damaged, nor
    /// layout-dirty already shows its current state on the retained surface
    /// (raster) or the last presented drawable (GPU) — begin/end/present are
    /// skipped entirely. Not presenting an unchanged drawable is legal and
    /// correct on Metal and GLES; on raster it's just free. The exception:
    /// a never-painted surface (r.painted — init/resize) must render once.
    /// Callers keep their frame counting: only the GPU/paint work is elided.
    pub fn paintDamage(r: *Renderer, root: *Node, bg: Color) void {
        if (r.painted and !root.damage_valid and !root.dirty and !root.layout_dirty) {
            r.last_frame_wait_ns = 0;
            return;
        }
        r.beginFrame();
        r.paintDamageInner(root, bg);
        r.endFrame();
        r.frames_presented += 1;
    }

    /// paintDamage minus the frame begin/end — callers that pace or
    /// instrument begin/end themselves (the windowed bench measures the
    /// vsync wait inside begin) drive the pieces directly.
    pub fn paintDamageInner(r: *Renderer, root: *Node, bg: Color) void {
        const surface = Rect{ .x = 0, .y = 0, .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
        // An opaque full-coverage retained-root blit rewrites every pixel —
        // the pre-paint clear would be dead work (Qt's backingstore skips it
        // the same way for fully-opaque dirty regions).
        const skip_clear = root.retainedBlitCoversSurface(r.ctx, surface);
        // The damage-clip path needs a surface that already holds this
        // tree's pixels: r.painted excludes the first frame / post-resize
        // (pixels outside the damage would be the fresh surface's garbage).
        if (r.retained_surface and r.painted and root.damage_valid) {
            const d = ui.node.rectIntersect(root.damage, surface);
            root.clearDamage();
            if (d.w > 0 and d.h > 0) {
                kx.c.kx_clip_rect(r.ctx, d.x, d.y, d.w, d.h);
                if (!skip_clear) kx.c.kx_clear(r.ctx, bg); // SkCanvas::clear is clip-aware
                root.paint(r.ctx, d);
                paintOverlayPass(root, r.ctx);
                kx.c.kx_clip_reset(r.ctx);
            } // else: damage entirely off-surface — nothing to repaint
        } else {
            root.clearDamage(); // GPU drawable: stale damage must not leak forward
            if (!skip_clear) kx.c.kx_clear(r.ctx, bg);
            root.paint(r.ctx, surface);
            paintOverlayPass(root, r.ctx);
        }
        r.painted = true;
    }

    /// The popup overlay pass: every node with a paint_overlay hook paints
    /// after the whole tree (the host paints the open popup's hook; goldens
    /// have no router, so the hook is found by walking the tree — pruned by
    /// the overlay_subtree flag, O(1) on trees without popups).
    fn paintOverlayPass(n: *Node, ctx: *kx.Ctx) void {
        if (!n.overlay_subtree) return;
        if (n.vtable.paint_overlay) |po| po(n, ctx);
        for (n.children.items) |child| paintOverlayPass(child, ctx);
    }

    pub fn readback(r: *Renderer, allocator: std.mem.Allocator) !Frame {
        const pixels = try allocator.alloc(u8, @as(usize, @intCast(r.w)) * @as(usize, @intCast(r.h)) * 4);
        errdefer allocator.free(pixels);
        var ow: c_int = 0;
        var oh: c_int = 0;
        if (!kx.c.kx_readback_rgba(r.ctx, pixels.ptr, pixels.len, &ow, &oh)) return error.ReadbackFailed;
        return .{ .pixels = pixels, .w = r.w, .h = r.h, .allocator = allocator };
    }
};

/// Lay out `root` over a w×h canvas, paint one frame on `bg`, read it back.
/// Takes ownership of `root`: the tree is torn down BEFORE the ctx (widgets
/// may hold ctx-bound GPU resources — destroying the ctx first is a
/// use-after-free).
pub fn render(allocator: std.mem.Allocator, root: *Node, w: i32, h: i32, bg: Color) !Frame {
    var r = try Renderer.init(allocator, w, h);
    defer r.deinit();
    defer root.deinit(); // defer LIFO: the tree dies before the ctx
    root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) });
    r.paint(root, bg);
    return r.readback(allocator);
}

// --- Test leaf: a solid rect (exact pixels at integer bounds) ---

const BoxState = struct {
    w: f32,
    h: f32,
    color: Color,
};

fn boxMeasure(n: *Node, c: ui.layout.Constraints) ui.layout.Size {
    const s: *BoxState = @ptrCast(@alignCast(n.state.?));
    return c.constrain(.{ .w = s.w, .h = s.h });
}
fn boxLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn boxPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *BoxState = @ptrCast(@alignCast(n.state.?));
    ui.paint.fillRect(ctx, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h, s.color);
}
fn boxDeinit(n: *Node) void {
    n.allocator.destroy(@as(*BoxState, @ptrCast(@alignCast(n.state.?))));
}
const box_vtable = ui.node.VTable{ .measure = boxMeasure, .layout = boxLayout, .paint = boxPaint, .deinit = boxDeinit };

pub fn solidBox(allocator: std.mem.Allocator, w: f32, h: f32, color: Color) !*Node {
    const node = try Node.create(allocator, &box_vtable);
    const s = try allocator.create(BoxState);
    s.* = .{ .w = w, .h = h, .color = color };
    node.state = s;
    return node;
}

// --- translucent-paint helpers (state layers, disabled containers) ---

fn blendChannel(s: u32, d: u32, sa: f32) u32 {
    const v = @as(f32, @floatFromInt(s)) * (sa / 255) + @as(f32, @floatFromInt(d)) * (1 - sa / 255) + 0.5;
    return @intFromFloat(std.math.clamp(v, 0, 255));
}

/// The expected src-over blend of `src` over `dst` (both 0xRRGGBBAA).
pub fn blendOver(src: Color, dst: Color) Color {
    const sa: f32 = @floatFromInt(src & 0xFF);
    return (blendChannel((src >> 24) & 0xFF, (dst >> 24) & 0xFF, sa) << 24) |
        (blendChannel((src >> 16) & 0xFF, (dst >> 16) & 0xFF, sa) << 16) |
        (blendChannel((src >> 8) & 0xFF, (dst >> 8) & 0xFF, sa) << 8) | 0xFF;
}

pub fn channelDiff(c1: Color, c2: Color, shift: u5) i32 {
    const x: i32 = @intCast((c1 >> shift) & 0xFF);
    const y: i32 = @intCast((c2 >> shift) & 0xFF);
    const d0 = x - y;
    return if (d0 < 0) -d0 else d0;
}

/// Assert a pixel equals `expected` within ±2 per channel (the raster's
/// integer rounding of translucent blends).
pub fn expectPixelApprox(f: Frame, x: i32, y: i32, expected: Color) !void {
    const got = f.pixelAt(x, y);
    try std.testing.expect(channelDiff(got, expected, 24) <= 2);
    try std.testing.expect(channelDiff(got, expected, 16) <= 2);
    try std.testing.expect(channelDiff(got, expected, 8) <= 2);
}

// --- tests: the no-damage no-op frame ---

const CountState = struct {
    w: f32,
    h: f32,
    color: Color,
    paints: *u32,
    /// Optional paint-time mutation target: when armed, paint marks it
    /// dirty — the damage must survive the pass (cleared BEFORE painting).
    mark_target: ?*Node = null,
    armed: bool = false,
};
fn countMeasure(n: *Node, c: ui.layout.Constraints) ui.layout.Size {
    const s: *CountState = @ptrCast(@alignCast(n.state.?));
    return c.constrain(.{ .w = s.w, .h = s.h });
}
fn countPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *CountState = @ptrCast(@alignCast(n.state.?));
    s.paints.* += 1;
    if (s.armed) {
        s.armed = false;
        if (s.mark_target) |t| t.markDirty();
    }
    ui.paint.fillRect(ctx, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h, s.color);
}
fn countDeinit(n: *Node) void {
    n.allocator.destroy(@as(*CountState, @ptrCast(@alignCast(n.state.?))));
}
const count_vtable = ui.node.VTable{ .measure = countMeasure, .layout = boxLayout, .paint = countPaint, .deinit = countDeinit };

fn countBox(allocator: std.mem.Allocator, w: f32, h: f32, color: Color, paints: *u32) !*Node {
    const node = try Node.create(allocator, &count_vtable);
    const s = try allocator.create(CountState);
    s.* = .{ .w = w, .h = h, .color = color, .paints = paints };
    node.state = s;
    return node;
}

test "paintDamage is a complete no-op on a clean tree (no repaint, no frame)" {
    var r = try Renderer.init(std.testing.allocator, 32, 32);
    defer r.deinit();
    var paints: u32 = 0;
    const root = try countBox(std.testing.allocator, 32, 32, 0xFF0000FF, &paints);
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 32, .h = 32 });
    // Frame 1 renders: the surface was never painted (r.painted == false)
    // even though layout-time damage exists.
    r.paintDamage(root, 0);
    try std.testing.expectEqual(@as(u32, 1), paints);
    // Clean frames cost nothing: no begin/end, no repaint.
    r.paintDamage(root, 0);
    r.paintDamage(root, 0);
    try std.testing.expectEqual(@as(u32, 1), paints);
    // A dirty mark produces a (clipped) repaint.
    root.markDirty();
    r.paintDamage(root, 0);
    try std.testing.expectEqual(@as(u32, 2), paints);
    // A pending layout forces a frame even without damage...
    root.markLayoutDirty();
    r.paintDamage(root, 0);
    try std.testing.expectEqual(@as(u32, 3), paints);
    // ...but once the layout pass ran (same bounds → zero new damage), the
    // tree is clean again and the next frame skips.
    root.layout(.{ .x = 0, .y = 0, .w = 32, .h = 32 });
    r.paintDamage(root, 0);
    try std.testing.expectEqual(@as(u32, 3), paints);
    // A resize invalidates the surface: the next frame must repaint even
    // though the tree is clean (fresh pixels are garbage).
    r.resize(16, 16);
    r.paintDamage(root, 0);
    try std.testing.expectEqual(@as(u32, 4), paints);
    r.paintDamage(root, 0);
    try std.testing.expectEqual(@as(u32, 4), paints);
}

test "a markDirty raised during paint seeds the next frame (pre-paint clear)" {
    var r = try Renderer.init(std.testing.allocator, 32, 32);
    defer r.deinit();
    var paints: u32 = 0;
    var other_paints: u32 = 0;
    const root = try countBox(std.testing.allocator, 32, 32, 0xFF0000FF, &paints);
    defer root.deinit();
    const other = try countBox(std.testing.allocator, 10, 10, 0x00FF00FF, &other_paints);
    root.add(other);
    root.layout(.{ .x = 0, .y = 0, .w = 32, .h = 32 });
    other.bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    (@as(*CountState, @ptrCast(@alignCast(root.state.?)))).mark_target = other;
    r.paintDamage(root, 0);
    try std.testing.expectEqual(@as(u32, 1), paints);
    try std.testing.expectEqual(@as(u32, 1), other_paints);
    // A clean frame can't even reach the armed mark — the whole pass skips.
    (@as(*CountState, @ptrCast(@alignCast(root.state.?)))).armed = true;
    r.paintDamage(root, 0);
    try std.testing.expectEqual(@as(u32, 1), paints);
    try std.testing.expect((@as(*CountState, @ptrCast(@alignCast(root.state.?)))).armed);
    // Dirty the root so a paint runs; root covers the surface, so `other`
    // repaints inside the same damage — and the in-paint mark on `other`
    // survives the (pre-paint) clear to seed ANOTHER frame.
    root.markDirty();
    r.paintDamage(root, 0);
    try std.testing.expectEqual(@as(u32, 2), paints);
    try std.testing.expectEqual(@as(u32, 2), other_paints);
    try std.testing.expect(root.dirty or other.dirty); // the in-paint mark lived
    r.paintDamage(root, 0);
    try std.testing.expectEqual(@as(u32, 3), paints);
    try std.testing.expectEqual(@as(u32, 3), other_paints);
}
