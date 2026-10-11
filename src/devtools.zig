// DevTools — real-time performance overlay (Phase 4a.1/4a.3/4a.4 + 4a.5).
// Debug panels painted above the widget tree when enabled: the FPS overlay
// (current / average / p99 over a rolling buffer, frame + paint times,
// backend name, RSS, and a 60-frame FPS bar graph — 4a.1), the frame
// timeline (layout / record / submit / present breakdown, one stacked bar
// per recent frame — 4a.4), and the memory ledger (live tracked bytes per
// subsystem + an RSS history sparkline — 4a.3). Toggled with F12
// (host.zig) or the --devtools flag (main.zig). When disabled the host
// skips recordFrame and paint entirely — zero interference with the normal
// render path (and the golden tests, which run with the overlay off).
const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl.zig");
const kx = @import("kx.zig");
const host_mod = @import("host.zig");
const golden = @import("golden.zig");

const Stats = host_mod.Stats;

/// Rolling buffer length (frame-time samples kept for avg/p99).
pub const HISTORY_LEN: usize = 120;
/// Bars drawn in the FPS graph (the most recent frames).
pub const GRAPH_LEN: usize = 60;

// Panel layout (pixels, origin top-left). Fixed size, anchored top-left.
const PANEL_X: f32 = 8;
const PANEL_Y: f32 = 8;
const PANEL_W: f32 = 280;
const PANEL_H: f32 = 120;
const TEXT_X: f32 = 16;
const LINE_H: f32 = 14;
const LINE_1_Y: f32 = 25; // first text baseline
const GRAPH_X: f32 = 16;
const GRAPH_BOTTOM: f32 = 102;
const GRAPH_H: f32 = 28;
const BAR_W: f32 = 3;
const BAR_PITCH: f32 = 4; // bar + 1px gap
const FOOTER_Y: f32 = 119;

// 0xRRGGBBAA (matches kx_skia.h).
const PANEL_BG: u32 = 0x000000CC;
const PANEL_BORDER: u32 = 0xFFFFFF1A;
const TEXT: u32 = 0xFFFFFFFF;
const TEXT_DIM: u32 = 0xAAAAAAFF;
const GRAPH_GREEN: u32 = 0x66BB6AFF; // frame < 8 ms
const GRAPH_YELLOW: u32 = 0xFFC107FF; // 8 ms <= frame < 16 ms
const GRAPH_RED: u32 = 0xEF5350FF; // frame >= 16 ms
const GRAPH_BASELINE: u32 = 0xFFFFFF33;

/// 16.67 ms = one 60 fps frame: a bar taller than the graph means the frame
/// missed the 60 fps budget (the height is clamped).
const FRAME_60FPS_MS: f32 = 16.67;
/// RSS is re-read at most this often (per paint call).
const RSS_TTL_MS: u64 = 250;

// Frame timeline panel (Phase 4a.4) — below the FPS panel.
const TL_X: f32 = 8;
const TL_Y: f32 = 136;
const TL_W: f32 = 280;
const TL_H: f32 = 110;
const TL_TEXT_X: f32 = 16;
const TL_BARS_X: f32 = 16;
const TL_BARS_W: f32 = 248; // 16.67 ms (the 60 fps budget) maps to full width
const TL_BARS_Y: f32 = 172; // first bar row (TL_Y + 36)
const TL_ROWS: usize = 20; // one stacked bar per recent frame
const TL_ROW_PITCH: f32 = 3; // 2px bar + 1px gap
const TL_BAR_H: f32 = 2;
const TL_BARS_BASE: f32 = TL_BARS_Y + TL_ROWS * TL_ROW_PITCH;
const TL_LEGEND_Y: f32 = 244; // text baseline of the phase legend

// Memory ledger panel (Phase 4a.3) — below the timeline panel.
const MEM_X: f32 = 8;
const MEM_Y: f32 = 254;
const MEM_W: f32 = 280;
const MEM_H: f32 = 132;
const MEM_TEXT_X: f32 = 16;
const MEM_VALUE_X: f32 = 76; // live-MB value column
const MEM_BAR_X: f32 = 116;
const MEM_BAR_W: f32 = 148; // a subsystem at 100% of RSS fills the bar
const MEM_BAR_H: f32 = 6;
const MEM_ROWS_Y: f32 = 292; // first subsystem row (MEM_Y + 38)
const MEM_ROW_H: f32 = 12;
const MEM_SPARK_TOP: f32 = 356; // RSS history sparkline (MEM_Y + 102)
const MEM_SPARK_H: f32 = 20;
const MEM_SPARK_BASE: f32 = MEM_SPARK_TOP + MEM_SPARK_H;

// Phase colors (timeline) — 0xRRGGBBAA (matches kx_skia.h).
const PHASE_LAYOUT: u32 = 0x42A5F5FF; // blue
const PHASE_RECORD: u32 = 0x66BB6AFF; // green
const PHASE_SUBMIT: u32 = 0xFFC107FF; // amber
const PHASE_PRESENT: u32 = 0xAB47BCFF; // purple
const SPARK: u32 = 0x4DD0E1FF; // RSS history sparkline (teal)

pub const DevTools = struct {
    enabled: bool = false,
    /// Ring buffer of frame times (ms). Valid samples are [0..history_count]
    /// until the buffer wraps (writes are sequential from slot 0); once full,
    /// every slot is valid and history_index is the next write slot.
    frame_times: [HISTORY_LEN]f32 = @splat(0),
    history_index: usize = 0,
    history_count: usize = 0,
    // RSS cache (readRssMb is throttled to one read per RSS_TTL_MS). The
    // clock is SDL_GetTicks (ms since SDL_Init) — the host's own clock.
    rss_mb: f32 = 0,
    rss_last_read_ms: ?u64 = null,
    // Frame cadence: wall-clock delta between consecutive paint() calls
    // (i.e. between consecutive rendered frames). FPS is derived from this,
    // NOT from frame_time_ms (which is the render DURATION, not the rate).
    cadence_ms: f32 = 0,
    last_paint_ms: ?u64 = null,
    /// Memory ledger (Phase 4a.3): per-subsystem tracked bytes + RSS history.
    ledger: MemoryLedger = .{},
    /// Frame timeline (Phase 4a.4): per-phase ring of frame samples.
    timeline: FrameTimeline = .{},

    pub fn init() DevTools {
        return .{};
    }

    pub fn toggle(devtools: *DevTools) void {
        devtools.enabled = !devtools.enabled;
    }

    /// Push a frame sample into the ring buffer. The sample is the frame
    /// CADENCE (wall-clock ms between consecutive frames), not the render
    /// duration — FPS must reflect the true frame rate, including paced/idle
    /// time between frames. The render duration is displayed separately (the
    /// "Frame:" line reads stats.frame_time_ms directly).
    pub fn recordFrame(devtools: *DevTools, frame_time_ms: f32) void {
        _ = frame_time_ms; // render duration shown in the Frame line, not here
        const now_ms = sdl.c.SDL_GetTicks();
        if (devtools.last_paint_ms) |last| {
            const delta = now_ms - last;
            if (delta > 0) {
                devtools.cadence_ms = @floatFromInt(delta);
                devtools.pushSample(devtools.cadence_ms);
            }
        }
        devtools.last_paint_ms = now_ms;
    }

    /// Push a raw sample into the ring buffer (oldest overwritten when full).
    /// Used by recordFrame (with the cadence) and by tests (with known values).
    fn pushSample(devtools: *DevTools, ms: f32) void {
        devtools.frame_times[devtools.history_index] = ms;
        devtools.history_index = (devtools.history_index + 1) % HISTORY_LEN;
        if (devtools.history_count < HISTORY_LEN) devtools.history_count += 1;
    }

    /// Mean frame time over the valid samples (0 when empty).
    pub fn avgFrameTimeMs(devtools: *const DevTools) f32 {
        if (devtools.history_count == 0) return 0;
        var sum: f32 = 0;
        for (devtools.frame_times[0..devtools.history_count]) |ft| sum += ft;
        return sum / @as(f32, @floatFromInt(devtools.history_count));
    }

    /// 99th percentile frame time over the valid samples (0 when empty).
    pub fn p99FrameTimeMs(devtools: *const DevTools) f32 {
        const n = devtools.history_count;
        if (n == 0) return 0;
        var sorted: [HISTORY_LEN]f32 = undefined;
        @memcpy(sorted[0..n], devtools.frame_times[0..n]);
        std.mem.sort(f32, sorted[0..n], {}, std.sort.asc(f32));
        const idx = @min((n * 99) / 100, n - 1);
        return sorted[idx];
    }

    /// Paint the overlay: a semi-transparent panel in the top-left corner
    /// with the stats lines, the FPS bar graph, and the toggle hint — plus
    /// the frame timeline and memory ledger panels below it (4a.4 / 4a.3).
    /// Drawn with the plain kx primitives (fill/stroke rect, text) — no
    /// widget tree, no layout pass.
    pub fn paint(devtools: *DevTools, ctx: *kx.Ctx, width: c_int, height: c_int, stats: *Stats) void {
        _ = width; // the panel is fixed-size, anchored top-left
        _ = height;
        // Throttled RSS read (a /proc or mach call per paint would be waste).
        const now_ms = sdl.c.SDL_GetTicks();
        if (devtools.rss_last_read_ms == null or now_ms - devtools.rss_last_read_ms.? >= RSS_TTL_MS) {
            devtools.rss_mb = readRssMb();
            devtools.rss_last_read_ms = now_ms;
            // The ledger shares this throttled read (one OS call per TTL).
            devtools.ledger.sampleRss(devtools.rss_mb);
        }
        // Panel + border.
        kx.c.kx_fill_rrect(ctx, PANEL_X, PANEL_Y, PANEL_W, PANEL_H, 8, PANEL_BG);
        kx.c.kx_stroke_rrect(ctx, PANEL_X, PANEL_Y, PANEL_W, PANEL_H, 8, 1, PANEL_BORDER);
        // Stats lines. The stats still describe the PREVIOUS frame here (the
        // host updates them after present) — one frame of display lag.
        // FPS uses the frame CADENCE (wall-clock delta between frames), not
        // the render duration: during paced/idle rendering the cadence is
        // the true frame rate.
        var buf: [96]u8 = undefined;
        const fps_line = std.fmt.bufPrintSentinel(&buf, "FPS: {d:.1} (avg {d:.1}, p99 {d:.1})", .{
            fpsFromMs(devtools.cadence_ms),
            fpsFromMs(devtools.avgFrameTimeMs()),
            fpsFromMs(devtools.p99FrameTimeMs()),
        }, 0) catch return;
        kx.c.kx_draw_text(ctx, fps_line, TEXT_X, LINE_1_Y, 11, TEXT);
        const frame_line = std.fmt.bufPrintSentinel(&buf, "Frame: {d:.2} ms (paint {d:.2} ms)", .{
            stats.frame_time_ms,
            stats.paint_time_ms,
        }, 0) catch return;
        kx.c.kx_draw_text(ctx, frame_line, TEXT_X, LINE_1_Y + LINE_H, 11, TEXT);
        const backend_line = std.fmt.bufPrintSentinel(&buf, "Backend: {s}", .{stats.backend}, 0) catch return;
        kx.c.kx_draw_text(ctx, backend_line, TEXT_X, LINE_1_Y + 2 * LINE_H, 11, TEXT);
        const rss_line = std.fmt.bufPrintSentinel(&buf, "RSS: {d:.1} MB", .{devtools.rss_mb}, 0) catch return;
        kx.c.kx_draw_text(ctx, rss_line, TEXT_X, LINE_1_Y + 3 * LINE_H, 11, TEXT);
        // FPS graph: one bar per recent frame, oldest → newest left → right.
        // Height = frame_time / 16.67 ms (clamped to the graph height);
        // color = green < 8 ms, yellow < 16 ms, red >= 16 ms.
        const n = @min(GRAPH_LEN, devtools.history_count);
        kx.c.kx_fill_rect(ctx, GRAPH_X, GRAPH_BOTTOM, BAR_PITCH * @as(f32, @floatFromInt(n)) - 1, 1, GRAPH_BASELINE);
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const slot = (devtools.history_index + HISTORY_LEN - n + j) % HISTORY_LEN;
            const ft = devtools.frame_times[slot];
            const bar_h = @max(@min(ft / FRAME_60FPS_MS * GRAPH_H, GRAPH_H), 1.0);
            const color: u32 = if (ft < 8.0) GRAPH_GREEN else if (ft < 16.0) GRAPH_YELLOW else GRAPH_RED;
            kx.c.kx_fill_rect(ctx, GRAPH_X + @as(f32, @floatFromInt(j)) * BAR_PITCH, GRAPH_BOTTOM - bar_h, BAR_W, bar_h, color);
        }
        // Toggle hint.
        kx.c.kx_draw_text(ctx, "F12: toggle devtools", TEXT_X, FOOTER_Y, 10, TEXT_DIM);
        // The two panels below: frame timeline (4a.4) + memory ledger (4a.3).
        devtools.paintTimeline(ctx);
        devtools.paintMemory(ctx);
    }

    /// Frame timeline panel (Phase 4a.4): one stacked bar per recent frame
    /// (layout / record / submit / present), scaled to the 60 fps budget,
    /// plus the per-phase averages and a phase color legend.
    fn paintTimeline(devtools: *DevTools, ctx: *kx.Ctx) void {
        kx.c.kx_fill_rrect(ctx, TL_X, TL_Y, TL_W, TL_H, 8, PANEL_BG);
        kx.c.kx_stroke_rrect(ctx, TL_X, TL_Y, TL_W, TL_H, 8, 1, PANEL_BORDER);
        kx.c.kx_draw_text(ctx, "Frame timeline", TL_TEXT_X, TL_Y + 17, 11, TEXT);
        const a = devtools.timeline.avg();
        var buf: [96]u8 = undefined;
        const avg_line = std.fmt.bufPrintSentinel(&buf, "avg {d:.2} ms  L {d:.2} R {d:.2} S {d:.2} P {d:.2}", .{
            a.totalMs(),
            a.layout_ms,
            a.record_ms,
            a.submit_ms,
            a.present_ms,
        }, 0) catch return;
        kx.c.kx_draw_text(ctx, avg_line, TL_TEXT_X, TL_Y + 31, 10, TEXT_DIM);
        // Stacked bars, oldest frame at the top. Width = phase time / 16.67
        // ms — a bar reaching the right edge spent the whole 60 fps budget.
        const n = @min(TL_ROWS, devtools.timeline.count);
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const s = devtools.timeline.sampleAt(n - 1 - j); // oldest first
            const y = TL_BARS_Y + @as(f32, @floatFromInt(j)) * TL_ROW_PITCH;
            var x = TL_BARS_X;
            const phases = .{
                .{ s.layout_ms, PHASE_LAYOUT },
                .{ s.record_ms, PHASE_RECORD },
                .{ s.submit_ms, PHASE_SUBMIT },
                .{ s.present_ms, PHASE_PRESENT },
            };
            inline for (phases) |ph| {
                const w = @min(ph[0] / FRAME_60FPS_MS * TL_BARS_W, TL_BARS_X + TL_BARS_W - x);
                if (w >= 1.0) {
                    kx.c.kx_fill_rect(ctx, x, y, w, TL_BAR_H, ph[1]);
                    x += w;
                }
            }
        }
        kx.c.kx_fill_rect(ctx, TL_BARS_X, TL_BARS_BASE, TL_BARS_W, 1, GRAPH_BASELINE);
        // Legend: phase color swatches (L = layout, R = record, S = submit,
        // P = present).
        const legend = .{
            .{ PHASE_LAYOUT, "L" },
            .{ PHASE_RECORD, "R" },
            .{ PHASE_SUBMIT, "S" },
            .{ PHASE_PRESENT, "P" },
        };
        var lx = TL_TEXT_X;
        inline for (legend) |entry| {
            kx.c.kx_fill_rect(ctx, lx, TL_LEGEND_Y - 7, 6, 6, entry[0]);
            kx.c.kx_draw_text(ctx, entry[1], lx + 9, TL_LEGEND_Y, 9, TEXT_DIM);
            lx += 34;
        }
    }

    /// Memory ledger panel (Phase 4a.3): one row per subsystem (live tracked
    /// bytes as a share of the process RSS) plus an RSS history sparkline.
    fn paintMemory(devtools: *DevTools, ctx: *kx.Ctx) void {
        const l = &devtools.ledger;
        kx.c.kx_fill_rrect(ctx, MEM_X, MEM_Y, MEM_W, MEM_H, 8, PANEL_BG);
        kx.c.kx_stroke_rrect(ctx, MEM_X, MEM_Y, MEM_W, MEM_H, 8, 1, PANEL_BORDER);
        kx.c.kx_draw_text(ctx, "Memory", MEM_TEXT_X, MEM_Y + 17, 11, TEXT);
        var buf: [96]u8 = undefined;
        const rss_line = std.fmt.bufPrintSentinel(&buf, "RSS {d:.1} MB (peak {d:.1})", .{
            l.rss_mb,
            l.rss_peak_mb,
        }, 0) catch return;
        kx.c.kx_draw_text(ctx, rss_line, MEM_TEXT_X, MEM_Y + 31, 10, TEXT_DIM);
        // Per-subsystem rows: name, live MB, and a bar showing the
        // subsystem's share of the process RSS.
        const rss_bytes: f32 = l.rss_mb * 1024.0 * 1024.0;
        for (0..SUBSYSTEM_COUNT) |i| {
            const sub: Subsystem = @enumFromInt(i);
            const row_y = MEM_ROWS_Y + @as(f32, @floatFromInt(i)) * MEM_ROW_H;
            kx.c.kx_draw_text(ctx, sub.name(), MEM_TEXT_X, row_y + 9, 10, TEXT);
            const live_line = std.fmt.bufPrintSentinel(&buf, "{d:.1}", .{
                @as(f32, @floatFromInt(l.live[i])) / (1024.0 * 1024.0),
            }, 0) catch return;
            kx.c.kx_draw_text(ctx, live_line, MEM_VALUE_X, row_y + 9, 10, TEXT);
            const share: f32 = if (rss_bytes > 0) @as(f32, @floatFromInt(l.live[i])) / rss_bytes else 0;
            const w = @min(share * MEM_BAR_W, MEM_BAR_W);
            if (l.live[i] > 0 and w >= 1.0) {
                kx.c.kx_fill_rect(ctx, MEM_BAR_X, row_y + 2, w, MEM_BAR_H, sub.color());
            }
        }
        // RSS history sparkline (MB, most recent right), scaled to the
        // largest sample in the window.
        const n = @min(GRAPH_LEN, l.rss_count);
        var max_rss: f32 = 0.001;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const slot = (l.rss_index + GRAPH_LEN - n + j) % GRAPH_LEN;
            max_rss = @max(max_rss, l.rss_history[slot]);
        }
        j = 0;
        while (j < n) : (j += 1) {
            const slot = (l.rss_index + GRAPH_LEN - n + j) % GRAPH_LEN;
            const h = @min(@max(l.rss_history[slot] / max_rss * MEM_SPARK_H, 1.0), MEM_SPARK_H);
            kx.c.kx_fill_rect(ctx, MEM_TEXT_X + @as(f32, @floatFromInt(j)) * BAR_PITCH, MEM_SPARK_BASE - h, BAR_W, h, SPARK);
        }
        kx.c.kx_fill_rect(ctx, MEM_TEXT_X, MEM_SPARK_BASE, BAR_PITCH * @as(f32, @floatFromInt(n)) - 1, 1, GRAPH_BASELINE);
    }
};

/// Memory ledger subsystems (Phase 4a.3). The OS reports only the process
/// total (RSS); per-subsystem bytes come from the tracking hooks — every
/// allocation routed through a TrackingAllocator (or recorded by hand via
/// recordAlloc/recordFree) lands in its subsystem's live counter. fonts and
/// images have no Zig-side allocations yet (Skia owns those caches and they
/// are not attributable per subsystem) — their rows show 0 until a hook
/// lands.
pub const Subsystem = enum {
    renderer, // the raster pixel buffer + canvas resources (host-owned)
    fonts,
    images,
    ui, // the widget tree (main.zig routes buildTree through a tracker)
    wasm, // emscripten: the stable-storage allocations

    pub fn name(sub: Subsystem) [*:0]const u8 {
        return switch (sub) {
            .renderer => "renderer",
            .fonts => "fonts",
            .images => "images",
            .ui => "ui",
            .wasm => "wasm",
        };
    }

    pub fn color(sub: Subsystem) u32 {
        return switch (sub) {
            .renderer => 0x42A5F5FF,
            .fonts => 0xAB47BCFF,
            .images => 0x66BB6AFF,
            .ui => 0xFFA726FF,
            .wasm => 0x26C6DAFF,
        };
    }
};

pub const SUBSYSTEM_COUNT: usize = @typeInfo(Subsystem).@"enum".field_names.len;

/// Memory ledger (Phase 4a.3): per-subsystem live/peak bytes from the
/// tracking hooks, plus the process RSS history (sampled by the overlay's
/// throttled readRssMb — one OS call per RSS_TTL_MS, shared with the FPS
/// panel's RSS line).
pub const MemoryLedger = struct {
    /// Currently live tracked bytes per subsystem.
    live: [SUBSYSTEM_COUNT]u64 = @splat(0),
    /// High-water mark of live bytes per subsystem.
    peak: [SUBSYSTEM_COUNT]u64 = @splat(0),
    /// Total alloc calls (incl. resize growth) per subsystem.
    alloc_count: [SUBSYSTEM_COUNT]u64 = @splat(0),
    /// Total free calls (incl. resize shrink) per subsystem.
    free_count: [SUBSYSTEM_COUNT]u64 = @splat(0),
    /// Last sampled process RSS (MB) and its high-water mark.
    rss_mb: f32 = 0,
    rss_peak_mb: f32 = 0,
    /// RSS history ring (MB), GRAPH_LEN samples.
    rss_history: [GRAPH_LEN]f32 = @splat(0),
    rss_index: usize = 0,
    rss_count: usize = 0,

    pub fn recordAlloc(l: *MemoryLedger, sub: Subsystem, bytes: usize) void {
        const i = @intFromEnum(sub);
        l.live[i] += bytes;
        l.peak[i] = @max(l.peak[i], l.live[i]);
        l.alloc_count[i] += 1;
    }

    /// Saturating: an unmatched free can never drive the counter negative.
    pub fn recordFree(l: *MemoryLedger, sub: Subsystem, bytes: usize) void {
        const i = @intFromEnum(sub);
        l.live[i] -|= bytes;
        l.free_count[i] += 1;
    }

    pub fn totalLive(l: *const MemoryLedger) u64 {
        var sum: u64 = 0;
        for (l.live) |v| sum += v;
        return sum;
    }

    /// Push an RSS sample (MB) into the history ring.
    pub fn sampleRss(l: *MemoryLedger, mb: f32) void {
        l.rss_mb = mb;
        l.rss_peak_mb = @max(l.rss_peak_mb, mb);
        l.rss_history[l.rss_index] = mb;
        l.rss_index = (l.rss_index + 1) % GRAPH_LEN;
        if (l.rss_count < GRAPH_LEN) l.rss_count += 1;
    }

    /// Mean RSS (MB) over the valid history samples (0 when empty).
    pub fn avgRssMb(l: *const MemoryLedger) f32 {
        if (l.rss_count == 0) return 0;
        var sum: f32 = 0;
        for (l.rss_history[0..l.rss_count]) |mb| sum += mb;
        return sum / @as(f32, @floatFromInt(l.rss_count));
    }
};

/// Tracking allocator (Phase 4a.3 memory hooks): forwards every operation
/// to a backing allocator and records the byte deltas in the ledger under
/// one subsystem. The caller owns the struct — its address is the
/// Allocator's context, so it must outlive every allocation made through
/// it:
///
///     var tracked: TrackingAllocator = .{ .ledger = &ledger, .subsystem = .ui, .backing = alloc };
///     const a = tracked.allocator();
pub const TrackingAllocator = struct {
    ledger: *MemoryLedger,
    subsystem: Subsystem,
    backing: std.mem.Allocator,

    const vtable = std.mem.Allocator.VTable{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };

    pub fn allocator(ta: *TrackingAllocator) std.mem.Allocator {
        return .{ .ptr = ta, .vtable = &vtable };
    }

    fn rawAlloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const ta: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        const mem = ta.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        ta.ledger.recordAlloc(ta.subsystem, len);
        return mem;
    }

    fn rawResize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const ta: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        if (!ta.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        recordDelta(ta, new_len, memory.len);
        return true;
    }

    fn rawRemap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const ta: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        const mem = ta.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        recordDelta(ta, new_len, memory.len);
        return mem;
    }

    fn rawFree(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const ta: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        ta.ledger.recordFree(ta.subsystem, memory.len);
        ta.backing.rawFree(memory, alignment, ret_addr);
    }

    /// Resize/remap bookkeeping: the live counter tracks the byte delta.
    fn recordDelta(ta: *TrackingAllocator, new_len: usize, old_len: usize) void {
        if (new_len > old_len) {
            ta.ledger.recordAlloc(ta.subsystem, new_len - old_len);
        } else if (old_len > new_len) {
            ta.ledger.recordFree(ta.subsystem, old_len - new_len);
        }
    }
};

/// One frame's phase breakdown (Phase 4a.4), in ms.
pub const PhaseSample = struct {
    layout_ms: f32 = 0, // the layout pass (0 when nothing re-laid-out)
    record_ms: f32 = 0, // begin_frame → end_frame (record into the surface)
    submit_ms: f32 = 0, // readback + texture update + render queue (raster)
    present_ms: f32 = 0, // SDL_RenderPresent — the vsync wait (raster)

    pub fn totalMs(s: PhaseSample) f32 {
        return s.layout_ms + s.record_ms + s.submit_ms + s.present_ms;
    }
};

/// Frame timeline (Phase 4a.4): a ring of per-phase frame samples, recorded
/// by the host once per rendered frame (only while the overlay is enabled).
pub const FrameTimeline = struct {
    samples: [HISTORY_LEN]PhaseSample = @splat(.{}),
    index: usize = 0,
    count: usize = 0,

    pub fn record(tl: *FrameTimeline, layout_ms: f32, record_ms: f32, submit_ms: f32, present_ms: f32) void {
        tl.samples[tl.index] = .{
            .layout_ms = layout_ms,
            .record_ms = record_ms,
            .submit_ms = submit_ms,
            .present_ms = present_ms,
        };
        tl.index = (tl.index + 1) % HISTORY_LEN;
        if (tl.count < HISTORY_LEN) tl.count += 1;
    }

    /// The most recent sample (null when empty).
    pub fn latest(tl: *const FrameTimeline) ?PhaseSample {
        if (tl.count == 0) return null;
        return tl.sampleAt(0);
    }

    /// Per-phase means over the valid samples (all 0 when empty).
    pub fn avg(tl: *const FrameTimeline) PhaseSample {
        if (tl.count == 0) return .{};
        var sum = PhaseSample{};
        for (tl.samples[0..tl.count]) |s| {
            sum.layout_ms += s.layout_ms;
            sum.record_ms += s.record_ms;
            sum.submit_ms += s.submit_ms;
            sum.present_ms += s.present_ms;
        }
        const n = @as(f32, @floatFromInt(tl.count));
        return .{
            .layout_ms = sum.layout_ms / n,
            .record_ms = sum.record_ms / n,
            .submit_ms = sum.submit_ms / n,
            .present_ms = sum.present_ms / n,
        };
    }

    /// The j-th most recent sample (0 = latest). Callers pass j < count.
    fn sampleAt(tl: *const FrameTimeline, j: usize) PhaseSample {
        const slot = (tl.index + HISTORY_LEN - 1 - j) % HISTORY_LEN;
        return tl.samples[slot];
    }
};

/// FPS for a frame time in ms (0 for a non-positive time).
pub fn fpsFromMs(frame_time_ms: f32) f32 {
    return if (frame_time_ms > 0) 1000.0 / frame_time_ms else 0.0;
}

/// Resident set size in MB. Linux: the VmRSS line of /proc/self/status
/// (kB). macOS: mach_task_basic_info's resident_size (bytes). Any other
/// target (emscripten, …): 0.0 — unsupported.
pub fn readRssMb() f32 {
    return switch (builtin.os.tag) {
        .linux => readRssMbLinux(),
        .macos => readRssMbMac(),
        else => 0.0,
    };
}

fn readRssMbLinux() f32 {
    // C stdio (std.fs.openFileAbsolute was removed in Zig 0.17; the C API
    // is what host.zig's dumpPpm already uses — same pattern).
    const f = std.c.fopen("/proc/self/status", "r") orelse return 0.0;
    defer _ = std.c.fclose(f);
    var buf: [8192]u8 = undefined;
    const n = std.c.fread(&buf, 1, buf.len, f);
    if (n == 0) return 0.0;
    const status = buf[0..n];
    const idx = std.mem.indexOf(u8, status, "VmRSS:") orelse return 0.0;
    var i = idx + "VmRSS:".len;
    while (i < status.len and (status[i] == ' ' or status[i] == '\t')) i += 1;
    var kb: u64 = 0;
    while (i < status.len and status[i] >= '0' and status[i] <= '9') : (i += 1) {
        kb = kb * 10 + (status[i] - '0');
    }
    return @as(f32, @floatFromInt(kb)) / 1024.0;
}

// mach_task_basic_info (MACH_TASK_BASIC_INFO = 20, "always 64-bit basic
// info"): resident_size is the RSS in bytes. mach_task_self() is a macro
// over the mach_task_self_ global, hence the extern var. The declarations
// are portable (plain integer types) — the function is only ever CALLED on
// macOS (readRssMb's switch), so no mach symbol is referenced elsewhere.
const mach = struct {
    const mach_port_t = c_uint; // natural_t
    const kern_return_t = c_int;
    const time_value_t = extern struct { seconds: c_int, microseconds: c_int };
    const info_t = extern struct {
        virtual_size: u64, // mach_vm_size_t (LP64)
        resident_size: u64,
        resident_size_max: u64,
        user_time: time_value_t,
        system_time: time_value_t,
        policy: c_int, // policy_t
        suspend_count: c_int, // integer_t
    };
    const MACH_TASK_BASIC_INFO: c_int = 20;
    extern var mach_task_self_: mach_port_t;
    extern fn task_info(target_task: mach_port_t, flavor: c_int, task_info_out: *anyopaque, task_info_out_count: *c_uint) kern_return_t;
};

fn readRssMbMac() f32 {
    var info: mach.info_t = undefined;
    var count: c_uint = @intCast(@sizeOf(mach.info_t) / @sizeOf(c_uint));
    if (mach.task_info(mach.mach_task_self_, mach.MACH_TASK_BASIC_INFO, &info, &count) != 0) return 0.0;
    return @as(f32, @floatFromInt(info.resident_size)) / (1024.0 * 1024.0);
}

test "toggle flips enabled" {
    var dt = DevTools.init();
    try std.testing.expect(!dt.enabled);
    dt.toggle();
    try std.testing.expect(dt.enabled);
    dt.toggle();
    try std.testing.expect(!dt.enabled);
}

test "rolling buffer wraps correctly" {
    var dt = DevTools.init();
    // Fill less than the buffer: sequential slots, count grows.
    for (0..10) |i| dt.pushSample(@floatFromInt(i));
    try std.testing.expectEqual(@as(usize, 10), dt.history_count);
    try std.testing.expectEqual(@as(usize, 10), dt.history_index);
    for (0..10) |i| try std.testing.expectEqual(@as(f32, @floatFromInt(i)), dt.frame_times[i]);
    // Record 200 frames into a fresh 120-slot buffer: only the last 120 are kept.
    var full = DevTools.init();
    for (0..200) |i| full.pushSample(@floatFromInt(i));
    try std.testing.expectEqual(@as(usize, HISTORY_LEN), full.history_count);
    try std.testing.expectEqual(@as(usize, 200 % HISTORY_LEN), full.history_index);
    // Slot s holds the last value v in [80..200) with v % HISTORY_LEN == s.
    for (0..HISTORY_LEN) |s| {
        const expected: f32 = if (s >= 200 - HISTORY_LEN) @floatFromInt(s) else @floatFromInt(s + HISTORY_LEN);
        try std.testing.expectEqual(expected, full.frame_times[s]);
    }
}

test "fps computation: avg and p99 over known frame times" {
    var dt = DevTools.init();
    for (1..101) |i| dt.pushSample(@floatFromInt(i)); // 1.0 .. 100.0 ms
    try std.testing.expectApproxEqAbs(@as(f32, 50.5), dt.avgFrameTimeMs(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), dt.p99FrameTimeMs(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), fpsFromMs(10.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), fpsFromMs(FRAME_60FPS_MS), 0.05);
    // Empty buffer: no samples, no division by zero.
    const empty = DevTools.init();
    try std.testing.expectEqual(@as(f32, 0), empty.avgFrameTimeMs());
    try std.testing.expectEqual(@as(f32, 0), empty.p99FrameTimeMs());
    try std.testing.expectEqual(@as(f32, 0), fpsFromMs(0));
}

test "readRssMb returns a sane value on supported platforms" {
    const mb = readRssMb();
    try std.testing.expect(mb >= 0.0);
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        // /proc/self/status or mach must report a non-zero RSS for the test exe.
        try std.testing.expect(mb > 0.0);
    }
}

test "memory ledger: alloc/free accounting per subsystem" {
    var l = MemoryLedger{};
    l.recordAlloc(.renderer, 1000);
    l.recordAlloc(.renderer, 500);
    l.recordAlloc(.ui, 250);
    try std.testing.expectEqual(@as(u64, 1500), l.live[@intFromEnum(Subsystem.renderer)]);
    try std.testing.expectEqual(@as(u64, 1500), l.peak[@intFromEnum(Subsystem.renderer)]);
    try std.testing.expectEqual(@as(u64, 2), l.alloc_count[@intFromEnum(Subsystem.renderer)]);
    try std.testing.expectEqual(@as(u64, 250), l.live[@intFromEnum(Subsystem.ui)]);
    try std.testing.expectEqual(@as(u64, 1750), l.totalLive());
    // Free shrinks live but never the peak.
    l.recordFree(.renderer, 600);
    try std.testing.expectEqual(@as(u64, 900), l.live[@intFromEnum(Subsystem.renderer)]);
    try std.testing.expectEqual(@as(u64, 1500), l.peak[@intFromEnum(Subsystem.renderer)]);
    try std.testing.expectEqual(@as(u64, 1), l.free_count[@intFromEnum(Subsystem.renderer)]);
    // Saturating free: an unmatched free cannot drive the counter negative.
    l.recordFree(.renderer, 10_000);
    try std.testing.expectEqual(@as(u64, 0), l.live[@intFromEnum(Subsystem.renderer)]);
    try std.testing.expectEqual(@as(u64, 2), l.free_count[@intFromEnum(Subsystem.renderer)]);
}

test "memory ledger: rss history wraps and averages" {
    var l = MemoryLedger{};
    try std.testing.expectEqual(@as(f32, 0), l.avgRssMb());
    l.sampleRss(10.0);
    l.sampleRss(20.0);
    try std.testing.expectEqual(@as(f32, 20.0), l.rss_mb);
    try std.testing.expectEqual(@as(f32, 20.0), l.rss_peak_mb);
    try std.testing.expectEqual(@as(usize, 2), l.rss_count);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), l.avgRssMb(), 0.001);
    // Wrap the ring: only the last GRAPH_LEN samples are kept. 2 explicit
    // samples + GRAPH_LEN+10 more → the write index wraps to 12.
    for (0..GRAPH_LEN + 10) |i| l.sampleRss(@floatFromInt(i));
    try std.testing.expectEqual(@as(usize, GRAPH_LEN), l.rss_count);
    try std.testing.expectEqual(@as(usize, (2 + GRAPH_LEN + 10) % GRAPH_LEN), l.rss_index);
    // Valid window holds values 10 .. GRAPH_LEN+9 → mean (10 + 69) / 2.
    try std.testing.expectApproxEqAbs(@as(f32, 39.5), l.avgRssMb(), 0.001);
    try std.testing.expectEqual(@as(f32, GRAPH_LEN + 9), l.rss_mb);
    try std.testing.expectEqual(@as(f32, GRAPH_LEN + 9), l.rss_peak_mb);
}

test "memory ledger: tracking allocator records byte deltas" {
    var l = MemoryLedger{};
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var ta: TrackingAllocator = .{ .ledger = &l, .subsystem = .ui, .backing = fba.allocator() };
    const alloc = ta.allocator();
    const ui = @intFromEnum(Subsystem.ui);

    var slice = try alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(u64, 100), l.live[ui]);
    try std.testing.expectEqual(@as(u64, 100), l.peak[ui]);
    // Grow in place (FBA: the last allocation, fits) → +150 recorded. The
    // caller owns the slice length: resize does not mutate it.
    try std.testing.expect(alloc.resize(slice, 250));
    slice.len = 250;
    try std.testing.expectEqual(@as(u64, 250), l.live[ui]);
    try std.testing.expectEqual(@as(u64, 250), l.peak[ui]);
    // Shrink → -200 recorded.
    try std.testing.expect(alloc.resize(slice, 50));
    slice.len = 50;
    try std.testing.expectEqual(@as(u64, 50), l.live[ui]);
    // Free → the live counter returns to 0.
    alloc.free(slice);
    try std.testing.expectEqual(@as(u64, 0), l.live[ui]);
    try std.testing.expectEqual(@as(u64, 2), l.alloc_count[ui]); // 100, +150
    try std.testing.expectEqual(@as(u64, 2), l.free_count[ui]); // -200, free
}

test "frame timeline: ring, latest, and per-phase averages" {
    var tl = FrameTimeline{};
    try std.testing.expect(tl.latest() == null);
    try std.testing.expectEqual(@as(f32, 0), tl.avg().totalMs());
    tl.record(1, 2, 3, 4);
    tl.record(2, 4, 6, 8);
    try std.testing.expectEqual(@as(usize, 2), tl.count);
    const latest = tl.latest().?;
    try std.testing.expectEqual(@as(f32, 2), latest.layout_ms);
    try std.testing.expectEqual(@as(f32, 4), latest.record_ms);
    try std.testing.expectEqual(@as(f32, 6), latest.submit_ms);
    try std.testing.expectEqual(@as(f32, 8), latest.present_ms);
    try std.testing.expectEqual(@as(f32, 20), latest.totalMs());
    const a = tl.avg();
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), a.layout_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), a.record_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.5), a.submit_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), a.present_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), a.totalMs(), 0.001);
    // Wrap the ring: 2 samples + HISTORY_LEN more → index wraps to 2, and
    // every slot holds the uniform sample (the first two were overwritten).
    for (0..HISTORY_LEN) |_| tl.record(1, 1, 1, 1);
    try std.testing.expectEqual(@as(usize, HISTORY_LEN), tl.count);
    try std.testing.expectEqual(@as(usize, 2), tl.index);
    try std.testing.expectEqual(@as(f32, 1), tl.latest().?.layout_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), tl.avg().totalMs() / 4, 0.001);
}

test "frame timeline: sampleAt is most-recent-first" {
    var tl = FrameTimeline{};
    tl.record(1, 0, 0, 0);
    tl.record(2, 0, 0, 0);
    tl.record(3, 0, 0, 0);
    try std.testing.expectEqual(@as(f32, 3), tl.sampleAt(0).layout_ms);
    try std.testing.expectEqual(@as(f32, 2), tl.sampleAt(1).layout_ms);
    try std.testing.expectEqual(@as(f32, 1), tl.sampleAt(2).layout_ms);
}

test "golden: devtools timeline + memory panels paint (exact pixels)" {
    const a = std.testing.allocator;
    // Transparent background: the panels' colors render EXACTLY over
    // alpha-0 (src-over preserves src alpha when dst alpha is 0).
    const bg: u32 = 0x00000000;
    var dt = DevTools.init();
    dt.enabled = true;
    // Timeline samples with non-zero phases (all four segments >= 1px wide).
    for (0..10) |_| dt.timeline.record(1.0, 4.0, 0.5, 0.25);
    // Ledger: renderer + ui allocations (drawn as subsystem bars).
    dt.ledger.recordAlloc(.renderer, 4 * 1024 * 1024);
    dt.ledger.recordAlloc(.ui, 2 * 1024 * 1024);

    var r = try golden.Renderer.init(a, 640, 480);
    defer r.deinit();
    var stats = Stats{ .backend = "raster" };

    // Frame 1: paint once so the RSS throttle path runs (the ledger samples
    // the real RSS here).
    kx.c.kx_begin_frame(r.ctx);
    kx.c.kx_clear(r.ctx, bg);
    dt.paint(r.ctx, 640, 480, &stats);
    kx.c.kx_end_frame(r.ctx);

    // Force a known RSS sample, then paint again and verify. The second
    // paint is inside the RSS TTL, so the manual sample survives.
    dt.ledger.sampleRss(64.0);
    kx.c.kx_begin_frame(r.ctx);
    kx.c.kx_clear(r.ctx, bg);
    dt.paint(r.ctx, 640, 480, &stats);
    kx.c.kx_end_frame(r.ctx);
    var f = try r.readback(a);
    defer f.deinit();
    // The FPS overlay still paints (shared panel background).
    try std.testing.expect(f.countColor(PANEL_BG) > 0);
    // Timeline: all four phase segments painted.
    try std.testing.expect(f.countColor(PHASE_LAYOUT) > 0);
    try std.testing.expect(f.countColor(PHASE_RECORD) > 0);
    try std.testing.expect(f.countColor(PHASE_SUBMIT) > 0);
    try std.testing.expect(f.countColor(PHASE_PRESENT) > 0);
    // Memory: the two tracked subsystems' bars + the RSS sparkline painted.
    try std.testing.expect(f.countColor(Subsystem.renderer.color()) > 0);
    try std.testing.expect(f.countColor(Subsystem.ui.color()) > 0);
    try std.testing.expect(f.countColor(SPARK) > 0);
}
