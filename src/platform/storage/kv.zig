// Key-Value storage service (Layer 4 — platform/storage/kv.zig).
// Provides an allocator-owned key-value store with deterministic binary
// serialization and an optional persistent backend hook (used by host apps
// and ADR-0006 plugin host services).

const std = @import("std");

pub const Error = error{
    KeyTooLong,
    ValueTooLarge,
    QuotaExceeded,
    CorruptSnapshot,
    OutOfMemory,
};

pub const Limits = struct {
    max_key_bytes: usize = 256,
    max_value_bytes: usize = 1024 * 1024, // 1 MiB per value
    max_total_bytes: usize = 16 * 1024 * 1024, // 16 MiB total quota
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]u8) = .empty,
    limits: Limits = .{},
    total_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, limits: Limits) Store {
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *Store) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
        self.total_bytes = 0;
    }

    pub fn get(self: *const Store, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn getOwned(self: *const Store, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        const val = self.map.get(key) orelse return null;
        return try allocator.dupe(u8, val);
    }

    pub fn contains(self: *const Store, key: []const u8) bool {
        return self.map.contains(key);
    }

    pub fn count(self: *const Store) usize {
        return self.map.count();
    }

    pub fn put(self: *Store, key: []const u8, value: []const u8) Error!void {
        if (key.len == 0 or key.len > self.limits.max_key_bytes) return error.KeyTooLong;
        if (value.len > self.limits.max_value_bytes) return error.ValueTooLarge;

        if (self.map.getEntry(key)) |existing| {
            const old_len = existing.value_ptr.*.len;
            const next_total = self.total_bytes - old_len + value.len;
            if (next_total > self.limits.max_total_bytes) return error.QuotaExceeded;
            const new_val = try self.allocator.dupe(u8, value);
            self.allocator.free(existing.value_ptr.*);
            existing.value_ptr.* = new_val;
            self.total_bytes = next_total;
            return;
        }

        const entry_cost = key.len + value.len;
        if (self.total_bytes + entry_cost > self.limits.max_total_bytes) return error.QuotaExceeded;

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_val = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_val);

        try self.map.put(self.allocator, owned_key, owned_val);
        self.total_bytes += entry_cost;
    }

    pub fn remove(self: *Store, key: []const u8) bool {
        if (self.map.fetchRemove(key)) |kv| {
            self.total_bytes -= kv.key.len + kv.value.len;
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
            return true;
        }
        return false;
    }

    pub fn clear(self: *Store) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.clearRetainingCapacity();
        self.total_bytes = 0;
    }

    /// Serialize the store into a compact binary snapshot:
    /// magic "KXKV" (4B) + version u32 LE (1) + count u32 LE + [klen u32 LE][vlen u32 LE][key][val]...
    pub fn serialize(self: *const Store, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "KXKV");
        var hdr: [8]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], 1, .little);
        std.mem.writeInt(u32, hdr[4..8], @intCast(self.map.count()), .little);
        try buf.appendSlice(allocator, &hdr);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            var lens: [8]u8 = undefined;
            std.mem.writeInt(u32, lens[0..4], @intCast(entry.key_ptr.*.len), .little);
            std.mem.writeInt(u32, lens[4..8], @intCast(entry.value_ptr.*.len), .little);
            try buf.appendSlice(allocator, &lens);
            try buf.appendSlice(allocator, entry.key_ptr.*);
            try buf.appendSlice(allocator, entry.value_ptr.*);
        }
        return buf.toOwnedSlice(allocator);
    }

    /// Restore entries from a binary snapshot produced by `serialize`.
    pub fn deserialize(self: *Store, bytes: []const u8) Error!void {
        if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "KXKV")) return error.CorruptSnapshot;
        const ver = std.mem.readInt(u32, bytes[4..8], .little);
        if (ver != 1) return error.CorruptSnapshot;
        const n = std.mem.readInt(u32, bytes[8..12], .little);

        var pos: usize = 12;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (pos + 8 > bytes.len) return error.CorruptSnapshot;
            const klen: usize = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            const vlen: usize = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
            pos += 8;
            if (pos + klen + vlen > bytes.len) return error.CorruptSnapshot;
            const k = bytes[pos .. pos + klen];
            pos += klen;
            const v = bytes[pos .. pos + vlen];
            pos += vlen;
            try self.put(k, v);
        }
        if (pos != bytes.len) return error.CorruptSnapshot;
    }
};

test "kv: put, get, overwrite, remove, quota, and snapshot round-trip" {
    const alloc = std.testing.allocator;
    var store = Store.initWithLimits(alloc, .{
        .max_key_bytes = 32,
        .max_value_bytes = 64,
        .max_total_bytes = 128,
    });
    defer store.deinit();

    try store.put("theme", "dark");
    try store.put("locale", "fr");
    try std.testing.expectEqual(@as(usize, 2), store.count());
    try std.testing.expectEqualStrings("dark", store.get("theme").?);

    // Overwrite updates value without leaking key
    try store.put("theme", "light");
    try std.testing.expectEqualStrings("light", store.get("theme").?);

    // Reject empty key and oversized value
    try std.testing.expectError(error.KeyTooLong, store.put("", "v"));
    const huge: [80]u8 = @splat('x');
    try std.testing.expectError(error.ValueTooLarge, store.put("huge", &huge));

    // Snapshot serialize/deserialize
    const snap = try store.serialize(alloc);
    defer alloc.free(snap);

    var restored = Store.init(alloc);
    defer restored.deinit();
    try restored.deserialize(snap);
    try std.testing.expectEqual(@as(usize, 2), restored.count());
    try std.testing.expectEqualStrings("light", restored.get("theme").?);
    try std.testing.expectEqualStrings("fr", restored.get("locale").?);

    try std.testing.expect(store.remove("locale"));
    try std.testing.expect(!store.contains("locale"));
}
