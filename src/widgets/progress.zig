// Progress indicators — 1:1 port of Compose material3.
//
// Upstream sources (.ref/material3, androidx-main):
//   - ProgressIndicator.kt          drawLinearIndicator, drawStopIndicator,
//                                   determinate/indeterminate draw blocks,
//                                   *AnimationSpec keyframes
//   - internal-LinearWavyProgressModifiers.kt
//                                   LinearProgressDrawingCache.updateFullPaths
//                                   (quad wave path + PathMeasure scale),
//                                   updateDrawPaths (segment extraction,
//                                   adaptive gap, right-to-left track build),
//                                   wavy drawStopIndicator
//   - internal-CircularWavyProgressModifiers.kt
//                                   CircularShapes.update (star/circle
//                                   polygons), CircularProgressDrawingCache
//                                   .updateFullPaths/updateDrawPaths
//                                   (scale+recenter, segment extraction,
//                                   offset shift + rotateZ, track gap),
//                                   drawCircularIndicator, the indeterminate
//                                   rotate(global + additional + 90)
//   - tokens/LinearProgressIndicatorTokens.kt, CircularProgressIndicatorTokens.kt
//
// What the port reproduces:
//   - flat linear: cap-inset segments, gap = TrackActiveSpace + strokeWidth,
//     shrinking-edge gap (p + min(p, gapFrac)), stop dot at the track end
//   - flat indeterminate: Compose's two-segment cycle (four keyframed
//     fractions, EmphasizedAccelerate cubic-bezier(0.3,0,0.8,0.15))
//   - wavy linear: full quad-wave path sampled once per size into an
//     arc-length table (the PathMeasure equivalent), per-frame segments cut
//     by arc length then y-scaled by amplitude; flat right-to-left track
//     pieces; stop dot that shrinks as progress nears the end
//   - determinate wavy amplitude ramp: 0 at p<=0.1 or p>=0.95 (upstream
//     indicatorAmplitude), cross-faded over 500ms — standard easing up,
//     emphasized-accelerate down (updateAmplitudeAnimation)
//   - circular determinate: gap-adjacent track arc + round-capped active arc
//   - circular indeterminate: keyframed progress 0.1<->0.87 (Standard easing),
//     4x90deg additional-rotation schedule (EmphasizedDecelerate) + 1080deg
//     global rotation over 6000ms
//   - wavy circular: the RoundedPolygon ring machinery of
//     internal-CircularWavyProgressModifiers.kt — a normalized circle
//     (track) / rounded star (active, amplitude 1) flattened into
//     wrap-around arc-length tables (the PathMeasure), segments cut by arc
//     length, the track gap taken out of the track only, the wave scroll
//     = shifted segment + rotateZ(-offset*360), and the indeterminate
//     rotate(global + additional + 90) wrapping both arcs. Container
//     48dp (WaveSize), wavelength 15dp, star = circle(numVertices)
//     vs star(numVertices, innerRadius 0.75, rounding 0.35/0.4,
//     innerRounding 0.5) — via ui.shapes (the androidx.graphics.shapes
//     port). At 0<amp<1 the active path is the circle→star Morph
//     (Morph.asCubics flattened into the same arc-length table), quantized
//     to 1/12 steps so the cross-fade rebuilds ~12 tables, not one per
//     frame.
//
// Deliberate deviations: upstream reads progress as a lambda and animates
// changes with ProgressAnimationSpec — here `progress_sig` carries the live
// value and the same spring spec drives it. The amplitude tween snaps on
// the first read (upstream Animatable(initialValue)) and does not retarget
// mid-flight — a newer target is picked up when the running job completes
// (upstream's job-gate).
//
// Painting: everything emits polylines (kx_stroke_polyline) — the wave path
// is sampled at ~1px x-resolution into a layout-allocated arc-length table
// (rebuilt on size/λ change only; 0 allocs per frame).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const anim = ui.anim;
const shapes = ui.shapes;
const node_mod = ui.node;
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

/// M3E tokens, verbatim from Compose LinearProgressIndicatorTokens /
/// CircularProgressIndicatorTokens / MotionTokens.
const linear_thickness: f32 = 4; // ActiveThickness == TrackThickness
const wave_height: f32 = 10; // WaveHeight (wavy container height)
const wave_amplitude: f32 = 3; // ActiveWaveAmplitude — the peak of the wave path
const wave_len_det: f32 = 40; // ActiveWaveWavelength (determinate)
const wave_len_indet: f32 = 20; // IndeterminateActiveWaveWavelength
const track_gap: f32 = 4; // TrackActiveSpace — active/track gap
const stop_size: f32 = 4; // StopSize — the dot at the track's end
const stop_trailing_max: f32 = 6; // StopIndicatorTrailingSpace
const circular_size: f32 = 40; // CircularProgressIndicatorTokens.Size
const circular_stroke: f32 = 4; // Circular TrackThickness
const circular_gap: f32 = 4; // Circular TrackActiveSpace
const circ_wavy_size: f32 = 48; // CircularProgressIndicatorTokens.WaveSize
const circ_wave_len: f32 = 15; // Circular ActiveWaveWavelength (det + indet)
const min_circ_verts: usize = 5; // MinCircularVertexCount
const arc_segments: usize = 48; // per full circle
const wave_seg_cap: usize = 2048; // emitted segment buffer (adaptive stride)
const linear_indet_ms: u32 = 1750; // LinearAnimationDuration
pub const circular_indet_ms: u32 = 6000; // CircularAnimationProgressDuration
const wave_offset_ms: f32 = 1000; // waveSpeed = wavelength/s → 1 cycle/s

pub const ProgressKind = enum { linear, circular };

pub const ProgressOptions = struct {
    kind: ProgressKind = .linear,
    /// 0..1 determinate; null = indeterminate (loops forever).
    progress: ?f32 = null,
    /// Live determinate value — overrides `progress`. Changes animate
    /// between values with upstream's ProgressAnimationSpec spring
    /// (dampingRatio 1.0 = DampingRatioNoBouncy, stiffness 50 =
    /// StiffnessVeryLow) instead of snapping; null = indeterminate is a
    /// static `progress`, not a signal state.
    progress_sig: ?*ui.state.Signal(f32) = null,
    wavy: bool = false, // linear + circular (M3E)
    theme: Theme = theme_mod.light,
};

/// Easing curves used by the indeterminate keyframes (MotionTokens).
fn easeEmphAccel(x: f32) f32 {
    return anim.cubicBezier(0.3, 0.0, 0.8, 0.15, x);
}
pub fn easeEmphDecel(x: f32) f32 {
    return anim.cubicBezier(0.05, 0.7, 0.1, 1.0, x);
}
pub fn easeStandard(x: f32) f32 {
    return anim.cubicBezier(0.2, 0.0, 0.0, 1.0, x);
}

/// One keyframe'd 0->1 segment: holds 0 until `delay_ms`, eases to 1 over
/// `duration_ms`, holds 1 after — port of `Xf at delay using Easing; 1f at
/// delay+duration`.
fn segValue(t_ms: f32, delay_ms: f32, duration_ms: f32, ease: *const fn (f32) f32) f32 {
    const t = t_ms - delay_ms;
    if (t <= 0) return 0;
    if (t >= duration_ms) return 1;
    return ease(t / duration_ms);
}

const ProgressState = struct {
    opts: ProgressOptions,
    phase: f32 = 0, // position inside the driving loop period (0..1)
    last_phase: f32 = 0, // previous tween value — elapsed accumulates its delta
    elapsed_ms: f64 = 0, // continuous clock; all schedules derive from it
    loop_running: bool = false, // the phase loop is registered on the timeline
    anim_channel: u8 = 0, // channel marker (stable address)
    // Wave path cache — upstream LinearProgressDrawingCache.updateFullPaths:
    // the quad-wave path sampled at ~1px x-resolution with cumulative arc
    // length (our PathMeasure). Rebuilt when (w,h,lambda) change; freed in
    // deinit. Never allocated per frame.
    cache_w: f32 = -1,
    cache_h: f32 = -1,
    cache_lambda: f32 = -1,
    path_x: []f32 = &.{},
    path_y: []f32 = &.{}, // centered at 0 (pre-translate)
    path_d: []f32 = &.{}, // cumulative arc length
    path_n: usize = 0,
    path_scale: f32 = 1, // arcLen / pathWidth (upstream progressPathScale)
    // Circular wavy cache — upstream CircularShapes +
    // CircularProgressDrawingCache: the normalized circle (track) and the
    // circle-or-star (progress) outlines flattened into wrap-around
    // arc-length tables (the PathMeasure). Rebuilt when (w, h, amp-class)
    // change; freed in deinit. Never allocated per frame.
    circ_w: f32 = -1,
    circ_h: f32 = -1,
    circ_amp: f32 = -1, // progress-path amplitude class: 1 = star, 0 = ring, (0,1) = morph
    circ_verts: usize = 0,
    /// The amplitude micro-animation (upstream updateAmplitudeAnimation):
    /// amp_display tweens to amp_target over DurationLong2 = 500ms when the
    /// target changes while attached — Increasing gets EasingStandard,
    /// Decreasing EasingEmphasizedAccelerate; the running job is NOT
    /// retargeted mid-flight (upstream's job-completed gate).
    amp_display: f32 = 0,
    amp_target: f32 = -1, // -1 = snap the first read (upstream initialValue)
    amp_running: bool = false,
    amp_channel: u8 = 0, // timeline channel marker (stable address) // star vertex count (the wave offset period base)
    circ_prog: RingTable = .{},
    circ_trk: RingTable = .{},
    // Signal-driven progress (ProgressAnimationSpec): an Effect springs
    // `displayed` toward the source's target — the OffsetState pattern.
    prog_effect: ?*ui.state.Effect = null,
    prog_channel: u8 = 0, // timeline channel marker (stable address)
    displayed: f32 = 0, // current animated value (read at paint)
    /// A `progressSetValue` spring is in flight on a signal-less widget —
    /// effProgress reads `displayed` until it completes.
    static_animating: bool = false,
    node: ?*Node = null, // back-pointer for the update callback's markDirty
};

fn stateOf(n: *Node) *ProgressState {
    return @ptrCast(@alignCast(n.state.?));
}

fn progressMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const circ_side: f32 = if (s.opts.wavy) circ_wavy_size else circular_size; // WaveSize vs Size
    const h: f32 = if (s.opts.kind == .linear) (if (s.opts.wavy) wave_height else linear_thickness) else circ_side;
    // LinearIndicatorWidth = 240dp when unbounded (upstream fixed size).
    const w: f32 = if (s.opts.kind == .circular) circ_side else (if (std.math.isFinite(c.max_w)) c.max_w else 240);
    return c.constrain(.{ .w = w, .h = h });
}

/// The phase loop runs while the widget lives when anything moves:
/// indeterminate sweeps/rotates on it, and the M3E wave scrolls on it even
/// when determinate. Flat determinate + determinate circular stay static —
/// nothing moves between value writes, so no animation is registered and
/// the host idles.
/// The value paint/schedule code reads: the animated display value when a
/// progress signal or a progressSetValue spring drives the widget, else
/// the static option.
fn effProgress(s: *const ProgressState) ?f32 {
    return if (s.opts.progress_sig != null or s.static_animating) s.displayed else s.opts.progress;
}

fn wantsPhaseLoop(s: *const ProgressState) bool {
    return effProgress(s) == null or s.opts.wavy;
}

fn progressLayout(n: *Node, bounds: Rect) void {
    _ = bounds;
    const s = stateOf(n);
    // The loop starts at the first layout that has a timeline — a widget
    // built before the host installs it (golden tests, conformance, bench
    // scenes) renders its phase-0 state; once a timeline exists this retry
    // kicks the loop off. Same pattern as loading_indicator's liLayout.
    if (wantsPhaseLoop(s) and !s.loop_running) startPhaseLoop(n, s);
}

/// NaN-safe progress clamp — a signal holding NaN would otherwise crash the
/// int casts in the arc/wave builders.
fn clamp01(v: f32) f32 {
    return if (std.math.isNan(v)) 0 else std.math.clamp(v, 0, 1);
}

/// One point of an arc, in degrees, centered at (cx, cy) with radius r.
/// Angles are degrees, 0 = 3 o'clock, positive clockwise (y down).
fn arcPoint(cx: f32, cy: f32, r: f32, deg: f32) struct { x: f32, y: f32 } {
    const rad = deg * std.math.pi / 180;
    return .{ .x = cx + r * @cos(rad), .y = cy + r * @sin(rad) };
}

/// Fill xs/ys with an arc from `start_deg` sweeping `sweep_deg` (clockwise).
/// Returns the point count (<= max).
pub fn arcPolyline(xs: []f32, ys: []f32, cx: f32, cy: f32, r: f32, start_deg: f32, sweep_deg: f32) usize {
    if (!std.math.isFinite(sweep_deg)) return 0;
    const n: usize = @intFromFloat(@ceil(@abs(sweep_deg) / 360 * arc_segments));
    const count = @min(@max(n, 2), xs.len);
    for (0..count) |i| {
        const p = arcPoint(cx, cy, r, start_deg + sweep_deg * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1)));
        xs[i] = p.x;
        ys[i] = p.y;
    }
    return count;
}

/// The y of the upstream quad wave at path-x `px`: quads run anchor→anchor
/// every lambda/2 px; the control point sits at the quarter offset with
/// alternating sign and magnitude `wave_ctrl` (h − strokeWidth, so the curve
/// peaks at wave_amplitude). Path-x of 0 starts on an anchor (the flat
/// segment the path begins with), first lobe dips +y.
fn waveY(px: f32, half_lambda: f32, wave_ctrl: f32) f32 {
    const k: f32 = px / half_lambda;
    const quad_i: f32 = @floor(k);
    const u = k - quad_i; // 0..1 inside the quad
    if (u <= 0 or u >= 1) return 0;
    const sign: f32 = if (@mod(quad_i, 2) == 0) 1 else -1;
    // quadratic y(t) = 2(1-t)t * controlY (endpoints at y=0)
    return sign * wave_ctrl * 2 * u * (1 - u);
}

/// Port of LinearProgressDrawingCache.updateFullPaths: sample the quad wave
/// over [0, w + 2*lambda] at ~1px resolution into xs/ys/dist + the
/// arc-length/path-width scale. Allocates via the node allocator, once per
/// (w, h, lambda). `path_y` is stored centered at 0 (upstream translates by
/// h/2; we fold that into the emit).
fn ensureWavePath(n: *Node, s: *ProgressState, w: f32, h: f32, lambda: f32) void {
    if (s.cache_w == w and s.cache_h == h and s.cache_lambda == lambda) return;
    if (!std.math.isFinite(w) or w <= 0 or lambda <= 0) {
        s.path_n = 0;
        return;
    }
    const half_l = lambda / 2;
    const wave_ctrl = h - linear_thickness; // controlY = height - stroke.width
    // upstream: quads while anchorX <= w + 2*lambda
    const ext = w + lambda * 2;
    const n_quads: usize = @intFromFloat(@floor(ext / half_l)); // anchors at half_l steps starting at half_l
    const pts_per_quad: usize = 16;
    const cap = n_quads * pts_per_quad + 2;
    if (s.path_x.len < cap) {
        if (s.path_x.len > 0) {
            n.allocator.free(s.path_x);
            n.allocator.free(s.path_y);
            n.allocator.free(s.path_d);
        }
        s.path_x = n.allocator.alloc(f32, cap) catch {
            s.path_n = 0;
            return;
        };
        s.path_y = n.allocator.alloc(f32, cap) catch {
            n.allocator.free(s.path_x);
            s.path_x = &.{};
            s.path_n = 0;
            return;
        };
        s.path_d = n.allocator.alloc(f32, cap) catch {
            n.allocator.free(s.path_x);
            n.allocator.free(s.path_y);
            s.path_x = &.{};
            s.path_y = &.{};
            s.path_n = 0;
            return;
        };
    }
    var i: usize = 0;
    s.path_x[i] = 0;
    s.path_y[i] = 0;
    s.path_d[i] = 0;
    i += 1;
    var q: usize = 0;
    while (q < n_quads) : (q += 1) {
        for (1..pts_per_quad + 1) |step| {
            const t = @as(f32, @floatFromInt(step)) / pts_per_quad;
            const px = (@as(f32, @floatFromInt(q)) + t) * half_l;
            s.path_x[i] = px;
            s.path_y[i] = waveY(px, half_l, wave_ctrl);
            const dx = s.path_x[i] - s.path_x[i - 1];
            const dy = s.path_y[i] - s.path_y[i - 1];
            s.path_d[i] = s.path_d[i - 1] + @sqrt(dx * dx + dy * dy);
            i += 1;
        }
    }
    s.path_n = i;
    s.cache_w = w;
    s.cache_h = h;
    s.cache_lambda = lambda;
    // upstream: progressPathScale = pathMeasure.length / bounds.width —
    // bounds.width = the last anchor's x (path starts at x=0).
    const last_x = s.path_x[i - 1];
    s.path_scale = if (last_x > 0) s.path_d[i - 1] / last_x else 1;
}

/// x coordinate on the sampled wave path at arc length `d` (linear walk +
/// interpolation; the caller walks dist monotonically so this stays fast).
fn pathXAtDist(s: *const ProgressState, d: f32) f32 {
    const n_pts = s.path_n;
    if (n_pts == 0 or d <= 0) return 0;
    if (d >= s.path_d[n_pts - 1]) return s.path_x[n_pts - 1];
    var lo: usize = 0;
    var hi: usize = n_pts - 1;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (s.path_d[mid] <= d) lo = mid else hi = mid;
    }
    const seg = s.path_d[hi] - s.path_d[lo];
    const f = if (seg > 0) (d - s.path_d[lo]) / seg else 0;
    return s.path_x[lo] + (s.path_x[hi] - s.path_x[lo]) * f;
}

/// Port of pathMeasure.getSegment + the translate/scale transform in
/// updateDrawPaths: emit the wave-path points whose arc length falls in
/// [d0, d1] (dist = (x + waveShift) * scale), screen x = pathX − waveShift,
/// y = pathY*amplitude + halfHeight (upstream y' = y*amp + (1−amp)*hh for a
/// centered path). Emits ~1pt per path px (stride when the segment is wider
/// than the buffer). Returns the point count.
fn emitWaveSegment(s: *const ProgressState, d0: f32, d1: f32, shift: f32, amp: f32, half_h: f32, base_x: f32, base_y: f32, xs: []f32, ys: []f32) usize {
    if (s.path_n == 0 or d1 <= d0) return 0;
    // sample count: one point per ~1.2px of arc length (matches the build
    // density), capped by the buffer.
    const want: usize = @as(usize, @intFromFloat(@ceil((d1 - d0) / 1.2))) + 1;
    const count = @min(@max(want, 2), xs.len);
    for (0..count) |i| {
        const d = d0 + (d1 - d0) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1));
        const px = pathXAtDist(s, d);
        xs[i] = base_x + px - shift;
        ys[i] = base_y + half_h + waveY(px, s.cache_lambda / 2, s.cache_h - linear_thickness) * amp;
    }
    return count;
}

// --- circular wavy (internal-CircularWavyProgressModifiers.kt) ---

/// A closed outline sampled into a wrap-around arc-length table — the
/// CircularProgressDrawingCache PathMeasure. x/y hold n+1 points (the last
/// duplicates the first so a segment crossing the wrap interpolates
/// cleanly); d holds n+1 cumulative lengths, d[n] = the full outline
/// length. The repeated (doubled) path upstream uses for motion is
/// equivalent to reading distances mod L.
const RingTable = struct {
    x: []f32 = &.{},
    y: []f32 = &.{},
    d: []f32 = &.{},
    n: usize = 0, // real points (excludes the duplicated closing point)

    fn deinit(t: *RingTable, a: std.mem.Allocator) void {
        if (t.x.len > 0) {
            a.free(t.x);
            a.free(t.y);
            a.free(t.d);
        }
        t.* = .{};
    }

    /// progressPathLength / trackPathLength.
    fn totalLen(t: *const RingTable) f32 {
        return if (t.n > 0) t.d[t.n] else 0;
    }

    /// The outline point at arc length `dist`, wrapping — PathMeasure over
    /// the closed (doubled) path.
    fn pointAt(t: *const RingTable, dist: f32) [2]f32 {
        const dd = @mod(dist, t.d[t.n]);
        var lo: usize = 0;
        var hi: usize = t.n;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (t.d[mid] <= dd) lo = mid else hi = mid;
        }
        const seg = t.d[hi] - t.d[lo];
        const f = if (seg > 0) (dd - t.d[lo]) / seg else 0;
        return .{
            t.x[lo] + (t.x[hi] - t.x[lo]) * f,
            t.y[lo] + (t.y[hi] - t.y[lo]) * f,
        };
    }

    /// pathMeasure.getSegment + the updateDrawPaths rotateZ / the
    /// indeterminate withTransform rotation: emit [d0, d1] (~1pt per arc px)
    /// into xs/ys, rotated `rot_deg` about (px, py) (y-down, positive =
    /// clockwise — the Compose rotateZ convention), then translated by
    /// (base_x, base_y). Returns the point count.
    fn emit(t: *const RingTable, d0: f32, d1: f32, rot_deg: f32, px: f32, py: f32, base_x: f32, base_y: f32, xs: []f32, ys: []f32) usize {
        if (t.n == 0 or d1 <= d0) return 0;
        const want: usize = @as(usize, @intFromFloat(@ceil(d1 - d0))) + 1;
        const count = @min(@max(want, 2), xs.len);
        const rad = rot_deg * std.math.pi / 180;
        const c = @cos(rad);
        const sn = @sin(rad);
        for (0..count) |i| {
            const p = t.pointAt(d0 + (d1 - d0) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1)));
            const dx = p[0] - px;
            const dy = p[1] - py;
            xs[i] = base_x + px + dx * c - dy * sn;
            ys[i] = base_y + py + dx * sn + dy * c;
        }
        return count;
    }
};

/// CircularShapes.update: the vertex count is the circumference at the
/// stroke-adjusted radius divided by the wavelength, clamped to
/// MinCircularVertexCount.
fn circVertexCount(w: f32, h: f32) usize {
    const r = @min(w, h) / 2 - circular_stroke / 2;
    if (!(r > 0) or !std.math.isFinite(r)) return min_circ_verts;
    return @max(min_circ_verts, @as(usize, @intFromFloat(@round(2 * std.math.pi * r / circ_wave_len))));
}

/// Port of updateFullPaths' scale + processPath: the normalized polygon
/// outline is scaled by (size - strokeWidth) per axis and translated so its
/// (approximate cubic) bounds center lands on the size center, then
/// flattened into a RingTable. Returns a table with n==0 on <2 points.
/// The shared tail of circBuildTable: the flattened normalized points
/// scaled by (w−stroke, h−stroke), recentered on the bounds' center, and
/// arc-length indexed.
fn circTableFromPoints(a: std.mem.Allocator, pts: []const shapes.Point, bounds_center: shapes.Point, w: f32, h: f32) !RingTable {
    var t: RingTable = .{};
    errdefer t.deinit(a);
    const sx = w - circular_stroke; // scaleMatrix.scale(width - stroke.width)
    const sy = h - circular_stroke;
    const ox = w / 2 - bounds_center[0] * sx; // size.center - bounds.center
    const oy = h / 2 - bounds_center[1] * sy;
    var np = pts.len;
    // The closed outline's last anchor1 duplicates the first anchor0 — drop
    // it so the wrap edge (last real point -> first) carries the arc length.
    while (np > 1 and @abs(pts[np - 1][0] - pts[0][0]) < 1e-6 and @abs(pts[np - 1][1] - pts[0][1]) < 1e-6) np -= 1;
    if (np < 2) return t;
    t.x = try a.alloc(f32, np + 1);
    t.y = try a.alloc(f32, np + 1);
    t.d = try a.alloc(f32, np + 1);
    var dd: f32 = 0;
    for (pts, 0..) |p, i| {
        t.x[i] = p[0] * sx + ox;
        t.y[i] = p[1] * sy + oy;
        if (i > 0) {
            const dx = t.x[i] - t.x[i - 1];
            const dy = t.y[i] - t.y[i - 1];
            dd += @sqrt(dx * dx + dy * dy);
        }
        t.d[i] = dd;
    }
    // The wrap edge: last point back to the first (forceClosed = true).
    t.x[np] = t.x[0];
    t.y[np] = t.y[0];
    {
        const dx = t.x[0] - t.x[np - 1];
        const dy = t.y[0] - t.y[np - 1];
        dd += @sqrt(dx * dx + dy * dy);
    }
    t.d[np] = dd;
    t.n = np;
    return t;
}

fn circBuildTable(a: std.mem.Allocator, poly: *const shapes.RoundedPolygon, w: f32, h: f32) !RingTable {
    const sx = w - circular_stroke;
    const sy = h - circular_stroke;
    const bb = poly.bounds(); // normalized 0..1 bounds
    const center = shapes.Point{ (bb.min[0] + bb.max[0]) / 2, (bb.min[1] + bb.max[1]) / 2 };
    var pts = std.array_list.Managed(shapes.Point).init(a);
    defer pts.deinit();
    try poly.flatten(0.15 / @min(sx, sy), &pts); // ~0.15px at display scale
    return circTableFromPoints(a, pts.items, center, w, h);
}

/// The morph-interpolated outline → a RingTable (the circular wavy
/// amplitude cross-fade's intermediate shapes — upstream's Morph path).
fn circBuildTableCubics(a: std.mem.Allocator, cubics: []const shapes.Cubic, w: f32, h: f32) !RingTable {
    const sx = w - circular_stroke;
    const sy = h - circular_stroke;
    var pts = std.array_list.Managed(shapes.Point).init(a);
    defer pts.deinit();
    try shapes.flattenCubics(cubics, 0.15 / @min(sx, sy), &pts);
    // The cubics' bounds → the recenter origin (same math as RoundedPolygon
    // .bounds: the min/max over every control point — approximation-free
    // for our convex-ish outlines).
    var lo = shapes.Point{ std.math.floatMax(f32), std.math.floatMax(f32) };
    var hi = shapes.Point{ std.math.floatMin(f32), std.math.floatMin(f32) };
    for (cubics) |c| {
        for ([_]shapes.Point{ c.a0, c.c0, c.c1, c.a1 }) |p| {
            lo[0] = @min(lo[0], p[0]);
            lo[1] = @min(lo[1], p[1]);
            hi[0] = @max(hi[0], p[0]);
            hi[1] = @max(hi[1], p[1]);
        }
    }
    const center = shapes.Point{ (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2 };
    return circTableFromPoints(a, pts.items, center, w, h);
}

/// Port of CircularShapes.update + CircularProgressDrawingCache
/// .updateFullPaths: build the track ring (RoundedPolygon.circle(nv)) and
/// the progress ring (the rounded star at amplitude 1, the track polygon
/// otherwise — upstream's no-morph branch), both normalized + scaled +
/// recentered + flattened. Rebuilt when (w, h, amplitude-class) change.
fn ensureCircPaths(n: *Node, s: *ProgressState, w: f32, h: f32, amp: f32) void {
    // Quantize the morph parameter (1/12 steps): the 500ms transition
    // rebuilds ~12 path tables instead of one per frame.
    const amp_key: f32 = std.math.clamp(@round(amp * 12) / 12, 0, 1);
    if (s.circ_w == w and s.circ_h == h and s.circ_amp == amp_key) return;
    const a = n.allocator;
    if (!std.math.isFinite(w) or !std.math.isFinite(h) or w <= circular_stroke or h <= circular_stroke) {
        s.circ_prog.deinit(a);
        s.circ_trk.deinit(a);
        return;
    }
    const nv = circVertexCount(w, h);
    // trackPolygon = RoundedPolygon.circle(numVertices).normalized()
    var track_poly = shapes.circle(a, nv, 1, .{ 0, 0 }) catch {
        s.circ_prog.deinit(a);
        s.circ_trk.deinit(a);
        return;
    };
    defer track_poly.deinit();
    var track_norm = track_poly.normalized(a) catch {
        s.circ_prog.deinit(a);
        s.circ_trk.deinit(a);
        return;
    };
    defer track_norm.deinit();
    var new_trk = circBuildTable(a, &track_norm, w, h) catch {
        s.circ_prog.deinit(a);
        s.circ_trk.deinit(a);
        return;
    };
    errdefer new_trk.deinit(a);
    // getProgressPath: the star at amplitude 1, the track ring at 0, and
    // the circle→star Morph (asCubics(amp) flattened) at intermediate
    // amplitudes — upstream's animatable amplitude cross-fade.
    // star(numVerticesPerRadius = nv, innerRadius = 0.75,
    // rounding = CornerRounding(0.35, smoothing 0.4), innerRounding = 0.5).
    var new_prog: RingTable = .{};
    if (amp_key > 0) {
        var star_poly = shapes.star(a, nv, 1, 0.75, .{ .radius = 0.35, .smoothing = 0.4 }, .{ .radius = 0.5 }, .{ 0, 0 }) catch {
            new_trk.deinit(a);
            s.circ_prog.deinit(a);
            s.circ_trk.deinit(a);
            return;
        };
        defer star_poly.deinit();
        var star_norm = star_poly.normalized(a) catch {
            new_trk.deinit(a);
            s.circ_prog.deinit(a);
            s.circ_trk.deinit(a);
            return;
        };
        defer star_norm.deinit();
        if (amp_key >= 1) {
            new_prog = circBuildTable(a, &star_norm, w, h) catch {
                new_trk.deinit(a);
                s.circ_prog.deinit(a);
                s.circ_trk.deinit(a);
                return;
            };
        } else {
            // 0 < amp < 1: morph ring → star at the quantized amplitude.
            var morph = shapes.Morph.init(a, &track_norm, &star_norm) catch {
                new_trk.deinit(a);
                s.circ_prog.deinit(a);
                s.circ_trk.deinit(a);
                return;
            };
            defer morph.deinit();
            const cubics = morph.asCubics(a, amp_key) catch {
                new_trk.deinit(a);
                s.circ_prog.deinit(a);
                s.circ_trk.deinit(a);
                return;
            };
            defer a.free(cubics);
            new_prog = circBuildTableCubics(a, cubics, w, h) catch {
                new_trk.deinit(a);
                s.circ_prog.deinit(a);
                s.circ_trk.deinit(a);
                return;
            };
        }
    } else {
        new_prog = circBuildTable(a, &track_norm, w, h) catch {
            new_trk.deinit(a);
            s.circ_prog.deinit(a);
            s.circ_trk.deinit(a);
            return;
        };
    }
    s.circ_prog.deinit(a);
    s.circ_trk.deinit(a);
    s.circ_prog = new_prog;
    s.circ_trk = new_trk;
    s.circ_verts = nv;
    s.circ_w = w;
    s.circ_h = h;
    s.circ_amp = amp_key;
}

/// The wave scroll: upstream's offset animation runs one full outline
/// revolution per (wavelength/waveSpeed * 1000 * vertexCount) ms — with
/// waveSpeed = wavelength that's vertexCount seconds.
fn circWaveOffset(s: *const ProgressState) f32 {
    if (s.circ_verts == 0) return 0;
    const period = @as(f64, @floatFromInt(s.circ_verts)) * 1000;
    return @floatCast(@mod(s.elapsed_ms / period, 1));
}

/// Port of DrawScope.drawLinearIndicator — a straight cap-inset segment at
/// the vertical center. start/end are fractions; order-agnostic.
fn drawLinearSeg(ctx: *kx.Ctx, b: Rect, start_f: f32, end_f: f32, color: Color, rtl: bool) void {
    const w = b.w;
    const y = b.y + b.h / 2;
    const cap_w = linear_thickness / 2; // round cap inset
    const bar_start = (if (rtl) 1 - end_f else start_f) * w;
    const bar_end = (if (rtl) 1 - start_f else end_f) * w;
    const a = std.math.clamp(bar_start, cap_w, w - cap_w);
    const e = std.math.clamp(bar_end, cap_w, w - cap_w);
    if (@abs(end_f - start_f) <= 0) return;
    var xs = [2]f32{ b.x + a, b.x + e };
    var ys = [2]f32{ y, y };
    ui.paint.strokePolyline(ctx, &xs, &ys, linear_thickness, true, color);
}

/// Flat stop dot (ProgressIndicatorDefaults.drawStopIndicator): a
/// stop_size circle at the track end, offset by StopIndicatorTrailingSpace.
fn drawFlatStop(ctx: *kx.Ctx, b: Rect, color: Color, rtl: bool) void {
    const adj = @min(stop_size, b.h);
    const off = @min((b.h - adj) / 2, stop_trailing_max);
    const cx = if (rtl) b.x + adj / 2 + off else b.x + b.w - adj / 2 - off;
    ui.paint.fillRRect(ctx, cx - adj / 2, b.y + (b.h - adj) / 2, adj, adj, adj / 2, color);
}

/// Port of LinearProgressDrawingCache.updateDrawPaths: for each [tail, head]
/// fraction pair, cut the wave segment by arc length and emit the flat
/// right-to-left track pieces between segments. Returns the head fraction of
/// the last segment (for the stop dot).
fn drawWavyLinear(n: *Node, s: *ProgressState, ctx: *kx.Ctx, b: Rect, fractions: []const f32, amp: f32, wave_offset: f32, active: Color, track: Color, rtl: bool) void {
    const w = b.w;
    const half_h = b.h / 2;
    const lambda: f32 = if (effProgress(s) != null) wave_len_det else wave_len_indet;
    ensureWavePath(n, s, w, b.h, lambda);
    const cap_w = linear_thickness / 2; // both strokes are 4dp Round
    const wave_shift: f32 = if (amp != 0) wave_offset * lambda else 0;

    var xs: [wave_seg_cap]f32 = undefined;
    var ys: [wave_seg_cap]f32 = undefined;

    // Track: upstream builds right-to-left; each piece is a straight line at
    // halfHeight. nextEndTrackOffset starts at w - capW.
    var next_end = w - cap_w;
    var adjusted_gap = track_gap;
    var active_visible = false;
    var i: usize = 0;
    while (i + 1 < fractions.len) : (i += 2) {
        const tail_f = fractions[i];
        const head_f = fractions[i + 1];
        const bar_tail = tail_f * w;
        const bar_head = head_f * w;
        if (i == 0) {
            adjusted_gap = if (bar_head < cap_w) 0 else @min(bar_head - cap_w, track_gap);
            active_visible = bar_head >= cap_w;
        }
        const adj_head = std.math.clamp(bar_head, cap_w, w - cap_w);
        const adj_tail = std.math.clamp(bar_tail, cap_w, w - cap_w);
        // active wave segment
        if (@abs(head_f - tail_f) > 0 and s.path_n > 0) {
            const d0 = (adj_tail + wave_shift) * s.path_scale;
            const d1 = (adj_head + wave_shift) * s.path_scale;
            const cnt = emitWaveSegment(s, d0, d1, wave_shift, amp, half_h, b.x, b.y, &xs, &ys);
            if (cnt > 1) {
                if (rtl) for (0..cnt) |j| {
                    xs[j] = b.x + w - (xs[j] - b.x);
                };
                ui.paint.strokePolyline(ctx, xs[0..cnt], ys[0..cnt], linear_thickness, true, active);
            }
        }
        // track piece before this segment (right-to-left build)
        const spacing: f32 = if (active_visible) adjusted_gap + cap_w * 2 else adjusted_gap;
        if (next_end > adj_head + spacing) {
            var txs = [2]f32{ b.x + next_end, b.x + @max(cap_w, adj_head + spacing) };
            var tys = [2]f32{ b.y + half_h, b.y + half_h };
            if (rtl) {
                txs[0] = b.x + w - (txs[0] - b.x);
                txs[1] = b.x + w - (txs[1] - b.x);
            }
            ui.paint.strokePolyline(ctx, &txs, &tys, linear_thickness, true, track);
        }
        if (bar_head > bar_tail) {
            next_end = @max(cap_w, adj_tail - spacing);
        }
    }
    // final track piece at the left end
    if (next_end > cap_w) {
        var txs = [2]f32{ b.x + next_end, b.x + cap_w };
        var tys = [2]f32{ b.y + half_h, b.y + half_h };
        if (rtl) {
            txs[0] = b.x + w - (txs[0] - b.x);
            txs[1] = b.x + w - (txs[1] - b.x);
        }
        ui.paint.strokePolyline(ctx, &txs, &tys, linear_thickness, true, track);
    }
}

/// Upstream amplitude(): zero at the edges, full in between.
fn wavyAmplitude(progress: f32) f32 {
    return if (progress <= 0.1 or progress >= 0.95) 0 else 1;
}

/// Upstream updateAmplitudeAnimation: the amp snaps to its target on the
/// first read (Animatable(initialValue = target) — no intro ramp), then a
/// target change while attached launches a 500ms tween — EasingStandard
/// increasing, EasingEmphasizedAccelerate decreasing. A running job is not
/// retargeted mid-flight (the job-completed gate); the next update picks
/// up the newest target when it finishes.
fn updateAmp(n: *Node, s: *ProgressState, target: f32) void {
    if (s.amp_target < 0) {
        s.amp_display = target;
        s.amp_target = target;
        return;
    }
    if (target == s.amp_target or s.amp_running) return;
    s.amp_target = target;
    if (anim.timeline()) |tl| {
        const increasing = s.amp_display < target;
        _ = tl.play(.{
            .kind = anim.Animation.tweenAnim(.{ target, 0, 0, 0 }, 500, .{ .ease = if (increasing) .emphasized else .emphasized_accelerate }),
            .from = .{ s.amp_display, 0, 0, 0 },
            .channel = @ptrCast(&s.amp_channel),
            .on_update = .{ .fn_ptr = ampUpdateCb, .userdata = n },
            .on_complete = .{ .fn_ptr = ampDoneCb, .userdata = n },
        });
        s.amp_running = true;
    } else {
        s.amp_display = target; // no timeline: snap (tests, pre-host paint)
    }
}

fn ampUpdateCb(userdata: ?*anyopaque, v: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.amp_display = v[0];
    n.markDirty();
}

fn ampDoneCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.amp_running = false;
    n.markDirty();
}

/// The four indeterminate fractions (t1, h1, t2, h2 order is the caller's
/// choice — we emit [tail, head] pairs as upstream getProgressFractions).
fn indetFractions(t_ms: f32, out: *[4]f32) void {
    // LinearIndeterminateProgressEasing = EmphasizedAccelerate
    const h1 = segValue(t_ms, 0, 1000, easeEmphAccel);
    const t1 = segValue(t_ms, 250, 1000, easeEmphAccel);
    const h2 = segValue(t_ms, 650, 850, easeEmphAccel);
    const t2 = segValue(t_ms, 900, 850, easeEmphAccel);
    out.* = .{ t1, h1, t2, h2 };
}

/// Circular indeterminate schedules, ported from the keyframe specs.
/// progress: 0.1 -> 0.87 over the first half (Standard), back over the
/// second (Linear). additionalRotation: +90deg steps at 300/1800/3300/4800ms
/// with EmphasizedDecelerate, holding between.
pub fn circIndetProgress(t_ms: f32) f32 {
    if (t_ms <= 3000) return 0.1 + (0.87 - 0.1) * easeStandard(t_ms / 3000);
    return 0.87 + (0.1 - 0.87) * ((t_ms - 3000) / 3000);
}

pub fn circAddRotation(t_ms: f32) f32 {
    // keyframes: step k eases [k*1500, k*1500+300] from 90k to 90(k+1) with
    // EmphasizedDecelerate, then holds. Upstream: 90@300 hold->1500,
    // 180@1800 hold->3000, 270@3300 hold->4500, 360@4800 hold->6000.
    if (t_ms >= 4800) return 360;
    const k: usize = @intFromFloat(@floor(t_ms / 1500));
    const local = t_ms - @as(f32, @floatFromInt(k)) * 1500;
    const base: f32 = @floatFromInt(k * 90);
    if (local >= 300) return base + 90;
    return base + 90 * easeEmphDecel(local / 300);
}

fn progressPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const t = s.opts.theme;
    const active = t.colors.primary;
    const track = t.colors.secondary_container;
    const rtl = ui.i18n.direction() == .rtl;
    const elapsed: f32 = @floatCast(s.elapsed_ms);
    switch (s.opts.kind) {
        .linear => {
            if (!s.opts.wavy) {
                // ---- flat linear (ProgressIndicator.kt draw blocks) ----
                const gap_f = (track_gap + linear_thickness) / b.w; // round cap -> + strokeWidth
                if (effProgress(s)) |p_raw| {
                    const p = clamp01(p_raw);
                    const track_start = p + @min(p, gap_f);
                    if (track_start <= 1) drawLinearSeg(ctx, b, track_start, 1, track, rtl);
                    drawLinearSeg(ctx, b, 0, p, active, rtl);
                    drawFlatStop(ctx, b, active, rtl);
                } else {
                    const t_ms = @mod(elapsed, @as(f32, @floatFromInt(linear_indet_ms)));
                    var fr: [4]f32 = undefined;
                    indetFractions(t_ms, &fr);
                    const t1 = fr[0];
                    const h1 = fr[1];
                    const t2 = fr[2];
                    const h2 = fr[3];
                    if (h1 < 1 - gap_f) {
                        const st = if (h1 > 0) h1 + gap_f else 0;
                        drawLinearSeg(ctx, b, st, 1, track, rtl);
                    }
                    if (h1 - t1 > 0) drawLinearSeg(ctx, b, t1, h1, active, rtl);
                    if (t1 > gap_f) {
                        const st = if (h2 > 0) h2 + gap_f else 0;
                        const en = if (t1 < 1) t1 - gap_f else 1;
                        drawLinearSeg(ctx, b, st, en, track, rtl);
                    }
                    if (h2 - t2 > 0) drawLinearSeg(ctx, b, t2, h2, active, rtl);
                    if (t2 > gap_f) {
                        const en = if (t2 < 1) t2 - gap_f else 1;
                        drawLinearSeg(ctx, b, 0, en, track, rtl);
                    }
                }
            } else {
                // ---- wavy linear (LinearWavyProgressModifiers) ----
                const wave_offset = @mod(elapsed / wave_offset_ms, 1);
                var fr: [4]f32 = undefined;
                var n_frac: usize = 2;
                var amp_target: f32 = 1;
                if (effProgress(s)) |p_raw| {
                    const p = clamp01(p_raw);
                    fr[0] = 0;
                    fr[1] = p;
                    amp_target = wavyAmplitude(p);
                } else {
                    indetFractions(@mod(elapsed, @as(f32, @floatFromInt(linear_indet_ms))), &fr);
                    n_frac = 4;
                }
                updateAmp(n, s, amp_target);
                drawWavyLinear(n, s, ctx, b, fr[0..n_frac], s.amp_display, wave_offset, active, track, rtl);
                if (effProgress(s)) |p_raw| {
                    // wavy stop dot — determinate only. Upstream draws it in
                    // rotate(ltr?0:180): compute in LTR space, mirror the
                    // final rect in RTL.
                    const pe = clamp01(p_raw);
                    const cap_w = linear_thickness / 2;
                    var sz = @min(linear_thickness, stop_size);
                    const x_off: f32 = if (sz == linear_thickness) 0 else linear_thickness / 4;
                    var ix = b.w - sz - x_off;
                    const px = b.w * pe + cap_w;
                    if (ix <= px) {
                        sz = @max(0, sz - (px - ix));
                        ix = px;
                    }
                    if (sz > 0) {
                        const rx = if (rtl) b.x + b.w - ix - sz else b.x + ix;
                        ui.paint.fillRRect(ctx, rx, b.y + (b.h - sz) / 2, sz, sz, sz / 2, active);
                    }
                }
            }
        },
        .circular => {
            if (s.opts.wavy) {
                // ---- wavy circular (CircularWavyProgressModifiers) ----
                // currentStrokeCapWidth: both strokes are Round →
                // max(stroke, trackStroke)/2 (0 when taller than wide).
                const cap_w: f32 = if (b.h > b.w) 0 else circular_stroke / 2;
                const pcx = b.w / 2; // the progress-path bounds center ==
                const pcy = b.h / 2; // size center after processPath
                var xs: [wave_seg_cap]f32 = undefined;
                var ys: [wave_seg_cap]f32 = undefined;
                if (effProgress(s)) |p_raw| {
                    const p = clamp01(p_raw);
                    updateAmp(n, s, wavyAmplitude(p));
                    const amp = s.amp_display; // indicatorAmplitude
                    ensureCircPaths(n, s, b.w, b.h, amp);
                    const lp = s.circ_prog.totalLen();
                    const lt = s.circ_trk.totalLen();
                    const p_stop = p * lp;
                    // updateDrawPaths: gap + cap insets come out of the
                    // track only (trackSpacing = 2*insets + gap).
                    const spacing = 2 * @min(p_stop, cap_w) + @min(p_stop, circular_gap);
                    const offset: f32 = if (amp > 0) circWaveOffset(s) else 0;
                    const shift = offset * lp;
                    const rot_a = @mod(offset * 360, 360);
                    const t_start = p * lt + spacing;
                    const t_stop = lt - spacing;
                    var cnt = s.circ_trk.emit(t_start, t_stop, 0, pcx, pcy, b.x, b.y, &xs, &ys);
                    if (cnt > 1) ui.paint.strokePolyline(ctx, xs[0..cnt], ys[0..cnt], circular_stroke, true, track);
                    cnt = s.circ_prog.emit(shift, p_stop + shift, -rot_a, pcx, pcy, b.x, b.y, &xs, &ys);
                    if (cnt > 1) ui.paint.strokePolyline(ctx, xs[0..cnt], ys[0..cnt], circular_stroke, true, active);
                } else {
                    ensureCircPaths(n, s, b.w, b.h, 1);
                    const lp = s.circ_prog.totalLen();
                    const lt = s.circ_trk.totalLen();
                    const t_ms = @mod(elapsed, @as(f32, @floatFromInt(circular_indet_ms)));
                    const prog = circIndetProgress(t_ms);
                    const p_stop = prog * lp;
                    const spacing = 2 * @min(p_stop, cap_w) + @min(p_stop, circular_gap);
                    // withTransform rotate(global + additional + 90) — baked
                    // into the emitted points (round caps are rotation
                    // invariant, so this is pixel-identical).
                    const rot = (t_ms / @as(f32, @floatFromInt(circular_indet_ms))) * 1080 + circAddRotation(t_ms) + 90;
                    const shift = circWaveOffset(s) * lp;
                    const rot_a = @mod(circWaveOffset(s) * 360, 360);
                    const t_start = prog * lt + spacing;
                    const t_stop = lt - spacing;
                    var cnt = s.circ_trk.emit(t_start, t_stop, rot, pcx, pcy, b.x, b.y, &xs, &ys);
                    if (cnt > 1) ui.paint.strokePolyline(ctx, xs[0..cnt], ys[0..cnt], circular_stroke, true, track);
                    cnt = s.circ_prog.emit(shift, p_stop + shift, rot - rot_a, pcx, pcy, b.x, b.y, &xs, &ys);
                    if (cnt > 1) ui.paint.strokePolyline(ctx, xs[0..cnt], ys[0..cnt], circular_stroke, true, active);
                }
            } else {
                const cx = b.x + b.w / 2;
                const cy = b.y + b.h / 2;
                const r = (@min(b.w, b.h) - circular_stroke) / 2;
                var xs: [arc_segments]f32 = undefined;
                var ys: [arc_segments]f32 = undefined;
                if (effProgress(s)) |p_raw| {
                    // ---- determinate circular ----
                    const sweep = clamp01(p_raw) * 360;
                    const start: f32 = 270;
                    const gap_sweep = (circular_gap + circular_stroke) / (std.math.pi * b.w) * 360;
                    const g = @min(sweep, gap_sweep);
                    // track arc (circularDeterminateTrackColor = track color)
                    const track_sweep = 360 - sweep - 2 * g;
                    if (track_sweep > 0) {
                        const nt = arcPolyline(&xs, &ys, cx, cy, r, start + sweep + g, track_sweep);
                        ui.paint.strokePolyline(ctx, xs[0..nt], ys[0..nt], circular_stroke, true, track);
                    }
                    if (sweep > 0) {
                        const na = arcPolyline(&xs, &ys, cx, cy, r, start, sweep);
                        ui.paint.strokePolyline(ctx, xs[0..na], ys[0..na], circular_stroke, true, active);
                    }
                } else {
                    // ---- indeterminate circular ----
                    const t_ms = @mod(elapsed, @as(f32, @floatFromInt(circular_indet_ms)));
                    const prog = circIndetProgress(t_ms);
                    const sweep = prog * 360;
                    const rot = (t_ms / @as(f32, @floatFromInt(circular_indet_ms))) * 1080 + circAddRotation(t_ms);
                    // indeterminate track color is Transparent upstream — skip
                    // the track arc entirely (same pixels).
                    const cap_off = (180.0 / std.math.pi) * (circular_stroke / (circular_size / 2)) / 2;
                    const na = arcPolyline(&xs, &ys, cx, cy, r, rot + cap_off, @max(sweep, 0.1));
                    ui.paint.strokePolyline(ctx, xs[0..na], ys[0..na], circular_stroke, true, active);
                }
            }
        },
    }
}

fn progressDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| {
        tl.cancelChannel(@ptrCast(&s.anim_channel)); // the update cb points at this node
        tl.cancelChannel(@ptrCast(&s.prog_channel));
        tl.cancelChannel(@ptrCast(&s.amp_channel));
    }
    if (s.prog_effect) |e| e.deinit();
    if (s.path_x.len > 0) {
        n.allocator.free(s.path_x);
        n.allocator.free(s.path_y);
        n.allocator.free(s.path_d);
    }
    s.circ_prog.deinit(n.allocator);
    s.circ_trk.deinit(n.allocator);
    n.allocator.destroy(s);
}

const progress_vtable = ui.node.VTable{
    .measure = progressMeasure,
    .layout = progressLayout,
    .paint = progressPaint,
    .deinit = progressDeinit,
};

/// Phase loop: play a 0..1 tween (linear easing) that re-arms itself on
/// completion — the indeterminate sweep/rotation and the wavy wave scroll.
/// Without a timeline the indicator renders its phase-0 state (tests).
fn startPhaseLoop(n: *Node, s: *ProgressState) void {
    const tl = anim.timeline() orelse return; // loop_running stays false → the layout retry can kick it off later
    const duration = loopPeriodMs(s);
    _ = tl.play(.{
        .kind = anim.Animation.tweenAnim(.{ 1, 0, 0, 0 }, duration, .{ .ease = .linear }),
        .from = .{ 0, 0, 0, 0 },
        .channel = @ptrCast(&s.anim_channel),
        .on_update = .{ .fn_ptr = progressPhaseCb, .userdata = n },
        .on_complete = .{ .fn_ptr = progressLoopCb, .userdata = n },
    });
    s.loop_running = true;
}

fn progressPhaseCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const v = value[0];
    // Accumulate a continuous clock from the looping tween's delta — every
    // schedule (indeterminate keyframes, wave offset) reads real elapsed
    // time so periods never drift apart.
    var d = v - s.last_phase;
    if (d < 0) d += 1; // loop wrap
    s.elapsed_ms += @as(f64, d) * @as(f64, @floatFromInt(loopPeriodMs(s)));
    s.last_phase = v;
    s.phase = v;
    n.markDirty();
}

fn loopPeriodMs(s: *const ProgressState) u32 {
    if (s.opts.kind == .circular) return circular_indet_ms;
    if (effProgress(s) == null) return linear_indet_ms;
    return @intFromFloat(wave_offset_ms); // determinate wavy: only the wave scrolls
}

fn progressLoopCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (wantsPhaseLoop(s)) startPhaseLoop(n, s); // loop forever
}

/// Upstream ProgressAnimationSpec (ProgressIndicator.kt:862):
/// spring(dampingRatio = DampingRatioNoBouncy, stiffness = StiffnessVeryLow).
const progress_spring = anim.Spring.fromDampingRatio(50, 1.0, 1);

fn progressUpdateCb(userdata: ?*anyopaque, v: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.displayed = v[0];
    n.markDirty();
}

/// Source moved → spring the display value to the new target (or snap when
/// no timeline exists — goldens/bench build before the host installs it).
fn progressEffectCb(userdata: ?*anyopaque) void {
    const s: *ProgressState = @ptrCast(@alignCast(userdata.?));
    const target = s.opts.progress_sig.?.get(); // tracked
    if (target == s.displayed) {
        if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.prog_channel));
        return;
    }
    const tl = anim.timeline() orelse {
        s.displayed = target; // no timeline: snap
        return;
    };
    _ = tl.play(.{
        // Velocity continuity on retarget (upstream animateFloatAsState).
        .kind = anim.Animation.springAnim(.{ s.displayed, 0, 0, 0 }, .{ target, 0, 0, 0 }, progress_spring, tl.channelVelocity(@ptrCast(&s.prog_channel))),
        .from = .{ s.displayed, 0, 0, 0 },
        .channel = @ptrCast(&s.prog_channel),
        .on_update = .{ .fn_ptr = progressUpdateCb, .userdata = s.node.? },
    });
}

/// The static-value spring completed — the paint falls back to the
/// (already-written) `opts.progress` target.
fn staticDoneCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.static_animating = false;
    n.markDirty();
}

/// Move a determinate progress to `v` through the same
/// ProgressAnimationSpec spring the signal path uses — upstream's
/// `animateFloatAsState(progress())` semantics for callers that don't
/// bind a signal. Routes through the signal when one is bound.
pub fn progressSetValue(n: *Node, v: f32) void {
    const s = stateOf(n);
    if (s.opts.progress_sig) |sig| {
        sig.set(clamp01(v));
        return;
    }
    const from = effProgress(s) orelse {
        // Indeterminate: keep the loop, just record the value.
        s.opts.progress = null;
        return;
    };
    const target = clamp01(v);
    if (target == from) {
        s.opts.progress = target;
        return;
    }
    s.opts.progress = target;
    const tl = anim.timeline() orelse {
        s.static_animating = false;
        s.displayed = target; // snap (tests, pre-host paint)
        n.markDirty();
        return;
    };
    // A mid-flight retarget hands the spring its velocity — the same
    // continuity the signal path gets by re-playing the channel.
    const v0 = tl.channelVelocity(@ptrCast(&s.prog_channel));
    s.displayed = from;
    s.static_animating = true;
    _ = tl.play(.{
        .kind = anim.Animation.springAnim(.{ from, 0, 0, 0 }, .{ target, 0, 0, 0 }, progress_spring, v0),
        .from = .{ from, 0, 0, 0 },
        .channel = @ptrCast(&s.prog_channel),
        .on_update = .{ .fn_ptr = progressUpdateCb, .userdata = n },
        .on_complete = .{ .fn_ptr = staticDoneCb, .userdata = n },
    });
    n.markDirty();
}

/// Linear + circular progress indicators (M3E).
pub fn progressIndicator(allocator: std.mem.Allocator, opts: ProgressOptions) !*Node {
    const node = try Node.create(allocator, &progress_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(ProgressState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .node = node };
    if (opts.progress_sig) |sig| {
        // Starts at the source so the first run() snaps (no retro intro
        // animation); later source moves spring to the new target.
        s.displayed = clamp01(sig.peek());
        s.prog_effect = try ui.state.Effect.init(allocator, progressEffectCb, s);
        errdefer if (s.prog_effect) |e| e.deinit();
        s.prog_effect.?.run(); // subscribe
    }
    node.state = s;
    ui.semantics.attach(node, .{ .role = .progress, .label = "Progress" }); // Phase 2c
    if (wantsPhaseLoop(s)) startPhaseLoop(node, s); // layout retries when no timeline exists yet
    return node;
}

// --- tests ---

test "progress: the indeterminate phase advances on timeline ticks and loops" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const n = try progressIndicator(std.testing.allocator, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 200, .h = 4 });
    try std.testing.expect(tl.hasActive());
    tl.tick(0); // lazy start: start_ms = 0
    tl.tick(500);
    const p1 = stateOf(n).phase;
    try std.testing.expectApproxEqAbs(@as(f32, 500) / @as(f32, @floatFromInt(linear_indet_ms)), p1, 1e-3);
    tl.tick(1000);
    try std.testing.expect(stateOf(n).phase > p1);
    // the tween re-arms on completion — the loop restarts (lazy start at
    // the tick after the 1750ms cycle ended)
    tl.tick(1800);
    tl.tick(1900);
    try std.testing.expect(tl.hasActive());
    try std.testing.expect(stateOf(n).phase < 0.2);
}

test "progress: a bound signal drives displayed — snap without timeline, spring with" {
    var sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.4);
    defer sig.deinit();
    const n = try progressIndicator(std.testing.allocator, .{ .progress_sig = sig });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 200, .h = 4 });
    try std.testing.expectEqual(@as(f32, 0.4), stateOf(n).displayed);
    try std.testing.expectEqual(@as(?f32, 0.4), effProgress(stateOf(n)));
    // No timeline → the effect snaps the display to the target.
    sig.set(0.9);
    try std.testing.expectEqual(@as(f32, 0.9), stateOf(n).displayed);
    // With a timeline the same write springs instead of snapping.
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    sig.set(0.2);
    const d0 = stateOf(n).displayed;
    tl.tick(0);
    tl.tick(50);
    const d50 = stateOf(n).displayed;
    try std.testing.expect(d50 > 0.2 and d50 < d0); // mid-flight, not snapped
    tl.tick(60000); // spring settle: ζ=1/k=50 decays under 0.1 in ~3s; generous cap
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), stateOf(n).displayed, 1e-3);
}

test "progress: the phase loop starts at layout when no timeline existed at construction" {
    // Built before the host installs its timeline (bench scene, conformance):
    // no animation is registered, the phase-0 state renders.
    const n = try progressIndicator(std.testing.allocator, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 200, .h = 4 });
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    try std.testing.expect(!tl.hasActive());
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    // A later layout (different bounds → the vtable runs) kicks the loop off.
    n.layout(.{ .x = 0, .y = 0, .w = 220, .h = 4 });
    try std.testing.expect(tl.hasActive());
    tl.tick(0);
    tl.tick(400);
    try std.testing.expect(stateOf(n).phase > 0);
}

test "progress: determinate wavy runs the phase loop too (the wave scrolls); flat determinate stays static" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const wavy = try progressIndicator(std.testing.allocator, .{ .progress = 0.6, .wavy = true });
    defer wavy.deinit();
    wavy.layout(.{ .x = 0, .y = 0, .w = 200, .h = 10 });
    try std.testing.expect(tl.hasActive());
    tl.tick(0);
    tl.tick(500);
    try std.testing.expect(stateOf(wavy).elapsed_ms > 0);
    // the wave offset scrolls: two emitted segments at different times differ
    var xs: [32]f32 = undefined;
    var ys_a: [32]f32 = undefined;
    var ys_b: [32]f32 = undefined;
    const s = stateOf(wavy);
    ensureWavePath(wavy, s, 200, 10, wave_len_det);
    const off_a = @mod(s.elapsed_ms / @as(f64, wave_offset_ms), 1);
    _ = emitWaveSegment(s, (@as(f32, @floatCast(off_a)) * wave_len_det) * s.path_scale, (60 + @as(f32, @floatCast(off_a)) * wave_len_det) * s.path_scale, @floatCast(off_a * wave_len_det), 1, 5, 0, 0, &xs, &ys_a);
    tl.tick(600);
    const off_b = @mod(s.elapsed_ms / @as(f64, wave_offset_ms), 1);
    _ = emitWaveSegment(s, (@as(f32, @floatCast(off_b)) * wave_len_det) * s.path_scale, (60 + @as(f32, @floatCast(off_b)) * wave_len_det) * s.path_scale, @floatCast(off_b * wave_len_det), 1, 5, 0, 0, &xs, &ys_b);
    try std.testing.expect(!std.meta.eql(ys_a, ys_b));
    // flat determinate: nothing moves — no animation is registered at all
    const flat = try progressIndicator(std.testing.allocator, .{ .progress = 0.5 });
    defer flat.deinit();
    flat.layout(.{ .x = 0, .y = 0, .w = 200, .h = 4 });
    try std.testing.expect(!stateOf(flat).loop_running);
    try std.testing.expectEqual(@as(usize, 1), tl.animations.items.len); // only the wavy loop
}

test "progress: progressSetValue springs the static value (upstream animateFloatAsState)" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const n = try progressIndicator(std.testing.allocator, .{ .progress = 0.2 });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 200, .h = 4 });
    const s = stateOf(n);
    try std.testing.expectEqual(@as(f32, 0.2), effProgress(s).?);
    // A static write moves the display through the spring, not a snap.
    progressSetValue(n, 0.9);
    try std.testing.expect(s.static_animating);
    tl.tick(0); // lazy start
    tl.tick(50);
    const mid = effProgress(s).?;
    try std.testing.expect(mid > 0.2 and mid < 0.9);
    // Settled: the flag clears, the logical target stands.
    tl.tick(20_000);
    try std.testing.expect(!s.static_animating);
    try std.testing.expectEqual(@as(f32, 0.9), effProgress(s).?);
    // A bound signal routes through the signal path instead.
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.3);
    defer sig.deinit();
    const sn = try progressIndicator(std.testing.allocator, .{ .progress_sig = sig });
    defer sn.deinit();
    progressSetValue(sn, 0.7);
    try std.testing.expectEqual(@as(f32, 0.7), sig.peek());
}

test "progress: linear measures full width x 4 (flat) / 10 (wavy); circular 40x40" {
    const lin = try progressIndicator(std.testing.allocator, .{});
    defer lin.deinit();
    const m = lin.measure(.{ .max_w = 480, .max_h = 600 });
    try std.testing.expectEqual(@as(f32, 480), m.w);
    try std.testing.expectEqual(@as(f32, 4), m.h);
    const wavy = try progressIndicator(std.testing.allocator, .{ .wavy = true });
    defer wavy.deinit();
    const mw = wavy.measure(.{ .max_w = 480, .max_h = 600 });
    try std.testing.expectEqual(@as(f32, 10), mw.h);
    const cir = try progressIndicator(std.testing.allocator, .{ .kind = .circular });
    defer cir.deinit();
    const mc = cir.measure(.{ .max_w = 480, .max_h = 600 });
    try std.testing.expectEqual(@as(f32, 40), mc.w);
    try std.testing.expectEqual(@as(f32, 40), mc.h);
}

test "progress: arc polyline and the wave path stay in bounds" {
    var xs: [arc_segments]f32 = undefined;
    var ys: [arc_segments]f32 = undefined;
    // full circle stays within the 40dp box centered at (20, 20)
    const n = arcPolyline(&xs, &ys, 20, 20, 18, 0, 360);
    try std.testing.expectEqual(arc_segments, n);
    for (0..n) |i| {
        try std.testing.expect(xs[i] >= 20 - 18 - 0.01 and xs[i] <= 20 + 18 + 0.01);
        try std.testing.expect(ys[i] >= 20 - 18 - 0.01 and ys[i] <= 20 + 18 + 0.01);
    }
    // a quarter arc has fewer segments than a full circle
    const q = arcPolyline(&xs, &ys, 20, 20, 18, -90, 90);
    try std.testing.expect(q < n);
    try std.testing.expect(q >= 2);
    // wave path: amplitude bounded by ActiveWaveAmplitude, arc scale sane
    const wavy = try progressIndicator(std.testing.allocator, .{ .wavy = true });
    defer wavy.deinit();
    const s = stateOf(wavy);
    ensureWavePath(wavy, s, 400, wave_height, wave_len_det);
    try std.testing.expect(s.path_n > 2);
    try std.testing.expectEqual(@as(f32, 0), s.path_x[0]);
    try std.testing.expect(s.path_x[s.path_n - 1] >= 400 + 2 * wave_len_det - wave_len_det / 2 - 0.01);
    for (0..s.path_n) |i| try std.testing.expect(@abs(s.path_y[i]) <= wave_amplitude + 0.05);
    try std.testing.expect(s.path_scale > 1 and s.path_scale < 1.2);
    // segment emission covers exactly [d0, d1]
    var xs2: [64]f32 = undefined;
    var ys2: [64]f32 = undefined;
    const cnt = emitWaveSegment(s, 20 * s.path_scale, 60 * s.path_scale, 0, 1, 5, 0, 0, &xs2, &ys2);
    try std.testing.expect(cnt > 10);
    try std.testing.expect(std.math.approxEqAbs(f32, 60, xs2[cnt - 1], 1.5));
}

test "progress: indeterminate keyframes reproduce Compose's two-segment cycle" {
    // t=0: head1 at 0, tail1 at 0 → nothing; t=500: head1 mid-sweep.
    var fr: [4]f32 = undefined;
    indetFractions(0, &fr);
    try std.testing.expectEqual(@as(f32, 0), fr[0]); // tail1
    try std.testing.expectEqual(@as(f32, 0), fr[1]); // head1
    indetFractions(500, &fr);
    try std.testing.expect(fr[1] > fr[0] and fr[0] > 0); // tail chasing head
    indetFractions(1300, &fr);
    try std.testing.expectEqual(@as(f32, 1), fr[1]); // head1 done
    try std.testing.expect(fr[3] > fr[2]); // second line mid-flight
    // circular: progress hits max at 3000ms, additional rotation steps 90deg/1500ms
    try std.testing.expectApproxEqAbs(@as(f32, 0.87), circIndetProgress(3000), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), circIndetProgress(6000), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 90), circAddRotation(1499), 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 360), circAddRotation(5999), 0.5);
}

test "golden: linear progress paints the track and the active segment" {
    const t = theme_mod.light;
    const bar = try progressIndicator(std.testing.allocator, .{ .progress = 0.5, .theme = t });
    defer bar.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 128, 16);
    defer r.deinit();
    bar.layout(.{ .x = 0, .y = 6, .w = 128, .h = 4 });
    r.paint(bar, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the right half is pure track at the vertical center
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(100, 8));
    // the stop dot (upstream drawStopIndicator, active color) sits at the
    // track's end — x = w - stopSize/2 = 126
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(126, 8));
    // the left half is the active segment (progress = 0.5)
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(2, 8));
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(60, 8));
}

test "progress: circular wavy measures 48x48 and builds the ring tables" {
    const wavy = try progressIndicator(std.testing.allocator, .{ .kind = .circular, .wavy = true, .progress = 0.6 });
    defer wavy.deinit();
    const m = wavy.measure(.{ .max_w = 480, .max_h = 600 });
    // CircularContainerSize = WaveSize = 48dp (vs 40dp flat circular).
    try std.testing.expectEqual(@as(f32, 48), m.w);
    try std.testing.expectEqual(@as(f32, 48), m.h);
    const s = stateOf(wavy);
    ensureCircPaths(wavy, s, 48, 48, 1);
    // CircularShapes.update: numVertices = round(2π·(24−2)/15) = 9.
    try std.testing.expectEqual(@as(usize, 9), s.circ_verts);
    // The track ring is a circle at ~21.5 about (24,24): the nominal
    // 48/2 − 4/2 = 22 shrinks a little under normalization (the approximate
    // bounds include the corner-control bulge).
    var tmin: f32 = std.math.inf(f32);
    var tmax: f32 = 0;
    for (0..s.circ_trk.n) |i| {
        const dx = s.circ_trk.x[i] - 24;
        const dy = s.circ_trk.y[i] - 24;
        const ri = @sqrt(dx * dx + dy * dy);
        tmin = @min(tmin, ri);
        tmax = @max(tmax, ri);
    }
    // The progress star oscillates: outer ~21.5, inner ~19 (0.75 + the
    // inner corner rounding pulls it in further than the nominal 16.5).
    var smin: f32 = std.math.inf(f32);
    var smax: f32 = 0;
    for (0..s.circ_prog.n) |i| {
        const dx = s.circ_prog.x[i] - 24;
        const dy = s.circ_prog.y[i] - 24;
        const ri = @sqrt(dx * dx + dy * dy);
        smin = @min(smin, ri);
        smax = @max(smax, ri);
    }
    try std.testing.expect(tmin > 20 and tmax < 22.5);
    try std.testing.expect(tmax - tmin < 1.5); // quasi-circle
    try std.testing.expect(smax > 20 and smax < 22.5);
    try std.testing.expect(smin > 14 and smin < 20);
    try std.testing.expect(smax - smin > 2); // the wave is visible
    // The wrap table closes: duplicated last point, monotone distances.
    try std.testing.expectEqual(s.circ_prog.x[0], s.circ_prog.x[s.circ_prog.n]);
    try std.testing.expectEqual(s.circ_prog.y[0], s.circ_prog.y[s.circ_prog.n]);
    try std.testing.expect(s.circ_prog.d[s.circ_prog.n] > s.circ_prog.d[s.circ_prog.n - 1]);
    const lt = s.circ_trk.totalLen();
    const lp = s.circ_prog.totalLen();
    try std.testing.expectApproxEqAbs(@as(f32, 2 * std.math.pi * 22), lt, 5); // ~138 (faceted)
    try std.testing.expect(lp > 0.8 * lt and lp < 1.5 * lt);
    // amplitude 0 → the progress ring is the plain circle (no-morph branch)
    ensureCircPaths(wavy, s, 48, 48, 0);
    var fmin: f32 = std.math.inf(f32);
    var fmax: f32 = 0;
    for (0..s.circ_prog.n) |i| {
        const dx = s.circ_prog.x[i] - 24;
        const dy = s.circ_prog.y[i] - 24;
        const ri = @sqrt(dx * dx + dy * dy);
        fmin = @min(fmin, ri);
        fmax = @max(fmax, ri);
    }
    try std.testing.expect(fmax - fmin < 0.5); // flat ring
}

test "progress: circular wavy segment emission wraps, rotates and scrolls" {
    const wavy = try progressIndicator(std.testing.allocator, .{ .kind = .circular, .wavy = true, .progress = 0.6 });
    defer wavy.deinit();
    const s = stateOf(wavy);
    ensureCircPaths(wavy, s, 48, 48, 1);
    const lp = s.circ_prog.totalLen();
    // pointAt wraps like the doubled upstream path: pointAt(0) == pointAt(L)
    const p0 = s.circ_prog.pointAt(0);
    const pl = s.circ_prog.pointAt(lp);
    try std.testing.expectApproxEqAbs(p0[0], pl[0], 0.01);
    try std.testing.expectApproxEqAbs(p0[1], pl[1], 0.01);
    var xs: [wave_seg_cap]f32 = undefined;
    var ys: [wave_seg_cap]f32 = undefined;
    // half the ring ~69px of arc → tens of points, all on the star band
    const cnt = s.circ_prog.emit(0, lp / 2, 0, 24, 24, 0, 0, &xs, &ys);
    try std.testing.expect(cnt > 40);
    for (0..cnt) |i| {
        const dx = xs[i] - 24;
        const dy = ys[i] - 24;
        const ri = @sqrt(dx * dx + dy * dy);
        try std.testing.expect(ri > 14 and ri < 22.5);
    }
    // A 90° emitted rotation maps the first point 90° about the center.
    var xs2: [wave_seg_cap]f32 = undefined;
    var ys2: [wave_seg_cap]f32 = undefined;
    _ = s.circ_prog.emit(0, lp / 2, 90, 24, 24, 0, 0, &xs2, &ys2);
    try std.testing.expectApproxEqAbs(24 - (ys[0] - 24), xs2[0], 0.01); // x' = cx − dy
    try std.testing.expectApproxEqAbs(24 + (xs[0] - 24), ys2[0], 0.01); // y' = cy + dx
    // The wave scroll: shifting the segment by the offset changes the
    // emitted curve (offset = elapsed / (verts·1000)).
    s.elapsed_ms = 0;
    const sh0 = circWaveOffset(s) * lp;
    var xa: [wave_seg_cap]f32 = undefined;
    var ya: [wave_seg_cap]f32 = undefined;
    var xb: [wave_seg_cap]f32 = undefined;
    var yb: [wave_seg_cap]f32 = undefined;
    _ = s.circ_prog.emit(sh0, 20 + sh0, -@mod(circWaveOffset(s) * 360, 360), 24, 24, 0, 0, &xa, &ya);
    s.elapsed_ms = 1000; // offset = 1/9 → the wave scrolled one wavelength
    const sh1 = circWaveOffset(s) * lp;
    try std.testing.expectApproxEqAbs(lp / 9, sh1, 0.01);
    _ = s.circ_prog.emit(sh1, 20 + sh1, -@mod(circWaveOffset(s) * 360, 360), 24, 24, 0, 0, &xb, &yb);
    try std.testing.expect(!std.meta.eql(xa[0..10], xb[0..10]));
}

test "progress: circular wavy mid-amplitude morphs between ring and star" {
    const wavy = try progressIndicator(std.testing.allocator, .{ .kind = .circular, .wavy = true, .progress = 0.6 });
    defer wavy.deinit();
    const s = stateOf(wavy);
    // amp 0.5 → the circle→star Morph branch: the progress outline is no
    // longer the flat ring, but not yet the full-depth star.
    ensureCircPaths(wavy, s, 48, 48, 0.5);
    try std.testing.expectEqual(@as(f32, 0.5), s.circ_amp);
    var rmin: f32 = std.math.inf(f32);
    var rmax: f32 = 0;
    for (0..s.circ_prog.n) |i| {
        const dx = s.circ_prog.x[i] - 24;
        const dy = s.circ_prog.y[i] - 24;
        const ri = @sqrt(dx * dx + dy * dy);
        rmin = @min(rmin, ri);
        rmax = @max(rmax, ri);
    }
    // Star at full amp spans ~[16.5, 21.5]; the half morph's excursion is
    // roughly half that but strictly positive.
    try std.testing.expect(rmax - rmin > 0.8);
    try std.testing.expect(rmax - rmin < 4);
    try std.testing.expect(rmin > 14);
    try std.testing.expect(rmax < 22.5);
    // The track ring stays a quasi-circle regardless of the amp morph.
    var tmin: f32 = std.math.inf(f32);
    var tmax: f32 = 0;
    for (0..s.circ_trk.n) |i| {
        const dx = s.circ_trk.x[i] - 24;
        const dy = s.circ_trk.y[i] - 24;
        const ri = @sqrt(dx * dx + dy * dy);
        tmin = @min(tmin, ri);
        tmax = @max(tmax, ri);
    }
    try std.testing.expect(tmax - tmin < 1.5);
    // Quantized amp keys share the cached table (1/12 steps): the cache
    // hit check uses the quantized key, not the raw display value.
    const table_ptr = s.circ_prog.x.ptr;
    ensureCircPaths(wavy, s, 48, 48, 0.49); // same amp_key = 6/12
    try std.testing.expectEqual(table_ptr, s.circ_prog.x.ptr);
}

test "progress: wavy amplitude tweens on target change, snapping the first read" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const wavy = try progressIndicator(std.testing.allocator, .{ .kind = .circular, .wavy = true, .progress = 0.6 });
    defer wavy.deinit();
    const s = stateOf(wavy);
    // First read snaps (Animatable(initialValue = target)): no intro ramp.
    updateAmp(wavy, s, 1);
    try std.testing.expectEqual(@as(f32, 1), s.amp_display);
    try std.testing.expect(!s.amp_running);
    // A target change launches the 500ms tween. The timeline's lazy start
    // pins start_ms at the first tick after play, so elapsed = t - 50 here.
    // Decreasing uses emphasized-accelerate cubic-bezier(0.3, 0, 0.8, 0.15):
    // a very slow start (at x=0.11 the eased progress is still < 1%), then
    // a rush at the end.
    tl.tick(0);
    updateAmp(wavy, s, 0);
    try std.testing.expect(s.amp_running);
    tl.tick(50); // lazy start pins here (elapsed 0)
    tl.tick(100); // elapsed 50 → x = 0.1 → eased ≈ 0.01 → amp ≈ 0.99
    try std.testing.expect(s.amp_display > 0.95);
    tl.tick(450); // elapsed 400 → x = 0.8 → eased ≈ 0.48 → amp ≈ 0.52
    // Linear would be at 0.2 here: the accelerate curve lags until the end.
    try std.testing.expect(s.amp_display > 0.4);
    try std.testing.expect(s.amp_display < 0.65);
    tl.tick(550); // elapsed 500 → completes
    try std.testing.expectEqual(@as(f32, 0), s.amp_display);
    try std.testing.expect(!s.amp_running);
    // Increasing runs the standard (emphasized) cubic-bezier(0.2, 0, 0, 1):
    // already ~19% at x=0.1 and ~75% at x=0.35.
    updateAmp(wavy, s, 1);
    try std.testing.expect(s.amp_running);
    tl.tick(600); // lazy start (elapsed 0)
    tl.tick(650); // elapsed 50 → x = 0.1 → eased ≈ 0.19
    try std.testing.expect(s.amp_display > 0.1);
    try std.testing.expect(s.amp_display < 0.4);
    tl.tick(775); // elapsed 175 → x = 0.35 → eased ≈ 0.75
    try std.testing.expect(s.amp_display > 0.7);
    tl.tick(1100); // elapsed 500 → completes
    try std.testing.expectEqual(@as(f32, 1), s.amp_display);
    try std.testing.expect(!s.amp_running);
}

test "progress: circular wavy determinate runs the phase loop; flat circular determinate stays static" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const wavy = try progressIndicator(std.testing.allocator, .{ .kind = .circular, .wavy = true, .progress = 0.6 });
    defer wavy.deinit();
    wavy.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    try std.testing.expect(tl.hasActive()); // the wave scrolls
    tl.tick(0);
    tl.tick(500);
    try std.testing.expect(stateOf(wavy).elapsed_ms > 0);
    // flat circular determinate: nothing moves — no animation at all
    const flat = try progressIndicator(std.testing.allocator, .{ .kind = .circular, .progress = 0.5 });
    defer flat.deinit();
    flat.layout(.{ .x = 0, .y = 0, .w = 40, .h = 40 });
    try std.testing.expect(!stateOf(flat).loop_running);
    try std.testing.expectEqual(@as(usize, 1), tl.animations.items.len);
}

test "golden: circular wavy determinate paints the wavy arc and the track ring" {
    const t = theme_mod.light;
    const wavy = try progressIndicator(std.testing.allocator, .{ .kind = .circular, .wavy = true, .progress = 0.5, .theme = t });
    defer wavy.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 56, 56);
    defer r.deinit();
    wavy.layout(.{ .x = 4, .y = 4, .w = 48, .h = 48 });
    r.paint(wavy, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // The path starts at 3 o'clock and winds clockwise: at progress 0.5 the
    // wavy arc covers the bottom half (right -> bottom -> left), the plain
    // track ring the top half, with the gap on both sides.
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(49, 28)); // arc start (3 o'clock)
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(28, 48)); // bottom of the wave
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(28, 6)); // track top
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(13, 13)); // track upper-left
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(43, 13)); // track upper-right
    // The active/track gap: a ring-band pixel past the left end is empty,
    // and the wedge before the arc start holds no full-strength pixel of
    // either stroke (only cap-edge AA haze).
    try std.testing.expectEqual(@as(u32, 0x000000FF), f.pixelAt(7, 23)); // past the left end
    const gap = Rect{ .x = 46, .y = 25, .w = 4, .h = 1 };
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(gap, t.colors.primary));
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(gap, t.colors.secondary_container));
}

test "golden: circular wavy indeterminate paints a small wavy arc and the track ring" {
    const t = theme_mod.light;
    const wavy = try progressIndicator(std.testing.allocator, .{ .kind = .circular, .wavy = true, .theme = t });
    defer wavy.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 56, 56);
    defer r.deinit();
    // No timeline: the schedules sit at t=0 — sweep 0.1, rotate +90°.
    wavy.layout(.{ .x = 4, .y = 4, .w = 48, .h = 48 });
    r.paint(wavy, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // The 36° wavy arc lands at bottom-left (path 0..36° + 90° -> 90..126°);
    // the track fills the rest of the ring minus the adjacent gap.
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(20, 45)); // the small arc
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(28, 6)); // track top
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(48, 28)); // track right
    // The gap between the arc's tail and the track start holds no
    // full-strength pixel of either (only cap-edge AA haze).
    const gap = Rect{ .x = 7, .y = 41, .w = 6, .h = 9 };
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(gap, t.colors.primary));
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(gap, t.colors.secondary_container));
}

test "golden: circular determinate paints the ring and a quarter arc" {
    const t = theme_mod.light;
    const cir = try progressIndicator(std.testing.allocator, .{ .kind = .circular, .progress = 0.25, .theme = t });
    defer cir.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 48, 48);
    defer r.deinit();
    cir.layout(.{ .x = 4, .y = 4, .w = 40, .h = 40 });
    r.paint(cir, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the arc runs from the top (-90deg) clockwise 90deg (progress = 0.25):
    // top and right points are on the active arc, bottom and left stay track
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(24, 6)); // top (arc start)
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(42, 24)); // right (arc end)
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(24, 42)); // bottom
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(6, 24)); // left
}
