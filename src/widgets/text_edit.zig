// TextEdit — the shared editing core for the text widgets
// (text_field, search_bar, search_view): the null-terminated UTF-8 buffer,
// the IME composition (preedit) buffer, the caret/selection model, the
// 500ms blink ticker, and the editing operations — insert at caret, range
// deletes, grapheme-cluster arrows/home/end, Cmd/Ctrl+A/C/X/V chords.
// `multiline` + `wrap_width` (owned by the widget) turn on soft-wrap hit
// geometry, up/down line motion with a sticky column and line-relative
// home/end; the single-line widgets leave both at their defaults.
//
// The widget owns the GEOMETRY (where the run paints → `caretAt`'s
// run origin) and the edit follow-ups (layout dirty, signal mirror, a11y
// notify, on_changed) through the `apply_edit` callback — this module owns
// the buffer/offsets/blink that must behave identically everywhere.
const std = @import("std");
const kx = @import("../kx.zig");
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
    /// Hit-test paragraph memo: `caretAt` rebuilds the layout only when the
    /// buffer's content hash or the probe size moved — a press-drag would
    /// otherwise pay an O(text) paragraph build per pointer event.
    hit_layout: ?*ui.paint.TextLayout = null,
    hit_key: u64 = 0,
    hit_size: f32 = 0,
    hit_rtl: bool = false,
    /// Multiline mode — the owning widget sets it before events/paint:
    /// paste keeps line breaks, the hit layout wraps at `wrap_width`,
    /// arrows gain up/down line motion and home/end go line-relative.
    multiline: bool = false,
    /// The wrap width the hit layout builds at — 0 = unconstrained (the
    /// single-line widgets). The owner syncs it to the painted text
    /// width so hit geometry agrees with the wrap on screen.
    wrap_width: f32 = 0,
    hit_wrap: f32 = 0,
    /// The sticky column consecutive up/down arrows aim at — the caret
    /// x the motion started from (Compose's vertical-motion x). Cleared
    /// by every non-vertical key and by taps.
    v_motion_x: ?f32 = null,
    /// Horizontal scroll offset for single-line text fields when the text
    /// exceeds the visible clip width (keeps the caret inside the viewport).
    scroll_x: f32 = 0,

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
        if (e.hit_layout) |l| ui.paint.textLayoutDestroy(l);
        e.buf.deinit();
        e.comp.deinit();
    }

    /// Clear any active IME preedit composition (e.g. on blur, Escape, or
    /// programmatic text replacement).
    pub fn clearComposition(e: *Edit) void {
        if (e.comp.items.len == 0 and e.comp_cursor == 0) return;
        e.comp.clearRetainingCapacity();
        e.comp_cursor = 0;
        setSentinel(&e.comp);
        if (e.node) |n| n.markDirty();
    }

    /// Update `scroll_x` so the caret `[caret_rel_x, caret_rel_x + caret_w]`
    /// stays visible inside a viewport of width `clip_w` for a run of width `total_w`.
    pub fn updateScroll(e: *Edit, caret_rel_x: f32, caret_w: f32, total_w: f32, clip_w: f32) void {
        if (clip_w <= 0) {
            e.scroll_x = 0;
            return;
        }
        const max_scroll = @max(@as(f32, 0), total_w + caret_w - clip_w);
        if (caret_rel_x < e.scroll_x) {
            e.scroll_x = caret_rel_x;
        } else if (caret_rel_x + caret_w > e.scroll_x + clip_w) {
            e.scroll_x = caret_rel_x + caret_w - clip_w;
        }
        e.scroll_x = std.math.clamp(e.scroll_x, 0, max_scroll);
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
        e.v_motion_x = null; // an edit re-seats the caret — the column resets
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
        e.v_motion_x = null; // a tap re-seats the caret — the column resets
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
        e.v_motion_x = null;
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
    /// signal mirror, a11y, on_changed) on the owning node. `size` is the
    /// run's painted text size — the arrows step in SCREEN direction
    /// through the same memoized layout the hit test builds, so it must
    /// match the paint size for the geometry to agree.
    pub fn handleKey(e: *Edit, ev: input.KeyEvent, apply_edit: *const fn (*Node) void, size: f32) bool {
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
                // The sticky vertical-motion column survives only across
                // consecutive up/down presses.
                if (ev.key != .up and ev.key != .down) e.v_motion_x = null;
                // Clipboard + select-all chords (Cmd on Apple, Ctrl
                // elsewhere — the platform's shortcut modifier arrives as
                // `ev.command`).
                if (ev.command) {
                    // Cmd/Ctrl+Home/End reach the document edges under
                    // multiline (single-line home/end already do).
                    if (e.multiline and (ev.key == .home or ev.key == .end)) {
                        e.moveCaret(if (ev.key == .home) 0 else e.buf.items.len, ev.shift);
                        return true;
                    }
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
                            // Multiline keeps them — normalized to '\n'
                            // so the buffer carries one line ending.
                            var scratch: ?[]u8 = null;
                            defer if (scratch) |b| n.allocator.free(b);
                            var ins: []const u8 = clip;
                            if (std.mem.indexOfAny(u8, clip, "\r\n") != null) {
                                const b = n.allocator.alloc(u8, clip.len) catch @panic("klaxon: out of memory");
                                var w: usize = 0;
                                var i: usize = 0;
                                while (i < clip.len) : (i += 1) {
                                    const ch = clip[i];
                                    if (ch == '\n') {
                                        if (!e.multiline) continue;
                                    } else if (ch == '\r') {
                                        if (!e.multiline) continue;
                                        if (i + 1 < clip.len and clip[i + 1] == '\n') i += 1;
                                        b[w] = '\n';
                                        w += 1;
                                        continue;
                                    }
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
                    // Visual caret motion — one position per press in the
                    // arrow's SCREEN direction: the logical neighbours'
                    // caret x pick the step, so RTL and mixed-direction
                    // text move the way the caret appears to move
                    // (Compose's visual motion). Identical to the
                    // grapheme step under pure LTR. Shift extends; a
                    // plain arrow over an open selection collapses onto
                    // the range's visual edge.
                    .left => {
                        const sel = e.selRange();
                        if (sel.hi > sel.lo and !ev.shift) {
                            e.moveCaret(e.visualEdge(sel.lo, sel.hi, -1, size), false);
                            return true;
                        }
                        e.moveCaret(e.visualStep(-1, size), ev.shift);
                        return true;
                    },
                    .right => {
                        const sel = e.selRange();
                        if (sel.hi > sel.lo and !ev.shift) {
                            e.moveCaret(e.visualEdge(sel.lo, sel.hi, 1, size), false);
                            return true;
                        }
                        e.moveCaret(e.visualStep(1, size), ev.shift);
                        return true;
                    },
                    // Vertical line motion — the sticky column (v_motion_x)
                    // aims at the caret x the run started from so jagged
                    // lines don't drift the caret left/right; an open
                    // selection keeps its anchor under shift.
                    .up => {
                        if (e.multiline) {
                            e.moveCaret(e.lineStep(-1, size), ev.shift);
                            return true;
                        }
                    },
                    .down => {
                        if (e.multiline) {
                            e.moveCaret(e.lineStep(1, size), ev.shift);
                            return true;
                        }
                    },
                    .home => {
                        const pos = if (e.multiline) e.lineEdge(-1, size) else e.visualEdge(0, e.buf.items.len, -1, size);
                        e.moveCaret(pos, ev.shift);
                        return true;
                    },
                    .end => {
                        const pos = if (e.multiline) e.lineEdge(1, size) else e.visualEdge(0, e.buf.items.len, 1, size);
                        e.moveCaret(pos, ev.shift);
                        return true;
                    },
                    else => {},
                }
            },
        }
        return false;
    }

    /// The memoized hit-test/motion layout: a single-span unconstrained
    /// paragraph in the GLOBAL text direction — the same direction the
    /// paint path builds its run — so hit-testing, caret geometry and
    /// arrow stepping all agree with what is on screen (a mirrored RTL
    /// run hit-tests its glyphs where they are painted). Keyed on
    /// (content hash, size, direction); drags and arrows reuse it.
    fn hitLayout(e: *Edit, size: f32) ?*ui.paint.TextLayout {
        const str = e.text();
        if (str.len == 0) return null;
        const key = std.hash.Wyhash.hash(0, str);
        const rtl = ui.paint.textDirectionRtl();
        if (e.hit_layout == null or e.hit_key != key or e.hit_size != size or e.hit_rtl != rtl or e.hit_wrap != e.wrap_width) {
            if (e.hit_layout) |old| ui.paint.textLayoutDestroy(old);
            // wrap_width constrains the layout — soft wraps hit-test
            // where they paint; 0 stays unconstrained (single-line).
            const l = ui.paint.textLayoutBegin(e.wrap_width) orelse {
                e.hit_layout = null;
                return null;
            };
            ui.paint.textLayoutSpan(l, str, ui.paint.textStyle(size, 400, 0, 0, 0xFF0000FF));
            e.hit_layout = l;
            e.hit_key = key;
            e.hit_size = size;
            e.hit_rtl = rtl;
            e.hit_wrap = e.wrap_width;
        }
        return e.hit_layout;
    }

    /// The byte offset of the grapheme boundary nearest a point in the
    /// run's own space (`px/py` are already relative to the run's painted
    /// left/top) — SkParagraph's getGlyphPositionAtCoordinate, Compose's
    /// TextLayoutResult.getOffsetForPosition. Falls back to the run's
    /// near edge (logical start under LTR, logical end under RTL) when
    /// the paragraph can't build.
    pub fn caretAt(e: *Edit, px: f32, py: f32, size: f32) usize {
        const str = e.text();
        if (str.len == 0) return 0;
        const near: usize = if (ui.paint.textDirectionRtl()) str.len else 0;
        const l = e.hitLayout(size) orelse return if (px <= 0) near else str.len - near;
        const pos = ui.paint.textLayoutPositionAt(l, px, py);
        if (pos < 0) return if (px <= 0) near else str.len - near;
        return utf16ToByteIndex(str, @intCast(pos));
    }

    /// The caret's rect for `byte_off` in layout space — {x, top, 0, h}
    /// where top/h bound the caret's LINE (the paragraph's caret rect),
    /// direction-aware under RTL. null when the paragraph can't build.
    pub fn caretRect(e: *Edit, byte_off: usize, size: f32) ?[4]f32 {
        const l = e.hitLayout(size) orelse return null;
        var r: [4]f32 = undefined;
        if (!ui.paint.textLayoutCaretRect(l, byteToUtf16Index(e.text(), byte_off), &r)) return null;
        return r;
    }

    /// The caret's visual x for `byte_off` in layout space — the leading
    /// edge of the grapheme at that offset, direction-aware under RTL.
    /// null when the paragraph can't build; callers fall back to the
    /// prefix-width measure.
    pub fn caretX(e: *Edit, byte_off: usize, size: f32) ?f32 {
        return (e.caretRect(byte_off, size) orelse return null)[0];
    }

    /// The glyph boxes covering byte range [lo, hi) in layout space —
    /// one per run when the range crosses a bidi boundary, which is what
    /// the selection highlight must paint under mixed direction. `out`
    /// gets {x,y,w,h} quads; null when the paragraph can't build.
    pub fn caretBoxes(e: *Edit, lo: usize, hi: usize, size: f32, out: [][4]f32) ?usize {
        const str = e.text();
        const l = e.hitLayout(size) orelse return null;
        return ui.paint.textLayoutRectsForRange(l, byteToUtf16Index(str, lo), byteToUtf16Index(str, hi), out);
    }

    /// The next caret position in SCREEN direction `dir` (-1 = visual
    /// left, +1 = visual right): the logical neighbours' caret x decide
    /// which lies toward `dir`, so RTL runs and bidi boundaries move the
    /// way the caret appears to move — identical to the grapheme step
    /// under pure LTR. A position sharing the caret's x (the two sides
    /// of a bidi boundary) counts toward either direction and wins by
    /// proximity. Falls back to the logical step when the paragraph
    /// can't build.
    fn visualStep(e: *Edit, dir: i32, size: f32) usize {
        const cur = e.caretX(e.caret, size) orelse return e.graphemeStep(e.caret, dir);
        var best: usize = e.caret;
        var best_dx: f32 = std.math.floatMax(f32);
        for ([_]usize{ e.graphemeStep(e.caret, -1), e.graphemeStep(e.caret, 1) }) |pos| {
            if (pos == e.caret) continue;
            const dx = (e.caretX(pos, size) orelse continue) - cur;
            if ((dir < 0 and dx > 0.5) or (dir > 0 and dx < -0.5)) continue; // wrong side
            if (@abs(dx) < best_dx) {
                best = pos;
                best_dx = @abs(dx);
            }
        }
        return best;
    }

    /// The range edge toward screen direction `dir` — the caret x of lo
    /// vs hi picks the visual side (under RTL the logical lo can sit on
    /// the right). null-fallback keeps the logical edge.
    fn visualEdge(e: *Edit, lo: usize, hi: usize, dir: i32, size: f32) usize {
        const lx = e.caretX(lo, size) orelse return if (dir < 0) lo else hi;
        const hx = e.caretX(hi, size) orelse return if (dir < 0) lo else hi;
        return if (dir < 0) (if (lx <= hx) lo else hi) else (if (lx >= hx) lo else hi);
    }

    /// The caret position one line up (dir < 0) or down (dir > 0),
    /// aiming at the sticky column — the caret x the vertical run started
    /// from (Compose's remembered x for line motion). First/last line
    /// jumps to the document edge like every desktop editor; the
    /// paragraph-less fallback does the same.
    fn lineStep(e: *Edit, dir: i32, size: f32) usize {
        const r = e.caretRect(e.caret, size) orelse {
            e.v_motion_x = null;
            return if (dir < 0) 0 else e.buf.items.len;
        };
        const aim = e.v_motion_x orelse r[0];
        const l = e.hitLayout(size) orelse return e.caret;
        // One pixel past the line box lands on the neighbour line.
        const y = if (dir < 0) r[1] - 1 else r[1] + r[3] + 1;
        const pos = ui.paint.textLayoutPositionAt(l, aim, y);
        if (pos < 0) return e.caret;
        const next = utf16ToByteIndex(e.text(), @intCast(pos));
        e.v_motion_x = aim;
        // The position query clamps onto the nearest line — landing on
        // the caret's OWN line means there's no line in `dir`, so the
        // caret goes to the document edge (Compose semantics).
        if (e.caretRect(next, size)) |nr| {
            if (nr[1] == r[1]) return if (dir < 0) 0 else e.buf.items.len;
        }
        return next;
    }

    /// The caret position at the caret's own line's edge — dir < 0 =
    /// the line's start edge, dir > 0 = its end edge, in READING order
    /// (multiline home/end; visual-left/right follows the base
    /// direction — under RTL the line start sits on the right). The
    /// position query at the line's mid-height and the wrap edge lands
    /// on the boundary; a collapsed (unwrappable) layout falls back to
    /// the document edges.
    fn lineEdge(e: *Edit, dir: i32, size: f32) usize {
        const r = e.caretRect(e.caret, size) orelse return if (dir < 0) 0 else e.buf.items.len;
        const l = e.hitLayout(size) orelse return if (dir < 0) 0 else e.buf.items.len;
        // The query clamps dx into the line, so an x past the far edge
        // lands on the boundary — 1e9 stands in for "the end edge" under
        // both constrained and unconstrained layouts.
        const edge_x: f32 = if ((dir < 0) == ui.paint.textDirectionRtl()) 1e9 else 0;
        const pos = ui.paint.textLayoutPositionAt(l, edge_x, r[1] + r[3] / 2);
        if (pos < 0) return if (dir < 0) 0 else e.buf.items.len;
        return utf16ToByteIndex(e.text(), @intCast(pos));
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

/// Byte offset → UTF-16 position (utf16ToByteIndex's inverse) — astral
/// chars count 2 units. A mid-codepoint offset lands on the position
/// after the whole codepoint; caret offsets are grapheme boundaries in
/// practice, so that case is a clamp, not a normal path.
fn byteToUtf16Index(str: []const u8, off: usize) i32 {
    var u16n: usize = 0;
    var i: usize = 0;
    while (i < @min(off, str.len)) {
        const l = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
        u16n += if (l == 4) 2 else 1;
        i += l;
    }
    return @intCast(u16n);
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

// --- tests ---

fn testMeasure(_: *Node, _: ui.layout.Constraints) ui.layout.Size {
    return .{ .w = 0, .h = 0 };
}
fn testLayout(_: *Node, _: ui.node.Rect) void {}
fn testPaint(_: *Node, _: *kx.Ctx) void {}

const test_vtable = ui.node.VTable{
    .measure = testMeasure,
    .layout = testLayout,
    .paint = testPaint,
};

fn noopApplyEdit(_: *Node) void {}

fn testEdit(a: std.mem.Allocator, text: [:0]const u8, wrap: f32) !struct { n: *Node, e: *Edit } {
    const n = try Node.create(a, &test_vtable);
    const e = try a.create(Edit);
    e.* = Edit.init(a, n);
    e.multiline = true;
    e.wrap_width = wrap;
    if (text.len > 0) {
        e.buf.appendSlice(text) catch @panic("klaxon: out of memory");
        setSentinel(&e.buf);
        e.caret = e.buf.items.len;
        e.sel_anchor = e.caret;
    }
    return .{ .n = n, .e = e };
}

fn freeTestEdit(a: std.mem.Allocator, n: *Node, e: *Edit) void {
    e.deinit();
    a.destroy(e);
    n.deinit();
}

// "xx\nxxxxx\nxx": line 1 = [0,2], \n@2, line 2 = [3,8], \n@8, line 3 = [9,11].
test "edit: multiline up/down ride the sticky column; home/end stay line-relative" {
    const a = std.testing.allocator;
    const t = try testEdit(a, "xx\nxxxxx\nxx", 200);
    defer freeTestEdit(a, t.n, t.e);
    const e = t.e;
    const size: f32 = 16;
    try std.testing.expectEqual(@as(usize, 11), e.caret);
    // up from the end of "xx" (x ≈ 2 chars in) lands on line 2 at that
    // column — "xx|xxx" → offset 5.
    _ = e.handleKey(.{ .kind = .key_down, .key = .up }, noopApplyEdit, size);
    try std.testing.expectEqual(@as(usize, 5), e.caret);
    // a second up keeps the column onto line 1 — "xx" ends at 2.
    _ = e.handleKey(.{ .kind = .key_down, .key = .up }, noopApplyEdit, size);
    try std.testing.expectEqual(@as(usize, 2), e.caret);
    // up on the first line jumps to the document edge.
    _ = e.handleKey(.{ .kind = .key_down, .key = .up }, noopApplyEdit, size);
    try std.testing.expectEqual(@as(usize, 0), e.caret);
    // The sticky column survives the edge jump — down re-aims at the
    // original x: 0 → "xx|xxx" (5) → the last line's end (11).
    _ = e.handleKey(.{ .kind = .key_down, .key = .down }, noopApplyEdit, size);
    try std.testing.expectEqual(@as(usize, 5), e.caret);
    _ = e.handleKey(.{ .kind = .key_down, .key = .down }, noopApplyEdit, size);
    try std.testing.expectEqual(@as(usize, 11), e.caret);
    _ = e.handleKey(.{ .kind = .key_down, .key = .down }, noopApplyEdit, size);
    try std.testing.expectEqual(@as(usize, 11), e.caret); // last line: already at the doc end
    // home/end bound the caret's own line — "xxxxx" is [3, 8].
    e.moveCaret(5, false);
    _ = e.handleKey(.{ .kind = .key_down, .key = .home }, noopApplyEdit, size);
    try std.testing.expectEqual(@as(usize, 3), e.caret);
    _ = e.handleKey(.{ .kind = .key_down, .key = .end }, noopApplyEdit, size);
    try std.testing.expectEqual(@as(usize, 8), e.caret);
    // Cmd/Ctrl+home/end reach the document edges.
    _ = e.handleKey(.{ .kind = .key_down, .key = .home, .command = true }, noopApplyEdit, size);
    try std.testing.expectEqual(@as(usize, 0), e.caret);
    _ = e.handleKey(.{ .kind = .key_down, .key = .end, .command = true }, noopApplyEdit, size);
    try std.testing.expectEqual(@as(usize, 11), e.caret);
}

test "edit: shift+down extends the selection across lines" {
    const a = std.testing.allocator;
    const t = try testEdit(a, "aa\nbb", 200);
    defer freeTestEdit(a, t.n, t.e);
    const e = t.e;
    e.moveCaret(0, false);
    _ = e.handleKey(.{ .kind = .key_down, .key = .down, .shift = true }, noopApplyEdit, 16);
    const sel = e.selRange();
    try std.testing.expectEqual(@as(usize, 0), sel.lo);
    try std.testing.expectEqual(@as(usize, 3), sel.hi); // line 2's start
}

test "edit: multiline paste keeps newlines and normalizes CRLF/CR to LF" {
    const a = std.testing.allocator;
    const S = struct {
        var slot: [256]u8 = undefined;
        var len: usize = 0;
        fn getImpl(al: std.mem.Allocator) ?[]u8 {
            if (len == 0) return null;
            return al.dupe(u8, slot[0..len]) catch null;
        }
        fn setImpl(text: []const u8) void {
            len = @min(text.len, slot.len);
            @memcpy(slot[0..len], text[0..len]);
        }
    };
    ui.clipboard.install(.{ .get = S.getImpl, .set = S.setImpl });
    defer ui.clipboard.install(.{});
    ui.clipboard.set("a\r\nb\rc\nd");
    const t = try testEdit(a, "", 200);
    defer freeTestEdit(a, t.n, t.e);
    _ = t.e.handleKey(.{ .kind = .key_down, .key = .unknown, .chr = 'v', .command = true }, noopApplyEdit, 16);
    try std.testing.expectEqualStrings("a\nb\nc\nd", t.e.text());
    // A single-line edit still strips them.
    const t2 = try testEdit(a, "", 0);
    defer freeTestEdit(a, t2.n, t2.e);
    t2.e.multiline = false;
    _ = t2.e.handleKey(.{ .kind = .key_down, .key = .unknown, .chr = 'v', .command = true }, noopApplyEdit, 16);
    try std.testing.expectEqualStrings("abcd", t2.e.text());
}

test "edit: caretRect reports the line box (top/height) on later lines" {
    const a = std.testing.allocator;
    const t = try testEdit(a, "aa\nbb", 200);
    defer freeTestEdit(a, t.n, t.e);
    const r0 = t.e.caretRect(0, 16) orelse return error.TestUnexpectedResult;
    const r1 = t.e.caretRect(4, 16) orelse return error.TestUnexpectedResult;
    try std.testing.expect(r1[1] > r0[1]); // line 2 sits below line 1
    try std.testing.expect(r1[3] > 0 and r0[3] > 0);
    // A wrapped paragraph wraps: "aaaa..." at wrap < text width → taller layout.
    const w = try testEdit(a, "a a a a a a a a a a", 30);
    defer freeTestEdit(a, w.n, w.e);
    const rl = w.e.caretRect(0, 16) orelse return error.TestUnexpectedResult;
    const rr = w.e.caretRect(19, 16) orelse return error.TestUnexpectedResult;
    try std.testing.expect(rr[1] > rl[1]); // the end caret sits on a later line
}
