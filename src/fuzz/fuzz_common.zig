// Fuzz harness shared helpers (test-only — built via `zig build fuzz`, never
// linked into app binaries).
//
// Two complementary consumption styles per Zig 0.17's std.testing.fuzz:
//   - `blob()` pulls the whole input through ONE Smith draw — the raw bytes
//     are the test case (JSON documents, ARB files).
//   - `Reader` decodes that blob into an op stream — deterministic cursor
//     semantics, so a crashing input is itself the minimal reproducer
//     (hex-dump it and feed it back through the corpus).
const std = @import("std");

const Smith = std.testing.Smith;
pub const Weight = Smith.Weight;

/// Pull the whole fuzz input as one draw. `byte_weights` shape the byte
/// distribution (bias toward structural bytes); the length is biased toward
/// short inputs with a long tail up to buf.len.
pub fn blob(smith: *Smith, buf: []u8, byte_weights: []const Weight) []const u8 {
    const n = smith.sliceWeighted(
        buf,
        &.{ .rangeAtMost(u32, 0, 64, 3), .rangeAtMost(u32, 0, @intCast(buf.len), 1) },
        byte_weights,
    );
    return buf[0..n];
}

/// A deterministic byte cursor over the input: every read shrinks it;
/// exhausted reads yield 0 (never error). Op streams decode as
/// `while (r.in.len > 0) switch (r.byte() % N) ...`.
pub const Reader = struct {
    in: []const u8,

    pub fn byte(r: *Reader) u8 {
        if (r.in.len == 0) return 0;
        const b = r.in[0];
        r.in = r.in[1..];
        return b;
    }

    /// One byte mod the item count — an index into `items`.
    pub fn pick(r: *Reader, comptime T: type, items: []const T) T {
        return items[r.byte() % items.len];
    }

    /// `cap`-bounded length-prefixed slice (the leading byte mod cap+1 is
    /// the length, then the bytes themselves).
    pub fn span(r: *Reader, cap: usize) []const u8 {
        return r.take(@min(@as(usize, r.byte()) % (cap + 1), r.in.len));
    }

    pub fn take(r: *Reader, n: usize) []const u8 {
        const k = @min(n, r.in.len);
        const s = r.in[0..k];
        r.in = r.in[k..];
        return s;
    }

    /// Little-endian int of any width — missing bytes read as 0.
    pub fn int(r: *Reader, comptime T: type) T {
        var b: [@sizeOf(T)]u8 = @splat(0);
        const got = r.take(@sizeOf(T));
        @memcpy(b[0..got.len], got);
        return std.mem.readInt(T, &b, .little);
    }

    pub fn flag(r: *Reader) bool {
        return r.byte() & 1 != 0;
    }

    /// A signed value centered on 0 (i8 → i32) — comp_start-style offsets.
    pub fn rel(r: *Reader) i32 {
        return @as(i32, @as(i8, @bitCast(r.byte())));
    }
};

/// Tricky-text dictionary shared by the text/input harnesses: multibyte
/// UTF-8, emoji + ZWJ/flag clusters, combining marks, RTL + bidi controls,
/// line endings, truncated/invalid UTF-8 fragments, CJK.
pub const text_dict = [_][]const u8{
    "",
    "a",
    "hello",
    "héllo wörld",
    "こんにちは世界",
    "👨‍👩‍👧‍👦",
    "🇫🇷🇯🇵",
    "אבגדה",
    "áb̧",
    "x\r\ny\rz\nw",
    "\xF0\x9F\x91",
    "\xFF\xFE\x80\xC0\xE0",
    "                                                ",
    "abcdefghijklmnopqrstuvwxyz0123456789",
    "١٢٣٤٥",
    "‮rtl‬",
    "{count, plural, =0{none} one{#} other{#}}",
    "\t  tabs\tand  spaces",
    "the quick brown fox jumps over the lazy dog",
};

/// Clipboard stub (the platform impl is installed by the host — headless
//  harnesses install this in-memory one so Cmd/Ctrl+C/X/V has somewhere
//  to go). Pattern lifted from widgets/text_edit.zig's own tests.
pub const Clip = struct {
    pub var slot: [512]u8 = undefined;
    pub var len: usize = 0;

    pub fn getImpl(allocator: std.mem.Allocator) ?[]u8 {
        if (len == 0) return null;
        return allocator.dupe(u8, slot[0..len]) catch null;
    }

    pub fn setImpl(text: []const u8) void {
        len = @min(text.len, slot.len);
        @memcpy(slot[0..len], text[0..len]);
    }

    pub fn install() void {
        @import("klaxon").ui.clipboard.install(.{ .get = getImpl, .set = setImpl });
    }
};
