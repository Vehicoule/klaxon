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
//
// v1 deviations: no sorting, no selection, no scroll, no sticky header,
// text-only cells.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

pub const TableOptions = struct {
    theme: Theme = theme_mod.light,
    /// When true, tapping a row fires on_row_tap.
    tappable: bool = false,
};

// --- Tokens ---
const header_h: f32 = 56;
const row_h: f32 = 52;
const cell_pad_x: f32 = 16;
const cell_pad_y: f32 = 12;
const col_min_w: f32 = 80;
const separator_h: f32 = 1;

// --- State ---

/// Row-tap callback: receives the tapped row index (0-based, data rows —
/// the header is not tappable).
pub const RowTapCallback = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, row: usize) void,
    userdata: ?*anyopaque,
};

const TableState = struct {
    opts: TableOptions,
    columns: std.array_list.Managed([:0]u8), // owned, null-terminated
    rows: std.array_list.Managed([][:0]u8), // owned cells per row
    row_lens: std.array_list.Managed(usize), // cells per row
    on_row_tap: ?RowTapCallback = null,
    hovered_row: i32 = -1,
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
    for (s.rows.items) |cells| {
        for (cells, 0..) |cell, ci| {
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

    var total_w: f32 = 0;
    for (s.col_ws.items) |w| total_w += w;

    const nrows = s.rows.items.len;
    const total_hgt = header_h + @as(f32, @floatFromInt(nrows)) * row_h;

    return .{
        .w = @max(c.min_w, @min(c.max_w, total_w)),
        .h = @max(c.min_h, @min(c.max_h, total_hgt)),
    };
}

fn tblLayout(_: *Node, _: Rect) void {}

// --- Paint ---

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

    // Header row.
    ui.paint.fillRect(ctx, b.x, b.y, b.w, header_h, t.colors.surface_container_highest);
    var cx = b.x;
    for (s.columns.items, 0..) |col, ci| {
        const w = s.col_ws.items[ci];
        const tx = cx + cell_pad_x;
        const ty = b.y + (header_h - hs.line_height) / 2 + hs.line_height * 0.8;
        ui.paint.text(ctx, col, tx, ty, hs.size, true, t.colors.on_surface);
        cx += w;
    }

    // Data rows.
    var ry = b.y + header_h;
    for (s.rows.items, 0..) |cells, ri| {
        // Row hover state.
        if (s.opts.tappable and s.hovered_row == @as(i32, @intCast(ri))) {
            const layer = theme_mod.stateLayer(t.colors.surface, t.colors.on_surface, t.state.hover);
            ui.paint.fillRect(ctx, b.x, ry, b.w, row_h, layer);
        }

        cx = b.x;
        for (cells, 0..) |cell, ci| {
            if (ci >= s.col_ws.items.len) break;
            const w = s.col_ws.items[ci];
            const tx = cx + cell_pad_x;
            const ty = ry + (row_h - bs.line_height) / 2 + bs.line_height * 0.8;
            ui.paint.text(ctx, cell, tx, ty, bs.size, false, t.colors.on_surface);
            cx += w;
        }

        // Row separator.
        if (ri + 1 < s.rows.items.len) {
            ui.paint.fillRect(ctx, b.x, ry + row_h, b.w, separator_h, t.colors.outline_variant);
        }
        ry += row_h;
    }
}

// --- Input ---

fn tblPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.tappable or s.rows.items.len == 0) return false;
    const b = n.bounds;

    switch (ev.phase) {
        .up => {
            if (ev.y >= b.y + header_h and ev.y <= b.y + header_h + @as(f32, @floatFromInt(s.rows.items.len)) * row_h) {
                const ri = @as(usize, @intCast(@divFloor(@as(i32, @intFromFloat(ev.y - b.y - header_h)), @as(i32, @intFromFloat(row_h)))));
                if (ri < s.rows.items.len) {
                    if (s.on_row_tap) |cb| cb.fn_ptr(cb.userdata, ri);
                    return true;
                }
            }
            return false;
        },
        // Hover rows: `.move` only reaches a captured node — the table
        // never captures, so row tracking lives on the hover phases.
        .hover_move => {
            if (ev.y >= b.y + header_h and ev.y <= b.y + header_h + @as(f32, @floatFromInt(s.rows.items.len)) * row_h) {
                const ri = @as(i32, @intCast(@divFloor(@as(i32, @intFromFloat(ev.y - b.y - header_h)), @as(i32, @intFromFloat(row_h)))));
                if (ri != s.hovered_row) {
                    s.hovered_row = ri;
                    n.markDirty();
                }
            } else if (s.hovered_row != -1) {
                s.hovered_row = -1;
                n.markDirty();
            }
            return false;
        },
        .leave => {
            if (s.hovered_row != -1) {
                s.hovered_row = -1;
                n.markDirty();
            }
            return false;
        },
        else => return false,
    }
}

// --- Deinit ---

fn tblDeinit(n: *Node) void {
    const s = stateOf(n);
    for (s.columns.items) |col| n.allocator.free(col);
    s.columns.deinit();
    for (s.rows.items) |cells| {
        for (cells) |cell| n.allocator.free(cell);
        n.allocator.free(cells);
    }
    s.rows.deinit();
    s.row_lens.deinit();
    s.col_ws.deinit();
    n.allocator.destroy(s);
}

// --- VTable ---

const tbl_vtable = ui.node.VTable{
    .measure = tblMeasure,
    .layout = tblLayout,
    .paint = tblPaint,
    .on_pointer = tblPointer,
    .deinit = tblDeinit,
};

// --- Factory ---

/// Create an M3E data table.
///
/// `columns` — column titles (copied).
/// `rows` — data rows, each an array of cell strings (copied).
/// `on_row_tap` — fired when a row is tapped (only when `opts.tappable`).
/// `opts` — theme, tappable.
pub fn table(
    allocator: std.mem.Allocator,
    columns: []const []const u8,
    rows: []const []const []const u8,
    on_row_tap: ?RowTapCallback,
    opts: TableOptions,
) !*Node {
    const node = try Node.create(allocator, &tbl_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(TableState);
    errdefer allocator.destroy(s);

    s.* = .{
        .opts = opts,
        .columns = std.array_list.Managed([:0]u8).init(allocator),
        .rows = std.array_list.Managed([][:0]u8).init(allocator),
        .row_lens = std.array_list.Managed(usize).init(allocator),
        .on_row_tap = on_row_tap,
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
        try s.rows.append(cells);
        try s.row_lens.append(row.len);
    }

    node.state = @ptrCast(s);

    ui.semantics.attach(node, .{
        .role = .group,
        .label = "Data table",
        .focusable = false,
    });

    return node;
}

// --- Tests ---

test "table: measure includes header + rows" {
    const a = std.testing.allocator;
    const n = try table(a, &.{ "Name", "Age" }, &.{ &.{ "Alice", "30" }, &.{"Bob"} }, null, .{});
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expect(sz.w >= col_min_w * 2);
    try std.testing.expectApproxEqAbs(header_h + row_h * 2, sz.h, 0.001);
}

test "table: tappable fires on_row_tap with the row index" {
    var count: u32 = 0;
    var tapped_row: usize = 999;
    const Ctx = struct { count: *u32, row: *usize };
    var ctx = Ctx{ .count = &count, .row = &tapped_row };
    const cb = RowTapCallback{ .fn_ptr = rowTapCb, .userdata = &ctx };
    const a = std.testing.allocator;
    const n = try table(a, &.{"A"}, &.{ &.{"1"}, &.{"2"} }, cb, .{ .tappable = true });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 200, .h = header_h + row_h * 2 });
    // Tap the 2nd row.
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 50, .y = header_h + row_h + 10, .raw_x = 50, .raw_y = header_h + row_h + 10 });
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(usize, 1), tapped_row);
}

test "golden: the table paints header fill + row text" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try table(a, &.{ "Name" }, &.{&.{ "Alice" }}, null, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 140);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 180, .h = header_h + row_h });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // Header fill.
    try std.testing.expectEqual(t.colors.surface_container_highest, f.pixelAt(20, 20));
    // Header text ink (OnSurface).
    try std.testing.expect(f.countColorIn(.{ .x = 26, .y = 20, .w = 100, .h = 20 }, t.colors.on_surface) > 0);
}

fn rowTapCb(userdata: ?*anyopaque, row: usize) void {
    const Ctx = struct { count: *u32, row: *usize };
    const ctx: *Ctx = @ptrCast(@alignCast(userdata.?));
    ctx.count.* += 1;
    ctx.row.* = row;
}
