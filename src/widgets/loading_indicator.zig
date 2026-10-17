// LoadingIndicator (Phase 2d.4 PR #32, M3E) — the Material 3 Expressive
// shape-morphing loading indicator: an indeterminate morph loop and a
// determinate progress variant, plain + contained.
//
// Spec: Compose LoadingIndicator.kt + LoadingIndicatorTokens:
//   - container 48x48 (ContainerWidth/Height), CornerFull; the contained
//     variant fills it PrimaryContainer with an OnPrimaryContainer
//     indicator; the plain variant is transparent with a Primary indicator
//   - the indicator is 38dp (ActiveSize), scaled 38/48 within the container
//   - indeterminate: each morph is a spring(dampingRatio = 0.6,
//     stiffness = 200, visibilityThreshold = 0.1) toward 1 that settles in
//     <650ms; the next morph starts on the 650ms boundary
//     (MorphIntervalMillis) regardless, so the loop is a schedule, not a
//     chain. +90° of shape rotation per completed morph (the rotation rides
//     the RAW spring value — its overshoot is the bounce), plus a
//     continuous global rotation (360° per 4666ms,
//     GlobalRotationDurationMillis, linear)
//   - determinate: morphs Circle(rotateZ 18°) -> SoftBurst with progress
//     (0..1), rotating -180° over the full range
//   - the painted shape is scaled by calculateScaleFactor(polygons) ×
//     ActiveIndicatorScale (rotation-safe bounds vs bounds per preset) and
//     recentered from the CURRENT frame's path bounds every frame
//     (processPath)
//
// The widget is a LEAF: it paints its container + the current morph frame.
// The M3E shapes are ui.shapes RoundedPolygon presets (the real androidx
// SoftBurst/Cookie9Sided/Pentagon/Pill/Sunny/Cookie4Sided/Oval geometry —
// rounded corners, vertex normalization), interpolated by Morph: the matched
// cubics at progress t are emitted as a verb path (move + N×cubic + close)
// and filled through kx_fill_path (ABI 0.16.0). The polygons + pairwise
// morphs are built once per widget; per-frame emission reuses preallocated
// scratch, so paint allocates nothing.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const i18n_mod = @import("../ui/i18n.zig");
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
/// The upstream morph spec: spring(dampingRatio = 0.6, stiffness = 200,
/// visibilityThreshold = 0.1) — it settles in ~271ms, well inside the 650ms
/// morph interval (springSettleMs decays the envelope below the same 0.1
/// the upstream visibilityThreshold uses).
const morph_spring: anim.Spring = anim.Spring.fromDampingRatio(200, 0.6, 1);

/// The M3E shape sequences live in ui.shapes (shapes.indeterminate_sequence:
/// SoftBurst -> Cookie9Sided -> Pentagon -> Pill -> Sunny -> Cookie4Sided ->
/// Oval, wrapping; shapes.determinate_sequence: Circle -> SoftBurst).
const LiState = struct {
    opts: LoadingIndicatorOptions,
    /// The determinate progress (0..1); null = the indeterminate morph loop.
    sig: ?*ui.state.Signal(f32) = null,
    morph_index: usize = 0,
    /// The accumulated +90° steps — upstream's morphRotationTargetAngle,
    /// which STARTS at QuarterRotation.
    morph_rotation: f32 = quarter,
    /// The RAW morph spring value — overshoots 1 briefly (the bounce rides
    /// the rotation; the painted path clamps it to 0..1 like upstream's
    /// coerced progress).
    morph_progress: f32 = 0,
    /// A morph spring is in flight — completes mid-interval (index
    /// advance), or is force-advanced by the 650ms boundary ticker.
    morph_pending: bool = false,
    /// The next morph's scheduled start (loop epoch + k×650, armed by the
    /// first ticker tick — the morph springs' lazy start lands on it).
    next_morph_ms: u64 = 0,
    global_rotation: f32 = 0, // 0..360 continuous
    loop_running: bool = false, // the indeterminate loop launched
    anim_channel: u8 = 0, // morph channel marker (stable address)
    rot_channel: u8 = 0, // global rotation channel marker (stable address)
    i18n: ?*i18n_mod.I18n = null,
    /// calculateScaleFactor(polys) × ActiveIndicatorScale — built once with
    /// the geometry (upstream remembers it per polygon list).
    scale_factor: f32 = 1,
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
    if (s.sig != null) {
        // DeterminateIndicatorPolygons rotates the Circle by 360/20 = 18°
        // ("a smoother morphing to the soft-burst shapes" — upstream's
        // comment): the rotation shifts which circle vertices the morph
        // maps onto the burst's spikes. The presets are normalized into the
        // 0..1 box, so rotate about its center (a circle's bounds are
        // rotation-invariant — the box stays 0..1).
        const rad = (360.0 / 20.0) * std.math.pi / 180.0;
        const c = @cos(rad);
        const sn = @sin(rad);
        const rotated = try polys[0].transformed(allocator, .{
            .xx = c,
            .xy = -sn,
            .yx = sn,
            .yy = c,
            .dx = 0.5 - 0.5 * c + 0.5 * sn,
            .dy = 0.5 - 0.5 * sn - 0.5 * c,
        });
        polys[0].deinit();
        polys[0] = rotated;
    }
    // Upstream: shapesScaleFactor = calculateScaleFactor(indicatorPolygons)
    // × ActiveIndicatorScale — the rotation-safe shrink so no morph frame
    // clips while rotating, times IndicatorSize / min(ContainerW, H).
    s.scale_factor = calculateScaleFactor(polys) * (indicator_size / container_size);
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

/// Upstream LoadingIndicator.kt's private calculateScaleFactor: per polygon,
/// max(bounds.width/maxBounds.width, bounds.height/maxBounds.height) —
/// the rotation-safe bounds vs the plain bounds — then the MINIMUM over the
/// sequence. Presets are already normalized (uniform scale + translate), so
/// the ratios match the upstream computation on the raw MaterialShapes.
fn calculateScaleFactor(polys: []const shapes.RoundedPolygon) f32 {
    var scale_factor: f32 = 1;
    for (polys) |*p| {
        const b = p.bounds();
        const mb = p.maxBounds();
        const sx = (b.max[0] - b.min[0]) / (mb.max[0] - mb.min[0]);
        const sy = (b.max[1] - b.min[1]) / (mb.max[1] - mb.min[1]);
        // max(scaleX, scaleY) handles pill-like shapes (upstream's comment)
        scale_factor = @min(scale_factor, @max(sx, sy));
    }
    return scale_factor;
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
    // The morph frame. Indeterminate runs morph[morph_index] at the COERCED
    // morph progress (the spring overshoots 1 briefly — upstream clamps the
    // path progress and lets the bounce live in the rotation only, and so
    // does this); determinate picks activeMorphIndex = floor(N·p) and the
    // adjusted intra-morph progress (p·N mod 1 — 1 at p==1 on the last
    // morph so the end state holds the final shape, not a wrap to 0).
    var mi: usize = s.morph_index % s.morphs.len;
    var prog: f32 = std.math.clamp(s.morph_progress, 0, 1);
    if (s.sig) |sig| {
        const p = std.math.clamp(sig.peek(), 0, 1);
        const nm: f32 = @floatFromInt(s.morphs.len);
        mi = @min(@as(usize, @intFromFloat(p * nm)), s.morphs.len - 1);
        prog = if (p == 1 and mi == s.morphs.len - 1) 1 else @mod(p * nm, 1);
    }
    const cubics = s.morphs[mi].asCubicsInto(prog, s.scratch_cubics);
    // Upstream processPath: the normalized path is scaled by
    // size×scaleFactor, then translated so the CURRENT frame's bounds
    // center lands on the size center — the bounds move as the morph
    // reshapes (Pill's off-center mass shifts), so recompute them per
    // frame instead of centering a fixed 0..1 box.
    var lo: @Vector(2, f32) = .{ std.math.inf(f32), std.math.inf(f32) };
    var hi: @Vector(2, f32) = .{ -std.math.inf(f32), -std.math.inf(f32) };
    for (cubics) |cb| {
        inline for (.{ cb.a0, cb.c0, cb.c1, cb.a1 }) |v| {
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
    }
    const bc = (lo + hi) / @as(@Vector(2, f32), @splat(2));
    const side = d * s.scale_factor;
    ui.paint.save(ctx);
    ui.paint.translate(ctx, cx, cy);
    ui.paint.rotate(ctx, shapeRotation(n));
    ui.paint.scale(ctx, side, side);
    ui.paint.translate(ctx, -bc[0], -bc[1]);
    shapes.fillCubics(ctx, cubics, s.path_pts, s.path_verbs, color, false); // winding
    ui.paint.restore(ctx);
}

/// The indeterminate loop, mirroring upstream's LaunchedEffect: each morph
/// is a spring(0.6, 200, threshold 0.1) toward 1; it settles mid-interval,
/// and the NEXT morph waits for the 650ms boundary (the upstream
/// `delay(MorphIntervalMillis)` then `deferred.await()` structure — the
/// spring is guaranteed finished by the boundary). A timeline ticker
/// watches the boundaries; the spring's own completion advances the index.
/// The global rotation is a separate 4666ms linear tween, re-chained per
/// period. Without a timeline the indicator stays static (golden tests).
fn startLoop(n: *Node, s: *LiState) void {
    const tl = anim.timeline() orelse return;
    playMorph(n, s); // morph 0 starts now (the lazy start lands on the 1st tick)
    s.next_morph_ms = 0; // unarmed: the first ticker tick sets the loop epoch
    _ = tl.play(.{
        .kind = anim.Animation.tweenAnim(.{ 360, 0, 0, 0 }, rotation_period_ms, .{ .ease = .linear }),
        .from = .{ 0, 0, 0, 0 },
        .channel = @ptrCast(&s.rot_channel),
        .on_update = .{ .fn_ptr = liRotUpdateCb, .userdata = n },
        .on_complete = .{ .fn_ptr = liRotCompleteCb, .userdata = n },
    });
    tl.addTicker(.{ .fn_ptr = liTickerCb, .userdata = n, .has_pending = liTickerPendingCb });
    s.loop_running = true;
}

/// Play the next morph spring on the morph channel (in place of the
/// finished/pending one — the channel retargets the slot).
fn playMorph(n: *Node, s: *LiState) void {
    const tl = anim.timeline() orelse return;
    _ = tl.play(.{
        .kind = anim.Animation.springAnim(.{ 0, 0, 0, 0 }, .{ 1, 0, 0, 0 }, morph_spring, .{ 0, 0, 0, 0 }),
        .from = .{ 0, 0, 0, 0 },
        .channel = @ptrCast(&s.anim_channel),
        .on_update = .{ .fn_ptr = liMorphUpdateCb, .userdata = n },
        .on_complete = .{ .fn_ptr = liMorphCompleteCb, .userdata = n },
    });
    s.morph_pending = true;
}

/// The morph spring's endResult block (upstream): index +1, progress 0,
/// rotation +90° — runs when the spring reports Finished.
fn advanceMorph(n: *Node, s: *LiState) void {
    s.morph_pending = false;
    s.morph_index = (s.morph_index + 1) % s.morphs.len;
    s.morph_rotation = @mod(s.morph_rotation + quarter, 360);
    s.morph_progress = 0;
    n.markDirty();
}

/// The 650ms morph boundary ticker — the upstream `delay(MorphIntervalMillis)`
/// then `deferred.await()`: the pending spring has settled by the boundary
/// (settle < interval), so a boundary means "finish + start the next morph".
/// Running through the whole backlog keeps the schedule phase-locked to the
/// loop epoch even after a long stall.
fn liTickerCb(userdata: ?*anyopaque, now_ms: u64) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.next_morph_ms == 0) {
        // The loop epoch: morph 0's lazy start lands on this same tick.
        s.next_morph_ms = now_ms + morph_interval_ms;
        return;
    }
    while (now_ms >= s.next_morph_ms) {
        if (s.morph_pending) advanceMorph(n, s); // the spring is done — commit it
        playMorph(n, s); // supersedes the finished spring's channel slot
        s.next_morph_ms += morph_interval_ms;
    }
}

fn liTickerPendingCb(userdata: ?*anyopaque) bool {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    return stateOf(n).loop_running;
}

fn liMorphUpdateCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.morph_progress = value[0];
    n.markDirty();
}

fn liMorphCompleteCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    // The spring settled mid-interval: advance now; the boundary ticker
    // schedules the NEXT morph at its own time (the upstream await-then-
    // delay order — the delay started when the spring did).
    const s = stateOf(n);
    if (s.morph_pending) advanceMorph(n, s);
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
        if (n.semantics) |sem| {
            sem.value = s.value_buf[0..s.value_len];
            // Percent units, matching the "{d}%" display string.
            sem.value_range = .{ .min = 0, .max = 100, .now = std.math.clamp(sig.peek(), 0, 1) * 100 };
        }
        ui.semantics.notifyControlChanged(n); // a11y: the value changed
    }
    n.markDirty();
}

fn liDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| {
        tl.cancelChannel(@ptrCast(&s.anim_channel));
        tl.cancelChannel(@ptrCast(&s.rot_channel));
        tl.removeTicker(.{ .fn_ptr = liTickerCb, .userdata = n });
    }
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = liSyncCb, .userdata = n } });
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = liLocaleCb, .userdata = n });
    input.releaseNode(n);
    deinitGeometry(n.allocator, s);
    n.allocator.destroy(s);
}

/// Indeterminate announces no value; determinate announces the clamped
/// progress percentage (the same pattern as the slider). The label is
/// tr()-resolved — the locale callback re-attaches in the new locale.
fn attachLiSemantics(n: *Node) void {
    const s = stateOf(n);
    if (s.sig) |sig| {
        ui.semantics.attach(n, .{ .role = .progress, .label = i18n_mod.tr("Loading indicator"), .value = s.value_buf[0..s.value_len], .value_range = .{ .min = 0, .max = 100, .now = std.math.clamp(sig.peek(), 0, 1) * 100 } });
    } else {
        ui.semantics.attach(n, .{ .role = .progress, .label = i18n_mod.tr("Loading indicator") });
    }
}

fn liLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    attachLiSemantics(n);
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
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
    // Phase 2c
    if (progress) |sig| {
        const str = std.fmt.bufPrint(&s.value_buf, "{d:.0}%", .{std.math.clamp(sig.peek(), 0, 1) * 100}) catch "";
        s.value_len = str.len;
        sig.subscribe(.{ .callback = .{ .fn_ptr = liSyncCb, .userdata = node } });
    }
    attachLiSemantics(node);
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = liLocaleCb, .userdata = node });
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
    // upstream: morphRotationTargetAngle starts at QuarterRotation — the
    // static frame is already rotated one quarter
    try std.testing.expectEqual(@as(f32, 90), shapeRotation(n));
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

test "loading_indicator: the morph is a low-damping spring — overshoot then settle before the 650ms boundary" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const n = try loadingIndicator(std.testing.allocator, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    try std.testing.expect(tl.hasActive());
    tl.tick(0); // lazy start: morph 0's spring + the loop epoch
    // mid-spring (100ms): the spring(0.6, 200) value ≈ 0.528 (NOT the old
    // 0.154 of a linear tween) — the upstream spec is a low-damping spring.
    tl.tick(100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5277), stateOf(n).morph_progress, 0.01);
    // the rotation rides the raw spring: progress×90 + target(90) + global
    try std.testing.expectApproxEqAbs(@as(f32, 145.2), shapeRotation(n), 1.0); // 0.528·90 + 90 + ~7.7
    // ~250ms: the spring overshoots past 1 — the bounce upstream puts on
    // the rotation (the painted path progress stays clamped)
    tl.tick(250);
    try std.testing.expect(stateOf(n).morph_progress > 1);
    // the spring settles (<0.1 envelope ≈ 271ms): the index + rotation
    // advance NOW — mid-interval, not at the 650ms boundary
    tl.tick(300);
    try std.testing.expectEqual(@as(usize, 1), morphIndex(n));
    try std.testing.expectEqual(@as(f32, 0), stateOf(n).morph_progress);
    try std.testing.expectEqual(@as(f32, 180), stateOf(n).morph_rotation); // 90 + 90
    // then the loop idles until the boundary: nothing advances at 500ms
    tl.tick(500);
    try std.testing.expectEqual(@as(usize, 1), morphIndex(n));
    // the boundary starts morph 1's spring (morph 2 begins at 1300ms)
    tl.tick(650);
    try std.testing.expectEqual(@as(usize, 1), morphIndex(n));
    try std.testing.expectEqual(@as(f32, 0), stateOf(n).morph_progress);
    tl.tick(1300);
    try std.testing.expectEqual(@as(usize, 2), morphIndex(n));
    try std.testing.expectEqual(@as(f32, 270), stateOf(n).morph_rotation);
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
    // a morph boundary lands every 650ms: 7 morphs walk the whole sequence
    // and the index wraps to 0. The rotation starts at QuarterRotation and
    // adds 90° per morph: 90 + 7×90 = 720 ≡ 0 — it wraps with the index.
    for (1..7) |i| {
        tl.tick(650 * i);
        try std.testing.expectEqual(i, morphIndex(n));
    }
    tl.tick(650 * 7);
    try std.testing.expectEqual(@as(usize, 0), morphIndex(n));
    try std.testing.expectEqual(@as(f32, 0), stateOf(n).morph_rotation);
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
    // force the pill morph (index 3) at t = 0: the M3E Pill preset inside
    // the scale-factor-shrunk box (calculateScaleFactor × ActiveIndicatorScale
    // → ~33px inside 15.6..48.4) — an asymmetric blob whose bump pair sits on
    // one diagonal: a top bump offset right, the tail bottom-left.
    stateOf(n).morph_index = 3;
    stateOf(n).morph_rotation = 0;
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(32, 32)); // the body
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(34, 16)); // the top bump
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(22, 44)); // the bottom-left tail
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(27, 16)); // left of the bump
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(16, 16)); // the top-left corner
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(45, 47)); // the bottom-right cut
    // +90° swings the diagonal: the bump moves top-left, the tail bottom-right
    stateOf(n).morph_rotation = 90;
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(32, 32));
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(29, 16)); // the bump swung left
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(41, 43)); // the tail swung right
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f2.pixelAt(43, 16)); // the old bump emptied
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f2.pixelAt(19, 43)); // the old tail emptied
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

test "loading_indicator: i18n — the framework label localizes + re-resolves on a locale switch" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Loading indicator\": \"Indicador de carga\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const sig = try ui.state.Signal(f32).init(a, 0.4);
    defer sig.deinit();
    const n = try loadingIndicator(a, sig, .{});
    defer n.deinit();
    const sem = n.semantics.?;
    try std.testing.expectEqualStrings("Indicador de carga", sem.label);
    try std.testing.expectEqualStrings("40%", sem.value);
    try i18n.setLocale("en");
    // the re-attach preserves the live value + range
    const sem2 = n.semantics.?;
    try std.testing.expectEqualStrings("Loading indicator", sem2.label);
    try std.testing.expectEqualStrings("40%", sem2.value);
    try std.testing.expectEqual(@as(f32, 40), sem2.value_range.?.now);
}
