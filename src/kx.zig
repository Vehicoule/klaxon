// Skia ABI bindings — generated at build time by `zig translate-c` over
// kx_skia/include/kx_skia.h (b.addTranslateC in build.zig).
pub const c = @import("kx_c");

pub const Ctx = c.kx_ctx;

// --- macOS NSAccessibility bridge (Phase 3a) ---
pub const c_extern = struct {
    extern fn kx_a11y_init(root_node: ?*anyopaque) void;
    extern fn kx_a11y_shutdown() void;
    extern fn kx_a11y_root_element() ?*anyopaque;
    /// Desktop Linux only (kx_a11y_linux.cpp): the SDL user-event type AT
    /// actions are marshalled through — 0 when the bridge is uninitialized.
    /// Only referenced from is_linux-gated code; the other platform bridges
    /// do not export it.
    extern fn kx_a11y_action_event_type() u32;
    /// iOS: true when the UIWindow's root view is attached (presents before
    /// mapping are silently lost — see klaxon-spikes kx_metal.mm).
    extern fn kx_ios_window_mapped(uiwindow: ?*anyopaque) bool;
    /// iOS (kx_skia_ios.mm): screen-points height of the strip the on-screen
    /// keyboard covers at the bottom edge (0 when hidden or floating).
    extern fn kx_ios_keyboard_height() f32;
};

pub fn a11yInit(root: *anyopaque) void {
    c_extern.kx_a11y_init(root);
}

pub fn a11yShutdown() void {
    c_extern.kx_a11y_shutdown();
}

/// Desktop Linux only: the SDL user-event type the ATK bridge pushes AT
/// actions on (0 = unregistered). See kx_a11y_linux.cpp's threading notes.
pub fn a11yActionEventType() u32 {
    return c_extern.kx_a11y_action_event_type();
}

/// iOS: true when the UIWindow's root view is attached (presents before
/// mapping are silently lost).
pub fn iosWindowMapped(uiwindow: ?*anyopaque) bool {
    return c_extern.kx_ios_window_mapped(uiwindow);
}

/// iOS: screen-points height of the strip the on-screen keyboard covers at
/// the bottom edge (0 when hidden or floating — see kx_skia_ios.mm).
pub fn iosKeyboardHeight() f32 {
    return c_extern.kx_ios_keyboard_height();
}

pub fn create(window: ?*anyopaque, width: c_int, height: c_int, backend: c.kx_backend) ?*Ctx {
    return c.kx_create(window, width, height, backend);
}

// --- tests ---

test "raster backend creates a headless ctx and destroys it" {
    const ctx = create(null, 64, 48, c.KX_BACKEND_RASTER) orelse return error.TestUnexpectedResult;
    c.kx_destroy(ctx);
}
