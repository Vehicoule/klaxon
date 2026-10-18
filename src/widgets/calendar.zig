// M3E Calendar (Phase 4d P2) — an inline (non-modal) calendar month view.
// Reuses the date_picker's civil calendar helpers (same algorithms).
//
// Spec: docs/specs/m3e-specs-4d-p2-calendar.md
//
// Differences from date_picker: inline (always visible), narrower (280dp),
// SurfaceContainer (not High), no OK/Cancel footer, smaller cells (36dp).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const i18n_mod = @import("../ui/i18n.zig");
const theme_mod = @import("../theme.zig");
const date_picker_w = @import("date_picker.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

pub const CalendarOptions = struct {
    theme: Theme = theme_mod.light,
    width: f32 = 280,
    /// "Today" as a UTC epoch day (null = system clock, UTC).
    today: ?i64 = null,
};

// --- Tokens ---
const panel_corner: f32 = 12;
const header_h: f32 = 56;
const weekday_h: f32 = 40;
const cell: f32 = 36;
const cell_gap: f32 = 4;
const grid_rows: usize = 6;
const h_pad: f32 = 8;
const chevron_hit: f32 = 40;
const chevron_icon: f32 = 24;

const grid_h: f32 = grid_rows * (cell + cell_gap); // 240
const total_h: f32 = header_h + weekday_h + grid_h + h_pad; // 312

// Weekday letters resolve per-frame through the active locale's CLDR
// `weekday_letter` table (Sunday-first, the grid's convention).

// --- State ---

const CalState = struct {
    opts: CalendarOptions,
    selected: ?*ui.state.Signal(?i64),
    displayed: ?*ui.state.Signal(i64),
    hovered_day: ?i64 = null,
    i18n: ?*i18n_mod.I18n = null,
};

fn stateOf(n: *Node) *CalState {
    return @ptrCast(@alignCast(n.state.?));
}

fn selDay(s: *CalState) ?i64 {
    return if (s.selected) |sig| sig.peek() else null;
}

fn dispMonth(s: *CalState) i64 {
    return if (s.displayed) |sig| sig.peek() else date_picker_w.todayDay(null);
}

// --- Measure / Layout ---

fn calMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const w = @max(s.opts.width, 280);
    return .{
        .w = @max(c.min_w, @min(c.max_w, w)),
        .h = @max(c.min_h, @min(c.max_h, total_h)),
    };
}

fn calLayout(_: *Node, _: Rect) void {}

// --- Paint ---

fn calPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;

    // Panel background.
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, panel_corner, t.colors.surface_container);

    const inner_w = b.w - h_pad * 2;
    const cell_w = (inner_w - cell_gap * 6) / 7;

    // Header: month-year + chevrons.
    const month_first = dispMonth(s);
    const civil = date_picker_w.civilFromDays(month_first);
    var month_buf: [32]u8 = undefined;
    const month_str_slice = std.fmt.bufPrint(&month_buf, "{s} {d}", .{ date_picker_w.monthName(civil.m), civil.y }) catch "?";
    month_buf[month_str_slice.len] = 0;
    const month_str: [:0]const u8 = month_buf[0..month_str_slice.len :0];
    const ts = t.type_scale.title_medium;
    const title_x = b.x + h_pad + 16;
    const title_y = b.y + (header_h - ts.line_height) / 2 + ts.line_height * 0.8;
    ui.paint.textStyled(ctx, month_str, title_x, title_y, ts.size, ts.weight, ts.letter_spacing, t.colors.on_surface);

    // Chevrons — vector triangles, not text glyphs: font fallback resolves
    // U+25C0/U+25B6 through the color-emoji font (a blue emoji button with
    // a white cutout), which ignores the theme ink color entirely.
    const chev_y = b.y + (header_h - chevron_icon) / 2;
    const chev_prev_x = b.x + b.w - h_pad - 16 - chevron_icon * 2 - 8;
    const chev_next_x = b.x + b.w - h_pad - 16 - chevron_icon;
    // 24dp icon box, ~10x14 triangle centered.
    const pxs = [_]f32{ chev_prev_x + 7, chev_prev_x + 17, chev_prev_x + 17 };
    const pys = [_]f32{ chev_y + 12, chev_y + 5, chev_y + 19 };
    ui.paint.fillPolygon(ctx, &pxs, &pys, t.colors.on_surface_variant);
    const nxs = [_]f32{ chev_next_x + 17, chev_next_x + 7, chev_next_x + 7 };
    const nys = [_]f32{ chev_y + 12, chev_y + 5, chev_y + 19 };
    ui.paint.fillPolygon(ctx, &nxs, &nys, t.colors.on_surface_variant);

    // Weekday row.
    const wd_y = b.y + header_h;
    const ls = t.type_scale.body_small;
    for (0..7) |col| {
        const letter = date_picker_w.weekdayLetter(col);
        const cx = b.x + h_pad + @as(f32, @floatFromInt(col)) * (cell_w + cell_gap) + cell_w / 2;
        const m = ui.paint.measureTextStyled(letter, ls.size, ls.weight, ls.letter_spacing);
        ui.paint.textStyled(ctx, letter, cx - m.width / 2, wd_y + (weekday_h - ls.line_height) / 2 + ls.line_height * 0.8, ls.size, ls.weight, ls.letter_spacing, t.colors.on_surface_variant);
    }

    // Day grid.
    const grid_y = wd_y + weekday_h;
    const today = date_picker_w.clampDay(date_picker_w.todayDay(s.opts.today));
    const sel = selDay(s);
    const first_weekday = date_picker_w.weekdayFromDays(month_first); // 0=Sun..6=Sat
    const days_in_month = date_picker_w.daysInMonth(civil.y, civil.m);

    var day: i64 = 1;
    var row: usize = 0;
    while (row < grid_rows) : (row += 1) {
        var col: usize = 0;
        while (col < 7) : (col += 1) {
            const idx = row * 7 + col;
            if (idx >= first_weekday and day <= days_in_month) {
                const epoch_day = date_picker_w.clampDay(date_picker_w.daysFromCivil(civil.y, civil.m, day));
                const cx = b.x + h_pad + @as(f32, @floatFromInt(col)) * (cell_w + cell_gap);
                const cy = grid_y + @as(f32, @floatFromInt(row)) * (cell + cell_gap);

                // Cell background.
                const is_sel = sel != null and sel.? == epoch_day;
                const is_today = today == epoch_day;
                if (is_sel) {
                    ui.paint.fillRRect(ctx, cx, cy, cell_w, cell, cell / 2, t.colors.primary);
                } else if (is_today) {
                    ui.paint.strokeRRect(ctx, cx, cy, cell_w, cell, cell / 2, 1, t.colors.primary);
                }

                // Day number.
                var day_buf: [5]u8 = undefined;
                const day_slice = std.fmt.bufPrint(&day_buf, "{d}", .{day}) catch "?";
                day_buf[day_slice.len] = 0;
                const day_str: [:0]const u8 = day_buf[0..day_slice.len :0];
                const day_color = if (is_sel)
                    t.colors.on_primary
                else if (is_today)
                    t.colors.primary
                else
                    t.colors.on_surface;
                const dm = ui.paint.measureTextStyled(day_str, ls.size, if (is_sel) 700 else ls.weight, ls.letter_spacing);
                ui.paint.textStyled(ctx, day_str, cx + (cell_w - dm.width) / 2, cy + (cell - dm.height) / 2 + dm.height * 0.8, ls.size, if (is_sel) 700 else ls.weight, ls.letter_spacing, day_color);

                day += 1;
            }
        }
    }
}

// --- Input ---

fn calPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    const b = n.bounds;
    if (ev.phase != .up) return false;

    // Chevron taps.
    const chev_y0 = b.y;
    const chev_y1 = b.y + header_h;
    if (ev.y >= chev_y0 and ev.y <= chev_y1) {
        const chev_prev_x = b.x + b.w - h_pad - 16 - chevron_icon * 2 - 8;
        const chev_next_x = b.x + b.w - h_pad - 16 - chevron_icon;
        // Hit target is `chevron_hit` (40dp) centered on the 24dp icon —
        // the bare icon was below the a11y touch floor.
        const hit_inset = (chevron_hit - chevron_icon) / 2;
        if (ev.x >= chev_prev_x - hit_inset and ev.x <= chev_prev_x + chevron_icon + hit_inset) {
            pageMonth(s, n, -1);
            return true;
        }
        if (ev.x >= chev_next_x - hit_inset and ev.x <= chev_next_x + chevron_icon + hit_inset) {
            pageMonth(s, n, 1);
            return true;
        }
    }

    // Day cell tap.
    const grid_y = b.y + header_h + weekday_h;
    const inner_w = b.w - h_pad * 2;
    const cell_w = (inner_w - cell_gap * 6) / 7;
    if (ev.y >= grid_y and ev.y <= grid_y + grid_h) {
        const col: usize = @intCast(@min(6, @max(0, @as(i32, @intFromFloat((ev.x - b.x - h_pad) / (cell_w + cell_gap))))));
        const row: usize = @intCast(@min(5, @max(0, @as(i32, @intFromFloat((ev.y - grid_y) / (cell + cell_gap))))));
        const idx = row * 7 + col;
        const month_first = dispMonth(s);
        const civil = date_picker_w.civilFromDays(month_first);
        const first_weekday = date_picker_w.weekdayFromDays(month_first);
        const days_in_month = date_picker_w.daysInMonth(civil.y, civil.m);
        if (idx >= first_weekday) {
            const day_num = idx - first_weekday + 1;
            if (day_num <= days_in_month) {
                const epoch_day = date_picker_w.clampDay(date_picker_w.daysFromCivil(civil.y, civil.m, @intCast(day_num)));
                if (s.selected) |sig| sig.set(epoch_day);
                n.markDirty();
                return true;
            }
        }
    }
    return false;
}

fn pageMonth(s: *CalState, n: *Node, delta: i32) void {
    const month_first = dispMonth(s);
    const civil = date_picker_w.civilFromDays(month_first);
    var y = civil.y;
    var m = civil.m + delta;
    if (m < 1) {
        m = 12;
        y -= 1;
    } else if (m > 12) {
        m = 1;
        y += 1;
    }
    const new_first = date_picker_w.clampDay(date_picker_w.daysFromCivil(y, m, 1));
    if (s.displayed) |sig| sig.set(new_first);
    n.markDirty();
}

// --- Deinit ---

fn calDeinit(n: *Node) void {
    i18n_mod.unsubscribeLocale(stateOf(n).i18n, .{ .fn_ptr = calLocaleCb, .userdata = n });
    n.allocator.destroy(stateOf(n));
}

/// The painted weekday letters read the locale live — a switch just needs
/// a repaint + the a11y label re-resolved.
fn calLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    ui.semantics.attach(n, .{ .role = .group, .label = i18n_mod.tr("Calendar"), .focusable = false });
    n.markDirty();
}

// --- VTable ---

const cal_vtable = ui.node.VTable{
    .measure = calMeasure,
    .layout = calLayout,
    .paint = calPaint,
    .on_pointer = calPointer,
    .deinit = calDeinit,
};

// --- Factory ---

pub fn calendar(
    allocator: std.mem.Allocator,
    selected: ?*ui.state.Signal(?i64),
    displayed: ?*ui.state.Signal(i64),
    opts: CalendarOptions,
) !*Node {
    const node = try Node.create(allocator, &cal_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(CalState);
    errdefer allocator.destroy(s);

    s.* = .{ .opts = opts, .selected = selected, .displayed = displayed };
    node.state = @ptrCast(s);

    calLocaleCb(node); // the same path resolves the label in the active locale
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = calLocaleCb, .userdata = node });

    return node;
}

// --- Tests ---

test "calendar: measure returns 280×312" {
    const a = std.testing.allocator;
    const n = try calendar(a, null, null, .{});
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(@as(f32, 280), sz.w, 0.001);
    try std.testing.expectApproxEqAbs(total_h, sz.h, 0.001);
}

test "calendar: tap a day selects it" {
    const sig = try ui.state.Signal(?i64).init(std.testing.allocator, null);
    defer sig.deinit();
    const a = std.testing.allocator;
    // Use a fixed "today" so the displayed month is deterministic.
    const fixed_today = date_picker_w.daysFromCivil(2026, 10, 15); // Oct 2026
    const n = try calendar(a, sig, null, .{ .today = fixed_today });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 280, .h = total_h });
    // Tap somewhere in the middle of the grid (row 2, col 3) — guaranteed
    // to land on a valid day cell for any month.
    const grid_y = header_h + weekday_h;
    const inner_w = 280 - h_pad * 2;
    const cell_w = (inner_w - cell_gap * 6) / 7;
    const tap_x = h_pad + 3 * (cell_w + cell_gap) + cell_w / 2;
    const tap_y = grid_y + 2 * (cell + cell_gap) + cell / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = tap_x, .y = tap_y, .raw_x = tap_x, .raw_y = tap_y });
    // A day was selected (not null) and it's in October 2026.
    const sel = sig.peek();
    try std.testing.expect(sel != null);
    const civil = date_picker_w.civilFromDays(sel.?);
    try std.testing.expectEqual(@as(i64, 2026), civil.y);
    try std.testing.expectEqual(@as(i64, 10), civil.m);
}

test "golden: the calendar paints SurfaceContainer + a day grid" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try calendar(a, null, null, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 300, 340);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 280, .h = total_h });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // Panel fill.
    try std.testing.expectEqual(t.colors.surface_container, f.pixelAt(20, 20));
    // Outside the panel corner: background.
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(10, 10));
}

test "golden: the selected day paints a primary-filled cell with on_primary ink" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    // A fixed "today" keeps the displayed month deterministic (Oct 2026).
    const fixed_today = date_picker_w.daysFromCivil(2026, 10, 15);
    const sel = try ui.state.Signal(?i64).init(a, null);
    defer sel.deinit();
    const n = try calendar(a, sel, null, .{ .theme = t, .today = fixed_today });
    defer n.deinit();
    var r = try golden.Renderer.init(a, 300, 340);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 280, .h = total_h });
    // counts are scoped to the panel INSET by the corner radius: the light
    // theme's on_primary is white (0xFFFFFFFF), and the rounded corners show
    // the white background — indistinguishable without the inset
    const panel: ui.node.Rect = .{ .x = 10 + panel_corner, .y = 10 + panel_corner, .w = 280 - 2 * panel_corner, .h = total_h - 2 * panel_corner };
    // unselected: no filled primary cell (today is only stroked) and no
    // on_primary ink anywhere in the panel
    r.paint(n, 0xFFFFFFFF);
    var f1 = try r.readback(a);
    defer f1.deinit();
    const base_primary = f1.countColorIn(panel, t.colors.primary);
    try std.testing.expectEqual(@as(u64, 0), f1.countColorIn(panel, t.colors.on_primary));
    // select Oct 10 (in the displayed month): a filled primary cell
    sel.set(date_picker_w.daysFromCivil(2026, 10, 10));
    n.layout(.{ .x = 10, .y = 10, .w = 280, .h = total_h });
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(a);
    defer f2.deinit();
    // the filled circle (r = 18 → ~1017px, minus the day-number ink) dominates
    // the today stroke (~100px) — font-independent (the fill needs no glyphs)
    try std.testing.expect(f2.countColorIn(panel, t.colors.primary) > base_primary + 400);
}

test "calendar: i18n — the weekday letters paint in the locale; the a11y label re-resolves" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("fr", "{\"@@locale\": \"fr\", \"Calendar\": \"Calendrier\"}", .ltr);
    try i18n.setLocale("fr");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const fixed_today = date_picker_w.daysFromCivil(2026, 10, 15);
    const n = try calendar(a, null, null, .{ .theme = theme_mod.light, .today = fixed_today });
    defer n.deinit();
    // the group label resolved through tr() at build
    try std.testing.expectEqualStrings("Calendrier", n.semantics.?.label);
    // the fr CLDR letters paint (Sunday-first: D L M M J V S)
    var r = try golden.Renderer.init(a, 300, 340);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 280, .h = total_h });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    const wd_y = 10 + header_h;
    const cell_w = (280 - h_pad * 2 - cell_gap * 6) / 7;
    // "D" has ink in its left half where "S" would leave a gap — probe the
    // left column center for the letter's left-edge ink
    const lcol = Rect{ .x = 10 + h_pad, .y = wd_y + weekday_h / 2 - 8, .w = cell_w, .h = 16 };
    try std.testing.expect(f.countColorApproxIn(lcol, theme_mod.light.colors.on_surface_variant) > 0);
    // a switch re-resolves the label + repaints (the callback marks dirty)
    try i18n.setLocale("en");
    try std.testing.expectEqualStrings("Calendar", n.semantics.?.label);
}
