// TextField — the Material 3 Expressive text field: filled and outlined
// variants, single-line, with a floating label, optional leading/trailing
// icons, placeholder, supporting text, error + disabled states, and real
// text entry (the input.zig machinery: a null-terminated buffer,
// text_input/backspace/enter/escape, a caret at the text end).
//
// Ported from the vendored Compose sources:
//   .ref/material3/TextField.kt          (state-based TextField)
//   .ref/material3/OutlinedTextField.kt  (state-based OutlinedTextField,
//                                       outlineCutout)
//   TextFieldImpl.kt / TextFieldDefaults.kt (androidx-main; not vendored —
//     CommonDecorationBox, InsideTextFieldLayout, CutoutTextFieldLayout,
//     TextFieldMeasurePolicy/OutlinedTextFieldMeasurePolicy,
//     placeWithLabel/placeWithoutLabel, labelProgress/placeholderOpacity,
//     textFieldHorizontalIconPadding, minimizedLabelHalfHeight,
//     contentPadding{With,Without}Label, supportingTextPadding, MinHeight/
//     MinWidth, indicator/border thicknesses, defaultTextFieldColors)
//   .ref/material3/tokens/FilledTextFieldTokens.kt
//   .ref/material3/tokens/OutlinedTextFieldTokens.kt
//
// Ported behavior:
//   - container 56 tall; the outlined field reserves an extra 8dp on top for
//     the cutout label when a label is present (topPaddingForLabelCutout =
//     minimizedLabelHalfHeight = bodySmall line/2): widget = 64 + supporting
//   - icons live in 48x48 minimumInteractiveComponentSize boxes centered in
//     the container — the 24dp glyph sits 12dp inset; the text/label offset
//     is 52 with an icon (48 + TextFieldPadding - horizontalIconPadding) and
//     16 without
//   - the label animates: labelProgress (InputPhase transition, FastSpatial
//     spring — theme.motion.springs.spatial_spring) lerps position, box
//     height (24→16) and font size (bodyLarge→bodySmall); focused-or-has-
//     text minimizes. Filled: x is fixed at the text offset, y lerps
//     centered→8 (contentPaddingWithLabel top). Outlined: x lerps
//     offset→16 and y lerps centered→straddling the container's top edge;
//     the border is cut behind it by the outlineCutout patch (label width
//     scaled by progress + 2*4dp OutlinedTextFieldInnerPadding)
//   - text: filled+label sits under the floated label (8 + the label box
//     height, single-line); otherwise vertically centered; the glyph block
//     is centered in its 24dp line box (heightIn + wrapContentHeight)
//   - supporting text: below the container, x = 16, 4dp top pad, bodySmall
//     in a 16dp min box (MinSupportingTextLineHeight)
//   - shapes: filled = 4dp top corners (CornerExtraSmallTop), outlined = 4dp
//     all corners (CornerExtraSmall); filled active indicator 1dp/2dp
//     focused (UnfocusedIndicatorThickness/FocusedIndicatorThickness);
//     outlined stroke 1dp/2dp focused (UnfocusedBorder/FocusedBorder)
//   - colors per the state-based defaultTextFieldColors (enabled/error/
//     focused axes only — the Hover* token rows are not consumed by
//     TextFieldColors): filled container SurfaceContainerHighest in ALL
//     enabled states AND disabled (the DisabledContainerOpacity 0.04 token
//     is only used by the deprecated colors() overload); indicator
//     OnSurfaceVariant/Primary/Error, disabled OnSurface@0.38; outline
//     Outline/OnSurface(hover unused)/Primary/Error, disabled OnSurface@
//     0.12; label Primary focused/Error/OnSurfaceVariant; icons
//     OnSurfaceVariant (trailing Error); supporting OnSurfaceVariant/Error;
//     disabled content OnSurface@0.38; caret Primary/Error
//
// The widget is a LEAF: the label, placeholder, input text, caret, icons and
// supporting text are all painted by the widget itself (their colors and
// positions change with focus — children would need a recolor on every focus
// change; paint-time computation needs none).
//
// Remaining deviations:
//   - Single-line only (no MultiLine lineLimits, no prefix/suffix/counter).
//   - The outlined cutout is a surface-colored patch over the stroke —
//     upstream clips the border draw with ClipOp.Difference, which the
//     paint API doesn't expose; the patch assumes a surface-toned
//     background.
//   - The label's font size lerps but its weight/tracking don't (upstream
//     lerps the full TextStyle); label/indicator colors snap on the phase
//     transition rather than animating FastEffects; the placeholder alpha
//     snaps instead of the fast/slow effects fade.
//   - The caret is static (no blink), 1dp wide, always at the text end (no
//     selection, no click-to-position); text scrolls by clip only.
//   - RTL mirrors the chrome; the text run itself stays LTR (no bidi —
//     same as text.zig). No TextSelectionColors (no selection).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
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

pub const TextFieldVariant = enum { filled, outlined };

pub const TextFieldOptions = struct {
    variant: TextFieldVariant = .outlined,
    enabled: bool = true,
    @"error": bool = false,
    label: []const u8 = "",
    placeholder: []const u8 = "",
    /// The initial text (used when no live signal is given).
    initial: []const u8 = "",
    leading_icon: ?icon_w.IconName = null,
    trailing_icon: ?icon_w.IconName = null,
    supporting: []const u8 = "",
    theme: Theme = theme_mod.light,
};

// --- M3E tokens (TextFieldImpl.kt paddings + the *TextFieldTokens) ---
const container_h: f32 = 56; // OutlinedTextFieldTokens.ContainerHeight / MinHeight
const h_padding: f32 = 16; // TextFieldPadding
const top_pad_label: f32 = 8; // TextFieldWithLabelVerticalPadding
const icon_box: f32 = 48; // minimumInteractiveComponentSize
const icon_size: f32 = 24; // LeadingIconSize/TrailingIconSize
const icon_pad: f32 = (icon_box - icon_size) / 2; // textFieldHorizontalIconPadding = 12
const corner: f32 = 4; // CornerExtraSmall (top corners for the filled)
const outline_w: f32 = 1; // UnfocusedIndicator/BorderThickness
const outline_w_focus: f32 = 2; // FocusedIndicator/BorderThickness
const caret_w: f32 = 1;
const cutout_pad: f32 = 4; // OutlinedTextFieldInnerPadding
const supporting_top: f32 = 4; // SupportingTopPadding
const min_w: f32 = 280; // TextFieldDefaults.MinWidth / OutlinedTextFieldDefaults.MinWidth
const min_text_line_h: f32 = 24; // MinTextLineHeight
const min_label_line_h: f32 = 16; // MinFocusedLabelLineHeight
const min_supporting_line_h: f32 = 16; // MinSupportingTextLineHeight

const TextFieldState = struct {
    buf: std.array_list.Managed(u8), // kept null-terminated: items[len] == 0
    label: [:0]const u8, // owned
    placeholder: [:0]const u8, // owned
    supporting: [:0]const u8, // owned
    opts: TextFieldOptions,
    /// Live text channel (registry/designer): the widget sets it on edit; an
    /// external set replaces the buffer (two-way). Growable + owned by the
    /// signal — never truncates, never dangles after the widget is gone.
    sig: ?*ui.state.TextSignal = null,
    on_changed: ?Callback = null,
    on_submitted: ?Callback = null,
    /// The InputPhase transition's labelProgress channel: 0 = expanded,
    /// 1 = minimized (focused or has text). Springs with FastSpatial; a
    /// missing timeline snaps. The phase cache detects transitions in paint
    /// (covers focus changes routed without a widget callback).
    label_progress: f32 = 1,
    phase: InputPhase = .unfocused_not_empty,
    label_channel: u8 = 0,
    /// Incremental measure rope: each committed piece is measured ONCE
    /// (its text lands in the text cache by content, so later frames hash
    /// only this segment's bytes) — a growing IME buffer used to re-shape
    /// the whole string on every frame (measured ~290µs/frame at ~1500
    /// CJK chars). `segs` covers buf[0..segs_len] in order; a tail outside
    /// that prefix — appended mid-frame or unsafe to split — measures
    /// whole and merges into the last segment.
    segs: std.array_list.Managed(Seg) = undefined,

    const Seg = struct {
        text: [:0]u8, // owned
        size: f32, // the measure font size (theme moves invalidate)
        m: ui.paint.TextMetrics,
    };

    fn text(s: *TextFieldState) [:0]const u8 {
        // Sentinel slice via the many-item pointer (see input.zig).
        return s.buf.items.ptr[0..s.buf.items.len :0];
    }
};

fn stateOf(n: *Node) *TextFieldState {
    return @ptrCast(@alignCast(n.state.?));
}

/// Write the null sentinel at items[len] (the P0 TextField helper).
/// Grows if the buffer is exactly full — the sync/setText paths reserve
/// only len bytes, and writing the sentinel past capacity was a heap OOB.
fn setSentinel(buf: *std.array_list.Managed(u8)) void {
    buf.ensureUnusedCapacity(1) catch @panic("klaxon: out of memory");
    buf.items.len += 1;
    buf.items[buf.items.len - 1] = 0;
    buf.items.len -= 1;
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

fn hasLabel(s: *TextFieldState) bool {
    return s.label.len > 0;
}
fn hasSupporting(s: *TextFieldState) bool {
    return s.supporting.len > 0;
}

/// CommonDecorationBox's InputPhase: the label/border transition input.
const InputPhase = enum { focused, unfocused_empty, unfocused_not_empty };

fn phaseOf(s: *TextFieldState, focused: bool) InputPhase {
    if (focused) return .focused;
    return if (s.buf.items.len == 0) .unfocused_empty else .unfocused_not_empty;
}

/// labelProgress target: Focused/UnfocusedNotEmpty → 1, UnfocusedEmpty → 0
/// (the Inside/Cutout positions always show the expanded label).
fn labelTarget(s: *TextFieldState) f32 {
    return if (s.phase == .unfocused_empty) 0 else 1;
}

fn labelProgressCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.label_progress = v[0];
    n.markLayoutDirty(); // the outlined width interpolates with progress
    n.markDirty();
}

/// Recompute the InputPhase and retarget the label spring on transitions
/// (MotionSchemeKeyTokens.FastSpatial → the theme spatial spring).
/// Called from paint so externally-routed focus changes transition too.
fn syncPhase(n: *Node, s: *TextFieldState) void {
    const focused = input.isFocused(n) and s.opts.enabled;
    const ph = phaseOf(s, focused);
    if (ph == s.phase) return;
    s.phase = ph;
    if (!hasLabel(s)) {
        s.label_progress = 1;
        return;
    }
    const target = labelTarget(s);
    if (ui.anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = ui.anim.Animation.springAnim(.{ s.label_progress, 0, 0, 0 }, .{ target, 0, 0, 0 }, s.opts.theme.motion.springs.spatial_spring, .{ 0, 0, 0, 0 }),
            .from = .{ s.label_progress, 0, 0, 0 },
            .channel = @ptrCast(&s.label_channel),
            .on_update = .{ .fn_ptr = labelProgressCb, .userdata = n },
        });
    } else {
        s.label_progress = target;
    }
}

fn lerpF(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
/// The label's animated point size — lerp(bodyLarge, bodySmall, progress).
fn labelSize(s: *TextFieldState, t: Theme) f32 {
    return lerpF(t.type_scale.body_large.size, t.type_scale.body_small.size, s.label_progress);
}
/// The label box's min height — lerp(MinTextLineHeight, MinFocusedLabelLineHeight).
fn labelBoxH(s: *TextFieldState) f32 {
    return lerpF(min_text_line_h, min_label_line_h, s.label_progress);
}

/// The horizontal offset of the text/placeholder/label glyphs from the
/// start edge: the 48dp icon box + (16 - 12) padding with an icon,
/// TextFieldPadding without.
fn leftOffset(s: *TextFieldState) f32 {
    return if (s.opts.leading_icon != null) icon_box + h_padding - icon_pad else h_padding;
}
fn rightOffset(s: *TextFieldState) f32 {
    return if (s.opts.trailing_icon != null) icon_box + h_padding - icon_pad else h_padding;
}

/// The container rect: fills the bounds minus the outlined cutout pad on
/// top (minimizedLabelHalfHeight) and the supporting text below.
fn containerRect(n: *Node) Rect {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const top = if (s.opts.variant == .outlined and hasLabel(s)) t.type_scale.body_small.line_height / 2 else 0;
    const sup = if (hasSupporting(s)) supporting_top + min_supporting_line_h else 0;
    return .{ .x = b.x, .y = b.y + top, .w = b.w, .h = @max(0, b.h - top - sup) };
}

fn bodyLarge(t: Theme) theme_mod.TypeStyle {
    return t.type_scale.body_large;
}
fn bodySmall(t: Theme) theme_mod.TypeStyle {
    return t.type_scale.body_small;
}

/// The label's animated line box (placeWithLabel / the cutout layout's
/// place()): the box height lerps 24→16 with labelProgress; the position
/// lerps centered→minimized. Filled keeps x at the text offset (Start
/// alignment both ways); outlined lerps the offset → 16 and straddles the
/// container's top edge. RTL-mirrored. null when there is no label.
pub fn labelRect(n: *Node) ?Rect {
    const s = stateOf(n);
    if (!hasLabel(s)) return null;
    syncPhase(n, s);
    const t = s.opts.theme;
    const c = containerRect(n);
    const p = s.label_progress;
    const rtl = ui.i18n.direction() == .rtl;
    const size = labelSize(s, t);
    const box_h = labelBoxH(s);
    const w = ui.paint.measureText(s.label, size, false).width;
    var x: f32 = undefined;
    var y: f32 = undefined;
    if (s.opts.variant == .filled) {
        // InsideTextFieldLayout: x = leftIconWidth + startPadding → the
        // text offset; y lerps centered → contentPadding.top (8).
        x = c.x + leftOffset(s);
        y = c.y + lerpF((c.h - box_h) / 2, top_pad_label, p);
    } else {
        // CutoutTextFieldLayout: x lerps leadingPlusPadding →
        // startPadding(16); y lerps centered → -box/2 (the cutout).
        x = c.x + lerpF(leftOffset(s), h_padding, p);
        y = c.y + lerpF((c.h - box_h) / 2, -box_h / 2, p);
    }
    if (rtl) x = c.x + c.w - (x - c.x) - w;
    return .{ .x = x, .y = y, .w = w, .h = box_h };
}

/// The input text's line box (the LTR anchor; the width is the content's).
/// Filled+label sits under the floated label (top padding + the label box
/// height — it slides as the label animates); otherwise the 24dp box is
/// vertically centered in the container (single line).
/// Paint mirrors the anchor (with the run width) in RTL.
pub fn textRect(n: *Node) Rect {
    const s = stateOf(n);
    syncPhase(n, s);
    const c = containerRect(n);
    const y = if (s.opts.variant == .filled and hasLabel(s))
        c.y + top_pad_label + labelBoxH(s)
    else
        c.y + (c.h - min_text_line_h) / 2;
    return .{ .x = c.x + leftOffset(s), .y = y, .w = 0, .h = min_text_line_h };
}

/// The resolved colors for the current state — the state-based
/// defaultTextFieldColors: enabled/error/focused axes only (the Hover*
/// token rows are not consumed by TextFieldColors).
const FieldColors = struct {
    container: Color, // filled only (0 = transparent)
    indicator: Color, // the filled bottom line
    indicator_h: f32,
    outline: Color, // outlined only (0 = none)
    outline_w: f32,
    input: Color,
    label: Color,
    placeholder: Color,
    icon_lead: Color,
    icon_trail: Color,
    supporting: Color,
    caret: Color,
    cutout: Color, // the outlined cutout patch = the surface behind the field
};

fn currentColors(s: *TextFieldState, focused: bool) FieldColors {
    const cs = s.opts.theme.colors;
    const filled = s.opts.variant == .filled;
    if (!s.opts.enabled) {
        const dis = ui.paint.withAlphaScaled(cs.on_surface, 0.38);
        return .{
            // DisabledContainerOpacity(0.04) is only consumed by the
            // deprecated colors() overload — the state-based defaults keep
            // SurfaceContainerHighest.
            .container = if (filled) cs.surface_container_highest else 0,
            .indicator = ui.paint.withAlphaScaled(cs.on_surface, 0.38), // DisabledActiveIndicator
            .indicator_h = outline_w,
            .outline = if (!filled) ui.paint.withAlphaScaled(cs.on_surface, 0.12) else 0, // DisabledOutline
            .outline_w = outline_w,
            .input = dis,
            .label = dis,
            .placeholder = dis,
            .icon_lead = dis,
            .icon_trail = dis,
            .supporting = dis,
            .caret = dis,
            .cutout = cs.surface,
        };
    }
    if (s.opts.@"error") {
        return .{
            .container = if (filled) cs.surface_container_highest else 0,
            .indicator = cs.@"error", // Error(ActiveIndicator|Outline)Color
            .indicator_h = if (focused) outline_w_focus else outline_w,
            .outline = if (!filled) cs.@"error" else 0,
            .outline_w = if (focused) outline_w_focus else outline_w,
            .input = cs.on_surface, // ErrorInputColor
            .label = cs.@"error", // ErrorLabelColor
            .placeholder = cs.on_surface_variant, // InputPlaceholderColor
            .icon_lead = cs.on_surface_variant, // ErrorLeadingIconColor
            .icon_trail = cs.@"error", // ErrorTrailingIconColor
            .supporting = cs.@"error", // ErrorSupportingColor
            .caret = cs.@"error", // ErrorFocusCaretColor
            .cutout = cs.surface,
        };
    }
    return .{
        .container = if (filled) cs.surface_container_highest else 0,
        .indicator = if (focused) cs.primary else cs.on_surface_variant, // Focus/ActiveIndicator
        .indicator_h = if (focused) outline_w_focus else outline_w,
        .outline = if (!filled) (if (focused) cs.primary else cs.outline) else 0, // FocusOutline/Outline
        .outline_w = if (focused) outline_w_focus else outline_w,
        .input = cs.on_surface, // (Focus)InputColor
        .label = if (focused) cs.primary else cs.on_surface_variant, // FocusLabel/LabelColor
        .placeholder = cs.on_surface_variant, // InputPlaceholderColor
        .icon_lead = cs.on_surface_variant, // (Focus)LeadingIconColor
        .icon_trail = cs.on_surface_variant, // (Focus)TrailingIconColor
        .supporting = cs.on_surface_variant, // (Focus)SupportingColor
        .caret = cs.primary, // CaretColor
        .cutout = cs.surface,
    };
}

/// Last scalar strictly before `cut` (decodes the UTF-8 sequence backwards).
fn lastCpBefore(str: []const u8, cut: usize) u21 {
    var i = cut;
    while (i > 0 and (str[i - 1] & 0xC0) == 0x80) i -= 1;
    if (i == 0) return 0;
    return std.unicode.utf8Decode(str[i - 1 .. cut]) catch 0xFFFD;
}
fn firstCpAt(str: []const u8, i: usize) u21 {
    if (i >= str.len) return 0;
    const l = std.unicode.utf8ByteSequenceLength(str[i]) catch return 0xFFFD;
    return std.unicode.utf8Decode(str[i..@min(str.len, i + l)]) catch 0xFFFD;
}
/// A segment boundary must never sit where shaping could join across it:
/// combining marks, joiners, emoji modifiers/pairers and Hangul jamo reject
/// the split; ASCII rejects too (liga/kern could bind a Latin pair — e.g.
/// f|i). Whitespace never joins, so it's allowed.
fn atomicBoundary(cp: u21) bool {
    if (cp < 0x80) return cp == ' ' or cp == '\t' or cp == 0;
    if (cp == 0x200D or (cp >= 0xFE0E and cp <= 0xFE0F)) return false;
    if ((cp >= 0x0300 and cp < 0x0370) or (cp >= 0x1AB0 and cp < 0x1AFF) or
        (cp >= 0x1DC0 and cp < 0x1DFF) or (cp >= 0x20D0 and cp < 0x20FF) or
        (cp >= 0xFE20 and cp < 0xFE30)) return false;
    if (cp >= 0x1F1E6 and cp <= 0x1F1FF) return false;
    if (cp >= 0x1100 and cp <= 0x11FF) return false;
    if ((cp >= 0xA960 and cp <= 0xA97C) or (cp >= 0xD7B0 and cp <= 0xD7FB)) return false;
    // RTL scripts reorder across run boundaries — a split inside one must
    // fold so the whole run shapes as a single paragraph, as before.
    if ((cp >= 0x0590 and cp < 0x0800) or (cp >= 0xFB1D and cp < 0xFE00) or
        (cp >= 0xFE70 and cp < 0xFF00) or cp == 0x061C or
        (cp >= 0x200E and cp <= 0x200F) or (cp >= 0x202A and cp <= 0x202E) or
        (cp >= 0x2066 and cp <= 0x2069) or (cp >= 0x10800 and cp < 0x10FFF) or
        (cp >= 0x1E800 and cp < 0x1EFFF)) return false;
    return true;
}
fn segSplitSafe(str: []const u8, cut: usize) bool {
    return atomicBoundary(lastCpBefore(str, cut)) and atomicBoundary(firstCpAt(str, cut));
}

/// The field's measured+shaped rope: `segs` cover buf[0..segs.items end)
/// in order. Each measure reconciles the tail against the buffer — a seg
/// whose stored end or bytes no longer match the tail is dropped (covers
/// every edit path without per-site sync), then the leftover suffix is
/// measured once and pushed (or the whole buffer re-measures when the cut
/// isn't shaping-safe). Steady-state cost: O(#segs + tail bytes).
fn fieldMetrics(s: *TextFieldState) ui.paint.TextMetrics {
    const str = s.text();
    const size = bodyLarge(s.opts.theme).size;
    // Reconcile: segs must form an exact prefix of the buffer, each piece
    // still matching the bytes at its position and measured at the live
    // font size. The first mismatch drops that seg and everything after.
    var covered: usize = 0;
    var keep: usize = 0;
    for (s.segs.items) |seg| {
        if (seg.size != size or covered + seg.text.len > str.len or
            !std.mem.eql(u8, str[covered .. covered + seg.text.len], seg.text)) break;
        covered += seg.text.len;
        keep += 1;
    }
    while (s.segs.items.len > keep) freeSeg(s, s.segs.pop().?);
    if (covered < str.len) {
        const tail: [:0]const u8 = str.ptr[covered..str.len :0];
        if (s.segs.items.len == 0 or segSplitSafe(str, covered)) {
            segPush(s, tail, size);
        } else {
            // Unsafe cut (a joined sequence spans it): fold the tail into
            // the previous segment — re-measure that span, still O(tail).
            const last = &s.segs.items[s.segs.items.len - 1];
            const merged = s.segs.allocator.alloc(u8, last.text.len + tail.len + 1) catch @panic("klaxon: out of memory");
            @memcpy(merged[0..last.text.len], last.text);
            @memcpy(merged[last.text.len ..][0..tail.len], tail);
            merged[last.text.len + tail.len] = 0;
            s.segs.allocator.free(@constCast(last.text.ptr)[0 .. last.text.len + 1]);
            last.text = merged[0 .. last.text.len + tail.len :0];
            last.size = size;
            last.m = ui.paint.measureText(last.text, size, false);
        }
    }
    var m = ui.paint.TextMetrics{};
    for (s.segs.items) |seg| {
        m.width += seg.m.width;
        m.height = seg.m.height; // same size → identical line metrics
        m.ascent = seg.m.ascent;
        m.descent = seg.m.descent;
    }
    return m;
}
fn segPush(s: *TextFieldState, piece: [:0]const u8, size: f32) void {
    const seg = s.segs.addOne() catch @panic("klaxon: out of memory");
    const buf = s.segs.allocator.alloc(u8, piece.len + 1) catch @panic("klaxon: out of memory");
    @memcpy(buf[0..piece.len], piece);
    buf[piece.len] = 0;
    seg.* = .{ .text = buf[0..piece.len :0], .size = size,
        .m = ui.paint.measureText(buf[0..piece.len :0], size, false) };
}
fn freeSeg(s: *TextFieldState, seg: TextFieldState.Seg) void {
    s.segs.allocator.free(@constCast(seg.text.ptr)[0 .. seg.text.len + 1]);
}
fn segsReset(s: *TextFieldState) void {
    while (s.segs.pop()) |seg| freeSeg(s, seg);
}

fn textFieldMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const t = s.opts.theme;
    const str = if (s.buf.items.len > 0) s.text() else s.placeholder;
    const m = if (s.buf.items.len > 0) fieldMetrics(s) else ui.paint.measureText(str, bodyLarge(t).size, false);
    const outlined = s.opts.variant == .outlined;
    // The measured label box: the text at the lerped size + the inner
    // padding the filled variant carries (the cutout label has none).
    const label_w = if (hasLabel(s)) ui.paint.measureText(s.label, labelSize(s, t), false).width else 0;
    // InsideTextFieldLayout.calculateWidth: icons occupy their 48dp boxes;
    // the middle section is max(text|placeholder, label) plus the
    // icon-reduced paddings. The cutout layout drops the label's width as
    // it minimizes (lerp(labelW, 0, progress)) but guarantees the floated
    // label fits: focusedLabelWidth = (labelW + 32) * progress.
    const lead_w: f32 = if (s.opts.leading_icon != null) icon_box else 0;
    const trail_w: f32 = if (s.opts.trailing_icon != null) icon_box else 0;
    const pad_l = leftOffset(s) - lead_w;
    const pad_r = rightOffset(s) - trail_w;
    const text_w = m.width + pad_l + pad_r;
    var middle: f32 = undefined;
    if (outlined) {
        middle = @max(text_w, lerpF(label_w, 0, s.label_progress));
    } else {
        middle = @max(text_w, label_w + pad_l + pad_r);
    }
    var w = lead_w + middle + trail_w;
    if (outlined and hasLabel(s)) {
        w = @max(w, (label_w + h_padding * 2) * s.label_progress);
    }
    w = @max(w, min_w); // TextFieldDefaults.MinWidth (both variants)
    // Height: the container + the cutout top pad (outlined+label) +
    // supporting text below.
    const top_pad: f32 = if (outlined and hasLabel(s)) bodySmall(t).line_height / 2 else 0;
    const h = top_pad + container_h + (if (hasSupporting(s)) supporting_top + min_supporting_line_h else 0);
    return c.constrain(.{ .w = w, .h = h });
}

fn textFieldLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: everything is positioned at paint time
}

/// Paint an icon glyph centered in a 24x24 box.
fn paintIcon(ctx: *kx.Ctx, name: ?icon_w.IconName, x: f32, y: f32, color: Color) void {
    const iname = name orelse return;
    if (color & 0xFF == 0) return;
    icon_w.drawIcon(ctx, iname, x, y, icon_size / 24.0, color);
}

fn textFieldPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    syncPhase(n, s); // the InputPhase transition drives the label spring
    const c = containerRect(n);
    const t = s.opts.theme;
    const focused = input.isFocused(n) and s.opts.enabled;
    const fc = currentColors(s, focused);
    const rtl = ui.i18n.direction() == .rtl;
    const mx = struct {
        fn f(bx: f32, bw: f32, x: f32, w: f32, rtl_flag: bool) f32 {
            return if (rtl_flag) bx + bw - (x - bx) - w else x;
        }
    }.f;
    // The glyph baseline when the text is vertically centered in a `box_h`
    // line box (Compose's heightIn(min).wrapContentHeight() centers the
    // measured block).
    const baselineIn = struct {
        fn f(box_y: f32, box_h: f32, m: ui.paint.TextMetrics) f32 {
            return box_y + (box_h - (m.ascent + m.descent)) / 2 + m.ascent;
        }
    }.f;

    // --- container ---
    if (s.opts.variant == .filled) {
        if (fc.container & 0xFF != 0) {
            // CornerExtraSmallTop: rounded top corners, square bottom
            ui.paint.fillRRectCorners(ctx, c.x, c.y, c.w, c.h, corner, corner, 0, 0, fc.container);
        }
        // the active indicator: the bottom line, full width
        if (fc.indicator & 0xFF != 0) {
            ui.paint.fillRect(ctx, c.x, c.y + c.h - fc.indicator_h, c.w, fc.indicator_h, fc.indicator);
        }
    } else {
        if (fc.outline & 0xFF != 0) {
            ui.paint.strokeRRect(ctx, c.x, c.y, c.w, c.h, corner, fc.outline_w, fc.outline);
        }
        // outlineCutout: erase the top edge behind the label — the hole is
        // anchored at the minimized position (startPadding + the measured
        // label width scaled by labelProgress) with 4dp inner padding.
        if (fc.outline & 0xFF != 0 and hasLabel(s) and s.label_progress > 0) {
            const cut_w = ui.paint.measureText(s.label, labelSize(s, t), false).width * s.label_progress;
            const patch_x = mx(c.x, c.w, c.x + h_padding - cutout_pad, cut_w + cutout_pad * 2, rtl);
            ui.paint.fillRect(ctx, patch_x, c.y - fc.outline_w / 2 - 0.5, cut_w + cutout_pad * 2, fc.outline_w + 1, fc.cutout);
        }
    }

    // --- icons: 24dp glyphs centered in 48dp boxes at the container edges
    // (minimumInteractiveComponentSize — the glyph is inset by 12) ---
    const icon_y = c.y + (c.h - icon_size) / 2;
    if (s.opts.leading_icon) |iname| {
        const ix = mx(c.x, c.w, c.x + icon_pad, icon_size, rtl);
        paintIcon(ctx, iname, ix, icon_y, fc.icon_lead);
    }
    if (s.opts.trailing_icon) |iname| {
        const ix = mx(c.x, c.w, c.x + c.w - icon_box + icon_pad, icon_size, rtl);
        paintIcon(ctx, iname, ix, icon_y, fc.icon_trail);
    }

    // --- text content (clipped to the area between the icons) ---
    const tr = textRect(n);
    const clip_x = c.x + @min(leftOffset(s), rightOffset(s));
    const clip_w = c.w - leftOffset(s) - rightOffset(s);
    ui.paint.clipRect(ctx, clip_x, c.y, clip_w, c.h);
    if (s.buf.items.len > 0) {
        const style = bodyLarge(t);
        const m = fieldMetrics(s);
        const tx = mx(c.x, c.w, tr.x, m.width, rtl);
        // Draw segment-by-segment: each piece's shaped blob is text-cache
        // resident — drawing the whole buffer would shape it fresh every
        // frame (the cache key is the full string, which always changes).
        var sx = tx;
        const baseline = baselineIn(tr.y, tr.h, m);
        for (s.segs.items) |seg| {
            ui.paint.text(ctx, seg.text, sx, baseline, style.size, false, fc.input);
            sx += seg.m.width;
        }
        if (focused) {
            // the caret at the end of the text
            ui.paint.fillRect(ctx, tx + m.width, baseline - m.ascent, caret_w, m.ascent + m.descent, fc.caret);
        }
    } else {
        // The placeholder shows only when the expanded label isn't covering
        // it: focused, or no label (placeholderOpacity).
        if (focused or !hasLabel(s)) {
            if (s.placeholder.len > 0) {
                const style = bodyLarge(t);
                const m = ui.paint.measureText(s.placeholder, style.size, false);
                const tx = mx(c.x, c.w, tr.x, m.width, rtl);
                ui.paint.text(ctx, s.placeholder, tx, baselineIn(tr.y, tr.h, m), style.size, false, fc.placeholder);
            }
        }
        if (focused) {
            // the caret at the start (empty text)
            const m = ui.paint.measureText(" ", bodyLarge(t).size, false);
            ui.paint.fillRect(ctx, mx(c.x, c.w, tr.x, caret_w, rtl), baselineIn(tr.y, tr.h, m) - m.ascent, caret_w, m.ascent + m.descent, fc.caret);
        }
    }
    ui.paint.clipReset(ctx);

    // --- label (the animated box; the glyph lerps size with progress) ---
    if (hasLabel(s)) {
        const lr = labelRect(n).?;
        const size = labelSize(s, t);
        const m = ui.paint.measureText(s.label, size, false);
        ui.paint.text(ctx, s.label, lr.x, baselineIn(lr.y, lr.h, m), size, false, fc.label);
    }

    // --- supporting text (below the container) ---
    if (hasSupporting(s)) {
        const style = bodySmall(t);
        const m = ui.paint.measureText(s.supporting, style.size, false);
        const sx = mx(c.x, c.w, c.x + h_padding, m.width, rtl);
        ui.paint.text(ctx, s.supporting, sx, baselineIn(c.y + c.h + supporting_top, min_supporting_line_h, m), style.size, false, fc.supporting);
    }
}

fn textFieldOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    switch (ev.phase) {
        .down => {
            input.requestFocus(n);
            n.markDirty(); // the label float / caret / colors follow focus
            return true;
        },
        .up => return true,
        .move => return false, // a drag is a scroll, not a field interaction
        .enter, .leave => return true, // no hover styling — the state-based colors have no hover axis
        else => {},
    }
    return false;
}

/// An edit happened: re-layout (the measured width is content-driven),
/// repaint, sync the a11y value, mirror the signal, fire the callback.
fn applyEdit(n: *Node, s: *TextFieldState) void {
    n.markLayoutDirty();
    n.markDirty();
    if (n.semantics) |sem| sem.value = s.text(); // a11y: the value follows edits
    ui.semantics.notifyControlChanged(n); // a11y: the control's value changed
    // The buffer is already bounded by the 1 MiB input cap → set cannot fail.
    if (s.sig) |sig| sig.set(s.text()) catch @panic("klaxon: text buffer exceeds the 1 MiB cap");
    if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
}

fn textFieldOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    switch (ev.kind) {
        .text_input => {
            // Reject (never truncate) input that would grow the text past
            // the documented cap — a paste/IME burst is applied whole or
            // not at all.
            if (s.buf.items.len + ev.text.len > ui.state.TextSignal.max_len) return true;
            s.buf.ensureTotalCapacity(s.buf.items.len + ev.text.len + 1) catch @panic("klaxon: out of memory");
            s.buf.appendSlice(ev.text) catch @panic("klaxon: out of memory");
            setSentinel(&s.buf);
            applyEdit(n, s);
            return true;
        },
        .key_down => switch (ev.key) {
            .backspace => {
                // Delete the last UTF-8 codepoint (continuation bytes first).
                while (s.buf.items.len > 0) {
                    const last = s.buf.items[s.buf.items.len - 1];
                    s.buf.items.len -= 1;
                    if ((last & 0xC0) != 0x80) break;
                }
                setSentinel(&s.buf);
                applyEdit(n, s);
                return true;
            },
            .enter => {
                if (s.on_submitted) |cb| cb.fn_ptr(cb.userdata);
                return true;
            },
            .escape => {
                input.requestFocus(null);
                n.markDirty();
                return true;
            },
            else => {},
        },
    }
    return false;
}

/// An external signal set (the designer): replace the buffer when the text
/// differs. The signal holds the full text, so the comparison runs against
/// the buffer itself — the widget's own sets round-trip as no-ops (the
/// signal dedups equal content).
fn textFieldSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const incoming = s.sig.?.peek();
    if (std.mem.eql(u8, s.text(), incoming)) return;
    s.buf.clearRetainingCapacity();
    s.buf.ensureTotalCapacity(incoming.len + 1) catch @panic("klaxon: out of memory");
    s.buf.appendSlice(incoming) catch @panic("klaxon: out of memory");
    setSentinel(&s.buf);
    n.markLayoutDirty(); // the measured width is content-driven
    n.markDirty();
    if (n.semantics) |sem| sem.value = s.text(); // a11y: the value follows external edits
}

fn textFieldDeinit(n: *Node) void {
    const s = stateOf(n);
    if (ui.anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.label_channel)); // the channel writes into state
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = textFieldSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.free(s.label);
    n.allocator.free(s.placeholder);
    n.allocator.free(s.supporting);
    s.buf.deinit();
    segsReset(s);
    s.segs.deinit();
    n.allocator.destroy(s);
}

const text_field_vtable = ui.node.VTable{
    .measure = textFieldMeasure,
    .layout = textFieldLayout,
    .paint = textFieldPaint,
    .deinit = textFieldDeinit,
    .on_pointer = textFieldOnPointer,
    .on_key = textFieldOnKey,
};

/// An M3E text field. `sig` = null → the text starts at `opts.initial`;
/// non-null → the text mirrors the signal both ways. `on_changed` fires on
/// every edit; `on_submitted` on Enter. The field is a leaf: it owns its text
/// buffer and paints all of its chrome. Text is growable up to
/// ui.state.TextSignal.max_len (1 MiB); over-cap initial text is REJECTED
/// (error.TextTooLong), never truncated.
pub fn textField(allocator: std.mem.Allocator, sig: ?*ui.state.TextSignal, on_changed: ?Callback, on_submitted: ?Callback, opts: TextFieldOptions) !*Node {
    // Rejected up front: over the documented cap → error.TextTooLong (never
    // truncated). Checked before any allocation so nothing needs freeing.
    const initial: []const u8 = if (sig) |sg| sg.peek() else opts.initial;
    if (initial.len > ui.state.TextSignal.max_len) return error.TextTooLong;
    const node = try Node.create(allocator, &text_field_vtable);
    errdefer node.allocator.destroy(node); // no state yet
    const s = try allocator.create(TextFieldState);
    errdefer allocator.destroy(s);
    const label = try dupeZ(allocator, opts.label);
    errdefer allocator.free(label);
    const placeholder = try dupeZ(allocator, opts.placeholder);
    errdefer allocator.free(placeholder);
    const supporting = try dupeZ(allocator, opts.supporting);
    errdefer allocator.free(supporting);
    s.* = .{
        .buf = std.array_list.Managed(u8).init(allocator),
        .segs = std.array_list.Managed(TextFieldState.Seg).init(allocator),
        .label = label,
        .placeholder = placeholder,
        .supporting = supporting,
        .opts = opts,
        .sig = sig,
        .on_changed = on_changed,
        .on_submitted = on_submitted,
        .label_progress = if (initial.len > 0) 1 else 0,
        .phase = if (initial.len > 0) .unfocused_not_empty else .unfocused_empty,
    };
    errdefer {
        allocator.free(s.label);
        allocator.free(s.placeholder);
        allocator.free(s.supporting);
        s.buf.deinit();
        s.segs.deinit();
    }
    s.buf.ensureTotalCapacity(initial.len + 1) catch @panic("klaxon: out of memory");
    if (initial.len > 0) {
        s.buf.appendSlice(initial) catch @panic("klaxon: out of memory");
    }
    setSentinel(&s.buf); // null-terminates the (possibly empty) buffer
    node.state = s;
    ui.semantics.attach(node, .{
        .role = .text_field,
        .label = if (s.label.len > 0) s.label else s.placeholder,
        .hint = s.placeholder,
        .value = s.text(),
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
    }); // Phase 2c
    if (sig) |sg| {
        sg.subscribe(.{ .callback = .{ .fn_ptr = textFieldSyncCb, .userdata = node } }); // external edits land in the buffer
    }
    return node;
}

/// Current text field text — borrowed from the widget's buffer (valid until
/// the next edit or deinit).
pub fn text(n: *Node) [:0]const u8 {
    return stateOf(n).text();
}

/// Replace the text (the gallery restores entries across theme rebuilds).
/// Over-cap text is rejected: the field keeps its current contents.
pub fn setText(n: *Node, str: []const u8) void {
    const s = stateOf(n);
    if (str.len > ui.state.TextSignal.max_len) return;
    s.buf.clearRetainingCapacity();
    s.buf.ensureTotalCapacity(str.len + 1) catch @panic("klaxon: out of memory");
    s.buf.appendSlice(str) catch @panic("klaxon: out of memory");
    setSentinel(&s.buf);
    n.markLayoutDirty();
    n.markDirty();
    if (n.semantics) |sem| sem.value = s.text();
    ui.semantics.notifyControlChanged(n);
    if (s.sig) |sig| sig.set(s.text()) catch @panic("klaxon: text buffer exceeds the 1 MiB cap");
}

// --- tests ---

fn editCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "text_field: measures 56/64 (+supporting), MinWidth 280, content width + paddings" {
    const t = theme_mod.light;
    // outlined + label → 8dp cutout pad + 56 container (topPaddingForLabelCutout)
    const b = try textField(std.testing.allocator, null, null, null, .{ .label = "Email", .placeholder = "you@example.com", .theme = t });
    defer b.deinit();
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(bodySmall(t).line_height / 2 + container_h, m.h);
    try std.testing.expectEqual(min_w, m.w); // MinWidth clamps the small content
    // wide content: width = the text + the icon-reduced paddings
    const w2 = try textField(std.testing.allocator, null, null, null, .{ .initial = "a very long piece of input text that exceeds the minimum width" });
    defer w2.deinit();
    const tw2 = ui.paint.measureText("a very long piece of input text that exceeds the minimum width", 16, false).width;
    try std.testing.expectApproxEqAbs(h_padding * 2 + tw2, w2.measure(.{ .max_w = 2000, .max_h = 2000 }).w, 0.001);
    // outlined without a label keeps 56 (no cutout pad)
    const nl = try textField(std.testing.allocator, null, null, null, .{ .placeholder = "hint" });
    defer nl.deinit();
    try std.testing.expectEqual(container_h, nl.measure(.{ .max_w = 2000, .max_h = 2000 }).h);
    // filled + label → no cutout pad: 56 + supporting (4 + the 16dp min box)
    const s = try textField(std.testing.allocator, null, null, null, .{ .variant = .filled, .label = "Email", .supporting = "Helper", .theme = t });
    defer s.deinit();
    try std.testing.expectEqual(container_h + supporting_top + min_supporting_line_h, s.measure(.{ .max_w = 2000, .max_h = 2000 }).h);
    // icons occupy their 48dp boxes; the text padding is icon-reduced:
    // 48 + (16-12) + text + (16-12) + 48 — the icon test needs text > 280-104
    const ic = try textField(std.testing.allocator, null, null, null, .{ .leading_icon = .search, .trailing_icon = .close, .initial = "another fairly long piece of input text for measure" });
    defer ic.deinit();
    const tw = ui.paint.measureText("another fairly long piece of input text for measure", 16, false).width;
    try std.testing.expectApproxEqAbs((icon_box + h_padding - icon_pad) * 2 + tw, ic.measure(.{ .max_w = 2000, .max_h = 2000 }).w, 0.001);
}

test "text_field: the label floats on focus (expanded centered → minimized)" {
    // outlined: the widget reserves 8dp above the 56dp container for the
    // cutout label (topPaddingForLabelCutout) — layout it at 64
    const o = try textField(std.testing.allocator, null, null, null, .{ .label = "Email" });
    defer o.deinit();
    o.layout(.{ .x = 0, .y = 0, .w = 260, .h = 64 });
    var lr = labelRect(o).?;
    try std.testing.expectEqual(@as(f32, 24), lr.y); // c.y(8) + (56-24)/2, expanded
    try std.testing.expectEqual(@as(f32, 24), lr.h); // MinTextLineHeight
    try std.testing.expectEqual(@as(f32, 16), lr.x);
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.focus(o);
    lr = labelRect(o).?;
    try std.testing.expectEqual(@as(f32, 0), lr.y); // c.y - 16/2: straddles the container's top edge
    try std.testing.expectEqual(@as(f32, 16), lr.h); // MinFocusedLabelLineHeight
    try std.testing.expectEqual(@as(f32, 16), lr.x); // the cutout aligns to the start padding
    router.focus(null);
    // filled: minimized = at the top INSIDE the container
    const f = try textField(std.testing.allocator, null, null, null, .{ .variant = .filled, .label = "Email", .initial = "x" });
    defer f.deinit();
    f.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    // has text → minimized even unfocused
    lr = labelRect(f).?;
    try std.testing.expectEqual(@as(f32, 8), lr.y); // top_pad_label
    try std.testing.expectEqual(@as(f32, 16), lr.x);
    // a leading icon pushes the EXPANDED outlined label to the text offset;
    // the minimized cutout label still aligns to 16
    const ic = try textField(std.testing.allocator, null, null, null, .{ .label = "Email", .leading_icon = .search });
    defer ic.deinit();
    ic.layout(.{ .x = 0, .y = 0, .w = 260, .h = 64 });
    try std.testing.expectEqual(icon_box + h_padding - icon_pad, labelRect(ic).?.x);
    router.focus(ic);
    try std.testing.expectEqual(h_padding, labelRect(ic).?.x);
    // no label → no label rect
    const nl = try textField(std.testing.allocator, null, null, null, .{});
    defer nl.deinit();
    try std.testing.expect(labelRect(nl) == null);
}

test "text_field: click focuses; typing appends; backspace/enter/escape; disabled swallows" {
    var changed: u32 = 0;
    var submitted: u32 = 0;
    const cb = Callback{ .fn_ptr = editCounterCb, .userdata = &changed };
    const sub = Callback{ .fn_ptr = editCounterCb, .userdata = &submitted };
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const b = try textField(std.testing.allocator, null, cb, sub, .{ .label = "Name" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    try std.testing.expect(!input.isFocused(b));
    // click → focus
    router.dispatchPointer(b, .{ .phase = .down, .x = 130, .y = 28 });
    try std.testing.expect(input.isFocused(b));
    // type
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "Hi" });
    try std.testing.expectEqualStrings("Hi", text(b));
    try std.testing.expectEqual(@as(u32, 1), changed);
    try std.testing.expectEqualStrings("Hi", b.semantics.?.value); // a11y follows
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "!" });
    try std.testing.expectEqualStrings("Hi!", text(b));
    // backspace deletes the last codepoint
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .backspace });
    try std.testing.expectEqualStrings("Hi", text(b));
    try std.testing.expectEqual(@as(u32, 3), changed);
    // enter submits (no newline — single line)
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 1), submitted);
    try std.testing.expectEqualStrings("Hi", text(b));
    // escape blurs
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .escape });
    try std.testing.expect(!input.isFocused(b));
    // the label stays floated while the field holds text (minimized = focused
    // OR has text) — the box straddles the container's top edge inside bounds
    try std.testing.expectEqual(@as(f32, 0), labelRect(b).?.y);
    // disabled: no focus, no edits
    const dis = try textField(std.testing.allocator, null, cb, sub, .{ .enabled = false, .initial = "Locked" });
    defer dis.deinit();
    dis.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    router.dispatchPointer(dis, .{ .phase = .down, .x = 130, .y = 28 });
    try std.testing.expect(!input.isFocused(dis));
    try std.testing.expectEqualStrings("Locked", text(dis));
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
}

test "text_field: the signal mirrors the text both ways" {
    const sig = try ui.state.TextSignal.init(std.testing.allocator, "Ada");
    defer sig.deinit();
    const b = try textField(std.testing.allocator, sig, null, null, .{});
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    try std.testing.expectEqualStrings("Ada", text(b)); // initialized from the signal
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.dispatchPointer(b, .{ .phase = .down, .x = 130, .y = 28 });
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "!" });
    try std.testing.expectEqualStrings("Ada!", sig.peek()); // the widget sets the signal
    // an external set replaces the buffer
    try sig.set("Bob");
    try std.testing.expectEqualStrings("Bob", text(b));
    try std.testing.expectEqualStrings("Bob", b.semantics.?.value);
}

test "text_field: text past the old 255-byte cap round-trips (CJK included)" {
    const sig = try ui.state.TextSignal.init(std.testing.allocator, "");
    defer sig.deinit();
    const b = try textField(std.testing.allocator, sig, null, null, .{});
    defer b.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.focus(b);
    // 120 CJK chars = 360 bytes — over the old fixed TextBuf cap
    var long_buf: [360]u8 = undefined;
    var long_len: usize = 0;
    for (0..120) |i| {
        const s = std.fmt.bufPrint(long_buf[long_len..], "{s}", .{switch (i % 3) {
            0 => "こ",
            1 => "ん",
            else => "世",
        }}) catch unreachable;
        long_len += s.len;
    }
    const long = long_buf[0..long_len];
    _ = router.dispatchKey(.{ .kind = .text_input, .text = long });
    try std.testing.expectEqualStrings(long, text(b)); // the widget buffer holds all of it
    try std.testing.expectEqualStrings(long, sig.peek()); // and so does the signal
    // an external over-the-old-cap set lands whole too
    var other_buf: [300]u8 = undefined;
    @memset(&other_buf, 'x');
    const other = other_buf[0..];
    try sig.set(other);
    try std.testing.expectEqualStrings(other, text(b));
}

test "text_field: input over the 1 MiB cap is rejected, not truncated" {
    const b = try textField(std.testing.allocator, null, null, null, .{});
    defer b.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.focus(b);
    const huge = try std.testing.allocator.alloc(u8, ui.state.TextSignal.max_len + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'x');
    _ = router.dispatchKey(.{ .kind = .text_input, .text = huge }); // over the cap → dropped whole
    try std.testing.expectEqual(@as(usize, 0), text(b).len);
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "ok" });
    try std.testing.expectEqualStrings("ok", text(b));
    // setText over the cap keeps the current text; an over-cap initial fails
    setText(b, huge);
    try std.testing.expectEqualStrings("ok", text(b));
    try std.testing.expectError(error.TextTooLong, textField(std.testing.allocator, null, null, null, .{ .initial = huge }));
}

test "text_field: RTL mirrors the chrome (the label moves to the end side)" {
    const i18n = try ui.i18n.I18n.init(std.testing.allocator, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    const b = try textField(std.testing.allocator, null, null, null, .{ .label = "Email", .leading_icon = .search });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    const lr = labelRect(b).?;
    const lw = ui.paint.measureText("Email", 16, false).width;
    // mirrored: the label's END is at the end-side icon offset (the leading
    // icon moved to the end side): 48dp box + 4dp reduced padding
    try std.testing.expectEqual(@as(f32, 260 - (icon_box + h_padding - icon_pad) - lw), lr.x);
    const tr = textRect(b);
    try std.testing.expectEqual(icon_box + h_padding - icon_pad, tr.x); // the LTR anchor (paint mirrors it)
}

test "golden: RTL paints the input text at the end side" {
    const i18n = try ui.i18n.I18n.init(std.testing.allocator, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .initial = "Hi", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 300, 80);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12, .w = 260, .h = 56 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const m = ui.paint.measureText("Hi", 16, false);
    // the run is end-aligned: ink at the right side, none where LTR paints
    try std.testing.expect(f.countNotIn(.{ .x = 36, .y = 28, .w = m.width, .h = 24 }, 0xFFFFFFFF) == 0);
    try std.testing.expect(f.countNotIn(.{ .x = 280 - m.width, .y = 28, .w = m.width, .h = 24 }, 0xFFFFFFFF) > 0);
}

test "golden: outlined field strokes the 1dp outline, transparent inside, expanded label" {
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .label = "Email", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 300, 96);
    defer r.deinit();
    // outlined + label = 64: 8dp cutout pad + the 56dp container at y 20.5
    b.layout(.{ .x = 20, .y = 12.5, .w = 260, .h = 64 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the top border, mid-edge (half-pixel aligned): outline
    try std.testing.expectEqual(t.colors.outline, f.pixelAt(150, 20));
    // inside, right of the label: transparent → the background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(150, 40));
    // the expanded label ink (on_surface_variant) in the centered band
    try std.testing.expect(f.countColorIn(.{ .x = 36, .y = 36, .w = 100, .h = 24 }, t.colors.on_surface_variant) > 0);
}

test "golden: outlined focused field — 2dp primary outline + the cutout patch" {
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .label = "Email", .theme = t });
    defer b.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.focus(b);
    var r = try golden.Renderer.init(std.testing.allocator, 300, 96);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12.5, .w = 260, .h = 64 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the focused outline: 2dp primary (band 19.5..22.5 → pixel 20/21 exact)
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(150, 20));
    // the cutout: no primary stroke in the patch's padding zone (left of the
    // label glyphs — the patch erased it); the stroke resumes right of the label
    const lw = ui.paint.measureText("Email", 12, false).width;
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(.{ .x = 32.5, .y = 20, .w = 3, .h = 1 }, t.colors.primary));
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(200, 20));
    // the minimized label ink (primary, focused) straddles the container's
    // top edge at y=20.5 (box 12.5..28.5)
    try std.testing.expect(f.countColorIn(.{ .x = 36, .y = 13, .w = lw, .h = 16 }, t.colors.primary) > 0);
}

test "golden: filled field paints the container + the active indicator; focused doubles it" {
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .variant = .filled, .label = "Notes", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 300, 80);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12, .w = 260, .h = 56 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the container: surface_container_highest (inside, left of the label)
    try std.testing.expectEqual(t.colors.surface_container_highest, f.pixelAt(24, 30));
    // the square bottom corner: the indicator spans the full width
    try std.testing.expectEqual(t.colors.on_surface_variant, f.pixelAt(20, 67));
    // the rounded top corner: the exact corner stays background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20, 12));
    // focused: the indicator is 2dp primary
    var router = input.InputRouter{};
    input.setCurrent(&router);
    router.focus(b);
    r.paint(b, 0xFFFFFFFF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(150, 66));
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(150, 67));
    input.setCurrent(null);
}

test "golden: error field paints the error outline + the error supporting text" {
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .@"error" = true, .label = "Username", .supporting = "Already taken", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 300, 100);
    defer r.deinit();
    // outlined + label + supporting = 8 + 56 + 20
    b.layout(.{ .x = 20, .y = 12.5, .w = 260, .h = 84 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the error outline (the container's top edge at 20.5)
    try std.testing.expectEqual(t.colors.@"error", f.pixelAt(150, 20));
    // the supporting text ink (error) below the container
    try std.testing.expect(f.countColorIn(.{ .x = 36, .y = 82, .w = 150, .h = 13 }, t.colors.@"error") > 0);
}

test "golden: disabled field paints the OnSurface@0.12 outline + @0.38 content" {
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .enabled = false, .label = "Email", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 300, 96);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12.5, .w = 260, .h = 64 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the top border: on_surface @ 0.12 over white
    try golden.expectPixelApprox(f, 150, 20, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.12), 0xFFFFFFFF));
    // the label ink: on_surface @ 0.38 over white
    const dis_label = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), 0xFFFFFFFF);
    try std.testing.expect(f.countColorIn(.{ .x = 36, .y = 40, .w = 100, .h = 18 }, dis_label) > 0);
}

test "golden: the caret paints at the end of the text when focused" {
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .label = "Name", .initial = "Hi", .theme = t });
    defer b.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.focus(b);
    var r = try golden.Renderer.init(std.testing.allocator, 300, 80);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12, .w = 260, .h = 56 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const m = ui.paint.measureText("Hi", 16, false);
    const caret_x = 20 + 16 + m.width; // text_x + the text width
    const tr = textRect(b);
    // the caret band (primary ink) right after the text...
    try std.testing.expect(f.countNotIn(.{ .x = caret_x - 0.5, .y = tr.y + 2, .w = 2, .h = m.height - 4 }, 0xFFFFFFFF) > 0);
    // ...and nothing 4dp further right
    try std.testing.expectEqual(@as(u64, 0), f.countNotIn(.{ .x = caret_x + 4, .y = tr.y + 2, .w = 4, .h = m.height - 4 }, 0xFFFFFFFF));
}
