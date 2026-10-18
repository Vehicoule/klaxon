// Fuzz harness: input — bytes → PointerEvent/KeyEvent/ScrollEvent streams
// dispatched through `InputRouter` onto a randomly built widget tree.
// The interesting machinery under test is NOT the widgets themselves but
// ui/node.zig's deferred destruction: widgets are deinited mid-dispatch
// (from a button's on_pressed callback — the traversal is active, so the
// node turns zombie and the outermost traversalEnd sweeps it), subtrees are
// detached while a pointer is captured inside them (captureOnDetach), and
// the router's hovered/focused/captured refs all have to track the churn.
//
// Between dispatches the harness collects the live tree by walking
// parent/child links (a node killed earlier is unreachable — no stale
// pointers) so kill targets are always live at trigger time.
const std = @import("std");
const klaxon = @import("klaxon");
const ui = klaxon.ui;
const fuzz = @import("fuzz_common.zig");
const input = ui.input;

const Node = ui.node.Node;
const Smith = std.testing.Smith;
const Reader = fuzz.Reader;
const Allocator = std.mem.Allocator;

const widgets = klaxon.widgets;
const button_w = widgets.button;
const checkbox_w = widgets.checkbox;
const container_w = widgets.container;
const divider_w = widgets.divider;
const icon_w = widgets.icon;
const layout_w = widgets.layout;
const scroll_view_w = widgets.scroll_view;
const slider_w = widgets.slider;
const text_w = widgets.text;
const text_field_w = widgets.text_field;

const icon_names = [_]icon_w.IconName{
    .play, .pause, .stop, .circle, .square, .arrow_right, .arrow_left,
    .arrow_up, .arrow_down, .chevron_right,
};

const phases = [_]input.PointerPhase{
    .down, .move, .up, .enter, .leave, .outside_down, .hover_move,
};

const keys = [_]input.Key{
    .backspace, .delete,  .left,  .right, .up,        .down,
    .home,      .end,     .enter, .escape, .space,    .tab,
    .page_up,   .page_down, .back, .unknown,
};

// --- harness state --------------------------------------------------------

const Ctx = struct {
    a: Allocator,
    /// Set right before a click dispatch; the button callback deinits it
    /// mid-traversal (the zombie path).
    kill_victim: ?*Node = null,
    /// Caller-owned signals bound into widgets; freed at ctx.deinit AFTER
    /// the tree is down (unbindAll on node teardown drops the .node subs).
    bools: std.array_list.Managed(*ui.state.Signal(bool)),
    floats: std.array_list.Managed(*ui.state.Signal(f32)),
    texts: std.array_list.Managed(*ui.state.TextSignal),
    /// Killer buttons we've built — pruned by liveness each click op.
    buttons: std.array_list.Managed(*Node),
    scratch: std.array_list.Managed(*Node),

    fn init(a: Allocator) Ctx {
        return .{
            .a = a,
            .bools = std.array_list.Managed(*ui.state.Signal(bool)).init(a),
            .floats = std.array_list.Managed(*ui.state.Signal(f32)).init(a),
            .texts = std.array_list.Managed(*ui.state.TextSignal).init(a),
            .buttons = std.array_list.Managed(*Node).init(a),
            .scratch = std.array_list.Managed(*Node).init(a),
        };
    }

    fn deinit(ctx: *Ctx) void {
        for (ctx.bools.items) |s| s.deinit();
        for (ctx.floats.items) |s| s.deinit();
        for (ctx.texts.items) |s| s.deinit();
        ctx.bools.deinit();
        ctx.floats.deinit();
        ctx.texts.deinit();
        ctx.buttons.deinit();
        ctx.scratch.deinit();
    }

    fn boolSig(ctx: *Ctx, v: bool) ?*ui.state.Signal(bool) {
        const s = ui.state.Signal(bool).init(ctx.a, v) catch return null;
        ctx.bools.append(s) catch {
            s.deinit();
            return null;
        };
        return s;
    }

    fn floatSig(ctx: *Ctx, v: f32) ?*ui.state.Signal(f32) {
        const s = ui.state.Signal(f32).init(ctx.a, v) catch return null;
        ctx.floats.append(s) catch {
            s.deinit();
            return null;
        };
        return s;
    }
};

/// The button press callback: destroy the pre-chosen victim mid-dispatch.
fn killerCb(userdata: ?*anyopaque) void {
    const ctx: *Ctx = @ptrCast(@alignCast(userdata.?));
    const v = ctx.kill_victim orelse return;
    ctx.kill_victim = null;
    v.deinit(); // traversal is active → zombie queue → swept at traversalEnd
}

fn collectLive(node: *Node, out: *std.array_list.Managed(*Node)) void {
    if (node.zombie) return;
    out.append(node) catch return;
    for (node.children.items) |c| collectLive(c, out);
}

/// Refresh ctx.scratch with every node reachable from `root` and prune
/// ctx.buttons to the live subset. Reachability is the ONLY safe liveness
/// test — a killed node's memory is freed at the sweep, so checking
/// .zombie/.parent on a stale pointer would itself be a UAF.
fn refreshLive(root: *Node, ctx: *Ctx) void {
    ctx.scratch.clearRetainingCapacity();
    collectLive(root, &ctx.scratch);
    var i: usize = 0;
    while (i < ctx.buttons.items.len) {
        if (std.mem.indexOfScalar(*Node, ctx.scratch.items, ctx.buttons.items[i]) == null) {
            _ = ctx.buttons.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

/// A live, non-root node (kill/detach target) or null.
fn pickVictim(root: *Node, ctx: *Ctx, r: *Reader) ?*Node {
    if (ctx.scratch.items.len <= 1) return null;
    const n = ctx.scratch.items[1 + r.byte() % (ctx.scratch.items.len - 1)];
    return if (n == root) null else n;
}

/// Layout-space bounds summed up the parent chain — an approximate global
/// position (scroll offsets aside) good enough to aim a click at.
fn aimAt(n: *Node) struct { x: f32, y: f32 } {
    var x = n.bounds.x + n.bounds.w / 2;
    var y = n.bounds.y + n.bounds.h / 2;
    var p = n.parent;
    while (p) |q| : (p = q.parent) {
        x += q.bounds.x;
        y += q.bounds.y;
    }
    return .{ .x = x, .y = y };
}

// --- random tree construction ---------------------------------------------

fn genTree(ctx: *Ctx, r: *Reader) ?*Node {
    // The root is always a container (kinds 8..12) so event dispatch and
    // detach/re-attach always have a real subtree to work on.
    return genWidget(ctx, r, 0, true);
}

fn genWidget(ctx: *Ctx, r: *Reader, depth: usize, want_container: bool) ?*Node {
    const a = ctx.a;
    const kind: u8 = if (want_container)
        8 + r.byte() % 5
    else if (depth < 2)
        r.byte() % 13
    else
        r.byte() % 8;
    return switch (kind) {
        0 => text_w.text(a, r.pick([]const u8, &fuzz.text_dict), .{}) catch null,
        1 => icon_w.icon(a, r.pick(icon_w.IconName, &icon_names), .{}) catch null,
        2 => divider_w.divider(a, .{}) catch null,
        3 => blk: {
            const b = button_w.button(a, .{ .fn_ptr = killerCb, .userdata = ctx }, .{
                .label = "kill",
            }) catch break :blk null;
            ctx.buttons.append(b) catch {};
            break :blk b;
        },
        4 => if (ctx.boolSig(r.flag())) |s|
            checkbox_w.checkbox(a, s, null, .{}) catch null
        else
            null,
        5 => if (ctx.floatSig(@as(f32, @floatFromInt(r.byte())) / 255.0)) |s|
            slider_w.slider(a, s, null, .{ .steps = r.byte() % 8 }) catch null
        else
            null,
        6 => blk: {
            var sig: ?*ui.state.TextSignal = null;
            if (r.flag()) {
                if (ui.state.TextSignal.init(a, r.pick([]const u8, &fuzz.text_dict)) catch null) |s| {
                    ctx.texts.append(s) catch {
                        s.deinit();
                        break :blk null;
                    };
                    sig = s;
                }
            }
            break :blk text_field_w.textField(a, sig, null, null, .{ .initial = r.pick([]const u8, &fuzz.text_dict) }) catch null;
        },
        7 => container_w.container(a, .{}) catch null,
        // containers (only reachable when depth allows):
        8 => blk: {
            const p = layout_w.padding(a, ui.layout.EdgeInsets.all(@floatFromInt(r.byte() % 16))) catch break :blk null;
            if (genWidget(ctx, r, depth + 1, false)) |c| p.add(c);
            break :blk p;
        },
        9 => blk: {
            const c0 = layout_w.center(a) catch break :blk null;
            if (genWidget(ctx, r, depth + 1, false)) |c| c0.add(c);
            break :blk c0;
        },
        10, 11 => blk: {
            const flex = if (kind == 10)
                layout_w.column(a, .{ .gap = @floatFromInt(r.byte() % 12) }) catch break :blk null
            else
                layout_w.stack(a, .{}) catch break :blk null;
            const nch = 1 + r.byte() % 3;
            for (0..nch) |_| {
                if (genWidget(ctx, r, depth + 1, false)) |c| flex.add(c);
            }
            break :blk flex;
        },
        else => blk: {
            const sv = scroll_view_w.scrollView(a, .{ .wheel_speed = 20 + @as(f32, @floatFromInt(r.byte())) }) catch break :blk null;
            const col = layout_w.column(a, .{}) catch break :blk sv;
            sv.add(col);
            const nch = r.byte() % 5;
            for (0..nch) |_| {
                if (genWidget(ctx, r, depth + 1, false)) |c| col.add(c);
            }
            break :blk sv;
        },
    };
}

// --- event emission --------------------------------------------------------

fn pointerEv(r: *Reader) input.PointerEvent {
    const x = @as(f32, @floatFromInt(r.byte())) * 3 - 20; // -20..745 (window 480)
    const y = @as(f32, @floatFromInt(r.byte())) * 4 - 20; // -20..1000 (window 800)
    return .{
        .phase = r.pick(input.PointerPhase, &phases),
        .x = x,
        .y = y,
        .button = r.byte() % 4,
        .pointer = r.byte() % (input.MAX_POINTERS + 2),
        .time_ms = @as(u64, r.byte()) * 41,
    };
}

fn keyEv(r: *Reader) input.KeyEvent {
    return switch (r.byte() % 5) {
        0, 1 => .{
            .kind = .key_down,
            .key = r.pick(input.Key, &keys),
            .chr = if (r.byte() % 4 == 0) 0 else 'a' + r.byte() % 26,
            .shift = r.flag(),
            .command = r.byte() % 5 == 0,
        },
        2 => .{ .kind = .key_down, .key = .tab, .shift = r.flag() }, // focus walk
        3 => .{ .kind = .text_input, .text = r.pick([]const u8, &fuzz.text_dict) },
        else => .{
            .kind = .text_editing,
            .text = r.span(24),
            .comp_start = r.rel(),
            .comp_len = r.rel(),
        },
    };
}

// --- the fuzz body ----------------------------------------------------------

fn testOne(_: void, smith: *Smith) !void {
    const a = std.testing.allocator;

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

    var blob_buf: [4096]u8 = undefined;
    const blob = fuzz.blob(smith, &blob_buf, &.{
        .rangeAtMost(u8, 0x00, 0xff, 2),
        .rangeAtMost(u8, 0x20, 0x7e, 2),
        .rangeAtMost(u8, 0, 23, 3), // plenty of low op ids
    });
    var r = Reader{ .in = blob };

    var ctx = Ctx.init(a);
    defer ctx.deinit(); // signals outlive the tree (defer order)

    var root = genTree(&ctx, &r) orelse return;
    defer root.deinit();
    var ww: f32 = 480;
    var wh: f32 = 800;
    root.layout(.{ .x = 0, .y = 0, .w = ww, .h = wh });
    if (r.flag()) router.focus(root);

    var now_ms: u64 = 0;
    var ops: usize = 0;
    while (r.in.len > 0 and ops < 160) : (ops += 1) {
        // The live-node list + pruned button list for this op — built by
        // walking the tree so no stale pointer is ever dereferenced.
        refreshLive(root, &ctx);
        // A victim armed last op that never got clicked may be dead by now
        // — disarm rather than let killerCb deinit freed memory.
        ctx.kill_victim = null;
        switch (r.byte() % 24) {
            0...9 => router.dispatchPointer(root, pointerEv(&r)),
            10...13 => _ = router.dispatchKey(keyEv(&r)),
            14 => router.dispatchScroll(root, .{
                .x = @floatFromInt(r.byte()),
                .y = @floatFromInt(r.byte()),
                .delta_x = @floatFromInt(r.rel()),
                .delta_y = @floatFromInt(r.rel()),
            }),
            15 => {
                now_ms +%= @as(u64, r.byte()) * 53 +% 1;
                tl.tick(now_ms);
            },
            16 => {
                ww = 120 + @as(f32, @floatFromInt(r.byte())) * 4;
                wh = 120 + @as(f32, @floatFromInt(r.byte())) * 4;
                root.layout(.{ .x = 0, .y = 0, .w = ww, .h = wh });
            },
            // click a killer button with a live victim armed — the press
            // fires mid-bubble and the victim zombies inside the traversal.
            17 => {
                if (ctx.buttons.items.len > 0) {
                    ctx.kill_victim = pickVictim(root, &ctx, &r);
                    const b = ctx.buttons.items[r.byte() % ctx.buttons.items.len];
                    const p = aimAt(b);
                    router.dispatchPointer(root, .{ .phase = .down, .x = p.x, .y = p.y, .time_ms = now_ms });
                    router.dispatchPointer(root, .{ .phase = .up, .x = p.x, .y = p.y, .time_ms = now_ms +% 60 });
                }
            },
            // detach a subtree (capture transfer via captureOnDetach),
            // then kill it or graft it back elsewhere.
            18, 19 => {
                if (pickVictim(root, &ctx, &r)) |v| {
                    if (v.parent) |p| {
                        _ = p.remove(v);
                        if (r.flag()) {
                            v.deinit();
                        } else {
                            // Rebuild the live set — the detached subtree
                            // is unreachable, so the new parent can never
                            // be `v` or one of its own descendants (add()
                            // asserts on that cycle in Debug).
                            refreshLive(root, &ctx);
                            if (pickVictim(root, &ctx, &r)) |new_p| {
                                new_p.add(v); // reparent: add() re-attaches
                            } else {
                                v.deinit();
                            }
                        }
                    }
                }
            },
            // straight mid-stream destroy between dispatches.
            20 => if (pickVictim(root, &ctx, &r)) |v| v.deinit(),
            // focus/hover churn + signal pokes.
            21 => {
                if (pickVictim(root, &ctx, &r)) |v| router.focus(v);
                if (r.flag()) {
                    for (ctx.bools.items) |s| s.set(r.flag());
                    for (ctx.floats.items) |s| s.set(@as(f32, @floatFromInt(r.byte())) / 255.0);
                }
            },
            // rebuild the world entirely — the new tree's killer buttons
            // land on ctx.buttons as genWidget creates them; the dead old
            // entries get pruned by liveness on the next 17-op.
            22 => {
                const nr = genTree(&ctx, &r) orelse continue;
                root.deinit();
                root = nr;
                root.layout(.{ .x = 0, .y = 0, .w = ww, .h = wh });
            },
            else => {
                // multi-touch sequence on the same pointer slot.
                const pid = r.byte() % 3;
                const x = @as(f32, @floatFromInt(r.byte())) * 3;
                const y = @as(f32, @floatFromInt(r.byte())) * 4;
                router.dispatchPointer(root, .{ .phase = .down, .x = x, .y = y, .pointer = pid });
                router.dispatchPointer(root, .{ .phase = .move, .x = x + 40, .y = y + 40, .pointer = pid });
                router.dispatchPointer(root, .{ .phase = .up, .x = x + 40, .y = y + 40, .pointer = pid });
            },
        }
    }
    ctx.kill_victim = null;
}

test "fuzz: pointer/key stream over a mutating widget tree" {
    try std.testing.fuzz({}, testOne, .{
        .corpus = &.{
            // a few pointer/key events then a rebuild
            "\x00\x20\x40\x50\x0a\x01" ++ "\x16\x40\x40" ++ "\x00\x60\x80\x01",
            // click-kill sequence + subtree detach/destroy + rebuild
            "\x11\x00\x00" ++ "\x12\x01\x00\x01" ++ "\x14\x05" ++ "\x16\x30\x30",
            // scrolls, keys, focus churn
            "\x0e\x40\x40\x20\x10" ++ "\x0a\x02" ++ "\x0d\x01\x02" ++ "\x15\x01\x01" ++ "\x17\x10\x20\x30\x40",
        },
    });
}
