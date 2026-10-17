// TextEdit — the shared single-line editing core for the text widgets
// (text_field, search_bar, search_view): the null-terminated UTF-8 buffer,
// the IME composition (preedit) buffer, the caret/selection model, the
// 500ms blink ticker, and the editing operations — insert at caret, range
// deletes, grapheme-cluster arrows/home/end, Cmd/Ctrl+A/C/X/V chords.
//
// The widget owns the GEOMETRY (where the run paints → caretFromPoint's
// run origin) and the edit follow-ups (layout dirty, signal mirror, a11y
// notify, on_changed) through the `apply_edit` callback — this module owns
// the buffer/offsets/blink that must behave identically everywhere.
const std = @import("std");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");

const Node = ui.node.Node;

/// Compose's caret cadence (a fixed 500ms half-period; re-shown on edits).
pub const blink_half_ms: u64 = 500;
/// Double-tap window — ViewConfiguration.getDoubleTapTimeout (300ms) with
/// the standard touch slop between the two taps.
pub const double_tap_ms: u64 = 300;
const tap_slop: f32 = 12;

pub const Edit = struct {
    buf: std.array_list.Managed(u8), // kept null-terminated: items[len] == 0
    /// IME composition (preedit) — text_editing replaces it wholesale; the
    /// next text_input commits into `buf` and clears it.
    comp: std.array_list.Managed(u8),
    /// SDL's cursor offset inside `comp` (bytes, text_editing comp_start).
    comp_cursor: i32 = 0,
    /// The caret: a byte offset into `buf` on a codepoint boundary.
    caret: usize = 0,
    /// The selection anchor — the frozen end of the range; the caret is the
    /// moving end. anchor == caret → collapsed (no highlight).
    sel_anchor: usize = 0,
    /// Primary-button drag in progress (extends the selection).
    dragging: bool = false,
    /// A word-select double-tap armed word-granular drag (the move handler
    /// extends to whole-word edges, like upstream's word-drag). Cleared on
    /// the next plain tap.
    drag_word: bool = false,
    /// Double-tap tracking: the previous tap's timestamp + screen spot.
    last_tap_ms: u64 = 0,
    last_tap_x: f32 = 0,
    last_tap_y: f32 = 0,
    /// The blink clock: `caret_on` is the painted phase; `blink_epoch` is
    /// the tick-time the ON phase started — maxInt = "re-base at the next
    /// tick" (set by every caret event, whose KeyEvent has no timestamp).
    caret_on: bool = true,
    blink_epoch: u64 = std.math.maxInt(u64),
    /// The blink ticker — registered lazily (a widget built before the host
    /// installs its timeline retries at the first paint), removed at deinit.
    ticker: ?ui.anim.Timeline.Ticker = null,
    /// The owning node — the tick/move callbacks mark it dirty.
    node: ?*Node = null,

    pub fn init(allocator: std.mem.Allocator, node: *Node) Edit {
        return .{
            .buf = std.array_list.Managed(u8).init(allocator),
            .comp = std.array_list.Managed(u8).init(allocator),
            .node = node,
        };
    }

    /// Remove the blink ticker and free both buffers.
    pub fn deinit(e: *Edit) void {
        if (e.ticker) |t| {
            if (ui.anim.timeline()) |tl| tl.removeTicker(t);
        }
        e.buf.deinit();
        e.comp.deinit();
    }

    /// The committed text (borrowed, null-terminated).
    pub fn text(e: *const Edit) [:0]const u8 {
        // A fresh list's items.ptr is undefined — the sentinel slice would
        // dereference it; an empty text needs no sentinel storage.
        if (e.buf.items.len == 0) return "";
        return e.buf.items.ptr[0..e.buf.items.len :0];
    }
    /// The live preedit (borrowed, null-terminated).
    pub fn composition(e: *const Edit) [:0]const u8 {
        if (e.comp.items.len == 0) return "";
        return e.comp.items.ptr[0..e.comp.items.len :0];
    }

    /// The ordered selection range [lo, hi); empty when collapsed.
    pub fn selRange(e: *const Edit) struct { lo: usize, hi: usize } {
        return .{ .lo = @min(e.caret, e.sel_anchor), .hi = @max(e.caret, e.sel_anchor) };
    }

    /// The next grapheme-cluster boundary in `dir` — ICU UBRK_CHARACTER
    /// via the paint backend (emoji, flags and ZWJ sequences stay atomic,
    /// matching Compose's BreakIterator-backed caret). Falls back to a
    /// codepoint step when the backend can't answer.
    pub fn graphemeStep(e: *const Edit, off: usize, dir: i32) usize {
        const items = e.buf.items;
        if (ui.paint.graphemeBoundary(items, @min(off, items.len), dir)) |b| return @min(b, items.len);
        var p = off;
        if (dir >= 0) {
            if (p < items.len) {
                p += 1;
                while (p < items.len and (items[p] & 0xC0) == 0x80) p += 1;
            }
            return p;
        }
        while (p > 0) {
            p -= 1;
            if ((items[p] & 0xC0) != 0x80) break;
        }
        return p;
    }

    /// Delete [lo, hi) from the buffer and collapse the caret onto `lo`.
    /// The caller decides whether this is an edit (applyEdit) or not.
    pub fn deleteRange(e: *Edit, lo: usize, hi: usize) void {
        std.mem.copyForwards(u8, e.buf.items.ptr[lo .. e.buf.items.len - (hi - lo)], e.buf.items[hi..]);
        e.buf.items.len -= hi - lo;
        e.caret = lo;
        e.sel_anchor = lo;
        setSentinel(&e.buf);
    }

    /// Pull caret/anchor back onto codepoint boundaries after an external
    /// set replaced the buffer (upstream clamps the selection into the new
    /// text).
    pub fn clampOffsets(e: *Edit) void {
        for ([2]*usize{ &e.caret, &e.sel_anchor }) |p| {
            p.* = @min(p.*, e.buf.items.len);
            while (p.* > 0 and p.* < e.buf.items.len and (e.buf.items[p.*] & 0xC0) == 0x80) p.* -= 1;
        }
    }

    /// A caret event (move/edit/focus): the caret shows for the next half
    /// period. The epoch re-bases at the next tick (KeyEvent carries no
    /// timestamp — the ticker's now_ms is the only SDL-epoch clock here).
    pub fn resetBlink(e: *Edit) void {
        e.caret_on = true;
        e.blink_epoch = std.math.maxInt(u64);
    }

    /// Move the caret to `pos` clamped onto a codepoint boundary. `extend`
    /// keeps the anchor (shift-arrow / drag selection); otherwise the
    /// anchor collapses onto the caret.
    pub fn moveCaret(e: *Edit, pos: usize, extend: bool) void {
        var p = @min(pos, e.buf.items.len);
        // items[len] is the sentinel slot — outside the slice: only scan
        // continuation bytes strictly inside the text.
        while (p > 0 and p < e.buf.items.len and (e.buf.items[p] & 0xC0) == 0x80) p -= 1;
        if (p == e.caret and (extend or p == e.sel_anchor)) return;
        e.caret = p;
        if (!extend) e.sel_anchor = p;
        e.resetBlink();
        if (e.node) |n| n.markDirty();
    }

    /// A primary press at byte offset `off` (screen x/y feed the tap
    /// slop). A second tap within double_tap_ms and the slop selects the
    /// containing UBRK_WORD segment and arms word-granular drag — the
    /// upstream double-click; a plain tap places the caret and arms the
    /// glyph-granular drag-select. time_ms = 0 means "unstamped" (test
    /// injections) — it can never be a double-tap.
    pub fn tap(e: *Edit, off: usize, x: f32, y: f32, time_ms: u64) void {
        const double = time_ms != 0 and e.last_tap_ms != 0 and
            time_ms -| e.last_tap_ms < double_tap_ms and
            @abs(x - e.last_tap_x) <= tap_slop and @abs(y - e.last_tap_y) <= tap_slop;
        e.last_tap_ms = time_ms;
        e.last_tap_x = x;
        e.last_tap_y = y;
        e.dragging = true;
        if (double) {
            e.drag_word = true;
            e.selectWordAt(off);
            return;
        }
        e.drag_word = false;
        e.moveCaret(off, false);
    }

    /// A press-drag move to byte offset `off` — by word when a double-tap
    /// selected a word, else the plain caret-extend. The anchor is the
    /// FAR edge of the selection once the hovered word lies entirely on
    /// one side — the originally double-clicked word stays covered, like
    /// upstream's word-granular drag.
    pub fn dragExtend(e: *Edit, off: usize) void {
        if (e.drag_word) {
            const items = e.buf.items;
            if (ui.paint.wordRange(items, @min(off, items.len))) |r| {
                const sel = e.selRange();
                if (r.hi <= sel.lo) { // hovered word entirely left of the selection
                    e.sel_anchor = sel.hi;
                    e.caret = r.lo;
                } else if (r.lo >= sel.hi) { // entirely right
                    e.sel_anchor = sel.lo;
                    e.caret = r.hi;
                } else { // overlapping: extend to the word's far edge
                    e.caret = if (r.lo >= e.sel_anchor) r.hi else r.lo;
                }
                e.clampOffsets();
                e.resetBlink();
                if (e.node) |n| n.markDirty();
                return;
            }
        }
        e.moveCaret(off, true);
    }

    /// Select the word-break segment containing `off` (UBRK_WORD —
    /// whitespace and punctuation select as their own segment, matching
    /// upstream getWordBoundary); falls back to a caret move when the
    /// backend can't answer.
    pub fn selectWordAt(e: *Edit, off: usize) void {
        const items = e.buf.items;
        if (ui.paint.wordRange(items, @min(off, items.len))) |r| {
            e.sel_anchor = @min(r.lo, items.len);
            e.caret = @min(r.hi, items.len);
            e.clampOffsets();
            e.resetBlink();
            if (e.node) |n| n.markDirty();
            return;
        }
        e.moveCaret(off, false);
    }

    /// Splice `ins` in AT the caret — an open selection is replaced first.
    /// Over-cap input is rejected whole (never truncated mid-codepoint).
    /// Returns false when the insert didn't fit the documented 1 MiB cap.
    pub fn insert(e: *Edit, ins: []const u8) bool {
        const sel = e.selRange();
        if (e.buf.items.len + ins.len - (sel.hi - sel.lo) > ui.state.TextSignal.max_len) return false;
        if (sel.hi > sel.lo) e.deleteRange(sel.lo, sel.hi);
        const at = e.caret;
        e.buf.ensureUnusedCapacity(ins.len + 1) catch @panic("klaxon: out of memory");
        const tail = e.buf.items.len - at;
        std.mem.copyBackwards(u8, e.buf.items.ptr[at + ins.len ..][0..tail], e.buf.items[at..][0..tail]);
        @memcpy(e.buf.items.ptr[at..][0..ins.len], ins);
        e.buf.items.len += ins.len;
        e.caret = at + ins.len;
        e.sel_anchor = e.caret; // inserted text is not left selected
        setSentinel(&e.buf);
        return true;
    }

    /// Register the blink ticker once (the scrollbar's lazy pattern).
    pub fn ensureTicker(e: *Edit) void {
        if (e.ticker != null) return;
        const tl = ui.anim.timeline() orelse return;
        const t = ui.anim.Timeline.Ticker{ .fn_ptr = caretTickCb, .userdata = e, .has_pending = caretPendingCb };
        tl.addTicker(t);
        e.ticker = t;
    }

    /// The shared key/clipboard path — returns true when the event was an
    /// editing operation this core consumed: text_input commits, the
    /// text_editing preedit, Cmd/Ctrl chords, backspace/delete, and the
    /// arrows/home/end navigation. Widget keys (enter, escape, activation)
    /// return false — the widget's own switch handles them.
    /// `apply_edit` runs the widget's post-edit follow-ups (re-layout,
    /// signal mirror, a11y, on_changed) on the owning node.
    pub fn handleKey(e: *Edit, ev: input.KeyEvent, apply_edit: *const fn (*Node) void) bool {
        const n = e.node orelse return false;
        switch (ev.kind) {
            .text_input => {
                // A commit discharges the composition: SDL's sequence is
                // text_input (commit) then text_editing("") (clear) on the
                // platforms that report preedit at all.
                e.comp.clearRetainingCapacity();
                e.comp_cursor = 0;
                setSentinel(&e.comp);
                if (!e.insert(ev.text)) return true; // over cap — dropped whole
                e.resetBlink();
                apply_edit(n);
                return true;
            },
            .text_editing => {
                // SDL delivers the full composing string — replace, don't
                // append. Bounded by the same documented cap; an over-cap
                // preedit is dropped whole (never truncated mid-codepoint).
                e.comp.clearRetainingCapacity();
                if (ev.text.len <= ui.state.TextSignal.max_len) {
                    e.comp.appendSlice(ev.text) catch @panic("klaxon: out of memory");
                    // A fresh composition over an open selection commits the
                    // deletion (the IME owns the range; the text changed).
                    const sel = e.selRange();
                    if (e.comp.items.len > 0 and sel.hi > sel.lo) {
                        e.deleteRange(sel.lo, sel.hi);
                        apply_edit(n);
                    }
                }
                e.comp_cursor = ev.comp_start;
                setSentinel(&e.comp);
                n.markDirty(); // repaint only — comp is not a committed edit
                return true;
            },
            .key_down => {
                // Clipboard + select-all chords (Cmd on Apple, Ctrl
                // elsewhere — the platform's shortcut modifier arrives as
                // `ev.command`).
                if (ev.command) {
                    const sel = e.selRange();
                    switch (ev.chr) {
                        'a' => { // select all: anchor start, caret end
                            e.sel_anchor = 0;
                            e.moveCaret(e.buf.items.len, true);
                            return true;
                        },
                        'c' => { // copy the open range; collapsed = no-op
                            if (sel.hi > sel.lo) ui.clipboard.set(e.buf.items[sel.lo..sel.hi]);
                            return true;
                        },
                        'x' => { // cut = copy + delete the range
                            if (sel.hi > sel.lo) {
                                ui.clipboard.set(e.buf.items[sel.lo..sel.hi]);
                                e.deleteRange(sel.lo, sel.hi);
                                e.resetBlink();
                                apply_edit(n);
                            }
                            return true;
                        },
                        'v' => { // paste: replaces the selection / caret insert
                            const clip = ui.clipboard.get(n.allocator) orelse return true;
                            defer n.allocator.free(clip);
                            if (clip.len == 0) return true;
                            // Single-line: line terminators don't paste
                            // (upstream filters them through the IME path).
                            var scratch: ?[]u8 = null;
                            defer if (scratch) |b| n.allocator.free(b);
                            var ins: []const u8 = clip;
                            if (std.mem.indexOfAny(u8, clip, "\r\n") != null) {
                                const b = n.allocator.alloc(u8, clip.len) catch @panic("klaxon: out of memory");
                                var w: usize = 0;
                                for (clip) |ch| {
                                    if (ch == '\r' or ch == '\n') continue;
                                    b[w] = ch;
                                    w += 1;
                                }
                                scratch = b;
                                ins = b[0..w];
                            }
                            if (ins.len == 0) return true;
                            if (!e.insert(ins)) return true;
                            e.resetBlink();
                            apply_edit(n);
                            return true;
                        },
                        else => return true, // unknown chord — still consumed
                    }
                }
                switch (ev.key) {
                    .backspace => {
                        if (e.comp.items.len > 0) {
                            // An open composition eats the backspace
                            // (codepoint first); the platform re-sends
                            // text_editing anyway.
                            while (e.comp.items.len > 0) {
                                const last = e.comp.items[e.comp.items.len - 1];
                                e.comp.items.len -= 1;
                                if ((last & 0xC0) != 0x80) break;
                            }
                            e.comp_cursor = @intCast(e.comp.items.len);
                            setSentinel(&e.comp);
                            n.markDirty();
                            return true;
                        }
                        // An open selection eats the delete — upstream
                        // clears the range, not the codepoint before it.
                        const sel = e.selRange();
                        if (sel.hi > sel.lo) {
                            e.deleteRange(sel.lo, sel.hi);
                            e.resetBlink();
                            apply_edit(n);
                            return true;
                        }
                        if (e.caret == 0) return true;
                        e.deleteRange(e.graphemeStep(e.caret, -1), e.caret);
                        e.resetBlink();
                        apply_edit(n);
                        return true;
                    },
                    .delete => {
                        const sel = e.selRange();
                        if (sel.hi > sel.lo) {
                            e.deleteRange(sel.lo, sel.hi);
                            e.resetBlink();
                            apply_edit(n);
                            return true;
                        }
                        // Forward delete: the grapheme cluster at the caret.
                        if (e.caret >= e.buf.items.len or e.comp.items.len > 0) return true;
                        e.deleteRange(e.caret, e.graphemeStep(e.caret, 1));
                        e.resetBlink();
                        apply_edit(n);
                        return true;
                    },
                    // Logical caret motion — one grapheme cluster per
                    // press (UAX #29 via the paint backend, like Compose's
                    // BreakIterator). Shift extends; a plain arrow over an
                    // open selection collapses onto the range's edge.
                    .left => {
                        const sel = e.selRange();
                        if (sel.hi > sel.lo and !ev.shift) {
                            e.moveCaret(sel.lo, false);
                            return true;
                        }
                        e.moveCaret(e.graphemeStep(e.caret, -1), ev.shift);
                        return true;
                    },
                    .right => {
                        const sel = e.selRange();
                        if (sel.hi > sel.lo and !ev.shift) {
                            e.moveCaret(sel.hi, false);
                            return true;
                        }
                        e.moveCaret(e.graphemeStep(e.caret, 1), ev.shift);
                        return true;
                    },
                    .home => {
                        e.moveCaret(0, ev.shift); // single line: the run start
                        return true;
                    },
                    .end => {
                        e.moveCaret(e.buf.items.len, ev.shift); // the run end
                        return true;
                    },
                    else => {},
                }
            },
        }
        return false;
    }
};

/// Write the null sentinel at items[len]. Grows if the buffer is exactly
/// full — writing the sentinel past capacity was a heap OOB.
pub fn setSentinel(buf: *std.array_list.Managed(u8)) void {
    buf.ensureUnusedCapacity(1) catch @panic("klaxon: out of memory");
    buf.items.len += 1;
    buf.items[buf.items.len - 1] = 0;
    buf.items.len -= 1;
}

/// An owned null-terminated copy of a string.
pub fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

/// UTF-16 position → byte offset. The paragraph reports grapheme-cluster
/// boundaries in UTF-16 code units (astral chars count 2 — the surrogate
/// pair); a position mid-cluster clamps back to the codepoint's start.
pub fn utf16ToByteIndex(str: []const u8, pos16: usize) usize {
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

/// The byte offset of the grapheme boundary nearest a point in the run's
/// own space (`px/py` are already relative to the run's painted left/top).
/// SkParagraph's getGlyphPositionAtCoordinate — Compose's
/// TextLayoutResult.getOffsetForPosition. The probe builds under LTR: the
/// text widgets paint the run in logical order (the text-run-LTR
/// deviation), so the hit test must agree with what is on screen.
/// Falls back to the run's near edge when the paragraph can't build.
pub fn caretFromPoint(str: [:0]const u8, px: f32, py: f32, size: f32) usize {
    if (str.len == 0) return 0;
    const l = ui.paint.textLayoutBegin(0) orelse { // no wrap — fields clip
        return if (px <= 0) 0 else str.len;
    };
    defer ui.paint.textLayoutDestroy(l);
    const prev_rtl = ui.paint.textDirectionRtl();
    ui.paint.setTextDirection(false);
    defer ui.paint.setTextDirection(prev_rtl);
    ui.paint.textLayoutSpan(l, str, ui.paint.textStyle(size, 400, 0, 0, 0xFF0000FF));
    const pos = ui.paint.textLayoutPositionAt(l, px, py);
    if (pos < 0) return if (px <= 0) 0 else str.len;
    return utf16ToByteIndex(str, @intCast(pos));
}

fn caretTickCb(userdata: ?*anyopaque, now_ms: u64) void {
    const e: *Edit = @ptrCast(@alignCast(userdata.?));
    if (e.blink_epoch == std.math.maxInt(u64)) e.blink_epoch = now_ms;
    const on = ((now_ms - e.blink_epoch) / blink_half_ms) % 2 == 0;
    if (on != e.caret_on) {
        e.caret_on = on;
        if (e.node) |n| n.markDirty();
    }
}

/// The blink only needs the host awake while the caret is shown — an
/// unfocused widget paints no caret and lets the loop block.
fn caretPendingCb(userdata: ?*anyopaque) bool {
    const e: *Edit = @ptrCast(@alignCast(userdata.?));
    const n = e.node orelse return false;
    return input.isFocused(n);
}
