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
//     it at half alpha, upstream's hover reveal), rotated 180° descending
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
// Remaining deviations: text-only cells (`cell_paint` takes over a cell's
// draw — real child widgets in cells stay out of scope), the arrow's
// rotation snaps (upstream animates it), no column resizing, no
// virtualization (every row paints; the body clip culls them).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
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
    /// The body scrolls under the pinned header; content = the rows region.
    scroll: scroll_mod.ScrollState = .{},
    input: scroll_util.ScrollInput = .{},
    /// Column widths — computed in measure, reused by paint (was: a heap
    /// ArrayList rebuilt per frame). clearRetainingCapacity on mutation.
    col_ws: std.array_list.Managed(f32),
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
        const w = ui.paint.measureText(col, hs.size, true).width + cell_pad_x * 2;
        s.col_ws.append(@max(col_min_w, w)) catch @panic("klaxon: out of memory");
    }
    // Expand with cell content.
    for (s.rows.items) |row| {
        for (row.cells, 0..) |cell, ci| {
            if (ci >= s.col_ws.items.len) break;
            const w = ui.paint.measureText(cell, bs.size, false).width + cell_pad_x * 2;
            if (w > s.col_ws.items[ci]) s.col_ws.items[ci] = w;
        }
    }
}

fn tblMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);

    // Column widths: max of header and cell content widths + padding.
    const ncols = s.columns.items.len;
    if (ncols == 0) return .{ .w = 0, .h = 0 };

    computeColWidths(s);

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

/// A sortable header tap: a new column sorts ascending, the same column
/// toggles the direction.
fn toggleSort(n: *Node, col: usize) void {
    const s = stateOf(n);
    const ci: i32 = @intCast(col);
    s.sort_asc = if (s.sort_col == ci) !s.sort_asc else true;
    s.sort_col = ci;
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
/// points up; descending is the same glyph rotated 180° (upstream
/// animates the rotation — it snaps here).
fn paintSortArrow(ctx: *kx.Ctx, cx: f32, cy: f32, asc: bool, color: Color) void {
    ui.paint.save(ctx);
    if (!asc) {
        ui.paint.translate(ctx, cx, cy);
        ui.paint.rotate(ctx, 180);
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
        var ry = body_y - s.scroll.offset;
        for (s.rows.items, 0..) |row, ri| {
            if (ry >= body_y + body_h) break; // fully below the viewport
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
                        ui.paint.text(ctx, cell, tx, ty, bs.size, false, t.colors.on_surface);
                    }
                    cx += w;
                }

                // Row separator.
                if (ri + 1 < s.rows.items.len) {
                    ui.paint.fillRect(ctx, b.x, ry + row_h, b.w, separator_h, t.colors.outline_variant);
                }
            }
            ry += row_h;
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
        ui.paint.text(ctx, col, tx, ty, hs.size, true, t.colors.on_surface);
        const cii: i32 = @intCast(ci);
        // The sorted column's arrow is always painted (the programmatic
        // setSort can sort a non-`sortable` column — upstream's
        // sortColumnIndex is independent of a column's onSort); an
        // unsorted sortable column's appears on hover at half alpha.
        if (s.sort_col == cii or (isSortable(s, ci) and s.hovered_header_col == cii)) {
            const active = s.sort_col == cii;
            const tw = ui.paint.measureText(col, hs.size, true).width;
            const ax = tx + tw + sort_arrow_gap + sort_arrow_w / 2;
            paintSortArrow(ctx, ax, b.y + header_h / 2, if (active) s.sort_asc else true, ui.paint.withAlphaScaled(t.colors.on_surface, if (active) 1 else 0.5));
        }
        cx += w;
    }
}

// --- Input ---

fn tblPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    const b = n.bounds;

    switch (ev.phase) {
        .down => {
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
            _ = s.input.onPointer(ev, &s.scroll, setScrollOffset, n);
            return false;
        },
        // Hover rows: `.move` only reaches a captured node — the table's
        // own moves go to the scroll gesture, so row tracking lives on the
        // hover phases.
        .hover_move => {
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
            if (s.hovered_row != -1 or s.hovered_header_col != -1) {
                s.hovered_row = -1;
                s.hovered_header_col = -1;
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
    n.allocator.destroy(s);
}

// --- VTable ---

const tbl_vtable = ui.node.VTable{
    .measure = tblMeasure,
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
/// wheel_speed.
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
    };

    // Copy columns.
    for (columns) |col| {
        const buf = try allocator.alloc(u8, col.len + 1);
        @memcpy(buf[0..col.len], col);
        buf[col.len] = 0;
        try s.columns.append(buf[0..col.len :0]);
    }

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

    ui.semantics.attach(node, .{
        .role = .group,
        .label = "Data table",
        .focusable = false,
    });

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
    s.sort_col = @intCast(col);
    s.sort_asc = ascending;
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
    const tw = ui.paint.measureText("Name", t.type_scale.title_small.size, true).width;
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
