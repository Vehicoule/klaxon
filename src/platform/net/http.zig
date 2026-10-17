// HTTP client abstraction (Layer 4 — platform/net/http.zig).
// Provides a transport-agnostic HTTP client interface with ADR-0006 budget
// enforcement (call count, timeout, max request/response payload bytes).

const std = @import("std");

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method = .GET,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    timeout_ms: u32 = 10_000,
};

pub const Response = struct {
    status: u16,
    headers: []Header = &.{},
    body: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        for (self.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        if (self.headers.len > 0) allocator.free(self.headers);
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Error = error{
    InvalidUrl,
    CallBudgetExhausted,
    PayloadTooLarge,
    Timeout,
    NoTransport,
    NetworkError,
    OutOfMemory,
};

pub const Budgets = struct {
    max_calls: u32 = 32,
    default_timeout_ms: u32 = 10_000,
    max_body_bytes: usize = 8 * 1024 * 1024, // 8 MiB per ADR-0006
};

pub const Transport = struct {
    ctx: ?*anyopaque = null,
    send: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        req: Request,
    ) Error!Response,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: ?Transport = null,
    budgets: Budgets = .{},
    calls_made: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, transport: ?Transport, budgets: Budgets) Client {
        return .{
            .allocator = allocator,
            .transport = transport,
            .budgets = budgets,
        };
    }

    pub fn resetBudget(self: *Client) void {
        self.calls_made = 0;
    }

    pub fn send(self: *Client, req: Request) Error!Response {
        if (!isValidHttpUrl(req.url)) return error.InvalidUrl;
        if (self.calls_made >= self.budgets.max_calls) return error.CallBudgetExhausted;
        if (req.body.len > self.budgets.max_body_bytes) return error.PayloadTooLarge;

        const t = self.transport orelse return error.NoTransport;
        self.calls_made += 1;

        var effective = req;
        if (effective.timeout_ms == 0 or effective.timeout_ms > self.budgets.default_timeout_ms) {
            effective.timeout_ms = self.budgets.default_timeout_ms;
        }
        var resp = try t.send(t.ctx, self.allocator, effective);
        if (resp.body.len > self.budgets.max_body_bytes) {
            resp.deinit(self.allocator);
            return error.PayloadTooLarge;
        }
        return resp;
    }
};

pub fn isValidHttpUrl(url: []const u8) bool {
    const rest = if (std.mem.startsWith(u8, url, "https://"))
        url["https://".len..]
    else if (std.mem.startsWith(u8, url, "http://"))
        url["http://".len..]
    else
        return false;
    if (rest.len == 0 or rest[0] == '/') return false;
    for (url) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }
    return true;
}

test "http: URL validation and budget enforcement" {
    const alloc = std.testing.allocator;
    const Mock = struct {
        fn send(_: ?*anyopaque, allocator: std.mem.Allocator, req: Request) Error!Response {
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, req.url),
            };
        }
    };

    var client = Client.init(alloc, .{ .send = Mock.send }, .{
        .max_calls = 2,
        .default_timeout_ms = 5_000,
        .max_body_bytes = 64,
    });

    try std.testing.expectError(error.InvalidUrl, client.send(.{ .url = "ftp://example.com" }));
    try std.testing.expectError(error.InvalidUrl, client.send(.{ .url = "https://" }));

    var r1 = try client.send(.{ .url = "https://api.example.com/v1" });
    defer r1.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 200), r1.status);
    try std.testing.expectEqualStrings("https://api.example.com/v1", r1.body);

    var r2 = try client.send(.{ .url = "http://localhost:8080/health" });
    defer r2.deinit(alloc);

    // 3rd call exceeds max_calls = 2
    try std.testing.expectError(error.CallBudgetExhausted, client.send(.{ .url = "https://api.example.com/v2" }));
}
