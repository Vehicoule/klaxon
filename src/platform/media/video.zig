// Video & audio media service (Layer 4 — platform/media/video.zig).
// Defines the zero-copy / streaming video frame contract and playback controls
// used by media widgets and the 120 fps video_playback benchmark scene.

const std = @import("std");

pub const PixelFormat = enum(u8) {
    rgba8888 = 0,
    bgra8888 = 1,
    nv12 = 2,
};

pub const PlaybackState = enum(u8) {
    idle = 0,
    playing = 1,
    paused = 2,
    ended = 3,
    err = 4,
};

pub const FrameDesc = struct {
    width: u32,
    height: u32,
    format: PixelFormat = .rgba8888,
    pts_ns: u64 = 0,
    /// Tightly-packed pixel buffer (width * height * 4 for RGBA/BGRA).
    pixels: []const u8,

    pub fn isValid(self: FrameDesc) bool {
        if (self.width == 0 or self.height == 0) return false;
        const px_count = @as(usize, self.width) * @as(usize, self.height);
        return switch (self.format) {
            .rgba8888, .bgra8888 => self.pixels.len >= px_count * 4,
            .nv12 => self.pixels.len >= px_count + (px_count / 2),
        };
    }
};

pub const VideoVTable = struct {
    play: *const fn (ctx: *anyopaque) void,
    pause: *const fn (ctx: *anyopaque) void,
    seek_ns: *const fn (ctx: *anyopaque, position_ns: u64) void,
    state: *const fn (ctx: *anyopaque) PlaybackState,
    duration_ns: *const fn (ctx: *anyopaque) u64,
    position_ns: *const fn (ctx: *anyopaque) u64,
    acquire_frame: *const fn (ctx: *anyopaque) ?FrameDesc,
    deinit: *const fn (ctx: *anyopaque) void,
};

pub const VideoPlayer = struct {
    ctx: *anyopaque,
    vtable: *const VideoVTable,

    pub fn play(self: VideoPlayer) void {
        self.vtable.play(self.ctx);
    }

    pub fn pause(self: VideoPlayer) void {
        self.vtable.pause(self.ctx);
    }

    pub fn seekNs(self: VideoPlayer, position_ns: u64) void {
        self.vtable.seek_ns(self.ctx, position_ns);
    }

    pub fn state(self: VideoPlayer) PlaybackState {
        return self.vtable.state(self.ctx);
    }

    pub fn durationNs(self: VideoPlayer) u64 {
        return self.vtable.duration_ns(self.ctx);
    }

    pub fn positionNs(self: VideoPlayer) u64 {
        return self.vtable.position_ns(self.ctx);
    }

    pub fn acquireFrame(self: VideoPlayer) ?FrameDesc {
        return self.vtable.acquire_frame(self.ctx);
    }

    pub fn deinit(self: VideoPlayer) void {
        self.vtable.deinit(self.ctx);
    }
};

test "video: FrameDesc validation checks buffer byte length" {
    const rgba: [16]u8 = @splat(0);
    const valid = FrameDesc{ .width = 2, .height = 2, .format = .rgba8888, .pixels = &rgba };
    try std.testing.expect(valid.isValid());

    const short = FrameDesc{ .width = 4, .height = 4, .format = .rgba8888, .pixels = &rgba };
    try std.testing.expect(!short.isValid());
}
