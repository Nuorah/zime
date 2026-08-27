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
    if (options.body.isPresent() and !method.requestHasBody())
        return error.BodyNotAllowed;
    if (options.body.contentType()) |content_type| {
        if (content_type.len == 0 or !isValidHeaderValue(content_type))
            return error.InvalidContentType;
    }

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
            .content_type = if (options.body.contentType()) |content_type|
                .{ .override = content_type }
            else
                .default,
        },
        // Strip caller-provided headers when redirecting to another host.
        .privileged_headers = backend_headers,
    });
    defer request.deinit();

    if (method.requestHasBody()) {
        try request.sendBodyComplete(@constCast(options.body.data()));
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

pub const Body = union(enum) {
    none,
    bytes: []const u8,
    json: []const u8,
    content: struct {
        content_type: []const u8,
        data: []const u8,
    },

    fn isPresent(self: Body) bool {
        return switch (self) {
            .none => false,
            else => true,
        };
    }

    fn data(self: Body) []const u8 {
        return switch (self) {
            .none => "",
            .bytes, .json => |bytes| bytes,
            .content => |content| content.data,
        };
    }

    fn contentType(self: Body) ?[]const u8 {
        return switch (self) {
            .none, .bytes => null,
            .json => "application/json",
            .content => |content| content.content_type,
        };
    }
};

pub const SendOptions = struct {
    method: Method = .GET,
    url: []const u8,
    headers: []const Header = &.{},
    body: Body = .none,
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
        isValidHeaderValue(header.value);
}

fn isValidHeaderValue(value: []const u8) bool {
    return std.mem.indexOf(u8, value, "\r\n") == null;
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
            .body = .{ .bytes = "not allowed" },
        },
    ));
}

test "body variants provide data and content type" {
    const bytes: Body = .{ .bytes = "raw" };
    try std.testing.expectEqualStrings("raw", bytes.data());
    try std.testing.expect(bytes.contentType() == null);

    const json: Body = .{ .json = "{}" };
    try std.testing.expectEqualStrings("{}", json.data());
    try std.testing.expectEqualStrings("application/json", json.contentType().?);

    const custom: Body = .{ .content = .{
        .content_type = "application/x-www-form-urlencoded",
        .data = "name=anon",
    } };
    try std.testing.expectEqualStrings("name=anon", custom.data());
    try std.testing.expectEqualStrings(
        "application/x-www-form-urlencoded",
        custom.contentType().?,
    );
}

test "reject malformed custom content type before network access" {
    var client = Client.init(std.testing.allocator, std.testing.io);
    defer client.deinit();

    try std.testing.expectError(error.InvalidContentType, client.send(
        std.testing.allocator,
        .{
            .method = .POST,
            .url = "https://example.com",
            .body = .{ .content = .{
                .content_type = "application/json\r\nX-Injected: yes",
                .data = "{}",
            } },
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
