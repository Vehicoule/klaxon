// Conformance engine (Phase 4c.7) — interprets conformance/tests/*.json vectors
// against the real widget tree. See conformance/SPEC.md for the behavioral
// contract, conformance/schema.json for the vector format, and
// conformance/ADAPTERS.md for the port contract other frameworks implement.
//
// A vector is one JSON object:
//   {"id":"LAYOUT-001.1", "rule":"LAYOUT-001", "domain":"layout",
//    "setup":{"viewport":[w,h], "tree":{...}, "locales":{...}, "signals":{...},
//             "effects":[...], "memo":{...}, "navigator":{...}},
//    "actions":[{"op":"pointer", ...}, ...],
//    "expect":{...}, "tolerance":0.01}
//
// The harness builds the DSL tree, installs deterministic globals (input
// router, timeline, focus manager, a11y log bridge, i18n), replays the
// actions in order, then checks every key in `expect`. A test passes iff no
// mismatch was recorded; failures are human-readable strings in the report.
const std = @import("std");
const ui = @import("ui.zig");
const kx = @import("kx.zig");
const golden = @import("golden.zig");
const widgets = @import("widgets.zig");

const Allocator = std.mem.Allocator;
const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Size = ui.node.Size;
const Constraints = ui.layout.Constraints;
const Color = ui.paint.Color;
const input_mod = ui.input;
const anim_mod = ui.anim;
const sem = ui.semantics;
const state_mod = ui.state;
const i18n_mod = ui.i18n;
const nav_mod = ui.navigator;
const gest_mod = ui.gestures;
const value_mod = ui.value;

const Value = value_mod.Value;
const Callback = state_mod.Callback;
const wl = widgets.layout;
const winput = widgets.input;
const wgest = widgets.gestures;
const wscroll = widgets.scroll_view;
const wlist = widgets.list_view;
const wi18n = widgets.i18n;

pub const DEFAULT_TOLERANCE: f32 = 0.01;
const empty_obj: Value = .{ .object = &.{} };

// --- JSON value helpers --------------------------------------------------------

fn getProp(v: Value, name: []const u8) ?Value {
    if (v != .object) return null;
    return v.get(name);
}

fn num(v: ?Value, default: f32) f32 {
    const x = v orelse return default;
    return switch (x) {
        .int => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => default,
    };
}

fn intOf(v: ?Value, default: i64) i64 {
    const x = v orelse return default;
    return switch (x) {
        .int => |i| i,
        .float => |f| @intFromFloat(f),
        else => default,
    };
}

fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn strOr(v: ?Value, default: []const u8) []const u8 {
    return str(v) orelse default;
}

fn boolean(v: ?Value, default: bool) bool {
    const x = v orelse return default;
    return if (x == .bool) x.bool else default;
}

fn parseColor(v: ?Value) ?Color {
    const x = v orelse return null;
    switch (x) {
        .int => |i| return @intCast(@as(u64, @bitCast(i)) & 0xFFFFFFFF),
        .string => |s| {
            const hex = if (std.mem.startsWith(u8, s, "#")) s[1..] else s;
            if (hex.len != 8) return null;
            return std.fmt.parseInt(u32, hex, 16) catch null;
        },
        else => return null,
    }
}

fn parseAlign(v: ?Value) ?ui.layout.Alignment {
    const x = v orelse return null;
    if (x != .array or x.array.len < 2) return null;
    return .{ .x = num(x.array[0], 0), .y = num(x.array[1], 0) };
}

fn parseRect(v: ?Value) ?Rect {
    const x = v orelse return null;
    if (x != .array or x.array.len < 4) return null;
    return .{
        .x = num(x.array[0], 0),
        .y = num(x.array[1], 0),
        .w = num(x.array[2], 0),
        .h = num(x.array[3], 0),
    };
}

fn parseInsets(v: ?Value) ?ui.layout.EdgeInsets {
    const x = v orelse return null;
    if (x != .object) {
        const a = num(v, -1); // scalar shorthand: "padding": 8 → all sides
        if (a < 0) return null;
        return ui.layout.EdgeInsets.all(a);
    }
    return .{
        .left = num(x.get("left"), 0),
        .top = num(x.get("top"), 0),
        .right = num(x.get("right"), 0),
        .bottom = num(x.get("bottom"), 0),
    };
}

fn parseDirInsets(v: ?Value) ?ui.layout.EdgeInsetsDirectional {
    const x = v orelse return null;
    if (x != .object) return null;
    return .{
        .start = num(x.get("start"), 0),
        .top = num(x.get("top"), 0),
        .end = num(x.get("end"), 0),
        .bottom = num(x.get("bottom"), 0),
    };
}

fn parseMainAlign(s: []const u8) ui.layout.MainAlign {
    if (std.mem.eql(u8, s, "center")) return .center;
    if (std.mem.eql(u8, s, "end")) return .end;
    if (std.mem.eql(u8, s, "space_between")) return .space_between;
    if (std.mem.eql(u8, s, "space_around")) return .space_around;
    if (std.mem.eql(u8, s, "space_evenly")) return .space_evenly;
    return .start;
}

fn parseCrossAlign(s: []const u8) ui.layout.CrossAlign {
    if (std.mem.eql(u8, s, "start")) return .start;
    if (std.mem.eql(u8, s, "center")) return .center;
    if (std.mem.eql(u8, s, "end")) return .end;
    return .stretch; // widget default
}

fn parseStackFit(s: []const u8) wl.StackFit {
    if (std.mem.eql(u8, s, "expand")) return .expand;
    return .loose;
}

fn parseTextAlign(s: []const u8) ui.layout.TextAlign {
    if (std.mem.eql(u8, s, "center")) return .center;
    if (std.mem.eql(u8, s, "right")) return .right;
    if (std.mem.eql(u8, s, "start")) return .start;
    if (std.mem.eql(u8, s, "end")) return .end;
    return .left;
}

fn parseRole(s: []const u8) ?sem.Role {
    const info = @typeInfo(sem.Role).@"enum";
    inline for (info.field_names, info.field_values) |name, value| {
        if (std.mem.eql(u8, s, name)) return @enumFromInt(value);
    }
    return null;
}

fn parseKey(s: []const u8) input_mod.Key {
    if (std.mem.eql(u8, s, "tab")) return .tab;
    if (std.mem.eql(u8, s, "enter")) return .enter;
    if (std.mem.eql(u8, s, "space")) return .space;
    if (std.mem.eql(u8, s, "escape")) return .escape;
    if (std.mem.eql(u8, s, "backspace")) return .backspace;
    if (std.mem.eql(u8, s, "delete")) return .delete;
    if (std.mem.eql(u8, s, "left")) return .left;
    if (std.mem.eql(u8, s, "right")) return .right;
    if (std.mem.eql(u8, s, "up")) return .up;
    if (std.mem.eql(u8, s, "down")) return .down;
    if (std.mem.eql(u8, s, "back")) return .back;
    // Single chars map to their codepoint (Key is a non-exhaustive enum(u32);
    // e.g. "a" → @enumFromInt('a') like the host's keymap path).
    if (s.len == 1) return @enumFromInt(s[0]);
    return .unknown;
}

fn parseRegion(s: []const u8) sem.LiveRegion {
    if (std.mem.eql(u8, s, "assertive")) return .assertive;
    return .polite;
}

fn parsePhase(s: []const u8) ?input_mod.PointerPhase {
    if (std.mem.eql(u8, s, "down")) return .down;
    if (std.mem.eql(u8, s, "move")) return .move;
    if (std.mem.eql(u8, s, "up")) return .up;
    return null;
}

fn parseTransition(s: []const u8) nav_mod.Transition {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "slide_up")) return .slide_up;
    if (std.mem.eql(u8, s, "fade")) return .fade;
    if (std.mem.eql(u8, s, "scale")) return .scale;
    return .slide;
}

// --- event log callbacks -------------------------------------------------------
// ADR-0009 shape: a fn ptr + userdata. LogCtx points at the destination list.

const LogCtx = struct {
    list: *std.array_list.Managed([]const u8),
    tag: []const u8,
};

fn logCb(userdata: ?*anyopaque) void {
    const c: *LogCtx = @ptrCast(@alignCast(userdata.?));
    c.list.append(c.tag) catch @panic("klaxon: out of memory");
}

fn logPanCb(userdata: ?*anyopaque, dx: f32, dy: f32) void {
    _ = dx;
    _ = dy;
    logCb(userdata);
}

fn logPanEndCb(userdata: ?*anyopaque, vx: f32, vy: f32, dx: f32, dy: f32) void {
    _ = vx;
    _ = vy;
    _ = dx;
    _ = dy;
    logCb(userdata);
}

fn logSwipeCb(userdata: ?*anyopaque, dir: gest_mod.SwipeDirection, vx: f32, vy: f32) void {
    _ = vx;
    _ = vy;
    const c: *LogCtx = @ptrCast(@alignCast(userdata.?));
    const tag = std.fmt.allocPrint(c.list.allocator, "swipe:{s}", .{@tagName(dir)}) catch @panic("klaxon: out of memory");
    c.list.append(tag) catch @panic("klaxon: out of memory");
}

fn logPinchCb(userdata: ?*anyopaque, scale: f32) void {
    _ = scale;
    logCb(userdata);
}

fn logRotateCb(userdata: ?*anyopaque, delta_radians: f32) void {
    _ = delta_radians;
    logCb(userdata);
}

// --- conformance "box" leaf ----------------------------------------------------
// A deterministic leaf: fixed intrinsic size, solid fill, optional press log.
// Keeps layout/paint vectors independent of font metrics.

const BoxState = struct {
    h: *Harness,
    id: []const u8, // owned by the test doc's arena
    w: f32 = 0,
    h_: f32 = 0,
    color: Color = 0xCCCCCCFF,
    on_press: bool = false,
    item_index: usize = std.math.maxInt(usize), // set by list_view factories
};

fn stateOf(comptime T: type, n: *Node) *T {
    return @ptrCast(@alignCast(n.state.?));
}

fn boxMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(BoxState, n);
    return c.constrain(.{ .w = s.w, .h = s.h_ });
}
fn boxLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn boxPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(BoxState, n);
    ui.paint.fillRect(ctx, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h, s.color);
}
fn boxPointer(n: *Node, ev: input_mod.PointerEvent) bool {
    const s = stateOf(BoxState, n);
    if (!s.on_press) return false;
    switch (ev.phase) {
        .down => return true, // claim: captures for the up check
        .up => {
            if (n.bounds.contains(ev.x, ev.y)) {
                const tag = std.fmt.allocPrint(s.h.alloc, "press:{s}", .{s.id}) catch @panic("klaxon: out of memory");
                s.h.events.append(tag) catch @panic("klaxon: out of memory");
            }
            return true;
        },
        else => return true,
    }
}
fn boxDeinit(n: *Node) void {
    const s = stateOf(BoxState, n);
    input_mod.releaseNode(n);
    n.allocator.destroy(s);
}
const box_vtable = ui.node.VTable{ .measure = boxMeasure, .layout = boxLayout, .paint = boxPaint, .on_pointer = boxPointer, .deinit = boxDeinit };

// --- memo (one per test; the compute fn reads the harness-provided sources) ----

const MemoOp = enum { add, sub, mul };
var cur_memo_src: ?struct { a: *state_mod.Signal(i64), b: *state_mod.Signal(i64), op: MemoOp } = null;

fn memoCompute() i64 {
    const src = cur_memo_src orelse return 0;
    return switch (src.op) {
        .add => src.a.get() + src.b.get(),
        .sub => src.a.get() - src.b.get(),
        .mul => src.a.get() * src.b.get(),
    };
}
const MemoT = state_mod.Memo(i64, memoCompute);

// --- effects -------------------------------------------------------------------

const EffectOp = enum { add, mul, first };

const EffectDef = struct {
    h: *Harness,
    name: []const u8,
    reads: []const []const u8, // "sig" tracked; "peek:sig" untracked; "memo" the test's memo
    op: EffectOp,
    effect: ?*state_mod.Effect = null,
};

fn effectCb(userdata: ?*anyopaque) void {
    const d: *EffectDef = @ptrCast(@alignCast(userdata.?));
    var acc: i64 = if (d.op == .mul) 1 else 0;
    var first = true;
    for (d.reads) |r| {
        const v = d.h.readRef(r) orelse 0;
        switch (d.op) {
            .add => acc += v,
            .mul => acc *= v,
            .first => {
                if (first) acc = v;
            },
        }
        first = false;
    }
    const line = std.fmt.allocPrint(d.h.alloc, "{s}={d}", .{ d.name, acc }) catch @panic("klaxon: out of memory");
    d.h.effect_log.append(line) catch @panic("klaxon: out of memory");
}

// --- the harness -----------------------------------------------------------------

const ScrollKind = enum { view, list };

pub const Harness = struct {
    alloc: Allocator, // test-scoped arena — every allocation dies with the test
    router: input_mod.InputRouter = undefined,
    timeline: anim_mod.Timeline = undefined,
    fm: ?*sem.FocusManager = null,
    lb: ?*sem.LogBridge = null,
    i18n: ?*i18n_mod.I18n = null,
    nav: ?*nav_mod.Navigator = null,
    root: ?*Node = null,
    renderer: ?golden.Renderer = null,
    viewport: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 },

    ids: std.StringHashMap(*Node),
    scroll_kind: std.StringHashMap(ScrollKind),
    sig_i64: std.StringHashMap(*state_mod.Signal(i64)),
    sig_bool: std.StringHashMap(*state_mod.Signal(bool)),
    sig_f32: std.StringHashMap(*state_mod.Signal(f32)),
    sig_text: std.StringHashMap(*state_mod.TextSignal),
    memo: ?*MemoT = null,
    memo_name: []const u8 = "",
    effects: std.array_list.Managed(*EffectDef),

    gestures: std.array_list.Managed([]const u8),
    events: std.array_list.Managed([]const u8),
    effect_log: std.array_list.Managed([]const u8),
    last_error: ?[]const u8 = null,

    pub fn init(alloc: Allocator) !*Harness {
        const h = try alloc.create(Harness);
        h.* = .{
            .alloc = alloc,
            .ids = std.StringHashMap(*Node).init(alloc),
            .scroll_kind = std.StringHashMap(ScrollKind).init(alloc),
            .sig_i64 = std.StringHashMap(*state_mod.Signal(i64)).init(alloc),
            .sig_bool = std.StringHashMap(*state_mod.Signal(bool)).init(alloc),
            .sig_f32 = std.StringHashMap(*state_mod.Signal(f32)).init(alloc),
            .sig_text = std.StringHashMap(*state_mod.TextSignal).init(alloc),
            .effects = std.array_list.Managed(*EffectDef).init(alloc),
            .gestures = std.array_list.Managed([]const u8).init(alloc),
            .events = std.array_list.Managed([]const u8).init(alloc),
            .effect_log = std.array_list.Managed([]const u8).init(alloc),
        };
        h.router = input_mod.InputRouter{};
        h.timeline = anim_mod.Timeline.init(alloc);
        h.fm = try sem.FocusManager.init(alloc);
        h.lb = try sem.LogBridge.init(alloc);
        // Deterministic globals: widgets and input dispatch read the
        // process-global router / timeline / focus / bridge.
        input_mod.setCurrent(&h.router);
        anim_mod.setCurrent(&h.timeline);
        sem.setCurrentFocus(h.fm);
        sem.setBridge(h.lb.?.bridge());
        return h;
    }

    /// Tree first (deinit callbacks read the globals), then the globals.
    pub fn deinit(h: *Harness) void {
        if (h.root) |r| r.deinit();
        if (h.nav) |nv| nv.deinit();
        for (h.effects.items) |d| {
            if (d.effect) |e| e.deinit();
        }
        if (h.memo) |m| m.deinit();
        var it = h.sig_i64.valueIterator();
        while (it.next()) |s| s.*.deinit();
        var itb = h.sig_bool.valueIterator();
        while (itb.next()) |s| s.*.deinit();
        var itf = h.sig_f32.valueIterator();
        while (itf.next()) |s| s.*.deinit();
        var itt = h.sig_text.valueIterator();
        while (itt.next()) |s| s.*.deinit();
        if (h.i18n) |i| i.deinit();
        input_mod.setCurrent(null);
        anim_mod.setCurrent(null);
        sem.setCurrentFocus(null);
        sem.setBridge(null);
        i18n_mod.setCurrent(null);
        cur_memo_src = null;
        if (h.renderer) |*r| r.deinit();
        if (h.fm) |f| f.deinit();
        if (h.lb) |l| l.deinit();
        h.timeline.deinit();
    }

    fn newLogCtx(h: *Harness, list: *std.array_list.Managed([]const u8), tag: []const u8) !*LogCtx {
        const c = try h.alloc.create(LogCtx);
        c.* = .{ .list = list, .tag = tag };
        return c;
    }

    fn taggedCallback(h: *Harness, comptime prefix: []const u8, id: []const u8) !Callback {
        const tag = try std.fmt.allocPrint(h.alloc, prefix ++ "{s}", .{id});
        return .{ .fn_ptr = logCb, .userdata = try h.newLogCtx(&h.events, tag) };
    }

    fn sigI64(h: *Harness, name: []const u8, initial: i64) !*state_mod.Signal(i64) {
        if (h.sig_i64.get(name)) |s| return s;
        const s = try state_mod.Signal(i64).init(h.alloc, initial);
        try h.sig_i64.put(try h.alloc.dupe(u8, name), s);
        return s;
    }
    fn sigBool(h: *Harness, name: []const u8, initial: bool) !*state_mod.Signal(bool) {
        if (h.sig_bool.get(name)) |s| return s;
        const s = try state_mod.Signal(bool).init(h.alloc, initial);
        try h.sig_bool.put(try h.alloc.dupe(u8, name), s);
        return s;
    }
    fn sigF32(h: *Harness, name: []const u8, initial: f32) !*state_mod.Signal(f32) {
        if (h.sig_f32.get(name)) |s| return s;
        const s = try state_mod.Signal(f32).init(h.alloc, initial);
        try h.sig_f32.put(try h.alloc.dupe(u8, name), s);
        return s;
    }

    /// "a" → tracked read; "peek:a" → untracked; "memo" → the test's memo.
    fn readRef(h: *Harness, ref: []const u8) ?i64 {
        if (std.mem.eql(u8, ref, "memo")) {
            const m = h.memo orelse return null;
            return m.get();
        }
        if (std.mem.startsWith(u8, ref, "peek:")) {
            const s = h.sig_i64.get(ref[5..]) orelse return null;
            return s.peek();
        }
        const s = h.sig_i64.get(ref) orelse return null;
        return s.get();
    }

    fn findNode(h: *Harness, id: []const u8) ?*Node {
        return h.ids.get(id);
    }

    /// True when `n` is still inside the live tree (list-view items are
    /// destroyed as they leave the virtualization window — a stale id then
    /// resolves to a detached/freed node).
    fn isLive(h: *Harness, n: *Node) bool {
        const root = h.root orelse return false;
        var cur: ?*Node = n;
        while (cur) |c| {
            if (c == root) return true;
            cur = c.parent;
        }
        return false;
    }

    /// Raster frame: creates the renderer lazily, paints, reads pixels back.
    fn renderFrame(h: *Harness) !golden.Frame {
        if (h.renderer == null) {
            h.renderer = try golden.Renderer.init(h.alloc, @intFromFloat(h.viewport.w), @intFromFloat(h.viewport.h));
        }
        const r = &h.renderer.?;
        r.paint(h.root.?, 0x000000FF);
        h.root.?.clearDamage();
        return r.readback(h.alloc);
    }
};

// --- tree builder ----------------------------------------------------------------

/// Attach semantics from props: role/label/hint/value/checked/disabled/
/// focusable/actions (array of strings).
fn attachPropSemantics(node: *Node, props: Value) void {
    if (props != .object) return;
    if (getProp(props, "role") == null and getProp(props, "label") == null and
        getProp(props, "focusable") == null and getProp(props, "checked") == null and
        getProp(props, "disabled") == null and getProp(props, "hint") == null and
        getProp(props, "value") == null and getProp(props, "actions") == null) return;
    // Merge into the widget's own descriptor when it exists — "checked" is
    // also a construction prop (checkbox/toggle/radio bind it to a signal),
    // so a blanket replace would wipe the widget's role/focusable/actions.
    const s = node.semantics orelse blk: {
        sem.attach(node, .{});
        break :blk node.semantics.?;
    };
    if (str(props.get("role"))) |r| s.role = parseRole(r) orelse .none;
    if (str(props.get("label"))) |l| s.label = l;
    if (str(props.get("hint"))) |t| s.hint = t;
    if (str(props.get("value"))) |t| s.value = t;
    if (getProp(props, "checked") != null) s.checked = boolean(props.get("checked"), false);
    if (getProp(props, "disabled") != null) s.disabled = boolean(props.get("disabled"), false);
    if (getProp(props, "focusable") != null) s.focusable = boolean(props.get("focusable"), false);
    if (getProp(props, "actions")) |a| {
        if (a == .array) {
            for (a.array) |av| {
                const name = str(av) orelse continue;
                const info = @typeInfo(sem.Action).@"enum";
                inline for (info.field_names, info.field_values) |fname, fval| {
                    if (std.mem.eql(u8, name, fname)) s.actions.insert(@enumFromInt(fval));
                }
            }
        }
    }
}

/// Node-level props applied to every DSL node after construction:
/// id/flex/visible/exclude_semantics/damage_overflow + prop semantics.
fn applyNodeProps(h: *Harness, node: *Node, tv: Value, id: []const u8) !void {
    const props = propsOf(tv);
    if (props == .object) {
        if (getProp(props, "flex")) |f| node.flex = @intFromFloat(@max(0, num(f, 1)));
        if (getProp(props, "visible")) |v| node.visible = boolean(v, true);
        if (parseRect(getProp(props, "damage_overflow"))) |r| {
            node.damage_overflow = .{ .left = r.x, .top = r.y, .right = r.w, .bottom = r.h };
        }
        if (boolean(props.get("exclude_semantics"), false)) node.exclude_semantics = true;
        attachPropSemantics(node, props);
    }
    if (id.len > 0) {
        if (h.ids.contains(id)) return error.DuplicateId;
        try h.ids.put(id, node);
    }
}

// Explicit error set: buildChildren ↔ buildNode are mutually recursive, so
// inferred error sets create a dependency loop (Zig 0.17).
fn buildChildren(h: *Harness, parent: *Node, tv: Value) anyerror!void {
    if (getProp(tv, "children")) |kids| {
        if (kids == .array) {
            for (kids.array) |kv| {
                const child = try buildNode(h, kv);
                parent.add(child);
            }
        }
    }
}

/// Build one DSL node: {"type":"row","id":"r","props":{...},"children":[...]}.
pub fn buildNode(h: *Harness, tv: Value) !*Node {
    const wtype = str(tv.get("type")) orelse return error.MissingType;
    const id = strOr(tv.get("id"), "");
    const props = propsOf(tv);

    const node: *Node = blk: {
        if (std.mem.eql(u8, wtype, "box")) {
            const n = try Node.create(h.alloc, &box_vtable);
            const s = try h.alloc.create(BoxState);
            s.* = .{
                .h = h,
                .id = id,
                .w = num(props.get("w"), 0),
                .h_ = num(props.get("h"), 0),
                .color = parseColor(props.get("color")) orelse 0xCCCCCCFF,
                .on_press = boolean(props.get("on_press"), false),
            };
            n.state = s;
            break :blk n;
        } else if (std.mem.eql(u8, wtype, "row") or std.mem.eql(u8, wtype, "column")) {
            const opts = wl.FlexOptions{
                .gap = num(props.get("gap"), 0),
                .padding = num(props.get("padding"), 0),
                .main_align = parseMainAlign(strOr(props.get("main_align"), "start")),
                .cross_align = parseCrossAlign(strOr(props.get("cross_align"), "stretch")),
            };
            break :blk if (wtype[0] == 'r') try wl.row(h.alloc, opts) else try wl.column(h.alloc, opts);
        } else if (std.mem.eql(u8, wtype, "stack")) {
            break :blk try wl.stack(h.alloc, .{
                .fit = parseStackFit(strOr(props.get("fit"), "loose")),
                .alignment = parseAlign(props.get("alignment")) orelse .top_left,
            });
        } else if (std.mem.eql(u8, wtype, "grid")) {
            break :blk try wl.grid(h.alloc, .{
                .columns = @intFromFloat(num(props.get("columns"), 2)),
                .gap = num(props.get("gap"), 0),
                .padding = num(props.get("padding"), 0),
            });
        } else if (std.mem.eql(u8, wtype, "padding")) {
            break :blk try wl.padding(h.alloc, parseInsets(props.get("padding")) orelse .{});
        } else if (std.mem.eql(u8, wtype, "padding_directional")) {
            break :blk try wl.paddingDir(h.alloc, parseDirInsets(props) orelse .{});
        } else if (std.mem.eql(u8, wtype, "center")) {
            break :blk try wl.center(h.alloc);
        } else if (std.mem.eql(u8, wtype, "align")) {
            break :blk try wl.alignTo(h.alloc, .{ .alignment = parseAlign(props.get("alignment")) orelse .center });
        } else if (std.mem.eql(u8, wtype, "constrained_box")) {
            break :blk try wl.constrainedBox(h.alloc, .{
                .min_w = num(props.get("min_w"), 0),
                .min_h = num(props.get("min_h"), 0),
                .max_w = num(props.get("max_w"), std.math.inf(f32)),
                .max_h = num(props.get("max_h"), std.math.inf(f32)),
            });
        } else if (std.mem.eql(u8, wtype, "expanded")) {
            break :blk try wl.expanded(h.alloc, @intFromFloat(num(props.get("weight"), 1)));
        } else if (std.mem.eql(u8, wtype, "container")) {
            break :blk try widgets.container.container(h.alloc, .{
                .color = parseColor(props.get("color")),
                .padding = parseInsets(props.get("padding")) orelse .{},
            });
        } else if (std.mem.eql(u8, wtype, "text")) {
            break :blk try widgets.text.text(h.alloc, strOr(props.get("text"), ""), .{
                .size = num(props.get("size"), 16),
                .color = parseColor(props.get("color")) orelse 0x000000FF,
                .bold = boolean(props.get("bold"), false),
                .text_align = parseTextAlign(strOr(props.get("text_align"), "left")),
            });
        } else if (std.mem.eql(u8, wtype, "button")) {
            const cb = try h.taggedCallback("press:", id);
            break :blk try winput.button(h.alloc, cb, .{});
        } else if (std.mem.eql(u8, wtype, "toggle")) {
            const sig = try h.sigBool(strOr(props.get("signal"), id), boolean(props.get("checked"), false));
            const cb = try h.taggedCallback("change:", id);
            break :blk try winput.toggle(h.alloc, sig, cb, .{});
        } else if (std.mem.eql(u8, wtype, "checkbox")) {
            const sig = try h.sigBool(strOr(props.get("signal"), id), boolean(props.get("checked"), false));
            const cb = try h.taggedCallback("change:", id);
            break :blk try winput.checkbox(h.alloc, sig, cb, .{});
        } else if (std.mem.eql(u8, wtype, "slider")) {
            const sig = try h.sigF32(strOr(props.get("signal"), id), num(props.get("value"), 0.5));
            const cb = try h.taggedCallback("change:", id);
            break :blk try winput.slider(h.alloc, sig, cb, .{
                .default_width = num(props.get("width"), 200),
            });
        } else if (std.mem.eql(u8, wtype, "text_field")) {
            const change = try h.taggedCallback("change:", id);
            const submit = try h.taggedCallback("submit:", id);
            break :blk try winput.textField(h.alloc, .{
                .placeholder = strOr(props.get("placeholder"), ""),
                .initial = strOr(props.get("initial"), ""),
            }, change, submit);
        } else if (std.mem.eql(u8, wtype, "gesture_detector")) {
            var cbs = gest_mod.GestureCallbacks{};
            if (getProp(props, "gestures")) |gs| {
                if (gs == .array) {
                    for (gs.array) |gv| {
                        const name = str(gv) orelse continue;
                        if (std.mem.eql(u8, name, "tap")) cbs.on_tap = .{ .fn_ptr = logCb, .userdata = try h.newLogCtx(&h.gestures, "tap") };
                        if (std.mem.eql(u8, name, "double_tap")) cbs.on_double_tap = .{ .fn_ptr = logCb, .userdata = try h.newLogCtx(&h.gestures, "double_tap") };
                        if (std.mem.eql(u8, name, "long_press")) cbs.on_long_press = .{ .fn_ptr = logCb, .userdata = try h.newLogCtx(&h.gestures, "long_press") };
                        if (std.mem.eql(u8, name, "pan_start")) cbs.on_pan_start = .{ .fn_ptr = logPanCb, .userdata = try h.newLogCtx(&h.gestures, "pan_start") };
                        if (std.mem.eql(u8, name, "pan_update")) cbs.on_pan_update = .{ .fn_ptr = logPanCb, .userdata = try h.newLogCtx(&h.gestures, "pan_update") };
                        if (std.mem.eql(u8, name, "pan_end")) cbs.on_pan_end = .{ .fn_ptr = logPanEndCb, .userdata = try h.newLogCtx(&h.gestures, "pan_end") };
                        if (std.mem.eql(u8, name, "swipe")) cbs.on_swipe = .{ .fn_ptr = logSwipeCb, .userdata = try h.newLogCtx(&h.gestures, "") };
                        if (std.mem.eql(u8, name, "pinch")) cbs.on_pinch = .{ .fn_ptr = logPinchCb, .userdata = try h.newLogCtx(&h.gestures, "pinch") };
                        if (std.mem.eql(u8, name, "rotate")) cbs.on_rotate = .{ .fn_ptr = logRotateCb, .userdata = try h.newLogCtx(&h.gestures, "rotate") };
                    }
                }
            }
            break :blk try wgest.gestureDetector(h.alloc, .{ .callbacks = cbs });
        } else if (std.mem.eql(u8, wtype, "scroll_view")) {
            const n = try wscroll.scrollView(h.alloc, .{
                .wheel_speed = num(props.get("wheel_speed"), 48),
            });
            if (id.len > 0) try h.scroll_kind.put(id, .view);
            break :blk n;
        } else if (std.mem.eql(u8, wtype, "list_view")) {
            const n = try buildListView(h, props, id);
            if (id.len > 0) try h.scroll_kind.put(id, .list);
            break :blk n;
        } else if (std.mem.eql(u8, wtype, "l10n_text")) {
            const i18n = h.i18n orelse return error.MissingI18n;
            break :blk try wi18n.l10nText(h.alloc, i18n, strOr(props.get("key"), ""), .{
                .size = num(props.get("size"), 14),
            });
        } else if (std.mem.eql(u8, wtype, "l10n_plural")) {
            const i18n = h.i18n orelse return error.MissingI18n;
            if (str(props.get("count_signal"))) |name| {
                const sig = try h.sigI64(name, intOf(props.get("count"), 0));
                break :blk try wi18n.l10nPluralSig(h.alloc, i18n, strOr(props.get("key"), ""), sig, .{});
            }
            break :blk try wi18n.l10nPlural(h.alloc, i18n, strOr(props.get("key"), ""), intOf(props.get("count"), 0), .{});
        } else {
            return error.UnknownType;
        }
    };

    try buildChildren(h, node, tv);
    try applyNodeProps(h, node, tv, id);
    return node;
}

/// list_view factory userdata — survives for the widget's lifetime (arena).
const ListBuilder = struct {
    h: *Harness,
    list_id: []const u8,
    item_focusable: bool,
    item_press: bool,
};

/// Items are alternating-color boxes registered as "<list>.item<i>" — id
/// expectations locate them; `first_item` reads the first child's index.
fn listItemCb(userdata: ?*anyopaque, index: usize) *Node {
    const b: *ListBuilder = @ptrCast(@alignCast(userdata.?));
    const h = b.h;
    const n = Node.create(h.alloc, &box_vtable) catch @panic("klaxon: out of memory");
    const s = h.alloc.create(BoxState) catch @panic("klaxon: out of memory");
    const name = std.fmt.allocPrint(h.alloc, "{s}.item{d}", .{ b.list_id, index }) catch @panic("klaxon: out of memory");
    const palette = [_]Color{ 0xFF0000FF, 0x00FF00FF, 0x0000FFFF };
    s.* = .{ .h = h, .id = name, .color = palette[index % 3], .on_press = b.item_press, .item_index = index };
    n.state = s;
    if (b.item_focusable) sem.attach(n, .{ .role = .list_item, .focusable = true });
    h.ids.put(name, n) catch @panic("klaxon: out of memory");
    return n;
}

fn buildListView(h: *Harness, props: Value, id: []const u8) !*Node {
    const builder = try h.alloc.create(ListBuilder);
    builder.* = .{
        .h = h,
        .list_id = try h.alloc.dupe(u8, if (id.len > 0) id else "list"),
        .item_focusable = boolean(props.get("item_focusable"), false),
        .item_press = boolean(props.get("item_press"), false),
    };
    return wlist.listView(h.alloc, .{
        .factory = .{ .fn_ptr = listItemCb, .userdata = builder },
        .item_count = @intFromFloat(num(props.get("item_count"), 0)),
        .item_height = num(props.get("item_height"), 48),
        .gap = num(props.get("gap"), 0),
        .margin = @intFromFloat(num(props.get("margin"), 2)),
        .wheel_speed = num(props.get("wheel_speed"), 48),
    });
}

fn propsOf(v: Value) Value {
    return getProp(v, "props") orelse empty_obj;
}

// --- setup -----------------------------------------------------------------------

fn setupSignals(h: *Harness, sigs: Value) !void {
    if (sigs != .object) return;
    for (sigs.object) |f| {
        const name = try h.alloc.dupe(u8, f.name);
        switch (f.value) {
            .bool => |b| _ = try h.sigBool(name, b),
            .int => |i| _ = try h.sigI64(name, i),
            .float => |fl| _ = try h.sigF32(name, @floatCast(fl)),
            .string => |s| {
                const ts = try state_mod.TextSignal.init(h.alloc, s);
                try h.sig_text.put(name, ts);
            },
            .object => {
                if (std.mem.eql(u8, strOr(f.value.get("type"), ""), "text")) {
                    const ts = try state_mod.TextSignal.init(h.alloc, strOr(f.value.get("value"), ""));
                    try h.sig_text.put(name, ts);
                }
            },
            else => {},
        }
    }
}

/// effects: [{"name":"e1","reads":["a","b"],"op":"add|mul|first"}] — the log
/// records "name=value" on every run.
fn setupEffects(h: *Harness, defs: Value) !void {
    if (defs != .array) return;
    for (defs.array) |dv| {
        const d = try h.alloc.create(EffectDef);
        var reads = std.array_list.Managed([]const u8).init(h.alloc);
        if (getProp(dv, "reads")) |rs| {
            if (rs == .array) {
                for (rs.array) |rv| {
                    if (str(rv)) |r| try reads.append(try h.alloc.dupe(u8, r));
                }
            }
        }
        const op_name = strOr(getProp(dv, "op"), "add");
        d.* = .{
            .h = h,
            .name = try h.alloc.dupe(u8, strOr(getProp(dv, "name"), "effect")),
            .reads = try reads.toOwnedSlice(),
            .op = if (std.mem.eql(u8, op_name, "mul")) .mul else if (std.mem.eql(u8, op_name, "first")) .first else .add,
        };
        d.effect = try state_mod.Effect.init(h.alloc, effectCb, d);
        try h.effects.append(d);
        d.effect.?.run(); // first run: resolve + subscribe
    }
}

/// memo: {"name":"m","op":"add|sub|mul","args":["a","b"]} — at most one per test.
fn setupMemo(h: *Harness, def: Value) !void {
    if (def != .object) return;
    const args_v = getProp(def, "args") orelse return;
    if (args_v != .array or args_v.array.len < 2) return;
    const a = h.sig_i64.get(str(args_v.array[0]) orelse "") orelse return;
    const b = h.sig_i64.get(str(args_v.array[1]) orelse "") orelse return;
    const op_name = strOr(getProp(def, "op"), "add");
    cur_memo_src = .{
        .a = a,
        .b = b,
        .op = if (std.mem.eql(u8, op_name, "sub")) .sub else if (std.mem.eql(u8, op_name, "mul")) .mul else .add,
    };
    h.memo = try MemoT.init(h.alloc);
    h.memo_name = try h.alloc.dupe(u8, strOr(getProp(def, "name"), "memo"));
}

/// i18n: {"locale":"en","fallback":"en","locales":{"en":{...arb...}},
///         "dirs":{"ar":"rtl"}} — ARB objects serialize back through
/// value_mod.toJson (the DSL embeds them as real JSON).
fn setupI18n(h: *Harness, v: Value) !void {
    if (v != .object) return;
    const i18n = try i18n_mod.I18n.init(h.alloc, strOr(getProp(v, "fallback"), "en"));
    h.i18n = i18n;
    if (getProp(v, "locales")) |locs| {
        if (locs == .object) {
            for (locs.object) |f| {
                const dir: i18n_mod.Direction = blk: {
                    const d = getProp(v, "dirs") orelse break :blk .ltr;
                    if (d != .object) break :blk .ltr;
                    const dv = d.get(f.name) orelse break :blk .ltr;
                    break :blk if (std.mem.eql(u8, strOr(dv, "ltr"), "rtl")) .rtl else .ltr;
                };
                const arb = switch (f.value) {
                    .string => |s| s,
                    .object => try value_mod.toJson(h.alloc, f.value),
                    else => continue,
                };
                try i18n.addArb(f.name, arb, dir);
            }
        }
    }
    if (str(getProp(v, "locale"))) |tag| try i18n.setLocale(tag);
    i18n_mod.setCurrent(i18n);
}

/// navigator: {"routes":[{"pattern":"home"},{"pattern":"anime/{id}"}]}.
/// Page content is a fixed box — nav semantics don't depend on page content.
/// Stack changes log "nav:<kind>" into the events log.
fn setupNavigator(h: *Harness, v: Value) !void {
    if (v != .object) return;
    const nv = try h.alloc.create(nav_mod.Navigator);
    nv.* = nav_mod.Navigator.init(h.alloc);
    h.nav = nv;
    const ctx = try h.newLogCtx(&h.events, "");
    nv.setOnChange(.{ .fn_ptr = navChangeCb, .userdata = ctx });
    if (getProp(v, "routes")) |rs| {
        if (rs == .array) {
            for (rs.array) |rv| {
                const pattern = str(getProp(rv, "pattern")) orelse continue;
                try nv.define(pattern, .{ .fn_ptr = navPageCb, .userdata = h }, parseTransition(strOr(getProp(rv, "transition"), "slide")));
            }
        }
    }
}

fn navChangeCb(userdata: ?*anyopaque, kind: nav_mod.ChangeKind) void {
    const c: *LogCtx = @ptrCast(@alignCast(userdata.?));
    const tag = std.fmt.allocPrint(c.list.allocator, "nav:{s}", .{@tagName(kind)}) catch @panic("klaxon: out of memory");
    c.list.append(tag) catch @panic("klaxon: out of memory");
}

fn navPageCb(userdata: ?*anyopaque, route: nav_mod.Route) *Node {
    const h: *Harness = @ptrCast(@alignCast(userdata.?));
    _ = route;
    const n = Node.create(h.alloc, &box_vtable) catch @panic("klaxon: out of memory");
    const s = h.alloc.create(BoxState) catch @panic("klaxon: out of memory");
    s.* = .{ .h = h, .id = "page", .w = 10, .h_ = 10, .color = 0x333333FF };
    n.state = s;
    return n;
}

// --- actions -----------------------------------------------------------------------

fn paramsFromJson(h: *Harness, v: ?Value) ![]nav_mod.Param {
    var list = std.array_list.Managed(nav_mod.Param).init(h.alloc);
    if (v) |p| {
        if (p == .object) {
            for (p.object) |f| {
                try list.append(.{ .key = f.name, .value = strOr(f.value, "") });
            }
        }
    }
    return list.toOwnedSlice();
}

/// One action. Errors land in h.last_error (the `action_error` expect key
/// checks them) instead of failing the test — error cases ARE testable.
fn runAction(h: *Harness, av: Value) void {
    const op = strOr(getProp(av, "op"), "");
    runActionInner(h, op, av) catch |e| {
        h.last_error = @errorName(e);
    };
}

fn runActionInner(h: *Harness, op: []const u8, av: Value) !void {
    // The tree is required only by ops that dispatch into it — signal/memo/
    // nav/focus ops run on tree-less state tests.
    if (std.mem.eql(u8, op, "pointer")) {
        const root = h.root orelse return error.NoTree;
        h.router.dispatchPointer(root, .{
            .phase = parsePhase(strOr(getProp(av, "phase"), "move")) orelse .move,
            .x = num(getProp(av, "x"), 0),
            .y = num(getProp(av, "y"), 0),
            .pointer = @intCast(@max(0, intOf(getProp(av, "pointer"), 0))),
            .time_ms = @intCast(@max(0, intOf(getProp(av, "t"), 0))),
        });
    } else if (std.mem.eql(u8, op, "scroll")) {
        const root = h.root orelse return error.NoTree;
        h.router.dispatchScroll(root, .{
            .x = num(getProp(av, "x"), 0),
            .y = num(getProp(av, "y"), 0),
            .delta_x = num(getProp(av, "dx"), 0),
            .delta_y = num(getProp(av, "dy"), 0),
            .time_ms = @intCast(@max(0, intOf(getProp(av, "t"), 0))),
        });
        h.router.refreshHover(root); // mirrors the host (content moves under the pointer)
    } else if (std.mem.eql(u8, op, "key")) {
        const ev = input_mod.KeyEvent{
            .kind = .key_down,
            .key = parseKey(strOr(getProp(av, "key"), "unknown")),
            .shift = boolean(getProp(av, "shift"), false),
        };
        // Host dispatch order (host.zig): Escape/Back → dispatchBack; Tab →
        // the focus manager; anything else → focused chain, then the FM's
        // activation fallback (Enter/Space).
        if (ev.key == .escape or ev.key == .back) {
            _ = h.router.dispatchBack();
        } else if (ev.key == .tab) {
            if (h.fm) |fm| _ = fm.handleKey(ev);
        } else {
            if (!h.router.dispatchKey(ev)) {
                if (h.fm) |fm| _ = fm.handleKey(ev);
            }
        }
    } else if (std.mem.eql(u8, op, "text_input")) {
        _ = h.router.dispatchKey(.{ .kind = .text_input, .text = strOr(getProp(av, "text"), "") });
    } else if (std.mem.eql(u8, op, "tick")) {
        h.timeline.tick(@intCast(@max(0, intOf(getProp(av, "ms"), 0))));
    } else if (std.mem.eql(u8, op, "focus")) {
        if (h.fm) |fm| {
            if (str(getProp(av, "id"))) |id| {
                fm.focusNode(h.findNode(id) orelse return error.UnknownNode);
            } else {
                fm.focusNode(null);
            }
        }
    } else if (std.mem.eql(u8, op, "mark_dirty")) {
        const id = strOr(getProp(av, "id"), "");
        const n = h.findNode(id) orelse return error.UnknownNode;
        n.markDirty();
    } else if (std.mem.eql(u8, op, "mark_dirty_rect")) {
        const id = strOr(getProp(av, "id"), "");
        const n = h.findNode(id) orelse return error.UnknownNode;
        n.markDirtyRect(parseRect(getProp(av, "rect")) orelse return error.BadRect);
    } else if (std.mem.eql(u8, op, "relayout")) {
        h.viewport.w = num(getProp(av, "w"), h.viewport.w);
        h.viewport.h = num(getProp(av, "h"), h.viewport.h);
        const root = h.root orelse return error.NoTree;
        root.layout(h.viewport);
        if (h.renderer) |*r| r.resize(@intFromFloat(h.viewport.w), @intFromFloat(h.viewport.h));
    } else if (std.mem.eql(u8, op, "paint")) {
        var frame = try h.renderFrame();
        frame.deinit();
    } else if (std.mem.eql(u8, op, "set_scroll")) {
        const n = h.findNode(strOr(getProp(av, "id"), "")) orelse return error.UnknownNode;
        const kind = h.scroll_kind.get(strOr(getProp(av, "id"), "")) orelse .view;
        const off = num(getProp(av, "offset"), 0);
        _ = switch (kind) {
            .view => wscroll.setScrollOffset(n, off),
            .list => wlist.setScrollOffset(n, off),
        };
    } else if (std.mem.eql(u8, op, "list_count")) {
        const n = h.findNode(strOr(getProp(av, "id"), "")) orelse return error.UnknownNode;
        wlist.setItemCount(n, @intCast(@max(0, intOf(getProp(av, "count"), 0))));
    } else if (std.mem.eql(u8, op, "list_reload")) {
        const n = h.findNode(strOr(getProp(av, "id"), "")) orelse return error.UnknownNode;
        wlist.reloadItems(n);
    } else if (std.mem.eql(u8, op, "set_locale")) {
        const i18n = h.i18n orelse return error.MissingI18n;
        try i18n.setLocale(strOr(getProp(av, "tag"), ""));
    } else if (std.mem.eql(u8, op, "signal_set")) {
        const name = strOr(getProp(av, "name"), "");
        const v = getProp(av, "value") orelse Value{ .int = 0 };
        if (h.sig_i64.get(name)) |s| {
            s.set(intOf(v, 0));
        } else if (h.sig_bool.get(name)) |s| {
            s.set(boolean(v, false));
        } else if (h.sig_f32.get(name)) |s| {
            s.set(num(v, 0));
        } else if (h.sig_text.get(name)) |s| {
            if (getProp(av, "len")) |lv| {
                // Generate `len` filler bytes — exercises the 1 MiB cap
                // without embedding it in the vector.
                const len: usize = @intCast(@max(0, intOf(lv, 0)));
                const buf = try h.alloc.alloc(u8, len);
                @memset(buf, 'x');
                try s.set(buf);
            } else {
                try s.set(strOr(v, ""));
            }
        } else return error.UnknownSignal;
    } else if (std.mem.eql(u8, op, "signal_notify")) {
        const name = strOr(getProp(av, "name"), "");
        if (h.sig_i64.get(name)) |s| {
            s.notify();
        } else if (h.sig_text.get(name)) |s| {
            s.notify();
        } else return error.UnknownSignal;
    } else if (std.mem.eql(u8, op, "nav_push")) {
        const nv = h.nav orelse return error.MissingNavigator;
        try nv.push(strOr(getProp(av, "pattern"), ""), try paramsFromJson(h, getProp(av, "params")));
    } else if (std.mem.eql(u8, op, "nav_push_path")) {
        const nv = h.nav orelse return error.MissingNavigator;
        try nv.pushPath(strOr(getProp(av, "path"), ""), try paramsFromJson(h, getProp(av, "params")));
    } else if (std.mem.eql(u8, op, "navigate")) {
        const nv = h.nav orelse return error.MissingNavigator;
        try nv.navigateTo(strOr(getProp(av, "uri"), ""));
    } else if (std.mem.eql(u8, op, "nav_replace")) {
        const nv = h.nav orelse return error.MissingNavigator;
        try nv.replace(strOr(getProp(av, "pattern"), ""), try paramsFromJson(h, getProp(av, "params")));
    } else if (std.mem.eql(u8, op, "nav_pop")) {
        const nv = h.nav orelse return error.MissingNavigator;
        _ = nv.pop();
    } else if (std.mem.eql(u8, op, "nav_back")) {
        const nv = h.nav orelse return error.MissingNavigator;
        _ = nv.onBack();
    } else if (std.mem.eql(u8, op, "nav_pop_to_root")) {
        const nv = h.nav orelse return error.MissingNavigator;
        nv.popToRoot();
    } else if (std.mem.eql(u8, op, "announce")) {
        sem.announce(strOr(getProp(av, "text"), ""), parseRegion(strOr(getProp(av, "region"), "polite")));
    } else {
        return error.UnknownOp;
    }
}

// --- expectations ------------------------------------------------------------------

const Check = struct {
    failures: *std.array_list.Managed([]const u8),
    alloc: Allocator,
    tol: f32,

    fn fail(c: *Check, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(c.alloc, fmt, args) catch @panic("klaxon: out of memory");
        c.failures.append(s) catch @panic("klaxon: out of memory");
    }
};

fn nearEq(a: f32, b: f32, tol: f32) bool {
    return @abs(a - b) <= tol;
}

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

fn rectEq(a: Rect, b: Rect, tol: f32) bool {
    return nearEq(a.x, b.x, tol) and nearEq(a.y, b.y, tol) and nearEq(a.w, b.w, tol) and nearEq(a.h, b.h, tol);
}

/// Resolve an id → node only if still live (list items die on scroll).
fn liveNode(h: *Harness, c: *Check, id: []const u8) ?*Node {
    const n = h.findNode(id) orelse {
        c.fail("unknown node id \"{s}\"", .{id});
        return null;
    };
    if (!h.isLive(n)) {
        c.fail("node \"{s}\" is no longer in the tree", .{id});
        return null;
    }
    return n;
}

fn idFor(h: *Harness, n: *Node) []const u8 {
    var it = h.ids.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == n) return e.key_ptr.*;
    }
    return "(unnamed)";
}

fn expectRects(h: *Harness, c: *Check, v: Value) void {
    if (v != .object) return;
    for (v.object) |f| {
        const n = liveNode(h, c, f.name) orelse continue;
        const want = parseRect(f.value) orelse {
            c.fail("rects.{s}: expected [x,y,w,h]", .{f.name});
            continue;
        };
        if (!rectEq(n.bounds, want, c.tol)) {
            c.fail("rects.{s}: expected [{d},{d},{d},{d}] got [{d},{d},{d},{d}]", .{ f.name, want.x, want.y, want.w, want.h, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h });
        }
    }
}

fn expectMeasured(h: *Harness, c: *Check, v: Value) void {
    if (v != .object) return;
    for (v.object) |f| {
        const n = liveNode(h, c, f.name) orelse continue;
        const want = parseAlign(f.value) orelse {
            c.fail("measured.{s}: expected [w,h]", .{f.name});
            continue;
        };
        const got = n.measure(.{ .max_w = h.viewport.w, .max_h = h.viewport.h });
        if (!nearEq(got.w, want.x, c.tol) or !nearEq(got.h, want.y, c.tol)) {
            c.fail("measured.{s}: expected [{d},{d}] got [{d},{d}]", .{ f.name, want.x, want.y, got.w, got.h });
        }
    }
}

fn expectDamage(h: *Harness, c: *Check, v: Value) void {
    const root = h.root orelse return;
    if (v == .null) {
        if (root.damage_valid) c.fail("damage: expected none, got [{d},{d},{d},{d}]", .{ root.damage.x, root.damage.y, root.damage.w, root.damage.h });
        return;
    }
    const want = parseRect(v) orelse {
        c.fail("damage: expected [x,y,w,h] or null", .{});
        return;
    };
    if (!root.damage_valid) {
        c.fail("damage: expected [{d},{d},{d},{d}] got none", .{ want.x, want.y, want.w, want.h });
        return;
    }
    if (!rectEq(root.damage, want, c.tol)) {
        c.fail("damage: expected [{d},{d},{d},{d}] got [{d},{d},{d},{d}]", .{ want.x, want.y, want.w, want.h, root.damage.x, root.damage.y, root.damage.w, root.damage.h });
    }
}

fn expectFocused(h: *Harness, c: *Check, v: Value, router_side: bool) void {
    const n = if (router_side) h.router.focused else if (h.fm) |fm| fm.focused else null;
    if (v == .null) {
        if (n) |nn| c.fail("{s}: expected null, got \"{s}\"", .{ if (router_side) "router_focused" else "focused", idFor(h, nn) });
        return;
    }
    const want = strOr(v, "");
    const got = if (n) |nn| idFor(h, nn) else "";
    if (n == null or !std.mem.eql(u8, got, want)) {
        c.fail("{s}: expected \"{s}\", got {s}", .{ if (router_side) "router_focused" else "focused", want, if (n == null) "null" else got });
    }
}

fn expectFocusOrder(h: *Harness, c: *Check, v: Value) void {
    const fm = h.fm orelse return;
    if (v != .array) return;
    const order = fm.focusOrder(h.alloc) catch return;
    var got = std.array_list.Managed([]const u8).init(h.alloc);
    for (order) |n| got.append(idFor(h, n)) catch @panic("klaxon: out of memory");
    expectSeq(c, "focus_order", v.array, got.items);
}

/// Exact-sequence compare for log-based expects.
fn expectSeq(c: *Check, key: []const u8, want: []const Value, got: []const []const u8) void {
    var i: usize = 0;
    while (i < @max(want.len, got.len)) : (i += 1) {
        const w = if (i < want.len) strOr(want[i], "?") else "<missing>";
        const g = if (i < got.len) got[i] else "<missing>";
        if (!std.mem.eql(u8, w, g)) {
            c.fail("{s}[{d}]: expected \"{s}\", got \"{s}\" (full got: {any})", .{ key, i, w, g, got });
            return;
        }
    }
}

fn expectSignals(h: *Harness, c: *Check, v: Value) void {
    if (v != .object) return;
    for (v.object) |f| {
        if (h.sig_i64.get(f.name)) |s| {
            const want = intOf(f.value, 0);
            if (s.peek() != want) c.fail("signals.{s}: expected {d}, got {d}", .{ f.name, want, s.peek() });
        } else if (h.sig_bool.get(f.name)) |s| {
            const want = boolean(f.value, false);
            if (s.peek() != want) c.fail("signals.{s}: expected {s}, got {s}", .{ f.name, boolStr(want), boolStr(s.peek()) });
        } else if (h.sig_f32.get(f.name)) |s| {
            const want = num(f.value, 0);
            if (!nearEq(s.peek(), want, c.tol)) c.fail("signals.{s}: expected {d}, got {d}", .{ f.name, want, s.peek() });
        } else if (h.sig_text.get(f.name)) |s| {
            const want = strOr(f.value, "");
            if (!std.mem.eql(u8, s.peek(), want)) c.fail("signals.{s}: expected \"{s}\", got \"{s}\"", .{ f.name, want, s.peek() });
        } else c.fail("signals.{s}: unknown signal", .{f.name});
    }
}

/// Flattened semantic tree: pre-order, dropping the synthetic group wrapper
/// the builder adds when the root has no semantics of its own.
fn flattenSem(h: *Harness, c: *Check, v: Value) void {
    const root = h.root orelse return;
    var tree = sem.buildSemanticTree(h.alloc, root) catch return;
    defer tree.deinit(h.alloc);
    var list = std.array_list.Managed(sem.SemanticNode).init(h.alloc);
    const synthetic = tree.role == .group and tree.label.len == 0 and root.semantics == null;
    if (synthetic) {
        for (tree.children) |child| flattenNode(&list, child) catch return;
    } else {
        flattenNode(&list, tree) catch return;
    }
    if (v != .array) return;
    if (v.array.len != list.items.len) {
        c.fail("a11y: expected {d} semantic nodes, got {d}", .{ v.array.len, list.items.len });
        return;
    }
    for (v.array, list.items) |ev, got| {
        checkSemNode(h, c, ev, got);
    }
}

fn flattenNode(list: *std.array_list.Managed(sem.SemanticNode), n: sem.SemanticNode) !void {
    try list.append(n); // children slices are shared with the tree (freed by tree.deinit)
    for (n.children) |child| try flattenNode(list, child);
}

fn checkSemNode(h: *Harness, c: *Check, ev: Value, got: sem.SemanticNode) void {
    if (str(getProp(ev, "role"))) |r| {
        const want = parseRole(r) orelse .none;
        if (got.role != want) c.fail("a11y role: expected \"{s}\", got \"{s}\"", .{ r, @tagName(got.role) });
    }
    if (str(getProp(ev, "label"))) |l| {
        if (!std.mem.eql(u8, got.label, l)) c.fail("a11y label: expected \"{s}\", got \"{s}\"", .{ l, got.label });
    }
    if (str(getProp(ev, "hint"))) |t| {
        if (!std.mem.eql(u8, got.hint, t)) c.fail("a11y hint: expected \"{s}\", got \"{s}\"", .{ t, got.hint });
    }
    if (str(getProp(ev, "value"))) |t| {
        if (!std.mem.eql(u8, got.value, t)) c.fail("a11y value: expected \"{s}\", got \"{s}\"", .{ t, got.value });
    }
    if (getProp(ev, "checked")) |cv| {
        const want = boolean(cv, false);
        const g = got.checked orelse false;
        if (g != want) c.fail("a11y checked: expected {s}, got {s}", .{ boolStr(want), boolStr(g) });
    }
    if (getProp(ev, "focusable")) |fv| {
        if (got.focusable != boolean(fv, false)) c.fail("a11y focusable: expected {s}, got {s}", .{ boolStr(boolean(fv, false)), boolStr(got.focusable) });
    }
    if (getProp(ev, "disabled")) |dv| {
        if (got.disabled != boolean(dv, false)) c.fail("a11y disabled: expected {s}, got {s}", .{ boolStr(boolean(dv, false)), boolStr(got.disabled) });
    }
    _ = h;
}

fn expectA11yEvents(h: *Harness, c: *Check, v: Value) void {
    const lb = h.lb orelse return;
    if (v != .array) return;
    for (v.array, 0..) |ev, i| {
        if (i >= lb.events.items.len) {
            c.fail("a11y_events[{d}]: expected \"{s}\", log ended at {d} events", .{ i, strOr(getProp(ev, "kind"), "?"), lb.events.items.len });
            return;
        }
        const got = lb.events.items[i];
        if (str(getProp(ev, "kind"))) |k| {
            if (!std.mem.eql(u8, @tagName(got.kind), k)) {
                c.fail("a11y_events[{d}]: expected kind \"{s}\", got \"{s}\"", .{ i, k, @tagName(got.kind) });
                return;
            }
        }
        if (str(getProp(ev, "text"))) |t| {
            if (!std.mem.eql(u8, got.text, t)) {
                c.fail("a11y_events[{d}]: expected text \"{s}\", got \"{s}\"", .{ i, t, got.text });
                return;
            }
        }
    }
    if (lb.events.items.len != v.array.len) {
        c.fail("a11y_events: expected {d} events, got {d}", .{ v.array.len, lb.events.items.len });
    }
}

fn expectText(h: *Harness, c: *Check, v: Value) void {
    if (v != .object) return;
    for (v.object) |f| {
        const n = liveNode(h, c, f.name) orelse continue;
        const s = n.semantics orelse {
            c.fail("text.{s}: node has no semantics", .{f.name});
            continue;
        };
        const got = if (s.label.len > 0) s.label else s.value;
        const want = strOr(f.value, "");
        if (!std.mem.eql(u8, got, want)) c.fail("text.{s}: expected \"{s}\", got \"{s}\"", .{ f.name, want, got });
    }
}

/// i18n service calls: "tr:key" / "plural:key:N" / "num:V[:opts]" /
/// "date:Y-M-D:kind" / "direction".
fn expectI18n(h: *Harness, c: *Check, v: Value) void {
    const i18n = h.i18n orelse {
        c.fail("i18n expects require setup.i18n", .{});
        return;
    };
    if (v != .object) return;
    for (v.object) |f| {
        const want = strOr(f.value, "");
        var got: []const u8 = "";
        if (std.mem.eql(u8, f.name, "direction")) {
            got = @tagName(i18n.direction());
        } else if (std.mem.startsWith(u8, f.name, "tr:")) {
            got = i18n.tr(f.name[3..]);
        } else if (std.mem.startsWith(u8, f.name, "plural:")) {
            const rest = f.name[7..];
            if (std.mem.lastIndexOfScalar(u8, rest, ':')) |ci| {
                const n = std.fmt.parseInt(i64, rest[ci + 1 ..], 10) catch 0;
                got = i18n.trPlural(h.alloc, rest[0..ci], n, .{}) catch "";
            }
        } else if (std.mem.startsWith(u8, f.name, "num:")) {
            const rest = f.name[4..];
            var opts = i18n_mod.NumberOptions{};
            var valstr = rest;
            if (std.mem.indexOfScalar(u8, rest, ':')) |ci| {
                valstr = rest[0..ci];
                var it = std.mem.splitScalar(u8, rest[ci + 1 ..], ',');
                while (it.next()) |tok| {
                    if (std.mem.eql(u8, tok, "pct")) opts.percent = true;
                    if (std.mem.eql(u8, tok, "nogroup")) opts.grouping = false;
                    if (std.mem.startsWith(u8, tok, "dec=")) opts.decimals = std.fmt.parseInt(u8, tok[4..], 10) catch null;
                }
            }
            const loc = i18n.locale() orelse continue;
            const val = std.fmt.parseFloat(f64, valstr) catch 0;
            got = loc.formatNumber(h.alloc, val, opts) catch "";
        } else if (std.mem.startsWith(u8, f.name, "date:")) {
            const rest = f.name[5..];
            // "date:2024-03-05:long"
            if (std.mem.lastIndexOfScalar(u8, rest, ':')) |ci| {
                const kind: i18n_mod.DateKind = if (std.mem.eql(u8, rest[ci + 1 ..], "long")) .long else if (std.mem.eql(u8, rest[ci + 1 ..], "medium")) .medium else .short;
                var it = std.mem.splitScalar(u8, rest[0..ci], '-');
                const y = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
                const m = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
                const d = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
                const loc = i18n.locale() orelse continue;
                got = loc.formatDate(h.alloc, .{ .year = y, .month = m, .day = d }, kind) catch "";
            }
        }
        if (!std.mem.eql(u8, got, want)) {
            c.fail("i18n.{s}: expected \"{s}\", got \"{s}\"", .{ f.name, want, got });
        }
    }
}

fn expectPixels(h: *Harness, c: *Check, v: Value) void {
    if (v != .array) return;
    var frame = h.renderFrame() catch {
        c.fail("pixels: render failed", .{});
        return;
    };
    defer frame.deinit();
    for (v.array, 0..) |pv, i| {
        const want = parseColor(getProp(pv, "color")) orelse {
            c.fail("pixels[{d}]: missing color", .{i});
            continue;
        };
        const got = frame.pixelAt(@intFromFloat(num(getProp(pv, "x"), 0)), @intFromFloat(num(getProp(pv, "y"), 0)));
        const approx = boolean(getProp(pv, "approx"), false);
        const ok = if (approx) blk: {
            break :blk golden.channelDiff(got, want, 24) <= 2 and golden.channelDiff(got, want, 16) <= 2 and
                golden.channelDiff(got, want, 8) <= 2 and golden.channelDiff(got, want, 0) <= 2;
        } else got == want;
        if (!ok) c.fail("pixels[{d}] at ({d},{d}): expected #{x:0>8}, got #{x:0>8}", .{ i, num(getProp(pv, "x"), 0), num(getProp(pv, "y"), 0), want, got });
    }
}

fn expectPixelCounts(h: *Harness, c: *Check, v: Value) void {
    if (v != .array) return;
    var frame = h.renderFrame() catch {
        c.fail("pixel_counts: render failed", .{});
        return;
    };
    defer frame.deinit();
    for (v.array, 0..) |pv, i| {
        const color = parseColor(getProp(pv, "color")) orelse {
            c.fail("pixel_counts[{d}]: missing color", .{i});
            continue;
        };
        const rect = parseRect(getProp(pv, "rect"));
        const n = if (rect) |r| frame.countColorIn(r, color) else frame.countColor(color);
        if (getProp(pv, "exact")) |e| {
            const want: u64 = @intCast(@max(0, intOf(e, 0)));
            if (n != want) c.fail("pixel_counts[{d}]: expected exactly {d} of #{x:0>8}, got {d}", .{ i, want, color, n });
        }
        if (getProp(pv, "min")) |e| {
            const want: u64 = @intCast(@max(0, intOf(e, 0)));
            if (n < want) c.fail("pixel_counts[{d}]: expected ≥{d} of #{x:0>8}, got {d}", .{ i, want, color, n });
        }
        if (getProp(pv, "max")) |e| {
            const want: u64 = @intCast(@max(0, intOf(e, 0)));
            if (n > want) c.fail("pixel_counts[{d}]: expected ≤{d} of #{x:0>8}, got {d}", .{ i, want, color, n });
        }
    }
}

fn expectScroll(h: *Harness, c: *Check, v: Value) void {
    if (v != .object) return;
    for (v.object) |f| {
        const n = liveNode(h, c, f.name) orelse continue;
        const kind = h.scroll_kind.get(f.name) orelse .view;
        const got = switch (kind) {
            .view => wscroll.scrollOffset(n),
            .list => wlist.scrollOffset(n),
        };
        const want = num(f.value, 0);
        if (!nearEq(got, want, c.tol)) c.fail("scroll.{s}: expected {d}, got {d}", .{ f.name, want, got });
    }
}

/// scroll_info: {id: {"offset":N,"max_offset":N,"viewport":N,"content":N,
/// "thumb":N}} — reads the scrollable's generic vtable hook (SCROLL-007).
fn expectScrollInfo(h: *Harness, c: *Check, v: Value) void {
    if (v != .object) return;
    for (v.object) |f| {
        const n = liveNode(h, c, f.name) orelse continue;
        const si = n.vtable.scroll_info orelse {
            c.fail("scroll_info.{s}: node is not scrollable", .{f.name});
            continue;
        };
        const info = si(n);
        if (f.value != .object) continue;
        const fields = .{ "offset", "max_offset", "viewport", "content", "thumb" };
        inline for (fields) |name| {
            if (getProp(f.value, name)) |ev| {
                const got = if (comptime std.mem.eql(u8, name, "thumb")) info.thumbFraction() else @field(info, name);
                const want = num(ev, 0);
                if (!nearEq(got, want, c.tol)) c.fail("scroll_info.{s}.{s}: expected {d}, got {d}", .{ f.name, name, want, got });
            }
        }
    }
}

fn expectChildren(h: *Harness, c: *Check, v: Value) void {
    if (v != .object) return;
    for (v.object) |f| {
        const n = liveNode(h, c, f.name) orelse continue;
        const want: usize = @intCast(@max(0, intOf(f.value, 0)));
        if (n.children.items.len != want) c.fail("children.{s}: expected {d}, got {d}", .{ f.name, want, n.children.items.len });
    }
}

fn expectFirstItem(h: *Harness, c: *Check, v: Value) void {
    if (v != .object) return;
    for (v.object) |f| {
        const n = liveNode(h, c, f.name) orelse continue;
        if (n.children.items.len == 0) {
            c.fail("first_item.{s}: no live items", .{f.name});
            continue;
        }
        const s = stateOf(BoxState, n.children.items[0]);
        const want: usize = @intCast(@max(0, intOf(f.value, 0)));
        if (s.item_index != want) c.fail("first_item.{s}: expected {d}, got {d}", .{ f.name, want, s.item_index });
    }
}

fn expectNav(h: *Harness, c: *Check, v: Value) void {
    const nv = h.nav orelse {
        c.fail("nav expects require setup.navigator", .{});
        return;
    };
    if (v != .object) return;
    if (getProp(v, "depth")) |dv| {
        const want: usize = @intCast(@max(0, intOf(dv, 0)));
        if (nv.depth() != want) c.fail("nav.depth: expected {d}, got {d}", .{ want, nv.depth() });
    }
    if (str(getProp(v, "current"))) |want| {
        const cur = nv.current();
        const got = if (cur) |p| p.route.path else "";
        if (!std.mem.eql(u8, got, want)) c.fail("nav.current: expected \"{s}\", got \"{s}\"", .{ want, got });
    }
    if (getProp(v, "params")) |pv| {
        const cur = nv.current();
        if (cur == null) {
            c.fail("nav.params: stack empty", .{});
            return;
        }
        if (pv == .object) {
            for (pv.object) |f| {
                const got = cur.?.route.params.get(f.name) orelse "";
                if (!std.mem.eql(u8, got, strOr(f.value, ""))) c.fail("nav.params.{s}: expected \"{s}\", got \"{s}\"", .{ f.name, strOr(f.value, ""), got });
            }
        }
    }
}

// --- the runner --------------------------------------------------------------------

pub const TestResult = struct {
    id: []const u8 = "",
    domain: []const u8 = "",
    rule: []const u8 = "",
    passed: bool = false,
    failures: std.array_list.Managed([]const u8),
};

/// Run one test vector. `alloc` should be an arena (or a scope that frees).
pub fn runTest(alloc: Allocator, tv: Value) TestResult {
    var res = TestResult{
        .id = strOr(tv.get("id"), "?"),
        .domain = strOr(tv.get("domain"), "?"),
        .rule = strOr(tv.get("rule"), ""),
        .failures = std.array_list.Managed([]const u8).init(alloc),
    };
    var c = Check{ .failures = &res.failures, .alloc = alloc, .tol = num(tv.get("tolerance"), DEFAULT_TOLERANCE) };

    runTestInner(alloc, tv, &c) catch |e| {
        c.fail("error: {s}", .{@errorName(e)});
    };
    res.passed = res.failures.items.len == 0;
    return res;
}

fn runTestInner(alloc: Allocator, tv: Value, c: *Check) !void {
    const h = try Harness.init(alloc);
    defer h.deinit();

    const setup = getProp(tv, "setup") orelse empty_obj;
    if (parseAlign(getProp(setup, "viewport"))) |vp| {
        h.viewport.w = vp.x;
        h.viewport.h = vp.y;
    }
    try setupSignals(h, getProp(setup, "signals") orelse empty_obj);
    try setupI18n(h, getProp(setup, "i18n") orelse empty_obj);
    try setupNavigator(h, getProp(setup, "navigator") orelse empty_obj);
    try setupEffects(h, getProp(setup, "effects") orelse empty_obj);
    try setupMemo(h, getProp(setup, "memo") orelse empty_obj);

    if (getProp(setup, "tree")) |tree| {
        h.root = try buildNode(h, tree);
        h.fm.?.setRoot(h.root.?);
        h.root.?.layout(h.viewport);
        h.root.?.clearDamage(); // frame-0 boundary: actions observe a clean damage accumulator
    }

    if (getProp(tv, "actions")) |actions| {
        if (actions == .array) {
            for (actions.array) |av| runAction(h, av);
        }
    }

    const expect = getProp(tv, "expect") orelse return;
    if (expect != .object) return;
    for (expect.object) |f| {
        checkExpect(h, c, f.name, f.value);
    }
}

fn checkExpect(h: *Harness, c: *Check, key: []const u8, v: Value) void {
    if (std.mem.eql(u8, key, "rects")) {
        expectRects(h, c, v);
    } else if (std.mem.eql(u8, key, "measured")) {
        expectMeasured(h, c, v);
    } else if (std.mem.eql(u8, key, "damage")) {
        expectDamage(h, c, v);
    } else if (std.mem.eql(u8, key, "focused")) {
        expectFocused(h, c, v, false);
    } else if (std.mem.eql(u8, key, "router_focused")) {
        expectFocused(h, c, v, true);
    } else if (std.mem.eql(u8, key, "focus_order")) {
        expectFocusOrder(h, c, v);
    } else if (std.mem.eql(u8, key, "gestures")) {
        if (v == .array) expectSeq(c, "gestures", v.array, h.gestures.items);
    } else if (std.mem.eql(u8, key, "events")) {
        if (v == .array) expectSeq(c, "events", v.array, h.events.items);
    } else if (std.mem.eql(u8, key, "effect_log")) {
        if (v == .array) expectSeq(c, "effect_log", v.array, h.effect_log.items);
    } else if (std.mem.eql(u8, key, "signals")) {
        expectSignals(h, c, v);
    } else if (std.mem.eql(u8, key, "memo_value")) {
        const m = h.memo orelse {
            c.fail("memo_value: no memo in setup", .{});
            return;
        };
        const want = intOf(v, 0);
        if (m.get() != want) c.fail("memo_value: expected {d}, got {d}", .{ want, m.get() });
    } else if (std.mem.eql(u8, key, "a11y")) {
        flattenSem(h, c, v);
    } else if (std.mem.eql(u8, key, "a11y_events")) {
        expectA11yEvents(h, c, v);
    } else if (std.mem.eql(u8, key, "text")) {
        expectText(h, c, v);
    } else if (std.mem.eql(u8, key, "i18n")) {
        expectI18n(h, c, v);
    } else if (std.mem.eql(u8, key, "pixels")) {
        expectPixels(h, c, v);
    } else if (std.mem.eql(u8, key, "pixel_counts")) {
        expectPixelCounts(h, c, v);
    } else if (std.mem.eql(u8, key, "scroll")) {
        expectScroll(h, c, v);
    } else if (std.mem.eql(u8, key, "scroll_info")) {
        expectScrollInfo(h, c, v);
    } else if (std.mem.eql(u8, key, "children")) {
        expectChildren(h, c, v);
    } else if (std.mem.eql(u8, key, "first_item")) {
        expectFirstItem(h, c, v);
    } else if (std.mem.eql(u8, key, "nav")) {
        expectNav(h, c, v);
    } else if (std.mem.eql(u8, key, "action_error")) {
        const want = strOr(v, "");
        const got = h.last_error orelse "";
        if (!std.mem.eql(u8, got, want)) c.fail("action_error: expected \"{s}\", got \"{s}\"", .{ want, got });
    } else {
        c.fail("unknown expect key \"{s}\"", .{key});
    }
}

// --- tests ------------------------------------------------------------------------
// Smoke coverage for the engine itself; the corpus in conformance/tests/ is the
// real suite (run via `zig build conformance`).

test "conformance: box DSL + rects + damage expect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc =
        \\{"id":"T-1","domain":"layout","setup":{"viewport":[200,100],
        \\"tree":{"type":"column","children":[
        \\  {"type":"box","id":"a","props":{"w":50,"h":30}},
        \\  {"type":"box","id":"b","props":{"w":20,"h":10}}]}},
        \\"actions":[{"op":"mark_dirty","id":"a"}],
        \\"expect":{"rects":{"a":[0,0,200,30],"b":[0,30,200,10]},"damage":[0,0,200,30]}}
    ;
    const tv = try value_mod.parseJson(arena.allocator(), doc);
    const res = runTest(arena.allocator(), tv);
    try std.testing.expect(res.passed);
    if (!res.passed) for (res.failures.items) |f| std.debug.print("  {s}\n", .{f});
}

test "conformance: failing vector reports the mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc =
        \\{"id":"T-2","domain":"layout",
        \\"setup":{"viewport":[100,100],"tree":{"type":"box","id":"a","props":{"w":10,"h":10}}},
        \\"expect":{"rects":{"a":[0,0,99,99]}}}
    ;
    const tv = try value_mod.parseJson(arena.allocator(), doc);
    const res = runTest(arena.allocator(), tv);
    try std.testing.expect(!res.passed);
    try std.testing.expect(res.failures.items.len > 0);
}

test "conformance: signal + effect ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc =
        \\{"id":"T-3","domain":"state",
        \\"setup":{"signals":{"a":1,"b":2},
        \\"  "effects":[{"name":"e","reads":["a","b"],"op":"add"}]},
        \\"actions":[{"op":"signal_set","name":"a","value":5}],
        \\"expect":{"effect_log":["e=3","e=7"],"signals":{"a":5}}}
    ;
    const tv = try value_mod.parseJson(arena.allocator(), doc);
    const res = runTest(arena.allocator(), tv);
    try std.testing.expect(res.passed);
    if (!res.passed) for (res.failures.items) |f| std.debug.print("  {s}\n", .{f});
}
