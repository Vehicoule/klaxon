// Fuzz harness: arb — bytes → the ARB (Application Resource Bundle) JSON
// parser in ui/i18n.zig, plus the ICU-style plural machinery it feeds:
// `Locale.parseArb` (std.json over untrusted bytes), `parsePlural`'s
// hand-rolled `{name, plural, sel{text}}` scanner, `selectPlural` over the
// baked-in CLDR rules, `interpolate` placeholder substitution, and the
// locale-aware `formatNumber`/`formatDate` paths. Every allocation runs on
// the fuzz runner's leak-checking allocator.
const std = @import("std");
const klaxon = @import("klaxon");
const ui = klaxon.ui;
const fuzz = @import("fuzz_common.zig");

const Smith = std.testing.Smith;
const Reader = fuzz.Reader;
const i18n_mod = ui.i18n;
const I18n = i18n_mod.I18n;
const Locale = i18n_mod.Locale;

const tags = [_][]const u8{
    "en",    "en-US", "fr",    "fr-FR", "de",    "ja",    "ar",
    "ar-EG", "cs",    "ru",    "pl",    "zh",    "ko",    "pt-BR",
    "he",    "hi",    "cy",    "gd",    "lt",    "lv",    "mk",
    "ro",    "sl",    "mt",    "br",    "ga",    "sh",    "tl",
    "x",     "",      "EN_us", "a",     "zzz-ZZZ", "fr_CA",
};

const keys = [_][]const u8{
    "greeting", "items", "files", "plain", "k0", "k1", "k2", "k3",
    "@@locale", "@meta", "", "a", "nonexistent_key_name",
};

/// Message bodies: valid + degenerate plural blocks, interpolations,
/// nesting, unclosed braces — the parser must reject or survive all of it.
const msgs = [_][]const u8{
    "Hello {name}!",
    "{count, plural, =0{no items} one{# item} other{# items}}",
    "{n, plural, few{pár} many{hodně} other{x}}",
    "{count, plural, =0{zero} =1{one} =2{two} =-3{neg} other{many}}",
    "pre {count, plural, one{#} other{#}} post",
    "{count,plural,one{a {name} b} other{c {count} d}}",
    "{count , plural , zero{} other{}}",
    "{count, plural, boguskw{x} other{y}}",
    "{,plural,other{x}}",
    "{count plural other{x}}",
    "{count, plural, other{",
    "plain text",
    "# # #",
    "{unclosed",
    "{name} {name} {nope} {}",
    "{count, plural, one{} other{}}",
    "١٢٣ {count} ﭐ",
    "{c, plural, =0{a} =0{b} other{c}}",
    "{count, plural, one{x} one{y} other{z}}",
    "{q, plural, one{one} other{other}} trailing {count, plural, one{e} other{f}}",
};

const Args = struct { name: []const u8 = "x", count: i64 = 0, n: i64 = 0 };

/// Build a generated ARB document: `{"k0":"msg","k1":"msg",...}` (a
/// handful of entries, one occasionally an `@`-metadata pair).
fn genArb(r: *Reader, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("{") catch {};
    const n = 1 + r.byte() % 6;
    for (0..n) |i| {
        if (i > 0) w.writeAll(",") catch {};
        const meta = r.byte() % 8 == 0;
        w.print("\"{s}k{d}\":\"", .{ if (meta) "@" else "", i }) catch {};
        w.writeAll(r.pick([]const u8, &msgs)) catch {};
        // Generated docs are raw-quoted — JSON-incompatible bytes in the
        // fragment are part of the test (parseArb must handle rejects).
        w.writeAll("\"") catch {};
    }
    // Occasionally append a non-string value / truncated tail.
    switch (r.byte() % 6) {
        0 => w.writeAll(",\"extra\":123}") catch {},
        1 => w.writeAll(",\"extra\":null}") catch {},
        2 => w.writeAll("}") catch {},
        3 => w.writeAll(",\"x\":[1,2]") catch {},
        else => w.writeAll("}") catch {},
    }
    return w.buffered();
}

fn testOne(_: void, smith: *Smith) !void {
    const a = std.testing.allocator;
    var blob_buf: [2048]u8 = undefined;
    const blob = fuzz.blob(smith, &blob_buf, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .value(u8, '{', 6), .value(u8, '}', 6),
        .value(u8, '"', 4), .value(u8, ',', 3), .value(u8, '=', 2),
        .value(u8, '#', 2),
    });
    var r = Reader{ .in = blob };

    const i18n = try I18n.init(a, r.pick([]const u8, &tags));
    defer i18n.deinit();
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);

    var ops: usize = 0;
    var arb_buf: [4096]u8 = undefined;
    while (r.in.len > 0 and ops < 64) : (ops += 1) {
        switch (r.byte() % 12) {
            // --- catalog loading ---
            0, 1 => {
                const tag = r.pick([]const u8, &tags);
                const payload = if (r.flag()) r.span(600) else genArb(&r, &arb_buf);
                i18n.addArb(tag, payload, if (r.flag()) .rtl else .ltr) catch {};
            },
            2 => {
                const loc = Locale.init(a, r.pick([]const u8, &tags)) catch continue;
                defer loc.deinit();
                loc.parseArb(if (r.flag()) r.span(600) else genArb(&r, &arb_buf)) catch {};
            },
            // --- locale switching / resolution ---
            3 => {
                var tag_buf: [16]u8 = undefined;
                const n = @min(r.byte() % tag_buf.len, r.in.len);
                @memcpy(tag_buf[0..n], r.take(n));
                i18n.setLocale(if (r.flag()) r.pick([]const u8, &tags) else tag_buf[0..n]) catch {};
            },
            // --- lookups ---
            4 => _ = i18n.tr(r.pick([]const u8, &keys)),
            5 => {
                const key = r.pick([]const u8, &keys);
                if (i18n.trArgs(a, key, .{ .name = "x", .count = r.int(i16), .n = r.int(i8) })) |s|
                    a.free(s)
                else |_| {}
            },
            6 => {
                const key = r.pick([]const u8, &keys);
                const count = r.int(i64) >> @intCast(r.byte() % 62);
                if (i18n.trPlural(a, key, count, .{ .name = "x" })) |s|
                    a.free(s)
                else |_| {}
            },
            // --- the plural scanner/selector directly on raw bytes ---
            7 => {
                const msg = if (r.flag()) r.span(160) else r.pick([]const u8, &msgs);
                if (i18n_mod.parsePlural(msg)) |pm| {
                    _ = i18n_mod.selectPlural(pm, r.pick([]const u8, &tags), r.int(i64));
                    _ = i18n_mod.selectPlural(pm, r.pick([]const u8, &tags), @as(i64, r.byte()) - 5);
                }
            },
            // --- formatting (locale CLDR data + untrusted numbers/dates) ---
            8 => {
                const loc = Locale.init(a, r.pick([]const u8, &tags)) catch continue;
                defer loc.deinit();
                i18n_mod.applyFormatData(loc);
                const v = @as(f64, @bitCast(r.int(u64)));
                const d = r.byte();
                if (loc.formatNumber(a, v, .{
                    .decimals = if (d < 12) d else null,
                    .percent = r.flag(),
                    .grouping = r.flag(),
                })) |s| a.free(s) else |_| {}
            },
            9 => {
                const loc = Locale.init(a, r.pick([]const u8, &tags)) catch continue;
                defer loc.deinit();
                i18n_mod.applyFormatData(loc);
                const kinds = [_]i18n_mod.DateKind{ .short, .medium, .long };
                if (loc.formatDate(a, .{
                    .year = r.int(i16),
                    .month = r.byte() % 16,
                    .day = r.byte() % 40,
                }, r.pick(i18n_mod.DateKind, &kinds))) |s| a.free(s) else |_| {}
            },
            // --- misc public surface ---
            10 => {
                const count = r.int(i64) >> @intCast(r.byte() % 62);
                _ = i18n_mod.pluralCategory(r.pick([]const u8, &tags), count);
            },
            else => {
                const msg = if (r.flag()) r.span(96) else r.pick([]const u8, &msgs);
                if (i18n_mod.interpolate(a, msg, Args{ .name = "v", .count = r.int(i16) })) |s|
                    a.free(s)
                else |_| {}
            },
        }
    }
    _ = i18n_mod.direction();
    _ = i18n_mod.amPm();
}

test "fuzz: ARB parse + CLDR plurals + locale formatting" {
    try std.testing.fuzz({}, testOne, .{
        .corpus = &.{
            // load en+ar generated docs, switch locale, tr + trPlural
            "\x00\x00\x01\x03\x00" ++ "\x02\x00\x01" ++ "\x04\x00\x04\x01" ++ "\x06\x01\xff\xff\xff\x00" ++ "\x07\x01",
            // raw ARB doc then a plural message through parsePlural
            "\x00\x00\x00{\"items\":\"{count, plural, one{# i} other{# i}}\"}" ++ "\x03\x00\x06\x01\x02\x00\x00",
            // a degenerate doc + number/date formatting
            "\x01\x01\x00" ++ "\x08\x02\x00\x00\x00\x00\x00\x00\xf0\x7f\x03" ++ "\x09\x02\xff\x07\xff\x1f\x02",
        },
    });
}
