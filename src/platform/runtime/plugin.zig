// Abstract WASM plugin runtime contract (Layer 4 — platform/runtime/plugin.zig).
// Implements ADR-0006: Klaxon exposes ONLY the abstract `PluginRuntime` trait,
// capability taxonomy, and sandbox resource budgets. Applications (e.g. Vehicule)
// supply the concrete WAMR or native sandbox implementation.

const std = @import("std");
const http = @import("../net/http.zig");
const kv = @import("../storage/kv.zig");

/// The 11 plugin capabilities defined in ADR-0006.
pub const Capability = enum(u8) {
    catalog_search = 0,
    catalog_metadata = 1,
    catalog_artwork = 2,
    catalog_entity = 3,
    catalog_suggest = 4,
    playback_resolve = 5,
    playback_candidates = 6,
    lyrics_plain = 7,
    lyrics_synced = 8,
    radio_seed = 9,
    tracker = 10,

    pub fn wireName(self: Capability) []const u8 {
        return switch (self) {
            .catalog_search => "catalog.search",
            .catalog_metadata => "catalog.metadata",
            .catalog_artwork => "catalog.artwork",
            .catalog_entity => "catalog.entity",
            .catalog_suggest => "catalog.suggest",
            .playback_resolve => "playback.resolve",
            .playback_candidates => "playback.candidates",
            .lyrics_plain => "lyrics.plain",
            .lyrics_synced => "lyrics.synced",
            .radio_seed => "radio.seed",
            .tracker => "tracker",
        };
    }
};

/// Structural sandbox budgets mandated by ADR-0006 (`vh_call` v0.1).
pub const Budgets = struct {
    fuel_default: u64 = 200_000_000,
    fuel_max: u64 = 2_000_000_000,
    max_memory_bytes: usize = 64 * 1024 * 1024, // 64 MiB linear memory
    max_table_elements: u32 = 65_536, // 64K table elements
    deadline_ms: u32 = 30_000, // 30s wall clock deadline
    max_http_calls: u32 = 32, // 32 HTTP requests per call
    http_timeout_ms: u32 = 10_000, // 10s per HTTP request
    max_io_bytes: usize = 8 * 1024 * 1024, // 8 MiB in + out per call
    max_artifact_bytes: usize = 5 * 1024 * 1024, // 5 MiB per artifact
};

pub const HostServices = struct {
    http_client: ?*http.Client = null,
    kv_store: ?*kv.Store = null,
    now_ms: ?*const fn () u64 = null,
};

pub const ModuleHandle = *anyopaque;

pub const Error = error{
    InvalidModule,
    FuelExhausted,
    MemoryLimitExceeded,
    DeadlineExceeded,
    PayloadTooLarge,
    UnsupportedCapability,
    Trap,
    OutOfMemory,
};

pub const VTable = struct {
    load_module: *const fn (
        ctx: *anyopaque,
        wasm_bytes: []const u8,
        budgets: Budgets,
    ) Error!ModuleHandle,
    unload_module: *const fn (ctx: *anyopaque, module: ModuleHandle) void,
    call: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        module: ModuleHandle,
        capability: Capability,
        input: []const u8,
        services: HostServices,
    ) Error![]u8,
    deinit: *const fn (ctx: *anyopaque) void,
};

pub const PluginRuntime = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    budgets: Budgets = .{},

    pub fn loadModule(self: PluginRuntime, wasm_bytes: []const u8) Error!ModuleHandle {
        if (wasm_bytes.len == 0 or wasm_bytes.len > self.budgets.max_artifact_bytes) {
            return error.InvalidModule;
        }
        return self.vtable.load_module(self.ctx, wasm_bytes, self.budgets);
    }

    pub fn unloadModule(self: PluginRuntime, module: ModuleHandle) void {
        self.vtable.unload_module(self.ctx, module);
    }

    pub fn call(
        self: PluginRuntime,
        allocator: std.mem.Allocator,
        module: ModuleHandle,
        capability: Capability,
        input: []const u8,
        services: HostServices,
    ) Error![]u8 {
        if (input.len > self.budgets.max_io_bytes) return error.PayloadTooLarge;
        const out = try self.vtable.call(self.ctx, allocator, module, capability, input, services);
        if (out.len > self.budgets.max_io_bytes) {
            allocator.free(out);
            return error.PayloadTooLarge;
        }
        return out;
    }

    pub fn deinit(self: PluginRuntime) void {
        self.vtable.deinit(self.ctx);
    }
};

test "plugin: capability wire names and runtime budget checks" {
    try std.testing.expectEqualStrings("catalog.search", Capability.catalog_search.wireName());
    try std.testing.expectEqualStrings("playback.resolve", Capability.playback_resolve.wireName());

    const MockRuntime = struct {
        dummy_mod: u8 = 1,

        fn load(ctx: *anyopaque, wasm_bytes: []const u8, _: Budgets) Error!ModuleHandle {
            if (wasm_bytes.len < 4) return error.InvalidModule;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return @ptrCast(&self.dummy_mod);
        }
        fn unload(_: *anyopaque, _: ModuleHandle) void {}
        fn invoke(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: ModuleHandle,
            cap: Capability,
            input: []const u8,
            _: HostServices,
        ) Error![]u8 {
            return std.fmt.allocPrint(allocator, "{s}:{s}", .{ cap.wireName(), input });
        }
        fn deinitFn(_: *anyopaque) void {}
    };

    var mock: MockRuntime = .{};
    const rt: PluginRuntime = .{
        .ctx = &mock,
        .vtable = &.{
            .load_module = MockRuntime.load,
            .unload_module = MockRuntime.unload,
            .call = MockRuntime.invoke,
            .deinit = MockRuntime.deinitFn,
        },
        .budgets = .{ .max_io_bytes = 32, .max_artifact_bytes = 64 },
    };
    defer rt.deinit();

    try std.testing.expectError(error.InvalidModule, rt.loadModule(""));
    const mod = try rt.loadModule("\x00asm\x01\x00\x00\x00");
    defer rt.unloadModule(mod);

    const alloc = std.testing.allocator;
    const res = try rt.call(alloc, mod, .lyrics_plain, "track-1", .{});
    defer alloc.free(res);
    try std.testing.expectEqualStrings("lyrics.plain:track-1", res);

    // Input exceeding max_io_bytes is rejected before invoking the guest
    const huge_in: [40]u8 = @splat('a');
    try std.testing.expectError(error.PayloadTooLarge, rt.call(alloc, mod, .lyrics_plain, &huge_in, .{}));
}
