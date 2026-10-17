// Layer 4 (`src/platform/`) — Platform integration umbrella module.
// Exposes storage, networking, OS integration services, media primitives,
// and the abstract ADR-0006 WASM plugin runtime contract.

const std = @import("std");

pub const clipboard = @import("../ui/clipboard.zig");
pub const kv = @import("storage/kv.zig");
pub const paths = @import("storage/paths.zig");
pub const http = @import("net/http.zig");
pub const window_insets = @import("os/window_insets.zig");
pub const url = @import("os/url.zig");
pub const haptics = @import("os/haptics.zig");
pub const picker = @import("os/file_picker.zig");
pub const file_picker = picker;
pub const share_service = @import("os/share.zig");
pub const notifications = @import("os/notifications.zig");
pub const video = @import("media/video.zig");
pub const runtime = @import("runtime/plugin.zig");
pub const plugin = runtime;

// Convenience aliases matching docs/ARCHITECTURE.md
pub const openUrl = url.openUrl;
pub const share = share_service.share;
pub const notify = notifications.notify;
pub const haptic = haptics.trigger;
pub const safeArea = window_insets.safeArea;
pub const keyboardHeight = window_insets.keyboardHeight;

test "platform umbrella references all submodules" {
    std.testing.refAllDecls(clipboard);
    std.testing.refAllDecls(kv);
    std.testing.refAllDecls(paths);
    std.testing.refAllDecls(http);
    std.testing.refAllDecls(window_insets);
    std.testing.refAllDecls(url);
    std.testing.refAllDecls(haptics);
    std.testing.refAllDecls(picker);
    std.testing.refAllDecls(share_service);
    std.testing.refAllDecls(notifications);
    std.testing.refAllDecls(video);
    std.testing.refAllDecls(runtime);
}
