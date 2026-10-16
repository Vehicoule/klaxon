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
//     indicatorAmplitude; the 450ms cross-fade tween is skipped — progress
//     is a construction-time constant in this API, deviation documented)
//   - circular determinate: gap-adjacent track arc + round-capped active arc
//   - circular indeterminate: keyframed progress 0.1<->0.87 (Standard easing),
//     4x90deg additional-rotation schedule (EmphasizedDecelerate) + 1080deg
//     global rotation over 6000ms
//
// Deliberate deviations: upstream animates progress changes with a spring
// (ProgressAnimationSpec) — Klaxon takes progress as a construction-time
// value; the wave offset/amplitude micro-animations on attach are skipped
// (amplitude starts at target). Circular WAVY (CircularWavyProgressIndicator,
// 48dp) is not yet exposed — `wavy` is linear-only here.
//
// Painting: everything emits polylines (kx_stroke_polyline) — the wave path
// is sampled at ~1px x-resolution into a layout-allocated arc-length table
// (rebuilt on size/λ change only; 0 allocs per frame).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const anim = ui.anim;
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
const arc_segments: usize = 48; // per full circle
const wave_seg_cap: usize = 2048; // emitted segment buffer (adaptive stride)
const linear_indet_ms: u32 = 1750; // LinearAnimationDuration
const circular_indet_ms: u32 = 6000; // CircularAnimationProgressDuration
const wave_offset_ms: f32 = 1000; // waveSpeed = wavelength/s → 1 cycle/s

pub const ProgressKind = enum { linear, circular };

pub const ProgressOptions = struct {
    kind: ProgressKind = .linear,
    /// 0..1 determinate; null = indeterminate (loops forever).
    progress: ?f32 = null,
    wavy: bool = false, // linear only (M3E)
    theme: Theme = theme_mod.light,
};

/// Easing curves used by the indeterminate keyframes (MotionTokens).
fn easeEmphAccel(x: f32) f32 {
    return anim.cubicBezier(0.3, 0.0, 0.8, 0.15, x);
}
fn easeEmphDecel(x: f32) f32 {
    return anim.cubicBezier(0.05, 0.7, 0.1, 1.0, x);
}
fn easeStandard(x: f32) f32 {
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
};

fn stateOf(n: *Node) *ProgressState {
    return @ptrCast(@alignCast(n.state.?));
}

fn progressMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const h: f32 = if (s.opts.kind == .linear) (if (s.opts.wavy) wave_height else linear_thickness) else circular_size;
    // LinearIndicatorWidth = 240dp when unbounded (upstream fixed size).
    const w: f32 = if (s.opts.kind == .circular) circular_size else (if (std.math.isFinite(c.max_w)) c.max_w else 240);
    return c.constrain(.{ .w = w, .h = h });
}

/// The phase loop runs while the widget lives when anything moves:
/// indeterminate sweeps/rotates on it, and the M3E wave scrolls on it even
/// when determinate. Flat determinate + determinate circular stay static —
/// nothing moves between value writes, so no animation is registered and
/// the host idles.
fn wantsPhaseLoop(s: *const ProgressState) bool {
    return s.opts.progress == null or (s.opts.kind == .linear and s.opts.wavy);
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
fn arcPolyline(xs: []f32, ys: []f32, cx: f32, cy: f32, r: f32, start_deg: f32, sweep_deg: f32) usize {
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
    const lambda: f32 = if (s.opts.progress != null) wave_len_det else wave_len_indet;
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
fn circIndetProgress(t_ms: f32) f32 {
    if (t_ms <= 3000) return 0.1 + (0.87 - 0.1) * easeStandard(t_ms / 3000);
    return 0.87 + (0.1 - 0.87) * ((t_ms - 3000) / 3000);
}

fn circAddRotation(t_ms: f32) f32 {
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
                if (s.opts.progress) |p_raw| {
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
                var amp: f32 = 1;
                if (s.opts.progress) |p_raw| {
                    const p = clamp01(p_raw);
                    fr[0] = 0;
                    fr[1] = p;
                    amp = wavyAmplitude(p);
                } else {
                    indetFractions(@mod(elapsed, @as(f32, @floatFromInt(linear_indet_ms))), &fr);
                    n_frac = 4;
                }
                drawWavyLinear(n, s, ctx, b, fr[0..n_frac], amp, wave_offset, active, track, rtl);
                if (s.opts.progress) |p_raw| {
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
            const cx = b.x + b.w / 2;
            const cy = b.y + b.h / 2;
            const r = (@min(b.w, b.h) - circular_stroke) / 2;
            var xs: [arc_segments]f32 = undefined;
            var ys: [arc_segments]f32 = undefined;
            if (s.opts.progress) |p_raw| {
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
        },
    }
}

fn progressDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel)); // the update cb points at this node
    if (s.path_x.len > 0) {
        n.allocator.free(s.path_x);
        n.allocator.free(s.path_y);
        n.allocator.free(s.path_d);
    }
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
    if (s.opts.progress == null) return linear_indet_ms;
    return @intFromFloat(wave_offset_ms); // determinate wavy: only the wave scrolls
}

fn progressLoopCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (wantsPhaseLoop(s)) startPhaseLoop(n, s); // loop forever
}

/// Linear + circular progress indicators (M3E).
pub fn progressIndicator(allocator: std.mem.Allocator, opts: ProgressOptions) !*Node {
    const node = try Node.create(allocator, &progress_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(ProgressState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts };
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
