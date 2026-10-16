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
//     the same stepped endKeylineSteps sequence Compose builds, step
//     interpolation weighted by each step's shift distance)
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
// Ported 1:1 from upstream (carousel/Carousel.kt, KeylineList.kt,
// Strategy.kt, Keylines.kt, KeylineSnapPosition.kt — androidx-main):
// createKeylinesWithPivot, multiBrowseKeylineList, uncontainedKeylineList,
// getStartKeylineSteps, getEndKeylineSteps, moveKeylineStep,
// getStepInterpolationPoints, get(Start|End)ShiftDistance,
// getKeylineListForScrollOffset, getSnapPositionOffset, and the
// Modifier.carouselItem mask+translation math (items keep their FULL
// natural size inside per-item mask wrappers — no content reflow).
//
// Remaining deviations: no contentPadding support (we never expose it),
// no hero/center-aligned strategy, no parallax; release settle uses our
// spatial spring seeded with the fling velocity (≈ TargetedFlingBehavior).
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
    if (!std.math.isFinite(viewport) or viewport <= 0 or preferred <= 0) return null;
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
    // Ratios are clamped before the int casts: absurd inputs (a 1e9px
    // viewport or a 0.01dp item) would otherwise overflow u32 → panic.
    const min_large_count: u32 = @intFromFloat(@min(4096, @max(1, @floor(min_avail_large / target_large))));
    const max_large_count: u32 = @intFromFloat(@min(4096, @ceil(viewport / target_large)));

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
    if (!std.math.isFinite(viewport) or viewport <= 0 or item_width <= 0) return null;
    const large_size = @min(item_width + spacing, viewport);
    // spacing == -item_width (or worse) collapses the item size to ≤0 —
    // the count division below would produce inf → intFromFloat panic.
    if (large_size <= 0) return null;
    const large_count: u32 = @intFromFloat(@min(4096, @max(1, @floor(viewport / large_size))));
    const remaining = viewport - @as(f32, @floatFromInt(large_count)) * large_size;
    const medium_count: u32 = if (remaining > 0) 1 else 0;
    const medium_size = mediumChildSize(large_size, remaining);
    return .{ .small_size = 0, .small_count = 0, .medium_size = medium_size, .medium_count = medium_count, .large_size = large_size, .large_count = large_count };
}

/// Compose `Keyline` (KeylineList.kt): the size an item takes when its
/// center is co-located with this keyline. `offset` is the ADJUSTED
/// position (post-shift); `unadjusted_offset` is the position items land
/// on without shifting (stride-based) — items compare their unadjusted
/// center against keyline unadjusted offsets, then morph toward the
/// interpolated keyline's size + offset. `cutoff` = how far the keyline
/// straddles the container edge (0 when fully inside or fully outside).
const Keyline = struct {
    size: f32,
    offset: f32,
    unadjusted_offset: f32,
    cutoff: f32 = 0,
    is_focal: bool = false,
    is_anchor: bool = false,
    is_pivot: bool = false,

    /// Compose `lerp(Keyline, Keyline, Float)` — flags follow the nearer
    /// endpoint.
    fn lerpTo(a: Keyline, b: Keyline, t: f32) Keyline {
        return .{
            .size = a.size + (b.size - a.size) * t,
            .offset = a.offset + (b.offset - a.offset) * t,
            .unadjusted_offset = a.unadjusted_offset + (b.unadjusted_offset - a.unadjusted_offset) * t,
            .cutoff = a.cutoff + (b.cutoff - a.cutoff) * t,
            .is_focal = if (t < 0.5) a.is_focal else b.is_focal,
            .is_anchor = if (t < 0.5) a.is_anchor else b.is_anchor,
            .is_pivot = if (t < 0.5) a.is_pivot else b.is_pivot,
        };
    }
};

/// A keyline as added by the strategy DSL (size + anchor flag; offsets are
/// computed by the pivot pass).
const TmpKeyline = struct { size: f32, is_anchor: bool = false };

/// Compose `KeylineList` — a fixed-capacity list (bounded port: 2 anchors
/// + up to a screenful of focal/non-focal keylines).
const KeylineList = struct {
    lines: [max_keylines]Keyline = undefined,
    count: usize = 0,
    // Cached indices (the upstream lazy vals — recomputed on every build).
    pivot_index: usize = 0,
    first_non_anchor_index: usize = 0,
    last_non_anchor_index: usize = 0,
    first_focal_index: usize = 0,
    last_focal_index: usize = 0,

    fn focalCount(kl: *const KeylineList) usize {
        return if (kl.count == 0) 0 else kl.last_focal_index - kl.first_focal_index + 1;
    }

    fn firstFocal(kl: *const KeylineList) Keyline {
        return kl.lines[kl.first_focal_index];
    }

    fn lastFocal(kl: *const KeylineList) Keyline {
        return kl.lines[kl.last_focal_index];
    }

    fn pivot(kl: *const KeylineList) Keyline {
        return kl.lines[kl.pivot_index];
    }

    /// Recompute the cached indices after building `lines` (upstream does
    /// this lazily via indexOfFirst/indexOfLast).
    fn rebuildIndex(kl: *KeylineList) void {
        kl.first_non_anchor_index = 0;
        kl.last_non_anchor_index = 0;
        kl.first_focal_index = 0;
        kl.last_focal_index = 0;
        kl.pivot_index = 0;
        var i: usize = 0;
        while (i < kl.count) : (i += 1) {
            const k = kl.lines[i];
            if (!k.is_anchor) kl.last_non_anchor_index = i;
            if (k.is_focal) kl.last_focal_index = i;
            if (k.is_pivot) kl.pivot_index = i;
        }
        i = kl.count;
        while (i > 0) {
            i -= 1;
            const k = kl.lines[i];
            if (!k.is_anchor) kl.first_non_anchor_index = i;
            if (k.is_focal) kl.first_focal_index = i;
        }
    }

    /// KeylineList.isFirstFocalItemAtStartOfContainer.
    fn isFirstFocalItemAtStart(kl: *const KeylineList) bool {
        const ff = kl.firstFocal();
        return ff.offset - ff.size / 2 >= 0 and kl.first_focal_index == kl.first_non_anchor_index;
    }

    /// KeylineList.isLastFocalItemAtEndOfContainer.
    fn isLastFocalItemAtEnd(kl: *const KeylineList, carousel_size: f32) bool {
        const lf = kl.lastFocal();
        return lf.offset + lf.size / 2 <= carousel_size and kl.last_focal_index == kl.last_non_anchor_index;
    }

    /// KeylineList.firstIndexAfterFocalRangeWithSize — the first index at
    /// or after the last focal keyline whose size equals `size` (or the
    /// last index when none matches).
    fn firstIndexAfterFocalRangeWithSize(kl: *const KeylineList, size: f32) usize {
        var i = kl.last_focal_index;
        while (i < kl.count) : (i += 1) {
            if (kl.lines[i].size == size) return i;
        }
        return kl.count - 1;
    }

    /// KeylineList.lastIndexBeforeFocalRangeWithSize.
    fn lastIndexBeforeFocalRangeWithSize(kl: *const KeylineList, size: f32) usize {
        var i = kl.first_focal_index;
        while (i > 0) {
            i -= 1;
            if (kl.lines[i].size == size) return i;
        }
        return 0;
    }

    /// KeylineList.getKeylineBefore — the index of the last keyline whose
    /// unadjustedOffset is < `unadjusted` (or 0 when none).
    fn keylineBeforeIndex(kl: *const KeylineList, unadjusted: f32) usize {
        var i = kl.count;
        while (i > 0) {
            i -= 1;
            if (kl.lines[i].unadjusted_offset < unadjusted) return i;
        }
        return 0;
    }

    /// KeylineList.getKeylineAfter — the index of the first keyline whose
    /// unadjustedOffset is >= `unadjusted` (or the last).
    fn keylineAfterIndex(kl: *const KeylineList, unadjusted: f32) usize {
        for (kl.lines[0..kl.count], 0..) |k, i| {
            if (k.unadjusted_offset >= unadjusted) return i;
        }
        return kl.count - 1;
    }

    /// Compose `lerp(KeylineList, KeylineList, Float)` — elementwise (the
    /// two lists always share the count — steps preserve it).
    fn lerpTo(a: *const KeylineList, b: *const KeylineList, t: f32) KeylineList {
        var out: KeylineList = .{ .count = a.count };
        for (a.lines[0..a.count], b.lines[0..b.count], 0..) |ka, kb, i| {
            out.lines[i] = ka.lerpTo(kb, t);
        }
        out.rebuildIndex();
        return out;
    }
};

/// isCutoffLeft — the keyline straddles the start edge.
fn isCutoffLeft(size: f32, offset: f32) bool {
    return offset - size / 2 < 0 and offset + size / 2 > 0;
}

/// isCutoffRight — the keyline straddles the end edge.
fn isCutoffRight(size: f32, offset: f32, carousel_size: f32) bool {
    return offset - size / 2 < carousel_size and offset + size / 2 > carousel_size;
}

/// KeylineListScopeImpl.findLastFocalIndex — the contiguous run of
/// focal-size items starting at the first focal.
fn findLastFocalIndex(tmp: []const TmpKeyline, first_focal: usize, focal_size: f32) usize {
    var last = first_focal;
    while (last + 1 < tmp.len and tmp[last + 1].size == focal_size) last += 1;
    return last;
}

/// The focal indices over a tmp keyline list: the first NON-ANCHOR item
/// whose size strictly exceeds the running max (scope.add semantics), then
/// the contiguous run of that size.
fn focalIndices(tmp: []const TmpKeyline) struct { first: usize, last: usize, size: f32 } {
    var first: usize = 0;
    var focal_size: f32 = 0;
    for (tmp, 0..) |k, i| {
        if (!k.is_anchor and k.size > focal_size) {
            first = i;
            focal_size = k.size;
        }
    }
    return .{ .first = first, .last = findLastFocalIndex(tmp, first, focal_size), .size = focal_size };
}

/// KeylineListScopeImpl.createKeylinesWithPivot — verbatim: place the
/// pivot at `pivot_offset`, then walk keylines away from it accumulating
/// size-based offsets (visual positions) and stride-based unadjusted
/// offsets (where an unshifted item's center lands).
fn createWithPivot(tmp: []const TmpKeyline, pivot_index: usize, pivot_offset: f32, first_focal_index: usize, last_focal_index: usize, item_main_size: f32, carousel_size: f32, spacing: f32) KeylineList {
    var kl: KeylineList = .{};
    if (tmp.len == 0 or pivot_index >= tmp.len or tmp.len > max_keylines) return kl;
    const pv = tmp[pivot_index];
    const pivot_cutoff: f32 = if (isCutoffLeft(pv.size, pivot_offset))
        pivot_offset - pv.size / 2
    else if (isCutoffRight(pv.size, pivot_offset, carousel_size))
        pivot_offset + pv.size / 2 - carousel_size
    else
        0;
    kl.lines[0] = .{
        .size = pv.size,
        .offset = pivot_offset,
        .unadjusted_offset = pivot_offset,
        .is_focal = pivot_index >= first_focal_index and pivot_index <= last_focal_index,
        .is_anchor = pv.is_anchor,
        .is_pivot = true,
        .cutoff = pivot_cutoff,
    };
    kl.count = 1;
    // Before the pivot: insert at the front, preserving tmp order.
    var offset = pivot_offset - item_main_size / 2 - spacing;
    var unadjusted = pivot_offset - item_main_size / 2 - spacing;
    var written: [max_keylines]Keyline = undefined;
    written[0] = kl.lines[0];
    var wc: usize = 1;
    var oi: usize = pivot_index;
    while (oi > 0) {
        oi -= 1;
        const t = tmp[oi];
        const t_off = offset - t.size / 2;
        const t_unadj = unadjusted - item_main_size / 2;
        const cutoff: f32 = if (isCutoffLeft(t.size, t_off)) @abs(t_off - t.size / 2) else 0;
        // shift the tail right by one, prepend
        std.mem.copyBackwards(Keyline, written[1 .. wc + 1], written[0..wc]);
        written[0] = .{
            .size = t.size,
            .offset = t_off,
            .unadjusted_offset = t_unadj,
            .is_focal = oi >= first_focal_index and oi <= last_focal_index,
            .is_anchor = t.is_anchor,
            .cutoff = cutoff,
        };
        wc += 1;
        offset -= t.size + spacing;
        unadjusted -= item_main_size + spacing;
    }
    // After the pivot: append.
    offset = pivot_offset + item_main_size / 2 + spacing;
    unadjusted = pivot_offset + item_main_size / 2 + spacing;
    for (tmp[pivot_index + 1 ..], pivot_index + 1..) |t, oi2| {
        const t_off = offset + t.size / 2;
        const t_unadj = unadjusted + item_main_size / 2;
        const cutoff: f32 = if (isCutoffRight(t.size, t_off, carousel_size)) t_off + t.size / 2 - carousel_size else 0;
        written[wc] = .{
            .size = t.size,
            .offset = t_off,
            .unadjusted_offset = t_unadj,
            .is_focal = oi2 >= first_focal_index and oi2 <= last_focal_index,
            .is_anchor = t.is_anchor,
            .cutoff = cutoff,
        };
        wc += 1;
        offset += t.size + spacing;
        unadjusted += item_main_size + spacing;
    }
    @memcpy(kl.lines[0..wc], written[0..wc]);
    kl.count = wc;
    kl.rebuildIndex();
    return kl;
}

/// keylineListOf(carouselSize, spacing, alignment) — the focal-index/pivot
/// derivation then the pivot pass. `alignment` is Start (-1) for our
/// multi_browse/uncontained strategies (Center only for hero, later).
fn keylineListOf(carousel_size: f32, spacing: f32, tmp: []const TmpKeyline) KeylineList {
    const f = focalIndices(tmp);
    // CarouselAlignment.Start: the pivot is the first focal, offset to the
    // focal half-size (the first large sits flush at the start edge).
    const pivot_offset = f.size / 2;
    return createWithPivot(tmp, f.first, pivot_offset, f.first, f.last, f.size, carousel_size, spacing);
}

/// moveKeylineAndCreateShiftedKeylineList — one step: move `src` to `dst`,
/// shift the pivot by the moved keyline's (size - cutoff + spacing) toward
/// the move direction, rebuild from the pivot.
fn moveKeylineStep(from: *const KeylineList, src: usize, dst: usize, carousel_size: f32, spacing: f32) KeylineList {
    const pivot_dir: f32 = if (src > dst) 1 else -1;
    const pivot_delta = (from.lines[src].size - from.lines[src].cutoff + spacing) * pivot_dir;
    const new_pivot_index: usize = @intCast(@max(0, @as(i32, @intCast(from.pivot_index)) + @as(i32, @intFromFloat(pivot_dir))));
    const new_pivot_offset = from.pivot().offset + pivot_delta;
    var tmp: [max_keylines]TmpKeyline = undefined;
    var tn: usize = 0;
    for (from.lines[0..from.count]) |k| {
        if (tn != src) {
            tmp[tn] = .{ .size = k.size, .is_anchor = k.is_anchor };
            tn += 1;
        }
    }
    // re-insert the moved keyline at dst
    std.mem.copyBackwards(TmpKeyline, tmp[dst + 1 .. tn + 1], tmp[dst..tn]);
    tmp[dst] = .{ .size = from.lines[src].size, .is_anchor = from.lines[src].is_anchor };
    tn += 1;
    const f = focalIndices(tmp[0..tn]);
    return createWithPivot(tmp[0..tn], new_pivot_index, new_pivot_offset, f.first, f.last, f.size, carousel_size, spacing);
}

/// getStartKeylineSteps — steps that move the focal range toward the
/// container start, one non-anchor keyline at a time (each step re-inserts
/// the first non-anchor keyline after the focal range, size-matched).
fn startKeylineSteps(defaults: *const KeylineList, carousel_size: f32, spacing: f32, out: *[max_steps]KeylineList) usize {
    var n: usize = 0;
    if (defaults.count == 0) return 0;
    out[n] = defaults.*;
    n += 1;
    if (defaults.isFirstFocalItemAtStart()) return n;
    const start_index = defaults.first_non_anchor_index;
    const num_steps = defaults.first_focal_index -| start_index;
    if (num_steps == 0 and defaults.firstFocal().cutoff > 0) {
        if (n < max_steps) {
            out[n] = moveKeylineStep(defaults, 0, 0, carousel_size, spacing);
            n += 1;
        }
        return n;
    }
    var i: usize = 0;
    while (i < num_steps and n < max_steps) : (i += 1) {
        const prev = &out[n - 1];
        const orig = start_index + i;
        var dst = defaults.count - 1;
        if (orig > 0) {
            const neighbor_size = defaults.lines[orig - 1].size;
            dst = prev.firstIndexAfterFocalRangeWithSize(neighbor_size) - 1;
        }
        out[n] = moveKeylineStep(prev, defaults.first_non_anchor_index, dst, carousel_size, spacing);
        n += 1;
    }
    return n;
}

/// getEndKeylineSteps — the mirror: move the last non-anchor keyline
/// before the focal range, one at a time, until the last focal rests at
/// the container end.
fn endKeylineSteps(defaults: *const KeylineList, carousel_size: f32, spacing: f32, out: *[max_steps]KeylineList) usize {
    var n: usize = 0;
    if (defaults.count == 0) return 0;
    out[n] = defaults.*;
    n += 1;
    if (defaults.isLastFocalItemAtEnd(carousel_size)) return n;
    const end_index = defaults.last_non_anchor_index;
    const num_steps = end_index -| defaults.last_focal_index;
    if (num_steps == 0 and defaults.lastFocal().cutoff > 0) {
        if (n < max_steps) {
            out[n] = moveKeylineStep(defaults, 0, 0, carousel_size, spacing);
            n += 1;
        }
        return n;
    }
    var i: usize = 0;
    while (i < num_steps and n < max_steps) : (i += 1) {
        const prev = &out[n - 1];
        const orig = end_index - i;
        var dst: usize = 0;
        if (orig < defaults.count - 1) {
            const neighbor_size = defaults.lines[orig + 1].size;
            dst = prev.lastIndexBeforeFocalRangeWithSize(neighbor_size) + 1;
        }
        out[n] = moveKeylineStep(prev, defaults.last_non_anchor_index, dst, carousel_size, spacing);
        n += 1;
    }
    return n;
}

/// getStepInterpolationPoints — unequally spaced [0..1] points per step,
/// weighted by each step's shift distance fraction of the total.
fn stepInterpolationPoints(total_shift: f32, steps: []const KeylineList, shifting_left: bool, out: *[max_steps]f32) void {
    out[0] = 0;
    if (total_shift == 0 or steps.len == 0) return;
    var i: usize = 1;
    while (i < steps.len) : (i += 1) {
        const dist = if (shifting_left)
            steps[i].lines[0].unadjusted_offset - steps[i - 1].lines[0].unadjusted_offset
        else
            steps[i - 1].lines[steps[i - 1].count - 1].unadjusted_offset - steps[i].lines[steps[i].count - 1].unadjusted_offset;
        const pct = dist / total_shift;
        out[i] = if (i == steps.len - 1) 1 else out[i - 1] + pct;
    }
}

/// Compose `lerp(outputMin, outputMax, inputMin, inputMax, value)` —
/// clamped remap.
fn remapClamp(out_min: f32, out_max: f32, in_min: f32, in_max: f32, v: f32) f32 {
    if (v <= in_min) return out_min;
    if (v >= in_max) return out_max;
    return out_min + (out_max - out_min) * ((v - in_min) / (in_max - in_min));
}

/// The carousel strategy (Compose Strategy): the default (start-aligned)
/// keyline list + the start/end shift steps the scroll morphs through.
const Strategy = struct {
    default_keylines: KeylineList = .{},
    start_steps: [max_steps]KeylineList = undefined,
    start_count: usize = 0,
    end_steps: [max_steps]KeylineList = undefined,
    end_count: usize = 0,
    start_shift_distance: f32 = 0,
    end_shift_distance: f32 = 0,
    start_shift_points: [max_steps]f32 = undefined,
    end_shift_points: [max_steps]f32 = undefined,
    /// itemMainAxisSize — the focal (fully unmasked) item main size.
    item_main_size: f32 = 0,
    /// Test-facing aliases (kept from v1): stride = L + spacing.
    stride: f32 = 0,
    large_size: f32 = 0,
    offset_max: f32 = 0,
    valid: bool = false,
    item_spacing: f32 = 0,

    /// getKeylineListForScrollOffset — the interpolated keyline list for
    /// the current scroll position (steps at both ends, default between).
    fn listForOffset(st: *const Strategy, offset: f32) KeylineList {
        const positive = @max(0, offset);
        const start_shift_offset = st.start_shift_distance;
        const end_shift_offset = @max(0, st.offset_max - st.end_shift_distance);
        if (positive >= start_shift_offset and positive <= end_shift_offset) {
            return st.default_keylines;
        }
        var interpolation: f32 = 0;
        var points: *const [max_steps]f32 = &st.start_shift_points;
        var steps: []const KeylineList = st.start_steps[0..st.start_count];
        if (positive > end_shift_offset) {
            interpolation = remapClamp(0, 1, end_shift_offset, st.offset_max, positive);
            points = &st.end_shift_points;
            steps = st.end_steps[0..st.end_count];
        } else {
            interpolation = remapClamp(1, 0, 0, start_shift_offset, positive);
        }
        if (steps.len == 0) return st.default_keylines;
        var from: usize = 0;
        var to: usize = 0;
        var stepped: f32 = 0;
        var lower = points[0];
        var i: usize = 1;
        while (i < steps.len) : (i += 1) {
            const upper = points[i];
            if (interpolation <= upper) {
                from = i - 1;
                to = i;
                stepped = remapClamp(0, 1, lower, upper, interpolation);
                break;
            }
            lower = upper;
        }
        return steps[from].lerpTo(&steps[to], stepped);
    }

    /// getSnapPositionOffset — the scroll offset that snaps `item_index`
    /// into the focal run (nearest aligned step).
    fn snapPositionOffset(st: *const Strategy, item_index: usize, item_count: usize) f32 {
        if (!st.valid) return 0;
        var offset = st.default_keylines.firstFocal().unadjusted_offset - st.item_main_size / 2;
        if (st.start_count > 0 and item_index <= st.start_count - 1) {
            const si = st.start_count - 1 - @min(item_index, st.start_count - 1);
            offset = st.start_steps[si].firstFocal().unadjusted_offset - st.item_main_size / 2;
        }
        const last_item = item_count -| 1;
        if (st.end_count > 0 and item_index >= last_item -| (st.end_count - 1) and item_count > st.default_keylines.focalCount()) {
            const si = st.end_count - 1 - @min(last_item -| item_index, st.end_count - 1);
            offset = st.end_steps[si].lastFocal().unadjusted_offset - st.item_main_size / 2;
        }
        return std.math.clamp(offset, 0, st.offset_max);
    }
};

const max_steps = 8;

// --- the scrollable strip ---

const CarouselState = struct {
    opts: CarouselOptions,
    scroll: scroll_mod.ScrollState = .{},
    /// The strategy (keyline geometry) of the last layout — kept for
    /// paint-free scroll snaps + tests.
    keylines: Strategy = .{},
    /// Per-pointer drag tracks (window-space x — see ScrollInput).
    tracks: [8]Track = @splat(.{ .pointer = 0, .x = 0, .active = false }),
    dragged: bool = false,
    /// Channel owning the release snap/fling spring — a retargeted play
    /// cancels it in place; a fresh grab cancels it directly.
    anim_channel: u8 = 0,
};

const Track = struct {
    pointer: u64,
    x: f32,
    active: bool,
    /// Content-space velocity EMA, px/ms (finger left = positive).
    vel: f32 = 0,
    last_ms: u64 = 0,
};

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

/// Build the strategy for the current viewport/options/item count:
/// arrangement → tmp keylines → pivot-built default list → start/end
/// shift steps + interpolation points (Carousel.kt CarouselPageSize /
/// Strategy ctor).
fn computeStrategy(n: *Node, s: *CarouselState) void {
    const viewport = n.bounds.w;
    const count = n.children.items.len;
    s.keylines = .{};
    const arr = switch (s.opts.variant) {
        .multi_browse => multiBrowseArrangement(viewport, s.opts.item_width, s.opts.item_spacing, count),
        .uncontained => uncontainedArrangement(viewport, s.opts.item_width, s.opts.item_spacing),
    } orelse return;
    if (arr.large_count == 0 or arr.large_size <= 0) return;

    const spacing = s.opts.item_spacing;
    const st = &s.keylines;
    st.stride = arr.large_size + spacing;
    st.large_size = arr.large_size;
    st.item_main_size = arr.large_size;
    st.item_spacing = spacing;
    // the content: n item slots of stride minus the trailing spacing
    s.scroll.content = @as(f32, @floatFromInt(count)) * st.stride - spacing;
    s.scroll.viewport = viewport;
    // Clamp against the new range: if the offset moved, every keyline
    // position shifts — damage the viewport.
    if (s.scroll.setOffset(s.scroll.offset)) n.markDirty();
    st.offset_max = s.scroll.maxOffset();

    // createLeftAlignedKeylineList: [anchorL][large×F][medium×M][small×S][anchorR]
    const left_anchor = switch (s.opts.variant) {
        .multi_browse => anchor_size,
        .uncontained => @max(@min(anchor_size, s.opts.item_width), arr.medium_size * 0.5),
    };
    var tmp: [max_keylines]TmpKeyline = undefined;
    var tn: usize = 0;
    tmp[tn] = .{ .size = left_anchor, .is_anchor = true };
    tn += 1;
    for (0..arr.large_count) |_| {
        tmp[tn] = .{ .size = arr.large_size };
        tn += 1;
    }
    for (0..arr.medium_count) |_| {
        tmp[tn] = .{ .size = arr.medium_size };
        tn += 1;
    }
    for (0..arr.small_count) |_| {
        tmp[tn] = .{ .size = arr.small_size };
        tn += 1;
    }
    tmp[tn] = .{ .size = anchor_size, .is_anchor = true };
    tn += 1;

    st.default_keylines = keylineListOf(viewport, spacing, tmp[0..tn]);
    st.start_count = startKeylineSteps(&st.default_keylines, viewport, spacing, &st.start_steps);
    st.end_count = endKeylineSteps(&st.default_keylines, viewport, spacing, &st.end_steps);
    // getStartShiftDistance / getEndShiftDistance
    st.start_shift_distance = if (st.start_count == 0) 0 else @max(0, st.start_steps[st.start_count - 1].lines[0].unadjusted_offset - st.start_steps[0].lines[0].unadjusted_offset);
    st.end_shift_distance = if (st.end_count == 0) 0 else @max(0, st.end_steps[0].lines[st.end_steps[0].count - 1].unadjusted_offset - st.end_steps[st.end_count - 1].lines[st.end_steps[st.end_count - 1].count - 1].unadjusted_offset);
    stepInterpolationPoints(st.start_shift_distance, st.start_steps[0..st.start_count], true, &st.start_shift_points);
    stepInterpolationPoints(st.end_shift_distance, st.end_steps[0..st.end_count], false, &st.end_shift_points);
    st.valid = st.default_keylines.count > 0 and viewport > 0 and st.item_main_size > 0;
}

/// The scroll offset of the nearest item-focal snap — getSnapPositionOffset
/// evaluated per item, nearest wins (singleAdvanceFlingBehavior's target).
fn snapOffset(s: *CarouselState, item_count: usize, offset: f32) f32 {
    const st = &s.keylines;
    const count = s.scroll.content + s.opts.item_spacing; // n*stride
    if (st.stride <= 0 or st.offset_max <= 0 or !std.math.isFinite(count)) return 0;
    // Bound the candidate count by the real item count before the cast —
    // a denormal stride would otherwise produce a huge/hanging loop.
    const n: usize = @intFromFloat(@max(1, @round(@min(count / st.stride, @as(f32, @floatFromInt(item_count))))));
    var best: f32 = 0;
    var best_d: f32 = std.math.inf(f32);
    for (0..n) |i| {
        const cand = st.snapPositionOffset(i, n);
        const d = @abs(cand - offset);
        if (d < best_d) {
            best_d = d;
            best = cand;
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
    settleSnap(n, s, 0);
}

/// Release settle: project the landing from the release velocity (v px/ms
/// × the decay horizon), then let the M3 spatial spring carry the strip to
/// the nearest item-focal candidate — seeded WITH the fling velocity, so a
/// fast release sails past an item before it settles. No timeline → snap
/// immediately (headless tests).
fn settleSnap(n: *Node, s: *CarouselState, v: f32) void {
    const projected = s.scroll.offset + v * 260; // ms: decay horizon
    const target = snapOffset(s, n.children.items.len, projected);
    if (ui.anim.timeline()) |tl| {
        const from: ui.anim.Vec4 = .{ s.scroll.offset, 0, 0, 0 };
        _ = tl.play(.{
            .kind = ui.anim.Animation.springAnim(from, .{ target, 0, 0, 0 }, s.opts.theme.motion.springs.spatial_spring, .{ v * 1000, 0, 0, 0 }),
            .from = from,
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = snapUpdateCb, .userdata = n },
        });
    } else {
        _ = applyScrollOffset(n, s, target);
    }
}

fn snapUpdateCb(userdata: ?*anyopaque, value: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    _ = applyScrollOffset(n, stateOf(n), value[0]);
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

/// Per-item mask (Compose Modifier.carouselItem): the item keeps its FULL
/// unmasked size as content; only the interpolated keyline's rect shows —
/// the wrapper's bounds ARE the visible band (so hit-testing lands on the
/// visible part) and the child inside is laid out at the item's natural
/// size, clipped by the wrapper's child_clip.
const mask_vtable = ui.node.VTable{
    .measure = struct {
        fn m(n: *Node, c: Constraints) Size {
            if (n.children.items.len == 0) return c.constrain(.{});
            return n.children.items[0].measure(c);
        }
    }.m,
    .layout = struct {
        fn l(n: *Node, b: Rect) void {
            _ = n;
            _ = b; // the carousel positions the item inside itself
        }
    }.l,
    .paint = struct {
        fn p(n: *Node, ctx: *kx.Ctx) void {
            _ = n;
            _ = ctx;
        }
    }.p,
    .child_clip = struct {
        fn c(n: *Node) Rect {
            return n.bounds; // clip the item's full-size content to the band
        }
    }.c,
    .deinit = struct {
        fn d(n: *Node) void {
            _ = n;
        }
    }.d,
};

/// Wrap any not-yet-masked child in a mask node (lazy — callers add plain
/// item children; the mask is internal chrome owned by the carousel).
fn ensureWrapped(n: *Node) void {
    var i: usize = 0;
    while (i < n.children.items.len) : (i += 1) {
        const c = n.children.items[i];
        if (c.vtable == &mask_vtable) continue;
        const m = Node.create(n.allocator, &mask_vtable) catch return;
        _ = n.remove(c);
        m.add(c);
        n.insert(i, m);
    }
}

fn carouselLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    ensureWrapped(n);
    computeStrategy(n, s);
    // a11y: attach .list_item to the mask wrappers (the item content keeps
    // its own semantics — a button in an item stays a button)
    for (n.children.items) |mask| {
        if (mask.semantics == null) {
            ui.semantics.attach(mask, .{ .role = .list_item, .focusable = true });
        }
    }
    const st = &s.keylines;
    if (!st.valid or n.children.items.len == 0) return;
    const ks = st.listForOffset(s.scroll.offset);
    const large = st.item_main_size;
    const stride = st.stride;
    const rtl = ui.i18n.direction() == .rtl;
    for (n.children.items, 0..) |mask, i| {
        // Modifier.carouselItem: the item center in unadjusted (stride)
        // space → bracketing keylines → the interpolated keyline drives the
        // mask size + the translation pinning masked edges together.
        const unadjusted_center = large / 2 + @as(f32, @floatFromInt(i)) * stride - s.scroll.offset;
        const bi = ks.keylineBeforeIndex(unadjusted_center);
        const ai = ks.keylineAfterIndex(unadjusted_center);
        const before = ks.lines[bi];
        const after = ks.lines[ai];
        const progress = if (bi == ai)
            1
        else
            std.math.clamp((unadjusted_center - before.unadjusted_offset) / (after.unadjusted_offset - before.unadjusted_offset), 0, 1);
        const ik = before.lerpTo(after, progress);
        const out_of_bounds = bi == ai; // beyond the first/last keyline
        var translation = ik.offset - unadjusted_center;
        if (out_of_bounds) {
            // beyond the first/last keyline: keep translating by the
            // masked-size ratio (Compose's outOfBoundsOffset)
            translation += (unadjusted_center - ik.unadjusted_offset) / ik.size;
        }
        const mask_center = unadjusted_center + translation;
        const mask_w = @max(0, ik.size);
        // the visible band is centered on the item center (the mask rect is
        // item-space symmetric around the middle)
        const screen_cx = if (rtl) bounds.x + bounds.w - mask_center else bounds.x + mask_center;
        mask.layout(.{ .x = screen_cx - mask_w / 2, .y = bounds.y, .w = mask_w, .h = bounds.h });
        // the item inside the mask: full natural size, centered on the same
        // point — the wrapper clip reveals only the band
        const item = mask.children.items[0];
        item.layout(.{ .x = screen_cx - large / 2, .y = bounds.y, .w = large, .h = bounds.h });
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
            t.* = .{ .pointer = ev.pointer, .x = ev.raw_x, .active = true, .last_ms = ev.time_ms };
            s.dragged = false;
            // A grab interrupts an in-flight snap — the strip follows the finger.
            if (ui.anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel));
            return false; // items handle taps
        },
        .up, .outside_down => {
            var v: f32 = 0;
            for (&s.tracks) |*t| {
                if (t.active and t.pointer == ev.pointer) {
                    // A finger held still before release carries no fling.
                    if (ev.time_ms -| t.last_ms <= 120) v = t.vel;
                    t.active = false;
                }
            }
            if (s.dragged) {
                s.dragged = false;
                settleSnap(n, s, v); // fling → spring onto the nearest item
            }
            return false;
        },
        .move => {},
        else => return false,
    }
    const router = input.current() orelse return false;
    const dragging = router.capturedNode(ev.pointer) != null;
    const t = trackFor(s, ev.pointer);
    const same = t.active and t.pointer == ev.pointer;
    const last = if (same) t.x else ev.raw_x;
    const last_ms = if (same) t.last_ms else ev.time_ms;
    var vel = if (same) t.vel else 0;
    if (ev.time_ms > last_ms) {
        // content-space velocity: finger left (dx < 0) scrolls forward
        const inst = (last - ev.raw_x) / @as(f32, @floatFromInt(ev.time_ms - last_ms));
        vel = vel * 0.65 + inst * 0.35;
    }
    t.* = .{ .pointer = ev.pointer, .x = ev.raw_x, .active = true, .vel = vel, .last_ms = ev.time_ms };
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
    // For 390dp / 186dp / 8dp the lowest-cost arrangement is [L][M][S]:
    // item i lands on keyline i+1 in unadjusted space, so item1 takes the
    // medium keyline's size and item2 the small's (verbatim upstream cost).
    const item1 = c.children.items[1];
    try std.testing.expectApproxEqAbs(ks.default_keylines.lines[2].size, item1.bounds.w, 0.01);
    const item2 = c.children.items[2];
    try std.testing.expectApproxEqAbs(ks.default_keylines.lines[3].size, item2.bounds.w, 0.01);
    try std.testing.expect(item2.bounds.w < item1.bounds.w);
    // an item past the last keyline is the 10dp anchor sliver (offscreen)
    const item5 = c.children.items[5];
    try std.testing.expect(item5.bounds.w <= anchor_size + 1);
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
    try std.testing.expectApproxEqAbs(snapped, snapOffset(s, c.children.items.len, snapped), 0.01);
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
