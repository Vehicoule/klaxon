// LoadingIndicator (Phase 2d.4 PR #32, M3E) — the Material 3 Expressive
// shape-morphing loading indicator: an indeterminate morph loop and a
// determinate progress variant, plain + contained.
//
// Spec: Compose LoadingIndicator.kt + LoadingIndicatorTokens:
//   - container 48x48 (ContainerWidth/Height), CornerFull; the contained
//     variant fills it PrimaryContainer with an OnPrimaryContainer
//     indicator; the plain variant is transparent with a Primary indicator
//   - the indicator is 38dp (ActiveSize), scaled 38/48 within the container
//   - indeterminate: morphs between 7 shapes every 650ms
//     (MorphIntervalMillis), +90° of shape rotation per morph, plus a
//     continuous global rotation (360° per 4666ms, GlobalRotationDuration-
//     Millis, linear)
//   - determinate: morphs Circle -> SoftBurst with progress (0..1), rotating
//     -180° over the full range
//
// The widget is a LEAF: it paints its container + the current morph frame.
// The M3E shapes are ui.shapes RoundedPolygon presets (the real androidx
// SoftBurst/Cookie9Sided/Pentagon/Pill/Sunny/Cookie4Sided/Oval geometry —
// rounded corners, vertex normalization), interpolated by Morph: the matched
// cubics at progress t are emitted as a verb path (move + N×cubic + close)
// and filled through kx_fill_path (ABI 0.16.0). The polygons + pairwise
// morphs are built once per widget; per-frame emission reuses preallocated
// scratch, so paint allocates nothing.
//
// Remaining deviation (documented): the indeterminate morph tween is LINEAR
// — the M3E morph spring is a follow-up (asCubics extrapolates past t=1, so
// the spring can drive the same path when it lands).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const anim = ui.anim;
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests
const shapes = ui.shapes;

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

pub const LoadingIndicatorOptions = struct {
    /// The contained variant: a PrimaryContainer 48x48 CornerFull container
    /// with an OnPrimaryContainer indicator (else plain: transparent
    /// container, Primary indicator).
    contained: bool = false,
    theme: Theme = theme_mod.light,
};

/// M3E tokens (LoadingIndicatorTokens / LoadingIndicatorDefaults).
const container_size: f32 = 48; // ContainerWidth/Height
const indicator_size: f32 = 38; // ActiveSize
const morph_interval_ms: u32 = 650; // MorphIntervalMillis
const rotation_period_ms: u32 = 4666; // GlobalRotationDurationMillis
const quarter: f32 = 90; // +90° of shape rotation per morph

/// The M3E shape sequences live in ui.shapes (shapes.indeterminate_sequence:
/// SoftBurst -> Cookie9Sided -> Pentagon -> Pill -> Sunny -> Cookie4Sided ->
/// Oval, wrapping; shapes.determinate_sequence: Circle -> SoftBurst).

const LiState = struct {
    opts: LoadingIndicatorOptions,
    /// The determinate progress (0..1); null = the indeterminate morph loop.
    sig: ?*ui.state.Signal(f32) = null,
    morph_index: usize = 0,
    morph_rotation: f32 = 0, // the per-morph +90° steps
    morph_progress: f32 = 0, // 0..1 within the current morph (drives +90°)
    global_rotation: f32 = 0, // 0..360 continuous
    loop_running: bool = false, // the indeterminate loop launched
    anim_channel: u8 = 0, // morph channel marker (stable address)
    rot_channel: u8 = 0, // global rotation channel marker (stable address)
    /// The determinate semantic value ("35%") — a11y (Phase 2c); the
    /// indeterminate indicator announces no value (like progress.zig).
    value_buf: [16]u8 = std.mem.zeroes([16]u8),
    value_len: usize = 0,
    // The shape geometry, built once by initGeometry: the normalized preset
    // polygons + one Morph per adjacent pair (indeterminate wraps last ->
    // first), plus the emission scratch sized to the largest morph — the
    // per-frame emitPath writes into it, so paint allocates nothing.
    polys: []shapes.RoundedPolygon = &.{},
    morphs: []shapes.Morph = &.{},
    scratch_cubics: []shapes.Cubic = &.{},
    path_pts: []f32 = &.{},
    path_verbs: []i32 = &.{},
};

fn stateOf(n: *Node) *LiState {
    return @ptrCast(@alignCast(n.state.?));
}

/// The current shape index + rotation (pub accessors — tests + the app).
pub fn morphIndex(n: *Node) usize {
    return stateOf(n).morph_index;
}
pub fn shapeRotation(n: *Node) f32 {
    const s = stateOf(n);
    if (s.sig != null) {
        const p = std.math.clamp(s.sig.?.peek(), 0, 1);
        return -p * 180; // determinate: counterclockwise
    }
    return s.morph_progress * quarter + s.morph_rotation + s.global_rotation;
}

fn liMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = container_size, .h = container_size });
}

fn liLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    _ = bounds;
    // The indeterminate loop starts at the first layout that has a timeline
    // (golden tests have none — the indicator stays static there).
    if (s.sig == null and !s.loop_running) startLoop(n, s);
}

/// Build the shape geometry once per widget: the normalized preset
/// RoundedPolygons + a Morph per adjacent pair (the indeterminate loop wraps
/// last -> first; the determinate chain is linear), plus the per-frame
/// emission scratch sized to the largest morph's segment count.
fn initGeometry(allocator: std.mem.Allocator, s: *LiState, seq: []const shapes.Preset) !void {
    const polys = try allocator.alloc(shapes.RoundedPolygon, seq.len);
    var built_p: usize = 0;
    errdefer {
        for (polys[0..built_p]) |*p| p.deinit();
        allocator.free(polys);
    }
    for (seq, 0..) |preset, i| {
        polys[i] = try shapes.presetShape(allocator, preset);
        built_p += 1;
    }
    const n_morphs = if (s.sig == null) seq.len else seq.len - 1;
    const morphs = try allocator.alloc(shapes.Morph, n_morphs);
    var built_m: usize = 0;
    errdefer {
        for (morphs[0..built_m]) |*m| m.deinit();
        allocator.free(morphs);
    }
    var max_seg: usize = 0;
    for (0..n_morphs) |i| {
        morphs[i] = try shapes.Morph.init(allocator, &polys[i], &polys[(i + 1) % seq.len]);
        built_m += 1;
        max_seg = @max(max_seg, morphs[i].segmentCount());
    }
    const counts = shapes.pathCounts(max_seg);
    const scratch = try allocator.alloc(shapes.Cubic, max_seg);
    errdefer allocator.free(scratch);
    const pts = try allocator.alloc(f32, counts.pts);
    errdefer allocator.free(pts);
    const verbs = try allocator.alloc(i32, counts.verbs);
    errdefer allocator.free(verbs);
    s.polys = polys;
    s.morphs = morphs;
    s.scratch_cubics = scratch;
    s.path_pts = pts;
    s.path_verbs = verbs;
}

fn deinitGeometry(allocator: std.mem.Allocator, s: *LiState) void {
    for (s.morphs) |*m| m.deinit();
    allocator.free(s.morphs);
    for (s.polys) |*p| p.deinit();
    allocator.free(s.polys);
    allocator.free(s.scratch_cubics);
    allocator.free(s.path_pts);
    allocator.free(s.path_verbs);
}

fn liPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    const d = @min(b.w, b.h);
    // the container (the contained variant only)
    if (s.opts.contained) {
        ui.paint.fillRRect(ctx, cx - d / 2, cy - d / 2, d, d, d / 2, t.colors.primary_container);
    }
    // the indicator color
    const color: Color = if (s.opts.contained) t.colors.on_primary_container else t.colors.primary;
    if (color & 0xFF == 0 or s.morphs.len == 0) return;
    // the morph frame: indeterminate runs morph[morph_index] at
    // morph_progress (shape i -> i+1, wrapping); determinate runs the single
    // Circle -> SoftBurst morph at the clamped progress.
    const mi: usize = if (s.sig != null) 0 else s.morph_index % s.morphs.len;
    const prog: f32 = if (s.sig) |sig| std.math.clamp(sig.peek(), 0, 1) else s.morph_progress;
    const cubics = s.morphs[mi].asCubicsInto(prog, s.scratch_cubics);
    // the shape box: square, 38/48 of the container, centered — painted by
    // transforming the canvas (presets live in the normalized 0..1 box)
    const side = d * (indicator_size / container_size);
    ui.paint.save(ctx);
    ui.paint.translate(ctx, cx, cy);
    ui.paint.rotate(ctx, shapeRotation(n));
    ui.paint.scale(ctx, side, side);
    ui.paint.translate(ctx, -0.5, -0.5);
    shapes.fillCubics(ctx, cubics, s.path_pts, s.path_verbs, color, false); // winding
    ui.paint.restore(ctx);
}

/// The indeterminate loop, driven by the timeline: a morph tween (650ms
/// linear — morph_progress, the within-morph cubic lerp + its +90° rotation)
/// chained per morph, and a global rotation tween (4666ms linear) chained
/// per period. Without a timeline the indicator stays static (golden tests).
fn startLoop(n: *Node, s: *LiState) void {
    const tl = anim.timeline() orelse return;
    _ = tl.play(.{
        .kind = anim.Animation.tweenAnim(.{ 1, 0, 0, 0 }, morph_interval_ms, .{ .ease = .linear }),
        .from = .{ 0, 0, 0, 0 },
        .channel = @ptrCast(&s.anim_channel),
        .on_update = .{ .fn_ptr = liMorphUpdateCb, .userdata = n },
        .on_complete = .{ .fn_ptr = liMorphCompleteCb, .userdata = n },
    });
    _ = tl.play(.{
        .kind = anim.Animation.tweenAnim(.{ 360, 0, 0, 0 }, rotation_period_ms, .{ .ease = .linear }),
        .from = .{ 0, 0, 0, 0 },
        .channel = @ptrCast(&s.rot_channel),
        .on_update = .{ .fn_ptr = liRotUpdateCb, .userdata = n },
        .on_complete = .{ .fn_ptr = liRotCompleteCb, .userdata = n },
    });
    s.loop_running = true;
}

fn liMorphUpdateCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.morph_progress = value[0];
    n.markDirty();
}

fn liMorphCompleteCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.morph_index = (s.morph_index + 1) % s.morphs.len;
    s.morph_rotation = @mod(s.morph_rotation + quarter, 360);
    s.morph_progress = 0;
    n.markDirty();
    // chain the next morph (the same channel cancels the finished one)
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.tweenAnim(.{ 1, 0, 0, 0 }, morph_interval_ms, .{ .ease = .linear }),
            .from = .{ 0, 0, 0, 0 },
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = liMorphUpdateCb, .userdata = n },
            .on_complete = .{ .fn_ptr = liMorphCompleteCb, .userdata = n },
        });
    }
}

fn liRotUpdateCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).global_rotation = value[0];
    n.markDirty();
}

fn liRotCompleteCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.global_rotation = 0;
    n.markDirty();
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.tweenAnim(.{ 360, 0, 0, 0 }, rotation_period_ms, .{ .ease = .linear }),
            .from = .{ 0, 0, 0, 0 },
            .channel = @ptrCast(&s.rot_channel),
            .on_update = .{ .fn_ptr = liRotUpdateCb, .userdata = n },
            .on_complete = .{ .fn_ptr = liRotCompleteCb, .userdata = n },
        });
    }
}

/// The determinate progress changed (the app): repaint + keep the semantic
/// value in sync (Phase 2c). The announced value is clamped.
fn liSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.sig) |sig| {
        const str = std.fmt.bufPrint(&s.value_buf, "{d:.0}%", .{std.math.clamp(sig.peek(), 0, 1) * 100}) catch return;
        s.value_len = str.len;
        if (n.semantics) |sem| sem.value = s.value_buf[0..s.value_len];
        ui.semantics.notifyControlChanged(n); // a11y: the value changed
    }
    n.markDirty();
}

fn liDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| {
        tl.cancelChannel(@ptrCast(&s.anim_channel));
        tl.cancelChannel(@ptrCast(&s.rot_channel));
    }
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = liSyncCb, .userdata = n } });
    input.releaseNode(n);
    deinitGeometry(n.allocator, s);
    n.allocator.destroy(s);
}

const li_vtable = ui.node.VTable{
    .measure = liMeasure,
    .layout = liLayout,
    .paint = liPaint,
    .deinit = liDeinit,
};

/// An M3E loading indicator. `progress` = null → the indeterminate morph
/// loop (timeline-driven; static without a timeline); non-null → determinate
/// (the signal's 0..1 value selects the morph position + rotation). The
/// widget is a leaf: it paints its container + the current morph frame.
pub fn loadingIndicator(allocator: std.mem.Allocator, progress: ?*ui.state.Signal(f32), opts: LoadingIndicatorOptions) !*Node {
    const node = try Node.create(allocator, &li_vtable);
    errdefer node.allocator.destroy(node); // no state yet
    const s = try allocator.create(LiState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .sig = progress };
    node.state = s;
    // The preset polygons + pairwise morphs (the indeterminate sequence
    // wraps; the determinate chain is linear) — built once.
    try initGeometry(allocator, s, if (progress != null)
        &shapes.determinate_sequence
    else
        &shapes.indeterminate_sequence);
    // Phase 2c: indeterminate announces no value; determinate announces the
    // clamped progress percentage (the same pattern as the slider).
    if (progress) |sig| {
        const str = std.fmt.bufPrint(&s.value_buf, "{d:.0}%", .{std.math.clamp(sig.peek(), 0, 1) * 100}) catch "";
        s.value_len = str.len;
        ui.semantics.attach(node, .{ .role = .progress, .label = "Loading indicator", .value = s.value_buf[0..s.value_len] });
        sig.subscribe(.{ .callback = .{ .fn_ptr = liSyncCb, .userdata = node } });
    } else {
        ui.semantics.attach(node, .{ .role = .progress, .label = "Loading indicator" });
    }
    return node;
}

// --- tests ---

test "loading_indicator: measures the 48x48 container" {
    const n = try loadingIndicator(std.testing.allocator, null, .{});
    defer n.deinit();
    const m = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(container_size, m.w);
    try std.testing.expectEqual(container_size, m.h);
    try std.testing.expectEqual(ui.semantics.Role.progress, n.semantics.?.role);
}

test "loading_indicator: without a timeline the indeterminate loop stays static at shape 0" {
    const n = try loadingIndicator(std.testing.allocator, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    try std.testing.expectEqual(@as(usize, 0), morphIndex(n));
    try std.testing.expectEqual(@as(f32, 0), shapeRotation(n));
}

test "loading_indicator: the geometry builds once — 7 wrapping morphs indeterminate, 1 determinate" {
    const n = try loadingIndicator(std.testing.allocator, null, .{});
    defer n.deinit();
    const s = stateOf(n);
    try std.testing.expectEqual(@as(usize, shapes.indeterminate_sequence.len), s.polys.len);
    try std.testing.expectEqual(@as(usize, shapes.indeterminate_sequence.len), s.morphs.len);
    // the emission scratch fits the largest morph's outline
    var max_seg: usize = 0;
    for (s.morphs) |*m| max_seg = @max(max_seg, m.segmentCount());
    try std.testing.expect(max_seg > 0);
    const counts = shapes.pathCounts(max_seg);
    try std.testing.expectEqual(counts.pts, s.path_pts.len);
    try std.testing.expectEqual(counts.verbs, s.path_verbs.len);
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0);
    defer sig.deinit();
    const d = try loadingIndicator(std.testing.allocator, sig, .{});
    defer d.deinit();
    const ds = stateOf(d);
    try std.testing.expectEqual(@as(usize, shapes.determinate_sequence.len), ds.polys.len);
    try std.testing.expectEqual(@as(usize, shapes.determinate_sequence.len - 1), ds.morphs.len);
}

test "loading_indicator: the indeterminate loop advances the morph + rotation on the timeline" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const n = try loadingIndicator(std.testing.allocator, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    try std.testing.expect(tl.hasActive());
    tl.tick(0); // lazy start
    // mid-morph (325ms): morph_progress 0.5 → +45°, plus the global rotation
    // (325/4666 × 360 ≈ 25.07°)
    tl.tick(325);
    try std.testing.expectApproxEqAbs(@as(f32, 45), stateOf(n).morph_progress * quarter, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 70.07), shapeRotation(n), 1.0);
}

test "loading_indicator: a completed morph advances the index + 90° (and the rotation wraps)" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const n = try loadingIndicator(std.testing.allocator, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    tl.tick(0); // lazy start
    tl.tick(650); // the first morph completes
    try std.testing.expectEqual(@as(usize, 1), morphIndex(n));
    // the next morph starts: morph_progress 0, morph_rotation 90
    try std.testing.expectEqual(@as(f32, 0), stateOf(n).morph_progress);
    try std.testing.expectEqual(@as(f32, 90), stateOf(n).morph_rotation);
    // the second morph completes at 1300ms: index 2, rotation 180
    tl.tick(1300);
    try std.testing.expectEqual(@as(usize, 2), morphIndex(n));
    try std.testing.expectEqual(@as(f32, 180), stateOf(n).morph_rotation);
    // the global rotation is independent (linear, 360° per 4666ms)
    try std.testing.expect(stateOf(n).global_rotation > 0);
}

test "loading_indicator: the indeterminate morph steps through all 7 shapes and wraps" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const n = try loadingIndicator(std.testing.allocator, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    tl.tick(0); // lazy start
    // a morph completes every 650ms: 7 morphs walk the whole sequence and
    // the index wraps to 0 (the +90° morph rotation keeps accumulating —
    // 7×90 = 630 ≡ 270, it does not wrap with the shape index).
    for (1..7) |i| {
        tl.tick(650 * i);
        try std.testing.expectEqual(i, morphIndex(n));
    }
    tl.tick(650 * 7);
    try std.testing.expectEqual(@as(usize, 0), morphIndex(n));
    try std.testing.expectEqual(@as(f32, 270), stateOf(n).morph_rotation);
}

test "loading_indicator: determinate — the signal selects the shape + rotation" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0);
    defer sig.deinit();
    const n = try loadingIndicator(std.testing.allocator, sig, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    try std.testing.expectEqual(@as(f32, 0), shapeRotation(n)); // p=0 → circle, no rotation
    sig.set(0.25);
    try std.testing.expectEqual(@as(f32, -45), shapeRotation(n)); // -p × 180
    sig.set(0.75);
    try std.testing.expectEqual(@as(f32, -135), shapeRotation(n)); // the burst shape, rotated
    // out-of-range progress clamps
    sig.set(2);
    try std.testing.expectEqual(@as(f32, -180), shapeRotation(n));
}

test "golden: the contained variant paints the PrimaryContainer circle + the Primary indicator shape" {
    const t = theme_mod.light;
    const n = try loadingIndicator(std.testing.allocator, null, .{ .contained = true, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    n.layout(.{ .x = 8, .y = 8, .w = 48, .h = 48 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the container: a 48dp circle (primary_container), its corner is background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(8, 8));
    try std.testing.expectEqual(t.colors.primary_container, f.pixelAt(32, 12)); // inside the circle, above the shape
    // the indicator (on_primary_container): shape 0 = SoftBurst, its 38dp
    // box (13..51) centered at (32, 32) — its ink is inside the circle
    try std.testing.expect(f.countColorIn(.{ .x = 13, .y = 13, .w = 38, .h = 38 }, t.colors.on_primary_container) > 0);
    // the exact center is indicator ink (a filled shape covers it)
    try std.testing.expectEqual(t.colors.on_primary_container, f.pixelAt(32, 32));
}

test "golden: the plain variant paints no container — the Primary shape over the background" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0);
    defer sig.deinit();
    const n = try loadingIndicator(std.testing.allocator, sig, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    n.layout(.{ .x = 8, .y = 8, .w = 48, .h = 48 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // determinate p=0 → the circle shape (radius 19 at (32,32)): primary ink
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(32, 32));
    // the shape's bounding box edge (radius 19 → x = 13..51): just outside is background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(10, 32));
    // no container: the corner is background (not primary_container)
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(8, 8));
    // progress 0.75 → the Circle -> SoftBurst morph at t = 0.75, rotated
    // -135°: ink at the center
    sig.set(0.75);
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(32, 32));
    // the shape doesn't fill its box: the extreme corner of the 38dp box
    // ((13,13) and ~2px in) is outside the rounded shape (rotated)
    try std.testing.expect(f2.countColorIn(.{ .x = 13, .y = 13, .w = 3, .h = 3 }, t.colors.primary) == 0);
}

test "golden: the Pill preset rotates with the shape rotation (asymmetric outline)" {
    const t = theme_mod.light;
    const n = try loadingIndicator(std.testing.allocator, null, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    n.layout(.{ .x = 8, .y = 8, .w = 48, .h = 48 });
    // force the pill morph (index 3) at t = 0: the M3E Pill preset fills most
    // of the 38dp box (13..51) — an asymmetric blob whose bump pair sits on
    // one diagonal: a top bump offset right, the bottom-left corner cut deep,
    // the bottom-right moderate.
    stateOf(n).morph_index = 3;
    stateOf(n).morph_rotation = 0;
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(32, 32)); // the body
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(33, 15)); // the top bump
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(19, 43)); // the bottom-left body
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(23, 15)); // left of the bump
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(16, 16)); // the top-left corner
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(45, 47)); // the bottom-right cut
    // +90° swings the diagonal: the bottom-left body empties out, the
    // bottom-right cut fills in
    stateOf(n).morph_rotation = 90;
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(32, 32));
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f2.pixelAt(19, 45)); // was ink
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(47, 43)); // was background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f2.pixelAt(41, 15)); // the bump shifted
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(43, 45)); // ...into the right-bottom
}

test "loading_indicator: determinate announces its progress value (a11y); indeterminate announces none" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.35);
    defer sig.deinit();
    const n = try loadingIndicator(std.testing.allocator, sig, .{});
    defer n.deinit();
    try std.testing.expectEqualStrings("35%", n.semantics.?.value);
    sig.set(0.75);
    try std.testing.expectEqualStrings("75%", n.semantics.?.value);
    sig.set(2); // clamped
    try std.testing.expectEqualStrings("100%", n.semantics.?.value);
    // the indeterminate indicator announces no value (like progress.zig)
    const ind = try loadingIndicator(std.testing.allocator, null, .{});
    defer ind.deinit();
    try std.testing.expectEqualStrings("", ind.semantics.?.value);
}
