// Host — window, event loop (dirty-flag, 0-frame idle), stats (Phase 0.6).
// Converts SDL platform events into ui/input events and routes them into
// the widget tree (Phase 1c). Phase 1e: owns the animation Timeline (ticked
// every loop iteration), repaints clipped to the damage region (dirty-rect,
// the surface is retained between frames), and paces rendering to the
// 8.3 ms frame budget (~120 fps).
// Phase 3f (wasm): the loop body is extracted into runIteration() — one
// pass of drain/tick/render. Native run() keeps its blocking waits
// (SDL_WaitEvent / SDL_WaitEventTimeout); on emscripten run() delegates to
// the rAF main loop in platform_wasm.zig — the browser owns the main
// thread, so nothing in the loop may block (SDL_WaitEvent/SDL_Delay
// busy-poll without Asyncify and freeze the tab).
const std = @import("std");
const builtin = @import("builtin");

// Force-link the a11y bridge C exports (consumed by kx_a11y_macos.mm).
comptime {
    _ = @import("a11y_bridge.zig");
}
const sdl = @import("sdl.zig");
const a11y_bridge = @import("a11y_bridge.zig");
const kx = @import("kx.zig");
const ui = @import("ui.zig");
const input_mod = @import("ui/input.zig");
const semantics_mod = @import("ui/semantics.zig");
const anim = @import("ui/anim.zig");
const devtools_mod = @import("devtools.zig");
const inspector_mod = @import("inspector.zig");

const node_mod = ui.node;
const Node = ui.node.Node;

/// Emscripten target (wasm32-emscripten). The rAF main loop paces the frame
/// loop (platform_wasm.zig); every blocking wait and the SDL_Delay pacing
/// are compiled out under this flag.
pub const is_emscripten = builtin.os.tag == .emscripten;

/// Android target (aarch64-linux-android, Phase 3d) and iOS target
/// (aarch64-ios, Phase 3e). is_mobile gates every mobile branch: the GL
/// context created before kx_create, the pixel-size/DPR handling, the
/// lifecycle events, and the SDL_Log-based log() below.
pub const is_android = builtin.os.tag == .linux and builtin.abi == .android;
pub const is_linux = builtin.os.tag == .linux and builtin.abi != .android;
pub const is_ios = builtin.os.tag == .ios;
pub const is_mobile = is_android or is_ios;

const platform_wasm = if (is_emscripten) @import("platform_wasm.zig") else struct {};

/// Logging (Phase 3d/3e). std.debug.print and @panic route through
/// std.Options.debug_io → std.Io.Threaded, whose Darwin spawn path reads
/// NullFile.fd — a field that does not exist on iOS (Zig 0.17 std bug), so
/// any reachable std.debug.print / @panic fails the iOS compile. On mobile,
/// log through SDL_Log (stderr / OSLog, no std.Io); on native keep
/// std.debug.print. The untaken branch is comptime-pruned, so std.debug is
/// never analyzed for mobile targets.
fn log(comptime fmt: []const u8, args: anytype) void {
    if (is_mobile) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
        sdl.c.SDL_Log("%s", msg.ptr);
    } else {
        std.debug.print(fmt ++ "\n", args);
    }
}

/// Mobile: the layout-to-canvas factor (pixels per layout unit), derived
/// from the real window sizes. SDL_GetWindowDisplayScale is the display
/// density on Android, not this factor (on iOS the two coincide: the Retina
/// DPR, because the window carries SDL_WINDOW_HIGH_PIXEL_DENSITY).
fn displayScaleOf(window: *sdl.c.SDL_Window, layout_w: c_int, pixel_w: c_int) f32 {
    if (layout_w > 0 and pixel_w > 0)
        return @as(f32, @floatFromInt(pixel_w)) / @as(f32, @floatFromInt(layout_w));
    return sdl.c.SDL_GetWindowDisplayScale(window);
}

/// Frame budget: 8.33 ms → 120 fps target (the metrics gate). The whole loop
/// iteration is paced to the budget (slow iterations run unthrottled and flag
/// the timeline's frame_overrun — low-priority animations pause).
const FRAME_BUDGET_NS: u64 = 8_333_333;
const FRAME_BUDGET_MS: f32 = 8.333;
const FRAME_BUDGET_WAIT_MS: u32 = 8; // integer wait granularity for the budget

pub const Stats = struct {
    frames: u64 = 0,
    frame_time_ms: f32 = 0, // begin_frame → present (total frame)
    paint_time_ms: f32 = 0, // begin_frame → end_frame (drives frame_overrun)
    /// Frame timeline breakdown (Phase 4a.4), all in ms.
    layout_time_ms: f32 = 0, // the layout pass (0 when nothing re-laid-out)
    record_time_ms: f32 = 0, // begin_frame → end_frame (record into the surface)
    submit_time_ms: f32 = 0, // readback + texture update + render queue (raster)
    present_time_ms: f32 = 0, // SDL_RenderPresent — the vsync wait (raster)
    backend: [*:0]const u8 = "unknown",
};

pub const OnFrame = *const fn (ctx: ?*anyopaque, frame: u64) void;

// KLAXON_FULL_PRESENT=1 forces the full-surface readback+upload on the
// raster present path — an A/B switch for measuring the damage-scoped
// upload. Latched: getenv is not free in the frame loop.
var full_present_latched: ?bool = null;
fn fullPresentForced() bool {
    if (full_present_latched == null)
        full_present_latched = std.c.getenv("KLAXON_FULL_PRESENT") != null;
    return full_present_latched.?;
}

// KLAXON_DPR=1 forces display_scale = 1 — headless PPM captures and
// benchmark runs want the logical-size surface (a Retina 2x canvas doubles
// every pixel cost and the raster surface is capped at 16384²). Latched:
// getenv is not free in the frame loop.
var dpr_latched: ?f32 = null;
fn forcedDpr() f32 {
    if (dpr_latched == null) {
        dpr_latched = 0;
        if (std.c.getenv("KLAXON_DPR")) |v| {
            const parsed = std.fmt.parseFloat(f32, std.mem.span(v)) catch 0;
            // inf/nan/garbage → ignore: a non-finite scale turns every
            // downstream intFromFloat(surface_px) into a panic. 16× is
            // far past any real display (Retina = 2).
            if (parsed > 0 and std.math.isFinite(parsed)) dpr_latched = @min(parsed, 16);
        }
    }
    return dpr_latched.?;
}

fn sdlSystemCursor(c: input_mod.PointerCursor) sdl.c.SDL_SystemCursor {
    const id: c_int = switch (c) {
        .default => sdl.c.SDL_SYSTEM_CURSOR_DEFAULT,
        .hand => sdl.c.SDL_SYSTEM_CURSOR_POINTER,
        .ibeam => sdl.c.SDL_SYSTEM_CURSOR_TEXT,
        .move => sdl.c.SDL_SYSTEM_CURSOR_MOVE,
        .wait => sdl.c.SDL_SYSTEM_CURSOR_WAIT,
    };
    return @intCast(id);
}

pub const Host = struct {
    allocator: std.mem.Allocator,
    window: *sdl.c.SDL_Window,
    ctx: *kx.Ctx,
    renderer: ?*sdl.c.SDL_Renderer,
    texture: ?*sdl.c.SDL_Texture,
    pixels: []u8,
    width: c_int,
    height: c_int,
    ppm_path: ?[:0]const u8,
    stats: Stats,
    /// DevTools overlay (Phase 4a): disabled by default — F12 (handleEvent)
    /// or --devtools (main) enables it. Zero cost when off.
    devtools: devtools_mod.DevTools = .{},
    /// Inspector panel (Phase 4a.2): disabled by default — F11 (handleEvent)
    /// or --inspector (main) enables it. Zero cost when off.
    inspector: inspector_mod.Inspector,
    input: input_mod.InputRouter,
    timeline: anim.Timeline,
    frame_start_ns: u64 = 0,
    /// Pointer cursors (Phase 2d-0.5, desktop): the app sets this from the
    /// theme's platform tokens (theme.platform.cursors).
    cursors: bool = false,
    cursors_unavailable: bool = false, // headless / no driver: fail-soft
    current_cursor: input_mod.PointerCursor = .default,
    cursor_cache: [5]?*sdl.c.SDL_Cursor = .{ null, null, null, null, null },
    /// Emscripten (wasm): the WebGL2 context created before kx.create — the
    /// GPU shim (kx_skia_wasm.cpp) requires a current GL context at init.
    /// Null on native. SDL_GLContext is already an optional pointer in the
    /// Zig translation.
    gl_ctx: sdl.c.SDL_GLContext = null,
    /// Mobile (Phase 3d/3e): lifecycle gate — false while the app is
    /// backgrounded (WILL/DID_ENTER_BACKGROUND); runIteration skips
    /// rendering while inactive.
    active: bool = true,
    /// The surface-space rect repainted this frame (desktop raster present
    /// path): only that region needs the readback + texture upload. null =
    /// full surface (full repaint, overlays, or GPU backend).
    present_rect: ?sdl.c.SDL_Rect,
    /// Set when SDL_UpdateTexture fails mid-present: the texture keeps stale
    /// pixels for the damaged region, so the NEXT frame takes the
    /// full-repaint path (self-heals) instead of trusting partial damage.
    present_failed: bool = false,
    /// Mobile: window size in pixels (SDL_GetWindowSizeInPixels). The kx
    /// canvas is pixel-sized; width/height stay in points (dp) — the
    /// layout space.
    pixel_width: c_int = 0,
    pixel_height: c_int = 0,
    /// Mobile: pixels per layout unit (Retina DPR on iOS, 1.0 on Android
    /// where the window size is already in pixels). renderFrame scales the
    /// point-space paint onto the pixel canvas by this factor.
    display_scale: f32 = 1.0,
    /// iOS: timestamp (ns) when the UIWindow's root view was first mapped.
    /// -1 = not yet mapped. Presents before mapping are silently lost.
    ios_mapped_ns: i128 = -1,
    /// The bottom safe-area inset last seen while the screen keyboard was
    /// hidden — the nav/gesture bar height. While the keyboard is up the
    /// reported bottom inset is the IME (it occludes the nav region), so
    /// this baseline keeps safe_area.bottom honest during input.
    nav_baseline_bottom: f32 = 0,
    /// Mobile benchmark aid (Phase 4c): ns timestamp of the last periodic
    /// fps log (windowed over 600 frames).
    fps_log_ns: i128 = 0,
    /// Mobile benchmark aid: sum of frame work times over the current window.
    fps_log_time_sum: f32 = 0,
    /// GPU warmup (Phase 4e.1): kx_gpu_warmup ran once (after the first
    /// present). False until then; raster backends skip the call entirely.
    gpu_warmed: bool = false,
    /// IME lifecycle: the platform text input is active while a
    /// wants_text_input node holds focus (SDL_StartTextInput/StopTextInput
    /// — the soft keyboard on mobile, the IME session on desktop).
    ime_active: bool = false,
    /// The node the IME is anchored to — its bounds feed
    /// SDL_SetTextInputArea each frame so the candidate window tracks
    /// layout moves. Distinct from input.focused: a non-editable focus
    /// means the IME is simply down.
    ime_node: ?*Node = null,

    pub fn init(
        allocator: std.mem.Allocator,
        width: c_int,
        height: c_int,
        backend: kx.c.kx_backend,
        ppm_path: ?[:0]const u8,
    ) !Host {
        // Init stage timing (Phase 4e.1): retail TTFF is 126 ms against a
        // < 20 ms budget; this one log line localizes the cost (SDL vs
        // window vs GL context vs Skia init) on the next device run.
        const t_init = sdl.c.SDL_GetTicksNS();
        if (!sdl.c.SDL_Init(sdl.c.SDL_INIT_VIDEO)) {
            log("SDL_Init failed: {s}", .{sdl.c.SDL_GetError()});
            return error.SdlInit;
        }
        errdefer sdl.c.SDL_Quit();
        // The widget layer's clipboard rides SDL (installed once; widgets
        // stay SDL-free). The allocator feeds SDL_SetClipboardText copies.
        clipboard_allocator = allocator;
        ui.clipboard.install(.{ .get = clipboardGetImpl, .set = clipboardSetImpl });
        // Layer-4 services ride SDL the same way (installed once; the
        // service modules stay SDL-free). Haptics has no SDL-level API —
        // the contract stays uninstalled = documented no-op.
        ui.platform.url.install(.{ .open = sdlOpenUrl });
        ui.platform.picker.install(.{ .open_file = sdlOpenFileDialog, .save_file = sdlSaveFileDialog });
        ui.platform.paths.install(.{ .resolve = sdlResolveDir });
        const t_sdl = sdl.c.SDL_GetTicksNS();

        // PPM dumps go through kx_readback_rgba — raster surfaces only.
        if (ppm_path != null and backend != kx.c.KX_BACKEND_RASTER)
            log("warning: --ppm requires the raster backend; no PPM will be written", .{});

        // Emscripten (wasm) + Android: request a GLES (ES 3.0) context before
        // window creation — the GPU shims (kx_skia_wasm.cpp,
        // kx_skia_android.cpp) need a current GL context when kx.create
        // runs. Double-buffered, no depth buffer, 8-bit stencil.
        // iOS has no GL path (metal → raster only, per the backend contract).
        // wasm: only WebGL2 claims the canvas via GL — Graphite WebGPU and
        // raster must NOT create a GL context (a canvas supports exactly one
        // context type; WebGL first would make navigator.gpu fail).
        const need_gl_attrs = is_android or
            (is_emscripten and backend == kx.c.KX_BACKEND_GANESH_WEBGL2);
        if (need_gl_attrs) {
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_MAJOR_VERSION), 3);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_MINOR_VERSION), 0);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_PROFILE_MASK), sdl.c.SDL_GL_CONTEXT_PROFILE_ES);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_DOUBLEBUFFER), 1);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_DEPTH_SIZE), 0);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_STENCIL_SIZE), 8);
        }
        // Linux Ganesh GL: desktop GL context (not ES). 3.3 core covers
        // Ganesh's requirements; 8-bit stencil for clip masks, double
        // buffering for swaps. SDL picks GLX or EGL under the hood.
        // AUTO prepares for the chain's GPU member (ganesh-gl on linux) —
        // kx_create does the actual chain walk.
        const need_desktop_gl_attrs = is_linux and
            (backend == kx.c.KX_BACKEND_GANESH_GL or backend == kx.c.KX_BACKEND_AUTO);
        if (need_desktop_gl_attrs) {
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_MAJOR_VERSION), 3);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_MINOR_VERSION), 3);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_PROFILE_MASK), sdl.c.SDL_GL_CONTEXT_PROFILE_CORE);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_DOUBLEBUFFER), 1);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_DEPTH_SIZE), 0);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_STENCIL_SIZE), 8);
        }
        // Emscripten: pin the canvas selector before SDL creates the window —
        // on the pinned SDL/emsdk combo SDL_GetHint() returns "" rather than
        // NULL for this unset hint, and Emscripten_CreateWindow then calls
        // querySelector("") which throws mid-creation.
        if (is_emscripten) {
            _ = sdl.c.SDL_SetHintWithPriority(
                sdl.c.SDL_HINT_EMSCRIPTEN_CANVAS_SELECTOR,
                "#canvas",
                sdl.c.SDL_HINT_OVERRIDE,
            );
        }
        // Linux Vulkan leg is only possible when the video driver answers
        // the extension probe — loading the lib succeeds even under the
        // dummy driver, but GetInstanceExtensions reflects the driver's
        // actual surface support. The probe ref is released again — the
        // shim does its own LoadLibrary inside kx.create. Unused off linux.
        var vk_ext_count: c_uint = 0;
        const vulkan_possible = is_linux and
            (backend == kx.c.KX_BACKEND_GRAPHITE_VULKAN or backend == kx.c.KX_BACKEND_AUTO) and
            sdl.c.SDL_Vulkan_LoadLibrary(null) and
            (sdl.c.SDL_Vulkan_GetInstanceExtensions(&vk_ext_count) != null and vk_ext_count > 0);
        if (vulkan_possible) sdl.c.SDL_Vulkan_UnloadLibrary();
        const window_flags: u64 = if (is_emscripten)
            // OPENGL claims the canvas for WebGL2 — WebGPU/raster must not
            // set it (single context type per canvas).
            if (backend == kx.c.KX_BACKEND_GANESH_WEBGL2)
                sdl.c.SDL_WINDOW_OPENGL
            else
                0
        else if (is_android)
            // OPENGL only: the activity theme (NoTitleBar.Fullscreen) already
            // covers the screen. SDL_WINDOW_FULLSCREEN would switch the window
            // to immersive-sticky mode, whose ImmersiveModeConfirmation dialog
            // steals window focus (headless emulators never dismiss it) — the
            // app then stops rendering (host.active = false).
            sdl.c.SDL_WINDOW_OPENGL
        else if (is_ios)
            // HIGH_PIXEL_DENSITY: without it SDL_GetWindowSizeInPixels
            // reports points on iOS — the DPR model needs real pixels.
            // METAL for everything GPU (graphite-metal attaches the
            // SDL_MetalView itself; AUTO resolves to it), raster gets the
            // SDL software renderer.
            if (backend == kx.c.KX_BACKEND_RASTER)
                sdl.c.SDL_WINDOW_HIGH_PIXEL_DENSITY
            else
                sdl.c.SDL_WINDOW_METAL | sdl.c.SDL_WINDOW_HIGH_PIXEL_DENSITY
        else if (is_linux)
            // AUTO/graphite-vulkan: VULKAN window first — no GL context is
            // created for the Vulkan attempt (SDL_Vulkan_CreateSurface
            // requires the flag). Only when the driver can actually serve
            // Vulkan: a VULKAN-flagged create on a driver without surface
            // support (dummy/headless) leaves SDL video half-initialized and
            // even a plain-window retry then fails. The extension probe is
            // the driver's own capability answer. Explicit ganesh-gl:
            // OPENGL. Raster stays on the software renderer.
            if (vulkan_possible)
                sdl.c.SDL_WINDOW_VULKAN
            else if (backend == kx.c.KX_BACKEND_GANESH_GL or backend == kx.c.KX_BACKEND_AUTO)
                sdl.c.SDL_WINDOW_OPENGL
            else
                0
        else
            // Desktop (macOS/Windows): HIGH_PIXEL_DENSITY so
            // SDL_GetWindowSizeInPixels reports real backing pixels on
            // Retina/HiDPI instead of synthesizing 1:1 points — without it
            // every backend renders at logical size and SDL/Cocoa upscales
            // the result, which is the blurry look this fixes.
            sdl.c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        // Linux only: the first window carries SDL_WINDOW_VULKAN — if the
        // backend chain falls through to raster, the ganesh-gl leg is retried
        // below on a recreated OPENGL window (see the retry block after
        // kx_create).
        const vulkan_window_first = is_linux and vulkan_possible;
        // Android: SDLActivity starts the SDL thread only once the surface is
        // ready, but it never creates an SDL window object — the app must call
        // SDL_CreateWindow (SDL attaches the activity's surface; Android
        // supports exactly one window). Reuse a pre-existing window if some
        // flow already created one, otherwise create it ourselves.
        var android_owns_window = false;
        var resolved_backend = backend;
        var window: *sdl.c.SDL_Window = if (is_android) blk: {
            var count: c_int = 0;
            if (sdl.c.SDL_GetWindows(&count)) |windows| {
                defer sdl.c.SDL_free(@ptrCast(windows)); // the array is a single SDL-owned allocation
                if (count > 0) {
                    if (windows[0]) |win| break :blk win;
                }
            }
            // Request the display's natural size: Android_CreateWindow passes
            // the requested w/h to setOrientation, and a fixed (non-resizable)
            // window locks orientation by aspect — requesting a size whose
            // aspect differs from the device rotates the activity (surface
            // churn → stale EGL surface → rejected swaps, frozen screen).
            var req_w = width;
            var req_h = height;
            const display = sdl.c.SDL_GetPrimaryDisplay();
            if (display != 0) {
                if (sdl.c.SDL_GetCurrentDisplayMode(display)) |mode| {
                    if (mode.*.w > 0 and mode.*.h > 0) {
                        req_w = mode.*.w;
                        req_h = mode.*.h;
                    }
                }
            }
            const win = sdl.c.SDL_CreateWindow("klaxon gallery", req_w, req_h, window_flags) orelse {
                log("SDL_CreateWindow failed: {s}", .{sdl.c.SDL_GetError()});
                return error.SdlWindow;
            };
            android_owns_window = true;
            break :blk win;
        } else blk: {
            if (sdl.c.SDL_CreateWindow("klaxon hello", width, height, window_flags)) |w|
                break :blk w;
            // Linux GPU is optional: when the video driver cannot create an
            // OpenGL window at all (headless dummy driver, missing GL
            // support) retry without the flag and resolve to raster, same
            // as the SDL_GL_CreateContext fallback below.
            if (is_linux and (backend == kx.c.KX_BACKEND_GANESH_GL or backend == kx.c.KX_BACKEND_AUTO)) {
                log("SDL_CreateWindow(OPENGL) failed ({s}) — retrying without GL", .{sdl.c.SDL_GetError()});
                const w = sdl.c.SDL_CreateWindow("klaxon hello", width, height, 0) orelse {
                    log("SDL_CreateWindow failed: {s}", .{sdl.c.SDL_GetError()});
                    return error.SdlWindow;
                };
                resolved_backend = kx.c.KX_BACKEND_RASTER;
                break :blk w;
            }
            log("SDL_CreateWindow failed: {s}", .{sdl.c.SDL_GetError()});
            return error.SdlWindow;
        };
        if (!is_android or android_owns_window) {
            errdefer sdl.c.SDL_DestroyWindow(window);
        }
        dialog_window = window; // file dialogs parent to this window
        const t_win = sdl.c.SDL_GetTicksNS();

        // Emscripten (wasm) + Android + Linux-GL: create the GL context and
        // make it current BEFORE kx.create — gpu_init checks
        // SDL_GL_GetCurrentContext. iOS/macOS Metal: no GL context (Metal
        // view instead). Linux AUTO/graphite-vulkan: deliberately none — the
        // Vulkan attempt must not have a GL context; if it fails, the GL leg
        // is retried on a recreated OPENGL window below. Raster: none.
        var gl_ctx: sdl.c.SDL_GLContext = null;
        // wasm: only WebGL2 claims the canvas via GL — Graphite WebGPU and
        // raster must NOT create a GL context (a canvas supports exactly one
        // context type; WebGL first would make navigator.gpu fail). iOS has
        // no GL path. Linux AUTO takes the Vulkan window first — no GL
        // context on that leg; the GL retry happens on a recreated OPENGL
        // window if the chain settles on raster. AUTO without a usable
        // Vulkan driver goes straight to an OPENGL window and needs the
        // context now — ganesh-gl is the next leg.
        const linux_gl_first = is_linux and
            (backend == kx.c.KX_BACKEND_GANESH_GL or (backend == kx.c.KX_BACKEND_AUTO and !vulkan_possible));
        const need_gl = is_android or
            (is_emscripten and backend == kx.c.KX_BACKEND_GANESH_WEBGL2) or
            linux_gl_first;
        if (need_gl) {
            gl_ctx = sdl.c.SDL_GL_CreateContext(window);
            if (gl_ctx == null) {
                if (linux_gl_first) {
                    // Linux GPU is optional: no GL context (headless, missing
                    // driver) → recreate the window without OPENGL and run
                    // raster instead of failing.
                    log("SDL_GL_CreateContext failed ({s}) — falling back to raster", .{sdl.c.SDL_GetError()});
                    sdl.c.SDL_DestroyWindow(window);
                    window = sdl.c.SDL_CreateWindow("klaxon hello", width, height, 0) orelse {
                        log("SDL_CreateWindow failed: {s}", .{sdl.c.SDL_GetError()});
                        return error.SdlWindow;
                    };
                    resolved_backend = kx.c.KX_BACKEND_RASTER;
                } else {
                    log("SDL_GL_CreateContext failed: {s}", .{sdl.c.SDL_GetError()});
                    return error.SdlGlContext;
                }
            } else {
                _ = sdl.c.SDL_GL_MakeCurrent(window, gl_ctx);
                _ = sdl.c.SDL_GL_SetSwapInterval(0); // the platform paces the loop (rAF / CADisplayLink / vsync)
            }
        }
        errdefer {
            if (gl_ctx) |ctx| _ = sdl.c.SDL_GL_DestroyContext(ctx);
        }
        const t_gl = sdl.c.SDL_GetTicksNS();

        // Text input is focus-gated (syncIme): SDL_StartTextInput runs
        // only while a wants_text_input node holds focus — the mobile soft
        // keyboard appears on field focus, the desktop IME session anchors
        // its candidate window at the field.

        // Mobile: the real window size comes from SDL after creation (the
        // caller may pass 0x0 — iOS ignores the requested size and goes
        // fullscreen): points → width/height (the layout space), pixels →
        // pixel_width/pixel_height (the kx canvas is pixel-sized).
        var win_w = width;
        var win_h = height;
        var pixel_w: c_int = width;
        var pixel_h: c_int = height;
        var display_scale: f32 = 1.0;
        // All platforms: logical window size (layout space) vs backing pixel
        // size (canvas space). On desktop they differ whenever the display
        // scale isn't 1.0 (Retina 2x, Windows 150%, Wayland fractional).
        _ = sdl.c.SDL_GetWindowSize(window, &win_w, &win_h);
        _ = sdl.c.SDL_GetWindowSizeInPixels(window, &pixel_w, &pixel_h);
        display_scale = displayScaleOf(window, win_w, pixel_w);
        // Test/capture override: force the layout:canvas factor (the
        // pixel buffer/texture stay at logical size below).
        if (forcedDpr() > 0) {
            display_scale = forcedDpr();
            pixel_w = @intFromFloat(@as(f32, @floatFromInt(win_w)) * display_scale);
            pixel_h = @intFromFloat(@as(f32, @floatFromInt(win_h)) * display_scale);
        }

        // kx_create walks the backend fallback chain internally (explicit
        // request → itself → raster; AUTO → full platform chain → raster).
        var ctx = kx.create(@ptrCast(window), pixel_w, pixel_h, resolved_backend) orelse {
            log("kx_create failed (backend {s})", .{kx.c.kx_backend_name(resolved_backend)});
            return error.KxCreate;
        };
        resolved_backend = kx.c.kx_backend_of(ctx); // the backend that actually won
        errdefer kx.c.kx_destroy(ctx);

        // Linux Vulkan-first windows carry no GL context, so the AUTO
        // chain's ganesh-gl leg could not actually run (gpu_init needs a
        // current SDL GL context) — if the chain settled on raster, retry
        // the GL leg on a recreated OPENGL window before settling. An
        // explicit graphite-vulkan that fell through to raster also gets a
        // plain window (the VULKAN flag is meaningless without the shim's
        // swapchain).
        if (vulkan_window_first and resolved_backend == kx.c.KX_BACKEND_RASTER) {
            if (backend == kx.c.KX_BACKEND_AUTO) {
                const gl_window = sdl.c.SDL_CreateWindow("klaxon hello", width, height, sdl.c.SDL_WINDOW_OPENGL) orelse {
                    log("SDL_CreateWindow failed: {s}", .{sdl.c.SDL_GetError()});
                    return error.SdlWindow;
                };
                const new_gl = sdl.c.SDL_GL_CreateContext(gl_window);
                if (new_gl == null) {
                    // No GL either — keep the raster ctx (it never references
                    // the window) and settle on a plain window.
                    log("SDL_GL_CreateContext failed ({s}) — staying on raster", .{sdl.c.SDL_GetError()});
                    sdl.c.SDL_DestroyWindow(gl_window);
                    const plain = sdl.c.SDL_CreateWindow("klaxon hello", width, height, 0) orelse {
                        log("SDL_CreateWindow failed: {s}", .{sdl.c.SDL_GetError()});
                        return error.SdlWindow;
                    };
                    sdl.c.SDL_DestroyWindow(window);
                    window = plain;
                    // syncIme re-arms text input on the new window
                } else {
                    _ = sdl.c.SDL_GL_MakeCurrent(gl_window, new_gl);
                    _ = sdl.c.SDL_GL_SetSwapInterval(0); // the platform paces the loop
                    const gl_kx = kx.create(@ptrCast(gl_window), pixel_w, pixel_h, kx.c.KX_BACKEND_GANESH_GL) orelse {
                        _ = sdl.c.SDL_GL_DestroyContext(new_gl);
                        sdl.c.SDL_DestroyWindow(gl_window);
                        log("kx_create retry failed (backend ganesh-gl)", .{});
                        return error.KxCreate;
                    };
                    // Swap succeeded — drop the transient raster ctx and the
                    // vulkan window.
                    kx.c.kx_destroy(ctx);
                    sdl.c.SDL_DestroyWindow(window);
                    ctx = gl_kx;
                    window = gl_window;
                    gl_ctx = new_gl;
                    resolved_backend = kx.c.kx_backend_of(ctx);
                    // syncIme re-arms text input on the new window
                }
            } else {
                const plain = sdl.c.SDL_CreateWindow("klaxon hello", width, height, 0) orelse {
                    log("SDL_CreateWindow failed: {s}", .{sdl.c.SDL_GetError()});
                    return error.SdlWindow;
                };
                sdl.c.SDL_DestroyWindow(window);
                window = plain;
                // syncIme re-arms text input on the new window
            }
        }
        // Emscripten AUTO tries Graphite WebGPU first (without an OpenGL
        // context on the canvas). If WebGPU is unavailable and the chain fell
        // through to raster, retry Ganesh WebGL2 on an OPENGL window with a
        // current GLES 3.0 context before settling on raster.
        if (is_emscripten and backend == kx.c.KX_BACKEND_AUTO and resolved_backend == kx.c.KX_BACKEND_RASTER) {
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_MAJOR_VERSION), 3);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_MINOR_VERSION), 0);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_PROFILE_MASK), sdl.c.SDL_GL_CONTEXT_PROFILE_ES);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_DOUBLEBUFFER), 1);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_DEPTH_SIZE), 0);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_STENCIL_SIZE), 8);
            sdl.c.SDL_DestroyWindow(window);
            window = sdl.c.SDL_CreateWindow("klaxon hello", width, height, sdl.c.SDL_WINDOW_OPENGL) orelse
                sdl.c.SDL_CreateWindow("klaxon hello", width, height, 0) orelse return error.SdlWindow;
            if (sdl.c.SDL_GL_CreateContext(window)) |new_gl| {
                _ = sdl.c.SDL_GL_MakeCurrent(window, new_gl);
                _ = sdl.c.SDL_GL_SetSwapInterval(0);
                if (kx.create(@ptrCast(window), pixel_w, pixel_h, kx.c.KX_BACKEND_GANESH_WEBGL2)) |gl_kx| {
                    kx.c.kx_destroy(ctx);
                    ctx = gl_kx;
                    gl_ctx = new_gl;
                    resolved_backend = kx.c.kx_backend_of(ctx);
                } else {
                    _ = sdl.c.SDL_GL_DestroyContext(new_gl);
                }
            }
        }
        const t_kx = sdl.c.SDL_GetTicksNS();
        log("init stages: sdl {d:.1} ms, window {d:.1} ms, gl-ctx {d:.1} ms, kx-create {d:.1} ms", .{
            @as(f32, @floatFromInt(t_sdl - t_init)) / 1e6,
            @as(f32, @floatFromInt(t_win - t_sdl)) / 1e6,
            @as(f32, @floatFromInt(t_gl - t_win)) / 1e6,
            @as(f32, @floatFromInt(t_kx - t_gl)) / 1e6,
        });

        // Raster presents through an SDL streaming texture; GPU backends present
        // inside the shim (onscreen surface attached to the window). Mobile:
        // the GPU shim presents (Metal / EGL swap), but raster has no GPU
        // shim to swap inside — without the SDL renderer the frames draw
        // into a CPU buffer that never reaches the screen (iOS's software
        // Metal made the same case explicit: SDL software renderer is the
        // reliable present path whenever the resolved backend is raster).
        const use_sdl_present = !is_mobile or resolved_backend == kx.c.KX_BACKEND_RASTER;
        const renderer = if (use_sdl_present and resolved_backend == kx.c.KX_BACKEND_RASTER)
            sdl.c.SDL_CreateRenderer(window, null) orelse return error.SdlRenderer
        else
            null;
        errdefer {
            if (renderer) |r| sdl.c.SDL_DestroyRenderer(r);
        }

        const texture = if (!use_sdl_present)
            null
        else if (renderer) |r|
            sdl.c.SDL_CreateTexture(r, sdl.c.SDL_PIXELFORMAT_ABGR8888, sdl.c.SDL_TEXTUREACCESS_STREAMING, pixel_w, pixel_h) orelse return error.SdlTexture
        else
            null;
        errdefer {
            if (texture) |t| sdl.c.SDL_DestroyTexture(t);
        }

        // CPU pixel buffer only for the raster+SDL present path — on GPU
        // backends the shim presents and kx_readback_rgba always fails, so
        // allocating w*h*4 here would be dead memory (~33 MB at 4K).
        const pixels: []u8 = if (renderer == null)
            &[_]u8{}
        else
            try allocator.alloc(u8, @as(usize, @intCast(pixel_w)) * @as(usize, @intCast(pixel_h)) * 4);
        errdefer allocator.free(pixels);

        const backend_name: [*:0]const u8 = kx.c.kx_backend_name(resolved_backend) orelse "unknown";

        const inspector = try inspector_mod.Inspector.init(allocator);
        errdefer inspector.deinit();

        // Memory ledger (Phase 4a.3): the raster pixel buffer is the
        // renderer subsystem's tracked allocation (freed in deinit/resize).
        var devtools = devtools_mod.DevTools{};
        devtools.ledger.recordAlloc(.renderer, pixels.len);

        return .{
            .allocator = allocator,
            .window = window,
            .ctx = ctx,
            .gl_ctx = gl_ctx,
            .renderer = renderer,
            .texture = texture,
            .pixels = pixels,
            .present_rect = null,
            .width = win_w,
            .height = win_h,
            .pixel_width = pixel_w,
            .pixel_height = pixel_h,
            .display_scale = display_scale,
            .ppm_path = ppm_path,
            .stats = .{ .backend = backend_name },
            .devtools = devtools,
            .inspector = inspector,
            .input = .{},
            .timeline = anim.Timeline.init(allocator),
        };
    }

    /// The widget layer's clipboard rides SDL on every platform (installed
    /// in init above — ui.clipboard keeps widgets SDL-free).
    var clipboard_allocator: ?std.mem.Allocator = null;
    fn clipboardSetImpl(text: []const u8) void {
        const alloc = clipboard_allocator orelse return;
        // SDL_SetClipboardText wants a C string — copy with a sentinel.
        const z = alloc.alloc(u8, text.len + 1) catch return;
        defer alloc.free(z);
        @memcpy(z[0..text.len], text);
        z[text.len] = 0;
        _ = sdl.c.SDL_SetClipboardText(z.ptr);
    }
    fn clipboardGetImpl(alloc: std.mem.Allocator) ?[]u8 {
        const p = sdl.c.SDL_GetClipboardText() orelse return null;
        defer sdl.c.SDL_free(@ptrCast(p));
        const str = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        if (str.len == 0) return null;
        return alloc.dupe(u8, str) catch null;
    }

    // ---- Layer-4 platform services, SDL-backed (installed in init) ----
    // url/file-picker/paths are install contracts in ui.platform; these
    // impls wire them to real SDL calls on every platform SDL covers.

    /// The window file dialogs are modal to (set after window creation;
    /// null is legal — dialogs just aren't parented).
    var dialog_window: ?*sdl.c.SDL_Window = null;

    /// allocSentinel + copy — every SDL C-string the services hand over.
    fn dupeZ(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
        const z = try a.allocSentinel(u8, s.len, 0);
        @memcpy(z, s);
        return z;
    }

    fn sdlOpenUrl(url: []const u8) bool {
        const alloc = clipboard_allocator orelse return false;
        const z = alloc.allocSentinel(u8, url.len, 0) catch return false;
        defer alloc.free(z);
        @memcpy(z, url);
        return sdl.c.SDL_OpenURL(z.ptr);
    }

    const Picker = ui.platform.file_picker;

    /// One pending dialog's lifetime: the picker strings (title, location,
    /// filter name/patterns) must stay valid until SDL's callback fires,
    /// and the delivered path list needs somewhere to live — one arena
    /// covers both, freed after the app callback runs on the main thread.
    const DialogCtx = struct {
        cb: Picker.Callback,
        userdata: ?*anyopaque,
        arena: std.heap.ArenaAllocator,
        status: Picker.Status = .err,
        paths: []const []const u8 = &.{},
    };

    fn dialogDeliverMain(ud: ?*anyopaque) callconv(.c) void {
        const ctx: *DialogCtx = @ptrCast(@alignCast(ud orelse return));
        ctx.cb(ctx.userdata, ctx.status, ctx.paths);
        const alloc = ctx.arena.child_allocator;
        ctx.arena.deinit();
        alloc.destroy(ctx);
    }

    fn sdlDialogCb(ud: ?*anyopaque, filelist: [*c]const [*c]const u8, filter: c_int) callconv(.c) void {
        _ = filter;
        const ctx: *DialogCtx = @ptrCast(@alignCast(ud orelse return));
        const list = filelist orelse {
            ctx.status = .err;
            if (!sdl.c.SDL_RunOnMainThread(dialogDeliverMain, ctx, false)) dialogDeliverMain(ctx);
            return;
        };
        var n: usize = 0;
        while (list[n] != null) n += 1;
        if (n == 0) {
            ctx.status = .cancelled;
        } else ok: {
            const a = ctx.arena.allocator();
            const items = a.alloc([]const u8, n) catch break :ok;
            for (items, 0..) |*item, i| {
                item.* = a.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(list[i])))) catch break :ok;
            }
            ctx.paths = items;
            ctx.status = .ok;
        }
        // SDL may invoke this on a worker thread (Android result dispatch);
        // the widget-facing contract is main-thread only.
        if (!sdl.c.SDL_RunOnMainThread(dialogDeliverMain, ctx, false)) dialogDeliverMain(ctx);
    }

    fn sdlShowDialog(
        save: bool,
        title: ?[]const u8,
        default_path: ?[]const u8,
        filters: []const Picker.FileFilter,
        allow_many: bool,
        cb: Picker.Callback,
        userdata: ?*anyopaque,
    ) void {
        const alloc = clipboard_allocator orelse return cb(userdata, .unavailable, &.{});
        const ctx = alloc.create(DialogCtx) catch return cb(userdata, .err, &.{});
        ctx.* = .{ .cb = cb, .userdata = userdata, .arena = std.heap.ArenaAllocator.init(alloc) };
        var shown = false;
        // Any setup failure delivers .err through the same path SDL uses.
        defer if (!shown) dialogDeliverMain(ctx);

        const a = ctx.arena.allocator();
        const props = sdl.c.SDL_CreateProperties();
        if (props == 0) return;
        defer sdl.c.SDL_DestroyProperties(props);

        if (title) |t| {
            const z = dupeZ(a, t) catch return;
            _ = sdl.c.SDL_SetStringProperty(props, sdl.c.SDL_PROP_FILE_DIALOG_TITLE_STRING, z.ptr);
        }
        if (default_path) |d| {
            const z = dupeZ(a, d) catch return;
            _ = sdl.c.SDL_SetStringProperty(props, sdl.c.SDL_PROP_FILE_DIALOG_LOCATION_STRING, z.ptr);
        }
        if (filters.len > 0) {
            const sf = a.alloc(sdl.c.SDL_DialogFileFilter, filters.len) catch return;
            for (filters, sf) |f, *dst| {
                dst.name = (dupeZ(a, f.name) catch return).ptr;
                dst.pattern = (dupeZ(a, f.pattern) catch return).ptr;
            }
            _ = sdl.c.SDL_SetPointerProperty(props, sdl.c.SDL_PROP_FILE_DIALOG_FILTERS_POINTER, sf.ptr);
            _ = sdl.c.SDL_SetNumberProperty(props, sdl.c.SDL_PROP_FILE_DIALOG_NFILTERS_NUMBER, @intCast(filters.len));
        }
        if (dialog_window) |w| {
            _ = sdl.c.SDL_SetPointerProperty(props, sdl.c.SDL_PROP_FILE_DIALOG_WINDOW_POINTER, w);
        }
        if (!save and allow_many) {
            _ = sdl.c.SDL_SetBooleanProperty(props, sdl.c.SDL_PROP_FILE_DIALOG_MANY_BOOLEAN, true);
        }
        sdl.c.SDL_ShowFileDialogWithProperties(
            if (save) sdl.c.SDL_FILEDIALOG_SAVEFILE else sdl.c.SDL_FILEDIALOG_OPENFILE,
            sdlDialogCb,
            ctx,
            props,
        );
        shown = true;
    }

    fn sdlOpenFileDialog(opts: Picker.OpenOptions, cb: Picker.Callback, userdata: ?*anyopaque) void {
        sdlShowDialog(false, opts.title, opts.default_path, opts.filters, opts.allow_multiple, cb, userdata);
    }
    fn sdlSaveFileDialog(opts: Picker.SaveOptions, cb: Picker.Callback, userdata: ?*anyopaque) void {
        sdlShowDialog(true, opts.title, opts.default_path, opts.filters, false, cb, userdata);
    }

    /// SDL_GetPrefPath is the app's private writable dir on every target
    /// (incl. Android files/ and the iOS sandbox); cache/config hang under
    /// it. temp stays on the env fallback — SDL has no temp-dir API.
    fn sdlResolveDir(allocator: std.mem.Allocator, kind: ui.platform.paths.DirKind, org: []const u8, app: []const u8) ?[]u8 {
        return switch (kind) {
            .executable => blk: {
                const p = sdl.c.SDL_GetBasePath() orelse break :blk null;
                break :blk allocator.dupe(u8, std.mem.span(p)) catch null;
            },
            .app_data => prefPathJoin(allocator, org, app, null),
            .cache => prefPathJoin(allocator, org, app, "cache"),
            .config => prefPathJoin(allocator, org, app, "config"),
            .temp => null,
        };
    }

    fn prefPathJoin(alloc: std.mem.Allocator, org: []const u8, app: []const u8, leaf: ?[]const u8) ?[]u8 {
        const zorg = dupeZ(alloc, if (org.len == 0) "klaxon" else org) catch return null;
        defer alloc.free(zorg);
        const zapp = dupeZ(alloc, if (app.len == 0) "app" else app) catch return null;
        defer alloc.free(zapp);
        const raw = sdl.c.SDL_GetPrefPath(zorg.ptr, zapp.ptr) orelse return null;
        defer sdl.c.SDL_free(raw);
        const base = std.mem.trimEnd(u8, std.mem.span(raw), "/\\");
        if (leaf) |l| return std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, l }) catch null;
        return alloc.dupe(u8, base) catch null;
    }

    /// Pointer cursors (Phase 2d-0.5, desktop): map the hovered node to a
    /// system cursor. Fail-soft: without a video driver the creation returns
    /// null and cursors are simply never set.
    fn updateCursor(host: *Host) void {
        if (host.cursors_unavailable) return;
        if (!host.cursors) {
            // disabled (mobile preset): restore the default arrow once
            if (host.current_cursor != .default) {
                const cur = host.cursorFor(.default) orelse return;
                if (!sdl.c.SDL_SetCursor(cur)) return;
                host.current_cursor = .default;
            }
            return;
        }
        const want = input_mod.cursorForNode(host.input.hoveredNode());
        if (want == host.current_cursor) return;
        const cur = host.cursorFor(want) orelse return;
        if (!sdl.c.SDL_SetCursor(cur)) return;
        host.current_cursor = want;
    }

    /// IME lifecycle: platform text input (the mobile soft keyboard, the
    /// desktop IME session) is active exactly while a wants_text_input
    /// node holds focus. Called every iteration — the area is re-anchored
    /// so the candidate window tracks layout moves, and SDL no-ops a
    /// redundant start.
    fn syncIme(host: *Host) void {
        const focused = host.input.focusedNode();
        const editing = focused != null and focused.?.vtable.wants_text_input;
        if (editing) {
            const node = focused.?;
            host.ime_node = node;
            const r = node.mapRectToRoot(node.bounds);
            var area = sdl.c.SDL_Rect{
                .x = @intFromFloat(@round(r.x)),
                .y = @intFromFloat(@round(r.y)),
                .w = @intFromFloat(@round(@max(0, r.w))),
                .h = @intFromFloat(@round(@max(0, r.h))),
            };
            // cursor offset: at the field's end edge (caret-side anchor).
            _ = sdl.c.SDL_SetTextInputArea(host.window, &area, area.w);
            if (!host.ime_active) {
                _ = sdl.c.SDL_StartTextInput(host.window);
                host.ime_active = true;
            }
        } else if (host.ime_active) {
            _ = sdl.c.SDL_StopTextInput(host.window);
            host.ime_active = false;
            host.ime_node = null;
        }
    }

    /// The SDL cursor for a shape (created lazily, cached).
    fn cursorFor(host: *Host, c: input_mod.PointerCursor) ?*sdl.c.SDL_Cursor {
        const idx: usize = @backingInt(c);
        if (host.cursor_cache[idx]) |cur| return cur;
        const created = sdl.c.SDL_CreateSystemCursor(sdlSystemCursor(c)) orelse {
            host.cursors_unavailable = true; // headless: no cursors
            return null;
        };
        host.cursor_cache[idx] = created;
        return created;
    }

    pub fn deinit(host: *Host) void {
        host.inspector.deinit();
        host.timeline.deinit();
        for (host.cursor_cache) |c| {
            if (c) |cur| sdl.c.SDL_DestroyCursor(cur);
        }
        if (host.texture) |t| sdl.c.SDL_DestroyTexture(t);
        if (host.renderer) |r| sdl.c.SDL_DestroyRenderer(r);
        kx.c.kx_destroy(host.ctx);
        if (host.gl_ctx) |ctx| _ = sdl.c.SDL_GL_DestroyContext(ctx);
        sdl.c.SDL_DestroyWindow(host.window);
        sdl.c.SDL_Quit();
        host.devtools.ledger.recordFree(.renderer, host.pixels.len);
        host.allocator.free(host.pixels);
    }

    /// Frame loop (native). Renders only when the tree is dirty; at idle it
    /// blocks on SDL_WaitEvent — 0 frames, 0 wakeups. `on_frame` is the app
    /// tick (it may mark nodes dirty). The animation timeline is ticked every
    /// iteration: active animations update signals → nodes mark dirty → the
    /// frame renders below (time-based values — the tick rate is the loop
    /// rate, ~120 Hz while animating).
    ///
    /// On emscripten this delegates to platform_wasm.runWasm: the browser
    /// owns the main thread and paces the loop with rAF (never blocks).
    pub fn run(host: *Host, root: *Node, max_frames: u64, on_frame: ?OnFrame, on_frame_ctx: ?*anyopaque) !void {
        if (is_emscripten) {
            platform_wasm.runWasm(host, root, max_frames, on_frame, on_frame_ctx);
            return;
        }
        // macOS: the NSAccessibility bridge; Android: the TalkBack bridge
        // (kx_a11y_android.cpp attaches the delegate over JNI); Windows:
        // the UIA bridge (kx_a11y_win.cpp — raw HWND providers, WM_GETOBJECT
        // → UiaReturnRawElementProvider via a subclassed WNDPROC); Linux:
        // the AT-SPI2 bridge (kx_a11y_linux.cpp — an AtkObject tree bridged
        // onto the a11y bus by the stock at-spi2-atk adaptor; when no a11y
        // bus is up — headless CI, no AT running — init is a no-op).
        if (builtin.os.tag == .macos or builtin.os.tag == .windows or
            builtin.os.tag == .linux) // .linux covers android (is_android ⊆ .linux)
        {
            kx.a11yInit(@ptrCast(root));
            defer kx.a11yShutdown();
        }
        var quit = false;
        host.syncWindowInsets(root); // first layout reads real insets
        // max_frames = 0 means run forever (mobile: the app lives until the
        // OS terminates it; native demos use a finite budget for testing).
        while (!quit and (max_frames == 0 or host.stats.frames < max_frames)) {
            quit = try host.runIteration(root, on_frame, on_frame_ctx);
        }
    }

    /// One pass of the frame loop (Phase 3f extraction): tick the animation
    /// timeline, drain pending events, run the app tick, render when the tree
    /// is dirty, pace the iteration. Returns true when the app requested quit.
    ///
    /// Native: the event wait blocks per the loop's state — dirty (drain,
    /// non-blocking), app ticking (wait out the rest of the frame budget),
    /// timed work pending (wake at the timeline's granularity, ~240 Hz),
    /// true idle (block on SDL_WaitEvent: 0 wakeups). The iteration is paced
    /// to the frame budget (~120 fps active).
    ///
    /// Emscripten: NEVER blocks. SDL_WaitEvent / SDL_WaitEventTimeout /
    /// SDL_Delay busy-poll without Asyncify and freeze the tab; the rAF main
    /// loop (platform_wasm.zig) paces the iteration, so only a non-blocking
    /// SDL_PollEvent drain runs and the pacing delay is compiled out.
    pub fn runIteration(host: *Host, root: *Node, on_frame: ?OnFrame, on_frame_ctx: ?*anyopaque) !bool {
        const iter_start_ns = sdl.c.SDL_GetTicksNS();
        // Animations (1e): advance the timeline — active animations update
        // signals → nodes mark dirty → the frame renders below. The clock
        // never runs past a queued event: a release stamped before a
        // long-press deadline is processed before the deadline fires.
        const now = sdl.c.SDL_GetTicks();
        var peek: sdl.c.SDL_Event = undefined;
        const tick_time: u64 = if (sdl.c.SDL_PeepEvents(&peek, 1, @intCast(sdl.c.SDL_PEEKEVENT), @intCast(sdl.c.SDL_EVENT_FIRST), @intCast(sdl.c.SDL_EVENT_LAST)) > 0)
            @min(now, peek.common.timestamp / 1_000_000)
        else
            now;
        host.timeline.tick(tick_time);
        var event: sdl.c.SDL_Event = undefined;
        var quit = false;
        if (is_emscripten) {
            // Wasm: non-blocking drain only — SDL's emscripten backend fills
            // the queue from its JS event handlers; the rAF callback paces
            // the loop. Blocking here would freeze the tab.
            while (sdl.c.SDL_PollEvent(&event)) {
                if (host.handleEvent(root, &event)) quit = true;
            }
        } else if (is_ios) {
            // iOS: no drain here — SDL_AppEvent (platform_ios.zig) dispatches
            // every event as SDL pumps them (SDL_main_callbacks also routes
            // the watch-only lifecycle events to the app callback).
            _ = &event; // no event drain on iOS — keep the slot referenced
        } else if (is_android) {
            // Android: non-blocking drain — SDL_main runs this loop on SDL's
            // main thread; the platform paces the iteration (no blocking
            // waits on mobile).
            while (sdl.c.SDL_PollEvent(&event)) {
                if (host.handleEvent(root, &event)) quit = true;
            }
        } else if (root.dirty) {
            // Active: drain events without blocking.
            while (sdl.c.SDL_PollEvent(&event)) {
                if (host.handleEvent(root, &event)) quit = true;
            }
        } else if (on_frame != null) {
            // Clean but the app ticks: wait out the rest of the frame
            // budget (the app may mark nodes dirty → rendered below).
            const elapsed_ms = (sdl.c.SDL_GetTicksNS() - iter_start_ns) / 1_000_000;
            if (elapsed_ms < FRAME_BUDGET_WAIT_MS) {
                const wait_ms = FRAME_BUDGET_WAIT_MS - @as(u32, @intCast(elapsed_ms));
                if (sdl.c.SDL_WaitEventTimeout(&event, @intCast(wait_ms))) {
                    if (host.handleEvent(root, &event)) quit = true;
                    while (sdl.c.SDL_PollEvent(&event)) {
                        if (host.handleEvent(root, &event)) quit = true;
                    }
                }
            }
        } else if (host.timeline.hasTimedWork()) {
            // Timed work pending (running animation / held pointer waiting
            // for a long-press deadline): wake at the timeline's
            // granularity (~240 Hz) instead of blocking indefinitely.
            if (sdl.c.SDL_WaitEventTimeout(&event, 4)) {
                if (host.handleEvent(root, &event)) quit = true;
                while (sdl.c.SDL_PollEvent(&event)) {
                    if (host.handleEvent(root, &event)) quit = true;
                }
            }
        } else {
            // True idle: block until an event arrives (0 wakeups).
            if (sdl.c.SDL_WaitEvent(&event)) {
                if (host.handleEvent(root, &event)) quit = true;
                while (sdl.c.SDL_PollEvent(&event)) {
                    if (host.handleEvent(root, &event)) quit = true;
                }
            }
        }
        // App tick every iteration (may mark nodes dirty). An app tick
        // means the app drives a continuous animation: render EVERY
        // iteration — a tick that changes nothing (e.g. an animation
        // value quantized to the same integer) must not stall the loop
        // (frames < max_frames with frames frozen = infinite loop).
        if (on_frame) |f| f(on_frame_ctx, host.stats.frames);
        // Render when the tree is dirty (or the app ticks: continuous) and
        // the app is active (mobile: skip while backgrounded).
        if (!quit and host.active and (root.dirty or on_frame != null)) host.renderFrame(root);
        // The IME follows the focused text node (soft keyboard up/down,
        // candidate-window anchor).
        host.syncIme();
        // Pointer cursor follows the hovered node (desktop, Phase 2d-0.5).
        host.updateCursor();
        // Pace the whole iteration to the frame budget (~120 fps active).
        host.paceIteration(iter_start_ns);
        return quit;
    }

    fn renderFrame(host: *Host, root: *Node) void {
        // The whole frame is a tree traversal: any widget code that deinits
        // a node (paint hooks, layout, signal writes) defers to the sweep.
        node_mod.traversalBegin();
        defer node_mod.traversalEnd();
        // Layout pass (Phase 1e): re-layout when sizes/structure changed.
        // Layout moves content, so the frame repaints fully. The pass is
        // timed separately (Phase 4a.4 frame timeline).
        const t_layout = sdl.c.SDL_GetTicksNS();
        if (root.layout_dirty) {
            root.layout(root.bounds);
            root.dirty = true;
            root.clearDamage();
            semantics_mod.notifyTreeDirty(); // the semantic tree may have changed
            // content moved under a stationary pointer: refresh hover (cursors)
            host.input.refreshHover(root);
            host.stats.layout_time_ms = @as(f32, @floatFromInt(sdl.c.SDL_GetTicksNS() - t_layout)) / 1e6;
        } else {
            host.stats.layout_time_ms = 0;
        }
        // NO-DAMAGE NO-OP: the tick/layout marked nothing and no damage
        // accumulated — the previous present already shows the current
        // state. Skip begin_frame/end_frame/present entirely: on Metal and
        // GLES the swapchain keeps the last drawable (not presenting an
        // unchanged frame is legal and correct); on raster the retained
        // surface already holds the pixels. The frame still COUNTS — an
        // on_frame app ticking without changes keeps its frame clock (and
        // max_frames keeps terminating) — only the GPU/paint work is
        // elided. The first frame never reaches here (the tree starts
        // dirty). Overlays (devtools/inspector) paint dynamic content every
        // frame, so they keep the full path alive.
        if (!root.dirty and !root.damage_valid and
            !host.devtools.enabled and !host.inspector.enabled)
        {
            host.stats.frames += 1;
            host.stats.frame_time_ms = 0;
            host.stats.paint_time_ms = 0;
            host.stats.record_time_ms = 0;
            host.stats.submit_time_ms = 0;
            host.stats.present_time_ms = 0;
            host.timeline.frame_overrun = false;
            return;
        }
        host.frame_start_ns = sdl.c.SDL_GetTicksNS();
        kx.c.kx_begin_frame(host.ctx);
        // HiDPI: the canvas is pixel-sized (kx_create got
        // pixel_width/pixel_height) while the tree lays out in points —
        // scale the point-space paint onto the pixel canvas (crisp on
        // Retina/HiDPI) on all platforms after kx_begin_frame resets the
        // canvas matrix.
        if (host.display_scale != 1.0) {
            kx.c.kx_save(host.ctx);
            kx.c.kx_scale(host.ctx, host.display_scale, host.display_scale);
        }
        // Dirty-rect is raster-only: the raster surface is retained between
        // frames; GPU backends acquire a fresh drawable each frame (no
        // retained pixels) → full repaint until retained composition lands.
        const raster = kx.c.kx_backend_of(host.ctx) == kx.c.KX_BACKEND_RASTER;
        const focus = semantics_mod.currentFocus();
        host.present_rect = null; // full present unless the damage path narrows it
        // A failed upload forces ONE full repaint; if it presents clean the
        // damage path resumes (persistent failures re-arm every frame).
        const recover_present = host.present_failed;
        host.present_failed = false;
        // The repaint region (root space = points): the traversal culls any
        // subtree that can't reach it — off-surface content costs nothing.
        const surface = ui.node.Rect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(host.width),
            .h = @floatFromInt(host.height),
        };
        // The DevTools overlay paints translucent pixels over the whole panel
        // area; a dirty-rect partial repaint would blend the new overlay over
        // retained old overlay pixels (ghosting). Force a full repaint when
        // the overlay (or the inspector panel) is enabled so the panel area
        // is cleared first.
        if (raster and root.damage_valid and !host.devtools.enabled and !host.inspector.enabled and !recover_present) {
            // Repaint the tree clipped to the damaged region — and clear the
            // clip first (SkCanvas::clear is clip-aware): vacated pixels
            // (moving widgets) are erased, not trailed. The focus ring paints
            // INSIDE the clip (a focus change damages its ring regions), so
            // unrelated repaints never redraw it.
            const d = ui.node.rectIntersect(root.damage, surface);
            if (d.w <= 0 or d.h <= 0) {
                // Damage entirely off-surface: nothing to repaint — and the
                // texture already holds the pixels, so present() can skip
                // the readback/upload too (zero-size rect).
                root.clearDamage();
                host.present_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            } else {
                // Clear the accumulator BEFORE painting: dirty marks raised
                // during the paint pass (paint hooks writing signals) start
                // next frame's damage, they aren't wiped by the tail clear.
                root.clearDamage();
                kx.c.kx_clip_rect(host.ctx, d.x, d.y, d.w, d.h);
                kx.c.kx_clear(host.ctx, 0);
                root.paint(host.ctx, d);
                host.paintPopupOverlay(); // above the tree (a popup overflows its anchor), below the ring
                if (focus) |fm| fm.paintRing(host.ctx);
                kx.c.kx_clip_reset(host.ctx);
                // The repaint touched only `d` — present uploads just that
                // region instead of two full-frame copies. Stored in PIXEL
                // space (the raster surface and texture are pixel-sized —
                // display_scale ≠ 1 on HiDPI), rounded out to cover the AA
                // fringe.
                const s = host.display_scale;
                // Clamp INTO the pixel surface: d is already intersected
                // with the logical surface, but floor/ceil in float can
                // still land 1px outside (e.g. 360*1.5 = 540.000…1 → ceil
                // 541). The readback clamps its copy again — an unclamped
                // rect here would desync the upload size/pitch from the
                // bytes actually read (OOB texels + smearing).
                const px0: c_int = @max(0, @as(c_int, @intFromFloat(@floor(d.x * s))));
                const py0: c_int = @max(0, @as(c_int, @intFromFloat(@floor(d.y * s))));
                const px1: c_int = @min(host.pixel_width, @as(c_int, @intFromFloat(@ceil((d.x + d.w) * s))));
                const py1: c_int = @min(host.pixel_height, @as(c_int, @intFromFloat(@ceil((d.y + d.h) * s))));
                host.present_rect = if (!fullPresentForced()) .{
                    .x = px0,
                    .y = py0,
                    .w = @max(0, px1 - px0),
                    .h = @max(0, py1 - py0),
                } else null; // A/B: force the full-surface upload
            }
        } else {
            root.clearDamage(); // same: marks during paint seed the next frame
            root.paint(host.ctx, surface);
            host.paintPopupOverlay();
            if (focus) |fm| fm.paintRing(host.ctx); // full repaint: ring included
        }
        // Inspector (Phase 4a.2): the bounds highlight paints after the focus
        // ring (over the tree, under the panel), the panel paints after that —
        // above everything, always unclipped (like the DevTools overlay).
        if (host.inspector.enabled) {
            // Rebuild FIRST: a selected node destroyed since the last frame
            // (e.g. a virtualized list scrolled) must be dropped before the
            // highlight paint dereferences it (use-after-free).
            host.inspector.rebuildRows(root);
            host.inspector.paintHighlight(host.ctx);
            host.inspector.paint(host.ctx, host.width, host.height);
        }
        // DevTools overlay (Phase 4a): painted after the tree and the focus
        // ring, outside the damage clip — above everything, always unclipped.
        // The stats still hold the PREVIOUS frame's times here (they update
        // after present, below): recordFrame + paint show last frame's numbers.
        if (host.devtools.enabled) {
            host.devtools.recordFrame(host.stats.frame_time_ms);
            host.devtools.paint(host.ctx, host.width, host.height, &host.stats);
        }
        if (host.display_scale != 1.0)
            kx.c.kx_restore(host.ctx);
        kx.c.kx_end_frame(host.ctx);
        const t_paint = sdl.c.SDL_GetTicksNS();
        // Record phase (Phase 4a.4): begin_frame → end_frame — the same span
        // paint_time_ms has always measured (kept for the FPS overlay and
        // the frame_overrun signal).
        host.stats.record_time_ms = @as(f32, @floatFromInt(t_paint - host.frame_start_ns)) / 1e6;
        // Damage was cleared before the paint pass — marks raised while
        // painting are still accumulating for the next frame; do NOT wipe.
        host.present(); // fills submit_time_ms / present_time_ms (raster)
        const t1 = sdl.c.SDL_GetTicksNS();
        host.stats.frames += 1;
        host.stats.frame_time_ms = @as(f32, @floatFromInt(t1 - host.frame_start_ns)) / 1e6;
        host.stats.paint_time_ms = host.stats.record_time_ms;
        // Mobile benchmark aid (Phase 4c): windowed fps + avg frame work time
        // log to the platform log (SDL_Log → console on iOS, logcat on
        // Android) so on-device / on-simulator per-backend numbers can be
        // read without a profiler. frame_time_ms is the render work time
        // (the vsync wait happens between iterations, not inside it).
        if (is_mobile) {
            host.fps_log_time_sum += host.stats.frame_time_ms;
            if (host.stats.frames % 600 == 0) {
                const now = sdl.c.SDL_GetTicksNS();
                if (host.fps_log_ns > 0) {
                    const elapsed_s: f64 = @as(f64, @floatFromInt(now - host.fps_log_ns)) / 1e9;
                    if (elapsed_s > 0) {
                        const avg_ms: f64 = @as(f64, host.fps_log_time_sum) / 600.0;
                        log("klaxon: {d:.1} fps, {d:.2} ms/frame over last 600 frames ({s})", .{ 600.0 / elapsed_s, avg_ms, host.stats.backend });
                    }
                }
                host.fps_log_ns = now;
                host.fps_log_time_sum = 0;
            }
        }
        // Frame timeline sample (Phase 4a.4): only while the overlay is on —
        // zero cost when off (the stats fields above update regardless).
        if (host.devtools.enabled) {
            host.devtools.timeline.record(
                host.stats.layout_time_ms,
                host.stats.record_time_ms,
                host.stats.submit_time_ms,
                host.stats.present_time_ms,
            );
        }
        // Frame budget signal (1e.7): low-priority animations pause on overrun.
        host.timeline.frame_overrun = host.stats.paint_time_ms > FRAME_BUDGET_MS;
        if (host.ppm_path != null and host.stats.frames == 30) host.dumpPpm();

        // iOS window-mapped gate: presents before the SDL view is attached
        // to its UIWindow are silently lost (black screen). Keep rendering
        // until the window is mapped, plus 200ms to cover the appearance
        // transition. (Ported from klaxon-spikes kx_metal.mm.)
        if (is_ios) {
            if (host.ios_mapped_ns < 0) {
                const props = sdl.c.SDL_GetWindowProperties(host.window);
                const uiwindow = sdl.c.SDL_GetPointerProperty(props, sdl.c.SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, null);
                if (uiwindow != null and kx.iosWindowMapped(uiwindow)) {
                    host.ios_mapped_ns = @intCast(sdl.c.SDL_GetTicksNS());
                }
                root.dirty = true; // keep rendering until mapped
            } else if (sdl.c.SDL_GetTicksNS() - @as(u64, @intCast(host.ios_mapped_ns)) < 200_000_000) {
                root.dirty = true; // 200ms grace after mapping
            }
        }

        // GPU warmup (Phase 4e.1): right after the first present (TTFF is
        // measured run-start -> first frame, so it stays untouched), pre-
        // compile the backend's programs for the framework's op set into a
        // small offscreen surface. The one-time compile lands in THIS call —
        // outside every frame's timed span — instead of inside the first
        // real frames (retail frame p99 was dominated by first-frames
        // shader-compile jank). Raster backends pre-compile nothing (the
        // call is a no-op returning true).
        // Emscripten: the browser composites only AFTER the rAF callback
        // returns, so warming inside callback 1 delays the first VISIBLE
        // frame — wait for callback 2 (stats.frames counts rendered frames:
        // reaching 2 means callback 1 fully returned and composited).
        const warmup_due = !is_emscripten or host.stats.frames >= 2;
        if (!host.gpu_warmed and warmup_due) {
            host.gpu_warmed = true;
            if (kx.c.kx_backend_of(host.ctx) != kx.c.KX_BACKEND_RASTER) {
                const t_warm = sdl.c.SDL_GetTicksNS();
                if (kx.c.kx_gpu_warmup(host.ctx)) {
                    const warm_ms = @as(f32, @floatFromInt(sdl.c.SDL_GetTicksNS() - t_warm)) / 1e6;
                    log("gpu warmup: {d:.1} ms — programs pre-compiled ({s})", .{ warm_ms, host.stats.backend });
                } else {
                    log("gpu warmup: no offscreen path on this backend yet ({s}) — first frames may jank once", .{host.stats.backend});
                }
            }
        }
    }

    /// Paint the open popup's overlay pass: popup content overflows its
    /// anchor (a menu panel over later siblings), so it paints after the
    /// whole tree — above everything except the focus ring. Inside the
    /// damage clip: the popup's dirty marks already cover its overflow.
    fn paintPopupOverlay(host: *Host) void {
        if (host.input.openPopupNode()) |popup| {
            if (popup.vtable.paint_overlay) |po| po(popup, host.ctx);
        }
    }

    /// Pace one loop iteration to the frame budget: delay only the remainder
    /// of the 8.3 ms budget (slow iterations run unthrottled). Compiled out
    /// on emscripten — the rAF main loop paces the iteration; SDL_Delay
    /// would busy-poll and freeze the tab. Also compiled out on mobile —
    /// the platform paces the iteration (CADisplayLink on iOS,
    /// eglSwapBuffers/vsync on Android).
    fn paceIteration(host: *Host, iter_start_ns: u64) void {
        if (is_emscripten or is_mobile) return;
        _ = host;
        const elapsed = sdl.c.SDL_GetTicksNS() - iter_start_ns;
        if (elapsed < FRAME_BUDGET_NS) {
            const remaining_ms: u32 = @intCast((FRAME_BUDGET_NS - elapsed) / 1_000_000);
            if (remaining_ms > 0) sdl.c.SDL_Delay(remaining_ms);
        }
    }

    /// Returns true if the event requests quit. Pub: platform_ios.zig calls
    /// it from SDL_AppEvent (iOS dispatches events through the SDL main
    /// callbacks, not through this loop's drain).
    pub fn handleEvent(host: *Host, root: *Node, event: *sdl.c.SDL_Event) bool {
        // iOS simulator: ignore QUIT/TERMINATING — the sim sends them when
        // the simctl launch parent exits; the app should run until the OS
        // kills it (mobile apps don't quit on their own).
        if (is_ios and (event.type == sdl.c.SDL_EVENT_QUIT or event.type == sdl.c.SDL_EVENT_TERMINATING)) {
            log("klaxon: ignoring event {d} on iOS", .{event.type});
            return false;
        }
        if (event.type == sdl.c.SDL_EVENT_QUIT) return true;
        // Linux AT-SPI bridge (Phase 3a): AT-initiated actions (AtkAction
        // "click", AtkComponent grab_focus) are invoked on the bridge's a11y
        // thread, which must not touch the render-thread-owned node tree —
        // the C++ side marshals them through this registered SDL user event
        // (kx_a11y_linux.cpp; user.code picks the action, user.data1/data2
        // carry the root and target node pointers). Dispatch here on the
        // render thread. The getter returns 0 when the bridge is down — no
        // real event has type 0.
        if ((is_linux or is_android) and event.type == kx.a11yActionEventType()) {
            const ptr: u64 = if (event.user.data2) |p| @intFromPtr(p) else 0;
            a11y_bridge.dispatchAtAction(event.user.code, event.user.data1, ptr);
            return false;
        }
        // Mobile lifecycle (Phase 3d/3e): background/foreground gating plus
        // the low-memory / terminating notifications. On iOS these arrive
        // through SDL_AppEvent (SDL_main_callbacks dispatches the watch-only
        // app events immediately); on Android they are never queued, so the
        // branch is a no-op there.
        if (is_mobile) {
            switch (event.type) {
                sdl.c.SDL_EVENT_WILL_ENTER_BACKGROUND, sdl.c.SDL_EVENT_DID_ENTER_BACKGROUND => {
                    host.active = false;
                    return false;
                },
                sdl.c.SDL_EVENT_WILL_ENTER_FOREGROUND, sdl.c.SDL_EVENT_DID_ENTER_FOREGROUND => {
                    // The surface may have been lost while backgrounded:
                    // full repaint on resume (no dirty-rect).
                    host.active = true;
                    root.dirty = true;
                    root.clearDamage();
                    return false;
                },
                sdl.c.SDL_EVENT_LOW_MEMORY => {
                    log("klaxon: low memory warning", .{});
                    return false;
                },
                // iOS TERMINATING already returned above (line ~997); the
                // only mobile build reaching this arm is Android, where the
                // event is never queued anyway.
                sdl.c.SDL_EVENT_TERMINATING => return true,
                else => {},
            }
        }
        // DevTools (Phase 4a): F12 toggles the overlay — checked before any
        // other key handling so it works regardless of the focused node.
        // Key-repeat events are ignored (holding F12 would toggle per repeat).
        if (event.type == sdl.c.SDL_EVENT_KEY_DOWN and event.key.key == sdl.c.SDLK_F12 and !event.key.repeat) {
            host.devtools.toggle();
            root.dirty = true; // force a repaint to show/hide the overlay
            return false;
        }
        // Inspector (Phase 4a.2): F11 toggles the panel — independent of F12.
        if (event.type == sdl.c.SDL_EVENT_KEY_DOWN and event.key.key == sdl.c.SDLK_F11 and !event.key.repeat) {
            host.inspector.toggle();
            root.dirty = true; // force a repaint to show/hide the panel
            // Invalidate the damage too: closing the panel re-enables the
            // dirty-rect path, and a widget-sized clip would leave the old
            // panel/highlight pixels outside it on the retained surface.
            root.clearDamage();
            return false;
        }
        // Moving the window between displays at different DPR fires these
        // without RESIZED — the backing pixel size and display_scale change,
        // so the canvas + buffers must be rebuilt (same work as a resize).
        // Window/display geometry changes can move the safe-area margins —
        // resync the insets (fullscreen toggles, display moves, safe-area
        // and screen-keyboard changes all arrive here).
        if (event.type == sdl.c.SDL_EVENT_WINDOW_MOVED or
            event.type == sdl.c.SDL_EVENT_WINDOW_DISPLAY_CHANGED or
            event.type == sdl.c.SDL_EVENT_WINDOW_ENTER_FULLSCREEN or
            event.type == sdl.c.SDL_EVENT_WINDOW_LEAVE_FULLSCREEN or
            event.type == sdl.c.SDL_EVENT_WINDOW_SAFE_AREA_CHANGED or
            event.type == sdl.c.SDL_EVENT_SCREEN_KEYBOARD_SHOWN or
            event.type == sdl.c.SDL_EVENT_SCREEN_KEYBOARD_HIDDEN)
        {
            host.syncWindowInsets(root);
        }
        if (event.type == sdl.c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED or
            event.type == sdl.c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED)
        {
            host.syncWindowInsets(root);
            host.resize(host.width, host.height);
            root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(host.width), .h = @floatFromInt(host.height) });
            root.dirty = true;
            return false;
        }
        if (event.type == sdl.c.SDL_EVENT_WINDOW_RESIZED) {
            const w: c_int = @intCast(event.window.data1);
            const h: c_int = @intCast(event.window.data2);
            if (w > 0 and h > 0) {
                host.syncWindowInsets(root);
                host.resize(w, h);
                // The surface is recreated (garbage pixels) and the tree is
                // laid out at the new size: full repaint, no dirty-rect.
                root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) });
                root.dirty = true;
                root.clearDamage();
                // The layout consumed the dirty flag renderFrame uses to
                // refresh hover — without this, hover/cursor stay stale
                // under a stationary pointer until the next motion event.
                host.input.refreshHover(root);
            }
        }
        // Input routing (Phase 1c/1d): platform events → router → widget tree.
        // Every pointer event carries its pointer id (mouse = which, touch =
        // finger id) and a timestamp (gesture timing). The event's own
        // timestamp (ns since SDL_Init, same epoch as SDL_GetTicks) is used —
        // not the handling time — so queued events keep their real clock.
        const time_ms: u64 = event.common.timestamp / 1_000_000;
        switch (event.type) {
            // The mouse is the primary pointer: normalized to ID 0 (hover
            // tracks pointer 0 only). Touches keep their own IDs (multi-touch).
            sdl.c.SDL_EVENT_MOUSE_MOTION => {
                // Inspector (Phase 4a.2): motion over the panel clears hover
                // and skips widget routing (the pointer is over the panel) —
                // unless a widget holds the pointer capture (an active drag):
                // the captured node keeps receiving moves even outside its
                // bounds, and dropping them would leave a stale drag whose
                // release lands later as an accidental click. SDL reports
                // pointer coords in logical window units on every platform
                // (the tree's own layout space) — no scaling needed.
                const sx = event.motion.x;
                const sy = event.motion.y;
                const has_capture = host.input.capturedNode(0) != null;
                if (host.inspector.enabled and !has_capture and host.inspector.hitZone(sx, sy, host.width, host.height) != .none) {
                    host.input.clearHover();
                    return false; // skip routing
                }
                host.input.dispatchPointer(root, .{
                    .phase = .move,
                    .x = sx,
                    .y = sy,
                    .pointer = 0,
                    .time_ms = time_ms,
                });
            },
            sdl.c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                // Inspector (Phase 4a.2): a click in the panel is consumed
                // (tree: select/expand, props: no-op); a click on the canvas
                // passively selects the hit node (routing continues normally).
                if (host.inspector.enabled) {
                    const px = event.button.x;
                    const py = event.button.y;
                    const z = host.inspector.hitZone(px, py, host.width, host.height);
                    if (z != .none) {
                        host.inspector.clickAt(root, px, py, host.width, host.height);
                        root.dirty = true;
                        return false; // consume the panel click
                    }
                    host.inspector.pickAt(root, px, py); // passive selection
                }
                // Every button dispatches — the event carries its SDL
                // button id (left/middle/right/Xn); widgets that don't
                // care treat all buttons alike, consumers that do
                // (context menus, secondary actions) can finally see them.
                {
                    // Logical window units — the tree's layout space.
                    const sx = event.button.x;
                    const sy = event.button.y;
                    host.input.dispatchPointer(root, .{
                        .phase = .down,
                        .x = sx,
                        .y = sy,
                        .button = event.button.button,
                        .pointer = 0,
                        .time_ms = time_ms,
                    });
                }
            },
            sdl.c.SDL_EVENT_MOUSE_BUTTON_UP => {
                // A press that began on the inspector panel releases over it
                // too — without this, a widget under the panel gets a stray
                // `.up` it never saw `.down` for.
                if (host.inspector.enabled and host.input.capturedNode(0) == null and
                    host.inspector.hitZone(
                        event.button.x,
                        event.button.y,
                        host.width,
                        host.height,
                    ) != .none)
                    return false;
                {
                    const sx = event.button.x;
                    const sy = event.button.y;
                    host.input.dispatchPointer(root, .{
                        .phase = .up,
                        .x = sx,
                        .y = sy,
                        .button = event.button.button,
                        .pointer = 0,
                        .time_ms = time_ms,
                    });
                }
            },
            // Touch: normalized finger coords → window pixels (multi-touch).
            sdl.c.SDL_EVENT_FINGER_DOWN => host.input.dispatchPointer(root, .{
                .phase = .down,
                .x = event.tfinger.x * @as(f32, @floatFromInt(host.width)),
                .y = event.tfinger.y * @as(f32, @floatFromInt(host.height)),
                .pointer = @intCast(event.tfinger.fingerID),
                .time_ms = time_ms,
            }),
            sdl.c.SDL_EVENT_FINGER_MOTION => host.input.dispatchPointer(root, .{
                .phase = .move,
                .x = event.tfinger.x * @as(f32, @floatFromInt(host.width)),
                .y = event.tfinger.y * @as(f32, @floatFromInt(host.height)),
                .pointer = @intCast(event.tfinger.fingerID),
                .time_ms = time_ms,
            }),
            sdl.c.SDL_EVENT_FINGER_UP => host.input.dispatchPointer(root, .{
                .phase = .up,
                .x = event.tfinger.x * @as(f32, @floatFromInt(host.width)),
                .y = event.tfinger.y * @as(f32, @floatFromInt(host.height)),
                .pointer = @intCast(event.tfinger.fingerID),
                .time_ms = time_ms,
            }),
            // Wheel → scroll event (Phase 1f): routed like pointer input.
            // The content may scroll under a stationary pointer: refresh hover.
            sdl.c.SDL_EVENT_MOUSE_WHEEL => {
                // Logical window units — the tree's layout space.
                const sx = event.wheel.mouse_x;
                const sy = event.wheel.mouse_y;
                // Inspector (Phase 4a.2): wheel over the panel scrolls the
                // tree view (consumed — no widget scroll).
                if (host.inspector.enabled and host.inspector.hitZone(sx, sy, host.width, host.height) != .none) {
                    // SDL3: wheel.y > 0 = scroll up (toward the start),
                    // wheel.y < 0 = scroll down. scrollBy's positive dy grows
                    // scroll_y (content moves down) → negate the event value.
                    host.inspector.scrollBy(-event.wheel.y, host.width, host.height);
                    root.dirty = true;
                    return false; // consume
                }
                host.input.dispatchScroll(root, .{
                    .x = sx,
                    .y = sy,
                    .delta_x = event.wheel.x,
                    .delta_y = event.wheel.y,
                    .pointer = 0,
                    .time_ms = time_ms,
                });
                host.input.refreshHover(root);
            },
            sdl.c.SDL_EVENT_TEXT_INPUT => {
                _ = host.input.dispatchKey(.{
                    .kind = .text_input,
                    .text = std.mem.span(event.text.text),
                });
            },
            sdl.c.SDL_EVENT_TEXT_EDITING => {
                // IME preedit: replaces the focused field's composition
                // range; the next TEXT_INPUT commits it.
                _ = host.input.dispatchKey(.{
                    .kind = .text_editing,
                    .text = if (event.edit.text) |t| std.mem.span(t) else "",
                    .comp_start = event.edit.start,
                    .comp_len = event.edit.length,
                });
            },
            sdl.c.SDL_EVENT_KEY_DOWN => {
                // Inspector (Phase 4a.2): when the tree panel has keyboard
                // focus, arrows/Enter/Escape navigate it — consumed before
                // any widget routing.
                if (host.inspector.enabled and host.inspector.tree_focus and !event.key.repeat) {
                    // Rows may reference nodes freed by a pointer/scroll
                    // dispatch earlier in this drain — rebuild first.
                    host.inspector.rebuildRows(root);
                    if (host.inspector.handleKey(event.key.key)) {
                        root.dirty = true;
                        return false; // consumed, no widget routing
                    }
                }
                // Back (Android hardware button / desktop Escape): the
                // focused chain gets the key first, then the navigator pops
                // (Phase 2a back handler).
                if (event.key.key == sdl.c.SDLK_ESCAPE or event.key.key == sdl.c.SDLK_AC_BACK) {
                    _ = host.input.dispatchBack();
                } else {
                    const ev = sdlKeyEvent(.key_down, event.key.key, event.key.mod);
                    // The focused node sees keys first (Tab included —
                    // time_picker consumes it to walk its hour/minute
                    // fields and bubbles false off the edge); unhandled
                    // keys fall to the semantics focus traversal, which
                    // is what moves keyboard focus on plain Tab.
                    if (!host.input.dispatchKey(ev)) {
                        // Unhandled by the focused node: Enter/Space activate it.
                        if (semantics_mod.currentFocus()) |fm| _ = fm.handleKey(ev);
                    }
                }
            },
            sdl.c.SDL_EVENT_KEY_UP => {
                // Focused node + bubble only: a key release with no
                // press-tracking consumer does nothing (no activation,
                // no traversal — key_down already handled those).
                _ = host.input.dispatchKey(sdlKeyEvent(.key_up, event.key.key, event.key.mod));
            },
            else => {},
        }
        return false;
    }

    fn sdlKeyEvent(kind: input_mod.KeyEvent.Kind, key: u32, mod: u16) input_mod.KeyEvent {
        const shortcut_mod: u32 = if (builtin.os.tag == .macos or builtin.os.tag == .ios)
            sdl.c.SDL_KMOD_LGUI | sdl.c.SDL_KMOD_RGUI // Cmd
        else
            sdl.c.SDL_KMOD_LCTRL | sdl.c.SDL_KMOD_RCTRL; // Ctrl
        return .{
            .kind = kind,
            .key = sdlKeyToKey(key),
            .shift = (mod & (sdl.c.SDL_KMOD_LSHIFT | sdl.c.SDL_KMOD_RSHIFT)) != 0,
            .command = (mod & shortcut_mod) != 0,
            .chr = if (key >= 'a' and key <= 'z') @intCast(key) else 0,
        };
    }

    fn sdlKeyToKey(k: u32) input_mod.Key {
        return switch (k) {
            sdl.c.SDLK_BACKSPACE => .backspace,
            sdl.c.SDLK_DELETE => .delete,
            sdl.c.SDLK_RETURN, sdl.c.SDLK_KP_ENTER => .enter,
            sdl.c.SDLK_ESCAPE => .escape,
            sdl.c.SDLK_LEFT => .left,
            sdl.c.SDLK_RIGHT => .right,
            sdl.c.SDLK_UP => .up,
            sdl.c.SDLK_DOWN => .down,
            sdl.c.SDLK_HOME => .home,
            sdl.c.SDLK_END => .end,
            sdl.c.SDLK_PAGEUP => .page_up,
            sdl.c.SDLK_PAGEDOWN => .page_down,
            sdl.c.SDLK_TAB => .tab,
            sdl.c.SDLK_SPACE => .space,
            else => .unknown,
        };
    }

    fn resize(host: *Host, w: c_int, h: c_int) void {
        host.width = w;
        host.height = h;
        // All platforms: the canvas is pixel-sized — re-query the pixel size
        // and DPR (WINDOW_RESIZED carries points). Mobile has no SDL
        // renderer/texture/pixel buffer to rebuild.
        host.refreshPixelSize();
        kx.c.kx_resize(host.ctx, host.pixel_width, host.pixel_height);
        if (is_mobile) return;
        // Memory ledger (Phase 4a.3): the pixel buffer is re-allocated —
        // move its tracked bytes (renderer subsystem) to the new size. GPU
        // backends keep no buffer (renderer == null → readback always fails).
        host.devtools.ledger.recordFree(.renderer, host.pixels.len);
        host.allocator.free(host.pixels);
        // Fail-soft on OOM (an @panic here would pull std.debug into the
        // mobile compile — see log()): the next present skips the readback
        // (kx_readback_rgba rejects a short buffer).
        host.pixels = if (host.renderer == null)
            &[_]u8{}
        else
            host.allocator.alloc(u8, @as(usize, @intCast(host.pixel_width)) * @as(usize, @intCast(host.pixel_height)) * 4) catch blk: {
                log("klaxon: out of memory", .{});
                break :blk &[_]u8{};
            };
        host.devtools.ledger.recordAlloc(.renderer, host.pixels.len);
        if (host.texture) |t| {
            sdl.c.SDL_DestroyTexture(t);
            host.texture = sdl.c.SDL_CreateTexture(host.renderer.?, sdl.c.SDL_PIXELFORMAT_ABGR8888, sdl.c.SDL_TEXTUREACCESS_STREAMING, host.pixel_width, host.pixel_height);
        }
    }

    /// Push the window's safe-area insets + soft-keyboard height into
    /// `ui.platform.window_insets`. `SDL_GetWindowSafeArea` reports the
    /// per-window interactive rect — the macOS notch, the iOS/Android
    /// status/nav bars + display cutout, TV overscan — in window (layout)
    /// units, so insets are the margin between the window edge and the
    /// safe rect. Re-queried at startup and on
    /// SDL_EVENT_WINDOW_SAFE_AREA_CHANGED / screen-keyboard / geometry
    /// events; a changed inset marks the tree layout-dirty since widgets
    /// read the global during layout.
    /// The Android insets listener unions the IME into the reported
    /// bottom edge: while the screen keyboard is up, the bottom inset IS
    /// the keyboard height, and the nav/gesture baseline is the last
    /// bottom seen while it was hidden. iOS excludes the keyboard from
    /// safeAreaInsets entirely — its height comes from our UIKit frame
    /// observer (kx_ios_keyboard_height).
    fn syncWindowInsets(host: *Host, root: *Node) void {
        var r: sdl.c.SDL_Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        if (!sdl.c.SDL_GetWindowSafeArea(host.window, &r)) return;
        var sa: ui.platform.window_insets.SafeArea = .{
            .top = @max(0, @as(f32, @floatFromInt(r.y))),
            .left = @max(0, @as(f32, @floatFromInt(r.x))),
            .right = @max(0, @as(f32, @floatFromInt(host.width - (r.x + r.w)))),
            .bottom = @max(0, @as(f32, @floatFromInt(host.height - (r.y + r.h)))),
        };
        var kb: f32 = 0;
        if (is_ios) {
            kb = kx.iosKeyboardHeight();
        } else if (sdl.c.SDL_ScreenKeyboardShown(host.window)) {
            kb = sa.bottom;
            sa.bottom = host.nav_baseline_bottom;
        } else {
            host.nav_baseline_bottom = sa.bottom;
        }
        const prev = ui.platform.window_insets.get();
        if (!prev.safe_area.eql(sa) or prev.keyboard_height != kb) {
            ui.platform.window_insets.set(.{ .safe_area = sa, .keyboard_height = kb });
            root.markLayoutDirty();
        }
    }

    /// Mobile: refresh the pixel size + display scale from the window (call
    /// on resize — the WINDOW_RESIZED event carries points, the canvas
    /// needs pixels).
    fn refreshPixelSize(host: *Host) void {
        if (forcedDpr() > 0) {
            // capture/test override — the canvas stays at the forced DPR
            host.display_scale = forcedDpr();
            host.pixel_width = @intFromFloat(@as(f32, @floatFromInt(host.width)) * host.display_scale);
            host.pixel_height = @intFromFloat(@as(f32, @floatFromInt(host.height)) * host.display_scale);
            return;
        }
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = sdl.c.SDL_GetWindowSizeInPixels(host.window, &pw, &ph);
        if (pw > 0 and ph > 0) {
            host.pixel_width = pw;
            host.pixel_height = ph;
        }
        host.display_scale = displayScaleOf(host.window, host.width, host.pixel_width);
    }

    /// One-shot diagnostic for a failed texture upload — a persistent
    /// failure shouldn't spam per frame, and a transient one self-heals via
    /// present_failed.
    fn logPresentFailOnce() void {
        const S = struct {
            var logged: bool = false;
        };
        if (!S.logged) {
            S.logged = true;
            std.debug.print("klaxon: SDL_UpdateTexture failed: {s}\n", .{sdl.c.SDL_GetError()});
        }
    }

    fn present(host: *Host) void {
        // Frame timeline (Phase 4a.4): the raster present splits into submit
        // (readback + texture update + render-to-queue) and present (the
        // SDL_RenderPresent vsync wait). GPU backends present inside
        // kx_end_frame — both stay 0 there (record covers the whole span).
        host.stats.submit_time_ms = 0;
        host.stats.present_time_ms = 0;
        if (host.texture) |t| {
            const t0 = sdl.c.SDL_GetTicksNS();
            var w: c_int = 0;
            var h: c_int = 0;
            if (host.present_rect) |r| {
                // Damage path: readback + upload only the repainted rect —
                // two copies shrink from w*h to the damaged region. An empty
                // rect means nothing repainted: skip the copy entirely.
                if (r.w > 0 and r.h > 0) {
                    const need = @as(usize, @intCast(r.w)) * @as(usize, @intCast(r.h)) * 4;
                    if (need <= host.pixels.len and
                        kx.c.kx_readback_rgba_rect(host.ctx, host.pixels.ptr, need, r.x, r.y, r.w, r.h))
                    {
                        if (!sdl.c.SDL_UpdateTexture(t, &r, host.pixels.ptr, r.w * 4)) {
                            // Stale texels in the damage rect: force the next
                            // frame onto the full-repaint path (once, logged).
                            host.present_failed = true;
                            logPresentFailOnce();
                        }
                    }
                }
                if (host.renderer) |r2| {
                    _ = sdl.c.SDL_RenderTexture(r2, t, null, null);
                    const t_submit = sdl.c.SDL_GetTicksNS();
                    _ = sdl.c.SDL_RenderPresent(r2);
                    const t_present = sdl.c.SDL_GetTicksNS();
                    host.stats.submit_time_ms = @as(f32, @floatFromInt(t_submit - t0)) / 1e6;
                    host.stats.present_time_ms = @as(f32, @floatFromInt(t_present - t_submit)) / 1e6;
                }
                return;
            }
            if (kx.c.kx_readback_rgba(host.ctx, host.pixels.ptr, host.pixels.len, &w, &h)) {
                if (!sdl.c.SDL_UpdateTexture(t, null, host.pixels.ptr, host.pixel_width * 4)) {
                    host.present_failed = true;
                    logPresentFailOnce();
                }
                if (host.renderer) |r| {
                    _ = sdl.c.SDL_RenderTexture(r, t, null, null);
                    const t_submit = sdl.c.SDL_GetTicksNS();
                    _ = sdl.c.SDL_RenderPresent(r);
                    const t_present = sdl.c.SDL_GetTicksNS();
                    host.stats.submit_time_ms = @as(f32, @floatFromInt(t_submit - t0)) / 1e6;
                    host.stats.present_time_ms = @as(f32, @floatFromInt(t_present - t_submit)) / 1e6;
                }
            }
        }
        // GPU backends present inside kx_end_frame (onscreen surface).
    }

    fn dumpPpm(host: *Host) void {
        const path = host.ppm_path orelse return;
        var w: c_int = 0;
        var h: c_int = 0;
        if (!kx.c.kx_readback_rgba(host.ctx, host.pixels.ptr, host.pixels.len, &w, &h)) return;
        const f = std.c.fopen(path, "wb") orelse return;
        defer _ = std.c.fclose(f);
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrintSentinel(&header_buf, "P6\n{d} {d}\n255\n", .{ w, h }, 0) catch return;
        _ = std.c.fwrite(header.ptr, 1, header.len, f);
        var i: usize = 0;
        const n = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
        while (i < n) : (i += 4) {
            _ = std.c.fwrite(host.pixels.ptr + i, 1, 3, f); // RGBA → RGB
        }
    }
};
