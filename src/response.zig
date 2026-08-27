const std = @import("std");
const http = @import("http");
const json_tools = @import("json.zig");

pub const ContentType = enum {
    text,
    json,
    binary,
};

const text_headers = [_]http.Response.Header{
    .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
};

const json_headers = [_]http.Response.Header{
    .{ .name = "Content-Type", .value = "application/json" },
};

const binary_headers = [_]http.Response.Header{
    .{ .name = "Content-Type", .value = "application/octet-stream" },
};

pub fn body(
    status: http.Response.Status,
    content_type: ContentType,
    bytes: []const u8,
) http.Response {
    return .{
        .status = status,
        .headers = switch (content_type) {
            .text => &text_headers,
            .json => &json_headers,
            .binary => &binary_headers,
        },
        .body = bytes,
    };
}

pub fn json(
    allocator: std.mem.Allocator,
    status: http.Response.Status,
    value: anytype,
) !http.Response {
    return body(status, .json, try json_tools.encode(allocator, value));
}

test "construct encoded body responses" {
    const text = body(.ok, .text, "hello");
    const encoded_json = body(.ok, .json, "{}");
    const binary = body(.ok, .binary, "\x00\xff");

    try std.testing.expectEqualStrings("text/plain; charset=utf-8", text.headers[0].value);
    try std.testing.expectEqualStrings("application/json", encoded_json.headers[0].value);
    try std.testing.expectEqualStrings("application/octet-stream", binary.headers[0].value);
}

test "serialize JSON response" {
    const result = try json(
        std.testing.allocator,
        .created,
        .{ .id = @as(i64, 42) },
    );
    defer std.testing.allocator.free(result.body);

    try std.testing.expectEqual(http.Response.Status.created.code, result.status.code);
    try std.testing.expectEqualStrings("application/json", result.headers[0].value);
    try std.testing.expectEqualStrings("{\"id\":42}", result.body);
}
