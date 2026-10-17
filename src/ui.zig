// UI core — re-exports.
pub const node = @import("ui/node.zig");
pub const paint = @import("ui/paint.zig");
pub const layout = @import("ui/layout.zig");
pub const state = @import("ui/state.zig");
pub const input = @import("ui/input.zig");
pub const gestures = @import("ui/gestures.zig");
pub const anim = @import("ui/anim.zig");
pub const interactions = @import("ui/interactions.zig");
pub const state_layer = @import("ui/state_layer.zig");
pub const ripple = @import("ui/ripple.zig");
pub const shapes = @import("ui/shapes.zig");
pub const scroll = @import("ui/scroll.zig");
pub const navigator = @import("ui/navigator.zig");
pub const i18n = @import("ui/i18n.zig");
pub const semantics = @import("ui/semantics.zig");
pub const clipboard = @import("ui/clipboard.zig");
pub const value = @import("ui/value.zig");
pub const platform = @import("platform/mod.zig");

// A pub const re-export is lazy — a module nothing else references isn't
// analyzed, so its tests would never run. Touch the machinery modules here
// until widget migration wires real uses (interactions arrives via
// state_layer, listed anyway for clarity).
test {
    _ = interactions;
    _ = state_layer;
    _ = ripple;
}
