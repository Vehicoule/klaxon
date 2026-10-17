// Fuzz harness: text_edit — the shared editing core behind the M3E
// TextField (widgets/text_edit.zig): the null-terminated buffer, IME
// composition, grapheme caret/selection model, clipboard chords, the
// incremental seg rope and the memoized hit layout.
//
// The input decodes to an op stream — typed inserts (raw spans + a
// tricky-text dictionary), IME preedit, key/nav/chord events, pointer
// taps/drags, scrolls, timeline ticks, relayouts, programmatic sets and
// field recreation — driven through a REAL TextField node in a headless
// tree (InputRouter + Timeline installed, clipboard stubbed), so the events
// take the same path a host dispatch takes. std.testing.allocator is the
// fuzz runner's leak-checking SafeAllocator: the field deinit must free
// everything or the run fails.
const std = @import("std");
const klaxon = @import("klaxon");
const ui = klaxon.ui;
const fuzz = @import("fuzz_common.zig");
const input = ui.input;
const text_field_w = klaxon.widgets.text_field;

const Node = ui.node.Node;
const Smith = std.testing.Smith;
const Reader = fuzz.Reader;

const keys = [_]input.Key{
    .backspace, .delete,   .left,     .right, .up,       .down,
    .home,      .end,      .enter,    .escape, .space,   .tab,
    .page_up,   .page_down, .back,    .unknown,
};
const chord_chrs = [_]u8{ 'a', 'c', 'x', 'v', 'z', 'y', 'b', 'w' };

fn dkey(router: *input.InputRouter, r: *Reader, shift: bool, command: bool) void {
    _ = router.dispatchKey(.{
        .kind = .key_down,
        .key = r.pick(input.Key, &keys),
        .chr = r.pick(u8, &chord_chrs),
        .shift = shift,
        .command = command,
    });
}

fn pointer(router: *input.InputRouter, field: *Node, r: *Reader, phase: input.PointerPhase) void {
    const x = @as(f32, @floatFromInt(r.byte())) * 4 - 60;
    const y = @as(f32, @floatFromInt(r.byte())) * 2 - 40;
    router.dispatchPointer(field, .{
        .phase = phase,
        .x = x,
        .y = y,
        .button = 1 + r.byte() % 3,
        .pointer = r.byte() % 3,
        .time_ms = @as(u64, r.byte()) * 37,
    });
}

fn testOne(_: void, smith: *Smith) !void {
    const a = std.testing.allocator;

    // The host's process-globals, installed exactly like a real window.
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var tl = ui.anim.Timeline.init(a);
    defer tl.deinit();
    ui.anim.setCurrent(&tl);
    defer ui.anim.setCurrent(null);
    fuzz.Clip.install();
    defer ui.clipboard.install(.{});
    defer fuzz.Clip.len = 0;

    var blob_buf: [2048]u8 = undefined;
    const blob = fuzz.blob(smith, &blob_buf, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 4), // printable
        .rangeAtMost(u8, 0x00, 0xff, 1), // anything
        .rangeAtMost(u8, 0x80, 0xbf, 1), // UTF-8 continuations
        .rangeAtMost(u8, 0xc0, 0xf4, 1), // UTF-8 leads
        .value(u8, '\n', 2),
    });
    var r = Reader{ .in = blob };

    const multiline = r.flag();
    const sig: ?*ui.state.TextSignal = if (r.byte() % 3 == 0)
        try ui.state.TextSignal.init(a, "")
    else
        null;
    defer if (sig) |s| s.deinit();

    var field = try text_field_w.textField(a, sig, null, null, .{
        .multiline = multiline,
        .label = "Fuzz",
        .placeholder = "type",
        .supporting = if (r.flag()) "hint" else "",
        .initial = r.pick([]const u8, &fuzz.text_dict),
    });
    defer field.deinit();
    field.layout(.{ .x = 0, .y = 0, .w = 300, .h = if (multiline) 200 else 64 });
    if (r.flag()) router.focus(field) else pointer(&router, field, &r, .down);

    var now_ms: u64 = 0;
    var ops: usize = 0;
    while (r.in.len > 0 and ops < 128) : (ops += 1) {
        switch (r.byte() % 20) {
            // --- text commits (the paste-like bulk path included) ---
            0...3 => _ = router.dispatchKey(.{ .kind = .text_input, .text = r.span(64) }),
            4 => _ = router.dispatchKey(.{ .kind = .text_input, .text = r.pick([]const u8, &fuzz.text_dict) }),
            // --- keys: navigation, deletion, chords ---
            5 => dkey(&router, &r, false, false),
            6 => dkey(&router, &r, true, false),
            7, 8 => dkey(&router, &r, r.flag(), true),
            // --- IME preedit: replaces the composition wholesale ---
            9 => _ = router.dispatchKey(.{
                .kind = .text_editing,
                .text = r.span(32),
                .comp_start = r.rel(),
                .comp_len = r.rel(),
            }),
            // --- pointer gestures (tap, double-tap word select, drags) ---
            10 => pointer(&router, field, &r, .down),
            11 => pointer(&router, field, &r, .move),
            12 => pointer(&router, field, &r, .up),
            13 => router.dispatchScroll(field, .{
                .x = @floatFromInt(r.byte()),
                .y = @floatFromInt(r.byte()),
                .delta_y = @floatFromInt(r.rel()),
            }),
            // --- time + geometry ---
            14 => {
                now_ms +%= @as(u64, r.byte()) * 37 +% 1;
                tl.tick(now_ms);
            },
            15 => field.layout(.{
                .x = 0,
                .y = 0,
                .w = 40 + @as(f32, @floatFromInt(r.byte())) * 3,
                .h = if (multiline) 40 + @as(f32, @floatFromInt(r.byte())) else 64,
            }),
            // --- programmatic / two-way signal writes ---
            16 => text_field_w.setText(field, r.pick([]const u8, &fuzz.text_dict)),
            17 => if (sig) |s| s.set(r.span(48)) catch {},
            18 => {
                const clip = r.span(48);
                fuzz.Clip.setImpl(clip);
            },
            else => {
                // focus churn + lifecycle: blur, refocus, or rebuild the
                // field (fresh Edit state over the same signal).
                switch (r.byte() % 4) {
                    0 => input.requestFocus(null),
                    1 => input.requestFocus(field),
                    2 => {
                        const nf = text_field_w.textField(a, sig, null, null, .{
                            .multiline = multiline,
                            .initial = r.pick([]const u8, &fuzz.text_dict),
                        }) catch continue;
                        field.deinit();
                        field = nf;
                        field.layout(.{ .x = 0, .y = 0, .w = 300, .h = if (multiline) 200 else 64 });
                    },
                    else => _ = router.dispatchKey(.{ .kind = .key_down, .key = .escape }),
                }
            },
        }
    }
}

test "fuzz: text_edit op stream through a real TextField" {
    try std.testing.fuzz({}, testOne, .{
        .corpus = &.{
            // type "hello", backspace, chord select-all, delete
            "\x00\x00\x00\x00" ++ "\x00\x05hello" ++ "\x05\x00" ++ "\x07\x00" ++ "\x05\x01",
            // multiline + clipboard "a\nb\nc" + Cmd-V, then two enters
            "\x01\x01\x04\x01" ++ "\x12\x05a\nb\nc" ++ "\x07\x03" ++ "\x05\x08\x05\x08",
            // IME preedit then commit + a right-to-left insert + taps
            "\x00\x00\x00\x00" ++ "\x09\x03abc" ++ "\x00\x02hi" ++ "\x04\x07" ++ "\x0a\x2c\x18\x01\x00\x0c\x2c\x18",
            // drag across text after dict insert, scroll, tick, relayout
            "\x01\x00\x03\x01" ++ "\x04\x04" ++ "\x0a\x10\x20" ++ "\x0b\x60\x20" ++ "\x0c\x60\x20" ++ "\x0d\x10\x10\x03" ++ "\x0e\xff" ++ "\x0f\x50",
        },
    });
}
