// Bench — the benchmark runner + the 9 canonical scenes (Phase 4c.1 + 4c.2).
// Headless by construction: every scene renders through golden.zig's Renderer
// on the RASTER backend — no window, no GPU, deterministic on CI. The same
// scenes + metrics feed the `klaxon bench` command (4c.3) and the
// cross-framework comparison (4c.4/4c.5).
//
//   runScene(scene, allocator) → Metrics
//     builds the scene's widget tree, renders N frames offscreen, collects:
//     fps, frame_time avg/p50/p99, draw_calls_per_frame, rss_mb, ttff_ms,
//     frames_rendered.
//
// Metric definitions:
//   - fps: 1000 / frame_time_avg_ms (the headless loop is unpaced — it renders
//     as fast as the raster backend allows).
//   - frame_time_*: per-frame wall time of tick + layout + paint, measured
//     frames only (the warmup frames are rendered but not counted).
//   - ttff_ms (time to first frame): run start (scene build + ctx create
//     included) → the END of the first completed frame.
//   - draw_calls_per_frame: the kx_skia ABI has no draw-call counter (the C++
//     shim is frozen); estimated as the number of visible nodes painted per
//     frame — the raster backend paints the whole tree every frame and every
//     node's paint callback issues >= 0 kx draw calls. For the virtualized
//     scenes this is the LIVE window (~10 nodes for scroll_10k), matching what
//     a real frame issues.
//   - rss_mb: devtools.readRssMb (Linux /proc/self/status VmRSS, macOS
//     mach_task_basic_info — cross-platform, no new dependency).
const std = @import("std");
const kx = @import("kx.zig");
const sdl = @import("sdl.zig");
const ui = @import("ui.zig");
const widgets = @import("widgets.zig");
const theme_mod = @import("theme.zig");
const golden = @import("golden.zig");
const gallery_mod = @import("gallery.zig");
const devtools = @import("devtools.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const EdgeInsets = ui.layout.EdgeInsets;
const input_mod = ui.input;
const anim_mod = ui.anim;
const state = ui.state;

/// The 9 canonical scenes (ROADMAP 4c.1).
pub const BenchScene = enum {
    hello,
    scroll_10k,
    text_cjk,
    glass_blur,
    anim_100,
    gallery,
    resize,
    input_ime,
    video_playback,

    pub fn name(s: BenchScene) []const u8 {
        return @tagName(s);
    }
};

/// Collected metrics for one scene run (ROADMAP 4c.2).
pub const Metrics = struct {
    fps: f64 = 0,
    frame_time_avg_ms: f64 = 0,
    frame_time_p50_ms: f64 = 0,
    frame_time_p99_ms: f64 = 0,
    draw_calls_per_frame: u64 = 0,
    rss_mb: f64 = 0,
    ttff_ms: f64 = 0, // time to first frame: run start → first completed frame
    frames_rendered: u64 = 0, // every frame painted (warmup + measured)
};

/// How many frames a scene renders and at what size.
pub const RunOptions = struct {
    frames: u64 = 120, // measured frames (after warmup)
    warmup_frames: u64 = 10, // rendered but not counted in the timing stats
    width: i32 = 640,
    height: i32 = 480,
    // --- diagnostics (investigation tooling; NOT part of the JSON report).
    // bench_main wires these to the KLAXON_BENCH_TRACE_DIR /
    // KLAXON_BENCH_PHASES / KLAXON_BENCH_PROFILE env vars. ---
    /// Per-frame CSV trace written to <dir>/<scene>.csv (frame index,
    /// tick/layout/paint ms, relayout flag, damage_valid flag).
    trace_dir: ?[]const u8 = null,
    /// stderr breakdown of the frame into tick / layout / paint phases,
    /// plus the slowest measured frames with their phase split.
    phase_breakdown: bool = false,
    /// After the measured run, a per-node own-paint profile over a few
    /// extra frames: total/max per vtable, offscreen-node accounting
    /// (bounds mapped to window space don't intersect the surface).
    paint_profile: bool = false,
    /// Counterfactual (gallery): hide the ScrollView's content column —
    /// approximates "paint-time culling skipped the off-screen content".
    hide_scroll_content: bool = false,
};

/// The background the frames are cleared with (a neutral dark surface).
const BG: Color = 0x14141CFF;

/// Run a scene headlessly and collect its metrics (default options).
pub fn runScene(scene: BenchScene, allocator: std.mem.Allocator) !Metrics {
    return runSceneWithOpts(scene, allocator, .{});
}

/// Run a scene headlessly with explicit options.
pub fn runSceneWithOpts(scene: BenchScene, allocator: std.mem.Allocator, opts: RunOptions) !Metrics {
    // SDL_GetTicksNS: the monotonic clock the host's frame timing uses (Zig
    // 0.17 removed std.time.nanoTimestamp; SDL is linked everywhere anyway).
    const start_ns = sdl.c.SDL_GetTicksNS();
    var renderer = try golden.Renderer.init(allocator, opts.width, opts.height);
    defer renderer.deinit(); // the ctx dies LAST (defer LIFO)…
    const runner = try SceneRunner.init(allocator, scene, opts);
    defer allocator.destroy(runner); // …after the tree is torn down…
    defer runner.deinit(); // …which dies FIRST (widgets hold ctx-bound resources)
    return runner.run(&renderer, opts, start_ns);
}

// --- the scene runner ---

/// One scene's live state: the tree plus whatever the per-frame tick drives
/// (a scroll offset, animation targets, an input router, a video frame
/// counter). Heap-allocated: the tree holds pointers into it (the list
/// factory's userdata, the process-global timeline/router), so its address
/// must be stable — same pattern as gallery.Gallery.
const SceneRunner = struct {
    allocator: std.mem.Allocator,
    scene: BenchScene,
    root: *Node,
    // --- owned scene state (freed after the tree — widgets hold pointers) ---
    gallery: ?*gallery_mod.Gallery = null, // gallery scene
    timeline: ?anim_mod.Timeline = null, // anim_100 (installed process-global)
    anim_heights: [ANIM_WIDGETS]*state.Signal(f32) = undefined, // anim_100 targets
    anim_colors: [ANIM_WIDGETS]*state.Signal(Color) = undefined,
    router: ?input_mod.InputRouter = null, // input_ime (installed process-global)
    text_field: ?*Node = null, // input_ime
    scroll_list: ?*Node = null, // scroll_10k
    list_ctx: ListItemCtx = undefined, // the virtualized lists' factory ctx
    video: ?*VideoState = null, // video_playback

    fn init(allocator: std.mem.Allocator, scene: BenchScene, opts: RunOptions) !*SceneRunner {
        const r = try allocator.create(SceneRunner);
        errdefer allocator.destroy(r);
        r.* = .{
            .allocator = allocator,
            .scene = scene,
            .root = undefined,
            .list_ctx = .{ .allocator = allocator },
        };
        r.build(opts) catch |err| {
            // Clear the process-globals first (a partially built scene may
            // have installed them; the rest leaks — OOM posture, same as the
            // gallery's buildTree).
            anim_mod.setCurrent(null);
            input_mod.setCurrent(null);
            allocator.destroy(r);
            return err;
        };
        return r;
    }

    fn deinit(r: *SceneRunner) void {
        // The tree dies first: widget deinits touch the process-global timeline
        // (cancelChannel) and input router (releaseNode).
        if (r.gallery) |g| {
            g.deinit(); // owns + destroys the root tree
        } else {
            r.root.deinit();
        }
        if (r.timeline) |*tl| {
            anim_mod.setCurrent(null); // the widgets are gone; nothing may touch it
            tl.deinit();
        }
        if (r.router != null) input_mod.setCurrent(null);
        if (r.scene == .anim_100) {
            // The widgets' Effects already unsubscribed with the tree.
            for (&r.anim_heights) |sig| sig.deinit();
            for (&r.anim_colors) |sig| sig.deinit();
        }
    }

    fn build(r: *SceneRunner, opts: RunOptions) !void {
        _ = opts;
        switch (r.scene) {
            .hello => r.root = try buildHello(r.allocator),
            .scroll_10k => r.root = try buildScrollList(r, 10_000, "scroll_10k — 10 000 items, virtualized (~10 live nodes)"),
            .text_cjk => r.root = try buildTextCjk(r.allocator),
            .glass_blur => r.root = try buildGlassBlur(r.allocator),
            .anim_100 => try buildAnim100(r),
            .gallery => {
                r.gallery = try gallery_mod.Gallery.init(r.allocator);
                r.root = r.gallery.?.root;
            },
            .resize => r.root = try buildResize(r),
            .input_ime => try buildInputIme(r),
            .video_playback => r.root = try buildVideoPlayback(r),
        }
    }

    /// Per-frame scene logic (before layout + paint). Deterministic in `frame`.
    fn tick(r: *SceneRunner, renderer: *golden.Renderer, frame: u64) void {
        switch (r.scene) {
            .hello, .text_cjk, .glass_blur, .gallery => {}, // static trees
            .scroll_10k => {
                // Scroll ~1 item per frame; the virtualization window diffs
                // every frame (items created/destroyed as the window slides).
                const list = r.scroll_list.?;
                const max_off = widgets.list_view.maxScrollOffset(list);
                const off = @mod(@as(f32, @floatFromInt(frame)) * 37.0, max_off + 1.0);
                _ = widgets.list_view.setScrollOffset(list, off);
            },
            .anim_100 => {
                // Retarget every widget (phase-offset per widget) and advance
                // the timeline 8 ms/frame — 100 concurrent spring animations.
                for (&r.anim_heights, 0..) |sig, i| {
                    const phase = @as(f32, @floatFromInt(frame)) * 0.06 + @as(f32, @floatFromInt(i)) * 0.17;
                    sig.set(24 + 16 * @sin(phase));
                }
                for (&r.anim_colors, 0..) |sig, i| {
                    const phase = @as(f32, @floatFromInt(frame)) * 0.06 + @as(f32, @floatFromInt(i)) * 0.17;
                    sig.set(anim_mod.lerpColor(0x3F51B5FF, 0xE91E63FF, (@sin(phase) + 1) / 2));
                }
                r.timeline.?.tick(frame * 8);
            },
            .resize => {
                // Cycle the viewport: resize the surface + relayout the tree.
                const s = RESIZE_SIZES[@as(usize, @intCast(frame % RESIZE_SIZES.len))];
                kx.c.kx_resize(renderer.ctx, s[0], s[1]);
                r.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(s[0]), .h = @floatFromInt(s[1]) });
            },
            .input_ime => {
                const router = &r.router.?;
                if (frame == 0) {
                    // Click the field to focus it (pointer down requests focus).
                    const b = r.text_field.?.bounds;
                    router.dispatchPointer(r.root, .{ .phase = .down, .x = b.x + b.w / 2, .y = b.y + b.h / 2 });
                    router.dispatchPointer(r.root, .{ .phase = .up, .x = b.x + b.w / 2, .y = b.y + b.h / 2 });
                }
                // The IME commit path: text_input events (CJK + emoji); a
                // backspace every 12th frame keeps the buffer bounded.
                if (frame % 12 == 11) {
                    _ = router.dispatchKey(.{ .kind = .key_down, .key = .backspace });
                } else {
                    const s = IME_STRINGS[@as(usize, @intCast(frame % IME_STRINGS.len))];
                    _ = router.dispatchKey(.{ .kind = .text_input, .text = s });
                }
            },
            .video_playback => {
                r.video.?.frame = frame; // the widget regenerates its "frame" at paint
            },
        }
    }

    /// Render `opts.warmup_frames + opts.frames` frames and collect metrics.
    fn run(r: *SceneRunner, renderer: *golden.Renderer, opts: RunOptions, start_ns: u64) !Metrics {
        const bounds = Rect{ .x = 0, .y = 0, .w = @floatFromInt(opts.width), .h = @floatFromInt(opts.height) };
        r.root.layout(bounds);
        if (opts.hide_scroll_content and r.scene == .gallery) {
            // Counterfactual: painting only what the viewport would show
            // (approximates a paint-time cull of the off-screen content).
            const sv = r.gallery.?.refs.scroll_view;
            if (sv.children.items.len > 0) sv.children.items[0].visible = false;
        }
        var frame_times = std.array_list.Managed(f64).init(r.allocator);
        defer frame_times.deinit();
        try frame_times.ensureTotalCapacity(@intCast(opts.frames));
        // Diagnostic collectors (populated only when requested; ~0 cost
        // otherwise — three extra SDL_GetTicksNS calls per frame).
        var tick_times = std.array_list.Managed(f64).init(r.allocator);
        defer tick_times.deinit();
        var layout_times = std.array_list.Managed(f64).init(r.allocator);
        defer layout_times.deinit();
        var paint_times = std.array_list.Managed(f64).init(r.allocator);
        defer paint_times.deinit();
        var trace_csv = std.array_list.Managed(u8).init(r.allocator);
        defer trace_csv.deinit();
        var layout_passes: u64 = 0;
        var ttff_ms: f64 = 0;
        const total = opts.warmup_frames + opts.frames;
        var i: u64 = 0;
        while (i < total) : (i += 1) {
            const t0 = sdl.c.SDL_GetTicksNS();
            r.tick(renderer, i);
            const t1 = sdl.c.SDL_GetTicksNS();
            const relayout = r.root.layout_dirty;
            if (relayout) r.root.layout(bounds); // animated/resized scenes mark it
            const t2 = sdl.c.SDL_GetTicksNS();
            const had_damage = r.root.damage_valid;
            renderer.paint(r.root, BG);
            // The host clears the damage accumulator after painting; mirror
            // that so the trace shows whether the NEXT frame would be a
            // clipped repaint (damage) or a full repaint on the host path.
            r.root.clearDamage();
            const t3 = sdl.c.SDL_GetTicksNS();
            if (i == 0) ttff_ms = @as(f64, @floatFromInt(t3 - start_ns)) / 1e6;
            if (i >= opts.warmup_frames) {
                try frame_times.append(@as(f64, @floatFromInt(t3 - t0)) / 1e6);
                if (opts.phase_breakdown or opts.trace_dir != null) {
                    try tick_times.append(@as(f64, @floatFromInt(t1 - t0)) / 1e6);
                    try layout_times.append(@as(f64, @floatFromInt(t2 - t1)) / 1e6);
                    try paint_times.append(@as(f64, @floatFromInt(t3 - t2)) / 1e6);
                }
            }
            if (relayout) layout_passes += 1;
            if (opts.trace_dir != null) {
                try trace_csv.print("{d},{d:.3},{d:.3},{d:.3},{d:.3},{d},{d}\n", .{
                    i,
                    @as(f64, @floatFromInt(t1 - t0)) / 1e6,
                    @as(f64, @floatFromInt(t2 - t1)) / 1e6,
                    @as(f64, @floatFromInt(t3 - t2)) / 1e6,
                    @as(f64, @floatFromInt(t3 - t0)) / 1e6,
                    @intFromBool(relayout),
                    @intFromBool(had_damage),
                });
            }
        }
        // --- stats over the measured frames ---
        const n = frame_times.items.len;
        var avg: f64 = 0;
        for (frame_times.items) |t| avg += t;
        if (n > 0) avg /= @as(f64, @floatFromInt(n));
        const sorted = try r.allocator.dupe(f64, frame_times.items);
        defer r.allocator.free(sorted);
        std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
        // --- diagnostics output (stderr/files; the JSON report is unchanged) ---
        if (opts.trace_dir) |dir| writeFrameTrace(dir, r.scene, trace_csv.items);
        if (opts.phase_breakdown) {
            printPhaseBreakdown(r.scene, frame_times.items, tick_times.items, layout_times.items, paint_times.items, layout_passes, opts.warmup_frames);
        }
        if (opts.paint_profile) try r.profilePaint(renderer, opts);
        return .{
            .fps = if (avg > 0) 1000.0 / avg else 0,
            .frame_time_avg_ms = avg,
            .frame_time_p50_ms = percentile(sorted, 50),
            .frame_time_p99_ms = percentile(sorted, 99),
            .draw_calls_per_frame = countPaintNodes(r.root),
            .rss_mb = @as(f64, devtools.readRssMb()),
            .ttff_ms = ttff_ms,
            .frames_rendered = total,
        };
    }

    /// Per-node own-paint profile (KLAXON_BENCH_PROFILE): re-implements
    /// Node.paint's traversal (visible / defer_paint / pre-post hooks + the
    /// overlay pass) with a timer around each node's OWN paint work, so the
    /// frame cost attributes to widget types. Also counts nodes whose bounds
    /// — mapped to window space through transformed ancestors — don't
    /// intersect the surface: they are painted anyway (no paint-time culling).
    /// For gallery, own-paint is also bucketed per top-level SECTION (each
    /// child of the ScrollView's content column).
    fn profilePaint(r: *SceneRunner, renderer: *golden.Renderer, opts: RunOptions) !void {
        const a = r.allocator;
        const bounds = Rect{ .x = 0, .y = 0, .w = @floatFromInt(opts.width), .h = @floatFromInt(opts.height) };
        const surf = Rect{ .x = 0, .y = 0, .w = @floatFromInt(opts.width), .h = @floatFromInt(opts.height) };
        var names = try probeVtableNames(a);
        defer names.deinit();
        var stats = std.AutoHashMap(usize, VtStat).init(a);
        defer stats.deinit();
        var overlay_nodes: u64 = 0;
        // Gallery: map each content-column child (a section) to an index so
        // own-paint buckets per section. The section label is the first
        // semantics label found inside it (the section header text).
        var sections = std.AutoHashMap(usize, usize).init(a);
        defer sections.deinit();
        var prof = ProfileCtx{
            .stats = &stats,
            .names = &names,
            .surf = surf,
            .overlay_nodes = &overlay_nodes,
        };
        if (r.scene == .gallery) {
            if (r.gallery.?.refs.scroll_view.children.items.len > 0) {
                const content = r.gallery.?.refs.scroll_view.children.items[0];
                for (content.children.items, 0..) |sec, i| {
                    if (i >= prof.section_ns.len) break;
                    sections.put(@intFromPtr(sec), i) catch break;
                }
                prof.sections = &sections;
            }
        }
        var f: u64 = 0;
        while (f < PROFILE_FRAMES) : (f += 1) {
            // Keep the scene dynamics honest (scroll/anim ticks keep working);
            // these frames are NOT part of the measured set.
            r.tick(renderer, opts.warmup_frames + opts.frames + f);
            if (r.root.layout_dirty) r.root.layout(bounds);
            kx.c.kx_begin_frame(renderer.ctx);
            kx.c.kx_clear(renderer.ctx, BG);
            overlay_nodes = 0;
            profileNode(r.root, renderer.ctx, &prof, null);
            profileOverlay(r.root, renderer.ctx, &prof);
            kx.c.kx_end_frame(renderer.ctx);
        }
        printPaintProfile(r.scene, &stats, PROFILE_FRAMES, overlay_nodes, &prof);
    }
};

const PROFILE_FRAMES: u64 = 8;
const MAX_SECTIONS: usize = 64;

/// Per-vtable paint statistics (own paint only — children excluded).
const VtStat = struct {
    calls: u64 = 0,
    own_ns: u64 = 0,
    max_ns: u64 = 0,
    offscreen_calls: u64 = 0, // bounds outside the surface in window space
    offscreen_ns: u64 = 0,
    label: ?[]const u8 = null, // probe name or semantics role
    sample_text: ?[]const u8 = null, // a node's semantics label (debug hint)
};

/// Shared profiler state threaded through the traversal.
const ProfileCtx = struct {
    stats: *std.AutoHashMap(usize, VtStat),
    names: *std.AutoHashMap(usize, []const u8),
    surf: Rect,
    overlay_nodes: *u64,
    // Section bucketing (gallery): content-child ptr → index.
    sections: ?*std.AutoHashMap(usize, usize) = null,
    section_ns: [MAX_SECTIONS]u64 = @splat(0),
    section_nodes: [MAX_SECTIONS]u64 = @splat(0),
    section_labels: [MAX_SECTIONS]?[]const u8 = @splat(null),
    cur_section: ?usize = null,
};

fn rectsIntersect(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y;
}

/// Record one node's own-paint sample into the vtable stats + section bucket.
fn recordPaint(n: *Node, own_ns: u64, p: *ProfileCtx) void {
    const mapped = n.mapRectToRoot(n.bounds);
    const offscreen = !rectsIntersect(mapped, p.surf);
    const key = @intFromPtr(n.vtable);
    const gop = p.stats.getOrPut(key) catch return;
    const st = gop.value_ptr;
    st.calls += 1;
    st.own_ns += own_ns;
    st.max_ns = @max(st.max_ns, own_ns);
    if (offscreen) {
        st.offscreen_calls += 1;
        st.offscreen_ns += own_ns;
    }
    if (st.label == null) {
        if (p.names.get(key)) |name| {
            st.label = name;
        } else if (n.semantics) |sem| {
            st.label = @tagName(sem.role);
        }
    }
    if (st.sample_text == null) {
        if (n.semantics) |sem| {
            if (sem.label.len > 0) st.sample_text = sem.label;
        }
    }
    if (p.cur_section) |idx| {
        p.section_ns[idx] += own_ns;
        p.section_nodes[idx] += 1;
        if (p.section_labels[idx] == null) {
            if (n.semantics) |sem| {
                if (sem.label.len > 0) p.section_labels[idx] = sem.label;
            }
        }
    }
}

/// profileNode times each node's own paint (vtable.paint + pre/post hooks),
/// then recurses — a timed mirror of Node.paint. Section membership is
/// resolved at entry so descendants of a section root inherit its bucket.
fn profileNode(n: *Node, ctx: *kx.Ctx, p: *ProfileCtx, parent_section: ?usize) void {
    if (!n.visible) return;
    var my_section = parent_section;
    if (p.sections) |set| {
        if (set.get(@intFromPtr(n))) |idx| my_section = idx;
    }
    const t0 = sdl.c.SDL_GetTicksNS();
    n.vtable.paint(n, ctx);
    if (n.vtable.pre_children_paint) |pre| pre(n, ctx);
    const t1 = sdl.c.SDL_GetTicksNS();
    for (n.children.items) |child| {
        if (child.defer_paint) {
            p.overlay_nodes.* += 1;
            continue; // paints in the overlay pass (profiled there)
        }
        profileNode(child, ctx, p, my_section);
    }
    const t2 = sdl.c.SDL_GetTicksNS();
    if (n.vtable.post_children_paint) |post| post(n, ctx);
    const t3 = sdl.c.SDL_GetTicksNS();
    const own_ns: u64 = @intCast((t1 - t0) + (t3 - t2));
    p.cur_section = my_section; // children may have moved the cursor
    recordPaint(n, own_ns, p);
}

/// The popup-overlay pass (golden.paintOverlayPass): paint_overlay hooks run
/// after the whole tree.
fn profileOverlay(n: *Node, ctx: *kx.Ctx, p: *ProfileCtx) void {
    if (!n.visible) return;
    if (n.vtable.paint_overlay) |po| {
        const t0 = sdl.c.SDL_GetTicksNS();
        po(n, ctx);
        const t1 = sdl.c.SDL_GetTicksNS();
        recordPaint(n, @intCast(t1 - t0), p);
    }
    for (n.children.items) |child| profileOverlay(child, ctx, p);
}

/// Build one node per common widget type to learn its vtable pointer →
/// printable name. Probes are deinited immediately (not added to a tree).
/// Unknown vtables still get a semantics-role label or "vt:0x…".
fn probeVtableNames(a: std.mem.Allocator) !std.AutoHashMap(usize, []const u8) {
    var map = std.AutoHashMap(usize, []const u8).init(a);
    errdefer map.deinit();
    const P = struct {
        map: *std.AutoHashMap(usize, []const u8),
        nodes: std.array_list.Managed(*Node),
        fn add(p: *@This(), name: []const u8, node: *Node) void {
            p.map.put(@intFromPtr(node.vtable), name) catch {};
            p.nodes.append(node) catch {};
        }
    };
    var p = P{ .map = &map, .nodes = std.array_list.Managed(*Node).init(a) };
    defer {
        for (p.nodes.items) |n| n.deinit();
        p.nodes.deinit();
    }
    p.add("text", try widgets.text.text(a, "x", .{}));
    p.add("icon", try widgets.icon.icon(a, .star, .{}));
    p.add("container", try widgets.container.container(a, .{}));
    p.add("row", try widgets.layout.row(a, .{}));
    p.add("column", try widgets.layout.column(a, .{}));
    p.add("stack", try widgets.layout.stack(a, .{}));
    p.add("grid", try widgets.layout.grid(a, .{ .columns = 1 }));
    p.add("center", try widgets.layout.center(a));
    p.add("align", try widgets.layout.alignTo(a, .{}));
    p.add("constrained_box", try widgets.layout.constrainedBox(a, .{}));
    p.add("expanded", try widgets.layout.expanded(a, 1));
    p.add("divider", try widgets.divider.divider(a, .{}));
    p.add("card", try widgets.card.card(a, null, .{}));
    p.add("scroll_view", try widgets.scroll_view.scrollView(a, .{}));
    return map;
}

const VtRow = struct { key: usize, st: VtStat };

fn vtRowDesc(_: void, a: VtRow, b: VtRow) bool {
    return a.st.own_ns > b.st.own_ns;
}

fn printPaintProfile(scene: BenchScene, stats: *std.AutoHashMap(usize, VtStat), frames: u64, overlay_nodes: u64, p: *ProfileCtx) void {
    var list = std.array_list.Managed(VtRow).init(std.heap.page_allocator);
    defer list.deinit();
    var it = stats.iterator();
    var total_ns: u64 = 0;
    var total_off_ns: u64 = 0;
    var total_calls: u64 = 0;
    while (it.next()) |e| {
        list.append(.{ .key = e.key_ptr.*, .st = e.value_ptr.* }) catch return;
        total_ns += e.value_ptr.own_ns;
        total_off_ns += e.value_ptr.offscreen_ns;
        total_calls += e.value_ptr.calls;
    }
    std.mem.sort(VtRow, list.items, {}, vtRowDesc);
    std.debug.print(
        "klaxon bench profile {s}: {d} node-paints/frame avg, own-paint {d:.2} ms/frame, {d:.2} ms/frame ({d:.0}%) on nodes fully OFF-surface; {d} deferred nodes/pass\n",
        .{
            scene.name(),
            total_calls / @max(frames, 1),
            @as(f64, @floatFromInt(total_ns)) / 1e6 / @as(f64, @floatFromInt(frames)),
            @as(f64, @floatFromInt(total_off_ns)) / 1e6 / @as(f64, @floatFromInt(frames)),
            if (total_ns > 0) @as(f64, @floatFromInt(total_off_ns)) * 100.0 / @as(f64, @floatFromInt(total_ns)) else 0,
            overlay_nodes,
        },
    );
    std.debug.print("  {s:<22} {s:>8} {s:>10} {s:>10} {s:>10} {s:>10}  sample\n", .{ "vtable", "calls/f", "ms/f", "avg_us", "max_us", "off_ms/f" });
    const show = @min(list.items.len, 30);
    for (list.items[0..show]) |row| {
        const st = row.st;
        const label = st.label orelse "?";
        std.debug.print("  {s:<22} {d:>8} {d:>10.2} {d:>10.2} {d:>10.2} {d:>10.3}  {s}", .{
            label,
            st.calls / @max(frames, 1),
            @as(f64, @floatFromInt(st.own_ns)) / 1e6 / @as(f64, @floatFromInt(frames)),
            @as(f64, @floatFromInt(st.own_ns)) / 1e3 / @as(f64, @floatFromInt(@max(st.calls, 1))),
            @as(f64, @floatFromInt(st.max_ns)) / 1e3,
            @as(f64, @floatFromInt(st.offscreen_ns)) / 1e6 / @as(f64, @floatFromInt(frames)),
            st.sample_text orelse "",
        });
        if (st.label == null) std.debug.print(" vt:0x{x}", .{row.key});
        std.debug.print("\n", .{});
    }
    // Gallery: per-section own-paint table (content-column children).
    if (p.sections != null) {
        const SecRow = struct { idx: usize, ns: u64, nodes: u64, label: []const u8 };
        var secs = std.array_list.Managed(SecRow).init(std.heap.page_allocator);
        defer secs.deinit();
        for (0..MAX_SECTIONS) |i| {
            if (p.section_nodes[i] > 0) {
                secs.append(.{ .idx = i, .ns = p.section_ns[i], .nodes = p.section_nodes[i], .label = p.section_labels[i] orelse "?" }) catch break;
            }
        }
        std.mem.sort(SecRow, secs.items, {}, struct {
            fn f(_: void, x: SecRow, y: SecRow) bool {
                return x.ns > y.ns;
            }
        }.f);
        std.debug.print("  gallery sections by own-paint (ms/frame avg):\n", .{});
        for (secs.items) |s| {
            std.debug.print("    {s:<28.28} nodes {d:>4}/f  {d:>8.2} ms/f\n", .{
                s.label,
                s.nodes / @max(frames, 1),
                @as(f64, @floatFromInt(s.ns)) / 1e6 / @as(f64, @floatFromInt(frames)),
            });
        }
    }
}

/// Write the per-frame CSV trace to <dir>/<scene>.csv (dirs auto-created).
/// C stdio + POSIX mkdir, same pattern as bench_main's writeFile/makePath.
fn writeFrameTrace(dir: []const u8, scene: BenchScene, csv: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.csv", .{ dir, scene.name() }) catch return;
    makePath(std.heap.page_allocator, dir) catch {};
    const path_z = std.heap.page_allocator.dupeSentinel(u8, path, 0) catch return;
    defer std.heap.page_allocator.free(path_z);
    const f = std.c.fopen(path_z, "wb") orelse return;
    defer _ = std.c.fclose(f);
    const header = "frame,tick_ms,layout_ms,paint_ms,total_ms,relayout,had_damage\n";
    _ = std.c.fwrite(header.ptr, 1, header.len, f);
    _ = std.c.fwrite(csv.ptr, 1, csv.len, f);
    std.debug.print("klaxon bench: frame trace → {s}\n", .{path});
}

/// mkdir -p over POSIX mkdir (EEXIST and friends are ignored).
fn makePath(allocator: std.mem.Allocator, dir: []const u8) !void {
    var i: usize = 0;
    while (i < dir.len) : (i += 1) {
        if (dir[i] == '/' or i == dir.len - 1) {
            const prefix_z = try allocator.dupeSentinel(u8, dir[0 .. i + 1], 0);
            defer allocator.free(prefix_z);
            _ = std.c.mkdir(prefix_z, 0o755);
        }
    }
}

/// stderr breakdown: tick / layout / paint phase stats + the slowest frames.
fn printPhaseBreakdown(scene: BenchScene, totals: []const f64, ticks: []const f64, layouts: []const f64, paints: []const f64, layout_passes: u64, warmup: u64) void {
    const a = std.heap.page_allocator;
    std.debug.print("klaxon bench phases {s}: {d} measured frames, {d} relayouts (incl. warmup)\n", .{ scene.name(), totals.len, layout_passes });
    const phases = .{
        .{ "tick  ", ticks },
        .{ "layout", layouts },
        .{ "paint ", paints },
        .{ "total ", totals },
    };
    inline for (phases) |ph| {
        const s = a.dupe(f64, ph[1]) catch return;
        defer a.free(s);
        std.mem.sort(f64, s, {}, std.sort.asc(f64));
        var sum: f64 = 0;
        for (s) |v| sum += v;
        const avg = if (s.len > 0) sum / @as(f64, @floatFromInt(s.len)) else 0;
        std.debug.print("  {s}: avg {d:.3} ms  p50 {d:.3}  p99 {d:.3}  max {d:.3}\n", .{ ph[0], avg, percentile(s, 50), percentile(s, 99), if (s.len > 0) s[s.len - 1] else 0 });
    }
    // The 8 slowest frames with their phase split (indices = trace frame #s).
    const FrameRow = struct { idx: usize, t: f64 };
    var idx_rows = std.array_list.Managed(FrameRow).init(a);
    defer idx_rows.deinit();
    for (totals, 0..) |t, i| idx_rows.append(.{ .idx = i, .t = t }) catch return;
    std.mem.sort(FrameRow, idx_rows.items, {}, struct {
        fn f(_: void, x: FrameRow, y: FrameRow) bool {
            return x.t > y.t;
        }
    }.f);
    const show = @min(idx_rows.items.len, 8);
    std.debug.print("  slowest frames (idx = measured order, +{d} warmup):\n", .{warmup});
    for (idx_rows.items[0..show]) |row| {
        const i = row.idx;
        std.debug.print("    frame {d}: total {d:.3}  tick {d:.3}  layout {d:.3}  paint {d:.3}\n", .{
            i + warmup,
            totals[i],
            if (i < ticks.len) ticks[i] else 0,
            if (i < layouts.len) layouts[i] else 0,
            if (i < paints.len) paints[i] else 0,
        });
    }
}

/// The p-th percentile of an ascending-sorted sample set (nearest-rank — the
/// devtools.p99FrameTimeMs convention). 0 for an empty set.
fn percentile(sorted: []const f64, p: u64) f64 {
    const n = sorted.len;
    if (n == 0) return 0;
    const idx = @min((n * p) / 100, n - 1);
    return sorted[idx];
}

/// Draw-call estimate: the visible nodes painted per frame (see the header).
fn countPaintNodes(n: *Node) u64 {
    if (!n.visible) return 0;
    var count: u64 = 1;
    for (n.children.items) |child| count += countPaintNodes(child);
    return count;
}

// --- scene: hello — a simple centered text widget ---

fn buildHello(a: std.mem.Allocator) !*Node {
    const c = try widgets.layout.center(a);
    c.add(try widgets.text.text(a, "Hello, Klaxon!", .{ .size = 24, .color = 0xFFFFFFFF }));
    return c;
}

// --- scene: scroll_10k — a virtualized list of 10 000 items ---
// ListView virtualizes through widgets/scroll_util.zig (syncItemWindow): only
// the items intersecting the viewport ± margin are alive as child nodes.

const ListItemCtx = struct { allocator: std.mem.Allocator };

/// One list row (ItemFactory: no error union — OOM is fatal, Node.add
/// convention).
fn benchListItem(userdata: ?*anyopaque, index: usize) *Node {
    const ctx: *ListItemCtx = @ptrCast(@alignCast(userdata.?));
    const a = ctx.allocator;
    const card = widgets.container.container(a, .{
        .color = 0x2A2A3EFF,
        .radius = 6,
        .padding = .{ .left = 8, .top = 6, .right = 8, .bottom = 6 },
    }) catch @panic("klaxon: out of memory");
    const row = widgets.layout.row(a, .{ .gap = 8, .cross_align = .center }) catch @panic("klaxon: out of memory");
    row.add(widgets.icon.icon(a, .star, .{ .size = 14, .color = 0xFFD54FFF }) catch @panic("klaxon: out of memory"));
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "Item #{d}", .{index}) catch "Item";
    row.add(widgets.text.text(a, label, .{ .size = 14, .color = 0xFFFFFFFF }) catch @panic("klaxon: out of memory"));
    card.add(row);
    return card;
}

fn buildScrollList(r: *SceneRunner, item_count: usize, title: []const u8) !*Node {
    const a = r.allocator;
    const col = try widgets.layout.column(a, .{ .gap = 12, .padding = 16 });
    col.add(try widgets.text.text(a, title, .{ .size = 14, .color = 0xCCCCCCFF }));
    const list = try widgets.list_view.listView(a, .{
        .item_count = item_count,
        .factory = .{ .fn_ptr = benchListItem, .userdata = &r.list_ctx },
        .item_height = 36,
    });
    r.scroll_list = list;
    // The list needs a bounded viewport (P0 ListView contract).
    const box = try widgets.layout.constrainedBox(a, .{ .max_w = 880, .max_h = 300 });
    box.add(list);
    col.add(box);
    return col;
}

// --- scene: text_cjk — Chinese / Japanese / Korean text (shaping stress) ---

fn buildTextCjk(a: std.mem.Allocator) !*Node {
    const col = try widgets.layout.column(a, .{ .gap = 10, .padding = 24 });
    col.add(try widgets.text.text(a, "text_cjk — CJK shaping (中文 / 日本語 / 한국어)", .{ .size = 14, .color = 0xCCCCCCFF }));
    col.add(try widgets.text.text(a, "你好，世界！Klaxon 是一个用 Zig 编写的 UI 框架。", .{ .size = 22, .color = 0xFFFFFFFF }));
    col.add(try widgets.text.text(a, "こんにちは、世界！Klaxon は Zig で書かれた UI フレームワークです。", .{ .size = 22, .color = 0xFFFFFFFF }));
    col.add(try widgets.text.text(a, "안녕하세요, 세계! Klaxon은 Zig로 작성된 UI 프레임워크입니다.", .{ .size = 22, .color = 0xFFFFFFFF }));
    col.add(try widgets.text.text(a, "混ぜるな危険 — CJK + Latin + emoji 🌍🎉", .{ .size = 18, .color = 0xFFD54FFF }));
    return col;
}

// --- scene: glass_blur — translucent cards over a colorful backdrop ---
// A glass card: an alpha layer (kx_layer_alpha — the blur stand-in; the C ABI
// has no blur primitive) with a translucent tint + frosted content bars. The
// stack uses fit .expand so the deco column measures full width.

const GlassState = struct {
    radius: f32,
    tint: Color,
    alpha: f32,
};

fn glassMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = 300, .h = 110 }); // fixed card size; Align positions it
}
fn glassLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: bounds come from the parent
}
fn glassPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *GlassState = @ptrCast(@alignCast(n.state.?));
    const b = n.bounds;
    // layerAlpha pushes a saveLayer (a save + a layer); the matching restore
    // pops it — the canvas state stays balanced (navigator.zig's pattern).
    ui.paint.layerAlpha(ctx, s.alpha);
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, s.radius, s.tint);
    ui.paint.fillRect(ctx, b.x + 12, b.y + 12, b.w - 24, 6, 0xFFFFFFFF);
    ui.paint.fillRect(ctx, b.x + 12, b.y + 24, (b.w - 24) * 0.62, 6, 0xB3FFFFFF);
    ui.paint.fillRect(ctx, b.x + 12, b.y + 36, (b.w - 24) * 0.4, 6, 0x80FFFFFF);
    ui.paint.restore(ctx);
}
fn glassDeinit(n: *Node) void {
    n.allocator.destroy(@as(*GlassState, @ptrCast(@alignCast(n.state.?))));
}
const glass_vtable = ui.node.VTable{ .measure = glassMeasure, .layout = glassLayout, .paint = glassPaint, .deinit = glassDeinit };

fn glassCard(a: std.mem.Allocator, tint: Color, alpha: f32, radius: f32) !*Node {
    const node = try Node.create(a, &glass_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try a.create(GlassState);
    errdefer a.destroy(s);
    s.* = .{ .radius = radius, .tint = tint, .alpha = alpha };
    node.state = s;
    return node;
}

fn colorPanel(a: std.mem.Allocator, color: Color, h: f32) !*Node {
    const c = try widgets.container.container(a, .{ .color = color, .radius = 12 });
    // An empty ConstrainedBox honors its minimums (a fixed-size spacer); the
    // column's stretch gives it the full width.
    c.add(try widgets.layout.constrainedBox(a, .{ .min_h = h, .max_h = h }));
    return c;
}

fn buildGlassBlur(a: std.mem.Allocator) !*Node {
    // A dark backdrop, bright deco panels, and 3 glass cards floating over
    // them (each in its own Align — the stack shares one alignment).
    const backdrop = try widgets.container.container(a, .{ .color = 0x101426FF });
    const stack = try widgets.layout.stack(a, .{ .fit = .expand, .alignment = .top_left });
    const deco = try widgets.layout.column(a, .{ .gap = 12 });
    deco.add(try colorPanel(a, 0xE91E63FF, 150));
    deco.add(try colorPanel(a, 0x3F51B5FF, 150));
    deco.add(try colorPanel(a, 0x00ACC1FF, 150));
    stack.add(deco);
    const placements = [_]ui.layout.Alignment{ .center, .top_right, .bottom_left };
    const tints = [_]Color{ 0xFFFFFFFF, 0xFFD54FFF, 0x80FF87FF };
    for (placements, tints) |al, tint| {
        const wrap = try widgets.layout.alignTo(a, .{ .alignment = al });
        wrap.add(try glassCard(a, tint, 0.45, 16));
        stack.add(wrap);
    }
    backdrop.add(stack);
    return backdrop;
}

// --- scene: anim_100 — 100 widgets with concurrent animations ---
// A 10×10 grid of AnimatedContainers; each retargets its height + color every
// frame (phase-offset per widget) and the timeline advances 8 ms/frame — 100
// concurrent spring animations, a relayout + repaint of all 100 every frame.

const ANIM_WIDGETS: usize = 100;

fn buildAnim100(r: *SceneRunner) !void {
    const a = r.allocator;
    // The timeline must be installed BEFORE the widgets build: their Effects
    // subscribe at build time (without one they snap to the target).
    r.timeline = anim_mod.Timeline.init(a);
    anim_mod.setCurrent(&r.timeline.?);
    const grid = try widgets.layout.grid(a, .{ .columns = 10, .gap = 8, .padding = 16 });
    var i: usize = 0;
    while (i < ANIM_WIDGETS) : (i += 1) {
        // Per-widget targets (the tick phase-offsets them); the widget keeps
        // animating toward the moving target.
        const h_sig = try state.Signal(f32).init(a, 32);
        errdefer h_sig.deinit();
        const c_sig = try state.Signal(Color).init(a, 0x3F51B5FF);
        errdefer c_sig.deinit();
        const box = try widgets.anim.animatedContainer(a, .{
            .height = h_sig,
            .color = c_sig,
            .radius = 8,
        });
        grid.add(box);
        r.anim_heights[i] = h_sig;
        r.anim_colors[i] = c_sig;
    }
    r.root = grid;
}

// --- scene: gallery — the existing gallery app tree ---
// Gallery.init builds the full showcase (all widgets, dark theme, the 10k list)
// and owns every signal; the runner paints g.root as-is.

// --- scene: resize — a widget tree that handles resize events ---
// The tick cycles the viewport through RESIZE_SIZES: kx_resize (the surface is
// recreated) + a full relayout — layout stress, incl. the virtualized list's
// window re-clamp.

const RESIZE_SIZES = [_][2]i32{
    .{ 640, 480 }, .{ 480, 320 }, .{ 320, 240 }, .{ 800, 600 }, .{ 240, 400 }, .{ 960, 640 },
};

fn buildResize(r: *SceneRunner) !*Node {
    const a = r.allocator;
    const col = try widgets.layout.column(a, .{ .gap = 12, .padding = 16 });
    col.add(try widgets.text.text(a, "resize — the viewport cycles every frame (layout stress)", .{ .size = 14, .color = 0xCCCCCCFF }));
    const cards = try widgets.layout.row(a, .{ .gap = 12 });
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const card = try widgets.container.container(a, .{ .color = 0x2A2A3EFF, .radius = 8, .padding = EdgeInsets.all(12) });
        card.add(try widgets.text.text(a, "Card", .{ .size = 13, .color = 0xFFFFFFFF }));
        cards.add(card);
    }
    col.add(cards);
    const list = try widgets.list_view.listView(a, .{
        .item_count = 2_000,
        .factory = .{ .fn_ptr = benchListItem, .userdata = &r.list_ctx },
        .item_height = 32,
    });
    const box = try widgets.layout.constrainedBox(a, .{ .max_w = 880, .max_h = 200 });
    box.add(list);
    col.add(box);
    return col;
}

// --- scene: input_ime — a text field with input handling ---
// The tick focuses the field (a click on frame 0) then feeds it IME
// text_input commits (CJK + emoji) with a backspace every 12th frame.

const IME_STRINGS = [_][]const u8{
    "こんにちは",
    "世界",
    "안녕하세요",
    "你好，世界",
    "🌍 ",
    "🎉 ",
};

fn buildInputIme(r: *SceneRunner) !void {
    const a = r.allocator;
    r.router = input_mod.InputRouter{};
    input_mod.setCurrent(&r.router.?); // the field's focus request is process-global
    const col = try widgets.layout.column(a, .{ .gap = 12, .padding = 24 });
    col.add(try widgets.text.text(a, "input_ime — text field, IME text_input commits (CJK + emoji)", .{ .size = 14, .color = 0xCCCCCCFF }));
    const tf = try widgets.text_field.textField(a, null, null, null, .{
        .variant = .filled,
        .label = "Message",
        .placeholder = "こんにちは…",
        .supporting = "type CJK / emoji — the buffer follows the caret",
        .theme = theme_mod.light,
    });
    r.text_field = tf;
    col.add(tf);
    r.root = col;
}

// --- scene: video_playback — a widget that updates a texture every frame ---
// A simulated video: every paint generates the frame's pixels (a moving
// gradient + a sliding bar — deterministic in the frame counter) and uploads a
// FRESH texture (kx_image_create copies the pixels; create + draw + destroy
// per frame, like a player presenting decoded frames).

const VideoState = struct {
    w: i32,
    h: i32,
    frame: u64 = 0,
    pixels: []u8, // owned scratch, w*h*4 (RGBA memory order)
};

fn videoMeasure(n: *Node, c: Constraints) Size {
    const s: *VideoState = @ptrCast(@alignCast(n.state.?));
    return c.constrain(.{ .w = @floatFromInt(s.w), .h = @floatFromInt(s.h) });
}
fn videoLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: bounds come from the parent
}
fn videoPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *VideoState = @ptrCast(@alignCast(n.state.?));
    const w: usize = @intCast(s.w);
    const h: usize = @intCast(s.h);
    const bar: usize = @intCast(@mod(s.frame * 3, @as(u64, @intCast(w))));
    for (0..h) |y| {
        for (0..w) |x| {
            const i = (y * w + x) * 4;
            s.pixels[i] = @intCast(x * 255 / (w - 1));
            s.pixels[i + 1] = @intCast(y * 255 / (h - 1));
            s.pixels[i + 2] = 0x60;
            s.pixels[i + 3] = 0xFF;
            if (x >= bar and x < bar + 24) {
                s.pixels[i] = 0xFF;
                s.pixels[i + 1] = 0xFF;
                s.pixels[i + 2] = 0xFF;
            }
        }
    }
    const id = ui.paint.imageCreate(ctx, s.pixels.ptr, s.w, s.h);
    if (id != 0) {
        ui.paint.imageDraw(ctx, id, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h);
        ui.paint.imageDestroy(ctx, id);
    }
}
fn videoDeinit(n: *Node) void {
    const s: *VideoState = @ptrCast(@alignCast(n.state.?));
    n.allocator.free(s.pixels);
    n.allocator.destroy(s);
}
const video_vtable = ui.node.VTable{ .measure = videoMeasure, .layout = videoLayout, .paint = videoPaint, .deinit = videoDeinit };

fn videoWidget(a: std.mem.Allocator, w: i32, h: i32) !*Node {
    const node = try Node.create(a, &video_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try a.create(VideoState);
    errdefer a.destroy(s);
    const pixels = try a.alloc(u8, @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4);
    errdefer a.free(pixels);
    s.* = .{ .w = w, .h = h, .pixels = pixels };
    node.state = s;
    return node;
}

fn buildVideoPlayback(r: *SceneRunner) !*Node {
    const a = r.allocator;
    const col = try widgets.layout.column(a, .{ .gap = 12, .padding = 16 });
    col.add(try widgets.text.text(a, "video_playback — simulated 320×180 stream (texture re-upload every frame)", .{ .size = 14, .color = 0xCCCCCCFF }));
    const v = try videoWidget(a, 320, 180);
    r.video = @ptrCast(@alignCast(v.state.?));
    col.add(v);
    return col;
}

// --- tests ---

/// Tiny options: the tests check that scenes build + run, not the numbers.
const test_opts: RunOptions = .{ .frames = 4, .warmup_frames = 2, .width = 320, .height = 240 };

test "bench: every scene builds and runs without crashing" {
    // Zig 0.17's @typeInfo enum: parallel field_names / field_values arrays.
    const info = @typeInfo(BenchScene).@"enum";
    inline for (info.field_values) |value| {
        const scene: BenchScene = @fromBackingInt(@intCast(value));
        // The gallery's dialogs assert a 280px panel floor (dialog.zig) — run
        // the gallery at its natural window size, like the gallery's own tests.
        const opts = if (scene == .gallery)
            RunOptions{ .frames = test_opts.frames, .warmup_frames = test_opts.warmup_frames, .width = gallery_mod.WINDOW_W, .height = gallery_mod.WINDOW_H }
        else
            test_opts;
        const m = try runSceneWithOpts(scene, std.testing.allocator, opts);
        try std.testing.expectEqual(@as(u64, test_opts.warmup_frames + test_opts.frames), m.frames_rendered);
        try std.testing.expect(m.draw_calls_per_frame > 0);
        try std.testing.expect(m.frame_time_avg_ms >= 0);
        try std.testing.expect(m.frame_time_p50_ms <= m.frame_time_p99_ms);
        try std.testing.expect(m.ttff_ms >= 0);
        try std.testing.expect(m.fps >= 0);
        try std.testing.expect(m.rss_mb >= 0);
    }
}

test "bench: runScene collects metrics with the default options" {
    const m = try runScene(.hello, std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 130), m.frames_rendered); // 10 warmup + 120
    try std.testing.expect(m.draw_calls_per_frame == 2); // Center + Text
    try std.testing.expect(m.frame_time_avg_ms > 0);
}

test "bench: scroll_10k keeps the virtualization window small" {
    const m = try runSceneWithOpts(.scroll_10k, std.testing.allocator, test_opts);
    // ~10 live rows × 4 nodes + chrome — a real frame issues ~45 draw calls,
    // not 10 000.
    try std.testing.expect(m.draw_calls_per_frame < 150);
}

test "bench: anim_100 runs 100 concurrent animations" {
    const m = try runSceneWithOpts(.anim_100, std.testing.allocator, test_opts);
    try std.testing.expect(m.draw_calls_per_frame >= ANIM_WIDGETS); // grid + 100 containers
    try std.testing.expectEqual(@as(u64, test_opts.warmup_frames + test_opts.frames), m.frames_rendered);
}

test "bench: resize cycles the viewport without crashing" {
    const m = try runSceneWithOpts(.resize, std.testing.allocator, test_opts);
    try std.testing.expect(m.draw_calls_per_frame > 0);
    try std.testing.expectEqual(@as(u64, test_opts.warmup_frames + test_opts.frames), m.frames_rendered);
}

test "bench: input_ime types CJK + emoji into the field" {
    const m = try runSceneWithOpts(.input_ime, std.testing.allocator, test_opts);
    try std.testing.expect(m.draw_calls_per_frame > 0);
    try std.testing.expectEqual(@as(u64, test_opts.warmup_frames + test_opts.frames), m.frames_rendered);
}

test "bench: percentile follows the nearest-rank convention" {
    const s = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqual(@as(f64, 1), percentile(&s, 0));
    try std.testing.expectEqual(@as(f64, 6), percentile(&s, 50)); // idx (10*50)/100 = 5
    try std.testing.expectEqual(@as(f64, 10), percentile(&s, 99)); // idx min(9, 9) = 9
    try std.testing.expectEqual(@as(f64, 10), percentile(&s, 100));
    try std.testing.expectEqual(@as(f64, 0), percentile(&[_]f64{}, 99));
}
