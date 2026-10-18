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
    /// The span style the hit layout bakes — the owning widget sets them
    /// from its paint style (theme-fixed at construction; `hit_ink` may
    /// follow state colors). Defaults keep the old neutral span. A widget
    /// that paints `hitLayout` verbatim (multiline text_field) updates
    /// hit_ink per frame — a color change rebuilds the shared layout.
    hit_weight: i32 = 400,
    hit_spacing: f32 = 0,
    hit_ink: u32 = 0xFF0000FF,
    hit_style_baked: struct { weight: i32 = 400, spacing: f32 = 0, ink: u32 = 0xFF0000FF } = .{},
    /// The sticky column consecutive up/down arrows aim at — the caret
    /// x the motion started from (Compose's vertical-motion x). Cleared
    /// by every non-vertical key and by taps.
    v_motion_x: ?f32 = null,
    /// Horizontal scroll offset for single-line text fields when the text
    /// exceeds the visible clip width (keeps the caret inside the viewport).
    scroll_x: f32 = 0,
    /// Optional prefix-measure hook the owning widget wires to its
    /// incrementally-shaped paint segmentation (text_field's segs). Called
    /// by `caretX` on the single-line fast path instead of a whole-buffer
    /// measure or a paragraph build — O(cached segs), not O(text) shaping.
    /// Signature: (edit, byte_off, size) -> advance of text[0..byte_off].
    measure_prefix: ?*const fn (e: *Edit, byte_off: usize, size: f32) f32 = null,
    /// The strong-RTL memo (content-hash keyed): a buffer with any strong
    /// RTL codepoint or bidi control routes caret geometry through the
    /// paragraph (mirrored runs); a clean buffer paints L→R in logical
    /// order so prefix advances answer the same question far cheaper.
    bidi_key: u64 = 0,
    bidi_key_set: bool = false,
    bidi_rtl: bool = false,

    /// The multiline (wrap_width > 0) layout table: ONE SkParagraph per
    /// hard line ('\n'-delimited), incrementally reconciled against the
    /// buffer so a keystroke rebuilds only the touched line instead of a
    /// monolithic O(text) paragraph. Geometry is identical either way —
    /// a hard break unconditionally ends a SkParagraph line and bounds
    /// its bidi/wrap state, so a paragraph over one line's bytes (the
    /// '\n' excluded — inside a span it would fabricate a second empty
    /// line) wraps to the same rows it occupies in the whole-buffer
    /// layout. Reconciled on (content hash, size, wrap, direction, baked
    /// span style) — the same key hitLayout uses.
    line_paras: std.ArrayListUnmanaged(LinePara) = .empty,
    /// Reconcile scratch: the current hard-line split + content hashes.
    line_spans: std.ArrayListUnmanaged(LineSpan) = .empty,
    /// Reconcile scratch: the next line table (kept paras move into it).
    line_next: std.ArrayListUnmanaged(LinePara) = .empty,
    /// Reconcile scratch: a segmented line's next seg table.
    seg_next: std.ArrayListUnmanaged(SegPara) = .empty,
    /// Shared paragraph for empty lines, built over a single space — an
    /// empty line's height is the span's line metrics (SkParagraph gives
    /// in-text empty lines the run metrics too; an empty PARAGRAPH would
    /// fall back to the 14px paragraph default). One per table, not one
    /// per line — empty lines have no ink to distinguish them.
    empty_para: ?*ui.paint.TextLayout = null,
    lines_built: bool = false,
    lines_ok: bool = false,
    lines_key: u64 = 0,
    lines_size: f32 = 0,
    lines_wrap: f32 = 0,
    lines_rtl: bool = false,
    lines_style: struct { weight: i32 = 400, spacing: f32 = 0, ink: u32 = 0xFF0000FF } = .{},
    lines_total_h: f32 = 0,
    lines_max_w: f32 = 0,
    /// Test/diagnostic counter — one increment per paragraph build. An
    /// edit inside one line must not bump this for untouched lines.
    para_builds: u64 = 0,

    /// One hard line's incremental layout record. `para` is the line's
    /// own paragraph over buf[start..content_end]; null for empty lines
    /// (which answer geometry through `empty_para`) AND for segmented
    /// lines (which answer through `segs`). `segs` is the same idea one
    /// level down: when a hard line wraps past the seg budget, its text
    /// splits at soft-wrap row boundaries into independently rebuilt
    /// paragraphs, so a keystroke inside one chunk doesn't re-lay the
    /// whole line.
    pub const LinePara = struct {
        /// [start, end) byte range in buf — `end` sits past the '\n' when
        /// the line has one; `content_end` is `end` minus that '\n' (the
        /// bytes the paragraph actually shaped).
        start: usize = 0,
        end: usize = 0,
        content_end: usize = 0,
        /// Wyhash of buf[start..content_end] — the reconcile identity.
        key: u64 = 0,
        para: ?*ui.paint.TextLayout = null,
        /// Soft-wrap shards — non-empty iff the line is segmented.
        segs: std.ArrayListUnmanaged(SegPara) = .empty,
        /// The line-content hash the seg table was built against — a
        /// match on lp.key means every seg is still exact (offsets may
        /// just shift), so reconcile skips the hashing entirely.
        segs_key: u64 = 0,
        /// Layout-space top of the line's first soft row.
        y: f32 = 0,
        /// Laid-out height — every soft row of the line summed.
        h: f32 = 0,
        /// The line's longest soft-line width (0 for empty lines).
        w: f32 = 0,
        /// First soft row's baseline — the uniform style makes it every
        /// row's baseline offset, so it also positions the comp overlay.
        base: f32 = 0,
    };

    /// One soft-wrap shard inside a segmented line: a paragraph over
    /// buf[start..end) covering one or more COMPLETE visual rows. Its
    /// start is always a real wrap boundary of the line's layout (or the
    /// line start), so the paragraph reproduces the same rows those bytes
    /// occupy in the monolithic layout — the break state resets at row
    /// starts. Geometry entry points translate line-local coordinates in
    /// and out of it; `y` is line-local (doc y = line.y + seg.y).
    pub const SegPara = struct {
        /// [start, end) byte range in buf — inside the line's content.
        start: usize = 0,
        end: usize = 0,
        /// Wyhash of buf[start..end] — the seg reconcile identity.
        key: u64 = 0,
        para: ?*ui.paint.TextLayout = null,
        /// Line-local top of the seg's first row.
        y: f32 = 0,
        /// Laid-out height — every row the seg covers.
        h: f32 = 0,
        /// The seg's longest row width.
        w: f32 = 0,
        /// First row's baseline (uniform style ⇒ every row's offset).
        base: f32 = 0,
    };

    /// The reconcile split record — range + content hash per hard line.
    const LineSpan = struct { start: usize, end: usize, content_end: usize, key: u64 };

    /// (Unicode Bidi_Class R/AL blocks + the isolates/controls that can
    /// reorder). Memoized on the content hash — the scan is a UTF-8 decode
    /// + range check, ~2 orders cheaper than a paragraph build.
    pub fn hasStrongRtl(e: *Edit) bool {
        const str = e.text();
        const key = std.hash.Wyhash.hash(0, str);
        if (!e.bidi_key_set or e.bidi_key != key) {
            e.bidi_rtl = scanStrongRtl(str);
            e.bidi_key = key;
            e.bidi_key_set = true;
        }
        return e.bidi_rtl;
    }

    pub fn init(allocator: std.mem.Allocator, node: *Node) Edit {
        return .{
            .buf = std.array_list.Managed(u8).init(allocator),
            .comp = std.array_list.Managed(u8).init(allocator),
            .node = node,
        };
    }

    /// Remove the blink ticker, free both buffers, and destroy every
    /// cached paragraph — the monolithic hit layout plus the per-line
    /// table and its shared empty-line paragraph.
    pub fn deinit(e: *Edit) void {
        if (e.ticker) |t| {
            if (ui.anim.timeline()) |tl| tl.removeTicker(t);
        }
        if (e.hit_layout) |l| ui.paint.textLayoutDestroy(l);
        for (e.line_paras.items) |*lp| {
            if (lp.para) |p| ui.paint.textLayoutDestroy(p);
            for (lp.segs.items) |sg| {
                if (sg.para) |p| ui.paint.textLayoutDestroy(p);
            }
            lp.segs.deinit(e.buf.allocator);
        }
        const a = e.buf.allocator;
        e.line_paras.deinit(a);
        e.line_spans.deinit(a);
        e.line_next.deinit(a);
        e.seg_next.deinit(a);
        if (e.empty_para) |p| ui.paint.textLayoutDestroy(p);
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
                    // The sentinel must land BEFORE apply_edit can run:
                    // syncScroll→composition() reads it, and appendSlice
                    // leaves stale capacity bytes in the slot.
                    setSentinel(&e.comp);
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
            // A text field has no key_up behavior — bubble so a parent
            // (e.g. a button tracking a keyboard press) can see it.
            .key_up => return false,
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
                        // Unknown chords stay consumed — except Enter:
                        // the widget's own .enter case submits on
                        // Cmd/Ctrl+Enter (single- and multi-line alike).
                        else => return ev.key != .enter,
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

    /// The memoized hit-test/motion layout for the SINGLE-LINE path
    /// (wrap_width == 0): a single-span paragraph in the GLOBAL text
    /// direction — the same direction the paint path builds its run — so
    /// hit-testing, caret geometry and arrow stepping all agree with what
    /// is on screen (a mirrored RTL run hit-tests its glyphs where they
    /// are painted). Keyed on (content hash, size, direction); drags and
    /// arrows reuse it. The baked span style (hit_weight / hit_spacing /
    /// hit_ink) makes hit-testing paint-accurate.
    /// Multiline (wrap_width > 0) geometry instead comes from the
    /// per-hard-line paragraph table — see syncLines.
    pub fn hitLayout(e: *Edit, size: f32) ?*ui.paint.TextLayout {
        const str = e.text();
        if (str.len == 0) return null;
        const key = std.hash.Wyhash.hash(0, str);
        const rtl = ui.paint.textDirectionRtl();
        if (e.hit_layout == null or e.hit_key != key or e.hit_size != size or e.hit_rtl != rtl or e.hit_wrap != e.wrap_width or
            e.hit_style_baked.weight != e.hit_weight or e.hit_style_baked.spacing != e.hit_spacing or e.hit_style_baked.ink != e.hit_ink)
        {
            if (e.hit_layout) |old| ui.paint.textLayoutDestroy(old);
            // wrap_width constrains the layout — soft wraps hit-test
            // where they paint; 0 stays unconstrained (single-line).
            const l = ui.paint.textLayoutBegin(e.wrap_width) orelse {
                e.hit_layout = null;
                return null;
            };
            ui.paint.textLayoutSpan(l, str, ui.paint.textStyle(size, e.hit_weight, 0, e.hit_spacing, e.hit_ink));
            e.hit_layout = l;
            e.hit_key = key;
            e.hit_size = size;
            e.hit_rtl = rtl;
            e.hit_wrap = e.wrap_width;
            e.hit_style_baked = .{ .weight = e.hit_weight, .spacing = e.hit_spacing, .ink = e.hit_ink };
        }
        return e.hit_layout;
    }

    /// Drop every cached line paragraph + the shared empty line's — a
    /// style/wrap/direction/size change invalidates the whole table.
    fn clearLines(e: *Edit) void {
        for (e.line_paras.items) |*lp| {
            if (lp.para) |p| ui.paint.textLayoutDestroy(p);
            e.dropSegs(lp);
        }
        e.line_paras.clearRetainingCapacity();
        if (e.empty_para) |p| ui.paint.textLayoutDestroy(p);
        e.empty_para = null;
        e.lines_built = false;
        e.lines_total_h = 0;
        e.lines_max_w = 0;
    }

    /// Destroy a line's seg paragraphs and release the list — the line is
    /// no longer segmented.
    fn dropSegs(e: *Edit, lp: *LinePara) void {
        for (lp.segs.items) |sg| {
            if (sg.para) |p| ui.paint.textLayoutDestroy(p);
        }
        lp.segs.deinit(e.buf.allocator);
        lp.segs = .empty;
        lp.segs_key = 0;
    }

    /// Build one hard line's paragraph over `content` — a '\n'-free slice;
    /// the span takes a sentinel-terminated string so the line's bytes are
    /// copied for the call (the builder keeps its own copy afterwards).
    /// Same style and same process-global direction hitLayout bakes —
    /// textLayoutBegin applies kx_paragraph_dir internally.
    fn buildLinePara(e: *Edit, content: []const u8, size: f32) ?*ui.paint.TextLayout {
        const l = ui.paint.textLayoutBegin(e.wrap_width) orelse return null;
        const z = dupeZ(e.buf.allocator, content) catch @panic("klaxon: out of memory");
        defer e.buf.allocator.free(z.ptr[0 .. z.len + 1]);
        ui.paint.textLayoutSpan(l, z, ui.paint.textStyle(size, e.hit_weight, 0, e.hit_spacing, e.hit_ink));
        e.para_builds += 1;
        return l;
    }

    /// The per-line layout table for the multiline path (wrap_width > 0):
    /// reconciles the stored table against the buffer — a mid-buffer edit
    /// rebuilds only the lines whose content changed (unchanged lines
    /// keep their paragraph pointer; matching is content-keyed so a
    /// shifted line survives). Returns false for an empty buffer or a
    /// missing paragraph backend — the same "no layout" signal hitLayout
    /// gives, so callers take identical fallbacks.
    pub fn syncLines(e: *Edit, size: f32) bool {
        const str = e.text();
        if (str.len == 0 or e.wrap_width <= 0) {
            if (e.line_paras.items.len != 0 or e.empty_para != null) e.clearLines();
            e.lines_built = false; // a stale lines_key must not short-circuit
            e.lines_ok = false;
            return false;
        }
        const rtl = ui.paint.textDirectionRtl();
        const geom = e.lines_size == size and e.lines_wrap == e.wrap_width and e.lines_rtl == rtl and
            e.lines_style.weight == e.hit_weight and e.lines_style.spacing == e.hit_spacing and
            e.lines_style.ink == e.hit_ink;
        const key = std.hash.Wyhash.hash(0, str);
        if (e.lines_built and geom and e.lines_key == key) return e.lines_ok;
        if (!geom) e.clearLines();
        e.lines_built = true;
        e.lines_key = key;
        e.lines_size = size;
        e.lines_wrap = e.wrap_width;
        e.lines_rtl = rtl;
        e.lines_style = .{ .weight = e.hit_weight, .spacing = e.hit_spacing, .ink = e.hit_ink };
        e.lines_ok = e.reconcileLines(str, size);
        return e.lines_ok;
    }

    /// Re-split the buffer into hard lines and reconcile against the
    /// stored table: kept lines' paragraphs survive, changed/added lines
    /// build, dropped lines' paragraphs are destroyed. Then the pass
    /// recomputes every line's layout-space y plus the totals.
    fn reconcileLines(e: *Edit, str: [:0]const u8, size: f32) bool {
        const a = e.buf.allocator;
        // The split — an O(text) byte scan, ~2 orders cheaper than shaping.
        // A '\n' ends its line; the buffer end ends the last one, so a
        // trailing '\n' yields a final empty line (the monolithic layout
        // carries one too — its height counts).
        e.line_spans.clearRetainingCapacity();
        var s: usize = 0;
        for (str, 0..) |c, i| {
            if (c == '\n') {
                e.line_spans.append(a, .{ .start = s, .end = i + 1, .content_end = i, .key = std.hash.Wyhash.hash(0, str[s..i]) }) catch @panic("klaxon: out of memory");
                s = i + 1;
            }
        }
        e.line_spans.append(a, .{ .start = s, .end = str.len, .content_end = str.len, .key = std.hash.Wyhash.hash(0, str[s..str.len]) }) catch @panic("klaxon: out of memory");
        const spans = e.line_spans.items;
        const old = e.line_paras.items;
        // Prefix pass — leading lines keep their paragraph when position
        // AND content match (the '\n' may come or go without touching the
        // shaped bytes — it lives outside the paragraph).
        var head: usize = 0;
        while (head < old.len and head < spans.len) {
            const o = &old[head];
            const n = &spans[head];
            if (o.start != n.start or o.content_end - o.start != n.content_end - n.start or
                o.key != n.key or (o.para != null) != (n.content_end > n.start)) break;
            head += 1;
        }
        // Suffix pass — content-identical trailing lines keep their
        // paragraph even when a mid-buffer edit shifted their offsets
        // (an insert in line 1 of 3 doesn't rebuild lines 2 and 3).
        var tail: usize = 0;
        while (tail < old.len - head and tail < spans.len - head) {
            const o = &old[old.len - 1 - tail];
            const n = &spans[spans.len - 1 - tail];
            if (o.content_end - o.start != n.content_end - n.start or o.key != n.key or
                (o.para != null) != (n.content_end > n.start)) break;
            tail += 1;
        }
        // Assemble the next table: kept head + middle + kept tail. A
        // middle span pairs with a stored middle entry carrying a seg
        // table so an edited long line keeps its shard granularity —
        // content-identical (moved) lines keep every seg, same-start
        // lines keep up to the dirty point, leftovers pair positionally.
        e.line_next.clearRetainingCapacity();
        e.line_next.ensureTotalCapacity(a, spans.len) catch @panic("klaxon: out of memory");
        e.line_next.appendSlice(a, old[0..head]) catch @panic("klaxon: out of memory");
        const mid_old = old[head .. old.len - tail];
        for (spans[head .. spans.len - tail]) |n| {
            var src: ?*LinePara = null;
            for (mid_old) |*o| {
                if (o.segs.items.len == 0) continue;
                if (o.content_end - o.start == n.content_end - n.start and o.key == n.key) {
                    src = o;
                    break;
                }
            }
            if (src == null) {
                for (mid_old) |*o| {
                    if (o.segs.items.len > 0 and o.start == n.start) {
                        src = o;
                        break;
                    }
                }
            }
            if (src == null) {
                for (mid_old) |*o| {
                    if (o.segs.items.len > 0) {
                        src = o;
                        break;
                    }
                }
            }
            if (src) |o| {
                var lp = o.*;
                o.segs = .empty; // moved — the destroy pass must skip it
                o.para = null;
                if (lp.para) |p| {
                    ui.paint.textLayoutDestroy(p);
                    lp.para = null;
                }
                lp.start = n.start;
                lp.end = n.end;
                lp.content_end = n.content_end;
                lp.key = n.key;
                e.line_next.append(a, lp) catch @panic("klaxon: out of memory");
            } else {
                e.line_next.append(a, .{ .start = n.start, .end = n.end, .content_end = n.content_end, .key = n.key }) catch @panic("klaxon: out of memory");
            }
        }
        e.line_next.appendSlice(a, old[old.len - tail ..]) catch @panic("klaxon: out of memory");
        // Refresh every entry's range from the new split — kept tail
        // entries shifted, and a kept line's `end` tracks a gained or
        // lost '\n' without its paragraph moving.
        for (e.line_next.items, 0..) |*lp, i| {
            lp.start = spans[i].start;
            lp.end = spans[i].end;
            lp.content_end = spans[i].content_end;
            lp.key = spans[i].key;
        }
        // Free the dropped middle lines' paragraphs + segs, then swap.
        for (mid_old) |*o| {
            if (o.para) |p| ui.paint.textLayoutDestroy(p);
            for (o.segs.items) |sg| {
                if (sg.para) |p| ui.paint.textLayoutDestroy(p);
            }
            o.segs.deinit(a);
        }
        e.line_paras.deinit(a);
        e.line_paras = e.line_next;
        e.line_next = .empty;
        // Measure: build paragraphs only for fresh lines — kept lines
        // reuse their cached h/w/base (same content + same style, wrap,
        // size, direction ⇒ same geometry). y accumulates over all of
        // them, so a kept line's band slides with the lines above. A
        // paired middle entry keeps its seg table — syncSegs reconciles
        // it against the new content shard by shard.
        var y: f32 = 0;
        var maxw: f32 = 0;
        var ok = true;
        for (e.line_paras.items) |*lp| {
            lp.y = y;
            if (lp.content_end == lp.start) {
                // Empty line — the shared " " paragraph supplies the
                // line-metrics height SkParagraph's own empty lines get;
                // it contributes no width and paints nothing.
                e.dropSegs(lp);
                if (e.empty_para == null) {
                    e.empty_para = e.buildLinePara(" ", size);
                    ok = ok and e.empty_para != null;
                }
                lp.h = if (e.empty_para) |p| ui.paint.textLayoutHeight(p) else ui.paint.measureTextStyled(" ", size, e.hit_weight, e.hit_spacing).height;
                lp.base = if (e.empty_para) |p| ui.paint.textLayoutBaseline(p) else 0;
                lp.w = 0;
            } else if (lp.segs.items.len > 0) {
                if (lp.para) |p| {
                    ui.paint.textLayoutDestroy(p);
                    lp.para = null;
                }
                ok = ok and e.syncSegs(lp, str, size);
            } else if (lp.para == null) {
                lp.para = e.buildLinePara(str[lp.start..lp.content_end], size);
                if (lp.para) |p| {
                    lp.h = ui.paint.textLayoutHeight(p);
                    lp.w = ui.paint.textLayoutWidth(p);
                    lp.base = ui.paint.textLayoutBaseline(p);
                    e.maybeSegment(lp, str, size);
                } else {
                    ok = false;
                    lp.h = ui.paint.measureTextStyled(" ", size, e.hit_weight, e.hit_spacing).height;
                    lp.w = 0;
                    lp.base = 0;
                }
            }
            y += lp.h;
            maxw = @max(maxw, lp.w);
        }
        e.lines_total_h = y;
        e.lines_max_w = maxw;
        return ok;
    }

    /// A line's rows are segmented once it wraps past this many — short
    /// lines keep the whole-line `para`, so most lines pay zero seg
    /// overhead. A seg's own para beyond it splits off its complete rows.
    const seg_row_budget: usize = 8;

    /// Uniform style ⇒ uniform row height; the first row's caret height
    /// supplies it. Position 0 sits on the first row for any non-empty
    /// paragraph.
    fn paraRowH(e: *const Edit, p: *ui.paint.TextLayout, size: f32) f32 {
        var r: [4]f32 = undefined;
        if (ui.paint.textLayoutCaretRect(p, 0, &r) and r[3] > 0) return r[3];
        return ui.paint.measureTextStyled(" ", size, e.hit_weight, e.hit_spacing).height;
    }

    /// Visual row count of a laid-out paragraph.
    fn paraRows(p: *ui.paint.TextLayout, row_h: f32) usize {
        if (row_h <= 0) return 0;
        return @intFromFloat(@round(ui.paint.textLayoutHeight(p) / row_h));
    }

    /// The byte offset (within `span`, the paragraph's own text) where
    /// its last visual row begins — probed at the row's left edge. No new
    /// C ABI: a position query at the row top + ε returns its first
    /// cluster.
    fn lastRowStart(p: *ui.paint.TextLayout, span: []const u8, row_h: f32, rows: usize) usize {
        if (rows == 0) return 0;
        const pos = ui.paint.textLayoutPositionAt(p, 0, @as(f32, @floatFromInt(rows - 1)) * row_h + 1);
        if (pos < 0) return 0;
        return utf16ToByteIndex(span, @intCast(pos));
    }

    /// Seg index covering byte offset `off` — the first seg whose end is
    /// past it, so a boundary offset belongs to the NEXT seg (the caret
    /// there is a row start, not a row tail). Clamps to the last seg.
    fn segIndexOf(lp: *const LinePara, off: usize) usize {
        const items = lp.segs.items;
        var lo: usize = 0;
        var hi: usize = items.len - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].end > off) hi = mid else lo = mid + 1;
        }
        return lo;
    }

    /// Seg index covering LINE-LOCAL `ly` — first seg whose bottom is
    /// past it. y above 0 → 0; past the last seg → last.
    fn segIndexOfY(lp: *const LinePara, ly: f32) usize {
        const items = lp.segs.items;
        var lo: usize = 0;
        var hi: usize = items.len - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].y + items[mid].h > ly) hi = mid else lo = mid + 1;
        }
        return lo;
    }

    /// A freshly built line is long enough to shard: seed the seg table
    /// with one seg covering the content (reusing the just-built para),
    /// then split off its complete rows so the tail stays small.
    fn maybeSegment(e: *Edit, lp: *LinePara, str: [:0]const u8, size: f32) void {
        const p = lp.para orelse return;
        if (e.hasStrongRtl()) return; // per-seg bidi could diverge
        const row_h = paraRowH(e, p, size);
        if (paraRows(p, row_h) <= seg_row_budget) return;
        lp.segs.append(e.buf.allocator, .{
            .start = lp.start,
            .end = lp.content_end,
            .key = lp.key,
            .para = p,
            .h = lp.h,
            .w = lp.w,
            .base = lp.base,
        }) catch @panic("klaxon: out of memory");
        lp.para = null;
        lp.segs_key = lp.key;
        _ = e.oversizeSplit(lp, lp.segs.items.len - 1, str, size);
    }

    /// If seg `idx` lays out past the row budget, split off its complete
    /// rows (all but the last) into a stable seg — one paragraph over
    /// those bytes — leaving a small remainder seg behind it. The split
    /// point is a real wrap boundary by construction, so both halves are
    /// exact.
    fn oversizeSplit(e: *Edit, lp: *LinePara, idx: usize, str: [:0]const u8, size: f32) bool {
        const a = e.buf.allocator;
        const sg = lp.segs.items[idx];
        const p = sg.para orelse return false;
        const row_h = paraRowH(e, p, size);
        const rows = paraRows(p, row_h);
        if (rows <= seg_row_budget) return true;
        const b = lastRowStart(p, str[sg.start..sg.end], row_h, rows);
        if (b == 0) return true; // degenerate: a single row can't split
        const stable = e.buildLinePara(str[sg.start .. sg.start + b], size);
        const tail = e.buildLinePara(str[sg.start + b .. sg.end], size);
        ui.paint.textLayoutDestroy(p);
        const stable_h = if (stable) |q| ui.paint.textLayoutHeight(q) else 0;
        lp.segs.items[idx] = .{
            .start = sg.start,
            .end = sg.start + b,
            .key = std.hash.Wyhash.hash(0, str[sg.start .. sg.start + b]),
            .para = stable,
            .y = sg.y,
            .h = stable_h,
            .w = if (stable) |q| ui.paint.textLayoutWidth(q) else 0,
            .base = if (stable) |q| ui.paint.textLayoutBaseline(q) else 0,
        };
        lp.segs.insert(a, idx + 1, .{
            .start = sg.start + b,
            .end = sg.end,
            .key = std.hash.Wyhash.hash(0, str[sg.start + b .. sg.end]),
            .para = tail,
            .y = sg.y + stable_h,
            .h = if (tail) |q| ui.paint.textLayoutHeight(q) else 0,
            .w = if (tail) |q| ui.paint.textLayoutWidth(q) else 0,
            .base = if (tail) |q| ui.paint.textLayoutBaseline(q) else 0,
        }) catch @panic("klaxon: out of memory");
        return stable != null and tail != null;
    }

    /// Reconcile a segmented line against its new content — lp's
    /// start/content_end/key are already refreshed. The stored segs
    /// partition the line's OLD content (seg[0].start is the old line
    /// start); this pass keeps matching prefix segs, keeps suffix segs
    /// only when a bridge paragraph proves their first boundary is still
    /// real, and otherwise rebuilds the tail as one seg — the re-wrap
    /// frontier stops at the first provable boundary.
    fn syncSegs(e: *Edit, lp: *LinePara, str: [:0]const u8, size: f32) bool {
        const a = e.buf.allocator;
        const segs = lp.segs.items;
        const old_start = segs[0].start;
        const old_end = segs[segs.len - 1].end;
        const new_start = lp.start;
        const new_end = lp.content_end;
        const new_len = new_end - new_start;
        var ok = true;

        // Fast path — the line's content is unchanged (same key) and the
        // seg table spans the same length: every seg is still exact, its
        // absolute offsets just shift by the delta. O(#segs), no hashing.
        if (lp.segs_key == lp.key and old_end - old_start == new_len) {
            const delta = @as(isize, @intCast(new_start)) - @as(isize, @intCast(old_start));
            var ly: f32 = 0;
            var maxw: f32 = 0;
            for (lp.segs.items) |*sg| {
                sg.start = @intCast(@as(isize, @intCast(sg.start)) + delta);
                sg.end = @intCast(@as(isize, @intCast(sg.end)) + delta);
                sg.y = ly;
                ly += sg.h;
                maxw = @max(maxw, sg.w);
            }
            lp.h = ly;
            lp.w = maxw;
            lp.base = lp.segs.items[0].base;
            return true;
        }

        // A strong-RTL buffer keeps whole-line paras — per-seg bidi
        // resolution could diverge. Collapse back to `para`.
        if (e.hasStrongRtl()) {
            e.dropSegs(lp);
            lp.para = e.buildLinePara(str[new_start..new_end], size);
            if (lp.para) |p| {
                lp.h = ui.paint.textLayoutHeight(p);
                lp.w = ui.paint.textLayoutWidth(p);
                lp.base = ui.paint.textLayoutBaseline(p);
                return true;
            }
            lp.h = ui.paint.measureTextStyled(" ", size, e.hit_weight, e.hit_spacing).height;
            lp.w = 0;
            lp.base = 0;
            return false;
        }

        // Prefix pass — a seg survives at the same position with the
        // same length and the same content hash: its wrap is provably
        // identical (row starts reset the break state).
        var pos: usize = 0;
        var head: usize = 0;
        while (head < segs.len) {
            const sg = &segs[head];
            const rel = sg.start - old_start;
            const len = sg.end - sg.start;
            if (rel != pos or pos + len > new_len) break;
            if (std.hash.Wyhash.hash(0, str[new_start + pos .. new_start + pos + len]) != sg.key) break;
            pos += len;
            head += 1;
        }
        // Suffix pass — content-identical segs anchored from the line's
        // end (a mid-line edit shifts their absolute offsets but not
        // their distance from the end).
        var tail_n: usize = 0;
        while (tail_n < segs.len - head) {
            const sg = &segs[segs.len - 1 - tail_n];
            const len = sg.end - sg.start;
            const from_end = old_end - sg.end;
            if (from_end + len > new_len - pos) break;
            const ns = new_end - from_end - len;
            if (std.hash.Wyhash.hash(0, str[ns .. ns + len]) != sg.key) break;
            tail_n += 1;
        }
        const fs = segs.len - tail_n; // first kept suffix seg index
        var mid_start = new_start + pos;

        // The dirty region's start is a kept seg's END — a real wrap
        // boundary only when both neighbouring bytes are unchanged
        // (a kept seg's START always satisfies that: its own bytes and
        // the previous seg's are identical). When content follows —
        // a dirty middle, or appended bytes continuing the old last row
        // — retreat one kept seg so the rebuild begins at a provable
        // boundary. Without this the appended tail would start mid-row.
        var dirty = mid_start < new_end;
        if (tail_n > 0) {
            const f_start = new_end - (old_end - segs[fs].start);
            dirty = mid_start < f_start;
        }
        if (dirty and head > 0) {
            head -= 1;
            pos = segs[head].start - old_start;
            mid_start = new_start + pos;
        }

        e.seg_next.clearRetainingCapacity();
        e.seg_next.ensureTotalCapacity(a, segs.len + 1) catch @panic("klaxon: out of memory");
        // Move kept prefix segs to their new absolute positions.
        for (segs[0..head]) |sg| {
            var ns = sg;
            ns.start = new_start + (sg.start - old_start);
            ns.end = ns.start + (sg.end - sg.start);
            e.seg_next.append(a, ns) catch @panic("klaxon: out of memory");
        }
        // Old segs in [head, destroy_upto) get destroyed; the kept
        // suffix moves at index destroy_upto and up.
        var destroy_upto = segs.len;
        var moved_from = segs.len; // index of first moved suffix seg
        var rebuild_tail = (tail_n == 0);
        var bridge_idx: ?usize = null; // seg_next index of a fused bridge seg
        if (tail_n > 0) {
            const first = &segs[fs];
            const f_start = new_end - (old_end - first.start);
            const f_end = new_end - (old_end - first.end);
            if (mid_start < f_start) {
                // The bridge covers the dirty middle PLUS the first kept
                // suffix seg — its last row must start at f_start for
                // the suffix's stored boundaries to be real.
                const bridge = e.buildLinePara(str[mid_start..f_end], size);
                var boundary_ok = false;
                if (bridge) |bp| {
                    const row_h = paraRowH(e, bp, size);
                    const b = lastRowStart(bp, str[mid_start..f_end], row_h, paraRows(bp, row_h));
                    boundary_ok = (mid_start + b == f_start);
                }
                if (boundary_ok) {
                    // Middle + first suffix seg fuse into one seg — the
                    // bridge para covers exactly that range and its last
                    // row IS the suffix's first row (just verified).
                    bridge_idx = e.seg_next.items.len;
                    e.seg_next.append(a, .{
                        .start = mid_start,
                        .end = f_end,
                        .key = std.hash.Wyhash.hash(0, str[mid_start..f_end]),
                        .para = bridge,
                        .h = ui.paint.textLayoutHeight(bridge.?),
                        .w = ui.paint.textLayoutWidth(bridge.?),
                        .base = ui.paint.textLayoutBaseline(bridge.?),
                    }) catch @panic("klaxon: out of memory");
                    destroy_upto = fs + 1; // fs was absorbed — its para dies
                    moved_from = fs + 1;
                } else {
                    if (bridge) |bp| ui.paint.textLayoutDestroy(bp);
                    rebuild_tail = true; // boundary drifted — drop the suffix
                }
            } else {
                // Empty middle — f_start == pos is the prefix end,
                // already a real boundary; the suffix stands untouched.
                destroy_upto = fs;
                moved_from = fs;
            }
        }
        if (rebuild_tail and mid_start < new_end) {
            // The tail: one paragraph over everything from the dirty
            // point — then ratchet off its complete rows if oversized.
            const tail = e.buildLinePara(str[mid_start..new_end], size);
            ok = ok and tail != null;
            e.seg_next.append(a, .{
                .start = mid_start,
                .end = new_end,
                .key = std.hash.Wyhash.hash(0, str[mid_start..new_end]),
                .para = tail,
                .h = if (tail) |q| ui.paint.textLayoutHeight(q) else 0,
                .w = if (tail) |q| ui.paint.textLayoutWidth(q) else 0,
                .base = if (tail) |q| ui.paint.textLayoutBaseline(q) else 0,
            }) catch @panic("klaxon: out of memory");
        }
        // Move kept suffix segs to their end-anchored absolute offsets.
        for (segs[moved_from..]) |sg| {
            var ns = sg;
            ns.start = new_end - (old_end - sg.start);
            ns.end = new_end - (old_end - sg.end);
            e.seg_next.append(a, ns) catch @panic("klaxon: out of memory");
        }
        // Destroy the dropped old segs' paragraphs, then swap tables.
        for (segs[head..destroy_upto]) |sg| {
            if (sg.para) |p| ui.paint.textLayoutDestroy(p);
        }
        lp.segs.clearRetainingCapacity();
        lp.segs.appendSlice(a, e.seg_next.items) catch @panic("klaxon: out of memory");

        // Ratchet: a freshly built seg splits off its complete rows when
        // it exceeds the budget — the fused bridge seg separates back
        // into middle + first-suffix at their verified boundary, and the
        // mutable tail stays small (~one row of shaping per keystroke).
        if (bridge_idx) |bi| {
            if (bi < lp.segs.items.len) ok = ok and e.oversizeSplit(lp, bi, str, size);
        }
        if (lp.segs.items.len > 0 and lp.segs.items.len - 1 != (bridge_idx orelse std.math.maxInt(usize))) {
            ok = ok and e.oversizeSplit(lp, lp.segs.items.len - 1, str, size);
        }
        lp.segs_key = lp.key;

        // Collapse: a single seg covering the whole content within the
        // budget is just `para` again (the line shrank back below it).
        if (lp.segs.items.len == 1) {
            const sg = lp.segs.items[0];
            if (sg.start == lp.start and sg.end == lp.content_end and sg.para != null and
                paraRows(sg.para.?, paraRowH(e, sg.para.?, size)) <= seg_row_budget)
            {
                lp.para = sg.para;
                lp.h = sg.h;
                lp.w = sg.w;
                lp.base = sg.base;
                lp.segs.items[0].para = null;
                lp.segs.clearRetainingCapacity();
                lp.segs_key = 0;
            }
        }

        // Aggregate line metrics + line-local seg offsets.
        var ly: f32 = 0;
        var maxw: f32 = 0;
        for (lp.segs.items) |*sg| {
            sg.y = ly;
            ly += sg.h;
            maxw = @max(maxw, sg.w);
        }
        if (lp.segs.items.len > 0) {
            lp.h = ly;
            lp.w = maxw;
            lp.base = lp.segs.items[0].base;
        }
        return ok;
    }

    /// The reconciled line table — meaningful only after syncLines.
    pub fn lineParas(e: *Edit) []const LinePara {
        return e.line_paras.items;
    }

    /// Total laid-out height across all hard lines (post-syncLines).
    pub fn linesHeight(e: *Edit) f32 {
        return e.lines_total_h;
    }

    /// The widest soft line across the table (post-syncLines) — the
    /// measure path's replacement for textLayoutWidth.
    pub fn linesWidth(e: *Edit) f32 {
        return e.lines_max_w;
    }

    /// The line index for a byte offset — a caret slot equal to a
    /// '\n'-terminated line's end already belongs to the NEXT line; the
    /// buffer end lands on the last. Post-syncLines only.
    pub fn lineIndexOf(e: *Edit, off: usize) ?usize {
        const items = e.line_paras.items;
        if (items.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = items.len - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].end > off) hi = mid else lo = mid + 1;
        }
        return lo;
    }

    /// The line index for a layout-space y — the line whose [y, y+h) band
    /// holds it; a y outside the table clamps to the nearest edge line,
    /// the same answer SkParagraph's clamping position query gives.
    fn lineIndexOfY(e: *Edit, py: f32) ?usize {
        const items = e.line_paras.items;
        if (items.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = items.len - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].y + items[mid].h > py) hi = mid else lo = mid + 1;
        }
        return lo;
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
        if (e.wrap_width > 0) {
            // Pick the line by y-band, then hit-test inside its own
            // paragraph at the line-local y — a y outside the table
            // clamps to the edge line like the monolithic query clamps.
            if (!e.syncLines(size)) return if (px <= 0) near else str.len - near;
            const i = e.lineIndexOfY(py) orelse return if (px <= 0) near else str.len - near;
            const lp = &e.line_paras.items[i];
            if (lp.segs.items.len > 0) {
                // Pick the seg by line-local y-band, then hit-test
                // inside its own paragraph.
                const ly = py - lp.y;
                const sg = &lp.segs.items[segIndexOfY(lp, ly)];
                const p = sg.para orelse return if (px <= 0) near else str.len - near;
                const pos = ui.paint.textLayoutPositionAt(p, px, ly - sg.y);
                if (pos < 0) return if (px <= 0) near else str.len - near;
                return sg.start + utf16ToByteIndex(str[sg.start..sg.end], @intCast(pos));
            }
            const para = lp.para orelse (e.empty_para orelse return if (px <= 0) near else str.len - near);
            const pos = ui.paint.textLayoutPositionAt(para, px, py - lp.y);
            if (pos < 0) return if (px <= 0) near else str.len - near;
            return lp.start + utf16ToByteIndex(str[lp.start..lp.content_end], @intCast(pos));
        }
        const l = e.hitLayout(size) orelse return if (px <= 0) near else str.len - near;
        const pos = ui.paint.textLayoutPositionAt(l, px, py);
        if (pos < 0) return if (px <= 0) near else str.len - near;
        return utf16ToByteIndex(str, @intCast(pos));
    }

    /// The caret's rect for `byte_off` in layout space — {x, top, 0, h}
    /// where top/h bound the caret's LINE (the paragraph's caret rect),
    /// direction-aware under RTL. null when the paragraph can't build.
    /// The multiline path queries the owning line's paragraph at the
    /// line-local offset and shifts the top by the line's y.
    pub fn caretRect(e: *Edit, byte_off: usize, size: f32) ?[4]f32 {
        if (e.wrap_width > 0) {
            const str = e.text();
            if (str.len == 0 or !e.syncLines(size)) return null;
            const off = @min(byte_off, str.len);
            var i = e.lineIndexOf(off) orelse return null;
            // The buffer-end caret behind a trailing '\n': the monolithic
            // paragraph answers with the '\n' glyph's bounds — the
            // terminated line's trailing edge, not the empty last line.
            if (off == str.len and str[off - 1] == '\n' and i > 0) i -= 1;
            const lp = &e.line_paras.items[i];
            if (lp.segs.items.len > 0) {
                const sg = &lp.segs.items[segIndexOf(lp, off)];
                const p = sg.para orelse return null;
                const local = @min(off - sg.start, sg.end - sg.start);
                var r: [4]f32 = undefined;
                if (!ui.paint.textLayoutCaretRect(p, byteToUtf16Index(str[sg.start..sg.end], local), &r)) return null;
                r[1] += lp.y + sg.y;
                return r;
            }
            const para = lp.para orelse (e.empty_para orelse return null);
            const local = @min(off - lp.start, lp.content_end - lp.start);
            var r: [4]f32 = undefined;
            if (!ui.paint.textLayoutCaretRect(para, byteToUtf16Index(str[lp.start..lp.content_end], local), &r)) return null;
            r[1] += lp.y;
            return r;
        }
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
        // Fast path (single-line, no strong-RTL content): the run paints
        // L→R in logical order — every seg draws its glyphs left-to-right
        // at its own offset — so the caret x is exactly the prefix advance.
        // The widget's seg-memoized measure makes this O(cached segs);
        // without the hook a one-shot measure still skips the paragraph.
        if (e.wrap_width == 0 and !e.hasStrongRtl()) {
            const str = e.text();
            const off = @min(byte_off, str.len);
            if (e.measure_prefix) |mp| return mp(e, off, size);
            return ui.paint.measureTextLenStyled(str[0..off], size, e.hit_weight, e.hit_spacing).width;
        }
        return (e.caretRect(byte_off, size) orelse return null)[0];
    }

    /// The glyph boxes covering byte range [lo, hi) in layout space —
    /// one per run when the range crosses a bidi boundary, which is what
    /// the selection highlight must paint under mixed direction. `out`
    /// gets {x,y,w,h} quads; null when the paragraph can't build.
    pub fn caretBoxes(e: *Edit, lo: usize, hi: usize, size: f32, out: [][4]f32) ?usize {
        const str = e.text();
        if (e.wrap_width > 0) {
            // Each affected hard line contributes its own local-range
            // boxes (a wrapped line yields one per soft row; a bidi run
            // one per run) shifted by the line's y — a cross-hard-line
            // selection is naturally one or more boxes per line.
            if (str.len == 0 or !e.syncLines(size)) return null;
            const items = e.line_paras.items;
            var i = e.lineIndexOf(@min(lo, str.len)) orelse return null;
            var total: usize = 0;
            while (i < items.len) : (i += 1) {
                const lp = &items[i];
                if (lp.start >= hi) break;
                const s = @max(lo, lp.start);
                const t = @min(hi, lp.content_end);
                if (s < t) {
                    if (lp.segs.items.len > 0) {
                        // Same boxes one level down — per-seg local
                        // ranges shifted by lp.y + seg.y. A boundary seg
                        // start (s == sg.start) maps into that seg; an
                        // interior end clips at its seg's edge.
                        var si = segIndexOf(lp, s);
                        while (si < lp.segs.items.len) : (si += 1) {
                            const sg = &lp.segs.items[si];
                            if (sg.start >= t) break;
                            const p = sg.para orelse continue;
                            const s2 = @max(s, sg.start);
                            const t2 = @min(t, sg.end);
                            if (s2 >= t2) continue;
                            const content = str[sg.start..sg.end];
                            const lo16 = byteToUtf16Index(content, s2 - sg.start);
                            const hi16 = byteToUtf16Index(content, t2 - sg.start);
                            const cnt = ui.paint.textLayoutRectsForRange(p, lo16, hi16, &.{}) orelse return null;
                            if (total + cnt <= out.len) {
                                _ = ui.paint.textLayoutRectsForRange(p, lo16, hi16, out[total .. total + cnt]);
                                for (out[total .. total + cnt]) |*b| b[1] += lp.y + sg.y;
                            }
                            total += cnt;
                        }
                        continue;
                    }
                    const para = lp.para orelse (e.empty_para orelse continue);
                    const content = str[lp.start..lp.content_end];
                    const lo16 = byteToUtf16Index(content, s - lp.start);
                    const hi16 = byteToUtf16Index(content, t - lp.start);
                    const cnt = ui.paint.textLayoutRectsForRange(para, lo16, hi16, &.{}) orelse return null;
                    if (total + cnt <= out.len) {
                        _ = ui.paint.textLayoutRectsForRange(para, lo16, hi16, out[total .. total + cnt]);
                        for (out[total .. total + cnt]) |*b| b[1] += lp.y;
                    }
                    total += cnt;
                } else if (lo < lp.end and hi > lp.content_end) {
                    // Only the '\n' is covered — the monolithic paragraph
                    // emits a zero-width box at the terminated edge; keep
                    // the same count so the caller's buffer sizing agrees
                    // (a 0-width box paints no pixels either way).
                    const g = e.caretRect(@min(lp.content_end, str.len), size) orelse [4]f32{ 0, lp.y, 0, lp.h };
                    if (total < out.len) out[total] = .{ g[0], g[1], 0, g[3] };
                    total += 1;
                }
            }
            return total;
        }
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
        const str = e.text();
        // One pixel past the line box lands on the neighbour line.
        const y = if (dir < 0) r[1] - 1 else r[1] + r[3] + 1;
        var next: usize = undefined;
        if (e.wrap_width > 0 and e.syncLines(size)) {
            // The target y-band picks the line — more soft rows of the
            // same hard line or the next/prev hard line — and its own
            // paragraph hit-tests the sticky column at a line-local y.
            const i = e.lineIndexOfY(y) orelse return if (dir < 0) 0 else str.len;
            const lp = &e.line_paras.items[i];
            if (lp.segs.items.len > 0) {
                const ly = y - lp.y;
                const sg = &lp.segs.items[segIndexOfY(lp, ly)];
                const p = sg.para orelse return e.caret;
                const pos = ui.paint.textLayoutPositionAt(p, aim, ly - sg.y);
                if (pos < 0) return e.caret;
                next = sg.start + utf16ToByteIndex(str[sg.start..sg.end], @intCast(pos));
            } else {
                const para = lp.para orelse (e.empty_para orelse return e.caret);
                const pos = ui.paint.textLayoutPositionAt(para, aim, y - lp.y);
                if (pos < 0) return e.caret;
                next = lp.start + utf16ToByteIndex(str[lp.start..lp.content_end], @intCast(pos));
            }
        } else {
            const l = e.hitLayout(size) orelse return e.caret;
            const pos = ui.paint.textLayoutPositionAt(l, aim, y);
            if (pos < 0) return e.caret;
            next = utf16ToByteIndex(str, @intCast(pos));
        }
        e.v_motion_x = aim;
        // The position query clamps onto the nearest line — landing on
        // the caret's OWN line means there's no line in `dir`, so the
        // caret goes to the document edge (Compose semantics).
        if (e.caretRect(next, size)) |nr| {
            if (nr[1] == r[1]) return if (dir < 0) 0 else str.len;
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
        const str = e.text();
        // The query clamps dx into the line, so an x past the far edge
        // lands on the boundary — 1e9 stands in for "the end edge" under
        // both constrained and unconstrained layouts.
        const edge_x: f32 = if ((dir < 0) == ui.paint.textDirectionRtl()) 1e9 else 0;
        if (e.wrap_width > 0 and e.syncLines(size)) {
            // The caret rect's own mid-height picks the row's hard line —
            // for the trailing-'\n' end caret that's the terminated line
            // above, matching where the caret was answered.
            const i = e.lineIndexOfY(r[1] + r[3] / 2) orelse return if (dir < 0) 0 else str.len;
            const lp = &e.line_paras.items[i];
            const mid_y = r[1] + r[3] / 2 - lp.y;
            if (lp.segs.items.len > 0) {
                const sg = &lp.segs.items[segIndexOfY(lp, mid_y)];
                const p = sg.para orelse return if (dir < 0) 0 else str.len;
                const pos = ui.paint.textLayoutPositionAt(p, edge_x, mid_y - sg.y);
                if (pos < 0) return if (dir < 0) 0 else str.len;
                return sg.start + utf16ToByteIndex(str[sg.start..sg.end], @intCast(pos));
            }
            const para = lp.para orelse (e.empty_para orelse return if (dir < 0) 0 else str.len);
            const pos = ui.paint.textLayoutPositionAt(para, edge_x, mid_y);
            if (pos < 0) return if (dir < 0) 0 else str.len;
            return lp.start + utf16ToByteIndex(str[lp.start..lp.content_end], @intCast(pos));
        }
        const l = e.hitLayout(size) orelse return if (dir < 0) 0 else str.len;
        const pos = ui.paint.textLayoutPositionAt(l, edge_x, r[1] + r[3] / 2);
        if (pos < 0) return if (dir < 0) 0 else str.len;
        return utf16ToByteIndex(str, @intCast(pos));
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
/// Conservative strong-RTL / bidi-control scan: true when the text holds
/// any codepoint whose presence can reorder the painted glyph sequence
/// (Unicode Bidi_Class R/AL blocks + the isolates and marks that steer
/// the bidi algorithm). Over-flags deliberately (a few LTR-neutral chars
/// in RTL blocks count) — a false positive just takes the paragraph path.
fn scanStrongRtl(str: []const u8) bool {
    var i: usize = 0;
    while (i < str.len) {
        const n = std.unicode.utf8ByteSequenceLength(str[i]) catch return true;
        if (i + n > str.len) return true; // truncated seq — play safe
        const cp = std.unicode.utf8Decode(str[i..][0..n]) catch return true;
        if (isRtlCp(cp)) return true;
        i += n;
    }
    return false;
}

fn isRtlCp(cp: u21) bool {
    return (cp >= 0x0590 and cp <= 0x08FF) or // Hebrew/Arabic/Syriac/Thaana/N'Ko/Samaritan/Mandaic blocks
        (cp >= 0xFB1D and cp <= 0xFDFF) or // Hebrew + Arabic presentation forms A
        (cp >= 0xFE70 and cp <= 0xFEFF) or // Arabic presentation forms B
        (cp >= 0x10800 and cp <= 0x10FFF) or // astral RTL scripts
        (cp >= 0x1E800 and cp <= 0x1EFFF) or // Mende/Adlam/…
        cp == 0x200F or cp == 0x202B or cp == 0x202E or
        (cp >= 0x2066 and cp <= 0x2069); // bidi isolates
}

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

// "aa\nbb\ncc": line 1 = [0,3), line 2 = [3,6), line 3 = [6,8).
test "edit: an edit in one line rebuilds only that line's paragraph" {
    const a = std.testing.allocator;
    const t = try testEdit(a, "aa\nbb\ncc", 200);
    defer freeTestEdit(a, t.n, t.e);
    const e = t.e;
    const size: f32 = 16;
    try std.testing.expect(e.syncLines(size));
    try std.testing.expectEqual(@as(usize, 3), e.lineParas().len);
    const p0 = e.lineParas()[0].para orelse return error.TestUnexpectedResult;
    const p2 = e.lineParas()[2].para orelse return error.TestUnexpectedResult;
    const builds = e.para_builds; // 3 paragraphs built so far
    // Insert inside line 2 — "bb" → "bXb": only its paragraph rebuilds;
    // lines 1 and 3 keep their pointers even though line 3's offsets moved.
    e.moveCaret(4, false);
    _ = e.insert("X");
    try std.testing.expectEqualStrings("aa\nbXb\ncc", e.text());
    try std.testing.expect(e.syncLines(size));
    try std.testing.expectEqual(@as(usize, 3), e.lineParas().len);
    try std.testing.expectEqual(p0, e.lineParas()[0].para.?);
    try std.testing.expectEqual(p2, e.lineParas()[2].para.?);
    try std.testing.expectEqual(builds + 1, e.para_builds);
    // A '\n' insertion splits a line: two fresh paragraphs, the rest kept.
    e.moveCaret(0, false);
    _ = e.insert("\n"); // "" line + "aa\n" + "bXb\n" + "cc"
    try std.testing.expectEqualStrings("\naa\nbXb\ncc", e.text());
    try std.testing.expect(e.syncLines(size));
    try std.testing.expectEqual(@as(usize, 4), e.lineParas().len);
    try std.testing.expectEqual(p0, e.lineParas()[1].para.?);
    try std.testing.expectEqual(p2, e.lineParas()[3].para.?);
}

test "edit: line-table geometry — caret tops, hit-testing, selection boxes" {
    // Geometry equality is calibrated to the platform default font's
    // metrics (CoreText); other hosts resolve a different face.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const a = std.testing.allocator;
    const t = try testEdit(a, "aa\nbb\ncc", 200);
    defer freeTestEdit(a, t.n, t.e);
    const e = t.e;
    const size: f32 = 16;
    const r0 = e.caretRect(0, size) orelse return error.TestUnexpectedResult;
    const r1 = e.caretRect(3, size) orelse return error.TestUnexpectedResult;
    const r2 = e.caretRect(6, size) orelse return error.TestUnexpectedResult;
    // Line starts stack at x = 0, each one line-height below the previous.
    try std.testing.expectEqual(@as(f32, 0), r0[0]);
    try std.testing.expectEqual(@as(f32, 0), r1[0]);
    try std.testing.expectEqual(@as(f32, 0), r2[0]);
    try std.testing.expectEqual(r0[1] + r0[3], r1[1]);
    try std.testing.expectEqual(r1[1] + r1[3], r2[1]);
    // The line-end caret is at the line's laid-out width on its own row.
    const re = e.caretRect(2, size) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(r0[1], re[1]);
    try std.testing.expect(re[0] > 0);
    // Hit-test: a point inside line 2's band maps to its start at x=0.
    try std.testing.expectEqual(@as(usize, 3), e.caretAt(0.5, r1[1] + 1, size));
    try std.testing.expectEqual(@as(usize, 6), e.caretAt(0.5, r2[1] + 1, size));
    // Below the table the last line answers (the clamped-edge query).
    const below = e.caretAt(0.5, r2[1] + r2[3] + 50, size);
    try std.testing.expect(below >= 6 and below <= 8);
    // Cross-line selection [1, 8): one box per line.
    var boxes: [8][4]f32 = undefined;
    const nb = e.caretBoxes(1, 8, size, &boxes) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), nb);
    try std.testing.expectEqual(r0[1], boxes[0][1]);
    try std.testing.expectEqual(r1[1], boxes[1][1]);
    try std.testing.expectEqual(r2[1], boxes[2][1]);
    // A mid-line insertion shifts later lines' bands, not their heights.
    e.moveCaret(4, false);
    _ = e.insert("XXXXX XXXXX XXXXX XXXXX XXXXX XXXXX XXXXX XXXXX"); // wraps line 2
    const r1w = e.caretRect(4, size) orelse return error.TestUnexpectedResult;
    const r2w = e.caretRect(e.buf.items.len, size) orelse return error.TestUnexpectedResult;
    try std.testing.expect(r2w[1] > r1w[1]); // the last line moved down
    try std.testing.expectEqual(r0[3], r2w[3]); // its own row height unchanged
}

test "edit: a trailing newline yields a counted empty last line" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const a = std.testing.allocator;
    const t = try testEdit(a, "aa\n", 200);
    defer freeTestEdit(a, t.n, t.e);
    const e = t.e;
    const size: f32 = 16;
    try std.testing.expect(e.syncLines(size));
    const items = e.lineParas();
    try std.testing.expectEqual(@as(usize, 2), items.len);
    // The trailing empty line has no paragraph of its own but a real
    // height — SkParagraph's in-text empty lines carry the style's
    // metrics; the shared " " paragraph supplies the same.
    try std.testing.expect(items[1].para == null);
    try std.testing.expect(items[1].h > 0);
    try std.testing.expectEqual(items[0].h, items[1].h); // the uniform style
    try std.testing.expectEqual(items[0].h + items[1].h, e.linesHeight());
    // The buffer-end caret behind a trailing '\n' renders at the
    // terminated line's trailing edge — the monolithic paragraph answers
    // the '\n' glyph's bounds (line 1's end), not the empty line.
    const r = e.caretRect(3, size) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 0), r[1]);
    try std.testing.expect(r[0] > 0);
    // …but a click INTO the empty last line still resolves to offset 3.
    try std.testing.expectEqual(@as(usize, 3), e.caretAt(1, items[1].y + 1, size));
    // Consecutive newlines: "a\n\nb" — the empty middle line counts.
    const m = try testEdit(a, "a\n\nb", 200);
    defer freeTestEdit(a, m.n, m.e);
    try std.testing.expect(m.e.syncLines(size));
    const mi = m.e.lineParas();
    try std.testing.expectEqual(@as(usize, 3), mi.len);
    try std.testing.expect(mi[1].para == null and mi[1].h > 0);
    const rm = m.e.caretRect(2, size) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mi[0].h, rm[1]); // the empty line's row
    try std.testing.expectEqual(@as(f32, 0), rm[0]);
}

/// A test scratch pad: `text` repeated `n` times, sentinel-terminated.
fn testRepeat(comptime n: usize, comptime text: []const u8) *const [text.len * n:0]u8 {
    const S = struct {
        var buf: [text.len * n:0]u8 = undefined;
    };
    for (0..n) |i| @memcpy(S.buf[i * text.len ..][0..text.len], text);
    S.buf[text.len * n] = 0;
    return &S.buf;
}

// One ~2000-byte hard line — no '\n' — wraps to dozens of soft rows at
// wrap 200; the seg table is the same incremental idea one level down.
test "edit: appends to a soft-wrapped line rebuild only the tail seg" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const a = std.testing.allocator;
    const t = try testEdit(a, testRepeat(2000, "x"), 200);
    defer freeTestEdit(a, t.n, t.e);
    const e = t.e;
    const size: f32 = 16;
    try std.testing.expect(e.syncLines(size));
    try std.testing.expectEqual(@as(usize, 1), e.lineParas().len);
    const lp = e.lineParas()[0];
    // Engaged: the line is segmented at real wrap boundaries, the
    // mutable tail holding only its last rows.
    try std.testing.expect(lp.segs.items.len >= 2);
    try std.testing.expect(lp.para == null);
    const tail = lp.segs.items[lp.segs.items.len - 1];
    try std.testing.expect(tail.h < lp.h / 4.0);
    const p0 = lp.segs.items[0].para;

    // One 50-char insert at the end — O(1) builds (the tail's own
    // rebuild + a possible promote), NOT ~one-per-row.
    var before = e.para_builds;
    _ = e.insert(testRepeat(50, "y"));
    try std.testing.expect(e.syncLines(size));
    try std.testing.expect(e.para_builds - before <= 4);

    // Ten single keystrokes — each costs ~one small tail para, never a
    // re-lay of the line's stable segs.
    for (0..10) |_| {
        before = e.para_builds;
        _ = e.insert("z");
        try std.testing.expect(e.syncLines(size));
        try std.testing.expect(e.para_builds - before <= 4);
    }
    // The stable segs' paragraphs survived all of it.
    const lp2 = e.lineParas()[0];
    try std.testing.expect(lp2.segs.items.len >= 2);
    try std.testing.expect(lp2.segs.items[0].para == p0);

    // Pure appends continue the LAST ROW — the old content end was never
    // a real boundary — so the grown tail's geometry must still answer
    // bit-identically to the monolithic layout. (The reconcile retreats
    // one kept seg so the rebuild starts inside unchanged bytes.)
    const str = e.text();
    const mono = e.hitLayout(size) orelse return error.TestUnexpectedResult;
    var off = str.len - 60;
    while (off <= str.len) : (off += 7) {
        var want: [4]f32 = undefined;
        try std.testing.expect(ui.paint.textLayoutCaretRect(mono, byteToUtf16Index(str, off), &want));
        try std.testing.expectEqual(want, e.caretRect(off, size).?);
    }
    // …and the hit-test over the grown tail's band maps identically.
    const tail2 = lp2.segs.items[lp2.segs.items.len - 1];
    var px: f32 = 3;
    while (px < 210) : (px += 31) {
        const py = lp2.y + tail2.y + tail2.h - 1;
        const pos = ui.paint.textLayoutPositionAt(mono, px, py);
        const want = if (pos < 0) 0 else utf16ToByteIndex(str, @intCast(pos));
        try std.testing.expectEqual(want, e.caretAt(px, py, size));
    }
}

test "edit: a segmented line's geometry matches the monolithic paragraph" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const a = std.testing.allocator;
    const t = try testEdit(a, testRepeat(64, "abcdefghijklmnopqrstuvwxyzabc "), 200);
    defer freeTestEdit(a, t.n, t.e);
    const e = t.e;
    const size: f32 = 16;
    try std.testing.expect(e.syncLines(size));
    const lp0 = e.lineParas()[0];
    try std.testing.expect(lp0.segs.items.len >= 2); // engaged
    const str = e.text();
    const mono = e.hitLayout(size) orelse return error.TestUnexpectedResult;

    // Caret rects: every 37th offset plus the exact seg boundaries —
    // per-seg answers must be bit-identical to the monolithic layout's.
    var off: usize = 0;
    while (off <= str.len) : (off += 37) {
        var want: [4]f32 = undefined;
        try std.testing.expect(ui.paint.textLayoutCaretRect(mono, byteToUtf16Index(str, off), &want));
        try std.testing.expectEqual(want, e.caretRect(off, size).?);
    }
    for (lp0.segs.items) |sg| {
        for ([_]usize{ sg.start, sg.end }) |b| {
            var want: [4]f32 = undefined;
            try std.testing.expect(ui.paint.textLayoutCaretRect(mono, byteToUtf16Index(str, b), &want));
            try std.testing.expectEqual(want, e.caretRect(@min(b, str.len), size).?);
        }
    }
    // Hit-test: a grid over the line's whole band maps identically.
    var py: f32 = 1;
    while (py < e.linesHeight()) : (py += 13.7) {
        var px: f32 = 3;
        while (px < 210) : (px += 41) {
            const pos = ui.paint.textLayoutPositionAt(mono, px, py);
            const want = if (pos < 0) 0 else utf16ToByteIndex(str, @intCast(pos));
            try std.testing.expectEqual(want, e.caretAt(px, py, size));
        }
    }
    // Selection across several rows: same boxes, same count.
    var got: [32][4]f32 = undefined;
    var want_boxes: [32][4]f32 = undefined;
    const lo: usize = 950;
    const hi: usize = 1050;
    const lo16 = byteToUtf16Index(str, lo);
    const hi16 = byteToUtf16Index(str, hi);
    const cnt = e.caretBoxes(lo, hi, size, &got) orelse return error.TestUnexpectedResult;
    const mono_cnt = ui.paint.textLayoutRectsForRange(mono, lo16, hi16, &.{}).?;
    try std.testing.expectEqual(mono_cnt, cnt);
    _ = ui.paint.textLayoutRectsForRange(mono, lo16, hi16, want_boxes[0..mono_cnt]);
    for (0..cnt) |i| try std.testing.expectEqual(want_boxes[i], got[i]);

    // A mid-line edit re-verifies boundaries downstream — geometry still
    // bit-identical to a fresh monolithic layout.
    e.moveCaret(960, false);
    _ = e.insert("QQQ");
    try std.testing.expect(e.syncLines(size));
    const str2 = e.text();
    const mono2 = e.hitLayout(size) orelse return error.TestUnexpectedResult;
    off = 0;
    while (off <= str2.len) : (off += 41) {
        var want: [4]f32 = undefined;
        try std.testing.expect(ui.paint.textLayoutCaretRect(mono2, byteToUtf16Index(str2, off), &want));
        try std.testing.expectEqual(want, e.caretRect(off, size).?);
    }
}

test "edit: a strong-RTL line keeps its whole-line paragraph" {
    const a = std.testing.allocator;
    // Hebrew words — strong RTL — long enough to wrap past the budget.
    const t = try testEdit(a, testRepeat(60, "שלום עולם "), 200);
    defer freeTestEdit(a, t.n, t.e);
    const e = t.e;
    const size: f32 = 16;
    try std.testing.expect(e.syncLines(size));
    try std.testing.expect(e.hasStrongRtl());
    const lp = e.lineParas()[0];
    // Per-seg bidi resolution could diverge — segs must stay off.
    try std.testing.expectEqual(@as(usize, 0), lp.segs.items.len);
    try std.testing.expect(lp.para != null);
    const r = e.caretRect(4, size) orelse return error.TestUnexpectedResult;
    try std.testing.expect(r[3] > 0);
}
