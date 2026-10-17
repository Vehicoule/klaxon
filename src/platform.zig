// Platform layer root re-export (`src/platform.zig` -> `src/platform/mod.zig`).
pub const mod = @import("platform/mod.zig");
pub const clipboard = mod.clipboard;
pub const kv = mod.kv;
pub const paths = mod.paths;
pub const http = mod.http;
pub const window_insets = mod.window_insets;
pub const url = mod.url;
pub const haptics = mod.haptics;
pub const picker = mod.picker;
pub const file_picker = mod.file_picker;
pub const share_service = mod.share_service;
pub const notifications = mod.notifications;
pub const video = mod.video;
pub const runtime = mod.runtime;
pub const plugin = mod.plugin;

pub const openUrl = mod.openUrl;
pub const share = mod.share;
pub const notify = mod.notify;
pub const haptic = mod.haptic;
pub const safeArea = mod.safeArea;
pub const keyboardHeight = mod.keyboardHeight;
