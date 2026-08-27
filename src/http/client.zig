const std = @import("std");

pub const Client = @This();

backend: std.http.Client,

pub fn init(allocator: std.mem.Allocator, io: std.Io) Client {
    return .{
        .backend = .{ .allocator = allocator, .io = io },
    };
}

pub fn deinit(self: *Client) void {
    self.backend.deinit();
}

pub fn send(
    self: *Client,
    allocator: std.mem.Allocator,
    options: SendOptions,
) !Response {
    const method = options.method.toStd();
    if (options.body.len != 0 and !method.requestHasBody())
        return error.BodyNotAllowed;

    for (options.headers) |header| {
        if (!isValidHeader(header))
            return error.InvalidHeader;
    }

    const uri = try std.Uri.parse(options.url);

    const backend_headers = try allocator.alloc(std.http.Header, options.headers.len);
    defer allocator.free(backend_headers);
    for (options.headers, backend_headers) |source, *destination| {
        destination.* = .{
            .name = source.name,
            .value = source.value,
        };
    }

    var request = try self.backend.request(method, uri, .{
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
        // Strip caller-provided headers when redirecting to another host.
        .privileged_headers = backend_headers,
    });
    defer request.deinit();

    if (method.requestHasBody()) {
        try request.sendBodyComplete(@constCast(options.body));
    } else {
        try request.sendBodiless();
    }

    var head_buffer: [32 * 1024]u8 = undefined;
    var backend_response = try request.receiveHead(&head_buffer);
    const status: u16 = @intFromEnum(backend_response.head.status);

    var transfer_buffer: [8 * 1024]u8 = undefined;
    const reader = backend_response.reader(&transfer_buffer);
    const body = try reader.allocRemaining(
        allocator,
        .limited(options.max_response_bytes),
    );

    return .{
        .status = status,
        .body = body,
    };
}

pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,

    fn toStd(self: Method) std.http.Method {
        return switch (self) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .PATCH => .PATCH,
            .DELETE => .DELETE,
            .HEAD => .HEAD,
        };
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const SendOptions = struct {
    method: Method = .GET,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    max_response_bytes: usize = 1024 * 1024,
};

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

fn isValidHeader(header: Header) bool {
    if (header.name.len == 0 or
        std.mem.indexOfScalar(u8, header.name, ':') != null)
    {
        return false;
    }

    return std.mem.indexOf(u8, header.name, "\r\n") == null and
        std.mem.indexOf(u8, header.value, "\r\n") == null;
}

test "response owns its buffered body" {
    const body = try std.testing.allocator.dupe(u8, "response body");
    var response: Response = .{ .status = 200, .body = body };
    response.deinit(std.testing.allocator);
}

test "reject request body for a bodiless method before network access" {
    var client = Client.init(std.testing.allocator, std.testing.io);
    defer client.deinit();

    try std.testing.expectError(error.BodyNotAllowed, client.send(
        std.testing.allocator,
        .{
            .method = .GET,
            .url = "https://example.com",
            .body = "not allowed",
        },
    ));
}

test "reject malformed headers before network access" {
    var client = Client.init(std.testing.allocator, std.testing.io);
    defer client.deinit();

    const headers = [_]Header{
        .{ .name = "X-Test", .value = "safe\r\nX-Injected: yes" },
    };
    try std.testing.expectError(error.InvalidHeader, client.send(
        std.testing.allocator,
        .{
            .url = "https://example.com",
            .headers = &headers,
        },
    ));
}
