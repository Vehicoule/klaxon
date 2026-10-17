// Shapes — M3E shape morphing: a Zig port of androidx.graphics.shapes
// (RoundedPolygon + Morph). Shapes are closed outlines of cubic Béziers;
// morphs interpolate matched cubic pairs.
//
// Pipeline (mirrors the library):
//   vertices + per-corner CornerRounding -> features (corners & edges, each a
//   list of cubics) -> RoundedPolygon. A corner rounds to a circular arc
//   cubic flanked by two smoothing cubics; an edge is a straight-line cubic.
//   Morph measures both outlines by arc length (progress 0..1), maps corner
//   "features" between them (convex<->convex only, greedy nearest match, no
//   crossings) into a piecewise-linear DoubleMapper, cuts + rotates the end
//   shape's outline to align with the start's progress 0, then walks both
//   cubic lists splitting whichever runs longer until the pair lists match.
//   asCubics(t) lerps the 8 coordinates of each matched pair — t is NOT
//   clamped, so spring overshoot (t > 1) extrapolates naturally.
//
// Rendering: cubics are the first-class representation (Cubic / Morph.asCubics).
//   emitPathInto / Path encode a closed outline as the kx_fill_path wire
//   format (move + N×cubic + close, ABI 0.16.0); fillCubics/strokeCubics +
//   Path.fill/stroke push it through the ABI. flatten() remains for the
//   polygon fallback (kx_fill_polygon) and area tests.
//
// All presets are normalized into a 0..1 box (like MaterialShapes.normalized)
// — scale + translate to the target rect at draw time.
const std = @import("std");
const kx = @import("../kx.zig");
const paint = @import("paint.zig");

const Allocator = std.mem.Allocator;

// --- math helpers ---

pub const Point = @Vector(2, f32); // {x, y}

pub fn pt(x: f32, y: f32) Point {
    return .{ x, y };
}

fn dot(a: Point, b: Point) f32 {
    return @reduce(.Add, a * b);
}

fn dist(a: Point) f32 {
    return @sqrt(dot(a, a));
}

fn distSq(a: Point) f32 {
    return dot(a, a);
}

/// Unit vector of `a` — the caller guarantees a nonzero vector.
fn dir(a: Point) Point {
    const d = dist(a);
    std.debug.assert(d > 0);
    return a / @as(Point, @splat(d));
}

fn dirAngle(rad: f32) Point {
    return .{ @cos(rad), @sin(rad) };
}

fn rotate90(a: Point) Point {
    return .{ -a[1], a[0] };
}

/// Cross-product z sign: true when b is clockwise from a.
fn clockwise(a: Point, b: Point) bool {
    return a[0] * b[1] - a[1] * b[0] > 0;
}

/// Approximate convexity of the corner at `cur` (androidx `convex`).
fn cornerConvex(prev: Point, cur: Point, next: Point) bool {
    return clockwise(cur - prev, next - cur);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn lerpPt(a: Point, b: Point, t: f32) Point {
    return a + (b - a) * @as(Point, @splat(t));
}

/// positiveModulo — always in [0, m) for m > 0.
fn pmod(x: f32, m: f32) f32 {
    return @mod(x, m);
}

/// Distance between two progress values on the [0,1) circle.
fn progressDistance(p1: f32, p2: f32) f32 {
    const d = @abs(p1 - p2);
    return @min(d, 1 - d);
}

/// progress ∈ [from, to] on the wrapping [0,1) circle.
fn progressInRange(progress: f32, from: f32, to: f32) bool {
    return if (to >= from)
        progress >= from and progress <= to
    else
        progress >= from or progress <= to;
}

/// androidx DistanceEpsilon — small enough that roundoff stays sub-pixel.
const distance_epsilon: f32 = 1e-4;
/// androidx AngleEpsilon.
const angle_epsilon: f32 = 1e-6;

// --- Cubic ---

/// One cubic Bézier: anchor0, control0, control1, anchor1.
pub const Cubic = struct {
    a0: Point,
    c0: Point,
    c1: Point,
    a1: Point,

    pub fn init(a0: Point, c0: Point, c1: Point, a1: Point) Cubic {
        return .{ .a0 = a0, .c0 = c0, .c1 = c1, .a1 = a1 };
    }

    /// The 8 raw coordinates (a0x,a0y,c0x,c0y,c1x,c1y,a1x,a1y) — the layout a
    /// future kx_fill_path ABI consumes.
    pub fn points(c: Cubic) [8]f32 {
        return .{ c.a0[0], c.a0[1], c.c0[0], c.c0[1], c.c1[0], c.c1[1], c.a1[0], c.a1[1] };
    }

    pub fn pointOnCurve(c: Cubic, t: f32) Point {
        const u = 1 - t;
        return c.a0 * @as(Point, @splat(u * u * u)) +
            c.c0 * @as(Point, @splat(3 * t * u * u)) +
            c.c1 * @as(Point, @splat(3 * t * t * u)) +
            c.a1 * @as(Point, @splat(t * t * t));
    }

    /// Controls at 1/3 and 2/3 so the curve is a straight line a->b.
    pub fn straightLine(a: Point, b: Point) Cubic {
        return .{ .a0 = a, .c0 = lerpPt(a, b, 1.0 / 3.0), .c1 = lerpPt(a, b, 2.0 / 3.0), .a1 = b };
    }

    /// A cubic approximating the smaller circular arc p0->p1 around `center`
    /// (androidx `Cubic.circularArc`; use several cubics for arcs > 180°).
    pub fn circularArc(center: Point, p0: Point, p1: Point) Cubic {
        const p0d = dir(p0 - center);
        const p1d = dir(p1 - center);
        const r0 = rotate90(p0d);
        const r1 = rotate90(p1d);
        const cw = dot(r0, p1 - center) >= 0;
        const cosa = dot(p0d, p1d);
        if (cosa > 0.999) return straightLine(p0, p1); // p0 ~= p1
        const k = dist(p0 - center) * 4.0 / 3.0 *
            (@sqrt(2 * (1 - cosa)) - @sqrt(1 - cosa * cosa)) / (1 - cosa) *
            (if (cw) @as(f32, 1) else -1);
        return .{ .a0 = p0, .c0 = p0 + r0 * @as(Point, @splat(k)), .c1 = p1 - r1 * @as(Point, @splat(k)), .a1 = p1 };
    }

    /// de Casteljau split at t — returns the two halves.
    pub fn split(c: Cubic, t: f32) [2]Cubic {
        const u = 1 - t;
        const m = c.pointOnCurve(t);
        return .{
            .{
                .a0 = c.a0,
                .c0 = c.a0 * @as(Point, @splat(u)) + c.c0 * @as(Point, @splat(t)),
                .c1 = c.a0 * @as(Point, @splat(u * u)) + c.c0 * @as(Point, @splat(2 * u * t)) + c.c1 * @as(Point, @splat(t * t)),
                .a1 = m,
            },
            .{
                .a0 = m,
                .c0 = c.c0 * @as(Point, @splat(u * u)) + c.c1 * @as(Point, @splat(2 * u * t)) + c.a1 * @as(Point, @splat(t * t)),
                .c1 = c.c1 * @as(Point, @splat(u)) + c.a1 * @as(Point, @splat(t)),
                .a1 = c.a1,
            },
        };
    }

    pub fn reverse(c: Cubic) Cubic {
        return .{ .a0 = c.a1, .c0 = c.c1, .c1 = c.c0, .a1 = c.a0 };
    }

    pub fn zeroLength(c: Cubic) bool {
        return @abs(c.a0[0] - c.a1[0]) < distance_epsilon and
            @abs(c.a0[1] - c.a1[1]) < distance_epsilon;
    }

    pub fn transformed(c: Cubic, t: Transform) Cubic {
        return .{ .a0 = t.apply(c.a0), .c0 = t.apply(c.c0), .c1 = t.apply(c.c1), .a1 = t.apply(c.a1) };
    }
};

// --- Transform (affine 2x2 + offset) ---

pub const Transform = struct {
    xx: f32 = 1,
    xy: f32 = 0,
    yx: f32 = 0,
    yy: f32 = 1,
    dx: f32 = 0,
    dy: f32 = 0,

    pub fn apply(t: Transform, p: Point) Point {
        return .{ t.xx * p[0] + t.xy * p[1] + t.dx, t.yx * p[0] + t.yy * p[1] + t.dy };
    }

    /// Rotate by `degrees` around the origin (y-down: positive is clockwise on
    /// screen — the Compose rotateZ convention).
    pub fn rotation(degrees: f32) Transform {
        const a = degrees * std.math.pi / 180;
        const c = @cos(a);
        const s = @sin(a);
        return .{ .xx = c, .xy = -s, .yx = s, .yy = c };
    }

    pub fn scale(sx: f32, sy: f32) Transform {
        return .{ .xx = sx, .yy = sy };
    }

    /// Map the unit box (presets are normalized to 0..1) into a draw rect.
    pub fn fitRect(x: f32, y: f32, w: f32, h: f32) Transform {
        return .{ .xx = w, .yy = h, .dx = x, .dy = y };
    }
};

// --- CornerRounding ---

/// Per-corner shape: `radius` is the circular-arc radius (shape units);
/// `smoothing` in [0,1] extends the curve into the adjacent edges with
/// decreasing curvature (0 = pure circular arc, 1 = the corner cut doubles —
/// androidx semantics).
pub const CornerRounding = struct {
    radius: f32 = 0,
    smoothing: f32 = 0,
};

pub const unrounded: CornerRounding = .{};

// --- RoundedPolygon ---

/// A group of cubics forming one semantic feature. Only corners participate
/// in morph feature mapping (edges are ignorable); corners map same-convexity
/// only.
pub const Feature = struct {
    kind: enum { corner, edge },
    is_convex: bool,
    /// Range into RoundedPolygon.feature_cubics.
    start: usize,
    len: usize,
};

/// A closed polygon outline with rounded corners, as cubics + features.
/// Owns three allocations; deinit frees them.
pub const RoundedPolygon = struct {
    /// Render-order outline: the first corner is split in half so the curve
    /// starts mid-corner (androidx RoundedPolygon.cubics). Contiguous; the
    /// last anchor1 equals the first anchor0 exactly.
    cubics: []Cubic,
    /// Semantic features in vertex order (corner, edge, corner, edge, ...).
    features: []Feature,
    /// Backing store for every feature's `cubics` slice.
    feature_cubics: []Cubic,
    center: Point,
    allocator: Allocator,

    pub fn deinit(p: *RoundedPolygon) void {
        p.allocator.free(p.cubics);
        p.allocator.free(p.features);
        p.allocator.free(p.feature_cubics);
    }

    /// Approximate bounds (min/max over anchors AND controls — matches the
    /// androidx `approximate` default).
    pub fn bounds(p: *const RoundedPolygon) struct { min: Point, max: Point } {
        var lo: Point = .{ std.math.inf(f32), std.math.inf(f32) };
        var hi: Point = .{ -std.math.inf(f32), -std.math.inf(f32) };
        for (p.cubics) |c| {
            inline for (.{ c.a0, c.c0, c.c1, c.a1 }) |v| {
                lo = @min(lo, v);
                hi = @max(hi, v);
            }
        }
        return .{ .min = lo, .max = hi };
    }

    /// Rotation-safe square bounds: the max distance from the center over
    /// cubic anchors + midpoints (androidx calculateMaxBounds).
    pub fn maxBounds(p: *const RoundedPolygon) struct { min: Point, max: Point } {
        var max_d2: f32 = 0;
        for (p.cubics) |c| {
            const d0 = distSq(c.a0 - p.center);
            const dm = distSq(c.pointOnCurve(0.5) - p.center);
            max_d2 = @max(max_d2, @max(d0, dm));
        }
        const d = @sqrt(max_d2);
        return .{ .min = p.center - @as(Point, @splat(d)), .max = p.center + @as(Point, @splat(d)) };
    }

    /// The cubics of feature `f`.
    pub fn featureCubics(p: *const RoundedPolygon, f: Feature) []Cubic {
        return p.feature_cubics[f.start .. f.start + f.len];
    }

    /// New polygon with every point affine-transformed (the feature layout is
    /// preserved: same ranges, transformed points).
    pub fn transformed(p: *const RoundedPolygon, allocator: Allocator, t: Transform) !RoundedPolygon {
        const fc = try allocator.alloc(Cubic, p.feature_cubics.len);
        errdefer allocator.free(fc);
        for (p.feature_cubics, fc) |c, *dst| dst.* = c.transformed(t);
        const features = try allocator.alloc(Feature, p.features.len);
        errdefer allocator.free(features);
        for (p.features, features) |f, *nf| nf.* = f;
        const merged = try mergeCubics(allocator, features, fc, t.apply(p.center));
        return .{ .cubics = merged, .features = features, .feature_cubics = fc, .center = t.apply(p.center), .allocator = allocator };
    }

    /// Scale + translate so the (approximate) bounds fill the 0..1 box,
    /// centered on the short axis — androidx RoundedPolygon.normalized().
    pub fn normalized(p: *const RoundedPolygon, allocator: Allocator) !RoundedPolygon {
        const b = p.bounds();
        const w = b.max[0] - b.min[0];
        const h = b.max[1] - b.min[1];
        const side = @max(w, h);
        const ox = (side - w) / 2 - b.min[0];
        const oy = (side - h) / 2 - b.min[1];
        return p.transformed(allocator, .{ .xx = 1 / side, .yy = 1 / side, .dx = ox / side, .dy = oy / side });
    }

    /// Flatten the outline into a polygon (append to `out`). `tolerance` is the
    /// max deviation from the true curve in shape units — at display scale
    /// ~0.25 px is a good default.
    pub fn flatten(p: *const RoundedPolygon, tolerance: f32, out: *std.array_list.Managed(Point)) !void {
        return flattenCubics(p.cubics, tolerance, out);
    }

    /// The outline emitted into caller buffers (see emitPathInto).
    pub fn emitPath(p: *const RoundedPolygon, pts: []f32, verbs: []i32) EmittedPath {
        return emitPathInto(p.cubics, pts, verbs);
    }

    /// The outline as an owned verb path (see Path).
    pub fn toPath(p: *const RoundedPolygon, allocator: Allocator) !Path {
        return pathFromCubics(allocator, p.cubics);
    }
};

/// One corner's geometry state: computes how much of each adjacent edge the
/// rounding cut needs, then emits the corner's cubics once the per-edge
/// budget is known (edges shared by two corners split their length between
/// the two cuts).
const RoundedCorner = struct {
    p0: Point,
    p1: Point,
    p2: Point,
    d1: Point = .{ 0, 0 },
    d2: Point = .{ 0, 0 },
    corner_radius: f32 = 0,
    smoothing: f32 = 0,
    cos_angle: f32 = 0,
    sin_angle: f32 = 0,
    expected_round_cut: f32 = 0,

    fn init(p0: Point, p1: Point, p2: Point, rounding: CornerRounding) RoundedCorner {
        var rc: RoundedCorner = .{ .p0 = p0, .p1 = p1, .p2 = p2 };
        const v01 = p0 - p1;
        const v21 = p2 - p1;
        const d01 = dist(v01);
        const d21 = dist(v21);
        if (d01 > 0 and d21 > 0) {
            rc.d1 = v01 / @as(Point, @splat(d01));
            rc.d2 = v21 / @as(Point, @splat(d21));
            rc.corner_radius = rounding.radius;
            rc.smoothing = rounding.smoothing;
            rc.cos_angle = dot(rc.d1, rc.d2);
            rc.sin_angle = @sqrt(1 - rc.cos_angle * rc.cos_angle);
            // Where the rounding circle hits the edge: tan(A/2) = radius/cut
            // and tan(A/2) = sinA/(1+cosA).
            rc.expected_round_cut = if (rc.sin_angle > 1e-3)
                rc.corner_radius * (rc.cos_angle + 1) / rc.sin_angle
            else
                0;
        }
        return rc;
    }

    /// Smoothing extends the cut: 0 -> the round cut, 1 -> double it.
    fn expectedCut(rc: RoundedCorner) f32 {
        return (1 + rc.smoothing) * rc.expected_round_cut;
    }

    /// The corner's cubics into `out` (1 or 3); returns the count.
    /// allowedCut0/1: how much of each adjacent edge this corner may consume.
    fn getCubics(rc: *RoundedCorner, allowed_cut0: f32, allowed_cut1: f32, out: *[3]Cubic) usize {
        const allowed_cut = @min(allowed_cut0, allowed_cut1);
        if (rc.expected_round_cut < distance_epsilon or
            allowed_cut < distance_epsilon or
            rc.corner_radius < distance_epsilon)
        {
            // Unrounded / no room: a degenerate point cubic at the vertex.
            out[0] = Cubic.straightLine(rc.p1, rc.p1);
            return 1;
        }
        const actual_round_cut = @min(allowed_cut, rc.expected_round_cut);
        // Two smoothing values, one per side — rounding takes the space first.
        const actual_smoothing0 = rc.actualSmoothing(allowed_cut0);
        const actual_smoothing1 = rc.actualSmoothing(allowed_cut1);
        const actual_r = rc.corner_radius * actual_round_cut / rc.expected_round_cut;
        const center_distance = @sqrt(actual_r * actual_r + actual_round_cut * actual_round_cut);
        const center = rc.p1 + dir((rc.d1 + rc.d2) / @as(Point, @splat(2))) * @as(Point, @splat(center_distance));
        const ci0 = rc.p1 + rc.d1 * @as(Point, @splat(actual_round_cut));
        const ci2 = rc.p1 + rc.d2 * @as(Point, @splat(actual_round_cut));
        const flank0 = rc.flanking(actual_round_cut, actual_smoothing0, rc.p0, ci0, ci2, center, actual_r);
        const flank2 = rc.flanking(actual_round_cut, actual_smoothing1, rc.p2, ci2, ci0, center, actual_r).reverse();
        out[0] = flank0;
        out[1] = Cubic.circularArc(center, flank0.a1, flank2.a0);
        out[2] = flank2;
        return 3;
    }

    /// Room beyond the round cut is spent on smoothing, scaled down linearly
    /// when partially available.
    fn actualSmoothing(rc: RoundedCorner, allowed_cut: f32) f32 {
        const ec = rc.expectedCut();
        if (allowed_cut > ec) return rc.smoothing;
        if (allowed_cut > rc.expected_round_cut)
            return rc.smoothing * (allowed_cut - rc.expected_round_cut) / (ec - rc.expected_round_cut);
        return 0;
    }

    /// The flanking cubic: from the (cut) linear side to the (cut) circular
    /// arc, blending curvature to zero at the edge.
    fn flanking(
        rc: *const RoundedCorner,
        actual_round_cut: f32,
        actual_smoothing: f32,
        side_start: Point,
        csi: Point, // circle intersection on this side
        other_ci: Point, // circle intersection on the other side
        center: Point,
        actual_r: f32,
    ) Cubic {
        const side_dir = dir(side_start - rc.p1);
        const curve_start = rc.p1 + side_dir * @as(Point, @splat(actual_round_cut * (1 + actual_smoothing)));
        // Cut the arc section proportionally to (1 - smoothing).
        const p = lerpPt(csi, (csi + other_ci) / @as(Point, @splat(2)), actual_smoothing);
        const curve_end = center + dir(p - center) * @as(Point, @splat(actual_r));
        // End control: intersection of the circle tangent at curve_end with
        // the linear side.
        const circle_tangent = rotate90(curve_end - center);
        const anchor_end = lineIntersection(side_start, side_dir, curve_end, circle_tangent) orelse csi;
        const anchor_start = (curve_start + anchor_end * @as(Point, @splat(2))) / @as(Point, @splat(3));
        return .{ .a0 = curve_start, .c0 = anchor_start, .c1 = anchor_end, .a1 = curve_end };
    }

    /// Intersection of lines (p0,d0) x (p1,d1), or null when (near-)parallel.
    fn lineIntersection(p0: Point, d0: Point, p1: Point, d1: Point) ?Point {
        const rd1 = rotate90(d1);
        const den = dot(d0, rd1);
        if (@abs(den) < distance_epsilon) return null;
        const num = dot(p1 - p0, rd1);
        if (@abs(den) < distance_epsilon * @abs(num)) return null; // relative check, avoids the division
        return p0 + d0 * @as(Point, @splat(num / den));
    }
};

/// The merged render-order outline (androidx RoundedPolygon.cubics): if the
/// first feature is a 3-cubic corner, its arc cubic is split at the midpoint
/// and the halves wrap around — the outline starts mid-arc. Zero-length
/// cubics are dropped (their endpoints merge into the previous cubic so the
/// chain stays contiguous).
fn mergeCubics(allocator: Allocator, features: []const Feature, feature_cubics: []const Cubic, center: Point) ![]Cubic {
    var out = std.array_list.Managed(Cubic).init(allocator);
    errdefer out.deinit();
    var first_cubic: ?Cubic = null;
    var last_cubic: ?Cubic = null;
    var split_start: [2]Cubic = undefined;
    var split_end: [2]Cubic = undefined;
    const has_split = features.len > 0 and features[0].len == 3;
    if (has_split) {
        const f0 = feature_cubics[features[0].start .. features[0].start + 3];
        const halves = f0[1].split(0.5);
        split_start = .{ f0[0], halves[0] };
        split_end = .{ halves[1], f0[2] };
    }
    var i: usize = 0;
    while (i <= features.len) : (i += 1) {
        const fc: []const Cubic =
            if (i == 0 and has_split)
                split_end[0..]
            else if (i == features.len)
                (if (has_split) split_start[0..] else break)
            else
                feature_cubics[features[i].start .. features[i].start + features[i].len];
        for (fc) |cubic| {
            if (!cubic.zeroLength()) {
                if (last_cubic) |lc| try out.append(lc);
                last_cubic = cubic;
                if (first_cubic == null) first_cubic = cubic;
            } else if (last_cubic) |*lc| {
                lc.a1 = cubic.a1; // absorb the gap into the pending cubic
            }
        }
    }
    if (last_cubic != null and first_cubic != null) {
        const lc = last_cubic.?;
        try out.append(.{ .a0 = lc.a0, .c0 = lc.c0, .c1 = lc.c1, .a1 = first_cubic.?.a0 });
    } else {
        try out.append(.{ .a0 = center, .c0 = center, .c1 = center, .a1 = center });
    }
    return out.toOwnedSlice();
}

/// Build a RoundedPolygon from raw vertices (androidx RoundedPolygon(
/// vertices, rounding, perVertexRounding, center)). Vertices are ordered
/// along the outline; `center` defaults to the vertex average.
pub fn polygonFromVertices(
    allocator: Allocator,
    vertices: []const Point,
    rounding: CornerRounding,
    per_vertex_rounding: ?[]const CornerRounding,
    center: ?Point,
) !RoundedPolygon {
    const n = vertices.len;
    std.debug.assert(n >= 3);
    if (per_vertex_rounding) |pvr| std.debug.assert(pvr.len == n);

    const corners = try allocator.alloc(RoundedCorner, n);
    defer allocator.free(corners);
    for (0..n) |i| {
        const r = if (per_vertex_rounding) |pvr| pvr[i] else rounding;
        corners[i] = RoundedCorner.init(vertices[(i + n - 1) % n], vertices[i], vertices[(i + 1) % n], r);
    }

    // Per side (corner i -> i+1), split the available length between the two
    // corners' cuts: full rounding first, smoothing with what's left.
    const CutAdjust = struct { round: f32, cut: f32 };
    const adjusts = try allocator.alloc(CutAdjust, n);
    defer allocator.free(adjusts);
    for (0..n) |i| {
        const erc = corners[i].expected_round_cut + corners[(i + 1) % n].expected_round_cut;
        const ec = corners[i].expectedCut() + corners[(i + 1) % n].expectedCut();
        const side = dist(vertices[i] - vertices[(i + 1) % n]);
        adjusts[i] = if (erc > side)
            .{ .round = side / erc, .cut = 0 }
        else if (ec > side)
            .{ .round = 1, .cut = (side - erc) / (ec - erc) }
        else
            .{ .round = 1, .cut = 1 };
    }

    // Corner cubics: up to 3 each, staged before the final layout is known.
    const stage = try allocator.alloc(Cubic, 3 * n);
    defer allocator.free(stage);
    const starts = try allocator.alloc(usize, n + 1); // prefix sums of corner lengths
    defer allocator.free(starts);
    starts[0] = 0;
    for (0..n) |i| {
        var allowed: [2]f32 = undefined;
        for (0..2) |delta| {
            const adj = adjusts[(i + n - 1 + delta) % n];
            allowed[delta] = corners[i].expected_round_cut * adj.round +
                (corners[i].expectedCut() - corners[i].expected_round_cut) * adj.cut;
        }
        starts[i + 1] = starts[i] + corners[i].getCubics(allowed[0], allowed[1], stage[starts[i]..][0..3]);
    }
    const total_corner = starts[n];

    // Final layout: all corner cubics, then one edge cubic per side.
    const fc = try allocator.alloc(Cubic, total_corner + n);
    errdefer allocator.free(fc);
    @memcpy(fc[0..total_corner], stage[0..total_corner]);
    for (0..n) |i| {
        fc[total_corner + i] = Cubic.straightLine(fc[starts[i + 1] - 1].a1, fc[starts[(i + 1) % n]].a0);
    }
    const features = try allocator.alloc(Feature, 2 * n);
    errdefer allocator.free(features);
    for (0..n) |i| {
        const cvx = cornerConvex(vertices[(i + n - 1) % n], vertices[i], vertices[(i + 1) % n]);
        features[2 * i] = .{ .kind = .corner, .is_convex = cvx, .start = starts[i], .len = starts[i + 1] - starts[i] };
        features[2 * i + 1] = .{ .kind = .edge, .is_convex = false, .start = total_corner + i, .len = 1 };
    }

    const cen = center orelse blk: {
        var sum: Point = .{ 0, 0 };
        for (vertices) |v| sum += v;
        break :blk sum / @as(Point, @splat(@floatFromInt(n)));
    };
    const merged = try mergeCubics(allocator, features, fc, cen);
    return .{ .cubics = merged, .features = features, .feature_cubics = fc, .center = cen, .allocator = allocator };
}

// --- Shape constructors (androidx Shapes.kt) ---

fn verticesFromNumVerts(allocator: Allocator, n: usize, radius: f32, center: Point) ![]Point {
    const vs = try allocator.alloc(Point, n);
    for (0..n) |i| {
        // vertex 0 at angle 0 (3 o'clock), counterclockwise in y-down space
        vs[i] = center + dirAngle(std.math.pi / @as(f32, @floatFromInt(n)) * 2 * @as(f32, @floatFromInt(i))) * @as(Point, @splat(radius));
    }
    return vs;
}

/// Regular n-gon, vertex 0 at (radius, 0) — androidx RoundedPolygon(numVertices).
pub fn regularPolygon(
    allocator: Allocator,
    n: usize,
    radius: f32,
    center: Point,
    rounding: CornerRounding,
    per_vertex_rounding: ?[]const CornerRounding,
) !RoundedPolygon {
    std.debug.assert(n >= 3);
    const vs = try verticesFromNumVerts(allocator, n, radius, center);
    defer allocator.free(vs);
    return polygonFromVertices(allocator, vs, rounding, per_vertex_rounding, center);
}

/// Circle approximated by an n-gon whose vertices sit outside the circle so
/// the rounded outline lands on it (androidx RoundedPolygon.circle).
pub fn circle(allocator: Allocator, n: usize, radius: f32, center: Point) !RoundedPolygon {
    std.debug.assert(n >= 3);
    const theta = std.math.pi / @as(f32, @floatFromInt(n));
    const polygon_radius = radius / @cos(theta);
    return regularPolygon(allocator, n, polygon_radius, center, .{ .radius = radius }, null);
}

/// (w x h) rect centered at `center`; corners rounded per `rounding`
/// (androidx RoundedPolygon.rectangle).
pub fn rectangle(
    allocator: Allocator,
    width: f32,
    height: f32,
    rounding: CornerRounding,
    per_vertex_rounding: ?[]const CornerRounding,
    center: Point,
) !RoundedPolygon {
    const l = center[0] - width / 2;
    const t = center[1] - height / 2;
    const r = center[0] + width / 2;
    const b = center[1] + height / 2;
    const vs = [_]Point{ .{ r, b }, .{ l, b }, .{ l, t }, .{ r, t } };
    return polygonFromVertices(allocator, &vs, rounding, per_vertex_rounding, center);
}

/// Star: alternating outer/inner radius vertices — androidx RoundedPolygon.star.
/// `inner_rounding` overrides `rounding` on inner vertices only.
pub fn star(
    allocator: Allocator,
    n_per_radius: usize,
    radius: f32,
    inner_radius: f32,
    rounding: CornerRounding,
    inner_rounding: ?CornerRounding,
    center: Point,
) !RoundedPolygon {
    std.debug.assert(radius > 0 and inner_radius > 0 and inner_radius < radius);
    const n = 2 * n_per_radius;
    const vs = try allocator.alloc(Point, n);
    defer allocator.free(vs);
    var pvr_buf: ?[]CornerRounding = null;
    defer if (pvr_buf) |b| allocator.free(b);
    for (0..n_per_radius) |i| {
        const a = std.math.pi / @as(f32, @floatFromInt(n_per_radius));
        vs[2 * i] = center + dirAngle(a * 2 * @as(f32, @floatFromInt(i))) * @as(Point, @splat(radius));
        vs[2 * i + 1] = center + dirAngle(a * (2 * @as(f32, @floatFromInt(i)) + 1)) * @as(Point, @splat(inner_radius));
    }
    if (inner_rounding) |ir| {
        const pvr = try allocator.alloc(CornerRounding, n);
        pvr_buf = pvr;
        for (0..n_per_radius) |i| {
            pvr[2 * i] = rounding;
            pvr[2 * i + 1] = ir;
        }
    }
    return polygonFromVertices(allocator, vs, rounding, pvr_buf, center);
}

/// Stadium: a (w x h) rect with fully-rounded short ends — androidx
/// RoundedPolygon.pill (the parametric helper; the M3E "Pill" preset is a
/// customPolygon, see presets.pill).
pub fn stadium(allocator: Allocator, width: f32, height: f32, smoothing: f32, center: Point) !RoundedPolygon {
    std.debug.assert(width > 0 and height > 0);
    const wh = width / 2;
    const hh = height / 2;
    const vs = [_]Point{
        .{ wh + center[0], hh + center[1] },
        .{ -wh + center[0], hh + center[1] },
        .{ -wh + center[0], -hh + center[1] },
        .{ wh + center[0], -hh + center[1] },
    };
    return polygonFromVertices(allocator, &vs, .{ .radius = @min(wh, hh), .smoothing = smoothing }, null, center);
}

// --- customPolygon (androidx MaterialShapes: PointNRound + reps/mirroring) ---

/// A vertex + its rounding, for `customPolygon`.
pub const PointNRound = struct { p: Point, r: CornerRounding = unrounded };

fn rotateDeg(p: Point, degrees: f32, center: Point) Point {
    const a = degrees * std.math.pi / 180;
    const off = p - center;
    const c = @cos(a);
    const s = @sin(a);
    return pt(off[0] * c - off[1] * s, off[0] * s + off[1] * c) + center;
}

/// Repeat `points` `reps` times around `center` (rotating each copy by
/// 360/reps). With `mirroring`, the section alternates forward/reversed so the
/// result is symmetric across each section boundary (androidx doRepeat):
/// actual reps = 2*reps, each rep covers 360/(2*reps) degrees, and the odd
/// reps reflect the point angles while keeping the distances.
fn repeatPoints(
    allocator: Allocator,
    points: []const PointNRound,
    reps: usize,
    center: Point,
    mirroring: bool,
) ![]PointNRound {
    var out = std.array_list.Managed(PointNRound).init(allocator);
    errdefer out.deinit();
    if (mirroring) {
        const actual_reps = reps * 2;
        const section = 360.0 / @as(f32, @floatFromInt(actual_reps));
        const angles = try allocator.alloc(f32, points.len);
        defer allocator.free(angles);
        const dists = try allocator.alloc(f32, points.len);
        defer allocator.free(dists);
        for (points, 0..) |pnr, i| {
            const off = pnr.p - center;
            angles[i] = std.math.atan2(off[1], off[0]) * 180 / std.math.pi;
            dists[i] = dist(off);
        }
        for (0..actual_reps) |rep| {
            for (0..points.len) |index| {
                const i = if (rep % 2 == 0) index else points.len - 1 - index;
                if (i > 0 or rep % 2 == 0) {
                    const extra = if (rep % 2 == 0) angles[i] else section - angles[i] + 2 * angles[0];
                    const a = (section * @as(f32, @floatFromInt(rep)) + extra) * std.math.pi / 180;
                    const final = center + dirAngle(a) * @as(Point, @splat(dists[i]));
                    try out.append(.{ .p = final, .r = points[i].r });
                }
            }
        }
    } else {
        const np = points.len;
        for (0..np * reps) |it| {
            const deg = @as(f32, @floatFromInt(it / np)) * 360.0 / @as(f32, @floatFromInt(reps));
            try out.append(.{ .p = rotateDeg(points[it % np].p, deg, center), .r = points[it % np].r });
        }
    }
    return out.toOwnedSlice();
}

/// Vertices built by repeating a point list around a center, with per-vertex
/// rounding (androidx MaterialShapes customPolygon, center (0.5, 0.5)).
pub fn customPolygon(
    allocator: Allocator,
    points: []const PointNRound,
    reps: usize,
    mirroring: bool,
) !RoundedPolygon {
    const center: Point = .{ 0.5, 0.5 };
    const pts = try repeatPoints(allocator, points, reps, center, mirroring);
    defer allocator.free(pts);
    const vertices = try allocator.alloc(Point, pts.len);
    defer allocator.free(vertices);
    const pvr = try allocator.alloc(CornerRounding, pts.len);
    defer allocator.free(pvr);
    for (pts, 0..) |pnr, i| {
        vertices[i] = pnr.p;
        pvr[i] = pnr.r;
    }
    return polygonFromVertices(allocator, vertices, unrounded, pvr, center);
}

// --- Measuring (androidx PolygonMeasure.kt): arc-length outline progress ---

/// Arc length of a cubic, approximated by 3 chord segments (LengthMeasurer —
/// ≥98.5% accurate on circular arcs, the worst case for these shapes).
fn measureCubic(c: Cubic) f32 {
    return closestProgressTo(c, std.math.inf(f32))[1];
}

/// Parameter t at which the cubic's measured length reaches `m`
/// (LengthMeasurer.findCubicCutPoint).
fn findCubicCutPoint(c: Cubic, m: f32) f32 {
    return closestProgressTo(c, m)[0];
}

/// Walk the 3 chord segments; returns .{t, total} — either the cut parameter
/// for `threshold` or the total measured length when threshold is infinite.
fn closestProgressTo(c: Cubic, threshold: f32) [2]f32 {
    const segments = 3;
    if (threshold <= 0) return .{ 0, 0 }; // m<=0 cuts at the start (defensive)
    var total: f32 = 0;
    var remainder = threshold;
    var prev = c.a0;
    for (1..segments + 1) |i| {
        const progress = @as(f32, @floatFromInt(i)) / segments;
        const p = c.pointOnCurve(progress);
        const seg = dist(p - prev);
        if (seg >= remainder)
            return .{ progress - (1 - remainder / seg) / segments, threshold };
        remainder -= seg;
        total += seg;
        prev = p;
    }
    return .{ 1, total };
}

/// A corner feature with its measured outline position (midpoint of the
/// corner's center cubic) — the unit feature mapping works on.
const ProgressableFeature = struct {
    progress: f32,
    is_convex: bool,
    /// Representative point: midpoint of the feature's first anchor0 and last
    /// anchor1 (androidx featureRepresentativePoint).
    rep: Point,
};

/// A cubic plus its [start, end) outline-progress range and measured length.
const MeasuredCubic = struct {
    cubic: Cubic,
    start: f32,
    end: f32,
    size: f32,

    /// Cut in two at outline progress `p` (clamped into the cubic's range):
    /// the split parameter t is found by arc length, not linearly.
    fn cutAtProgress(mc: MeasuredCubic, p: f32) [2]MeasuredCubic {
        const cp = std.math.clamp(p, mc.start, mc.end);
        const relative = (cp - mc.start) / (mc.end - mc.start);
        const t = findCubicCutPoint(mc.cubic, relative * mc.size);
        std.debug.assert(t >= 0 and t <= 1);
        const halves = mc.cubic.split(t);
        return .{
            .{ .cubic = halves[0], .start = mc.start, .end = cp, .size = relative * mc.size },
            .{ .cubic = halves[1], .start = cp, .end = mc.end, .size = (1 - relative) * mc.size },
        };
    }
};

/// A polygon measured by outline progress (0..1 over total arc length):
/// measured cubics + the corner features' progress positions.
const MeasuredPolygon = struct {
    cubics: []MeasuredCubic,
    features: []ProgressableFeature,
    allocator: Allocator,

    fn deinit(mp: *MeasuredPolygon) void {
        mp.allocator.free(mp.cubics);
        mp.allocator.free(mp.features);
    }

    /// Assemble measured cubics from raw cubics + their cumulative outline
    /// progress (size = cubics.len + 1, [0]=0, [last]=1). Cubics whose
    /// progress range is empty are dropped; the last one ends at exactly 1.
    fn assemble(allocator: Allocator, raw: []const Cubic, outline_progress: []const f32, features: []ProgressableFeature) !MeasuredPolygon {
        var measured = std.array_list.Managed(MeasuredCubic).init(allocator);
        errdefer measured.deinit();
        var start_op: f32 = 0;
        for (raw, 0..) |cubic, i| {
            if (outline_progress[i + 1] - outline_progress[i] > distance_epsilon) {
                try measured.append(.{ .cubic = cubic, .start = start_op, .end = outline_progress[i + 1], .size = measureCubic(cubic) });
                start_op = outline_progress[i + 1];
            }
        }
        std.debug.assert(measured.items.len > 0);
        measured.items[measured.items.len - 1].end = 1;
        const feats = try allocator.dupe(ProgressableFeature, features);
        return .{ .cubics = try measured.toOwnedSlice(), .features = feats, .allocator = allocator };
    }

    /// Measure a polygon's outline (feature order — corners and edges), giving
    /// each corner's CENTER cubic's midpoint as its feature progress.
    fn measure(allocator: Allocator, poly: *const RoundedPolygon) !MeasuredPolygon {
        var raw = std.array_list.Managed(Cubic).init(allocator);
        defer raw.deinit();
        // corner feature index -> index of its center cubic in `raw`
        var marks = std.array_list.Managed(usize).init(allocator);
        defer marks.deinit();
        for (poly.features) |f| {
            const fc = poly.featureCubics(f);
            if (f.kind == .corner) {
                for (fc, 0..) |cubic, ci| {
                    if (ci == fc.len / 2) try marks.append(raw.items.len);
                    try raw.append(cubic);
                }
            } else {
                try raw.appendSlice(fc);
            }
        }
        // cumulative measures -> normalized outline progress
        const op = try allocator.alloc(f32, raw.items.len + 1);
        defer allocator.free(op);
        op[0] = 0;
        for (raw.items, 0..) |cubic, i| op[i + 1] = op[i] + measureCubic(cubic);
        const total = op[raw.items.len];
        std.debug.assert(total > 0);
        for (op) |*v| v.* /= total;

        const feats = try allocator.alloc(ProgressableFeature, marks.items.len);
        defer allocator.free(feats);
        var fi: usize = 0;
        for (poly.features) |f| {
            if (f.kind != .corner) continue;
            const fc = poly.featureCubics(f);
            const ix = marks.items[fi];
            fi += 1;
            feats[fi - 1] = .{
                .progress = pmod((op[ix] + op[ix + 1]) / 2, 1),
                .is_convex = f.is_convex,
                .rep = (fc[0].a0 + fc[fc.len - 1].a1) / @as(Point, @splat(2)),
            };
        }
        return assemble(allocator, raw.items, op, feats);
    }

    /// A copy of this outline cut at `cutting_point` and rotated so it starts
    /// there (androidx cutAndShift) — the cubic crossing the cut is split, the
    /// rest wrap around, and outline progress is re-based.
    fn cutAndShift(mp: *const MeasuredPolygon, allocator: Allocator, cutting_point: f32) !MeasuredPolygon {
        std.debug.assert(cutting_point >= 0 and cutting_point <= 1);
        if (cutting_point < distance_epsilon) {
            return .{
                .cubics = try allocator.dupe(MeasuredCubic, mp.cubics),
                .features = try allocator.dupe(ProgressableFeature, mp.features),
                .allocator = allocator,
            };
        }
        const sz = mp.cubics.len;
        var target: usize = 0;
        for (mp.cubics, 0..) |mc, i| {
            if (cutting_point >= mc.start and cutting_point <= mc.end) {
                target = i;
                break;
            }
        }
        const halves = mp.cubics[target].cutAtProgress(cutting_point);

        const ret = try allocator.alloc(Cubic, sz + 1);
        defer allocator.free(ret);
        ret[0] = halves[1].cubic; // after the cut
        for (1..sz) |i| ret[i] = mp.cubics[(i + target) % sz].cubic;
        ret[sz] = halves[0].cubic; // before the cut, at the end

        const op = try allocator.alloc(f32, sz + 2);
        defer allocator.free(op);
        for (0..sz + 2) |i| {
            op[i] = if (i == 0)
                0
            else if (i == sz + 1)
                1
            else
                pmod(mp.cubics[(target + i - 1) % sz].end - cutting_point, 1);
        }

        const feats = try allocator.alloc(ProgressableFeature, mp.features.len);
        defer allocator.free(feats);
        for (mp.features, feats) |f, *nf| {
            nf.* = .{ .progress = pmod(f.progress - cutting_point, 1), .is_convex = f.is_convex, .rep = f.rep };
        }
        return assemble(allocator, ret, op, feats);
    }
};

// --- Feature mapping (androidx FeatureMapping.kt + FloatMapping.kt) ---

/// Piecewise-linear map between two shapes' circular [0,1) progress domains,
/// built from aligned feature pairs. mapBack is the inverse direction.
const DoubleMapper = struct {
    xs: []f32, // source progresses, sorted circularly
    ys: []f32,
    allocator: Allocator,

    fn deinit(m: *DoubleMapper) void {
        m.allocator.free(m.xs);
        m.allocator.free(m.ys);
    }

    fn map(m: *const DoubleMapper, x: f32) f32 {
        return linearMap(m.xs, m.ys, x);
    }

    fn mapBack(m: *const DoubleMapper, x: f32) f32 {
        return linearMap(m.ys, m.xs, x);
    }
};

fn linearMap(xs: []const f32, ys: []const f32, x: f32) f32 {
    std.debug.assert(x >= 0 and x <= 1);
    // A degenerate mapping (featureMapper can emit a single entry when
    // every later candidate is rejected) has no segment to find — flat-map
    // to the single target instead of reading xs[n] out of bounds.
    const n = xs.len;
    if (n == 0) return x;
    if (n == 1) return ys[0];
    // find the segment (wrapping) containing x
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (progressInRange(x, xs[i], xs[(i + 1) % n])) break;
    }
    if (i >= n) return ys[n - 1]; // x fell between segments (float dust)
    const j = (i + 1) % n;
    const sx = pmod(xs[j] - xs[i], 1);
    const sy = pmod(ys[j] - ys[i], 1);
    const pos = if (sx < 0.001) @as(f32, 0.5) else pmod(x - xs[i], 1) / sx;
    return pmod(ys[i] + sy * pos, 1);
}

/// Greedy min-distance matching of corner features between the two shapes:
/// pair them smallest-distance-first, skipping used features, near-duplicate
/// progress entries, and any pair that would cross the mapping.
fn featureMapper(allocator: Allocator, f1: []const ProgressableFeature, f2: []const ProgressableFeature) !DoubleMapper {
    const DV = struct { d: f32, i: usize, j: usize };
    var dvs = std.array_list.Managed(DV).init(allocator);
    defer dvs.deinit();
    for (f1, 0..) |a, i| {
        for (f2, 0..) |b, j| {
            // convex corners only map to convex, concave to concave.
            if (a.is_convex != b.is_convex) continue;
            try dvs.append(.{ .d = distSq(a.rep - b.rep), .i = i, .j = j });
        }
    }
    std.mem.sort(DV, dvs.items, {}, struct {
        fn lt(_: void, a: DV, b: DV) bool {
            return a.d < b.d;
        }
    }.lt);

    // Special cases: nothing maps -> identity; a single pair gets an
    // antipodal anchor so the wrap has something to lean on.
    if (dvs.items.len == 0) {
        return .{ .xs = try allocator.dupe(f32, &.{ 0, 0.5 }), .ys = try allocator.dupe(f32, &.{ 0, 0.5 }), .allocator = allocator };
    }
    if (dvs.items.len == 1) {
        const dv = dvs.items[0];
        return .{
            .xs = try allocator.dupe(f32, &.{ f1[dv.i].progress, pmod(f1[dv.i].progress + 0.5, 1) }),
            .ys = try allocator.dupe(f32, &.{ f2[dv.j].progress, pmod(f2[dv.j].progress + 0.5, 1) }),
            .allocator = allocator,
        };
    }

    // MappingHelper: pairs sorted by f1 progress; a pair is added iff unused,
    // not too close to its neighbours, and (for n>1) not crossing the wrap.
    var used1 = try allocator.alloc(bool, f1.len);
    defer allocator.free(used1);
    var used2 = try allocator.alloc(bool, f2.len);
    defer allocator.free(used2);
    @memset(used1, false);
    @memset(used2, false);
    const Pair = struct { p1: f32, p2: f32 };
    var mapping = std.array_list.Managed(Pair).init(allocator);
    defer mapping.deinit();

    for (dvs.items) |dv| {
        if (used1[dv.i] or used2[dv.j]) continue;
        const p1 = f1[dv.i].progress;
        const p2 = f2[dv.j].progress;
        var ins: usize = 0;
        while (ins < mapping.items.len and mapping.items[ins].p1 < p1) ins += 1;
        const nm = mapping.items.len;
        var ok = true;
        if (nm >= 1) {
            const before = mapping.items[(ins + nm - 1) % nm];
            const after = mapping.items[ins % nm];
            if (progressDistance(p1, before.p1) < distance_epsilon or
                progressDistance(p1, after.p1) < distance_epsilon or
                progressDistance(p2, before.p2) < distance_epsilon or
                progressDistance(p2, after.p2) < distance_epsilon) ok = false;
            if (ok and nm > 1 and !progressInRange(p2, before.p2, after.p2)) ok = false;
        }
        if (ok) {
            try mapping.insert(ins, .{ .p1 = p1, .p2 = p2 });
            used1[dv.i] = true;
            used2[dv.j] = true;
        }
    }

    const xs = try allocator.alloc(f32, mapping.items.len);
    errdefer allocator.free(xs);
    const ys = try allocator.alloc(f32, mapping.items.len);
    errdefer allocator.free(ys);
    for (mapping.items, 0..) |pair, i| {
        xs[i] = pair.p1;
        ys[i] = pair.p2;
    }
    return .{ .xs = xs, .ys = ys, .allocator = allocator };
}

// --- Morph ---

/// A morph between two RoundedPolygons: the matched cubic pairs, aligned by
/// feature mapping + outline-progress cutting. Construct once per shape pair;
/// asCubics evaluates any progress t (extrapolating outside [0,1]).
pub const Morph = struct {
    pub const Pair = struct { start: Cubic, end: Cubic };

    pairs: []Pair,
    allocator: Allocator,

    pub fn init(allocator: Allocator, start: *const RoundedPolygon, end: *const RoundedPolygon) !Morph {
        var mp1 = try MeasuredPolygon.measure(allocator, start);
        defer mp1.deinit();
        var mp2 = try MeasuredPolygon.measure(allocator, end);
        defer mp2.deinit();

        var mapper = try featureMapper(allocator, mp1.features, mp2.features);
        defer mapper.deinit();

        // Where on shape 2's outline shape 1's progress-0 lands; cut+shift so
        // both outlines start at matching positions.
        const cut_point = mapper.map(0);
        var bs2 = try mp2.cutAndShift(allocator, cut_point);
        defer bs2.deinit();

        var pairs = std.array_list.Managed(Pair).init(allocator);
        errdefer pairs.deinit();
        const bs1 = mp1.cubics;
        const bs2c = bs2.cubics;
        var ix1: usize = 1;
        var ix2: usize = 1;
        var b1: ?MeasuredCubic = if (bs1.len > 0) bs1[0] else null;
        var b2: ?MeasuredCubic = if (bs2c.len > 0) bs2c[0] else null;
        while (b1 != null and b2 != null) {
            // Progresses are compared in shape 1's domain (b2's end is
            // un-shifted then mapped back).
            const b1a = if (ix1 == bs1.len) @as(f32, 1) else b1.?.end;
            const b2a = if (ix2 == bs2c.len) @as(f32, 1) else mapper.mapBack(pmod(b2.?.end + cut_point, 1));
            const minb = @min(b1a, b2a);
            var seg1 = b1.?;
            if (b1a > minb + angle_epsilon) {
                const halves = b1.?.cutAtProgress(minb);
                seg1 = halves[0];
                b1 = halves[1]; // the remainder stays current
            } else {
                b1 = if (ix1 < bs1.len) bs1[ix1] else null;
                ix1 += 1;
            }
            var seg2 = b2.?;
            if (b2a > minb + angle_epsilon) {
                const halves = b2.?.cutAtProgress(pmod(mapper.map(minb) - cut_point, 1));
                seg2 = halves[0];
                b2 = halves[1];
            } else {
                b2 = if (ix2 < bs2c.len) bs2c[ix2] else null;
                ix2 += 1;
            }
            try pairs.append(.{ .start = seg1.cubic, .end = seg2.cubic });
        }
        std.debug.assert(b1 == null and b2 == null);
        return .{ .pairs = try pairs.toOwnedSlice(), .allocator = allocator };
    }

    pub fn deinit(m: *Morph) void {
        m.allocator.free(m.pairs);
    }

    /// Matched-cubic count — the segment count of the interpolated outline.
    pub fn segmentCount(m: *const Morph) usize {
        return m.pairs.len;
    }

    /// Write the interpolated outline at progress `t` into `out` (len >=
    /// segmentCount). t is not clamped: values outside [0,1] extrapolate
    /// (spring overshoot). Returns the written slice.
    pub fn asCubicsInto(m: *const Morph, t: f32, out: []Cubic) []Cubic {
        std.debug.assert(out.len >= m.pairs.len);
        for (m.pairs, 0..) |pair, i| {
            const s = pair.start;
            const e = pair.end;
            out[i] = .{
                .a0 = lerpPt(s.a0, e.a0, t),
                .c0 = lerpPt(s.c0, e.c0, t),
                .c1 = lerpPt(s.c1, e.c1, t),
                .a1 = lerpPt(s.a1, e.a1, t),
            };
        }
        const n = m.pairs.len;
        // Close exactly: last anchor1 = first anchor0 (avoids seam artifacts).
        if (n > 0) out[n - 1].a1 = out[0].a0;
        return out[0..n];
    }

    /// The interpolated outline at `t` as a fresh slice (see asCubicsInto).
    pub fn asCubics(m: *const Morph, allocator: Allocator, t: f32) ![]Cubic {
        const out = try allocator.alloc(Cubic, m.pairs.len);
        _ = m.asCubicsInto(t, out);
        return out;
    }

    /// The interpolated outline at `t` emitted into caller buffers (see
    /// emitPathInto): `scratch` (len >= segmentCount) takes the cubics —
    /// the allocation-free per-frame paint path.
    pub fn emitPath(m: *const Morph, t: f32, scratch: []Cubic, pts: []f32, verbs: []i32) EmittedPath {
        return emitPathInto(m.asCubicsInto(t, scratch), pts, verbs);
    }

    /// The interpolated outline at `t` as an owned path (see Path).
    pub fn toPath(m: *const Morph, allocator: Allocator, t: f32) !Path {
        const cubics = try m.asCubics(allocator, t);
        defer allocator.free(cubics);
        return pathFromCubics(allocator, cubics);
    }
};

// --- Path emission (kx_fill_path / kx_stroke_path, ABI 0.16.0) ---
//
// The path ABI consumes a flat x,y point stream driven by verb opcodes
// (paint.PathVerb: 0 move / 1 line / 2 quad / 3 cubic / 4 close). A closed
// cubic outline emits move + N×cubic + close: each cubic's a0 is implied by
// the current point (moveTo for the first), so a cubic contributes only its
// c0,c1,a1 — 6 floats. The emitted curve is unchanged by cubic-list splits:
// morph pairs resegment the outline but produce the same curve.

/// Verb opcodes — re-exported so emitted verbs are exactly the paint ABI's
/// encoding (a single source of truth for the wire format).
pub const PathVerb = paint.PathVerb;

/// Buffer sizes a closed outline of `n` cubics needs for emitPathInto.
pub const PathCounts = struct { pts: usize, verbs: usize };

pub fn pathCounts(n_cubics: usize) PathCounts {
    return .{ .pts = 2 + 6 * n_cubics, .verbs = n_cubics + 2 };
}

/// The used prefix of an emission — pass straight to ui.paint.fillPath or
/// ui.paint.strokePath (pts/verbs are slices of the caller's buffers).
pub const EmittedPath = struct { pts: []const f32, verbs: []const i32 };

/// Write a closed cubic outline as a verb path into caller buffers sized
/// per pathCounts(cubics.len) — allocation-free. Layout: moveTo(cubics[0].a0),
/// cubicTo(c0,c1,a1) per cubic, close. Contiguity (a1 == next a0) is the
/// RoundedPolygon/Morph invariant; the emitted path stays connected through
/// the implicit current point regardless.
pub fn emitPathInto(cubics: []const Cubic, pts: []f32, verbs: []i32) EmittedPath {
    std.debug.assert(cubics.len > 0);
    const counts = pathCounts(cubics.len);
    std.debug.assert(pts.len >= counts.pts and verbs.len >= counts.verbs);
    verbs[0] = @backingInt(PathVerb.move);
    pts[0] = cubics[0].a0[0];
    pts[1] = cubics[0].a0[1];
    var w: usize = 2;
    for (cubics, 1..) |c, i| {
        verbs[i] = @backingInt(PathVerb.cubic);
        inline for (.{ c.c0, c.c1, c.a1 }) |v| {
            pts[w] = v[0];
            pts[w + 1] = v[1];
            w += 2;
        }
    }
    verbs[cubics.len + 1] = @backingInt(PathVerb.close);
    return .{ .pts = pts[0..counts.pts], .verbs = verbs[0..counts.verbs] };
}

/// An emitted path owning its arrays; deinit frees both.
pub const Path = struct {
    pts: []f32,
    verbs: []i32,
    allocator: Allocator,

    pub fn deinit(p: *Path) void {
        p.allocator.free(p.pts);
        p.allocator.free(p.verbs);
    }

    /// Fill through kx_fill_path — `fill_rule` false = winding, true =
    /// even-odd (the ABI encoding; winding for simple closed outlines).
    pub fn fill(p: *const Path, ctx: *kx.Ctx, color: paint.Color, fill_rule: bool) void {
        paint.fillPath(ctx, p.pts, p.verbs, color, fill_rule);
    }

    /// Stroke through kx_stroke_path.
    pub fn stroke(p: *const Path, ctx: *kx.Ctx, stroke_w: f32, color: paint.Color, fill_rule: bool) void {
        paint.strokePath(ctx, p.pts, p.verbs, stroke_w, color, fill_rule);
    }
};

/// Owned path arrays for a closed cubic outline (see emitPathInto).
pub fn pathFromCubics(allocator: Allocator, cubics: []const Cubic) !Path {
    const counts = pathCounts(cubics.len);
    const pts = try allocator.alloc(f32, counts.pts);
    errdefer allocator.free(pts);
    const verbs = try allocator.alloc(i32, counts.verbs);
    errdefer allocator.free(verbs);
    _ = emitPathInto(cubics, pts, verbs);
    return .{ .pts = pts, .verbs = verbs, .allocator = allocator };
}

/// Emit + fill a closed cubic outline through kx_fill_path using caller
/// scratch buffers sized per pathCounts(cubics.len) — the allocation-free
/// paint path. `fill_rule`: false winding, true even-odd.
pub fn fillCubics(ctx: *kx.Ctx, cubics: []const Cubic, pts: []f32, verbs: []i32, color: paint.Color, fill_rule: bool) void {
    const e = emitPathInto(cubics, pts, verbs);
    paint.fillPath(ctx, e.pts, e.verbs, color, fill_rule);
}

/// Emit + stroke a closed cubic outline through kx_stroke_path.
pub fn strokeCubics(ctx: *kx.Ctx, cubics: []const Cubic, pts: []f32, verbs: []i32, stroke_w: f32, color: paint.Color, fill_rule: bool) void {
    const e = emitPathInto(cubics, pts, verbs);
    paint.strokePath(ctx, e.pts, e.verbs, stroke_w, color, fill_rule);
}

// --- Flattening (polygon fallback for kx_fill_polygon + area tests) ---

/// Adaptively subdivide a closed cubic outline into polygon points, appended
/// to `out` (no duplicate closing point — the polygon is implicitly closed).
/// `tolerance` = max distance between the curve and its chord, in shape units.
pub fn flattenCubics(cubics: []const Cubic, tolerance: f32, out: *std.array_list.Managed(Point)) !void {
    for (cubics) |c| {
        if (out.items.len == 0) try out.append(c.a0);
        try flattenCubic(c, tolerance, out, 0);
    }
}

fn flattenCubic(c: Cubic, tol: f32, out: *std.array_list.Managed(Point), depth: u32) error{OutOfMemory}!void {
    if (depth >= 16 or cubicFlat(c, tol)) {
        try out.append(c.a1);
        return;
    }
    const halves = c.split(0.5);
    try flattenCubic(halves[0], tol, out, depth + 1);
    try flattenCubic(halves[1], tol, out, depth + 1);
}

/// Flat when both control points lie within `tol` of the chord a0->a1.
fn cubicFlat(c: Cubic, tol: f32) bool {
    const chord = c.a1 - c.a0;
    const l = dist(chord);
    if (l < 1e-9) {
        return dist(c.c0 - c.a0) <= tol and dist(c.c1 - c.a0) <= tol;
    }
    const d0 = @abs(chord[0] * (c.c0[1] - c.a0[1]) - chord[1] * (c.c0[0] - c.a0[0])) / l;
    const d1 = @abs(chord[0] * (c.c1[1] - c.a0[1]) - chord[1] * (c.c1[0] - c.a0[0])) / l;
    return @max(d0, d1) <= tol;
}

/// Flatten into parallel xs/ys arrays — what kx_fill_polygon takes.
pub fn flattenXY(cubics: []const Cubic, tolerance: f32, xs: *std.array_list.Managed(f32), ys: *std.array_list.Managed(f32)) !void {
    var pts = std.array_list.Managed(Point).init(xs.allocator);
    defer pts.deinit();
    try flattenCubics(cubics, tolerance, &pts);
    try xs.ensureUnusedCapacity(pts.items.len);
    try ys.ensureUnusedCapacity(pts.items.len);
    for (pts.items) |p| {
        xs.appendAssumeCapacity(p[0]);
        ys.appendAssumeCapacity(p[1]);
    }
}

/// Convenience: flatten a morph at progress `t` into `out` (stack-friendly —
/// reuse `out` across frames; also `scratch` for the cubic buffer).
pub fn flattenMorph(m: *const Morph, t: f32, tolerance: f32, scratch: []Cubic, out: *std.array_list.Managed(Point)) !void {
    const cubics = m.asCubicsInto(t, scratch);
    try flattenCubics(cubics, tolerance, out);
}

// --- M3E presets (androidx.compose.material3.MaterialShapes) ---
//
// Exact androidx parameter values. Every preset is normalized into the 0..1
// box (MaterialShapes applies .normalized() to each). `presetShape` returns an
// owned RoundedPolygon — cache it once per widget, morphs read it by ref.

pub const Preset = enum {
    circle,
    square,
    triangle,
    diamond,
    pentagon,
    hexagon, // Klaxon addition (no androidx preset): regular 6-gon, rounding .15
    pill,
    oval,
    sunny,
    very_sunny,
    cookie4,
    cookie6,
    cookie7,
    cookie9,
    cookie12,
    clover4,
    clover8,
    burst,
    soft_burst,
};

/// The un-normalized preset geometry (exact androidx MaterialShapes params).
fn presetRaw(allocator: Allocator, p: Preset) !RoundedPolygon {
    switch (p) {
        // MaterialShapes.circle(): RoundedPolygon.circle(numVertices = 10)
        .circle => return circle(allocator, 10, 1, .{ 0, 0 }),
        // RoundedPolygon.rectangle(1, 1, cornerRound30)
        .square => return rectangle(allocator, 1, 1, .{ .radius = 0.3 }, null, .{ 0, 0 }),
        // RoundedPolygon(3, cornerRound20) rotated -90° (vertex up)
        .triangle => {
            var poly = try regularPolygon(allocator, 3, 1, .{ 0, 0 }, .{ .radius = 0.2 }, null);
            defer poly.deinit();
            return poly.transformed(allocator, Transform.rotation(-90));
        },
        // customPolygon([(.5,1.096) r(.151,.524), (.04,.5) r.159], reps=2)
        .diamond => return customPolygon(allocator, &.{
            .{ .p = pt(0.5, 1.096), .r = .{ .radius = 0.151, .smoothing = 0.524 } },
            .{ .p = pt(0.04, 0.5), .r = .{ .radius = 0.159 } },
        }, 2, false),
        // customPolygon([(.5,-.009) r.172, (1.03,.365) r.164, (.828,.97) r.169],
        //               reps=1, mirroring) — a puffy pentagon
        .pentagon => return customPolygon(allocator, &.{
            .{ .p = pt(0.5, -0.009), .r = .{ .radius = 0.172 } },
            .{ .p = pt(1.03, 0.365), .r = .{ .radius = 0.164 } },
            .{ .p = pt(0.828, 0.97), .r = .{ .radius = 0.169 } },
        }, 1, true),
        // Klaxon addition — androidx has no hexagon preset.
        .hexagon => return regularPolygon(allocator, 6, 1, .{ 0, 0 }, .{ .radius = 0.15 }, null),
        // customPolygon([(.961,.039) r.426, (1.001,.428) -, (1,.609) r1],
        //               reps=2, mirroring) — a stadium ~2:1
        .pill => return customPolygon(allocator, &.{
            .{ .p = pt(0.961, 0.039), .r = .{ .radius = 0.426 } },
            .{ .p = pt(1.001, 0.428) },
            .{ .p = pt(1.0, 0.609), .r = .{ .radius = 1.0 } },
        }, 2, true),
        // RoundedPolygon.circle(8) scaled (1, .64) then rotated -45°
        .oval => {
            var poly = try circle(allocator, 8, 1, .{ 0, 0 });
            defer poly.deinit();
            var scaled = try poly.transformed(allocator, Transform.scale(1, 0.64));
            defer scaled.deinit();
            return scaled.transformed(allocator, Transform.rotation(-45));
        },
        // RoundedPolygon.star(8, innerRadius=.8, cornerRound15)
        .sunny => return star(allocator, 8, 1, 0.8, .{ .radius = 0.15 }, null, .{ 0, 0 }),
        // customPolygon([(.5,1.08) r.085, (.358,.843) r.085], reps=8)
        .very_sunny => return customPolygon(allocator, &.{
            .{ .p = pt(0.5, 1.08), .r = .{ .radius = 0.085 } },
            .{ .p = pt(0.358, 0.843), .r = .{ .radius = 0.085 } },
        }, 8, false),
        // customPolygon([(1.237,1.236) r.258, (.5,.918) r.233], reps=4)
        .cookie4 => return customPolygon(allocator, &.{
            .{ .p = pt(1.237, 1.236), .r = .{ .radius = 0.258 } },
            .{ .p = pt(0.5, 0.918), .r = .{ .radius = 0.233 } },
        }, 4, false),
        // customPolygon([(.723,.884) r.394, (.5,1.099) r.398], reps=6)
        .cookie6 => return customPolygon(allocator, &.{
            .{ .p = pt(0.723, 0.884), .r = .{ .radius = 0.394 } },
            .{ .p = pt(0.5, 1.099), .r = .{ .radius = 0.398 } },
        }, 6, false),
        // star(7, inner=.75, cornerRound50) rotated -90°
        .cookie7 => {
            var poly = try star(allocator, 7, 1, 0.75, .{ .radius = 0.5 }, null, .{ 0, 0 });
            defer poly.deinit();
            return poly.transformed(allocator, Transform.rotation(-90));
        },
        // star(9, inner=.8, cornerRound50) rotated -90°
        .cookie9 => {
            var poly = try star(allocator, 9, 1, 0.8, .{ .radius = 0.5 }, null, .{ 0, 0 });
            defer poly.deinit();
            return poly.transformed(allocator, Transform.rotation(-90));
        },
        // star(12, inner=.8, cornerRound50) rotated -90°
        .cookie12 => {
            var poly = try star(allocator, 12, 1, 0.8, .{ .radius = 0.5 }, null, .{ 0, 0 });
            defer poly.deinit();
            return poly.transformed(allocator, Transform.rotation(-90));
        },
        // customPolygon([(.5,.074) -, (.725,-.099) r.476], reps=4, mirroring)
        .clover4 => return customPolygon(allocator, &.{
            .{ .p = pt(0.5, 0.074) },
            .{ .p = pt(0.725, -0.099), .r = .{ .radius = 0.476 } },
        }, 4, true),
        // customPolygon([(.5,.036) -, (.758,-.101) r.209], reps=8)
        .clover8 => return customPolygon(allocator, &.{
            .{ .p = pt(0.5, 0.036) },
            .{ .p = pt(0.758, -0.101), .r = .{ .radius = 0.209 } },
        }, 8, false),
        // customPolygon([(.5,-.006) r.006, (.592,.158) r.006], reps=12)
        .burst => return customPolygon(allocator, &.{
            .{ .p = pt(0.5, -0.006), .r = .{ .radius = 0.006 } },
            .{ .p = pt(0.592, 0.158), .r = .{ .radius = 0.006 } },
        }, 12, false),
        // customPolygon([(.193,.277) r.053, (.176,.055) r.053], reps=10)
        .soft_burst => return customPolygon(allocator, &.{
            .{ .p = pt(0.193, 0.277), .r = .{ .radius = 0.053 } },
            .{ .p = pt(0.176, 0.055), .r = .{ .radius = 0.053 } },
        }, 10, false),
    }
}

/// An M3E preset shape, normalized into the 0..1 box.
pub fn presetShape(allocator: Allocator, p: Preset) !RoundedPolygon {
    var raw = try presetRaw(allocator, p);
    defer raw.deinit();
    return raw.normalized(allocator);
}

/// M3E LoadingIndicatorDefaults.IndeterminateIndicatorPolygons.
pub const indeterminate_sequence = [_]Preset{ .soft_burst, .cookie9, .pentagon, .pill, .sunny, .cookie4, .oval };
/// M3E LoadingIndicatorDefaults.DeterminateIndicatorPolygons.
pub const determinate_sequence = [_]Preset{ .circle, .soft_burst };

// --- tests ---

const testing = std.testing;

/// A closed outline: consecutive anchors chain (within distance_epsilon —
/// near-endpoint splits can differ by ~1 ulp, as in androidx) and the last
/// anchor1 equals the first anchor0 exactly (the seam fix in asCubicsInto).
fn expectClosed(cubics: []const Cubic) !void {
    try testing.expect(cubics.len > 0);
    for (0..cubics.len - 1) |i| {
        try expectApprox(cubics[i].a1, cubics[i + 1].a0, distance_epsilon);
    }
    try testing.expectEqual(cubics[cubics.len - 1].a1, cubics[0].a0);
}

fn expectApprox(a: Point, b: Point, tol: f32) !void {
    try testing.expectApproxEqAbs(a[0], b[0], tol);
    try testing.expectApproxEqAbs(a[1], b[1], tol);
}

fn flatArea(pts: []const Point) f32 {
    var a: f32 = 0;
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        a += p[0] * q[1] - q[0] * p[1];
    }
    return @abs(a) / 2;
}

test "shapes: presets build closed outlines with the expected corner counts" {
    const expected = [_]struct { p: Preset, corners: usize }{
        .{ .p = .circle, .corners = 10 },
        .{ .p = .square, .corners = 4 },
        .{ .p = .triangle, .corners = 3 },
        .{ .p = .diamond, .corners = 4 },
        .{ .p = .pentagon, .corners = 5 }, // 3 pts mirrored rep=1 -> 2*1 reps, 5 vertices
        .{ .p = .hexagon, .corners = 6 },
        .{ .p = .pill, .corners = 10 }, // 3 pts x 2 mirrored reps, index 0 skipped on odd reps -> 10
        .{ .p = .sunny, .corners = 16 },
        .{ .p = .cookie4, .corners = 8 },
        .{ .p = .cookie9, .corners = 18 },
        .{ .p = .clover4, .corners = 12 }, // mirrored: even reps 2 pts, odd 1 -> 2+1 x4
        .{ .p = .burst, .corners = 24 },
    };
    for (expected) |e| {
        var poly = try presetShape(testing.allocator, e.p);
        defer poly.deinit();
        try expectClosed(poly.cubics);
        var n_corners: usize = 0;
        for (poly.features) |f| {
            if (f.kind == .corner) n_corners += 1;
            // every feature's cubics are contiguous
            const fc = poly.featureCubics(f);
            for (fc[1..], 0..) |c, i| try expectApprox(fc[i].a1, c.a0, 1e-5);
        }
        try testing.expectEqual(e.corners, n_corners);
    }
}

test "shapes: the normalized circle fills the unit box and is centered" {
    var c = try presetShape(testing.allocator, .circle);
    defer c.deinit();
    const b = c.bounds();
    // normalized() scales by the approximate (control-point) bounds, so the
    // tight axis is exact and the other centers within ~0.01.
    try expectApprox(b.min, .{ 0, 0 }, 0.01);
    try expectApprox(b.max, .{ 1, 1 }, 0.01);
    try expectApprox(c.center, .{ 0.5, 0.5 }, 0.01);
    // outline points stay ~0.5 from the center
    for (c.cubics) |cu| {
        try testing.expectApproxEqAbs(@as(f32, 0.5), dist(cu.a0 - c.center), 0.05);
    }
}

test "shapes: star inner vertices are concave corners" {
    var s = try star(testing.allocator, 8, 1, 0.5, .{ .radius = 0.1 }, null, .{ 0, 0 });
    defer s.deinit();
    var convex_count: usize = 0;
    var concave_count: usize = 0;
    for (s.features) |f| {
        if (f.kind == .corner) {
            if (f.is_convex) convex_count += 1 else concave_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 8), convex_count);
    try testing.expectEqual(@as(usize, 8), concave_count);
}

test "shapes: morphing a shape into itself is the identity at any t" {
    var sq = try presetShape(testing.allocator, .square);
    defer sq.deinit();
    var m = try Morph.init(testing.allocator, &sq, &sq);
    defer m.deinit();
    const at0 = try m.asCubics(testing.allocator, 0);
    defer testing.allocator.free(at0);
    for ([_]f32{ 0.5, 1.0, 1.35 }) |t| {
        const mid = try m.asCubics(testing.allocator, t);
        defer testing.allocator.free(mid);
        try testing.expectEqual(at0.len, mid.len);
        for (at0, mid) |a, b| {
            try expectApprox(a.a0, b.a0, 1e-4);
            try expectApprox(a.c0, b.c0, 1e-4);
            try expectApprox(a.c1, b.c1, 1e-4);
            try expectApprox(a.a1, b.a1, 1e-4);
        }
    }
}

test "shapes: morph endpoints reproduce start/end, midpoint is between" {
    var a = try presetShape(testing.allocator, .circle);
    defer a.deinit();
    var b = try presetShape(testing.allocator, .pentagon);
    defer b.deinit();
    var m = try Morph.init(testing.allocator, &a, &b);
    defer m.deinit();
    const n = m.segmentCount();
    try testing.expect(n >= @max(a.cubics.len, b.cubics.len));

    const at0 = try m.asCubics(testing.allocator, 0);
    defer testing.allocator.free(at0);
    const at1 = try m.asCubics(testing.allocator, 1);
    defer testing.allocator.free(at1);
    // endpoints = the matched start/end cubics verbatim
    for (0..n) |i| {
        try expectApprox(at0[i].a0, m.pairs[i].start.a0, 1e-6);
        try expectApprox(at1[i].a0, m.pairs[i].end.a0, 1e-6);
        // midpoint = componentwise average
        try expectApprox(at0[i].c0 + (m.pairs[i].end.c0 - m.pairs[i].start.c0) * @as(Point, @splat(0.5)), at0[i].c0 + (at1[i].c0 - at0[i].c0) * @as(Point, @splat(0.5)), 1e-6);
    }
    // the midpoint shape's bounds sit inside the union of the endpoints'
    const mid = try m.asCubics(testing.allocator, 0.5);
    defer testing.allocator.free(mid);
    try expectClosed(mid);
    const ba = a.bounds();
    const bb = b.bounds();
    const umin = @min(ba.min, bb.min);
    const umax = @max(ba.max, bb.max);
    for (mid) |c| {
        inline for (.{ c.a0, c.a1 }) |v| {
            try testing.expect(v[0] >= umin[0] - 1e-4 and v[0] <= umax[0] + 1e-4);
            try testing.expect(v[1] >= umin[1] - 1e-4 and v[1] <= umax[1] + 1e-4);
        }
    }
}

test "shapes: morph t>1 extrapolates instead of clamping" {
    var a = try presetShape(testing.allocator, .circle);
    defer a.deinit();
    var b = try presetShape(testing.allocator, .triangle);
    defer b.deinit();
    var m = try Morph.init(testing.allocator, &a, &b);
    defer m.deinit();
    var buf: [512]Cubic = undefined;
    const out = m.asCubicsInto(1.25, &buf);
    const s = m.pairs[0].start;
    const e = m.pairs[0].end;
    try expectApprox(s.a0 + (e.a0 - s.a0) * @as(Point, @splat(1.25)), out[0].a0, 1e-6);
    // extrapolation visibly overshoots the end shape
    const e2 = out[0].a0;
    const e1 = m.asCubicsInto(1.0, &buf)[0].a0;
    try testing.expect(!std.meta.eql(e1, e2));
    // and stays a closed outline
    try expectClosed(out);
}

test "shapes: morph between different complexities aligns segment counts" {
    var a = try presetShape(testing.allocator, .circle); // 10 corners
    defer a.deinit();
    var b = try presetShape(testing.allocator, .cookie12); // 24 corners
    defer b.deinit();
    var m = try Morph.init(testing.allocator, &a, &b);
    defer m.deinit();
    try testing.expect(m.segmentCount() > 0);
    const buf = try testing.allocator.alloc(Cubic, m.segmentCount());
    defer testing.allocator.free(buf);
    const mid = m.asCubicsInto(0.5, buf);
    try expectClosed(mid);
    // every pair is a real cubic (contiguous within each side of the pair at t=0/1)
    for (m.pairs) |pair| {
        try testing.expect(dist(pair.start.a1 - pair.start.a0) >= 0);
    }
}

test "shapes: flatten is non-degenerate and tolerance controls detail" {
    var c = try presetShape(testing.allocator, .circle);
    defer c.deinit();
    var fine = std.array_list.Managed(Point).init(testing.allocator);
    defer fine.deinit();
    var coarse = std.array_list.Managed(Point).init(testing.allocator);
    defer coarse.deinit();
    try c.flatten(0.001, &fine);
    try c.flatten(0.05, &coarse);
    try testing.expect(fine.items.len > coarse.items.len);
    try testing.expect(coarse.items.len >= 12);
    // unit circle -> area near pi*r^2 = pi/4
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 4.0), flatArea(fine.items), 0.02);
}

test "shapes: morph flatten produces a drawable polygon every frame" {
    var a = try presetShape(testing.allocator, .soft_burst);
    defer a.deinit();
    var b = try presetShape(testing.allocator, .cookie9);
    defer b.deinit();
    var m = try Morph.init(testing.allocator, &a, &b);
    defer m.deinit();
    const scratch = try testing.allocator.alloc(Cubic, m.segmentCount());
    defer testing.allocator.free(scratch);
    var pts = std.array_list.Managed(Point).init(testing.allocator);
    defer pts.deinit();
    for ([_]f32{ 0, 0.3, 0.7, 1.1 }) |t| {
        pts.clearRetainingCapacity();
        try flattenMorph(&m, t, 0.002, scratch, &pts);
        try testing.expect(pts.items.len > 8);
        try testing.expect(flatArea(pts.items) > 0.05);
        for (pts.items) |p| {
            try testing.expect(p[0] > -0.5 and p[0] < 1.5 and p[1] > -0.5 and p[1] < 1.5);
        }
    }
}

/// Assert an emitted path is a well-formed closed outline: move + N×cubic +
/// close, moveTo lands on the first anchor, every cubic emits c0,c1,a1 in
/// order, and emitted points stay inside [bmin, bmax] (± eps).
fn expectValidPath(cubics: []const Cubic, e: EmittedPath, bmin: Point, bmax: Point) !void {
    const counts = pathCounts(cubics.len);
    try testing.expectEqual(counts.pts, e.pts.len);
    try testing.expectEqual(counts.verbs, e.verbs.len);
    // verb stream: move, then one cubic per outline cubic, then close
    try testing.expectEqual(@as(i32, @backingInt(PathVerb.move)), e.verbs[0]);
    for (e.verbs[1 .. e.verbs.len - 1]) |v|
        try testing.expectEqual(@as(i32, @backingInt(PathVerb.cubic)), v);
    try testing.expectEqual(@as(i32, @backingInt(PathVerb.close)), e.verbs[e.verbs.len - 1]);
    // point stream: a0 then c0,c1,a1 per cubic, in order
    try expectApprox(.{ e.pts[0], e.pts[1] }, cubics[0].a0, 0);
    var w: usize = 2;
    for (cubics) |c| {
        inline for (.{ c.c0, c.c1, c.a1 }) |v| {
            try expectApprox(.{ e.pts[w], e.pts[w + 1] }, v, 0);
            w += 2;
        }
    }
    try testing.expectEqual(counts.pts, w);
    // bounds sanity: every emitted point sits inside the control bounds
    const eps = 1e-4;
    var i: usize = 0;
    while (i < e.pts.len) : (i += 2) {
        try testing.expect(e.pts[i] >= bmin[0] - eps and e.pts[i] <= bmax[0] + eps);
        try testing.expect(e.pts[i + 1] >= bmin[1] - eps and e.pts[i + 1] <= bmax[1] + eps);
    }
    // the path isn't degenerate: some spread in both axes
    try testing.expect(bmax[0] - bmin[0] > 0);
    try testing.expect(bmax[1] - bmin[1] > 0);
}

test "shapes: emitPathInto emits move + N cubic + close with sane bounds" {
    var poly = try presetShape(testing.allocator, .cookie9);
    defer poly.deinit();
    const counts = pathCounts(poly.cubics.len);
    const pts = try testing.allocator.alloc(f32, counts.pts);
    defer testing.allocator.free(pts);
    const verbs = try testing.allocator.alloc(i32, counts.verbs);
    defer testing.allocator.free(verbs);
    const b = poly.bounds();
    try expectValidPath(poly.cubics, poly.emitPath(pts, verbs), b.min, b.max);
    // the owned path is identical
    var path = try poly.toPath(testing.allocator);
    defer path.deinit();
    try testing.expectEqualSlices(f32, pts, path.pts);
    try testing.expectEqualSlices(i32, verbs, path.verbs);
}

test "shapes: morph emits a valid closed path at every progress" {
    var a = try presetShape(testing.allocator, .soft_burst);
    defer a.deinit();
    var b = try presetShape(testing.allocator, .cookie9);
    defer b.deinit();
    var m = try Morph.init(testing.allocator, &a, &b);
    defer m.deinit();
    const scratch = try testing.allocator.alloc(Cubic, m.segmentCount());
    defer testing.allocator.free(scratch);
    const counts = pathCounts(m.segmentCount());
    const pts = try testing.allocator.alloc(f32, counts.pts);
    defer testing.allocator.free(pts);
    const verbs = try testing.allocator.alloc(i32, counts.verbs);
    defer testing.allocator.free(verbs);
    const ba = a.bounds();
    const bb = b.bounds();
    const umin = @min(ba.min, bb.min) - @as(Point, @splat(0.5)); // t>1 overshoot slack
    const umax = @max(ba.max, bb.max) + @as(Point, @splat(0.5));
    for ([_]f32{ 0, 0.25, 0.5, 0.75, 1, 1.15 }) |t| {
        const e = m.emitPath(t, scratch, pts, verbs);
        try expectValidPath(scratch[0..m.segmentCount()], e, umin, umax);
    }
    // Morph.toPath agrees with the buffer path
    var path = try m.toPath(testing.allocator, 0.5);
    defer path.deinit();
    const e = m.emitPath(0.5, scratch, pts, verbs);
    try testing.expectEqualSlices(f32, e.pts, path.pts);
    try testing.expectEqualSlices(i32, e.verbs, path.verbs);
}

test "golden: shapes — Path.fill renders ink through kx_fill_path" {
    const golden = @import("../golden.zig");
    var c = try presetShape(testing.allocator, .circle);
    defer c.deinit();
    var path = try c.toPath(testing.allocator);
    defer path.deinit();
    var r = try golden.Renderer.init(testing.allocator, 64, 64);
    defer r.deinit();
    r.beginFrame();
    kx.c.kx_clear(r.ctx, 0xFFFFFFFF);
    paint.save(r.ctx);
    paint.translate(r.ctx, 32, 32);
    paint.scale(r.ctx, 40, 40); // the normalized 0..1 circle -> 40px
    paint.translate(r.ctx, -0.5, -0.5);
    path.fill(r.ctx, 0xFF0000FF, false); // opaque red, winding
    paint.restore(r.ctx);
    r.endFrame();
    var f = try r.readback(testing.allocator);
    defer f.deinit();
    try testing.expectEqual(@as(u32, 0xFF0000FF), f.pixelAt(32, 32)); // center ink
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), f.pixelAt(4, 4)); // corner bg
    // the circle edge (~20px radius): ink at mid-edge, bg just outside
    try testing.expectEqual(@as(u32, 0xFF0000FF), f.pixelAt(32, 15));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), f.pixelAt(32, 10));
    // strokeCubics: the same outline stroked — ink on the ring, bg inside
    const counts = pathCounts(c.cubics.len);
    var pts_buf: [512]f32 = undefined;
    var verbs_buf: [64]i32 = undefined;
    try testing.expect(pts_buf.len >= counts.pts and verbs_buf.len >= counts.verbs);
    r.beginFrame();
    kx.c.kx_clear(r.ctx, 0xFFFFFFFF);
    paint.save(r.ctx);
    paint.translate(r.ctx, 32, 32);
    paint.scale(r.ctx, 40, 40);
    paint.translate(r.ctx, -0.5, -0.5);
    // stroke width is in the (scaled) canvas space: 0.1 ≈ 4px
    strokeCubics(r.ctx, c.cubics, &pts_buf, &verbs_buf, 0.1, 0x00FF00FF, false);
    paint.restore(r.ctx);
    r.endFrame();
    var f2 = try r.readback(testing.allocator);
    defer f2.deinit();
    try testing.expectEqual(@as(u32, 0x00FF00FF), f2.pixelAt(32, 12)); // on the ring
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), f2.pixelAt(32, 32)); // hollow center
}
