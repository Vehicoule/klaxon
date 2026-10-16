// M3E date picker (Phase 2d.4 PR #33) — the modal date picker's calendar
// panel (single date, picker mode), ported from Compose material3
// DatePicker.kt + DatePickerModalTokens.kt (/tmp/m3compose2/d3-DatePicker.kt,
// d3-DatePickerModalTokens.kt) + the M3E spec (m3.material.io/components/
// date-pickers) + the m3e-canvas / matraic-m3e visual references.
//
// Tokens (DatePickerModalTokens):
//   - container: SurfaceContainerHigh, CornerExtraLarge (28dp), 360dp wide
//   - header (120dp): title = LabelLarge + OnSurfaceVariant ("Select date"),
//     headline = HeadlineLarge + OnSurfaceVariant (the selected date
//     "EEE, MMM d", or the title when nothing is selected), a 1dp
//     OutlineVariant divider at the header's bottom
//   - month/year nav row (56dp): the month-year label (LabelLarge +
//     OnSurfaceVariant) and prev/next chevron icon buttons (OnSurfaceVariant,
//     40dp hit areas, circular state layer)
//   - weekday row (48dp): 7 single letters (BodyLarge + OnSurface)
//   - day grid: 6 rows x 48dp over a 288dp area, 40dp CornerFull cells spread
//     evenly (7dp gaps); selected = Primary circle + OnPrimary label; today =
//     a 1dp Primary outline + Primary label; unselected = OnSurface; empty
//     cells for the days outside the month (the modal grid shows no
//     adjacent-month days)
//   - footer: Cancel / OK text buttons (LabelLarge + Primary, CornerFull
//     state layer, right-aligned, 8dp gap, 12dp bottom/right padding)
//
// State: `selected` is a two-way Signal(?i64) holding a UTC epoch day (null =
// no selection); `displayed` is a two-way Signal(i64) holding the displayed
// month (the epoch day of its 1st). Tapping a day selects it (the signal
// round-trips); the chevrons page the displayed month (clamped to
// 1900..2100, disabled at the edges); OK fires on_select, Cancel on_cancel.
// "Today" is injected (opts.today) or read from the system clock (UTC) —
// deterministic tests inject it.
//
//   - The year picker (YearPickerMenuButton + the YearPicker grid): the
//     month-year label is a TextButton + ArrowDropDown (rotated when open)
//     toggling a scrollable 3-column year grid (72×36 CornerFull cells,
//     16dp row gap, wheel + drag scroll, current year = 1dp Primary
//     outline + Primary label, selected = Primary + OnPrimary); a year
//     tap closes the picker and pages to that year's same month.
//
// v1 deviations (documented, fixed later):
//   - No date-input mode, no range selection, no docked variant, no swipe
//     paging on the day grid (chevron paging, the desktop idiom).
//   - Header/footer strings are en-only ("Select date", Cancel/OK); the
//     month/weekday names already route through the active locale.
//   - UTC dates (epoch days); no timezone/locale calendar model (the grid
//     is always Sunday-first — RTL mirrors it, it does not re-order it).
//   - The headline color follows the Compose token (OnSurfaceVariant; the
//     m3e-canvas oracle paints OnSurface — the Compose token + matraic-m3e
//     agree, they win).
//   - No keyboard navigation within the grid (arrows/home/end) yet.
//
// RTL: the whole panel mirrors like upstream's placeRelative layout —
// header text to the start edge, the month-year button + chevrons to the
// start edge (chevron glyphs auto-mirror), the weekday columns and the
// day/year grids read right-to-left, the footer anchors to the left.
// `zoneAt` maps the hit point into the unmirrored (LTR) space once, so
// paint + hit-testing stay in lockstep.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const i18n_mod = @import("../ui/i18n.zig");
const theme_mod = @import("../theme.zig");
const icon_w = @import("icon.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

pub const DatePickerOptions = struct {
    theme: Theme = theme_mod.light,
    /// The panel width (DatePickerModalTokens.ContainerWidth = 360dp).
    width: f32 = 360,
    /// The header title (the supporting text; "Select date" by default).
    title: []const u8 = "Select date",
    /// "Today" as a UTC epoch day (null = the system clock, UTC) — injected
    /// for deterministic tests.
    today: ?i64 = null,
};

/// M3E measurement tokens (DatePickerModalTokens + the private vals).
const container_corner: f32 = 28; // CornerExtraLarge
const header_h: f32 = 120; // HeaderContainerHeight
const nav_h: f32 = 56; // MonthYearHeight
const grid_rows: usize = 6; // MaxCalendarRows
const cell: f32 = 40; // DateContainerWidth/Height
/// RecommendedSizeForAccessibility — the weekday label row rides the
/// platform's interactive floor (theme.platform.hit_target_min;
/// 48dp mobile / 24 desktop).
fn weekdayRowH(t: Theme) f32 {
    return t.platform.hit_target_min;
}
/// The day rows ride the same a11y floor, floored at the 40dp cell so a
/// dense theme can't overlap the visuals.
fn rowH(t: Theme) f32 {
    return @max(cell, t.platform.hit_target_min);
}
const h_pad: f32 = 12; // DatePickerHorizontalPadding
const title_pad_top: f32 = 16; // DatePickerTitlePadding
const headline_pad_bottom: f32 = 12; // DatePickerHeadlinePadding
const footer_h: f32 = 40;
const footer_pad_bottom: f32 = 12;
const footer_gap: f32 = 8;
const footer_pad_x: f32 = 12; // the text button's horizontal padding
const chevron_hit: f32 = 40;
const chevron_icon: f32 = 24;
const min_year: i64 = 1900; // DatePickerDefaults.YearRange
const max_year: i64 = 2100;
// the year picker (DatePicker.kt YearPicker + YearPickerMenuButton):
// LazyVerticalGrid of 3 columns (YearsInRow), 72×36 cells
// (SelectionYearContainerWidth/Height), 16dp vertical spacing
// (YearsVerticalPadding), CircleShape state layer; the menu button is a
// TextButton + ArrowDropDown (rotated 180° when expanded)
const year_cols: usize = 3;
const year_cell_w: f32 = 72;
const year_cell_h: f32 = 36;
const year_vgap: f32 = 16; // YearsVerticalPadding
const year_row_h: f32 = year_cell_h + year_vgap; // 52
const year_menu_icon: f32 = 18;
const year_menu_gap: f32 = 8; // ButtonDefaults.IconSpacing
const year_menu_h: f32 = 40;
const year_menu_pad: f32 = 12;

/// The supported civil-date range (the year range), as UTC epoch days.
pub const min_epoch_day: i64 = daysFromCivil(min_year, 1, 1); // 1900-01-01
pub const max_epoch_day: i64 = daysFromCivil(max_year, 12, 31); // 2100-12-31

/// Clamp an epoch day to the supported civil-date range (1900..2100) — the
/// calendar helpers stay total (no i64 overflow) for any input.
pub fn clampDay(day: i64) i64 {
    return std.math.clamp(day, min_epoch_day, max_epoch_day);
}

/// Derived layout metrics.
fn gridH(t: Theme) f32 {
    return @as(f32, @floatFromInt(grid_rows)) * rowH(t);
}
fn gridYOff(t: Theme) f32 {
    return header_h + nav_h + weekdayRowH(t);
}
fn footerYOff(t: Theme) f32 {
    return gridYOff(t) + gridH(t);
}
fn totalH(t: Theme) f32 {
    return footerYOff(t) + footer_h + footer_pad_bottom;
}
/// The default-theme total height (tests).
const total_h: f32 = totalH(theme_mod.light);

// Month/weekday names route through the active locale (i18n.Locale) — the
// English tables below are the no-i18n fallback only.
const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

fn monthLong(m: i64) []const u8 {
    if (m < 1 or m > 12) return "?";
    if (i18n_mod.current()) |i| {
        if (i.current) |loc| return loc.month_long[@intCast(m - 1)];
    }
    return month_names[@intCast(m - 1)];
}

/// The month name (1-based month index).
pub fn monthName(m: i64) []const u8 {
    return monthLong(m);
}
const month_names_short = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
fn monthShort(m: i64) []const u8 {
    if (m < 1 or m > 12) return "?";
    if (i18n_mod.current()) |i| {
        if (i.current) |loc| return loc.month_short[@intCast(m - 1)];
    }
    return month_names_short[@intCast(m - 1)];
}
const weekday_names_short = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
fn weekdayShort(wd: usize) []const u8 {
    if (wd > 6) return "?";
    if (i18n_mod.current()) |i| {
        if (i.current) |loc| return loc.weekday_short[wd];
    }
    return weekday_names_short[wd];
}
const weekday_letters = [_][:0]const u8{ "S", "M", "T", "W", "T", "F", "S" };
fn weekdayLetter(wd: usize) [:0]const u8 {
    if (wd > 6) return "?";
    if (i18n_mod.current()) |i| {
        if (i.current) |loc| return loc.weekday_letter[wd];
    }
    return weekday_letters[wd];
}

// --- civil calendar (UTC epoch days; Howard Hinnant's algorithms) ---

pub fn isLeap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

pub fn daysInMonth(y: i64, m: i64) i64 {
    const d = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var n = d[@intCast(m - 1)];
    if (m == 2 and isLeap(y)) n = 29;
    return n;
}

/// Days since 1970-01-01 (UTC) for a civil date (proleptic Gregorian).
pub fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    const yy = y - @intFromBool(m <= 2);
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400; // [0, 399]
    const mp = @mod(m + 9, 12); // [0, 11]
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

const Civil = struct { y: i64, m: i64, d: i64 };

/// The civil date (UTC) of an epoch day (clamped to the supported range —
/// an extreme epoch day maps to the range's edge, never an overflow).
pub fn civilFromDays(z0: i64) Civil {
    const z = clampDay(z0) + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp = @divTrunc(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1; // [1, 31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{ .y = y + @intFromBool(m <= 2), .m = m, .d = d };
}

/// The weekday of an epoch day (0 = Sunday). 1970-01-01 was a Thursday.
pub fn weekdayFromDays(z: i64) usize {
    return @intCast(@mod(clampDay(z) + 4, 7));
}

fn firstOfMonth(y: i64, m: i64) i64 {
    return daysFromCivil(y, m, 1);
}

/// The first day of the month `delta` months away (clamped to the year range).
fn shiftMonth(day: i64, delta: i64) i64 {
    const c = civilFromDays(day);
    var y = c.y;
    var m = c.m + delta;
    while (m > 12) {
        m -= 12;
        y += 1;
    }
    while (m < 1) {
        m += 12;
        y -= 1;
    }
    if (y < min_year) return firstOfMonth(min_year, 1);
    if (y > max_year) return firstOfMonth(max_year, 12);
    return firstOfMonth(y, m);
}

/// "EEE, MMM d" (e.g. "Fri, Oct 9") — the header headline (pub: the gallery's
/// selected-day label).
pub fn formatDay(day: i64, buf: []u8) [:0]const u8 {
    const c = civilFromDays(day);
    const wd = weekdayFromDays(day);
    return std.fmt.bufPrintSentinel(buf, "{s}, {s} {d}", .{ weekdayShort(wd), monthShort(c.m), c.d }, 0) catch "?";
}

/// "MMMM yyyy" (e.g. "October 2026") — the month-year nav label.
fn formatMonthYear(day: i64, buf: []u8) [:0]const u8 {
    const c = civilFromDays(day);
    return std.fmt.bufPrintSentinel(buf, "{s} {d}", .{ monthLong(c.m), c.y }, 0) catch "?";
}

/// The system clock's UTC epoch day (opts.today = null).
fn todayFromClock() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        // RtlGetSystemTimePrecise: 100ns ticks since 1601 → unix seconds.
        const ticks: i64 = @intCast(std.os.windows.ntdll.RtlGetSystemTimePrecise());
        return @divFloor(@divFloor(ticks, 10_000_000) - 11644473600, 86400);
    }
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @divFloor(ts.sec, 86400);
}

// --- widget state ---

const Zone = union(enum) {
    none,
    prev,
    next,
    day: i64, // the epoch day
    year_menu, // the month-year TextButton (toggles the year picker)
    year: i64, // a year cell
    cancel,
    ok,
};

const DpState = struct {
    opts: DatePickerOptions,
    /// The duped, null-terminated title (the options string is borrowed).
    title_z: [:0]const u8,
    sel: *ui.state.Signal(?i64),
    disp: *ui.state.Signal(i64),
    on_select: ?ui.state.Callback,
    on_cancel: ?ui.state.Callback,
    today: i64,
    hover: Zone = .none,
    pressed: Zone = .none,
    down_x: f32 = 0,
    down_y: f32 = 0,
    /// The year-picker menu: open replaces the day grid with the scrollable
    /// year list; year_scroll is the grid's pixel offset.
    year_open: bool = false,
    year_scroll: f32 = 0,
    year_dragging: bool = false, // a drag-scroll owns the gesture until .up
    /// The a11y value (the headline, or the owned title when nothing is
    /// selected) — Phase 2c. Points into value_buf or at title_z.
    value_buf: [32]u8 = std.mem.zeroes([32]u8),
    a11y_value: []const u8 = "",
};

fn stateOf(n: *Node) *DpState {
    return @ptrCast(@alignCast(n.state.?));
}

/// The current selection (a UTC epoch day; null = none) — tests + the app.
pub fn selectedDay(n: *Node) ?i64 {
    return stateOf(n).sel.peek();
}

/// The displayed month (the epoch day of its 1st) — tests + the app.
pub fn displayedMonth(n: *Node) i64 {
    return stateOf(n).disp.peek();
}

/// "Today" resolved: the injected option, else the system clock (UTC).
pub fn todayDay(today_opt: ?i64) i64 {
    return today_opt orelse todayFromClock();
}

/// The first day of the month containing `day` (a UTC epoch day).
pub fn firstOfMonthOf(day: i64) i64 {
    const c = civilFromDays(day);
    return firstOfMonth(c.y, c.m);
}

/// The rect of `day`'s cell in the displayed month (null when the day is not
/// in the displayed month) — tests + the app.
pub fn dayCellRect(n: *Node, day: i64) ?Rect {
    const s = stateOf(n);
    const c = civilFromDays(s.disp.peek());
    const dc = civilFromDays(day);
    if (dc.y != c.y or dc.m != c.m) return null;
    const i: usize = @intCast(@as(i64, @intCast(weekdayFromDays(s.disp.peek()))) + dc.d - 1);
    return cellRect(s.opts.theme, n.bounds, i % 7, i / 7);
}

/// The epoch day of the day cell `i` (0..41) of the displayed month, or null
/// when the cell is empty (outside the month).
fn dayAtCell(n: *Node, i: usize) ?i64 {
    const s = stateOf(n);
    const c = civilFromDays(s.disp.peek());
    const first_wd = weekdayFromDays(s.disp.peek());
    const dim = daysInMonth(c.y, c.m);
    if (i < first_wd) return null;
    const day_num: i64 = @intCast(i - first_wd + 1);
    if (day_num > dim) return null;
    return daysFromCivil(c.y, c.m, day_num);
}

fn canPrev(n: *Node) bool {
    return stateOf(n).disp.peek() > firstOfMonth(min_year, 1);
}

fn canNext(n: *Node) bool {
    return stateOf(n).disp.peek() < firstOfMonth(max_year, 12);
}

/// The day cells' geometry: the grid area (inset by h_pad), cells spread
/// evenly (SpaceEvenly: equal gaps around and between the 40dp cells).
fn gridMetrics(b: Rect) struct { x: f32, w: f32, gap: f32 } {
    const w = b.w - 2 * h_pad;
    return .{ .x = b.x + h_pad, .w = w, .gap = (w - 7 * cell) / 8 };
}

fn rtl() bool {
    return i18n_mod.direction() == .rtl;
}

/// Mirror a horizontal span inside the container (RTL): the left edge of
/// an LTR rect at `x` becomes `2·bx + bw − x − w`. Same idiom as app_bar's
/// placeRelative mirroring.
fn mx(b: Rect, x: f32, w: f32) f32 {
    return if (rtl()) 2 * b.x + b.w - x - w else x;
}

fn cellRect(t: Theme, b: Rect, col: usize, row: usize) Rect {
    const g = gridMetrics(b);
    const lx = g.x + g.gap + @as(f32, @floatFromInt(col)) * (cell + g.gap);
    return .{
        .x = mx(b, lx, cell),
        .y = b.y + gridYOff(t) + @as(f32, @floatFromInt(row)) * rowH(t) + (rowH(t) - cell) / 2,
        .w = cell,
        .h = cell,
    };
}

// --- year picker geometry ---

/// The area the year grid occupies: it replaces the weekday row + the day
/// grid (the AnimatedVisibility region, ≈ upstream's 48×7−1 = 335dp).
const year_grid_y_off: f32 = header_h + nav_h;
fn yearGridH(t: Theme) f32 {
    return weekdayRowH(t) + gridH(t);
}

fn yearGridMetrics(t: Theme, b: Rect) struct { x: f32, w: f32, gap: f32, y: f32, h: f32 } {
    const w = b.w - 2 * h_pad;
    return .{
        .x = b.x + h_pad,
        .w = w,
        .gap = (w - @as(f32, year_cols) * year_cell_w) / (@as(f32, year_cols) + 1), // SpaceEvenly
        .y = b.y + year_grid_y_off,
        .h = yearGridH(t),
    };
}

/// The total scrollable height of the year grid (67 rows of 52).
fn yearContentH() f32 {
    const rows = (max_year - min_year + 1 + year_cols - 1) / year_cols;
    return @as(f32, @floatFromInt(rows)) * year_row_h - year_vgap;
}

/// Max scroll offset (content − viewport); the grid is never shorter than
/// the viewport (3468 > 336) but clamp defensively.
fn yearMaxScroll(t: Theme) f32 {
    return @max(0, yearContentH() - yearGridH(t));
}

/// The year at grid cell `i` (row-major, min_year first) — always valid.
fn yearAtCell(i: usize) i64 {
    return min_year + @as(i64, @intCast(i));
}

/// A year cell's rect in window coords (before clipping) given the scroll.
fn yearCellRect(t: Theme, b: Rect, i: usize, scroll: f32) Rect {
    const g = yearGridMetrics(t, b);
    const col: f32 = @floatFromInt(i % year_cols);
    const row: f32 = @floatFromInt(i / year_cols);
    return .{
        .x = mx(b, g.x + g.gap + col * (year_cell_w + g.gap), year_cell_w),
        .y = g.y + row * year_row_h - scroll,
        .w = year_cell_w,
        .h = year_cell_h,
    };
}

/// The month-year menu button's rect (TextButton: label + icon spacing +
/// ArrowDropDown, wrapped in its hit area).
fn yearMenuRect(n: *Node) Rect {
    const s = stateOf(n);
    const b = n.bounds;
    const ls = s.opts.theme.type_scale.label_large;
    var my_buf: [32]u8 = undefined;
    const my = formatMonthYear(s.disp.peek(), &my_buf);
    const my_m = ui.paint.measureText(my, ls.size, ls.weight >= 500);
    const w = 4 + my_m.width + year_menu_gap + year_menu_icon + year_menu_pad;
    return .{
        .x = mx(b, b.x + h_pad - 4, w),
        .y = b.y + header_h + (nav_h - year_menu_h) / 2,
        .w = w,
        .h = year_menu_h,
    };
}

/// Open the year menu with the upstream scroll: the displayed year's row
/// sits one row below the viewport top (initialFirstVisibleItemIndex =
/// displayedYear − first − YearsInRow).
fn openYearMenu(n: *Node) void {
    const s = stateOf(n);
    s.year_open = true;
    const dy = civilFromDays(s.disp.peek()).y;
    const idx: i64 = dy - min_year - @as(i64, @intCast(year_cols));
    const row = @divFloor(@max(0, idx), @as(i64, @intCast(year_cols)));
    s.year_scroll = std.math.clamp(@as(f32, @floatFromInt(row)) * year_row_h, 0, yearMaxScroll(s.opts.theme));
    n.markDirty();
}

fn chevronRects(b: Rect) struct { prev: Rect, next: Rect } {
    const right = b.x + b.w - h_pad;
    const y = b.y + header_h + (nav_h - chevron_hit) / 2;
    // Mirrored under RTL the group anchors to the start edge and reads
    // [next][prev] — the same visual order flip Compose's Row does.
    return .{
        .prev = .{ .x = mx(b, right - 2 * chevron_hit, chevron_hit), .y = y, .w = chevron_hit, .h = chevron_hit },
        .next = .{ .x = mx(b, right - chevron_hit, chevron_hit), .y = y, .w = chevron_hit, .h = chevron_hit },
    };
}

const FooterRects = struct { cancel: Rect, ok: Rect };

fn footerRects(n: *Node) FooterRects {
    const s = stateOf(n);
    const ls = s.opts.theme.type_scale.label_large;
    const bold = ls.weight >= 500;
    const ok_m = ui.paint.measureText("OK", ls.size, bold);
    const cancel_m = ui.paint.measureText("Cancel", ls.size, bold);
    const ok_w = ok_m.width + 2 * footer_pad_x;
    const cancel_w = cancel_m.width + 2 * footer_pad_x;
    const right = n.bounds.x + n.bounds.w - footer_pad_bottom;
    const y = n.bounds.y + footerYOff(s.opts.theme);
    const b = n.bounds;
    // End-aligned like upstream's Arrangement.End — the START edge under
    // RTL, where the mirrored order reads [OK][Cancel].
    return .{
        .cancel = .{ .x = mx(b, right - ok_w - footer_gap - cancel_w, cancel_w), .y = y, .w = cancel_w, .h = footer_h },
        .ok = .{ .x = mx(b, right - ok_w, ok_w), .y = y, .w = ok_w, .h = footer_h },
    };
}

/// The interactive zone at (x, y) — window coordinates.
fn zoneAt(n: *Node, x: f32, y: f32) Zone {
    const s = stateOf(n);
    const b = n.bounds;
    // All chrome mirrors under RTL: rect zones are already mirrored (the
    // helpers produce the painted rects), the grid-fraction math maps the
    // point into the unmirrored (LTR) space once — paint and hit-testing
    // stay in lockstep either way.
    const lx = if (rtl()) 2 * b.x + b.w - x else x;
    const fr = footerRects(n);
    if (fr.cancel.contains(x, y)) return .cancel;
    if (fr.ok.contains(x, y)) return .ok;
    if (yearMenuRect(n).contains(x, y)) return .year_menu;
    if (s.year_open) {
        // the chevrons are hidden while the picker is open (MonthsNavigation
        // collapses to Arrangement.Start); hits resolve against the year grid
        const g = yearGridMetrics(s.opts.theme, b);
        if (x >= g.x and x < g.x + g.w and y >= g.y and y < g.y + g.h) {
            const row_f = (y - g.y + s.year_scroll) / year_row_h;
            const gx = lx - g.x - g.gap;
            const col_f = gx / (year_cell_w + g.gap);
            if (row_f >= 0 and col_f >= 0) {
                const row: usize = @intFromFloat(row_f);
                const col: usize = @intFromFloat(col_f);
                if (col < year_cols) {
                    const in_cell = gx - @as(f32, @floatFromInt(col)) * (year_cell_w + g.gap) <= year_cell_w and
                        (y - g.y + s.year_scroll) - @as(f32, @floatFromInt(row)) * year_row_h <= year_cell_h;
                    if (in_cell) {
                        const i = row * year_cols + col;
                        if (i < max_year - min_year + 1) return .{ .year = yearAtCell(i) };
                    }
                }
            }
        }
        return .none;
    }
    const chev = chevronRects(b);
    if (canPrev(n) and chev.prev.contains(x, y)) return .prev;
    if (canNext(n) and chev.next.contains(x, y)) return .next;
    const g = gridMetrics(b);
    const gy = b.y + gridYOff(s.opts.theme);
    if (y >= gy and y < gy + gridH(s.opts.theme) and x >= g.x and x < g.x + g.w) {
        const gx = lx - g.x - g.gap;
        const ly = y - gy - (rowH(s.opts.theme) - cell) / 2;
        if (gx >= 0 and ly >= 0) {
            const col = @as(usize, @intFromFloat(gx / (cell + g.gap)));
            const row = @as(usize, @intFromFloat(ly / rowH(s.opts.theme)));
            if (col < 7 and row < grid_rows) {
                const in_cell_x = gx - @as(f32, @floatFromInt(col)) * (cell + g.gap) <= cell;
                const in_cell_y = ly - @as(f32, @floatFromInt(row)) * rowH(s.opts.theme) <= cell;
                if (in_cell_x and in_cell_y) {
                    if (dayAtCell(n, row * 7 + col)) |d| return .{ .day = d };
                }
            }
        }
    }
    return .none;
}

// --- measure / layout / paint ---

fn dpMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    return c.constrain(.{ .w = s.opts.width, .h = totalH(s.opts.theme) });
}

fn dpLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: the chrome is computed from the bounds at paint/hit
}

/// Paint an icon centered in a box — vector geometry (icon.zig), not a font
/// glyph (emoji-capable codepoints bypass the theme ink via the emoji font).
fn paintIcon(ctx: *kx.Ctx, name: icon_w.IconName, x: f32, y: f32, size: f32, color: Color) void {
    if (color & 0xFF == 0) return;
    icon_w.drawIcon(ctx, name, x, y, size / 24.0, color);
}

fn paintChevron(n: *Node, ctx: *kx.Ctx, r: Rect, name: icon_w.IconName, zone: Zone, enabled: bool) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const hover = std.meta.eql(s.hover, zone);
    const pressed = std.meta.eql(s.pressed, zone);
    if (hover or pressed) {
        const alpha = if (pressed) t.state.pressed else t.state.hover;
        ui.paint.fillRRect(ctx, r.x, r.y, r.w, r.h, r.w / 2, theme_mod.stateLayer(0, t.colors.on_surface_variant, alpha));
    }
    const base: Color = if (enabled) t.colors.on_surface_variant else ui.paint.withAlphaScaled(t.colors.on_surface_variant, 0.38);
    paintIcon(ctx, name, r.x + (r.w - chevron_icon) / 2, r.y + (r.h - chevron_icon) / 2, chevron_icon, base);
}

fn paintTextButton(n: *Node, ctx: *kx.Ctx, r: Rect, label: [:0]const u8, zone: Zone) void {
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
    const m = ui.paint.measureText(label, ls.size, bold);
    ui.paint.text(ctx, label, r.x + (r.w - m.width) / 2, r.y + (r.h - m.height) / 2 + m.ascent, ls.size, bold, t.colors.primary);
}

fn dpPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const cs = t.colors;
    const b = n.bounds;
    // the container
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, container_corner, cs.surface_container_high);
    // the header: title (top), headline (bottom), divider
    const ls = t.type_scale.label_large;
    const bold = ls.weight >= 500;
    const title_m = ui.paint.measureText(s.title_z, ls.size, bold);
    ui.paint.text(ctx, s.title_z, mx(b, b.x + 24, title_m.width), b.y + title_pad_top + (ls.line_height - title_m.height) / 2 + title_m.ascent, ls.size, bold, cs.on_surface_variant);
    const hl = t.type_scale.headline_large;
    const hl_bold = hl.weight >= 500;
    var hl_buf: [32]u8 = undefined;
    const headline: [:0]const u8 = if (s.sel.peek()) |d| formatDay(d, &hl_buf) else s.title_z;
    const hl_m = ui.paint.measureText(headline, hl.size, hl_bold);
    const hl_box_y = b.y + header_h - headline_pad_bottom - hl.line_height;
    ui.paint.text(ctx, headline, mx(b, b.x + 24, hl_m.width), hl_box_y + (hl.line_height - hl_m.height) / 2 + hl_m.ascent, hl.size, hl_bold, cs.on_surface_variant);
    ui.paint.fillRect(ctx, b.x, b.y + header_h - 1, b.w, 1, cs.outline_variant);
    // the month/year nav row: the menu button (TextButton + ArrowDropDown,
    // rotated 180° while the year picker is open) + the chevrons (hidden
    // while open — MonthsNavigation collapses to Arrangement.Start)
    var my_buf: [32]u8 = undefined;
    const my = formatMonthYear(s.disp.peek(), &my_buf);
    const my_m = ui.paint.measureText(my, ls.size, bold);
    const nav_cy = b.y + header_h + nav_h / 2;
    const yr = yearMenuRect(n);
    if (std.meta.eql(s.hover, .year_menu) or std.meta.eql(s.pressed, .year_menu)) {
        const alpha = if (std.meta.eql(s.pressed, .year_menu)) t.state.pressed else t.state.hover;
        ui.paint.fillRRect(ctx, yr.x, yr.y, yr.w, yr.h, yr.h / 2, theme_mod.stateLayer(0, cs.on_surface_variant, alpha));
    }
    ui.paint.text(ctx, my, mx(b, b.x + h_pad, my_m.width), nav_cy - my_m.height / 2 + my_m.ascent, ls.size, bold, cs.on_surface_variant);
    paintIcon(ctx, if (s.year_open) .triangle_up else .triangle_down, mx(b, b.x + h_pad + my_m.width + year_menu_gap, year_menu_icon), nav_cy - year_menu_icon / 2, year_menu_icon, cs.on_surface_variant);
    if (!s.year_open) {
        const chev = chevronRects(b);
        paintChevron(n, ctx, chev.prev, .chevron_left, .prev, canPrev(n));
        paintChevron(n, ctx, chev.next, .chevron_right, .next, canNext(n));
    }
    const bl = t.type_scale.body_large;
    const bl_bold = bl.weight >= 500;
    if (s.year_open) {
        paintYearGrid(n, ctx, b, bl.size, bl_bold);
        paintFooter(n, ctx);
        return;
    }
    // the weekday row (RTL mirrors the columns: the week still runs
    // Sunday→Saturday but reads right-to-left)
    const g = gridMetrics(b);
    const weekday_y = b.y + header_h + nav_h;
    for (0..7) |col| {
        const cx = g.x + g.gap + @as(f32, @floatFromInt(col)) * (cell + g.gap) + cell / 2;
        const wl = weekdayLetter(if (rtl()) 6 - col else col);
        const lm = ui.paint.measureText(wl, bl.size, bl_bold);
        ui.paint.text(ctx, wl, cx - lm.width / 2, weekday_y + (weekdayRowH(t) - lm.height) / 2 + lm.ascent, bl.size, bl_bold, cs.on_surface);
    }
    // the day grid
    const sel = s.sel.peek();
    for (0..42) |i| {
        const day = dayAtCell(n, i) orelse continue;
        const cr = cellRect(t, b, i % 7, i / 7);
        const is_sel = sel != null and sel.? == day;
        const is_today = day == s.today;
        const is_hover = std.meta.eql(s.hover, Zone{ .day = day });
        const is_pressed = std.meta.eql(s.pressed, Zone{ .day = day });
        if (is_sel) {
            ui.paint.fillRRect(ctx, cr.x, cr.y, cr.w, cr.h, cell / 2, cs.primary);
        } else {
            if (is_today) ui.paint.strokeRRect(ctx, cr.x, cr.y, cr.w, cr.h, cell / 2, 1, cs.primary);
            if (is_hover or is_pressed) {
                const alpha = if (is_pressed) t.state.pressed else t.state.hover;
                ui.paint.fillRRect(ctx, cr.x, cr.y, cr.w, cr.h, cell / 2, theme_mod.stateLayer(0, cs.on_surface, alpha));
            }
        }
        var dbuf: [4]u8 = undefined;
        const dstr = std.fmt.bufPrintSentinel(&dbuf, "{d}", .{civilFromDays(day).d}, 0) catch return;
        const dm = ui.paint.measureText(dstr, bl.size, bl_bold);
        const fg: Color = if (is_sel) cs.on_primary else if (is_today) cs.primary else cs.on_surface;
        ui.paint.text(ctx, dstr, cr.x + (cell - dm.width) / 2, cr.y + (cell - dm.height) / 2 + dm.ascent, bl.size, bl_bold, fg);
    }
    // the footer
    paintFooter(n, ctx);
}

fn paintFooter(n: *Node, ctx: *kx.Ctx) void {
    const fr = footerRects(n);
    paintTextButton(n, ctx, fr.cancel, "Cancel", .cancel);
    paintTextButton(n, ctx, fr.ok, "OK", .ok);
}

/// The year picker grid (DatePicker.kt YearPicker): a clipped, scrollable
/// LazyVerticalGrid — 3 columns, 72×36 CornerFull cells, 16dp row gap.
/// Selected year = the displayed month's year (Primary + OnPrimary);
/// the current year carries the 1dp Primary outline + Primary label;
/// the rest are OnSurfaceVariant BodyLarge.
fn paintYearGrid(n: *Node, ctx: *kx.Ctx, b: Rect, size: f32, bold: bool) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const cs = t.colors;
    const g = yearGridMetrics(t, b);
    const disp_year = civilFromDays(s.disp.peek()).y;
    const cur_year = civilFromDays(s.today).y;
    ui.paint.save(ctx);
    ui.paint.clipRect(ctx, g.x, g.y, g.w, g.h);
    const first: usize = @intFromFloat(@max(0, s.year_scroll / year_row_h));
    const last: usize = @min(@as(usize, @intCast(max_year - min_year + 1)), (first + 8) * year_cols + year_cols);
    var i = first * year_cols;
    while (i < last) : (i += 1) {
        const y = yearAtCell(i);
        const cr = yearCellRect(t, b, i, s.year_scroll);
        if (cr.y > g.y + g.h or cr.y + cr.h < g.y) continue;
        const is_sel = y == disp_year;
        const is_cur = y == cur_year;
        const is_hover = std.meta.eql(s.hover, Zone{ .year = y });
        const is_pressed = std.meta.eql(s.pressed, Zone{ .year = y });
        if (is_sel) {
            ui.paint.fillRRect(ctx, cr.x, cr.y, cr.w, cr.h, cr.h / 2, cs.primary);
        } else {
            if (is_cur) ui.paint.strokeRRect(ctx, cr.x, cr.y, cr.w, cr.h, cr.h / 2, 1, cs.primary);
            if (is_hover or is_pressed) {
                const alpha = if (is_pressed) t.state.pressed else t.state.hover;
                ui.paint.fillRRect(ctx, cr.x, cr.y, cr.w, cr.h, cr.h / 2, theme_mod.stateLayer(0, cs.on_surface_variant, alpha));
            }
        }
        var ybuf: [8]u8 = undefined;
        const ystr = std.fmt.bufPrintSentinel(&ybuf, "{d}", .{y}, 0) catch break;
        const ym = ui.paint.measureText(ystr, size, bold);
        const fg: Color = if (is_sel) cs.on_primary else if (is_cur) cs.primary else cs.on_surface_variant;
        ui.paint.text(ctx, ystr, cr.x + (cr.w - ym.width) / 2, cr.y + (cr.h - ym.height) / 2 + ym.ascent, size, bold, fg);
    }
    ui.paint.clipReset(ctx);
    ui.paint.restore(ctx);
}

// --- input ---

fn dpOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    switch (ev.phase) {
        .down => {
            const z = zoneAt(n, ev.x, ev.y);
            if (std.meta.activeTag(z) == .none) return false;
            s.pressed = z;
            s.down_x = ev.raw_x;
            s.down_y = ev.raw_y;
            n.markDirty();
            return true;
        },
        .up => {
            const was = s.pressed;
            s.pressed = .none;
            const was_dragging = s.year_dragging;
            s.year_dragging = false;
            n.markDirty();
            if (was_dragging) return true; // the scroll consumed the gesture
            if (std.meta.activeTag(was) == .none) return false;
            if (!std.meta.eql(zoneAt(n, ev.x, ev.y), was)) return true; // released outside: no action
            activate(n, s, was);
            return true;
        },
        .move => {
            // a drag in the open year grid scrolls it (LazyVerticalGrid)
            if (s.year_dragging) {
                s.year_scroll = std.math.clamp(s.year_scroll - (ev.raw_y - s.down_y), 0, yearMaxScroll(s.opts.theme));
                s.down_y = ev.raw_y;
                s.hover = zoneAt(n, ev.x, ev.y);
                n.markDirty();
                return true;
            }
            // A drag beyond the touch slop cancels the press (button.zig's
            // pattern); the move is NOT claimed (it keeps bubbling).
            if (std.meta.activeTag(s.pressed) != .none) {
                const dx = ev.raw_x - s.down_x;
                const dy = ev.raw_y - s.down_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    if (s.year_open and std.meta.activeTag(s.pressed) == .year and @abs(dy) > @abs(dx)) {
                        // a vertical drag off a year cell scrolls the grid
                        s.year_dragging = true;
                        s.down_y = ev.raw_y;
                    }
                    s.pressed = .none;
                    n.markDirty();
                }
            }
            return false;
        },
        .outside_down => {
            s.year_dragging = false;
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

fn activate(n: *Node, s: *DpState, z: Zone) void {
    switch (z) {
        .none => {},
        .prev => s.disp.set(shiftMonth(s.disp.peek(), -1)),
        .next => s.disp.set(shiftMonth(s.disp.peek(), 1)),
        .day => |d| s.sel.set(d),
        .year_menu => {
            if (s.year_open) {
                s.year_open = false;
                n.markDirty();
            } else {
                openYearMenu(n);
            }
        },
        .year => |y| {
            // upstream: selecting a year closes the picker and pages the
            // displayed month to that year's same month
            const c = civilFromDays(s.disp.peek());
            s.year_open = false;
            s.disp.set(firstOfMonth(y, c.m));
        },
        .cancel => {
            if (s.on_cancel) |cb| cb.fn_ptr(cb.userdata);
        },
        .ok => {
            if (s.on_select) |cb| cb.fn_ptr(cb.userdata);
        },
    }
}

/// Mouse wheel / touchpad scroll over the open year grid (LazyVerticalGrid).
fn dpOnScroll(n: *Node, ev: input.ScrollEvent) bool {
    const s = stateOf(n);
    if (!s.year_open) return false;
    const g = yearGridMetrics(s.opts.theme, n.bounds);
    if (!(ev.x >= g.x and ev.x < g.x + g.w and ev.y >= g.y and ev.y < g.y + g.h)) return false;
    // delta_y negative = scroll down (the scroll_view wheel convention,
    // 48px per click)
    s.year_scroll = std.math.clamp(s.year_scroll - ev.delta_y * 48, 0, yearMaxScroll(s.opts.theme));
    s.hover = zoneAt(n, ev.x, ev.y);
    n.markDirty();
    return true;
}

// --- signals + a11y ---

/// The selection changed (the app or a day tap): repaint + the a11y value.
fn dpSelSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    updateA11yValue(n);
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the value changed
}

/// The displayed month changed: repaint (the grid + the nav label).
fn dpDispSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    n.markDirty();
}

fn updateA11yValue(n: *Node) void {
    const s = stateOf(n);
    if (s.sel.peek()) |d| {
        const str = formatDay(d, &s.value_buf);
        s.a11y_value = s.value_buf[0..str.len];
    } else {
        // The unselected value is the owned title — point at it directly (a
        // long title would not fit the fixed buffer, and the options string
        // is borrowed: never read it here).
        s.a11y_value = s.title_z;
    }
    if (n.semantics) |sem| sem.value = s.a11y_value;
}

fn dpDeinit(n: *Node) void {
    const s = stateOf(n);
    s.sel.unsubscribe(.{ .callback = .{ .fn_ptr = dpSelSyncCb, .userdata = n } });
    s.disp.unsubscribe(.{ .callback = .{ .fn_ptr = dpDispSyncCb, .userdata = n } });
    n.allocator.free(s.title_z);
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const dp_vtable = ui.node.VTable{
    .measure = dpMeasure,
    .layout = dpLayout,
    .paint = dpPaint,
    .deinit = dpDeinit,
    .on_pointer = dpOnPointer,
    .on_scroll = dpOnScroll,
};

fn dupeZ(allocator: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    const buf = try allocator.alloc(u8, s.len + 1);
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// An M3E date picker panel (single date, calendar mode). `selected` is a
/// two-way Signal(?i64) of UTC epoch days (null = no selection); `displayed`
/// is a two-way Signal(i64) of the displayed month (the epoch day of its
/// 1st). `on_select` fires on OK, `on_cancel` on Cancel. The widget is a LEAF
/// panel (it paints all its chrome; the app wraps it in a dialog for modal
/// behavior).
pub fn datePicker(allocator: std.mem.Allocator, selected: *ui.state.Signal(?i64), displayed: *ui.state.Signal(i64), on_select: ?ui.state.Callback, on_cancel: ?ui.state.Callback, opts: DatePickerOptions) !*Node {
    const node = try Node.create(allocator, &dp_vtable);
    errdefer node.allocator.destroy(node); // no state yet
    const s = try allocator.create(DpState);
    errdefer allocator.destroy(s);
    const title = try dupeZ(allocator, opts.title);
    errdefer allocator.free(title);
    s.* = .{
        .opts = opts,
        .title_z = title,
        .sel = selected,
        .disp = displayed,
        .on_select = on_select,
        .on_cancel = on_cancel,
        .today = clampDay(opts.today orelse todayFromClock()),
    };
    node.state = s;
    updateA11yValue(node);
    ui.semantics.attach(node, .{ .role = .group, .label = "Date picker", .value = s.a11y_value }); // Phase 2c
    selected.subscribe(.{ .callback = .{ .fn_ptr = dpSelSyncCb, .userdata = node } });
    displayed.subscribe(.{ .callback = .{ .fn_ptr = dpDispSyncCb, .userdata = node } });
    return node;
}

// --- tests ---

/// A picker for October 2026 (today = 2026-10-08, selected = 2026-10-09).
fn dpFixture(a: std.mem.Allocator) !struct { *Node, *ui.state.Signal(?i64), *ui.state.Signal(i64) } {
    const sel = try ui.state.Signal(?i64).init(a, daysFromCivil(2026, 10, 9));
    errdefer sel.deinit();
    const disp = try ui.state.Signal(i64).init(a, daysFromCivil(2026, 10, 1));
    errdefer disp.deinit();
    const n = try datePicker(a, sel, disp, null, null, .{ .today = daysFromCivil(2026, 10, 8) });
    errdefer n.deinit();
    return .{ n, sel, disp };
}

test "date_picker: the civil calendar round-trips (epoch days, weekdays, leap years)" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 1), daysFromCivil(1970, 1, 2));
    try std.testing.expectEqual(@as(i64, 10957), daysFromCivil(2000, 1, 1));
    try std.testing.expectEqual(@as(i64, 946684800 / 86400), daysFromCivil(2000, 1, 1)); // 2000-01-01 00:00 UTC = 946684800s
    const c = civilFromDays(daysFromCivil(2026, 10, 9));
    try std.testing.expectEqual(@as(i64, 2026), c.y);
    try std.testing.expectEqual(@as(i64, 10), c.m);
    try std.testing.expectEqual(@as(i64, 9), c.d);
    // 1970-01-01 was a Thursday (4); 2026-10-09 is a Friday (5)
    try std.testing.expectEqual(@as(usize, 4), weekdayFromDays(0));
    try std.testing.expectEqual(@as(usize, 5), weekdayFromDays(daysFromCivil(2026, 10, 9)));
    // leap years
    try std.testing.expectEqual(@as(i64, 29), daysInMonth(2000, 2));
    try std.testing.expectEqual(@as(i64, 28), daysInMonth(1900, 2));
    try std.testing.expectEqual(@as(i64, 29), daysInMonth(2024, 2));
    try std.testing.expectEqual(@as(i64, 31), daysInMonth(2026, 10));
    // a negative epoch day round-trips (pre-1970)
    const cn = civilFromDays(daysFromCivil(1969, 12, 31));
    try std.testing.expectEqual(@as(i64, 1969), cn.y);
    try std.testing.expectEqual(@as(i64, 12), cn.m);
    try std.testing.expectEqual(@as(i64, 31), cn.d);
}

test "date_picker: extreme epoch days never overflow (clamped to 1900..2100)" {
    try std.testing.expectEqual(@as(i64, -25567), min_epoch_day); // 1900-01-01
    try std.testing.expectEqual(@as(i64, 47846), max_epoch_day); // 2100-12-31
    try std.testing.expectEqual(@as(i64, 47846), clampDay(std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(i64, -25567), clampDay(std.math.minInt(i64)));
    // the helpers stay total at the i64 endpoints
    const c = civilFromDays(std.math.maxInt(i64));
    try std.testing.expectEqual(@as(i64, 2100), c.y);
    try std.testing.expectEqual(@as(i64, 12), c.m);
    try std.testing.expectEqual(@as(i64, 31), c.d);
    try std.testing.expectEqual(@as(usize, 5), weekdayFromDays(std.math.maxInt(i64))); // 2100-12-31 = Friday
    var buf: [32]u8 = undefined;
    _ = formatDay(std.math.maxInt(i64), &buf); // no trap
    try std.testing.expectEqual(@as(i64, -25567), firstOfMonthOf(std.math.minInt(i64)));
}

test "date_picker: a long title is the unselected a11y value (no buffer overflow, no dangling read)" {
    const a = std.testing.allocator;
    const sel = try ui.state.Signal(?i64).init(a, null);
    defer sel.deinit();
    const disp = try ui.state.Signal(i64).init(a, daysFromCivil(2026, 10, 1));
    defer disp.deinit();
    const long_title = "A very long date picker title that overflows the value buffer";
    const n = try datePicker(a, sel, disp, null, null, .{ .title = long_title, .today = daysFromCivil(2026, 10, 8) });
    defer n.deinit();
    // constructs with a null selection: the a11y value is the owned title
    try std.testing.expectEqualStrings(long_title, n.semantics.?.value);
    // selecting a day switches the value to the headline; clearing it restores
    // the owned title (never the borrowed options string)
    sel.set(daysFromCivil(2026, 10, 20));
    try std.testing.expectEqualStrings("Tue, Oct 20", n.semantics.?.value);
    sel.set(null);
    try std.testing.expectEqualStrings(long_title, n.semantics.?.value);
}

test "date_picker: measures the 360x564 M3E panel" {
    const a = std.testing.allocator;
    const f = try dpFixture(a);
    defer f[1].deinit(); // LIFO: the node deinits first (it unsubscribes)
    defer f[2].deinit();
    defer f[0].deinit();
    const m = f[0].measure(.{ .max_w = 1000, .max_h = 1000 });
    try std.testing.expectEqual(@as(f32, 360), m.w);
    try std.testing.expectEqual(total_h, m.h);
}

test "date_picker: the grid lays out the displayed month (empty cells outside it)" {
    const a = std.testing.allocator;
    const f = try dpFixture(a);
    defer f[1].deinit(); // LIFO: the node deinits first (it unsubscribes)
    defer f[2].deinit();
    defer f[0].deinit();
    const n = f[0];
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    // October 2026 starts on a Thursday (4): 4 empty cells, then 31 days
    try std.testing.expectEqual(@as(?i64, null), dayAtCell(n, 0));
    try std.testing.expectEqual(@as(?i64, null), dayAtCell(n, 3));
    try std.testing.expectEqual(daysFromCivil(2026, 10, 1), dayAtCell(n, 4).?);
    try std.testing.expectEqual(daysFromCivil(2026, 10, 31), dayAtCell(n, 34).?);
    try std.testing.expectEqual(@as(?i64, null), dayAtCell(n, 35)); // 42 cells: 4 + 31 + 7
    // the cell geometry: col 5, row 1 = Oct 9 (i = 12)
    const cr = cellRect(theme_mod.light, n.bounds, 5, 1);
    try std.testing.expectEqual(@as(f32, 19 + 5 * 47), cr.x);
    try std.testing.expectEqual(@as(f32, 224 + 48 + 4), cr.y);
}

test "date_picker: tapping a day selects it (the signal round-trips); OK/Cancel fire" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const f = try dpFixture(a);
    defer f[1].deinit(); // LIFO: the node deinits first (it unsubscribes)
    defer f[2].deinit();
    defer f[0].deinit();
    const n = f[0];
    var ok_fired: u32 = 0;
    var cancel_fired: u32 = 0;
    const s = stateOf(n);
    s.on_select = .{ .fn_ptr = countCb, .userdata = &ok_fired };
    s.on_cancel = .{ .fn_ptr = countCb, .userdata = &cancel_fired };
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    // tap Oct 20 (i = 4 + 19 = 23 → col 2, row 3): the cell's center
    const cr = cellRect(theme_mod.light, n.bounds, 2, 3);
    const cx = cr.x + cr.w / 2;
    const cy = cr.y + cr.h / 2;
    router.dispatchPointer(n, .{ .phase = .down, .x = cx, .y = cy, .raw_x = cx, .raw_y = cy });
    router.dispatchPointer(n, .{ .phase = .up, .x = cx, .y = cy, .raw_x = cx, .raw_y = cy });
    try std.testing.expectEqual(daysFromCivil(2026, 10, 20), selectedDay(n).?);
    try std.testing.expectEqual(daysFromCivil(2026, 10, 20), f[1].peek().?); // round-trips
    try std.testing.expectEqual(@as(u32, 0), ok_fired); // OK not tapped yet
    // the a11y value follows the selection
    try std.testing.expectEqualStrings("Tue, Oct 20", n.semantics.?.value);
    // the footer: Cancel then OK
    const fr = footerRects(n);
    router.dispatchPointer(n, .{ .phase = .down, .x = fr.cancel.x + 5, .y = fr.cancel.y + 5, .raw_x = fr.cancel.x + 5, .raw_y = fr.cancel.y + 5 });
    router.dispatchPointer(n, .{ .phase = .up, .x = fr.cancel.x + 5, .y = fr.cancel.y + 5, .raw_x = fr.cancel.x + 5, .raw_y = fr.cancel.y + 5 });
    try std.testing.expectEqual(@as(u32, 1), cancel_fired);
    router.dispatchPointer(n, .{ .phase = .down, .x = fr.ok.x + 5, .y = fr.ok.y + 5, .raw_x = fr.ok.x + 5, .raw_y = fr.ok.y + 5 });
    router.dispatchPointer(n, .{ .phase = .up, .x = fr.ok.x + 5, .y = fr.ok.y + 5, .raw_x = fr.ok.x + 5, .raw_y = fr.ok.y + 5 });
    try std.testing.expectEqual(@as(u32, 1), ok_fired);
    // a release outside the pressed zone does not fire
    router.dispatchPointer(n, .{ .phase = .down, .x = fr.ok.x + 5, .y = fr.ok.y + 5, .raw_x = fr.ok.x + 5, .raw_y = fr.ok.y + 5 });
    router.dispatchPointer(n, .{ .phase = .up, .x = 5, .y = 5, .raw_x = 5, .raw_y = 5 });
    try std.testing.expectEqual(@as(u32, 1), ok_fired);
}

fn countCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "date_picker: the chevrons page the displayed month (clamped + disabled at the edges)" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const f = try dpFixture(a);
    defer f[1].deinit(); // LIFO: the node deinits first (it unsubscribes)
    defer f[2].deinit();
    defer f[0].deinit();
    const n = f[0];
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    try std.testing.expectEqual(daysFromCivil(2026, 10, 1), displayedMonth(n));
    const chev = chevronRects(n.bounds);
    const tap = struct {
        fn go(r: *input.InputRouter, node: *Node, rct: Rect) void {
            const cx = rct.x + rct.w / 2;
            const cy = rct.y + rct.h / 2;
            r.dispatchPointer(node, .{ .phase = .down, .x = cx, .y = cy, .raw_x = cx, .raw_y = cy });
            r.dispatchPointer(node, .{ .phase = .up, .x = cx, .y = cy, .raw_x = cx, .raw_y = cy });
        }
    }.go;
    // next → November 2026
    tap(&router, n, chev.next);
    try std.testing.expectEqual(daysFromCivil(2026, 11, 1), displayedMonth(n));
    try std.testing.expectEqual(daysFromCivil(2026, 11, 1), f[2].peek()); // round-trips
    // prev → back to October
    tap(&router, n, chev.prev);
    try std.testing.expectEqual(daysFromCivil(2026, 10, 1), displayedMonth(n));
    // at the range's first month the prev chevron is disabled (no zone, no paging)
    f[2].set(firstOfMonth(min_year, 1));
    try std.testing.expect(!canPrev(n));
    try std.testing.expect(canNext(n));
    try std.testing.expect(std.meta.activeTag(zoneAt(n, chev.prev.x + chev.prev.w / 2, chev.prev.y + chev.prev.h / 2)) == .none);
    tap(&router, n, chev.prev);
    try std.testing.expectEqual(firstOfMonth(min_year, 1), displayedMonth(n)); // unchanged
    // at the range's last month the next chevron is disabled
    f[2].set(firstOfMonth(max_year, 12));
    try std.testing.expect(!canNext(n));
    try std.testing.expect(canPrev(n));
    tap(&router, n, chev.next);
    try std.testing.expectEqual(firstOfMonth(max_year, 12), displayedMonth(n)); // unchanged
}

test "date_picker: the app drives the selection + the displayed month (two-way signals)" {
    const a = std.testing.allocator;
    const f = try dpFixture(a);
    defer f[1].deinit(); // LIFO: the node deinits first (it unsubscribes)
    defer f[2].deinit();
    defer f[0].deinit();
    const n = f[0];
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    f[1].set(null);
    try std.testing.expectEqual(@as(?i64, null), selectedDay(n));
    try std.testing.expectEqualStrings("Select date", n.semantics.?.value); // the headline falls back to the title
    f[1].set(daysFromCivil(2027, 1, 15));
    try std.testing.expectEqual(daysFromCivil(2027, 1, 15), selectedDay(n).?);
    try std.testing.expectEqualStrings("Fri, Jan 15", n.semantics.?.value);
    f[2].set(daysFromCivil(2027, 1, 1));
    try std.testing.expectEqual(daysFromCivil(2027, 1, 1), displayedMonth(n));
    // January 2027 starts on a Friday (5)
    try std.testing.expectEqual(@as(?i64, null), dayAtCell(n, 4));
    try std.testing.expectEqual(daysFromCivil(2027, 1, 1), dayAtCell(n, 5).?);
}

test "date_picker: the month-year button opens the year picker; a year tap pages and closes it" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const f = try dpFixture(a);
    defer f[1].deinit(); // LIFO: the node deinits first (it unsubscribes)
    defer f[2].deinit();
    defer f[0].deinit();
    const n = f[0];
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    const s = stateOf(n);
    try std.testing.expect(!s.year_open);
    // tap the menu button → the picker opens, scrolled so the displayed year
    // (2026) sits one row below the top (upstream initialFirstVisibleItemIndex)
    const yr = yearMenuRect(n);
    const tapAt = struct {
        fn go(r: *input.InputRouter, node: *Node, x: f32, y: f32) void {
            r.dispatchPointer(node, .{ .phase = .down, .x = x, .y = y, .raw_x = x, .raw_y = y });
            r.dispatchPointer(node, .{ .phase = .up, .x = x, .y = y, .raw_x = x, .raw_y = y });
        }
    }.go;
    tapAt(&router, n, yr.x + 8, yr.y + yr.h / 2);
    try std.testing.expect(s.year_open);
    // the 2026 cell (item 126 → row 42) is in view, one row below the top
    const idx26: usize = @intCast(2026 - min_year);
    const r2026 = yearCellRect(theme_mod.light, n.bounds, idx26, s.year_scroll);
    const g = yearGridMetrics(theme_mod.light, n.bounds);
    try std.testing.expect(r2026.y >= g.y and r2026.y < g.y + 2 * year_row_h);
    // the chevrons are not hit zones while open
    const chev = chevronRects(n.bounds);
    try std.testing.expect(std.meta.activeTag(zoneAt(n, chev.next.x + 2, chev.next.y + 2)) != .next);
    // tap the 2030 cell → closes and pages to October 2030
    const idx30: usize = @intCast(2030 - min_year);
    const r2030 = yearCellRect(theme_mod.light, n.bounds, idx30, s.year_scroll);
    try std.testing.expect(std.meta.eql(zoneAt(n, r2030.x + 4, r2030.y + 4), Zone{ .year = 2030 }));
    tapAt(&router, n, r2030.x + 4, r2030.y + 4);
    try std.testing.expect(!s.year_open);
    try std.testing.expectEqual(daysFromCivil(2030, 10, 1), displayedMonth(n));
    // reopen + close via the same button (the toggle)
    tapAt(&router, n, yr.x + 8, yr.y + yr.h / 2);
    try std.testing.expect(s.year_open);
    tapAt(&router, n, yr.x + 8, yr.y + yr.h / 2);
    try std.testing.expect(!s.year_open);
}

test "date_picker: the year grid scrolls on the wheel and on a vertical drag" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const f = try dpFixture(a);
    defer f[1].deinit(); // LIFO: the node deinits first (it unsubscribes)
    defer f[2].deinit();
    defer f[0].deinit();
    const n = f[0];
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    const s = stateOf(n);
    openYearMenu(n);
    const g = yearGridMetrics(theme_mod.light, n.bounds);
    const gy = g.y + 20;
    const s0 = s.year_scroll;
    // wheel down over the grid scrolls deeper (delta_y negative = down)
    router.dispatchScroll(n, .{ .x = g.x + 20, .y = gy, .delta_y = -2 });
    try std.testing.expectEqual(s0 + 96, s.year_scroll);
    // wheel outside the grid area is not claimed
    try std.testing.expect(!dpOnScroll(n, .{ .x = 10, .y = n.bounds.y + 10, .delta_y = -1 }));
    // a vertical drag off a year cell scrolls; a tap still selects
    const idx30: usize = @intCast(2030 - min_year);
    const r2030 = yearCellRect(theme_mod.light, n.bounds, idx30, s.year_scroll);
    router.dispatchPointer(n, .{ .phase = .down, .x = r2030.x + 4, .y = r2030.y + 4, .raw_x = r2030.x + 4, .raw_y = r2030.y + 4 });
    router.dispatchPointer(n, .{ .phase = .move, .x = r2030.x + 4, .y = r2030.y - 60, .raw_x = r2030.x + 4, .raw_y = r2030.y - 60 }); // drag up 60+ → scrolling
    try std.testing.expect(s.year_dragging);
    const s1 = s.year_scroll;
    router.dispatchPointer(n, .{ .phase = .move, .x = r2030.x + 4, .y = r2030.y - 120, .raw_x = r2030.x + 4, .raw_y = r2030.y - 120 });
    try std.testing.expect(s.year_scroll > s1);
    router.dispatchPointer(n, .{ .phase = .up, .x = r2030.x + 4, .y = r2030.y - 120, .raw_x = r2030.x + 4, .raw_y = r2030.y - 120 });
    try std.testing.expect(s.year_open); // the drag didn't select/close
}

test "golden: the M3E date picker panel (container, header, grid, selected + today, footer)" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const f = try dpFixture(a);
    defer f[1].deinit(); // LIFO: the node deinits first (it unsubscribes)
    defer f[2].deinit();
    defer f[0].deinit();
    const n = f[0];
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    var r = try golden.Renderer.init(a, 360, 564);
    defer r.deinit();
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(a);
    defer f2.deinit();
    // the container (SurfaceContainerHigh), inside the top edge
    try std.testing.expectEqual(t.colors.surface_container_high, f2.pixelAt(180, 5));
    // the header divider (OutlineVariant) at y = 119
    try std.testing.expectEqual(t.colors.outline_variant, f2.pixelAt(180, 119));
    // the header has text ink (the title + the headline)
    try std.testing.expect(f2.countNotIn(.{ .x = 24, .y = 16, .w = 200, .h = 20 }, t.colors.surface_container_high) > 0);
    try std.testing.expect(f2.countNotIn(.{ .x = 24, .y = 68, .w = 250, .h = 40 }, t.colors.surface_container_high) > 0);
    // the month-year nav label has ink
    try std.testing.expect(f2.countNotIn(.{ .x = 12, .y = 120, .w = 200, .h = 56 }, t.colors.surface_container_high) > 0);
    // the selected day (Oct 9: col 5, row 1): a solid Primary circle at its center
    const sel_cell = cellRect(theme_mod.light, n.bounds, 5, 1);
    // inside the circle (r = 17 < 20), away from the centered day label's ink
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(@intFromFloat(sel_cell.x + 8), @intFromFloat(sel_cell.y + 8)));
    // the today (Oct 8: col 4, row 1) is NOT selected: Primary ink (the outline
    // + the label), unlike a plain unselected day (Oct 7: col 3, row 1)
    const today_cell = cellRect(theme_mod.light, n.bounds, 4, 1);
    const plain_cell = cellRect(theme_mod.light, n.bounds, 3, 1);
    try std.testing.expect(f2.countColorApproxIn(today_cell, t.colors.primary) > 0);
    try std.testing.expectEqual(@as(usize, 0), f2.countColorApproxIn(plain_cell, t.colors.primary));
    // the footer: the OK label (Primary ink) in its button rect
    const fr = footerRects(n);
    try std.testing.expect(f2.countColorApproxIn(fr.ok, t.colors.primary) > 0);
    try std.testing.expect(f2.countColorApproxIn(fr.cancel, t.colors.primary) > 0);
}

test "golden: the open year picker paints the year grid (selected/current/plain years)" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const f = try dpFixture(a);
    defer f[1].deinit();
    defer f[2].deinit();
    defer f[0].deinit();
    const n = f[0];
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    const s = stateOf(n);
    openYearMenu(n);
    var r = try golden.Renderer.init(a, 360, 564);
    defer r.deinit();
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(a);
    defer f2.deinit();
    // the displayed year (2026) is a solid Primary cell
    const idx26: usize = @intCast(2026 - min_year);
    const r2026 = yearCellRect(theme_mod.light, n.bounds, idx26, s.year_scroll);
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(@intFromFloat(r2026.x + 8), @intFromFloat(r2026.y + 8)));
    // the current year (2026 IS today here — use a different fixture year:
    // today = 2026 → the current year IS the selected year; check a plain
    // year instead: 2027 unselected = container, no Primary)
    const idx27: usize = @intCast(2027 - min_year);
    const r2027 = yearCellRect(theme_mod.light, n.bounds, idx27, s.year_scroll);
    try std.testing.expectEqual(@as(usize, 0), f2.countColorApproxIn(.{ .x = r2027.x + 2, .y = r2027.y + 2, .w = r2027.w - 4, .h = r2027.h - 4 }, t.colors.primary));
    // the year label has OnSurfaceVariant ink
    try std.testing.expect(f2.countNotIn(.{ .x = r2027.x, .y = r2027.y, .w = r2027.w, .h = r2027.h }, t.colors.surface_container_high) > 0);
    // the dropdown icon (rotated up while open) sits after the label
    const yr = yearMenuRect(n);
    try std.testing.expect(f2.countNotIn(.{ .x = yr.x + yr.w - year_menu_icon - year_menu_pad, .y = yr.y + 8, .w = year_menu_icon + 8, .h = yr.h - 16 }, t.colors.surface_container_high) > 0);
}
