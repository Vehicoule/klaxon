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
//     spring — theme.motion.springs.fast_spatial) lerps position, box
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
//   - The outlined cutout now clips the border stroke with
//     ClipOp.Difference (kx_clip_rect_diff, ABI 0.20.0) — a real hole like
//     upstream; the background shows through on any surface.
//   - The label's font size lerps but its weight/tracking don't (upstream
//     lerps the full TextStyle); label/indicator colors snap on the phase
//     transition rather than animating FastEffects; the placeholder alpha
//     snaps instead of the fast/slow effects fade.
//   - The caret is a real editing position: click places it at the nearest
//     grapheme boundary (SkParagraph getGlyphPositionAtCoordinate through
//     kx_text_position_at), it blinks at Compose's 500ms cadence while
//     focused (a timeline ticker re-shows it on every edit/move), and
//     typing/backspace/delete/left/right apply AT the caret. Selection is
//     real too: drag or shift+arrows/home/end extend the range (primary
//     @0.4 highlight, collapsed anchors, delete replaces the range).
//     Still missing: no clipboard (cut/copy/paste), no selection handles
//     or double-click word select, no TextSelectionColors customization,
//     and arrows move by codepoint, not grapheme cluster.
//   - RTL mirrors the chrome; the text run itself stays LTR (no bidi —
//     same as text.zig); under RTL arrow keys still move logically.
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
const icon_size: f32 = 24; // LeadingIconSize/TrailingIconSize
// The icon boxes ride the a11y interactive minimum —
// theme.platform.hit_target_min (upstream minimumInteractiveComponentSize;
// 48dp mobile / 24 desktop).
fn iconBox(t: Theme) f32 {
    return t.platform.hit_target_min;
}
/// textFieldHorizontalIconPadding — the icon's inset inside its box.
fn iconPad(t: Theme) f32 {
    return (iconBox(t) - icon_size) / 2;
}
const corner: f32 = 4; // CornerExtraSmall (top corners for the filled)
const outline_w: f32 = 1; // UnfocusedIndicator/BorderThickness
const outline_w_focus: f32 = 2; // FocusedIndicator/BorderThickness
const caret_w: f32 = 1;
/// Upstream TextFieldDefaults caret cadence (Compose's cursor blink is a
/// fixed 500ms half-period — the caret re-shows on any caret event).
const blink_half_ms: u64 = 500;
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
    /// IME composition (preedit) — SDL_EVENT_TEXT_EDITING replaces it
    /// wholesale; the next text_input commits into `buf` and clears it.
    /// Never committed to `buf`, the signal, or semantics — platforms that
    /// collapse composition to commits (Android) simply leave it empty.
    comp: std.array_list.Managed(u8) = undefined,
    /// SDL's cursor offset inside `comp` (bytes, text_editing comp_start);
    /// the caret draws there while a composition is open.
    comp_cursor: i32 = 0,
    /// The caret: a byte offset into `buf` on a codepoint boundary. Every
    /// committed edit applies at this position; a pointer-down maps to the
    /// nearest grapheme boundary through the paragraph position lookup.
    caret: usize = 0,
    /// The selection anchor — the frozen end of the selection range; the
    /// caret is the moving end. anchor == caret → collapsed (no highlight).
    /// Click sets both; drag/shift-move move only the caret.
    sel_anchor: usize = 0,
    /// Primary-button drag in progress (a drag inside the field extends the
    /// selection instead of scrolling away).
    dragging: bool = false,
    /// The blink clock (Compose's 500ms half-period). `caret_on` is the
    /// painted phase; `blink_epoch` is the tick-time the ON phase started
    /// — maxInt = "re-base at the next tick" (set by every caret event,
    /// whose KeyEvent carries no timestamp).
    caret_on: bool = true,
    blink_epoch: u64 = std.math.maxInt(u64),
    /// The blink ticker — registered lazily at the first paint (a field
    /// built before the host installs its timeline retries), removed at
    /// deinit. It only keeps the host awake while the field is focused.
    ticker: ?ui.anim.Timeline.Ticker = null,

    const Seg = struct {
        text: [:0]u8, // owned
        size: f32, // the measure font size (theme moves invalidate)
        m: ui.paint.TextMetrics,
    };

    fn text(s: *TextFieldState) [:0]const u8 {
        // Sentinel slice via the many-item pointer (see input.zig).
        return s.buf.items.ptr[0..s.buf.items.len :0];
    }

    fn composition(s: *TextFieldState) [:0]const u8 {
        return s.comp.items.ptr[0..s.comp.items.len :0];
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
            .kind = ui.anim.Animation.springAnim(.{ s.label_progress, 0, 0, 0 }, .{ target, 0, 0, 0 }, s.opts.theme.motion.springs.fast_spatial, .{ 0, 0, 0, 0 }),
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
/// start edge: the icon box + (16 - iconPad) padding with an icon,
/// TextFieldPadding without.
fn leftOffset(s: *TextFieldState) f32 {
    const t = s.opts.theme;
    return if (s.opts.leading_icon != null) iconBox(t) + h_padding - iconPad(t) else h_padding;
}
fn rightOffset(s: *TextFieldState) f32 {
    const t = s.opts.theme;
    return if (s.opts.trailing_icon != null) iconBox(t) + h_padding - iconPad(t) else h_padding;
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
            @memcpy(merged[last.text.len..][0..tail.len], tail);
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
    seg.* = .{ .text = buf[0..piece.len :0], .size = size, .m = ui.paint.measureText(buf[0..piece.len :0], size, false) };
}
fn freeSeg(s: *TextFieldState, seg: TextFieldState.Seg) void {
    s.segs.allocator.free(@constCast(seg.text.ptr)[0 .. seg.text.len + 1]);
}
fn segsReset(s: *TextFieldState) void {
    while (s.segs.pop()) |seg| freeSeg(s, seg);
}

// --- the caret ---

/// The run's visual left edge in node-parent space (the `mx` mirror).
fn runLeft(n: *Node, run_w: f32) f32 {
    const c = containerRect(n);
    const tr = textRect(n);
    if (ui.i18n.direction() == .rtl) {
        return c.x + c.w - (tr.x - c.x) - run_w;
    }
    return tr.x;
}

/// UTF-16 position → byte offset. The paragraph reports grapheme-cluster
/// boundaries in UTF-16 code units (astral chars count 2 — the surrogate
/// pair); a position mid-cluster clamps back to the codepoint's start.
fn utf16ToByteIndex(str: []const u8, pos16: usize) usize {
    var u16n: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        const l = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
        const units: usize = if (l == 4) 2 else 1; // astral = surrogate pair
        if (u16n + units > pos16) break; // inside a codepoint → its start
        u16n += units;
        i += l;
    }
    return i;
}

/// Byte offset of the grapheme boundary nearest to the press — the
/// paragraph's getGlyphPositionAtCoordinate (Compose's
/// TextLayoutResult.getOffsetForPosition). One layout per click; the
/// field's own segmented path is paint-only. Falls back to the run's
/// near edge when the paragraph backend can't build.
fn caretFromPoint(n: *Node, s: *TextFieldState, px: f32, py: f32) usize {
    const str = s.text();
    if (str.len == 0) return 0;
    const m = fieldMetrics(s);
    const tx = runLeft(n, m.width);
    const tr = textRect(n);
    const l = ui.paint.textLayoutBegin(0) orelse { // no wrap — the field clips
        return if (px <= tx) 0 else str.len;
    };
    defer ui.paint.textLayoutDestroy(l);
    // The paint path draws the segments in LOGICAL order (the text-run-LTR
    // deviation). The hit test must agree with what's on screen, so the
    // probe paragraph builds under LTR regardless of the locale's base
    // direction — single-threaded UI; the global is restored right after.
    const prev_rtl = ui.paint.textDirectionRtl();
    ui.paint.setTextDirection(false);
    defer ui.paint.setTextDirection(prev_rtl);
    const style = bodyLarge(s.opts.theme);
    ui.paint.textLayoutSpan(l, str, ui.paint.textStyle(style.size, 400, 0, 0, 0xFF0000FF));
    const pos = ui.paint.textLayoutPositionAt(l, px - tx, py - tr.y);
    if (pos < 0) return if (px <= tx) 0 else str.len;
    return utf16ToByteIndex(str, @intCast(pos));
}

/// The x of a byte offset inside the run (run-space): whole segments
/// before it + the measured prefix of the straddled segment. The same
/// segmented sum the paint path draws, so caret and selection edges land
/// exactly where the glyphs are.
fn runXAt(s: *TextFieldState, pos: usize) f32 {
    const size = bodyLarge(s.opts.theme).size;
    var x: f32 = 0;
    var covered: usize = 0;
    for (s.segs.items) |seg| {
        // Strict: an offset on a segment's end boundary is the same x as
        // the next segment's start — falling through skips the measure.
        if (pos < covered + seg.text.len) {
            return x + ui.paint.measureTextLen(seg.text[0 .. pos - covered], size, false).width;
        }
        x += seg.m.width;
        covered += seg.text.len;
    }
    return x; // at/past the run end — no measure needed
}

/// The ordered selection range [lo, hi); empty when collapsed.
fn selRange(s: *const TextFieldState) struct { lo: usize, hi: usize } {
    return .{ .lo = @min(s.caret, s.sel_anchor), .hi = @max(s.caret, s.sel_anchor) };
}

/// Delete [lo, hi) from the buffer and collapse the caret onto `lo`.
/// The caller decides whether this is an edit (applyEdit) or not.
fn deleteRange(s: *TextFieldState, lo: usize, hi: usize) void {
    std.mem.copyForwards(u8, s.buf.items.ptr[lo .. s.buf.items.len - (hi - lo)], s.buf.items[hi..]);
    s.buf.items.len -= hi - lo;
    s.caret = lo;
    s.sel_anchor = lo;
    setSentinel(&s.buf);
}

/// A caret event (move/edit/focus): the caret shows for the next half
/// period. The epoch re-bases at the next tick (KeyEvent has no
/// timestamp — the ticker's now_ms is the only SDL-epoch clock here).
fn resetBlink(s: *TextFieldState) void {
    s.caret_on = true;
    s.blink_epoch = std.math.maxInt(u64);
}

fn caretTickCb(userdata: ?*anyopaque, now_ms: u64) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.blink_epoch == std.math.maxInt(u64)) s.blink_epoch = now_ms;
    const on = ((now_ms - s.blink_epoch) / blink_half_ms) % 2 == 0;
    if (on != s.caret_on) {
        s.caret_on = on;
        n.markDirty();
    }
}

/// The blink only needs the host awake while the caret is shown — an
/// unfocused field paints no caret and lets the loop block.
fn caretPendingCb(userdata: ?*anyopaque) bool {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    return s.opts.enabled and input.isFocused(n);
}

/// Register the blink ticker once (the scrollbar's lazy pattern: built
/// before the host installs its timeline → retries at the first paint).
fn ensureTicker(n: *Node, s: *TextFieldState) void {
    if (s.ticker != null) return;
    const tl = ui.anim.timeline() orelse return;
    const t = ui.anim.Timeline.Ticker{ .fn_ptr = caretTickCb, .userdata = n, .has_pending = caretPendingCb };
    tl.addTicker(t);
    s.ticker = t;
}

/// Move the caret to `pos` clamped onto a codepoint boundary. `extend`
/// keeps the anchor (shift-arrow / drag selection); otherwise the anchor
/// collapses onto the caret.
fn moveCaret(n: *Node, s: *TextFieldState, pos: usize, extend: bool) void {
    var p = @min(pos, s.buf.items.len);
    // items[len] is the sentinel slot — outside the slice: only scan
    // continuation bytes strictly inside the text.
    while (p > 0 and p < s.buf.items.len and (s.buf.items[p] & 0xC0) == 0x80) p -= 1;
    if (p == s.caret and (extend or p == s.sel_anchor)) return;
    s.caret = p;
    if (!extend) s.sel_anchor = p;
    resetBlink(s);
    n.markDirty();
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
    const lead_w: f32 = if (s.opts.leading_icon != null) iconBox(t) else 0;
    const trail_w: f32 = if (s.opts.trailing_icon != null) iconBox(t) else 0;
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
    ensureTicker(n, s); // the caret blink (focused fields stay awake)
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
            // outlineCutout: Compose clips the border stroke with
            // ClipOp.Difference — a REAL hole behind the label (whatever
            // background shows through), not a surface-colored patch.
            if (hasLabel(s) and s.label_progress > 0) {
                const cut_w = ui.paint.measureText(s.label, labelSize(s, t), false).width * s.label_progress;
                const hole_x = mx(c.x, c.w, c.x + h_padding - cutout_pad, cut_w + cutout_pad * 2, rtl);
                // ±2px past the stroke's outer edge so no AA fringe survives.
                ui.paint.clipRectDiff(ctx, hole_x, c.y - fc.outline_w - 2, cut_w + cutout_pad * 2, fc.outline_w * 2 + 4);
                ui.paint.strokeRRect(ctx, c.x, c.y, c.w, c.h, corner, fc.outline_w, fc.outline);
                ui.paint.clipReset(ctx);
            } else {
                ui.paint.strokeRRect(ctx, c.x, c.y, c.w, c.h, corner, fc.outline_w, fc.outline);
            }
        }
    }

    // --- icons: 24dp glyphs centered in iconBox (the platform's
    // minimumInteractiveComponentSize) boxes at the container edges ---
    const icon_y = c.y + (c.h - icon_size) / 2;
    if (s.opts.leading_icon) |iname| {
        const ix = mx(c.x, c.w, c.x + iconPad(t), icon_size, rtl);
        paintIcon(ctx, iname, ix, icon_y, fc.icon_lead);
    }
    if (s.opts.trailing_icon) |iname| {
        const ix = mx(c.x, c.w, c.x + c.w - iconBox(t) + iconPad(t), icon_size, rtl);
        paintIcon(ctx, iname, ix, icon_y, fc.icon_trail);
    }

    // --- text content (clipped to the area between the icons) ---
    const tr = textRect(n);
    const clip_x = c.x + @min(leftOffset(s), rightOffset(s));
    const clip_w = c.w - leftOffset(s) - rightOffset(s);
    ui.paint.clipRect(ctx, clip_x, c.y, clip_w, c.h);
    const has_comp = s.comp.items.len > 0;
    if (s.buf.items.len > 0 or has_comp) {
        const style = bodyLarge(t);
        const m = fieldMetrics(s);
        const tx = mx(c.x, c.w, tr.x, m.width, rtl);
        // Draw segment-by-segment: each piece's shaped blob is text-cache
        // resident — drawing the whole buffer would shape it fresh every
        // frame (the cache key is the full string, which always changes).
        const baseline = baselineIn(tr.y, tr.h, m);
        // Selection highlight — behind the glyphs (upstream:
        // TextSelectionColors background, primary @ 0.4). The range is
        // contiguous in the painted logical order.
        const sel = selRange(s);
        if (sel.hi > sel.lo) {
            const hx0 = tx + runXAt(s, sel.lo);
            const hx1 = tx + runXAt(s, sel.hi);
            ui.paint.fillRect(ctx, hx0, baseline - m.ascent, hx1 - hx0, m.ascent + m.descent, ui.paint.withAlphaScaled(fc.caret, 0.4));
        }
        var sx = tx;
        for (s.segs.items) |seg| {
            ui.paint.text(ctx, seg.text, sx, baseline, style.size, false, fc.input);
            sx += seg.m.width;
        }
        var caret_x = tx + runXAt(s, s.caret);
        if (has_comp) {
            // Preedit: appended visually after the committed text with the
            // platform-conventional underline (Compose marks the composing
            // range; a 1px underline is the standard visual). SDL's
            // comp_start positions the IME cursor INSIDE the composition.
            const comp = s.composition();
            const comp_m = ui.paint.measureText(comp, style.size, false);
            ui.paint.text(ctx, comp, sx, baseline, style.size, false, fc.input);
            ui.paint.fillRect(ctx, sx, baseline + 1, comp_m.width, 1, fc.input);
            const at: usize = @intCast(@min(@max(s.comp_cursor, 0), @as(i32, @intCast(comp.len))));
            caret_x = sx + ui.paint.measureTextLen(comp[0..at], style.size, false).width;
        }
        if (focused and s.caret_on) {
            // the caret at its position (inside the composition when open)
            ui.paint.fillRect(ctx, caret_x, baseline - m.ascent, caret_w, m.ascent + m.descent, fc.caret);
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
        if (focused and s.caret_on) {
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
            // Click-to-caret: the press maps to the nearest grapheme
            // boundary (the pointer arrives in the node's parent space —
            // the same space containerRect/textRect build in). A down
            // collapses the selection onto the caret — the anchor.
            s.dragging = true;
            moveCaret(n, s, caretFromPoint(n, s, ev.x, ev.y), false);
            resetBlink(s);
            n.markDirty(); // the label float / caret / colors follow focus
            return true;
        },
        .up => {
            s.dragging = false;
            return true;
        },
        .move => {
            // A held primary button drags the caret — drag-select (the
            // pointer is captured, so moves keep arriving off-bounds).
            if (!s.dragging) return false;
            moveCaret(n, s, caretFromPoint(n, s, ev.x, ev.y), true);
            return true;
        },
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
            // A commit discharges the composition: SDL's sequence is
            // text_input (commit) then text_editing("") (clear) on the
            // platforms that report preedit at all.
            s.comp.clearRetainingCapacity();
            s.comp_cursor = 0;
            setSentinel(&s.comp);
            // Reject (never truncate) input that would grow the text past
            // the documented cap — a paste/IME burst is applied whole or
            // not at all.
            if (s.buf.items.len + ev.text.len > ui.state.TextSignal.max_len) return true;
            // Insert AT the caret — an open selection is replaced first.
            const sel = selRange(s);
            if (sel.hi > sel.lo) deleteRange(s, sel.lo, sel.hi);
            const at = s.caret;
            s.buf.ensureUnusedCapacity(ev.text.len + 1) catch @panic("klaxon: out of memory");
            const tail = s.buf.items.len - at;
            std.mem.copyBackwards(u8, s.buf.items.ptr[at + ev.text.len ..][0..tail], s.buf.items[at..][0..tail]);
            @memcpy(s.buf.items.ptr[at..][0..ev.text.len], ev.text);
            s.buf.items.len += ev.text.len;
            s.caret = at + ev.text.len;
            s.sel_anchor = s.caret; // inserted text is not left selected
            setSentinel(&s.buf);
            resetBlink(s);
            applyEdit(n, s);
            return true;
        },
        .text_editing => {
            // SDL delivers the full composing string — replace, don't
            // append. Bounded by the same documented cap; an over-cap
            // preedit is dropped whole (never truncated mid-codepoint).
            s.comp.clearRetainingCapacity();
            if (ev.text.len <= ui.state.TextSignal.max_len) {
                s.comp.appendSlice(ev.text) catch @panic("klaxon: out of memory");
                // A fresh composition over an open selection commits the
                // deletion (the IME owns the range; the text changed).
                const sel = selRange(s);
                if (s.comp.items.len > 0 and sel.hi > sel.lo) {
                    deleteRange(s, sel.lo, sel.hi);
                    applyEdit(n, s);
                }
            }
            s.comp_cursor = ev.comp_start;
            setSentinel(&s.comp);
            n.markDirty(); // repaint only — comp is not a committed edit
            return true;
        },
        .key_down => switch (ev.key) {
            .backspace => {
                if (s.comp.items.len > 0) {
                    // An open composition eats the backspace (codepoint
                    // first); the platform re-sends text_editing anyway.
                    while (s.comp.items.len > 0) {
                        const last = s.comp.items[s.comp.items.len - 1];
                        s.comp.items.len -= 1;
                        if ((last & 0xC0) != 0x80) break;
                    }
                    s.comp_cursor = @intCast(s.comp.items.len);
                    setSentinel(&s.comp);
                    n.markDirty();
                    return true;
                }
                // An open selection eats the delete — upstream clears the
                // range, not the codepoint before the caret.
                const sel = selRange(s);
                if (sel.hi > sel.lo) {
                    deleteRange(s, sel.lo, sel.hi);
                    resetBlink(s);
                    applyEdit(n, s);
                    return true;
                }
                // Delete the codepoint ending AT the caret.
                if (s.caret == 0) return true;
                var start = s.caret;
                while (start > 0 and (s.buf.items[start - 1] & 0xC0) == 0x80) start -= 1;
                start -= 1;
                deleteRange(s, start, s.caret);
                resetBlink(s);
                applyEdit(n, s);
                return true;
            },
            .delete => {
                const sel = selRange(s);
                if (sel.hi > sel.lo) {
                    deleteRange(s, sel.lo, sel.hi);
                    resetBlink(s);
                    applyEdit(n, s);
                    return true;
                }
                // Forward delete: the codepoint STARTING at the caret.
                if (s.caret >= s.buf.items.len or s.comp.items.len > 0) return true;
                const l = std.unicode.utf8ByteSequenceLength(s.buf.items[s.caret]) catch 1;
                const end = @min(s.buf.items.len, s.caret + l);
                deleteRange(s, s.caret, end);
                resetBlink(s);
                applyEdit(n, s);
                return true;
            },
            // Logical caret motion — one codepoint per press (upstream
            // moves by grapheme cluster; a cluster-aware step needs the
            // paragraph's break iterator, tracked as a deviation). Under
            // RTL this moves logically, not visually. Shift extends the
            // selection; a plain arrow over an open selection collapses
            // onto the range's edge (upstream caret-collapse semantics).
            .left => {
                const sel = selRange(s);
                if (sel.hi > sel.lo and !ev.shift) {
                    moveCaret(n, s, sel.lo, false); // collapse to the start
                    return true;
                }
                var p = s.caret;
                while (p > 0) {
                    p -= 1;
                    if ((s.buf.items[p] & 0xC0) != 0x80) break;
                }
                moveCaret(n, s, p, ev.shift);
                return true;
            },
            .right => {
                const sel = selRange(s);
                if (sel.hi > sel.lo and !ev.shift) {
                    moveCaret(n, s, sel.hi, false); // collapse to the end
                    return true;
                }
                var p = s.caret;
                if (p < s.buf.items.len) {
                    p += 1;
                    while (p < s.buf.items.len and (s.buf.items[p] & 0xC0) == 0x80) p += 1;
                }
                moveCaret(n, s, p, ev.shift);
                return true;
            },
            .home => {
                moveCaret(n, s, 0, ev.shift); // single line: the run start
                return true;
            },
            .end => {
                moveCaret(n, s, s.buf.items.len, ev.shift); // the run end
                return true;
            },
            .enter => {
                if (s.on_submitted) |cb| cb.fn_ptr(cb.userdata);
                return true;
            },
            .escape => {
                s.comp.clearRetainingCapacity();
                s.comp_cursor = 0;
                setSentinel(&s.comp);
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
    // The replaced text may be shorter — pull the caret back onto a
    // codepoint boundary (upstream clamps the selection into the new text).
    s.caret = @min(s.caret, s.buf.items.len);
    while (s.caret > 0 and s.caret < s.buf.items.len and (s.buf.items[s.caret] & 0xC0) == 0x80) s.caret -= 1;
    s.sel_anchor = @min(s.sel_anchor, s.buf.items.len);
    while (s.sel_anchor > 0 and s.sel_anchor < s.buf.items.len and (s.buf.items[s.sel_anchor] & 0xC0) == 0x80) s.sel_anchor -= 1;
    n.markLayoutDirty(); // the measured width is content-driven
    n.markDirty();
    if (n.semantics) |sem| sem.value = s.text(); // a11y: the value follows external edits
}

fn textFieldDeinit(n: *Node) void {
    const s = stateOf(n);
    if (s.ticker) |t| {
        if (ui.anim.timeline()) |tl| tl.removeTicker(t); // the blink callback writes into state
    }
    if (ui.anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.label_channel)); // the channel writes into state
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = textFieldSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.free(s.label);
    n.allocator.free(s.placeholder);
    n.allocator.free(s.supporting);
    s.buf.deinit();
    s.comp.deinit();
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
    .wants_text_input = true,
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
        .comp = std.array_list.Managed(u8).init(allocator),
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
    s.caret = s.buf.items.len; // the caret starts at the end (Compose parity)
    s.sel_anchor = s.caret; // collapsed — nothing selected at birth
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
    s.caret = s.buf.items.len; // programmatic replace → caret at the end
    s.sel_anchor = s.caret;
    resetBlink(s);
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
    try std.testing.expectApproxEqAbs((iconBox(t) + h_padding - iconPad(t)) * 2 + tw, ic.measure(.{ .max_w = 2000, .max_h = 2000 }).w, 0.001);
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
    try std.testing.expectEqual(iconBox(theme_mod.light) + h_padding - iconPad(theme_mod.light), labelRect(ic).?.x);
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
    try std.testing.expectEqual(@as(f32, 260 - (iconBox(theme_mod.light) + h_padding - iconPad(theme_mod.light)) - lw), lr.x);
    const tr = textRect(b);
    try std.testing.expectEqual(iconBox(theme_mod.light) + h_padding - iconPad(theme_mod.light), tr.x); // the LTR anchor (paint mirrors it)
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

test "text_field: click places the caret; arrows/home/end move it; edits apply at the caret" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const b = try textField(std.testing.allocator, null, null, null, .{ .initial = "abc" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    const s = stateOf(b);
    try std.testing.expectEqual(@as(usize, 3), s.caret); // starts at the end
    // a press at the run's left edge → the nearest boundary (0 or 1)
    router.dispatchPointer(b, .{ .phase = .down, .x = 17, .y = 28 });
    try std.testing.expect(input.isFocused(b));
    try std.testing.expect(s.caret <= 1);
    // a press far past the run end → the end
    router.dispatchPointer(b, .{ .phase = .down, .x = 250, .y = 28 });
    try std.testing.expectEqual(@as(usize, 3), s.caret);
    // arrows move by codepoint; home/end jump to the edges
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .left });
    try std.testing.expectEqual(@as(usize, 2), s.caret);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .home });
    try std.testing.expectEqual(@as(usize, 0), s.caret);
    // typing inserts AT the caret
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "X" });
    try std.testing.expectEqualStrings("Xabc", text(b));
    try std.testing.expectEqual(@as(usize, 1), s.caret);
    // backspace deletes the codepoint BEFORE the caret
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .backspace });
    try std.testing.expectEqualStrings("abc", text(b));
    try std.testing.expectEqual(@as(usize, 0), s.caret);
    // backspace at 0 is a consumed no-op
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .backspace });
    try std.testing.expectEqualStrings("abc", text(b));
    // delete removes the codepoint AT the caret
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .delete });
    try std.testing.expectEqualStrings("bc", text(b));
    try std.testing.expectEqual(@as(usize, 0), s.caret);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .end });
    try std.testing.expectEqual(@as(usize, 2), s.caret);
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "!" });
    try std.testing.expectEqualStrings("bc!", text(b));
}

test "text_field: the caret steps by codepoint through multibyte text" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // "hé" = 3 bytes (é is 2) — boundaries at 0, 1, 3
    const b = try textField(std.testing.allocator, null, null, null, .{ .initial = "h\xC3\xA9" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    const s = stateOf(b);
    try std.testing.expectEqual(@as(usize, 3), s.caret);
    router.focus(b);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .left });
    try std.testing.expectEqual(@as(usize, 1), s.caret); // é's lead byte
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .left });
    try std.testing.expectEqual(@as(usize, 0), s.caret);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .right });
    try std.testing.expectEqual(@as(usize, 1), s.caret);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .right });
    try std.testing.expectEqual(@as(usize, 3), s.caret);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .right }); // clamped
    try std.testing.expectEqual(@as(usize, 3), s.caret);
    // insert in the middle of a multibyte buffer lands on the boundary
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .left });
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "i" });
    try std.testing.expectEqualStrings("hi\xC3\xA9", text(b));
    // backspace deletes the whole codepoint before the caret
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .backspace });
    try std.testing.expectEqualStrings("h\xC3\xA9", text(b));
    try std.testing.expectEqual(@as(usize, 1), s.caret);
    // an external set clamps the caret onto a boundary
    const sig_field = try textField(std.testing.allocator, null, null, null, .{ .initial = "long" });
    defer sig_field.deinit();
    const s2 = stateOf(sig_field);
    s2.caret = 4;
    setText(sig_field, "h\xC3\xA9");
    try std.testing.expectEqual(@as(usize, 3), s2.caret); // clamped to len
}

test "text_field: the caret blinks on the 500ms cadence and re-shows on edits" {
    var tl = ui.anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    ui.anim.setCurrent(&tl);
    defer ui.anim.setCurrent(null);
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const b = try textField(std.testing.allocator, null, null, null, .{ .initial = "x" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    const s = stateOf(b);
    router.focus(b);
    ensureTicker(b, s); // paint would do it; tests paint nothing
    try std.testing.expect(s.caret_on);
    tl.tick(0); // re-bases the epoch
    tl.tick(600); // one half-period past → off
    try std.testing.expect(!s.caret_on);
    tl.tick(1100); // second half-period → on
    try std.testing.expect(s.caret_on);
    // an edit re-shows the caret immediately, re-based at the next tick
    tl.tick(1600);
    try std.testing.expect(!s.caret_on);
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "y" });
    try std.testing.expect(s.caret_on); // reset on the edit event
    tl.tick(1700); // epoch re-based → still on within the half period
    try std.testing.expect(s.caret_on);
    tl.tick(2300); // a half-period after the re-base → off
    try std.testing.expect(!s.caret_on);
    // unfocused: the ticker stops keeping the loop awake
    router.focus(null);
    try std.testing.expect(!caretPendingCb(b));
    try std.testing.expect(!tl.hasTimedWork());
}

test "golden: the caret paints at its position mid-text, not just the end" {
    const t = theme_mod.light;
    _ = t;
    const b = try textField(std.testing.allocator, null, null, null, .{ .initial = "Hi", .theme = theme_mod.light });
    defer b.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.focus(b);
    b.layout(.{ .x = 20, .y = 12, .w = 260, .h = 56 });
    // caret between the two glyphs (left arrow from the end)
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .left });
    const s = stateOf(b);
    try std.testing.expectEqual(@as(usize, 1), s.caret);
    var r = try golden.Renderer.init(std.testing.allocator, 300, 80);
    defer r.deinit();
    r.paint(b, 0xFFFFFFFF); // caret ON (the blink's shown phase)
    var f_on = try r.readback(std.testing.allocator);
    defer f_on.deinit();
    s.caret_on = false; // the blink's hidden phase
    r.paint(b, 0xFFFFFFFF);
    var f_off = try r.readback(std.testing.allocator);
    defer f_off.deinit();
    // The caret is the ONLY difference between the two paints — count the
    // changed pixels in the mid-text band (a 1dp rect at a fractional x
    // anti-aliases across two columns, so pixel-exact color matching is
    // unreliable; the diff is the honest assertion).
    const m_all = ui.paint.measureText("Hi", 16, false);
    const m_h = ui.paint.measureText("H", 16, false);
    const tr = textRect(b);
    const mid_x = 20 + 16 + m_h.width; // the H|i boundary
    const y0: i32 = @intFromFloat(@ceil(tr.y));
    const y1: i32 = @intFromFloat(@floor(tr.y + m_all.height));
    var mid_diff: u32 = 0;
    var end_diff: u32 = 0;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x: i32 = @intFromFloat(@floor(mid_x - 1));
        while (x < @as(i32, @intFromFloat(@ceil(mid_x + 2)))) : (x += 1) {
            if (f_on.pixelAt(x, y) != f_off.pixelAt(x, y)) mid_diff += 1;
        }
        const end_x = 20 + 16 + m_all.width; // the run end (old static caret)
        x = @intFromFloat(@floor(end_x + 1));
        while (x < @as(i32, @intFromFloat(@ceil(end_x + 4)))) : (x += 1) {
            if (f_on.pixelAt(x, y) != f_off.pixelAt(x, y)) end_diff += 1;
        }
    }
    try std.testing.expect(mid_diff > 4); // the caret column diffs the line height
    try std.testing.expectEqual(@as(u32, 0), end_diff); // nothing at the old end position
}

test "text_field: shift extends the selection; drag-selects; delete replaces the range" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const b = try textField(std.testing.allocator, null, null, null, .{ .initial = "hello" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    const s = stateOf(b);
    router.focus(b);
    // shift+left selects backwards; the anchor stays at 5
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .left, .shift = true });
    try std.testing.expectEqual(@as(usize, 4), s.caret);
    try std.testing.expectEqual(@as(usize, 5), s.sel_anchor);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .left, .shift = true });
    try std.testing.expectEqual(@as(usize, 3), s.caret);
    // shift+home extends to the start
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .home, .shift = true });
    try std.testing.expectEqual(@as(usize, 0), s.caret);
    try std.testing.expectEqual(@as(usize, 5), s.sel_anchor); // whole text selected
    // typing replaces the selection (upstream: the range is deleted first)
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "yo" });
    try std.testing.expectEqualStrings("yo", text(b));
    try std.testing.expectEqual(@as(usize, 2), s.caret);
    try std.testing.expectEqual(@as(usize, 2), s.sel_anchor); // collapsed, not re-selected
    // a plain arrow over an open selection collapses onto the edge
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .home });
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .right, .shift = true });
    try std.testing.expectEqual(@as(usize, 1), s.caret); // [0,1) selected
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .right }); // no shift → collapse to hi
    try std.testing.expectEqual(@as(usize, 1), s.caret);
    try std.testing.expectEqual(@as(usize, 1), s.sel_anchor);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .right, .shift = true }); // [1,2)
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .backspace }); // deletes the range
    try std.testing.expectEqualStrings("y", text(b));
    try std.testing.expectEqual(@as(usize, 1), s.caret);
    // drag-select: down at the end, move back over the text
    router.dispatchPointer(b, .{ .phase = .down, .x = 250, .y = 28 });
    try std.testing.expectEqual(@as(usize, 1), s.caret); // end
    router.dispatchPointer(b, .{ .phase = .move, .x = 17, .y = 28 });
    try std.testing.expect(s.caret <= 1);
    try std.testing.expectEqual(@as(usize, 1), s.sel_anchor); // anchor froze at the press
    router.dispatchPointer(b, .{ .phase = .up, .x = 17, .y = 28 });
    try std.testing.expect(!s.dragging);
    // a plain click collapses
    router.dispatchPointer(b, .{ .phase = .down, .x = 250, .y = 28 });
    router.dispatchPointer(b, .{ .phase = .up, .x = 250, .y = 28 });
    try std.testing.expectEqual(s.caret, s.sel_anchor);
}

test "golden: the selection paints a primary@0.4 highlight over the range" {
    const b = try textField(std.testing.allocator, null, null, null, .{ .initial = "Hi", .theme = theme_mod.light });
    defer b.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.focus(b);
    b.layout(.{ .x = 20, .y = 12, .w = 260, .h = 56 });
    // select [0,1) — the "H"
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .home });
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .right, .shift = true });
    const s = stateOf(b);
    s.caret_on = false; // hold the caret off in both paints — the diff is pure highlight
    var r = try golden.Renderer.init(std.testing.allocator, 300, 80);
    defer r.deinit();
    r.paint(b, 0xFFFFFFFF); // selection painted
    var f_sel = try r.readback(std.testing.allocator);
    defer f_sel.deinit();
    s.sel_anchor = s.caret; // collapse → same frame without the highlight
    r.paint(b, 0xFFFFFFFF);
    var f_plain = try r.readback(std.testing.allocator);
    defer f_plain.deinit();
    // The highlight is the ONLY difference: it tints the H band's
    // background (glyph pixels are opaque ink and don't change).
    const m_h = ui.paint.measureText("H", 16, false);
    const m_all = ui.paint.measureText("Hi", 16, false);
    const tr = textRect(b);
    const y0: i32 = @intFromFloat(@ceil(tr.y));
    const y1: i32 = @intFromFloat(@floor(tr.y + m_all.height));
    var h_diff: u32 = 0;
    var i_diff: u32 = 0;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x: i32 = 37; // run starts at 36
        while (x < @as(i32, @intFromFloat(@floor(36 + m_h.width)))) : (x += 1) {
            if (f_sel.pixelAt(x, y) != f_plain.pixelAt(x, y)) h_diff += 1;
        }
        x = @intFromFloat(@ceil(36 + m_h.width));
        while (x < @as(i32, @intFromFloat(@floor(36 + m_all.width)))) : (x += 1) {
            if (f_sel.pixelAt(x, y) != f_plain.pixelAt(x, y)) i_diff += 1;
        }
    }
    try std.testing.expect(h_diff > 4); // the H band highlights
    try std.testing.expectEqual(@as(u32, 0), i_diff); // the i stays plain
}
