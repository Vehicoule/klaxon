// An M3E single-choice segmented button row: equal-width segments with a
// 1dp outlined border, one selected (SecondaryContainer), driven by an
// external Signal(usize) (single choice = radio-group semantics: the arrow
// keys move AND select).
//
// Spec: m3.material.io/components/segmented-buttons + Compose
// SegmentedButton.kt (SingleChoiceSegmentedButtonRow / SegmentedButton) +
// OutlinedSegmentedButtonTokens:
//   - row: segments are EQUAL width (weight 1f over the row's IntrinsicSize
//     .Min — the mean of the contents, floored at ButtonDefaults.MinWidth
//     58dp), 40dp tall (ContainerHeight); the segments OVERLAP by the
//     border width (spacedBy(-space), space = OutlineWidth = 1dp) so the
//     borders coincide — no double border
//   - shapes (itemShape on CornerFull): count == 1 -> full; first -> the
//     start side full (tl/bl = h/2); last -> the end side full (tr/br = h/2);
//     middle -> square. RTL mirrors the row and the shapes
//   - segment: 1dp Outline border (disabled: Outline @ 0.12 — upstream's
//     disabled*BorderColor = OutlineColor.copy(0.12)), label label_large,
//     18dp icon slot + 8dp gap RESERVED for every segment (Compose's
//     SegmentedButtonContentMeasurePolicy always includes max(IconSize,
//     iconWidth) + IconSpacing; an empty slot re-centers the label),
//     content padding 12dp start/end
//   - paint order: Compose zIndex = interactionCount + checked*5 — a
//     pressed unchecked segment paints over quiet neighbours, the checked
//     segment over everyone (the higher-z claims the shared 1dp border);
//     the focused segment carries the 0.10 focus layer (the Klaxon row's
//     virtual focus is the selected segment)
//   - colors: selected = SecondaryContainer fill + OnSecondaryContainer
//     content; unselected = transparent fill + OnSurface content; disabled =
//     OnSurface @ 0.38 content (the fill stays: a disabled+selected segment
//     keeps SecondaryContainer)
//   - state layer: the content color blended over the container at hover
//     0.08 / focus 0.10 / pressed 0.12 (over the transparent unselected
//     container the layer is the content color AT that alpha — lerping from
//     transparent black would double-scale the RGB in the src-over blend)
//   - input: a drag past the touch slop (ui/gestures.SLOP, raw coords) is a
//     scroll, not a press; a click selects (sets the signal + on_change);
//     left/right (up/down) arrows move the selection, skipping disabled
//     segments and wrapping (RTL flips left/right)
//
//   - the check icon is upstream's AnimatedVisibility: fade + scale-in
//     from the bottom-left (FastSpatial spring) on select, instant exit
//     while the label offset springs back to center
//
// v1 deviations (documented):
//   - Multi-choice (`segmentedButtonMulti`) is a u64 bitmask — selectable
//     segments cap at 64; a click/space toggles, arrows move the cursor.
//   - A squeezed segment wraps its label through the paragraph ABI
//     (IntrinsicSize.Min parity — the row grows past ContainerHeight by
//     the 8dp vertical ButtonVerticalPadding); the label's wrap budget
//     excludes the reserved icon slot + gap.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const i18n_mod = @import("../ui/i18n.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const icon_w = @import("icon.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

/// A segment (the factory copies the label).
pub const SegmentedItem = struct {
    label: []const u8,
    icon: ?icon_w.IconName = null,
    enabled: bool = true,
};

pub const SegmentedButtonOptions = struct {
    /// The fixed selection when no signal is given (with one, the signal is
    /// the source of truth and this is only the fallback).
    selected: usize = 0,
    /// Multi-choice fallback bitmask (segmentedButtonMulti): bit i = item i.
    selected_mask: u64 = 0,
    theme: Theme = theme_mod.light,
};

/// M3E tokens (OutlinedSegmentedButtonTokens + SegmentedButtonDefaults).
const seg_height: f32 = 40; // ContainerHeight
// The a11y touch-target floor is theme.platform.hit_target_min (48 mobile /
// 24 desktop) — read from s.opts.theme where used.
const seg_min_w: f32 = 58; // ButtonDefaults.MinWidth
const seg_h_pad: f32 = 12; // ContentPadding (start/end)
const icon_size: f32 = 18; // IconSize
const icon_gap: f32 = 8; // IconSpacing (private val in SegmentedButton.kt)
const border_w: f32 = 1; // OutlineWidth (also the row overlap)

/// The check-icon AnimatedVisibility state (upstream: fadeIn +
/// scaleIn(0, origin bottom-left) on enter, instant exit — while the
/// label offset springs -(IconSize+Spacing)/2 → 0). `a` carries the
/// transition for the label offset on BOTH directions; `shown` is the
/// target visibility (the icon paints only while `shown`, at alpha/scale
/// `a`; on exit `shown` flips instantly and `a` decays so the label
/// slides back). `chan` is the stable timeline channel (items.items
/// never re-allocs after init — same guarantee the a11y children rely
/// on).
const CheckAnim = struct {
    n: *Node,
    a: f32 = 0,
    shown: bool = false,
    chan: u8 = 0,
};

const ItemDef = struct {
    label: [:0]const u8, // owned
    icon: ?icon_w.IconName,
    enabled: bool,
    anim: CheckAnim,
    /// Cached wrapped-label layout for a squeezed segment (built through
    /// the paragraph ABI — HarfBuzz shaping + ICU line breaking). Keyed
    /// on the laid-out width and the baked span color; null when the
    /// label fits single-line at the last probe.
    wrap: ?*ui.paint.TextLayout = null,
    wrap_w: f32 = -1,
    wrap_fg: u32 = 0,
};

const SegState = struct {
    items: std.array_list.Managed(ItemDef), // owned defs
    /// Live per-segment a11y descriptors — the semantics tree's virtual
    /// children borrow this slice; segSelect updates `checked` in place.
    sem_children: std.array_list.Managed(ui.semantics.Semantics),
    opts: SegmentedButtonOptions,
    sig: ?*ui.state.Signal(usize) = null,
    on_change: ?Callback = null,
    selected: usize = 0,
    /// MultiChoiceSegmentedButtonRow mode: each segment is a toggle, the
    /// selection is a u64 bitmask (bit i = segment i — caps the row at 64
    /// selectable items). The arrows move `cursor` without toggling;
    /// space/enter/click toggles (upstream: segments keep their own
    /// checked state, the row is not a radio group).
    multi: bool = false,
    mask: u64 = 0,
    cursor: usize = 0,
    multi_sig: ?*ui.state.Signal(u64) = null,
    pressed: i32 = -1,
    hovered: i32 = -1,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — gestures.SLOP).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
    i18n: ?*i18n_mod.I18n = null,
};

fn stateOf(n: *Node) *SegState {
    return @ptrCast(@alignCast(n.state.?));
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

/// The segment width: upstream distributes the Row's intrinsic width
/// evenly across weight(1f) children — each segment's slot is the MEAN
/// of the contents (icon slot + gap + label + paddings), floored at the
/// 58dp min width. Upstream's SegmentedButtonContentMeasurePolicy
/// reserves `max(IconSize, iconWidth) + IconSpacing` for EVERY segment —
/// the check-icon slot exists even when the icon content is empty (the
/// -13dp offset then re-centers the label, which is what an icon-less
/// label's centered paint below reproduces).
fn segWidth(s: *SegState, t: Theme) f32 {
    const count = s.items.items.len;
    if (count == 0) return seg_min_w;
    const ls = t.type_scale.label_large;
    const bold = ls.weight >= 500;
    var sum: f32 = 0;
    for (s.items.items) |def| {
        sum += seg_h_pad * 2 + icon_size + icon_gap + ui.paint.measureText(def.label, ls.size, bold).width;
    }
    return @max(seg_min_w, sum / @as(f32, @floatFromInt(count)));
}

/// The label's width budget inside a segment of width `w` — the reserved
/// icon slot + gap and the 12dp side pads never yield to text.
fn labelBudget(w: f32) f32 {
    return @max(w - seg_h_pad * 2 - icon_size - icon_gap, 1);
}

/// The wrapped label layout for a squeezed segment — the paragraph ABI
/// (ShaperLayout wrap + ICU line breaking), cached on the item keyed by
/// (width, ink). `fg = null` is a metrics probe: reuse whatever layout is
/// cached at that width without rebuilding for color.
fn wrappedLabel(def: *ItemDef, ls: anytype, avail_w: f32, fg: ?Color) ?*ui.paint.TextLayout {
    if (def.wrap == null or def.wrap_w != avail_w or (fg != null and def.wrap_fg != fg.?)) {
        if (def.wrap) |l| ui.paint.textLayoutDestroy(l);
        const l = ui.paint.textLayoutBegin(avail_w) orelse {
            def.wrap = null;
            return null;
        };
        const ink = fg orelse @as(u32, 0xFF000000); // probe: any ink shapes the same
        ui.paint.textLayoutSpan(l, def.label, ui.paint.textStyle(ls.size, @intCast(ls.weight), 0, ls.letter_spacing, ink));
        def.wrap = l;
        def.wrap_w = avail_w;
        def.wrap_fg = ink;
    }
    return def.wrap;
}

/// The segment's rect in LTR space (the segments overlap by the border
/// width). The caller mirrors it for RTL.
fn segRectLtr(b: Rect, i: usize, w: f32) Rect {
    return .{ .x = b.x + @as(f32, @floatFromInt(i)) * (w - border_w), .y = b.y, .w = w, .h = b.h };
}

fn mirrorX(b: Rect, r: Rect) Rect {
    return .{ .x = b.x + b.w - (r.x - b.x) - r.w, .y = r.y, .w = r.w, .h = r.h };
}

/// Segment `index`'s rect in NODE-LOCAL space (Semantics.child_bounds —
/// the a11y bridge maps it to window space for per-item highlights and
/// targeted activation taps).
fn segChildBounds(n: *Node, index: usize) Rect {
    const s = stateOf(n);
    const local = Rect{ .x = 0, .y = 0, .w = n.bounds.w, .h = n.bounds.h };
    const w = segWidthFit(s, s.opts.theme, local);
    var r = segRectLtr(local, index, w);
    if (ui.i18n.direction() == .rtl) r = mirrorX(local, r);
    return r;
}

/// The segment width FIT to the assigned bounds: the intrinsic width when
/// the node is wide enough, otherwise the segments shrink so the row fills
/// exactly the assigned width (a constrained parent never gets paint
/// outside the node, and hit-testing matches the paint).
fn segWidthFit(s: *SegState, t: Theme, b: Rect) f32 {
    const count = s.items.items.len;
    if (count == 0) return 0;
    const w = segWidth(s, t);
    const total = @as(f32, @floatFromInt(count)) * w - @as(f32, @floatFromInt(count - 1)) * border_w;
    if (total <= b.w) return w;
    return @max((b.w + @as(f32, @floatFromInt(count - 1)) * border_w) / @as(f32, @floatFromInt(count)), 0);
}

/// A segment's rect + per-corner radii (itemShape on CornerFull, mirrored in
/// RTL): first = start half, last = end half, middle = square, single = full.
const SegShape = struct { sr: Rect, tl: f32, tr: f32, br: f32, bl: f32 };

fn segShape(b: Rect, i: usize, count: usize, w: f32) SegShape {
    const rtl = ui.i18n.direction() == .rtl;
    var sr = segRectLtr(b, i, w);
    if (rtl) sr = mirrorX(b, sr);
    const half = b.h / 2;
    var tl: f32 = 0;
    var tr: f32 = 0;
    var br: f32 = 0;
    var bl: f32 = 0;
    if (count == 1) {
        tl = half;
        tr = half;
        br = half;
        bl = half;
    } else if (i == 0) {
        tl = half;
        bl = half;
    } else if (i == count - 1) {
        tr = half;
        br = half;
    }
    if (rtl) { // the start side flips to the right
        const t2 = tl;
        tl = tr;
        tr = t2;
        const b2 = bl;
        bl = br;
        br = b2;
    }
    return .{ .sr = sr, .tl = tl, .tr = tr, .br = br, .bl = bl };
}

/// The segment under the point (-1 = none), in the widget's parent space.
fn segAt(s: *SegState, t: Theme, b: Rect, x: f32, y: f32) i32 {
    const count = s.items.items.len;
    if (count == 0) return -1;
    if (y < b.y or y >= b.y + b.h) return -1;
    const w = segWidthFit(s, t, b);
    for (0..count) |i| {
        const sr = segShape(b, i, count, w).sr;
        if (x >= sr.x and x < sr.x + sr.w) return @intCast(i);
    }
    return -1;
}

/// Is segment `i` selected (radio `selected` vs the multi bitmask)?
fn isSel(s: *const SegState, i: usize) bool {
    if (s.multi) return i < 64 and (s.mask >> @intCast(i)) & 1 == 1;
    return i == s.selected;
}

/// Select a segment: the state + the signal (if any) + the a11y value, then
/// on_change. Radio-group semantics: the selection follows.
fn segSelect(n: *Node, index: usize) void {
    const s = stateOf(n);
    if (index >= s.items.items.len) return;
    if (!s.items.items[index].enabled) return;
    s.selected = index;
    retargetAllChecks(s); // the old check exits, the new one scales in
    if (s.sig) |sig| sig.set(index); // the sync callback re-reads (idempotent)
    n.markDirty();
    if (n.semantics) |sem| {
        sem.value = s.items.items[index].label; // a11y: the value follows
        for (s.sem_children.items, 0..) |*c, i| c.checked = (i == index);
        ui.semantics.notifyControlChanged(n);
    }
    if (s.on_change) |cb| cb.fn_ptr(cb.userdata);
}

/// Multi-choice: flip segment `index`'s bit (the mask is the source of
/// truth — the signal re-syncs idempotently), update the a11y children,
/// then on_change.
fn segToggle(n: *Node, index: usize) void {
    const s = stateOf(n);
    if (index >= s.items.items.len or index >= 64) return;
    if (!s.items.items[index].enabled) return;
    s.mask ^= @as(u64, 1) << @intCast(index);
    retargetCheck(s, index);
    if (s.multi_sig) |sig| sig.set(s.mask);
    s.cursor = index;
    n.markDirty();
    if (n.semantics != null) {
        for (s.sem_children.items, 0..) |*c, i| c.checked = isSel(s, i);
        ui.semantics.notifyControlChanged(n);
    }
    if (s.on_change) |cb| cb.fn_ptr(cb.userdata);
}

/// The signal -> widget sync (the app moved the selection externally).
fn segSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const v = s.sig.?.peek();
    if (v < s.items.items.len and v != s.selected) {
        s.selected = v;
        retargetAllChecks(s);
        if (n.semantics) |sem| {
            sem.value = s.items.items[v].label;
            for (s.sem_children.items, 0..) |*c, i| c.checked = (i == v);
            ui.semantics.notifyControlChanged(n); // a11y follows external changes
        }
        n.markDirty();
    }
}

/// The multi mask sync (the app moved the selection externally).
fn segMultiSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const v = s.multi_sig.?.peek();
    if (v != s.mask) {
        s.mask = v;
        retargetAllChecks(s);
        if (n.semantics != null) {
            for (s.sem_children.items, 0..) |*c, i| c.checked = isSel(s, i);
            ui.semantics.notifyControlChanged(n);
        }
        n.markDirty();
    }
}

fn checkCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const anim: *CheckAnim = @ptrCast(@alignCast(userdata.?));
    anim.a = v[0];
    anim.n.markDirty();
}

/// Retarget segment `i`'s check transition after its selection flipped:
/// the spatial spring carries `a` to the target; the paint reads `shown`
/// for the icon's visibility and `a` for the label offset — an exit is
/// instant for the icon while the label slides back (upstream's
/// ExitTransition.None). A custom `icon` replaces the whole slot, no
/// check anim. No timeline → snap.
fn retargetCheck(s: *SegState, i: usize) void {
    const def = &s.items.items[i];
    if (def.icon != null) return;
    const anim = &def.anim;
    const show = isSel(s, i);
    if (anim.shown == show and anim.a == @as(f32, @floatFromInt(@intFromBool(show)))) return;
    anim.shown = show;
    if (ui.anim.timeline()) |tl| {
        const target: f32 = if (show) 1 else 0;
        const from: ui.anim.Vec4 = .{ anim.a, 0, 0, 0 };
        _ = tl.play(.{
            .kind = ui.anim.Animation.springAnim(from, .{ target, 0, 0, 0 }, s.opts.theme.motion.springs.spatial_spring, tl.channelVelocity(@ptrCast(&anim.chan))),
            .from = from,
            .channel = @ptrCast(&anim.chan),
            .on_update = .{ .fn_ptr = checkCb, .userdata = anim },
        });
    } else {
        anim.a = @floatFromInt(@intFromBool(show));
        anim.n.markDirty();
    }
}

/// Refresh every segment's check target (selection changed wholesale —
/// the sync callbacks and the factories).
fn retargetAllChecks(s: *SegState) void {
    for (0..s.items.items.len) |i| retargetCheck(s, i);
}

/// Settle the check state without animation (construction — upstream's
/// initialOffset likewise skips the first-measure animation).
fn snapChecks(s: *SegState) void {
    for (s.items.items, 0..) |*def, i| {
        def.anim.shown = def.icon == null and isSel(s, i);
        def.anim.a = @floatFromInt(@intFromBool(def.anim.shown));
    }
}

/// The last selected index (pub accessor — single-choice rows).
pub fn selectedIndex(n: *Node) usize {
    return stateOf(n).selected;
}

/// The current selection bitmask (pub accessor — multi-choice rows).
pub fn selectedMask(n: *Node) u64 {
    return stateOf(n).mask;
}

fn segMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const count = s.items.items.len;
    if (count == 0) return c.constrain(.{});
    const t = s.opts.theme;
    const w = segWidth(s, t);
    const total_w = @as(f32, @floatFromInt(count)) * w - @as(f32, @floatFromInt(count - 1)) * border_w;
    var h = seg_height;
    // A squeezed row wraps labels (upstream: the Row's IntrinsicSize.Min
    // makes the label's measured height grow the segment past
    // ContainerHeight; vertical content padding = ButtonVerticalPadding
    // 8dp). Probe each label at its share of the offered width.
    if (total_w > c.max_w) {
        const per_w = @max((c.max_w + @as(f32, @floatFromInt(count - 1)) * border_w) / @as(f32, @floatFromInt(count)), 0);
        const avail = labelBudget(per_w);
        const ls = t.type_scale.label_large;
        const bold = ls.weight >= 500;
        for (s.items.items) |*def| {
            const iw = ui.paint.measureText(def.label, ls.size, bold).width;
            if (iw > avail) {
                if (wrappedLabel(def, ls, avail, null)) |l| {
                    h = @max(h, ui.paint.textLayoutHeight(l) + 16);
                }
            }
        }
    }
    return c.constrain(.{ .w = total_w, .h = h });
}

fn segLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: the segments are computed from the bounds at paint/hit
}

/// Paint an icon centered in a size x size box — vector geometry (icon.zig),
/// not a font glyph (emoji-capable codepoints bypass the theme ink).
fn paintIcon(ctx: *kx.Ctx, name: icon_w.IconName, x: f32, y: f32, size: f32, color: Color) void {
    if (color & 0xFF == 0) return;
    icon_w.drawIcon(ctx, name, x, y, size / 24.0, color);
}

/// One segment's fill + state layer + content + border. The fill, state
/// layer and content are clipped to the segment (a shrunken segment never
/// bleeds into its neighbours); the border paints after the reset
/// (unclipped per segment — like the M3E button's outline, a stroke is
/// centered on the edge).
fn segPaintOne(n: *Node, s: *SegState, ctx: *kx.Ctx, i: usize, w: f32, focused: bool) void {
    const t = s.opts.theme;
    const b = n.bounds;
    const cs = t.colors;
    const count = s.items.items.len;
    const def = &s.items.items[i]; // the wrap cache mutates through this
    const idx: i32 = @intCast(i);
    const sh = segShape(b, i, count, w);
    const sr = sh.sr;
    const selected = isSel(s, i);
    const ls = t.type_scale.label_large;
    const bold = ls.weight >= 500;
    ui.paint.clipRect(ctx, sr.x, sr.y, sr.w, sr.h); // saves
    // container (a disabled+selected segment keeps the fill)
    if (selected) {
        ui.paint.fillRRectCorners(ctx, sr.x, sr.y, sr.w, sr.h, sh.tl, sh.tr, sh.br, sh.bl, cs.secondary_container);
    }
    // state layer (enabled only): the content color over the container.
    // Upstream the focused segment carries the layer — the Klaxon row is
    // one focused control whose virtual focus is the selected segment.
    if (def.enabled) {
        // The virtual focus: single = the selected segment, multi = the
        // keyboard cursor (the next toggled segment).
        const focused_here = focused and (if (s.multi) i == s.cursor else selected);
        const alpha: f32 = if (s.pressed == idx)
            t.state.pressed
        else if (focused_here)
            t.state.focus
        else if (s.hovered == idx)
            t.state.hover
        else
            0;
        if (alpha > 0) {
            const on = if (selected) cs.on_secondary_container else cs.on_surface;
            const layer = if (selected)
                theme_mod.stateLayer(cs.secondary_container, on, alpha)
            else
                ui.paint.withAlphaScaled(on, alpha); // transparent container
            ui.paint.fillRRectCorners(ctx, sr.x, sr.y, sr.w, sr.h, sh.tl, sh.tr, sh.br, sh.bl, layer);
        }
    }
    // content: [icon, gap, label] centered (the always-reserved icon slot
    // means an icon-less label centers in the segment — see segWidth)
    const fg: Color = if (!def.enabled)
        ui.paint.withAlphaScaled(cs.on_surface, 0.38)
    else if (selected)
        cs.on_secondary_container
    else
        cs.on_surface;
    const lm = ui.paint.measureText(def.label, ls.size, bold);
    // Upstream content box: the icon slot is ALWAYS reserved (IconSize +
    // IconSpacing) and the label's offset animates
    // -(IconSize+Spacing)/2 → 0 as the check enters (the measure
    // policy's animatable). A custom `icon` fills the slot in both
    // states (upstream: the icon lambda is the whole slot — a checked
    // icon does NOT yield to the check); with no icon the default
    // SegmentedButtonDefaults.Icon paints the check when selected.
    // A label wider than its budget wraps (IntrinsicSize.Min grows the
    // segment — segMeasure reports the wrapped height).
    const wrap = if (lm.width > labelBudget(sr.w)) wrappedLabel(def, ls, labelBudget(sr.w), fg) else null;
    const label_w = if (wrap) |l| ui.paint.textLayoutWidth(l) else lm.width;
    const label_h = if (wrap) |l| ui.paint.textLayoutHeight(l) else lm.height;
    const cw = icon_size + icon_gap + label_w;
    const cx = sr.x + (sr.w - cw) / 2;
    const baseline = sr.y + (sr.h - label_h) / 2 + if (wrap) |l| ui.paint.textLayoutBaseline(l) else lm.ascent;
    const icon_y = sr.y + (sr.h - icon_size) / 2;
    if (def.icon) |iname| {
        paintIcon(ctx, iname, cx, icon_y, icon_size, fg);
    } else if (def.anim.shown) {
        // The check enters fading + scaling from its bottom-left corner
        // (scaleIn transformOrigin (0,1)); the exit is instant — `shown`
        // is already false while `a` decays for the label offset.
        const isz = icon_size * def.anim.a;
        paintIcon(ctx, .check, cx, icon_y + icon_size - isz, isz, ui.paint.withAlphaScaled(fg, def.anim.a));
    }
    const label_off: f32 = if (def.icon != null)
        0
    else
        std.math.lerp(-(icon_size + icon_gap) / 2, 0, def.anim.a);
    if (wrap) |l|
        ui.paint.textLayoutPaint(ctx, l, cx + icon_size + icon_gap + label_off, baseline)
    else
        ui.paint.text(ctx, def.label, cx + icon_size + icon_gap + label_off, baseline, ls.size, bold, fg);
    ui.paint.clipReset(ctx); // restores
    // border — upstream disabled*BorderColor = OutlineColor @ 0.12 (the
    // DisabledOutlineColor OnSurface token is not the one the colors use)
    const oc: Color = if (def.enabled) cs.outline else ui.paint.withAlphaScaled(cs.outline, 0.12);
    ui.paint.strokeRRectCorners(ctx, sr.x, sr.y, sr.w, sr.h, sh.tl, sh.tr, sh.br, sh.bl, border_w, oc);
}

fn segPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const count: usize = s.items.items.len;
    if (count == 0) return;
    const w = segWidthFit(s, t, b);
    const focused = input.isFocused(n);
    // Upstream z-order (zIndex = interactionCount + checked*5): checked
    // segments paint ABOVE their neighbours in the 1dp overlap, and an
    // interacting (pressed) unchecked segment above quiet ones — the
    // higher-z segment claims the shared border.
    for (0..count) |i| {
        if (!isSel(s, i) and s.pressed != @as(i32, @intCast(i))) segPaintOne(n, s, ctx, i, w, focused);
    }
    for (0..count) |i| {
        if (!isSel(s, i) and s.pressed == @as(i32, @intCast(i))) segPaintOne(n, s, ctx, i, w, focused);
    }
    for (0..count) |i| {
        if (isSel(s, i)) segPaintOne(n, s, ctx, i, w, focused);
    }
}

fn segOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    const idx = segAt(s, s.opts.theme, n.bounds, ev.x, ev.y);
    switch (ev.phase) {
        .down => {
            if (idx < 0 or !s.items.items[@intCast(idx)].enabled) return false;
            s.pressed = idx;
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            n.markDirty();
            return true;
        },
        .up => {
            const was = s.pressed;
            s.pressed = -1;
            n.markDirty();
            if (was >= 0 and idx == was) {
                if (s.multi) segToggle(n, @intCast(was)) else segSelect(n, @intCast(was));
            }
            return true;
        },
        .move => {
            // A drag beyond the touch slop is a scroll, not a press: cancel
            // the pressed state. The move is NOT claimed (return false) so
            // it keeps bubbling to scrollable ancestors.
            if (s.pressed >= 0) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.pressed = -1;
                    n.markDirty();
                }
            }
            return false;
        },
        // the pointer went down outside while we held the capture: cancel
        .outside_down => {
            s.pressed = -1;
            n.markDirty();
            return true;
        },
        .enter => {
            s.hovered = idx;
            n.markDirty();
            return true;
        },
        // moving across segments within the leaf emits hover_move (not
        // enter/leave): re-resolve the segment under the pointer
        .hover_move => {
            const h = segAt(s, s.opts.theme, n.bounds, ev.x, ev.y);
            if (h != s.hovered) {
                s.hovered = h;
                n.markDirty();
            }
            return true;
        },
        .leave => {
            s.hovered = -1;
            n.markDirty();
            return true;
        },
    }
    return false;
}

/// Keyboard: the row is focusable. Single choice = radio-group semantics —
/// the arrows move AND select. Multi choice = each segment is a toggle —
/// the arrows move the cursor (skipping disabled, wrapping, RTL-flipped)
/// and space/enter toggles the segment under it (upstream: segments are
/// individually focusable toggles).
fn segOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind != .key_down) return false;
    const count: i32 = @intCast(s.items.items.len);
    if (count == 0) return false;
    switch (ev.key) {
        .left, .up, .right, .down => {
            const rtl = ui.i18n.direction() == .rtl;
            const forward: i32 = if (ev.key == .right or ev.key == .down) 1 else -1;
            const step: i32 = if (rtl and (ev.key == .left or ev.key == .right)) -forward else forward;
            var i: i32 = @intCast(@min(if (s.multi) s.cursor else s.selected, s.items.items.len - 1));
            var guard: i32 = 0;
            while (guard < count) : (guard += 1) {
                i = @mod(i + step, count);
                if (s.items.items[@intCast(i)].enabled) break;
            }
            if (s.multi) {
                s.cursor = @intCast(i);
                n.markDirty();
            } else {
                segSelect(n, @intCast(i));
            }
            return true;
        },
        .space, .enter => {
            if (!s.multi) return false;
            if (s.cursor < s.items.items.len) segToggle(n, s.cursor);
            return true;
        },
        else => {},
    }
    return false;
}

fn segDeinit(n: *Node) void {
    const s = stateOf(n);
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = segSyncCb, .userdata = n } });
    if (s.multi_sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = segMultiSyncCb, .userdata = n } });
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = segLocaleCb, .userdata = n });
    input.releaseNode(n);
    for (s.items.items) |*def| {
        if (ui.anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&def.anim.chan)); // the cb points into this item
        if (def.wrap) |l| ui.paint.textLayoutDestroy(l);
        n.allocator.free(def.label);
    }
    s.items.deinit();
    s.sem_children.deinit();
    n.allocator.destroy(s);
}

/// The interactive target: ≥ hit_target_min tall centered on the 40dp
/// container — seg_height was below the a11y touch floor.
fn segHitBounds(n: *Node) Rect {
    const s = stateOf(n);
    const b = n.bounds;
    const h = @max(b.h, s.opts.theme.platform.hit_target_min);
    return .{
        .x = b.x,
        .y = b.y + (b.h - h) / 2,
        .w = b.w,
        .h = h,
    };
}

/// The group label is tr()-resolved — the locale callback re-attaches in
/// the new locale (the segment children are app strings, verbatim).
fn attachSegSemantics(n: *Node, multi: bool) void {
    const s = stateOf(n);
    ui.semantics.attach(n, .{
        .role = .group, // a radio group (single) / toggle group (multi)
        .label = i18n_mod.tr("Segmented button"),
        .focusable = true, // takes the keyboard focus (arrow nav)
        .value = if (!multi and s.items.items.len > 0) s.items.items[s.selected].label else "",
        .children = s.sem_children.items,
        .child_bounds = segChildBounds,
    });
}

fn segLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    attachSegSemantics(n, stateOf(n).multi);
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

const seg_vtable = ui.node.VTable{
    .measure = segMeasure,
    .layout = segLayout,
    .paint = segPaint,
    .deinit = segDeinit,
    .on_pointer = segOnPointer,
    .on_key = segOnKey,
    .hit_bounds = segHitBounds,
};

/// An M3E single-choice segmented button row. The segments are internal
/// chrome painted by the widget (a leaf — no document children). `items`
/// are copied (the labels are owned). `sig` drives the selection
/// (round-trips); `on_change` fires with `selectedIndex(n)` valid after a
/// click or an arrow-key selection.
/// Shared row construction — `multi` selects single-choice (radio) vs
/// multi-choice (toggle bitmask) semantics.
fn segBuild(allocator: std.mem.Allocator, items: []const SegmentedItem, opts: SegmentedButtonOptions, multi: bool) !*Node {
    const node = try Node.create(allocator, &seg_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(SegState);
    errdefer allocator.destroy(s);
    s.* = .{
        .items = std.array_list.Managed(ItemDef).init(allocator),
        .sem_children = std.array_list.Managed(ui.semantics.Semantics).init(allocator),
        .opts = opts,
        .on_change = null,
        .selected = opts.selected,
        .multi = multi,
        .mask = opts.selected_mask,
        .cursor = opts.selected,
    };
    // One ownership boundary: on ANY failure this errdefer frees the
    // appended defs' labels (segDeinit owns them only once returned).
    errdefer {
        for (s.items.items) |*def| allocator.free(def.label);
        s.items.deinit();
    }
    for (items) |item| {
        const label = try dupeZ(allocator, item.label);
        errdefer allocator.free(label); // iteration scope: freed only if THIS iteration fails before the append
        // No catch-free here: on append failure the errdefer frees the copy.
        try s.items.append(.{ .label = label, .icon = item.icon, .enabled = item.enabled, .anim = .{ .n = node } });
    }
    node.state = s;
    if (s.selected >= s.items.items.len) s.selected = 0; // clamp bad data
    snapChecks(s); // the initial check state is settled — no enter anim
    // Per-segment virtual a11y children — VoiceOver reads/selects each
    // segment (radio or checkbox by mode), not just an opaque group. The
    // borrowed slice is stable (items never re-alloc after init);
    // `checked` mutates in place on selection changes.
    for (s.items.items, 0..) |*def, i| {
        s.sem_children.append(.{
            .role = if (multi) .checkbox else .radio,
            .label = def.label,
            .checked = isSel(s, i),
            .disabled = !def.enabled,
            .actions = ui.semantics.Actions.initOne(.activate),
        }) catch @panic("klaxon: out of memory");
    }
    attachSegSemantics(node, multi); // Phase 2c
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = segLocaleCb, .userdata = node });
    return node;
}

/// An M3E single-choice segmented button row. The segments are internal
/// chrome painted by the widget (a leaf — no document children). `items`
/// are copied (the labels are owned). `sig` drives the selection
/// (round-trips); `on_change` fires with `selectedIndex(n)` valid after a
/// click or an arrow-key selection.
pub fn segmentedButton(allocator: std.mem.Allocator, items: []const SegmentedItem, sig: ?*ui.state.Signal(usize), on_change: ?Callback, opts: SegmentedButtonOptions) !*Node {
    const node = try segBuild(allocator, items, opts, false);
    const s = stateOf(node);
    s.sig = sig;
    s.on_change = on_change;
    if (sig) |sg| {
        sg.subscribe(.{ .callback = .{ .fn_ptr = segSyncCb, .userdata = node } });
        const v = sg.peek();
        if (v < s.items.items.len) s.selected = v; // the signal wins
        snapChecks(s);
        if (node.semantics) |sem| {
            // An empty row is legal (registry/JSON paths build one) — the
            // clamped selected==0 is still out of bounds then.
            sem.value = if (s.items.items.len > 0) s.items.items[s.selected].label else "";
            for (s.sem_children.items, 0..) |*c, i| c.checked = (i == s.selected);
        }
    }
    return node;
}

/// An M3E MultiChoiceSegmentedButtonRow: same chrome, but every segment is
/// an independent toggle. The selection is a u64 bitmask (bit i = item i —
/// selectable segments cap at 64); `sig`/`on_change` round-trip it. A
/// click or space/enter on the keyboard cursor toggles; arrows move the
/// cursor only. `selectedMask(n)` reads it back. Checked segments paint
/// the check icon (upstream's default icon slot).
pub fn segmentedButtonMulti(allocator: std.mem.Allocator, items: []const SegmentedItem, sig: ?*ui.state.Signal(u64), on_change: ?Callback, opts: SegmentedButtonOptions) !*Node {
    const node = try segBuild(allocator, items, opts, true);
    const s = stateOf(node);
    s.multi_sig = sig;
    s.on_change = on_change;
    if (sig) |sg| {
        sg.subscribe(.{ .callback = .{ .fn_ptr = segMultiSyncCb, .userdata = node } });
        s.mask = sg.peek(); // the signal wins
        snapChecks(s);
        for (s.sem_children.items, 0..) |*c, i| c.checked = isSel(s, i);
    }
    return node;
}

// --- tests ---

fn changeCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "segmented_button: measures equal-width segments overlapping by the border; 40dp tall" {
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{ .{ .label = "Day" }, .{ .label = "Week" }, .{ .label = "Month" } }, null, null, .{});
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    const t = theme_mod.light;
    const ls = t.type_scale.label_large;
    // every segment reserves the 26dp icon slot (upstream measure policy);
    // weight(1f) shares the row's intrinsic width evenly — the MEAN
    const w = @max(seg_min_w, seg_h_pad * 2 + icon_size + icon_gap + (ui.paint.measureText("Day", ls.size, true).width + ui.paint.measureText("Week", ls.size, true).width + ui.paint.measureText("Month", ls.size, true).width) / 3);
    try std.testing.expectApproxEqAbs(@as(f32, 3) * w - 2 * border_w, sz.w, 0.001);
    try std.testing.expectEqual(seg_height, sz.h);
    // a single segment: full width, no overlap
    const one = try segmentedButton(a, &.{.{ .label = "Only" }}, null, null, .{});
    defer one.deinit();
    const sz1 = one.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(@max(seg_min_w, seg_h_pad * 2 + icon_size + icon_gap + ui.paint.measureText("Only", ls.size, true).width), sz1.w, 0.001);
}

test "segmented_button: click selects (signal + on_change); arrows move AND select; a11y follows" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = changeCounterCb, .userdata = &count };
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sig.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{ .{ .label = "Day" }, .{ .label = "Week", .enabled = false }, .{ .label = "Month" } }, sig, cb, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 300, .h = 40 });
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n));
    try std.testing.expectEqualStrings("Day", n.semantics.?.value);
    // click the 3rd segment (weight(1f): the mean of the contents sets
    // the segment width; the segments overlap by 1dp)
    const t = theme_mod.light;
    const ls = t.type_scale.label_large;
    const w = @max(seg_min_w, (seg_h_pad * 2 + icon_size + icon_gap) + (ui.paint.measureText("Day", ls.size, true).width + ui.paint.measureText("Week", ls.size, true).width + ui.paint.measureText("Month", ls.size, true).width) / 3);
    const x3 = @as(f32, @floatFromInt(2)) * (w - border_w) + 10;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = x3, .y = 20, .raw_x = x3, .raw_y = 20 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = x3, .y = 20, .raw_x = x3, .raw_y = 20 });
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(n));
    try std.testing.expectEqual(@as(usize, 2), sig.peek()); // the signal round-trips
    try std.testing.expectEqual(@as(u32, 1), count); // on_change fired
    try std.testing.expectEqualStrings("Month", n.semantics.?.value); // a11y follows
    // keyboard: the row takes the focus; left wraps AND selects (skipping
    // the disabled middle segment)
    input.requestFocus(n);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .left });
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n)); // wrapped from 2 (1 disabled)
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .right });
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(n)); // 0 -> skips 1 -> 2
    try std.testing.expectEqual(@as(u32, 3), count);
    // the external signal moves the selection too
    sig.set(0);
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n));
    try std.testing.expectEqualStrings("Day", n.semantics.?.value);
}

test "segmented_button: semantics — role group, focusable, value follows the selection" {
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{ .{ .label = "A" }, .{ .label = "B" } }, null, null, .{ .selected = 1 });
    defer n.deinit();
    try std.testing.expectEqual(ui.semantics.Role.group, n.semantics.?.role);
    try std.testing.expect(n.semantics.?.focusable);
    try std.testing.expectEqualStrings("B", n.semantics.?.value);
    try std.testing.expectEqual(@as(usize, 1), selectedIndex(n));
}

test "segmented_button: multi-choice toggles a bitmask — click, cursor+space, signal round-trip" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = changeCounterCb, .userdata = &count };
    const sig = try ui.state.Signal(u64).init(std.testing.allocator, 0b001);
    defer sig.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try segmentedButtonMulti(a, &.{ .{ .label = "Bold" }, .{ .label = "Italic" }, .{ .label = "Underline", .enabled = false } }, sig, cb, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 300, .h = 40 });
    // the signal seeds the mask; a11y children are checkboxes
    try std.testing.expectEqual(@as(u64, 0b001), selectedMask(n));
    try std.testing.expectEqual(ui.semantics.Role.checkbox, n.semantics.?.children[0].role);
    try std.testing.expect(n.semantics.?.children[0].checked.?);
    try std.testing.expect(!n.semantics.?.children[1].checked.?);
    // click segment 1 → toggles its bit ON without clearing segment 0
    const t = theme_mod.light;
    const ls = t.type_scale.label_large;
    const w = @max(seg_min_w, (seg_h_pad * 2 + icon_size + icon_gap) + (ui.paint.measureText("Bold", ls.size, true).width + ui.paint.measureText("Italic", ls.size, true).width + ui.paint.measureText("Underline", ls.size, true).width) / 3);
    const x1 = w - border_w + 10;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = x1, .y = 20, .raw_x = x1, .raw_y = 20 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = x1, .y = 20, .raw_x = x1, .raw_y = 20 });
    try std.testing.expectEqual(@as(u64, 0b011), selectedMask(n));
    try std.testing.expectEqual(@as(u64, 0b011), sig.peek());
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expect(n.semantics.?.children[1].checked.?);
    // clicking a selected segment toggles it OFF
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = x1, .y = 20, .raw_x = x1, .raw_y = 20 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = x1, .y = 20, .raw_x = x1, .raw_y = 20 });
    try std.testing.expectEqual(@as(u64, 0b001), selectedMask(n));
    // keyboard: arrows move the cursor WITHOUT toggling (skips disabled 2,
    // wraps), space toggles
    input.requestFocus(n);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .right }); // cursor 1 → wraps to 0
    try std.testing.expectEqual(@as(u64, 0b001), selectedMask(n)); // moved, no toggle
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .space });
    try std.testing.expectEqual(@as(u64, 0b000), selectedMask(n)); // toggled segment 0 off
    // the external signal moves the mask
    sig.set(0b010);
    try std.testing.expectEqual(@as(u64, 0b010), selectedMask(n));
    try std.testing.expect(!n.semantics.?.children[0].checked.?);
    try std.testing.expect(n.semantics.?.children[1].checked.?);
}

test "golden: the selected segment paints SecondaryContainer; the row's ends are rounded, the middle is square" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{ .{ .label = "Day" }, .{ .label = "Week" }, .{ .label = "Month" } }, null, null, .{ .selected = 1, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 320, 80);
    defer r.deinit();
    // half-pixel y: the 1dp border stroke then covers pixel row 20 exactly
    n.layout(.{ .x = 20, .y = 20.5, .w = 280, .h = 40 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const w = segWidth(stateOf(n), t);
    const mid_lx = 20 + (w - border_w);
    const mid_x = mid_lx + w / 2;
    // the middle (selected) segment: SecondaryContainer above the label ink
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(@intFromFloat(mid_x), 24));
    // the first segment's start corner (radius 20 = h/2): the exact corner
    // stays background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20, 20));
    // the middle segment's corners are square: inside the corner (clear of
    // the strokes) the fill is there
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(@as(i32, @intFromFloat(mid_lx)) + 2, 23));
    // the unselected segments' borders: Outline ink at the row's top edge
    // (the first segment's straight top edge starts at x = 20 + 20)
    try std.testing.expect(f.countColorIn(.{ .x = 40, .y = 20, .w = 20, .h = 1 }, t.colors.outline) > 0);
    // the selected segment's label ink (on_secondary_container) in its row
    try std.testing.expect(f.countColorIn(.{ .x = mid_lx, .y = 30, .w = w, .h = 20 }, t.colors.on_secondary_container) > 0);
}

test "golden: a hovered unselected segment paints the on_surface state layer" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{ .{ .label = "Day" }, .{ .label = "Week" } }, null, null, .{ .selected = 0, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 80);
    defer r.deinit();
    n.layout(.{ .x = 20, .y = 20, .w = 160, .h = 40 });
    // hover the 2nd (unselected) segment — the FIT width: the always-
    // reserved icon slot pushes the intrinsic row past 160, so the
    // segments shrink to fill the assigned bounds
    const w = segWidthFit(stateOf(n), t, n.bounds);
    const x2 = 20 + (w - border_w) + w - 5; // near its end edge, no label ink
    _ = n.vtable.on_pointer.?(n, .{ .phase = .enter, .x = x2, .y = 40 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the state layer: on_surface @ 0.08 AT the alpha (transparent
    // container) blended over the background
    try golden.expectPixelApprox(f, @intFromFloat(x2), 40, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, t.state.hover), 0xFFFFFFFF));
}

test "golden: a disabled segment paints the OnSurface@0.38 label + the @0.12 border" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    // the disabled segment is NOT selected (a transparent container: the ink
    // blends over the background)
    const n = try segmentedButton(a, &.{ .{ .label = "Day", .enabled = false }, .{ .label = "Week" } }, null, null, .{ .selected = 1, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 80);
    defer r.deinit();
    // half-pixel y: the 1dp border stroke then covers pixel row 20 exactly
    n.layout(.{ .x = 20, .y = 20.5, .w = 80, .h = 40 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the label ink: on_surface @ 0.38 over the background
    const dis = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), 0xFFFFFFFF);
    try std.testing.expect(f.countColorIn(.{ .x = 30, .y = 30, .w = 60, .h = 20 }, dis) > 0);
    // the border ink: Outline @ 0.12 over the background (row 20 is the
    // first segment's straight top edge) — upstream disabled*BorderColor
    const boc = golden.blendOver(ui.paint.withAlphaScaled(t.colors.outline, 0.12), 0xFFFFFFFF);
    try golden.expectPixelApprox(f, 50, 20, boc);
}

test "segmented_button: hover_move re-resolves the segment under the pointer" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{ .{ .label = "Day" }, .{ .label = "Week" }, .{ .label = "Month" } }, null, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 200, .h = 40 });
    const w = segWidth(stateOf(n), theme_mod.light);
    // hover the 1st segment, then move across to the 3rd within the leaf
    // (the router emits hover_move, not enter/leave)
    router.dispatchPointer(n, .{ .phase = .move, .x = 10, .y = 20 });
    try std.testing.expectEqual(@as(i32, 0), stateOf(n).hovered);
    router.dispatchPointer(n, .{ .phase = .move, .x = 2 * (w - border_w) + 10, .y = 20 });
    try std.testing.expectEqual(@as(i32, 2), stateOf(n).hovered);
    // moving outside the row clears the highlight (leave)
    router.dispatchPointer(n, .{ .phase = .move, .x = 10, .y = 100 });
    try std.testing.expectEqual(@as(i32, -1), stateOf(n).hovered);
}

test "golden: a constrained width shrinks the segments (no paint outside the node)" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{ .{ .label = "Day" }, .{ .label = "Week" }, .{ .label = "Month" } }, null, null, .{ .selected = 1, .theme = t });
    defer n.deinit();
    // intrinsic ~3*67-2 = 199; assign 120 — the segments shrink to fit
    n.layout(.{ .x = 20, .y = 20, .w = 120, .h = 40 });
    var r = try golden.Renderer.init(std.testing.allocator, 200, 80);
    defer r.deinit();
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the shrunken middle (selected) segment still paints its fill
    const w = segWidthFit(stateOf(n), t, n.bounds);
    const mid_lx = 20 + (w - border_w);
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(@as(i32, @intFromFloat(mid_lx)) + 2, 23));
    // nothing paints beyond the node's right edge (x = 140): the strip
    // 141..150 is pure background
    var x: i32 = 141;
    while (x < 151) : (x += 1) {
        try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(x, 40));
        try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(x, 25));
    }
}

test "segmented_button: RTL mirrors the row (the first segment sits at the end side)" {
    const a = std.testing.allocator;
    const i18n = try ui.i18n.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    const n = try segmentedButton(a, &.{ .{ .label = "A" }, .{ .label = "B" } }, null, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 116, .h = 40 }); // 2 segments of 58 (min width)
    // in RTL the FIRST segment is at the END side: a click at the right end
    // selects index 0
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 100, .y = 20, .raw_x = 100, .raw_y = 20 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 100, .y = 20, .raw_x = 100, .raw_y = 20 });
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n));
}

test "segmented_button: the check scales in on select, exits instantly while the label offset springs back" {
    var tl = ui.anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    ui.anim.setCurrent(&tl);
    defer ui.anim.setCurrent(null);
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{ .{ .label = "A" }, .{ .label = "B" } }, null, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 200, .h = 40 });
    const s = stateOf(n);
    // settled at construction: seg 0 selected → shown at a=1; seg 1 hidden
    try std.testing.expect(s.items.items[0].anim.shown and s.items.items[0].anim.a == 1);
    try std.testing.expect(!s.items.items[1].anim.shown and s.items.items[1].anim.a == 0);
    segSelect(n, 1);
    tl.tick(0); // lazy start
    // upstream: the exit is instant (shown already false) while `a`
    // still carries the label's offset slide; the new check is mid-scale
    try std.testing.expect(!s.items.items[0].anim.shown);
    try std.testing.expect(s.items.items[0].anim.a > 0.5);
    try std.testing.expect(s.items.items[1].anim.shown);
    try std.testing.expect(s.items.items[1].anim.a < 0.5);
    tl.tick(800); // the springs settle
    try std.testing.expectEqual(@as(f32, 0), s.items.items[0].anim.a);
    try std.testing.expectEqual(@as(f32, 1), s.items.items[1].anim.a);
    // re-select mid-flight: the channel retargets, no snap
    segSelect(n, 0);
    tl.tick(1000);
    try std.testing.expect(s.items.items[0].anim.shown);
    try std.testing.expect(s.items.items[0].anim.a < 1); // still rising
}

test "golden: the selected icon-less segment paints the check glyph; the label shifts right" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{ .{ .label = "Day" }, .{ .label = "Week" } }, null, null, .{ .selected = 0, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 260, 80);
    defer r.deinit();
    n.layout(.{ .x = 20, .y = 20, .w = 220, .h = 40 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const w = segWidthFit(stateOf(n), t, n.bounds);
    // the check sits at the content box's leading edge: the label ("Day")
    // is centered in the box, so the icon zone is the slot's left band.
    // Icon ink = on_secondary_container over the secondary_container fill
    // (AA'd — probe approximately).
    const icon_x = 20 + (w - (icon_size + icon_gap + ui.paint.measureText("Day", t.type_scale.label_large.size, true).width)) / 2;
    try std.testing.expect(f.countColorApproxIn(.{ .x = icon_x, .y = 30, .w = icon_size, .h = icon_size }, t.colors.on_secondary_container) > 0);
    // the unselected segment has NO check: its leading icon zone is clear
    // of glyph ink (the "Week" label is inset by the reserved slot)
    const week_w = ui.paint.measureText("Week", t.type_scale.label_large.size, true).width;
    const cx1 = 20 + (w - border_w) + (w - (icon_size + icon_gap + week_w)) / 2;
    try std.testing.expectEqual(@as(u32, 0), f.countColorApproxIn(.{ .x = cx1 + 2, .y = 32, .w = 8, .h = 16 }, t.colors.on_surface));
}

test "segmented_button: i18n — the framework label localizes + re-resolves on a locale switch" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Segmented button\": \"Botón segmentado\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const n = try segmentedButton(a, &.{ .{ .label = "Day" }, .{ .label = "Week" } }, null, null, .{});
    defer n.deinit();
    try std.testing.expectEqualStrings("Botón segmentado", n.semantics.?.label);
    try i18n.setLocale("en");
    const sem = n.semantics.?;
    try std.testing.expectEqualStrings("Segmented button", sem.label);
    // the segment children survive (app labels, verbatim)
    try std.testing.expectEqual(@as(usize, 2), sem.children.len);
    try std.testing.expectEqualStrings("Day", sem.children[0].label);
}

test "segmented_button: a squeezed segment wraps its label and the row grows" {
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{
        .{ .label = "A" },
        .{ .label = "A very long segment label that wraps" },
        .{ .label = "C" },
    }, null, null, .{});
    defer n.deinit();
    const s = stateOf(n);
    // Unconstrained: single-line labels at the 40dp container height.
    const wide = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(seg_height, wide.h);
    try std.testing.expect(s.items.items[1].wrap == null); // no wrap cached yet
    // Squeeze to 300px → ~101px segments → the middle label wraps over
    // multiple lines (IntrinsicSize.Min grows the row past 40dp).
    const tight = n.measure(.{ .max_w = 300, .max_h = 2000 });
    try std.testing.expect(tight.h > seg_height);
    try std.testing.expect(s.items.items[1].wrap != null); // paragraph cached
    try std.testing.expect(s.items.items[0].wrap == null); // "A" still fits
    // The wrapped layout is narrower than the single-line intrinsic.
    const ls = theme_mod.light.type_scale.label_large;
    const iw = ui.paint.measureText(s.items.items[1].label, ls.size, true).width;
    try std.testing.expect(ui.paint.textLayoutWidth(s.items.items[1].wrap.?) < iw);
}
