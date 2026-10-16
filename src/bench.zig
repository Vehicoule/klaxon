// Bench — the benchmark runner + the canonical scene catalogue (Phase 4c.1
// + 4c.2 + the 4c.6 catalogue: docs/specs/bench-scenes.md — 33 scenes).
// Headless by construction: every scene renders through golden.zig's Renderer
// on the RASTER backend — no window, no GPU, deterministic on CI. The same
// scenes + metrics feed the `klaxon bench` command (4c.3) and the
// cross-framework comparison (4c.4/4c.5).
//
//   runScene(scene, allocator) → Metrics
//     builds the scene's widget tree, renders N frames offscreen, collects:
//     fps, frame_time avg/p50/p99/p999, jank_frames/jank_pct,
//     draw_calls_per_frame, rss_mb, ttff_ms, frames_rendered + scene extras.
//
// Metric definitions:
//   - fps: 1000 / frame_time_avg_ms (the headless loop is unpaced — it renders
//     as fast as the raster backend allows).
//   - frame_time_*: per-frame wall time of tick + layout + paint, measured
//     frames only (the warmup frames are rendered but not counted).
//   - jank: a frame is jank when frame_ms > 16.67 (the 60 Hz budget —
//     Macrobenchmark/JankStats convention, schema v2).
//   - ttff_ms (time to first frame): run start (scene build + ctx create
//     included) → the END of the first completed frame.
//   - draw_calls_per_frame: real submitted canvas ops (kx_frame_draw_ops,
//     0.14.0 — counted on the emit path, a layer's contents count once at
//     replay). `fps` is the unthrottled work rate; `presented_fps` is the
//     real presented rate — windowed only (0 headless).
//     shim is frozen); estimated as the number of visible nodes painted per
//     frame — mirrors Node.paint's off-surface culling (a node's paint
//     callback issues >= 0 kx draw calls). For the virtualized scenes this
//     is the LIVE window (~10 nodes for scroll_10k); for retained scenes it
//     is the on-surface fraction, matching what a real frame issues. For
//     ramp scenes (one node painting N items) it is the final step's N.
//   - rss_mb: devtools.readRssMb (Linux /proc/self/status VmRSS, macOS
//     mach_task_basic_info — cross-platform, no new dependency).
//   - extra: per-scene fields (schema v2) — op_ms (list_ops), ramp[] +
//     n_max_60fps (ramp scenes), latency_ms/latency_frames (input_latency),
//     nodes_per_frame (semantics_build), teardown_ms/resume_ms (app_switch).
const std = @import("std");
const builtin = @import("builtin");
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

/// getenv is a linear environ scan — never call it per frame inside a tick.
/// `name` is comptime so each call site gets its own cached answer.
fn latchEnv(comptime name: [*:0]const u8) bool {
    const S = struct {
        var v: ?bool = null;
    };
    if (S.v == null) S.v = std.c.getenv(name) != null;
    return S.v.?;
}
const EdgeInsets = ui.layout.EdgeInsets;
const input_mod = ui.input;
const anim_mod = ui.anim;
const state = ui.state;

/// The canonical scene catalogue (ROADMAP 4c.1 + 4c.6). Enum names are the
/// contract — the spec's catalogue tables write them snake_case, so the JSON
/// report emits them verbatim (the spec's "kebab_case in JSON/CLI" note is
/// reconciled by also accepting kebab on the CLI — see bench_main.zig).
pub const BenchScene = enum {
    // the original 9 (4c.1)
    hello,
    scroll_10k,
    text_cjk,
    glass_blur,
    anim_100,
    gallery,
    resize,
    input_ime,
    video_playback,
    // family A — list_ops (krausest js-framework-benchmark, native adaptation)
    list_create_1k,
    list_replace_1k,
    list_update_10th,
    list_swap_rows,
    list_remove_row,
    list_clear_1k,
    // family B — ramp (MotionMark methodology, stepped)
    shapes_ramp,
    paths_ramp,
    text_ramp,
    images_ramp,
    // family C — stress (known-divergence scenarios)
    overdraw_stack,
    elevation_grid,
    relayout_storm,
    mount_churn,
    scroll_anim,
    text_rich,
    chart_live,
    clip_path,
    theme_switch,
    backdrop_scroll,
    // family D — system (non-paint paths)
    input_latency,
    pointer_storm,
    semantics_build,
    app_switch,

    pub fn name(s: BenchScene) []const u8 {
        return @tagName(s);
    }

    /// Family A: the op is timed once (extra.op_ms); frame metrics are
    /// collected over the 60 frames after it — runListOp drives these.
    pub fn isListOp(s: BenchScene) bool {
        return switch (s) {
            .list_create_1k, .list_replace_1k, .list_update_10th,
            .list_swap_rows, .list_remove_row, .list_clear_1k => true,
            else => false,
        };
    }

    /// Family B: stepped ramp — 20 measured frames per step (runRamp).
    pub fn isRamp(s: BenchScene) bool {
        return switch (s) {
            .shapes_ramp, .paths_ramp, .text_ramp, .images_ramp => true,
            else => false,
        };
    }
};

/// The ramp step sizes (spec family B — MotionMark methodology).
pub const RAMP_STEPS = [_]u64{ 10, 25, 50, 100, 200, 400, 800, 1600, 3200 };
/// Measured frames per ramp step (spec); capped by opts.frames in tests.
const RAMP_MEASURED: u64 = 20;
/// Measured frames after a list op (spec); capped by opts.frames in tests.
const LIST_OP_MEASURED: u64 = 60;
/// 60 Hz frame budget — a frame is jank above it (schema v2).
const JANK_MS: f64 = 16.67;

/// One ramp step result (extra.ramp[]).
pub const RampPoint = struct { n: u64, p50_ms: f64 };

/// Per-scene extra fields (schema v2). Missing optionals serialize as null.
pub const Extra = struct {
    op_ms: ?f64 = null, // list_ops: wall time of the operation itself
    ramp: [RAMP_STEPS.len]RampPoint = undefined,
    ramp_len: usize = 0, // ramp scenes: extra.ramp[0..ramp_len]
    n_max_60fps: ?u64 = null, // largest ramp step with p50 <= 16.67 ms
    latency_ms: ?f64 = null, // input_latency: event → response paint
    latency_frames: ?u64 = null,
    nodes_per_frame: ?u64 = null, // semantics_build
    teardown_ms: ?f64 = null, // app_switch (avg over the run's cycles)
    resume_ms: ?f64 = null,
};

/// Collected metrics for one scene run (ROADMAP 4c.2 + schema v2).
pub const Metrics = struct {
    fps: f64 = 0, // unthrottled work rate (1000/avg work ms) — NOT presented fps
    /// Real presented frames/s — windowed only (wall clock over the measured
    /// window, vsync waits included). 0 on headless: no presentation exists.
    presented_fps: f64 = 0,
    frame_time_avg_ms: f64 = 0,
    frame_time_p50_ms: f64 = 0,
    frame_time_p99_ms: f64 = 0,
    frame_time_p999_ms: f64 = 0,
    jank_frames: u64 = 0, // frames > 16.67 ms
    jank_pct: f64 = 0,
    draw_calls_per_frame: u64 = 0,
    rss_mb: f64 = 0,
    ttff_ms: f64 = 0, // time to first frame: run start → first completed frame
    frames_rendered: u64 = 0, // every frame painted (warmup + measured)
    extra: Extra = .{},
};

/// How many frames a scene renders and at what size.
pub const RunOptions = struct {
    frames: u64 = 120, // measured frames (after warmup)
    warmup_frames: u64 = 10, // rendered but not counted in the timing stats
    width: i32 = 640,
    height: i32 = 480,
    // --- diagnostics (investigation tooling; NOT part of the JSON report).
    // bench_main wires these to the KLAXON_BENCH_TRACE_DIR /
    // KLAXON_BENCH_PHASES / KLAXON_BENCH_PROFILE env vars. They drive the
    // standard runFrames loop — list_ops + ramp scenes have their own run
    // loops and skip diagnostics. ---
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
    /// Cap the ramp ladder (tests use 2; production runs the full 9 steps).
    ramp_steps: usize = RAMP_STEPS.len,
    /// Tier-2 mode: scenes render into a real SDL window on a real GPU
    /// backend — frame begin blocks on drawable backpressure (vsync), so
    /// the paced wait is subtracted from the measured work (see
    /// golden.Renderer.last_frame_wait_ns; the other runners report the
    /// same work-only fps through FrameTiming-style spans).
    windowed: bool = false,
    /// kx_backend for the windowed ctx (AUTO = the platform chain).
    backend: kx.c.kx_backend = kx.c.KX_BACKEND_AUTO,
};

/// The background the frames are cleared with (a neutral dark surface).
const BG: Color = 0x14141CFF;

/// Run a scene headlessly and collect its metrics (default options).
pub fn runScene(scene: BenchScene, allocator: std.mem.Allocator) !Metrics {
    return runSceneWithOpts(scene, allocator, .{});
}

/// The shared tier-2 window: one SDL window serves the whole scene run —
/// per-scene kx ctxs still come and go (fresh GPU state per scene = the
/// headless run's isolation), but respawning a real window per scene would
/// spam the compositor.
var bench_window: ?*sdl.c.SDL_Window = null;
var bench_gl: sdl.c.SDL_GLContext = null; // Android GLES: kept for the run's life

const WindowedSurface = struct { ctx: *kx.Ctx, w: i32, h: i32 };

fn windowedSurface(opts: RunOptions) !WindowedSurface {
    const is_android = builtin.os.tag == .linux and builtin.abi == .android;
    if (bench_window == null) {
        if (!sdl.c.SDL_Init(sdl.c.SDL_INIT_VIDEO)) return error.SdlInit;
        var win_w: c_int = opts.width;
        var win_h: c_int = opts.height;
        if (is_android) {
            // Ganesh GLES binds to the current EGL context — the ES 3.0
            // attributes must be set before the window, and the context
            // created + made current before kx_create (host.zig's order).
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_MAJOR_VERSION), 3);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_MINOR_VERSION), 0);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_PROFILE_MASK), sdl.c.SDL_GL_CONTEXT_PROFILE_ES);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_DOUBLEBUFFER), 1);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_DEPTH_SIZE), 0);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_STENCIL_SIZE), 8);
            // Fixed sizes lock the activity's orientation by aspect — ask
            // for the display's natural size (the surface is full-panel
            // anyway; the ctx reports its real pixels below).
            const display = sdl.c.SDL_GetPrimaryDisplay();
            if (display != 0) {
                if (sdl.c.SDL_GetCurrentDisplayMode(display)) |mode| {
                    if (mode.*.w > 0 and mode.*.h > 0) {
                        win_w = mode.*.w;
                        win_h = mode.*.h;
                    }
                }
            }
        }
        const flags: u64 = if (builtin.os.tag == .macos)
            sdl.c.SDL_WINDOW_METAL
        else if (is_android)
            // OPENGL only — not FULLSCREEN: immersive-sticky's confirmation
            // dialog steals focus on headless emulators (host.zig's comment).
            sdl.c.SDL_WINDOW_OPENGL
        else
            0;
        // No HIGH_PIXEL_DENSITY: the bench viewport is 640×480 device pixels
        // on every tier — Retina would silently quadruple the raster work
        // vs the headless runs (and vs the other runners' 640×480 windows).
        const win = sdl.c.SDL_CreateWindow("klaxon bench", win_w, win_h, flags) orelse {
            sdl.c.SDL_Log("klaxon bench: SDL_CreateWindow failed: %s", sdl.c.SDL_GetError());
            return error.SdlWindow;
        };
        bench_window = win;
        if (is_android) {
            const gl = sdl.c.SDL_GL_CreateContext(win) orelse {
                sdl.c.SDL_Log("klaxon bench: SDL_GL_CreateContext failed: %s", sdl.c.SDL_GetError());
                return error.SdlGlContext;
            };
            bench_gl = gl;
            if (!sdl.c.SDL_GL_MakeCurrent(win, gl)) {
                sdl.c.SDL_Log("klaxon bench: SDL_GL_MakeCurrent failed: %s", sdl.c.SDL_GetError());
                return error.SdlGlCurrent;
            }
            _ = sdl.c.SDL_GL_SetSwapInterval(1); // eglSwapBuffers paces the run
        }
    }
    // The ctx's drawable dims: the display's pixels on Android (the EGL
    // surface is always full-panel), the requested viewport elsewhere.
    var cw: c_int = opts.width;
    var ch: c_int = opts.height;
    if (is_android) {
        var pw: c_int = 0;
        var ph: c_int = 0;
        if (sdl.c.SDL_GetWindowSizeInPixels(bench_window, &pw, &ph) and pw > 0 and ph > 0) {
            cw = pw;
            ch = ph;
        }
    }
    const ctx = kx.create(@ptrCast(bench_window.?), cw, ch, opts.backend) orelse {
        sdl.c.SDL_Log("klaxon bench: kx_create {d}x{d} failed", cw, ch);
        return error.KxCreateFailed;
    };
    resolved_backend = kx.c.kx_backend_name(kx.c.kx_backend_of(ctx));
    std.debug.print("klaxon bench: windowed ctx {d}x{d} on {s}\n", .{ cw, ch, resolved_backend.? });
    return .{ .ctx = ctx, .w = cw, .h = ch };
}

/// The backend the last windowed ctx resolved to (AUTO picks per platform);
/// nil until the first windowed scene — read by formatReport callers.
pub var resolved_backend: ?[*:0]const u8 = null;

/// Run a scene headlessly with explicit options.
pub fn runSceneWithOpts(scene: BenchScene, allocator: std.mem.Allocator, opts: RunOptions) !Metrics {
    // SDL_GetTicksNS: the monotonic clock the host's frame timing uses (Zig
    // 0.17 removed std.time.nanoTimestamp; SDL is linked everywhere anyway).
    const start_ns = sdl.c.SDL_GetTicksNS();
    var renderer = if (opts.windowed) blk: {
        const surf = try windowedSurface(opts);
        break :blk golden.Renderer.initWithCtx(allocator, surf.ctx, surf.w, surf.h);
    } else try golden.Renderer.init(allocator, opts.width, opts.height);
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
    router: ?input_mod.InputRouter = null, // input_ime + input_latency (installed process-global)
    text_field: ?*Node = null, // input_ime
    scroll_list: ?*Node = null, // scroll_10k + list_ops + scroll_anim + backdrop_scroll
    pulse_overlay: ?*Node = null, // scroll_anim's live pulse layer
    list_empty_text: ?*Node = null, // list_ops empty-state ("No rows")
    list_ctx: ListItemCtx = undefined, // the virtualized lists' factory ctx
    video: ?*VideoState = null, // video_playback
    // --- 4c.6 catalogue state ---
    bounds: Rect = .{}, // the run viewport (ticks that relayout mid-frame)
    drive: Drive = .{}, // shared frame clock for paint-animated scene nodes
    list_ops: ListOpsCtx = undefined, // family A model (labels + count)
    pulse_ctx: PulseItemCtx = undefined, // scroll_anim item factory ctx
    ramp_node: ?*Node = null, // family B workhorse node
    storm_col: ?*Node = null, // relayout_storm (relaid out every frame)
    churn_parent: ?*Node = null, // mount_churn pool
    churn_next: u64 = 0,
    theme_flip: ThemeFlip = .{}, // theme_switch palette flag
    theme_nodes: std.array_list.Managed(*Node), // theme_switch: every themed node (flip invalidates them)
    lat_node: ?*Node = null, // input_latency responder
    lat_ev: u64 = std.math.maxInt(u64), // frame to inject the event on
    lat_event_ns: u64 = 0,
    storm_rng: u64 = 0x9E3779B97F4A7C15, // pointer_storm LCG (deterministic)
    app_slot: ?*Node = null, // app_switch: parent of the swappable app subtree
    app_root: ?*Node = null, // app_switch: the swapped subtree (null while paused)
    resume_t0: u64 = 0, // set at resume-build start; closed after the frame paints
    switch_teardown_ms: f64 = 0,
    switch_teardowns: u64 = 0,
    switch_resume_ms: f64 = 0,
    switch_resumes: u64 = 0,
    windowed: bool = false, // tier-2 mode — input_latency routes through SDL
    extra: Extra = .{}, // scene extras, merged into Metrics at the end

    fn init(allocator: std.mem.Allocator, scene: BenchScene, opts: RunOptions) !*SceneRunner {
        const r = try allocator.create(SceneRunner);
        errdefer allocator.destroy(r);
        r.* = .{
            .allocator = allocator,
            .scene = scene,
            .root = undefined,
            .list_ctx = .{ .allocator = allocator },
            .list_ops = .{ .allocator = allocator },
            .pulse_ctx = .{ .allocator = allocator, .drive = &r.drive },
            .theme_nodes = std.array_list.Managed(*Node).init(allocator),
            .windowed = opts.windowed,
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
        r.theme_nodes.deinit();
    }

    fn build(r: *SceneRunner, opts: RunOptions) !void {
        _ = opts;
        switch (r.scene) {
            .hello => r.root = try buildHello(r.allocator),
            .scroll_10k => r.root = try buildScrollList(r, 10_000, "scroll_10k — 10 000 items, virtualized (~10 live nodes)"),
            .text_cjk => {
                r.root = try buildTextCjk(r.allocator);
                r.root.retained = true;
                r.root.retained_bg = BG;
            },
            .glass_blur => {
                r.root = try buildGlassBlur(r.allocator);
                r.root.retained = true;
                r.root.retained_bg = BG;
            },
            .anim_100 => try buildAnim100(r),
            .gallery => {
                r.gallery = try gallery_mod.Gallery.init(r.allocator);
                r.root = r.gallery.?.root;
                // The catalogue is static in this scene (no input — the
                // showcase animations only run on interaction): mark the
                // whole tree retained so it rasterizes once and re-blits —
                // the whole-window backingstore idiom (QSG item textures).
                r.root.retained = true;
                r.root.retained_bg = BG;
            },
            .resize => r.root = try buildResize(r),
            .input_ime => try buildInputIme(r),
            .video_playback => r.root = try buildVideoPlayback(r),
            // family A — list_ops (the op runs inside runListOp, not the tick)
            .list_create_1k => try buildListOps(r, true),
            .list_replace_1k, .list_update_10th, .list_swap_rows, .list_remove_row, .list_clear_1k => try buildListOps(r, false),
            // family B — ramp (one workhorse node per kind; runRamp drives it)
            .shapes_ramp => r.root = try buildRamp(r, .shapes),
            .paths_ramp => r.root = try buildRamp(r, .paths),
            .text_ramp => r.root = try buildRamp(r, .text),
            .images_ramp => r.root = try buildRamp(r, .images),
            // family C — stress
            .overdraw_stack => {
                // Static composition: retain the whole frame — one opaque
                // Src blit per frame (the retained-backingstore idiom).
                r.root = try buildOverdraw(r.allocator);
                r.root.retained = true;
                r.root.retained_bg = BG;
            },
            .elevation_grid => r.root = try buildElevationGrid(r),
            .relayout_storm => r.root = try buildRelayoutStorm(r),
            .mount_churn => r.root = try buildMountChurn(r),
            .scroll_anim => r.root = try buildScrollAnim(r),
            .text_rich => r.root = try buildTextRich(r.allocator),
            .chart_live => r.root = try buildChartLive(r),
            .clip_path => r.root = try buildClipPath(r),
            .theme_switch => {
                // Dirty only on the 30-frame flips: retain the frame so the
                // 29 in-between frames re-blit while flip frames re-rasterize.
                r.root = try buildThemeSwitch(r);
                r.root.retained = true;
                r.root.retained_bg = BG;
            },
            .backdrop_scroll => r.root = try buildBackdropScroll(r),
            // family D — system
            .input_latency => try buildInputLatency(r),
            .pointer_storm => r.root = try buildPointerStorm(r.allocator),
            .semantics_build => r.root = try buildSemanticsScene(r.allocator),
            .app_switch => try buildAppSwitch(r),
        }
    }

    /// Per-frame scene logic (before layout + paint). Deterministic in `frame`.
    /// List-op and ramp scenes have their own run loops and never reach here.
    fn tick(r: *SceneRunner, renderer: *golden.Renderer, frame: u64) void {
        r.drive.frame = frame; // the shared scene clock (paint-animated nodes)
        switch (r.scene) {
            .hello, .text_cjk, .glass_blur, .gallery, .overdraw_stack, .text_rich => {}, // static trees
            .list_create_1k, .list_replace_1k, .list_update_10th, .list_swap_rows, .list_remove_row, .list_clear_1k, .shapes_ramp, .paths_ramp, .text_ramp, .images_ramp => {},
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
                const prof = latchEnv("KLAXON_BENCH_PHASES");
                const ta = sdl.c.SDL_GetTicksNS();
                for (&r.anim_heights, 0..) |sig, i| {
                    const phase = @as(f32, @floatFromInt(frame)) * 0.06 + @as(f32, @floatFromInt(i)) * 0.17;
                    sig.set(24 + 16 * @sin(phase));
                }
                const tb = sdl.c.SDL_GetTicksNS();
                for (&r.anim_colors, 0..) |sig, i| {
                    const phase = @as(f32, @floatFromInt(frame)) * 0.06 + @as(f32, @floatFromInt(i)) * 0.17;
                    sig.set(anim_mod.lerpColor(0x3F51B5FF, 0xE91E63FF, (@sin(phase) + 1) / 2));
                }
                const tc = sdl.c.SDL_GetTicksNS();
                r.timeline.?.tick(frame * 8);
                if (prof) std.debug.print("  tick h={d}us c={d}us tl={d}us\n", .{ (tb - ta) / 1000, (tc - tb) / 1000, sdl.c.SDL_GetTicksNS() -| tc });
            },
            .resize => {
                // Cycle the viewport: resize the surface + relayout the tree.
                const s = RESIZE_SIZES[@as(usize, @intCast(frame % RESIZE_SIZES.len))];
                renderer.resize(s[0], s[1]); // keeps the paint-visible rect in sync
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
            .elevation_grid, .clip_path, .chart_live => {
                r.root.markDirty(); // the drive clock changed — repaint everything
            },
            .theme_switch => {
                // The palette flips every 30 frames — the invalidation (and
                // so the repaint) is real only on flip frames. Marking every
                // frame would repaint a static tree 30× more than the spec's
                // workload; the other runners' scenes idle between switches.
                // Every themed node is marked (like a real theme system
                // invalidating bound widgets) so retained parents re-rasterize.
                if (frame % 30 == 0) {
                    r.theme_flip.dark = !r.theme_flip.dark;
                    for (r.theme_nodes.items) |n| n.markDirty();
                }
            },
            .relayout_storm => {
                // Every row's width is a function of the frame — relayout the
                // whole column (measure + layout, NOT a compositable transform).
                r.storm_col.?.markLayoutDirty();
            },
            .mount_churn => {
                // Steady-state pool of 500: retire the 50 oldest, create 50 new.
                const parent = r.churn_parent.?;
                const prof = latchEnv("KLAXON_BENCH_PHASES");
                var trm: u64 = 0;
                var tde: u64 = 0;
                var tcr: u64 = 0;
                var tad: u64 = 0;
                var detached: [CHURN_DELTA]*Node = undefined;
                const ts = sdl.c.SDL_GetTicksNS();
                const nd = parent.removeRange(0, CHURN_DELTA, &detached);
                const t2 = sdl.c.SDL_GetTicksNS();
                for (detached[0..nd]) |v| v.deinit();
                const t3 = sdl.c.SDL_GetTicksNS();
                var k: usize = 0;
                while (k < CHURN_DELTA) : (k += 1) {
                    const t3b = sdl.c.SDL_GetTicksNS();
                    const card = churnCard(r.allocator, r.churn_next);
                    const t4 = sdl.c.SDL_GetTicksNS();
                    parent.add(card);
                    const t5 = sdl.c.SDL_GetTicksNS();
                    tcr += t4 - t3b;
                    tad += t5 - t4;
                    r.churn_next +%= 1;
                }
                trm += t2 - ts;
                tde += t3 - t2;
                if (prof) std.debug.print("  churn rm={d}us deinit={d}us create={d}us add={d}us\n", .{ trm / 1000, tde / 1000, tcr / 1000, tad / 1000 });
            },
            .scroll_anim => {
                // 600 dp/s at 60 Hz ≈ 10 px/frame. The overlay repaints the
                // ~30 visible row icons every frame (Qt's banded delegates
                // pay the same); it reads the live offset + drive clock.
                const list = r.scroll_list.?;
                const max_off = widgets.list_view.maxScrollOffset(list);
                const off = @mod(@as(f32, @floatFromInt(frame)) * 10.0, max_off + 1.0);
                _ = widgets.list_view.setScrollOffset(list, off);
                r.pulse_overlay.?.markDirty();
            },
            .backdrop_scroll => {
                const list = r.scroll_list.?;
                const max_off = widgets.list_view.maxScrollOffset(list);
                const off = @mod(@as(f32, @floatFromInt(frame)) * 8.0, max_off + 1.0);
                _ = widgets.list_view.setScrollOffset(list, off);
            },
            .input_latency => {
                if (frame == r.lat_ev) {
                    // A tap on the responder box. Windowed: pushed as a real
                    // SDL event — the measured span covers queue push → poll
                    // → translate → dispatch → response paint (the in-process
                    // span; OS delivery is unmeasurable for every framework —
                    // Qt/Compose inject synthetically the same way). Headless
                    // has no event queue: direct dispatch is the equivalent.
                    const b = r.lat_node.?.bounds;
                    const cx = b.x + b.w / 2;
                    const cy = b.y + b.h / 2;
                    r.lat_event_ns = sdl.c.SDL_GetTicksNS();
                    if (r.windowed) {
                        var ev: sdl.c.SDL_Event = std.mem.zeroes(sdl.c.SDL_Event);
                        ev.button.type = sdl.c.SDL_EVENT_MOUSE_BUTTON_DOWN;
                        ev.button.button = sdl.c.SDL_BUTTON_LEFT;
                        ev.button.x = cx;
                        ev.button.y = cy;
                        _ = sdl.c.SDL_PushEvent(&ev);
                        ev.button.type = sdl.c.SDL_EVENT_MOUSE_BUTTON_UP;
                        _ = sdl.c.SDL_PushEvent(&ev);
                        var pev: sdl.c.SDL_Event = undefined;
                        while (sdl.c.SDL_PollEvent(&pev)) {
                            if (pev.type == sdl.c.SDL_EVENT_MOUSE_BUTTON_DOWN or pev.type == sdl.c.SDL_EVENT_MOUSE_BUTTON_UP) {
                                const phase: input_mod.PointerPhase = if (pev.type == sdl.c.SDL_EVENT_MOUSE_BUTTON_DOWN) .down else .up;
                                r.router.?.dispatchPointer(r.root, .{ .phase = phase, .x = pev.button.x, .y = pev.button.y });
                            }
                        }
                    } else {
                        r.router.?.dispatchPointer(r.root, .{ .phase = .down, .x = cx, .y = cy });
                        r.router.?.dispatchPointer(r.root, .{ .phase = .up, .x = cx, .y = cy });
                    }
                }
                // Latency closes post-paint — see closeLatency (runFrames).
            },
            .pointer_storm => {
                // 1000 hit-test queries over the tree — pure hit-test cost.
                var rng = r.storm_rng;
                var i: usize = 0;
                while (i < 1000) : (i += 1) {
                    rng = rng *% 6364136223846793005 +% 1442695040888963407;
                    const x = @as(f32, @floatFromInt(rng >> 33)) / 2147483648.0 * r.bounds.w;
                    rng = rng *% 6364136223846793005 +% 1442695040888963407;
                    const y = @as(f32, @floatFromInt(rng >> 33)) / 2147483648.0 * r.bounds.h;
                    _ = r.root.hitTest(x, y);
                }
                r.storm_rng = rng;
            },
            .semantics_build => {
                // Build + tear down the a11y semantics tree every frame.
                var tree = ui.semantics.buildSemanticTree(r.allocator, r.root) catch @panic("klaxon: out of memory");
                r.extra.nodes_per_frame = countSemNodes(&tree);
                tree.deinit(r.allocator);
            },
            .app_switch => {
                const phase = frame % 60;
                if (phase == 30 and r.app_root != null) {
                    // Pause: tear the app subtree down (timed).
                    const t0 = sdl.c.SDL_GetTicksNS();
                    _ = r.app_slot.?.remove(r.app_root.?);
                    r.app_root.?.deinit();
                    r.app_root = null;
                    r.switch_teardown_ms += @as(f64, @floatFromInt(sdl.c.SDL_GetTicksNS() - t0)) / 1e6;
                    r.switch_teardowns += 1;
                } else if (phase == 0 and frame > 0 and r.app_root == null) {
                    // Resume: rebuild + relayout; resume_ms closes when this
                    // frame's paint completes (the run loop checks resume_t0).
                    r.resume_t0 = sdl.c.SDL_GetTicksNS();
                    r.app_root = buildAppContent(r.allocator) catch @panic("klaxon: out of memory");
                    r.app_slot.?.add(r.app_root.?);
                    r.root.layout(r.bounds);
                }
            },
        }
    }

    /// Render `opts.warmup_frames + opts.frames` frames and collect metrics.
    fn run(r: *SceneRunner, renderer: *golden.Renderer, opts: RunOptions, start_ns: u64) !Metrics {
        // The layout space follows the renderer's surface — windowed tier-2
        // can report the display's real size (Android is always full-panel).
        r.bounds = Rect{ .x = 0, .y = 0, .w = @floatFromInt(renderer.w), .h = @floatFromInt(renderer.h) };
        r.lat_ev = opts.warmup_frames + @min(5, opts.frames / 2); // input_latency injection frame
        r.root.layout(r.bounds);
        if (opts.hide_scroll_content and r.scene == .gallery) {
            // Counterfactual UPPER BOUND: hiding the whole scroll content
            // column removes visible sections too — the resulting frame time
            // is the ceiling of the savings an off-screen paint cull would
            // realize, not an exact isolation (see PERF-INVESTIGATION.md).
            const sv = r.gallery.?.refs.scroll_view;
            if (sv.children.items.len > 0) sv.children.items[0].setVisible(false);
        }
        if (r.scene.isListOp()) return r.runListOp(renderer, opts, start_ns);
        if (r.scene.isRamp()) return r.runRamp(renderer, opts, start_ns);
        return r.runFrames(renderer, opts, start_ns);
    }

    /// The standard loop: warmup + measured frames of tick → layout → paint.
    /// Per-phase timing feeds the optional trace/phase diagnostics (3 extra
    /// SDL_GetTicksNS calls per frame — ~0 cost when the opts are off).
    fn runFrames(r: *SceneRunner, renderer: *golden.Renderer, opts: RunOptions, start_ns: u64) !Metrics {
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
        // SDL's first event pump does one-time Cocoa setup (~300ms measured:
        // event taps, window-server connect, IME session). A real app pays it
        // at startup and pumps continuously — drain once BEFORE the run so
        // input_latency's in-process span isn't charged OS init.
        if (opts.windowed) {
            var ev: sdl.c.SDL_Event = undefined;
            while (sdl.c.SDL_PollEvent(&ev)) {}
        }
        const total = opts.warmup_frames + opts.frames;
        // Windowed: wall clock over the measured window → presented_fps —
        // the real presented rate (vsync-paced), vs `fps` = unthrottled
        // work rate. Headless has no presentation: the field stays 0.
        var wall_start: u64 = 0;
        var wall_end: u64 = 0;
        var presented_at_start: u64 = 0;
        var i: u64 = 0;
        while (i < total) : (i += 1) {
            if (opts.windowed and i == opts.warmup_frames) {
                wall_start = sdl.c.SDL_GetTicksNS();
                presented_at_start = renderer.frames_presented;
            }
            // Windowed input_latency: keep the OS queue hot like a real app —
            // without it the injection-frame poll eats the accumulated
            // backlog (measured 35ms inside the span). Scene-scoped: pumping
            // the Cocoa runloop every frame costs real ms on a busy queue —
            // charging every scene's frame for event plumbing they never
            // use would inflate the whole suite (~2x measured).
            if (opts.windowed and r.scene == .input_latency) {
                var ev: sdl.c.SDL_Event = undefined;
                while (sdl.c.SDL_PollEvent(&ev)) {}
            }
            const t0 = sdl.c.SDL_GetTicksNS();
            r.tick(renderer, i);
            const t1 = sdl.c.SDL_GetTicksNS();
            const relayout = r.root.layout_dirty;
            if (relayout) r.root.layout(r.bounds); // animated/resized scenes mark it
            const t2 = sdl.c.SDL_GetTicksNS();
            const had_damage = r.root.damage_valid;
            // The host's raster path: repaint clipped to the accumulated
            // damage when any exists (retained surface — undamaged pixels
            // stay), a full repaint on a clean tree. paintDamage clears the
            // accumulator before painting so marks raised mid-paint seed the
            // next frame — the trace still sees whether this frame had any.
            renderer.paintDamage(r.root, BG);
            const t3 = sdl.c.SDL_GetTicksNS();
            // Windowed tier-2: the frame wait is vsync backpressure (Metal:
            // nextDrawable in begin; GLES: eglSwapBuffers in end), not
            // frame work — subtract it (≈0 on raster, so unconditional).
            const wait_ns = renderer.last_frame_wait_ns;
            if (r.resume_t0 != 0) { // app_switch: the resume frame just painted
                r.switch_resume_ms += @as(f64, @floatFromInt(t3 - r.resume_t0 -| wait_ns)) / 1e6;
                r.switch_resumes += 1;
                r.resume_t0 = 0;
            }
            r.closeLatency(); // input_latency: same-frame close-out
            if (i == 0) ttff_ms = @as(f64, @floatFromInt(t3 - start_ns)) / 1e6;
            if (opts.windowed) wall_end = t3;
            if (i >= opts.warmup_frames) {
                try frame_times.append(@as(f64, @floatFromInt(t3 - t0 -| wait_ns)) / 1e6);
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
        // --- diagnostics output (stderr/files; the JSON report is unchanged) ---
        if (opts.trace_dir) |dir| writeFrameTrace(dir, r.scene, trace_csv.items);
        if (opts.phase_breakdown) {
            printPhaseBreakdown(r.scene, frame_times.items, tick_times.items, layout_times.items, paint_times.items, layout_passes, opts.warmup_frames);
        }
        // Capture the measured-run metrics BEFORE the optional profile: its
        // extra ticks allocate (scroll rows land in the arena) and would
        // inflate rss_mb for this scene and the shared baseline of later
        // ones. The app_switch extras freeze here too — profile frames keep
        // ticking and can cross a teardown/resume boundary outside the
        // measured range, which must not contaminate them.
        // The current surface (resize may have changed it) — the same region
        // the paint pass culls against.
        // Real submitted ops from the kx counter (last measured frame —
        // per-node paint emits counted once, on the emit path).
        const draw_calls = kx.c.kx_frame_draw_ops(renderer.ctx);
        const rss_mb = devtools.readRssMb();
        if (r.switch_teardowns > 0) r.extra.teardown_ms = r.switch_teardown_ms / @as(f64, @floatFromInt(r.switch_teardowns));
        if (r.switch_resumes > 0) r.extra.resume_ms = r.switch_resume_ms / @as(f64, @floatFromInt(r.switch_resumes));
        if (opts.paint_profile) try r.profilePaint(renderer, opts);
        var m = try r.finishMetrics(frame_times.items, ttff_ms, total, draw_calls, rss_mb);
        m.presented_fps = presentedFps(opts, wall_start, wall_end, renderer.frames_presented - presented_at_start);
        return m;
    }

    /// Family A (list_ops): warmup on the pre-op state → the operation timed
    /// as model mutation + rebind + layout + one full paint (extra.op_ms) →
    /// frame metrics over LIST_OP_MEASURED frames after the op.
    fn runListOp(r: *SceneRunner, renderer: *golden.Renderer, opts: RunOptions, start_ns: u64) !Metrics {
        var frame_times = std.array_list.Managed(f64).init(r.allocator);
        defer frame_times.deinit();
        const measured = @min(opts.frames, LIST_OP_MEASURED);
        try frame_times.ensureTotalCapacity(@intCast(measured));
        var ttff_ms: f64 = 0;
        var wall_start: u64 = 0;
        var wall_end: u64 = 0;
        var i: u64 = 0;
        while (i < opts.warmup_frames) : (i += 1) {
            if (r.root.layout_dirty) r.root.layout(r.bounds);
            renderer.paint(r.root, BG);
            if (i == 0) ttff_ms = @as(f64, @floatFromInt(sdl.c.SDL_GetTicksNS() - start_ns)) / 1e6;
        }
        // Settle the caches a real session would have: a prior interaction
        // (here: a sibling-region mark) dirties the retained ancestors once
        // while the list rows stay clean — so the list's retained pass runs
        // once and the rows' atlas slots exist BEFORE the timed op. Without
        // it the op measures one-time cache establishment (~15 first
        // rasters) that any real interaction would have absorbed earlier.
        if (r.list_empty_text) |t| {
            t.markDirty();
            if (r.root.layout_dirty) r.root.layout(r.bounds);
            renderer.paint(r.root, BG);
        }
        // The op: mutate the model, rebind the list, render once — timed.
        const dbg_phases = std.c.getenv("KLAXON_BENCH_OP_PHASES") != null;
        // Profiling hook: re-run mutate+layout+paint N times so `sample`
        // can catch the op frame's hot path (idempotent ops only).
        const op_loop: u64 = if (std.c.getenv("KLAXON_OP_LOOP")) |v|
            std.fmt.parseInt(u64, std.mem.span(v), 10) catch 0
        else
            0;
        var ol: u64 = 0;
        while (ol < op_loop) : (ol += 1) {
            applyListOp(r);
            r.root.layout(r.bounds);
            renderer.paint(r.root, BG);
        }
        const o0 = sdl.c.SDL_GetTicksNS();
        applyListOp(r);
        const o1 = sdl.c.SDL_GetTicksNS();
        r.root.layout(r.bounds);
        const o2 = sdl.c.SDL_GetTicksNS();
        if (dbg_phases) {
            renderer.beginFrame();
            const ob = sdl.c.SDL_GetTicksNS();
            renderer.paintDamageInner(r.root, BG);
            const oi = sdl.c.SDL_GetTicksNS();
            renderer.endFrame();
            const o3 = sdl.c.SDL_GetTicksNS();
            std.debug.print("  op inner={d:.3}ms begin={d:.3}ms end={d:.3}ms draws={d}\n", .{
                @as(f64, @floatFromInt(oi - ob)) / 1e6,
                @as(f64, @floatFromInt(ob - o2)) / 1e6,
                @as(f64, @floatFromInt(o3 - oi)) / 1e6,
                kx.c.kx_frame_draw_ops(renderer.ctx),
            });
        } else {
            renderer.paint(r.root, BG);
        }
        const o3 = sdl.c.SDL_GetTicksNS();
        r.extra.op_ms = @as(f64, @floatFromInt(o3 - o0 -| renderer.last_frame_wait_ns)) / 1e6;
        if (dbg_phases) std.debug.print("op {s}: mutate={d:.3}ms layout={d:.3}ms paint={d:.3}ms wait={d:.3}ms\n", .{
            r.scene.name(),
            @as(f64, @floatFromInt(o1 - o0)) / 1e6,
            @as(f64, @floatFromInt(o2 - o1)) / 1e6,
            @as(f64, @floatFromInt(o3 - o2)) / 1e6,
            @as(f64, @floatFromInt(renderer.last_frame_wait_ns)) / 1e6,
        });
        if (opts.warmup_frames == 0) ttff_ms = @as(f64, @floatFromInt(o1 - start_ns)) / 1e6;
        i = 0;
        if (opts.windowed) wall_start = sdl.c.SDL_GetTicksNS();
        const dbg_loop = latchEnv("KLAXON_BENCH_PHASES");
        while (i < measured) : (i += 1) {
            const t0 = sdl.c.SDL_GetTicksNS();
            r.tick(renderer, i);
            const tl = sdl.c.SDL_GetTicksNS();
            if (r.root.layout_dirty) r.root.layout(r.bounds);
            const tp = sdl.c.SDL_GetTicksNS();
            renderer.paint(r.root, BG);
            const t1 = sdl.c.SDL_GetTicksNS();
            if (dbg_loop) std.debug.print("  frame tick={d}us layout={d}us paint={d}us\n", .{ (tl - t0) / 1000, (tp - tl) / 1000, (t1 - tp) / 1000 });
            wall_end = t1;
            try frame_times.append(@as(f64, @floatFromInt(t1 - t0 -| renderer.last_frame_wait_ns)) / 1e6);
        }
        const draw_calls = kx.c.kx_frame_draw_ops(renderer.ctx);
        var m = try r.finishMetrics(frame_times.items, ttff_ms, opts.warmup_frames + 1 + measured, draw_calls, devtools.readRssMb());
        m.presented_fps = presentedFps(opts, wall_start, wall_end, measured);
        return m;
    }

    /// Family B (ramp): stepped ladder — `warmup + min(frames, 20)` frames per
    /// step, per-step p50 into extra.ramp[], n_max_60fps = largest passing N.
    fn runRamp(r: *SceneRunner, renderer: *golden.Renderer, opts: RunOptions, start_ns: u64) !Metrics {
        var frame_times = std.array_list.Managed(f64).init(r.allocator);
        defer frame_times.deinit();
        // @min narrows to the smallest integer holding the bound (u4/u5 here)
        // — widen before multiplying or the product overflows in Debug builds.
        const steps: usize = @min(opts.ramp_steps, RAMP_STEPS.len);
        const per_step: u64 = @min(opts.frames, RAMP_MEASURED);
        try frame_times.ensureTotalCapacity(@intCast(per_step * steps));
        var step_buf: [RAMP_MEASURED]f64 = undefined;
        var ttff_ms: f64 = 0;
        var first_done = false;
        var total: u64 = 0;
        var last_n: u64 = 0;
        var wall_ns: u64 = 0; // measured-frame wall time (windowed presented rate)
        for (RAMP_STEPS[0..steps], 0..) |n, si| {
            const s: *RampState = @ptrCast(@alignCast(r.ramp_node.?.state.?));
            s.n = n;
            last_n = n;
            var i: u64 = 0;
            while (i < opts.warmup_frames + per_step) : (i += 1) {
                const t0 = sdl.c.SDL_GetTicksNS();
                s.frame = i;
                if (r.root.layout_dirty) r.root.layout(r.bounds);
                renderer.paint(r.root, BG);
                const t1 = sdl.c.SDL_GetTicksNS();
                total += 1;
                if (!first_done) {
                    ttff_ms = @as(f64, @floatFromInt(t1 - start_ns)) / 1e6;
                    first_done = true;
                }
                if (i >= opts.warmup_frames) {
                    const ms = @as(f64, @floatFromInt(t1 - t0 -| renderer.last_frame_wait_ns)) / 1e6;
                    step_buf[@intCast(i - opts.warmup_frames)] = ms;
                    try frame_times.append(ms);
                    wall_ns += t1 - t0;
                }
            }
            const step_times = step_buf[0..@intCast(per_step)];
            const sorted = try r.allocator.dupe(f64, step_times);
            defer r.allocator.free(sorted);
            std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
            r.extra.ramp[si] = .{ .n = n, .p50_ms = percentile(sorted, 50) };
        }
        r.extra.ramp_len = steps;
        // n_max_60fps: the largest step still inside the 60 Hz budget.
        var n_max: ?u64 = null;
        for (r.extra.ramp[0..steps]) |p| {
            if (p.p50_ms <= JANK_MS) n_max = p.n;
        }
        r.extra.n_max_60fps = n_max;
        // draw_calls_per_frame = real submitted ops of the last measured frame.
        var m = try r.finishMetrics(frame_times.items, ttff_ms, total,
            kx.c.kx_frame_draw_ops(renderer.ctx), devtools.readRssMb());
        m.presented_fps = if (opts.windowed and wall_ns > 0)
            @as(f64, @floatFromInt(frame_times.items.len)) * 1e9 / @as(f64, @floatFromInt(wall_ns))
        else
            0;
        return m;
    }

    /// input_latency: close the event→paint window once the lit response has
    /// painted. Runs after the frame's paint (not in tick — the responder
    /// stamps painted_ns inside paint), so a run ending on the injected frame
    /// still reports latency_frames/latency_ms. No-op for other scenes.
    fn closeLatency(r: *SceneRunner) void {
        if (r.scene != .input_latency or r.lat_event_ns == 0 or r.extra.latency_ms != null) return;
        const s: *LatState = @ptrCast(@alignCast(r.lat_node.?.state.?));
        if (s.painted_ns == 0) return;
        r.extra.latency_ms = @as(f64, @floatFromInt(s.painted_ns - r.lat_event_ns)) / 1e6;
        r.extra.latency_frames = s.painted_frame - r.lat_ev + 1;
    }

    /// Stats over the measured frames → Metrics (extras merged from r.extra).
    /// draw_calls + rss_mb are captured by the CALLER — before any optional
    /// paint_profile run (its extra ticks allocate and would pollute rss_mb).
    fn finishMetrics(r: *SceneRunner, times: []f64, ttff_ms: f64, total: u64, draw_calls: u64, rss_mb: f64) !Metrics {
        const sorted = try r.allocator.dupe(f64, times);
        defer r.allocator.free(sorted);
        std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
        const n = times.len;
        var avg: f64 = 0;
        var jank: u64 = 0;
        for (times) |t| {
            avg += t;
            if (t > JANK_MS) jank += 1;
        }
        if (n > 0) avg /= @as(f64, @floatFromInt(n));
        return .{
            .fps = if (avg > 0) 1000.0 / avg else 0,
            .frame_time_avg_ms = avg,
            .frame_time_p50_ms = percentile(sorted, 50),
            .frame_time_p99_ms = percentile(sorted, 99),
            .frame_time_p999_ms = percentile(sorted, 99.9),
            .jank_frames = jank,
            .jank_pct = if (n > 0) 100.0 * @as(f64, @floatFromInt(jank)) / @as(f64, @floatFromInt(n)) else 0,
            .draw_calls_per_frame = draw_calls,
            .rss_mb = rss_mb,
            .ttff_ms = ttff_ms,
            .frames_rendered = total,
            .extra = r.extra,
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
    if (!gop.found_existing) gop.value_ptr.* = .{};
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
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.csv", .{ dir, scene.name() }) catch {
        std.debug.print("klaxon bench: frame trace skipped — path too long: {s}/{s}.csv\n", .{ dir, scene.name() });
        return;
    };
    makePath(std.heap.page_allocator, dir) catch {
        std.debug.print("klaxon bench: frame trace skipped — cannot create {s}\n", .{dir});
        return;
    };
    const path_z = std.heap.page_allocator.dupeSentinel(u8, path, 0) catch return;
    defer std.heap.page_allocator.free(path_z);
    const f = std.c.fopen(path_z, "wb") orelse {
        std.debug.print("klaxon bench: frame trace failed — cannot open {s}\n", .{path});
        return;
    };
    defer _ = std.c.fclose(f);
    const header = "frame,tick_ms,layout_ms,paint_ms,total_ms,relayout,had_damage\n";
    if (std.c.fwrite(header.ptr, 1, header.len, f) != header.len or
        std.c.fwrite(csv.ptr, 1, csv.len, f) != csv.len)
    {
        std.debug.print("klaxon bench: frame trace truncated — write failed for {s}\n", .{path});
        return;
    }
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
/// devtools.p99FrameTimeMs convention). 0 for an empty set. `p` is fractional
/// so p99.9 uses the same convention (p999_ms schema v2).
fn percentile(sorted: []const f64, p: f64) f64 {
    const n = sorted.len;
    if (n == 0) return 0;
    const idx: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(n)) * p / 100.0));
    return sorted[@min(idx, n - 1)];
}

/// Node count of a semantics tree (semantics_build's nodes_per_frame).
fn countSemNodes(sn: *const ui.semantics.SemanticNode) u64 {
    var c: u64 = 1;
    for (sn.children) |*child| c += countSemNodes(child);
    return c;
}

/// Windowed presented rate: measured frames over the wall window they were
/// presented in (vsync waits included). 0 headless — no presentation exists.
fn presentedFps(opts: RunOptions, wall_start: u64, wall_end: u64, frames: u64) f64 {
    if (!opts.windowed or wall_start == 0 or wall_end <= wall_start or frames == 0) return 0;
    return @as(f64, @floatFromInt(frames)) * 1e9 / @as(f64, @floatFromInt(wall_end - wall_start));
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
    card.retained = true; // static row — blit while the window slides (QSG idiom)
    return card;
}

/// Row recycling for benchListItem rows: card → row → (icon, text) — only
/// the label differs per index; re-set it in place (the card's dirty mark
/// re-rasterizes its retained image on the next paint).
fn benchListRebind(userdata: ?*anyopaque, index: usize, node: *Node) bool {
    _ = userdata;
    const row = node.children.items[0];
    const label = row.children.items[1];
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "Item #{d}", .{index}) catch return false;
    widgets.text.setText(label, s);
    return true;
}

fn buildScrollList(r: *SceneRunner, item_count: usize, title: []const u8) !*Node {
    const a = r.allocator;
    const col = try widgets.layout.column(a, .{ .gap = 12, .padding = 16 });
    col.add(try widgets.text.text(a, title, .{ .size = 14, .color = 0xCCCCCCFF }));
    const list = try widgets.list_view.listView(a, .{
        .item_count = item_count,
        .factory = .{ .fn_ptr = benchListItem, .userdata = &r.list_ctx, .rebind = benchListRebind },
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
    const lines = [_]struct { txt: []const u8, size: f32, color: u32 }{
        .{ .txt = "text_cjk — CJK shaping (中文 / 日本語 / 한국어)", .size = 14, .color = 0xCCCCCCFF },
        .{ .txt = "你好，世界！Klaxon 是一个用 Zig 编写的 UI 框架。", .size = 22, .color = 0xFFFFFFFF },
        .{ .txt = "こんにちは、世界！Klaxon は Zig で書かれた UI フレームワークです。", .size = 22, .color = 0xFFFFFFFF },
        .{ .txt = "안녕하세요, 세계! Klaxon은 Zig로 작성된 UI 프레임워크입니다.", .size = 22, .color = 0xFFFFFFFF },
        .{ .txt = "混ぜるな危険 — CJK + Latin + emoji 🌍🎉", .size = 18, .color = 0xFFD54FFF },
    };
    // Per-LINE retained: a glyph-mask blit per line (~12K px) beats the
    // drawTextBlob path — and a whole-column blit (224K px) loses to both.
    for (lines) |l| {
        const t = try widgets.text.text(a, l.txt, .{ .size = l.size, .color = l.color });
        t.retained = true;
        col.add(t);
    }
    return col;
}

// --- scene: glass_blur — translucent cards over a colorful backdrop ---
// A glass card: an alpha layer (kx_layer_alpha — the blur stand-in; the C ABI
// has no blur primitive) with a translucent tint + frosted content bars. The
// stack uses fit .expand so the deco column measures full width.

const GlassState = struct {
    radius: f32,
    tint: Color,
    sigma: f32,
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
    // Real backdrop blur (0.16.0): the backdrop filter blurs the panels
    // painted underneath, then the translucent tint + highlights composite
    // over — the frosted-glass primitive Qt/Flutter do natively, replacing
    // the alpha-saveLayer stand-in.
    ui.paint.backdropBlur(ctx, b.x, b.y, b.w, b.h, s.sigma);
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, s.radius, s.tint);
    ui.paint.fillRect(ctx, b.x + 12, b.y + 12, b.w - 24, 6, 0xFFFFFFFF);
    ui.paint.fillRect(ctx, b.x + 12, b.y + 24, (b.w - 24) * 0.62, 6, 0xB3FFFFFF);
    ui.paint.fillRect(ctx, b.x + 12, b.y + 36, (b.w - 24) * 0.4, 6, 0x80FFFFFF);
}
fn glassDeinit(n: *Node) void {
    n.allocator.destroy(@as(*GlassState, @ptrCast(@alignCast(n.state.?))));
}
const glass_vtable = ui.node.VTable{ .measure = glassMeasure, .layout = glassLayout, .paint = glassPaint, .deinit = glassDeinit, .reads_backdrop = true };

fn glassCard(a: std.mem.Allocator, tint: Color, sigma: f32, radius: f32) !*Node {
    const node = try Node.create(a, &glass_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try a.create(GlassState);
    errdefer a.destroy(s);
    s.* = .{ .radius = radius, .tint = tint, .sigma = sigma };
    node.state = s;
    // NOT retained: a card's own offscreen pass starts transparent — the
    // backdrop blur would sample nothing (and nested offscreens are banned).
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
        wrap.add(try glassCard(a, tint, 12.0, 16)); // σ=12 — M3 glass blur
        stack.add(wrap);
    }
    backdrop.add(stack);
    backdrop.retained = true; // static scene — one raster re-blits per frame
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
        .factory = .{ .fn_ptr = benchListItem, .userdata = &r.list_ctx, .rebind = benchListRebind },
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
    pixels: []u32, // owned scratch, w*h pixels — one u32 per RGBA pixel
    /// Per-x red gradient precomputed at init: the per-pixel term of the
    /// frame decode (`x*255/(w-1)` as r | b | a bits — g is per-row).
    rbase: []u32,
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
    // Regenerate the "decoded" frame: gradient rows, one u32 store per pixel
    // (memory order R,G,B,A → little-endian word A<<24|B<<16|G<<8|R).
    const bar_end = @min(bar + 24, w);
    // One OR+store per pixel: the r|b|a word is per-x (precomputed), g<<8 is
    // per-row — the decode loop has no division, no per-pixel multiply.
    for (0..h) |y| {
        const g: u32 = @as(u32, @intCast(y * 255 / (h - 1))) << 8;
        const row = s.pixels[y * w .. (y + 1) * w];
        for (row, s.rbase) |*px, rb| px.* = rb | g;
        for (row[bar..bar_end]) |*px| px.* = 0xFFFFFFFF;
    }
    // Upload+draw in one zero-copy call: the decode buffer is borrowed for
    // the synchronous raster draw (a player presents frames, doesn't keep
    // them) — no registry image, no 230KB copy per frame.
    ui.paint.drawPixels(ctx, @ptrCast(s.pixels.ptr), s.w, s.h,
        n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h);
    // The decoded frame changes every paint: mark dirty so the damage path
    // repaints just this node next frame (a real video widget does the same).
    n.markDirty();
}
fn videoDeinit(n: *Node) void {
    const s: *VideoState = @ptrCast(@alignCast(n.state.?));
    n.allocator.free(s.pixels);
    n.allocator.free(s.rbase);
    n.allocator.destroy(s);
}
const video_vtable = ui.node.VTable{ .measure = videoMeasure, .layout = videoLayout, .paint = videoPaint, .deinit = videoDeinit };

fn videoWidget(a: std.mem.Allocator, w: i32, h: i32) !*Node {
    const node = try Node.create(a, &video_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try a.create(VideoState);
    errdefer a.destroy(s);
    const pixels = try a.alloc(u32, @as(usize, @intCast(w)) * @as(usize, @intCast(h)));
    errdefer a.free(pixels);
    const rbase = try a.alloc(u32, @as(usize, @intCast(w)));
    errdefer a.free(rbase);
    for (rbase, 0..) |*rb, x| {
        const r: u32 = @intCast(x * 255 / @as(usize, @intCast(w - 1)));
        rb.* = r | (0x60 << 16) | (0xFF << 24);
    }
    s.* = .{ .w = w, .h = h, .pixels = pixels, .rbase = rbase };
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

// =====================================================================
// 4c.6 scene catalogue (docs/specs/bench-scenes.md)
// =====================================================================

/// Shared per-frame clock handed to scene nodes that animate at paint time
/// (the runner sets it at the top of tick — deterministic in `frame`).
const Drive = struct { frame: u64 = 0 };

// --- family A: list_ops — krausest ops over the virtualized list ---
// One shared row widget: 48 dp, "Row NNNN — klaxon bench" left, a 16×16
// #7C4DFFFF square right. Virtualization stays ON (the framework idiom): the
// op measures the model→render path — model mutation + window rebind + one
// full render pass — not the layout of 1000 live nodes.

const LIST_ROWS = 1000;

const ListOpsCtx = struct {
    allocator: std.mem.Allocator,
    labels: [LIST_ROWS][]const u8 = undefined,
    bufs: [LIST_ROWS][40]u8 = undefined,
    count: usize = 0,
};

/// (Re)generate the whole row model — `tag` distinguishes generations
/// (list_replace_1k writes a fresh generation so the swap is observable).
/// Hand-rolled label writer: std.fmt's runtime format parsing costs ~100ns
/// per row here — 1000 rows of it was the dominant term in create/replace.
fn writeListLabel(ctx: *ListOpsCtx, i: usize, tag: []const u8) void {
    const mid = " — klaxon bench";
    const buf: []u8 = &ctx.bufs[i];
    @memcpy(buf[0..4], "Row ");
    var n = i; // i < 1000 — always four digits, back to front
    buf[7] = '0' + @as(u8, @intCast(n % 10));
    n /= 10;
    buf[6] = '0' + @as(u8, @intCast(n % 10));
    n /= 10;
    buf[5] = '0' + @as(u8, @intCast(n % 10));
    n /= 10;
    buf[4] = '0' + @as(u8, @intCast(n));
    @memcpy(buf[8..][0..mid.len], mid);
    @memcpy(buf[8 + mid.len ..][0..tag.len], tag);
    ctx.labels[i] = buf[0 .. 8 + mid.len + tag.len];
}

fn fillListOpsModel(ctx: *ListOpsCtx, tag: []const u8) void {
    for (0..LIST_ROWS) |i| writeListLabel(ctx, i, tag);
    ctx.count = LIST_ROWS;
}

fn listOpsItem(userdata: ?*anyopaque, index: usize) *Node {
    const ctx: *ListOpsCtx = @ptrCast(@alignCast(userdata.?));
    const a = ctx.allocator;
    const row = widgets.layout.row(a, .{ .padding = 8, .main_align = .space_between, .cross_align = .center }) catch @panic("klaxon: out of memory");
    row.add(widgets.text.text(a, ctx.labels[index], .{ .size = 14, .color = 0xFFFFFFFF }) catch @panic("klaxon: out of memory"));
    row.add(golden.solidBox(a, 16, 16, 0x7C4DFFFF) catch @panic("klaxon: out of memory"));
    return row;
}

/// list_ops rows recycle: row → (text, box) — the box is index-independent.
fn listOpsRebind(userdata: ?*anyopaque, index: usize, node: *Node) bool {
    const ctx: *ListOpsCtx = @ptrCast(@alignCast(userdata.?));
    widgets.text.setText(node.children.items[0], ctx.labels[index]);
    return true;
}

fn buildListOps(r: *SceneRunner, empty: bool) !void {
    const a = r.allocator;
    r.list_ops.count = 0;
    if (!empty) fillListOpsModel(&r.list_ops, ""); // create_1k starts empty
    const box = try widgets.layout.constrainedBox(a, .{ .max_w = 640, .max_h = 480 });
    const list = try widgets.list_view.listView(a, .{
        .item_count = r.list_ops.count,
        .factory = .{ .fn_ptr = listOpsItem, .userdata = &r.list_ops, .rebind = listOpsRebind },
        .item_height = 48,
    });
    r.scroll_list = list;
    // The empty state — Flutter's Center(Text('No rows')) idiom (it also
    // keeps the text pipeline warm for list_create_1k's timed op).
    const st = try widgets.layout.stack(a, .{ .fit = .expand, .alignment = .center });
    st.add(list);
    r.list_empty_text = try widgets.text.text(a, "No rows", .{ .size = 14, .color = 0xCCCCCCFF });
    r.list_empty_text.?.setVisible(r.list_ops.count == 0);
    st.add(r.list_empty_text.?);
    box.add(st);
    r.root = box;
}

/// The timed list operation (inside runListOp's op window).
fn applyListOp(r: *SceneRunner) void {
    const list = r.scroll_list.?;
    switch (r.scene) {
        .list_create_1k => {
            fillListOpsModel(&r.list_ops, "");
            widgets.list_view.setItemCount(list, r.list_ops.count);
        },
        .list_replace_1k => {
            fillListOpsModel(&r.list_ops, " ·r2"); // swap all 1000 row models
            widgets.list_view.reloadItems(list);
        },
        .list_update_10th => {
            var i: usize = 0;
            while (i < LIST_ROWS) : (i += 10) {
                writeListLabel(&r.list_ops, i, " ·upd");
            }
            widgets.list_view.reloadItems(list);
        },
        .list_swap_rows => {
            const tmp = r.list_ops.labels[5];
            r.list_ops.labels[5] = r.list_ops.labels[995];
            r.list_ops.labels[995] = tmp;
            widgets.list_view.reloadItems(list);
        },
        .list_remove_row => {
            const mid = r.list_ops.count / 2;
            var i = mid;
            while (i + 1 < r.list_ops.count) : (i += 1) r.list_ops.labels[i] = r.list_ops.labels[i + 1];
            r.list_ops.count -= 1;
            widgets.list_view.setItemCount(list, r.list_ops.count);
        },
        .list_clear_1k => {
            r.list_ops.count = 0;
            widgets.list_view.setItemCount(list, 0);
        },
        else => unreachable,
    }
    // The empty state shows whenever the model is empty (Flutter's idiom).
    if (r.list_empty_text) |t| t.setVisible(r.list_ops.count == 0);
}

// --- family B: ramp — one workhorse node painting N items ---
// Stepped MotionMark: N = RAMP_STEPS, 20 measured frames per step (spec).
// Items are scattered deterministically and move on a Lissajous path
// (~4 px/frame). paths_ramp rasterizes its tessellated blob ONCE per color
// into ctx images (kx_offscreen_*, ABI 0.12.0) then draws each item as a
// rotated blit — the retained-asset idiom (Qt caches Shape geometry the
// same way; Compose keeps the Path object and transforms at draw time).

const RAMP_PATH_PTS = 204; // ~200 pts of tessellation (12 edges × 17)
const RAMP_BLOB_IMG = 44; // blob radius 18 → 36 px; 44 leaves an AA margin
const RampKind = enum { shapes, paths, text, images };

const RAMP_MAX = 3200; // RAMP_STEPS.last

const RampState = struct {
    kind: RampKind,
    n: usize = 0,
    frame: u64 = 0,
    base_xs: [RAMP_PATH_PTS]f32 = undefined, // paths: tessellated unit blob
    base_ys: [RAMP_PATH_PTS]f32 = undefined,
    pts_xs: [RAMP_PATH_PTS]f32 = undefined, // rasterization scratch
    pts_ys: [RAMP_PATH_PTS]f32 = undefined,
    pixels: [64 * 64 * 4]u8 = undefined, // images: the one decoded test image
    img_id: u64 = 0,
    blob_ids: [2]u64 = .{ 0, 0 }, // paths/shapes: rasterized blobs (2 colors)
    text_img: u64 = 0, // text: rasterized string + dims + ascent offset
    text_iw: f32 = 0,
    text_ih: f32 = 0,
    text_ascent: f32 = 0,
    // Sprite transforms for the drawAtlas batch — every ramp kind funnels
    // to ONE submission per frame (the QSG quad-batch idiom).
    xfs: [RAMP_MAX]ui.paint.SpriteXform = undefined,
    ctx: ?*kx.Ctx = null,
};

fn rampScatter(i: usize, w: f32, h: f32) [2]f32 {
    const fi: f32 = @floatFromInt(i);
    return .{ @mod(fi * 137.3, @max(1, w - 70)), @mod(fi * 91.7, @max(1, h - 60)) };
}

fn rampMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = c.max_w, .h = c.max_h });
}
fn rampLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn rampPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *RampState = @ptrCast(@alignCast(n.state.?));
    const b = n.bounds;
    const t = @as(f32, @floatFromInt(s.frame));
    var i: usize = 0;
    switch (s.kind) {
        .shapes => {
            // Same retained-asset idiom as paths: rasterize each color's
            // rrect once, then submit every item as ONE drawAtlas batch.
            if (s.ctx != ctx) {
                for (0..2) |c| {
                    if (s.blob_ids[c] != 0) {
                        if (s.ctx) |old| ui.paint.imageDestroy(old, s.blob_ids[c]);
                        s.blob_ids[c] = 0;
                    }
                }
                for (0..2) |c| {
                    if (!ui.paint.offscreenBegin(ctx, 44, 28)) break;
                    ui.paint.fillRRect(ctx, 2, 2, 40, 24, 8, if (c == 0) 0x7C4DFFFF else 0x03DAC6FF);
                    s.blob_ids[c] = ui.paint.offscreenEndImage(ctx);
                }
                s.ctx = ctx;
            }
            for (0..2) |c| {
                var j: usize = c;
                var k: usize = 0;
                while (j < s.n) : (j += 2) {
                    const fj: f32 = @floatFromInt(j);
                    const p = rampScatter(j, b.w, b.h);
                    s.xfs[k] = .{ .scos = 1, .ssin = 0, .tx = b.x + p[0] + 55 * @sin(0.063 * t + fj * 0.83) - 2, .ty = b.y + p[1] + 45 * @cos(0.081 * t + fj * 0.71) - 2 };
                    k += 1;
                }
                ui.paint.imageDrawAtlas(ctx, s.blob_ids[c], s.xfs[0..k]);
            }
        },
        .paths => {
            if (s.ctx != ctx) { // rasterize the blob once per ctx (per color)
                for (0..2) |c| {
                    if (s.blob_ids[c] != 0) {
                        if (s.ctx) |old| ui.paint.imageDestroy(old, s.blob_ids[c]);
                        s.blob_ids[c] = 0;
                    }
                }
                const c0 = RAMP_BLOB_IMG / 2; // blob centre inside the image
                for (0..2) |c| {
                    if (!ui.paint.offscreenBegin(ctx, RAMP_BLOB_IMG, RAMP_BLOB_IMG)) break;
                    for (s.base_xs, s.base_ys, 0..) |bx, by, k| {
                        s.pts_xs[k] = c0 + bx;
                        s.pts_ys[k] = c0 + by;
                    }
                    ui.paint.fillPolygon(ctx, &s.pts_xs, &s.pts_ys, if (c == 0) 0x7C4DFFFF else 0x03DAC6FF);
                    s.blob_ids[c] = ui.paint.offscreenEndImage(ctx);
                }
                s.ctx = ctx;
            }
            // translate(cx,cy)·rotate(deg)·blit-centred ≡ RSXform
            // {cos,sin, cx - c0·cos + c0·sin, cy - c0·sin - c0·cos}
            const c0 = RAMP_BLOB_IMG / 2;
            const D2R = std.math.pi / 180.0;
            for (0..2) |c| {
                var j: usize = c;
                var k: usize = 0;
                while (j < s.n) : (j += 2) {
                    const fj: f32 = @floatFromInt(j);
                    const p = rampScatter(j, b.w, b.h);
                    const cx = b.x + 35 + p[0];
                    const cy = b.y + 30 + p[1];
                    const a = (t + fj * 7.0) * D2R;
                    const cs = @cos(a);
                    const sn = @sin(a);
                    s.xfs[k] = .{ .scos = cs, .ssin = sn, .tx = cx - c0 * cs + c0 * sn, .ty = cy - c0 * sn - c0 * cs };
                    k += 1;
                }
                ui.paint.imageDrawAtlas(ctx, s.blob_ids[c], s.xfs[0..k]);
            }
        },
        .text => {
            if (s.ctx != ctx) { // rasterize the string once per ctx — N items share it
                if (s.text_img != 0) {
                    if (s.ctx) |old| ui.paint.imageDestroy(old, s.text_img);
                    s.text_img = 0;
                }
                const STR = "The quick brown fox 0123456789";
                const m = ui.paint.measureText(STR, 14, false);
                s.text_ascent = m.ascent;
                const iw: i32 = @intFromFloat(@ceil(m.width + 2));
                const ih: i32 = @intFromFloat(@ceil(m.ascent + m.descent + 2));
                if (ui.paint.offscreenBegin(ctx, iw, ih)) {
                    ui.paint.text(ctx, STR, 1, m.ascent + 1, 14, false, 0xFFFFFFFF);
                    s.text_img = ui.paint.offscreenEndImage(ctx);
                    s.text_iw = @floatFromInt(iw);
                    s.text_ih = @floatFromInt(ih);
                }
                s.ctx = ctx;
            }
            while (i < s.n) : (i += 1) {
                const fi: f32 = @floatFromInt(i);
                const p = rampScatter(i, b.w, b.h);
                const x = b.x + p[0] + 28 * @sin(0.06 * t + fi * 0.4);
                const baseline = b.y + 14 + p[1];
                s.xfs[i] = .{ .scos = 1, .ssin = 0, .tx = x, .ty = baseline - s.text_ascent - 1 };
            }
            ui.paint.imageDrawAtlas(ctx, s.text_img, s.xfs[0..s.n]);
        },
        .images => {
            if (s.ctx != ctx) { // decode/upload once — startup cost excluded
                if (s.img_id != 0) {
                    if (s.ctx) |old| ui.paint.imageDestroy(old, s.img_id);
                    s.img_id = 0;
                }
                s.img_id = ui.paint.imageCreate(ctx, &s.pixels, 64, 64);
                s.ctx = ctx;
            }
            while (i < s.n) : (i += 1) {
                const fi: f32 = @floatFromInt(i);
                const p = rampScatter(i, b.w, b.h);
                const x = b.x + p[0] + 50 * @sin(0.063 * t + fi * 0.83);
                const y = b.y + p[1] + 45 * @cos(0.081 * t + fi * 0.71);
                s.xfs[i] = .{ .scos = 0.75, .ssin = 0, .tx = x, .ty = y }; // 48/64
            }
            ui.paint.imageDrawAtlas(ctx, s.img_id, s.xfs[0..s.n]);
        },
    }
}
fn rampDeinit(n: *Node) void {
    const s: *RampState = @ptrCast(@alignCast(n.state.?));
    if (s.img_id != 0) {
        if (s.ctx) |ctx| ui.paint.imageDestroy(ctx, s.img_id);
    }
    if (s.text_img != 0) {
        if (s.ctx) |ctx| ui.paint.imageDestroy(ctx, s.text_img);
    }
    for (s.blob_ids) |id| {
        if (id != 0) {
            if (s.ctx) |ctx| ui.paint.imageDestroy(ctx, id);
        }
    }
    n.allocator.destroy(s);
}
const ramp_vtable = ui.node.VTable{ .measure = rampMeasure, .layout = rampLayout, .paint = rampPaint, .deinit = rampDeinit };

fn buildRamp(r: *SceneRunner, kind: RampKind) !*Node {
    const a = r.allocator;
    const node = try Node.create(a, &ramp_vtable);
    errdefer node.allocator.destroy(node);
    const s = try a.create(RampState);
    errdefer a.destroy(s);
    s.* = .{ .kind = kind, .n = @intCast(RAMP_STEPS[0]) };
    if (kind == .paths) tessellateBlob(&s.base_xs, &s.base_ys);
    if (kind == .images) fillChecker(&s.pixels);
    node.state = s;
    r.ramp_node = node;
    return node;
}

/// The 12-point closed bezier for paths_ramp: control points on alternating
/// radii (a lobed blob), closed quadratic-through-midpoints curve, 17
/// segments per edge ≈ 200 pts of tessellation (spec: ~200).
fn tessellateBlob(xs: *[RAMP_PATH_PTS]f32, ys: *[RAMP_PATH_PTS]f32) void {
    var ctrl: [12][2]f32 = undefined;
    for (0..12) |i| {
        const ang = @as(f32, @floatFromInt(i)) * (std.math.pi / 6.0);
        const rad: f32 = if (i % 2 == 0) 18.0 else 11.0;
        ctrl[i] = .{ rad * @cos(ang), rad * @sin(ang) };
    }
    const SEG = RAMP_PATH_PTS / 12;
    var k: usize = 0;
    for (0..12) |i| {
        const p0 = ctrl[i];
        const p1 = ctrl[(i + 1) % 12];
        const p2 = ctrl[(i + 2) % 12];
        const m0 = [2]f32{ (p0[0] + p1[0]) * 0.5, (p0[1] + p1[1]) * 0.5 };
        const m1 = [2]f32{ (p1[0] + p2[0]) * 0.5, (p1[1] + p2[1]) * 0.5 };
        for (0..SEG) |j| {
            const t = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(SEG));
            const u = 1.0 - t;
            xs[k] = u * u * m0[0] + 2 * u * t * p1[0] + t * t * m1[0];
            ys[k] = u * u * m0[1] + 2 * u * t * p1[1] + t * t * m1[1];
            k += 1;
        }
    }
}

/// The 64×64 RGBA test image for images_ramp: an 8 px checkerboard,
/// generated at startup (decode cost excluded — measures sampling/draw).
fn fillChecker(pixels: *[64 * 64 * 4]u8) void {
    for (0..64) |y| {
        for (0..64) |x| {
            const i = (y * 64 + x) * 4;
            const dark = ((x / 8) + (y / 8)) % 2 == 0;
            pixels[i] = if (dark) 0x7C else 0xF5;
            pixels[i + 1] = if (dark) 0x4D else 0xF5;
            pixels[i + 2] = if (dark) 0xFF else 0xF5;
            pixels[i + 3] = 0xFF;
        }
    }
}

// --- scene: overdraw_stack — 24 full-screen rects, alpha 0x1F each ---
// A plain translucent fill would just src-over blend; the spec's cost is the
// saveLayer, so each rect paints inside kx_layer_alpha (like glass_blur).

const OverdrawState = struct { color: Color, alpha: f32 };

fn fillMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = c.max_w, .h = c.max_h });
}
fn noopLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn overdrawPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *OverdrawState = @ptrCast(@alignCast(n.state.?));
    const b = n.bounds;
    ui.paint.layerAlpha(ctx, s.alpha);
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, s.color);
    ui.paint.restore(ctx);
}
fn overdrawDeinit(n: *Node) void {
    n.allocator.destroy(@as(*OverdrawState, @ptrCast(@alignCast(n.state.?))));
}
const overdraw_vtable = ui.node.VTable{ .measure = fillMeasure, .layout = noopLayout, .paint = overdrawPaint, .deinit = overdrawDeinit };

fn buildOverdraw(a: std.mem.Allocator) !*Node {
    const stack = try widgets.layout.stack(a, .{ .fit = .expand });
    stack.retained = true; // static stack — the composited result is a stable image
    for (0..24) |i| {
        const node = try Node.create(a, &overdraw_vtable);
        const s = try a.create(OverdrawState);
        s.* = .{ .color = if (i % 2 == 0) 0x7C4DFFFF else 0x03DAC6FF, .alpha = 31.0 / 255.0 };
        node.state = s;
        stack.add(node);
    }
    return stack;
}

// --- scene: elevation_grid — 10×10 cards, shadow re-rasterized per frame ---
// Real elevation shadows (0.16.0): SkShadowUtils ambient+spot per card —
// the same model as Qt's RectangularGlow/5+1 layer effect and Flutter's
// PhysicalShape — not the old two-translucent-rrect approximation.

const ElevState = struct { i: usize, drive: *Drive };

fn elevMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = 48, .h = 40 });
}
fn elevPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *ElevState = @ptrCast(@alignCast(n.state.?));
    const b = n.bounds;
    // Real M3 elevation shadow (0.16.0): SkShadowUtils ambient+spot pair —
    // the same model Qt's RectangularGlow / Flutter's PhysicalShape run,
    // replacing the two-translucent-rrect stand-in.
    ui.paint.shadowRRect(ctx, b.x, b.y, b.w, b.h, 12, 2.0, 0x00000026, 0x00000061, false);
    const t = @as(f32, @floatFromInt(s.drive.frame));
    const k = 0.04 * @sin(0.15 * t + @as(f32, @floatFromInt(s.i)) * 0.31); // ±4% lightness
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, 12, shiftLight(0x7A7A96FF, k));
}
fn elevDeinit(n: *Node) void {
    n.allocator.destroy(@as(*ElevState, @ptrCast(@alignCast(n.state.?))));
}
const elev_vtable = ui.node.VTable{ .measure = elevMeasure, .layout = noopLayout, .paint = elevPaint, .deinit = elevDeinit };

/// Add k to every RGB channel (±4% ≈ ±10/255 — a cheap lightness wobble).
fn shiftLight(c: Color, k: f32) Color {
    const d: i32 = @intFromFloat(k * 255.0);
    const ch = struct {
        fn f(v: u32, dd: i32) u32 {
            return @intCast(std.math.clamp(@as(i32, @intCast(v)) + dd, 0, 255));
        }
    }.f;
    return (ch((c >> 24) & 0xFF, d) << 24) | (ch((c >> 16) & 0xFF, d) << 16) | (ch((c >> 8) & 0xFF, d) << 8) | (c & 0xFF);
}

fn buildElevationGrid(r: *SceneRunner) !*Node {
    const a = r.allocator;
    const grid = try widgets.layout.grid(a, .{ .columns = 10, .gap = 6, .padding = 16 });
    for (0..100) |i| {
        const cell = try widgets.layout.center(a);
        const node = try Node.create(a, &elev_vtable);
        const s = try a.create(ElevState);
        s.* = .{ .i = i, .drive = &r.drive };
        node.state = s;
        cell.add(node);
        grid.add(cell);
    }
    return grid;
}

// --- scene: relayout_storm — 200 rows animating width 200↔440 dp ---
// The row width is part of MEASURE (not a compositable transform): the tick
// marks the column layout-dirty, so every frame re-measures + re-lays out.

const StormRowState = struct { i: usize, drive: *Drive };

fn stormRowMeasure(n: *Node, c: Constraints) Size {
    const s: *StormRowState = @ptrCast(@alignCast(n.state.?));
    const t = @as(f32, @floatFromInt(s.drive.frame));
    const phase = t * (2.0 * std.math.pi / 120.0) + @as(f32, @floatFromInt(s.i)) * 0.1; // 2 s loop at the nominal 60 Hz
    return c.constrain(.{ .w = 320 + 120 * @sin(phase), .h = 2 });
}
fn stormRowPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *StormRowState = @ptrCast(@alignCast(n.state.?));
    const b = n.bounds;
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, if (s.i % 2 == 0) 0x7C4DFFFF else 0x03DAC6FF);
}
fn stormRowDeinit(n: *Node) void {
    n.allocator.destroy(@as(*StormRowState, @ptrCast(@alignCast(n.state.?))));
}
const storm_row_vtable = ui.node.VTable{ .measure = stormRowMeasure, .layout = noopLayout, .paint = stormRowPaint, .deinit = stormRowDeinit };

fn buildRelayoutStorm(r: *SceneRunner) !*Node {
    const a = r.allocator;
    // cross_align .start: the children keep their (animated) measured width.
    const col = try widgets.layout.column(a, .{ .gap = 0, .padding = 4, .cross_align = .start });
    for (0..200) |i| {
        const node = try Node.create(a, &storm_row_vtable);
        const s = try a.create(StormRowState);
        s.* = .{ .i = i, .drive = &r.drive };
        node.state = s;
        col.add(node);
    }
    r.storm_col = col;
    return col;
}

// --- scene: mount_churn — destroy 50 + create 50 widgets every frame ---
// Steady-state pool of 500 label+icon cards; ids are sequential (the spec's
// "random id" — determinism matters more than entropy for a bench). The
// allocator pressure IS the workload: every card is container+row+icon+text.

const CHURN_POOL = 500;
const CHURN_DELTA = 50;

var churn_prof_latched: ?bool = null;
fn churnCard(a: std.mem.Allocator, id: u64) *Node {
    if (churn_prof_latched == null) churn_prof_latched = std.c.getenv("KLAXON_BENCH_PHASES") != null;
    const prof = churn_prof_latched.?;
    var t0: u64 = 0;
    if (prof) t0 = sdl.c.SDL_GetTicksNS();
    const card = widgets.container.container(a, .{
        .color = if (id % 2 == 0) 0x2A2A3EFF else 0x24303CFF,
        .radius = 6,
        .padding = .{ .left = 8, .top = 4, .right = 8, .bottom = 4 },
    }) catch @panic("klaxon: out of memory");
    const row = widgets.layout.row(a, .{ .gap = 8, .cross_align = .center }) catch @panic("klaxon: out of memory");
    const t1 = sdl.c.SDL_GetTicksNS();
    row.add(widgets.icon.icon(a, .star, .{ .size = 12, .color = 0xFFD54FFF }) catch @panic("klaxon: out of memory"));
    const t2 = sdl.c.SDL_GetTicksNS();
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "card #{d}", .{id}) catch "card";
    row.add(widgets.text.text(a, label, .{ .size = 12, .color = 0xFFFFFFFF }) catch @panic("klaxon: out of memory"));
    if (prof) {
        const t3 = sdl.c.SDL_GetTicksNS();
        std.debug.print("    card: boxes={d}us icon={d}us text={d}us\n", .{ (t1 - t0) / 1000, (t2 - t1) / 1000, (t3 - t2) / 1000 });
    }
    card.add(row);
    return card;
}

fn buildMountChurn(r: *SceneRunner) !*Node {
    const a = r.allocator;
    const col = try widgets.layout.column(a, .{ .gap = 2, .padding = 8 });
    for (0..CHURN_POOL) |i| {
        col.add(churnCard(a, i));
        r.churn_next = i + 1;
    }
    r.churn_parent = col;
    return col;
}

// --- scene: scroll_anim — virtualized list scrolling + pulsing row icons ---
// The icon is a 12×12 dot whose alpha follows the shared drive clock
// (~30 live rows at item_height 16 in the bounded viewport — the spec's
// "30 embedded row icons" ARE the live window of a virtualized 10k list).

const PulseItemCtx = struct { allocator: std.mem.Allocator, drive: *Drive };

/// The pulse overlay: one dot per visible row, repainted EVERY frame —
/// the honest equivalent of the QML delegate's `opacity: banded ?
/// list.pulse : 1.0` (Qt re-issues the band delegates' star each frame).
/// Kept OUT of the row delegates: a dot baked into a retained row slot
/// could never update between rasters — frozen paint would be a fake win.
const PulseOverlayState = struct {
    list: *Node,
    drive: *Drive,
    // The 12x12 dot rasterized ONCE into a shared-atlas slot — the ~30
    // per-frame repaints are tinted slot blits (mesh vertex alpha), the
    // QSG opacity-uniform idiom. Raster/GLES fall back to direct rrects.
    dot_ok: bool = false,
    dot_slot: [4]f32 = .{ 0, 0, 0, 0 },
    dot_gen: u32 = 0,
    dot_serial: u64 = 0,
};

fn pulseOverlayMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = 640, .h = 470 });
}
fn pulseOverlayPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *PulseOverlayState = @ptrCast(@alignCast(n.state.?));
    const b = n.bounds;
    const off = widgets.list_view.scrollOffset(s.list);
    const t = @as(f32, @floatFromInt(s.drive.frame));
    const row_h: f32 = 16;
    const first: usize = @intFromFloat(@max(0, @floor(off / row_h)));
    const last: usize = @intFromFloat(@min(9_999, @floor((off + b.h) / row_h)));
    if (ui.paint.inAtlasPass(ctx)) {
        pulseOverlayDots(ctx, b, off, t, first, last, null);
        return;
    }
    // Establish the atlas tile once per ctx (serial) / atlas regrow (gen).
    const serial = ui.paint.ctxSerial(ctx);
    const gen = ui.paint.atlasGen(ctx);
    if (!s.dot_ok or s.dot_serial != serial or s.dot_gen != gen) {
        s.dot_ok = false;
        if (ui.paint.atlasBegin(ctx, 12, 12, &s.dot_slot)) {
            ui.paint.fillRRect(ctx, 0, 0, 12, 12, 6, 0xFFD54FFF);
            ui.paint.atlasEnd(ctx);
            s.dot_gen = ui.paint.atlasGen(ctx); // post-begin: regrow bumps
            s.dot_serial = serial;
            s.dot_ok = true;
        }
    }
    pulseOverlayDots(ctx, b, off, t, first, last, if (s.dot_ok) s else null);
}

/// Dot pass: the band's ~30 visible rows. With a live atlas slot the dots
/// are tinted blits inside one sprite mesh; without one (raster, nested
/// pass) each paints as its own rrect — same pixels either way.
fn pulseOverlayDots(ctx: *kx.Ctx, b: Rect, off: f32, t: f32, first: usize, last: usize, s: ?*PulseOverlayState) void {
    if (s != null) ui.paint.spriteBatchBegin(ctx);
    defer if (s != null) ui.paint.spriteBatchEnd(ctx);
    const row_h: f32 = 16;
    var row = first;
    while (row <= last) : (row += 1) {
        // Same band rule as the QML: the first 30 visible rows pulse,
        // anything past them stays opaque (at ~30 rows / viewport the
        // band is effectively the whole viewport).
        const in_band = row < first + 30;
        const k = if (in_band)
            0.25 + 0.75 * (0.5 + 0.5 * @sin(0.12 * t + @as(f32, @floatFromInt(row)) * 0.7))
        else
            1.0;
        const y = b.y + @as(f32, @floatFromInt(row)) * row_h - off + 2;
        if (s) |ov| {
            const img = ui.paint.atlasImage(ctx);
            if (img != 0) {
                ui.paint.imageDrawRegionTinted(ctx, img, ov.dot_slot[0], ov.dot_slot[1], ov.dot_slot[2], ov.dot_slot[3], b.x + 2, y, 12, 12, ui.paint.withAlphaScaled(0xFFFFFFFF, k));
                continue;
            }
            ui.paint.fillRRect(ctx, b.x + 2, y, 12, 12, 6, ui.paint.withAlphaScaled(0xFFD54FFF, k));
        } else {
            ui.paint.fillRRect(ctx, b.x + 2, y, 12, 12, 6, ui.paint.withAlphaScaled(0xFFD54FFF, k));
        }
    }
}
fn pulseOverlayHit(n: *Node) Rect {
    _ = n;
    return .{}; // decorative overlay: never a pointer target
}
fn pulseOverlayDeinit(n: *Node) void {
    n.allocator.destroy(@as(*PulseOverlayState, @ptrCast(@alignCast(n.state.?))));
}
const pulse_overlay_vtable = ui.node.VTable{ .measure = pulseOverlayMeasure, .layout = noopLayout, .paint = pulseOverlayPaint, .deinit = pulseOverlayDeinit, .hit_bounds = pulseOverlayHit };

fn scrollAnimItem(userdata: ?*anyopaque, index: usize) *Node {
    const ctx: *PulseItemCtx = @ptrCast(@alignCast(userdata.?));
    const a = ctx.allocator;
    const row = widgets.layout.row(a, .{ .gap = 0, .padding = 2, .cross_align = .center }) catch @panic("klaxon: out of memory");
    // 20px holds the 12px icon + its 8px label gap; the overlay paints
    // the pulsing dot there (kept live per frame, not baked in the slot).
    row.add(widgets.layout.constrainedBox(a, .{ .min_w = 20, .max_w = 20, .min_h = 12, .max_h = 12 }) catch @panic("klaxon: out of memory"));
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "Item #{d}", .{index}) catch "Item";
    row.add(widgets.text.text(a, label, .{ .size = 11, .color = 0xFFFFFFFF }) catch @panic("klaxon: out of memory"));
    return row;
}

/// scroll_anim rows recycle: update the label (the dot lives in the
/// pulse overlay — nothing per-row left to refresh).
fn scrollAnimRebind(userdata: ?*anyopaque, index: usize, node: *Node) bool {
    _ = userdata;
    var buf: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "Item #{d}", .{index}) catch return false;
    widgets.text.setText(node.children.items[1], str);
    return true;
}

fn buildScrollAnim(r: *SceneRunner) !*Node {
    const a = r.allocator;
    const col = try widgets.layout.column(a, .{ .gap = 8 });
    const list = try widgets.list_view.listView(a, .{
        .item_count = 10_000,
        .factory = .{ .fn_ptr = scrollAnimItem, .userdata = &r.pulse_ctx, .rebind = scrollAnimRebind },
        .item_height = 16,
    });
    r.scroll_list = list;
    const stack = try widgets.layout.stack(a, .{ .fit = .expand });
    stack.add(list);
    const overlay = try Node.create(a, &pulse_overlay_vtable);
    const os = try a.create(PulseOverlayState);
    os.* = .{ .list = list, .drive = r.pulse_ctx.drive };
    overlay.state = os;
    stack.add(overlay);
    r.pulse_overlay = overlay;
    const box = try widgets.layout.constrainedBox(a, .{ .max_w = 640, .max_h = 470 });
    box.add(stack);
    col.add(box);
    return col;
}

// --- scene: text_rich — 60 paragraphs × 3 lines of styled spans ---
// Mixed sizes (12/16/20 sp), weight 100..900 + italic + letter-spacing +
// one LTR+RTL bidi line per paragraph. Each richText is ONE shaped
// SkParagraph run (0.15.0) — HarfBuzz + ICU bidi + fallback, the same work
// Flutter/Compose/Qt do per rich-text line.

fn richParagraph(a: std.mem.Allocator) !*Node {
    const col = try widgets.layout.column(a, .{ .gap = 2, .cross_align = .start });
    col.add(try widgets.text.richText(a, &.{
        .{ .text = "The quick brown fox ", .size = 12, .color = 0xE0E0E0FF },
        .{ .text = "jumps", .size = 16, .color = 0xFFFFFFFF, .weight = 800, .letter_spacing = 0.5 },
        .{ .text = " over the lazy dog 0123456789", .size = 12, .color = 0xB0B0B0FF, .italic = true },
    }));
    col.add(try widgets.text.richText(a, &.{
        .{ .text = "Pack my box ", .size = 16, .color = 0xE0E0E0FF },
        .{ .text = "with five dozen", .size = 20, .color = 0xFFD54FFF, .weight = 300 },
        .{ .text = " liquor jugs", .size = 12, .color = 0xB0B0B0FF, .letter_spacing = 1.0 },
    }));
    col.add(try widgets.text.richText(a, &.{
        .{ .text = "مختصر ", .size = 14, .color = 0xE0E0E0FF },
        .{ .text = "Klaxon", .size = 14, .color = 0x03DAC6FF, .bold = true },
        .{ .text = " عربي test اختبار", .size = 14, .color = 0xB0B0B0FF },
    }));
    return col;
}

fn buildTextRich(a: std.mem.Allocator) !*Node {
    const col = try widgets.layout.column(a, .{ .gap = 10, .padding = 16, .cross_align = .start });
    for (0..60) |_| col.add(try richParagraph(a));
    return col;
}

// --- scene: chart_live — 1000-point polyline rebuilt every frame ---
// A dashboard chart: 10×8 grid + one polyline, point arrays preallocated in
// the node state (zero allocs/frame — the rebuild is math + one draw call).

const CHART_PTS = 1000;
const ChartState = struct { drive: *Drive, xs: [CHART_PTS]f32, ys: [CHART_PTS]f32 };

fn chartPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *ChartState = @ptrCast(@alignCast(n.state.?));
    const b = n.bounds;
    var v: usize = 0;
    while (v <= 10) : (v += 1) {
        const x = b.x + @as(f32, @floatFromInt(v)) * b.w / 10.0;
        ui.paint.fillRect(ctx, x, b.y, 1, b.h, 0xFFFFFF1A);
    }
    var h: usize = 0;
    while (h <= 8) : (h += 1) {
        const y = b.y + @as(f32, @floatFromInt(h)) * b.h / 8.0;
        ui.paint.fillRect(ctx, b.x, y, b.w, 1, 0xFFFFFF1A);
    }
    const t = @as(f32, @floatFromInt(s.drive.frame));
    for (0..CHART_PTS) |i| {
        const fi: f32 = @floatFromInt(i);
        s.xs[i] = b.x + fi * b.w / @as(f32, @floatFromInt(CHART_PTS - 1));
        s.ys[i] = b.y + b.h * 0.5 + b.h * 0.38 * (0.7 * @sin(fi * 0.021 + t * 0.11) + 0.3 * @sin(fi * 0.007 - t * 0.05));
    }
    ui.paint.strokePolyline(ctx, &s.xs, &s.ys, 2.0, false, 0x03DAC6FF);
}
fn chartDeinit(n: *Node) void {
    n.allocator.destroy(@as(*ChartState, @ptrCast(@alignCast(n.state.?))));
}
const chart_vtable = ui.node.VTable{ .measure = fillMeasure, .layout = noopLayout, .paint = chartPaint, .deinit = chartDeinit };

fn buildChartLive(r: *SceneRunner) !*Node {
    const a = r.allocator;
    const col = try widgets.layout.column(a, .{ .gap = 8, .padding = 12 });
    col.add(try widgets.text.text(a, "chart_live — 1000 pts, polyline rebuilt every frame", .{ .size = 12, .color = 0xCCCCCCFF }));
    const box = try widgets.layout.constrainedBox(a, .{ .max_w = 640, .max_h = 420 });
    const node = try Node.create(a, &chart_vtable);
    const s = try a.create(ChartState);
    s.* = .{ .drive = &r.drive, .xs = undefined, .ys = undefined };
    node.state = s;
    box.add(node);
    col.add(box);
    return col;
}

// --- scene: clip_path — 120 nodes clipped by a 6-point star path ---
// kx_clip_path (0.12.0) intersects the real polygon clip — the same op as
// Qt's QPainterPath clip; the stripes scroll underneath it per frame.

const StarClipState = struct {
    i: usize,
    drive: *Drive,
    /// Star polygon for the item's (fixed) bounds — computed once, reused by
    /// the clip and the outline stroke every frame.
    xs: [13]f32 = undefined,
    ys: [13]f32 = undefined,
    have_pts: bool = false,
};

fn starClipMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = 56, .h = 36 });
}
fn starClipPaint(n: *Node, ctx: *kx.Ctx) void {
    // Same op set as the reference item (qt StarClipItem::paint): a card
    // fill plus stripes scrolling under the star clip — the stripes are the
    // "contents moving underneath" the spec requires.
    const s: *StarClipState = @ptrCast(@alignCast(n.state.?));
    const b = n.bounds;
    const t = @as(f32, @floatFromInt(s.drive.frame));
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, 0x2A2A3EFF);
    const stripe = 12.0;
    const off = @mod(t * 2.0 + @as(f32, @floatFromInt(s.i)) * 13.0, 2 * stripe);
    var y = b.y - 2 * stripe + off;
    while (y < b.y + b.h + stripe) : (y += 2 * stripe) {
        ui.paint.fillRect(ctx, b.x, y, b.w, stripe, 0x7C4DFFFF);
    }
}
fn starClipPrePaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *StarClipState = @ptrCast(@alignCast(n.state.?));
    const b = n.bounds;
    // The spec's workload: an arbitrary PATH clip (6-point star) — kx_clip_path
    // (0.12.0) is the real thing now, matching Qt's QPainterPath clip.
    if (!s.have_pts) {
        starPts(b, &s.xs, &s.ys);
        s.have_pts = true;
    }
    // Hard scanline clip — same quality level as Qt's setClipPath (no AA
    // render hint).
    ui.paint.clipPath(ctx, s.xs[0..12], s.ys[0..12], false);
}
fn starClipPostPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.clipReset(ctx);
}
fn starClipDeinit(n: *Node) void {
    n.allocator.destroy(@as(*StarClipState, @ptrCast(@alignCast(n.state.?))));
}
const star_clip_vtable = ui.node.VTable{
    .measure = starClipMeasure,
    .layout = starClipLayout,
    .paint = starClipPaint,
    .deinit = starClipDeinit,
    .pre_children_paint = starClipPrePaint,
    .post_children_paint = starClipPostPaint,
};
fn starClipLayout(n: *Node, bounds: Rect) void {
    // The content column is 192 px tall — scrolled under the clip by the
    // paint transform (not by relayout).
    for (n.children.items) |child| child.layout(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = 192 });
}

/// 6-point star: 12 vertices alternating outer/inner radius (closed = 13 pts).
fn starPts(b: Rect, xs: *[13]f32, ys: *[13]f32) void {
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    const r_out = @max(2, @min(b.w, b.h) / 2 - 1);
    const r_in = r_out * 0.45;
    for (0..12) |i| {
        const ang = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * (std.math.pi / 6.0);
        const rad = if (i % 2 == 0) r_out else r_in;
        xs[i] = cx + rad * @cos(ang);
        ys[i] = cy + rad * @sin(ang);
    }
    xs[12] = xs[0];
    ys[12] = ys[0];
}

fn buildClipPath(r: *SceneRunner) !*Node {
    const a = r.allocator;
    const grid = try widgets.layout.grid(a, .{ .columns = 10, .gap = 4, .padding = 8 });
    for (0..120) |i| {
        const node = try Node.create(a, &star_clip_vtable);
        const s = try a.create(StarClipState);
        s.* = .{ .i = i, .drive = &r.drive };
        node.state = s;
        grid.add(node);
    }
    return grid;
}

// --- scene: theme_switch — 200+ node tree, light/dark every 30 frames ---
// Klaxon themes are build-time values, so a switch can't rebuild widgets
// declaratively: the scene's nodes hold BOTH palettes via a shared flip
// flag — the measured cost is the global invalidation repaint (paint with
// the alternate scheme), matching what the other runners' theme switch
// repaints. Documented approximation (spec §C).

const ThemeFlip = struct { dark: bool = false };

const ThemedState = struct { role: usize, flip: *ThemeFlip, label: [24]u8, label_len: u8 };

fn themePair(dark: bool, role: usize) struct { bg: ?Color, fg: Color } {
    const cs = if (dark) &theme_mod.dark.colors else &theme_mod.light.colors;
    return switch (role % 5) {
        0 => .{ .bg = cs.surface_container, .fg = cs.on_surface },
        1 => .{ .bg = cs.primary_container, .fg = cs.on_primary_container },
        2 => .{ .bg = cs.secondary_container, .fg = cs.on_secondary_container },
        3 => .{ .bg = cs.tertiary_container, .fg = cs.on_tertiary_container },
        else => .{ .bg = null, .fg = cs.on_surface }, // text-only row
    };
}
fn themedMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = 56, .h = 26 });
}
fn themedPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *ThemedState = @ptrCast(@alignCast(n.state.?));
    const b = n.bounds;
    const p = themePair(s.flip.dark, s.role);
    if (p.bg) |bg| ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, 8, bg);
    const label = s.label[0..s.label_len :0];
    ui.paint.text(ctx, label, b.x + 6, b.y + b.h / 2 + 4, 11, false, p.fg);
}
fn themedDeinit(n: *Node) void {
    n.allocator.destroy(@as(*ThemedState, @ptrCast(@alignCast(n.state.?))));
}
const themed_vtable = ui.node.VTable{ .measure = themedMeasure, .layout = noopLayout, .paint = themedPaint, .deinit = themedDeinit };

fn buildThemeSwitch(r: *SceneRunner) !*Node {
    const a = r.allocator;
    const col = try widgets.layout.column(a, .{ .gap = 6, .padding = 12 });
    col.retained = true; // static between flips — one raster, re-blit
    for (0..20) |row_i| {
        const row = try widgets.layout.row(a, .{ .gap = 6 });
        for (0..10) |i| {
            const node = try Node.create(a, &themed_vtable);
            const s = try a.create(ThemedState);
            s.* = .{ .role = (row_i + i) % 5, .flip = &r.theme_flip, .label = @splat(0), .label_len = 0 };
            const label = std.fmt.bufPrint(&s.label, "Item {d}", .{row_i * 10 + i}) catch "Item";
            s.label_len = @intCast(@min(label.len, 23));
            node.state = s;
            try r.theme_nodes.append(node);
            row.add(node);
        }
        col.add(row);
    }
    return col;
}

// --- scene: backdrop_scroll — 200 scrolling items under a blur band ---
// Real backdrop blur (0.16.0, σ=12): the band re-filters the scrolled
// content beneath EVERY frame — the honest cost Qt's FastBlur effect and
// Flutter's BackdropFilter pay — replacing the alpha-saveLayer + frosted
// tint stand-in. The band must NOT be retained: its pixels depend on the
// scrolling backdrop under it.

const FrostState = struct {};

fn frostMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = 640, .h = 160 });
}
fn frostPaint(n: *Node, ctx: *kx.Ctx) void {
    const b = n.bounds;
    ui.paint.backdropBlur(ctx, b.x, b.y, b.w, b.h, 12.0);
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, 0, 0xE8E8FF55);
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, 0x00000099); // 60% scrim
}
fn frostDeinit(n: *Node) void {
    n.allocator.destroy(@as(*FrostState, @ptrCast(@alignCast(n.state.?))));
}
const frost_vtable = ui.node.VTable{ .measure = frostMeasure, .layout = noopLayout, .paint = frostPaint, .deinit = frostDeinit, .reads_backdrop = true };

fn buildBackdropScroll(r: *SceneRunner) !*Node {
    const a = r.allocator;
    const stack = try widgets.layout.stack(a, .{ .fit = .expand });
    const list = try widgets.list_view.listView(a, .{
        .item_count = 200,
        .factory = .{ .fn_ptr = benchListItem, .userdata = &r.list_ctx, .rebind = benchListRebind },
        .item_height = 36,
    });
    r.scroll_list = list;
    stack.add(list);
    const top = try widgets.layout.alignTo(a, .{ .alignment = .top_center });
    const band = try Node.create(a, &frost_vtable);
    const s = try a.create(FrostState);
    s.* = .{};
    band.state = s; // not retained — its pixels ride the scrolling backdrop
    top.add(band);
    stack.add(top);
    return stack;
}

// --- scene: input_latency — synthetic event → frames to the visual response ---
// A tap on the responder box lights it; latency_frames = painted_frame -
// event_frame + 1 (the response paints inside the frame it was dispatched on
// → 1), latency_ms = wall time dispatch → end of that paint. The close-out
// runs after the frame's paint (SceneRunner.closeLatency) — a run ending on
// the injected frame still reports both fields.

const LatState = struct {
    drive: *Drive,
    lit: bool = false,
    painted_ns: u64 = 0,
    painted_frame: u64 = 0,
};

fn latMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = 160, .h = 48 });
}
fn latPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *LatState = @ptrCast(@alignCast(n.state.?));
    const b = n.bounds;
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, 8, if (s.lit) 0x03DAC6FF else 0x3A3A4EFF);
    ui.paint.text(ctx, "tap target", b.x + 8, b.y + b.h / 2 + 5, 13, false, 0xFFFFFFFF);
    if (s.lit and s.painted_ns == 0) {
        s.painted_ns = sdl.c.SDL_GetTicksNS();
        s.painted_frame = s.drive.frame;
    }
}
fn latOnPointer(n: *Node, ev: input_mod.PointerEvent) bool {
    const s: *LatState = @ptrCast(@alignCast(n.state.?));
    if (ev.phase == .down and n.bounds.contains(ev.x, ev.y)) {
        s.lit = true;
        n.markDirty();
        return true;
    }
    return ev.phase == .down;
}
fn latDeinit(n: *Node) void {
    n.allocator.destroy(@as(*LatState, @ptrCast(@alignCast(n.state.?))));
}
const lat_vtable = ui.node.VTable{
    .measure = latMeasure,
    .layout = noopLayout,
    .paint = latPaint,
    .deinit = latDeinit,
    .on_pointer = latOnPointer,
};

fn buildInputLatency(r: *SceneRunner) !void {
    const a = r.allocator;
    r.router = input_mod.InputRouter{};
    input_mod.setCurrent(&r.router.?);
    const col = try widgets.layout.column(a, .{ .gap = 12, .padding = 24 });
    col.add(try widgets.text.text(a, "input_latency — pointer event → response paint", .{ .size = 14, .color = 0xCCCCCCFF }));
    const box = try Node.create(a, &lat_vtable);
    const s = try a.create(LatState);
    s.* = .{ .drive = &r.drive };
    box.state = s;
    r.lat_node = box;
    col.add(box);
    r.root = col;
}

// --- scene: pointer_storm — 1000 hit-test queries/frame over a 500-node tree ---

fn buildPointerStorm(a: std.mem.Allocator) !*Node {
    const col = try widgets.layout.column(a, .{ .gap = 4, .padding = 8 });
    col.add(try widgets.text.text(a, "pointer_storm — 1000 hit-tests/frame over 500 nodes", .{ .size = 12, .color = 0xCCCCCCFF }));
    const grid = try widgets.layout.grid(a, .{ .columns = 10, .gap = 4 });
    for (0..500) |i| {
        grid.add(try golden.solidBox(a, 56, 6, if (i % 2 == 0) 0x2A2A3EFF else 0x24303CFF));
    }
    col.add(grid);
    return col;
}

// --- scene: semantics_build — build/diff the a11y tree of 1000 nodes/frame ---
// 250 rows × 4 semantic nodes (icon .image + 3 texts .text) = 1000-node
// semantic tree, built and torn down every frame through the runner
// allocator (the diff cost IS the workload).

fn buildSemanticsScene(a: std.mem.Allocator) !*Node {
    const col = try widgets.layout.column(a, .{ .gap = 4, .padding = 8 });
    for (0..250) |i| {
        const row = try widgets.layout.row(a, .{ .gap = 8, .cross_align = .center });
        row.add(try widgets.icon.icon(a, .star, .{ .size = 12, .color = 0xFFD54FFF }));
        var buf: [32]u8 = undefined;
        for (0..3) |k| {
            const label = std.fmt.bufPrint(&buf, "row {d} cell {d}", .{ i, k }) catch "cell";
            row.add(try widgets.text.text(a, label, .{ .size = 11, .color = 0xE0E0E0FF }));
        }
        col.add(row);
    }
    return col;
}

// --- scene: app_switch — pause→resume cycle every 60 frames ---
// Pause tears down the app subtree (teardown_ms); resume rebuilds + relayouts
// it and reports the wall time until the resumed frame finishes painting
// (resume_ms, averaged over the run's cycles).

fn buildAppContent(a: std.mem.Allocator) !*Node {
    const col = try widgets.layout.column(a, .{ .gap = 8, .padding = 12 });
    for (0..10) |sec| {
        var tbuf: [32]u8 = undefined;
        const title = std.fmt.bufPrint(&tbuf, "Section {d}", .{sec}) catch "Section";
        col.add(try widgets.text.text(a, title, .{ .size = 14, .color = 0xFFFFFFFF }));
        const row = try widgets.layout.row(a, .{ .gap = 8 });
        for (0..4) |i| {
            const card = try widgets.container.container(a, .{
                .color = if ((sec + i) % 2 == 0) 0x2A2A3EFF else 0x24303CFF,
                .radius = 8,
                .padding = EdgeInsets.all(8),
            });
            var lbuf: [32]u8 = undefined;
            const label = std.fmt.bufPrint(&lbuf, "Card {d}", .{sec * 4 + i}) catch "Card";
            card.add(try widgets.text.text(a, label, .{ .size = 12, .color = 0xFFFFFFFF }));
            row.add(card);
        }
        col.add(row);
    }
    return col;
}

fn buildAppSwitch(r: *SceneRunner) !void {
    const a = r.allocator;
    const col = try widgets.layout.column(a, .{ .gap = 8, .padding = 8 });
    col.add(try widgets.text.text(a, "app_switch — pause→resume every 60 frames", .{ .size = 12, .color = 0xCCCCCCFF }));
    const slot = try widgets.layout.column(a, .{});
    r.app_slot = slot;
    col.add(slot);
    r.app_root = try buildAppContent(a);
    slot.add(r.app_root.?);
    r.root = col;
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
        var opts = if (scene == .gallery)
            RunOptions{ .frames = test_opts.frames, .warmup_frames = test_opts.warmup_frames, .width = gallery_mod.WINDOW_W, .height = gallery_mod.WINDOW_H }
        else
            test_opts;
        // Ramp scenes run the first two steps only — the 1600/3200-item steps
        // would take seconds under a Debug test build.
        if (scene.isRamp()) opts.ramp_steps = 2;
        const m = try runSceneWithOpts(scene, std.testing.allocator, opts);
        if (scene.isListOp()) {
            // warmup + 1 op paint + min(frames, 60) measured
            try std.testing.expectEqual(@as(u64, test_opts.warmup_frames + 1 + test_opts.frames), m.frames_rendered);
        } else if (scene.isRamp()) {
            try std.testing.expectEqual(@as(u64, 2 * (test_opts.warmup_frames + test_opts.frames)), m.frames_rendered);
        } else {
            try std.testing.expectEqual(@as(u64, test_opts.warmup_frames + test_opts.frames), m.frames_rendered);
        }
        try std.testing.expect(m.draw_calls_per_frame > 0);
        try std.testing.expect(m.frame_time_avg_ms >= 0);
        try std.testing.expect(m.frame_time_p50_ms <= m.frame_time_p99_ms);
        try std.testing.expect(m.jank_pct >= 0 and m.jank_pct <= 100);
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
    // draw_calls_per_frame is now the REAL submitted-op count
    // (kx_frame_draw_ops, cull-aware): ~64 ops at 640x480 — part of the
    // 10x10 grid is off-surface — not the old node-count proxy (>=100).
    const opts: RunOptions = .{ .frames = test_opts.frames, .warmup_frames = test_opts.warmup_frames, .width = 640, .height = 480 };
    const m = try runSceneWithOpts(.anim_100, std.testing.allocator, opts);
    try std.testing.expect(m.draw_calls_per_frame > 0);
    try std.testing.expectEqual(@as(u64, opts.warmup_frames + opts.frames), m.frames_rendered);
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
    try std.testing.expectEqual(@as(f64, 10), percentile(&s, 99.9)); // p999 = max
    try std.testing.expectEqual(@as(f64, 10), percentile(&s, 100));
    try std.testing.expectEqual(@as(f64, 0), percentile(&[_]f64{}, 99));
}

test "bench: list ops mutate the model and report op_ms" {
    const info = @typeInfo(BenchScene).@"enum";
    inline for (info.field_values) |value| {
        const scene: BenchScene = @fromBackingInt(@intCast(value));
        if (scene.isListOp()) {
            const m = try runSceneWithOpts(scene, std.testing.allocator, test_opts);
            try std.testing.expect(m.extra.op_ms != null);
            try std.testing.expect(m.extra.op_ms.? >= 0);
            try std.testing.expect(m.extra.ramp_len == 0);
        }
    }
    // clear → the list renders empty after the op
    const m = try runSceneWithOpts(.list_clear_1k, std.testing.allocator, test_opts);
    try std.testing.expect(m.draw_calls_per_frame >= 2); // box + list chrome
}

test "bench: ramp scenes report per-step p50 and n_max_60fps" {
    const m = try runSceneWithOpts(.shapes_ramp, std.testing.allocator, .{ .frames = 4, .warmup_frames = 2, .width = 320, .height = 240, .ramp_steps = 3 });
    try std.testing.expectEqual(@as(usize, 3), m.extra.ramp_len);
    try std.testing.expectEqual(@as(u64, 10), m.extra.ramp[0].n);
    try std.testing.expectEqual(@as(u64, 25), m.extra.ramp[1].n);
    try std.testing.expect(m.extra.ramp[0].p50_ms >= 0);
    try std.testing.expect(m.extra.n_max_60fps != null); // tiny steps all pass
    try std.testing.expectEqual(@as(u64, 50), m.extra.n_max_60fps.?);
    try std.testing.expectEqual(@as(u64, 3 * 6), m.frames_rendered);
}

test "bench: input_latency records the event→paint latency" {
    const m = try runSceneWithOpts(.input_latency, std.testing.allocator, test_opts);
    try std.testing.expect(m.extra.latency_ms != null);
    try std.testing.expectEqual(@as(u64, 1), m.extra.latency_frames.?); // paints the dispatch frame
    try std.testing.expect(m.extra.latency_ms.? >= 0);
    // A run ending on the injected frame still reports latency — the close-out
    // is post-paint, not next-frame tick (Devin review: frames=1 regression).
    const one = try runSceneWithOpts(.input_latency, std.testing.allocator, .{ .frames = 1, .warmup_frames = 2, .width = 320, .height = 240 });
    try std.testing.expect(one.extra.latency_ms != null);
    try std.testing.expectEqual(@as(u64, 1), one.extra.latency_frames.?);
    try std.testing.expect(one.extra.latency_ms.? >= 0);
}

test "bench: semantics_build reports nodes per frame" {
    const m = try runSceneWithOpts(.semantics_build, std.testing.allocator, test_opts);
    try std.testing.expect(m.extra.nodes_per_frame != null);
    try std.testing.expect(m.extra.nodes_per_frame.? >= 1000); // 250 rows × 4 + group root
}

test "bench: app_switch cycles teardown/resume over 60 frames" {
    const m = try runSceneWithOpts(.app_switch, std.testing.allocator, .{ .frames = 70, .warmup_frames = 0, .width = 640, .height = 480 });
    try std.testing.expect(m.extra.teardown_ms != null); // fired at frame 30
    try std.testing.expect(m.extra.resume_ms != null); // resumed at frame 60
    try std.testing.expect(m.extra.teardown_ms.? >= 0);
    try std.testing.expect(m.extra.resume_ms.? >= 0);
}

test "bench: jank counters track the 16.67 ms budget" {
    const m = try runSceneWithOpts(.hello, std.testing.allocator, test_opts);
    try std.testing.expect(m.jank_frames <= m.frames_rendered);
    try std.testing.expect(m.jank_pct <= 100);
    try std.testing.expect(m.frame_time_p999_ms >= m.frame_time_p99_ms);
}

/// Android tier-2 entry (gallery_main's SDL_main calls this when the
/// debug.klaxon.bench system property is set): the full catalogue on the
/// activity's real GLES surface — eglSwapBuffers pacing included — with
/// the report written to the app's files dir (read it back via
/// `adb shell run-as <pkg> cat files/bench.json`).
/// `only` (debug.klaxon.scene): restrict the run to the named scene —
/// per-scene iteration without the full catalogue's cost.
/// `phases` (debug.klaxon.phases): print the tick/layout/paint breakdown.
pub fn runAndroidSuite(only: ?[]const u8, phases: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const scene_names = @typeInfo(BenchScene).@"enum".field_names;
    var scenes: [1]BenchScene = undefined;
    var many_scenes: [scene_names.len]BenchScene = undefined;
    var list: []BenchScene = &many_scenes;
    if (only) |name| {
        var found = false;
        inline for (scene_names) |n| {
            if (std.mem.eql(u8, name, n)) {
                scenes[0] = @field(BenchScene, n);
                list = &scenes;
                found = true;
            }
        }
        if (!found) {
            sdl.c.SDL_Log("klaxon bench: unknown scene '%s' — running the full suite", name.ptr);
        }
    }
    if (only == null or list.len != 1) {
        inline for (scene_names, 0..) |n, i| many_scenes[i] = @field(BenchScene, n);
        list = &many_scenes;
    }
    var metrics: [scene_names.len]Metrics = undefined;
    const opts: RunOptions = .{ .windowed = true, .backend = kx.c.KX_BACKEND_GANESH_GLES, .phase_breakdown = phases };
    var ran: usize = 0;
    for (list, 0..) |*scene, i| {
        std.debug.print("klaxon bench: {s} ({d}/{d})...\n", .{ scene.name(), i + 1, list.len });
        metrics[ran] = runSceneWithOpts(scene.*, allocator, opts) catch |err| {
            sdl.c.SDL_Log("klaxon bench: scene %s failed: %s", @tagName(scene.*).ptr, @errorName(err).ptr);
            return err;
        };
        ran += 1;
    }
    const json = try formatReport(allocator, list[0..ran], metrics[0..ran], 0, resolved_backend orelse "ganesh-gles");
    const pref = sdl.c.SDL_GetPrefPath("klaxon", "bench") orelse return error.NoPrefPath;
    defer sdl.c.SDL_free(pref);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}bench.json", .{std.mem.span(pref)}, 0);
    const f = std.c.fopen(path, "wb") orelse return error.CannotWriteReport;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(json.ptr, 1, json.len, f);
    sdl.c.SDL_Log("klaxon bench: report written to %s", path.ptr);
}

// --- JSON report (schema v2, docs/specs/bench-scenes.md) — shared by the
// native bench_main runner and the Android bench entry. ---

/// { "scenes": [ {"name", "fps", "frame_time_*", "jank_*",
/// "draw_calls_per_frame", "rss_mb", "ttff_ms", "frames_rendered",
/// "extra": {…}} ], "binary_size_bytes": N, "backend": name, "timestamp": ISO8601 }
pub fn formatReport(allocator: std.mem.Allocator, scenes: []const BenchScene, metrics: []const Metrics, binary_size_bytes: u64, backend: [*:0]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\n  \"scenes\": [\n");
    for (scenes, metrics, 0..) |scene, m, i| {
        if (i > 0) try buf.appendSlice(allocator, ",\n");
        try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator,
            \\    {{
            \\      "name": "{s}",
            \\      "fps": {d:.1},
            \\      "presented_fps": {d:.1},
            \\      "frame_time_avg_ms": {d:.2},
            \\      "frame_time_p50_ms": {d:.2},
            \\      "frame_time_p99_ms": {d:.2},
            \\      "frame_time_p999_ms": {d:.2},
            \\      "jank_frames": {d},
            \\      "jank_pct": {d:.1},
            \\      "draw_calls_per_frame": {d},
            \\      "rss_mb": {d:.1},
            \\      "ttff_ms": {d:.1},
            \\      "frames_rendered": {d},
            \\      "extra": {s}
            \\    }}
        , .{
            scene.name(),
            m.fps,
            m.presented_fps,
            m.frame_time_avg_ms,
            m.frame_time_p50_ms,
            m.frame_time_p99_ms,
            m.frame_time_p999_ms,
            m.jank_frames,
            m.jank_pct,
            m.draw_calls_per_frame,
            m.rss_mb,
            m.ttff_ms,
            m.frames_rendered,
            try formatExtra(allocator, m.extra),
        }));
    }
    try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\
        \\  ],
        \\  "binary_size_bytes": {d},
        \\  "backend": "{s}",
        \\  "timestamp": "{s}"
        \\}}
        \\
    , .{
        binary_size_bytes,
        std.mem.span(backend),
        try timestampIso8601(allocator),
    }));
    return buf.items;
}

/// The scene-extra object (schema v2): every contract field is emitted;
/// fields the scene didn't produce serialize as null.
fn formatExtra(allocator: std.mem.Allocator, e: Extra) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"op_ms\": ");
    try appendOptF(&buf, allocator, e.op_ms);
    try buf.appendSlice(allocator, ", \"ramp\": ");
    if (e.ramp_len == 0) {
        try buf.appendSlice(allocator, "null");
    } else {
        try buf.appendSlice(allocator, "[");
        for (e.ramp[0..e.ramp_len], 0..) |p, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{{\"n\": {d}, \"p50_ms\": {d:.2}}}", .{ p.n, p.p50_ms }));
        }
        try buf.appendSlice(allocator, "]");
    }
    try buf.appendSlice(allocator, ", \"n_max_60fps\": ");
    try appendOptU(&buf, allocator, e.n_max_60fps);
    try buf.appendSlice(allocator, ", \"latency_ms\": ");
    try appendOptF(&buf, allocator, e.latency_ms);
    try buf.appendSlice(allocator, ", \"latency_frames\": ");
    try appendOptU(&buf, allocator, e.latency_frames);
    try buf.appendSlice(allocator, ", \"nodes_per_frame\": ");
    try appendOptU(&buf, allocator, e.nodes_per_frame);
    try buf.appendSlice(allocator, ", \"teardown_ms\": ");
    try appendOptF(&buf, allocator, e.teardown_ms);
    try buf.appendSlice(allocator, ", \"resume_ms\": ");
    try appendOptF(&buf, allocator, e.resume_ms);
    try buf.appendSlice(allocator, "}");
    return buf.items;
}

fn appendOptF(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: ?f64) !void {
    if (v) |x| {
        try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d:.3}", .{x}));
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn appendOptU(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: ?u64) !void {
    if (v) |x| {
        try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{x}));
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

/// Current UTC time, ISO 8601 ("2026-10-11T14:03:22Z").
fn timestampIso8601(allocator: std.mem.Allocator) ![]const u8 {
    const secs: u64 = if (builtin.os.tag == .windows)
        @intCast(@divFloor(@as(i64, @intCast(std.os.windows.ntdll.RtlGetSystemTimePrecise())), 10_000_000) - 11644473600)
    else blk: {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        break :blk @intCast(ts.sec);
    };
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_sec = epoch.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_sec.getHoursIntoDay(),
        day_sec.getMinutesIntoHour(),
        day_sec.getSecondsIntoMinute(),
    });
}
