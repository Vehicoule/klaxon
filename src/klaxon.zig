// Klaxon — umbrella module for external apps (Phase 5a).
//
// A project scaffolded by `klaxon create` imports the whole framework as
// `@import("klaxon")` and reaches the pieces through these re-exports:
//
//     const klaxon = @import("klaxon");
//     klaxon.host.Host.init(...)
//     klaxon.widgets.text.text(...)
//     klaxon.ui.state.Signal(...)
//     klaxon.kx.c.KX_BACKEND_AUTO
//
// One named module wraps all of src/: every file-relative import inside the
// framework then resolves into this same module instance, so the app and the
// framework share types and globals (input router, timeline, registry) —
// importing src/*.zig roots separately would compile them twice and split
// that state.
pub const kx = @import("kx.zig");
pub const sdl = @import("sdl.zig");
pub const ui = @import("ui.zig");
pub const theme = @import("theme.zig");
pub const widgets = @import("widgets.zig");
pub const host = @import("host.zig");
pub const platform = @import("platform.zig");
pub const c_abi = @import("c_abi.zig");
pub const ios_io = @import("ios_io.zig");
pub const registry = @import("registry.zig");
