// M3E Table (Phase 4d P2) — a data table: header row + data rows.
//
// Spec: docs/specs/m3e-specs-4d-p2-table.md
//
// Tokens:
//   - container: Surface, header: SurfaceContainerHighest (56dp)
//   - header text: TitleSmall / OnSurface, cell text: BodyMedium / OnSurface
//   - row separator: 1dp OutlineVariant, row height: 52dp
//   - cell padding: 16dp horizontal, 12dp vertical
//   - column min width: 80dp
//   - hover state (tappable): OnSurface @ 0.08
//   - selected row: SurfaceVariant fill
//   - select column: 56dp leading, an 18dp checkbox box (checkbox.zig's
//     box geometry minus its state layer + draw-on animation)
//   - sort arrow: the Material "arrow_upward" glyph at 16dp, OnSurface —
//     painted on the sorted column (hovered unsorted sortable columns show
//     it at half alpha, upstream's hover reveal), rotating 180° descending
//     on the default spring (upstream's animateFloatAsState)
//
// Interactions:
//   - sorting: a `sortable` column's header toggles asc → desc on tap and
//     reorders the owned rows (a stable sort on the cell text, or
//     `sort_cmp`); selection is row-model state and follows the row.
//   - selection: `selectable` prepends the checkbox column — a row's
//     checkbox toggles it (firing `on_selection_change`), the header
//     checkbox toggles all and paints the tristate dash on a partial
//     selection.
//   - scroll: a height constraint below the content height scrolls the
//     BODY (wheel + drag/fling via the shared ScrollInput) under the
//     pinned header — the sticky header. Unbounded (inside a ScrollView)
//     the table reports its natural height and the parent scrolls — the
//     header then scrolls away with the page, like upstream.
//
// Column resizing (`resizable` + `on_col_resize`): a press inside ±4dp
// of a data column's trailing header border grabs a drag that rewrites
// the column's user width (clamped to the 80dp minimum) — a faint
// divider marks the hovered border, a primary bar tracks the drag.
//
// Remaining deviations: text-only cells (`cell_paint` takes over a cell's
// draw — real child widgets in cells stay out of scope). Virtualized in
// the flat sense: rows are data, not nodes — the paint pass jumps to the
// first visible row by index math, and column widths compute once (memo).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const i18n_mod = @import("../ui/i18n.zig");
const gestures = @import("../ui/gestures.zig");
const scroll_mod = @import("../ui/scroll.zig");
const scroll_util = @import("scroll_util.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

pub const TableOptions = struct {
    theme: Theme = theme_mod.light,
    /// When true, tapping a row fires on_row_tap.
    tappable: bool = false,
    /// Per-column sort flag — `sortable[i]` = column i's header toggles a
    /// sort on tap (ascending → descending).
    sortable: []const bool = &.{},
    /// The sort comparator (orders two cells of a column) — defaults to
    /// lexicographic byte order on the cell text.
    sort_cmp: SortComparator = .{},
    /// A leading checkbox column: a row's checkbox toggles its selection,
    /// the header checkbox toggles all.
    selectable: bool = false,
    /// Takes over a data cell's paint — non-null when the callback draws
    /// the cell (the default text draw is skipped). The cell text still
    /// drives the column width.
    cell_paint: ?CellPaintCallback = null,
    /// Header-border drags resize columns — the grab zone sits ±4dp on
    /// each data column's trailing edge inside the header row. Resized
    /// widths persist in the widget (auto columns still fit content).
    resizable: bool = false,
    /// Fires on each width change while a header-border drag runs and
    /// once more when it settles (col index + width in dp, already
    /// applied to the layout).
    on_col_resize: ?ColResizeCallback = null,
    /// px scrolled per wheel click.
    wheel_speed: f32 = 48,
};

// --- Tokens ---
const header_h: f32 = 56;
const row_h: f32 = 52;
const cell_pad_x: f32 = 16;
const cell_pad_y: f32 = 12;
const col_min_w: f32 = 80;
const separator_h: f32 = 1;
const select_col_w: f32 = 56;
const checkbox_box: f32 = 18; // checkbox.zig's box_size
const checkbox_radius: f32 = 2; // its box_radius
const sort_arrow_w: f32 = 16; // upstream's sort icon slot
const sort_arrow_gap: f32 = 4;
const resize_zone: f32 = 8; // ±4dp grab strip on a column's trailing edge

// --- State ---

/// Row-tap callback: receives the tapped row index (0-based, data rows —
/// the header is not tappable). The index is the row's CURRENT position:
/// a sort reorders the rows, so it shifts with them.
pub const RowTapCallback = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, row: usize) void,
    userdata: ?*anyopaque,
};

/// The sort comparator: orders two cells of column `col` (TableOptions.
/// sort_cmp). The defaults are a valid comparator — lexicographic byte
/// order — so optionsFromValue can instantiate the field.
pub const SortComparator = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, col: usize, a: []const u8, b: []const u8) std.math.Order = cellTextOrder,
    userdata: ?*anyopaque = null,
};

fn cellTextOrder(_: ?*anyopaque, _: usize, a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

/// A custom cell paint's arguments (TableOptions.cell_paint): `rect` is
/// the cell's box in the table's parent space (the padding is NOT applied
/// — the callback owns the whole cell); `text` is the cell's model.
pub const CellPaintArgs = struct {
    node: *Node,
    rect: Rect,
    row: usize,
    col: usize,
    text: [:0]const u8,
    selected: bool,
};

/// Custom cell painter — true means the callback drew the cell.
pub const CellPaintCallback = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, ctx: *kx.Ctx, args: CellPaintArgs) bool = cellPaintDeclined,
    userdata: ?*anyopaque = null,
};

fn cellPaintDeclined(_: ?*anyopaque, _: *kx.Ctx, _: CellPaintArgs) bool {
    return false;
}

/// Column-resize callback (TableOptions.on_col_resize): the resized
/// column index + the width the drag settled at. The defaults are a
/// no-op — optionsFromValue can instantiate the field.
pub const ColResizeCallback = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, col: usize, width: f32) void = colResizeNoop,
    userdata: ?*anyopaque = null,
};

fn colResizeNoop(_: ?*anyopaque, _: usize, _: f32) void {}

const Row = struct {
    cells: [][:0]u8, // owned, null-terminated
    selected: bool = false,
};

/// What a pointer press grabbed — an .up fires it only when it still
/// lands on the same target (press/up consistency like the other
/// controls).
const Press = union(enum) { select_all, sort: usize, select: usize, tap: usize };

const TableState = struct {
    opts: TableOptions,
    columns: std.array_list.Managed([:0]u8), // owned, null-terminated
    rows: std.array_list.Managed(Row), // owned row models (cells owned)
    on_row_tap: ?RowTapCallback = null,
    on_selection_change: ?Callback = null,
    hovered_row: i32 = -1,
    /// Hovered unsorted sortable column (the hover arrow reveal).
    hovered_header_col: i32 = -1,
    press: ?Press = null,
    /// The down position in raw coordinates — drag deltas are physical
    /// pointer motion (PointerEvent.raw_x/raw_y).
    press_raw_x: f32 = 0,
    press_raw_y: f32 = 0,
    /// The active sort column (-1 = unsorted).
    sort_col: i32 = -1,
    sort_asc: bool = true,
    /// The sort arrow's animated rotation in degrees (0 = up/ascending).
    /// Upstream rides it on animateFloatAsState; the chan byte gives the
    /// timeline a stable key (the state's heap address is stable).
    arrow_rot: f32 = 0,
    arrow_chan: u8 = 0,
    /// The body scrolls under the pinned header; content = the rows region.
    scroll: scroll_mod.ScrollState = .{},
    input: scroll_util.ScrollInput = .{},
    /// Column widths — computed in measure, reused by paint (was: a heap
    /// ArrayList rebuilt per frame). clearRetainingCapacity on mutation.
    col_ws: std.array_list.Managed(f32),
    /// Per-column user width overrides (0 = content-auto) — a header-
    /// border drag writes the dragged column. Sized to `columns` at init.
    user_ws: std.array_list.Managed(f32),
    /// The header-border drag in progress (-1 = idle): the grabbed
    /// column, the grab x and the column's width at grab.
    resizing_col: i32 = -1,
    resize_grab_x: f32 = 0,
    resize_start_w: f32 = 0,
    /// The header border under the pointer — the resize affordance
    /// (-1 = none).
    hover_border: i32 = -1,
    i18n: ?*i18n_mod.I18n = null,
};

fn stateOf(n: *Node) *TableState {
    return @ptrCast(@alignCast(n.state.?));
}

// --- Measure ---

/// Recompute column widths into the state's retained list — called by
/// measure (rows/columns mutation clears it, so the next measure refills).
/// Paint reuses the retained items instead of re-measuring every cell.
fn computeColWidths(s: *TableState) void {
    const t = s.opts.theme;
    const hs = t.type_scale.title_small;
    const bs = t.type_scale.body_medium;
    s.col_ws.clearRetainingCapacity();
    for (s.columns.items) |col| {
        const w = ui.paint.measureTextStyled(col, hs.size, hs.weight, hs.letter_spacing).width + cell_pad_x * 2;
        s.col_ws.append(@max(col_min_w, w)) catch @panic("klaxon: out of memory");
    }
    // Expand with cell content.
    for (s.rows.items) |row| {
        for (row.cells, 0..) |cell, ci| {
            if (ci >= s.col_ws.items.len) break;
            const w = ui.paint.measureTextStyled(cell, bs.size, bs.weight, bs.letter_spacing).width + cell_pad_x * 2;
            if (w > s.col_ws.items[ci]) s.col_ws.items[ci] = w;
        }
    }
    // User-resized columns hold their dragged width.
    for (s.user_ws.items, 0..) |uw, ci| {
        if (ci >= s.col_ws.items.len) break;
        if (uw > 0) s.col_ws.items[ci] = uw;
    }
}

fn tblMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);

    // Column widths: max of header and cell content widths + padding.
    const ncols = s.columns.items.len;
    if (ncols == 0) return .{ .w = 0, .h = 0 };

    // Lazy like the paint/hit-test paths: widths are a pure function of
    // the (immutable) columns+rows+theme — a resize marks layout dirty
    // and re-enters measure, where the col_ws memo still holds (the user
    // override re-applies inside computeColWidths only on rebuild).
    if (s.col_ws.items.len == 0) computeColWidths(s);

    var total_w: f32 = if (s.opts.selectable) select_col_w else 0;
    for (s.col_ws.items) |w| total_w += w;

    const nrows = s.rows.items.len;
    const total_hgt = header_h + @as(f32, @floatFromInt(nrows)) * row_h;

    return .{
        .w = @max(c.min_w, @min(c.max_w, total_w)),
        .h = @max(c.min_h, @min(c.max_h, total_hgt)),
    };
}

fn tblLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    // The scrollable content is the body — the header stays pinned.
    s.scroll.viewport = @max(0, bounds.h - header_h);
    s.scroll.content = @as(f32, @floatFromInt(s.rows.items.len)) * row_h;
    // Re-clamp after a resize: if the clamp moved the offset the whole
    // viewport shifts — damage it (layout must not teleport content
    // silently; scroll_view's rule).
    if (s.scroll.setOffset(s.scroll.offset)) n.markDirty();
}

// --- Geometry ---

/// The x where data columns start — a selectable table's leading checkbox
/// column is fixed-width and sits outside `col_ws`.
fn dataOriginX(s: *const TableState, b: Rect) f32 {
    return b.x + if (s.opts.selectable) select_col_w else 0;
}

/// The data column under header x. Defensive width refill for paint-less
/// input paths (same as tblPaint's).
fn headerColAt(s: *TableState, b: Rect, x: f32) ?usize {
    if (s.col_ws.items.len == 0) computeColWidths(s);
    var cx = dataOriginX(s, b);
    for (s.columns.items, 0..) |_, ci| {
        if (ci >= s.col_ws.items.len) break;
        const w = s.col_ws.items[ci];
        if (x >= cx and x < cx + w) return ci;
        cx += w;
    }
    return null;
}

/// The data column whose TRAILING border sits within the resize grab
/// zone of (x, y) — header row only. null outside the header/zone.
fn borderColAt(s: *TableState, n: *Node, x: f32, y: f32) ?usize {
    const b = n.bounds;
    if (y < b.y or y >= b.y + header_h) return null;
    if (s.col_ws.items.len == 0) computeColWidths(s);
    var cx = dataOriginX(s, b);
    for (s.columns.items, 0..) |_, ci| {
        if (ci >= s.col_ws.items.len) break;
        cx += s.col_ws.items[ci];
        if (@abs(x - cx) <= resize_zone / 2) return ci;
    }
    return null;
}

/// The data row under body y — content space maps through the scroll
/// offset; null outside the body viewport.
fn rowAt(s: *const TableState, b: Rect, y: f32) ?usize {
    if (y < b.y + header_h or y >= b.y + b.h) return null;
    const cy = y - (b.y + header_h) + s.scroll.offset;
    if (cy < 0) return null; // rubber-band overscroll
    const ri: usize = @intFromFloat(cy / row_h);
    return if (ri < s.rows.items.len) ri else null;
}

/// What a press at (x, y) grabs — the .down/.up contract (an up on a
/// different target doesn't fire).
fn pressTargetAt(s: *TableState, n: *Node, x: f32, y: f32) ?Press {
    const b = n.bounds;
    if (!b.contains(x, y)) return null;
    if (y < b.y + header_h) {
        if (s.opts.selectable and x < dataOriginX(s, b)) return .select_all;
        if (headerColAt(s, b, x)) |ci| {
            if (isSortable(s, ci)) return .{ .sort = ci };
        }
        return null;
    }
    const ri = rowAt(s, b, y) orelse return null;
    if (s.opts.selectable and x < dataOriginX(s, b)) return .{ .select = ri };
    return if (s.opts.tappable) .{ .tap = ri } else null;
}

// --- Sorting / selection ---

fn isSortable(s: *const TableState, col: usize) bool {
    return col < s.opts.sortable.len and s.opts.sortable[col];
}

fn compareCells(s: *const TableState, col: usize, a: []const u8, b: []const u8) std.math.Order {
    const cmp = s.opts.sort_cmp;
    return cmp.fn_ptr(cmp.userdata, col, a, b);
}

const SortCtx = struct { s: *TableState, col: usize };

fn sortRowLess(ctx: SortCtx, a: Row, b: Row) bool {
    const ca: []const u8 = if (ctx.col < a.cells.len) a.cells[ctx.col] else "";
    const cb: []const u8 = if (ctx.col < b.cells.len) b.cells[ctx.col] else "";
    const ord = compareCells(ctx.s, ctx.col, ca, cb);
    return if (ctx.s.sort_asc) ord == .lt else ord == .gt;
}

/// Stable-sort the owned rows by the active column (std.mem.sort is the
/// block sort — equal cells keep their order, upstream's expectation for
/// a re-clicked sort).
fn sortRows(n: *Node) void {
    const s = stateOf(n);
    if (s.sort_col < 0) return;
    std.mem.sort(Row, s.rows.items, SortCtx{ .s = s, .col = @intCast(s.sort_col) }, sortRowLess);
    n.markDirty();
}

fn arrowCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.arrow_rot = v[0];
    n.markDirty();
}

/// Upstream carries the arrow rotation on animateFloatAsState — a
/// direction flip on the active column animates 0↔180 on the default
/// spring; switching columns snaps (each header owns its rotation state,
/// and the freshly sorted one starts asc/up). No timeline → snap.
fn retargetArrow(n: *Node, animate: bool) void {
    const s = stateOf(n);
    const target: f32 = if (s.sort_asc) 0 else 180;
    if (animate) {
        if (ui.anim.timeline()) |tl| {
            const from: ui.anim.Vec4 = .{ s.arrow_rot, 0, 0, 0 };
            _ = tl.play(.{
                .kind = ui.anim.Animation.springAnim(from, .{ target, 0, 0, 0 }, s.opts.theme.motion.springs.default_spring, tl.channelVelocity(@ptrCast(&s.arrow_chan))),
                .from = from,
                .channel = @ptrCast(&s.arrow_chan),
                .on_update = .{ .fn_ptr = arrowCb, .userdata = n },
            });
            return;
        }
    }
    s.arrow_rot = target;
    n.markDirty();
}

/// A sortable header tap: a new column sorts ascending, the same column
/// toggles the direction.
fn toggleSort(n: *Node, col: usize) void {
    const s = stateOf(n);
    const ci: i32 = @intCast(col);
    const flip = s.sort_col == ci;
    s.sort_asc = if (flip) !s.sort_asc else true;
    s.sort_col = ci;
    retargetArrow(n, flip);
    sortRows(n);
}

/// The header checkbox: anything-but-all selects all, all clears
/// (upstream's tristate collapses to binary on tap — there's no "clear
/// some" gesture).
fn toggleSelectAll(n: *Node) void {
    const s = stateOf(n);
    if (s.rows.items.len == 0) return;
    const target = selectedCount(n) != s.rows.items.len;
    for (s.rows.items) |*r| r.selected = target;
    if (s.on_selection_change) |cb| cb.fn_ptr(cb.userdata);
    n.markDirty();
}

// --- Paint ---

const CheckKind = enum { unchecked, checked, indeterminate };

/// The in-cell checkbox — checkbox.zig's drawBox/drawCheck geometry (the
/// 18dp r2 box, the 2dp outline ring inset by half its width, the
/// (0.25,0.5) → (0.4,0.65) → (0.75,0.3) check polyline) minus its state
/// layer + animated draw-on fraction: a per-cell affordance, not a
/// focusable control. `indeterminate` is upstream's tristate header box
/// for a partial selection: a filled box + the dash.
fn paintCellCheckbox(ctx: *kx.Ctx, cx: f32, cy: f32, v: CheckKind, t: Theme) void {
    const x = cx - checkbox_box / 2;
    const y = cy - checkbox_box / 2;
    const cs = t.colors;
    if (v == .unchecked) {
        ui.paint.strokeRRect(ctx, x + 1, y + 1, checkbox_box - 2, checkbox_box - 2, checkbox_radius - 1, 2, cs.on_surface_variant);
        return;
    }
    ui.paint.fillRRect(ctx, x, y, checkbox_box, checkbox_box, checkbox_radius, cs.primary);
    if (v == .indeterminate) {
        ui.paint.fillRect(ctx, x + 4, cy - 1, checkbox_box - 8, 2, cs.on_primary);
        return;
    }
    const xs = [_]f32{ x + checkbox_box * 0.25, x + checkbox_box * 0.4, x + checkbox_box * 0.75 };
    const ys = [_]f32{ y + checkbox_box * 0.5, y + checkbox_box * 0.65, y + checkbox_box * 0.3 };
    ui.paint.strokePolyline(ctx, &xs, &ys, 2, false, cs.on_primary);
}

/// The Material "arrow_upward" glyph in its 16dp slot: a stem + a
/// two-segment head, stroked (no icon path crosses the ABI). Ascending
/// points up; `deg` is the animated rotation (180° descending).
fn paintSortArrow(ctx: *kx.Ctx, cx: f32, cy: f32, deg: f32, color: Color) void {
    ui.paint.save(ctx);
    if (deg != 0) {
        ui.paint.translate(ctx, cx, cy);
        ui.paint.rotate(ctx, deg);
        ui.paint.translate(ctx, -cx, -cy);
    }
    const stem_x = [_]f32{ cx, cx };
    const stem_y = [_]f32{ cy + 5, cy - 4 };
    ui.paint.strokePolyline(ctx, &stem_x, &stem_y, 1.5, true, color);
    const head_x = [_]f32{ cx - 3.5, cx, cx + 3.5 };
    const head_y = [_]f32{ cy - 0.5, cy - 4, cy - 0.5 };
    ui.paint.strokePolyline(ctx, &head_x, &head_y, 1.5, true, color);
    ui.paint.restore(ctx);
}

fn tblPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const hs = t.type_scale.title_small;
    const bs = t.type_scale.body_medium;

    if (s.columns.items.len == 0) return;

    // Column widths are cached by measure; recompute if paint runs without
    // a layout pass (defensive — mutations always markLayoutDirty).
    if (s.col_ws.items.len == 0) computeColWidths(s);

    // Container background.
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, t.colors.surface);

    // Data rows: the body scrolls under the pinned header — clip to the
    // body region and translate by the scroll offset.
    const body_y = b.y + header_h;
    const body_h = @max(0, b.h - header_h);
    if (body_h > 0) {
        ui.paint.clipRect(ctx, b.x, body_y, b.w, body_h);
        // Fixed row_h → the visible window is index math: jump to the
        // first (possibly clipped) row instead of scanning from row 0.
        var ri: usize = @intFromFloat(@max(0, s.scroll.offset) / row_h);
        var ry = body_y - s.scroll.offset + @as(f32, @floatFromInt(ri)) * row_h;
        while (ri < s.rows.items.len and ry < body_y + body_h) : ({
            ri += 1;
            ry += row_h;
        }) {
            const row = s.rows.items[ri];
            if (ry + row_h > body_y) { // fully above → clipped away anyway
                // Selected row: the SurfaceVariant fill; else the hover
                // state layer (tappable).
                if (row.selected) {
                    ui.paint.fillRect(ctx, b.x, ry, b.w, row_h, t.colors.surface_variant);
                } else if (s.opts.tappable and s.hovered_row == @as(i32, @intCast(ri))) {
                    const layer = theme_mod.stateLayer(t.colors.surface, t.colors.on_surface, t.state.hover);
                    ui.paint.fillRect(ctx, b.x, ry, b.w, row_h, layer);
                }

                if (s.opts.selectable) {
                    paintCellCheckbox(ctx, b.x + select_col_w / 2, ry + row_h / 2, if (row.selected) .checked else .unchecked, t);
                }

                var cx = dataOriginX(s, b);
                for (row.cells, 0..) |cell, ci| {
                    if (ci >= s.col_ws.items.len) break;
                    const w = s.col_ws.items[ci];
                    var painted = false;
                    if (s.opts.cell_paint) |cp| {
                        painted = cp.fn_ptr(cp.userdata, ctx, .{ .node = n, .rect = .{ .x = cx, .y = ry, .w = w, .h = row_h }, .row = ri, .col = ci, .text = cell, .selected = row.selected });
                    }
                    if (!painted) {
                        const tx = cx + cell_pad_x;
                        const ty = ry + (row_h - bs.line_height) / 2 + bs.line_height * 0.8;
                        ui.paint.textStyled(ctx, cell, tx, ty, bs.size, bs.weight, bs.letter_spacing, t.colors.on_surface);
                    }
                    cx += w;
                }

                // Row separator.
                if (ri + 1 < s.rows.items.len) {
                    ui.paint.fillRect(ctx, b.x, ry + row_h, b.w, separator_h, t.colors.outline_variant);
                }
            }
        }
        ui.paint.clipReset(ctx);
    }

    // Header row — painted last, never scrolled: the sticky header.
    ui.paint.fillRect(ctx, b.x, b.y, b.w, header_h, t.colors.surface_container_highest);
    if (s.opts.selectable) {
        const sel = selectedCount(n);
        const v: CheckKind = if (sel == 0)
            .unchecked
        else if (sel == s.rows.items.len)
            .checked
        else
            .indeterminate;
        paintCellCheckbox(ctx, b.x + select_col_w / 2, b.y + header_h / 2, v, t);
    }
    var cx = dataOriginX(s, b);
    for (s.columns.items, 0..) |col, ci| {
        if (ci >= s.col_ws.items.len) break;
        const w = s.col_ws.items[ci];
        const tx = cx + cell_pad_x;
        const ty = b.y + (header_h - hs.line_height) / 2 + hs.line_height * 0.8;
        ui.paint.textStyled(ctx, col, tx, ty, hs.size, hs.weight, hs.letter_spacing, t.colors.on_surface);
        const cii: i32 = @intCast(ci);
        // The sorted column's arrow is always painted (the programmatic
        // setSort can sort a non-`sortable` column — upstream's
        // sortColumnIndex is independent of a column's onSort); an
        // unsorted sortable column's appears on hover at half alpha.
        if (s.sort_col == cii or (isSortable(s, ci) and s.hovered_header_col == cii)) {
            const active = s.sort_col == cii;
            const tw = ui.paint.measureTextStyled(col, hs.size, hs.weight, hs.letter_spacing).width;
            const ax = tx + tw + sort_arrow_gap + sort_arrow_w / 2;
            paintSortArrow(ctx, ax, b.y + header_h / 2, if (active) s.arrow_rot else 0, ui.paint.withAlphaScaled(t.colors.on_surface, if (active) 1 else 0.5));
        }
        cx += w;
    }

    // The resize affordance: a faint divider under the hovered border,
    // a primary bar while the drag is live (Finder/Excel convention).
    if (s.opts.resizable) {
        const hot: i32 = if (s.resizing_col >= 0) s.resizing_col else s.hover_border;
        if (hot >= 0) {
            var bx = dataOriginX(s, b);
            for (0..@intCast(hot + 1)) |i| {
                if (i < s.col_ws.items.len) bx += s.col_ws.items[i];
            }
            const live = s.resizing_col >= 0;
            ui.paint.fillRect(ctx, bx - (if (live) @as(f32, 1) else 0.5), b.y, if (live) @as(f32, 2) else 1, header_h, if (live) t.colors.primary else t.colors.outline_variant);
        }
    }
}

// --- Input ---

fn tblPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    const b = n.bounds;

    switch (ev.phase) {
        .down => {
            // A header-border grab starts a column resize and owns the
            // gesture outright — the scroll tracker stays disarmed (a
            // border press is never a scroll intent).
            if (s.opts.resizable) {
                if (borderColAt(s, n, ev.x, ev.y)) |ci| {
                    s.resizing_col = @intCast(ci);
                    s.resize_grab_x = ev.raw_x;
                    s.resize_start_w = s.col_ws.items[ci];
                    s.press = null;
                    n.markDirty(); // the divider affordance lights up
                    return true;
                }
            }
            // Register the drag track + stop a fling; the down still
            // bubbles so a parent scroller tracks the same gesture
            // (ListView's nested-scroll idiom).
            _ = s.input.onPointer(ev, &s.scroll, setScrollOffset, n);
            s.press = pressTargetAt(s, n, ev.x, ev.y);
            s.press_raw_x = ev.raw_x;
            s.press_raw_y = ev.raw_y;
            return false;
        },
        .up => {
            // A resize ends with the dragged width committed; the
            // callback reports the settled width.
            if (s.resizing_col >= 0) {
                const ci: usize = @intCast(s.resizing_col);
                s.resizing_col = -1;
                n.markDirty();
                if (s.opts.on_col_resize) |cb| cb.fn_ptr(cb.userdata, ci, s.user_ws.items[ci]);
                return true;
            }
            _ = s.input.onPointer(ev, &s.scroll, setScrollOffset, n); // a fast release flings
            const press = s.press orelse return false;
            s.press = null;
            const cur = pressTargetAt(s, n, ev.x, ev.y) orelse return false;
            if (!std.meta.eql(press, cur)) return false;
            switch (press) {
                .select_all => toggleSelectAll(n),
                .sort => |ci| toggleSort(n, ci),
                .select => |ri| setRowSelected(n, ri, !s.rows.items[ri].selected),
                .tap => |ri| if (s.on_row_tap) |cb| cb.fn_ptr(cb.userdata, ri),
            }
            return true;
        },
        .move => {
            // An active resize owns the pointer: the grabbed column's
            // user width tracks the drag (clamped to the column minimum),
            // re-measuring the table on each change.
            if (s.resizing_col >= 0) {
                const ci: usize = @intCast(s.resizing_col);
                const w = @max(col_min_w, s.resize_start_w + ev.raw_x - s.resize_grab_x);
                if (ci < s.user_ws.items.len and s.user_ws.items[ci] != w) {
                    s.user_ws.items[ci] = w;
                    // The col_ws memo is lazy now — apply the override
                    // directly so the next measure keeps the drag.
                    if (ci < s.col_ws.items.len) s.col_ws.items[ci] = w;
                    n.markLayoutDirty(); // the width feeds measure
                    if (s.opts.on_col_resize) |cb| cb.fn_ptr(cb.userdata, ci, w);
                }
                return true;
            }
            // A drag past the tap slop cancels the press (the scroll owns
            // the gesture); moves that scroll are claimed, the rest bubble.
            if (s.press != null) {
                const dx = ev.raw_x - s.press_raw_x;
                const dy = ev.raw_y - s.press_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) s.press = null;
            }
            return s.input.onPointer(ev, &s.scroll, setScrollOffset, n);
        },
        .outside_down => {
            s.press = null;
            s.resizing_col = -1;
            _ = s.input.onPointer(ev, &s.scroll, setScrollOffset, n);
            return false;
        },
        // Hover rows: `.move` only reaches a captured node — the table's
        // own moves go to the scroll gesture, so row tracking lives on the
        // hover phases.
        .hover_move => {
            // The resize affordance lights the border under the pointer.
            if (s.opts.resizable) {
                const hb: i32 = if (borderColAt(s, n, ev.x, ev.y)) |ci| @intCast(ci) else -1;
                if (hb != s.hover_border) {
                    s.hover_border = hb;
                    n.markDirty();
                }
            }
            if (s.opts.tappable) {
                const ri: i32 = if (rowAt(s, b, ev.y)) |r| @intCast(r) else -1;
                if (ri != s.hovered_row) {
                    s.hovered_row = ri;
                    n.markDirty();
                }
            }
            const hc: i32 = blk: {
                if (ev.y < b.y or ev.y >= b.y + header_h) break :blk -1;
                const ci = headerColAt(s, b, ev.x) orelse break :blk -1;
                const cii: i32 = @intCast(ci);
                // The reveal is for unsorted sortable columns — the sorted
                // column's arrow already shows.
                break :blk if (s.sort_col != cii and isSortable(s, ci)) cii else -1;
            };
            if (hc != s.hovered_header_col) {
                s.hovered_header_col = hc;
                n.markDirty();
            }
            return false;
        },
        .leave => {
            if (s.hovered_row != -1 or s.hovered_header_col != -1 or s.hover_border != -1) {
                s.hovered_row = -1;
                s.hovered_header_col = -1;
                s.hover_border = -1;
                n.markDirty();
            }
            return false;
        },
        else => return false,
    }
}

fn tblOnScroll(n: *Node, ev: input.ScrollEvent) bool {
    const s = stateOf(n);
    return s.input.onScroll(ev, &s.scroll, s.opts.wheel_speed, setScrollOffset, n);
}

fn tblScrollInfo(n: *Node) scroll_mod.ScrollInfo {
    return stateOf(n).scroll.info();
}

fn tblScrollSetOffset(n: *Node, value: f32) void {
    _ = setScrollOffset(n, value);
}

// --- Deinit ---

fn tblDeinit(n: *Node) void {
    const s = stateOf(n);
    s.input.deinit(); // a live flight ticker borrows this state
    input.releaseNode(n); // the table can hold a pointer capture/hover
    for (s.columns.items) |col| n.allocator.free(col);
    s.columns.deinit();
    for (s.rows.items) |row| {
        for (row.cells) |cell| n.allocator.free(cell);
        n.allocator.free(row.cells);
    }
    s.rows.deinit();
    s.col_ws.deinit();
    s.user_ws.deinit();
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = tblLocaleCb, .userdata = n });
    if (ui.anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.arrow_chan)); // the cb points into this state
    n.allocator.destroy(s);
}

// --- VTable ---

/// The group label is tr()-resolved — the locale callback re-attaches in
/// the new locale.
fn tblLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    ui.semantics.attach(n, .{ .role = .group, .label = i18n_mod.tr("Data table"), .focusable = false });
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

const tbl_vtable = ui.node.VTable{
    .measure = tblMeasure,
    .measure_pure = true, // memo writes only (col_ws) — same constraints → same size
    .layout = tblLayout,
    .paint = tblPaint,
    .on_pointer = tblPointer,
    .on_scroll = tblOnScroll,
    .scroll_info = tblScrollInfo,
    .scroll_set_offset = tblScrollSetOffset,
    .deinit = tblDeinit,
    // auto_retain: paint never leaves the bounds (the body clip) — an idle
    // table replays one blit; scrolling marks it dirty → direct paint.
    .auto_retain = true,
};

// --- Factory ---

/// Create an M3E data table.
///
/// `columns` — column titles (copied).
/// `rows` — data rows, each an array of cell strings (copied). The widget
/// owns the row models: a sort reorders them in place and selection
/// follows the row.
/// `on_row_tap` — fired when a row is tapped (only when `opts.tappable`).
/// `on_selection_change` — fired on any selection change (a row's
/// checkbox toggle or the header's select-all).
/// `opts` — theme, tappable, sortable/sort_cmp, selectable, cell_paint,
/// resizable/on_col_resize, wheel_speed.
pub fn table(
    allocator: std.mem.Allocator,
    columns: []const []const u8,
    rows: []const []const []const u8,
    on_row_tap: ?RowTapCallback,
    on_selection_change: ?Callback,
    opts: TableOptions,
) !*Node {
    const node = try Node.create(allocator, &tbl_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(TableState);
    errdefer allocator.destroy(s);

    s.* = .{
        .opts = opts,
        .columns = std.array_list.Managed([:0]u8).init(allocator),
        .rows = std.array_list.Managed(Row).init(allocator),
        .on_row_tap = on_row_tap,
        .on_selection_change = on_selection_change,
        .col_ws = std.array_list.Managed(f32).init(allocator),
        .user_ws = std.array_list.Managed(f32).init(allocator),
    };

    // Copy columns.
    for (columns) |col| {
        const buf = try allocator.alloc(u8, col.len + 1);
        @memcpy(buf[0..col.len], col);
        buf[col.len] = 0;
        try s.columns.append(buf[0..col.len :0]);
    }
    try s.user_ws.appendNTimes(0, s.columns.items.len); // 0 = auto width

    // Copy rows.
    for (rows) |row| {
        const cells = try allocator.alloc([:0]u8, row.len);
        for (row, 0..) |cell, ci| {
            const buf = try allocator.alloc(u8, cell.len + 1);
            @memcpy(buf[0..cell.len], cell);
            buf[cell.len] = 0;
            cells[ci] = buf[0..cell.len :0];
        }
        try s.rows.append(.{ .cells = cells });
    }

    node.state = @ptrCast(s);

    tblLocaleCb(node); // the same path resolves the label in the active locale
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = tblLocaleCb, .userdata = node });

    return node;
}

// --- Public state API ---

/// The active sort column (null = unsorted).
pub fn sortColumn(n: *Node) ?usize {
    const s = stateOf(n);
    return if (s.sort_col < 0) null else @intCast(s.sort_col);
}

/// The active sort's direction (true = ascending, the up arrow).
pub fn sortAscending(n: *Node) bool {
    return stateOf(n).sort_asc;
}

/// Set the sort programmatically (a no-op for a bogus column) — the rows
/// re-sort immediately, same path as a header tap. The previous order is
/// not restored on a re-sort: the rows' current order is the base, like
/// upstream sorting the data on each toggle.
pub fn setSort(n: *Node, col: usize, ascending: bool) void {
    const s = stateOf(n);
    if (col >= s.columns.items.len) return;
    const ci: i32 = @intCast(col);
    const flip = s.sort_col == ci and s.sort_asc != ascending;
    s.sort_col = ci;
    s.sort_asc = ascending;
    retargetArrow(n, flip);
    sortRows(n);
}

/// Whether row `ri` (current position) is selected. Selection follows the
/// row through sorts.
pub fn isRowSelected(n: *Node, ri: usize) bool {
    const s = stateOf(n);
    return ri < s.rows.items.len and s.rows.items[ri].selected;
}

/// Set row `ri`'s selection — fires on_selection_change on a change.
pub fn setRowSelected(n: *Node, ri: usize, selected: bool) void {
    const s = stateOf(n);
    if (ri >= s.rows.items.len or s.rows.items[ri].selected == selected) return;
    s.rows.items[ri].selected = selected;
    if (s.on_selection_change) |cb| cb.fn_ptr(cb.userdata);
    n.markDirty();
}

/// The number of selected rows.
pub fn selectedCount(n: *Node) usize {
    const s = stateOf(n);
    var count: usize = 0;
    for (s.rows.items) |r| count += @intFromBool(r.selected);
    return count;
}

/// The body scroll offset (the header stays pinned above it).
pub fn scrollOffset(n: *Node) f32 {
    return stateOf(n).scroll.offset;
}

/// Set the body scroll offset (clamped to [0, content - viewport]).
/// Returns true if it changed.
pub fn setScrollOffset(n: *Node, value: f32) bool {
    const s = stateOf(n);
    if (!s.scroll.setOffset(value)) return false;
    n.markDirty();
    return true;
}

// --- Tests ---

test "table: measure includes header + rows" {
    const a = std.testing.allocator;
    const n = try table(a, &.{ "Name", "Age" }, &.{ &.{ "Alice", "30" }, &.{"Bob"} }, null, null, .{});
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expect(sz.w >= col_min_w * 2);
    try std.testing.expectApproxEqAbs(header_h + row_h * 2, sz.h, 0.001);
}

test "table: measure adds the select column when selectable" {
    const a = std.testing.allocator;
    const n = try table(a, &.{"A"}, &.{&.{"1"}}, null, null, .{ .selectable = true });
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expect(sz.w >= select_col_w + col_min_w);
}

test "table: tappable fires on_row_tap with the row index" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var count: u32 = 0;
    var tapped_row: usize = 999;
    const Ctx = struct { count: *u32, row: *usize };
    var ctx = Ctx{ .count = &count, .row = &tapped_row };
    const cb = RowTapCallback{ .fn_ptr = rowTapCb, .userdata = &ctx };
    const a = std.testing.allocator;
    const n = try table(a, &.{"A"}, &.{ &.{"1"}, &.{"2"} }, cb, null, .{ .tappable = true });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 200, .h = header_h + row_h * 2 });
    // Tap the 2nd row (down + up on the same row).
    router.dispatchPointer(n, .{ .phase = .down, .x = 50, .y = header_h + row_h + 10 });
    router.dispatchPointer(n, .{ .phase = .up, .x = 50, .y = header_h + row_h + 10 });
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(usize, 1), tapped_row);
}

test "table: a sortable header tap toggles asc/desc and reorders the rows" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try table(a, &.{ "Name", "N" }, &.{ &.{ "Charlie", "3" }, &.{ "Alice", "1" }, &.{ "Bob", "2" } }, null, null, .{ .sortable = &.{ true, false } });
    defer n.deinit();
    _ = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    n.layout(.{ .x = 0, .y = 0, .w = 300, .h = header_h + row_h * 3 });
    const s = stateOf(n);
    // Tap col 0's header → ascending.
    router.dispatchPointer(n, .{ .phase = .down, .x = 30, .y = 20 });
    router.dispatchPointer(n, .{ .phase = .up, .x = 30, .y = 20 });
    try std.testing.expectEqual(@as(?usize, 0), sortColumn(n));
    try std.testing.expect(sortAscending(n));
    try std.testing.expectEqualStrings("Alice", s.rows.items[0].cells[0]);
    try std.testing.expectEqualStrings("Bob", s.rows.items[1].cells[0]);
    try std.testing.expectEqualStrings("Charlie", s.rows.items[2].cells[0]);
    // Tap again → descending.
    router.dispatchPointer(n, .{ .phase = .down, .x = 30, .y = 20 });
    router.dispatchPointer(n, .{ .phase = .up, .x = 30, .y = 20 });
    try std.testing.expectEqual(@as(?usize, 0), sortColumn(n));
    try std.testing.expect(!sortAscending(n));
    try std.testing.expectEqualStrings("Charlie", s.rows.items[0].cells[0]);
    try std.testing.expectEqualStrings("Bob", s.rows.items[1].cells[0]);
    try std.testing.expectEqualStrings("Alice", s.rows.items[2].cells[0]);
    // The non-sortable col 1 header is inert.
    const x1 = s.col_ws.items[0] + 10;
    router.dispatchPointer(n, .{ .phase = .down, .x = x1, .y = 20 });
    router.dispatchPointer(n, .{ .phase = .up, .x = x1, .y = 20 });
    try std.testing.expectEqual(@as(?usize, 0), sortColumn(n));
    try std.testing.expect(!sortAscending(n));
}

test "table: sort_cmp overrides the cell ordering + selection follows the row" {
    const a = std.testing.allocator;
    var col_seen: usize = 999;
    const Ctx = struct { col: *usize };
    var ctx = Ctx{ .col = &col_seen };
    const n = try table(a, &.{"N"}, &.{ &.{"30"}, &.{"4"}, &.{"120"} }, null, null, .{ .sortable = &.{true}, .sort_cmp = .{ .fn_ptr = numericCmp, .userdata = &ctx } });
    defer n.deinit();
    setSort(n, 0, true);
    try std.testing.expectEqual(@as(usize, 0), col_seen);
    const s = stateOf(n);
    // numeric order (lexicographic would put "120" first).
    try std.testing.expectEqualStrings("4", s.rows.items[0].cells[0]);
    try std.testing.expectEqualStrings("30", s.rows.items[1].cells[0]);
    try std.testing.expectEqualStrings("120", s.rows.items[2].cells[0]);
    // Selection travels with the row model through a re-sort.
    setRowSelected(n, 2, true); // "120"
    setSort(n, 0, false);
    try std.testing.expect(isRowSelected(n, 0)); // "120" descends to the top
    try std.testing.expectEqualStrings("120", s.rows.items[0].cells[0]);
}

test "table: selectable rows toggle + the header checkbox selects all" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var changes: u32 = 0;
    const Ctx = struct { count: *u32 };
    var ctx = Ctx{ .count = &changes };
    const a = std.testing.allocator;
    const n = try table(a, &.{"A"}, &.{ &.{"1"}, &.{"2"}, &.{"3"} }, null, .{ .fn_ptr = selCb, .userdata = &ctx }, .{ .selectable = true });
    defer n.deinit();
    _ = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    n.layout(.{ .x = 0, .y = 0, .w = 200, .h = header_h + row_h * 3 });
    // Tap row 0's checkbox (inside the select column).
    router.dispatchPointer(n, .{ .phase = .down, .x = select_col_w / 2, .y = header_h + 10 });
    router.dispatchPointer(n, .{ .phase = .up, .x = select_col_w / 2, .y = header_h + 10 });
    try std.testing.expect(isRowSelected(n, 0));
    try std.testing.expect(!isRowSelected(n, 1));
    try std.testing.expectEqual(@as(usize, 1), selectedCount(n));
    try std.testing.expectEqual(@as(u32, 1), changes);
    // A tap on a row's text area doesn't toggle the checkbox.
    router.dispatchPointer(n, .{ .phase = .down, .x = select_col_w + 40, .y = header_h + row_h + 10 });
    router.dispatchPointer(n, .{ .phase = .up, .x = select_col_w + 40, .y = header_h + row_h + 10 });
    try std.testing.expectEqual(@as(usize, 1), selectedCount(n));
    // The header checkbox: partial → select all.
    router.dispatchPointer(n, .{ .phase = .down, .x = select_col_w / 2, .y = header_h / 2 });
    router.dispatchPointer(n, .{ .phase = .up, .x = select_col_w / 2, .y = header_h / 2 });
    try std.testing.expectEqual(@as(usize, 3), selectedCount(n));
    try std.testing.expectEqual(@as(u32, 2), changes);
    // All → clear.
    router.dispatchPointer(n, .{ .phase = .down, .x = select_col_w / 2, .y = header_h / 2 });
    router.dispatchPointer(n, .{ .phase = .up, .x = select_col_w / 2, .y = header_h / 2 });
    try std.testing.expectEqual(@as(usize, 0), selectedCount(n));
    try std.testing.expectEqual(@as(u32, 3), changes);
}

test "table: the body scrolls under the pinned header" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var count: u32 = 0;
    var tapped_row: usize = 999;
    const Ctx = struct { count: *u32, row: *usize };
    var ctx = Ctx{ .count = &count, .row = &tapped_row };
    const cb = RowTapCallback{ .fn_ptr = rowTapCb, .userdata = &ctx };
    const a = std.testing.allocator;
    const n = try table(a, &.{"A"}, &.{ &.{"r0"}, &.{"r1"}, &.{"r2"}, &.{"r3"}, &.{"r4"} }, cb, null, .{ .tappable = true });
    defer n.deinit();
    _ = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    // A bounded height below the content: 2 rows visible + the header.
    n.layout(.{ .x = 0, .y = 0, .w = 200, .h = header_h + row_h * 2 });
    const info = n.vtable.scroll_info.?(n);
    try std.testing.expectEqual(@as(f32, row_h * 5), info.content);
    try std.testing.expectEqual(@as(f32, row_h * 2), info.viewport);
    try std.testing.expectEqual(@as(f32, row_h * 3), info.max_offset);
    // Wheel scrolls the body.
    router.dispatchScroll(n, .{ .x = 50, .y = header_h + 10, .delta_y = -1 });
    try std.testing.expectEqual(@as(f32, 48), scrollOffset(n));
    // Hit-testing maps through the offset: offset row_h + a tap at the
    // body's top lands on row 1+1 = 2? (offset 48: row 1 is partially
    // visible at the top; y = header+10 → content y = 10+48 = 58 → row 1.)
    _ = setScrollOffset(n, row_h);
    router.dispatchPointer(n, .{ .phase = .down, .x = 50, .y = header_h + 10 });
    router.dispatchPointer(n, .{ .phase = .up, .x = 50, .y = header_h + 10 });
    try std.testing.expectEqual(@as(usize, 1), tapped_row);
    // A tap on the header still hits the header, not a scrolled row.
    router.dispatchPointer(n, .{ .phase = .down, .x = 50, .y = 10 });
    router.dispatchPointer(n, .{ .phase = .up, .x = 50, .y = 10 });
    try std.testing.expectEqual(@as(u32, 1), count); // no extra tap
}

test "golden: the pinned header + scrolled body" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try table(a, &.{"Name"}, &.{ &.{"r0"}, &.{"r1"}, &.{"r2"}, &.{"r3"}, &.{"r4"} }, null, null, .{ .theme = t });
    defer n.deinit();
    _ = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    var r = try golden.Renderer.init(std.testing.allocator, 120, 160);
    defer r.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 120, .h = header_h + row_h * 2 });
    _ = setScrollOffset(n, row_h); // row 0 scrolled out, row 1 at the top
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // The header band is still the header fill — pinned through the scroll.
    try std.testing.expectEqual(t.colors.surface_container_highest, f.pixelAt(60, 5));
    try std.testing.expectEqual(t.colors.surface_container_highest, f.pixelAt(60, @intFromFloat(header_h - 2)));
    // The body scrolled: the separator between rows 1/2 sits at
    // header_h + row_h, not at the row 0/1 position anymore — pixel just
    // under the header is row 1's surface, not a separator.
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(100, @intFromFloat(header_h + 2)));
    try std.testing.expectEqual(t.colors.outline_variant, f.pixelAt(60, @intFromFloat(header_h + row_h)));
}

test "golden: a sorted column paints the sort arrow" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try table(a, &.{"Name"}, &.{&.{"x"}}, null, null, .{ .theme = t, .sortable = &.{true} });
    defer n.deinit();
    _ = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    var r = try golden.Renderer.init(std.testing.allocator, 200, 140);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 180, .h = header_h + row_h });
    // The arrow lands right of the header text — compute its slot.
    const tw = ui.paint.measureTextStyled("Name", t.type_scale.title_small.size, t.type_scale.title_small.weight, t.type_scale.title_small.letter_spacing).width;
    const ax = 10 + cell_pad_x + tw + sort_arrow_gap + sort_arrow_w / 2;
    const arrow_rect = Rect{ .x = ax - 8, .y = 10 + header_h / 2 - 8, .w = 16, .h = 16 };
    r.paint(n, 0xFFFFFFFF);
    var f0 = try r.readback(std.testing.allocator);
    defer f0.deinit();
    // Unsorted, unhovered: no arrow ink in the slot.
    try std.testing.expectEqual(@as(u64, 0), f0.countColorIn(arrow_rect, t.colors.on_surface));
    setSort(n, 0, true);
    r.paint(n, 0xFFFFFFFF);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    try std.testing.expect(f1.countColorIn(arrow_rect, t.colors.on_surface) > 0);
}

test "golden: a selected row paints the SurfaceVariant fill + the check" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try table(a, &.{"A"}, &.{ &.{"r0"}, &.{"r1"} }, null, null, .{ .theme = t, .selectable = true });
    defer n.deinit();
    _ = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    var r = try golden.Renderer.init(std.testing.allocator, 200, 170);
    defer r.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 200, .h = header_h + row_h * 2 });
    setRowSelected(n, 1, true); // partial: the header box is indeterminate
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // Row 1's band fills SurfaceVariant.
    try std.testing.expectEqual(t.colors.surface_variant, f.pixelAt(160, @intFromFloat(header_h + row_h + 10)));
    // Row 0 stays surface.
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(160, @intFromFloat(header_h + 10)));
    // The selected row's checkbox box fills Primary (the check + row-0's
    // outline carve pixels out — count the region, don't probe a pixel).
    const row1_box = Rect{ .x = select_col_w / 2 - checkbox_box / 2, .y = header_h + row_h + row_h / 2 - checkbox_box / 2, .w = checkbox_box, .h = checkbox_box };
    try std.testing.expect(f.countColorIn(row1_box, t.colors.primary) > 100);
    // The header's indeterminate box fills Primary too (the dash is
    // on_primary inside it).
    const hdr_box = Rect{ .x = select_col_w / 2 - checkbox_box / 2, .y = header_h / 2 - checkbox_box / 2, .w = checkbox_box, .h = checkbox_box };
    try std.testing.expect(f.countColorIn(hdr_box, t.colors.primary) > 100);
}

test "golden: cell_paint takes over a cell's draw" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    var calls: u32 = 0;
    const Ctx = struct { count: *u32 };
    var ctx = Ctx{ .count = &calls };
    const n = try table(a, &.{"A"}, &.{&.{"r0"}}, null, null, .{ .theme = t, .cell_paint = .{ .fn_ptr = fillCellCb, .userdata = &ctx } });
    defer n.deinit();
    _ = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    var r = try golden.Renderer.init(std.testing.allocator, 160, 140);
    defer r.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 160, .h = header_h + row_h });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 1), calls);
    // The callback painted the cell solid red — no cell text ink there.
    try std.testing.expectEqual(@as(Color, 0xFF0000FF), f.pixelAt(40, @intFromFloat(header_h + 10)));
}

fn rowTapCb(userdata: ?*anyopaque, row: usize) void {
    const Ctx = struct { count: *u32, row: *usize };
    const ctx: *Ctx = @ptrCast(@alignCast(userdata.?));
    ctx.count.* += 1;
    ctx.row.* = row;
}

fn selCb(userdata: ?*anyopaque) void {
    const Ctx = struct { count: *u32 };
    const ctx: *Ctx = @ptrCast(@alignCast(userdata.?));
    ctx.count.* += 1;
}

fn numericCmp(userdata: ?*anyopaque, col: usize, a: []const u8, b: []const u8) std.math.Order {
    const Ctx = struct { col: *usize };
    const ctx: *Ctx = @ptrCast(@alignCast(userdata.?));
    ctx.col.* = col;
    const va = std.fmt.parseInt(i64, a, 10) catch 0;
    const vb = std.fmt.parseInt(i64, b, 10) catch 0;
    return std.math.order(va, vb);
}

fn fillCellCb(userdata: ?*anyopaque, ctx: *kx.Ctx, args: CellPaintArgs) bool {
    const Ctx = struct { count: *u32 };
    const c: *Ctx = @ptrCast(@alignCast(userdata.?));
    c.count.* += 1;
    ui.paint.fillRect(ctx, args.rect.x, args.rect.y, args.rect.w, args.rect.h, 0xFF0000FF);
    return true;
}

test "table: i18n — the framework label localizes + re-resolves on a locale switch" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Data table\": \"Tabla de datos\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const n = try table(a, &.{"A"}, &.{&.{"1"}}, null, null, .{});
    defer n.deinit();
    try std.testing.expectEqualStrings("Tabla de datos", n.semantics.?.label);
    try i18n.setLocale("en");
    try std.testing.expectEqualStrings("Data table", n.semantics.?.label);
}

test "table: the sort arrow springs 0→180 on a direction flip and snaps on a column switch" {
    var tl = ui.anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    ui.anim.setCurrent(&tl);
    defer ui.anim.setCurrent(null);
    const a = std.testing.allocator;
    const n = try table(a, &.{ "A", "B" }, &.{ &.{ "2", "y" }, &.{ "1", "x" } }, null, null, .{ .sortable = &.{ true, true } });
    defer n.deinit();
    const s = stateOf(n);
    setSort(n, 0, true); // first sort — the arrow appears already up
    try std.testing.expectEqual(@as(f32, 0), s.arrow_rot);
    setSort(n, 0, false); // same-column flip — the rotation animates
    tl.tick(0); // lazy start — arms the spring
    tl.tick(120);
    try std.testing.expect(s.arrow_rot > 0 and s.arrow_rot < 180);
    tl.tick(800); // the spring settles
    try std.testing.expectEqual(@as(f32, 180), s.arrow_rot);
    setSort(n, 1, true); // a new column's arrow starts asc — no unwind
    try std.testing.expectEqual(@as(f32, 0), s.arrow_rot);
}

fn resizeCb(userdata: ?*anyopaque, col: usize, w: f32) void {
    const c: *struct { col: *usize, w: *f32, calls: *u32 } = @ptrCast(@alignCast(userdata.?));
    c.col.* = col;
    c.w.* = w;
    c.calls.* += 1;
}

test "table: header-border drags resize the column (min clamp, callback)" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var last_col: usize = 99;
    var last_w: f32 = 0;
    var calls: u32 = 0;
    var cb_ctx = .{ .col = &last_col, .w = &last_w, .calls = &calls };
    const a = std.testing.allocator;
    const n = try table(a, &.{ "Alpha", "Beta" }, &.{&.{ "1", "x" }}, null, null, .{ .resizable = true, .sortable = &.{ true, true }, .on_col_resize = .{ .fn_ptr = resizeCb, .userdata = &cb_ctx } });
    defer n.deinit();
    const m = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    n.layout(.{ .x = 0, .y = 0, .w = m.w, .h = m.h });
    const s = stateOf(n);
    const w0 = s.col_ws.items[0];
    // Column 0's trailing border sits at x = w0 (no select column).
    router.dispatchPointer(n, .{ .phase = .down, .x = w0, .y = header_h / 2 });
    try std.testing.expectEqual(@as(i32, 0), s.resizing_col);
    router.dispatchPointer(n, .{ .phase = .move, .x = w0 + 40, .y = header_h / 2 });
    try std.testing.expectEqual(@as(f32, w0 + 40), s.user_ws.items[0]);
    try std.testing.expectEqual(@as(i32, 0), s.resizing_col);
    router.dispatchPointer(n, .{ .phase = .up, .x = w0 + 40, .y = header_h / 2 });
    try std.testing.expectEqual(@as(i32, -1), s.resizing_col);
    try std.testing.expectEqual(@as(usize, 0), last_col);
    try std.testing.expectEqual(@as(f32, w0 + 40), last_w);
    try std.testing.expect(calls >= 2); // each change + the settle
    // The resized width feeds the next measure.
    _ = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(@as(f32, w0 + 40), s.col_ws.items[0]);
    // Dragging way left clamps to the column minimum.
    router.dispatchPointer(n, .{ .phase = .down, .x = w0 + 40, .y = header_h / 2 });
    router.dispatchPointer(n, .{ .phase = .move, .x = w0 - 400, .y = header_h / 2 });
    try std.testing.expectEqual(@as(f32, col_min_w), s.user_ws.items[0]);
    router.dispatchPointer(n, .{ .phase = .up, .x = w0 - 400, .y = header_h / 2 });
}

test "table: without resizable a header-border tap still sorts" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try table(a, &.{ "Alpha", "Beta" }, &.{ &.{ "2", "y" }, &.{ "1", "x" } }, null, null, .{ .sortable = &.{ true, true } });
    defer n.deinit();
    const m = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    n.layout(.{ .x = 0, .y = 0, .w = m.w, .h = m.h });
    const s = stateOf(n);
    // A tap just inside column 0's trailing border sorts — the grab
    // zone is only live under `resizable` (x = w0-1: inside col0's cell
    // AND inside the ±4dp border zone).
    const w0 = s.col_ws.items[0];
    router.dispatchPointer(n, .{ .phase = .down, .x = w0 - 1, .y = header_h / 2 });
    router.dispatchPointer(n, .{ .phase = .up, .x = w0 - 1, .y = header_h / 2 });
    try std.testing.expectEqual(@as(i32, 0), s.sort_col);
    try std.testing.expectEqualStrings("1", s.rows.items[0].cells[0]);
    // And a resizable table's border tap does NOT sort (it grabbed a resize).
    const n2 = try table(a, &.{ "Alpha", "Beta" }, &.{ &.{ "2", "y" }, &.{ "1", "x" } }, null, null, .{ .resizable = true, .sortable = &.{ true, true } });
    defer n2.deinit();
    const m2 = n2.measure(.{ .max_w = 2000, .max_h = 2000 });
    n2.layout(.{ .x = 0, .y = 0, .w = m2.w, .h = m2.h });
    const s2 = stateOf(n2);
    router.dispatchPointer(n2, .{ .phase = .down, .x = s2.col_ws.items[0] - 1, .y = header_h / 2 });
    router.dispatchPointer(n2, .{ .phase = .up, .x = s2.col_ws.items[0] - 1, .y = header_h / 2 });
    try std.testing.expectEqual(@as(i32, -1), s2.sort_col); // no sort fired
    try std.testing.expectEqual(@as(f32, 0), s2.user_ws.items[0]); // no drag = no resize
}

test "table: a scrolled big table paints only the visible window" {
    const a = std.testing.allocator;
    const t = theme_mod.light;
    // 200 one-column rows; row 50 is selected — its fill marks it.
    var cells: [200][1][]const u8 = undefined;
    for (&cells, 0..) |*c, i| c.*[0] = try std.fmt.allocPrint(a, "row {d}", .{i});
    defer for (&cells) |*c| a.free(c[0]);
    var rows: [200][]const []const u8 = undefined;
    for (&rows, 0..) |*r, i| r.* = &cells[i];
    const n = try table(a, &.{"Name"}, &rows, null, null, .{ .theme = t });
    defer n.deinit();
    setRowSelected(n, 50, true);
    var r = try golden.Renderer.init(a, 200, 240);
    defer r.deinit();
    // a 3-row viewport: header + rows 50, 51, 52 visible
    n.layout(.{ .x = 0, .y = 0, .w = 180, .h = header_h + 3 * row_h });
    _ = setScrollOffset(n, 50 * row_h); // row 50 lands at the body's top
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    const x: i32 = 170; // right of the cell text, inside the row fill
    // the first visible row is row 50 — its selected fill
    try std.testing.expectEqual(t.colors.surface_variant, f.pixelAt(x, @intFromFloat(header_h + 6)));
    // the next row down is unselected — the container's surface shows
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(x, @intFromFloat(header_h + row_h + 6)));
}
