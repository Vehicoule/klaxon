// M3E time picker — the analog (dial) variant (Phase 2d.4 PR #33) and the
// text-input variant, ported from Compose material3 TimePicker.kt +
// TimePickerTokens.kt + TimeInputTokens.kt (/tmp/m3compose2/d3-TimePicker.kt,
// d3-TimePickerTokens.kt, .ref/material3/TimePicker.kt,
// .ref/material3/tokens/TimeInputTokens.kt) + the M3E spec
// (m3.material.io/components/time-pickers) + the m3e-canvas visual reference.
//
// Tokens (TimePickerTokens):
//   - container: SurfaceContainerHigh, CornerExtraLarge (28dp), 360dp wide
//   - header (a centered row): the hour plate + the ":" separator + the
//     minute plate + the AM/PM period toggle (12h only)
//     - plates: 96x80, CornerSmall (8dp); the ACTIVE plate (the dial's mode):
//       PrimaryContainer fill + OnPrimaryContainer label + a 2dp Primary
//       border; the inactive plate: SurfaceContainerHighest + OnSurface
//     - labels: DisplayLarge, zero-padded 2 digits
//     - separator: 24dp wide, DisplayLarge, OnSurface
//     - period toggle: 52x80, CornerSmall, a 1dp Outline border + a 1dp
//       Outline divider between the halves; the selected half:
//       TertiaryContainer + OnTertiaryContainer; unselected: transparent +
//       OnSurfaceVariant; labels TitleMedium
//   - dial: 256dp circle, SurfaceContainerHighest, CornerFull
//     - labels on a 101dp ring (OuterCircleToSizeRatio = 101/256), 48dp
//       cells, BodyLarge; hour screen: 12, 1..11 (12 at the top); minute
//       screen: 00, 05..55 (every 5th minute)
//     - the 24h hour screen is a dual-ring dial: 00..11 on the outer ring
//       (101dp) + 12..23 on the inner circle (69dp, InnerCircleToSizeRatio);
//       the tap's radius picks the ring (MaxDistance = 74dp: >= 74 → the
//       outer 0..11, closer → the inner 12..23)
//     - the selector: a 48dp Primary circle (CornerFull) at the selected
//       position (on the selected hour's ring) + the selected label OnPrimary
//       (drawn on top of the knob); the track: a 2dp Primary line from the
//       center to the knob's near edge; the center: an 8dp Primary circle
//   - footer: Cancel / OK text buttons (same as the date picker)
//
// State: `time` is a two-way Signal(i32) of minutes since midnight (clamped
// to 0..1439). Tapping the hour/minute plate switches the dial's mode; tapping
// the dial (or dragging) selects by angle (hours snap to the nearest hour,
// minutes to the nearest minute; in 24h the tap's radius picks the ring);
// tapping AM/PM flips the period (12h). OK fires on_select, Cancel on_cancel.
//
//   - autoSwitchToMinute (opts.auto_switch_to_minute, default on): releasing
//     a dial gesture in the hour mode advances to the minute dial.
//
// The INPUT variant (opts.mode = .input, upstream's TimeInput composable —
// TimeInputImpl + TimePickerTextField + TimeInputTransformation in
// TimePicker.kt): a centered row of the hour field + the ":" separator +
// the minute field + the AM/PM column (12h), with the Hour/Minute or the
// error supporting text under each field. Only the SELECTED field is an
// editable box (PrimaryContainer + a 2dp Outline border while focused,
// SurfaceContainerHighest + a 1dp Outline border when not); the other is a
// borderless SurfaceContainerHighest plate — tapping it selects the field
// (upstream swaps a TimeSelector surface for the focused BasicTextField).
// Tokens (TimeInputTokens): fields 96x72 CornerSmall, DisplayMedium text,
// the separator 24x72 DisplayMedium OnSurface (-4dp nudge), the period toggle 52x72,
// supporting text BodySmall OnSurfaceVariant / Error, 7dp top pad, a 2-line
// box (upstream minLines=2). The editing core is text_edit.Edit (real
// caret/selection/clipboard) — the fields cap at 2 digits and reject
// non-digit input wholesale (upstream's transformInput), a valid typed
// value updates `time` immediately, an out-of-range value paints the error
// state without touching the signal (upstream hourInput/minuteInput).
// Upstream field navigation: a tap selects the other field, a complete
// valid hour auto-advances to the minute field (2 typed digits, or a lone
// 2..9 digit in 12h — isTypedTwoDigits/is12HourAutoAdvanceDigit), a digit
// at the end of a complete valid hour lands in the minute field instead
// (shouldSwitchFocusToMinute), a lone digit typed into a full field rolls
// the buffer over to just that digit (isReplacingTwoDigits), Enter is
// ImeAction.Next (hour → minute) / ImeAction.Done (minute → blur), and the
// AM/PM flip is gated on a valid hour input.
//
// opts.mode_toggle: an icon-button affordance at the footer's leading edge
// that flips the variant at runtime — upstream's caller-supplied `toggle`
// slot (a keyboard glyph in dial mode, a clock glyph in input mode).
// Default: shown in input mode only.
//
// Remaining deviations (documented, fixed later):
//   - The input variant ports the CLASSIC TimeInput (shapes == null): the
//     vibrant/uncontained styles (100x120 CornerFull fields, the side
//     control column) are not.
//   - The supporting texts are hand-wrapped fixed strings; no real text
//     wrap, and no liveRegion announce on the error text.
//   - Upstream suppresses the auto-advance while an a11y service is
//     enabled (a11yServicesEnabled); we have no equivalent query, so the
//     advance always runs.
//   - Tab moves between the fields only in tests — the host maps Tab to
//     the global focus traversal, so in-app field navigation is tap /
//     auto-advance / Enter (the AM/PM column is pointer-only, as in the
//     dial variant).
//   - No per-label hover on the dial; no keyboard navigation on the dial.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const i18n_mod = @import("../ui/i18n.zig");
const text_edit = @import("text_edit.zig");
const icon_w = @import("icon.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

/// The picker's variant: the analog dial (default) or the text-input
/// fields (upstream's TimeInput).
pub const PickerMode = enum { dial, input };

pub const TimePickerOptions = struct {
    theme: Theme = theme_mod.light,
    /// The panel width.
    width: f32 = 360,
    /// 24-hour mode: no AM/PM toggle, the hour plate shows 00..23.
    is_24h: bool = false,
    /// Compose autoSwitchToMinute (default true): after an hour selection
    /// (dial tap release or drag end) the dial advances to the minute mode.
    auto_switch_to_minute: bool = true,
    /// The variant: .dial (default, the clock face) or .input (upstream
    /// TimeInput — the hour/minute text fields).
    mode: PickerMode = .dial,
    /// The dial⇄keyboard mode toggle at the footer's leading edge —
    /// upstream's caller-supplied `toggle` slot. null = shown in input
    /// mode only (an explicit bool pins it on/off for both variants).
    mode_toggle: ?bool = null,
};

pub const DialMode = enum { hour, minute };

/// M3E measurement tokens (TimePickerTokens + the private vals).
const container_corner: f32 = 28; // CornerExtraLarge
const plate_w: f32 = 96; // TimeSelectorContainerWidth
const plate_h: f32 = 80; // TimeSelectorContainerHeight
const plate_corner: f32 = 8; // CornerSmall
const plate_border: f32 = 2; // the selected plate's Primary border
const sep_w: f32 = 24; // DisplaySeparatorWidth
const period_w: f32 = 52; // PeriodSelectorVerticalContainerWidth
const period_h: f32 = 80; // PeriodSelectorVerticalContainerHeight
const period_gap: f32 = 4; // PeriodTogglePaddingSmall
const dial_size: f32 = 256; // ClockDialContainerSize
const label_ring: f32 = 101; // OuterCircleToSizeRatio × 256
const inner_label_ring: f32 = 69; // InnerCircleToSizeRatio × 256 (the 24h dial's inner circle)
const max_tap_dist: f32 = 74; // MaxDistance (the 24h ring threshold)
const knob_d: f32 = 48; // ClockDialSelectorHandleContainerSize
const track_w: f32 = 2; // ClockDialSelectorTrackContainerWidth
const center_d: f32 = 8; // ClockDialSelectorCenterContainerSize
const header_top: f32 = 16;
const header_h: f32 = 80; // the plates' height
const display_gap: f32 = 36; // ClockDisplayBottomMargin
const face_gap: f32 = 24; // ClockFaceBottomMargin
const footer_h: f32 = 40;
const footer_pad_bottom: f32 = 12;
const footer_gap: f32 = 8;
const footer_pad_x: f32 = 12; // the text button's horizontal padding

/// Input-variant tokens (TimeInputTokens + the private vals): the fields
/// are 96x72 (TimeFieldContainerWidth/Height) with a 24dp separator
/// (DisplaySeparatorWidth) and a 52x72 period toggle
/// (PeriodSelectorContainerWidth/Height) — the same widths/gaps as the
/// dial's header row, so headerRowX centers both layouts identically.
const field_w: f32 = 96; // TimeFieldContainerWidth
const field_h: f32 = 72; // TimeFieldContainerHeight
const input_period_h: f32 = 72; // PeriodSelectorContainerHeight
const support_top_pad: f32 = 7; // SupportLabelTop
const sep_offset_y: f32 = -4; // upstream DisplaySeparator's -4dp nudge
const toggle_hit: f32 = 48; // MinimumInteractiveSize (the mode toggle's tap target)
const toggle_box: f32 = 40; // the icon button's visual box
const toggle_icon: f32 = 24; // the glyph size inside it
const max_field_chars: usize = 2; // upstream's maxTextLength = 2

/// Derived layout metrics.
const dial_y_off: f32 = header_top + header_h + display_gap; // 132
const footer_y_off: f32 = dial_y_off + dial_size + face_gap; // 412
const total_h: f32 = footer_y_off + footer_h + footer_pad_bottom; // 464
/// The header row's width (12h: plates + separator + period toggle).
const header_row_w_12h: f32 = plate_w + sep_w + plate_w + period_gap + period_w; // 272

/// The input variant's supporting-text box: upstream minLines = 2 of
/// BodySmall (TimeFieldSupportingTextFont).
fn supportH(t: Theme) f32 {
    return 2 * t.type_scale.body_small.line_height;
}

/// The input variant's footer row offset + total height.
fn inputFooterYOff(t: Theme) f32 {
    return header_top + field_h + support_top_pad + supportH(t) + face_gap;
}

fn inputTotalH(t: Theme) f32 {
    return inputFooterYOff(t) + footer_h + footer_pad_bottom;
}

/// The hour screen values (12 at the top, then 1..11 clockwise).
const hour_values = [_]i32{ 12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

// --- time math (minutes since midnight) ---

fn clampedTime(t: i32) i32 {
    return std.math.clamp(t, 0, 1439);
}

fn hour24Of(t: i32) i32 {
    return @divTrunc(clampedTime(t), 60);
}

fn minuteOf(t: i32) i32 {
    return @mod(clampedTime(t), 60);
}

fn hour12Of(t: i32) i32 {
    const h = @mod(hour24Of(t), 12);
    return if (h == 0) 12 else h;
}

fn isPm(t: i32) bool {
    return hour24Of(t) >= 12;
}

/// The dial's value for the current mode (hour12 in 12h hour mode, 0..23 in
/// 24h hour mode, minute in minute mode).
fn dialValue(t: i32, mode: DialMode, is_24h: bool) i32 {
    if (mode == .hour) return if (is_24h) hour24Of(t) else hour12Of(t);
    return minuteOf(t);
}

/// The angle (degrees, standard math: -90 at the top, clockwise) of a dial
/// value. 12h hours are 1..12; 24h hours are 0..23 (the position's 12h base).
fn valueAngle(value: i32, mode: DialMode, is_24h: bool) f32 {
    if (mode == .hour) {
        const base12: i32 = if (is_24h) @mod(value, 12) else value;
        const v12: i32 = if (base12 == 0) 12 else base12;
        var i: usize = 0;
        while (i < 12) : (i += 1) {
            if (hour_values[i] == v12) break;
        }
        return @as(f32, @floatFromInt(i)) * 30 - 90;
    }
    return @as(f32, @floatFromInt(value)) * 6 - 90;
}

/// The ring radius of a dial value's selector knob (the 24h dial's 12..23
/// hours sit on the inner circle).
fn selectorRing(value: i32, mode: DialMode, is_24h: bool) f32 {
    if (mode == .hour and is_24h and value >= 12) return inner_label_ring;
    return label_ring;
}

/// The dial value at a pointer position (the nearest hour / minute). In 24h
/// hour mode the tap's radius picks the ring: >= MaxDistance → the outer
/// circle (0..11), closer → the inner circle (12..23).
fn valueAtAngle(cx: f32, cy: f32, x: f32, y: f32, mode: DialMode, is_24h: bool) i32 {
    var deg = std.math.atan2(y - cy, x - cx) * 180 / std.math.pi + 90;
    deg = @mod(deg, 360);
    if (mode == .hour) {
        const i = @as(usize, @intFromFloat(@round(deg / 30))) % 12;
        if (is_24h) {
            const base = @mod(hour_values[i], 12); // 0..11
            const dist = std.math.hypot(x - cx, y - cy);
            return if (dist >= max_tap_dist) base else base + 12;
        }
        return hour_values[i];
    }
    return @mod(@as(i32, @intFromFloat(@round(deg / 6))), 60);
}

/// Apply a dial selection to the time signal (mode-dependent).
fn applyDialValue(s: *TpState, value: i32) void {
    const t = clampedTime(s.time.peek());
    if (s.mode == .hour) {
        if (s.opts.is_24h) {
            s.time.set(std.math.clamp(value, 0, 23) * 60 + minuteOf(t));
        } else {
            const hour12 = std.math.clamp(value, 1, 12);
            const h24: i32 = if (isPm(t)) @mod(hour12, 12) + 12 else @mod(hour12, 12);
            s.time.set(h24 * 60 + minuteOf(t));
        }
    } else {
        s.time.set(hour24Of(t) * 60 + std.math.clamp(value, 0, 59));
    }
}

// --- input-variant state (upstream TimeInputImpl + TimeInputTransformation) ---

/// The field a DialMode selects.
fn editOf(s: *TpState, which: DialMode) *text_edit.Edit {
    return if (which == .hour) &s.hour_edit else &s.minute_edit;
}

/// Upstream state.isPm — the COMMITTED hour's period (always valid).
fn committedPm(s: *TpState) bool {
    return isPm(clampedTime(s.time.peek()));
}

/// Upstream TimePickerState.isValidHour — on the hour-24 scale against
/// `pm` (12h inputs are only valid inside the committed period's half).
fn isValidHourIn(s: *TpState, target: i32, pm: bool) bool {
    if (s.opts.is_24h) return target >= 0 and target <= 23;
    return if (pm) (target >= 12 and target <= 23) else (target >= 0 and target <= 11);
}

fn isValidHour(s: *TpState, target: i32) bool {
    return isValidHourIn(s, target, committedPm(s));
}

/// Upstream isHourInputValid / isMinuteInputValid.
fn isHourInputValid(s: *TpState) bool {
    return isValidHour(s, s.hour_input);
}
fn isMinuteInputValid(s: *TpState) bool {
    return s.minute_input >= 0 and s.minute_input <= 59;
}

/// The field's error flag — upstream `!isValidInput` (drives the error
/// container/border/text + the supporting-text swap).
fn fieldInvalid(s: *TpState, which: DialMode) bool {
    return if (which == .hour) !isHourInputValid(s) else !isMinuteInputValid(s);
}

/// Upstream's transform target: the typed hour (0..99) converted to the
/// hour-24 scale via the committed period (12 → 0 AM / 12 PM, other +12 PM).
fn hourTarget(s: *TpState, typed: i32, pm: bool) i32 {
    if (s.opts.is_24h) return typed;
    if (typed == 12) return if (pm) 12 else 0;
    if (pm) return typed + 12;
    return typed;
}

/// Upstream hourForDisplay: hour % 24 in 24h; 12 for :00/:12, hour-12 in
/// PM, else hour in 12h.
fn hourForDisplay(s: *TpState) i32 {
    const t = s.time.peek();
    if (s.opts.is_24h) return @mod(hour24Of(t), 24);
    return hour12Of(t);
}

/// The canonical field text — upstream hourTextValue()/minuteTextValue():
/// the valid display value when the input is valid, the RAW input
/// otherwise (toLocalString(minDigits = 2)). Also the unselected plate's
/// text (upstream TimeSelector's value.toLocalString(minDigits = 2) —
/// for the minute it shows minuteInput directly, which is the same
/// expression: valid minuteInput == minute).
fn canonicalFieldText(s: *TpState, which: DialMode, buf: *[8]u8) [:0]const u8 {
    const v: i32 = if (which == .hour)
        (if (isHourInputValid(s)) hourForDisplay(s) else s.hour_input)
    else
        (if (isMinuteInputValid(s)) minuteOf(s.time.peek()) else s.minute_input);
    return std.fmt.bufPrintSentinel(buf, "{d:0>2}", .{@as(u32, @intCast(@max(0, v)))}, 0) catch "?";
}

/// A pre-edit buffer snapshot — upstream revertAllChanges() restores the
/// whole buffer + selection when a change is structurally rejected.
const EditSnap = struct {
    len: usize = 0, // the pre-edit buffer length
    sel_len: usize = 0, // the pre-edit selection length
    caret: usize = 0,
    anchor: usize = 0,
    text: [8]u8 = std.mem.zeroes([8]u8), // the field never exceeds 2 chars — 8 is ample
    tlen: usize = 0,
};

fn snapEdit(ed: *const text_edit.Edit) EditSnap {
    var sn: EditSnap = .{};
    const items = ed.buf.items;
    const sel = ed.selRange();
    sn.tlen = @min(items.len, sn.text.len);
    @memcpy(sn.text[0..sn.tlen], items[0..sn.tlen]);
    sn.len = items.len;
    sn.sel_len = sel.hi - sel.lo;
    sn.caret = ed.caret;
    sn.anchor = ed.sel_anchor;
    return sn;
}

/// revertAllChanges: restore the pre-edit buffer + selection wholesale.
fn revertEdit(ed: *text_edit.Edit, sn: *const EditSnap) void {
    ed.buf.clearRetainingCapacity();
    ed.buf.appendSlice(sn.text[0..sn.tlen]) catch @panic("klaxon: out of memory");
    text_edit.setSentinel(&ed.buf);
    ed.caret = sn.caret;
    ed.sel_anchor = sn.anchor;
    ed.clampOffsets();
}

/// A programmatic replace (the sync's canonical text / the variant
/// reset) — upstream `hourState.edit { replace(0, length, text);
/// placeCursorBeforeCharAt(0) }`: the caret lands at offset 0.
fn setFieldText(ed: *text_edit.Edit, str: [:0]const u8) void {
    ed.buf.clearRetainingCapacity();
    ed.buf.appendSlice(str) catch @panic("klaxon: out of memory");
    text_edit.setSentinel(&ed.buf);
    ed.caret = 0;
    ed.sel_anchor = 0;
    ed.comp.clearRetainingCapacity();
    text_edit.setSentinel(&ed.comp);
}

/// (Re)build the input fields from the committed time — the constructor's
/// `rememberTextFieldState(textValue(), initialSelection = TextRange.Zero)`
/// and the dial→input toggle's fresh composition.
fn resetInputFields(n: *Node) void {
    const s = stateOf(n);
    const t = clampedTime(s.time.peek());
    s.hour_input = hour24Of(t);
    s.minute_input = minuteOf(t);
    var hb: [8]u8 = undefined;
    var mb: [8]u8 = undefined;
    setFieldText(&s.hour_edit, canonicalFieldText(s, .hour, &hb));
    setFieldText(&s.minute_edit, canonicalFieldText(s, .minute, &mb));
    s.hour_override = true;
    s.minute_override = true;
    s.last_hour = hour24Of(t);
    s.last_minute = minuteOf(t);
}

/// The a11y value of a field child: a decimal snapshot of the LIVE text
/// (stable — the edit buffer may reallocate on the next edit, so the
/// semantics descriptor borrows this copy, never the buffer).
fn fieldSemValue(n: *Node, which: DialMode) [:0]const u8 {
    const s = stateOf(n);
    const i: usize = if (which == .hour) 0 else 1;
    const txt = editOf(s, which).text();
    const len = @min(txt.len, s.field_sem_bufs[i].len - 1);
    @memcpy(s.field_sem_bufs[i][0..len], txt[0..len]);
    s.field_sem_bufs[i][len] = 0;
    s.field_sem_lens[i] = len;
    return s.field_sem_bufs[i][0..len :0];
}

/// Upstream TimeInputTransformation.transformInput — runs after EVERY
/// buffer change (the Edit's apply_edit hook). `prev` is the pre-edit
/// snapshot; structural rejects (non-digit, > 2 chars, value > 99 —
/// upstream revertAllChanges + errorHandler.onError) restore it.
fn transformAfterEdit(n: *Node, which: DialMode) void {
    const s = stateOf(n);
    const prev = &s.snap;
    const ed = editOf(s, which);
    const items = ed.buf.items;
    const pm = committedPm(s);
    const t_now = clampedTime(s.time.peek());
    // The all-digit + length + MaxValueForTextField (99) gates.
    var digits = true;
    var v: i32 = 0;
    for (items) |c| {
        if (c < '0' or c > '9') {
            digits = false;
            break;
        }
        v = v * 10 + @as(i32, c - '0');
    }
    if (items.len > 2 or !digits or v > 99) {
        revertEdit(ed, prev);
        refreshSemanticsChildren(n);
        n.markDirty();
        return;
    }
    // hasInsertedText: the change grew the buffer past the deleted range.
    const inserted = items.len -| (prev.len -| prev.sel_len) > 0;
    if (which == .hour) {
        if (items.len == 0) {
            // An emptied hour field inputs the period's zero (12h: 12 AM/PM
            // — upstream target = isPm && !is24hour ? 12 : 0) and COMMITS it.
            const target: i32 = if (pm and !s.opts.is_24h) 12 else 0;
            if (hour24Of(t_now) != target) s.hour_override = false;
            s.hour_input = target;
            if (isValidHourIn(s, target, pm)) s.time.set(target * 60 + minuteOf(t_now));
        } else {
            const target = hourTarget(s, v, pm);
            if (isValidHourIn(s, target, pm) and hour24Of(t_now) != target) s.hour_override = false;
            s.hour_input = target;
            if (isValidHourIn(s, target, pm)) s.time.set(target * 60 + minuteOf(t_now));
            // shouldAutoAdvance: a complete valid hour jumps to the minute
            // field (upstream: 2 typed digits, or a lone 2..9 digit in 12h —
            // no 2-digit hour can start with those).
            if (isValidHourIn(s, target, pm) and
                (items.len == 2 or (inserted and !s.opts.is_24h and v >= 2 and v <= 9)))
            {
                s.mode = .minute;
                clearComp(&s.hour_edit);
            }
        }
    } else {
        if (items.len == 0) {
            // An emptied minute field inputs — and commits — :00.
            if (minuteOf(t_now) != 0) s.minute_override = false;
            s.minute_input = 0;
            s.time.set(hour24Of(t_now) * 60);
        } else {
            if (v <= 59 and minuteOf(t_now) != v) s.minute_override = false;
            s.minute_input = v;
            if (v <= 59) s.time.set(hour24Of(t_now) * 60 + v);
        }
    }
    refreshSemanticsChildren(n);
    ui.semantics.notifyControlChanged(n);
    n.markDirty();
}

/// Drop an open IME composition (field switches lose the preedit).
fn clearComp(ed: *text_edit.Edit) void {
    ed.comp.clearRetainingCapacity();
    ed.comp_cursor = 0;
    text_edit.setSentinel(&ed.comp);
}

/// The widget's applyEdit adapted to text_edit's callback signature —
/// the transform runs on the field the routed event went to.
fn applyEditNode(n: *Node) void {
    const s = stateOf(n);
    transformAfterEdit(n, s.editing);
}

/// Upstream shouldSwitchFocusToMinute: a digit typed while the selection
/// END sits at the end of a complete VALID hour text moves the selection
/// to the minute field — the digit then lands in the minute field
/// instead.
fn shouldSwitchFocusToMinute(s: *TpState, ev: input.KeyEvent) bool {
    if (ev.kind != .text_input or s.mode != .hour) return false;
    if (!(ev.text.len == 1 and ev.text[0] >= '0' and ev.text[0] <= '9')) return false;
    const ed = &s.hour_edit;
    if (!(ed.selRange().hi == 2 and ed.buf.items.len == 2)) return false;
    // upstream checks the hour text int directly: 0..23 / 1..12.
    var v: i32 = 0;
    for (ed.buf.items) |c| {
        if (c < '0' or c > '9') return false;
        v = v * 10 + @as(i32, c - '0');
    }
    const ok = if (s.opts.is_24h) (v >= 0 and v <= 23) else (v >= 1 and v <= 12);
    return ok and isHourInputValid(s);
}

// --- widget state ---

const Zone = union(enum) {
    none,
    hour_plate,
    minute_plate,
    hour_field,
    minute_field,
    am,
    pm,
    dial,
    mode_toggle,
    cancel,
    ok,
};

const TpState = struct {
    opts: TimePickerOptions,
    time: *ui.state.Signal(i32),
    on_select: ?ui.state.Callback,
    on_cancel: ?ui.state.Callback,
    /// The dial's mode — and upstream's `selection` (the active field) in
    /// the input variant.
    mode: DialMode = .hour,
    /// The live variant (opts.mode seeds it; the mode toggle flips it).
    variant: PickerMode = .dial,
    hover: Zone = .none,
    pressed: Zone = .none,
    dragging: bool = false, // the dial owns the pointer
    down_x: f32 = 0,
    down_y: f32 = 0,
    /// The input variant's fields — upstream hourState/minuteState. Both
    /// are live text_edit.Editing cores regardless of the variant (the
    /// mode toggle can switch at runtime); only the SELECTED one edits.
    hour_edit: text_edit.Edit = undefined,
    minute_edit: text_edit.Edit = undefined,
    /// The fields' parsed inputs — upstream hourInput (the hour24-scale
    /// target, invalid while out of range) and minuteInput (0..59).
    hour_input: i32 = 0,
    minute_input: i32 = 0,
    /// Upstream userOverride per field: true → an external signal change
    /// rewrites the field text (canonical "HH"/"MM", caret at 0); a user
    /// edit that changes the time clears it for that one sync so the typed
    /// text isn't clobbered.
    hour_override: bool = true,
    minute_override: bool = true,
    /// The components at the last sync — the sync rewrites only the field
    /// whose component actually changed (upstream's per-part
    /// LaunchedEffect on state.hour/state.minute).
    last_hour: i32 = -1,
    last_minute: i32 = -1,
    /// The field the routed key event went to (applyEditNode's target) +
    /// its pre-edit snapshot (revertAllChanges restores it wholesale).
    editing: DialMode = .hour,
    snap: EditSnap = .{},
    /// The field a text drag belongs to (the Edit owns the drag flag).
    drag_field: ?DialMode = null,
    /// The a11y value (the formatted time) — Phase 2c.
    value_buf: [24]u8 = std.mem.zeroes([24]u8),
    value_len: usize = 0,
    /// The virtual a11y children (the input variant's fields + the AM/PM
    /// halves + the mode toggle) — borrowed by the semantics descriptor;
    /// values mutate in place like segmented_button's.
    sem_children: [5]ui.semantics.Semantics = undefined,
    /// The fields' borrowed a11y value strings (stable — never the edit
    /// buffers, which reallocate on edits).
    field_sem_bufs: [2][8]u8 = .{ std.mem.zeroes([8]u8), std.mem.zeroes([8]u8) },
    field_sem_lens: [2]usize = .{ 0, 0 },
    /// The installed i18n (null when the app runs without one) — the
    /// widget subscribes to locale_sig: a locale switch repaints the
    /// tr()-routed labels and rebuilds the a11y tree's strings.
    i18n: ?*i18n_mod.I18n = null,
};

fn stateOf(n: *Node) *TpState {
    return @ptrCast(@alignCast(n.state.?));
}

/// The dial's mode (hour/minute) — tests + the app.
pub fn dialMode(n: *Node) DialMode {
    return stateOf(n).mode;
}

/// The current time (minutes since midnight, clamped) — tests + the app.
pub fn timeMinutes(n: *Node) i32 {
    return clampedTime(stateOf(n).time.peek());
}

/// The dial's rect — tests + the app.
pub fn dialRectOf(n: *Node) Rect {
    return dialRect(n.bounds);
}

// --- geometry ---

fn headerRowX(b: Rect, is_24h: bool) f32 {
    const row_w: f32 = if (is_24h) plate_w + sep_w + plate_w else header_row_w_12h;
    return b.x + (b.w - row_w) / 2;
}

fn plateRect(b: Rect, which: DialMode, is_24h: bool) Rect {
    const row_x = headerRowX(b, is_24h);
    const x = if (which == .hour) row_x else row_x + plate_w + sep_w;
    return .{ .x = x, .y = b.y + header_top, .w = plate_w, .h = plate_h };
}

fn separatorRect(b: Rect, is_24h: bool) Rect {
    const row_x = headerRowX(b, is_24h);
    return .{ .x = row_x + plate_w, .y = b.y + header_top, .w = sep_w, .h = plate_h };
}

fn periodRect(b: Rect) Rect {
    const row_x = headerRowX(b, false);
    return .{ .x = row_x + 2 * plate_w + sep_w + period_gap, .y = b.y + header_top, .w = period_w, .h = period_h };
}

fn dialRect(b: Rect) Rect {
    return .{ .x = b.x + (b.w - dial_size) / 2, .y = b.y + dial_y_off, .w = dial_size, .h = dial_size };
}

// --- input-variant geometry ---

/// An input-variant field's box (96x72, at the header row's y) — the
/// hour field is the row's first slot, the minute field its third (the
/// separator is the second).
fn inputFieldRect(b: Rect, which: DialMode, is_24h: bool) Rect {
    const row_x = headerRowX(b, is_24h);
    const x = if (which == .hour) row_x else row_x + field_w + sep_w;
    return .{ .x = x, .y = b.y + header_top, .w = field_w, .h = field_h };
}

fn inputSeparatorRect(b: Rect, is_24h: bool) Rect {
    const row_x = headerRowX(b, is_24h);
    return .{ .x = row_x + field_w, .y = b.y + header_top, .w = sep_w, .h = field_h };
}

/// The input variant's period toggle: 52x72 (PeriodSelectorContainer) at
/// the row's end — narrower vertically than the dial's 80dp toggle.
fn inputPeriodRect(b: Rect) Rect {
    const row_x = headerRowX(b, false);
    return .{ .x = row_x + 2 * field_w + sep_w + period_gap, .y = b.y + header_top, .w = period_w, .h = input_period_h };
}

/// A field's supporting-text line box (under its 96dp field, 16dp tall
/// each of the two upstream minLines).
fn supportRect(b: Rect, which: DialMode, is_24h: bool, line: usize, t: Theme) Rect {
    const f = inputFieldRect(b, which, is_24h);
    return .{ .x = f.x, .y = f.y + f.h + support_top_pad + @as(f32, @floatFromInt(line)) * t.type_scale.body_small.line_height, .w = f.w, .h = t.type_scale.body_small.line_height };
}

/// The footer row's y offset — the dial pushes it below the 256dp face;
/// the input variant sits it right under the fields + supporting text.
fn footerYOff(n: *Node) f32 {
    const s = stateOf(n);
    return if (s.variant == .input) inputFooterYOff(s.opts.theme) else footer_y_off;
}

/// The mode toggle's tap target at the footer's leading edge (48dp,
/// MinimumInteractiveSize; the 40dp icon button is centered inside).
fn modeToggleRect(n: *Node) Rect {
    const b = n.bounds;
    return .{ .x = b.x + footer_pad_x, .y = b.y + footerYOff(n) + (footer_h - toggle_hit) / 2, .w = toggle_hit, .h = toggle_hit };
}

/// Whether the dial⇄keyboard affordance is on — explicit opt, else input
/// mode only (upstream: the dialog/vibrant variants supply the toggle).
fn showModeToggle(s: *const TpState) bool {
    return s.opts.mode_toggle orelse (s.variant == .input);
}

const FooterRects = struct { cancel: Rect, ok: Rect };

fn footerRects(n: *Node) FooterRects {
    const s = stateOf(n);
    const ls = s.opts.theme.type_scale.label_large;
    const bold = ls.weight >= 500;
    const ok_m = ui.paint.measureTextLen(i18n_mod.tr("OK"), ls.size, bold);
    const cancel_m = ui.paint.measureTextLen(i18n_mod.tr("Cancel"), ls.size, bold);
    const ok_w = ok_m.width + 2 * footer_pad_x;
    const cancel_w = cancel_m.width + 2 * footer_pad_x;
    const right = n.bounds.x + n.bounds.w - footer_pad_bottom;
    const y = n.bounds.y + footerYOff(n);
    return .{
        .cancel = .{ .x = right - ok_w - footer_gap - cancel_w, .y = y, .w = cancel_w, .h = footer_h },
        .ok = .{ .x = right - ok_w, .y = y, .w = ok_w, .h = footer_h },
    };
}

/// The interactive zone at (x, y) — window coordinates.
fn zoneAt(n: *Node, x: f32, y: f32) Zone {
    const s = stateOf(n);
    const b = n.bounds;
    const fr = footerRects(n);
    if (fr.cancel.contains(x, y)) return .cancel;
    if (fr.ok.contains(x, y)) return .ok;
    if (showModeToggle(s) and modeToggleRect(n).contains(x, y)) return .mode_toggle;
    if (s.variant == .input) {
        if (inputFieldRect(b, .hour, s.opts.is_24h).contains(x, y)) return .hour_field;
        if (inputFieldRect(b, .minute, s.opts.is_24h).contains(x, y)) return .minute_field;
        if (!s.opts.is_24h) {
            const pr = inputPeriodRect(b);
            if (pr.contains(x, y)) return if (y < pr.y + pr.h / 2) .am else .pm;
        }
        return .none;
    }
    if (plateRect(b, .hour, s.opts.is_24h).contains(x, y)) return .hour_plate;
    if (plateRect(b, .minute, s.opts.is_24h).contains(x, y)) return .minute_plate;
    if (!s.opts.is_24h) {
        const pr = periodRect(b);
        if (pr.contains(x, y)) return if (y < pr.y + pr.h / 2) .am else .pm;
    }
    const d = dialRect(b);
    if (d.contains(x, y)) {
        const cx = d.x + d.w / 2;
        const cy = d.y + d.h / 2;
        const dx = x - cx;
        const dy = y - cy;
        if (dx * dx + dy * dy <= (d.w / 2) * (d.w / 2)) return .dial;
    }
    return .none;
}

// --- measure / layout / paint ---

fn tpMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const h = if (s.variant == .input) inputTotalH(s.opts.theme) else total_h;
    return c.constrain(.{ .w = s.opts.width, .h = h });
}

fn tpLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: the chrome is computed from the bounds at paint/hit
}

fn paintTextButton(n: *Node, ctx: *kx.Ctx, r: Rect, label: []const u8, zone: Zone) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const hover = std.meta.eql(s.hover, zone);
    const pressed = std.meta.eql(s.pressed, zone);
    if (hover or pressed) {
        const alpha = if (pressed) t.state.pressed else t.state.hover;
        ui.paint.fillRRect(ctx, r.x, r.y, r.w, r.h, r.h / 2, theme_mod.stateLayer(0, t.colors.primary, alpha));
    }
    const ls = t.type_scale.label_large;
    const bold = ls.weight >= 500;
    const m = ui.paint.measureTextLen(label, ls.size, bold);
    ui.paint.textSlice(ctx, label, r.x + (r.w - m.width) / 2, r.y + (r.h - m.height) / 2 + m.ascent, ls.size, bold, t.colors.primary);
}

/// A time plate (96x80, CornerSmall): the active mode gets the
/// PrimaryContainer fill + the 2dp Primary border + OnPrimaryContainer.
fn paintPlate(n: *Node, ctx: *kx.Ctx, r: Rect, label: []const u8, active: bool, zone: Zone) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const cs = t.colors;
    const fill: Color = if (active) cs.primary_container else cs.surface_container_highest;
    const fg: Color = if (active) cs.on_primary_container else cs.on_surface;
    ui.paint.fillRRect(ctx, r.x, r.y, r.w, r.h, plate_corner, fill);
    const hover = std.meta.eql(s.hover, zone);
    const pressed = std.meta.eql(s.pressed, zone);
    if (hover or pressed) {
        const alpha = if (pressed) t.state.pressed else t.state.hover;
        ui.paint.fillRRect(ctx, r.x, r.y, r.w, r.h, plate_corner, theme_mod.stateLayer(fill, fg, alpha));
    }
    if (active) ui.paint.strokeRRect(ctx, r.x, r.y, r.w, r.h, plate_corner, plate_border, cs.primary);
    const dl = t.type_scale.display_large;
    const m = ui.paint.measureTextLen(label, dl.size, dl.weight >= 500);
    ui.paint.textSlice(ctx, label, r.x + (r.w - m.width) / 2, r.y + (r.h - m.height) / 2 + m.ascent, dl.size, dl.weight >= 500, fg);
}

/// A 24dp keyboard glyph (input variant → dial affordance) — a rounded
/// frame + a 3×2 key grid, all stroked/filled primitives.
fn paintKeyboardGlyph(ctx: *kx.Ctx, x: f32, y: f32, size: f32, color: Color) void {
    const w = size;
    const h = size * 15 / 24;
    const top = y + (size - h) / 2;
    ui.paint.strokeRRect(ctx, x, top, w, h, 2, 1.6, color);
    var row: usize = 0;
    while (row < 2) : (row += 1) {
        var col: usize = 0;
        while (col < 3) : (col += 1) {
            const kx2 = x + w * 0.22 + @as(f32, @floatFromInt(col)) * w * 0.28;
            const ky2 = top + h * 0.24 + @as(f32, @floatFromInt(row)) * h * 0.32;
            ui.paint.fillRect(ctx, kx2, ky2, w * 0.13, h * 0.16, color);
        }
    }
}

/// A 24dp clock glyph (dial variant → keyboard affordance) — a stroked
/// circle + two hands.
fn paintClockGlyph(ctx: *kx.Ctx, x: f32, y: f32, size: f32, color: Color) void {
    const cx = x + size / 2;
    const cy = y + size / 2;
    const r = size * 0.42;
    ui.paint.strokeRRect(ctx, cx - r, cy - r, 2 * r, 2 * r, r, 1.6, color);
    var xs = [2]f32{ cx, cx };
    var ys = [2]f32{ cy, cy - r * 0.62 };
    ui.paint.strokePolyline(ctx, &xs, &ys, 1.6, false, color);
    var xs2 = [2]f32{ cx, cx + r * 0.55 };
    var ys2 = [2]f32{ cy, cy + r * 0.18 };
    ui.paint.strokePolyline(ctx, &xs2, &ys2, 1.6, false, color);
}

/// The footer: the optional mode toggle at the leading edge + the
/// Cancel/OK text buttons.
fn paintFooter(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const cs = t.colors;
    if (showModeToggle(s)) {
        const tr = modeToggleRect(n);
        const hover = std.meta.eql(s.hover, .mode_toggle);
        const pressed = std.meta.eql(s.pressed, .mode_toggle);
        if (hover or pressed) {
            const alpha = if (pressed) t.state.pressed else t.state.hover;
            ui.paint.fillRRect(ctx, tr.x + (tr.w - toggle_box) / 2, tr.y + (tr.h - toggle_box) / 2, toggle_box, toggle_box, toggle_box / 2, theme_mod.stateLayer(0, cs.on_surface_variant, alpha));
        }
        const gx = tr.x + (tr.w - toggle_icon) / 2;
        const gy = tr.y + (tr.h - toggle_icon) / 2;
        // dial mode → the keyboard glyph (switch to typing); input → clock.
        if (s.variant == .dial) {
            paintKeyboardGlyph(ctx, gx, gy, toggle_icon, cs.on_surface_variant);
        } else {
            paintClockGlyph(ctx, gx, gy, toggle_icon, cs.on_surface_variant);
        }
    }
    const fr = footerRects(n);
    paintTextButton(n, ctx, fr.cancel, i18n_mod.tr("Cancel"), .cancel);
    paintTextButton(n, ctx, fr.ok, i18n_mod.tr("OK"), .ok);
}

/// The supporting text's line strings — "Hour"/"Minute" normally, the
/// upstream error text when the field's input is invalid (hand-wrapped to
/// the 96dp box; upstream minLines = 2). Localized through tr() — the
/// English literal is the key (the app's ARB overrides per locale).
fn supportLine(s: *TpState, which: DialMode, line: usize) ?[]const u8 {
    if (!fieldInvalid(s, which)) {
        if (line != 0) return null;
        return i18n_mod.tr(if (which == .hour) "Hour" else "Minute");
    }
    return switch (which) {
        .hour => switch (line) {
            0 => i18n_mod.tr("Hour must be"),
            1 => i18n_mod.tr(if (s.opts.is_24h) "between 0 and 23" else "between 1 and 12"),
            else => null,
        },
        .minute => switch (line) {
            0 => i18n_mod.tr("Minutes must be"),
            1 => i18n_mod.tr("between 0 and 59"),
            else => null,
        },
    };
}

/// An input-variant field (96x72, upstream TimeInputImpl's row): only the
/// SELECTED field is an editable box — PrimaryContainer + a 2dp Outline
/// border while focused, SurfaceContainerHighest + a 1dp Outline border
/// when the node isn't focused (upstream's TimePickerTextFieldContainer
/// border); the other field paints the borderless TimeSelector plate —
/// SurfaceContainerHighest + the FORMATTED value. An invalid input swaps
/// the container/text/border + the supporting text for the error tokens.
fn paintInputField(n: *Node, ctx: *kx.Ctx, which: DialMode) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const cs = t.colors;
    const r = inputFieldRect(n.bounds, which, s.opts.is_24h);
    const e = editOf(s, which);
    const selected = s.mode == which;
    const focused = input.isFocused(n);
    const invalid = fieldInvalid(s, which);
    const zone: Zone = if (which == .hour) .hour_field else .minute_field;
    // The upstream container/content colors (timeTextFieldColors /
    // timeSelectorColors + the error slots).
    const fill: Color = if (invalid)
        cs.error_container
    else if (selected and focused)
        cs.primary_container
    else
        cs.surface_container_highest;
    const fg: Color = if (invalid)
        // timeTextFieldColors: focusedTextColor → Error, the
        // TimeSelector's → OnErrorContainer.
        (if (selected) cs.@"error" else cs.on_error_container)
    else if (selected and focused)
        cs.on_primary_container
    else
        cs.on_surface;
    ui.paint.fillRRect(ctx, r.x, r.y, r.w, r.h, plate_corner, fill);
    const hover = std.meta.eql(s.hover, zone);
    const pressed = std.meta.eql(s.pressed, zone);
    if (hover or pressed) {
        const alpha = if (pressed) t.state.pressed else t.state.hover;
        ui.paint.fillRRect(ctx, r.x, r.y, r.w, r.h, plate_corner, theme_mod.stateLayer(fill, fg, alpha));
    }
    const dm = t.type_scale.display_medium;
    const dm_bold = dm.weight >= 500;
    var tx: f32 = 0;
    var baseline: f32 = 0;
    var m: ui.paint.TextMetrics = undefined;
    var str: [:0]const u8 = "";
    if (selected) {
        // The editable box: the 2dp focused / 1dp unfocused Outline border
        // (Error while invalid), then the LIVE buffer text centered.
        const bw: f32 = if (focused) plate_border else 1;
        ui.paint.strokeRRect(ctx, r.x, r.y, r.w, r.h, plate_corner, bw, if (invalid) cs.@"error" else cs.outline);
        str = e.text();
        m = ui.paint.measureText(str, dm.size, dm_bold);
        tx = r.x + (r.w - m.width) / 2;
        baseline = r.y + (r.h - m.height) / 2 + m.ascent;
        e.ensureTicker(); // lazy — the host timeline may not exist at init
        // The selection highlight sits behind the glyphs (focused only).
        if (focused) {
            const sel = e.selRange();
            if (sel.hi > sel.lo) {
                const hx0 = tx + ui.paint.measureTextLen(str[0..sel.lo], dm.size, dm_bold).width;
                const hx1 = tx + ui.paint.measureTextLen(str[0..sel.hi], dm.size, dm_bold).width;
                ui.paint.fillRect(ctx, hx0, baseline - m.ascent, hx1 - hx0, m.ascent + m.descent, ui.paint.withAlphaScaled(cs.primary, 0.4));
            }
        }
        ui.paint.text(ctx, str, tx, baseline, dm.size, dm_bold, fg);
        // The IME preedit rides after the buffer text (underlined).
        var cx = tx + ui.paint.measureTextLen(str[0..e.caret], dm.size, dm_bold).width;
        if (e.comp.items.len > 0) {
            const comp = e.composition();
            const pre_w = ui.paint.measureTextLen(str, dm.size, dm_bold).width;
            const cm = ui.paint.measureText(comp, dm.size, dm_bold);
            ui.paint.text(ctx, comp, tx + pre_w, baseline, dm.size, dm_bold, fg);
            ui.paint.fillRect(ctx, tx + pre_w, baseline + 1, cm.width, 1, fg);
            const at: usize = @intCast(@min(@max(e.comp_cursor, 0), @as(i32, @intCast(comp.len))));
            cx = tx + pre_w + ui.paint.measureTextLen(comp[0..at], dm.size, dm_bold).width;
        }
        // The caret (focused only) — upstream's middle-80% glyph block.
        if (focused and e.caret_on) {
            ui.paint.fillRect(ctx, cx, baseline - m.ascent * 0.8, 2, (m.ascent + m.descent) * 0.8, cs.primary);
        }
    } else {
        // The TimeSelector plate: the CANONICAL value (the formatted
        // input), no border, centered.
        var b: [8]u8 = undefined;
        str = canonicalFieldText(s, which, &b);
        m = ui.paint.measureText(str, dm.size, dm_bold);
        tx = r.x + (r.w - m.width) / 2;
        baseline = r.y + (r.h - m.height) / 2 + m.ascent;
        ui.paint.text(ctx, str, tx, baseline, dm.size, dm_bold, fg);
    }
    // The supporting text: "Hour"/"Minute" (or the error text), BodySmall
    // in the field's x band.
    const bs = t.type_scale.body_small;
    const bs_bold = bs.weight >= 500;
    const ink: Color = if (invalid) cs.@"error" else cs.on_surface_variant;
    var line: usize = 0;
    while (supportLine(s, which, line)) |lbl| : (line += 1) {
        const sup = supportRect(n.bounds, which, s.opts.is_24h, line, t);
        const lm = ui.paint.measureTextLen(lbl, bs.size, bs_bold);
        ui.paint.textSlice(ctx, lbl, sup.x, sup.y + lm.ascent, bs.size, bs_bold, ink);
    }
}

/// The AM/PM period toggle (both variants): a 1dp Outline border +
/// divider, the selected half TertiaryContainer.
fn paintPeriodToggle(n: *Node, ctx: *kx.Ctx, pr: Rect, tm: i32) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const cs = t.colors;
    ui.paint.strokeRRect(ctx, pr.x, pr.y, pr.w, pr.h, plate_corner, 1, cs.outline);
    const half_h = pr.h / 2;
    const pm = isPm(tm);
    const ampm = i18n_mod.amPm();
    const halves = [_]struct { zone: Zone, label: []const u8, selected: bool, y: f32 }{
        .{ .zone = .am, .label = ampm.am, .selected = !pm, .y = pr.y },
        .{ .zone = .pm, .label = ampm.pm, .selected = pm, .y = pr.y + half_h },
    };
    for (halves) |h| {
        // the half's corners: the toggle's rounded side only (AM = top,
        // PM = bottom)
        const tl: f32 = if (h.zone == .am) plate_corner else 0;
        const tr: f32 = tl;
        const br: f32 = if (h.zone == .pm) plate_corner else 0;
        const bl: f32 = br;
        if (h.selected) {
            ui.paint.fillRRectCorners(ctx, pr.x, h.y, pr.w, half_h, tl, tr, br, bl, cs.tertiary_container);
        }
        const hover = std.meta.eql(s.hover, h.zone);
        const pressed = std.meta.eql(s.pressed, h.zone);
        if (hover or pressed) {
            const alpha = if (pressed) t.state.pressed else t.state.hover;
            const on: Color = if (h.selected) cs.on_tertiary_container else cs.on_surface_variant;
            ui.paint.fillRRectCorners(ctx, pr.x, h.y, pr.w, half_h, tl, tr, br, bl, theme_mod.stateLayer(0, on, alpha));
        }
        const tm_style = t.type_scale.title_medium;
        const bold = tm_style.weight >= 500;
        const m = ui.paint.measureTextLen(h.label, tm_style.size, bold);
        const fg: Color = if (h.selected) cs.on_tertiary_container else cs.on_surface_variant;
        ui.paint.textSlice(ctx, h.label, pr.x + (pr.w - m.width) / 2, h.y + (half_h - m.height) / 2 + m.ascent, tm_style.size, bold, fg);
    }
    // the 1dp divider between the halves
    ui.paint.fillRect(ctx, pr.x, pr.y + half_h - 0.5, pr.w, 1, cs.outline);
}

fn tpPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const cs = t.colors;
    const b = n.bounds;
    const tm = clampedTime(s.time.peek());
    // the container
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, container_corner, cs.surface_container_high);
    if (s.variant == .input) {
        // the input variant: two fields + the separator + the period
        // toggle, the supporting labels, the footer — no clock face
        paintInputField(n, ctx, .hour);
        paintInputField(n, ctx, .minute);
        // upstream DisplaySeparator: LocalTextStyle(DisplayMedium), the
        // -4dp optical nudge.
        const dm0 = t.type_scale.display_medium;
        const sep0 = inputSeparatorRect(b, s.opts.is_24h);
        const sep0_m = ui.paint.measureText(":", dm0.size, dm0.weight >= 500);
        ui.paint.text(ctx, ":", sep0.x + (sep0.w - sep0_m.width) / 2, sep0.y + sep_offset_y + (sep0.h - sep0_m.height) / 2 + sep0_m.ascent, dm0.size, dm0.weight >= 500, cs.on_surface);
        if (!s.opts.is_24h) paintPeriodToggle(n, ctx, inputPeriodRect(b), tm);
        paintFooter(n, ctx);
        return;
    }
    // the header: the hour plate, the separator, the minute plate, the toggle
    var hbuf: [4]u8 = undefined;
    var mbuf: [4]u8 = undefined;
    const hour_v = if (s.opts.is_24h) hour24Of(tm) else hour12Of(tm);
    // The clock fields are euclidean (always >= 0) — cast to unsigned: Zig
    // 0.17 pads signed ints with an explicit sign.
    const hour_lbl = std.fmt.bufPrintSentinel(&hbuf, "{d:0>2}", .{@as(u32, @intCast(hour_v))}, 0) catch "?";
    const minute_lbl = std.fmt.bufPrintSentinel(&mbuf, "{d:0>2}", .{@as(u32, @intCast(minuteOf(tm)))}, 0) catch "?";
    paintPlate(n, ctx, plateRect(b, .hour, s.opts.is_24h), hour_lbl, s.mode == .hour, .hour_plate);
    paintPlate(n, ctx, plateRect(b, .minute, s.opts.is_24h), minute_lbl, s.mode == .minute, .minute_plate);
    const dl = t.type_scale.display_large;
    const sep = separatorRect(b, s.opts.is_24h);
    const sep_m = ui.paint.measureText(":", dl.size, dl.weight >= 500);
    ui.paint.text(ctx, ":", sep.x + (sep.w - sep_m.width) / 2, sep.y + (sep.h - sep_m.height) / 2 + sep_m.ascent, dl.size, dl.weight >= 500, cs.on_surface);
    if (!s.opts.is_24h) paintPeriodToggle(n, ctx, periodRect(b), tm);
    // the dial
    const d = dialRect(b);
    const cx = d.x + d.w / 2;
    const cy = d.y + d.h / 2;
    ui.paint.fillRRect(ctx, d.x, d.y, d.w, d.h, dial_size / 2, cs.surface_container_highest);
    const bl = t.type_scale.body_large;
    const bl_bold = bl.weight >= 500;
    const is_24h = s.opts.is_24h and s.mode == .hour;
    const sel_val = dialValue(tm, s.mode, s.opts.is_24h);
    // the labels on the ring(s): the 24h hour dial has two rings — 00..11 on
    // the outer circle (101dp), 12..23 on the inner one (69dp). The selected
    // label is stashed and drawn AFTER the selector (on top of the knob).
    var sel_buf: [4]u8 = undefined;
    var sel_str: ?[:0]const u8 = null;
    var sel_x: f32 = 0;
    var sel_y: f32 = 0;
    var ring_index: usize = 0;
    while (ring_index < @as(usize, if (is_24h) 2 else 1)) : (ring_index += 1) {
        const ring: f32 = if (ring_index == 1) inner_label_ring else label_ring;
        for (0..12) |i| {
            const a = (@as(f32, @floatFromInt(i)) * 30 - 90) * std.math.pi / 180;
            const lx = cx + @cos(a) * ring;
            const ly = cy + @sin(a) * ring;
            const value: i32 = if (s.mode == .hour) blk: {
                if (is_24h) {
                    const base = @mod(hour_values[i], 12); // 0..11
                    break :blk if (ring_index == 1) base + 12 else base;
                }
                break :blk hour_values[i];
            } else @intCast(i * 5);
            var vbuf: [4]u8 = undefined;
            const vstr = if (s.mode == .hour and is_24h)
                std.fmt.bufPrintSentinel(&vbuf, "{d:0>2}", .{@as(u32, @intCast(value))}, 0) catch "?"
            else if (s.mode == .hour)
                std.fmt.bufPrintSentinel(&vbuf, "{d}", .{value}, 0) catch "?"
            else
                std.fmt.bufPrintSentinel(&vbuf, "{d:0>2}", .{@as(u32, @intCast(value))}, 0) catch "?";
            if (value == sel_val) {
                @memcpy(sel_buf[0..vstr.len], vstr[0..vstr.len]);
                sel_buf[vstr.len] = 0;
                sel_str = sel_buf[0..vstr.len :0];
                sel_x = lx;
                sel_y = ly;
                continue;
            }
            const m = ui.paint.measureText(vstr, bl.size, bl_bold);
            ui.paint.text(ctx, vstr, lx - m.width / 2, ly - m.height / 2 + m.ascent, bl.size, bl_bold, cs.on_surface);
        }
    }
    // the selector: the track + the knob + the center dot
    const sel_angle = valueAngle(sel_val, s.mode, s.opts.is_24h) * std.math.pi / 180;
    const sel_ring = selectorRing(sel_val, s.mode, s.opts.is_24h);
    const kx_ = cx + @cos(sel_angle) * sel_ring;
    const ky = cy + @sin(sel_angle) * sel_ring;
    const hand_end_r = sel_ring - knob_d / 2;
    var xs = [2]f32{ cx, cx + @cos(sel_angle) * hand_end_r };
    var ys = [2]f32{ cy, cy + @sin(sel_angle) * hand_end_r };
    ui.paint.strokePolyline(ctx, &xs, &ys, track_w, false, cs.primary);
    ui.paint.fillRRect(ctx, kx_ - knob_d / 2, ky - knob_d / 2, knob_d, knob_d, knob_d / 2, cs.primary);
    ui.paint.fillRRect(ctx, cx - center_d / 2, cy - center_d / 2, center_d, center_d, center_d / 2, cs.primary);
    // the selected label on top of the knob (OnPrimary)
    if (sel_str) |vstr| {
        const m = ui.paint.measureText(vstr, bl.size, bl_bold);
        ui.paint.text(ctx, vstr, sel_x - m.width / 2, sel_y - m.height / 2 + m.ascent, bl.size, bl_bold, cs.on_primary);
    }
    // the footer
    paintFooter(n, ctx);
}

// --- input ---

/// The caret offset a field tap lands on: the field's text is centered,
/// so the hit x is measured off the run's left edge (text_field's
/// caretFromPoint pattern against the field's DisplayMedium).
fn fieldCaretFromPoint(n: *Node, s: *TpState, which: DialMode, x: f32, y: f32) usize {
    const e = editOf(s, which);
    const str = e.text();
    const r = inputFieldRect(n.bounds, which, s.opts.is_24h);
    const dm = s.opts.theme.type_scale.display_medium;
    const m = ui.paint.measureText(str, dm.size, dm.weight >= 500);
    const tx = r.x + (r.w - m.width) / 2;
    return e.caretAt(x - tx, y - r.y, dm.size);
}

fn tpOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    switch (ev.phase) {
        .down => {
            const z = zoneAt(n, ev.x, ev.y);
            if (std.meta.activeTag(z) == .none) return false;
            s.down_x = ev.raw_x;
            s.down_y = ev.raw_y;
            if (std.meta.activeTag(z) == .dial) {
                // the dial owns the drag: select by angle immediately
                s.dragging = true;
                const c = dialCenter(n);
                applyDialValue(s, valueAtAngle(c[0], c[1], ev.x, ev.y, s.mode, s.opts.is_24h));
                n.markDirty();
                return true;
            }
            if (z == .hour_field or z == .minute_field) {
                const which: DialMode = if (z == .hour_field) .hour else .minute;
                if (s.mode != which) {
                    // The unselected field is a TimeSelector surface — a
                    // press highlight; the selection swaps on release
                    // (upstream's Surface onClick).
                    s.pressed = z;
                    n.markDirty();
                    return true;
                }
                // The selected field is the real editable box: a tap lands
                // the caret (text_field's pattern) and can drag-select.
                input.requestFocus(n);
                const e = editOf(s, which);
                e.tap(fieldCaretFromPoint(n, s, which, ev.x, ev.y), ev.x, ev.y, ev.time_ms);
                s.drag_field = which;
                s.pressed = z;
                n.markDirty();
                return true;
            }
            s.pressed = z;
            n.markDirty();
            return true;
        },
        .move => {
            if (s.dragging) {
                const c = dialCenter(n);
                applyDialValue(s, valueAtAngle(c[0], c[1], ev.x, ev.y, s.mode, s.opts.is_24h));
                n.markDirty();
                return true; // the dial claims the move
            }
            if (s.drag_field) |which| {
                const e = editOf(s, which);
                if (e.dragging) {
                    e.dragExtend(fieldCaretFromPoint(n, s, which, ev.x, ev.y));
                    n.markDirty();
                    return true;
                }
                s.drag_field = null;
            }
            if (std.meta.activeTag(s.pressed) != .none) {
                const dx = ev.raw_x - s.down_x;
                const dy = ev.raw_y - s.down_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.pressed = .none;
                    n.markDirty();
                }
            }
            return false;
        },
        .up => {
            if (s.drag_field) |which| {
                const e = editOf(s, which);
                e.dragging = false;
                e.drag_word = false;
                s.drag_field = null;
                s.pressed = .none;
                n.markDirty();
                return true; // the field's gesture consumed the release
            }
            if (s.dragging) {
                s.dragging = false;
                // upstream onTap/onDragEnd: after an hour pick the dial
                // auto-advances to the minute mode (autoSwitchToMinute)
                if (s.mode == .hour and s.opts.auto_switch_to_minute) s.mode = .minute;
                n.markDirty();
                return true;
            }
            const was = s.pressed;
            s.pressed = .none;
            n.markDirty();
            if (std.meta.activeTag(was) == .none) return false;
            if (!std.meta.eql(zoneAt(n, ev.x, ev.y), was)) return true; // released outside: no action
            activate(n, s, was);
            return true;
        },
        .outside_down => {
            if (std.meta.activeTag(s.pressed) != .none) {
                s.pressed = .none;
                n.markDirty();
            }
            return false;
        },
        .enter, .leave => {
            s.hover = zoneAt(n, ev.x, ev.y);
            n.markDirty();
            return true;
        },
        .hover_move => {
            const z = zoneAt(n, ev.x, ev.y);
            if (!std.meta.eql(z, s.hover)) {
                s.hover = z;
                n.markDirty();
            }
            return true;
        },
    }
}

fn tpOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    // Only the input variant edits — and only while a field holds focus.
    if (s.variant != .input or !input.isFocused(n)) return false;
    // Upstream shouldSwitchFocusToMinute: a digit at the end of a complete
    // valid hour hops to the minute field and lands there.
    var target: DialMode = s.mode;
    if (shouldSwitchFocusToMinute(s, ev)) {
        s.mode = .minute;
        clearComp(&s.hour_edit);
        refreshSemanticsChildren(n);
        ui.semantics.notifyTreeDirty(); // the focusable child moved
        target = .minute;
        n.markDirty();
    }
    s.editing = target;
    const e = editOf(s, target);
    s.snap = snapEdit(e);
    // Upstream isReplacingTwoDigits: a lone char typed into a full
    // collapsed-caret field rolls the buffer over to just that char
    // (otherwise the transform's >2-char gate would reject it).
    if (ev.kind == .text_input and ev.text.len == 1 and
        e.buf.items.len == max_field_chars and e.caret == e.sel_anchor)
    {
        e.buf.clearRetainingCapacity();
        e.buf.appendSlice(ev.text) catch @panic("klaxon: out of memory");
        text_edit.setSentinel(&e.buf);
        e.caret = e.buf.items.len;
        e.sel_anchor = e.caret;
        e.resetBlink();
        transformAfterEdit(n, target);
        return true;
    }
    if (e.handleKey(ev, applyEditNode)) return true;
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        // Upstream KeyboardOptions: hour = ImeAction.Next (→ the minute
        // field, gated on a valid hour), minute = ImeAction.Done (blur).
        .enter => {
            if (s.mode == .hour) {
                if (isHourInputValid(s)) selectField(n, s, .minute);
            } else {
                input.requestFocus(null);
            }
            n.markDirty();
            return true;
        },
        // Tab walks the fields directionally; off the edge it bubbles to
        // the host's focus traversal.
        .tab => {
            if (!ev.shift and s.mode == .hour) {
                selectField(n, s, .minute);
                return true;
            }
            if (ev.shift and s.mode == .minute) {
                selectField(n, s, .hour);
                return true;
            }
            return false;
        },
        .escape => {
            input.requestFocus(null);
            n.markDirty();
            return true;
        },
        else => return false,
    }
}

fn dialCenter(n: *Node) struct { f32, f32 } {
    const d = dialRect(n.bounds);
    return .{ d.x + d.w / 2, d.y + d.h / 2 };
}

/// Upstream's `selection = which` + the field's focusRequester: the swap
/// selects the field and focuses it — the field keeps its OWN text state
/// (upstream restore-only rememberTextFieldState; no select-all).
fn selectField(n: *Node, s: *TpState, which: DialMode) void {
    if (s.mode != which) {
        clearComp(editOf(s, s.mode)); // the outgoing field loses its preedit
        s.mode = which;
        // The a11y tree's focusable bit moved to the other field child.
        refreshSemanticsChildren(n);
        ui.semantics.notifyTreeDirty();
    }
    input.requestFocus(n);
    n.markDirty();
}

/// The footer toggle's runtime variant flip (upstream swaps the
/// TimeInput/TimePicker composable): entering input is a fresh
/// composition — the fields re-seed from the committed time.
fn flipVariant(n: *Node, s: *TpState) void {
    s.variant = if (s.variant == .dial) .input else .dial;
    if (s.variant == .input) {
        resetInputFields(n);
        input.requestFocus(n); // the selected field takes focus
    } else {
        s.drag_field = null;
        clearComp(&s.hour_edit);
        clearComp(&s.minute_edit);
        if (input.isFocused(n)) input.requestFocus(null);
    }
    attachSemantics(n); // the child set differs per variant
    ui.semantics.notifyTreeDirty();
    n.markLayoutDirty(); // the two variants measure different heights
    n.markDirty();
}

fn activate(n: *Node, s: *TpState, z: Zone) void {
    switch (z) {
        .none, .dial => {},
        .hour_plate => s.mode = .hour,
        .minute_plate => s.mode = .minute,
        .hour_field => selectField(n, s, .hour),
        .minute_field => selectField(n, s, .minute),
        .mode_toggle => flipVariant(n, s),
        .am, .pm => {
            const t = clampedTime(s.time.peek());
            if (s.variant == .input) {
                // Upstream TimeInput's PeriodToggle: gated on
                // isHourInputValid, hour ± 12 on the committed time.
                if (!isHourInputValid(s)) return;
                if (z == .am and isPm(t)) {
                    s.time.set(t - 12 * 60);
                } else if (z == .pm and !isPm(t)) {
                    s.time.set(t + 12 * 60);
                }
            } else {
                const h12 = hour12Of(t);
                const h24: i32 = if (z == .pm) @mod(h12, 12) + 12 else @mod(h12, 12);
                s.time.set(h24 * 60 + minuteOf(t));
            }
        },
        .cancel => {
            if (s.on_cancel) |cb| cb.fn_ptr(cb.userdata);
        },
        .ok => {
            if (s.on_select) |cb| cb.fn_ptr(cb.userdata);
        },
    }
}

// --- signals + a11y ---

/// Rewrite a field's text from the signal when its COMMITTED component
/// changed — upstream's per-part LaunchedEffect on state.hour (the
/// hour-24 value — an AM→PM flip at the same 12h display still fires)
/// /state.minute. The setter-side `hourInput = hour` runs first, then
/// `override` is consumed once: a field that just pushed its own edit
/// isn't rewritten (the typed text wins for that one sync), then re-arms.
fn syncComponent(s: *TpState, which: DialMode) void {
    const e = editOf(s, which);
    const committed: i32 = if (which == .hour) hour24Of(s.time.peek()) else minuteOf(s.time.peek());
    const last = if (which == .hour) &s.last_hour else &s.last_minute;
    if (last.* == committed) return;
    last.* = committed;
    const input_slot = if (which == .hour) &s.hour_input else &s.minute_input;
    input_slot.* = committed; // upstream: the component setter writes the input
    const override = if (which == .hour) &s.hour_override else &s.minute_override;
    if (!override.*) {
        override.* = true;
        return;
    }
    var b: [8]u8 = undefined;
    const str = canonicalFieldText(s, which, &b);
    // Upstream compares before replacing — an identical text keeps the
    // field's caret/selection.
    if (!std.mem.eql(u8, e.text(), str)) {
        setFieldText(e, str);
        // A rewrite also refreshes the a11y child's live value.
        refreshSemanticsChildren(e.node.?);
    }
}

/// (Re)build the input variant's virtual a11y children — the hour field,
/// the minute field, the AM/PM halves (12h), the mode toggle. Upstream
/// mirrors the swap: the SELECTED field is a text field ("for hour" /
/// "for minutes" content descriptions, focusable); the other is a
/// RadioButton-role TimeSelector ("Hour selection"/"Minute selection").
fn refreshSemanticsChildren(n: *Node) void {
    const s = stateOf(n);
    if (s.variant != .input) return;
    const act = ui.semantics.Actions.initOne(.activate);
    var i: usize = 0;
    const fields = [_]struct { which: DialMode, sel_label: []const u8, field_label: []const u8 }{
        .{ .which = .hour, .sel_label = i18n_mod.tr("Hour selection"), .field_label = i18n_mod.tr("for hour") },
        .{ .which = .minute, .sel_label = i18n_mod.tr("Minute selection"), .field_label = i18n_mod.tr("for minutes") },
    };
    for (fields) |f| {
        const selected = s.mode == f.which;
        s.sem_children[i] = if (selected)
            .{ .role = .text_field, .label = f.field_label, .focusable = true, .value = fieldSemValue(n, f.which) }
        else
            .{ .role = .radio, .label = f.sel_label, .actions = act, .value = fieldSemValue(n, f.which) };
        i += 1;
    }
    if (!s.opts.is_24h) {
        const pm = committedPm(s);
        const ampm = i18n_mod.amPm();
        s.sem_children[i] = .{ .role = .radio, .label = ampm.am, .checked = !pm, .actions = act };
        i += 1;
        s.sem_children[i] = .{ .role = .radio, .label = ampm.pm, .checked = pm, .actions = act };
        i += 1;
    }
    if (showModeToggle(s)) {
        s.sem_children[i] = .{ .role = .button, .label = i18n_mod.tr("Switch to clock"), .actions = act };
        i += 1;
    }
    if (n.semantics) |sem| sem.children = s.sem_children[0..i];
}

/// (Re)attach the node's a11y descriptor for the current variant — the
/// dial keeps its original group semantics; the input variant adds the
/// virtual children.
fn attachSemantics(n: *Node) void {
    const s = stateOf(n);
    if (s.variant == .input) {
        ui.semantics.attach(n, .{
            .role = .group,
            .label = i18n_mod.tr("Time picker"),
            .value = s.value_buf[0..s.value_len],
            .children = &.{},
            .child_bounds = tpChildBounds,
        });
        refreshSemanticsChildren(n);
    } else {
        ui.semantics.attach(n, .{
            .role = .group,
            .label = i18n_mod.tr("Time picker"),
            .value = s.value_buf[0..s.value_len],
        }); // the dial's original descriptor — unchanged
    }
}

fn tpSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    syncComponent(s, .hour);
    syncComponent(s, .minute);
    updateA11yValue(n);
    refreshSemanticsChildren(n);
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the value changed
}

/// A locale switch: the tr()/amPm() strings re-resolve — repaint the
/// labels, reformat the a11y value (the day-period literal is localized)
/// and rebuild the virtual children's strings.
fn tpLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    updateA11yValue(n); // the day-period literal localizes
    // The root descriptor's label is tr()-resolved — re-attach (rebuilds
    // the input variant's virtual children in the new locale).
    attachSemantics(n);
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

/// "10:30 AM" (12h) / "22:30" (24h) — the a11y value + the gallery's time
/// label (pub for the gallery: it matches what the picker displays).
pub fn formatTime(t: i32, is_24h: bool, buf: []u8) [:0]const u8 {
    const h24: u32 = @intCast(hour24Of(t));
    const min: u32 = @intCast(minuteOf(t));
    if (is_24h) {
        return std.fmt.bufPrintSentinel(buf, "{d:0>2}:{d:0>2}", .{ h24, min }, 0) catch "?";
    }
    var b1: [4]u8 = undefined;
    var b2: [4]u8 = undefined;
    const h = std.fmt.bufPrintSentinel(&b1, "{d:0>2}", .{@as(u32, @intCast(hour12Of(t)))}, 0) catch "?";
    const m = std.fmt.bufPrintSentinel(&b2, "{d:0>2}", .{min}, 0) catch "?";
    const ampm = i18n_mod.amPm();
    return std.fmt.bufPrintSentinel(buf, "{s}:{s} {s}", .{ h, m, if (isPm(t)) ampm.pm else ampm.am }, 0) catch "?";
}

fn updateA11yValue(n: *Node) void {
    const s = stateOf(n);
    const tm = clampedTime(s.time.peek());
    const str = formatTime(tm, s.opts.is_24h, &s.value_buf);
    s.value_len = str.len;
    if (n.semantics) |sem| sem.value = s.value_buf[0..s.value_len];
}

fn tpDeinit(n: *Node) void {
    const s = stateOf(n);
    s.time.unsubscribe(.{ .callback = .{ .fn_ptr = tpSyncCb, .userdata = n } });
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = tpLocaleCb, .userdata = n });
    input.releaseNode(n);
    s.hour_edit.deinit();
    s.minute_edit.deinit();
    n.allocator.destroy(s);
}

/// The virtual a11y children's LOCAL-space rects (the framework adds
/// bounds.x/y back), in the same order refreshSemanticsChildren builds
/// them: hour field, minute field, AM half, PM half (12h), mode toggle.
fn tpChildBounds(n: *Node, index: usize) Rect {
    const s = stateOf(n);
    const b = n.bounds;
    var r: Rect = undefined;
    var idx = index;
    if (idx == 0) {
        r = inputFieldRect(b, .hour, s.opts.is_24h);
    } else if (idx == 1) {
        r = inputFieldRect(b, .minute, s.opts.is_24h);
    } else {
        idx -= 2;
        if (!s.opts.is_24h) {
            const pr = inputPeriodRect(b);
            if (idx == 0) {
                r = .{ .x = pr.x, .y = pr.y, .w = pr.w, .h = pr.h / 2 };
            } else if (idx == 1) {
                r = .{ .x = pr.x, .y = pr.y + pr.h / 2, .w = pr.w, .h = pr.h / 2 };
            } else {
                r = modeToggleRect(n);
            }
        } else {
            r = modeToggleRect(n);
        }
    }
    return .{ .x = r.x - b.x, .y = r.y - b.y, .w = r.w, .h = r.h };
}

const tp_vtable = ui.node.VTable{
    .measure = tpMeasure,
    .layout = tpLayout,
    .paint = tpPaint,
    .deinit = tpDeinit,
    .on_pointer = tpOnPointer,
    .on_key = tpOnKey,
    // The node raises the platform IME only while it holds the focus —
    // i.e. only while an input-variant field is selected.
    .wants_text_input = true,
};

/// An M3E time picker panel (the analog dial). `time` is a two-way
/// Signal(i32) of minutes since midnight (clamped to 0..1439). `on_select`
/// fires on OK, `on_cancel` on Cancel. The widget is a LEAF panel (it paints
/// all its chrome; the app wraps it in a dialog for modal behavior).
pub fn timePicker(allocator: std.mem.Allocator, time: *ui.state.Signal(i32), on_select: ?ui.state.Callback, on_cancel: ?ui.state.Callback, opts: TimePickerOptions) !*Node {
    const node = try Node.create(allocator, &tp_vtable);
    errdefer node.allocator.destroy(node); // no state yet
    const s = try allocator.create(TpState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .time = time, .on_select = on_select, .on_cancel = on_cancel, .variant = opts.mode };
    node.state = s;
    s.hour_edit = text_edit.Edit.init(allocator, node);
    s.minute_edit = text_edit.Edit.init(allocator, node);
    errdefer {
        s.hour_edit.deinit();
        s.minute_edit.deinit();
    }
    // Seed the field texts + the parsed inputs from the signal (upstream's
    // rememberTextFieldState, canonical "%02d") and the a11y value.
    resetInputFields(node);
    updateA11yValue(node);
    attachSemantics(node); // Phase 2c — the input variant adds its virtual children
    time.subscribe(.{ .callback = .{ .fn_ptr = tpSyncCb, .userdata = node } });
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = tpLocaleCb, .userdata = node });
    return node;
}

// --- tests ---

/// A picker at 10:30 (630 minutes).
fn tpFixture(a: std.mem.Allocator) !struct { *Node, *ui.state.Signal(i32) } {
    const t = try ui.state.Signal(i32).init(a, 630);
    errdefer t.deinit();
    const n = try timePicker(a, t, null, null, .{});
    errdefer n.deinit();
    return .{ n, t };
}

test "time_picker: the time math (12h display, period, clamping)" {
    try std.testing.expectEqual(@as(i32, 10), hour24Of(630));
    try std.testing.expectEqual(@as(i32, 30), minuteOf(630));
    try std.testing.expectEqual(@as(i32, 10), hour12Of(630));
    try std.testing.expect(!isPm(630));
    try std.testing.expect(isPm(720)); // 12:00 = noon = PM
    try std.testing.expectEqual(@as(i32, 12), hour12Of(720));
    try std.testing.expectEqual(@as(i32, 0), hour24Of(0)); // 12:00 AM
    try std.testing.expectEqual(@as(i32, 12), hour12Of(0));
    try std.testing.expectEqual(@as(i32, 23), hour24Of(1439));
    try std.testing.expectEqual(@as(i32, 1439), clampedTime(5000));
    try std.testing.expectEqual(@as(i32, 0), clampedTime(-5));
    // the dial angles: 12 at the top (-90°), 6 at the bottom (90°)
    try std.testing.expectApproxEqAbs(@as(f32, -90), valueAngle(12, .hour, false), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 90), valueAngle(6, .hour, false), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -90), valueAngle(0, .minute, false), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 90), valueAngle(30, .minute, false), 0.01);
    // the angle → value round-trips
    try std.testing.expectEqual(@as(i32, 12), valueAtAngle(0, 0, 0, -101, .hour, false)); // the top = 12
    try std.testing.expectEqual(@as(i32, 6), valueAtAngle(0, 0, 0, 101, .hour, false)); // down = 6
    try std.testing.expectEqual(@as(i32, 30), valueAtAngle(0, 0, 0, 101, .minute, false)); // down = 30
    try std.testing.expectEqual(@as(i32, 0), valueAtAngle(0, 0, 0, -101, .minute, false)); // up = 00
    try std.testing.expectEqual(@as(i32, 15), valueAtAngle(0, 0, 101, 0, .minute, false)); // right = 15
    // the 24h dial: 00 and 12 share the top position, 18 sits at the bottom
    try std.testing.expectApproxEqAbs(@as(f32, -90), valueAngle(0, .hour, true), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -90), valueAngle(12, .hour, true), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 90), valueAngle(18, .hour, true), 0.01);
    try std.testing.expectEqual(@as(i32, 15), dialValue(15 * 60 + 30, .hour, true));
    try std.testing.expectEqual(@as(i32, 10), dialValue(22 * 60 + 30, .hour, false)); // 12h keeps 10
    // the 24h ring selection: the outer ring (>= 74dp) → 0..11, the inner → 12..23
    try std.testing.expectEqual(@as(i32, 3), valueAtAngle(0, 0, 101, 0, .hour, true)); // outer 3 o'clock
    try std.testing.expectEqual(@as(i32, 15), valueAtAngle(0, 0, 69, 0, .hour, true)); // inner 3 o'clock
    try std.testing.expectEqual(@as(i32, 0), valueAtAngle(0, 0, 0, -74, .hour, true)); // the top, at MaxDistance → outer
    try std.testing.expectEqual(label_ring, selectorRing(3, .hour, true));
    try std.testing.expectEqual(inner_label_ring, selectorRing(15, .hour, true));
    try std.testing.expectEqual(label_ring, selectorRing(10, .hour, false)); // 12h: a single ring
}

test "time_picker: measures the 360x464 M3E panel" {
    const a = std.testing.allocator;
    const f = try tpFixture(a);
    defer f[1].deinit();
    defer f[0].deinit();
    const m = f[0].measure(.{ .max_w = 1000, .max_h = 1000 });
    try std.testing.expectEqual(@as(f32, 360), m.w);
    try std.testing.expectEqual(total_h, m.h);
}

test "time_picker: the plates switch the dial mode; AM/PM flips the period; OK/Cancel fire" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const f = try tpFixture(a);
    defer f[1].deinit();
    defer f[0].deinit();
    const n = f[0];
    var ok_fired: u32 = 0;
    var cancel_fired: u32 = 0;
    const s = stateOf(n);
    s.on_select = .{ .fn_ptr = countCb, .userdata = &ok_fired };
    s.on_cancel = .{ .fn_ptr = countCb, .userdata = &cancel_fired };
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    try std.testing.expectEqual(DialMode.hour, dialMode(n));
    const tap = struct {
        fn go(r: *input.InputRouter, node: *Node, rct: Rect) void {
            const cx = rct.x + rct.w / 2;
            const cy = rct.y + rct.h / 2;
            r.dispatchPointer(node, .{ .phase = .down, .x = cx, .y = cy, .raw_x = cx, .raw_y = cy });
            r.dispatchPointer(node, .{ .phase = .up, .x = cx, .y = cy, .raw_x = cx, .raw_y = cy });
        }
    }.go;
    // the minute plate → minute mode
    tap(&router, n, plateRect(n.bounds, .minute, false));
    try std.testing.expectEqual(DialMode.minute, dialMode(n));
    // the hour plate → back to hour mode
    tap(&router, n, plateRect(n.bounds, .hour, false));
    try std.testing.expectEqual(DialMode.hour, dialMode(n));
    // PM: 10:30 AM → 22:30 (the signal round-trips) — tap the PM half's
    // center (the toggle's exact vertical center is the AM/PM boundary → .pm)
    const pr = periodRect(n.bounds);
    const px = pr.x + pr.w / 2;
    const py = pr.y + pr.h * 3 / 4; // PM = bottom half
    router.dispatchPointer(n, .{ .phase = .down, .x = px, .y = py, .raw_x = px, .raw_y = py });
    router.dispatchPointer(n, .{ .phase = .up, .x = px, .y = py, .raw_x = px, .raw_y = py });
    try std.testing.expectEqual(@as(i32, 22 * 60 + 30), f[1].peek());
    try std.testing.expectEqual(@as(i32, 1350), timeMinutes(n));
    try std.testing.expectEqualStrings("10:30 PM", n.semantics.?.value);
    // AM: back — tap the AM half's center
    const ay = pr.y + pr.h / 4; // AM = top half
    router.dispatchPointer(n, .{ .phase = .down, .x = px, .y = ay, .raw_x = px, .raw_y = ay });
    router.dispatchPointer(n, .{ .phase = .up, .x = px, .y = ay, .raw_x = px, .raw_y = ay });
    try std.testing.expectEqual(@as(i32, 630), f[1].peek());
    // the footer
    const fr = footerRects(n);
    tap(&router, n, fr.cancel);
    try std.testing.expectEqual(@as(u32, 1), cancel_fired);
    tap(&router, n, fr.ok);
    try std.testing.expectEqual(@as(u32, 1), ok_fired);
}

fn countCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "time_picker: tapping + dragging the dial selects by angle (hour + minute modes)" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const f = try tpFixture(a);
    defer f[1].deinit();
    defer f[0].deinit();
    const n = f[0];
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    const c = dialCenter(n);
    // hour mode: tap straight up (the top) → 12 o'clock; the picker is in AM
    // (10:30) so 12 means 12 AM = midnight → 00:30 = 30
    router.dispatchPointer(n, .{ .phase = .down, .x = c[0], .y = c[1] - 101, .raw_x = c[0], .raw_y = c[1] - 101 });
    try std.testing.expectEqual(@as(i32, 30), f[1].peek());
    // keep dragging (the dial owns the move): drag to the right (3 o'clock) → 3
    router.dispatchPointer(n, .{ .phase = .move, .x = c[0] + 101, .y = c[1], .raw_x = c[0] + 101, .raw_y = c[1] });
    try std.testing.expectEqual(@as(i32, 3 * 60 + 30), f[1].peek());
    router.dispatchPointer(n, .{ .phase = .up, .x = c[0] + 101, .y = c[1], .raw_x = c[0] + 101, .raw_y = c[1] });
    // minute mode: tap straight down → minute 30 (3:30 → 3:30? hour stays 3)
    const s = stateOf(n);
    s.mode = .minute;
    router.dispatchPointer(n, .{ .phase = .down, .x = c[0], .y = c[1] + 101, .raw_x = c[0], .raw_y = c[1] + 101 });
    try std.testing.expectEqual(@as(i32, 3 * 60 + 30), f[1].peek());
    // drag to the right → minute 15
    router.dispatchPointer(n, .{ .phase = .move, .x = c[0] + 101, .y = c[1], .raw_x = c[0] + 101, .raw_y = c[1] });
    try std.testing.expectEqual(@as(i32, 3 * 60 + 15), f[1].peek());
    router.dispatchPointer(n, .{ .phase = .up, .x = c[0] + 101, .y = c[1], .raw_x = c[0] + 101, .raw_y = c[1] });
    // a tap outside the dial circle (the square's corner) does nothing
    router.dispatchPointer(n, .{ .phase = .down, .x = c[0] + 120, .y = c[1] + 120, .raw_x = c[0] + 120, .raw_y = c[1] + 120 });
    router.dispatchPointer(n, .{ .phase = .up, .x = c[0] + 120, .y = c[1] + 120, .raw_x = c[0] + 120, .raw_y = c[1] + 120 });
    try std.testing.expectEqual(@as(i32, 3 * 60 + 15), f[1].peek());
}

test "time_picker: the 24h dial is a dual ring (outer 0..11, inner 12..23)" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(i32).init(a, 630); // 10:30
    defer sig.deinit();
    // the ring-geometry test taps the hour dial repeatedly — hold it in the
    // hour mode (upstream autoSwitchToMinute would advance after each pick)
    const n = try timePicker(a, sig, null, null, .{ .is_24h = true, .auto_switch_to_minute = false });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    const c = dialCenter(n);
    const tap = struct {
        fn go(r: *input.InputRouter, node: *Node, x: f32, y: f32) void {
            r.dispatchPointer(node, .{ .phase = .down, .x = x, .y = y, .raw_x = x, .raw_y = y });
            r.dispatchPointer(node, .{ .phase = .up, .x = x, .y = y, .raw_x = x, .raw_y = y });
        }
    }.go;
    // the OUTER ring at 3 o'clock (radius 101 >= MaxDistance 74) → 03:30
    tap(&router, n, c[0] + 101, c[1]);
    try std.testing.expectEqual(@as(i32, 3 * 60 + 30), sig.peek());
    // the INNER ring at 3 o'clock (radius 69 < 74) → 15:30
    tap(&router, n, c[0] + 69, c[1]);
    try std.testing.expectEqual(@as(i32, 15 * 60 + 30), sig.peek());
    // the boundary distance (74) picks the outer ring: the top → 00:30
    tap(&router, n, c[0], c[1] - 74);
    try std.testing.expectEqual(@as(i32, 30), sig.peek());
    // the a11y value follows (24h format)
    try std.testing.expectEqualStrings("00:30", n.semantics.?.value);
}

test "time_picker: releasing an hour-dial gesture auto-switches to the minute dial" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(i32).init(a, 630); // 10:30
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{}); // auto_switch_to_minute = true
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    const c = dialCenter(n);
    try std.testing.expectEqual(DialMode.hour, dialMode(n));
    // a tap on the hour dial: selects AND advances (upstream onTap)
    router.dispatchPointer(n, .{ .phase = .down, .x = c[0] + 101, .y = c[1], .raw_x = c[0] + 101, .raw_y = c[1] });
    router.dispatchPointer(n, .{ .phase = .up, .x = c[0] + 101, .y = c[1], .raw_x = c[0] + 101, .raw_y = c[1] });
    try std.testing.expectEqual(@as(i32, 3 * 60 + 30), sig.peek()); // 3 selected
    try std.testing.expectEqual(DialMode.minute, dialMode(n));
    // a minute-dial tap stays in minute mode
    router.dispatchPointer(n, .{ .phase = .down, .x = c[0], .y = c[1] - 101, .raw_x = c[0], .raw_y = c[1] - 101 });
    router.dispatchPointer(n, .{ .phase = .up, .x = c[0], .y = c[1] - 101, .raw_x = c[0], .raw_y = c[1] - 101 });
    try std.testing.expectEqual(DialMode.minute, dialMode(n));
    try std.testing.expectEqual(@as(i32, 3 * 60), sig.peek()); // minute 00
    // back to hour via the plate: the hour plate restores the hour dial
    const hp = plateRect(n.bounds, .hour, false);
    router.dispatchPointer(n, .{ .phase = .down, .x = hp.x + 4, .y = hp.y + 4, .raw_x = hp.x + 4, .raw_y = hp.y + 4 });
    router.dispatchPointer(n, .{ .phase = .up, .x = hp.x + 4, .y = hp.y + 4, .raw_x = hp.x + 4, .raw_y = hp.y + 4 });
    try std.testing.expectEqual(DialMode.hour, dialMode(n));
    // a drag ending on the hour dial also advances (upstream onDragEnd)
    router.dispatchPointer(n, .{ .phase = .down, .x = c[0] + 101, .y = c[1], .raw_x = c[0] + 101, .raw_y = c[1] });
    router.dispatchPointer(n, .{ .phase = .move, .x = c[0], .y = c[1] + 101, .raw_x = c[0], .raw_y = c[1] + 101 });
    router.dispatchPointer(n, .{ .phase = .up, .x = c[0], .y = c[1] + 101, .raw_x = c[0], .raw_y = c[1] + 101 });
    try std.testing.expectEqual(DialMode.minute, dialMode(n));
}

test "time_picker: the app drives the time (two-way signal, clamped)" {
    const a = std.testing.allocator;
    const f = try tpFixture(a);
    defer f[1].deinit();
    defer f[0].deinit();
    const n = f[0];
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    f[1].set(22 * 60 + 5); // 22:05
    try std.testing.expectEqual(@as(i32, 1325), timeMinutes(n));
    try std.testing.expectEqualStrings("10:05 PM", n.semantics.?.value);
    f[1].set(-10); // clamped to 00:00
    try std.testing.expectEqual(@as(i32, 0), timeMinutes(n));
    try std.testing.expectEqualStrings("12:00 AM", n.semantics.?.value);
}

test "golden: the M3E time picker panel (plates, period toggle, dial knob + hand, footer)" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const f = try tpFixture(a); // 10:30 AM, hour mode
    defer f[1].deinit();
    defer f[0].deinit();
    const n = f[0];
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    var r = try golden.Renderer.init(a, 360, 464);
    defer r.deinit();
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(a);
    defer f2.deinit();
    // the container (SurfaceContainerHigh)
    try std.testing.expectEqual(t.colors.surface_container_high, f2.pixelAt(180, 5));
    // the hour plate (active): PrimaryContainer fill, inside the 2dp border
    const hp = plateRect(n.bounds, .hour, false);
    try std.testing.expectEqual(t.colors.primary_container, f2.pixelAt(@intFromFloat(hp.x + 12), @intFromFloat(hp.y + 12)));
    // the minute plate (inactive): SurfaceContainerHighest
    const mp = plateRect(n.bounds, .minute, false);
    try std.testing.expectEqual(t.colors.surface_container_highest, f2.pixelAt(@intFromFloat(mp.x + 12), @intFromFloat(mp.y + 12)));
    // the period toggle: 10:30 is AM → the AM half is TertiaryContainer
    // (sample above the "AM" label ink, inside the rounded fill)
    const pr = periodRect(n.bounds);
    try std.testing.expectEqual(t.colors.tertiary_container, f2.pixelAt(@intFromFloat(pr.x + 26), @intFromFloat(pr.y + 4)));
    // the dial fill (SurfaceContainerHighest) between the center and the ring
    const d = dialRect(n.bounds);
    const cx = @as(i32, @intFromFloat(d.x + d.w / 2));
    const cy = @as(i32, @intFromFloat(d.y + d.h / 2));
    try std.testing.expectEqual(t.colors.surface_container_highest, f2.pixelAt(cx, cy - 60));
    // the knob: 10 o'clock → angle 210° → the knob center at radius 101
    // (92.5, 209.5); sample inside the 48dp knob, away from the "10" label
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(cx - 103, cy - 51));
    // the center dot (8dp Primary)
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(cx, cy - 2));
    // the footer: the OK label (Primary ink)
    const fr = footerRects(n);
    try std.testing.expect(f2.countColorApproxIn(fr.ok, t.colors.primary) > 0);
}

test "golden: the M3E time picker panel in 24h mode (dual-ring dial, inner knob)" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    // 15:30, 24h → the knob sits on the INNER ring (69dp) at 3 o'clock
    const sig = try ui.state.Signal(i32).init(a, 15 * 60 + 30);
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{ .is_24h = true });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    var r = try golden.Renderer.init(a, 360, 464);
    defer r.deinit();
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(a);
    defer f2.deinit();
    // the container (SurfaceContainerHigh)
    try std.testing.expectEqual(t.colors.surface_container_high, f2.pixelAt(180, 5));
    // the hour plate (active): "15" (OnPrimaryContainer ink on PrimaryContainer)
    const hp = plateRect(n.bounds, .hour, true);
    try std.testing.expectEqual(t.colors.primary_container, f2.pixelAt(@intFromFloat(hp.x + 12), @intFromFloat(hp.y + 12)));
    try std.testing.expect(f2.countColorApproxIn(hp, t.colors.on_primary_container) > 0);
    // no period toggle in 24h: the dial's left edge is clear at the header's
    // right side (the row is narrower — nothing painted past the minute plate)
    const mp = plateRect(n.bounds, .minute, true);
    try std.testing.expectEqual(t.colors.surface_container_high, f2.pixelAt(@intFromFloat(mp.x + mp.w + 10), @intFromFloat(mp.y + mp.h / 2)));
    // the inner knob (Primary) at 3 o'clock on the inner ring, away from the
    // "15" label ink (below it, still inside the 48dp knob)
    const d = dialRect(n.bounds);
    const cx = @as(i32, @intFromFloat(d.x + d.w / 2));
    const cy = @as(i32, @intFromFloat(d.y + d.h / 2));
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(cx + 69, cy + 15));
    // the outer ring's "03" label (OnSurface ink) at 3 o'clock on the outer ring
    try std.testing.expect(f2.countColorApproxIn(.{ .x = @floatFromInt(cx + 101 - 20), .y = @floatFromInt(cy - 12), .w = 40, .h = 24 }, t.colors.on_surface) > 0);
    // the inner ring's "15" label is on the knob (OnPrimary ink)
    try std.testing.expect(f2.countColorApproxIn(.{ .x = @floatFromInt(cx + 69 - 20), .y = @floatFromInt(cy - 12), .w = 40, .h = 24 }, t.colors.on_primary) > 0);
}

test "time_picker: the input variant — tap a field, type digits, the time updates" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(i32).init(a, 630); // 10:30 AM
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{ .mode = .input });
    defer n.deinit();
    const s = stateOf(n);
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = inputTotalH(s.opts.theme) });
    // the fields seeded from the signal (canonical "%02d")
    try std.testing.expectEqualStrings("10", s.hour_edit.text());
    try std.testing.expectEqualStrings("30", s.minute_edit.text());
    // tap the SELECTED (hour) field → it focuses + lands the caret at the
    // tap point (a real text-field tap, upstream restore-only semantics)
    const hr = inputFieldRect(n.bounds, .hour, false);
    const hcx = hr.x + hr.w / 2;
    const hcy = hr.y + hr.h / 2;
    router.dispatchPointer(n, .{ .phase = .down, .x = hcx, .y = hcy, .raw_x = hcx, .raw_y = hcy });
    router.dispatchPointer(n, .{ .phase = .up, .x = hcx, .y = hcy, .raw_x = hcx, .raw_y = hcy });
    try std.testing.expect(input.isFocused(n));
    try std.testing.expectEqual(DialMode.hour, s.mode);
    // a digit into the full "10" rolls it to just that digit (upstream
    // isReplacingTwoDigits) — a rolled digit is NOT an inserted one, so no
    // auto-advance: 03:30, the hour field stays selected
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "3" });
    try std.testing.expectEqualStrings("3", s.hour_edit.text());
    try std.testing.expectEqual(@as(i32, 3 * 60 + 30), sig.peek());
    try std.testing.expectEqual(DialMode.hour, s.mode);
    // backspace empties the field → commits the period's zero (00:30),
    // then a lone 2 auto-advances to the minute field (upstream's
    // is12HourAutoAdvanceDigit for 2..9)
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .backspace });
    try std.testing.expectEqualStrings("", s.hour_edit.text());
    try std.testing.expectEqual(@as(i32, 30), sig.peek());
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "2" });
    try std.testing.expectEqual(@as(i32, 2 * 60 + 30), sig.peek());
    try std.testing.expectEqual(DialMode.minute, s.mode); // auto-advance
    // "4" rolls the full minute field to just the digit, "5" appends →
    // "45" → 02:45
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "4" });
    try std.testing.expectEqualStrings("4", s.minute_edit.text());
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "5" });
    try std.testing.expectEqual(@as(i32, 2 * 60 + 45), sig.peek());
    try std.testing.expectEqualStrings("45", s.minute_edit.text());
}

test "time_picker: the input variant rejects non-digits, keeps out-of-range as an error state" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(i32).init(a, 630);
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{ .mode = .input });
    defer n.deinit();
    const s = stateOf(n);
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = inputTotalH(s.opts.theme) });
    selectField(n, s, .minute);
    // a letter is reverted (upstream revertAllChanges)
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "x" });
    try std.testing.expectEqualStrings("30", s.minute_edit.text());
    // a digit typed into the full field rolls it to just that digit
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "7" });
    try std.testing.expectEqualStrings("7", s.minute_edit.text());
    try std.testing.expectEqual(@as(i32, 10 * 60 + 7), sig.peek());
    // a second digit makes "77" — out of range: the text stays (the error
    // state) but the committed time doesn't move (upstream minuteInput)
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "7" });
    try std.testing.expectEqualStrings("77", s.minute_edit.text());
    try std.testing.expectEqual(@as(i32, 10 * 60 + 7), sig.peek());
    try std.testing.expect(fieldInvalid(s, .minute));
    // typing a digit into the full (invalid) field rolls again → valid :07
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "7" });
    try std.testing.expectEqualStrings("7", s.minute_edit.text());
    try std.testing.expect(!fieldInvalid(s, .minute));
}

test "time_picker: the mode toggle swaps variants + reseeds the fields" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(i32).init(a, 630);
    defer sig.deinit();
    // mode_toggle = true pins the affordance on the dial variant too
    const n = try timePicker(a, sig, null, null, .{ .mode_toggle = true });
    defer n.deinit();
    const s = stateOf(n);
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    try std.testing.expect(s.variant == .dial);
    const tr = modeToggleRect(n);
    const tx = tr.x + tr.w / 2;
    const ty = tr.y + tr.h / 2;
    router.dispatchPointer(n, .{ .phase = .down, .x = tx, .y = ty, .raw_x = tx, .raw_y = ty });
    router.dispatchPointer(n, .{ .phase = .up, .x = tx, .y = ty, .raw_x = tx, .raw_y = ty });
    try std.testing.expect(s.variant == .input);
    try std.testing.expect(input.isFocused(n)); // entering input focuses a field
    try std.testing.expectEqualStrings("10", s.hour_edit.text());
    // back to the dial drops the focus — the footer moved (the input
    // variant is shorter), so re-layout + retap at the new toggle rect
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = inputTotalH(s.opts.theme) });
    const tr2 = modeToggleRect(n);
    const tx2 = tr2.x + tr2.w / 2;
    const ty2 = tr2.y + tr2.h / 2;
    router.dispatchPointer(n, .{ .phase = .down, .x = tx2, .y = ty2, .raw_x = tx2, .raw_y = ty2 });
    router.dispatchPointer(n, .{ .phase = .up, .x = tx2, .y = ty2, .raw_x = tx2, .raw_y = ty2 });
    try std.testing.expect(s.variant == .dial);
    try std.testing.expect(!input.isFocused(n));
}

/// Dispatch a down+up tap inside a rect (window-space coords).
fn tapRect(r: *input.InputRouter, n: *Node, rct: Rect) void {
    const cx = rct.x + rct.w / 2;
    const cy = rct.y + rct.h / 2;
    r.dispatchPointer(n, .{ .phase = .down, .x = cx, .y = cy, .raw_x = cx, .raw_y = cy });
    r.dispatchPointer(n, .{ .phase = .up, .x = cx, .y = cy, .raw_x = cx, .raw_y = cy });
}

test "time_picker: the input variant — a tap on the unselected field selects it; Enter advances" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(i32).init(a, 630);
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{ .mode = .input });
    defer n.deinit();
    const s = stateOf(n);
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = inputTotalH(s.opts.theme) });
    // a tap on the UNSELECTED (minute) field swaps the selection — the
    // field keeps its own caret (no select-all)
    tapRect(&router, n, inputFieldRect(n.bounds, .minute, false));
    try std.testing.expectEqual(DialMode.minute, s.mode);
    try std.testing.expect(input.isFocused(n));
    const sel = s.minute_edit.selRange();
    try std.testing.expectEqual(sel.lo, sel.hi); // a collapsed caret, not select-all
    // Enter on the minute field = ImeAction.Done → blur
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .enter });
    try std.testing.expect(!input.isFocused(n));
    // re-focus the hour field; Enter = ImeAction.Next → the minute field
    tapRect(&router, n, inputFieldRect(n.bounds, .hour, false));
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(DialMode.minute, s.mode);
    // an INVALID hour blocks ImeAction.Next (upstream isHourInputValid
    // gate) — a multi-char insert lands "19" at once (hourInput 19 → the
    // error state, the committed time untouched)
    tapRect(&router, n, inputFieldRect(n.bounds, .hour, false));
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .unknown, .chr = 'a', .command = true });
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "19" });
    try std.testing.expectEqualStrings("19", s.hour_edit.text());
    try std.testing.expect(fieldInvalid(s, .hour));
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(DialMode.hour, s.mode); // no advance
}

test "time_picker: the input variant — shouldSwitchFocusToMinute lands the digit in the minute field" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(i32).init(a, 630); // 10:30 AM, hour "10" full + valid
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{ .mode = .input });
    defer n.deinit();
    const s = stateOf(n);
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = inputTotalH(s.opts.theme) });
    selectField(n, s, .hour);
    s.hour_edit.moveCaret(2, false); // caret at the end of "10"
    // a digit at the end of a complete VALID hour hops to the minute field
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "5" });
    try std.testing.expectEqual(DialMode.minute, s.mode);
    // the digit rolled the full minute field to just "5" → 10:05
    try std.testing.expectEqualStrings("5", s.minute_edit.text());
    try std.testing.expectEqual(@as(i32, 10 * 60 + 5), sig.peek());
}

test "time_picker: the input variant — an emptied field commits the period's zero" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(i32).init(a, 22 * 60 + 30); // 10:30 PM
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{ .mode = .input });
    defer n.deinit();
    const s = stateOf(n);
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = inputTotalH(s.opts.theme) });
    // emptying the PM hour field inputs+commits 12 PM (upstream target=12)
    selectField(n, s, .hour);
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .unknown, .chr = 'a', .command = true });
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .backspace });
    try std.testing.expectEqualStrings("", s.hour_edit.text());
    try std.testing.expectEqual(@as(i32, 12 * 60 + 30), sig.peek());
    // emptying the minute field commits :00
    selectField(n, s, .minute);
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .unknown, .chr = 'a', .command = true });
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .backspace });
    try std.testing.expectEqual(@as(i32, 12 * 60), sig.peek());
}

test "time_picker: the input variant — AM/PM is gated on a valid hour input" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(i32).init(a, 630); // 10:30 AM
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{ .mode = .input });
    defer n.deinit();
    const s = stateOf(n);
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = inputTotalH(s.opts.theme) });
    const pr = inputPeriodRect(n.bounds);
    const pm_r = Rect{ .x = pr.x, .y = pr.y + pr.h / 2, .w = pr.w, .h = pr.h / 2 };
    const am_r = Rect{ .x = pr.x, .y = pr.y, .w = pr.w, .h = pr.h / 2 };
    // PM: hour += 12 on the committed time → 22:30; the hour field re-syncs
    tapRect(&router, n, pm_r);
    try std.testing.expectEqual(@as(i32, 22 * 60 + 30), sig.peek());
    try std.testing.expectEqualStrings("10", s.hour_edit.text()); // hour12 stays "10"
    // an invalid hour input blocks the period toggle entirely (upstream)
    // — "19" in PM inputs 19+12 = 31 on the 24h scale (a multi-char insert
    // lands both digits at once, so no intermediate commit)
    selectField(n, s, .hour);
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .unknown, .chr = 'a', .command = true });
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "19" });
    try std.testing.expect(fieldInvalid(s, .hour));
    tapRect(&router, n, am_r);
    try std.testing.expectEqual(@as(i32, 22 * 60 + 30), sig.peek()); // unchanged
    // a valid hour input re-enables it: "10" (PM → 22:30) → AM → 10:30
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .unknown, .chr = 'a', .command = true });
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "10" });
    try std.testing.expect(!fieldInvalid(s, .hour));
    tapRect(&router, n, am_r);
    try std.testing.expectEqual(@as(i32, 10 * 60 + 30), sig.peek());
    try std.testing.expectEqualStrings("10", s.hour_edit.text());
}

test "time_picker: the input variant — 24h hours accept 0..23; external signal changes re-sync the fields" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(i32).init(a, 15 * 60 + 30); // 15:30
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{ .mode = .input, .is_24h = true });
    defer n.deinit();
    const s = stateOf(n);
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = inputTotalH(s.opts.theme) });
    try std.testing.expectEqualStrings("15", s.hour_edit.text());
    try std.testing.expectEqualStrings("30", s.minute_edit.text());
    // no period toggle in 24h — and only 3 a11y children (fields + toggle)
    try std.testing.expectEqual(@as(usize, 3), n.semantics.?.children.len);
    // "23" is a valid 24h hour (a complete field → auto-advance)
    selectField(n, s, .hour); // focuses the node
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .unknown, .chr = 'a', .command = true });
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "23" });
    try std.testing.expectEqual(@as(i32, 23 * 60 + 30), sig.peek());
    try std.testing.expectEqual(DialMode.minute, s.mode);
    // "24" isn't — an error state, no commit
    selectField(n, s, .hour);
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .unknown, .chr = 'a', .command = true });
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "24" });
    try std.testing.expect(fieldInvalid(s, .hour));
    try std.testing.expectEqual(@as(i32, 23 * 60 + 30), sig.peek());
    // an external change re-syncs BOTH fields (canonical text, clears the
    // error) — upstream's LaunchedEffect on state.hour/state.minute
    sig.set(8 * 60 + 5);
    try std.testing.expectEqualStrings("08", s.hour_edit.text());
    try std.testing.expectEqualStrings("05", s.minute_edit.text());
    try std.testing.expect(!fieldInvalid(s, .hour));
    try std.testing.expectEqualStrings("08:05", n.semantics.?.value);
}

test "time_picker: the input variant — the a11y children carry the field values + the period state" {
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(i32).init(a, 630); // 10:30 AM
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{ .mode = .input });
    defer n.deinit();
    const s = stateOf(n);
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = inputTotalH(s.opts.theme) });
    // the input variant's group: 5 virtual children (hour, minute, AM, PM,
    // mode toggle)
    const sem = n.semantics.?;
    try std.testing.expectEqual(@as(usize, 5), sem.children.len);
    // the selected field is the text field ("for hour"); the other is the
    // TimeSelector radio ("Minute selection")
    try std.testing.expectEqual(ui.semantics.Role.text_field, sem.children[0].role);
    try std.testing.expectEqualStrings("for hour", sem.children[0].label);
    try std.testing.expectEqualStrings("10", sem.children[0].value);
    try std.testing.expect(sem.children[0].focusable);
    try std.testing.expectEqual(ui.semantics.Role.radio, sem.children[1].role);
    try std.testing.expectEqualStrings("Minute selection", sem.children[1].label);
    try std.testing.expectEqualStrings("30", sem.children[1].value);
    try std.testing.expect(!sem.children[1].focusable);
    try std.testing.expect(sem.children[2].checked.?); // AM
    try std.testing.expect(!sem.children[3].checked.?); // PM
    try std.testing.expectEqualStrings("Switch to clock", sem.children[4].label);
    // the child bounds are the field/toggle rects in local space
    const hb = sem.child_bounds.?(n, 0);
    const hr = inputFieldRect(n.bounds, .hour, false);
    try std.testing.expectEqual(hr.x - n.bounds.x, hb.x);
    try std.testing.expectEqual(hr.y - n.bounds.y, hb.y);
}

test "time_picker: i18n — labels, the period toggle and the a11y value localize + re-resolve on a locale switch" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es",
        \\{"@@locale": "es", "Time picker": "Selector de hora", "Hour selection": "Selección de hora",
        \\ "Minute selection": "Selección de minutos", "for hour": "para la hora",
        \\ "Switch to clock": "Cambiar al reloj"}
    , .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const sig = try ui.state.Signal(i32).init(a, 810); // 13:30 = 1:30 PM
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{ .mode = .input });
    defer n.deinit();
    const s = stateOf(n);
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = inputTotalH(s.opts.theme) });
    const sem = n.semantics.?;
    // the root label + the virtual children resolve through tr()
    try std.testing.expectEqualStrings("Selector de hora", sem.label);
    try std.testing.expectEqualStrings("para la hora", sem.children[0].label);
    try std.testing.expectEqualStrings("Selección de minutos", sem.children[1].label);
    // the AM/PM halves come from the es day-period CLDR data
    try std.testing.expectEqualStrings("a.m.", sem.children[2].label);
    try std.testing.expectEqualStrings("p.m.", sem.children[3].label);
    try std.testing.expectEqualStrings("Cambiar al reloj", sem.children[4].label);
    // the a11y value's day-period literal localizes too
    try std.testing.expectEqualStrings("01:30 p.m.", sem.value);
    // support strings resolve in the active locale (untranslated → the en literal)
    try std.testing.expectEqualStrings("Hour", supportLine(s, .hour, 0).?);
    // a locale switch re-resolves: the children + the a11y value rebuild
    try i18n.setLocale("en");
    const sem2 = n.semantics.?; // re-attached by the locale callback
    try std.testing.expectEqualStrings("Time picker", sem2.label);
    try std.testing.expectEqualStrings("for hour", sem2.children[0].label);
    try std.testing.expectEqualStrings("AM", sem2.children[2].label);
    try std.testing.expectEqualStrings("PM", sem2.children[3].label);
    try std.testing.expectEqualStrings("Switch to clock", sem2.children[4].label);
    try std.testing.expectEqualStrings("01:30 PM", sem2.value);
}

test "golden: the input variant (editable box, borderless plate, period toggle, supporting text)" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(i32).init(a, 630); // 10:30 AM
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{ .mode = .input });
    defer n.deinit();
    const total = inputTotalH(t);
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total });
    var r = try golden.Renderer.init(a, 360, @intFromFloat(total));
    defer r.deinit();
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(a);
    defer f2.deinit();
    // the container (SurfaceContainerHigh)
    try std.testing.expectEqual(t.colors.surface_container_high, f2.pixelAt(180, 5));
    // the SELECTED (hour) field: SurfaceContainerHighest + the Outline
    // border (unfocused — no InputRouter in this test) + the DisplayMedium text
    const hr = inputFieldRect(n.bounds, .hour, false);
    try std.testing.expectEqual(t.colors.surface_container_highest, f2.pixelAt(@intFromFloat(hr.x + hr.w / 2), @intFromFloat(hr.y + hr.h / 2)));
    // the border pixel: Outline
    try std.testing.expect(f2.countColorApproxIn(hr, t.colors.outline) > 0);
    // the UNSELECTED (minute) field: the borderless plate —
    // SurfaceContainerHighest with NO Outline border anywhere inside
    const mr = inputFieldRect(n.bounds, .minute, false);
    try std.testing.expectEqual(t.colors.surface_container_highest, f2.pixelAt(@intFromFloat(mr.x + mr.w / 2), @intFromFloat(mr.y + mr.h / 2)));
    try std.testing.expect(f2.countColorApproxIn(mr, t.colors.on_surface) > 0); // the "30" ink
    // the period toggle: AM selected → TertiaryContainer top half
    const pr = inputPeriodRect(n.bounds);
    try std.testing.expectEqual(t.colors.tertiary_container, f2.pixelAt(@intFromFloat(pr.x + 26), @intFromFloat(pr.y + 4)));
    // the supporting text ("Hour"/"Minute"): OnSurfaceVariant ink under each field
    const sup = supportRect(n.bounds, .hour, false, 0, t);
    try std.testing.expect(f2.countColorApproxIn(sup, t.colors.on_surface_variant) > 0);
    // the mode toggle: the clock glyph's OnSurfaceVariant ink at the
    // footer's leading edge
    const tr = modeToggleRect(n);
    try std.testing.expect(f2.countColorApproxIn(tr, t.colors.on_surface_variant) > 0);
}

test "golden: the input variant's error state (ErrorContainer + error supporting text)" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const sig = try ui.state.Signal(i32).init(a, 630); // 10:30 AM
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{ .mode = .input });
    defer n.deinit();
    const s = stateOf(n);
    const total = inputTotalH(t);
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total });
    // an invalid minute input → the error container + the error text
    selectField(n, s, .minute);
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .unknown, .chr = 'a', .command = true });
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "9" });
    _ = n.vtable.on_key.?(n, .{ .kind = .text_input, .text = "9" });
    try std.testing.expect(fieldInvalid(s, .minute));
    var r = try golden.Renderer.init(a, 360, @intFromFloat(total));
    defer r.deinit();
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(a);
    defer f2.deinit();
    // the minute field: ErrorContainer fill + the Error border
    const mr = inputFieldRect(n.bounds, .minute, false);
    try std.testing.expectEqual(t.colors.error_container, f2.pixelAt(@intFromFloat(mr.x + mr.w / 2), @intFromFloat(mr.y + mr.h / 2)));
    try std.testing.expect(f2.countColorApproxIn(mr, t.colors.@"error") > 0);
    // the error supporting text (Error ink) under the field
    const sup = supportRect(n.bounds, .minute, false, 0, t);
    try std.testing.expect(f2.countColorApproxIn(sup, t.colors.@"error") > 0);
    // the hour field is untouched: SurfaceContainerHighest, no error text
    const hs = supportRect(n.bounds, .hour, false, 0, t);
    try std.testing.expect(f2.countColorApproxIn(hs, t.colors.on_surface_variant) > 0);
}
