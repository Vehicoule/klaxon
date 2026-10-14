// Carousel (Phase 2d.5, M3 batch 4) — horizontal scrolling item strip in
// the two M3 strategies: multi-browse (items morph through large/medium/
// small keylines; the focused item is largest) and uncontained (fixed item
// width, one cut-off item at the end edge).
//
// Spec: m3.material.io/components/carousel + Compose Carousel.kt /
// Keylines.kt / KeylineList.kt / Strategy.kt / Arrangement.kt:
//   - multi_browse: the large/medium/small counts + sizes come from
//     Arrangement.findLowestCostArrangement (target small ≈ large/3 clamped
//     to [40, 56], medium = (large+small)/2, anchors 10dp slivers at the
//     edges; the arrangement is fitted to the viewport, preferring the
//     target large size)
//   - uncontained: as many full `item_width` items as fit + one cut-off
//     "medium" item at the end (calculateMediumChildSize; left anchor =
//     max(anchorSize, medium/2), right anchor = 10)
//   - keylines: items morph by where their center lands between the
//     blended keyline sizes (a static start-aligned list lerps toward the
//     mirrored end-aligned list as the scroll approaches the content end —
//     v1 approximates Compose's stepped endKeylineSteps)
//   - scroll: drag (raw_x, finger drags the content), wheel (delta_x or
//     delta_y), snap to the nearest item-focal alignment on release
//   - keyboard: left/right move by one item stride (mirrored in RTL —
//     "forward" is ArrowRight in LTR, ArrowLeft in RTL)
//   - a11y: the strip is a focusable `.list`; plain container children get
//     `.list_item` semantics (interactive children keep their own role)
//   - layout: item positions mirror in RTL (item 0 sits at the end edge,
//     scrolling "forward" moves content toward the start edge)
//   - children paint clipped to the viewport (items never bleed past the
//     strip); hit-testing uses each child's morphed bounds
//
// v1 deviations (documented, fixed later):
//   - The end-arrangement morph is a single linear keyline lerp over the
//     last leg of the scroll range (Compose shifts focal keylines one at a
//     time through the focal run — the visual result matches at the two
//     stops and midpoints are close).
//   - Items are LAID OUT at their morphed width (content resizes) instead
//     of Compose's mask-only clipping (an image crops the same; text
//     reflows instead of clipping).
//   - Snap is instant (no fling/spring animation — the anim pass is
//     Phase 3); the hero/fullscreen-center strategies and parallax/haptics
//     are not implemented.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const scroll_mod = @import("../ui/scroll.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

pub const CarouselVariant = enum { multi_browse, uncontained };

pub const CarouselOptions = struct {
    variant: CarouselVariant = .multi_browse,
    /// The main-axis item size target: the PREFERRED large-item width for
    /// multi_browse (the fitted result is clamped to the viewport), the
    /// EXACT item width for uncontained (no size morphing).
    item_width: f32 = 186,
    /// The M3 spacing between adjacent items (the spec's 8dp — Compose's
    /// default token is 0, every sample/guideline uses 8).
    item_spacing: f32 = 8,
    /// The semantic label of the strip (a list of items).
    label: []const u8 = "Carousel",
    theme: Theme = theme_mod.light,
};

/// M3 carousel constants (CarouselDefaults): the small-item size bounds,
/// the edge anchor sliver, and the medium/large similarity threshold.
const min_small: f32 = 40; // MinSmallItemSize
const max_small: f32 = 56; // MaxSmallItemSize
const anchor_size: f32 = 10; // AnchorSize
const medium_large_threshold: f32 = 0.85; // MediumLargeItemDiffThreshold
/// The pointer wheel scroll speed (px per wheel click — the scroll_util
/// default).
const wheel_speed: f32 = 48;
/// Max keylines: 2 anchors + up to a screenful of larges (bounded) + medium
/// + small.
const max_keylines = 16;

/// The fitted arrangement (Arrangement.findLowestCostArrangement port):
/// counts + adjusted sizes per size class.
const Arrangement = struct {
    small_size: f32 = 0,
    small_count: u32 = 0,
    medium_size: f32 = 0,
    medium_count: u32 = 0,
    large_size: f32 = 0,
    large_count: u32 = 0,

    fn itemCount(a: Arrangement) usize {
        return a.large_count + a.medium_count + a.small_count;
    }

    /// Arrangement.isValid: with all three classes present the sizes must
    /// strictly decrease (large > medium > small); with large+small only,
    /// large > small.
    fn isValid(a: Arrangement) bool {
        if (a.large_count > 0 and a.small_count > 0 and a.medium_count > 0) {
            return a.large_size > a.medium_size and a.medium_size > a.small_size;
        } else if (a.large_count > 0 and a.small_count > 0) {
            return a.large_size > a.small_size;
        }
        return true;
    }

    /// |targetLarge - largeSize| * priority (invalid → ∞).
    fn cost(a: Arrangement, priority: u32, target_large: f32) f32 {
        if (!a.isValid()) return std.math.inf(f32);
        return @abs(target_large - a.large_size) * @as(f32, @floatFromInt(priority));
    }
};

/// Arrangement.calculateLargeSize: solve availableSpace = L*count +
/// ((L+S)/2)*mediumCount + S*smallCount for L.
fn calcLargeSize(available: f32, small_count: u32, small_size: f32, medium_count: u32, large_count: u32) f32 {
    const sc: f32 = @floatFromInt(small_count);
    const mc: f32 = @floatFromInt(medium_count);
    const lc: f32 = @floatFromInt(large_count);
    return (available - (sc + mc / 2) * small_size) / (lc + mc / 2);
}

/// Arrangement.fit: adjust small → medium → large sizes until the
/// arrangement fits `available` (spacing already excluded).
fn fitArrangement(available: f32, spacing: f32, small_count: u32, small_size: f32, medium_count: u32, medium_size: f32, large_count: u32, large_size: f32) Arrangement {
    const total: f32 = @floatFromInt(large_count + medium_count + small_count);
    const avail_no_spacing = available - (total - 1) * spacing;
    var small = std.math.clamp(small_size, min_small, max_small);
    var medium = medium_size;
    var large = large_size;

    const taken = large * @as(f32, @floatFromInt(large_count)) + medium * @as(f32, @floatFromInt(medium_count)) + small * @as(f32, @floatFromInt(small_count));
    const delta = avail_no_spacing - taken;
    if (small_count > 0 and delta > 0) {
        small += @min(delta / @as(f32, @floatFromInt(small_count)), max_small - small);
    } else if (small_count > 0 and delta < 0) {
        small += @max(delta / @as(f32, @floatFromInt(small_count)), min_small - small);
    }
    if (small_count == 0) small = 0;
    large = calcLargeSize(avail_no_spacing, small_count, small, medium_count, large_count);
    medium = (large + small) / 2;

    // the medium item flexes ±10% to counter the large-size adjustment
    const flex: f32 = 0.1;
    if (medium_count > 0 and large != large_size) {
        const adjust = (large_size - large) * @as(f32, @floatFromInt(large_count));
        const flex_room = medium * flex * @as(f32, @floatFromInt(medium_count));
        const distribute = @min(@abs(adjust), flex_room);
        const mc: f32 = @floatFromInt(medium_count);
        const lc: f32 = @floatFromInt(large_count);
        if (adjust > 0) {
            medium -= distribute / mc;
            large += distribute / lc;
        } else {
            medium += distribute / mc;
            large -= distribute / lc;
        }
    }
    return .{ .small_size = small, .small_count = small_count, .medium_size = medium, .medium_count = medium_count, .large_size = large, .large_count = large_count };
}

/// Arrangement.findLowestCostArrangement: the lowest-|Δlarge|·priority
/// permutation over the count choices (priority order: largeCount desc,
/// then mediumCount, then smallCount).
fn lowestCostArrangement(available: f32, spacing: f32, target_small: f32, small_counts: []const u32, target_medium: f32, medium_counts: []const u32, target_large: f32, large_counts: []const u32) ?Arrangement {
    var best: ?Arrangement = null;
    var best_cost: f32 = std.math.inf(f32);
    var priority: u32 = 1;
    for (large_counts) |lc| {
        for (medium_counts) |mc| {
            for (small_counts) |sc| {
                const a = fitArrangement(available, spacing, sc, target_small, mc, target_medium, lc, target_large);
                const c = a.cost(priority, target_large);
                if (c < best_cost) {
                    best = a;
                    best_cost = c;
                    if (c == 0) return best;
                }
                priority += 1;
            }
        }
    }
    return best;
}

/// multiBrowseKeylineList: the arrangement the strategy fits to the
/// viewport (then trimmed to the item count: smalls then mediums drop).
fn multiBrowseArrangement(viewport: f32, preferred: f32, spacing: f32, item_count: usize) ?Arrangement {
    if (viewport <= 0 or preferred <= 0) return null;
    const small_counts_1 = [_]u32{1};
    const small_counts_0 = [_]u32{0};
    const small_counts_none = [_]u32{0};
    _ = small_counts_none;
    const medium_counts = [_]u32{ 1, 0 };
    var small_counts: []const u32 = &small_counts_1;
    if (viewport < min_small * 2) small_counts = &small_counts_0;

    const target_large = @min(preferred, viewport);
    const target_small = std.math.clamp(target_large / 3, min_small, max_small);
    const target_medium = (target_large + target_small) / 2;

    const min_avail_large = viewport - target_medium * 1 - max_small * 1;
    const min_large_count: u32 = @intFromFloat(@max(1, @floor(min_avail_large / target_large)));
    const max_large_count: u32 = @intFromFloat(@ceil(viewport / target_large));

    var large_buf: [8]u32 = undefined;
    var ln: usize = 0;
    var lc: u32 = max_large_count;
    while (lc >= min_large_count and ln < large_buf.len) : (lc -= 1) {
        large_buf[ln] = lc;
        ln += 1;
    }
    const large_counts = large_buf[0..ln];

    var arr = lowestCostArrangement(viewport, spacing, target_small, small_counts, target_medium, &medium_counts, target_large, large_counts) orelse return null;

    // trim the arrangement down to the item count: drop smalls, then
    // mediums (keep ≥1 medium so larges don't fill the whole strip).
    if (arr.itemCount() > item_count) {
        var surplus = arr.itemCount() - item_count;
        var sc = arr.small_count;
        var mc = arr.medium_count;
        while (surplus > 0) : (surplus -= 1) {
            if (sc > 0) sc -= 1 else if (mc > 1) mc -= 1;
        }
        const sc_arr = [_]u32{sc};
        const mc_arr = [_]u32{mc};
        arr = lowestCostArrangement(viewport, spacing, target_small, &sc_arr, target_medium, &mc_arr, target_large, large_counts) orelse return null;
    }
    return arr;
}

/// calculateMediumChildSize (uncontained): the cut-off item — ~2/3 visible
/// (remainingSpace*1.5), clamped so it differs enough from the large item
/// to produce scroll motion.
fn mediumChildSize(large_size: f32, remaining: f32) f32 {
    var medium = @max(anchor_size, remaining * 1.5);
    const threshold = large_size * medium_large_threshold;
    if (medium > threshold) {
        medium = @min(@max(threshold, remaining * 1.2), large_size);
    }
    return medium;
}

/// uncontainedKeylineList: F full items + (optionally) one cut-off medium.
fn uncontainedArrangement(viewport: f32, item_width: f32, spacing: f32) ?Arrangement {
    if (viewport <= 0 or item_width <= 0) return null;
    const large_size = @min(item_width + spacing, viewport);
    const large_count: u32 = @intFromFloat(@max(1, @floor(viewport / large_size)));
    const remaining = viewport - @as(f32, @floatFromInt(large_count)) * large_size;
    const medium_count: u32 = if (remaining > 0) 1 else 0;
    const medium_size = mediumChildSize(large_size, remaining);
    return .{ .small_size = 0, .small_count = 0, .medium_size = medium_size, .medium_count = medium_count, .large_size = large_size, .large_count = large_count };
}

/// One keyline: a size class at two scroll-alignment positions — the
/// start-aligned center and the end-aligned (zone-mirrored) center. During
/// the end-of-scroll morph the item size interpolates between them.
const Keyline = struct {
    start_center: f32,
    end_center: f32,
    size: f32,
};

/// The computed keyline set for the current layout (recomputed when the
/// viewport, spacing, variant or item count changes).
const Keylines = struct {
    lines: [max_keylines]Keyline = undefined,
    count: usize = 0,
    stride: f32 = 0,
    large_size: f32 = 0,
    /// The scroll offset where the end-arrangement morph completes.
    offset_max: f32 = 0,
    /// The scroll range over which the arrangement morphs start→end (the
    /// max distance any keyline travels).
    shift_span: f32 = 0,

    fn blendedCenter(k: Keyline, t: f32) f32 {
        return k.start_center + (k.end_center - k.start_center) * t;
    }

    /// The morph parameter: 0 = start-aligned, 1 = end-aligned (ramps over
    /// the last shift_span of the scroll range).
    fn tFor(ks: *const Keylines, offset: f32) f32 {
        if (ks.shift_span <= 0 or ks.offset_max <= 0) return 0;
        return std.math.clamp((offset - (ks.offset_max - ks.shift_span)) / ks.shift_span, 0, 1);
    }
};

// --- the scrollable strip ---

const CarouselState = struct {
    opts: CarouselOptions,
    scroll: scroll_mod.ScrollState = .{},
    /// The keyline geometry of the last layout (kept for paint-free
    /// scroll snaps + tests).
    keylines: Keylines = .{},
    /// Per-pointer drag tracks (window-space x — see ScrollInput).
    tracks: [8]Track = @splat(.{ .pointer = 0, .x = 0, .active = false }),
    dragged: bool = false,
};

const Track = struct { pointer: u64, x: f32, active: bool };

fn stateOf(n: *Node) *CarouselState {
    return @ptrCast(@alignCast(n.state.?));
}

fn trackFor(s: *CarouselState, pointer: u64) *Track {
    for (&s.tracks) |*t| {
        if (t.active and t.pointer == pointer) return t;
    }
    for (&s.tracks) |*t| {
        if (!t.active) return t;
    }
    return &s.tracks[0];
}

fn releaseTrack(s: *CarouselState, pointer: u64) void {
    for (&s.tracks) |*t| {
        if (t.active and t.pointer == pointer) t.active = false;
    }
}

/// Recompute the keyline set for the current viewport/options/item count:
/// the arrangement → the start-aligned + end-aligned keyline positions.
fn computeKeylines(n: *Node, s: *CarouselState) void {
    const viewport = n.bounds.w;
    const count = n.children.items.len;
    s.keylines = .{};
    const arr = switch (s.opts.variant) {
        .multi_browse => multiBrowseArrangement(viewport, s.opts.item_width, s.opts.item_spacing, count),
        .uncontained => uncontainedArrangement(viewport, s.opts.item_width, s.opts.item_spacing),
    } orelse return;
    if (arr.large_count == 0 or arr.large_size <= 0) return;

    const spacing = s.opts.item_spacing;
    const stride = arr.large_size + spacing;
    const ks = &s.keylines;
    ks.stride = stride;
    ks.large_size = arr.large_size;
    // the content: n item slots of stride minus the trailing spacing
    const content = @as(f32, @floatFromInt(count)) * stride - spacing;
    s.scroll.content = content;
    s.scroll.viewport = viewport;
    // Clamp against the new range: if the offset moved, every keyline
    // position shifts — damage the viewport.
    if (s.scroll.setOffset(s.scroll.offset)) n.markDirty();
    ks.offset_max = s.scroll.maxOffset();

    const left_anchor = switch (s.opts.variant) {
        .multi_browse => anchor_size,
        .uncontained => @max(@min(anchor_size, s.opts.item_width), arr.medium_size * 0.5),
    };
    const right_anchor = anchor_size;

    // START-aligned centers (createLeftAlignedKeylineList):
    //   [anchorL][large×F][medium×M][small×S][anchorR]
    var i: usize = 0;
    const first_focal = arr.large_size / 2;
    var last_focal = first_focal;
    ks.lines[i] = .{ .start_center = first_focal - (arr.large_size + left_anchor) / 2 - spacing, .end_center = 0, .size = left_anchor };
    i += 1;
    const focal_start = i;
    for (0..arr.large_count) |f| {
        const c = first_focal + @as(f32, @floatFromInt(f)) * stride;
        ks.lines[i] = .{ .start_center = c, .end_center = 0, .size = arr.large_size };
        last_focal = c;
        i += 1;
    }
    var prev_size = arr.large_size;
    var prev_center = last_focal;
    for (0..arr.medium_count) |_| {
        const c = prev_center + (prev_size + arr.medium_size) / 2 + spacing;
        ks.lines[i] = .{ .start_center = c, .end_center = 0, .size = arr.medium_size };
        prev_center = c;
        prev_size = arr.medium_size;
        i += 1;
    }
    for (0..arr.small_count) |_| {
        const c = prev_center + (prev_size + arr.small_size) / 2 + spacing;
        ks.lines[i] = .{ .start_center = c, .end_center = 0, .size = arr.small_size };
        prev_center = c;
        prev_size = arr.small_size;
        i += 1;
    }
    ks.lines[i] = .{ .start_center = prev_center + (prev_size + right_anchor) / 2 + spacing, .end_center = 0, .size = right_anchor };
    i += 1;
    ks.count = i;

    // END-aligned centers (the zone-mirrored arrangement, focal run flush
    // to the end edge): [anchorL][small][medium][large×F][anchorR].
    const end_last_focal = viewport - arr.large_size / 2;
    // focal keylines (in order): end centers step back from the last
    for (0..arr.large_count) |f| {
        ks.lines[focal_start + f].end_center = end_last_focal - @as(f32, @floatFromInt(arr.large_count - 1 - @as(u32, @intCast(f)))) * stride;
    }
    // medium zones sit left of the first end focal, small left of medium
    var eprev_center = ks.lines[focal_start].end_center;
    var eprev_size = arr.large_size;
    // walk the non-focal keylines in REVERSE order (small nearest anchor)
    // — medium sits adjacent to the focal run, small outside it
    var nonfocal: [4]usize = .{ 0, 0, 0, 0 };
    var nn: usize = 0;
    if (arr.small_count > 0) {
        // small keyline is the one BEFORE the right anchor in start order
        nonfocal[nn] = focal_start + arr.large_count + arr.medium_count; // small index
        nn += 1;
    }
    if (arr.medium_count > 0) {
        nonfocal[nn] = focal_start + arr.large_count; // medium index
        nn += 1;
    }
    // nonfocal now lists [small?, medium?] in the end-order (nearest to
    // anchorL first); fill their end centers walking left from the focal
    var k: usize = nn;
    while (k > 0) {
        k -= 1;
        const idx = nonfocal[k];
        const c = eprev_center - (eprev_size + ks.lines[idx].size) / 2 - spacing;
        ks.lines[idx].end_center = c;
        eprev_center = c;
        eprev_size = ks.lines[idx].size;
    }
    // anchors: left anchor leftmost, right anchor past the last end focal
    ks.lines[0].end_center = eprev_center - (eprev_size + left_anchor) / 2 - spacing;
    ks.lines[ks.count - 1].end_center = end_last_focal + (arr.large_size + right_anchor) / 2 + spacing;

    // the morph span: the max distance any keyline travels start→end
    var span: f32 = 0;
    for (ks.lines[0..ks.count]) |kl| {
        span = @max(span, @abs(kl.end_center - kl.start_center));
    }
    ks.shift_span = @min(span, ks.offset_max);
}

/// The item width at a viewport-space center x under the blended keylines.
fn keylineSizeAt(ks: *const Keylines, t: f32, x: f32) f32 {
    if (ks.count == 0) return 0;
    // find the two blended keyline centers bracketing x (centers may cross
    // mid-morph — scan for the immediate neighbors)
    var lo: usize = 0;
    var hi: usize = 0;
    var lo_c: f32 = -std.math.inf(f32);
    var hi_c: f32 = std.math.inf(f32);
    for (0..ks.count) |j| {
        const c = Keylines.blendedCenter(ks.lines[j], t);
        if (c <= x and c > lo_c) {
            lo = j;
            lo_c = c;
        }
        if (c >= x and c < hi_c) {
            hi = j;
            hi_c = c;
        }
    }
    if (lo_c == -std.math.inf(f32)) return ks.lines[hi].size; // left of all
    if (hi_c == std.math.inf(f32)) return ks.lines[lo].size; // right of all
    if (hi == lo or hi_c == lo_c) return ks.lines[lo].size;
    const frac = (x - lo_c) / (hi_c - lo_c);
    return ks.lines[lo].size + (ks.lines[hi].size - ks.lines[lo].size) * frac;
}

/// The scroll offset of the nearest item-focal snap: candidates are the
/// stride-multiples under both alignments (start: k*stride; end:
/// k*stride + endShift where endShift = offset_max - (n-F)*stride).
fn snapOffset(s: *CarouselState, offset: f32) f32 {
    const ks = &s.keylines;
    const count = s.scroll.content + s.opts.item_spacing; // n*stride
    const stride = ks.stride;
    if (stride <= 0 or ks.offset_max <= 0) return 0;
    const n_f: f32 = count / stride;
    const large_count: f32 = blk: {
        var f: f32 = 0;
        for (ks.lines[0..ks.count]) |kl| {
            if (kl.size == ks.large_size) f += 1;
        }
        break :blk f;
    };
    const end_shift = ks.offset_max - @max(0, n_f - large_count) * stride;
    const k_max = @max(0, n_f - large_count);
    var best: f32 = 0;
    var best_d: f32 = std.math.inf(f32);
    var k: f32 = 0;
    while (k <= k_max) : (k += 1) {
        const cand_a = std.math.clamp(k * stride, 0, ks.offset_max);
        const cand_b = std.math.clamp(k * stride + end_shift, 0, ks.offset_max);
        for ([2]f32{ cand_a, cand_b }) |cand| {
            const d = @abs(cand - offset);
            if (d < best_d) {
                best_d = d;
                best = cand;
            }
        }
    }
    return best;
}

fn applyScrollOffset(n: *Node, s: *CarouselState, value: f32) bool {
    if (!s.scroll.setOffset(value)) return false;
    n.markLayoutDirty(); // item positions/widths follow the offset
    n.markDirty();
    return true;
}

/// Snap the scroll to the nearest item-focal alignment (called on release
/// + after a wheel click when the pointer rests on the strip — wheel
/// scrolling stays free; the snap applies on the next drag release).
fn snapNow(n: *Node, s: *CarouselState) void {
    _ = applyScrollOffset(n, s, snapOffset(s, s.scroll.offset));
}

fn carouselMeasure(n: *Node, c: Constraints) Size {
    var max_h: f32 = 0;
    for (n.children.items) |child| {
        const cs = child.measure(c);
        max_h = @max(max_h, cs.h);
    }
    const w = if (std.math.isFinite(c.max_w)) c.max_w else 400;
    return c.constrain(.{ .w = w, .h = max_h });
}

fn carouselLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    const count = n.children.items.len;
    computeKeylines(n, s);
    // a11y: attach .list_item to plain-container children (interactive
    // children keep their own semantics — a button in an item stays a button)
    for (n.children.items) |child| {
        if (child.semantics == null) {
            ui.semantics.attach(child, .{ .role = .list_item, .focusable = true });
        }
    }
    if (count == 0) return;
    const ks = &s.keylines;
    const t = Keylines.tFor(ks, s.scroll.offset);
    const rtl = ui.i18n.direction() == .rtl;
    for (n.children.items, 0..) |child, i| {
        // the item center in local (viewport) space: large/2 + i*stride -
        // offset; its width morphs between the blended keylines
        const center = ks.large_size / 2 + @as(f32, @floatFromInt(i)) * ks.stride - s.scroll.offset;
        const w = @max(0, keylineSizeAt(ks, t, center));
        var x = bounds.x + center - w / 2;
        if (rtl) {
            // mirror the item around the viewport — item 0 sits at the
            // end edge, scrolling "forward" moves content toward start
            x = bounds.x + bounds.w - center - w / 2;
        }
        child.layout(.{ .x = x, .y = bounds.y, .w = w, .h = bounds.h });
    }
}

/// The children paint clipped to the viewport (an item never bleeds past
/// the strip's edge — the anchor keylines' slivers stay inside).
fn carouselPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    ui.paint.clipRect(ctx, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h); // saves
}

fn carouselPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.clipReset(ctx); // restores
}

fn carouselChildClip(n: *Node) Rect {
    return n.bounds;
}

fn carouselPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}

/// Drag-to-scroll (horizontal — the ScrollInput pattern on raw_x) + the
/// snap on release. Tracks are per-pointer (concurrent fingers never jump).
fn carouselOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    switch (ev.phase) {
        .down => {
            const t = trackFor(s, ev.pointer);
            t.* = .{ .pointer = ev.pointer, .x = ev.raw_x, .active = true };
            s.dragged = false;
            return false; // items handle taps
        },
        .up, .outside_down => {
            releaseTrack(s, ev.pointer);
            if (s.dragged) {
                s.dragged = false;
                snapNow(n, s); // snap to the nearest item on release
            }
            return false;
        },
        .move => {},
        else => return false,
    }
    const router = input.current() orelse return false;
    const dragging = router.capturedNode(ev.pointer) != null;
    const t = trackFor(s, ev.pointer);
    const last = if (t.active and t.pointer == ev.pointer) t.x else ev.raw_x;
    t.* = .{ .pointer = ev.pointer, .x = ev.raw_x, .active = true };
    if (!dragging) return false; // hover move: no scroll
    const dx = ev.raw_x - last;
    if (dx == 0) return false;
    // the finger drags the content: moving left (dx < 0) scrolls forward
    s.dragged = true;
    return applyScrollOffset(n, s, s.scroll.offset - dx);
}

/// Wheel scroll (delta_x when present, else delta_y mapped to the
/// horizontal strip).
fn carouselOnScroll(n: *Node, ev: input.ScrollEvent) bool {
    const s = stateOf(n);
    if (!s.scroll.info().canScroll()) return false;
    const delta = if (ev.delta_x != 0) ev.delta_x else ev.delta_y;
    if (delta == 0) return false;
    return applyScrollOffset(n, s, s.scroll.offset - delta * wheel_speed);
}

/// Keyboard: arrow keys scroll by one item stride — "forward" is
/// ArrowRight in LTR, ArrowLeft in RTL.
fn carouselOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind != .key_down) return false;
    const ks = &s.keylines;
    if (ks.stride <= 0) return false;
    const rtl = ui.i18n.direction() == .rtl;
    const forward = if (rtl) ev.key == .left else ev.key == .right;
    const backward = if (rtl) ev.key == .right else ev.key == .left;
    if (!forward and !backward) return false;
    const step = if (forward) ks.stride else -ks.stride;
    return applyScrollOffset(n, s, s.scroll.offset + step);
}

fn carouselScrollInfo(n: *Node) scroll_mod.ScrollInfo {
    const s = stateOf(n);
    return s.scroll.info();
}

fn carouselSetOffset(n: *Node, offset: f32) void {
    const s = stateOf(n);
    _ = applyScrollOffset(n, s, offset);
}

fn carouselDeinit(n: *Node) void {
    const s = stateOf(n);
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const carousel_vtable = ui.node.VTable{
    .measure = carouselMeasure,
    .layout = carouselLayout,
    .paint = carouselPaint,
    .deinit = carouselDeinit,
    .on_pointer = carouselOnPointer,
    .on_key = carouselOnKey,
    .on_scroll = carouselOnScroll,
    .scroll_info = carouselScrollInfo,
    .scroll_set_offset = carouselSetOffset,
    .pre_children_paint = carouselPreChildrenPaint,
    .post_children_paint = carouselPostChildrenPaint,
    .child_clip = carouselChildClip,
    // auto_retain: the viewport clip bounds the extent — an idle carousel
    // is one blit; any drag/snap marks the subtree → direct paint.
    .auto_retain = true,
};

/// An M3 carousel: a horizontal scrolling strip of item children
/// (document data — not internal chrome). `variant` selects the strategy:
/// multi_browse fits large/medium/small keylines to the viewport;
/// uncontained keeps `item_width` fixed with a cut-off item at the edge.
/// The strip is a focusable `.list` (arrow-key scroll); plain-container
/// children get `.list_item` semantics.
pub fn carousel(allocator: std.mem.Allocator, opts: CarouselOptions) !*Node {
    const node = try Node.create(allocator, &carousel_vtable);
    errdefer allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(CarouselState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts };
    node.state = s;
    ui.semantics.attach(node, .{
        .role = .list,
        .label = opts.label,
        .focusable = true, // takes the keyboard focus (arrow nav)
    });
    return node;
}

/// The current scroll offset (gallery state save/restore — like
/// scroll_view.scrollOffset).
pub fn scrollOffset(n: *Node) f32 {
    return stateOf(n).scroll.offset;
}

/// Set the scroll offset (clamped to the strip's range); returns whether
/// the offset changed.
pub fn setScrollOffset(n: *Node, value: f32) bool {
    return applyScrollOffset(n, stateOf(n), value);
}

// --- tests ---

/// The arrangement: viewport 390, preferred 186, spacing 8 → [L][L][M][S]
/// (2 larges + 1 medium + 1 small fitted to fill).
fn arrangeFixture(viewport: f32, preferred: f32, spacing: f32, items: usize) ?Arrangement {
    return multiBrowseArrangement(viewport, preferred, spacing, items);
}

test "carousel multi_browse: arrangement sizes large>medium>small, fills the viewport" {
    const a = arrangeFixture(390, 186, 8, 10).?;
    try std.testing.expect(a.large_count >= 1);
    try std.testing.expectEqual(@as(u32, 1), a.medium_count);
    try std.testing.expectEqual(@as(u32, 1), a.small_count);
    // sizes strictly decrease, small stays within [40, 56]
    try std.testing.expect(a.large_size > a.medium_size);
    try std.testing.expect(a.medium_size > a.small_size);
    try std.testing.expect(a.small_size >= min_small and a.small_size <= max_small);
    // the arrangement fills the viewport (sizes + spacing = 390)
    const total = a.large_size * @as(f32, @floatFromInt(a.large_count)) + a.medium_size * @as(f32, @floatFromInt(a.medium_count)) + a.small_size * @as(f32, @floatFromInt(a.small_count)) + 8 * @as(f32, @floatFromInt(a.itemCount() - 1));
    try std.testing.expectApproxEqAbs(@as(f32, 390), total, 0.01);
}

test "carousel multi_browse: item count trims smalls then mediums" {
    // 3 items fill the [L][M][S] zones exactly — nothing to trim
    const a3 = arrangeFixture(390, 186, 8, 3).?;
    try std.testing.expect(a3.itemCount() <= 3 + 0); // the zones ≤ the items
    // 2 items: the small zone drops (the medium zone stays — larges
    // never fill the whole strip alone)
    const a2 = arrangeFixture(390, 186, 8, 2).?;
    try std.testing.expectEqual(@as(u32, 0), a2.small_count);
    try std.testing.expectEqual(@as(u32, 1), a2.medium_count);
    // 1 item: only the large + medium zones remain (≥1 medium per the spec)
    const a1 = arrangeFixture(390, 186, 8, 1).?;
    try std.testing.expect(a1.large_count >= 1);
    try std.testing.expectEqual(@as(u32, 0), a1.small_count);
}

test "carousel uncontained: full items + one cut-off medium at the end" {
    const a = uncontainedArrangement(390, 186, 8).?;
    try std.testing.expectEqual(@as(u32, 2), a.large_count); // floor(390/194)=2
    try std.testing.expectEqual(@as(u32, 1), a.medium_count);
    // the cut-off item: remaining*1.5 (vs the large threshold)
    try std.testing.expectEqual(@as(f32, 186 + 8), a.large_size);
    const remaining = @as(f32, 390) - 2 * 194;
    try std.testing.expectApproxEqAbs(mediumChildSize(194, remaining), a.medium_size, 0.01);
    // medium differs enough from large (< 85% of it)
    try std.testing.expect(a.medium_size < a.large_size * medium_large_threshold + 0.01);
}

test "carousel layout: items land at keyline positions with morphing widths" {
    const c = try carousel(std.testing.allocator, .{ .item_width = 186 });
    defer c.deinit();
    for (0..8) |_| {
        const child = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF0000FF);
        c.add(child);
    }
    c.layout(.{ .x = 0, .y = 0, .w = 390, .h = 120 });
    const s = stateOf(c);
    const ks = &s.keylines;
    // item 0 at the first focal slot: width = large_size, center = large/2
    const first = c.children.items[0];
    try std.testing.expectApproxEqAbs(ks.large_size, first.bounds.w, 0.01);
    try std.testing.expectApproxEqAbs(ks.large_size / 2, first.bounds.x + first.bounds.w / 2, 0.01);
    // the second item morphs into the medium zone (narrower than focal)
    const item1 = c.children.items[1];
    try std.testing.expect(item1.bounds.w < ks.large_size);
    // an item past the last keyline is the 10dp anchor sliver (offscreen)
    const item2 = c.children.items[2];
    try std.testing.expect(item2.bounds.w <= anchor_size + 1);
}

test "carousel drag: moves the content, snaps to an item on release" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const c = try carousel(std.testing.allocator, .{ .item_width = 186 });
    defer c.deinit();
    for (0..10) |_| {
        const child = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF0000FF);
        c.add(child);
    }
    c.layout(.{ .x = 0, .y = 0, .w = 390, .h = 120 });
    const s = stateOf(c);
    // drag left 100 → offset +100; release → snap to a stride multiple
    router.dispatchPointer(c, .{ .phase = .down, .x = 200, .y = 60 });
    router.dispatchPointer(c, .{ .phase = .move, .x = 100, .y = 60 });
    try std.testing.expectApproxEqAbs(@as(f32, 100), s.scroll.offset, 0.01);
    router.dispatchPointer(c, .{ .phase = .up, .x = 100, .y = 60 });
    // the offset is a snap candidate (item-focal under an alignment) and
    // snapping again is a no-op
    const snapped = s.scroll.offset;
    try std.testing.expectApproxEqAbs(snapped, snapOffset(s, snapped), 0.01);
    // it moved from the free-drag offset to the snap
    try std.testing.expect(snapped != 100);
}

test "carousel keyboard: arrows scroll by one item stride (forward = right)" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const c = try carousel(std.testing.allocator, .{ .item_width = 120 });
    defer c.deinit();
    for (0..8) |_| {
        const child = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF0000FF);
        c.add(child);
    }
    c.layout(.{ .x = 0, .y = 0, .w = 300, .h = 100 });
    const s = stateOf(c);
    router.focus(c);
    const on_key = c.vtable.on_key.?;
    try std.testing.expect(on_key(c, .{ .kind = .key_down, .key = .right }));
    try std.testing.expectApproxEqAbs(s.keylines.stride, s.scroll.offset, 0.01);
    try std.testing.expect(on_key(c, .{ .kind = .key_down, .key = .left }));
    try std.testing.expectApproxEqAbs(@as(f32, 0), s.scroll.offset, 0.01);
}

test "carousel semantics: list role, items get list_item; scroll_info reports the strip" {
    const c = try carousel(std.testing.allocator, .{ .item_width = 100 });
    defer c.deinit();
    for (0..6) |_| {
        const child = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF0000FF);
        c.add(child);
    }
    try std.testing.expectEqual(ui.semantics.Role.list, c.semantics.?.role);
    try std.testing.expect(c.semantics.?.focusable);
    c.layout(.{ .x = 0, .y = 0, .w = 300, .h = 100 });
    for (c.children.items) |child| {
        try std.testing.expectEqual(ui.semantics.Role.list_item, child.semantics.?.role);
        try std.testing.expect(child.semantics.?.focusable);
    }
    const info = c.vtable.scroll_info.?(c);
    try std.testing.expectEqual(@as(f32, 300), info.viewport);
    try std.testing.expect(info.content > info.viewport); // 6 items > 300
    try std.testing.expect(info.canScroll());
}

test "golden: multi_browse carousel paints the focal item largest, edge items morph" {
    const c = try carousel(std.testing.allocator, .{ .item_width = 186 });
    defer c.deinit();
    const colors = [_]Color{ 0xFF0000FF, 0x00FF00FF, 0x0000FFFF, 0xFFFF00FF, 0xFF00FFFF };
    for (colors) |col| {
        const child = try golden.solidBox(std.testing.allocator, 10, 10, col);
        c.add(child);
    }
    var r = try golden.Renderer.init(std.testing.allocator, 390, 120);
    defer r.deinit();
    c.layout(.{ .x = 0, .y = 0, .w = 390, .h = 120 });
    r.paint(c, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the first item fills its focal slot: its color spans the left edge
    const item0 = c.children.items[0];
    try std.testing.expectEqual(colors[0], f.pixelAt(4, 60));
    // item 0's width = the large keyline (the biggest painted item)
    var widest: f32 = 0;
    for (c.children.items) |child| widest = @max(widest, child.bounds.w);
    try std.testing.expectApproxEqAbs(item0.bounds.w, widest, 0.01);
    // the edge item is narrower than the focal (morphed small/medium)
    const item4 = c.children.items[4];
    try std.testing.expect(item4.bounds.w < item0.bounds.w);
}

test "golden: uncontained carousel keeps every focal item at the slot width" {
    const c = try carousel(std.testing.allocator, .{ .variant = .uncontained, .item_width = 150 });
    defer c.deinit();
    for (0..6) |_| {
        const child = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF0000FF);
        c.add(child);
    }
    c.layout(.{ .x = 0, .y = 0, .w = 390, .h = 100 });
    // the focal items measure item_width + item_spacing wide (Compose's
    // uncontainedKeylineList: the slot includes the inter-item gap)
    try std.testing.expectEqual(@as(f32, 158), c.children.items[0].bounds.w);
    try std.testing.expectEqual(@as(f32, 158), c.children.items[1].bounds.w);
    // the cut-off edge item is narrower (the medium keyline)
    try std.testing.expect(c.children.items[2].bounds.w <= 158);
}
